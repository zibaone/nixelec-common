# nixelec-common — récepteur IR : tables, fusion, gardes et chargement de keymap.
#
# Ce module ne fournit **aucun récepteur** : ni `sunxi-ir`, ni `meson-ir`, ni
# `gpio_ir_recv`, ni overlay DT. Il possède les tables publiques, la fusion, les
# gardes d'éval, le chargement de keymap et la règle udev. La couche carte
# apporte le récepteur, son nœud DT et le nom d'entrée qu'il expose.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.nixelec.ir;

  # ir-keytable vient de v4l-utils ; `withGUI = false` évite de tirer Qt pour
  # un outil en ligne de commande (même choix que le profil Kodi de HavenOS).
  v4l = pkgs.v4l-utils.override { withGUI = false; };

  # ---------------------------------------------------------------------------
  # Télécommandes : un fichier TOML par télécommande, plusieurs activables
  # ---------------------------------------------------------------------------
  # Chaque fichier est une keymap `ir-keytable` (TOML : `[[protocols]]` +
  # `[protocols.scancodes]`), au format capturé sur la carte avec
  # `ir-keytable -s <dev> -p nec -t`.
  #
  # La keymap chargée est la **fusion** des télécommandes activées : rc-core ne
  # garde qu'un keycode par scancode (`rc-main.c`, `ir_update_mapping`) et
  # `ir-keytable` éclate toutes les sections en une seule liste
  # (`keytable.c:372`, `add_keymap`). Ajouter une télécommande = déposer un
  # fichier, l'ajouter à `remotes` si le défaut ne le prend pas, et recharger.
  #
  # Le répertoire du module porte les tables publiques ; `extraRemotesDir`
  # permet à une couche (publique ou privée) d'ajouter les siennes sans
  # modifier ce dépôt (même nom = la version supplémentaire gagne).
  dirs = [ ./remotes ] ++ lib.optional (cfg.extraRemotesDir != null) cfg.extraRemotesDir;

  remoteFiles = lib.foldl' (
    acc: dir:
    acc
    // lib.mapAttrs' (n: _: lib.nameValuePair (lib.removeSuffix ".toml" n) (dir + "/${n}")) (
      lib.filterAttrs (n: t: t == "regular" && lib.hasSuffix ".toml" n) (builtins.readDir dir)
    )
  ) { } dirs;

  availableNames = lib.attrNames remoteFiles;

  enabledNames = if cfg.remotes == [ ] then availableNames else cfg.remotes;

  unknownRemotes = lib.subtractLists availableNames enabledNames;

  # `variant` est documentaire : ir-keytable l'ignore (seul `ir-ctl` le lit).
  # Le décodeur NEC du noyau rend NEC, NECX et NEC32 dès que `nec` est activé,
  # donc `-p nec` couvre les tables « necx » et « nec32 ».
  parseRemote =
    name:
    let
      lines = lib.splitString "\n" (builtins.readFile remoteFiles.${name});
      grab =
        pattern:
        let
          found = lib.filter (m: m != null) (map (l: builtins.match pattern l) lines);
        in
        if found == [ ] then null else lib.head (lib.head found);
      protocol = grab "[ \t]*protocol[ \t]*=[ \t]*\"([a-z0-9._-]+)\".*";
    in
    {
      protocol = if protocol == null then "nec" else protocol;
      variant = grab "[ \t]*variant[ \t]*=[ \t]*\"([a-z0-9._-]+)\".*";
      entries =
        map
          (m: {
            scancode = lib.elemAt m 0;
            keycode = lib.elemAt m 1;
          })
          (
            lib.filter (m: m != null) (
              map (l: builtins.match "[ \t]*(0x[0-9a-fA-F]+)[ \t]*=[ \t]*\"(KEY_[A-Z0-9_]+)\".*" l) lines
            )
          );
    };

  # Toutes les revendications par scancode : de quoi nommer un conflit et les
  # télécommandes en cause.
  claims = lib.foldl' (
    acc: name:
    let
      remote = parseRemote name;
    in
    lib.foldl' (
      inner: entry:
      inner
      // {
        ${entry.scancode} = (inner.${entry.scancode} or [ ]) ++ [
          {
            inherit (entry) keycode;
            inherit (remote) protocol variant;
            remote = name;
          }
        ];
      }
    ) acc remote.entries
  ) { } enabledNames;

  conflicts = lib.filterAttrs (_: c: lib.length (lib.unique (map (x: x.keycode) c)) > 1) claims;

  conflictReport = lib.mapAttrsToList (
    scancode: c: "${scancode} → ${lib.concatStringsSep ", " (map (x: "${x.keycode} (${x.remote})") c)}"
  ) conflicts;

  # Un conflit n'est pas fatal : une surcharge du scancode le tranche.
  unresolvedConflicts = lib.filter (s: !(cfg.remoteOverrides ? ${s})) (lib.attrNames conflicts);

  # Une surcharge qui ne correspond à aucun scancode chargé est une faute de
  # frappe, ou vise une télécommande désactivée.
  orphanOverrides = lib.filter (s: !(claims ? ${s})) (lib.attrNames cfg.remoteOverrides);

  finalEntries = lib.filter (e: e.keycode != null) (
    lib.mapAttrsToList (
      scancode: c:
      let
        first = lib.head c;
        overridden = cfg.remoteOverrides ? ${scancode};
      in
      {
        inherit scancode;
        inherit (first) protocol variant;
        keycode = if overridden then cfg.remoteOverrides.${scancode} else first.keycode;
      }
    ) claims
  );

  # Une section [[protocols]] par couple protocole/variante.
  keymapText = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (
      group: entries:
      let
        parts = lib.splitString "|" group;
        protocol = lib.head parts;
        variant = lib.elemAt parts 1;
        header = [
          "[[protocols]]"
          "name = \"nixelec\""
          "protocol = \"${protocol}\""
        ]
        ++ lib.optional (variant != "") "variant = \"${variant}\""
        ++ [ "[protocols.scancodes]" ];
      in
      lib.concatStringsSep "\n" header
      + "\n"
      + lib.concatMapStrings (e: "${e.scancode} = \"${e.keycode}\"\n") entries
    ) (lib.groupBy (e: "${e.protocol}|${if e.variant == null then "" else e.variant}") finalEntries)
  );

  # Une table dont tous les scancodes tiennent sur 8 bits vient d'un récepteur à
  # décodeur matériel. Un récepteur logiciel rend l'adresse dans le scancode :
  # elle ne matchera que si l'adresse vaut 0x00. Avertissement, pas erreur.
  maybeHardwareTables = lib.filter (
    name:
    let
      entries = (parseRemote name).entries;
    in
    entries != [ ] && lib.all (e: lib.stringLength e.scancode <= 4) entries
  ) enabledNames;

  keymap = pkgs.writeText "remotes.toml" (
    lib.warnIf (maybeHardwareTables != [ ])
      "nixelec.ir : table(s) 8 bits (${lib.concatStringsSep ", " maybeHardwareTables}) — relevées avec un décodeur matériel ; sur un récepteur logiciel (meson-ir, gpio_ir_recv), le scancode doit inclure l'adresse (ex. 0x2fe40), sinon la table ne matchera pas"
      keymapText
  );
in
{
  options.nixelec.ir = {
    enable = lib.mkEnableOption "récepteur IR (rc-core + ir-keytable, sans LIRC)";

    remotes = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [
        "hk1x3"
        "mecool"
      ];
      description = ''
        Télécommandes activées, par nom de fichier sans `.toml`. Vide = toutes
        celles trouvées (celles du module, plus `extraRemotesDir`). Les tables
        sont **fusionnées** : plusieurs télécommandes cohabitent, à condition
        qu'aucun scancode ne revendique deux keycodes différents — un conflit
        non tranché échoue à l'éval, pas à la télécommande.
      '';
    };

    remoteOverrides = lib.mkOption {
      type = lib.types.attrsOf (lib.types.nullOr lib.types.str);
      default = { };
      example = {
        "0x404043" = null;
        "0x116" = "KEY_ENTER";
      };
      description = ''
        Surcharges par scancode : `null` désactive la touche (le scancode n'est
        pas écrit, donc absent du keybit), une valeur la réaffecte. C'est le
        mécanisme pour trancher un doublon entre deux télécommandes.
      '';
    };

    extraRemotesDir = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Répertoire supplémentaire de keymaps `.toml` (couche carte, publique ou
        privée). Même nom de fichier qu'une table du module = la version
        supplémentaire gagne.
      '';
    };

    inputName = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Nom du périphérique d'entrée créé par rc-core — c'est lui que la règle
        udev doit taguer pour que Kodi/libinput l'énumère. `sunxi-ir` pour le
        décodeur du SoC Allwinner, `meson-ir` pour le décodeur Amlogic,
        `gpio_ir_recv` pour un récepteur GPIO. La couche carte le fournit.
      '';
    };

    protocols = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "nec" ];
      description = ''
        Décodeurs activés par `ir-keytable -p`. `nec` couvre NEC, NECX et
        NEC32 : c'est le cas de toutes les télécommandes relevées jusqu'ici.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.inputName != null;
        message = "nixelec.ir.inputName : la couche carte doit fournir le nom d'entrée du récepteur (sunxi-ir, meson-ir, gpio_ir_recv…).";
      }
      {
        assertion = unknownRemotes == [ ];
        message = "nixelec.ir.remotes : télécommande(s) inconnue(s) ${lib.concatStringsSep ", " unknownRemotes} — disponibles : ${lib.concatStringsSep ", " availableNames}.";
      }
      {
        assertion = enabledNames != [ ];
        message = "nixelec.ir.remotes : aucune télécommande disponible (répertoire `remotes/` vide ?).";
      }
      {
        assertion = unresolvedConflicts == [ ];
        message = "nixelec.ir : scancode(s) revendiqué(s) avec deux keycodes — ${lib.concatStringsSep " ; " conflictReport}. Trancher avec `nixelec.ir.remoteOverrides`.";
      }
      {
        assertion = orphanOverrides == [ ];
        message = "nixelec.ir.remoteOverrides : scancode(s) absent(s) des tables chargées — ${lib.concatStringsSep ", " orphanOverrides}.";
      }
    ];

    # `ir_nec_decoder` n'a aucun compatible OF : le pruner de modules de nixbian
    # ne le garde que s'il est déclaré ici. Sans lui, `ir-keytable -p nec`
    # échoue et le device reste en mode brut — silencieusement côté Kodi.
    boot.kernelModules = [ "ir_nec_decoder" ];

    # La keymap est la fusion de toutes les télécommandes activées ; le nom du
    # fichier ne change pas quand la liste change, donc `rc_maps.cfg` reste
    # valable pour les outils qui le lisent.
    environment.etc."rc_keymaps/remotes.toml".source = keymap;
    environment.etc."rc_maps.cfg".text = "* * remotes.toml";

    environment.systemPackages = [ v4l ];

    # Sans ce tag, udev ne place pas le device sur un siège et libinput (le
    # backend de Kodi) ne l'énumère jamais : la keymap est chargée mais les
    # touches n'arrivent pas. `ID_INPUT_POINTINGSTICK` est un faux positif du
    # classifieur — le bitmask KEY_* d'une télécommande ressemble à un stick.
    services.udev.extraRules = ''
      ACTION=="add", SUBSYSTEM=="input", ATTRS{name}=="${cfg.inputName}", ENV{ID_SEAT}="seat0", TAG+="seat", ENV{ID_INPUT_KEY}="1", ENV{ID_INPUT_KEYBOARD}="1", ENV{ID_INPUT_POINTINGSTICK}=""
    '';

    systemd.services.ir-keymap = {
      description = "Charge les keymaps IR (toutes les télécommandes configurées)";
      wantedBy = [ "multi-user.target" ];
      after = [ "systemd-udev-settle.service" ];
      serviceConfig.Type = "oneshot";
      # Le numéro de `rcN` n'est pas stable : sur ces SoC le CEC HDMI peut
      # occuper rc0. On choisit le premier device dont les protocoles
      # mentionnent celui qu'on veut, jamais par numéro.
      script = ''
        dev=""
        for d in /sys/class/rc/rc*; do
          [ -e "$d/protocols" ] || continue
          for p in ${lib.concatStringsSep " " cfg.protocols}; do
            if grep -qw "$p" "$d/protocols"; then dev=$(basename "$d"); break 2; fi
          done
        done
        if [ -z "$dev" ]; then
          echo "ir-keymap: aucun récepteur IR (nœud DT absent ou désactivé ?)" >&2
          exit 0
        fi
        exec ${v4l}/bin/ir-keytable -s "$dev" -c -p ${lib.concatStringsSep "," cfg.protocols} -w /etc/rc_keymaps/remotes.toml
      '';
    };
  };
}
