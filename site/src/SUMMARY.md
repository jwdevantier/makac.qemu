<!-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier -->
<!-- SPDX-License-Identifier: CC0-1.0 -->

# Summary

- [Introduction](intro.md)
- [Getting Started](getting-started.md)
- [Concepts](concepts/index.md)
  - [VMs and handles](concepts/vms.md)
  - [Images](concepts/images.md)
  - [Snapshots](concepts/snapshots.md)
  - [QMP](concepts/qmp.md)
- [Actions](reference/index.md)
  - [`qemu:vm`](reference/vm.md)
  - [`qemu:probe`](reference/probe.md)
  - [`qemu:loadvm`](reference/loadvm.md)
  - [`qemu:savevm`](reference/savevm.md)
  - [`qemu:qmp/send`, `poll`, `consume`](reference/qmp.md)
  - [`qemu:img`](reference/img.md)
- [API](api/index.md)
  - [QMP helpers](api/qmp.md)
  - [Serial console](api/serial.md)
  - [Image builders](api/img.md)
- [Examples](examples/index.md)
  - [The NVMe snapshot + hotplug test loop](examples/nvme-test.md)
