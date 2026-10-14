<!-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier -->
<!-- SPDX-License-Identifier: CC0-1.0 -->

# Snapshots

A **snapshot** saves a running VM's state (RAM and devices) into its disk
image under a tag. A VM can later start from that tag instead of booting.
This uses QEMU's internal snapshots (`savevm`/`loadvm`).

Every writable disk must support internal snapshots. In practice that means
qcow2, which includes the overlay disks `qemu:vm` creates. If a writable disk
is raw or otherwise unsupported, the step fails, quoting QMP's error and
naming the disk.

## Capture: `qemu:savevm`

```lua
local snap = step {
    name = "snapshot the VM",
    uses = "qemu:savevm",
    with = {
        vm  = vm.out.handle,   -- handle or name; the VM must be running
        tag = "ready-state",   -- optional; default: a timestamped tag
        -- timeout_s = 300,    -- optional; how long to wait for the capture
    },
}
-- snap.out.snapshot == "ready-state"   (the tag)
```

`qemu:savevm` pauses the guest while it captures, then lets it keep running.
The snapshot survives the VM stopping and `makac` exiting, because it is
written into the image file itself. The step waits for the capture to finish,
up to `timeout_s` (default 300).

## Resume: `qemu:loadvm`

```lua
local vm2 = step {
    name = "resume vm",
    uses = "qemu:loadvm",
    with = {
        vm       = "testvm",            -- the VM name used on the save side
        qemu_bin = qemu_bin,
        args     = saved_args,          -- the machine config the snapshot was taken with
        snapshot = snap.out.snapshot,   -- required: the tag
        state    = "started",           -- "started" (default) | "restarted"
        ssh      = { port = 2222 },     -- optional, as in qemu:vm
    },
}
```

`qemu:loadvm` is `qemu:vm` plus a required `snapshot` tag. It adds
`-loadvm <tag>` to the launch, so the guest resumes instead of booting.

Three things to get right:

- **Resume on the same VM name.** The snapshot is stored in the VM's disk
  image, so the VM's disks must resolve to the image it was saved in. For an
  overlay-booted VM that is `.makac/qemu/<name>/disk.qcow2`. `qemu:loadvm`
  keeps the existing overlay instead of recreating it.
- **Pass the machine configuration in `args`.** A snapshot stores guest
  state, not the QEMU command line, so the package cannot recover it. The
  `args` are part of the invocation identity and must match byte for byte.
- **A different tag is a different invocation.** To resume a running VM from
  another tag, use `state = "restarted"`. With `state = "started"`, a
  mismatch fails the step instead of silently relaunching the VM.

A tag that is not in the image fails at launch: QEMU exits, and the step
failure quotes the qemu-stderr log.

## Delete: `qemu:qmp/send`

There is no dedicated action. Send the QMP command through the existing
surface:

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

Build an image and boot it once. Save a `"base"` snapshot, then stop the VM.
For each test, resume from `"base"`, run the test, and stop the VM again.
Every test starts from the same machine state, and resuming takes seconds
instead of a full boot. See [the NVMe test loop](../examples/nvme-test.md).
