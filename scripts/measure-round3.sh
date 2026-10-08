#!/bin/zsh
# Round 3: avoidance OFF (Tauri PoC may run), glass mode, `open -n` so args apply. Config file is not modified.
cd "$(dirname "$0")/.."
DUR=${1:-60}
launch() { pkill -f SidePanel.app/Contents/MacOS/SidePanel; sleep 2; open -n build/SidePanel.app --args -axPrompt NO -avoidMode off -mode glass "$@"; }
run() { label=$1; secs=$2; shift 2; launch "$@"; sleep 15; ./scripts/measure.sh "$secs" "$label ($*)"; tail -1 launch.log; echo; }
run "n left regular"  $DUR -position left -size regular
run "o left compact"  $DUR -position left -size compact
run "p left minimal"  $DUR -position left -size minimal
run "q top bar"       $DUR -position top
# manager open for 60 s, then closed by the app at t=80 s, then 60 s idle after close
launch -position left -size regular -openManager YES -closeManagerAfter 80; sleep 15
./scripts/measure.sh $DUR "r manager window open"; echo
sleep 10; tail -1 launch.log
./scripts/measure.sh $DUR "s idle after manager closed"; echo
run "t size-switch cycle every 2 s (15 s)"     15 -position left -size regular -cycleSizes YES
run "u position-switch cycle every 3 s (15 s)" 15 -position left -size regular -cyclePositions YES
run "v baseline 15 s"                          15 -position left -size regular
pkill -f SidePanel.app/Contents/MacOS/SidePanel
