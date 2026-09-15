<!-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier -->
<!-- SPDX-License-Identifier: CC0-1.0 -->

# `qemu:vm`

Bring a VM to a state: `started`, `stopped`, or `restarted`. The
workhorse action of the package.

## `with`

```lua
with = {
    vm = "testvm",                  -- identity: a VM name or a previous
                                    -- out.handle (one key, either value)
    state = "started",               -- "started" (default) | "stopped" | "restarted"

    -- required for "started"/"restarted":
    qemu_bin = "/usr/bin/qemu-system-x86_64",
    args = {                         -- QEMU argv (see Concepts: VMs)
        "-nodefaults",
        "-machine", "q35,accel=kvm",
        -- ...
    },

    -- optional:
    ssh = {                          -- enable out.target; see below
        port = 2222,                 -- host-assigned port (required)
        user = "root",               -- global VM_SSH_USER; default "root"
        identity_file = "...",       -- global VM_SSH_IDENTITY_FILE
        options = { StrictHostKeyChecking = "no" },
    },
    disk = { backing = img.out.path },  -- boot on a throwaway overlay
                                        -- (see Concepts: Overlay boot disks;
                                        -- `path = "..."` puts the overlay elsewhere)
    wait_ssh = { timeout_s = 120, interval_s = 2 },  -- default: wait
    -- wait_ssh = false,              -- return as soon as QEMU is launched
    run_dir = "...",                 -- override the runtime directory
}
```

`state = "stopped"` ignores `ssh`/`disk`/`qemu_bin`/`args` — only the
identity and `run_dir` matter.

## `out`

```lua
out = {
    handle = <handle table>,   -- pass to later VM actions
    target = <remote target> or nil,   -- iff ssh configured
    pid    = 1234,
    -- status probe fields (see Concepts: VMs):
    alive         = true,
    running       = true,
    qmp_connected = true,
    runstate      = "running",
}
```

`changed` is `true` when the step actually started/stopped the VM, `false`
for a no-op (`started` on an already-running same-invocation VM, `stopped`
on a not-running VM).

## States

| state | semantics |
| --- | --- |
| `started` | launch; no-op if running the same invocation. Errors if running a *different* invocation — that's `restarted`. |
| `stopped` | graceful: QMP `system_powerdown`, poll `query-status` up to `timeout_s` (default 20). Then, when `force` (default `true`): QMP `quit`, then `kill -9` the pidfile pid. On success, remove runtime files, close the handle's QMP connection. |
| `restarted` | stop then start, unconditionally. Recreates the overlay disk (except when resuming from a snapshot — see `qemu:loadvm`). |

`with.force` (default `true`) controls the escalation in `stopped`.

## Errors

- `state` not one of the three, or `name`+`handle` both given / neither
  given → spec failure.
- `started`/`restarted` without `qemu_bin` or `args` → spec failure.
- A `-pidfile`/`-monitor`/`-serial`/`-qmp` in `args` → spec error (these are
  injected).
- A launch that exits immediately (bad args, missing image) → step failure
  quoting the qemu-stderr log.
- The QMP socket never appearing within the launch window → step failure
  (QEMU is up but not controllable).
- `wait_ssh` timeout → step failure naming the serial log.
