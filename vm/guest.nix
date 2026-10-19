# NixOS guest for local testing under vfkit (Apple Virtualization.framework).
#
# The root disk is a systemd-repart appliance image: it builds without KVM (so
# a nix-darwin linux-builder can produce it) and boots via systemd-boot + a
# UKI under vfkit's EFI loader. It is replaced whenever the flake changes.
# All state (MariaDB, Redis, feeds, logs) lives on a second, persistent disk
# mounted at /var, so a rebuilt image keeps your users, inputs and feeds.
#
# Not for production: root's password is "emoncms" and SSH accepts it.
{ self }:
{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}:
let
  efiArch = config.nixpkgs.hostPlatform.efiArch;
in
{
  imports = [
    self.nixosModules.default
    "${modulesPath}/image/repart.nix"
  ];

  system.stateVersion = "26.05";
  networking.hostName = "emoncms-vm";

  ## Boot: systemd-boot from the ESP, UKI built from this configuration.
  boot.loader.grub.enable = false;
  boot.initrd.systemd.enable = true;
  boot.initrd.availableKernelModules = [
    "virtio_pci"
    "virtio_blk"
    "virtio_net"
    "virtio_console"
    "virtio_rng"
  ];
  # hvc0 is vfkit's virtio-serial console; listed last so it is /dev/console.
  boot.kernelParams = [
    "console=tty0"
    "console=hvc0"
  ];

  image.repart = {
    name = "emoncms-vm";
    sectorSize = 512;
    partitions = {
      esp = {
        contents = {
          "/EFI/BOOT/BOOT${lib.toUpper efiArch}.EFI".source =
            "${pkgs.systemd}/lib/systemd/boot/efi/systemd-boot${efiArch}.efi";
          "/EFI/Linux/${config.system.boot.loader.ukiFile}".source =
            "${config.system.build.uki}/${config.system.boot.loader.ukiFile}";
          "/loader/loader.conf".source = pkgs.writeText "loader.conf" "timeout 0\n";
        };
        repartConfig = {
          Type = "esp";
          Format = "vfat";
          SizeMinBytes = "128M";
        };
      };
      root = {
        storePaths = [ config.system.build.toplevel ];
        repartConfig = {
          Type = "root";
          Format = "ext4";
          Label = "root";
          Minimize = "guess";
        };
      };
    };
  };

  # The helper script enlarges the disk file; grow the root partition and its
  # filesystem into the new space on boot.
  boot.initrd.systemd.repart.enable = true;
  systemd.repart.partitions."10-root".Type = "root";

  fileSystems."/" = {
    device = "/dev/disk/by-partlabel/root";
    fsType = "ext4";
    autoResize = true;
  };
  # Second vfkit disk (deviceId=emoncms-data), formatted on first boot.
  fileSystems."/var" = {
    device = "/dev/disk/by-id/virtio-emoncms-data";
    fsType = "ext4";
    autoFormat = true;
    neededForBoot = true;
  };
  boot.tmp.useTmpfs = true;

  # The appliance image has no Nix database, so nix inside the guest is useless.
  nix.enable = false;

  ## Access from the Mac.
  networking.useNetworkd = true;
  networking.firewall.allowedTCPPorts = [
    80
    1883
  ];
  services.avahi = {
    enable = true;
    nssmdns4 = true;
    publish = {
      enable = true;
      addresses = true;
    };
  };
  services.getty.autologinUser = "root";
  users.mutableUsers = false;
  users.users.root.password = "emoncms";
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "yes";
      PasswordAuthentication = true;
    };
    # Keep host keys on the persistent disk so they survive image rebuilds.
    hostKeys = [
      {
        type = "ed25519";
        path = "/var/lib/ssh/ssh_host_ed25519_key";
      }
    ];
  };
  programs.bash.loginShellInit = ''
    [[ $- == *i* ]] || return 0
    ip4=$(${pkgs.iproute2}/bin/ip -4 -o addr show scope global | ${pkgs.gawk}/bin/awk '{split($4,a,"/"); print a[1]; exit}')
    echo
    echo "Emoncms: http://''${ip4:-<no address yet>}/  (or http://emoncms-vm.local/)"
    echo "MQTT:    ''${ip4:-<ip>}:1883  user emoncms / password emoncms, topic emon/<node>/<input>"
    echo
  '';

  environment.systemPackages = with pkgs; [
    mosquitto
    redis
    jq
    curl
  ];

  ## Emoncms, standalone: local MariaDB, Redis and Mosquitto.
  environment.etc."emoncms/mqtt-password".text = "emoncms";
  services.emoncms = {
    enable = true;
    hostName = "emoncms-vm";
    mqtt = {
      createLocally = true;
      passwordFile = "/etc/emoncms/mqtt-password";
    };
  };
  services.nginx.virtualHosts.emoncms-vm.default = true;
}
