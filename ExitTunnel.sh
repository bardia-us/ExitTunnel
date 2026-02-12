#!/usr/bin/env bash
set -euo pipefail

# ExitTunnel single-file installer (QUIC-based)
# - Interactive (simple menu: 1 Create / 2 Manage)
# - Builds Go-based QUIC server/client
# - Systemd per-tunnel units
# - stores metadata in /etc/exittunnel/tunnels.json
# - Logs in /var/log/exittunnel/install.log

##############################
# Configuration paths
##############################
BASE_DIR="/opt/exittunnel"
BIN_DIR="$BASE_DIR/bin"
SCRIPTS_DIR="$BASE_DIR/scripts"
CONF_DIR="/etc/exittunnel"
LOG_DIR="/var/log/exittunnel"
INSTALL_LOG="$LOG_DIR/install.log"
TUNNELS_JSON="$CONF_DIR/tunnels.json"
QDT_BIN="/usr/local/bin/qdtunnel"

mkdir -p "$BASE_DIR" "$BIN_DIR" "$SCRIPTS_DIR" "$CONF_DIR" "$LOG_DIR"
touch "$INSTALL_LOG"
chmod 640 "$INSTALL_LOG"

log() {
  echo "[$(date +'%F %T')] $*" | tee -a "$INSTALL_LOG"
}

# safe read (preserve blank handling and allow Enter)
safe_read() {
  local varname="$1"; shift
  local prompt="$*"
  local val
  while true; do
    printf "%s" "$prompt"
    IFS= read -r val || true
    val="${val%%$'\r'}"
    # allow empty (to go back) by returning empty if user pressed Enter only
    printf -v "$varname" "%s" "$val"
    return 0
  done
}

read_choice() {
  local prompt="$1"
  local val
  while true; do
    safe_read val "$prompt"
    if [[ -z "$val" ]]; then
      echo ""
      return 0
    fi
    printf "%s" "$val"
    return 0
  done
}

ensure_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "Run as root (sudo)." >&2
    exit 1
  fi
}

ensure_root

log "Starting ExitTunnel installer (QUIC edition)..."

##############################
# Dependencies installer with fallback for restricted networks
##############################
install_deps() {
  log "Installing packages (golang-go, git, build-essential, openssl, jq, iptables-persistent)..."
  PKGS=(golang-go git build-essential openssl jq iptables-persistent curl wget)
  if apt-get update -y >>"$INSTALL_LOG" 2>&1 && apt-get install -y "${PKGS[@]}" >>"$INSTALL_LOG" 2>&1; then
    log "Packages installed via apt."
    return 0
  fi

  log "apt install failed — your network may restrict access. You can provide a local mirror URL or direct .deb links."
  safe_read MIRROR "If you have an apt mirror URL (e.g. http://mirror.example/ubuntu) or Enter to skip: "
  if [[ -n "$MIRROR" ]]; then
    log "Temporarily using mirror $MIRROR"
    cp -n /etc/apt/sources.list /etc/apt/sources.list.exitt_backup || true
    echo "deb $MIRROR $(lsb_release -cs) main" >/tmp/exitt_sources.list
    mv /tmp/exitt_sources.list /etc/apt/sources.list
    apt-get update -y >>"$INSTALL_LOG" 2>&1
    apt-get install -y "${PKGS[@]}" >>"$INSTALL_LOG" 2>&1 || {
      log "Mirror install failed — restoring sources.list."
      cp -f /etc/apt/sources.list.exitt_backup /etc/apt/sources.list || true
    }
  else
    log "Skipping mirror. You may need to manually install packages and re-run installer."
  fi
}

install_deps

##############################
# Write Go server.go and client.go
##############################
log "Writing Go sources..."

cat > "$BASE_DIR/server.go" <<'EOF'
package main

import (
	"crypto/tls"
	"flag"
	"io"
	"log"
	"net"
	"strings"
	"sync"

	quic "github.com/lucas-clemente/quic-go"
)

var (
	certFile string
	keyFile  string
	bindAddr string
	authKey  string
)

func handleStream(s quic.Stream) {
	defer s.Close()
	// read auth token line
	buf := make([]byte, 1024)
	n, err := s.Read(buf)
	if err != nil {
		log.Printf("[stream] auth read err: %v", err)
		return
	}
	payload := buf[:n]
	i := -1
	for idx := 0; idx < len(payload); idx++ {
		if payload[idx] == '\n' {
			i = idx
			break
		}
	}
	if i == -1 {
		log.Println("[stream] no newline after auth")
		return
	}
	token := strings.TrimSpace(string(payload[:i]))
	if token != authKey {
		log.Printf("[stream] invalid token: %s", token)
		return
	}
	rest := payload[i+1:]
	// read destination line
	destBuf := make([]byte, 1024)
	m := 0
	if len(rest) > 0 {
		copy(destBuf, rest)
		m = len(rest)
	}
	for {
		if pos := strings.IndexByte(string(destBuf[:m]), '\n'); pos >= 0 {
			dest := strings.TrimSpace(string(destBuf[:pos]))
			// connect to dest
			targetConn, err := net.Dial("tcp", dest)
			if err != nil {
				log.Printf("[stream] dial target %s err: %v", dest, err)
				return
			}
			defer targetConn.Close()
			after := destBuf[pos+1 : m]
			if len(after) > 0 {
				if _, err := targetConn.Write(after); err != nil {
					log.Printf("[stream] write initial to target err: %v", err)
					return
				}
			}
			var wg sync.WaitGroup
			wg.Add(2)
			go func() {
				defer wg.Done()
				io.Copy(targetConn, s)
			}()
			go func() {
				defer wg.Done()
				io.Copy(s, targetConn)
			}()
			wg.Wait()
			return
		}
		nn, err := s.Read(destBuf[m:])
		if err != nil {
			log.Printf("[stream] read dest err: %v", err)
			return
		}
		m += nn
		if m >= len(destBuf) {
			log.Println("[stream] destination too long")
			return
		}
	}
}

func main() {
	flag.StringVar(&certFile, "cert", "server.pem", "TLS cert file")
	flag.StringVar(&keyFile, "key", "server.key", "TLS key file")
	flag.StringVar(&bindAddr, "bind", ":443", "bind address")
	flag.StringVar(&authKey, "auth", "secret-token", "auth token")
	flag.Parse()

	log.Printf("quic server starting on %s", bindAddr)
	tlsCert, err := tls.LoadX509KeyPair(certFile, keyFile)
	if err != nil {
		log.Fatalf("load cert err: %v", err)
	}
	tlsConf := &tls.Config{
		Certificates: []tls.Certificate{tlsCert},
		NextProtos:   []string{"exittunnel-quic"},
	}
	listener, err := quic.ListenAddr(bindAddr, tlsConf, nil)
	if err != nil {
		log.Fatalf("quic listen err: %v", err)
	}
	for {
		sess, err := listener.Accept()
		if err != nil {
			log.Printf("accept session err: %v", err)
			continue
		}
		go func(sess quic.Session) {
			defer sess.CloseWithError(0, "")
			for {
				stream, err := sess.AcceptStream()
				if err != nil {
					log.Printf("accept stream err: %v", err)
					return
				}
				go handleStream(stream)
			}
		}(sess)
	}
}
EOF

cat > "$BASE_DIR/client.go" <<'EOF'
package main

import (
	"bufio"
	"crypto/tls"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"strings"
	"time"

	quic "github.com/lucas-clemente/quic-go"
)

var (
	serverAddrs string
	authKey     string
	localSocks  string
)

func tryDial(addr string) (quic.Session, error) {
	tlsConf := &tls.Config{
		InsecureSkipVerify: true,
		NextProtos:         []string{"exittunnel-quic"},
	}
	sess, err := quic.DialAddr(addr, tlsConf, nil)
	return sess, err
}

func openStream(sess quic.Session, dest string) (io.ReadWriteCloser, error) {
	stream, err := sess.OpenStreamSync()
	if err != nil {
		return nil, err
	}
	if _, err := stream.Write([]byte(authKey + "\n")); err != nil {
		stream.Close()
		return nil, err
	}
	if _, err := stream.Write([]byte(dest + "\n")); err != nil {
		stream.Close()
		return nil, err
	}
	return stream, nil
}

func socksHandler(conn net.Conn, sess quic.Session) {
	defer conn.Close()
	buf := make([]byte, 262)
	n, err := conn.Read(buf)
	if err != nil {
		return
	}
	if n < 2 || buf[0] != 0x05 {
		return
	}
	conn.Write([]byte{0x05, 0x00})
	n, err = conn.Read(buf)
	if err != nil {
		return
	}
	if buf[0] != 0x05 {
		return
	}
	cmd := buf[1]
	if cmd != 0x01 {
		conn.Write([]byte{0x05, 0x07, 0x00, 0x01, 0,0,0,0, 0,0})
		return
	}
	atype := buf[3]
	var addr string
	if atype == 0x01 {
		ip := net.IPv4(buf[4], buf[5], buf[6], buf[7]).String()
		port := int(buf[8])<<8 | int(buf[9])
		addr = fmt.Sprintf("%s:%d", ip, port)
	} else if atype == 0x03 {
		dlen := int(buf[4])
		domain := string(buf[5:5+dlen])
		port := int(buf[5+dlen])<<8 | int(buf[6+dlen])
		addr = fmt.Sprintf("%s:%d", domain, port)
	} else {
		conn.Write([]byte{0x05, 0x08, 0x00, 0x01, 0,0,0,0, 0,0})
		return
	}
	conn.Write([]byte{0x05, 0x00, 0x00, 0x01, 0,0,0,0, 0,0})
	stream, err := openStream(sess, addr)
	if err != nil {
		return
	}
	defer stream.Close()
	done := make(chan struct{}, 2)
	go func() { io.Copy(stream, conn); done <- struct{}{} }()
	go func() { io.Copy(conn, stream); done <- struct{}{} }()
	<-done
}

func main() {
	flag.StringVar(&serverAddrs, "server", "127.0.0.1:443", "comma-separated server addrs host:port")
	flag.StringVar(&authKey, "auth", "secret-token", "auth token")
	flag.StringVar(&localSocks, "listen", "127.0.0.1:1080", "local socks5 listen")
	flag.Parse()

	addrs := strings.Split(serverAddrs, ",")
	var sess quic.Session
	var err error
	for _, a := range addrs {
		a = strings.TrimSpace(a)
		log.Printf("Trying %s ...", a)
		sess, err = tryDial(a)
		if err == nil {
			break
		}
		log.Printf("Dial %s err: %v", a, err)
	}
	if sess == nil {
		log.Fatalf("All dial attempts failed: %v", err)
	}
	log.Printf("Connected to %s", sess.RemoteAddr())

	ln, err := net.Listen("tcp", localSocks)
	if err != nil {
		log.Fatalf("listen socks err: %v", err)
	}
	log.Printf("socks5 listening on %s", localSocks)
	for {
		c, err := ln.Accept()
		if err != nil {
			log.Printf("accept socks err: %v", err)
			continue
		}
		go socksHandler(c, sess)
	}
}
EOF

log "Go sources written."

##############################
# Build Go binaries
##############################
export GO111MODULE=on
# try to get quic-go via `go get` (may be slow behind restricted nets)
log "Building Go binaries (this may take a minute)..."
pushd "$BASE_DIR" >/dev/null
# init temporary module to get dependency
cat > go.mod <<'EOF'
module exittunnel
go 1.20
require github.com/lucas-clemente/quic-go v0.30.0
EOF

# try build server
if command -v go >/dev/null 2>&1; then
  log "go is available; building..."
  GOPROXY=https://proxy.golang.org go build -o "$BIN_DIR/quic-server" server.go >>"$INSTALL_LOG" 2>&1 || {
    log "go build server failed, trying without GOPROXY..."
    go build -o "$BIN_DIR/quic-server" server.go >>"$INSTALL_LOG" 2>&1 || {
      log "Server build failed. Check $INSTALL_LOG"
      popd >/dev/null
      exit 1
    }
  }
  GOPROXY=https://proxy.golang.org go build -o "$BIN_DIR/quic-client" client.go >>"$INSTALL_LOG" 2>&1 || {
    log "go build client failed, trying without GOPROXY..."
    go build -o "$BIN_DIR/quic-client" client.go >>"$INSTALL_LOG" 2>&1 || {
      log "Client build failed. Check $INSTALL_LOG"
      popd >/dev/null
      exit 1
    }
  }
else
  log "go not installed - cannot build. Install golang and re-run this script."
  popd >/dev/null
  exit 1
fi
popd >/dev/null
log "Binaries built: $BIN_DIR/quic-server and quic-client"

##############################
# qdtunnel management CLI
##############################
cat > "$QDT_BIN" <<'EOF'
#!/usr/bin/env bash
# qdtunnel CLI (QUIC)
CONF="/etc/exittunnel/tunnels.json"
BIN_DIR="/opt/exittunnel/bin"

safe_read() {
  local varname="$1"; shift
  local prompt="$*"
  local val
  while true; do
    printf "%s" "$prompt"
    IFS= read -r val || true
    val="${val%%$'\r'}"
    printf -v "$varname" "%s" "$val"
    return 0
  done
}

list() {
  if command -v jq >/dev/null 2>&1; then
    jq -r '.[] | "\(.name) | \(.role) | port=\(.port) | remote=\(.remote // "-") | auth=\(.auth)"' "$CONF"
  else
    cat "$CONF"
  fi
}

create_server() {
  safe_read NAME "Enter name (no spaces): "
  safe_read PORT "Listen port (e.g. 443): "
  safe_read TARGET "Local target host (default 127.0.0.1): "
  TARGET=${TARGET:-127.0.0.1}
  safe_read TPORT "Local target port (default 1080): "
  TPORT=${TPORT:-1080}
  safe_read AUTH "Auth token (enter for random): "
  if [[ -z "$AUTH" ]]; then
    AUTH=$(head -c 16 /dev/urandom | xxd -p)
  fi
  CERT="/etc/exittunnel/${NAME}.pem"
  KEY="/etc/exittunnel/${NAME}.key"
  if [[ ! -f "$CERT" || ! -f "$KEY" ]]; then
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 -keyout "$KEY" -out "$CERT" -subj "/CN=${NAME}"
  fi
  UNIT="/etc/systemd/system/exittunnel-${NAME}.service"
  CMD="${BIN_DIR}/quic-server -cert ${CERT} -key ${KEY} -bind :${PORT} -auth ${AUTH}"
  cat > "$UNIT" <<EOL
[Unit]
Description=ExitTunnel QUIC server ${NAME}
After=network.target

[Service]
Type=simple
ExecStart=${CMD}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOL
  systemctl daemon-reload
  systemctl enable --now "exittunnel-${NAME}.service"
  # save metadata
  if command -v jq >/dev/null 2>&1; then
    tmp=$(mktemp)
    jq --arg name "$NAME" --arg role "server" --arg port "$PORT" --arg remote "" --arg auth "$AUTH" --arg target "${TARGET}:${TPORT}" \
      '. += [{name:$name,role:$role,port:$port,remote:$remote,auth:$auth,target:$target,created:(now|todate)}]' "$CONF" > "$tmp" && mv "$tmp" "$CONF"
  fi
  echo "Server $NAME created and started."
}

create_client() {
  safe_read NAME "Enter name (no spaces): "
  safe_read SERVER "Server address (comma-separated host:port): "
  safe_read PORT "Server port (just number for metadata): "
  safe_read DIRECT "Direct ports CSV (80,443 or empty): "
  safe_read AUTH "Auth token (must match server) (enter for random): "
  if [[ -z "$AUTH" ]]; then
    AUTH=$(head -c 16 /dev/urandom | xxd -p)
  fi
  LOCAL_SOCKS="127.0.0.1:1080"
  CMD="${BIN_DIR}/quic-client -server ${SERVER} -auth ${AUTH} -listen ${LOCAL_SOCKS}"
  UNIT="/etc/systemd/system/exittunnel-${NAME}.service"
  cat > "$UNIT" <<EOL
[Unit]
Description=ExitTunnel QUIC client ${NAME}
After=network.target

[Service]
Type=simple
ExecStart=${CMD}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOL
  systemctl daemon-reload
  systemctl enable --now "exittunnel-${NAME}.service"

  # setup iptables redirect for direct ports
  CHAIN="EXITT_${NAME}"
  iptables -t nat -N ${CHAIN} 2>/dev/null || true
  iptables -t nat -F ${CHAIN} 2>/dev/null || true
  IFS=',' read -ra PARR <<< "$DIRECT"
  for p in "${PARR[@]}"; do
    [[ -n "$p" ]] && iptables -t nat -A ${CHAIN} -p tcp --dport "$p" -j RETURN
  done
  # redirect to local socks (we use redsocks style, but for simplicity we redirect to socks local port via redsocks is not included)
  # Here we just leave iptables chain; client binary provides a local SOCKS listener.

  if command -v jq >/dev/null 2>&1; then
    tmp=$(mktemp)
    jq --arg name "$NAME" --arg role "client" --arg port "$PORT" --arg remote "$SERVER" --arg auth "$AUTH" --arg target "$DIRECT" \
      '. += [{name:$name,role:$role,port:$port,remote:$remote,auth:$auth,target:$target,created:(now|todate)}]' "$CONF" > "$tmp" && mv "$tmp" "$CONF"
  fi
  echo "Client $NAME created and started. SOCKS5 at 127.0.0.1:1080"
}

remove_tunnel() {
  NAME="$1"
  systemctl stop "exittunnel-${NAME}.service" || true
  systemctl disable "exittunnel-${NAME}.service" || true
  rm -f "/etc/systemd/system/exittunnel-${NAME}.service"
  systemctl daemon-reload || true
  if command -v jq >/dev/null 2>&1; then
    tmp=$(mktemp)
    jq --arg n "$NAME" 'map(select(.name != $n))' "$CONF" > "$tmp" && mv "$tmp" "$CONF"
  fi
  echo "Removed $NAME"
}

case "${1:-}" in
  create)
    echo "Create server or client? (s/c)"
    read -r t
    if [[ "$t" == "s" ]]; then create_server; else create_client; fi
    ;;
  list)
    list
    ;;
  start|stop|restart|status|logs)
    name="$2"
    if [[ -z "$name" ]]; then echo "specify tunnel name"; exit 1; fi
    systemctl "$1" "exittunnel-${name}.service"
    ;;
  remove)
    name="$2"
    if [[ -z "$name" ]]; then echo "specify name or 'all'"; exit 1; fi
    if [[ "$name" == "all" ]]; then
      for n in $(jq -r '.[].name' "$CONF"); do remove_tunnel "$n"; done
    else
      remove_tunnel "$name"
    fi
    ;;
  help|"")
    cat <<EOM
qdtunnel CLI (QUIC)
Usage:
  qdtunnel create
  qdtunnel list
  qdtunnel start <name>
  qdtunnel stop <name>
  qdtunnel restart <name>
  qdtunnel status <name>
  qdtunnel logs <name>
  qdtunnel remove <name|all>
EOM
    ;;
  *)
    echo "unknown cmd"
    ;;
esac
EOF

chmod +x "$QDT_BIN"
log "qdtunnel CLI installed at $QDT_BIN"

##############################
# Ensure tunnels.json exists
##############################
if [[ ! -f "$TUNNELS_JSON" ]]; then
  echo "[]" > "$TUNNELS_JSON"
fi

##############################
# Simple interactive front-end (very small, main menu 1/2)
##############################
main_menu() {
  while true; do
    clear
    echo "================ ExitTunnel (QUIC) ================"
    echo "1) Create tunnel (server/client)"
    echo "2) Manage tunnels (list/start/stop/remove)"
    echo ""
    echo "Press Enter to refresh the list or go back."
    echo "q) Quit"
    echo "--------------------------------------------------"
    echo "Existing tunnels:"
    echo "--------------------------------------------------"
    if command -v jq >/dev/null 2>&1; then
      jq -r '.[] | (" - " + .name + " | " + .role + " | port=" + .port + " | remote=" + (.remote // "-"))' "$TUNNELS_JSON" || true
    else
      cat "$TUNNELS_JSON"
    fi
    echo "--------------------------------------------------"
    printf "Choose (1/2/q): "
    IFS= read -r CH || true
    if [[ -z "$CH" ]]; then
      continue
    fi
    if [[ "$CH" == "q" ]]; then
      break
    fi
    if [[ "$CH" == "1" ]]; then
      $QDT_BIN create
      printf "Press Enter to return to menu..."
      IFS= read -r _ || true
      continue
    fi
    if [[ "$CH" == "2" ]]; then
      manage_menu
      continue
    fi
  done
}

manage_menu() {
  while true; do
    clear
    echo "---- Manage tunnels ----"
    echo "a) List"
    echo "b) Start"
    echo "c) Stop"
    echo "d) Restart"
    echo "e) Status"
    echo "f) Logs"
    echo "g) Remove (single)"
    echo "h) Remove all"
    echo "Enter to go back"
    printf "choice: "
    IFS= read -r C || true
    if [[ -z "$C" ]]; then
      return
    fi
    case "$C" in
      a) $QDT_BIN list; ;;
      b) safe_read NAME "Name: "; systemctl start "exittunnel-${NAME}.service"; echo "started"; ;;
      c) safe_read NAME "Name: "; systemctl stop "exittunnel-${NAME}.service"; echo "stopped"; ;;
      d) safe_read NAME "Name: "; systemctl restart "exittunnel-${NAME}.service"; echo "restarted"; ;;
      e) safe_read NAME "Name: "; systemctl status "exittunnel-${NAME}.service" --no-pager; ;;
      f) safe_read NAME "Name: "; journalctl -u "exittunnel-${NAME}.service" -n 200 --no-pager; ;;
      g) safe_read NAME "Name: "; $QDT_BIN remove "$NAME"; ;;
      h) $QDT_BIN remove all; ;;
      *) echo "unknown"; ;;
    esac
    printf "Press Enter..."
    IFS= read -r _ || true
  done
}

log "Installation complete. Starting interactive menu..."
main_menu

log "Exiting installer. Use 'qdtunnel help' for CLI usage."
