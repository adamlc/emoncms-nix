# Pinned upstream sources. Emoncms core 11.9.10 plus the module commits that
# were current on each module's branch while 11.9.10 was the stable release
# (2025-09-17 .. 2025-09-20). Branches follow the reference Docker build:
# graph/dashboard/app/device from `stable`, sync/postprocess/backup from `master`.
{ fetchFromGitHub }:
let
  gh =
    owner: repo: rev: hash:
    fetchFromGitHub {
      inherit
        owner
        repo
        rev
        hash
        ;
    };
in
{
  emoncms = {
    version = "11.9.10";
    src =
      gh "emoncms" "emoncms" "995555e1451982a7b19a0392da53f5bfa8491028"
        "sha256-oDgn+2Aa/RLD2HCAAnC4KrY7fu3RhGM23WEhfpqgri4=";
  };

  # Installed directly into Modules/<name>
  modules = {
    graph = {
      version = "2.2.7";
      src =
        gh "emoncms" "graph" "4d6cec75219399d0646d80877a9d82697fc9feb1"
          "sha256-gYkhiphWubTBq42d5ipir04j1d2PUfMgiOHhamRZr30=";
    };
    dashboard = {
      version = "2.4.3";
      src =
        gh "emoncms" "dashboard" "c8edbf8979b55434bc2f2f0c27499fc277c061b4"
          "sha256-HcRAI2AtDVGwNyQC3e/qtmkXf3QSCa+a1pP55K7xzR0=";
    };
    app = {
      version = "3.1.5";
      src =
        gh "emoncms" "app" "81b0d1b28287031ddddfae2365f18f8e933327eb"
          "sha256-mktWulMeymVTIuCi4faaCrDwnvp5dA0BgVn65fHXceY=";
    };
    device = {
      version = "2.3.5";
      src =
        gh "emoncms" "device" "2e10f590339b271c358978625dd360a5921a1aac"
          "sha256-qqZFdwHGo/lDzbDyMggK9W70wY+Nm/sOISO8BlWsmCI=";
    };
  };

  # Installed under <emoncms_dir>/modules/<name>, with <name>-module symlinked into Modules/
  linkedModules = {
    sync = {
      version = "3.2.2";
      src =
        gh "emoncms" "sync" "f3602eb15abf9586ccd2e579bdca73e282396e13"
          "sha256-6IG0jcoruYLvolFWlRoUIXX1Lemp7bG2sntT+63qTUw=";
    };
    postprocess = {
      version = "2.4.9";
      src =
        gh "emoncms" "postprocess" "061e8da5f5c98254a36754d7da705ca6da32b392"
          "sha256-/itFfwwXkIKWP02ruwGcoC4Lw1nCwTEZitszaUhyFAg=";
    };
    backup = {
      version = "2.3.5";
      src =
        gh "emoncms" "backup" "d2742e2c125d27307de92577a420c8a35289ce80"
          "sha256-uIUTUrKcFYrFxrI/TRb8GBxMM5TgXcZnwL2v0rCZnp4=";
    };
  };

  mosquitto-php = {
    version = "0.5.1";
    # openenergymonitor fork, branch php8 (mgdm/Mosquitto-PHP does not build on PHP 8)
    src =
      gh "openenergymonitor" "Mosquitto-PHP" "426a08afc452a5779a1404ffb875aed375431dfa"
        "sha256-IOlqP4HEGyUNpS4ttLOIbDTyYwEMCIjNRAZJoLmq944=";
  };
}
