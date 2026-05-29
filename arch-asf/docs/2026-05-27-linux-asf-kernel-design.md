# linux-asf — design doc

**Date:** 2026-05-27
**Base kernel:** zen-kernel 6.17.4 (branch `6.17/main`)
**Target machine:** AMD Ryzen 9 7950X3D + Radeon RX 7900 XT/XTX + 64 GB + 2× NVMe + I226-V + MT7925 Wi-Fi 7
**Status:** approved, pending implementation plan

## 1. Goal

Produce a custom kernel package, **`linux-asf`**, that installs alongside the user's existing `linux`, `linux-lts`, and `linux-zen` kernels, optimized for:

1. Maximum performance on this specific hardware (Zen 4 / RDNA 3 / NVMe / 2.5 GbE / Wi-Fi 7).
2. A mixed power-user workload: low-latency gaming, large compiles, AI/ML inference, privacy-conscious daily driving.
3. Strong network privacy/anonymity defaults without sacrificing throughput.
4. Reproducible, reviewable, easily rolled back.

Mitigations stay **fully enabled** (Zen 4 ones are cheap and the user prefers safe baseline).

## 2. Architecture

Everything lives in a new top-level directory of the kernel source tree:

```
arch-asf/
├── README.md
├── build.sh                  # idempotent driver
├── verify.sh                 # pre/post-install checks
├── fragments/                # Kconfig fragments, numbered for merge order
│   ├── 10-cpu-zen4.cfg
│   ├── 15-sched-latency.cfg
│   ├── 20-mm-perf.cfg
│   ├── 25-io-perf.cfg
│   ├── 30-net-perf.cfg
│   ├── 35-net-anon.cfg
│   ├── 40-crypto-accel.cfg
│   ├── 45-virt-iommu.cfg
│   ├── 50-gpu-rocm.cfg
│   ├── 55-ntsync.cfg
│   ├── 60-security.cfg
│   ├── 65-hardening.cfg
│   ├── 70-privacy.cfg
│   ├── 80-lto-clang.cfg
│   ├── 90-disable-unused.cfg
│   └── 99-localversion.cfg
├── presets/linux-asf.preset
├── boot/linux-asf.conf.tmpl
└── docs/                     # this file
```

**Build flow** (driven by `build.sh`):
`merge_config.sh` → `make olddefconfig` → `make LLVM=1 KCFLAGS=-march=znver4` → `make modules_install` → copy `vmlinuz` → `mkinitcpio -p linux-asf` → install systemd-boot entry → `verify.sh`.

The user's existing `.config` is preserved as `.config.preasf.bak` on first run. Their other installed kernels remain untouched.

## 3. Fragment contents (summary)

### 3.1 Performance

**`10-cpu-zen4.cfg`** — `MZEN4=y`, `X86_AMD_PSTATE=y`, `X86_AMD_PSTATE_DEFAULT_MODE=3` (active EPP), `AMD_HSMP=m`, `AMD_PMC=m`, `AMD_PMF=m`, `AMD_NB=y`, `PERF_EVENTS_AMD_BRS=y`, `PERF_EVENTS_AMD_UNCORE=m`, `CRYPTO_DEV_CCP{,_DD}=y`, `AMD_PTDMA=m`.

**`15-sched-latency.cfg`** — `SCHED_BORE=y`, `RCU_NOCB_CPU=y`, `RCU_NOCB_CPU_DEFAULT_ALL=y`, `RCU_BOOST=y`, `PREEMPT=y` + `PREEMPT_DYNAMIC=y` (already), `SCHED_AUTOGROUP=y`, `SCHED_CLUSTER=y` (already — critical for X3D dual-CCD asymmetry), `HZ_1000=y`, `NO_HZ_IDLE=y`, `SCHEDSTATS=n`.

**`20-mm-perf.cfg`** — `TRANSPARENT_HUGEPAGE_MADVISE=y`, `READ_ONLY_THP_FOR_FS=y`, `THP_SWAP=y`, `LRU_GEN=y` + `LRU_GEN_ENABLED=y` (MGLRU), `PER_VMA_LOCK=y`, `NUMA_BALANCING=y`, `KSM=y`, `ZSWAP=y` + `ZSWAP_DEFAULT_ON=y` + `ZSWAP_COMPRESSOR_DEFAULT_ZSTD=y`, `ZRAM_DEF_COMP_ZSTD=y`, `ZRAM_WRITEBACK=y`, `SLUB_DEBUG=n` (was `y`), `SHUFFLE_PAGE_ALLOCATOR=y`, `SLAB_FREELIST_RANDOM=y`.

**`25-io-perf.cfg`** — `NVME_MULTIPATH=y`, `NVME_AUTH=y`, `NVME_HWMON=y`, `BLK_WBT=y` + `BLK_WBT_MQ=y`, `BLK_CGROUP_IOLATENCY=y`, `BLK_CGROUP_IOCOST=y`, `BLK_CGROUP_IOPRIO=y`, `IOSCHED_BFQ=y` + `BFQ_GROUP_IOSCHED=y`, `MQ_IOSCHED_KYBER=y` (already), `BLK_INLINE_ENCRYPTION=y`, `FS_ENCRYPTION=y`, `FS_VERITY=y`, `BTRFS_FS=m`, `F2FS_FS=m`.

**`30-net-perf.cfg`** — `TCP_CONG_BBR=y` + `DEFAULT_BBR=y` + `DEFAULT_TCP_CONG="bbr"`, `NET_SCH_FQ=y` + `DEFAULT_NET_SCH="fq"`, `NET_SCH_FQ_CODEL=y`, `NET_SCH_CAKE=m`, `XDP_SOCKETS=y`, `TLS=m` + `TLS_DEVICE=y`, `NET_RX_BUSY_POLL=y`, `INET_DIAG_DESTROY=y`, `IP_MULTIPLE_TABLES=y`, `IP6_MULTIPLE_TABLES=y`.

**`40-crypto-accel.cfg`** — `CRYPTO_AES_NI_INTEL=y`, `CRYPTO_VAES_INTEL=y`, `CRYPTO_SHA{1,256,512}_AVX2=y`, `CRYPTO_SHA{1,256,512}_SSSE3=y`, `CRYPTO_GHASH_CLMUL_NI_INTEL=y`, `CRYPTO_CRC32C_INTEL=y`, `CRYPTO_CRC32_PCLMUL=y`, `CRYPTO_CHACHA20_X86_64=y`, `CRYPTO_POLY1305_X86_64=y`, `CRYPTO_AEGIS128_AESNI_SSE2=y`, `CRYPTO_BLAKE2{B,S}=y`, `CRYPTO_DEV_CCP_DD=y`, `CRYPTO_DEV_SP_PSP=y`, `CRYPTO_USER_API_{HASH,SKCIPHER,RNG,AEAD}=y`.

**`80-lto-clang.cfg`** — `LTO_CLANG=y`, `LTO_CLANG_THIN=y`, `LTO_NONE=n`, `CFI_CLANG=y`, `CFI_PERMISSIVE=n`, `LD_DEAD_CODE_DATA_ELIMINATION=y`, `KCSAN=n`. Requires `LLVM=1` for build.

### 3.2 Security / privacy / anonymity

**`35-net-anon.cfg`** — `WIREGUARD=y` (built-in), `NF_TABLES=y` + nft_*=m, `IP_NF_TARGET_TPROXY=m`, `NF_TPROXY_IPV4=m`, `NF_TPROXY_IPV6=m`, `IPV6_PRIVACY=y`, `NET_NS=y` + `USER_NS=y` + `PID_NS=y` + `UTS_NS=y` + `IPC_NS=y`, `XFRM_*=y` (already), `NETFILTER_NETLINK_QUEUE=m`, `INET_DIAG_DESTROY=y`, `TCP_MD5SIG=y`.

**`60-security.cfg`** — `SECURITY_LANDLOCK=y`, `SECURITY_APPARMOR=y` + `DEFAULT_SECURITY_APPARMOR=y`, `SECURITY_YAMA=y`, `SECURITY_LOCKDOWN_LSM=y` + `SECURITY_LOCKDOWN_LSM_EARLY=y` + `LOCK_DOWN_KERNEL_FORCE_NONE=y` (off by default; opt in via cmdline), `LSM="landlock,lockdown,yama,integrity,apparmor,bpf"`, `SECURITY_DMESG_RESTRICT=y`, `INTEGRITY=y` + `IMA=y`, `MODULE_SIG=y` + `MODULE_SIG_ALL=y` + `MODULE_SIG_SHA512=y` + `MODULE_SIG_FORCE=n`, `SECURITY_SELINUX=n`.

**`65-hardening.cfg`** — `FORTIFY_SOURCE=y`, `VMAP_STACK=y`, `SCHED_STACK_END_CHECK=y`, `HARDENED_USERCOPY=y`, `INIT_STACK_ALL_ZERO=y`, `INIT_ON_ALLOC_DEFAULT_ON=y`, `INIT_ON_FREE_DEFAULT_ON=n` (perf), `RANDOM_KMALLOC_CACHES=y`, `SLAB_FREELIST_HARDENED=y`, `RANDOMIZE_MEMORY_PHYSICAL_PADDING=0xa` (bumped from `0x0`), `KFENCE=y` + `KFENCE_SAMPLE_INTERVAL=100`, `BUG_ON_DATA_CORRUPTION=y`, `STRICT_KERNEL_RWX=y`, `STRICT_MODULE_RWX=y`, `DEFAULT_MMAP_MIN_ADDR=65536`, `LEGACY_VSYSCALL_NONE=y`, `LEGACY_PTYS=n`.

**`70-privacy.cfg`** — `RANDOM_TRUST_CPU=n`, `RANDOM_TRUST_BOOTLOADER=n`, `PROC_KCORE=n`, `STRICT_DEVMEM=y`, `IO_STRICT_DEVMEM=y`, `DEVKMEM=n`, `KEXEC=n`, `KEXEC_FILE=n`, `PROC_PAGE_MONITOR=n`, `BPF_UNPRIV_DEFAULT_OFF=y` (already), `USER_NS_UNPRIVILEGED=y`.

### 3.3 Hardware/features

**`45-virt-iommu.cfg`** — `KVM=m`, `KVM_AMD=m`, `KVM_AMD_SEV=y`, `KVM_SMM=y`, `VHOST_{NET,VSOCK,SCSI,IOTLB}=m`, `IOMMU_API=y`, `AMD_IOMMU=y`, `AMD_IOMMU_V2=m`, `IOMMU_DEFAULT_DMA_LAZY=y`, `VFIO=m` + `VFIO_IOMMU_TYPE1=m` + `VFIO_PCI=m` + `VFIO_PCI_VGA=y`, `VFIO_MDEV=m`, `VFIO_NOIOMMU=n`, `VIRTIO_*=m` (full set), `AMD_MEM_ENCRYPT=y`, `CRYPTO_DEV_VIRTIO=m`.

**`50-gpu-rocm.cfg`** — `DRM_AMDGPU=m`, `DRM_AMDGPU_USERPTR=y`, `DRM_AMD_DC=y`, `DRM_AMD_DC_FP=y`, `DRM_AMD_DC_HDCP=y`, `HSA_AMD=y`, `HSA_AMD_SVM=y`, `HSA_AMD_P2P=y`, `HMM_MIRROR=y`, `ZONE_DEVICE=y`, `DEVICE_PRIVATE=y`, `DRM_SCHED=y`, `DRM_TTM=y`, `DRM_BUDDY=y`.

**`55-ntsync.cfg`** — `NTSYNC=y` (Wine/Proton).

**`90-disable-unused.cfg`** — drop Ethernet/GPU/WiFi vendors not present, legacy buses (`CAN`, `IRDA`, `MTD`, `PARPORT`, `PARIDE`), deprecated FS (jfs, reiserfs, nilfs2, ocfs2, ceph, afs, coda, ubifs, jffs2, romfs), `SOUND_OSS_CORE`, `SND_PCSP`, most touchscreen drivers. Keep gaming controllers (Xbox/PS/Nintendo). Keep `IA32_EMULATION=y` (Steam/Wine 32-bit).

**`99-localversion.cfg`** — `LOCALVERSION="-asf"`, plus any final overrides.

## 4. Toolchain & build

- **Compiler:** `clang ≥ 18`, `lld ≥ 18`, `llvm-{ar,nm,objcopy,strip}`, `pahole ≥ 1.25` (for BTF).
- **Build flags:** `LLVM=1 LLVM_IAS=1 KCFLAGS="-march=znver4 -mtune=znver4"`. No `-O3` — kernel uses `-O2` via `CC_OPTIMIZE_FOR_PERFORMANCE`.
- **Module install:** `INSTALL_MOD_STRIP=1` (strip debug info).
- **Expected build time** on 7950X3D / 64GB: cold 7-12 min, incremental 3-5 min.
- **PGO** is scaffolded but **out of scope for v1** (Phase 2: `arch-asf/pgo/`).

## 5. Bootloader & initramfs

- **Bootloader target:** systemd-boot (active on this machine; `/boot/loader/entries/` is canonical).
- **mkinitcpio preset:** `arch-asf/presets/linux-asf.preset` mirrors `linux-zen.preset` shape, produces `initramfs-linux-asf.img` + `-fallback.img`, with `amd-ucode.img` as ALL_microcode.
- **Boot entries (three):**
  - `arch-asf.conf` — default daily-driver: `lockdown=integrity`, quiet, autodetect initramfs.
  - `arch-asf-fallback.conf` — fallback: fat initramfs (`-S autodetect`), `lockdown=integrity`, verbose (`loglevel=7`, no `quiet`).
  - `arch-asf-relaxed.conf` — escape hatch: `lockdown=none`, otherwise identical to default. Use when installing/testing DKMS modules (VirtualBox, VMware, proprietary drivers) which won't be signed by our build key and would be rejected by lockdown=integrity.
  Root PARTUUID auto-detected by `build.sh install`.
- **Default boot entry is NOT changed** — user picks `linux-asf` from menu on first boot. Existing `linux-zen` / `linux-lts` / `linux` remain bootable fallbacks.

**Kernel cmdline (default entry):**
```
mitigations=auto
amd_pstate=active
iommu=pt iommu.passthrough=0
nvme_core.default_ps_max_latency_us=0
random.trust_cpu=0 random.trust_bootloader=0
slab_nomerge
lsm=landlock,lockdown,yama,integrity,apparmor,bpf
lockdown=integrity
loglevel=3 quiet
```

## 6. Verification

`verify.sh` checks (pre-install): config-symbol presence, file existence, depmod cleanliness.

`verify.sh --runtime` checks (post-boot): `uname -r`, `cpufreq` scaling driver = `amd-pstate-epp`, `amd_pstate/status = active`, `tcp_congestion_control = bbr`, root qdisc = `fq`, MGLRU on, THP = `[madvise]`, critical modules loaded, KCFI initialized, LSM stack matches, lockdown level = integrity, all `/sys/devices/system/cpu/vulnerabilities/*` = Mitigation or "Not affected" (never "Vulnerable").

**User-run benchmarks** (before/after pairs vs. `linux-zen`): kernel-build wall time, iperf3 LAN + high-RTT, gaming frame-time variance (`mangohud`), llama.cpp ROCm latency, `fio` NVMe random 4K QD32, `systemd-analyze` boot time.

## 7. Rollback

1. **Don't pick it from menu** — default kernel is unchanged.
2. **Panic / fail to boot** — pick `linux-lts` or `linux-zen` from the menu.
3. **Boot but broken feature** — bisect by disabling a single fragment, `build.sh all` again.
4. **Full uninstall** — remove `/boot/vmlinuz-linux-asf`, `initramfs-linux-asf*.img`, `System.map-linux-asf`, `/boot/loader/entries/arch-asf*.conf`, `/etc/mkinitcpio.d/linux-asf.preset`, `/lib/modules/6.17.4-asf/`.
5. **Reset config** — `cp .config.preasf.bak .config && make olddefconfig`.

## 8. Untouched / non-goals

Not changed: `/etc/mkinitcpio.conf` (HOOKS/MODULES), existing kernels' images/modules, `/boot/loader/loader.conf` `default=` (timeout may be bumped from 0→3 with preview/confirm), pacman state.

Explicit non-goals for v1: PGO build, PKGBUILD distribution, PREEMPT_RT real-time kernel, Secure-Boot MOK signing setup, userspace tuning (sysctl.d, tlp, ananicy, gamemode).

## 9. Done definition

- `linux-asf` built, installed, bootable.
- `verify.sh --runtime` all green.
- User boots `linux-asf`, no regressions vs `linux-zen` over ≥1 boot cycle.
- `arch-asf/` committed to local kernel git so the build is reproducible.

## 10. Estimated performance delta

Compounded across mixed workloads vs. current `linux-zen` baseline: **~10-25%** general, **much larger** on network-heavy paths (BBR + FQ vs CUBIC + pfifo_fast) and on memory-pressured paths (MGLRU + mTHP). AI/ML latency wins come from HSA/KFD + AVX-512 + SHA-NI crypto offload. Gaming wins come from BORE scheduler + PREEMPT + X3D-aware cluster scheduling + NTSYNC for Wine/Proton.
