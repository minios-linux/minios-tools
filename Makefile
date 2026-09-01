# Variables
EXECUTABLES = $(shell find bin -type f)
COMPLETIONS = $(shell find completion -type f)
AUTOSTART = $(shell find autostart -type f 2>/dev/null)

BINDIR = usr/bin
LIBDIR = usr/lib/minios-tools
LOCALEDIR = usr/share/locale
COMPLETIONSDIR = usr/share/bash-completion/completions
AUTOSTARTDIR = etc/xdg/autostart
MANDIR = usr/share/man/man1

ENGINE_FILES = $(shell find lib -name "*.py" -type f 2>/dev/null)

DOC_FILES = $(shell find doc -name "*.md")
MAN_FILES = $(patsubst doc/%.md, man/%.1, $(DOC_FILES))

PO_FILES  = $(shell find po -name "*.po")
MO_FILES  = $(patsubst %.po,%.mo,$(PO_FILES))

# Build rules
ifeq (,$(findstring nodoc,$(DEB_BUILD_PROFILES)))
ifeq (,$(findstring nodoc,$(DEB_BUILD_OPTIONS)))
build: man
endif
endif
build: locale

.PHONY: build test man locale clean install

test:
	@bats_tmp=$$(mktemp -d "$${TMPDIR:-/tmp}/minios-tools-tests.XXXXXX"); \
	trap 'rm -rf "$$bats_tmp"' EXIT HUP INT TERM; \
	MINIOS_TOOLS_TEST_TMPDIR="$$bats_tmp" bats tests/*.bats

# Compilation rules
man: $(MAN_FILES)

man/%.1: doc/%.md
	@echo "Generating man file for $<"
	mkdir -p $(@D)
	pandoc -s -t man $< -o $@

locale: $(MO_FILES)

%.mo: %.po
	@echo "Generating mo file for $<"
	msgfmt -o $@ $<
	chmod 644 $@

# Clean rule
clean:
	rm -rf man lib/__pycache__ $(MO_FILES)

# Install rule
install: build
	install -d $(DESTDIR)/$(BINDIR)
	install -m755 $(EXECUTABLES) $(DESTDIR)/$(BINDIR)

	install -d $(DESTDIR)/$(LIBDIR)
	if [ -n "$(ENGINE_FILES)" ]; then install -m644 $(ENGINE_FILES) $(DESTDIR)/$(LIBDIR); fi

	install -d $(DESTDIR)/$(COMPLETIONSDIR)
	install -m644 $(COMPLETIONS) $(DESTDIR)/$(COMPLETIONSDIR)

	install -d $(DESTDIR)/$(AUTOSTARTDIR)
	if [ -n "$(AUTOSTART)" ]; then install -m644 $(AUTOSTART) $(DESTDIR)/$(AUTOSTARTDIR); fi

	set -e; if ls man/*.1 >/dev/null 2>&1; then \
		install -d $(DESTDIR)/$(MANDIR); \
		install -m644 man/*.1 $(DESTDIR)/$(MANDIR); \
	fi

	set -e; for MO_FILE in $(MO_FILES); do \
		LOCALE=$$(basename $$MO_FILE .mo); \
		echo "Copying mo file $$MO_FILE to $(DESTDIR)/$(LOCALEDIR)/$$LOCALE/LC_MESSAGES/minios-tools.mo"; \
		install -Dm644 "$$MO_FILE" "$(DESTDIR)/$(LOCALEDIR)/$$LOCALE/LC_MESSAGES/minios-tools.mo"; \
	done
