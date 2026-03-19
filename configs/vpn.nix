{ config, pkgs, ... }:

let
  connectScript = pkgs.writeShellScriptBin "connect-rdp" ''
    #!/bin/bash
    CONFIG_DIR="$HOME/.config/rdp-system"
    WG_USERS_DIR="$CONFIG_DIR/wireguard_users"
    mkdir -p "$WG_USERS_DIR"

    # 1. ВЫБОР ПРОТОКОЛА
    PROTO=$(zenity --list --radiolist --title="Выбор подключения" --width=500 --height=350 \
      --text="Выберите протокол для работы:" \
      --column="Выбор" --column="Протокол" \
      TRUE "WireGuard" FALSE "L2TP")
    
    [ -z "$PROTO" ] && exit 0

    # --- СЦЕНАРИЙ L2TP ---
    if [ "$PROTO" == "L2TP" ]; then
      L2TP_CONF="$CONFIG_DIR/l2tp.conf"
      
      # 2. ПОИСК И СОЗДАНИЕ КОНФИГА L2TP
      if [ ! -f "$L2TP_CONF" ]; then
        L_DATA=$(zenity --forms --title="Первичная настройка L2TP" --width=500 \
          --text="Введите параметры сервера" \
          --add-entry="Внешний IP адрес VPN" \
          --add-entry="Внутренний IP адрес RDP сервера" \
          --add-entry="Ключ IPsec PSK" \
          --separator="|")
        [ -z "$L_DATA" ] && exit 0
        
        echo "VPN_GATEWAY=$(echo $L_DATA | cut -d'|' -f1)" > "$L2TP_CONF"
        echo "RDP_SERVER=$(echo $L_DATA | cut -d'|' -f2)" >> "$L2TP_CONF"
        echo "VPN_PSK=$(echo $L_DATA | cut -d'|' -f3)" >> "$L2TP_CONF"
      fi
      source "$L2TP_CONF"

      # 3. ЗАПРОС ЛОГИНА И ПАРОЛЯ RDP
      RDP_DATA=$(zenity --forms --title="Авторизация RDP (L2TP)" --width=500 \
        --add-entry="Логин пользователя" --add-password="Пароль пользователя" --separator="|")
      [ -z "$RDP_DATA" ] && exit 0
      U_NAME=$(echo "$RDP_DATA" | cut -d'|' -f1)
      U_PASS=$(echo "$RDP_DATA" | cut -d'|' -f2)

      # 4. ПОДКЛЮЧЕНИЕ (В ТОЧНОСТИ КАК В ИСХОДНИКЕ)
      SEC=$(mktemp); echo "vpn.secrets.password:$U_PASS" > "$SEC"; echo "vpn.secrets.ipsec-psk:$VPN_PSK" >> "$SEC"
      
      nmcli connection modify Server vpn.user-name "$U_NAME" vpn.data \
      "gateway=$VPN_GATEWAY, ipsec-enabled=yes, ipsec-psk-flags=2, password-flags=2, user-auth-type=password, machine-auth-type=psk, refuse-chap=yes, refuse-mschap=yes, refuse-mschapv2=no, refuse-pap=yes, refuse-eap=yes"

      if ! nmcli connection up Server passwd-file "$SEC"; then
        zenity --error --text="Ошибка: Не удалось установить соединение L2TP!" --width=400
        rm "$SEC"; exit 1
      fi
      rm "$SEC"; VPN_CONN="Server"
    fi

    # --- СЦЕНАРИЙ WIRE GUARD ---
    if [ "$PROTO" == "WireGuard" ]; then
      SAMBA_CONF="$CONFIG_DIR/wg_samba.conf"

      if [ ! -f "$SAMBA_CONF" ]; then
        R_IP=$(cat /etc/router_ip 2>/dev/null || echo "192.168.1.1")
        S_DATA=$(zenity --forms --title="Настройка диска" --width=500 \
          --text="Введите данные для доступа к роутеру ($R_IP)" \
          --add-entry="IP адрес роутера" --add-entry="Логин Samba" --add-password="Пароль Samba" \
          --separator="|")
        [ -z "$S_DATA" ] && exit 0
        S_IP=$(echo "$S_DATA" | cut -d'|' -f1); [ -z "$S_IP" ] && S_IP="$R_IP"
        echo "SAMBA_IP=$S_IP" > "$SAMBA_CONF"
        echo "SAMBA_USER=$(echo "$S_DATA" | cut -d'|' -f2)" >> "$SAMBA_CONF"
        echo "SAMBA_PASS=$(echo "$S_DATA" | cut -d'|' -f3)" >> "$SAMBA_CONF"
      fi
      source "$SAMBA_CONF"

      RDP_DATA=$(zenity --forms --title="Авторизация RDP (WireGuard)" --width=500 \
        --add-entry="Логин пользователя" --add-password="Пароль пользователя" --separator="|")
      [ -z "$RDP_DATA" ] && exit 0
      U_NAME=$(echo "$RDP_DATA" | cut -d'|' -f1)
      U_PASS=$(echo "$RDP_DATA" | cut -d'|' -f2)

      U_WG_CONF="$CONFIG_DIR/wireguard_users/$U_NAME.conf"

      if [ ! -f "$U_WG_CONF" ]; then
        MNT=$(mktemp -d)
        if sudo mount -t cifs "//$SAMBA_IP/wireguard_configs" "$MNT" -o "user=$SAMBA_USER,password=$SAMBA_PASS,vers=2.0,iocharset=utf8" 2>/dev/null; then
          F_PATH=$(find "$MNT" -maxdepth 1 -iname "$U_NAME.conf" | head -n 1)
          [ -n "$F_PATH" ] && cp "$F_PATH" "$U_WG_CONF" && chmod 600 "$U_WG_CONF"
          sudo umount "$MNT"
        fi
        rmdir "$MNT"
      fi

      if [ ! -f "$U_WG_CONF" ]; then
        zenity --error --text="Ошибка: Конфиг '$U_NAME.conf' не найден на диске!" --width=400
        exit 1
      fi

      nmcli connection delete wg-rdp 2>/dev/null || true
      nmcli connection import type wireguard file "$U_WG_CONF" name wg-rdp
      if ! nmcli connection up wg-rdp; then
        zenity --error --text="Ошибка: Не удалось поднять соединение WireGuard!" --width=400
        exit 1
      fi
      VPN_CONN="wg-rdp"
      [ -f "$CONFIG_DIR/l2tp.conf" ] && RDP_SERVER=$(grep RDP_SERVER "$CONFIG_DIR/l2tp.conf" | cut -d'=' -f2)
    fi

    # --- ОБЩИЙ ЗАПУСК RDP ---
    if [ -z "$RDP_SERVER" ]; then
      RDP_SERVER=$(zenity --entry --title="Настройка RDP" --text="Введите IP адрес сервера:" --width=500)
    fi

    echo "Ожидание стабилизации сети (1 сек)..."
    sleep 1
    export LD_PRELOAD=$(find /nix/store -name libpcsclite.so.1 | head -n 1)
    xfreerdp /v:"$RDP_SERVER" /u:"$U_NAME" /p:"$U_PASS" /smartcard /f /cert:ignore +dynamic-resolution +video /network:auto /floatbar:sticky:off

    [ -n "$VPN_CONN" ] && nmcli connection down "$VPN_CONN" || true
  '' ;

in {
  services.strongswan.enable = true;
  networking.networkmanager.plugins = [ pkgs.networkmanager-l2tp ];
  systemd.tmpfiles.rules = [ "d /etc/ipsec.d 0700 root root -" ]; 
  environment.systemPackages = [ connectScript pkgs.freerdp pkgs.zenity pkgs.pcsclite pkgs.wireguard-tools pkgs.cifs-utils ];

  networking.networkmanager.ensureProfiles.profiles = {
    "Server" = {
      connection = { id = "Server"; type = "vpn"; autoconnect = "false"; };
      vpn = {
        service-type = "org.freedesktop.NetworkManager.l2tp";
        gateway = ""; user = ""; "user-auth-type" = "password"; "password-flags" = "2";
        "ipsec-enabled" = "yes"; "machine-auth-type" = "psk"; "ipsec-psk-flags" = "2";
        "mru" = "1400"; "mtu" = "1400";
        "refuse-chap" = "yes"; "refuse-mschap" = "yes"; "refuse-mschapv2" = "no"; "refuse-pap" = "yes"; "refuse-eap" = "yes";
      };
    };
  };
}
