# =============================================================================
# Basalt 构建容器 — mkosi 管线的完整构建环境（构建流程容器化）
#
# 运行必须 --privileged：mkosi 以 root 执行 mount / loop 设备 / chroot
# （依赖 CAP_SYS_ADMIN 与 /dev/loop*，Docker 官方文档定义 --privileged 恰好
# 授予全 capabilities + 全设备访问）。mkosi 官方 Q&A（systemd/mkosi#4153）
# 确认 --privileged 容器内构建为受支持路径。
#
# CRLF 防御：仓库在 Windows 侧编辑，mkosi 脚本（shebang 解析）遇 CRLF 即
# 'sh\r' not found（同 #4153 根因）；行尾规范由 .gitattributes 强制。
# =============================================================================
FROM ubuntu:24.04

ARG MKOSI_VERSION=v26
ARG DEBIAN_FRONTEND=noninteractive

# 依赖集合与 build.sh require 断言清单同构（mkosi/qemu-img/xz/curl/python3/
# objcopy/ukify + PE stub）；erofs/btrfs mkfs 由 mkosi ToolsTree 自带，
# 不预焙进本镜像
RUN apt-get update && apt-get install -y --no-install-recommends \
        systemd-repart \
        systemd-ukify \
        systemd-boot-efi \
        qemu-utils \
        xz-utils \
        binutils \
        python3-pip \
        debian-archive-keyring \
        curl \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# mkosi 不发布 PyPI 包，从 GitHub tag 源码包安装（与 build.sh 的 >=26
# 硬断言同版本锚点，可经 --build-arg MKOSI_VERSION= 覆盖）
RUN python3 -m pip install --break-system-packages --no-cache-dir \
        "https://github.com/systemd/mkosi/archive/refs/tags/${MKOSI_VERSION}.tar.gz"

WORKDIR /src
