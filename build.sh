#!/bin/bash
# =============================================================================
# build.sh — Basalt 镜像构建入口（mkosi 两遍管线）
#
# 用法：
#   ./build.sh [--include-docker true] [--output-format img,vmdk,ova]
#              [--version vX.Y.Z] [--no-compress] [--smoke]
#   --smoke : 构建后 mkosi qemu 直接启动验证
#
# 更新模型（EROFS 文件轮转，无 A/B root 分区）：
#   pass1  以临时 root 分区定义 + --split-artifacts partitions 拆出裸 EROFS
#          根镜像工件（<主输出名>.root-x86-64.raw），同时产出 kernel/initrd/
#          UKI（rescue UKI 的原料与 ESP 定稿实测）
#   pass2  移除 root 分区定义，将 EROFS 种子进 var 分区 @images 子卷
#          （CopyFiles=/@os-staging:/@images），终盘 = ESP + var(btrfs)
#   运行期 systemd-sysupdate 按版本号成对更新 EROFS 文件 + UKI
#   （mkosi.extra/usr/lib/sysupdate.d/），当前版本 ProtectVersion=%A 保护；
#   @images 运行期默认 ro（btrfs 属性 ro=true，images-lock 收敛），rw 窗口
#   由 systemd-sysupdate.service.d/10-images-rw.conf 承载
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "  $*"; }

usage() {
    sed -n '/^# 用法：$/,/^# ===/p' "${BASH_SOURCE[0]}" | sed '$d;s/^# \{0,1\}//'
}

# ── 配置 ──
[[ -f "${SCRIPT_DIR}/build.env" ]] || die "缺少 build.env（配置单一声明文件）"
source "${SCRIPT_DIR}/build.env"
# 全部可调参数的默认值均在 build.env 声明，此处不再重复
MB=$(( 1024 * 1024 ))                      # 字节算术统一单位，杜绝裸字面量
SMOKE=false
INSTANCES_MAX="${INSTANCES_MAX:-3}"        # 兜底默认（正源在 build.env）

CLI_FORMATS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --base-system)   # 仅支持 debian（mkosi 管线不提供其他系统后端）
            [[ "$2" == "debian" ]] || die "mkosi 管线仅支持 debian，收到 '$2'"
            shift 2 ;;
        --include-docker) INCLUDE_DOCKER="$2"; shift 2 ;;
        --output-format)  CLI_FORMATS+=("$2"); shift 2 ;;
        --version)        LANDSCAPE_VERSION="$2"; shift 2 ;;
        --no-compress)    COMPRESS_OUTPUT="no"; shift ;;
        --run-test)       RUN_TEST="$2"; shift 2 ;;
        --smoke)          SMOKE=true; shift ;;
        -h|--help)        usage; exit 0 ;;
        *) die "未知参数: $1" ;;
    esac
done
# CLI 传入时整体取代 build.env 默认；展开逗号、去重，img 归一到最后
# （导出阶段压缩 img 会移除源 raw，必须最后处理）
if [[ ${#CLI_FORMATS[@]} -gt 0 ]]; then
    OUTPUT_FORMATS="$(IFS=,; echo "${CLI_FORMATS[*]}")"
fi
# grep 无匹配返回 1（仅 img 时必现），须屏蔽退出码防 set -e 终止
rest="$(tr , '\n' <<<"${OUTPUT_FORMATS}" | awk '!seen[$0]++' | { grep -vx img || true; } | paste -sd, -)"
OUTPUT_FORMATS="${rest:+${rest},}img"

# ── 镜像版本（单一事实 = 版本号）──
# 工厂构建恒为 1；--version 显式指定时用该版本号。恒注入 --image-version 是
# 硬契约：ProtectVersion=%A 取 os-release 的 IMAGE_VERSION=，缺失则 vacuum
# 保护静默失效（见 70-root.transfer 头注）
VER="1"
[[ "${LANDSCAPE_VERSION:-latest}" != "latest" ]] && VER="${LANDSCAPE_VERSION#v}"
[[ ${#VER} -le 16 ]] || echo "WARN: 镜像版本 '${VER}' 偏长（UKI/镜像文件名预算）" >&2

require() { command -v "$1" >/dev/null || die "缺少 '$1'（安装: apt install $2）"; }
require mkosi   mkosi
require qemu-img qemu-utils
require xz       xz-utils
require curl     curl
require python3  python3
# pass1 UKI 的 .cmdline PE 段提取（rescue UKI cmdline 唯一事实源）
require objcopy binutils
# rescue UKI（basalt.ro=1 只读根入口）手工编排，用宿主侧 ukify
require ukify    systemd-ukify
# ukify 默认 PE stub（Linux UKI 段容器）：systemd-boot-efi 包提供；
# 缺失时报 FileNotFoundError 而非提示 → 构建期显式断言替代 traceback
EFI_STUB="/usr/lib/systemd/boot/efi/linuxx64.efi.stub"
[[ -f "${EFI_STUB}" ]] || die "缺少 ukify PE stub ${EFI_STUB}（安装: apt install systemd-boot-efi）"
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
# 暂存进 extra tree；mkosi 合入镜像树，经 pass1 的 root 分区 CopyFiles=/ 烘焙
# 为 /usr/share/landscape/landscape_init.toml（工厂默认配置），
# landscape-router.service 首启有条件拷贝到 /var/lib/landscape。
# 不放 var 分区：该分区由 CopyFiles=/var:/@data 组装，业务文件统一走
# /usr/share（随版本原子更新），工厂重置（清 /var）即恢复出厂拓扑。
STAGED_CONFIG="${SCRIPT_DIR}/mkosi/mkosi.extra/usr/share/landscape/landscape_init.toml"
STAGED_WEBAPP="${SCRIPT_DIR}/mkosi/mkosi.extra/root/landscape-webserver"
STAGED_STATIC="${SCRIPT_DIR}/mkosi/mkosi.extra/root/static.zip"
# 先清残留：上次构建中途退出（die/TERM）留在 extra tree 的文件若不在此清除，
# 会被本次构建的 CopyFiles 静默烘焙进镜像
rm -f "${STAGED_CONFIG}" "${STAGED_WEBAPP}" "${STAGED_STATIC}"

# 工厂拓扑烘焙：CI 经 EFFECTIVE_CONFIG_PATH 注入（workflow 设置
# configs/landscape_init.toml），无配置时跳过——缺此步骤 landscape 首启无
# /usr/share/landscape/landscape_init.toml → 走 --auto 不配数据面 → eth0 down
# → bootstrap 通道不通
if [[ -n "${EFFECTIVE_CONFIG_PATH:-}" ]]; then
    [[ -f "${EFFECTIVE_CONFIG_PATH}" ]] || die "EFFECTIVE_CONFIG_PATH 不存在: ${EFFECTIVE_CONFIG_PATH}"
    install -Dm644 "${EFFECTIVE_CONFIG_PATH}" "${STAGED_CONFIG}"
fi

# ── mkosi 参数拼装 ──
MKOSI_ARGS=(
    -C "${SCRIPT_DIR}/mkosi"
    --output-dir       "${WORK_DIR}"
    --package-cache-dir "${WORK_DIR}/aptcache"
    --root-password    "${ROOT_PASSWORD}"
    --image-id         "${IMAGE_ID}"
    --image-version    "${VER}"
    --timezone         "${TIMEZONE}"
    --locale           "${LOCALE}"
    # v26 脚本 sandbox 清洗宿主环境，需显式注入（postinst 的 ld 用户密码用 +
    # os-release 注入：IMAGE_ID/IMAGE_VERSION 是 ProtectVersion=%A 契约源）
    --environment      "ROOT_PASSWORD=${ROOT_PASSWORD}"
    --environment      "IMAGE_ID=${IMAGE_ID}"
    --environment      "IMAGE_VERSION=${VER}"
)
# UKI 自描述根（文件轮转契约；mkosi CLI 的 KernelCommandLine 为追加语义，
# 基础行见 mkosi.conf）：
#   root=/dev/disk/by-partlabel/var + rootflags=subvol=@os → initrd 的
#     fstab-generator 生成 sysroot.mount（btrfs @os：overlay 层宿主；
#     root= 采用 man 明示的设备节点路径形态）
#   basalt.image=<文件名> → initrd-root-overlay.service 解析，相对
#     /sysroot/images/；与 sysupdate 70-root.transfer 的 Target MatchPattern
#     同版本同源（任意可启动 UKI 的镜像必然同版本存在）
MKOSI_ARGS+=(
    --kernel-command-line "root=/dev/disk/by-partlabel/var"
    # 显式 rw：systemd 缺 rw/ro 时挂载为 ro，@os 是 overlay upper 宿主必须可写
    # （与 fstab @os 条目同源）
    --kernel-command-line "rootflags=subvol=@os,compress=zstd:1,noatime,rw"
    --kernel-command-line "basalt.image=${IMAGE_ID}_${VER}.erofs"
)
# 网卡命名对齐：configs/landscape_init.toml 拓扑声明 eth0/eth1，预测性命名
# （ens3 等）随平台漂移；路由器 appliance 惯例固定 eth0/eth1
MKOSI_ARGS+=(--kernel-command-line "net.ifnames=0")
# 诊断参数仅 DIAG_CMDLINE=1 注入（journal 转发到串口），常规构建产物保持 quiet 语义
if [[ "${DIAG_CMDLINE:-0}" == 1 ]]; then
    MKOSI_ARGS+=(
        --kernel-command-line "loglevel=7"
        --kernel-command-line "systemd.log_level=debug"
        --kernel-command-line "systemd.log_target=console"
        --kernel-command-line "udev.log_level=debug"
        --kernel-command-line "systemd.journald.forward_to_console=1"
    )
fi
# APT 镜像直通（mkosi 原生 --mirror，单源无 failover 候选链）
[[ -n "${APT_MIRROR}" ]] && MKOSI_ARGS+=(--mirror "${APT_MIRROR}")
# 诊断：MKOSI_DEBUG=1 时透传 mkosi --debug（模块过滤函数运行时列表等
# debug 日志落 CI step 输出），常规构建保持默认日志级别、产物不受影响
if [[ "${MKOSI_DEBUG:-0}" == 1 ]]; then
    MKOSI_ARGS+=(--debug)
fi

# ── 暂存-恢复：构建期渲染仓库模板文件，EXIT trap 统一还原 git 原状 ──
# 不可用 --repart-dir 指向 work 拷贝：mkosi 自动发现的 mkosi.repart/ 先于
# CLI 目录注册，而 systemd-repart 对跨目录同名定义先到先得
# （conf-files.c files_add() 的 hashmap 去重），work 渲染会被静默跳过。
# 因此只能原位渲染，.orig 备份承载还原职责（repart 只消费 *.conf）。
REPART_DIR="${SCRIPT_DIR}/mkosi/mkosi.repart"
STAGED_REPART_CONFS=()
for conf in "${REPART_DIR}"/*.conf; do
    cp -f "$conf" "$conf.orig"
    STAGED_REPART_CONFS+=("$conf")
done
# 设备侧 sysupdate.d 同属暂存-恢复：渲染 IMAGE_ID 前缀（sed 即在此处生效）。
# 只渲染 MatchPattern 与源 URL；/var/lib/basalt 为固定路径（fstab @os 条目
# 同源），不参与渲染
STAGED_SYSUPDATE_D=(
    "${SCRIPT_DIR}/mkosi/mkosi.extra/usr/lib/sysupdate.d/70-root.transfer"
    "${SCRIPT_DIR}/mkosi/mkosi.extra/usr/lib/sysupdate.d/80-uki.transfer"
    "${SCRIPT_DIR}/mkosi/mkosi.sysupdate/70-root.transfer"
    "${SCRIPT_DIR}/mkosi/mkosi.sysupdate/80-uki.transfer"
)
# 备份名带父目录消歧（设备侧/构建侧同名 transfer）
STAGED_SYSUPDATE_BACKUP=()
for f in "${STAGED_SYSUPDATE_D[@]}"; do
    b="${WORK_DIR}/$(basename "${f%/*}")_$(basename "$f").orig"
    cp -f "$f" "${b}"
    STAGED_SYSUPDATE_BACKUP+=("${b}")
done
sed -i -e "s/basalt_/${IMAGE_ID}_/g" \
    -e "s#updates.example.com/basalt/#updates.example.com/${IMAGE_ID}/#g" \
    -e "s/InstancesMax=3/InstancesMax=${INSTANCES_MAX}/g" \
    -e "s/TriesLeft=3/TriesLeft=${INSTANCES_MAX}/g" \
    "${STAGED_SYSUPDATE_D[@]}"
# 文件轮转新增暂存路径：
#   @os-staging/  —— pass1 EROFS 工件种子（pass2 CopyFiles=/@os-staging:/@images；
#                   staging 根即镜像文件，无 images/ 子目录层级）
#   rescue UKI    —— mkosi.extra/efi/EFI/Linux/，经 ESP CopyFiles=/efi:/ 带入
#   20-root.conf  —— pass1 临时 root 分区定义（pass2 删除）
STAGED_OS_DIR="${SCRIPT_DIR}/mkosi/mkosi.extra/@os-staging"
STAGED_RESCUE_UKI="${SCRIPT_DIR}/mkosi/mkosi.extra/efi/EFI/Linux/${IMAGE_ID}-rescue.efi"
PASS1_ROOT_CONF="${REPART_DIR}/20-root.conf"
rm -rf "${STAGED_OS_DIR}"
rm -f "${STAGED_RESCUE_UKI}"
cleanup_staged() {
    # 无条件清理暂存产物：上次构建中途退出（die/TERM）的残留若不清除，
    # 会被本次构建的 CopyFiles 静默烘焙进镜像
    rm -f "${STAGED_CONFIG}" "${STAGED_WEBAPP}" "${STAGED_STATIC}"
    rm -rf "${STAGED_OS_DIR}"
    rm -f "${STAGED_RESCUE_UKI}" "${PASS1_ROOT_CONF}"
    for conf in "${STAGED_REPART_CONFS[@]:-}"; do
        [[ -n "$conf" && -f "$conf.orig" ]] && mv -f "$conf.orig" "$conf"
    done
    local i=0
    for f in "${STAGED_SYSUPDATE_D[@]:-}"; do
        local b="${STAGED_SYSUPDATE_BACKUP[$i]:-}"
        [[ -n "$f" && -n "${b}" && -f "${b}" ]] && mv -f "${b}" "$f"
        i=$((i+1))
    done
    return 0
}
if [[ "${IMAGE_ID}" != "basalt" ]] && \
   grep -qE 'basalt_' "${STAGED_SYSUPDATE_D[@]}"; then
    die "IMAGE_ID 渲染不完整：渲染后的定义文件仍残留 basalt_"
fi
trap cleanup_staged EXIT
# bash 默认收到 TERM/INT 不执行 EXIT trap（CI timeout 即 TERM），转发使其必达
trap 'exit 143' TERM
trap 'exit 130' INT

if [[ "${INCLUDE_DOCKER}" == "true" ]]; then
    # CLI 逐包注入，配置文件保持单一事实
    MKOSI_ARGS+=(--package docker.io)
fi

echo "============================================================"
echo " Basalt (mkosi, 文件轮转)"
echo " docker=${INCLUDE_DOCKER} outputs=${OUTPUT_FORMATS} version=${LANDSCAPE_VERSION:-latest} image=${VER}"
echo "============================================================"

# ── 构建 ──
export LANDSCAPE_VERSION="${LANDSCAPE_VERSION:-latest}"

# latest 仅用于选下载源；InitConfig 契约要求 toml 顶层 version 与二进制
# 精确一致（Boot 阶段硬校验），故 latest 须先解析出真实 tag
if [[ "${LANDSCAPE_VERSION}" == "latest" ]]; then
    # 匿名 api.github.com 限额 60/hr 且按 runner 共享 IP 计，CI 偶发 403。
    # 有 GITHUB_TOKEN 时带上（→5000/hr，与目标仓库无关）；本地无 token 则匿名
    api_auth=()
    [[ -n "${GITHUB_TOKEN:-}" ]] && api_auth=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
    LANDSCAPE_VERSION="$(curl -fsSL --retry 3 --retry-delay 5 ${api_auth[@]+"${api_auth[@]}"} \
        "https://api.github.com/repos/${LANDSCAPE_REPO#https://github.com/}/releases/latest" \
        | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p')" \
        || die "无法从 GitHub API 解析最新版本号"
    [[ -n "${LANDSCAPE_VERSION}" ]] || die "GitHub API 返回中未找到 tag_name"
fi
ASSET_BASE="${LANDSCAPE_REPO}/releases/download/${LANDSCAPE_VERSION}"
info "下载 Landscape 发布物（${LANDSCAPE_VERSION}）..."
mkdir -p "${STAGED_WEBAPP%/*}" "${STAGED_STATIC%/*}"
curl -fL --retry 3 -o "${STAGED_WEBAPP}" "${ASSET_BASE}/landscape-webserver-x86_64"
chmod +x "${STAGED_WEBAPP}"
curl -fL --retry 3 -o "${STAGED_STATIC}" "${ASSET_BASE}/static.zip"

# 渲染 InitConfig 版本契约：顶层 version 必须与 webserver 一致，缺失即
# Boot("Init config version mismatch") 拒启 → 服务重启循环 → 无人配置网络
if [[ -f "${STAGED_CONFIG}" ]]; then
    sed -i "1i version = \"${LANDSCAPE_VERSION#v}\"" "${STAGED_CONFIG}"
fi

# ── Pass 1：拆出 EROFS 根镜像 + kernel/initrd/UKI 工件 ──
# 防御断言：@os-staging 必须在 pass1 结束后才允许存在——pass1 的 root 分区
# CopyFiles=/ 会烘焙 mkosi.extra/ 全部内容，种子若提前就位即自我嵌套
[[ ! -e "${STAGED_OS_DIR}" ]] || die "@os-staging 残留泄漏进 pass1（CopyFiles=/ 将嵌套种子）"
# 临时 root 分区定义：repart SplitName 默认 %t（分区类型标识）→ 分区工件
# <主输出名>.root-x86-64.raw = 裸 EROFS 根镜像（Label 不参与工件命名，
# 扩展名恒为 .raw；全盘产物弃用）。partitions 由 CLI 追加（主配置
# SplitArtifacts 保持 uki,initrd，终盘不拆分区工件）。
# Minimize=guess 必需：repart 按实测内容（CopyFiles 填充后的 erofs）
# 定分区尺寸；缺省时该分区不参与尺寸推导，内容会被分到极小尺寸 →
# "contents don't fit"
cat > "${PASS1_ROOT_CONF}" <<EOF
[Partition]
Type=root
Label=${IMAGE_ID}_${VER}
Format=erofs
Compression=lz4hc
Minimize=guess
CopyFiles=/
EOF
info "mkosi build（pass 1/2：拆分 EROFS/kernel/initrd/UKI 工件）..."
mkosi "${MKOSI_ARGS[@]}" --split-artifacts uki,initrd,kernel,partitions build

# pass1 分区工件 → 版本化 EROFS 根镜像（sysupdate/loop 挂载的正名产物）
EROFS_SPLIT="$(ls "${WORK_DIR}"/${IMAGE_ID}*.root-x86-64.raw 2>/dev/null | head -1)"
[[ -n "${EROFS_SPLIT}" ]] || die "未找到 pass1 EROFS 分区工件（${IMAGE_ID}*.root-x86-64.raw）"
EROFS_FILE="${WORK_DIR}/${IMAGE_ID}_${VER}.erofs"
mv -f "${EROFS_SPLIT}" "${EROFS_FILE}"

KERNEL_FILE="$(ls "${WORK_DIR}"/${IMAGE_ID}*.vmlinuz 2>/dev/null | head -1)"
[[ -n "${KERNEL_FILE}" ]] || die "未找到 pass1 kernel 工件（rescue UKI 原料，${IMAGE_ID}*.vmlinuz）"

# EROFS 种子：pass2 经 CopyFiles=/@os-staging:/@images 写入 @images 子卷根
# （0444 与 70-root.transfer 的 Target Mode= 对齐）。路径契约：@images 子卷根
# = 70-root.transfer Target /var/lib/basalt/images（fstab @images 条目同源）
# = initrd-root-overlay 的 /sysroot/images（@images 子卷挂载点；种子不在
# 查找路径根会 loop mount ENOENT → emergency）
install -D -m 0444 "${EROFS_FILE}" "${STAGED_OS_DIR}/${IMAGE_ID}_${VER}.erofs"

# ── rescue UKI（Phase 1：同 kernel+initrd，cmdline 追加只读根分支）──
# 手工 ukify 独立 UKI 是必要路线：mkosi v26 UnifiedKernelImageProfiles=
# 产物不作为 systemd-boot 菜单独立条目，无法满足「rescue 手动选择」语义。
# cmdline 基础行直接从 pass1 UKI 的 .cmdline PE 段提取（objcopy）：
# 主 UKI 即唯一事实（mkosi.conf 基础行 + 本脚本 CLI 追加的完整产物），
# rescue 仅追加只读根分支参数，消除手抄双源
UKI_FILE_PASS1="$(ls -t "${WORK_DIR}"/${IMAGE_ID}*.efi | head -1)"
[[ -n "${UKI_FILE_PASS1}" ]] || die "未找到 pass1 UKI（cmdline 提取源）"
UKI_CMDLINE="$(objcopy -O binary --only-section=.cmdline "${UKI_FILE_PASS1}" /dev/stdout | tr -d '\0')"
[[ -n "${UKI_CMDLINE}" ]] || die "从 pass1 UKI 提取 .cmdline 失败（objcopy）"

# IMAGE_VERSION 契约断言（§5.1）：mkosi 将 --image-id/--image-version 写入
# 镜像 os-release 的 IMAGE_ID=/IMAGE_VERSION=（mkosi.news 官方变更记录），
# UKI 的 .osrel PE 段源自同一 os-release。ProtectVersion=%A 展开取
# /etc/os-release 的 IMAGE_VERSION= —— 缺失时 vacuum 保护静默失效，
# 故在构建期即硬性断言（运行期契约由 readiness 的 guest 侧检查兜底）
UKI_OSREL="$(objcopy -O binary --only-section=.osrel "${UKI_FILE_PASS1}" /dev/stdout | tr -d '\0')"
# .osrel 是 os-release KEY="VALUE" 语法，ukify 会把值用引号包裹；
# 不能用行尾锚点去配原始串（=`1"` 结尾），须解析出值再精确 eq
osrel_val() { awk -F= -v k="$1" '$1==k{gsub(/^"|"$/, "", $2); print $2; exit}' <<<"${UKI_OSREL}"; }
[[ "$(osrel_val IMAGE_VERSION)" == "${VER}" ]] \
    || die "UKI .osrel IMAGE_VERSION=$(osrel_val IMAGE_VERSION) != ${VER}（ProtectVersion=%A 契约破坏）; .osrel 实际=[$(echo "${UKI_OSREL}" | tr '\n' ' ')]"
[[ "$(osrel_val IMAGE_ID)" == "${IMAGE_ID}" ]] \
    || die "UKI .osrel IMAGE_ID=$(osrel_val IMAGE_ID) != ${IMAGE_ID}"
# UKI 内实际 initrd = 子镜像 initrd + kernel-modules initrd 的拼接流
# （SplitArtifacts=initrd 只拆出前者）；rescue UKI 原料与模块门禁工件
# 一律取 pass1 UKI 的 .initrd PE 段——与主 UKI 同源，消除工件分裂
INITRD_FILE="${WORK_DIR}/${IMAGE_ID}_${VER}.initrd"
objcopy -O binary --only-section=.initrd "${UKI_FILE_PASS1}" "${INITRD_FILE}"
[[ -s "${INITRD_FILE}" ]] || die "从 pass1 UKI 提取 .initrd 失败（objcopy）"
info "ukify rescue UKI（只读根入口）..."
# ukify 不创建输出目录的父目录，缺失时报 FileNotFoundError → 先建目录
install -d "$(dirname "${STAGED_RESCUE_UKI}")"
ukify build \
    --linux="${KERNEL_FILE}" \
    --initrd="${INITRD_FILE}" \
    --cmdline="${UKI_CMDLINE} basalt.ro=1 systemd.unit=rescue.target" \
    --output="${STAGED_RESCUE_UKI}"

# ── ESP 自适应定稿（唯一需要预算的固定尺寸）──
#   ESP 目标 = max(单 UKI 实测) × (InstancesMax+1) + rescue UKI 实测
#              （+1 = 更新过程瞬态；≥ 64MiB vfat 实用下限）
# var 保持 Minimize=guess 紧凑尺寸；盘尾增长空间不烘焙进镜像——真实部署盘
# / 测试 expand（LANDSCAPE_ROUTER_EXPAND_IMAGE_BYTES）提供，首启
# systemd-repart（92-var-grow.conf Weight=100）+ x-systemd.growfs 吃掉。
# 显式 IMAGE_SIZE_MB 时仍可按指定总尺寸 truncate（罕见场景）。
ukis=("${WORK_DIR}"/${IMAGE_ID}*.efi)
[[ -e "${ukis[0]}" ]] || die "未找到 UKI 产物，自适应定稿失败（构建输出异常）"
uki_bytes=0
for u in "${ukis[@]}"; do
    sz=$(stat -c %s "${u}")
    (( sz > uki_bytes )) && uki_bytes=${sz}
done
rescue_bytes=$(stat -c %s "${STAGED_RESCUE_UKI}")
ESP_MIN_BYTES=$(( 64 * MB ))
esp_target=$(( uki_bytes * ( INSTANCES_MAX + 1 ) + rescue_bytes ))
(( esp_target < ESP_MIN_BYTES )) && esp_target=${ESP_MIN_BYTES}
esp_target=$(( (esp_target + MB - 1) / MB * MB ))   # 上取整 MiB

# 渲染 1/3：构建侧 ESP 精确尺寸。两源合并：/boot/EFI（主 UKI，mkosi
# 安装位）+ /efi（systemd-boot + rescue + loader）；/boot 根的 Debian
# 传统内核文件（vmlinuz/System.map/config）与 UKI 引导无关，不入 ESP。
cat > "${REPART_DIR}/10-esp.conf" <<EOF
[Partition]
Type=esp
Label=ESP
Format=vfat
CopyFiles=/boot/EFI:/EFI
CopyFiles=/efi:/
SizeMinBytes=${esp_target}
SizeMaxBytes=${esp_target}
EOF

# 渲染 2/3：移除 pass1 root 定义（root 分区从 GPT 退出）
rm -f "${PASS1_ROOT_CONF}"

# 渲染 3/3：var 增补种子 CopyFiles（.orig 备份由通用暂存-恢复机制承载）
# 前导空行：防御目标文件末尾无换行时注释被拼接
cat >> "${REPART_DIR}/30-var.conf" <<EOF

# build.sh pass2 渲染：EROFS 种子入 @images
CopyFiles=/@os-staging:/@images
EOF

info "mkosi -f build（pass 2/2：终盘 = ESP + var；包缓存/增量缓存仍生效）..."
mkosi -f "${MKOSI_ARGS[@]}" build

latest_raw() {
    # 排除 pass1 --split-artifacts partitions 拆出的全部分区工件
    # （<主名>.<type>.raw，root-x86-64/var/esp 等；同 .raw 后缀共存于 work/）；
    # 主输出 <名>.raw 无中间 .type 段——主名为 IMAGE_ID[_VER][_variant]，
    # 段间分隔是 _/-，不会出现额外点段
    ls -t "${WORK_DIR}"/${IMAGE_ID}*.raw 2>/dev/null \
        | { grep -vE '\.[a-z][a-z0-9-]*\.raw$' || true; } | head -1
}
BUILT_RAW="$(latest_raw)"
[[ -n "${BUILT_RAW}" ]] || die "二次构建未产出 raw"

# ── initrd 收集（pass1 UKI 的 .initrd PE 段 = UKI 内实际 initrd，模块门禁/调试用）──
# 不入 BUILD_ARTIFACTS 与 SHA256SUMS：仅模块门禁消费，不入发布清单
cp -f "${INITRD_FILE}" "${OUTPUT_DIR}/"

# ROOT 工件（裸 EROFS 根镜像）：CI 模块门禁第二参数（erofsfuse/loop 读取）
# 的输入；同 initrd 处理——不入 BUILD_ARTIFACTS 与发布清单
cp -f "${EROFS_FILE}" "${OUTPUT_DIR}/"

# BUILT_RAW 已是最终产物名（显式版本恒注入，与 RAW_FILE 同名）
[[ "${BUILT_RAW}" -ef "${RAW_FILE}" ]] || mv -f "${BUILT_RAW}" "${RAW_FILE}"

# 显式 IMAGE_SIZE_MB：按指定总尺寸 truncate（罕见场景）；
# 默认留空 = 紧凑产物（mkosi pass2 产出，ESP 定稿 + var 内容实测）
if [[ -n "${IMAGE_SIZE_MB}" ]]; then
    raw_mb=$(( ($(stat -c %s "${RAW_FILE}") + MB - 1) / MB ))
    (( IMAGE_SIZE_MB < raw_mb )) && IMAGE_SIZE_MB=${raw_mb}
    truncate -s "${IMAGE_SIZE_MB}M" "${RAW_FILE}"
fi

# ── 冒烟 ──
if [[ "${SMOKE}" == "true" ]]; then
    info "QEMU 冒烟启动（Ctrl-A X 退出）..."
    # 复用完整 MKOSI_ARGS：cmdline（basalt.image 版本绑定）必须与产物一致
    mkosi "${MKOSI_ARGS[@]}" qemu
fi

# ── 导出 ──
IFS=',' read -r -a formats <<<"${OUTPUT_FORMATS//[[:space:]]/}"
for f in "${formats[@]}"; do
    case "$f" in
        img)  ;;           # 最后处理（压缩会移除源文件）
        vmdk) export_vmdk ;;
        ova)  export_ova ;;
        *) die "未知格式 ${f}" ;;
    esac
done
for f in "${formats[@]}"; do
    [[ "$f" == "img" ]] && export_img_xz
done

# ── OTA 产物（sysupdate 版本枚举源）──
# 版本化 EROFS（xz 分发形态，70-root.transfer 的 Source MatchPattern）+
# 版本化 UKI（80-uki.transfer 的 Source MatchPattern）
EROFS_XZ_FILE="${OUTPUT_DIR}/${IMAGE_ID}_${VER}.erofs.xz"
UKI_FILE="${OUTPUT_DIR}/${IMAGE_ID}_${VER}.efi"
info "导出 OTA 工件（${IMAGE_ID}_${VER}.erofs.xz + ${IMAGE_ID}_${VER}.efi）..."
xz -T0 -c "${EROFS_FILE}" > "${EROFS_XZ_FILE}"
uki_latest="$(ls -t "${WORK_DIR}"/${IMAGE_ID}*.efi | head -1)"
cp -f "${uki_latest}" "${UKI_FILE}"
BUILD_ARTIFACTS+=("${EROFS_XZ_FILE}" "${UKI_FILE}")

# ── 本地验证 ──
if [[ "${RUN_TEST}" != "none" ]]; then
    # 压缩会删除 .img（只留 .img.xz），QEMU 测试需要 raw
    [[ "${COMPRESS_OUTPUT}" == "no" ]] || die "RUN_TEST 需要 COMPRESS_OUTPUT=no（先构建再手动解压 xz 亦可）"
    export SSH_PASSWORD="${ROOT_PASSWORD}"
    tests=()
    for t in ${RUN_TEST//,/ }; do
        case "$t" in
            readiness) tests+=("test-readiness.sh") ;;
            dataplane) tests+=("test-dataplane.sh") ;;
            ota)       tests+=("test-ota.sh") ;;
            *) die "未知 RUN_TEST 项 '${t}'（支持 none|readiness|dataplane|ota）" ;;
        esac
    done
    for t in "${tests[@]}"; do
        [[ -f "${SCRIPT_DIR}/tests/${t}" ]] || die "RUN_TEST=${RUN_TEST} 但 ${SCRIPT_DIR}/tests/${t} 不存在"
        # OTA 矩阵含多轮重启/硬复位/tries 耗尽，时长远超其余套件
        tmo=20m
        [[ "${t}" == "test-ota.sh" ]] && tmo=80m
        timeout --foreground "${tmo}" \
            "${SCRIPT_DIR}/tests/${t}" "${IMAGE_RAW_FILE}" || die "${t} 测试失败"
    done
fi

# ── 发布清单 ──
# sysupdate 版本枚举源 = erofs.xz + 版本化 UKI（SHA256SUMS 为 url-file 源的
# 完整性校验契约）；工厂全盘 img(.xz) 仅供 dd 部署，不入清单
( cd "${OUTPUT_DIR}" && sha256sum \
    "$(basename "${EROFS_XZ_FILE}")" "$(basename "${UKI_FILE}")" > SHA256SUMS )

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
    echo "resolved_version=${LANDSCAPE_VERSION}"
    echo "image_version=${VER}"
    echo "base_system=debian"
    echo "include_docker=${INCLUDE_DOCKER}"
    echo "run_test=${RUN_TEST}"
    echo "artifact_id=${BUILD_NAME}"
} > "${OUTPUT_DIR}/metadata/build-metadata.txt"

echo ""
echo "构建完成："
for a in "${BUILD_ARTIFACTS[@]}"; do echo "  - ${a}"; done