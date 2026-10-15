<!-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier -->
<!-- SPDX-License-Identifier: CC0-1.0 -->

# Serial console

`require("pkgs/qemu/serial")` reads the guest console captured by a started
VM (`qemu:vm` writes it to the VM's `serial` file).

```lua
local serial = require("pkgs/qemu/serial")

serial.wait_for(handle_or_name, pattern, timeout_s)
-- Poll the serial log until the Lua pattern matches. On timeout, fail with
-- the log's tail.

serial.tail(handle_or_name, n)
-- The last n lines of the serial log.
```
