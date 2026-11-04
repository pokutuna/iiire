# Koe

[speech.cpp](https://github.com/nyosegawa/speech.cpp) で書き起こす、自分用の小さな音声入力アプリ (macOS, Apple silicon)。
メニューバーに常駐し、ホットキーで録音して、書き起こした文字列をカーソル位置に入力する。

## ビルド

macOS 14 以降、Apple silicon。Xcode か Command Line Tools (Swift 5.10 以降) と cmake (`brew install cmake`) が要る。

```sh
git clone --recurse-submodules <このリポジトリ>
make signing-identity   # 初回のみ
make run                # ビルドして起動する
```

| make | 動作 |
|---|---|
| `make` / `make app` | speech.cpp と Koe をビルドし、`build/Koe.app` を作る |
| `make run` | ビルドして起動する |
| `make install` | `~/Applications/Koe.app` に入れる (`INSTALL_DIR=/Applications` で変えられる)。起動中の Koe は終了する |
| `make test` | `swift test` |
| `make signing-identity` | 署名用の自己署名証明書を作る (初回のみ) |
| `make clean` | `Koe.app` と Swift のビルドを消す |
| `make distclean` | speech.cpp のビルドも含めて消す |

- speech.cpp は submodule (`vendor/speech.cpp`) で、使う版を固定している。`build/speech.cpp` にビルドし、`Koe.app/Contents/MacOS/speech` に同梱する
  - `git pull` で固定した版が変わったときは `git submodule update --init --recursive` で合わせる (違っていれば `make` が知らせる)
- `-DGGML_OPENMP=OFF -DGGML_NATIVE=OFF` でビルドし、Homebrew の libomp やビルドした Mac の CPU に依存しない単体の実行ファイルにする
- モデルは初回に `speech` が Hugging Face から取得し、`~/Library/Caches/speech.cpp` に置く
- 署名には `make signing-identity` で作る自己署名証明書「Koe Local Signing」を使う。アドホック署名だと許可がビルドのハッシュ値に紐づき、ビルドし直すたびにアクセシビリティの許可が外れるため

speech.cpp の版を上げるとき:

```sh
cd vendor/speech.cpp && git fetch --tags && git checkout v0.x.y && git submodule update --init --recursive && cd -
make run
git add vendor/speech.cpp
```

## 使い方

| 操作 | 動作 |
|---|---|
| ホットキーを短く押す | 録音を開始。もう一度押すと止めて書き起こす |
| ホットキーを長押し (0.4 秒以上) | 押している間だけ録音し、離すと書き起こす |
| 録音中に Esc | 録音を捨てる |
| 書き起こし中に Esc | 取り消す。もう一度 Esc を押すと、応答を待たずに worker を起動し直して止める |
| メニューの履歴 | 直近 10 件の書き起こし。選ぶとクリップボードにコピーする |

録音中は画面下部に、流れる波形、経過時間、使っている入力デバイスを出す。書き起こしが終わると、入力した文字列を短く出す (コピーのみのときや、ペーストできなかったときはそう示す)。

既定のホットキーは右 ⌥。修飾キー単独のホットキーで、押したまま別のキーを押した場合は、ショートカットの一部とみなして録音を捨てる。

書き起こす前に録音を確かめる。

- 0.3 秒未満の録音は誤操作とみなして捨てる
- 1 秒以上録音したのにマイクから音が届いていなければ、エラーを出す
- 音が小さすぎる (ピークが 0.005 以下) ときは、無音とみなしてエラーを出す (無音を渡すとモデルがそれらしい文を作るため)
- 小さい音は、ピークが 0.5 になるまで持ち上げる (最大 10 倍)

マイクが 3 秒以内に開かなければ、あきらめてエラーを出す (CoreAudio が応答しなくなっても、アプリ全体は止まらない)。

## 権限

| 権限 | 使い道 |
|---|---|
| マイク | 録音 |
| アクセシビリティ | ペーストのキー入力を送る。修飾キー単独のホットキーを検出する |
| オートメーション (System Events) | ペーストを AppleScript で送るときだけ |

起動時にマイクとアクセシビリティの許可を求める。許可の状態は「一般」タブの「権限」で確かめられる。

## 設定

設定画面は 5 つのタブに分かれている。変更はすぐに保存され、次の録音から使う。

**一般**

- **ホットキー**: 「変更…」を押してから、登録したいキーを実際に押す。押している間はその場で表示される
  - 修飾キー単独 (左右を区別。例: 右 ⌥、左 ⌘、fn)
  - ⌃ ⌥ ⌘ とキーの組み合わせ (例: ⌃⌥Space)。⇧ だけとの組み合わせは、大文字の入力を奪うので使えない。他のアプリが使っている組み合わせは登録できない
  - F キーは単独でも可
- **マイク**: システムの既定、または入力デバイスを指定。指定したデバイスがつながっていなければ、システムの既定で録音する
- **効果音**: 録音の開始と終了で音を鳴らす。既定はオンで、開始音 Tink、終了音 Pop。音は `~/Library/Sounds`、`/Library/Sounds`、`/System/Library/Sounds` にあるものから選べ、選ぶと試聴できる。開始音がマイクに入らないよう、録音の先頭の最大 0.2 秒を捨てる

**認識**

- **モデル**: Haas ja (既定) / ReazonSpeech v2 / Parakeet ja / Qwen3-ASR 0.6B・1.7B。切り替えると worker を起動し直す
  - ダウンロード済みのモデルには ✓ が付く。ダウンロード中は、設定画面、メニュー、HUD に進み具合を出す (`speech models --json` を 1 秒ごとに調べる)
- **言語**: 自動 / 日本語 / 英語。Qwen3-ASR のときだけ出る
- **語彙・ヒント**: Haas では `表記=読み` を 1 行に 1 つ (例: `Claude=クロード`)。Qwen3-ASR では固有名詞や用語を並べたプロンプト

**出力**

- **書き起こした文字列**: カーソル位置に入力 (クリップボードを元に戻す) / カーソル位置に入力してクリップボードにも残す / クリップボードにコピーのみ
- **ペーストの送り方**: 右 ⌘ で ⌘V (既定) / 左 ⌘ で ⌘V / AppleScript (System Events) で ⌘V / キーを指定
  - 左右の ⌘ に別の役割を割り当てているアプリでは、⌘ として扱われる側を選ぶ
  - 右 ⌘・左 ⌘ は QWERTY の V の位置のキーを送る。キー配列によって ⌘V が別の位置にあるときは「キーを指定」を選び、ペーストになるキー (⌘ と V を打つキー) を押して記録する。記録できるキーはアプリごとのルールと同じ
  - AppleScript は文字 "v" を指定して打つので、多くのキー配列でそのまま使える。⌘ を押す間だけ QWERTY になる配列などで ⌘V にならないときは「キーを指定」を使う。初回は「System Events の制御」の許可を求められる (システム設定 > プライバシーとセキュリティ > オートメーション)
  - 送るキーが録音のホットキーと同じなら送らない (文字列はクリップボードに残す)
- **ペーストのタイミング**: キー入力の間隔 (既定 10 ms、0〜100 ms) と、クリップボードを戻すまでの時間 (既定 300 ms、100〜3000 ms)。文字が入らないときや、前のクリップボードの中身が貼られるときは大きくする。使う設定のときだけ出る

**アプリ**

- 入力先のアプリ (最前面のアプリ) ごとに、出力とペーストの送り方を上書きする。「既定」の項目は「出力」タブの設定に従う。起動中のアプリか、アプリケーションフォルダから選んで追加する
- ペーストの送り方に「キーを指定」を選ぶと、⌘V の代わりに任意のキー (例: ⌃Y) を送る。そのアプリでペーストのキーバインドを変えているときに使う
  - 書き起こすたびに送るので、⌃ ⌥ ⇧ ⌘ のいずれかを含むキーか F キーに限る。Return、Tab、Esc、Delete と、アプリを閉じたり隠したりする ⌘Q、⌘W、⌘H、⌘M は送れない
  - 修飾キーは左側のキーとして送る

**詳細**

- **speech コマンド**: 使う `speech` のパス。空なら、環境変数 `KOE_SPEECH`、`.app` に同梱したもの、`~/.local/bin/speech`、`/opt/homebrew/bin/speech`、`/usr/local/bin/speech` の順に探す
- 「worker を再起動」で worker を起動し直す

## 表示言語

英語と日本語に対応し、macOS の言語設定に従う。アプリごとの言語は「システム設定 > 一般 > 言語と地域 > アプリケーション」で変えられる。

- 画面の文字列はソースに英語で書き、日本語訳は `Resources/ja.lproj/Localizable.strings` に置く。キーは英語の文字列そのもの
- 許可を求めるダイアログ (マイク、オートメーション) の説明文の日本語訳は `Resources/ja.lproj/InfoPlist.strings`
- 一時的に言語を変えて起動する: `build/Koe.app/Contents/MacOS/Koe -AppleLanguages '(en)'`

## しくみ

- `speech worker MODEL` を子プロセスとして起動したままにし、[JSON Lines のプロトコル](https://github.com/nyosegawa/speech.cpp/blob/main/docs/worker.md)で録音を渡す
- 録音は止めたあとにまとめて送る。モデルが読み込み中でも録音はでき、準備ができてから書き起こす
- 入力はクリップボードに文字列を置き、⌘V を送ってペーストする ([VoiceInk](https://github.com/Beingpax/VoiceInk) と同じ方式)
- 元のクリップボードに戻すときは、置いた文字列に `org.nspasteboard.TransientType` と `AutoGeneratedType` を付け、クリップボードの履歴を取るアプリに残さなくてよいと伝える ([nspasteboard.org](http://nspasteboard.org) の慣習)

## 動作確認

マイクなしで、音声ファイルを同じ経路で書き起こせる。

```sh
say -v Kyoko "音声入力のテストです。" -o /tmp/t.aiff && afconvert -f WAVE -d LEI16@48000 /tmp/t.aiff /tmp/t.wav
build/Koe.app/Contents/MacOS/Koe --transcribe /tmp/t.wav [MODEL]
```

ショートカットの記録、アプリごとのルール、モデル一覧の読み取り、クリップボードの目印は `make test` で確かめる。

設定画面は、起動時に開いたり、各タブを PNG に書き出したりできる。書き出しはアプリが自分のウィンドウを描くので、画面収録の許可は要らない。

```sh
build/Koe.app/Contents/MacOS/Koe --open-settings
build/Koe.app/Contents/MacOS/Koe --snapshot-settings /tmp/shots -AppleLanguages '(en)'   # settings-<tab>.png を書き出して終了する
build/Koe.app/Contents/MacOS/Koe --snapshot-hud /tmp/shots   # HUD の各表示を hud-<状態>-<light|dark>.png に書き出す
```
