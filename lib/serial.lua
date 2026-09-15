-- pkgs:qemu/serial — waiting for patterns in a VM's serial log
-- (design/vm.md, "The serial console").
--
-- QEMU captures the guest console to a file for the VM's lifetime
-- (`-serial file:<run_dir>/serial`, wired by qemu:vm — the handle carries
-- the path in `serial_log`). Workflows consume it here:
--
--   serial.wait_for(handle_or_name, pattern, timeout_s) — poll the log
--       until the Lua pattern matches; on timeout, fail quoting the log's
--       tail. Used for "wait for login prompt", "wait for cloud-init
--       done", device-appearance loops, ...
--   serial.tail(handle_or_name, n) — the last n lines.
--
-- Both resolve their first argument exactly like the actions do (a name
-- re-derives the handle), so a VM started by an earlier run can be tailed.

local handlelib = require("pkgs:qemu/handle")

local M = {}

-- read the log; nil-safe — a not-yet-created log reads as "" (the console
-- file appears when QEMU opens it, which can lag the workflow).
local function read_log(path)
	local text = makac.fs.read_file(path)
	return text or ""
end

-- quote_tail(text, max_bytes): the tail of the log bounded for a failure
-- message (serial logs can spew), prefixed with an elision marker when cut.
local function quote_tail(text, max_bytes)
	if text == "" then
		return "(the serial log has no content yet)"
	end
	if #text > max_bytes then
		text = ("... (%d bytes elided) ...\n%s"):format(#text - max_bytes, text:sub(#text - max_bytes + 1))
	end
	return text
end

-- tail(handle_or_name, n) -> string: the last n lines of the serial log.
-- A missing/empty log returns "" (nothing to say); a log shorter than n
-- lines comes back whole.
function M.tail(handle_or_name, n)
	if type(n) ~= "number" or n < 1 or n % 1 ~= 0 then
		error(("qemu/serial.tail: n must be a positive integer, got %s"):format(tostring(n)), 2)
	end
	local h = handlelib.resolve(handle_or_name)
	local text = read_log(h.serial_log)
	-- walk from the end collecting line boundaries; stop after n lines.
	-- The scan goes backwards so a huge log is not split wholesale.
	local stop = #text
	-- a trailing newline terminates the last line rather than making a
	-- phantom empty one
	if stop > 0 and text:sub(stop, stop) == "\n" then
		stop = stop - 1
	end
	local start = 1
	for _ = 1, n do
		local nl
		for i = stop, 1, -1 do
			if text:sub(i, i) == "\n" then nl = i break end
		end
		if nl == nil then
			start = 1 -- fewer than n lines remain: take the whole log
			break
		end
		start = nl + 1
		stop = nl - 1
		if stop < 1 then break end
	end
	return text:sub(start)
end

-- wait_for(handle_or_name, pattern, timeout_s) -> match: poll the log
-- every interval until the Lua pattern matches, then return string.match's
-- result (the whole match, or the first capture — workflows can pull a
-- value out of the line they waited on). Timeout is a failure quoting the
-- log's tail.
function M.wait_for(handle_or_name, pattern, timeout_s)
	if type(pattern) ~= "string" or pattern == "" then
		error(("qemu/serial.wait_for: the pattern must be a non-empty Lua pattern, got %s")
			:format(tostring(pattern)), 2)
	end
	if type(timeout_s) ~= "number" or timeout_s <= 0 then
		error(("qemu/serial.wait_for: timeout_s must be a positive number, got %s")
			:format(tostring(timeout_s)), 2)
	end
	local h = handlelib.resolve(handle_or_name)

	local time = makac.time
	local ns_per_s = time.ns_per_s
	local deadline = time.now() + timeout_s * ns_per_s
	local interval = 0.25 * ns_per_s
	while true do
		local text = read_log(h.serial_log)
		local match = text:match(pattern)
		if match ~= nil then
			return match
		end
		if time.now() >= deadline then
			error(("qemu/serial: VM '%s': no match for %s in the serial log within %gs " ..
				"(%s):\n%s"):format(h.name, ("%q"):format(pattern), timeout_s, h.serial_log,
				quote_tail(text, 16384)), 2)
		end
		time.sleep(interval)
	end
end

return M
