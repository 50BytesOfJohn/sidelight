#!/bin/zsh
# Round 2 states. Avoidance OFF (Tauri PoC may be running), animated bg explicitly off, `open -n` so args always apply.
cd "$(dirname "$0")/.."
DUR=${1:-60}
run() { label=$1; secs=$2; shift 2
  pkill -f SidePanel.app/Contents/MacOS/SidePanel; sleep 2
  open -n build/SidePanel.app --args -axPrompt NO -avoidance NO -animatedBG NO -showSeconds NO "$@"; sleep 15
  ./scripts/measure.sh "$secs" "$label ($*)"; tail -1 launch.log; echo
}
run "g glass, codex on"         $DUR -mode glass -codexWidget YES -htmlWidget YES
run "h glass, codex off"        $DUR -mode glass -codexWidget NO  -htmlWidget YES
run "i black idle"              $DUR -mode black -codexWidget YES -htmlWidget YES
run "j image, material cards"   $DUR -mode image -imageCards material -codexWidget YES -htmlWidget YES
run "k image, glass cards"      $DUR -mode image -imageCards glass    -codexWidget YES -htmlWidget YES
run "l burst baseline 10s"      10   -mode glass -codexWidget YES -htmlWidget YES
run "m codex demo burst 10s"    10   -mode glass -codexWidget YES -htmlWidget YES -codexDemo YES
pkill -f SidePanel.app/Contents/MacOS/SidePanel
