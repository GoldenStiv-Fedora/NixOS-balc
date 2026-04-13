{ config, pkgs, ... }:

{
  # Включаем CUPS (Common UNIX Printing System)
  services.printing = {
    enable = true;
    # Автоматически открываем firewall для печати
    openFirewall = true;
    # Веб-интерфейс для администрирования (порт 631)
    browsing = true;
    # Автоматическое обнаружение сетевых принтеров
    defaultShared = true;
  };

  # Поддержка различных протоколов и драйверов
  services.printing.drivers = with pkgs; [
    # Драйверы для HP принтеров (HPLIP)
    hplip
    hplipWithPlugin
    # Драйверы для Brother принтеров (исправленные имена)
    brlaser
    brgenml1cupswrapper  # Правильное имя вместо brgenml1
    # Драйверы для Canon, Epson, Samsung и др.
    gutenprint
    splix
    # Универсальные драйверы
    cups-bjnp  # Для Canon BJNP протокола
    # CUPS фильтры для PDF/PostScript
    cups-filters
  ];

  # Автоматическая установка рекомендованных драйверов
  hardware.printers = {
    ensurePrinters = [];
    ensureDefaultPrinter = null;
  };

  # Служба для автоматической настройки принтеров (Avahi/Bonjour)
  services.avahi = {
    enable = true;
    nssmdns4 = true;  # Для разрешения имен .local
    publish = {
      enable = true;
      addresses = true;
      workstation = true;
    };
  };

  # Добавляем утилиты для работы с принтерами
  environment.systemPackages = with pkgs; [
    cups                # Основные утилиты CUPS
    cups-filters        # Фильтры печати
    system-config-printer  # Графическая настройка принтеров (GTK)
    gutenprint          # Утилиты для Gutenprint
    hplip               # Утилиты для HP
    sane-airscan        # Сканирование через сеть (если MFP)
    ipp-usb             # Поддержка USB принтеров через IPP over USB
    nmap                # Для поиска принтеров в сети
  ];

  # Добавляем пользователя в группу lpadmin для управления принтерами
  users.users.balc.extraGroups = [ "lpadmin" ];
  users.users.user.extraGroups = [ "lpadmin" ];

  # Автоматический скрипт для поиска и добавления сетевых принтеров
  systemd.services.auto-discover-printers = {
    description = "Auto-discover and configure network printers";
    after = [ "network-online.target" "cups.service" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.writeShellScript "auto-printers" ''
        #!/bin/bash
        sleep 10  # Ждем полной загрузки сети и CUPS
        
        # Используем Avahi для поиска принтеров в сети
        if command -v avahi-browse &> /dev/null; then
          PRINTERS=$(${pkgs.avahi}/bin/avahi-browse -rpt _ipp._tcp 2>/dev/null | grep "=" | cut -d';' -f7,8 | sort -u)
          
          echo "$PRINTERS" | while IFS=';' read -r PRINTER_NAME PRINTER_URL; do
            if [ -n "$PRINTER_NAME" ] && [ -n "$PRINTER_URL" ]; then
              SAFE_NAME=$(echo "$PRINTER_NAME" | sed 's/ /_/g' | sed 's/[^a-zA-Z0-9_-]/_/g')
              
              # Проверяем, не добавлен ли уже принтер
              if ! ${pkgs.cups}/bin/lpstat -p 2>/dev/null | grep -q "$SAFE_NAME"; then
                echo "Adding printer: $SAFE_NAME at $PRINTER_URL"
                ${pkgs.cups}/bin/lpadmin -p "$SAFE_NAME" -E -v "$PRINTER_URL" -m everywhere 2>/dev/null || true
              fi
            fi
          done
        fi
        
        # Также ищем принтеры по протоколу AppSocket/JetDirect (порт 9100)
        if command -v nmap &> /dev/null; then
          ${pkgs.nmap}/bin/nmap -sT -p 9100 --open --host-timeout 2s 192.168.1.0/24 2>/dev/null | \
            grep "Nmap scan" | awk '{print $5}' | while read ip; do
              PRINTER_NAME="printer_$(echo $ip | tr '.' '_')"
              if ! ${pkgs.cups}/bin/lpstat -p 2>/dev/null | grep -q "$PRINTER_NAME"; then
                echo "Adding JetDirect printer: $PRINTER_NAME at $ip"
                ${pkgs.cups}/bin/lpadmin -p "$PRINTER_NAME" -E -v "socket://$ip:9100" -m everywhere 2>/dev/null || true
              fi
            done
        fi
      ''}";
      User = "root";
    };
  };

  # Таймер для периодического поиска новых принтеров (каждые 4 часа)
  systemd.timers.auto-discover-printers = {
    description = "Timer for printer auto-discovery";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "30sec";
      OnUnitActiveSec = "4h";
      Unit = "auto-discover-printers.service";
    };
  };

  # GUI ярлык для настройки принтеров на рабочем столе
  system.activationScripts.setup-printer-shortcut = {
    text = ''
      # Создаем ярлык для настройки принтеров
      mkdir -p /etc/skel/Desktop
      printf "[Desktop Entry]
Version=1.0
Type=Application
Name=Настройка принтеров
Comment=Управление принтерами
Exec=system-config-printer
Icon=printer
Terminal=false
Categories=System;Settings;
" > /etc/skel/Desktop/printer-settings.desktop
      chmod +x /etc/skel/Desktop/printer-settings.desktop

      # Копируем всем существующим пользователям
      for user_home in /home/*; do
        if [ -d "$user_home" ]; then
          user_name=$(basename "$user_home")
          if id "$user_name" >/dev/null 2>&1; then
            user_group=$(id -gn "$user_name")
            for d in "Desktop" "Рабочий стол"; do
              TARGET_DIR="$user_home/$d"
              if [ -d "$TARGET_DIR" ]; then
                mkdir -p "$TARGET_DIR"
                cp /etc/skel/Desktop/printer-settings.desktop "$TARGET_DIR/" 2>/dev/null || true
                chown -R "$user_name:$user_group" "$TARGET_DIR" 2>/dev/null || true
                chmod +x "$TARGET_DIR/printer-settings.desktop" 2>/dev/null || true
              fi
            done
          fi
        fi
      done
    '';
  };
}