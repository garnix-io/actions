{
  description = "Some garnix actions";

  inputs.flake-utils.url = "github:numtide/flake-utils";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs";

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let pkgs = nixpkgs.legacyPackages.${system}; in
      {
        lib = let
        in {
          reviewDog = {
            linter,
            errorFormat ? "%f:$l%:%c: %m",
            encryptedTokenFile
          }: pkgs.writeShellApplication {
              name = "reviewdog";
              runtimeInputs = with pkgs; [
                reviewdog
              ];
              text = ''
                ${linter} | reviewdog -reporter=github-annotations -efm=${errorFormat}
              '';
            };
        };
        apps = {
          reviewDog = flake-utils.lib.mkApp { drv = self.packages.${system}.reviewDog; };
        };
      }
    );
}
