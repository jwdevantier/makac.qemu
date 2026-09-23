<!-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier -->
<!-- SPDX-License-Identifier: CC0-1.0 -->

# Actions at a glance

All eight actions, their `with` and `out` in one place.

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

| field | meaning |
| --- | --- |
| `with.vm` | the VM: a name (string) or a previous `out.handle` (table) — one key, either value. |
| `with.run_dir` | optional override of the VM's runtime directory (default `.makac/qemu/<name>`). |

`qemu:vm` and `qemu:loadvm` accept the same `with.vm` key (the historical
`with.name`/`with.handle` pair was replaced by it — pass `with.vm`; giving
it neither is a failure).

## Action table

| action | `with` | `out` |
| --- | --- | --- |
| [`qemu:vm`](vm.md) | `vm`, `state?`, `qemu_bin`, `args`, `ssh?`, `disk?`, `wait_ssh?`, `guest_shutdown?`, `force?` | `handle`, `target?`, `pid`, `disk?`, status fields |
| [`qemu:probe`](probe.md) | `vm` | `handle`, `pid`, status fields |
| [`qemu:loadvm`](loadvm.md) | `vm`, `state?`, `snapshot`, `qemu_bin`, `args`, `ssh?`, `disk?`, `wait_ssh?` | `handle`, `target?`, `pid`, `disk?`, status fields |
| [`qemu:savevm`](savevm.md) | `vm`, `tag?`, `timeout_s?` | `snapshot` (the tag) |
| [`qemu:qmp/send`](qmp.md) | `vm`, `commands`, `on_error?` | `results` (one per command) |
| [`qemu:qmp/poll`](qmp.md) | `vm`, `timeout_s?` | `events` |
| [`qemu:qmp/consume`](qmp.md) | `vm`, `n` | — |
| [`qemu:img`](img.md) | `name`, `builder`, builder-specific keys | `path` |

Every action takes a `run_dir` override when it addresses a VM.
