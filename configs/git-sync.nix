{ config, pkgs, ... }:

let
  # Синхронизация: GitHub -> /etc/nixos/.sync -> /etc/nixos -> предварительная сборка -> switch.
  # Состояние хранится в /var/lib/nixos-git-sync/status.json.
  syncScript = pkgs.writeShellScriptBin "nixos-git-sync" ''
    set -u

    export GIT_TERMINAL_PROMPT=0
    export GIT_HTTP_LOW_SPEED_LIMIT=1000
    export GIT_HTTP_LOW_SPEED_TIME=30

    SYNC_DIR="/etc/nixos/.sync"
    DEST_DIR="/etc/nixos"
    APPS_DIR="$DEST_DIR/apps"
    STATE_DIR="/var/lib/nixos-git-sync"
    STATUS_FILE="$STATE_DIR/status.json"
    LOCK_FILE="$STATE_DIR/sync.lock"
    BUILD_LOG="$STATE_DIR/build.log"
    SWITCH_LOG="$STATE_DIR/switch.log"
    REVISION_FILE="$DEST_DIR/revision"
    REMOTE_URL="https://github.com/GoldenStiv-Fedora/NixOS-balc.git"
    BRANCH="main"

    FORCE=0
    if [ "''${1:-}" = "--force" ]; then
      FORCE=1
    fi

    GIT="${pkgs.git}/bin/git"
    RSYNC="${pkgs.rsync}/bin/rsync"
    JQ="${pkgs.jq}/bin/jq"
    FLOCK="${pkgs.util-linux}/bin/flock"
    TIMEOUT="${pkgs.coreutils}/bin/timeout"
    INSTALL="${pkgs.coreutils}/bin/install"
    DATE="${pkgs.coreutils}/bin/date"
    HOSTNAME="${pkgs.coreutils}/bin/hostname"
    READLINK="${pkgs.coreutils}/bin/readlink"
    CAT="${pkgs.coreutils}/bin/cat"
    SLEEP="${pkgs.coreutils}/bin/sleep"
    TR="${pkgs.coreutils}/bin/tr"
    HEAD="${pkgs.coreutils}/bin/head"
    TAIL="${pkgs.coreutils}/bin/tail"
    CUT="${pkgs.coreutils}/bin/cut"
    MKDIR="${pkgs.coreutils}/bin/mkdir"
    CHMOD="${pkgs.coreutils}/bin/chmod"
    RM="${pkgs.coreutils}/bin/rm"
    MV="${pkgs.coreutils}/bin/mv"
    CP="${pkgs.coreutils}/bin/cp"
    GREP="${pkgs.gnugrep}/bin/grep"
    IP="${pkgs.iproute2}/bin/ip"
    NIXOS_REBUILD="/run/current-system/sw/bin/nixos-rebuild"
    NIXOS_VERSION="/run/current-system/sw/bin/nixos-version"
    SYSTEMD_RUN="/run/current-system/systemd/bin/systemd-run"

    get_mac() {
      local iface=""
      iface=$($IP route get 1.1.1.1 2>/dev/null | $GREP -o 'dev [^ ]*' | $HEAD -n1 | $CUT -d' ' -f2)
      if [ -n "$iface" ] && [ -r "/sys/class/net/$iface/address" ]; then
        $CAT "/sys/class/net/$iface/address"
      else
        $CAT /sys/class/net/*/address 2>/dev/null | $GREP -v '^00:00:00:00:00:00$' | $HEAD -n1
      fi
    }

    status_get() {
      $JQ -r --arg k "$1" '.[$k] // ""' "$STATUS_FILE" 2>/dev/null || true
    }

    write_status() {
      local result="$1"
      local error="''${2:-}"
      local attempt_commit="''${3:-}"
      local success_commit="''${4:-}"
      local synced_commit="''${5:-}"
      local now
      now=$($DATE -u +"%Y-%m-%dT%H:%M:%S.%NZ")
      $JQ -n \
        --arg updated_at "$now" \
        --arg last_check_at "$now" \
        --arg last_attempt_at "''${LAST_ATTEMPT_AT:-}" \
        --arg last_attempt_commit "$attempt_commit" \
        --arg last_success_at "''${LAST_SUCCESS_AT:-}" \
        --arg last_success_commit "$success_commit" \
        --arg last_synced_commit "$synced_commit" \
        --arg last_result "$result" \
        --arg last_error "$error" \
        --arg remote_commit "''${REMOTE_HASH:-}" \
        --arg hostname "$($HOSTNAME 2>/dev/null || echo nixos)" \
        --arg mac "$(get_mac)" \
        --arg generation "$($READLINK -f /run/current-system 2>/dev/null || true)" \
        --arg configuration_revision "$($NIXOS_VERSION --configuration-revision 2>/dev/null || true)" \
        '{updated_at:$updated_at,last_check_at:$last_check_at,last_attempt_at:$last_attempt_at,last_attempt_commit:$last_attempt_commit,last_success_at:$last_success_at,last_success_commit:$last_success_commit,last_synced_commit:$last_synced_commit,last_result:$last_result,last_error:$last_error,remote_commit:$remote_commit,hostname:$hostname,mac:$mac,generation:$generation,configuration_revision:$configuration_revision}' \
        > "$STATUS_FILE.tmp" && $MV "$STATUS_FILE.tmp" "$STATUS_FILE"
      $CHMOD 644 "$STATUS_FILE" 2>/dev/null || true
    }

    sync_images() {
      if [ -d "$SYNC_DIR/imag" ]; then
        echo "Синхронизация обоев..."
        $MKDIR -p /usr/share/backgrounds/balc
        if ! $RSYNC -a --delete "$SYNC_DIR/imag/" /usr/share/backgrounds/balc/; then
          echo "ПРЕДУПРЕЖДЕНИЕ: не удалось синхронизировать обои."
          return 1
        fi
        $CHMOD -R 755 /usr/share/backgrounds/balc
      fi
      return 0
    }

    sync_app() {
      local app_src="$SYNC_DIR/apps/balc"
      local app_dst="$APPS_DIR/balc"

      if [ -f "$app_src/balc.nix" ] && [ -d "$app_src" ]; then
        $MKDIR -p "$APPS_DIR"
        $RM -rf "$app_dst.new"
        if ! $CP -a "$app_src" "$app_dst.new"; then
          echo "ОШИБКА: не удалось скопировать приложение balc."
          return 1
        fi
        $RM -rf "$app_dst"
        $MV "$app_dst.new" "$app_dst"
        # Файл от старой раскладки, когда balc.nix лежал рядом с папкой.
        $RM -f "$APPS_DIR/balc.nix"
        if [ -f "$SYNC_DIR/inventory.json" ]; then
          $INSTALL -m644 "$SYNC_DIR/inventory.json" "$APPS_DIR/inventory.json"
        else
          $RM -f "$APPS_DIR/inventory.json"
        fi
        $CHMOD -R a+rX "$app_dst"
        echo "Приложение balc обновлено в $app_dst."
      else
        if [ -e "$app_dst" ] || [ -f "$APPS_DIR/balc.nix" ]; then
          $RM -rf "$app_dst"
          $RM -f "$APPS_DIR/balc.nix"
          $RM -f "$APPS_DIR/inventory.json"
          echo "Приложение balc отсутствует в репозитории; удалено из $APPS_DIR."
        fi
      fi
      return 0
    }

    copy_configs() {
      echo "Копирование конфигов в $DEST_DIR..."
      # --checksum: не пропустить изменение файла того же размера,
      # даже если mtime совпал с точностью до секунды.
      $RSYNC -a --checksum --exclude=hardware-configuration.nix "$SYNC_DIR/configs/" "$DEST_DIR/"
    }

    # flake.nix читает /etc/nixos/revision и передаёт значение в
    # system.configurationRevision. Пишем коммит, который реально собираем.
    write_revision() {
      local commit="''${1:-}"
      if [ -n "$commit" ]; then
        printf '%s\n' "$commit" > "$REVISION_FILE.tmp" && $MV "$REVISION_FILE.tmp" "$REVISION_FILE"
        $CHMOD 644 "$REVISION_FILE" 2>/dev/null || true
      else
        $RM -f "$REVISION_FILE"
      fi
    }

    restore_last_success() {
      # После cd в STATE_DIR перед сборкой возвращаемся в рабочую копию:
      # git-команды должны выполняться в .sync, а не в каталоге состояния.
      cd "$SYNC_DIR" || return 0
      if [ -n "$LAST_SUCCESS_COMMIT" ] && $GIT cat-file -e "$LAST_SUCCESS_COMMIT^{commit}" 2>/dev/null; then
        echo "Возвращаю последнюю успешную конфигурацию $LAST_SUCCESS_COMMIT..."
        $GIT reset --hard "$LAST_SUCCESS_COMMIT" >/dev/null 2>&1 || true
        $GIT sparse-checkout set configs imag apps 2>/dev/null || true
        copy_configs || true
        sync_app || true
        write_revision "$LAST_SUCCESS_COMMIT"
      else
        write_revision ""
      fi
    }

    $MKDIR -p "$STATE_DIR" "$SYNC_DIR"
    $CHMOD 755 "$STATE_DIR"
    # result от прошлой сборки — лишний GC-root; убираем перед новой попыткой.
    $RM -f "$STATE_DIR/result"
    if [ ! -f "$STATUS_FILE" ]; then
      echo '{}' > "$STATUS_FILE"
      $CHMOD 644 "$STATUS_FILE"
    fi

    LAST_SUCCESS_COMMIT=$(status_get last_success_commit)
    LAST_SUCCESS_AT=$(status_get last_success_at)
    LAST_SYNCED_COMMIT=$(status_get last_synced_commit)
    LAST_ATTEMPT_AT=$(status_get last_attempt_at)
    LAST_ATTEMPT_COMMIT=$(status_get last_attempt_commit)
    PREV_REMOTE_COMMIT=$(status_get remote_commit)
    REMOTE_HASH=""

    exec 9>"$LOCK_FILE"
    if ! $FLOCK -w 600 9; then
      echo "Другой процесс обновления уже выполняется."
      REMOTE_HASH="$PREV_REMOTE_COMMIT"
      write_status "busy" "Другой процесс обновления уже выполняется" "$LAST_ATTEMPT_COMMIT" "$LAST_SUCCESS_COMMIT" "$LAST_SYNCED_COMMIT"
      exit 0
    fi

    cd "$SYNC_DIR" || exit 1

    if [ ! -d "$SYNC_DIR/.git" ]; then
      echo "Инициализация локального репозитория..."
      $GIT init -q
    fi

    if ! $GIT config --global --get-all safe.directory 2>/dev/null | $GREP -qx "$SYNC_DIR"; then
      $GIT config --global --add safe.directory "$SYNC_DIR" || true
    fi

    if ! $GIT remote get-url origin >/dev/null 2>&1; then
      $GIT remote add origin "$REMOTE_URL"
    else
      $GIT remote set-url origin "$REMOTE_URL"
    fi

    $GIT sparse-checkout init --cone 2>/dev/null || true
    $GIT sparse-checkout set configs imag apps 2>/dev/null || true

    fetch_ok=0
    attempt=1
    while [ "$attempt" -le 3 ]; do
      echo "Проверка обновлений в GitHub (попытка $attempt)..."
      if $TIMEOUT 120 $GIT fetch --prune origin "$BRANCH"; then
        fetch_ok=1
        break
      fi
      $SLEEP $((attempt * 10))
      attempt=$((attempt + 1))
    done

    if [ "$fetch_ok" -eq 1 ]; then
      REMOTE_HASH=$($GIT rev-parse "origin/$BRANCH" 2>/dev/null || true)
    fi

    if [ -z "$REMOTE_HASH" ]; then
      echo "Не удалось получить обновления с GitHub."
      if [ "$FORCE" -eq 1 ] && $GIT rev-parse --verify HEAD >/dev/null 2>&1; then
        REMOTE_HASH=$($GIT rev-parse HEAD)
        echo "Принудительная сборка: использую текущую копию .sync ($REMOTE_HASH)."
      else
        LAST_ATTEMPT_AT=$($DATE -u +"%Y-%m-%dT%H:%M:%S.%NZ")
        REMOTE_HASH="$PREV_REMOTE_COMMIT"
        write_status "fetch-failed" "Не удалось получить обновления с GitHub (таймаут или сеть)" "$LAST_ATTEMPT_COMMIT" "$LAST_SUCCESS_COMMIT" "$LAST_SYNCED_COMMIT"
        exit 1
      fi
    fi

    echo "Обновление рабочей копии до $REMOTE_HASH..."
    $GIT sparse-checkout set configs imag apps 2>/dev/null || true
    if ! $GIT reset --hard "$REMOTE_HASH" >/dev/null 2>&1; then
      echo "ОШИБКА: не удалось обновить рабочую копию."
      write_status "git-failed" "Не удалось обновить рабочую копию .sync" "$REMOTE_HASH" "$LAST_SUCCESS_COMMIT" "$LAST_SYNCED_COMMIT"
      exit 1
    fi

    sync_images || true
    if ! sync_app; then
      LAST_ATTEMPT_AT=$($DATE -u +"%Y-%m-%dT%H:%M:%S.%NZ")
      write_status "app-failed" "Не удалось обновить файлы приложения balc" "$REMOTE_HASH" "$LAST_SUCCESS_COMMIT" "$LAST_SYNCED_COMMIT"
      exit 1
    fi
    LAST_SYNCED_COMMIT="$REMOTE_HASH"

    NEED_BUILD=0
    if [ "$FORCE" -eq 1 ]; then
      NEED_BUILD=1
    elif [ -z "$LAST_SUCCESS_COMMIT" ]; then
      NEED_BUILD=1
    elif ! $GIT cat-file -e "$LAST_SUCCESS_COMMIT^{commit}" 2>/dev/null; then
      NEED_BUILD=1
    else
      if ! CHANGED=$($GIT diff --name-only "$LAST_SUCCESS_COMMIT" "$REMOTE_HASH" -- configs apps 2>/dev/null); then
        NEED_BUILD=1
      elif [ -n "$CHANGED" ]; then
        NEED_BUILD=1
      fi
    fi

    if [ -f "$SYNC_DIR/apps/balc/balc.nix" ] && [ ! -f "$APPS_DIR/balc/balc.nix" ]; then
      NEED_BUILD=1
    fi

    if [ "$NEED_BUILD" -eq 1 ]; then
      if ! copy_configs; then
        echo "ОШИБКА: не удалось скопировать конфиги."
        write_status "copy-failed" "Не удалось скопировать конфиги в /etc/nixos" "$REMOTE_HASH" "$LAST_SUCCESS_COMMIT" "$LAST_SYNCED_COMMIT"
        exit 1
      fi

      write_revision "$REMOTE_HASH"

      LAST_ATTEMPT_AT=$($DATE -u +"%Y-%m-%dT%H:%M:%S.%NZ")
      LAST_ATTEMPT_COMMIT="$REMOTE_HASH"
      write_status "building" "" "$REMOTE_HASH" "$LAST_SUCCESS_COMMIT" "$LAST_SYNCED_COMMIT"

      echo "Предварительная сборка (nixos-rebuild build)..."
      cd "$STATE_DIR" || exit 1
      $RM -f result
      if ! $NIXOS_REBUILD build --option substituters https://cache.nixos.org --flake "$DEST_DIR#nixos" > "$BUILD_LOG" 2>&1; then
        echo "ОШИБКА ПРЕДВАРИТЕЛЬНОЙ СБОРКИ. Система не изменена."
        $TAIL -n 80 "$BUILD_LOG" || true
        ERROR_TEXT=$($TAIL -n 40 "$BUILD_LOG" 2>/dev/null | $TR '\n' ' ' | $CUT -c1-2000)
        write_status "build-failed" "$ERROR_TEXT" "$REMOTE_HASH" "$LAST_SUCCESS_COMMIT" "$LAST_SYNCED_COMMIT"
        $RM -f "$STATE_DIR/result"
        restore_last_success
        exit 1
      fi

      echo "Предварительная сборка успешна."
      write_status "built" "" "$REMOTE_HASH" "$LAST_SUCCESS_COMMIT" "$LAST_SYNCED_COMMIT"

      echo "Применение системы (nixos-rebuild switch)..."
      write_status "switching" "" "$REMOTE_HASH" "$LAST_SUCCESS_COMMIT" "$LAST_SYNCED_COMMIT"
      SWITCH_OK=0
      if [ -x "$SYSTEMD_RUN" ]; then
        SWITCH_UNIT="nixos-git-sync-switch-$($DATE +%s)-$$"
        if $SYSTEMD_RUN --unit="$SWITCH_UNIT" --collect --wait --pipe --setenv=PATH=/run/current-system/sw/bin:/run/current-system/systemd/bin "$NIXOS_REBUILD" switch --option substituters https://cache.nixos.org --flake "$DEST_DIR#nixos" > "$SWITCH_LOG" 2>&1; then
          SWITCH_OK=1
        fi
      else
        if $NIXOS_REBUILD switch --option substituters https://cache.nixos.org --flake "$DEST_DIR#nixos" > "$SWITCH_LOG" 2>&1; then
          SWITCH_OK=1
        fi
      fi

      if [ "$SWITCH_OK" -ne 1 ]; then
        echo "ОШИБКА ПРИМЕНЕНИЯ. Система не переключена."
        $TAIL -n 80 "$SWITCH_LOG" || true
        ERROR_TEXT=$($TAIL -n 40 "$SWITCH_LOG" 2>/dev/null | $TR '\n' ' ' | $CUT -c1-2000)
        write_status "switch-failed" "$ERROR_TEXT" "$REMOTE_HASH" "$LAST_SUCCESS_COMMIT" "$LAST_SYNCED_COMMIT"
        $RM -f "$STATE_DIR/result"
        restore_last_success
        exit 1
      fi

      LAST_SUCCESS_COMMIT="$REMOTE_HASH"
      LAST_SUCCESS_AT=$($DATE -u +"%Y-%m-%dT%H:%M:%S.%NZ")
      LAST_ATTEMPT_AT="$LAST_SUCCESS_AT"
      LAST_ATTEMPT_COMMIT="$REMOTE_HASH"
      $RM -f "$STATE_DIR/result"
      write_status "success" "" "$REMOTE_HASH" "$LAST_SUCCESS_COMMIT" "$LAST_SYNCED_COMMIT"
      echo "Система обновлена до $REMOTE_HASH."
    else
      LAST_ATTEMPT_AT=$($DATE -u +"%Y-%m-%dT%H:%M:%S.%NZ")
      LAST_ATTEMPT_COMMIT="$REMOTE_HASH"
      if [ "$LAST_SYNCED_COMMIT" = "$REMOTE_HASH" ] && [ "$LAST_SUCCESS_COMMIT" = "$REMOTE_HASH" ]; then
        write_status "up-to-date" "" "$REMOTE_HASH" "$LAST_SUCCESS_COMMIT" "$LAST_SYNCED_COMMIT"
        echo "Система уже актуальна."
      else
        write_status "assets-only" "" "$REMOTE_HASH" "$LAST_SUCCESS_COMMIT" "$LAST_SYNCED_COMMIT"
        echo "Обновлены только файлы без пересборки (картинки/инвентарь)."
      fi
    fi
  '';

  # Кнопка ручной пересборки для приложения balc. Только запускает службу.
  rebuildTrigger = pkgs.writeShellScriptBin "nixos-fleet-rebuild" ''
    exec /run/current-system/sw/bin/systemctl start --no-block nixos-fleet-rebuild.service
  '';
in {
  environment.systemPackages = [ syncScript rebuildTrigger pkgs.rsync pkgs.jq ];

  security.sudo.extraRules = [
    {
      users = [ "balc" ];
      commands = [
        {
          command = "${rebuildTrigger}/bin/nixos-fleet-rebuild";
          options = [ "NOPASSWD" ];
        }
        {
          command = "/run/current-system/sw/bin/nixos-fleet-rebuild";
          options = [ "NOPASSWD" ];
        }
      ];
    }
  ];

  systemd.services.nixos-git-sync = {
    description = "Фоновая синхронизация NixOS с GitHub";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    restartIfChanged = false;
    stopIfChanged = false;
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${syncScript}/bin/nixos-git-sync";
      User = "root";
      TimeoutStartSec = "3h";
      Nice = 10;
      IOSchedulingClass = "best-effort";
      IOSchedulingPriority = 7;
      CPUWeight = 50;
      IOWeight = 50;
      Environment = [
        "PATH=/run/current-system/sw/bin:/run/current-system/systemd/bin"
      ];
    };
  };

  # Принудительная пересборка по запросу приложения. Общий flock не даст
  # таймеру и ручному запуску работать одновременно.
  systemd.services.nixos-fleet-rebuild = {
    description = "Принудительная пересборка NixOS из GitHub";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    restartIfChanged = false;
    stopIfChanged = false;
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${syncScript}/bin/nixos-git-sync --force";
      User = "root";
      TimeoutStartSec = "3h";
      Nice = 10;
      IOSchedulingClass = "best-effort";
      IOSchedulingPriority = 7;
      CPUWeight = 50;
      IOWeight = 50;
      Environment = [
        "PATH=/run/current-system/sw/bin:/run/current-system/systemd/bin"
      ];
    };
  };

  systemd.timers.nixos-git-sync = {
    description = "Таймер синхронизации (каждые 20 минут)";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "5min";
      OnUnitActiveSec = "20min";
      RandomizedDelaySec = "5min";
      AccuracySec = "1min";
      Unit = "nixos-git-sync.service";
    };
  };
}
