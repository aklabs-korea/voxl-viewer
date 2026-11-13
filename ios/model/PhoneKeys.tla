------------------------------- MODULE PhoneKeys -------------------------------
(***************************************************************************)
(* Dan's keys, clicks and key-bar modifiers from the iPhone/iPad app to a  *)
(* Mac screen: the app (ViewerController, Pointer, KeyBar), the scripts it *)
(* injects into voxl's page (Page.input, Page.watch), voxl's page          *)
(* (keyboard.ts, pointer.ts), the worker's socket and the voxl process of  *)
(* each screen, whose injector holds keys and buttons on the Mac.          *)
(*                                                                         *)
(* Code (the coverage record and sync point are in                         *)
(* .claude/skills/voxl-ios-model/SKILL.md):                                *)
(*   A = ios/Voxl in this repo: ViewerController.swift, Pointer.swift,     *)
(*       KeyBar.swift, Page.swift, App.swift.                              *)
(*   R = voxl 0.3.4: web/src/client/keyboard.ts, pointer.ts, main.ts,      *)
(*       web/src/worker.ts, src/server.rs, src/mac/input.rs.               *)
(*                                                                         *)
(* Dan's inputs: letter keys from a hardware keyboard or the iPhone        *)
(* keyboard ("a", "b": a press and its release are separate steps, so two  *)
(* can overlap), a tap that clicks, held drags, up to one of each kind at  *)
(* once ("pad": a hold on the pad; "picHold": a still hold on the picture  *)
(* in Trackpad; "picPan": a drag on the picture in Direct; "pointer": an   *)
(* iPad trackpad or mouse dragging on the picture), the Trackpad/Direct    *)
(* switch, the key bar's ⌘, its Esc, its Mac keys (a chord: ⌘Space, ⌘Tab, *)
(* ⌃↑, ⌘F3, and Paste's ⌘V) and its keyboard button. ⌘ stands for all     *)
(* four bar modifiers: Page.input treats them alike. Every drag shares     *)
(* Pointer's one dragging flag.                                            *)
(*                                                                         *)
(* Steps. One step is one main-thread job of the app or the page: a        *)
(* script call the app makes runs in the document the view holds at that   *)
(* moment (evaluateJavaScript and key events go to the page in order), and *)
(* what the page sends reaches its voxl process in the same step if the    *)
(* worker's socket is open (worker.ts:97-99 drops it otherwise). The       *)
(* page's 'armed' and 'status' messages reach the app in the same step.    *)
(* Quick steps (the commit of a new page, the worker's 1 s reconnect, the  *)
(* app's handling of the socket's open, voxl's hello on a new connection)  *)
(* can interleave with Dan; the promises are checked once no quick step is *)
(* left (Settled). Off removes guards, to show each one matters.           *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

\* Chords: the bar's Mac keys Dan may pick. KbLoading: Dan may tap the bar's
\* keyboard button before the page's picture gives the view the keys.
CONSTANTS Letters, Presses, Clicks, Drags, Kinds, Flips, Arms, Taps, Chords, Overlap, ArmLoading, KbLoading,
          Events, EnvMax, Off

Screens    == {1, 2}
MacKeys    == {"a", "b", "Cmd"}     \* Injector.pressed (letters) and mods (⌘), R mac/input.rs:160-164
None       == "none"
Free       == {}                    \* a Mac key or button no input holds
\* leave: Dan leaves the app (resign; then background, the 30 s close, back).
\* switch: Dan picks the other screen (a tab, F1/F2). reload: load() without
\* release() (retry, the 10 s hello watch, the web process ending, Reconnect,
\* the cover's Ask for Sharp). loud: the socket closes and voxl sees it.
\* silent: the socket closes on the phone and voxl doesn't see it until TCP
\* gives up (Wi-Fi to cellular, a dead path). It also stands for a socket
\* that goes silent on both ends (packets dropped, no FIN): for voxl the same
\* (nothing more arrives, the connection stays open with what it holds), and
\* what the phone sends after it is lost either way; such a socket reconnects
\* only through a fresh page (reload, switch, leave), and the promises are
\* checked once the phone has a connected page again (see Settled).
EventNames == {"leave", "switch", "reload", "loud", "silent"}
Guards     == {"Blur", "Hidden", "Bye", "Disarm", "BarClear", "ArmedMsg", "KeyUpLift", "ClickLift",
               "HoldPress", "ButtonUp", "OpenRelease", "LetGoKey", "LetGoClick", "LoadClearsBar",
               "ModeUp", "HoldEndUp", "TapLetGo", "Resend", "ChordDisarm", "ChordBarClear"}
DragKinds  == {"pad", "picHold", "picPan", "pointer"}
NoHold     == [code |-> None, mods |-> {}]

ASSUME /\ Letters \subseteq {"a", "b"} /\ Events \subseteq EventNames /\ Off \subseteq Guards
       /\ {Presses, Clicks, Drags, Flips, Arms, Taps, Chords, EnvMax} \subseteq Nat /\ Overlap \in BOOLEAN
       /\ ArmLoading \in BOOLEAN /\ KbLoading \in BOOLEAN /\ Kinds \subseteq DragKinds

Has(g)   == g \notin Off
Other(s) == 3 - s

VARIABLES
  hw,        \* the letters Dan holds down
  fingers,   \* the drags Dan holds (DragKinds)
  used,      \* Dan's actions so far, for the bounds
  envn,      \* world events so far
  scene,     \* "active", "inactive", "background" (sceneDidBecomeActive and the rest, A App.swift:25-28)
  row,       \* the screen on show
  mode,      \* Pointer.mode: "trackpad" or "direct" (A Pointer.swift:18-26)
  dragging,  \* Pointer.dragging, one flag for every drag (A Pointer.swift:46)
  bar,       \* KeyBar.armed: the lit modifiers (A KeyBar.swift:11, 171-181)
  doc,       \* the web view's document: "none" (closePage), "blank" (loading), "page" (voxl's page)
  focused,   \* the web view is the first responder, so Dan's keys reach the page's #kbd: from
             \* focusKeys (A ViewerController.swift:709-715), at the page's first picture (:652-657)
             \* or the key bar's keyboard button (:714-717); a web view load() makes has none
             \* (:355, 327-349), one it loads again (no commit since) keeps what it had
  sock,      \* the worker's socket: "closed" (it reconnects in 1 s) or "open"
  opened,    \* the app has handled this socket's status open (A ViewerController.swift:676-682)
  hello,     \* the app's hello: voxl's hello on this connection reached it (A ViewerController.swift:41,
             \* 619; cleared by load() :360 and a close :668)
  armed,     \* Page.input's armed (A Page.swift:80)
  hold,      \* Page.input's holding: [code, mods], code None when null (A Page.swift:80, 108)
  clickMods, \* Page.input's clickMods ({} when null; never set to []) (A Page.swift:115, 124)
  down,      \* keyboard.ts's down: the codes it pressed ("Cmd" is MetaLeft) (R keyboard.ts:121)
  mac,       \* [Screens -> [MacKeys -> the inputs it is held for]]: what that screen's
             \* voxl has macOS hold (Free: not held). Inputs: a letter, "drag", "tap".
  btn,       \* [Screens -> the inputs it is held for]: Injector.buttons[1] (left button)
  stale,     \* [Screens -> BOOLEAN]: voxl still has a connection whose phone end is gone
  fresh,     \* (ghost) Dan changed the bar and has made no key or click since
  bad        \* (ghost) "extra", "missing": a key or click reached the Mac with modifiers
             \* other than the ones the bar promised it

vars == <<hw, fingers, used, envn, scene, row, mode, dragging, bar, doc, focused, sock, opened, hello,
          armed, hold, clickMods, down, mac, btn, stale, fresh, bad>>

\* All variables as one record, so the app's, the page's and voxl's code can be
\* applied in turn within one step.
Now == [hw |-> hw, fingers |-> fingers, used |-> used, envn |-> envn, scene |-> scene, row |-> row,
        mode |-> mode, dragging |-> dragging, bar |-> bar, doc |-> doc, focused |-> focused,
        sock |-> sock, opened |-> opened, hello |-> hello,
        armed |-> armed, hold |-> hold, clickMods |-> clickMods,
        down |-> down, mac |-> mac, btn |-> btn, stale |-> stale, fresh |-> fresh, bad |-> bad]
Set(r) == /\ hw' = r.hw /\ fingers' = r.fingers /\ used' = r.used /\ envn' = r.envn
          /\ scene' = r.scene /\ row' = r.row /\ mode' = r.mode /\ dragging' = r.dragging
          /\ bar' = r.bar /\ doc' = r.doc /\ focused' = r.focused /\ sock' = r.sock
          /\ opened' = r.opened /\ hello' = r.hello
          /\ armed' = r.armed /\ hold' = r.hold
          /\ clickMods' = r.clickMods /\ down' = r.down /\ mac' = r.mac /\ btn' = r.btn
          /\ stale' = r.stale /\ fresh' = r.fresh /\ bad' = r.bad

-----------------------------------------------------------------------------
(* voxl's process of a screen (R server.rs:261-308, 332-384; mac/input.rs) *)

Flags(r, s) == IF r.mac[s]["Cmd"] # Free THEN {"Cmd"} ELSE {}

\* macOS acts on a key or click with the injector's held modifiers
\* (self.flags(), R mac/input.rs:175-177, 205, 220); the ghost compares them
\* with what the bar promised that key or click.
Judge(r, s, want) ==
  [r EXCEPT !.bad = @ \cup (IF Flags(r, s) \ want # {} THEN {"extra"} ELSE {})
                      \cup (IF want \ Flags(r, s) # {} THEN {"missing"} ELSE {})]

\* release_all (R mac/input.rs:420-435): every key, modifier and button up.
ReleaseAll(r, s) == [r EXCEPT !.mac[s] = [m \in MacKeys |-> Free], !.btn[s] = Free]

K(m, dn, src, want) == [t |-> "k", m |-> m, dn |-> dn, src |-> src, want |-> want]
B(dn, src, want)    == [t |-> "b", m |-> None, dn |-> dn, src |-> src, want |-> want]
R                   == [t |-> "r", m |-> None, dn |-> FALSE, src |-> None, want |-> {}]

\* One message of the page, handled by screen s's server (R server.rs:261-289,
\* 329-381) and its input thread (one channel per process, in order). k
\* (mac/input.rs:340-418): ⌘ is
\* a flags change, posted only when it changes mods (:341-359); a letter
\* already pressed is posted again as an autorepeat (:367-371), else pressed;
\* an up is posted only for a pressed key (:361-365). Esc and a chord's key
\* are pressed and released at once (voxlTap, voxlChord). b (:259-287): a
\* down or up that matches the button's state is dropped. r (server.rs:384):
\* release_all.
Post(r, s, x) ==
  CASE x.t = "k" /\ x.m = "Cmd" ->
         IF ~x.dn THEN [r EXCEPT !.mac[s]["Cmd"] = Free]
         ELSE [r EXCEPT !.mac[s]["Cmd"] = @ \cup {x.src}]
    [] x.t = "k" /\ x.m \in {"esc", "chord"} -> IF x.dn THEN Judge(r, s, x.want) ELSE r
    [] x.t = "k" ->
         IF ~x.dn THEN [r EXCEPT !.mac[s][x.m] = Free]
         ELSE Judge([r EXCEPT !.mac[s][x.m] = @ \cup {x.src}], s, x.want)
    [] x.t = "b" ->
         IF ~x.dn THEN [r EXCEPT !.btn[s] = Free]
         ELSE IF r.btn[s] = Free THEN Judge([r EXCEPT !.btn[s] = {x.src}], s, x.want)
              ELSE [r EXCEPT !.btn[s] = @ \cup {x.src}]
    [] OTHER -> ReleaseAll(r, s)

-----------------------------------------------------------------------------
(* voxl's page *)

\* app.send -> the worker's send (R main.ts:61-63, worker.ts:97-99, 404-406):
\* dropped unless the socket is open.
Send(r, x) == IF r.doc = "page" /\ r.sock = "open" THEN Post(r, r.row, x) ELSE r

\* keyboard.ts: press (R keyboard.ts:127-130, 187-208), release (:135-140:
\* an up only for a code in down), releaseAll (:141-145, on window blur :285).
\* Latin letters and the modifiers: the Korean keyboard's mirror (:146-178)
\* has nothing to flush for them.
KbdDown(r, c, src, want) == Send([r EXCEPT !.down = @ \cup {c}], K(c, TRUE, src, want))
KbdUp(r, c)              == IF c \in r.down THEN Send([r EXCEPT !.down = @ \ {c}], K(c, FALSE, None, {}))
                            ELSE r
KbdReleaseAll(r)         == Send([r EXCEPT !.down = {}], R)

\* Page.input (A Page.swift:74-160). disarm (:87) posts 'armed' [] and the app
\* clears the bar (A ViewerController.swift:691-692). press and lift (:85-86)
\* dispatch the modifiers' keydowns and keyups on #kbd, into keyboard.ts.
Disarm(r)           == IF r.armed # {} THEN [r EXCEPT !.armed = {}, !.bar = IF Has("ArmedMsg") THEN {} ELSE @]
                       ELSE r
PressMods(r, m, src) == IF "Cmd" \in m THEN KbdDown(r, "Cmd", src, {}) ELSE r
LiftMods(r, m)       == IF "Cmd" \in m THEN KbdUp(r, "Cmd") ELSE r

\* letGo (:101): holding's modifiers up, holding null.
LetGo(r) == IF r.hold.code = None THEN r ELSE [LiftMods(r, r.hold.mods) EXCEPT !.hold = NoHold]
\* A trusted keydown (:104-109; a modifier key returns first, :103, 105: not
\* modeled, Dan's keys are letters): another key lets go of holding first;
\* while armed, holding, disarm, the modifiers go down; then keyboard.ts
\* presses the key (its listener is on #kbd, after the capture listener on
\* document), and prevents its default (R keyboard.ts:201), so no
\* beforeinput follows: the beforeinput disarm (:111) is for text with no key,
\* not modeled.
KeyIn(r, k, want) ==
  LET r0 == IF r.hold.code # None /\ r.hold.code # k /\ Has("LetGoKey") THEN LetGo(r) ELSE r
      r1 == IF r0.armed = {} THEN r0
            ELSE LET m == r0.armed
                     r2 == Disarm([r0 EXCEPT !.hold = [code |-> k, mods |-> m]])
                 IN IF Has("HoldPress") THEN PressMods(r2, m, k) ELSE r2
  IN KbdDown(r1, k, k, want)
\* The keyup: keyboard.ts releases the key (#kbd, target phase), then the
\* document's listener lifts holding's modifiers (:112-114, bubble phase).
KeyOut(r, k) ==
  LET r1 == KbdUp(r, k)
  IN IF r1.hold.code # k THEN r1
     ELSE LET r2 == IF Has("KeyUpLift") THEN LiftMods(r1, r1.hold.mods) ELSE r1
          IN [r2 EXCEPT !.hold = NoHold]
\* voxlMouse('down') (:122-125): let go of holding, clickMods, disarm, press;
\* pointerdown sends b,1,1 (R pointer.ts:62-76). voxlMouse('up') (:126-129):
\* pointerup sends b,1,0 (R pointer.ts:77-85), then lift.
MouseDown(r, src, want) ==
  LET r0 == IF Has("LetGoClick") THEN LetGo(r) ELSE r
      r1 == IF r0.armed = {} THEN r0
            ELSE LET m == r0.armed IN PressMods(Disarm([r0 EXCEPT !.clickMods = m]), m, src)
  IN Send(r1, B(TRUE, src, want))
MouseUp(r) ==
  LET r1 == IF Has("ButtonUp") THEN Send(r, B(FALSE, None, {})) ELSE r
  IN IF r1.clickMods = {} THEN r1
     ELSE LET r2 == IF Has("ClickLift") THEN LiftMods(r1, r1.clickMods) ELSE r1
          IN [r2 EXCEPT !.clickMods = {}]
\* voxlTap (:89-93), the bar's Esc: let go of holding (:90, since ce88951),
\* armed, disarm, press, Esc down and up, lift.
VoxlTap(r, want) ==
  LET r0 == IF Has("TapLetGo") THEN LetGo(r) ELSE r
      m  == r0.armed
      r1 == PressMods(Disarm(r0), m, "tap")
  IN LiftMods(Send(r1, K("esc", TRUE, "tap", want)), m)
\* voxlChord (:95-99), a Mac key from the bar or Paste's ⌘V: let go of
\* holding; since 5e57a1f its own modifiers and the armed ones, disarm; press,
\* the key down and up, lift. Its own modifier is ⌘ here, and ⌘ stands for
\* all four, so the armed ones add nothing: only the disarm shows.
VoxlChord(r, want) ==
  LET r0 == LetGo(r)
      r1 == IF Has("ChordDisarm") THEN Disarm(r0) ELSE r0
      r2 == PressMods(r1, {"Cmd"}, "tap")
  IN LiftMods(Send(r2, K("chord", TRUE, "tap", want)), {"Cmd"})
\* voxlRelease (:150-151 wrapping :53): disarm, holding and clickMods null,
\* then the window blur that keyboard.ts maps to releaseAll.
VoxlRelease(r) ==
  LET r1 == IF Has("Disarm") THEN [Disarm(r) EXCEPT !.hold = NoHold, !.clickMods = {}] ELSE r
  IN IF Has("Blur") THEN KbdReleaseAll(r1) ELSE r1

-----------------------------------------------------------------------------
(* The app *)

\* release() (A ViewerController.swift:723-726): voxlRelease in the page, the
\* bar's lights off.
Release(r) ==
  LET r1 == IF r.doc = "page" THEN VoxlRelease(r) ELSE r
  IN IF Has("BarClear") THEN [r1 EXCEPT !.bar = {}] ELSE r1

\* The page in the view goes (newWebView :327-334, closePage :374-386): the
\* view leaves the window, so the page is hidden and sends r (R main.ts:
\* 118-121); then it closes and its voxl releases all (R server.rs:290-294).
\* Assumed: both reach voxl before a new page's first message (that needs a
\* commit and a socket first).
Teardown(r) ==
  IF r.doc = "page" /\ r.sock = "open"
    THEN LET r1 == IF Has("Hidden") THEN Post(r, r.row, R) ELSE r
         IN IF Has("Bye") THEN ReleaseAll(r1, r.row) ELSE r1
    ELSE r
NewDoc(r, d) == [r EXCEPT !.doc = d, !.sock = "closed", !.opened = FALSE, !.armed = {}, !.hold = NoHold,
                          !.clickMods = {}, !.down = {}]
\* load() (:351-371): a fresh web view if the page committed (or none, :355),
\* loading; hello false (:360); the bar's lights off (:365). A fresh view has
\* no keyboard focus; one kept (still loading, no commit since its load)
\* stays the first responder if the keyboard button made it one (it has had
\* no picture).
Load(r) == [NewDoc(Teardown(r), "blank") EXCEPT !.hello = FALSE,
                                                !.focused = (r.doc = "blank" /\ r.focused),
                                                !.bar = IF Has("LoadClearsBar") THEN {} ELSE @]

\* The app's up (send "up", Pointer.swift:266-272) into the page.
SendUp(r) == LET r1 == [r EXCEPT !.dragging = FALSE] IN IF r.doc = "page" THEN MouseUp(r1) ELSE r1

\* Drag g ends (Pointer.swift:108-121, 174-212), read with the mode now: a hold
\* sends up if dragging, in either mode (:197-199; before a302a7d its mode
\* guard came first: none on the picture in Direct); a Direct pan on the
\* picture sends up in its default branch (:175-177), and in Trackpad it is a
\* cursor move (:181-187); an iPad pointer drag sends up (:107-109).
EndDrag(r, g) ==
  LET ups == CASE g = "picHold" -> Has("HoldEndUp") \/ r.mode = "trackpad"
               [] g = "picPan"  -> r.mode = "direct"
               [] OTHER         -> TRUE
      r1  == [r EXCEPT !.fingers = @ \ {g}]
  IN IF ups /\ r.dragging THEN SendUp(r1) ELSE r1

\* Every drag ends (iOS cancels the touches), in a fixed order.
EndAll(r) ==
  LET e1 == IF "pad" \in r.fingers THEN EndDrag(r, "pad") ELSE r
      e2 == IF "picHold" \in e1.fingers THEN EndDrag(e1, "picHold") ELSE e1
      e3 == IF "picPan" \in e2.fingers THEN EndDrag(e2, "picPan") ELSE e2
  IN IF "pointer" \in e3.fingers THEN EndDrag(e3, "pointer") ELSE e3

-----------------------------------------------------------------------------
Init ==
  \* The app in front on screen 1, its page connected (hello and picture
  \* handled, so the view has the keys), nothing held.
  /\ hw = {} /\ fingers = {}
  /\ used = [press |-> [k \in Letters |-> 0], click |-> 0, drag |-> 0, flip |-> 0, arm |-> 0, tap |-> 0,
             chord |-> 0]
  /\ envn = 0
  /\ scene = "active" /\ row = 1 /\ mode = "trackpad" /\ dragging = FALSE /\ bar = {}
  /\ doc = "page" /\ focused = TRUE /\ sock = "open" /\ opened = TRUE /\ hello = TRUE
  /\ armed = {} /\ hold = NoHold /\ clickMods = {} /\ down = {}
  /\ mac = [s \in Screens |-> [m \in MacKeys |-> Free]] /\ btn = [s \in Screens |-> Free]
  /\ stale = [s \in Screens |-> FALSE]
  /\ fresh = FALSE /\ bad = {}

-----------------------------------------------------------------------------
(* Dan *)

\* What the bar promises Dan's next key or click: the lit modifiers, if he
\* changed the bar since his last key or click.
Want == IF fresh THEN bar ELSE {}

\* Overlap: Dan may start a key, click or drag while he still holds another
\* (fast typing on a hardware keyboard rolls over). Otherwise he holds one at
\* a time, as the iPhone keyboard does (keydown and keyup at once).
Free1 == Overlap \/ (hw = {} /\ fingers = {})

\* Dan presses a letter. With the app in front it reaches the page's #kbd
\* once the view has the keyboard focus (focusKeys, :706-712, at the page's
\* first picture or from the bar's keyboard button); before that it goes
\* nowhere.
KeyDown(k) ==
  /\ k \in Letters /\ k \notin hw /\ used.press[k] < Presses /\ scene = "active" /\ Free1
  /\ LET r0 == [Now EXCEPT !.hw = @ \cup {k}, !.used.press[k] = @ + 1]
     IN Set(IF doc = "page" /\ focused THEN [KeyIn(r0, k, Want) EXCEPT !.fresh = FALSE] ELSE r0)

\* Dan lets go. The keyup reaches the page only with the app in front and
\* the view focused.
KeyUp(k) ==
  /\ k \in hw
  /\ LET r0 == [Now EXCEPT !.hw = @ \ {k}]
     IN Set(IF scene = "active" /\ doc = "page" /\ focused THEN KeyOut(r0, k) ELSE r0)

\* A tap or an iPad pointer click: click(0) runs voxlMouse down then up
\* (Pointer.swift:102-106, 214-224, 266-278).
Click ==
  /\ scene = "active" /\ used.click < Clicks /\ Free1
  /\ LET r0 == [Now EXCEPT !.used.click = @ + 1]
     IN Set(IF doc = "page" THEN [MouseUp(MouseDown(r0, "tap", Want)) EXCEPT !.fresh = FALSE] ELSE r0)

\* A hold (.began, :192-196: not on the picture in Direct), a Direct pan on
\* the picture (.began, :169-173) or an iPad pointer drag (.began, :102-105):
\* down, dragging.
DragStart(g) ==
  /\ scene = "active" /\ g \in Kinds /\ g \notin fingers /\ used.drag < Drags /\ Free1
  /\ \/ g \in {"pad", "pointer"}
     \/ g = "picHold" /\ mode = "trackpad"
     \/ g = "picPan" /\ mode = "direct"
  /\ LET r0 == [Now EXCEPT !.fingers = @ \cup {g}, !.dragging = TRUE, !.used.drag = @ + 1]
     IN Set(IF doc = "page" THEN [MouseDown(r0, "drag", Want) EXCEPT !.fresh = FALSE] ELSE r0)

\* Dan lifts a finger, or lets go of the trackpad's button.
DragEnd(g) == g \in fingers /\ Set(EndDrag(Now, g))

\* The Trackpad/Direct control on the pad (A ViewerController.swift:137-140),
\* with another finger while one drags, or between drags. mode's didSet sends
\* up if dragging (A Pointer.swift:18-26).
ModeFlip ==
  /\ scene = "active" /\ used.flip < Flips
  /\ LET r0 == [Now EXCEPT !.mode = IF @ = "trackpad" THEN "direct" ELSE "trackpad", !.used.flip = @ + 1]
     IN Set(IF dragging /\ Has("ModeUp") THEN SendUp(r0) ELSE r0)

\* Dan taps ⌘ on the bar: toggle (A KeyBar.swift:157-162) lights it and arms the
\* page. ArmLoading: also while a page loads under the cover (the bar stays
\* usable); otherwise only once voxl's page is in the view.
BarToggle ==
  /\ scene = "active" /\ used.arm < Arms /\ (ArmLoading \/ doc = "page")
  /\ LET nb == IF "Cmd" \in bar THEN {} ELSE {"Cmd"}
         r0 == [Now EXCEPT !.bar = nb, !.fresh = TRUE, !.used.arm = @ + 1]
     IN Set(IF doc = "page" THEN [r0 EXCEPT !.armed = nb] ELSE r0)

\* Dan taps the bar's Esc: tap (A KeyBar.swift:146-149) runs voxlTap and
\* clears the bar.
BarTap ==
  /\ scene = "active" /\ used.tap < Taps /\ Free1
  /\ LET r0 == [Now EXCEPT !.used.tap = @ + 1]
         r1 == IF doc = "page" THEN VoxlTap(r0, Want) ELSE r0
     IN Set([r1 EXCEPT !.bar = {}, !.fresh = FALSE])

\* Dan picks a Mac key from the bar's menu: chord (A KeyBar.swift:151-155)
\* runs voxlChord and, since 5e57a1f, clears the bar (:154); Paste
\* (:183-187) does the same through voxlPaste's ⌘V (A Page.swift:151-157;
\* its paste event and keyboard.ts's delayed ⌘V, R keyboard.ts:195-199, are
\* not modeled). The key is the next key: it promises its own ⌘ and the
\* bar's.
BarChord ==
  /\ scene = "active" /\ used.chord < Chords /\ Free1
  /\ LET r0 == [Now EXCEPT !.used.chord = @ + 1]
         r1 == IF doc = "page" THEN VoxlChord(r0, {"Cmd"} \cup Want) ELSE r0
     IN Set([r1 EXCEPT !.bar = IF Has("ChordBarClear") THEN {} ELSE @, !.fresh = FALSE])

\* KbLoading: Dan taps the bar's keyboard button, "Show or hide the
\* keyboard" (A KeyBar.swift:94 -> onKeyboard, ViewerController.swift:148 ->
\* toggleKeyboard, :714-717 -> focusKeys, :706-712), before the picture gave
\* the view the keys. The bar is added after the cover, so it is above it
\* (:102, 148), and beside it: the cover covers only the picture
\* (cover.frame = f.picture :202, keyBar.frame = f.keys :213; Layout.swift
\* gives the keys their own strip in every pose, :22-53). So he can tap it
\* while a page loads. focusKeys needs only a web view (guard let web): the
\* view becomes the first responder, and voxlKeyboard focuses #kbd if voxl's
\* page is in the view (A Page.swift:54-61); a page still loading focuses
\* #kbd itself when it starts (R keyboard.ts:287), so Dan's keys reach it
\* from its commit (WebKit and UIKit, assumed: see the skill). Tapped with
\* the focus already there, it only shows or hides the iPhone keyboard (not
\* modeled).
KbButton ==
  /\ KbLoading /\ scene = "active" /\ doc # "none" /\ ~focused
  /\ Set([Now EXCEPT !.focused = TRUE])

-----------------------------------------------------------------------------
(* The world: the app's scene, screens, reloads, the socket *)

Ev(e) == e \in Events /\ envn < EnvMax

\* The app stops being in front (sceneWillResignActive -> resignedActive,
\* :769-775): release(). iOS cancels the touches, so every drag ends.
Resign ==
  /\ Ev("leave") /\ scene = "active"
  /\ Set(EndAll([Release(Now) EXCEPT !.scene = "inactive", !.envn = @ + 1]))

\* Back in front (becameActive, :758-767): a new page if closePage ran (with
\* a picture, focusKeys again: the view has the focus already).
Activate ==
  /\ scene = "inactive"
  /\ LET r0 == [Now EXCEPT !.scene = "active"] IN Set(IF doc = "none" THEN Load(r0) ELSE r0)

\* The background (enteredBackground, :777-790): the page is hidden and sends
\* r (R main.ts:118-121; down is kept).
Background ==
  /\ scene = "inactive"
  /\ LET r0 == [Now EXCEPT !.scene = "background"]
     IN Set(IF doc = "page" /\ sock = "open" /\ Has("Hidden") THEN Post(r0, row, R) ELSE r0)

\* closeLater or the background task's expiry: closePage (:374-386), the view
\* (and its focus) gone.
ClosePage == scene = "background" /\ doc # "none" /\ Set([NewDoc(Teardown(Now), "none") EXCEPT !.focused = FALSE])

Foreground == scene = "background" /\ Set([Now EXCEPT !.scene = "inactive"])

\* A tab or F1/F2 (go(to:), switched(), :292-307): release(), then load().
Switch ==
  /\ Ev("switch") /\ scene = "active"
  /\ Set([Load(Release(Now)) EXCEPT !.row = Other(row), !.envn = @ + 1])

\* load() with no release(): retry (:443-450), the hello watch (:410-421),
\* the web process ending (:536-540), Reconnect (:117-120), the cover's button
\* (:458-476), a changed machine list (:490-505).
Reload == Ev("reload") /\ doc # "none" /\ Set([Load(Now) EXCEPT !.envn = @ + 1])

\* The socket closes and voxl sees it: its read loop ends and it releases all
\* (R server.rs:261-294). The worker posts status closed (R worker.ts:113-117;
\* the app: hello false, A ViewerController.swift:670-675) and reconnects in
\* 1 s. The app hears the close after the open (opened).
LossLoud ==
  /\ Ev("loud") /\ doc = "page" /\ sock = "open" /\ opened
  /\ LET r0 == [Now EXCEPT !.sock = "closed", !.opened = FALSE, !.hello = FALSE, !.envn = @ + 1]
     IN Set(IF Has("Bye") THEN ReleaseAll(r0, row) ELSE r0)

\* The socket stops on the phone only: voxl keeps the connection, and what it
\* holds (its read loop has no timeout, server.rs:261), until TCP gives up.
LossSilent ==
  /\ Ev("silent") /\ doc = "page" /\ sock = "open" /\ opened
  /\ Set([Now EXCEPT !.sock = "closed", !.opened = FALSE, !.hello = FALSE, !.stale[row] = TRUE,
                     !.envn = @ + 1])

TcpGivesUp(s) ==
  /\ stale[s]
  /\ LET r0 == [Now EXCEPT !.stale[s] = FALSE] IN Set(IF Has("Bye") THEN ReleaseAll(r0, s) ELSE r0)

-----------------------------------------------------------------------------
(* Quick steps *)

\* voxl's page commits in the view (didCommit, :529-534): injected scripts and
\* keyboard.ts fresh, the worker connecting.
Commit == doc = "blank" /\ Set(NewDoc(Now, "page"))

\* The worker's socket opens (R worker.ts:108-112): it posts status open to
\* the page, and the page's sends go out from now on (worker.ts:97-99).
SocketOpen ==
  /\ doc = "page" /\ sock = "closed"
  /\ Set([Now EXCEPT !.sock = "open", !.opened = FALSE])

\* Page.watch passes the status on (A Page.swift:35) and the app's status
\* handler runs, since 5e57a1f on every open (A ViewerController.swift:676-682),
\* a window blur in the page, which keyboard.ts maps to its releaseAll (R
\* keyboard.ts:141-145, 285: down cleared, r sent: voxl's release_all lets go
\* of everything that screen's voxl holds, for every connection, R
\* server.rs:384, mac/input.rs:420-435). Page.input's armed, holding and
\* clickMods stay, and so does the bar: its modifiers stay armed across a
\* reconnect. Dan's taps and keys can reach voxl between SocketOpen and this
\* step (the status's hops from the worker to the page to the app).
StatusOpen ==
  /\ doc = "page" /\ sock = "open" /\ ~opened
  /\ LET r0 == [Now EXCEPT !.opened = TRUE]
     IN Set(IF Has("OpenRelease") THEN KbdReleaseAll(r0) ELSE r0)

\* voxl's first message on the new connection is its hello (R server.rs:223);
\* the worker passes it on after its status open (R worker.ts:155-164),
\* Page.watch posts it (A Page.swift:34), and the app's hello handler (A
\* ViewerController.swift:624-654) runs, since ce88951, the bar's lit
\* modifiers again (keyBar.resend, :651; A KeyBar.swift:165-168: voxlArm if
\* any are lit). Since 5e57a1f the hello lets nothing go: voxl sends it again
\* when it restarts its stream (not modeled here: it would only arm the lit
\* modifiers again).
Hello ==
  /\ doc = "page" /\ sock = "open" /\ opened /\ ~hello
  /\ LET r0 == [Now EXCEPT !.hello = TRUE]
     IN Set(IF r0.bar # {} /\ Has("Resend") THEN [r0 EXCEPT !.armed = r0.bar] ELSE r0)

Quick == Commit \/ SocketOpen \/ StatusOpen \/ Hello

\* No quick step left: what Dan sees and the Mac holds for more than a moment.
Settled == ~ENABLED Quick

-----------------------------------------------------------------------------
(* Slow steps *)

\* The page's first frame plays (Page.watch posts picture once per page,
\* A Page.swift:13-15, 36-38; video is off while the page is hidden, R main.ts:
\* 108-121): picture (A ViewerController.swift:655-666) runs focusKeys
\* (:706-712), so the view takes the keyboard focus. Frames follow the hello.
Picture ==
  /\ doc = "page" /\ sock = "open" /\ hello /\ ~focused /\ scene # "background"
  /\ Set([Now EXCEPT !.focused = TRUE])

Done == Settled /\ UNCHANGED vars

DanStep == \/ \E k \in Letters : KeyDown(k) \/ KeyUp(k)
           \/ Click \/ \E g \in DragKinds : DragStart(g) \/ DragEnd(g)
           \/ ModeFlip \/ BarToggle \/ BarTap \/ BarChord \/ KbButton
World   == \/ Resign \/ Activate \/ Background \/ ClosePage \/ Foreground \/ Switch \/ Reload
           \/ LossLoud \/ LossSilent \/ \E s \in Screens : TcpGivesUp(s)

Next == DanStep \/ World \/ Quick \/ Picture \/ Done

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* Dan's promises *)

\* The phone is on screen s, in front, with its page connected.
Attached(s) == scene = "active" /\ row = s /\ doc = "page" /\ sock = "open"
Holds(s, srcs) == /\ Attached(s)
                  /\ \E src \in srcs : \/ src \in hw
                                       \/ src = "drag" /\ fingers # {}

\* P3 "No key or button stays held": once settled, a screen's Mac holds a key,
\* modifier or button only while the phone is on that screen, in front and
\* connected, and Dan still holds the key or finger it is for.
NothingStuck ==
  Settled => \A s \in Screens : /\ \A m \in MacKeys : mac[s][m] # Free => Holds(s, mac[s][m])
                                /\ btn[s] # Free => Holds(s, btn[s])

\* P4 "Bar modifiers hit the next key only": a key or click reaches the Mac
\* with exactly the bar's modifiers if it is the first since Dan changed the
\* bar, and with none otherwise (once): no extra modifier, none missing.
NoExtraModifier   == "extra" \notin bad
NoMissingModifier == "missing" \notin bad

\* P4 "... and the bar shows what the page has armed": once settled, the bar's
\* lit modifiers are the ones the page's next key or click will get.
BarShowsArmed == Settled => bar = (IF doc = "page" THEN armed ELSE {})

TypeOK ==
  /\ hw \subseteq Letters /\ fingers \subseteq DragKinds /\ opened \in BOOLEAN
  /\ scene \in {"active", "inactive", "background"} /\ row \in Screens
  /\ mode \in {"trackpad", "direct"} /\ dragging \in BOOLEAN /\ bar \subseteq {"Cmd"}
  /\ doc \in {"none", "blank", "page"} /\ focused \in BOOLEAN /\ sock \in {"closed", "open"}
  /\ hello \in BOOLEAN /\ armed \subseteq {"Cmd"}
  /\ hold \in [code : Letters \cup {None}, mods : SUBSET {"Cmd"}] /\ clickMods \subseteq {"Cmd"}
  /\ down \subseteq Letters \cup {"Cmd"}
  /\ mac \in [Screens -> [MacKeys -> SUBSET (Letters \cup {"drag", "tap"})]]
  /\ btn \in [Screens -> SUBSET {"drag", "tap"}]
  /\ stale \in [Screens -> BOOLEAN] /\ fresh \in BOOLEAN /\ bad \subseteq {"extra", "missing"}
=============================================================================
