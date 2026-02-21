#!/bin/bash

# ==========================================
# GoTunnel Enterprise - All-in-One Manager
# ==========================================

DIR="/opt/gotunnel"
BIN="$DIR/gotunnel-core"
GO_FILE="$DIR/main.go"

mkdir -p $DIR

# ------------------------------------------
# 1. نصب Go و کامپایل سورس کد (فقط بار اول)
# ------------------------------------------
setup_core() {
    if [ ! -f "$BIN" ]; then
        echo -e "\e[33m[*] Installing dependencies and compiling core...\e[0m"
        if ! command -v go &> /dev/null; then
            apt-get update -y && apt-get install golang -y
        fi

        # جاسازی کدهای Go به صورت مستقیم داخل اسکریپت
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
	poolSize   = flag.Int("pool", 20, "Pool size")

	bufferPool = sync.Pool{New: func() interface{} { return make([]byte, 32*1024) }}
	connPool   chan net.Conn
)

func main() {
	flag.Parse()
	log.Printf("Starting [%s] Mode | Listen: %s | Target: %s", strings.ToUpper(*mode), *listenAddr, *remoteAddr)

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
		if tcpConn, ok := conn.(*net.TCPConn); ok {
			tcpConn.SetNoDelay(true)
			tcpConn.SetKeepAlive(true)
		}
		if *mode == "server" {
			go handleServer(conn)
		} else {
			go handleBridge(conn)
		}
	}
}

func handleServer(clientConn net.Conn) {
	defer clientConn.Close()
	reader := bufio.NewReader(clientConn)
	token, _ := reader.ReadString('\n')
	if strings.TrimSpace(token) != *secret {
		return
	}
	targetConn, err := net.DialTimeout("tcp", *remoteAddr, 5*time.Second)
	if err != nil {
		return
	}
	defer targetConn.Close()
	bridgeTraffic(clientConn, targetConn)
}

func maintainPool() {
	for {
		targetConn, err := net.DialTimeout("tcp", *remoteAddr, 5*time.Second)
		if err == nil {
			if tcpConn, ok := targetConn.(*net.TCPConn); ok {
				tcpConn.SetNoDelay(true)
				tcpConn.SetKeepAlive(true)
			}
			targetConn.Write([]byte(*secret + "\n"))
			connPool <- targetConn
		} else {
			time.Sleep(2 * time.Second)
		}
	}
}

func handleBridge(localConn net.Conn) {
	defer localConn.Close()
	remoteConn := <-connPool
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
        echo -e "\e[32m[+] Core compiled successfully!\e[0m"
        sleep 1
    fi
}

# ------------------------------------------
# 2. منوی اصلی
# ------------------------------------------
show_menu() {
    clear
    echo -e "\e[36m=========================================\e[0m"
    echo -e "\e[1m          GoTunnel Manager v1.0          \e[0m"
    echo -e "\e[36m=========================================\e[0m"
    echo "1. 🟢 Create New Tunnel"
    echo "2. 🔴 Delete Existing Tunnel"
    echo "3. 📊 Monitor Active Tunnels"
    echo "0. ❌ Exit"
    echo -e "\e[36m=========================================\e[0m"
    read -p "Select an option: " choice

    case $choice in
        1) create_tunnel ;;
        2) delete_tunnel ;;
        3) monitor_tunnels ;;
        0) exit 0 ;;
        *) echo "Invalid option!"; sleep 1; show_menu ;;
    esac
}

# ------------------------------------------
# 3. ساخت تانل جدید
# ------------------------------------------
create_tunnel() {
    echo -e "\n\e[33m--- Create Tunnel ---\e[0m"
    echo "1) Server Mode (Receives traffic from tunnel, forwards to local app)"
    echo "2) Bridge Mode (Receives traffic from user, forwards to tunnel)"
    read -p "Select Mode [1/2]: " mode_num

    if [ "$mode_num" == "1" ]; then
        MODE="server"
        read -p "Tunnel Listen Port (e.g., 8279): " LISTEN_PORT
        read -p "Forward to IP:Port (e.g., 127.0.0.1:9277): " TARGET_ADDR
    elif [ "$mode_num" == "2" ]; then
        MODE="bridge"
        read -p "Local Listen Port (e.g., 9277): " LISTEN_PORT
        read -p "Remote Server IP:Port (e.g., 1.1.1.1:8279): " TARGET_ADDR
    else
        echo "Invalid Mode!"; sleep 1; show_menu
    fi

    read -p "Enter Secret Key (e.g., MySecret123): " SECRET_KEY
    SVC_NAME="gotunnel-${MODE}-${LISTEN_PORT}"
    
    cat <<EOF > /etc/systemd/system/${SVC_NAME}.service
[Unit]
Description=GoTunnel $MODE on $LISTEN_PORT
After=network.target

[Service]
Type=simple
ExecStart=$BIN -mode $MODE -listen :$LISTEN_PORT -remote $TARGET_ADDR -secret $SECRET_KEY
Restart=always
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now ${SVC_NAME}.service
    echo -e "\e[32m[+] Tunnel $SVC_NAME created and started!\e[0m"
    read -p "Press Enter to return..."
    show_menu
}

# ------------------------------------------
# 4. حذف تانل
# ------------------------------------------
delete_tunnel() {
    echo -e "\n\e[33m--- Delete Tunnel ---\e[0m"
    tunnels=($(ls /etc/systemd/system/gotunnel-*.service 2>/dev/null | awk -F'/' '{print $5}' | sed 's/.service//'))
    
    if [ ${#tunnels[@]} -eq 0 ]; then
        echo -e "\e[31mNo active tunnels found.\e[0m"
        read -p "Press Enter to return..."
        show_menu
    fi

    for i in "${!tunnels[@]}"; do
        echo "$((i+1)). ${tunnels[$i]}"
    done

    read -p "Select tunnel to delete (0 to cancel): " del_idx
    if [[ "$del_idx" -gt 0 && "$del_idx" -le "${#tunnels[@]}" ]]; then
        SVC_TO_DEL="${tunnels[$((del_idx-1))]}"
        systemctl stop $SVC_TO_DEL
        systemctl disable $SVC_TO_DEL
        rm -f /etc/systemd/system/${SVC_TO_DEL}.service
        systemctl daemon-reload
        echo -e "\e[32m[+] Tunnel $SVC_TO_DEL deleted.\e[0m"
    fi
    read -p "Press Enter to return..."
    show_menu
}

# ------------------------------------------
# 5. مانیتورینگ تانل‌ها
# ------------------------------------------
monitor_tunnels() {
    echo -e "\n\e[33m--- Active Tunnels Status ---\e[0m"
    tunnels=($(ls /etc/systemd/system/gotunnel-*.service 2>/dev/null | awk -F'/' '{print $5}' | sed 's/.service//'))
    
    printf "%-30s %-15s %-15s\n" "TUNNEL NAME" "STATUS" "CONNECTIONS"
    echo "------------------------------------------------------------"
    
    for tun in "${tunnels[@]}"; do
        STATUS=$(systemctl is-active $tun)
        PORT=$(echo $tun | awk -F'-' '{print $3}')
        # شمارش تعداد کانکشن‌های فعال روی پورت تانل
        CONNS=$(ss -tn | grep ":$PORT " | wc -l)
        
        if [ "$STATUS" == "active" ]; then
            printf "%-30s \e[32m%-15s\e[0m %-15s\n" "$tun" "Running" "$CONNS active"
        else
            printf "%-30s \e[31m%-15s\e[0m %-15s\n" "$tun" "Stopped/Failed" "-"
        fi
    done
    
    echo -e "\n(Use 'journalctl -u <tunnel_name> -f' to see live logs)"
    read -p "Press Enter to return..."
    show_menu
}

# ==========================================
# اجرای اولیه
# ==========================================
if [ "$EUID" -ne 0 ]; then
  echo -e "\e[31mPlease run as root (sudo ./gotunnel.sh)\e[0m"
  exit
fi

setup_core
show_menu

