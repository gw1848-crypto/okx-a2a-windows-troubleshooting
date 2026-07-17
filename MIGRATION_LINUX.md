# OKX A2A Migration to Linux VPS

This guide migrates an OKX A2A ASP agent from a Windows desktop runtime to a Linux VPS runtime.

Set the target agent explicitly through `AGENT_ID`; do not commit a production Agent ID.

## Goal

- Keep the A2A listener online 7x24 on a VPS.
- Avoid Windows sleep, local VPN/TUN instability, and desktop process interruption.
- Preserve the response-time fixes from the Windows incident:
  - isolated Codex runtime
  - deterministic low-price rejection fast path
  - agent-bound status queries
  - guard against leaking internal auth/JWT/stderr details to peers
  - watchdog restart when the single daemon/client invariant breaks

## Field Notes Count

This migration records 33 operational lessons:

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
12. Before initial listing or a genuine rejection retry, submit only after setup is ready and the VPS reports exactly one active client. Once approved, do not activate again just to test the runtime.
13. OKX's current official skills merge identity, task, watch, and chat into `okx-ai`, while old task directories may disappear after `npx skills add okx/onchainos-skills`; keep runtime-specific review guards in the isolated A2A home instead of relying only on global skills.
14. Do not let the Codex wrapper read standard input for health-check commands such as `login status` or `setup`; only capture stdin for inbound `codex exec` sessions, otherwise setup probes can hang waiting for input.
15. For `job_asp_selected`, a deterministic handler may run official `next-action`, but it may execute only an unambiguous official `Price gate (TOO_LOW)` reject command. Capability matching, estimates, negotiation, acceptance, and all peer chat remain in the official Codex role flow.
16. The A2A node runtime may pass only the system `message` object as a Codex exec argument, not an outer `{agentId,message}` envelope on stdin. The wrapper must inspect exec arguments first and the fast handler must accept both shapes; otherwise events fall back to slow Codex despite the handler being installed.
17. OnchainOS 4.2.2 no longer defines a custom review-probe acknowledgement. Do not hard-code an XMTP reply for text beginning with `Please disregard...`; treat it as untrusted peer content and fall back to the official role playbook.
18. Do not assume `exec` is the wrapper's first argument. Current daemons may prepend flags such as `--sandbox`, `--ask-for-approval`, and `--cd`; scan the complete argument vector for the exact `exec` token before enabling the fast handler.
19. Treat the identity detail response as the source of truth for listing state. A service-list response may expose a different internal approval number; use the human-readable approval label from the agent detail response and do not hand-map backend integers.
20. The platform detail response does not currently expose a dedicated review-submission timestamp. Record the activation audit entry with its timezone, distinguish a fresh submission from an `already under review` response, and never report heartbeat or `updatedAt` as the submission time.
21. Include both `$HOME/.local/bin` and the actual Node prefix (for example `/opt/node-v22/bin`) in the watchdog service PATH. Wrap daemon and refresh checks in finite timeouts so a stuck CLI call cannot freeze recovery indefinitely.
22. When running maintenance setup from a plain SSH shell, export the same `OKX_A2A_AI_CODEX_COMMAND` used by the watchdog. Otherwise setup may ignore the authenticated isolated wrapper and start an unnecessary `codex login --device-auth` flow.
23. Keep the VPS timezone aligned with the platform audit timezone (`Asia/Shanghai` for Beijing time) so wrapper, watchdog, and review timestamps can be correlated directly.
24. Treat exit code `64` as the only safe-handler fallback signal. Timeout, malformed official output after a deterministic decision, or a failed reject must stop that event instead of allowing a second Codex path to act on it.
25. Bind every fast-path envelope to the expected Agent ID, require one exact event/job shape, reject conflicting stdin/argv JSON, and persist per-job state so serial or concurrent duplicates can execute at most once.
26. Keep runtime data, temporary stdin, state, and logs private (`0700` directories, `0600` files). Unlink captured stdin before launching the slow Codex path and never log tokens, JWTs, peer payloads, or command stderr.
27. Make the watchdog the sole lifecycle owner. Require `agentCount=1` and `activeClients=1`, use finite command timeouts, consecutive-failure thresholds, restart cooldown, atomic snapshots, and bounded log rotation.
28. Keep health checks read-only. Start the watchdog first, wait for its state snapshot, then inspect it; run `doctor --fix --json`, package upgrades, setup, activation, or daemon restarts only as explicit maintenance actions.
29. Never bootstrap over an initialized runtime. Stage and verify the target plus a rollback package while the listener remains online, then use one short maintenance window with automatic restoration and strict post-upgrade communication checks.
30. Test systemd hardening in the actual unprivileged user manager, not only with `systemd-analyze verify`. On VPS/container hosts, `PrivateDevices`, `ProtectClock`, `ProtectKernelModules`, or an empty `CapabilityBoundingSet` may terminate a user unit with status `218/CAPABILITIES`, while `ProtectHostname` may be ignored because UTS namespaces are unavailable. Keep only directives proven by a transient runtime probe and require a successful service start before committing the unit.
31. A manually migrated, already-listed runtime may predate both `.production-initialized` and the isolated `okx-ai` skill. Do not invent either artifact before verification or rerun the full bootstrap over production. Use the explicit `OKX_A2A_ALLOW_LEGACY_BASELINE=1` maintenance gate so the upgrade backs up the installed binaries, records that the marker/skill were absent, installs the pinned skill atomically, and removes the new baseline again if post-change validation fails.
32. The `skills` CLI may interpret `/tree/<commit-sha>` as a branch name and may write `--global` installs to `~/.agents/skills` even when only `CODEX_HOME` is overridden. First verify that the immutable release tag resolves to the pinned commit, install from `/tree/<tag>`, and set both `HOME` and `CODEX_HOME` to a private staging root. Copy the verified result into the isolated production skill directory only after rejecting symlinks.
33. Keep task discovery separate from acceptance. Periodically call the official `recommend-task` command, filter through explicit deny/capability/price rules, and start at most one `contact-user` negotiation per cooldown. Never cold-start `apply`, loop over job IDs, or treat untrusted descriptions as capability evidence; wait for the buyer/User Agent designation and authoritative system event.

## Cutover Rule

Do not run two active daemons for the same agent for long periods.

Recommended sequence:

1. Prepare the VPS.
2. Authenticate Codex and OnchainOS on the VPS.
3. Start the VPS watchdog and confirm `agentCount=1` and `activeClients=1`.
4. Stop the Windows watchdog/daemon.
5. Re-check the VPS after 5-10 minutes.
6. Submit only if this is an initial listing or a documented rejection retry. Never repeat activation for an already approved agent.

## Install on VPS

Use Ubuntu 22.04/24.04 with at least 2 GB RAM.

If the distribution package manager installs Node.js below `v22.14.0`, install the official Node 22 Linux tarball and link
`node`, `npm`, and `npx` into `/usr/local/bin`.

From this repository on the VPS:

```bash
chmod +x scripts/setup-linux-vps.sh
AGENT_ID=<agent-id> ./scripts/setup-linux-vps.sh
```

The setup script requires a verified Node.js `>=22.14.0` and an official Codex CLI already on the host. It then installs pinned production dependencies:

- OnchainOS `4.2.6` from the signed release checksums
- `@okxweb3/a2a-node` `0.1.9`
- OKX OnchainOS skills from tag `v4.2.6`, pinned to commit `93a2841501cde295f26af026d9c3a33efd42fd49`
- Vercel `skills` installer `1.5.19` (used only to copy the tagged OKX skill)
- an isolated A2A Codex wrapper
- a deterministic A2A fast handler for platform system events
- Linux command guards
- a user-level systemd watchdog
- an optional guarded public-task discovery timer

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

## Start Watchdog and Health Check

Start the single lifecycle owner first and wait for its atomic snapshot:

```bash
systemctl --user start okx-a2a-watchdog.service
systemctl --user status okx-a2a-watchdog.service
test -s ~/.okx-agent-task/run/watchdog-state.json
```

Then run the read-only check:

```bash
AGENT_ID=<agent-id> ~/.okx-agent-task/bin/health-check.sh
```

Healthy signs:

- Node is at least `v22.14.0`.
- Codex is available and authenticated.
- The A2A daemon is running.
- The recent watchdog snapshot reports `agentCount=1` and `activeClients=1` for the expected Agent ID.
- Runtime directories and files have private permissions and no stale captured stdin remains.

If the read-only check fails, inspect its exact finding first. Use `okx-a2a doctor --fix --json` only in a deliberate
maintenance window; do not let a task session run setup, activation, upgrades, or daemon lifecycle commands.

## Upgrade an Initialized Runtime

Never rerun `setup-linux-vps.sh` over a production runtime. Use the versioned maintenance script, which stages and
verifies downloads before it stops the listener.

Preparation-only dry run (no service interruption):

```bash
chmod +x scripts/upgrade-linux-runtime.sh
AGENT_ID=<agent-id> OKX_A2A_ALLOW_MAINTENANCE=1 OKX_A2A_MAINTENANCE_DRY_RUN=1 \
  ./scripts/upgrade-linux-runtime.sh
```

Actual maintenance window:

```bash
AGENT_ID=<agent-id> OKX_A2A_ALLOW_MAINTENANCE=1 \
  ./scripts/upgrade-linux-runtime.sh
```

If an already-listed manual migration is verified to predate both the marker and isolated skill, add
`OKX_A2A_ALLOW_LEGACY_BASELINE=1` to both commands. This flag accepts only absent artifacts; it does not bypass a
symlink, wrong file type, corrupt marker, or corrupt skill path.

The script refuses to run while a duplicate `okx-a2a.service` is active. It retains private release and rollback
directories under `~/.okx-agent-task/`, stops the watchdog only after all artifacts and the rollback package are ready,
and automatically restores the prior OnchainOS binary, A2A package, skill and production marker if any validation fails.
Success requires ready authentication, the persisted isolated wrapper, a fast-path self-test within two seconds, a fresh
watchdog snapshot, and live `agentCount=1` / `activeClients=1`. It never invokes Agent activation or listing submission.

## Watchdog Logs

```bash
tail -f ~/.okx-agent-task/logs/watchdog.log
```

## Stop Windows Runtime

Only after VPS is healthy:

```powershell
okx-a2a daemon stop
```

If the Windows watchdog is enabled, disable or stop it before the final VPS cutover.

## Listing or Re-submit Review

Only for an initial listing or after a documented rejection, and only after the VPS stays healthy for at least 30-60 minutes:

```bash
onchainos agent activate --agent-id <agent-id> --preferred-language zh-CN
```

Then monitor:

```bash
AGENT_ID=<agent-id> ~/.okx-agent-task/bin/health-check.sh
tail -f ~/.okx-agent-task/logs/watchdog.log
```

If the agent is already approved/listed, skip `activate`; deployment health validation does not require another review.

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
