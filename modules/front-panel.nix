# nixelec-common — afficheur de façade 7 segments FD650/FD655.
#
# Le protocole est bit-bangé en espace utilisateur (la puce n'ACK pas, donc
# i2c-gpio + tm16xx rend -ENXIO). Le module ne connaît ni carte ni SoC : la
# couche carte fournit le gpiochip et les deux numéros de GPIO.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.nixelec.frontPanel;
  fd6xx = pkgs.callPackage ../packages/fd6xx { };
  chipPath = if cfg.chip == null then "" else cfg.chip;

  # Le transport et la géométrie sont communs à toutes les commandes. Les
  # valeurs nulles sont remplacées par des sentinelles ; l'assertion ci-dessous
  # refuse l'éval avant que le service ne soit construit.
  transportArgs = [
    "--chip"
    chipPath
    "--clk"
    (if cfg.clk == null then "0" else toString cfg.clk)
    "--dat"
    (if cfg.dat == null then "0" else toString cfg.dat)
    "--brightness"
    (toString cfg.brightness)
    "--base"
    (toString cfg.layout.digitBase)
    "--stride"
    (toString cfg.layout.digitStride)
    "--digits"
    (toString cfg.layout.digits)
  ]
  ++ lib.optional cfg.pushPull "--push-pull"
  ++ lib.optional cfg.leftToRight "--ltr";

  # `show` est un rendu complet : toute icône connue du profil est passée,
  # active (`--bit`) ou éteinte (`--clear`). La puce n'a pas de lecture de la
  # RAM d'affichage, donc une icône omise resterait dans son état précédent.
  iconArg = name: icon: [
    (if lib.elem name cfg.icons then "--bit" else "--clear")
    "${toString icon.address}:${toString icon.mask}"
  ];
  iconArgs = lib.concatLists (lib.mapAttrsToList iconArg cfg.layout.icons);

  showArgs = [
    "show"
    "--text"
    cfg.text
  ]
  ++ iconArgs;

  # Rendu d'état : le script part des icônes statiques, ajoute eth/wifi selon
  # l'état réseau, puis reconstruit une commande `show` complète. Toute icône
  # du profil non active est explicitement éteinte.
  iconCase = lib.concatStrings (
    lib.mapAttrsToList (name: icon: ''
      case " $active " in
        *" ${name} "*) set -- "$@" --bit "${toString icon.address}:${toString icon.mask}" ;;
        *) set -- "$@" --clear "${toString icon.address}:${toString icon.mask}" ;;
      esac
    '') cfg.layout.icons
  );
  ethCheck = lib.optionalString (cfg.status.ethernetIcon != null) ''
    if [ "$(cat /sys/class/net/${cfg.status.ethernetInterface}/operstate 2>/dev/null)" = "up" ]; then
      active="$active ${cfg.status.ethernetIcon}"
    fi
  '';
  wifiCheck = lib.optionalString (cfg.status.wifiIcon != null) ''
    if ${pkgs.iw}/bin/iw dev ${cfg.status.wifiInterface} link 2>/dev/null | grep -q '^Connected to'; then
      active="$active ${cfg.status.wifiIcon}"
    fi
  '';

  statusScript = ''
    active="${lib.concatStringsSep " " cfg.icons}"
    ${ethCheck}
    ${wifiCheck}
    set -- show --text ${lib.escapeShellArg cfg.text}
    ${iconCase}
    ${fd6xx}/bin/fd6xx ${lib.escapeShellArgs transportArgs} "$@" \
      || echo "front-panel: fd6xx a échoué" >&2
  '';

  # Horloge : HHMM sur quatre chiffres, colon clignotant à 1 Hz (secondes
  # paires), avec les mêmes icônes d'état que le rendu statique. La boucle
  # relit l'heure à chaque tour : un saut d'horloge (suspend/resume, NTP) est
  # corrigé au tour suivant, sans état interne.
  clockScript = ''
    while :; do
      active="${lib.concatStringsSep " " cfg.icons}"
      ${ethCheck}
      ${wifiCheck}
      ${lib.optionalString (cfg.clock.colonIcon != null) ''
        case "$(date +%S)" in
          *[02468]) active="$active ${cfg.clock.colonIcon}" ;;
        esac
      ''}
      set -- show --text "$(date +%H%M)"
      ${iconCase}
      # Un échec doit se voir : sans ce message, une boucle qui n'écrit plus
      # (lignes tenues par un fd6xx resté en fond, chip muet) ressemble à une
      # dalle noire sans cause. Le service doit survivre, donc pas de `exit`.
      ${fd6xx}/bin/fd6xx ${lib.escapeShellArgs transportArgs} "$@" \
        || echo "front-panel: fd6xx a échoué" >&2
      sleep ${cfg.clock.interval}
    done
  '';
in
{
  # Afficheur de façade 7 segments à deux fils (FD650/FD655).
  #
  # OPT-IN ET DÉSACTIVÉ PAR DÉFAUT, volontairement : un afficheur est un
  # accessoire. Il ne doit ni retarder le boot, ni le faire échouer. L'unité
  # est donc `oneshot` + `RemainAfterExit`, n'a aucun `before=` sur une cible
  # du boot, et son script termine toujours en 0 (`|| true`).
  #
  # Pourquoi en espace utilisateur et non en pilote noyau : la puce **n'ACK
  # pas**, or `i2c-gpio` exige un ACK — le couple i2c-gpio + tm16xx rend
  # `-ENXIO` au premier octet. Un pilote dédié bit-bang serait le bon produit à
  # terme, mais l'outil en espace utilisateur permet d'itérer sur le protocole
  # sans recompiler un noyau aarch64.
  options.nixelec.frontPanel = {
    enable = lib.mkEnableOption "afficheur façade 7 segments FD650/FD655 (2 fils bit-bangés)";

    chip = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/dev/gpiochip1";
      description = ''
        Chemin du gpiochip qui porte les deux lignes. Donnée de carte : la
        numérotation des nœuds `/dev/gpiochipN` n'est pas celle de
        `/sys/class/gpio`.
      '';
    };

    clk = lib.mkOption {
      type = lib.types.nullOr lib.types.int;
      default = null;
      example = 226;
      description = ''
        Numéro GPIO global de l'horloge (offset dans `chip`). Donnée de carte :
        le même brochage n'est pas partagé entre les cartes.
      '';
    };

    dat = lib.mkOption {
      type = lib.types.nullOr lib.types.int;
      default = null;
      example = 227;
      description = "Numéro GPIO global des données (offset dans `chip`). Donnée de carte.";
    };

    brightness = lib.mkOption {
      type = lib.types.ints.between 0 7;
      default = 3;
      description = "Luminosité, 0 (1/8 de rapport cyclique) à 7 (8/8).";
    };

    pushPull = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Piloter les deux lignes en sortie franche au lieu d'open-drain +
        pull-up. Requis par les cartes dont la dalle n'a **pas** de pull-up
        externe : l'open-drain ne fait rien monter la ligne et l'afficheur
        reste éteint, alors que le push-pull allume la dalle.
      '';
    };

    leftToRight = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        L'adresse de base porte le chiffre de **gauche**. Faux quand 0x68 est
        le chiffre de droite (mesuré sur la H96), vrai sur les dalles câblées
        dans l'autre sens (Transpeed).
      '';
    };

    text = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = ''
        Texte affiché au démarrage (au plus `layout.digits` caractères,
        chiffres et un jeu de lettres). Vide = afficheur éteint, ce qui est le
        comportement le plus sûr : rien ne s'allume si la carte n'a pas
        d'afficheur.
      '';
    };

    layout = {
      digits = lib.mkOption {
        type = lib.types.ints.between 1 5;
        default = 5;
        description = ''
          Nombre de positions de la dalle. H96 : 5 grilles ; Transpeed : 4
          positions. Les icônes ne sont pas une position de chiffre : elles
          occupent l'octet d'icônes séparé (0x66 sur les FD650/FD655 mesurés).
        '';
      };

      digitBase = lib.mkOption {
        type = lib.types.ints.between 0 255;
        default = 104; # 0x68
        description = ''
          Adresse de la première grille. Donnée de carte : 0x68 sur les deux
          dalles mesurées, mais l'adresse d'une rangée d'icônes n'est pas
          déductible du nom de la puce.
        '';
      };

      digitStride = lib.mkOption {
        type = lib.types.ints.between 1 8;
        default = 2;
        description = "Pas entre deux grilles (2 sur les FD650/FD655 mesurés).";
      };

      icons = lib.mkOption {
        type = lib.types.attrsOf (
          lib.types.submodule {
            options = {
              address = lib.mkOption {
                type = lib.types.ints.between 0 255;
                description = "Adresse de l'octet qui porte le bit (grille ou adresse séparée).";
              };
              mask = lib.mkOption {
                type = lib.types.ints.between 1 255;
                description = "Bit de l'icône dans cet octet (0x01 à 0x80).";
              };
            };
          }
        );
        default = { };
        description = ''
          Table de capacité de la dalle : nom d'icône → (adresse, bit). Un nom
          absent signifie « cette dalle n'a pas cette icône ». Les noms suivent
          le vocabulaire OpenVFD : alarm, usb, play, pause, colon, eth, wifi,
          hdmi, cvbs, sd, etc. Une icône peut partager une grille de chiffre
          (par exemple la colonne sur le point décimal) ou occuper l'octet
          d'icônes séparé (0x66 sur les FD650/FD655 mesurés).
        '';
      };
    };

    icons = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Icônes allumées au démarrage, parmi les noms de `layout.icons`. Une
        icône inconnue du profil fait échouer l'éval : une faute de frappe ne
        doit pas être silencieuse.
      '';
    };

    status = {
      enable = lib.mkEnableOption "mise à jour des icônes eth/wifi depuis l'état réseau";

      ethernetInterface = lib.mkOption {
        type = lib.types.str;
        default = "eth0";
        description = "Interface dont l'état `operstate` pilote l'icône Ethernet.";
      };

      wifiInterface = lib.mkOption {
        type = lib.types.str;
        default = "wlan0";
        description = "Interface dont l'association pilote l'icône WiFi.";
      };

      ethernetIcon = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = "eth";
        description = "Nom de l'icône Ethernet dans `layout.icons`, ou null pour ne pas la piloter.";
      };

      wifiIcon = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = "wifi";
        description = "Nom de l'icône WiFi dans `layout.icons`, ou null pour ne pas la piloter.";
      };

      interval = lib.mkOption {
        type = lib.types.str;
        default = "30s";
        description = ''
          Intervalle entre deux rafraîchissements. Un timer simple suffit :
          il réécrit l'état complet et couvre aussi la fenêtre où le bring-up
          vidéo réinitialise le banc PIO.
        '';
      };
    };

    clock = {
      enable = lib.mkEnableOption "horloge HH:MM sur l'afficheur (remplace le timer status)";

      colonIcon = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = "colon";
        description = ''
          Icône de colonne à faire clignoter à 1 Hz (secondes paires), parmi
          les noms de `layout.icons`. `null` désactive le clignotement ; dans
          ce cas la colonne peut rester statique via `icons`.
        '';
      };

      interval = lib.mkOption {
        type = lib.types.str;
        default = "1s";
        description = ''
          Période de la boucle. `1s` donne le clignotement à 1 Hz ; une valeur
          plus grande ralentit le clignotement sans arrêter l'heure.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.chip != null && cfg.clk != null && cfg.dat != null;
        message = "nixelec.frontPanel : la couche carte doit fournir chip, clk et dat (brochage de l'afficheur).";
      }
      {
        assertion = cfg.layout.digitBase + cfg.layout.digitStride * (cfg.layout.digits - 1) <= 255;
        message = "nixelec.frontPanel.layout : digitBase + digitStride * (digits - 1) dépasse 0xFF.";
      }
      {
        assertion = builtins.stringLength cfg.text <= cfg.layout.digits;
        message = "nixelec.frontPanel.text : le texte dépasse layout.digits caractères.";
      }
      {
        assertion = lib.all (name: builtins.hasAttr name cfg.layout.icons) cfg.icons;
        message = "nixelec.frontPanel.icons : une icône demandée n'existe pas dans layout.icons.";
      }
      {
        assertion =
          !(cfg.status.enable || cfg.clock.enable)
          || cfg.status.ethernetIcon == null
          || builtins.hasAttr cfg.status.ethernetIcon cfg.layout.icons;
        message = "nixelec.frontPanel.status.ethernetIcon : icône absente de layout.icons.";
      }
      {
        assertion =
          !(cfg.status.enable || cfg.clock.enable)
          || cfg.status.wifiIcon == null
          || builtins.hasAttr cfg.status.wifiIcon cfg.layout.icons;
        message = "nixelec.frontPanel.status.wifiIcon : icône absente de layout.icons.";
      }
      {
        assertion = !cfg.clock.enable || cfg.layout.digits >= 4;
        message = "nixelec.frontPanel.clock : l'horloge HHMM demande au moins 4 chiffres.";
      }
      {
        assertion =
          !cfg.clock.enable
          || cfg.clock.colonIcon == null
          || builtins.hasAttr cfg.clock.colonIcon cfg.layout.icons;
        message = "nixelec.frontPanel.clock.colonIcon : icône absente de layout.icons.";
      }
      {
        assertion =
          !cfg.clock.enable || cfg.clock.colonIcon == null || !(lib.elem cfg.clock.colonIcon cfg.icons);
        message = "nixelec.frontPanel.clock.colonIcon : ne pas mettre la colonne dans icons, elle clignote.";
      }
    ];

    # L'outil reste disponible en console pour vérifier à la main
    # (`fd6xx test`, `fd6xx scan`, `fd6xx show ...`) : c'est la seule
    # vérification qui vaille pour un afficheur.
    environment.systemPackages = [ fd6xx ];

    systemd.services.front-panel = {
      description = "Afficheur façade 7 segments (FD650/FD655)";
      wantedBy = [ "multi-user.target" ];
      # Le PIO doit être prêt avant le bit-bang ; sur la H96, le service
      # lancé trop tôt laissait l'écran éteint alors que `fd6xx` sortait 0.
      # `dev-gpiochip1.device` n'est jamais « active » : un chardev GPIO n'est
      # pas une unité de périphérique systemd, d'où 90 s de timeout à chaque
      # boot (mesuré sur Transpeed le 2026-11-18). On attend l'événement udev
      # du nœud, pas une unité qui n'existera jamais.
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStartPre = "${pkgs.systemd}/bin/udevadm wait --timeout=120 ${chipPath}";
      };
      script = ''
        # Deux passes. La première allume l'afficheur, mais le bring-up de la
        # sortie vidéo (TCON/DE puis HDMI) réinitialise le banc PIO quelques
        # secondes plus tard et l'écran s'éteint sans que rien ne le signale :
        # mesuré sur la H96 le 2026-11-19, service « Finished » à 11:39:34,
        # dalle noire, et un `fd6xx write H96` manuel la rallume. La seconde
        # passe, après stabilisation, couvre cette fenêtre. `fd6xx` est
        # idempotent (il réécrit le registre complet).
        ${fd6xx}/bin/fd6xx ${lib.escapeShellArgs transportArgs} ${lib.escapeShellArgs showArgs}
        sleep 8
        ${fd6xx}/bin/fd6xx ${lib.escapeShellArgs transportArgs} ${lib.escapeShellArgs showArgs}
      '';
    };

    systemd.services.front-panel-clock = lib.mkIf cfg.clock.enable {
      description = "Horloge de l'afficheur façade";
      wantedBy = [ "multi-user.target" ];
      after = [ "front-panel.service" ];
      wants = [ "front-panel.service" ];
      path = [
        pkgs.coreutils
        pkgs.gnugrep
        pkgs.iw
      ];
      serviceConfig = {
        Type = "simple";
        Restart = "always";
        RestartSec = "2s";
      };
      script = clockScript;
    };

    systemd.services.front-panel-status = lib.mkIf (cfg.status.enable && !cfg.clock.enable) {
      description = "Icônes d'état de l'afficheur façade";
      wantedBy = [ "multi-user.target" ];
      after = [ "front-panel.service" ];
      wants = [ "front-panel.service" ];
      # `cat`/`grep` ne sont pas garantis dans le PATH par défaut d'un
      # service systemd ; `iw` est appelé en chemin absolu, mais on garde le
      # paquet dans le PATH pour la lisibilité du script.
      path = [
        pkgs.coreutils
        pkgs.gnugrep
        pkgs.iw
      ];
      serviceConfig = {
        Type = "oneshot";
      };
      script = statusScript;
    };

    systemd.timers.front-panel-status = lib.mkIf (cfg.status.enable && !cfg.clock.enable) {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "20s";
        OnUnitInactiveSec = cfg.status.interval;
      };
    };
  };
}
