# hp-omen-transcend-cachyos-patch

Kernel patch and DKMS package to fix the NVIDIA RTX 4060 Max-Q GPU being stuck at 35W (instead of 65W) on the **HP Omen Transcend Gaming Laptop 14-fb0xxx** (DMI board `8C58`) running **CachyOS** (or any Arch-based distro with kernel 6.19+).

## The Problem

The RTX 4060 Max-Q in the HP Omen Transcend 14 has a maximum TGP (Total Graphics Power) of **65W**, but the kernel's `hp-wmi` driver limits it to **35W** due to two issues:

### 1. Missing Board ID

Board `8C58` is **not listed** in the `omen_thermal_profile_boards[]` array in `drivers/platform/x86/hp/hp-wmi.c`. Without this entry, the kernel never creates `/sys/firmware/acpi/platform_profile`, the Embedded Controller stays locked in balanced mode (35W GPU TGP), and `nvidia-powerd` cannot negotiate higher power via Dynamic Boost.

### 2. Module Load Failure (-EIO)

Even if you manually add the board ID, the stock `hp-wmi` module **fails to load entirely** on this hardware. The function `hp_wmi_input_setup()` calls `wmi_install_notify_handler(HPWMI_EVENT_GUID, ...)` which returns `AE_ERROR` (-EIO). In the stock code, this is treated as a fatal error — the entire module init aborts, taking the thermal profile subsystem down with it.

This is overly aggressive: the WMI event handler is only needed for hotkey notifications. The thermal profile, rfkill, and platform device functionality are completely independent and work fine without it.

### Symptoms

- `nvidia-smi` shows `Current Power Limit: 35.00 W`, `Max Power Limit: 65.00 W`
- `/sys/firmware/acpi/platform_profile` does not exist
- `hp_wmi` module either fails to load or loads without thermal profile support
- GPU-bound games run at ~45 FPS instead of 60+ at native 2560x1600
- `nvidia-smi -pl 65` fails with "not supported in current scope" (laptop GPU limitation)
- The same hardware works correctly on Windows (Omen Gaming Hub sets performance mode via the same EC registers)

## The Fix

This patch makes two changes to `drivers/platform/x86/hp/hp-wmi.c`:

### Patch 1: Add board 8C58 to omen_thermal_profile_boards

```c
 static const char * const omen_thermal_profile_boards[] = {
     ...
     "8BAD",
+    "8C58", /* HP Omen Transcend Gaming Laptop 14-fb0xxx */
 };
```

This tells the driver that board 8C58 supports Omen thermal profiles, enabling `/sys/firmware/acpi/platform_profile` with choices `cool`, `balanced`, and `performance`.

### Patch 2: Make WMI event handler failure non-fatal

```c
 status = wmi_install_notify_handler(HPWMI_EVENT_GUID, hp_wmi_notify, NULL);
 if (ACPI_FAILURE(status)) {
-    err = -EIO;
-    goto err_free_dev;
+    pr_warn("Failed to register WMI notify handler: %s (continuing without hotkey events)\n",
+            acpi_format_exception(status));
+} else {
+    hp_wmi_event_handler_installed = true;
 }
```

The cleanup path (`hp_wmi_input_destroy`) is also guarded:

```c
 static void hp_wmi_input_destroy(void)
 {
-    wmi_remove_notify_handler(HPWMI_EVENT_GUID);
+    if (hp_wmi_event_handler_installed)
+        wmi_remove_notify_handler(HPWMI_EVENT_GUID);
     input_unregister_device(hp_wmi_input_dev);
 }
```

**Trade-off:** HP WMI hotkey events (e.g., the Omen key) won't be delivered through this module. On the Omen Transcend 14, the `omen_rgb_keyboard` driver handles the Omen key independently via its own WMI event registration, so there is no functional loss.

## How It Works (Technical Deep Dive)

### Power Negotiation Chain

```
platform_profile → EC register 0x95 → ACPI NPCF → nvidia-powerd → Dynamic Boost → GPU TGP
```

1. **`platform_profile`** is a kernel interface (`/sys/firmware/acpi/platform_profile`) that exposes thermal profiles (cool/balanced/performance) to userspace
2. When set to `performance`, the `hp-wmi` driver writes **`0x31`** (V1 performance mode) to **EC offset `0x95`** via WMI BIOS call
3. The **NPCF ACPI device** (`\_SB_.NPCF`, PNP ID `NVDA0820`) reads the EC state and reports the available power budget to the NVIDIA driver
4. **`nvidia-powerd`** (NVIDIA's Dynamic Boost daemon) queries NPCF and negotiates the GPU's power limit upward — from the 35W default toward the 65W maximum
5. Under GPU load, Dynamic Boost dynamically allocates power between CPU and GPU up to the system's thermal envelope

### EC Register Map (Thermal Profile)

| Offset | Value  | Mode                    | GPU TGP |
|--------|--------|-------------------------|---------|
| `0x95` | `0x30` | V1 Balanced (default)   | 35W     |
| `0x95` | `0x31` | V1 Performance          | 65W     |
| `0x95` | `0x50` | V1 Cool                 | ~25W    |

### Why nvidia-smi -pl Doesn't Work

On laptop GPUs with Dynamic Boost, the power limit is managed by `nvidia-powerd` through ACPI/NPCF negotiation, not through direct `nvidia-smi` power limit commands. The driver correctly rejects `nvidia-smi -pl 65` with "not supported in current scope" because the power budget is firmware-managed.

## Installation

### Prerequisites

- **CachyOS** or Arch-based distro (tested on CachyOS with kernel 6.19.9)
- `dkms` package installed (`sudo pacman -S dkms`)
- Kernel headers installed (`sudo pacman -S linux-cachyos-headers`)
- `nvidia-powerd` service enabled (`sudo systemctl enable nvidia-powerd`)

### Quick Install

```bash
git clone https://github.com/MCMike0399/hp-omen-trascend-cachyos-patch.git
cd hp-omen-trascend-cachyos-patch
sudo ./install.sh
```

This will:
1. Register the patched `hp-wmi` module with DKMS (auto-rebuilds on kernel updates)
2. Build and install the module for your current kernel
3. Install and enable a systemd service that sets `performance` profile on boot
4. Set performance mode immediately

### Manual Install

```bash
# Build the module
make KVER=$(uname -r)

# Replace stock module
sudo cp hp-wmi.ko /usr/lib/modules/$(uname -r)/updates/dkms/
sudo depmod -a

# Load it
sudo rmmod hp_wmi
sudo modprobe hp_wmi

# Set performance mode
echo performance | sudo tee /sys/firmware/acpi/platform_profile

# Restart nvidia-powerd to renegotiate
sudo systemctl restart nvidia-powerd
```

### Verify

```bash
# Check platform profile
cat /sys/firmware/acpi/platform_profile
# Expected: performance

# Check GPU power
nvidia-smi --query-gpu=power.limit,enforced.power.limit,power.max_limit --format=csv
# Expected: enforced limit should climb toward 65W under load

# Or use the included tool
gpu-performance status
```

## Included Files

| File | Description |
|------|-------------|
| `hp-wmi.c` | Patched kernel source (based on v6.19.9 stable) |
| `hp-wmi-stock.c` | Original unmodified source for reference |
| `hp-wmi-8c58.patch` | Unified diff of changes |
| `Makefile` | Out-of-tree module build (uses `LLVM=1` for CachyOS clang-built kernels) |
| `dkms.conf` | DKMS configuration for automatic rebuilds |
| `install.sh` | Full installer (DKMS + systemd service) |
| `uninstall.sh` | Clean removal of everything |

## gpu-performance CLI Tool

The installer also places a helper script at `~/.local/bin/gpu-performance`:

```bash
sudo gpu-performance              # Set performance mode (default)
sudo gpu-performance off          # Set balanced mode
sudo gpu-performance cool         # Set cool/quiet mode
gpu-performance status            # Show current GPU power state
sudo gpu-performance ec-write     # Direct EC write fallback
```

## Gaming

Use this Steam launch option to run games on the NVIDIA GPU with performance optimizations:

```
__GL_SHADER_DISK_CACHE_SKIP_CLEANUP=1 prime-run game-performance %command%
```

The default GPU is Intel Arc (integrated), so `prime-run` is required to offload to the RTX 4060.

## Compatibility

- **Tested on:** HP Omen Transcend Gaming Laptop 14-fb0xxx (board 8C58), CachyOS, kernel 6.19.9
- **GPU:** NVIDIA RTX 4060 Max-Q (65W TGP)
- **Should work on:** Any Arch-based distro with kernel 6.19+ and the same hardware
- **Coexistence:** Works alongside the [`omen-rgb-keyboard`](https://github.com/alessandromrc/omen-rgb-keyboard) driver — both modules load without conflict
- **Note:** This laptop worked correctly on Nobara (Fedora-based) previously, suggesting different kernel config or ACPI handling in that distribution

## Upstream Status

The board ID addition (patch 1) is a straightforward candidate for upstream submission to `platform-drivers-x86@vger.kernel.org`. The WMI notify handler fix (patch 2) may need discussion — the current behavior of aborting module init on notify handler failure affects other boards too, but the fix changes error handling semantics that maintainers may want to review carefully.

## Uninstall

```bash
sudo ./uninstall.sh
# Then reboot to restore stock hp-wmi
```

## License

The patched `hp-wmi.c` is derived from the Linux kernel source and is licensed under **GPL-2.0-or-later**, matching the original.
