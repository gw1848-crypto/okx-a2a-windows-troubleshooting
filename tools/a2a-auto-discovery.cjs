#!/usr/bin/env node
'use strict';

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const EXIT_OK = 0;
const EXIT_DATAERR = 65;
const EXIT_TEMPFAIL = 75;
const EXIT_CONFIG = 78;

const base = process.env.OKX_A2A_BASE || path.join(process.env.HOME || os.homedir(), '.okx-agent-task');
const agentId = String(process.env.AGENT_ID || process.env.OKX_A2A_AGENT_ID || '').trim();
const onchainosCommand = process.env.OKX_A2A_ONCHAINOS_COMMAND || 'onchainos';
const stateDir = path.join(base, 'state', 'auto-discovery');
const stateFile = path.join(stateDir, 'seen.json');
const lockFile = path.join(stateDir, 'run.lock');
const logDir = path.join(base, 'logs');
const logFile = path.join(logDir, 'auto-discovery.log');
const expectedToken = String(
  process.env.OKX_A2A_DISCOVERY_TOKEN_ADDRESS || '0x779ded0c9e1022225f8e0630b35a9b54be713736',
).toLowerCase();

function envNumber(name, fallback, min, max) {
  const value = Number(process.env[name]);
  return Number.isFinite(value) && value >= min && value <= max ? value : fallback;
}

const maxNotifications = Math.trunc(envNumber('OKX_A2A_DISCOVERY_MAX_CANDIDATES', 3, 1, 5));
const commandTimeoutMs = Math.trunc(envNumber('OKX_A2A_DISCOVERY_TIMEOUT_MS', 60_000, 5_000, 120_000));
const autoContact = process.env.OKX_A2A_DISCOVERY_AUTO_CONTACT === '1';
const contactCooldownMs = envNumber('OKX_A2A_DISCOVERY_CONTACT_COOLDOWN_HOURS', 1, 1, 168) * 60 * 60 * 1000;
const denyPattern = /(\[test\]|流程试运行|自动测试消息|请回复确认|登录|oauth|注册|邮箱|电报|telegram|twitter|推特|关注|点赞|转发|评论|截图|蓝v|订阅套餐|api[ -]?key|节点绑定|provider node|每小时|每日推送|持续监控|长期运行|24\s*小时|实时推送|实际资金操作|实际交易|自动交易|下单|转账|钱包授权|签名|桥接到|存入aave|借出基础币|共享订阅)/iu;
const policy = [
  {
    id: 'website_status',
    label: '网站响应状态检测',
    minimum: envNumber('OKX_A2A_DISCOVERY_MIN_WEBSITE', 0.01, 0, 1_000_000),
    pattern: /(网站|网页|http|https|url|响应状态|健康检查|连通性|可用性监测)/iu,
  },
  {
    id: 'remote_access',
    label: '跨设备远程接入配置',
    minimum: envNumber('OKX_A2A_DISCOVERY_MIN_REMOTE', 1, 0, 1_000_000),
    pattern: /(远程接入|远程访问|远程办公|跨设备|vpn|网络接入|链路诊断)/iu,
  },
  {
    id: 'quant_risk',
    label: '量化策略目标风险评估',
    minimum: envNumber('OKX_A2A_DISCOVERY_MIN_RISK', 10, 0, 1_000_000),
    pattern: /(量化|交易策略|投资策略|投资组合|目标风险|风险评估|最大回撤|收益分析)/iu,
  },
  {
    id: 'public_data_query',
    label: '公开数据查询',
    minimum: envNumber('OKX_A2A_DISCOVERY_MIN_QUERY', 0.01, 0, 1_000_000),
    pattern: /(查询|排行|排名|top\s*[0-9]+|公开数据|链上数据)/iu,
  },
  {
    id: 'research_analysis',
    label: '研究与分析报告',
    minimum: envNumber('OKX_A2A_DISCOVERY_MIN_ANALYSIS', 1, 0, 1_000_000),
    pattern: /(分析|研究|评估|报告|策略|方案|教程|指南|总结|行情走势)/iu,
  },
  {
    id: 'software_work',
    label: '软件与自动化任务',
    minimum: envNumber('OKX_A2A_DISCOVERY_MIN_SOFTWARE', 1, 0, 1_000_000),
    pattern: /(代码|脚本|程序|开发|修复|调试|代码审查|部署|自动化)/iu,
  },
  {
    id: 'content_work',
    label: '内容整理与优化',
    minimum: envNumber('OKX_A2A_DISCOVERY_MIN_CONTENT', 1, 0, 1_000_000),
    pattern: /(文案|内容整理|内容优化|改写|翻译|摘要)/iu,
  },
];

function ensurePrivateDir(directory) {
  fs.mkdirSync(directory, { recursive: true, mode: 0o700 });
  try { fs.chmodSync(directory, 0o700); } catch { /* restrictive umask is the fallback */ }
}

function log(message) {
  try {
    const safe = String(message).replace(/[\r\n]+/g, ' ').slice(0, 2000);
    fs.appendFileSync(logFile, `${new Date().toISOString()} ${safe}\n`, { mode: 0o600 });
  } catch {
    // Discovery must not turn a logging failure into task activity.
  }
}

function run(args, timeout = commandTimeoutMs) {
  const result = spawnSync(onchainosCommand, args, {
    encoding: 'utf8',
    shell: false,
    timeout,
    maxBuffer: 4 * 1024 * 1024,
    windowsHide: true,
  });
  if (result.error) {
    return { status: result.error.code === 'ETIMEDOUT' ? 124 : 1, stdout: result.stdout || '', stderr: String(result.error.message || result.error) };
  }
  return { status: result.status ?? 1, stdout: result.stdout || '', stderr: result.stderr || '' };
}

function sanitizeText(value, limit = 120) {
  return String(value || '')
    .replace(/[\u0000-\u001f\u007f]/g, ' ')
    .replace(/\s+/g, ' ')
    .trim()
    .slice(0, limit);
}

function parseRecommendations(text) {
  const lines = String(text || '').split(/\r?\n/);
  const header = lines.map((line) => line.match(/^\[Agent ([0-9]+)\] Matched ([0-9]+) Public task\(s\):$/u)).find(Boolean);
  if (!header || header[1] !== agentId) throw new Error('missing or mismatched recommendation header');
  const expectedCount = Number(header[2]);
  const tasks = [];
  let current = null;

  for (const line of lines) {
    const start = line.match(/^  [0-9]+\. jobId: (0x[0-9a-fA-F]{64})$/u);
    if (start) {
      if (current) tasks.push(current);
      current = { jobId: start[1], title: '', description: '', budget: null, tokenAddress: '', createdAt: '', inDescription: false };
      continue;
    }
    if (!current) continue;
    const title = line.match(/^     Title:\s+(.*)$/u);
    if (title) {
      current.title = sanitizeText(title[1]);
      current.inDescription = false;
      continue;
    }
    const description = line.match(/^     Description:\s*(.*)$/u);
    if (description) {
      current.description = sanitizeText(description[1], 1000);
      current.inDescription = true;
      continue;
    }
    const budget = line.match(/^     Budget:\s+((?:0|[1-9][0-9]*)(?:\.[0-9]+)?) \(token: (0x[0-9a-fA-F]{40})\)$/u);
    if (budget) {
      current.budget = Number(budget[1]);
      current.budgetText = budget[1];
      current.tokenAddress = budget[2].toLowerCase();
      current.inDescription = false;
      continue;
    }
    const created = line.match(/^     Created:\s+([^\r\n]+)$/u);
    if (created) {
      current.createdAt = created[1].trim().slice(0, 80);
      current.inDescription = false;
      continue;
    }
    if (current.inDescription && current.description.length < 1000) {
      current.description = sanitizeText(`${current.description} ${line}`, 1000);
    }
  }
  if (current) tasks.push(current);

  const unique = new Set(tasks.map((task) => task.jobId));
  if (tasks.length !== expectedCount || unique.size !== tasks.length) {
    throw new Error(`recommendation parse count mismatch expected=${expectedCount} parsed=${tasks.length} unique=${unique.size}`);
  }
  return tasks.filter((task) => task.title && Number.isFinite(task.budget) && task.tokenAddress);
}

function classify(task) {
  if (task.tokenAddress !== expectedToken) return null;
  if (denyPattern.test(`${task.title} ${task.description}`)) return null;
  for (const rule of policy) {
    // Capability selection is title-bound. Descriptions are untrusted and are
    // used only for conservative deny rules, never to lower a price threshold.
    if (rule.pattern.test(task.title)) {
      return task.budget >= rule.minimum ? rule : null;
    }
  }
  return null;
}

function valueScore(task, rule) {
  // The configured category floor is a deterministic proxy for expected work.
  // Never use the untrusted task description to reduce that baseline.
  const baseline = Math.max(rule.minimum, 0.01);
  return Math.round((task.budget / baseline) * 100) / 100;
}

function readState() {
  try {
    const value = JSON.parse(fs.readFileSync(stateFile, 'utf8'));
    return value && typeof value === 'object' && value.seen && typeof value.seen === 'object'
      ? value
      : { version: 1, seen: {} };
  } catch (error) {
    if (error && error.code === 'ENOENT') return { version: 1, seen: {} };
    throw error;
  }
}

function writeState(state) {
  const entries = Object.entries(state.seen)
    .sort((a, b) => String(b[1]?.notifiedAt || '').localeCompare(String(a[1]?.notifiedAt || '')))
    .slice(0, 1000);
  const value = {
    version: 1,
    updatedAt: new Date().toISOString(),
    lastContactAt: state.lastContactAt || null,
    seen: Object.fromEntries(entries),
  };
  const temporary = `${stateFile}.${process.pid}.tmp`;
  fs.writeFileSync(temporary, `${JSON.stringify(value)}\n`, { mode: 0o600 });
  fs.renameSync(temporary, stateFile);
}

function acquireLock() {
  try {
    const fd = fs.openSync(lockFile, 'wx', 0o600);
    fs.writeFileSync(fd, `${process.pid}\n`);
    fs.closeSync(fd);
    return true;
  } catch (error) {
    if (!error || error.code !== 'EEXIST') throw error;
    try {
      const ageMs = Date.now() - fs.statSync(lockFile).mtimeMs;
      if (ageMs > 5 * 60_000) {
        fs.unlinkSync(lockFile);
        return acquireLock();
      }
    } catch {
      return false;
    }
    return false;
  }
}

function releaseLock() {
  try { fs.unlinkSync(lockFile); } catch { /* stale lock cleanup handles crashes */ }
}

function notify(candidates) {
  const rows = candidates.map((candidate, index) => (
    `${index + 1}. ${candidate.title}\n` +
    `   报酬：${candidate.budgetText} USDT\n` +
    `   性价比：${candidate.valueScore.toFixed(2)}× 类别最低价\n` +
    `   匹配服务：${candidate.rule.label}\n` +
    `   任务 ID：${candidate.jobId}`
  ));
  const content = `[自动找单] 发现 ${candidates.length} 个符合归元能力与价格下限的新任务：\n\n${rows.join('\n\n')}\n\n如要开始协商，请回复“接 <任务 ID>”。平台指定归元后，系统才会按官方流程申请。`;
  return run(['agent', 'user-notify', '--content', content], 10_000);
}

function notifyContact(candidate) {
  const content = `[自动找单] 已为归元选择并联系一个可自动完成的任务：\n\n${candidate.title}\n报酬：${candidate.budgetText} USDT\n性价比：${candidate.valueScore.toFixed(2)}× 类别最低价\n匹配能力：${candidate.rule.label}\n任务 ID：${candidate.jobId}\n\n已进入官方协商流程；买方指定归元后，系统事件才会提交申请。`;
  return run(['agent', 'user-notify', '--content', content], 10_000);
}

function main() {
  if (!/^[0-9]+$/u.test(agentId)) {
    process.stderr.write('AGENT_ID must be numeric.\n');
    return EXIT_CONFIG;
  }
  if (!/^0x[0-9a-f]{40}$/u.test(expectedToken)) {
    process.stderr.write('OKX_A2A_DISCOVERY_TOKEN_ADDRESS is invalid.\n');
    return EXIT_CONFIG;
  }

  ensurePrivateDir(stateDir);
  ensurePrivateDir(logDir);
  if (!acquireLock()) {
    log('skip reason=already_running');
    return EXIT_OK;
  }

  try {
    const result = run(['agent', 'recommend-task', '--agent-id', agentId]);
    if (result.status !== 0) {
      log(`recommend_failed status=${result.status}`);
      return EXIT_TEMPFAIL;
    }

    let tasks;
    try {
      tasks = parseRecommendations(result.stdout);
    } catch (error) {
      log(`parse_failed error=${error.message || error}`);
      return EXIT_DATAERR;
    }

    const state = readState();
    const eligible = [];
    for (const task of tasks) {
      const rule = classify(task);
      if (!rule || state.seen[task.jobId]) continue;
      eligible.push({ ...task, rule, valueScore: valueScore(task, rule) });
    }

    eligible.sort((a, b) => b.valueScore - a.valueScore || b.budget - a.budget || b.createdAt.localeCompare(a.createdAt));
    eligible.splice(maxNotifications);

    if (eligible.length === 0) {
      log(`scan matched=${tasks.length} eligible=0`);
      console.log(`AUTO_DISCOVERY matched=${tasks.length} eligible=0 notified=0`);
      return EXIT_OK;
    }

    if (process.env.OKX_A2A_DISCOVERY_DRY_RUN === '1') {
      console.log(JSON.stringify({ matched: tasks.length, eligible: eligible.map(({ jobId, title, budgetText, rule, valueScore: score }) => ({ jobId, title, budget: budgetText, service: rule.id, valueScore: score })) }));
      return EXIT_OK;
    }

    if (autoContact) {
      const previousContact = Date.parse(state.lastContactAt || '');
      if (Number.isFinite(previousContact) && Date.now() - previousContact < contactCooldownMs) {
        log(`scan matched=${tasks.length} eligible=${eligible.length} contact=skipped_cooldown`);
        console.log(`AUTO_DISCOVERY matched=${tasks.length} eligible=${eligible.length} contact=skipped_cooldown`);
        return EXIT_OK;
      }

      const candidate = eligible[0];
      const contactedAt = new Date().toISOString();
      const contacted = run(['agent', 'contact-user', candidate.jobId, '--agent-id', agentId]);
      state.lastContactAt = contactedAt;
      state.seen[candidate.jobId] = {
        notifiedAt: contactedAt,
        service: candidate.rule.id,
        budget: candidate.budgetText,
        valueScore: candidate.valueScore,
        contactStatus: contacted.status === 0 ? 'started' : 'failed',
      };
      writeState(state);
      if (contacted.status !== 0) {
        log(`contact_failed job=${candidate.jobId} status=${contacted.status}`);
        return EXIT_TEMPFAIL;
      }
      const notice = notifyContact(candidate);
      if (notice.status !== 0) log(`contact_notice_failed job=${candidate.jobId} status=${notice.status}`);
      log(`scan matched=${tasks.length} eligible=${eligible.length} contacted=1 job=${candidate.jobId}`);
      console.log(`AUTO_DISCOVERY matched=${tasks.length} eligible=${eligible.length} contacted=1`);
      return EXIT_OK;
    }

    const sent = notify(eligible);
    if (sent.status !== 0) {
      log(`notify_failed status=${sent.status}`);
      return EXIT_TEMPFAIL;
    }

    const notifiedAt = new Date().toISOString();
    for (const candidate of eligible) {
      state.seen[candidate.jobId] = { notifiedAt, service: candidate.rule.id, budget: candidate.budgetText, valueScore: candidate.valueScore };
    }
    writeState(state);
    log(`scan matched=${tasks.length} eligible=${eligible.length} notified=${eligible.length}`);
    console.log(`AUTO_DISCOVERY matched=${tasks.length} eligible=${eligible.length} notified=${eligible.length}`);
    return EXIT_OK;
  } finally {
    releaseLock();
  }
}

process.exitCode = main();
