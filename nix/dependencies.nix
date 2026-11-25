# haskell-flake のプロジェクトモジュール：nixpkgs 標準の haskellPackages に対して、
# project-m36 を組むのに要る依存の差し替えだけを書く。
# flake の haskellFlakeProjectModules.output に含まれて外にも出るので、
# 使う側の haskell-flake プロジェクトは import するだけでこの差し替えが入る。
#
# nixpkgs を上げたら（nix flake update）、要らなくなった項目がないか確かめて減らす。
{ ... }:
let
  # Hackage から版とハッシュを指定して取る。haskell-flake の packages.<name>.source に
  # 版の文字列を書く方法は nixpkgs の all-cabal-hashes を引くが、その索引が古いと
  # 新しい版が見つからない（curryer-rpc 0.5.2 など）。こちらはその索引を使わない。
  # `custom` は他の設定より先に適用されるので、jailbreak や check はこの後に効く。
  fromHackage = pkg: ver: sha256: { self, ... }: {
    custom = _: self.callHackageDirect { inherit pkg ver sha256; } { };
  };
in
{
  settings = {
    # project-m36 は streamly == 0.11.1 を要求する（nixpkgs は 0.10 系）
    streamly = { imports = [ (fromHackage "streamly" "0.11.1" "sha256-4h1MwaN7eXMvzXKyjggIjjR3BlsGzl4vfCO7VBGGvrc=") ]; jailbreak = true; };
    streamly-core = fromHackage "streamly-core" "0.3.1" "sha256-k9h+I74GNsluf55hJFDZiLwEO2x9moFvtCarCeCpaa4=";
    streamly-bytestring.jailbreak = true;

    # project-m36 は curryer-rpc >= 0.5.2（streamly 0.11 対応版）を要求する。
    # Hackage の tarball にテスト用の証明書の設定（test/Curryer/Test/openssl.cnf など）が
    # 入っておらず TLS のテストが通らないので、テストは止める。
    curryer-rpc = { imports = [ (fromHackage "curryer-rpc" "0.5.2" "sha256-t0hjNe+SQSPXVolU/9dbSkBo0pEd58sI/BfF4h31eQw=") ]; check = false; };

    # curryer-rpc 0.5.2 は crypton-x509 >= 1.8（ASN.1 の型が crypton-asn1-types に
    # 移った版）と tls >= 2.1.12 を使う。nixpkgs は x509 1.7 / tls 2.1.8。
    # x509 1.9 と tls 2.3 以降は crypton 1.1 と（broken 扱いの）mlkem を要求して
    # 差し替えがさらに広がるので、crypton 1.0 系のまま組める x509 1.8 と tls 2.2 を使う。
    crypton-x509 = fromHackage "crypton-x509" "1.8.0" "sha256-wxU8Ou52UCuCT2gbxqPKssteIVGUyg5WEbv1xRIyZTg=";
    crypton-x509-store = fromHackage "crypton-x509-store" "1.8.0" "sha256-U6DH5Ke3JXAzZuqxLM6mPKDxqj4HTf5kjoBXaerLOcc=";
    crypton-x509-system = fromHackage "crypton-x509-system" "1.8.0" "sha256-uUNhwQnTPuVd1feZLUZJYKHIk/5v6t7nHpf1jqrMGTQ=";
    crypton-x509-validation = fromHackage "crypton-x509-validation" "1.8.0" "sha256-CyRqTUOcUzzVlQfTd3yylwDVtOaumBbBg9hMyvtcu7c=";
    tls = fromHackage "tls" "2.2.2" "sha256-lbroDPZiOa2YH1jqEzxzNgBGcPZDP6WJEeD0odDgNqs=";

    # winery の依存。nixpkgs では broken 扱い。template-haskell 2.21（GHC 9.8）以降、
    # データ型の型変数の束縛が () から BndrVis に変わった 1 か所を直す
    barbies-th = {
      broken = false;
      jailbreak = true;
      patches = [ ./patches/barbies-th-template-haskell-2.21.patch ];
    };

    # barbies < 2.1 の上限が合わない（nixpkgs は 2.1 系）。ライブラリは通るが、
    # テストの 1 か所が GHC 9.10 のレコード更新の型推論で曖昧になってコンパイルできない
    winery = {
      jailbreak = true;
      check = false;
    };

    # Linux でだけ使う。上限の制約で broken 扱いになっている
    linux-xattr = {
      broken = false;
      jailbreak = true;
    };

    # project-m36 が無条件に依存している。テストは /proc を読むので Linux でしか通らない
    system-linux-proc.check = false;
  };
}
