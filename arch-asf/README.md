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
- `boot/`      — systemd-boot entry templates

## Safety

- Original `.config` saved as `.config.pre-asf` on first run.
- Existing kernels (linux, linux-lts, linux-zen) are never touched.
- The default systemd-boot entry is not changed; you pick `linux-riff` from the menu.

## Rollback

    sudo rm /boot/vmlinuz-linux-riff /boot/initramfs-linux-riff*.img \
            /boot/System.map-linux-riff /boot/loader/entries/linux-riff*.conf \
            /etc/mkinitcpio.d/linux-riff.preset
    sudo rm -rf /lib/modules/6.17.4-zen-riff+
    cp .config.pre-asf .config && make LLVM=1 olddefconfig
