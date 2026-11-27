# Contrat veille/réveil agnostique de la carte : bouton power, mode de veille
# et réarmement réseau après reprise. Les sources (IR, WoL, WoWLAN) sont des
# données de la couche famille/carte ; ici, seulement le socle. Voir la spec
# HavenOS `docs/specs/veille-reveil.md`.
{
  config,
  lib,
  ...
}:

let
  cfg = config.nixelec.power;
in
{
  options.nixelec.power = {
    enable = lib.mkEnableOption "the nixelec suspend/resume base";

    onPowerKey = lib.mkOption {
      type = lib.types.enum [
        "poweroff"
        "suspend"
        "ignore"
      ];
      default = "poweroff";
      description = ''
        Action of the physical power button, through systemd-logind
        (`HandlePowerKey`). NixOS defaults to `poweroff`, which powers the box
        off: no wake source (IR, WoL, RTC) can then bring it back. Set it to
        `suspend` on a board whose wake sources are wired and tested.
      '';
    };

    suspend.mode = lib.mkOption {
      type = lib.types.enum [
        "s2idle"
        "mem"
      ];
      default = "s2idle";
      description = ''
        Kernel sleep mode, passed as `mem_sleep_default`. `s2idle` is the only
        mode measured on sunxi64; `mem` stays available for a board that proves
        it.
      '';
    };

    realignEthernet = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Cycle the wired link after a resume (`ip link set eth0 down/up`). On
        `sunxi-gmac` the PHY can stay `Link is Down` after a sleep even with the
        cable plugged (measured 2026-11-27 on H96 Max H618): the board is awake
        but unreachable. Enable it on boards where the driver leaves the link
        down.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    services.logind.settings.Login.HandlePowerKey = cfg.onPowerKey;

    boot.kernelParams = [ "mem_sleep_default=${cfg.suspend.mode}" ];

    # Hook unique du socle : après reprise, réarmer le lien si demandé.
    powerManagement.resumeCommands = lib.optionalString cfg.realignEthernet ''
      ip link set eth0 down 2>/dev/null || true
      ip link set eth0 up 2>/dev/null || true
    '';
  };
}
