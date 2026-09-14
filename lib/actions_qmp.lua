-- pkgs:qemu/actions_qmp — internal implementations of the qemu:qmp/*
-- actions (design2/qmp.md). Thin wrappers over the makac.qmp_open client
-- binding (vm/qmp.odin); the binding already carries the semantics these
-- actions rely on: send clears the event buffer when it issues commands,
-- poll drains the socket into the buffer and reports whether anything
-- arrived (a timeout is not an error), events(n?) reads the first n buffered
-- events — all of them when n is omitted, reading does not consume — and
-- consume drops the n oldest buffered events and raises when n exceeds the
-- buffered count.
--
-- Every action accepts `with.vm` = a handle OR a plain VM name (plus an
-- optional `with.run_dir` override) and resolves "this handle's connection"
-- through the per-run registry at call time (handle.md, "One handle per VM
-- per run"). Step failures raise with a message naming the VM.

local handlelib = require("pkgs:qemu/handle")

local M = {}

-- connection(action, with) -> client, handle
-- Resolve the VM, then its connection through the registry. A VM with no
-- connection in this run (name-based attach without a prior qemu:vm start)
-- gets one opened at attach time — QEMU accepts concurrent QMP clients
-- across runs (qmp.md, "The connection model"). An unconnectable socket is
-- a step failure naming the VM.
local function connection(action, with)
	local vm = with.vm
	if vm == nil then
		error(("qemu:%s: 'with.vm' is required: a VM handle (qemu:vm's out.handle) or a plain VM name")
			:format(action), 2)
	end
	local h = handlelib.resolve(vm, with.run_dir)
	local client = handlelib.qmp_of(h)
	if client ~= nil then
		return client, h
	end
	local ok, new_client = pcall(makac.qmp_open, {
		socket = h.qmp_socket,
		timeout_s = 5,
	})
	if not ok then
		error(("qemu:%s: VM '%s': cannot connect to QMP socket %s: %s"):format(
			action, h.name, h.qmp_socket, tostring(new_client)), 2)
	end
	return handlelib.attach_qmp(h, new_client), h
end

-- connection is shared with the snapshot actions (savevm lives over the
-- same per-run connection discipline).
M.connection = connection

local function check_timeout_s(action, v)
	if v == nil then
		return nil
	end
	if type(v) ~= "number" or v < 0 then
		error(("qemu:%s: 'with.timeout_s' must be a non-negative number, got %s")
			:format(action, tostring(v)), 2)
	end
	return v
end

-- qemu:qmp/send — send `with.commands` IN ARRAY ORDER on the VM's
-- connection. on_error = "fail" (default): the first QMP error reply fails
-- the step, naming the command and its desc; "collect": run them all and
-- carry failures in out.results[i].error. Each command is
-- { execute = "...", arguments = {...}? } (arguments nests freely — the
-- pkgs:qemu/qmp library builds these tables, but hand-written ones are
-- identical).
function M.send(with)
	with = with or {}
	local commands = with.commands
	if type(commands) ~= "table" or #commands == 0 then
		error("qemu:qmp/send: 'with.commands' must be a non-empty array of { execute = ..., arguments = ...? }", 2)
	end
	for i, cmd in ipairs(commands) do
		if type(cmd) ~= "table" or type(cmd.execute) ~= "string" then
			error(("qemu:qmp/send: 'with.commands[%d]' must be a table with a string 'execute'"):format(i), 2)
		end
		if cmd.arguments ~= nil and type(cmd.arguments) ~= "table" then
			error(("qemu:qmp/send: 'with.commands[%d].arguments' must be a table, got %s")
				:format(i, type(cmd.arguments)), 2)
		end
	end
	local on_error = with.on_error or "fail"
	if on_error ~= "fail" and on_error ~= "collect" then
		error(('qemu:qmp/send: \'with.on_error\' must be "fail" or "collect", got %s')
			:format(tostring(with.on_error)), 2)
	end

	local client, h = connection("qmp/send", with)
	-- per-command sends: "fail" (default) aborts the step at the FIRST
	-- error reply — not sending the remaining commands; "collect" runs
	-- them all, carrying failures in out.results[i].error (qmp.md,
	-- "qemu:qmp/send" — only collect "continues"). The client binding
	-- clears the event buffer at each issued command (a new transaction
	-- begins).
	local results = {}
	for i, cmd in ipairs(commands) do
		local ok, one = pcall(client.send, client, { cmd })
		if not ok then
			error(("qemu:qmp/send: VM '%s': %s"):format(h.name, tostring(one)), 0)
		end
		results[i] = one[1]
		if on_error == "fail" and results[i].error ~= nil then
			error(("qemu:qmp/send: VM '%s': command '%s' (commands[%d]) failed: %s (%s)"):format(
				h.name, cmd.execute, i,
				tostring(results[i].error.desc), tostring(results[i].error.class)), 0)
		end
	end
	return { changed = true, out = { results = results } }
end

-- qemu:qmp/poll — drain pending events on the VM's connection, bounded by
-- `with.timeout_s` (default 0; a timeout is NOT an error — the action
-- returns with whatever arrived). out.events is the VM's PENDING events —
-- the whole buffer after the drain — and they REMAIN buffered (drop them
-- with qemu:qmp/consume once treated). What the step shows is exactly what
-- a matching consume(n) discards.
function M.poll(with)
	with = with or {}
	local timeout_s = check_timeout_s("qmp/poll", with.timeout_s) or 0

	local client, h = connection("qmp/poll", with)
	local ok, e = pcall(client.poll, client, { timeout_s = timeout_s })
	if not ok then
		error(("qemu:qmp/poll: VM '%s': %s"):format(h.name, tostring(e)), 0)
	end
	local ok2, events = pcall(client.events, client)
	if not ok2 then
		error(("qemu:qmp/poll: VM '%s': %s"):format(h.name, tostring(events)), 0)
	end
	return { out = { events = events } }
end

-- qemu:qmp/consume — discard the `with.n` OLDEST buffered events, the ones
-- the workflow has finished treating (their count came from a poll). The
-- client binding raises when n exceeds the buffered count; that becomes a
-- step failure naming the VM.
function M.consume(with)
	with = with or {}
	local n = with.n
	if type(n) ~= "number" or n < 0 or n % 1 ~= 0 then
		error(("qemu:qmp/consume: 'with.n' must be a non-negative integer, got %s")
			:format(tostring(n)), 2)
	end

	local client, h = connection("qmp/consume", with)
	local ok, err = pcall(client.consume, client, n)
	if not ok then
		error(("qemu:qmp/consume: VM '%s': %s"):format(h.name, tostring(err)), 0)
	end
	return {}
end

return M
