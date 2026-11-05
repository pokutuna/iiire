# iiire

[speech.cpp](https://github.com/nyosegawa/speech.cpp) で書き起こす、自分用の音声入力アプリ (macOS 14 以降、Apple silicon)。
メニューバーに常駐し、ホットキーで録音して、書き起こした文字列をカーソル位置に入力する。

## インストール

Xcode か Command Line Tools (Swift 5.10 以降) と cmake (`brew install cmake`) が要る。

```sh
git clone --recurse-submodules <このリポジトリ>
make signing-identity   # 初回のみ
make install            # ~/Applications/iiire.app に入れる
```

`make signing-identity` は署名用の自己署名証明書を作る。アドホック署名だと、ビルドし直すたびにアクセシビリティの許可が外れるため。

## 使い方

| 操作 | 動作 |
|---|---|
| ホットキーを短く押す | 録音を開始し、もう一度押すと書き起こす |
| ホットキーを長押し | 押している間だけ録音し、離すと書き起こす |
| Esc | 録音や書き起こしを取り消す |

- 既定のホットキーは右 ⌥。ホットキー、マイク、モデル、出力の方法は設定画面で変えられる
- モデルは初めて使うときに Hugging Face からダウンロードし、`~/Library/Caches/speech.cpp` に置く
- マイクとアクセシビリティの許可が要る。ペーストを AppleScript で送る設定では、System Events の制御の許可も要る
- エラーの詳細は `~/Library/Logs/iiire.log` に書く。書き起こした文章は書かない

## 開発

| コマンド | 動作 |
|---|---|
| `make run` | ビルドして起動する |
| `make test` | テストを実行する |
| `make clean` | アプリと Swift のビルドを消す (`make distclean` は speech.cpp のビルドも消す) |

- speech.cpp は submodule (`vendor/speech.cpp`) で版を固定し、`speech` コマンドをアプリに同梱する。版を上げるときは、`vendor/speech.cpp` で目的の版を checkout してから `git submodule update --init --recursive` を実行する
- 画面の文字列はソースに英語で書き、日本語訳を `Resources/ja.lproj` に置く
- アプリのアイコンは、ビルドのときに `Resources/AppIcon.svg` から作る。メニューバーのアイコンは同じ形を `MenuBarGlyph.swift` で描く
- デバッグビルド (`swift build`) は、書き起こした文章もログに書く

マイクを使わずに音声ファイルを書き起こしたり、画面を PNG に書き出したりできる。

```sh
APP=build/iiire.app/Contents/MacOS/iiire
$APP --transcribe /tmp/t.wav [MODEL]
$APP --snapshot-settings /tmp/shots   # 設定画面の各タブ
$APP --snapshot-hud /tmp/shots        # HUD の各表示
```
