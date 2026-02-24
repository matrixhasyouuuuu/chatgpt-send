---
name: chatgpt-web-handoff
description: "Понятный мост между Codex CLI и ChatGPT Web ('Specialist') через chatgpt_send: работа без shell-команд, один постоянный чат со Specialist, и координация мультиагентов как мягкий рой (главный агент = координатор/мозг, child-агенты = параллельные исполнители без жёстких запретов)."
---

# ChatGPT Web Handoff ("Specialist")

## Glossary

- **Specialist**: a ChatGPT web chat in the browser (`chatgpt.com/c/...`).
- **Codex terminal**: only short user inputs + short status updates.
- **Bridge tool**: `chatgpt_send` (prefer `PATH`, fallback to absolute binary path).

## Bridge Command Resolution (Mandatory)

Before first Specialist command in a turn, resolve bridge binary once:

```bash
if command -v chatgpt_send >/dev/null 2>&1; then
  CHATGPT_SEND_BIN="$(command -v chatgpt_send)"
elif [[ -x /home/matrix/projects/chatgpt-send/bin/chatgpt_send ]]; then
  CHATGPT_SEND_BIN="/home/matrix/projects/chatgpt-send/bin/chatgpt_send"
else
  echo "chatgpt_send not found"
fi
```

Rules:
- If fallback path exists, use it silently and continue.
- Ask user for install/path only when both checks fail.
- For all bridge actions in this skill, run `$CHATGPT_SEND_BIN ...` instead of bare `chatgpt_send`.

## Hard Rules

- Do not run any repo analysis (`ls`, `rg`, tests, etc.) until the user gives an explicit **project path**.
- For this workflow, all user-facing texts (questions, statuses, summaries, child tasks) must be in **Russian** unless user explicitly asks another language.
- In Specialist mode:
  - send all findings, questions, plans, diffs, and test results to the Specialist
  - in the terminal, only show short status updates (what you sent/received, what you do next)
- The Specialist browser window must be **visible** and stay open.
- If the user explicitly says "decide yourself", "autonomous", "не спрашивай", or equivalent:
  - switch to **autonomous coordinator mode**
  - do not ask setup questions about agent count/mode/browser policy/iterations unless a real blocker remains
  - choose reasonable defaults yourself, state the chosen plan briefly, and proceed

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
5) "Launch second agent: <TASK>"
6) "Run 2/3/5/10 agents and split work by folders"
7) "Help me split one big goal into tasks for child agents"

You translate these into `$CHATGPT_SEND_BIN` calls internally.

## Startup Flow (Step-by-Step)

When the user says: **"I want to work with the Specialist"**

Step 1: Session
- If there are saved sessions, show them and ask one question:
  - "Resume `last` (recommended), pick another, or `new`?"

Step 2: Project path
- Ask:
  - "Give me the full path to the project folder."

Step 3: Agent mode
- Default behavior:
  - If the user already asked for multi-agent/swarm work (or said to decide autonomously), choose child-agent mode yourself.
  - Otherwise use `single`.
- Ask only if this is still ambiguous and the choice materially changes the workflow.

Step 4: Main browser mode
- In autonomous coordinator mode, choose main browser usage yourself from task needs and current context (Specialist needed vs local-only work).
- Ask only if this choice is genuinely ambiguous and affects the workflow.

Step 5: Specialist iterations (only if main browser mode = `yes`)
- If the user didn't specify N:
  - in autonomous coordinator mode, choose iteration budget yourself from task complexity and expected loop depth
  - otherwise ask one question.

Step 6: Child-agent plan (only if child mode was selected)
- In autonomous coordinator mode:
  - choose child count, shared/separate path strategy, and initial task split yourself from the user's goal/context
  - when one project path was provided, usually start from shared path unless there is a clear reason to separate
  - restate the chosen plan briefly and proceed unless a real blocker exists
- Otherwise ask one-by-one:
  - "How many child agents exactly?"
  - "One shared project path for all children, or separate path per child?"
  - If shared: "Confirm shared path."
  - If separate: ask sequentially "Path for agent #1?", "Path for agent #2?", ...
  - "Do you already have tasks per agent, or should I split the goal for you?"
- If user asks you to split the goal:
  - Ask for one global goal sentence.
  - Ask permission to list top-level folders in the given project path(s).
  - After permission, inspect only top-level folders and suggest task split.
  - Ask confirmation for each child task, one child at a time.
- In autonomous coordinator mode:
  - choose iterations strategy (`shared` vs `per-child`) and budget yourself from task shape
  - choose browser policy per child from task needs (local-only analysis vs Specialist/web dependency)
  - choose browser brief only when a child actually needs Specialist/browser context
- Otherwise ask:
  - "Iterations for children: one value for all or per-child? (shared/per-child)"
  - If shared: "How many iterations budget per child? (3/5/10/20)"
  - If per-child: ask one-by-one "Iterations for agent #1?", "Iterations for agent #2?", ...
  - "Browser policy per child? (`required` / `optional` / `disabled`)"
  - If policies differ: ask one-by-one "Policy for agent #1?", "Policy for agent #2?", ...
  - "For `required` children use default browser brief or custom? (default/custom)"
  - If `custom`: ask one concise brief per required child.

Child task composition rule:
- Each child task must include:
  - original user goal (verbatim short form)
  - child-specific role/scope
  - browser policy for that child
  - browser brief for that child if policy=`required`
- Never replace user goal with a different goal.

Default browser brief (use when user selects `default`):
- "Ты внешний специалист по этой задаче. Я исполнительный агент в локальном проекте. Я присылаю факты, выводы команд и изменения по коду; ты даешь короткие и проверяемые рекомендации. Используй интернет для актуальной информации и документацию по теме. Фокус: факты, проверки, риски, конкретные шаги."

Step 7: Title (only for new session and main browser mode = `yes`)
- Ask:
  - "Short title for this session (what are we working on)?"

Step 8: Open browser (only if main browser mode = `yes`)
- If resuming an existing session:
  - `$CHATGPT_SEND_BIN --use-chat <name-or-index>`
  - `$CHATGPT_SEND_BIN --open-browser`
- If creating a new session:
  - `$CHATGPT_SEND_BIN --open-browser --chatgpt-url https://chatgpt.com/`

Step 9: User writes the intro in the web chat (only if main browser mode = `yes`)
- Say one sentence:
  - "Write one intro message to the Specialist in the browser, then tell me: `ready`."
- Wait for `ready`.

Step 10: Pin chat + set title (only if main browser mode = `yes`)
- After user says `ready`:
  - `$CHATGPT_SEND_BIN --sync-chatgpt-url`
  - `$CHATGPT_SEND_BIN --set-active-title "<title> (<YYYY-MM-DD>)"`

Step 11: Initialize loop (only if main browser mode = `yes`)
- `$CHATGPT_SEND_BIN --loop-init N`
- Run exactly N Specialist back-and-forths.

Step 12: Child launches (if child mode selected)
- Launch child agents according to approved child plan.
- If main browser mode = `no`, keep all progress and final summary in terminal.
- If main browser mode = `yes`, also send final aggregate summary to Specialist.

## Multi-Agent Coordinator Mode

Use this mode when user asks to run several child agents.

Important swarm model (explicit):
- This is a **soft swarm**, not a hard-coded routing/locking system.
- The main agent is the coordinator/"brain" (think: the "queen"/core intelligence of the swarm workflow, not a rigid dispatcher).
- The coordinator is not limited to a fixed number of agents in the skill text:
  - for a small task it may use zero or one child,
  - for a larger task it may use several waves and many children,
  - the number/roles are chosen dynamically per task.
- The coordinator decides dynamically:
  - how many child agents to launch,
  - how to split/re-split work,
  - when to re-ask the same child,
  - when to add another child for verification/arbitration,
  - when to continue talking to Specialist vs when to send work to the swarm,
  - when to stop, summarize, or launch another wave.
- If results conflict, are incomplete, or look risky, the coordinator must run another swarm step:
  - re-ask the same child, or
  - launch an additional verifier/arbitration child, or
  - re-split and launch another wave with updated context.
- Child agents get shared context (goal + peers), may overlap, and must report overlap.
- The coordinator is responsible for checking child results, reconciling differences, and deciding the next move.

Planning rules:
- Keep one question at a time.
- In autonomous coordinator mode, ask no planning questions unless blocked; choose and state defaults briefly.
- Do not hard-code fixed swarm sizes/budgets in the skill text; the coordinator chooses these per task.
- Before launch, restate the chosen plan briefly (and ask for `confirm` only when the user wants confirmation or the plan changes risk materially).

Launch protocol:
- Start each child with `spawn_second_agent`.
- Use `--launcher window` so each child can have its own terminal window.
- Always launch children in parallel mode (no sequential launch mode in UX).
- Always pass `--skip-git-repo-check` for child launches.
- Always pass explicit `--iterations` for each child launch.
- If iterations mode is `per-child`, pass that child's value.
- If iterations mode is `shared`, pass the shared value for all children.
- Map per-child browser policy to flags:
  - `required` -> `--browser-required --open-browser`
  - `optional` -> `--browser-optional` (open-browser optional)
  - `disabled` -> `--browser-disabled --no-open-browser`
- In shared browser mode, keep one shared Chrome profile/cookies and separate child state/chat metadata per child.
- Do not force separate browser windows per child; prefer one visible browser with multiple tabs/chats.
- For policies `required` and `optional`, keep `--init-specialist-chat` enabled so each child gets its own dedicated Specialist chat.
- Dedicated child chat URL must be captured in child log/metadata before child deep work.
- Launch without `--wait`.
- Collect `RUN_ID`, `LOG_FILE`, `LAST_FILE`, `EXIT_FILE`, `PID_FILE` for each child.
- Right after launch, validate start: `PID_FILE` exists and `kill -0 <pid>` succeeds. If not, mark child as `failed` immediately.
- Poll each child by `EXIT_FILE` + process liveness:
  - status `running` allowed only when `kill -0 <pid>` is true.
  - if process is dead and `EXIT_FILE` is missing -> status `failed` (do not report `running`).
  - if `running` but `LOG_FILE` mtime does not change for >=60s -> status `stuck`, include last 20 log lines.
- While polling, also capture final line from `LAST_FILE` when available.
- For each `required` child, include browser brief directly inside child task text so child sends this context to Specialist before deep work.
- Send short progress lines in terminal:
  - `agent-2 running`
  - `agent-2 done: <short child result>`

Aggregation protocol:
- After all children finish, create one summary with:
  - child id
  - project path
  - browser policy
  - status (`ok` / `failed`)
  - browser usage evidence (`CHILD_BROWSER_USED: ...`)
  - final `CHILD_RESULT`
- Always send this summary to the user.
- Send to Specialist only if main browser mode = `yes`.
- If user asked for follow-up iteration, continue from this summary.

Failure handling:
- If child status indicates browser policy failure or logs contain `chatgpt_send failed (cdp status=2)`:
  - mark that child as `failed` (do not treat as partial success)
  - ask user to bring a visible ChatGPT chat tab to front
  - rerun only failed `required` child(ren) with same task and policy

## Iteration Loop

Before each send:
- Read `done/max` via `$CHATGPT_SEND_BIN --loop-status`
- Set `i = done + 1`, `N = max`
- Prefix the message with: `Iteration i/N.`
- On the last iteration, add:
  - "This is the last iteration. Give a final answer and a verification checklist."

After each Specialist reply:
- `$CHATGPT_SEND_BIN --loop-inc`
- Terminal status: remaining iterations.
- If code/files were changed successfully, run the commit helper:
  - `/home/matrix/projects/chatgpt-send/bin/commit_agent --repo "<project_path>" --push`
  - If it prints `нечего коммитить`, continue silently.

After the loop ends:
- `$CHATGPT_SEND_BIN --loop-clear`

## Commands You Run Internally

Never use `xdg-open` and do not depend on other tools like `oracle`.

Open browser:

```bash
$CHATGPT_SEND_BIN --open-browser
```

List / switch sessions:

```bash
$CHATGPT_SEND_BIN --list-chats
$CHATGPT_SEND_BIN --use-chat last
$CHATGPT_SEND_BIN --use-chat 2
```

Send to Specialist and wait for final answer:

```bash
$CHATGPT_SEND_BIN --prompt "TEXT"
```

Launch a second Codex agent (same browser/profile/cookies by default):

```bash
/home/matrix/projects/chatgpt-send/bin/spawn_second_agent --project-path "<project_path>" --task "<task_for_child>" --iterations 3 --launcher window --wait --skip-git-repo-check --browser-required
```

Notes:
- By default child uses shared Specialist browser profile/cookies (`CDP_PORT=9222`) with separate child state/chat metadata.
- Child can still run in isolated mode if explicitly needed: `--isolated-browser`.
- Child may open its own terminal window and continue there.
- In `--wait` mode, use `CHILD_RESULT=...` as the child's final return to the main agent.
- Child prompt requires explicit browser line: `CHILD_BROWSER_USED: <yes|no> ; REASON: ... ; EVIDENCE: ...`.

Launch multiple child agents in parallel (example pattern):

```bash
# child 1
/home/matrix/projects/chatgpt-send/bin/spawn_second_agent --project-path "<path_1>" --task "<task_1>" --iterations 5 --launcher window --skip-git-repo-check --browser-required
# child 2
/home/matrix/projects/chatgpt-send/bin/spawn_second_agent --project-path "<path_2>" --task "<task_2>" --iterations 5 --launcher window --skip-git-repo-check --browser-disabled --no-open-browser
# child 3
/home/matrix/projects/chatgpt-send/bin/spawn_second_agent --project-path "<path_3>" --task "<task_3>" --iterations 5 --launcher window --skip-git-repo-check --browser-optional
```

Then monitor each child by `EXIT_FILE`/`LAST_FILE` from command output and aggregate the final status.

Auto-commit helper (no browser required):

```bash
/home/matrix/projects/chatgpt-send/bin/commit_agent --repo "/abs/project/path" --push
```

Optional trigger mode (commit only when a specific file grows):

```bash
/home/matrix/projects/chatgpt-send/bin/commit_agent --repo "/abs/project/path" --trigger-file "relative/or/absolute/file" --min-growth 10 --push
```

## If Cloudflare Shows Up

- Ask the user to solve "Just a moment..." in the open browser window.
- Retry sending.

## Safety

- Never send secrets (API keys, passwords, tokens, private keys, personal data) to the Specialist.
