#!/bin/bash
# =============================================================================
# Basalt - End-to-End Dataplane Test
# =============================================================================
#
# Validates stable client-visible dataplane behavior after the router has already
# satisfied the shared readiness contract.
#
# E2E scope:
#   1. Router satisfies the readiness contract
#   2. Client VM boots on the LAN segment
#   3. Client receives DHCP on the expected LAN subnet
#   4. DHCP lease is visible in the router API
#   5. Router and client can communicate on the LAN
#
# Deliberately not used as hard gating here:
#   - public DNS lookups
#   - router-self curl to internet
#   - ARP as a substitute for ping success
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/common.sh"
source "${SCRIPT_DIR}/local-runtime.sh"

IMAGE_PATH="${1:-${PROJECT_DIR}/output/basalt.img}"
SSH_PORT="${SSH_PORT:-${LANDSCAPE_DEFAULT_SSH_PORT}}"
WEB_PORT="${WEB_PORT:-${LANDSCAPE_DEFAULT_WEB_PORT}}"
LANDSCAPE_CONTROL_PORT="${LANDSCAPE_CONTROL_PORT:-${LANDSCAPE_DEFAULT_CONTROL_PORT}}"
QEMU_MEM="${QEMU_MEM:-1024}"
QEMU_SMP="${QEMU_SMP:-2}"
SSH_PASSWORD="${SSH_PASSWORD:-landscape}"
API_USERNAME="${API_USERNAME:-root}"
API_PASSWORD="${API_PASSWORD:-root}"
SSH_TIMEOUT="${SSH_TIMEOUT:-120}"
SHUTDOWN_TIMEOUT=15
DHCP_TIMEOUT="${DHCP_TIMEOUT:-120}"
LANDSCAPE_TEST_NAME="dataplane"
LANDSCAPE_IMAGE_PATH="${IMAGE_PATH}"

CIRROS_VERSION="0.6.2"
# CirrOS 直启需要 disk(rootfs)+kernel+initramfs 三资产；校验走同 release 的
# MD5SUMS（单一事实，asset 名以 GitHub release 实测为准）
CIRROS_URL="https://github.com/cirros-dev/cirros/releases/download/${CIRROS_VERSION}/cirros-${CIRROS_VERSION}-x86_64-disk.img"
CIRROS_KERNEL_URL="https://github.com/cirros-dev/cirros/releases/download/${CIRROS_VERSION}/cirros-${CIRROS_VERSION}-x86_64-kernel"
CIRROS_INITRD_URL="https://github.com/cirros-dev/cirros/releases/download/${CIRROS_VERSION}/cirros-${CIRROS_VERSION}-x86_64-initramfs"
CIRROS_MD5SUMS_URL="https://github.com/cirros-dev/cirros/releases/download/${CIRROS_VERSION}/MD5SUMS"
CIRROS_USER="cirros"
CIRROS_PASSWORD="gocubsgo"

MCAST_ADDR="${MCAST_ADDR:-230.0.0.1}"
MCAST_PORT="${MCAST_PORT:-${LANDSCAPE_DEFAULT_MCAST_PORT}}"
ROUTER_WAN_MAC="${ROUTER_WAN_MAC:-52:54:00:12:34:01}"
ROUTER_LAN_MAC="${ROUTER_LAN_MAC:-52:54:00:12:34:02}"
ROUTER_MGMT_MAC="${ROUTER_MGMT_MAC:-52:54:00:12:34:03}"
CLIENT_MAC="${CLIENT_MAC:-52:54:00:12:34:10}"

CLIENT_SERIAL_LOG=""
CLIENT_PID=""
CLIENT_PIDFILE=""
CLIENT_MONITOR=""
TEMP_CIRROS=""
CLIENT_DIAGNOSTICS_FILE=""
CLIENT_RESULTS_FILE=""

cleanup() {
    local exit_code=$?
    set +e

    if [[ -n "${CLIENT_PID}" ]] && kill -0 "${CLIENT_PID}" 2>/dev/null; then
        info "Stopping client VM (PID ${CLIENT_PID})..."
        if [[ -n "${CLIENT_MONITOR}" ]] && [[ -S "${CLIENT_MONITOR}" ]]; then
            echo "quit" | socat -T2 STDIN UNIX-CONNECT:"${CLIENT_MONITOR}" &>/dev/null || true
            sleep 2
        fi
        if kill -0 "${CLIENT_PID}" 2>/dev/null; then
            kill -9 "${CLIENT_PID}" 2>/dev/null || true
            wait "${CLIENT_PID}" 2>/dev/null || true
        fi
    fi

    [[ -n "${TEMP_CIRROS}" ]] && rm -f "${TEMP_CIRROS}"
    [[ -n "${CLIENT_PIDFILE}" ]] && rm -f "${CLIENT_PIDFILE}"
    [[ -n "${CLIENT_MONITOR}" ]] && rm -f "${CLIENT_MONITOR}"

    landscape_router_cleanup
    exit $exit_code
}

trap cleanup EXIT
# TERM 先落盘诊断再退出（CI 硬超时路径的证据保障），EXIT trap 负责清理
trap landscape_dump_diagnostics_on_term TERM
trap 'exit 130' INT

preflight() {
    landscape_prepare_test_environment
    info "Preflight checks..."

    ensure_image_exists "${IMAGE_PATH}" || {
        error "Run 'make build' first."
        exit 2
    }

    if ! require_commands qemu-system-x86_64 qemu-img sshpass curl socat jq awk md5sum; then
        error "Run 'make deps-test' to install test dependencies."
        exit 2
    fi

    if ! ensure_local_ports_free "${SSH_PORT}" "${WEB_PORT}" "$(landscape_bootstrap_ssh_port)"; then
        exit 2
    fi

    load_landscape_topology || exit 2
    landscape_router_init_paths "dataplane"

    local artifact_suffix=""

    artifact_suffix="$(landscape_test_artifact_suffix)"
    CLIENT_SERIAL_LOG="${LANDSCAPE_TEST_LOG_DIR}/dataplane${artifact_suffix}-serial-client.log"
    CLIENT_DIAGNOSTICS_FILE="${LANDSCAPE_TEST_LOG_DIR}/dataplane${artifact_suffix}-client-diagnostics.txt"
    CLIENT_RESULTS_FILE="${LANDSCAPE_RESULTS_FILE}"
    rm -f "${CLIENT_SERIAL_LOG}" "${CLIENT_DIAGNOSTICS_FILE}"

    landscape_load_test_identity "${IMAGE_PATH}" || true
    LANDSCAPE_TEST_LANDSCAPE_VERSION="${LANDSCAPE_TEST_LANDSCAPE_VERSION:-$(resolve_default_landscape_version)}"
    landscape_write_test_metadata "${IMAGE_PATH}"

    ROUTER_WAN_DEVICE_OPTS="${ROUTER_WAN_DEVICE_OPTS:-,mac=${ROUTER_WAN_MAC}}"
    ROUTER_LAN_DEVICE_OPTS="${ROUTER_LAN_DEVICE_OPTS:-,mac=${ROUTER_LAN_MAC}}"
    ROUTER_MGMT_DEVICE_OPTS="${ROUTER_MGMT_DEVICE_OPTS:-,mac=${ROUTER_MGMT_MAC}}"
    # hostfwd 全部走 common.sh 的 MGMT 口（eth2）；LAN 段只承载数据面，
    # client 与 router eth1 同挂 mcast 组
    ROUTER_LAN_NETDEV="${ROUTER_LAN_NETDEV:-socket,id=lan,mcast=${MCAST_ADDR}:${MCAST_PORT}}"

    ok "Preflight passed"
}

download_cirros() {
    local download_dir="${CIRROS_CACHE_DIR}/${CIRROS_VERSION}"
    local cirros_file="${download_dir}/cirros-${CIRROS_VERSION}-x86_64-disk.img"
    local kernel_file="${download_dir}/cirros-${CIRROS_VERSION}-x86_64-kernel"
    local initrd_file="${download_dir}/cirros-${CIRROS_VERSION}-x86_64-initramfs"
    local sums_file="${download_dir}/MD5SUMS"
    local base sum actual

    mkdir -p "${download_dir}"

    fetch_if_missing() {
        local file="$1" url="$2"
        if [[ ! -f "${file}" ]]; then
            info "Downloading $(basename "${file}") ..." >&2
            curl -fL --retry 3 --retry-delay 5 -o "${file}" "${url}" >&2 || return 1
        else
            info "$(basename "${file}") already cached" >&2
        fi
    }

    fetch_if_missing "${sums_file}" "${CIRROS_MD5SUMS_URL}" || return 1
    fetch_if_missing "${cirros_file}" "${CIRROS_URL}" || return 1
    fetch_if_missing "${kernel_file}" "${CIRROS_KERNEL_URL}" || return 1
    fetch_if_missing "${initrd_file}" "${CIRROS_INITRD_URL}" || return 1

    # MD5SUMS 逐文件核对（disk/kernel/initramfs 均为 HTTPS 下载，校验闭环）
    for file in "${cirros_file}" "${kernel_file}" "${initrd_file}"; do
        base="$(basename "${file}")"
        sum="$(awk -v b="${base}" '$2==b || $3==b {print $1; exit}' "${sums_file}")"
        [[ -n "${sum}" ]] || { error "MD5SUMS 中未找到 ${base}" >&2; return 1; }
        actual="$(md5sum "${file}" | awk '{print $1}')"
        if [[ "${actual}" != "${sum}" ]]; then
            error "Checksum mismatch for ${base}: expected ${sum}, got ${actual}" >&2
            return 1
        fi
    done

    CIRROS_KERNEL_FILE="${kernel_file}"
    CIRROS_INITRD_FILE="${initrd_file}"
    export CIRROS_KERNEL_FILE CIRROS_INITRD_FILE

    ok "CirrOS ready (disk/kernel/initramfs)" >&2
    echo "${cirros_file}"
}

start_client() {
    local cirros_file="$1"

    info "Preparing client disk image..."

    TEMP_CIRROS=$(mktemp "${LANDSCAPE_TEST_LOG_DIR}/dataplane-client-XXXXXX.qcow2")
    rm -f "${TEMP_CIRROS}"
    qemu-img create -f qcow2 -b "${cirros_file}" -F qcow2 "${TEMP_CIRROS}" >/dev/null

    CLIENT_PIDFILE=$(mktemp "${LANDSCAPE_TEST_LOG_DIR}/dataplane-client-pid-XXXXXX")
    CLIENT_MONITOR=$(mktemp -u "${LANDSCAPE_TEST_LOG_DIR}/dataplane-client-monitor-XXXXXX.sock")

    local kvm_args=()
    read -r -a kvm_args <<< "$(detect_kvm)"

    info "Starting client VM (CirrOS)..."
    # CirrOS 直启：-kernel/-initrd 经 cmdline 注入 ds=nocloud（SMBIOS 路径对
    # 0.6.2 精简实现无效，实证见 serial "datasource: None None"）；disk.img 仅
    # 作 rootfs（root=LABEL=cirros-rootfs），metadata 探测（169.254.169.254）
    # 被 NoCloud 短路，免去 44s 阻塞
    qemu-system-x86_64 \
        "${kvm_args[@]}" \
        -m 256 \
        -smp 1 \
        -kernel "${CIRROS_KERNEL_FILE}" \
        -initrd "${CIRROS_INITRD_FILE}" \
        -append "root=LABEL=cirros-rootfs console=ttyS0 ds=nocloud" \
        -drive "file=${TEMP_CIRROS},format=qcow2,if=virtio" \
        -device "virtio-net-pci,netdev=net0,mac=${CLIENT_MAC}" \
        -netdev "socket,id=net0,mcast=${MCAST_ADDR}:${MCAST_PORT}" \
        -display none \
        -serial "file:${CLIENT_SERIAL_LOG}" \
        -monitor "unix:${CLIENT_MONITOR},server,nowait" \
        -pidfile "${CLIENT_PIDFILE}" \
        -daemonize

    if CLIENT_PID=$(wait_for_pidfile "${CLIENT_PIDFILE}" "Client VM" 10); then
        if kill -0 "${CLIENT_PID}" 2>/dev/null; then
            ok "Client VM started (PID ${CLIENT_PID})"
            return 0
        fi
    fi

    error "Client VM exited immediately"
    dump_log_tail "${CLIENT_SERIAL_LOG}" "client serial log"
    return 1
}

write_client_diagnostics() {
    local client_ip="${1:-}"
    {
        echo "timestamp_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "client_ip=${client_ip}"
        echo "client_mac=${CLIENT_MAC}"
        echo "router_lan_iface=${LANDSCAPE_EXPECTED_LAN_IFACE}"
        echo "router_lan_gateway=${LANDSCAPE_EXPECTED_LAN_GATEWAY}"
        echo ""
        echo "== client serial log tail =="
        tail -n 100 "${CLIENT_SERIAL_LOG}" 2>/dev/null || true
        echo ""
        echo "== router arp/neigh =="
        guest_run "ip neigh show" 2>&1 || true
        echo ""
        echo "== router ping route =="
        guest_run "ip route get ${client_ip}" 2>&1 || true
        echo ""
        echo "== router dhcp assigned_ips =="
        landscape_api_dhcp_assigned "${LANDSCAPE_ROUTER_API_TOKEN}" 2>&1 || true
    } > "${CLIENT_DIAGNOSTICS_FILE}"
}

wait_for_dhcp_assignment() {
    local token="$1"
    local elapsed=0
    local client_ip=""

    info "Waiting for client DHCP assignment (timeout: ${DHCP_TIMEOUT}s)..." >&2

    while [[ $elapsed -lt $DHCP_TIMEOUT ]]; do
        if ! kill -0 "${CLIENT_PID}" 2>/dev/null; then
            error "Client VM died while waiting for DHCP" >&2
            dump_log_tail "${CLIENT_SERIAL_LOG}" "client serial log" >&2
            write_client_diagnostics
            return 1
        fi

        client_ip="$(landscape_api_dhcp_assigned_ip "$token" "$LANDSCAPE_EXPECTED_LAN_SUBNET_PREFIX" 2>/dev/null || true)"
        if [[ -n "$client_ip" ]]; then
            ok "Client received DHCP: ${client_ip} (after ${elapsed}s)" >&2
            echo "$client_ip"
            return 0
        fi

        sleep 5
        ((elapsed += 5))
        if ((elapsed % 15 == 0)); then
            info "  ...still waiting for DHCP (${elapsed}s)" >&2
        fi
    done

    error "DHCP assignment timeout after ${DHCP_TIMEOUT}s" >&2
    dump_log_tail "${CLIENT_SERIAL_LOG}" "client serial log" >&2
    write_client_diagnostics
    return 1
}

router_can_ping_client() {
    local client_ip="$1"
    local attempt

    for attempt in 1 2 3 4 5 6; do
        if guest_run "ping -c 2 -W 3 ${client_ip}" &>/dev/null; then
            return 0
        fi
        sleep 3
    done

    return 1
}

run_e2e_checks() {
    local token="$1"
    local client_ip="$2"
    local assigned_ip=""

    reset_test_counters
    set +e

    echo "============================================================"
    echo "Basalt — End-to-End Dataplane Tests"
    echo "============================================================"
    echo ""

    echo "---- DHCP ----"
    run_check "Client received DHCP IP (${client_ip})" test -n "$client_ip"

    assigned_ip="$(landscape_api_dhcp_assigned_ip "$token" "$LANDSCAPE_EXPECTED_LAN_SUBNET_PREFIX" 2>/dev/null || true)"
    run_check "DHCP lease visible in router API" test "$assigned_ip" = "$client_ip"

    echo ""
    echo "---- LAN Connectivity ----"
    run_check "Router can ping client (${client_ip})" router_can_ping_client "$client_ip"

    write_client_diagnostics "$client_ip"
    landscape_router_dump_diagnostics "$token"

    echo ""
    echo "============================================================"
    echo "Results: ${PASS_COUNT} passed, ${FAIL_COUNT} failed, ${SKIP_COUNT} skipped"
    echo "============================================================"

    set -e
    return $FAIL_COUNT
}

main() {
    echo ""
    echo "============================================================"
    echo "  Basalt — End-to-End Dataplane Test"
    echo "============================================================"
    echo ""
    info "Image: ${IMAGE_PATH}"
    echo ""

    preflight

    local cirros_file
    cirros_file="$(download_cirros)" || exit 2

    if ! landscape_router_start_vm "${IMAGE_PATH}"; then
        exit 2
    fi

    if ! landscape_router_bootstrap_mgmt "Router"; then
        exit 2
    fi

    setup_ssh

    if ! landscape_router_wait_ready "Router" "${SSH_TIMEOUT}"; then
        error "Router failed readiness contract; cannot run E2E"
        info "Router serial log:       ${LANDSCAPE_ROUTER_SERIAL_LOG}"
        info "Readiness snapshot:     ${LANDSCAPE_READINESS_SNAPSHOT_FILE}"
        info "Service snapshot:       ${LANDSCAPE_SERVICE_SNAPSHOT_FILE}"
        info "Diagnostics snapshot:   ${LANDSCAPE_ROUTER_DIAGNOSTICS_FILE}"
        info "Metadata snapshot:      ${LANDSCAPE_TEST_METADATA_FILE}"
        exit 1
    fi

    start_client "${cirros_file}" || exit 2

    local client_ip
    client_ip="$(wait_for_dhcp_assignment "${LANDSCAPE_ROUTER_API_TOKEN}")" || {
        error "Client did not receive DHCP; cannot complete E2E"
        info "Client serial log:      ${CLIENT_SERIAL_LOG}"
        info "Client diagnostics:     ${CLIENT_DIAGNOSTICS_FILE}"
        exit 1
    }

    echo ""
    run_e2e_checks "${LANDSCAPE_ROUTER_API_TOKEN}" "$client_ip" 2>&1 | tee "${CLIENT_RESULTS_FILE}"
    local rc=${PIPESTATUS[0]}

    echo ""
    if [[ $rc -eq 0 ]]; then
        ok "End-to-end dataplane checks passed"
    else
        error "${rc} end-to-end dataplane check(s) failed"
        rc=1
    fi
    info "Router serial log:       ${LANDSCAPE_ROUTER_SERIAL_LOG}"
    info "Client serial log:       ${CLIENT_SERIAL_LOG}"
    info "Results:                 ${CLIENT_RESULTS_FILE}"
    info "Readiness snapshot:      ${LANDSCAPE_READINESS_SNAPSHOT_FILE}"
    info "Service snapshot:        ${LANDSCAPE_SERVICE_SNAPSHOT_FILE}"
    info "Router diagnostics:      ${LANDSCAPE_ROUTER_DIAGNOSTICS_FILE}"
    info "Client diagnostics:      ${CLIENT_DIAGNOSTICS_FILE}"
    info "Metadata snapshot:       ${LANDSCAPE_TEST_METADATA_FILE}"
    echo ""

    exit $rc
}

main