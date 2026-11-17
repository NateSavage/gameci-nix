# The game-ci CLI is distributed as a single Bun-compiled executable. The Unity build logic
# (image selection, license activation, container flags) lives in it, so we package the
# release binary as-is and only fix its ELF interpreter for NixOS.
{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
}:
stdenv.mkDerivation rec {
  pname = "game-ci-cli";
  version = "0.1.72";

  src = fetchurl {
    url = "https://github.com/game-ci/cli/releases/download/v${version}/game-ci-linux-x64";
    # from the release's checksums.txt
    sha256 = "a14afcb203920e3bf457b1a8d231c6795e4cda2f3be2dce6a1f32800c7b1bc66";
  };

  dontUnpack = true;
  # A Bun-compiled binary carries its JS payload appended to the ELF file; stripping it
  # would discard that payload.
  dontStrip = true;

  nativeBuildInputs = [ autoPatchelfHook ];

  installPhase = ''
    runHook preInstall
    install -Dm755 $src $out/bin/game-ci
    runHook postInstall
  '';

  meta = {
    description = "Game CI command line interface (Unity, Godot and Unreal build automation)";
    homepage = "https://github.com/game-ci/cli";
    license = lib.licenses.mit;
    platforms = [ "x86_64-linux" ];
    mainProgram = "game-ci";
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
