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
  };
}
