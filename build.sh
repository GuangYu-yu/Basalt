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
#   pass2  移除 root 分区定义，将 EROFS 种子进 var 分区 @os 子卷
#          （CopyFiles=/@os-staging:/@os），终盘 = ESP + var(btrfs)
#   运行期 systemd-sysupdate 按版本号成对更新 EROFS 文件 + UKI
#   （mkosi.extra/usr/lib/sysupdate.d/），当前版本 ProtectVersion=%A 保护
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
ROOT_MARGIN_MB="${ROOT_MARGIN_MB:-128}"    # overlay 增长 + btrfs 元数据余量

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
# rescue UKI（basalt.ro=1 只读根入口）手工编排；ToolsTree 内 ukify 的宿主侧
# 调用路径待实测（V6），宿主 ukify 为确定路径
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
    # v26 脚本 sandbox 清洗宿主环境，需显式注入（postinst 的 ld 用户密码用）
    --environment      "ROOT_PASSWORD=${ROOT_PASSWORD}"
)
# UKI 自描述根（文件轮转契约；mkosi CLI 的 KernelCommandLine 为追加语义，
# 基础行见 mkosi.conf）：
#   root=/dev/disk/by-partlabel/var + rootflags=subvol=@os → initrd 的
#     fstab-generator 生成 sysroot.mount（btrfs @os：镜像与 overlay 层宿主；
#     root= 采用 man 明示的设备节点路径形态）
#   basalt.image=<文件名> → initrd-root-overlay.service 解析，相对
#     /sysroot/images/；与 sysupdate 70-root.transfer 的 Target MatchPattern
#     同版本同源（任意可启动 UKI 的镜像必然同版本存在）
MKOSI_ARGS+=(
    --kernel-command-line "root=/dev/disk/by-partlabel/var"
    --kernel-command-line "rootflags=subvol=@os,compress=zstd:1,noatime"
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
        # 触发 diag-dump.service（ConditionKernelCommandLine=diag）：
        # 运行期网络/端口/应用日志快照上串口
        --kernel-command-line "diag"
    )
fi
# APT 镜像直通（mkosi 原生 --mirror，单源无 failover 候选链）
[[ -n "${APT_MIRROR}" ]] && MKOSI_ARGS+=(--mirror "${APT_MIRROR}")

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
#   @os-staging/  —— pass1 EROFS 工件种子（pass2 CopyFiles=/@os-staging:/@os）
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
# 定分区尺寸；缺省时该分区不参与尺寸推导，实测被分到 4K →
# "contents don't fit"（CI run 33337902596 实证）
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
INITRD_FILE="$(ls -t "${WORK_DIR}"/${IMAGE_ID}*.initrd 2>/dev/null | head -1)"
[[ -n "${INITRD_FILE}" ]] || die "未找到 pass1 initrd 工件（rescue UKI 原料）"

# EROFS 种子：pass2 经 CopyFiles=/@os-staging:/@os 写入 @os 子卷
# （0444 与 70-root.transfer 的 Target Mode= 对齐）
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
info "ukify rescue UKI（只读根入口）..."
# ukify 不创建输出目录的父目录，缺失时报 FileNotFoundError → 先建目录
install -d "$(dirname "${STAGED_RESCUE_UKI}")"
ukify build \
    --linux="${KERNEL_FILE}" \
    --initrd="${INITRD_FILE}" \
    --cmdline="${UKI_CMDLINE} basalt.ro=1 systemd.unit=rescue.target" \
    --output="${STAGED_RESCUE_UKI}"

# ── 自适应定稿（pass2 派生全部尺寸）──
# 派生关系（文件轮转）：
#   ESP 目标  = max(单 UKI 实测) × (InstancesMax+1) + rescue UKI 实测
#               （+1 = 更新过程瞬态；≥ 64MiB vfat 实用下限）
#   名义盘    = ESP + var 静息（@data 种子 + @os 1 份镜像 + overlay 目录）
#               × IMAGE_HEADROOM + (InstancesMax-1) 份额外镜像 + ROOT_MARGIN_MB
#               （IMAGE_SIZE_MB 显式设置时优先于计算值）
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

# 渲染 2/3：移除 pass1 root 定义（root 分区从 GPT 退出）
rm -f "${PASS1_ROOT_CONF}"

# 渲染 3/3：var 增补种子 CopyFiles（.orig 备份由通用暂存-恢复机制承载）
cat >> "${REPART_DIR}/30-var.conf" <<EOF
# build.sh pass2 渲染：EROFS 种子入 @os
CopyFiles=/@os-staging:/@os
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

# ── initrd 收集（mkosi SplitArtifacts 拆出的合并 initrd，模块门禁/调试用）──
# 不入 BUILD_ARTIFACTS 与 SHA256SUMS：仅模块门禁消费，不入发布清单
for initrd in "${WORK_DIR}"/${IMAGE_ID}*.initrd; do
    [[ -e "${initrd}" ]] || continue
    cp -f "${initrd}" "${OUTPUT_DIR}/"
done

# ROOT 工件（裸 EROFS 根镜像）：CI 模块门禁第二参数（erofsfuse/loop 读取）
# 的输入；同 initrd 处理——不入 BUILD_ARTIFACTS 与发布清单
cp -f "${EROFS_FILE}" "${OUTPUT_DIR}/"

# BUILT_RAW 已是最终产物名（显式版本恒注入，与 RAW_FILE 同名）
[[ "${BUILT_RAW}" -ef "${RAW_FILE}" ]] || mv -f "${BUILT_RAW}" "${RAW_FILE}"

# ── 分区实测：var 静息尺寸（@data 种子 + @os 1 份镜像 + overlay 目录）──
erofs_bytes=$(stat -c %s "${EROFS_FILE}")
read -r var_bytes < <(sfdisk -J "${RAW_FILE}" | python3 -c '
import json, sys
t = json.load(sys.stdin)["partitiontable"]
ss = int(t.get("sectorsize", 512))
# DPS（Discoverable Partition Specification）标准类型：var
VAR = "4d21b016-b534-45c2-a9fb-5c16e091fd21"
var = next((p for p in t["partitions"] if p.get("type", "").lower() == VAR), None)
print((var["size"] * ss) if var else 0)
')
# var 实测失败时转储分区表 JSON 供诊断（type 匹配依赖 sfdisk 输出格式）
[[ -n "${var_bytes:-}" && "${var_bytes}" -gt 0 ]] || {
    sfdisk -J "${RAW_FILE}" >&2 || true
    die "var 分区实测失败（上方为 sfdisk -J 原始输出）"
}
nominal_mb=$(( ( esp_target + var_bytes * IMAGE_HEADROOM
                 + erofs_bytes * ( INSTANCES_MAX - 1 )
                 + ROOT_MARGIN_MB * MB + MB - 1 ) / MB ))
info "自适应: UKI=${uki_bytes}B → ESP=${esp_target}B；erofs=${erofs_bytes}B 保留${INSTANCES_MAX}份；名义=${nominal_mb}MB（var 余量 ×${IMAGE_HEADROOM}）"

# 名义尺寸：显式 IMAGE_SIZE_MB 优先，否则用自适应计算值；
# 不得小于 mkosi 实际产出（否则 truncate 切掉 var 尾部与 GPT 备份头）
raw_mb=$(( ($(stat -c %s "${RAW_FILE}") + MB - 1) / MB ))
(( nominal_mb < raw_mb )) && nominal_mb=${raw_mb}
IMAGE_SIZE_MB="${IMAGE_SIZE_MB:-${nominal_mb}}"
truncate -s "${IMAGE_SIZE_MB}M" "${RAW_FILE}"

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
            *) die "未知 RUN_TEST 项 '${t}'（支持 none|readiness|dataplane）" ;;
        esac
    done
    for t in "${tests[@]}"; do
        [[ -f "${SCRIPT_DIR}/tests/${t}" ]] || die "RUN_TEST=${RUN_TEST} 但 ${SCRIPT_DIR}/tests/${t} 不存在"
        timeout --foreground 20m \
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