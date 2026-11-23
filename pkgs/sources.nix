# Pinned upstream sources. Emoncms core 12.2.1 (2026-11-10, the stable branch
# head), plus each module's release on its stable branch, except sync, which
# is pinned to master for the upstream fix to the uploader's startup feed
# list load. Versions are those in each commit's module.json.
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
    version = "12.2.1";
    src =
      gh "emoncms" "emoncms" "148764d238cfd66ac8b527cac1de22f06cb06ff4"
        "sha256-RGDG9J9a3wuqbEsnQguZD1wmGOWAb6qubp1KdYf+zJI=";
  };

  # Installed directly into Modules/<name>
  modules = {
    graph = {
      version = "3.5.0";
      src =
        gh "emoncms" "graph" "70a249c4380d25f2965a644433dd4bda0f0ad1fd"
          "sha256-fx4f3HVOpgBvkgMOkmIcCQio5lV+DrAnF+cEnvTVqp0=";
    };
    dashboard = {
      version = "4.2.1";
      src =
        gh "emoncms" "dashboard" "5c8b09cbd8c53e44a99a3bbdaf24f52992675bdd"
          "sha256-nrCcztccXedt1Pl2WtKRc10TvNNumJqX9EXXJR8ebYY=";
    };
    app = {
      version = "3.8.4";
      src =
        gh "emoncms" "app" "5a91cba18ac08c8dbe8e33811f12ea915b04399b"
          "sha256-01Tl8FL8VfG3kD3hxTb25eA+99moZFaarMzwlR5ZdsM=";
    };
    device = {
      version = "2.6.2";
      src =
        gh "emoncms" "device" "a72109f8665f0cadd299aea60aae8ecc5fe19380"
          "sha256-mVwGP8aR+hLgBIKaa9l98p1KLVBdFiapACFmo5x8lkA=";
    };
  };

  # Installed under <emoncms_dir>/modules/<name>, with <name>-module symlinked into Modules/
  linkedModules = {
    sync = {
      # master: 3.6.0 plus "Retry feed list load instead of idling forever",
      # which replaces this flake's own patch for the same bug.
      version = "3.6.0";
      src =
        gh "emoncms" "sync" "c3838f2edf1a0f47cafeeea0762a1adb78b324ce"
          "sha256-NBctwyBHzr48pFveqSFvzg9r8pKHq5hthyU6UHuCDKU=";
    };
    postprocess = {
      version = "2.8.0";
      src =
        gh "emoncms" "postprocess" "81eccb16e89c12216fc9328c56f63b07917c114d"
          "sha256-qtTwZM1AD+QWmWNFXLaXCzHXUyoIOqQ5ZAPU9JrGCuk=";
    };
    backup = {
      version = "2.6.0";
      src =
        gh "emoncms" "backup" "3aad63259e3e3bd1ce13ac67d08fee9f45c9d4a7"
          "sha256-JY5qVNdvJM0iRubbJX7DcP1bLIrrua+k3ixMORnNLrI=";
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
