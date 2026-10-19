# Compile-time feature fragments

Each `.conf` is a small, verifiable feature block.  `enabled.txt` is the
default list; optional fragments can be enabled with `FEATURES=...`.

Supported sections:

- `[meta]` — `desc=...`, `expect_pkgs=pkg1,pkg2` (checked against the final manifest)
- `[config]` — `CONFIG_PACKAGE_*=y` lines for the OpenWrt `.config`
- `[config-unset]` — symbols that must be `# ... is not set`
- `[kconfig]` — kernel symbols merged into `target/linux/x86/64/config-6.12`
- `[kconfig-unset]` — kernel symbols that must be unset

The applier is idempotent and self-checking: it asserts every line it wrote
can be read back.  The build script additionally checks the final kernel
`.config` and the final package manifest, so a feature that is silently
dropped fails the build instead of shipping.

Current defaults: `enabled.txt`.

<!-- build trigger 20261019T052437Z -->
