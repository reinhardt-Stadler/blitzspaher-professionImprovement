// 全局代理引导：在 pi 加载前安装 undici 代理 dispatcher
//
// 为什么需要：Node 原生 fetch 不读 HTTP_PROXY 环境变量。
//   pi 内部虽然用 undici，但 --print/--mode json 路径下未初始化代理 dispatcher，
//   导致容器内（L6 内网、无 DNS 出口）请求直接 EAI_AGAIN 失败。
//
// 做法：预加载本文件，用 pi 自带的 undici 安装 EnvHttpProxyAgent。
//   EnvHttpProxyAgent 会读取 HTTP_PROXY / HTTPS_PROXY / NO_PROXY。

const path = require("node:path");

function loadUndici() {
  const candidates = [
    // pi 全局安装目录下的 undici
    "/usr/local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/undici",
    // 通用回退
    "undici",
  ];
  for (const c of candidates) {
    try {
      return require(c);
    } catch {
      /* 尝试下一个 */
    }
  }
  return null;
}

const undici = loadUndici();
if (!undici) {
  // 没有 undici 时静默跳过（不阻塞 pi 启动）
  if (process.env.BLITZSPAHER_DEBUG_PROXY === "1") {
    console.error("[proxy-setup] undici 未找到，跳过代理安装");
  }
} else {
  const proxy = process.env.HTTPS_PROXY || process.env.https_proxy || process.env.HTTP_PROXY || process.env.http_proxy;
  if (proxy) {
    try {
      undici.setGlobalDispatcher(
        new undici.EnvHttpProxyAgent({ allowH2: false, proxyTunnel: true }),
      );
      if (process.env.BLITZSPAHER_DEBUG_PROXY === "1") {
        console.error(`[proxy-setup] 已安装 EnvHttpProxyAgent，代理=${proxy}`);
      }
    } catch (e) {
      if (process.env.BLITZSPAHER_DEBUG_PROXY === "1") {
        console.error(`[proxy-setup] 安装失败: ${e.message}`);
      }
    }
  }
}
