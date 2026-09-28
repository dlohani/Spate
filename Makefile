# cascade build/export targets.
#
# One Go core, exported to every platform:
#   - desktop CLI            : native `go build`
#   - desktop/Flutter FFI    : c-shared library + header (per host OS)
#   - Android                : gomobile bind -> .aar
#   - iOS                    : gomobile bind -> .xcframework
#
# c-shared and gomobile require CGO and a platform toolchain; targets build for
# the HOST OS. Cross-building the shared libs needs a cross C compiler (set CC).

GO      ?= go
DIST    ?= dist
PKG_CLI  = ./cmd/cascade
PKG_LIB  = ./export/cshared
PKG_MOB  = ./mobile

.PHONY: all cli test race lib android ios tools clean

all: cli lib

cli:
	$(GO) build -o $(DIST)/cascade $(PKG_CLI)

test:
	$(GO) test ./...

race:
	$(GO) test -race ./...

# c-shared library for the host OS (libcascade.{dylib,so} or cascade.dll).
lib:
	@mkdir -p $(DIST)
	@case "$$($(GO) env GOOS)" in \
	  darwin)  out=$(DIST)/libcascade.dylib ;; \
	  linux)   out=$(DIST)/libcascade.so ;; \
	  windows) out=$(DIST)/cascade.dll ;; \
	  *)       out=$(DIST)/libcascade.so ;; \
	esac; \
	echo "building $$out"; \
	CGO_ENABLED=1 $(GO) build -buildmode=c-shared -o $$out $(PKG_LIB)

# Android AAR (requires: gomobile + Android SDK/NDK; ANDROID_NDK_HOME set).
android:
	@mkdir -p $(DIST)
	gomobile bind -target=android -androidapi 30 -o $(DIST)/cascade.aar $(PKG_MOB)

# iOS xcframework (requires: gomobile + Xcode, on macOS).
ios:
	@mkdir -p $(DIST)
	gomobile bind -target=ios -o $(DIST)/Cascade.xcframework $(PKG_MOB)

# Cross-compile and package the Windows amd64 binaries (needs mingw-w64).
windows:
	scripts/build-windows.sh

# Cross-compile the (pure Go) native host for Linux from any OS. libcascade.so
# needs cgo and is built natively on Linux by scripts/install-linux.sh.
host-linux:
	@mkdir -p $(DIST)/linux-amd64 $(DIST)/linux-arm64
	GOOS=linux GOARCH=amd64 CGO_ENABLED=0 $(GO) build -o $(DIST)/linux-amd64/cascade-host ./cmd/cascade-host
	GOOS=linux GOARCH=arm64 CGO_ENABLED=0 $(GO) build -o $(DIST)/linux-arm64/cascade-host ./cmd/cascade-host

# Install/initialize gomobile (one-time).
tools:
	$(GO) install golang.org/x/mobile/cmd/gomobile@latest
	gomobile init

clean:
	rm -rf $(DIST)
