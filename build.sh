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
APT_MIRROR="${APT_MIRROR:-}"
IMAGE_SIZE_MB="${IMAGE_SIZE_MB-}"          # 空 = 自适应（见自适应定稿段）
IMAGE_HEADROOM="${IMAGE_HEADROOM-2}"       # 名义盘中 var 余量倍数
MB=$(( 1024 * 1024 ))                      # 字节算术统一单位，杜绝裸字面量
RUN_TEST="${RUN_TEST:-none}"
IMAGE_ID="${IMAGE_ID:-basalt}"     # 产物名/PARTLABEL/sysupdate 的同源前缀（build.env 单一声明，此处保底）
SMOKE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --base-system)   # 兼容占位：仅接受 debian
            [[ "$2" == "debian" ]] || die "mkosi 管线仅支持 debian，收到 '$2'"
            shift 2 ;;
        --include-docker) INCLUDE_DOCKER="$2"; shift 2 ;;
        # 首个 CLI flag 取代 build.env 默认（否则与默认 img 累积重复，导致二次压缩）；
        # CI 重复 flag 依序累积，img 需排在最后（压缩会移除源文件）
        --output-format)
            if [[ -z "${OUTPUT_FORMAT_FROM_CLI:-}" ]]; then
                OUTPUT_FORMATS="$2"
            else
                OUTPUT_FORMATS="${OUTPUT_FORMATS:+${OUTPUT_FORMATS},}$2"
            fi
            OUTPUT_FORMAT_FROM_CLI=1
            shift 2 ;;
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

# uki 引导 + ToolsTree + systemd-boot 形态需要 mkosi >= 26
# （apt 发行版里的旧版缺 Bootloader=/KernelInitrdModules= 语义）；
# mkosi 不发布 PyPI 包，经 GitHub tag 源码包安装
mkosi_ver="$(mkosi --version | grep -oE '[0-9]+' | head -1)"
[[ "${mkosi_ver}" -ge 26 ]] || die "需要 mkosi >= 26（当前 ${mkosi_ver}；安装: python3 -m pip install --break-system-packages https://github.com/systemd/mkosi/archive/refs/tags/v26.tar.gz）"

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
STAGED_WEBAPP="${SCRIPT_DIR}/mkosi/mkosi.extra/root/landscape-webserver"
STAGED_STATIC="${SCRIPT_DIR}/mkosi/mkosi.extra/root/static.zip"
# 统一清理（函数体在 IMAGE_ID 渲染段定义：彼时 STAGED_SYSUPDATE_D 等才就绪）
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
    --timezone         "${TIMEZONE}"
    --locale           "${LOCALE}"
    # v26 脚本 sandbox 清洗宿主环境，需显式注入（postinst 的 ld 用户密码用）
    --environment      "ROOT_PASSWORD=${ROOT_PASSWORD}"
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
# 网卡命名对齐：configs/landscape_init.toml 拓扑声明 eth0/eth1，预测性命名
# （ens3 等）随平台漂移；路由器 appliance 惯例固定 eth0/eth1
MKOSI_ARGS+=(--kernel-command-line "net.ifnames=0")
# GPT 分区名上限 36 字符，超长被 sfdisk/repart 静默截断 → root=PARTLABEL 永远
# 找不到分区、紧急模式。构建期显式失败优于静默产物
partlabel="${IMAGE_ID}_${ROOT_LABEL_VER}"
[[ ${#partlabel} -le 36 ]] || die "PARTLABEL '${partlabel}' 超过 GPT 36 字符上限（IMAGE_ID=${IMAGE_ID} version=${ROOT_LABEL_VER}），截断将导致 root= 无法匹配"
# 排障专用：DIAG_CMDLINE=1 时叠加诊断参数（转发 journal 到串口）。
# 默认关闭；排障结束勿保留在常规构建中
if [[ "${DIAG_CMDLINE:-0}" == 1 ]]; then
    MKOSI_ARGS+=(
        --kernel-command-line "loglevel=7"
        --kernel-command-line "systemd.log_level=debug"
        --kernel-command-line "systemd.log_target=console"
        --kernel-command-line "udev.log_level=debug"
        --kernel-command-line "systemd.journald.forward_to_console=1"
        # 触发 diag-dump.service（ConditionKernelCommandLine=diag）：
        # 运行期网络/端口/应用日志快照上串口
        --kernel-command-line "diag"
    )
fi
# APT 镜像直通（兼容旧版 APT_MIRROR 变量名；mkosi 原生 --mirror，无 failover
# 候选链）
[[ -n "${APT_MIRROR}" ]] && MKOSI_ARGS+=(--mirror "${APT_MIRROR}")
# repart 构建侧定义：与设备侧 sysupdate.d 相同的"暂存-恢复"惯用法。
# 不可用 --repart-dir 指向 work 拷贝：mkosi 自动发现的 mkosi.repart/ 先于
# CLI 目录注册，而 systemd-repart 对跨目录同名定义先到先得
# （conf-files.c files_add() 的 hashmap 去重），work 渲染会被静默跳过，
# ESP/B 自适应曾因此整体失效。.orig 备份仅供 cleanup_staged 恢复，
# repart 只消费 *.conf。
ESP_SLOTS="${ESP_SLOTS:-3}"
REPART_DIR="${SCRIPT_DIR}/mkosi/mkosi.repart"
STAGED_REPART_CONFS=()
for conf in "${REPART_DIR}"/*.conf; do
    cp -f "$conf" "$conf.orig"
    STAGED_REPART_CONFS+=("$conf")
done
sed -i -e "s/basalt_/${IMAGE_ID}_/g" -e "s#/basalt/#/${IMAGE_ID}/#g" \
    "${REPART_DIR}"/*.conf

# ── IMAGE_ID 渲染 ──
# 仓库源文件以默认 ID "basalt" 为模板；构建期把消费方（repart Label /
# sysupdate MatchPattern / URL 路径）统一渲染为实际 IMAGE_ID。
# 设备侧 sysupdate.d 属"暂存-恢复"惯用法（EXIT trap 还原 git 原状）。
STAGED_SYSUPDATE_D=(
    "${SCRIPT_DIR}/mkosi/mkosi.extra/usr/lib/sysupdate.d/70-root.transfer"
    "${SCRIPT_DIR}/mkosi/mkosi.extra/usr/lib/sysupdate.d/80-uki.transfer"
)
for f in "${STAGED_SYSUPDATE_D[@]}"; do
    cp -f "$f" "${WORK_DIR}/$(basename "$f").orig"
done
sed -i -e "s/basalt_/${IMAGE_ID}_/g" -e "s#/basalt/#/${IMAGE_ID}/#g" \
    "${STAGED_SYSUPDATE_D[@]}"
cleanup_staged() {
    [[ -n "${STAGED_CONFIG_SET:-}" ]] && rm -f "${STAGED_CONFIG}"
    [[ -n "${STAGED_ASSETS_SET:-}" ]] && rm -f "${STAGED_WEBAPP}" "${STAGED_STATIC}"
    for conf in "${STAGED_REPART_CONFS[@]:-}"; do
        [[ -n "$conf" && -f "$conf.orig" ]] && mv -f "$conf.orig" "$conf"
    done
    if [[ -n "${STAGED_B_DEF:-}" && -f "${WORK_DIR}/91-root-b.conf.orig" ]]; then
        mv -f "${WORK_DIR}/91-root-b.conf.orig" "${STAGED_B_DEF}"
    fi
    for f in "${STAGED_SYSUPDATE_D[@]:-}"; do
        [[ -n "$f" && -f "${WORK_DIR}/$(basename "$f").orig" ]] \
            && mv -f "${WORK_DIR}/$(basename "$f").orig" "$f"
    done
    return 0
}
if [[ "${IMAGE_ID}" != "basalt" ]] && \
   grep -qE 'basalt_' "${REPART_DIR}"/*.conf "${STAGED_SYSUPDATE_D[@]}"; then
    die "IMAGE_ID 渲染不完整：渲染后的定义文件仍残留 basalt_"
fi
trap cleanup_staged EXIT
# bash 默认收到 TERM/INT 不执行 EXIT trap（CI timeout 即 TERM），
# 转发避免 sed 过的暂存文件残留在仓库工作区
trap 'exit 143' TERM
trap 'exit 130' INT
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

# 上游发布物在宿主侧下载，暂存进 mkosi.extra 注入镜像（chroot 内零网络）；
# postinst 只做落位与解压
if [[ "${LANDSCAPE_VERSION}" == "latest" ]]; then
    ASSET_BASE="${LANDSCAPE_REPO}/releases/latest/download"
else
    ASSET_BASE="${LANDSCAPE_REPO}/releases/download/${LANDSCAPE_VERSION}"
fi
require curl curl
info "下载 Landscape 发布物（${LANDSCAPE_VERSION}）..."
mkdir -p "${STAGED_WEBAPP%/*}" "${STAGED_STATIC%/*}"
curl -fL --retry 3 -o "${STAGED_WEBAPP}" "${ASSET_BASE}/landscape-webserver-x86_64"
chmod +x "${STAGED_WEBAPP}"
curl -fL --retry 3 -o "${STAGED_STATIC}" "${ASSET_BASE}/static.zip"
STAGED_ASSETS_SET=1

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
#   （IMAGE_SIZE_MB 显式设置时优先于计算值）
require python3 python3
ukis=("${WORK_DIR}"/${IMAGE_ID}*.efi)
[[ -e "${ukis[0]}" ]] || die "未找到 UKI 产物，自适应定稿失败（构建输出异常）"

uki_bytes=0
for u in "${ukis[@]}"; do
    sz=$(stat -c %s "${u}")
    (( sz > uki_bytes )) && uki_bytes=${sz}
done
ESP_MIN_BYTES=$(( 64 * MB ))   # vfat 实用下限（GPT 结构 + sd-boot）
esp_target=$(( uki_bytes * ESP_SLOTS ))
(( esp_target < ESP_MIN_BYTES )) && esp_target=${ESP_MIN_BYTES}
esp_target=$(( (esp_target + MB - 1) / MB * MB ))   # 上取整 MiB

# 分区实测：sfdisk -J（util-linux 自带 JSON），按 DPS Type GUID 取
# 第一块 root（min start = A 槽）与 var 的字节大小
read -r root_bytes var_bytes < <(sfdisk -J "${BUILT_RAW}" | python3 -c '
import json, sys
t = json.load(sys.stdin)["partitiontable"]
ss = int(t.get("sectorsize", 512))
ps = t["partitions"]
ROOT, VAR = ("4f68bce3-e8cd-4db1-96e7-fbcaf984b709",
             "4d21b016-b534-45c2-a9fb-5c16e091fd21")
root = min((p for p in ps if p.get("type", "").lower() == ROOT),
           key=lambda p: p["start"])
var = next((p for p in ps if p.get("type", "").lower() == VAR), None)
print(root["size"] * ss, (var["size"] * ss) if var else 0)
')
[[ -n "${root_bytes}" && "${root_bytes}" -gt 0 ]] || die "root 分区实测失败"

# B 槽余量：两槽物理上夹死无法再扩，此值 = 构建后未来所有版本 root 镜像
# 相对当前实测的累计增长预算（超过即更新失败）；两槽对称各持有一份
ROOT_MARGIN_MB="${ROOT_MARGIN_MB:-128}"
b_target=$(( (root_bytes + ROOT_MARGIN_MB * MB + MB - 1) / MB * MB ))
nominal_mb=$(( (root_bytes * 2 + ROOT_MARGIN_MB * 2 * MB + esp_target + var_bytes * IMAGE_HEADROOM + MB - 1) / MB ))

info "自适应: UKI=${uki_bytes}B → ESP=${esp_target}B；root=${root_bytes}B → B=${b_target}B（余量${ROOT_MARGIN_MB}MB）；名义=${nominal_mb}MB（var 余量 ×${IMAGE_HEADROOM}）"

# 渲染 1/3：构建侧 ESP 精确尺寸
cat > "${REPART_DIR}/10-esp.conf" <<EOF
[Partition]
Type=esp
Label=ESP
Format=vfat
CopyFiles=/boot:/
CopyFiles=/efi:/
SizeMinBytes=${esp_target}
SizeMaxBytes=${esp_target}
EOF

# 渲染 2/2：设备侧 B 槽尺寸（暂存进 extra tree，EXIT trap 统一恢复）
STAGED_B_DEF="${SCRIPT_DIR}/mkosi/mkosi.extra/usr/lib/repart.d/91-root-b.conf"
cp -f "${STAGED_B_DEF}" "${WORK_DIR}/91-root-b.conf.orig"
cat > "${STAGED_B_DEF}" <<EOF
# 构建期自适应渲染（build.sh；勿手改 —— 源模板为 git 版本）
# B 槽 = A 槽实测 + 余量：两槽对称，任意次 sysupdate 写入完整 root 原始镜像不溢出
[Partition]
Type=root
SizeMinBytes=${b_target}
GrowFileSystem=no
EOF

# 渲染 2/3：构建侧 B 槽同步全尺寸。分区起点不可移动，若 B 构建期最小化
# 占位，首启 repart 想扩 B 时尾部空闲隔着 var 物理不可达
# （Can't fit ... refusing，连带 var 不扩）
cat > "${REPART_DIR}/21-root-b.conf" <<EOF
[Partition]
Type=root
Label=_empty
Format=erofs
SizeMinBytes=${b_target}
SizeMaxBytes=${b_target}
EOF

# 渲染 3/3：构建侧 A 槽同步 +余量。余量必须两槽对称：更新后角色互换，
# 若 A 保持内容最小尺寸，第二次 sysupdate 写回 A 时余量即失效
cat > "${REPART_DIR}/20-root-a.conf" <<EOF
[Partition]
Type=root
Label=${IMAGE_ID}_1
Format=erofs
Compression=lz4hc
CopyFiles=/
SizeMinBytes=${b_target}
SizeMaxBytes=${b_target}
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

# ── initrd 收集（mkosi SplitArtifacts 拆出的合并 initrd，模块门禁/调试用）──
# 不入 BUILD_ARTIFACTS 与 SHA256SUMS：sysupdate 契约只消费 img(.xz) 与 *.efi
for initrd in "${WORK_DIR}"/${IMAGE_ID}*.initrd; do
    [[ -e "${initrd}" ]] || continue
    cp -f "${initrd}" "${OUTPUT_DIR}/"
done

# latest 构建无版本后缀时 BUILT_RAW 即 RAW_FILE，避免 mv 同文件报错
[[ "${BUILT_RAW}" -ef "${RAW_FILE}" ]] || mv -f "${BUILT_RAW}" "${RAW_FILE}"
# 名义尺寸：显式 IMAGE_SIZE_MB 优先，否则用自适应计算值；
# 不得小于 mkosi 实际产出（否则 truncate 切掉 var 尾部与 GPT 备份头）
raw_mb=$(( ($(stat -c %s "${RAW_FILE}") + MB - 1) / MB ))
(( nominal_mb < raw_mb )) && nominal_mb=${raw_mb}
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