# Claude Progress: style menu discoverability plan (2026-11-23)

_Made by a Product + Design team of agents (UX Researcher, Trend Researcher, UX Architect, UI Designer, Product Manager), with a Sprint Prioritizer and a UI finish-gate reviewer as the gate. It passed the gate on round 2: sized, scoped, and a clear first milestone (S1). It sits alongside M2 of [product-plan.md](product-plan.md) and is kept small on purpose._

**The problem in one line:** commit af790f6 shipped a good style picker, but many people cannot find it again. The owner could not find it either. Their picker was already closed (`styleChosen=true`), hide-when-idle was on, and the window was a mini bar.

## 1. Sized

**Who can reach the styles today, unaided (all ASSUMED, from the UX Researcher):**

| Group | Share of users | Can they find styles? | Why |
| --- | --- | --- | --- |
| Normal window | 60-80% | 30-50% try right-click | Nothing on the window says a menu exists |
| Hide-when-idle | 20-40% | 10-20% | No window to click; a Start menu launch shows it for 6 s |
| Mini bar | about 15% | Lower than normal | Tiny right-click target |
| Keyboard or screen reader | small, unknown | 0% | No focus, no taskbar button, no Alt+Tab entry |
| First-run picker | all new installs | 40-60% miss it | It opens while they watch the installer; one chance only |
| Upgraders | all existing users | Often never see it | The installer force-kills the old app; the picker is lost or silently marked "seen" |

**Headline:** about half of users cannot find styles unaided (base case, ASSUMED). Within the main plan's base case of about 1,100 users in 12 months, that is roughly 550 people stuck on a default style.

**Impact:** styles are how people pick "Show only progress" or the mini bar, so they decide how much the window gets in the way. Someone who cannot change style is likely to close the window for good. We have not measured that (ASSUMED).

**Cost:** 7.25 person-days in total. S1, the first fix, is 3.5 days.

## 2. Scoped

| In scope | Out of scope |
| --- | --- |
| Gear button in the header and on the mini bar | Tray icon (deferred, see Decisions) |
| Start menu shortcut "Claude Progress - Choose a style" | Global hotkey |
| First-run fix: `prefsVersion` migration, `pickerSeen`, installer rule, login timing | Jump lists |
| Activation rule for the picker (see Decisions) | Windows toasts that point to styles |
| One-time coach mark under the gear | New styles, or redesigned style previews |
| Picker refinements: footer text, Use state, anchoring, focus return | Changes to the existing "In use" pill, Esc-to-close and "Cancel" label |
| Local counters in prefs, tester task script, upgrade test, screenshot check | Telemetry of any kind; a What's New window |

## 3. Milestones (capacity: about 10-12 working days per 3 weeks)

### S1 (M2, week 4): Fix the owner's case (3.5 person-days)

**Goal:** hide-when-idle, mini bar and upgrade users can all reach the picker without help.

| Deliverable | Days |
| --- | --- |
| Gear button: a real `Button` with `AutomationProperties.Name="Styles and settings"` and the same tooltip. Glyph E713, FontSize 12, full-opacity TextMuted at rest (same as MinBtn), TextMain plus the Track hover layer on hover, 24x24 hit target. Placed left of MinHit with Margin 4,-4,0,-4, so minimize stays in the corner. Shown on the full header **and** the mini bar. It opens the full right-click menu, with "Choose a style..." first. On the 330px mini bar, Title trims first and Count never trims. Picker footer becomes "Change it later: click the gear > Choose a style...". Gear TabIndex comes before MinHit; its hover layer uses CornerRadius 6, like MinHit | 1 |
| Start menu shortcut "Claude Progress - Choose a style", running `-ChooseStyle`. The launcher calls `AllowSetForegroundWindow(ASFW_ANY)`, then signals the named event `Local\ClaudeProgressStyle`. The running copy opens the picker activated and resets the idle grace so the main window shows too. If no copy is running, it starts one and opens the picker. (Uninstall already deletes the whole Start menu folder: 0 days) | 1 |
| Prefs migration with a one-time marker: if `prefsVersion` is missing, an old `styleChosen=true` becomes `pickerSeen=true` with `styleChosen=false`, then write `prefsVersion: 2`. From then on `styleChosen` is set only by Use or double-click, and `pickerSeen` by any close. The Loaded first-run check (ClaudeProgress.ps1, around line 1794) tests `pickerSeen` instead of `styleChosen` | 0.5 |
| Installer rule: if `prefsVersion` is below 2 or missing, or `pickerSeen` is false, the last step of install.ps1 starts the app with `Start-Process ... -ChooseStyle` **instead of** the usual step-6 launch (`Start-ScheduledTask`), so only one copy starts. `Show-StylePicker` does nothing if `$script:pick` is already set, so the startup check and `-ChooseStyle` can never open two pickers. The `-Outside` path stays non-activating | 0.25 |
| Hide-when-idle: don't hide while `$script:pick` is set | 0.25 |
| Testing: owner repro, upgrade test on a clean VM, typing-while-hook-starts test, keyboard and Narrator run through the Start menu | 0.5 |

**Definition of done:**
- [ ] Owner's case: with hide-when-idle on, the mini bar style and `styleChosen=true` from af790f6, upgrading shows the picker once, from the last step of install.ps1. Later, "Choose a style" from Start opens it while the window is hidden.
- [ ] Migration runs once: after the first start `prefsVersion` is 2. Choose a style, restart twice, and `styleChosen` is still true. The picker does not reopen.
- [ ] On a fresh install, exactly one app copy runs and exactly one picker opens.
- [ ] Running install.ps1 again on a migrated machine with `pickerSeen=true` does not open the picker.
- [ ] From Start, with another app focused, the picker comes to the front with keyboard focus. The `-Outside` path never takes focus.
- [ ] Typing Enter in Claude while the hook starts the app never chooses a style.
- [ ] With hide-when-idle on, open the picker and wait past the idle grace: the window and the picker stay. After closing, the window hides after the normal grace.
- [ ] The gear is visible on the mini bar without hovering. Clicking it never starts DragMove or the double-click minimize.
- [ ] At 330px and Size150, the mini bar shows "12 chats · 100% · ~59m left" in full next to the gear and MinHit.
- [ ] Inspect or Accessibility Insights shows a button named "Styles and settings".
- [ ] Keyboard only: Win, type "choose a style", Enter. The picker opens with focus, and Narrator reads the style names.
- [ ] The picker footer says "Change it later: click the gear > Choose a style...".
- [ ] The owner confirms they can find the menu without hints.

**Risk retired:** the owner's "where is my menu", and the fully blocked keyboard and hidden-window users.

### S2: Teach it and measure it (2.5 person-days)

**Goal:** new and upgrading users notice the gear once, and we can prove that people find it.

| Deliverable | Days |
| --- | --- |
| Coach mark under the gear: "Styles and settings are here", second line "Change how much this window shows". Shown on the full header and the mini bar (where the gear is easiest to miss). Non-activating, max width 220px, with an arrow pointing at the gear; it flips above the gear when there is no room below. It appears 800 ms after the window is first visible and is held while the window is hidden. Pulse: gear opacity 0.55 to 1.0, 3 cycles of 600 ms, skipped when `SystemParameters.ClientAreaAnimation` is false. Dismissed by click, close, opening the right-click menu, or 10 s visible (the timer pauses while the pointer hovers). Shown once in total, unless it was killed before 3 s; saves `hintShown` | 1 |
| Local counters in prefs: how the picker was opened (gear, menu, Start menu, installer, first run), how it closed (Use, double-click, Cancel, Esc), and seconds until the first style change. "Killed" means opened with no close record | 0.5 |
| Screenshot check: all 4 styles x 3 themes, at 100% and 150%, with the gear at rest, on hover, and with the coach mark showing | 0.5 |
| Tester run: 5 testers, the task script in Metrics, plus the upgrade test | 0.5 |

**Definition of done:**
- [ ] On a fresh install and on an upgrade, the coach mark shows exactly once. Killing the app within 3 s makes it show once more, never again after that.
- [ ] The coach mark never shows while the window is hidden, and never takes focus.
- [ ] With the gear in the bottom screen edge, the coach mark flips above it.
- [ ] With animations turned off in Windows, the gear does not pulse.
- [ ] Hovering over the coach mark at 9 s keeps it open until the pointer leaves.
- [ ] The counters appear in prefs after one open and close; a killed picker shows as opened with no close record.
- [ ] The screenshot set is complete, with no clipped text and the gear legible in every theme.
- [ ] The tester run meets the pass bar in Metrics.

**Risk retired:** the one easy-to-miss first-run chance, and not knowing whether the fix works.

### S3: Picker polish (1.25 person-days)

| Deliverable | Days |
| --- | --- |
| Use is disabled while the "In use" style is selected | 0.25 |
| Anchor the picker beside the overlay, on the side with room, never covering it; CenterScreen as the fallback | 0.5 |
| Esc (existing IsCancel) or Cancel closes the picker and focus goes back to the window that had it before | 0.25 |
| Login start (Startup shortcut or scheduled task): don't open the picker over the desktop; wait until the main window is first visible | 0.25 |

**Definition of done (one line per refinement):**
- [ ] With the "In use" style selected, Use is disabled; selecting any other style enables it.
- [ ] With the overlay at the right screen edge, the picker opens on its left; at the left edge, on its right. It never overlaps the overlay.
- [ ] With no room on either side, the picker opens at screen centre.
- [ ] Open from Start while typing in Notepad, press Esc: Notepad has focus again.
- [ ] Sign in with hide-when-idle on and `pickerSeen=false`: no picker appears until the main window first shows.

### Later (not scheduled): Tray icon (1-1.5 days)

Moves into a milestone only if the S2 tester run fails the hide-when-idle condition (fewer than 4 of 5).

### Where the days come from

- **M2 with S1.** M2 drops the toast (1.5 days) and is 8-9.5 days; with S1 it is 11.5-13. S1 runs first, in week 4, because every upgrade on the old logic can lose the picker for good. **If M2 reaches day 12 with work left, cut in this order:**
  1. The update-rate half of the cheaper default mode (up to 1 day). The CPU test runs on the frame-rate change alone. If it fails, the update-rate change moves into M4's bug-fix buffer.
  2. Release signing (0.5 day, only if approved) moves to M3's `v1.1` Release. M3's launch support drops from 2 to 1.5 days.
  The ETA work and the ETA exit criteria are never cut for this plan.
- **The toast goes to M4, first in line.** The pivot plan relies on toasts, so it ships before anything else in M4.
- **If the Node bundle is dropped** (decided in M1): its 3 freed days go to S2 in M3, before the launch posts, so launch users get the coach mark. M4 is then the toast (1.5), S3 (1.25) and the base 8 days with the bug-fix buffer at 3 days: 10.75 days.
- **If the Node bundle ships:** M3 is full. M4 is the toast (1.5), then S2 (2.5), with the bug-fix buffer at 3 days: 12 days. S3 moves past week 12.

## 4. Why this order

1. **Entry points before teaching.** A coach mark pointing at nothing is useless. The gear and Start menu entry have to exist first.
2. **The hidden-window path first.** The Start menu shortcut is the only entry point that works while the window is hidden. That is the owner's case and the most blocked group.
3. **Fix the prefs before anyone else upgrades.** Every upgrade on the old logic can mark the picker "seen" for good. The `prefsVersion` marker makes the fix run once and keeps real choices.
4. **Counters ship with the tester run.** Only S2 reads them, so they wait for S2 and keep S1 small enough for M2.
5. **Teach before launch when we can.** If the Node bundle is dropped, S2 lands before the posts, when the most new users arrive.
6. **Polish after the fix.** S3 helps, but none of it helps a user who cannot open the picker.
7. **Tray last, if at all.** It is the most expensive option, and Windows 11 hides it anyway.

## 5. Top 5 risks

| Risk | Mitigation |
| --- | --- |
| The gear crowds the mini bar or makes clicks start a drag or minimize | 24x24 hit target left of MinHit; Title trims first, Count never; 330px check; drag, click and double-click tests in S1 |
| The picker steals focus and a stray Enter chooses a style | Activate only on user-started paths (Decisions #1); the `-Outside` path stays non-activating; typing test in S1 |
| Migration reruns and wipes real choices, or the picker reopens on every install | `prefsVersion: 2` one-time marker; installer rule checks `prefsVersion` and `pickerSeen`; restart and reinstall tests in S1 |
| `-ChooseStyle` races with startup, or Windows blocks the foreground change | `AllowSetForegroundWindow(ASFW_ANY)` before the signal; reuse the single-instance check; queue the request until the window is ready; test cold and warm start |
| S1 pushes M2 past 12 days and delays the ETA work | Toast moved to M4; named cut list at day 12; counters moved to S2; S2 and S3 placed by the Node decision |

## 6. Metrics (no telemetry)

| Type | Metric | Source | Target |
| --- | --- | --- | --- |
| Leading | Owner finds the menu unaided | Owner check after S1 | Yes |
| Leading | Testers switch to "Show only progress" within 2 min, no hints | Tester task script, 3 conditions: normal, hide-when-idle, mini bar | 4 of 5 or better in **every** condition |
| Leading | Keyboard and Narrator run completes | Same task, keyboard only | Passes |
| Leading | Upgrade test from af790f6 shows the picker once | Clean VM | Passes |
| Leading | Median seconds until the first style change | Prefs counters, pasted back by the 5 testers | Under 60 s |
| Leading | Share of picker opens from the gear or Start menu (vs right-click) | Prefs counters, pasted back by the 5 testers | Over 50% |
| Leading | First-run picker closed with Use or double-click (vs Cancel, Esc or killed) | Prefs counters; "killed" = opened with no close record | Over 50% |
| Lagging | "Where is the menu / how do I change style" issues after S1 | GitHub issues and Discussions | 0 by week 12 |

## 7. Decisions

1. **Activate the picker or not?** The Trend Researcher wants first-run activated; the code review says never steal focus. **Decision:** activate only when the person started it: the last step of install.ps1, the Start menu "Choose a style", or the gear and menu item. Stay non-activating when the hook, scheduled task, login or `-Outside` path starts it. Keyboard users who miss the non-activating first run use the Start menu entry, which does take focus.
2. **Gear or brush, and visible on the mini bar?** **Decision:** gear (E713) that opens the whole menu, with "Choose a style..." first. One button then reveals every setting, including hide-when-idle, at the same cost. Styles stay one click deeper, and the coach mark and footer point to the gear. **Always visible on the mini bar**, at full-opacity TextMuted like MinBtn: a button that appears only on hover cannot be discovered, and the mini bar is the owner's case. On a tight mini bar the Title trims, never the gear or Count.
3. **Tray now or later?** **Decision:** later. It lands in the overflow on Windows 11, adds about 15-20 MB (which works against Saver mode), needs an .ico, and leaves ghost icons after a crash. The Start menu entry covers the hidden-window case for 1 day. **Revisit if** the S2 hide-when-idle condition scores under 4 of 5.
