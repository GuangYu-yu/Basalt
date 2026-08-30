#!/bin/bash

if [[ -n "${LANDSCAPE_TEST_LOCAL_RUNTIME_SOURCED:-}" ]]; then
    return 0
fi
LANDSCAPE_TEST_LOCAL_RUNTIME_SOURCED=1

# 端口默认值常量由 tests/common.sh 顶部提供（LANDSCAPE_DEFAULT_*_PORT）
LANDSCAPE_DEFAULT_MCAST_ADDR="230.0.0.1"
LANDSCAPE_DEFAULT_ROUTER_WAN_MAC="52:54:00:12:34:01"
LANDSCAPE_DEFAULT_ROUTER_LAN_MAC="52:54:00:12:34:02"
LANDSCAPE_DEFAULT_ROUTER_MGMT_MAC="52:54:00:12:34:03"
LANDSCAPE_DEFAULT_CLIENT_MAC="52:54:00:12:34:10"

if [[ -z "${SSH_PORT+x}" ]]; then
    SSH_PORT="${LANDSCAPE_DEFAULT_SSH_PORT}"
fi
if [[ -z "${WEB_PORT+x}" ]]; then
    WEB_PORT="${LANDSCAPE_DEFAULT_WEB_PORT}"
fi
if [[ -z "${LANDSCAPE_CONTROL_PORT+x}" ]]; then
    LANDSCAPE_CONTROL_PORT="${LANDSCAPE_DEFAULT_CONTROL_PORT}"
fi
if [[ -z "${MCAST_PORT+x}" ]]; then
    MCAST_PORT="${LANDSCAPE_DEFAULT_MCAST_PORT}"
fi
if [[ -z "${MCAST_ADDR+x}" ]]; then
    MCAST_ADDR="${LANDSCAPE_DEFAULT_MCAST_ADDR}"
fi
if [[ -z "${ROUTER_WAN_MAC+x}" ]]; then
    ROUTER_WAN_MAC="${LANDSCAPE_DEFAULT_ROUTER_WAN_MAC}"
fi
if [[ -z "${ROUTER_LAN_MAC+x}" ]]; then
    ROUTER_LAN_MAC="${LANDSCAPE_DEFAULT_ROUTER_LAN_MAC}"
fi
if [[ -z "${ROUTER_MGMT_MAC+x}" ]]; then
    ROUTER_MGMT_MAC="${LANDSCAPE_DEFAULT_ROUTER_MGMT_MAC}"
fi
if [[ -z "${CLIENT_MAC+x}" ]]; then
    CLIENT_MAC="${LANDSCAPE_DEFAULT_CLIENT_MAC}"
fi
if [[ -z "${CIRROS_CACHE_DIR+x}" ]]; then
    CIRROS_CACHE_DIR="${WORK_DIR}/downloads/cirros"
fi

export SSH_PORT WEB_PORT LANDSCAPE_CONTROL_PORT MCAST_PORT MCAST_ADDR
export ROUTER_WAN_MAC ROUTER_LAN_MAC ROUTER_MGMT_MAC CLIENT_MAC CIRROS_CACHE_DIR

landscape_port_in_use() {
    local port="$1"
    ss -tlnH 2>/dev/null | awk '{print $4}' | grep -Eq "(^|[.:])${port}$"
}

landscape_dir_is_writable() {
    local target_dir="$1"
    local parent_dir=""

    if [[ -d "$target_dir" ]]; then
        [[ -w "$target_dir" ]]
        return
    fi

    parent_dir="$(dirname "$target_dir")"
    while [[ "$parent_dir" != "/" && ! -d "$parent_dir" ]]; do
        parent_dir="$(dirname "$parent_dir")"
    done

    [[ -d "$parent_dir" && -w "$parent_dir" ]]
}

landscape_assign_auto_mac_addresses() {
    local alloc_id="$1"
    local value=""

    value=$((alloc_id & 255))
    printf -v ROUTER_WAN_MAC '52:54:00:12:34:%02x' "$value"
    printf -v ROUTER_LAN_MAC '52:54:00:12:35:%02x' "$value"
    printf -v CLIENT_MAC '52:54:00:12:36:%02x' "$value"
}

landscape_next_allocation_id() {
    local require_mcast="$1"
    local lock_fd=""
    local lock_file="${LANDSCAPE_TEST_RESOURCE_LOCK}"
    local counter_file="${lock_file}.counter"
    local next_id=1
    local ssh_port=0
    local web_port=0
    local mcast_port=0

    mkdir -p "${LANDSCAPE_TEST_TMP_ROOT}"
    : > "$lock_file"
    exec {lock_fd}<>"$lock_file"
    flock "$lock_fd"

    if [[ -f "$counter_file" ]]; then
        next_id="$(cat "$counter_file")"
        if [[ ! "$next_id" =~ ^[0-9]+$ ]] || [[ "$next_id" -lt 1 ]]; then
            next_id=1
        fi
    fi

    while :; do
        ssh_port=$((LANDSCAPE_DEFAULT_SSH_PORT + next_id - 1))
        web_port=$((LANDSCAPE_DEFAULT_WEB_PORT + next_id - 1))
        mcast_port=$((LANDSCAPE_DEFAULT_MCAST_PORT + next_id - 1))

        if landscape_port_in_use "$ssh_port" || landscape_port_in_use "$web_port"; then
            next_id=$((next_id + 1))
            continue
        fi
        if [[ "$require_mcast" == "1" ]] && landscape_port_in_use "$mcast_port"; then
            next_id=$((next_id + 1))
            continue
        fi
        break
    done

    printf '%s\n' "$((next_id + 1))" > "$counter_file"
    flock -u "$lock_fd"
    eval "exec ${lock_fd}>&-"
    printf '%s\n' "$next_id"
}

landscape_prepare_test_environment() {
    local need_auto=0
    local require_mcast=0
    local allocate_default_ports=0
    local allocate_default_mcast=0
    local alloc_id=0

    if [[ "${LANDSCAPE_TEST_AUTO_ALLOCATE}" != "1" ]]; then
        return 0
    fi

    if [[ "${LANDSCAPE_TEST_NAME:-}" == "dataplane" ]]; then
        require_mcast=1
    fi

    if [[ "$SSH_PORT" == "$LANDSCAPE_DEFAULT_SSH_PORT" && "$WEB_PORT" == "$LANDSCAPE_DEFAULT_WEB_PORT" ]]; then
        need_auto=1
        allocate_default_ports=1
    fi
    if [[ "$require_mcast" == "1" && "$MCAST_PORT" == "$LANDSCAPE_DEFAULT_MCAST_PORT" ]]; then
        need_auto=1
        allocate_default_mcast=1
    fi
    if ! landscape_dir_is_writable "${LANDSCAPE_TEST_LOG_DIR}"; then
        need_auto=1
        LANDSCAPE_TEST_OWN_LOG_DIR=1
    fi
    if [[ "$require_mcast" == "1" ]]; then
        if ! landscape_dir_is_writable "${CIRROS_CACHE_DIR}"; then
            need_auto=1
        fi
    fi

    if [[ "$need_auto" -ne 1 ]]; then
        export OUTPUT_DIR WORK_DIR LANDSCAPE_TEST_LOG_DIR LANDSCAPE_TEST_ALLOCATED_ID
        export SSH_PORT WEB_PORT LANDSCAPE_CONTROL_PORT MCAST_PORT MCAST_ADDR
        export ROUTER_WAN_MAC ROUTER_LAN_MAC ROUTER_MGMT_MAC CLIENT_MAC CIRROS_CACHE_DIR
        return 0
    fi

    alloc_id="$(landscape_next_allocation_id "$require_mcast")"
    LANDSCAPE_TEST_ALLOCATED_ID="$alloc_id"

    if [[ "$allocate_default_ports" == "1" ]]; then
        SSH_PORT=$((LANDSCAPE_DEFAULT_SSH_PORT + alloc_id - 1))
        WEB_PORT=$((LANDSCAPE_DEFAULT_WEB_PORT + alloc_id - 1))
    fi
    if [[ "$allocate_default_mcast" == "1" ]]; then
        MCAST_PORT=$((LANDSCAPE_DEFAULT_MCAST_PORT + alloc_id - 1))
    fi

    if [[ "$ROUTER_WAN_MAC" == "$LANDSCAPE_DEFAULT_ROUTER_WAN_MAC" && "$ROUTER_LAN_MAC" == "$LANDSCAPE_DEFAULT_ROUTER_LAN_MAC" && "$CLIENT_MAC" == "$LANDSCAPE_DEFAULT_CLIENT_MAC" ]]; then
        landscape_assign_auto_mac_addresses "$alloc_id"
    fi

    if [[ "$LANDSCAPE_TEST_OWN_LOG_DIR" -eq 1 ]]; then
        LANDSCAPE_TEST_TMP_LOG_DIR="$(mktemp -d "${LANDSCAPE_TEST_TMP_ROOT}/landscape-test-${LANDSCAPE_TEST_NAME:-test}-${alloc_id}-XXXXXX")"
        LANDSCAPE_TEST_LOG_DIR="${LANDSCAPE_TEST_TMP_LOG_DIR}"
    fi

    if [[ "$require_mcast" == "1" ]]; then
        if ! landscape_dir_is_writable "${CIRROS_CACHE_DIR}"; then
            LANDSCAPE_TEST_TMP_WORK_DIR="$(mktemp -d "${LANDSCAPE_TEST_TMP_ROOT}/landscape-work-${LANDSCAPE_TEST_NAME:-test}-${alloc_id}-XXXXXX")"
            WORK_DIR="${LANDSCAPE_TEST_TMP_WORK_DIR}"
            CIRROS_CACHE_DIR="${WORK_DIR}/downloads/cirros"
        fi
    fi

    export OUTPUT_DIR WORK_DIR LANDSCAPE_TEST_LOG_DIR LANDSCAPE_TEST_ALLOCATED_ID
    export SSH_PORT WEB_PORT LANDSCAPE_CONTROL_PORT MCAST_PORT MCAST_ADDR
    export ROUTER_WAN_MAC ROUTER_LAN_MAC ROUTER_MGMT_MAC CLIENT_MAC CIRROS_CACHE_DIR

    if [[ "$require_mcast" == "1" ]]; then
        info "Auto-allocated local test resources: SSH=${SSH_PORT}, Web=${WEB_PORT}, Mcast=${MCAST_PORT}"
    else
        info "Auto-allocated local test resources: SSH=${SSH_PORT}, Web=${WEB_PORT}"
    fi
    if [[ -n "${LANDSCAPE_TEST_TMP_LOG_DIR:-}" ]]; then
        info "Using temporary writable test logs: ${LANDSCAPE_TEST_TMP_LOG_DIR}"
    fi
    if [[ -n "${LANDSCAPE_TEST_TMP_WORK_DIR:-}" ]]; then
        info "Using temporary writable work dir: ${LANDSCAPE_TEST_TMP_WORK_DIR}"
    fi
}