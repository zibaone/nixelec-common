{
  lib,
  stdenv,
}:

stdenv.mkDerivation {
  pname = "fd6xx";
  version = "0.1.0";

  src = ./.;

  dontConfigure = true;

  buildPhase = ''
    runHook preBuild
    $CC -O2 -Wall -Wextra -o fd6xx fd6xx.c
    runHook postBuild
  '';

  # La composition des trames (ordre des chiffres, bits d'icones sur une
  # grille ou sur une adresse separee) est du pur calcul : elle se vérifie
  # sur x86, sans GPIO ni carte. Le test est dans le binaire pour qu'il
  # parte avec le même code que celui qui sera déployé.
  doCheck = true;
  checkPhase = ''
    runHook preCheck
    ./fd6xx selftest
    # Vérifie aussi le chemin CLI `show` (parsing ADDR:MASK, bit sur une
    # grille, bit sur une adresse séparée) sans ouvrir de GPIO.
    ./fd6xx --dry-run --digits 4 --base 104 --stride 2 --ltr \
      show --text TEST --bit 112:32 --clear 112:64 \
      | grep -q '^grid\[4\] addr=0x70 byte=0x20$'
    ./fd6xx --dry-run show --text H96 --bit 102:32 \
      | grep -q '^extra addr=0x66 byte=0x20$'
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 fd6xx $out/bin/fd6xx
    runHook postInstall
  '';

  meta = {
    description = "Bit-bang userspace driver for H616/H618 front-panel 7-segment displays (FD650/FD655)";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
  };
}
