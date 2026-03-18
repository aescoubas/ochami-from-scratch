{ pkgs
, lib
, profileName
, images
}:

pkgs.runCommand "ochami-oci-images-${profileName}" { } ''
  mkdir -p "$out"
  ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: archive:
    "ln -s ${archive} \"$out/${name}.tar.gz\""
  ) images)}
''
