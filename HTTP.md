# HTTP API

アプリは 127.0.0.1 の空いたポートで待ち受け、`~/Library/Application Support/Mitate/server.json`（権限 0600）に `{ port, token, pid }` を書く。ビューワーと MCP はこの API だけを使う。応答の形は `native/Sources/MitateCore/API.swift` が正本で、web 側は `web/src/fixtures` の実データで型を検査する。

## 認証

- すべての要求で `Host` が `127.0.0.1:<port>` か `localhost:<port>` であることを確かめ、違えば 403 を返す
- `/api/` 以下は `Authorization: Bearer <token>` を要る。token は起動のたびに作り直す
- ビューワーはアプリの WKWebView が `window.__MITATE__ = { token }` を注入して受け取る

## 一覧

| 要求                                              | 応答                                                                                                                |
| ------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| `GET /api/sources`                                | `SourcesResponse`                                                                                                   |
| `GET /api/browse?sources=&offset=&limit=`         | `ShotsResponse`。検索語が無いときの壁。新しいものからサイトを交互に並べる                                           |
| `GET /api/search?q=&sources=&kinds=&limit=&live=` | NDJSON の `SearchEvent`。`local` を 1 行、`live=1` のときは `live` と `error` をサイトごとに届いた順、最後に `done` |
| `POST /api/similar?sources=&kinds=&limit=`        | `ShotsResponse`。本文が `{ "id": "<shot id>" }` ならその Shot に、`image/*` なら送った画像に近い順                  |
| `GET /api/shots/<id>`                             | `ShotView`。`text` は省略しない                                                                                     |
| `GET /api/selection`                              | `ShotsResponse`。選んだ順                                                                                           |
| `PUT /api/selection/<id>`                         | 本文 `SelectionUpdate`。応答は更新後の `ShotView`                                                                   |
| `DELETE /api/selection`                           | 204。選択をすべて外す                                                                                               |
| `POST /api/sync?source=`                          | 202。`source` を省くと全サイト                                                                                      |
| `POST /api/login?source=`                         | 202。アプリがそのサイトのログイン画面を開く                                                                         |
| `POST /api/open`                                  | 本文 `{ "url": "…" }`。204。既定のブラウザで開く                                                                    |
| `GET /api/sheet?ids=a,b,c`                        | `image/jpeg`。番号付きのコンタクトシート                                                                            |
| `GET /api/frames/<id>?n=8`                        | `image/jpeg`。動画を等間隔に n 枚並べたもの。`X-Frame-Times` に各フレームの時刻（ms、カンマ区切り）                 |
| `GET /api/view/<id>`                              | `image/jpeg`。長辺 1568px までの元画像                                                                              |
| `GET /media/<key>.jpg`、`/media/icon-<id>.png`    | 手元のサムネイルと favicon。token は要らない                                                                        |
| `GET /`                                           | ビューワー                                                                                                          |

`sources` はカンマ区切りの source id。省くと全サイト。`kinds` は `image`・`video`・`text` のカンマ区切り。省くと全種類。`offset` は 0 以上（既定 0）、`limit` は 1〜500（既定 80）、`frames` の `n` は 1〜16（既定 8）。範囲の外の値と整数でない値には 400 を返す。

## 検索の並び

1. 検索語を FTS5（trigram）と埋め込みの両方で引き、順位を Reciprocal Rank Fusion でまとめる
2. 埋め込みが 0.96 以上近い画像を 1 件にまとめ、`duplicates` に件数を入れる。`origin` は同じ記事の別の画像でも一致するので、重複の判定には使わない
3. 同じサイトが続かないよう、近い順位の中でサイトを交互にする
4. live の結果は手元へ保存し、サムネイルと埋め込みを計算してから、検索語に近い順で流す

## サイトへの問い合わせの上限

live 検索は、呼び出し元（ビューワー、MCP、CLI）に関わらずエンジンが制限する。同じサイトへの問い合わせは 4 秒以上空け、1 分に 6 回までにする。判定は、サイトへの呼び出しの列（次の段落）で順番が来て問い合わせを始める直前に行う。同期の後ろで待っていた検索が、列が空いた途端に続けてサイトへ届くことは無い。上限に達したサイトは `error` を流し、手元の結果だけを返す。同じ検索語の結果は 10 分間、問い合わせずに手元の結果を使う。

これとは別に、サイト用 JS の `pace`（既定 1 秒）が、そのサイトへのすべての呼び出しに効く。live 検索、差分の取得、ログイン状態の確認は同じ列に並び、前の呼び出しが終わってから `pace` だけ空けて次を始める。
