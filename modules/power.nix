# Contrat veille/réveil agnostique de la carte : bouton power, mode de veille
# et réarmement réseau après reprise. Les sources (IR, WoL, WoWLAN) sont des
# données de la couche famille/carte ; ici, seulement le socle. Voir la spec
# HavenOS `docs/specs/veille-reveil.md`.
{
  config,
  lib,
  pkgs,
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
        off: no wake source (IR, WoL, RTC) can then bring it back.

        Measured pitfall on H96 Max H618 (2026-11-27): when the only "power"
        key is the IR remote's `KEY_POWER`, the press that wakes the box is
        re-delivered to logind ~6 s after resume. With `suspend`, the box
        therefore suspends itself again right after every wake (wake IRQ 300
        at 19:33:35, `Power key pressed short`/`Suspending...` at 19:33:41).
        Prefer `ignore` on such a board and let Kodi (or another policy)
        handle the key while awake; the kernel wake path still works.
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

    realignWifi = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Reload the AIC8800 SDIO driver after a resume. Measured 2026-11-28 on
        H96 Max H618: after s2idle the interface never re-associates —
        wpa_supplicant loops on `CTRL-EVENT-SCAN-FAILED ret=-16` (EBUSY), and
        neither `ip link down/up` nor a wpa_supplicant restart clears it. Only
        `rmmod`/`modprobe` of `aic8800_fdrv` + `aic8800_bsp` re-associates.
        Required on boards whose only network path is WiFi (kiosk H96).
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    services.logind.settings.Login.HandlePowerKey = cfg.onPowerKey;

    boot.kernelParams = [ "mem_sleep_default=${cfg.suspend.mode}" ];

    # Hook unique du socle : après reprise, réarmer le lien si demandé.
    powerManagement.resumeCommands =
      lib.optionalString cfg.realignEthernet ''
        ip link set eth0 down 2>/dev/null || true
        ip link set eth0 up 2>/dev/null || true
      ''
      + lib.optionalString cfg.realignWifi ''
        # Le rechargement se fait dans une unité transitoire : la transaction de
        # veille ne doit jamais attendre le SDIO. Mesuré 2026-11-28 sur H96 : un
        # hook qui bloque laisse logind en « suspend in progress » et refuse
        # toutes les veilles suivantes (« Action suspend already in progress »),
        # et le rmmod en cours fait traîner la phase device du suspend suivant
        # (46 s et 77 s observés). wpa_supplicant est donc arrêté avant le
        # rmmod, chaque étape est bornée par `timeout`, et l'ensemble tourne
        # hors de la transaction (systemd-run).
        ${config.systemd.package}/bin/systemd-run --no-block --collect \
          --unit=havenos-wifi-realign --property=RuntimeMaxSec=120 \
          ${pkgs.bash}/bin/bash -c '
            ${config.systemd.package}/bin/systemctl stop wpa-supplicant-wlan0 || true
            ${pkgs.coreutils}/bin/timeout 20 ${pkgs.kmod}/bin/modprobe -r aic8800_fdrv aic8800_bsp || true
            ${pkgs.coreutils}/bin/timeout 10 ${pkgs.kmod}/bin/modprobe aic8800_bsp || true
            ${pkgs.coreutils}/bin/timeout 10 ${pkgs.kmod}/bin/modprobe aic8800_fdrv || true
            ${config.systemd.package}/bin/systemctl --no-block start wpa-supplicant-wlan0 || true
          ' || true
      '';
  };
}
