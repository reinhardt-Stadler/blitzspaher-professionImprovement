#!/usr/bin/env node
/**
 * 构建上下文准备脚本
 *
 * 背景：本机 Docker 未安装 buildx 插件（GitHub 直连不通，下载失败），
 *       classic builder 不支持 additional_contexts / 跨目录 COPY。
 *       因此构建前把所需内容拷到 deploy/ 下，让 classic builder 可用。
 *
 * 做两件事：
 *   1. ../src/pi-pentest/  → ./pi-pentest/
 *   2. ./knowledge/generated/ → ./knowledge-ctx/
 *
 * 用法：
 *   node deploy/prepare-build.mjs
 *   cd deploy && docker compose build agent
 */

import { cpSync, rmSync, existsSync, mkdirSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const repoRoot = join(__dirname, "..");

const jobs = [
  {
    name: "pi-pentest 源码",
    from: join(repoRoot, "src", "pi-pentest"),
    to: join(__dirname, "pi-pentest"),
    required: true,
  },
  {
    name: "知识库",
    from: join(__dirname, "knowledge", "generated"),
    to: join(__dirname, "knowledge-ctx"),
    required: false,
    fallback: () => {
      // 知识库未生成时给一个空索引，让镜像仍可构建
      mkdirSync(join(__dirname, "knowledge-ctx"), { recursive: true });
      const { writeFileSync } = require("node:fs");
    },
  },
];

for (const job of jobs) {
  if (existsSync(job.to)) rmSync(job.to, { recursive: true, force: true });

  if (!existsSync(job.from)) {
    if (!job.required) {
      console.warn(`⚠ ${job.name} 源不存在，将创建空索引：${job.from}`);
      mkdirSync(job.to, { recursive: true });
      continue;
    }
    console.error(`✗ ${job.name} 源不存在：${job.from}`);
    process.exit(1);
  }

  cpSync(job.from, job.to, {
    recursive: true,
    filter: (src) => !src.includes("node_modules") && !src.includes(".git"),
  });
  console.log(`✓ ${job.name} → ${job.to}`);
}

// 知识库为空时补一个空索引
const indexPath = join(__dirname, "knowledge-ctx", "index.json");
if (!existsSync(indexPath)) {
  const { writeFileSync } = await import("node:fs");
  writeFileSync(
    indexPath,
    JSON.stringify({ generatedAt: null, source: "empty", entries: [] }, null, 1),
    "utf8",
  );
  console.log("   （已创建空索引 knowledge-ctx/index.json）");
}

console.log("\n准备完成。下一步：");
console.log("  cd deploy && docker compose build agent");
