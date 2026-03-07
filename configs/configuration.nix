{ config, pkgs, pkgs-unstable, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ./users.nix
    ./rutoken.nix
    ./vpn.nix
    ./git-sync.nix
  ];

  # Загрузчик UEFI с ограничением до 4-х сборок
  boot.loader.systemd-boot.enable = true;
  boot.loader.systemd-boot.configurationLimit = 4;
  boot.loader.efi.canTouchEfiVariables = true;

  # Автоматическая очистка и оптимизация
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 7d";
  };
  nix.settings.auto-optimise-store = true;
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  networking.hostName = "nixos";
  networking.networkmanager.enable = true;

  time.timeZone = "Europe/Moscow";
  i18n.defaultLocale = "ru_RU.UTF-8";

  services.xserver.enable = true;
  services.xserver.displayManager.lightdm.enable = true;
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
    pkgs-unstable.gemini-cli
    firefox
    git
    vim
    wget
    usbutils
    xfce.xfce4-pulseaudio-plugin
    xfce.xfce4-xkb-plugin
    pavucontrol
  ];

  # ПРОЗРАЧНЫЕ АЛИАСЫ
  environment.shellAliases = {
    # Собрать текущую систему
    soberi = "sudo nixos-rebuild switch --flake /etc/nixos#nixos";
    
    # Обновить из Git + Обновить каналы + Собрать
    obnovi = "cd /etc/nixos/.sync && sudo git fetch origin main && sudo git reset --hard origin/main && sudo cp -rfT ./configs/ /etc/nixos/ && cd /etc/nixos && sudo nix flake update && soberi";
  };

  system.stateVersion = "25.11"; 
}
