<!-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier -->
<!-- SPDX-License-Identifier: CC0-1.0 -->

# `qemu:probe`

Read a VM's status: liveness, pid, runstate. The read-only action of the
package — `ok`, never `changed`, and never a failure on a down or wedged
VM: those are **data**, not errors.

## `with`

```lua
with = {
    vm = "testvm",        -- a VM name or a previous out.handle
    run_dir = "...",      -- optional override
}
```

## `out`

The same status shape `qemu:vm` reports:

```lua
out = {
    handle = <handle table>,   -- pass to later VM actions
    pid    = 1234 or nil,      -- from the pidfile, if present & valid
    alive  = true,             -- the process exists (QMP or pid evidence)
    running = true or nil,     -- vCPUs executing; QMP-derived only
    qmp_connected = true,      -- was QMP reachable in this probe?
    runstate = "running",      -- "running"|"paused"|... or nil
}
```

## Rules

- **The probe order** is QMP first (`query-status`), pidfile second. When
  this run already holds a connection to the VM, the probe uses it; a VM
  started outside this run gets a transient connection, opened and closed
  by the probe.
- **Down and wedged are results, not errors.** `alive = false` means down
  (no pidfile, or a dead pid). `alive = true` with `running = nil` and
  `qmp_connected = false` is the "wedged" signature — process there, QMP
  unresponsive. Only invalid input (a missing or malformed `with.vm`)
  fails the step.
- **The send caveat.** Probing through this run's *attached* connection
  clears its buffered events — the same as any `qemu:qmp/send` (see
  [`qemu:qmp/send`, `poll`, `consume`](qmp.md)). Don't probe between a
  `poll` and its `consume`.

## Typical use: workflow policy

The action exists so workflows spell liveness decisions over step output
instead of reaching into the package's internals:

```lua
local p = step { name = "probe testvm", uses = "qemu:probe", with = { vm = "testvm" } }
if p.out.alive then
    print(("already running (pid %s) — no-op"):format(tostring(p.out.pid)))
    return
end
```

```lua
local p = step { uses = "qemu:probe", with = { vm = "testvm" } }
assert(not p.out.alive, "testvm must be down to re-seed its disk")
```
