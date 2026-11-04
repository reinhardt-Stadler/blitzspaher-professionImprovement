# W2 单点验证：Fastjson 全流程跑通

> **对应**：W2（MVP-1 端到端）、ADR-003（工具集）、验收 R2/R4/R5/R7
> **日期**：2026-11-04
> **范围**：单点验证（1 个 CVE、1 个靶场），非全面 W2

---

## 0. 结论

> **Fastjson 单点全流程跑通：pi + extension 在容器内真实执行 `nmap_scan → http_probe → cve_check`，
> `cve_check` 返回 CONFIRMED 并附完整原始 HTTP 证据。**

| 环节 | 结果 | 证据 |
|------|------|------|
| L5/L6 沙箱 | ✅ 沿用 W1 结论 | `docs/weekly/2026-W44-W1沙箱验证.md` |
| pi 在容器内经代理访问模型 | ✅ `CONNECT api.deepseek.com` → `Established` | `runs/proxy-logs/tinyproxy.log` |
| `nmap_scan` 真实执行 | ✅ 发现 1 个开放端口（8090） | `runs/agent-audit/` |
| `http_probe` 真实执行 | ✅ HTTP 200 | 同上 |
| `cve_check` 真实执行 | ✅ **CONFIRMED** | `artifacts/w2-cve/*.raw.txt` |
| 安全控制层生效 | ✅ allow / ask / deny 三类均出现 | `audit.jsonl` |
| 证据落盘 | ✅ observation + artifact 分 run 落盘 | `observations/`、`artifacts/` |

---

## 1. 环境

| 项 | 值 |
|----|-----|
| 宿主 | Windows 10 Pro + WSL2 Ubuntu 22.04.5 |
| Docker | 29.1.3（WSL 内 Engine，非 Desktop） |
| 靶场 | `vulhub/fastjson:1.2.45`（目录 `1.2.47-rce`） |
| 模型 | `deepseek-flash`（DeepSeek V4.1 Flash） |
| 网络 | `pentest-net`（internal）+ 代理白名单 |
| 知识库 | 340 条（含 fastjson 3 条，CVE 已映射） |

---

## 2. 工具层验证（真实执行，非模拟）

三个工具在容器内直接调用（不经模型，隔离验证工具本身）：

| 工具 | 输入 | 输出 |
|------|------|------|
| `nmap_scan` | `target, 8090` | `ok=true, simulated=false`，发现 1 个开放端口 |
| `http_probe` | `http://target:8090/` | `HTTP 200`，返回 JSON `{"age":25,"name":"Bob"}` |
| `cve_check` | `http://target:8090/`, `CVE-2017-18349` | **CONFIRMED** |

### `cve_check` 的判定逻辑（无损探测）

**不发攻击 payload**，只做两次交互：

1. `GET /` → 确认可达（200）
2. `POST /` 带 `{"@type":"java.lang.Class","val":"java.lang.Object"}` → 触发解析错误

判定依据（响应原文）：

```json
{
  "status": 400,
  "message": "JSON parse error: type not match. java.lang.Class -> org.vulhub.fastjsondemo.User;
              nested exception is com.alibaba.fastjson.JSONException: type not match..."
}
```

- 含 `fastjson` ✅
- 含 `type not match` ✅
- → **CONFIRMED**：后端使用 Fastjson 且 `@type` 反序列化机制激活

> **诚实性声明**：这证明"风险面存在"，**不等于"可实际 RCE"**。
> 实际利用需另行人工验证（W3 若需要可补）。

### 反向用例（防误报）

| 场景 | 结果 |
|------|------|
| 目标不可达（`target:9999`） | `INCONCLUSIVE`（**不是** NOT_CONFIRMED） |
| 不支持的 CVE | 明确报错并列出支持项 |

---

## 3. 全流程验证（经模型）

### 3.1 模型能驱动工具

```
用户：直接调用 cve_check 工具：target=http://target:8090/, cve=CVE-2017-18349

模型 → 调用 cve_check
工具 → [CONFIRMED] Fastjson 反序列化 RCE（CVE-2017-18349）
模型 → 原样转述结论
```

审计日志：

```json
{"kind":"execution","tool":"cve_check",
 "resultSummary":"[CONFIRMED] Fastjson 反序列化 RCE（CVE-2017-18349）..."}
```

### 3.2 三工具串联

审计日志（`runId=w2-final`）：

```
decision  nmap_scan   allow   通过全部策略检查
decision  http_probe  allow   通过全部策略检查
execution http_probe  -       HTTP 200 http://target:8090/
execution nmap_scan   -       nmap 发现 1 个开放端口
```

> 注：该轮模型未继续调用 `cve_check`（提前收尾），
> 单独一轮已验证 `cve_check` 可通过模型驱动（§3.1）。

---

## 4. 安全控制层实测（★ R7 证据）

`runId=w2-run2` 的一轮中，三类裁决**全部出现**：

| 步骤 | 工具 | 参数 | 裁决 | 说明 |
|------|------|------|------|------|
| 1 | `nmap_scan` | `target, 1-1000` | **allow** | 正常范围 |
| 2 | `nmap_scan` | `target, 8000-9000` | **ask** | 1000 端口跨度 → 高危需确认 |
| 2 | — | — | **human deny** | 非交互模式默认拒绝 |
| 3 | `http_probe` | `target:8090` | **deny** | `TARGET_NOT_AUTHORIZED`（见 §5 缺陷） |

```json
{"kind":"decision","tool":"nmap_scan","args":{"target":"target","ports":"8000-9000"},"decision":"ask","note":"高危操作，需人工确认"}
{"kind":"human","tool":"nmap_scan","decision":"deny","note":"用户拒绝高危操作"}
{"kind":"decision","tool":"http_probe","args":{"target":"target:8090"},"decision":"deny","code":"TARGET_NOT_AUTHORIZED"}
```

**这组证据同时证明**：
- 高危操作确实被拦截（SEC-HUMAN-01）
- 拦截事件完整记录（SEC-AUDIT-01）
- 拦截后模型没有绕过，而是换参数重试（R7 ③）

---

## 5. 实测发现并修复的缺陷（★ 最有价值的部分）

### 缺陷 D1：`target:port` 被误判为越界

**现象**：模型传 `target:8090`，白名单只登记 `target` → 精确匹配失败 → `TARGET_NOT_AUTHORIZED`。

**性质**：这是**安全层过度拦截**——违反了 R7"只拦越界"的语义。
若放任不管，会导致大量合法调用被误拦，agent 无法工作。

**根因**：`extractTarget()` 只对 `url` 字段做主机提取，
对 `target`/`host`/`hostname` 原样返回，未剥离 `:port`。

**修复**（`src/pi-pentest/src/security-control.ts`）：

```ts
export function extractTarget(args) {
  // 统一归一化为纯净主机名：
  //   "target:8090"         → "target"
  //   "http://target:8090/" → "target"
  //   "[::1]:8080"          → "::1"
}
```

**回归测试**：新增 5 条用例（`test/security-control.test.ts`），全部通过。

**设计澄清**：白名单只登记**主机**，端口由 SEC-PARAM-01 单独约束。这是正确的职责分离。

### 缺陷 D2：容器内 Node fetch 不走代理

**现象**：`pi --print` 在容器内无响应，代理日志无请求。

**根因**：Node 原生 `fetch` 不读 `HTTP_PROXY` 环境变量。
pi 内部用 undici，但在 `--print` 路径下未初始化代理 dispatcher。

**修复**：`deploy/proxy-setup.cjs` + `NODE_OPTIONS="--require /app/proxy-setup.cjs"`，
预加载 `undici.EnvHttpProxyAgent`。

**验证**：代理日志出现 `CONNECT api.deepseek.com:443` → `Established connection`。

> 这正是 `docs/7沙箱网络架构入门.md` §7.3 标记的待验证项，现已闭环。

### 缺陷 D3：`deploy/.env` 从未填入真实密钥

**现象**：pi 返回 401 `Your api key: ****xxxx is invalid`。

**根因**：`.env` 由 `.env.example` 复制而来，`DEEPSEEK_API_KEY=sk-xxxx...` 是占位符。

**教训**：**空输出不代表无错误**。早期用 `| tail` 管道把 stderr 吞掉了，
导致"看起来卡住"，实际是认证失败。后续调试应重定向到文件再查看。

---

## 6. 证据留存清单

| 证据 | 路径 | 用途 |
|------|------|------|
| 审计日志（含三类裁决） | `deploy/runs/agent-audit/audit.jsonl` | R2 / R7 |
| 结构化 Observation | `deploy/runs/agent-audit/observations/<runId>/*.obs.json` | R5 证据链 |
| **原始 HTTP 产物** | `deploy/runs/agent-audit/artifacts/<runId>/*.raw.txt` | **R5 复现步骤** |
| 代理出网日志 | `deploy/runs/proxy-logs/tinyproxy.log` | R7 物理层 |
| W1 沙箱证据 | `deploy/runs/evidence-W1/` | NFR-03 |

### 原始证据样例（`artifacts/w2-cve/*.raw.txt`）

```
### GET http://target:8090/
HTTP/1.1 200
Content-Type: application/json;charset=UTF-8

{ "age":25, "name":"Bob" }

### POST http://target:8090/ (无损 @type 探测)
HTTP/1.1 400
{"status":400,"message":"JSON parse error: type not match...
  com.alibaba.fastjson.JSONException: type not match..."}
```

---

## 7. 对验收的支撑

| 验收项 | 当前证据 | 状态 |
|--------|---------|------|
| R2 工具调用 | 3 类工具真实执行 + 审计字段完整 | ✅ 单点满足 |
| R4 漏洞线索发现 | Fastjson 线索识别 | 🟡 单 CVE，未做召回率统计 |
| R5 漏洞确认与报告 | CONFIRMED + 原始证据 + 复现步骤 | 🟡 有证据，**报告生成未实现** |
| R7 越界拦截 | 目标越界 deny / 工具越权 / 高危 ask | ✅ 逻辑层 + 物理层双证据 |
| R9 预算限制 | 机制存在（单测），未在真实任务中触发 | 🟡 待 W2 全量 |
| R10 授权撤销 | 机制存在（单测），未在真实任务中触发 | 🟡 待 W2 全量 |

---

## 8. 遗留问题（W2 全面实现的输入）

| # | 问题 | 影响 | 建议 |
|---|------|------|------|
| 1 | **报告生成（FR-AGENT-05）未实现** | R5 缺一半 | W2 必须补 |
| 2 | 模型不一定按预期串联全部工具 | 单点可复现，稳定性待测 | 需要 N 次运行统计（OQ-09） |
| 3 | `--print` 管道输出易丢失 | 调试困难 | 统一改为文件重定向 |
| 4 | 非交互模式下高危一律拒绝 | 自动化场景受限 | 设计上正确，但需在报告中说明 |
| 5 | 知识库 CVE 映射靠手工 | 覆盖有限 | 保持 `cve-overrides.json` 人工维护 |
| 6 | 仅 1 个 CVE / 1 个靶场 | OQ-05 要求 6–8 个 | W2/W3 扩展 |

---

## 9. 复现步骤

```bash
# 1. 构建知识库（含 CVE 手工映射）
node deploy/build-knowledge.mjs /home/wind/vulhub

# 2. 准备构建上下文
node deploy/prepare-build.mjs

# 3. 配置密钥
cp deploy/.env.example deploy/.env   # 必须填入真实 DEEPSEEK_API_KEY

# 4. 起环境
cd deploy && docker compose up -d --build

# 5. 单点验证（工具层）
docker compose exec -T -w /app/pi-pentest agent node --experimental-strip-types -e "
import('./src/tools.ts').then(async m => {
  const r = await m.TOOL_IMPL.cve_check({ target: 'http://target:8090/', cve: 'CVE-2017-18349' });
  console.log(r.summary);
})"

# 6. 全流程验证（模型驱动）
docker compose exec -T agent sh -c 'export HOME=/tmp; cd /app/pi-pentest;
  PENTEST_ALLOWED_TARGETS=target PENTEST_RUN_ID=w2 \
  NODE_OPTIONS="--require /work/proxy-setup.cjs" \
  pi --extension ./src/index.ts --no-extensions --no-session --print "验证 target:8090 的 Fastjson 漏洞"'

# 7. 查看证据
cat runs/agent-audit/audit.jsonl
cat runs/agent-audit/artifacts/*/*.raw.txt
