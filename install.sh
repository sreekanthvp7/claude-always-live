#!/bin/bash
# =============================================================================
#  claude-always-live — keep Claude Code sessions live on Linux servers and Macs
#  https://github.com/sreekanthvp7/claude-always-live
#
#  ONE COMMAND, ANY MACHINE (Linux server, AWS / Google Cloud / Azure VM, Mac):
#     curl -fsSL https://raw.githubusercontent.com/sreekanthvp7/claude-always-live/main/install.sh | bash
#  On Linux it asks for sudo itself. On a Mac run it as the Mac user (no sudo).
#
#  WHAT IT DOES (for every chosen user)
#    1. Installs tmux and Claude Code if missing.
#    2. Runs a Remote Control "device", so the machine shows under Devices in
#       the Claude app and you can start new sessions on it from your phone.
#    3. Keeps that user's sessions (used in the last 30 days, max 8) live with
#       Remote Control on, each in its own tmux session.
#    4. Starts all of it again after every reboot (systemd on Linux, launchd
#       on macOS), and answers Claude's start-up questions automatically.
#    5. Turns off older Claude autostart services at boot, if it finds them.
#  Safe to re-run: updates everything, keeps session lists, never starts a
#  session that is already open.
#
#  AFTER INSTALL
#     claude-live list              # sessions and whether they are running
#     claude-live sync              # pick up sessions started since
#     claude-live remove <name>     # stop a session for good
#     claude-live attach <name>     # see its terminal (Ctrl-b d to leave)
#  Linux, if a user isn't signed in yet:
#     sudo -iu <user> claude auth login   # same account as your phone app
#     (device + sessions then start by themselves within a minute)
#  Linux, if the server had an older Claude autostart, stop it once
#  (it is already disabled for the next boot):
#     sudo systemctl stop claude-remote
#  macOS uninstall:   bash install.sh --uninstall
#
#  NON-INTERACTIVE
#     Linux: curl -fsSL <url> | sudo USERS="alice bob" PERMISSION_MODE=auto \
#              MAX_SESSIONS=8 MAX_AGE_DAYS=30 START_NOW=1 bash
#     macOS: curl -fsSL <url> | PERMISSION_MODE=auto MAX_SESSIONS=6 \
#              MAX_AGE_DAYS=30 NO_SLEEP=1 START_NOW=1 bash
#
#  TAKE CARE
#   - Anyone who can use your Claude account (phone/web) can run commands on
#     this machine as these users. Turn on 2-step verification for it.
#   - Permission mode "auto" lets Claude act without asking each time. A user
#     with passwordless sudo gives Claude root. Never use bypassPermissions.
#   - This runs as root on Linux and is fetched from GitHub: whoever can push
#     to the repo controls what runs on every machine. Keep that account
#     secure and never put passwords or keys in the repo (it is public).
#   - Deleting a session in the app does not stop it here; use
#     `claude-live remove`. Each live session uses ~300-450 MB RAM.
#   - If a user's Claude login expires, their sessions stop reconnecting
#     until they sign in again.
#   - Only choose real users, not service accounts.
#   - macOS needs automatic login to start after a restart (not possible with
#     FileVault on); anyone with physical access then gets your desktop.
# =============================================================================
set -euo pipefail
SELF_URL="https://raw.githubusercontent.com/sreekanthvp7/claude-always-live/main/install.sh"
OS=$(uname)

ask() { # ask VAR "question" "default"   (reads the keyboard even when piped)
  local var=$1 q=$2 def=$3 ans=""
  if [ -n "${!var:-}" ]; then return; fi
  if [ -t 0 ]; then read -r -p "$q [$def]: " ans
  elif [ -r /dev/tty ] && : 2>/dev/null </dev/tty; then read -r -p "$q [$def]: " ans </dev/tty || true; fi
  printf -v "$var" '%s' "${ans:-$def}"
}

# =============================================================================
#  Helper scripts (same on Linux and macOS). Written into $1.
# =============================================================================
write_helpers() {
local DIR=$1
cat > "$DIR/claude-session.sh" <<'EOF'
#!/bin/bash
# Runs one saved Claude session (by ID) with Remote Control, inside tmux.
# Started by `claude-live`. Config: ~/.config/claude-sessions/<slug>.env
slug="$1"
CONF="$HOME/.config/claude-sessions"
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
[ -f "$CONF/live.conf" ] && source "$CONF/live.conf"
source "$CONF/$slug.env"
cd "${WORKDIR:-$HOME}" 2>/dev/null || cd "$HOME"
# Answer the "trust this folder" question only if it is on screen.
( for i in $(seq 1 30); do sleep 2
    if tmux capture-pane -p 2>/dev/null | grep -q "Yes, I trust this folder"; then
      tmux send-keys Down; sleep 1; tmux send-keys Enter; break; fi
  done ) &
claude --resume "$SESSION_ID" --remote-control "$RC_NAME" \
       --permission-mode "${PERMISSION_MODE:-auto}"
exec bash   # keep the window open if Claude exits
EOF

cat > "$DIR/claude-device.sh" <<'EOF'
#!/bin/bash
# Remote Control device: this machine appears under "Devices" in the Claude
# app, so new sessions can be started on it remotely.
CONF="$HOME/.config/claude-sessions"
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
[ -f "$CONF/live.conf" ] && source "$CONF/live.conf"
cd "$HOME"
# Answer the start-up questions only when they are the last line on screen:
#   "Trust /home/<user>? [y/N]"  and  "Enable Remote Control? (y/n)"
( for i in $(seq 1 45); do sleep 2
    last=$(tmux capture-pane -p 2>/dev/null | grep -v '^[[:space:]]*$' | tail -1)
    case "$last" in
      "Trust "*"? [y/N]"*|"Enable Remote Control? (y/n)"*) tmux send-keys y Enter ;;
      *"Yes, I trust this folder"*) tmux send-keys Down; sleep 1; tmux send-keys Enter ;;
    esac
  done ) &
# Retry if it stops early (a registration left over from before a reboot can
# block it for a few minutes: "This folder is already served ...").
# Not signed in yet? Wait (checking every 30s) until the user signs in, so no
# restart is needed after `claude auth login`.
until claude auth status 2>/dev/null | grep -q '"loggedIn": true'; do
  echo "Waiting for sign-in: run  claude auth login  as $(id -un)"; sleep 30
done
for try in $(seq 1 20); do
  claude remote-control --permission-mode "${PERMISSION_MODE:-auto}" \
         --no-create-session-in-dir \
         --remote-control-session-name-prefix "$(hostname -s)-$(id -un)"
  echo "remote-control stopped (try $try); retrying in 30s ..."; sleep 30
done
exec bash
EOF

cat > "$DIR/claude-live" <<'EOF'
#!/bin/bash
# claude-live — keep this user's Claude Code sessions live with Remote Control.
#   claude-live list              show sessions and whether they are running
#   claude-live sync              add sessions used in the last MAX_AGE_DAYS
#   claude-live start [slug]      start all (or one) that are not running
#   claude-live add <id> [name]   keep a session live (also un-removes it)
#   claude-live remove <slug|id|name>   stop it and never reopen it
#   claude-live attach <slug>     open its terminal (Ctrl+B then D to leave)
#   claude-live boot | stop-all   used by systemd / launchd
set -u
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
HERE=$(cd "$(dirname "$0")" && pwd)
CONF="$HOME/.config/claude-sessions"; mkdir -p "$CONF"
REMOVED="$CONF/removed"; touch "$REMOVED"
MAX_SESSIONS=8; MAX_AGE_DAYS=30; PERMISSION_MODE=auto
[ -f "$CONF/live.conf" ] && source "$CONF/live.conf"
T="tmux -L claude-live"
HOST=$(hostname -s)

envs()      { ls "$CONF"/*.env 2>/dev/null; }
known()     { grep -qx "SESSION_ID=$1" "$CONF"/*.env 2>/dev/null; }
removed()   { grep -qx "$1" "$REMOVED"; }
short()     { printf '%s' "$1" | cut -c1-$2; }
# Running = any live Claude process has it open (terminal, desktop app, phone).
# Claude records these in ~/.claude/sessions/<pid>.json
running()   { local f p
  pgrep -u "$(id -u)" -f -- "--resume $1" >/dev/null && return 0
  for f in "$HOME"/.claude/sessions/*.json; do
    [ -f "$f" ] && grep -q "\"sessionId\":\"$1\"" "$f" || continue
    p=$(basename "$f" .json); kill -0 "$p" 2>/dev/null && return 0
  done; return 1; }
field()     { grep -aoE "\"$2\":\"[^\"]*\"" "$1" | tail -1 | cut -d'"' -f4; }
clean()     { printf '%s' "$1" | tr -d '"$`\\' | cut -c1-60; }
# newest session logs first (GNU find on Linux, BSD stat on macOS)
recent()    { if find --version >/dev/null 2>&1; then
    find "$HOME/.claude/projects" -mindepth 2 -maxdepth 2 -name '*.jsonl' \
         -mtime "-$MAX_AGE_DAYS" -printf '%T@ %p\n' 2>/dev/null
  else
    find "$HOME/.claude/projects" -mindepth 2 -maxdepth 2 -name '*.jsonl' \
         -mtime "-$MAX_AGE_DAYS" -exec stat -f '%m %N' {} + 2>/dev/null
  fi | sort -rn | cut -d' ' -f2-; }

write_env() { # id name workdir
  local id=$1 name workdir=$3 slug; slug=$(short "$1" 8)
  name=$(clean "$2")
  if grep -qx "RC_NAME=\"$name\"" "$CONF"/*.env 2>/dev/null; then name="$name $(short "$id" 4)"; fi
  printf 'SESSION_ID=%s\nRC_NAME="%s"\nWORKDIR=%s\n' "$id" "$name" "$workdir" > "$CONF/$slug.env"
  echo "  + $slug  $name"
}

sync() {
  local count f id name wd
  count=$(envs | wc -l | tr -d ' ')
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ "$count" -ge "$MAX_SESSIONS" ] && { echo "  (limit $MAX_SESSIONS reached)"; break; }
    id=$(basename "$f" .jsonl)
    [[ $id =~ ^[0-9a-f-]{36}$ ]] || continue
    known "$id" && continue; removed "$id" && continue
    grep -qE '"entrypoint":"(cli|claude-desktop)"' "$f" || continue   # interactive sessions only
    grep -q '"type":"user"' "$f" || continue
    name=$(field "$f" customTitle); [ -z "$name" ] && name=$(field "$f" aiTitle)
    [ -z "$name" ] && name="$HOST $(short "$id" 8)"
    wd=$(field "$f" cwd); [ -d "$wd" ] || wd=$HOME
    write_env "$id" "$name" "$wd"; count=$((count+1))
  done < <(recent)
}

start_one() {
  local e=$1 slug; slug=$(basename "$e" .env)
  ( source "$e"
    if running "$SESSION_ID"; then echo "  = $slug already running"; exit; fi
    $T kill-session -t "$slug" 2>/dev/null
    $T new-session -d -s "$slug" "$HERE/claude-session.sh" "$slug" && echo "  > $slug started ($RC_NAME)" )
}

case "${1:-list}" in
  sync)  sync ;;
  start) if [ -n "${2:-}" ]; then start_one "$CONF/$2.env"; else for e in $(envs); do start_one "$e"; sleep 3; done; fi ;;
  boot)  # wait for the network, then let the device claim its folder first
         # (a session in a parent folder would otherwise block the device)
         for i in $(seq 1 60); do curl -s -o /dev/null --max-time 5 https://api.anthropic.com && break; sleep 2; done
         until claude auth status 2>/dev/null | grep -q '"loggedIn": true'; do sleep 30; done
         for i in $(seq 1 60); do
           tmux -L claude-device capture-pane -p -t device 2>/dev/null | grep -q 'Ready' && break
           sleep 2; done
         sync; for e in $(envs); do start_one "$e"; sleep 3; done ;;
  stop-all) for e in $(envs); do $T kill-session -t "$(basename "$e" .env)" 2>/dev/null; done; true ;;
  attach) exec $T attach -t "$2" ;;
  add)   [ -n "${2:-}" ] || { echo "usage: claude-live add <session-id> [name]"; exit 1; }
         grep -vx "$2" "$REMOVED" > "$REMOVED.tmp" || true; mv "$REMOVED.tmp" "$REMOVED"
         f=$(ls "$HOME"/.claude/projects/*/"$2".jsonl 2>/dev/null | head -1)
         wd=$HOME; [ -n "$f" ] && { w=$(field "$f" cwd); [ -d "$w" ] && wd=$w; }
         known "$2" || write_env "$2" "${3:-$HOST $(short "$2" 8)}" "$wd"
         start_one "$CONF/$(short "$2" 8).env" ;;
  remove) [ -n "${2:-}" ] || { echo "usage: claude-live remove <slug|id|name>"; exit 1; }
         for e in $(envs); do
           ( source "$e"; s=$(basename "$e" .env)
             if [ "$s" = "$2" ] || [ "$SESSION_ID" = "$2" ] || [ "$RC_NAME" = "$2" ]; then
               echo "$SESSION_ID" >> "$REMOVED"; $T kill-session -t "$s" 2>/dev/null
               pkill -u "$(id -u)" -f -- "--resume $SESSION_ID" 2>/dev/null
               rm -f "$e"; echo "  - removed $s ($RC_NAME)"; fi )
         done ;;
  list|*) printf '%-10s %-8s %-36s %s\n' SLUG STATE SESSION_ID NAME
         for e in $(envs); do ( source "$e"; st=stopped; running "$SESSION_ID" && st=live
           printf '%-10s %-8s %-36s %s\n' "$(basename "$e" .env)" "$st" "$SESSION_ID" "$RC_NAME" ); done
         echo; echo "attach: claude-live attach <slug>   (leave with Ctrl+B then D)" ;;
esac
EOF
chmod 755 "$DIR/claude-session.sh" "$DIR/claude-device.sh" "$DIR/claude-live"
}

# =============================================================================
#  Linux (systemd): runs as root, sets up any number of users
# =============================================================================
install_linux() {
if [ "$(id -u)" -ne 0 ]; then
  echo "== Needs root; asking for sudo"
  if [ -f "${BASH_SOURCE[0]:-}" ]; then exec sudo -E bash "${BASH_SOURCE[0]}" "$@"; fi
  TMP=$(mktemp); curl -fsSL "$SELF_URL" -o "$TMP"
  exec sudo -E bash "$TMP" "$@"
fi

ALL_USERS=$(awk -F: '$3>=1000 && $3<60000 && $7!~/(nologin|false)$/ {printf "%s:%s ",$1,$6}' /etc/passwd)
DEFAULT_USERS=""   # suggest only users who already use Claude; else everyone
for e in $ALL_USERS; do [ -d "${e#*:}/.claude" ] && DEFAULT_USERS="$DEFAULT_USERS${e%%:*} "; done
[ -n "$DEFAULT_USERS" ] || for e in $ALL_USERS; do DEFAULT_USERS="$DEFAULT_USERS${e%%:*} "; done
echo "== Claude Code always-live setup on $(hostname) (Linux) =="
ask USERS           "Users to set up (space separated)"                         "${DEFAULT_USERS% }"
ask PERMISSION_MODE "Permission mode (auto, acceptEdits, default, bypassPermissions)" "auto"
MEM_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
SUGGEST=$(( (MEM_MB - 1024) / 500 )); [ "$SUGGEST" -lt 1 ] && SUGGEST=1; [ "$SUGGEST" -gt 8 ] && SUGGEST=8
ask MAX_SESSIONS    "Max live sessions per user (RAM ${MEM_MB} MB; each uses ~300-450 MB)" "$SUGGEST"
ask MAX_AGE_DAYS    "Keep sessions used within the last N days"                 "30"
ask START_NOW       "Start everything now? (1=yes, 0=only at next boot)"         "1"

echo "== Installing packages (tmux, curl)"
MISSING=""
for c in tmux curl pgrep; do command -v $c >/dev/null || MISSING="$MISSING $c"; done
MISSING=${MISSING/pgrep/procps}
if [ -n "$MISSING" ]; then
  if command -v apt-get >/dev/null; then        # Ubuntu, Debian
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $MISSING
  elif command -v dnf >/dev/null; then          # Amazon Linux 2023, RHEL/Rocky/Alma 8+, Fedora
    dnf install -y -q ${MISSING/procps/procps-ng}
  elif command -v yum >/dev/null; then          # Amazon Linux 2, CentOS 7
    yum install -y -q ${MISSING/procps/procps-ng}
  elif command -v zypper >/dev/null; then       # SUSE (Azure / Google Cloud images)
    zypper --non-interactive install $MISSING
  else
    echo "!! Please install:$MISSING  then re-run"; exit 1
  fi
fi
TMUX_BIN=$(command -v tmux)

write_helpers /usr/local/bin

cat > /etc/systemd/system/claude-device@.service <<EOF
[Unit]
Description=Claude Code Remote Control device for %i
After=network-online.target
Wants=network-online.target

[Service]
Type=forking
User=%i
WorkingDirectory=~
ExecStart=$TMUX_BIN -L claude-device new-session -d -s device /usr/local/bin/claude-device.sh
ExecStop=$TMUX_BIN -L claude-device kill-server
RemainAfterExit=yes
TimeoutStartSec=60

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/claude-live@.service <<'EOF'
[Unit]
Description=Claude Code live sessions for %i (Remote Control)
After=network-online.target claude-device@%i.service
Wants=network-online.target

[Service]
Type=oneshot
User=%i
WorkingDirectory=~
ExecStart=/usr/local/bin/claude-live boot
ExecStop=/usr/local/bin/claude-live stop-all
RemainAfterExit=yes
TimeoutStartSec=infinity

[Install]
WantedBy=multi-user.target
EOF

# Older single-session units from earlier setups: stop them starting at boot
# (left running now so no open session is cut off).
for u in claude-remote.service $(systemctl list-unit-files --no-legend 'claude-session@*' 'claude-ubuntu@*' 2>/dev/null | awk '{print $1}') \
         $(systemctl list-units --all --no-legend 'claude-session@*' 'claude-ubuntu@*' 2>/dev/null | awk '{print $1}'); do
  case $u in *@.service) continue;; esac
  systemctl disable "$u" >/dev/null 2>&1 || true
done
systemctl daemon-reload

NEED_LOGIN=""
for U in $USERS; do
  id "$U" >/dev/null 2>&1 || { echo "!! user $U does not exist, skipped"; continue; }
  H=$(getent passwd "$U" | cut -d: -f6)
  echo "== $U"
  if [ ! -x "$H/.local/bin/claude" ]; then
    echo "  installing Claude Code for $U"
    sudo -iu "$U" bash -c 'curl -fsSL https://claude.ai/install.sh | bash' >/dev/null
  fi
  sudo -u "$U" mkdir -p "$H/.config/claude-sessions"
  printf 'PERMISSION_MODE=%s\nMAX_SESSIONS=%s\nMAX_AGE_DAYS=%s\n' "$PERMISSION_MODE" "$MAX_SESSIONS" "$MAX_AGE_DAYS" \
    | sudo -u "$U" tee "$H/.config/claude-sessions/live.conf" >/dev/null
  systemctl enable "claude-device@$U" "claude-live@$U" >/dev/null 2>&1
  if sudo -iu "$U" "$H/.local/bin/claude" auth status 2>/dev/null | grep -q '"loggedIn": true'; then
    sudo -iu "$U" /usr/local/bin/claude-live sync
    if [ "$START_NOW" = "1" ]; then
      systemctl restart "claude-device@$U"
      systemctl restart "claude-live@$U"
    fi
    echo "  ready (device + live sessions)"
  else
    NEED_LOGIN="$NEED_LOGIN $U"
    echo "  NOT signed in yet"
  fi
done

echo
echo "== Done. Services: claude-device@<user> and claude-live@<user> (start at boot)."
if [ -n "$NEED_LOGIN" ]; then
  echo
  echo "Sign in once for:$NEED_LOGIN"
  for U in $NEED_LOGIN; do
    echo "   sudo -iu $U claude auth login     # open the link, sign in, paste the code"
    echo "   (the device and sessions then start by themselves within a minute)"
  done
fi
if systemctl is-active --quiet claude-remote 2>/dev/null; then
  echo
  echo "The old claude-remote service is still running. Once the new sessions show"
  echo "in the app, stop it:  sudo systemctl stop claude-remote"
fi
echo
echo "Manage sessions as each user:  claude-live list | add <id> | remove <slug> | attach <slug>"
}

# =============================================================================
#  macOS (launchd): runs as the logged-in user, sets up that user
# =============================================================================
install_mac() {
[ "$(id -u)" -ne 0 ] || { echo "On macOS run this as your Mac user, without sudo."; exit 1; }
local BIN="$HOME/.local/bin" AGENTS="$HOME/Library/LaunchAgents" CONF="$HOME/.config/claude-sessions"
local UID_N; UID_N=$(id -u)
local LABELS="com.claude.device com.claude.live"
export PATH="$BIN:/opt/homebrew/bin:/usr/local/bin:$PATH"

if [ "${1:-}" = "--uninstall" ]; then
  for l in $LABELS; do
    launchctl bootout "gui/$UID_N/$l" 2>/dev/null || true
    rm -f "$AGENTS/$l.plist"
  done
  tmux -L claude-device kill-server 2>/dev/null || true
  tmux -L claude-live kill-server 2>/dev/null || true
  rm -f "$BIN/claude-live" "$BIN/claude-session.sh" "$BIN/claude-device.sh"
  echo "Removed. Session list kept in $CONF (delete it if not needed)."
  exit 0
fi

MEM_MB=$(( $(sysctl -n hw.memsize) / 1048576 ))
SUGGEST=$(( (MEM_MB - 4096) / 500 )); [ "$SUGGEST" -lt 1 ] && SUGGEST=1; [ "$SUGGEST" -gt 8 ] && SUGGEST=8
echo "== Claude Code always-live setup for $(id -un) on $(scutil --get ComputerName 2>/dev/null || hostname -s) (macOS) =="
ask PERMISSION_MODE "Permission mode (auto, acceptEdits, default, bypassPermissions)" "auto"
ask MAX_SESSIONS    "Max live sessions (RAM ${MEM_MB} MB; each uses ~300-450 MB)"   "$SUGGEST"
ask MAX_AGE_DAYS    "Keep sessions used within the last N days"                    "30"
ask NO_SLEEP        "Stop this Mac sleeping + restart after power loss? (1/0, asks for your password)" "1"
ask START_NOW       "Start everything now? (1=yes, 0=at next login)"               "1"

if ! command -v tmux >/dev/null; then
  if ! command -v brew >/dev/null; then
    echo "!! tmux is needed and Homebrew is not installed."
    echo "   Install Homebrew from https://brew.sh , then re-run this script."
    exit 1
  fi
  echo "== Installing tmux"; brew install tmux
fi
local TMUX_BIN; TMUX_BIN=$(command -v tmux)
if [ ! -x "$BIN/claude" ]; then
  echo "== Installing Claude Code"; curl -fsSL https://claude.ai/install.sh | bash
fi
mkdir -p "$BIN" "$AGENTS" "$CONF"
printf 'PERMISSION_MODE=%s\nMAX_SESSIONS=%s\nMAX_AGE_DAYS=%s\n' "$PERMISSION_MODE" "$MAX_SESSIONS" "$MAX_AGE_DAYS" > "$CONF/live.conf"

write_helpers "$BIN"

# AbandonProcessGroup keeps the tmux servers running after the launcher exits.
plist() { # label program args...
  local label=$1; shift
  {
    echo '<?xml version="1.0" encoding="UTF-8"?>'
    echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
    echo '<plist version="1.0"><dict>'
    echo "  <key>Label</key><string>$label</string>"
    echo '  <key>ProgramArguments</key><array>'
    for a in "$@"; do echo "    <string>$a</string>"; done
    echo '  </array>'
    echo '  <key>RunAtLoad</key><true/>'
    echo '  <key>AbandonProcessGroup</key><true/>'
    echo "  <key>WorkingDirectory</key><string>$HOME</string>"
    echo '  <key>EnvironmentVariables</key><dict>'
    echo "    <key>PATH</key><string>$BIN:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>"
    echo '  </dict>'
    echo "  <key>StandardOutPath</key><string>/tmp/$label.$(id -un).log</string>"
    echo "  <key>StandardErrorPath</key><string>/tmp/$label.$(id -un).log</string>"
    echo '</dict></plist>'
  } > "$AGENTS/$label.plist"
}
plist com.claude.device "$TMUX_BIN" -L claude-device new-session -d -s device "$BIN/claude-device.sh"
plist com.claude.live   "$BIN/claude-live" boot

if [ "$NO_SLEEP" = "1" ]; then
  echo "== Keeping the Mac awake (your password may be asked)"
  sudo pmset -a sleep 0 disksleep 0 autorestart 1 || echo "!! pmset failed; set it in System Settings > Energy"
  sudo pmset -a womp 1 2>/dev/null || true
fi

if claude auth status 2>/dev/null | grep -q '"loggedIn": true'; then
  claude-live sync
  if [ "$START_NOW" = "1" ]; then
    for l in $LABELS; do launchctl bootout "gui/$UID_N/$l" 2>/dev/null || true; done
    tmux -L claude-device kill-server 2>/dev/null || true
    launchctl bootstrap "gui/$UID_N" "$AGENTS/com.claude.device.plist"
    launchctl bootstrap "gui/$UID_N" "$AGENTS/com.claude.live.plist"
    echo "== Started. Give it a minute, then: claude-live list"
  else
    echo "== Will start at next login."
  fi
else
  echo
  echo "!! Not signed in to Claude yet. Run:  claude   (sign in, then /exit)"
  echo "   then re-run this script, or log out and back in."
fi

echo
local FV AUTO
FV=$(fdesetup status 2>/dev/null || true)
AUTO=$(defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser 2>/dev/null || true)
if [ "$AUTO" != "$(id -un)" ]; then
  echo "NOTE: automatic login is not set for $(id -un). After a restart nothing starts"
  echo "      until you log in. Set it in System Settings > Users & Groups."
  case "$FV" in *"On"*) echo "      (FileVault is on, which blocks automatic login.)";; esac
fi
echo "Manage sessions:  claude-live list | add <id> | remove <slug> | attach <slug>"
}

case "$OS" in
  Linux)  install_linux "$@" ;;
  Darwin) install_mac "$@" ;;
  *)      echo "Unsupported system: $OS (Linux and macOS only)"; exit 1 ;;
esac
