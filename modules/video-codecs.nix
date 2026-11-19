{
  lib,
  ...
}:

{
  options.nixelec.video = {
    unsupportedCodecs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "av01" ];
      description = ''
        Codec prefixes the VPU cannot decode on this platform, in the spelling
        used by yt-dlp and Kodi (`av01`, `vp9`, `hevc`, `avc1`).

        Declared by the family or board layer from a measurement, never guessed:
        the kiosk profile turns the list into the sendtokodi
        `avoid_video_codecs` setting and into the yt-dlp download filter, so a
        rendition the hardware cannot decode is never chosen — a black picture
        is reported by Kodi as a successful playback, so there is no runtime
        signal to fall back on.

        Empty by default: no assumption is made about a board that has not been
        measured. Mesuré le 2026-11-19 sur H616/H618 : `v4l2-ctl
        --list-formats-out` donne `MG2S S264 S265 VP8F VP9F`, sans `AV1F` —
        d'où `[ "av01" ]` dans la couche famille sunxi64.
      '';
    };
  };
}
