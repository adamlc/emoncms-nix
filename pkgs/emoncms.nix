# Emoncms core + modules assembled into one read-only tree:
#
#   $out/share/emoncms/www                 web root (core, Modules/<name>)
#   $out/share/emoncms/modules/<name>      "linked" modules (sync, postprocess, backup)
#   $out/share/emoncms                     is what settings.ini calls emoncms_dir
#
# Runtime state lives outside the store. The tree contains symlinks into
# /run/emoncms for files the NixOS module renders at boot:
#   www/settings.ini                  -> /run/emoncms/settings.ini
#   modules/backup/config.cfg         -> /run/emoncms/backup-config.cfg
{
  lib,
  stdenvNoCC,
  callPackage,
  bash,
  modules ? [
    "graph"
    "dashboard"
    "app"
    "device"
  ],
  linkedModules ? [
    "sync"
    "postprocess"
    "backup"
  ],
}:
let
  sources = callPackage ./sources.nix { };
  pick =
    set: names:
    map (n: {
      name = n;
      src = set.${n}.src or (throw "emoncms: unknown module '${n}'");
    }) names;
in
stdenvNoCC.mkDerivation {
  pname = "emoncms";
  inherit (sources.emoncms) version src;

  buildInputs = [ bash ]; # for patchShebangs of module shell scripts

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall

    root=$out/share/emoncms
    mkdir -p $root/modules
    cp -r . $root/www
    chmod -R u+w $root/www

    ${lib.concatMapStrings (m: ''
      cp -r ${m.src} $root/www/Modules/${m.name}
    '') (pick sources.modules modules)}

    ${lib.concatMapStrings (m: ''
      cp -r ${m.src} $root/modules/${m.name}
      if [ -d $root/modules/${m.name}/${m.name}-module ]; then
        ln -s $root/modules/${m.name}/${m.name}-module $root/www/Modules/${m.name}
      fi
    '') (pick sources.linkedModules linkedModules)}
    chmod -R u+w $root

    ln -s /run/emoncms/settings.ini $root/www/settings.ini
    ${lib.optionalString (lib.elem "backup" linkedModules) ''
      ln -s /run/emoncms/backup-config.cfg $root/modules/backup/config.cfg
    ''}

    # Debian/Docker paths baked into the PHP, shell and Python sources.
    # /var/lock is root-only on NixOS, and /tmp is private per service, so
    # lock and flag files that cross process boundaries go to /run/emoncms.
    find $root -type f \( -name '*.php' -o -name '*.sh' -o -name '*.py' \) -print0 \
      | xargs -0 sed -i \
          -e "s|/var/www/emoncms|$root/www|g" \
          -e "s|/opt/emoncms/modules|$root/modules|g" \
          -e "s|/var/lock/|/run/emoncms/|g" \
          -e "s|/tmp/emoncms-flag-|/run/emoncms/emoncms-flag-|g" \
          -e "s|/tmp/backuplock|/run/emoncms/backuplock|g"

    # service-runner (11.9.x) always connects to localhost:6379
    substituteInPlace $root/www/scripts/services/service-runner/service-runner.py \
      --replace-fail "import redis" "import os
    import redis" \
      --replace-fail "redis.Redis()" \
        'redis.Redis(host=os.environ.get("REDIS_HOST", "localhost"), port=int(os.environ.get("REDIS_PORT", "6379")))'

    ${lib.optionalString (lib.elem "backup" linkedModules) ''
      for f in $root/modules/backup/*.sh; do
        # The DB user may authenticate by unix socket and have no password;
        # a bare -p"" makes mysql/mysqldump prompt on a missing TTY.
        sed -i 's|-p"''${password}"|''${password:+-p"''${password}"}|g' "$f"
        # EmonScripts is not installed; run the core migration instead
        sed -i "s|php /opt/openenergymonitor/EmonScripts/common/emoncmsdbupdate.php|(cd $root/www \&\& php scripts/emoncms-cli admin:dbupdate)|; s|-f /opt/openenergymonitor/EmonScripts/common/emoncmsdbupdate.php|-d $root/www|" "$f"
      done
      # ...and the import treats an empty password as unreadable settings.
      substituteInPlace $root/modules/backup/emoncms-import.sh \
        --replace-fail 'if [ -n "$password" ]' 'if [ -n "$username" ]'
    ''}

    runHook postInstall
  '';

  passthru = {
    webRoot = "share/emoncms/www";
    inherit modules linkedModules;
  };

  meta = {
    description = "Web app for processing, logging and visualising energy, temperature and other environmental data";
    homepage = "https://github.com/emoncms/emoncms";
    license = lib.licenses.agpl3Plus;
    platforms = lib.platforms.linux;
  };
}
