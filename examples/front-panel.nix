{ ... }:

{
  nixelec.frontPanel = {
    enable = true;
    chip = "/dev/gpiochip1";
    clk = 226;
    dat = 227;
    text = "TEST";
  };
}
