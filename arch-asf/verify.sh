#!/usr/bin/env bash
# linux-riff verification.
# Default: pre-install checks (fragments present, config built, kernel image built).
# With --runtime: post-reboot checks (running kernel name, LSM, lockdown, AMD-Vi, etc.)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ASF_DIR="${REPO_ROOT}/arch-asf"
FRAG_DIR="${ASF_DIR}/fragments"

PASS=0
FAIL=0

ok()   { printf '  \033[1;32m✓\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  \033[1;31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
sect() { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }

check_kv() {
  local key="$1" want="$2" file="$3"
  local got=""
  # pipefail-safe: if grep finds nothing the pipeline returns non-zero;
  # capture into got="" without killing the script under set -e.
  got="$( { grep -E "^${key}=" "${file}" 2>/dev/null || true; } | head -n1 | cut -d= -f2- )"
  if [[ "${got}" == "${want}" ]]; then ok "${key} = ${want}"; else bad "${key} = ${got:-<unset>} (want ${want})"; fi
}

check_y() { check_kv "CONFIG_$1" "y" "${2:-${REPO_ROOT}/.config}"; }
check_m() { check_kv "CONFIG_$1" "m" "${2:-${REPO_ROOT}/.config}"; }

mode_preinstall() {
  sect "fragments present"
  local expected=(10-cpu-zen4 15-sched-latency 20-mm-perf 25-io-perf 30-net-perf 35-net-anon \
    40-crypto-accel 45-virt-iommu 50-gpu-rocm 55-ntsync 60-security 65-hardening 70-privacy \
    80-lto-clang 90-disable-unused 99-localversion)
  for f in "${expected[@]}"; do
    [[ -f "${FRAG_DIR}/${f}.cfg" ]] && ok "${f}.cfg" || bad "missing ${f}.cfg"
  done

  if [[ ! -f "${REPO_ROOT}/.config" ]]; then
    sect "no .config yet — run 'arch-asf/build.sh config' first"
    summarize; return
  fi

  sect "config: core toolchain (LTO/CFI)"
  check_y LTO_CLANG_THIN
  # 7.0 renamed CFI_CLANG -> CFI (CFI_CLANG is now a transitional compat symbol).
  check_y CFI
  check_y CFI_AUTO_DEFAULT
  check_y LD_IS_LLD

  sect "config: CPU / scheduler"
  check_y X86_AMD_PSTATE
  check_kv CONFIG_X86_AMD_PSTATE_DEFAULT_MODE 3 "${REPO_ROOT}/.config"
  check_y SCHED_CLUSTER
  check_y PREEMPT

  sect "config: memory"
  check_y LRU_GEN
  check_y LRU_GEN_ENABLED
  check_y ZSWAP
  check_y TRANSPARENT_HUGEPAGE

  sect "config: net + anonymity"
  check_y TCP_CONG_BBR
  check_y NET_SCH_FQ
  check_y WIREGUARD
  check_m MT7925E

  sect "config: security + privacy"
  check_y SECURITY_APPARMOR
  check_y SECURITY_LANDLOCK
  check_y SECURITY_LOCKDOWN_LSM
  check_y FORTIFY_SOURCE
  check_y VMAP_STACK
  check_y INIT_ON_ALLOC_DEFAULT_ON
  check_y STRICT_DEVMEM

  sect "config: virt + gpu + features"
  check_m KVM_AMD
  check_y AMD_IOMMU
  check_m VFIO_PCI
  check_m DRM_AMDGPU
  check_y HSA_AMD
  check_m NTSYNC
  check_y IA32_EMULATION

  sect "config: kernel name"
  check_kv CONFIG_LOCALVERSION '"-riff"' "${REPO_ROOT}/.config"

  sect "build artifacts"
  if [[ -f "${REPO_ROOT}/arch/x86/boot/bzImage" ]]; then
    local sz
    sz="$(stat -c%s "${REPO_ROOT}/arch/x86/boot/bzImage")"
    ok "bzImage built (${sz} bytes)"
  else
    bad "bzImage not built (run arch-asf/build.sh build)"
  fi

  summarize
}

mode_runtime() {
  sect "running kernel"
  local krel; krel="$(uname -r)"
  if [[ "${krel}" == *-riff* ]]; then ok "uname -r = ${krel}"; else bad "uname -r = ${krel} (expected *-riff*)"; fi

  sect "lockdown state"
  if [[ -r /sys/kernel/security/lockdown ]]; then
    local lk; lk="$(cat /sys/kernel/security/lockdown)"
    ok "lockdown = ${lk}"
  else
    bad "no /sys/kernel/security/lockdown (lockdown LSM not active?)"
  fi

  sect "LSM stack"
  if [[ -r /sys/kernel/security/lsm ]]; then
    ok "lsm = $(cat /sys/kernel/security/lsm)"
  else
    bad "no /sys/kernel/security/lsm"
  fi

  sect "AppArmor"
  if [[ -d /sys/kernel/security/apparmor ]]; then ok "apparmor enabled"; else bad "apparmor not active"; fi

  sect "AMD-Vi / IOMMU"
  if dmesg 2>/dev/null | grep -qi 'AMD-Vi.*enabled'; then ok "AMD-Vi enabled"; else bad "AMD-Vi not enabled (check dmesg)"; fi

  sect "amd-pstate-epp"
  if [[ -r /sys/devices/system/cpu/amd_pstate/status ]]; then
    ok "amd_pstate status = $(cat /sys/devices/system/cpu/amd_pstate/status)"
  else
    bad "amd_pstate not active"
  fi

  sect "TCP congestion"
  ok "tcp_congestion_control = $(sysctl -n net.ipv4.tcp_congestion_control)"
  ok "default_qdisc          = $(sysctl -n net.core.default_qdisc)"

  sect "BBR module"
  if grep -q '^tcp_bbr ' /proc/modules || lsmod | grep -q '^tcp_bbr'; then
    ok "tcp_bbr loaded"
  else
    ok "tcp_bbr built-in or not yet loaded (OK if sysctl shows bbr)"
  fi

  sect "ntsync device"
  if [[ -c /dev/ntsync ]]; then ok "/dev/ntsync present"; else bad "/dev/ntsync missing (load ntsync module)"; fi

  sect "KFD compute"
  if [[ -d /sys/class/kfd ]] || [[ -c /dev/kfd ]]; then ok "kfd present"; else bad "kfd device missing"; fi

  summarize
}

summarize() {
  printf '\n\033[1;36m== summary ==\033[0m\n  PASS: %d   FAIL: %d\n' "${PASS}" "${FAIL}"
  (( FAIL == 0 ))
}

case "${1:-}" in
  --runtime|-r) mode_runtime ;;
  --help|-h) printf 'usage: %s [--runtime]\n  (no flag)   pre-install fragment/config/build checks\n  --runtime   post-reboot kernel state checks\n' "$0" ;;
  *) mode_preinstall ;;
esac
