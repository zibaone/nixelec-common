{ ... }:

{
  nixelec.wifiClient = {
    enable = true;
    interface = "wlan0";
    ssid = "nixelec-test";
    pskFile = "/run/secrets/wifi-psk";
  };
}
