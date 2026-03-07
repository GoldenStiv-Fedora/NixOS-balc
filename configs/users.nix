{ config, pkgs, ... }:

{
  # Администратор системы
  users.users.Balc = {
    isNormalUser = true;
    description = "Balc";
    extraGroups = [ "networkmanager" "wheel" ];
    initialPassword = "13579";
  };

  # Обычный пользователь для работы
  users.users.User = {
    isNormalUser = true;
    description = "User";
    extraGroups = [ "networkmanager" ];
    initialPassword = "123123123";
  };
}
