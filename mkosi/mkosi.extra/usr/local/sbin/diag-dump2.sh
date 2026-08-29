#!/bin/sh
# 第二阶段诊断：landscape-router 完成 TC/eBPF attach 后取证。
# 区分 webserver 故障与入站路径被数据面拦截：本地 curl 走 lo，
# SSH hostfwd 走 eth0 入站；认证态请求抓取服务状态响应体
# （凭据与就绪测试一致，login 路径与 tests/common.sh 的 API_AUTH_PATH 对齐）
{
    echo "===== diag-dump-2 ====="
    date -u
    echo "--- tc qdisc ---"
    tc qdisc show
    echo "--- webserver local probe (no auth) ---"
    curl -sk -o /dev/null -w 'interfaces/all http_code=%{http_code}\n' --max-time 5 \
        https://127.0.0.1:6443/api/v1/interfaces/all
    echo "--- login (/api/auth/login) ---"
    token=$(curl -sk --max-time 5 -X POST \
        -H 'Content-Type: application/json' \
        -d '{"username":"root","password":"root"}' \
        https://127.0.0.1:6443/api/auth/login)
    echo "$token" | head -c 300
    echo
    tk=$(printf '%s' "$token" | grep -o 'eyJ[A-Za-z0-9._-]*' | head -n 1)
    echo "token_len=${#tk}"
    echo "--- authenticated service status ---"
    for path in services/ip/status services/wan/status services/route_wans/status interfaces/all; do
        echo "## /api/v1/${path}"
        curl -sk --max-time 5 -H "Authorization: Bearer $tk" \
            "https://127.0.0.1:6443/api/v1/${path}" | head -c 800
        echo
    done
    echo "--- home dir ---"
    ls -la /root/.landscape-router/
    echo "--- webserver file logs ---"
    find /root/.landscape-router/logs -type f 2>/dev/null | while read -r f; do
        echo "== $f"; tail -n 25 "$f"
    done
    echo "--- ip addr ---"
    ip addr
    echo "--- landscape-router journal tail ---"
    journalctl -u landscape-router -n 40 --no-pager | tail -n 20
} > /dev/console
exit 0
