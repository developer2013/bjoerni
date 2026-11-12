# 2. Ersteinrichtung

[← Installation](01-installation-proxmox.md) · [Übersicht](README.md) · [Weiter: FRITZ!Box →](03-fritzbox-und-router.md)

---

## 1. Der Einrichtungsassistent

Öffne im Browser **`http://192.168.178.53:3000`**. Die Oberfläche erscheint auf
Deutsch, wenn dein Browser auf Deutsch eingestellt ist. Ansonsten kannst du die
Sprache unten auf der Seite umstellen.

| Schritt | Was du siehst | Was du tust |
|---|---|---|
| 1 | **Willkommen bei AdGuard Home!** | **Anfangen** klicken |
| 2 | **Admin-Weboberfläche**: Netzwerk-Schnittstelle / Port | **Alle Schnittstellen**, Port **80** lassen |
|   | **DNS-Server**: Netzwerk-Schnittstelle / Port | **Alle Schnittstellen**, Port **53** lassen → **Weiter** |
| 3 | **Authentifizierung** | Benutzername (z. B. `admin`) und ein **gutes Passwort** → **Weiter** |
| 4 | **Konfigurieren Sie Ihre Geräte** | Nur lesen. Das machen wir zentral über die FRITZ!Box in [Kapitel 3](03-fritzbox-und-router.md) → **Weiter** |
| 5 | **Gratulation!** | **Übersicht öffnen** |

> **Ab jetzt** erreichst du AdGuard Home unter **`http://192.168.178.53`** (ohne `:3000`).
> Am besten gleich als Lesezeichen speichern.

Steht in Schritt 2 eine Warnung, dass Port 80 oder 53 belegt ist, sieh in der
[Fehlerbehebung](06-fehlerbehebung.md#port-53-oder-80-ist-belegt) nach.

---

## 2. DNS-Einstellungen

Das ist die wichtigste Seite: **Einstellungen → DNS-Einstellungen**.

### Upstream-DNS-Server

Hierhin schickt AdGuard alle Anfragen, die **nicht** blockiert werden. Wir nehmen
**verschlüsselte** Server (DNS-over-HTTPS). So kann dein Internetanbieter nicht
mitlesen, welche Seiten im Haushalt aufgerufen werden.

Lösch den Inhalt des Feldes und trag ein (eine Zeile pro Server):

```
https://dns.quad9.net/dns-query
https://unfiltered.joindns4.eu/dns-query
[/fritz.box/]192.168.178.1
```

| Zeile | Bedeutung |
|---|---|
| `dns.quad9.net` | **Quad9**: gemeinnützige Stiftung mit Sitz in der Schweiz, speichert keine IP-Adressen, blockt zusätzlich bekannte Schadseiten |
| `unfiltered.joindns4.eu` | **DNS4EU**: öffentlicher DNS-Dienst der EU, hier die ungefilterte Variante |
| `[/fritz.box/]192.168.178.1` | Namen wie `fritz.box` (die Oberfläche der FRITZ!Box) fragt AdGuard bei der FRITZ!Box selbst |

Darunter bei der Betriebsart **Lastverteilung** lassen. AdGuard nimmt dann
automatisch den Server, der gerade am schnellsten antwortet.

Unten auf **Upstreams testen** klicken. Beide Server sollten grün sein. Dann **Anwenden**.

> Lieber Cloudflare? Die Adresse wäre `https://cloudflare-dns.com/dns-query`.
> Schnell, aber ein US-Unternehmen. Für den Datenschutz sind Quad9 und DNS4EU die
> bessere Wahl.

### Bootstrap-DNS-Server

Um `dns.quad9.net` zu finden, braucht AdGuard einmal einen „normalen“ DNS-Server:

```
9.9.9.9
149.112.112.112
```

### Fallback-DNS-Server

Wird benutzt, falls **alle** Upstreams ausfallen. So bleibt das Internet auch dann
nutzbar:

```
9.9.9.9
```

### Private inverse DNS-Server

Damit AdGuard im Protokoll **Gerätenamen** statt nur IP-Adressen anzeigt
(z. B. „Björns-iPhone“ statt `192.168.178.34`), fragt es dafür die FRITZ!Box:

```
192.168.178.1
```

Darunter beide Haken setzen:

- ☑ **Private Reverse-DNS-Resolver verwenden**
- ☑ **Hostnamenauflösung der Clients aktivieren**

**Speichern.**

### DNS-Server-Konfiguration

Weiter unten auf derselben Seite:

| Einstellung | Wert | Warum |
|---|---|---|
| **Ratenlimit** | `20` lassen, **aber** siehe Hinweis | Schützt vor Geräten, die verrückt spielen |
| **DNSSEC aktivieren** | ☑ an | Prüft, ob DNS-Antworten unterwegs gefälscht wurden |
| **Sperrmodus** | Standard | Blockierte Adressen bekommen `0.0.0.0` als Antwort |

> **Wichtig zum Ratenlimit:** Lässt du später in [Kapitel 3](03-fritzbox-und-router.md#variante-b-die-fritzbox-fragt-adguard)
> die FRITZ!Box selbst bei AdGuard nachfragen (Variante B), kommen sehr viele
> Anfragen von nur einer Adresse. Trag dann `192.168.178.1` unter **Freigabeliste
> für die Ratebegrenzung** ein. Sonst bremst AdGuard die FRITZ!Box aus und Seiten
> laden manchmal nicht.

**Konfiguration des DNS-Cache:** Die Vorgaben passen.

---

## 3. Allgemeine Einstellungen

**Einstellungen → Allgemeine Einstellungen**

| Einstellung | Empfehlung | Warum |
|---|---|---|
| Filter aktualisieren | alle 24 Stunden | Sperrlisten bleiben aktuell |
| **AdGuard Webservice für Internetsicherheit nutzen** | ☑ an | Warnt vor Phishing- und Schadseiten |
| **AdGuard Webservice für Kindersicherung verwenden** | aus (oder nur für einzelne Geräte, siehe [Kapitel 4](04-filter-und-clients.md#geräte-einzeln-einstellen)) | Würde sonst für alle gelten |
| **Sichere Suche verwenden** | aus (dito) | |
| **Rotation der Abfrageprotokolle** | 7 Tage | Reicht zur Fehlersuche, respektiert die Privatsphäre aller im Haushalt |
| **Statistiken speichern** | 30 Tage | Für die schönen Grafiken auf der Übersicht |

> **Privatsphäre:** Im Abfrageprotokoll sieht man, welches Gerät wann welche Seite
> aufruft. Sag deiner Familie bzw. deinen Mitbewohnern Bescheid, dass es AdGuard
> gibt, und halt die Speicherdauer kurz.

---

## 4. Schon mal testen (vor der FRITZ!Box-Umstellung)

Noch nutzt kein Gerät AdGuard. Du kannst es aber gezielt fragen. Auf einem PC:

**Windows** (Eingabeaufforderung):

```
nslookup doubleclick.net 192.168.178.53
nslookup wikipedia.org 192.168.178.53
```

**Mac / Linux** (Terminal):

```bash
dig @192.168.178.53 doubleclick.net +short    # → 0.0.0.0  (blockiert ✅)
dig @192.168.178.53 wikipedia.org +short      # → echte IP-Adresse ✅
```

`doubleclick.net` (Google-Werbung) muss `0.0.0.0` liefern, `wikipedia.org` eine
echte Adresse. Dann funktioniert AdGuard. In der **Übersicht** siehst du die
beiden Anfragen. 🎉

Weiter mit **[3. FRITZ!Box und andere Router](03-fritzbox-und-router.md)**.
