<!-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier -->
<!-- SPDX-License-Identifier: BSD-2-Clause -->

# Introduction

makac.qemu is a [makac](https://jwdevantier.github.io/makac/) package that turns
makac into a **VM orchestrator**. It adds steps to build disk images, manage
QEMU virtual machines, take and resume snapshots, and talk to a running VM over
QMP — everything needed to exercise real hardware (a device, a driver, a kernel
path) inside a real VM, end to end.

It ships under the package id `qemu`, so its actions are referenced as
`qemu:<action>` in workflows.

## The pattern

The package exists for one workflow shape above all:

1. **build** a bootable disk image (a cloud-init-customized OS),
2. **boot** the VM once,
3. **snapshot** the booted state — RAM + device state — into the image,
4. for each test: **resume** from the snapshot in seconds (no re-boot),
5. **hotplug** devices via QMP while the guest runs,
6. watch the guest **pick them up**, assert, run the test,
7. **tear down**.

The snapshot step is what makes the loop fast: one slow boot is amortized
over many instant test starts, each beginning at a known, deterministic
machine state. The hotplug step is what makes it *real*: the machine under
test is reconfigured while running, and the workflow observes the guest
reacting to it.

[The NVMe test loop](examples/nvme-test.md) is the canonical example — it
boots a VM, snapshots it, then runs a series of tests that each resume from
the snapshot, hotplug an NVMe controller at a known PCI address, bind it to
`vfio-pci` in the guest, and exercise it.

## What's in the box

| Action | Purpose |
| --- | --- |
| [`qemu:vm`](reference/vm.md) | Bring a VM to a state: `started`, `stopped`, `restarted`. A started VM with ssh configured is returned as a makac remote target. |
| [`qemu:img`](reference/img.md) | Ensure a disk image is built: a raw blank, a cloud-init-customized OS image, or a fully custom builder. Content-cached. |
| [`qemu:savevm`](reference/savevm.md) | Capture a running VM's state (RAM + devices) into its image under a tag. |
| [`qemu:loadvm`](reference/loadvm.md) | Boot a VM resuming from a snapshot — the "boot once, test many times" trick. |
| [`qemu:qmp/send`](reference/qmp.md) | Send QMP commands to a VM (e.g. hotplug a device). |
| [`qemu:qmp/poll`](reference/qmp.md) | Drain events from a VM's QMP event stream. |
| [`qemu:qmp/consume`](reference/qmp.md) | Discard events the workflow has finished treating. |

Plus library modules — [`require("pkgs:qemu/qmp")`](reference/library.md)
(QMP command constructors), `require("pkgs:qemu/img")` (custom image
builders), `require("pkgs:qemu/serial")` (waiting on the guest's serial
console).

## The big ideas

- **Everything is a step.** The package has no hidden daemons: every
  capability is a makac action invoked from a workflow, and every action
  takes and returns plain Lua tables.
- **State survives runs.** VMs, images and snapshots live on disk under
  `.makac/`; a VM started by one `makac run` can be operated on by the next.
- **Content-addressable caching.** Images rebuild only when their inputs
  change; snapshots travel with the image file.
- **QMP is the control surface.** Hotplug, snapshots and status all go over
  QEMU's own protocol — no guessing, no poking at QEMU's monitor.

## Dependencies

makac.qemu shells out to QEMU tooling at run time. The package itself needs:
`qemu-system-<arch>` (the binary is configurable per step), `qemu-img`
(overlay disks, image resize), `genisoimage` (cloud-init ISO), and `ssh`
(guest access). Everything else is makac + Lua.

## Getting started

Head to [Getting Started](getting-started.md) to declare the package in your
project and run your first VM.
