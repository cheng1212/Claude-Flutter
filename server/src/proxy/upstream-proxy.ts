import http from 'node:http';
import https from 'node:https';
import type { IncomingMessage, ServerResponse } from 'node:http';
import { loadRoutes, type RouteConfig, type RouteEntry } from '../routes.js';

/**
 * 上游中转代理:zcode 自己的模型( routes.json 里带 relayTo 的条目 )走这里。
 * Claude Code 以 ANTHROPIC_BASE_URL 指向本代理;代理按请求体里的 model 找到
 * relayTo 指向的真实路由,原样转发 + 把上游 SSE 流式响应端到端透传回来。
 * 内容不解析不加工;只对 /v1/messages 的主请求发计时事件(请求发出/首包/结束),
 * 供手机端静默期显示真实上游状态。count_tokens 等辅助路径盲转发不打扰。
 */

export type UpstreamPhase = 'request' | 'first_byte' | 'done' | 'error';
export type UpstreamStatus = {
  phase: UpstreamPhase;
  model: string;
  status?: number;
  ms?: number;
  error?: string;
};

export type UpstreamProxyOptions = {
  port: number;
  host?: string; // 默认 127.0.0.1:模型流量没理由暴露到局域网
  routesPath: string;
  onStatus?: (s: UpstreamStatus) => void;
};

/** routes.json 里带 relayTo 的条目即中转模型;按请求 model 匹配 entry.model(缺省用 key)。 */
export function resolveRelay(config: RouteConfig | null, model: string): { relay: RouteEntry; target: RouteEntry } | null {
  if (!model) return null;
  const routes = config?.routes ?? {};
  for (const [id, entry] of Object.entries(routes)) {
    const relayTo = (entry as { relayTo?: string }).relayTo;
    if (!relayTo) continue;
    if ((entry.model ?? id) !== model) continue;
    const target = routes[relayTo];
    if (!target?.baseUrl) return null; // relayTo 指了个不存在的路由:按无目标处理
    return { relay: entry, target };
  }
  return null;
}

export function startUpstreamProxy(opts: UpstreamProxyOptions): http.Server {
  const server = http.createServer((req, res) => {
    void handle(req, res, opts).catch(() => {
      if (!res.headersSent) {
        res.writeHead(502, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: { type: 'proxy_error', message: 'zcode relay internal error' } }));
      } else {
        res.end();
      }
    });
  });
  server.listen(opts.port, opts.host ?? '127.0.0.1');
  return server;
}

const OBSERVED_PATH = /\/v1\/messages\/?$/; // 主请求才发计时事件;count_tokens 等静默转发

async function handle(req: IncomingMessage, res: ServerResponse, opts: UpstreamProxyOptions): Promise<void> {
  const onStatus = (s: UpstreamStatus) => {
    try { opts.onStatus?.(s); } catch { /* 状态回调不许炸掉代理 */ }
  };
  const started = Date.now();
  const log = (msg: string) => console.log(`[relay] ${req.method} ${req.url} ${msg}`);

  if (req.method === 'GET' && req.url === '/healthz') {
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end('{"ok":true}');
    return;
  }
  if (req.method !== 'POST') {
    log('-> 405 只放行 POST(/healthz 除外)');
    res.writeHead(405, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ error: { type: 'proxy_error', message: 'POST only' } }));
    return;
  }

  // 请求体是小 JSON(messages 数组),整收没问题;响应才是大流量,必须流式透传。
  const chunks: Buffer[] = [];
  for await (const chunk of req) chunks.push(chunk as Buffer);
  let body = Buffer.concat(chunks);
  let parsed: { model?: string } = {};
  try { parsed = JSON.parse(body.toString('utf8')) as { model?: string }; } catch { /* 上游会报它自己的格式错 */ }
  const model = String(parsed.model ?? '');
  const observed = OBSERVED_PATH.test(req.url ?? '');
  if (observed) onStatus({ phase: 'request', model });

  const found = resolveRelay(loadRoutes(opts.routesPath), model);
  if (!found) {
    log(`model=${model || '?'} -> 502 无中转目标 (${Date.now() - started}ms)`);
    if (observed) onStatus({ phase: 'error', model, ms: Date.now() - started, error: 'no relay target' });
    res.writeHead(502, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ error: { type: 'proxy_error', message: `zcode relay: no upstream route for model '${model}'` } }));
    return;
  }
  const target = found.target;

  // relay 条目与目标路由的 model 名不同时改写请求体,上游永远收到它自己的名字
  const upstreamModel = target.model || model;
  if (upstreamModel !== model) {
    parsed.model = upstreamModel;
    body = Buffer.from(JSON.stringify(parsed), 'utf8');
  }

  // CLI 发的是 origin-form(以 / 开头),new URL 会把它当"从根开始"整个替换掉
  // baseUrl 的路径前缀(智谱的 /api/anthropic 会丢,变成根路径 405)——去掉前导斜杠再拼。
  const incoming = req.url ?? '/v1/messages';
  const baseUrl = target.baseUrl ?? ''; // resolveRelay 已保证非空,此处仅满足类型
  const base = baseUrl.endsWith('/') ? baseUrl : `${baseUrl}/`;
  const upstream = new URL(incoming.replace(/^\//, ''), base);
  // 鉴权统一换成目标路由的 token(x-api-key + Bearer 双写,各端点各取所需);
  // accept-encoding 摘掉:压缩流会让"透传"在代理这里变成不可解读的字节,还可能被中间层缓冲。
  const headers: Record<string, string | number | string[]> = {};
  for (const [k, v] of Object.entries(req.headers)) {
    if (v == null) continue;
    if (['host', 'authorization', 'x-api-key', 'accept-encoding', 'content-length'].includes(k)) continue;
    headers[k] = v as string | string[];
  }
  headers.host = upstream.host;
  const token = target.authToken ?? '';
  if (token) {
    headers['x-api-key'] = token;
    headers.authorization = `Bearer ${token}`;
  }
  headers['content-length'] = body.length;

  const send = upstream.protocol === 'https:' ? https.request : http.request;
  const upReq = send(
    upstream,
    { method: 'POST', headers },
    (upRes) => {
      if (observed) onStatus({ phase: 'first_byte', model, status: upRes.statusCode, ms: Date.now() - started });
      // 保留上游状态短语:nginx 的 "405 Not Allowed" 之类原样带给 CLI,排查看得出是谁拒的
      res.writeHead(upRes.statusCode ?? 502, upRes.statusMessage || undefined, upRes.headers);
      if ((upRes.statusCode ?? 0) >= 400) log(`model=${model || '?'} -> 上游 ${upRes.statusCode} ${upstream.pathname}${upstream.search} (${Date.now() - started}ms)`);
      upRes.pipe(res);
      upRes.on('end', () => {
        if (observed) onStatus({ phase: 'done', model, status: upRes.statusCode, ms: Date.now() - started });
      });
    },
  );
  upReq.on('error', (error) => {
    log(`model=${model || '?'} -> 上游连不上: ${error.message} (${Date.now() - started}ms)`);
    if (observed) onStatus({ phase: 'error', model, ms: Date.now() - started, error: error.message });
    if (!res.headersSent) {
      res.writeHead(502, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ error: { type: 'proxy_error', message: `upstream unreachable: ${error.message}` } }));
    } else {
      res.end();
    }
  });
  // 客户端(CLI)中途放弃:上游请求一并掐断,别让上游继续烧 token
  req.on('close', () => {
    if (!res.writableEnded) upReq.destroy();
  });
  upReq.end(body);
}
