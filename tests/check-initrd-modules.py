#!/usr/bin/env python3
"""模块门禁：两套工件 × 三态契约，断言引导/数据面所需内核模块存在。

工件：
  initrd  mkosi 拆分产物（经 extract_pe_section 从 UKI 拆出的合并 initrd，
          build.sh 收集到 output/）；此处零抽取逻辑，只做解码与断言
  root    pass1 SplitArtifacts=partitions 拆出的裸 EROFS 根镜像（可选参数，
          缺省跳过 ROOT 断言；需要 root（loop 挂载）或 erofsfuse 读取）

三态契约（与 mkosi.conf 的 KernelInitrdModules=/KernelModules= 对应；此处是
验证端，契约定义在 mkosi.conf，本脚本自动派生、不手工同步）：
  required  子集判断：契约集合 ⊆ 工件内模块（.ko 文件或 modules.builtin）
  forbidden 不相交判断：工件内模块 ∷ 配置排除的子系统 = ∅（forbidden 前缀
            由 forbidden_from_conf() 从 KernelInitrdModules=/KernelModules=
            的负向目录条目派生——单一事实，任一排除项因依赖闭包拉回而
            失效（如 cfg80211）都会被门禁立即暴露）
  其余      allowed：不在契约内的模块不构成失败（依赖闭包合法产物）

契约内容：
  initrd 启动链  virtio_blk virtio_scsi virtio_pci virtio_net ahci sd_mod
                 nvme autofs4 erofs overlay btrfs vfat loop
  initrd 平台    ata_piix vmw_pvscsi mptspi mpt3sas hv_vmbus
                 hv_storvsc hv_netvsc xen_blkfront
  root 数据面    nf_conntrack tun veth bridge e1000 r8169
遗漏/越禁 = 退出码 1（构建期秒级失败，替代 5 分钟 SSH 超时才发现）。
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import zstandard

REQUIRED_INITRD = {
    "virtio_blk", "virtio_scsi", "virtio_pci", "virtio_net", "ahci", "sd_mod", "nvme", "autofs4",
    "erofs", "overlay", "btrfs", "vfat", "loop",
    # btrfs 符号依赖（libcrc32c 引用 crc32c 符号；crc32c_generic 即满足，
    # crc32c-intel 在 arch/x86/crypto 不在根树保留集，不可得）
    "crc32c_generic",
    # 各平台存储控制器 / Hypervisor 半虚拟化：QEMU IDE / ESXi / Hyper-V / Xen
    "ata_piix", "vmw_pvscsi", "mptspi", "mpt3sas",
    "hv_vmbus", "hv_storvsc", "hv_netvsc", "xen_blkfront",
}

REQUIRED_ROOT = {
    # 数据面核心（netfilter 连接跟踪/NAT/表）
    "nf_conntrack", "nf_tables", "nfnetlink",
    # 流量控制（sched/cls/act：tc 链，landscape QoS）
    "sch_htb", "sch_fq_codel", "cls_bpf", "cls_fw", "act_skbedit", "act_mirred",
    # 虚拟组网（bridge/veth/tun/隧道/802.1Q/wireguard）
    "bridge", "veth", "tun", "vxlan", "geneve", "8021q", "wireguard",
    # 加密转发（xfrm/IPsec 隧道）
    "xfrm_user", "xfrm4_tunnel",
    # 有线网卡驱动代表（drivers/net/ethernet 等）
    "e1000", "e1000e", "r8169", "virtio_net", "igb",
    # 链路聚合（bonding/team）
    "bonding", "team",
    # ppp（WAN 上行拨号）
    "ppp_generic", "pppoe",
}

# initrd 单元契约：自定义 initrd 子镜像必须真实生效（主镜像未声明
# Initrds= 时 mkosi 静默用默认 initrd，这些文件缺失且启动只读根）。
# 含 repart 扩容关键三件套：时序 dropin、定义源（--definitions）dropin、
# 定义文件本身——任一丢失则首启扩容回归（repart 无定义 FAILED）
REQUIRED_UNITS = {
    "usr/lib/systemd/system/initrd-root-overlay.service",
    "usr/lib/systemd/system/initrd-switch-root.service.d/10-overlay.conf",
    "usr/lib/systemd/system/systemd-repart.service.d/90-after-sysroot.conf",
    "usr/lib/systemd/system/systemd-repart.service.d/99-console.conf",
    "etc/repart.d/92-var-grow.conf",
}


def forbidden_from_conf(conf: Path, setting: str) -> tuple[str, ...]:
    """从 mkosi.conf 指定设置块提取负向目录条目（去 `-` 前缀）。

    契约单一事实：forbidden = KernelInitrdModules=/KernelModules= 的显式
    排除项（`-` 前缀目录）。门禁据此验证每个排除项都真实生效——任一
    排除的子系统因依赖闭包拉回残留模块（如 cfg80211）即失败。
    解析容忍行内注释、空行与块内缩进注释；顶格新行结束当前块。
    """
    lines = conf.read_text(encoding="utf-8").splitlines()
    for i, line in enumerate(lines):
        if line.strip() != setting:
            continue
        out = []
        for raw in lines[i + 1:]:
            if raw.strip() and not raw[0].isspace():
                break
            v = raw.split("#", 1)[0].strip()
            if v.startswith("-") and v.endswith("/"):
                out.append(v[1:])
        return tuple(out)
    return ()


def retained_from_conf(conf: Path, setting: str) -> tuple[str, ...]:
    """从 mkosi.conf 指定设置块提取正向目录条目（net/ drivers/net/ 等）。

    与 forbidden_from_conf 对应：保留目录是"无遗漏"粗粒度契约——镜像内
    kernel/ 目录树必须包含它们（filter 配置失效导致整个子系统丢失即失败，
    如 KernelInitrdModules= 空格组导致的空 initrd 教训）。default/host/
    模块名等非目录条目自动跳过。
    """
    lines = conf.read_text(encoding="utf-8").splitlines()
    for i, line in enumerate(lines):
        if line.strip() != setting:
            continue
        out = []
        for raw in lines[i + 1:]:
            if raw.strip() and not raw[0].isspace():
                break
            v = raw.split("#", 1)[0].strip()
            if (not v.startswith("-") and not v.startswith("re:")
                    and not v.startswith("default") and v.endswith("/")):
                out.append(v)
        return tuple(out)
    return ()


def kernel_dirs(paths: set[str]) -> set[str]:
    """镜像内 kernel/ 目录树（含各级父目录，相对 kver，如 net/core/）。"""
    dirs = set()
    for p in paths:
        m = re.match(r"usr/lib/modules/[^/]+/kernel/(.+)/[^/]+\.ko", p)
        if not m:
            continue
        parts = m.group(1).split("/")
        for i in range(1, len(parts) + 1):
            dirs.add("/".join(parts[:i]) + "/")
    return dirs

NEWC_MAGIC = b"070701"
ZSTD_MAGIC = b"\x28\xb5\x2f\xfd"


def decode_initrd(data: bytes) -> bytes:
    """按内核 initramfs 解析语义处理混拼流：zstd 帧解压、裸 cpio 段原样保留。

    mkosi 的合并 initrd = initrd.cpio.zst（zstd 帧）+ kernel-modules initrd
    （未压缩 cpio），内核 initramfs 解析器逐段自识别，故系统能正常启动；
    此处必须同样逐段处理，整体 zstd -dc 会在裸 cpio 段报错。
    解码失败时把证据落盘 output/test-logs/（失败也会随 artifact 上传）。
    """
    probe_dir = Path("output/test-logs/module-gate")
    out = bytearray()
    rest = data
    while rest:
        # mkosi join_initrds 在每段后补零到 4 字节对齐（mkosi qemu.py:619），
        # zstd 帧与 newc 头均不以零开头，剥掉前导零即跳过段间填充
        rest = rest.lstrip(b"\x00")
        if not rest:
            break
        if rest[:4] == ZSTD_MAGIC:
            dctx = zstandard.ZstdDecompressor().decompressobj()
            try:
                out += dctx.decompress(rest)
            except zstandard.ZstdError as e:
                dump_probe(probe_dir, data, f"zstd: {e}")
                sys.exit(f"zstd 解压失败：{e}\n证据已写入 {probe_dir}")
            rest = dctx.unused_data
        elif rest[:6] == NEWC_MAGIC:
            out += rest
            rest = b""
        else:
            dump_probe(probe_dir, data, f"偏移 {len(data) - len(rest)} 处出现无法识别的段")
            sys.exit(f"initrd 段无法识别（大小 {len(data)}），证据已写入 {probe_dir}")
    return bytes(out)


def dump_probe(probe_dir: Path, data: bytes, reason: str) -> None:
    probe_dir.mkdir(parents=True, exist_ok=True)
    (probe_dir / "head-1m.bin").write_bytes(data[:1 << 20])
    (probe_dir / "tail-1m.bin").write_bytes(data[-(1 << 20):])
    (probe_dir / "info.txt").write_text(
        f"size={len(data)}\n"
        f"head64={data[:64].hex()}\n"
        f"tail64={data[-64:].hex()}\n"
        f"zstd_magic_at={data.find(ZSTD_MAGIC)}\n"
        f"reason={reason}\n",
        encoding="utf-8")


def cpio_names(blob: bytes) -> list[str]:
    """遍历拼接的 newc cpio 归档，返回全部文件名（解压后的裸 cpio）。"""
    names = []
    off = 0
    while True:
        off = blob.find(NEWC_MAGIC, off)
        if off < 0:
            break
        hdr = blob[off:off + 110]
        try:
            namesize = int(hdr[94:102], 16)
            filesize = int(hdr[54:62], 16)
        except ValueError:
            off += 1
            continue
        name = blob[off + 110:off + 110 + namesize - 1].decode("utf-8", "replace")
        # newc 格式 name 与 data 各自独立对齐 4 字节
        data_start = (off + 110 + namesize + 3) & ~3
        off = (data_start + filesize + 3) & ~3
        if name != "TRAILER!!!":
            names.append(name)
    return names


def modname(path: str) -> str:
    base = path.rsplit("/", 1)[-1]
    base = re.sub(r"\.ko(\.(gz|xz|zst))?$", "", base)
    # 内核模块名把文件名中的连字符归一为下划线（如 xen-blkfront -> xen_blkfront）
    return base.replace("-", "_")


def builtin_from_blob(blob: bytes, names: list[str]) -> set[str]:
    """从 cpio 数据流解析 modules.builtin（CONFIG_...=y 模块无 .ko 文件）。"""
    builtin = set()
    for path in names:
        if not path.endswith("modules.builtin"):
            continue
        hdr_off = blob.find(path.encode())
        if hdr_off < 0:
            continue
        # 回退到该条目头起始（文件名紧跟 110 字节头），沿头读 filesize
        start = blob.rfind(NEWC_MAGIC, 0, hdr_off)
        hdr = blob[start:start + 110]
        filesize = int(hdr[54:62], 16)
        namesize = int(hdr[94:102], 16)
        data_start = (start + 110 + namesize + 3) & ~3
        for line in blob[data_start:data_start + filesize].decode("utf-8", "replace").splitlines():
            if line.strip():
                builtin.add(modname(line.strip()))
    return builtin


def modules_from_paths(paths: set[str], builtin: set[str],
                       forbidden: tuple[str, ...]) -> tuple[set[str], list[str]]:
    """三态契约输入：模块名集合（.ko + builtin）与违例路径清单。"""
    kos = {modname(n): n for n in paths
           if re.search(r"usr/lib/modules/[^/]+/.*\.ko(\.(gz|xz|zst))?$", n)}
    violations = sorted(
        {n for n in paths if any(f in f"/{n}" for f in forbidden)})
    return set(kos) | builtin, violations


def check_artifact(label: str, modules: set[str], forbidden: list[str],
                   required: set[str]) -> list[str]:
    """三态断言：required 子集 / forbidden 不相交；返回失败项清单。"""
    print(f"[module-gate] {label} 内模块（含 built-in）：{len(modules)} 个")
    missing = []
    for req in sorted(required):
        ok = req in modules
        print(f"  {'OK ' if ok else 'MISS'} {req}")
        if not ok:
            missing.append(req)
    for path in forbidden:
        print(f"  FORBIDDEN {path}")
    return missing + forbidden


def walk_modules(root: str) -> tuple[set[str], set[str]]:
    """遍历挂载点内的 usr/lib/modules，返回（.ko 路径集，builtin 模块名集）。"""
    paths: set[str] = set()
    builtin: set[str] = set()
    for dirpath, _dirnames, filenames in os.walk(root):
        rel_dir = os.path.relpath(dirpath, root)
        for fn in filenames:
            rel = os.path.normpath(os.path.join(rel_dir, fn))
            if "usr/lib/modules/" in f"/{rel}":
                paths.add(rel.lstrip("/"))
                if fn == "modules.builtin":
                    try:
                        for line in Path(dirpath, fn).read_text(
                                encoding="utf-8", errors="replace").splitlines():
                            if line.strip():
                                builtin.add(modname(line.strip()))
                    except OSError:
                        pass
    return paths, builtin


def root_erofs_modules(erofs: Path, forbidden: tuple[str, ...]
                       ) -> tuple[set[str], list[str], set[str]]:
    """读取裸 EROFS 根镜像的模块清单（usr/lib/modules）。

    需要文件系统访问：root（loop 挂载）或 erofsfuse（非 root）。
    返回（模块名集, 违例路径, 全部 usr/lib/modules 路径集）。
    """
    tmp = tempfile.mkdtemp(prefix="basalt-gate-")
    mnt = os.path.join(tmp, "root")
    os.mkdir(mnt)
    try:
        if os.geteuid() == 0:
            subprocess.run(["mount", "-o", "ro,loop", str(erofs), mnt], check=True)
        elif shutil.which("erofsfuse"):
            subprocess.run(["erofsfuse", str(erofs), mnt], check=True)
        else:
            sys.exit("无法读取 ROOT 工件：需要 root（loop 挂载）或 erofsfuse")
        paths, builtin = walk_modules(mnt)
    finally:
        if os.geteuid() == 0:
            subprocess.run(["umount", mnt], check=True)
        else:
            unmount = shutil.which("fusermount3") or shutil.which("fusermount")
            subprocess.run([unmount, "-u", mnt], check=True)
    shutil.rmtree(tmp, ignore_errors=True)
    modules, violations = modules_from_paths(paths, builtin, forbidden)
    return modules, violations, paths


def check(blob: bytes, forbidden: tuple[str, ...],
          retained: tuple[str, ...]) -> int:
    names = cpio_names(blob)
    paths = set(names)
    builtin = builtin_from_blob(blob, names)
    modules, violations = modules_from_paths(paths, builtin, forbidden)

    missing = check_artifact("initrd", modules, violations, REQUIRED_INITRD)
    for r in retained:
        if r not in kernel_dirs(paths):
            print(f"  MISS-DIR {r}")
            missing.append(f"缺保留目录 {r}")

    name_set = set(names)
    for unit in sorted(REQUIRED_UNITS):
        ok = unit in name_set
        print(f"  {'OK ' if ok else 'MISS'} {unit}")
        if not ok:
            missing.append(unit)

    if missing:
        # 失败自证：builtin 全集（空集也能暴露解析 bug）+ modules.builtin 文件
        # 是否存在于 cpio 名录（存在但集合为空 = builtin_from_blob 解析失败）
        print(f"[module-gate] builtin 集合（{len(builtin)} 个）: "
              f"{' '.join(sorted(builtin)) or '<EMPTY>'}")
        print("[module-gate] modules.builtin 文件存在: "
              f"{any(n.endswith('modules.builtin') for n in names)}")
        print(f"[module-gate] FAIL 缺失/违例：{' '.join(missing)}", file=sys.stderr)
        return 1
    print("[module-gate] initrd PASS")
    return 0


def audit_dirs(paths: set[str], label: str) -> None:
    """目录审计：输出镜像内 kernel/ 目录树，暴露"该排除未排除"的多余子系统。

    forbidden 只验证 KernelModules= 显式排除项；net/ 内未排除的子系统
    （如废弃协议 ipx/netrom/llc）不在验证范围——审计输出供构建者审查，
    发现多余子系统后加入 KernelModules= 排除项（门禁随之自动收紧）。
    """
    dirs = kernel_dirs(paths)
    top = sorted({d.split("/", 1)[0] + "/" for d in dirs})
    net2 = sorted({"/".join(d.split("/")[:2]) + "/"
                   for d in dirs if d.startswith("net/")})
    drv2 = sorted({"/".join(d.split("/")[:2]) + "/"
                   for d in dirs if d.startswith("drivers/")})
    print(f"[module-gate] {label} kernel/ 顶层：{' '.join(top)}")
    print(f"[module-gate] {label} net/ 子目录：{' '.join(net2)}")
    print(f"[module-gate] {label} drivers/ 子目录：{' '.join(drv2)}")


def extract_cpio(blob: bytes, dest: Path) -> None:
    """把合并 cpio 流解包到目录（depmod 需要真实文件树；含 symlink/dir）。"""
    off = 0
    while True:
        off = blob.find(NEWC_MAGIC, off)
        if off < 0:
            break
        hdr = blob[off:off + 110]
        try:
            namesize = int(hdr[94:102], 16)
            filesize = int(hdr[54:62], 16)
            mode = int(hdr[14:22], 16)
        except ValueError:
            off += 1
            continue
        name = blob[off + 110:off + 110 + namesize - 1].decode("utf-8", "replace")
        data_start = (off + 110 + namesize + 3) & ~3
        body = blob[data_start:data_start + filesize]
        off = (data_start + filesize + 3) & ~3
        if name in ("", "TRAILER!!!"):
            continue
        target = dest / name.lstrip("/")
        if mode & 0o170000 == 0o120000:  # symlink
            target.parent.mkdir(parents=True, exist_ok=True)
            try:
                target.symlink_to(body.decode("utf-8", "replace"))
            except OSError:
                pass
        elif mode & 0o170000 == 0o040000:  # dir
            target.mkdir(parents=True, exist_ok=True)
        else:
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(body)


def kver_from_names(names: list[str]) -> str | None:
    """从 cpio 名录提取内核版本目录（usr/lib/modules/<kver>/）。"""
    for n in names:
        m = re.match(r"usr/lib/modules/([^/]+)/", n)
        if m:
            return m.group(1)
    return None


def extract_system_map(root_raw: Path, kver: str, dest: Path) -> bool:
    """从 pass1 root 分区产物（裸 EROFS）提取 /boot/System.map-<kver>。

    用 dump.erofs --path/--cat（无 FUSE 依赖；erofs-utils 1.9.4 无
    --extract 参数）。返回是否成功（退出码 0 且产物非空）。
    """
    cmd = ["dump.erofs", f"--path=/boot/System.map-{kver}", "--cat",
           str(root_raw)]
    with open(dest, "wb") as f:
        p = subprocess.run(cmd, stdout=f, stderr=subprocess.PIPE)
    return p.returncode == 0 and dest.stat().st_size > 0


def check_symbol_closure(blob: bytes, root_raw: Path, kver: str) -> list[str]:
    """depmod -e -F 符号完整性门禁：initrd 模块集引用的符号必须由
    模块集自身或内核（System.map）提供，否则启动链加载必然失败。

    mkosi 的 modinfo 闭包不含符号依赖（33514287139 实证：btrfs→libcrc32c
    需 crc32c 符号提供者，遗漏导致 modprobe ENOENT）。此处以 depmod 的
    符号解析（dep 级 + -F 内核符号）补齐该盲区。诊断输出非空即失败
    （不解析关键词，depmod 措辞无稳定契约）。
    """
    with tempfile.TemporaryDirectory(prefix="basalt-sym-") as tmp:
        root = Path(tmp)
        extract_cpio(blob, root)
        smap = root / "System.map"
        if not extract_system_map(root_raw, kver, smap):
            return [f"System.map 提取失败：dump.erofs --path=/boot/System.map-{kver}"]
        p = subprocess.run(
            ["depmod", "-b", str(root), "-e", "-F", str(smap), kver],
            capture_output=True, text=True)
        if p.returncode < 0:
            return [f"depmod 执行失败（signal {p.returncode}）"]
        if p.returncode != 0 and not p.stderr.strip():
            return [f"depmod 退出码 {p.returncode} 且无诊断输出"]
        return [ln.strip() for ln in p.stderr.splitlines() if ln.strip()]


def main() -> int:
    conf = Path(__file__).resolve().parent.parent / "mkosi" / "mkosi.conf"
    initrd_forbidden = forbidden_from_conf(conf, "KernelInitrdModules=")
    root_forbidden = forbidden_from_conf(conf, "KernelModules=")
    initrd_retained = retained_from_conf(conf, "KernelInitrdModules=")
    root_retained = retained_from_conf(conf, "KernelModules=")
    # 防御：排除项派生为空 = 配置解析失效，直接失败而非静默放行
    if not initrd_forbidden or not root_forbidden:
        sys.exit(f"门禁配置解析失败：mkosi.conf 排除项派生为空 "
                 f"(initrd={len(initrd_forbidden)}, root={len(root_forbidden)})")

    initrd = Path(sys.argv[1])
    blob = decode_initrd(initrd.read_bytes())
    rc = check(blob, initrd_forbidden, initrd_retained)

    if len(sys.argv) > 3:
        # 符号完整性门禁（depmod -e -F）：initrd 模块集引用符号必须自足
        # （模块集内提供 或 内核导出），补齐 mkosi modinfo 闭包不含符号
        # 依赖的盲区（33514287139：btrfs 符号依赖 crc32c 遗漏 → 启动失败）
        kver = kver_from_names(cpio_names(blob))
        if not kver:
            sys.exit("initrd 未找到 usr/lib/modules/<kver>，符号门禁无法运行")
        sym_issues = check_symbol_closure(blob, Path(sys.argv[3]), kver)
        if sym_issues:
            print(f"[module-gate] FAIL 符号完整性：{'；'.join(sym_issues[:20])}",
                  file=sys.stderr)
            return 1
        print("[module-gate] symbol closure PASS")

    if len(sys.argv) > 2:
        # ROOT 工件（pass1 拆出的裸 EROFS 根镜像）
        root_modules, root_violations, root_paths = \
            root_erofs_modules(Path(sys.argv[2]), root_forbidden)
        missing = check_artifact("root(EROFS)", root_modules,
                                 root_violations, REQUIRED_ROOT)
        for r in root_retained:
            if r not in kernel_dirs(root_paths):
                print(f"  MISS-DIR {r}")
                missing.append(f"缺保留目录 {r}")
        if missing:
            print(f"[module-gate] FAIL ROOT 缺失/违例：{' '.join(missing)}", file=sys.stderr)
            return 1
        print("[module-gate] root PASS")
        audit_dirs(root_paths, "root(EROFS)")
    return rc


if __name__ == "__main__":
    sys.exit(main())