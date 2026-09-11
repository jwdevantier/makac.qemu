<!-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier -->
<!-- SPDX-License-Identifier: CC0-1.0 -->

# The NVMe snapshot + hotplug test loop

This is the workflow shape the package exists for: exercise a device —
here an NVMe controller — inside a real VM, repeatedly and fast.

The pattern: **boot once, snapshot, then for each test resume from the
snapshot, hotplug an NVMe controller at a known PCI address, bind it to
`vfio-pci` in the guest, exercise it, and tear down.**

The values below that are site-local (QEMU binary path, ssh key, image
URL) are placeholders — substitute your own.

## The machine configuration

The VM is Q35 with **pre-created PCIe root ports** and **no NVMe devices at
boot**: Q35 cannot hotplug root ports, and the snapshot must freeze a
topology that has empty buses ready for hotplug. The boot disk is an
overlay over a built image (`{{ disk }}`).

```lua
local qmp = require("pkgs:qemu/qmp")

local QEMU = "/path/to/qemu-system-x86_64"   -- site-local

-- ssh defaults, ambient for every step in this file
VM_SSH_USER          = "root"
VM_SSH_IDENTITY_FILE = os.getenv("HOME") .. "/.ssh/id_ed25519"   -- site-local

local base_args = {
    "-nodefaults",
    { "-machine", "q35,accel=kvm,kernel-irqchip=split" },
    "-cpu", "host", "-smp", "2", "-m", "4096",
    { "-netdev", { user = true, id = "net0", hostfwd = "tcp::2090-:22" } },
    { "-device", "virtio-net-pci,netdev=net0" },
    { "-device", "pcie-root-port,id=root0,chassis=1,slot=0" },
    { "-device", "pcie-root-port,id=root1,chassis=2,slot=0" },
    { "-device", "pcie-root-port,id=root2,chassis=3,slot=0" },
    -- boot disk: overlay over the built image
    { "-drive",  "id=bdrv.boot,file={{ disk }},format=qcow2,if=none" },
    { "-device", "nvme-subsys,id=boot_subsys" },
    { "-device", "nvme,id=nvme-boot-ctrl,serial=boot,subsys=boot_subsys" },
    { "-device", "nvme-ns,id=nvme-boot,drive=bdrv.boot,nsid=1,bus=nvme-boot-ctrl,bootindex=0" },
}
```

## Boot once, snapshot, stop

```lua
local base_img = step {
    name = "build boot image",
    uses = "qemu:img",
    with = {
        name     = "bootbase",
        builder  = "cloud-init",
        -- img_size, base_img (url + sha256), env, templates, build_args
        -- as in the cloud-init builder docs
    },
}

local base = step {
    name = "boot base VM",
    uses = "qemu:vm",
    with = {
        name = "testvm", state = "started", qemu_bin = QEMU,
        disk = { backing = base_img.out.path },
        args = base_args,
        ssh  = { port = 2090 },
    },
}

local snap = step {
    name = "snapshot booted state",
    uses = "qemu:savevm",
    with = { vm = base.out.handle, tag = "base_snapshot" },
}

step { -- the base VM has done its work; its snapshot is in the image
    uses = "qemu:vm",
    with = { name = "testvm", state = "stopped" },
}
```

## Per test: resume, hotplug, bind, run, drop

```lua
local function run_test(test_name, test_args)
    local vm = step {
        name = "resume for test " .. test_name,
        uses = "qemu:loadvm",
        with = {
            name = "testvm",       -- same run dir the snapshot was taken on
            qemu_bin = QEMU,
            args = base_args,
            snapshot = snap.out.snapshot,      -- -loadvm base_snapshot
            state = "restarted",   -- fresh qemu process, existing overlay
            ssh = { port = 2090 },
        },
    }

    -- hotplug: synchronous at QMP; the guest discovers asynchronously.
    -- addr as a STRING fixes the BDF the guest will see.
    step {
        name = "attach nvme0",
        uses = "qemu:qmp/send",
        with = { vm = vm.out.handle, commands = {
            qmp.dev_add("nvme", { id = "nvme0", bus = "root0", addr = "0.0" }),
        } },
    }

    -- wait for guest-side appearance at the deterministic BDF
    step {
        uses = "shell",
        target = vm.out.target,
        with = { cmd = { "sh", "-c",
            "while ! lspci -nn | grep -q '0000:03:00.0'; do sleep 0.1; done" } },
    }

    -- bind to vfio-pci (the guest's nvme driver is blacklisted in the image)
    step {
        uses = "shell",
        target = vm.out.target,
        with = { cmd = { "sh", "-c", [[
            addr=0000:03:00.0
            echo "$addr" > /sys/bus/pci/devices/$addr/driver/unbind || true
            echo vfio-pci > /sys/bus/pci/devices/$addr/driver_override
            echo "$addr" > /sys/bus/pci/drivers/vfio-pci/bind
        ]] } },
    }

    -- the actual test
    step {
        name = "run " .. test_name,
        uses = "shell",
        target = vm.out.target,
        with = { cmd = test_args },
    }

    -- hot-unplug; poll QMP for the unplug event, then retire the buffer
    step {
        uses = "qemu:qmp/send",
        with = { vm = vm.out.handle, commands = {
            { execute = "device_del", arguments = { id = "nvme0" } },
        } },
    }
    local p = step { uses = "qemu:qmp/poll",
                     with = { vm = vm.out.handle, timeout_s = 10 } }
    assert(p.out.events[1].name == "DEVICE_DELETED")
    step { uses = "qemu:qmp/consume",
           with = { vm = vm.out.handle, n = #p.out.events } }

    step { uses = "qemu:vm", with = { name = "testvm", state = "stopped" } }
end

run_test("nvme-4k", { "/tmp/tp4176.test" })
```

## What each piece does

| recipe step | here |
| --- | --- |
| boot once, `savevm base_snapshot` | `qemu:vm` (waits for ssh) → `qemu:savevm` |
| per test: same args + `-loadvm` | `qemu:loadvm` with `base_args` + `snapshot` |
| root ports pre-created, no NVMe at boot | `base_args`; topology frozen by the snapshot |
| `device_add` with `addr = "0.0"` (string) | `qemu:qmp/send` + `qmp.dev_add` |
| guest polls `lspci` for the known BDF | `shell` step on `vm.out.target` |
| unbind / driver_override / bind vfio-pci | `shell` step on the target |
| run via `/dev/vfio/<group>` | the test `shell` step |
| destroy VM, repeat | `qemu:vm state = "stopped"`; next test re-resumes with `restarted` |

## Notes

- **Snapshot locality.** `savevm` writes into the VM's writable disk, which
  for an overlay-booted VM is `.makac/qemu/testvm/disk.qcow2` — so resumed
  instances use the *same run dir* (same name). The recipe above runs tests
  *serially*; for *concurrent* instances, use distinct names and make the
  snapshot live in a shared backing image rather than a per-run-dir overlay.
- **The guest's nvme-driver blacklist** is image content (the `bootbase`
  image's `user-data`), not a step.
- **Resume is fast.** Each test starts from the snapshot — seconds, not a
  fresh boot — and at a known, deterministic machine state.
