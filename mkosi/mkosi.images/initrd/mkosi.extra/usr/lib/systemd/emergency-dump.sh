#!/bin/sh
# 临时诊断：initrd 阶段 emergency 自动取证（覆盖 @images 挂载 / loop / overlay 组装失败）。
# 用后即删：与真实根版（mkosi.extra/usr/lib/systemd/emergency-dump.sh）互指，
# 诊断结束连同 emergency.service.d/99-dump.conf 一起删除。
# 调用方 99-dump.conf 的 ExecStartPre 带 - 前缀：本脚本任何命令失败不恶化故障。
exec >/dev/console 2>&1
echo "===== EMERGENCY DUMP (initrd) ====="
echo "--- list-jobs ---"
systemctl list-jobs --no-pager 2>&1 || true
echo "--- failed units ---"
systemctl --failed --no-pager 2>&1 || true
echo "--- blkid ---"
blkid 2>&1 || true
echo "--- /dev/disk/by-* ---"
ls -l /dev/disk/by-uuid/ 2>&1 || true
ls -l /dev/disk/by-partuuid/ 2>&1 || true
ls -l /dev/disk/by-partlabel/ 2>&1 || true
echo "--- /proc/mounts ---"
cat /proc/mounts 2>&1 || true
echo "--- root-image fstab (EROFS 本体) ---"
cat /run/root-image/etc/fstab 2>&1 || true
echo "--- sysroot fstab (overlay 视图，best-effort) ---"
cat /sysroot/etc/fstab 2>&1 || true
echo "--- repart journal ---"
journalctl -b --no-pager -u systemd-repart 2>&1 | tail -40 || true
echo "--- overlay/loop/erofs/mount failures ---"
journalctl -b --no-pager 2>&1 | grep -aiE "overlay|loop|erofs|mount.*failed|emergency" | tail -60 || true
echo "--- dmesg tail ---"
dmesg 2>&1 | tail -30 || true
echo "===== END DUMP ====="
exit 0
