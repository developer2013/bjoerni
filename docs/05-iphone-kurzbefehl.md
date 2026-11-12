# 5. Scannen per iPhone-Kurzbefehl (und Siri)

Mit einem Kurzbefehl auf dem iPhone startest du den Scan mit einem Fingertipp, vom
Home-Bildschirm, per Siri („Hey Siri, Scannen“) oder sogar per NFC-Aufkleber am
Drucker. Das Ergebnis erscheint als Mitteilung:

```
✅ 3 Seite(n) gescannt
📄 Scans/2026/2026-11/Scan_2026-11-12_21-50-00.pdf
```

**So funktioniert es:** Der Kurzbefehl verbindet sich per SSH mit dem
Scanner-Container und schickt ein einzelnes Wort, z. B. `einzug`. Dein iPhone
bekommt dafür einen eigenen Schlüssel, und dieser Schlüssel darf **nur scannen**.
Eine Shell oder andere Befehle sind damit nicht möglich.

> Voraussetzung: scan2nas ist installiert. Wurde es vor dem 12.11.2026 eingerichtet,
> einmal den Einzeiler erneut ausführen und **„Aktualisieren“** wählen. Damit kommt
> das Kurzbefehl-Werkzeug dazu.

---

## Schritt 1: Kurzbefehl anlegen und Schlüssel erzeugen

1. App **Kurzbefehle** öffnen → **+** (neuer Kurzbefehl)
2. **Aktion hinzufügen** → nach **„SSH“** suchen → **Skript über SSH ausführen**
3. In der Aktion ausfüllen (auf **Mehr anzeigen** tippen, falls Felder fehlen):

   | Feld | Wert |
   |---|---|
   | Skript | erst einmal `status` |
   | Host | IP des Scanner-Containers, z. B. `192.168.100.60` (dieselbe wie bei der Weboberfläche, ohne `:8080`). Anzeigen auf dem Proxmox-Host: `pct exec 107 -- hostname -I` |
   | Port | `22` |
   | Benutzer:in | `root`, **klein geschrieben und selbst eintippen**. Das graue „Root“ ist nur ein Platzhalter |
   | Authentifizierung | **SSH-Schlüssel**. Steht dort „Passwort“, drauftippen und umstellen. Mit Passwort geht es nicht: root hat keins, und Debian lässt root per SSH nur mit Schlüssel rein |
   | Eingabe | **leer lassen**. Wird nicht gebraucht |

   > Graue Werte in den Feldern sind nur Beispiele. Erst wenn der Text weiß ist,
   > ist wirklich etwas eingetragen.

4. Bei **SSH-Schlüssel** auf den Schlüssel tippen. Das iPhone hat bereits einen
   erzeugt (ed25519). Dort **„Öffentlichen Schlüssel teilen“** wählen und ihn dir
   z. B. per **AirDrop an den Mac** oder in eine **Notiz** schicken.

   Der Schlüssel ist eine lange Zeile, die mit `ssh-ed25519 AAAA…` beginnt. Er ist
   nicht geheim, den „öffentlichen“ Teil darf man weitergeben.

## Schritt 2: Schlüssel im Container eintragen

Am Mac in der Proxmox-Oberfläche → Knoten → **Shell** (Host-Shell). Die Zeile
`ssh-ed25519 …` einfügen, in **einfache Anführungszeichen**, und `107` durch die
Nummer deines Scanner-Containers ersetzen:

```bash
pct exec 107 -- scan2nas-kurzbefehl schluessel 'ssh-ed25519 AAAA…dein-schluessel… Kurzbefehle'
```

Antwort: `✔ Schlüssel eingetragen. Er darf nur scannen …`

## Schritt 3: Testen

Zurück im Kurzbefehl auf ▶︎ tippen. Beim ersten Mal fragt das iPhone eventuell,
ob es dem Server vertrauen soll → **Ja**. Als Ergebnis siehst du:

```
Zustand: Idle
Einzug:  ScannerAdfEmpty
```

Klappt das, ist alles verbunden. 🎉

---

## Schritt 4: Den richtigen Kurzbefehl bauen

### Variante „Ein Knopf“ (am einfachsten)

Im Feld **Skript** einfach `einzug` eintragen. Dann noch eine Aktion
**Mitteilung anzeigen** dahinter und als Text die Variable **Shell-Skript-Ergebnis**
einsetzen. Kurzbefehl **„Scannen“** nennen, fertig.

### Variante „Mit Auswahl“

```
┌ Aus Menü auswählen  (Frage: „Was scannen?“)
│   • Einzug (mehrere Seiten)  →  Text: einzug
│   • Einzug in Farbe          →  Text: einzug farbe
│   • Glas (eine Seite)        →  Text: glas
│   • Foto (600 dpi)           →  Text: foto
└ Ende des Menüs
  Skript über SSH ausführen    →  Skript: [Menüergebnis]
  Mitteilung anzeigen          →  [Shell-Skript-Ergebnis]
```

So musst du die SSH-Aktion nur **einmal** einrichten. Das **Menüergebnis** gehört ins
Feld **Skript** (ins Feld tippen → oben „Variable auswählen“ → *Menüergebnis*), **nicht**
ins Feld „Eingabe“.

### Alle erlaubten Befehle

| Befehl | Was passiert |
|---|---|
| `einzug` | alle Seiten aus dem Einzug in ein PDF, Graustufen, mit Texterkennung |
| `einzug farbe` | dasselbe in Farbe |
| `glas` | eine Seite vom Vorlagenglas, Farbe |
| `glas grau` | eine Seite vom Vorlagenglas, Graustufen |
| `foto` | Vorlagenglas, Farbe, 600 dpi, ohne Texterkennung |
| `status` | ist der Scanner bereit, liegt Papier im Einzug? |

Groß-/Kleinschreibung ist egal. Alles andere wird abgelehnt.

---

## Ideen zum Starten

- **Siri:** „Hey Siri, Scannen“. Der Name des Kurzbefehls ist das Sprachkommando.
- **Home-Bildschirm:** im Kurzbefehl auf ⓘ → **Zum Home-Bildschirm**
- **Action-Taste** (iPhone 15 Pro und neuer): Einstellungen → Action-Taste → Kurzbefehl
- **Zurücktippen:** Einstellungen → Bedienungshilfen → Tippen → Auf Rückseite tippen
- **NFC-Aufkleber am Drucker:** Kurzbefehle → **Automation** → **NFC** → Aufkleber
  scannen → Kurzbefehl „Scannen“ ausführen. Papier einlegen, iPhone an den
  Aufkleber halten, fertig. (NFC-Aufkleber gibt es für ein paar Euro, z. B. NTAG215.)

---

## Gut zu wissen

- **Nur im Heimnetz:** Unterwegs erreicht das iPhone den Container nicht. Mit einem
  VPN nach Hause (z. B. WireGuard in der FRITZ!Box) geht es auch von unterwegs.
- **Der Kurzbefehl wartet**, bis der Scan fertig ist. Bei vielen Seiten mit
  Texterkennung kann das 1–2 Minuten dauern.
- **Schlüssel entfernen** (z. B. bei einem neuen iPhone): im Container in
  `/root/.ssh/authorized_keys` die passende Zeile löschen.
- **Ausprobieren ohne iPhone:** im Container `scan2nas-kurzbefehl einzug`

## Wenn es nicht klappt

| Meldung | Lösung |
|---|---|
| Verbindung abgelehnt / Zeitüberschreitung | Stimmt die IP? Läuft SSH im Container? `pct exec 107 -- systemctl status ssh` |
| Permission denied (publickey) | Schlüssel nicht (richtig) eingetragen → Schritt 2 wiederholen, die **ganze** Zeile in einfachen Anführungszeichen |
| `❌ Unbekannter Befehl` | Tippfehler im Feld *Skript*, erlaubt sind nur die Befehle aus der Tabelle |
| `❌ Scan fehlgeschlagen` + Grund | Grund lesen (z. B. „Liegt Papier im Einzug?“), sonst [Fehlerbehebung](04-fehlerbehebung.md) |
