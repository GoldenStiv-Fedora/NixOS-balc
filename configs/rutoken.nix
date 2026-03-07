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

    nativeBuildInputs = [ pkgs.dpkg pkgs.autoPatchelfHook ];
    buildInputs = [ pkgs.libusb-compat-0_1 pkgs.pcsclite ];

    unpackPhase = "dpkg-deb -x $src .";

    installPhase = ''
      DEST=$out/pcsc/drivers/ifd-rutokens.bundle/Contents
      mkdir -p $DEST/Linux
      find . -name "Info.plist" -exec cp -L {} $DEST/ \;
      find . -name "librutokens.so" -exec cp -L {} $DEST/Linux/ \;
      
      chmod +w $DEST/Info.plist
      # Фикс: используем относительный путь для NixOS и исправляем структуру
      sed -i "s|<string>.*librutokens.so</string>|<string>librutokens.so</string>|g" $DEST/Info.plist
    '';
  };

in {
  services.pcscd.enable = true;
  services.pcscd.plugins = [ pkgs.ccid ifd-rutokens ];

  environment.systemPackages = with pkgs; [
    opensc
    pkcs11helper
    ccid
    ifd-rutokens
    pcsc-tools
    usbutils
  ];

  security.polkit.enable = true;

  services.udev.extraRules = ''
    SUBSYSTEM=="usb", ATTR{idVendor}=="0a89", ATTR{idProduct}=="0020", MODE="0664", GROUP="wheel", ENV{ID_SMARTCARD_READER}="1"
    SUBSYSTEM=="usb", ATTR{idVendor}=="0a89", ATTR{idProduct}=="0025", MODE="0664", GROUP="wheel", ENV{ID_SMARTCARD_READER}="1"
  '';
}
