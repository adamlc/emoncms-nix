{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib)
    mkOption
    mkEnableOption
    mkIf
    mkMerge
    mkDefault
    types
    optional
    optionals
    optionalAttrs
    ;

  cfg = config.services.emoncms;

  root = "${cfg.package}/share/emoncms";
  webRoot = "${root}/www";
  php = "${cfg.phpPackage}/bin/php";
  fpmSocket = config.services.phpfpm.pools.emoncms.socket;

  # ---------------------------------------------------------------------------
  # settings.ini
  #
  # Emoncms merges default-settings.ini (shipped in the package) with
  # settings.ini, so only overrides are written. Secrets are written as
  # placeholders here and substituted at boot by emoncms-setup.
  # ---------------------------------------------------------------------------
  secretPlaceholder = name: "@EMONCMS_SECRET_${name}@";

  iniValue =
    v:
    if lib.isBool v then
      lib.boolToString v
    else if lib.isInt v then
      toString v
    else if lib.isList v then
      "[${lib.concatMapStringsSep "," toString v}]"
    else if lib.hasInfix "'" (toString v) then
      throw "services.emoncms.settings: values may not contain a single quote: ${toString v}"
    else
      "'${toString v}'";

  # Nested attrsets inside a section become key[sub] = value
  # (e.g. feed.phpfina.datadir -> phpfina[datadir]).
  iniLines =
    prefix: attrs:
    lib.concatLists (
      lib.mapAttrsToList (
        k: v:
        let
          key = if prefix == "" then k else "${prefix}[${k}]";
        in
        if v == null then
          [ ]
        else if lib.isAttrs v then
          iniLines key v
        else
          [ "${key} = ${iniValue v}" ]
      ) attrs
    );

  settingsIni =
    let
      globals = lib.filterAttrs (_: v: !(lib.isAttrs v)) cfg.settings;
      sections = lib.filterAttrs (_: v: lib.isAttrs v) cfg.settings;
    in
    pkgs.writeText "emoncms-settings.ini" (
      lib.concatStringsSep "\n" (
        iniLines "" globals
        ++ lib.concatLists (
          lib.mapAttrsToList (
            name: attrs:
            [
              ""
              "[${name}]"
            ]
            ++ iniLines "" attrs
          ) sections
        )
      )
      + "\n"
    );

  # name -> { file; placeholder; } for every secret that ends up in settings.ini
  secrets =
    optionalAttrs (cfg.database.passwordFile != null) {
      sql_password = cfg.database.passwordFile;
    }
    // optionalAttrs (cfg.mqtt.enable && cfg.mqtt.passwordFile != null) {
      mqtt_password = cfg.mqtt.passwordFile;
    }
    // optionalAttrs (cfg.redis.passwordFile != null) {
      redis_auth = cfg.redis.passwordFile;
    };

  backupConfig = pkgs.writeText "emoncms-backup-config.cfg" ''
    user="${cfg.user}"
    backup_script_location="${root}/modules/backup"
    emoncms_location="${webRoot}"
    backup_location="${cfg.dataDir}/backup"
    database_path="${cfg.dataDir}"
    emonhub_config_path=""
    emonhub_specimen_config=""
    backup_source_path="${cfg.dataDir}/backup/uploads"
  '';

  hasBackup = lib.elem "backup" cfg.package.linkedModules;
  hasSync = lib.elem "sync" cfg.package.linkedModules;

  localDb = cfg.database.createLocally;
  localRedis = cfg.redis.createLocally;
  localMqtt = cfg.mqtt.enable && cfg.mqtt.createLocally;

  backendUnits =
    optional localDb "mysql.service"
    ++ optional localRedis "redis-emoncms.service"
    ++ optional localMqtt "mosquitto.service";

  # Shared by php-fpm-adjacent workers
  workerService =
    {
      description,
      exec,
      after ? [ ],
      restart ? "on-failure",
      extra ? { },
    }:
    lib.recursiveUpdate {
      inherit description;
      wantedBy = [ "multi-user.target" ];
      requires = [ "emoncms-setup.service" ];
      after = [ "emoncms-setup.service" ] ++ backendUnits ++ after;
      restartTriggers = [
        settingsIni
        cfg.package
      ];
      serviceConfig = {
        User = cfg.user;
        Group = cfg.group;
        WorkingDirectory = webRoot;
        ExecStart = exec;
        Restart = restart;
        RestartSec = "10s";
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        NoNewPrivileges = true;
        ReadWritePaths = [
          cfg.dataDir
          cfg.logDir
          "/run/emoncms"
        ];
      };
    } extra;

  # The backup/sync/postprocess shell scripts call `sudo <cmd>` and `systemctl`.
  # Run the commands unprivileged instead; systemctl calls simply fail, as they
  # do in the reference container.
  sudoShim = pkgs.writeShellScriptBin "sudo" ''exec "$@"'';
in
{
  options.services.emoncms = {
    enable = mkEnableOption "Emoncms energy monitoring web app";

    package = mkOption {
      type = types.package;
      default = pkgs.callPackage ../pkgs/emoncms.nix { };
      defaultText = lib.literalExpression "emoncms 11.9.10 with graph, dashboard, app, device, sync, postprocess, backup";
      description = ''
        Emoncms tree. Override `modules` / `linkedModules` on it to change which
        modules are installed, e.g. `pkgs.emoncms.override { linkedModules = [ "postprocess" ]; }`.
      '';
    };

    phpPackage = mkOption {
      type = types.package;
      default = pkgs.callPackage ../pkgs/php.nix { };
      defaultText = lib.literalExpression "php84 with redis and mosquitto extensions";
      description = "PHP used by php-fpm and all workers. Must include the redis (and, for MQTT, mosquitto) extensions.";
    };

    user = mkOption {
      type = types.str;
      default = "emoncms";
      description = "User running php-fpm and all workers. They share the timeseries files, so they must be the same user.";
    };

    group = mkOption {
      type = types.str;
      default = "emoncms";
      description = "Group for the Emoncms user.";
    };

    dataDir = mkOption {
      type = types.path;
      default = "/var/opt/emoncms";
      description = "Timeseries data (phpfina, phptimeseries) and backups. Upstream's default location.";
    };

    logDir = mkOption {
      type = types.path;
      default = "/var/log/emoncms";
      description = "Directory for emoncms.log and the logs of background jobs.";
    };

    logLevel = mkOption {
      type = types.enum [
        1
        2
        3
      ];
      default = 2;
      description = "1 = info, 2 = warn, 3 = error.";
    };

    hostName = mkOption {
      type = types.str;
      default = "localhost";
      example = "emoncms.example.org";
      description = ''
        nginx virtual host name. Further vhost settings (TLS, ACME, listen
        addresses) can be set directly on `services.nginx.virtualHosts.<hostName>`.
      '';
    };

    nginx.enable = mkOption {
      type = types.bool;
      default = true;
      description = "Configure an nginx virtual host serving Emoncms through php-fpm.";
    };

    database = {
      createLocally = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Run MariaDB locally and create the database and a user authenticated
          by unix socket (no password).
        '';
      };
      host = mkOption {
        type = types.str;
        default = "localhost";
        description = "Database host. `localhost` uses the unix socket.";
      };
      port = mkOption {
        type = types.port;
        default = 3306;
        description = "Database port.";
      };
      name = mkOption {
        type = types.str;
        default = "emoncms";
        description = "Database name.";
      };
      user = mkOption {
        type = types.str;
        default = cfg.user;
        defaultText = lib.literalExpression "config.services.emoncms.user";
        description = "Database user. With createLocally it must equal services.emoncms.user (socket auth).";
      };
      passwordFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "File holding the database password. Not needed with createLocally.";
      };
    };

    redis = {
      createLocally = mkOption {
        type = types.bool;
        default = true;
        description = "Run a dedicated Redis instance (redis-emoncms.service) without persistence, as the reference container does.";
      };
      host = mkOption {
        type = types.str;
        default = "127.0.0.1";
        description = "Redis host.";
      };
      port = mkOption {
        type = types.port;
        default = 6379;
        description = "Redis port.";
      };
      prefix = mkOption {
        type = types.str;
        default = "";
        description = ''
          Redis key prefix. Must be empty (or "emoncms" with a colon-aware
          service-runner) for 11.9.x's service-runner to see queued jobs; empty
          matches the reference container.
        '';
      };
      passwordFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "File holding the Redis password, for a remote Redis with AUTH.";
      };
    };

    mqtt = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Subscribe to MQTT for input (runs the emoncms_mqtt worker).";
      };
      createLocally = mkOption {
        type = types.bool;
        default = false;
        description = "Run a local Mosquitto broker. Off by default: point host/port at an existing broker.";
      };
      host = mkOption {
        type = types.str;
        default = "localhost";
        description = "MQTT broker host.";
      };
      port = mkOption {
        type = types.port;
        default = 1883;
        description = "MQTT broker port.";
      };
      user = mkOption {
        type = types.str;
        default = "emoncms";
        description = "MQTT user. Leave empty for an anonymous broker.";
      };
      passwordFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "File holding the MQTT password.";
      };
      basetopic = mkOption {
        type = types.str;
        default = "emon";
        description = "Topic prefix Emoncms subscribes to (`<basetopic>/<node>/<input>`).";
      };
      clientId = mkOption {
        type = types.str;
        default = "emoncms";
        description = "MQTT client id.";
      };
      localBroker = {
        address = mkOption {
          type = types.str;
          default = "0.0.0.0";
          description = "Address the local broker listens on (devices such as emonhub publish to it).";
        };
        users = mkOption {
          type = types.attrsOf types.anything;
          default = { };
          example = lib.literalExpression ''{ emonhub = { passwordFile = "/run/secrets/emonhub-mqtt"; acl = [ "write emon/#" ]; }; }'';
          description = "Extra users for the local broker's listener, in services.mosquitto `users` format.";
        };
      };
    };

    feedwriter.enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Low-write mode: buffer feed writes in Redis and flush them with the
        feedwriter worker every `redisbuffer.sleep` seconds. The reference
        container enables this (it targets SD cards); data in the buffer is lost
        if the machine crashes.
      '';
    };

    feedwriterInterval = mkOption {
      type = types.ints.positive;
      default = 300;
      description = "Seconds between feedwriter flushes (redisbuffer[sleep]). The reference container uses 300.";
    };

    serviceRunner.enable = mkOption {
      type = types.bool;
      default = true;
      description = "Run service-runner, which executes jobs queued by the web UI (backup export/import, sync, postprocess).";
    };

    syncUpload.enable = mkOption {
      type = types.bool;
      default = hasSync;
      defaultText = lib.literalExpression "true when the sync module is installed";
      description = "Run the sync module's background uploader (pushes feeds to the remote Emoncms configured in the Sync page).";
    };

    settings = mkOption {
      type = types.submodule {
        freeformType =
          with types;
          attrsOf (oneOf [
            str
            int
            bool
            (listOf int)
            (attrsOf anything)
          ]);
      };
      default = { };
      example = lib.literalExpression ''
        {
          interface.enable_multi_user = true;
          interface.default_language = "en_GB";
          smtp.host = "smtp.example.org";
        }
      '';
      description = ''
        Extra settings.ini values, merged over the ones this module sets.
        Keys are exactly those in Emoncms's default-settings.ini; a nested
        attribute `feed.phpfina.datadir` is written as `phpfina[datadir]` in
        the `[feed]` section.
      '';
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      assertions = [
        {
          assertion = !localDb || cfg.database.user == cfg.user;
          message = "services.emoncms.database.user must equal services.emoncms.user when createLocally is set (socket authentication).";
        }
        {
          assertion = !localMqtt || cfg.mqtt.passwordFile != null || cfg.mqtt.user == "";
          message = "services.emoncms.mqtt.createLocally needs mqtt.passwordFile (or mqtt.user = \"\" for an anonymous broker).";
        }
      ];

      services.emoncms.settings = {
        emoncms_dir = mkDefault root;
        openenergymonitor_dir = mkDefault "/var/empty";
        display_errors = mkDefault false;
        sql = {
          server = mkDefault cfg.database.host;
          database = mkDefault cfg.database.name;
          username = mkDefault cfg.database.user;
          password = mkDefault (
            if cfg.database.passwordFile != null then secretPlaceholder "sql_password" else ""
          );
          port = mkDefault cfg.database.port;
          dbtest = mkDefault true;
        };
        redis = {
          enabled = mkDefault true;
          host = mkDefault cfg.redis.host;
          port = mkDefault cfg.redis.port;
          prefix = mkDefault cfg.redis.prefix;
          auth = mkDefault (if cfg.redis.passwordFile != null then secretPlaceholder "redis_auth" else "");
        };
        mqtt = {
          enabled = mkDefault cfg.mqtt.enable;
          host = mkDefault cfg.mqtt.host;
          port = mkDefault cfg.mqtt.port;
          user = mkDefault cfg.mqtt.user;
          password = mkDefault (
            if cfg.mqtt.passwordFile != null then secretPlaceholder "mqtt_password" else ""
          );
          basetopic = mkDefault cfg.mqtt.basetopic;
          client_id = mkDefault cfg.mqtt.clientId;
        };
        feed = {
          engines_hidden = mkDefault [
            0
            6
            8
            10
          ];
          redisbuffer = {
            enabled = mkDefault cfg.feedwriter.enable;
            sleep = mkDefault cfg.feedwriterInterval;
          };
          phpfina.datadir = mkDefault "${cfg.dataDir}/phpfina/";
          phptimeseries.datadir = mkDefault "${cfg.dataDir}/phptimeseries/";
        };
        interface = {
          feedviewpath = mkDefault "graph/";
          enable_admin_ui = mkDefault true;
          # Updates come from bumping the flake pins, not from the web UI
          enable_update_ui = mkDefault false;
        };
        log = {
          enabled = mkDefault true;
          location = mkDefault cfg.logDir;
          level = mkDefault cfg.logLevel;
        };
      };

      users.users = optionalAttrs (cfg.user == "emoncms") {
        emoncms = {
          isSystemUser = true;
          group = cfg.group;
          home = cfg.dataDir;
        };
      };
      users.groups = optionalAttrs (cfg.group == "emoncms") { emoncms = { }; };

      systemd.tmpfiles.settings."10-emoncms" =
        let
          dir = {
            d = {
              user = cfg.user;
              group = cfg.group;
              mode = "0750";
            };
          };
        in
        {
          ${cfg.dataDir} = dir;
          "${cfg.dataDir}/phpfina" = dir;
          "${cfg.dataDir}/phptimeseries" = dir;
          "${cfg.dataDir}/backup" = dir;
          "${cfg.dataDir}/backup/uploads" = dir;
          ${cfg.logDir} = dir;
          "${cfg.logDir}/emoncms.log".f = {
            user = cfg.user;
            group = cfg.group;
            mode = "0640";
          };
          "/run/emoncms" = dir;
        };

      # Replaces the container's emoncms_pre + sql_ready oneshots
      systemd.services.emoncms-setup = {
        description = "Emoncms configuration and database migration";
        wantedBy = [ "multi-user.target" ];
        requires = optional localDb "mysql.service";
        wants = backendUnits ++ [ "network-online.target" ];
        after = backendUnits ++ [
          "network-online.target"
          "systemd-tmpfiles-setup.service"
          "systemd-tmpfiles-resetup.service"
        ];
        restartTriggers = [
          settingsIni
          cfg.package
        ];
        path = [ pkgs.replace-secret ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          User = cfg.user;
          Group = cfg.group;
          WorkingDirectory = webRoot;
          LoadCredential = lib.mapAttrsToList (n: f: "${n}:${f}") secrets;
          UMask = "0027";
          ProtectSystem = "strict";
          ProtectHome = true;
          PrivateTmp = true;
          NoNewPrivileges = true;
          ReadWritePaths = [ "/run/emoncms" ];
        };
        script = ''
          set -eu
          tmp=/run/emoncms/settings.ini.tmp
          install -m 0640 ${settingsIni} "$tmp"
          ${lib.concatStrings (
            lib.mapAttrsToList (n: _: ''
              if grep -q "'" "$CREDENTIALS_DIRECTORY/${n}"; then
                echo "emoncms: secret ${n} contains a single quote, which settings.ini cannot hold" >&2
                exit 1
              fi
              replace-secret '${secretPlaceholder n}' "$CREDENTIALS_DIRECTORY/${n}" "$tmp"
            '') secrets
          )}
          mv "$tmp" /run/emoncms/settings.ini
          ${lib.optionalString hasBackup "install -m 0640 ${backupConfig} /run/emoncms/backup-config.cfg"}

          # Idempotent: applies any schema differences for core and installed modules.
          # emoncms-cli exits 0 even when it cannot connect, so check its output.
          out=$(${php} scripts/emoncms-cli admin:dbupdate 2>&1) || { echo "$out"; exit 1; }
          echo "$out"
          case "$out" in
            *"Can't connect"*|*"missing settings"*|*"Fatal error"*) exit 1 ;;
          esac
        '';
      };

      services.phpfpm.pools.emoncms = {
        user = cfg.user;
        group = cfg.group;
        phpPackage = cfg.phpPackage;
        phpOptions = ''
          max_execution_time = 300
          post_max_size = 3G
          upload_max_filesize = 3G
          upload_tmp_dir = ${cfg.dataDir}/backup/uploads
          expose_php = Off
        '';
        settings = {
          "listen.owner" = config.services.nginx.user;
          "listen.group" = config.services.nginx.group;
          "pm" = "dynamic";
          "pm.max_children" = 16;
          "pm.start_servers" = 2;
          "pm.min_spare_servers" = 1;
          "pm.max_spare_servers" = 4;
          "pm.max_requests" = 500;
          "catch_workers_output" = true;
        };
      };
      systemd.services.phpfpm-emoncms = {
        requires = [ "emoncms-setup.service" ];
        after = [ "emoncms-setup.service" ];
        restartTriggers = [ settingsIni ];
      };

      systemd.services.emoncms_mqtt = mkIf cfg.mqtt.enable (workerService {
        description = "Emoncms MQTT input";
        exec = "${php} ${webRoot}/scripts/services/emoncms_mqtt/emoncms_mqtt.php";
        after = [ "network-online.target" ];
        extra.wants = [ "network-online.target" ];
      });

      systemd.services.feedwriter = mkIf cfg.feedwriter.enable (workerService {
        description = "Emoncms feedwriter (flushes the Redis write buffer)";
        exec = "${php} ${webRoot}/scripts/feedwriter.php";
      });

      systemd.services.service-runner = mkIf cfg.serviceRunner.enable (workerService {
        description = "Emoncms service-runner (runs jobs queued by the web UI)";
        exec = "${
          pkgs.python3.withPackages (ps: [ ps.redis ])
        }/bin/python3 ${webRoot}/scripts/services/service-runner/service-runner.py";
        restart = "always";
        extra = {
          environment = {
            REDIS_HOST = cfg.redis.host;
            REDIS_PORT = toString cfg.redis.port;
          };
          path = [
            cfg.phpPackage
            sudoShim
            pkgs.bash
            pkgs.coreutils
            pkgs.findutils
            pkgs.gnugrep
            pkgs.gnused
            pkgs.gnutar
            pkgs.gzip
            pkgs.hostname
            pkgs.mariadb.client
            pkgs.redis
            pkgs.systemd
          ];
        };
      });

      systemd.services.emoncms_sync = mkIf (hasSync && cfg.syncUpload.enable) (workerService {
        description = "Emoncms sync module uploader";
        exec = "${php} ${root}/modules/sync/sync_upload.php all bg";
        restart = "always";
        extra.serviceConfig.RestartSec = "60s";
      });

      environment.systemPackages = [
        (pkgs.writeShellScriptBin "emoncms-cli" ''
          cd ${webRoot}
          exec ${pkgs.util-linux}/bin/runuser -u ${cfg.user} -- ${php} scripts/emoncms-cli "$@"
        '')
      ];
    }

    (mkIf localDb {
      services.mysql = {
        enable = true;
        package = mkDefault pkgs.mariadb;
        ensureDatabases = [ cfg.database.name ];
        ensureUsers = [
          {
            name = cfg.database.user;
            ensurePermissions."${cfg.database.name}.*" = "ALL PRIVILEGES";
          }
        ];
      };
    })

    (mkIf localRedis {
      services.redis.servers.emoncms = {
        enable = true;
        bind = cfg.redis.host;
        port = cfg.redis.port;
        # Cache and write buffer only, as in the reference container
        save = [ ];
      };
    })

    (mkIf localMqtt {
      services.mosquitto = {
        enable = true;
        persistence = false;
        listeners = [
          {
            address = cfg.mqtt.localBroker.address;
            port = cfg.mqtt.port;
            settings.allow_anonymous = cfg.mqtt.user == "";
            acl = optionals (cfg.mqtt.user == "") [ "topic readwrite #" ];
            users =
              optionalAttrs (cfg.mqtt.user != "") {
                ${cfg.mqtt.user} = {
                  passwordFile = cfg.mqtt.passwordFile;
                  acl = [ "readwrite #" ];
                };
              }
              // cfg.mqtt.localBroker.users;
          }
        ];
      };
    })

    (mkIf cfg.nginx.enable {
      services.nginx = {
        enable = true;
        recommendedGzipSettings = mkDefault true;
        recommendedOptimisation = mkDefault true;
        recommendedProxySettings = mkDefault true;
        virtualHosts.${cfg.hostName} = {
          root = webRoot;
          extraConfig = ''
            index index.php;
            client_max_body_size 3G;
            charset utf-8;
            add_header X-Content-Type-Options "nosniff" always;
            add_header X-Frame-Options "SAMEORIGIN" always;
            add_header Referrer-Policy "same-origin" always;
          '';
          locations = {
            # Translation of Emoncms's .htaccess
            "/".extraConfig = ''
              try_files $uri $uri/ @emoncms;
            '';
            "@emoncms".extraConfig = ''
              rewrite ^/(.*)$ /index.php?q=$1 last;
            '';
            # Legacy /emoncms/ prefix (RewriteRule ^emoncms/(.*)$ $1)
            "^~ /emoncms/".extraConfig = ''
              rewrite ^/emoncms/(.*)$ /$1 last;
            '';
            # Directories upstream denies with their own .htaccess
            "^~ /scripts/".extraConfig = "deny all;";
            "^~ /tests/".extraConfig = "deny all;";
            "= /php-info.php".extraConfig = "deny all;";
            "~ /\\.(?!well-known/)".extraConfig = "deny all;";
            # settings.ini, logs, shell scripts, dumps...
            "~* (^#.*#|\\.(bak|cfg|config|dist|fla|inc|ini|log|psd|sh|sql|swo|swp)|~)$".extraConfig =
              "deny all;";
            "~ \\.php$".extraConfig = ''
              try_files $uri =404;
              fastcgi_split_path_info ^(.+\.php)(/.+)$;
              include ${config.services.nginx.package}/conf/fastcgi.conf;
              fastcgi_param HTTP_AUTHORIZATION $http_authorization;
              fastcgi_read_timeout 300;
              fastcgi_pass unix:${fpmSocket};
            '';
          };
        };
      };
    })
  ]);
}
