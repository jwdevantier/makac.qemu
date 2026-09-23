-- pkgs/qemu/handle (internal) — VM handles, the per-run registry, and the
-- status probe (design/handle.md).
--
-- A handle identifies a VM: a name, a runtime directory, and the QEMU
-- process (if any) currently occupying it. The handle table is PURE DATA
-- (paths/strings) — nothing about VM state is ever cached in it; status is
-- derived from the files at call time via probe(). The one piece of live
-- state is the QMP connection, owned by the per-run registry (one
-- connection per handle, exactly one handle per VM per run).
--
--   resolve(name, run_dir?)  -> handle   -- materialize or return existing
--   resolve(handle_tbl)      -> handle   -- same VM => IDENTICAL table
--   probe(handle_or_name)    -> status   -- never raises on down/wedged
--   attach_qmp(h, client)                -- registry takes the connection
--   qmp_of(handle_or_name)   -> client|nil
--   close(handle_or_name)                -- drop+close the QMP connection
--   process_alive(pid)       -> bool     -- kill(pid,0) MINUS zombies
--   attach_target(h, t) | target_of(h) | detach_target(h)
--                                        -- the VM's ssh target registry
--                                        -- (vm.md, "The ssh target")
--
-- Registry keys are the CANONICAL (absolute, cleaned) run_dir, so
-- syntactically different spellings of one directory resolve to the same
-- entry and the same table.

local M = {}

-- per-run registry: canonical run_dir -> handle table (handle.md, "One
-- handle per VM per run")
local registry = {}
-- registry-owned QMP connections: canonical run_dir -> client userdata
local clients = {}
-- registry-owned ssh targets (vm.md, "The ssh target"): canonical run_dir
-- -> target table. Kept here like the QMP clients: one per handle per run,
-- so stop() can close it as part of teardown and later steps see one
-- identity.
local targets = {}

-- default_run_dir(name): derivation rule (handle.md, "Obtaining one,
-- re-deriving one").
function M.default_run_dir(name)
	assert(makac.data_dir ~= nil, "qemu: makac.data_dir is not set")
	return makac.data_dir .. "/qemu/" .. name
end

-- canonical_run_dir(dir): absolute, cleaned string form of a run_dir —
-- the registry key. Relative input anchors at makac's cwd; cleaning is
-- lexical (symlinks not resolved).
function M.canonical_run_dir(dir)
	if type(dir) ~= "string" then
		dir = tostring(dir) -- path userdata: the escape hatch
	end
	if dir == "" then
		error("qemu: run_dir must be a non-empty path", 2)
	end
	if dir:sub(1, 1) ~= "/" then
		dir = tostring(makac.fs.cwd()) .. "/" .. dir
	end
	return tostring(makac.fs.path(dir))
end

local function new_handle(name, run_dir)
	return {
		name = name,                 -- identity
		run_dir = run_dir,           -- runtime directory (canonical absolute)
		pid_file = run_dir .. "/pid",
		qmp_socket = run_dir .. "/qmp.socket",
		disk_overlay = run_dir .. "/disk.qcow2", -- vm.md, "Overlay boot disks"
		monitor_socket = run_dir .. "/monitor.socket", -- human monitor
		serial_log = run_dir .. "/serial",
		qemu_stdout = run_dir .. "/qemu-stdout.log",
		qemu_stderr = run_dir .. "/qemu-stderr.log",
		ssh_config = run_dir .. "/ssh.conf",           -- if ssh configured
	}
end

-- resolve(handle_or_name, run_dir?): the identity guarantee. First touch
-- of a VM materializes the registry entry; every later resolve of the same
-- VM — by name, by handle, even by an equivalent table from another run —
-- returns the IDENTICAL table.
function M.resolve(handle_or_name, run_dir)
	local name, dir
	if type(handle_or_name) == "table" then
		name = handle_or_name.name
		dir = run_dir or handle_or_name.run_dir
	elseif type(handle_or_name) == "string" then
		name = handle_or_name
		dir = run_dir
	else
		error(("qemu: resolve: a VM name (string) or handle (table) is required (got %s)")
			:format(type(handle_or_name)), 2)
	end
	if type(name) ~= "string" or name == "" then
		error("qemu: resolve: VM name must be a non-empty string", 2)
	end
	if name:find("/", 1, true) then
		error(("qemu: VM name %q must not contain '/'"):format(name), 2)
	end
	dir = M.canonical_run_dir(dir or M.default_run_dir(name))
	local existing = registry[dir]
	if existing then
		return existing
	end
	local handle = new_handle(name, dir)
	registry[dir] = handle
	return handle
end

-- attach_target(handle_or_name, target): the registry remembers the VM's
-- ssh target (one per handle). Returns the target for convenience.
function M.attach_target(handle_or_name, target)
	local handle = M.resolve(handle_or_name)
	if targets[handle.run_dir] ~= nil then
		error(("qemu: VM '%s' already has an ssh target in this run (one per handle)")
			:format(handle.name), 2)
	end
	if type(target) ~= "table" then
		error(("qemu: attach_target: no target given for VM '%s'"):format(handle.name), 2)
	end
	targets[handle.run_dir] = target
	return target
end

-- target_of(handle_or_name) -> target|nil: the VM's ssh target, if ssh is
-- configured and one was set up this run.
function M.target_of(handle_or_name)
	return targets[M.resolve(handle_or_name).run_dir]
end

-- detach_target(handle_or_name) -> target|nil: drop the target from the
-- registry WITHOUT closing it (the caller closes — teardown order). A
-- handle without a target is a no-op.
function M.detach_target(handle_or_name)
	local handle = M.resolve(handle_or_name)
	local t = targets[handle.run_dir]
	targets[handle.run_dir] = nil
	return t
end
-- attach_qmp(handle_or_name, client): the registry takes ownership of the
-- handle's QMP connection. Exactly one connection per handle (handle.md,
-- "The QMP connection"): attaching while one is live is a spec error.
function M.attach_qmp(handle_or_name, client)
	local handle = M.resolve(handle_or_name)
	if clients[handle.run_dir] ~= nil then
		error(("qemu: a QMP client is already attached to VM '%s' (one connection per handle; close it first)")
			:format(handle.name), 2)
	end
	if client == nil then
		error(("qemu: attach_qmp: no client given for VM '%s'"):format(handle.name), 2)
	end
	clients[handle.run_dir] = client
	return client
end

-- qmp_of(handle_or_name) -> client|nil: resolve "this handle's connection"
-- through the registry at call time (handle.md).
function M.qmp_of(handle_or_name)
	return clients[M.resolve(handle_or_name).run_dir]
end

-- close(handle_or_name): drop and close the handle's QMP connection.
-- Idempotent; a handle without a connection is a no-op.
function M.close(handle_or_name)
	local handle = M.resolve(handle_or_name)
	local client = clients[handle.run_dir]
	clients[handle.run_dir] = nil
	if client ~= nil then
		pcall(client.close, client) -- closing twice is tolerated by the client
	end
end

-- read a QEMU pidfile -> pid number or nil (missing file, unparsable or
-- non-positive content all mean "no pid").
local function read_pid(pid_file)
	local content = makac.fs.read_file(pid_file)
	if content == nil then
		return nil
	end
	local pid = tonumber(content:match("^%s*(%d+)"))
	if pid ~= nil and pid > 0 then
		return pid
	end
	return nil
end

-- is_zombie(pid): a process that EXITED but was never reaped still answers
-- kill(pid, 0) — and a VM makac itself spawned becomes exactly that on
-- exit (it is reaped when the run ends; launch.md). Liveness must not
-- mistake the husk for a process. /proc/<pid>/stat's state field (the
-- letter after the last ")") tells: "Z"/"X" are dead. Unreadable /proc
-- entry means "can't tell" — kill(pid, 0) then has the last word.
local function is_zombie(pid)
	local stat = makac.fs.read_file(("/proc/%d/stat"):format(pid))
	if stat == nil then
		return false
	end
	local state = stat:match("^.*%)%s+(%a)")
	return state == "Z" or state == "X"
end

-- process_alive(pid): the liveness predicate for pidfile pids: answers
-- kill(pid, 0) MINUS zombies (see is_zombie). nil pid means not alive.
function M.process_alive(pid)
	return pid ~= nil and makac.pid_alive(pid) and not is_zombie(pid)
end

-- probe(handle_or_name) -> status (handle.md, "Status probing"). Probe
-- order:
--   1. QMP first: connect to handle.qmp_socket, query-status; its
--      `running` boolean is authoritative when it answers, and the query's
--      status string is the runstate.
--   2. PID fallback: live pidfile pid with unresponsive QMP means the
--      process is there but the VM is not responsive (wedged signature:
--      alive=true, running=nil, qmp_connected=false).
--   3. Down: no pidfile or dead pid.
-- NEVER raises on a down/wedged VM — it reports.
function M.probe(handle_or_name)
	local handle = M.resolve(handle_or_name)
	local qmp_connected = false
	local running = nil -- QMP-derived only
	local runstate = nil

	-- 1. QMP first. Real QEMU services ONE client connection on the QMP
	--    socket at a time: a transient probe connection only gets the
	--    greeting once the current client disconnects — so when this
	--    handle has an ATTACHED registry connection (the VM was started or
	--    attached in this run), the probe must use THAT one. (Using it
	--    clears its buffered events — qmp.md's send semantics; any action
	--    about to send on the connection would clear them anyway.)
	--    A VM whose run has no connection (started outside, or its run
	--    ended) gets the transient connection.
	local attached = M.qmp_of(handle)
	if attached ~= nil then
		local ok2, results = pcall(
			attached.send, attached, { { execute = "query-status" } }, { timeout_s = 2 }
		)
		if ok2 and type(results) == "table" and type(results[1]) == "table" then
			local ret = results[1]["return"]
			if type(ret) == "table" and ret.running ~= nil then
				qmp_connected = true
				running = not not ret.running
				runstate = ret.status
			end
		end
	else
		local ok, client = pcall(makac.qmp_open, { socket = handle.qmp_socket, timeout_s = 2 })
		if ok then
			local ok2, results = pcall(
				client.send, client, { { execute = "query-status" } }, { timeout_s = 2 }
			)
			pcall(client.close, client)
			if ok2 and type(results) == "table" and type(results[1]) == "table" then
				local ret = results[1]["return"]
				if type(ret) == "table" and ret.running ~= nil then
					qmp_connected = true
					running = not not ret.running
					runstate = ret.status
				end
				-- a QMP error reply or a missing answer means QMP is not
				-- authoritative here: fall through to the pid evidence.
			end
		end
	end

	-- 2/3. PID evidence: existence of the process. A zombie answers
	-- kill(pid, 0) but is dead: exclude it (a wedged VM is alive AND not a
	-- zombie; a dead husk of our own spawn is neither).
	local pid = read_pid(handle.pid_file)
	local pid_live = M.process_alive(pid)

	return {
		pid = pid,                          -- from pidfile, if present & valid
		alive = qmp_connected or pid_live,  -- process exists (QMP or pid evidence)
		running = running,                  -- QMP-derived only, nil otherwise
		qmp_connected = qmp_connected,      -- was QMP reachable in this probe?
		runstate = runstate,                -- "running"|"paused"|... or nil
	}
end

return M
