# Окружение для тестирования balc без установки в систему.
#
# Запуск из папки приложения:
#   cd apps/balc
#   nix-shell
#   python3 main.py
#
# nixpkgs берётся из flake.lock проекта — тот же, на котором собрана система,
# поэтому всё нужное уже есть в магазине и nix-shell запускается быстро.

{ system ? builtins.currentSystem }:

let
  flake = builtins.getFlake (toString ../..);
  pkgs = flake.inputs.nixpkgs.legacyPackages.${system};
  python = pkgs.python3.withPackages (ps: [ ps.paramiko ps.tkinter ]);
in

pkgs.mkShell {
  buildInputs = [
    python
    pkgs.openssh
    pkgs.xterm
  ];

  shellHook = ''
    echo "Окружение balc готово (nixpkgs: ${pkgs.lib.version})."
    echo "Запуск приложения: python3 main.py"
  '';
}
