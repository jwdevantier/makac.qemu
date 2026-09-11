<!-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier -->
<!-- SPDX-License-Identifier: CC0-1.0 -->

# `qemu:savevm`

Capture a running VM's full live state — RAM + device state — into its disk
image under a tag, via QMP `snapshot-save`. The guest is quiesced for the
capture and keeps running after. The snapshot lives *in the image file*: it
survives the VM dying and `makac` exiting, and travels with the image.

## `with`

```lua
with = {
    vm  = vm.out.handle,   -- required: a handle or a plain VM name
    tag = "ready-state",   -- optional; default: a timestamped tag
    timeout_s = 300,       -- optional; capture job timeout in seconds
    run_dir = "...",       -- optional override
}
```

## `out`

```lua
out = {
    snapshot = "ready-state",   -- the tag; pass to qemu:loadvm
}
```

`changed` is always `true`.

## Errors

- The VM must be **running**; anything else is a step failure quoting the
  status probe (down, wedged, or paused are all "not running").
- A QMP error (snapshot-uncapable device, duplicate tag, ...) is a step
  failure naming the command and QMP's error description.
- The capture job exceeding `timeout_s` is a step failure.

## Requirements

All writable block devices of the VM must support internal snapshots — in
practice: qcow2, including the overlay disks `qemu:vm` creates. A VM with a
raw or otherwise snapshot-uncapable writable device gets a step failure
quoting QMP's error and naming the device.

## Example

```lua
local snap = step {
    name = "snapshot booted state",
    uses = "qemu:savevm",
    with = { vm = vm.out.handle, tag = "base_snapshot" },
}
assert(snap.err == nil, tostring(snap.err))
```
