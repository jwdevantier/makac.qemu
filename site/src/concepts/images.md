<!-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier -->
<!-- SPDX-License-Identifier: CC0-1.0 -->

# Images

An **image** is a disk-image artifact built from a spec and cached by hashes
of its inputs. One action, one `builder` key:

```lua
local img = step {
    name = "build fedora base image",
    uses = "qemu:img",
    with = {
        name    = "fedora-base",
        builder = "cloud-init",
        -- ... builder-specific keys
    },
}
-- img.out.path == "/abs/.../.makac/qemu/img/fedora-base/image"
```

`qemu:img` dispatches on `with.builder` — a built-in name (`"raw"`,
`"cloud-init"`), a registered custom builder, or a function. Every builder
returns `out.path` (absolute path to the image) and `changed` iff any stage
ran.

## Caching

A builder is a pipeline of stages. Before a stage runs, the package computes
a **manifest** — a hash over every input the stage consumes — and compares
it against the manifest stored from the previous run. Match: the stage is
skipped. Mismatch or missing: it runs and saves the new manifest.

Concretely: editing a cloud-init template re-runs "render" and everything
after it, but does not re-download the base image or re-run the resize.

Image state lives under `.makac/qemu/img/<name>/`. Two workflows naming the
same image build the *same* artifact as long as their inputs hash the same
— sharing is the design. `with.force = true` bypasses the cache and
rebuilds.

## The environment and `env_hook`

Builders assemble an environment (a k→v table, most visibly consumed by
cloud-init templates) in two steps: start from `with.env`, then let
`with.env_hook` transform it:

```lua
env = { hostname = "testbox" },

env_hook = function(env)
    local f = io.open(os.getenv("HOME") .. "/.ssh/id_ed25519.pub")
    env.ssh_public_key = f and (f:read("a"):gsub("%s+$", "")) or ""
    if f then f:close() end
    env.root_password_hash = "$6$rounds=4096$dZvpjkhL4EwsC3Wi$lJ8pB0hy..."
    return env
end,
```

The hook is ordinary Lua: read a pubkey, derive a password hash, generate an
instance id.

## Builder `raw`

Empty disk images:

```lua
{
    name    = "raw-1",
    builder = "raw",
    img_size = "1G",
    -- format = "raw" (default)
}
```

One stage: `qemu-img create` under a manifest of name/size/format.

## Builder `cloud-init`

A customized OS image from a stock cloud image, in five content-cached
stages:

| stage | does |
| --- | --- |
| 1. download | fetch the base image (url + sha256) into the makac download cache |
| 2. prepare | copy base to the state dir, resize to `img_size`, create the working overlay |
| 3. templates | render each `templates` entry with the env |
| 4. iso | `genisoimage -volid cidata` from the rendered templates + sources |
| 5. customize | boot a throwaway VM (image as disk, ISO as cdrom); wait for it to power itself off |

Required keys: `img_size`; `qemu_bin` and `build_args` (the throwaway VM's
command line, flattened exactly like `qemu:vm`'s `args`);
`base_img = { url =, sha256 = }`; `templates` — at minimum user-data and
meta-data:

```lua
{
    name     = "bootbase",
    builder  = "cloud-init",
    qemu_bin = "qemu-system-x86_64",
    img_size = "10G",

    base_img = {
        url    = "https://example.com/fedora-cloud-base.qcow2",
        sha256 = "<64 hex chars>",
    },

    env = { hostname = "testbox" },

    templates = {
        { template = "templates/user-data.tpl",   output = "user-data" },
        { template = "templates/meta-data.tpl",   output = "meta-data" },
    },

    build_args = {
        "-m", "2048", "-smp", "2", "-cpu", "host", "-enable-kvm",
        { "-drive",  "file={{ img_self }},if=virtio" },
        "-cdrom",    "{{ cloud_init_iso }}",
        "-boot",     "order=c",
    },
}
```

### Templates

A template renders by one rule: `{{ name }}` expands to `env[name]`; a name
absent from the env is a spec error. No further syntax. `user-data` for a
Fedora-style base looks like:

```yaml
users:
  - name: root
    lock_passwd: false
    hashed_passwd: {{ root_password_hash }}
    ssh_authorized_keys:
      - {{ ssh_public_key }}
```

The customize VM must power itself off — the user-data ends with `poweroff:`
(or issues the shutdown). Inside `build_args`, two substitutions:
`{{ img_self }}` (the working image) and `{{ cloud_init_iso }}` (the ISO).
The customize VM obeys `timeout_s` (default 600).

## Custom builders

```lua
local img = require("pkgs/qemu/img")

img.register_builder("my-builder",
    -- build: produce the image file; returns its path
    function(with, ctx)
        -- ctx = { name, state_dir, env, force, exec, stage }
        return ctx.state_dir .. "/image"
    end,
    -- manifest (optional): what invalidates a rebuild
    function(with, ctx) return { size = with.img_size } end)
```

A builder is a *build* function and an optional *manifest* function. `ctx`
carries the state dir, the assembled env, a `stage` helper for per-stage
caching, and an `exec` helper. The two built-ins are implemented with
exactly this interface.

`with.builder` also accepts a function directly — the function *is* the
builder; pair it with `with.builder_manifest` for caching. Builders stay
inside this package's surface: there is no export path through the package
system.
