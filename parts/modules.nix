{ ... }:

{
  flake.nixosModules = {
    # Client WPA agnostique du pilote : contrat de provisioning + wpa_supplicant.
    # Le pilote, le firmware et le nom d'interface restent dans la couche carte.
    wifi-client = ../modules/wifi-client.nix;
  };
}
