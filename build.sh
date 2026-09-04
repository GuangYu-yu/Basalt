#!/bin/bash
# =============================================================================
# build.sh — Basalt 镜像构建入口（mkosi 两遍管线，一次构建两种封装）
#
# 用法：
#   ./build.sh [--include-docker true] [--output-format img,vmdk,ova]
#              [--version vX.Y.Z] [--no-compress] [--smoke]
#   --smoke : 构建后 mkosi qemu 直接启动验证
#
# 更新模型（btrfs 版本化部署子卷，A/B 即用即弃，全根可写）：
#   pass1  --format tar：mkosi 原生 Format=tar（默认 zstd 压缩）从构建树
#          直接流式产出 OTA 根载荷 basalt_<v>.tar.zst（GNU tar --acls
#          --selinux --xattrs PAX，与设备侧解包器 systemd-import 的 GNU tar
#          --xattrs --xattrs-include=* 同构——capabilities 全链路保留），
#          同时拆出 UKI/kernel/initrd 工件（rescue UKI 原料与 ESP 定稿实测）
#   pass2  --format disk（主配置）：工厂盘 = ESP + var(btrfs)。版本化部署
#          子卷 root-basalt-<v> 由 repart Subvolumes= + CopyFiles=/ 从同一
#          构建树灌装（不经 tar 中转，同源性由同一构建树保证）；@landscape
#          载荷子卷由 /@landscape-staging 暂存灌装（pass1 结束后才就位——
#          pass1 的 tar 须纯净，暂存目录不得提前存在）
#   运行期 systemd-sysupdate 按 transfer 文件名字母序成对更新
#   root-basalt-<v> 子卷（url-tar → subvolume）+ UKI（80-uki 最后落位），
#   当前版本 ProtectVersion=%A 保护，InstancesMax=2 即用即弃 A/B
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
# 部署保留深度 = 架构常量（需求：任意时刻最多两个部署共存——当前 rw + 一个
# 旧 ro），硬编码于两份 70-root/80-uki transfer，不经 build.env 参数化
INSTANCES_MAX=2

CLI_FORMATS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --base-system)   # 仅支持 debian（mkosi 管线不提供其他系统后端）
            [[ "$2" == "debian" ]] || die "mkosi 管线仅支持 debian，收到 '$2'"
            shift 2 ;;
        --include-docker) INCLUDE_DOCKER="$2"; shift 2 ;;
        --output-format)  CLI_FORMATS+=("$2"); shift 2 ;;
        --version)        LANDSCAPE_VERSION="$2"; shift 2 ;;
        --image-version)  IMAGE_VERSION="$2"; shift 2 ;;
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

# ── OTA 发布源（GitHub Releases latest/download）──
# 设备侧 transfer 的 Source URL 指向 GitHub Releases：releases/latest/download/
# 是无凭据 302 资产端点（SHA256SUMS 亦经此解析——sysupdate url-file 源的版本
# 枚举即 GET Path/SHA256SUMS）。owner/repo 从构建上下文 .git/config 的 origin
# 推导（复刻仓库构建 → 天然指向自己的 Release）；OTA_BASE_URL 显式覆盖（自建
# 源 / 无 .git 构建兜底）。两者皆缺时保留占位符并警告——设备端 sysupdate 不
# 可用，但不阻断镜像构建（发布流程会断言渲染完整性）。
ota_base_url="${OTA_BASE_URL:-}"
if [[ -z "${ota_base_url}" && -f "${SCRIPT_DIR}/.git/config" ]]; then
    origin_url="$(awk '/\[remote "origin"\]/{f=1;next} f&&/^[[:space:]]*url/{sub(/^[[:space:]]*url[[:space:]]*=[[:space:]]*/,"");print;exit}' "${SCRIPT_DIR}/.git/config")"
    case "${origin_url}" in
        git@github.com:*) repo_path="${origin_url#git@github.com:}" ;;
        *github.com/*)    repo_path="${origin_url#*github.com/}" ;;
    esac
    if [[ -n "${repo_path:-}" ]]; then
        repo_path="${repo_path%.git}"
        ota_base_url="https://github.com/${repo_path}/releases/latest/download/"
        info "OTA 发布源: ${ota_base_url}"
    fi
fi
if [[ -z "${ota_base_url}" ]]; then
    warn "OTA 发布源未渲染（无 .git/origin 或非 GitHub；可设 OTA_BASE_URL 显式指定）——设备侧 transfer 保留占位符"
fi

# ── 镜像版本（双层身份：landscape 版本 = 上游项目版本；镜像版本 = 不可变
#    OTA 单位版本，独立递增——发布 tag 为 v<landscape>-<image>）──
# 工厂构建恒为 1；--image-version 显式指定发布构建的版本。恒注入
# --image-version 是硬契约：ProtectVersion=%A 取 os-release 的 IMAGE_VERSION=，
# 缺失则 vacuum 保护静默失效（见 70-root.transfer 头注）
VER="${IMAGE_VERSION:-1}"
[[ "${VER}" =~ ^[0-9]+$ ]] || die "镜像版本须为纯数字（收到 '${VER}'）"
[[ ${#VER} -le 16 ]] || echo "WARN: 镜像版本 '${VER}' 偏长（UKI/镜像文件名预算）" >&2

require() { command -v "$1" >/dev/null || die "缺少 '$1'（安装: apt install $2）"; }
require mkosi   mkosi
require qemu-img qemu-utils
require xz       xz-utils
require curl     curl
require python3  python3
require unzip    unzip    # 宿主侧解压 static.zip 进 @landscape 暂存（postinst 逻辑已迁出 chroot）
# pass1 UKI 的 .cmdline PE 段提取（rescue UKI cmdline 唯一事实源）
require objcopy binutils
# rescue UKI（basalt.rescue=1 动态发现根入口）手工编排，用宿主侧 ukify
require ukify    systemd-ukify
# ukify 默认 PE stub（Linux UKI 段容器）：systemd-boot-efi 包提供；
# 缺失时报 FileNotFoundError 而非提示 → 构建期显式断言替代 traceback
EFI_STUB="/usr/lib/systemd/boot/efi/linuxx64.efi.stub"
[[ -f "${EFI_STUB}" ]] || die "缺少 ukify PE stub ${EFI_STUB}（安装: apt install systemd-boot-efi）"
# uki 引导 + ToolsTree + systemd-boot 形态需要 mkosi >= 26
# （apt 发行版里的旧版缺 Bootloader=/KernelInitrdModules= 语义）；
# mkosi 不发布 PyPI 包，经 GitHub tag 源码包安装
mkosi_ver="$(mkosi --version | grep -oE '[0-9]+' | head -1)"
[[ "${mkosi_ver}" -ge 26 ]] || die "需要 mkosi >= 26（当前 ${mkosi_ver}；安装: python3 -m pip install --break-system-packages https://github.com/systemd/mkosi/archive/refs/heads/main.tar.gz）"

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
# 暂存进 @landscape 载荷暂存树（三静态资源之一）；landscape-router.service
# 首启有条件拷贝到 /var/lib/landscape（@data）。不放 var 分区：该分区由
# CopyFiles=/var:/@data 组装，业务文件统一走载荷子卷（与二进制/static
# 同源管理，工厂重置（清 /var）后仍可从 @landscape 恢复出厂拓扑）
STAGED_LANDSCAPE_DIR="${SCRIPT_DIR}/mkosi/mkosi.extra/@landscape-staging"
STAGED_CONFIG="${STAGED_LANDSCAPE_DIR}/landscape_init.toml"
STAGED_WEBAPP="${STAGED_LANDSCAPE_DIR}/landscape-webserver"
STAGED_STATIC_ZIP="${WORK_DIR}/static.zip"   # 解压后只留 static/，zip 不入树
# 先清残留：上次构建中途退出（die/TERM）留在 extra tree 的文件若不在此清除，
# 会被本次构建的 CopyFiles 静默烘焙进镜像（pass1 纯净性断言亦依赖此清理）
rm -rf "${STAGED_LANDSCAPE_DIR}"

# 工厂拓扑烘焙：CI 经 EFFECTIVE_CONFIG_PATH 注入（workflow 设置
# configs/landscape_init.toml），无配置时跳过——缺此步骤 landscape 首启无
# 工厂默认 toml → 走 --auto 不配数据面 → eth0 down → bootstrap 通道不通。
# 注入落点为 @landscape-staging 暂存树（三静态资源之一），必须延迟到 pass1
# 之后灌装：pass1 的 tar 无排除面，暂存提前就位会被打包进根载荷
if [[ -n "${EFFECTIVE_CONFIG_PATH:-}" ]]; then
    [[ -f "${EFFECTIVE_CONFIG_PATH}" ]] || die "EFFECTIVE_CONFIG_PATH 不存在: ${EFFECTIVE_CONFIG_PATH}"
    :   # 仅校验存在性；实际灌装见 pass1 后的载荷暂存段
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
# UKI 自描述根（版本化部署子卷契约；mkosi CLI 的 KernelCommandLine 为追加
# 语义，基础行见 mkosi.conf）：
#   root=/dev/disk/by-partlabel/var + rootflags=subvol=root-basalt_<v> → initrd
#     的 fstab-generator 生成 sysroot.mount（btrfs 版本化部署子卷，全根
#     可写；root= 采用 man 明示的设备节点路径形态；与 sysupdate 70-root
#     transfer 的 Target MatchPattern 同版本同源——任意可启动 UKI 的部署
#     子卷必然同版本存在）
MKOSI_ARGS+=(
    --kernel-command-line "root=/dev/disk/by-partlabel/var"
    # 显式 rw：systemd 缺 rw/ro 时挂载语义不定，全根可写是硬需求
    # （内核默认 rw，显式声明防御 remount 语义漂移）
    --kernel-command-line "rootflags=subvol=root-basalt-${VER},compress=zstd:1,noatime,rw"
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
# 设备侧 sysupdate.d 同属暂存-恢复：渲染 IMAGE_ID 前缀与 OTA 源 URL。
# 只渲染 MatchPattern 与源 URL；/var/lib/basalt 为固定路径（fstab 条目
# 同源），不参与渲染。InstancesMax=2/TriesLeft=3 为架构常量，模板即定稿
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
    "${STAGED_SYSUPDATE_D[@]}"
# OTA 发布源渲染：占位域名 → GitHub Releases latest/download（ota_base_url 为
# 空时保留占位符并已警告）。replacement 中的 & 需转义（sed 替换段特殊字符）
if [[ -n "${ota_base_url}" ]]; then
    ota_base_url_esc="${ota_base_url//&/\\&}"
    sed -i -e "s#updates.example.com/${IMAGE_ID}/#${ota_base_url_esc}#g" \
        "${STAGED_SYSUPDATE_D[@]}"
fi
# 暂存路径（全部位于树根，与内容路径无前缀重叠）：
#   /@landscape-staging  —— pass2 @landscape 载荷灌装暂存（pass1 结束后就位，
#                           tar.zst 纯净性 + 部署子卷排除均以其为界）
#   rescue UKI           —— mkosi.extra/efi/EFI/Linux/，经 ESP CopyFiles=/efi:/ 带入
STAGED_RESCUE_UKI="${SCRIPT_DIR}/mkosi/mkosi.extra/efi/EFI/Linux/${IMAGE_ID}-rescue.efi"
rm -f "${STAGED_RESCUE_UKI}"
cleanup_staged() {
    # 无条件清理暂存产物：上次构建中途退出（die/TERM）的残留若不清除，
    # 会被本次构建的 CopyFiles 静默烘焙进镜像
    rm -rf "${STAGED_LANDSCAPE_DIR}"
    rm -f "${STAGED_STATIC_ZIP}" "${STAGED_RESCUE_UKI}"
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
if grep -qE '@v\+3(-0)?\.efi' "${STAGED_SYSUPDATE_D[@]}"; then
    die "MatchPattern 残留字面量 tries 形态（应为 @l/@d 通配）"
fi
if [[ -n "${ota_base_url}" ]] && \
   grep -q 'updates.example.com' "${STAGED_SYSUPDATE_D[@]}"; then
    die "OTA 源渲染不完整：渲染后的定义文件仍残留占位域名"
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
echo " Basalt (mkosi, btrfs 部署子卷)"
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
info "Landscape 发布物版本：${LANDSCAPE_VERSION}（载荷暂存于 pass1 后下载）"

# ── Pass 1：Format=tar 直接产出 OTA 根载荷 + kernel/initrd/UKI 工件 ──
# 防御断言：@landscape-staging 必须在 pass1 结束后才允许存在——pass1 的
# tar 无排除面（mkosi make_tar 仅排除 APIVFS 目录），暂存若提前就位即
# 作为 /@landscape-staging 进入每个 OTA 部署
[[ ! -e "${STAGED_LANDSCAPE_DIR}" ]] || die "@landscape-staging 残留泄漏进 pass1（tar 将携带载荷暂存）"
info "mkosi build（pass 1/2：tar 载荷 + kernel/initrd/UKI 工件）..."
# --format tar 覆盖主配置 Format=disk；tar 输出默认 zstd 压缩（mkosi
# config_default_compression），命名 <ImageId>_<ver>.tar.zst = 设备侧
# 70-root.transfer 的 Source MatchPattern 同名契约
mkosi "${MKOSI_ARGS[@]}" --format tar --split-artifacts uki,initrd,kernel build

# OTA 根载荷正名产物（tar.zst 直接可用，无二次压缩/解压中转）
ROOT_TAR="${WORK_DIR}/${IMAGE_ID}_${VER}.tar.zst"
[[ -f "${ROOT_TAR}" ]] || die "未找到 pass1 tar 载荷（${ROOT_TAR}）"

KERNEL_FILE="$(ls "${WORK_DIR}"/${IMAGE_ID}*.vmlinuz 2>/dev/null | head -1)"
[[ -n "${KERNEL_FILE}" ]] || die "未找到 pass1 kernel 工件（rescue UKI 原料，${IMAGE_ID}*.vmlinuz）"

# ── @landscape 载荷暂存（pass2 的 CopyFiles=/@landscape-staging:/@landscape
#    灌装源；三静态资源 = 完整应用载荷：landscape-webserver / static/（宿主侧
#    解压，zip 不入树）/ landscape_init.toml（下方 EFFECTIVE_CONFIG_PATH 注入）──
info "下载 Landscape 发布物..."
install -d "${STAGED_LANDSCAPE_DIR}"
# 工厂拓扑烘焙灌装（早前仅校验存在性，此处实际落盘；见 EFFECTIVE_CONFIG_PATH 契约）
if [[ -n "${EFFECTIVE_CONFIG_PATH:-}" ]]; then
    install -Dm644 "${EFFECTIVE_CONFIG_PATH}" "${STAGED_CONFIG}"
fi
curl -fL --retry 3 -o "${STAGED_WEBAPP}" "${ASSET_BASE}/landscape-webserver-x86_64"
chmod +x "${STAGED_WEBAPP}"
curl -fL --retry 3 -o "${STAGED_STATIC_ZIP}" "${ASSET_BASE}/static.zip"
unzip -oq "${STAGED_STATIC_ZIP}" -d "${STAGED_LANDSCAPE_DIR}/"
rm -f "${STAGED_STATIC_ZIP}"
[[ -d "${STAGED_LANDSCAPE_DIR}/static" ]] || die "static.zip 解压后无 static/ 目录（载荷布局契约破坏）"

# 渲染 InitConfig 版本契约：顶层 version 必须与 webserver 一致，缺失即
# Boot("Init config version mismatch") 拒启 → 服务重启循环 → 无人配置网络
if [[ -f "${STAGED_CONFIG}" ]]; then
    sed -i "1i version = \"${LANDSCAPE_VERSION#v}\"" "${STAGED_CONFIG}"
fi

# ── rescue UKI（同 kernel+initrd，动态发现根入口）──
# 手工 ukify 独立 UKI 是必要路线：mkosi v26 UnifiedKernelImageProfiles=
# 产物不作为 systemd-boot 菜单独立条目，无法满足「rescue 手动选择」语义。
# cmdline 基础行直接从 pass1 UKI 的 .cmdline PE 段提取（objcopy）并剔除
# root=/rootflags=：rescue 是永久条目，cmdline 不能固化 subvol=root-basalt-N
# （N 随更新递增）；且必须整体剔除 root=——残留 root=（无 subvol）会让
# fstab-generator 生成挂 DefaultSubvolume=@data 的 sysroot.mount，与
# basalt-rescue-select.service（basalt.rescue=1 激活，动态发现最高版本部署）
# 的挂载冲突（EBUSY）。root 发现完全交由 initrd 钩子，消除手抄双源
UKI_FILE_PASS1="$(ls -t "${WORK_DIR}"/${IMAGE_ID}*.efi | head -1)"
[[ -n "${UKI_FILE_PASS1}" ]] || die "未找到 pass1 UKI（cmdline 提取源）"
UKI_CMDLINE="$(objcopy -O binary --only-section=.cmdline "${UKI_FILE_PASS1}" /dev/stdout | tr -d '\0')"
[[ -n "${UKI_CMDLINE}" ]] || die "从 pass1 UKI 提取 .cmdline 失败（objcopy）"
RESCUE_CMDLINE="$(awk '{for(i=1;i<=NF;i++) if($i!~/^root=/ && $i!~/^rootflags=/) printf "%s ",$i; print ""}' <<<"${UKI_CMDLINE}")"
[[ "${RESCUE_CMDLINE}" != *"subvol="* ]] || die "rescue cmdline 残留 subvol=（版本固化事故）"

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
# .osrel 是 UKI 的必需构建输入（ukify --os-release=@PATH 读取文件；缺省时
# ukify 回退到构建宿主机 /etc/os-release——实测 rescue 嵌入 Ubuntu 身份）。
# 与镜像 /usr/lib/os-release 同源：VERSION_ID == IMAGE_VERSION，构成
# systemd-boot Type 2 条目排序契约。
# 身份块同源三处（修改须同步）：此处（rescue UKI 宿主侧原料）、
# mkosi.postinst.chroot（/usr/lib/os-release）、tests/ota_lib.sh（伪造 UKI）
cat > "${WORK_DIR}/basalt.osrel" <<EOF
ID=basalt
NAME="Basalt"
PRETTY_NAME="Basalt ${VER}"
VERSION_ID=${VER}
IMAGE_ID=${IMAGE_ID}
IMAGE_VERSION=${VER}
EOF
ukify build \
    --linux="${KERNEL_FILE}" \
    --initrd="${INITRD_FILE}" \
    --cmdline="${RESCUE_CMDLINE} basalt.rescue=1 systemd.unit=rescue.target" \
    --os-release=@"${WORK_DIR}/basalt.osrel" \
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
# 安装位）+ /efi（systemd-boot + rescue + loader）
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

# 渲染 2/3：30-var.conf 注入版本化部署子卷（.orig 备份由通用暂存-恢复机制
# 承载）。Subvolumes= 为单键空白分隔列表，sed 就地扩行；CopyFiles=/:/root-
# basalt-<v> 从构建树灌装部署子卷；ExcludeFilesTarget= 按目标路径映射排除
# （v257.2 源码 make_copy_files_denylist()：Target 变体不阻断显式源路径的
# 其他 CopyFiles 条目——ExcludeFiles= 源语义会整体跳过命中条目，不可用）：
#   /@landscape-staging —— 载荷暂存（仅入 @landscape，见渲染 3/3）
#   /boot /efi          —— ESP 内容（内核/initrd/引导器全在 ESP 的 UKI 内，
#                          部署子卷内的副本是被挂载遮蔽的死重；工厂子卷与
#                          OTA tar 的差异面记录于此）
sed -i "s#^Subvolumes=/@data /@landscape\$#Subvolumes=/@data /@landscape /root-basalt-${VER}#" \
    "${REPART_DIR}/30-var.conf"
grep -q "^Subvolumes=.* /root-basalt-${VER}\$" "${REPART_DIR}/30-var.conf" \
    || die "30-var.conf Subvolumes 渲染失败（模板行被改动？）"
cat >> "${REPART_DIR}/30-var.conf" <<EOF

# build.sh pass2 渲染：版本化部署子卷灌装 + @landscape 载荷
CopyFiles=/:/root-basalt-${VER}
ExcludeFilesTarget=/root-basalt-${VER}/@landscape-staging /root-basalt-${VER}/boot /root-basalt-${VER}/efi
CopyFiles=/@landscape-staging:/@landscape
EOF

info "mkosi -f build（pass 2/2：工厂盘 = ESP + var（部署子卷 + 载荷 + 数据）；包缓存/增量缓存仍生效）..."
mkosi -f "${MKOSI_ARGS[@]}" build

latest_raw() {
    # 主输出 <名>.raw（pass2 Format=disk 唯一 raw 产物；pass1 为 tar 格式
    # 无 raw）。主名为 IMAGE_ID[_VER][_variant]，段间分隔是 _/-，无点段
    ls -t "${WORK_DIR}"/${IMAGE_ID}*.raw 2>/dev/null | head -1
}
BUILT_RAW="$(latest_raw)"
[[ -n "${BUILT_RAW}" ]] || die "二次构建未产出 raw"

# ── initrd 收集（pass1 UKI 的 .initrd PE 段 = UKI 内实际 initrd，模块门禁/调试用）──
# 不入 BUILD_ARTIFACTS 与 SHA256SUMS：仅模块门禁消费，不入发布清单
cp -f "${INITRD_FILE}" "${OUTPUT_DIR}/"

# ROOT 工件（tar.zst）：CI 模块门禁第二参数（zstandard 解压 + tar 名录，
# 无需挂载权限）的输入；同 initrd 处理——不入 BUILD_ARTIFACTS 与发布清单
# （OTA 发布资产由下方 cp 至 OUTPUT_DIR 的正式副本承载）
cp -f "${ROOT_TAR}" "${OUTPUT_DIR}/"

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
    # 复用完整 MKOSI_ARGS：cmdline（部署子卷版本绑定）必须与产物一致
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
# 版本化 tar.zst（70-root.transfer 的 Source MatchPattern）+ 版本化 UKI
# （80-uki.transfer 的 Source MatchPattern）
ROOT_TAR_FILE="${OUTPUT_DIR}/${IMAGE_ID}_${VER}.tar.zst"
UKI_FILE="${OUTPUT_DIR}/${IMAGE_ID}_${VER}.efi"
info "导出 OTA 工件（${IMAGE_ID}_${VER}.tar.zst + ${IMAGE_ID}_${VER}.efi）..."
uki_latest="$(ls -t "${WORK_DIR}"/${IMAGE_ID}*.efi | head -1)"
cp -f "${uki_latest}" "${UKI_FILE}"
BUILD_ARTIFACTS+=("${ROOT_TAR_FILE}" "${UKI_FILE}")

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
# sysupdate 版本枚举源 = tar.zst + 版本化 UKI（SHA256SUMS 为 url-tar 源的
# 完整性校验契约：下载 payload 无条件对清单校验，Verify= 只管清单签名）；
# 工厂全盘 img(.xz) 仅供 dd 部署，不入清单
( cd "${OUTPUT_DIR}" && sha256sum \
    "$(basename "${ROOT_TAR_FILE}")" "$(basename "${UKI_FILE}")" > SHA256SUMS )

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