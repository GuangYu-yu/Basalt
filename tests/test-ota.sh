#!/bin/bash
# =============================================================================
# Basalt — OTA / 文件轮转更新端到端状态机测试
# =============================================================================
#
# 显式状态机（每阶段：前置状态 → 操作 → 后置契约）：
#
#   stage_v2_install   前置: 工厂 v1 运行中（cmdline/ro 属性/主 UKI 契约）
#                      操作: sysupdate 安装 v2
#                      契约: 成对落盘 + @images ro 恢复
#   stage_v2_boot      操作: 重启进 v2
#                      契约: cmdline 绑定 + overlay 根 + bless 去计数 + 健康门
#   stage_v3_exhaust   操作: 安装引导级坏版本（EROFS 截断 1M）→ 硬复位承载
#                      失败启动
#                      契约: tries 耗尽 → 自动回退 v2 + bad 态 + API 恢复
#   stage_v4_exhaust   操作: 安装业务级坏版本（mask landscape-router）→ 同上
#                      契约: 同 v3 + 回退后健康门成功
#   stage_v5_enospc    操作: @data 塞满 → sysupdate 更新 → 清理重试
#                      契约: 系统存活/半状态无害/重试成功
#   stage_vacuum       操作: vacuum（破坏性，收尾——消费前面自然形成的
#                      多版本状态，不 seed、不再销毁后续阶段的状态）
#                      契约: 发生裁剪 + 受保护版本（运行版本）永在 +
#                            实例数 ≤ InstancesMax+1 + rescue 不动
#   stage_rescue       操作: boot-loader-entry 选 rescue（破坏性，最后）
#                      契约: 只读根 + rescue shell（sulogin 上串口）+ SSH 关闭
#
# 断言哲学：只断言稳定契约（文件存在性 / cmdline / btrfs 属性 / bootctl 状态 /
# API 就绪），不断言偶然日志。串口仅两类用途：取证（ota_lib）与 rescue 的
# 唯一观察面（sulogin 是 rescue.target 的稳定产品行为）。
#
# 关键机制说明（详见 ota_lib.sh 实证教训）：
#   - 失败启动尝试 = 硬复位承载（kill -9 QEMU，断电语义；真实部署为看门狗）。
#     warm reboot 实测不可靠，禁用于失败路径
#   - boot counting 回退的判定 = SSH 可达 + bad 态文件存在（稳定契约），
#     不绑定失败发生在哪个阶段；串口签名仅取证
#   - 统一失败出口：EXIT trap 按原始退出码一次性取证（bash ERR trap 有控制流
#     例外，不作唯一兜底）
#
# 更新源：宿主 python3 http.server（SHA256SUMS + 版本化工件），guest 经 WAN
# slirp 网关 10.0.2.2 访问；设备侧定义以 /etc/sysupdate.d/ 同名覆盖
# （sysupdate.d(5)：/etc 优先于 /usr/lib）。
# =============================================================================
set -euo pipefail
FAIL_FAST=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/common.sh"
source "${SCRIPT_DIR}/local-runtime.sh"
source "${SCRIPT_DIR}/ota_lib.sh"

IMAGE_PATH="${1:-${PROJECT_DIR}/output/basalt.img}"
QEMU_MEM="${QEMU_MEM:-1024}"
QEMU_SMP="${QEMU_SMP:-2}"
SSH_PASSWORD="${SSH_PASSWORD:-landscape}"
SSH_TIMEOUT="${SSH_TIMEOUT:-180}"
SHUTDOWN_TIMEOUT="${SHUTDOWN_TIMEOUT:-15}"
LANDSCAPE_TEST_NAME="ota"
LANDSCAPE_IMAGE_PATH="${IMAGE_PATH}"
LANDSCAPE_ROUTER_PERSIST_IMAGE=1    # 跨重启/硬复位复用镜像（guest 状态存活）
OTA_SERVER_PORT="${OTA_SERVER_PORT:-18080}"
OTA_TRIES="${OTA_TRIES:-3}"         # tries=TriesLeft 耗尽需要 T 次失败尝试

OTA_HTTP_PID=""
OTA_VM_STARTED=0
OTA_RUNNING_VER=""                  # 状态机显式状态：当前运行的版本

# ── Stage 1：v2 安装 ──

stage_v2_install() {
    echo "== stage: v2 安装 =="
    # 前置状态：工厂 v1 运行中；@images 收敛 ro=true；工厂主 UKI 命名契约
    # （ESP 中唯一非 boot-count 主 UKI 恰为 ${IMAGE_ID}_${V1}.efi——sysupdate
    # MatchPattern=@v 同源，构建侧 UnifiedKernelImageFormat 保证。rescue 为
    # 连字符名，underscore 模式天然排除）
    ota_check "前置：工厂 v1 cmdline 绑定" \
        guest_run "grep -q 'basalt.image=${IMAGE_ID}_${V1}.erofs' /proc/cmdline"
    ota_check "前置：@images ro=true（images-lock 收敛）" \
        guest_run "btrfs property get -ts /var/lib/basalt/images ro | grep -q 'ro=true'"
    local factory_uki="${IMAGE_ID}_${V1}.efi"
    local found_uki
    found_uki="$(guest_run "find /efi/EFI/Linux -maxdepth 1 -type f -name '${IMAGE_ID}_*.efi' ! -name '*+*' -printf '%f\n'")"
    ota_check "前置：工厂主 UKI 契约（${factory_uki}）" \
        test "${found_uki}" = "${factory_uki}"

    # 操作：sysupdate 安装 v2（产品路径：service → wrapper → ota-prep/sysupdate/
    # ota-select）
    ota_fabricate_uki 2 "" "${FAB_DIR}/${IMAGE_ID}_2.efi"
    ota_serve_version 2 \
        "${PROJECT_DIR}/output/${IMAGE_ID}_${V1}.erofs" \
        "${FAB_DIR}/${IMAGE_ID}_2.efi"
    local result
    result="$(ota_run_update)"
    ota_check "sysupdate 安装成功（Result=${result}）" test "${result}" = "success"

    # 后置契约
    ota_check "@images 恢复 ro=true（wrapper trap）" \
        guest_run "btrfs property get -ts /var/lib/basalt/images ro | grep -q 'ro=true'"
    ota_assert_pair_landed 2
}

# ── Stage 2：v2 引导 + bless ──

stage_v2_boot() {
    echo "== stage: v2 引导 + bless =="
    ota_reboot_guest
    ota_check "v2 cmdline 镜像绑定" \
        guest_run "grep -q 'basalt.image=${IMAGE_ID}_2.erofs' /proc/cmdline"
    ota_check "根为 overlay（EROFS lower + @os upper）" \
        test "$(guest_run "findmnt -n -o FSTYPE /" 2>/dev/null | tr -d '[:space:]')" = "overlay"
    # bless 在 boot-complete（= basalt-boot-health 成功）后去计数；轮询文件重命名
    wait_for_guest_command "bless 去计数" 240 5 \
        guest_run "test -f /efi/EFI/Linux/${IMAGE_ID}_2.efi"
    ota_check "bless 去计数（basalt_2.efi，无 tries 后缀）" \
        guest_run "test -f /efi/EFI/Linux/${IMAGE_ID}_2.efi"
    ota_check "健康门通过（API 就绪）" \
        guest_run "systemctl show -p Result --value basalt-boot-health.service | grep -qx success"
    OTA_RUNNING_VER=2
}

# ── Stage 3：引导级坏版本 → tries 耗尽 → 回退 ──

stage_v3_exhaust() {
    echo "== stage: v3 引导级坏版本（EROFS 截断）→ tries 耗尽 → 回退 =="
    # 损坏注入：截断 1M——超级块保留（可挂载），内容缺失 → 启动无法完成。
    # 契约不绑定失败阶段（挂载失败 / switch_root 无 init 均为合法形态）。
    # sd-boot 对损坏 UKI 二进制的行为无文档保证，不作依赖，故用 EROFS 损坏
    # 而非 UKI 损坏承载同一机制
    ota_fabricate_uki 3 "" "${FAB_DIR}/${IMAGE_ID}_3.efi"
    cp -f "${PROJECT_DIR}/output/${IMAGE_ID}_${V1}.erofs" "${FAB_DIR}/${IMAGE_ID}_3.erofs.corrupt"
    truncate -s 1M "${FAB_DIR}/${IMAGE_ID}_3.erofs.corrupt"
    ota_serve_version 3 \
        "${FAB_DIR}/${IMAGE_ID}_3.erofs.corrupt" \
        "${FAB_DIR}/${IMAGE_ID}_3.efi"
    local result
    result="$(ota_run_update)"
    ota_check "坏版本安装成功（损坏在内容，不在安装）" test "${result}" = "success"
    ota_assert_pair_landed 3

    # 操作：OTA_TRIES 次失败 boot（硬复位承载）→ 契约：回退 v2
    ota_stage_exhaust 3 90 \
        "erofs loop mount failed|Switch root target contains no usable init" \
        || { echo "[FAIL] v3 tries 耗尽未收敛" >&2; return 1; }
    ota_assert_fallback 3 2
}

# ── Stage 4：业务级坏版本 → tries 耗尽 → 回退 ──

stage_v4_exhaust() {
    echo "== stage: v4 业务级坏版本（mask landscape-router）→ tries 耗尽 → 回退 =="
    # mask 注入：cmdline 级、版本内在的业务故障（不污染共享 overlay upper，
    # 回滚后业务即恢复）。注意 mask landscape-router 连带杀死全部接口配置
    # （镜像内 /etc/network/interfaces 仅 lo，eth 由 landscape-router 运行期
    # 管理）→ v4 内 SSH/网络全灭，失败形态的观察面只有串口（健康门失败消息
    # journal+console）
    ota_fabricate_uki 4 "systemd.mask=landscape-router.service" "${FAB_DIR}/${IMAGE_ID}_4.efi"
    ota_serve_version 4 \
        "${PROJECT_DIR}/output/${IMAGE_ID}_${V1}.erofs" \
        "${FAB_DIR}/${IMAGE_ID}_4.efi"
    local result
    result="$(ota_run_update)"
    ota_check "v4 安装成功" test "${result}" = "success"
    ota_assert_pair_landed 4

    ota_stage_exhaust 4 340 "API listener not ready" \
        || { echo "[FAIL] v4 tries 耗尽未收敛" >&2; return 1; }
    ota_assert_fallback 4 2
    ota_check "回退后健康门成功" \
        guest_run "systemctl show -p Result --value basalt-boot-health.service | grep -qx success"
}

# ── Stage 5：@data 塞满（ENOSPC 半状态可恢复）──

stage_v5_enospc() {
    echo "== stage: @data 塞满 → ENOSPC 半状态 → 清理重试 =="
    # 填满 /var（@data；btrfs 空间池与 @os/@images 共享 → 更新写入同样 ENOSPC）
    guest_run "nohup sh -c 'dd if=/dev/zero of=/var/lib/basalt-ota-fill bs=64M; echo done > /run/ota-fill-done' >/dev/null 2>&1 &" || true
    wait_for_guest_command "磁盘填满" 900 10 \
        guest_run "test -f /run/ota-fill-done"

    # 后置契约：系统存活 + API 在线（@data 满不阻塞运行）
    ota_check "塞满后系统存活（SSH）" guest_run "echo ok"
    ota_check "塞满后 API 在线" \
        guest_run "curl -skI --max-time 5 https://localhost:6443/ -o /dev/null"
    ota_check_fails "盘满探测（@data 写入 ENOSPC）" \
        guest_run "dd if=/dev/zero of=/var/lib/basalt-ota-probe bs=1M count=1"

    # 操作：更新写入 ENOSPC → 无害半状态（失败可重试）
    ota_fabricate_uki 5 "" "${FAB_DIR}/${IMAGE_ID}_5.efi"
    ota_serve_version 5 \
        "${PROJECT_DIR}/output/${IMAGE_ID}_${V1}.erofs" \
        "${FAB_DIR}/${IMAGE_ID}_5.efi"
    local result
    result="$(ota_run_update)"
    ota_check "盘满时 sysupdate 失败（ENOSPC 半状态）" test "${result}" != "success"
    ota_check "失败后半状态不伤运行（API 在线）" \
        guest_run "curl -skI --max-time 5 https://localhost:6443/ -o /dev/null"

    # 操作：释放空间 → 重试；契约：成功 + 成对落盘
    guest_run "rm -f /var/lib/basalt-ota-fill /var/lib/basalt-ota-probe /run/ota-fill-done; sync; sleep 3"
    result="$(ota_run_update)"
    ota_check "空间恢复后更新重试成功" test "${result}" = "success"
    ota_assert_pair_landed 5
}

# ── Stage 6：vacuum（破坏性，收尾）──

stage_vacuum() {
    echo "== stage: vacuum（裁剪保留深度 + ProtectVersion）=="
    # 前置状态：自然形成的多版本——运行版本 v2（受 ProtectVersion=%A 保护）；
    # 非保护：v1（工厂）、v3/v4（bad 态）、v5（candidate）。不再 seed 人工
    # 版本（旧流程 vacuum 先行 + seed 5 版本，已弃——破坏性操作应消费前面
    # 自然形成的状态）
    ota_check "前置：运行版本仍为 v2" \
        guest_run "grep -q 'basalt.image=${IMAGE_ID}_2.erofs' /proc/cmdline"
    local before n_before
    before="$(guest_run "ls /var/lib/basalt/images" 2>/dev/null || true)"
    n_before="$(grep -c "^${IMAGE_ID}_[0-9].*\.erofs\$" <<<"${before}" || true)"

    # 操作：vacuum（@images rw 窗口：解锁属性 → vacuum → 恢复加锁，成败皆锁；
    # systemd-sysupdate bin 不在 PATH，全路径调用）
    ota_images_unlock
    if ! guest_run "/usr/lib/systemd/systemd-sysupdate vacuum"; then
        ota_images_lock || true
        echo "[FAIL] vacuum 失败" >&2
        return 1
    fi
    ota_images_lock

    # 后置契约：发生裁剪 + 受保护版本（运行版本）永在 + 深度 ≤ InstancesMax+1
    # + rescue UKI 不动
    local after ukis n_after
    after="$(guest_run "ls /var/lib/basalt/images" 2>/dev/null || true)"
    ukis="$(guest_run "ls /efi/EFI/Linux" 2>/dev/null || true)"
    n_after="$(grep -c "^${IMAGE_ID}_[0-9].*\.erofs\$" <<<"${after}" || true)"
    ota_check "vacuum 发生裁剪（EROFS n=${n_before} → ${n_after}）" \
        test "${n_after}" -lt "${n_before}"
    ota_check "受保护版本镜像存在（运行版本 v${OTA_RUNNING_VER}）" \
        grep -q "^${IMAGE_ID}_${OTA_RUNNING_VER}\.erofs\$" <<<"${after}"
    ota_check "EROFS 实例数 ≤ InstancesMax+1（保护版本可额外保留）" \
        test "${n_after}" -le $(( INSTANCES_MAX + 1 ))
    ota_check "vacuum 不动 rescue UKI" \
        grep -q "${IMAGE_ID}-rescue.efi" <<<"${ukis}"
    ota_check "受保护版本 UKI 存在" \
        grep -q "^${IMAGE_ID}_${OTA_RUNNING_VER}\.efi\$" <<<"${ukis}"
}

# ── Stage 7：rescue（破坏性，最后）──

stage_rescue() {
    echo "== stage: rescue（手动入口 → 只读根 + rescue shell）=="
    # 经 EFI Boot Loader Interface 枚举可用条目并锁定 rescue
    local entries rescue_id
    entries="$(guest_run "systemctl reboot --boot-loader-entry=help" 2>&1 || true)"
    rescue_id="$(grep -oE '[^ ]*rescue[^ ]*' <<<"${entries}" | head -1)"
    [[ -n "${rescue_id}" ]] || {
        error "boot-loader-entry 清单中未找到 rescue 条目："
        echo "${entries}" >&2
        return 1
    }
    info "rescue 条目: ${rescue_id}"

    local offset
    offset="$(ota_serial_offset)"
    guest_run "systemctl reboot --boot-loader-entry=${rescue_id}" || true
    sleep 10

    # 契约：rescue.target 无 sshd/网络 → SSH 不可达；sulogin 提示上串口
    # （串口是 rescue 的唯一观察面；sulogin 提示是稳定产品行为，非偶然日志）
    ota_check "rescue shell 就绪（串口 sulogin 提示）" \
        ota_serial_expect "Give root password for maintenance|rescue" 420 "${offset}"
    local t0=${SECONDS} ssh_up=0
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

    OTA_RUNNING_VER="${V1}"
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
    echo "  Basalt — OTA / 文件轮转更新状态机测试"
    echo "============================================================"
    info "Image: ${IMAGE_PATH}"
    echo ""

    trap ota_exit_handler EXIT
    preflight

    ota_start_vm
    OTA_VM_STARTED=1
    ota_wait_booted
    # 失败取证由 wait_ready 内部完成（readiness_fail 含快照+诊断）
    landscape_router_wait_ready "Router" || exit 1

    # 注入测试 override（/etc 优先于 /usr/lib；持久，跨重启有效）
    ota_inject_sysupdate_overrides

    # 状态机：2 安装 → 2 引导 → v3 耗尽 → v4 耗尽 → ENOSPC → vacuum → rescue
    # （vacuum/rescue 破坏性，收尾；vacuum 需 SSH，rescue 销毁会话）
    stage_v2_install
    stage_v2_boot
    stage_v3_exhaust
    stage_v4_exhaust
    stage_v5_enospc
    stage_vacuum
    stage_rescue

    echo ""
    echo "============================================================"
    echo "OTA 状态机测试全部通过"
    echo "============================================================"
}

main "$@"
