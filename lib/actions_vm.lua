-- pkgs:qemu/actions_vm — internal implementations of the qemu:vm,
-- qemu:loadvm and qemu:probe actions (design/vm.md, "Start semantics"/
-- "Stop semantics"/"SSH defaults"/"The ssh target"/"Overlay boot disks";
-- design/launch.md, which this file follows near-verbatim; handle.md
-- "Status probing" for qemu:probe).
--
-- Choreography notes (launch.md):
--   * detached launch: makac.spawn with stdio to FILES, never pipes; the
--     process is not a child makac waits on.
--   * the launch window polls p:status() BEFORE the qmp socket each
--     iteration: a racing exit + a leftover socket file from a previous
--     run must not spell success.
--   * the process object is never reaped/re-polled after the window: if
--     the VM dies mid-workflow it is a zombie until makac exits and init
--     reaps it. That is intentional (launch.md) — do not "fix" it by
--     adding a reaper.
--   * p.pid answers the pidfile: we write <run_dir>/pid from it
--     (atomically), the way QEMU's own -pidfile would. probe() never
--     consults the process object — it does not survive the run.

local handlelib = require("pkgs:qemu/handle")
local argslib = require("pkgs:qemu/args")

local M = {}

local LAUNCH_WINDOW_S = 5

local function fail(action, fmt, ...)
	error(("qemu:%s: " .. fmt):format(action, ...), 0)
end

-- vm_arg(action, with) -> handle: with.vm is a VM name (string) or a
-- previous out.handle (table) — one key, either value, exactly like the
-- qmp actions' with.vm — plus the optional with.run_dir override
-- (handle.md's derivation rule).
local function vm_arg(action, with)
	local ident = with.vm
	if ident == nil then
		fail(action, "'with.vm' is required: a VM name (string) or a previous out.handle (table)")
	end
	return handlelib.resolve(ident, with.run_dir)
end

-- tail(path, n): the last n lines of a log file, for failure messages —
-- a shell-out to tail(1) via makac.exec (launch.md), not a primitive.
local function tail(path, n)
	local res = makac.exec({ "tail", "-n", tostring(n), path })
	if res.code ~= 0 then
		return ("<could not read log: %s>"):format(((res.stderr or ""):gsub("%s+$", "")))
	end
	return res.stdout or ""
end

-- The invocation file holds the CANONICAL form verbatim, byte-compared
-- (vm.md, "Invocation identity"). No whitespace tolerance.
local function read_invocation_verbatim(h)
	return makac.fs.read_file(h.run_dir .. "/invocation")
end

-- ensure_qmp(h): this handle's connection through the registry; attach on
-- demand when missing (handle.md, "The QMP connection"; launch.md's stop).
local function ensure_qmp(action, h)
	local c = handlelib.qmp_of(h)
	if c ~= nil then
		return c
	end
	local ok, client = pcall(makac.qmp_open, { socket = h.qmp_socket, timeout_s = 5 })
	if not ok then
		fail(action, "VM '%s': cannot connect to QMP socket %s: %s",
			h.name, h.qmp_socket, tostring(client))
	end
	return handlelib.attach_qmp(h, client)
end

-- resolve_ssh(h, ssh): with.ssh key fallbacks, each independently
-- (vm.md, "SSH defaults"): the with key, then the workflow's global
-- (VM_SSH_*), then the built-in default — read at step-evaluation time
-- (i.e. here, inside the action).
local function resolve_ssh(action, h, ssh)
	if ssh == nil then
		return nil
	end
	if type(ssh) ~= "table" then
		fail(action, "VM '%s': 'with.ssh' must be a table, got %s", h.name, type(ssh))
	end
	local port = ssh.port
	if port == nil then
		port = VM_SSH_PORT -- global: no built-in default
	end
	if port == nil then
		fail(action, "VM '%s': with.ssh has no port and neither does VM_SSH_PORT: 'with.ssh.port' is required (it is the HOST-assigned port; the target connects to 127.0.0.1:port)",
			h.name)
	end
	if type(port) ~= "number" or port ~= math.floor(port) or port < 1 or port > 65535 then
		fail(action, "VM '%s': with.ssh.port must be an integer in [1;65535], got %s",
			h.name, tostring(port))
	end
	local user = ssh.user
	if user == nil then
		user = VM_SSH_USER -- global
	end
	if user == nil then
		user = "root" -- built-in default
	end
	if type(user) ~= "string" or user == "" then
		fail(action, "VM '%s': with.ssh.user must be a non-empty string, got %s",
			h.name, tostring(user))
	end
	local identity_file = ssh.identity_file
	if identity_file == nil then
		identity_file = VM_SSH_IDENTITY_FILE -- global; built-in default: none
	end
	if identity_file ~= nil and (type(identity_file) ~= "string" or identity_file == "") then
		fail(action, "VM '%s': with.ssh.identity_file must be a non-empty string, got %s",
			h.name, tostring(identity_file))
	end
	-- extra ssh -o options (string keys -> string/number/bool values;
	-- passed through to the ssh config). An explicit option key wins over
	-- the typed identity_file mapping.
	local options
	if ssh.options ~= nil then
		if type(ssh.options) ~= "table" then
			fail(action, "VM '%s': with.ssh.options must be a table, got %s", h.name, type(ssh.options))
		end
		options = {}
		for k, v in pairs(ssh.options) do
			if type(k) ~= "string" then
				fail(action, "VM '%s': with.ssh.options keys must be strings, got %s",
					h.name, type(k))
			end
			options[k] = v
		end
	end
	if identity_file ~= nil then
		options = options or {}
		if options.IdentityFile == nil then
			options.IdentityFile = identity_file
		end
	end
	if options ~= nil and next(options) == nil then
		options = nil
	end
	return { port = port, user = user, options = options }
end

-- resolve_disk(action, h, disk): with.disk validation (vm.md, "Overlay
-- boot disks"). Returns nil or { backing = <abs path>, path = <abs path> }.
-- `backing` is the base image (never written); `path` is where the overlay
-- is created. Defaults to <run_dir>/disk.qcow2 (the throwaway overlay the
-- VM boots onto); a workflow-supplied `path` lands the overlay at a file
-- the caller controls, so a savevm baked into it can outlive the run dir.
-- The canonical invocation records `backing` only (vm.md: a rebuilt image
-- at the same path does not invalidate a running VM).
local function resolve_disk(action, h, disk)
	if disk == nil then
		return nil
	end
	if type(disk) ~= "table" then
		fail(action, "VM '%s': 'with.disk' must be a table { backing = <image path>, path = <overlay path>? }, got %s",
			h.name, type(disk))
	end
	local backing = disk.backing
	if type(backing) == "userdata" then
		backing = tostring(backing) -- a makac path (e.g. img.out.path)
	end
	if type(backing) ~= "string" or backing == "" then
		fail(action, "VM '%s': 'with.disk.backing' (the base image, never written) must be a non-empty path, got %s",
			h.name, tostring(disk.backing))
	end
	if backing:sub(1, 1) ~= "/" then
		backing = tostring(makac.fs.cwd():path()) .. "/" .. backing
	end
	if makac.fs.stat(backing) == nil then
		fail(action, "VM '%s': with.disk.backing does not exist: %s", h.name, backing)
	end
	-- the overlay path: defaults to the run-dir overlay. A user-supplied
	-- `path` may be relative — anchored to <run_dir>, like the default —
	-- or absolute, putting the overlay anywhere the caller wants. The
	-- default location is `<run_dir>/disk.qcow2`; a relative `path` of
	-- "my-disk.qcow2" lands at `<run_dir>/my-disk.qcow2`. Either way, the
	-- overlay is package-managed: cleanup_runtime_files leaves it alone
	-- on a loadvm restart (keep_overlay) and removes it on a qemu:vm stop.
	-- An absolute path puts the disk OUTSIDE the run dir — entirely
	-- caller-managed (cleanup never touches files outside <run_dir>) —
	-- which is the live-disk pattern: a savevm baked into a file the
	-- caller owns.
	local path = disk.path
	if path == nil then
		path = h.disk_overlay
	else
		if type(path) == "userdata" then
			path = tostring(path)
		end
		if type(path) ~= "string" or path == "" then
			fail(action, "VM '%s': 'with.disk.path' (where to create the overlay) must be a non-empty path, got %s",
				h.name, tostring(disk.path))
		end
		if path:sub(1, 1) ~= "/" then
			-- relative: anchored at <run_dir>, the same place the default
			-- lives (handle.lua: disk_overlay = run_dir .. "/disk.qcow2")
			path = h.run_dir .. "/" .. path
		end
		-- create the parent dir as needed: `qemu-img create` would fail on
		-- a missing parent with "could not create file", less helpful than
		-- surfacing it here
		local parent = path:match("^(.*)/[^/]*$")
		if parent and parent ~= "" then
			makac.fs.mkdir_p(parent)
		end
	end
	return { backing = backing, path = path }
end

-- create_overlay(action, h, disk): the qcow2 overlay the VM boots onto
-- (vm.md): `qemu-img create -f qcow2 -b <backing> -F qcow2 <disk.path>`.
-- The path defaults to <run_dir>/disk.qcow2; a workflow-supplied
-- `with.disk.path` lands it elsewhere (a savevm baked into the file then
-- outlives the run dir — exactly the live-disk pattern). Every fresh
-- START recreates the overlay (a boot consumes it); the exception is a
-- restart resumed by qemu:loadvm (snapshots.md), which keeps the existing
-- one — the snapshot lives IN it. os.remove first so a leftover from a
-- crashed stop cannot masquerade as pristine.
local function create_overlay(action, h, disk)
	os.remove(disk.path)
	local ok, res = pcall(makac.exec, {
		"qemu-img", "create",
		"-f", "qcow2",
		"-b", disk.backing,
		"-F", "qcow2",
		disk.path,
	})
	if not ok then
		fail(action, "VM '%s': cannot run qemu-img (on PATH?): %s", h.name, tostring(res))
	end
	if res.code ~= 0 then
		local why = type(res.stderr) == "string" and (res.stderr:gsub("%s+$", "")) or ""
		fail(action, "VM '%s': qemu-img create failed for overlay %s (backing %s) — qemu-img said: %s",
			h.name, disk.path, disk.backing, why)
	end
end

-- ensure_target(action, h, ssh): the VM's makac remote target (vm.md, "The ssh
-- target"): 127.0.0.1 + the configured port/user/options, named after the
-- VM. One per handle per run; makac's runner closes live targets at
-- workflow end, qemu:vm stopped closes it as part of teardown.
local function ensure_target(action, h, ssh)
	local t = handlelib.target_of(h)
	if t ~= nil then
		return t
	end
	local ok, t_or_err = pcall(makac.new_ssh_target, h.name, {
		host = "127.0.0.1",
		port = ssh.port,
		user = ssh.user,
		options = ssh.options,
	})
	if not ok then
		fail(action, "VM '%s': could not set up the ssh target: %s", h.name, tostring(t_or_err))
	end
	handlelib.attach_target(h, t_or_err)
	return t_or_err
end

-- wait_for_ssh(action, h, target, ssh, with): vm.md step 5 — poll ssh until a
-- trivial command runs, up to timeout_s (default 120, poll every
-- interval_s (default 2)); timeout is a step failure naming the serial
-- log.
-- NOTE: target:run RETURNS { code = 255, ... } on connection failure (it
-- only raises on closed/misuse), so the poll checks res.code, not just
-- pcall — a plain pcall would mistake an unreachable VM for a success.
local function wait_for_ssh(action, h, target, ssh, with)
	local ws = with.wait_ssh
	if ws == nil or ws == true then
		ws = {} -- defaults apply
	elseif ws == false then
		return -- the workflow opted out: return as soon as QEMU is launched
	elseif type(ws) ~= "table" then
		fail(action, "VM '%s': 'with.wait_ssh' must be false or a table { timeout_s =, interval_s = }, got %s",
			h.name, type(ws))
	end
	local timeout = ws.timeout_s or 120
	local interval = ws.interval_s or 2
	if type(timeout) ~= "number" or timeout < 0 then
		fail(action, "VM '%s': with.wait_ssh.timeout_s must be a non-negative number, got %s",
			h.name, tostring(timeout))
	end
	if type(interval) ~= "number" or interval <= 0 then
		fail(action, "VM '%s': with.wait_ssh.interval_s must be a positive number, got %s",
			h.name, tostring(interval))
	end

	local time = makac.time
	local deadline = time.now() + timeout * time.ns_per_s
	while true do
		local ok, res = pcall(function()
			return target:run({ "true" })
		end)
		if ok and type(res) == "table" and res.code == 0 then
			return
		end
		if time.now() >= deadline then
			fail(action, "ssh to VM '%s' (127.0.0.1:%d) not up within %ds — see %s",
				h.name, ssh.port, timeout, h.serial_log)
		end
		time.sleep(interval * time.ns_per_s)
	end
end

-- cleanup_runtime_files(h, keep_overlay?): drop the runtime directory
-- (launch.md's cleanup_runtime_files = fs.open_dir(h.run_dir):remove());
-- tolerant of a never-created run_dir. With keep_overlay (a loadvm
-- restart tearing down its VM), only the runtime files go — disk.qcow2
-- STAYS: it holds the snapshots the next launch resumes from
-- (snapshots.md: the snapshot lives inside <run_dir>/disk.qcow2).
local function cleanup_runtime_files(h, keep_overlay)
	if makac.fs.stat(h.run_dir) == nil then
		return
	end
	if not keep_overlay then
		makac.fs.open_dir(h.run_dir):remove()
		return
	end
	-- the overlay survives the teardown: it holds the snapshots the next
	-- launch resumes from (snapshots.md: the snapshot lives inside
	-- <run_dir>/disk.qcow2)
	local d = makac.fs.open_dir(h.run_dir)
	for _, ent in ipairs(makac.fs.listdir(h.run_dir)) do
		if ent.name ~= "disk.qcow2" then
			d:remove(ent.name)
		end
	end
end

local function status_out(h, st)
	-- vm.md: out carries the handle plus the handle.md status fields
	return {
		handle = h,
		pid = st.pid,
		alive = st.alive,
		running = st.running,
		qmp_connected = st.qmp_connected,
		runstate = st.runstate,
	}
end

-- forward declaration: start() below stops a partially-launched VM on the
-- error path (see the errdefer there), but stop() is defined after start().
local stop

-- start(h, qemu_bin, words, canonical, ssh, disk, with): vm.md "Start
-- semantics" steps 1–5. words are already flattened + `{{ disk }}`-subst-
-- ituted; ssh/disk are the already-resolved configs (or nil).
local function start(action, h, qemu_bin, words, canonical, ssh, disk, with, keep_overlay)
	makac.fs.mkdir_p(h.run_dir)
	makac.fs.write_file(h.qemu_stdout, "")
	makac.fs.write_file(h.qemu_stderr, "")

	-- vm.md step 2: probe + invocation identity (handle.md).
	local st = handlelib.probe(h)
	if st.alive then
		local recorded = read_invocation_verbatim(h)
		if recorded == nil then
			fail(action, "VM '%s' is already running but has no recorded invocation (%s/invocation missing) — its identity is unknowable; stop it first (state = \"stopped\")",
				h.name, h.run_dir)
		end
		if recorded ~= canonical then
			fail(action, "VM '%s' is already running with a DIFFERENT invocation (recorded at %s/invocation):\n--- recorded ---\n%s\n--- requested ---\n%s\nChanging a running VM's command line is spelled state = \"restarted\".",
				h.name, h.run_dir, recorded, canonical)
		end
		-- same invocation: no-op (vm.md: "No-op: return the handle,
		-- changed = false"). The overlay from the original boot still
		-- stands (only state = "restarted" recreates it). ssh: no waiting
		-- on a no-op, but out.target is part of the surface whenever ssh is
		-- configured — set it up. out.disk carries the resolved disk info
		-- (the same backing/path the original boot used) so callers can
		-- refer to the actual overlay on disk in later steps.
		local out = status_out(h, st)
		if ssh ~= nil then
			out.target = ensure_target(action, h, ssh)
		end
		if disk ~= nil then
			out.disk = { backing = disk.backing, path = disk.path }
		end
		return { changed = false, out = out }
	end

	-- vm.md, "Overlay boot disks": the fresh overlay is created per start,
	-- BEFORE launch (a failed qemu-img never leaves a half-booted VM) —
	-- EXCEPT a loadvm launch: it keeps the existing overlay, snapshots
	-- and all (snapshots.md).
	if disk ~= nil and not keep_overlay then
		create_overlay(action, h, disk)
	end

	-- vm.md, "Invocation identity": write the canonical form verbatim (text,
	-- so a "different invocation" failure can show the diff) BEFORE launch.
	makac.fs.write_file(h.run_dir .. "/invocation", canonical, { atomic = true })

	-- vm.md step 3: launch detached. The auto-injected runtime arguments
	-- (pidfile, monitor/serial/qmp wiring) derive solely from name+run_dir
	-- and are NOT part of the invocation identity (vm.md).
	local argv = { qemu_bin }
	for _, w in ipairs(words) do
		argv[#argv + 1] = w
	end
	local injected = {
		"-pidfile", h.pid_file,
		"-monitor", ("unix:%s,server,nowait"):format(h.monitor_socket),
		"-serial", "file:" .. h.serial_log,
		"-qmp", ("unix:%s,server,nowait"):format(h.qmp_socket),
	}
	for _, w in ipairs(injected) do
		argv[#argv + 1] = w
	end
	local ok_spawn, p = pcall(makac.spawn, argv, {
		stdout = h.qemu_stdout,
		stderr = h.qemu_stderr,
	})
	if not ok_spawn then
		fail(action, "VM '%s': failed to spawn %s: %s", h.name, qemu_bin, tostring(p))
	end

	-- The VM exists now but the caller does not own it yet. If any launch
	-- step below fails (launch window, QMP attach, ssh readiness), stop it
	-- on the way out: errdefer runs only on the error path, so a normal
	-- return leaves the VM running. guest_shutdown=false + force: the guest
	-- may never have come up, so don't wait on it.
	local teardown <close> = makac.errdefer(function()
		stop(action, h, { guest_shutdown = false, force = true }, keep_overlay)
	end)

	-- vm.md steps 3+4: the launch window. qqmgr slept a fixed 5s then
	-- checked; we poll (launch.md) — same detections, latency only when
	-- warranted.
	local time = makac.time
	local qmp
	local deadline = time.now() + LAUNCH_WINDOW_S * time.ns_per_s
	while time.now() < deadline do
		-- early-exit check FIRST (launch.md): a racing exit + a leftover
		-- socket file from a previous run must not spell success.
		local pst = p:status()
		if pst ~= "running" then
			local how = type(pst) == "table" and ("exit " .. tostring(pst.code)) or tostring(pst)
			fail(action, "VM '%s': qemu exited during launch (%s) — stderr log %s:\n%s",
				h.name, how, h.qemu_stderr, tail(h.qemu_stderr, 40))
		end
		if makac.fs.stat(h.qmp_socket) ~= nil then
			-- the socket exists before QEMU accepts on it: retry briefly
			local ok_conn, client = pcall(makac.qmp_open, { socket = h.qmp_socket, timeout_s = 2 })
			if ok_conn then
				qmp = client
				break
			end
		end
		time.sleep(50 * time.ns_per_ms)
	end
	if qmp == nil then
		fail(action, "VM '%s': qemu did not open %s within the launch window (%ds) — stderr log %s:\n%s",
			h.name, h.qmp_socket, LAUNCH_WINDOW_S, h.qemu_stderr, tail(h.qemu_stderr, 40))
	end
	-- vm.md step 4: this is the VM's connection for the rest of the run —
	-- the one every qmp action against it uses (qmp.md, handle.md).
	handlelib.attach_qmp(h, qmp)

	-- After the window the process object has done its job (launch.md): we
	-- never call p:status() again and never add a reaper. If the VM dies
	-- mid-workflow it is a zombie until makac exits and init reaps it.
	--
	-- p.pid answers the pidfile, the way QEMU's own -pidfile would
	-- (launch.md). probe() reads the pidfile + pid_alive, never the object.
	makac.fs.write_file(h.pid_file, tostring(p.pid) .. "\n", { atomic = true })

	-- vm.md step 5 + "The ssh target": with ssh configured, out.target is
	-- a makac remote target (127.0.0.1, the host-assigned port); unless
	-- wait_ssh is false, poll until a trivial command runs.
	local target
	if ssh ~= nil then
		target = ensure_target(action, h, ssh)
		wait_for_ssh(action, h, target, ssh, with)
	end

	local out = status_out(h, handlelib.probe(h))
	out.pid = p.pid -- authoritative for THIS launch (pidfile just written)
	out.target = target -- nil when ssh is not configured
	if disk ~= nil then
		out.disk = { backing = disk.backing, path = disk.path }
	end
	return { changed = true, out = out }
end

-- stop(h, with): vm.md "Stop semantics", launch.md's two-escalation loop.
stop = function(action, h, with, keep_overlay)
	local st = handlelib.probe(h)
	if not st.alive then
		cleanup_runtime_files(h, keep_overlay)
		return { changed = false, out = status_out(h, st) }
	end

	local timeout_s = with.timeout_s
	if timeout_s == nil then
		timeout_s = 20
	elseif type(timeout_s) ~= "number" or timeout_s < 0 then
		fail(action, "VM '%s': 'with.timeout_s' must be a non-negative number, got %s",
			h.name, tostring(timeout_s))
	end
	-- guest_shutdown (vm.md): true (default) asks the guest OS to power
	-- itself off first (system_powerdown — a cooperative shutdown); false
	-- skips that handshake and stops by QMP quit instead: a clean QEMU
	-- exit that flushes the disks, just without waiting on the guest.
	local guest_shutdown = with.guest_shutdown
	if guest_shutdown == nil then
		guest_shutdown = true
	elseif type(guest_shutdown) ~= "boolean" then
		fail(action, "VM '%s': 'with.guest_shutdown' must be a boolean, got %s",
			h.name, type(guest_shutdown))
	end
	local force = with.force ~= false -- default true (vm.md)

	local time = makac.time
	-- Best effort (pcall): a wedged QMP (socket dead, pid alive — the
	-- probe's "wedged" signature) just means we escalate to force.
	local ok_qmp, qmp = pcall(ensure_qmp, action, h)
	local function alive()
		return st.pid ~= nil and handlelib.process_alive(st.pid)
	end
	local function wait_gone(window_ns)
		local deadline = time.now() + window_ns
		while alive() and time.now() < deadline do
			time.sleep(50 * time.ns_per_ms)
		end
	end

	if guest_shutdown then
		-- cooperative first: ACPI powerdown, then watch the process go
		if ok_qmp then
			pcall(qmp.send, qmp, { { execute = "system_powerdown" } })
		end
		wait_gone(timeout_s * time.ns_per_s)
	elseif alive() and ok_qmp then
		-- the stop method IS the clean QEMU exit; give it the whole
		-- window to finish flushing before any force escalation
		pcall(qmp.send, qmp, { { execute = "quit" } })
		wait_gone(timeout_s * time.ns_per_s)
	end

	-- force escalation: QMP quit (when not already the stop method), then
	-- kill -9 to the pidfile pid.
	if alive() and force then
		if guest_shutdown then
			if ok_qmp then
				pcall(qmp.send, qmp, { { execute = "quit" } })
			end
			wait_gone(200 * time.ns_per_ms)
		end
		if alive() then
			makac.exec({ "kill", "-9", tostring(st.pid) })
			time.sleep(50 * time.ns_per_ms) -- let the kernel settle the corpse
		end
	end

	-- authority is a fresh probe (handles the pid-less "qmp-only" evidence
	-- path too): still alive after both escalations is a step failure.
	local after = handlelib.probe(h)
	if after.alive then
		fail(action, "VM '%s'%s did not stop (graceful timeout %ds, force %s)",
			h.name,
			st.pid ~= nil and (" (pid " .. st.pid .. ")") or "",
			timeout_s, force and "enabled" or "disabled")
	end

	-- the handle's connection goes with the VM (handle.md); the ssh target
	-- closes as part of teardown (vm.md, "The ssh target"). Both are
	-- idempotent; the runner's run-end close_all_targets double-close is
	-- tolerated by the target wrapper.
	handlelib.close(h)
	local t = handlelib.detach_target(h)
	if t ~= nil then
		pcall(t.close, t)
	end
	cleanup_runtime_files(h, keep_overlay)
	return { changed = true, out = { handle = h, pid = st.pid, alive = false } }
end

-- qemu:vm — bring a VM into the desired state (vm.md).
function M.vm(with)
	with = with or {}
	local state = with.state or "started"
	if state ~= "started" and state ~= "stopped" and state ~= "restarted" then
		fail("vm", "'with.state' must be \"started\", \"stopped\" or \"restarted\", got %s",
			tostring(with.state))
	end

	-- identity: with.vm — a VM name or a previous out.handle (vm_arg)
	local h = vm_arg("vm", with)

	if state == "stopped" then
		return stop("vm", h, with) -- ssh/disk config is start-relevant; a stop ignores it
	end
	-- ssh + disk: resolve NOW (before anything launches) so a spec error
	-- never leaves a booted VM behind it.
	local ssh = resolve_ssh("vm", h, with.ssh)
	local disk = resolve_disk("vm", h, with.disk)

	-- start/restart need the full launch spec (vm.md: qemu_bin + args are
	-- required for those states)
	local qemu_bin = with.qemu_bin
	if type(qemu_bin) ~= "string" or qemu_bin == "" then
		fail("vm", "VM '%s': 'with.qemu_bin' (the qemu-system binary to run) is required for state = \"%s\"",
			h.name, state)
	end
	if with.args == nil then
		fail("vm", "VM '%s': 'with.args' (the QEMU command line, an argv array) is required for state = \"%s\"",
			h.name, state)
	end
	argslib.check_reserved(with.args)
	-- `{{ disk }}` substitutes the overlay path (the only substitution in
	-- VM args; a spec error without with.disk — args.substitute enforces).
	-- The path is whatever resolve_disk settled on: the run-dir overlay by
	-- default, a user-supplied with.disk.path when given.
	local words = argslib.substitute(with.args, disk and { disk = disk.path } or nil)
	-- canonical AFTER flattening + substitution: syntactic variation in how
	-- the list was composed collapses to the same form (vm.md). The overlay
	-- backing's absolute path is part of the identity (vm.md: a rebuilt
	-- image at the same path does not invalidate a running VM; booting a
	-- NEW backing is spelled state = "restarted").
	local canonical = argslib.canonical_invocation(qemu_bin, words)
	if disk ~= nil then
		canonical = canonical .. "\n# overlay backing: " .. disk.backing
	end

	if state == "restarted" then
		stop("vm", h, with) -- unconditionally (vm.md); tolerates a down VM
	end
	return start("vm", h, qemu_bin, words, canonical, ssh, disk, with)
end

-- qemu:loadvm — qemu:vm's start/restart choreography with ONE additional
-- input (snapshots.md): with.snapshot, the tag qemu:savevm captured into
-- the VM's overlay. The launch appends -loadvm <tag> — the guest resumes
-- where the snapshot was taken instead of booting — and the tag is part
-- of the CANONICAL invocation: "same VM, new tag" is a different
-- invocation, spelled state = "restarted" (state = "started" is the
-- same-VM no-op, exactly as with qemu:vm).
--
-- Unlike qemu:vm's start, a loadvm start KEEPS the existing overlay: the
-- snapshot lives INSIDE <run_dir>/disk.qcow2 (recreating the overlay
-- would destroy the snapshot — vm.md, "Overlay boot disks"; the
-- recreate-on-restart rule of qemu:vm does NOT apply here).
--
-- The caller supplies `args`: resuming requires the machine configuration
-- the snapshot was taken with (the image records state, not
-- configuration). Control interfaces (pidfile, monitor/serial/qmp
-- wiring) are exempt from identity — the auto-injected runtime arguments
-- were never part of the invocation file (vm.md). A tag not present in
-- the image fails at launch: QEMU exits early, and the step failure
-- quotes the qemu-stderr log — qemu:vm's launch rules, verbatim.
function M.loadvm(with)
	with = with or {}
	local state = with.state or "started"
	if state ~= "started" and state ~= "restarted" then
		fail("loadvm", "'with.state' must be \"started\" or \"restarted\" (no \"stopped\": stopping is qemu:vm's), got %s",
			tostring(with.state))
	end

	-- identity: with.vm — a VM name or a previous out.handle (vm_arg)
	local h = vm_arg("loadvm", with)

	-- the one additional input: the snapshot tag (snapshots.md)
	local snapshot = with.snapshot
	if type(snapshot) ~= "string" or snapshot == "" then
		fail("loadvm", "VM '%s': 'with.snapshot' (the snapshot tag, from qemu:savevm's out.snapshot) is required and must be a non-empty string, got %s",
			h.name, tostring(with.snapshot))
	end

	-- ssh + disk resolve now, as in qemu:vm (never leave a booted VM
	-- behind a spec error)
	local ssh = resolve_ssh("loadvm", h, with.ssh)
	local disk = resolve_disk("loadvm", h, with.disk)

	local qemu_bin = with.qemu_bin
	if type(qemu_bin) ~= "string" or qemu_bin == "" then
		fail("loadvm", "VM '%s': 'with.qemu_bin' (the qemu-system binary to run) is required",
			h.name)
	end
	if with.args == nil then
		fail("loadvm", "VM '%s': 'with.args' (the QEMU command line the snapshot was taken with) is required",
			h.name)
	end
	argslib.check_reserved(with.args)
	local words = argslib.substitute(with.args, disk and { disk = disk.path } or nil)
	-- resume instead of boot; the tag participates in the identity
	words[#words + 1] = "-loadvm"
	words[#words + 1] = snapshot
	local canonical = argslib.canonical_invocation(qemu_bin, words)
	if disk ~= nil then
		canonical = canonical .. "\n# overlay backing: " .. disk.backing
	end

	if state == "restarted" then
		-- unconditionally, like qemu:vm's restart — but keep the overlay
		-- (keep_overlay): the snapshot being resumed lives inside it
		stop("loadvm", h, with, true)
	end
	-- keep_overlay: the overlay HOLDS the snapshot — keep, don't recreate
	return start("loadvm", h, qemu_bin, words, canonical, ssh, disk, with, true)
end

-- qemu:probe — read a VM's status (handle.md, "Status probing"): out is
-- exactly the status shape qemu:vm reports (status_out above) — handle,
-- pid, alive, running, qmp_connected, runstate. A READ: ok, never
-- changed, and it never fails on a down or wedged VM — those are data
-- (down: alive = false; wedged: alive = true with running = nil,
-- qmp_connected = false). Only invalid input fails. Workflows spell
-- liveness POLICY on top of it ("already up → no-op", "must be down to
-- re-seed") instead of reaching into pkgs:qemu/handle.
--
-- The probe asks QMP first (query-status — through this run's attached
-- connection when one exists, a transient one otherwise) with pidfile
-- evidence as fallback. Send caveat: probing through an ATTACHED
-- connection clears its buffered events (qmp.md's send semantics, same
-- as any send) — don't probe between a qmp/poll and its consume.
function M.probe(with)
	with = with or {}
	local h = vm_arg("probe", with)
	return { changed = false, out = status_out(h, handlelib.probe(h)) }
end

return M
