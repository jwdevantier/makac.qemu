<!-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier -->
<!-- SPDX-License-Identifier: BSD-2-Clause -->

# Actions at a glance

All seven actions, their `with` and `out` in one place.

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
| `with.name` | a VM name (identity). |
| `with.handle` | a previous `out.handle` (a VM name works everywhere a handle does). |
| `with.run_dir` | optional override of the VM's runtime directory (default `.makac/qemu/<name>`). |

Give `name` **or** `handle`, never both.

## Action table

| action | `with` | `out` |
| --- | --- | --- |
| [`qemu:vm`](vm.md) | `name`/`handle`, `state?`, `qemu_bin`, `args`, `ssh?`, `disk?`, `wait_ssh?` | `handle`, `target?`, `pid`, status fields |
| [`qemu:loadvm`](loadvm.md) | `name`/`handle`, `state?`, `snapshot`, `qemu_bin`, `args`, `ssh?`, `disk?` | `handle`, `target?`, `pid`, status fields |
| [`qemu:savevm`](savevm.md) | `vm`, `tag?`, `timeout_s?` | `snapshot` (the tag) |
| [`qemu:qmp/send`](qmp.md) | `vm`, `commands`, `on_error?` | `results` (one per command) |
| [`qemu:qmp/poll`](qmp.md) | `vm`, `timeout_s?` | `events` |
| [`qemu:qmp/consume`](qmp.md) | `vm`, `n` | — |
| [`qemu:img`](img.md) | `name`, `builder`, builder-specific keys | `path` |

Every action takes a `run_dir` override when it addresses a VM.
