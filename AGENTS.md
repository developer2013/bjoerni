# AGENTS.md – Hinweise für KI-Assistenten

Diese Datei richtet sich an KI-Coding-Assistenten (Claude Code, Codex, Cursor, …),
die an diesem Projekt mitarbeiten. Menschen lesen am besten die [README.md](README.md).

## Worum geht es?

**scan2nas** holt Scans von einem **Canon PIXMA TR8550** (Netzwerk, eSCL/AirScan)
ab und legt sie als durchsuchbare PDFs auf einem **NAS** ab. Das Ganze läuft in
einem **unprivilegierten Debian-LXC-Container auf Proxmox VE**. Zielgruppe ist
Björn: Homelab-Nutzer, liest Deutsch.

## Architektur

```
Canon TR8550 ──eSCL (HTTP :80/eSCL)──▶ Container "scanner" ──Bind-Mount──▶ Host /mnt/scan2nas ──CIFS/NFS──▶ NAS
                                        ├─ sane-airscan + scanimage   (Treiber)
                                        ├─ scanservjs  :8080          (fertige Weboberfläche, Fremdprojekt)
                                        └─ scan2nas                   (dieses Projekt)
```

- **Das NAS wird auf dem Proxmox-Host eingehängt**, nicht im Container (unprivilegierte
  Container dürfen kein CIFS/NFS mounten). CIFS-Mount mit `uid=100000,gid=100000,
  file_mode=0666,dir_mode=0777`. 100000 ist root des Containers.
- **scanservjs** ruft nach jedem Scan `scan2nas uebernehmen <datei>` auf
  (`konfiguration/scanservjs-config.local.js` → `/etc/scanservjs/config.local.js`).
- **scan2nas.service** (läuft als `scanservjs:users`) liefert die Warteschlange nach,
  räumt alte Web-Kopien auf und steuert optional die **Einzug-Automatik**
  (fragt `GET <eSCL>/ScannerStatus` → `AdfState` ab).
- **NAS-Wächter** auf dem Host (`scan2nas-nas-waechter.timer`) hängt das NAS nach
  Ausfällen neu ein und startet den Container neu. Bind-Mounts zeigen ein später
  eingehängtes NAS erst nach einem Container-Neustart.

## Verzeichnisse

| Pfad | Inhalt | Läuft wo |
|---|---|---|
| `einrichten.sh` | Einzeiler-Assistent (whiptail): Scanner-Suche, NAS-Test, speichert `/root/.scan2nas/proxmox.conf`, lädt das Repo und ruft `lxc-erstellen.sh` auf | Proxmox-Host, per `bash -c "$(curl …)"` |
| `programm/scan2nas.py` | Hauptprogramm (CLI + Dienst), eine Datei | Container → `/opt/scan2nas/`, Link `/usr/local/bin/scan2nas` |
| `proxmox/lxc-erstellen.sh` | Einrichtung auf dem Host: NAS, Container, Bind-Mount, Wächter, Installation | Proxmox-Host |
| `proxmox/proxmox.conf.beispiel` | Vorlage für Host-Einstellungen (echte `proxmox.conf` ist gitignored) | Host |
| `installation/installieren.sh` | Pakete, scanservjs, SANE-Konfiguration, Dienste | Container |
| `konfiguration/` | `scan2nas.conf.beispiel` (→ `/etc/scan2nas/scan2nas.conf`), scanservjs-Hook | Container |
| `systemd/scan2nas.service` | Hintergrunddienst | Container |
| `tests/test_scan2nas.py` | unittest, läuft ohne Scanner/NAS (simuliert `scanimage`/`img2pdf`) | überall |
| `tests/test_einrichten.py` | Tests für `einrichten.sh`: Prüffunktionen, Konfig-Rundreise, kompletter Dialogablauf mit Attrappen (whiptail, pvesm, ip, mount) | überall |
| `docs/` | Anleitungen für Björn (01 Vorbereitung … 04 Fehlerbehebung) | – |
| `adguard-home/` | **Eigenständige** Anleitung „AdGuard Home auf Proxmox“ (nur Markdown, kein Code). Nutzt das Community Script `community-scripts/ProxmoxVE/ct/adguard.sh`. Begriffe aus der Oberfläche stammen aus AdGuards `client/src/__locales/de.json`, bei Änderungen dort nachschlagen. Beispiel-IPs: FRITZ!Box `.1`, Proxmox `.5`, Drucker `.50`, AdGuard `.53`, scan2nas `.60` | – |

## Konventionen

- **Alles auf Deutsch:** Doku, Kommentare, Log- und Fehlermeldungen, CLI-Befehle und
  -Optionen, Funktions- und Variablennamen, Commit-Messages. Ansprache in der Doku: „du“.
- **Dateinamen nur ASCII** (`ae/oe/ue/ss` statt Umlauten), Inhalte dürfen UTF-8 nutzen.
- **Python: nur Standardbibliothek**, kompatibel ab **Python 3.9** (Debian 12 hat 3.11,
  Debian 13 hat 3.13, der Entwickler-Mac hat 3.9). Also `from __future__ import annotations`,
  `Optional[...]` statt `X | None`, kein `match`.
- **Bash:** `set -euo pipefail`, Meldungen über `info/ok/warn/fehler`. Skripte müssen
  **idempotent** sein, denn mehrfaches Ausführen ist der Update-Weg. Keine
  `test && befehl`-Ketten als letzte Anweisung einer Funktion (bricht unter `set -e`),
  stattdessen `if`.
- Neue Einstellung? Dann **an drei Stellen** ergänzen: `STANDARDWERTE` in
  `scan2nas.py`, `konfiguration/scan2nas.conf.beispiel` (mit Erklärung) und die
  Tabelle in `docs/03-benutzung.md`. Ein Test prüft, dass Code und Beispieldatei
  übereinstimmen.
- Neue **Host**-Einstellung (für `lxc-erstellen.sh`)? Dann in `proxmox/proxmox.conf.beispiel`,
  in den Standardwerten von `lxc-erstellen.sh` und in `KONFIG_VARIABLEN` +
  `standardwerte_setzen` von `einrichten.sh`. Auch hier prüft ein Test die Übereinstimmung.
- **`einrichten.sh`:** Dialog-Helfer (`eingabe`, `passwort`, `auswahl`) schreiben ihr
  Ergebnis per `printf -v` in eine Variable, statt es auszugeben. Nur so kann
  `abbruch` das Skript beenden (aus `$(…)` heraus ginge das nicht). Gespeichert wird mit
  `printf '%s=%q'`, damit `source` auch Passwörter mit Sonderzeichen exakt zurückliest.
  Ganz unten verhindert `SCAN2NAS_NUR_LADEN=1`, dass `main` läuft (für die Tests).
- **Die Einzeiler-URL ist öffentlich dokumentiert:** `einrichten.sh` im Wurzelordner,
  Branch `main`. Nicht umbenennen oder verschieben.
- Versionsnummer: `VERSION` in `programm/scan2nas.py`.

## Unverrückbare Regeln (Invarianten)

1. **`NAS_ORDNER` wird nie von scan2nas angelegt.** Fehlt er, ist das NAS nicht
   eingehängt. Sonst würde in den leeren lokalen Mountpunkt geschrieben und die
   Dateien wären später unter dem NAS „versteckt“. Unterordner darunter anzulegen
   ist erlaubt.
2. **Nie überschreiben:** Kollisionen bekommen `_2`, `_3` … (`freier_dateiname`).
3. **Atomar schreiben:** erst `.<name>.teil`, dann `os.replace`, damit Ordner-Überwacher
   wie paperless-ngx nie halbe Dateien sehen.
4. **Nichts verlieren:** Ist das NAS nicht erreichbar, kommt die Datei in die
   Warteschlange, statt dass ein Fehler auftritt.
5. **Der scanservjs-Hook darf einen Scan nie scheitern lassen** (Promise löst immer auf).
6. **Keine Geheimnisse ins Repo oder in den Container:** `proxmox.conf` ist gitignored,
   `lxc-erstellen.sh` kopiert per `tar --exclude='*.conf'`. SMB-Zugangsdaten liegen
   nur in `/root/.scan2nas-smb` und `/root/.scan2nas/proxmox.conf` (beide 0600) auf dem
   Host. Beim NAS-Test in `einrichten.sh` steht das Passwort in einer temporären
   `mktemp`-Datei (0600), nie auf der Kommandozeile.
7. **Rechte:** scan2nas setzt `umask 002`; `/var/lib/scan2nas` gehört `root:users`
   mit setgid (2775), damit root (CLI) und `scanservjs` (Dienst/Web) beide schreiben können.
8. **XML vom Scanner:** DOCTYPE/ENTITY werden vor dem Parsen abgelehnt (XXE-Schutz
   ohne `defusedxml`).

## Prüfen und Testen

```bash
python3 -m unittest discover -s tests -v                     # alle Tests
bash -n einrichten.sh proxmox/lxc-erstellen.sh installation/installieren.sh  # Shell-Syntax
node --check konfiguration/scanservjs-config.local.js         # JS-Syntax (falls node da ist)
```

Was sich **nicht** lokal testen lässt: echter Scanner, echtes NAS, Proxmox-Befehle
(`pct`, `pveam`), Debian-Pakete. Änderungen daran nur syntaktisch prüfen und im
Ergebnis offen sagen, was ungetestet ist.

## Nützliche Fakten zum Gerät

- Der TR8550 meldet sich per mDNS als **„Canon TR8500 series“**, `_uscan._tcp` auf
  Port 80, `rs=eSCL`, Quellen `platen,adf`, `duplex=F` (Einzug **nur einseitig**),
  Farbräume `grayscale,color`, Ausgabe `image/jpeg,application/pdf`.
- sane-airscan-Namen: Quelle `Flatbed`/`ADF`, Modus `Color`/`Gray`.
- scanservjs v3: Konfiguration in `/etc/scanservjs/`, Ausgabe in
  `/var/lib/scanservjs/output`, Dienst läuft als `scanservjs:users`, Port 8080.
