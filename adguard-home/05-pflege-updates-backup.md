# 5. Pflege: Updates und Backup

[← Filter und Geräte](04-filter-und-clients.md) · [Übersicht](README.md) · [Weiter: Fehlerbehebung →](06-fehlerbehebung.md)

---

## AdGuard Home aktualisieren

Gibt es eine neue Version, erscheint oben in der Weboberfläche ein Hinweis
**„AdGuard Home … ist jetzt verfügbar!“**. Draufklicken, bestätigen, fertig.
AdGuard aktualisiert sich selbst und startet neu. Das DNS ist dabei nur wenige
Sekunden weg.

Selbst nachschauen: In der **Übersicht** unten bzw. über
**Jetzt nach Aktualisierungen suchen**.

> Beim Debian-Container aus dem Community Script ist die Weboberfläche **der**
> Update-Weg. Das Script selbst aktualisiert AdGuard dort nicht. (Nur bei Alpine
> kann man im Container auch `update` eintippen.)

## Den Container aktualisieren (Debian)

Etwa einmal im Monat, in der Konsole des AdGuard-Containers:

```bash
apt update && apt full-upgrade -y
```

---

## Backup

### 1. Proxmox-Backup (empfohlen, sichert alles)

*Rechenzentrum → **Backup** → Hinzufügen*:

| Feld | Empfehlung |
|---|---|
| Speicher | Ein Backup-Speicher, idealerweise auf dem NAS (*Rechenzentrum → Storage → Hinzufügen → SMB/CIFS* bzw. NFS, Inhalt „VZDump Backup“) |
| Zeitplan | z. B. `sun 03:00` (sonntags 3 Uhr) |
| Auswahl | den AdGuard-Container (gern auch scan2nas und Co.) |
| Modus | **Snapshot** (Container läuft weiter) |
| Aufbewahrung | z. B. *Behalte letzte*: 4 |

Wiederherstellen: Speicher anklicken → *Backups* → Sicherung auswählen →
**Wiederherstellen**.

### 2. Nur die Einstellungen sichern

Alle AdGuard-Einstellungen, Listen, Clients und Umschreibungen stehen in **einer**
Datei: `/opt/AdGuardHome/AdGuardHome.yaml`. Auf den Proxmox-Host kopieren
(`<ID>` = Container-Nummer):

```bash
pct pull <ID> /opt/AdGuardHome/AdGuardHome.yaml /root/AdGuardHome-$(date +%F).yaml
```

Zurückspielen:

```bash
pct exec <ID> -- systemctl stop AdGuardHome
pct push <ID> /root/AdGuardHome-2026-11-12.yaml /opt/AdGuardHome/AdGuardHome.yaml
pct exec <ID> -- systemctl start AdGuardHome
```

> Die Datei enthält dein (verschlüsseltes) Admin-Passwort. Behandle sie wie ein
> Passwort, also nicht öffentlich teilen.

---

## Passwort vergessen

In der Konsole des AdGuard-Containers:

```bash
apt install -y apache2-utils
htpasswd -B -C 10 -n -b admin MeinNeuesPasswort
```

Ausgabe zum Beispiel: `admin:$2y$10$Ab3...xyz`. Den Teil **nach** dem Doppelpunkt
brauchst du. Dann:

```bash
systemctl stop AdGuardHome
nano /opt/AdGuardHome/AdGuardHome.yaml
```

Ganz oben bei `users:` den Wert hinter `password:` durch den neuen ersetzen:

```yaml
users:
  - name: admin
    password: $2y$10$Ab3...xyz
```

Speichern (`Strg+O`, `Enter`, `Strg+X`) und:

```bash
systemctl start AdGuardHome
```

---

## Für Fortgeschrittene: ein zweiter AdGuard

Fällt der eine AdGuard aus, steht das Internet im ganzen Haus. Ein zweiter
AdGuard (z. B. auf einem anderen Proxmox-Knoten oder einem Raspberry Pi) macht das
Ganze ausfallsicher. Gleich bleiben die Einstellungen mit dem Werkzeug
[adguardhome-sync](https://github.com/bakito/adguardhome-sync).

**Aber:** Die FRITZ!Box verteilt per DHCP nur **einen** lokalen DNS-Server. Echte
Ausfallsicherheit gibt es deshalb nur mit
[Variante B](03-fritzbox-und-router.md#variante-b-die-fritzbox-fragt-adguard)
(bevorzugt AdGuard 1, alternativ AdGuard 2) oder mit einem anderen DHCP-Server.
Für die meisten Haushalte reichen **Startreihenfolge + Backup + Notfallplan**
völlig aus.

Weiter mit **[6. Fehlerbehebung](06-fehlerbehebung.md)**.
