# OKX A2A Windows Troubleshooting

Windows 上运行 OKX A2A Agent 时，可能出现“守护进程在线、心跳正常，但 Agent 上架审核仍因无法及时响应而被驳回”的现象。

本文记录一次真实排障过程。所有 Agent ID、钱包地址、任务 ID、邮箱、本机用户名和业务资料均已移除。

## 现象

- A2A 守护进程持续运行。
- `agentCount=1`、`activeClients=1`。
- 心跳约每分钟成功一次。
- 审核邮件仍提示 Agent 无法及时响应功能验证。

这类情况不能只检查 VPN 或在线状态。`activeClients=1` 只说明通信客户端在线，不代表后台能在审核时限内完成处理和回调。

## 根因

本次故障由四个问题叠加造成：

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
- 运行时认证状态为 `ready`。

### 3. 验证通知回调

```powershell
onchainos agent user-notify --content "A2A notification self-test"
```

预期结果为 `OK`。如果提示 `program not found`，重新运行：

```powershell
okx-a2a doctor --fix
```

### 4. 为后台 Codex 使用精简参数

不要直接降低日常 Codex 会话的配置。仅为 A2A 守护进程设置独立参数：

- 使用适合自动化的较小模型和低推理等级。
- 加入 `--ignore-user-config`，避免加载无关个人配置和插件。
- 加入 `--ignore-rules`，避免加载与审核任务无关的执行规则。
- 保留必要的工作目录、沙箱和授权策略。

本次精简后，代表性冷启动耗时由 68 至 134 秒降低到约 17.5 秒。

> 参数模板应按当前 `okx-a2a` 版本的环境变量约定配置。升级后先运行 `okx-a2a doctor` 和 `okx-a2a setup --json`，不要盲目复制旧模板。

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
7. 最后再检查 VPN、TUN、系统休眠和网络出口。

不要看到“未及时响应”就立刻重装 VPN。先用日志区分：未收到、处理过慢、业务拒绝、回调失败。

## Windows 持续运行建议

- 禁止系统睡眠和休眠。
- Modern Standby 设备还需检查屏幕关闭是否触发断网待机。
- 保持代理/TUN 和 A2A 守护进程运行。
- 需要开机自启时，在管理员 PowerShell 中安装守护进程自启任务。
- 每次重启后执行健康检查，确认 `activeClients` 恢复。

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
