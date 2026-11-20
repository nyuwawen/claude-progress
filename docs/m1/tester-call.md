# 5 Windows testers wanted

Two versions below. Fill in `<RELEASE_URL>` and `<DISCUSSION_URL>` before posting. The ZIP file name is a placeholder until the Release exists.

---

## (a) GitHub Discussion

**Title:** 5 Windows testers wanted: try the v1.0.0 installer (about 10 minutes)

Hi all,

I'm looking for **5 people on Windows 10 or 11 who already use Claude Code** to try the first proper release of Claude Progress and tell me where the install trips them up.

Claude Progress is a small, free (MIT) window that shows what Claude is doing right now, where the time went, and roughly how long is left. It's built for long Claude Code jobs, so you can walk away and come back at the right time.

### What I'd ask you to do

1. Note the time you start, then download `claude-progress-1.0.0.zip` and `claude-progress-1.0.0.zip.sha256` from the Release page: <RELEASE_URL>
2. Check the hash in PowerShell, in the folder you downloaded to:
   ```powershell
   (Get-FileHash .\claude-progress-1.0.0.zip -Algorithm SHA256).Hash -eq (Get-Content .\claude-progress-1.0.0.zip.sha256).Split(' ')[0]
   ```
   It should print **True**. If it prints False, stop and tell me.
3. Unzip it (right-click → Extract All) and double-click **`Install.cmd`** in the extracted folder.
4. Read the preview. The installer lists every change it is about to make and waits. Nothing is changed until you answer.
5. Type **Y** and press **Enter** (anything else cancels and changes nothing).
6. Close Claude Code and start a new session (hooks load only when a session starts), then run any small job. A progress card should appear.

### What to send back

Reply here (or open an issue if you'd rather) with:

- **The time you started downloading** (roughly is fine), and **the two timestamps** from `%USERPROFILE%\.claude-progress\install-timing.json`: `installerStartedAt` and `firstCardAt`. They are Unix times in milliseconds; `firstCardAt` minus `installerStartedAt` is your install-to-first-card time. You can open it with:
  ```powershell
  Get-Content "$env:USERPROFILE\.claude-progress\install-timing.json"
  ```
  It only holds those times. No file names, prompts or anything personal.
- **Did you already have Node.js installed** before you started? (Yes / No / had to install it)
- **Windows 10 or 11.**
- **Anything confusing**, slow or worrying, however small. "I didn't know what this screen meant" is exactly the kind of thing I need.

### Honest notes before you start

- **It's unsigned for now.** I've applied for free code signing, but it isn't in place yet. Windows SmartScreen may show "Windows protected your PC". Click **More info**, then **Run anyway**, only if the hash in step 2 matched. If you'd rather not run unsigned software, that's completely reasonable; please skip this one.
- **It needs Node.js** for the Claude Code hook. If you don't have it, that's useful to know, so please tell me either way.
- **It edits `~/.claude/settings.json`** to add eight Claude Code hooks. It saves a backup first as `settings.json.before-claude-progress.bak` and keeps your other settings and hooks as they are.
- **It adds a "Claude Progress" task in Task Scheduler**, so the window can reopen when a Claude session starts, and it starts with Windows.
- **Everything stays on your machine.** No telemetry. The only data I'll ever see is what you choose to paste back.

### How to uninstall

Start menu → **Claude Progress** → **Uninstall Claude Progress** (or run `Uninstall.cmd` from the ZIP). It closes the window, removes only its own hooks, removes the scheduled task, and deletes the app and shortcuts. Your timing history in `%USERPROFILE%\.claude-progress` stays; delete that folder if you want it gone too.

Thanks. Even a "it just worked" reply with the two timestamps helps a lot.

---

## (b) Reddit / Discord (r/ClaudeAI, r/ClaudeCode, Claude Developers Discord)

**Title:** Looking for 5 Windows testers for a free progress window for Claude Code (MIT)

I made a small Windows app that shows what Claude Code is doing, where the time went, and roughly how long is left on a job. Free, MIT, everything stays local.

Looking for **5 people on Windows 10/11 who use Claude Code** to try the v1.0.0 installer (about 10 min):

1. Download the ZIP + `.sha256` from the Release, check the hash with `Get-FileHash`
2. Unzip, run `Install.cmd`, read the preview of changes, type Y and press Enter
3. Restart Claude Code, run any job and see if a card shows up

Then send back: roughly when you started downloading, the two timestamps (`installerStartedAt`, `firstCardAt`) from `%USERPROFILE%\.claude-progress\install-timing.json`, whether you already had Node.js, and anything confusing.

Upfront: it's **unsigned** for now (signing applied for, SmartScreen may warn), it **edits `~/.claude/settings.json`** (backup saved first) and adds a **Task Scheduler** entry. Uninstall from the Start menu removes the hooks, task and app.

Details and replies: <DISCUSSION_URL>
