# Koe.app を作る。speech.cpp は submodule (vendor/speech.cpp) からビルドして同梱する。

APP          := build/Koe.app
SPEECH_SRC   := vendor/speech.cpp
SPEECH_BUILD := build/speech.cpp
SPEECH       := $(SPEECH_BUILD)/speech
INSTALL_DIR  ?= $(HOME)/Applications

# OpenMP を切ると Homebrew の libomp に依存しない単体の実行ファイルになる。
# GGML_NATIVE を切ると、ビルドした Mac の CPU に依存する最適化をしない
SPEECH_CMAKE_FLAGS := -DCMAKE_BUILD_TYPE=Release -DGGML_OPENMP=OFF -DGGML_NATIVE=OFF

.PHONY: app speech test run install signing-identity clean distclean check-tools

app: speech
	SPEECH="$(SPEECH)" scripts/build-app.sh

# 毎回 cmake --build を呼ぶ。変更がなければすぐに終わる
speech: $(SPEECH_BUILD)/CMakeCache.txt
	cmake --build $(SPEECH_BUILD) --config Release --target speech-cli -j

$(SPEECH_BUILD)/CMakeCache.txt: | check-tools $(SPEECH_SRC)/CMakeLists.txt
	cmake -S $(SPEECH_SRC) -B $(SPEECH_BUILD) $(SPEECH_CMAKE_FLAGS)

$(SPEECH_SRC)/CMakeLists.txt:
	git submodule update --init --recursive

check-tools:
	@command -v swift >/dev/null || { echo "swift が見つかりません (xcode-select --install で入れる)" >&2; exit 1; }
	@command -v cmake >/dev/null || { echo "cmake が見つかりません (brew install cmake で入れる)" >&2; exit 1; }

test:
	swift test

run: app
	-pkill -x Koe
	open $(APP)

install: app
	-pkill -x Koe
	rm -rf "$(INSTALL_DIR)/Koe.app"
	mkdir -p "$(INSTALL_DIR)"
	ditto $(APP) "$(INSTALL_DIR)/Koe.app"
	@echo "installed: $(INSTALL_DIR)/Koe.app"

signing-identity:
	scripts/create-signing-identity.sh

clean:
	rm -rf $(APP)
	swift package clean

# speech.cpp のビルドも消す
distclean:
	rm -rf build .build
