{ config, pkgs, lib, ... }:

let
  # Скрипт автоматической настройки рабочего стола
  setup-xfce-wallpaper = pkgs.writeShellScriptBin "setup-xfce-wallpaper" ''
    # Ждем загрузки рабочего стола
    sleep 15

    # Находим все активные мониторы и рабочие области
    MONITORS=$(xfconf-query -c xfce4-desktop -l | grep "last-image" | sed 's/\/last-image//')
    
    # Находим любой первый файл изображения в папке
    FIRST_IMAGE=$(ls -1 /usr/share/backgrounds/balc/*.{png,jpg,jpeg} 2>/dev/null | head -n 1)

    if [ -z "$FIRST_IMAGE" ]; then
      echo "Обои не найдены в /usr/share/backgrounds/balc/"
      exit 0
    fi

    for m in $MONITORS; do
      # Указываем ПУТЬ К ФАЙЛУ (обязательно для XFCE)
      xfconf-query -c xfce4-desktop -p "$m/last-image" -n -t string -s "$FIRST_IMAGE"
      # Включаем циклическую смену
      xfconf-query -c xfce4-desktop -p "$m/backdrop-cycle-enable" -n -t bool -s true
      # Период: 4 (Daily / Раз в день)
      xfconf-query -c xfce4-desktop -p "$m/backdrop-cycle-period" -n -t int -s 4
      # Стиль: 5 (Zoomed / Заполнить)
      xfconf-query -c xfce4-desktop -p "$m/image-style" -n -t int -s 5
      # Случайный порядок
      xfconf-query -c xfce4-desktop -p "$m/backdrop-cycle-random-order" -n -t bool -s true
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
      printf "[Desktop Entry]\nVersion=1.0\nType=Application\nName=Подключиться к RDP\nComment=Запуск VPN и RDP сессии\nExec=connect-rdp\nIcon=computer\nTerminal=false\nCategories=Network;\n" > /etc/skel/Desktop/connect.desktop
      chmod +x /etc/skel/Desktop/connect.desktop

      # Копируем всем существующим и удаляем старые дубликаты
      for user_home in /home/*; do
        if [ -d "$user_home" ]; then
          mkdir -p "$user_home/Desktop"
          # Удаление старого имени ярлыка
          rm -f "$user_home/Desktop/Connect_RDP.desktop"
          # Копирование нового
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
