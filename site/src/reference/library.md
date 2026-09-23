<!-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier -->
<!-- SPDX-License-Identifier: CC0-1.0 -->

# Library modules

The package ships three workflow-facing library modules, required as
`require("pkgs/qemu/...")`. (Other `lib/` modules — `args`, `handle` — are
internal.)

## `require("pkgs/qemu/qmp")` — QMP command constructors

Pure table-builders: **no I/O** — no socket, no target VM, no sending.
They build `{ execute = ..., arguments = ... }` tables for
[`qemu:qmp/send`](qmp.md) — the only place commands are sent, and the only
place a VM is named.

```lua
local qmp = require("pkgs/qemu/qmp")

qmp.dev_add(driver, args)     -- { execute = "device_add",
                              --   arguments = merge(args, { driver = driver }) }
qmp.bdev_add(node, driver, args)   -- blockdev-add, node-name/driver injected
qmp.hmp("savevm my-snapshot")      -- human-monitor-command
qmp.query_status()                 -- { execute = "query-status" }

qmp.merge(tables)             -- shallow-merge an array of tables into a
                              -- fresh one; later sources win — the utility
                              -- the constructors are built on

qmp.ok(result)                -- result.error == nil
qmp.err_desc(result)          -- the error description, or nil
```

Because they are pure, they compose with ordinary Lua — merging, loops,
conditionals — and the same command table can be sent to any number of VMs.

## `require("pkgs/qemu/img")` — image builders

```lua
local img = require("pkgs/qemu/img")

img.register_builder(name, build_fn, manifest_fn)
```

Registers a custom builder for use by `with.builder = "<name>"` in
[`qemu:img`](img.md). `build_fn(with, ctx)` produces the image and returns
its path; `manifest_fn(with, ctx)` (optional) returns the cache key.
See [Concepts: Images](../concepts/images.md).

## `require("pkgs/qemu/serial")` — the serial console

Reads the guest console captured by a started VM:

```lua
local serial = require("pkgs/qemu/serial")

serial.wait_for(handle_or_name, pattern, timeout_s)
-- Poll the VM's serial log until the Lua pattern matches; on timeout, a
-- failure quoting the log's tail. Used for "wait for login prompt",
-- "wait for cloud-init done", device-appearance loops, ...

serial.tail(handle_or_name, n)
-- The last n lines of the serial log.
```
