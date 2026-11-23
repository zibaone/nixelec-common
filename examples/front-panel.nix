{ ... }:

{
  nixelec.frontPanel = {
    enable = true;
    chip = "/dev/gpiochip1";
    clk = 226;
    dat = 227;
    leftToRight = true;
    text = "TEST";

    # Profil de dalle : quatre positions, octet d'icônes à 0x66 (commande
    # 0x33 × 2, comme le registre « icon-set » des FD650/FD655). Les
    # adresses/bits sont des données de carte ; cet exemple n'est pas une
    # mesure, il exerce l'éval et le rendu d'état.
    layout = {
      digits = 4;
      digitBase = 104; # 0x68
      digitStride = 2;
      icons = {
        eth = {
          address = 102; # 0x66
          mask = 32; # 0x20
        };
        wifi = {
          address = 102; # 0x66
          mask = 64; # 0x40
        };
      };
    };

    icons = [ "eth" ];
    status.enable = true;
  };
}
