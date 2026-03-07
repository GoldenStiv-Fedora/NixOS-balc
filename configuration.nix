{ config, pkgs, pkgs-unstable, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ./users.nix
    ./rutoken.nix
    ./vpn.nix
    ./git-sync.nix
  ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

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

  # УЛУЧШЕННЫЕ АЛИАСЫ
  environment.shellAliases = {
    # soberi: Просто пересобрать текущие файлы
    soberi = "sudo nixos-rebuild switch --flake /etc/nixos#nixos";
    # obnovi: Стянуть конфиг из GitHub + Обновить каналы + Пересобрать систему
    obnovi = "cd /etc/nixos && sudo git pull && sudo nix flake update && soberi";
  };

  system.stateVersion = "25.11"; 
}
