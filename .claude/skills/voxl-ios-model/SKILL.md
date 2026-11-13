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
  key bar's ⌘, Esc, Mac keys and keyboard button, through `Page.input`, voxl's `keyboard.ts` and `pointer.ts`, the
  worker's socket, the app's release-all when it hears a socket open, voxl's hello (the re-arm) and each screen's
  voxl injector, with the app leaving, switching, reloading, losing its socket (also silently: voxl keeps it open)
  and reconnecting. Promises 3 and 4.

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

"Once settled" means no quick step is left: the page committing or connecting, the app hearing that its socket
opened, voxl's hello on a new connection, the worker's 1 s reconnect, voxl's capture rebuild (within 1 s), the
app's 1 s tick when it has work (and, unless `SlowAnswer`, voxl's answer to a load). That is what Dan sees for
more than a moment.

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
| `screen-fullgone` | another viewer holds Full or asks again, and always leaves | nothing |
| `screen-full` | another viewer may keep Full; no Sharp URL until Dan asks; slow answers | ComesBack (by design, see 2) |
| `screen-silent` | the open socket goes silent with no close | CoverTellsTruth, ComesBack (known, see 1) |
| `keys-typing` | the bar's ⌘, two letters that may overlap (hardware keyboard), a click | nothing |
| `keys-esc` | the bar's ⌘, a held letter, the bar's Esc or one of its Mac keys (a chord) meanwhile | nothing |
| `keys-pointer` | the bar's ⌘, a letter, a click, up to two drags at once, Trackpad/Direct meanwhile | NoExtraModifier |
| `keys-hold` | the bar's ⌘, still holds on the picture, Trackpad/Direct meanwhile | nothing |
| `keys-leave` | a held letter, click or drag, with or without ⌘ (tapped while the page shows); leave, back, switch | nothing |
| `keys-loading` | Dan switches screens and taps ⌘ (and may pick a Mac key) while the new one loads; no keyboard button | nothing |
| `keys-kbbutton` | Dan switches screens and taps ⌘ and the keyboard button while the new one loads | NoMissingModifier (see 5) |
| `keys-reload` | ⌘ tapped, then a load() without release() (retry, hello watch, web process, Reconnect, Ask for Sharp) | nothing |
| `keys-loss` | a held letter, click or drag; the socket drops and voxl sees it | nothing |
| `keys-tcp` | as loss, but voxl doesn't see the drop until TCP gives up | NoExtraModifier (see 4) |
| `keys-fresh` | a held letter, click or drag, with or without ⌘ (tapped while the page shows); the socket goes silent (voxl keeps it open), and the worker reconnects or a fresh page loads (a load() without release()) | NoExtraModifier (see 4) |

`KbLoading` (the bar's keyboard button before the picture) is on in every keys config but `keys-loading`, so
that one checks the `Resend` fix alone and break 5 has its own config. Its "nothing" doesn't cover a chord's
own modifiers (scope item c).

The breaks, in the code's words (A = `ios/Voxl`, R = voxl 0.3.4):

1. Known, expected: a silent socket freezes the picture (`screen-silent`). The picture plays; the open socket goes
   silent with no close (the Mac lost power, the path died): no cover, and nothing reloads, since the hello watch
   is armed only by `load()` and a close (A ViewerController.swift:376, 677-682). A heartbeat can't come from
   the page: voxl's worker answers voxl's pings itself, on its own socket (R worker.ts:145-147), so they never pass
   the page's `Worker.postMessage`. a302a7d's watchdog read them there, never heard one, and reloaded a healthy
   page every 10 s (this model showed the loop); a6a72ed removed it. Recovers when Dan touches (a send fails).
2. By design: while another viewer keeps Full and the screen has no Sharp URL, the app shows "Ask for Sharp" and
   waits for Dan (`ComesBack` in `screen-full`). With a Sharp URL every new connection takes Sharp back
   (`screen-sharp` holds).
3. ⌘ on a key typed during a ⌘-drag (`keys-pointer`). A ⌘ armed for a click stays down until its up (`clickMods`,
   A Page.swift:122-129), and a trusted keydown lets go only of `holding`: tap ⌘, start a drag, press a: ⌘A.
4. A click, or a key, in the moment a socket opens after a silent one gets a ⌘ held from it (`NoExtraModifier`
   in `keys-tcp` and `keys-fresh`). voxl lets go only when a connection ends (R server.rs:290-294). The app lets
   go when it hears the new socket open (a window blur, voxl's release-all: A ViewerController.swift:683-689, on
   every open since 5e57a1f), a status that goes from the worker to the page (A Page.swift:35) to the app; the
   page's sends go out from the worker's open (R worker.ts:97-99, 108-112). A tap on the pad is sent at once
   (Pointer.swift:266-278, Page.swift:116-130; the cover covers the picture, not the pad), and so is a key when
   the view has the keys. Path (`keys-tcp`): tap ⌘, hold a (⌘ held for it); the socket goes silent (voxl keeps
   it, with ⌘ and a down); let go of a (lost); the worker reconnects 1 s later and its socket opens; Dan taps the
   pad before the app has heard the open: the Mac gets ⌘-click; the app's blur then lets go of everything. With a
   hardware keyboard the same path ending in a key gives ⌘a (`keys-fresh` with Presses = 2, Clicks = 0,
   Drags = 0: BarToggle, KeyDown, LossSilent, KeyUp, SocketOpen, KeyDown): on a reconnect the view keeps the keys.
   On a fresh page (Reconnect, or the hello watch 10 s after the close) a key needs the bar's keyboard button
   first (BarToggle, KeyDown, LossSilent, KeyUp, Reload, KbButton, Commit, SocketOpen, KeyDown). A window of
   milliseconds: the status's two hops, worker to page to app. Before 5e57a1f the reconnect had the same window
   (its `release()` ran at the same message) and a fresh page's ran until voxl's hello; the model before then
   took the open and the app hearing it as one step, so it showed only the fresh page. Rare in real use: ⌘ (or
   another bar modifier) must be down for a held key or drag when the network drops (Wi-Fi to cellular), and
   Dan's next tap or key must land within those milliseconds of the reconnect; the Mac then gets one ⌘-click or
   ⌘-key.
5. A key typed in the moment a new page connects misses a ⌘ tapped while it loaded, after the bar's keyboard
   button (`NoMissingModifier` in `keys-kbbutton`). The keyboard button runs `focusKeys` any time there is a web
   view (A KeyBar.swift:94, ViewerController.swift:148, 724-727, 716-722), and the bar is above the cover and
   beside it (added after it, :102, 148; the cover takes the picture's frame and the bar its own strip, :202, 213
   and Layout.swift:24-56), so the new view can have the keys before its first frame (voxl's page focuses #kbd
   itself when it starts, R keyboard.ts:287). The page is armed with a ⌘ tapped while it loaded only by the
   hello's `keyBar.resend` (A ViewerController.swift:661). Path: Dan switches screens; while the new one loads he
   taps ⌘ (lit; the loading view has no `voxlArm`) and the keyboard button (before or after the commit); voxl's
   page commits; its socket opens; Dan presses a before the app has handled voxl's hello: the Mac gets a without
   ⌘; the hello then arms the page and ⌘ stays lit for the next key. Any load() with a modifier tapped while it
   loads does it, not only a switch (Reconnect, a retry, the hello watch, the web process ending, the cover's
   button: `load()` clears the bar first, :365). A window of milliseconds (between the new socket opening and the
   app handling voxl's first message), and only after the keyboard button: without it, keys reach a new page
   from its first frame, which comes after the hello.

ce88951 fixed the earlier breaks in `screen-fullgone` and `screen-full` (a Full cover left after a Sharp hello),
`keys-esc` (⌘ held for a letter landing on the bar's Esc) and `keys-loading` (⌘ tapped while a screen loads never
reaching its page): the `HelloSharp`, `TapLetGo` and `Resend` rows below. 5e57a1f moved the release-all from the
hello to the socket's open (voxl sends a hello again when it restarts its stream, which let go of a held drag) and
dropped the reconnect's `release()`, so the bar's modifiers stay armed across a reconnect; `voxlChord` takes the
armed modifiers and disarms, and the bar's chord and Paste clear the bar: the `OpenRelease`, `ChordDisarm` and
`ChordBarClear` rows.

`check.sh --guards` removes one guard at a time. Each must break something; if one stops breaking anything, a
rule is missing or the guard became dead. A single that breaks nothing is backed up by another guard, and its
pair row shows it:

| Guard removed (`Off`) | In the code | Config | Breaks |
|---|---|---|---|
| ResignMutes | `resignedActive` calls `updateAudio` (ViewerController.swift:783) | screen-sound | nothing: the 1 s tick mutes |
| ResignMutes, TickMutes | and the tick (:803-806) | screen-sound | QuietAway |
| TickMutes | the 1 s tick's `updateAudio` (:805) | screen-sound | QuietAway (5 idle minutes) |
| ActiveRule | `active` in `audible` (:739) | screen-sound | QuietAway |
| FreshMute | `muted = nil` for a new view (:348) | screen-steady | PlaysWhereIAm |
| FreshSuspend | a new view starts suspended (:346) | screen-behind | nothing: the commit applies the rule |
| CommitAudio, TickMutes | `didCommit`'s `updateAudio` (:533) and the tick | screen-behind | PlaysWhereIAm |
| FreshSuspend, CommitAudio, TickMutes | all three | screen-behind | QuietAway, PlaysWhereIAm |
| CommitAudio | `didCommit`'s `updateAudio` | screen-sound | nothing: the 1 s tick applies it |
| PictureHides | `picture` hides the cover (:656) | screen-sound | CoverTellsTruth, ComesBack |
| HelloHides | a playable hello hides it after the picture (:644-645) | screen-fullgone | CoverTellsTruth, ComesBack |
| HelloSharp | a playable hello before a frame takes the Full cover back to the label (:646-649) | screen-fullgone | CoverTellsTruth |
| WideWaits | a Full hello waits 2 s for the cover (`tooWideLater`, :634-643) | screen-sharp | nothing: the Sharp hello takes the Full cover back |
| WideWaits, HelloSharp | both | screen-sharp | CoverTellsTruth |
| WatchHello | `watchHello` at load and on the first close with none pending (:369, :410-421, :672) | screen-drop | ComesBack (a hung reconnect) |
| CommitClearsFailing | `didCommit`'s `gotAnswer` clears `failing` and shows the label (:532, 423-430) | screen-slow | CoverTellsTruth |
| CoverAction | the button follows `coverAction` (:458-476) | screen-slow | nothing: commit clears `failing` |
| CoverAction, CommitClearsFailing | both | screen-full | NeverSwitchesByItself, CoverTellsTruth |
| Blur | `voxlRelease`'s blur, voxl's releaseAll (Page.swift:53, 160; R keyboard.ts:141-145, 285) | keys-leave | NothingStuck, NoExtraModifier |
| Hidden | a hidden page sends r (R main.ts:118-121) | keys-leave | nothing: blur and the close release |
| Hidden, Bye | and voxl's release-all when a connection ends (R server.rs:290-294) | keys-reload | nothing: the new page's open releases |
| Hidden, Bye, OpenRelease | all three | keys-reload | NothingStuck |
| Bye | voxl's release-all when a connection ends | keys-loss | NoExtraModifier (a click after the reconnect's socket opens, before the app hears it) |
| Bye, OpenRelease | both | keys-loss | NothingStuck, NoExtraModifier |
| OpenRelease | the app's window blur, voxl's release-all, when it hears any socket open (ViewerController.swift:683-689; R keyboard.ts:141-145, 285) | keys-tcp | NothingStuck (a key or button held through the silent socket); NoExtraModifier is break 4 |
| Disarm | `voxlRelease` disarms and drops holding, clickMods (Page.swift:160) | keys-leave | NoExtraModifier, BarShowsArmed |
| BarClear | `release()` clears the bar (ViewerController.swift:732) | keys-leave | nothing: the page's 'armed' message clears it |
| BarClear, ArmedMsg | and the 'armed' message (Page.swift:87; ViewerController.swift:698-699) | keys-leave | NoExtraModifier, NoMissingModifier, BarShowsArmed |
| ArmedMsg | the page's 'armed' [] when it disarms | keys-typing | BarShowsArmed |
| LoadClearsBar | `load()` clears the bar (ViewerController.swift:371) | keys-reload | NoMissingModifier: ⌘ stays lit through the reload, so break 5 shows here (a key after the keyboard button, before the hello); the hello arms the new page with the lit ⌘, so BarShowsArmed holds |
| LoadClearsBar, Resend | both | keys-reload | NoMissingModifier, BarShowsArmed |
| Resend | the hello sends the lit modifiers again (`keyBar.resend`, ViewerController.swift:661; KeyBar.swift:165-168) | keys-loading | NoMissingModifier, BarShowsArmed |
| TapLetGo | `voxlTap` lets go of holding first (Page.swift:90) | keys-esc | NoExtraModifier |
| ChordDisarm | `voxlChord` disarms (Page.swift:97) | keys-esc | NoExtraModifier, BarShowsArmed |
| ChordBarClear | `chord` clears the bar (KeyBar.swift:154; Paste the same, :186) | keys-esc | nothing: the page's 'armed' message clears it |
| ChordBarClear (loading) | | keys-loading | NoExtraModifier (a Mac key picked while the page loads goes nowhere; the hello then arms the next key with the ⌘ still lit) |
| KeyUpLift | the keyup lifts holding's modifiers (Page.swift:112-114) | keys-typing | NothingStuck, NoExtraModifier |
| ClickLift | `voxlMouse('up')` lifts clickMods (Page.swift:128) | keys-typing | NothingStuck, NoExtraModifier |
| HoldPress | a key while armed presses the modifiers first (Page.swift:108) | keys-typing | NoMissingModifier |
| LetGoKey | another trusted keydown lets go of holding (Page.swift:106) | keys-typing | NoExtraModifier |
| LetGoClick | a mouse down lets go of holding (Page.swift:123) | keys-typing | NoExtraModifier |
| ButtonUp | pointerup sends b,n,0 (R pointer.ts:77-85) | keys-typing | NothingStuck |
| ModeUp | `mode`'s didSet sends up while dragging (Pointer.swift:18-26) | keys-pointer | NothingStuck (a Direct drag ended in Trackpad) |
| ModeUp (holds only) | | keys-hold | nothing: the hold's end lets go |
| HoldEndUp | a hold's end lets go in either mode (Pointer.swift:207-209) | keys-hold | nothing: the mode switch let go |
| ModeUp, HoldEndUp | both | keys-hold | NothingStuck |

(A config's baseline break shows in its rows too: `screen-full` ComesBack, `keys-pointer`, `keys-tcp` and
`keys-fresh` NoExtraModifier, `keys-kbbutton` NoMissingModifier.)

No guard, since no rule tells the code from the code before it: 5e57a1f's two changes to a close in PhoneScreen.
`tooWideLater` is cancelled on a close (A ViewerController.swift:680): before, a closed connection's Full hello
could still put up the Full cover 2 s later, which said what voxl then did (the phone's scale request goes with
its socket, so the other viewer's Full is the latest), and the next hello takes it back. The 10 s watch counts
from the first close (:672): see "voxl refusing connections" below. The trusted `beforeinput` disarm
(A Page.swift:111) is for text with no key, which isn't modeled.

The baseline held on 20 reruns of `check.sh` on 2026-11-13 at the sync below (5e57a1f; the PC, Git Bash, four
separate `check.sh` processes at a time, 14 minutes in all): exit 0 each time and byte-identical output.

## Timing contract

The models have no clock. Each holds only under these timing facts; if one changes, the model no longer
describes the code:

- Quick (about a second or less) against the app's 2, 3, 7, 10 and 30 s timers: the page committing once voxl
  answers, the worker's socket opening (it reconnects every 1 s, R worker.ts:113-117), the app hearing it opened
  (the status's hops from the worker to the page to the app), voxl's hello right after (its first message,
  R server.rs:223), voxl's capture rebuild after a scale request (once a second; measured about 0.5 s on the Duo),
  the 1 s tick. The timers fire only once these are done, so a Sharp request's new hello always cancels
  `tooWideLater` first.
- The timers of one try keep their order: `waitLater` (3 s) before `helloLater` (10 s from `load()` or, with no
  watch pending, from a close); `helloLater` from `load()` and `waited`'s 7 s retry fire together at about 10 s.
- Slow, any time: voxl's answer to a load when `SlowAnswer` (a poor link), a load failing, the first frames after
  a hello (10-30 s around a Mac wake), Dan, iOS and the network. Dan's keys reach a new web view's page from its
  first frame (`focusKeys` at the picture, A ViewerController.swift:667), or from its commit once he taps the bar's
  keyboard button (`focusKeys` from `toggleKeyboard`, :714-717, any time there is a web view; voxl's page focuses
  #kbd when it starts, R keyboard.ts:287); his taps on the pad reach it as soon as it commits.
- Dan's actions in PhoneKeys can interleave with the quick steps (Dan can let go during a reconnect, or tap the
  pad or type between a new socket opening and the app hearing it, or voxl's hello).

## Scope and assumptions

- Two screens of one Mac. Sharp (4096) is the widest picture the app plays; a Full (5120) stream doesn't play on
  the phone. voxl 0.3.4 streams the latest scale request and falls back to the one before when its viewer leaves
  (R server.rs:299-306, 401-407); the app asks for Sharp only from a screen's Sharp URL (A Machines.swift:17).
- One step per main-thread job: a script call the app makes runs in the document the view holds at that moment
  (evaluateJavaScript and key events reach the page in order); what the page posts reaches the app in the same
  step; what the page sends reaches voxl in the same step if the socket is open. In PhoneKeys the worker's socket
  opening is a step of its own: the page's sends go out from then, and the app hears the open (its release-all)
  in a later step. A message in flight when the socket breaks is not modeled.
- WebKit, assumed: `setAllMediaPlaybackSuspended` silences the page's AudioWorklet and lasts across loads in that
  view; `navigator.audioSession.type` belongs to the document, so a new page starts at `auto`, which the silent
  switch mutes; at `didCommit` the injected scripts are in place; a removed web view is silent and its page
  closes, sending r and closing its socket before a new page's first message.
- WebKit and UIKit, assumed, for the keys' focus (PhoneKeys `focused`): a web view made first responder before
  its page commits (the keyboard button) keeps that through the commit; hardware keys then reach the #kbd that
  voxl's page focuses when it starts (R keyboard.ts:287); a view that became first responder before its picture
  stays so through Resign and Activate (`becameActive` calls `focusKeys` again only once there is a picture,
  A ViewerController.swift:774).
- iOS: the app is suspended only after `closePage` (the background task's expiry closes the page first). Opening
  the app counts as Dan's touch (`becameActive` calls `input()`), also when iOS makes it active after a call.
- voxl is a macOS voxl with Dan's capture-scale patch, not read-only. A voxl process that crashes (no SIGTERM)
  leaves its injected keys held: not modeled.
- A silent socket in PhoneKeys (`silent`): voxl keeps the connection, and what it holds, until TCP gives up
  (R server.rs:261-294). The model has the phone see the close and reconnect in 1 s, so the promises are checked
  once the phone has a connected page again, by that reconnect or a fresh page; a socket silent on both ends looks
  the same to voxl (what the phone sends is lost either way), and while it stays silent nothing the app sends
  reaches voxl, so the model doesn't check that time.
- Real, but in no baseline config (seen in runs while re-syncing to 04f677a, again at 5e57a1f): (a) a key or
  button held on one screen when its socket goes silent stays held there after Dan switches to the other screen,
  until TCP gives up or he comes back: the app's release-all at a socket's open reaches only the screen whose page
  connects, and each screen has its own voxl (silent then switch: `NothingStuck`, path KeyDown, LossSilent,
  Switch, Commit, SocketOpen, StatusOpen, Hello). (b) ⌘ tapped while a page loads misses a pad tap made between
  the new socket opening and the hello, and stays lit for the next key (`keys-fresh` with `ArmLoading`:
  `NoMissingModifier`, path Reload, BarToggle, Commit, SocketOpen, Click). Its key version, after the keyboard
  button, is break 5. (c) Its chord version: ⇧ tapped while a page loads, then a Mac key from the bar (⌘Tab)
  between the new socket opening and the hello reaches the Mac without ⇧, and the chord clears the bar, so the
  hello resends nothing (A KeyBar.swift:154, ViewerController.swift:661). The model can't show it, since ⌘
  stands for every modifier and every chord presses ⌘ (see Not modeled); a copy where the chord's modifier
  differs from the bar's breaks `NoMissingModifier` on `keys-loading`, path Switch, BarToggle, Commit,
  SocketOpen, BarChord. Same millisecond window as (b) and break 5: very rare.
- voxl refusing connections (voxl down while its page stays in the view: the worker's socket closes every second,
  R worker.ts:113-117): the model has one close per lost socket and no clock, so it shows the 10 s watch firing
  10 s after the close, a fresh page, the failed load and "isn't answering". Since 5e57a1f that is what the code
  does (the watch counts from the first close, A ViewerController.swift:682); before it each close restarted the
  watch, so it never fired and voxl's own "Reconnecting…" stayed on the last frame. No rule tells the two apart:
  that cover is true too, and the page reconnects by itself once voxl is back.
- Not modeled: voxl's password (the sheet waits for Dan by design; a challenge counts as an answer, `gotAnswer`;
  it pauses the hello watch and re-arms it after a credential; after Cancel, the page's later challenges are
  cancelled without a sheet until he taps Sign in, and the watch skips while `needsPassword`,
  A ViewerController.swift:417-428, 555-577), the Machines screen beyond a reload, 5xx answers, read-only voxl,
  resize, downloads, the clipboard, the cursor, the idle timer, old web views after `newWebView` (assumed
  silent), and a screen's part (Parts.swift): following a window part, the app switches to the machine's other
  screen when the window moves there. Dan asked for that switch (2026-11-13); it follows his pick of the window,
  so `NeverSwitchesByItself` leaves it out. In PhoneKeys: hardware modifier keys (since 5e57a1f the keydown listener ignores them on either side,
  A Page.swift:103-105), text with no key (a suggestion, dictation: keyboard.ts's input listener types it,
  R keyboard.ts:265-282, and a trusted `beforeinput` disarms, A Page.swift:111), Paste's paste event and
  keyboard.ts's delayed ⌘V (`pendingPaste`, R keyboard.ts:122-126, 179-185, 195-199: Paste's ⌘V is a chord
  here), the chords' own modifiers apart from ⌘ (⌃↑; ⌘ stands for all four, so a chord's taking the armed ones
  doesn't show), voxl's hello again on a connection when it restarts its stream (since 5e57a1f it only re-arms
  the lit modifiers), iOS's Korean keyboard mirror (R keyboard.ts:146-178), F-keys, autorepeat, the key mapping
  before the hello says the Mac is a Mac, the Files panel, zoom, a right-click.

## Coverage record

`A` = `ios/Voxl` in this repo. `R` = voxl 0.3.4 (the PC keeps it at `%LOCALAPPDATA%\voxl\src\0.3.4`).

| Model action | Code |
|---|---|
| PhoneScreen `UpdateAudio`, `Input`, `Tick` | A ViewerController.swift:737-757, 816-825, 177 |
| `NewWebView`, `Load`, `ClosePage`, `DocGone` | A ViewerController.swift:333-393; Machines.swift:14-27 |
| `Waited`, `RetryFires`, `HelloFires`, `Fail`, `NotAnswering`, `CoverButton` | A ViewerController.swift:395-483, 533-540 |
| `Answer`, `Crash` | A ViewerController.swift:430-437, 542-553, 579-590 |
| `SocketOpens`, `Rebuild`, `HelloIn`, `StatusClosed`, `Picture`, `TooWideFires`, `Drop`, `Hang`, `Dead`, `Down` | A ViewerController.swift:621-689; Page.swift:10-67; R worker.ts:97-147, main.ts:118-158, server.rs:217-308, 401-407 |
| `OtherFull`, `OtherGone` | R server.rs:299-306, 401-407 |
| `AudioStarts` | R main.ts:91-96, 189; audio.ts:10-31 |
| `BecomeActive`, `Resign`, `Background`, `Foreground`, `Suspend`, `CloseFires` | A ViewerController.swift:768-808; App.swift:25-28 |
| `Touch`, `Idle` | A App.swift:37-60; ViewerController.swift:737-743 |
| `SwitchScreen`, `Reconnect` | A ViewerController.swift:118-121, 296-313 |
| PhoneKeys `KeyIn`, `KeyOut`, `LetGo`, `MouseDown`, `MouseUp`, `VoxlTap`, `VoxlChord`, `VoxlRelease`, `Disarm` | A Page.swift:74-160 |
| `KbdDown`, `KbdUp`, `KbdReleaseAll`, `Send` | R keyboard.ts:121-145, 187-217, 285; pointer.ts:62-89; main.ts:58-63; worker.ts:97-99, 404-406 |
| `Post`, `ReleaseAll`, `Judge` | R server.rs:261-308, 332-384; mac/input.rs:175-226, 244-287, 336-435 |
| `Release`, `Load`, `Teardown`, `Switch`, `Reload`, `Resign`, `Activate`, `Background`, `ClosePage` | A ViewerController.swift:304-313, 333-393, 450-457, 549-553, 698-699, 730-733, 768-803; R main.ts:118-121 |
| `DragStart`, `DragEnd`, `EndDrag`, `EndAll`, `Click`, `ModeFlip` | A Pointer.swift:18-26, 46, 102-121, 174-224, 266-278; ViewerController.swift:137-140 |
| `BarToggle`, `BarTap`, `BarChord` | A KeyBar.swift:146-162, 171-181, 183-187 |
| `KbButton`, `Load`'s kept focus | A KeyBar.swift:94; ViewerController.swift:102, 148-149, 203, 214, 357-378, 716-727; Page.swift:54-61; R keyboard.ts:287 (Layout.swift:24-56 only for "beside") |
| `LossLoud`, `LossSilent`, `TcpGivesUp`, `Commit`, `SocketOpen`, `StatusOpen` | A ViewerController.swift:542-547, 674-689; Page.swift:35; R worker.ts:97-117; keyboard.ts:141-145, 285; server.rs:261-294, 384 |
| `Hello`, `Picture`, `KeyDown`'s and `KeyUp`'s focus | A ViewerController.swift:631-673, 716-722, 768-778; KeyBar.swift:164-168; Page.swift:13-15, 32-41; R server.rs:217-223, worker.ts:155-164, main.ts:108-121 |

Drift guard: `ios/model/covered.sha256` holds a sha256 of
`ios/Voxl/{App,KeyBar,Machines,Page,Pointer,ViewerController}.swift` (carriage returns left out). `check.sh`
exits 3 when one differs. Layout.swift isn't covered: no rule leans on it (the bar is above the cover because
ViewerController adds it later, :102, 149). Nor is Parts.swift (a screen's part): it only zooms the picture and
calls voxl's window routes, and its hooks in covered files (`go(to:)` stepping the part when the screen on view is
picked again, `load` and `becameActive` following a window part, `enteredBackground` putting the window back, the
hello showing the part, `machinesChanged` putting it back when the screen on view changes, the layout refitting it
when the room changes) add no model action. voxl isn't in this repo: check its paths above by hand when voxl's
version moves.

Sync: voxl-viewer `5e57a1f` (branch `ios-duo`, aklabs-korea/voxl-viewer), voxl 0.3.4; then branch `screen-parts`
(a screen's part), which moves no model action: its A lines above are the branch's, and its R server.rs lines moved
by three with voxl patch 0017 (window routes, three lines in router()). Line numbers above are at
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
