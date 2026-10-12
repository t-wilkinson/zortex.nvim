{
  config,
  lib,
  pkgs,
  ...
}:

# services.zortex: `zortex serve`, one Go service that is the whole server side:
#
#   - the notes web app: rendered notes, links, backlinks, search, files
#   - the calendar (from calendar.zortex) and the notification API Neovim
#     syncs to (POST /notify); due notifications go out through ntfy
#   - the pomodoro clock shared by Neovim and the home page
#
# It reads notesDir (a Syncthing folder, say) and keeps its own state
# (notifications, pomodoro) in dataDir. Keep it on localhost and publish it
# through a reverse proxy with authentication: notes are private and the app
# has no login of its own.
#
# This replaces the Flask notification server + zortex-sender timer. Either
# `enable` turns the service on (both are kept so existing
# configurations keep working).

with lib;

let
  cfg = config.services.zortex;
  web = cfg.web;
  on = cfg.enable;

  args = [
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
    "-data"
    (toString cfg.dataDir)
    "-ntfy-url"
    cfg.ntfy.url
    "-ntfy-topic"
    cfg.ntfy.topic
  ]
  ++ optionals (web.basePath != "") [
    "-base"
    web.basePath
  ]
  ++ optionals web.writable [ "-writable" ]
  ++ optionals (web.resourceExtensions != null) [
    "-resources"
    (concatStringsSep "," web.resourceExtensions)
  ]
  ++ optionals (cfg.ntfy.authTokenFile != null) [
    "-ntfy-token-file"
    "%d/ntfy-token"
  ]
  ++ web.extraArgs;
in
{
  options.services.zortex = {
    enable = mkEnableOption "Zortex: notes web app, calendar, ntfy notifications and pomodoro (zortex serve)";

    package = mkOption {
      type = types.package;
      default = pkgs.callPackage ./zortex.nix { };
      defaultText = literalExpression "pkgs.callPackage ./zortex.nix { }";
      description = "Package providing the `zortex` binary.";
    };

    dataDir = mkOption {
      type = types.path;
      default = "/var/lib/zortex";
      description = ''
        State: scheduled notifications (notifications.json) and the pomodoro
        clock (pomodoro.json). The old notifications.db is no longer used;
        Neovim re-syncs the calendar on its next save.
      '';
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
        description = "Topic for calendar notifications and pomodoro alerts.";
      };

      authToken = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "ntfy access token. Ends up in the Nix store; prefer authTokenFile.";
      };

      authTokenFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        example = "/run/secrets/ntfy-token";
        description = "File with the ntfy access token (passed as a systemd credential).";
      };
    };

    apiKey = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        Shared secret for the endpoints Neovim uses (/notify, /pending), sent
        as X-API-Key (the plugin's server.api_key). Ends up in the Nix store;
        prefer apiKeyFile.
      '';
    };

    apiKeyFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "File holding apiKey (an EnvironmentFile line ZORTEX_API_KEY=...).";
    };

    notesDir = mkOption {
      type = types.nullOr types.path;
      default = null;
      example = "/var/lib/syncthing/zortex";
      description = "Synced zortex notes folder (read-only). Required.";
    };

    notesGroup = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "syncthing";
      description = "Extra group that gives the service read access to notesDir.";
    };

    notesSpecial = mkOption {
      type = types.listOf types.str;
      default = [
        "calendar"
        "structure"
        "projects"
        "areas"
        "okr"
      ];
      description = ''
        Top-level notes listed on the home page and shown by default in file
        listings (other top-level files are hidden until "show all").
      '';
    };

    timezone = mkOption {
      type = types.str;
      default = "America/New_York";
      description = "Time zone for the calendar and notification times.";
    };

    web = {
      address = mkOption {
        type = types.str;
        default = "127.0.0.1";
        description = "Address to listen on. Keep it local and put a reverse proxy with authentication in front.";
      };

      port = mkOption {
        type = types.port;
        default = 8090;
        description = "Port to listen on. The plugin's server.api_endpoint points here.";
      };

      basePath = mkOption {
        type = types.str;
        default = "";
        example = "/notes";
        description = ''
          URL path prefix when the proxy serves the app below "/" (the
          proxy passes the prefix through; the app strips it). The
          notification API is then at <basePath>/notify.
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
          re-reads changed files.
        '';
      };

      memoryLimit = mkOption {
        type = types.nullOr types.str;
        default = "128MiB";
        example = "64MiB";
        description = "Soft memory limit for the Go runtime (GOMEMLIMIT). Null leaves it unset.";
      };

      resourceExtensions = mkOption {
        type = types.nullOr (types.listOf types.str);
        default = null;
        example = [
          "pdf"
          "epub"
          "djvu"
          "png"
          "jpg"
        ];
        description = ''
          File extensions tracked as resources (backlinks on file pages, the
          unlinked list at /resources). Null: PDFs, e-books, images, video,
          audio and office documents.
        '';
      };

      writable = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Let the web app edit notes: toggle tasks, edit, add and remove
          lines, add to inbox.zortex. notesDir must be writable by the
          service (use notesGroup with a group-writable folder, e.g. the
          Syncthing group). Edits are line-level and refused when the note
          changed since the page was loaded.
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

  config = mkIf on {
    assertions = [
      {
        assertion = cfg.notesDir != null;
        message = "services.zortex needs services.zortex.notesDir.";
      }
      {
        assertion = web.basePath == "" || hasPrefix "/" web.basePath;
        message = "services.zortex.web.basePath must start with \"/\" (or be empty).";
      }
    ];

    users.groups.zortex = { };
    users.users.zortex = {
      isSystemUser = true;
      group = "zortex";
      description = "Zortex Service User";
      home = cfg.dataDir;
    };

    systemd.services.zortex-web = {
      description = "Zortex: notes, calendar, notifications and pomodoro";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      environment = {
        TZ = cfg.timezone;
      }
      // optionalAttrs (web.memoryLimit != null) { GOMEMLIMIT = web.memoryLimit; }
      // optionalAttrs (cfg.ntfy.authToken != null) { NTFY_AUTH_TOKEN = cfg.ntfy.authToken; }
      // optionalAttrs (cfg.apiKey != null) { ZORTEX_API_KEY = cfg.apiKey; };

      serviceConfig = {
        ExecStart = "${cfg.package}/bin/zortex ${escapeShellArgs args}";
        User = "zortex";
        Group = "zortex";
        SupplementaryGroups = optional (cfg.notesGroup != null) cfg.notesGroup;
        Restart = "on-failure";
        RestartSec = "5s";
        EnvironmentFile = optional (cfg.apiKeyFile != null) cfg.apiKeyFile;
        LoadCredential = optional (
          cfg.ntfy.authTokenFile != null
        ) "ntfy-token:${toString cfg.ntfy.authTokenFile}";

        # Read-only notes, writable state, nothing else
        StateDirectory = mkIf (cfg.dataDir == "/var/lib/zortex") "zortex";
        StateDirectoryMode = "0750";
        ReadWritePaths =
          optional (cfg.dataDir != "/var/lib/zortex") (toString cfg.dataDir)
          ++ optional (cfg.notesDir != null && web.writable) (toString cfg.notesDir);
        ReadOnlyPaths = optional (cfg.notesDir != null && !web.writable) (toString cfg.notesDir);
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
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
        ];
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        SystemCallArchitectures = "native";
        SystemCallFilter = [
          "@system-service"
          "~@privileged"
        ];
        # writable notes stay group-writable so Syncthing can keep syncing them
        UMask = if web.writable then "0007" else "0077";
      };
    };

    networking.firewall.allowedTCPPorts = optional web.openFirewall web.port;
  };
}
