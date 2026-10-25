{
  description = "mdpreview.nvim — optional Nix dev environment and tests";

  # Nix is entirely optional. This flake only provides a reproducible dev shell
  # (`nix develop`) and a headless test check (`nix flake check`). Users who do
  # not use Nix can install the plugin with any Neovim plugin manager and run
  # the tests with `bash test/run.sh`.

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      mkTests =
        pkgs:
        pkgs.stdenvNoCC.mkDerivation {
          pname = "mdpreview-nvim-tests";
          version = "0.1.0";
          src = self;

          nativeBuildInputs = [ pkgs.neovim ];

          dontConfigure = true;

          buildPhase = ''
            export HOME="$TMPDIR/home"
            export XDG_CONFIG_HOME="$TMPDIR/config"
            export XDG_DATA_HOME="$TMPDIR/data"
            export XDG_STATE_HOME="$TMPDIR/state"
            mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME"
            bash test/run.sh
          '';

          installPhase = ''
            mkdir -p "$out"
            touch "$out/passed"
          '';
        };
    in
    {
      packages = forAllSystems (pkgs: {
        default = pkgs.vimUtils.buildVimPlugin {
          pname = "mdpreview-nvim";
          version = "0.1.0";
          src = self;
        };
      });

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = [
            pkgs.neovim
            pkgs.luajit
            pkgs.lua-language-server
            pkgs.stylua
          ];
          shellHook = ''
            echo "mdpreview.nvim development shell"
            echo "  run the tests: bash test/run.sh"
          '';
        };
      });

      checks = forAllSystems (pkgs: {
        default = mkTests pkgs;
        tests = mkTests pkgs;
      });

      formatter = forAllSystems (pkgs: pkgs.nixfmt);
    };
}
