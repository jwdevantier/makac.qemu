<!-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier -->
<!-- SPDX-License-Identifier: CC0-1.0 -->

# Introduction

makac.qemu is a [makac](https://jwdevantier.github.io/makac/) package that turns
makac into a **VM orchestrator**. It adds steps to build disk images, manage
QEMU virtual machines, take and resume snapshots, and talk to a running VM over
QMP. It is everything needed to exercise QEMU device code or an OS kernel
inside a VM, end to end.

## Core ideas

- **Desired state.** The VM and image actions describe the state you want,
  not the steps to get there.
- **VMs survive runs.** A VM is stopped only if a workflow stops it. You can
  start and stop it across separate workflows and work on it in between.
- **Caching.** A cloud-init image rebuilds only when its inputs change;
  otherwise the build is a no-op.
- **Overlays for VM state.** Saving VM state writes it into the qcow2 image,
  so boot the VM on a qcow2 overlay of the base. The base image stays
  untouched, and several VMs can share it while each saves its own state.
- **QMP for dynamic devices.** Add and remove devices on a running VM
  through QMP.

## Getting started

Head to [Getting Started](getting-started.md) to declare the package in your
project and run your first VM.

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
