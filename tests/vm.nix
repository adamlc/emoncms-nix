# End-to-end check: boot, migrations, web UI, HTTP input, MQTT input,
# feedwriter flushing to phpfina, postprocess and sync jobs through
# service-runner, the sync uploader, and a backup export/import round trip
# driven through the backup module's web endpoints.
{ self }:
{ pkgs, ... }:
let
  common = {
    imports = [ self.nixosModules.default ];
    virtualisation.memorySize = pkgs.lib.mkDefault 2048;
    virtualisation.diskSize = 4096;
    networking.firewall.allowedTCPPorts = [ 80 ];
    environment.systemPackages = [
      pkgs.mosquitto
      pkgs.jq
      pkgs.redis
    ];
  };
in
{
  name = "emoncms";

  nodes.machine = {
    imports = [ common ];

    environment.etc."emoncms-mqtt-password".text = "mqttsecret";

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

  # A second Emoncms for the sync module to download from and upload to.
  nodes.remote = {
    imports = [ common ];
    virtualisation.memorySize = 1536;
    services.emoncms = {
      enable = true;
      mqtt.enable = false;
      syncUpload.enable = false;
    };
  };

  # Pipe page bodies into `grep ... >/dev/null`, not `grep -q`: -q stops
  # reading at the first match, and under pipefail the SIGPIPE'd curl
  # (exit 23) fails the command.
  testScript = ''
    import json

    start_all()

    def register(node, user):
        r = json.loads(node.succeed(
            "curl -sf -X POST http://localhost/user/register.json"
            f" -d username={user} -d password=adminpass123 -d email={user}@example.org -d timezone=UTC"
        ))
        assert r.get("success"), r
        keys = json.loads(node.succeed(
            f"curl -sf -X POST http://localhost/user/auth.json -d username={user} -d password=adminpass123"
        ))
        return keys["apikey_write"]

    def api(node, path, key):
        sep = "&" if "?" in path else "?"
        return json.loads(node.succeed(f"curl -sf 'http://localhost/{path}{sep}apikey={key}'"))

    def create_feed(node, key, tag, name):
        r = json.loads(node.succeed(
            f"curl -sf -G http://localhost/feed/create.json -d tag={tag} -d name={name} -d engine=5"
            f" --data-urlencode 'options={{\"interval\":10}}' -d apikey={key}"
        ))
        assert r.get("success"), r
        return r["feedid"]

    def feed_values(node, path):
        return [float(v) for v in node.succeed(f"od -An -v -f {path}").split() if v.lower() != "nan"]

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
        machine.succeed("curl -sf http://localhost/ | grep -i emoncms >/dev/null")
        machine.succeed("curl -sf http://localhost/user/login | grep -i password >/dev/null")

    with subtest("register user, API keys and a session"):
        apikey = register(machine, "admin")
        r = json.loads(machine.succeed(
            "curl -sf -c /tmp/jar -X POST http://localhost/user/login.json -d username=admin -d password=adminpass123"
        ))
        assert r.get("success"), r

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
        feedid = create_feed(machine, apikey, "t", "f")
        machine.succeed(
            f"curl -sf \"http://localhost/feed/insert.json?id={feedid}&time=$(date +%s)&value=42&apikey={apikey}\""
        )
        machine.wait_until_succeeds(f"test -s /var/opt/emoncms/phpfina/{feedid}.dat", timeout=60)

    with subtest("postprocess job through service-runner"):
        outid = create_feed(machine, apikey, "t", "f_x2")
        body = json.dumps({"process": "scalefeed", "input": feedid, "scale": 2, "output": outid})
        r = json.loads(machine.succeed(
            f"curl -sf -X POST 'http://localhost/postprocess/create.json?apikey={apikey}' -d '{body}'"
        ))
        assert r.get("success") and "not running" not in r.get("message", ""), r
        machine.wait_until_succeeds(
            f"curl -sf 'http://localhost/postprocess/list.json?apikey={apikey}' | jq -e '.[0].status == \"finished\"'",
            timeout=60,
        )
        print(machine.succeed("cat /var/log/emoncms/postprocess.log"))
        assert 84.0 in feed_values(machine, f"/var/opt/emoncms/phpfina/{outid}.dat")

    with subtest("sync: download a feed from a remote Emoncms"):
        remote.wait_for_unit("phpfpm-emoncms.service")
        remote.wait_for_open_port(80)
        remotekey = register(remote, "remoteuser")
        rfeed = create_feed(remote, remotekey, "rt", "rf")
        remote.succeed(
            f"curl -sf \"http://localhost/feed/insert.json?id={rfeed}&time=$(date +%s)&value=7&apikey={remotekey}\""
        )
        r = json.loads(machine.succeed(
            f"curl -sf -X POST 'http://localhost/sync/remote-save.json?apikey={apikey}'"
            f" -d host=http://remote -d write_apikey={remotekey}"
        ))
        assert r.get("success"), r
        r = api(machine, f"sync/download.json?name=rf&tag=rt&engine=5&interval=10&remoteid={rfeed}", apikey)
        assert r.get("success"), r
        machine.wait_until_succeeds("grep -q 'SYNC: Starting' /var/log/emoncms/sync.log", timeout=60)
        local = machine.wait_until_succeeds(
            f"curl -sf 'http://localhost/feed/getid.json?tag=rt&name=rf&apikey={apikey}' | grep -E '^[0-9]+$'"
        ).strip()
        machine.wait_until_succeeds(f"test -s /var/opt/emoncms/phpfina/{local}.dat", timeout=60)
        print(machine.succeed("cat /var/log/emoncms/sync.log"))
        assert 7.0 in feed_values(machine, f"/var/opt/emoncms/phpfina/{local}.dat")

    with subtest("sync: emoncms_sync uploads a feed to the remote"):
        api(machine, "sync/save-upload-interval.json?interval=10", apikey)
        r = api(machine, f"sync/upload.json?localid={feedid}", apikey)
        assert r.get("success"), r
        up = remote.wait_until_succeeds(
            f"curl -sf 'http://localhost/feed/getid.json?tag=t&name=f&apikey={remotekey}' | grep -E '^[0-9]+$'",
            timeout=180,
        ).strip()
        remote.wait_until_succeeds(f"test -s /var/opt/emoncms/phpfina/{up}.dat", timeout=120)
        print(machine.succeed("journalctl -u emoncms_sync --no-pager | tail -40"))
        assert 42.0 in feed_values(remote, f"/var/opt/emoncms/phpfina/{up}.dat")

    with subtest("backup page sees service-runner"):
        page = machine.succeed("curl -sf -b /tmp/jar http://localhost/backup")
        assert "service-runner is not running" not in page, page

    with subtest("backup export from the web UI"):
        machine.succeed("curl -sf -b /tmp/jar http://localhost/backup/start")
        machine.wait_until_succeeds(
            "curl -sf -b /tmp/jar http://localhost/backup/exportlog | grep '=== Emoncms export complete' >/dev/null",
            timeout=120,
        )
        print(machine.succeed("cat /var/log/emoncms/exportbackup.log"))
        machine.succeed("curl -sf -b /tmp/jar -o /tmp/backup.tar.gz http://localhost/backup/download")
        machine.succeed(
            "tar tzf /tmp/backup.tar.gz > /tmp/list"
            f" && grep -qx emoncms.sql /tmp/list && grep -qx phpfina/{feedid}.dat /tmp/list"
        )

    with subtest("backup import from the web UI restores DB and feeds"):
        # Diverge from the backup: a new input, and a feed's data deleted.
        machine.succeed(
            f"curl -sf -G http://localhost/input/post -d node=afterbackup --data-urlencode 'fulljson={{\"x\":1}}' -d apikey={apikey}"
        )
        machine.succeed(f"rm /var/opt/emoncms/phpfina/{outid}.dat")
        machine.succeed(
            "curl -sf -b /tmp/jar -o /dev/null -F file=@/tmp/backup.tar.gz http://localhost/backup/upload"
        )
        machine.wait_until_succeeds(
            "curl -sf -b /tmp/jar http://localhost/backup/importlog | grep -E '=== Emoncms import complete|Error' >/dev/null",
            timeout=120,
        )
        import_log = machine.succeed("cat /var/log/emoncms/importbackup.log")
        print(import_log)
        assert "Error" not in import_log, import_log
        machine.succeed(f"test -s /var/opt/emoncms/phpfina/{outid}.dat")
        inputs = api(machine, "input/list.json", apikey)
        assert not any(i["nodeid"] == "afterbackup" for i in inputs), inputs
        assert any(i["nodeid"] == "httpnode" for i in inputs), inputs
        # Restored files must stay writable by the workers.
        machine.succeed(f"runuser -u emoncms -- test -w /var/opt/emoncms/phpfina/{feedid}.dat")

    with subtest("no PHP fatals"):
        print(machine.succeed("cat /var/log/emoncms/emoncms.log"))
        machine.fail("journalctl -u phpfpm-emoncms | grep -i 'PHP Fatal'")
  '';
}
