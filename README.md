# Basalt

基于 [mkosi](https://mkosi.systemd.io/)（自适应最新 release）构建的 [Landscape](https://github.com/ThisSeanZhang/landscape) 路由器操作系统镜像。

系统设计：btrfs **版本化部署子卷**（`root-basalt-<v>`，全根可写，A/B 即用即弃）+ systemd-sysupdate `url-tar → subvolume` 原子更新，纯 UEFI（UKI）引导。

## 特性

- **版本化部署子卷**：根文件系统为 var 分区（btrfs）内 `root-basalt-<v>` 子卷，按版本号排列，全根可写；更新即装新版本子卷，稳态最多两个部署共存（`InstancesMax=2`），即用即弃 A/B
- **原子更新**：systemd-sysupdate 按共同版本号成对安装「根载荷 `basalt_<v>.tar.xz`（url-tar → 新部署子卷）+ UKI `basalt_<v>.efi`（url-file → ESP）」，SHA256SUMS 清单枚举版本；更新中断由下次调用自动收敛，当前运行版本受 `ProtectVersion=%A` 保护永不被清理
- **版本配对构建期固化**：每个 UKI 的 cmdline 内嵌 `rootflags=subvol=root-basalt-<v>`，任意可启动 UKI 的部署子卷必然同版本存在——零运行期胶水守护
- **UKI 引导**：内核 + initrd + cmdline 打包为单一 PE；systemd-boot 按 UKI 文件名版本排序自动切换启动项，旧版本条目保留在菜单中即回滚路径；tries 计数耗尽自动落回次新版本
- **常驻 rescue 入口**：`basalt-rescue.efi`（同 kernel+initrd，cmdline `basalt.rescue=1`）由 initrd 钩子动态发现最高版本部署子卷挂载，提供只读应急维护形态
- **声明式分区**：布局单一事实来源（`mkosi.repart/`，仅 ESP + var 两分区），首启自动扩容（systemd-repart + growfs），ESP 尺寸按 UKI 实测大小 × 版本保留深度自适应
- **声明式内核模块**：三层分治（base initrd / `KernelInitrdModules=` 启动链 / `KernelModules=` 数据面），CI 门禁按「required 子集 / forbidden 不相交」双契约校验
- **零秘钥烘焙**：machine-id / SSH host key 均不进镜像，initrd bind mount + `basalt-state-init` 首启在 `@data` 持久化，跨版本稳定

## 环境要求

- Linux 宿主 + Docker（构建流程完全容器化；mkosi 需 root 执行 mount/loop/chroot，容器必须 `--privileged` 运行）
- 测试套件（QEMU）仍在宿主执行，依赖 `qemu-system-x86`、`ovmf`、`sshpass`、`socat`、`jq` 等（见 `tests/` 各脚本 preflight）；网络后端 `passt` 由 `tests/tools/passt/install.sh` 按固定 commit 构建

原生构建（不依赖 Docker）需自行满足：`mkosi >= 26`、`qemu-img`、`xz`、`python3`、`curl`、`unzip`、`ukify`（systemd-ukify）+ PE stub（systemd-boot-efi）、`objcopy`（binutils）：

```bash
sudo apt install mkosi qemu-utils xz-utils python3 curl unzip \
  systemd-ukify systemd-boot-efi binutils util-linux
# apt 版本过旧时从源码安装最新 release（Dockerfile 同此解析逻辑）
python3 -m pip install --break-system-packages \
  "https://github.com/systemd/mkosi/archive/$(curl -fsSLI -o /dev/null -w '%{url_effective}' https://github.com/systemd/mkosi/releases/latest | sed 's#.*/tag/#refs/tags/#').tar.gz"
```

## 快速开始

### 容器化构建（推荐）

```bash
docker build -t basalt-builder .
docker run --rm --privileged -v "${PWD}:/src" -w /src basalt-builder ./build.sh
```

容器以 root 构建，产物落在挂载的 `output/`（Linux 宿主上为 root 属主，需要时 `sudo chown -R "$(id -u):$(id -g)" output/ work/`）。

### 原生构建

```bash
./build.sh
```

`build.sh` 为两遍 mkosi 管线：pass1（`Format=tar`）直接产出 OTA 根载荷，pass2（`Format=disk`）组装工厂盘（ESP + var）。

产物输出至 `output/`：

| 产物 | 说明 |
|---|---|
| `basalt.img.xz` | 工厂磁盘镜像（dd 部署用，仅 ESP + var 两分区） |
| `basalt_<v>.tar.xz` | 版本化根载荷（OTA 分发形态，sysupdate url-tar 源） |
| `basalt_<v>.efi` | 版本化 UKI（OTA 入口点资源） |
| `SHA256SUMS` | OTA 产物完整性清单（sysupdate url-file 源的版本枚举契约） |

常用参数：

```bash
./build.sh --include-docker true         # 纳入 Docker
./build.sh --version v1.2.3              # 绑定 landscape 发布版本
./build.sh --image-version 3             # 镜像版本（发布构建双层身份 tag 的 image 段）
./build.sh --output-format img,vmdk,ova  # 多格式导出
./build.sh --smoke                       # 构建后 QEMU 冒烟启动（Ctrl-A X 退出）
./build.sh --no-compress                 # 保留 raw（本地测试需配合 RUN_TEST）
./build.sh --run-test readiness,ota      # 构建后本地跑测试套件
```

双层身份版本：landscape 版本 = 上游项目版本（`--version`）；镜像版本 = 不可变 OTA 单位版本（`--image-version`，纯数字，工厂构建恒 1）。发布 tag 为 `v<landscape>-<image>`（如 `v0.24.2-3`）。

默认值集中在 `build.env`（版本、镜像 ID、密码、尺寸、输出格式等），CLI 参数覆盖文件默认值。部署保留深度（`InstancesMax=2`）为架构常量，硬编码于 transfer 定义，不经 build.env 参数化。

OTA 发布源（设备侧 transfer 的 Source URL）默认从 `.git/config` 推导为当前仓库的 GitHub Releases `releases/latest/download/`，可用 `OTA_BASE_URL` 显式覆盖（自建源 / 无 .git 构建）。

## 系统布局

| 分区 | 文件系统 | 内容 |
|---|---|---|
| ESP | vfat | systemd-boot + 各版本 UKI + 常驻 rescue UKI |
| var | btrfs | 唯一数据分区（版本化部署子卷 + 载荷 + 数据） |

- **ESP**：systemd-boot + 版本化 UKI（带 `+3-0` tries 计数）+ rescue UKI；尺寸 = max(UKI) × (INSTANCES_MAX+1) + rescue 实测（+1 为更新瞬态，下限 64M）
- **var**（btrfs，zstd:1 / noatime）：
  - `@data` 子卷（默认卷）：journald 日志、设备身份（`/var/lib/basalt/state`：machine-id、SSH host key）、landscape 状态；首启扩满剩余空间
  - `@landscape` 子卷：应用载荷（landscape-webserver + static/ + 工厂默认 toml），与 root OTA 解耦独立更新
  - `root-basalt-<v>` 子卷：版本化根部署（btrfs 池顶层，由 sysupdate 原生创建；非运行版本 `basalt-deployments-readonly.service` 收敛为 ro 属性）

运行期挂载（fstab 单一事实）：

```
/efi                    ESP
/var                    btrfs @data
/var/lib/basalt/landscape  btrfs @landscape
/var/lib/basalt/pool    btrfs 池顶层（subvolid=5，sysupdate 部署子卷目标）
```

部署子卷切换失败（如坏版本 tries 耗尽）由 systemd-boot 自动回落旧版本；rescue 形态（`basalt.rescue=1`）由 initrd 钩子动态选择最高版本部署子卷挂载，经串口 console 承接排障。

## 更新机制

设备侧 `systemd-sysupdate.timer` 定时消费 `/usr/lib/sysupdate.d/` 定义：

1. 从 OTA 发布源（默认 GitHub Releases `latest/download/`，`SHA256SUMS` 版本枚举端点）获取可用版本
2. 按共同版本号成对安装：根载荷 `basalt_<v>.tar.xz`（url-tar → btrfs 池顶层新部署子卷 `root-basalt-<v>`），UKI → ESP（入口点最后写，字母序保证）；非运行版本自动 vacuum 清理，当前运行版本受 `ProtectVersion=%A` 保护永不被清理（`InstancesMax=2`）
3. systemd-boot 按版本排序，下次启动自动进入新版（tries 计数 + `systemd-bless-boot` 健康确认）；更新中断的残留由下次调用自动清除

回滚 = 启动菜单选旧版本 UKI（其 cmdline 指向仍存在的同版本部署子卷）。子卷模型下每个版本自带快照（含 /etc），回滚即整体切到旧版本部署，无共享增量层污染问题。

工厂镜像（`latest` 构建，镜像版本恒为 `1`）仅供 dd 部署；版本化构建（`--image-version N`）产出的 `basalt_<v>.tar.xz` / `basalt_<v>.efi` 为 OTA 发布物。

## 测试

```bash
RUN_TEST=readiness ./build.sh --no-compress           # 启动 + 控制面就绪契约
RUN_TEST=readiness,dataplane ./build.sh --no-compress # 附加 LAN 内客户端 E2E
RUN_TEST=ota ./build.sh --no-compress                 # OTA 更新矩阵（设计文档矩阵 2-7）
RUN_TEST=netstress ./build.sh --no-compress           # 网络后端稳定性回归
```

`tests/` 目录：

| 脚本 | 覆盖 |
|---|---|
| `test-readiness.sh` | SSH 可达、API 登录、网口/服务就绪契约、IMAGE_VERSION 运行期契约 |
| `test-dataplane.sh` | 客户端 VM DHCP、租约入 API、LAN 互通 |
| `test-ota.sh` | OTA 成对落盘与 bless、坏版本 tries 耗尽自动回退、`@data` 满盘降级、rescue 入口、vacuum 淘汰 |
| `test-net-stress.sh` | 网络后端（passt/slirp）长时间存活稳定性回归 |
| `release-smoke.sh` | 发布后真实 sysupdate list 验证 GitHub 发布源 |
| `check-initrd-modules.py` | 两套工件（initrd + OTA 根载荷 tar.xz）× 三态模块契约 |

`ota_lib.sh`、`local-runtime.sh`、`common.sh` 为共享测试库；`tools/passt/` 为网络后端依赖层（固定 commit 源码构建）。

## CI

GitHub Actions 与本地共用同一入口 `build.sh`：

- `ci.yml` — PR / 手动触发，默认跑 readiness（无 push 触发）
- `custom-build.yml` — 手动按参数构建专属镜像
- `release.yml` — 手动触发（CI 全绿后）→ 双变体构建 + 测试 + GitHub Release → 发布后 smoke
- `test.yml` — 镜像复测（对历史 CI 构建产物重测，不重建）
- 本地测试复用 `tests/`，无 CI 专属路径

## 目录结构

```
build.sh / build.env     构建入口与参数默认值（两遍 mkosi 管线编排）
Dockerfile               构建容器（依赖与 build.sh require 断言同构）
lib/export.sh            img/vmdk/ova 导出
mkosi/
  mkosi.conf             主配置（发行版/包/模块三层分治/引导）
  mkosi.repart/          分区布局（ESP + var，单一事实来源）
  mkosi.sysupdate/       构建侧 sysupdate 定义（mkosi sysupdate 动词）
  mkosi.images/initrd/   initrd 子镜像（repart 扩容 + 状态绑定/rescue 钩子）
  mkosi.extra/           镜像内文件（fstab、服务、设备侧 sysupdate 定义）
  mkosi.postinst.chroot  chroot 内安装动作
  mkosi.finalize         宿主侧收尾（machine-id 清理、strip、禁焙扫描）
tests/                   readiness / dataplane / ota / netstress / 模块门禁
```

## 许可

见 [LICENSE](LICENSE)。
