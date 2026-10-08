#!/bin/bash
# Relaunches the app in each state (via launch-arg defaults) and measures 60 s each.
cd "$(dirname "$0")/.."
DUR=${1:-60}
run() { label=$1; shift
  pkill -f SidePanel.app/Contents/MacOS/SidePanel; sleep 2
  open build/SidePanel.app --args -axPrompt NO "$@"; sleep 15   # warm-up: WebKit spawn, first fetch, artwork
  ./scripts/measure.sh "$DUR" "$label ($*)"; tail -1 launch.log; echo
}
run "a idle panel"      -style panel -showSeconds NO  -animatedBG NO  -htmlWidget YES
run "b seconds on"      -style panel -showSeconds YES -animatedBG NO  -htmlWidget YES
run "c animated bg"     -style panel -showSeconds NO  -animatedBG YES -htmlWidget YES
run "d cards style"     -style cards -showSeconds NO  -animatedBG NO  -htmlWidget YES
run "e html widget off" -style panel -showSeconds NO  -animatedBG NO  -htmlWidget NO
run "f glass off (NSVisualEffectView)" -style panel -useGlass NO -showSeconds NO -animatedBG NO -htmlWidget YES
