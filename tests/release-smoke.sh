#!/bin/bash
# =============================================================================
# release-smoke.sh — 发布后真实 URL 契约验证（单 boot，轻量）
#
# 验证：构建期渲染的设备侧 transfer（Source = GitHub Releases
# latest/download）经 guest 内 systemd-sysupdate list 实际枚举出刚发布的
# 版本——覆盖"枚举 → GET Path/SHA256SUMS → @v 解析 → AVAILABLE"全语义链
# （HTTP 200 不够；SHA256SUMS 的 URL 本身也是 latest/download 资产端点）。
#
# 用法: ./tests/release-smoke.sh <image-path> <expected-image-version>
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/common.sh"
source "${SCRIPT_DIR}/local-runtime.sh"

IMAGE_PATH="${1:?用法: release-smoke.sh <image-path> <expected-version>}"
EXPECTED_VERSION="${2:?缺少 expected-image-version}"
QEMU_MEM="${QEMU_MEM:-1024}"
QEMU_SMP="${QEMU_SMP:-2}"
SSH_PASSWORD="${SSH_PASSWORD:-landscape}"
SSH_TIMEOUT="${SSH_TIMEOUT:-180}"
SHUTDOWN_TIMEOUT="${SHUTDOWN_TIMEOUT:-15}"
LANDSCAPE_TEST_NAME="release-smoke"
LANDSCAPE_IMAGE_PATH="${IMAGE_PATH}"
LANDSCAPE_ROUTER_PERSIST_IMAGE=0

cleanup() {
    landscape_router_cleanup
}
trap cleanup EXIT

landscape_prepare_test_environment
info "Preflight checks..."
ensure_image_exists "${IMAGE_PATH}" || { error "镜像不存在: ${IMAGE_PATH}"; exit 2; }
require_commands qemu-system-x86_64 sshpass socat jq || {
    error "Install test dependencies: sudo apt install qemu-system-x86 ovmf sshpass socat jq"; exit 2;
}
if ! ensure_local_ports_free "${SSH_PORT}" "$(landscape_bootstrap_ssh_port)" "${WEB_PORT:-9800}"; then
    exit 2
fi
source "${PROJECT_DIR}/build.env"   # IMAGE_ID
load_landscape_topology || exit 2
landscape_router_init_paths "release-smoke"
landscape_load_test_identity "${IMAGE_PATH}" || true
ok "Preflight passed"

landscape_router_start_vm "${IMAGE_PATH}"
landscape_router_bootstrap_mgmt "Router"
setup_ssh
wait_for_guest_ssh "${LANDSCAPE_ROUTER_PID}" "${LANDSCAPE_ROUTER_SERIAL_LOG}" "Router" "${SSH_TIMEOUT}"

# 真实语义链：guest 内 sysupdate 以设备侧定义（/usr/lib/sysupdate.d，构建期
# 渲染为 GitHub URL）枚举 AVAILABLE 集合；刚发布的版本不在设备上 → 出现在
# list 中即证明"GitHub 枚举 + @v 解析"整条链工作
echo "== systemd-sysupdate list（设备视角，Source = GitHub Releases）=="
list="$(guest_run "/usr/lib/systemd/systemd-sysupdate list --no-pager")"
echo "${list}"

if grep -q "${IMAGE_ID}_${EXPECTED_VERSION}\.erofs" <<<"${list}"; then
    ok "GitHub 发布源契约验证通过：AVAILABLE 含 ${IMAGE_ID}_${EXPECTED_VERSION}"
else
    error "AVAILABLE 未包含 ${IMAGE_ID}_${EXPECTED_VERSION}（GitHub 枚举/解析失败）"
    exit 1
fi
