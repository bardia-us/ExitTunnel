#!/bin/bash

# ==========================================
# GoTunnel Enterprise v3.0 - CLI Edition
# ==========================================

if [ "$EUID" -ne 0 ]; then
  echo -e "\e[31m❌ Please run as root (sudo bash install.sh)\e[0m"
  exit
fi

# ------------------------------------------
# 0. مکانیزم نصب خودکار (تبدیل به دستور سیستم)
# ------------------------------------------
INSTALL_PATH="/usr/local/bin/gotunnel"

if [[ "$(realpath "$0")" != "$INSTALL_PATH" ]]; then
    echo -e "\e[33m[*] Installing 'gotunnel' as a global command...\e[0m"
    cp "$0" "$INSTALL_PATH"
    chmod +x "$INSTALL_PATH"
    echo -e "\e[32m[+] Installation complete! You can now just type 'gotunnel' from anywhere.\e[0m"
    sleep 2
fi

DIR="/opt/gotunnel"
BIN="$DIR/gotunnel-core"
GO_FILE="$DIR/main.go"

mkdir -p $DIR

# ------------------------------------------
# 1. نصب وابستگی‌ها و کامپایل هسته
# ------------------------------------------
setup_core() {
    if [ ! -f "$BIN" ]; then
        echo -e "\e[33m[*] Checking dependencies and compiling core...\e[0m"
        if ! command -v go &> /dev/null; then
            apt-get update -y && apt-get install golang -y
        fi

        cat << 'EOF' > $GO_FILE
package main

import (
	"bufio"
	"flag"
	"io"
	"log"
	"net"
	"strings"
	"sync"
	"time"
)

var (
	mode       = flag.String("mode", "server", "server or bridge")
	listenAddr = flag.String("listen", ":8279", "Listen address")
	remoteAddr = flag.String("remote", "127.0.0.1:9277", "Remote address")
	secret     = flag.String("secret", "SecretKey123", "Auth token")
	poolSize   = flag.Int("pool", 50, "Pre-established pool size")
	maxConns   = flag.Int("maxconn", 1000, "Max concurrent connections")
	timeout    = flag.Duration("timeout", 10*time.Second, "Dial timeout")

	bufferPool = sync.Pool{New: func() interface{} { return make([]byte, 32*1024) }}
	connPool   chan net.Conn
	sem        chan struct{} 
)

func tuneTCP(conn net.Conn) {
	if tcpConn, ok := conn.(*net.TCPConn); ok {
		tcpConn.SetNoDelay(true)
		tcpConn.SetKeepAlive(true)
		tcpConn.SetKeepAlivePeriod(30 * time.Second)
	}
}

func main() {
	flag.Parse()
	log.SetFlags(log.Ldate | log.Ltime | log.Lmicroseconds)
	
	sem = make(chan struct{}, *maxConns)
	log.Printf("Starting [%s] | Listen: %s | Target: %s", strings.ToUpper(*mode), *listenAddr, *remoteAddr)

	listener, err := net.Listen("tcp", *listenAddr)
	if err != nil {
		log.Fatalf("Failed to listen: %v", err)
	}
	defer listener.Close()

	if *mode == "bridge" {
		connPool = make(chan net.Conn, *poolSize)
		go maintainPool()
	}

	for {
		conn, err := listener.Accept()
		if err != nil {
			continue
		}
		tuneTCP(conn)
		select {
		case sem <- struct{}{}:
			if *mode == "server" {
				go func() { defer func() { <-sem }(); handleServer(conn) }()
			} else {
				go func() { defer func() { <-sem }(); handleBridge(conn) }()
			}
		default:
			log.Printf("Connection dropped: Max limits")
			conn.Close()
		}
	}
}

func dialRemote() (net.Conn, error) {
	targetConn, err := net.DialTimeout("tcp", *remoteAddr, *timeout)
	if err == nil {
		tuneTCP(targetConn)
		targetConn.Write([]byte(*secret + "\n"))
	}
	return targetConn, err
}

func handleServer(clientConn net.Conn) {
	defer clientConn.Close()
	clientConn.SetReadDeadline(time.Now().Add(5 * time.Second)) 
	reader := bufio.NewReader(clientConn)
	token, err := reader.ReadString('\n')
	if err != nil || strings.TrimSpace(token) != *secret {
		return
	}
	clientConn.SetReadDeadline(time.Time{}) 

	targetConn, err := dialRemote()
	if err != nil {
		return
	}
	defer targetConn.Close()
	bridgeTraffic(clientConn, targetConn)
}

func maintainPool() {
	for {
		if len(connPool) < *poolSize {
			targetConn, err := dialRemote()
			if err == nil {
				connPool <- targetConn
			} else {
				time.Sleep(2 * time.Second)
			}
		} else {
			time.Sleep(500 * time.Millisecond)
		}
	}
}

func handleBridge(localConn net.Conn) {
	defer localConn.Close()
	var remoteConn net.Conn
	var err error

	select {
	case remoteConn = <-connPool:
	default:
		log.Printf("Pool empty! Direct dial fallback...")
		remoteConn, err = dialRemote()
		if err != nil {
			return
		}
	}
	defer remoteConn.Close()
	bridgeTraffic(localConn, remoteConn)
}

func bridgeTraffic(conn1, conn2 net.Conn) {
	var wg sync.WaitGroup
	wg.Add(2)
	copyFunc := func(dst io.WriteCloser, src io.Reader) {
		defer wg.Done()
		buf := bufferPool.Get().([]byte)
		defer bufferPool.Put(buf)
		io.CopyBuffer(dst, src, buf)
		dst.Close()
	}
	go copyFunc(conn1, conn2)
	go copyFunc(conn2, conn1)
	wg.Wait()
}
EOF
        cd $DIR
        go build -o $BIN $GO_FILE
        echo -e "\e[32m[+] Core compiled!\e[0m"
        sleep 1
    fi
}

# ------------------------------------------
# 2. منوی اصلی برنامه
# ------------------------------------------
show_menu() {
    clear
    echo -e "\e[36m=========================================\e[0m"
    echo -e "\e[1m        GoTunnel Global Manager        \e[0m"
    echo -e "\e[36m=========================================\e[0m"
    echo " 1) 🟢 Create New Tunnel"
    echo " 2) 🛠️  My Tunnels (Manage / Delete)"
    echo " 3) 📊 Status (Monitor & Logs)"
    echo " 4) 🗑️  Uninstall GoTunnel"
    echo " 0) ❌ Exit"
    echo -e "\e[36m=========================================\e[0m"
    read -p "Select an option: " choice

    case $choice in
        1) create_tunnel ;;
        2) my_tunnels ;;
        3) monitor_tunnels ;;
        4) uninstall_all ;;
        0) exit 0 ;;
        *) echo "Invalid option!"; sleep 1; show_menu ;;
    esac
}

# ------------------------------------------
# 3. ساخت تانل جدید
# ------------------------------------------
create_tunnel() {
    echo -e "\n\e[33m--- Create Tunnel ---\e[0m"
    read -p "Select Mode (1=Server/Exit, 2=Bridge/Client): " mode_num

    if [ "$mode_num" == "1" ]; then
        MODE="server"
        read -p "Tunnel Listen Port (e.g., 8279): " LISTEN_PORT
        read -p "Forward to IP:Port (e.g., 127.0.0.1:9277): " TARGET_ADDR
    else
        MODE="bridge"
        read -p "Local Listen Port (e.g., 9277): " LISTEN_PORT
        read -p "Remote Server IP:Port (e.g., 1.1.1.1:8279): " TARGET_ADDR
    fi

    read -p "Enter Secret Key (e.g., MySecret123): " SECRET_KEY
    read -p "Max Concurrent Connections (Default: 1000): " MAX_CONN
    MAX_CONN=${MAX_CONN:-1000}

    SVC_NAME="gotunnel-${MODE}-${LISTEN_PORT}"
    
    cat <<EOF > /etc/systemd/system/${SVC_NAME}.service
[Unit]
Description=GoTunnel $MODE on $LISTEN_PORT
After=network.target

[Service]
Type=simple
ExecStart=$BIN -mode $MODE -listen :$LISTEN_PORT -remote $TARGET_ADDR -secret $SECRET_KEY -maxconn $MAX_CONN
Restart=always
RestartSec=3
LimitNOFILE=100000

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now ${SVC_NAME}.service
    echo -e "\e[32m[+] Tunnel $SVC_NAME running successfully!\e[0m"
    read -p "Press Enter to return..."
    show_menu
}

# ------------------------------------------
# 4. تانل‌های من (مشاهده و حذف)
# ------------------------------------------
my_tunnels() {
    echo -e "\n\e[33m--- My Tunnels ---\e[0m"
    tunnels=($(ls /etc/systemd/system/gotunnel-*.service 2>/dev/null | awk -F'/' '{print $5}' | sed 's/.service//'))
    
    if [ ${#tunnels[@]} -eq 0 ]; then
        echo -e "\e[31mNo active tunnels found.\e[0m"
        read -p "Press Enter to return..."
        show_menu
    fi

    echo "List of installed tunnels:"
    for i in "${!tunnels[@]}"; do
        echo "  $((i+1)). ${tunnels[$i]}"
    done
    echo "-----------------------------------"
    read -p "Enter tunnel number to DELETE (or 0 to go back): " del_idx

    if [[ "$del_idx" -gt 0 && "$del_idx" -le "${#tunnels[@]}" ]]; then
        SVC_TO_DEL="${tunnels[$((del_idx-1))]}"
        systemctl stop $SVC_TO_DEL
        systemctl disable $SVC_TO_DEL
        rm -f /etc/systemd/system/${SVC_TO_DEL}.service
        systemctl daemon-reload
        echo -e "\e[32m[-] Tunnel $SVC_TO_DEL deleted permanently.\e[0m"
    fi
    sleep 1; show_menu
}

# ------------------------------------------
# 5. وضعیت تانل‌ها و مانیتورینگ
# ------------------------------------------
monitor_tunnels() {
    echo -e "\n\e[33m--- Active Tunnels Status ---\e[0m"
    tunnels=($(ls /etc/systemd/system/gotunnel-*.service 2>/dev/null | awk -F'/' '{print $5}' | sed 's/.service//'))
    
    printf "%-25s %-12s %-12s\n" "TUNNEL" "STATUS" "CONNS"
    echo "---------------------------------------------------"
    
    for tun in "${tunnels[@]}"; do
        STATUS=$(systemctl is-active $tun)
        PORT=$(echo $tun | awk -F'-' '{print $3}')
        CONNS=$(ss -tn | grep ":$PORT " | wc -l)
        
        if [ "$STATUS" == "active" ]; then
            printf "%-25s \e[32m%-12s\e[0m %-12s\n" "$tun" "Running" "$CONNS active"
        else
            printf "%-25s \e[31m%-12s\e[0m %-12s\n" "$tun" "Stopped" "-"
        fi
    done
    
    echo -e "\n\e[36m[TIP] To view live logs, run this outside the menu:\e[0m"
    echo "journalctl -u gotunnel-<mode>-<port> -f"
    read -p "Press Enter to return..."
    show_menu
}

# ------------------------------------------
# 6. حذف کامل (Uninstall)
# ------------------------------------------
uninstall_all() {
    echo -e "\n\e[31m⚠️  WARNING: This will delete ALL tunnels and the 'gotunnel' command.\e[0m"
    read -p "Are you sure? (y/N): " confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        echo "Stopping all services..."
        rm -f /etc/systemd/system/gotunnel-*.service
        systemctl daemon-reload
        
        echo "Removing core files and command..."
        rm -rf /opt/gotunnel
        rm -f /usr/local/bin/gotunnel
        
        echo -e "\e[32m[+] GoTunnel completely uninstalled! Bye 👋\e[0m"
        exit 0
    else
        echo "Aborted."
        sleep 1; show_menu
    fi
}

# اجرای سیستم
setup_core
show_menu
