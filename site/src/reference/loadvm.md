<!-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier -->
<!-- SPDX-License-Identifier: BSD-2-Clause -->

# `qemu:loadvm`

Boot a VM resuming from a snapshot — `qemu:vm`'s start choreography with
one additional input: `with.snapshot`, the tag captured by
[`qemu:savevm`](savevm.md). The launch appends `-loadvm <tag>`; the guest
resumes where it was captured instead of booting.

## `with`

```lua
with = {
    name = "testvm",                 -- identity (name or handle)
    state = "started",               -- "started" (default) | "restarted"
    snapshot = "ready-state",        -- required: the tag from qemu:savevm

    qemu_bin = "/usr/bin/qemu-system-x86_64",   -- required
    args = { ... },                  -- required: the machine config the
                                     -- snapshot was taken with

    ssh  = { port = 2222 },          -- optional, as in qemu:vm
    disk = { backing = img.out.path },   -- optional
    run_dir = "...",                 -- optional override
}
```

No `"stopped"` state here — stopping is `qemu:vm`'s.

## `out`

Same as [`qemu:vm`](vm.md): `handle`, `target?`, `pid`, status fields.

## Rules

- **Same VM name as the save side.** The snapshot lives in the VM's disk
  image; for an overlay-booted VM that is `.makac/qemu/<name>/disk.qcow2`
  of the VM it was saved from. Resume on that same run dir, and
  `qemu:loadvm` **keeps the existing overlay** rather than recreating it —
  recreating would destroy the snapshot.
- **Caller supplies `args`.** Resuming requires the machine configuration
  the snapshot was taken with; the image records state, not configuration.
  Control interfaces (pidfile, sockets, serial log) are exempt and may
  differ freely.
- **Idempotence.** `state = "started"` on a running VM is a no-op as with
  `qemu:vm`. The canonical invocation includes the snapshot tag, so "same
  VM, new tag" is a *different* invocation — spell it `state =
  "restarted"`.
- A tag not present in the image fails at launch: QEMU exits early, and the
  step failure quotes the qemu-stderr log.

## Example

```lua
local resumed = step {
    name = "resume from snapshot",
    uses = "qemu:loadvm",
    with = {
        name     = "testvm",
        qemu_bin = qemu_bin,
        args     = vm_args,          -- same machine as the save side
        snapshot = snap.out.snapshot,  -- -loadvm base_snapshot
        state    = "restarted",      -- fresh qemu process
        ssh      = { port = 2222 },
    },
}
local target = resumed.out.target    -- an ordinary makac remote target
```
