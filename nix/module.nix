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
    enable = mkEnableOption "Zortex Notification Server";

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
        # Ensure server can find the sender binary for the /test endpoint
        PATH = "${zortexPkg}/bin:${pkgs.coreutils}/bin";
      };

      serviceConfig = {
        ExecStart = "${zortexPkg}/bin/zortex-server";
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
