{ config, pkgs, lib, ... }:

let
  # Скрипт автоматической настройки рабочего стола (v2.1 - Enhanced Reliability)
  setup-xfce-wallpaper = pkgs.writeShellScriptBin "setup-xfce-wallpaper" ''
    # 1. Ждем загрузки рабочего стола (несколько попыток для надежности при первом входе)
    IMAGE_DIR="/usr/share/backgrounds/balc"
    XFCONF="${pkgs.xfce.xfconf}/bin/xfconf-query"
    
    # Проверка наличия картинок
    if [ ! -d "$IMAGE_DIR" ] || [ -z "$(ls -A "$IMAGE_DIR" 2>/dev/null)" ]; then
      exit 0
    fi

    FIRST_IMAGE=$(ls -1 "$IMAGE_DIR"/*.{jpg,jpeg,png,webp} 2>/dev/null | head -n 1)

    apply_settings() {
      # Получаем список всех существующих путей для мониторов в xfconf
      # Это самый надежный способ найти активные экраны
      MONITORS=$($XFCONF -c xfce4-desktop -p /backdrop -l | grep "workspace0/last-image" | cut -d'/' -f4 | sort -u)
      
      # Если xfconf еще пуст (первый запуск), используем дефолтные имена
      if [ -z "$MONITORS" ]; then
        MONITORS="monitor0 monitor1 monitorVirtual1 monitorHDMI-1 monitoreDP-1"
      fi

      for m in $MONITORS; do
        # Убираем возможный префикс "monitor", если он уже есть в переменной, 
        # чтобы избежать "monitormonitor0"
        MON_NAME=$(echo "$m" | sed 's/^monitor//')
        PREFIX="/backdrop/screen0/monitor$MON_NAME/workspace0"
        
        # А) Устанавливаем ПЕРВОЕ изображение сразу (чтобы не ждать ротации)
        if [ -n "$FIRST_IMAGE" ]; then
          $XFCONF -c xfce4-desktop -p "$PREFIX/last-image" -n -t string -s "$FIRST_IMAGE" 2>/dev/null || 
          $XFCONF -c xfce4-desktop -p "$PREFIX/last-image" -s "$FIRST_IMAGE"
        fi
        
        # Б) Настраиваем папку и ротацию
        $XFCONF -c xfce4-desktop -p "$PREFIX/image-path" -n -t string -s "$IMAGE_DIR" 2>/dev/null || 
        $XFCONF -c xfce4-desktop -p "$PREFIX/image-path" -s "$IMAGE_DIR"
        
        $XFCONF -c xfce4-desktop -p "$PREFIX/backdrop-cycle-enable" -n -t bool -s true 2>/dev/null || 
        $XFCONF -c xfce4-desktop -p "$PREFIX/backdrop-cycle-enable" -s true
        
        $XFCONF -c xfce4-desktop -p "$PREFIX/image-style" -n -t int -s 5 2>/dev/null || 
        $XFCONF -c xfce4-desktop -p "$PREFIX/image-style" -s 5
        
        # Период смены: 4 = Daily (раз в сутки/при входе)
        $XFCONF -c xfce4-desktop -p "$PREFIX/backdrop-cycle-period" -n -t int -s 4 2>/dev/null || 
        $XFCONF -c xfce4-desktop -p "$PREFIX/backdrop-cycle-period" -s 4
        
        $XFCONF -c xfce4-desktop -p "$PREFIX/backdrop-cycle-random-order" -n -t bool -s true 2>/dev/null || 
        $XFCONF -c xfce4-desktop -p "$PREFIX/backdrop-cycle-random-order" -s true
      done
    }

    # Делаем 3 попытки с интервалом, чтобы "поймать" инициализацию xfdesktop
    for i in 1 2 3; do
      sleep 10
      apply_settings
      # Принудительно обновляем рабочий стол
      ${pkgs.xfce.xfdesktop}/bin/xfdesktop --reload 2>/dev/null || true
    done
  '';

in {
  # Глобальный автозапуск для XFCE
  environment.etc."xdg/autostart/balc-wallpaper.desktop".text = ''
    [Desktop Entry]
    Type=Application
    Name=balc Wallpaper Setup
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
          user_name=$(basename "$user_home")
          if id "$user_name" >/dev/null 2>&1; then
            chown -R "$user_name" "$user_home/Desktop"
            chmod +x "$user_home/Desktop/connect.desktop"
          fi
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
