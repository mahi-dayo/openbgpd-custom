# OpenBGPD 検証ビルド

Pending Prefixの生成を抑制するパッチと、Ubuntuで `bgpd` の既定のアロケーターをjemallocにするビルド設定を管理します。上流のソースを版ごとに取得し、差分を適用して各RS VMでビルドします。

| RS | ソース | 既定のアロケーター |
| --- | --- | --- |
| Ubuntu | OpenBGPD Portableの正式リリース | jemallocを `bgpd` にリンク |
| OpenBSD | プロファイルで固定したnative版のコミット | OpenBSD標準 |

既定のPending抑制開始値は **2,000万件** です。受信や送出を続けながらPendingの生成を待たせます。実行中の初期ダンプは完了まで進めるため、一時的にこの件数を超える場合があります。パッチの動作確認対象はIPv4/IPv6 unicastです。

## Ubuntuでビルドする

必要なパッケージを導入し、既存のRS環境に権限分離用アカウント `_openbgpd` があることを確認します。

```bash
sudo apt install git build-essential autoconf automake binutils bison curl pkg-config \
  libevent-dev libmnl-dev libssl-dev libtool signify-openbsd zlib1g-dev \
  libjemalloc-dev
getent passwd _openbgpd
```

クローンしたリポジトリのルートで実行します。インストール先には新しいディレクトリを指定してください。

```bash
prefix="$HOME/opt/openbgpd-9.3-pending-cap-jemalloc"
bash scripts/build-release.sh 9.3 --prefix "$prefix"
env -u LD_PRELOAD "$prefix/sbin/bgpd" -V
readelf -d "$prefix/sbin/bgpd" | grep NEEDED
```

公式配布元からソースを取得し、同梱の公式公開鍵で署名を検証します。ビルド中にパッチ適用、`make check`、実際のRDEコードを使うテストを行います。ビルド先の `BUILD-METADATA.txt` にはソース、適用した差分、アロケーター、実行ファイルの情報を記録します。リンク結果は `libjemalloc` が依存先にあることと、`LD_PRELOAD` を解除しても `malloc()` と `free()` がjemallocに解決されることを確認します。 [OpenBGPD公式配布・署名鍵](https://www.openbgpd.org/ftp.html)

### 既存の検証ランチャーで起動する

```bash
OPENBGPD_CUSTOM_PREFIX="$prefix" \
RS_TEST_CONFIG="$PWD/config/ubuntu.env.example" \
  "$HOME/openbgpd-rs-lab/openbgpd-test.sh"
```

メニューで **OpenBGPD → Portable 9.3 → jemalloc** を選択します。現行ランチャーの `Default` は標準アロケーター用の検証条件です。ランチャーがjemallocを選択するのは既存の実測・照合手順に合わせるためです。リンク済みの `bgpd` 自体は `LD_PRELOAD` の指定なしで起動できます。新しいPortable版を指定した場合も、現行ランチャーの選択肢名は `Portable 9.3` と表示されるので、実行ファイルのパスとビルド記録で対象を確認してください。

## OpenBSDでビルドする

native 9.3向けのプロファイルはOpenBSD 7.9と8.xを対象にしています。既存の `_bgpd` アカウント、ベースのコンパイラとビルドツール、`bash` と `git` パッケージが必要です。

```bash
prefix="$HOME/opt/openbgpd-native-9.3-pending-cap"
bash openbsd/build-openbgpd-native.sh --version 9.3 --prefix "$prefix"
"$prefix/sbin/bgpd" -V
```

native版は固定したコミットとアーカイブのチェックサムを使い、Portable版と同じPending Prefixパッチをnative側のパスに読み替えて適用します。`--archive` で検証済みのアーカイブを指定することもできます。ビルドだけではシステムの実行ファイルやサービスに触れません。

既存の検証ランチャーに組み込む場合は次のように起動し、**OpenBGPD → native 9.3** を選択します。実験中の切り替えと終了時の復元は既存ランチャーが行います。

```bash
OPENBGPD_CUSTOM_PREFIX="$prefix" \
RS_TEST_CONFIG="$PWD/config/openbsd.env.example" \
  "$HOME/openbgpd-rs-lab/openbgpd-test.sh"
```

## OpenBGPDのバージョンを上げる

### Ubuntu

1. 新しい正式版の番号を明示して取得し、対象のRDEコードで走査・送出・終了コールバックの意味を確認します。
2. 元ソースをリポジトリの外に置き、同じ差分を適用できるかチェックします。
3. `--allow-new-version` を付けて専用の場所にビルドします。差分が合わなければ停止します。

```bash
version='実際の正式版番号'
work="$HOME/src/openbgpd-release-$version"
source_dir="$work/openbgpd-$version"

bash scripts/fetch-release.sh "$version" "$work" &&
bash scripts/apply-patch.sh --check --allow-new-version "$source_dir" &&
bash scripts/build.sh --allow-new-version --require-signed-source \
  --source "$source_dir" \
  --prefix "$HOME/opt/openbgpd-$version-pending-cap-jemalloc"
```

Pending Prefixの差分が合わない版では、内容を見直して `patches/<版>/pending-backpressure.patch` を用意します。Ubuntu用のjemallocリンク差分も必要な版に限り `patches/<版>/ubuntu-jemalloc-link.patch` を用意します。差分の適用チェックは、BGPの動作と性能を確認する試験とは別に行います。

### OpenBSD

`openbsd/profiles/<版>/native.conf` に、新しいnativeコミット、アーカイブのチェックサムと対象OSを登録します。既存の9.3用プロファイルを参考に、起動時の互換差分とimsgの取り扱いもその版で確認します。既存のRSランチャー側は9.3を固定しているので、新版を実験メニューで使う場合はランチャーの版・コミットの照合も合わせて更新します。

## 比較試験と配布

Ubuntuで比較する場合は、同じ上流版と同じjemallocで、Pending Prefixの差分だけを外した版をビルドできます。

```bash
bash scripts/build-release.sh 9.3 --no-pending-cap \
  --prefix "$HOME/opt/openbgpd-9.3-stock-jemalloc"
```

パッチ版と比較版で、同じクライアント、経路数、安定確認時間を使います。期待したBGPセッションと経路数が揃い、Pendingがゼロになり、収束時間を延ばさずピークRSSを減らせることを確認してから採用します。従来の性能比較は起動時にjemallocを指定したPortable 9.3の測定です。リンク方式を変更したビルドの測定結果とは区別します。

各VMで同じビルド手順を再現するには、Gitでコミットを揃えます。登録先を用意したら、リポジトリのルートで次を実行します。

```bash
git remote add origin "$REPO_URL"
git push -u origin HEAD
```

VMでは `git clone "$REPO_URL"` で取得し、`git checkout --detach "$COMMIT"` で使うコミットを固定します。`REPO_URL` と `COMMIT` には実際の値を指定します。実機試験まで完了した組み合わせはタグを付け、上流の版とビルド記録を残すと再検証に使えます。上流ソース一式、生成された実行ファイル、検証ログ、VM固有の設定は作業場所に保管します。

Gitサーバーを使わずに配布する場合は、`git bundle create ../openbgpd-custom.bundle --all` で作成したファイルをVMへコピーし、`git clone openbgpd-custom.bundle` で取得できます。
