{ config, pkgs, pkgs-unstable, ... }:

let
  routerIp = "192.168.1.1";
in
{
  imports = [
    ./hardware-configuration.nix
    ./users.nix
    ./rutoken.nix
    ./vpn.nix
    ./git-sync.nix
  ];

  environment.etc."router_ip".text = routerIp;
  environment.etc."strongswan.conf".text = "charon { }";

  # ПРАВИЛА SUDO: Монтирование без пароля для всех пользователей
  security.sudo.extraRules = [{
    commands = [
      { command = "/run/current-system/sw/bin/mount"; options = [ "NOPASSWD" ]; }
      { command = "/run/current-system/sw/bin/umount"; options = [ "NOPASSWD" ]; }
      { command = "/run/wrappers/bin/mount"; options = [ "NOPASSWD" ]; }
      { command = "/run/wrappers/bin/umount"; options = [ "NOPASSWD" ]; }
    ];
    groups = [ "wheel" ];
  }];

  boot.loader.systemd-boot.enable = true;
  boot.loader.systemd-boot.configurationLimit = 4;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.loader.timeout = 0;

  boot.consoleLogLevel = 0;
  boot.initrd.verbose = false;
  boot.kernelParams = [ "quiet" "splash" "boot.shell_on_fail=false" "loglevel=3" "rd.systemd.show_status=false" "rd.udev.log_level=3" "udev.log_priority=3" ];
  boot.plymouth.enable = true;

  nix.gc = { automatic = true; dates = "weekly"; options = "--delete-older-than 7d"; };
  nix.settings.auto-optimise-store = true;
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  networking.hostName = "nixos";
  networking.networkmanager.enable = true;

  time.timeZone = "Europe/Moscow";
  i18n.defaultLocale = "ru_RU.UTF-8";

  services.xserver.enable = true;
  services.xserver.displayManager.lightdm.enable = true;
  services.xserver.desktopManager.xfce.enable = true;
  services.xserver.xkb = { layout = "us,ru"; options = "grp:alt_shift_toggle"; };

  security.rtkit.enable = true;
  services.pipewire = { enable = true; alsa.enable = true; pulse.enable = true; };

  nixpkgs.config.allowUnfree = true;

  environment.systemPackages = with pkgs; [
    pkgs-unstable.gemini-cli
    firefox
    git
    vim
    wget
    usbutils
    numlockx
    pavucontrol
    cifs-utils
    wireguard-tools
  ];

  environment.shellAliases = {
    soberi = "sudo nixos-rebuild switch --flake /etc/nixos#nixos";
    obnovi = "cd /etc/nixos/.sync && sudo git fetch origin main && sudo git reset --hard origin/main && sudo rsync -a ./configs/ /etc/nixos/ --exclude=hardware-configuration.nix && cd /etc/nixos && sudo nix flake update && soberi";
  };

  system.stateVersion = "25.11"; 
}
