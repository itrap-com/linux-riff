#!/usr/bin/env bash
# install-maxperf-entry.sh — install ONLY the "Arch Linux Riff (max-perf)" boot entry.
#
# Run with sudo:
#   sudo ./arch-asf/install-maxperf-entry.sh           # write the entry (default)
#   sudo ./arch-asf/install-maxperf-entry.sh --prune-stale   # also remove stale riff module dirs
#
# What it does (and refuses to do):
#   * Derives root= / rootflags / LSM stack from /boot/loader/entries/arch.conf,
#     IDENTICALLY to arch-asf/build.sh — it never hardcodes your UUID.
#   * Writes /boot/loader/entries/linux-riff-maxperf.conf with lockdown=integrity +
#     full LSM stack ON and mitigations=off (opt-in speed entry).
#   * NEVER touches arch.conf (the default "Arch Linux Zen" entry) or any other entry.
#   * Backs up an existing maxperf entry before overwriting.
#   * --prune-stale only: removes /lib/modules/*-riff+ dirs that are NOT the current
#     build. The current build is auto-detected; it is never removed. Without the flag,
#     stale dirs are only reported.
#
set -euo pipefail

# ----- preflight -------------------------------------------------------------
if [[ ${EUID} -ne 0 ]]; then
  echo "error: must run as root.  sudo $0 $*" >&2
  exit 1
fi

PRUNE_STALE=0
[[ "${1:-}" == "--prune-stale" ]] && PRUNE_STALE=1

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPL="${REPO_DIR}/arch-asf/boot/linux-riff-maxperf.conf.tmpl"
ARCH_CONF="/boot/loader/entries/arch.conf"
DST="/boot/loader/entries/linux-riff-maxperf.conf"
TS="$(date +%Y%m%d-%H%M%S)"

[[ -f "${TMPL}" ]]      || { echo "error: template not found: ${TMPL}" >&2; exit 1; }
# This standalone helper is systemd-boot only. On GRUB, the max-perf variant is
# emitted by the /etc/grub.d/42_linux-riff generator — use the main installer.
if [[ ! -f "${ARCH_CONF}" ]] && { [[ -d /boot/grub ]] || [[ -d /boot/grub2 ]]; }; then
  echo "error: this host uses GRUB, not systemd-boot." >&2
  echo "       The max-perf entry is generated automatically on GRUB. Run:" >&2
  echo "         sudo ${REPO_DIR}/arch-asf/build.sh entries" >&2
  exit 1
fi
[[ -f "${ARCH_CONF}" ]] || { echo "error: ${ARCH_CONF} not found — cannot derive root spec" >&2; exit 1; }
[[ -f /boot/vmlinuz-linux-riff ]]        || { echo "error: /boot/vmlinuz-linux-riff missing — build/install the kernel first" >&2; exit 1; }
[[ -f /boot/initramfs-linux-riff.img ]]  || { echo "error: /boot/initramfs-linux-riff.img missing — run mkinitcpio first" >&2; exit 1; }

# ----- derive tokens (same logic as build.sh) --------------------------------
root_opts="$(grep -E '^options ' "${ARCH_CONF}" \
  | sed -E 's/^options +//; s/ +lsm=.*//; s/ +lockdown=[^ ]+//')"
[[ -n "${root_opts}" ]] || { echo "error: could not derive root options from ${ARCH_CONF}" >&2; exit 1; }

lsm_stack="lsm=landlock,lockdown,yama,integrity,apparmor,bpf apparmor=1"
lockdown_mode="lockdown=integrity"

echo "root options : ${root_opts}"
echo "lsm stack    : ${lsm_stack}"
echo "lockdown     : ${lockdown_mode}"
echo

# ----- write the maxperf entry (back up first) -------------------------------
if [[ -f "${DST}" ]]; then
  cp -p "${DST}" "${DST}.bak.${TS}"
  echo "backed up existing entry -> ${DST}.bak.${TS}"
fi

sed \
  -e "s|@ROOT_OPTS@|${root_opts}|g" \
  -e "s|@LSM_STACK@|${lsm_stack}|g" \
  -e "s|@LOCKDOWN@|${lockdown_mode}|g" \
  "${TMPL}" > "${DST}"
chmod 644 "${DST}"

echo "wrote ${DST}:"
echo "----------------------------------------------------------------------"
cat "${DST}"
echo "----------------------------------------------------------------------"

# Sanity: the default entry must be untouched.
if grep -q '^title.*Riff' "${ARCH_CONF}" 2>/dev/null; then
  echo "WARNING: ${ARCH_CONF} unexpectedly mentions Riff — inspect manually." >&2
fi

# ----- stale module-dir sweep (report by default, prune on flag) -------------
current_riff="$(ls -1d /lib/modules/*-riff+ 2>/dev/null | sort -V | tail -1)"
echo
echo "current riff modules dir (kept): ${current_riff:-<none found>}"
mapfile -t riff_dirs < <(ls -1d /lib/modules/*-riff+ 2>/dev/null || true)
stale=()
for d in "${riff_dirs[@]}"; do
  [[ "${d}" == "${current_riff}" ]] || stale+=("${d}")
done

if (( ${#stale[@]} == 0 )); then
  echo "stale riff module dirs: none"
else
  echo "stale riff module dirs detected:"
  for d in "${stale[@]}"; do echo "  - ${d}"; done
  if (( PRUNE_STALE )); then
    for d in "${stale[@]}"; do
      echo "removing ${d}"
      rm -rf "${d}"
    done
  else
    echo "(not removed — re-run with --prune-stale to delete them)"
  fi
fi

echo
echo "Done. The default 'Arch Linux Zen' entry was NOT modified."
echo "Reboot and pick 'Arch Linux Riff (max-perf ...)' to test, then:"
echo "  ${REPO_DIR}/arch-asf/verify.sh --runtime"
