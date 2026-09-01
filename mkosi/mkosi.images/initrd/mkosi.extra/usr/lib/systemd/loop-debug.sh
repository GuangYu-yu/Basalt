#!/bin/sh
# 临时诊断：dump loop 模块运行时状态，定位 mount -o loop
# "failed to setup loop device"（×15 → emergency）的确切环节。
# 静态产物含 loop.ko.xz（门禁 PASS）但运行时 setup 失败，需区分：
#   符号缺失（modprobe Unknown symbol/ENOENT）vs 运行时环境（设备节点/索引）。
# 用后即删，不进最终产物。
echo "===LOOP-DEBUG-START==="
echo "uname -r: $(uname -r)"
KVER=$(uname -r)
echo "--- /dev/loop* ---"
ls -la /dev/loop* 2>&1
echo "--- /dev/loop-control ---"
ls -la /dev/loop-control 2>&1
echo "--- loop.ko 文件 ---"
ls -la /lib/modules/$KVER/kernel/drivers/block/loop.ko* 2>&1
echo "--- modules.dep loop 条目 ---"
grep -a 'loop' /lib/modules/$KVER/modules.dep 2>&1
echo "--- modinfo loop ---"
modinfo loop 2>&1 | head -20
echo "--- modprobe -v -v loop ---"
modprobe -v -v loop 2>&1
echo "--- /proc/modules 含 loop ---"
grep loop /proc/modules 2>&1
echo "--- losetup -f ---"
losetup -f 2>&1
echo "--- cmdline ---"
cat /proc/cmdline 2>&1
echo "===LOOP-DEBUG-END==="
