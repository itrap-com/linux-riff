# linux-asf Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build and install `linux-asf` — a custom 6.17.4-asf kernel optimized for Ryzen 9 7950X3D + RX 7900 XT + 2.5 GbE/Wi-Fi 7, with clang ThinLTO + KCFI + MZEN4, BBR/FQ networking, BORE scheduler, MGLRU + mTHP memory, full ROCm/HSA, NTSYNC, KVM/VFIO, lockdown=integrity hardening, distrust-RDRAND privacy — installed alongside existing kernels with safe rollback.

**Architecture:** Kconfig fragments (16 files in `arch-asf/fragments/`, numbered for deterministic merge order) merged via `scripts/kconfig/merge_config.sh` into the existing zen `.config` baseline. Build with `make LLVM=1 KCFLAGS=-march=znver4`. Install as `linux-asf` (new vmlinuz, mkinitcpio preset, 3 systemd-boot entries) without modifying any existing kernel. Spec reference: `arch-asf/docs/2026-05-27-linux-asf-kernel-design.md`.

**Tech Stack:** Linux kernel 6.17.4-zen, clang ≥18, lld ≥18, llvm-binutils, pahole ≥1.25, mkinitcpio ≥38, systemd-boot.

---

## File structure

```
arch-asf/
├── README.md                         [Task 1]
├── .gitignore                        [Task 1]
├── build.sh                          [Task 19]
├── verify.sh                         [Task 20]
├── fragments/
│   ├── 10-cpu-zen4.cfg               [Task 4]
│   ├── 15-sched-latency.cfg          [Task 5]
│   ├── 20-mm-perf.cfg                [Task 6]
│   ├── 25-io-perf.cfg                [Task 7]
│   ├── 30-net-perf.cfg               [Task 8]
│   ├── 35-net-anon.cfg               [Task 9]
│   ├── 40-crypto-accel.cfg           [Task 10]
│   ├── 45-virt-iommu.cfg             [Task 11]
│   ├── 50-gpu-rocm.cfg               [Task 12]
│   ├── 55-ntsync.cfg                 [Task 13]
│   ├── 60-security.cfg               [Task 14]
│   ├── 65-hardening.cfg              [Task 15]
│   ├── 70-privacy.cfg                [Task 16]
│   ├── 80-lto-clang.cfg              [Task 17]
│   ├── 90-disable-unused.cfg         [Task 18a]
│   └── 99-localversion.cfg           [Task 18b]
├── presets/
│   └── linux-asf.preset              [Task 21]
├── boot/
│   ├── linux-asf.conf.tmpl           [Task 22]
│   ├── linux-asf-fallback.conf.tmpl  [Task 22]
│   └── linux-asf-relaxed.conf.tmpl   [Task 22]
└── docs/
    ├── 2026-05-27-linux-asf-kernel-design.md         (already exists)
    └── 2026-05-27-linux-asf-implementation-plan.md   (this file)
```

Each fragment task = create the file, commit. After all fragments exist, **Task 23** does the merge + `olddefconfig` and surfaces any symbol drift; **Tasks 24-27** build and install; **Task 28** is the verify+handoff.

Working directory for every task: `/home/usernew/arch-linux/zen-kernel` unless otherwise stated. All commits go on branch `6.17/main` (already checked out).

---

## Task 1: Scaffold arch-asf directory

**Files:**
- Create: `arch-asf/README.md`
- Create: `arch-asf/.gitignore`
- Create: `arch-asf/fragments/.gitkeep`
- Create: `arch-asf/presets/.gitkeep`
- Create: `arch-asf/boot/.gitkeep`

- [ ] **Step 1: Create directory layout**

```bash
cd /home/usernew/arch-linux/zen-kernel
mkdir -p arch-asf/fragments arch-asf/presets arch-asf/boot
touch arch-asf/fragments/.gitkeep arch-asf/presets/.gitkeep arch-asf/boot/.gitkeep
```

- [ ] **Step 2: Write `arch-asf/README.md`**

```markdown
# arch-asf — linux-asf custom kernel for 7950X3D / RX 7900 XT

Builds a custom `linux-asf` kernel alongside the upstream `linux`/`linux-lts`/`linux-zen`
packages, optimized for this exact hardware. See `docs/` for design + plan.

## Quick start

    ./build.sh all          # config + build + modules-install + install
    ./build.sh help         # list actions

## Layout

- `fragments/` — Kconfig fragments merged into `.config` via `merge_config.sh`
- `build.sh`   — driver
- `verify.sh`  — pre-install and `--runtime` post-boot checks
- `presets/`   — mkinitcpio preset
- `boot/`      — systemd-boot entry templates

## Safety

- Original `.config` saved as `.config.preasf.bak` on first run.
- Existing kernels (linux, linux-lts, linux-zen) are never touched.
- The default systemd-boot entry is not changed; you pick `linux-asf` from the menu.

## Rollback

    sudo rm /boot/vmlinuz-linux-asf /boot/initramfs-linux-asf*.img \
            /boot/System.map-linux-asf /boot/loader/entries/arch-asf*.conf \
            /etc/mkinitcpio.d/linux-asf.preset
    sudo rm -rf /lib/modules/6.17.4-asf
    cp .config.preasf.bak .config && make olddefconfig
```

- [ ] **Step 3: Write `arch-asf/.gitignore`**

```gitignore
# build artifacts
last-diff.txt
*.log
.merged/
profiles/
```

- [ ] **Step 4: Commit**

```bash
cd /home/usernew/arch-linux/zen-kernel
git add arch-asf/README.md arch-asf/.gitignore arch-asf/fragments/.gitkeep arch-asf/presets/.gitkeep arch-asf/boot/.gitkeep
git -c commit.gpgsign=false commit -m "arch-asf: scaffold project layout"
```

---

## Task 2: Preflight symbol-existence audit

**Files:**
- Create: `arch-asf/symbol-audit.txt` (audit output, committed for reference)

This catches Kconfig symbol drift between our spec and the actual 6.17.4-zen tree before we write fragments. If any required symbol is missing, we adjust the fragment in its task.

- [ ] **Step 1: Run audit script**

```bash
cd /home/usernew/arch-linux/zen-kernel

SYMBOLS=(
  MZEN4 X86_AMD_PSTATE X86_AMD_PSTATE_DEFAULT_MODE AMD_HSMP AMD_PMC AMD_PMF AMD_NB
  PERF_EVENTS_AMD_BRS PERF_EVENTS_AMD_UNCORE PERF_EVENTS_AMD_POWER
  CRYPTO_DEV_CCP CRYPTO_DEV_CCP_DD AMD_PTDMA CRYPTO_DEV_SP_PSP
  SCHED_BORE RCU_NOCB_CPU RCU_NOCB_CPU_DEFAULT_ALL RCU_BOOST SCHED_AUTOGROUP
  SCHED_CLUSTER HZ_1000 NO_HZ_IDLE SCHEDSTATS
  TRANSPARENT_HUGEPAGE_MADVISE READ_ONLY_THP_FOR_FS THP_SWAP
  LRU_GEN LRU_GEN_ENABLED PER_VMA_LOCK NUMA_BALANCING KSM
  ZSWAP ZSWAP_DEFAULT_ON ZSWAP_COMPRESSOR_DEFAULT_ZSTD
  ZRAM ZRAM_DEF_COMP_ZSTD ZRAM_WRITEBACK SHUFFLE_PAGE_ALLOCATOR SLAB_FREELIST_RANDOM
  NVME_MULTIPATH NVME_AUTH NVME_HWMON BLK_WBT BLK_WBT_MQ
  BLK_CGROUP_IOLATENCY BLK_CGROUP_IOCOST BLK_CGROUP_IOPRIO
  IOSCHED_BFQ BFQ_GROUP_IOSCHED BLK_INLINE_ENCRYPTION FS_ENCRYPTION FS_VERITY
  BTRFS_FS F2FS_FS
  TCP_CONG_BBR DEFAULT_BBR NET_SCH_FQ NET_SCH_FQ_CODEL NET_SCH_CAKE
  XDP_SOCKETS TLS TLS_DEVICE NET_RX_BUSY_POLL INET_DIAG_DESTROY
  IP_MULTIPLE_TABLES IP6_MULTIPLE_TABLES
  WIREGUARD NF_TABLES IP_NF_TARGET_TPROXY NF_TPROXY_IPV4 NF_TPROXY_IPV6
  IPV6_PRIVACY NET_NS USER_NS PID_NS UTS_NS IPC_NS XFRM TCP_MD5SIG
  CRYPTO_AES_NI_INTEL CRYPTO_VAES_INTEL CRYPTO_SHA256_AVX2 CRYPTO_SHA512_AVX2
  CRYPTO_GHASH_CLMUL_NI_INTEL CRYPTO_CRC32C_INTEL CRYPTO_CRC32_PCLMUL
  CRYPTO_CHACHA20_X86_64 CRYPTO_POLY1305_X86_64 CRYPTO_AEGIS128_AESNI_SSE2
  CRYPTO_BLAKE2B CRYPTO_BLAKE2S
  KVM KVM_AMD KVM_AMD_SEV KVM_SMM VHOST VHOST_NET VHOST_VSOCK VHOST_SCSI
  IOMMU_API AMD_IOMMU AMD_IOMMU_V2 IOMMU_DEFAULT_DMA_LAZY
  VFIO VFIO_IOMMU_TYPE1 VFIO_PCI VFIO_PCI_VGA VFIO_MDEV VFIO_NOIOMMU
  VIRTIO VIRTIO_PCI VIRTIO_NET VIRTIO_BLK VIRTIO_FS VIRTIO_GPU VIRTIO_IOMMU
  AMD_MEM_ENCRYPT CRYPTO_DEV_VIRTIO
  DRM_AMDGPU DRM_AMDGPU_USERPTR DRM_AMD_DC DRM_AMD_DC_FP HSA_AMD HSA_AMD_SVM HSA_AMD_P2P
  HMM_MIRROR ZONE_DEVICE DEVICE_PRIVATE DRM_SCHED DRM_TTM DRM_BUDDY
  NTSYNC
  SECURITY_LANDLOCK SECURITY_APPARMOR SECURITY_YAMA
  SECURITY_LOCKDOWN_LSM SECURITY_LOCKDOWN_LSM_EARLY LOCK_DOWN_KERNEL_FORCE_NONE
  SECURITY_DMESG_RESTRICT INTEGRITY IMA MODULE_SIG MODULE_SIG_ALL MODULE_SIG_SHA512
  FORTIFY_SOURCE VMAP_STACK SCHED_STACK_END_CHECK HARDENED_USERCOPY
  INIT_STACK_ALL_ZERO INIT_ON_ALLOC_DEFAULT_ON INIT_ON_FREE_DEFAULT_ON
  RANDOM_KMALLOC_CACHES SLAB_FREELIST_HARDENED
  RANDOMIZE_MEMORY_PHYSICAL_PADDING KFENCE KFENCE_SAMPLE_INTERVAL
  BUG_ON_DATA_CORRUPTION STRICT_KERNEL_RWX STRICT_MODULE_RWX
  DEFAULT_MMAP_MIN_ADDR LEGACY_VSYSCALL_NONE LEGACY_PTYS
  RANDOM_TRUST_CPU RANDOM_TRUST_BOOTLOADER PROC_KCORE STRICT_DEVMEM IO_STRICT_DEVMEM
  DEVKMEM KEXEC KEXEC_FILE PROC_PAGE_MONITOR BPF_UNPRIV_DEFAULT_OFF USER_NS_UNPRIVILEGED
  LTO_CLANG LTO_CLANG_THIN CFI_CLANG CFI_PERMISSIVE LD_DEAD_CODE_DATA_ELIMINATION KCSAN
  LOCALVERSION IGC MT7925E
)

PRESENT=()
MISSING=()
for s in "${SYMBOLS[@]}"; do
  if git grep -l "config $s\b" -- '*Kconfig*' >/dev/null 2>&1; then
    PRESENT+=("$s")
  else
    MISSING+=("$s")
  fi
done

{
  echo "# Symbol audit — $(date -u +%Y-%m-%dT%H:%M:%SZ) — base $(make -s kernelversion)"
  echo
  echo "## Present (${#PRESENT[@]})"; printf '%s\n' "${PRESENT[@]}" | sort
  echo
  echo "## MISSING (${#MISSING[@]}) — verify spelling or feature absence in this tree"
  printf '%s\n' "${MISSING[@]}" | sort
} > arch-asf/symbol-audit.txt

echo "Missing symbols (${#MISSING[@]}): adjust fragments if needed:"
printf '  %s\n' "${MISSING[@]}"
```

- [ ] **Step 2: Inspect output and decide adjustments**

If any symbol in MISSING is critical and you find a renamed equivalent in the kernel (e.g. `MT7925E` may be `MT7925_USB` or `MT7925_COMMON`), note the substitution. If a symbol is plain absent (e.g. `SCHED_BORE` if zen patches haven't landed BORE in this checkout), the corresponding fragment will skip that line. Record any adjustments to apply later in the relevant fragment task as a comment.

- [ ] **Step 3: Commit audit**

```bash
git add arch-asf/symbol-audit.txt
git -c commit.gpgsign=false commit -m "arch-asf: preflight Kconfig symbol audit"
```

---

## Task 3: Verify toolchain

- [ ] **Step 1: Check versions**

```bash
clang --version | head -1
ld.lld --version
llvm-objcopy --version | head -1
pahole --version
mkinitcpio --version
```

Expected: clang ≥18, lld ≥18, pahole ≥1.25, mkinitcpio ≥38.

- [ ] **Step 2: If any missing/old**

```bash
sudo pacman -S --needed clang lld llvm pahole mkinitcpio
```

No commit (no files changed).

---

## Task 4: Write `10-cpu-zen4.cfg`

**Files:**
- Create: `arch-asf/fragments/10-cpu-zen4.cfg`

- [ ] **Step 1: Create the fragment**

```ini
# 10-cpu-zen4.cfg — Zen 4 / 7950X3D CPU-specific tuning
# Replaces generic CPU target with znver4 codegen and platform drivers.

# Compile target
CONFIG_GENERIC_CPU=n
CONFIG_MZEN4=y

# P-state: amd-pstate-epp (active EPP) is correct for Zen 3+ with CPPC
CONFIG_X86_AMD_PSTATE=y
CONFIG_X86_AMD_PSTATE_DEFAULT_MODE=3
CONFIG_X86_AMD_PSTATE_UT=n

# AMD platform drivers
CONFIG_AMD_HSMP=m
CONFIG_AMD_PMC=m
CONFIG_AMD_PMF=m
CONFIG_X86_AMD_PLATFORM_DEVICE=y
CONFIG_AMD_NB=y

# Perf event sources for `perf`
CONFIG_PERF_EVENTS=y
CONFIG_PERF_EVENTS_AMD_BRS=y
CONFIG_PERF_EVENTS_AMD_UNCORE=m
CONFIG_PERF_EVENTS_AMD_POWER=m

# AMD Cryptographic Coprocessor + PassThrough DMA (also a TRNG source)
CONFIG_CRYPTO_DEV_CCP=y
CONFIG_CRYPTO_DEV_CCP_DD=y
CONFIG_CRYPTO_DEV_SP_PSP=y
CONFIG_AMD_PTDMA=m

# We are not Intel
CONFIG_X86_INTEL_PSTATE=n
```

- [ ] **Step 2: Commit**

```bash
git add arch-asf/fragments/10-cpu-zen4.cfg
git -c commit.gpgsign=false commit -m "arch-asf: 10-cpu-zen4 fragment (MZEN4, amd-pstate-epp, CCP, PMC/PMF)"
```

---

## Task 5: Write `15-sched-latency.cfg`

**Files:**
- Create: `arch-asf/fragments/15-sched-latency.cfg`

- [ ] **Step 1: Create the fragment**

```ini
# 15-sched-latency.cfg — scheduler + RCU + tick tuning for low-latency desktop
# Keep BORE only if present in this tree (audit Task 2). If absent, omit the
# CONFIG_SCHED_BORE line — zen kernel's CFS/EEVDF defaults are already strong.

# PREEMPT model: dynamic switchable at boot via preempt= cmdline
CONFIG_PREEMPT_BUILD=y
CONFIG_PREEMPT=y
CONFIG_PREEMPT_DYNAMIC=y
CONFIG_PREEMPTION=y
CONFIG_PREEMPT_COUNT=y
CONFIG_PREEMPT_RCU=y

# RCU offload — keep RCU work off the CPU running latency-critical tasks
CONFIG_RCU_NOCB_CPU=y
CONFIG_RCU_NOCB_CPU_DEFAULT_ALL=y
CONFIG_RCU_BOOST=y
CONFIG_RCU_BOOST_DELAY=0

# Scheduler topology — CRITICAL for 7950X3D dual-CCD (X3D vs non-X3D)
CONFIG_SCHED_AUTOGROUP=y
CONFIG_SCHED_CORE=y
CONFIG_SCHED_HRTICK=y
CONFIG_SCHED_CLUSTER=y
CONFIG_SCHED_SMT=y
CONFIG_SCHED_MC=y
CONFIG_SCHED_MC_PRIO=y
CONFIG_SCHED_OMIT_FRAME_POINTER=y
CONFIG_SCHED_MM_CID=y

# BORE — Burst-Oriented Response Enhancer, in zen patches
# Omit this line if audit says missing.
CONFIG_SCHED_BORE=y

# Timer
CONFIG_HZ_1000=y
CONFIG_HZ=1000
CONFIG_HIGH_RES_TIMERS=y
CONFIG_NO_HZ_COMMON=y
CONFIG_NO_HZ_IDLE=y
CONFIG_NO_HZ=y
CONFIG_TICK_ONESHOT=y
CONFIG_TICK_CPU_ACCOUNTING=y

# Disable scheduler stats counters for tiny hot-path win
CONFIG_SCHEDSTATS=n
```

- [ ] **Step 2: Commit**

```bash
git add arch-asf/fragments/15-sched-latency.cfg
git -c commit.gpgsign=false commit -m "arch-asf: 15-sched-latency fragment (BORE, RCU NOCB, PREEMPT, CLUSTER)"
```

---

## Task 6: Write `20-mm-perf.cfg`

**Files:**
- Create: `arch-asf/fragments/20-mm-perf.cfg`

- [ ] **Step 1: Create the fragment**

```ini
# 20-mm-perf.cfg — memory management: MGLRU, mTHP, zswap, KSM

# Transparent Huge Pages — madvise is correct for mixed desktop/AI workload
CONFIG_TRANSPARENT_HUGEPAGE=y
CONFIG_TRANSPARENT_HUGEPAGE_MADVISE=y
CONFIG_READ_ONLY_THP_FOR_FS=y
CONFIG_THP_SWAP=y

# MGLRU — multi-generational LRU
CONFIG_LRU_GEN=y
CONFIG_LRU_GEN_ENABLED=y
CONFIG_LRU_GEN_STATS=n

# Fine-grained mmap locking
CONFIG_PER_VMA_LOCK=y

# NUMA balancing — cheap on single-socket, useful for VMs
CONFIG_NUMA=y
CONFIG_NUMA_BALANCING=y
CONFIG_NUMA_BALANCING_DEFAULT_ENABLED=y

# KSM — memory dedup (helps VMs/containers)
CONFIG_KSM=y

# Compressed swap
CONFIG_ZSWAP=y
CONFIG_ZSWAP_DEFAULT_ON=y
CONFIG_ZSWAP_COMPRESSOR_DEFAULT_ZSTD=y
CONFIG_ZSWAP_COMPRESSOR_DEFAULT="zstd"
CONFIG_ZSWAP_ZPOOL_DEFAULT_ZSMALLOC=y
CONFIG_ZSWAP_ZPOOL_DEFAULT="zsmalloc"
CONFIG_ZSMALLOC=y

# Compressed RAM
CONFIG_ZRAM=m
CONFIG_ZRAM_DEF_COMP_ZSTD=y
CONFIG_ZRAM_DEF_COMP="zstd"
CONFIG_ZRAM_WRITEBACK=y

# SLUB perf
CONFIG_SLUB=y
CONFIG_SLAB_MERGE_DEFAULT=y
CONFIG_SLUB_CPU_PARTIAL=y
CONFIG_SLUB_DEBUG=n
CONFIG_SLUB_DEBUG_ON=n

# Hardening that's effectively free at this layer
CONFIG_SHUFFLE_PAGE_ALLOCATOR=y
CONFIG_SLAB_FREELIST_RANDOM=y

# Misc
CONFIG_HUGETLB_PAGE=y
CONFIG_HUGETLBFS=y
CONFIG_USERFAULTFD=y
CONFIG_PAGE_REPORTING=y
CONFIG_CMA=n
```

- [ ] **Step 2: Commit**

```bash
git add arch-asf/fragments/20-mm-perf.cfg
git -c commit.gpgsign=false commit -m "arch-asf: 20-mm-perf fragment (MGLRU, mTHP, zswap zstd, KSM)"
```

---

## Task 7: Write `25-io-perf.cfg`

**Files:**
- Create: `arch-asf/fragments/25-io-perf.cfg`

- [ ] **Step 1: Create the fragment**

```ini
# 25-io-perf.cfg — NVMe, block layer, filesystems

# NVMe
CONFIG_BLK_DEV_NVME=y
CONFIG_NVME_CORE=y
CONFIG_NVME_MULTIPATH=y
CONFIG_NVME_AUTH=y
CONFIG_NVME_VERBOSE_ERRORS=y
CONFIG_NVME_HWMON=y

# Block layer — writeback throttling on multiqueue
CONFIG_BLK_WBT=y
CONFIG_BLK_WBT_MQ=y

# Block cgroup QoS
CONFIG_BLK_CGROUP=y
CONFIG_BLK_CGROUP_IOLATENCY=y
CONFIG_BLK_CGROUP_IOPRIO=y
CONFIG_BLK_CGROUP_IOCOST=y
CONFIG_BLK_DEV_THROTTLING=y

# I/O schedulers — Kyber is the default; BFQ available for rotational
CONFIG_MQ_IOSCHED_DEADLINE=y
CONFIG_MQ_IOSCHED_KYBER=y
CONFIG_IOSCHED_BFQ=y
CONFIG_BFQ_GROUP_IOSCHED=y

# At-rest encryption + verity
CONFIG_BLK_INLINE_ENCRYPTION=y
CONFIG_FS_ENCRYPTION=y
CONFIG_FS_VERITY=y
CONFIG_FS_VERITY_BUILTIN_SIGNATURES=y

# io_uring already on in base; reaffirm
CONFIG_IO_URING=y

# Filesystems
CONFIG_EXT4_FS=y
CONFIG_EXT4_FS_POSIX_ACL=y
CONFIG_EXT4_FS_SECURITY=y
CONFIG_BTRFS_FS=m
CONFIG_BTRFS_FS_POSIX_ACL=y
CONFIG_F2FS_FS=m
CONFIG_XFS_FS=m
CONFIG_XFS_QUOTA=y
CONFIG_XFS_POSIX_ACL=y
CONFIG_FUSE_FS=m
CONFIG_OVERLAY_FS=m

# Zoned block devices
CONFIG_BLK_DEV_ZONED=y
```

- [ ] **Step 2: Commit**

```bash
git add arch-asf/fragments/25-io-perf.cfg
git -c commit.gpgsign=false commit -m "arch-asf: 25-io-perf fragment (NVMe, WBT, BFQ, FS encryption/verity)"
```

---

## Task 8: Write `30-net-perf.cfg`

**Files:**
- Create: `arch-asf/fragments/30-net-perf.cfg`

- [ ] **Step 1: Create the fragment**

```ini
# 30-net-perf.cfg — BBR + FQ + XDP + kTLS

# TCP congestion control — BBR default
CONFIG_TCP_CONG_ADVANCED=y
CONFIG_TCP_CONG_BBR=y
CONFIG_TCP_CONG_CUBIC=y
CONFIG_DEFAULT_BBR=y
CONFIG_DEFAULT_TCP_CONG="bbr"

# Default qdisc — FQ is required for BBR pacing
CONFIG_NET_SCHED=y
CONFIG_NET_SCH_FQ=y
CONFIG_NET_SCH_FQ_CODEL=y
CONFIG_NET_SCH_CAKE=m
CONFIG_DEFAULT_NET_SCH="fq"
CONFIG_DEFAULT_FQ=y

# XDP / AF_XDP
CONFIG_XDP_SOCKETS=y
CONFIG_XDP_SOCKETS_DIAG=m

# kernel TLS with hardware offload path
CONFIG_TLS=m
CONFIG_TLS_DEVICE=y

# Network diag (for `ss`)
CONFIG_INET_DIAG=y
CONFIG_INET_TCP_DIAG=y
CONFIG_INET_UDP_DIAG=y
CONFIG_INET_RAW_DIAG=y
CONFIG_INET_DIAG_DESTROY=y

# Low-latency / high-pps
CONFIG_NET_RX_BUSY_POLL=y
CONFIG_NET_FLOW_LIMIT=y
CONFIG_RPS=y

# Policy routing (for split-tunnel VPN)
CONFIG_IP_MULTIPLE_TABLES=y
CONFIG_IP6_MULTIPLE_TABLES=y

# Optional MD5 sig (BGP-ish, harmless if unused)
CONFIG_TCP_MD5SIG=y

# Ethernet driver for I226-V (Intel 2.5GbE)
CONFIG_IGC=m
```

- [ ] **Step 2: Commit**

```bash
git add arch-asf/fragments/30-net-perf.cfg
git -c commit.gpgsign=false commit -m "arch-asf: 30-net-perf fragment (BBR default, FQ qdisc, XDP, kTLS, IGC)"
```

---

## Task 9: Write `35-net-anon.cfg`

**Files:**
- Create: `arch-asf/fragments/35-net-anon.cfg`

- [ ] **Step 1: Create the fragment**

```ini
# 35-net-anon.cfg — WireGuard, nftables, namespaces, IPv6 privacy, TPROXY

# WireGuard built-in (works in early-userspace and initramfs scenarios)
CONFIG_WIREGUARD=y

# nftables (modern netfilter)
CONFIG_NF_TABLES=y
CONFIG_NF_TABLES_INET=y
CONFIG_NF_TABLES_NETDEV=y
CONFIG_NFT_NUMGEN=m
CONFIG_NFT_CT=m
CONFIG_NFT_FLOW_OFFLOAD=m
CONFIG_NFT_COUNTER=m
CONFIG_NFT_CONNLIMIT=m
CONFIG_NFT_LOG=m
CONFIG_NFT_LIMIT=m
CONFIG_NFT_MASQ=m
CONFIG_NFT_REDIR=m
CONFIG_NFT_NAT=m
CONFIG_NFT_TUNNEL=m
CONFIG_NFT_OBJREF=m
CONFIG_NFT_QUEUE=m
CONFIG_NFT_QUOTA=m
CONFIG_NFT_REJECT=m
CONFIG_NFT_COMPAT=m
CONFIG_NFT_HASH=m
CONFIG_NFT_FIB_INET=m
CONFIG_NFT_SOCKET=m
CONFIG_NFT_OSF=m
CONFIG_NFT_TPROXY=m
CONFIG_NFT_SYNPROXY=m

# Transparent proxy primitives (Tor / privacy-aware routers)
CONFIG_IP_NF_TARGET_TPROXY=m
CONFIG_NF_TPROXY_IPV4=m
CONFIG_NF_TPROXY_IPV6=m
CONFIG_NETFILTER_XT_TARGET_TPROXY=m

# IPv6 privacy: RFC 4941 temporary addresses (no MAC-derived EUI-64 leak)
CONFIG_IPV6=y
CONFIG_IPV6_PRIVACY=y

# Namespaces — required by Bubblewrap / Firejail / podman-rootless
CONFIG_NAMESPACES=y
CONFIG_NET_NS=y
CONFIG_USER_NS=y
CONFIG_PID_NS=y
CONFIG_UTS_NS=y
CONFIG_IPC_NS=y

# IPsec stack (already in base; reaffirm)
CONFIG_XFRM=y
CONFIG_XFRM_USER=y

# Netlink interfaces (diag)
CONFIG_NETFILTER_NETLINK_QUEUE=m
CONFIG_NETFILTER_NETLINK_LOG=y
CONFIG_NETLINK_DIAG=m
CONFIG_PACKET_DIAG=m

# Wi-Fi (MT7925 — your card)
CONFIG_CFG80211=m
CONFIG_MAC80211=m
CONFIG_RFKILL=m
CONFIG_MT76_CORE=m
CONFIG_MT76_CONNAC_LIB=m
CONFIG_MT7925_COMMON=m
CONFIG_MT7925E=m
```

- [ ] **Step 2: Commit**

```bash
git add arch-asf/fragments/35-net-anon.cfg
git -c commit.gpgsign=false commit -m "arch-asf: 35-net-anon fragment (WireGuard, nftables, namespaces, TPROXY, MT7925)"
```

---

## Task 10: Write `40-crypto-accel.cfg`

**Files:**
- Create: `arch-asf/fragments/40-crypto-accel.cfg`

- [ ] **Step 1: Create the fragment**

```ini
# 40-crypto-accel.cfg — AES-NI, VAES, SHA-NI, AVX-512 crypto paths
# Your 7950X3D exposes: aes, vaes, sha_ni, pclmulqdq, vpclmulqdq, avx512f/dq/bw/vl/...

CONFIG_CRYPTO=y
CONFIG_CRYPTO_HW=y

# AES paths
CONFIG_CRYPTO_AES=y
CONFIG_CRYPTO_AES_NI_INTEL=y
CONFIG_CRYPTO_VAES_INTEL=y

# SHA SIMD variants — kernel will pick the best at runtime
CONFIG_CRYPTO_SHA1_SSSE3=y
CONFIG_CRYPTO_SHA1_AVX2=y
CONFIG_CRYPTO_SHA256_SSSE3=y
CONFIG_CRYPTO_SHA256_AVX2=y
CONFIG_CRYPTO_SHA512_SSSE3=y
CONFIG_CRYPTO_SHA512_AVX2=y

# AEAD / GHASH using PCLMUL / VPCLMULQDQ
CONFIG_CRYPTO_GHASH_CLMUL_NI_INTEL=y
CONFIG_CRYPTO_AEGIS128_AESNI_SSE2=y

# CRC SIMD
CONFIG_CRYPTO_CRC32C_INTEL=y
CONFIG_CRYPTO_CRC32_PCLMUL=y

# WireGuard fast path
CONFIG_CRYPTO_CHACHA20_X86_64=y
CONFIG_CRYPTO_POLY1305_X86_64=y

# BLAKE2 (WireGuard, BTRFS)
CONFIG_CRYPTO_BLAKE2B=y
CONFIG_CRYPTO_BLAKE2S=y

# User-space crypto API
CONFIG_CRYPTO_USER=m
CONFIG_CRYPTO_USER_API=y
CONFIG_CRYPTO_USER_API_HASH=y
CONFIG_CRYPTO_USER_API_SKCIPHER=y
CONFIG_CRYPTO_USER_API_RNG=y
CONFIG_CRYPTO_USER_API_AEAD=y
```

- [ ] **Step 2: Commit**

```bash
git add arch-asf/fragments/40-crypto-accel.cfg
git -c commit.gpgsign=false commit -m "arch-asf: 40-crypto-accel fragment (AES-NI, VAES, SHA-NI, PCLMUL paths)"
```

---

## Task 11: Write `45-virt-iommu.cfg`

**Files:**
- Create: `arch-asf/fragments/45-virt-iommu.cfg`

- [ ] **Step 1: Create the fragment**

```ini
# 45-virt-iommu.cfg — KVM (AMD), IOMMU, VFIO, virtio

CONFIG_VIRTUALIZATION=y

# KVM
CONFIG_KVM=m
CONFIG_KVM_AMD=m
CONFIG_KVM_AMD_SEV=y
CONFIG_KVM_SMM=y
CONFIG_KVM_XEN=n

# vhost
CONFIG_VHOST=m
CONFIG_VHOST_NET=m
CONFIG_VHOST_VSOCK=m
CONFIG_VHOST_SCSI=m
CONFIG_VHOST_IOTLB=m

# IOMMU
CONFIG_IOMMU_SUPPORT=y
CONFIG_IOMMU_API=y
CONFIG_AMD_IOMMU=y
CONFIG_AMD_IOMMU_V2=m
CONFIG_IOMMU_DEFAULT_DMA_LAZY=y

# VFIO (passthrough)
CONFIG_VFIO=m
CONFIG_VFIO_IOMMU_TYPE1=m
CONFIG_VFIO_PCI=m
CONFIG_VFIO_PCI_VGA=y
CONFIG_VFIO_PCI_IGD=n
CONFIG_VFIO_MDEV=m
CONFIG_VFIO_NOIOMMU=n

# virtio
CONFIG_VIRTIO=m
CONFIG_VIRTIO_PCI=m
CONFIG_VIRTIO_BLK=m
CONFIG_VIRTIO_NET=m
CONFIG_VIRTIO_BALLOON=m
CONFIG_VIRTIO_CONSOLE=m
CONFIG_VIRTIO_FS=m
CONFIG_VIRTIO_GPU=m
CONFIG_VIRTIO_INPUT=m
CONFIG_VIRTIO_VSOCKETS=m
CONFIG_VIRTIO_IOMMU=m
CONFIG_VIRTIO_PMEM=m
CONFIG_CRYPTO_DEV_VIRTIO=m

# Host memory encryption
CONFIG_AMD_MEM_ENCRYPT=y
```

- [ ] **Step 2: Commit**

```bash
git add arch-asf/fragments/45-virt-iommu.cfg
git -c commit.gpgsign=false commit -m "arch-asf: 45-virt-iommu fragment (KVM-AMD, AMD-IOMMU, VFIO, virtio, SME)"
```

---

## Task 12: Write `50-gpu-rocm.cfg`

**Files:**
- Create: `arch-asf/fragments/50-gpu-rocm.cfg`

- [ ] **Step 1: Create the fragment**

```ini
# 50-gpu-rocm.cfg — AMDGPU + DisplayCore + ROCm/HSA paths for RX 7900 XT
# Raphael iGPU is the same driver.

CONFIG_DRM=y
CONFIG_DRM_KMS_HELPER=y
CONFIG_DRM_FBDEV_EMULATION=y

# AMDGPU
CONFIG_DRM_AMDGPU=m
CONFIG_DRM_AMDGPU_SI=y
CONFIG_DRM_AMDGPU_CIK=y
CONFIG_DRM_AMDGPU_USERPTR=y

# Display Core
CONFIG_DRM_AMD_DC=y
CONFIG_DRM_AMD_DC_FP=y
CONFIG_DRM_AMD_DC_HDCP=y
CONFIG_DRM_AMD_SECURE_DISPLAY=y

# ROCm KFD compute path — required for HIP / PyTorch ROCm
CONFIG_HSA_AMD=y
CONFIG_HSA_AMD_SVM=y
CONFIG_HSA_AMD_P2P=y

# Unified memory primitives
CONFIG_HMM_MIRROR=y
CONFIG_ZONE_DEVICE=y
CONFIG_DEVICE_PRIVATE=y

# DRM helpers
CONFIG_DRM_SCHED=y
CONFIG_DRM_TTM=y
CONFIG_DRM_BUDDY=y

# Devfreq governors (used by some AMD power paths)
CONFIG_DEVFREQ_GOV_PERFORMANCE=y
CONFIG_DEVFREQ_GOV_SIMPLE_ONDEMAND=y

# Disable Audio Co-Processor for AMDGPU (your audio is HDA)
CONFIG_DRM_AMD_ACP=n
```

- [ ] **Step 2: Commit**

```bash
git add arch-asf/fragments/50-gpu-rocm.cfg
git -c commit.gpgsign=false commit -m "arch-asf: 50-gpu-rocm fragment (AMDGPU, DC FP, HSA/KFD, P2P, HMM)"
```

---

## Task 13: Write `55-ntsync.cfg`

**Files:**
- Create: `arch-asf/fragments/55-ntsync.cfg`

- [ ] **Step 1: Create the fragment**

```ini
# 55-ntsync.cfg — NT synchronization primitives for Wine/Proton (kernel 6.10+)
CONFIG_NTSYNC=y

# Gaming controllers
CONFIG_HID_PLAYSTATION=m
CONFIG_HID_NINTENDO=m
CONFIG_HID_MICROSOFT=m
CONFIG_HID_LOGITECH=m
CONFIG_HID_LOGITECH_DJ=m
CONFIG_JOYSTICK_XPAD=m
CONFIG_JOYSTICK_XPAD_FF=y
CONFIG_JOYSTICK_XPAD_LEDS=y

# 32-bit ABI (required for Steam / Wine 32-bit titles)
CONFIG_IA32_EMULATION=y
CONFIG_X86_X32_ABI=n
```

- [ ] **Step 2: Commit**

```bash
git add arch-asf/fragments/55-ntsync.cfg
git -c commit.gpgsign=false commit -m "arch-asf: 55-ntsync fragment (Wine/Proton NTSYNC, gamepads, IA32_EMU)"
```

---

## Task 14: Write `60-security.cfg`

**Files:**
- Create: `arch-asf/fragments/60-security.cfg`

- [ ] **Step 1: Create the fragment**

```ini
# 60-security.cfg — LSM stack + lockdown (off by default; opt-in via cmdline)

CONFIG_SECURITY=y

# LSMs we want enabled
CONFIG_SECURITY_LANDLOCK=y
CONFIG_SECURITY_APPARMOR=y
CONFIG_SECURITY_APPARMOR_HASH=y
CONFIG_SECURITY_APPARMOR_HASH_DEFAULT=y
CONFIG_DEFAULT_SECURITY_APPARMOR=y
CONFIG_SECURITY_YAMA=y
CONFIG_SECURITY_LOCKDOWN_LSM=y
CONFIG_SECURITY_LOCKDOWN_LSM_EARLY=y
CONFIG_LOCK_DOWN_KERNEL_FORCE_NONE=y

# Disable SELinux (AppArmor preferred on Arch; having both adds attack surface)
CONFIG_SECURITY_SELINUX=n

# Default LSM stack order
CONFIG_LSM="landlock,lockdown,yama,integrity,apparmor,bpf"

# Hide kernel ring buffer from non-root
CONFIG_SECURITY_DMESG_RESTRICT=y

# IMA
CONFIG_INTEGRITY=y
CONFIG_INTEGRITY_SIGNATURE=y
CONFIG_IMA=y
CONFIG_IMA_DEFAULT_HASH_SHA256=y

# Kernel module signing
CONFIG_MODULE_SIG=y
CONFIG_MODULE_SIG_ALL=y
CONFIG_MODULE_SIG_SHA512=y
CONFIG_MODULE_SIG_FORCE=n
CONFIG_MODULE_SIG_HASH="sha512"

# BPF restrictions
CONFIG_BPF_LSM=y
CONFIG_BPF_UNPRIV_DEFAULT_OFF=y
```

- [ ] **Step 2: Commit**

```bash
git add arch-asf/fragments/60-security.cfg
git -c commit.gpgsign=false commit -m "arch-asf: 60-security fragment (LSM stack, AppArmor default, lockdown built-in)"
```

---

## Task 15: Write `65-hardening.cfg`

**Files:**
- Create: `arch-asf/fragments/65-hardening.cfg`

- [ ] **Step 1: Create the fragment**

```ini
# 65-hardening.cfg — compile-time & runtime memory hardening

# Stack
CONFIG_STACKPROTECTOR=y
CONFIG_STACKPROTECTOR_STRONG=y
CONFIG_VMAP_STACK=y
CONFIG_SCHED_STACK_END_CHECK=y
CONFIG_THREAD_INFO_IN_TASK=y

# Compile-time bounds checks
CONFIG_FORTIFY_SOURCE=y

# User-copy bounds
CONFIG_HARDENED_USERCOPY=y

# Zero on alloc (cheap, kills uninitialized info leaks)
CONFIG_INIT_STACK_ALL_ZERO=y
CONFIG_INIT_ON_ALLOC_DEFAULT_ON=y
CONFIG_INIT_ON_FREE_DEFAULT_ON=n

# Heap hardening
CONFIG_RANDOM_KMALLOC_CACHES=y
CONFIG_SLAB_FREELIST_HARDENED=y

# KASLR — bump memory padding from 0x0 default
CONFIG_RANDOMIZE_BASE=y
CONFIG_RANDOMIZE_MEMORY=y
CONFIG_RANDOMIZE_MEMORY_PHYSICAL_PADDING=0xa
CONFIG_RANDOMIZE_KSTACK_OFFSET=y
CONFIG_RANDOMIZE_KSTACK_OFFSET_DEFAULT=y

# Low-overhead sampling KASAN
CONFIG_KFENCE=y
CONFIG_KFENCE_SAMPLE_INTERVAL=100

# Detect data structure corruption and panic
CONFIG_BUG_ON_DATA_CORRUPTION=y
CONFIG_DEBUG_LIST=y
CONFIG_DEBUG_SG=y

# Memory protection
CONFIG_STRICT_KERNEL_RWX=y
CONFIG_STRICT_MODULE_RWX=y

# Block NULL deref exploits
CONFIG_DEFAULT_MMAP_MIN_ADDR=65536

# Drop legacy attack vectors
CONFIG_LEGACY_VSYSCALL_NONE=y
CONFIG_LEGACY_PTYS=n
CONFIG_COMPAT_VDSO=n

# Static usermode helper path
CONFIG_STATIC_USERMODEHELPER=y
CONFIG_STATIC_USERMODEHELPER_PATH="/usr/lib/initcpio/busybox"
```

- [ ] **Step 2: Commit**

```bash
git add arch-asf/fragments/65-hardening.cfg
git -c commit.gpgsign=false commit -m "arch-asf: 65-hardening fragment (FORTIFY, VMAP_STACK, INIT_ON_ALLOC, KFENCE)"
```

---

## Task 16: Write `70-privacy.cfg`

**Files:**
- Create: `arch-asf/fragments/70-privacy.cfg`

- [ ] **Step 1: Create the fragment**

```ini
# 70-privacy.cfg — information minimization / leak prevention

# Don't trust RDRAND/RDSEED as entropy source (user-requested paranoia)
CONFIG_RANDOM_TRUST_CPU=n
CONFIG_RANDOM_TRUST_BOOTLOADER=n

# Kill /proc/kcore (live-RAM exfil via file read)
CONFIG_PROC_KCORE=n
CONFIG_PROC_PAGE_MONITOR=n

# Restrict /dev/mem and /dev/kmem
CONFIG_STRICT_DEVMEM=y
CONFIG_IO_STRICT_DEVMEM=y
CONFIG_DEVKMEM=n

# Disable kexec — common chain-of-trust bypass vector
CONFIG_KEXEC=n
CONFIG_KEXEC_FILE=n

# Keep hibernation (useful) but no snapshot device
CONFIG_HIBERNATION=y

# Keep user namespaces (needed for podman-rootless, Bubblewrap, Firejail)
CONFIG_USER_NS_UNPRIVILEGED=y

# Reaffirm dmesg restriction from 60-security
CONFIG_SECURITY_DMESG_RESTRICT=y
```

- [ ] **Step 2: Commit**

```bash
git add arch-asf/fragments/70-privacy.cfg
git -c commit.gpgsign=false commit -m "arch-asf: 70-privacy fragment (distrust RDRAND, no kcore, no kexec)"
```

---

## Task 17: Write `80-lto-clang.cfg`

**Files:**
- Create: `arch-asf/fragments/80-lto-clang.cfg`

- [ ] **Step 1: Create the fragment**

```ini
# 80-lto-clang.cfg — Clang ThinLTO + KCFI. REQUIRES `make LLVM=1`.

# Toolchain
CONFIG_CC_IS_CLANG=y
CONFIG_LD_IS_LLD=y

# LTO
CONFIG_LTO=y
CONFIG_LTO_NONE=n
CONFIG_LTO_CLANG=y
CONFIG_LTO_CLANG_THIN=y

# Kernel CFI — Clang Control Flow Integrity
CONFIG_CFI_CLANG=y
CONFIG_CFI_PERMISSIVE=n

# Dead-code elimination at link time
CONFIG_LD_DEAD_CODE_DATA_ELIMINATION=y

# Disable kernel concurrency sanitizer (dev-only)
CONFIG_KCSAN=n

# kallsyms tweak that works with LTO
CONFIG_KALLSYMS_ABSOLUTE_PERCPU=y
```

- [ ] **Step 2: Commit**

```bash
git add arch-asf/fragments/80-lto-clang.cfg
git -c commit.gpgsign=false commit -m "arch-asf: 80-lto-clang fragment (ThinLTO, KCFI strict, LLD)"
```

---

## Task 18a: Write `90-disable-unused.cfg`

**Files:**
- Create: `arch-asf/fragments/90-disable-unused.cfg`

- [ ] **Step 1: Create the fragment**

```ini
# 90-disable-unused.cfg — drop hardware/protocols not present on this machine

# GPU vendors not present
CONFIG_DRM_NOUVEAU=n
CONFIG_DRM_I915=n
CONFIG_DRM_XE=n
CONFIG_DRM_RADEON=n

# Ethernet vendors we don't have
CONFIG_NET_VENDOR_3COM=n
CONFIG_NET_VENDOR_ADAPTEC=n
CONFIG_NET_VENDOR_ALACRITECH=n
CONFIG_NET_VENDOR_ALTEON=n
CONFIG_NET_VENDOR_ALTERA=n
CONFIG_NET_VENDOR_AMAZON=n
CONFIG_NET_VENDOR_ATHEROS=n
CONFIG_NET_VENDOR_BROADCOM=n
CONFIG_NET_VENDOR_BROCADE=n
CONFIG_NET_VENDOR_CADENCE=n
CONFIG_NET_VENDOR_CAVIUM=n
CONFIG_NET_VENDOR_CHELSIO=n
CONFIG_NET_VENDOR_CISCO=n
CONFIG_NET_VENDOR_DEC=n
CONFIG_NET_VENDOR_DLINK=n
CONFIG_NET_VENDOR_EMULEX=n
CONFIG_NET_VENDOR_EZCHIP=n
CONFIG_NET_VENDOR_HUAWEI=n
CONFIG_NET_VENDOR_MELLANOX=n
CONFIG_NET_VENDOR_MICROCHIP=n
CONFIG_NET_VENDOR_MYRI=n
CONFIG_NET_VENDOR_NETERION=n
CONFIG_NET_VENDOR_NETRONOME=n
CONFIG_NET_VENDOR_NI=n
CONFIG_NET_VENDOR_OKI=n
CONFIG_NET_VENDOR_PACKET_ENGINES=n
CONFIG_NET_VENDOR_PENSANDO=n
CONFIG_NET_VENDOR_QLOGIC=n
CONFIG_NET_VENDOR_QUALCOMM=n
CONFIG_NET_VENDOR_RDC=n
CONFIG_NET_VENDOR_ROCKER=n
CONFIG_NET_VENDOR_SAMSUNG=n
CONFIG_NET_VENDOR_SEEQ=n
CONFIG_NET_VENDOR_SILAN=n
CONFIG_NET_VENDOR_SIS=n
CONFIG_NET_VENDOR_SUN=n
CONFIG_NET_VENDOR_SYNOPSYS=n
CONFIG_NET_VENDOR_TEHUTI=n
CONFIG_NET_VENDOR_TI=n
CONFIG_NET_VENDOR_VIA=n
CONFIG_NET_VENDOR_WIZNET=n
CONFIG_NET_VENDOR_XILINX=n
# Keep INTEL (I226-V), AQUANTIA (USB dongles), AMD (just-in-case), REALTEK

# Legacy buses
CONFIG_CAN=n
CONFIG_IRDA=n
CONFIG_MTD=n
CONFIG_PARPORT=n
CONFIG_PARIDE=n
CONFIG_ATA_NONSTANDARD=n

# Audio cruft
CONFIG_SOUND_OSS_CORE=n
CONFIG_SND_PCSP=n

# Filesystems we don't use
CONFIG_JFS_FS=n
CONFIG_REISERFS_FS=n
CONFIG_NILFS2_FS=n
CONFIG_OCFS2_FS=n
CONFIG_CEPH_FS=n
CONFIG_AFS_FS=n
CONFIG_CODA_FS=n
CONFIG_UBIFS_FS=n
CONFIG_JFFS2_FS=n
CONFIG_ROMFS_FS=n
```

- [ ] **Step 2: Commit**

```bash
git add arch-asf/fragments/90-disable-unused.cfg
git -c commit.gpgsign=false commit -m "arch-asf: 90-disable-unused fragment (drop absent NICs/GPUs/buses/FS)"
```

---

## Task 18b: Write `99-localversion.cfg`

**Files:**
- Create: `arch-asf/fragments/99-localversion.cfg`

- [ ] **Step 1: Create the fragment**

```ini
# 99-localversion.cfg — must be last (sets the build's name suffix)
CONFIG_LOCALVERSION="-asf"
CONFIG_LOCALVERSION_AUTO=n
```

- [ ] **Step 2: Commit**

```bash
git add arch-asf/fragments/99-localversion.cfg
git -c commit.gpgsign=false commit -m "arch-asf: 99-localversion fragment (LOCALVERSION=-asf)"
```

---

## Task 19: Implement `arch-asf/build.sh`

**Files:**
- Create: `arch-asf/build.sh`

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
# arch-asf/build.sh — build & install linux-asf alongside existing kernels.
set -euo pipefail

KROOT="${KROOT:-/home/usernew/arch-linux/zen-kernel}"
ASF="$KROOT/arch-asf"
JOBS="${JOBS:-$(nproc)}"
ACTION="${1:-help}"

cd "$KROOT"

preflight() {
  for cmd in clang ld.lld llvm-objcopy pahole mkinitcpio make; do
    command -v "$cmd" >/dev/null || { echo "MISSING: $cmd"; exit 1; }
  done
  local cv
  cv=$(clang --version | head -1 | grep -oE '[0-9]+' | head -1)
  [[ $cv -ge 18 ]] || { echo "clang $cv too old (need >=18)"; exit 1; }
}

case "$ACTION" in
  preflight)
    preflight
    echo "OK: toolchain present"
    ;;

  config)
    preflight
    if [[ ! -f .config.preasf.bak ]]; then
      cp -v .config .config.preasf.bak
    fi
    # merge_config.sh -m: merge mode (don't run olddefconfig itself)
    KCONFIG_CONFIG=.config ./scripts/kconfig/merge_config.sh \
      -m -O . .config "$ASF"/fragments/*.cfg
    make LLVM=1 olddefconfig
    ./scripts/diffconfig .config.preasf.bak .config > "$ASF/last-diff.txt" || true
    echo "Diff: $ASF/last-diff.txt ($(wc -l < "$ASF/last-diff.txt") lines)"
    ;;

  build)
    preflight
    make LLVM=1 LLVM_IAS=1 \
         KCFLAGS="-march=znver4 -mtune=znver4" \
         -j"$JOBS" all
    ;;

  modules-install)
    sudo make LLVM=1 INSTALL_MOD_STRIP=1 modules_install
    ;;

  install)
    local KREL
    KREL=$(make -s kernelrelease)
    sudo install -Dm644 arch/x86/boot/bzImage "/boot/vmlinuz-linux-asf"
    sudo install -Dm644 System.map "/boot/System.map-linux-asf"
    sudo install -Dm644 "$ASF/presets/linux-asf.preset" /etc/mkinitcpio.d/linux-asf.preset
    sudo mkinitcpio -p linux-asf

    local PARTUUID
    PARTUUID=$(findmnt -no PARTUUID /)
    for variant in linux-asf linux-asf-fallback linux-asf-relaxed; do
      sudo install -Dm644 "$ASF/boot/${variant}.conf.tmpl" \
        "/boot/loader/entries/arch-${variant#linux-}.conf"
      sudo sed -i \
        -e "s|@KREL@|$KREL|g" \
        -e "s|@PARTUUID@|$PARTUUID|g" \
        "/boot/loader/entries/arch-${variant#linux-}.conf"
    done

    if grep -q '^timeout 0' /boot/loader/loader.conf 2>/dev/null; then
      echo "NOTE: /boot/loader/loader.conf has 'timeout 0' (menu hidden)."
      echo "      Edit it to e.g. 'timeout 3' to see the boot menu."
    fi

    echo "Installed kernel: $KREL"
    echo "Default boot entry NOT changed. Pick 'linux-asf' from boot menu."
    "$ASF/verify.sh" || true
    ;;

  all)
    "$0" config
    "$0" build
    "$0" modules-install
    "$0" install
    ;;

  clean)
    make LLVM=1 mrproper
    ;;

  help|*)
    cat <<EOF
Usage: $0 <action>

Actions:
  preflight        check toolchain versions
  config           merge fragments into .config (backs up first)
  build            compile (KCFLAGS=-march=znver4, LLVM=1)
  modules-install  sudo: install modules to /lib/modules/<rel>/
  install          sudo: install vmlinuz, initramfs, boot entries
  all              config + build + modules-install + install
  clean            make mrproper
EOF
    ;;
esac
```

- [ ] **Step 2: chmod and commit**

```bash
chmod +x arch-asf/build.sh
git add arch-asf/build.sh
git -c commit.gpgsign=false commit -m "arch-asf: build.sh driver (preflight/config/build/install/all)"
```

---

## Task 20: Implement `arch-asf/verify.sh`

**Files:**
- Create: `arch-asf/verify.sh`

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
# arch-asf/verify.sh — sanity checks. Pre-install by default, --runtime for post-boot.
set -u

KROOT="${KROOT:-/home/usernew/arch-linux/zen-kernel}"
CFG="$KROOT/.config"
KREL=$(make -s -C "$KROOT" kernelrelease 2>/dev/null || echo "unknown")
FAIL=0
WARN=0

ok()   { printf '\033[32mOK\033[0m   %s\n' "$*"; }
warn() { printf '\033[33mWARN\033[0m %s\n' "$*"; WARN=$((WARN+1)); }
bad()  { printf '\033[31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }

want_y() {
  if grep -q "^CONFIG_$1=y$" "$CFG"; then ok "CONFIG_$1=y"
  else warn "CONFIG_$1 is not =y"
  fi
}

if [[ "${1:-}" == "--runtime" ]]; then
  echo "=== runtime checks ($(uname -r)) ==="
  [[ "$(uname -r)" == *-asf ]] && ok "uname -r ends in -asf" || bad "not booted into linux-asf"
  [[ "$(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_driver 2>/dev/null)" == amd-pstate-epp ]] \
    && ok "scaling_driver=amd-pstate-epp" || warn "scaling_driver != amd-pstate-epp"
  [[ "$(cat /sys/devices/system/cpu/amd_pstate/status 2>/dev/null)" == active ]] \
    && ok "amd_pstate=active" || warn "amd_pstate not active"
  [[ "$(sysctl -n net.ipv4.tcp_congestion_control)" == bbr ]] \
    && ok "tcp_congestion_control=bbr" || warn "tcp != bbr"
  for ifn in $(ls /sys/class/net | grep -v lo); do
    tc qdisc show dev "$ifn" | head -1 | grep -q ' fq ' \
      && ok "qdisc fq on $ifn" || warn "qdisc != fq on $ifn"
  done
  [[ "$(cat /sys/module/zswap/parameters/enabled 2>/dev/null)" == Y ]] \
    && ok "zswap on" || warn "zswap off"
  grep -q '^[1-9]' /sys/kernel/mm/lru_gen/enabled 2>/dev/null \
    && ok "MGLRU on" || warn "MGLRU not enabled"
  grep -q '\[madvise\]' /sys/kernel/mm/transparent_hugepage/enabled \
    && ok "THP=madvise" || warn "THP not madvise"
  for m in kvm_amd amdgpu igc mt7925e wireguard; do
    lsmod | awk '{print $1}' | grep -qx "$m" \
      && ok "module $m loaded" || warn "module $m not loaded"
  done
  cat /sys/kernel/security/lsm 2>/dev/null | grep -q apparmor \
    && ok "AppArmor in LSM stack" || warn "AppArmor not in lsm stack"
  for v in /sys/devices/system/cpu/vulnerabilities/*; do
    s=$(cat "$v")
    [[ "$s" == *Vulnerable* ]] && bad "$(basename "$v"): $s" || ok "$(basename "$v"): ${s:0:40}"
  done
else
  echo "=== pre-install checks (target $KREL) ==="
  test -f "$CFG" || { bad "no .config"; exit 1; }
  for sym in MZEN4 X86_AMD_PSTATE WIREGUARD TCP_CONG_BBR DEFAULT_BBR \
             LRU_GEN_ENABLED LTO_CLANG_THIN CFI_CLANG \
             HSA_AMD NTSYNC SECURITY_LANDLOCK SECURITY_LOCKDOWN_LSM \
             RANDOMIZE_BASE STACKPROTECTOR_STRONG MODULE_SIG_ALL \
             IGC MT7925E AMD_IOMMU KVM_AMD DRM_AMDGPU ; do
    want_y "$sym"
  done
  # Files only checked if install has happened
  if [[ -f /boot/vmlinuz-linux-asf ]]; then
    ok "/boot/vmlinuz-linux-asf exists"
    [[ -f /boot/initramfs-linux-asf.img ]] && ok "initramfs present" || warn "no initramfs"
    [[ -d "/lib/modules/$KREL" ]] && ok "modules dir present" || warn "no modules dir"
    [[ -f /boot/loader/entries/arch-asf.conf ]] && ok "boot entry present" || warn "no boot entry"
    sudo depmod -a "$KREL" 2>&1 | grep -i error && bad "depmod errors" || ok "depmod clean"
  fi
fi

echo "=== summary: $FAIL fail / $WARN warn ==="
[[ $FAIL -eq 0 ]]
```

- [ ] **Step 2: chmod and commit**

```bash
chmod +x arch-asf/verify.sh
git add arch-asf/verify.sh
git -c commit.gpgsign=false commit -m "arch-asf: verify.sh pre-install + --runtime checks"
```

---

## Task 21: Write mkinitcpio preset

**Files:**
- Create: `arch-asf/presets/linux-asf.preset`

- [ ] **Step 1: Write preset**

```ini
# mkinitcpio preset file for the 'linux-asf' kernel
ALL_kver="/boot/vmlinuz-linux-asf"
ALL_microcode=(/boot/amd-ucode.img)

PRESETS=('default' 'fallback')

default_image="/boot/initramfs-linux-asf.img"
default_uki="no"
default_options=""

fallback_image="/boot/initramfs-linux-asf-fallback.img"
fallback_options="-S autodetect"
```

- [ ] **Step 2: Commit**

```bash
git add arch-asf/presets/linux-asf.preset
git -c commit.gpgsign=false commit -m "arch-asf: linux-asf mkinitcpio preset (default + fallback)"
```

---

## Task 22: Write systemd-boot entry templates

**Files:**
- Create: `arch-asf/boot/linux-asf.conf.tmpl`
- Create: `arch-asf/boot/linux-asf-fallback.conf.tmpl`
- Create: `arch-asf/boot/linux-asf-relaxed.conf.tmpl`

- [ ] **Step 1: Default entry**

`arch-asf/boot/linux-asf.conf.tmpl`:

```ini
title    Arch Linux — linux-asf (fast asf)
version  @KREL@
linux    /vmlinuz-linux-asf
initrd   /amd-ucode.img
initrd   /initramfs-linux-asf.img
options  root=PARTUUID=@PARTUUID@ rw rootfstype=ext4 mitigations=auto amd_pstate=active iommu=pt iommu.passthrough=0 nvme_core.default_ps_max_latency_us=0 random.trust_cpu=0 random.trust_bootloader=0 slab_nomerge lsm=landlock,lockdown,yama,integrity,apparmor,bpf lockdown=integrity loglevel=3 quiet
```

- [ ] **Step 2: Fallback entry**

`arch-asf/boot/linux-asf-fallback.conf.tmpl`:

```ini
title    Arch Linux — linux-asf (fallback)
version  @KREL@
linux    /vmlinuz-linux-asf
initrd   /amd-ucode.img
initrd   /initramfs-linux-asf-fallback.img
options  root=PARTUUID=@PARTUUID@ rw rootfstype=ext4 mitigations=auto amd_pstate=active iommu=pt random.trust_cpu=0 random.trust_bootloader=0 slab_nomerge lsm=landlock,lockdown,yama,integrity,apparmor,bpf lockdown=integrity loglevel=7
```

- [ ] **Step 3: Relaxed entry (no lockdown — for DKMS)**

`arch-asf/boot/linux-asf-relaxed.conf.tmpl`:

```ini
title    Arch Linux — linux-asf (relaxed: no lockdown, for DKMS)
version  @KREL@
linux    /vmlinuz-linux-asf
initrd   /amd-ucode.img
initrd   /initramfs-linux-asf.img
options  root=PARTUUID=@PARTUUID@ rw rootfstype=ext4 mitigations=auto amd_pstate=active iommu=pt iommu.passthrough=0 nvme_core.default_ps_max_latency_us=0 random.trust_cpu=0 random.trust_bootloader=0 slab_nomerge loglevel=3 quiet
```

> **Note on `rootfstype=ext4`:** confirm your root filesystem type before the install task. Run `findmnt -no FSTYPE /` — if not `ext4`, edit all three templates to match (likely `btrfs` or `xfs`).

- [ ] **Step 4: Commit**

```bash
git add arch-asf/boot/linux-asf.conf.tmpl arch-asf/boot/linux-asf-fallback.conf.tmpl arch-asf/boot/linux-asf-relaxed.conf.tmpl
git -c commit.gpgsign=false commit -m "arch-asf: systemd-boot entry templates (default + fallback + relaxed)"
```

---

## Task 23: Dry-run merge & inspect diff

- [ ] **Step 1: Run config action**

```bash
cd /home/usernew/arch-linux/zen-kernel
./arch-asf/build.sh config
```

Expected: prints a diff line count (typically a few hundred lines), no merge_config errors. If `merge_config.sh` says `Value of CONFIG_X is redefined by fragment...` for some symbol, that's a conflict — review which fragment is authoritative, edit the loser.

- [ ] **Step 2: Inspect the diff**

```bash
less arch-asf/last-diff.txt
```

Walk through it: every change should match a fragment's intent. Anything surprising means an indirect Kconfig dependency flipped — investigate before building.

- [ ] **Step 3: Sanity check critical built-ins**

```bash
./arch-asf/verify.sh
```

Expected: `0 fail` (warns are OK if some symbols are missing per Task 2 audit). Pre-install checks should be green for all built-in symbols.

- [ ] **Step 4: If anything fails**

Iterate on the offending fragment, re-run `./arch-asf/build.sh config`, re-run `./arch-asf/verify.sh`. Commit any fragment edits with a clear message describing the dependency you discovered.

---

## Task 24: Build the kernel

- [ ] **Step 1: Build**

```bash
cd /home/usernew/arch-linux/zen-kernel
./arch-asf/build.sh build 2>&1 | tee arch-asf/build.log
```

Expected: 7-12 minutes wall clock on 7950X3D. No errors. `vmlinux` and `arch/x86/boot/bzImage` produced.

- [ ] **Step 2: If build fails with KCFI link errors**

Edit `arch-asf/fragments/80-lto-clang.cfg`, set `CONFIG_CFI_PERMISSIVE=y` temporarily, re-run `./arch-asf/build.sh config && ./arch-asf/build.sh build`. File a follow-up task to investigate the strict-CFI break.

- [ ] **Step 3: If build fails with `BTF` errors**

Verify `pahole --version` ≥ 1.25. If older, `sudo pacman -S pahole` and rebuild.

- [ ] **Step 4: Note kernel release**

```bash
make -s kernelrelease
```

Expected: `6.17.4-asf`.

No commit (build artifacts are gitignored).

---

## Task 25: Install modules

- [ ] **Step 1: modules_install**

```bash
cd /home/usernew/arch-linux/zen-kernel
./arch-asf/build.sh modules-install
```

Expected: `sudo` prompt. Modules land in `/lib/modules/6.17.4-asf/`. depmod runs automatically.

- [ ] **Step 2: Verify**

```bash
ls -d /lib/modules/6.17.4-asf
sudo depmod -a 6.17.4-asf 2>&1 | grep -i error || echo "depmod clean"
```

Expected: directory exists, no depmod errors.

---

## Task 26: Install kernel + initramfs + boot entries

- [ ] **Step 1: Confirm root FS type matches templates**

```bash
findmnt -no FSTYPE /
```

If output is not `ext4`, edit `arch-asf/boot/linux-asf*.conf.tmpl` `rootfstype=` and re-commit before continuing.

- [ ] **Step 2: Install**

```bash
cd /home/usernew/arch-linux/zen-kernel
./arch-asf/build.sh install
```

Expected: copies `bzImage` → `/boot/vmlinuz-linux-asf`, installs preset, runs `mkinitcpio -p linux-asf` (which builds `initramfs-linux-asf.img` and `initramfs-linux-asf-fallback.img`), installs 3 boot entries with PARTUUID substituted, runs verify.

- [ ] **Step 3: Inspect bootloader state**

```bash
ls /boot/loader/entries/arch-asf*.conf
cat /boot/loader/entries/arch-asf.conf
ls /boot/vmlinuz-linux-asf /boot/initramfs-linux-asf*.img /boot/System.map-linux-asf
cat /boot/loader/loader.conf
```

Verify PARTUUID is substituted (no `@PARTUUID@` literals remain), files exist, and `loader.conf` `timeout` is non-zero (boot menu visible). If `timeout 0`, edit to `timeout 3`.

---

## Task 27: Pre-reboot verification

- [ ] **Step 1: Run verify**

```bash
cd /home/usernew/arch-linux/zen-kernel
./arch-asf/verify.sh
```

Expected: all OK or only acceptable warns (e.g. symbols not in tree per Task 2 audit). Zero FAILs.

- [ ] **Step 2: Dry-run module loads**

```bash
for m in kvm_amd amdgpu igc mt7925e vfio_pci wireguard btrfs; do
  modprobe -n -v -S 6.17.4-asf "$m" 2>&1 | head -3
done
```

Expected: each lists what would be loaded with no "FATAL" / "not found". (A "not found" for `wireguard` is OK because we built it as `=y` (in-kernel), not module.)

- [ ] **Step 3: Confirm fallback still works**

```bash
ls /boot/vmlinuz-linux /boot/vmlinuz-linux-lts /boot/vmlinuz-linux-zen
ls /boot/initramfs-linux.img /boot/initramfs-linux-lts.img /boot/initramfs-linux-zen.img
```

All must still exist — we never touched them.

---

## Task 28: Final commit + handoff to user

- [ ] **Step 1: Commit build artifacts that should persist**

```bash
cd /home/usernew/arch-linux/zen-kernel
git status -s
# Expected: .config has changed (the merged result). last-diff.txt is gitignored. build.log gitignored.
git add .config
git -c commit.gpgsign=false commit -m "arch-asf: merged .config for linux-asf build $(make -s kernelrelease)"
```

- [ ] **Step 2: Print handoff message**

```bash
echo "============================================================"
echo "  linux-asf $(make -s kernelrelease) ready."
echo "============================================================"
echo "Reboot and select 'Arch Linux — linux-asf (fast asf)' from"
echo "the systemd-boot menu. Existing kernels remain bootable."
echo
echo "After login on linux-asf, run:"
echo "  /home/usernew/arch-linux/zen-kernel/arch-asf/verify.sh --runtime"
echo
echo "Fallback: pick linux-lts or linux-zen from the boot menu."
echo "Uninstall: see arch-asf/README.md."
echo "============================================================"
```

- [ ] **Step 3: STOP. User reboots.**

This is a manual checkpoint. The next step (post-boot verification) requires the user to reboot into `linux-asf` and run `verify.sh --runtime` themselves. Do not proceed further from the plan-execution agent. Report completion of Task 28 and wait for the user.

---

## Post-reboot (user-driven, not part of automated plan)

After booting `linux-asf`:

```bash
/home/usernew/arch-linux/zen-kernel/arch-asf/verify.sh --runtime
```

If anything FAILs, capture `journalctl -k -b` and `dmesg | grep -iE 'cfi|kasan|kfence|bug|warn|error'` and review the offending fragment.

If boot fails entirely, pick `linux-lts` or `linux-zen` from the menu, then investigate from there.

---

## Self-review

**Spec coverage:**
- ✅ Section 2 (Architecture) → File structure + Tasks 1, 19, 20, 21, 22.
- ✅ Section 3.1 (Performance fragments) → Tasks 4, 5, 6, 7, 8, 10, 17.
- ✅ Section 3.2 (Security/privacy/anonymity) → Tasks 9, 14, 15, 16.
- ✅ Section 3.3 (Hardware fragments) → Tasks 11, 12, 13, 18a, 18b.
- ✅ Section 4 (Toolchain & build) → Tasks 3, 17, 19, 24.
- ✅ Section 5 (Bootloader & initramfs) → Tasks 21, 22, 26.
- ✅ Section 6 (Verification) → Tasks 20, 23, 27, post-reboot.
- ✅ Section 7 (Rollback) → README (Task 1) documents it; existing kernels untouched by design.
- ✅ Section 8 (Non-goals) → PGO/PKGBUILD/PREEMPT_RT/MOK signing not in plan, matches spec.
- ✅ DKMS option (3 boot entries: default + fallback + relaxed) → Task 22.

**Placeholder scan:** no TBD/TODO/"fill in"/"similar to". Every config fragment lists explicit `CONFIG_X=y/m/n` lines. Every shell step has its full command. The only intentional template tokens are `@KREL@` and `@PARTUUID@` in the boot templates, which `build.sh install` substitutes mechanically.

**Type/name consistency:** kernel naming (`linux-asf`), release (`6.17.4-asf`), localversion (`-asf`), boot entry IDs (`arch-asf`, `arch-asf-fallback`, `arch-asf-relaxed`) are consistent across tasks 19, 21, 22, 26, 28. Fragment numbers in file-structure map match task numbers throughout.

No issues found.
