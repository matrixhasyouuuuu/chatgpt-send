# chatgpt-send

Send a prompt to ChatGPT **in your browser** and get the final assistant reply back in your terminal.

This is a small, pragmatic bridge for a workflow like:

- **Codex (CLI)**: reads code, runs commands, edits files.
- **Specialist (ChatGPT Web)**: keeps long context, does web research, sanity-checking, strategy.
- **`chatgpt_send`**: moves messages between them while you keep the browser visible and can intervene anytime.

Not affiliated with OpenAI. This is UI automation: it can break when ChatGPT's web UI changes.

## How It Works

`chatgpt_send` controls an already-open ChatGPT Web tab using **Chrome DevTools Protocol (CDP)**:

- types your prompt into the composer
- clicks Send
- waits for generation to finish
- scrapes the last assistant message from the page DOM
- prints it to stdout

State is stored under `state/` (pinned chat URL, saved sessions, loop counters, and a dedicated Chrome profile for login).

## Requirements

- Linux + Chrome/Chromium (other OS can work but you'll likely need a custom `--chrome-path`)
- Python 3.10+
- `curl`
- Python package: `websocket-client`
- Optional: `wmctrl` (focus Chrome window)

Install Python deps:

```bash
pip3 install -r requirements.txt
```

## Quick Start

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

## Use An Existing Chat

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

## Saved Sessions ("Specialist Chats")

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

## Iteration Loop (N Back-and-Forths)

This is just a per-session counter stored in `state/`. It's useful for agent workflows:

```bash
./bin/chatgpt_send --loop-init 5
./bin/chatgpt_send --loop-status
./bin/chatgpt_send --loop-inc
./bin/chatgpt_send --loop-clear
```

## Codex Integration (Optional)

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
- "Open the browser"
- "Talk to the Specialist, max 5 iterations"

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

