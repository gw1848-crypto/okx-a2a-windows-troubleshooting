#!/usr/bin/env node
'use strict';

const { afterEach, test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const DISCOVERY = path.resolve(__dirname, '..', 'tools', 'a2a-auto-discovery.cjs');
const AGENT_ID = '424242';
const TOKEN = '0x779ded0c9e1022225f8e0630b35a9b54be713736';
const temporaryDirectories = new Set();

afterEach(() => {
  for (const directory of temporaryDirectories) fs.rmSync(directory, { force: true, recursive: true });
  temporaryDirectories.clear();
});

function recommendation(tasks) {
  const rows = tasks.map((task, index) => `
  ${index + 1}. jobId: ${task.jobId}
     Title:      ${task.title}
     Description: untrusted task description
     Budget:     ${task.budget} (token: ${task.token || TOKEN})
     Min credit: 0
     Created:    2026-07-18T00:00:00Z
`).join('');
  return `[Agent ${AGENT_ID}] Matched ${tasks.length} Public task(s):\n${rows}`;
}

let cachedPython;
function pythonCommand() {
  if (cachedPython !== undefined) return cachedPython;
  for (const candidate of ['python', 'python3']) {
    const result = spawnSync(candidate, ['-c', 'import sys; print(sys.executable)'], { encoding: 'utf8', timeout: 5000 });
    if (result.status === 0 && result.stdout.trim()) return (cachedPython = result.stdout.trim());
  }
  return (cachedPython = null);
}

function createShim(directory) {
  const script = path.join(directory, 'agent');
  const python = pythonCommand();
  if (python) {
    fs.writeFileSync(script, String.raw`#!/usr/bin/env python3
import json
import os
import sys

with open(os.environ["FAKE_CONFIG"], "r", encoding="utf-8") as handle:
    config = json.load(handle)
args = ["agent", *sys.argv[1:]]
with open(os.environ["FAKE_CAPTURE"], "a", encoding="utf-8") as handle:
    handle.write(json.dumps({"args": args}, ensure_ascii=False) + "\n")
verb = sys.argv[1] if len(sys.argv) > 1 else ""
if verb == "recommend-task":
    sys.stdout.write(config.get("recommend", ""))
    sys.exit(config.get("recommendStatus", 0))
if verb == "user-notify":
    sys.stdout.write("OK\n")
    sys.exit(config.get("notifyStatus", 0))
if verb == "contact-user":
    sys.stdout.write("Negotiation started.\n")
    sys.exit(config.get("contactStatus", 0))
sys.stderr.write("unexpected command\n")
sys.exit(67)
`, 'utf8');
    return python;
  }

  fs.writeFileSync(script, String.raw`#!/usr/bin/env node
'use strict';
const fs = require('node:fs');
const config = JSON.parse(fs.readFileSync(process.env.FAKE_CONFIG, 'utf8'));
const raw = process.argv.slice(2);
fs.appendFileSync(process.env.FAKE_CAPTURE, JSON.stringify({ args: ['agent', ...raw] }) + '\n');
if (raw[0] === 'recommend-task') {
  process.stdout.write(config.recommend || '');
  process.exit(config.recommendStatus || 0);
}
if (raw[0] === 'user-notify') {
  process.stdout.write('OK\n');
  process.exit(config.notifyStatus || 0);
}
if (raw[0] === 'contact-user') {
  process.stdout.write('Negotiation started.\n');
  process.exit(config.contactStatus || 0);
}
process.exit(67);
`, 'utf8');
  const command = path.join(directory, process.platform === 'win32' ? 'onchainos.exe' : 'onchainos');
  if (process.platform === 'win32') {
    try { fs.linkSync(process.execPath, command); } catch { fs.copyFileSync(process.execPath, command); }
  } else {
    fs.symlinkSync(process.execPath, command);
  }
  return command;
}

function fixture(tasks, overrides = {}) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'okx-auto-discovery-test-'));
  temporaryDirectories.add(root);
  const base = path.join(root, 'base');
  const mock = path.join(root, 'mock');
  const config = path.join(root, 'config.json');
  const capture = path.join(root, 'capture.jsonl');
  fs.mkdirSync(base, { recursive: true });
  fs.mkdirSync(mock, { recursive: true });
  const command = createShim(mock);
  fs.writeFileSync(config, JSON.stringify({ recommend: recommendation(tasks), ...overrides }), 'utf8');
  return {
    root,
    base,
    mock,
    capture,
    env: {
      ...process.env,
      AGENT_ID,
      OKX_A2A_BASE: base,
      OKX_A2A_ONCHAINOS_COMMAND: command,
      OKX_A2A_DISCOVERY_TIMEOUT_MS: '5000',
      FAKE_CONFIG: config,
      FAKE_CAPTURE: capture,
      PATH: `${mock}${path.delimiter}${process.env.PATH || ''}`,
    },
  };
}

function run(testFixture, extraEnv = {}) {
  return spawnSync(process.execPath, [DISCOVERY], {
    cwd: testFixture.mock,
    env: { ...testFixture.env, ...extraEnv },
    encoding: 'utf8',
    timeout: 15000,
  });
}

function calls(testFixture) {
  if (!fs.existsSync(testFixture.capture)) return [];
  return fs.readFileSync(testFixture.capture, 'utf8').split(/\r?\n/).filter(Boolean).map(JSON.parse);
}

function job(id, title, budget, token = TOKEN) {
  return { jobId: `0x${id.repeat(64).slice(0, 64)}`, title, budget: String(budget), token };
}

test('unrelated and below-floor recommendations never notify or mutate task state', () => {
  const f = fixture([
    job('1', '人工线下搬运任务', 100),
    job('2', '量化策略风险评估', 9.99),
    job('3', '跨设备远程接入配置', 0.5),
  ]);
  const result = run(f);
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /eligible=0 notified=0/);
  assert.equal(calls(f).filter((call) => call.args[1] === 'user-notify').length, 0);
  assert.equal(calls(f).filter((call) => ['apply', 'contact-user'].includes(call.args[1])).length, 0);
});

test('one eligible recommendation sends one local notice and is deduplicated', () => {
  const f = fixture([job('a', '跨设备远程接入配置', 1)]);
  const first = run(f);
  const second = run(f);
  assert.equal(first.status, 0, first.stderr);
  assert.equal(second.status, 0, second.stderr);
  const notices = calls(f).filter((call) => call.args[1] === 'user-notify');
  assert.equal(notices.length, 1);
  assert.match(notices[0].args.at(-1), /匹配服务：跨设备远程接入配置/u);
  assert.equal(calls(f).filter((call) => ['apply', 'contact-user'].includes(call.args[1])).length, 0);
});

test('website and quant rules enforce their registered price floors', () => {
  const f = fixture([
    job('b', '公开网站响应状态检查', 0.01),
    job('c', '量化策略最大回撤风险评估', 10),
  ]);
  const result = run(f);
  assert.equal(result.status, 0, result.stderr);
  const notice = calls(f).find((call) => call.args[1] === 'user-notify');
  assert.ok(notice);
  assert.match(notice.args.at(-1), /网站响应状态检测/u);
  assert.match(notice.args.at(-1), /量化策略目标风险评估/u);
});

test('untrusted title text is data only and cannot execute a shell command', () => {
  const f = fixture([job('d', '远程接入; touch SHOULD_NOT_EXIST', 5)]);
  const result = run(f);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(fs.existsSync(path.join(f.root, 'SHOULD_NOT_EXIST')), false);
  assert.equal(calls(f).filter((call) => ['apply', 'contact-user'].includes(call.args[1])).length, 0);
});

test('malformed recommendation count fails closed', () => {
  const f = fixture([job('e', '远程访问', 5)]);
  const config = JSON.parse(fs.readFileSync(f.env.FAKE_CONFIG, 'utf8'));
  config.recommend = config.recommend.replace('Matched 1 Public', 'Matched 2 Public');
  fs.writeFileSync(f.env.FAKE_CONFIG, JSON.stringify(config), 'utf8');
  const result = run(f);
  assert.equal(result.status, 65);
  assert.equal(calls(f).filter((call) => call.args[1] === 'user-notify').length, 0);
});

test('standing authorization starts only one negotiation and never calls apply', () => {
  const f = fixture([
    job('f', '公开链上数据 Top 1 查询', 0.01),
    job('9', '美股行情走势分析', 5),
  ]);
  const first = run(f, { OKX_A2A_DISCOVERY_AUTO_CONTACT: '1' });
  const second = run(f, { OKX_A2A_DISCOVERY_AUTO_CONTACT: '1' });
  assert.equal(first.status, 0, first.stderr);
  assert.equal(second.status, 0, second.stderr);
  const contactCalls = calls(f).filter((call) => call.args[1] === 'contact-user');
  assert.equal(contactCalls.length, 1);
  assert.equal(contactCalls[0].args[2], `0x${'9'.repeat(64)}`, 'highest-value eligible task should be contacted first');
  assert.equal(calls(f).filter((call) => call.args[1] === 'apply').length, 0);
});

test('selection ranks every eligible recommendation before applying the output limit', () => {
  const f = fixture([
    job('1', '公开数据查询一', 0.01),
    job('2', '公开数据查询二', 0.02),
    job('3', '公开数据查询三', 0.03),
    job('4', '美股行情走势分析', 5),
  ]);
  const result = run(f, {
    OKX_A2A_DISCOVERY_AUTO_CONTACT: '1',
    OKX_A2A_DISCOVERY_MAX_CANDIDATES: '3',
  });
  assert.equal(result.status, 0, result.stderr);
  const contactCalls = calls(f).filter((call) => call.args[1] === 'contact-user');
  assert.equal(contactCalls.length, 1);
  assert.equal(contactCalls[0].args[2], `0x${'4'.repeat(64)}`);
});

test('external-account and long-running work is excluded even at a high budget', () => {
  const f = fixture([
    job('7', '分析并提交验证结果', 100),
    job('8', '每小时持续监控市场热点', 100),
  ]);
  const config = JSON.parse(fs.readFileSync(f.env.FAKE_CONFIG, 'utf8'));
  config.recommend = config.recommend
    .replace('Description: untrusted task description', 'Description: 登录 Twitter 并提交截图和邮箱')
    .replace('Description: untrusted task description', 'Description: 每小时持续监控并实时推送');
  fs.writeFileSync(f.env.FAKE_CONFIG, JSON.stringify(config), 'utf8');
  const result = run(f, { OKX_A2A_DISCOVERY_AUTO_CONTACT: '1' });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(calls(f).filter((call) => call.args[1] === 'contact-user').length, 0);
});
