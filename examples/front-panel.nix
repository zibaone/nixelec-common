{ ... }:

{
  nixelec.frontPanel = {
    enable = true;
    chip = "/dev/gpiochip1";
    clk = 226;
    dat = 227;
    leftToRight = true;
    text = "TEST";

    # Profil de la H96 mesure a l'ecran le 2026-11-23 : cinq grilles,
    # octet d'icones 0x66 (commande 0x33 x 2). Les sept bits ont ete releves
    # un par un : alarm, usb, pause, play, colon, lan, wifi.
    layout = {
      digits = 5;
      digitBase = 104; # 0x68
      digitStride = 2;
      icons = {
        alarm = {
          address = 102; # 0x66
          mask = 1; # 0x01
        };
        usb = {
          address = 102;
          mask = 2; # 0x02
        };
        pause = {
          address = 102;
          mask = 4; # 0x04
        };
        play = {
          address = 102;
          mask = 8; # 0x08
        };
        colon = {
          address = 102;
          mask = 16; # 0x10
        };
        lan = {
          address = 102;
          mask = 32; # 0x20
        };
        wifi = {
          address = 102;
          mask = 64; # 0x40
        };
      };
    };

    icons = [ ];
    status = {
      enable = true;
      ethernetIcon = "lan";
      wifiIcon = "wifi";
    };
    clock.enable = true;
  };
}
