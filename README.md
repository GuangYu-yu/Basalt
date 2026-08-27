# Basalt

> 派生自 [Landscape](https://github.com/ThisSeanZhang/landscape) 的构建与测试体系，遵循 GPL-3.0（见 [LICENSE](LICENSE)）。

Debian Trixie + mkosi 全声明式构建：EROFS 只读根 + overlayfs 全根可写层、
repart 分区与首启扩容、UKI 纯 UEFI 引导、A/B 双槽 + systemd-sysupdate 原子更新。

## 本地构建

宿主要求：Linux + `mkosi>=27`（pip：`python3 -m pip install --break-system-packages mkosi`）
+ `qemu-utils` + `xz-utils`。

```bash
sudo ./build.sh                              # 构建 img（默认，xz 压缩）
sudo ./build.sh --smoke                      # 构建后 mkosi qemu 冒烟启动
sudo ./build.sh --include-docker true        # 附带 docker.io
sudo ./build.sh --output-format vmdk,ova     # 多格式（img 恒最后处理）
sudo ./build.sh --version v1.2.3             # 指定 Landscape 版本
RUN_TEST=readiness ./build.sh --no-compress  # 构建后跑 tests/ 全契约（需 raw）
```

产物：

| 产物 | 用途 |
|---|---|
| `basalt.img(.xz)` | dd 即用部署；首启 repart 自动扩容 |
| `basalt*.efi` | 版本化 UKI（cmdline 绑同版本 PARTLABEL），sysupdate OTA 用 |
| `output/metadata/build-metadata.txt` | CI 契约元数据 |

## 镜像架构（事实源索引）

| 事实 | 唯一声明点 |
|---|---|
| 分区布局/尺寸/GUID/UUID | `mkosi/mkosi.repart/`（构建期）；`mkosi/mkosi.extra/usr/lib/repart.d/`（首启扩容） |
| 槽位/版本身份 | GPT 分区标签 = `basalt_<版本>`（sysupdate 托管，`_empty` = 空槽）；设备侧 repart 定义按 Label 配对 |
| / 挂载 | initrd：`root=PARTLABEL=…`（erofs→/sysroot）+ `initrd-root-overlay.service` 叠 overlay；cmdline 的 root= 由 build.sh 按构建版本追加 |
| /var 挂载 | 30-var.conf `MountPoint=` 自动生成 fstab 条目（含 `x-systemd.growfs`） |
| ESP 挂载 | fstab `PARTLABEL=ESP /efi`（Label 声明于 `10-esp.conf`） |
| 引导顺序 | systemd-boot 按 UKI 文件名版本排序 = boot order 管理器 |
| 更新定义 | 设备侧 `mkosi.extra/usr/lib/sysupdate.d/`；构建侧 `mkosi.sysupdate/` |

A/B 语义：出厂 A 槽（标签 `_1`）有系统、B 槽空（`_empty`）；
首启 **initrd 内** systemd-repart 把 B 扩到与 A 槽实测一致、var 分区扩满
（两分区此时均未挂载，零在线风险）；sysupdate 把新版本写入空/旧槽并按
Target MatchPattern 贴版本标签，同时把版本化 UKI（cmdline 绑同版本标签）
写入 ESP（transfer 文件名序保证 UKI 最后写；tries 计数 `+3-0` 供
systemd-boot 连续失败自动回落）；systemd-boot 默认启动最新版本 = 更新后
自动切换；重复 update 同版本 = no-op；回滚 = 启动菜单选旧版本条目。

## 尺寸自适应（零魔数）

唯一的事实 = 构建产物实测值，常量只剩具名参数：

| 量 | 派生式 |
|---|---|
| ESP | max(单 UKI 实测) × `ESP_SLOTS`（默认 3） |
| B 槽 | A 槽分区实测大小（两槽同角色；build.sh 渲染进设备侧 91-root-b.conf） |
| 名义盘 | A×2 + ESP + var 构建值 × `IMAGE_HEADROOM`（默认 2）；`IMAGE_SIZE_MB` 显式设置时优先 |
| var 分区 | `Weight=100` 占满名义盘剩余 |
| root | `Minimize=guess` 按内容最小化 |

二遍构建：第一遍产出实测值 → 渲染 ESP/B 槽定义 → `mkosi -f build` 定稿
（包缓存/增量缓存生效，二遍代价小）。构建日志打印完整计算式。

## overlay 全根为何在 initrd 组装

fstab-generator 对 `/` 只生成 remount 语义，**真实根阶段无法把 erofs 的
`/` 换成 overlay**（且 overlay 根是双设备，fstab-generator 无法表达）；
OpenWrt/Android/overlayroot 均在 initramfs 阶段组装。实现 =
`mkosi.images/initrd/`（官方 root-verity.md 同范式）：initrd 内 repart 扩
分区 → `initrd-root-overlay.service` 挂 var 到 /run/var 并把 overlay 叠上
/sysroot → switch_root。失败时 Wants（非 Requires）语义退化为纯只读根
（nofail 兜底）。`/var` 由真实根 fstab（30-var.conf 的
MountPoint= 生成，含 `x-systemd.growfs`）挂载同一 btrfs 完成在线扩文件系统。

为什么不是"固件直连 UKI"：mkosi 的 UKI profiles 是"单 PE 多 `.profile` 段 +
Cmdline 追加"（mkosi 手册原文），直连固件只能启动基础 profile，无法做
版本/槽位选择，故引入 systemd-boot 仅作 boot order 管理器。

## 验证门禁（进 CI 默认矩阵前必须实测）

1. `--smoke`：`findmnt -T /` 显示 overlay（initrd-root-overlay 生效）；
   machine-id 提交成功；systemd-boot 默认项可启动。
2. `RUN_TEST=readiness`（`COMPRESS_OUTPUT=no`）：全契约绿。
3. 首启扩容：`lsblk` 验证 B 槽 = A 槽实测大小（自适应）、var 分区扩满；
   `btrfs filesystem usage /var` 验证文件系统已 growfs 扩展；journalctl -b
   查 initrd 阶段 systemd-repart / initrd-root-overlay 无失败。
4. sysupdate 实测（本地 file:// 源，`--version 2` 构建发布物）：A 槽部署 →
   模拟 update → B 槽（标签 `_2`）写入 → UKI v2（`+3-0` tries 后缀）落
   ESP → 重启自动进 v2 → overlay 配置保留 → 重复 update 同版本 no-op →
   菜单选 v1 回滚可启。

## CI 接入要点（合入主 .github 时）

- 构建入口 `./build.sh` 与本地完全一致；依赖安装改为
  `mkosi>=27`（pip）+ `systemd-repart` + `qemu-utils` + `xz-utils`。
- 产物上传路径补 `output/*.efi` 与 `output/SHA256SUMS`（设备侧 sysupdate
  url-file 源依赖发布目录中的 SHA256SUMS 枚举版本）。
- 设备侧 sysupdate 的 Source Path（`updates.example.com`）为占位 URL，
  由部署方替换为实际发布通道。
- `base_system` 选择收敛为仅 `debian`。
