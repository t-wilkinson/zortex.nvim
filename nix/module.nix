{
  config,
  lib,
  pkgs,
  ...
}:

with lib;

let
  cfg = config.services.zortex;
  # Import the package from the flake context or defined locally
  zortexPkg = pkgs.callPackage ./package.nix { };
in
{
  options.services.zortex = {
    enable = mkEnableOption "Zortex app (notifications, calendar dashboard, notes browser)";

    port = mkOption {
      type = types.port;
      default = 5000;
      description = "Port for the Flask server to listen on.";
    };

    dataDir = mkOption {
      type = types.path;
      default = "/var/lib/zortex";
      description = "Directory to store the SQLite database.";
    };

    ntfy = {
      url = mkOption {
        type = types.str;
        default = "https://ntfy.sh";
        description = "URL of the ntfy server.";
      };

      topic = mkOption {
        type = types.str;
        default = "zortex-notify";
        description = "Topic name for notifications.";
      };

      authToken = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Optional authentication token for ntfy.";
        # Note: For better security in production, consider using systemd LoadCredential.
      };
    };

    notesDir = mkOption {
      type = types.nullOr types.path;
      default = null;
      example = "/var/lib/syncthing/zortex";
      description = "Synced zortex notes folder to browse and search (read-only). Null disables the Notes tab.";
    };

    notesGroup = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "syncthing";
      description = "Extra group that gives the service read access to notesDir.";
    };

    notesSpecial = mkOption {
      type = types.listOf types.str;
      default = [ "calendar" "structure" "projects" "areas" "okr" ];
      description = "Top-level notes shown by default (other top-level *.zortex files are hidden unless 'all' is ticked).";
    };

    timezone = mkOption {
      type = types.str;
      default = "America/New_York";
      description = "Timezone for the server to use for rendering dates/times.";
    };

    interval = mkOption {
      type = types.str;
      default = "*:0/1";
      description = "Systemd calendar interval for checking notifications (default: every minute).";
    };
  };

  config = mkIf cfg.enable {

    # Ensure the user exists
    users.groups.zortex = { };
    users.users.zortex = {
      isSystemUser = true;
      group = "zortex";
      description = "Zortex Service User";
      home = cfg.dataDir;
      createHome = true;
    };

    # The main Flask server service
    systemd.services.zortex-server = {
      description = "Zortex Notification API Server";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];

      environment = {
        FLASK_PORT = toString cfg.port;
        DATABASE_PATH = lib.mkDefault "${cfg.dataDir}/notifications.db";
        LOG_LEVEL = "INFO";
        TZ = cfg.timezone;
        # Ensure server can find the sender binary for the /test endpoint
        PATH = lib.mkForce "${zortexPkg}/bin:${pkgs.coreutils}/bin";
        NTFY_SERVER_URL = cfg.ntfy.url;
        NTFY_TOPIC = cfg.ntfy.topic;
        NTFY_AUTH_TOKEN = if cfg.ntfy.authToken != null then cfg.ntfy.authToken else "";
        NOTES_SPECIAL = concatStringsSep "," cfg.notesSpecial;
      } // optionalAttrs (cfg.notesDir != null) {
        NOTES_DIR = toString cfg.notesDir;
      };

      serviceConfig = {
        ExecStart = "${zortexPkg}/bin/zortex-server";
        ReadOnlyPaths = optional (cfg.notesDir != null) (toString cfg.notesDir);
        SupplementaryGroups = optional (cfg.notesGroup != null) cfg.notesGroup;
        User = "zortex";
        Group = "zortex";
        Restart = "always";
        RestartSec = "5s";
        # StateDirectory creates /var/lib/zortex automatically with correct perms
        StateDirectory = "zortex";
        WorkingDirectory = cfg.dataDir;
      };
    };

    # The worker service that sends notifications (runs via timer)
    systemd.services.zortex-sender = {
      description = "Zortex Notification Sender Worker";
      after = [ "network.target" ];

      environment = {
        DATABASE_PATH = "${cfg.dataDir}/notifications.db";
        NTFY_SERVER_URL = cfg.ntfy.url;
        NTFY_TOPIC = cfg.ntfy.topic;
        NTFY_AUTH_TOKEN = if cfg.ntfy.authToken != null then cfg.ntfy.authToken else "";
      };

      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${zortexPkg}/bin/zortex-sender";
        User = "zortex";
        Group = "zortex";
        # Connect stdout/stderr to journal
        StandardOutput = "journal";
        StandardError = "journal";
      };
    };

    # Timer to trigger the sender service
    systemd.timers.zortex-sender = {
      description = "Timer for Zortex Notification Sender";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.interval;
        Unit = "zortex-sender.service";
      };
    };
  };
}
