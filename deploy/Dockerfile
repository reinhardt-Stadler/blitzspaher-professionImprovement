# syntax=docker/dockerfile:1
#
# agent 镜像：pi-pentest 运行环境
#
# 设计对应 ADR-004 L4/L5：
#   L4 工具层：内置 nmap / curl（execFile 调用，不拼 shell）
#   L5 容器层：非 root、只读 rootfs 友好（可写点仅 /work、/tmp、/app/audit）
#
# 网络：本镜像内**不配置任何出网**，出网由 compose 的代理白名单控制（L6）
#
# 构建：
#   docker build -t blitzspaher-agent:0.1 deploy/
#
# 知识库（A 方案）：
#   /knowledge/index.json + /knowledge/cve/**  由 deploy/build-knowledge.mjs 生成，
#   构建时通过 `--build-context` 或预生成目录挂入；缺省为空索引（工具会明确报"未收录"）。

FROM ubuntu:22.04

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ENV DEBIAN_FRONTEND=noninteractive \
    NODE_VERSION=24.18.1 \
    TZ=Asia/Shanghai

# ── 基础工具 + 渗透工具（L4）──────────────────────────────────
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl gnupg xz-utils jq \
      nmap \
      whois \
      dnsutils \
      netcat-openbsd \
 && rm -rf /var/lib/apt/lists/*

# ── Node.js（pi 的运行环境）──────────────────────────────────
RUN ARCH="$(dpkg --print-architecture)" \
 && case "$ARCH" in \
      amd64) NODE_ARCH=x64 ;; \
      arm64) NODE_ARCH=arm64 ;; \
      *) echo "unsupported arch: $ARCH" >&2; exit 1 ;; \
    esac \
 && curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${NODE_ARCH}.tar.xz" -o /tmp/node.tar.xz \
 && tar -xJf /tmp/node.tar.xz -C /usr/local --strip-components=1 \
 && rm /tmp/node.tar.xz \
 && node --version && npm --version

# ── pi-coding-agent ─────────────────────────────────────────
RUN npm install -g @earendil-works/pi-coding-agent@1.2.0 \
 && pi --version || true

# ── 非 root 用户（L5）────────────────────────────────────────
RUN groupadd -g 10001 agent \
 && useradd -m -u 10001 -g agent -s /bin/bash agent

# ── 应用代码 ────────────────────────────────────────────────
# 构建上下文为 deploy/；src/pi-pentest 由 prepare-build.mjs 拷入 ./pi-pentest/
WORKDIR /app
COPY --chown=agent:agent pi-pentest/ /app/pi-pentest/

# ── 代理引导（L6 必选）─────────────────────────────────────
# Node 原生 fetch 不读 HTTP_PROXY；pi 内部用 undici，需显式安装
# EnvHttpProxyAgent 才能走代理。经 NODE_OPTIONS 预加载。
COPY --chown=agent:agent proxy-setup.cjs /app/proxy-setup.cjs

# ── 知识库（A 方案：离线，无网络）─────────────────────────────
# 由 build-knowledge.mjs 生成 → prepare-build.mjs 拷入 ./knowledge-ctx/
# 若未生成，prepare-build 会自动创建空索引
COPY --chown=agent:agent knowledge-ctx/ /knowledge/

RUN set -eux; \
    mkdir -p /knowledge; \
    if [ ! -f /knowledge/index.json ]; then \
      echo '{"generatedAt":null,"source":"empty","entries":[]}' > /knowledge/index.json; \
    fi; \
    mkdir -p /work /app/pi-pentest/audit; \
    chown -R agent:agent /work /app/pi-pentest/audit /knowledge

# ── 运行用户 ────────────────────────────────────────────────
USER agent

# ── 运行期环境变量（可被 compose 覆盖）────────────────────────
ENV NODE_ENV=production \
    PENTEST_ALLOWED_TARGETS=target \
    PENTEST_MAX_CALLS=12 \
    PENTEST_MAX_RUNTIME_MS=600000 \
    PENTEST_ARM=on \
    KNOWLEDGE_DIR=/knowledge \
    # 出网必须经代理（L6）；代理地址由 compose 注入
    HTTP_PROXY= \
    HTTPS_PROXY= \
    NO_PROXY=localhost,127.0.0.1,target \
    # 预加载 undici 代理 dispatcher（否则 Node fetch 直连，内网无 DNS 出口）
    NODE_OPTIONS="--require /app/proxy-setup.cjs"

# 可写点（配合 compose 的 read_only: true 使用）
VOLUME ["/work", "/app/pi-pentest/audit"]

WORKDIR /work

# 健康检查：确认 pi 与工具可用（不触网）
HEALTHCHECK --interval=30s --timeout=10s --start-period=10s --retries=3 \
  CMD node --version >/dev/null && pi --version >/dev/null && command -v nmap >/dev/null || exit 1

# 默认入口：交互式 pi（由 compose 覆盖）
ENTRYPOINT ["pi"]
CMD ["--help"]
