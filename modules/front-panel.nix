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

  # La commande est construite ici pour que `text` puisse contenir des
  # espaces sans casser le script systemd. Les valeurs nulles sont remplacées
  # par des sentinelles ; l'assertion ci-dessous refuse l'éval avant que le
  # service ne soit construit.
  action =
    if cfg.text == "" then
      [ "blank" ]
    else
      [
        "write"
        cfg.text
      ];

  args = [
    "--chip"
    (if cfg.chip == null then "" else cfg.chip)
    "--clk"
    (if cfg.clk == null then "0" else toString cfg.clk)
    "--dat"
    (if cfg.dat == null then "0" else toString cfg.dat)
    "--brightness"
    (toString cfg.brightness)
  ]
  ++ lib.optional cfg.pushPull "--push-pull"
  ++ lib.optional cfg.leftToRight "--ltr"
  ++ action;
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
        L'adresse 0x68 porte le chiffre de **gauche**. Faux quand 0x68 est le
        chiffre de droite (mesuré), vrai sur les dalles câblées dans l'autre
        sens.
      '';
    };

    text = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = ''
        Texte affiché au démarrage (5 caractères au plus, chiffres et un jeu
        de lettres). Vide = afficheur éteint, ce qui est le comportement le
        plus sûr : rien ne s'allume si la carte n'a pas d'afficheur.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.chip != null && cfg.clk != null && cfg.dat != null;
        message = "nixelec.frontPanel : la couche carte doit fournir chip, clk et dat (brochage de l'afficheur).";
      }
    ];

    # L'outil reste disponible en console pour vérifier à la main
    # (`fd6xx test`, `fd6xx write 1234`) : c'est la seule vérification qui
    # vaille pour un afficheur.
    environment.systemPackages = [ fd6xx ];

    systemd.services.front-panel = {
      description = "Afficheur façade 7 segments (FD650/FD655)";
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        ${fd6xx}/bin/fd6xx ${lib.escapeShellArgs args}
      '';
    };
  };
}
