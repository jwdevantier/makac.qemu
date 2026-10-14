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

`qemu:img` dispatches on `with.builder`. The package provides two builders,
`raw` and `cloud-init`. Additionally, you may register your [own builder](#custom-builders).
All builders must return `out.path`, pointing to the built image file.

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

An empty image built by `qemu-img create`, cached under a manifest of
name/size/format.

## Builder `cloud-init`

A customized OS image from a stock cloud image, in six content-cached
stages:

| stage        | does                                                                                                          |
| ------------ | ------------------------------------------------------------------------------------------------------------- |
| 1. download  | fetch the base image (url + sha256) into the makac download cache                                             |
| 2. extract   | decompress the download when `compression` is set (else a no-op: the pristine base is the cache entry itself) |
| 3. prepare   | probe the base's format, copy it, resize the copy to `img_size`, create the working overlay                   |
| 4. templates | render each `templates` entry with the env                                                                    |
| 5. iso       | `genisoimage -volid cidata` from the rendered templates + sources                                             |
| 6. customize | boot a throwaway VM (image as disk, ISO as cdrom); wait for it to power itself off                            |

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
        -- compression = "xz",      -- optional; see below
    },

    env = { hostname = "testbox" },

    templates = {
        { template = "templates/user-data.tpl",   output = "user-data" },
        { template = "templates/meta-data.tpl",   output = "meta-data" },
    },

    sources = {                        -- optional: extra files grafted into the ISO
        { url = "https://example.com/vendor-data", sha256 = "<64 hex chars>",
          filename = "vendor-data" },
    },
    verbose = true,                    -- optional: stream the customize VM's console

    build_args = {
        "-m", "2048", "-smp", "2", "-cpu", "host", "-enable-kvm",
        { "-drive",  "file={{ img_self }},if=virtio" },
        "-cdrom",    "{{ cloud_init_iso }}",
        "-boot",     "order=c",
    },
}
```

Optional: `sources` (extra `{ url =, sha256 =, filename = }` files grafted
into the ISO) and `verbose` (stream the customize VM's serial console).


### FreeBSD BASIC-CI note
FreeBSD uses a cloud-init alternative, [nuageinit](https://man.freebsd.org/cgi/man.cgi?query=nuageinit&sektion=7&format=html). Unlike cloud-init, nuageinit
will run on every boot unless disabled. Therefore, structure your initialization
such that it ends with *disabling* the nuageinit service
(`sysrc nuageinit_enable=NO`).

### The base image: checksum, compression, format

`base_img.sha256` must match the hash of the downloaded file - even if it
is compressed and therefore extracted after the download.
Decompression is deterministic, so verifying the compressed file verifies
the uncompressed result.

The download may be compressed: `.xz`, `.bz2` and `.gz` suffixes are
decompressed in stage 2 (via `xz -dc`, `bzip2 -dc`, `gzip -dc` — the tool
is needed on `PATH` only when the URL uses it). Set
`base_img.compression = "xz" | "bz2" | "gz" | "none"` explicitly when the
URL has no telling suffix.

To create an overlay, one must also specify the format of the backing-file.
The action will automatically use `qemu-img info --output=json` to determine
the actual format of the backing image.

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
`{{ img_self }}` (the working image) and `{{ cloud_init_iso }}` (the ISO of
stage 5). The customize VM obeys `timeout_s` (default 600).

### Stage caching

The cloud-init builder is organized as a series of stages, as detailed in
the table above.

At each stage, a test is run to determine if a previous result can be reused
or if the stage must be re-done. Effectively, if any stage is (re-)done, then
all subsequent stages are also re-done.

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

**NOTE:** a builder which neglects to provide a manifest function will always
have its build function called. Such a builder MAY implement its own caching,
and in fact, `cloud-init` does.

## Caching

State lives under `.makac/qemu/img/<name>/`, where `<name>` is `with.name` —
the image name, not the step's own `name`, which is just a label:

```lua
step {
    name = "build fedora base image",   -- the step's label
    uses = "qemu:img",
    with = {
        name    = "fedora-base",        -- the image name: picks the state dir
        builder = "cloud-init",
    },
}
```

A builder's optional `manifest` function returns a table describing the
inputs that went into the build. `qemu:img` serializes that table and compares
it with the copy saved after the previous successful build. If the two match —
and the image file is still there — the build is skipped. Otherwise the build
runs, and the new manifest is saved afterwards.

Two consequences:

1. **The name is the state directory, so keep names unique.** Two steps that
   use the same `with.name` share the same image file. Whether to rebuild is
   then decided purely by whether that file exists and whether the manifest
   matches, so two steps that build *different* things under the same name
   overwrite each other and rebuild on every run. Share a name only when it
   really is the same image — same builder, same inputs. Otherwise give each
   its own name.

2. **Everything that determines the image must be in the manifest.** The
   manifest is the whole cache key, so anything the build reads from outside
   `with` — a file, an environment variable, the clock — is invisible to the
   cache, and changing it won't trigger a rebuild. Keep the build a pure
   function of `with`: pass such inputs in through `with`, and when an input is
   a file, put a hash of its contents in the manifest so it changes when the
   file does.

`cloud-init` has no manifest function. Instead, it implements caching inside
the build function itself, effectively writing a manifest per [stage](#stage-caching).
Each stage is chained such that a rebuild at any point cascades forward.

