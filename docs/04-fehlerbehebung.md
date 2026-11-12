# 4. Fehlerbehebung

**Erster Schritt bei jedem Problem:** im Container

```bash
scan2nas test
```

Der Selbsttest zeigt dir meistens schon, wo es hakt. Darunter findest du die
häufigsten Probleme, sortiert nach Bereich.

- [Installation](#installation)
- [NAS](#nas)
- [Scanner](#scanner)
- [Weboberfläche](#weboberfläche)
- [Texterkennung (OCR)](#texterkennung-ocr)
- [Einzug-Automatik](#einzug-automatik)

---

## Installation

**„pct nicht gefunden“**
Das Skript `proxmox/lxc-erstellen.sh` muss auf dem **Proxmox-Host** laufen, nicht
im Container und nicht auf deinem PC.

**„Der Container hat nach 2 Minuten noch kein Internet“**
- Bei fester IP: Stimmen `CT_IP` (mit `/24`!) und `CT_GATEWAY`?
- Stimmt `CT_BRIDGE` (meist `vmbr0`)?
- Test im Container: `pct enter <ID>`, dann `ping -c3 1.1.1.1` und `ping -c3 deb.debian.org`

**„Kein Debian-Template gefunden“**
Auf dem Host `pveam update` ausführen und die Internetverbindung des Hosts prüfen.

**`Permission denied` beim Start des Skripts**
Mit `bash ./proxmox/lxc-erstellen.sh` aufrufen. Nach einem ZIP-Download fehlt manchmal
das Ausführungsrecht.

---

## NAS

**„Das NAS konnte nicht eingehängt werden“**
Was genau schiefging, steht ganz unten in `dmesg`:

```bash
dmesg | tail -n 20
```

| Meldung | Bedeutung | Lösung |
|---|---|---|
| `mount error(13): Permission denied` | Benutzer oder Passwort falsch | `NAS_BENUTZER` / `NAS_PASSWORT` prüfen. Passwort in **einfache** Anführungszeichen setzen |
| `mount error(2): No such file or directory` | Freigabe gibt es nicht | `NAS_FREIGABE` = Name der **Freigabe**, nicht der Ordnerpfad |
| `mount error(112): Host is down` | SMB-Version passt nicht | `SMB_VERSION="2.1"` oder `"3.1.1"` probieren |
| `mount error(95): Operation not supported` | SMB-Version passt nicht | wie oben |
| `mount error(115)` / Zeitüberschreitung | NAS nicht erreichbar | IP, Firewall, ist SMB am NAS aktiv? |

Danach einfach `bash ./proxmox/lxc-erstellen.sh` erneut ausführen.

**„NAS-Ordner /mnt/nas/Scans fehlt“ (im Container)**
Der Container sieht das NAS nicht. Auf dem **Host** prüfen:

```bash
mountpoint /mnt/scan2nas && ls /mnt/scan2nas      # ist das NAS auf dem Host da?
pct config <ID> | grep mp0                         # ist es durchgereicht?
```

- Host hat das NAS nicht: `mount /mnt/scan2nas` (Fehler siehe oben)
- Host hat es, Container nicht: `pct reboot <ID>`. Ein Container sieht ein NAS, das
  erst *nach* seinem Start eingehängt wurde, erst nach einem Neustart. Der
  NAS-Wächter macht das normalerweise automatisch.

**„NAS-Ordner ist nicht beschreibbar“**
- SMB: Hat der NAS-Benutzer **Schreibrecht** auf die Freigabe?
- NFS: Siehe [NFS-Rechte](01-vorbereitung.md#nfs-statt-smb-für-fortgeschrittene).
  Der Container schreibt als Benutzer-ID 100000.

**Scans liegen in der Warteschlange und kommen nicht an**
`scan2nas warteschlange` ausführen und die Meldung lesen. Meist ist das NAS nicht
eingehängt (siehe oben).

---

## Scanner

**„Scanner antwortet nicht unter http://…/eSCL“**
1. Ist der Drucker an? Aus dem Tiefschlaf wacht er manchmal erst nach einem
   zweiten Versuch auf.
2. Stimmt die IP? Im Container: `ping -c3 <SCANNER-IP>`
3. Antwortet eSCL? `curl -s http://<SCANNER-IP>/eSCL/ScannerStatus` muss XML liefern.
4. Hat der Scanner eine neue IP bekommen? Dann in `/etc/scan2nas/scan2nas.conf`
   **und** in `/etc/sane.d/airscan.conf` ändern und `systemctl restart scan2nas scanservjs`.
   Besser: im Router eine feste IP vergeben, siehe [Vorbereitung](01-vorbereitung.md).

**„Kein passender Scanner gefunden“** (SANE)

```bash
scanimage -L                       # welche Geräte sieht SANE?
cat /etc/sane.d/airscan.conf       # ist die IP richtig eingetragen?
```

Mehr Details liefert das Debug-Log von sane-airscan:

```bash
SANE_DEBUG_AIRSCAN=1 scanimage -L 2>&1 | tail -n 40
```

**Plan B: pixma-Backend statt eSCL**
Der TR8550 wird auch vom SANE-Backend `pixma` unterstützt (Canon-Protokoll BJNP):

```bash
sed -i 's/^#pixma.*/pixma/' /etc/sane.d/dll.conf
echo "bjnp://<SCANNER-IP>" >> /etc/sane.d/pixma.conf
scanimage -L                                 # Gerät heißt dann z. B. pixma:…
scanimage -d "pixma:…" --help                # Namen für Quelle/Modus anzeigen
```

In `/etc/scan2nas/scan2nas.conf` dann `SCANNER_FILTER="pixma"` setzen und die
Werte `SANE_QUELLE_GLAS` / `SANE_QUELLE_EINZUG` an die Ausgabe von `--help`
anpassen.

**„Der Scanner hat keine Seite geliefert“**
- Einzug: Liegt das Papier richtig drin (Schrift nach oben, ganz eingeschoben)?
- Läuft gerade ein anderer Scan (Weboberfläche)? Dann kurz warten.
- Den genauen Fehler zeigt `scan2nas -v scannen -q einzug`.

**„Es läuft bereits ein Scan“**
Die Automatik oder ein anderer Befehl scannt gerade. Kurz warten.

---

## Weboberfläche

**Seite `http://<container-ip>:8080` lädt nicht**

```bash
systemctl status scanservjs
journalctl -u scanservjs -n 50
```

**Weboberfläche zeigt keinen Scanner**
Erst `scanimage -L` im Container prüfen (siehe [Scanner](#scanner)), dann
`systemctl restart scanservjs` und die Seite neu laden.

**Scan klappt, aber die Datei kommt nicht aufs NAS**

```bash
journalctl -u scanservjs | grep scan2nas
```

Steht dort „Übernahme fehlgeschlagen“, folgt direkt dahinter der Grund.
Prüf auch, ob `/etc/scanservjs/config.local.js` die Datei aus diesem Projekt ist
(sie enthält das Wort `scan2nas`).

---

## Texterkennung (OCR)

**OCR dauert sehr lange**
Normal sind ein paar Sekunden pro Seite. Wenn es zu lange dauert: dem Container mehr
Kerne geben (`pct set <ID> -cores 4`) oder in `OCR_OPTIONEN` das `--deskew`
weglassen.

**„Texterkennung fehlgeschlagen – PDF wird ohne OCR gespeichert“**
Das PDF ist trotzdem auf dem NAS, nur eben nicht durchsuchbar. Den Grund zeigt das
Log (`journalctl -u scan2nas` bzw. die Ausgabe des Befehls). Häufig fehlt ein
Sprachpaket: `apt install tesseract-ocr-deu tesseract-ocr-osd`.

---

## Einzug-Automatik

**Automatik scannt nicht**
1. `grep AUTOMATIK_AKTIV /etc/scan2nas/scan2nas.conf` muss `"ja"` zeigen,
   danach `systemctl restart scan2nas`.
2. `scan2nas status` bei eingelegtem Papier muss `Einzug: ScannerAdfLoaded` zeigen.
3. Lag das Papier schon beim Start des Dienstes drin? Dann herausnehmen und neu einlegen.
4. Ist ein Scan fehlgeschlagen (z. B. Stau)? Auch hier: herausnehmen, neu einlegen.
5. `journalctl -u scan2nas -f` beim Einlegen beobachten.

**„Der Scanner meldet keinen Einzug-Status (AdfState)“**
Dann kann die Automatik mit diesem Gerät bzw. dieser Firmware nicht funktionieren.
Scanne in dem Fall über die Weboberfläche oder `scan2nas scannen -q einzug`.
