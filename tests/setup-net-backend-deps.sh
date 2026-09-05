#!/bin/bash
# =============================================================================
# setup-net-backend-deps.sh — 测试网络后端依赖层（passt 版本固定安装）
# =============================================================================
# 职责：保证宿主 passt 具备 --map-host-tcp（bootstrap 3222→22 异端口映射的
# 硬依赖）。单一事实来源：版本 + SHA256 双锁定于本文件，不再散落 CI YAML。
#
# 为什么需要 pin：hosted runner 最高 ubuntu-24.04（apt passt = 2024.02，无
# --map-host-tcp）；无更高 runner 镜像可升级。最新 passt（2026.07+）已移除
# 静态端口转发选项（pesto 化改造），也不能用——本脚本固定二者之间的
# Debian trixie 2025.05 版。
#
# 幂等：已具备能力时跳过；校验失败即失败（不静默换源）。
# =============================================================================
set -euo pipefail

PASST_DEB="passt_0.0~git20250503.587980c-2+deb13u1_amd64.deb"
PASST_URL="http://deb.debian.org/debian/pool/main/p/passt/${PASST_DEB}"
PASST_SHA256="dfbca023b20c84a3345e36bbbe182c18bf262583d31386fc7e3050a708850f0d"

if command -v passt >/dev/null 2>&1 && passt --help 2>&1 | grep -q -- '--map-host-tcp'; then
    echo "[OK] passt 已具备 --map-host-tcp，跳过安装"
    passt --version 2>&1 | head -n1
    exit 0
fi

echo "[INFO] 下载固定版本 passt：${PASST_DEB}"
curl -fsSL --max-time 120 "${PASST_URL}" -o "/tmp/${PASST_DEB}"
echo "${PASST_SHA256}  /tmp/${PASST_DEB}" | sha256sum -c -

echo "[INFO] 安装"
sudo apt-get install -y "/tmp/${PASST_DEB}"

passt --version 2>&1 | head -n1
if ! passt --help 2>&1 | grep -q -- '--map-host-tcp'; then
    echo "[ERROR] 升级后仍无 --map-host-tcp（网络后端 passt 不可用）" >&2
    exit 1
fi
echo "[OK] passt 就绪（$(passt --version 2>&1 | head -n1)）"
