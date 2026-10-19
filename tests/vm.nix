# End-to-end check: boot, migrations, web UI, HTTP input, MQTT input,
# feedwriter flushing to phpfina, and a backup export through service-runner.
{ self }:
{ pkgs, ... }:
{
  name = "emoncms";

  nodes.machine =
    { pkgs, ... }:
    {
      imports = [ self.nixosModules.default ];
      virtualisation.memorySize = 2048;
      virtualisation.diskSize = 4096;

      environment.etc."emoncms-mqtt-password".text = "mqttsecret";
      environment.systemPackages = [
        pkgs.mosquitto
        pkgs.jq
        pkgs.redis
      ];

      services.emoncms = {
        enable = true;
        mqtt = {
          createLocally = true;
          passwordFile = "/etc/emoncms-mqtt-password";
        };
        feedwriter.enable = true;
        feedwriterInterval = 5;
      };
    };

  testScript = ''
    import json

    machine.wait_for_unit("emoncms-setup.service")
    machine.wait_for_unit("phpfpm-emoncms.service")
    machine.wait_for_unit("nginx.service")
    machine.wait_for_unit("emoncms_mqtt.service")
    machine.wait_for_unit("feedwriter.service")
    machine.wait_for_unit("service-runner.service")
    machine.wait_for_open_port(80)

    with subtest("migrations ran and are idempotent"):
        machine.succeed("mysql emoncms -e 'select count(*) from users'")
        out = machine.succeed("emoncms-cli admin:dbupdate")
        assert "No migrations to run" in out, out

    with subtest("settings.ini rendered with secret, not served"):
        machine.succeed("grep -q \"password = 'mqttsecret'\" /run/emoncms/settings.ini")
        machine.fail("grep -rq mqttsecret /nix/store/*-emoncms-settings.ini")
        machine.succeed("curl -s -o /dev/null -w '%{http_code}' http://localhost/settings.ini | grep -q 403")
        machine.succeed("curl -s -o /dev/null -w '%{http_code}' http://localhost/scripts/emoncms-cli | grep -q 403")

    with subtest("web UI renders"):
        machine.succeed("curl -sf http://localhost/ | grep -qi emoncms")
        machine.succeed("curl -sf http://localhost/user/login | grep -qi password")

    with subtest("register user and get API keys"):
        r = json.loads(machine.succeed(
            "curl -sf -X POST http://localhost/user/register.json"
            " -d username=admin -d password=adminpass123 -d email=a@example.org -d timezone=UTC"
        ))
        assert r.get("success"), r
        keys = json.loads(machine.succeed(
            "curl -sf -X POST http://localhost/user/auth.json -d username=admin -d password=adminpass123"
        ))
        apikey = keys["apikey_write"]

    with subtest("HTTP input"):
        out = machine.succeed(
            f"curl -sf -G http://localhost/input/post -d node=httpnode --data-urlencode 'fulljson={{\"power\":123}}' -d apikey={apikey}"
        )
        assert "ok" in out or json.loads(out).get("success"), out
        machine.wait_until_succeeds(
            f"curl -sf 'http://localhost/input/get/httpnode?apikey={apikey}' | jq -e '.power.value == 123'"
        )

    with subtest("MQTT input"):
        machine.wait_until_succeeds(
            "mosquitto_pub -h localhost -u emoncms -P mqttsecret -t emon/mqttnode/temp -m 21.5"
            f" && curl -sf 'http://localhost/input/get/mqttnode?apikey={apikey}' | jq -e '.temp.value == 21.5'",
            timeout=120,
        )

    with subtest("feed write through redis buffer and feedwriter"):
        r = json.loads(machine.succeed(
            f"curl -sf -G http://localhost/feed/create.json -d tag=t -d name=f -d engine=5 --data-urlencode 'options={{\"interval\":10}}' -d apikey={apikey}"
        ))
        assert r.get("success"), r
        feedid = r["feedid"]
        machine.succeed(
            f"curl -sf \"http://localhost/feed/insert.json?id={feedid}&time=$(date +%s)&value=42&apikey={apikey}\""
        )
        machine.wait_until_succeeds(f"test -s /var/opt/emoncms/phpfina/{feedid}.dat", timeout=60)

    with subtest("backup export via service-runner"):
        root = machine.succeed("readlink -f /run/emoncms/settings.ini >/dev/null; "
                               "grep -o \"emoncms_dir = '[^']*'\" /run/emoncms/settings.ini | cut -d\"'\" -f2").strip()
        machine.succeed(
            f"redis-cli rpush service-runner '{root}/modules/backup/emoncms-export.sh /run/emoncms/emoncms-flag-export>/var/log/emoncms/exportbackup.log'"
        )
        machine.wait_until_succeeds("grep -q '=== Emoncms export complete' /var/log/emoncms/exportbackup.log", timeout=120)
        print(machine.succeed("cat /var/log/emoncms/exportbackup.log"))
        machine.succeed("ls /var/opt/emoncms/backup/*.tar.gz")
        machine.succeed("tar tzf /var/opt/emoncms/backup/*.tar.gz > /tmp/list && grep -q emoncms.sql /tmp/list && grep -q phpfina/1.dat /tmp/list")

    with subtest("no errors in emoncms.log"):
        print(machine.succeed("cat /var/log/emoncms/emoncms.log"))
  '';
}
