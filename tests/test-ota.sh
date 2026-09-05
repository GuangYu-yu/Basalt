#!/bin/bash
# =============================================================================
# Basalt — OTA / btrfs 部署子卷更新端到端状态机测试
# =============================================================================
#
# 显式状态机（每阶段：前置状态 → 操作 → 后置契约）：
#
#   stage_v2_install   前置: 工厂 v1 运行中（cmdline 子卷绑定/池部署契约/
#                      主 UKI 契约/设备身份基线）
#                      操作: sysupdate 安装 v2（url-tar → subvolume）
#                      契约: 成对落盘（root-basalt-2 子卷 + tries UKI）
#   stage_v2_boot      操作: 重启进 v2
#                      契约: cmdline 子卷绑定 + btrfs 根 + bless 去计数 +
#                            健康门 + 设备身份跨版本稳定（machine-id/ssh key）
#   stage_v3_exhaust   操作: 安装引导级坏版本（tar 内 init 清空——SHA256
#                      由清单重签，安装成功、引导必败）→ 硬复位承载失败启动
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
#                      契约: 动态发现根 + rescue shell（sulogin 上串口）+
#                            SSH 关闭
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
OTA_V1_MACHINE_ID=""                # 设备身份基线（v1 运行时采集，v2 断言不变）
OTA_V1_SSH_KEY_HASH=""
INSTANCES_MAX=2                     # 架构常量（与设备侧 transfer 模板同值）

# ── Stage 1：v2 安装 ──

stage_v2_install() {
    echo "== stage: v2 安装 =="
    # 前置状态：工厂 v1 运行中；工厂部署子卷在池顶层且真实为子卷；工厂主
    # UKI 命名契约（ESP 中唯一非 boot-count 主 UKI 恰为 ${IMAGE_ID}_${V1}.efi
    # ——sysupdate MatchPattern=@v 同源，构建侧 UnifiedKernelImageFormat 保证。
    # rescue 为连字符名，underscore 模式天然排除）
    ota_check "前置：工厂 v1 cmdline 子卷绑定" \
        guest_run "grep -q 'subvol=root-basalt-${V1}' /proc/cmdline"
    ota_check "前置：工厂 v1 部署为池内真实子卷" \
        guest_run "btrfs subvolume show /var/lib/basalt/pool/root-basalt-${V1} >/dev/null"
    local factory_uki="${IMAGE_ID}_${V1}.efi"
    local found_uki
    found_uki="$(guest_run "find /efi/EFI/Linux -maxdepth 1 -type f -name '${IMAGE_ID}_*.efi' ! -name '*+*' -printf '%f\n'")"
    ota_check "前置：工厂主 UKI 契约（${factory_uki}）" \
        test "${found_uki}" = "${factory_uki}"
    # 设备身份基线（@data state 跨版本持久契约的采集点）
    OTA_V1_MACHINE_ID="$(guest_run "cat /etc/machine-id")"
    OTA_V1_SSH_KEY_HASH="$(guest_run "sha256sum /var/lib/basalt/state/ssh/ssh_host_ed25519_key.pub" | awk '{print $1}')"
    ota_check "前置：machine-id 基线非空（bind 契约生效）" \
        test -n "${OTA_V1_MACHINE_ID}"

    # 操作：sysupdate 安装 v2（产品路径：service → wrapper → ota-prep/
    # sysupdate/ota-select）
    ota_fabricate_uki 2 "" "${FAB_DIR}/${IMAGE_ID}_2.efi"
    ota_serve_version 2 \
        "${PROJECT_DIR}/output/${IMAGE_ID}_${V1}.tar.xz" \
        "${FAB_DIR}/${IMAGE_ID}_2.efi"
    local result
    result="$(ota_run_update)"
    ota_check "sysupdate 安装成功（Result=${result}）" test "${result}" = "success"

    # 后置契约
    ota_assert_pair_landed 2
}

# ── Stage 2：v2 引导 + bless ──

stage_v2_boot() {
    echo "== stage: v2 引导 + bless =="
    # 硬复位承载（warm reboot 实测串口输出丢失——v2 boot 曾因此零观察面）；
    # 断电安全：安装侧 sync 已由 ota_assert_pair_landed 保证。OneShot EFI 变量
    # 随 QEMU 终止丢失，但 v2 为最高版本且带 tries，systemd-boot 默认排序仍选 v2
    ota_hard_reset
    ota_wait_booted
    ota_check "v2 cmdline 子卷绑定" \
        guest_run "grep -q 'subvol=root-basalt-2' /proc/cmdline"
    ota_check "根为 btrfs 部署子卷（FSTYPE + FSROOT）" \
        test "$(guest_run "findmnt -n -o FSTYPE /" 2>/dev/null | tr -d '[:space:]')" = "btrfs" -a \
              "$(guest_run "findmnt -n -o FSROOT /" 2>/dev/null | tr -d '[:space:]')" = "/root-basalt-2"
    # bless 在 boot-complete（= basalt-boot-health 成功）后去计数；轮询文件重命名
    wait_for_guest_command "bless 去计数" 240 5 \
        guest_run "test -f /efi/EFI/Linux/${IMAGE_ID}_2.efi"
    ota_check "bless 去计数（basalt_2.efi，无 tries 后缀）" \
        guest_run "test -f /efi/EFI/Linux/${IMAGE_ID}_2.efi"
    ota_check "健康门通过（API 就绪）" \
        guest_run "systemctl show -p Result --value basalt-boot-health.service | grep -qx success"
    # 设备身份跨部署稳定（initrd bind mount + state 目录的核心断言）
    ota_check "machine-id 跨版本不变（v1 → v2）" \
        test "$(guest_run "cat /etc/machine-id")" = "${OTA_V1_MACHINE_ID}"
    ota_check "SSH host key 跨版本不变（v1 → v2）" \
        test "$(guest_run "sha256sum /var/lib/basalt/state/ssh/ssh_host_ed25519_key.pub" | awk '{print $1}')" = "${OTA_V1_SSH_KEY_HASH}"
    OTA_RUNNING_VER=2
    # /etc 随部署子卷版本化——v1 内注入的 sysupdate override 不随版本切换
    # 存活（旧 overlay 时代"注入一次跨重启有效"的前提已失效）。后续 v3/v4/v5
    # 更新均发起于 v2，此处重注入（ProtectVersion=字面运行版本，须先置
    # OTA_RUNNING_VER=2 再注入）
    ota_inject_sysupdate_overrides
    # 更新过程串口可见化：sysupdate 输出默认只进 journal，SSH 死亡时（实测
    # v3 安装期 SSH 死 30 分钟、串口全静默）guest 内部不可观测。tee 到 console
    # 后串口承载下载/解包/裁剪旧版本全程 + 死亡时刻的最后输出（测试侧取证，
    # 不改产品默认行为）。/etc 属 v2，存活至 rescue 前的全部更新阶段
    guest_run "mkdir -p /etc/systemd/system/systemd-sysupdate.service.d && printf '[Service]\nEnvironment=SYSTEMD_LOG_LEVEL=debug\nStandardOutput=journal+console\nStandardError=journal+console\n' > /etc/systemd/system/systemd-sysupdate.service.d/10-console-tee.conf && systemctl daemon-reload"
    # 解锁全部 SysRq（Debian 默认掩码 438 不含 64=任务转储）：SSH 死亡时经
    # QEMU monitor sendkey 触发 SysRq-w/t 任务转储到串口——挂死调用点的
    # 决定性取证（D 状态任务 + 内核栈，不依赖任何 guest 网络）
    guest_run "echo 1 > /proc/sys/kernel/sysrq"
}

# ── Stage 3：引导级坏版本 → tries 耗尽 → 回退 ──

stage_v3_exhaust() {
    echo "== stage: v3 引导级坏版本（tar 内 init 清空）→ tries 耗尽 → 回退 =="
    # 冻结诊断轮：产品路径原样执行（不绕行 InstancesMax 裁剪——手动删除绕行
    # 曾使 update 成功，已实锤冻结在 sysupdate 内部裁剪路径）。本轮目的 =
    # 抓冻结前最后操作：SYSTEMD_LOG_LEVEL=debug 经 console-tee 直达串口 +
    # journal 持久化于 /var（@data），冻结 → 硬复位 → 回退 boot 健康后经
    # journalctl -b -1 读上一 boot 的完整 debug 日志（strace 需给产品根树加
    # 包且冻结时刷盘不保证，journal 是更可靠的等价取证）
    # 损坏注入：解包工厂 tar.xz → 清空 /usr/lib/systemd/systemd → 重打包。
    # SHA256SUMS 由 ota_serve_version 重签（损坏在内容不在安装）；init 为空
    # 文件 → switch_root exec 失败 → 引导必败。契约不绑定失败阶段
    #（switch_root 失败 / kernel panic 均为合法形态）
    ota_fabricate_uki 3 "" "${FAB_DIR}/${IMAGE_ID}_3.efi"
    ota_fabricate_corrupt_tar 3 \
        "${PROJECT_DIR}/output/${IMAGE_ID}_${V1}.tar.xz" \
        "${FAB_DIR}/${IMAGE_ID}_3.tar.xz"
    ota_serve_version 3 \
        "${FAB_DIR}/${IMAGE_ID}_3.tar.xz" \
        "${FAB_DIR}/${IMAGE_ID}_3.efi"
    local result
    result="$(ota_run_update)"
    if [[ "${result}" == "ssh-lost" ]]; then
        # 冻结复现（update 内部裁剪路径）：硬复位 → 回退 boot 健康（v1 完整
        # 在场，无悬空 UKI）→ 经 SSH 读冻结 boot 的持久化 journal（@data）
        echo "[INFO] 冻结复现：硬复位恢复后读冻结 boot 的 journal 取证"
        ota_hard_reset
        ota_wait_booted || { echo "[FAIL] 恢复 boot 未达 SSH" >&2; return 1; }
        echo "=== [forensics] 冻结 boot journal（sysupdate debug，-b -1）===" >&2
        guest_run "journalctl -b -1 --no-pager -n 400 2>/dev/null | grep -iE 'sysupdate|pull|btrfs|sigkill|freeze' || echo 'journal 上一 boot 无匹配（journald 未持久化？）'" >&2 || true
        echo "=== [forensics] 冻结 boot 全 journal 尾部 ===" >&2
        guest_run "journalctl -b -1 --no-pager -n 60 2>/dev/null || true" >&2 || true
        guest_run "sync" || true
        echo "[FAIL] 诊断轮：sysupdate 裁剪路径冻结（取证已收集，见上）" >&2
        return 1
    fi
    ota_check "坏版本安装成功（损坏在内容，不在安装）" test "${result}" = "success"
    ota_assert_pair_landed 3

    # 操作：OTA_TRIES 次失败 boot（硬复位承载）→ 契约：回退 v2。
    # 签名为取证非契约（不绑定失败阶段）：实测 init 清空的失败形态是 initrd
    # PID1 "Failed to execute /sbin/init → Freezing execution"（不 panic 不
    # switch root 报错，静默冻结）；panic/not syncing 为其他失败模式的合法形态
    ota_stage_exhaust 3 90 \
        "Failed to execute|Freezing execution|Kernel panic|Failed to switch root|not syncing" \
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
        "${PROJECT_DIR}/output/${IMAGE_ID}_${V1}.tar.xz" \
        "${FAB_DIR}/${IMAGE_ID}_4.efi"
    local result
    result="$(ota_run_update)"
    ota_check "v4 安装成功" test "${result}" = "success"
    ota_assert_pair_landed 4

    # settle=800s：健康门探测预算最长 60×(3s curl 超时 + 3s sleep)≈360s +
    # boot 时间（TCG 慢启动波动实测把签名推到 500s 窗口外——漏检轮次白耗
    # 预算且 sig 欠账，实测 4 轮仅 1 命中），窗口须覆盖慢路径上限
    ota_stage_exhaust 4 800 "API listener not ready" \
        || { echo "[FAIL] v4 tries 耗尽未收敛" >&2; return 1; }
    ota_assert_fallback 4 2
    ota_check "回退后健康门成功" \
        guest_run "systemctl show -p Result --value basalt-boot-health.service | grep -qx success"
}

# ── Stage 5：@data 塞满（ENOSPC 半状态可恢复）──

stage_v5_enospc() {
    echo "== stage: @data 塞满 → ENOSPC 半状态 → 清理重试 =="
    # 填满 /var（@data；btrfs 单一空间池与部署子卷共享 → 更新写入同样 ENOSPC）
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
        "${PROJECT_DIR}/output/${IMAGE_ID}_${V1}.tar.xz" \
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
        guest_run "grep -q 'subvol=root-basalt-2' /proc/cmdline"
    local before n_before
    before="$(guest_run "ls /var/lib/basalt/pool" 2>/dev/null || true)"
    n_before="$(grep -c "^root-basalt-[0-9][0-9]*\$" <<<"${before}" || true)"

    # 操作：vacuum（池顶层挂载 rw，无属性窗口——旧 @images 机制已废弃；
    # systemd-sysupdate bin 不在 PATH，全路径调用）
    if ! guest_run "/usr/lib/systemd/systemd-sysupdate vacuum"; then
        echo "[FAIL] vacuum 失败" >&2
        return 1
    fi

    # 后置契约：发生裁剪 + 受保护版本（运行版本）永在 + 深度 ≤ InstancesMax+1
    # + rescue UKI 不动
    local after ukis n_after
    after="$(guest_run "ls /var/lib/basalt/pool" 2>/dev/null || true)"
    ukis="$(guest_run "ls /efi/EFI/Linux" 2>/dev/null || true)"
    n_after="$(grep -c "^root-basalt-[0-9][0-9]*\$" <<<"${after}" || true)"
    ota_check "vacuum 发生裁剪（部署子卷 n=${n_before} → ${n_after}）" \
        test "${n_after}" -lt "${n_before}"
    ota_check "受保护版本部署存在（运行版本 v${OTA_RUNNING_VER}）" \
        grep -q "^root-basalt-${OTA_RUNNING_VER}\$" <<<"${after}"
    ota_check "部署实例数 ≤ InstancesMax+1（保护版本可额外保留）" \
        test "${n_after}" -le $(( INSTANCES_MAX + 1 ))
    ota_check "vacuum 不动 rescue UKI" \
        grep -q "${IMAGE_ID}-rescue.efi" <<<"${ukis}"
    ota_check "受保护版本 UKI 存在" \
        grep -q "^${IMAGE_ID}_${OTA_RUNNING_VER}\.efi\$" <<<"${ukis}"
}

# ── Stage 7：rescue（破坏性，最后）──

stage_rescue() {
    echo "== stage: rescue（手动入口 → 动态发现根 + rescue shell）=="
    # 经 EFI Boot Loader Interface 枚举可用条目并锁定 rescue。
    # rescue UKI cmdline 无 root=：initrd basalt-rescue-select 动态发现最高
    # 版本部署子卷挂为 /sysroot（rescue.target 完整用户空间应急）
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

    if ! require_commands qemu-system-x86_64 sshpass curl socat jq awk truncate objcopy ukify python3 xz base64 zstd tar; then
        error "Install test dependencies: sudo apt install qemu-system-x86 ovmf sshpass socat jq systemd-ukify binutils zstd"
        exit 2
    fi

    if ! ensure_local_ports_free "${SSH_PORT}" "$(landscape_bootstrap_ssh_port)" "${OTA_SERVER_PORT}"; then
        exit 2
    fi

    source "${PROJECT_DIR}/build.env"   # IMAGE_ID（部署保留深度为架构常量 2）
    load_landscape_topology || exit 2
    landscape_router_init_paths "ota"

    landscape_load_test_identity "${IMAGE_PATH}" || true
    landscape_write_test_metadata "${IMAGE_PATH}"

    V1="$(sed -n 's/^image_version=//p' "${PROJECT_DIR}/output/metadata/build-metadata.txt" | tr -d '[:space:]')"
    [[ -n "${V1}" ]] || { error "build-metadata.txt 缺少 image_version"; exit 2; }
    local v1_tar="${PROJECT_DIR}/output/${IMAGE_ID}_${V1}.tar.xz"
    local v1_uki="${PROJECT_DIR}/output/${IMAGE_ID}_${V1}.efi"
    [[ -f "${v1_tar}" && -f "${v1_uki}" ]] || {
        error "缺少 OTA 原料工件（${v1_tar} / ${v1_uki}）；CI 需将 *.tar.xz/*.efi 纳入构建 artifact"
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
