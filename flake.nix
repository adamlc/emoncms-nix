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

      # Local test VM for macOS (see vm/ and the README). Each Mac runs the
      # Linux guest of its own architecture.
      vfkitGuest =
        system:
        nixpkgs.lib.nixosSystem {
          modules = [
            (import ./vm/guest.nix { inherit self; })
            { nixpkgs.hostPlatform = system; }
          ];
        };
      darwinGuests = {
        aarch64-darwin = "aarch64-linux";
        x86_64-darwin = "x86_64-linux";
      };
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

      nixosConfigurations = {
        vfkit-aarch64 = vfkitGuest "aarch64-linux";
        vfkit-x86_64 = vfkitGuest "x86_64-linux";
      };

      apps = nixpkgs.lib.mapAttrs (
        darwin: linux:
        let
          pkgs = nixpkgs.legacyPackages.${darwin};
          guest = self.nixosConfigurations."vfkit-${pkgs.lib.removeSuffix "-linux" linux}".config;
          vm = pkgs.callPackage ./vm/vfkit.nix {
            image = "${guest.system.build.image}/${guest.image.filePath}";
          };
        in
        {
          vm = {
            type = "app";
            program = "${vm}/bin/emoncms-vm";
          };
        }
      ) darwinGuests;

      nixosModules.default = ./module;
      nixosModules.emoncms = ./module;

      checks = forAllSystems (pkgs: {
        vm = pkgs.testers.runNixOSTest (import ./tests/vm.nix { inherit self; });
        formatting = pkgs.runCommand "emoncms-nix-formatting" { nativeBuildInputs = [ pkgs.nixfmt ]; } ''
          find ${self} -name '*.nix' -exec nixfmt --check {} +
          touch $out
        '';
      });

      formatter = forAllSystems (pkgs: pkgs.nixfmt-tree);
    };
}
