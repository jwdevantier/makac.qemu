<!-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier -->
<!-- SPDX-License-Identifier: CC0-1.0 -->

# Image builders

`require("pkgs/qemu/img")` registers custom builders for
[`qemu:img`](../reference/img.md) and exposes the helpers a builder uses.

```lua
local img = require("pkgs/qemu/img")

img.register_builder(name, build_fn, manifest_fn)
img.hash_file(path)                  -- sha256 of a file; a missing file hashes distinctly
img.hash_spec(value, why)            -- canonical text for a structured value
img.stage(ctx, name, manifest, run)  -- per-stage cache; true if it ran
```

`build_fn(with, ctx)` produces the image and returns its path;
`manifest_fn(with, ctx)` is optional and returns the cache key. Use the
`hash_*` helpers to turn files and spec tables into stable values.

See [Concepts: Images](../concepts/images.md) for the builder contract and
caching.
