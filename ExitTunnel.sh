#!/bin/bash

LOG_FILE="/var/log/tunnel_manager.log"

function log_action() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a $LOG_FILE }

function install_hysteria() { log_action "📥 نصب Hysteria در این سرور..." bash <(curl -fsSL https://get.hy2.sh/) log_action "✅ Hysteria نصب شد." }

function configure_server() { echo "\n🔧 تنظیم Hysteria Server (برای ایران یا سرور اصلی)" read -p "🔸 اسم تانل: " TUNNEL_NAME read -p "🔸 IP سرور خارج: " FOREIGN_IP read -p "🔸 انتخاب پروتکل تونل (tcp یا udp): " TUNNEL_PROTOCOL read -p "🔸 پورت ارتباط بین ایران و خارج: " TUNNEL_PORT read -p "🔸 رمز تانل: " TUNNEL_PASSWORD read -p "🔸 پورت برای کاربران نهایی (مرزبان/X-UI): " CLIENT_PORT

log_action "✅ تنظیم سرور با مشخصات: اسم=$TUNNEL_NAME، پروتکل=$TUNNEL_PROTOCOL، پورت تانل=$TUNNEL_PORT، پورت کاربر=$CLIENT_PORT"

mkdir -p /etc/hysteria
cat > /etc/hysteria/${TUNNEL_NAME}_server.yaml <<EOF

listen: :$CLIENT_PORT protocol: $TUNNEL_PROTOCOL up_mbps: 100 down_mbps: 100 password: [$TUNNEL_PASSWORD]

forward: type: $TUNNEL_PROTOCOL server: $FOREIGN_IP:$TUNNEL_PORT EOF

systemctl restart hysteria-server
log_action "✅ Hysteria Server روی پورت $CLIENT_PORT راه اندازی شد."

}

function configure_client() { echo "\n🔧 تنظیم Hysteria Client (برای سرور خارج)" read -p "🔸 اسم تانل: " TUNNEL_NAME read -p "🔸 پورت که باید listen بشه: " TUNNEL_PORT read -p "🔸 رمز تانل: " TUNNEL_PASSWORD read -p "🔸 پروتکل (tcp یا udp): " TUNNEL_PROTOCOL

log_action "✅ تنظیم کلاینت با مشخصات: اسم=$TUNNEL_NAME، پروتکل=$TUNNEL_PROTOCOL، پورت=$TUNNEL_PORT"

mkdir -p /etc/hysteria
cat > /etc/hysteria/${TUNNEL_NAME}_client.yaml <<EOF

listen: 0.0.0.0:$TUNNEL_PORT protocol: $TUNNEL_PROTOCOL up_mbps: 100 down_mbps: 100 password: [$TUNNEL_PASSWORD] EOF

systemctl restart hysteria-server
log_action "✅ Hysteria Client روی پورت $TUNNEL_PORT راه اندازی شد."

}

function delete_tunnel() { read -p "🔸 اسم تانل برای حذف: " TUNNEL_NAME

log_action "🗑 حذف کانفیگ برای تانل $TUNNEL_NAME"
rm -f /etc/hysteria/${TUNNEL_NAME}_server.yaml
rm -f /etc/hysteria/${TUNNEL_NAME}_client.yaml
systemctl restart hysteria-server

log_action "✅ تانل $TUNNEL_NAME حذف شد."

}

function main_menu() { while true; do echo "\n==== مدیریت تانل Hysteria ====" echo "1. نصب Hysteria در این سرور" echo "2. تنظیم این سرور به عنوان Server (ایران)" echo "3. تنظیم این سرور به عنوان Client (خارج)" echo "4. حذف تانل" echo "5. مشاهده لاگ" echo "6. خروج" read -p "یک گزینه را انتخاب کنید: " CHOICE

case $CHOICE in
        1)
            install_hysteria
            ;;
        2)
            configure_server
            ;;
        3)
            configure_client
            ;;
        4)
            delete_tunnel
            ;;
        5)
            cat $LOG_FILE
            ;;
        6)
            exit 0
            ;;
        *)
            echo "گزینه نامعتبر."
            ;;
    esac
done

}

main_menu


