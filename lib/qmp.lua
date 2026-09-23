-- pkgs/qemu/qmp — QMP command constructors and reply helpers (design/qmp.md,
-- "The library").
--
-- PURE table-builders: no socket, no target VM, no sending of anything.
-- A constructor maps arguments to a { execute = ..., arguments = ... }
-- table; a workflow passes such tables to `qemu:qmp/send`, the only place
-- commands are sent — and the only place a VM is named. Because they are
-- pure, the constructors compose with ordinary Lua and one command table
-- can be sent to any number of VMs.

---@class QemuQmpCommand
---@field execute string
---@field arguments? table<string, any>

---@class QemuQmpResult
---@field return? any
---@field error? { class: string, desc: string }

---@class QemuQmpLib
local M = {}

-- merge(tables): later tables win; returns a FRESH table (sources are
-- never mutated). Shallow — QMP arguments nest freely and nested tables
-- pass through verbatim, key names included (node-name/if need bracket
-- syntax but otherwise just work). Exposed because compositions like the
-- NVMe hotplug sequence reuse it for option tables. Entries are an ARRAY
-- of tables (no interior nils).
---@param tables table[]
---@return table
function M.merge(tables)
	local t = {}
	for _, tsrc in ipairs(tables) do
		for k, v in pairs(tsrc) do
			t[k] = v
		end
	end
	return t
end

-- dev_add(driver, args?) -> { execute = "device_add",
--                              arguments = merge{args, {driver = driver}} }
-- The explicit driver argument wins over a stray args.driver.
---@param driver string
---@param args? table<string, any>
---@return QemuQmpCommand
function M.dev_add(driver, args)
	return {
		execute = "device_add",
		arguments = M.merge { args or {}, { driver = driver } },
	}
end

-- bdev_add(node, driver, args?) -> blockdev-add with node-name/driver
-- injected.
---@param node string
---@param driver string
---@param args? table<string, any>
---@return QemuQmpCommand
function M.bdev_add(node, driver, args)
	return {
		execute = "blockdev-add",
		arguments = M.merge { args or {}, { ["node-name"] = node, driver = driver } },
	}
end

-- hmp(command_line) -> human-monitor-command table. The command line is an
-- opaque string ("savevm mysnapshot"); no quoting/escaping is involved in
-- either direction.
---@param command_line string
---@return QemuQmpCommand
function M.hmp(command_line)
	return {
		execute = "human-monitor-command",
		arguments = { ["command-line"] = command_line },
	}
end

-- query_status() -> { execute = "query-status" } (probe and start
-- choreography both ask this).
---@return QemuQmpCommand
function M.query_status()
	return { execute = "query-status" }
end

-- --- reply helpers (also pure) ------------------------------------------

-- ok(result): nil error means the command succeeded.
---@param result QemuQmpResult
---@return boolean
function M.ok(result)
	return result.error == nil
end

-- err_desc(result): the error desc, or nil when there is no error.
---@param result QemuQmpResult
---@return string?
function M.err_desc(result)
	return result.error ~= nil and result.error.desc or nil
end

return M
