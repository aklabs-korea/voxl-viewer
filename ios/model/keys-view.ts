// The /statechart view of PhoneKeys.tla: what Dan holds against what the Mac
// holds, then the app and its page, then the key bar against the page.

type Vars = {
  hw: string[];
  fingers: string[];
  scene: string;
  row: number;
  mode: string;
  dragging: boolean;
  bar: string[];
  doc: string;
  focused: boolean;
  sock: string;
  opened: boolean;
  hello: boolean;
  armed: string[];
  hold: { code: string; mods: string[] };
  clickMods: string[];
  down: string[];
  mac: Record<string, Record<string, string[]>>;
  btn: Record<string, string[]>;
  stale: Record<string, boolean>;
  fresh: boolean;
  bad: string[];
};

const FINGER: Record<string, string> = {
  pad: "a hold on the pad",
  picHold: "a hold on the picture",
  picPan: "a Direct drag on the picture",
  pointer: "an iPad trackpad drag",
};
const MAC: Record<string, string> = { a: "a", b: "b", Cmd: "⌘" };
const list = (xs: string[]) => (xs.length ? xs.join("+") : "nothing");

const dan = (v: Vars) => {
  const xs = [...(v.hw ?? [])];
  for (const f of v.fingers ?? []) xs.push(FINGER[f] ?? f);
  return xs;
};
const macHolds = (v: Vars) => {
  const out: string[] = [];
  for (const s of Object.keys(v.mac ?? {})) {
    for (const m of Object.keys(v.mac[s])) if ((v.mac[s][m] ?? []).length) out.push(`${MAC[m] ?? m} on ${s}`);
    if ((v.btn?.[s] ?? []).length) out.push(`the button on ${s}`);
  }
  return out;
};

const app = (v: Vars) => {
  const where = v.scene === "active" ? `the app on screen ${v.row}` : v.scene === "inactive" ? "the app behind" : "the app in the background";
  const page = v.doc === "none" ? "page closed" : v.doc === "blank" ? "loading"
    : v.sock !== "open" ? "reconnecting" : !v.opened ? "connected, the app not told yet"
    : v.hello ? "connected" : "connected, hello not in yet";
  const keys = v.doc === "page" && !v.focused ? " (keys go nowhere until the picture or the keyboard button)" : "";
  return `${where}, ${page}${keys}`;
};

const bar = (v: Vars) => {
  const lit = (v.bar ?? []).length ? "bar ⌘ lit" : "bar dark";
  const armed = v.doc === "page" && (v.armed ?? []).length ? "page armed" : "page not armed";
  return `${lit}, ${armed}`;
};

export const title = "Dan's keys, clicks and bar modifiers from the phone to the Mac";

export const state = (v: Vars) => [`Dan holds ${list(dan(v))}, the Mac holds ${list(macHolds(v))}`, app(v), bar(v)];

export const step = (action: string, from: Vars, to: Vars) => {
  const k = (to.hw ?? []).find((x) => !(from.hw ?? []).includes(x)) ?? (from.hw ?? []).find((x) => !(to.hw ?? []).includes(x));
  switch (action) {
    case "KeyDown": return `Dan presses ${k}`;
    case "KeyUp": return `Dan lets go of ${k}`;
    case "Click": return "Dan taps (a click)";
    case "DragStart": {
      const g = (to.fingers ?? []).find((f) => !(from.fingers ?? []).includes(f)) ?? "";
      return `Dan starts ${FINGER[g] ?? "a drag"}`;
    }
    case "DragEnd": {
      const g = (from.fingers ?? []).find((f) => !(to.fingers ?? []).includes(f)) ?? "";
      return `Dan ends ${FINGER[g] ?? "a drag"}`;
    }
    case "ModeFlip": return `Dan switches to ${to.mode === "direct" ? "Direct" : "Trackpad"}`;
    case "BarToggle": return (to.bar ?? []).length ? "Dan taps ⌘ on the bar" : "Dan taps ⌘ off on the bar";
    case "BarTap": return "Dan taps Esc on the bar";
    case "BarChord": return "Dan picks a Mac key on the bar (a chord with ⌘)";
    case "Resign": return "the app goes behind";
    case "Activate": return "the app comes back to the front";
    case "Background": return "the app goes to the background";
    case "ClosePage": return "30 s pass: the app closes the page";
    case "Foreground": return "the app leaves the background";
    case "Switch": return "Dan switches screens";
    case "Reload": return "the app reloads the page (no release)";
    case "LossLoud": return "the socket drops; voxl sees it";
    case "LossSilent": return "the socket drops on the phone only";
    case "TcpGivesUp": return "TCP gives up: voxl drops the old connection";
    case "Commit": return "the new page commits";
    case "SocketOpen": return "the page's socket opens";
    case "StatusOpen": return "the app hears the socket opened: release-all";
    case "Hello": return "voxl's hello reaches the app: the bar's ⌘ sent again";
    case "Picture": return "the first frame: the view takes the keys";
    case "KbButton": return "Dan taps the bar's keyboard button: the view takes the keys";
    case "Done": return null;
    default: return action;
  }
};
