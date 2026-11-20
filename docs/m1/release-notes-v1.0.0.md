# Claude Progress v1.0.0

A live progress window for Claude on Windows 10 and 11. It shows what Claude is doing right now, where the time went, and roughly how long is left, so you can walk away from a long Claude Code job and come back at the right time.

Free and open source (MIT). Everything stays on your computer.

## Highlights

- **Step-by-step progress.** Reading, editing, running a command, browsing, with the actual file name or command underneath. A timeline bar shows the whole job as coloured segments, and an activity list marks each step with ✓ or ✗ and how long it took.
- **Learned time estimates.** "Time left" comes from how long similar steps took before on your machine. When a step runs long, the bar eases back instead of sticking at 99%, and a note says why.
- **Team view for helper agents.** When Claude sends out subagents, the card shows who is doing what as a small pipeline, with 16 roles (design, review, security, test, plan, research and more), each with its current step and how long it has worked. Background helpers keep the job open until they finish.
- **Regular Claude chats too.** Chats in the Claude desktop app get a card with the chat name, current step and a learned estimate.
- **Themes and sizes.** Normal, DADA and REN themes; Small to Extra large; Saver, Neutral and Full power performance modes; a slim minimized bar.

## New in this release

- **The installer asks before changing anything.** It shows a preview of every change it will make (hooks added to `settings.json`, the scheduled task, shortcuts, the app folder) and waits for a Yes. Saying No leaves your system exactly as it was.
- **Checksums.** Each Release ships a ZIP and a `.sha256` file so you can confirm the download is the one published here.
- **Local job log for better estimates.** The hook now records each job's start, end, project folder and prompt length in `%USERPROFILE%\.claude-progress\jobs.jsonl` (the project folder's name and the prompt's length only, never the prompt itself). It never leaves your machine; it's there so future versions can give more accurate time-left ranges.

## Verify your download

In PowerShell, in the folder with the two files:

```powershell
(Get-FileHash .\claude-progress-1.0.0.zip -Algorithm SHA256).Hash -eq (Get-Content .\claude-progress-1.0.0.zip.sha256).Split(' ')[0]
```

It should print **True**. If it prints False, don't run it, and please open an issue.

> **Not yet code-signed.** A signing application is in progress. Until then, Windows SmartScreen may say "Windows protected your PC". If your hash matched, click **More info → Run anyway**.

## Install

1. Download and verify the ZIP (above), then unzip it (right-click → Extract All).
2. Double-click **`Install.cmd`**.
3. Read the preview of every change, then type **Y** and press **Enter** (anything else cancels and changes nothing).
4. Restart Claude Code (or open a new session). The window appears whenever Claude works.

Requires Windows 10 or 11, Windows PowerShell 5.1 (built in) and Node.js.

**What the installer changes:** copies the app to `%USERPROFILE%\.claude-progress\app`; adds eight hooks to `~/.claude/settings.json` after saving a backup as `settings.json.before-claude-progress.bak` (your other settings and hooks are kept); adds Start menu shortcuts; starts the app with Windows; adds a **Claude Progress** task in Task Scheduler that reopens the window when a Claude session starts.

## Uninstall

Start menu → **Claude Progress** → **Uninstall Claude Progress**, or run `Uninstall.cmd`. It closes the window, removes only its own hooks, removes the scheduled task, and deletes the app and shortcuts. Your timing history and job log in `%USERPROFILE%\.claude-progress` stay; delete that folder if you want them gone.

## Privacy

Nothing leaves your machine. There is no telemetry, no account and no network calls. Step timings, the job log and settings are plain files in `%USERPROFILE%\.claude-progress` that you can read or delete at any time.

## Feedback

Bugs and install problems: please open an issue with your Windows version and what you saw. Questions and ideas: Discussions.
