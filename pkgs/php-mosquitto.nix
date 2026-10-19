# Mosquitto-PHP extension. Must be built with the same `php` that loads it.
{
  php,
  mosquitto,
  symlinkJoin,
  callPackage,
  lib,
}:
let
  sources = callPackage ./sources.nix { };
  # config.m4 expects include/mosquitto.h and lib/libmosquitto.so under one prefix
  mosquittoPrefix = symlinkJoin {
    name = "mosquitto-prefix";
    paths = [
      mosquitto.dev
      mosquitto.lib
    ];
  };
in
php.buildPecl {
  pname = "mosquitto";
  inherit (sources.mosquitto-php) version src;
  buildInputs = [ mosquitto ];
  configureFlags = [ "--with-mosquitto=${mosquittoPrefix}" ];
  meta = {
    description = "PHP extension for the Mosquitto MQTT client library (OpenEnergyMonitor PHP 8 fork)";
    homepage = "https://github.com/openenergymonitor/Mosquitto-PHP";
    license = lib.licenses.bsd3;
  };
}
