# Changelog

All notable changes to this flake are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the flake uses its own [semantic versioning](https://semver.org/spec/v2.0.0.html), independent of Emoncms's version number. Each release names the Emoncms version it pins.

While the version is 0.x, a minor bump (0.1 → 0.2) may change module options in a way that needs your configuration to change; patch releases do not.

## [Unreleased]

### Added

- `services.emoncms.gravatar.enable` (default off) turns on Emoncms's server-side gravatar avatars, cached in `/var/cache/emoncms/gravatar`. Emoncms only fetches from gravatar.com when that directory exists.
- README guide to migrating an existing installation from the Open-Building-Management Docker container, by Backup module export/import or by copying the database and timeseries files.

### Changed

- README notes that the flake is in real use and drops wording that assumed the repository was still private.
- **Emoncms moves from 11.9.10 to 11.19.8**, the last 11.x release. Take a database dump (`mysqldump emoncms`) before switching: `emoncms-setup` applies the schema migrations on first start, and from then on each user's password is rehashed to bcrypt when they log in, so rolling back to 11.9.10 without the dump locks those users out. A NixOS rollback does not roll back the database.
- Modules move with it: graph 2.2.7 → 3.4.4, dashboard 2.4.3 → 4.1.4, app 3.1.5 → 3.5.0, device 2.3.5 → 2.5.0, sync 3.2.2 → 3.5.1, postprocess 2.4.9 → 2.7.1, backup 2.3.5 → 2.5.0. These are each module's last versions before the Bootstrap 5 rewrite that belongs to Emoncms 12. 11.19.8 removes the vis and time modules and the old Flot charts, so custom pages or dashboards that loaded `vis/...` or `Lib/flot/` stop working.
- service-runner only runs jobs from its built-in whitelist (backup, sync, postprocess and a few admin actions), so anything else pushed onto its Redis queue is now rejected. The module passes it `EMONCMS_DIR` and `EMONCMS_LOG_DIR`.
- The nginx vhost no longer adds `X-Frame-Options: SAMEORIGIN` and `Referrer-Policy: same-origin`. Emoncms now sends these itself, set by the new `interface.frame_ancestors`, `embed_frame_ancestors` and `referrer_policy` settings. With the defaults, public dashboards, apps and `graph/embed` opened with a readkey can be framed by other sites, and the referrer policy is `strict-origin-when-cross-origin`. A page loaded with an Emoncms session cookie is always sent `frame_ancestors` (default `"self"`), so if you embed Emoncms in another site, such as Home Assistant, from a browser that is also logged in to Emoncms, the frame is blocked. List that site in `services.emoncms.settings.interface.frame_ancestors`, e.g. `"self https://ha.example.org"`. To block embedding entirely, set `interface.embed_frame_ancestors = "self"`.
- The backup module's generated `config.cfg` sets `drive_backup_enabled="no"`. The new attached-drive backup needs root, which service-runner does not have here.

### Deprecated

- Upstream moved the mail settings `smtp.from_email`, `smtp.from_name`, `smtp.default_emailto` and `smtp.sendmail` to a new `[email]` section (`email.from_email`, `email.from_name`, `email.default_to`, `email.transport`). The old names still work in 11.19.8; if you set them through `services.emoncms.settings`, move them when convenient.

### Removed

- The module no longer writes `interface.enable_update_ui`, which 11.19.8 dropped. The admin Update page is always shown now; its buttons do nothing on NixOS, as updates come from the flake pins.

### Security

- The locked nixpkgs (nixos-26.05) moves to `da6dc0e`, which ships PHP 8.4.27, fixing the critical PHP remote code execution flaws CVE-2026-109618 and CVE-2026-109619 (PHP 8.4.26 and earlier are affected). The module builds PHP from your system's nixpkgs, so to get the fix on a host, update that host's nixpkgs to a nixos-26.05 that has PHP 8.4.27 (for example `nix flake update nixpkgs`) and rebuild; updating this flake alone does not change the PHP your server runs.

## [0.1.0] - 2026-10-19

Pins **Emoncms 11.9.10**, PHP 8.4, nixos-26.05.

### Added

- Emoncms 11.9.10 packaged from upstream `emoncms/emoncms`, with modules graph 2.2.7, dashboard 2.4.3, app 3.1.5 and device 2.3.5 in `Modules/`, and sync 3.2.2, postprocess 2.4.9 and backup 2.3.5 as linked modules.
- Mosquitto PHP extension 0.5.1 (OpenEnergyMonitor's PHP 8 fork) built against the same PHP 8.4 as php-fpm and the workers.
- NixOS module `services.emoncms` running Emoncms as separate systemd units: MariaDB, Redis, optional local Mosquitto, a setup oneshot that renders `settings.ini` and applies schema migrations, php-fpm with nginx, and the `emoncms_mqtt`, `feedwriter`, `service-runner` and `emoncms_sync` workers.
- Secrets passed through `*File` options and systemd credentials, never the Nix store.
- NixOS VM tests for x86_64-linux and aarch64-linux, covering MQTT input, feeds, postprocess, sync and a backup export/import round trip.
- `nix run .#vm`, a vfkit test VM for macOS.

[Unreleased]: https://github.com/adamlc/emoncms-nix/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/adamlc/emoncms-nix/releases/tag/v0.1.0
