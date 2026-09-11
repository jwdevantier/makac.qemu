<!-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier -->
<!-- SPDX-License-Identifier: BSD-2-Clause -->

# Getting Started

This page walks you through declaring the package in a makac project and
starting your first VM.

## Requirements

- A [makac](https://jwdevantier.github.io/makac/) install (any version with
  the package system).
- On the machine that runs makac:
  - `qemu-system-x86_64` (or the arch you target) — path configurable per
    step,
  - `qemu-img` — overlay disks and image resize,
  - `genisoimage` — building cloud-init ISOs (only for the `cloud-init`
    image builder),
  - `ssh` — guest access (only when you use the ssh target).

## Declare the package

Packages are declared in `.makac/packages.lua` inside your project's data
directory:

```lua
-- .makac/packages.lua
return {
    {
        id = "qemu",
        fetcher = "fetchgit",
        with = {
            url = "https://github.com/jwdevantier/makac.qemu",
            rev = "main",
        },
    },
}
```

Then fetch it:

```bash
$ makac fetch
defined packages (#1):
  1. qemu (fetcher: fetchgit)
fetching qemu via fetchgit...
fetched qemu
```

> **During development**, point at your checkout with the `filesystem`
> fetcher instead — nothing is copied, edits are live:
>
> ```lua
> {
>     id = "qemu",
>     fetcher = "filesystem",
>     with = { path = "path/to/makac.qemu" },
> }
> ```

See [makac's fetchers documentation](https://jwdevantier.github.io/makac/reference/fetchers.html)
for the full argument tables.

## Run a workflow that starts a VM

Create `vm.lua`:

```lua
step {
    name = "start test VM",
    uses = "qemu:vm",
    with = {
        name  = "testvm",
        state = "started",
        qemu_bin = "qemu-system-x86_64",
        args = {
            "-nodefaults",
            { "-machine", "q35,accel=kvm,kernel-irqchip=split" },
            "-cpu", "host",
            "-smp", "2",
            "-m", "4096",
        },
    },
}
```

Run it:

```bash
$ makac run vm.lua
run: [host] start test VM
changed: [host] start test VM (0.5s)
```

The VM is now running, detached from makac. Its runtime files — pidfile,
QMP socket, serial log, invocation record — live under
`.makac/qemu/testvm/`. The workflow did not configure ssh, so no target was
returned; to actually *do* something inside the guest, add `with.ssh` (see
[`qemu:vm`](reference/vm.md)).

## Stop it

Stopping is a step too — graceful powerdown, with escalation if the guest
wedges:

```lua
step {
    uses = "qemu:vm",
    with = { name = "testvm", state = "stopped" },
}
```

```bash
$ makac run stop.lua
changed: [host] stop test VM (1.2s)
```

## Next steps

- [Concepts](concepts/index.md) — how VMs, images, snapshots and QMP fit
  together.
- [The NVMe test loop](examples/nvme-test.md) — the full
  build → boot → snapshot → resume → hotplug → test → teardown cycle.
