#!/usr/bin/env bash
# arch-asf runtime tuning — applies the staged network/privacy layers to /etc.
# Idempotent; backs up anything it removes. Run as root:
#   sudo ./arch-asf/runtime/apply.sh
#
# Layers:
#   1. Network sysctl — consolidate 6 overlapping drop-ins into one authoritative
#      file (keep 99-tailscale.conf).
#   2. Firewall — keep ufw (active), disable the redundant nftables.service.
#   3. Wi-Fi MAC privacy — per-connection stable-random MAC + scan randomization.
#   4. DNS — force DNS-over-TLS (strict).

set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "must run as root: sudo $0" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/riff-runtime-backup-${STAMP}"
mkdir -p "${BACKUP}"
echo ">> backups -> ${BACKUP}"

say() { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }

# ---- Layer 1: network sysctl --------------------------------------------------
say "Layer 1: network sysctl consolidation"
REDUNDANT=(90-swappiness.conf 98-socket-buffers.conf 99-desktop-latency.conf \
           99-net-tune.conf 99-net-tuning.conf 99-network-tuning.conf)
for f in "${REDUNDANT[@]}"; do
  if [[ -e "/etc/sysctl.d/${f}" ]]; then
    cp -a "/etc/sysctl.d/${f}" "${BACKUP}/" && rm -f "/etc/sysctl.d/${f}"
    echo "  removed (backed up): ${f}"
  fi
done
install -Dm644 "${SCRIPT_DIR}/sysctl/99-riff-network.conf" /etc/sysctl.d/99-riff-network.conf
echo "  installed: /etc/sysctl.d/99-riff-network.conf  (kept: 99-tailscale.conf)"
sysctl --system >/dev/null && echo "  sysctl --system applied"

# ---- Layer 2: firewall --------------------------------------------------------
say "Layer 2: firewall (keep ufw, drop redundant nftables.service)"
if systemctl is-enabled nftables >/dev/null 2>&1; then
  systemctl disable --now nftables 2>/dev/null || true
  echo "  nftables.service disabled + stopped"
fi
systemctl enable --now ufw >/dev/null 2>&1 && echo "  ufw enabled + active"
echo "  ufw status:"; ufw status verbose | sed 's/^/    /'

# ---- Layer 3: Wi-Fi MAC privacy ----------------------------------------------
say "Layer 3: Wi-Fi MAC privacy"
install -Dm644 "${SCRIPT_DIR}/NetworkManager/30-riff-mac-privacy.conf" \
  /etc/NetworkManager/conf.d/30-riff-mac-privacy.conf
echo "  installed: /etc/NetworkManager/conf.d/30-riff-mac-privacy.conf"
# reload NM config without dropping the active connection where possible
systemctl reload NetworkManager 2>/dev/null \
  && echo "  NetworkManager reloaded (reconnect Wi-Fi to pick up new MAC)" \
  || echo "  reload NetworkManager manually to apply"

# ---- Layer 4: DNS-over-TLS strict --------------------------------------------
say "Layer 4: DNS-over-TLS (strict)"
install -Dm644 "${SCRIPT_DIR}/resolved.conf.d/90-riff-dot-strict.conf" \
  /etc/systemd/resolved.conf.d/90-riff-dot-strict.conf
echo "  installed: /etc/systemd/resolved.conf.d/90-riff-dot-strict.conf"
systemctl restart systemd-resolved && echo "  systemd-resolved restarted"

say "done"
echo "verify:"
echo "  sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc vm.swappiness"
echo "  systemctl is-enabled nftables ufw   # disabled / enabled"
echo "  resolvectl status | grep -i DNSOverTLS"
echo "  nmcli -g 802-11-wireless.cloned-mac-address connection show <wifi> 2>/dev/null"
echo "rollback: configs saved in ${BACKUP}"
