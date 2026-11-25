# flake.nix の packages.<linux>.docker から呼ばれる。
# Haskell スクリプト機能のため、イメージには GHC と project-m36 のパッケージ DB も入れる。
{ pkgs, haskellPackages }:
let
  project = pkgs.haskell.lib.dontCheck haskellPackages.project-m36;
  ghc = haskellPackages.ghc;
  ghcWithPackages = haskellPackages.ghcWithPackages (p: [ p.project-m36 ]);

  projectBin = "${project}/bin";
  ghcBin = "${ghc}/bin";
  ghcLib = "${ghc}/lib";
  projectLib = "${project}/lib";
  glibcLib = "${pkgs.glibc}/lib";
  ghcWithPackagesDatabase = "${ghcWithPackages}/lib/${ghc.targetPrefix}${ghc.haskellCompilerName}/lib/package.conf.d";
in
pkgs.dockerTools.buildImage {
  name = "project-m36";
  tag = "latest";
  copyToRoot = [
    ghc
    ghcWithPackages
    project
    pkgs.bash
    pkgs.coreutils
    pkgs.glibc
  ];
  config = {
    Env = [
      "LANG=en_US.UTF-8"
      "PATH=/bin:/usr/bin:${projectBin}:${ghcBin}"
      "LD_LIBRARY_PATH=${ghcLib}:${projectLib}:${glibcLib}"
      "GHC_PACKAGE_PATH=${ghcWithPackagesDatabase}"
    ];
    ExposedPorts = { "6543/tcp" = { }; "8000/tcp" = { }; };
    Cmd = [ "/bin/sh" "-c" "export PATH=$PATH:${projectBin}:${ghcBin} && exec tutd" ];
    Volumes = { "/tmp" = { }; };
  };
}
