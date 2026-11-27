{ ... }:

{
  flake.nixosModules = {
    # Client WPA agnostique du pilote : contrat de provisioning + wpa_supplicant.
    # Le pilote, le firmware et le nom d'interface restent dans la couche carte.
    wifi-client = ../modules/wifi-client.nix;

    # Récepteur IR : tables, fusion, gardes d'éval, keymap et udev. Aucun
    # récepteur : la couche carte fournit sunxi-ir, meson-ir ou gpio_ir_recv.
    ir = ../modules/ir.nix;

    # Afficheur façade FD650/FD655 : protocole bit-bang, chip/clk/dat en
    # données de carte.
    front-panel = ../modules/front-panel.nix;

    # Racine sur étiquette, bootloader-agnostique (extlinux ou U-Boot vendor).
    emmc-root = ../modules/emmc-root.nix;

    # Contrat veille/réveil : bouton power + mode de veille. Les sources
    # (IR, WoL, WoWLAN) restent des données de la couche famille/carte.
    power = ../modules/power.nix;

    # Contrat « ce que le VPU ne décode pas » : la couche famille ou carte le
    # remplit à partir d'une mesure, le profil kiosque le traduit en réglage
    # sendtokodi et en filtre yt-dlp.
    video-codecs = ../modules/video-codecs.nix;
  };
}
