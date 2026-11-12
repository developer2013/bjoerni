# Idee: Scans automatisch an Paperless-ngx schicken

> **Status:** Idee, noch **nicht umgesetzt** (Stand 12.11.2026).
> Hier steht alles, was wir schon geklärt haben, damit wir später direkt loslegen können.

## Ziel

Jeder Scan landet automatisch in **Paperless-ngx**, egal ob er über die Weboberfläche,
den iPhone-Kurzbefehl, Siri, den Befehl `scan2nas scannen` oder die Einzug-Automatik
kommt. Dort wird er durchsuchbar abgelegt und mit dem Tag **„Scanner“** markiert.

## Ausgangslage bei Björn

| Was | Wert |
|---|---|
| Paperless-Container | **104 (paperless-ngx)**, installiert per Community Script |
| Weboberfläche / API | `http://<ip-von-104>:8000` |
| Programm | `/opt/paperless` (Python über `uv`), Konfiguration `/opt/paperless/paperless.conf` |
| Eingangsordner (Consume) | `/opt/paperless_data/consume` |
| scan2nas | Container 107, legt PDFs bereits auf dem NAS ab |

## Mögliche Wege

| Weg | So funktioniert's | Bewertung |
|---|---|---|
| **A. Direkt hochladen** ⭐ | scan2nas schickt jedes fertige PDF über die Paperless-Schnittstelle | **Favorit.** Funktioniert für alle Scan-Wege, Ausfälle fängt eine Warteschlange auf, am Paperless-Container ändert sich nichts |
| B. Gemeinsamer Eingangsordner | Ein Host-Ordner wird in beide Container eingehängt | Greift in Container 104 ein (Mounts, Rechte). Bei Netzwerkfreigaben muss Paperless den Ordner regelmäßig abfragen (`PAPERLESS_CONSUMER_POLLING`), weil sonst neue Dateien nicht gemeldet werden |
| C. Paperless liest den NAS-Ordner | Der Eingangsordner zeigt auf `Scans` | **Nein:** Paperless löscht eingelesene Dateien, das NAS-Archiv wäre weg |

Doppelte Texterkennung gibt es nicht: Paperless überspringt OCR standardmäßig
(`PAPERLESS_OCR_MODE=skip`), wenn ein PDF schon Text enthält. Das ist bei unseren
PDFs der Fall.

## Entscheidungen

- ✅ **Tag „Scanner“** an jedem Scan. scan2nas legt ihn in Paperless an, falls er fehlt.
- ❓ **NAS-Kopie: offen.** Zur Wahl stehen:
  - *Beides:* NAS-Archiv + Paperless (Empfehlung: eine Kopie zum direkten Durchstöbern)
  - *Nur Paperless:* der NAS-Ordner dient dann nur noch als Notablage, wenn Paperless nicht erreichbar ist

## Technischer Entwurf (Weg A)

**Neue Einstellungen** in `/etc/scan2nas/scan2nas.conf`:

```bash
PAPERLESS_URL=""          # z. B. http://192.168.100.x:8000 – leer = aus
PAPERLESS_TOKEN=""        # API-Token
PAPERLESS_TAG="Scanner"   # leer = kein Tag
NAS_KOPIE="ja"            # ja = zusätzlich aufs NAS (je nach Entscheidung oben)
PAPERLESS_WARTESCHLANGE="/var/lib/scan2nas/paperless-warteschlange"
```

**Hochladen** (nur Python-Standardbibliothek, `urllib` + selbst gebautes multipart):

```
POST {PAPERLESS_URL}/api/documents/post_document/
Authorization: Token {PAPERLESS_TOKEN}
Formularfelder: document=<PDF>, created=<Scanzeit>, tags=<Tag-ID>
```

**Tag-ID ermitteln:** `GET /api/tags/?name__iexact=Scanner`. Gibt es ihn nicht:
`POST /api/tags/` mit `{"name": "Scanner"}`. Die ID für die Laufzeit merken.

**Einbau:** in `ablegen()` in `programm/scan2nas.py`. Darüber laufen schon alle
Scan-Wege, auch `scan2nas uebernehmen` aus der Weboberfläche.

**Ausfälle:** Ist Paperless nicht erreichbar, kommt die Datei in eine eigene
Warteschlange. Der Hintergrunddienst liefert sie nach, genau wie beim NAS.

**Einrichtung im Assistenten** (`einrichten.sh` → „Einstellungen ändern“):
1. Container mit `/opt/paperless` erkennen (wie beim AdGuard-Skript) → IP, Port 8000
2. Token erzeugen. Idee, **ungetestet**:
   `pct exec 104 -- bash -c 'cd /opt/paperless/src && uv run --no-sync -- python manage.py drf_create_token <benutzer>'`
   Fallback: Björn erzeugt ihn selbst in Paperless (Profil → API-Token) und fügt ihn ein
3. Verbindung testen (`GET /api/` mit Token) und in die Konfiguration schreiben

**Tests:** eine nachgebaute Paperless-API wie in `tests/test_adguard.py`. Sie prüft
Upload, Tag anlegen und wiederverwenden, Warteschlange bei Ausfall und das Nachliefern.

**Doku:** neue Seite `docs/06-paperless.md`, dazu im AdGuard-Assistenten der Name
`paperless.lan` → Container 104.

## Noch zu klären

- NAS-Kopie: beides oder nur Paperless (siehe oben)
- Klappt `drf_create_token` mit der `uv`-Installation des Community Scripts? Mit welchem Benutzer?
- Titel in Paperless: Dateiname (`Scan_2026-11-12_23-05-12`) oder leer lassen, damit
  Paperless selbst einen findet?
- Sollen Weboberfläche und iPhone-Scans unterschiedliche Tags bekommen (z. B. „iPhone“)?

## Quellen

- Paperless-ngx API, Abschnitt „POSTing documents“:
  https://github.com/paperless-ngx/paperless-ngx/blob/main/docs/api.md
- Community Script (Pfade, Port 8000, `uv`):
  https://github.com/community-scripts/ProxmoxVE/blob/main/install/paperless-ngx-install.sh
