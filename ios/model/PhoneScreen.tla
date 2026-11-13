------------------------------ MODULE PhoneScreen ------------------------------
(***************************************************************************)
(* The iPhone/iPad app connecting to a Mac screen and playing its sound:   *)
(* the app's connect attempt (ViewerController: a web view per try, the    *)
(* cover and its button, the 2, 3, 7, 10 and 30 s timers, the 1 s tick),  *)
(* the scene's life (in front, behind, background, the page closed, iOS   *)
(* suspending the app), what the injected scripts tell the app             *)
(* (Page.watch: hello, status, picture once per page), voxl's page (its    *)
(* worker socket that reconnects every 1 s, its                            *)
(* AudioContext, navigator.audioSession) and each screen's voxl (the       *)
(* hello's size, the scale requests: the phone's cs,0.8 on a screen with a *)
(* Sharp URL, another viewer asking for Full).                             *)
(*                                                                         *)
(* Code (the coverage record and sync point are in                         *)
(* .claude/skills/voxl-ios-model/SKILL.md):                                *)
(*   A = ios/Voxl in this repo: ViewerController.swift, Page.swift,        *)
(*       App.swift, Machines.swift.                                        *)
(*   R = voxl 0.3.4: web/src/client/main.ts, audio.ts, web/src/worker.ts,  *)
(*       src/server.rs, src/hub.rs, src/mac/mod.rs, src/video.rs.          *)
(*                                                                         *)
(* Two screens of one Mac, 1 and 2. Sharp (4096) is the widest picture the *)
(* app plays; "wide" is Full (5120), asked for only by another viewer.     *)
(*                                                                         *)
(* Steps. One step is one main-thread job of the app, or one event of the  *)
(* page or of voxl and the app's handling of what the page posts about it  *)
(* (WKScriptMessage, in order with the navigation callbacks). Quick steps  *)
(* take at most about a second: the page's AudioContext starting, its      *)
(* socket opening once voxl answers, voxl's capture rebuild after a scale  *)
(* change (within 1 s), the 1 s tick when it has work, and voxl's answer   *)
(* to a load unless SlowAnswer (a poor link: over 3 s). The app's 2, 3, 7, *)
(* 10 and 30 s timers fire only when no quick step is left (Settled), and  *)
(* the promises are checked there: what Dan sees for more than a moment.   *)
(* Slow steps can happen any time: a load failing, the first frames (10-30 *)
(* s around a Mac wake), Dan, iOS, the network. No time otherwise: 5       *)
(* minutes pass in one step. Off removes guards, to show each one matters. *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS DanActs, DanMax, Events, EnvMax, StartFull, OtherLeaves, SlowAnswer, HasSharp, Off

Screens == {1, 2}
\* touch: Dan touches or types in the app. idle: 5 minutes pass with no input.
\* leave: the app stops being in front (and may go to the background, close
\* its page after 30 s, be suspended, come back). switch: a tab or F1/F2.
\* cover: the cover's button. reconnect: More > Reconnect.
DanNames   == {"touch", "idle", "leave", "switch", "cover", "reconnect"}
\* down: a screen's voxl stops (its socket closes) and starts again. drop: the
\* page's socket closes, voxl still up. hang: the worker's next socket neither
\* opens nor closes (the case the hello watch is for). crash: the page's web
\* process ends. full: another viewer asks a screen for Full, and later
\* leaves. dead: the open socket goes silent with no close event (the Mac
\* lost power, the path died).
EventNames == {"down", "drop", "hang", "crash", "full", "dead"}
Guards     == {"ResignMutes", "TickMutes", "ActiveRule", "CommitAudio", "FreshMute", "FreshSuspend",
               "PictureHides", "HelloHides", "WatchHello", "CommitClearsFailing", "CoverAction",
               "WideWaits", "HelloSharp"}

ASSUME /\ DanActs \subseteq DanNames /\ Events \subseteq EventNames /\ Off \subseteq Guards
       /\ DanMax \in Nat /\ EnvMax \in Nat
       /\ {StartFull, OtherLeaves, SlowAnswer, HasSharp} \subseteq BOOLEAN

Has(g)   == g \notin Off
Other(s) == 3 - s
\* A scale request list without x (hub.scale_requests, R server.rs:299-306, 401-407).
Drop1(q, x) == SelectSeq(q, LAMBDA y : y # x)

VARIABLES
  scene,     \* "active", "inactive", "background", "suspended" (A App.swift:25-28)
  recent,    \* Dan touched or typed in the last 5 minutes (lastInput, A ViewerController.swift:54, 736)
  row,       \* the screen asked for
  web,       \* a web view exists
  dscr,      \* the screen the view's page was loaded for (loaded, :38)
  dsharp,    \* that page was loaded from the screen's Sharp URL (?scale=0.8, A Machines.swift:17)
  sharp,     \* [Screens -> BOOLEAN]: the screen has a Sharp URL (Screen.sharp, A Machines.swift:14)
  answered, committed, hello, picture, failing, tooWide,   \* the try's flags (:39-42)
  waitT,     \* waitLater armed (3 s, :388-393)
  retryT,    \* retryLater: "none", "cond" (waited's, :400-405: loads only if still unanswered),
             \* "always" (retry's, :447-449)
  helloT,    \* helloLater (10 s, :410-421): "off", or armed by "load" or by a socket "closed"
  closeT,    \* closeLater armed (30 s, :783-788)
  wideT,     \* tooWideLater armed (2 s, :48, 634-643)
  cover,     \* the Cover (:835-876) as showCover left it (:453-456): "off" (hidden), "label"
             \* (the screen's name, no button), "dim" ("isn't answering. Trying again every 3 s."
             \* + "Show <other>", action otherScreen), "full" ("Another viewer asked ... for Full
             \* ..." + "Ask for Sharp", action sharp)
  muted,     \* muted: Bool?, the last sound state applied (:57): "nil", "yes", "no"
  nav,       \* the view's document: "none" (blank), "asked" (a load out), "page" (voxl's page)
  sock,      \* the page's socket: "none", "closed" (the worker reconnects every 1 s), "open",
             \* "hung" (neither opens nor closes), "dead" (looks open, nothing comes)
  pagePic,   \* Page.watch posted picture (once per page, A Page.swift:13-14)
  docWide,   \* the page's latest hello is Full: its frames don't play here
  audioOn,   \* the page's AudioContext runs (R audio.ts:10-31, main.ts:189)
  session,   \* the page's navigator.audioSession.type: "auto", "playback", "ambient"
  susp,      \* setAllMediaPlaybackSuspended(true) is in force on the view
  up,        \* [Screens -> BOOLEAN]: the screen's voxl answers
  reqs,      \* [Screens -> sequence of "phone", "other"]: its scale requests, latest last
  wide,      \* [Screens -> BOOLEAN]: its capture is Full
  dann,      \* Dan's actions so far (bound)
  envn,      \* world events so far (bound)
  stray      \* (ghost) a cover button that didn't say "Show <other>" switched screens

vars == <<scene, recent, row, web, dscr, dsharp, sharp, answered, committed, hello, picture, failing,
          tooWide, waitT, retryT, helloT, closeT, wideT, cover, muted, nav, sock, pagePic, docWide,
          audioOn, session, susp, up, reqs, wide, dann, envn, stray>>

Now == [scene |-> scene, recent |-> recent, row |-> row, web |-> web, dscr |-> dscr, dsharp |-> dsharp,
        sharp |-> sharp, answered |-> answered, committed |-> committed, hello |-> hello,
        picture |-> picture, failing |-> failing, tooWide |-> tooWide, waitT |-> waitT,
        retryT |-> retryT, helloT |-> helloT, closeT |-> closeT, wideT |-> wideT, cover |-> cover,
        muted |-> muted, nav |-> nav, sock |-> sock, pagePic |-> pagePic, docWide |-> docWide,
        audioOn |-> audioOn, session |-> session, susp |-> susp, up |-> up, reqs |-> reqs,
        wide |-> wide, dann |-> dann, envn |-> envn, stray |-> stray]
Set(r) == /\ scene' = r.scene /\ recent' = r.recent /\ row' = r.row /\ web' = r.web /\ dscr' = r.dscr
          /\ dsharp' = r.dsharp /\ sharp' = r.sharp /\ answered' = r.answered
          /\ committed' = r.committed /\ hello' = r.hello /\ picture' = r.picture
          /\ failing' = r.failing /\ tooWide' = r.tooWide /\ waitT' = r.waitT /\ retryT' = r.retryT
          /\ helloT' = r.helloT /\ closeT' = r.closeT /\ wideT' = r.wideT /\ cover' = r.cover
          /\ muted' = r.muted /\ nav' = r.nav /\ sock' = r.sock /\ pagePic' = r.pagePic
          /\ docWide' = r.docWide /\ audioOn' = r.audioOn /\ session' = r.session /\ susp' = r.susp
          /\ up' = r.up /\ reqs' = r.reqs /\ wide' = r.wide /\ dann' = r.dann /\ envn' = r.envn
          /\ stray' = r.stray

-----------------------------------------------------------------------------
(* The app's code *)

\* updateAudio (A ViewerController.swift:740-750): audible = committed &&
\* active && recentInput; nothing happens if muted already says so; else the
\* view's suspension and the page's audio session type. The script call runs
\* in the view's document now: if voxl's page hasn't committed yet it lands in
\* the blank document, which the page replaces.
Audible(r) == r.committed /\ (r.scene = "active" \/ ~Has("ActiveRule")) /\ r.recent
UpdateAudio(r) ==
  IF ~r.web THEN r
  ELSE LET a == Audible(r)
           m == IF a THEN "no" ELSE "yes"
       IN IF r.muted = m THEN r
          ELSE [r EXCEPT !.muted = m, !.susp = ~a,
                         !.session = IF r.nav = "page" THEN (IF a THEN "playback" ELSE "ambient") ELSE @]

\* input() (:727-731): updateAudio only when back from 5 minutes idle.
Input(r) == LET r1 == [r EXCEPT !.recent = TRUE] IN IF r.recent THEN r1 ELSE UpdateAudio(r1)

\* The page in the view goes: its socket closes, and voxl drops the phone's
\* scale request (R server.rs:299-306).
DocGone(r) ==
  LET r1 == IF r.sock \in {"open", "dead"} THEN [r EXCEPT !.reqs[r.dscr] = Drop1(@, "phone")] ELSE r
  IN [r1 EXCEPT !.nav = "none", !.sock = "none", !.pagePic = FALSE, !.docWide = FALSE,
                !.audioOn = FALSE, !.session = "auto"]

\* newWebView (:327-349): the old view suspended and removed (its page goes),
\* a new one suspended (:346), muted = nil (:348). Assumed: the old view is
\* silent from here on.
NewWebView(r) ==
  [DocGone(r) EXCEPT !.web = TRUE, !.susp = Has("FreshSuspend"),
                     !.muted = IF Has("FreshMute") THEN "nil" ELSE @]

\* load() (:351-371): retryLater cleared; a new view if none or the page
\* committed; the flags reset, tooWideLater cancelled; the label unless failing;
\* waitLater (3 s) and helloLater (10 s) armed; the load goes out for the
\* screen asked for, from its Sharp URL if it has one (page, Machines.swift:17).
Load(r) ==
  LET r1 == [r EXCEPT !.retryT = "none"]
      r2 == IF ~r1.web \/ r1.committed THEN NewWebView(r1) ELSE r1
  IN [r2 EXCEPT !.answered = FALSE, !.committed = FALSE, !.hello = FALSE, !.picture = FALSE,
                !.tooWide = FALSE, !.wideT = FALSE, !.cover = IF r2.failing THEN @ ELSE "label",
                !.waitT = TRUE, !.helloT = IF Has("WatchHello") THEN "load" ELSE "off",
                !.nav = "asked", !.dscr = r2.row, !.dsharp = r2.sharp[r2.row]]

\* go(to:) and switched() (:292-307): failing cleared, load().
Switched(r, to) == Load([r EXCEPT !.row = to, !.failing = FALSE])

\* notAnswering (:432-441).
NotAnswering(r) == [r EXCEPT !.failing = TRUE, !.cover = "dim"]

\* closePage (:374-386): the view goes; committed cleared, the connect timers
\* and tooWideLater cancelled; answered, hello, picture, failing, tooWide, muted kept.
ClosePage(r) ==
  IF ~r.web THEN r
  ELSE [DocGone(r) EXCEPT !.web = FALSE, !.committed = FALSE, !.waitT = FALSE, !.retryT = "none",
                          !.helloT = "off", !.wideT = FALSE]

\* The page's messages (:608-700). hello (:618-651): tooWide arms
\* tooWideLater, which puts up the Full cover 2 s later if tooWide still holds
\* (every connection first hears Full until the page's Sharp request lands); a
\* playable hello cancels it and takes the cover away once the picture played
\* (:644-645), and before a frame, since ce88951, takes a Full cover back to
\* the label (coverAction is .sharp, :646-649: only the Full cover has that
\* action, and cover.hide() runs only once the picture played). Without
\* WideWaits, as before eb7470e: the Full cover at once. The hello's
\* keyBar.resend (:650-651) and the blur at the socket's open (:673-679) are
\* keys: PhoneKeys. status closed (:667-672): hello false; since 5e57a1f,
\* tooWideLater cancelled (:670) and the 10 s watch started only if none is
\* pending (:672; its work sets helloLater nil when it runs, :414), so it
\* counts from the first close. Neither is a guard: no rule here tells them
\* from the code before (see the skill's scope). picture (:652-663).
HelloIn(r, w) ==
  [r EXCEPT !.hello = TRUE, !.helloT = "off", !.tooWide = w, !.wideT = w /\ Has("WideWaits"),
            !.cover = IF w THEN (IF Has("WideWaits") THEN @ ELSE "full")
                      ELSE IF r.picture THEN (IF Has("HelloHides") THEN "off" ELSE @)
                      ELSE IF r.cover = "full" /\ Has("HelloSharp") THEN "label"
                      ELSE @]
StatusClosed(r) ==
  [r EXCEPT !.hello = FALSE, !.wideT = FALSE,
            !.helloT = IF Has("WatchHello") /\ r.helloT = "off" THEN "closed" ELSE @]
PictureIn(r) ==
  [r EXCEPT !.picture = TRUE, !.failing = FALSE, !.waitT = FALSE,
            !.cover = IF ~r.tooWide /\ Has("PictureHides") THEN "off" ELSE @]

\* The phone's open socket to its screen closes: voxl drops its scale request.
SockEnds(r) ==
  [StatusClosed(r) EXCEPT !.sock = "closed", !.reqs[r.dscr] = Drop1(@, "phone")]

\* What a screen's capture should be: Full when the latest request is the
\* other viewer's (R server.rs:401-407, 299-306).
WantWide(r, s) == r.reqs[s] # <<>> /\ r.reqs[s][Len(r.reqs[s])] = "other"

-----------------------------------------------------------------------------
Init ==
  \* Launched (viewDidLoad): no view yet, the cover up and black, the scene
  \* about to become active.
  /\ scene = "inactive" /\ recent = FALSE /\ row = 1 /\ web = FALSE /\ dscr = 1 /\ dsharp = FALSE
  \* HasSharp: the screens have Sharp URLs (the desktop viewers' list, or Ask for Sharp earlier).
  /\ sharp = [s \in Screens |-> HasSharp]
  /\ answered = FALSE /\ committed = FALSE /\ hello = FALSE /\ picture = FALSE
  /\ failing = FALSE /\ tooWide = FALSE
  /\ waitT = FALSE /\ retryT = "none" /\ helloT = "off" /\ closeT = FALSE /\ wideT = FALSE
  /\ cover = "label" /\ muted = "nil"
  /\ nav = "none" /\ sock = "none" /\ pagePic = FALSE /\ docWide = FALSE /\ audioOn = FALSE
  /\ session = "auto" /\ susp = FALSE
  /\ up = [s \in Screens |-> TRUE]
  \* StartFull: another viewer has screen 1 on Full when the app starts.
  /\ reqs = [s \in Screens |-> IF StartFull /\ s = 1 THEN <<"other">> ELSE <<>>]
  /\ wide = [s \in Screens |-> StartFull /\ s = 1]
  /\ dann = 0 /\ envn = 0 /\ stray = FALSE

-----------------------------------------------------------------------------
(* Quick steps *)

\* main() starts the AudioContext (R main.ts:189, audio.ts:10-31; the config
\* lets it play without a gesture, A ViewerController.swift:82).
AudioStarts == web /\ nav = "page" /\ ~audioOn /\ scene # "suspended" /\ Set([Now EXCEPT !.audioOn = TRUE])

\* The worker's socket opens (R worker.ts:104-112) and voxl's first message
\* is the hello with the current size (R server.rs:223). On open, a page
\* loaded with ?scale=0.8 asks for it (R main.ts:153-157), which voxl makes
\* its latest request (server.rs:401-407).
\* The hello was sent before the cs was read.
SocketOpens ==
  /\ web /\ nav = "page" /\ sock = "closed" /\ up[dscr] /\ scene # "suspended"
  /\ LET w  == wide[dscr]
         r0 == [Now EXCEPT !.sock = "open", !.docWide = w,
                           !.reqs[dscr] = IF dsharp THEN Append(Drop1(@, "phone"), "phone") ELSE @]
     IN Set(HelloIn(r0, w))

\* voxl's capture follows the latest request within 1 s and sends every
\* viewer a new hello (R mac/capture.rs:261-269, video.rs:302-303,
\* hub.rs:353-362; the worker resets its decoder).
Rebuild(s) ==
  /\ wide[s] # WantWide(Now, s)
  /\ LET w  == ~wide[s]
         r0 == [Now EXCEPT !.wide[s] = w]
     IN Set(IF web /\ nav = "page" /\ sock = "open" /\ dscr = s THEN HelloIn([r0 EXCEPT !.docWide = w], w)
            ELSE r0)

\* voxl answers the load: the response (decidePolicyFor, :566-577) and the
\* commit (didCommit, :529-534) of a new page, its socket connecting. The
\* commit's gotAnswer (:423-430, since 5e57a1f) takes a "isn't answering"
\* cover down; then the sound rule.
Answer ==
  /\ web /\ nav = "asked" /\ up[dscr] /\ scene # "suspended"
  /\ LET r0 == [Now EXCEPT !.answered = TRUE, !.committed = TRUE, !.nav = "page", !.sock = "closed",
                           !.pagePic = FALSE, !.docWide = FALSE, !.audioOn = FALSE, !.session = "auto"]
         r1 == IF r0.failing /\ Has("CommitClearsFailing") THEN [r0 EXCEPT !.failing = FALSE, !.cover = "label"]
               ELSE r0
     IN Set(IF Has("CommitAudio") THEN UpdateAudio(r1) ELSE r1)

\* The 1 s tick (:803-812), when updateAudio has work.
Tick == Has("TickMutes") /\ scene # "suspended" /\ UpdateAudio(Now) # Now /\ Set(UpdateAudio(Now))

\* voxl answers the load quickly, unless SlowAnswer.
QuickAnswer == ~SlowAnswer /\ Answer

Quick == AudioStarts \/ SocketOpens \/ (\E s \in Screens : Rebuild(s)) \/ Tick \/ QuickAnswer

\* No quick step left.
Settled == ~ENABLED Quick

-----------------------------------------------------------------------------
(* Slow steps of the page and voxl *)

\* The load fails (NSURLError, :520-527): retry (:443-450): not answering, a
\* load 3 s later whatever happens.
Fail ==
  /\ web /\ nav = "asked" /\ ~up[dscr] /\ scene # "suspended"
  /\ Set([NotAnswering(Now) EXCEPT !.nav = "none", !.retryT = "always"])

\* The picture plays: voxl's frames reach a visible page (video is off while
\* hidden, R main.ts:108-121) and Page.watch posts picture, once per page
\* (A Page.swift:13-15, 36-38). Assumed: a Full (5120) stream doesn't play here.
Picture ==
  /\ web /\ nav = "page" /\ sock = "open" /\ ~docWide /\ ~pagePic /\ scene \in {"active", "inactive"}
  /\ Set(PictureIn([Now EXCEPT !.pagePic = TRUE]))

-----------------------------------------------------------------------------
(* The app's timers: they fire only once no quick step is left *)

\* The timers of one try keep their order: load() arms waitLater (3 s) and
\* helloLater (10 s) together, a close with no watch pending arms helloLater
\* for 10 s later, and waited arms its retry 7 s after it runs, so waitLater
\* fires first, and the load's helloLater and waited's retry fire together
\* at about 10 s.
\* tooWideLater (2 s) fires after voxl's capture rebuild (within 1 s), so a
\* Sharp request's new hello always cancels it first.
Ticking == Settled /\ scene # "suspended"

\* waited (:396-406).
Waited ==
  /\ waitT /\ Ticking
  /\ Set(IF answered THEN [Now EXCEPT !.waitT = FALSE]
         ELSE LET r == NotAnswering([Now EXCEPT !.waitT = FALSE])
              IN IF retryT = "none" THEN [r EXCEPT !.retryT = "cond"] ELSE r)

\* retryLater (:400-405 or :447). waited's comes after the load's helloLater.
RetryFires ==
  /\ retryT # "none" /\ Ticking /\ (retryT = "always" \/ helloT # "load")
  /\ Set(IF retryT = "cond" /\ answered THEN [Now EXCEPT !.retryT = "none"] ELSE Load(Now))

\* helloLater (:412-418; helloLater nil, :414; it also waits while
\* needsPassword, :415, not modeled), after waitLater; with waited's retry
\* due at once, both.
HelloFires ==
  /\ helloT # "off" /\ ~waitT /\ Ticking
  /\ LET r == [Now EXCEPT !.helloT = "off"]
     IN Set(IF ~hello /\ answered THEN Load(r)
            ELSE IF helloT = "load" /\ retryT = "cond" /\ ~answered THEN Load(r)
            ELSE r)

\* tooWideLater (:637-641): the Full cover if the last hello is still too wide.
TooWideFires ==
  /\ wideT /\ Ticking
  /\ Set([Now EXCEPT !.wideT = FALSE, !.cover = IF tooWide THEN "full" ELSE @])

\* closeLater, or the background task's expiry (:779-788): closePage.
CloseFires == closeT /\ scene = "background" /\ Settled /\ Set(ClosePage([Now EXCEPT !.closeT = FALSE]))

-----------------------------------------------------------------------------
(* The scene: Dan and iOS *)

Dan(a) == a \in DanActs /\ dann < DanMax

\* sceneDidBecomeActive -> becameActive (:758-767): active, input(), the
\* close cancelled, load() if there is no view, updateAudio.
BecomeActive ==
  /\ scene = "inactive"
  /\ LET r0 == Input([Now EXCEPT !.scene = "active", !.closeT = FALSE])
         r1 == IF ~r0.web THEN Load(r0) ELSE r0
     IN Set(UpdateAudio(r1))

\* sceneWillResignActive -> resignedActive (:769-775).
Resign ==
  /\ Dan("leave") /\ scene = "active"
  /\ LET r0 == [Now EXCEPT !.scene = "inactive", !.dann = @ + 1]
     IN Set(IF Has("ResignMutes") THEN UpdateAudio(r0) ELSE r0)

\* sceneDidEnterBackground -> enteredBackground (:777-790).
Background == scene = "inactive" /\ "leave" \in DanActs /\ Set([Now EXCEPT !.scene = "background", !.closeT = TRUE])

\* iOS suspends the app once its background task is over: after closePage
\* (its expiry handler closes the page first).
Suspend == scene = "background" /\ ~web /\ Set([Now EXCEPT !.scene = "suspended"])

\* sceneWillEnterForeground -> enteringForeground (:792-795).
Foreground == scene \in {"background", "suspended"} /\ Set([Now EXCEPT !.scene = "inactive", !.closeT = FALSE])

\* A touch or a key in the app (ViewerWindow.sendEvent, App.swift:37-60). A
\* touch also moves the Mac's pointer, so a dead socket's send fails and it
\* closes.
Touch ==
  /\ Dan("touch") /\ scene = "active"
  /\ LET r0 == Input([Now EXCEPT !.dann = @ + 1])
     IN Set(IF sock = "dead" THEN SockEnds(r0) ELSE r0)

\* Five minutes pass with no touch or key.
Idle == "idle" \in DanActs /\ recent /\ Set([Now EXCEPT !.recent = FALSE])

\* A tab or F1/F2: the other screen.
SwitchScreen ==
  /\ Dan("switch") /\ scene = "active"
  /\ Set(Switched(Input([Now EXCEPT !.dann = @ + 1]), Other(row)))

\* The cover's button (coverButton, :458-476) does what the cover offers:
\* "Show <other>" the other screen; "Ask for Sharp" gives the screen its Sharp
\* URL and loads. Without CoverAction, as before a302a7d: the other screen if
\* failing, else Sharp and load. The ghost: a button that didn't say
\* "Show <other>" switched.
CoverButton ==
  /\ Dan("cover") /\ scene = "active" /\ cover \in {"dim", "full"}
  /\ LET r0     == Input([Now EXCEPT !.dann = @ + 1])
         toOther == IF Has("CoverAction") THEN cover = "dim" ELSE failing
     IN Set(IF toOther THEN [Switched(r0, Other(row)) EXCEPT !.stray = stray \/ cover # "dim"]
            ELSE Load([r0 EXCEPT !.sharp[row] = TRUE]))

\* More > Reconnect (:117-120).
Reconnect ==
  /\ Dan("reconnect") /\ scene = "active"
  /\ Set(Load([Input([Now EXCEPT !.dann = @ + 1]) EXCEPT !.failing = FALSE]))

-----------------------------------------------------------------------------
(* The world *)

Ev(e) == e \in Events /\ envn < EnvMax

\* A screen's voxl stops: its page's socket closes; it starts again fresh
\* (no scale requests, the startup size, which isn't Full).
Down(s) ==
  /\ Ev("down") /\ up[s]
  /\ LET r0 == [Now EXCEPT !.up[s] = FALSE, !.wide[s] = FALSE, !.reqs[s] = <<>>, !.envn = @ + 1]
     IN Set(IF web /\ nav = "page" /\ dscr = s /\ sock \in {"open", "dead"} THEN SockEnds(r0) ELSE r0)
VoxlUp(s) == ~up[s] /\ Set([Now EXCEPT !.up[s] = TRUE])

\* The page's socket closes, voxl still up.
Drop == Ev("drop") /\ web /\ nav = "page" /\ sock = "open" /\ Set(SockEnds([Now EXCEPT !.envn = @ + 1]))

\* The worker's reconnect hangs.
Hang == Ev("hang") /\ web /\ nav = "page" /\ sock = "closed" /\ Set([Now EXCEPT !.sock = "hung", !.envn = @ + 1])

\* The open socket goes silent: no close, no frames, no pings.
Dead == Ev("dead") /\ web /\ nav = "page" /\ sock = "open" /\ Set([Now EXCEPT !.sock = "dead", !.envn = @ + 1])

\* The page's web process ends (webViewWebContentProcessDidTerminate,
\* :536-540): load().
Crash == Ev("crash") /\ web /\ scene # "suspended" /\ Set(Load([DocGone(Now) EXCEPT !.envn = @ + 1]))

\* Another viewer asks screen s for Full (cs,1: its request is the latest),
\* and later leaves (its request goes; the one before it, or the startup
\* size, applies). OtherLeaves: it always does.
OtherFull(s) == Ev("full") /\ Set([Now EXCEPT !.reqs[s] = Append(Drop1(@, "other"), "other"), !.envn = @ + 1])
OtherGone(s) == "other" \in {reqs[s][i] : i \in DOMAIN reqs[s]} /\ Set([Now EXCEPT !.reqs[s] = Drop1(@, "other")])

-----------------------------------------------------------------------------
Done == Settled /\ UNCHANGED vars

DanStep == BecomeActive \/ Resign \/ Background \/ Suspend \/ Foreground \/ Touch \/ Idle
           \/ SwitchScreen \/ CoverButton \/ Reconnect
World   == \/ \E s \in Screens : Down(s) \/ VoxlUp(s) \/ OtherFull(s) \/ OtherGone(s)
           \/ Drop \/ Hang \/ Dead \/ Crash
Slow    == Answer \/ Fail \/ Picture
Timers  == Waited \/ RetryFires \/ HelloFires \/ TooWideFires \/ CloseFires

Next == DanStep \/ World \/ Quick \/ Slow \/ Timers \/ Done

\* voxl, the page and the app's timers do what they are due to; Dan and the
\* world need not.
Fair == /\ WF_vars(AudioStarts) /\ WF_vars(SocketOpens) /\ \A s \in Screens : WF_vars(Rebuild(s))
        /\ WF_vars(Tick) /\ WF_vars(Answer) /\ WF_vars(Fail) /\ WF_vars(Picture)
        /\ WF_vars(Waited) /\ WF_vars(RetryFires) /\ WF_vars(HelloFires) /\ WF_vars(TooWideFires)
        /\ WF_vars(CloseFires)
        /\ OtherLeaves => \A s \in Screens : WF_vars(OtherGone(s))

Spec == Init /\ [][Next]_vars /\ Fair

-----------------------------------------------------------------------------
(* Dan's promises *)

\* The page's sound reaches the speaker, with the silent switch off.
Heard == web /\ audioOn /\ ~susp

\* P1 "Sound plays only where I am", first half: once settled, the page is
\* heard only while the app is in front and Dan touched or typed in it within
\* 5 minutes.
QuietAway == Settled => (Heard => scene = "active" /\ recent)

\* P1, second half: while that holds, the sound plays, also with the silent
\* switch on: the view isn't suspended and the page's session is playback.
PlaysWhereIAm == Settled => (web /\ audioOn /\ scene = "active" /\ recent => ~susp /\ session = "playback")

\* The picture plays: voxl's page, its socket open, frames at a size it plays.
Playing == web /\ nav = "page" /\ sock = "open" /\ pagePic /\ ~docWide /\ scene \in {"active", "inactive"}
Shown   == Playing /\ cover = "off"

\* P2 "A screen always comes back by itself": once the world stops changing,
\* with the screen's voxl answering and the app in front, the picture ends up
\* playing with no cover, with no help from Dan.
Calm      == up[row] /\ scene = "active"
ComesBack == <>[]Calm => <>[]Shown

\* P2, "... and never switches screens on its own": the cover's button switches
\* only when it says it will.
NeverSwitchesByItself == ~stray

\* A reload is coming (what "Trying again every 3 s" promises).
WillRetry == \/ retryT = "always"
             \/ retryT = "cond" /\ ~answered
             \/ waitT /\ ~answered
             \/ helloT # "off" /\ answered /\ ~hello

\* What the cover's button does while the Full cover shows: asks for Sharp,
\* or (before a302a7d, failing) switches screens.
AsksSharp == IF Has("CoverAction") THEN TRUE ELSE ~failing

\* P2, "... the cover's text and button match the real state": once settled,
\* with the app in front: no cover only over a playing picture (or voxl's own
\* "Reconnecting…" on it); the screen's name only while it isn't playing;
\* "isn't answering. Trying again" only while it has no hello and a reload is
\* coming; "Another viewer asked for Full" only while the last hello says Full,
\* and its "Ask for Sharp" button then asks for Sharp (it doesn't switch).
\* Not while tooWideLater runs: the app's designed 2 s wait on a Full hello.
CoverTellsTruth ==
  Settled /\ scene = "active" /\ ~wideT =>
    CASE cover = "off"   -> Playing \/ (pagePic /\ sock \in {"closed", "hung"})
      [] cover = "label" -> ~Playing
      [] cover = "dim"   -> ~hello /\ WillRetry
      [] OTHER           -> tooWide /\ AsksSharp

TypeOK ==
  /\ scene \in {"active", "inactive", "background", "suspended"} /\ recent \in BOOLEAN
  /\ row \in Screens /\ web \in BOOLEAN /\ dscr \in Screens /\ dsharp \in BOOLEAN
  /\ sharp \in [Screens -> BOOLEAN]
  /\ {answered, committed, hello, picture, failing, tooWide} \subseteq BOOLEAN
  /\ waitT \in BOOLEAN /\ retryT \in {"none", "cond", "always"} /\ helloT \in {"off", "load", "closed"}
  /\ closeT \in BOOLEAN /\ wideT \in BOOLEAN
  /\ cover \in {"off", "label", "dim", "full"} /\ muted \in {"nil", "yes", "no"}
  /\ nav \in {"none", "asked", "page"} /\ sock \in {"none", "closed", "open", "hung", "dead"}
  /\ {pagePic, docWide, audioOn, susp} \subseteq BOOLEAN /\ session \in {"auto", "playback", "ambient"}
  /\ up \in [Screens -> BOOLEAN] /\ wide \in [Screens -> BOOLEAN]
  /\ \A s \in Screens : reqs[s] \in {<<>>, <<"phone">>, <<"other">>, <<"phone", "other">>, <<"other", "phone">>}
  /\ stray \in BOOLEAN
=============================================================================
