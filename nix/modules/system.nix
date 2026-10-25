# Shared NixOS / nix-darwin module: lets the nix-daemon use builders started
# with `nix-remote up` or `nix-remote exec`, for every build on the machine.
{ platform }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib)
    mkEnableOption
    mkOption
    mkIf
    types
    ;

  cfg = config.services.nix-remote;
  tomlFormat = pkgs.formats.toml { };
  isDarwin = platform == "darwin";
  stateDir = dirOf cfg.machinesFile;
in
{
  options.services.nix-remote = {
    enable = mkEnableOption "machine-wide nix-remote builder sessions";

    package = mkOption {
      type = types.package;
      default = pkgs.callPackage ../package.nix { };
      defaultText = lib.literalExpression "pkgs.callPackage ../package.nix { }";
      description = "The nix-remote package to install.";
    };

    machinesFile = mkOption {
      type = types.str;
      default = if isDarwin then "/var/lib/nix-remote/machines" else "/run/nix-remote/machines";
      description = ''
        Machines file listing active builder sessions. The nix-daemon's
        `builders` setting includes it, and `nix-remote` writes it.
      '';
    };

    group = mkOption {
      type = types.str;
      default = if isDarwin then "admin" else "nix-remote";
      description = "Group allowed to start and stop builder sessions.";
    };

    users = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "alice" ];
      description = "Users added to {option}`services.nix-remote.group` (NixOS only).";
    };

    settings = mkOption {
      inherit (tomlFormat) type;
      default = { };
      example = lib.literalExpression ''
        {
          repo = "my-org/nix-builders";
          tailscale_tags = "tag:nix-builder";
        }
      '';
      description = ''
        System-wide defaults written to `/etc/nix-remote/config.toml`.
        Each user's `~/.config/nix-remote/config.toml` overrides them.
      '';
    };
  };

  config = mkIf cfg.enable (
    lib.mkMerge [
      {
        environment.systemPackages = [ cfg.package ];
        environment.variables.NIX_REMOTE_MACHINES_FILE = cfg.machinesFile;
        environment.etc."nix-remote/config.toml" = mkIf (cfg.settings != { }) {
          source = tomlFormat.generate "nix-remote-config.toml" cfg.settings;
        };

        nix.settings = {
          # Keeps nix.buildMachines (/etc/nix/machines) working alongside the
          # session file; both are skipped when missing. Wins over the
          # `builders = null` that distributedBuilds = false would set.
          builders = lib.mkOverride 90 "@/etc/nix/machines;@${cfg.machinesFile}";
          builders-use-substitutes = lib.mkDefault true;
        };
      }

      (lib.optionalAttrs (!isDarwin) {
        users.groups.${cfg.group}.members = cfg.users;
        systemd.tmpfiles.rules = [
          "d ${stateDir} 2775 root ${cfg.group} -"
          "d ${stateDir}/sessions 2775 root ${cfg.group} -"
        ];
      })

      (lib.optionalAttrs isDarwin {
        system.activationScripts.postActivation.text = ''
          mkdir -p ${lib.escapeShellArg "${stateDir}/sessions"}
          chown -R root:${lib.escapeShellArg cfg.group} ${lib.escapeShellArg stateDir}
          chmod 2775 ${lib.escapeShellArg stateDir} ${lib.escapeShellArg "${stateDir}/sessions"}
        '';
      })
    ]
  );
}
