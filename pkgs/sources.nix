# Pinned upstream sources. Emoncms core 11.19.8 (2026-09-29), the last 11.x
# release, plus each module's last commit before its Bootstrap 5 conversion
# (2026-09-24), which belongs to Emoncms 12 and does not render on the 11.x
# core. Versions are those in each commit's module.json.
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
    version = "11.19.8";
    src =
      gh "emoncms" "emoncms" "7f8a5b2d4df399599bbb8026c064d956a5a85f34"
        "sha256-iTc1i+/KmsFkCN1iLGE9etfYST+XDEJCtX6n2cDPFJM=";
  };

  # Installed directly into Modules/<name>
  modules = {
    graph = {
      version = "3.4.4";
      src =
        gh "emoncms" "graph" "01aa8f29abfc021b21bd0527e52ce04edcf3e4f4"
          "sha256-h9dIsoJzhKdh4X3JuHQbwRg1fWRdTBxZ9LOw0SX3Zxc=";
    };
    dashboard = {
      version = "4.1.4";
      src =
        gh "emoncms" "dashboard" "12e15bc5cc7ed9b9919855b1f98f2bfcdabcd630"
          "sha256-0VVoW0lOh0sBVVqt/Xz+QT3ybEoZ1Y3pgf5fB7mA12Q=";
    };
    app = {
      version = "3.5.0";
      src =
        gh "emoncms" "app" "52ff3d9ace5e81e38833be501c5290e5fdb08c16"
          "sha256-ItB+RZ/OjgyHfjxmZQBw2FWpLpUq83PTTk4GgUObOVw=";
    };
    device = {
      version = "2.5.0";
      src =
        gh "emoncms" "device" "642309e65988ebe6c669c3fd4db97b52c6be6a46"
          "sha256-1n4ZoS8w9k1r+Xm+ZejPfud9i9QEztdmlpO9pbrnwyM=";
    };
  };

  # Installed under <emoncms_dir>/modules/<name>, with <name>-module symlinked into Modules/
  linkedModules = {
    sync = {
      version = "3.5.1";
      src =
        gh "emoncms" "sync" "a5f65a5e6f883f95a874c7d4810bf65a1c4c2642"
          "sha256-/reF+dEjWL8zWvOu1R/NBJN4DAfxg4/quHgeW7DcqFU=";
    };
    postprocess = {
      version = "2.7.1";
      src =
        gh "emoncms" "postprocess" "592db530dcc92859e81df78f5fcd8808c2cf2c28"
          "sha256-7OWqN2p2lHqP7mkyF5OLKNYpqNJeaCQx7M5KIKsdMb8=";
    };
    backup = {
      version = "2.5.0";
      src =
        gh "emoncms" "backup" "30c922bbe4289059d2c5097e688638fc2d85b72c"
          "sha256-IAPLKh/Y/HVOTSLaGIgFbDpYzbLYLmScdXGEvhB2j+A=";
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
