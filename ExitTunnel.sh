#!/bin/bash
set -e

APP_NAME="qdtunnel"
BASE_DIR="/opt/qdtunnel"
BIN_DIR="/usr/local/bin"
SERVICE_DIR="/etc/systemd/system"

mkdir -p $BASE_DIR

echo "========================================"
echo "      Quick & Dirty Tunnel (QDT)       "
echo "========================================"
echo ""
echo "1) Server (خارج)"
echo "2) Client (ایران)"
read -p "انتخاب کن (1 یا 2): " ROLE

if [[ "$ROLE" == "1" ]]; then
  MODE="server"
elif [[ "$ROLE" == "2" ]]; then
  MODE="client"
else
  echo "انتخاب نامعتبر!"
  exit 1
fi

read -p "Port تونل (مثلاً 443 یا 7850): " TUNNEL_PORT

if [[ "$MODE" == "client" ]]; then
  read -p "IP سرور خارج: " SERVER_IP
  read -p "پورت‌های دایرکت (مثلاً 80,443,8080): " DIRECT_PORTS
fi

echo "در حال نصب وابستگی‌ها..."
apt update -y >/dev/null 2>&1
apt install -y socat iptables-persistent >/dev/null 2>&1

# -------- SERVER SCRIPT --------
cat > $BASE_DIR/server.sh << 'EOF'
#!/bin/bash
TUNNEL_PORT="$1"

socat TCP-LISTEN:$TUNNEL_PORT,reuseaddr,fork \
  EXEC:"bash -c 'read -r line; if [[ \"$line\" == GET* ]]; then cat; else echo \"INVALID\"; fi'" \
  | socat - TCP:127.0.0.1:1080
EOF

# -------- CLIENT SCRIPT --------
cat > $BASE_DIR/client.sh << 'EOF'
#!/bin/bash
SERVER_IP="$1"
TUNNEL_PORT="$2"
DIRECT_PORTS="$3"

# پاک‌سازی قوانین قبلی
iptables -t nat -F QDT 2>/dev/null || true
iptables -t nat -N QDT 2>/dev/null || true

# هدایت ترافیک به تونل
for p in $(echo $DIRECT_PORTS | tr "," " "); do
  iptables -t nat -A QDT -p tcp --dport $p -j RETURN
done

iptables -t nat -A QDT -p tcp -j REDIRECT --to-port $TUNNEL_PORT
iptables -t nat -A PREROUTING -j QDT

# اتصال تونل با هدر HTTP-like
socat TCP-LISTEN:$TUNNEL_PORT,reuseaddr,fork \
  EXEC:"bash -c 'echo -e \"GET /api/v1/update HTTP/1.1\r\nHost: cdn.microsoft.com\r\nUser-Agent: Mozilla/5.0\r\nConnection: keep-alive\r\n\r\"; cat'" \
  | socat - TCP:$SERVER_IP:$TUNNEL_PORT
EOF

chmod +x $BASE_DIR/server.sh $BASE_DIR/client.sh

# -------- Systemd Service --------
if [[ "$MODE" == "server" ]]; then
  cat > $SERVICE_DIR/qdtunnel.service <<EOF
[Unit]
Description=Quick Dirty Tunnel Server
After=network.target

[Service]
ExecStart=$BASE_DIR/server.sh $TUNNEL_PORT
Restart=always

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable qdtunnel
  systemctl restart qdtunnel

  echo ""
  echo "✅ Server نصب شد!"
  echo "پورت تونل: $TUNNEL_PORT"

else
  cat > $SERVICE_DIR/qdtunnel.service <<EOF
[Unit]
Description=Quick Dirty Tunnel Client
After=network.target

[Service]
ExecStart=$BASE_DIR/client.sh $SERVER_IP $TUNNEL_PORT \"$DIRECT_PORTS\"
Restart=always

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable qdtunnel
  systemctl restart qdtunnel

  echo ""
  echo "✅ Client نصب شد!"
  echo "سرور: $SERVER_IP"
  echo "پورت تونل: $TUNNEL_PORT"
  echo "پورت‌های دایرکت: $DIRECT_PORTS"
fi

# دستور کنترلی
cat > $BIN_DIR/qdtunnel << 'EOF'
#!/bin/bash
case "$1" in
  start) systemctl start qdtunnel ;;
  stop) systemctl stop qdtunnel ;;
  restart) systemctl restart qdtunnel ;;
  status) systemctl status qdtunnel ;;
  logs) journalctl -u qdtunnel -n 100 --no-pager ;;
  *)
    echo "Usage: qdtunnel {start|stop|restart|status|logs}"
    ;;
esac
EOF

chmod +x $BIN_DIR/qdtunnel

echo ""
echo "برای مدیریت:"
echo "  qdtunnel status"
echo "  qdtunnel logs"
