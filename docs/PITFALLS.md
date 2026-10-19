# Pitfalls this image fixes

These are the failures observed on the live host during 2026-09-20 → 2026-10-19.
Each item has a corresponding build-time or boot-time guard.

## 1. Wrong QAT driver (DH895XCC vs C3XXX)

- Hardware: `01:00.0 8086:19e2` = Atom C3000 integrated QAT.
- Linux IDs: `PCI_DEVICE_ID_INTEL_QAT_DH895XCC = 0x0435`;
  `PCI_DEVICE_ID_INTEL_QAT_C3XXX = 0x19e2`.
- Old image shipped `qat_dh895xcc` and `qat_895xcc.bin`; device stayed unbound.
- This image ships `qat_c3xxx` / `qat_c3xxxvf` and `qat_c3xxx.bin`.
- Gate: manifest must contain `kmod-crypto-qat-c3xxx` and
  `qat-firmware-c3xxx`, and must NOT contain `kmod-crypto-qat-dh895xcc`.

## 2. ACPI does not enter ACPI mode on this BIOS

Observed:

```
ACPI Error: Hardware did not enter ACPI mode
ACPI Warning: AcpiEnable failed
ACPI: Unable to enter ACPI mode
ACPI: Interpreter disabled.
```

Consequences: no cpufreq, no platform thermal/fan, serial `irq:0`, standard S5
power-off unavailable. Mitigations:

- boot option `acpi=force` added (attempts normal ACPI);
- `/sbin/poweroff` is a deterministic engine: stop containers → unmount NFS →
  sync (unless NFS remains) → unmount local data → write S5 to PM1_CNT;
- `powerguard` checks `SCI_EN` and writes `SLP_TYP=5` as a last resort.

## 3. A/B rollback was fake

Old `/boot/grub/grub.cfg` fixed `default=0`, had no `load_env/save_env` and no
`ab-bootok`. Mitigations:

- build patch embeds `loadenv` in both `core.img` and `bootx64.efi`;
- `grub.cfg` reads `next_entry` / `boot_ok` / `bootcount`;
- `ab-bootok` (S95) writes `boot_ok=1` after a default route exists;
- `ab-upgrade` writes to the inactive slot and sets `next_entry`;
- two failed boots switch GRUB default back to the previous slot.

## 4. NFS + global sync = D-state shutdown hang

Observed: after K90network, a `sync` walked a lazy-unmounted hard NFS mount and
never returned; procd waits forever.

Mitigations:

- `nfs-guard` K60 stops containers with a 9 s budget;
- K86 unmounts NFS with a 3 s sync budget and bounded graceful/force/lazy
  unmount;
- patched `/etc/init.d/umount` skips global sync if any NFS mount remains;
- protects `/dev` and `/tmp` so K98 can still write `/dev/port`.

## 5. fsck after mount is useless

`/Lager` is mounted by `block hotplug`, before any `Sxx` init script.
Mitigations:

- `/etc/hotplug.d/block/00-fsck-guard` runs before `10-mount` / `15-automount`;
- S10 `fsck-guard` is only a fallback;
- `fstab.check_fs` is `0` to avoid a second concurrent fsck.

## 6. Wrong/absent kernel capabilities

Old image had no KVM, VFIO, vhost, THP, HugeTLB, hung-task detection or iTCO
watchdog. This image enables:

- `CONFIG_KVM`, `kvm_intel`, `vhost-net`, `vfio`, `vfio-pci`, QEMU;
- `CONFIG_TRANSPARENT_HUGEPAGE=madvise`, `CONFIG_HUGETLBFS`;
- `CONFIG_DETECT_HUNG_TASK`, `CONFIG_SOFTLOCKUP_DETECTOR`;
- `kmod-itco-wdt` + `hw-watchdog`;
- `intel-microcode`, `fstrim`, `efibootmgr`, `efivar`, `efivarfs`.

## 7. Non-ECC memory

`dmidecode` reports `Error Correction Type: None`. The README of the old
firmware claimed ECC. This is a hardware/spec mismatch, not fixable in the
image. If ECC was a requirement, replace the DIMMs.

## 8. Storage state

The Samsung M.2 SMART is PASSED, but it has one reallocated sector, one runtime
bad block and a historical UDMA CRC count (97). Continue monitoring; run a long
self-test in a maintenance window.

## 9. CPU stuck at ~1 GHz (Denverton)

Measured on the live host: `perf_event` CPU cycles over a pinned busy loop gave
~0.95 GHz, while `MSR_PLATFORM_INFO` reports a 20× max ratio (2.0 GHz).  This is
not thermal throttling (no throttle events, 53 °C), not a PL1/PL2 limit, and not
`IA32_PERF_CTL` being unreadable (the earlier `dd` test used `bs=8 skip=0x199`,
which addresses MSR `0xCC8`, not `0x199`).

Root cause in the old image: `intel_pstate` rejects `INTEL_ATOM_GOLDMONT_D`
(Denverton, family 6 model 0x5F); `acpi-cpufreq` has no `_PSS` policy.  There is
no OS component driving `IA32_PERF_CTL`.

This image:

- applies `x86-64-host/kernel-patches/0001-intel-pstate-goldmont-d.patch`
  adding `X86_MATCH(INTEL_ATOM_GOLDMONT_D, core_funcs)`;
- adds `acpi=force intel_pstate=passive` to the GRUB command line;
- keeps `/proc/config.gz` available for post-boot verification.

Verification after boot:

```sh
dmesg | grep -i intel_pstate      # should NOT say "CPU model not supported"
ls /sys/devices/system/cpu/cpufreq/policy0/
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq
```

If the platform still refuses to hand P-state control to the OS, the next step is
the ACPI `_PPC`/SMM handoff (`acpi_processor_pstate_control()` writes the FADT
`PSTATE_CNT` value 0x80 to SMI port 0xB2); this is why `acpi=force` is on the
command line.  Raw writes to `IA32_PERF_CTL` alone were verified insufficient
on the old ACPI-disabled boot.

### BIOS fallback (if the OS still runs at 1 GHz)

The setup screen `Power -> Advanced CPU Control` has:

- `EIST (GV3)` = `Enable`;
- `BIOS Request Frequency` = `Enable` (InsydeH2O help: “Auto - Enable for B0
  CPU stepping, all others disabled, change setting to override.”);
- `CPU Flex Ratio Override` = `Disable`.

This host is B0 stepping (CPUID `0x506F1`), so the firmware automatically
enables the `BIOS Request Frequency` workaround.  If the new image loads
`intel_pstate` and exposes `/sys/devices/system/cpu/cpufreq/policy0`, but the
measured effective frequency is still ~1 GHz, override that workaround in the
BIOS: set `BIOS Request Frequency` to `Disable`, keep `CPU Flex Ratio Override`
at `Disable`, save and reboot.  This is an SMM/firmware P-state request and
cannot be overridden reliably from Linux.
