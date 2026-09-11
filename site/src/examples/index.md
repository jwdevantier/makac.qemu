<!-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier -->
<!-- SPDX-License-Identifier: BSD-2-Clause -->

# Examples

- [The NVMe snapshot + hotplug test loop](nvme-test.md) — the workflow
  class makac.qemu exists for: build → boot once → snapshot → per-test
  resume → hotplug → guest-side bind → run → teardown.
