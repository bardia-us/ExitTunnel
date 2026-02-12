#!/usr/bin/env bash
set -euo pipefail
# install_qdtunnel.sh
# Quick, robust installer/manager for qdtunnel-like simple HTTP-header tunnel
# Features:
# - interactive server/client setup
# - dependency install with logging and fallback mirror prompt
# - persistent tunnel configs saved to /etc/qdtunnel/tunnels.json
# - create/delete named tunnels (single or all)
# - creates a systemd service per tunnel for easy start/stop/status
# - improved robust input handling (fix numeric-input bug)

LOG="/var/log/qdtunnel/install.log"
BASE_DIR="/opt/qdtunnel"
CONF_DIR="/etc/qdtunnel"
BIN="/usr/local/bin/qdtunnel"
mkdir -p "$BASE_DIR" "$CONF_DIR"
touch "$LOG"
chmod 640 "$LOG"

# safe read function to avoid input weirdness
safe_read() {
  local varname="$1"; shift
  local prompt="$*"
  local val
  while true; do
    printf "%s" "$prompt"
    # use -r to keep backslashes, use IFS= to preserve leading/trailing whitespace if any
    IFS= read -r val || true
    # trim
    val="${val%%$'\r'}"
    if [[ -n "$val" ]]; then
      printf -v "$varname" "%s" "$val"
      return 0
    fi
    echo "مقداری وارد کن."
  done
}

log_and_run() {
  # run command, tee stdout/stderr to log and to terminal
  # usage: log_and_run <cmd...>
  echo "[$(date +'%F %T')] CMD: $*" | tee -a "$LOG"
  # run in subshell to capture both stdout and stderr
  ("$@" ) 2>&1 | tee -a "$LOG"
  return ${PIPESTATUS[0]:-0}
}

jq_installed() {
  command -v jq >/dev/null 2>&1
}

ensure_jq() {
  if ! jq_installed; then
    echo "jq لازم است. تلاش برای نصب با apt..."
    if apt-get update -y >>"$LOG" 2>&1 && apt-get install -y jq >>"$LOG" 2>&1; then
      echo "jq نصب شد." | tee -a "$LOG"
    else
      echo "نصب jq با apt موفق نبود. اگر در داخل ایران هستی، می‌تونی آینه یا آدرس بسته deb را بدهی." | tee -a "$LOG"
      safe_read MIRROR "اگر آینه محلی یا آدرس مستقیم .deb برای jq داری، وارد کن (یا Enter برای رد): "
      if [[ -n "$MIRROR" ]]; then
        echo "درحال دانلود از $MIRROR ..." | tee -a "$LOG"
        log_and_run wget -O /tmp/jq.deb "$MIRROR" || { echo "دانلود ناکام"; exit 1; }
        log_and_run dpkg -i /tmp/jq.deb || apt-get -f install -y >>"$LOG" 2>&1
        rm -f /tmp/jq.deb
      else
        echo "نشد jq را نصب کنیم، ادامه می‌دهیم اما برخی قابلیت‌ها کار نمی‌کنند." | tee -a "$LOG"
      fi
    fi
  fi
}

install_dependencies() {
  echo "در حال بررسی پیش‌نیازها و تلاش نصب..." | tee -a "$LOG"
  PKGS=(socat iptables-persistent jq wget curl)
  # Try apt normally, show logs live
  if log_and_run apt-get update -y && log_and_run apt-get install -y "${PKGS[@]}"; then
    echo "پکیج‌ها نصب شدند." | tee -a "$LOG"
    return 0
  fi

  echo "نصب با apt موفق نبود — ممکن است دسترسی به برخی مخازن قطع باشد." | tee -a "$LOG"
  safe_read ALT "اگر آدرس mirror/آینه apt محلی یا آدرس دایرکت برای دانلود debها داری وارد کن (یا Enter برای رد): "
  if [[ -n "$ALT" ]]; then
    echo "تلاش برای تنظیم موقت mirror..." | tee -a "$LOG"
    # backup and replace sources.list temporarily
    cp -n /etc/apt/sources.list /etc/apt/sources.list.qdtbackup || true
    echo "deb $ALT $(lsb_release -cs) main" >/tmp/qdt-sources.list
    mv /tmp/qdt-sources.list /etc/apt/sources.list
    log_and_run apt-get update -y && log_and_run apt-get install -y "${PKGS[@]}" || {
      echo "با mirror هم نصب نشد. برگشت فایل sources.list" | tee -a "$LOG"
      mv /etc/apt/sources.list.qdtbackup /etc/apt/sources.list || true
    }
  else
    echo "هیچ mirror معرفی نشد — می‌تونی بسته‌ها را دستی دانلود و نصب کنی." | tee -a "$LOG"
  fi
}

# read and validate port number
read_port() {
  local varname="$1"; shift
  local prompt="$*"
  local val
  while true; do
    safe_read val "$prompt"
    if [[ "$val" =~ ^[0-9]+$ ]] && (( val >= 1 && val <= 65535 )); then
      printf -v "$varname" "%s" "$val"
      return 0
    fi
    echo "پورت معتبر نیست، دوباره امتحان کن."
  done
}

# create tunnels metadata store if not exist
TUNNELS_JSON="$CONF_DIR/tunnels.json"
if [[ ! -f "$TUNNELS_JSON" ]]; then
  echo "[]" > "$TUNNELS_JSON"
fi

# helper: list tunnels
list_tunnels() {
  if jq_installed; then
    jq -r '.[] | "\(.name) | role=\(.role) | port=\(.port) | remote=\(.remote // "-") | pid=\(.pid // "-")"' "$TUNNELS_JSON" || true
  else
    cat "$TUNNELS_JSON"
  fi
}

# helper: save tunnel object
save_tunnel() {
  local obj="$1"
  if jq_installed; then
    tmp="$(mktemp)"
    jq --argjson obj "$obj" '. + [$obj]' "$TUNNELS_JSON" > "$tmp" && mv "$tmp" "$TUNNELS_JSON"
  else
    # fallback: append raw JSON line (less ideal)
    echo "$obj" >> "$TUNNELS_JSON"
  fi
}

# helper: remove tunnel by name
remove_tunnel_by_name() {
  local name="$1"
  if jq_installed; then
    tmp="$(mktemp)"
    jq --arg n "$name" 'map(select(.name != $n))' "$TUNNELS_JSON" > "$tmp" && mv "$tmp" "$TUNNELS_JSON"
  else
    # naive fallback
    grep -v "$name" "$TUNNELS_JSON" > "$TUNNELS_JSON.tmp" && mv "$TUNNELS_JSON.tmp" "$TUNNELS_JSON"
  fi
}

# create systemd unit for a tunnel (server/client)
create_unit() {
  local name="$1"; shift
  local cmd="$*"
  local unit="/etc/systemd/system/qdtunnel-${name}.service"
  cat > "$unit" <<EOF
[Unit]
Description=QDTunnel $name
After=network.target

[Service]
Type=simple
ExecStart=$cmd
Restart=always
RestartSec=3
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable "qdtunnel-${name}.service"
}

# remove unit and stop service
remove_unit() {
  local name="$1"
  local unit="/etc/systemd/system/qdtunnel-${name}.service"
  if systemctl is-active --quiet "qdtunnel-${name}.service"; then
    systemctl stop "qdtunnel-${name}.service" || true
  fi
  systemctl disable "qdtunnel-${name}.service" 2>/dev/null || true
  rm -f "$unit"
  systemctl daemon-reload || true
}

# server script template (HTTP-like header then raw pipe to local program or port)
cat > "$BASE_DIR/qdt-server.sh" <<'EOF'
#!/usr/bin/env bash
# usage: qdt-server.sh <listen_port> <target_host> <target_port>   (target_host optional - default localhost)
LISTEN_PORT="$1"
TARGET_HOST="${2:-127.0.0.1}"
TARGET_PORT="${3:-1080}"
# Logging
LOG="/var/log/qdtunnel/server-${LISTEN_PORT}.log"
mkdir -p /var/log/qdtunnel
exec >>"$LOG" 2>&1
echo "server starting on $LISTEN_PORT forwarding to $TARGET_HOST:$TARGET_PORT"
# simple TCP listener: accept connection, read initial data, if looks like HTTP GET then strip header and pipe
while true; do
  # use socat one-liner to accept TCP, run a handler
  socat TCP-LISTEN:${LISTEN_PORT},reuseaddr,fork SYSTEM:"bash -c 'head -n 20 | ( read -r firstline; if [[ \"\$firstline\" == GET* || \"\$firstline\" == POST* ]]; then # look like http\n    # print debug\n    echo \"[qdt] http-like header detected: \$firstline\" >&2\n    # after headers, stream raw data between client and target\n  fi; cat' | socat - TCP:${TARGET_HOST}:${TARGET_PORT}'"
done
EOF

chmod +x "$BASE_DIR/qdt-server.sh"

# client script template
cat > "$BASE_DIR/qdt-client.sh" <<'EOF'
#!/usr/bin/env bash
# usage: qdt-client.sh <server_ip> <server_port> <direct_ports_csv>
SERVER_IP="$1"
SERVER_PORT="$2"
DIRECT_CSV="$3"
LOG="/var/log/qdtunnel/client-${SERVER_PORT}.log"
mkdir -p /var/log/qdtunnel
exec >>"$LOG" 2>&1
echo "client starting, server=$SERVER_IP:$SERVER_PORT direct_ports=$DIRECT_CSV"

# set iptables rules - create chain
iptables -t nat -N QDT_CHAIN_${SERVER_PORT} 2>/dev/null || true
# flush existing
iptables -t nat -F QDT_CHAIN_${SERVER_PORT} 2>/dev/null || true

# allow direct ports to bypass (RETURN)
IFS=',' read -ra PORTS <<< "$DIRECT_CSV"
for p in "${PORTS[@]}"; do
  p="${p// /}"
  if [[ -n "$p" ]]; then
    iptables -t nat -A QDT_CHAIN_${SERVER_PORT} -p tcp --dport "${p}" -j RETURN
  fi
done

# redirect all other tcp to local proxy port (we will run local socat to forward to remote)
LOCAL_REDIRECT_PORT=$((SERVER_PORT + 10000))  # choose an unlikely local redirect port
iptables -t nat -A QDT_CHAIN_${SERVER_PORT} -p tcp -j REDIRECT --to-port "${LOCAL_REDIRECT_PORT}"
# insert PREROUTING jump if not exists
if ! iptables -t nat -C PREROUTING -j QDT_CHAIN_${SERVER_PORT} >/dev/null 2>&1; then
  iptables -t nat -I PREROUTING -j QDT_CHAIN_${SERVER_PORT}
fi

# run local forwarder: listen on LOCAL_REDIRECT_PORT, when connection comes, open TCP to remote server:server_port with HTTP-like header, then pipe data
socat TCP-LISTEN:${LOCAL_REDIRECT_PORT},reuseaddr,fork SYSTEM:"bash -c 'echo -e \"GET /update HTTP/1.1\r\nHost: cdn.microsoft.com\r\nUser-Agent: Mozilla/5.0\r\nConnection: keep-alive\r\n\r\n\"; cat' | socat - TCP:${SERVER_IP}:${SERVER_PORT}"
EOF

chmod +x "$BASE_DIR/qdt-client.sh"

# Main interactive menu
echo "========== QDTUNNEL INSTALLER ==========="
echo "لاگ نصب در: $LOG"
echo ""

install_dependencies
ensure_jq

while true; do
  echo ""
  echo "1) ساخت تونل جدید"
  echo "2) لیست تونل‌ها"
  echo "3) حذف تونل (تک یا همه)"
  echo "4) start/stop/status تونل"
  echo "5) show install log (last 200 lines)"
  echo "0) خروج"
  safe_read choice "انتخاب کن: "
  case "$choice" in
    1)
      echo "ساخت تونل جدید:"
      echo "Server یا Client؟ [s/c]"
      safe_read rc "انتخاب (s/c): "
      if [[ "$rc" =~ ^[sS]$ ]]; then
        role="server"
        read_port TUNNEL_PORT "پورت تونل (مثلا 443 یا 7850): "
        safe_read NAME "اسم تونل بذار (بدون فاصله): "
        safe_read TARGET_HOST "آدرس محلی که روی سرور باید فوروارد کنه (مثلا 127.0.0.1): "
        safe_read TARGET_PORT "پورت محلی هدف (مثلا 1080 یا 80): "
        # create systemd unit with server script
        cmd="$BASE_DIR/qdt-server.sh $TUNNEL_PORT $TARGET_HOST $TARGET_PORT"
        create_unit "$NAME" "$cmd"
        # save metadata
        # build json object
        if jq_installed; then
          obj=$(jq -n --arg name "$NAME" --arg role "$role" --arg port "$TUNNEL_PORT" --arg remote "" --arg target "$TARGET_HOST:$TARGET_PORT" \
            '{name:$name,role:$role,port:$port,remote:$remote,target:$target,pid:null,created:now}')
          tmp="$(mktemp)"
          jq ". + [$obj]" "$TUNNELS_JSON" > "$tmp" && mv "$tmp" "$TUNNELS_JSON"
        fi
        systemctl start "qdtunnel-${NAME}.service"
        echo "سرور تونل $NAME ساخته و اجرا شد."
      else
        role="client"
        safe_read SERVER_IP "IP سرور خارج: "
        read_port TUNNEL_PORT "پورت تونل روی سرور: "
        safe_read DIRECT "پورت‌های دایرکت (مثال: 80,443,8080 یا خالی برای هیچ): "
        safe_read NAME "اسم تونل بذار (بدون فاصله): "
        cmd="$BASE_DIR/qdt-client.sh $SERVER_IP $TUNNEL_PORT \"$DIRECT\""
        create_unit "$NAME" "$cmd"
        if jq_installed; then
          obj=$(jq -n --arg name "$NAME" --arg role "$role" --arg port "$TUNNEL_PORT" --arg remote "$SERVER_IP" --arg target "$DIRECT" \
            '{name:$name,role:$role,port:$port,remote:$remote,target:$target,pid:null,created:now}')
          tmp="$(mktemp)"
          jq ". + [$obj]" "$TUNNELS_JSON" > "$tmp" && mv "$tmp" "$TUNNELS_JSON"
        fi
        systemctl start "qdtunnel-${NAME}.service"
        echo "کلاینت تونل $NAME ساخته و اجرا شد."
      fi
      ;;
    2)
      echo "لیست تونل‌ها:"
      list_tunnels
      ;;
    3)
      echo "حذف تونل — وارد کن 'all' برای حذف همه یا اسم تونل را برای حذف تکی"
      safe_read RNAME "اسم یا all: "
      if [[ "$RNAME" == "all" ]]; then
        echo "تأیید حذف همه؟ (y/N)"
        safe_read conf ">>> "
        if [[ "$conf" =~ ^[yY]$ ]]; then
          # stop and remove units
          if jq_installed; then
            names=$(jq -r '.[].name' "$TUNNELS_JSON")
            for n in $names; do
              remove_unit "$n"
            done
          fi
          rm -f "$TUNNELS_JSON"
          echo "[]">"$TUNNELS_JSON"
          echo "همه تونل‌ها حذف شدند."
        fi
      else
        remove_unit "$RNAME"
        remove_tunnel_by_name "$RNAME"
        echo "تونل $RNAME حذف شد (در صورت موجود بودن)."
      fi
      ;;
    4)
      echo "اسم تونل را وارد کن:"
      safe_read TNAME "name: "
      echo "عمل؟ [start|stop|restart|status|logs]"
      safe_read ACT "action: "
      case "$ACT" in
        start) systemctl start "qdtunnel-${TNAME}.service" && echo "started $TNAME" ;;
        stop) systemctl stop "qdtunnel-${TNAME}.service" && echo "stopped $TNAME" ;;
        restart) systemctl restart "qdtunnel-${TNAME}.service" && echo "restarted $TNAME" ;;
        status) systemctl status "qdtunnel-${TNAME}.service" --no-pager ;;
        logs) journalctl -u "qdtunnel-${TNAME}.service" -n 200 --no-pager ;;
        *) echo "نامشخص" ;;
      esac
      ;;
    5)
      echo "==== last 200 lines of install log ===="
      tail -n 200 "$LOG" || true
      ;;
    0)
      echo "خروج."
      exit 0
      ;;
    *)
      echo "نامعتبر."
      ;;
  esac
done
