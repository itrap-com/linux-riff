#!/usr/bin/env bash
# autofdo.sh — turnkey AutoFDO (PGO) for the riff kernel. No AUR packages:
# uses llvm-profgen (bundled with LLVM) instead of create_llvm_prof, and AMD
# Zen4 amd_lbr_v2 branch sampling for the profile.
#
# AutoFDO is a 3-stage, 2-reboot process. You profile YOUR real workload, so the
# compiler optimizes your actual hot paths (front-end/branch stalls especially).
#
#   sudo ./arch-asf/autofdo.sh stage1        # build+stay: reference kernel (AUTOFDO on, no profile)
#        ./arch-asf/autofdo.sh profile WORKLOAD...   # collect perf + make .afdo (run after rebooting stage1)
#   sudo ./arch-asf/autofdo.sh stage2        # rebuild optimized with the .afdo profile
#
# FULL FLOW:
#   1. sudo ./arch-asf/autofdo.sh stage1      → build reference kernel
#      sudo ./arch-asf/build.sh install       → install it
#      reboot into "Arch Linux Riff"
#   2. ./arch-asf/autofdo.sh profile -- glmark2          (or: a game, a compile, your real load)
#      → writes arch-asf/autofdo/riff.afdo
#   3. sudo ./arch-asf/autofdo.sh stage2      → rebuild with the profile
#      sudo ./arch-asf/build.sh install       → install the optimized kernel
#      reboot — done.
#
# A representative workload matters more than a long one: run what you actually
# care about being fast (your game, your compiler, your encoder) for ~1-2 min.
set -euo pipefail

ASF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${ASF_DIR}/.." && pwd)"
OUT_DIR="${ASF_DIR}/autofdo"
PROFILE="${OUT_DIR}/riff.afdo"
VMLINUX_SAVE="${OUT_DIR}/vmlinux.reference"
PERF_EVENT="RETIRED_TAKEN_BRANCH_INSTRUCTIONS:k"   # Zen4 amd_lbr_v2 event for AutoFDO
PERF_PERIOD=500009                                  # prime sample period per kernel docs

log()  { printf '\033[1;36m[autofdo]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[autofdo:warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[autofdo:err]\033[0m %s\n' "$*" >&2; exit 1; }

cd "${ROOT_DIR}"
mkdir -p "${OUT_DIR}"

# Memory-aware job count (mirrors build.sh: ThinLTO relink is RAM-heavy).
jobs() {
  local j="${JOBS:-$(nproc)}" avail cap
  avail="$(awk '/MemAvailable/ {print int($2/1024/1024)}' /proc/meminfo)"
  cap=$(( avail / 4 )); (( cap < 4 )) && cap=4
  (( cap < j )) && j="$cap"
  echo "$j"
}

# Build .config with the riff fragments + AUTOFDO_CLANG enabled. $1 = optional
# profile path passed through CLANG_AUTOFDO_PROFILE for stage2.
configure_autofdo() {
  log "config: merge riff fragments (via build.sh config)"
  ./arch-asf/build.sh config >/dev/null
  log "config: enable CONFIG_AUTOFDO_CLANG"
  ./scripts/config --file .config -e AUTOFDO_CLANG
  make LLVM=1 olddefconfig >/dev/null
  grep -q '^CONFIG_AUTOFDO_CLANG=y' .config \
    || die "AUTOFDO_CLANG did not stick — check CC_IS_CLANG / ARCH_SUPPORTS_AUTOFDO_CLANG"
  log "config: AUTOFDO_CLANG=y confirmed"
}

case "${1:-}" in
  # ---- stage1: reference kernel (AutoFDO build config, no profile yet) -------
  stage1)
    [[ $EUID -eq 0 ]] && warn "stage1 builds as root — prefer running it UNPRIVILEGED, then 'sudo build.sh install'."
    configure_autofdo
    J="$(jobs)"; log "build: make LLVM=1 -j${J} (reference)"
    make LLVM=1 -j"${J}"
    make LLVM=1 -j"${J}" modules
    cp -f vmlinux "${VMLINUX_SAVE}"
    log "stage1 OK. Saved reference vmlinux -> ${VMLINUX_SAVE}"
    log "next: sudo ./arch-asf/build.sh install ; reboot into riff ; then 'autofdo.sh profile -- <workload>'"
    ;;

  # ---- profile: collect perf during a workload, convert to .afdo ------------
  profile)
    shift
    [[ "${1:-}" == "--" ]] && shift
    (( $# )) || die "usage: autofdo.sh profile -- <workload command...>   (e.g. -- glmark2)"
    [[ "$(uname -r)" == *-riff* ]] || warn "not booted into a -riff kernel; profile should be collected on the stage1 kernel."
    [[ -f "${VMLINUX_SAVE}" ]] || die "missing ${VMLINUX_SAVE} — run stage1 first (its vmlinux must match the booted kernel)."
    command -v llvm-profgen >/dev/null || die "llvm-profgen missing (install llvm)."
    grep -q amd_lbr_v2 /proc/cpuinfo || die "amd_lbr_v2 absent — AutoFDO sampling unsupported on this CPU."

    local perf_raw="${OUT_DIR}/riff.perf"
    local paranoid; paranoid="$(cat /proc/sys/kernel/perf_event_paranoid)"
    if (( paranoid > 1 )) && [[ $EUID -ne 0 ]]; then
      warn "perf_event_paranoid=${paranoid} blocks system-wide sampling. Re-run with sudo, or:"
      warn "  sudo sysctl kernel.perf_event_paranoid=1   (revert after with =2)"
    fi
    log "profiling: perf record --pfm-events ${PERF_EVENT} -a -N -b -c ${PERF_PERIOD}"
    log "workload: $*"
    perf record --pfm-events "${PERF_EVENT}" -a -N -b -c "${PERF_PERIOD}" -o "${perf_raw}" -- "$@"
    log "convert: llvm-profgen --kernel -> ${PROFILE}"
    llvm-profgen --kernel --binary="${VMLINUX_SAVE}" --perfdata="${perf_raw}" -o "${PROFILE}"
    [[ -s "${PROFILE}" ]] || die "empty profile — workload may have been too short or sampling was blocked."
    log "profile OK -> ${PROFILE} ($(du -h "${PROFILE}" | cut -f1)). Next: sudo ./arch-asf/autofdo.sh stage2"
    ;;

  # ---- stage2: optimized rebuild using the .afdo profile --------------------
  stage2)
    [[ -s "${PROFILE}" ]] || die "no profile at ${PROFILE} — run 'profile' first."
    [[ $EUID -eq 0 ]] && warn "stage2 builds as root — prefer UNPRIVILEGED, then 'sudo build.sh install'."
    configure_autofdo
    J="$(jobs)"; log "build: make LLVM=1 CLANG_AUTOFDO_PROFILE=${PROFILE} -j${J} (optimized)"
    make LLVM=1 CLANG_AUTOFDO_PROFILE="${PROFILE}" -j"${J}"
    make LLVM=1 CLANG_AUTOFDO_PROFILE="${PROFILE}" -j"${J}" modules
    log "stage2 OK — optimized kernel built. next: sudo ./arch-asf/build.sh install ; reboot."
    ;;

  *)
    die "usage: $0 {stage1|profile -- <workload...>|stage2}"
    ;;
esac
