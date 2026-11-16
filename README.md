# nixelec-common

Contrats de service **matériel-agnostiques** partagés par les couches appareil
`nixelec-sunxi64` et `nixelec-meson64`.

```
nixpkgs → nixbian → nixelec-common → { nixelec-sunxi64, nixelec-meson64 } → assemblage
```

Une couche appareil ne réimplémente pas un contrat commun : elle apporte le
pilote, le firmware et les données de sa carte. Ce dépôt ne contient aucun nom de
flotte, aucune IP, aucun secret, aucun blob non redistribuable.

## Modules

| Module | Contrat | Fourni par la couche carte |
|---|---|---|
| `wifi-client` | `nixelec.wifiClient` : source des réseaux (`networksFile` prioritaire, sinon `ssid` + `pskFile`), rendu de `/run/wpa_supplicant.conf`, unité `wpa-supplicant-*`, power-save après association | pilote, firmware, NVRAM, nom d'interface stable |

Les autres modules (`ir`, `front-panel`, `emmc-root`, overlay DT) suivent la même
règle et sont ajoutés au fil de la migration, un commit par module.

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
