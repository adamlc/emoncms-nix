# `nix run .#vm` on macOS: boot the guest from ./guest.nix under vfkit.
{
  lib,
  writeShellApplication,
  vfkit,
  coreutils,
  curl,
  gawk,
  openssh,
  sshpass,
  image,
}:
writeShellApplication {
  name = "emoncms-vm";
  runtimeInputs = [
    vfkit
    coreutils
    curl
    gawk
    openssh
    sshpass
  ];
  text = ''
    image=${lib.escapeShellArg image}
    state="''${EMONCMS_VM_DIR:-''${XDG_STATE_HOME:-$HOME/.local/state}/emoncms-vm}"
    cpus="''${EMONCMS_VM_CPUS:-2}"
    memory="''${EMONCMS_VM_MEMORY:-2048}"
    root_size="''${EMONCMS_VM_ROOT_SIZE:-4G}"
    data_size="''${EMONCMS_VM_DATA_SIZE:-8G}"
    mac="''${EMONCMS_VM_MAC:-52:54:00:e0:c0:15}"
    sock="$state/vfkit.sock"
    pidfile="$state/vfkit.pid"

    usage() {
      cat <<USAGE
    Usage: emoncms-vm [command]

      start        Boot the VM in this terminal (serial console; 'poweroff' to quit)
      start -d     Boot in the background, wait for Emoncms, print its URL
      stop         Shut the VM down
      status       Say whether the VM is running, and its address
      ip           Print the VM's IP address
      ssh [cmd]    SSH in as root (password: emoncms)
      log          Follow the console log of a background VM
      reset        Delete the VM's disks (all Emoncms data)

    State lives in $state (override with EMONCMS_VM_DIR).
    USAGE
    }

    die() { echo "emoncms-vm: $*" >&2; exit 1; }

    running() {
      [[ -f $pidfile ]] && kill -0 "$(cat "$pidfile")" 2>/dev/null
    }

    # vmnet's DHCP server writes leases with leading zeros stripped from
    # each MAC octet (52:54:0:e0:c0:15).
    vm_ip() {
      local short ip
      short=$(echo "$mac" | awk -F: '{for (i = 1; i <= NF; i++) { sub(/^0/, "", $i); printf "%s%s", $i, (i < NF ? ":" : "") }}')
      [[ -r /var/db/dhcpd_leases ]] || return 1
      ip=$(awk -v mac="$short" '
        /^\{/ { ip = ""; hw = "" }
        /ip_address=/ { sub(/.*ip_address=/, ""); ip = $0 }
        /hw_address=/ { sub(/.*hw_address=[0-9]+,/, ""); hw = $0 }
        /^\}/ { if (hw == mac && ip != "") { print ip; exit } }
      ' /var/db/dhcpd_leases)
      [[ -n $ip ]] && echo "$ip"
    }

    wait_ip() {
      local ip
      for _ in $(seq 1 120); do
        if ip=$(vm_ip); then echo "$ip"; return 0; fi
        running || return 1
        sleep 1
      done
      return 1
    }

    prepare() {
      [[ $(uname -s) == Darwin ]] || die "vfkit only runs on macOS"
      running && die "already running (pid $(cat "$pidfile")); use 'stop' first"
      mkdir -p "$state"
      if [[ ! -f $state/root.raw || "$(cat "$state/image" 2>/dev/null)" != "$image" ]]; then
        [[ -f $state/root.raw ]] && echo "Flake changed: replacing the root disk (data disk at /var is kept)."
        rm -f "$state/root.raw"
        # -c clones on APFS instead of copying.
        cp -c "$image" "$state/root.raw" 2>/dev/null || cp "$image" "$state/root.raw"
        chmod u+w "$state/root.raw"
        truncate -s ">$root_size" "$state/root.raw"
        echo "$image" > "$state/image"
      fi
      [[ -f $state/data.raw ]] || truncate -s "$data_size" "$state/data.raw"
      rm -f "$sock"
    }

    vfkit_args() {
      printf '%s\n' \
        --cpus "$cpus" --memory "$memory" \
        --bootloader "efi,variable-store=$state/efi-vars.fd,create" \
        --device "virtio-blk,path=$state/root.raw" \
        --device "virtio-blk,path=$state/data.raw,deviceId=emoncms-data" \
        --device "virtio-net,nat,mac=$mac" \
        --device virtio-rng \
        --restful-uri "unix://$sock"
    }

    cmd_start() {
      prepare
      local args
      mapfile -t args < <(vfkit_args)
      if [[ ''${1:-} == -d ]]; then
        : > "$state/console.log"
        nohup vfkit "''${args[@]}" --device "virtio-serial,logFilePath=$state/console.log" \
          > "$state/vfkit.log" 2>&1 &
        echo $! > "$pidfile"
        echo "Booting (console log: $state/console.log)..."
        local ip
        ip=$(wait_ip) || die "no DHCP lease seen; check $state/console.log and $state/vfkit.log"
        echo "VM is at $ip, waiting for Emoncms..."
        for _ in $(seq 1 300); do
          if curl -sf -o /dev/null "http://$ip/user/login"; then
            echo "Emoncms is up: http://$ip/  (register the first user there)"
            echo "MQTT broker: $ip:1883, user emoncms, password emoncms"
            return 0
          fi
          running || die "VM exited; see $state/console.log"
          sleep 1
        done
        die "Emoncms did not answer at http://$ip/; try 'emoncms-vm ssh journalctl -b'"
      else
        echo "Starting VM; log in is automatic, 'poweroff' quits. Run 'emoncms-vm ip' from another terminal for the address."
        echo $$ > "$pidfile"
        exec vfkit "''${args[@]}" --device virtio-serial,stdio
      fi
    }

    cmd_stop() {
      running || { echo "not running"; return 0; }
      local pid
      pid=$(cat "$pidfile")
      # A clean guest shutdown lets MariaDB flush; vfkit's Stop is the fallback.
      local ip
      if ip=$(vm_ip); then
        SSHPASS=emoncms sshpass -e ssh -o ConnectTimeout=5 \
          -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
          "root@$ip" systemctl poweroff 2>/dev/null || true
      fi
      for _ in $(seq 1 30); do
        kill -0 "$pid" 2>/dev/null || { rm -f "$pidfile"; echo "stopped"; return 0; }
        sleep 1
      done
      curl -sf --unix-socket "$sock" -X POST http://vfkit/vm/state -d '{"state":"Stop"}' >/dev/null || true
      for _ in $(seq 1 30); do
        kill -0 "$pid" 2>/dev/null || { rm -f "$pidfile"; echo "stopped"; return 0; }
        sleep 1
      done
      echo "guest did not shut down, forcing"
      curl -sf --unix-socket "$sock" -X POST http://vfkit/vm/state -d '{"state":"HardStop"}' >/dev/null || kill "$pid"
      rm -f "$pidfile"
    }

    cmd_ssh() {
      local ip
      ip=$(vm_ip) || die "no address for the VM yet"
      SSHPASS=emoncms exec sshpass -e ssh \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        "root@$ip" "$@"
    }

    case "''${1:-start}" in
      start) shift || true; cmd_start "$@" ;;
      stop) cmd_stop ;;
      status)
        if running; then echo "running (pid $(cat "$pidfile")) at $(vm_ip || echo '?')"; else echo "not running"; fi ;;
      ip) vm_ip || die "no address for the VM yet" ;;
      ssh) shift; cmd_ssh "$@" ;;
      log) exec tail -f "$state/console.log" ;;
      reset)
        running && die "stop the VM first"
        rm -f "$state"/{root.raw,data.raw,efi-vars.fd,image,console.log,vfkit.log}
        echo "VM disks deleted" ;;
      -h|--help|help) usage ;;
      *) usage >&2; exit 1 ;;
    esac
  '';
}
