#!/bin/bash
# =============================================================================
# Basalt - OTA / 文件轮转更新矩阵测试（设计文档 §10 矩阵 2-7）
# =============================================================================
#
# 覆盖：
#   矩阵 2  OTA v1→v2：成对落盘（erofs+UKI 带 +3-0）、重启后 cmdline 一致、
#           bless 去计数、@images rw wrapper 恢复 ro
#   矩阵 3  引导级坏版本：v3 EROFS 损坏 → initrd emergency → 3 次 tries 耗尽
#           → 自动回 v2（测试机硬复位承载"失败的启动尝试"语义——真实部署
#           为硬件看门狗；sd-boot 对损坏 UKI 二进制的行为无文档保证，不作
#           依赖，故用 EROFS 损坏而非 UKI 损坏承载同一机制）
#   矩阵 4  业务级坏版本：v4 UKI cmdline 追加 systemd.mask=landscape-router
#           → 引导成功但 API_READY 超时 → bless 不触发 → tries 耗尽 → 回 v2
#           （mask 是 cmdline 级、版本内在的故障，不污染共享 overlay upper，
#           回滚后 v1/v2 业务即恢复——规避 §2 声明的共享状态污染边界）
#   矩阵 5  @data 塞满：系统存活 + API 在线；sysupdate 更新 ENOSPC 失败
#           （无害半状态）；清空间后重试成功
#   矩阵 6  rescue：boot-loader-entry 选 basalt-rescue.efi → 只读根 +
#           rescue shell（无 sshd；经串口日志取证 sulogin 提示）
#   矩阵 7  vacuum：运行 v1（os-release 与 ProtectVersion=%A 一致）时种子
#           5 个版本 → 裁至 InstancesMax、当前版本永在、rescue UKI 不动
#
# 伪造版本物料（host 侧）：erofs = v1 工件副本（矩阵 3 为截断副本）；UKI =
# objcopy 抽取 pass1 UKI 的 .linux/.initrd/.osrel/.uname/.cmdline 段后经
# ukify 重排（cmdline 换绑 basalt_<v>.erofs）。矩阵 7 先行（此时运行版本
# 的 os-release 与文件版本一致，ProtectVersion 语义才真实），随后清理种子
# 避免污染后续 OTA 阶段的版本枚举与 sd-boot 选择。
#
# 更新源：宿主 python3 http.server（SHA256SUMS + 版本化工件），guest 经
# WAN slirp 网关 10.0.2.2 访问；设备侧定义以 /etc/sysupdate.d/ 同名覆盖
# （sysupdate.d(5)：/etc 优先于 /usr/lib，扩展名 .transfer）。
# =============================================================================
set -euo pipefail
FAIL_FAST=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/common.sh"
source "${SCRIPT_DIR}/local-runtime.sh"

IMAGE_PATH="${1:-${PROJECT_DIR}/output/basalt.img}"
QEMU_MEM="${QEMU_MEM:-1024}"
QEMU_SMP="${QEMU_SMP:-2}"
SSH_PASSWORD="${SSH_PASSWORD:-landscape}"
SSH_TIMEOUT="${SSH_TIMEOUT:-180}"
SHUTDOWN_TIMEOUT=15
LANDSCAPE_TEST_NAME="ota"
LANDSCAPE_IMAGE_PATH="${IMAGE_PATH}"
LANDSCAPE_ROUTER_PERSIST_IMAGE=1    # 跨重启/硬复位复用镜像（guest 状态存活）
OTA_SERVER_PORT="${OTA_SERVER_PORT:-18080}"
# 矩阵 3/4：tries=TriesLeft 耗尽需要 T 次失败尝试（+T-0 → +0-T）
OTA_TRIES="${OTA_TRIES:-3}"

cleanup() {
    local exit_code=$?
    if [[ -n "${OTA_HTTP_PID:-}" ]] && kill -0 "${OTA_HTTP_PID}" 2>/dev/null; then
        kill "${OTA_HTTP_PID}" 2>/dev/null || true
    fi
    landscape_router_cleanup
    exit $exit_code
}
trap cleanup EXIT
trap landscape_dump_diagnostics_on_term TERM
trap 'exit 130' INT

# ── 断言辅助（FAIL_FAST：任一断言失败即终止——后续阶段依赖前序状态）──
ota_check() {
    local desc="$1"
    shift
    if "$@"; then
        echo "[PASS] ${desc}"
    else
        echo "[FAIL] ${desc}"
        landscape_router_dump_diagnostics "${LANDSCAPE_ROUTER_API_TOKEN:-}"
        exit 1
    fi
}

ota_check_fails() {
    # 断言命令必须失败（ENOSPC 探测等）；失败语义与 ota_check 一致
    # （FAIL_FAST：意外成功同样终止——后续阶段依赖前序状态）
    local desc="$1"
    shift
    if "$@" &>/dev/null; then
        echo "[FAIL] ${desc}（命令意外成功）"
        landscape_router_dump_diagnostics "${LANDSCAPE_ROUTER_API_TOKEN:-}"
        exit 1
    fi
    echo "[PASS] ${desc}"
    return 0
}

# ── 串口日志（每轮 QEMU 启动轮转一个文件，规避 -serial file: 追加/截断
#    语义差异导致的跨启动误匹配）──
SERIAL_GEN=0
ota_rotate_serial() {
    if [[ -f "${LANDSCAPE_ROUTER_SERIAL_LOG}" ]]; then
        SERIAL_GEN=$((SERIAL_GEN + 1))
        mv -f "${LANDSCAPE_ROUTER_SERIAL_LOG}" "${LANDSCAPE_ROUTER_SERIAL_LOG}.boot${SERIAL_GEN}"
    fi
}

ota_serial_wait_pattern() {
    local pattern="$1" timeout="$2" offset="$3"
    local t0=${SECONDS}
    while (( SECONDS - t0 < timeout )); do
        if [[ -f "${LANDSCAPE_ROUTER_SERIAL_LOG}" ]] && \
           tail -c +$((offset + 1)) "${LANDSCAPE_ROUTER_SERIAL_LOG}" 2>/dev/null | grep -q "${pattern}"; then
            return 0
        fi
        sleep 5
    done
    error "串口日志 ${SERIAL_GEN} 轮内未匹配: ${pattern}（${timeout}s）"
    dump_log_tail "${LANDSCAPE_ROUTER_SERIAL_LOG}" "router serial log"
    return 1
}

ota_serial_offset() {
    [[ -f "${LANDSCAPE_ROUTER_SERIAL_LOG}" ]] && stat -c %s "${LANDSCAPE_ROUTER_SERIAL_LOG}" || echo 0
}

# ── VM 生命周期 ──
ota_start_vm() {
    ota_rotate_serial
    landscape_router_start_vm "${IMAGE_PATH}"
}

ota_hard_reset() {
    # 模拟看门狗硬复位：直接终止 QEMU（emergency 挂起时 ACPI 不被响应）
    landscape_router_stop_vm
    ota_start_vm
}

ota_wait_booted() {
    # guest（重）启动后：bootstrap 口注入 eth2 → 主 SSH（mgmt 口）可用
    landscape_router_bootstrap_mgmt "Router"
    setup_ssh
    wait_for_guest_ssh "${LANDSCAPE_ROUTER_PID}" "${LANDSCAPE_ROUTER_SERIAL_LOG}" "Router" "${SSH_TIMEOUT}"
}

ota_reboot_guest() {
    guest_run "systemctl reboot" || true
    sleep 5
    ota_wait_booted
}

# ── OTA 物料伪造（host 侧）──
FAB_DIR=""
OTA_SERVE_DIR=""
V1=""          # 工厂版本号（build-metadata image_version）

ota_fabricate_uki() {
    local ver="$1" extra_cmdline="${2:-}" out="$3"
    local d="${FAB_DIR}/uki-${ver}"
    mkdir -p "${d}"
    local v1_uki="${PROJECT_DIR}/output/${IMAGE_ID}_${V1}.efi"
    [[ -f "${v1_uki}" ]] || { error "缺少工厂 UKI 工件: ${v1_uki}"; return 1; }

    objcopy -O binary --only-section=.linux   "${v1_uki}" "${d}/linux"
    objcopy -O binary --only-section=.initrd  "${v1_uki}" "${d}/initrd"
    objcopy -O binary --only-section=.osrel   "${v1_uki}" "${d}/osrel"
    local cmdline uname
    cmdline="$(objcopy -O binary --only-section=.cmdline "${v1_uki}" /dev/stdout | tr -d '\0')"
    uname="$(objcopy -O binary --only-section=.uname "${v1_uki}" /dev/stdout | tr -d '\0')"
    [[ -s "${d}/linux" && -s "${d}/initrd" && -n "${cmdline}" ]] || { error "UKI PE 段提取失败"; return 1; }

    # cmdline 换绑目标版本镜像（其余参数与工厂 UKI 逐字一致）
    cmdline="$(sed "s/${IMAGE_ID}_${V1}\.erofs/${IMAGE_ID}_${ver}.erofs/" <<<"${cmdline}")"
    [[ -n "${extra_cmdline}" ]] && cmdline="${cmdline} ${extra_cmdline}"
    sed -i "s/^IMAGE_VERSION=.*/IMAGE_VERSION=${ver}/" "${d}/osrel"

    ukify build \
        --linux="${d}/linux" \
        --initrd="${d}/initrd" \
        --os-release="${d}/osrel" \
        --uname="${uname}" \
        --cmdline="${cmdline}" \
        --output="${out}"
}

# 服务一个目标版本：清理服务目录 → 放入 erofs.xz + UKI → 重写 SHA256SUMS
ota_serve_version() {
    local ver="$1" erofs_src="$2" uki_file="$3"
    rm -rf "${OTA_SERVE_DIR}"
    mkdir -p "${OTA_SERVE_DIR}"
    # 流式直压：无需中间未压缩副本（sysupdate 源只消费 .erofs.xz）
    xz -T0 -c "${erofs_src}" > "${OTA_SERVE_DIR}/${IMAGE_ID}_${ver}.erofs.xz"
    cp -f "${uki_file}" "${OTA_SERVE_DIR}/${IMAGE_ID}_${ver}.efi"
    ( cd "${OTA_SERVE_DIR}" && sha256sum \
        "${IMAGE_ID}_${ver}.erofs.xz" "${IMAGE_ID}_${ver}.efi" > SHA256SUMS )
}

# ── guest 侧操作 ──
ota_inject_sysupdate_overrides() {
    local url="http://10.0.2.2:${OTA_SERVER_PORT}/"
    local root_b64 uki_b64
    # 设备侧定义的本地镜像（URL + 显式 Verify=no：测试无 GPG 签名链路，
    # 排除发行版 Verify= 默认值差异的干扰；TriesLeft/InstancesMax 与
    # build.env 同源）
    root_b64="$(base64 -w0 <<EOF
[Transfer]
ProtectVersion=%A
Verify=no

[Source]
Type=url-file
Path=${url}
MatchPattern=${IMAGE_ID}_@v.erofs.xz

[Target]
Type=regular-file
Path=/var/lib/basalt/images
MatchPattern=${IMAGE_ID}_@v.erofs
Mode=0444
InstancesMax=${INSTANCES_MAX}
EOF
)"
    uki_b64="$(base64 -w0 <<EOF
[Transfer]
ProtectVersion=%A
Verify=no

[Source]
Type=url-file
Path=${url}
MatchPattern=${IMAGE_ID}_@v.efi

[Target]
Type=regular-file
Path=/efi/EFI/Linux
MatchPattern=${IMAGE_ID}_@v+${OTA_TRIES}-0.efi ${IMAGE_ID}_@v+${OTA_TRIES}.efi ${IMAGE_ID}_@v.efi
TriesLeft=${OTA_TRIES}
TriesDone=0
InstancesMax=${INSTANCES_MAX}
EOF
)"
    guest_run "mkdir -p /etc/sysupdate.d"
    guest_run "echo ${root_b64} | base64 -d > /etc/sysupdate.d/70-root.transfer"
    guest_run "echo ${uki_b64} | base64 -d > /etc/sysupdate.d/80-uki.transfer"
}

# 经 systemd-sysupdate.service（rw wrapper 窗口）执行更新；输出 service Result
ota_run_update() {
    # 临时取证：service journal 为空（update 真实输出从未被捕获），改为前台
    # 直跑与 ExecStart 完全相同的 wrapper 命令；输出 tee 到 stderr——调用方
    # 以 $( ) 捕获 stdout，不落 stderr 则日志不可见（实测教训）
    local out
    out="$(guest_run "btrfs property set -ts /var/lib/basalt/images ro false && /usr/lib/systemd/systemd-sysupdate update 2>&1; echo RC=\$?")"
    guest_run "btrfs property set -ts /var/lib/basalt/images ro true" || true
    echo "=== [probe] sysupdate update 完整输出 ===" >&2
    echo "${out}" >&2
    printf '%s' "${out}"
}

# ── 各阶段 ──

phase_vacuum() {
    echo "============================================================"
    echo "Phase: 矩阵 7 — vacuum（运行 v${V1}，ProtectVersion 一致）"
    echo "============================================================"
    # boot 收敛校验：每次 boot 由 images-lock.service 强制 @images 子卷属性
    # ro=true（fstab 挂载保持 rw，只读在 btrfs 属性层）。此前首窗口已锁。
    ota_check "boot 收敛 @images ro=true（images-lock.service）" \
        guest_run "btrfs property get -ts /var/lib/basalt/images ro | grep -q 'ro=true'"
    # seed 源双重保障：erofs 与当前镜像同命名；工厂主 UKI 契约校验——
    # ESP 中唯一非 boot-count 的主 UKI（rescue 为连字符名，underscore 模式
    # 天然排除）必须恰为 ${IMAGE_ID}_${V1}.efi（sysupdate MatchPattern=@v 同源，
    # 构建侧 UnifiedKernelImageFormat=%i_%v.efi 保证）。不符则 dump 清单并失败。
    # 解锁（btrfs 子卷属性 ro=false；remount,rw 已被属性方案取代——同 superblock
    # 下 remount,ro 必 EBUSY，见 fstab 注释）。
    guest_run "btrfs property set -ts /var/lib/basalt/images ro false"
    factory_uki="${IMAGE_ID}_${V1}.efi"
    found_uki="$(guest_run "find /efi/EFI/Linux -maxdepth 1 -type f -name '${IMAGE_ID}_*.efi' ! -name '*+*' -printf '%f\n'")"
    if [[ "${found_uki}" != "${factory_uki}" ]]; then
        echo "[FAIL] 工厂主 UKI 契约不符：期望=${factory_uki} 实际=[${found_uki}]" >&2
        guest_run "ls -la /efi/EFI/Linux" >&2
        guest_run "find /efi/EFI/Linux -maxdepth 1 -type f -printf '%f\n'" >&2
        return 1
    fi
    echo "[PASS] 工厂主 UKI 契约校验：${factory_uki}"
    for v in 2 3 4 5; do
        guest_run "cp /var/lib/basalt/images/${IMAGE_ID}_${V1}.erofs /var/lib/basalt/images/${IMAGE_ID}_${v}.erofs"
        guest_run "cp /efi/EFI/Linux/${IMAGE_ID}_${V1}.efi /efi/EFI/Linux/${IMAGE_ID}_${v}.efi"
    done
    # cp 种子后锁回 @images（btrfs 子卷属性 ro=true；原 mount remount,ro 在
    # 共享 superblock 下必 EBUSY，已弃用——见 fstab/10-images-rw.conf 注释）。
    guest_run "btrfs property set -ts /var/lib/basalt/images ro true"

    # systemd-sysupdate bin 在 /usr/lib/systemd/（不在 PATH），须全路径调用；
    # vacuum 的 @images rw 窗口：临时解锁属性 → vacuum → 恢复加锁。
    # 显式捕获退出码（set -e 下 if ! 不可靠）；加锁恢复置于判失败前，成败皆锁。
    set +e
    guest_run "btrfs property set -ts /var/lib/basalt/images ro false && /usr/lib/systemd/systemd-sysupdate vacuum"
    rc=$?
    set -e
    guest_run "btrfs property set -ts /var/lib/basalt/images ro true" || true
    if (( rc != 0 )); then
        echo "[FAIL] vacuum 前 @images rw 窗口解锁/vacuum 失败 (rc=${rc})" >&2
        guest_run "systemctl status systemd-sysupdate.service --no-pager -l" >&2 || true
        return 1
    fi

    local imgs ukis
    imgs="$(guest_run "ls /var/lib/basalt/images" 2>/dev/null || true)"
    ukis="$(guest_run "ls /efi/EFI/Linux" 2>/dev/null || true)"

    ota_check "vacuum 后当前（受保护）版本镜像存在" \
        grep -q "^${IMAGE_ID}_${V1}\.erofs\$" <<<"${imgs}"
    # ota_check 经 "$@" 执行命令，无法承载 shell 否定前缀 `!`（被当命令名）；
    # "v2 已淘汰" = grep v2 必须失败 → 用 ota_check_fails 承载
    ota_check_fails "vacuum 淘汰最旧非保护版本（v2）" \
        grep -q "^${IMAGE_ID}_2\.erofs\$" <<<"${imgs}"
    local n_erofs
    n_erofs="$(grep -c "^${IMAGE_ID}_[0-9].*\.erofs\$" <<<"${imgs}" || true)"
    ota_check "EROFS 实例数 ≤ InstancesMax+1（保护版本可额外保留，n=${n_erofs}）" \
        test "${n_erofs}" -le $(( INSTANCES_MAX + 1 ))
    ota_check "vacuum 不动 rescue UKI" \
        grep -q "${IMAGE_ID}-rescue.efi" <<<"${ukis}"
    ota_check "vacuum 后当前（受保护）UKI 存在" \
        grep -q "^${IMAGE_ID}_${V1}\.efi\$" <<<"${ukis}"

    # 清理种子残留：避免污染后续 OTA 阶段的版本枚举与 sd-boot 最新版选择
    guest_run "btrfs property set -ts /var/lib/basalt/images ro false"
    guest_run "sh -c 'cd /var/lib/basalt/images && ls | grep -v \"^${IMAGE_ID}_${V1}\\.erofs\$\" | xargs -r rm -f'"
    guest_run "btrfs property set -ts /var/lib/basalt/images ro true"
    # ESP 侧清理同样必须排除 v1（^basalt_[0-9] 会同时匹配工厂主 UKI
    # basalt_1.efi——曾实测误删导致 v1 判 incomplete、后续 update no-op）
    guest_run "sh -c 'cd /efi/EFI/Linux && ls | grep -E \"^${IMAGE_ID}_[0-9]\" | grep -v \"^${IMAGE_ID}_${V1}\\.efi\$\" | xargs -r rm -f'"
}

phase_ota_update() {
    local ver="$1"
    echo "============================================================"
    echo "Phase: OTA v${V1}→v${ver}"
    echo "============================================================"
    ota_fabricate_uki "${ver}" "" "${FAB_DIR}/${IMAGE_ID}_${ver}.efi"
    ota_serve_version "${ver}" \
        "${PROJECT_DIR}/output/${IMAGE_ID}_${V1}.erofs" \
        "${FAB_DIR}/${IMAGE_ID}_${ver}.efi"

    # 临时取证（A/B 终审）：update 前 ESP 状态——若 basalt_1.efi 已缺失则为
    # 首启丢失（A）；若存在且 update 后消失则为 sysupdate 行为（B）
    echo "=== [probe] update 前 ESP 清单 ==="
    guest_run "ls -la /efi/EFI/Linux" || true
    echo "=== [probe] /proc/cmdline（当前启动的 UKI 分支）==="
    guest_run "cat /proc/cmdline" || true
    echo "=== [probe] journal 中 ESP 文件删除痕迹 ==="
    guest_run "journalctl --no-pager | grep -iE 'basalt_1|EFI/Linux|unlink' | tail -n 40" || true
    echo "=== [probe] var 分区扩容状态（df + lsblk + ro 属性）==="
    guest_run "df -h /var/lib/basalt/images /var; lsblk /dev/vda; btrfs property get -ts /var/lib/basalt/images ro" || true
    echo "=== [probe] guest 串口（当前 boot）：repart/sysroot 相关行 ==="
    grep -aiE "repart|sysroot|growing|sizing" "${LANDSCAPE_ROUTER_SERIAL_LOG}" | tail -n 40 || true

    local result
    result="$(ota_run_update)"
    # 临时取证版：ota_run_update 直跑输出完整 sysupdate 日志，末行 RC=<n>
    ota_check "sysupdate 更新退出码为 0（RC=0）" \
        grep -q "RC=0" <<<"${result}"
    ota_check "@images wrapper 恢复 ro=true（V12，btrfs 属性）" \
        guest_run "btrfs property get -ts /var/lib/basalt/images ro | grep -q 'ro=true'"
    # EROFS 成对落盘（资源级取证）：Result=success 是服务级结果，不保证 root
    # transfer 安装了 v2——可能 no-op/未枚举/装错路径。失败即 dump：
    #   journal（真实执行序列）+ list 总表 + list <v> 逐 transfer 逐文件详情
    #   （incomplete 定位到具体 transfer/文件）+ 目录清单 + 注入定义
    if ! guest_run "test -f /var/lib/basalt/images/${IMAGE_ID}_${ver}.erofs"; then
        echo "[FAIL] EROFS 成对落盘（${IMAGE_ID}_${ver}.erofs）" >&2
        echo "=== journalctl systemd-sysupdate ===" >&2
        guest_run "journalctl -u systemd-sysupdate.service --no-pager -n 80" >&2 || true
        echo "=== sysupdate list 总表 ===" >&2
        guest_run "/usr/lib/systemd/systemd-sysupdate list --no-pager" >&2 || true
        echo "=== sysupdate list ${V1}（current 逐 transfer 文件详情）===" >&2
        guest_run "/usr/lib/systemd/systemd-sysupdate list ${V1} --no-pager" >&2 || true
        echo "=== sysupdate list ${ver}（candidate 逐 transfer 文件详情）===" >&2
        guest_run "/usr/lib/systemd/systemd-sysupdate list ${ver} --no-pager" >&2 || true
        echo "=== images 目录清单 ===" >&2
        guest_run "ls -la /var/lib/basalt/images" >&2 || true
        echo "=== /efi/EFI/Linux 目录清单 ===" >&2
        guest_run "ls -la /efi/EFI/Linux" >&2 || true
        echo "=== /etc/sysupdate.d 定义（70-root + 80-uki）===" >&2
        guest_run "cat /etc/sysupdate.d/70-root.transfer; echo '---'; cat /etc/sysupdate.d/80-uki.transfer" >&2 || true
        landscape_router_dump_diagnostics "${LANDSCAPE_ROUTER_API_TOKEN:-}"
        return 1
    fi
    ota_check "EROFS 成对落盘（${IMAGE_ID}_${ver}.erofs）" \
        guest_run "test -f /var/lib/basalt/images/${IMAGE_ID}_${ver}.erofs"
    ota_check "UKI 落盘带 tries 计数（${IMAGE_ID}_${ver}+${OTA_TRIES}-0.efi）" \
        guest_run "test -f /efi/EFI/Linux/${IMAGE_ID}_${ver}+${OTA_TRIES}-0.efi"
}

phase_ota_boot_bless() {
    local ver="$1"
    echo "---- 重启进入 v${ver} 并验证 bless ----"
    ota_reboot_guest
    ota_check "v${ver} cmdline 镜像绑定一致" \
        guest_run "grep -q 'basalt.image=${IMAGE_ID}_${ver}.erofs' /proc/cmdline"
    ota_check "根为 overlay（EROFS lower + @os upper）" \
        test "$(guest_run "findmnt -n -o FSTYPE /" 2>/dev/null | tr -d '[:space:]')" = "overlay"
    # bless 在 boot-complete（= basalt-boot-health 成功）后去计数；轮询文件重命名
    wait_for_guest_command "bless 去计数" 240 5 \
        guest_run "test -f /efi/EFI/Linux/${IMAGE_ID}_${ver}.efi"
    ota_check "bless 去计数（${IMAGE_ID}_${ver}.efi，无 tries 后缀）" \
        guest_run "test -f /efi/EFI/Linux/${IMAGE_ID}_${ver}.efi && ! ls /efi/EFI/Linux/ | grep -q '^${IMAGE_ID}_${ver}+.*\.efi\$'"
    ota_check "basalt-boot-health 门通过（API 就绪）" \
        guest_run "systemctl show -p Result --value basalt-boot-health.service | grep -qx success"
}

phase_boot_level_bad() {
    local ver=3
    echo "============================================================"
    echo "Phase: 矩阵 3 — 引导级坏版本（v${ver} EROFS 损坏 → tries 耗尽 → 回 v2）"
    echo "============================================================"
    # UKI 正常（cmdline 绑定 v3），EROFS 截断 → initrd loop mount 失败 → emergency
    ota_fabricate_uki "${ver}" "" "${FAB_DIR}/${IMAGE_ID}_${ver}.efi"
    cp -f "${PROJECT_DIR}/output/${IMAGE_ID}_${V1}.erofs" "${FAB_DIR}/${IMAGE_ID}_${ver}.erofs.corrupt"
    truncate -s 1M "${FAB_DIR}/${IMAGE_ID}_${ver}.erofs.corrupt"
    ota_serve_version "${ver}" \
        "${FAB_DIR}/${IMAGE_ID}_${ver}.erofs.corrupt" \
        "${FAB_DIR}/${IMAGE_ID}_${ver}.efi"

    local result
    result="$(ota_run_update)"
    ota_check "坏版本安装成功（损坏在内容，不在安装）" grep -q "RC=0" <<<"${result}"

    local attempt
    for attempt in 1 2 3; do
        echo "---- 失败启动尝试 ${attempt}/${OTA_TRIES}（硬复位承载）----"
        ota_reboot_guest || true
        # 引导失败：emergency 挂起（无 SSH）；串口取证 initrd-root-overlay 失败信息
        local offset
        offset="$(ota_serial_offset)"
        ota_check "尝试 ${attempt}: initrd emergency（erofs loop mount 失败）" \
            ota_serial_wait_pattern "erofs loop mount failed" 420 "${offset}"
        ota_hard_reset
    done

    echo "---- 第 4 次启动：tries 耗尽，自动回 v2 ----"
    ota_wait_booted
    ota_check "自动回退到 v2（cmdline）" \
        guest_run "grep -q 'basalt.image=${IMAGE_ID}_2.erofs' /proc/cmdline"
    ota_check "坏版本条目耗尽为 bad 态（${IMAGE_ID}_${ver}+0-${OTA_TRIES}.efi）" \
        guest_run "test -f /efi/EFI/Linux/${IMAGE_ID}_${ver}+0-${OTA_TRIES}.efi"
    ota_check "回退后 API 恢复在线" \
        guest_run "curl -skI --max-time 5 https://localhost:6443/ -o /dev/null"
}

phase_business_level_bad() {
    local ver=4
    echo "============================================================"
    echo "Phase: 矩阵 4 — 业务级坏版本（v${ver} mask landscape → API_READY 超时 → 回 v2）"
    echo "============================================================"
    # EROFS 内容完好（v1 副本）；UKI cmdline 追加 systemd.mask= —— 版本内在
    # 故障，不写共享 overlay upper，回滚后业务即恢复
    ota_fabricate_uki "${ver}" "systemd.mask=landscape-router.service" "${FAB_DIR}/${IMAGE_ID}_${ver}.efi"
    ota_serve_version "${ver}" \
        "${PROJECT_DIR}/output/${IMAGE_ID}_${V1}.erofs" \
        "${FAB_DIR}/${IMAGE_ID}_${ver}.efi"

    local result
    result="$(ota_run_update)"
    ota_check "v${ver} 安装成功" test "${result}" = "success"

    local attempt expected_name
    for attempt in 1 2 3; do
        echo "---- 业务失败启动 ${attempt}/${OTA_TRIES} ----"
        ota_reboot_guest
        # 引导成功但 API 永不就绪：健康门超时失败（bless 不触发）
        wait_for_guest_command "basalt-boot-health 失败" 360 5 \
            guest_run "systemctl is-failed basalt-boot-health.service"
        ota_check "尝试 ${attempt}: 健康门失败（bless 不触发）" \
            guest_run "systemctl is-failed basalt-boot-health.service"
        expected_name="${IMAGE_ID}_${ver}+$(( OTA_TRIES - attempt ))-${attempt}.efi"
        ota_check "尝试 ${attempt}: UKI 保留计数（${expected_name}，未被 bless）" \
            guest_run "test -f /efi/EFI/Linux/${expected_name}"
    done

    echo "---- 第 4 次启动：tries 耗尽，自动回 v2 ----"
    ota_reboot_guest
    ota_check "自动回退到 v2（cmdline）" \
        guest_run "grep -q 'basalt.image=${IMAGE_ID}_2.erofs' /proc/cmdline"
    ota_check "回退后 API 恢复在线（业务自愈）" \
        guest_run "curl -skI --max-time 5 https://localhost:6443/ -o /dev/null"
    ota_check "回退后健康门成功" \
        guest_run "systemctl show -p Result --value basalt-boot-health.service | grep -qx success"
}

phase_data_full() {
    local ver=5
    echo "============================================================"
    echo "Phase: 矩阵 5 — @data 塞满（启动/运行不受阻；ENOSPC 半状态可恢复）"
    echo "============================================================"
    # 填满 /var（@data；btrfs 空间池与 @os/@images 共享 → 更新写入同样 ENOSPC）
    guest_run "nohup sh -c 'dd if=/dev/zero of=/var/lib/basalt-ota-fill bs=64M; echo done > /run/ota-fill-done' >/dev/null 2>&1 &" || true
    wait_for_guest_command "磁盘填满" 900 10 \
        guest_run "test -f /run/ota-fill-done"

    ota_check "塞满后系统存活（SSH）" guest_run "echo ok"
    ota_check "塞满后 API 在线（@data 满不阻塞运行）" \
        guest_run "curl -skI --max-time 5 https://localhost:6443/ -o /dev/null"
    ota_check_fails "盘满探测（@data 写入 ENOSPC）" \
        guest_run "dd if=/dev/zero of=/var/lib/basalt-ota-probe bs=1M count=1"

    # 更新写入 ENOSPC → 无害半状态（失败可重试）
    ota_fabricate_uki "${ver}" "" "${FAB_DIR}/${IMAGE_ID}_${ver}.efi"
    ota_serve_version "${ver}" \
        "${PROJECT_DIR}/output/${IMAGE_ID}_${V1}.erofs" \
        "${FAB_DIR}/${IMAGE_ID}_${ver}.efi"
    local result
    result="$(ota_run_update)"
    ota_check_fails "盘满时 sysupdate 失败（ENOSPC 半状态）" grep -q "RC=0" <<<"${result}"
    ota_check "失败后半状态不伤运行（API 在线）" \
        guest_run "curl -skI --max-time 5 https://localhost:6443/ -o /dev/null"

    # 释放空间 → 重试成功
    guest_run "rm -f /var/lib/basalt-ota-fill /var/lib/basalt-ota-probe /run/ota-fill-done; sync; sleep 3"
    result="$(ota_run_update)"
    ota_check "空间恢复后更新重试成功" grep -q "RC=0" <<<"${result}"
    ota_check "v${ver} 成对落盘" \
        guest_run "test -f /var/lib/basalt/images/${IMAGE_ID}_${ver}.erofs -a -f /efi/EFI/Linux/${IMAGE_ID}_${ver}+${OTA_TRIES}-0.efi"
}

phase_rescue() {
    echo "============================================================"
    echo "Phase: 矩阵 6 — rescue（手动选择 → 只读根 + rescue shell）"
    echo "============================================================"
    # 经 EFI Boot Loader Interface 枚举可用条目并锁定 rescue
    local entries rescue_id
    entries="$(guest_run "systemctl reboot --boot-loader-entry=help" 2>&1 || true)"
    rescue_id="$(grep -oE '[^ ]*rescue[^ ]*' <<<"${entries}" | head -1)"
    [[ -n "${rescue_id}" ]] || {
        error "boot-loader-entry 清单中未找到 rescue 条目："
        echo "${entries}" >&2
        exit 1
    }
    info "rescue 条目: ${rescue_id}"

    local offset
    offset="$(ota_serial_offset)"
    guest_run "systemctl reboot --boot-loader-entry=${rescue_id}" || true
    sleep 10

    # rescue.target：无 sshd/网络 → SSH 不可达；sulogin 提示落在串口
    ota_check "rescue shell 就绪（串口 sulogin 提示）" \
        ota_serial_wait_pattern "Give root password for maintenance|rescue" 420 "${offset}"
    local t0=${SECONDS}
    local ssh_up=0
    while (( SECONDS - t0 < 60 )); do
        if guest_run "echo ok" &>/dev/null; then ssh_up=1; break; fi
        sleep 5
    done
    ota_check "rescue 模式 SSH 关闭（rescue.target 单用户语义）" test "${ssh_up}" = "0"
}

# ── 主流程 ──

preflight() {
    landscape_prepare_test_environment
    info "Preflight checks..."

    ensure_image_exists "${IMAGE_PATH}" || {
        error "Build first: ./build.sh --no-compress"
        exit 2
    }

    if ! require_commands qemu-system-x86_64 sshpass curl socat jq awk truncate objcopy ukify python3 xz base64; then
        error "Install test dependencies: sudo apt install qemu-system-x86 ovmf sshpass socat jq systemd-ukify binutils"
        exit 2
    fi

    if ! ensure_local_ports_free "${SSH_PORT}" "$(landscape_bootstrap_ssh_port)" "${OTA_SERVER_PORT}"; then
        exit 2
    fi

    source "${PROJECT_DIR}/build.env"   # IMAGE_ID / INSTANCES_MAX（与设备侧渲染同源）
    load_landscape_topology || exit 2
    landscape_router_init_paths "ota"

    landscape_load_test_identity "${IMAGE_PATH}" || true
    landscape_write_test_metadata "${IMAGE_PATH}"

    V1="$(sed -n 's/^image_version=//p' "${PROJECT_DIR}/output/metadata/build-metadata.txt" | tr -d '[:space:]')"
    [[ -n "${V1}" ]] || { error "build-metadata.txt 缺少 image_version"; exit 2; }
    local v1_erofs="${PROJECT_DIR}/output/${IMAGE_ID}_${V1}.erofs"
    local v1_uki="${PROJECT_DIR}/output/${IMAGE_ID}_${V1}.efi"
    [[ -f "${v1_erofs}" && -f "${v1_uki}" ]] || {
        error "缺少 OTA 原料工件（${v1_erofs} / ${v1_uki}）；CI 需将 *.erofs/*.efi 纳入构建 artifact"
        exit 2
    }

    FAB_DIR="$(mktemp -d "${LANDSCAPE_TEST_TMP_ROOT}/basalt-ota-fab-XXXXXX")"
    OTA_SERVE_DIR="$(mktemp -d "${LANDSCAPE_TEST_TMP_ROOT}/basalt-ota-serve-XXXXXX")"

    # 本地更新源（guest 经 WAN slirp 网关 10.0.2.2 访问宿主）
    python3 -m http.server "${OTA_SERVER_PORT}" --bind 0.0.0.0 \
        --directory "${OTA_SERVE_DIR}" >/dev/null 2>&1 &
    OTA_HTTP_PID=$!
    sleep 1
    kill -0 "${OTA_HTTP_PID}" 2>/dev/null || { error "OTA HTTP 服务启动失败（端口 ${OTA_SERVER_PORT}）"; exit 2; }
    info "OTA update server: http://10.0.2.2:${OTA_SERVER_PORT}/ (pid ${OTA_HTTP_PID})"

    ok "Preflight passed"
}

main() {
    echo ""
    echo "============================================================"
    echo "  Basalt — OTA / 文件轮转更新矩阵测试（矩阵 2-7）"
    echo "============================================================"
    info "Image: ${IMAGE_PATH}"
    echo ""

    preflight

    ota_start_vm
    ota_wait_booted
    # 失败取证由 wait_ready 内部完成（readiness_fail 含快照+诊断）；
    # 外层仅终止
    landscape_router_wait_ready "Router" || exit 1

    # 注入测试 override 到 /etc/sysupdate.d/（覆盖 /usr/lib 占位定义：指向本地
    # OTA server + 与 build.env 同源的 Tries/InstancesMax）。所有 sysupdate
    # 调用（含矩阵 7 的 vacuum 与后续 update）必须加载本地定义，故在首个
    # phase 前注入一次（/etc 持久，跨重启有效）。
    ota_inject_sysupdate_overrides

    # 顺序敏感：矩阵 7 先行（运行版本 os-release 与 ProtectVersion 一致）；
    # 其后 2 → 3 → 4 → 5 → 6（每阶段依赖前序落盘状态）
    phase_vacuum
    phase_ota_update 2
    phase_ota_boot_bless 2
    phase_boot_level_bad
    phase_business_level_bad
    phase_data_full
    phase_rescue

    echo ""
    echo "============================================================"
    echo "OTA 矩阵测试 2-7 全部通过"
    echo "============================================================"
}

main "$@"
