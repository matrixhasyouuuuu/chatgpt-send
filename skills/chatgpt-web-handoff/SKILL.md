---
name: chatgpt-web-handoff
description: "Connect Codex CLI with ChatGPT Web ('Specialist') via chatgpt_send: keep one persistent chat, send messages, read replies back. UX: user speaks in natural language (no shell commands). Supports saved sessions, resume/new, and an N-iteration loop counter."
---

# ChatGPT Web Handoff ("Specialist")

## Glossary

- **Specialist**: a ChatGPT web chat in the browser (`chatgpt.com/c/...`).
- **Codex terminal**: only short user inputs + short status updates.
- **Bridge tool**: `chatgpt_send` (must be available on `PATH`).

## Hard Rules

- Do not run any repo analysis (`ls`, `rg`, tests, etc.) until the user gives an explicit **project path**.
- In Specialist mode:
  - send all findings, questions, plans, diffs, and test results to the Specialist
  - in the terminal, only show short status updates (what you sent/received, what you do next)
- The Specialist browser window must be **visible** and stay open.

## One Question At A Time (Important)

Users get annoyed when you dump 3-5 questions at once.

- Ask exactly **one** question.
- Wait for the answer.
- Then ask the next question.

If the user answers multiple items in one message, use it, but still continue one-by-one for any missing info.

## User UX (No Shell Commands)

The user might say:

1) "I want to work with the Specialist"
2) "Open the browser"
3) "Talk to the Specialist, max 5 iterations"
4) "Send to Specialist: <TEXT>"

You translate these into `chatgpt_send` calls internally.

## Startup Flow (Step-by-Step)

When the user says: **"I want to work with the Specialist"**

Step 1: Session
- If there are saved sessions, show them and ask one question:
  - "Resume `last` (recommended), pick another, or `new`?"

Step 2: Project path
- Ask:
  - "Give me the full path to the project folder."

Step 3: Iterations
- If the user didn't specify N, ask:
  - "How many Specialist iterations? (2/3/5)"

Step 4: Title (only for new session)
- Ask:
  - "Short title for this session (what are we working on)?"

Step 5: Open browser
- If resuming an existing session:
  - `chatgpt_send --use-chat <name-or-index>`
  - `chatgpt_send --open-browser`
- If creating a new session:
  - `chatgpt_send --open-browser --chatgpt-url https://chatgpt.com/`

Step 6: User writes the intro in the web chat
- Say one sentence:
  - "Write one intro message to the Specialist in the browser, then tell me: `ready`."
- Wait for `ready`.

Step 7: Pin chat + set title
- After user says `ready`:
  - `chatgpt_send --sync-chatgpt-url`
  - `chatgpt_send --set-active-title "<title> (<YYYY-MM-DD>)"`

Step 8: Initialize loop
- `chatgpt_send --loop-init N`
- Run exactly N Specialist back-and-forths.

## Iteration Loop

Before each send:
- Read `done/max` via `chatgpt_send --loop-status`
- Set `i = done + 1`, `N = max`
- Prefix the message with: `Iteration i/N.`
- On the last iteration, add:
  - "This is the last iteration. Give a final answer and a verification checklist."

After each Specialist reply:
- `chatgpt_send --loop-inc`
- Terminal status: remaining iterations.

After the loop ends:
- `chatgpt_send --loop-clear`

## Commands You Run Internally

Never use `xdg-open` and do not depend on other tools like `oracle`.

Open browser:

```bash
chatgpt_send --open-browser
```

List / switch sessions:

```bash
chatgpt_send --list-chats
chatgpt_send --use-chat last
chatgpt_send --use-chat 2
```

Send to Specialist and wait for final answer:

```bash
chatgpt_send --prompt "TEXT"
```

## If Cloudflare Shows Up

- Ask the user to solve "Just a moment..." in the open browser window.
- Retry sending.

## Safety

- Never send secrets (API keys, passwords, tokens, private keys, personal data) to the Specialist.

