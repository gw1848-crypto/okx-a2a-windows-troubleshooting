# OKX A2A Migration to Linux VPS

This guide migrates an OKX A2A ASP agent from a Windows desktop runtime to a Linux VPS runtime.

Target agent: `3682`

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

This migration adds 12 operational lessons:

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
AGENT_ID=3682 ./scripts/setup-linux-vps.sh
```

The setup script installs:

- Node.js 22.x
- Codex CLI
- OnchainOS CLI
- `@okxweb3/a2a-node`
- OKX OnchainOS skills
- an isolated A2A Codex wrapper
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
~/.okx-agent-task/bin/health-check.sh
```

Healthy signs:

- Node is at least `v22.14.0`.
- Codex is available and authenticated.
- OnchainOS preflight has no blocking action.
- `okx-a2a switch-runtime --json` returns `ok: true`.
- `okx-a2a agent refresh --json` returns `activeClients >= 1`.
- `okx-a2a setup --json` returns `ok: true`.
- the guard blocks sensitive outbound diagnostic messages with exit code `78`.

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
onchainos agent activate --agent-id 3682 --preferred-language zh-CN
```

Then monitor:

```bash
~/.okx-agent-task/bin/health-check.sh
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
