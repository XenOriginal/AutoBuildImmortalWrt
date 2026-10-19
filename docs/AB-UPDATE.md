# A/B update and rollback

## Normal update

```sh
ab-upgrade /tmp/immortalwrt-x86-64-generic-squashfs-combined-efi.img.gz --yes
reboot
```

The updater writes the inactive slot, migrates the current `/overlay` into a
new f2fs overlay inside that slot, writes `next_entry` / `boot_ok=0` /
`bootcount=0`, then reboots.

After boot:

```sh
ab-status
# expect: current_slot = target slot, boot_ok=1, bootcount=0
```

## One-time bootloader refresh

Required only when coming from an image whose GRUB/EFI loader lacks `loadenv`:

```sh
ab-upgrade <image> --update-boot --yes
```

This refreshes `core.img`, `bootx64.efi` and `grub.cfg`, keeping `.bak-<time>`
copies on the ESP. On the current UEFI setup the EFI loader is the one that
matters.

## Return to the other slot

From the new slot, run the same command again; it will write the other slot.
This is the A→B→A "mutual progression" test.

## Rollback

- Automatic: if the new slot never sets `boot_ok=1`, GRUB increases
  `bootcount`; after two failed boots it switches `default` back to the old slot.
- Manual: use the serial/GRUB menu and choose the old slot. Do not use
  `sysupgrade`.
