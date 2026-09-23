-- pkgs/qemu/args (internal) — flattening and canonical serialization of a
-- VM's `args` into a QEMU argument vector (design/vm.md, "`args`: an argv
-- array", "Auto-injected runtime arguments", "Invocation identity",
-- "Overlay boot disks").
--
--   args        = a list of words in any of the composable shapes below.
--   flatten()   -> { word, ... }           one flat argv
--   serialize() -> "k=v,...,flag"          one assoc table -> one word
--   canonical_invocation(bin, args) -> the verbatim text form that decides
--                 invocation identity (written to <run_dir>/invocation)
--   check_reserved(args)                   spec-error on auto-injected words
--   substitute(args, { disk = path })      `{{ disk }}` substitution
--
-- Flattening rules (vm.md, verbatim): strings pass through; list-like
-- tables flatten depth-first; functions are called (no arguments) and
-- their return flattens recursively; nil/false elements drop; anything
-- else is a spec error naming its path in the tree (args[3][2]).
--
-- Associative tables serialize to ONE comma-joined QEMU property word,
-- canonically: keys sort lexically, `k=v` joined with `,`, a `true` value
-- is the bare flag, strings/numbers pass as-is; anything else is a spec
-- error. Lua `pairs` order never leaks out.

local M = {}

-- Words the package injects itself (pidfile/sockets/serial): authoring
-- them in `args` is a spec error naming the conflicting word.
local RESERVED = {
	["-pidfile"] = true,
	["-monitor"] = true,
	["-serial"] = true,
	["-qmp"] = true,
}

local function fail(fmt, ...)
	error(("qemu:vm args: " .. fmt):format(...), 0)
end

-- serialize(tbl, path): associative table -> one canonical property word.
-- Exported so tests (and other package modules) can use it directly.
function M.serialize(tbl, path)
	path = path or "props"
	local keys = {}
	for k in pairs(tbl) do
		local kt = type(k)
		if kt ~= "string" then
			fail("bad key at %s: expected string keys (got %s %s); an associative table serializes to one property word",
				path, kt, tostring(k))
		end
		keys[#keys + 1] = k
	end
	table.sort(keys) -- canonical: lexical order, independent of pairs order
	local parts = {}
	for _, k in ipairs(keys) do
		local v = tbl[k]
		if v == true then
			parts[#parts + 1] = k -- bare flag
		elseif type(v) == "string" then
			parts[#parts + 1] = k .. "=" .. v
		elseif type(v) == "number" then
			parts[#parts + 1] = k .. "=" .. tostring(v)
		else
			fail("value for '%s' (%s.%s) must be a string, a number or true (got %s)",
				k, path, k, type(v))
		end
	end
	return table.concat(parts, ",")
end

-- Flatten one element at path into out.
local function push(el, path, out)
	if el == nil or el == false then
		return -- elements drop
	end
	local t = type(el)
	if t == "string" then
		out[#out + 1] = el
		return
	end
	if t == "function" then
		push(el(), path, out) -- called with no arguments; return flattens recursively
		return
	end
	if t == "table" then
		local has_str = false
		local indices = {}
		for k in pairs(el) do
			local kt = type(k)
			if kt == "string" then
				has_str = true
			elseif kt == "number" and k >= 1 and k == math.floor(k) then
				indices[#indices + 1] = k
			else
				fail("bad key %s at %s: list keys must be positive integers",
					tostring(k), path)
			end
		end
		if has_str then
			if #indices > 0 then
				fail("mixed table at %s: a table is either an argv list or a property table (string keys), not both",
					path)
			end
			out[#out + 1] = M.serialize(el, path)
			return
		end
		-- list-like: flatten depth-first, in index order; iterate the key
		-- set rather than 1..#el so a nil hole DROPS instead of truncating
		table.sort(indices)
		for _, i in ipairs(indices) do
			push(el[i], ("%s[%d]"):format(path, i), out)
		end
		return
	end
	fail("bad element at %s: expected a string, list, property table or function (got %s)",
		path, t)
end

-- flatten(args) -> { word, ... }: the flat argv. A nil/false root flattens
-- to nothing; a function root is called.
function M.flatten(args)
	local out = {}
	push(args, "args", out)
	return out
end

-- canonical_invocation(qemu_bin, args) -> string: the verbatim text form
-- of an invocation — qemu_bin as given, followed by the flattened args,
-- one word per line. Newline separation is a faithful argv rendering (a
-- word containing a newline is rejected as unrepresentable) and makes
-- "different invocation" failures diffable (vm.md, "Invocation identity").
function M.canonical_invocation(qemu_bin, args)
	if type(qemu_bin) ~= "string" or qemu_bin == "" then
		fail("canonical_invocation: qemu_bin must be a non-empty string (got %s)",
			type(qemu_bin))
	end
	local lines = { qemu_bin }
	for _, w in ipairs(M.flatten(args)) do
		lines[#lines + 1] = w
	end
	for _, w in ipairs(lines) do
		if w:find("\n", 1, true) then
			fail("canonical_invocation: word %q contains a newline and cannot be represented in the canonical form",
				w)
		end
	end
	return table.concat(lines, "\n")
end

-- check_reserved(args): supplying a word the package auto-injects
-- (vm.md, "Auto-injected runtime arguments") is a spec error naming the
-- conflicting word. Accepts raw args or an already-flattened word list.
function M.check_reserved(args)
	for _, w in ipairs(M.flatten(args)) do
		if RESERVED[w] then
			fail("'%s' must not appear in args: the package injects it itself (it is part of the runtime directory wiring)",
				w)
		end
	end
end

-- substitute(args, { disk = path }) -> { word, ... }: replace `{{ disk }}`
-- in the flattened words. `{{ disk }}` is the ONLY substitution available
-- in VM args (vm.md, "Overlay boot disks"); using it with no disk given is
-- a spec error. Accepts raw args or an already-flattened word list.
function M.substitute(args, vars)
	local disk = vars and vars.disk
	local out = {}
	for _, w in ipairs(M.flatten(args)) do
		if w:find("{{ disk }}", 1, true) then
			if disk == nil then
				fail("word %q uses {{ disk }} but no `disk` was given", w)
			end
			w = (w:gsub("{{ disk }}", tostring(disk)))
		end
		out[#out + 1] = w
	end
	return out
end

return M
