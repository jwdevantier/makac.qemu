# VM handles

A *VM handle* identifies a VM: a name, a runtime directory, and the QEMU
process (if any) currently occupying it. Steps pass VMs around through
handles: `qemu:vm` returns one in `out.handle`; every other VM action accepts
one.

## Shape

A handle is a Lua table of known keys:

```lua
handle = {
  name           = "testvm",                        -- identity
  run_dir        = "/abs/path/.makac/qemu/testvm",  -- runtime directory
  pid_file       = run_dir .. "/pid",
  qmp_socket     = run_dir .. "/qmp.socket",
  monitor_socket = run_dir .. "/monitor.socket",    -- human monitor
  serial_log     = run_dir .. "/serial",
  disk_overlay   = run_dir .. "/disk.qcow2",        -- the overlay boot disk (vm.md)
  qemu_stdout    = run_dir .. "/qemu-stdout.log",
  qemu_stderr    = run_dir .. "/qemu-stderr.log",
  ssh_config     = run_dir .. "/ssh.conf",          -- if ssh configured
}
```

All keys are paths/strings. The live state associated with a handle — its
**QMP connection**, and its ssh target when configured — is owned by the
per-run registry (below); everything else about the VM is
derived from the files at call time, never cached in the table.

## One handle per VM per run

Within a workflow run, there is exactly one handle per VM. The package keeps
a registry keyed by canonical (absolute) `run_dir`: the first step to touch
a VM — a `qemu:vm` start, or a name-based attach from any other action —
materializes the entry (creating the handle table and, on start/attach, its
QMP connection); every later step naming or receiving the same VM gets the
*identical table*. Identity is literal: two `qemu:vm` steps with
`state = "started"` against the same name satisfy `s1.out.handle ==
s2.out.handle`.

The registry owns the live state — the QMP connection, and (when ssh is
configured) the VM's remote target (vm.md, "The ssh target"). Actions
resolve "this handle's connection" through it at call time, so a connection
can never be duplicated, split, or shadowed by a second handle — there is
no second handle. Multiple connections to one VM exist only across separate
`makac run` processes; QEMU accepts concurrent QMP clients, each with its
own event stream.

The handle table itself stays pure data (paths/strings), safe to copy,
diff, or stash in a variable.

## The QMP connection

A started VM has exactly one QMP connection, opened by `qemu:vm` **as part
of starting it** and held until the handle is closed — i.e.
until `state = "stopped"` succeeds or the workflow run ends. All qmp actions
against the VM share it (see `qmp.md`); commands and polls serialize on it
in step order. A run that *attaches* to an already-running VM by name opens
a connection on demand — its first QMP-needing step — and from then on that
connection is the VM's connection for the rest of the run.

Events reach the buffer only while connected: anything QEMU emitted between
runs, before a run's connection existed, is not received.

## Obtaining one, re-deriving one

Every VM-addressing action takes `with.vm` — one key, either value: a
plain VM name (string) or a handle (table, e.g. a previous `out.handle`):

```lua
step { uses = "qemu:vm", with = { vm = "testvm", state = "stopped" } }
```

is equivalent to:

```lua
step { uses = "qemu:vm", with = { vm = vm.out.handle, state = "stopped" } }
```

even if the handle came from an entirely different `makac run`.

Derivation rule: `run_dir` defaults to `makac.data_dir .. "/qemu/" .. name`.
Every action accepts a `run_dir` override changing this derivation.

## Status probing

Status is defined by a probe order:

1. **QMP first.** Connect to `handle.qmp_socket`, send `query-status`. If the
   connection succeeds, QMP is authoritative: its `running` boolean is the
   answer (a paused VM is alive but not running; only QMP reports that), and
   the query's status string is the runstate. (When this run already holds
   the VM's connection, the probe uses THAT one — real QEMU services one
   QMP client at a time; a transient connection would wait for the greeting
   until the current client disconnects.)
2. **PID fallback.** If the QMP socket is not connectable: read
   `handle.pid_file`, check the process exists (`kill(pid, 0)`, minus
   zombies — a zombie answers the signal but is dead). A live pid
   with an unconnectable QMP socket means the process is there but the VM is
   not responsive (early boot, hung).
3. **Down.** No pidfile, or a stale pidfile with a dead pid.

The status vocabulary returned by `qemu:vm`'s `out` and used by every
action's error messages:

```lua
{
  pid           = 1234 or nil,      -- from pidfile, if present & valid
  alive         = true/false,       -- process exists (QMP or pid evidence)
  running       = true/false or nil,-- vCPUs executing; QMP-derived only, nil otherwise
  qmp_connected = true/false,       -- was QMP reachable in this probe?
  runstate      = "running"|"paused"|"suspended"|... or nil,
}
```

`alive` true with `running` nil means the process exists but the guest is not
executing (paused/suspended/unresponsive). `qmp_connected` false with
`alive` true is the "the VM is wedged" signature.

The read is exposed as its own action — `qemu:probe` — so workflows spell
liveness POLICY ("already up → no-op", "must be down to re-seed") over
plain step output instead of reaching into the package's internals:

```lua
local p = step { uses = "qemu:probe", with = { vm = "testvm" } }
if p.out.alive then ... end
```

`qemu:probe` is a READ: `ok`, never `changed`, and it never fails on a down
or wedged VM — those are data. (It asks QMP first — through this run's
attached connection when one exists, a transient one otherwise — so, like
any send, probing an attached connection clears its buffered events; see
qmp.md's send semantics.) `qemu:vm` on an already-started VM also returns
the probe, and each action documents whether a down/unresponsive VM is
an error for it.
