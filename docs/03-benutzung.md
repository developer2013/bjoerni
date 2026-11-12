# 3. Benutzung

- [Weboberfläche](#weboberfläche)
- [iPhone-Kurzbefehl und Siri](05-iphone-kurzbefehl.md) (eigene Anleitung)
- [Scannen per Befehl](#scannen-per-befehl)
- [Einzug-Automatik](#einzug-automatik)
- [Einstellungen](#einstellungen)
- [Warteschlange](#warteschlange-wenn-das-nas-aus-ist)
- [Meldungen und Logs](#meldungen-und-logs)

---

## Weboberfläche

Im Browser öffnen: **`http://<container-ip>:8080`**

1. **Sprache:** Oben rechts auf das Zahnrad (*Settings*) → *Locale* → **Deutsch**.
   Das musst du pro Browser nur einmal machen.
2. **Quelle:** *Flatbed* = Vorlagenglas, *ADF* = Einzug oben (bis 20 Blatt).
3. **Auflösung:** 300 dpi ist voreingestellt und passt für Dokumente.
4. **Format:** Ein PDF-Format wählen. Formate mit **OCR** im Namen machen das PDF
   durchsuchbar, brauchen aber etwas länger.
5. **Scannen** klicken.

Jeder Scan landet **automatisch auf dem NAS**:
`Scans/<Jahr>/<Jahr-Monat>/Scan_<Datum>_<Uhrzeit>.pdf`

Im Reiter **Dateien** siehst du die letzten Scans zum Ansehen oder Herunterladen.
Diese lokalen Kopien werden nach 7 Tagen gelöscht (`WEB_AUFBEWAHRUNG_TAGE`). Auf dem
NAS bleiben sie natürlich. Über die Aktion **„Nochmal aufs NAS kopieren“** kannst du
eine Datei erneut senden.

**Mehrere Seiten vom Glas in ein PDF:** Bei *Stapel* (*Batch*) die Einstellung
**Manuell** wählen. Nach jeder Seite fragt die Oberfläche, ob noch eine Seite kommt.

**Tipp fürs Handy:** Seite öffnen → *Teilen → Zum Home-Bildschirm*. Dann hast du
eine „Scanner-App“ auf dem Handy.

---

## Scannen per Befehl

Im Container (`pct enter <ID>` auf dem Proxmox-Host):

```bash
scan2nas scannen                    # 1 Seite vom Glas, Farbe, 300 dpi, mit OCR
scan2nas scannen -q einzug          # alle Seiten aus dem Einzug → ein PDF
scan2nas scannen -q einzug -m grau  # Einzug in Graustufen (kleinere Dateien)
scan2nas scannen -d 600             # hohe Auflösung, z. B. für Fotos
scan2nas scannen --ohne-ocr         # ohne Texterkennung (schneller)
```

| Option | Werte | Standard (aus der Konfiguration) |
|---|---|---|
| `-q`, `--quelle` | `glas`, `einzug` | `QUELLE="glas"` |
| `-m`, `--modus` | `farbe`, `grau` | `MODUS="farbe"` |
| `-d`, `--dpi` | z. B. `150`, `300`, `600` | `AUFLOESUNG="300"` |
| `--ohne-ocr` | – | `OCR_AKTIV="ja"` |

Weitere Befehle:

```bash
scan2nas test                 # Selbsttest
scan2nas status               # Scanner bereit? Papier im Einzug?
scan2nas warteschlange        # wartende Scans jetzt aufs NAS schieben
scan2nas uebernehmen datei.pdf   # beliebige Datei nach demselben Schema aufs NAS legen
scan2nas --help
```

**Vom Proxmox-Host aus, ohne in den Container zu wechseln:**

```bash
pct exec <ID> -- scan2nas scannen -q einzug
```

---

## Einzug-Automatik

Mit der Automatik reicht es, **Papier in den Einzug zu legen**. Nach 15 Sekunden
wird gescannt und das PDF landet auf dem NAS. Du musst nichts klicken.

### Einschalten

```bash
nano /etc/scan2nas/scan2nas.conf
#   AUTOMATIK_AKTIV="ja"
systemctl restart scan2nas
journalctl -u scan2nas -f        # zuschauen
```

### So entscheidet die Automatik

- Sie fragt den Scanner alle 5 Sekunden (`AUTOMATIK_INTERVALL`), ob Papier im
  Einzug liegt.
- Sie scannt erst, wenn das Papier **15 Sekunden lang ununterbrochen** drin liegt
  (`AUTOMATIK_WARTEZEIT`). So kannst du den Stapel in Ruhe fertig einlegen.
- Sie scannt **nur, wenn der Scanner frei ist**, also nicht gerade druckt oder kopiert.
- **Jeder Stapel wird nur einmal gescannt.** Gibt es einen Papierstau, versucht sie
  es nicht endlos weiter. Nimm das Papier heraus und leg es neu ein.
- Liegt beim Start des Dienstes schon Papier im Einzug, wird es **nicht** gescannt.
  Es könnte ein vergessener Rest sein. Auch hier hilft: herausnehmen, neu einlegen.

### ⚠️ Gut zu wissen

- **Kopieren am Gerät:** Willst du mit dem Einzug am Drucker *kopieren*, musst du
  innerhalb der Wartezeit auf Start drücken. Sonst greift die Automatik zu. Wenn dich
  das stört, stell die Wartezeit höher (z. B. `AUTOMATIK_WARTEZEIT="30"`) oder lass
  die Automatik aus und scanne über die Weboberfläche.
- **Energiesparen:** Die regelmäßige Abfrage kann den Drucker eventuell davon
  abhalten, in den tiefsten Schlaf zu gehen. Ein größeres Intervall
  (`AUTOMATIK_INTERVALL="15"`) entlastet ihn.
- **Voraussetzung:** Der Scanner muss den Einzug-Status (*AdfState*) melden. Prüfen
  kannst du das mit `scan2nas status`. Steht dort „Einzug: wird nicht gemeldet“,
  funktioniert die Automatik mit diesem Gerät nicht.

---

## Einstellungen

Alle Einstellungen stehen mit Erklärung in **`/etc/scan2nas/scan2nas.conf`**.
Nach einer Änderung: `systemctl restart scan2nas`, dann `scan2nas test`.

| Einstellung | Standard | Bedeutung |
|---|---|---|
| `SCANNER_IP` | – | Feste IP des Scanners |
| `SCANNER_GERAET` | leer | SANE-Gerätename. Leer bedeutet automatische Suche (`scanimage -L`) |
| `AUFLOESUNG` | `300` | dpi für `scan2nas scannen` und die Automatik |
| `MODUS` | `farbe` | `farbe` oder `grau` |
| `QUELLE` | `glas` | `glas` oder `einzug` |
| `BILDFORMAT` | `jpeg` | Zwischenformat der Seiten: `jpeg`, `png`, `tiff` |
| `OCR_AKTIV` | `ja` | Texterkennung an/aus |
| `OCR_SPRACHE` | `deu` | z. B. `deu+eng` (dann `apt install tesseract-ocr-eng`) |
| `OCR_OPTIONEN` | `--rotate-pages --deskew --optimize 1` | Zusatzoptionen für ocrmypdf |
| `NAS_ORDNER` | `/mnt/nas/Scans` | Zielordner. **Muss existieren**, sonst gilt das NAS als „nicht da“ |
| `DATEINAME_MUSTER` | `%Y/%Y-%m/Scan_%Y-%m-%d_%H-%M-%S` | Unterordner + Dateiname, siehe unten |
| `WARTESCHLANGE` | `/var/lib/scan2nas/warteschlange` | Zwischenlager, wenn das NAS fehlt |
| `WARTESCHLANGE_INTERVALL` | `300` | Sekunden zwischen zwei Nachliefer-Versuchen |
| `AUTOMATIK_AKTIV` | `nein` | Einzug-Automatik an/aus |
| `AUTOMATIK_INTERVALL` | `5` | Sekunden zwischen zwei Abfragen |
| `AUTOMATIK_WARTEZEIT` | `15` | Sekunden, die das Papier liegen muss |
| `AUTOMATIK_MODUS` | `grau` | Farbmodus der Automatik |
| `WEB_AUFBEWAHRUNG_TAGE` | `7` | Lokale Kopien der Weboberfläche löschen nach … Tagen (`0` = nie) |
| `LOGLEVEL` | `INFO` | `DEBUG` für mehr Details |

### Dateinamen und Ordner

`DATEINAME_MUSTER` legt Unterordner und Dateinamen fest (ohne `.pdf`). Platzhalter:
`%Y` Jahr, `%m` Monat, `%d` Tag, `%H` Stunde, `%M` Minute, `%S` Sekunde.

| Muster | Ergebnis |
|---|---|
| `%Y/%Y-%m/Scan_%Y-%m-%d_%H-%M-%S` | `2026/2026-11/Scan_2026-11-12_20-43-05.pdf` |
| `Scan_%Y-%m-%d_%H-%M-%S` | alles in einem Ordner |
| `%Y/%Y-%m-%d_%H%M%S` | `2026/2026-11-12_204305.pdf` |

Gibt es eine Datei schon, wird `_2`, `_3` … angehängt. Überschrieben wird nie etwas.

**paperless-ngx:** Zeig mit `NAS_ORDNER` direkt auf den *consume*-Ordner und setz
`DATEINAME_MUSTER="Scan_%Y-%m-%d_%H-%M-%S"`. scan2nas schreibt jede Datei zuerst
unter einem versteckten Namen und benennt sie erst fertig um, wenn sie vollständig
ist. paperless greift also nie eine halbe Datei.

---

## Warteschlange (wenn das NAS aus ist)

Ist das NAS nicht erreichbar, legt scan2nas den Scan in
`/var/lib/scan2nas/warteschlange` ab. Der Hintergrunddienst versucht alle 5 Minuten,
die wartenden Dateien aufs NAS zu schieben. Ordnerstruktur und Dateinamen bleiben
dabei erhalten.

```bash
scan2nas warteschlange                       # sofort versuchen
ls -R /var/lib/scan2nas/warteschlange        # was wartet noch?
```

---

## Meldungen und Logs

```bash
journalctl -u scan2nas -f          # Hintergrunddienst (Automatik, Warteschlange)
journalctl -u scanservjs -f        # Weboberfläche (inkl. „[scan2nas] …“-Zeilen)
systemctl status scan2nas scanservjs
```

Auf dem **Proxmox-Host** (NAS-Wächter):

```bash
journalctl -t scan2nas             # Meldungen des NAS-Wächters
systemctl list-timers scan2nas-nas-waechter.timer
```
