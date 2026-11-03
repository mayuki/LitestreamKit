# Litestream コンテナーバックアップキット

SQLite を使うアプリのコンテナーに [Litestream](https://litestream.io/) を同梱し、起動時の自動復元と継続バックアップを行うための部品一式。バックアップ先は `docker run` 時の環境変数で選ぶ。

- `file`: コンテナーの `/backup` にマウントしたディレクトリ（NAS など）
- `s3`: AWS S3、または Cloudflare R2・Backblaze B2・MinIO などの S3 互換ストレージ
- `none`: 復元も複製もせずにアプリを起動する（開発・テスト用）

何も指定せずに `docker run` すると、`/backup` がないため起動しない。本番でバックアップ先の指定を忘れたまま動き続けることを防ぐための既定値で、複製なしで起動するには `none` を明示する。

Litestream は v0.5.17（Apache-2.0）をイメージダイジェスト固定で使う。

## 構成

| パス | 内容 |
| --- | --- |
| `container/litestream-entrypoint.sh` | 復元・初期DBの取り込み・アプリ起動を行うエントリーポイント |
| `container/litestream/file.yml` | `file` 用の Litestream 設定（`/etc/litestream/file.yml`） |
| `container/litestream/s3.yml` | `s3` 用の Litestream 設定（`/etc/litestream/s3.yml`） |
| `container/LICENSE.litestream` | Litestream のライセンス |
| `LICENSE` | このキットのライセンス（MIT） |
| `Dockerfile` | 公開するキット（`kit` ステージ）と、それを使う組み込み例。例では `example/demo-app.sh`（SQLite に記録し続けるだけのアプリ）を動かす |
| `test/` | エントリーポイントの単体テストとコンテナー結合テスト |
| `.github/workflows/ci.yml` | ShellCheck とテストの実行、およびバージョンタグでのキット公開を行う GitHub Actions のワークフロー |

## 自分のアプリに組み込む

GHCR に公開したキットから、アプリの Dockerfile にファイルをコピーする。

```dockerfile
FROM your-app-runtime
# ...アプリのビルド成果物をコピー...

COPY --from=ghcr.io/mayuki/litestreamkit:1 / /
RUN mkdir -p /data
ENV LITESTREAM_DB_PATH=/data/app.db
ENV LITESTREAM_EXEC="dotnet /app/MyApp.dll"
ENTRYPOINT ["/usr/local/bin/litestream-entrypoint"]
```

キットは `linux/amd64` と `linux/arm64` に対応し、中身は Litestream 本体、エントリーポイント、Litestream の設定、Litestream とこのキットのライセンス（`/usr/share/licenses/` 以下）だけである。タグは次のように使い分ける。

| タグ | 用途 |
| --- | --- |
| `1` | ビルドのたびに `1.x.y` の最新版を使う。キットを更新してもアプリ側の Dockerfile を変更しなくてよい |
| `1.2.3` | 特定のバージョンに固定する。更新時は Dockerfile のタグを変更する |

パッケージが非公開の場合は、アプリのビルド環境でも `docker login ghcr.io` が必要になる（[キットの公開](#キットの公開)）。GHCR を使わない場合は、`container/` と `LICENSE` をアプリのリポジトリにコピーし、`Dockerfile` の `litestream` と `kit` の2つのステージを加えて `COPY --from=kit / /` とする。

- アプリ自身の DB 設定（接続文字列など）を `LITESTREAM_DB_PATH` と同じ絶対パスに向ける。エントリーポイントはアプリの設定を書き換えない。
- アプリは SQLite を WAL モードで使う。
- ランタイムイメージには `/bin/sh` と基本的なコマンド（`awk`・`mktemp` など）が必要。`s3` で HTTPS エンドポイントを使う場合は CA 証明書（Debian 系なら `ca-certificates`）も必要。`mcr.microsoft.com/dotnet/aspnet` などは最初から含む。
- `/data` はコンテナーの書き込み層（ローカルディスク）に置く。NFS 上に置かない。永続化はバックアップ先が担い、コンテナー再作成時は起動時に復元される。

## 環境変数

### 共通

| 環境変数 | 既定値 | 用途 |
| --- | --- | --- |
| `LITESTREAM_DB_PATH` | （必須） | アプリと Litestream が使う DB の絶対パス |
| `LITESTREAM_EXEC` | （必須） | Litestream が起動するアプリのコマンド |
| `LITESTREAM_REPLICA_TYPE` | `file` | バックアップ先。`file`・`s3`、または複製しない `none` |
| `LITESTREAM_ALLOW_INITIALIZE` | `false` | バックアップのない新規 DB の作成を許可する。初回デプロイだけ `true` |
| `LITESTREAM_SYNC_INTERVAL` | `10s` | バックアップ先への転送間隔 |
| `LITESTREAM_SNAPSHOT_INTERVAL` | `24h` | フルスナップショットの間隔 |
| `LITESTREAM_SNAPSHOT_RETENTION` | `168h` | 保持期間（7日） |
| `LITESTREAM_CONFIG_PATH` | `/etc/litestream/<type>.yml` | 独自の Litestream 設定を使う場合に指定する |

### `s3` 用

| 環境変数 | 既定値 | 用途 |
| --- | --- | --- |
| `LITESTREAM_S3_BUCKET` | （必須） | バケット名 |
| `LITESTREAM_S3_PATH` | （必須） | バケット内のキープレフィックス。DB ごとに専用にする（例: `myapp/db`） |
| `LITESTREAM_S3_ENDPOINT` | 空（AWS S3） | S3 互換サービスのエンドポイント URL |
| `LITESTREAM_S3_REGION` | 空 | リージョン。空の場合、AWS ではバケットから検出し、エンドポイント指定時は `us-east-1` |
| `LITESTREAM_S3_FORCE_PATH_STYLE` | 空 | `true`/`false`。空の場合はエンドポイント指定時にパス形式になる |
| `LITESTREAM_S3_SKIP_VERIFY` | 空（検証する） | `true` で TLS 証明書を検証しない。自己署名の検証環境以外では使わない |
| `LITESTREAM_ACCESS_KEY_ID` | | アクセスキー ID。`AWS_ACCESS_KEY_ID` でもよい |
| `LITESTREAM_SECRET_ACCESS_KEY` | | シークレットアクセスキー。`AWS_SECRET_ACCESS_KEY` でもよい |

認証情報は Litestream（AWS SDK）が環境変数から直接読むため、設定ファイルには展開しない。指定しない場合は IAM ロールなど AWS SDK の既定の認証情報を使う。Cloudflare R2・Backblaze B2・MinIO などはエンドポイントから Litestream が判別し、必要な既定値を適用する。

## 実行例

### ディレクトリ（NAS）にバックアップする

```sh
docker run -d --name myapp --restart unless-stopped --stop-timeout 60 \
  --mount type=bind,src=/mnt/nas/backups/myapp,dst=/backup \
  myapp:latest
```

`/backup` にはアプリ専用のディレクトリをマウントする。マウント漏れ・読み取り専用の場合は起動しない。

### AWS S3 にバックアップする

```sh
docker run -d --name myapp --restart unless-stopped --stop-timeout 60 \
  -e LITESTREAM_REPLICA_TYPE=s3 \
  -e LITESTREAM_S3_BUCKET=my-backups \
  -e LITESTREAM_S3_PATH=myapp/db \
  --env-file ./litestream-s3.env \
  myapp:latest
```

`litestream-s3.env`（リポジトリにコミットしない）:

```sh
LITESTREAM_ACCESS_KEY_ID=AKIA...
LITESTREAM_SECRET_ACCESS_KEY=...
```

### S3 互換ストレージにバックアップする

Cloudflare R2 の例。`LITESTREAM_S3_ENDPOINT` を追加するだけで、他は AWS S3 と同じ。

```sh
docker run -d --name myapp --restart unless-stopped --stop-timeout 60 \
  -e LITESTREAM_REPLICA_TYPE=s3 \
  -e LITESTREAM_S3_BUCKET=my-backups \
  -e LITESTREAM_S3_PATH=myapp/db \
  -e LITESTREAM_S3_ENDPOINT=https://<ACCOUNT_ID>.r2.cloudflarestorage.com \
  -e LITESTREAM_S3_REGION=auto \
  --env-file ./litestream-s3.env \
  myapp:latest
```

自前の S3 互換サーバー（MinIO・Garage・VersityGW など）を HTTP で使う場合は `LITESTREAM_S3_ENDPOINT=http://s3.internal:9000` のように指定する。パス形式は自動で選ばれる。

### 初回デプロイ

バックアップがまだない状態で空の DB から始める初回だけ、`-e LITESTREAM_ALLOW_INITIALIZE=true` を追加する。バックアップの作成を確認したら、この指定を外してコンテナーを作り直す。

### 開発・テスト環境で起動する

```sh
docker run --rm -p 8080:8080 -e LITESTREAM_REPLICA_TYPE=none myapp:latest
```

Litestream を使わず、`LITESTREAM_EXEC` のアプリをそのまま起動する。DB はコンテナーの書き込み層に作られ、コンテナーを削除すると消える。起動時に警告をログに出す。CI の結合テストのように、毎回空の DB から始めたい場合にも使える。compose の開発用設定などに書いておくとよい。本番の設定には書かない。

`none` ではシェルが `LITESTREAM_EXEC` を解釈する（Litestream の `-exec` と違い、`$VAR` なども展開される）。アプリはシェルを介さず PID 1 として起動し、停止シグナルを直接受け取る。

バックアップの動作も含めて試したい場合は、`none` の代わりに `--mount type=volume,src=myapp-dev-backup,dst=/backup -e LITESTREAM_ALLOW_INITIALIZE=true` を指定する。バックアップがあればそこから復元されるので、開発用なら初期化の許可を付けたままでもよい。

## 起動時の動作

1. 環境変数を検証する。`file` では `/backup` がマウントされ書き込めることを確認する。
2. 非空のローカル DB があればそれを使う（`docker restart` など）。空ファイルや、DB のない孤立した `-wal` などはエラーにする。
3. DB がなければバックアップ先から復元し、SQLite の `quick_check` を行う。
4. バックアップがなく初期 DB ファイルがあれば取り込む（後述）。
5. 復元・取り込みに成功してから DB を `LITESTREAM_DB_PATH` に移す。失敗・中断時の部分的なファイルは次回の起動で使われない。
6. `litestream replicate -exec` でアプリを起動し、継続バックアップを行う。

`LITESTREAM_REPLICA_TYPE=none` の場合は、共通の環境変数（`LITESTREAM_DB_PATH`・`LITESTREAM_EXEC` など）だけを検証し、`/backup` の確認や復元を行わずにアプリを直接起動する。

バックアップも初期 DB もない場合、既定では起動しない。`LITESTREAM_ALLOW_INITIALIZE=true` でも、許すのは「バックアップが1つもない」場合だけで、認証エラー・バケット不在・通信エラー・破損したバックアップでは起動しない。設定ミスで空の DB から始まり、既存のバックアップを上書きすることを防ぐ。

## 既存の DB を引き継ぐ

既存の書き込み元を停止して整合した単一の SQLite ファイルを用意し（または SQLite のバックアップ機能で作成し）、`LITESTREAM_DB_PATH` と同じファイル名で次の場所に置いて起動する。

| バックアップ先 | 置き場所 |
| --- | --- |
| `file` | `/backup/<DBファイル名>`（ホストのバックアップディレクトリ） |
| `s3` | `/import/<DBファイル名>`（任意のディレクトリを書き込み可能で `/import` にマウント） |

```sh
cp ./app.db /srv/myapp-import/app.db

docker run -d --name myapp --restart unless-stopped --stop-timeout 60 \
  -e LITESTREAM_REPLICA_TYPE=s3 -e LITESTREAM_S3_BUCKET=my-backups -e LITESTREAM_S3_PATH=myapp/db \
  --env-file ./litestream-s3.env \
  --mount type=bind,src=/srv/myapp-import,dst=/import \
  myapp:latest
```

取り込みはローカルのコピーで検証し、バックアップ先へのバックアップに成功してからアプリを起動する。成功後、元のファイルは `<DBファイル名>.imported` に名前を変えて残り、以後の起動では使われない。バックアップ先にすでにバックアップがある場合はそちらを優先し、初期 DB は取り込まない。`-wal`・`-shm`・`-journal` が同じ場所にある場合は整合性を確認できないため拒否する。2回目以降の起動では `/import` のマウントは不要。

## 運用上の注意

- 1つのバックアップ先（`/backup` のディレクトリ、または S3 のバケットとパスの組）に対して、稼働するコンテナーは1つにする。更新時は旧コンテナーを停止してから新しいものを起動する。
- `--stop-timeout 60` で Litestream の停止時同期（最大30秒）を待つ。強制終了・削除した場合は、最後の転送以降の更新が失われる可能性がある。
- Litestream は起動後の最初の監視（約1秒後）で DB を開くまで、停止時の最終同期を行わない。起動直後に停止してコンテナーを削除すると、その間の更新は失われる。コンテナーを残したままの再起動ではローカル DB が使われるため問題ない。
- 失われる可能性があるのは最後に転送が成功してからの更新であり、`LITESTREAM_SYNC_INTERVAL` はデータ損失時間の保証ではない。S3 では転送間隔を短くするとリクエスト数（料金）が増える。
- `file` で NAS のマウントがホスト上で外れると、コンテナー内からは空のディレクトリと区別できないことがある。通常起動では初期化を許可しないことに加え、ホスト側のマウントも確認する。
- 認証情報はイメージに含めず、`--env-file` やオーケストレーターのシークレットで渡す。S3 のアクセスキーは対象バケット（とプレフィックス）に限定した権限にする。

## 復元の確認

アプリの稼働 DB とは別の出力先に復元し、読めることを定期的に確認する。

```sh
# file
litestream restore -integrity-check quick -o /tmp/restored.db file:///mnt/nas/backups/myapp

# s3 / S3 互換（認証情報は LITESTREAM_ACCESS_KEY_ID / LITESTREAM_SECRET_ACCESS_KEY で渡す）
litestream restore -integrity-check quick -o /tmp/restored.db \
  "s3://my-backups/myapp/db?endpoint=https://<ACCOUNT_ID>.r2.cloudflarestorage.com&region=auto"
```

## 独自の Litestream 設定を使う

`LITESTREAM_CONFIG_PATH` に設定ファイルを指定すると、同梱の設定と `s3` 用の環境変数の検証を使わない。`LITESTREAM_REPLICA_TYPE` は `/backup` の検証と初期 DB の置き場所の選択に引き続き使われる。独自の設定でも DB のパスは `${LITESTREAM_DB_PATH}` で参照する（初期 DB の取り込み時に、同じ設定を検証済みのコピーに向けてバックアップするため）。Litestream v0.5 では DB ごとにバックアップ先は1つで、`file` と `s3` の同時利用はできない。

## 検証

Docker Engine と PowerShell 7 で実行する。テストは専用のコンテナー・ボリューム・ネットワークを作り、最後に削除する。S3 互換サーバーとして VersityGW を使う。

```powershell
docker build -t litestream-kit:test .
pwsh -File test/Test-Litestream.ps1
```

`file` と `s3` のそれぞれで、初回デプロイ、稼働中の継続バックアップ、コンテナー強制削除後の自動復元、正常停止時の最終同期を確認する。加えて、マウント漏れ・読み取り専用、バックアップ欠落・破損、S3 の認証エラーやバケット不在で起動しないこと、`/import` からの初期 DB 取り込み、`none` でバックアップ先なしに起動・正常停止できることを確認する。起動ポリシーの細かな分岐は `test/entrypoint-tests.sh` が偽の `litestream` コマンドで検証する。

GitHub Actions では、`main` へのプッシュとプルリクエストのたびに、ShellCheck のあとで同じ手順を実行する。

## キットの公開

`vX.Y.Z` 形式のタグをプッシュすると、テストに合格した場合だけ `Dockerfile` の `kit` ステージを `ghcr.io/mayuki/litestreamkit` に公開する。

```bash
git tag v1.2.3
```

```bash
git push origin v1.2.3
```

`v1.2.3` なら `1.2.3`・`1.2`・`1` の3つのタグを更新する。`v1.2.3-rc.1` のようなプレリリースは `1.2.3-rc.1` だけを公開する。`latest` タグは作らない。

GitHub のパッケージは、最初の公開時点では非公開である。誰でも使えるようにするには、パッケージの設定にある「Change visibility」で公開に変更する。一度公開すると非公開には戻せない。

参考: [Litestream の Docker 構成](https://litestream.io/guides/docker/)、[設定リファレンス](https://litestream.io/reference/config/)、[復元コマンド](https://litestream.io/reference/restore/)。
