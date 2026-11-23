# Claude Progress: 12-week plan (2026-11-21)

_Made by a product team of agents (Trend Researcher, UX Researcher, Product Manager, Sprint Prioritizer as gate). It passed the gate on round 3: sized, scoped, and a clear first milestone._

## 1. Sized

**Opportunity funnel (low / base / high):**

| Step | Low | Base | High | Basis |
| --- | --- | --- | --- | --- |
| Active Claude Code users | 1.5M | 3M | 5M | ASSUMED, anchored to 21.66M npm downloads/week (SOURCED; inflated by CI and updates) |
| x on native Windows | 20% | 25% | 35% | ASSUMED |
| x running long or multi-agent jobs | 20% | 30% | 40% | ASSUMED |
| **= SAM** | **60k** | **225k** | **700k** | |
| x indie reach in 12 months | 0.1% | 0.5% | 2% | ASSUMED |
| **= SOM (users)** | **~60** | **~1,100** | **~14,000** | |
| x stars per user (one rate: 10-33%) | ~6-20 | ~110-370 | ~1,400-4,600 | ASSUMED |

Desktop-chat users on Windows are not counted, which is upside.

**Week-12 star threshold (ASSUMED):** we assume about 35% of first-year stars arrive in the launch quarter, because stars cluster around launch posts. Applied to the base case of 110-370 stars, that gives about 40-130 stars by week 12. **40 stars** is the base-case trajectory. Fewer than 40 at week 12 means we are below the base-case trajectory.

**The bet:** Solo developers will install a trusted, native Windows window that tells them **how long is left** on a long Claude Code job, so they can walk away and come back at the right time. No alternative has time-left estimates. ccusage, Usage-Monitor and the Electron and web monitors all track cost or activity.

**Why now:**
- Users are asking for this in Claude Code issues today:
  - subagent visibility and liveness: #24580, #39008, #48246, #67485, #91093, #46076, #61405 (a 12-hour hang)
  - ETA: #31527
  - long-operation progress: #12770, #67706
- Anthropic may ship built-in progress (30-50% in 12 months, ASSUMED). Our window to earn a reputation and get onto the awesome-claude-code lists is the next one or two quarters.

**Kill/pivot triggers** (checked weekly against the Claude Code changelog, plus a formal review in week 12):
- **Anthropic ships native progress with ETA.** Pivot within 2 weeks to what it lacks: Windows toasts for walk-away jobs, and a cross-session view of every running job. If it covers those too, move to maintenance mode.
- **Weak launch.** If week 12 has fewer than 40 stars (below the base-case trajectory) **and** fewer than 5 distinct outside issue or Discussion authors, stop feature work and move to maintenance mode. (This threshold is deliberately strict: a result between the low and base cases still triggers it, so the week-12 memo should say whether that is still the right call.)

## 2. Scoped

**Target segment first: A, the solo developer running long Claude Code jobs.**
- **Demand:** the clearest asks are about this segment's pain: ETA (#31527) and long-operation progress (#12770, #67706).
- **Reliability:** it is served by hooks, our most reliable data path, rather than fragile UI Automation.
- **Fit:** time-left is the differentiator, and it matters most for long jobs.
- **Size:** we have not measured how large this segment is relative to the others (ASSUMED).

Segment B (multi-agent) gets the existing Team view for free. Segment C (desktop chat) is blocked by Node and by UI Automation fragility, so we keep it working and make failures visible, but do not grow it.

**Why bundle Node for segment A:** people who install Claude Code with the native installer may not have Node (ASSUMED). In M1 we ask each tester "did you already have Node?" to check this before M3 builds the bundle.

**Node decision rule:** if 4 or more of the 5 testers already had Node, we drop the Node bundle from M3 and use its 3 days for style-menu S2 in M3, before the launch posts (so new users can find the styles at launch). See [style-menu-plan.md](style-menu-plan.md).

| In scope (12 weeks) | Out of scope |
| --- | --- |
| Versioned Releases with SHA256; signing if approved | macOS / Linux, WSL / SSH |
| Installer that shows its changes and asks before applying them; manual update check | Remote or phone notifications |
| Job ETA bucketed by project and prompt length, shown as a range. Targets: median error at least 30% below today, range contains the actual time on 70% or more of jobs | Telemetry of any kind |
| Default mode: mean CPU at or under 5% | Cost or token tracking |
| Windows toast when a long job finishes | Per-helper ETA, better role guessing |
| Install path that bundles Node (subject to the decision rule) | Prompt-type classification for ETA |
| Visible chat-watch health state; UI Automation fixture tests | New themes, UI translation |
| Issue templates and labels; launch posts; awesome-list PRs; ETA-accuracy Discussion | Paid tier |

## 3. Milestones (capacity: about 10-12 working days per 3 weeks)

### M1 (weeks 1-3): Trustworthy install, plus recording jobs (9.5-11 person-days)

**Deliverables:**

| Deliverable | Days |
| --- | --- |
| `v1.0.0` tag and a Release with a ZIP and a `.sha256` file | 2 |
| Installer preview that lists every change and waits for a Yes | 3 |
| Local hook log: job start/end, project (cwd) and prompt length, kept on the machine | 1.5 |
| Install timing log: installer start, and first card shown | 1 |
| Signing application to SignPath OSS or Azure Trusted Signing, submitted by day 3 | 0.5 |
| Testing on clean Windows 10 and Windows 11 VMs, and tester support | 1.5-3 |
| `.gitignore` entry for `*.mp4` | 0 |

**Recruiting testers by day 5:** post a "5 Windows testers wanted" call in a GitHub Discussion, in r/ClaudeAI and r/ClaudeCode, and in the Claude Developers Discord. If those come up short, fill the gap with personal contacts.

**Definition of done:**
- [ ] The Release page has a ZIP and a `.sha256` file, and the hash matches.
- [ ] On both clean VMs, install shows the preview and reaches a live card. Users never set the execution policy by hand.
- [ ] Declining the preview changes nothing: `settings.json` is byte-identical and no task is created.
- [ ] Uninstall leaves `settings.json` JSON-equal to the pre-install backup plus any edits the user made since, with none of our hook entries left, and removes the task.
- [ ] The hook log records the start, end, project and prompt length of every job.
- [ ] At least 25 jobs are logged by the end of week 3. If there are fewer, M2's backtest adds opt-in logs donated by testers.
- [ ] No mp4 appears in `git status`.

**The one metric:** at least 4 of 5 outside testers reach a live card within 5 minutes. Each tester pastes the two timestamps from their local log (installer start, first card) back to us. Nothing is self-reported from memory.

**Risk retired:** install friction and trust (blocker #1).

### M2 (weeks 4-6): An estimate worth trusting (8-9.5 person-days; 11.5-13 with style-menu S1, see the day-12 cut list in [style-menu-plan.md](style-menu-plan.md))

- **Goal:** make the core promise true for segment A.
- **Deliverables and effort:**

  | Deliverable | Days |
  | --- | --- |
  | ETA buckets by project and prompt length, shown as a range | 3-4 |
  | Replay harness that backtests ETAs on the logged jobs | 2.5 |
  | CPU baseline measured before any change | 0.5 |
  | Cheaper default mode: lower default frame rate and update rate | 1.5-2 |
  | Sign the release if signing is approved | 0.5 |

- **Exit criteria:**
  - On at least 50 logged jobs (the maintainer's plus any donated by testers), median absolute ETA error is at least 30% below the single-bucket baseline.
  - The range contains the actual time on at least 70% of jobs.
  - Default-mode CPU passes the CPU test defined below.
- **CPU test:**
  - **Setup:** run a 10-minute replayed job on the reference machine, an AMD Ryzen 9 8940HX with 32 logical cores, on Windows 11.
  - **Sampling:** log `\Process(*)\% Processor Time` and `\Process(*)\ID Process` every second with `typeperf` to a CSV. The sampler is `typeperf.exe`, so it cannot match the processes being measured.
  - **Attribution:** `typeperf` does not record command lines or parent PIDs, so save a `Get-CimInstance Win32_Process` snapshot (ProcessId, ParentProcessId, CommandLine) every second during the run. The replay must actually start the `hook.js` node processes. Those processes are short-lived and 1-second sampling can miss them, so their share is best-effort.
  - **What counts:** afterwards, keep only the window's PID, its child processes (such as chat-watch), and the `node` processes running `hook.js` during the replay, which we identify by their command line. Add those up for each sample.
  - **Pass:** the per-process % figures are per core, so the summed mean must be 160% or less. That is 5% of 32 logical cores, about 1.6 cores.
  - **Baseline:** record a before-change baseline (today's Neutral mode) on the same machine.
- **Risk retired:** the core promise does not hold (blocker #4) and the CPU cost (#6).

### M3 (weeks 7-9): No-Node install, visible chat health, then launch (12 person-days)

- **Goal:** remove the last install blocker and stop silent breakage, then get the product seen and support new users.
- **Deliverables and effort:**

  | Deliverable | Days |
  | --- | --- |
  | `v1.1` with bundled portable Node (dropped under the decision rule) | 3 |
  | Chat-watch health state ("chat tracking unavailable" shown in the window), **before** the posts | 2 |
  | Issue templates and labels (install, chat-watch, ETA, bug, idea), **before** the posts | 1 |
  | Manual "Check for updates" menu item | 1.5 |
  | README trust section ("What it changes / what it never does") | 0.5 |
  | Show HN and r/ClaudeAI posts, plus awesome-list PRs | 1.5 |
  | Pinned "How accurate was the ETA?" Discussion | 0.5 |
  | Launch-week user support (weeks 8-9) | 2 |

- **Exit criteria (outputs only):**
  - Install passes on a clean VM with no Node (if the bundle ships).
  - The health state appears when the Claude window is missing or not recognised.
  - Issue templates and labels are live before the first post.
  - Both launch posts are live.
  - At least 2 awesome-list PRs are open.
  - The Discussion is pinned.
- **Risk retired:** Node dependency (blocker #2) if the bundle ships; if the decision rule drops it, blocker #2 stays open for segment C. Also silent chat breakage at launch, and having no distribution.

### M4 (weeks 10-12): Harden and decide (9.5-10.5 person-days including the toast; see the style-menu note below)

- **Goal:** keep launch users and make the kill/pivot decision.
- **Deliverables and effort:**

  | Deliverable | Days |
  | --- | --- |
  | Toast for jobs over 2 minutes (moved from M2; goes first, because the pivot plan relies on toasts) | 1.5 |
  | UI Automation fixture tests, including a non-English fixture | 3 |
  | Bug-fix buffer for launch issues | 3-4 |
  | `v1.2` Release | 1 |
  | Week-12 review memo | 1 |

- **Style-menu note:** M4's spare days cannot hold the toast plus style-menu S2 unless the Node bundle is dropped. If it is dropped, S2 uses the freed 3 days in M3 before the posts, and S3 (1.25 days) follows the toast in M4. If it ships, S2 (2.5 days) comes right after the toast, and the bug-fix buffer stays at 3 days. See [style-menu-plan.md](style-menu-plan.md).
- **Exit criteria:** the toast fires in a functional test, fixture tests run in CI, `v1.2` is published, and the week-12 review below is complete with a written decision.
- **Week-12 review targets:**

  | Measure | Target |
  | --- | --- |
  | Stars | 40 or more (the base-case trajectory, ASSUMED); fewer than 40 counts toward the weak-launch trigger |
  | Distinct outside issue/Discussion authors | 5 or more |
  | Awesome-list PRs accepted | 1 or more |
  | Install + chat-watch share of issues (only if there are 8 or more issues) | Under 25% |
  | Median time-to-close | 7 days or less |

- **Risk retired:** UI Automation regressions (blocker #3) and maintainer overload.

## 4. Why this order

1. **Trust before reach.** Launching an unsigned `.cmd` that edits `settings.json` burns first impressions we cannot get back.
2. **Logging before estimating.** M1's hook log, plus any logs testers donate, is what produces the 50 jobs M2 needs to backtest against.
3. **Accuracy before launch.** Time-left is the only differentiator, and launch posts will be judged on it.
4. **Releases come first because everything depends on them.** The update check, download counts and the bundled-Node ZIP all need M1's Release pipeline.
5. **Health state and issue labels before the posts.** New users must never meet silent breakage, and launch-week issues have to be labelled for the issue-share metric to be measurable.
6. **Fixture tests after launch.** Real issues show which UI variants matter.

## 5. Top 5 risks

| Risk | Mitigation |
| --- | --- |
| Anthropic ships built-in progress or ETA | Weekly changelog check; differentiate on toasts and the cross-session view; pivot trigger above |
| Signing approval is slow or costly | Apply on day 3; checksums plus a transparent installer preview as the fallback; signing is not on the critical path |
| Bucketed ETA is still inaccurate with few logged jobs | Logs donated by testers; show a range; fall back to "learning" honestly; backtest before launch |
| Launch gets little attention | Several channels, awesome-list PRs, demo GIF; weak-launch trigger leads to maintenance mode |
| Solo maintainer burnout | Each milestone sized to 12 days or less; launch-support days in M3; bug-fix buffer in M4; out-of-scope list published in the README |

## 6. Metrics (no telemetry)

| Type | Metric | Source | Target |
| --- | --- | --- | --- |
| Leading | Testers reaching first card within 5 min | Pasted log timestamps | 4 of 5 or better (M1) |
| Leading | ETA median error vs baseline; range hit rate | Replay harness | -30% or better; 70% or better (M2) |
| Leading | Mean CPU in default mode | typeperf test on the reference machine | 5% or less of 32 logical cores, about 1.6 cores (M2) |
| Leading | Release downloads per version | GitHub Releases API | 100 or more total by week 12 |
| Leading | Stars per week in launch weeks (weeks 8-9) | GitHub | 10 or more per week |
| Lagging | Total stars at week 12 | GitHub | 40 or more (ASSUMED trajectory; also the kill threshold) |
| Lagging | Distinct outside authors | GitHub | 5 or more |
| Lagging | Install + chat-watch share of issues (once there are 8 or more issues) | Labels | Under 25% |
| Lagging | Median issue time-to-close | GitHub | 7 days or less |
| Lagging | "ETA was within range" votes | Pinned Discussion | 60% or more |
| Lagging | Awesome-list inclusions | Accepted PRs | 1 or more |
