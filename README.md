# Koe

[speech.cpp](https://github.com/nyosegawa/speech.cpp) で書き起こす、自分用の小さな音声入力アプリ (macOS, Apple silicon)。
メニューバーに常駐し、ホットキーで録音して、書き起こした文字列をカーソル位置に入力する。

## ビルド

```sh
scripts/create-signing-identity.sh   # 初回のみ
scripts/build-app.sh            # speech.cpp を ~/ghq/github.com/nyosegawa/speech.cpp からビルドして同梱する
open build/Koe.app
```

- speech.cpp は `-DGGML_OPENMP=OFF` でビルドし、`Koe.app/Contents/MacOS/speech` に同梱する。作り直すときは `REBUILD_SPEECH=1` を付ける
- モデルは初回に `speech` が Hugging Face から取得し、`~/Library/Caches/speech.cpp` に置く
- 署名には `scripts/create-signing-identity.sh` で作る自己署名証明書「Koe Local Signing」を使う。アドホック署名だと許可がビルドのハッシュ値に紐づき、ビルドし直すたびにアクセシビリティの許可が外れるため

## 使い方

| 操作 | 動作 |
|---|---|
| ホットキーを短く押す | 録音を開始。もう一度押すと止めて書き起こす |
| ホットキーを長押し | 押している間だけ録音し、離すと書き起こす |
| Esc | 録音・書き起こしを取り消す |

既定のホットキーは右 ⌥。修飾キー単独のホットキーで、押したまま別のキーを押した場合は、ショートカットの一部とみなして録音を捨てる。

## 設定

- **モデル**: Haas ja (既定) / ReazonSpeech v2 / Parakeet ja / Qwen3-ASR 0.6B・1.7B。切り替えると worker を起動し直す
- **語彙・ヒント**: Haas では `表記=読み` を 1 行に 1 つ (例: `Claude=クロード`)。Qwen3-ASR では固有名詞や用語を並べたプロンプト
- **マイク**: システムの既定、または入力デバイスを指定
- **ホットキー**: 「変更…」を押してから、登録したいキーを実際に押す。押している間はその場で表示される
  - 修飾キー単独 (左右を区別。例: 右 ⌥、左 ⌘、fn)
  - ⌃ ⌥ ⇧ ⌘ とキーの組み合わせ (例: ⌃⌥Space)。他のアプリが使っている組み合わせは登録できない
  - F キーは単独でも可
- **効果音**: 録音の開始と終了で音を鳴らす。既定はオンで、開始音 Tink、終了音 Pop。音は `~/Library/Sounds`、`/Library/Sounds`、`/System/Library/Sounds` にあるものから選べ、選ぶと試聴できる。開始音がマイクに入らないよう、録音の先頭の最大 0.2 秒を捨てる
- **出力**: カーソル位置に入力 (クリップボードを元に戻す) / カーソル位置に入力してクリップボードにも残す / クリップボードにコピーのみ

## 表示言語

英語と日本語に対応し、macOS の言語設定に従う。アプリごとの言語は「システム設定 > 一般 > 言語と地域 > アプリケーション」で変えられる。

- 画面の文字列はソースに英語で書き、日本語訳は `Resources/ja.lproj/Localizable.strings` に置く。キーは英語の文字列そのもの
- マイク許可ダイアログの説明文の日本語訳は `Resources/ja.lproj/InfoPlist.strings`
- 一時的に言語を変えて起動する: `build/Koe.app/Contents/MacOS/Koe -AppleLanguages '(en)'`

## しくみ

- `speech worker MODEL` を子プロセスとして起動したままにし、[JSON Lines のプロトコル](https://github.com/nyosegawa/speech.cpp/blob/main/docs/worker.md)で録音を渡す
- 録音は止めたあとにまとめて送る。モデルが読み込み中でも録音はでき、準備ができてから書き起こす
- 入力はクリップボードに文字列を置き、⌘V を送ってペーストする (VoiceInk と同じ方式)

## 動作確認

マイクなしで、音声ファイルを同じ経路で書き起こせる。

```sh
say -v Kyoko "音声入力のテストです。" -o /tmp/t.aiff && afconvert -f WAVE -d LEI16@48000 /tmp/t.aiff /tmp/t.wav
build/Koe.app/Contents/MacOS/Koe --transcribe /tmp/t.wav [MODEL]
```

ショートカットの記録の判定は `swift test` で確かめる。
