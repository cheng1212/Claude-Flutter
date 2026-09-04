// 本地 Claude Code 会话导入器:扫描 ~/.claude/projects/<encoded-cwd>/<sessionId>.jsonl
// 转成 zCode 的 sessions + messages 行,让手机端能看到电脑上的真实旧对话。
// 逻辑精简移植自 CloudCLI(3005):claude-sessions.provider.ts(normalizeMessage)
// + claude-session-synchronizer.provider.ts(processSessionFile)。
// 幂等:以 provider_session_id(= 文件名 stem)判重,已入库的会话不覆盖。
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

import { appendOutbound, createSession, getSessionByProviderSessionId, listTombstonedProviderSessionIds, type Db } from './db.js';
import type { ProtocolEvent } from './protocol/types.js';

type AnyRecord = Record<string, unknown>;

const INTERNAL_CONTENT_PREFIXES = [
  '<system-reminder>',
  'Caveat:',
  '[Request interrupted',
  'Base directory for this skill:',
] as const;

/** ~/.claude 根(可用环境变量覆盖,方便测试注入 fixtures)。 */
export function claudeHome(): string {
  return process.env.ZCODE_CLAUDE_HOME ?? path.join(os.homedir(), '.claude');
}

/**
 * subagent / tool-result 转写不是顶层会话,且会重复父会话的 sessionId,
 * 当成独立会话导入会污染主会话记录,必须跳过。
 */
function isSubagentTranscript(filePath: string): boolean {
  const parts = path.normalize(filePath).split(path.sep);
  return parts.includes('subagents') || parts.includes('tool-results');
}

function readAllLines(filePath: string): string[] {
  try {
    return fs.readFileSync(filePath, 'utf8').split(/\r?\n/);
  } catch {
    return [];
  }
}

function parseObj(line: string): AnyRecord | null {
  const trimmed = line.trim();
  if (!trimmed) return null;
  try {
    const value = JSON.parse(trimmed) as unknown;
    if (value && typeof value === 'object' && !Array.isArray(value)) return value as AnyRecord;
  } catch {
    // 跳过损坏行(并发写入时可能产生)
  }
  return null;
}

function findProjectFiles(rootDir: string): string[] {
  const out: string[] = [];
  if (!fs.existsSync(rootDir)) return out;
  const stack = [rootDir];
  while (stack.length > 0) {
    const dir = stack.pop()!;
    let entries: fs.Dirent[];
    try {
      entries = fs.readdirSync(dir, { withFileTypes: true });
    } catch {
      continue;
    }
    for (const entry of entries) {
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) {
        stack.push(full);
      } else if (entry.isFile() && entry.name.endsWith('.jsonl')) {
        out.push(full);
      }
    }
  }
  return out;
}

/** ~/.claude/history.jsonl → sessionId→display 映射(nameMap)。 */
function readHistoryNameMap(historyPath: string): Map<string, string> {
  const map = new Map<string, string>();
  for (const line of readAllLines(historyPath)) {
    const obj = parseObj(line);
    if (!obj) continue;
    const key = obj.sessionId;
    const value = obj.display;
    if (typeof key === 'string' && typeof value === 'string' && !map.has(key)) {
      map.set(key, value);
    }
  }
  return map;
}

function readFileTimestamps(filePath: string): { createdAt?: string; updatedAt?: string } {
  try {
    const stat = fs.statSync(filePath);
    return {
      createdAt: stat.birthtime.toISOString(),
      updatedAt: stat.mtime.toISOString(),
    };
  } catch {
    return {};
  }
}

function normalizeSessionName(rawValue: string | undefined, fallback: string): string {
  const normalized = (rawValue ?? '').replace(/\s+/g, ' ').trim();
  if (!normalized) return fallback;
  return normalized.slice(0, 120);
}

function stripFilesInputTag(text: string): string {
  return text.replace(/<files_input>[\s\S]*?<\/files_input>[ \t]*/g, '').trim();
}

function stripAnsi(text: string): string {
  // eslint-disable-next-line no-control-regex
  return text.replace(/\[[0-9;?]*[ -/]*[@-~]/g, '');
}

function extractTaggedContent(content: string, tagName: string): string | null {
  const escaped = tagName.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const match = new RegExp(`<${escaped}>([\\s\\S]*?)<\\/${escaped}>`).exec(content);
  return match ? match[1] : null;
}

/** 把本地 slash 命令的隐藏包裹(<command-name>…)转成用户可见的短命令串。 */
function parseLocalCommandPayload(content: string): string | null {
  const name = extractTaggedContent(content, 'command-name');
  const message = extractTaggedContent(content, 'command-message');
  const args = extractTaggedContent(content, 'command-args');
  if (name === null && message === null && args === null) return null;
  const base = (name ?? '').trim() || (message ?? '').trim();
  if (!base) return null;
  const argText = (args ?? '').trim();
  return argText ? `${base} ${argText}` : base;
}

function isInternalContent(content: string): boolean {
  return INTERNAL_CONTENT_PREFIXES.some((prefix) => content.startsWith(prefix));
}

function cleanUserText(text: string): string {
  return stripFilesInputTag(text).trim();
}

/**
 * 一行转写 → ProtocolEvent[]。产出的字段与 transform.ts 完全对齐
 * (kind/role/content/toolId/toolName/toolInput/isError),前端 applyEvent 直接复用。
 */
export function normalizeTranscriptLine(raw: AnyRecord): ProtocolEvent[] {
  const out: ProtocolEvent[] = [];

  // 独立 thinking/tool_use/tool_result 行(实时流形态,转写里少见)
  if (raw.type === 'thinking' && typeof (raw.message as AnyRecord | undefined)?.content === 'string') {
    const content = (raw.message as AnyRecord).content as string;
    if (content.trim()) out.push({ kind: 'thinking', content });
    return out;
  }
  if (raw.type === 'tool_use' && typeof raw.toolName === 'string') {
    out.push({
      kind: 'tool_use',
      toolId: String(raw.toolCallId ?? raw.id ?? ''),
      toolName: raw.toolName,
      toolInput: raw.toolInput ?? {},
    });
    return out;
  }
  if (raw.type === 'tool_result') {
    const toolId = String(raw.toolCallId ?? '');
    if (toolId) {
      out.push({
        kind: 'tool_result',
        toolId,
        content: typeof raw.output === 'string' ? raw.output : JSON.stringify(raw.output ?? ''),
        isError: false,
      });
    }
    return out;
  }

  const message = raw.message as AnyRecord | undefined;
  const role = typeof message?.role === 'string' ? message.role : undefined;
  const content = typeof message?.content === 'string' ? message.content : message?.content;

  if (role === 'user' && content && raw.isMeta !== true) {
    if (Array.isArray(content)) {
      for (const part of content) {
        const block = part as AnyRecord;
        if (block.type === 'tool_result') {
          const toolId = block.tool_use_id ? String(block.tool_use_id) : '';
          if (toolId) {
            out.push({
              kind: 'tool_result',
              toolId,
              content: typeof block.content === 'string' ? block.content : JSON.stringify(block.content ?? ''),
              isError: Boolean(block.is_error),
            });
          }
        } else if (block.type === 'text') {
          const text = cleanUserText((block.text as string) ?? '');
          if (text && !isInternalContent(text)) out.push({ kind: 'text', role: 'user', content: text });
        }
        // image block 无渲染支持,导入时忽略
      }
    } else if (typeof content === 'string') {
      const text = content;
      // 摘要行是 "user" 造型,但对 UI 更像 assistant 汇总 → 重新标 assistant
      if (raw.isCompactSummary === true && text.trim()) {
        out.push({ kind: 'text', role: 'assistant', content: text });
        return out;
      }
      const localCommand = parseLocalCommandPayload(text);
      if (localCommand) {
        out.push({ kind: 'text', role: 'user', content: localCommand });
        return out;
      }
      const stdout = extractTaggedContent(text, 'local-command-stdout');
      if (stdout !== null) {
        const clean = stripAnsi(stdout).trim();
        if (clean) out.push({ kind: 'text', role: 'assistant', content: clean });
        return out;
      }
      const clean = cleanUserText(text);
      if (clean && !isInternalContent(clean)) out.push({ kind: 'text', role: 'user', content: clean });
    }
    return out;
  }

  if (role === 'assistant' && content) {
    if (Array.isArray(content)) {
      for (const part of content) {
        const block = part as AnyRecord;
        if (block.type === 'text' && typeof block.text === 'string' && block.text.trim()) {
          out.push({ kind: 'text', role: 'assistant', content: block.text });
        } else if (block.type === 'thinking' && typeof block.thinking === 'string' && block.thinking.trim()) {
          out.push({ kind: 'thinking', content: block.thinking });
        } else if (block.type === 'tool_use') {
          out.push({
            kind: 'tool_use',
            toolId: String(block.id ?? ''),
            toolName: String(block.name ?? ''),
            toolInput: block.input ?? {},
          });
        }
      }
    } else if (typeof content === 'string' && content.trim()) {
      out.push({ kind: 'text', role: 'assistant', content });
    }
    return out;
  }

  return out;
}

/** 从文件末尾往前找 ai-title / last-prompt / custom-title。 */
function extractTitleFromEnd(lines: string[], sessionId: string): string | undefined {
  for (let index = lines.length - 1; index >= 0; index -= 1) {
    const raw = parseObj(lines[index]);
    if (!raw) continue;
    const type = typeof raw.type === 'string' ? raw.type : undefined;
    const sid = typeof raw.sessionId === 'string' ? raw.sessionId : undefined;
    const aiTitle = typeof raw.aiTitle === 'string' ? raw.aiTitle : undefined;
    const lastPrompt = typeof raw.lastPrompt === 'string' ? raw.lastPrompt : undefined;
    const customTitle = typeof raw.customTitle === 'string' ? raw.customTitle : undefined;
    if (
      sid === sessionId
      && (
        (type === 'ai-title' && aiTitle?.trim())
        || (type === 'last-prompt' && lastPrompt?.trim())
        || (type === 'custom-title' && customTitle?.trim())
      )
    ) {
      return aiTitle || lastPrompt || customTitle;
    }
  }
  return undefined;
}

function resolveTitle(nameMap: Map<string, string>, sessionId: string, lines: string[], cwd: string | undefined): string {
  const fromMap = nameMap.get(sessionId);
  if (fromMap) return normalizeSessionName(fromMap, '新会话');
  const fromEnd = extractTitleFromEnd(lines, sessionId);
  if (fromEnd) return normalizeSessionName(fromEnd, '新会话');
  return normalizeSessionName(cwd ? path.basename(cwd) : '', '本地会话');
}

export type ImportResult = { imported: number; skipped: number };

/**
 * 扫描 ~/.claude/projects,把未导入的会话写进 zCode SQLite。
 * 幂等:provider_session_id 已存在则跳过。单文件/单行失败不中断整体。
 */
export function importLocalSessions(db: Db, opts: { projectsDir?: string } = {}): ImportResult {
  const projectsDir = opts.projectsDir ?? path.join(claudeHome(), 'projects');
  const historyPath = path.join(claudeHome(), 'history.jsonl');
  const nameMap = readHistoryNameMap(historyPath);
  // 用户删过的会话不复活:墓碑按 provider_session_id 拉黑
  const tombstones = listTombstonedProviderSessionIds(db);

  let imported = 0;
  let skipped = 0;

  for (const filePath of findProjectFiles(projectsDir)) {
    if (isSubagentTranscript(filePath)) {
      skipped += 1;
      continue;
    }
    const lines = readAllLines(filePath);
    if (lines.length === 0) {
      skipped += 1;
      continue;
    }

    // 首条同时带 sessionId + cwd 的行确定会话元数据(不信任目录名)。
    let sessionMeta: AnyRecord | null = null;
    for (const line of lines) {
      const obj = parseObj(line);
      if (obj && typeof obj.sessionId === 'string' && typeof obj.cwd === 'string') {
        sessionMeta = obj;
        break;
      }
    }
    if (!sessionMeta) {
      skipped += 1;
      continue;
    }
    const sessionId = sessionMeta.sessionId as string;
    const cwd = sessionMeta.cwd as string;

    if (tombstones.has(sessionId) || getSessionByProviderSessionId(db, sessionId)) {
      skipped += 1;
      continue;
    }

    const timestamps = readFileTimestamps(filePath);
    const title = resolveTitle(nameMap, sessionId, lines, cwd);

    const session = createSession(db, {
      title,
      cwd,
      source: 'local',
      providerSessionId: sessionId,
      createdAt: timestamps.createdAt,
      updatedAt: timestamps.updatedAt,
    });

    // 按文件时间序铺 seq,meta 存完整出站事件,前端 _rowEvent 直接还原。
    let seq = 0;
    for (const line of lines) {
      const raw = parseObj(line);
      if (!raw) continue;
      for (const event of normalizeTranscriptLine(raw)) {
        seq += 1;
        appendOutbound(db, session.id, { seq, ...event });
      }
    }

    imported += 1;
  }

  return { imported, skipped };
}
