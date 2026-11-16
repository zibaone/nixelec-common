# Compilation d'un overlay DT en .dtbo, sans passer par `compileDTS`.
#
# `hardware.deviceTree.overlays` avec un `dtsFile` tire `kernel.dev`
# (include-prefixes) : cette sortie n'est pas au cache et déclenche une
# recompilation complète du noyau (mesuré). Un `.dtbo` fourni tel quel ne passe
# que par `applyOverlays`, qui travaille sur le DTB déjà construit. Ce fichier
# ne fait donc que `dtc`.
{ pkgs }:
{
  mkDtbo =
    { name, dts }:
    pkgs.runCommandLocal "${name}.dtbo" { nativeBuildInputs = [ pkgs.dtc ]; } ''
      ${pkgs.dtc}/bin/dtc -@ -I dts -O dtb -o $out ${pkgs.writeText "${name}.dts" dts}
    '';
}
