# `gameci-update-images [VERSION...]`: resolve unityci/editor tags to manifest digests and write
# them into nix/images.json. With no versions, refreshes the versions already pinned.
{
  writeShellApplication,
  curl,
  jq,
  coreutils,
}:
writeShellApplication {
  name = "gameci-update-images";

  runtimeInputs = [
    curl
    jq
    coreutils
  ];

  text = ''
    file="''${GAMECI_IMAGES_JSON:-nix/images.json}"
    if [ ! -f "$file" ]; then
      echo "gameci-update-images: $file not found; run from the flake root or set GAMECI_IMAGES_JSON" >&2
      exit 2
    fi

    image_version="$(jq -r '.imageVersion' "$file")"
    declare -A modules=([linux]=linux-il2cpp [windows]=windows-mono [webgl]=webgl [android]=android [macos]=mac-mono)

    if [ $# -gt 0 ]; then
      versions=("$@")
    else
      mapfile -t versions < <(jq -r '.versions | keys[]' "$file")
    fi

    tmp="$(mktemp)"
    cp "$file" "$tmp"

    for v in "''${versions[@]}"; do
      for target in "''${!modules[@]}"; do
        tag="ubuntu-$v-''${modules[$target]}-$image_version"
        digest="$(curl -fsS "https://hub.docker.com/v2/repositories/unityci/editor/tags/$tag" | jq -r '.digest // empty')"
        if [ -z "$digest" ]; then
          echo "gameci-update-images: no such tag unityci/editor:$tag" >&2
          exit 1
        fi
        echo "$v $target -> $digest" >&2
        jq --arg v "$v" --arg t "$target" --arg d "$digest" '.versions[$v][$t] = $d' "$tmp" > "$tmp.new"
        mv "$tmp.new" "$tmp"
      done
    done

    jq -S . "$tmp" > "$file"
    rm -f "$tmp"
    echo "gameci-update-images: wrote $file" >&2
  '';
}
