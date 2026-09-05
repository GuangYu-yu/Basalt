#!/bin/bash
# =============================================================================
# install.sh — 项目测试依赖层：passt（固定 commit 源码构建）
# =============================================================================
# 决策边界：本脚本只写 tests/tools/passt/bin/（项目本地），不安装进系统，
# 不改动任何产品镜像内容。
#
# 流程：本机 passt 已具备 --map-host-tcp → 直接使用；
#       否则下载 version 锁定的 commit 源码包 → sha256 校验 → 源码构建 →
#       安装到 tests/tools/passt/bin/。
# 消费方：tests/common.sh 的 landscape_passt_bin()（优先项目本地二进制）。
# =============================================================================
set -euo pipefail

TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMIT="$(cat "${TOOL_DIR}/version")"
EXPECTED_SHA256="$(cat "${TOOL_DIR}/sha256")"
BIN="${TOOL_DIR}/bin/passt"

capability() { "$1" --help 2>&1 | grep -q -- '--map-host-tcp'; }

# commit 选择依据：--map-host-tcp 于 2024.05 引入、2026 版移除（pesto 化），
# 587980c = Debian trixie 2025.05 版（二者之间，含该选项；与 Debian pool
# 的 passt_0.0~git20250503.587980c 同源）

if [[ -x "${BIN}" ]] && capability "${BIN}"; then
    echo "[OK] 项目本地 passt 已就绪：${BIN}"
    exit 0
fi

if command -v passt >/dev/null 2>&1 && capability "$(command -v passt)"; then
    echo "[OK] 系统 passt 已具备 --map-host-tcp，使用系统版本"
    exit 0
fi

echo "[INFO] 构建 passt @ ${COMMIT}（源码构建，项目本地安装）"
src="${TOOL_DIR}/src"
rm -rf "${src}"
mkdir -p "${src}"
curl -fsSL --max-time 120 "https://passt.top/passt/snapshot/passt-${COMMIT}.tar.xz" \
    -o "${src}/passt.tar.xz"
echo "${EXPECTED_SHA256}  ${src}/passt.tar.xz" | sha256sum -c -
tar -xJf "${src}/passt.tar.xz" -C "${src}" --strip-components=1
make -C "${src}" -j"$(nproc)"
mkdir -p "${TOOL_DIR}/bin"
install -m 0755 "${src}/passt" "${BIN}"
rm -rf "${src}"

capability "${BIN}" || { echo "[ERROR] 构建产物仍无 --map-host-tcp" >&2; exit 1; }
echo "[OK] passt 构建完成：${BIN}"
