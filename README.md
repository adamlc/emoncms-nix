# emoncms-nix

[![check](https://github.com/adamlc/emoncms-nix/actions/workflows/check.yml/badge.svg)](https://github.com/adamlc/emoncms-nix/actions/workflows/check.yml)

Emoncms 11.9.10 as native NixOS services: a read-only package, a php-fpm pool behind nginx, and one systemd unit per background worker. It replaces the all-in-one s6 container from [Open-Building-Management/emoncms](https://github.com/Open-Building-Management/emoncms), which was used as the behavioural reference.

## Quick start

Add the flake as an input to your system's flake and import its NixOS module:

```nix
# flake.nix of your system
{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
  inputs.emoncms = {
    url = "github:adamlc/emoncms-nix";
    inputs.nixpkgs.follows = "nixpkgs";
  };
  outputs = { nixpkgs, emoncms, ... }: {
    nixosConfigurations.host = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        emoncms.nixosModules.default
        {
          services.emoncms = {
            enable = true;
            hostName = "emoncms.lan";
            mqtt = {
              host = "broker.lan";              # your existing broker
              user = "emoncms";
              passwordFile = "/run/secrets/emoncms-mqtt";
            };
          };
          networking.firewall.allowedTCPPorts = [ 80 ];
        }
      ];
    };
  };
}
```

Then open `http://emoncms.lan/` and register. The first account becomes the admin.

The module builds Emoncms and its PHP with your system's `pkgs`, so `follows` only saves a second nixpkgs in your lock file. It is built and tested against nixos-26.05. Pin a commit with `github:adamlc/emoncms-nix/<rev>` and move it with `nix flake update emoncms`.

Flake outputs:

| Output | Contents |
|---|---|
| `nixosModules.default` (alias `nixosModules.emoncms`) | The `services.emoncms` module. It is self-contained and does not need the overlay. |
| `overlays.default` | Adds `pkgs.emoncms` and `pkgs.emoncms-php`, for overriding the package (see below). |
| `packages.<system>.{emoncms,emoncms-php,php-mosquitto}` | The same packages, for `x86_64-linux` and `aarch64-linux`. |
| `checks.<system>.{vm,formatting}` | The NixOS VM test (see Verification) and a `nixfmt` check. |
| `apps.<darwin>.vm`, `nixosConfigurations.vfkit-*` | The macOS test VM (see below). |

TLS: set it on the vhost the module creates, e.g. `services.nginx.virtualHosts."emoncms.lan" = { forceSSL = true; enableACME = true; };`.

## What runs

| Unit | Replaces (container) | Notes |
|---|---|---|
| `mysql.service` | `mariadb` longrun + `sql_ready` | `services.mysql` with `ensureDatabases`/`ensureUsers`. The DB user `emoncms` authenticates by unix socket, so there is no DB password. |
| `redis-emoncms.service` | `redis` longrun | `services.redis.servers.emoncms` on 127.0.0.1:6379, RDB snapshots off (as in the container). |
| `mosquitto.service` | `mosquitto` longrun | Only with `mqtt.createLocally = true` (off by default). |
| `emoncms-setup.service` | `emoncms_pre` + `sql_ready` | Oneshot. Renders `/run/emoncms/settings.ini` (secrets from `*File` options via systemd credentials), writes the backup module's `config.cfg`, then runs `emoncms-cli admin:dbupdate`. It runs on every boot and whenever the package or settings change. The container only migrated on first install. |
| `phpfpm-emoncms.service` + `nginx.service` | `apache2` longrun | PHP 8.4 with `redis` and `mosquitto` extensions. The nginx vhost is a translation of Emoncms's `.htaccess` (see below). |
| `emoncms_mqtt.service` | `emoncms_mqtt` | Only with `mqtt.enable` (default on). |
| `feedwriter.service` | `feedwriter` | Only with `feedwriter.enable` (low-write mode). Off by default; the container turned it on because it targets SD cards. |
| `service-runner.service` | `service-runner` | Runs jobs the web UI queues in Redis: backup export/import, sync, postprocess. |
| `emoncms_sync.service` | `sync_upload` | Sync module's uploader, on by default to match the container (`syncUpload.enable`). It idles until a remote is configured on the Sync page. |

Every worker runs as the `emoncms` user (the same user as php-fpm, because they share the timeseries files), with `ProtectSystem=strict` and write access only to the data dir, the log dir and `/run/emoncms`. Units use upstream's names so the Emoncms admin page's service status works.

Paths:

| Path | Contents |
|---|---|
| `/nix/store/…-emoncms-11.9.10/share/emoncms/www` | Web root: core + graph, dashboard, app, device in `Modules/` |
| `…/share/emoncms/modules/{sync,postprocess,backup}` | Linked modules (the container's `/opt/emoncms/modules`), with `<name>-module` symlinked into `Modules/` |
| `/var/opt/emoncms/{phpfina,phptimeseries,backup}` | Data (`dataDir`, upstream's default location) |
| `/var/log/emoncms` | `emoncms.log` and job logs (`logDir`) |
| `/run/emoncms` | Rendered `settings.ini`, `backup-config.cfg`, lock and flag files |

An `emoncms-cli` wrapper is installed system-wide (runs as the emoncms user), e.g. `sudo emoncms-cli admin:dbupdate`.

## Generated settings.ini

Emoncms reads `default-settings.ini` and overlays `settings.ini`, which must sit next to `process_settings.php`. The package ships `www/settings.ini` as a symlink to `/run/emoncms/settings.ini`. The module writes only the overrides below, and every value can be changed with `services.emoncms.settings` (keys exactly as in `default-settings.ini`):

```ini
display_errors = false
emoncms_dir = '/nix/store/…-emoncms-11.9.10/share/emoncms'
openenergymonitor_dir = '/var/empty'

[sql]
server = 'localhost'          ; database.host (unix socket)
database = 'emoncms'
username = 'emoncms'
password = ''                 ; or substituted from database.passwordFile
port = 3306
dbtest = true

[redis]
enabled = true
host = '127.0.0.1'
port = 6379
prefix = ''                   ; must stay '' for the 11.9.x service-runner
auth = ''                     ; or from redis.passwordFile

[mqtt]
enabled = true
host = 'localhost'
port = 1883
user = 'emoncms'
password = '<from mqtt.passwordFile>'
basetopic = 'emon'
client_id = 'emoncms'

[feed]
engines_hidden = [0,6,8,10]
redisbuffer[enabled] = false  ; feedwriter.enable
redisbuffer[sleep] = 300      ; feedwriterInterval
phpfina[datadir] = '/var/opt/emoncms/phpfina/'
phptimeseries[datadir] = '/var/opt/emoncms/phptimeseries/'

[interface]
feedviewpath = 'graph/'
enable_admin_ui = true
enable_update_ui = false      ; updates come from the flake pins

[log]
enabled = true
location = '/var/log/emoncms'
level = 2
```

Example of extra settings:

```nix
services.emoncms.settings = {
  interface.enable_multi_user = true;
  feed.phpfina.datadir = "/srv/emoncms/phpfina/";   # written as phpfina[datadir]
};
```

Secrets never enter the Nix store. The template holds placeholders, and `emoncms-setup` substitutes them from `LoadCredential=` copies of `database.passwordFile`, `mqtt.passwordFile` and `redis.passwordFile`, writing `settings.ini` with mode 0640. A secret may not contain a single quote, which settings.ini cannot hold; setup fails with a clear message if one does.

## Options

`enable`, `package`, `phpPackage`, `user`, `group`, `dataDir`, `logDir`, `logLevel`, `hostName`, `nginx.enable`,
`database.{createLocally,host,port,name,user,passwordFile}`,
`redis.{createLocally,host,port,prefix,passwordFile}`,
`mqtt.{enable,createLocally,host,port,user,passwordFile,basetopic,clientId,localBroker.address,localBroker.users}`,
`feedwriter.enable`, `feedwriterInterval`, `serviceRunner.enable`, `syncUpload.enable`, `settings`.

To change the installed modules, override the package:

```nix
# with overlays.default applied; or emoncms.packages.x86_64-linux.emoncms.override
services.emoncms.package = pkgs.emoncms.override {
  linkedModules = [ "postprocess" "backup" ];   # drop sync
};
```

## Design notes

**Native services rather than a container.** Each daemon is a stock NixOS service, and systemd ordering replaces s6's oneshots. The cost is that Emoncms's self-update features cannot work against a read-only tree: the admin update page is turned off (`enable_update_ui = false`), and you upgrade by changing the pins in `pkgs/sources.nix`.

**Upstream, not the fork.** The reference Dockerfile defaults to `alexandrecuer/emoncms@master`. That branch is a stale mirror of upstream (0 commits ahead), and the published images are built from `emoncms/emoncms@stable`. The fork's `bios_master` adds Redis batch "forecast" reads and OBM branding, which aren't needed here.

**MQTT extension.** `mgdm/Mosquitto-PHP` does not compile on PHP 8 (it fails on `TSRMLS_CC`). The flake builds OpenEnergyMonitor's fork with `php84.buildPecl`, against the same PHP that php-fpm and the workers use. The only packaging wrinkle is that its `config.m4` wants mosquitto's headers and library under one prefix, so it gets a `symlinkJoin` of `mosquitto.dev` and `mosquitto.lib`.

**Source patches** (sed at build time, in `pkgs/emoncms.nix`):
- `/var/www/emoncms` → the store web root. This path is hard-coded in sync, postprocess, backup and app scripts.
- `/opt/emoncms/modules` → the store modules dir.
- `/var/lock/*.lock` → `/run/emoncms/`. On NixOS `/run/lock` is root-only.
- The backup module's `/tmp/emoncms-flag-*` and `/tmp/backuplock` → `/run/emoncms/`. php-fpm and service-runner each have a private `/tmp`, so files they both need can't live there.
- service-runner takes `REDIS_HOST`/`REDIS_PORT` from the environment instead of assuming localhost.
- Backup scripts: `mysqldump -p"${password}"` only adds `-p` when a password is set, because socket auth has none and a bare `-p` prompts. They also call `emoncms-cli admin:dbupdate` instead of EmonScripts' `emoncmsdbupdate.php`.

The backup, sync and postprocess shell scripts call `sudo` and `systemctl`. service-runner's PATH has a `sudo` that simply runs the command unprivileged. Their `systemctl stop/start` calls fail as non-root, as they do in the container, so the export log reports "completed with ERRORS" even when the archive is fine.

**nginx instead of Apache.** `.htaccess` is translated as follows: unknown paths are rewritten to `index.php?q=<path>`; `/emoncms/<x>` is rewritten to `/<x>`; access to `/scripts/`, `/tests/`, dotfiles, `php-info.php` and `*.ini|cfg|log|sh|sql|bak…` is denied; `HTTP_AUTHORIZATION` is passed through; uploads are allowed up to 3G and requests up to 300s, for backup import.

## Local test VM on macOS (vfkit)

`nix run .#vm` boots a standalone NixOS guest running this module (MariaDB, Redis and Mosquitto all local) under [vfkit](https://github.com/crc-org/vfkit), Apple's Virtualization.framework. An Apple Silicon Mac gets an aarch64-linux guest and an Intel Mac an x86_64-linux one.

```sh
nix run .#vm              # boot in this terminal; you're logged in as root; `poweroff` quits
nix run .#vm -- start -d  # boot in the background, wait for Emoncms, print its URL
nix run .#vm -- ip        # the VM's address on the vmnet NAT (usually 192.168.64.x)
nix run .#vm -- ssh       # root shell (password: emoncms); `-- ssh journalctl -u emoncms_mqtt` works too
nix run .#vm -- stop      # clean shutdown
nix run .#vm -- reset     # delete the VM's disks
```

Open `http://<ip>/` (or `http://emoncms-vm.local/` via mDNS) and register the first user. The broker listens on `<ip>:1883` with user `emoncms`, password `emoncms`, so from the Mac `mosquitto_pub -h <ip> -u emoncms -P emoncms -t emon/test/power -m 100` creates an input.

**You need a Linux builder.** The guest image is aarch64-linux (or x86_64-linux), which macOS can't build itself. Any remote or local Linux builder works; the simplest is nix-darwin's:

```nix
nix.linux-builder.enable = true;   # aarch64-linux builder VM, for Apple Silicon
```

The image is a systemd-repart appliance image, so building it needs no KVM or nested virtualisation, only an ordinary builder. Most of the closure comes from cache.nixos.org; the builder compiles Emoncms, the Mosquitto PHP extension and the image itself.

**How it's laid out.** `vm/guest.nix` is the guest configuration (exposed as `nixosConfigurations.vfkit-aarch64` and `vfkit-x86_64`), and `vm/vfkit.nix` is the launcher. State lives in `~/.local/state/emoncms-vm` (`EMONCMS_VM_DIR` overrides it):

- `root.raw` is a copy of the built image (an APFS clone, so it's instant). It boots systemd-boot and a UKI from the ESP, and grows to `EMONCMS_VM_ROOT_SIZE` (4G) on first boot. When the flake changes, the next start replaces it.
- `data.raw` (`EMONCMS_VM_DATA_SIZE`, 8G, sparse) is a second disk mounted at `/var` and formatted on first boot. MariaDB, Redis, feed data, logs and the SSH host keys live there, so users, inputs and feeds survive a rebuilt image. `reset` deletes both disks.
- The NIC has a fixed MAC (`EMONCMS_VM_MAC`), so vmnet's DHCP keeps handing out the same address, and `ip` looks it up in `/var/db/dhcpd_leases`.
- `EMONCMS_VM_CPUS` (2) and `EMONCMS_VM_MEMORY` (2048 MiB) size the VM.

Iterating on the module is: edit, `nix run .#vm -- stop`, `nix run .#vm`. There is no `nixos-rebuild` inside the guest (the appliance image has no Nix database), so changes always go through a new image.

The guest is for local testing only: root's password is `emoncms`, SSH accepts it, and ports 80 and 1883 are open. vmnet's NAT is reachable only from the Mac itself.

## Upgrading Emoncms later

1. Update the commits and hashes in `pkgs/sources.nix`. To get a hash, set it to `lib.fakeHash`, build, and copy the hash from the error.
2. Rebuild. `emoncms-setup` applies schema migrations on start.
3. Check the build still applies the sed patches above. `substituteInPlace --replace-fail` is used where a miss should fail the build.

For 11.9.10 → 12.x specifically: take a DB dump first (`mysqldump emoncms`). Version 12 rehashes passwords to bcrypt on login, so rolling back afterwards locks those users out, and a NixOS rollback does not roll back the database. Version 12's service-runner uses a script whitelist with `/opt/emoncms/modules` paths, which the sed patch covers.

## Verification

`nix flake check` runs `checks.<system>.vm` (`tests/vm.nix`). GitHub Actions runs it on every push and pull request (`.github/workflows/check.yml`): on an x86_64 runner with KVM, and, once the repository is public, on an `ubuntu-24.04-arm` runner, which has no KVM, so the test runs there under QEMU emulation (about seven minutes). The arm job is skipped while the repository is private, because GitHub only provides those runners free to public repositories. It boots a NixOS VM with the module, using a local broker and feedwriter switched on, and checks:

- `emoncms-setup` renders `settings.ini` with the MQTT secret substituted, and the secret is not in the store.
- Migrations run, and a second `emoncms-cli admin:dbupdate` reports "No migrations to run".
- nginx returns 403 for `/settings.ini` and `/scripts/…`, and serves the login page.
- Registering a user and fetching API keys work.
- **HTTP input** (`/input/post`) lands as an input.
- **MQTT input**: `mosquitto_pub emon/mqttnode/temp` is picked up by `emoncms_mqtt` and shows up as an input.
- A feed write through the Redis buffer is flushed to `phpfina/<id>.dat` by `feedwriter`.
- A backup export queued in Redis is run by `service-runner` and produces a `.tar.gz` containing `emoncms.sql` and the phpfina data.

Not verified:

1. **Backup import**, and the sync and postprocess jobs, haven't been run end to end. Only export is tested. Import reuses the same mechanisms, with `mysql` and `redis-cli flushall` on PATH.
2. **Restoring a backup taken in the Docker container** into this setup hasn't been tried. The container's Redis prefix is also `''`, so that matches.
3. **The archive's `settings.ini` is a symlink.** Backups contain it as a symlink to `/run/emoncms/settings.ini` rather than its contents. That's arguably right, since settings come from Nix, but it differs from the container.
4. **The export log always ends "completed with ERRORS"**, because of the `systemctl stop feedwriter` and `cd /boot` (Raspberry Pi) steps. The archive itself is fine.
5. **Edge cases of the `.htaccess` translation.** Odd paths, such as ones containing spaces, `&` or `%2F`, haven't been compared against Apache.
6. **Remote MariaDB/Redis** (`createLocally = false` with `passwordFile`) is implemented but not covered by the test.
7. **Version choices.** Module versions are the commits that were current while core 11.9.10 was the stable release. Device is 2.3.5, where the reference changelog says 2.3.3. The other module versions match the changelog.
8. **The vfkit launcher has been run on one Mac**, where the guest booted and the web login worked. Other commands, such as `reset`, haven't been checked there. Before that, the x86_64 guest image was built and booted under QEMU with the same disk layout (virtio root disk, a second disk with serial `emoncms-data`, virtio console on hvc0). That checked the root grows to fill its disk, `/var` is formatted on first boot and survives a rebuilt image, and Emoncms, MQTT input and SSH work.

## Licence

The Nix code in this repository is released under the [MIT licence](LICENSE), the same licence as nixpkgs, so any of it can be upstreamed there. It contains no Emoncms source; the build fetches Emoncms and its modules, which are AGPL-3.0, and the Mosquitto PHP extension, which is BSD-3-Clause. Those licences apply to the software you deploy. MIT is compatible with the AGPL, so combining the two is fine. If you change Emoncms itself and expose it to users over a network, the AGPL asks you to offer them your modified source.
