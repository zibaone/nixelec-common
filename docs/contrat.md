# Contrat `nixelec.wifiClient`

Le module ne fournit **ni pilote ni firmware** : il possède le contrat de
provisioning et le service `wpa_supplicant`. La couche carte fournit le pilote,
le firmware, la NVRAM et, si nécessaire, une règle de nommage d'interface.

## Sources de la configuration

Deux sources, dans cet ordre :

1. `networksFile` — chemin d'un fichier `wpa_supplicant` complet, rendu au boot
   par la couche de provisioning. Lu verbatim ; prioritaire dès qu'il est
   lisible. Le fichier doit être sous `/run` : le clair ne touche pas le disque.
2. `ssid` + `pskFile` — couple historique de secours. `pskFile` est lu au boot,
   jamais cuit dans le store. Les deux options vont ensemble : n'en poser qu'une
   échoue à l'évaluation.

Sans source, `wpa_supplicant` n'est pas démarré. Une source déclarée mais
illisible fait échouer `wpa-psk` bruyamment, et `wpa-supplicant-*` est *skipped*
(`ConditionPathExists`) plutôt que relancé en boucle.

## Unités

| Unité | Rôle |
|---|---|
| `wpa-psk` | rend `/run/wpa_supplicant.conf` (mode 0600) depuis la source |
| `wpa-supplicant-<interface>` | `wpa_supplicant` sur l'interface, 5 essais maximum |
| `wlan-ps-off` | attend une adresse IPv4 puis bascule `power_save` on/off pour forcer l'appel firmware |

`wlan-ps-off` est un `Type=simple` : il ne bloque pas `multi-user.target`. Il
sort en 0 après 120 s sans association et ne fait jamais échouer le boot.

## Ce que la couche carte doit fournir

- le module noyau et le firmware du chip ;
- le cas échéant, le nom d'interface stable (`systemd.network.links`) ;
- `nixelec.wifiClient.enable = true` et les données de sa carte.

Le module ne connaît ni SSID de flotte, ni chemin de secret, ni nom de carte.
