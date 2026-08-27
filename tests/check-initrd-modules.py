#!/usr/bin/env python3
"""模块门禁：从 UKI 抽取 .initrd，断言引导契约所需内核模块确实存在。

需求契约（与 mkosi.conf 的 KernelModules= 对应；此处是验证端，二者需同步修改）：
  启动链   virtio_blk virtio_pci virtio_net ahci sd_mod nvme autofs
  根/引导  erofs overlay btrfs vfat
  数据面   nf_conntrack tun veth bridge e1000 r8169
遗漏 = 退出码 1（构建期秒级失败，替代 5 分钟 SSH 超时才发现）。
"""
import re
import struct
import subprocess
import sys
from pathlib import Path

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


def extract_initrd(uki: Path) -> bytes:
    sec = subprocess.run(
        ["objcopy", "-O", "binary", "--only-section=.initrd", str(uki)],
        check=True, stdout=subprocess.PIPE,
    ).stdout
    return sec


def decode_zstd(data: bytes) -> bytes:
    # .initrd = 各 cpio 独立 zstd 压缩后拼接；zstd CLI 原生支持连续帧
    return subprocess.run(["zstd", "-dc"], input=data, check=True,
                          stdout=subprocess.PIPE).stdout


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
    uki = Path(sys.argv[1])
    blob = decode_zstd(extract_initrd(uki))
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