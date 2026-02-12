#!/usr/bin/env bash
set -euo pipefail

# ExitTunnel — Single-file installer & manager (Iran / Kharej modes)
# - TCP forwarding (simple, reliable)
# - Interactive menu (1/2) + Enter to go back
# - Named tunnels, JSON metadata, systemd per-tunnel
# - Optional HTTP-like header injection to mimic normal traffic
# - Logs to /var/log/exittunnel/install.log
#
# Usage: sudo bash install.sh
# After install: run `qdtunnel` (installed to /usr/local/bin/qdtunnel)

# ---------------- paths ----------------
BASE_DIR="/opt/exittunnel"
SCRIPTS_DIR="$BASE_DIR/scripts"
CONF_DIR="/etc/exittunnel"
LOG_DIR="/var/log/exittunnel"
INSTALL_LOG="$LOG_DIR/install.log"
TUNNELS_JSON="$CONF_DIR/tunnels.json"
QDT_BIN="/usr/local/bin/qdtunnel"
SERVICE_DIR="/etc/systemd/system"

mkdir -p "$SCRIPTS_DIR" "$CONF_DIR" "$LOG_DIR"
touch "$INSTALL_LOG"
chmod 640 "$INSTALL_LOG"

# redirect script stdout/stderr to log (and to console)
exec > >(tee -a "$INSTALL_LOG") 2>&1

log() { echo "[$(date '+%F %T')] $*"; }

# ---------------- helpers ----------------
safe_read() {
  # safe read: allow empty (user presses Enter) and preserve spaces
  local _varname="$1"; shift
  local _prompt="$*"
  local _val
  printf "%s" "$_prompt"
  IFS= read -r _val || true
  # strip trailing CR if any
  _val="${_val%%$'\r'}"
  printf -v "$_varname" "%s" "$_val"
}

require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "Run as root (sudo)." >&2
    exit 1
  fi
}

ensure_pkg() {
  local pkgs=(socat jq)
  log "Ensuring packages: ${pkgs[*]}"
  if apt-get update -y >>"$INSTALL_LOG" 2>&1 && apt-get install -y "${pkgs[@]}" >>"$INSTALL_LOG" 2>&1; then
    log "Packages installed."
    return 0
  fi
  log "apt install failed. If you're inside a restricted network, you may provide an apt mirror or install packages manually."
  safe_read MIRROR "Mirror URL (apt) to try (or Enter to skip): "
  if [[ -n "$MIRROR" ]]; then
    cp -n /etc/apt/sources.list /etc/apt/sources.list.exitt_backup || true
    echo "deb $MIRROR $(lsb_release -cs) main" >/tmp/exitt_sources.list
    mv /tmp/exitt_sources.list /etc/apt/sources.list
    apt-get update -y >>"$INSTALL_LOG" 2>&1
    apt-get install -y "${pkgs[@]}" >>"$INSTALL_LOG" 2>&1 || {
      log "Mirror install failed; restoring sources.list"
      cp -f /etc/apt/sources.list.exitt_backup /etc/apt/sources.list || true
    }
  fi
}

# initialize json store
init_store() {
  if [[ ! -f "$TUNNELS_JSON" || ! -s "$TUNNELS_JSON" ]]; then
    echo "[]" > "$TUNNELS_JSON"
    chmod 640 "$TUNNELS_JSON"
  fi
}

# add metadata entry via jq; fallback naive append if jq missing
add_tunnel_meta() {
  local meta="$1"
  if command -v jq >/dev/null 2>&1; then
    tmp=$(mktemp)
    jq ". += [ $meta ]" "$TUNNELS_JSON" > "$tmp" && mv "$tmp" "$TUNNELS_JSON"
  else
    # naive: append JSON object to array (not robust, but fallback)
    python3 - <<PY >> /dev/null 2>&1 || true
import json,sys
try:
    f=open("$TUNNELS_JSON")
    arr=json.load(f)
    f.close()
except:
    arr=[]
arr.append($meta)
open("$TUNNELS_JSON","w").write(json.dumps(arr))
PY
  fi
}

remove_tunnel_meta() {
  local name="$1"
  if command -v jq >/dev/null 2>&1; then
    tmp=$(mktemp)
    jq --arg n "$name" 'map(select(.name != $n))' "$TUNNELS_JSON" > "$tmp" && mv "$tmp" "$TUNNELS_JSON"
  else
    # best-effort
    grep -v "\"name\": \"$name\"" "$TUNNELS_JSON" > /tmp/tunnels.json.tmp || true
    mv /tmp/tunnels.json.tmp "$TUNNELS_JSON"
  fi
}

list_tunnels_meta() {
  if command -v jq >/dev/null 2>&1; then
    jq -r '.[] | "• " + .name + " | role=" + .role + " | local=" + (.local_port // "-") + " | remote=" + (.remote_host // "-") + ":" + (.remote_port // "-")' "$TUNNELS_JSON" || echo "(empty)"
  else
    cat "$TUNNELS_JSON"
  fi
}

# create run script wrapper to avoid complex quoting in systemd
write_run_script() {
  local name="$1"
  local script_content="$2"
  local runpath="$SCRIPTS_DIR/run-$name.sh"
  cat > "$runpath" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
SH
  printf "%s\n" "$script_content" >> "$runpath"
  chmod +x "$runpath"
  echo "$runpath"
}

create_systemd_unit() {
  local name="$1"
  local runscript="$2"
  local unit="/etc/systemd/system/exittunnel-${name}.service"
  cat > "$unit" <<EOF
[Unit]
Description=ExitTunnel - ${name}
After=network.target

[Service]
Type=simple
ExecStart=${runscript}
Restart=always
RestartSec=3
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now "exittunnel-${name}.service"
}

# ---------------- add tunnel flow ----------------
add_tunnel_flow() {
  clear
  echo "=== Add Tunnel ==="
  echo "Choose role:"
  echo "1) Iran (client)  — listens locally, forwards to outside server"
  echo "2) Kharej (server) — listens on outside server, forwards to local target"
  safe_read role_choice "Select (1/2, Enter to cancel): "
  if [[ -z "$role_choice" ]]; then
    echo "Cancelled." ; return
  fi
  if [[ "$role_choice" != "1" && "$role_choice" != "2" ]]; then
    echo "Invalid choice."; return
  fi

  safe_read NAME "Tunnel name (no spaces): "
  if [[ -z "$NAME" ]]; then echo "Name required."; return; fi

  if [[ "$role_choice" == "1" ]]; then
    role="client"
    safe_read LOCAL_PORT "Local listen port on IRAN side (e.g. 1080 or 443): "
    safe_read REMOTE_HOST "Outside server IP or host (e.g. 87.248.x.x): "
    safe_read REMOTE_PORT "Outside server port (e.g. 443): "
    # optional header
    safe_read WANT_HDR "Inject HTTP-like header to remote? (y/N): "
    HDR_CMD=""
    if [[ "$WANT_HDR" =~ ^[Yy] ]]; then
      safe_read HDR_HOST "Header Host (e.g. cdn.microsoft.com or varzesh3.ir): "
      safe_read HDR_PATH "Header Path (e.g. /api/v1/update) [default /]: "
      HDR_PATH=${HDR_PATH:-/}
      # build header string for echo -e
      HDR_STR="GET ${HDR_PATH} HTTP/1.1\r\nHost: ${HDR_HOST}\r\nUser-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64)\r\nConnection: keep-alive\r\n\r\n"
      # The run script: listen local, for each connection prepend header then pipe to remote
      read -r -d '' RUN <<'RUN_EOF' || true
# client run script for NAME
LOCAL_PORT='__LOCAL_PORT__'
REMOTE_HOST='__REMOTE_HOST__'
REMOTE_PORT='__REMOTE_PORT__'
HDR_BIN='__HDR_STR__'
# start the socat listener
exec socat TCP-LISTEN:${LOCAL_PORT},reuseaddr,fork SYSTEM:"bash -c 'printf \"%b\" \"${HDR_BIN}\"; cat' | socat - TCP:${REMOTE_HOST}:${REMOTE_PORT}"
RUN_EOF
      RUN="${RUN//__LOCAL_PORT__/$LOCAL_PORT}"
      RUN="${RUN//__REMOTE_HOST__/$REMOTE_HOST}"
      RUN="${RUN//__REMOTE_PORT__/$REMOTE_PORT}"
      # escape HDR_STR for embedding
      HDR_ESCAPED=$(printf '%s' "$HDR_STR" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
      RUN="${RUN//__HDR_STR__/$HDR_ESCAPED}"
    else
      # simple TCP forwarder without header: listen local -> pipe raw to remote
      read -r -d '' RUN <<'RUN_EOF' || true
LOCAL_PORT='__LOCAL_PORT__'
REMOTE_HOST='__REMOTE_HOST__'
REMOTE_PORT='__REMOTE_PORT__'
exec socat TCP-LISTEN:${LOCAL_PORT},reuseaddr,fork TCP:${REMOTE_HOST}:${REMOTE_PORT}
RUN_EOF
      RUN="${RUN//__LOCAL_PORT__/$LOCAL_PORT}"
      RUN="${RUN//__REMOTE_HOST__/$REMOTE_HOST}"
      RUN="${RUN//__REMOTE_PORT__/$REMOTE_PORT}"
    fi

    # write run script and unit
    RUNPATH=$(write_run_script "$NAME" "$RUN")
    create_systemd_unit "$NAME" "$RUNPATH"

    # save metadata
    meta=$(cat <<JSON
{"name":"$NAME","role":"$role","local_port":"$LOCAL_PORT","remote_host":"$REMOTE_HOST","remote_port":"$REMOTE_PORT","header":$(if [[ "$WANT_HDR" =~ ^[Yy] ]]; then printf '%s' "\"$HDR_HOST $HDR_PATH\""; else printf 'null'; fi), "created": "$(date --iso-8601=seconds)"}
JSON
)
    add_tunnel_meta "$meta"
    echo "Client tunnel '$NAME' created."

  else
    role="server"
    safe_read LISTEN_PORT "Listen port on KHAREJ (outside) (e.g. 443): "
    safe_read TARGET_HOST "Local target host on outside server (e.g. 127.0.0.1): "
    safe_read TARGET_PORT "Local target port on outside server (e.g. 1080): "
    # server side: optionally require header check? keep simple: just forward
    read -r -d '' RUN <<'RUN_EOF' || true
LISTEN_PORT='__LISTEN_PORT__'
TARGET_HOST='__TARGET_HOST__'
TARGET_PORT='__TARGET_PORT__'
exec socat TCP-LISTEN:${LISTEN_PORT},reuseaddr,fork TCP:${TARGET_HOST}:${TARGET_PORT}
RUN_EOF
    RUN="${RUN//__LISTEN_PORT__/$LISTEN_PORT}"
    RUN="${RUN//__TARGET_HOST__/$TARGET_HOST}"
    RUN="${RUN//__TARGET_PORT__/$TARGET_PORT}"

    RUNPATH=$(write_run_script "$NAME" "$RUN")
    create_systemd_unit "$NAME" "$RUNPATH"

    meta=$(cat <<JSON
{"name":"$NAME","role":"$role","listen_port":"$LISTEN_PORT","target_host":"$TARGET_HOST","target_port":"$TARGET_PORT","created":"$(date --iso-8601=seconds)"}
JSON
)
    add_tunnel_meta "$meta"
    echo "Server tunnel '$NAME' created."
  fi

  sleep 1
}

# ---------------- remove tunnel ----------------
remove_tunnel_flow() {
  clear
  echo "=== Remove Tunnel ==="
  list_tunnels_meta
  safe_read NAME "Enter tunnel name to remove (or Enter to cancel): "
  if [[ -z "$NAME" ]]; then echo "Cancelled."; return; fi
  # stop and disable
  systemctl stop "exittunnel-${NAME}.service" 2>/dev/null || true
  systemctl disable "exittunnel-${NAME}.service" 2>/dev/null || true
  rm -f "/etc/systemd/system/exittunnel-${NAME}.service" "$SCRIPTS_DIR/run-${NAME}.sh"
  systemctl daemon-reload || true
  remove_tunnel_meta "$NAME"
  echo "Removed tunnel '$NAME'."
  sleep 1
}

# ---------------- list ----------------
list_flow() {
  clear
  echo "=== Tunnels ==="
  list_tunnels_meta
  echo ""
  safe_read _ "Press Enter to go back..."
}

# ---------------- restart ----------------
restart_flow() {
  clear
  echo "=== Restart Tunnel ==="
  list_tunnels_meta
  safe_read NAME "Enter tunnel name to restart (or Enter to cancel): "
  if [[ -z "$NAME" ]]; then echo "Cancelled."; return; fi
  systemctl restart "exittunnel-${NAME}.service"
  echo "Restarted $NAME"
  sleep 1
}

# ---------------- main menu ----------------
require_root
ensure_pkg
init_store

# install CLI helper
cat > "$QDT_BIN" <<'EOF'
#!/usr/bin/env bash
CONF="/etc/exittunnel/tunnels.json"
case "${1:-}" in
  create) sudo bash /opt/exittunnel/manager.sh create ;;
  list)  sudo bash /opt/exittunnel/manager.sh list ;;
  remove) sudo bash /opt/exittunnel/manager.sh remove ;;
  restart) sudo bash /opt/exittunnel/manager.sh restart ;;
  help|"") echo "qdtunnel CLI: create|list|remove|restart"; ;;
  *) echo "unknown"; ;;
esac
EOF
chmod +x "$QDT_BIN"

# write manager script to be callable by qdtunnel and here
cat > "$BASE_DIR/manager.sh" <<'MAN'
#!/usr/bin/env bash
# wrapper to call internal functions in installer file
# this script expects installer to still be present at /opt/exittunnel/installer.sh
if [[ ! -f /opt/exittunnel/installer.sh ]]; then
  echo "installer missing"
  exit 1
fi
# execute the installer in a mode to run manager commands
exec bash /opt/exittunnel/installer.sh manager "$@"
MAN
chmod +x "$BASE_DIR/manager.sh"

# copy this running script into /opt/exittunnel/installer.sh so manager can re-use functions
SCRIPT_PATH="/opt/exittunnel/installer.sh"

# ---------- SAFE SELF-COPY BLOCK (replaces fragile "$0" copy) ----------
# Try to copy from BASH_SOURCE if script was executed from a file.
# If running via a pipe (curl | bash), attempt to read remaining stdin via /proc/$$/fd/0
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
  SRC_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
  cp -f "$SRC_PATH" "$SCRIPT_PATH"
  chmod +x "$SCRIPT_PATH"
  echo "[info] installer copied from $SRC_PATH to $SCRIPT_PATH"
else
  # fallback: try to read stdin from /proc
  if [[ -r "/proc/$$/fd/0" ]]; then
    TMP_SRC="$(mktemp /tmp/exittunnel_installer.XXXXXX.sh)"
    # copy whatever remains on stdin (if any) into temp file
    cat /proc/$$/fd/0 > "$TMP_SRC" || true
    if [[ -s "$TMP_SRC" ]]; then
      cp -f "$TMP_SRC" "$SCRIPT_PATH"
      chmod +x "$SCRIPT_PATH"
      echo "[info] installer written from stdin to $SCRIPT_PATH (temp $TMP_SRC)"
    else
      echo "[error] Could not persist installer: no BASH_SOURCE and stdin empty" >&2
      exit 1
    fi
  else
    echo "[error] Cannot determine script path and no stdin available. Aborting." >&2
    exit 1
  fi
fi
# -----------------------------------------------------------------------

# if installer invoked with 'manager' arg, run only manager CLI
if [[ "${1:-}" == "manager" ]]; then
  cmd="${2:-}"
  case "$cmd" in
    create) add_tunnel_flow ;;
    list) list_flow ;;
    remove) remove_tunnel_flow ;;
    restart) restart_flow ;;
    *) echo "manager commands: create|list|remove|restart" ;;
  esac
  exit 0
fi

# interactive menu loop
while true; do
  clear
  echo "===================================="
  echo "   ExitTunnel — Iran ↔ Kharej (TCP)"
  echo "===================================="
  echo "1) Add Tunnel"
  echo "2) Remove Tunnel"
  echo "3) List Tunnels"
  echo "4) Restart Tunnel"
  echo "5) Exit"
  echo "------------------------------------"
  echo "Press Enter to refresh list."
  echo ""
  # show list
  list_tunnels_meta
  echo "------------------------------------"
  safe_read CH "Choose [1-5] (or Enter): "
  if [[ -z "$CH" ]]; then
    continue
  fi
  case "$CH" in
    1) add_tunnel_flow ;;
    2) remove_tunnel_flow ;;
    3) list_flow ;;
    4) restart_flow ;;
    5) echo "Goodbye."; exit 0 ;;
    *) echo "Invalid"; sleep 1 ;;
  esac
done
