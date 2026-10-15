<!-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier -->
<!-- SPDX-License-Identifier: CC0-1.0 -->

# QMP helpers

`require("pkgs/qemu/qmp")` provides helpers for building QMP commands and
reading replies. Constructors return a `{ execute = ..., arguments = ... }`
table, which you submit with [`qemu:qmp/send`](../reference/qmp.md), the step
that names the VM:

```lua
local qmp = require("pkgs/qemu/qmp")

step {
    uses = "qemu:qmp/send",
    with = {
        vm = vm.out.handle,
        commands = {
            qmp.dev_add("nvme", { id = "nvme-ctrl.2", serial = "test" }),
            qmp.bdev_add("bdev.test", "raw", { file = { driver = "file", filename = "x.img" } }),
        },
    },
}
```

Command constructors:

| constructor                        | builds                                            |
| ---------------------------------- | ------------------------------------------------- |
| `qmp.dev_add(driver, args)`        | `device_add` with `driver` injected               |
| `qmp.bdev_add(node, driver, args)` | `blockdev-add` with `node-name`/`driver` injected |
| `qmp.hmp("savevm mysnapshot")`     | `human-monitor-command`                           |
| `qmp.query_status()`               | `query-status`                                    |

The other helpers do not build commands:

- `qmp.merge(tables)` shallow-merges an array of tables into a fresh one.
  Later sources win; the sources are not mutated.
- `qmp.ok(result)` is true when `result.error == nil`.
- `qmp.err_desc(result)` returns a failed command's error description.

See [Concepts: QMP](../concepts/qmp.md) for how `send`, `poll`, and `consume`
fit together.
