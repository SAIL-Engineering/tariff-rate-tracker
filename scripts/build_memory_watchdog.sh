#!/usr/bin/env bash
# Stop a long build quickly when the whole machine runs out of memory, instead
# of letting it thrash for hours.
#
# Usage (start it just before the build, in the same shell):
#   scripts/build_memory_watchdog.sh <unit> [min_gb] [grace_seconds] &
#   systemd-run --user --scope --collect --unit=<unit> ... Rscript ...
#
# Why: on 2026-11-14 the rebuild's R process sat at its normal ~19 GB while the
# rest of the desktop grew to ~38 GB of a 62 GB machine. With a 2 GB swapfile
# and systemd-oomd's pressure kill turned off (20-no-oomd-pressure-kill.conf),
# nothing stepped in: the machine thrashed from 18:39 (journald and snapd missed
# their watchdogs, almost nothing was logged 20:00-22:00) until the kernel's OOM
# killer took R at 22:46 -- four hours lost on a revision that takes ~35 min.
# The scope's MemoryMax cannot help there: the build was under its own cap.
#
# Rule: when MemAvailable + SwapFree stays below <min_gb> (default 1.5) for
# <grace_seconds> (default 60), SIGKILL every process in <unit> and exit 1.
# Free swap counts as headroom, so a larger swapfile delays the kill rather
# than triggering it. Only the named unit is ever touched. The loop uses shell
# builtins only, so it keeps running when the machine is too short of memory
# to page in new programs.
set -u
unit=${1:?usage: build_memory_watchdog.sh <unit> [min_gb] [grace_seconds]}
case "$unit" in *.scope|*.service) ;; *) unit="$unit.scope" ;; esac
min_gb=${2:-1.5}
grace=${3:-60}
interval=5
min_kb=$(awk -v g="$min_gb" 'BEGIN { printf "%d", g * 1048576 }')

stamp() { printf '%(%Y-%m-%dT%H:%M:%S%z)T' -1; }

headroom_kb() {
  local key val rest avail=0 swap=0
  while read -r key val rest; do
    case "$key" in
      MemAvailable:) avail=$val ;;
      SwapFree:) swap=$val ;;
    esac
  done < /proc/meminfo
  echo $((avail + swap))
}

# Wait up to five minutes for the build's scope to appear.
cgroup=''
for _ in $(seq 1 60); do
  cgroup=$(systemctl --user show -p ControlGroup --value "$unit" 2>/dev/null)
  if [ -n "$cgroup" ] && [ -d "/sys/fs/cgroup$cgroup" ]; then break; fi
  cgroup=''
  sleep "$interval"
done
if [ -z "$cgroup" ]; then
  echo "$(stamp) memory watchdog: $unit never started; nothing to watch" >&2
  exit 2
fi
echo "$(stamp) memory watchdog: watching $unit (kill below ${min_gb} GB available+swap for ${grace}s)" >&2

low=0
while [ -d "/sys/fs/cgroup$cgroup" ]; do
  kb=$(headroom_kb)
  if [ "$kb" -lt "$min_kb" ]; then low=$((low + interval)); else low=0; fi
  if [ "$low" -gt "$grace" ]; then
    echo "$(stamp) memory watchdog: available+swap $((kb / 1024)) MB, below ${min_gb} GB for ${grace}s -- killing $unit so the machine does not thrash. Resume with the same --only-revisions list; finished revisions are skipped." >&2
    systemctl --user kill --signal=SIGKILL "$unit"
    exit 1
  fi
  sleep "$interval"
done
echo "$(stamp) memory watchdog: $unit finished; exiting" >&2
exit 0
