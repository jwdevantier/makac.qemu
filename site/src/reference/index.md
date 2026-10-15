<!-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier -->
<!-- SPDX-License-Identifier: CC0-1.0 -->

# Actions

The package's actions (steps), and the result shape they share.

Examples assume the package is declared with id `qemu` (see
[Getting Started](../getting-started.md)).

| Action                       | Purpose                                                                                                                          |
| ---------------------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| [`qemu:vm`](vm.md)           | Bring a VM to a state: `started`, `stopped`, `restarted`. A started VM with ssh configured is returned as a makac remote target. |
| [`qemu:probe`](probe.md)     | Read a VM's status. Never `changed`, and never fails on a down or wedged VM.                                                     |
| [`qemu:img`](img.md)         | Ensure a disk image is built: a raw blank, a cloud-init-customized OS image, or a fully custom builder. Content-cached.          |
| [`qemu:savevm`](savevm.md)   | Capture a running VM's state (RAM + devices) into its image under a tag.                                                         |
| [`qemu:loadvm`](loadvm.md)   | Boot a VM resuming from a snapshot: the "boot once, test many times" trick.                                                      |
| [`qemu:qmp/send`](qmp.md)    | Send QMP commands to a VM (for example, hotplug a device).                                                                       |
| [`qemu:qmp/poll`](qmp.md)    | Read events from a VM's QMP event stream.                                                                                        |
| [`qemu:qmp/consume`](qmp.md) | Discard events the workflow has finished treating.                                                                               |

## The result shape

Every action returns the normalized makac result shape:

```lua
{
    err = nil,       -- string, set iff the action failed; absent otherwise
    changed = false, -- bool
    skipped = false, -- bool
    out = {},        -- table: action-specific values
}
```

## Common fields

| field          | meaning                                                                            |
| -------------- | ---------------------------------------------------------------------------------- |
| `with.vm`      | the VM: a name (string) or a previous `out.handle` (table). One key, either value. |
| `with.run_dir` | optional override of the VM's runtime directory (default `.makac/qemu/<name>`).    |

`qemu:vm` and `qemu:loadvm` accept the same `with.vm` key.
