#!/bin/sh
# 临时诊断：dump 运行时模块树真实状态 + modprobe -v -v 定位 btrfs ENOENT 环节。
# 用于对比静态产物（UKI .initrd 帧2 含 btrfs.ko.xz）与运行时可见性。
# 用后即删，不进最终产物。
echo "===BTRFS-DEBUG-START==="
echo "uname -r: $(uname -r)"
KVER=$(uname -r)
echo "--- /lib/modules ---"
ls -la /lib/modules/ 2>&1
echo "--- /lib/modules/$KVER ---"
ls -la /lib/modules/$KVER/ 2>&1
echo "--- /lib/modules/$KVER/kernel/fs ---"
ls -la /lib/modules/$KVER/kernel/fs/ 2>&1
echo "--- /lib/modules/$KVER/kernel/fs/btrfs ---"
ls -la /lib/modules/$KVER/kernel/fs/btrfs/ 2>&1
echo "--- modules.dep btrfs 条目 ---"
grep -a btrfs /lib/modules/$KVER/modules.dep 2>&1
echo "--- /proc/modules (已加载) ---"
cat /proc/modules 2>&1
echo "--- modprobe -v -v btrfs ---"
modprobe -v -v btrfs 2>&1
echo "--- modprobe -v -v xor ---"
modprobe -v -v xor 2>&1
echo "--- modprobe -v -v raid6_pq ---"
modprobe -v -v raid6_pq 2>&1
echo "--- modprobe -v -v libcrc32c ---"
modprobe -v -v libcrc32c 2>&1
echo "===BTRFS-DEBUG-END==="
