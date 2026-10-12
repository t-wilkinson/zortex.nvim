{
  config,
  lib,
  pkgs,
  ...
}:

# services.zortex: two independent parts sharing a user and the notes folder.
#
#   services.zortex.enable      the notification server (Flask: calendar
#                               dashboard, notification API, ntfy sender)
#   services.zortex.web.enable  the notes web app (`zortex serve`, Go): rendered
#                               notes, links, backlinks, search, file browser
#
# Both only read notesDir (a Syncthing folder, say). Keep them on localhost
# and publish them through a reverse proxy with authentication: notes are
# private and the apps have no login of their own.

with lib;

let
  cfg = config.services.zortex;
  web = cfg.web;
  # Import the package from the flake context or defined locally
  zortexPkg = pkgs.callPackage ./package.nix { };

  webArgs =
    [
      "serve"
      "-dir"
      (toString cfg.notesDir)
      "-addr"
      "${web.address}:${toString web.port}"
      "-title"
      web.title
      "-poll"
      web.pollInterval
      "-special"
      (concatStringsSep "," cfg.notesSpecial)
    ]
    ++ optionals (web.basePath != "") [
      "-base"
      web.basePath
    ]
    ++ web.extraArgs;
in
{
  options.services.zortex = {
    enable = mkEnableOption "Zortex notification server (notification API, calendar dashboard, ntfy sender)";

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
      description = ''
        Synced zortex notes folder (read-only). Used by the web app
        (required for it) and by the notification server's Notes tab
        (null disables that tab).
      '';
    };

    notesGroup = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "syncthing";
      description = "Extra group that gives the services read access to notesDir.";
    };

    notesSpecial = mkOption {
      type = types.listOf types.str;
      default = [ "calendar" "structure" "projects" "areas" "okr" ];
      description = ''
        Top-level notes shown by default in file listings (other top-level
        files are hidden until "show all"); the web app also lists them on
        its home page.
      '';
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

    web = {
      enable = mkEnableOption "the Zortex notes web app (zortex serve): rendered notes, links, backlinks, search and a file browser";

      package = mkOption {
        type = types.package;
        default = pkgs.callPackage ./zortex.nix { };
        defaultText = literalExpression "pkgs.callPackage ./zortex.nix { }";
        description = "Package providing the `zortex` binary.";
      };

      address = mkOption {
        type = types.str;
        default = "127.0.0.1";
        description = "Address to listen on. Keep it local and put a reverse proxy with authentication in front.";
      };

      port = mkOption {
        type = types.port;
        default = 8090;
        description = "Port to listen on.";
      };

      basePath = mkOption {
        type = types.str;
        default = "";
        example = "/notes";
        description = ''
          URL path prefix when the proxy serves the app below "/" (the
          proxy passes the prefix through; the app strips it).
        '';
      };

      title = mkOption {
        type = types.str;
        default = "Zortex";
        description = "Site title.";
      };

      pollInterval = mkOption {
        type = types.str;
        default = "10s";
        example = "1m";
        description = ''
          How often to rescan notesDir (a Go duration). A rescan only
          re-reads changed files; the search index and backlinks are rebuilt
          when anything changed.
        '';
      };

      memoryLimit = mkOption {
        type = types.nullOr types.str;
        default = "128MiB";
        example = "64MiB";
        description = ''
          Soft memory limit for the Go runtime (GOMEMLIMIT): the garbage
          collector works harder near it instead of growing the heap. A few
          thousand notes fit in well under 128 MiB. Null leaves it unset.
        '';
      };

      openFirewall = mkOption {
        type = types.bool;
        default = false;
        description = "Open the port in the firewall (only useful with a non-local address).";
      };

      extraArgs = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Extra arguments for `zortex serve`.";
      };
    };
  };

  config = mkMerge [
    (mkIf (cfg.enable || web.enable) {
      users.groups.zortex = { };
      users.users.zortex = {
        isSystemUser = true;
        group = "zortex";
        description = "Zortex Service User";
        home = cfg.dataDir;
        createHome = true;
      };
    })

    (mkIf cfg.enable {
      # The main Flask server service
      systemd.services.zortex-server = {
        description = "Zortex Notification API Server";
        after = [ "network.target" ];
        wantedBy = [ "multi-user.target" ];

        environment =
          {
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
          }
          // optionalAttrs (cfg.notesDir != null) {
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
    })

    (mkIf web.enable {
      assertions = [
        {
          assertion = cfg.notesDir != null;
          message = "services.zortex.web needs services.zortex.notesDir.";
        }
        {
          assertion = web.basePath == "" || hasPrefix "/" web.basePath;
          message = "services.zortex.web.basePath must start with \"/\" (or be empty).";
        }
      ];

      systemd.services.zortex-web = {
        description = "Zortex notes web app";
        after = [ "network.target" ];
        wantedBy = [ "multi-user.target" ];

        environment = {
          TZ = cfg.timezone;
        } // optionalAttrs (web.memoryLimit != null) { GOMEMLIMIT = web.memoryLimit; };

        serviceConfig = {
          ExecStart = "${web.package}/bin/zortex ${escapeShellArgs webArgs}";
          User = "zortex";
          Group = "zortex";
          SupplementaryGroups = optional (cfg.notesGroup != null) cfg.notesGroup;
          Restart = "on-failure";
          RestartSec = "5s";

          # Read-only access to the notes, nothing else
          ReadOnlyPaths = optional (cfg.notesDir != null) (toString cfg.notesDir);
          ProtectSystem = "strict";
          # notesDir may live in a home directory (a Syncthing user's)
          ProtectHome = "read-only";
          PrivateTmp = true;
          PrivateDevices = true;
          NoNewPrivileges = true;
          CapabilityBoundingSet = "";
          AmbientCapabilities = "";
          ProtectKernelTunables = true;
          ProtectKernelModules = true;
          ProtectKernelLogs = true;
          ProtectControlGroups = true;
          ProtectClock = true;
          ProtectHostname = true;
          ProtectProc = "invisible";
          ProcSubset = "pid";
          RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
          RestrictNamespaces = true;
          RestrictRealtime = true;
          RestrictSUIDSGID = true;
          LockPersonality = true;
          MemoryDenyWriteExecute = true;
          SystemCallArchitectures = "native";
          SystemCallFilter = [ "@system-service" "~@privileged" ];
          UMask = "0077";
        };
      };

      networking.firewall.allowedTCPPorts = optional web.openFirewall web.port;
    })
  ];
}
