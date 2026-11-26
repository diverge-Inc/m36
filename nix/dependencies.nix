# haskell-flake のプロジェクトモジュール：nixpkgs 標準の haskellPackages に対して、
# project-m36 を組むのに要る設定だけを書く。
# flake の haskellFlakeProjectModules.output に含まれて外にも出るので、
# 使う側の haskell-flake プロジェクトは import するだけでこの設定が入る。
#
# 方針：依存の版は nixpkgs のものをそのまま使い、project-m36.cabal の制約を
# それに合わせて書く。ここに残すのは、他人のパッケージ側の問題で nixpkgs のままでは
# 組めないものだけ。nixpkgs を上げたら（nix flake update）減らせないか確かめる。
{ pkgs, ... }:
let
  # 他人のパッケージの cabal ファイルで、合わない上限だけを書き換える。
  # jailbreak は制約をすべて外すので使わない。--replace-fail なので、上流の cabal
  # ファイルが変わったらビルドが止まって気づける。Hackage の改訂版（revision）の
  # cabal ファイルに置き換わった後（postPatch）に効く。
  loosenBounds = cabalFile: replacements: {
    custom = pkgs.haskell.lib.compose.overrideCabal (old: {
      postPatch = (old.postPatch or "") + ''
        substituteInPlace ${cabalFile} \
          ${pkgs.lib.concatMapStringsSep " \\\n          "
            (r: "--replace-fail ${pkgs.lib.escapeShellArg r.from} ${pkgs.lib.escapeShellArg r.to}")
            replacements}
      '';
    });
  };

  # Hackage から版とハッシュを指定して取る。haskell-flake の packages.<name>.source に
  # 版の文字列を書く方法は nixpkgs の all-cabal-hashes を引くが、その索引は古いことが
  # あるうえ、大きな tarball を取りに行く。こちらはその索引を使わない。
  fromHackage = pkg: ver: sha256: { self, ... }: {
    custom = _: self.callHackageDirect { inherit pkg ver sha256; } { };
  };
in
{
  settings = {
    # curryer-rpc 0.5.1（nixpkgs の版）は crypton-x509 >= 1.7.7 と宣言しているが、実際には
    # ASN.1 の型が crypton-asn1-types に移った 1.8 以降でないとコンパイルできない
    # （宣言の下限が誤っている）。tls も >= 2.1.12 を求めるが nixpkgs は 2.1.8。
    # x509 1.9 と tls 2.3 以降は crypton 1.1 と（broken 扱いの）mlkem まで要るので、
    # crypton 1.0 系のまま組める x509 1.8 と tls 2.2 にする。
    crypton-x509 = fromHackage "crypton-x509" "1.8.0" "sha256-wxU8Ou52UCuCT2gbxqPKssteIVGUyg5WEbv1xRIyZTg=";
    crypton-x509-store = fromHackage "crypton-x509-store" "1.8.0" "sha256-U6DH5Ke3JXAzZuqxLM6mPKDxqj4HTf5kjoBXaerLOcc=";
    crypton-x509-system = fromHackage "crypton-x509-system" "1.8.0" "sha256-uUNhwQnTPuVd1feZLUZJYKHIk/5v6t7nHpf1jqrMGTQ=";
    crypton-x509-validation = fromHackage "crypton-x509-validation" "1.8.0" "sha256-CyRqTUOcUzzVlQfTd3yylwDVtOaumBbBg9hMyvtcu7c=";
    tls = fromHackage "tls" "2.2.2" "sha256-lbroDPZiOa2YH1jqEzxzNgBGcPZDP6WJEeD0odDgNqs=";

    # Hackage の tarball にテスト用の証明書の設定（test/Curryer/Test/openssl.cnf など）が
    # 入っておらず、TLS のテストが通らない
    curryer-rpc.check = false;

    # winery の依存。nixpkgs では broken 扱い。
    # - template-haskell 2.21（GHC 9.8）以降、データ型の型変数の束縛が () から
    #   BndrVis に変わった 1 か所を直す
    # - base / template-haskell / barbies の上限を GHC 9.10 と nixpkgs の版まで広げる
    barbies-th = {
      imports = [
        (loosenBounds "barbies-th.cabal" [
          { from = "base >= 4.12 && <4.20"; to = "base >= 4.12 && <4.21"; }
          { from = "template-haskell >= 2.14 && <2.22"; to = "template-haskell >= 2.14 && <2.23"; }
          { from = "barbies ^>= 2.0.1"; to = "barbies >= 2.0.1 && < 2.2"; }
        ])
      ];
      broken = false;
      patches = [ ./patches/barbies-th-template-haskell-2.21.patch ];
    };

    # barbies の上限を nixpkgs の 2.1 系まで広げる。ライブラリは通るが、テストの 1 か所が
    # GHC 9.10 のレコード更新の型推論で曖昧になってコンパイルできないので、テストは止める
    winery = {
      imports = [
        (loosenBounds "winery.cabal" [
          { from = "barbies ^>= 2.0"; to = "barbies >= 2.0 && < 2.2"; }
        ])
      ];
      check = false;
    };

    # project-m36 が無条件に依存している。テストは /proc を読むので Linux でしか通らない
    system-linux-proc.check = false;
  };
}
