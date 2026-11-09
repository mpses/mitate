# Mitate

## 概要

Mitate は、デザインの参考サイトを横断して検索する Mac アプリです。Pinterest、X、Detail、Design Spells、Recent、Collect UI などの情報を手元に索引し、文章や画像の近さから参考を探せます。索引と埋め込みの計算は Mac 内で行い、サイトからの取得やモデルのダウンロードにはネットワークを使います。

このリポジトリは、非公開の monorepo から `apps/mitate` を切り出したソースのスナップショットです。このままでは単独でビルドできません。

## できること

- 言葉で検索し、画像・動画・文章やサイトで絞り込む
- 保存済みの参考や手元の画像に、見た目が近い参考を探す
- ビューワーで参考を選び、メモとともにエージェントへ渡す
- タイルをほかのアプリへドラッグして、ファイルとして渡す。画像は保存済みのサムネイル、動画はポスター画像、文章は Markdown になる
- CLI と MCP から検索や索引の状態確認を行う

実行ファイルは SwiftPM で作る `Mitate` の1本です。引数なしで GUI を開き、`mcp` で標準入出力の MCP サーバーになります。CLI には `search`、`similar`、`selection`、`sync`、`status` があり、開発用に `probe`、`shoot`、`dragcheck`、`fixtures` があります。

MCP は `search`、`view`、`similar`、`selection`、`sources` を提供します。使い方は [エージェント向け skill](skill/SKILL.md) に記載しています。

## 仕組み

サイトごとの JavaScript を、隠し WKWebView の隔離された content world で実行します。ページと DOM を共有しますが、ページの JavaScript 変数には直接アクセスしません。ログインが必要なサイトでは、その WebKit の Cookie を使います。

検索では SQLite FTS5 の trigram による全文検索と、埋め込みによる検索の順位を RRF（Reciprocal Rank Fusion）で統合します。埋め込みには SigLIP 2 と ONNX Runtime を使います。[models.json](models.json) に取得元の固定 commit とファイルのハッシュを記録し、[scripts/models.mjs](scripts/models.mjs) が Hugging Face から取得して SHA-256 を照合します。

ビューワーは React と Panda CSS で実装しています。ネイティブ側が `127.0.0.1` で HTTP API を提供し、ビューワーと MCP が利用します。通信の契約は [HTTP.md](HTTP.md) に記載しています。

## 構成

| パス | 内容 |
| --- | --- |
| `native/` | SwiftPM の実行ファイル、取得・索引・検索・HTTP API・MCP の実装とテスト |
| `sources/` | サイトごとの取得処理と、その契約 |
| `web/` | React と Panda CSS によるビューワー |
| `skill/SKILL.md` | エージェント向けの利用手順 |
| `models.json` | 埋め込みモデルの取得元と検証値 |
| `scripts/models.mjs` | モデルの取得と検証 |
| `scripts/install.mjs` | ビルド、アプリの配置、CLI・skill・MCP の登録 |
| `HTTP.md` | ネイティブ側の HTTP API の仕様 |

## 動作環境

- macOS 15 以降（`native/Package.swift` の指定）
- Xcode と SwiftPM（Swift tools version は 6.0）
- Node.js と pnpm
- インストーラーによる MCP 登録には Claude Code と Codex の CLI、および既存の skill 配置先

インストーラーは `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` を設定して Xcode のツールチェーンを使います。コード内のコメントでは、Command Line Tools の Swift で modulemap が重複する問題を避けるためと説明されています。Node.js と pnpm の最低バージョンは、このスナップショットでは指定していません。

## ビルドとインストール

単独ビルドに必要な依存関係と設定は、このリポジトリだけでは揃いません。

- `tsconfig.json` が、同梱されていない `../../tsconfig.base.json` を継承する
- `package.json` の `@bakutan-org/ui` と `@bakutan-org/design-tokens` が `workspace:*` を参照する。両パッケージは非公開の GitHub Packages 向けに公開設定されており、このスナップショットには含まれない
- `scripts/install.mjs` が、アプリの2階層上を monorepo の根として `pnpm --filter @bakutan-org/mitate build` を実行する

元の monorepo の設定と依存パッケージを用意できる環境では、`scripts/install.mjs` がビューワーと Swift のリリースビルドを行い、リソースをまとめて `.app` を作ります。その後、モデルを取得し、`~/Applications/Mitate.app` へ配置して、`~/.local/bin/mitate`、skill、Claude Code と Codex の MCP を登録します。

インストーラーは既存のアプリを停止して置き換え、同名の CLI・skill・MCP 登録も更新します。このスナップショットには、独立したリポジトリ向けに調整済みのインストール手順はありません。

## サイトの追加

取得処理は `sources/<id>.js` として定義します。`defineSource` でサイト情報を宣言し、`list` または `search` から1ページ分の参考と次のカーソルを返します。

利用者が追加するファイルは `~/Library/Application Support/Mitate/sources/` に置きます。同じ id があれば、アプリ同梱のファイルより優先されます。返却する Shot の形式、取得間隔、ログイン、検証用の `probe` については [sources/README.md](sources/README.md) を参照してください。

## 規約上の注意

Pinterest と X は利用規約で自動取得を禁じています。そのため、実装では次のように間隔と回数を絞っています。

- Pinterest と X はともに `pace: 4000` を指定し、同じサイトの前の呼び出しが終わってから4秒空ける
- ネイティブ側の live 検索は、サイトごとに問い合わせを4秒以上空け、直近60秒で6回までに制限する
- 同じサイト・検索語の結果は600秒間再利用する。検索語の大文字小文字と空白の違いは同一とみなす
- Pinterest の検索は1ページ50件を要求する。通常の live 検索では次ページを追わない
- X は検索画面に描画された内容を読み、最大4回スクロールし、最大40件を返す

繰り返し検索するときは MCP の `live: false` で手元の索引を使えます。取得間隔や回数の制限は、規約上の許可を意味しません。

aiverse は利用規約で scrape・mirror・cache を禁じているため、取得処理を持ちません。各サイトの規約は変わることがあるので、使う前に現行の規約を確かめてください。
