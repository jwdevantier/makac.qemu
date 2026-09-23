-- The qemu package (design/main.md): actions to build disk images and
-- manage QEMU virtual machines.
--
-- This file only EXPORTS; the implementations live in lib/ modules
-- (lib/actions_*.lua; also lib/handle.lua — internal, and
-- lib/qmp.lua, lib/args.lua, lib/img.lua, lib/serial.lua — the
-- workflow-facing libraries). Actions are functions of
-- a single `with` table (the action contract, makac core — see the makac
-- repository's design/action.md); makac normalizes their result
-- table ({ err?, changed?, skipped?, out? }).

local actions_qmp = require("pkgs/qemu/actions_qmp")
local actions_vm = require("pkgs/qemu/actions_vm")
local actions_snapshots = require("pkgs/qemu/actions_snapshots")
local img = require("pkgs/qemu/img")

return {
	actions = {
		-- set a VM's state: started / stopped / restarted (vm.md, launch.md)
		vm = actions_vm.vm,
		-- read a VM's status: liveness, pid, runstate (handle.md)
		probe = actions_vm.probe,
		-- QMP: send commands / poll events / consume treated events (qmp.md)
		["qmp/send"] = actions_qmp.send,
		["qmp/poll"] = actions_qmp.poll,
		["qmp/consume"] = actions_qmp.consume,
		-- snapshots (snapshots.md)
		savevm = actions_snapshots.savevm,
		loadvm = actions_vm.loadvm,
		-- ensure an image is built: raw, cloud-init, custom (images.md)
		img = img.build,
	},
}
