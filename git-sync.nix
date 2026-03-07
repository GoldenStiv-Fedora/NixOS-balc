{ config, pkgs, ... }:

let
  syncScript = pkgs.writeShellScriptBin "nixos-git-sync" ''
    set -e
    REPO_DIR="/etc/nixos"
    REMOTE_URL="https://github.com/GoldenStiv-Fedora/NixOS-balc.git"
    BRANCH="main"

    cd $REPO_DIR

    if [ ! -d ".git" ]; then
      echo "Git не инициализирован. Пропускаю."
      exit 0
    fi

    REMOTE_HASH=$( ${pkgs.git}/bin/git ls-remote $REMOTE_URL -h refs/heads/$BRANCH | cut -f1 )
    LOCAL_HASH=$( ${pkgs.git}/bin/git rev-parse HEAD )

    if [ "$REMOTE_HASH" != "$LOCAL_HASH" ] && [ ! -z "$REMOTE_HASH" ]; then
      echo "Обновление..."
      ${pkgs.git}/bin/git pull origin $BRANCH
      # Добавлен флаг --impure
      ${pkgs.nixos-rebuild}/bin/nixos-rebuild switch --flake /etc/nixos#nixos --impure
    fi
  '';
in {
  environment.systemPackages = [ syncScript ];
  systemd.services.nixos-git-sync = {
    description = "Автоматическое обновление NixOS из Git";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${syncScript}/bin/nixos-git-sync";
      User = "root";
    };
  };
  systemd.timers.nixos-git-sync = {
    description = "Таймер обновления NixOS (3ч)";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "10min";
      OnUnitActiveSec = "3h";
      Unit = "nixos-git-sync.service";
    };
  };
}
