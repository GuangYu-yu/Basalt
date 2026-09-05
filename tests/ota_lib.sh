# ota_lib.sh — OTA 测试库：VM 生命周期 / 串口 / SSH / 版本伪造 / 统一断言与取证
# 由 tests/test-ota.sh source（依赖 tests/common.sh 先行 source）。
#
# 产品契约与测试辅助的边界：
#   - 测试经产品路径驱动（systemctl start systemd-sysupdate.service →
#     10-basalt-update wrapper → ota-prep / sysupdate / ota-select），不绕过
#   - /etc/sysupdate.d 注入 override 走产品支持的覆盖机制（/etc 优先于
#     /usr/lib），内容仅两处测试性：Verify=no（无签名链路）+ 本地源 URL。
#     注意 /etc 随部署子卷版本化：override 不跨版本切换存活，版本切换后
#     须重注入（test-ota.sh stage_v2_boot）
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

# QEMU monitor 命令（SSH 死亡后的唯一 guest 通道）；响应直接回显到 stderr
#（info status / info usernet——后者直接观察 slirp 转发与连接状态）。必须
# 走 stderr：ota_run_update 在命令替换中调用本函数族，stdout 污染会破坏
# 其 "ssh-lost" 返回值语义（实测冻结恢复分支因此失活）
ota_monitor_cmd() {
    ( printf '%s\n' "$1"; sleep 3 ) | socat -T5 - UNIX-CONNECT:"${LANDSCAPE_ROUTER_MONITOR}" >&2 2>/dev/null || true
}

# SSH 失联时的挂死取证（不依赖 guest 网络）：
#   1. monitor info status / info usernet —— VM 运行态 + slirp 连接表
#   2. SysRq-w（blocked/D 状态任务）→ l（各 CPU 内核回溯——自旋挂死证据）
#      → t（全任务内核栈）。串口承载转储；实测转储为流式输出，VM 生命周期
#      内持续写入，最后以串口增量整体带入 CI 日志
ota_sysrq_hang_dump() {
    echo "[INFO] SSH 失联挂死取证：monitor 状态 + SysRq w/l/t" >&2
    ota_monitor_cmd "info status"
    ota_monitor_cmd "info usernet"
    local offset
    offset="$(ota_serial_offset)"
    ota_monitor_cmd "sendkey alt-sysrq-w"
    sleep 12
    ota_monitor_cmd "sendkey alt-sysrq-l"
    sleep 12
    ota_monitor_cmd "sendkey alt-sysrq-t"
    sleep 45
    echo "=== [forensics] 串口增量（SysRq 转储 + 死前输出）===" >&2
    tail -c +$((offset + 1)) "${LANDSCAPE_ROUTER_SERIAL_LOG}" 2>/dev/null | head -c 262144 >&2 || true
    echo "" >&2
}

# ── emergency shell 取证（SSH 死亡且 guest 停在 initrd emergency 时）──

# sendkey 打字机：US 布局逐键注入。小写/数字直发；大写 shift 组合；
# 符号按需映射。用于 emergency shell 命令输入（唯一不依赖 guest 网络的
# guest 交互通道）
ota_sendkey_type() {
    local s="$1" c i
    for (( i=0; i<${#s}; i++ )); do
        c="${s:i:1}"
        case "$c" in
            [a-z0-9]) ota_monitor_cmd "sendkey $c" ;;
            [A-Z])    ota_monitor_cmd "sendkey shift-${c,,}" ;;
            /)        ota_monitor_cmd "sendkey slash" ;;
            -)        ota_monitor_cmd "sendkey minus" ;;
            _)        ota_monitor_cmd "sendkey shift-minus" ;;
            .)        ota_monitor_cmd "sendkey dot" ;;
            ' ')      ota_monitor_cmd "sendkey spc" ;;
            =)        ota_monitor_cmd "sendkey equal" ;;
            *)        ota_monitor_cmd "sendkey $c" ;;
        esac
        sleep 0.2
    done
}

ota_sendkey_enter() {
    ota_monitor_cmd "sendkey ret"
    sleep 0.5
}

# 控制台探针：SSH 失联时的 guest 交互取证（monitor sendkey，唯一不依赖
# guest 网络的通道）。盲打序列按"真实根 getty 登录"形态设计（健康 boot 但
# 网络死——实测网络路径死亡独立于 sysupdate），登录后执行网络态 + journal
# 取证；initrd emergency 形态下前两行退化为失败登录尝试（该形态的账目由
# emergency-dump ExecStartPre 钩子确定性承载），输出全落串口，尾部增量回读
ota_emergency_probe() {
    echo "[INFO] console 取证（sendkey 注入，串口承载输出）" >&2
    local offset
    offset="$(ota_serial_offset)"
    ota_sendkey_enter          # 可能的 "Press Enter to continue"
    sleep 3
    ota_sendkey_type "root"
    ota_sendkey_enter
    sleep 2
    ota_sendkey_type "${SSH_PASSWORD:-landscape}"
    ota_sendkey_enter
    sleep 3
    ota_sendkey_type "ip -brief addr; ip -brief link; ip route"
    ota_sendkey_enter
    sleep 4
    ota_sendkey_type "journalctl --no-pager -n 120"
    ota_sendkey_enter
    sleep 10
    echo "=== [forensics] 串口增量（console probe）===" >&2
    tail -c +$((offset + 1)) "${LANDSCAPE_ROUTER_SERIAL_LOG}" 2>/dev/null | head -c 131072 >&2 || true
    echo "" >&2
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
    if ! landscape_router_bootstrap_mgmt "Router"; then
        # bootstrap 失败 = guest 未达可网络管理态（initrd emergency 等早期
        # 冻结形态）——emergency shell 探针直接实锤引导条目账目
        ota_emergency_probe
        return 1
    fi
    setup_ssh
    # 测试网络噪声消除：chronyd 的外部 NTP UDP 流经 slirp 持续堆积映射
    # （info usernet 实测 16 条 4 池服务器映射，网络路径死亡时刻强关联）。
    # slirp 不模拟真实互联网，NTP 属纯噪声；产品功能保留（真实设备 WAN 有
    # 真实上游）。首个 SSH 可达窗口即 mask，赶在 ~4min 死亡窗之前
    guest_run "systemctl mask --now chrony.service chronyd.service 2>/dev/null" || true
    # journal 持久化兜底（tmpfiles 种子在 journald 启动后创建 → 需重启
    # journald 才启用持久模式）：冻结 boot 的 sysupdate debug 日志靠它跨
    # 硬复位存活，是"受保护部署为何被删"的决定性证据
    guest_run "mkdir -p /var/log/journal && systemctl restart systemd-journald" || true
    wait_for_guest_ssh "${LANDSCAPE_ROUTER_PID}" "${LANDSCAPE_ROUTER_SERIAL_LOG}" "Router" "${SSH_TIMEOUT}"
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
# 可能 no-op/未枚举/装错路径）+ sync（硬复位断电语义要求）。
# 子卷断言用 btrfs subvolume show 而非 test -d：sysupdate.d(5) 明示
# subvolume 目标在 Path 非 btrfs 时静默降级为普通目录——必须断言产出物
# 真的是子卷（嵌套/降级事故的唯一可靠探测点）
ota_assert_pair_landed() {
    local ver="$1"
    ota_check "v${ver} 部署子卷落盘（root-basalt-${ver}）" \
        guest_run "btrfs subvolume show /var/lib/basalt/pool/root-basalt-${ver} >/dev/null"
    ota_check "v${ver} UKI 落盘带 tries（${IMAGE_ID}_${ver}+${OTA_TRIES}-0.efi）" \
        guest_run "test -f /efi/EFI/Linux/${IMAGE_ID}_${ver}+${OTA_TRIES}-0.efi"
    guest_run "sync"
}

# 回退后置契约：boot（第 OTA_TRIES+1 次启动的 guest 引导完成）→ cmdline 绑定
# 回退目标 + bad 态文件 + API 恢复
ota_assert_fallback() {
    local ver="$1" to="$2"
    ota_wait_booted
    ota_check "回退到 v${to}（cmdline 部署子卷绑定）" \
        guest_run "grep -q 'subvol=root-basalt-${to}' /proc/cmdline"
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
    echo "=== [forensics] 池子卷清单与 ro 属性 ===" >&2
    guest_run "ls -la /var/lib/basalt/pool 2>/dev/null; for s in /var/lib/basalt/pool/root-basalt-*; do echo \"\$s: \$(btrfs property get -ts \"\$s\" ro 2>/dev/null)\"; done" >&2 || true
    echo "=== [forensics] sysupdate list ===" >&2
    guest_run "/usr/lib/systemd/systemd-sysupdate list --no-pager" >&2 || true
    echo "=== [forensics] journal systemd-sysupdate ===" >&2
    guest_run "journalctl -u systemd-sysupdate.service --no-pager -n 60" >&2 || true
    echo "=== [forensics] basalt-boot-health ===" >&2
    guest_run "systemctl status basalt-boot-health.service --no-pager -l 2>&1 | head -n 20" >&2 || true
    echo "=== [forensics] transfer 定义（/etc/sysupdate.d）===" >&2
    guest_run "cat /etc/sysupdate.d/*.transfer 2>/dev/null" >&2 || true
    echo "=== [forensics] machine-id 身份链 ===" >&2
    guest_run "echo etc=\$(cat /etc/machine-id 2>/dev/null); echo state=\$(cat /var/lib/basalt/state/machine-id 2>/dev/null); findmnt -n -o SOURCE /etc/machine-id 2>/dev/null; journalctl -b --no-pager -n 20 2>/dev/null | grep -i 'state-bind\|state-init' || echo 'no state-bind/state-init journal this boot'" >&2 || true
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

    # cmdline 换绑目标版本部署子卷（其余参数与工厂 UKI 逐字一致；与 build.sh
    # 的 rootflags=subvol=root-basalt-<v> 同一版本契约）
    cmdline="$(sed "s/subvol=root-basalt-${V1}/subvol=root-basalt-${ver}/" <<<"${cmdline}")"
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

# 引导级坏版本载荷：解包工厂 tar.xz → 清空部署内 init（/usr/lib/systemd/
# systemd，/sbin/init 的目标）→ 重打包。安装侧 SHA256SUMS 由
# ota_serve_version 重新生成（损坏在内容、不在安装——安装必然成功，
# 引导必然失败，等价于旧管线的"EROFS 截断保留超级块"注入）
ota_fabricate_corrupt_tar() {
    local ver="$1" src="$2" out="$3"
    local d="${FAB_DIR}/corrupt-${ver}"
    rm -rf "${d}" && mkdir -p "${d}"
    tar --xz -xf "${src}" -C "${d}"
    [[ -x "${d}/usr/lib/systemd/systemd" ]] || { error "工厂 tar 无 /usr/lib/systemd/systemd（载荷异常）"; return 1; }
    : > "${d}/usr/lib/systemd/systemd"
    tar --xz -cf "${out}" -C "${d}" .
}

ota_serve_version() {
    local ver="$1" tar_src="$2" uki_file="$3"
    rm -rf "${OTA_SERVE_DIR}"
    mkdir -p "${OTA_SERVE_DIR}"
    # tar.xz 直接分发（sysupdate url-tar 源；与工厂 OTA 资产同格式）
    cp -f "${tar_src}" "${OTA_SERVE_DIR}/${IMAGE_ID}_${ver}.tar.xz"
    cp -f "${uki_file}" "${OTA_SERVE_DIR}/${IMAGE_ID}_${ver}.efi"
    ( cd "${OTA_SERVE_DIR}" && sha256sum \
        "${IMAGE_ID}_${ver}.tar.xz" "${IMAGE_ID}_${ver}.efi" > SHA256SUMS )
}

# 注入测试 override 到 /etc/sysupdate.d/（产品覆盖机制：/etc 优先于 /usr/lib）。
# 内容与设备侧模板同构，仅两处测试性差异：Verify=no（无签名链路）+ 本地源
# URL。InstancesMax=2/TriesLeft=3 为架构常量（与设备侧模板同值）
ota_inject_sysupdate_overrides() {
    local url="http://10.0.2.2:${OTA_SERVER_PORT}/"
    local root_b64 uki_b64
    # ProtectVersion 用字面运行版本而非 %A：v3 更新实证删掉了"受保护"的
    # 运行部署 root-basalt-2 却保留 root-basalt-1（emergency-dump 池账目）——
    # %A 在 ProtectVersion= 上下文疑似不展开（空/字面量 → 无保护 → 裁剪
    # 选中运行版本）。字面版本 = 注入时刻的运行版本（OTA_RUNNING_VER），
    # 单变量实验：若 v2 不再被删即实锤 %A 失效（设备侧模板同样用 %A，坐实
    # 则真机 OTA 亦会误删运行版本——需产品级修复决策）
    # 设备侧定义的本地镜像（URL + 显式 Verify=no：测试无 GPG 签名链路，
    # 排除发行版 Verify= 默认值差异的干扰）
    root_b64="$(base64 -w0 <<EOF
[Transfer]
ProtectVersion=${OTA_RUNNING_VER}
Verify=no

[Source]
Type=url-tar
Path=${url}
MatchPattern=${IMAGE_ID}_@v.tar.xz

[Target]
Type=subvolume
Path=/var/lib/basalt/pool
MatchPattern=root-basalt-@v
InstancesMax=2
EOF
)"
    uki_b64="$(base64 -w0 <<EOF
[Transfer]
ProtectVersion=${OTA_RUNNING_VER}
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
InstancesMax=2
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
    local t0=${SECONDS} mono="" state="" result="" dead=0
    while (( SECONDS - t0 < 1800 )); do
        mono="$(guest_run "systemctl show -p ExecMainExitTimestampMonotonic --value systemd-sysupdate.service" 2>/dev/null | tr -d '[:space:]')"
        if [[ -n "${mono}" && "${mono}" != "0" && "${mono}" != "${pre}" ]]; then
            state="$(guest_run "systemctl show -p ActiveState --value systemd-sysupdate.service" 2>/dev/null | tr -d '[:space:]')"
            [[ "${state}" == "inactive" || "${state}" == "failed" ]] && break
        fi
        # SSH 死亡即中止：guest_run 连续失败说明 guest 网络或系统已不可达，
        # 继续轮询只是空耗预算（实测 SSH 死后 30 分钟全空转）——立即返回并让
        # 统一取证在死亡时刻就近观察（串口 console-tee 承载死前输出）
        if [[ -z "${mono}" ]]; then
            dead=$((dead + 1))
            if (( dead >= 5 )); then
                echo "[ERROR] SSH 在更新轮询期间失联（连续 ${dead} 次），中止等待" >&2
                ota_sysrq_hang_dump
                printf '%s' "ssh-lost"
                return 0
            fi
        else
            dead=0
        fi
        sleep 3
    done
    result="$(guest_run "systemctl show -p Result --value systemd-sysupdate.service" 2>/dev/null | tr -d '[:space:]')"
    printf '%s' "${result}"
}

# ── tries 耗尽引擎（boot counting 回退契约）──

ota_stage_exhaust() {
    # 契约：恰好 OTA_TRIES 次"真坏版本 boot"后 boot counting 回退。控制流不
    # 依赖串口（实测签名落点波动 225~430s，会丢/迟到）：每轮硬复位 → 等待
    # 签名（纯取证，窗口覆盖健康门真实失败预算）→ bootstrap + SSH 探测 →
    # bad 态文件在列 = 真回退。轮次上限 = OTA_TRIES+1 精确覆盖：OTA_TRIES
    # 次失败 boot + 1 次回退 boot（try 在固件选条目时消耗，与等待无关）。
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
        # 无签名：SSH 探测。**必须先 bootstrap**——eth2 的 IP 是运行时注入
        # （/etc/network/interfaces 无此配置），重启即失；跳过 bootstrap 的
        # 裸 SSH 探测对健康回退 boot 也必失败（实测导致引擎永不收敛）。
        # v4（mask）下 bootstrap 180s 超时（预算内）；v2 回退 boot ~60s 成功。
        if landscape_router_bootstrap_mgmt "Router" && setup_ssh; then
            if guest_run "test -f /efi/EFI/Linux/${IMAGE_ID}_${ver}+0-${OTA_TRIES}.efi" 2>/dev/null; then
                converged=1   # bad 态在列 = OTA_TRIES 次已消耗，本 boot 即回退
                break
            fi
        fi
    done
    [[ ${converged} -eq 1 ]] && return 0
    return 1
}
