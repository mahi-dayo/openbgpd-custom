# OpenBGPD検証ビルド（Ubuntu）

OpenBGPD PortableにPending Prefixの抑制を加え、`bgpd` にjemallocをリンクします。抑制開始値は2,000万件です。処理中の初期ダンプは続行するため、一時的にこの件数を超えることがあります。

## 初回の準備

Ubuntu RSで実行します。既存のRS環境には権限分離用の `_openbgpd` アカウントが必要です。

```bash
sudo apt install git build-essential autoconf automake binutils bison curl \
  pkg-config libevent-dev libmnl-dev libssl-dev libtool signify-openbsd \
  zlib1g-dev libjemalloc-dev

git clone https://github.com/mahi-dayo/openbgpd-custom.git
cd openbgpd-custom
```

すでにクローン済みなら、そのディレクトリで `git pull --ff-only` を実行します。

## ビルドと検証

```bash
bash build.sh 9.3
bash build.sh 9.3 --lab
```

1行目で署名を確認した公式ソースをビルドし、`~/opt/openbgpd-9.3-pending-jemalloc` に配置します。ビルド中にパッチのテストと、`LD_PRELOAD` を解除した状態でのjemallocの使用を確認します。既存のビルド先は上書きしません。別の場所に作る場合は `--prefix "$HOME/opt/openbgpd-test"` を指定します。

2行目で既存の検証ランチャーを起動します。メニューで **OpenBGPD → Portable 9.3 → jemalloc** を選びます。ランチャーの表示名は固定なので、他の版ではビルド記録で実際の版を確認してください。

## 別のバージョンを試す

```bash
version='試したい正式版の番号'
bash build.sh "$version"
```

ビルド前に署名とパッチの適用可否を確認します。確認だけなら `bash build.sh "$version" --check` を使います。差分が合わない版では、上流の変更を確認して `pending-backpressure-<版番号>.patch` を用意します。保存済みの公式ソースと対応する署名がある場合は `--archive FILE --signature FILE` を指定できます。 [OpenBGPD公式配布・署名鍵](https://www.openbgpd.org/ftp.html)

9.0・9.1・9.2・9.3でUbuntu上のビルド、RDEのテスト、jemallocの使用を確認しました。8.9では共通パッチの適用チェックで停止します。負荷試験では同じ版・同じjemallocで経路数・収束時間・ピークRSSを比較します。比較用は `bash build.sh "$version" --no-pending-cap` でビルドし、`--no-pending-cap --lab` で起動できます。
