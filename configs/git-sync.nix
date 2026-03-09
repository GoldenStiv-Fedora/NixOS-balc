{ config, pkgs, ... }:

let
  # Скрипт синхронизации: GitHub -> .sync -> /etc/nixos -> rebuild
  syncScript = pkgs.writeShellScriptBin "nixos-git-sync" ''
    set -e
    SYNC_DIR="/etc/nixos/.sync"
    DEST_DIR="/etc/nixos"
    REMOTE_URL="https://github.com/GoldenStiv-Fedora/NixOS-balc.git"
    
    mkdir -p $SYNC_DIR

    # Исправление ошибки "dubious ownership" (безопасность Git)
    # Это позволит запускать команды git от root в этой папке без ошибок
    ${pkgs.git}/bin/git config --global --add safe.directory $SYNC_DIR || true

    # 1. Тянем данные в .sync
    if [ ! -d "$SYNC_DIR/.git" ]; then
      echo "Клонирование репозитория в .sync..."
      ${pkgs.git}/bin/git clone $REMOTE_URL $SYNC_DIR
    fi

    cd $SYNC_DIR
    echo "Проверка обновлений в GitHub..."
    ${pkgs.git}/bin/git fetch origin main
    
    # Сверяем хеши ПЕРЕД сбросом, чтобы знать, нужно ли пересобирать систему
    REMOTE_HASH=$(${pkgs.git}/bin/git rev-parse origin/main)
    LOCAL_HASH=$(${pkgs.git}/bin/git rev-parse HEAD)

    # Принудительно обновляем локальную копию (чтобы подтянуть новые картинки)
    ${pkgs.git}/bin/git reset --hard origin/main

    # 2. Обновление библиотеки обоев (делаем ВСЕГДА, не дожидаясь смены конфигов)
    echo "Синхронизация библиотеки обоев в /usr/share/backgrounds/balc..."
    mkdir -p /usr/share/backgrounds/balc
    ${pkgs.rsync}/bin/rsync -a --delete $SYNC_DIR/imag/ /usr/share/backgrounds/balc/
    chmod -R 755 /usr/share/backgrounds/balc

    # 3. Пересборка системы только если изменились файлы конфигурации
    if [ "$REMOTE_HASH" != "$LOCAL_HASH" ]; then
      echo "Найдена новая версия конфигов! Начинаю обновление..."
      
      # Копируем конфиги в основную папку (Защита: исключаем hardware-configuration.nix)
      ${pkgs.rsync}/bin/rsync -a $SYNC_DIR/configs/ $DEST_DIR/ --exclude=hardware-configuration.nix

      echo "Финальная сборка системы..."
      sudo nixos-rebuild switch --flake /etc/nixos#nixos
      echo "Обновление системы завершено!"
    else
      echo "Конфигурация системы уже актуальна. Картинки синхронизированы."
    fi
  '';
in {
  environment.systemPackages = [ syncScript pkgs.rsync ];
  
  systemd.services.nixos-git-sync = {
    description = "Фоновая синхронизация NixOS с GitHub";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${syncScript}/bin/nixos-git-sync";
      User = "root";
    };
  };

  systemd.timers.nixos-git-sync = {
    description = "Таймер синхронизации (каждые 20 минут)";
    wantedBy = [ "timers.target" ];
    timerConfig = { 
      OnBootSec = "5min"; 
      OnUnitActiveSec = "3h"; 
      Unit = "nixos-git-sync.service"; 
    };
  };
}
