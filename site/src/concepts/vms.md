<!-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier -->
<!-- SPDX-License-Identifier: CC0-1.0 -->

# VMs and handles

A **VM** is a QEMU process plus its runtime files. The package identifies a
VM by a **name** you choose (`"testvm"`), and addresses it through a
**handle** — a Lua table of paths and names that `qemu:vm` returns in
`out.handle` and every other VM action accepts (a plain name works
everywhere a handle does).

## Runtime files

A started VM keeps its state under `.makac/qemu/<name>/`:

| file | purpose |
| --- | --- |
| `pid` | the QEMU process id |
| `qmp.socket` | the QMP control socket (unix) |
| `monitor.socket` | the human monitor socket |
| `serial` | the guest console, captured to a file |
| `qemu-stdout.log` / `qemu-stderr.log` | QEMU's own output |
| `invocation` | the canonical command line the VM was started with |
| `disk.qcow2` | the overlay boot disk (when `with.disk` is given) |
| `ssh.conf` | generated ssh config (when ssh is configured) |

These are the *named* state: all workflows sharing the data directory share
VM names. Naming a VM asserts "my VM" — if a VM of that name is already
running with a *different* invocation, `qemu:vm` fails rather than reusing
or replacing it. Two workflows that want isolation pick different names.

## `args`: the QEMU command line

`with.args` is the QEMU command line in **argv form** — each element is one
word, passed verbatim, never split:

```lua
args = {
    "-nodefaults",
    "-machine", "q35,accel=kvm",
    "-m", "4096",
}
```

Elements may be nested arrays or functions; all are flattened before launch,
so configuration composes:

```lua
local function boot_disk(device)
    return {
        "-drive", "id=bdrv.boot,file=" .. device .. ",format=qcow2,if=none",
        { "-device", "nvme-ns,id=ns.boot,drive=bdrv.boot,nsid=1,bus=nvme-ctrl.1" },
        function() return { "-boot", "order=c" } end,
    }
end
```

Associative tables serialize to a single QEMU property word — canonically
(keys sort lexically, `true` values become bare flags):

```lua
{ "-netdev", { user = true, id = "net0", hostfwd = "tcp::2222-:22" } }
-- one word: "hostfwd=tcp::2222-:22,id=net0,user"
```

List-like structure keeps its order — argv order is meaning in QEMU.

On start, the package appends its own infrastructure arguments
(`-pidfile`, `-monitor`, `-serial`, `-qmp`) pointing into the run
directory. Supplying any of those yourself is a spec error.

One substitution is available: `{{ disk }}` expands to the overlay disk
path (see below). Using it without `with.disk` is a spec error.

## States

`qemu:vm` brings a VM to a state:

| state | meaning |
| --- | --- |
| `started` (default) | launch the VM; no-op if it's already running the same invocation |
| `stopped` | graceful powerdown (`system_powerdown`, then escalate), remove runtime files |
| `restarted` | stop, then start, unconditionally |

"Same invocation" is decided byte-for-byte on the canonical command line
(`qemu_bin` + flattened `args`, associative tables canonicalized) — `-m 4G`
and `-m 4096` are different invocations. A running VM whose invocation
differs is a spec failure: change it with `state = "restarted"`.

Starting waits for ssh if configured (`wait_ssh`, default on): a VM that
never answers is a step failure quoting its serial log.

## Overlay boot disks

A VM's boot disk is usually a built image — an artifact meant to be reused,
not consumed by boots. `with.disk` expresses that separation:

```lua
disk = { backing = img.out.path }
```

On start, the package creates a qcow2 overlay at
`.makac/qemu/<name>/disk.qcow2` backed by `backing`; the backing image is
never written to. `args` refers to the overlay via `{{ disk }}`:

```lua
{ "-drive", "id=bdrv.boot,file={{ disk }},format=qcow2,if=none" },
```

Every fresh start of the VM name boots a pristine disk. **Exception:
`qemu:loadvm`** — a snapshot saved from an overlay-booted VM lives *in* the
overlay, so a restart that resumes from a snapshot keeps the existing
overlay instead of recreating it.

## The ssh target

When `with.ssh` is given, a started VM is returned as `out.target` — an
ordinary makac remote target named after the VM, usable by later steps:

```lua
step {
    uses = "shell",
    target = vm.out.target,
    with = { cmd = { "uname", "-a" } },
}
```

`with.ssh.port` is the **host-assigned port** (the guest side of the
forwarding lives in `args`, e.g. `hostfwd=tcp::2222-:22`). Other ssh keys
fall back to workflow globals, then built-in defaults:

| ssh key | global | default |
| --- | --- | --- |
| `port` | `VM_SSH_PORT` | none (required) |
| `user` | `VM_SSH_USER` | `"root"` |
| `identity_file` | `VM_SSH_IDENTITY_FILE` | none |

```lua
VM_SSH_USER = "admin"
VM_SSH_PORT = 2222
```

The forwarding must agree between `args` and `ssh.port` — the package does
not parse `hostfwd=` to cross-check it. Convention: bind both to one Lua
value.

## Status

A VM's status is defined by a probe: QMP first (`query-status`), then the
pidfile. The probe result is available in `qemu:vm`'s `out` — and as the
output of the read-only [`qemu:probe`](../reference/probe.md) action, for
workflow policy like "already up → no-op":

```lua
{
    pid           = 1234 or nil,
    alive         = true,     -- process exists
    running       = true,     -- vCPUs executing (QMP-derived; nil if QMP unreachable)
    qmp_connected = true,     -- was QMP reachable in this probe?
    runstate      = "running",-- QMP runstate, or nil
}
```

`alive` true with `running` nil is the "the VM is wedged" signature —
process up, QMP unresponsive.

## The serial console

`-serial file:<run_dir>/serial` captures the guest console for the VM's
lifetime. Workflows consume it through `require("pkgs:qemu/serial")`:

```lua
local serial = require("pkgs:qemu/serial")

serial.wait_for(vm.out.handle, "login:", 30)   -- wait for a Lua pattern
serial.tail(vm.out.handle, 20)                 -- last 20 lines
```

Used for "wait for login prompt", "wait for cloud-init done",
device-appearance loops, ...
