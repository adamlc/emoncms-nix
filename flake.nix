{
  description = "Emoncms (OpenEnergyMonitor) packaged as native NixOS services";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      overlays.default = final: prev: {
        emoncms = final.callPackage ./pkgs/emoncms.nix { };
        emoncms-php = final.callPackage ./pkgs/php.nix { };
      };

      packages = forAllSystems (pkgs: rec {
        emoncms = pkgs.callPackage ./pkgs/emoncms.nix { };
        emoncms-php = pkgs.callPackage ./pkgs/php.nix { };
        php-mosquitto = pkgs.callPackage ./pkgs/php-mosquitto.nix { php = pkgs.php84; };
        default = emoncms;
      });

      nixosModules.default = ./module;
      nixosModules.emoncms = ./module;

      checks = forAllSystems (pkgs: {
        vm = pkgs.testers.runNixOSTest (import ./tests/vm.nix { inherit self; });
      });

      formatter = forAllSystems (pkgs: pkgs.nixfmt);
    };
}
