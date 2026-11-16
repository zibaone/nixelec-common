{
  description = "nixelec-common — contrats de service matériel-agnostiques pour les couches nixelec";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/cd4ea8d57de16f4810bc5f14207bac45fbf19f67";
    flake-parts.url = "github:hercules-ci/flake-parts";
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      imports = [
        ./parts/modules.nix
        ./parts/packages.nix
        ./parts/checks.nix
      ];

      # Mécanisme commun de compilation d'un overlay DT en .dtbo. Les couches
      # carte l'utilisent pour activer un nœud (ir, etc.) sans recompiler le
      # noyau ; aucune option nixbian n'entre dans ce dépôt.
      flake.lib = { pkgs }: import ./lib/dt-overlay.nix { inherit pkgs; };
    };
}
