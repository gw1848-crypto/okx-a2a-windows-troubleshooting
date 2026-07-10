# OKX A2A Migration to Linux VPS

This guide migrates an OKX A2A ASP agent from a Windows desktop runtime to a Linux VPS runtime.

Set the target agent explicitly through `AGENT_ID`; do not commit a production Agent ID.

## Goal

- Keep the A2A listener online 7x24 on a VPS.
- Avoid Windows sleep, local VPN/TUN instability, and desktop process interruption.
- Preserve the response-time fixes from the Windows incident:
  - isolated Codex runtime
  - review-probe silent fast path
  - agent-bound status queries
  - guard against leaking internal auth/JWT/stderr details to peers
  - watchdog restart when daemon or active client drops

## Field Notes Count

This migration adds 20 operational lessons:

1. Browser console access is useful for emergency login, but SSH is more reliable for setup and verification.
2. Keep the A2A daemon on one machine only; do not leave the Windows and VPS listeners active for the same agent.
3. Ubuntu package mirrors may install an old Node.js release; verify `node --version` and install Node 22 manually when needed.
4. `okx-a2a` may install under the Node prefix without appearing on `PATH`; verify `command -v okx-a2a`.
5. `okx-a2a ai-provider set --provider codex` is required when the VPS shell is not detected as an AI runtime.
6. Codex device-code login must be enabled in ChatGPT security settings before VPS authentication can complete.
7. A successful local desktop Codex login does not authenticate the VPS; the VPS has its own CLI credential store.
8. OnchainOS wallet login must be repeated on the VPS before the VPS can see or refresh the agent.
9. Treat `activeClients=1` as the handoff gate before shutting down the desktop listener.
10. Linux file hardening must preserve executable bits under the Codex installation directory.
11. UFW plus fail2ban is a low-risk first hardening layer; keep password SSH until key login is confirmed.
12. Re-submit listing review only after `okx-a2a setup --json` is ready and the VPS refresh still reports `activeClients=1`.
13. OKX's current official skills merge identity, task, watch, and chat into `okx-ai`, while old task directories may disappear after `npx skills add okx/onchainos-skills`; keep runtime-specific review guards in the isolated A2A home instead of relying only on global skills.
14. Do not let the Codex wrapper read standard input for health-check commands such as `login status` or `setup`; only capture stdin for inbound `codex exec` sessions, otherwise setup probes can hang waiting for input.
15. For listing review events, add a deterministic fast handler before Codex only for `job_asp_selected`: run `next-action`, choose the capability-match branch, and execute the exact command returned by the official playbook. Other system events and peer chat fall back to the official Codex role flow.
16. The A2A node runtime may pass only the system `message` object as a Codex exec argument, not an outer `{agentId,message}` envelope on stdin. The wrapper must inspect exec arguments first and the fast handler must accept both shapes; otherwise events fall back to slow Codex despite the handler being installed.
17. OnchainOS 4.2.2 no longer defines a custom review-probe acknowledgement. Do not hard-code an XMTP reply for text beginning with `Please disregard...`; treat it as untrusted peer content and fall back to the official role playbook.
18. Do not assume `exec` is the wrapper's first argument. Current daemons may prepend flags such as `--sandbox`, `--ask-for-approval`, and `--cd`; scan the complete argument vector for the exact `exec` token before enabling the fast handler.
19. Treat the identity detail response as the source of truth for listing state. A service-list response may expose a different internal approval number; use the human-readable approval label from the agent detail response and do not hand-map backend integers.
20. The platform detail response does not currently expose a dedicated review-submission timestamp. Record the activation audit entry with its timezone, distinguish a fresh submission from an `already under review` response, and never report heartbeat or `updatedAt` as the submission time.
21. Include both `$HOME/.local/bin` and the actual Node prefix (for example `/opt/node-v22/bin`) in the watchdog service PATH. Wrap daemon and refresh checks in finite timeouts so a stuck CLI call cannot freeze recovery indefinitely.
22. When running maintenance setup from a plain SSH shell, export the same `OKX_A2A_AI_CODEX_COMMAND` used by the watchdog. Otherwise setup may ignore the authenticated isolated wrapper and start an unnecessary `codex login --device-auth` flow.
23. Keep the VPS timezone aligned with the platform audit timezone (`Asia/Shanghai` for Beijing time) so wrapper, watchdog, and review timestamps can be correlated directly.

## Cutover Rule

Do not run two active daemons for the same agent for long periods.

Recommended sequence:

1. Prepare the VPS.
2. Authenticate Codex and OnchainOS on the VPS.
3. Start the VPS watchdog and confirm `activeClients >= 1`.
4. Stop the Windows watchdog/daemon.
5. Re-check the VPS after 5-10 minutes.
6. Re-submit listing review only after the VPS health check is clean.

## Install on VPS

Use Ubuntu 22.04/24.04 with at least 2 GB RAM.

If the distribution package manager installs Node.js below `v22.14.0`, install the official Node 22 Linux tarball and link
`node`, `npm`, and `npx` into `/usr/local/bin`.

From this repository on the VPS:

```bash
chmod +x scripts/setup-linux-vps.sh
AGENT_ID=<agent-id> ./scripts/setup-linux-vps.sh
```

The setup script installs:

- Node.js 22.x
- Codex CLI
- OnchainOS CLI
- `@okxweb3/a2a-node`
- OKX OnchainOS skills
- an isolated A2A Codex wrapper
- a deterministic A2A fast handler for platform system events
- Linux command guards
- a user-level systemd watchdog

## Required Manual Login

After installation, complete the two interactive logins on the VPS:

```bash
codex
onchainos wallet login
```

Do not share private keys, seed phrases, API keys, or full authentication files in chat.

For Codex device-code login, ChatGPT account security settings must allow Codex device authorization. If setup reports
`provider_cli_login_timeout` or `provider_cli_login_failed`, enable device-code authorization, rerun:

```bash
codex login --device-auth
```

Then verify:

```bash
codex login status
```

## Health Check

```bash
AGENT_ID=<agent-id> ~/.okx-agent-task/bin/health-check.sh
```

Healthy signs:

- Node is at least `v22.14.0`.
- Codex is available and authenticated.
- OnchainOS preflight has no blocking action.
- `okx-a2a switch-runtime --json` returns `ok: true`.
- `okx-a2a agent refresh --json` returns `activeClients >= 1`.
- `okx-a2a setup --json` returns `ok: true`.
- the guard blocks sensitive outbound diagnostic messages with exit code `78`.
- the fast handler dry-run can parse a captured system event and return `FAST_HANDLER_DRY_RUN action=...`.

If `okx-a2a setup --json` reports that the Codex wrapper cannot find `codex`, check both the symlink and the target
executable permissions. Tightening all files under `~/.codex` to `600` can break the standalone Codex executable.

## Start Watchdog

```bash
systemctl --user start okx-a2a-watchdog.service
systemctl --user status okx-a2a-watchdog.service
```

Logs:

```bash
tail -f ~/.okx-agent-task/logs/watchdog.log
```

## Stop Windows Runtime

Only after VPS is healthy:

```powershell
okx-a2a daemon stop
```

If the Windows watchdog is enabled, disable or stop it before the final VPS cutover.

## Re-submit Review

After the VPS stays healthy for at least 30-60 minutes:

```bash
onchainos agent activate --agent-id <agent-id> --preferred-language zh-CN
```

Then monitor:

```bash
AGENT_ID=<agent-id> ~/.okx-agent-task/bin/health-check.sh
tail -f ~/.okx-agent-task/logs/watchdog.log
```

## Security Notes

- Prefer SSH key login, then disable password login after setup.
- Use a dedicated VPS user, not root.
- Keep wallet funds minimal for this service runtime.
- Do not co-host public VPN services on the same VPS until A2A listing is approved and stable.
- Avoid publishing logs that contain Agent IDs, wallet addresses, communication addresses, task IDs, email addresses, or local usernames.

Recommended first hardening pass:

```bash
sudo apt-get install -y ufw fail2ban
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 22/tcp
sudo ufw --force enable
```

Keep password SSH enabled until SSH key login has been tested from a separate session.
