{
  description = "Game CI for NixOS: a pinned game-ci CLI plus Podman-backed wrappers for Unity builds and tests";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
  };

  outputs =
    { self, nixpkgs }:
    let
      # Unity's editor images are x86_64 only.
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};

      images = import ./nix/images.nix;
      imagesJson = pkgs.writeText "gameci-images.json" (
        builtins.toJSON {
          inherit (images) repository versions targets;
        }
      );

      game-ci-cli = pkgs.callPackage ./nix/cli.nix { };
      gameci-build = pkgs.callPackage ./nix/gameci-build.nix { inherit game-ci-cli imagesJson; };
      gameci-test-summary = pkgs.callPackage ./nix/gameci-test-summary.nix { };
      gameci-test = pkgs.callPackage ./nix/gameci-test.nix {
        inherit game-ci-cli gameci-test-summary imagesJson;
      };
      gameci-checkout = pkgs.callPackage ./nix/gameci-checkout.nix { };
      update-images = pkgs.callPackage ./nix/update-images.nix { };

      # everything a runner's jobs call, in one package
      gameci = pkgs.symlinkJoin {
        name = "gameci";
        paths = [
          gameci-build
          gameci-test
          gameci-test-summary
          gameci-checkout
        ];
      };

      app = package: name: {
        type = "app";
        program = "${package}/bin/${name}";
      };
    in
    {
      packages.${system} = {
        inherit
          game-ci-cli
          gameci
          gameci-build
          gameci-test
          gameci-test-summary
          gameci-checkout
          update-images
          ;
        default = gameci-build;
      };

      apps.${system} = {
        build = app gameci-build "gameci-build";
        test = app gameci-test "gameci-test";
        checkout = app gameci-checkout "gameci-checkout";
        update-images = app update-images "gameci-update-images";
        default = self.apps.${system}.build;
      };

      nixosModules.default = import ./nix/module.nix self;

      devShells.${system}.default = pkgs.mkShell {
        packages = [
          gameci
          game-ci-cli
          update-images
          pkgs.jq
        ];
      };

      formatter.${system} = pkgs.nixfmt;
    };
}
