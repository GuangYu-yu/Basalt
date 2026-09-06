#!/usr/bin/env bash
# =============================================================================
# 渲染 Effective 工厂拓扑：按 LAN CIDR 改写 configs/landscape_init.toml 副本，
# 供 EFFECTIVE_CONFIG_PATH 烘焙（custom-build 的 LAN / Web 凭据自定义）。
# 推导惯例（与仓库默认拓扑同构）：网关 = 首个可用主机地址，DHCP 池 = 其余
# 主机位（network+2 .. broadcast-1）。如默认 192.168.10.0/24 → 网关 .1、池 .2~.254。
# 可选变量：LAN_CIDR / WEB_ADMIN_USER+WEB_ADMIN_PASSWORD（成对）。全空 = 原样拷贝。
# 契约：确定性 —— 相同输入恒产出相同文件（测试 job 各自重渲染，不跨 job 传文件）。
# =============================================================================
set -euo pipefail

SRC="${TOPOLOGY_SRC:?TOPOLOGY_SRC required}"
DEST="${TOPOLOGY_DEST:?TOPOLOGY_DEST required}"
LAN_CIDR="${LAN_CIDR:-}"
WEB_ADMIN_USER="${WEB_ADMIN_USER:-}"
WEB_ADMIN_PASSWORD="${WEB_ADMIN_PASSWORD:-}"

[[ -z "${WEB_ADMIN_USER}" || -n "${WEB_ADMIN_PASSWORD}" ]] || { echo "ERROR: WEB_ADMIN_PASSWORD 缺失" >&2; exit 1; }
[[ -n "${WEB_ADMIN_USER}" || -z "${WEB_ADMIN_PASSWORD}" ]] || { echo "ERROR: WEB_ADMIN_USER 缺失" >&2; exit 1; }

if [[ -n "${LAN_CIDR}" ]]; then
    # CIDR 解析与主机位推导交由 python3 ipaddress（CI 宿主必备，build.sh 同依赖）
    derivation="$(python3 - "$LAN_CIDR" <<'PY'
import ipaddress, sys
try:
    net = ipaddress.ip_network(sys.argv[1], strict=False)
except ValueError as e:
    sys.exit(f"ERROR: 非法 CIDR {sys.argv[1]}: {e}")
hosts = list(net.hosts())
if len(hosts) < 3:
    sys.exit(f"ERROR: {sys.argv[1]} 可用主机不足（需 ≥3：网关 + DHCP 池起止）")
print(net.with_prefixlen, hosts[0], hosts[1], hosts[-1])
PY
)" || exit 1
    read -r NETWORK LAN_GATEWAY DHCP_POOL_START DHCP_POOL_END <<< "${derivation}"
    LAN_PREFIX="${NETWORK##*/}"
    echo "LAN ${NETWORK}: 网关 ${LAN_GATEWAY}, DHCP 池 ${DHCP_POOL_START} ~ ${DHCP_POOL_END}"
fi

mkdir -p "$(dirname "${DEST}")"
cp "${SRC}" "${DEST}"

# DHCP 池与网关（toml 字段：[dhcpv4_services.config]）
[[ -z "${LAN_GATEWAY}" ]] || sed -i "s#^server_ip_addr = .*#server_ip_addr = \"${LAN_GATEWAY}\"#" "${DEST}"
[[ -z "${LAN_PREFIX:-}" ]] || sed -i "s#^network_mask = .*#network_mask = ${LAN_PREFIX}#" "${DEST}"
[[ -z "${DHCP_POOL_START}" ]] || sed -i "s#^ip_range_start = .*#ip_range_start = \"${DHCP_POOL_START}\"#" "${DEST}"
[[ -z "${DHCP_POOL_END}" ]] || sed -i "s#^ip_range_end = .*#ip_range_end = \"${DHCP_POOL_END}\"#" "${DEST}"

# Web 凭据 → [config.auth] 挂在 InitConfig.config 下
if [[ -n "${WEB_ADMIN_USER}" ]]; then
    cat >> "${DEST}" <<EOF

[config.auth]
admin_user = "${WEB_ADMIN_USER}"
admin_pass = "${WEB_ADMIN_PASSWORD}"
EOF
fi

echo "effective topology rendered: ${DEST}"