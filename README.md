<div align="center">

# Basalt

**为 [Landscape Router](https://github.com/ThisSeanZhang/landscape) 构建系统镜像**

btrfs 版本化 A/B 部署 · systemd-sysupdate 原子 OTA · UKI 引导 · 失败自动回滚

[![Release](https://img.shields.io/github/v/release/GuangYu-yu/Basalt?sort=semver)](https://github.com/GuangYu-yu/Basalt/releases/latest)
[![License](https://img.shields.io/badge/license-GPL--3.0-blue)](LICENSE)

</div>

---

更新一个路由器操作系统，不需要重刷整盘：sysupdate 拉取新版本，装为新子卷 `root-basalt-N` 与新 UKI，重启自动进入。健康门通过则转正为稳定版本；失败则 tries 耗尽后自动回退到上一稳定版本。

系统本体 = btrfs 单池多子卷：每个版本是完整的独立根（含 /etc），旧版本只读冻结；
landscape 走独立载荷子卷更新，与系统互不牵连。

## 快速开始

```bash
# 构建（容器化，Docker 需 --privileged）
docker build -t basalt-builder .
docker run --rm --privileged -v "${PWD}:/src" -w /src basalt-builder ./build.sh

# 部署
dd if=output/basalt.img of=/dev/sdX bs=4M status=progress
```

构建参数：`--version`（上游版本）· `--image-version`（OTA 单位版本）· `--output-format img,vmdk,ova` · `--smoke`。完整说明：`./build.sh --help`。

## 默认值

| 项 | 值 |
|---|---|
| SSH / 系统登录 | `root` / `landscape` |
| Web UI | `root` / `root` |
| LAN 段 | 192.168.10.1/24（DHCP 池 .2~.254） |
| Web 端口 | HTTPS 6443 / HTTP 6300 |

## 测试

QEMU 全矩阵：readiness（启动链）· dataplane（LAN E2E）· ota（更新/回退/盘满/rescue）· netstress（网络后端稳定性），CI 每次推送执行：

```bash
RUN_TEST=readiness,ota ./build.sh --no-compress
```

## 许可

[GPL-3.0](LICENSE)