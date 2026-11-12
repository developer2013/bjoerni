# 6. Fehlerbehebung

[← Pflege](05-pflege-updates-backup.md) · [Übersicht](README.md)

---

## Kein Internet mehr (nirgends)

Fast immer heißt das: **AdGuard läuft nicht** oder ist nicht erreichbar.

1. Proxmox → Container *adguard*: läuft er? Wenn nicht: **Start**
2. Läuft er, aber der Dienst nicht? In der Konsole des Containers:
   ```bash
   systemctl status AdGuardHome
   systemctl restart AdGuardHome
   tail -n 50 /var/log/AdGuardHome.err
   ```
3. Kommt AdGuard selbst ins Internet? In der Container-Konsole:
   `ping -c3 9.9.9.9`. Klappt das nicht, stimmt die Netzwerkeinstellung des
   Containers nicht (IP, Gateway).
4. In AdGuard *Einstellungen → DNS-Einstellungen → **Upstreams testen***: Sind
   die Server grün? Wenn nicht, die Uhrzeit des Proxmox-Hosts prüfen (`date`).
   Verschlüsseltes DNS funktioniert nicht mit falscher Uhrzeit.
5. Nichts hilft? Den [Notfallplan](03-fritzbox-und-router.md#notfallplan-adguard-ist-aus)
   ausführen. Dann läuft das Internet ohne AdGuard weiter, und du kannst in Ruhe suchen.

---

## Werbung wird trotzdem angezeigt

| Ursache | Prüfen / Lösung |
|---|---|
| Gerät nutzt AdGuard (noch) nicht | Gerät taucht nicht im *Abfrageprotokoll* auf → WLAN aus/ein, `ipconfig /renew` |
| **IPv6** geht an AdGuard vorbei | Das ist der häufigste Grund! Kapitel 3, [Schritt 2 (IPv6)](03-fritzbox-und-router.md#schritt-2-ipv6-nicht-überspringen) prüfen. `nslookup doubleclick.net` muss bei *Server* AdGuard zeigen |
| Browser nutzt eigenes DNS | „Sicheres DNS“ / „DNS über HTTPS“ abschalten, siehe [Kapitel 4](04-filter-und-clients.md#was-adguard-nicht-kann-und-wie-man-lücken-schließt) |
| Gerät hat die Antwort noch im Speicher | Ein paar Minuten warten oder Browser neu starten |
| Werbung in YouTube/Twitch | Geht mit DNS grundsätzlich nicht, siehe [Kapitel 4](04-filter-und-clients.md#was-adguard-nicht-kann-und-wie-man-lücken-schließt) |
| Schutz ist pausiert | In der *Übersicht* oben rechts: **Schutz aktivieren** |

---

## Eine Seite oder App funktioniert nicht mehr

→ [Kapitel 4: freigeben](04-filter-und-clients.md#wenn-etwas-nicht-funktioniert-freigeben)

Schnelltest, ob AdGuard schuld ist: In der *Übersicht* **Schutz deaktivieren**
(z. B. für 1 Minute), dann die Seite neu laden. Geht sie dann, ist es ein Filter.
Im Abfrageprotokoll den roten Eintrag suchen und entsperren.

---

## Alle Anfragen kommen von der FRITZ!Box

Dann ist [Variante B](03-fritzbox-und-router.md#variante-b-die-fritzbox-fragt-adguard)
aktiv, aber Variante A nicht (oder nur für IPv4). Für eine Statistik pro Gerät
[Variante A](03-fritzbox-und-router.md#variante-a-geräte-fragen-adguard-direkt)
vollständig einrichten, inklusive IPv6.

---

## Seiten laden manchmal sehr langsam oder gar nicht (mit Variante B)

Das ist das **Ratenlimit**. Die FRITZ!Box schickt alle Anfragen des Hauses von
einer Adresse. In AdGuard die `192.168.178.1` unter *Einstellungen →
DNS-Einstellungen → Freigabeliste für die Ratebegrenzung* eintragen.

---

## Gerätenamen fehlen im Protokoll (nur IP-Adressen)

*Einstellungen → DNS-Einstellungen → **Private inverse DNS-Server***:
`192.168.178.1` eintragen, **Private Reverse-DNS-Resolver verwenden** und
**Hostnamenauflösung der Clients aktivieren** anhaken
([Kapitel 2](02-ersteinrichtung.md#private-inverse-dns-server)).

---

## `fritz.box` öffnet sich nicht mehr

In den Upstream-DNS-Servern fehlt die Zeile `[/fritz.box/]192.168.178.1`
([Kapitel 2](02-ersteinrichtung.md#upstream-dns-server)). Die FRITZ!Box erreichst du
immer auch direkt über `http://192.168.178.1`.

---

## Weboberfläche nicht erreichbar

- Nach dem Assistenten läuft sie auf **Port 80**: `http://192.168.178.53`,
  **nicht** mehr auf `:3000`
- Läuft der Dienst? `systemctl status AdGuardHome` im Container
- Hast du im Assistenten einen anderen Port gewählt? Nachsehen:
  `grep -A3 "^http:" /opt/AdGuardHome/AdGuardHome.yaml`

---

## Port 53 oder 80 ist belegt

Kommt im Assistenten die Meldung, dass ein Port schon benutzt wird, im Container
nachsehen, wer ihn belegt:

```bash
ss -tulpn | grep -E ':53 |:80 '
```

- **systemd-resolved** auf Port 53: `systemctl disable --now systemd-resolved`
- Ein Webserver auf Port 80: im Assistenten einfach einen anderen Port für die
  Weboberfläche nehmen, z. B. `8080`

Im frischen Container aus dem Community Script ist normalerweise beides frei.

---

## Wo stehen die Logs?

| Was | Befehl (in der Container-Konsole) |
|---|---|
| Programm-Meldungen | `tail -f /var/log/AdGuardHome.err` |
| Dienst-Status | `systemctl status AdGuardHome` |
| Welche Seiten wurden gefragt/blockiert | Weboberfläche → **Abfrageprotokoll** |
