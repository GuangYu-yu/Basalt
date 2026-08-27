# Basalt

基于 [mkosi](https://mkosi.systemd.io/) v26 构建的 [Landscape](https://github.com/ThisSeanZhang/landscape) 路由器操作系统镜像。

不可变系统设计：EROFS 只读根 + overlayfs 增量层 + A/B 双槽原子更新，纯 UEFI（UKI）引导。

## 特性

- **不可变根**：root 分区为 EROFS（lz4hc 压缩），运行期改动经 overlayfs 落入 btrfs `/var`，重启即知哪些是系统、哪些是增量
- **A/B 原子更新**：systemd-sysupdate 按 SHA256SUMS 清单枚举版本，整分区写入 + PARTLABEL 版本簿记，更新失败不破坏当前槽位
- **UKI 引导**：内核 + initrd + cmdline 打包为单一 PE，cmdline 绑定版本化 PARTLABEL，与 sysupdate 簿记同源；systemd-boot 按版本排序自动切换启动项
- **声明式分区**：分区布局单一事实来源（`mkosi.repart/`），首启自动扩容（systemd-repart + growfs），ESP 尺寸按 UKI 实测大小自适应
- **声明式内核模块**：mkosi 原生 `KernelModules=`（上游默认集 + 显式意图条目），依赖闭包自动处理，CI 门禁校验关键模块在位
- **零秘钥烘焙**：machine-id / SSH host key 均不进镜像，首启生成并经 overlay 层持久化

## 环境要求

- Linux 宿主（mkosi 管线不支持 Windows/macOS 原生运行）
- `mkosi >= 26`、`qemu-img`、`xz`、`python3`、`curl`

```bash
sudo apt install mkosi qemu-utils xz-utils python3 curl
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
| `basalt.img.xz` | 磁盘镜像（dd 部署用） |
| `basalt.efi` | UKI（OTA 发布用，与镜像同版本） |
| `SHA256SUMS` | 发布清单（sysupdate 版本枚举依赖） |

常用参数：

```bash
./build.sh --include-docker true        # 纳入 Docker
./build.sh --version v1.2.3             # 发布构建（版本化产物名 + OTA 可枚举）
./build.sh --output-format img,vmdk,ova # 多格式导出
./build.sh --smoke                      # 构建后 QEMU 冒烟启动（Ctrl-A X 退出）
./build.sh --no-compress                # 保留 raw（本地测试需配合 RUN_TEST）
```

默认值集中在 `build.env`（版本、镜像 ID、尺寸、输出格式等），CLI 参数覆盖文件默认值。

## 系统布局

| 分区 | 文件系统 | 内容 |
|---|---|---|
| ESP | vfat | systemd-boot + 各版本 UKI |
| root A | EROFS | 当前系统（只读） |
| root B | EROFS | 更新槽位（空闲时为 `_empty`） |
| var | btrfs | 数据、日志、overlay 增量层 |

- **ESP**：systemd-boot + 各版本 UKI；尺寸 = 单 UKI 实测 × 槽位倍数（默认 3，下限 64M）
- **root A/B**：同角色双槽，槽位身份由 PARTLABEL 版本标签（`basalt_<版本>`）标识；B 槽首启扩容至可容纳一次完整更新
- **var**：btrfs（zstd:1 / noatime），承载 journald 日志、landscape 状态、overlay upper/work 层；首启扩满剩余空间

运行期挂载（fstab 单一事实）：

```
/        EROFS 只读（lowerdir）
/var     btrfs 独立分区
/        overlayfs 全根增量（upper=/var/lib/etc/upper, work=/var/lib/etc/work, nofail）
```

`nofail` 保证 overlay 挂载失败时退回只读根进入紧急模式，而非启动卡死。

## 更新机制

设备侧 `systemd-sysupdate.timer` 定时消费 `/usr/lib/sysupdate.d/` 定义：

1. 从发布 URL（`updates.example.com/basalt/`，需按部署环境修改）拉取 `SHA256SUMS` 枚举可用版本
2. 新版 root 镜像写入空闲槽，UKI 落入 ESP，完成后按 MatchPattern 给分区贴版本标签
3. systemd-boot 按版本排序，下次启动自动进入新版；旧版本条目保留在启动菜单中，即回滚路径

工厂镜像（`latest` 构建，槽位标签 `_1`）仅供 dd 部署；版本化构建（`--version vX`）的产物名与 MatchPattern 对应，参与 OTA。

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
| `check-initrd-modules.py` | 从 UKI 提取 initrd，断言关键模块在位 |

## CI

GitHub Actions 与本地共用同一入口 `build.sh`：

- `ci.yml` — push / PR / 手动触发，默认跑 readiness
- `custom-build.yml` — 自定义参数构建
- `release.yml` — 发布版本化产物
- 本地测试复用 `tests/`，无 CI 专属路径

## 目录结构

```
build.sh / build.env     构建入口与参数默认值
lib/export.sh            img/vmdk/ova 导出
mkosi/
  mkosi.conf             主配置（发行版/包/模块白名单/引导）
  mkosi.repart/          分区布局（单一事实来源）
  mkosi.sysupdate/       构建侧 sysupdate 定义
  mkosi.images/initrd/   initrd 子镜像（root overlay 挂载注入）
  mkosi.extra/           镜像内文件（fstab、服务、设备侧 repart/sysupdate 定义）
  mkosi.postinst.chroot  chroot 内安装动作
  mkosi.finalize         宿主侧收尾（machine-id 清理、strip、渲染）
tests/                   readiness / dataplane / 模块门禁
```

## 许可

见 [LICENSE](LICENSE)。