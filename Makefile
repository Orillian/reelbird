# Friendly entry points. Each target calls a script in scripts/, which does the real work.

.PHONY: help build test app run install dist icon signing clean

help:
	@echo "make build    debug build of every module"
	@echo "make test     run the test suite"
	@echo "make run      rebuild the app and open it (quits a running copy first)"
	@echo "make app      build build/Reelbird.app (release)"
	@echo "make install  build the app and copy it to /Applications (asks before replacing)"
	@echo "make dist     build/Reelbird-<version>.zip and its SHA-256 (release; notarized with a Developer ID, else ad hoc)"
	@echo "make icon     regenerate the app icon and menu bar glyphs from brand/*.svg"
	@echo "make signing  create a local signing certificate so permissions survive rebuilds"
	@echo "make clean    remove .build/ and build/"

build:
	scripts/build.sh

test:
	scripts/test.sh

app:
	scripts/build-app.sh

run:
	scripts/run.sh

install:
	scripts/install.sh

dist:
	scripts/dist.sh

icon:
	scripts/make-icon.sh

signing:
	scripts/dev-signing.sh

clean:
	rm -rf .build build
