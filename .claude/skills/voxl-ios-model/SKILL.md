---
name: voxl-ios-model
description: Model-check the voxl iPhone/iPad app (TLA+, ios/model) against Dan's four promises — sound plays only where he is, a screen always comes back by itself, no key or button stays held on the Mac, the key bar's ⌘⌥⌃⇧ hit the next key only. Use before and after any change to ios/Voxl/ViewerController.swift, Pointer.swift, KeyBar.swift, Page.swift, App.swift or Machines.swift, or to the voxl paths they lean on (web/src/client/keyboard.ts, pointer.ts, main.ts, audio.ts, web/src/worker.ts, src/server.rs, src/mac/input.rs), when ios/model/check.sh reports DRIFT, and whenever someone asks why the phone app plays no sound with the silent switch on, keeps a cover over the picture, says a screen isn't answering when it is, switched screens by itself, left a key, ⌘ or the mouse button held on the Mac, or put ⌘ on the wrong key.
---

# voxl iOS app model

Two TLA+ models of the iPhone/iPad app in `ios/Voxl` and the parts of voxl it drives:

- `ios/model/PhoneScreen.tla`: the connect attempt (a web view per try, the cover and its button, the 2, 3, 7,
  10 and 30 s timers, the 1 s tick), the scene (in front, behind, background, the page closed after 30 s,
  suspended), what the injected `Page.watch` tells the app (hello, status, picture once per page), voxl's page
  (its worker socket, AudioContext, `navigator.audioSession`) and each screen's voxl (the hello's size, its scale
  requests: the app's `cs,0.8` from a screen's Sharp URL, another viewer asking for Full). Promises 1 and 2.
- `ios/model/PhoneKeys.tla`: Dan's letters, clicks, held drags (fingers on the pad or the picture, an iPad
  trackpad; up to one of each at once, sharing Pointer's one `dragging` flag), the Trackpad/Direct switch and the
  key bar's ⌘ and Esc, through `Page.input`, voxl's `keyboard.ts` and `pointer.ts`, the worker's socket and each
  screen's voxl injector, with the app leaving, switching, reloading, losing its socket and reconnecting.
  Promises 3 and 4.

TLA+ with TLC, because each promise is about the order of events across the app's main thread, its timers,
WebKit, the page, the worker's socket and voxl, which tests on the phone don't reach.

## The promises (Dan's words)

| Rule in the spec | Promise | Kind |
|---|---|---|
| `QuietAway` (PhoneScreen) | 1 "Sound plays only where I am": the page is heard only while the app is in front and Dan touched or typed in it within 5 minutes. | invariant, once settled |
| `PlaysWhereIAm` (PhoneScreen) | 1, "... and while that holds, sound actually plays": the view isn't suspended and the page's `navigator.audioSession.type` is `playback`, so the silent switch can't mute it. | invariant, once settled |
| `ComesBack` (PhoneScreen) | 2 "A screen always comes back by itself": once the world stops changing with the screen's voxl answering and the app in front, the picture ends up playing with no cover, with no help from Dan. | liveness, under weak fairness of voxl's, the page's and the app's own steps |
| `NeverSwitchesByItself` (PhoneScreen) | 2, "... and never switches screens on its own": the cover's button switches only when it says so. | invariant |
| `CoverTellsTruth` (PhoneScreen) | 2, "... the cover's text and button match the real state". Not during the app's designed 2 s wait on a Full hello (`tooWideLater`). | invariant, once settled, app in front |
| `NothingStuck` (PhoneKeys) | 3 "No key or button stays held": once settled, a screen's Mac holds a key, modifier or button only while the app is in front on that screen, connected, and Dan still holds the key or finger it is for. | invariant, once settled |
| `NoExtraModifier`, `NoMissingModifier` (PhoneKeys) | 4 "Bar modifiers hit the next key only": a key or click reaches the Mac with the bar's modifiers if it is the first since Dan changed the bar, and with none otherwise. | invariants |
| `BarShowsArmed` (PhoneKeys) | 4, "... and the bar shows what the page has armed". | invariant, once settled |

"Once settled" means no quick step is left: the page committing or connecting, the worker's 1 s reconnect,
voxl's capture rebuild (within 1 s), the app's 1 s tick when it has work (and, unless `SlowAnswer`, voxl's answer
to a load). That is what Dan sees for more than a moment.

## Run it

```sh
ios/model/check.sh            # every config: about 3 minutes on the PC
ios/model/check.sh --guards   # also removes each guard once: a few minutes more
ios/model/check.sh --record   # records ios/Voxl's covered files in covered.sha256 (only after re-syncing)
```

It needs `mise` (it installs TLC 1.7.4 and Java 25 on first run, so the first run needs the network) or
`TLA2TOOLS` and `JAVA` set. On the PC run it from Git Bash (`C:/Program Files/Git/bin/bash.exe`), not WSL's bash.
Exit codes:

- 0: every verdict matches the baseline and the covered files are the ones recorded.
- 1: a verdict changed; its line is marked `<-- CHANGED` and TLC's path is printed.
- 2: TLC could not run.
- 3: every verdict matches, but a covered file in `ios/Voxl` changed since `covered.sha256` was recorded.

Each rule expected to break runs alone on one worker, so an invariant's printed path is TLC's shortest (a
liveness path is a loop TLC found, not always the shortest). TLC runs with `-fp 0`, so a temporal property's
printed loop is the same from run to run. Each TLC run has its own folder, temp folder and a 512 MB heap, and one
check runs at most 6 JVMs at once. A run whose Java dies without a verdict is started again, at most twice; a run
that ended with a verdict (exit 0, 11, 12 or 13) never is.

CI: `.github/workflows/ios-model.yml` runs `ios/model/check.sh` on every pull request that touches `ios/Voxl`,
`ios/model`, this skill or the workflow. The drift guard hashes the checked-out files, so CI's shallow checkout
is enough.

Read every result with the pstack `/statechart` skill: give it the model, the config of the run (one of the
`.cfg` files below, or one you write with the same constants), the view (`ios/model/screen-view.ts` for
PhoneScreen, `ios/model/keys-view.ts` for PhoneKeys) and a new output folder outside the repo. It tells each
broken rule as its path in plain words. Use the check's own output only to see which verdict moved.

## Baseline (sync below)

Every config starts PhoneKeys with the app in front on screen 1, connected; PhoneScreen with the app launching.

| Config | What | Breaks |
|---|---|---|
| `screen-sound` | Dan opens, touches, idles 5 min, leaves (behind, background, closed, suspended, back) | nothing |
| `screen-steady` | as sound, plus switching screens, the cover's button, Reconnect | nothing |
| `screen-slow` | voxl's answer can take over 3 s (`SlowAnswer`); switching, the cover's button | nothing |
| `screen-drop` | the socket drops, the worker's reconnect hangs, the web process ends | nothing |
| `screen-down` | a screen's voxl stops and starts; the reconnect hangs | nothing |
| `screen-behind` | Dan leaves; the web process ends or the socket drops, so a page commits behind | nothing |
| `screen-sharp` | another viewer holds screen 1 at Full; the screens have Sharp URLs | nothing |
| `screen-fullgone` | another viewer holds Full or asks again, and always leaves | CoverTellsTruth |
| `screen-full` | another viewer may keep Full; no Sharp URL until Dan asks; slow answers | CoverTellsTruth, ComesBack |
| `screen-silent` | the open socket goes silent with no close | CoverTellsTruth, ComesBack (known, see 1) |
| `keys-typing` | the bar's ⌘, two letters that may overlap (hardware keyboard), a click | nothing |
| `keys-esc` | the bar's ⌘, a held letter, the bar's Esc meanwhile | NoExtraModifier |
| `keys-pointer` | the bar's ⌘, a letter, a click, up to two drags at once, Trackpad/Direct meanwhile | NoExtraModifier |
| `keys-hold` | the bar's ⌘, still holds on the picture, Trackpad/Direct meanwhile | nothing |
| `keys-leave` | a held letter, click or drag, with or without ⌘ (tapped while the page shows); leave, back, switch | nothing |
| `keys-loading` | Dan switches screens and taps ⌘ while the new one loads | NoMissingModifier, BarShowsArmed |
| `keys-reload` | ⌘ tapped, then a load() without release() (retry, hello watch, web process, Reconnect, Ask for Sharp) | nothing |
| `keys-loss` | a held letter, click or drag; the socket drops and voxl sees it | nothing |
| `keys-tcp` | as loss, but voxl doesn't see the drop until TCP gives up | nothing |

The breaks, in the code's words (A = `ios/Voxl`, R = voxl 0.3.4):

1. Known, expected: a silent socket freezes the picture (`screen-silent`). The picture plays; the open socket goes
   silent with no close (the Mac lost power, the path died): no cover, and nothing reloads, since the hello watch
   is armed only by `load()` and a close (A ViewerController.swift:371-372, 655-658). A heartbeat can't come from
   the page: voxl's worker answers voxl's pings itself, on its own socket (R worker.ts:145-147), so they never pass
   the page's `Worker.postMessage`. a302a7d's watchdog read them there, never heard one, and reloaded a healthy
   page every 10 s (this model showed the loop); a6a72ed removed it. Recovers when Dan touches (a send fails).
2. A Full cover after the stream is Sharp again (`CoverTellsTruth` in `screen-fullgone`, `screen-full`). The hello
   handler hides the cover on a playable hello only if the picture already played (A ViewerController.swift:637-639).
   Path: open the app while another viewer holds Full; the hello says Full (`tooWideLater` armed); the other viewer
   asks again; 2 s later the cover says "Another viewer asked ... for Full" with "Ask for Sharp"; it leaves; a Sharp
   hello comes before the first frame: the cover keeps saying Full until the first frame (10-30 s around a Mac wake).
3. By design: while another viewer keeps Full and the screen has no Sharp URL, the app shows "Ask for Sharp" and
   waits for Dan (`ComesBack` in `screen-full`). With a Sharp URL every new connection takes Sharp back
   (`screen-sharp` holds).
4. ⌘ on the bar's Esc while a letter is held (`keys-esc`). `voxlTap` doesn't let go of `holding` (A Page.swift:89-92;
   `letGo` runs only on a trusted keydown and a mouse down, :95-101, 113): tap ⌘, hold a (⌘ held for it), tap the
   bar's Esc: the Mac gets ⌘Esc.
5. ⌘ on a key typed during a ⌘-drag (`keys-pointer`). A ⌘ armed for a click stays down until its up (`clickMods`,
   A Page.swift:112-119), and a trusted keydown lets go only of `holding`: tap ⌘, start a drag, press a: ⌘A.
6. A lit ⌘ the page doesn't have (`keys-loading`). `load()` clears the bar (A ViewerController.swift:368), but ⌘
   tapped while the new screen loads lights it and runs `voxlArm` in the blank document, which the page replaces:
   the bar shows ⌘ and the next key reaches the Mac without it.

`check.sh --guards` removes one guard at a time. Each must break something; if one stops breaking anything, a
rule is missing or the guard became dead. A single that breaks nothing is backed up by another guard, and its
pair row shows it:

| Guard removed (`Off`) | In the code | Config | Breaks |
|---|---|---|---|
| ResignMutes | `resignedActive` calls `updateAudio` (ViewerController.swift:755) | screen-sound | nothing: the 1 s tick mutes |
| ResignMutes, TickMutes | and the tick (:786-789) | screen-sound | QuietAway |
| TickMutes | the 1 s tick's `updateAudio` (:788) | screen-sound | QuietAway (5 idle minutes) |
| ActiveRule | `active` in `audible` (:722) | screen-sound | QuietAway |
| FreshMute | `muted = nil` for a new view (:350) | screen-steady | PlaysWhereIAm |
| FreshSuspend | a new view starts suspended (:348) | screen-behind | nothing: the commit applies the rule |
| CommitAudio, TickMutes | `didCommit`'s `updateAudio` (:528) and the tick | screen-behind | PlaysWhereIAm |
| FreshSuspend, CommitAudio, TickMutes | all three | screen-behind | QuietAway, PlaysWhereIAm |
| CommitAudio | `didCommit`'s `updateAudio` | screen-sound | nothing: the 1 s tick applies it |
| PictureHides | `picture` hides the cover (:644) | screen-sound | CoverTellsTruth, ComesBack |
| HelloHides | a playable hello hides it after the picture (:637-639) | screen-fullgone | CoverTellsTruth, ComesBack |
| WideWaits | a Full hello waits 2 s for the cover (`tooWideLater`, :627-636) | screen-sharp | CoverTellsTruth |
| WatchHello | `watchHello` at load and on close (:372, :412-421, :658) | screen-drop | ComesBack (a hung reconnect) |
| CommitClearsFailing | `didCommit` clears `failing` and shows the label (:524-527) | screen-slow | CoverTellsTruth |
| CoverAction | the button follows `coverAction` (:449-467) | screen-slow | nothing: commit clears `failing` |
| CoverAction, CommitClearsFailing | both | screen-full | NeverSwitchesByItself, CoverTellsTruth |
| Blur | `voxlRelease`'s blur, voxl's releaseAll (Page.swift:53, 141; R keyboard.ts:141-145, 285) | keys-leave | NothingStuck, NoExtraModifier |
| Hidden | a hidden page sends r (R main.ts:118-121) | keys-leave | nothing: blur and the close release |
| Hidden, Bye | and voxl's release-all when a connection ends (R server.rs:287-291) | keys-reload | NothingStuck |
| Bye | voxl's release-all when a connection ends | keys-loss | nothing: the reconnect's release |
| Bye, ReconnectRelease | and `release()` on a reconnect (ViewerController.swift:659-662) | keys-loss | NothingStuck, NoExtraModifier |
| ReconnectRelease | `release()` on a reconnect | keys-tcp | NothingStuck, NoExtraModifier |
| Disarm | `voxlRelease` disarms and drops holding, clickMods (Page.swift:141) | keys-leave | NoExtraModifier, BarShowsArmed |
| BarClear | `release()` clears the bar (ViewerController.swift:705) | keys-leave | nothing: the page's 'armed' message clears it |
| BarClear, ArmedMsg | and the 'armed' message (Page.swift:87; ViewerController.swift:671-672) | keys-leave | NoMissingModifier, BarShowsArmed |
| ArmedMsg | the page's 'armed' [] when it disarms | keys-typing | BarShowsArmed |
| LoadClearsBar | `load()` clears the bar (ViewerController.swift:368) | keys-reload | NoMissingModifier, BarShowsArmed |
| KeyUpLift | the keyup lifts holding's modifiers (Page.swift:102-104) | keys-typing | NothingStuck, NoExtraModifier |
| ClickLift | `voxlMouse('up')` lifts clickMods (Page.swift:118) | keys-typing | NothingStuck, NoExtraModifier |
| HoldPress | a key while armed presses the modifiers first (Page.swift:100) | keys-typing | NoMissingModifier |
| LetGoKey | another trusted keydown lets go of holding (Page.swift:98) | keys-typing | NoExtraModifier |
| LetGoClick | a mouse down lets go of holding (Page.swift:113) | keys-typing | NoExtraModifier |
| ButtonUp | pointerup sends b,n,0 (R pointer.ts:77-85) | keys-typing | NothingStuck |
| ModeUp | `mode`'s didSet sends up while dragging (Pointer.swift:18-26) | keys-pointer | NothingStuck (a Direct drag ended in Trackpad) |
| ModeUp (holds only) | | keys-hold | nothing: the hold's end lets go |
| HoldEndUp | a hold's end lets go in either mode (Pointer.swift:197-199) | keys-hold | nothing: the mode switch let go |
| ModeUp, HoldEndUp | both | keys-hold | NothingStuck |

(`keys-pointer` already breaks NoExtraModifier, so its rows list it too.)

The baseline held on 20 reruns of `check.sh` on 2026-11-13 at the sync below (the PC, four at a time, 14 minutes in all): exit 0
each time and byte-identical output.

## Timing contract

The models have no clock. Each holds only under these timing facts; if one changes, the model no longer
describes the code:

- Quick (about a second or less) against the app's 2, 3, 7, 10 and 30 s timers: the page committing once voxl
  answers, the worker's socket opening (it reconnects every 1 s, R worker.ts:113-117), voxl's capture rebuild after
  a scale request (once a second; measured about 0.5 s on the Duo), the 1 s tick. The timers fire only once these
  are done, so a Sharp request's new hello always cancels `tooWideLater` first.
- The timers of one try keep their order: `waitLater` (3 s) before `helloLater` (10 s from `load()` or from a
  close); `helloLater` from `load()` and `waited`'s 7 s retry fire together at about 10 s.
- Slow, any time: voxl's answer to a load when `SlowAnswer` (a poor link), a load failing, the first frames after
  a hello (10-30 s around a Mac wake), Dan, iOS and the network.
- Dan's actions in PhoneKeys can interleave with the quick steps (Dan can let go during a reconnect).

## Scope and assumptions

- Two screens of one Mac. Sharp (4096) is the widest picture the app plays; a Full (5120) stream doesn't play on
  the phone. voxl 0.3.4 streams the latest scale request and falls back to the one before when its viewer leaves
  (R server.rs:296-303, 398-404); the app asks for Sharp only from a screen's Sharp URL (A Machines.swift:17).
- One step per main-thread job: a script call the app makes runs in the document the view holds at that moment
  (evaluateJavaScript and key events reach the page in order); what the page posts reaches the app in the same
  step; what the page sends reaches voxl in the same step if the socket is open. A message in flight when the
  socket breaks is not modeled.
- WebKit, assumed: `setAllMediaPlaybackSuspended` silences the page's AudioWorklet and lasts across loads in that
  view; `navigator.audioSession.type` belongs to the document, so a new page starts at `auto`, which the silent
  switch mutes; at `didCommit` the injected scripts are in place; a removed web view is silent and its page
  closes, sending r and closing its socket before a new page's first message.
- iOS: the app is suspended only after `closePage` (the background task's expiry closes the page first). Opening
  the app counts as Dan's touch (`becameActive` calls `input()`), also when iOS makes it active after a call.
- voxl is a macOS voxl with Dan's capture-scale patch, not read-only. A voxl process that crashes (no SIGTERM)
  leaves its injected keys held: not modeled.
- Not modeled: voxl's password (the sheet waits for Dan by design; it pauses the hello watch and re-arms it after
  a credential, A ViewerController.swift:538-557), the Machines screen beyond a reload, 5xx answers, read-only
  voxl, resize, downloads, the clipboard, the cursor, the idle timer, old web views after `newWebView` (assumed
  silent). In PhoneKeys: hardware modifier keys, ⌘V's delayed paste (`pendingPaste`, R keyboard.ts:122-126, 179-185),
  iOS's Korean keyboard mirror (R keyboard.ts:146-178), the bar's Mac-key chords and Paste (`voxlChord` ignores
  armed modifiers), F-keys, autorepeat, the key mapping before the hello says the Mac is a Mac, the Files panel,
  zoom, a right-click.

## Coverage record

`A` = `ios/Voxl` in this repo. `R` = voxl 0.3.4 (the PC keeps it at `%LOCALAPPDATA%\voxl\src\0.3.4`).

| Model action | Code |
|---|---|
| PhoneScreen `UpdateAudio`, `Input`, `Tick` | A ViewerController.swift:710-730, 786-795, 178 |
| `NewWebView`, `Load`, `ClosePage`, `DocGone` | A ViewerController.swift:329-389; Machines.swift:14-27 |
| `Waited`, `RetryFires`, `HelloFires`, `Fail`, `NotAnswering`, `CoverButton` | A ViewerController.swift:391-467, 511-518 |
| `Answer`, `Crash` | A ViewerController.swift:520-535, 559-570 |
| `SocketOpens`, `Rebuild`, `Picture`, `TooWideFires`, `Drop`, `Hang`, `Dead`, `Down` | A ViewerController.swift:601-662; Page.swift:10-67; R worker.ts:97-147, main.ts:118-158, server.rs:214-305, 398-404 |
| `OtherFull`, `OtherGone` | R server.rs:296-303, 398-404 |
| `AudioStarts` | R main.ts:91-96, 189; audio.ts:10-31 |
| `BecomeActive`, `Resign`, `Background`, `Foreground`, `Suspend`, `CloseFires` | A ViewerController.swift:741-778; App.swift:25-28 |
| `Touch`, `Idle` | A App.swift:37-60; ViewerController.swift:710-716 |
| `SwitchScreen`, `Reconnect` | A ViewerController.swift:119-122, 294-309 |
| PhoneKeys `KeyIn`, `KeyOut`, `LetGo`, `MouseDown`, `MouseUp`, `VoxlTap`, `VoxlRelease`, `Disarm` | A Page.swift:74-141 |
| `KbdDown`, `KbdUp`, `KbdReleaseAll`, `Send` | R keyboard.ts:121-145, 187-217, 285; pointer.ts:62-89; main.ts:58-63; worker.ts:97-99, 404-406 |
| `Post`, `ReleaseAll`, `Judge` | R server.rs:258-305, 329-381; mac/input.rs:175-226, 244-287, 336-435 |
| `Release`, `Load`, `Teardown`, `Switch`, `Reload`, `Resign`, `Activate`, `Background`, `ClosePage` | A ViewerController.swift:300-309, 329-389, 434-441, 531-535, 671-672, 703-706, 741-773; R main.ts:118-121 |
| `DragStart`, `DragEnd`, `EndDrag`, `EndAll`, `Click`, `ModeFlip` | A Pointer.swift:18-26, 44, 92-111, 164-214, 256-268; ViewerController.swift:137-140 |
| `BarToggle`, `BarTap` | A KeyBar.swift:146-174 |
| `LossLoud`, `LossSilent`, `TcpGivesUp`, `Commit`, `SocketOpen` | A ViewerController.swift:520-529, 655-662; R worker.ts:104-117; server.rs:258-291 |

Drift guard: `ios/model/covered.sha256` holds a sha256 of
`ios/Voxl/{App,KeyBar,Machines,Page,Pointer,ViewerController}.swift` (carriage returns left out). `check.sh`
exits 3 when one differs. voxl isn't in this repo: check its paths above by hand when voxl's version moves.

Sync: voxl-viewer `eb7470e` (branch `ios-duo`, aklabs-korea/voxl-viewer), voxl 0.3.4. Line numbers above are at
these. Move this line, and record `covered.sha256` again, only after you confirmed the models describe the code
at the new commit.

## When you change covered code

1. Does the change touch a file or behavior in the coverage record? If not, stop.
2. Change the model to match the new code first: one model action per main-thread job, with its file:line in
   the comment. Never weaken a rule or the baseline to make a run pass.
3. Run `ios/model/check.sh`. A verdict that moved is either a real bug or a model that no longer matches the
   code. Read its path with `/statechart`, then replay it against the code one step per action. If the steps can
   happen in that order in the code, it is a bug: report it with the path in the code's words. If one step
   can't, the model is wrong: fix the model, not the rule.
4. A fix for one of the breaks above should move its verdicts to "holds": update `BASELINE` (and `GUARDS` if a
   guard row changes) in `check.sh` and the tables here, add a guard row for the new check, run
   `check.sh --guards`, and rerun `check.sh` a few times to see it stable. A rule that already breaks can't
   catch a new break, so each break fixed makes the check guard more.
5. Update the coverage record and the sync line, then run `ios/model/check.sh --record`. To bring the models
   back in line after changes made without them (exit 3), use `/pstack:maintain-formal-verification-skill`.
