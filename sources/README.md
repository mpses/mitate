# サイト

1 サイトを 1 つの JS ファイルで表す。ファイル名（拡張子なし）がサイトの id になり、Shot の id の接頭辞になる。`_` で始まるファイルは読み込まない。

アプリに同梱するサイトはこのディレクトリに置く。利用者が足すサイトは `~/Library/Application Support/Mitate/sources/` に置く。同じ id のファイルがあれば、利用者側が優先する。

## 実行環境

サイトの `home` を隠しウィンドウの WebKit で開き、ページのスクリプトから隔離した content world で関数を呼ぶ。

- `fetch` はサイト自身のオリジンから飛び、そのサイトの Cookie が付く。ログインが要るサイトも同じ書き方になる
- DOM はページと共有する。ページの JS 変数（`window.__NEXT_DATA__` のようなグローバル）は見えないので、`<script id="__NEXT_DATA__">` の中身を DOM から読む
- 呼び出しのたびにファイル全体を評価し直す。呼び出しをまたぐ状態は、カーソルにだけ持たせる
- 同じサイトへの呼び出し（`list`、`search`、`login.check`）は 1 つずつ順に行い、前の呼び出しが終わってから `pace` だけ空けて次を始める
- ファイルの最上位で DOM やネットワークに触れない。宣言を読むときは DOM の無い環境で評価する

## 宣言

```js
defineSource({
  name: "Design Spells",
  home: "https://designspells.com/",
  login: null,
  async list(cursor) {
    return { shots, next };
  },
});
```

| 項目     | 内容                                                                                                                                                                       |
| -------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `name`   | 表示名                                                                                                                                                                     |
| `home`   | 実行時に開くページ。API と同じオリジンにする                                                                                                                               |
| `login`  | ログインが要るサイトは `{ url, check }`。`url` はログイン画面、`check()` はログイン済みなら `true` を返す。要らないサイトは `null`                                         |
| `pace`   | 同じサイトへの呼び出しの間隔（ミリ秒）。省くと 1000。前の呼び出しの終わりから数え、差分の取得・live 検索・ログインの確認のすべてに効く。自動取得に厳しいサイトでは長くする |
| `list`   | 全件を列挙できるサイトが持つ。`cursor` を受け、1 ページ分を返す。最初の呼び出しの `cursor` は `null`                                                                       |
| `search` | 全件を写せないサイトが持つ。`(query, cursor)` を受け、検索結果の 1 ページ分を返す                                                                                          |

`list` と `search` の少なくとも一方を持つ。全件を写せるサイトは `list` だけを持ち、検索は手元の索引で行う。

## ページ

`list` と `search` は `{ shots, next, goto }` を返す。

- `shots`：Shot の配列
- `next`：次のページのカーソル。JSON にできる値なら何でもよい。最後のページでは `null`
- `goto`：別のページを開いてから続けたいときの絶対 URL。指定すると実行環境がそのページを開き、`next` を渡して同じ関数をもう一度呼ぶ。DOM を読むしかないサイトで使う

`list` は新しいものから順に返す。アプリは取得のたびに、`next` が `null` になるまで辿る。一度も最後まで取れていないサイトは、前回保存したカーソルから再開する。既に手元にある Shot の詳細ページを取り直さないよう、`mitate.known` で確かめてから省く。

## Shot

```js
{
  id: "magnetic-cursor",
  url: "https://designspells.com/spells/magnetic-cursor",
  origin: undefined,
  kind: "video",
  media: {
    src: "https://…/magnetic-cursor.mp4",
    poster: "https://…/magnetic-cursor.jpg",
    width: 1600,
    height: 1200,
  },
  title: "Magnetic cursor",
  text: undefined,
  tags: ["cursor", "hover"],
  author: "Rauno",
  publishedAt: "2025-04-01T00:00:00.000Z",
}
```

| 項目                    | 規則                                                                                                                       |
| ----------------------- | -------------------------------------------------------------------------------------------------------------------------- |
| `id`                    | サイト内で一意で、何度取っても変わらない値。サイトの id か slug を使い、配列の位置や取得時刻を使わない                     |
| `url`                   | このサイト上のページの絶対 URL                                                                                             |
| `origin`                | 集約サイトが引用している原典（X の投稿、作者のサイトなど）の絶対 URL。分かる時だけ入れる。ビューワーの「原典を開く」で使う |
| `kind`                  | `image`・`video`・`text` のどれか。文章が主役のもの（記事・講義・ツールの説明）だけを `text` にする                        |
| `media.src`             | `image` は長辺 700〜1600px 程度の画像。`video` は mp4、webm、HLS（m3u8）のどれか                                           |
| `media.poster`          | `video` の静止画。あれば必ず入れる                                                                                         |
| `media.width`・`height` | 分かる範囲で入れる。タイルの縦横比に使う                                                                                   |
| `text`                  | `text` の Shot では必須。本文の冒頭か説明文                                                                                |
| `tags`                  | サイトが付けた分類。無ければ空配列                                                                                         |
| `publishedAt`           | ISO 8601                                                                                                                   |

メディアは Cookie なしで取得できる URL にする。アプリのダウンローダーは Referer に `home` を付けるので、Referer を見るサイトでも取れる。

## 補助関数

`mitate` を通して使う。

| 関数                     | 内容                                                                                                                          |
| ------------------------ | ----------------------------------------------------------------------------------------------------------------------------- |
| `mitate.json(url, init)` | fetch して JSON を返す。2xx 以外は例外                                                                                        |
| `mitate.text(url, init)` | fetch して本文を返す。2xx 以外は例外                                                                                          |
| `mitate.doc(url, init)`  | fetch した HTML を `DOMParser` で Document にする                                                                             |
| `mitate.abs(url, base)`  | 相対 URL を絶対 URL にする。`base` の既定は現在のページ                                                                       |
| `mitate.sleep(ms)`       | 待つ                                                                                                                          |
| `mitate.waitFor(fn, ms)` | `fn()` が真になるまで 200ms ごとに確かめる。既定は 15 秒まで                                                                  |
| `mitate.known(ids)`      | サイト内の id（ファイル名の接頭辞なし）の配列を受け、手元の索引にあるかを同じ順の真偽値の配列で返す。`probe` では常に `false` |

## 礼儀

- 1 回の呼び出しで取るのは 1 ページ分だけにする。続きはカーソルで次の呼び出しへ渡す
- 1 回の呼び出しの中で複数のリクエストを送るときは、間に 300ms 以上空ける
- 取得が失敗したら例外を投げる。空の配列を返して成功に見せない

## 検証

```bash
Mitate probe sources/designspells.js
Mitate probe sources/pinterest.js --search "toggle switch"
```

`probe` は宣言を読み、2 ページ分を取り、Shot の形、id の重複、先頭数件のメディアの取得可否を確かめる。終了コード 0 で `PASS` と出れば完成とする。
