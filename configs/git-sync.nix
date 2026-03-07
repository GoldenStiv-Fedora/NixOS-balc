{ config, pkgs, ... }:

let
  # Скрипт синхронизации: GitHub -> .sync -> /etc/nixos -> rebuild
  syncScript = pkgs.writeShellScriptBin "nixos-git-sync" ''
    set -e
    SYNC_DIR="/etc/nixos/.sync"
    DEST_DIR="/etc/nixos"
    REMOTE_URL="https://github.com/GoldenStiv-Fedora/NixOS-balc.git"
    
    mkdir -p $SYNC_DIR

    # 1. Тянем данные в .sync
    if [ ! -d "$SYNC_DIR/.git" ]; then
      echo "Клонирование репозитория в .sync..."
      ${pkgs.git}/bin/git clone $REMOTE_URL $SYNC_DIR
    fi

    cd $SYNC_DIR
    ${pkgs.git}/bin/git fetch origin main

    # 2. Сверяем хеши
    REMOTE_HASH=$(${pkgs.git}/bin/git rev-parse origin/main)
    LOCAL_HASH=$(${pkgs.git}/bin/git rev-parse HEAD)

    if [ "$REMOTE_HASH" != "$LOCAL_HASH" ]; then
      echo "Найдена новая версия! Начинаю обновление..."
      ${pkgs.git}/bin/git reset --hard origin/main
      
      # 3. Копируем конфиги в основную папку
      echo "Копирование новых конфигов в $DEST_DIR..."
      cp -rf $SYNC_DIR/configs/* $DEST_DIR/

      # 4. Обновление библиотеки обоев
      echo "Обновление библиотеки обоев..."
      mkdir -p /usr/share/backgrounds/balc
      ${pkgs.rsync}/bin/rsync -a --delete $SYNC_DIR/imag/ /usr/share/backgrounds/balc/
      chmod -R 755 /usr/share/backgrounds/balc
      
      # 5. Собираем систему
      echo "Финальная сборка системы..."
      sudo nixos-rebuild switch --flake /etc/nixos#nixos
      echo "Обновление завершено!"
    else
      echo "Система уже актуальна."
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
    description = "Таймер синхронизации (3ч)";
    wantedBy = [ "timers.target" ];
    timerConfig = { OnBootSec = "10min"; OnUnitActiveSec = "3h"; Unit = "nixos-git-sync.service"; };
  };
}
