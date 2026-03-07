{ config, pkgs, ... }:

let
  # Скрипт автоматического обновления
  syncScript = pkgs.writeShellScriptBin "nixos-git-sync" ''
    set -e
    REPO_DIR="/etc/nixos"
    REMOTE_URL="https://github.com/GoldenStiv-Fedora/NixOS-balc.git"
    BRANCH="main"

    cd $REPO_DIR

    # Проверяем, инициализирован ли Git в папке
    if [ ! -d ".git" ]; then
      echo "Git не инициализирован в $REPO_DIR. Пропускаю автообновление."
      exit 0
    fi

    # Получаем хеш последней версии на сервере без скачивания (ls-remote)
    REMOTE_HASH=$( ${pkgs.git}/bin/git ls-remote $REMOTE_URL -h refs/heads/$BRANCH | cut -f1 )
    # Получаем хеш текущей локальной версии
    LOCAL_HASH=$( ${pkgs.git}/bin/git rev-parse HEAD )

    if [ "$REMOTE_HASH" != "$LOCAL_HASH" ] && [ ! -z "$REMOTE_HASH" ]; then
      echo "Обнаружены обновления в Git. Начинаю обновление системы..."
      ${pkgs.git}/bin/git pull origin $BRANCH
      # Запускаем нашу команду soberi (полный путь к rebuild)
      ${pkgs.nixos-rebuild}/bin/nixos-rebuild switch --flake /etc/nixos#nixos
      echo "Система успешно обновлена до версии $REMOTE_HASH"
    else
      echo "Обновлений не найдено. Текущая версия: $LOCAL_HASH"
    fi
  '';
in {
  # Добавляем скрипт в систему, чтобы его можно было запустить вручную командой nixos-git-sync
  environment.systemPackages = [ syncScript ];

  # Создаем службу systemd для запуска скрипта
  systemd.services.nixos-git-sync = {
    description = "Автоматическое обновление конфигурации NixOS из Git";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${syncScript}/bin/nixos-git-sync";
      User = "root";
    };
  };

  # Создаем таймер на 3 часа
  systemd.timers.nixos-git-sync = {
    description = "Таймер для автоматического обновления конфигурации NixOS (раз в 3 часа)";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "10min";      # Первый запуск через 10 минут после загрузки
      OnUnitActiveSec = "3h";   # Далее каждые 3 часа
      Unit = "nixos-git-sync.service";
    };
  };
}
