<!-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier -->
<!-- SPDX-License-Identifier: CC0-1.0 -->

# Snapshots

A **snapshot** is a VM's full live state — RAM and device state — *baked
into its disk image* under a tag. This is QEMU's internal-snapshot
mechanism: QMP `snapshot-save` / `snapshot-load` (`savevm`/`loadvm`), and
`-loadvm <tag>` on the command line.

The shape this gives workflows: bring a VM to a known state, snapshot it,
then boot VMs resuming *from the snapshot in the image* — skipping boot —
use them, throw them away.

**Requirement.** All writable block devices of the VM must support internal
snapshots — in practice: qcow2, including the overlay disks `qemu:vm`
creates. A VM with a raw or otherwise snapshot-uncapable writable device
gets a step failure quoting QMP's error and naming the device.

## Capturing: `qemu:savevm`

```lua
local snap = step {
    name = "snapshot the VM",
    uses = "qemu:savevm",
    with = {
        vm  = vm.out.handle,   -- handle or name; must be running
        tag = "ready-state",   -- optional; default: timestamped tag
    },
}
-- snap.out.snapshot == "ready-state"   (the tag)
```

The guest is quiesced for the capture and keeps running after. The snapshot
lives *in the image file*: it survives the VM dying and `makac` exiting,
and travels with the image — copy the image, the snapshot comes along.
Captures have a `timeout_s` (default 300).

## Resuming: `qemu:loadvm`

```lua
local vm2 = step {
    name = "resume vm",
    uses = "qemu:loadvm",
    with = {
        name     = "testvm",
        qemu_bin = qemu_bin,
        args     = saved_args,          -- the machine config the snapshot was taken with
        snapshot = snap.out.snapshot,   -- required: the tag
        state    = "started",           -- "started" (default) | "restarted"
        ssh      = { port = 2222 },     -- optional, as in qemu:vm
    },
}
```

`qemu:loadvm` is `qemu:vm` with one additional input: `snapshot` makes the
launch append `-loadvm <tag>`, so the guest resumes where it was captured
rather than booting.

- The caller supplies `args`. Resuming requires the machine configuration
  the snapshot was taken with — the image records state, not configuration.
  Control interfaces (pidfile, sockets, serial log) are exempt and may
  differ freely.
- The image holding the tag must be the one the VM's disks resolve to. For
  an overlay-booted VM the snapshot lives in `.makac/qemu/<name>/disk.qcow2`
  — so resume on the **same VM name** (same run dir), and `qemu:loadvm`
  *keeps* the existing overlay rather than recreating it.
- `state = "started"` on a running VM is idempotent, as with `qemu:vm`. The
  canonical invocation includes the snapshot tag, so "same VM, new tag" is a
  different invocation and must be spelled `state = "restarted"`.
- A tag not present in the image fails at launch — QEMU exits, and the step
  failure quotes the qemu-stderr log.

## Housekeeping

Deleting a snapshot is a QMP command through the existing surface:

```lua
step {
    uses = "qemu:qmp/send",
    with = {
        vm = vm.out.handle,
        commands = {
            { execute = "snapshot-delete",
              arguments = { name = "old-tag", devices = { } } },
        },
    },
}
```

## The boot-once, test-many loop

The canonical use — see [the NVMe test loop](../examples/nvme-test.md):

1. build an image, boot it once,
2. `qemu:savevm` a `"base"` tag,
3. stop the VM,
4. for each test: `qemu:loadvm` from `"base"` (seconds, not minutes),
   run the test, `qemu:vm state = "stopped"`.

Each test starts at a known, deterministic machine state — no re-boot, no
re-provisioning.
