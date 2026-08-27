#!/bin/bash
# =============================================================================
# build.sh — Basalt 镜像构建入口（mkosi 管线）
#
# 兼容旧 CLI：--include-docker / --output-format / --version / --no-compress
# 有意不兼容：--base-system alpine（mkosi 不支持 Alpine）；BIOS 引导（UKI 纯 UEFI）
#
# 用法：
#   ./build.sh [--include-docker true] [--output-format img,vmdk,ova]
#              [--version vX.Y.Z] [--no-compress] [--smoke]
#   --smoke : 构建后 mkosi qemu 直接启动验证
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "  $*"; }

# ── 配置 ──
[[ -f "${SCRIPT_DIR}/build.env" ]] && source "${SCRIPT_DIR}/build.env"
INCLUDE_DOCKER="${INCLUDE_DOCKER:-false}"
OUTPUT_FORMATS="${OUTPUT_FORMATS:-img}"
COMPRESS_OUTPUT="${COMPRESS_OUTPUT:-yes}"
ROOT_PASSWORD="${ROOT_PASSWORD:-landscape}"
TIMEZONE="${TIMEZONE:-Asia/Shanghai}"
LOCALE="${LOCALE:-C.UTF-8}"
EXTRA_LOCALES="${EXTRA_LOCALES:-}"
APT_MIRROR="${APT_MIRROR:-}"
IMAGE_SIZE_MB="${IMAGE_SIZE_MB-}"          # 空 = 自适应（见自适应定稿段）
IMAGE_HEADROOM="${IMAGE_HEADROOM-2}"       # 名义盘中 var 余量倍数
RUN_TEST="${RUN_TEST:-none}"
SMOKE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --base-system)   # 兼容占位：仅接受 debian
            [[ "$2" == "debian" ]] || die "mkosi 管线仅支持 debian，收到 '$2'"
            shift 2 ;;
        --include-docker) INCLUDE_DOCKER="$2"; shift 2 ;;
        # CI 以重复 flag 传入多格式（--output-format img --output-format vmdk），
        # 累积语义：img 恒最后处理（压缩会移除源文件）
        --output-format)  OUTPUT_FORMATS="${2}${OUTPUT_FORMATS:+,${OUTPUT_FORMATS}}"; shift 2 ;;
        --version)        LANDSCAPE_VERSION="$2"; shift 2 ;;
        --no-compress)    COMPRESS_OUTPUT="no"; shift ;;
        --run-test)       RUN_TEST="$2"; shift 2 ;;
        --smoke)          SMOKE=true; shift ;;
        -h|--help)        sed -n '3,22p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) die "未知参数: $1" ;;
    esac
done

require() { command -v "$1" >/dev/null || die "缺少 '$1'（安装: apt install $2）"; }
require mkosi   mkosi
require qemu-img qemu-utils
require xz       xz-utils

# uki 引导 + ToolsTree + systemd-boot 形态需要较新 mkosi
# （apt 发行版里的旧版缺 Bootloader=uki/systemd-boot 语义）
mkosi_ver="$(mkosi --version | grep -oE '[0-9]+' | head -1)"
[[ "${mkosi_ver}" -ge 27 ]] || die "需要 mkosi >= 27（当前 ${mkosi_ver}；pip 安装: python3 -m pip install --break-system-packages mkosi）"

WORK_DIR="${WORK_DIR:-${SCRIPT_DIR}/work}"
OUTPUT_DIR="${OUTPUT_DIR:-$(pwd)/output}"
mkdir -p "${WORK_DIR}" "${OUTPUT_DIR}"

BUILD_NAME="${IMAGE_ID}"
[[ "${INCLUDE_DOCKER}" == "true" ]] && BUILD_NAME+="-docker"

RAW_FILE="${WORK_DIR}/${BUILD_NAME}.raw"
IMAGE_RAW_FILE="${OUTPUT_DIR}/${BUILD_NAME}.img"
IMAGE_XZ_FILE="${IMAGE_RAW_FILE}.xz"
VMDK_FILE="${OUTPUT_DIR}/${BUILD_NAME}.vmdk"
OVA_FILE="${OUTPUT_DIR}/${BUILD_NAME}.ova"
BUILD_ARTIFACTS=()

source "${SCRIPT_DIR}/lib/export.sh"

# ── 智能初始化配置注入（CI 的 EFFECTIVE_CONFIG_PATH 契约）──
# 暂存进 extra tree；mkosi 合入后经 repart CopyFiles=/var 落进 btrfs 分区，
# finalize 据此渲染 runtime.env。构建后恢复 extra tree 原状。
STAGED_CONFIG="${SCRIPT_DIR}/mkosi/mkosi.extra/var/lib/landscape/landscape_init.toml"
# 统一清理：暂存的注入配置 + 自适应渲染的 B 槽定义（后者仅在定稿后才存在）
cleanup_staged() {
    [[ -n "${STAGED_CONFIG_SET:-}" ]] && rm -f "${STAGED_CONFIG}"
    [[ -n "${STAGED_B_DEF:-}" && -f "${WORK_DIR}/91-root-b.conf.orig" ]] && \
        mv -f "${WORK_DIR}/91-root-b.conf.orig" "${STAGED_B_DEF}"
}
trap cleanup_staged EXIT
if [[ -n "${EFFECTIVE_CONFIG_PATH:-}" ]]; then
    [[ -f "${EFFECTIVE_CONFIG_PATH}" ]] || die "EFFECTIVE_CONFIG_PATH 不存在: ${EFFECTIVE_CONFIG_PATH}"
    install -Dm644 "${EFFECTIVE_CONFIG_PATH}" "${STAGED_CONFIG}"
    STAGED_CONFIG_SET=1
fi

# ── mkosi 参数拼装 ──
MKOSI_ARGS=(
    -C "${SCRIPT_DIR}/mkosi"
    --output-dir       "${WORK_DIR}"
    --package-cache-dir "${WORK_DIR}/aptcache"
    --root-password    "${ROOT_PASSWORD}"
    --image-id         "${IMAGE_ID}"
)
# UKI 自描述根：cmdline 绑 sysupdate 版本标签
# （mkosi CLI 的 KernelCommandLine 为追加语义，base 见 mkosi.conf）。
# 工厂构建（latest）= 版本 1，与 mkosi.repart/20-root-a.conf 的 Label 一致
# （该 Label 为槽位标签权威，repart 无版本 specifier，需人工保持一致）；
# 发布构建（--version vX）= x，与 sysupdate 写入后的分区标签同源。
ROOT_LABEL_VER="1"
if [[ -n "${LANDSCAPE_VERSION:-}" && "${LANDSCAPE_VERSION}" != "latest" ]]; then
    ROOT_LABEL_VER="${LANDSCAPE_VERSION#v}"
fi
MKOSI_ARGS+=(--kernel-command-line "root=PARTLABEL=${IMAGE_ID}_${ROOT_LABEL_VER}")
# APT 镜像直通（旧管线 APT_MIRROR 契约；mkosi 原生 --mirror，无 failover
# 候选链）
[[ -n "${APT_MIRROR}" ]] && MKOSI_ARGS+=(--mirror "${APT_MIRROR}")
# 供 finalize（locale）与 postinst（ld 用户密码）消费
export ROOT_PASSWORD LOCALE EXTRA_LOCALES
# ESP 构建期自适应：首次构建按内容实际大小产出，构建后提取 ×ESP_SLOTS 二次
# repart 定稿（见下方 build 段）。repart 定义用 work/repart 的拷贝，不改仓库源文件。
# build.env 缺失时的运行时兜底（与上方各 knob 同一惯用法：文件提供默认值，此处保底）
IMAGE_ID="${IMAGE_ID:-basalt}"
ESP_SLOTS="${ESP_SLOTS:-3}"
REPART_DIR="${WORK_DIR}/repart"
rm -rf "${REPART_DIR}"
cp -a "${SCRIPT_DIR}/mkosi/mkosi.repart" "${REPART_DIR}"
MKOSI_ARGS+=(--repart-dir "${REPART_DIR}")
[[ "${LANDSCAPE_VERSION:-latest}" != "latest" ]] \
    && MKOSI_ARGS+=(--image-version "${LANDSCAPE_VERSION#v}")

if [[ "${INCLUDE_DOCKER}" == "true" ]]; then
    # CLI 逐包注入，配置文件保持单一事实
    MKOSI_ARGS+=(--package docker.io)
fi

echo "============================================================"
echo " Basalt (mkosi)"
echo " docker=${INCLUDE_DOCKER} outputs=${OUTPUT_FORMATS} version=${LANDSCAPE_VERSION:-latest}"
echo "============================================================"

# ── 构建 ──
export LANDSCAPE_VERSION="${LANDSCAPE_VERSION:-latest}"
export LANDSCAPE_REPO TIMEZONE

info "mkosi build ..."
mkosi "${MKOSI_ARGS[@]}" build

# mkosi 产物名 = ${ImageId}[_${ImageVersion}].raw，glob 免疫命名变体
BUILT_RAW="$(ls -t "${WORK_DIR}"/${IMAGE_ID}*.raw 2>/dev/null | head -1)"
[[ -n "${BUILT_RAW}" ]] || die "未找到构建产物（${WORK_DIR}/${IMAGE_ID}*.raw）"

# ── 自适应定稿（二遍构建派生全部尺寸）──
# 派生关系：
#   ESP 目标  = max(单 UKI 实测大小) × ESP_SLOTS（A/B + 更新中临时）
#   B 槽目标  = A 槽分区实测大小（两槽同角色，首启 repart 按此扩容）
#   名义盘    = A + B + ESP + var 构建期分区 × IMAGE_HEADROOM
#   （IMAGE_SIZE_MB 显式设置时优先 —— 旧契约兼容）
require python3 python3
ukis=("${WORK_DIR}"/${IMAGE_ID}*.efi)
[[ -e "${ukis[0]}" ]] || die "未找到 UKI 产物，自适应定稿失败（构建输出异常）"

uki_bytes=0
for u in "${ukis[@]}"; do
    sz=$(stat -c %s "${u}")
    (( sz > uki_bytes )) && uki_bytes=${sz}
done
ESP_MIN_BYTES=$(( 64 * 1024 * 1024 ))   # vfat 实用下限（GPT 结构 + sd-boot）
esp_target=$(( uki_bytes * ESP_SLOTS ))
(( esp_target < ESP_MIN_BYTES )) && esp_target=${ESP_MIN_BYTES}
esp_target=$(( (esp_target + 1048575) / 1048576 * 1048576 ))   # 上取整 MiB

# 分区实测：sfdisk -J（util-linux 自带 JSON），按 DPS Type GUID 取
# 第一块 root（min start = A 槽）与 var 的字节大小
read -r root_bytes var_bytes < <(python3 - "${BUILT_RAW}" <<'PYEOF'
import json, sys
t = json.load(open(sys.argv[1]))["partitiontable"]
ss = int(t.get("sectorsize", 512))
ps = t["partitions"]
ROOT, VAR = ("4f68bce3-e8cd-4db1-96e7-fbcaf984b709",
             "4d21b016-b534-45c2-a9fb-5c16e091fd21")
root = min((p for p in ps if p.get("type", "").lower() == ROOT),
           key=lambda p: p["start"])
var = next((p for p in ps if p.get("type", "").lower() == VAR), None)
print(root["size"] * ss, (var["size"] * ss) if var else 0)
PYEOF
)
[[ -n "${root_bytes}" && "${root_bytes}" -gt 0 ]] || die "root 分区实测失败"

b_target=$(( (root_bytes + 1048575) / 1048576 * 1048576 ))
nominal_mb=$(( (root_bytes * 2 + esp_target + var_bytes * IMAGE_HEADROOM + 1048575) / 1048576 ))

info "自适应: UKI=${uki_bytes}B → ESP=${esp_target}B；root=${root_bytes}B → B=${b_target}B；名义=${nominal_mb}MB（var 余量 ×${IMAGE_HEADROOM}）"

# 渲染 1/2：构建侧 ESP 精确尺寸
cat > "${REPART_DIR}/10-esp.conf" <<EOF
[Partition]
Type=esp
Label=ESP
Format=vfat
SizeMinBytes=${esp_target}
SizeMaxBytes=${esp_target}
EOF

# 渲染 2/2：设备侧 B 槽尺寸（暂存进 extra tree，EXIT trap 统一恢复）
STAGED_B_DEF="${SCRIPT_DIR}/mkosi/mkosi.extra/usr/lib/repart.d/91-root-b.conf"
cp -f "${STAGED_B_DEF}" "${WORK_DIR}/91-root-b.conf.orig"
cat > "${STAGED_B_DEF}" <<EOF
# 构建期自适应渲染（build.sh；勿手改 —— 源模板为 git 版本）
# B 槽 = A 槽实测大小：两槽同角色，首次 sysupdate 写入完整 root 原始镜像不溢出
[Partition]
Type=root
SizeMinBytes=${b_target}
GrowFileSystem=no
EOF

info "mkosi -f build（自适应定稿重建；包缓存/增量缓存仍生效）..."
mkosi -f "${MKOSI_ARGS[@]}" build
BUILT_RAW="$(ls -t "${WORK_DIR}"/${IMAGE_ID}*.raw 2>/dev/null | head -1)"
[[ -n "${BUILT_RAW}" ]] || die "二次构建未产出 raw"

# ── UKI 产物收集（仅 *.efi，sysupdate OTA 发布用）──
# 版本化 UKI（cmdline 绑同版本 PARTLABEL）与 raw 盘共享同一镜像定义
for uki in "${WORK_DIR}"/${IMAGE_ID}*.efi; do
    [[ -e "${uki}" ]] || continue
    cp -f "${uki}" "${OUTPUT_DIR}/"
    BUILD_ARTIFACTS+=("${OUTPUT_DIR}/${uki##*/}")
done

mv -f "${BUILT_RAW}" "${RAW_FILE}"
# 名义尺寸：显式 IMAGE_SIZE_MB 优先（旧契约），否则用自适应计算值。
# 稀疏扩展给首启 repart 增长留可测余量（与 dd 大盘场景对齐）
IMAGE_SIZE_MB="${IMAGE_SIZE_MB:-${nominal_mb}}"
truncate -s "${IMAGE_SIZE_MB}M" "${RAW_FILE}"

# ── 冒烟 ──
if [[ "${SMOKE}" == "true" ]]; then
    info "QEMU 冒烟启动（Ctrl-A X 退出）..."
    # 复用完整 MKOSI_ARGS：cmdline（root=PARTLABEL 版本标签）必须与产物一致
    mkosi "${MKOSI_ARGS[@]}" qemu
fi

# ── 导出 ──
IFS=',' read -r -a formats <<<"${OUTPUT_FORMATS//[[:space:]]/}"
for f in "${formats[@]}"; do
    case "${f}" in
        img)  ;;           # 最后处理（压缩会移除源文件）
        vmdk) export_vmdk ;;
        ova)  export_ova ;;
        *) die "未知格式 ${f}" ;;
    esac
done
for f in "${formats[@]}"; do
    [[ "${f}" == "img" ]] && export_img_xz
done

# ── 本地验证（继承原 RUN_TEST 语义）──
if [[ "${RUN_TEST}" != "none" ]]; then
    [[ -f "${SCRIPT_DIR}/tests/test-readiness.sh" ]] || die "RUN_TEST=${RUN_TEST} 但 ${SCRIPT_DIR}/tests/test-readiness.sh 不存在"
    # 压缩会删除 .img（只留 .img.xz），readiness 需要 raw
    [[ "${COMPRESS_OUTPUT}" == "no" ]] || die "RUN_TEST 需要 COMPRESS_OUTPUT=no（先构建再手动解压 xz 亦可）"
    export SSH_PASSWORD="${ROOT_PASSWORD}"
    timeout --foreground 20m \
        "${SCRIPT_DIR}/tests/test-readiness.sh" "${IMAGE_RAW_FILE}" || die "readiness 测试失败"
fi

# ── 发布清单 ──
# 设备侧 sysupdate url-file 源以发布目录中的 SHA256SUMS 枚举版本（sysupdate.d(5)）；
# 仅纳入设备侧 MatchPattern 消费的产物（img(.xz) + *.efi），vmdk/ova 与 metadata 不入清单。
# 版本化构建（--version vX）的产物名 basalt_<v>.{img.xz,efi} 与 MatchPattern
# 对应；工厂镜像（无版本后缀）仅供 dd 部署，不参与 OTA 枚举。
release_files=()
if [[ "${COMPRESS_OUTPUT}" == "yes" ]]; then
    release_files+=("$(basename "${IMAGE_XZ_FILE}")")
else
    release_files+=("$(basename "${IMAGE_RAW_FILE}")")
fi
for a in "${BUILD_ARTIFACTS[@]}"; do
    [[ "${a}" == *.efi ]] && release_files+=("${a##*/}")
done
( cd "${OUTPUT_DIR}" && sha256sum "${release_files[@]}" > SHA256SUMS )

# ── CI metadata 契约（.github 收集 output/metadata/build-metadata.txt，
# produced_files 逗号分隔：custom-build 按逗号解析；
# 身份键与 tests/common.sh 的 landscape_load_test_identity 对齐）──
cleanup_staged  # 提前清理，产物不依赖 extra tree 残留
produced=""
for a in "${BUILD_ARTIFACTS[@]}"; do produced+="${produced:+,}${a##*/}"; done
mkdir -p "${OUTPUT_DIR}/metadata"
{
    if [[ "${COMPRESS_OUTPUT}" == "yes" ]]; then
        echo "image_file=$(basename "${IMAGE_XZ_FILE}")"
    else
        echo "image_file=$(basename "${IMAGE_RAW_FILE}")"
    fi
    echo "produced_files=${produced}"
    echo "output_formats=${OUTPUT_FORMATS}"
    echo "landscape_version=${LANDSCAPE_VERSION}"
    echo "resolved_version=${LANDSCAPE_VERSION}"
    echo "base_system=debian"
    echo "include_docker=${INCLUDE_DOCKER}"
    echo "run_test=${RUN_TEST}"
    echo "release_channel="
    echo "artifact_id=${BUILD_NAME}"
} > "${OUTPUT_DIR}/metadata/build-metadata.txt"

echo ""
echo "构建完成："
for a in "${BUILD_ARTIFACTS[@]}"; do echo "  - ${a}"; done