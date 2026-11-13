#!/bin/sh
# Model-checks the iPhone/iPad app against Dan's four promises with TLC
# (PhoneScreen.tla: sound and the screen coming back; PhoneKeys.tla: keys,
# buttons and the key bar's modifiers) and compares every verdict with the
# baseline below.
#
#   ios/model/check.sh            every config (see BASELINE)
#   ios/model/check.sh --guards   also removes each guard of the code once
#                                 and shows which promise breaks
#   ios/model/check.sh --record   records the covered app files in
#                                 covered.sha256, after you confirmed the
#                                 models describe them
#
# Exit 0: every verdict matches the baseline and the covered files are the
# ones recorded. 1: a verdict changed (the output names it and prints its
# path). 2: TLC could not run. 3: the verdicts match, but a covered file in
# ios/Voxl changed since covered.sha256 was recorded: the models may describe
# code that is gone. voxl's own code (the page and the server) isn't in this
# repo: its version is in the voxl-ios-model skill, not checked here.
# Tools: TLC 1.7.4 and Java 25 from mise (installed on first run), or set
# TLA2TOOLS to a tla2tools.jar and JAVA to a java binary.
set -u
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)

# The drift guard: a sha256 of every app file the models describe, path
# relative to the repo root. Carriage returns are left out, so a Windows
# checkout (CRLF) and a Mac or CI (LF) agree.
FILES="ios/Voxl/App.swift ios/Voxl/KeyBar.swift ios/Voxl/Machines.swift ios/Voxl/Page.swift ios/Voxl/Pointer.swift ios/Voxl/ViewerController.swift"
sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi | cut -d' ' -f1; }
covered() {
  (cd "$root" && for f in $FILES; do
    if [ -f "$f" ]; then printf '%s  %s\n' "$(tr -d '\r' < "$f" | sha)" "$f"; else printf 'missing  %s\n' "$f"; fi
  done)
}
if [ "${1:-}" = "--record" ]; then
  covered > "$here/covered.sha256"
  echo "Recorded $(wc -l < "$here/covered.sha256" | tr -d ' ') files in ios/model/covered.sha256."
  exit 0
fi
drift=0
if ! covered | cmp -s - "$here/covered.sha256"; then
  drift=1
  echo "DRIFT: ios/Voxl changed since ios/model/covered.sha256 was recorded:"
  covered | diff "$here/covered.sha256" - | sed -n 's/^</  recorded:/p; s/^>/  now:     /p'
  echo "  The models may no longer describe the code. Bring them back in line with"
  echo "  /pstack:maintain-formal-verification-skill (and the voxl-ios-model skill), then"
  echo "  record the files again: ios/model/check.sh --record"
fi

TLC_SPEC='http:tla2tools[url=https://github.com/tlaplus/tlaplus/releases/download/v1.7.4/tla2tools.jar,checksum=sha256:936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88]@1.7.4'
JAVA_SPEC='java@temurin-25'

jar=${TLA2TOOLS:-}
java=${JAVA:-}
if [ -z "$jar" ] || [ -z "$java" ]; then
  command -v mise >/dev/null || { echo "check.sh: needs mise (or TLA2TOOLS and JAVA)" >&2; exit 2; }
  if ! mise where "$TLC_SPEC" >/dev/null 2>&1 || ! mise which java --tool "$JAVA_SPEC" >/dev/null 2>&1; then
    mise install "$JAVA_SPEC" "$TLC_SPEC" >&2 || { echo "check.sh: mise install failed" >&2; exit 2; }
  fi
  [ -n "$jar" ] || jar="$(mise where "$TLC_SPEC")/tla2tools.jar"
  [ -n "$java" ] || java=$(mise which java --tool "$JAVA_SPEC")
fi
# Java on Windows wants Windows paths.
winpath() { if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s\n' "$1"; fi; }
jar=$(winpath "$jar")

guards=0
[ "${1:-}" = "--guards" ] && guards=1

# Each model's rules: invariants, then temporal properties.
INV_PhoneScreen="QuietAway PlaysWhereIAm NeverSwitchesByItself CoverTellsTruth"
PROP_PhoneScreen="ComesBack"
INV_PhoneKeys="NothingStuck NoExtraModifier NoMissingModifier BarShowsArmed"
PROP_PhoneKeys=""

# The baseline: the rules each run breaks. Every other rule of its model
# holds. A run takes its constants from ios/model/CONFIG.cfg, with Off
# replaced.
#   name | model | config | Off (guards removed) | rules that break
BASELINE='sound|PhoneScreen|screen-sound|{}|
steady|PhoneScreen|screen-steady|{}|
slow|PhoneScreen|screen-slow|{}|
drop|PhoneScreen|screen-drop|{}|
down|PhoneScreen|screen-down|{}|
behind|PhoneScreen|screen-behind|{}|
sharp|PhoneScreen|screen-sharp|{}|
full|PhoneScreen|screen-full|{}|ComesBack
fullgone|PhoneScreen|screen-fullgone|{}|
silent|PhoneScreen|screen-silent|{}|CoverTellsTruth ComesBack
typing|PhoneKeys|keys-typing|{}|
esc|PhoneKeys|keys-esc|{}|
pointer|PhoneKeys|keys-pointer|{}|NoExtraModifier
hold|PhoneKeys|keys-hold|{}|
leave|PhoneKeys|keys-leave|{}|
loading|PhoneKeys|keys-loading|{}|NoMissingModifier
reload|PhoneKeys|keys-reload|{}|
loss|PhoneKeys|keys-loss|{}|
tcp|PhoneKeys|keys-tcp|{}|
fresh|PhoneKeys|keys-fresh|{}|NoExtraModifier'
GUARDS='no-ResignMutes|PhoneScreen|screen-sound|{"ResignMutes"}|
no-ResignMutes-TickMutes|PhoneScreen|screen-sound|{"ResignMutes","TickMutes"}|QuietAway
no-TickMutes|PhoneScreen|screen-sound|{"TickMutes"}|QuietAway
no-ActiveRule|PhoneScreen|screen-sound|{"ActiveRule"}|QuietAway
no-FreshMute|PhoneScreen|screen-steady|{"FreshMute"}|PlaysWhereIAm
no-FreshSuspend|PhoneScreen|screen-behind|{"FreshSuspend"}|
no-CommitAudio-TickMutes|PhoneScreen|screen-behind|{"CommitAudio","TickMutes"}|PlaysWhereIAm
no-FreshSuspend-CommitAudio-TickMutes|PhoneScreen|screen-behind|{"FreshSuspend","CommitAudio","TickMutes"}|QuietAway PlaysWhereIAm
no-CommitAudio|PhoneScreen|screen-sound|{"CommitAudio"}|
no-PictureHides|PhoneScreen|screen-sound|{"PictureHides"}|CoverTellsTruth ComesBack
no-HelloHides|PhoneScreen|screen-fullgone|{"HelloHides"}|CoverTellsTruth ComesBack
no-HelloSharp|PhoneScreen|screen-fullgone|{"HelloSharp"}|CoverTellsTruth
no-WideWaits|PhoneScreen|screen-sharp|{"WideWaits"}|
no-WideWaits-HelloSharp|PhoneScreen|screen-sharp|{"WideWaits","HelloSharp"}|CoverTellsTruth
no-WatchHello|PhoneScreen|screen-drop|{"WatchHello"}|ComesBack
no-CommitClearsFailing|PhoneScreen|screen-slow|{"CommitClearsFailing"}|CoverTellsTruth
no-CoverAction|PhoneScreen|screen-slow|{"CoverAction"}|
no-CoverAction-CommitClearsFailing|PhoneScreen|screen-full|{"CoverAction","CommitClearsFailing"}|NeverSwitchesByItself CoverTellsTruth ComesBack
no-Blur|PhoneKeys|keys-leave|{"Blur"}|NothingStuck NoExtraModifier
no-Hidden|PhoneKeys|keys-leave|{"Hidden"}|
no-Hidden-Bye|PhoneKeys|keys-reload|{"Hidden","Bye"}|
no-Hidden-Bye-HelloRelease|PhoneKeys|keys-reload|{"Hidden","Bye","HelloRelease"}|NothingStuck
no-Bye|PhoneKeys|keys-loss|{"Bye"}|
no-Bye-ReconnectRelease|PhoneKeys|keys-loss|{"Bye","ReconnectRelease"}|NoExtraModifier
no-Bye-ReconnectRelease-HelloRelease|PhoneKeys|keys-loss|{"Bye","ReconnectRelease","HelloRelease"}|NothingStuck NoExtraModifier
no-ReconnectRelease|PhoneKeys|keys-tcp|{"ReconnectRelease"}|NoExtraModifier
no-ReconnectRelease-HelloRelease|PhoneKeys|keys-tcp|{"ReconnectRelease","HelloRelease"}|NothingStuck NoExtraModifier
no-Disarm|PhoneKeys|keys-leave|{"Disarm"}|NoExtraModifier BarShowsArmed
no-BarClear|PhoneKeys|keys-leave|{"BarClear"}|
no-BarClear-ArmedMsg|PhoneKeys|keys-leave|{"BarClear","ArmedMsg"}|NoExtraModifier NoMissingModifier BarShowsArmed
no-ArmedMsg|PhoneKeys|keys-typing|{"ArmedMsg"}|BarShowsArmed
no-LoadClearsBar|PhoneKeys|keys-reload|{"LoadClearsBar"}|NoMissingModifier
no-LoadClearsBar-Resend|PhoneKeys|keys-reload|{"LoadClearsBar","Resend"}|NoMissingModifier BarShowsArmed
no-Resend|PhoneKeys|keys-loading|{"Resend"}|NoMissingModifier BarShowsArmed
no-TapLetGo|PhoneKeys|keys-esc|{"TapLetGo"}|NoExtraModifier
no-HelloRelease|PhoneKeys|keys-fresh|{"HelloRelease"}|NothingStuck NoExtraModifier
no-KeyUpLift|PhoneKeys|keys-typing|{"KeyUpLift"}|NothingStuck NoExtraModifier
no-ClickLift|PhoneKeys|keys-typing|{"ClickLift"}|NothingStuck NoExtraModifier
no-HoldPress|PhoneKeys|keys-typing|{"HoldPress"}|NoMissingModifier
no-LetGoKey|PhoneKeys|keys-typing|{"LetGoKey"}|NoExtraModifier
no-LetGoClick|PhoneKeys|keys-typing|{"LetGoClick"}|NoExtraModifier
no-ButtonUp|PhoneKeys|keys-typing|{"ButtonUp"}|NothingStuck
no-ModeUp|PhoneKeys|keys-pointer|{"ModeUp"}|NothingStuck NoExtraModifier
no-ModeUp-hold|PhoneKeys|keys-hold|{"ModeUp"}|
no-HoldEndUp|PhoneKeys|keys-hold|{"HoldEndUp"}|
no-ModeUp-HoldEndUp|PhoneKeys|keys-hold|{"ModeUp","HoldEndUp"}|NothingStuck'
runs=$BASELINE
[ $guards = 1 ] && runs="$BASELINE
$GUARDS"

work=$(mktemp -d "${TMPDIR:-/tmp}/voxl-ios-model.XXXXXX")
trap 'rm -rf "${work:?}"' EXIT INT TERM
cores=$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)

invs() { eval "echo \$INV_$1"; }
props() { eval "echo \$PROP_$1"; }

# One TLC run: job NAME WORKERS MODEL CONFIG OFF RULES... (TypeOK is always
# checked). Its own folder and temp folder: TLC unpacks its standard modules
# into the temp folder and deletes them when it exits. -Xmx512m: the models
# need little, and Java's default (a quarter of RAM per JVM) made parallel
# checks die for lack of memory. -fp 0: a fixed fingerprint polynomial; with
# TLC's random one, the loop it prints for a broken temporal property changed
# from run to run.
job() {
  name=$1 workers=$2 model=$3 cfg=$4 off=$5; shift 5
  d="$work/$name"
  mkdir -p "$d/tmp"
  cp "$here/$model.tla" "$d/"
  {
    sed '/^INVARIANTS/,$d; /^ *Off *=/d' "$here/$cfg.cfg"
    echo "  Off = $off"
    echo "INVARIANTS"
    echo "  TypeOK"
    for r in "$@"; do case " $(invs "$model") " in *" $r "*) echo "  $r" ;; esac; done
    echo "PROPERTIES"
    for r in "$@"; do case " $(props "$model") " in *" $r "*) echo "  $r" ;; esac; done
  } > "$d/run.cfg"
  # Java itself can die: while it starts, before TLC prints a line (seen on
  # Windows with many JVMs starting at once: "jimage file name is null"), or
  # when the machine runs out of memory. Only a run that ended that way, with
  # no verdict (exit 0, 11, 12 or 13), is tried again, at most twice; a
  # verdict never is.
  for try in 1 2 3; do
    rm -rf "${d:?}/meta"
    (cd "$d" && "$java" -Xmx512m -XX:+UseParallelGC "-Djava.io.tmpdir=$(winpath "$d/tmp")" -cp "$jar" tlc2.TLC \
       -workers "$workers" -lncheck final -fp 0 -metadir "$(winpath "$d/meta")" -config run.cfg "$model.tla" \
       > "$d/tlc.out" 2>&1; echo $? > "$d/exit")
    case $(cat "$d/exit") in 0|11|12|13) break ;; esac
    grep -q '^TLC2 Version' "$d/tlc.out" &&
      ! grep -Eq '^# (There is insufficient memory|A fatal error)' "$d/tlc.out" && break
    [ $try = 3 ] || sleep "$try"
  done
}

# Each rule expected to break runs on its own, on one worker, so TLC stops at
# its first break with the shortest path (for an invariant; a temporal
# property's path is a loop TLC found, not always the shortest). The rules
# expected to hold run together over the whole state space, in parallel.
plan="$work/plan"
: > "$plan"
echo "$runs" | while IFS='|' read -r name model cfg off broken; do
  for r in $broken; do echo "$name~$r|$model|$cfg|$off|$r" >> "$plan"; done
  hold=""
  for r in $(invs "$model") $(props "$model"); do
    case " $broken " in *" $r "*) ;; *) hold="$hold $r" ;; esac
  done
  [ -n "$hold" ] && echo "$name~holds|$model|$cfg|$off|$hold" >> "$plan"
done
# At most 6 JVMs at once (or one per core), so a few checks side by side
# don't run the machine out of memory.
slots=$cores; [ "$slots" -le 6 ] || slots=6
i=0
grep -v '~holds|' "$plan" > "$work/quick"
while IFS='|' read -r name model cfg off rules; do
  # shellcheck disable=SC2086
  job "$name" 1 "$model" "$cfg" "$off" $rules &
  i=$((i + 1))
  [ $((i % slots)) -eq 0 ] && wait
done < "$work/quick"
wait
grep '~holds|' "$plan" > "$work/full"
full=$(wc -l < "$work/full")
[ "$full" -le "$slots" ] || full=$slots
workers=$(( cores / full )); [ "$workers" -ge 1 ] || workers=1
i=0
while IFS='|' read -r name model cfg off rules; do
  # shellcheck disable=SC2086
  job "$name" "$workers" "$model" "$cfg" "$off" $rules &
  i=$((i + 1))
  [ $((i % slots)) -eq 0 ] && wait
done < "$work/full"
wait

status=0
printf '%-22s %-22s %-9s %s\n' RUN RULE EXPECTED GOT
while IFS='|' read -r name model cfg off rules; do
  d="$work/$name"
  code=$(cat "$d/exit" 2>/dev/null || echo 255)
  case $name in *~holds) expect=holds ;; *) expect=breaks ;; esac
  # Which rule TLC says broke. TLC stops at the first break, so in a group the
  # rules after it are not checked. A temporal break doesn't name its
  # property; the group's invariants held, since -lncheck final checks
  # liveness only after every state passed them.
  broke=""
  case $code in
    0) ;;
    11|12|13)
      broke=$(sed -n 's/^Error: Invariant \([A-Za-z0-9_]*\) is violated.*/\1/p' "$d/tlc.out" | head -1)
      [ -n "$broke" ] || { grep -q "Temporal properties were violated" "$d/tlc.out" && broke=temporal; }
      [ -n "$broke" ] || broke=other ;;
    *) broke=error ;;
  esac
  nprops=0
  for r in $rules; do case " $(props "$model") " in *" $r "*) nprops=$((nprops + 1)) ;; esac; done
  moved=0
  for r in $rules; do
    isprop=0
    case " $(props "$model") " in *" $r "*) isprop=1 ;; esac
    if [ -z "$broke" ]; then got=holds
    elif [ "$broke" = error ]; then got="error($code)"
    elif [ "$broke" = "$r" ]; then got=breaks
    elif [ "$broke" = temporal ] && [ $isprop = 1 ] && [ $nprops = 1 ]; then got=breaks
    elif [ "$broke" = temporal ] && [ $isprop = 1 ]; then got="one-of-these-breaks"
    elif [ "$broke" = temporal ]; then got=holds
    elif [ "$broke" = other ]; then got="breaks(TypeOK?)"
    else got="not-checked"
    fi
    mark=""
    case $got in
      "$expect") ;;
      not-checked) mark="  (TLC stops at its first break in a run)" ;;
      *) mark="  <-- CHANGED"; moved=1 ;;
    esac
    printf '%-22s %-22s %-9s %s%s\n' "${name%~*}" "$r" "$expect" "$got" "$mark"
  done
  if [ "$broke" = error ]; then
    status=2
    echo "---- ${name%~*} ($model, $cfg.cfg, Off=$off): TLC could not run:"
    tail -20 "$d/tlc.out"
  elif [ $moved = 1 ]; then
    [ $status = 2 ] || status=1
    echo "---- ${name%~*} ($model, $cfg.cfg, Off=$off): TLC said:"
    grep -E "is violated|Temporal properties|^State [0-9]+:|Back to state|Stuttering|^Error|distinct states found" "$d/tlc.out" | sed 's/ line [0-9].*//' | head -60
    echo "---- read this path in plain words with the statechart skill (see the voxl-ios-model skill)"
  elif [ -n "$broke" ]; then
    printf '    path:'
    grep -E "^State [0-9]+:|Back to state|Stuttering" "$d/tlc.out" | sed -n 's/^State [0-9]*: <\([A-Za-z0-9]*\).*/\1/p; s/^\(Back to state\|Stuttering\).*/\1/p' | tr '\n' ' '
    echo
  fi
done < "$plan"
for n in sound typing; do
  [ "$(cat "$work/$n~holds/exit" 2>/dev/null)" = 0 ] &&
    echo "$n: $(grep -h "distinct states found" "$work/$n~holds/tlc.out" | tail -1)"
done
[ $status = 0 ] && [ $drift = 1 ] && status=3
case $status in
  0) echo "OK: every verdict matches the baseline." ;;
  1) echo "CHANGED: a verdict differs from the baseline (marked above)." ;;
  2) echo "ERROR: TLC could not run a check (see above)." ;;
  3) echo "DRIFT: every verdict matches the baseline, but covered files changed (see the top)." ;;
esac
[ $drift = 1 ] && [ $status != 3 ] && echo "(Also DRIFT: covered files changed, see the top.)"
exit $status
