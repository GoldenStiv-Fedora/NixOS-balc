{ config, pkgs, ... }:

let
  # Скрипт подключения RDP через VPN
  connectScript = pkgs.writeShellScriptBin "connect-rdp" ''
    #!/bin/bash
    CONFIG_DIR="$HOME/.config"
    CONFIG_FILE="$CONFIG_DIR/rdp-connect.conf"
    mkdir -p "$CONFIG_DIR"

    # Загрузка настроек IP и PSK
    if [ ! -f "$CONFIG_FILE" ] || [ ! -s "$CONFIG_FILE" ]; then
      VPN_GATEWAY=$(${pkgs.zenity}/bin/zenity --entry --title="Настройка VPN" --text="Введите ВНЕШНИЙ IP-адрес (VPN шлюз):")
      [ -z "$VPN_GATEWAY" ] && exit 1
      RDP_SERVER=$(${pkgs.zenity}/bin/zenity --entry --title="Настройка RDP" --text="Введите ВНУТРЕННИЙ IP-адрес сервера RDP:")
      [ -z "$RDP_SERVER" ] && exit 1
      VPN_PSK=$(${pkgs.zenity}/bin/zenity --entry --title="Настройка PSK" --text="Введите ключ IPsec PSK:" --hide-text)
      [ -z "$VPN_PSK" ] && exit 1
      echo "VPN_GATEWAY=$VPN_GATEWAY" > "$CONFIG_FILE"
      echo "RDP_SERVER=$RDP_SERVER" >> "$CONFIG_FILE"
      echo "VPN_PSK=$VPN_PSK" >> "$CONFIG_FILE"
      chmod 600 "$CONFIG_FILE"
    else
      source "$CONFIG_FILE"
    fi

    # Проверка активного VPN
    VPN_ACTIVE=$(${pkgs.networkmanager}/bin/nmcli connection show --active | grep -w "Server" || true)

    if [ -z "$VPN_ACTIVE" ]; then
      USER_DATA=$(${pkgs.zenity}/bin/zenity --password --username --title="Авторизация (VPN + RDP)")
      [ -z "$USER_DATA" ] && exit 1
      USER_NAME=$(echo "$USER_DATA" | cut -d'|' -f1)
      USER_PASS=$(echo "$USER_DATA" | cut -d'|' -f2)

      SEC_FILE=$(mktemp)
      chmod 600 "$SEC_FILE"
      echo "vpn.secrets.password:$USER_PASS" > "$SEC_FILE"
      echo "vpn.secrets.ipsec-psk:$VPN_PSK" >> "$SEC_FILE"

      # Настройка и запуск VPN
      ${pkgs.networkmanager}/bin/nmcli connection modify Server vpn.user-name "$USER_NAME" vpn.data "gateway=$VPN_GATEWAY, ipsec-enabled=yes, ipsec-psk-flags=2, password-flags=2, user-auth-type=password, machine-auth-type=psk, refuse-chap=yes, refuse-mschap=yes, refuse-mschapv2=no, refuse-pap=yes, refuse-eap=yes"

      if ! ${pkgs.networkmanager}/bin/nmcli connection up Server passwd-file "$SEC_FILE"; then
        rm "$SEC_FILE"
        ${pkgs.zenity}/bin/zenity --error --text="Ошибка подключения VPN!"
        exit 1
      fi
      rm "$SEC_FILE"
      sleep 2
    else
      USER_DATA=$(${pkgs.zenity}/bin/zenity --password --username --title="RDP Авторизация")
      [ -z "$USER_DATA" ] && exit 1
      USER_NAME=$(echo "$USER_DATA" | cut -d'|' -f1)
      USER_PASS=$(echo "$USER_DATA" | cut -d'|' -f2)
    fi

    # Запуск RDP (FreeRDP 3.x)
    ${pkgs.freerdp}/bin/xfreerdp /v:"$RDP_SERVER" /u:"$USER_NAME" /p:"$USER_PASS" /smartcard /f /cert:ignore +dynamic-resolution +video /network:auto /floatbar:sticky:off,default:visible,show:fullscreen

    # Очистка данных
    ${pkgs.networkmanager}/bin/nmcli connection down Server || true
    ${pkgs.networkmanager}/bin/nmcli connection modify Server vpn.user-name "" vpn.data "gateway=, ipsec-enabled=yes, ipsec-psk-flags=2, password-flags=2, refuse-chap=yes, refuse-mschap=yes, refuse-mschapv2=no, refuse-pap=yes, refuse-eap=yes"
  '';

in {
  services.strongswan.enable = true;
  networking.networkmanager.plugins = [ pkgs.networkmanager-l2tp ];

  systemd.tmpfiles.rules = [ "d /etc/ipsec.d 0700 root root -" ]; 
  environment.etc."strongswan.conf".text = "charon { }";

  environment.systemPackages = [ connectScript pkgs.freerdp pkgs.libnotify pkgs.zenity ];

  networking.networkmanager.ensureProfiles.profiles = {
    "Server" = {
      connection = { id = "Server"; type = "vpn"; autoconnect = "false"; permissions = ""; };
      vpn = {
        service-type = "org.freedesktop.NetworkManager.l2tp";
        gateway = ""; user = ""; "user-auth-type" = "password"; "password-flags" = "2";
        "ipsec-enabled" = "yes"; "machine-auth-type" = "psk"; "ipsec-psk-flags" = "2";
        "mru" = "1400"; "mtu" = "1400";
        "refuse-chap" = "yes"; "refuse-eap" = "yes"; "refuse-mschap" = "yes"; "refuse-mschapv2" = "no"; "refuse-pap" = "yes";
      };
    };
  };

  system.activationScripts.desktopShortcuts = {
    text = ''
      for user_home in /home/*; do
        if [ -d "$user_home/Desktop" ]; then
          cat <<DESK > "$user_home/Desktop/Connect_RDP.desktop"
[Desktop Entry]
Version=1.0
Type=Application
Name=Подключиться к Серверу
Comment=VPN + RDP + Смарт-карты
Exec=connect-rdp
Icon=network-vpn
Terminal=false
Categories=Network;
DESK
          OWNER=$(stat -c '%U' "$user_home/Desktop")
          chown $OWNER "$user_home/Desktop/Connect_RDP.desktop"
          chmod +x "$user_home/Desktop/Connect_RDP.desktop"
        fi
      done
    '';
  };
}
