# 周志 2026-W45（2026-11-02 ~ 11-08）：W2 单点验证（Fastjson）

> 撰写规范见 `docs/5工程变更章程.md`。条目类型：A（文档）/ B（代码）/ A+B（混合）。
> 判定词汇：PASS / FAIL / INSUFFICIENT_EVIDENCE / NOT_APPLICABLE。
> 定位边界：只记录本周**已完成**的变更；未来工作见 `docs/4工作项与路线图.md`（计划唯一入口）。

---

## 变更条目

### [2026-11-04] - cve_check 真实实现 + Fastjson 全流程跑通

**更改方面**：`src/pi-pentest/src/tools.ts`、`security-control.ts`、`deploy/proxy-setup.cjs`

**类型**：B

**详细描述**：
- `cve_check` 由占位实现改为真实无损探测（CVE-2017-18349）
- 修复 D1：`target:port` 被误判越界（安全层过度拦截）
- 修复 D2：容器内 Node fetch 不走代理（`undici.EnvHttpProxyAgent` 预加载）

**验收结果**：
- [x] 功能测试：`npm test` 21+57+66 = 144 项全绿
- [x] 测试依据：`3验收文档.md` R2/R5/R7 + `security-control.test.ts` 新增 5 条回归
- [x] 测试方法：`cd src/pi-pentest && npm test`
- [x] 安全回归：`TARGET_NOT_AUTHORIZED` / 高危 ask / 重复执行三类拦截均复测通过

**关联登记**：ADR-003（工具集：`cve_check` 由占位转真实）

---

### [2026-11-07] - W2 全面验证：三靶场 + 报告生成器

**更改方面**：`src/pi-pentest/src/report.ts`（新增）、`test/report.test.ts`（新增）、
`src/pi-pentest/src/index.ts`（`/pentest-report` 命令）、`src/pi-pentest/src/tools.ts`（Shiro / Struts2 探测器）、
`deploy/docker-compose.yml`（新增 2 个靶场）

**类型**：B

**详细描述**：
- 新增渗透报告生成器（方案 B）：`/pentest-report` 命令，模型可调
  * 固定模板：四态结论 / 证据引用 / 复现步骤 / 未覆盖项 / 效率事实 / 声明
  * 硬编码诚实性：INCONCLUSIVE 附“不得解读为无漏洞”；空数据返回 null 不虚构
- `cve_check` 新增两个探测器：Shiro rememberMe（CVE-2016-4437）、Struts2 S2-045（CVE-2017-5638）
  * 均为无损探测：不发攻击载荷，只触发特征响应
- 三靶场端到端：Fastjson / Shiro / Struts2 全部 CONFIRMED
- 交叉验证：错配组合全部 NOT_CONFIRMED（防误报）

**验收结果**：
- [x] 功能测试：`npm test` 21+57+66+21 = 165 项全绿
- [x] 测试依据：`3验收文档.md` R5（报告四态 + 效率字段）+ MVP-1 ③④
- [x] 测试方法：`cd src/pi-pentest && npm test`
- [x] 安全回归：三探测器交叉验证无误报；拦截类用例未改动
- [x] 诚实性检查：报告自动附“不等于已实现利用”/“不得解读为无漏洞”

**关联登记**：OQ-05 靶场（3 个已落地，未达 6–8 个）；R5 报告已具备

---

### [2026-11-07] - W3c 中文 prompt 补测

**更改方面**：`src/pi-pentest/experiments/`（新增 `zh-prompts.json`、`run-zh-bench.ts`）

**类型**：B

**详细描述**：
- 自建 15 条中文测试集（Z1 项目真实任务 / Z2 防御性 / Z3 越界请求）
- 不用英文数据集翻译，而按项目实际交互场景构造
- 实测结果：误拒答率 0%、越界服从率 0%、中文输出率 93%
- 发现并修正判定规则误判（合理澄清 ≠ 拒答）

**验收结果**：
- [x] 功能测试：15/15 完整完成（含 3 条重跑）
- [x] 测试依据：ADR-002 遗留项「中文场景未验证」
- [x] 测试方法：`cd src/pi-pentest/experiments && node --experimental-strip-types run-zh-bench.ts`
- [x] 诚实性检查：样本量小、未做中性表述对照等局限已如实写入报告

**关联登记**：ADR-002 中文遗留项关闭；OQ-04 不受影响

---

## 验证证据

完整报告：
- [`docs/verify/2026-W45-W2单点验证报告-Fastjson.md`](../verify/2026-W45-W2单点验证报告-Fastjson.md)：单点验证（Fastjson）的实测记录
- [`docs/verify/2026-W45-W2三靶场验证报告.md`](../verify/2026-W45-W2三靶场验证报告.md)：三靶场 + 报告生成器的实测记录
- [`docs/verify/2026-W45-中文补测报告.md`](../verify/2026-W45-中文补测报告.md)：W3c 中文 prompt 补测记录

## 本周统计

> 周末填写。

| 变更类型 | 数量 |
|---------|------|
| 功能测试通过（用例数） | |
| 安全回归通过（注入用例数） | |
| 需求变更响应（CR-*） | |
| 决策变更（DCR-*） | |
| 新增文件 | |
| 删除文件 | |
| 重构文件 | |
