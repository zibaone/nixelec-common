{ ... }:

{
  perSystem =
    { pkgs, ... }:
    {
      packages.fd6xx = pkgs.callPackage ../packages/fd6xx { };
    };
}
