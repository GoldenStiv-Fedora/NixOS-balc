{ config, pkgs, lib, ... }:

let
  # Скрипт автоматической настройки рабочего стола (v2.0 - Universal)
  setup-xfce-wallpaper = pkgs.writeShellScriptBin "setup-xfce-wallpaper" ''
    # Ждем загрузки рабочего стола и инициализации служб
    sleep 10
    
    XFCONF="${pkgs.xfce.xfconf}/bin/xfconf-query"
    XRANDR="${pkgs.xorg.xrandr}/bin/xrandr"
    IMAGE_DIR="/usr/share/backgrounds/balc"

    # Проверка наличия картинок
    if [ ! -d "$IMAGE_DIR" ] || [ -z "$(ls -A "$IMAGE_DIR" 2>/dev/null)" ]; then
      exit 0
    fi

    # 1. Получаем список РЕАЛЬНО подключенных мониторов через xrandr
    # Это позволяет скрипту работать на любом железе (Intel/AMD/Nvidia/VM)
    REAL_MONITORS=$($XRANDR | grep " connected" | awk '{print $1}')
    
    # 2. Добавляем резервные имена (monitor0 - стандарт для XFCE, Virtual1 - для VM)
    TARGET_MONITORS="$REAL_MONITORS monitor0 Virtual1"

    for m in $TARGET_MONITORS; do
      # Формируем путь настроек XFCE: /backdrop/screen0/monitor<ИМЯ>/workspace0
      PREFIX="/backdrop/screen0/monitor$m/workspace0"
      
      # 3. Сбрасываем привязку к конкретному файлу (last-image), чтобы XFCE начал использовать папку
      # Флаг -r удаляет свойство, -R рекурсивно (на всякий случай)
      $XFCONF -c xfce4-desktop -p "$PREFIX/last-image" -r -R 2>/dev/null || true
      
      # 4. Устанавливаем папку с изображениями
      $XFCONF -c xfce4-desktop -p "$PREFIX/image-path" -n -t string -s "$IMAGE_DIR"
      
      # 5. Включаем ротацию (циклическую смену)
      $XFCONF -c xfce4-desktop -p "$PREFIX/backdrop-cycle-enable" -n -t bool -s true
      
      # 6. Стиль: 5 = Zoom (Заполнение/Растянуть)
      $XFCONF -c xfce4-desktop -p "$PREFIX/image-style" -n -t int -s 5
      
      # 7. Период смены (совместимость с разными версиями XFCE)
      # Обычно 4 = Daily (Ежедневно) или при входе.
      $XFCONF -c xfce4-desktop -p "$PREFIX/backdrop-cycle-period" -n -t int -s 4
      $XFCONF -c xfce4-desktop -p "$PREFIX/backdrop-cycle-timer" -n -t int -s 4
      
      # 8. Случайный порядок
      $XFCONF -c xfce4-desktop -p "$PREFIX/backdrop-cycle-random-order" -n -t bool -s true
    done

    # 9. Принудительно обновляем рабочий стол, чтобы применить изменения
    ${pkgs.xfce.xfdesktop}/bin/xfdesktop --reload 2>/dev/null || 
    ${pkgs.procps}/bin/pkill -USR1 xfdesktop || true
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

  users.users.balc = {
    isNormalUser = true;
    description = "Balc";
    extraGroups = [ "networkmanager" "wheel" ];
    initialPassword = "13579";
  };

  users.users.user = {
    isNormalUser = true;
    description = "User";
    extraGroups = [ "networkmanager" ];
    initialPassword = "123123123";
  };
}
