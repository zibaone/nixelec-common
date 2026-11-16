{ self, inputs, ... }:

{
  perSystem =
    { pkgs, ... }:
    {
      checks = {
        formatting =
          pkgs.runCommand "check-nixfmt"
            {
              nativeBuildInputs = [ pkgs.nixfmt ];
            }
            ''
              find ${self} -name '*.nix' -exec nixfmt --check {} +
              touch $out
            '';

        eval-wifi-client =
          let
            example = inputs.nixpkgs.lib.nixosSystem {
              system = "x86_64-linux";
              modules = [
                self.nixosModules.wifi-client
                ../examples/wifi-client.nix
                {
                  system.stateVersion = "26.05";
                  boot.loader.grub.enable = false;
                  fileSystems."/" = {
                    device = "/dev/null";
                    fsType = "ext4";
                  };
                }
              ];
            };
          in
          pkgs.runCommand "check-eval-wifi-client"
            {
              drv = builtins.unsafeDiscardStringContext example.config.system.build.toplevel.drvPath;
            }
            ''
              test -n "$drv"
              touch $out
            '';

        eval-ir =
          let
            example = inputs.nixpkgs.lib.nixosSystem {
              system = "x86_64-linux";
              modules = [
                self.nixosModules.ir
                ../examples/ir.nix
                {
                  system.stateVersion = "26.05";
                  boot.loader.grub.enable = false;
                  fileSystems."/" = {
                    device = "/dev/null";
                    fsType = "ext4";
                  };
                }
              ];
            };
          in
          pkgs.runCommand "check-eval-ir"
            {
              drv = builtins.unsafeDiscardStringContext example.config.system.build.toplevel.drvPath;
            }
            ''
              test -n "$drv"
              touch $out
            '';

        eval-front-panel =
          let
            example = inputs.nixpkgs.lib.nixosSystem {
              system = "x86_64-linux";
              modules = [
                self.nixosModules.front-panel
                ../examples/front-panel.nix
                {
                  system.stateVersion = "26.05";
                  boot.loader.grub.enable = false;
                  fileSystems."/" = {
                    device = "/dev/null";
                    fsType = "ext4";
                  };
                }
              ];
            };
          in
          pkgs.runCommand "check-eval-front-panel"
            {
              drv = builtins.unsafeDiscardStringContext example.config.system.build.toplevel.drvPath;
            }
            ''
              test -n "$drv"
              touch $out
            '';

        eval-emmc-root =
          let
            example = inputs.nixpkgs.lib.nixosSystem {
              system = "x86_64-linux";
              modules = [
                self.nixosModules.emmc-root
                ../examples/emmc-root.nix
                {
                  system.stateVersion = "26.05";
                  boot.loader.grub.enable = false;
                }
              ];
            };
          in
          pkgs.runCommand "check-eval-emmc-root"
            {
              drv = builtins.unsafeDiscardStringContext example.config.system.build.toplevel.drvPath;
            }
            ''
              test -n "$drv"
              touch $out
            '';
      };
    };
}
