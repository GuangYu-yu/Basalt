#!/bin/sh
# 临时诊断：switch_root 后主系统 emergency 自动取证（覆盖 var.mount / fsck / local-fs 失败）。
# 用后即删：与 initrd 版（mkosi.images/initrd/mkosi.extra/usr/lib/systemd/emergency-dump.sh）互指，
# 诊断结束连同 emergency.service.d/99-dump.conf 一起删除。
# 调用方 99-dump.conf 的 ExecStartPre 带 - 前缀：本脚本任何命令失败不恶化故障。
# 真实根视图：/etc/fstab = overlay（首启 upper 空 = EROFS 内容）；/run/root-image = EROFS 本体对照。
exec >/dev/console 2>&1
echo "===== EMERGENCY DUMP (real-root) ====="
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
echo "--- real-root /etc/fstab ---"
cat /etc/fstab 2>&1 || true
echo "--- root-image fstab (EROFS 本体对照) ---"
cat /run/root-image/etc/fstab 2>&1 || true
echo "--- repart journal ---"
journalctl -b --no-pager -u systemd-repart 2>&1 | tail -40 || true
echo "--- fsck/var.mount/mount failures ---"
journalctl -b --no-pager 2>&1 | grep -aiE "var\.mount|fsck|mount.*failed|emergency" | tail -60 || true
echo "--- dmesg tail ---"
dmesg 2>&1 | tail -30 || true
echo "===== END DUMP ====="
exit 0
