-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
-- SPDX-License-Identifier: BSD-2-Clause
---@meta
-- User-settable configuration globals the qemu actions read when a step's
-- `with.ssh` omits a field (design/vm.md, "The ssh target"). Declared for the
-- language server; this file is never required.

---@type integer?
VM_SSH_PORT = nil

---@type string?
VM_SSH_USER = nil

---@type string?
VM_SSH_IDENTITY_FILE = nil
