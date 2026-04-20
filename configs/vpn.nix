{ config, pkgs, ... }:

let
  connectScript = pkgs.writeShellScriptBin "connect-rdp" ''
    #!/bin/bash
    CONFIG_DIR="$HOME/.config"
    mkdir -p "$CONFIG_DIR"

    # Функция диагностики ошибок
    check_rdp_error() {
      RET=$?
      if [ $RET -ne 0 ]; then
        MSG="Ошибка подключения (код $RET)."
        
        # Проверка ключа
        if ! ${pkgs.pcsc-tools}/bin/pcsc_scan -n -t 1 | grep -q "Card inserted"; then
          MSG="КЛЮЧ НЕ НАЙДЕН. Вставьте Рутокен в порт."
        elif ! ping -c 1 "$RDP_SERVER" &>/dev/null; then
          MSG="СЕТЬ НЕДОСТУПНА. Проверьте соединение с VPN или сервером."
        elif [ $RET -eq 20 ]; then
          MSG="ОШИБКА ДРАЙВЕРА: Система не может пробросить устройство USB."
        elif [ $RET -eq 130 ]; then
          MSG="ОШИБКА АВТОРИЗАЦИИ: Проверьте пароль или правильность имени пользователя."
        fi

        ${pkgs.zenity}/bin/zenity --error --title="Ошибка RDP" --text="$MSG"
      fi
    }

    CHOICE=$(${pkgs.zenity}/bin/zenity --list --title="Выбор подключения" \
      --text="Выберите режим работы:" \
      --radiolist --column="Выбор" --column="Тип" \
      TRUE "L2TP (Удаленный доступ)" \
      FALSE "Офис (Локальная сеть)")

    [ -z "$CHOICE" ] && exit 0

    if [ "$CHOICE" == "L2TP (Удаленный доступ)" ]; then
        CONFIG_FILE="$CONFIG_DIR/rdp-connect.conf"
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

        VPN_ACTIVE=$(${pkgs.networkmanager}/bin/nmcli connection show --active | grep -w "Server" || true)

        if [ -z "$VPN_ACTIVE" ]; then
          USER_DATA=$(${pkgs.zenity}/bin/zenity --password --username --title="Авторизация VPN")
          [ -z "$USER_DATA" ] && exit 1
          USER_NAME=$(echo "$USER_DATA" | cut -d'|' -f1)
          USER_PASS=$(echo "$USER_DATA" | cut -d'|' -f2)

          SEC_FILE=$(mktemp)
          chmod 600 "$SEC_FILE"
          echo "vpn.secrets.password:$USER_PASS" > "$SEC_FILE"
          echo "vpn.secrets.ipsec-psk:$VPN_PSK" >> "$SEC_FILE"

          ${pkgs.networkmanager}/bin/nmcli connection modify Server vpn.user-name "$USER_NAME" vpn.data "gateway=$VPN_GATEWAY, ipsec-enabled=yes, ipsec-psk-flags=2, password-flags=2, user-auth-type=password, machine-auth-type=psk, refuse-chap=yes, refuse-mschap=yes, refuse-mschapv2=no, refuse-pap=yes, refuse-eap=yes"

          if ! ${pkgs.networkmanager}/bin/nmcli connection up Server passwd-file "$SEC_FILE"; then
            rm "$SEC_FILE"
            ${pkgs.zenity}/bin/zenity --error --text="Ошибка подключения VPN!"
            exit 1
          fi
          rm "$SEC_FILE"
          sleep 2
        else
          USER_DATA=$(${pkgs.zenity}/bin/zenity --password --username --title="RDP Авторизация (VPN уже активен)")
          [ -z "$USER_DATA" ] && exit 1
          USER_NAME=$(echo "$USER_DATA" | cut -d'|' -f1)
          USER_PASS=$(echo "$USER_DATA" | cut -d'|' -f2)
        fi

        ${pkgs.freerdp}/bin/xfreerdp /v:"$RDP_SERVER" /u:"$USER_NAME" /p:"$USER_PASS" /f /cert:ignore +dynamic-resolution +video /network:auto /floatbar:sticky:off,default:visible,show:fullscreen +clipboard +smartcard /sec:nla
        check_rdp_error
        ${pkgs.networkmanager}/bin/nmcli connection down Server || true
    else
        CONFIG_FILE="$CONFIG_DIR/rdp-office.conf"
        if [ ! -f "$CONFIG_FILE" ] || [ ! -s "$CONFIG_FILE" ]; then
          RDP_SERVER=$(${pkgs.zenity}/bin/zenity --entry --title="Настройка Офис" --text="Введите IP-адрес сервера RDP в офисе:")
          [ -z "$RDP_SERVER" ] && exit 1
          echo "RDP_SERVER=$RDP_SERVER" > "$CONFIG_FILE"
          chmod 600 "$CONFIG_FILE"
        else
          source "$CONFIG_FILE"
        fi

        USER_DATA=$(${pkgs.zenity}/bin/zenity --password --username --title="RDP Авторизация (Офис)")
        [ -z "$USER_DATA" ] && exit 1
        USER_NAME=$(echo "$USER_DATA" | cut -d'|' -f1)
        USER_PASS=$(echo "$USER_DATA" | cut -d'|' -f2)

        ${pkgs.freerdp}/bin/xfreerdp /v:"$RDP_SERVER" /u:"$USER_NAME" /p:"$USER_PASS" /f /cert:ignore +dynamic-resolution +video /network:auto /floatbar:sticky:off,default:visible,show:fullscreen +clipboard +smartcard /sec:nla
        check_rdp_error
    fi
  '';

in {
  services.strongswan.enable = true;
  networking.networkmanager.plugins = [ pkgs.networkmanager-l2tp ];
  systemd.tmpfiles.rules = [ "d /etc/ipsec.d 0700 root root -" ]; 
  environment.etc."strongswan.conf".text = "charon { }";
  environment.systemPackages = [ connectScript pkgs.freerdp pkgs.libnotify pkgs.zenity pkgs.pcsclite pkgs.pcsc-tools ];

  networking.networkmanager.ensureProfiles.profiles = {
    "Server" = {
      connection = { id = "Server"; type = "vpn"; autoconnect = "false"; permissions = ""; };
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
