# Racine sur eMMC — machine installée, pas une image.
#
# Les configurations de bring-up importent `sd-image`, qui déclare
# `fileSystems."/"` et étiquette le système `sd-card-…`. Une machine installée
# sur sa eMMC n'est pas une image SD : elle a besoin d'une racine déclarée
# explicitement et d'une étiquette qui lui soit propre.
#
# Ce module ne suppose **aucun** bootloader : il ne pose que `fileSystems."/"`.
# Il convient aussi bien à extlinux (sunxi64) qu'à un U-Boot vendor (meson64),
# tant que la partition racine porte l'étiquette demandée.
#
# L'étiquette unique n'est pas cosmétique. `root=LABEL=nixos` est ambigu dès
# qu'un autre support NixOS est présent (carte SD, clé USB portant une image) :
# l'initrd monte le mauvais support et le boot échoue sur « Failed to start
# Find NixOS closure » — mesuré sur une carte de la flotte avec la fermeture
# pourtant bien installée.
{
  config,
  lib,
  ...
}:

let
  cfg = config.nixelec.emmc;
in
{
  options.nixelec.emmc = {
    rootLabel = lib.mkOption {
      type = lib.types.str;
      description = ''
        Étiquette de la partition racine de la eMMC. Doit être unique parmi les
        supports que la machine peut voir : c'est elle que le noyau reçoit dans
        `root=` et qu'aucun autre support ne doit porter.

        **16 caractères maximum** : c'est la limite du champ `s_volume_name`
        d'ext4. `e2label` tronque silencieusement au-delà (avertissement
        « label too long, truncating » puis un label qui ne correspond plus à
        `by-label/…` — la machine ne redémarre plus). Vérifier avec `blkid`
        après écriture, jamais avec `lsblk` seul, qui peut servir une valeur
        en cache.
      '';
      example = "nixelec-root";
    };

    extraPackages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
      description = ''
        Paquets supplémentaires pour une machine installée (outils de banc,
        console série…). Ils ne sont pas nécessaires au contrat de racine ;
        la couche carte les fournit.
      '';
    };
  };

  config = {
    fileSystems."/" = {
      device = "/dev/disk/by-label/${cfg.rootLabel}";
      fsType = "ext4";
    };

    # La règle est vérifiée ici, une fois, plutôt que découverte sur la carte :
    # une étiquette trop longue est tronquée par e2label (ext4 limite le champ
    # à 16 octets) et la machine ne redémarre plus. Une étiquette « nixos »
    # réintroduirait l'ambiguïté avec les images du même nom.
    assertions = [
      {
        assertion = builtins.stringLength cfg.rootLabel <= 16;
        message = ''
          nixelec.emmc.rootLabel fait ${toString (builtins.stringLength cfg.rootLabel)} caractères : la limite ext4 est de 16.
          e2label tronquerait silencieusement l'étiquette et la machine ne
          retrouverait plus sa racine au démarrage.
        '';
      }
      {
        assertion = cfg.rootLabel != "nixos";
        message = ''
          nixelec.emmc.rootLabel ne peut pas être « nixos » : c'est l'étiquette
          des images SD, et `root=LABEL=nixos` redeviendrait ambigu dès qu'un
          tel support est branché.
        '';
      }
    ];

    environment.systemPackages = cfg.extraPackages;

    # `nixbian` (nix/parts/nixos-module.nix) pose `root=LABEL=nixos` pour les
    # images SD. Sur une machine installée, l'étiquette est `cfg.rootLabel` :
    # on ajoute donc notre `root=` en **dernier** (`mkAfter`). Le noyau retient
    # la dernière occurrence — `root_dev_setup` écrase la valeur précédente —
    # et le `root=` des images reste inoffensif au lieu de monter la mauvaise
    # partition (symptôme mesuré : `stage 2 init script (/mnt-root//init) not
    # found` sur la Transpeed, dont la racine est `nixelec-8k618`).
    boot.kernelParams = lib.mkAfter [ "root=LABEL=${cfg.rootLabel}" ];
  };
}
