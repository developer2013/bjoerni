# 3. FRITZ!Box und andere Router

[← Ersteinrichtung](02-ersteinrichtung.md) · [Übersicht](README.md) · [Weiter: Filter und Geräte →](04-filter-und-clients.md)

Jetzt sorgen wir dafür, dass **alle Geräte automatisch AdGuard benutzen**. Du musst
dafür kein einziges Gerät anfassen. Die FRITZ!Box teilt es ihnen mit.

Es gibt zwei Varianten, die sich gut ergänzen:

| | Variante A: Geräte fragen AdGuard direkt | Variante B: FRITZ!Box fragt AdGuard |
|---|---|---|
| Wie | FRITZ!Box sagt per DHCP: „Euer DNS-Server ist AdGuard“ | Geräte fragen weiter die FRITZ!Box, die leitet an AdGuard weiter |
| Statistik pro Gerät | ✅ ja | ❌ alles erscheint als „FRITZ!Box“ |
| Regeln pro Gerät (Kindersicherung) | ✅ möglich | ❌ nicht möglich |
| Gastnetz wird gefiltert | ❌ nein | ✅ ja |
| Aufwand | etwas mehr (IPv6) | sehr gering |

**Empfehlung:** Variante A einrichten. Wer zusätzlich das Gastnetz filtern oder
ganz sicher gehen will, dass nichts an AdGuard vorbeigeht, nimmt Variante B dazu.

---

## Variante A: Geräte fragen AdGuard direkt

### Schritt 1: IPv4

FRITZ!Box-Oberfläche (`http://fritz.box`) → **Heimnetz → Netzwerk → Netzwerkeinstellungen**
→ ganz unten **weitere Einstellungen** bzw. **IPv4-Einstellungen**:

- **Lokaler DNS-Server:** `192.168.178.53`

**OK / Übernehmen.** Die FRITZ!Box fragt eventuell nach einer Bestätigung am Gerät
oder per App.

### Schritt 2: IPv6 (nicht überspringen!)

Fast alle Anschlüsse in Deutschland haben heute IPv6. Wenn du nur Schritt 1 machst,
fragen viele Geräte **über IPv6 weiter die FRITZ!Box** und die Werbung kommt durch.

**2a. Die FRITZ!Box soll feste lokale IPv6-Adressen verteilen.**
*Heimnetz → Netzwerk → Netzwerkeinstellungen → IPv6-Einstellungen*:

- **Unique Local Addresses (ULA) immer zuweisen:** auswählen
- Übernehmen

**2b. Die IPv6-Adresse von AdGuard herausfinden.**
Container kurz neu starten (Proxmox: Container → *Neustart*), damit er eine ULA
bekommt. Dann in der Konsole des AdGuard-Containers:

```bash
ip -6 addr show eth0 | grep "inet6 fd"
```

Ausgabe zum Beispiel:

```
inet6 fd00::be24:11ff:fe2a:7c3d/64 scope global dynamic mngtmpaddr
```

Die Adresse ist der Teil **vor** dem `/64`, hier `fd00::be24:11ff:fe2a:7c3d`.
Steht `temporary` dahinter, nimm die andere Zeile.
(Kommt gar nichts? Dann hat der Container kein IPv6. Proxmox → Container → *Netzwerk*
→ `eth0` bearbeiten → **IPv6: SLAAC** → Neustart.)

**2c. Diese Adresse in der FRITZ!Box eintragen.**
Wieder unter *IPv6-Einstellungen*, weiter unten bei **DNSv6-Server im Heimnetz**:

- ☑ **DNSv6-Server auch über Router Advertisement bekanntgeben (RFC 5006)**
- **Lokaler DNSv6-Server:** `fd00::be24:11ff:fe2a:7c3d` (deine Adresse aus 2b)

Übernehmen.

### Schritt 3: Geräte neu verbinden

Die Geräte übernehmen den neuen DNS-Server erst beim nächsten Verbinden:

- **Handy/Tablet:** WLAN aus- und wieder einschalten
- **Windows:** `ipconfig /renew` in der Eingabeaufforderung, oder neu starten
- **Mac:** WLAN aus/ein
- **Smart-TV, Konsole:** einmal ganz vom Strom (oder bis morgen warten)

### Schritt 4: Prüfen

In AdGuard → **Abfrageprotokoll**: Dort tauchen jetzt deine Geräte auf, mit Namen,
dank der Einstellung aus Kapitel 2.

Am PC zur Kontrolle:

```
nslookup doubleclick.net
```

Bei *Server* muss die AdGuard-Adresse stehen (`192.168.178.53` oder die `fd00::…`),
bei *Address* `0.0.0.0`. ✅

---

## Variante B: Die FRITZ!Box fragt AdGuard

Damit landen auch Anfragen bei AdGuard, die an der FRITZ!Box ankommen, etwa aus dem
**Gastnetz** oder von Geräten, die stur die FRITZ!Box fragen.

*Internet → Zugangsdaten → **DNS-Server***:

- **DNSv4-Server:** ☑ **Andere DNSv4-Server verwenden**
  - Bevorzugter DNSv4-Server: `192.168.178.53`
  - Alternativer DNSv4-Server: `192.168.178.53`
    (oder einen öffentlichen wie `9.9.9.9`, siehe Kasten unten)
- **DNSv6-Server:** ☑ **Andere DNSv6-Server verwenden** → beide Felder: deine
  `fd00::…`-Adresse von AdGuard
- **Verschlüsselte Namensauflösung im Internet (DNS over TLS):** ☐ **aus**.
  AdGuard verschlüsselt die Anfragen selbst. Bleibt der Haken an, kann die FRITZ!Box
  AdGuard nicht erreichen.

Übernehmen. Dann **in AdGuard** unter *Einstellungen → DNS-Einstellungen →
Freigabeliste für die Ratebegrenzung* die `192.168.178.1` eintragen
([warum](02-ersteinrichtung.md#dns-server-konfiguration)).

> **Bevorzugt und alternativ gleich oder verschieden?**
> Beide auf AdGuard heißt: lückenlose Filterung, aber fällt AdGuard aus, hat das
> ganze Haus kein Internet.
> Alternativ `9.9.9.9` heißt: Bei einem Ausfall läuft das Internet weiter (ohne
> Filter), dafür rutscht ab und zu eine Anfrage an AdGuard vorbei.
> Für einen Familienhaushalt ist die zweite Variante oft entspannter.

> ⚠️ **Keine Schleife bauen:** AdGuard darf die FRITZ!Box nie als normalen
> Upstream benutzen, sonst fragen sich beide gegenseitig im Kreis. Die Zeile
> `[/fritz.box/]192.168.178.1` und die privaten inversen DNS-Server aus Kapitel 2
> sind in Ordnung. Für diese Namen antwortet die FRITZ!Box selbst.

---

## Andere Router

Das Prinzip ist überall gleich: In den **DHCP-Einstellungen** des Routers den
**DNS-Server** auf `192.168.178.53` (bzw. deine AdGuard-Adresse) setzen.

| Router | Wo suchen |
|---|---|
| Telekom Speedport | Heimnetz → DHCP bzw. Netzwerk → DNS |
| Vodafone Station / Kabelrouter | oft nicht änderbar, dann Variante B nicht möglich → AdGuard-DHCP (siehe unten) |
| UniFi | Settings → Networks → Netz auswählen → DHCP → DNS Server: manuell |
| OPNsense / pfSense | Services → DHCPv4 → DNS servers |

**Router ohne einstellbaren DNS-Server:** Dann kann AdGuard selbst die Adressen
verteilen (*Einstellungen → DHCP-Einstellungen*). Dafür muss der DHCP-Server des
Routers **ausgeschaltet** werden, und AdGuard kennzeichnet die Funktion noch als
„experimentell“. Nur machen, wenn es nicht anders geht.

---

## Notfallplan: AdGuard ist aus

**Woran merkt man es?** Webseiten laden nicht, Apps sagen „keine Verbindung“, das
WLAN-Symbol ist aber voll.

**Schnellste Lösung:** Container wieder starten, in Proxmox → Container *adguard*
→ **Start**. Nach 10 Sekunden geht alles wieder.

**Wenn das nicht geht** (Proxmox selbst ist aus oder kaputt): In der FRITZ!Box die
Umstellung rückgängig machen. Die Oberfläche erreichst du auch ohne DNS unter
**`http://192.168.178.1`**:

1. *Heimnetz → Netzwerk → Netzwerkeinstellungen → IPv4-Einstellungen*:
   **Lokaler DNS-Server** → `192.168.178.1`
2. *IPv6-Einstellungen*: Haken bei **„DNSv6-Server auch über Router Advertisement
   bekanntgeben“** entfernen
3. Falls Variante B eingerichtet: *Internet → Zugangsdaten → DNS-Server* →
   **„DNSv4-Server vom Internetanbieter verwenden“** und dasselbe für DNSv6
4. Geräte neu verbinden (WLAN aus/ein)

> 💡 Tipp: Druck dir diesen Abschnitt aus und häng ihn neben den Router. Dann kann
> auch jemand anderes im Haushalt das Internet retten, wenn du nicht da bist.

Weiter mit **[4. Filter, Geräte und eigene Namen](04-filter-und-clients.md)**.
