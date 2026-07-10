#!/usr/bin/env node
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const base = process.env.OKX_A2A_BASE || path.join(process.env.HOME || os.homedir(), '.okx-agent-task');
const logDir = path.join(base, 'logs');
fs.mkdirSync(logDir, { recursive: true });
const logFile = path.join(logDir, 'fast-handler.log');

function log(message) {
  try {
    fs.appendFileSync(logFile, `${new Date().toISOString()} ${message}\n`);
  } catch {
    // Logging must never block protocol handling.
  }
}

function run(command, args) {
  const result = spawnSync(command, args, { encoding: 'utf8', shell: false });
  if (result.error) {
    return { status: 1, stdout: '', stderr: String(result.error.message || result.error) };
  }
  return {
    status: result.status ?? 1,
    stdout: result.stdout || '',
    stderr: result.stderr || '',
  };
}

function extractJsonObject(text) {
  const trimmed = (text || '').trim();
  const candidates = [];
  if (trimmed) candidates.push(trimmed);
  const first = trimmed.indexOf('{');
  const last = trimmed.lastIndexOf('}');
  if (first >= 0 && last > first) candidates.push(trimmed.slice(first, last + 1));

  for (const candidate of candidates) {
    try {
      return JSON.parse(candidate);
    } catch {
      // Try the next possible JSON segment.
    }
  }
  return null;
}

function getLine(label, text) {
  const escaped = label.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const match = text.match(new RegExp(`${escaped}:\\s*(.*)`));
  return match ? match[1].trim() : '';
}

function parseCommand(text, verb) {
  const escaped = verb.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const match = text.match(new RegExp(`^onchainos\\s+agent\\s+${escaped}\\s+([^\\n]+)$`, 'm'));
  if (!match) return null;
  const line = `onchainos agent ${verb} ${match[1]}`.trim();
  const args = [];
  let current = '';
  let quote = null;
  let escapedChar = false;

  for (const char of line) {
    if (escapedChar) {
      current += char;
      escapedChar = false;
      continue;
    }
    if (char === '\\') {
      escapedChar = true;
      continue;
    }
    if (quote) {
      if (char === quote) quote = null;
      else current += char;
      continue;
    }
    if (char === '"' || char === "'") {
      quote = char;
      continue;
    }
    if (/\s/.test(char)) {
      if (current) {
        args.push(current);
        current = '';
      }
      continue;
    }
    current += char;
  }
  if (current) args.push(current);
  return args.slice(2);
}

const capabilityFamilies = [
  [
    '网站', '网页', '网址', 'https', 'http', 'url', 'endpoint', '接口',
    '响应状态', '健康检查', '健康监测', '连通检查', 'status check', 'health check',
  ],
  [
    '远程接入', '远程访问', '远程协作', '远程桌面', '跨设备', 'vpn', 'vps',
    '代理', '链路', 'proxy', 'xray', 'vless', 'clash',
  ],
  [
    '量化', '交易', '收益', '回撤', '风控', '风险评估', '策略',
    'trading', 'strategy', 'drawdown', 'risk assessment',
  ],
];

function capabilityMatches(playbook) {
  const taskText = `${getLine('Task title', playbook)}\n${getLine('Task description', playbook)}`.toLowerCase();
  const serviceText = `${getLine('Designated service', playbook)}\n${getLine('Service description', playbook)}`.toLowerCase();
  return capabilityFamilies.some((family) => (
    family.some((keyword) => taskText.includes(keyword))
    && family.some((keyword) => serviceText.includes(keyword))
  ));
}

function userNotify(content) {
  return run('onchainos', ['agent', 'user-notify', '--content', content]);
}

function selfTest() {
  const matching = `Task title: 配置跨设备远程接入\nTask description: 使用 Windows 服务器供笔记本和手机远程协作\nDesignated service: 跨设备远程接入配置\nService description: 规划并实施跨设备远程接入和链路验证。`;
  const mismatch = `Task title: 配置跨设备远程接入\nTask description: 使用 Windows 服务器供笔记本和手机远程协作\nDesignated service: 网站响应状态检测\nService description: 对公开 HTTPS 地址执行连通检查。`;
  if (!capabilityMatches(matching) || capabilityMatches(mismatch)) process.exit(1);
  console.log('FAST_HANDLER_SELF_TEST ok');
}

if (process.env.OKX_A2A_FAST_HANDLER_SELF_TEST === '1') {
  selfTest();
  process.exit(0);
}

const input = fs.readFileSync(0, 'utf8');
const joinedArgs = process.argv.slice(2).join('\n');
const envelope = extractJsonObject(input) || extractJsonObject(joinedArgs);
if (!envelope) process.exit(64);

// The current OKX task flow has no custom review-probe acknowledgement.
// Peer chat must fall through to the official Codex role playbook.
if (envelope.msgType === 'a2a-agent-chat') process.exit(64);

let systemMessage = null;
let agentId = null;
if (envelope.message && envelope.message.source === 'system' && envelope.message.event && envelope.message.jobId) {
  systemMessage = envelope.message;
  agentId = envelope.agentId || envelope.message.providerAgentId || envelope.message.agentId;
} else if (envelope.source === 'system' && envelope.event && envelope.jobId) {
  systemMessage = envelope;
  agentId = envelope.agentId || envelope.providerAgentId;
}

if (!systemMessage || !agentId) process.exit(64);

const event = String(systemMessage.event).toLowerCase();
if (!event.includes('asp_selected')) process.exit(64);

agentId = String(agentId);
const jobId = String(systemMessage.jobId);
const startedAt = Date.now();
log(`system_event start agent=${agentId} job=${jobId} event=${systemMessage.event}`);

const next = run('onchainos', [
  'agent',
  'next-action',
  '--role',
  'auto',
  '--agentId',
  agentId,
  '--message',
  JSON.stringify(systemMessage),
]);

if (next.status !== 0) {
  const detail = (next.stderr || next.stdout).slice(0, 240).replace(/\s+/g, ' ');
  log(`next_action_failed job=${jobId} status=${next.status} err=${detail}`);
  userNotify(`[系统事件处理失败] 任务 ${jobId} 未能取得官方下一步动作，请人工检查。`);
  process.exit(0);
}

const playbook = next.stdout;
const priceReject = /Price gate \(TOO_LOW\)|Recommended action:\s*Reject/i.test(playbook);
const needsJudgment = /LLM judgment/i.test(playbook);
let action = null;
if (priceReject) action = 'reject';
else if (needsJudgment) action = capabilityMatches(playbook) ? 'apply' : 'reject';
else if (/Recommended action:\s*Apply|APPLY path/i.test(playbook)) action = 'apply';

if (!action) {
  log(`unsupported_playbook job=${jobId}`);
  process.exit(64);
}

if (process.env.OKX_A2A_FAST_HANDLER_DRY_RUN === '1') {
  log(`dry_run job=${jobId} action=${action} elapsed_ms=${Date.now() - startedAt}`);
  console.log(`FAST_HANDLER_DRY_RUN action=${action} job=${jobId}`);
  process.exit(0);
}

if (action === 'reject') {
  const rejectArgs = parseCommand(playbook, 'asp-reject');
  if (!rejectArgs) {
    log(`reject_command_missing job=${jobId}`);
    process.exit(64);
  }
  const rejected = run('onchainos', ['agent', ...rejectArgs]);
  log(`reject job=${jobId} status=${rejected.status} elapsed_ms=${Date.now() - startedAt}`);
  if (rejected.status === 0) {
    const reason = priceReject ? '报价低于已登记服务费用' : '任务内容与指定服务能力不匹配';
    userNotify(`[指定任务已拒绝] 任务 ${jobId} 已按官方流程处理。\n- 原因：${reason}\n发布方可以选择其他服务方或将任务公开。`);
  } else {
    const error = (rejected.stderr || rejected.stdout || '拒绝操作失败').split(/\r?\n/).find(Boolean) || '拒绝操作失败';
    userNotify(`[指定任务拒绝失败] 任务 ${jobId} 未能完成处理。\n- 错误：${error.slice(0, 180)}\n请人工检查。`);
  }
  process.exit(0);
}

const applyArgs = parseCommand(playbook, 'apply');
if (!applyArgs) {
  log(`apply_command_missing job=${jobId}`);
  process.exit(64);
}
const applied = run('onchainos', ['agent', ...applyArgs]);
log(`apply job=${jobId} status=${applied.status} elapsed_ms=${Date.now() - startedAt}`);
if (applied.status !== 0 || !/txHash|transaction/i.test(applied.stdout)) {
  const error = (applied.stderr || applied.stdout || '申请失败').split(/\r?\n/).find(Boolean) || '申请失败';
  userNotify(`[指定任务接单失败] 任务 ${jobId} 未能完成链上申请。\n- 错误：${error.slice(0, 180)}\n本次申请未登记，请人工决定是否重试。`);
}
