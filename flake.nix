{
  description = "Project:M36 relational algebra engine (diverge fork)";

  inputs = {
    # nixpkgs の標準 GHC（haskellPackages）に合わせる。HLS を含めて
    # 依存のほとんどが cache.nixos.org から取れる。
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    flake-parts.inputs.nixpkgs-lib.follows = "nixpkgs";
    haskell-flake.url = "github:srid/haskell-flake";
  };

  outputs = inputs@{ self, nixpkgs, flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } ({ withSystem, ... }: {
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      imports = [ inputs.haskell-flake.flakeModule ];

      perSystem = { self', config, pkgs, lib, ... }: {
        haskellProjects.default = {
          # Nix まわりのファイルを変えただけで project-m36 を作り直さないよう、
          # ビルドに関係しないものをソースから外す。
          projectRoot = builtins.toString (lib.fileset.toSource {
            root = ./.;
            fileset = lib.fileset.difference ./. (lib.fileset.unions (map lib.fileset.maybeMissing [
              ./flake.nix
              ./flake.lock
              ./nix
              ./docker.nix
              ./.github
              ./.envrc
              ./.vscode
              ./jupyter
              ./posts
            ]));
          });

          imports = [ ./nix/dependencies.nix ];

          settings.project-m36 = {
            haddock = false;
            # テストが test/ 以下や scripts/ のファイルを直接読むので、sdist ではなく
            # ソースツリーから組む
            buildFromSdist = false;
            # Haskell スクリプト機能のテストは、実行時に GHC API で project-m36 と依存を
            # 読み込む。ビルド中はどちらもパッケージ DB に入っていないので、
            # ScriptSession が読む GHC_ENVIRONMENT で場所を教える。cabal が作る環境ファイルと
            # 同じく、テストのモジュール（test/TutorialD/Interpreter/TestModule.hs）が
            # import する scientific も公開する。
            drvAttrs.preCheck = ''
              cat > "$PWD/pm36-test.ghc.env" <<EOF
              package-db $packageConfDir
              package-db $PWD/dist/package.conf.inplace
              package-id $(ghc-pkg --package-db="$packageConfDir" field scientific id --simple-output)
              EOF
              export GHC_ENVIRONMENT="$PWD/pm36-test.ghc.env"
            '';
          };

          devShell = {
            tools = hp: { inherit (hp) ghcid; nixpkgs-fmt = pkgs.nixpkgs-fmt; };
            # HLS が project-m36 を読めるかの検査は、ビルドのたびに走ると重いので外す
            hlsCheck.enable = false;
          };
        };

        packages = {
          default = self'.packages.project-m36;
        } // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
          docker = import ./docker.nix {
            inherit pkgs;
            haskellPackages = config.haskellProjects.default.outputs.finalPackages;
          };
        };

        # 差し替え済みの Haskell パッケージ集合（haskell-flake を使わない利用者向け）
        legacyPackages.haskellPackages = config.haskellProjects.default.outputs.finalPackages;

        apps =
          let
            mkApp = name: {
              type = "app";
              program = "${self'.packages.project-m36}/bin/${name}";
              meta.description = "Project:M36 ${name}";
            };
          in
          lib.genAttrs [ "tutd" "sqlegacy" "project-m36-server" "project-m36-websocket-server" ] mkApp
          // { default = mkApp "tutd"; };

        formatter = pkgs.nixpkgs-fmt;
      };

      flake = {
        # 実行ファイル（tutd, project-m36-server など）を pkgs.project-m36 として足す。
        # ライブラリとして使うなら、haskell-flake の利用者は
        # haskellFlakeProjectModules.output を import し、そうでなければ
        # legacyPackages.<system>.haskellPackages（差し替え済みのパッケージ集合）を使う。
        # 使う側のトップレベルの haskellPackages を差し替える overlay は、cabal2nix 自身が
        # 差し替え後の集合に依存して循環するので出さない。
        overlays.default = final: prev: {
          project-m36 = withSystem prev.stdenv.hostPlatform.system ({ config, ... }:
            prev.haskell.lib.justStaticExecutables
              config.haskellProjects.default.outputs.finalPackages.project-m36);
        };
      };
    });
}
