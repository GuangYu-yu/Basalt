# Basalt

基于 [mkosi](https://mkosi.systemd.io/) v26 构建的 [Landscape](https://github.com/ThisSeanZhang/landscape) 路由器操作系统镜像。

不可变系统设计：EROFS 只读根镜像以版本化文件承载 + overlayfs 全根增量层 + systemd-sysupdate 文件轮转原子更新，纯 UEFI（UKI）引导。

## 特性

- **不可变根**：系统本体为 EROFS 镜像文件（lz4hc 压缩，存于 btrfs `@os` 子卷），运行期改动经 overlayfs 落入共享增量层，重启即知哪些是系统、哪些是增量
- **文件轮转原子更新**：systemd-sysupdate 按版本号成对安装「EROFS 镜像 + UKI」两种资源（SHA256SUMS 清单枚举版本），中断最坏只留无入口的孤儿镜像，下次更新自动清理；无需 A/B 双 root 分区，稳态只占 1 份根镜像
- **版本配对构建期固化**：每个 UKI 的 cmdline 内嵌 `basalt.image=<版本化镜像名>`，任意可启动 UKI 的根镜像必然同版本存在——零运行期胶水守护
- **UKI 引导**：内核 + initrd + cmdline 打包为单一 PE；systemd-boot 按 UKI 文件名版本排序自动切换启动项，旧版本条目保留在菜单中即回滚路径；tries 计数耗尽自动落回次新版本
- **常驻 rescue 入口**：`basalt-rescue.efi`（同 kernel+initrd，cmdline 追加 `basalt.ro=1`）提供无增量层的纯只读根排障形态
- **声明式分区**：布局单一事实来源（`mkosi.repart/`，仅 ESP + var 两分区），首启自动扩容（systemd-repart + growfs），ESP 尺寸按 UKI 实测大小 × 版本保留深度自适应
- **声明式内核模块**：三层分治（base initrd / `KernelInitrdModules=` 启动链 / `KernelModules=` 数据面），CI 门禁按「required 子集 / forbidden 不相交」双契约校验
- **零秘钥烘焙**：machine-id / SSH host key 均不进镜像，首启生成并经 overlay 层持久化

## 环境要求

- Linux 宿主（mkosi 管线不支持 Windows/macOS 原生运行）
- `mkosi >= 26`、`qemu-img`、`xz`、`python3`、`curl`、`ukify`（systemd-ukify）+ PE stub（systemd-boot-efi）、`objcopy`（binutils）、`sfdisk`（util-linux）

```bash
sudo apt install mkosi qemu-utils xz-utils python3 curl \
  systemd-ukify systemd-boot-efi binutils util-linux
# apt 版本过旧时从源码安装固定版本
python3 -m pip install --break-system-packages \
  https://github.com/systemd/mkosi/archive/refs/tags/v26.tar.gz
```

## 快速开始

```bash
./build.sh
```

产物输出至 `output/`：

| 产物 | 说明 |
|---|---|
| `basalt.img.xz` | 工厂磁盘镜像（dd 部署用，仅 ESP + var 两分区） |
| `basalt_<v>.erofs.xz` | 版本化 EROFS 根镜像（OTA 分发形态，sysupdate 源） |
| `basalt_<v>.efi` | 版本化 UKI（OTA 入口点资源） |
| `SHA256SUMS` | OTA 产物完整性清单（sysupdate url-file 源的版本枚举契约） |

常用参数：

```bash
./build.sh --include-docker true        # 纳入 Docker
./build.sh --version v1.2.3             # 发布构建（绑定 landscape 发布版本）
./build.sh --output-format img,vmdk,ova # 多格式导出
./build.sh --smoke                      # 构建后 QEMU 冒烟启动（Ctrl-A X 退出）
./build.sh --no-compress                # 保留 raw（本地测试需配合 RUN_TEST）
```

默认值集中在 `build.env`（版本、镜像 ID、版本保留深度 `INSTANCES_MAX`、尺寸、输出格式等），CLI 参数覆盖文件默认值。

## 系统布局

| 分区 | 文件系统 | 内容 |
|---|---|---|
| ESP | vfat | systemd-boot + 各版本 UKI + 常驻 rescue UKI |
| var | btrfs | 唯一数据分区（`@os` 系统卷 + `@data` 数据卷） |

- **ESP**：systemd-boot + 版本化 UKI（带 `+3-0` tries 计数）+ rescue UKI；尺寸 = max(UKI) × (INSTANCES_MAX+1) + rescue 实测（+1 为更新瞬态，下限 64M）
- **var**（btrfs，zstd:1 / noatime）：
  - `@os` 子卷：`images/` 各版本 EROFS 镜像（0444）+ `overlay/` 全根增量层 upper/work（跨版本共享）；initrd 期即 sysroot
  - `@data` 子卷（默认卷）：journald 日志、landscape 状态等持久数据；首启扩满剩余空间

运行期挂载（fstab 单一事实）：

```
/                 overlayfs 全根（lower=版本化 EROFS 文件 loop 只读挂载，
                                    upper/work=@os overlay/，initrd 期组装）
/var              btrfs @data
/var/lib/basalt   btrfs @os（sysupdate 目标目录与运维访问）
/efi              ESP
```

overlay 组装失败进 initrd 紧急模式（无回退分支），由 rescue UKI / 串口 console 承接排障；rescue 形态（`basalt.ro=1`）跳过 overlay，纯只读 EROFS 根。

## 更新机制

设备侧 `systemd-sysupdate.timer` 定时消费 `/usr/lib/sysupdate.d/` 定义：

1. 从发布 URL（`updates.example.com/basalt/`，需按部署环境修改）拉取 `SHA256SUMS` 枚举可用版本
2. 按共同版本号成对安装：EROFS 镜像 → `/var/lib/basalt/images`（`@os`），UKI → ESP（入口点最后写，字母序保证）；各保留 `INSTANCES_MAX`（默认 3）份，当前运行版本受 `ProtectVersion=%A` 保护永不被清理
3. systemd-boot 按版本排序，下次启动自动进入新版（tries 计数 + `systemd-bless-boot` 健康确认）；更新中断的残留由下次调用自动清除

回滚 = 启动菜单选旧版本 UKI（其 cmdline 指向仍在 `@os` 的同版本镜像）。增量层跨版本共享（`/etc` 是当前状态而非版本属性），回滚后系统状态保持最新版本的累积结果。

工厂镜像（`latest` 构建，镜像版本恒为 `1`）仅供 dd 部署；版本化构建（`--version vX`）产出的 `basalt_<v>.erofs.xz` / `basalt_<v>.efi` 为 OTA 发布物。

## 测试

```bash
RUN_TEST=readiness ./build.sh --no-compress           # 启动 + 控制面就绪契约
RUN_TEST=readiness,dataplane ./build.sh --no-compress # 附加 LAN 内客户端 E2E
```

`tests/` 目录：

| 脚本 | 覆盖 |
|---|---|
| `test-readiness.sh` | SSH 可达、API 登录、网口/服务就绪契约 |
| `test-dataplane.sh` | 客户端 VM DHCP、租约入 API、LAN 互通 |
| `check-initrd-modules.py` | 两套工件（initrd + 裸 EROFS 根镜像）× 三态模块契约 |

## CI

GitHub Actions 与本地共用同一入口 `build.sh`：

- `ci.yml` — push / PR / 手动触发，默认跑 readiness
- `custom-build.yml` — 自定义参数构建
- `release.yml` — 发布版本化产物
- 本地测试复用 `tests/`，无 CI 专属路径

## 目录结构

```
build.sh / build.env     构建入口与参数默认值（两遍 mkosi 管线编排）
lib/export.sh            img/vmdk/ova 导出
mkosi/
  mkosi.conf             主配置（发行版/包/模块三层分治/引导）
  mkosi.repart/          分区布局（ESP + var，单一事实来源）
  mkosi.sysupdate/       构建侧 sysupdate 定义（mkosi sysupdate 动词）
  mkosi.images/initrd/   initrd 子镜像（overlay 组装 + 首启扩容定义）
  mkosi.extra/           镜像内文件（fstab、服务、设备侧 sysupdate 定义）
  mkosi.postinst.chroot  chroot 内安装动作
  mkosi.finalize         宿主侧收尾（machine-id 清理、strip、渲染）
tests/                   readiness / dataplane / 模块门禁
```

## 许可

见 [LICENSE](LICENSE)。