{
  config,
  lib,
  pkgs,
  ...
}:

# services.zortex: `zortex serve` (zortex-web.service), one Go service that
# is the whole server side:
#
#   - the notes web app: rendered notes, links, backlinks, search, files,
#     and with web.writable light editing and time tracking
#   - the calendar (from calendar.zortex) and the notification API Neovim
#     syncs to (POST /notify); due notifications go out through ntfy when
#     ntfy.topic is set
#   - the pomodoro clock shared by Neovim and the home page, and the home
#     page's timers, alarms and stopwatch
#   - calendar feeds: other calendars' iCal links (a Cozi family member's,
#     say) fetched into notesDir/z/feeds/<name>.zortex, which the calendar
#     shows read-only; and /calendar.ics, the calendar's @share lines for
#     other calendars to subscribe to
#
# It reads notesDir (a Syncthing folder, say) and keeps its own state in
# dataDir. Notes are private: keep it on localhost behind a reverse proxy
# with authentication, or give it a login of its own with web.authFile (HTTP
# basic auth; use HTTPS).

with lib;

let
  cfg = config.services.zortex;
  web = cfg.web;
  on = cfg.enable;

  # the service writes into notesDir: edits from the web, feed notes
  notesWritable = web.writable || cfg.feeds != { };

  # a feed's urlFile is passed as a systemd credential, read from here
  credDir = "/run/credentials/zortex-web.service";
  feedsOn = filterAttrs (_: f: f.enable) cfg.feeds;
  feedsJSON = pkgs.writeText "zortex-feeds.json" (
    builtins.toJSON {
      feeds = mapAttrsToList (
        name: f:
        {
          inherit name;
          inherit (f) notify busy every;
          # an off feed stays listed: the service removes its note
          enabled = f.enable;
          days_back = f.daysBack;
          days_ahead = f.daysAhead;
        }
        // optionalAttrs (f.title != null) { inherit (f) title; }
        // optionalAttrs (f.url != null) { inherit (f) url; }
        // optionalAttrs (f.enable && f.urlFile != null) { url_file = "${credDir}/feed-${name}"; }
      ) cfg.feeds;
    }
  );

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
    "-data"
    (toString cfg.dataDir)
  ]
  ++ optionals (cfg.ntfy.topic != null) [
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
  ++ optionals web.htmlScripts [ "-html-scripts" ]
  ++ optionals (web.resourceExtensions != null) [
    "-resources"
    (concatStringsSep "," web.resourceExtensions)
  ]
  ++ optionals (cfg.ntfy.authTokenFile != null) [
    "-ntfy-token-file"
    "%d/ntfy-token"
  ]
  ++ optionals (web.authFile != null) [
    "-auth-file"
    "%d/auth"
  ]
  ++ optionals (cfg.feeds != { }) [
    "-feeds"
    "${feedsJSON}"
  ]
  ++ optionals (cfg.shareTokenFile != null) [
    "-share-token-file"
    "%d/share-token"
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
        State: scheduled notifications (notifications.json), the pomodoro
        clock (pomodoro.json), timers, alarms and the stopwatch
        (clocks.json), time tracking (track.json, track_log.jsonl) and the
        XP summary.
      '';
    };

    ntfy = {
      url = mkOption {
        type = types.str;
        default = "https://ntfy.sh";
        description = "URL of the ntfy server.";
      };

      topic = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "zortex-7f3k2q";
        description = ''
          Topic for calendar notifications, pomodoro changes, timers and
          alarms. Anyone who knows a topic on a public server can read it:
          pick a private, hard-to-guess one. Null: nothing is sent.
        '';
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


    feeds = mkOption {
      default = { };
      example = literalExpression ''
        {
          cozi = {
            title = "Family";
            urlFile = "/run/secrets/cozi-ical-url";
          };
          school = {
            url = "https://example.edu/calendar.ics";
            notify = true;
            busy = false;
          };
        }
      '';
      description = ''
        Calendar feeds: iCal links (a Cozi family member's "Connected
        calendars" link, Google's "Secret address in iCal format") fetched
        every few minutes into notesDir/z/feeds/<name>.zortex, which the
        calendar, planner and web app show read-only. The service writes
        into notesDir: give it write access with notesGroup and a
        group-writable folder (as web.writable). A feed turned off has its
        note removed.
      '';
      type = types.attrsOf (
        types.submodule {
          options = {
            enable = mkOption {
              type = types.bool;
              default = true;
              description = "Fetch this feed. Off: its note is removed and its events leave the calendar.";
            };
            title = mkOption {
              type = types.nullOr types.str;
              default = null;
              description = "The note's title (@@Title). Null: the feed's name.";
            };
            url = mkOption {
              type = types.nullOr types.str;
              default = null;
              description = "The feed's URL (https:// or webcal://). Ends up in the Nix store: a private link is a secret, prefer urlFile.";
            };
            urlFile = mkOption {
              type = types.nullOr types.path;
              default = null;
              example = "/run/secrets/cozi-ical-url";
              description = "File holding the URL (passed as a systemd credential).";
            };
            notify = mkOption {
              type = types.bool;
              default = false;
              description = "Notify for the feed's timed events, as for your own (Neovim syncs them). Off: its lines get @n(no).";
            };
            busy = mkOption {
              type = types.bool;
              default = true;
              description = "The feed's events take time in the planner's capacity line. Off: its lines get @free.";
            };
            every = mkOption {
              type = types.str;
              default = "15m";
              description = "How often to fetch it (a Go duration, 5m at least).";
            };
            daysBack = mkOption {
              type = types.ints.positive;
              default = 7;
              description = "Days before today the note keeps.";
            };
            daysAhead = mkOption {
              type = types.ints.positive;
              default = 60;
              description = "Days after today the note covers.";
            };
          };
        }
      );
    };

    shareTokenFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      example = "/run/secrets/zortex-share-token";
      description = ''
        File holding a token (16 characters or more: openssl rand -hex 16)
        that lets a calendar app subscribe to
        <site>/calendar.ics?token=<token>, the calendar's lines tagged
        @share, without the login. With a proxy that has its own login, let
        /calendar.ics through to the app (an Authelia "bypass" rule for that
        path, say): with a token and no web.authFile, the app answers
        /calendar.ics only to the token. Passed as a systemd credential.
      '';
    };

    timezone = mkOption {
      type = types.nullOr types.str;
      default = config.time.timeZone;
      defaultText = literalExpression "config.time.timeZone";
      example = "America/New_York";
      description = ''
        Time zone for the calendar and notification times (TZ). Null leaves
        TZ unset: the system's time zone.
      '';
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
        default = "3s";
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

      authFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        example = "/run/secrets/zortex-auth";
        description = ''
          File of `user:password` lines: a login (HTTP basic auth) for every
          page, for setups without a proxy that has one. Use it over HTTPS.
          Passed as a systemd credential.
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

      htmlScripts = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Let HTML files in the notes folder run JavaScript in the file
          viewer. Scripts run in a sandbox with an opaque origin: they can't
          read the site's pages or files, and POSTs they send are
          refused. Only turn it on if you trust the HTML files you sync.
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
    ]
    ++ mapAttrsToList (name: f: {
      assertion = !f.enable || ((f.url != null) != (f.urlFile != null));
      message = "services.zortex.feeds.${name}: set one of url and urlFile.";
    }) cfg.feeds
    ++ mapAttrsToList (name: _: {
      assertion = builtins.match "[A-Za-z0-9_-]+" name != null;
      message = "services.zortex.feeds.${name}: a feed's name is letters, digits, - and _.";
    }) cfg.feeds;

    warnings =
      optional (cfg.ntfy.topic == null) ''
        services.zortex.ntfy.topic is not set: calendar notifications and
        pomodoro alerts won't be sent. Set a private, hard-to-guess topic.
      ''
      ++ optional (cfg.ntfy.topic == "zortex-notify" && hasPrefix "https://ntfy.sh" cfg.ntfy.url) ''
        services.zortex.ntfy.topic is "zortex-notify" on the public ntfy.sh:
        anyone can read it. Pick a private, hard-to-guess topic.
      '';

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

      environment =
        optionalAttrs (cfg.timezone != null) { TZ = cfg.timezone; }
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
        LoadCredential =
          optional (cfg.ntfy.authTokenFile != null) "ntfy-token:${toString cfg.ntfy.authTokenFile}"
          ++ optional (web.authFile != null) "auth:${toString web.authFile}"
          ++ optional (cfg.shareTokenFile != null) "share-token:${toString cfg.shareTokenFile}"
          ++ mapAttrsToList (name: f: "feed-${name}:${toString f.urlFile}") (
            filterAttrs (_: f: f.urlFile != null) feedsOn
          );

        # Read-only notes (writable with web.writable or calendar feeds,
        # which write z/feeds/), writable state, nothing else
        StateDirectory = mkIf (cfg.dataDir == "/var/lib/zortex") "zortex";
        StateDirectoryMode = "0750";
        ReadWritePaths =
          optional (cfg.dataDir != "/var/lib/zortex") (toString cfg.dataDir)
          ++ optional (cfg.notesDir != null && notesWritable) (toString cfg.notesDir);
        ReadOnlyPaths = optional (cfg.notesDir != null && !notesWritable) (toString cfg.notesDir);
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
        UMask = if notesWritable then "0007" else "0077";
      };
    };

    networking.firewall.allowedTCPPorts = optional web.openFirewall web.port;
  };
}
