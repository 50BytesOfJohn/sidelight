#!/bin/bash
# Usage: scripts/measure.sh <seconds> [label]
# Samples CPU% and RSS every second for the SidePanel app process AND related processes, prints averages/peaks.
#
# How related processes are found:
#  1. "responsible PID": WebKit's WebContent/Networking/GPU XPC services are children of launchd (ppid 1),
#     not of the app, so a ppid walk misses them. macOS tracks a "responsible process" for each XPC service;
#     tools/respid (tiny C helper, calls libsystem's responsibility_get_pid_responsible_for_pid) lists
#     every process whose responsible PID == app PID. This catches WebKit helpers, perl (media-control),
#     MTLCompilerService etc. without confusing them with WebKit processes of Safari or the Tauri app.
#  2. plus a classic ppid walk (descendants of the app), as a fallback.
# CPU% = delta of cumulative CPU time (ps 'time' column, 10 ms resolution) / wall-clock delta. 100% = one core.
# (ps %cpu on macOS is a decaying average, so it is not used.)
# Energy/footprint: `top -stats cpu,idlew,power,mem` runs in parallel over the same PIDs.
#   POWER = Activity Monitor "Energy Impact"; MEM = physical footprint (what Activity Monitor shows as Memory).
# Env: APP_MATCH (pgrep -f pattern for the main process), default SidePanel.app/Contents/MacOS/SidePanel
set -u
DUR=${1:-60}; LABEL=${2:-run}
DIR=$(cd "$(dirname "$0")/.." && pwd)
MATCH=${APP_MATCH:-SidePanel.app/Contents/MacOS/SidePanel}
APP=$(pgrep -f "$MATCH" | head -1)
[ -z "$APP" ] && { echo "app not running ($MATCH)"; exit 1; }
[ -x "$DIR/tools/respid" ] || clang -O2 -o "$DIR/tools/respid" "$DIR/tools/respid.c"

related() {
  { echo "$APP"
    "$DIR/tools/respid" | awk -v p="$APP" '$2==p {print $1}'
    local frontier="$APP" all next f
    all=$(ps -A -o pid=,ppid=)
    while [ -n "$frontier" ]; do
      next=""
      for f in $frontier; do next="$next $(echo "$all" | awk -v f="$f" '$2==f {print $1}')"; done
      frontier=$(echo $next); [ -n "$frontier" ] && echo $frontier | tr ' ' '\n'
    done
  } | sort -un
}

PIDS=$(related | tr '\n' ',' | sed 's/,$//')
TMP=$(mktemp -d)
TOPARGS=""; for p in ${PIDS//,/ }; do TOPARGS="$TOPARGS -pid $p"; done
top -l $((DUR + 1)) -s 1 -stats pid,command,cpu,idlew,power,mem $TOPARGS > "$TMP/top.txt" 2>/dev/null &
TOPPID=$!

for ((i = 0; i <= DUR; i++)); do
  if (( i % 10 == 0 && i > 0 )); then PIDS=$(related | tr '\n' ',' | sed 's/,$//'); fi
  T=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
  ps -o pid=,time=,rss=,comm= -p "$PIDS" | awk -v t="$T" '{c=$4; for(i=5;i<=NF;i++) c=c"_"$i; sub(/.*\//,"",c); print t, $1, $2, $3, c}' >> "$TMP/raw.txt"
  sleep 1
done
wait $TOPPID 2>/dev/null

echo "=== $LABEL: ${DUR}s, app pid $APP, related pids: $PIDS"
awk -v app="$APP" '
function secs(s,   n,a){ n=split(s,a,":"); return (n==3)? a[1]*3600+a[2]*60+a[3] : a[1]*60+a[2] }
function grp(pid,c){ if(pid==app) return "app"; if(c ~ /WebKit/) return "webkit"; if(c ~ /perl|media-control/) return "media-control"; if(c ~ /codex/) return "codex"; return "other" }
{ t=$1; pid=$2; cpu=secs($3); rss=$4/1024; c=$5; g=grp(pid,c)
  if(!(t in seen)){ seen[t]=1; ts[++nt]=t }
  name[pid]=c
  if(pid in lastc){ dc=(cpu-lastc[pid])/(t-lastt[pid])*100; CPU[t,g]+=dc; CPU[t,"TOTAL"]+=dc; PCPU[pid]+=dc; PN[pid]++ }
  lastc[pid]=cpu; lastt[pid]=t
  RSS[t,g]+=rss; RSS[t,"TOTAL"]+=rss; PRSS[pid]=rss
}
END{
  split("app media-control codex webkit other TOTAL",gs," ")
  printf "%-14s %9s %9s %11s %11s\n","group","avgCPU%","peakCPU%","avgRSS_MB","peakRSS_MB"
  for(k=1;k<=6;k++){ g=gs[k]; sc=0;pc=0;sr=0;pr=0;n=0;m=0
    for(i=1;i<=nt;i++){ t=ts[i]; r=RSS[t,g]; sr+=r; if(r>pr)pr=r; m++
      if(i>1){ c=CPU[t,g]; sc+=c; if(c>pc)pc=c; n++ } }
    if(pr==0) continue
    printf "%-14s %9.2f %9.2f %11.1f %11.1f\n", g, (n?sc/n:0), pc, sr/m, pr }
  print "-- per process (avg CPU%, last RSS MB):"
  for(p in name) printf "   %-7s %-32s %6.2f%% %7.1f MB\n", p, name[p], (PN[p]?PCPU[p]/PN[p]:0), PRSS[p]
}' "$TMP/raw.txt"
awk '
function mb(x,   v,u){ v=x+0; u=x; gsub(/[0-9.+-]/,"",u); if(u=="K") return v/1024; if(u=="G") return v*1024; if(u=="B") return v/1048576; return v }
/^PID/ { s++; next }
s>1 && $1 ~ /^[0-9]+$/ && NF>=6 { pw[s]+=$(NF-1); iw[s]+=$(NF-2); fp[s]+=mb($NF) }
END { n=0; for(k in pw){ n++; P+=pw[k]; I+=iw[k]; F+=fp[k]; if(fp[k]>FP) FP=fp[k] }
  if(n) printf "top: avg POWER(sum)=%.2f  avg IDLEW(sum)=%.1f  avg footprint(sum)=%.1f MB (peak %.1f) over %d samples\n", P/n, I/n, F/n, FP, n }' "$TMP/top.txt"
rm -rf "$TMP"
