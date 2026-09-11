-- pkgs:qemu/img — image specs, builder registry, env assembly, manifest
-- caching and the qemu:img action core (design2/images.md).
--
-- An *image* is a disk-image artifact built from a spec and cached by
-- hashes (manifests) of its inputs. A builder is a *build* function plus
-- an optional *manifest* function ("what invalidates a rebuild"); both
-- built-ins are implemented with exactly the interface custom builders get.
--
-- Manifest mechanics (images.md, "Caching"): a manifest serializes
-- canonically (keys sorted, one `k=v` per line) to
-- `<state_dir>/manifests/<slot>`; a stage runs when its manifest differs
-- from (or misses) the stored one, and the stored manifest is updated only
-- AFTER the stage succeeded — a failed run re-runs next time. `with.force`
-- bypasses all manifest checks.
--
-- Manifest inputs are structured (task 25): img.hash_spec(v) canonicalizes
-- a spec value (sorted keys — stable across runs; the format is private);
-- img.hash_file(path) hashes file content via makac.fs.sha256, hashing a
-- missing/unreadable file as its error string so a gone input rebuilds.
-- img.stage(ctx, ...) (also bound as ctx.stage inside builders) is the
-- per-stage runner custom builders opt into; qqmgr shape: one manifest
-- file per stage in the state dir. `changed` is true iff any stage ran
-- (builders that never call the stage runner always "changed").
--
-- State layout:
--   <state_dir>/image               the artifact (all builders produce this)
--   <state_dir>/manifests/build     the builder-level manifest
--   <state_dir>/manifests/<stage>   per-stage manifests (builders that use
--                                   img.stage — e.g. cloud-init)
--   default state_dir: makac.data_dir .. "/qemu/img/" .. with.name

local M = {}

local function fail(fmt, ...)
	error(("qemu:img: " .. fmt):format(...), 0)
end

--- Registry ------------------------------------------------------------

local builders = {} -- name -> { build = fn, manifest = fn? }

-- register_builder(name, build_fn, manifest_fn?): images.md, "Custom
-- builders". build(with, ctx) must produce ctx.state_dir .. "/image" and
-- return { path = <abs path> }; manifest(with, ctx) returns the input
-- table whose change invalidates the build. ctx carries state_dir, the
-- assembled env and an exec helper (raising on failure). Not exported
-- through the package system — workflow code require()s pkgs:qemu/img.
function M.register_builder(name, build_fn, manifest_fn)
	assert(type(name) == "string" and name ~= "",
		"qemu:img register_builder: the builder name must be a non-empty string")
	assert(type(build_fn) == "function",
		("qemu:img register_builder '%s': build must be a function"):format(name))
	assert(manifest_fn == nil or type(manifest_fn) == "function",
		("qemu:img register_builder '%s': the manifest must be a function"):format(name))
	builders[name] = { build = build_fn, manifest = manifest_fn }
end

--- Manifests -------------------------------------------------------------

-- serialize_manifest(manifest, who): canonical text form — keys sorted,
-- one `k=v` line each (Lua pairs order never leaks out, like
-- args.serialize).
local function serialize_manifest(manifest, who)
	local keys = {}
	for k in pairs(manifest) do
		if type(k) ~= "string" then
			fail("%s: manifest keys must be strings (got %s)", who, type(k))
		end
		keys[#keys + 1] = k
	end
	table.sort(keys)
	local lines = {}
	for _, k in ipairs(keys) do
		local v = manifest[k]
		local t = type(v)
		if t ~= "string" and t ~= "number" and t ~= "boolean" then
			fail("%s: manifest value '%s' must be a string, number or boolean, got %s",
				who, k, t)
		end
		lines[#lines + 1] = k .. "=" .. tostring(v)
	end
	return table.concat(lines, "\n") .. "\n"
end

local function manifest_path(state_dir, slot)
	return state_dir .. "/manifests/" .. slot
end

-- canonical_value / M.hash_spec: structured spec inputs (images.md,
-- "Caching"). lua's table iteration order varies per process (seeded
-- hash), so manifest equality needs a canonical form: objects serialize
-- with string keys sorted, arrays in order, strings %q-quoted — a
-- one-line, order-stable text. Two equal specs encode identically no
-- matter how the table was constructed.
local function canonical_value(v, why)
	local t = type(v)
	if t == "nil" then
		return "null"
	elseif t == "boolean" or t == "number" then
		if t == "number" and (v ~= v or v == math.huge or v == -math.huge) then
			fail("%s: manifest spec numbers must be finite", why)
		end
		return tostring(v)
	elseif t == "string" then
		return string.format("%q", v)
	elseif t == "table" then
		local n, max_i = 0, 0
		local saw_string, saw_index = false, false
		for k in pairs(v) do
			if type(k) == "string" then
				saw_string = true
			elseif type(k) == "number" and k >= 1 and k == math.floor(k) then
				saw_index = true
				if k > max_i then max_i = k end
			else
				fail("%s: manifest spec table keys must be strings or positive " ..
					"integer indexes (got %s)", why, type(k))
			end
			n = n + 1
		end
		if saw_string and saw_index then
			fail("%s: manifest spec tables are arrays OR maps, not both", why)
		end
		local parts = {}
		if saw_index then
			if max_i ~= n then
				fail("%s: manifest spec arrays must have no holes", why)
			end
			for i = 1, n do
				parts[#parts + 1] = canonical_value(v[i], why)
			end
			return "[" .. table.concat(parts, ",") .. "]"
		end
		local keys = {}
		for k in pairs(v) do keys[#keys + 1] = k end
		table.sort(keys)
		for _, k in ipairs(keys) do
			parts[#parts + 1] = string.format("%q", k) .. ":" .. canonical_value(v[k], why)
		end
		return "{" .. table.concat(parts, ",") .. "}"
	end
	fail("%s: manifest spec values of type '%s' cannot be hashed", why, t)
end

-- hash_spec(value): hash a spec input (a table of arbitrary shape, an
-- env, ...). Returns the canonical text; builders put the string into
-- their manifest tables.
function M.hash_spec(value, why)
	return canonical_value(value, why or "img.hash_spec")
end

-- hash_file(path): hash a file input via fs.sha256. A file that cannot
-- be read hashes as its error string — distinct from every real hash —
-- so "input file gone" counts as changed and rebuilds rather than
-- silently matching.
function M.hash_file(path)
	local hex, err = makac.fs.sha256(path)
	if hex == nil then
		return "error:" .. tostring(err)
	end
	return hex
end

-- stage(ctx, name, manifest, run): the per-stage cache. Returns true when
-- the stage ran. The stored manifest updates only after a successful run.
-- Stage accounting lives on ctx so M.build can report changed = "any
-- stage ran" for builders that don't self-report.
function M.stage(ctx, stage_name, manifest, run)
	assert(type(stage_name) == "string" and stage_name ~= "" and not stage_name:find("/", 1, true),
		"qemu:img stage: the stage name must be a simple non-empty word")
	ctx._stages_used = (ctx._stages_used or 0) + 1
	local text = serialize_manifest(manifest,
		("image '%s' stage '%s'"):format(ctx.name, stage_name))
	local path = manifest_path(ctx.state_dir, stage_name)
	if not ctx.force and makac.fs.read_file(path) == text then
		return false -- manifest match: skipped (images.md, "Caching")
	end
	run(ctx)
	ctx._stages_ran = (ctx._stages_ran or 0) + 1
	makac.fs.write_file(path, text, { atomic = true })
	return true
end

--- Env -------------------------------------------------------------------

-- assemble_env(with): images.md, "The environment and env_hook": start
-- from with.env, then let with.env_hook transform it; the result is the
-- environment builders (cloud-init templates most visibly) work with.
local function assemble_env(with)
	local env = {}
	for k, v in pairs(with.env or {}) do
		assert(type(k) == "string",
			"qemu:img: with.env keys must be strings")
		local t = type(v)
		assert(t == "string" or t == "number" or t == "boolean",
			("qemu:img: with.env.%s must be a string, number or boolean, got %s"):format(k, t))
		env[k] = v
	end
	if with.env_hook ~= nil then
		assert(type(with.env_hook) == "function",
			"qemu:img: with.env_hook must be a function(env) -> env")
		env = with.env_hook(env)
		assert(type(env) == "table",
			"qemu:img: with.env_hook must return the env table")
	end
	return env
end

--- ctx.exec ----------------------------------------------------------------

-- exec helper on ctx: runs argv via makac.exec (PATH lookup; qemu-img /
-- genisoimage are invoked by name, qqmgr precedent). Non-zero exit is a
-- build failure quoting the command and stderr.
local function make_exec(name)
	return function(argv)
		assert(type(argv) == "table" and type(argv[1]) == "string" and argv[1] ~= "",
			("qemu:img: image '%s': exec takes an argv array (program first)"):format(name))
		local ok, res = pcall(makac.exec, argv)
		if not ok then
			fail("image '%s': cannot run %s (on PATH?): %s", name, argv[1], tostring(res))
		end
		if res.code ~= 0 then
			local why = type(res.stderr) == "string" and (res.stderr:gsub("%s+$", "")) or ""
			local shown = {}
			for i, a in ipairs(argv) do shown[#shown + 1] = a end
			fail("image '%s': command failed (exit %d): %s\n%s",
				name, res.code, table.concat(shown, " "), why)
		end
		return res
	end
end

--- Builder resolution ------------------------------------------------------

-- with.builder: a registered name OR a function (images.md, "`with.builder`:
-- a name or a function"); a function pairs with with.builder_manifest.
local function resolve_builder(with)
	local b = with.builder
	if type(b) == "function" then
		if with.builder_manifest ~= nil then
			assert(type(with.builder_manifest) == "function",
				"qemu:img: with.builder_manifest must be a function(with, ctx) -> table")
		end
		return b, with.builder_manifest
	end
	if type(b) ~= "string" or b == "" then
		fail("image '%s': 'with.builder' must be a builder name or a function, got %s",
			tostring(with.name), type(b))
	end
	local entry = builders[b]
	if entry == nil then
		local names = {}
		for n in pairs(builders) do names[#names + 1] = n end
		table.sort(names)
		if #names == 0 then names[1] = "(none registered)" end
		fail("image '%s': unknown builder %q (registered: %s)",
			with.name, b, table.concat(names, ", "))
	end
	return entry.build, entry.manifest
end

--- The qemu:img action -----------------------------------------------------

local function absolute(p)
	assert(type(p) == "string" and p ~= "", "qemu:img: state_dir must be a non-empty path")
	if p:sub(1, 1) ~= "/" then
		p = tostring(makac.fs.cwd():path()) .. "/" .. p
	end
	return tostring(makac.fs.path(p))
end

-- build(with) -> { changed, out = { path = ... } }: the qemu:img action
-- (images.md). Every builder returns out = { path = <abs path to the
-- image> } and changed = true iff any stage ran.
local defaulted_changed -- defined below
function M.build(with)
	assert(type(with) == "table", "qemu:img: the step's 'with' table is required")
	if type(with.name) ~= "string" or with.name == "" then
		fail("'with.name' (identity & state-dir key) must be a non-empty string")
	end
	assert(makac.data_dir ~= nil, "qemu:img: makac.data_dir is not set")
	local state_dir = with.state_dir or (makac.data_dir .. "/qemu/img/" .. with.name)
	state_dir = absolute(state_dir)

	-- state root up front: a build never leaves its first bytes homeless
	makac.fs.mkdir_p(state_dir)
	makac.fs.mkdir_p(state_dir .. "/manifests")

	local build_fn, manifest_fn = resolve_builder(with)
	local ctx = {
		name = with.name,
		state_dir = state_dir,
		env = assemble_env(with),
		force = with.force == true,
		exec = make_exec(with.name),
	}
	-- ctx.stage: the per-stage cache, available without an extra require so
	-- custom builders opt into caching the same way the built-ins do
	ctx.stage = function(stage_name, manifest, run)
		return M.stage(ctx, stage_name, manifest, run)
	end
	local expect_path = state_dir .. "/image" -- the artifact, by convention

	-- Builder-level caching (a single implicit stage around the whole
	-- build; builders want finer caching use img.stage inside). A match
	-- only counts when the artifact is still there — a deleted image
	-- rebuilds no matter what the manifest says.
	if manifest_fn ~= nil then
		local manifest = manifest_fn(with, ctx)
		assert(type(manifest) == "table",
			("qemu:img: image '%s': the manifest function must return a table"):format(with.name))
		local text = serialize_manifest(manifest, ("image '%s'"):format(with.name))
		if not ctx.force
			and makac.fs.read_file(manifest_path(state_dir, "build")) == text
			and makac.fs.stat(expect_path) ~= nil then
			return { changed = false, out = { path = expect_path } }
		end
		local result, changed = M.run_build(with, build_fn, ctx)
		makac.fs.write_file(manifest_path(state_dir, "build"), text, { atomic = true })
		return { changed = defaulted_changed(ctx, changed), out = { path = result } }
	end

	-- no manifest: runs every time (images.md); a builder that does its
	-- own per-stage caching reports through result.changed.
	local result, changed = M.run_build(with, build_fn, ctx)
	return { changed = defaulted_changed(ctx, changed), out = { path = result } }
end

-- defaulted_changed: when a builder doesn't self-report changed, fall
-- back to the stage accounting — changed iff any stage ran (images.md,
-- "changed = true iff any stage ran"); a builder that never used the
-- stage runner ran unconditionally, so it changed.
local function defaulted_changed_fn(ctx, changed)
	if changed ~= nil then return changed end
	return (ctx._stages_used or 0) == 0 or (ctx._stages_ran or 0) > 0
end
defaulted_changed = defaulted_changed_fn

-- run_build: call the builder and validate its artifact. Returns the
-- absolute image path and the builder's changed flag (nil = not reported).
function M.run_build(with, build_fn, ctx)
	local result = build_fn(with, ctx)
	assert(type(result) == "table",
		("qemu:img: image '%s': the builder must return { path = ... }"):format(with.name))
	local path = result.path
	if type(path) == "userdata" then
		path = tostring(path) -- a makac path
	end
	if type(path) ~= "string" or path == "" then
		fail("image '%s': the builder returned a bad path (%s)", with.name, tostring(result.path))
	end
	if makac.fs.stat(path) == nil then
		fail("image '%s': the builder returned %s, but no file is there",
			with.name, path)
	end
	return path, result.changed
end

--- Built-in builder: raw ---------------------------------------------------
--
-- Empty disk images (images.md): keys img_size = "1G", format = "raw"
-- (default). One stage: qemu-img create under a manifest of
-- name/size/format.

M.register_builder("raw",
	function(with, ctx)
		if type(with.img_size) ~= "string" or with.img_size == "" then
			fail("image '%s': builder 'raw' needs with.img_size (e.g. \"1G\")", ctx.name)
		end
		local format = "raw"
		if with.format ~= nil then
			assert(type(with.format) == "string" and with.format ~= "",
				("qemu:img: image '%s': with.format must be a non-empty string"):format(ctx.name))
			format = with.format
		end
		local path = ctx.state_dir .. "/image"
		os.remove(path) -- qemu-img refuses to overwrite some formats; a build is a fresh artifact
		ctx.exec({ "qemu-img", "create", "-f", format, path, with.img_size })
		return { path = path }
	end,
	function(with, ctx)
		return {
			name = ctx.name,
			size = with.img_size,
			format = with.format or "raw",
		}
	end)

--- Built-in builder: cloud-init --------------------------------------------
--
-- A customized OS image from a stock cloud image, in five stages
-- (images.md, "Builder `cloud-init`"). Per-stage manifests via img.stage;
-- no builder-level manifest (the builder reports changed through
-- result.changed).
--
-- State layout:
--   <state_dir>/base.img          resized pristine copy of the base
--   <state_dir>/image             the working overlay (the artifact)
--   <state_dir>/<output>          rendered templates (user-data, ...)
--   <state_dir>/cloud-init.iso    the cidata ISO
--   <state_dir>/serial.log        the customize VM's serial console
--   <state_dir>/qemu-stderr.log   the customize VM's stderr

local arglib = require("pkgs:qemu/args")

-- render_template(env, text): the one rule (images.md, "Templates"):
-- `{{ name }}` expands to env[name]; a name absent from the env is a spec
-- error naming it. `why` names the image/template for that error.
local function render_template(env, text, why)
	return (text:gsub("{{%s*([%w_][%w_.-]*)%s*}}", function(name)
		local v = env[name]
		if v == nil then
			fail("%s: the template references '{{ %s }}' but the env has no such name", why, name)
		end
		local t = type(v)
		if t ~= "string" and t ~= "number" and t ~= "boolean" then
			fail("%s: env.%s is a %s — templates expand strings/numbers/booleans", why, name, t)
		end
		return tostring(v)
	end))
end

	-- the builder hashes its inputs with the shared structured-input
	-- helpers (M.hash_file / M.hash_spec), same as any custom builder

-- tail_text(path, max): the last ~max bytes of a log (serial logs can
-- spew); quoted into stage-failure messages.
local function tail_text(path, max)
	local text = makac.fs.read_file(path)
	if text == nil then return "(no " .. tostring(path) .. ")" end
	if #text > max then
		text = "... (" .. (#text - max) .. " bytes elided) ...\n" .. text:sub(#text - max + 1)
	end
	return text
end

local function cloud_init_build(with, ctx)
	-- validate the required keys up front (images.md)
	local name = ctx.name
	local function need(key)
		if with[key] == nil then
			fail("image '%s': builder 'cloud-init' needs with.%s", name, key)
		end
		return with[key]
	end
	local img_size = need("img_size")
		assert(type(img_size) == "string" and img_size ~= "",
			("qemu:img: image '%s': with.img_size must be a size string (e.g. \"10G\")"):format(name))
	local qemu_bin = need("qemu_bin")
		assert(type(qemu_bin) == "string" and qemu_bin ~= "",
			("qemu:img: image '%s': with.qemu_bin must name the qemu binary"):format(name))
	local base_img = need("base_img")
		assert(type(base_img) == "table"
			and type(base_img.url) == "string" and base_img.url ~= ""
			and type(base_img.sha256) == "string" and base_img.sha256 ~= "",
			("qemu:img: image '%s': with.base_img must be { url =, sha256 = }"):format(name))
	local build_args = need("build_args")
		assert(type(build_args) == "table" and #build_args > 0,
			("qemu:img: image '%s': with.build_args is the command line of the throwaway VM " ..
				"(flattened exactly as qemu:vm's `args`)"):format(name))
	local templates = need("templates")
		assert(type(templates) == "table" and #templates >= 2,
			("qemu:img: image '%s': with.templates needs at minimum user-data and meta-data"):format(name))
	local seen_out = {}
	for i, t in ipairs(templates) do
		assert(type(t) == "table"
			and type(t.template) == "string" and t.template ~= ""
			and type(t.output) == "string" and t.output ~= "",
			("qemu:img: image '%s': templates[%d] must be { template = <file>, output = <name> }")
				:format(name, i))
		seen_out[t.output] = true
	end
	assert(seen_out["user-data"] and seen_out["meta-data"],
		("qemu:img: image '%s': with.templates must render a user-data and a meta-data"):format(name))
	local timeout_s = with.timeout_s or 600
	assert(type(timeout_s) == "number" and timeout_s > 0,
		("qemu:img: image '%s': with.timeout_s must be a positive number"):format(name))
	-- live build output: `with.verbose = true` (or MAKAC_IMG_VERBOSE in
	-- the environment) streams the customize VM's serial console while it
	-- boots/installs/powers off (stage 5 follows the log file; the VM
	-- itself stays on files-per-stdio, launch.md).
	local verbose = with.verbose
	if verbose == nil then
		verbose = os.getenv("MAKAC_IMG_VERBOSE") ~= nil
	end
	assert(type(verbose) == "boolean",
		("qemu:img: image '%s': with.verbose must be a boolean"):format(name))

	local sd = ctx.state_dir
	local image_path = sd .. "/image"
	local base_resized = sd .. "/base.img"
	local iso_path = sd .. "/cloud-init.iso"
	local serial_log = sd .. "/serial.log"
	local stderr_log = sd .. "/qemu-stderr.log"

	local changed = false
	local function stage(stage_name, manifest, run)
		if M.stage(ctx, stage_name, manifest, run) then changed = true end
	end

	-- stage 1: download — content-cached (two builds naming the same
	-- url+sha256 share one download); the stage manifest records which
	-- base this image consumed.
	stage("1-download", { url = base_img.url, sha256 = base_img.sha256 }, function() end)
	local ok, base_path = pcall(makac.download, base_img.url, base_img.sha256)
	if not ok then
		fail("image '%s': failed to download base image %s: %s", name, base_img.url, tostring(base_path))
	end
	base_path = tostring(base_path)

	-- stage 2: prepare — copy the base, resize, create the working overlay
	-- (manifest: base content + img_size)
	stage("2-prepare", { base = M.hash_file(base_path), img_size = img_size }, function()
		local ok2, err2 = pcall(function()
			ctx.exec({ "cp", "--", base_path, base_resized })
			ctx.exec({ "qemu-img", "resize", base_resized, img_size })
			os.remove(image_path)
			ctx.exec({ "qemu-img", "create", "-f", "qcow2", "-F", "qcow2",
				"-b", base_resized, image_path })
		end)
		if not ok2 then error(err2, 0) end
	end)

	-- stage 3: templates — render each entry with the env into the state
	-- dir (manifest: the env + each template's content)
	local tmanifest = { env = M.hash_spec(ctx.env, ("image '%s'"):format(name)) }
	for _, t in ipairs(templates) do
		local tpath = t.template
		if tpath:sub(1, 1) ~= "/" then
			tpath = tostring(makac.fs.cwd():path()) .. "/" .. tpath
		end
		local text, terr = makac.fs.read_file(tpath)
		if text == nil then
			fail("image '%s': cannot read template %s: %s", name, tpath, tostring(terr))
		end
		tmanifest["template:" .. t.template] = M.hash_file(tpath)
	end
	stage("3-templates", tmanifest, function()
		for _, t in ipairs(templates) do
			local tpath = t.template
			if tpath:sub(1, 1) ~= "/" then
				tpath = tostring(makac.fs.cwd():path()) .. "/" .. tpath
			end
			local text = assert(makac.fs.read_file(tpath))
			local rendered = render_template(ctx.env, text,
				("image '%s' template '%s'"):format(name, t.template))
			makac.fs.write_file(sd .. "/" .. t.output, rendered)
		end
	end)

	-- stage 4: iso — genisoimage from the rendered templates + `sources`
	-- (manifest: the rendered files' content); sources are { url=, sha256=,
	-- filename= } downloads grafted straight from the download cache
	local imanifest = {}
	for _, t in ipairs(templates) do
		imanifest[t.output] = M.hash_file(sd .. "/" .. t.output)
	end
	local sources = with.sources or {}
	assert(type(sources) == "table",
		("qemu:img: image '%s': with.sources must be an array of { url=, sha256=, filename= }"):format(name))
	local grafts = {}
	for _, t in ipairs(templates) do
		grafts[#grafts + 1] = { name = t.output, path = sd .. "/" .. t.output }
	end
	for i, s in ipairs(sources) do
		assert(type(s) == "table"
			and type(s.url) == "string" and type(s.sha256) == "string"
			and type(s.filename) == "string",
			("qemu:img: image '%s': sources[%d] must be { url=, sha256=, filename= }"):format(name, i))
		local ok3, spath = pcall(makac.download, s.url, s.sha256)
		if not ok3 then
			fail("image '%s': failed to download source %s: %s", name, s.url, tostring(spath))
		end
		imanifest[s.filename] = s.sha256
		grafts[#grafts + 1] = { name = s.filename, path = tostring(spath) }
	end
	stage("4-iso", imanifest, function()
		local argv = { "genisoimage", "-output", iso_path, "-volid", "cidata",
			"-joliet", "-input-charset", "utf-8", "-graft-points" }
		for _, g in ipairs(grafts) do
			argv[#argv + 1] = g.name .. "=" .. g.path
		end
		os.remove(iso_path)
		ctx.exec(argv)
	end)

	-- stage 5: customize — boot the throwaway VM, wait for it to power
	-- itself off (manifest: build_args + iso content). `{{ img_self }}`
	-- and `{{ cloud_init_iso }}` substitute inside build_args; the serial
	-- console and qemu stderr are captured to the state dir per contract.
	local words = arglib.flatten(build_args)
	for i, wd in ipairs(words) do
		words[i] = (wd
			:gsub("{{%s*img_self%s*}}", function() return image_path end)
			:gsub("{{%s*cloud_init_iso%s*}}", function() return iso_path end))
	end
	local vmanifest = { build_args = table.concat(words, "\n"), iso = M.hash_file(iso_path) }
	stage("5-customize", vmanifest, function()
		os.remove(serial_log)
		os.remove(stderr_log)
		local argv = { qemu_bin }
		for _, wd in ipairs(words) do argv[#argv + 1] = wd end
		argv[#argv + 1] = "-display"
		argv[#argv + 1] = "none"
		argv[#argv + 1] = "-serial"
		argv[#argv + 1] = "file:" .. serial_log
		local ok4, proc = pcall(makac.spawn, argv, {
			stdout = tostring(makac.fs.null_file()),
			stderr = stderr_log,
		}) 
		if not ok4 then
			fail("image '%s': cannot start the customize VM (%s): %s", name, qemu_bin, tostring(proc))
		end

		local t = makac.time
		local deadline = t.now() + math.floor(timeout_s * t.ns_per_s)
		local function quote_logs()
			return ("serial log (%s):\n%s\nqemu-stderr (%s):\n%s")
				:format(serial_log, tail_text(serial_log, 16384),
					stderr_log, tail_text(stderr_log, 16384))
		end
		-- verbose: follow the serial console as it lands. The file is
		-- truncated per stage run and append-only afterwards, so a plain
		-- offset suffices (a restart recreates it, never shrinks it).
		local seen = 0
		local function follow()
			if not verbose then return end
			local text = makac.fs.read_file(serial_log)
			if text ~= nil and #text > seen then
				io.write(text:sub(seen + 1))
				seen = #text
			end
		end
		while true do
			follow()
			local st = proc:status()
			if st ~= "running" then
				if st.code ~= 0 then
					fail("image '%s': the customize VM exited abnormally (code %d) — the VM must " ..
						"power itself off (cloud-init user-data ends with `poweroff:`)\n%s",
						name, st.code, quote_logs())
				end
				break
			end
			if t.now() > deadline then
				pcall(makac.exec, { "kill", tostring(proc.pid) })
				t.sleep(200 * t.ns_per_ms)
				if makac.pid_alive(proc.pid) then
					pcall(makac.exec, { "kill", "-9", tostring(proc.pid) })
					t.sleep(100 * t.ns_per_ms)
				end
				fail("image '%s': the customize VM timed out after %ds waiting for it to power " ..
					"itself off\n%s", name, timeout_s, quote_logs())
			end
			t.sleep(50 * t.ns_per_ms)
		end
		follow() -- last bytes between the final poll and poweroff
	end)

	return { path = image_path, changed = changed }
end

M.register_builder("cloud-init", cloud_init_build)

return M
