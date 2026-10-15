.PHONY: analyze test build run

FLUTTER ?= flutter
DART_DEFINE_FILE ?=
DART_DEFINE_FLAG := $(if $(DART_DEFINE_FILE),--dart-define-from-file=$(DART_DEFINE_FILE),)

analyze:
	$(FLUTTER) analyze --no-pub

test:
	$(FLUTTER) test --no-pub

build:
	$(FLUTTER) build apk --debug $(DART_DEFINE_FLAG)

run:
	$(FLUTTER) run $(DART_DEFINE_FLAG)
