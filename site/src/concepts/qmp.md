<!-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier -->
<!-- SPDX-License-Identifier: CC0-1.0 -->

# QMP

QMP is QEMU's control protocol: JSON over a unix socket — the socket every
`qemu:vm` VM opens at `.makac/qemu/<name>/qmp.socket`. The package surfaces
it as three actions and a library, and a workflow writes and reads **Lua
tables throughout** — the JSON wire format is not part of its surface.

## The connection model

A started VM has exactly one QMP connection, opened by `qemu:vm` as part of
starting it and held until the handle is closed (stop succeeding, or the
run ending). All qmp actions against the VM share it; commands and polls
serialize on it in step order. A run that *attaches* to an already-running
VM by name opens its connection at attach time.

Events reach the buffer only while connected: anything QEMU emitted between
runs, or before the run attached, is never received. To observe an event,
arrange to poll *after* the step that raises it.

## `qemu:qmp/send`

Send commands to a VM, in array order:

```lua
local res = step {
    name = "attach 4k test namespace",
    uses = "qemu:qmp/send",
    with = {
        vm = vm.out.handle,   -- a handle, or a plain VM name
        commands = {
            { execute = "device_add", arguments = { driver = "nvme-subsys", id = "subsys.test" } },
            { execute = "device_add", arguments = { driver = "nvme", id = "nvme-ctrl.2",
                                                     serial = "test", bus = "pcie-root-port.2",
                                                     subsys = "subsys.test" } },
            { execute = "blockdev-add", arguments = { ["node-name"] = "bdev.test",
                                                      driver = "raw", ... } },
        },
        on_error = "fail",   -- "fail" (default) | "collect"
    },
}
-- res.out.results == { { ["return"] = ... }, ... }   -- one per command, in order
```

- Each command is `{ execute = "<qmp command>", arguments = {...}? }`.
  `arguments` nests freely; key names pass verbatim — QMP keys like
  `node-name` need bracket syntax but otherwise just work.
- A QMP error reply yields `error = { class =, desc = }`. `on_error =
  "fail"` aborts the step at the first failure (remaining commands are not
  sent); `"collect"` runs them all and carries failures in
  `out.results[i].error`.
- Sending **discards the event buffer** — a new command declares that
  events before it are not of interest. Events arriving while the command
  is in flight are buffered and observed with `poll`.

## `qemu:qmp/poll` and `qemu:qmp/consume`

Alongside command replies, the connection receives asynchronous events
(`DEVICE_DELETED`, `RESET`, ...). They accumulate in a per-VM buffer, and
two actions manage them:

```lua
local p = step {
    uses = "qemu:qmp/poll",
    with = { vm = vm.out.handle, timeout_s = 5 },   -- listen up to 5s; default 0
}
-- p.out.events == { { name = "DEVICE_DELETED", data = {...} }, ... }
```

```lua
step {
    uses = "qemu:qmp/consume",
    with = { vm = vm.out.handle, n = #p.out.events },  -- discard the n oldest
}
```

The discipline:

- `poll` drains the socket (bounded by `timeout_s`; a timeout is **not** an
  error — it returns with what arrived). `out.events` is the VM's **pending
  events** — the whole buffer after the drain, including events that arrived
  while an earlier `send` awaited its replies. They **remain in the buffer**:
  what a poll shows is exactly what a matching `consume(n)` discards.
- `consume` discards the `n` oldest buffered events — the ones the workflow
  has finished treating (it knows their count from a poll).
- `send` discards the buffer at the moment it issues its commands.

The typical pattern — raise a condition, then witness it:

```lua
step {
    uses = "qemu:qmp/send",
    with = { vm = vm.out.handle,
             commands = { { execute = "device_del", arguments = { id = "ns.test" } } } },
}
local p = step { uses = "qemu:qmp/poll",
                 with = { vm = vm.out.handle, timeout_s = 10 } }
assert(p.out.events[1].name == "DEVICE_DELETED")
step { uses = "qemu:qmp/consume",
       with = { vm = vm.out.handle, n = #p.out.events } }
```

## The library

`require("pkgs/qemu/qmp")` constructs command tables. **It performs no I/O**
— there is no socket, no target VM, no sending. Constructors map arguments
to a `{ execute = ..., arguments = ... }` table, which a workflow passes to
`qemu:qmp/send` — the only place commands are sent, and the only place a VM
is named:

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

Constructors:

| constructor | builds |
| --- | --- |
| `qmp.dev_add(driver, args)` | `device_add` with `driver` injected |
| `qmp.bdev_add(node, driver, args)` | `blockdev-add` with `node-name`/`driver` injected |
| `qmp.hmp("savevm mysnapshot")` | `human-monitor-command` |
| `qmp.query_status()` | `query-status` |
| `qmp.merge(tables)` | a fresh shallow merge of the tables (later sources win) |
| `qmp.ok(result)` | `result.error == nil` |
| `qmp.err_desc(result)` | the error description |

Because they are pure table-builders they compose with ordinary Lua
(merging, loops, conditionals), and the same command table can be sent to
any number of VMs by any number of `qemu:qmp/send` steps. The `merge` the
constructors are built on is exposed too, for compositions that reuse it
for their own option tables.

## Hotplug notes

Two QEMU facts worth stating:

- **`addr` is a string.** To give a device a deterministic PCI BDF, pass
  `addr` explicitly — and as a string (`addr = "0.0"`), never a number. The
  guest then finds the device at a known address, pollable over ssh
  (`lspci -nn`).
- **Q35 cannot hotplug PCIe root ports.** The buses devices attach to must
  exist from boot: pre-create them in the VM's `args` (`pcie-root-port`
  devices with ids) and hotplug onto those buses. Snapshotting after boot
  freezes this topology into base state, so every resumed VM has the ports
  ready.

Waiting for a *guest-side* condition is expressed with polls from steps:
`poll`/`consume` when there's a QMP event; a ssh shell loop or
`serial.wait_for` when the evidence is inside the guest.
