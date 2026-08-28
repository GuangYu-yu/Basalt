#!/usr/bin/env python3
"""模块门禁：校验 mkosi 拆分产物 basalt.initrd，断言引导契约所需内核模块存在。

输入是 mkosi 构建时经其自身 extract_pe_section（pefile，取
min(VirtualSize, SizeOfRawData)）从 UKI 拆出的合并 initrd
（mkosi v26 SplitArtifacts 默认含 initrd；build.sh 收集到 output/），
此处零抽取逻辑，只做解码与断言。

需求契约（与 mkosi.conf 的 KernelModules= 对应；此处是验证端，二者需同步修改）：
  启动链   virtio_blk virtio_pci virtio_net ahci sd_mod nvme autofs
  根/引导  erofs overlay btrfs vfat
  数据面   nf_conntrack tun veth bridge e1000 r8169
遗漏 = 退出码 1（构建期秒级失败，替代 5 分钟 SSH 超时才发现）。
"""
import re
import sys
from pathlib import Path

import zstandard

REQUIRED = {
    "virtio_blk", "virtio_pci", "virtio_net", "ahci", "sd_mod", "nvme", "autofs",
    "erofs", "overlay", "btrfs", "vfat",
    # 旧版延续的部署场景：PVE IDE / ESXi / Hyper-V / Xen
    "ata_piix", "vmw_pvscsi", "mptspi", "mpt3sas",
    "hv_vmbus", "hv_storvsc", "hv_netvsc", "xen_blkfront",
    # 数据面
    "nf_conntrack", "tun", "veth", "bridge", "e1000", "r8169",
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
    return re.sub(r"\.ko(\.(gz|xz|zst))?$", "", base)


def main() -> int:
    initrd = Path(sys.argv[1])
    blob = decode_initrd(initrd.read_bytes())
    names = cpio_names(blob)

    kos = {modname(n): n for n in names
           if re.search(r"usr/lib/modules/[^/]+/.*\.ko(\.(gz|xz|zst))?$", n)}
    aliases = blob.count(b"autofs4")

    missing = sorted(REQUIRED - set(kos)
                     - ({"autofs"} if aliases else set()))
    total = len(kos)
    print(f"[module-gate] initrd 内模块文件：{total} 个")
    for req in sorted(REQUIRED):
        hit = kos.get(req)
        print(f"  {'OK ' if hit else 'MISS'} {req}" + (f" -> {hit}" if hit else ""))

    if missing:
        print(f"[module-gate] FAIL 缺失：{' '.join(missing)}", file=sys.stderr)
        return 1
    print("[module-gate] PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())