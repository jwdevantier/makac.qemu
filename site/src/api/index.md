<!-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier -->
<!-- SPDX-License-Identifier: CC0-1.0 -->

# API

Three workflow-facing library modules, required as `require("pkgs/qemu/...")`:

| module                          | for                                              |
| ------------------------------- | ------------------------------------------------ |
| [`pkgs/qemu/qmp`](qmp.md)       | Building QMP command tables and reading replies. |
| [`pkgs/qemu/serial`](serial.md) | Reading the guest serial console.                |
| [`pkgs/qemu/img`](img.md)       | Registering custom image builders.               |

(The internal `args` and `handle` modules are not part of this surface.)
