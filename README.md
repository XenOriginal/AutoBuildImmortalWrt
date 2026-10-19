# ImmortalWrt x86-64 Host — Inspur AliMoC-MD-02-25G

This repository is intentionally **single-purpose**: it builds one production
A/B firmware for one machine.

- Board: Inspur AliMoC-MD-02-25G (Intel Atom C3958, 32 GB RAM)
- Storage: Samsung MZMTE512HMHP 512 GB SATA M.2
- Network: 2× Mellanox ConnectX-4 Lx + 1× Intel X553
- Boot: UEFI (Legacy GRUB image is also produced)
- Base: ImmortalWrt `openwrt-25.12`, pinned to `214e26e4`

The upstream multi-architecture ImageBuilder tree was removed on purpose.
Only the host build path, the QAT C3XXX driver, the A/B tooling and the
production reliability overlay are kept.

## Build

GitHub Actions: **Build ImmortalWrt x86-64 Host (A/B production)**

Every push to `master` builds the image and publishes the `latest-clean-ab`
release with:

- `immortalwrt-x86-64-generic-squashfs-combined.img.gz` (Legacy)
- `immortalwrt-x86-64-generic-squashfs-combined-efi.img.gz` (UEFI)
- `immortalwrt-x86-64-1024.manifest`
- `sha256sums`

## What is inside

See [`docs/PITFALLS.md`](docs/PITFALLS.md) for the failures this image was
built to prevent, and [`docs/AB-UPDATE.md`](docs/AB-UPDATE.md)
for the A/B layout.

Key changes in this branch:

1. **QAT is C3XXX**, not DH895XCC. Hardware `8086:19e2` is the Atom C3000
   integrated QAT; the correct modules are `qat_c3xxx.ko` / `qat_c3xxxvf.ko`
   and firmware is `qat_c3xxx.bin` / `qat_c3xxx_mmp.bin`.
2. **A/B rollback is real**: GRUB `loadenv` is embedded into both
   `core.img` and `bootx64.efi`; `ab-bootok` writes `boot_ok=1` only after a
   default route exists.
3. **NFS shutdown cannot hang the box**: `nfs-guard` splits container stop
   (K60) from NFS unmount (K86); `umount` never runs a global sync while NFS
   is still mounted.
4. **fsck happens before mount**: `hotplug/block/00-fsck-guard` runs before
   `10-mount`/`15-automount`.
5. **ACPI-dead board can still power off**: `/sbin/poweroff` is a deterministic
   engine that stops containers, unmounts NFS/local data and writes S5 to
   PM1_CNT. `acpi=force` is also on the kernel command line; if the BIOS still
   refuses ACPI, the fallback remains available.
6. **Hardware watchdog + health monitoring**: `kmod-itco-wdt`, `hw-watchdog`,
   `hw-healthd`, `fstrim`.
7. **KVM/VFIO/QEMU/THP/HugeTLB** are built in.
8. **Intel microcode** and UEFI tools (`efibootmgr`, `efivar`, `efivarfs`) are
   included.
9. **Denverton CPU P-state support**: a kernel patch adds
   `INTEL_ATOM_GOLDMONT_D` to `intel_pstate`; the command line includes
   `acpi=force intel_pstate=passive`.  See `docs/PITFALLS.md` for the
   1 GHz root cause and the BIOS `BIOS Request Frequency` fallback.

## Safety

Never use the stock `sysupgrade` on an A/B layout. The image installs a
`/usr/sbin/sysupgrade` wrapper that redirects firmware writes to
`/usr/sbin/ab-upgrade`.

For a first migration from an old image whose GRUB lacks `loadenv`, run:

```sh
ab-upgrade /tmp/immortalwrt-...-combined-efi.img.gz --update-boot --yes
```

`--update-boot` is opt-in; ordinary A/B tests leave the bootloader alone.

<!-- build trigger: 20261019T052409Z -->
