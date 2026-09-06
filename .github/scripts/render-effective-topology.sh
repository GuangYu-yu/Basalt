#!/usr/bin/env bash
# =============================================================================
# 渲染 Effective 工厂拓扑：按可选环境变量改写 configs/landscape_init.toml 副本，
# 供 EFFECTIVE_CONFIG_PATH 烘焙（custom-build 的 LAN / DHCP / Web 凭据自定义）。
# 全部变量可选：无任何提供时原样拷贝（等价仓库默认拓扑）。
# 契约：确定性 —— 相同输入恒产出相同文件（测试 job 各自重渲染，不跨 job 传文件）。
# =============================================================================
set -euo pipefail

SRC="${TOPOLOGY_SRC:?TOPOLOGY_SRC required}"
DEST="${TOPOLOGY_DEST:?TOPOLOGY_DEST required}"
LAN_GATEWAY="${LAN_GATEWAY:-}"
LAN_PREFIX="${LAN_PREFIX:-}"
DHCP_POOL_START="${DHCP_POOL_START:-}"
DHCP_POOL_END="${DHCP_POOL_END:-}"
WEB_ADMIN_USER="${WEB_ADMIN_USER:-}"
WEB_ADMIN_PASSWORD="${WEB_ADMIN_PASSWORD:-}"

ipv4_ok() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }

[[ -z "${LAN_GATEWAY}" ]] || ipv4_ok "${LAN_GATEWAY}" || { echo "ERROR: LAN_GATEWAY 非法 IPv4: ${LAN_GATEWAY}" >&2; exit 1; }
[[ -z "${DHCP_POOL_START}" ]] || ipv4_ok "${DHCP_POOL_START}" || { echo "ERROR: DHCP_POOL_START 非法 IPv4" >&2; exit 1; }
[[ -z "${DHCP_POOL_END}" ]] || ipv4_ok "${DHCP_POOL_END}" || { echo "ERROR: DHCP_POOL_END 非法 IPv4" >&2; exit 1; }
[[ -z "${LAN_PREFIX}" ]] || [[ "${LAN_PREFIX}" =~ ^([0-9]|[12][0-9]|3[0-2])$ ]] || { echo "ERROR: LAN_PREFIX 须为 0-32" >&2; exit 1; }
# Web 凭据成对提供（只给一个视为配置错误，避免产出半套凭据）
[[ -z "${WEB_ADMIN_USER}" || -n "${WEB_ADMIN_PASSWORD}" ]] || { echo "ERROR: WEB_ADMIN_PASSWORD 缺失" >&2; exit 1; }
[[ -n "${WEB_ADMIN_USER}" || -z "${WEB_ADMIN_PASSWORD}" ]] || { echo "ERROR: WEB_ADMIN_USER 缺失" >&2; exit 1; }
# DHCP 池必须落在 LAN 网段内（同前缀的粗校验，防网段与池张冠李戴）
if [[ -n "${LAN_GATEWAY}" && -n "${DHCP_POOL_START}" ]]; then
    [[ "${LAN_GATEWAY%.*}" == "${DHCP_POOL_START%.*}" && "${LAN_GATEWAY%.*}" == "${DHCP_POOL_END%.*}" ]] \
        || { echo "ERROR: DHCP 池与 LAN 网关不在同一 /24 网段" >&2; exit 1; }
fi

mkdir -p "$(dirname "${DEST}")"
cp "${SRC}" "${DEST}"

# DHCP 池与网关（toml 字段：[dhcpv4_services.config]）
[[ -z "${LAN_GATEWAY}" ]] || sed -i "s#^server_ip_addr = .*#server_ip_addr = \"${LAN_GATEWAY}\"#" "${DEST}"
[[ -z "${LAN_PREFIX}" ]] || sed -i "s#^network_mask = .*#network_mask = ${LAN_PREFIX}#" "${DEST}"
[[ -z "${DHCP_POOL_START}" ]] || sed -i "s#^ip_range_start = .*#ip_range_start = \"${DHCP_POOL_START}\"#" "${DEST}"
[[ -z "${DHCP_POOL_END}" ]] || sed -i "s#^ip_range_end = .*#ip_range_end = \"${DHCP_POOL_END}\"#" "${DEST}"

# Web 凭据（[auth] 表 → InitConfig.config.auth → 首启导入写 landscape.toml）
if [[ -n "${WEB_ADMIN_USER}" ]]; then
    cat >> "${DEST}" <<EOF

[auth]
admin_user = "${WEB_ADMIN_USER}"
admin_pass = "${WEB_ADMIN_PASSWORD}"
EOF
fi

echo "effective topology rendered: ${DEST}"