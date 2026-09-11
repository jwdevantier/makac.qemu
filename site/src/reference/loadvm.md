<!-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier -->
<!-- SPDX-License-Identifier: CC0-1.0 -->

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

- **Idempotence = invocation identity.** At launch the package writes the
  canonical invocation — `qemu_bin`, the flattened `args`, and the
  `-loadvm <tag>` it appends — to `<run_dir>/invocation`. Every
  `state = "started"` request against an *already-running* VM byte-compares
  the requested invocation against that file:
  - **identical → no-op.** The VM is already running exactly what was asked
    for; the step returns the handle with `changed = false` (ssh target
    still set up). This is what makes `loadvm` idempotent: the step is
    safe to re-run — "ensure the VM is running from snapshot X".
  - **different → step failure.** The VM is running a *different*
    invocation (other args, other tag, or a plain boot); the failure
    names the difference and points at `state = "restarted"`. Nothing is
    silently re-launched underneath a running VM.

- **The tag is part of the identity.** "Same VM, new tag" is a different
  invocation, so `state = "started"` against a VM already running from
  another tag fails instead of quietly resuming the new one. Switching
  snapshots (or switching a running VM to a plain boot and back) is
  spelled `state = "restarted"` — stop unconditionally, then resume.

- **Caller supplies `args`.** The snapshot records guest state (RAM,
  devices) in the image — not the QEMU command line; there is nothing in
  the image to recover the machine config from. The `args` you pass are
  part of the identity, compared byte-for-byte (after flattening and
  `{{ disk }}` substitution). Only the package-injected control wiring —
  pidfile, monitor/serial/qmp sockets — is outside the identity and may
  differ freely.

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
