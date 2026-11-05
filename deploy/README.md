# deploy/ —— L5/L6 沙箱与靶场部署

> 对应：ADR-004（沙箱 7 层）、W1（沙箱与靶场工作项）、W2（MVP-1 端到端）
> 设计说明：`../docs/7沙箱网络架构入门.md`（从零讲起，含架构图）

---

## 目录内容

```
deploy/
├── Dockerfile              ← agent 镜像（Ubuntu 22.04 + Node 24 + pi + nmap/curl）
├── docker-compose.yml      ← 三服务拓扑（agent / target / proxy）
├── .env.example            ← 环境变量模板
├── proxy/
│   ├── tinyproxy.conf      ← 代理配置（默认拒绝 + 域名白名单）
│   └── filter              ← 白名单规则（当前只有 DeepSeek / Moonshot）
├── build-knowledge.mjs     ← 知识库构建脚本（A 方案）
└── knowledge/
    └── generated/          ← 构建产物（340 个漏洞环境，不进 git）
        ├── index.json
        └── cve/*.md
```

---

## 网络拓扑（方案 2：出网代理白名单）

```
┌─ pentest-net (internal, 172.28.0.0/24) ──────────────────┐
│                                                          │
│   agent ──────────► target (Vulhub Fastjson)             │
│     │                                                    │
│     └──────────► proxy ──────────┐                       │
│                                  │                       │
└──────────────────────────────────┼───────────────────────┘
                                   │
                    ┌──────────────▼──────────────┐
                    │ outbound (172.29.0.0/24)    │
                    │  可出网，但只此一跳            │
                    └──────────────┬──────────────┘
                                   │
                        ┌──────────▼──────────┐
                        │ 白名单：             │
                        │ ✅ api.deepseek.com  │
                        │ ✅ api.moonshot.cn   │
                        │ 🚫 其他全部          │
                        └─────────────────────┘
```

**为什么不是双网卡**：双网卡会让 agent 直接拥有出网能力，等于没有隔离。
**为什么不是模型外置**：架构改动过大，超出 W1 时间盒（记录为 P3 演进项）。

详见 `../docs/7沙箱网络架构入门.md` §6。

---

## 快速开始

### 1. 准备知识库（A 方案，离线）

```bash
# 在 WSL 或 Windows 均可（只读文件，不联网）
node deploy/build-knowledge.mjs /home/wind/vulhub
# 或在 Windows 上：
node deploy/build-knowledge.mjs "\\\\wsl.localhost\\Ubuntu-22.04\\home\\wind\\vulhub"
```

产物：`deploy/knowledge/generated/`（约 1.7 MB，340 个漏洞环境）

### 2. 配置密钥

```bash
cp deploy/.env.example deploy/.env
# 编辑 deploy/.env，填入 DEEPSEEK_API_KEY
```

### 3. 启动

```bash
cd deploy
docker compose up -d --build

# 查看状态
docker compose ps
docker compose logs -f proxy     # 代理日志（ALLOW/DENY）
```

### 4. 进入 agent

```bash
docker compose exec agent bash
```

---

## 验证清单（每一步都留证据）

### V1 网络拓扑正确

```bash
docker network inspect blitzspaher_pentest-net --format '{{.Internal}}'
# 期望: true
```

### V2 agent → 靶场 连通（L6 正向）

```bash
docker compose exec agent curl -s -m 5 -i http://target:8090/ | head -5
# 期望: HTTP 200 + JSON 响应（Fastjson 环境）
```

### V3 agent → 公网 不通（L6 反向，★R7 物理层证据）

```bash
docker compose exec agent curl -s -m 8 https://www.baidu.com ; echo "退出码=$?"
# 期望: 失败（代理拒绝），退出码非 0
```

### V4 代理白名单放行模型 API

```bash
docker compose exec agent curl -s -m 10 -o /dev/null -w '%{http_code}\n' \
  https://api.deepseek.com/models
# 期望: 401（未带 key，但连接成功 = 代理放行）
```

### V5 代理拒绝非白名单

```bash
docker compose exec agent curl -s -m 8 https://api.github.com ; echo "退出码=$?"
# 期望: 失败
docker compose logs --tail 5 proxy     # 应有 DENY 记录
```

### V6 文件系统隔离（L5）

```bash
docker compose exec agent cat /etc/shadow ; echo "退出码=$?"
# 期望: Permission denied
docker compose exec agent touch /usr/bin/x ; echo "退出码=$?"
# 期望: Read-only file system
```

### V7 权限最小化（L5）

```bash
docker compose exec agent id
# 期望: uid=10001(agent)，非 root
docker compose exec agent capsh --print 2>/dev/null | head -3
# 期望: 无 capability
```

---

## 证据留存

| 文件 | 内容 | 对应验收 |
|------|------|---------|
| `runs/agent-audit/audit.jsonl` | 结构化审计（决策/执行/拦截） | R2 / R7 / R9 / R10 |
| `runs/agent-audit/observations/` | 结构化 Observation | R5 证据链 |
| `runs/agent-audit/artifacts/` | 工具原始产物 | R5 证据链 |
| `runs/proxy-logs/tinyproxy.log` | 出网 ALLOW/DENY | **R7 物理层** |
| `runs/agent-work/` | 工作目录（可放报告） | R5 |

---

## 常见问题

### Q: 靶场镜像拉不下来？

`vulhub/fastjson:1.2.47` 需要网络。替代方案：

```bash
# 用本地 vulhub 源码构建
cd /home/wind/vulhub/fastjson/1.2.47-rce
docker compose up -d          # 先手动起一次，确认镜像已有
docker tag vulhub_fastjson-1247 / 或用 compose 里的 build: 指向该目录
```

或修改 `docker-compose.yml` 中 target 服务为：

```yaml
target:
  build:
    context: /home/wind/vulhub/fastjson/1.2.47-rce
```

### Q: 代理不生效？

确认 agent 容器内环境变量：

```bash
docker compose exec agent env | grep -i proxy
```

### Q: 想临时查资料怎么办？

**不要放开代理白名单。** 走 A 方案：

```bash
node deploy/build-knowledge.mjs /home/wind/vulhub   # 扩充知识库
```

情报需求由 `lookup_knowledge` 工具读本地文件满足（W3a 实现）。

---

## 与 ADR 的对应

| 要求 | 落点 |
|------|------|
| ADR-004 L5 容器隔离 | `read_only` / `cap_drop: ALL` / 非 root / 资源限额 |
| ADR-004 L6 网络隔离 | `pentest-net: internal: true` + 代理白名单 |
| ADR-004 公网情报首版禁止 | `proxy/filter` 只放行两个模型 API |
| NFR-01 可重复性 | 靶场 `docker compose` 一条命令重置 |
| A 方案离线知识库 | `build-knowledge.mjs` + Dockerfile 拷入 `/knowledge/` |
