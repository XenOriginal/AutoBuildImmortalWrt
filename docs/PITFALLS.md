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
