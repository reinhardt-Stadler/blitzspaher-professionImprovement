#!/usr/bin/env node
/**
 * 知识库构建脚本（A 方案：离线知识库）
 *
 * 从 Vulhub 目录提取每个漏洞环境的 README，生成结构化索引与正文。
 * 产物：deploy/knowledge/generated/
 *   ├── index.json          ← 检索索引（cve_id / component / title / 关键词）
 *   └── cve/<slug>.md       ← 正文（中文优先，回退英文）
 *
 * 设计依据：
 *   - ADR-004：公网情报通道首版禁止 → 用离线知识库替代
 *   - A+D 方案：知识库本身不联网；D 方案为未来受限工具预留结构化接口
 *
 * 用法：
 *   node deploy/build-knowledge.mjs /home/wind/vulhub
 *   docker build --build-arg 时把 deploy/knowledge/generated 作为 knowledge/ 上下文
 *
 * 注意：本脚本在**宿主机/WSL** 运行，不在容器内运行（不需要出网）。
 */

import { readdirSync, readFileSync, writeFileSync, mkdirSync, existsSync, statSync } from "node:fs";
import { join, dirname, relative, basename } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const OUT_DIR = join(__dirname, "knowledge", "generated");
const OUT_CVE = join(OUT_DIR, "cve");
const OVERRIDES_PATH = join(__dirname, "cve-overrides.json");

// ── 手工 CVE 映射（补充自动提取不到的）──────────────────────
let overrides = {};
if (existsSync(OVERRIDES_PATH)) {
  try {
    overrides = JSON.parse(readFileSync(OVERRIDES_PATH, "utf8"));
    delete overrides._comment;
    console.log(`已加载手工映射: ${Object.keys(overrides).length} 条`);
  } catch (e) {
    console.warn(`⚠ 映射表解析失败，忽略: ${e.message}`);
  }
}

// ── CVE 编号识别 ──────────────────────────────────────────────
const CVE_RE = /CVE-\d{4}-\d{4,7}/i;
const S2_RE = /\bs2-0\d{2}\b/i;   // Struts2 的 s2-xxx 编号

/** 从目录路径与 README 标题中推断结构化元信息 */
function analyze(vulhubRoot, dirPath) {
  const rel = relative(vulhubRoot, dirPath).replace(/\\/g, "/");
  const parts = rel.split("/");
  if (parts.length < 2) return null;          // 顶层目录（如 fastjson/）跳过

  const component = parts[0];                  // fastjson / shiro / log4j ...
  const variant = parts.slice(1).join("/");    // 1.2.47-rce / CVE-2016-4437

  // 读取 README（中文优先）
  let body = null, lang = null, title = null;
  for (const [name, l] of [["README.zh-cn.md", "zh"], ["README.md", "en"]]) {
    const p = join(dirPath, name);
    if (existsSync(p)) {
      body = readFileSync(p, "utf8");
      lang = l;
      const m = body.match(/^#\s+(.+)$/m);
      title = m ? m[1].trim() : null;
      break;
    }
  }
  if (!body) return null;

  // CVE 编号：优先手工映射 → 目录名 → 标题 → 正文
  const cveFromPath = variant.match(CVE_RE)?.[0];
  const cveFromBody = body.match(CVE_RE)?.[0];
  const cveFromTitle = title?.match(CVE_RE)?.[0];
  const override = overrides[rel];
  const cve =
    (override?.cve || cveFromPath || cveFromTitle || cveFromBody || "").toUpperCase() || null;
  const cveConfidence = override ? override.confidence ?? "manual" : cve ? "exact" : null;
  const s2 = variant.match(S2_RE)?.[0] ?? title?.match(S2_RE)?.[0] ?? null;

  // 版本线索（从目录名提取，如 1.2.47-rce → 1.2.47）
  const verMatch = variant.match(/^(\d+\.\d+(?:\.\d+)?)/);

  return {
    slug: `${component}__${variant.replace(/[^A-Za-z0-9._-]/g, "_")}`,
    path: rel,
    component,
    variant,
    cve,
    cveConfidence,
    cveNote: override?.note ?? null,
    s2: s2 ? s2.toLowerCase() : null,
    version: verMatch ? verMatch[1] : null,
    title,
    lang,
    bytes: Buffer.byteLength(body, "utf8"),
    body,
  };
}

/** 递归找出所有含 README 的漏洞目录 */
function walk(root, dir, out) {
  let entries;
  try { entries = readdirSync(dir, { withFileTypes: true }); } catch { return out; }
  const hasReadme = entries.some(
    (e) => e.isFile() && (e.name === "README.md" || e.name === "README.zh-cn.md"),
  );
  // 只在"二级及以下且含 README"的目录视为漏洞环境
  const rel = relative(root, dir);
  if (hasReadme && rel && rel.split(/[\\/]/).length >= 2 && !rel.includes("node_modules")) {
    out.push(dir);
  }
  for (const e of entries) {
    if (e.isDirectory() && !["node_modules", ".git", "images"].includes(e.name)) {
      walk(root, join(dir, e.name), out);
    }
  }
  return out;
}

// ── 主流程 ────────────────────────────────────────────────────
const root = process.argv[2];
if (!root) {
  console.error("用法: node deploy/build-knowledge.mjs <vulhub 根目录>");
  console.error("例如: node deploy/build-knowledge.mjs /home/wind/vulhub");
  process.exit(1);
}
if (!existsSync(root)) {
  console.error(`目录不存在: ${root}`);
  process.exit(1);
}

console.log(`扫描: ${root}`);
const dirs = walk(root, root, []);
console.log(`发现 ${dirs.length} 个漏洞环境目录`);

mkdirSync(OUT_CVE, { recursive: true });

const entries = [];
let skipped = 0;
for (const d of dirs) {
  const info = analyze(root, d);
  if (!info) { skipped++; continue; }
  writeFileSync(join(OUT_CVE, `${info.slug}.md`), info.body, "utf8");
  const { body, ...meta } = info;
  entries.push(meta);
}

// 统计
const withCve = entries.filter((e) => e.cve).length;
const withS2 = entries.filter((e) => e.s2).length;
const zhCount = entries.filter((e) => e.lang === "zh").length;
const components = [...new Set(entries.map((e) => e.component))];

const index = {
  generatedAt: new Date().toISOString(),
  source: root,
  counts: {
    entries: entries.length,
    withCve,
    withS2,
    zh: zhCount,
    en: entries.length - zhCount,
    components: components.length,
  },
  components: components.sort(),
  entries,
};
writeFileSync(join(OUT_DIR, "index.json"), JSON.stringify(index, null, 1), "utf8");

console.log("");
console.log("=== 构建完成 ===");
console.log(`条目: ${entries.length}（跳过 ${skipped}）`);
console.log(`含 CVE 编号: ${withCve}`);
console.log(`含 Struts2 编号: ${withS2}`);
console.log(`中文正文: ${zhCount} / 英文: ${entries.length - zhCount}`);
console.log(`组件数: ${components.length}`);
console.log(`输出: ${OUT_DIR}`);
console.log(`索引大小: ${(statSync(join(OUT_DIR, "index.json")).size / 1024).toFixed(1)} KB`);
