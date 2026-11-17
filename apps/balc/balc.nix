{ pkgs, ... }:

let
  # Самодостаточное окружение приложения: Python, SSH-клиент, Tkinter.
  pythonEnv = pkgs.python3.withPackages (ps: [
    ps.paramiko
    ps.tkinter
  ]);

  balcApp = pkgs.stdenv.mkDerivation {
    pname = "balc";
    version = "0.1.0";
    # balc.nix лежит внутри папки приложения, поэтому исходники — эта же папка.
    src = ./.;

    dontBuild = true;
    dontConfigure = true;

    installPhase = ''
      runHook preInstall

      mkdir -p $out/share/balc
      cp -a ./. $out/share/balc/

      mkdir -p $out/bin
      cat > $out/bin/balc <<EOF
      #!${pkgs.runtimeShell}
      exec ${pythonEnv}/bin/python $out/share/balc/main.py "\$@"
      EOF
      chmod +x $out/bin/balc

      # Создание зашифрованного токена: balc-token-setup ПУТЬ/token.enc
      cat > $out/bin/balc-token-setup <<EOF
      #!${pkgs.runtimeShell}
      exec ${pythonEnv}/bin/python $out/share/balc/token_tool.py "\$@"
      EOF
      chmod +x $out/bin/balc-token-setup

      mkdir -p $out/share/applications
      cat > $out/share/applications/balc.desktop <<EOF
      [Desktop Entry]
      Type=Application
      Name=balc
      Comment=Мониторинг и управление парком NixOS
      Exec=balc
      Icon=balc
      Terminal=false
      Categories=System;Monitor;
      StartupNotify=true
      EOF

      mkdir -p $out/share/icons/hicolor/256x256/apps
      cp ./icon.png $out/share/icons/hicolor/256x256/apps/balc.png

      runHook postInstall
    '';
  };
in {
  # Приложение доступно только пользователю balc: в меню и PATH остальных
  # пользователей его нет.
  users.users.balc.packages = [
    balcApp
    pkgs.openssh
    pkgs.xterm
  ];
}
