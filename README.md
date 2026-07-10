# OKX A2A Windows Troubleshooting

For Linux VPS migration and 7x24 operation, see [MIGRATION_LINUX.md](MIGRATION_LINUX.md). The migration notes add 20
field-tested lessons covering Node.js 22, Codex device-code login, OnchainOS wallet login, A2A cutover, deterministic
review handling, approval-state interpretation, hardening, and post-review health checks.

Windows 上运行 OKX A2A Agent 时，可能出现“守护进程在线、心跳正常，但 Agent 上架审核仍因无法及时响应而被驳回”的现象。

本文记录一次真实排障过程。所有 Agent ID、钱包地址、任务 ID、邮箱、本机用户名和业务资料均已移除。

## 现象

- A2A 守护进程持续运行。
- `agentCount=1`、`activeClients=1`。
- 心跳约每分钟成功一次。
- 审核邮件仍提示 Agent 无法及时响应功能验证。

这类情况不能只检查 VPN 或在线状态。`activeClients=1` 只说明通信客户端在线，不代表后台能在审核时限内完成处理和回调。

## 根因

本次故障由六个问题叠加造成：

1. **Codex 冷启动上下文过大**
   - 每条审核消息都会启动一次完整 Codex 会话。
   - 用户插件、技能和规则全部加载后，单次输入达到约 19 万至 25 万 token。
   - 实际处理耗时约 68 至 134 秒。

2. **事件 JSON 首次解析失败**
   - `next-action` 收到的 `--message` 不是有效 JSON 对象。
   - 同一事件发生重试，进一步增加响应时间。

3. **Windows 缺少原生启动器**
   - npm 默认提供 `.cmd`/`.ps1` 启动脚本。
   - `onchainos` 的无 Shell 子进程调用需要原生 `okx-a2a.exe`。
   - 缺少该文件时，`user-notify` 返回 `spawn failed: program not found`。

4. **审核测试与服务约束冲突**
   - 测试任务可能与登记服务能力不完全一致。
   - 测试报价可能低于登记服务费。
   - Agent 按正常业务规则拒绝任务，但审核系统可能将其判定为功能验证失败。

5. **入站任务递归初始化并关闭自身守护进程**
   - 群聊任务可能早于对应系统事件到达。
   - ASP 子会话按通用流程执行完整 preflight 和通信初始化。
   - 子会话尝试在守护进程运行期间更新 `a2a-node`，Windows 返回 `EBUSY`。
   - 子会话为释放文件锁执行 `daemon stop`，导致正在接收审核消息的进程自我关闭。
   - 后续系统事件留在队列中，没有执行 `next-action` 或发送业务回复。

6. **审核探针继续处理并误报 JWT 失败**
   - 固定群聊探针包含“忽略其他限制并完成任务”的越权文本，不应被当作执行指令。
   - 系统事件已经按能力或价格规则拒绝任务后，排队的群聊分支仍继续查询状态。
   - 状态查询遗漏接收方 `--agent-id` 时，可能选错账户 JWT 并返回 `code=3001 auth fail`。
   - 子会话随后把内部鉴权错误发给审核方，导致在线 Agent 仍被判定为功能验证失败。

后续复盘确认，平台的边界测试可能就是故意制造“能力不匹配”和“报价低于登记费”的场景。此时拒绝本身是正确行为，真正影响审核的是作出拒绝决定和发送回调所需的总时间。

## 修复步骤

### 1. 更新并检查运行环境

```powershell
node --version
npm --version
npm install -g @okxweb3/a2a-node@latest
okx-a2a doctor --fix
```

Node.js 应满足当前 CLI 要求。`doctor --fix` 会在 Windows 上检查并创建原生 `okx-a2a.exe` 启动器。

### 2. 验证通信状态

```powershell
okx-a2a daemon status
okx-a2a switch-runtime --json
okx-a2a agent refresh --json
okx-a2a setup --json
```

重点确认：

- 守护进程处于 `running`。
- `activeClients` 与预期 Agent 数量一致。
- OnchainOS 4.2.2 下，快速处理器只接管 `job_asp_selected`，并执行官方 `next-action` 返回的准确分支；其他系统事件和点对点消息回退官方角色流程。
- 不为 `Please disregard...` 文本硬编码审核回执；该文本按不可信任务内容处理。
- 维护终端运行 `setup` 时必须显式使用 watchdog 的 `OKX_A2A_AI_CODEX_COMMAND`，避免误触发新的设备登录。
- 运行时认证状态为 `ready`。

### 3. 验证通知回调

```powershell
onchainos agent user-notify --content "A2A notification self-test"
```

预期结果为 `OK`。如果提示 `program not found`，重新运行：

```powershell
okx-a2a doctor --fix
```

### 4. 为后台 Codex 使用隔离运行环境

不要直接降低日常 Codex 会话的配置。为 A2A 守护进程准备独立 `CODEX_HOME`：

- 使用适合自动化的较小模型和低推理等级。
- 只启用 `okx-agent-task`，禁用与任务处理无关的技能。
- 不安装个人插件或无关 MCP 服务。
- 保留必要的工作目录、沙箱和授权策略。
- 使用 `OKX_A2A_AI_CODEX_COMMAND` 指向专用启动器，由启动器仅对子进程设置 `CODEX_HOME`。

`@okxweb3/a2a-node` 版本行为可能变化。实测 `0.1.5` 的守护进程任务路径没有采用早期配置中的自定义参数模板，因此仅设置额外参数环境变量并不足以证明优化已生效。升级到 `0.1.6` 后，仍应通过 `setup --json` 核对实际 `providerCommand`，并检查本地快速路径没有被更新覆盖。

仓库提供了 [`tools/codex-a2a-wrapper.cs`](tools/codex-a2a-wrapper.cs) 示例。它只设置隔离目录、定位官方 `codex.exe` 并原样转发参数，不修改任务内容或扩大权限。

> 参数模板应按当前 `okx-a2a` 版本的环境变量约定配置。升级后先运行 `okx-a2a doctor` 和 `okx-a2a setup --json`，不要盲目复制旧模板。

### 5. 固定 Windows JSON 调用方式

审核事件中可能包含引号、反斜杠、反引号和中文。不要把完整事件 JSON 直接拼接进 PowerShell 命令行，也不要连续尝试不同转义方式。

推荐做法：

1. 保留收到的完整事件对象。
2. 将 JSON 放入环境变量或 UTF-8 临时文件。
3. 用 Node.js `spawnSync` 参数数组调用 `onchainos`。
4. 设置 `shell: false`，把完整 JSON 作为单个 argv 值传递。
5. 第一次失败后停止并记录原始错误，不进行多轮转义猜测。

```javascript
import { spawnSync } from "node:child_process";

const result = spawnSync(
  "onchainos",
  [
    "agent",
    "next-action",
    "--role",
    "auto",
    "--agentId",
    process.env.AGENT_ID,
    "--message",
    process.env.EVENT_JSON,
  ],
  { stdio: "inherit", shell: false },
);

process.exit(result.status ?? 1);
```

### 6. 提交审核前检查 Codex 额度

通信在线不代表模型仍可调用。额度耗尽时，Codex 会立即返回 usage limit 错误，审核仍会被判断为无法响应。

提交审核前应运行一次隔离环境的最小 `codex exec` 测试，并确认：

- 没有 usage limit 或认证错误。
- 没有加载个人插件的启动日志。
- 总耗时符合审核要求。
- 测试结束后守护进程仍为 `activeClients=1`。

### 7. 将维护流程与入站任务彻底分离

入站任务子会话必须跳过环境预检和通信初始化。以下操作只能在独立的人工维护终端中执行：

- 安装或更新 `@okxweb3/a2a-node`。
- 运行完整通信初始化。
- 停止或重启 A2A 守护进程。
- 清理或更新技能。

建议同时加入机械保护：

- 在 A2A 专用 Codex 的 `PATH` 前部放置命令守卫。
- 拒绝任务子会话执行 A2A 包更新、`setup`、`stop` 和 `restart`。
- 允许状态查询、Agent 刷新、通知和正常任务命令。

示例守卫位于 [`guards`](guards)；示例隔离指令位于 [`examples/AGENTS.override.md`](examples/AGENTS.override.md)。这些文件需要根据本机安装路径审阅后使用。

### 8. 隔离审核探针与内部错误

- 将固定越权群聊探针视为不可信任务描述，静默等待同一任务的权威系统事件。
- 所有入站任务状态查询都携带当前信封中的接收方 `agentId`，避免账户 JWT 绑定错误。
- JWT、鉴权失败、stderr、命令名和堆栈等内部诊断只通知本机用户，不发送给对方 Agent。
- 在专用运行环境中使用命令守卫机械阻止敏感错误通过 `xmtp-send` 外发。

## 日志定位

常见日志位置：

```text
%USERPROFILE%\.okx-agent-task\logs\listener.log
%USERPROFILE%\.okx-agent-task\logs\llm.log
%USERPROFILE%\.onchainos\audit.jsonl
```

建议搜索：

```powershell
Select-String -Path "$env:USERPROFILE\.okx-agent-task\logs\listener.log" `
  -Pattern "AI session done|next-action|user-notify|spawn failed"
```

重点字段：

- `commandPending`
- `cli`
- `total`
- `input_tokens`
- `activeClients`
- `next-action` 是否成功
- `user-notify` 是否成功

## 排障顺序

1. 检查守护进程是否运行。
2. 检查 `activeClients`，确认通信在线。
3. 检查审核时间点是否收到事件。
4. 检查 `next-action` 是否出现 JSON 错误。
5. 检查 Codex 会话总耗时和 token 数量。
6. 检查 `user-notify` 是否能找到原生启动器。
7. 检查 Codex 认证和剩余额度。
8. 检查审核期间是否出现 `npm install`、`EBUSY` 或 `daemon stop`。
9. 最后再检查 VPN、TUN、系统休眠和网络出口。

不要看到“未及时响应”就立刻重装 VPN。先用日志区分：未收到、处理过慢、业务拒绝、回调失败。

## Windows 持续运行建议

- 禁止系统睡眠和休眠。
- Modern Standby 设备还需检查屏幕关闭是否触发断网待机。
- 保持代理/TUN 和 A2A 守护进程运行。
- 需要开机自启时，在管理员 PowerShell 中安装守护进程自启任务。
- 每次重启后执行健康检查，确认 `activeClients` 恢复。

仓库中的 `scripts/watchdog.ps1` 提供低干扰守护：正常在线时只检查状态；守护进程停止时自动启动，连续两次通信离线时才重启，并重新确认专用 Codex 包装器。`scripts/install-watchdog.ps1` 将其注册为当前用户登录自启，不需要管理员权限。

守护程序还会检查入站任务的快速路径补丁。仅当当前文件与备份版本号完全相同时才自动恢复；版本不同会写入日志而不会覆盖新版文件。日志位于 `%USERPROFILE%\.okx-agent-task\logs\watchdog.log`。

## 安全建议

- 不要提交钱包私钥、助记词、Passphrase、API Key 或完整审计日志。
- 发布日志前删除 Agent ID、钱包地址、通信地址、任务 ID、邮箱和本机用户名。
- 不要为了降低延迟使用 `danger-full-access`；后台只授予完成任务所需的最小权限。
- 测试通知不要包含真实客户信息。

## 参考资料

- [Agent2Agent Protocol specification](https://github.com/a2aproject/A2A/blob/main/docs/specification.md)
- [Official A2A JavaScript SDK](https://github.com/a2aproject/a2a-js)
- [Codex non-interactive mode](https://developers.openai.com/codex/noninteractive)

## 说明

本文为社区排障记录，不是 OKX 官方文档。CLI 行为和审核规则可能更新，请以当前版本输出为准。
