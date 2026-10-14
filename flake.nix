{
  description = "k3-weather: weather + MBTA display for a jailbroken Kindle 3";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs =
    { self, nixpkgs }:
    let
      forAllSystems = nixpkgs.lib.genAttrs [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
    in
    {
      # `nix develop`, then `zig build --release=small` for the Kindle build
      # or `zig build preview -- --png out.png` for a desktop preview.
      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.mkShell {
            packages = [ pkgs.zig_0_17 ];
          };
        }
      );
    };
}
