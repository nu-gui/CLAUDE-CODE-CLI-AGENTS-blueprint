#!/usr/bin/env bash
# install-systemd-timers.sh
#
# Generate + install systemd --user units from config/nightly-schedule.yaml.
# Makes nightly-puffin truly 24/7: timers survive reboot, logout, and Claude
# session exit. No Claude session has to be running for the shell scripts
# themselves to fire (they call `claude -p` headless as needed, which uses
# the user's persisted auth token).
#
# Prerequisite: `loginctl enable-linger $USER` (checked by this script).
#
# Usage:
#   install-systemd-timers.sh                # generate + enable + start
#   install-systemd-timers.sh --dry-run      # print what would be written
#   install-systemd-timers.sh --uninstall    # disable + remove all units
#   install-systemd-timers.sh --list         # list currently installed units
#
# Unit naming: nightly-puffin-<trigger-name>.{service,timer}
# Unit location: ~/.config/systemd/user/
#
# Each trigger in nightly-schedule.yaml produces ONE service + ONE timer pair.
# Timer fires OnCalendar={cron expanded}; service runs the trigger's prompt
# via bash with $HOME wired. stdout/stderr → journal (view with `journalctl
# --user -u nightly-puffin-<name>.service`).

set -euo pipefail

SCHEDULE="${SCHEDULE:-$HOME/.claude/config/nightly-schedule.yaml}"
UNIT_DIR="$HOME/.config/systemd/user"
UNIT_PREFIX="nightly-puffin"
LOG="$HOME/.claude/logs/install-systemd-timers.log"

mkdir -p "$(dirname "$LOG")"
log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*" | tee -a "$LOG"; }

MODE="install"
for arg in "$@"; do
  case "$arg" in
    --dry-run)   MODE="dry-run" ;;
    --uninstall) MODE="uninstall" ;;
    --list)      MODE="list" ;;
    -h|--help)   sed -n '2,25p' "$0"; exit 0 ;;
    *) echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

# --- preflight ---
command -v systemctl >/dev/null || { echo "systemctl missing" >&2; exit 10; }
command -v python3 >/dev/null   || { echo "python3 missing" >&2; exit 10; }

if [[ "$MODE" == "install" || "$MODE" == "dry-run" ]]; then
  [[ -f "$SCHEDULE" ]] || { echo "schedule file not found: $SCHEDULE" >&2; exit 20; }
  # Linger required for user-level timers to fire when the user is not logged in.
  linger_state=$(loginctl show-user "$USER" 2>/dev/null | awk -F= '/^Linger=/{print $2}')
  if [[ "$linger_state" != "yes" ]]; then
    echo "WARNING: linger is '$linger_state' — user timers will not fire when you log out." >&2
    echo "Fix: sudo loginctl enable-linger $USER" >&2
    # Not fatal — proceed so the install still works if the user is logged in.
  fi
fi

# --- helpers ---

list_installed() {
  systemctl --user list-unit-files "${UNIT_PREFIX}-*.timer" --no-pager 2>/dev/null
  systemctl --user list-timers "${UNIT_PREFIX}-*.timer" --no-pager --all 2>/dev/null
}

# Parse the schedule YAML and emit one line per trigger:
#   <name>|<cron>|<prompt>|<description>
parse_triggers() {
  SCHEDULE="$SCHEDULE" python3 - <<'PY'
import os, sys, yaml
with open(os.environ["SCHEDULE"]) as f:
    doc = yaml.safe_load(f)
for t in doc.get("triggers", []):
    name = t.get("name","").strip()
    cron = t.get("cron","").strip()
    prompt = t.get("prompt","").strip()
    desc = t.get("description","").replace("|","/").strip()
    if not (name and cron and prompt):
        continue
    # Systemd unit name can't contain / ; names in YAML should already be clean.
    print(f"{name}|{cron}|{prompt}|{desc}")
PY
}

# Convert a 5-field crontab expression "M H DoM Mon DoW" into a systemd
# OnCalendar string. Supports */N, N, N-M, N,M, and the standard 5 fields.
# Systemd's OnCalendar format: "DayOfWeek Year-Month-Day Hour:Minute:Second"
cron_to_on_calendar() {
  local cron="$1"
  CRON="$cron" python3 - <<'PY'
import os
cron = os.environ["CRON"].split()
if len(cron) != 5:
    raise SystemExit(f"bad cron: {cron}")
m, h, dom, mon, dow = cron

def conv_field(v, mapping=None):
    if v == "*": return "*"
    if v.startswith("*/"):
        # Cron */N → systemd N-starts-at-0 step form "0/N".
        # Systemd rejects "*/N" inside a wildcard field — only "0/N" is
        # accepted (normalised by systemd itself to "00/N"). See #147.
        return f"0/{v[2:]}"
    return v

def conv_dow(v):
    # cron: 0=Sun..6=Sat or 1-5=Mon-Fri etc.
    # systemd: Mon,Tue,Wed,Thu,Fri,Sat,Sun or ranges Mon..Fri
    names = ["Sun","Mon","Tue","Wed","Thu","Fri","Sat"]
    if v == "*": return ""
    if "-" in v:
        a,b = v.split("-")
        return f"{names[int(a)]}..{names[int(b)]}"
    if "," in v:
        return ",".join(names[int(x)] for x in v.split(","))
    return names[int(v)]

on_cal_dow = conv_dow(dow)
# Wildcard cron fields must stay "*", not collapse to "00". The previous
# "00 if == '*'" branch turned "*/6 * * * *" into "*-*-* 00:*/6:00" — hour
# pinned to midnight only, which systemd rejects as a bad unit setting
# (issue #147: pool-worker-tick.timer never fired since install).
mm = conv_field(m)
hh = conv_field(h)
dom_s = conv_field(dom)
mon_s = conv_field(mon)

# Build the OnCalendar. Systemd wants: "DOW YYYY-MM-DD HH:MM:SS"
# For ranges like */6 on minute, systemd uses the same */6 syntax within the minute field.
cal = []
if on_cal_dow: cal.append(on_cal_dow)
cal.append(f"*-{mon_s}-{dom_s}")
cal.append(f"{hh}:{mm}:00")
print(" ".join(cal))
PY
}

write_unit_pair() {
  local name="$1" cron="$2" prompt="$3" desc="$4"
  local service_path="$UNIT_DIR/${UNIT_PREFIX}-${name}.service"
  local timer_path="$UNIT_DIR/${UNIT_PREFIX}-${name}.timer"
  local on_cal
  on_cal=$(cron_to_on_calendar "$cron")

  # #140: hive-status.sh exits 1 when pipeline STATUS is DEGRADED/BLOCKED.
  # Under systemd that non-zero exit marks the calling unit failed even
  # though the script ran fine. Prompts that call it must pass --observe
  # (which forces exit 0). Warn loudly if a prompt is missing it.
  if [[ "$prompt" == *"hive-status.sh"* && "$prompt" != *"--observe"* ]]; then
    log "WARNING: trigger '${name}' calls hive-status.sh without --observe; systemd will mark the unit failed on DEGRADED/BLOCKED. Add --observe to the prompt in nightly-schedule.yaml (see #140)."
  fi

  # W18-ID14: overnight stages that chain 2+ claude -p specialists get 90 min;
  # all other triggers keep the default 30 min (1800s).
  local timeout
  case "$name" in
    nightly-exec-B1|nightly-exec-B2|issue-planner) timeout=5400 ;;
    *) timeout=1800 ;;
  esac

  local service_body timer_body
  service_body=$(cat <<EOF
[Unit]
Description=nightly-puffin trigger: ${name} — ${desc}
Documentation=file://$HOME/.claude/config/nightly-schedule.yaml

[Service]
Type=oneshot
Environment=HOME=$HOME
Environment=PATH=/usr/local/bin:/usr/bin:/bin:$HOME/.nvm/versions/node/v22.22.0/bin
ExecStart=/bin/bash -c '${prompt}'
StandardOutput=journal
StandardError=journal
TimeoutStartSec=${timeout}
Nice=10
EOF
)

  timer_body=$(cat <<EOF
[Unit]
Description=Timer for nightly-puffin trigger ${name}
Documentation=file://$HOME/.claude/config/nightly-schedule.yaml

[Timer]
OnCalendar=${on_cal}
Persistent=true
RandomizedDelaySec=30

[Install]
WantedBy=timers.target
EOF
)

  if [[ "$MODE" == "dry-run" ]]; then
    echo "--- $service_path"; echo "$service_body"; echo
    echo "--- $timer_path";   echo "$timer_body";   echo
    return 0
  fi

  echo "$service_body" > "$service_path"
  echo "$timer_body"   > "$timer_path"
  log "wrote $service_path + $timer_path (OnCalendar=$on_cal)"
}

# --- modes ---

case "$MODE" in

  list)
    list_installed
    ;;

  uninstall)
    mapfile -t units < <(systemctl --user list-unit-files "${UNIT_PREFIX}-*.timer" --no-pager --no-legend 2>/dev/null | awk '{print $1}')
    if [[ "${#units[@]}" -eq 0 ]]; then
      log "no ${UNIT_PREFIX}-* timers to uninstall"
      exit 0
    fi
    for t in "${units[@]}"; do
      local_svc="${t%.timer}.service"
      systemctl --user disable --now "$t" 2>/dev/null || true
      rm -f "$UNIT_DIR/$t" "$UNIT_DIR/$local_svc"
      log "uninstalled $t / $local_svc"
    done
    systemctl --user daemon-reload
    log "uninstall complete"
    ;;

  install|dry-run)
    mkdir -p "$UNIT_DIR"
    count=0
    while IFS="|" read -r name cron prompt desc; do
      [[ -z "$name" ]] && continue
      write_unit_pair "$name" "$cron" "$prompt" "$desc"
      count=$((count+1))
    done < <(parse_triggers)

    if [[ "$MODE" == "dry-run" ]]; then
      log "dry-run: would install $count unit pairs"
      exit 0
    fi

    systemctl --user daemon-reload
    log "daemon-reload"

    # enable + start every timer
    mapfile -t timers < <(cd "$UNIT_DIR" && ls "${UNIT_PREFIX}-"*.timer 2>/dev/null)
    for t in "${timers[@]}"; do
      systemctl --user enable --now "$t" 2>&1 | tee -a "$LOG"
    done

    log "installed and started $count timers"
    echo
    echo "Verify: systemctl --user list-timers '${UNIT_PREFIX}-*.timer'"
    echo "Logs:   journalctl --user -u ${UNIT_PREFIX}-<name>.service -f"
    ;;

esac
