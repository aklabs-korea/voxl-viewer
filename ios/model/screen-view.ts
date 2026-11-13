// The /statechart view of PhoneScreen.tla: what Dan sees (the cover over the
// picture), what he hears, and where the app is.

type Vars = {
  scene: string;
  recent: boolean;
  row: number;
  web: boolean;
  answered: boolean;
  committed: boolean;
  hello: boolean;
  picture: boolean;
  failing: boolean;
  tooWide: boolean;
  waitT: boolean;
  retryT: string;
  helloT: string;
  closeT: boolean;
  cover: string;
  muted: string;
  nav: string;
  sock: string;
  pagePic: boolean;
  docWide: boolean;
  audioOn: boolean;
  session: string;
  susp: boolean;
  up: Record<string, boolean>;
  wide: Record<string, boolean>;
  owner: Record<string, string>;
};

const COVER: Record<string, string> = {
  off: "no cover",
  label: "cover: the screen's name",
  dim: "cover: isn't answering",
  full: "cover: another viewer asked for Full",
};

const picture = (v: Vars) => {
  if (!v.web) return "no page";
  if (v.nav === "asked") return "loading";
  if (v.nav !== "page") return "no page";
  if (v.sock === "dead") return "picture frozen (socket silent)";
  if (v.sock === "hung") return "reconnect hanging";
  if (v.sock !== "open") return "reconnecting";
  if (v.docWide) return "Full: nothing plays";
  return v.pagePic ? "picture playing" : "connected, no frames yet";
};

const sound = (v: Vars) => {
  if (!v.web || !v.audioOn) return "silent";
  if (v.susp) return "muted";
  return v.session === "playback" ? "sound on" : "sound on unless the silent switch is on";
};

const where = (v: Vars) =>
  v.scene === "active" ? `in front on screen ${v.row}${v.recent ? "" : ", idle 5 min"}`
  : v.scene === "inactive" ? "behind" : v.scene === "background" ? "background" : "suspended";
// What the screen's voxl is doing: down, or another viewer holding it on Full.
const voxl = (v: Vars) => {
  const r = String(v.row);
  const xs: string[] = [];
  if (v.up && v.up[r] === false) xs.push("its voxl down");
  if (v.owner && v.owner[r] === "other") xs.push("another viewer holds Full");
  return xs.length ? `, ${xs.join(", ")}` : "";
};
const scene = (v: Vars) => where(v) + voxl(v);

export const title = "The phone app connecting to a screen";

export const state = (v: Vars) => [`${COVER[v.cover] ?? v.cover}, ${picture(v)}`, sound(v), scene(v)];

export const step = (action: string, from: Vars, to: Vars) => {
  switch (action) {
    case "BecomeActive": return "the app comes to the front";
    case "Resign": return "the app goes behind";
    case "Background": return "the app goes to the background";
    case "Suspend": return "iOS suspends the app";
    case "Foreground": return "the app leaves the background";
    case "Touch": return "Dan touches the app";
    case "Idle": return "5 minutes pass";
    case "SwitchScreen": return "Dan switches screens";
    case "CoverButton": return to.row !== from.row ? "Dan presses the cover's button: other screen" : "Dan presses the cover's button: reload";
    case "Reconnect": return "Dan picks Reconnect";
    case "Answer":
    case "QuickAnswer": return "voxl answers; the page commits";
    case "Fail": return "the load fails";
    case "AudioStarts": return "the page's sound starts";
    case "SocketOpens": return to.docWide ? "the page connects: hello says Full" : "the page connects";
    case "Rebuild": return to.docWide ? "voxl's capture goes Full: a new hello" : "voxl's capture leaves Full: a new hello";
    case "Picture": return "the picture plays";
    case "Tick": return "the 1 s tick applies the sound rule";
    case "Waited": return "3 s pass";
    case "RetryFires": return "the retry fires";
    case "HelloFires": return "10 s pass with no hello";
    case "TooWideFires": return to.cover === "full" && from.cover !== "full" ? "2 s pass: the Full cover" : "2 s pass";
    case "CloseFires": return "30 s pass: the app closes the page";
    case "Down": return "a screen's voxl stops";
    case "VoxlUp": return "a screen's voxl starts again";
    case "Drop": return "the socket drops";
    case "Hang": return "the reconnect hangs";
    case "Dead": return "the socket goes silent";
    case "Crash": return "the web process ends";
    case "OtherFull": return "another viewer asks for Full";
    case "OtherGone": return "the other viewer leaves";
    case "Done": return null;
    default: return action;
  }
};
