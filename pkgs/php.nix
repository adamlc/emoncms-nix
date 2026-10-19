# PHP used by php-fpm and by every CLI worker, so extension ABI always matches.
{ php84, callPackage }:
let
  base = php84;
in
base.withExtensions (
  { enabled, all }:
  enabled
  ++ [
    all.redis
    (callPackage ./php-mosquitto.nix { php = base; })
  ]
)
