{ config, pkgs, lib, ... }:

let
  # Скрипт автоматической настройки рабочего стола
  setup-xfce-wallpaper = pkgs.writeShellScriptBin "setup-xfce-wallpaper" ''
    # Ждем загрузки рабочего стола и инициализации xfconf
    sleep 15
    XFCONF="${pkgs.xfce.xfconf}/bin/xfconf-query"
    IMAGE_DIR="/usr/share/backgrounds/balc"

    # Проверка наличия картинок
    if [ ! -d "$IMAGE_DIR" ] || [ -z "$(ls -A "$IMAGE_DIR" 2>/dev/null)" ]; then
      echo "Обои не найдены в $IMAGE_DIR"
      exit 0
    fi

    # Динамический поиск всех путей мониторов в XFCE
    # Ищем всё, что относится к мониторам и рабочим столам
    MONITORS=$($XFCONF -c xfce4-desktop -l | grep "workspace0" | sed 's/\/last-image//; s/\/image-path//; s/\/backdrop-cycle-enable//; s/\/image-style//; s/\/backdrop-cycle-period//; s/\/backdrop-cycle-random-order//' | sort -u)

    # Если на абсолютно чистой системе веток еще нет, добавляем стандартные
    if [ -z "$MONITORS" ]; then
        echo "Мониторы не определены в xfconf, использую стандартные пути"
        MONITORS="/backdrop/screen0/monitor0/workspace0 /backdrop/screen0/monitorVirtual1/workspace0"
    fi

    for m in $MONITORS; do
      echo "Применяю настройки для монитора: $m"
      
      # 1. Указываем папку (image-path) вместо одного файла (last-image)
      $XFCONF -c xfce4-desktop -p "$m/image-path" -n -t string -s "$IMAGE_DIR"
      
      # 2. Включаем циклическую смену (автоматически подхватит все файлы из папки)
      $XFCONF -c xfce4-desktop -p "$m/backdrop-cycle-enable" -n -t bool -s true
      
      # 3. Стиль: 5 (Растянуть/Заполнить)
      $XFCONF -c xfce4-desktop -p "$m/image-style" -n -t int -s 5
      
      # 4. Период смены: 4 (Раз в день)
      $XFCONF -c xfce4-desktop -p "$m/backdrop-cycle-period" -n -t int -s 4
      
      # 5. Случайный порядок
      $XFCONF -c xfce4-desktop -p "$m/backdrop-cycle-random-order" -n -t bool -s true
      
      # 6. Сбрасываем last-image, чтобы XFCE перечитал папку
      $XFCONF -c xfce4-desktop -p "$m/last-image" -r 2>/dev/null || true
    done
  '';
in {
  # Глобальный автозапуск для XFCE
  environment.etc."xdg/autostart/balc-wallpaper.desktop".text = ''
    [Desktop Entry]
    Type=Application
    Name=Balc Wallpaper Setup
    Comment=Настройка обоев из Git
    Exec=${setup-xfce-wallpaper}/bin/setup-xfce-wallpaper
    Terminal=false
    OnlyShowIn=XFCE;
  '';

  # Создание ярлыка RDP на рабочем столе
  system.activationScripts.setup-desktop-shortcuts = {
    text = ''
      # Шаблон ярлыка
      mkdir -p /etc/skel/Desktop
      printf "[Desktop Entry]
Version=1.0
Type=Application
Name=Подключиться к RDP
Comment=Запуск VPN и RDP сессии
Exec=connect-rdp
Icon=computer
Terminal=false
Categories=Network;
" > /etc/skel/Desktop/connect.desktop
      chmod +x /etc/skel/Desktop/connect.desktop

      # Копируем всем существующим пользователям
      for user_home in /home/*; do
        if [ -d "$user_home" ]; then
          mkdir -p "$user_home/Desktop"
          rm -f "$user_home/Desktop/Connect_RDP.desktop"
          cp /etc/skel/Desktop/connect.desktop "$user_home/Desktop/"
          chown -R $(basename "$user_home") "$user_home/Desktop"
          chmod +x "$user_home/Desktop/connect.desktop"
        fi
      done
    '';
  };

  environment.systemPackages = [ setup-xfce-wallpaper ];

  users.users.Balc = {
    isNormalUser = true;
    description = "Balc";
    extraGroups = [ "networkmanager" "wheel" ];
    initialPassword = "13579";
  };

  users.users.User = {
    isNormalUser = true;
    description = "User";
    extraGroups = [ "networkmanager" ];
    initialPassword = "123123123";
  };
}
