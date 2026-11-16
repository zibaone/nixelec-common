# nixelec-common

Contrats de service **matériel-agnostiques** partagés par les couches appareil
`nixelec-sunxi64` et `nixelec-meson64`.

```
nixpkgs → nixbian → nixelec-common → { nixelec-sunxi64, nixelec-meson64 } → assemblage
```

Une couche appareil ne réimplémente pas un contrat commun : elle apporte le
pilote, le firmware et les données de sa carte. Ce dépôt ne contient aucun nom de
flotte, aucune IP, aucun secret, aucun blob non redistribuable.

Aucun patch kernel ici : la composition et le build des noyaux appartiennent aux
couches famille (`nixelec-sunxi64`, `nixelec-meson64`), qui appliquent l'export
Armbian de `nixbian` et leurs propres patches (décision B, 2026-11-16). Ce dépôt
ne porte que des contrats NixOS.

## Modules

| Module | Contrat | Fourni par la couche carte |
|---|---|---|
| `wifi-client` | `nixelec.wifiClient` : source des réseaux (`networksFile` prioritaire, sinon `ssid` + `pskFile`), rendu de `/run/wpa_supplicant.conf`, unité `wpa-supplicant-*`, power-save après association | pilote, firmware, NVRAM, nom d'interface stable |
| `ir` | tables `remotes/*.toml`, fusion, gardes d'éval (conflit, override orphelin), keymap, règle udev | récepteur (`sunxi-ir`, `meson-ir`, `gpio_ir_recv`) et `nixelec.ir.inputName` |
| `front-panel` | afficheur FD650/FD655 bit-bang, unité `oneshot` sans dépendance de boot | `chip`, `clk`, `dat`, `pushPull`, `leftToRight`, `text` |
| `emmc-root` | `fileSystems."/"` par étiquette, assertions ext4 (16 caractères, pas `nixos`), bootloader-agnostique | `rootLabel`, `extraPackages` éventuels |

Le dépôt expose aussi `flake.lib { pkgs }` → `mkDtbo { name, dts }`, qui compile
un overlay DT en `.dtbo` avec `dtc` seul : pas de `kernel.dev`, donc pas de
recompilation du noyau. La couche carte enregistre le `.dtbo` dans son propre
`hardware.nixbian.overlays`.

## Utilisation

```nix
{
  inputs.nixelec-common = {
    url = "github:zibaone/nixelec-common";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  modules = [
    nixelec-common.nixosModules.wifi-client
    {
      nixelec.wifiClient = {
        enable = true;
        ssid = "…";
        pskFile = "/run/secrets/wifi-psk";  # jamais dans le store
      };
    }
  ];
}
```

Vérification : `nix flake check --system x86_64-linux -L`.
