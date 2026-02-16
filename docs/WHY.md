# Why: the "Codex <-> Specialist" loop

`chatgpt-send` is a tiny CLI bridge that lets a coding agent (Codex CLI) hand off questions and evidence to a "Specialist" running in ChatGPT Web, then pull the Specialist's reply back into the terminal.

This is not "multi-agent orchestration". It's a simple, practical loop you can actually steer.

## The idea in one sentence

Give your coding agent a teammate that holds long context (and can consult docs), while the agent stays focused on execution in your repo.

## Why it's powerful

- **Role separation.** Codex executes (read code, run commands, edit files). The Specialist thinks (strategy, checklists, sanity checks).
- **Better prompts over time.** Your initial vague idea turns into a structured investigation prompt because each round adds real evidence.
- **Up-to-date guidance.** The Specialist runs inside ChatGPT Web, so you can use whatever features your chat has (browsing, deep research, etc.).
- **Human-in-the-loop.** The browser window is visible the whole time. You can jump in, clarify, correct, or stop the loop at any moment.
- **Bounded iteration.** You can say "do 3 iterations" and it will do exactly 3 back-and-forths, then stop.
- **One thread per task.** You keep a single Specialist chat for a task instead of starting a new chat every time.

## What it feels like (typical flow)

1. Open the Specialist chat in a normal browser window and describe the task in your own words.
2. Codex explores the repo and sends evidence to the Specialist (logs, snippets, diffs, metrics).
3. The Specialist replies with:
   - what is known
   - what to verify next
   - what to do (action plan)
   - risks / gotchas
4. Repeat for N iterations (or stop early).

## Great for

- Debugging a production issue where you need a careful checklist, not a guess.
- Audits (security, performance, reliability) where evidence matters.
- Migrations where you want a plan plus verification steps.
- Any "I don't even know where to start" investigation.

## Reality checks

- This is UI automation (CDP). ChatGPT Web UI changes can break it.
- The Specialist's abilities depend on what your ChatGPT Web session can do.
- Treat `state/` as sensitive (it contains an automation browser profile).

## Share copy (GitHub / X)

**One-liner:**

> `chatgpt-send` is a CLI bridge that lets Codex hand off evidence to a persistent ChatGPT Web "Specialist" and pull replies back into the terminal, in a bounded N-iteration loop you can steer.

**Short pitch:**

> Sometimes a coding agent gets stuck because the prompt is vague or the context is messy.  
> This loop fixes that: Codex executes in the repo, the Specialist holds the long context and turns evidence into the next step.  
> You keep the browser visible, you can intervene at any time, and you can cap it to N iterations.

