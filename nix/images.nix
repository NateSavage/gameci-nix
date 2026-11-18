# Pinned Unity editor images, read from images.json (rewritten by `nix run .#update-images`).
#
# Each entry is the manifest digest of a unityci/editor tag, so a build never silently picks up
# a re-pushed image. Target names are ours; the image module each one maps to is in `modules`.
let
  data = builtins.fromJSON (builtins.readFile ./images.json);
in
data
// {
  # target -> unityci/editor module suffix, and the CLI's --targetPlatform value
  targets = {
    linux = {
      module = "linux-il2cpp";
      platform = "StandaloneLinux64";
    };
    windows = {
      module = "windows-mono";
      platform = "StandaloneWindows64";
    };
    webgl = {
      module = "webgl";
      platform = "WebGL";
    };
    android = {
      module = "android";
      platform = "Android";
    };
    # Mono only: a Mac IL2CPP build needs Apple's toolchain, which a Linux editor does not have
    macos = {
      module = "mac-mono";
      platform = "StandaloneOSX";
    };
  };
}
