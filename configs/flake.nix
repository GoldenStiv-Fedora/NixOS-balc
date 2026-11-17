{
  description = "Конфигурация парка из 15 ПК на NixOS с поддержкой Рутокена и RDP";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05"; # Версия текущей OS
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs, nixpkgs-unstable, ... }@inputs:
    let
      lib = nixpkgs.lib;

      # Служба синхронизации пишет реально собранный коммит в /etc/nixos/revision.
      # Если файла нет (например, ручная сборка вне службы) — берём ревизию
      # флейка, а при её отсутствии помечаем значение как unknown.
      revisionFromFile =
        if builtins.pathExists ./revision
        then lib.removeSuffix "\n" (builtins.readFile ./revision)
        else "";

      revision =
        if revisionFromFile != ""
        then revisionFromFile
        else if self ? rev then self.rev
        else if self ? dirtyRev then self.dirtyRev
        else "unknown";
    in {
      nixosConfigurations.nixos = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = {
          pkgs-unstable = import nixpkgs-unstable {
            system = "x86_64-linux";
            config.allowUnfree = true;
          };
        };
        modules = [
          ./configuration.nix
          { system.configurationRevision = revision; }
        ];
      };
    };
}
