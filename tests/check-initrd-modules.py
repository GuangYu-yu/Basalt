#!/usr/bin/env python3
"""模块门禁：两套工件 × 三态契约，断言引导/数据面所需内核模块存在。

工件：
  initrd  mkosi 拆分产物（经 extract_pe_section 从 UKI 拆出的合并 initrd，
          build.sh 收集到 output/）；此处零抽取逻辑，只做解码与断言
  root    pass1 SplitArtifacts=partitions 拆出的裸 EROFS 根镜像（可选参数，
          缺省跳过 ROOT 断言；需要 root（loop 挂载）或 erofsfuse 读取）

三态契约（与 mkosi.conf 的 KernelInitrdModules=/KernelModules= 对应；此处是
验证端，二者需同步修改；绝不比较完整模块集合，只做两种判断）：
  required  子集判断：契约集合 ⊆ 工件内模块（.ko 文件或 modules.builtin）
  forbidden 不相交判断：工件内模块 ∷ 禁用子系统 = ∅
  其余      allowed：不在契约内的模块不构成失败（依赖闭包合法产物）

契约内容：
  initrd 启动链  virtio_blk virtio_pci virtio_net ahci sd_mod nvme autofs4
                 erofs overlay btrfs vfat loop
  initrd 平台    ata_piix vmw_pvscsi mptspi mpt3sas hv_vmbus hv_storvsc
                 hv_netvsc xen_blkfront
  root 数据面    nf_conntrack tun veth bridge e1000 r8169
  forbidden      net/bluetooth/ net/wireless/ drivers/net/wireless/
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
    "virtio_blk", "virtio_pci", "virtio_net", "ahci", "sd_mod", "nvme", "autofs4",
    "erofs", "overlay", "btrfs", "vfat", "loop",
    # 各平台存储控制器 / Hypervisor 半虚拟化：PVE IDE / ESXi / Hyper-V / Xen
    "ata_piix", "vmw_pvscsi", "mptspi", "mpt3sas",
    "hv_vmbus", "hv_storvsc", "hv_netvsc", "xen_blkfront",
}

REQUIRED_ROOT = {
    # 数据面：landscape NIC / TC-eBPF / 虚拟组网
    "nf_conntrack", "tun", "veth", "bridge", "e1000", "r8169",
}

# 禁用子系统（路径级判断，命中即违例）
FORBIDDEN_PATHS = ("net/bluetooth/", "net/wireless/", "drivers/net/wireless/")

# initrd 单元契约：自定义 initrd 子镜像必须真实生效（主镜像未声明
# Initrds= 时 mkosi 静默用默认 initrd，这些文件缺失且启动只读根）
REQUIRED_UNITS = {
    "usr/lib/systemd/system/initrd-root-overlay.service",
    "usr/lib/systemd/system/initrd-switch-root.service.d/10-overlay.conf",
}

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


def modules_from_paths(paths: set[str], builtin: set[str]) -> tuple[set[str], list[str]]:
    """三态契约输入：模块名集合（.ko + builtin）与违例路径清单。"""
    kos = {modname(n): n for n in paths
           if re.search(r"usr/lib/modules/[^/]+/.*\.ko(\.(gz|xz|zst))?$", n)}
    violations = sorted(
        {n for n in paths if any(f in f"/{n}" for f in FORBIDDEN_PATHS)})
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


def root_erofs_modules(erofs: Path) -> tuple[set[str], list[str]]:
    """读取裸 EROFS 根镜像的模块清单（usr/lib/modules）。

    需要文件系统访问：root（loop 挂载）或 erofsfuse（非 root）。
    """
    tmp = tempfile.mkdtemp(prefix="basalt-gate-")
    mnt = os.path.join(tmp, "root")
    os.mkdir(mnt)
    if os.geteuid() == 0:
        subprocess.run(["mount", "-o", "ro,loop", str(erofs), mnt], check=True)
        try:
            paths, builtin = walk_modules(mnt)
        finally:
            subprocess.run(["umount", mnt], check=True)
    elif shutil.which("erofsfuse"):
        subprocess.run(["erofsfuse", str(erofs), mnt], check=True)
        try:
            paths, builtin = walk_modules(mnt)
        finally:
            unmount = shutil.which("fusermount3") or shutil.which("fusermount")
            subprocess.run([unmount, "-u", mnt], check=True)
    else:
        sys.exit("无法读取 ROOT 工件：需要 root（loop 挂载）或 erofsfuse")
    shutil.rmtree(tmp, ignore_errors=True)
    return modules_from_paths(paths, builtin)


def check(blob: bytes) -> int:
    names = cpio_names(blob)
    paths = set(names)
    builtin = builtin_from_blob(blob, names)
    modules, forbidden = modules_from_paths(paths, builtin)

    missing = check_artifact("initrd", modules, forbidden, REQUIRED_INITRD)

    name_set = set(names)
    for unit in sorted(REQUIRED_UNITS):
        ok = unit in name_set
        print(f"  {'OK ' if ok else 'MISS'} {unit}")
        if not ok:
            missing.append(unit)

    if missing:
        print(f"[module-gate] FAIL 缺失/违例：{' '.join(missing)}", file=sys.stderr)
        return 1
    print("[module-gate] initrd PASS")
    return 0


def main() -> int:
    initrd = Path(sys.argv[1])
    blob = decode_initrd(initrd.read_bytes())
    rc = check(blob)

    if len(sys.argv) > 2:
        # ROOT 工件（pass1 拆出的裸 EROFS 根镜像）
        root_modules, root_forbidden = root_erofs_modules(Path(sys.argv[2]))
        missing = check_artifact("root(EROFS)", root_modules,
                                 root_forbidden, REQUIRED_ROOT)
        if missing:
            print(f"[module-gate] FAIL ROOT 缺失/违例：{' '.join(missing)}", file=sys.stderr)
            return 1
        print("[module-gate] root PASS")
    return rc


if __name__ == "__main__":
    sys.exit(main())
