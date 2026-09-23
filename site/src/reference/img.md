<!-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier -->
<!-- SPDX-License-Identifier: CC0-1.0 -->

# `qemu:img`

Ensure a disk image is built. Dispatches on `with.builder` — a built-in
name, a registered custom builder, or a function. Concepts and the full
builder semantics are on [Concepts: Images](../concepts/images.md); this
page is the reference.

## `with` (common)

| key | meaning |
| --- | --- |
| `name` | required; identity and state-dir key |
| `builder` | required; `"raw"`, `"cloud-init"`, a registered name, or a function |
| `state_dir` | optional; default `makac.data_dir .. "/qemu/img/" .. name` |
| `env` | optional; k→v map merged into the build environment |
| `env_hook` | optional; `function(env) -> env`, applied after `env` |
| `force` | optional; bypass the manifest cache and rebuild |

## `out`

```lua
out = {
    path = "/abs/.../.makac/qemu/img/<name>/image",
}
```

`changed` is `true` iff any stage ran.

## Builder `raw`

```lua
with = {
    name = "raw-1", builder = "raw",
    img_size = "1G",     -- required
    format   = "raw",    -- optional; default "raw"
}
```

One stage: `qemu-img create` under a manifest of name/size/format.

## Builder `cloud-init`

```lua
with = {
    name     = "bootbase",
    builder  = "cloud-init",
    qemu_bin = "qemu-system-x86_64",   -- required
    img_size = "10G",                  -- required

    base_img = {                       -- required
        url    = "https://example.com/fedora-cloud-base.qcow2",
        sha256 = "<64 hex chars>",     -- required
    },

    env = { hostname = "testbox" },    -- optional

    templates = {                      -- required: at minimum user-data, meta-data
        { template = "templates/user-data.tpl", output = "user-data" },
        { template = "templates/meta-data.tpl", output = "meta-data" },
    },

    build_args = { ... },              -- required: throwaway VM command line
    timeout_s = 600,                   -- optional; customize-VM timeout

    sources = {                        -- optional: extra files grafted into the ISO
        { url = "https://...", sha256 = "<64 hex>", filename = "vendor-data" },
    },
    verbose = true,                    -- optional: stream the customize VM's console
}
```

Stages: download → prepare (resize, overlay) → templates → iso
(`genisoimage`) → customize (throwaway VM powers itself off). See
[Concepts: Images](../concepts/images.md) for the template rule and the
`{{ img_self }}` / `{{ cloud_init_iso }}` substitutions.

## Custom builders

`with.builder` may be a function; pair it with `with.builder_manifest` for
caching:

```lua
with = {
    name = "mine", builder = function(with, ctx)
        -- ctx = { name, state_dir, env, force, exec, stage }
        return ctx.state_dir .. "/image"
    end,
    builder_manifest = function(with, ctx) return { size = with.img_size } end,
}
```

Or register one for reuse:

```lua
local img = require("pkgs/qemu/img")
img.register_builder("my-builder", build_fn, manifest_fn)
```

For a `manifest_fn` that depends on files or structured inputs, the module
exports the same helpers the built-ins use:

```lua
img.hash_file(path)          -- sha256 of a file; an unreadable file hashes to
                             -- a distinct error string, so "input gone" = changed
img.hash_spec(value, why)    -- canonical text for a structured spec value
img.stage(ctx, name, manifest, run)  -- the per-stage cache; true if it ran
```

A one-off function without a manifest runs every time.
