# This function receives 'self' from the flake, so we can access the package source
{ self }:
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.zortex;

  # We define the package here using the source from the flake to ensure
  # the module is self-contained and uses the correct version of python/libs
  # from the user's system (pkgs).
  zortexPkg = pkgs.python3Packages.buildPythonApplication {
    pname = "zortex";
    version = "1.0.0";
    format = "other";

    src = self; # Points to the flake root

    propagatedBuildInputs = with pkgs.python3Packages; [
      flask
      werkzeug
    ];

    installPhase = ''
      mkdir -p $out/bin $out/share/zortex
      cp server.py $out/share/zortex/server.py

      makeWrapper ${pkgs.python3Packages.python.interpreter} $out/bin/zortex-server \
        --add-flags "$out/share/zortex/server.py" \
        --prefix PYTHONPATH : "$PYTHONPATH"
    '';
  };

  # The Worker Script (Replaces run.sh)
  # Dynamic based on config options
  workerScript = pkgs.writeShellScriptBin "zortex-worker" ''
    export PATH="${
      lib.makeBinPath [
        pkgs.sqlite
        pkgs.curl
        pkgs.coreutils
        pkgs.gnugrep
      ]
    }:$PATH"

    DB_PATH="${cfg.dataDir}/notifications.db"
    LOG_FILE="${cfg.dataDir}/zortex.log"
    NTFY_URL="${cfg.ntfyUrl}"
    TOPIC="${cfg.ntfyTopic}"

    log() { echo "$(date) - $1" >> "$LOG_FILE"; }

    # Ensure DB dir exists (redundant if using StateDirectory, but safe)
    mkdir -p "$(dirname "$DB_PATH")"

    CURRENT_TIME=$(date +%s)

    # Check for pending notifications
    # We select columns matching the python schema
    sqlite3 "$DB_PATH" "SELECT id, title, message, priority, tags FROM notifications WHERE sent_at IS NULL AND scheduled_time <= $CURRENT_TIME ORDER BY scheduled_time" | while IFS='|' read -r id title message priority tags; do
      
      # Clean tags: The python script stores them as JSON strings like '["tag1", "tag2"]'
      # We need to clean that up for the ntfy header
      CLEAN_TAGS=$(echo "$tags" | sed 's/[]["]//g' | sed 's/,/,/g')

      # Send to NTFY
      if curl -s \
        -H "Title: $title" \
        -H "Priority: $priority" \
        -H "Tags: $CLEAN_TAGS" \
        -d "$message" \
        "$NTFY_URL/$TOPIC"; then
        
        # Mark as sent
        sqlite3 "$DB_PATH" "UPDATE notifications SET sent_at = $CURRENT_TIME WHERE id = $id"
        log "Sent notification $id: $title"
      else
        log "Failed to send notification $id"
      fi
    done

    # Cleanup Old (Older than 7 days)
    CLEANUP_TIME=$((CURRENT_TIME - 604800))
    sqlite3 "$DB_PATH" "DELETE FROM notifications WHERE sent_at IS NOT NULL AND sent_at < $CLEANUP_TIME"
  '';

in
{
  options.services.zortex = {
    enable = lib.mkEnableOption "Zortex Notification Service";

    port = lib.mkOption {
      type = lib.types.port;
      default = 5000;
      description = "Port for the Flask API";
    };

    ntfyUrl = lib.mkOption {
      type = lib.types.str;
      default = "http://127.0.0.1:8083";
      description = "URL of the Ntfy server";
    };

    ntfyTopic = lib.mkOption {
      type = lib.types.str;
      default = "zortex-notify";
    };

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/zortex";
      description = "Location for the SQLite database";
    };
  };

  config = lib.mkIf cfg.enable {

    # Define a system user for the service
    users.users.zortex = {
      isSystemUser = true;
      group = "zortex";
      description = "Zortex Service User";
    };
    users.groups.zortex = { };

    # 1. The Web Server Service
    systemd.services.zortex-web = {
      description = "Zortex Web API";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];

      serviceConfig = {
        User = "zortex";
        Group = "zortex";
        StateDirectory = "zortex"; # Automatically creates /var/lib/zortex
        ExecStart = "${zortexPkg}/bin/zortex-server";
        Restart = "always";
      };

      environment = {
        FLASK_PORT = toString cfg.port;
        DATABASE_PATH = "${cfg.dataDir}/notifications.db";
        LOG_LEVEL = "INFO";
      };
    };

    # 2. The Timer (Replaces Cron)
    systemd.timers.zortex-worker = {
      description = "Run Zortex notification checks every minute";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "1m";
        OnUnitActiveSec = "1m"; # Run every 1 minute
        Unit = "zortex-worker.service";
      };
    };

    # 3. The Worker Service (Triggered by Timer)
    systemd.services.zortex-worker = {
      description = "Zortex Notification Worker";
      serviceConfig = {
        Type = "oneshot";
        User = "zortex";
        Group = "zortex";
        # We need access to the same state directory
        StateDirectory = "zortex";
        ExecStart = "${workerScript}/bin/zortex-worker";
      };
    };
  };
}
