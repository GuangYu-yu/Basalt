#!/bin/bash
# =============================================================================
# Basalt — 测试网络后端压力 POC（passt A/B 验证工具）
# =============================================================================
# 目的：验证测试网络后端（LANDSCAPE_TEST_NET=passt|slirp）在"guest 长时间
# 存活 + 周期性 SSH 探测 + guest→宿主 HTTP 拉取"下的稳定性。
#
# 背景：slirp 存在非确定性网络路径死亡（guest 健康、sshd 在列、hostfwd 在
# 列但新建连接不通；~4min guest uptime 起随机命中）——此前污染所有 OTA 实
# 验结果。本脚本以最小网络闭环（boot → bootstrap → SSH → guest 拉取宿主
# HTTP → 驻留期周期探测）连续 N 轮暴露该形态，作为 passt 切换的 A/B 证据。
#
# 用法：test-net-stress.sh <image_path>   （env：ITERATIONS=6 DWELL=300）
# 判定：全部轮次 bootstrap/SSH/HTTP 探测通过 → PASS；任一网络死亡 → FAIL
#（死亡轮次自动经 emergency/console 探针取证——与 OTA 测试共用取证链）
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/common.sh"
source "${SCRIPT_DIR}/local-runtime.sh"

IMAGE_PATH="${1:-${PROJECT_DIR}/output/basalt.img}"
ITERATIONS="${ITERATIONS:-6}"
DWELL="${DWELL:-300}"
SSH_PASSWORD="${SSH_PASSWORD:-landscape}"
SSH_TIMEOUT="${SSH_TIMEOUT:-180}"
LANDSCAPE_TEST_NAME="netstress"
LANDSCAPE_IMAGE_PATH="${IMAGE_PATH}"
LANDSCAPE_ROUTER_PERSIST_IMAGE=1

LANDSCAPE_HTTP_PID=""
OTA_SERVER_PORT="${OTA_SERVER_PORT:-18080}"
OTA_VM_STARTED=0

# 与 OTA 测试同一套取证（EXIT trap → ota_lib 的统一取证链）
source "${SCRIPT_DIR}/ota_lib.sh"

cleanup() {
    [[ -n "${LANDSCAPE_HTTP_PID:-}" ]] && kill "${LANDSCAPE_HTTP_PID}" 2>/dev/null || true
    landscape_router_cleanup
}
trap cleanup EXIT

# guest→宿主 HTTP 拉取探测（本地 OTA 源的 SHA256SUMS 占位文件——验证
# guest 经 WAN 网关访问宿主服务的完整路径）
probe_http() {
    guest_run "curl -fsS --max-time 10 http://$(landscape_ota_guest_host):${OTA_SERVER_PORT}/SHA256SUMS -o /dev/null && echo http-ok"
}

# 驻留期探测：DWELL 秒内每 15s 一次 SSH 探测，网络死亡即时暴露并取证
dwell_probes() {
    local t0=${SECONDS} fails=0 probes=0
    while (( SECONDS - t0 < DWELL )); do
        probes=$((probes + 1))
        if ! guest_run "echo alive" &>/dev/null; then
            fails=$((fails + 1))
            echo "[FAIL] 驻留探测失联（probe ${probes}，t=$((SECONDS - t0))s）" >&2
            ota_emergency_probe || true
            return 1
        fi
        sleep 15
    done
    echo "[OK] 驻留 ${DWELL}s：${probes} 次探测全部存活"
    return 0
}

main() {
    info "网络后端压力 POC：backend=$(landscape_net_backend) iterations=${ITERATIONS} dwell=${DWELL}s"
    [[ -f "${IMAGE_PATH}" ]] || { error "镜像不存在: ${IMAGE_PATH}"; exit 2; }

    landscape_prepare_test_environment
    source "${PROJECT_DIR}/build.env"
    landscape_router_init_paths "netstress"

    # 本地 HTTP 源（guest 经网关访问——OTA 数据路径的替身）
    local serve_dir
    serve_dir="$(mktemp -d "${LANDSCAPE_TEST_TMP_ROOT:-/tmp}/netstress-serve-XXXXXX")"
    echo "netstress-placeholder $(date -u +%s)" > "${serve_dir}/SHA256SUMS"
    python3 -m http.server "${OTA_SERVER_PORT}" --bind 0.0.0.0 \
        --directory "${serve_dir}" >/dev/null 2>&1 &
    LANDSCAPE_HTTP_PID=$!
    sleep 1

    ota_start_vm
    OTA_VM_STARTED=1

    local i fails=0
    for i in $(seq 1 "${ITERATIONS}"); do
        echo ""
        echo "======== 迭代 ${i}/${ITERATIONS} ========"
        if (( i > 1 )); then
            ota_hard_reset
        fi
        if ! ota_wait_booted; then
            echo "[FAIL] 迭代 ${i}: bootstrap/SSH 未达" >&2
            fails=$((fails + 1))
            break
        fi
        if ! probe_http; then
            echo "[FAIL] 迭代 ${i}: guest→宿主 HTTP 拉取失败" >&2
            fails=$((fails + 1))
            break
        fi
        echo "[OK] 迭代 ${i}: boot + bootstrap + SSH + HTTP 全通"
        if ! dwell_probes; then
            fails=$((fails + 1))
            break
        fi
    done

    echo ""
    if (( fails == 0 )); then
        ok "网络压力 POC 全部通过（${ITERATIONS} 迭代，backend=$(landscape_net_backend)）"
    else
        error "网络压力 POC 失败（迭代 ${i}，backend=$(landscape_net_backend)）"
        exit 1
    fi
}

main "$@"
