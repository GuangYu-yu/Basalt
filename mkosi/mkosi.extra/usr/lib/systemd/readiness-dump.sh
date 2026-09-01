#!/bin/sh
# 临时诊断：就绪性自动取证（boot 完成后 dump 服务/网络状态到 console，定位
# bootstrap SSH 不可达根因）。用后即删：与 readiness-dump.service 同生命周期。
# 调用方为 oneshot 服务，任何命令失败不中断（|| true）。
exec >/dev/console 2>&1
echo "===== READINESS DUMP ====="
echo "--- ip addr ---"
ip -br addr 2>&1 || true
echo "--- ip link ---"
ip -br link 2>&1 || true
echo "--- services active ---"
systemctl is-active ssh landscape-router networking 2>&1 || true
echo "--- landscape-router status ---"
systemctl status landscape-router --no-pager 2>&1 | tail -30 || true
echo "--- landscape-router journal ---"
journalctl -b --no-pager -u landscape-router 2>&1 | tail -40 || true
echo "--- ssh status ---"
systemctl status ssh --no-pager 2>&1 | tail -15 || true
echo "--- ssh journal ---"
journalctl -b --no-pager -u ssh 2>&1 | tail -25 || true
echo "--- failed units ---"
systemctl --failed --no-pager 2>&1 || true
echo "--- listeners :22 ---"
ss -tlnp 2>&1 | grep -E ':22|State' || true
echo "--- /root (landscape) ---"
ls -la /root/ 2>&1 | grep -E "landscape|total" || true
echo "--- /var/lib/landscape ---"
ls -la /var/lib/landscape/ 2>&1 || true
echo "--- /usr/share/landscape ---"
ls -la /usr/share/landscape/ 2>&1 || true
echo "--- machine-id ---"
cat /etc/machine-id 2>&1 || true
echo "--- ssh host keys ---"
ls -la /etc/ssh/ 2>&1 | grep -E "ssh_host|total" || true
echo "--- boot journal (landscape/sshd/failed/error) ---"
journalctl -b --no-pager 2>&1 | grep -aiE "landscape|sshd|failed|error" | tail -40 || true
echo "===== END DUMP ====="
exit 0
