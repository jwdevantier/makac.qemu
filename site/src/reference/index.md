<!-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier -->
<!-- SPDX-License-Identifier: CC0-1.0 -->

# Reference

The precise reference for the package's actions and library modules.
Concepts are explained on the [Concepts](../concepts/index.md) pages; here
every input (`with`) and output (`out`) is spelled out.

- [Actions at a glance](actions.md) — the full action table, result shapes,
  common `with` fields.
- [`qemu:vm`](vm.md) — states, args, overlay disks, ssh target.
- [`qemu:loadvm`](loadvm.md) — resume from a snapshot.
- [`qemu:savevm`](savevm.md) — capture a snapshot.
- [`qemu:qmp/send`, `poll`, `consume`](qmp.md) — the QMP actions.
- [`qemu:img`](img.md) — image builders.
- [Library modules](library.md) — `pkgs:qemu/qmp`, `pkgs:qemu/img`,
  `pkgs:qemu/serial`.
