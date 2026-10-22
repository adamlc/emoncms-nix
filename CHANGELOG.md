# Changelog

All notable changes to this flake are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the flake uses its own [semantic versioning](https://semver.org/spec/v2.0.0.html), independent of Emoncms's version number. Each release names the Emoncms version it pins.

While the version is 0.x, a minor bump (0.1 → 0.2) may change module options in a way that needs your configuration to change; patch releases do not.

## [Unreleased]

### Added

- README guide to migrating an existing installation from the Open-Building-Management Docker container, by Backup module export/import or by copying the database and timeseries files.

### Changed

- README notes that the flake is in real use and drops wording that assumed the repository was still private.

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
