# arch-asf — linux-riff custom kernel for 7950X3D / RX 7900 XT

Builds a custom `linux-riff` kernel alongside the upstream `linux`/`linux-lts`/`linux-zen`
packages, optimized for this exact hardware. See `docs/` for design + plan.

## Quick start

    ./build.sh all          # preflight + config + build (NO install)
    sudo ./build.sh install # deploy kernel, modules, initramfs, boot entries

## Layout

- `fragments/` — Kconfig fragments merged into `.config` via `merge_config.sh`
- `build.sh`   — driver
- `verify.sh`  — pre-install and `--runtime` post-boot checks
- `presets/`   — mkinitcpio preset
- `boot/`      — boot entry templates: systemd-boot (`*.conf.tmpl`) + GRUB generator (`42_linux-riff.grub.tmpl`)

## Bootloaders

`install` auto-detects the host bootloader and writes entries portably (root spec
derived from the running system — no hardcoded UUIDs):

- **systemd-boot** (`/boot/loader/entries`): writes the four `linux-riff*.conf` entries.
- **GRUB** (`/boot/grub`): installs `/etc/grub.d/42_linux-riff` and runs `grub-mkconfig`.
  The generator emits the same four variants and re-runs cleanly on later grub upgrades.
- **Neither**: prints the kernel image + cmdline so you can add an entry by hand.

Override the derived root spec with `sudo ROOT_OPTS='root=… rw rootflags=…' ./build.sh install`.
Rewrite entries only (after a cmdline change), no rebuild: `sudo ./build.sh entries`.

## Safety

- Original `.config` saved as `.config.pre-asf` on first run.
- Existing kernels (linux, linux-lts, linux-zen) are never touched.
- The default boot entry is not changed; you pick `linux-riff` from the menu.

## Rollback

    sudo rm /boot/vmlinuz-linux-riff /boot/initramfs-linux-riff*.img \
            /boot/System.map-linux-riff /boot/loader/entries/linux-riff*.conf \
            /etc/mkinitcpio.d/linux-riff.preset
    # GRUB hosts: also remove the generator and regenerate the menu
    sudo rm -f /etc/grub.d/42_linux-riff && sudo grub-mkconfig -o /boot/grub/grub.cfg
    sudo rm -rf /lib/modules/6.17.4-zen-riff+
    cp .config.pre-asf .config && make LLVM=1 olddefconfig
