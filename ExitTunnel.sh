#!/bin/bash

# ==========================================
# QDTunnel STABLE - Debug Mode
# ==========================================

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

CONF_DIR="/etc/qdtunnel"
TUNNELS_JSON="$CONF_DIR/tunnels.json"

# 1. چک کردن روت
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}[!] لطفا با دستور sudo اجرا کنید.${NC}"
   exit 1
fi

# 2. نصب پیش‌نیازها (اجباری)
echo -e "${CYAN}[*] در حال بررسی پیش‌نیازها...${NC}"
if ! command -v socat &> /dev/null; then
    echo "Installing socat..."
    apt-get update -qq && apt-get install -y socat -qq
fi
if ! command -v jq &> /dev/null; then
    echo "Installing jq..."
    apt-get install -y jq -qq
fi

# ساخت پوشه کانفیگ
mkdir -p "$CONF_DIR"
if [[ ! -f "$TUNNELS_JSON" ]]; then
    echo "[]" > "$TUNNELS_JSON"
fi

# --- توابع اصلی ---

add_tunnel() {
    echo -e "\n${CYAN}=== ساخت تانل جدید ===${NC}"
    echo "این اسکریپت روی کدام سرور اجرا شده است؟"
    echo "1) سرور ایران (مبدا)"
    echo "2) سرور خارج (مقصد)"
    read -r -p "انتخاب کنید [1-2]: " ROLE

    if [[ "$ROLE" != "1" && "$ROLE" != "2" ]]; then
        echo -e "${RED}گزینه اشتباه است!${NC}"
        return
    fi

    read -r -p "یک نام انگلیسی برای تانل انتخاب کنید (مثلا radin): " TNAME
    if [[ -z "$TNAME" ]]; then echo -e "${RED}نام نمی‌تواند خالی باشد.${NC}"; return; fi

    # بررسی تکراری بودن نام
    if grep -q "\"name\": \"$TNAME\"" "$TUNNELS_JSON"; then
        echo -e "${RED}این نام قبلا استفاده شده!${NC}"; return;
    fi

    if [[ "$ROLE" == "1" ]]; then
        # --- تنظیمات ایران ---
        echo -e "\n${GREEN}--- تنظیمات سرور ایران ---${NC}"
        read -r -p "پورت لوکال (پورتی که در ایران باز شود، مثلا 8080): " LPORT
        read -r -p "آی‌پی سرور خارج (مثلا 85.x.x.x): " RHOST
        read -r -p "پورت سرور خارج (پورتی که در خارج باز است): " RPORT
        
        # دستور اجرای تانل
        CMD="socat TCP-LISTEN:${LPORT},reuseaddr,fork,keepalive TCP:${RHOST}:${RPORT},keepalive"
        
        # ساخت سرویس
        create_service "$TNAME" "$CMD"
        
        # ذخیره در جیسون
        JSON_STR="{\"name\": \"$TNAME\", \"type\": \"IRAN\", \"port\": \"$LPORT -> $RHOST:$RPORT\"}"
        save_to_json "$JSON_STR"
        
        echo -e "${GREEN}[✓] تمام! تانل ایران روی پورت $LPORT فعال شد و به $RHOST متصل می‌شود.${NC}"

    elif [[ "$ROLE" == "2" ]]; then
        # --- تنظیمات خارج ---
        echo -e "\n${GREEN}--- تنظیمات سرور خارج ---${NC}"
        read -r -p "پورت ورودی (پورتی که ایران به آن وصل می‌شود، مثلا 443): " LPORT
        read -r -p "مقصد نهایی (معمولا 127.0.0.1): " RHOST
        read -r -p "پورت مقصد نهایی (مثلا پورت کانفیگ V2ray): " RPORT

        CMD="socat TCP-LISTEN:${LPORT},reuseaddr,fork,keepalive TCP:${RHOST}:${RPORT},keepalive"
        
        create_service "$TNAME" "$CMD"
        
        JSON_STR="{\"name\": \"$TNAME\", \"type\": \"KHAREJ\", \"port\": \"$LPORT -> $RHOST:$RPORT\"}"
        save_to_json "$JSON_STR"
        
        echo -e "${GREEN}[✓] تمام! سرور خارج روی پورت $LPORT گوش می‌دهد و به $RPORT فوروارد می‌کند.${NC}"
    fi
}

create_service() {
    local NAME=$1
    local EXEC_CMD=$2
    local SERVICE_PATH="/etc/systemd/system/qdtunnel-${NAME}.service"

    cat > "$SERVICE_PATH" <<EOF
[Unit]
Description=QDTunnel Service - ${NAME}
After=network.target

[Service]
ExecStart=/usr/bin/env bash -c '${EXEC_CMD}'
Restart=always
RestartSec=3
User=root

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now "qdtunnel-${NAME}"
}

save_to_json() {
    # استفاده از فایل موقت برای جلوگیری از خرابی فایل اصلی
    jq ". += [$1]" "$TUNNELS_JSON" > "$TUNNELS_JSON.tmp" && mv "$TUNNELS_JSON.tmp" "$TUNNELS_JSON"
}

list_tunnels() {
    echo -e "\n${CYAN}=== لیست تانل‌های فعال ===${NC}"
    if [[ ! -s "$TUNNELS_JSON" || "$(cat $TUNNELS_JSON)" == "[]" ]]; then
        echo "هیچ تانلی وجود ندارد."
    else
        jq -r '.[] | "نام: \(.name) | مدل: \(.type) | مسیر: \(.port)"' "$TUNNELS_JSON"
    fi
    echo ""
}

remove_tunnel() {
    echo -e "\n${CYAN}=== حذف تانل ===${NC}"
    jq -r '.[] | .name' "$TUNNELS_JSON"
    echo ""
    read -r -p "نام تانل را برای حذف بنویسید: " TNAME
    
    if [[ -z "$TNAME" ]]; then return; fi
    
    # حذف سرویس
    systemctl stop "qdtunnel-${TNAME}" 2>/dev/null
    systemctl disable "qdtunnel-${TNAME}" 2>/dev/null
    rm "/etc/systemd/system/qdtunnel-${TNAME}.service" 2>/dev/null
    systemctl daemon-reload

    # حذف از دیتابیس
    jq "map(select(.name != \"$TNAME\"))" "$TUNNELS_JSON" > "$TUNNELS_JSON.tmp" && mv "$TUNNELS_JSON.tmp" "$TUNNELS_JSON"
    
    echo -e "${GREEN}[✓] تانل $TNAME حذف شد.${NC}"
}

# --- منوی اصلی ---
while true; do
    echo -e "\n=============================="
    echo -e "   QDTunnel Manager (Fixed)"
    echo -e "=============================="
    echo "1. ساخت تانل جدید (Add)"
    echo "2. نمایش لیست تانل‌ها (List)"
    echo "3. حذف تانل (Delete)"
    echo "0. خروج (Exit)"
    echo "------------------------------"
    read -r -p "انتخاب کنید: " OPT

    case $OPT in
        1) add_tunnel ;;
        2) list_tunnels ;;
        3) remove_tunnel ;;
        0) echo "خداحافظ"; exit 0 ;;
        *) echo "گزینه اشتباه است." ;;
    esac
done
