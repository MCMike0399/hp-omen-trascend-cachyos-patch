# hp-omen-transcend-cachyos-patch

Kernel patch and DKMS package to fix the NVIDIA RTX 4060 Max-Q GPU being stuck at **35W** (instead of its **65W** maximum) on the **HP Omen Transcend Gaming Laptop 14-fb0xxx** (DMI board `8C58`) running **CachyOS** (or any Arch-based distro with kernel 6.19+).

On Windows with Omen Gaming Hub, this laptop runs games at 60fps stable at native 2560x1600. On Linux, out of the box, the GPU is power-capped to 35W with no way to change it — resulting in severely degraded gaming performance. This patch fixes that.

## The Problem

There are **four** compounding issues in the stock kernel that prevent the GPU from reaching its full 65W TGP:

### 1. Missing Board ID

Board `8C58` is **not listed** in the `omen_thermal_profile_boards[]` array in `drivers/platform/x86/hp/hp-wmi.c`. Without this entry, the kernel never creates `/sys/firmware/acpi/platform_profile`, the Embedded Controller stays locked in balanced mode (35W GPU TGP), and `nvidia-powerd` cannot negotiate higher power via Dynamic Boost.

### 2. Module Load Failure (-EIO)

Even if you manually add the board ID, the stock `hp-wmi` module **fails to load entirely** on this hardware. The function `hp_wmi_input_setup()` calls `wmi_install_notify_handler(HPWMI_EVENT_GUID, ...)` which returns `AE_ERROR` (-EIO). In the stock code, this is treated as a fatal error — the entire module init aborts, killing the thermal profile subsystem, rfkill, and everything else the module provides.

This is overly aggressive: the WMI event handler is only needed for hotkey event notifications. The thermal profile, rfkill, and platform device functionality are completely independent and work fine without it.

### 3. Missing GPU ctgp/ppab Enablement (the 45W ceiling)

Even after fixing issues 1 and 2, the GPU only reaches **~45W** instead of 65W. This is because the Omen code path in `hp-wmi` only sets the EC thermal profile — it does **not** enable **ctgp** (Configurable TGP) or **ppab** (Power Performance Adjustment Boost) via WMI query `0x22`.

Without ctgp enabled, `nvidia-powerd` Dynamic Boost can only add ~10W above the 35W base TGP, capping the GPU at ~45W. The newer Victus S code path in the same driver DOES enable ctgp/ppab — that's how those laptops get full GPU power. The Omen Transcend 14 supports the same WMI queries but the driver never calls them for Omen boards.

Additionally, on board 8C58, the WMI BIOS call for setting the thermal profile (`HPWMI_SET_PERFORMANCE_MODE`, query `0x1A`) **silently fails** — it returns success but the EC register doesn't change. The sysfs shows "performance" but the EC stays at `0x30` (balanced). A direct EC register write is needed as a fallback.

### 4. EC Timer Resets Profile to Balanced

Board 8C58 has an Embedded Controller timer that **automatically resets** the thermal profile back to balanced mode. The kernel driver has a mechanism to handle this (disabling the timer and setting a NOTIMER flag), but only for boards listed in `omen_timed_thermal_profile_boards[]`. Without 8C58 in this list, the profile silently reverts after a short time, undoing any performance gains.

### Symptoms

- `nvidia-smi` shows `Current Power Limit: 35.00 W`, `Max Power Limit: 65.00 W`
- `/sys/firmware/acpi/platform_profile` does not exist
- `hp_wmi` module either fails to load or loads without thermal profile support
- Even when fixed, GPU power caps at ~45W instead of 65W
- Performance profile reverts to balanced on its own
- `nvidia-smi -pl 65` fails with "not supported in current scope"
- Games run significantly worse than on Windows at the same settings
- On Windows, Omen Gaming Hub sets performance mode via the same EC registers and WMI calls, achieving stable 60fps

## The Fix

This patch makes **five changes** to `drivers/platform/x86/hp/hp-wmi.c` (kernel 6.19.9):

### Patch 1: Add board 8C58 to omen_thermal_profile_boards

```c
 static const char * const omen_thermal_profile_boards[] = {
     ...
     "8BAD",
+    "8C58", /* HP Omen Transcend Gaming Laptop 14-fb0xxx */
 };
```

Enables `/sys/firmware/acpi/platform_profile` with choices `cool`, `balanced`, and `performance`.

### Patch 2: Make WMI event handler failure non-fatal

```c
 status = wmi_install_notify_handler(HPWMI_EVENT_GUID, hp_wmi_notify, NULL);
 if (ACPI_FAILURE(status)) {
-    err = -EIO;
-    goto err_free_dev;
+    pr_warn("Failed to register WMI notify handler: %s "
+            "(continuing without hotkey events)\n",
+            acpi_format_exception(status));
+} else {
+    hp_wmi_event_handler_installed = true;
 }
```

**Trade-off:** HP WMI hotkey events (e.g., the Omen key) won't be delivered through this module. On the Omen Transcend 14, the [`omen-rgb-keyboard`](https://github.com/alessandromrc/omen-rgb-keyboard) driver handles the Omen key independently, so there is no functional loss.

### Patch 3: Direct EC write fallback

```c
 err = omen_thermal_profile_set(tp);
 if (err < 0)
     return err;

+err = ec_write(HP_OMEN_EC_THERMAL_PROFILE_OFFSET, tp);
+if (err)
+    pr_warn("Failed to write EC thermal profile directly: %d\n", err);
```

On board 8C58, the WMI BIOS call for setting the thermal profile returns success but doesn't actually update the EC register. Writing directly to EC offset `0x95` ensures the firmware sees the change.

### Patch 4: Enable ctgp + ppab for Omen boards

```c
+err = victus_s_gpu_thermal_profile_set(gpu_ctgp_enable,
+                                       gpu_ppab_enable, 1);
+if (err < 0 && err != -EINVAL)
+    pr_debug("GPU ctgp/ppab set returned %d\n", err);
```

When performance mode is set:
- **ctgp** (Configurable TGP) is enabled — allows the GPU TGP to go above the 35W base
- **ppab** (Power Performance Adjustment Boost) is enabled — allows Dynamic Boost to use the full ctgp headroom

This uses the same WMI query (`0x22`, `HPWMI_SET_GPU_THERMAL_MODES_QUERY`) as the Victus S code path. The difference: **35W → 45W** (without ctgp) vs **35W → 57W+** (with ctgp).

| Profile     | ctgp | ppab | GPU power |
|-------------|------|------|-----------|
| Performance | on   | on   | up to 65W |
| Balanced    | off  | on   | ~35-45W   |
| Cool        | off  | off  | ~25W      |

### Patch 5: Add board 8C58 to timed thermal profile boards

```c
 static const char * const omen_timed_thermal_profile_boards[] = {
     "8A15", "8A42",
     "8BAD",
+    "8C58", /* HP Omen Transcend 14 - EC resets profile to balanced */
 };
```

This tells the driver that board 8C58 has an EC timer that resets the thermal profile. When setting performance mode, the driver now:
- Sets the EC timer to 0 (disabled)
- Sets EC flags to `HP_OMEN_EC_FLAGS_NOTIMER | HP_OMEN_EC_FLAGS_TURBO`

Without this, the profile silently reverts to balanced after a short period.

## How It Works (Technical Deep Dive)

### Power Negotiation Chain

```
platform_profile
  → hp-wmi: WMI BIOS call (0x1A) + direct EC write (0x95 = 0x31)
  → hp-wmi: ctgp/ppab enable via WMI (0x22)
  → EC thermal profile changes → fans ramp, power envelope opens
  → NPCF ACPI device (\_SB_.NPCF, NVDA0820) reads EC state
  → nvidia-powerd queries NPCF via ACPI _DSM
  → Dynamic Boost negotiates GPU TGP upward
  → GPU draws up to 65W under load
```

### EC Register Map

| Offset | Register | Values |
|--------|----------|--------|
| `0x95` | Thermal profile | `0x30` = balanced, `0x31` = performance, `0x50` = cool |
| `0x62` | Thermal profile flags | `0x04` = TURBO, `0x02` = NOTIMER, `0x01` = JUSTSET |
| `0x63` | Thermal profile timer | `0x00` = disabled (timer counts down to 0 → resets to balanced) |

### GPU Power Modes (WMI Query 0x22)

The `victus_gpu_power_modes` struct controls GPU power allocation:

```c
struct victus_gpu_power_modes {
    u8 ctgp_enable;        // Configurable TGP: allows GPU above base TGP
    u8 ppab_enable;        // Power Performance Adjustment Boost: Dynamic Boost
    u8 dstate;             // 1=100%, 2=50%, 3=25%, 4=12.5%
    u8 gpu_slowdown_temp;  // Preserved from current value
};
```

### Why nvidia-smi -pl Doesn't Work

On laptop GPUs with Dynamic Boost, the power limit is managed by `nvidia-powerd` through ACPI/NPCF negotiation, not through direct `nvidia-smi` power limit commands. The driver rejects `nvidia-smi -pl 65` with "not supported in current scope" because the power budget is firmware-managed.

### Why the Stock Module Silently Fails

The Omen code path calls `omen_thermal_profile_set()` which uses WMI BIOS query `0x1A` (`HPWMI_SET_PERFORMANCE_MODE`) with a buffer of `{0xFF, mode}`. On board 8C58, this WMI call returns success (return code 0) but the firmware doesn't apply the change — the EC register stays at `0x30`. This is likely a firmware bug specific to newer Omen boards. The direct `ec_write()` fallback bypasses WMI entirely.

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

# Check EC register (requires root)
sudo modprobe ec_sys write_support=1
sudo dd if=/sys/kernel/debug/ec/ec0/io bs=1 count=1 skip=$((0x95)) 2>/dev/null | xxd -p
# Expected: 31

# Check GPU power (under load)
nvidia-smi --query-gpu=power.draw,enforced.power.limit,power.max_limit --format=csv
# Expected: enforced limit should be 55-65W under GPU load
```

## Additional Performance Fixes for Gaming on Linux

Beyond the kernel module, these settings significantly impact gaming performance on this hardware:

### Split Lock Mitigation

Persona 3 Reload (and other Unreal Engine games under Proton) trigger **split lock detection traps** on every game thread. Each trap causes the CPU to serialize and context-switch, severely degrading performance. Disable it:

```bash
echo 0 > /proc/sys/kernel/split_lock_mitigate
# Make permanent:
echo "kernel.split_lock_mitigate=0" > /etc/sysctl.d/99-split-lock.conf
```

### CPU Governor

Set the CPU to performance mode for maximum clock speeds:

```bash
for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    echo performance | sudo tee "$cpu"
done
```

### Gaming Mode Script

A `gaming-mode` script is included that sets all of the above in one command:

```bash
sudo gaming-mode        # Enable all performance settings
sudo gaming-mode off    # Restore balanced/powersave settings
sudo gaming-mode status # Show current state
```

### Steam Launch Options

For games that need the NVIDIA GPU (default is Intel Arc integrated):

```
prime-run %command%
```

## Included Files

| File | Description |
|------|-------------|
| `hp-wmi.c` | Patched kernel source (based on v6.19.9 stable) |
| `hp-wmi-stock.c` | Original unmodified source for reference |
| `hp-wmi-8c58.patch` | Unified diff of all changes |
| `Makefile` | Out-of-tree module build (uses `LLVM=1` for CachyOS clang-built kernels) |
| `dkms.conf` | DKMS configuration for automatic rebuilds |
| `install.sh` | Full installer (DKMS + systemd service) |
| `uninstall.sh` | Clean removal of everything |
| `debug-power.sh` | Diagnostic script for GPU power debugging |
| `fix-gpu-power-full.sh` | Standalone power fix (EC write + ctgp via acpi_call) |

## Compatibility

- **Tested on:** HP Omen Transcend Gaming Laptop 14-fb0xxx (board 8C58), CachyOS, kernel 6.19.9
- **GPU:** NVIDIA RTX 4060 Max-Q (65W TGP), driver 595.45.04
- **Should work on:** Any Arch-based distro with kernel 6.19+ and the same hardware
- **Coexistence:** Works alongside the [`omen-rgb-keyboard`](https://github.com/alessandromrc/omen-rgb-keyboard) driver — both modules load without conflict (hp_wmi is NOT blacklisted)
- **Note:** This laptop worked correctly on Nobara (Fedora-based) previously, suggesting different kernel config or ACPI handling

## Related Projects

This repo is part of a set of tools for running the HP Omen Transcend 14 on Linux:

| Repo | Purpose |
|------|---------|
| **[hp-omen-trascend-cachyos-patch](https://github.com/MCMike0399/hp-omen-trascend-cachyos-patch)** (this repo) | Patched `hp-wmi` kernel module — fixes GPU power (35W→65W), enables `platform_profile`, adds manual fan speed control via hwmon |
| **[omen-fan-curve](https://github.com/MCMike0399/omen-fan-curve)** | Temperature-based fan curve daemon + KDE Plasma 6 widget. **Requires this repo's patched module** for fan speed control (hwmon `pwm1`) |
| **[omen-rgb-keyboard](https://github.com/alessandromrc/omen-rgb-keyboard)** | 4-zone RGB keyboard driver. Coexists with the patched hp-wmi module without conflict |

**Install order:** This repo first (kernel module), then omen-fan-curve (fan daemon + widget).

## Upstream Status

These changes could be split into separate patches for upstream submission to `platform-drivers-x86@vger.kernel.org`:

1. **Board ID addition** — straightforward, just adding `8C58` to the board lists
2. **WMI notify handler** — makes failure non-fatal; benefits other boards with similar issues
3. **ctgp/ppab for Omen boards** — the most impactful change; may need discussion since it reuses the Victus S WMI query path for Omen boards
4. **Direct EC write fallback** — compensates for firmware bugs on specific boards

## Uninstall

```bash
sudo ./uninstall.sh
# Then reboot to restore stock hp-wmi
```

## License

The patched `hp-wmi.c` is derived from the Linux kernel source and is licensed under **GPL-2.0-or-later**, matching the original.
