# ota_lib.sh — OTA 测试库：VM 生命周期 / 串口 / SSH / 版本伪造 / 统一断言与取证
# 由 tests/test-ota.sh source（依赖 tests/common.sh 先行 source）。
#
# 产品契约与测试辅助的边界：
#   - 测试经产品路径驱动（systemctl start systemd-sysupdate.service →
#     10-images-rw wrapper → ota-prep / sysupdate / ota-select），不绕过
#   - /etc/sysupdate.d 注入 override 走产品支持的覆盖机制（/etc 优先于
#     /usr/lib），内容仅两处测试性：Verify=no（无签名链路）+ 本地源 URL
#
# 实证教训（保留背景，防回归）：
#   - 硬复位 = kill -9 QEMU（断电语义）：install 后必须 sync 刷盘，否则页缓存
#     中的新版本文件丢失（实测 v3 从未落盘、四轮全部引导 v2）
#   - warm reboot（SSH systemctl reboot）实测可能未执行；失败 boot 一律硬复位
#     承载；且 warm reboot 后新 boot 的串口输出可能丢失
#   - 串口签名是取证不是契约：实测会丢/迟到。boot counting 回退的判定以
#     SSH 可达 + bad 态文件存在为准（稳定契约），串口仅作取证与失败形态同步

# ── 串口 ──

SERIAL_GEN=0
ota_rotate_serial() {
    if [[ -f "${LANDSCAPE_ROUTER_SERIAL_LOG}" ]]; then
        SERIAL_GEN=$((SERIAL_GEN + 1))
        mv -f "${LANDSCAPE_ROUTER_SERIAL_LOG}" "${LANDSCAPE_ROUTER_SERIAL_LOG}.boot${SERIAL_GEN}"
    fi
}

ota_serial_offset() {
    [[ -f "${LANDSCAPE_ROUTER_SERIAL_LOG}" ]] && stat -c %s "${LANDSCAPE_ROUTER_SERIAL_LOG}" || echo 0
}

# 串口取证（非判定）：等待已知失败签名；命中返回 0、超时返回 1。仅在 if
# 上下文消费（调用点须 || true 或 if 包裹，防 set -e 终止）。测试断言不绑定
# 具体错误文本——签名只证明"boot 已进入失败阶段，可安全硬复位"
ota_serial_wait_evidence() {
    local pattern="$1" timeout="$2" offset="$3"
    local t0=${SECONDS}
    while (( SECONDS - t0 < timeout )); do
        if [[ -f "${LANDSCAPE_ROUTER_SERIAL_LOG}" ]] && \
           tail -c +$((offset + 1)) "${LANDSCAPE_ROUTER_SERIAL_LOG}" 2>/dev/null | grep -Eq "${pattern}"; then
            echo "[INFO] 失败签名取证（boot 已进入失败阶段）"
            return 0
        fi
        sleep 5
    done
    echo "[WARN] 未捕获失败签名（仅取证记录，不影响控制流）"
    dump_log_tail "${LANDSCAPE_ROUTER_SERIAL_LOG}" "router serial log"
    return 1
}

# 串口断言：仅用于"串口是唯一观察面"的 stage（rescue——sulogin 提示是
# rescue.target 的稳定产品行为，非偶然日志）
ota_serial_expect() {
    local pattern="$1" timeout="$2" offset="$3"
    local t0=${SECONDS}
    while (( SECONDS - t0 < timeout )); do
        if [[ -f "${LANDSCAPE_ROUTER_SERIAL_LOG}" ]] && \
           tail -c +$((offset + 1)) "${LANDSCAPE_ROUTER_SERIAL_LOG}" 2>/dev/null | grep -q "${pattern}"; then
            return 0
        fi
        sleep 5
    done
    error "串口 ${SERIAL_GEN} 轮内未出现: ${pattern}（${timeout}s）"
    dump_log_tail "${LANDSCAPE_ROUTER_SERIAL_LOG}" "router serial log"
    return 1
}

# ── VM 生命周期 ──

ota_start_vm() {
    ota_rotate_serial
    landscape_router_start_vm "${IMAGE_PATH}"
}

ota_hard_reset() {
    # 模拟看门狗硬复位：直接终止 QEMU（emergency 挂起时 ACPI 不被响应）。
    # 断电语义：调用方负责保证关键写入已 sync
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

# ── 断言 ──

ota_check() {
    local desc="$1"
    shift
    if "$@"; then
        echo "[PASS] ${desc}"
    else
        echo "[FAIL] ${desc}"
        exit 1
    fi
}

ota_check_fails() {
    # 断言命令必须失败（ENOSPC 探测等）；意外成功同样终止
    local desc="$1"
    shift
    if "$@" &>/dev/null; then
        echo "[FAIL] ${desc}（命令意外成功）"
        exit 1
    fi
    echo "[PASS] ${desc}"
}

# 安装后置契约：成对落盘（Result=success 是服务级结果，不保证资源落盘——
# 可能 no-op/未枚举/装错路径）+ sync（硬复位断电语义要求）
ota_assert_pair_landed() {
    local ver="$1"
    ota_check "v${ver} EROFS 落盘（${IMAGE_ID}_${ver}.erofs）" \
        guest_run "test -f /var/lib/basalt/images/${IMAGE_ID}_${ver}.erofs"
    ota_check "v${ver} UKI 落盘带 tries（${IMAGE_ID}_${ver}+${OTA_TRIES}-0.efi）" \
        guest_run "test -f /efi/EFI/Linux/${IMAGE_ID}_${ver}+${OTA_TRIES}-0.efi"
    guest_run "sync"
}

# 回退后置契约：boot（第 OTA_TRIES+1 次启动的 guest 引导完成）→ cmdline 绑定
# 回退目标 + bad 态文件 + API 恢复
ota_assert_fallback() {
    local ver="$1" to="$2"
    ota_wait_booted
    ota_check "回退到 v${to}（cmdline 镜像绑定）" \
        guest_run "grep -q 'basalt.image=${IMAGE_ID}_${to}.erofs' /proc/cmdline"
    ota_check "坏版本条目耗尽为 bad 态（${IMAGE_ID}_${ver}+0-${OTA_TRIES}.efi）" \
        guest_run "test -f /efi/EFI/Linux/${IMAGE_ID}_${ver}+0-${OTA_TRIES}.efi"
    # 轮询等待（TCG 下 landscape-webserver 启动 30s+，单发 curl 时序脆弱）
    wait_for_guest_command "回退后 API 恢复在线" 120 5 \
        guest_run "curl -skI --max-time 5 https://localhost:6443/ -o /dev/null"
    ota_check "回退后 API 恢复在线" \
        guest_run "curl -skI --max-time 5 https://localhost:6443/ -o /dev/null"
}

# ── 统一取证（仅失败路径调用：EXIT trap）──

ota_dump_forensics() {
    echo "=== [forensics] /proc/cmdline ===" >&2
    guest_run "cat /proc/cmdline" >&2 || true
    echo "=== [forensics] ESP /efi/EFI/Linux ===" >&2
    guest_run "ls -la /efi/EFI/Linux" >&2 || true
    echo "=== [forensics] bootctl list ===" >&2
    guest_run "bootctl list --no-pager 2>&1 | head -n 40" >&2 || true
    echo "=== [forensics] @images 清单与 ro 属性 ===" >&2
    guest_run "ls -la /var/lib/basalt/images 2>/dev/null; btrfs property get -ts /var/lib/basalt/images ro 2>/dev/null" >&2 || true
    echo "=== [forensics] sysupdate list ===" >&2
    guest_run "/usr/lib/systemd/systemd-sysupdate list --no-pager" >&2 || true
    echo "=== [forensics] journal systemd-sysupdate ===" >&2
    guest_run "journalctl -u systemd-sysupdate.service --no-pager -n 60" >&2 || true
    echo "=== [forensics] basalt-boot-health ===" >&2
    guest_run "systemctl status basalt-boot-health.service --no-pager -l 2>&1 | head -n 20" >&2 || true
    echo "=== [forensics] transfer 定义（/etc/sysupdate.d）===" >&2
    guest_run "cat /etc/sysupdate.d/*.transfer 2>/dev/null" >&2 || true
    dump_log_tail "${LANDSCAPE_ROUTER_SERIAL_LOG}" "router serial log"
}

# 统一失败出口：EXIT trap 按原始退出码一次性取证。bash 的 ERR trap 有控制流
# 例外（if/&& 上下文不触发），不能作唯一兜底；EXIT 保证必达且保留原退出码
ota_exit_handler() {
    local rc=$?
    trap - EXIT
    if (( rc != 0 )) && [[ "${OTA_VM_STARTED:-0}" == "1" ]]; then
        echo "[FAIL] 测试失败（rc=${rc}），统一取证：" >&2
        ota_dump_forensics
    fi
    [[ -n "${OTA_HTTP_PID:-}" ]] && kill "${OTA_HTTP_PID}" 2>/dev/null || true
    landscape_router_cleanup
    exit "${rc}"
}

# ── @images 只读窗口（btrfs 子卷属性；共享 superblock 下 remount,ro 必
#    EBUSY，见 fstab / 10-images-rw.conf 注释）──

ota_images_unlock() { guest_run "btrfs property set -ts /var/lib/basalt/images ro false"; }
ota_images_lock() { guest_run "btrfs property set -ts /var/lib/basalt/images ro true"; }

# ── 版本伪造（host 侧）──

ota_fabricate_uki() {
    local ver="$1" extra_cmdline="${2:-}" out="$3"
    local d="${FAB_DIR}/uki-${ver}"
    mkdir -p "${d}"
    local v1_uki="${PROJECT_DIR}/output/${IMAGE_ID}_${V1}.efi"
    [[ -f "${v1_uki}" ]] || { error "缺少工厂 UKI 工件: ${v1_uki}"; return 1; }

    objcopy -O binary --only-section=.linux   "${v1_uki}" "${d}/linux"
    objcopy -O binary --only-section=.initrd  "${v1_uki}" "${d}/initrd"
    local cmdline uname
    cmdline="$(objcopy -O binary --only-section=.cmdline "${v1_uki}" /dev/stdout | tr -d '\0')"
    uname="$(objcopy -O binary --only-section=.uname "${v1_uki}" /dev/stdout | tr -d '\0')"
    [[ -s "${d}/linux" && -s "${d}/initrd" && -n "${cmdline}" ]] || { error "UKI PE 段提取失败"; return 1; }

    # cmdline 换绑目标版本镜像（其余参数与工厂 UKI 逐字一致）
    cmdline="$(sed "s/${IMAGE_ID}_${V1}\.erofs/${IMAGE_ID}_${ver}.erofs/" <<<"${cmdline}")"
    [[ -n "${extra_cmdline}" ]] && cmdline="${cmdline} ${extra_cmdline}"

    # .osrel 独立生成（与 build.sh rescue 同一契约）：VERSION_ID == IMAGE_VERSION
    # == OTA 版本，是 systemd-boot Type 2 条目排序键。ukify --os-release=@PATH
    # 读文件（缺省回退构建宿主机 /etc/os-release——实测曾嵌入 Ubuntu 身份）
    cat > "${d}/osrel" <<EOF
ID=basalt
NAME="Basalt"
PRETTY_NAME="Basalt ${ver}"
VERSION_ID=${ver}
IMAGE_ID=${IMAGE_ID}
IMAGE_VERSION=${ver}
EOF

    ukify build \
        --linux="${d}/linux" \
        --initrd="${d}/initrd" \
        --os-release=@"${d}/osrel" \
        --uname="${uname}" \
        --cmdline="${cmdline}" \
        --output="${out}"
}

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

# 注入测试 override 到 /etc/sysupdate.d/（产品覆盖机制：/etc 优先于 /usr/lib）。
# 内容与设备侧模板同构，仅两处测试性差异：Verify=no（无签名链路）+ 本地源
# URL。Tries/InstancesMax 与 build.env 同源（设备侧渲染同源）
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
# @l/@d 通配：枚举时匹配任意计数状态（+3-0 全新 / 中间态 / +0-3 bad），
# 字面量形态曾致实例不可见 → 账目错乱 → 裁掉运行中版本（实测）
MatchPattern=${IMAGE_ID}_@v+@l-@d.efi ${IMAGE_ID}_@v.efi
TriesLeft=${OTA_TRIES}
TriesDone=0
InstancesMax=${INSTANCES_MAX}
EOF
)"
    guest_run "mkdir -p /etc/sysupdate.d"
    guest_run "echo ${root_b64} | base64 -d > /etc/sysupdate.d/70-root.transfer"
    guest_run "echo ${uki_b64} | base64 -d > /etc/sysupdate.d/80-uki.transfer"
}

# ── 更新执行（走产品路径：systemd-sysupdate.service → wrapper）──

ota_run_update() {
    # 完成判定：ExecMainExitTimestampMonotonic 相对启动前基线变化且 ActiveState
    # 离开 active/activating。仅凭 is-active 会与 --no-block 的任务入队竞态——
    # 单元尚未启动即返回 inactive，而从未运行的单元 Result 默认 success（实测
    # 假 PASS 根因）。属性逐一查询（多 -p 合并查询的输出顺序不可靠，实测错位）
    local pre
    pre="$(guest_run "systemctl show -p ExecMainExitTimestampMonotonic --value systemd-sysupdate.service" 2>/dev/null | tr -d '[:space:]')"
    guest_run "systemctl start --no-block systemd-sysupdate.service"
    local t0=${SECONDS} mono="" state="" result=""
    while (( SECONDS - t0 < 1800 )); do
        mono="$(guest_run "systemctl show -p ExecMainExitTimestampMonotonic --value systemd-sysupdate.service" 2>/dev/null | tr -d '[:space:]')"
        if [[ -n "${mono}" && "${mono}" != "0" && "${mono}" != "${pre}" ]]; then
            state="$(guest_run "systemctl show -p ActiveState --value systemd-sysupdate.service" 2>/dev/null | tr -d '[:space:]')"
            [[ "${state}" == "inactive" || "${state}" == "failed" ]] && break
        fi
        sleep 3
    done
    result="$(guest_run "systemctl show -p Result --value systemd-sysupdate.service" 2>/dev/null | tr -d '[:space:]')"
    printf '%s' "${result}"
}

# ── tries 耗尽引擎（boot counting 回退契约）──

ota_stage_exhaust() {
    # 契约：恰好 OTA_TRIES 次"真坏版本 boot"后 boot counting 回退。控制流不
    # 依赖串口（实测签名会丢/迟到）：每轮硬复位 → 等待签名（纯取证，窗口 =
    # 失败形态的自然耗时，同时保证 try 已消耗）→ SSH 探测（可达 = 旧版本
    # boot，v4 内网络全灭不可达）→ bad 态文件在列 = 真回退。
    # 轮次上限 = OTA_TRIES+1：容忍观测到的"install 后首次冷启动 selection
    # 落旧版本"浪费一次（根因未明；测试环境 EFI 变量挥发——QEMU 未挂 vars
    # pflash——ota-select 的 OneShot 天然无效，选择实际由 ESP 文件名排序承
    # 载）；浪费超过一次 = 固件反复选旧版本 = 产品 bug，测试应当失败暴露。
    local ver="$1" settle="$2" pattern="$3"
    local round sig=0 converged=0
    for round in $(seq 1 $((OTA_TRIES + 1))); do
        echo "---- 硬复位轮次 ${round}（v${ver} 失败 boot 收敛，sig=${sig}）----"
        ota_hard_reset
        local offset
        offset="$(ota_serial_offset)"
        if ota_serial_wait_evidence "${pattern}" "${settle}" "${offset}"; then
            sig=$((sig + 1))
            if [[ ${sig} -ge ${OTA_TRIES} ]]; then
                ota_hard_reset   # 第 OTA_TRIES+1 次启动：tries 耗尽 → 旧版本
                converged=1
                break
            fi
            continue
        fi
        # 无签名：SSH 探测（可达 = 旧版本 boot——真回退或浪费 boot）
        if wait_for_guest_command "SSH 探测（回退判别）" 120 10 guest_run "true"; then
            if guest_run "test -f /efi/EFI/Linux/${IMAGE_ID}_${ver}+0-${OTA_TRIES}.efi" 2>/dev/null; then
                converged=1   # bad 态在列 = OTA_TRIES 次已消耗，本 boot 即回退
                break
            fi
        fi
    done
    [[ ${converged} -eq 1 ]] && return 0
    return 1
}
