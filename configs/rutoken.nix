{ config, pkgs, lib, ... }:

let
  # Официальный драйвер для Rutoken S (HID)
  ifd-rutokens = pkgs.stdenv.mkDerivation rec {
    pname = "ifd-rutokens";
    version = "1.0.4";

    src = pkgs.fetchurl {
      url = "https://download.rutoken.ru/Rutoken/Drivers_Unix/${version}/Linux/x64/ifd-rutokens_${version}_amd64.deb";
      sha256 = "18cdch725482smg29zrbnb83d6x735ls0pi1rnrl7jif32wgmi3x";
    };

    nativeBuildInputs = [ pkgs.dpkg ];

    unpackPhase = "dpkg-deb -x $src .";

    # В NixOS модуль pcscd ищет плагины по пути $out/pcsc/drivers
    installPhase = ''
      # Создаем целевую структуру по стандарту NixOS
      DEST=$out/pcsc/drivers/ifd-rutokens.bundle/Contents
      mkdir -p $DEST/Linux
      
      # Ищем файлы в распакованном архиве (игнорируя битые ссылки)
      find . -name "Info.plist" -exec cp -L {} $DEST/ \;
      find . -name "librutokens.so" -exec cp -L {} $DEST/Linux/ \;
      
      # Исправление путей внутри Info.plist для Nix Store
      chmod +w $DEST/Info.plist
      sed -i "s|librutokens.so|$DEST/Linux/librutokens.so|g" $DEST/Info.plist
    '';
  };

in {
  # Служба для работы со смарт-картами
  services.pcscd.enable = true;
  
  # Добавляем драйверы в pcscd
  # NixOS автоматически объединит их в один PCSCLITE_HP_DROPDIR
  services.pcscd.plugins = [ 
    pkgs.ccid 
    ifd-rutokens 
  ];

  # Утилиты для работы с ЭЦП и диагностики
  environment.systemPackages = with pkgs; [
    opensc
    pkcs11helper
    ccid
    ifd-rutokens
    pcsc-tools
    usbutils
  ];

  # Разрешение пользователям работать со смарт-картами без пароля Root
  security.polkit.enable = true;

  # Настройка обнаружения устройств Рутокен
  services.udev.extraRules = ''
    # Rutoken S (HID модель)
    SUBSYSTEM=="usb", ATTR{idVendor}=="0a89", ATTR{idProduct}=="0020", MODE="0664", GROUP="wheel", ENV{ID_SMARTCARD_READER}="1"
    # Rutoken Lite (CCID модель)
    SUBSYSTEM=="usb", ATTR{idVendor}=="0a89", ATTR{idProduct}=="0025", MODE="0664", GROUP="wheel", ENV{ID_SMARTCARD_READER}="1"
  '';
}
