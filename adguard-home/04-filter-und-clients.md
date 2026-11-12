# 4. Filter, Geräte und eigene Namen

[← FRITZ!Box](03-fritzbox-und-router.md) · [Übersicht](README.md) · [Weiter: Pflege →](05-pflege-updates-backup.md)

---

## Sperrlisten (DNS-Blocklisten)

Eine Sperrliste ist eine Liste bekannter Werbe-, Tracking- und Schadadressen.
Ab Werk ist der **AdGuard DNS filter** aktiv, ein guter Anfang.

### Empfohlene Ergänzung

**Filter → DNS-Blocklisten → Blockliste hinzufügen → Aus Liste auswählen** und dort
**eine** dieser Listen anhaken:

| Liste | Für wen |
|---|---|
| **HaGeZi's Normal Blocklist** | Familienhaushalt: blockt viel, macht fast nie etwas kaputt |
| **HaGeZi's Pro Blocklist** ⭐ | Die beliebte Mitte: deutlich mehr Tracker weg, ab und zu muss man etwas freigeben |
| HaGeZi's Pro++ / Ultimate | Für Fans. Hier geht öfter mal etwas nicht |
| OISD Blocklist Small / Big | Gute Alternative zu HaGeZi, Big entspricht etwa „Pro“ |

Zusätzlich sinnvoll, macht praktisch nie Probleme:

- **HaGeZi's Threat Intelligence Feeds**: Phishing, Schadsoftware, Betrugsseiten

> **Mehr ist nicht besser.** Die großen Listen überschneiden sich stark. Wer fünf
> Listen stapelt, bekommt kaum mehr Schutz, aber deutlich mehr kaputte Seiten.
> **AdGuard DNS filter + eine HaGeZi-Liste + Threat Intelligence** ist eine sehr
> gute Kombination.

---

## Wenn etwas nicht funktioniert: freigeben

Irgendwann klappt eine Seite oder App nicht mehr, weil AdGuard etwas blockt, das
sie braucht. Typische Fälle: Links in Newslettern, „Gesponsert“-Links bei Google,
Gutschein- und Vergleichsseiten, manche Smart-TV-Apps.

**So findest du den Übeltäter:**

1. **Abfrageprotokoll** öffnen
2. Oben nach dem Gerät oder der Seite filtern, oder einfach die Seite/App noch
   einmal aufrufen und schauen, was ganz oben **rot** erscheint
3. Beim roten Eintrag auf **Entsperren** klicken
4. Seite neu laden. Hilft das nicht, war es der falsche Eintrag: zurück zu Schritt 2

**Eigene Regeln** unter *Filter → Benutzerdefinierte Filterregeln*:

```
! Zeilen mit ! sind Kommentare
! Freigeben (@@ am Anfang):
@@||beispiel-newsletter.de^

! Zusätzlich sperren:
||nervige-seite.example^
```

---

## Geräte einzeln einstellen

AdGuard erkennt Geräte an ihrer IP-Adresse. Damit du Regeln pro Gerät festlegen
kannst, legst du sie als **Persistente Clients** an:
*Einstellungen → Client-Einstellungen → **Client hinzufügen***

| Feld | Beispiel |
|---|---|
| Name | `Tablet Kinderzimmer` |
| Bezeichner | IP-Adresse (z. B. `192.168.178.40`) **oder** MAC-Adresse |
| Einstellungen | Haken bei **Allgemeine Einstellungen nutzen** entfernen und gezielt einschalten: |
| | ☑ **AdGuard Webservice für Kindersicherung verwenden** (blockt Erwachseneninhalte) |
| | ☑ **Sichere Suche verwenden** (Google, Bing, YouTube … filtern anstößige Ergebnisse) |
| Gesperrte Dienste | z. B. TikTok, Instagram, Spiele, auf Wunsch mit Zeitplan |

> **Wichtig:** Damit die IP eines Geräts gleich bleibt, in der FRITZ!Box beim Gerät
> „Immer die gleiche IPv4-Adresse zuweisen“ anhaken. Das klappt nur mit
> [Variante A](03-fritzbox-und-router.md#variante-a-geräte-fragen-adguard-direkt).
> Bei Variante B sieht AdGuard nur die FRITZ!Box.

---

## Eigene Namen statt IP-Adressen (DNS-Umschreibungen)

Statt `http://192.168.178.60:8080` für die Scanner-Oberfläche kannst du einfach
**`http://scanner.lan:8080`** eintippen. Dafür: *Filter → **DNS-Umschreibungen** →
DNS-Umschreibung hinzufügen*

| Domain | Antwort | Wofür |
|---|---|---|
| `scanner.lan` | `192.168.178.60` | Weboberfläche von [scan2nas](../README.md) → `http://scanner.lan:8080` |
| `drucker.lan` | `192.168.178.50` | Canon TR8550 (Druckerseite) → `http://drucker.lan` |
| `adguard.lan` | `192.168.178.53` | AdGuard selbst → `http://adguard.lan` |
| `proxmox.lan` | `192.168.178.5` | Proxmox → `https://proxmox.lan:8006` |
| `nas.lan` | IP deines NAS | NAS-Oberfläche |

Das funktioniert auf allen Geräten, die AdGuard benutzen. Nach dem Speichern
sofort, ganz ohne Neustart.

> **Warum `.lan`?** Die Endung gibt es im Internet nicht, also gibt es keine
> Verwechslung. „Offiziell“ für Heimnetze vorgesehen sind `.home.arpa` und
> `.internal`, die funktionieren genauso, sind nur länger zu tippen.
> **Nicht** `.local` verwenden, das ist für Apple/Bonjour reserviert und führt zu
> merkwürdigen Fehlern.

---

## Was AdGuard nicht kann (und wie man Lücken schließt)

Manche Geräte und Browser umgehen deinen DNS-Server absichtlich:

| Was | Wo abschalten |
|---|---|
| **Chrome/Edge „Sicheres DNS“** | Einstellungen → Datenschutz und Sicherheit → Sicherheit → *Sicheres DNS verwenden* → aus (oder „Mit Ihrem aktuellen Dienstanbieter“) |
| **Firefox „DNS über HTTPS“** | Einstellungen → Datenschutz & Sicherheit → *DNS über HTTPS* → Standardschutz/aus |
| **Android „Privates DNS“** | Einstellungen → Netzwerk & Internet → *Privates DNS* → Aus oder Automatisch |
| **iPhone „iCloud Privat-Relay“** | Einstellungen → [Name] → iCloud → *Privat-Relay*. Für das Heim-WLAN kann man es beim WLAN-Netz abschalten |

Für Fortgeschrittene gibt es die Liste **HaGeZi's Encrypted DNS/VPN/TOR/Proxy Bypass**.
Sie blockt solche Umgehungen netzweit, kann aber auch gewollte VPNs (z. B. Firmen-VPN)
stören.

**Werbung in YouTube- und Twitch-Videos** kommt vom selben Server wie die Videos
selbst. Die kann **kein** DNS-Filter blocken, dafür braucht es einen Werbeblocker im
Browser (z. B. uBlock Origin).

Weiter mit **[5. Pflege: Updates und Backup](05-pflege-updates-backup.md)**.
