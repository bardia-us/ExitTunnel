#!/usr/bin/env bash
set -euo pipefail

# ExitTunnel Minimal — single-file installer & manager
# - No apt upgrade; only installs socat and jq (if available)
# - Interactive menu: Iran/Kharej, Add/Remove/List/Restart/Logs/Exit
# - Per-tunnel systemd service and per-tunnel log file
# - Live-tail logs option after creating or from menu
#
# Usage:
#   sudo bash install.sh
# After install you can also run: qdtunnel create|list|remove|restart|logs

# -------- paths --------
BASE_DIR="/opt/exittunnel"
SCRIPTS_DIR="$BASE_DIR/scripts"
CONF_DIR="/etc/exittunnel"
LOG_DIR="/var/log/exittunnel"
INSTALL_LOG="$LOG_DIR/install.log"
TUNNELS_JSON="$CONF_DIR/tunnels.json"
QDT_BIN="/usr/local/bin/qdtunnel"
SERVICE_DIR="/etc/systemd/system"

# ensure dirs
mkdir -p "$SCRIPTS_DIR" "$CONF_DIR" "$LOG_DIR"
touch "$INSTALL_LOG"
chmod 640 "$INSTALL_LOG"

# small logger
log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; echo "[$(date '+%F %T')] $*" >> "$INSTALL_LOG"; }

# safe interactive read from /dev/tty when available (works with curl|bash)
safe_read() {
  local varname="$1"; shift
  local prompt="$*"
  local val=""
  if [[ -e /dev/tty && -r /dev/tty ]]; then
    printf "%s" "$prompt" > /dev/tty
    IFS= read -r val < /dev/tty || true
  else
    printf "%s" "$prompt"
    IFS= read -r val || true
  fi
  val="${val%%$'\r'}"
  printf -v "$varname" "%s" "$val"
}

require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "Run as root (sudo)." >&2
    exit 1
  fi
}

# install minimal packages (no upgrade). Log output to install log but keep console short.
install_deps() {
  log "Installing dependencies (socat jq) — no apt upgrade."
  # try install and capture output in install log
  if apt-get update -y >>"$INSTALL_LOG" 2>&1 && apt-get install -y socat jq >>"$INSTALL_LOG" 2>&1; then
    log "Packages installed (socat jq)."
    return 0
  fi
  log "apt install failed or partial — you can provide a mirror or install manually."
  safe_read MIRROR "If you have an apt mirror URL to try, enter it (or Enter to skip): "
  if [[ -n "$MIRROR" ]]; then
    cp -n /etc/apt/sources.list /etc/apt/sources.list.exitt_backup || true
    echo "deb $MIRROR $(lsb_release -cs) main" >/tmp/exitt_sources.list
    mv /tmp/exitt_sources.list /etc/apt/sources.list
    apt-get update -y >>"$INSTALL_LOG" 2>&1 || true
    apt-get install -y socat jq >>"$INSTALL_LOG" 2>&1 || true
    log "Tried mirror. Check $INSTALL_LOG for details."
    cp -f /etc/apt/sources.list.exitt_backup /etc/apt/sources.list || true
  fi
}

# JSON store helpers
init_store() {
  if [[ ! -f "$TUNNELS_JSON" || ! -s "$TUNNELS_JSON" ]]; then
    echo "[]" > "$TUNNELS_JSON"
    chmod 640 "$TUNNELS_JSON"
  fi
}

add_tunnel_meta() {
  local meta="$1"
  if command -v jq >/dev/null 2>&1; then
    tmp=$(mktemp)
    jq ". += [ $meta ]" "$TUNNELS_JSON" > "$tmp" && mv "$tmp" "$TUNNELS_JSON"
  else
    # safe python fallback
    python3 - <<PY >>"$INSTALL_LOG" 2>&1 || true
import json
f="$TUNNELS_JSON"
try:
  a=json.load(open(f))
except:
  a=[]
a.append($meta)
open(f,"w").write(json.dumps(a))
PY
  fi
}

remove_tunnel_meta() {
  local name="$1"
  if command -v jq >/dev/null 2>&1; then
    tmp=$(mktemp)
    jq --arg n "$name" 'map(select(.name != $n))' "$TUNNELS_JSON" > "$tmp" && mv "$tmp" "$TUNNELS_JSON"
  else
    grep -v "\"name\": \"$name\"" "$TUNNELS_JSON" > /tmp/tun.tmp || true
    mv /tmp/tun.tmp "$TUNNELS_JSON" || true
  fi
}

list_tunnels_meta() {
  if command -v jq >/dev/null 2>&1; then
    jq -r '.[] | "• " + .name + " | role=" + .role + " | local=" + (.local_port // "-") + " | remote=" + (.remote_host // "-") + ":" + (.remote_port // "-")' "$TUNNELS_JSON" || echo "(empty)"
  else
    cat "$TUNNELS_JSON"
  fi
}

# write run script with its own log (so user can tail the file)
write_run_script() {
  local name="$1"; local content="$2"
  local runpath="$SCRIPTS_DIR/run-$name.sh"
  cat > "$runpath" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
SH
  # add log redirect at top of run script
  local runlog="$LOG_DIR/$name.log"
  printf "exec >>\"%s\" 2>&1\n" "$runlog" >> "$runpath"
  printf "%s\n" "$content" >> "$runpath"
  chmod +x "$runpath"
  echo "$runpath"
}

create_systemd_unit_and_start() {
  local name="$1"; local runpath="$2"
  local unit="/etc/systemd/system/exittunnel-${name}.service"
  cat > "$unit" <<EOF
[Unit]
Description=ExitTunnel - ${name}
After=network.target

[Service]
Type=simple
ExecStart=/bin/bash ${runpath}
Restart=always
RestartSec=3
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now "exittunnel-${name}.service"
  sleep 0.4
}

# create client (Iran side) or server (Kharej side)
add_tunnel_flow() {
  clear
  echo "=== Add Tunnel ==="
  echo "1) Iran (client) — listens locally, forwards to outside"
  echo "2) Kharej (server) — listens on outside server, forwards locally"
  safe_read ROLE "Select role (1/2, Enter to cancel): "
  if [[ -z "$ROLE" ]]; then echo "Cancelled."; return; fi
  if [[ "$ROLE" != "1" && "$ROLE" != "2" ]]; then echo "Invalid."; return; fi

  safe_read NAME "Tunnel name (no spaces): "
  if [[ -z "$NAME" ]]; then echo "Name required."; return; fi

  if [[ "$ROLE" == "1" ]]; then
    # client (Iran)
    safe_read LOCAL_PORT "Local listen port on IRAN (e.g. 1080 or 443): "
    safe_read REMOTE_HOST "Outside server IP/host (e.g. 87.248.x.x): "
    safe_read REMOTE_PORT "Outside server port (e.g. 443): "
    safe_read WANT_HDR "Inject HTTP-like header to remote? (y/N): "
    if [[ "$WANT_HDR" =~ ^[Yy] ]]; then
      safe_read HDR_HOST "Header Host (e.g. cdn.microsoft.com): "
      safe_read HDR_PATH "Header Path (e.g. /api/v1/update) [default /]: "
      HDR_PATH=${HDR_PATH:-/}
      HDR_STR=$(printf 'printf "GET %s HTTP/1.1\\r\\nHost: %s\\r\\nUser-Agent: Mozilla/5.0\\r\\nConnection: keep-alive\\r\\n\\r\\n"' "$HDR_PATH" "$HDR_HOST")
      # run content: for each conn, send header then stream
      read -r -d '' RUN <<'RUN_EOF' || true
LOCAL_PORT='__LOCAL__'
REMOTE_HOST='__REMOTE__'
REMOTE_PORT='__RPORT__'
# socat: for each incoming, run a tiny shell that prints header then streams
exec socat TCP-LISTEN:${LOCAL_PORT},reuseaddr,fork SYSTEM:"bash -c '$HDR_CMD; cat' | socat - TCP:${REMOTE_HOST}:${REMOTE_PORT}"
RUN_EOF
      RUN="${RUN//__LOCAL__/$LOCAL_PORT}"
      RUN="${RUN//__REMOTE__/$REMOTE_HOST}"
      RUN="${RUN//__RPORT__/$REMOTE_PORT}"
      # substitute HDR_CMD safely (unquote later)
      RUN="${RUN//\$HDR_CMD/$HDR_STR}"
    else
      # simple forward
      read -r -d '' RUN <<'RUN_EOF' || true
LOCAL_PORT='__LOCAL__'
REMOTE_HOST='__REMOTE__'
REMOTE_PORT='__RPORT__'
exec socat TCP-LISTEN:${LOCAL_PORT},reuseaddr,fork TCP:${REMOTE_HOST}:${REMOTE_PORT}
RUN_EOF
      RUN="${RUN//__LOCAL__/$LOCAL_PORT}"
      RUN="${RUN//__REMOTE__/$REMOTE_HOST}"
      RUN="${RUN//__RPORT__/$REMOTE_PORT}"
    fi

    RUNPATH=$(write_run_script "$NAME" "$RUN")
    create_systemd_unit_and_start "$NAME" "$RUNPATH"

    meta=$(cat <<JSON
{"name":"$NAME","role":"client","local_port":"$LOCAL_PORT","remote_host":"$REMOTE_HOST","remote_port":"$REMOTE_PORT","header":$(if [[ "$WANT_HDR" =~ ^[Yy] ]]; then printf '%s' "\"$HDR_HOST $HDR_PATH\""; else printf 'null'; fi), "created":"$(date --iso-8601=seconds)"}
JSON
)
    add_tunnel_meta "$meta"
    log "Client tunnel '$NAME' created."

    safe_read SHOW "Show live logs now? (Y/n): "
    if [[ -z "$SHOW" || "$SHOW" =~ ^[Yy] ]]; then
      log "Tailing log for $NAME — press Ctrl-C to stop."
      # prefer tail -f on run log file
      tail -n 200 -f "$LOG_DIR/$NAME.log" || true
    fi

  else
    # server (Kharej)
    safe_read LISTEN_PORT "Listen port on KHAREJ (outside) (e.g. 443): "
    safe_read TARGET_HOST "Target host on outside server (e.g. 127.0.0.1): "
    safe_read TARGET_PORT "Target port on outside server (e.g. 1080): "

    read -r -d '' RUN <<'RUN_EOF' || true
LISTEN_PORT='__LP__'
TARGET_HOST='__TH__'
TARGET_PORT='__TP__'
exec socat TCP-LISTEN:${LISTEN_PORT},reuseaddr,fork TCP:${TARGET_HOST}:${TARGET_PORT}
RUN_EOF
    RUN="${RUN//__LP__/$LISTEN_PORT}"
    RUN="${RUN//__TH__/$TARGET_HOST}"
    RUN="${RUN//__TP__/$TARGET_PORT}"

    RUNPATH=$(write_run_script "$NAME" "$RUN")
    create_systemd_unit_and_start "$NAME" "$RUNPATH"

    meta=$(cat <<JSON
{"name":"$NAME","role":"server","listen_port":"$LISTEN_PORT","target_host":"$TARGET_HOST","target_port":"$TARGET_PORT","created":"$(date --iso-8601=seconds)"}
JSON
)
    add_tunnel_meta "$meta"
    log "Server tunnel '$NAME' created."

    safe_read SHOW "Show live logs now? (Y/n): "
    if [[ -z "$SHOW" || "$SHOW" =~ ^[Yy] ]]; then
      log "Tailing log for $NAME — press Ctrl-C to stop."
      tail -n 200 -f "$LOG_DIR/$NAME.log" || true
    fi
  fi
}

remove_tunnel_flow() {
  clear
  echo "=== Remove Tunnel ==="
  list_tunnels_meta
  safe_read NAME "Enter tunnel name to remove (or Enter to cancel): "
  if [[ -z "$NAME" ]]; then echo "Cancelled."; return; fi
  systemctl stop "exittunnel-${NAME}.service" 2>/dev/null || true
  systemctl disable "exittunnel-${NAME}.service" 2>/dev/null || true
  rm -f "/etc/systemd/system/exittunnel-${NAME}.service" "$SCRIPTS_DIR/run-${NAME}.sh"
  systemctl daemon-reload || true
  remove_tunnel_meta "$NAME"
  log "Removed tunnel '$NAME'."
  sleep 1
}

list_flow() {
  clear
  echo "=== Tunnels ==="
  list_tunnels_meta
  echo ""
  safe_read _ "Press Enter to go back..."
}

restart_flow() {
  clear
  echo "=== Restart Tunnel ==="
  list_tunnels_meta
  safe_read NAME "Enter tunnel name to restart (or Enter to cancel): "
  if [[ -z "$NAME" ]]; then echo "Cancelled."; return; fi
  systemctl restart "exittunnel-${NAME}.service"
  log "Restarted $NAME"
  sleep 1
}

logs_flow() {
  clear
  echo "=== Logs ==="
  list_tunnels_meta
  safe_read NAME "Enter tunnel name to view logs (or Enter to cancel): "
  if [[ -z "$NAME" ]]; then echo "Cancelled."; return; fi
  runlog="$LOG_DIR/$NAME.log"
  if [[ -f "$runlog" ]]; then
    log "Showing file log: $runlog (Ctrl-C to stop)"
    tail -n 200 -f "$runlog" || true
  else
    log "No file log found; showing journalctl for service (Ctrl-C to stop)"
    journalctl -u "exittunnel-${NAME}.service" -n 200 -f || true
  fi
}

# CLI helper installed to /usr/local/bin/qdtunnel
install_cli() {
  cat > "$QDT_BIN" <<'EOF'
#!/usr/bin/env bash
CONF="/etc/exittunnel/tunnels.json"
case "${1:-}" in
  create) sudo bash /opt/exittunnel/installer.sh manager create ;;
  list) sudo bash /opt/exittunnel/installer.sh manager list ;;
  remove) sudo bash /opt/exittunnel/installer.sh manager remove ;;
  restart) sudo bash /opt/exittunnel/installer.sh manager restart ;;
  logs) sudo bash /opt/exittunnel/installer.sh manager logs ;;
  help|"") echo "qdtunnel CLI: create|list|remove|restart|logs" ;;
  *) echo "unknown" ;;
esac
EOF
  chmod +x "$QDT_BIN"
  log "Installed CLI helper at $QDT_BIN"
}

# create manager wrapper
install_manager_wrapper() {
  cat > "$BASE_DIR/manager.sh" <<'MAN'
#!/usr/bin/env bash
if [[ ! -f /opt/exittunnel/installer.sh ]]; then
  echo "installer missing"
  exit 1
fi
exec bash /opt/exittunnel/installer.sh manager "$@"
MAN
  chmod +x "$BASE_DIR/manager.sh"
}

# safe persist of installer to /opt/exittunnel/installer.sh
persist_installer_self() {
  SCRIPT_PATH="/opt/exittunnel/installer.sh"
  if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    SRC_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
    cp -f "$SRC_PATH" "$SCRIPT_PATH"
    chmod +x "$SCRIPT_PATH"
    log "Installer copied from $SRC_PATH to $SCRIPT_PATH"
  else
    # try to read remaining stdin safely (only if executed via pipe)
    if [[ -r "/proc/$$/fd/0" ]]; then
      TMP_SRC="$(mktemp /tmp/exittunnel_installer.XXXXXX.sh)"
      # copy stdin to temp
      cat /proc/$$/fd/0 > "$TMP_SRC" || true
      if [[ -s "$TMP_SRC" ]]; then
        cp -f "$TMP_SRC" "$SCRIPT_PATH"
        chmod +x "$SCRIPT_PATH"
        log "Installer written from stdin to $SCRIPT_PATH (temp $TMP_SRC)"
      else
        log "ERROR: Could not persist installer: no BASH_SOURCE and stdin empty"
        # not fatal; continue (manager will not work if persisted copy missing)
      fi
    else
      log "ERROR: Cannot determine script path and no stdin available."
    fi
  fi
}

# manager command dispatcher (used by qdtunnel CLI)
if [[ "${1:-}" == "manager" ]]; then
  cmd="${2:-}"
  case "$cmd" in
    create) add_tunnel_flow ;;
    list) list_flow ;;
    remove) remove_tunnel_flow ;;
    restart) restart_flow ;;
    logs) logs_flow ;;
    *) echo "manager commands: create|list|remove|restart|logs" ;;
  esac
  exit 0
fi

# ---------- main ----------

require_root
install_deps
init_store
install_cli
install_manager_wrapper
persist_installer_self

# interactive menu
while true; do
  clear
  echo "===================================="
  echo "   ExitTunnel — Iran ↔ Kharej (TCP)"
  echo "===================================="
  echo "1) Add Tunnel"
  echo "2) Remove Tunnel"
  echo "3) List Tunnels"
  echo "4) Restart Tunnel"
  echo "5) Logs"
  echo "6) Exit"
  echo "------------------------------------"
  echo "Press Enter to refresh list."
  echo ""
  list_tunnels_meta
  printf "\n"
  safe_read CH "Choose [1-6] (or Enter): "
  if [[ -z "$CH" ]]; then
    continue
  fi
  case "$CH" in
    1) add_tunnel_flow ;;
    2) remove_tunnel_flow ;;
    3) list_flow ;;
    4) restart_flow ;;
    5) logs_flow ;;
    6) echo "Goodbye."; exit 0 ;;
    *) echo "Invalid"; sleep 1 ;;
  esac
done
