{ config, pkgs, pkgs-unstable, lib, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ./users.nix
    ./rutoken.nix
    ./vpn.nix
    ./git-sync.nix
    ./printers.nix
  ] ++ lib.optional (builtins.pathExists ./apps/balc/balc.nix) ./apps/balc/balc.nix;

  # Загрузчик UEFI с ограничением до 4-х сборок и максимально тихой загрузкой
  boot.loader.systemd-boot.enable = true;
  boot.loader.systemd-boot.configurationLimit = 4;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.loader.timeout = 0; # Скрыть меню выбора (удерживайте клавишу для вызова)

  # Максимально тихая загрузка (Silent Boot)
  boot.consoleLogLevel = 0;
  boot.initrd.verbose = false;
  boot.kernelParams = [
    "quiet"
    "splash"
    "boot.shell_on_fail=false"
    "loglevel=3"
    "rd.systemd.show_status=false"
    "rd.udev.log_level=3"
    "udev.log_priority=3"
  ];
  boot.plymouth.enable = true;

  # Автоматическая очистка и оптимизация
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 7d";
  };
  nix.settings.auto-optimise-store = true;
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  nix.settings.substituters = [
    "https://cache.nixos.org"
  ];

  # SSH для управления парком с любого ПК под пользователем balc.
  # Пароли не меняем: используются уже заданные в users.nix.
  services.openssh = {
    enable = true;
    openFirewall = true;
    settings = {
      PasswordAuthentication = true;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
    };
  };

  networking.hostName = "nixos";
  networking.networkmanager.enable = true;

  time.timeZone = "Europe/Moscow";
  i18n.defaultLocale = "ru_RU.UTF-8";

  services.xserver.enable = true;
  services.xserver.displayManager.lightdm.enable = true;
  services.xserver.displayManager.lightdm.greeters.gtk.extraConfig = "activate-numlock=true";
  services.xserver.displayManager.sessionCommands = "${pkgs.numlockx}/bin/numlockx on";
  services.xserver.desktopManager.xfce.enable = true;
  services.xserver.xkb = {
    layout = "us,ru";
    options = "grp:alt_shift_toggle";
  };

  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
  };

  nixpkgs.config.allowUnfree = true;

  environment.systemPackages = with pkgs; [
    #pkgs-unstable.gemini-cli
    #pkgs-unstable.opencode
    #remmina
    pkgs-unstable.opencode-desktop
    #pkgs-unstable.brave
    firefox
    git
    vim
    wget
    usbutils
    numlockx
    nix-output-monitor
    xfce4-pulseaudio-plugin 
    xfce4-xkb-plugin 
    pavucontrol
    pkgs-unstable.amnezia-vpn
  ];
# Добавляем архиватор
programs.thunar.plugins = with pkgs; [
  thunar-archive-plugin
  xarchiver
];

  # ПРОЗРАЧНЫЕ АЛИАСЫ
  environment.shellAliases = {
    # Собрать текущую систему. Используем только официальный кэш.
    # Вывод сборки — через nom (nix-output-monitor), красивое дерево зависимостей.
    soberi = "sudo nixos-rebuild switch --option substituters 'https://cache.nixos.org' --flake /etc/nixos#nixos |& ${pkgs.nix-output-monitor}/bin/nom";

    # Обновить из Git и пересобрать прямо в терминале: flock тот же, что у
    # таймера, а сборка идёт через nom — красивое дерево в реальном времени.
    obnovi = "sudo /run/current-system/sw/bin/nixos-git-sync --force";
  };

  system.stateVersion = "26.05"; 
}
