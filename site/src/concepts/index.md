<!-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier -->
<!-- SPDX-License-Identifier: CC0-1.0 -->

# Concepts

makac.qemu's model has four nouns:

- **A [VM](vms.md)** — a QEMU process plus its runtime files, identified by a
  name, addressed through a *handle*. Brought to a state (`started` /
  `stopped` / `restarted`) by `qemu:vm`; resumed from a snapshot by
  `qemu:loadvm`.
- **An [image](images.md)** — a disk-image artifact built from a spec and
  cached by hashes of its inputs. Built by `qemu:img`.
- **A [snapshot](snapshots.md)** — a VM's full state (RAM + devices) baked
  into its disk image under a tag. Captured by `qemu:savevm`, resumed by
  `qemu:loadvm`.
- **QMP** — QEMU's control protocol, surfaced as `qemu:qmp/send`, `poll`
  and `consume`. How the workflow hotplugs devices, reads events, and gets
  status.

State survives `makac run` exiting: everything lives under the project's
data directory (`.makac/qemu/...`), keyed by *content* for images and by
*name* for VMs.

## The four pages

- [VMs and handles](vms.md) — states, the argv `args`, overlay boot disks,
  the ssh target, handles and status.
- [Images](images.md) — the `raw` and `cloud-init` builders, caching, custom
  builders.
- [Snapshots](snapshots.md) — the boot-once/test-many loop, tags, overlay
  interplay.
- [QMP](qmp.md) — the event discipline, hotplug, the command-constructor
  library.

## A minimal workflow using most of the model

```lua
local img = step {
    name = "build boot disk",
    uses = "qemu:img",
    with = { name = "bootbase", builder = "raw", img_size = "1G" },
}

local vm = step {
    name = "boot testvm",
    uses = "qemu:vm",
    with = {
        name     = "testvm",
        qemu_bin = "qemu-system-x86_64",
        disk     = { backing = img.out.path },
        args = {
            "-nodefaults",
            { "-machine", "q35,accel=kvm" },
            { "-drive",  "id=bdrv.boot,file={{ disk }},format=qcow2,if=none" },
            { "-device", "nvme,id=nvme-ctrl.0" },
            { "-device", "nvme-ns,id=ns.boot,drive=bdrv.boot,nsid=1,bus=nvme-ctrl.0" },
        },
    },
}

local snap = step {
    name = "snapshot booted state",
    uses = "qemu:savevm",
    with = { vm = vm.out.handle, tag = "base" },
}

step { uses = "qemu:vm", with = { vm = "testvm", state = "stopped" } }
```

Build an image, boot the VM onto a throwaway overlay of it, snapshot the
booted state into the overlay, stop. Every later test resumes from `"base"`
with `qemu:loadvm` — see the [NVMe test loop](../examples/nvme-test.md) for
the full pattern.
