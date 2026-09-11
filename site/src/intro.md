<!-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier -->
<!-- SPDX-License-Identifier: CC0-1.0 -->

# Introduction

makac.qemu is a [makac](https://jwdevantier.github.io/makac/) package that turns
makac into a **VM orchestrator**. It adds steps to build disk images, manage
QEMU virtual machines, take and resume snapshots, and talk to a running VM over
QMP — everything needed to exercise QEMU device code or an OS kernel inside
a VM, end to end.

## The pattern

The package exists for one workflow shape above all:

1. **build** a bootable disk image (a cloud-init-customized OS),
    - supports building images from cloud-init and raw disk images
2. **boot** the VM once - and make a snapshot
    - Ideally boot with an overlay image to have the snapshot persisted there
3. For each test:
    - **load the VM from saved state** - bypassing boot-time
    - (for testing QEMU devices) - hotplug devices into the VM via QMP calls
        - ensures there is no lingering device state between tests.
    - await the VM adding the device
    - run tests
4. Kill the VM

Snapshotting accomplishes two things - amortizing boot time cost, over
many tests and removing test interference - if you add the device(s) under
test dynamically using QMP after loading the VM.

[The NVMe test loop](examples/nvme-test.md) is the canonical example — it
boots a VM, snapshots it, then runs a series of tests that each resume from
the snapshot, hotplug an NVMe controller at a known PCI address, bind it to
`vfio-pci` in the guest, and exercise it.

## What makac.qemu provides
For illustrative purposes, this assumes you add the package under the id 'qemu', see [Getting Started](getting-started.md). Adjust to match the id you assign to the dependency.

### Actions
| Action | Purpose |
| --- | --- |
| [`qemu:vm`](reference/vm.md) | Bring a VM to a state: `started`, `stopped`, `restarted`. A started VM with ssh configured is returned as a makac remote target. |
| [`qemu:img`](reference/img.md) | Ensure a disk image is built: a raw blank, a cloud-init-customized OS image, or a fully custom builder. Content-cached. |
| [`qemu:savevm`](reference/savevm.md) | Capture a running VM's state (RAM + devices) into its image under a tag. |
| [`qemu:loadvm`](reference/loadvm.md) | Boot a VM resuming from a snapshot — the "boot once, test many times" trick. |
| [`qemu:qmp/send`](reference/qmp.md) | Send QMP commands to a VM (e.g. hotplug a device). |
| [`qemu:qmp/poll`](reference/qmp.md) | Drain events from a VM's QMP event stream. |
| [`qemu:qmp/consume`](reference/qmp.md) | Discard events the workflow has finished treating. |

### Library code
* [`require("pkgs:qemu/qmp")`](reference/library.md)
    * Helpers to construct QMP commands
* `require("pkgs:qemu/img")`
    * Custom image builders for raw- and cloud-init images.
    * You can create your own builders to use with the `qemu:img` action
* `require("pkgs:qemu/serial")`
    * Code to wait on particular strings appearing on the QEMU VM's serial console

## The big ideas

- **Declarative**
  - Every action describes a desired state, not definite action to take
- **VMs survive runs**
  - A VM is only stopped if the workflow does it
  - You can split starting and stopping across separate workflows and work on the VM in between
- **Caching**
  - Cloud-init images rebuild *only* when their inputs change; otherwise a NO-OP
* **Overlays for VM state**
  - QEMUs ability to save VM state requires writing it into the QCOW2 image
  - Use a qcow2 image overlay on top of the base cloud-init image to
      - avoid tampering the original image
      - allow multiple VMs to use the same base image, even while saving VM state
* **Use QMP to dynamically add devices**

## Dependencies

- [makac](https://jwdevantier.github.io/makac)
    - The workflow runner
- `qemu-system-<arch>`
  - QEMU binary - can be set per-step
- `qemu-img`
  - for creating QEMU images (raw *and* qcow2)
- `genisoimage`
  - for creating the cloud-init ISO containing the assets and cloud-init scripts which customize the base, upstream cloud-init image.
- `ssh`, `scp`
  - communicating with the VM itself

## Getting started

Head to [Getting Started](getting-started.md) to declare the package in your
project and run your first VM.
