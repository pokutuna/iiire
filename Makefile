# iiire.app を作る。speech.cpp は submodule (vendor/speech.cpp) からビルドして同梱する。

APP          := build/iiire.app
SPEECH_SRC   := vendor/speech.cpp
SPEECH_BUILD := build/speech.cpp
SPEECH       := $(SPEECH_BUILD)/speech
INSTALL_DIR  ?= /Applications

# OpenMP を切ると Homebrew の libomp に依存しない単体の実行ファイルになる。
# GGML_NATIVE を切ると、ビルドした Mac の CPU に依存する最適化をしない
SPEECH_CMAKE_FLAGS := -DCMAKE_BUILD_TYPE=Release -DGGML_OPENMP=OFF -DGGML_NATIVE=OFF

.PHONY: signing-identity app run install test update-speech speech check-tools clean distclean
.DEFAULT_GOAL := app

# 初回に一度だけ。再ビルドしてもアクセシビリティの許可が外れないよう、署名用の証明書を作る
signing-identity:
	scripts/create-signing-identity.sh

app: speech
	SPEECH="$(SPEECH)" scripts/build-app.sh

run: app
	-pkill -x iiire
	open $(APP)

install: app
	-pkill -x iiire
	rm -rf "$(INSTALL_DIR)/iiire.app"
	mkdir -p "$(INSTALL_DIR)"
	ditto $(APP) "$(INSTALL_DIR)/iiire.app"
	@echo "installed: $(INSTALL_DIR)/iiire.app"
	open "$(INSTALL_DIR)/iiire.app"

test:
	swift test

# speech.cpp を REF (タグやコミット) のバージョンに更新する。REF を省くと最新のタグ。
# 更新したら git add までするので、続けてコミットする
update-speech:
	git -C $(SPEECH_SRC) fetch --tags origin
	git -C $(SPEECH_SRC) checkout $(or $(REF),$$(git -C $(SPEECH_SRC) tag --sort=-v:refname | head -n 1))
	git -C $(SPEECH_SRC) submodule update --init --recursive
	git add $(SPEECH_SRC)
	@echo "speech.cpp: $$(git -C $(SPEECH_SRC) describe --tags --always)"

# 毎回 cmake --build を呼ぶ。変更がなければすぐに終わる。
# submodule が固定したバージョンと違えば知らせる (更新作業中は、そのままビルドする)
speech: $(SPEECH_BUILD)/CMakeCache.txt
	@git submodule status $(SPEECH_SRC) | grep -q '^+' && echo "warning: $(SPEECH_SRC) は固定したバージョンと違う (git submodule update --init --recursive で合わせる)" >&2 || true
	cmake --build $(SPEECH_BUILD) --config Release --target speech-cli -j $(shell sysctl -n hw.ncpu)

# Makefile (ビルドの指定) を変えたら構成し直す
$(SPEECH_BUILD)/CMakeCache.txt: Makefile | check-tools $(SPEECH_SRC)/CMakeLists.txt
	cmake -S $(SPEECH_SRC) -B $(SPEECH_BUILD) $(SPEECH_CMAKE_FLAGS)

$(SPEECH_SRC)/CMakeLists.txt:
	git submodule update --init --recursive

check-tools:
	@command -v swift >/dev/null || { echo "swift が見つかりません (xcode-select --install で入れる)" >&2; exit 1; }
	@command -v cmake >/dev/null || { echo "cmake が見つかりません (brew install cmake で入れる)" >&2; exit 1; }

clean:
	rm -rf $(APP)
	swift package clean

# speech.cpp のビルドも消す
distclean:
	rm -rf build .build
