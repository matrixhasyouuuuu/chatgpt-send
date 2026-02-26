# chatgpt-send

A tiny CLI bridge: send a prompt to ChatGPT **in your browser** and get the final assistant reply back in your terminal.

No API keys. Uses your ChatGPT Web login.

Best use-case: a "two-brain loop":

- **Codex (CLI)**: reads code, runs commands, edits files.
- **Specialist (ChatGPT Web)**: keeps long context, does web research, sanity-checking, strategy.
- **`chatgpt_send`**: moves messages between them while you keep the browser visible and can intervene anytime.

Not affiliated with OpenAI. This is UI automation: it can break when ChatGPT's web UI changes.

## 30-Second Demo

```bash
git clone https://github.com/matrixhasyouuuuu/chatgpt-send.git
cd chatgpt-send
pip3 install -r requirements.txt

./bin/chatgpt_send --open-browser
# Log into chatgpt.com in the opened Chrome window (one time)

./bin/chatgpt_send --init-specialist --topic "hello"
./bin/chatgpt_send --prompt "Reply with exactly: pong"
```

## Install Once (Then Use Anywhere)

If you want to install once and stop thinking about paths, put `chatgpt_send` on your `PATH`:

```bash
git clone https://github.com/matrixhasyouuuuu/chatgpt-send.git ~/opt/chatgpt-send
cd ~/opt/chatgpt-send
pip3 install --user -r requirements.txt

mkdir -p ~/.local/bin
ln -sf "$(pwd)/bin/chatgpt_send" ~/.local/bin/chatgpt_send
```

One-time login (keeps a dedicated browser profile under `state/`):

```bash
chatgpt_send --open-browser
```

Now you can run it from any folder:

```bash
chatgpt_send --init-specialist --topic "my task"
chatgpt_send --prompt "Reply with exactly: pong"
```

Update later:

```bash
cd ~/opt/chatgpt-send && git pull
```

## Why This Exists

- Codex is great at executing. The Specialist is great at holding long context + fresh docs.
- You can cap back-and-forth to N iterations (and stop anytime).
- One chat thread per task, not a new chat every time.
- Optional: a Codex skill so you can drive this in plain English (no shell commands).

## Why It's Powerful (Plain English)

Think of it as giving your coding agent a research teammate.

When you ask a coding agent: “find the bug in this repo”, you often get a short answer, a wrong guess, or a pile of clarifying questions.

This workflow helps because it splits roles:

- **Codex** gathers *evidence* (reads code, runs commands, extracts logs, tests hypotheses).
- **The Specialist (ChatGPT Web)** turns that evidence into a *better next step* (what to check next, where to look, which docs matter).

In practice this means:

- A vague idea becomes a structured checklist.
- You can keep “the long story” in one web chat while Codex stays focused on execution.
- The Specialist can use web browsing / up-to-date docs (depending on your ChatGPT plan/features).
- You control the loop: run N iterations, stop/steer anytime, and the browser stays visible.
- Works with whatever model you pick in the ChatGPT Web UI and whatever model Codex is running.

If you want the longer pitch + examples (for sharing), see: `docs/WHY.md`.

## AI Agent Integration (JSON-first)

If another CLI/AI agent needs to use this tool, the easiest path is the UX facade + JSON outputs:

```bash
chatgpt_send --status --json
chatgpt_send --explain latest --json
chatgpt_send step read --json
chatgpt_send step send --message "..."
chatgpt_send --ack
```

Docs for integrations:

- `AGENTS.md` (quick rules / safety model / loop)
- `docs/AI_AGENT_INTEGRATION.md` (practical integration flow)
- `docs/JSON_CONTRACTS.md` (`status.v1`, `explain.v1`, `step.v1`)
- `docs/ERRORS.md` (common `E_*` and handling)
- `docs/ENV_FLAGS.md` (runtime/planner flags)

## Requirements

- Linux + Chrome/Chromium (other OS can work but you'll likely need a custom `--chrome-path`)
- Python 3.10+
- `curl`
- Python package: `websocket-client`
- Optional: `wmctrl` (focus Chrome window)

Install deps:

```bash
pip3 install -r requirements.txt
```

<details>
<summary><strong>Quick Start (step-by-step)</strong></summary>

1) Open the automation browser and sign in once:

```bash
./bin/chatgpt_send --open-browser
```

A Chrome window will open with a dedicated profile at `state/manual-login-profile`. Log into `chatgpt.com` there.

2) Create a new "Specialist" chat and pin it:

```bash
./bin/chatgpt_send --init-specialist --topic "my task"
```

3) Send prompts and get answers:

```bash
./bin/chatgpt_send --prompt "Reply with only: pong"
```

Or via stdin:

```bash
printf '%s\n' "my prompt" | ./bin/chatgpt_send
```

</details>

<details>
<summary><strong>Use an existing chat</strong></summary>

Pin a specific ChatGPT chat:

```bash
./bin/chatgpt_send --set-chatgpt-url "https://chatgpt.com/c/<CHAT_ID>"
```

Auto-detect the only open `https://chatgpt.com/c/...` tab and pin it:

```bash
./bin/chatgpt_send --sync-chatgpt-url
```

Show the currently pinned chat:

```bash
./bin/chatgpt_send --show-chatgpt-url
```

</details>

<details>
<summary><strong>Saved sessions ("Specialist chats")</strong></summary>

Sessions are stored in:

- `state/chats.json`
- `state/sessions.md`

List saved chats:

```bash
./bin/chatgpt_send --list-chats
```

Switch active chat:

```bash
./bin/chatgpt_send --use-chat last
./bin/chatgpt_send --use-chat 2
```

Save current/resolved chat as a name:

```bash
./bin/chatgpt_send --save-chat alpha
```

</details>

<details>
<summary><strong>Iteration loop (N back-and-forths)</strong></summary>

This is just a per-session counter stored in `state/`. It's useful for agent workflows:

```bash
./bin/chatgpt_send --loop-init 5
./bin/chatgpt_send --loop-status
./bin/chatgpt_send --loop-inc
./bin/chatgpt_send --loop-clear
```

</details>

<details>
<summary><strong>Auto commit helper (optional)</strong></summary>

If you want an extra helper to auto-commit after meaningful file growth:

```bash
./bin/commit_agent --repo /abs/project/path --push
```

Behavior:
- In default mode, commits all current repo changes.
- If there is nothing to commit, prints `нечего коммитить` and exits.
- Optional trigger mode: add `--trigger-file path --min-growth 10` to commit only after line growth in that file.

</details>

<details>
<summary><strong>Spawn second Codex agent (optional)</strong></summary>

You can launch a child Codex agent. By default it uses the same Specialist browser/profile/cookies as the main agent:

```bash
./bin/spawn_second_agent \
  --project-path /abs/project/path \
  --task "Investigate and fix X" \
  --iterations 3 \
  --launcher window \
  --browser-required \
  --skip-git-repo-check \
  --wait
```

Behavior:
- Default mode: shared browser profile/cookies + CDP 9222, with per-child state/chat metadata.
- Optional isolated mode: add `--isolated-browser` (separate root/port).
- Browser policy is explicit per child:
- `--browser-required` forces child to use Specialist/browser and report evidence.
- `--browser-optional` lets child decide.
- `--browser-disabled` forbids Specialist/browser for that child.
- `--skip-git-repo-check` avoids startup failure when child project is outside trusted git repo.
- Opens child Specialist browser only when policy allows and `--open-browser` is active.
- Runs child `codex exec` and returns `CHILD_RESULT=...` in `--wait` mode.
- In no-wait mode, starts background auto-monitor by default and prints:
- `AUTO_MONITOR=1`, `MONITOR_LOG_FILE=...`, `MONITOR_PID_FILE=...`.
- Disable with `--no-auto-monitor`.

Run several child agents (parallel example):

```bash
./bin/spawn_second_agent --project-path /abs/project/a --task "Task A" --iterations 5 --launcher window
./bin/spawn_second_agent --project-path /abs/project/b --task "Task B" --iterations 5 --launcher window
./bin/spawn_second_agent --project-path /abs/project/c --task "Task C" --iterations 5 --launcher window
```

Each command prints `RUN_ID`, `LOG_FILE`, `LAST_FILE`, `EXIT_FILE` and auto-monitor metadata. You can rely on monitor logs instead of manual polling.

When you launch several child agents under one run root, monitor the whole fleet and get a final summary automatically:

```bash
./scripts/child_fleet_monitor.sh \
  --pool-run-dir /abs/path/to/pool_run \
  --poll-sec 2 \
  --summary-json /abs/path/to/pool_run/fleet.summary.json
```

Monitor writes atomic snapshots (`fleet.summary.json` + `fleet.summary.csv`) with per-agent classes (`RUNNING`, `STUCK`, `DONE_OK`, `DONE_FAIL`, `ORPHANED`) and uses single-instance lock/pid files.

`scripts/agent_pool_run.sh` can also run this monitor automatically (with watchdog restart + strict end-of-run gate). The pool output includes:
- `POOL_FLEET_MONITOR_LOG`, `POOL_FLEET_SUMMARY_JSON`, `POOL_FLEET_EVENTS_JSONL`, `POOL_FLEET_HEARTBEAT_FILE`
- `POOL_FLEET_ROSTER_JSONL` (orchestrator append-only roster; used with registry as second source)
- `POOL_FLEET_GATE_STATUS`, `POOL_FLEET_GATE_REASON`, `POOL_FLEET_GATE_EXPECTED_TOTAL`, `POOL_FLEET_GATE_OBSERVED_TOTAL`, `POOL_FLEET_GATE_MISSING_ARTIFACTS_TOTAL`, `POOL_FLEET_WATCHDOG_RESTARTS`
- `POOL_CHAT_OK_TOTAL`, `POOL_CHAT_MISMATCH_TOTAL`, `POOL_CHAT_UNKNOWN_TOTAL`, `POOL_STRICT_CHAT_PROOF`
- `POOL_GC_ROOT`, `POOL_GC_APPLIED`, `POOL_GC_REASON`, `POOL_GC_LOG` (retention/GC pre-run status)
- `POOL_REPORT_MD`, `POOL_REPORT_JSON`, `POOL_REPORT_STATUS` (единый итоговый отчёт по пулу)
- `POOL_STATUS=INTERRUPTED` + `POOL_ABORT_SIGNAL` on SIGINT/SIGTERM cleanup
- `E_POOL_ALREADY_RUNNING` protection via single-flight pool lock

For scaled live runs (5-10 agents), prepare chat pool with:

```bash
./scripts/chat_pool_manage.sh extract --out state/chat_pool_e2e_10.txt --count 10
./scripts/chat_pool_manage.sh validate --chat-pool-file state/chat_pool_e2e_10.txt --min 10
```

Then run live demo directly in pool mode:

```bash
RUN_LIVE_CDP_E2E=1 LIVE_CONCURRENCY=10 LIVE_CHAT_POOL_FILE=state/chat_pool_e2e_10.txt \
  ./scripts/run_live_multi_agent_demo.sh
```

Optional but recommended before large live runs:

```bash
./scripts/live_chat_pool_precheck.sh --chat-pool-file state/chat_pool_e2e_10.txt --concurrency 10
```

This uses read-only chat probes (`chatgpt_send --probe-chat-url ... --no-state-write`) and fails fast if at least one chat is not ready.

</details>

<details>
<summary><strong>Codex integration (optional)</strong></summary>

This repo ships a Codex skill that makes the UX "speak in natural language" and keeps a single Specialist chat per task.

Skill file:

- `skills/chatgpt-web-handoff/SKILL.md`

Install it:

```bash
mkdir -p ~/.codex/skills/local/chatgpt-web-handoff
cp skills/chatgpt-web-handoff/SKILL.md ~/.codex/skills/local/chatgpt-web-handoff/SKILL.md
```

Make sure `chatgpt_send` is on your `PATH` (one option):

```bash
mkdir -p ~/.local/bin
ln -sf "$(pwd)/bin/chatgpt_send" ~/.local/bin/chatgpt_send
```

Then in Codex you can say things like:

- "I want to work with the Specialist"
- "Работаем со Специалистом"
- "Open the browser"
- "Talk to the Specialist, max 5 iterations"
- "Explain how Specialist mode works"
- "Run 5 child agents and split tasks by folders"
- "Help me split one goal across agents"

You can also just talk normally (e.g. Russian is fine). The skill will guide you one question at a time and run the right `chatgpt_send` commands behind the scenes.

</details>

## How It Works (Under the Hood)

`chatgpt_send` controls an already-open ChatGPT Web tab via **Chrome DevTools Protocol (CDP)**:

- types your prompt into the composer
- clicks Send
- waits for generation to finish
- scrapes the last assistant message from the page DOM
- prints it to stdout

State is stored under `state/` (pinned chat URL, saved sessions, loop counters, and a dedicated Chrome profile for login).

## Security Notes

- This uses CDP (`--remote-debugging-port`). It binds to `127.0.0.1` by default. Do not expose it.
- `state/manual-login-profile` contains browser data/cookies. Treat `state/` as sensitive.
- `bin/chrome_no_sandbox` uses `--no-sandbox`. That's unsafe. Use only on a trusted machine, or pass `--chrome-path` to use your normal Chrome.

## Troubleshooting

- Cloudflare / "Just a moment...": solve it in the open browser window, then retry.
- If you have multiple `https://chatgpt.com/c/...` tabs open, `--sync-chatgpt-url` may refuse to guess. Close extras or pass `--chatgpt-url`.
- Health check:

```bash
./bin/chatgpt_send --doctor
```

test greptile
