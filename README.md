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

既定のホットキーは右 ⌥。修飾キーを押したまま別のキーを押した場合は、ショートカットの一部とみなして録音を捨てる。

## 設定

- **モデル**: Haas ja (既定) / ReazonSpeech v2 / Parakeet ja / Qwen3-ASR 0.6B・1.7B。切り替えると worker を起動し直す
- **語彙・ヒント**: Haas では `表記=読み` を 1 行に 1 つ (例: `Claude=クロード`)。Qwen3-ASR では固有名詞や用語を並べたプロンプト
- **マイク**: システムの既定、または入力デバイスを指定
- **ホットキー**: 右 ⌥ / 右 ⌘ / 右 ⌃ / fn / ⌥Space / ⌃⌥Space / F5
- **出力**: カーソル位置に入力 (クリップボードを元に戻す) / カーソル位置に入力してクリップボードにも残す / クリップボードにコピーのみ

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
