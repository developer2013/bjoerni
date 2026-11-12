# CLAUDE.md

Die gemeinsamen Projektregeln für alle KI-Assistenten stehen in AGENTS.md und
werden hier eingebunden:

@AGENTS.md

## Zusätzlich für Claude Code

- **Antworte auf Deutsch.** Das Projekt und seine Leser (Carsten, Björn) sind deutschsprachig.
- **Python auf Carstens Mac:** `python3` ist 3.9, `python3.14` ist 3.14 (Homebrew).
  Der Code muss unter beiden laufen. Tests deshalb mit beiden ausführen:
  ```bash
  python3.14 -m unittest discover -s tests -v
  python3 -m unittest discover -s tests
  ```
- **shellcheck ist lokal nicht installiert**, daher `bash -n` für die Shell-Skripte.
- **Commit und Push nur auf ausdrückliche Anweisung.** Commit-Messages auf Deutsch.
  Remote: `https://github.com/developer2013/bjoerni`, Branch `main`.
  Der Einzeiler lädt `einrichten.sh` direkt von `main` – alles, was dort landet,
  ist sofort „live“ für Björn. Vor jedem Push also die Tests laufen lassen.
- Wenn du Doku änderst: Björn liest sie. Lieber kurze Sätze und konkrete Befehle zum
  Kopieren als Theorie.
