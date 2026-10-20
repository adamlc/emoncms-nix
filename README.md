# emoncms-nix

[![check](https://github.com/adamlc/emoncms-nix/actions/workflows/check.yml/badge.svg)](https://github.com/adamlc/emoncms-nix/actions/workflows/check.yml)

Emoncms 11.9.10 as native NixOS services: a read-only package, a php-fpm pool behind nginx, and one systemd unit per background worker. It replaces the all-in-one s6 container from [Open-Building-Management/emoncms](https://github.com/Open-Building-Management/emoncms), which was used as the behavioural reference.

It is in real use: an existing installation has been moved from that container onto this module and runs day to day, with MQTT input, feeds, dashboards and the background workers all working. The flake is meant to be usable as-is by anyone running NixOS; see [Migrating from the Docker container](#migrating-from-the-docker-container) if you are coming from the container.

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

The module builds Emoncms and its PHP with your system's `pkgs`, so `follows` only saves a second nixpkgs in your lock file. It is built and tested against nixos-26.05. Pin a release with `github:adamlc/emoncms-nix/v0.1.0` and move to a newer tag when you choose; [CHANGELOG.md](CHANGELOG.md) says which Emoncms version each release pins and what changed. `github:adamlc/emoncms-nix` follows `main`, which you move with `nix flake update emoncms`.

Flake outputs:

| Output | Contents |
|---|---|
| `nixosModules.default` (alias `nixosModules.emoncms`) | The `services.emoncms` module. It is self-contained and does not need the overlay. |
| `overlays.default` | Adds `pkgs.emoncms` and `pkgs.emoncms-php`, for overriding the package (see below). |
| `packages.<system>.{emoncms,emoncms-php,php-mosquitto}` | The same packages, for `x86_64-linux` and `aarch64-linux`. |
| `checks.<system>.{vm,formatting}` | The NixOS VM test (see Verification) and a `nixfmt` check. |
| `apps.<darwin>.vm`, `nixosConfigurations.vfkit-*` | The macOS test VM (see below). |

If you set `mqtt.createLocally = true` instead of using an existing broker, the module runs Mosquitto for you; open port 1883 too if devices on your network publish to it.

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

**MQTT extension.** `mgdm/Mosquitto-PHP` does not compile on PHP 8 (it fails on `TSRMLS_CC`). The flake builds OpenEnergyMonitor's fork with `php84.buildPecl`, against the same PHP that php-fpm and the workers use. The only packaging wrinkle is that its `config.m4` wants mosquitto's headers and library under one prefix, so it gets a `symlinkJoin` of `mosquitto.dev` and `mosquitto.lib`.

**Source patches** (sed at build time, in `pkgs/emoncms.nix`):
- `/var/www/emoncms` → the store web root. This path is hard-coded in sync, postprocess, backup and app scripts.
- `/opt/emoncms/modules` → the store modules dir.
- `/var/lock/*.lock` → `/run/emoncms/`. On NixOS `/run/lock` is root-only.
- The backup module's `/tmp/emoncms-flag-*` and `/tmp/backuplock` → `/run/emoncms/`. php-fpm and service-runner each have a private `/tmp`, so files they both need can't live there.
- service-runner takes `REDIS_HOST`/`REDIS_PORT` from the environment instead of assuming localhost.
- Backup scripts: `mysqldump -p"${password}"` only adds `-p` when a password is set, because socket auth has none and a bare `-p` prompts. They also call `emoncms-cli admin:dbupdate` instead of EmonScripts' `emoncmsdbupdate.php`. The import checks the username rather than the password before restoring the database, for the same reason.

The backup, sync and postprocess shell scripts call `sudo` and `systemctl`. service-runner's PATH has a `sudo` that simply runs the command unprivileged. Their `systemctl stop/start` calls fail as non-root, as they do in the container, so the export log reports "completed with ERRORS" even when the archive is fine.

php-fpm clears the environment, so the pool gets an explicit `PATH` (coreutils, grep, sed, awk, procps, systemd, util-linux, which, php). The postprocess and backup pages check for service-runner with `systemctl show` and `ps ax`, and without it they report service-runner as not running and postprocess jobs are never queued.

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

## Migrating from the Docker container

Your data is the MariaDB database (users, API keys, inputs, feeds' metadata, dashboards) and the timeseries files (`phpfina`, `phptimeseries`). Redis holds only caches and the feedwriter buffer, so it does not need to move. Either route below keeps your API keys, so devices posting over HTTP keep working once they point at the new host.

Before you start, deploy the module with an empty install and check you can reach the login page. Don't register a user on it; the import replaces the database.

**Route 1: the Backup module (recommended).** This is the route a real migration used.

1. In the container, stop new data arriving (or accept a small gap) and, if the container runs feedwriter, wait one interval (`redisbuffer[sleep]`, 300 s by default) so buffered values reach disk.
2. In the container's web UI, open Backup, run Export and download the archive.
3. On the NixOS host, register a temporary user (the first account is the admin), open Backup and upload the archive under Import. It restores the database and the timeseries files and runs the schema migrations. The temporary user is replaced by your old accounts, so sign in again with your old login.

The upload limit is 3 GB. For a larger archive use route 2.

**Route 2: copy the database and files by hand.**

1. Stop the container (so nothing writes while you copy), after the feedwriter wait above.
2. Dump the database from inside the container, e.g. `mysqldump emoncms > emoncms.sql`, and copy out the `phpfina` and `phptimeseries` directories from its data volume.
3. On the host, load the dump and put the files in place:

   ```sh
   sudo systemctl stop emoncms_mqtt feedwriter service-runner emoncms_sync phpfpm-emoncms
   sudo mysql emoncms < emoncms.sql
   sudo cp -a phpfina phptimeseries /var/opt/emoncms/
   sudo chown -R emoncms:emoncms /var/opt/emoncms
   sudo systemctl restart emoncms-setup    # applies schema migrations
   sudo systemctl start phpfpm-emoncms emoncms_mqtt service-runner   # plus feedwriter / emoncms_sync if enabled
   ```

   `sudo mysql` works because NixOS's MariaDB lets root in over the unix socket. Adjust `/var/opt/emoncms` if you changed `dataDir`.

**After either route:**

- Point your devices (emonhub, emonTx, other MQTT publishers or HTTP posters) at the new host, or move the old hostname over to it.
- Keep `mqtt.basetopic` (default `emon`) the same as the container's, or MQTT inputs will appear under new names.
- Settings you changed in the container's `settings.ini` don't come across, because `settings.ini` is generated from Nix. Set them with `services.emoncms.settings`.
- Check `journalctl -u emoncms_mqtt -f` shows incoming messages, and that feeds update on the Feeds page.
- Keep the container's volume until you're happy; switching back is just starting it again.

## Upgrading Emoncms later

1. Update the commits and hashes in `pkgs/sources.nix`. To get a hash, set it to `lib.fakeHash`, build, and copy the hash from the error.
2. Rebuild. `emoncms-setup` applies schema migrations on start.
3. Check the build still applies the sed patches above. `substituteInPlace --replace-fail` is used where a miss should fail the build.

For 11.9.10 → 12.x specifically: take a DB dump first (`mysqldump emoncms`). Version 12 rehashes passwords to bcrypt on login, so rolling back afterwards locks those users out, and a NixOS rollback does not roll back the database. Version 12's service-runner uses a script whitelist with `/opt/emoncms/modules` paths, which the sed patch covers.

## Verification

`nix flake check` runs `checks.<system>.vm` (`tests/vm.nix`). GitHub Actions runs it on every push and pull request (`.github/workflows/check.yml`): on an x86_64 runner with KVM, and on an `ubuntu-24.04-arm` runner, which has no KVM, so the test runs there under QEMU emulation, much slower than with KVM. It boots two NixOS VMs with the module: `machine` (local broker, feedwriter on) and `remote`, a second Emoncms for the sync module to talk to. It checks:

- `emoncms-setup` renders `settings.ini` with the MQTT secret substituted, and the secret is not in the store.
- Migrations run, and a second `emoncms-cli admin:dbupdate` reports "No migrations to run".
- nginx returns 403 for `/settings.ini` and `/scripts/…`, and serves the login page.
- Registering a user, fetching API keys and logging in work.
- **HTTP input** (`/input/post`) lands as an input.
- **MQTT input**: `mosquitto_pub emon/mqttnode/temp` is picked up by `emoncms_mqtt` and shows up as an input.
- A feed write through the Redis buffer is flushed to `phpfina/<id>.dat` by `feedwriter`.
- **Postprocess**: a `scalefeed` job created through the API is queued to `service-runner` and writes the scaled values.
- **Sync download**: after saving `remote` on the Sync page's API, a feed download is run by `service-runner` (`emoncms-sync.sh`) and the data arrives locally.
- **Sync upload**: flagging a feed for upload makes `emoncms_sync` create it on `remote` and upload its data.
- The backup page sees service-runner as running.
- **Backup round trip through the web endpoints**: `/backup/start` exports, `/backup/download` returns an archive with `emoncms.sql` and the phpfina data, and uploading it to `/backup/upload` imports it: a later input disappears, a deleted feed file comes back, and restored files stay writable by the `emoncms` user.
- php-fpm logs no PHP fatal errors.

Not verified:

1. **Migration routes.** A real installation has been migrated from the container with the Backup module route in [Migrating from the Docker container](#migrating-from-the-docker-container), but only from one container version. The manual route (copying the database and files) hasn't been tried. The container's Redis prefix is also `''`, so that matches.
2. **The archive's `settings.ini` is a symlink.** Backups contain it as a symlink to `/run/emoncms/settings.ini` rather than its contents. That's arguably right, since settings come from Nix, but it differs from the container.
3. **The export log always ends "completed with ERRORS"**, because of the `systemctl stop feedwriter` and `cd /boot` (Raspberry Pi) steps. The archive itself is fine.
4. **Edge cases of the `.htaccess` translation.** Odd paths, such as ones containing spaces, `&` or `%2F`, haven't been compared against Apache.
5. **Remote MariaDB/Redis** (`createLocally = false` with `passwordFile`) is implemented but not covered by the test.
6. **Version choices.** Module versions are the commits that were current while core 11.9.10 was the stable release. Device is 2.3.5, where the reference changelog says 2.3.3. The other module versions match the changelog.
7. **The vfkit launcher has been run on one Mac**, where the guest booted and the web login worked. Other commands, such as `reset`, haven't been checked there. Before that, the x86_64 guest image was built and booted under QEMU with the same disk layout (virtio root disk, a second disk with serial `emoncms-data`, virtio console on hvc0). That checked the root grows to fill its disk, `/var` is formatted on first boot and survives a rebuilt image, and Emoncms, MQTT input and SSH work.

## Licence

The Nix code in this repository is released under the [MIT licence](LICENSE), the same licence as nixpkgs, so any of it can be upstreamed there. It contains no Emoncms source; the build fetches Emoncms and its modules, which are AGPL-3.0, and the Mosquitto PHP extension, which is BSD-3-Clause. Those licences apply to the software you deploy. MIT is compatible with the AGPL, so combining the two is fine. If you change Emoncms itself and expose it to users over a network, the AGPL asks you to offer them your modified source.
