#!/usr/bin/env bash
# linux-riff kernel build orchestrator.
# Stages: preflight | config | build | install | all (preflight+config+build, NO install)
# Install is a separate explicit step because it requires sudo.

set -euo pipefail

# Resolve to repo root (script lives in arch-asf/)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

ASF_DIR="${REPO_ROOT}/arch-asf"
FRAG_DIR="${ASF_DIR}/fragments"
PRESETS_DIR="${ASF_DIR}/presets"
BOOT_TMPL_DIR="${ASF_DIR}/boot"

LOCALVERSION="-riff"
# Job count. The ThinLTO+CFI final relink (and the BTF/pahole pass) is memory-
# heavy — a full -j$(nproc) relink OOM-killed the build before (exit 137). Cap
# jobs at ~4 GiB of *available* RAM per job so the relink survives, but never
# below 4. Override explicitly with `JOBS=N arch-asf/build.sh build` when you
# have headroom (e.g. closed the browser) and want full core parallelism.
JOBS="${JOBS:-$(nproc)}"
_avail_gib="$(awk '/MemAvailable/ {print int($2/1024/1024)}' /proc/meminfo)"
_mem_cap=$(( _avail_gib / 4 ))
(( _mem_cap < 4 )) && _mem_cap=4
if (( _mem_cap < JOBS )); then
  JOBS="$_mem_cap"
fi
unset _avail_gib _mem_cap

log()  { printf '\033[1;36m[asf]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[asf:warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[asf:err]\033[0m %s\n' "$*" >&2; exit 1; }

# ----- preflight -----------------------------------------------------------
cmd_preflight() {
  log "preflight: checking toolchain"
  local tools=(clang ld.lld llvm-objcopy llvm-ar llvm-nm llvm-strip llvm-readelf bc pahole perl)
  local missing=()
  for t in "${tools[@]}"; do
    command -v "$t" >/dev/null 2>&1 || missing+=("$t")
  done
  if (( ${#missing[@]} )); then
    die "missing tools: ${missing[*]} — install llvm, clang, lld, pahole"
  fi
  local clang_ver
  clang_ver="$(clang --version | head -n1)"
  log "clang: ${clang_ver}"
  log "lld:   $(ld.lld --version | head -n1)"
  log "cores: ${JOBS}"
  log "preflight OK"
}

# ----- config --------------------------------------------------------------
# Seed from running kernel /proc/config.gz, or current .config, or zen defconfig.
cmd_config() {
  log "config: seeding base .config"
  if [[ ! -f .config ]]; then
    if [[ -r /proc/config.gz ]]; then
      log "  seed: /proc/config.gz (running kernel)"
      zcat /proc/config.gz > .config
    elif [[ -r /boot/config-linux-zen ]]; then
      log "  seed: /boot/config-linux-zen"
      cp /boot/config-linux-zen .config
    else
      log "  seed: make defconfig"
      make defconfig
    fi
  else
    log "  reusing existing .config"
  fi

  log "config: merging arch-asf fragments"
  local frags=()
  while IFS= read -r -d '' f; do frags+=("$f"); done \
    < <(find "${FRAG_DIR}" -maxdepth 1 -name '*.cfg' -type f -print0 | sort -z)
  (( ${#frags[@]} )) || die "no fragments found in ${FRAG_DIR}"

  # merge_config.sh: -m merges into .config, -O sets output dir.
  # Export LLVM=1 — merge_config.sh's internal `make alldefconfig` is hardcoded
  # to call `make` (not $MAKE), but it inherits the env. Without LLVM=1, the
  # toolchain-detection $(success,...) checks fail and LTO_CLANG_THIN / KCFI
  # / other clang-gated symbols silently drop back to defaults.
  LLVM=1 KCONFIG_CONFIG=.config \
    ./scripts/kconfig/merge_config.sh -m -O . .config "${frags[@]}"

  log "config: make olddefconfig (resolves new symbols)"
  make LLVM=1 olddefconfig

  log "config: verifying LOCALVERSION=${LOCALVERSION}"
  grep -q "^CONFIG_LOCALVERSION=\"${LOCALVERSION}\"$" .config \
    || warn "LOCALVERSION mismatch in .config"
  log "config OK — review with: scripts/diffconfig .config.old .config (if .old exists)"
}

# ----- build ---------------------------------------------------------------
cmd_build() {
  log "build: make LLVM=1 -j${JOBS}"
  make LLVM=1 -j"${JOBS}"
  log "build: make LLVM=1 -j${JOBS} modules"
  make LLVM=1 -j"${JOBS}" modules
  local krel
  krel="$(make -s kernelrelease)"
  log "build OK — kernelrelease: ${krel}"
}

# ----- install -------------------------------------------------------------
# Copies kernel + modules, generates initramfs, writes boot entries.
# Requires sudo. Never overwrites the existing default systemd-boot entry.
cmd_install() {
  if [[ $EUID -ne 0 ]]; then
    die "install must run as root (sudo ./arch-asf/build.sh install)"
  fi

  # Guard: refuse to install before the build is COMPLETE. If modules.order /
  # bzImage are absent, modules_install would invoke `make` as root in the source
  # tree, creating root-owned object files that poison the next user build
  # (Permission denied). Require a finished build first. (Learned the hard way.)
  if [[ ! -f modules.order || ! -f arch/x86/boot/bzImage || ! -f vmlinux ]]; then
    die "build not complete (missing vmlinux/bzImage/modules.order). Run \`arch-asf/build.sh build\` as your normal user and let it FINISH, then re-run install. Never run install while a build is in progress."
  fi
  # Guard: a prior interrupted root run may have left root-owned artifacts. If any
  # exist, the build is poisoned — tell the user to restore ownership first.
  if find . -user root -not -path './.git/*' -name '*.o' -print -quit 2>/dev/null | grep -q .; then
    die "root-owned build artifacts found in the source tree (from an earlier root run). Restore ownership first:  sudo chown -R $(stat -c '%U' arch-asf/build.sh):$(stat -c '%G' arch-asf/build.sh) ."
  fi

  local krel
  krel="$(make -s kernelrelease)"
  log "install: kernelrelease=${krel}"

  # 1. modules_install
  log "install: modules_install (INSTALL_MOD_STRIP=1)"
  make LLVM=1 INSTALL_MOD_STRIP=1 modules_install

  # 2. kernel image -> /boot/vmlinuz-linux-riff
  log "install: /boot/vmlinuz-linux-riff"
  install -Dm644 arch/x86/boot/bzImage /boot/vmlinuz-linux-riff

  # 3. mkinitcpio preset + initramfs
  log "install: /etc/mkinitcpio.d/linux-riff.preset"
  install -Dm644 "${PRESETS_DIR}/linux-riff.preset" /etc/mkinitcpio.d/linux-riff.preset
  log "install: mkinitcpio -p linux-riff"
  # mkinitcpio returns non-zero on soft-error warnings (e.g. a module listed in
  # /etc/mkinitcpio.conf MODULES=() that doesn't exist for this kernel build).
  # The initramfs is still created and bootable; don't abort the install over it.
  mkinitcpio -p linux-riff || warn "mkinitcpio exited non-zero (soft warnings only) — continuing"

  # 4. boot entries
  write_boot_entries

  log "install OK — entries written, default entry NOT modified"
  log "next: run arch-asf/verify.sh, then reboot and pick 'Arch Linux Riff'"
}

# Derive the kernel root cmdline portably from THIS host (not a hardcoded
# arch.conf — that's specific to one machine and breaks on a friend's box).
# Order: explicit ROOT_OPTS override → host's systemd-boot default entry →
# any non-riff loader entry → the running kernel's /proc/cmdline. Image- and
# riff-managed tokens are stripped (the templates re-add lsm/lockdown/etc.).
derive_root_opts() {
  if [[ -n "${ROOT_OPTS:-}" ]]; then printf '%s' "${ROOT_OPTS}"; return 0; fi
  local raw="" def="" cand
  [[ -f /boot/loader/loader.conf ]] && def="$(awk '/^default/{print $2; exit}' /boot/loader/loader.conf)"
  for cand in "/boot/loader/entries/${def}" /boot/loader/entries/*.conf; do
    [[ -f "${cand}" ]] || continue
    [[ "${cand}" == *linux-riff* ]] && continue   # don't seed from our own entries
    raw="$(grep -E '^options ' "${cand}" 2>/dev/null | head -1 | sed -E 's/^options +//')"
    [[ -n "${raw}" ]] && break
  done
  [[ -z "${raw}" ]] && raw="$(cat /proc/cmdline 2>/dev/null)"
  # Strip image-specific + template-managed tokens; keep root=/rw/rootflags=/etc.
  printf '%s' "${raw}" | tr ' ' '\n' | grep -vE \
    '^(initrd=|BOOT_IMAGE=|lsm=|apparmor=|lockdown=|mitigations=|amdgpu\.ppfeaturemask=)' \
    | paste -sd' '
}

# ----- boot entries (shared by install + entries) --------------------------
# Dispatch on the host's bootloader: systemd-boot (loader entries) or GRUB
# (grub.d generator). Never writes the host's default/other-OS entries.
# Portable across machines via derive_root_opts.
write_boot_entries() {
  if [[ -d /boot/loader/entries ]]; then
    write_sdboot_entries "$@"
  elif command -v grub-mkconfig >/dev/null 2>&1 \
       && { [[ -d /boot/grub ]] || [[ -d /boot/grub2 ]]; }; then
    write_grub_entries "$@"
  else
    warn "no systemd-boot (/boot/loader/entries) and no GRUB (/boot/grub) found."
    warn "kernel + modules + initramfs ARE installed; add a boot entry to your"
    warn "bootloader manually. Linux: /boot/vmlinuz-linux-riff  initrd: /boot/initramfs-linux-riff.img"
    warn "cmdline: $(derive_root_opts) lsm=landlock,lockdown,yama,integrity,apparmor,bpf apparmor=1 lockdown=integrity"
    die  "unrecognised bootloader — see the manual cmdline above (set ROOT_OPTS=... to override the derived root spec)."
  fi
}

# systemd-boot: regenerate the four riff loader entries from the boot/ templates.
write_sdboot_entries() {
  local root_opts
  root_opts="$(derive_root_opts)"
  if [[ "${root_opts}" != *root=* ]]; then
    die "could not derive a root= spec (no systemd-boot entry and /proc/cmdline lacks root=). Set it explicitly: sudo ROOT_OPTS='root=UUID=<your-root> rw rootflags=subvol=@' ./arch-asf/build.sh ${1:-install}"
  fi
  log "entries: root options = ${root_opts}"

  local lsm_stack="lsm=landlock,lockdown,yama,integrity,apparmor,bpf apparmor=1"

  install_entry() {
    local src="$1" dst="$2" lockdown_mode="$3"
    sed \
      -e "s|@ROOT_OPTS@|${root_opts}|g" \
      -e "s|@LSM_STACK@|${lsm_stack}|g" \
      -e "s|@LOCKDOWN@|${lockdown_mode}|g" \
      "${src}" > "${dst}"
    chmod 644 "${dst}"
    log "entries: ${dst}"
  }

  install_entry "${BOOT_TMPL_DIR}/linux-riff.conf.tmpl"          /boot/loader/entries/linux-riff.conf          "lockdown=integrity"
  install_entry "${BOOT_TMPL_DIR}/linux-riff-fallback.conf.tmpl" /boot/loader/entries/linux-riff-fallback.conf "lockdown=integrity"
  install_entry "${BOOT_TMPL_DIR}/linux-riff-relaxed.conf.tmpl"  /boot/loader/entries/linux-riff-relaxed.conf  ""
  # max-perf: mitigations=off but lockdown=integrity + full LSM stack stay ON.
  # Opt-in speed entry; the default secure entry is unchanged.
  install_entry "${BOOT_TMPL_DIR}/linux-riff-maxperf.conf.tmpl"  /boot/loader/entries/linux-riff-maxperf.conf  "lockdown=integrity"
}

# GRUB: install the /etc/grub.d generator (with the host's root spec baked in)
# and regenerate grub.cfg. The generator emits the same four riff variants as
# the systemd-boot path and re-runs cleanly on later grub upgrades.
write_grub_entries() {
  local root_opts gen_src gen_dst grub_cfg
  root_opts="$(derive_root_opts)"
  if [[ "${root_opts}" != *root=* ]]; then
    die "could not derive a root= spec (no usable boot entry and /proc/cmdline lacks root=). Set it explicitly: sudo ROOT_OPTS='root=UUID=<your-root> rw rootflags=subvol=@' ./arch-asf/build.sh ${1:-install}"
  fi
  log "entries(grub): root options = ${root_opts}"

  gen_src="${BOOT_TMPL_DIR}/42_linux-riff.grub.tmpl"
  gen_dst="/etc/grub.d/42_linux-riff"
  [[ -f "${gen_src}" ]] || die "missing GRUB generator template: ${gen_src}"

  sed -e "s|@ROOT_OPTS@|${root_opts}|g" "${gen_src}" > "${gen_dst}"
  chmod 755 "${gen_dst}"
  log "entries(grub): installed generator ${gen_dst}"

  if   [[ -d /boot/grub ]];  then grub_cfg=/boot/grub/grub.cfg
  elif [[ -d /boot/grub2 ]]; then grub_cfg=/boot/grub2/grub.cfg
  else die "GRUB detected but neither /boot/grub nor /boot/grub2 exists"; fi

  command -v grub-mkconfig >/dev/null 2>&1 \
    || die "grub-mkconfig not found — install grub, then re-run: sudo ./arch-asf/build.sh entries"
  log "entries(grub): regenerating ${grub_cfg}"
  grub-mkconfig -o "${grub_cfg}"
  log "entries(grub): done — pick an 'Arch Linux Riff — …' entry at boot"
}

# ----- entries -------------------------------------------------------------
# Rewrite the riff boot entries ONLY (e.g. after a cmdline/ppfeaturemask change)
# without touching the kernel image, modules, or initramfs. Fast; needs root.
cmd_entries() {
  if [[ $EUID -ne 0 ]]; then
    die "entries must run as root (sudo ./arch-asf/build.sh entries)"
  fi
  [[ -f /boot/vmlinuz-linux-riff ]] \
    || die "/boot/vmlinuz-linux-riff missing — install the kernel first (build.sh install)"
  write_boot_entries
  log "entries OK — riff loader entries rewritten, default entry NOT modified"
}

# ----- all -----------------------------------------------------------------
cmd_all() {
  cmd_preflight
  cmd_config
  cmd_build
  log "all OK — run 'sudo ./arch-asf/build.sh install' to deploy"
}

# ----- dispatch ------------------------------------------------------------
case "${1:-}" in
  preflight) cmd_preflight ;;
  config)    cmd_config ;;
  build)     cmd_build ;;
  install)   cmd_install ;;
  entries)   cmd_entries ;;
  all|"")    cmd_all ;;
  *) die "usage: $0 {preflight|config|build|install|entries|all}" ;;
esac
