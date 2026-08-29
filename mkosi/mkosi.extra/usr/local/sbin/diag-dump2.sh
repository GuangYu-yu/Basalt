#!/bin/sh
# 第二阶段诊断：landscape-router 完成 TC/eBPF attach 后取证。
# 区分 webserver 故障与入站路径被数据面拦截：本地 curl 走 lo，
# SSH hostfwd 走 eth0 入站；认证态请求抓取 interfaces/all 的
# HTTP 码与响应体（凭据与就绪测试一致）
set -x
{
    echo "===== diag-dump-2 ====="
    date -u
    echo "--- tc qdisc ---"
    tc qdisc show
    echo "--- tc filter eth0 ---"
    tc filter show dev eth0 ingress
    tc filter show dev eth0 egress
    echo "--- webserver local probe (no auth) ---"
    curl -sk -o /dev/null -w 'interfaces/all http_code=%{http_code}\n' --max-time 5 \
        https://127.0.0.1:6443/api/v1/interfaces/all
    echo "--- login ---"
    token=$(curl -sk --max-time 5 -X POST \
        -H 'Content-Type: application/json' \
        -d '{"username":"root","password":"root"}' \
        https://127.0.0.1:6443/api/v1/users/login)
    echo "$token" | head -c 400
    echo
    echo "--- authenticated interfaces/all ---"
    tk=$(printf '%s' "$token" | grep -o 'eyJ[A-Za-z0-9._-]*' | head -n 1)
    curl -sk -o /tmp/iface-resp -w 'http_code=%{http_code}\n' --max-time 5 \
        -H "Authorization: Bearer $tk" \
        https://127.0.0.1:6443/api/v1/interfaces/all
    head -c 800 /tmp/iface-resp
    echo
    echo "--- listening ---"
    ss -tlnp
    echo "--- landscape-router journal ---"
    journalctl -u landscape-router -n 60 --no-pager
    echo "--- dmesg tail ---"
    dmesg | tail -n 30
} > /dev/console
exit 0
