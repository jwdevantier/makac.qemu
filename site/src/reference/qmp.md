<!-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier -->
<!-- SPDX-License-Identifier: CC0-1.0 -->

# `qemu:qmp/send`, `qemu:qmp/poll`, `qemu:qmp/consume`

The three QMP actions. QMP is QEMU's control protocol; the package's QMP
surface is explained in [Concepts: QMP](../concepts/qmp.md).

## `qemu:qmp/send`

Send commands to a VM, in array order, on the VM's connection.

```lua
with = {
    vm = vm.out.handle,      -- required: handle or VM name
    commands = {             -- required: non-empty array of command tables
        { execute = "device_add", arguments = { driver = "nvme", id = "nvme0" } },
    },
    on_error = "fail",       -- "fail" (default) | "collect"
}
```

```lua
out = {
    results = {              -- one per command, in order
        { ["return"] = {...} or nil,       -- the command's return payload
          error = { class = ..., desc = ... } or nil },
    },
}
```

- Each command must be a table with a string `execute`; `arguments` is an
  optional table that nests freely.
- `on_error = "fail"`: the first error reply aborts the step (remaining
  commands are not sent), message naming the command and QMP's `desc`.
  `"collect"`: execution continues; failures land in
  `out.results[i].error`.
- A VM whose QMP socket doesn't connect is a step failure naming the VM
  and its socket.
- Sending discards the event buffer (see Concepts: QMP).

`changed` is always `true`.

## `qemu:qmp/poll`

Drain pending events from the VM's event stream, bounded by a timeout.

```lua
with = {
    vm = vm.out.handle,      -- required: handle or VM name
    timeout_s = 5,           -- how long to listen; default 0
}
```

```lua
out = {
    events = {               -- the VM's pending events after the drain
        { name = "DEVICE_DELETED", data = { ... } },
    },
}
```

A timeout is **not** an error — the action returns with whatever arrived.
`out.events` is the VM's **pending events** — the whole buffer after the
drain, including events that arrived while an earlier `send` awaited its
replies. They remain in the buffer: what the step shows is exactly what a
matching `consume(n)` discards.

`changed` is always `false` (polling changes nothing).

## `qemu:qmp/consume`

Discard the `n` oldest buffered events — the ones the workflow has finished
treating.

```lua
with = {
    vm = vm.out.handle,      -- required: handle or VM name
    n = 3,                   -- required: non-negative integer
}
```

Discarding more events than are buffered raises (a step failure naming the
VM). `changed` is always `false`.

## The pattern

```lua
-- raise a condition, then witness it
step { uses = "qemu:qmp/send",
       with = { vm = h, commands = { { execute = "device_del", arguments = { id = "ns0" } } } } }
local p = step { uses = "qemu:qmp/poll", with = { vm = h, timeout_s = 10 } }
assert(p.out.events[1].name == "DEVICE_DELETED")
step { uses = "qemu:qmp/consume", with = { vm = h, n = #p.out.events } }
```
