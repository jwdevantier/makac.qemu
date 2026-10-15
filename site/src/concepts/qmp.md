<!-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier -->
<!-- SPDX-License-Identifier: CC0-1.0 -->

# QMP

QMP is QEMU's control protocol. It exchanges JSON messages: mostly
request/response, with asynchronous events on occasion. The package provides
three actions for sending commands and handling events, plus
[helpers](../api/qmp.md) for constructing QMP commands. You work in Lua
tables; the JSON wire format is not exposed.

## Connections and events

Each VM has one QMP connection per run. `qemu:vm` opens it when it starts the
VM; a run that attaches to a running VM opens it on its first QMP step. Every
QMP step against the VM shares that connection and runs in step order.

Events arrive only while the connection exists. Anything QEMU emitted between
runs, or before the run attached, is not delivered. To catch an event, poll
after the step that raises it.

Events collect in a per-VM buffer, and the three actions move it:

| action             | effect on the buffer                                                             |
| ------------------ | -------------------------------------------------------------------------------- |
| `qemu:qmp/send`    | clears it when it issues its commands, then buffers events that arrive in flight |
| `qemu:qmp/poll`    | drains the socket and returns the whole buffer; the events stay in place         |
| `qemu:qmp/consume` | removes the oldest `n`                                                           |

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
  `arguments` nests freely; key names pass verbatim. QMP keys like
  `node-name` need bracket syntax but otherwise just work.
- A QMP error reply yields `error = { class =, desc = }`. `on_error =
  "fail"` aborts the step at the first failure (remaining commands are not
  sent); `"collect"` runs them all and carries failures in
  `out.results[i].error`.

## `qemu:qmp/poll` and `qemu:qmp/consume`

`poll` reads QEMU's asynchronous events (`DEVICE_DELETED`, `RESET`, ...).
`consume` discards events you have handled. Use them together: poll to see
what happened, act on it, then consume so later polls do not return it again.

`poll` returns the VM's buffered events in `out.events`, oldest first.
`timeout_s` bounds how long it waits and defaults to 0, which returns
immediately; pass a `timeout_s` when you are waiting for an event.

```lua
local p = step {
    uses = "qemu:qmp/poll",
    with = { vm = vm.out.handle, timeout_s = 5 },
}
-- p.out.events == { { name = "DEVICE_DELETED", data = {...} }, ... }
```

`poll` does not remove anything. After handling events, call `consume` with
how many to discard, counting from the oldest.

```lua
step {
    uses = "qemu:qmp/consume",
    with = { vm = vm.out.handle, n = #p.out.events },   -- everything polled
}
```

The full pattern: raise a condition, poll for its event, consume it.

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
