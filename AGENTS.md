## Agent skills

### Issue tracker

Issues and specs live as GitHub issues. See `docs/agents/issue-tracker.md`.

### Triage labels

The five canonical roles use the default label strings. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: `GLOSSARY.md` and `docs/adr/` at the repo root. See `docs/agents/domain.md`.

### Checks

Before committing: `scripts/check.sh` (widget-source guard, QML suite, Python
suite). A single QML file: `scripts/qml-test`. `qmltestrunner` on `PATH` is Qt 5
and fails silently; the scripts use `/usr/lib/qt6/bin/qmltestrunner`.

### Live verification

After installing or copying plugin QML/JS: `docs/agents/live-verify.md`.
