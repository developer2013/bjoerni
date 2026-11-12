# 1. Installation auf Proxmox

[← Übersicht](README.md) · [Weiter: Ersteinrichtung →](02-ersteinrichtung.md)

Wir nutzen das bewährte **Community Script** für AdGuard Home. Es legt einen
kleinen, unprivilegierten LXC-Container an und installiert AdGuard Home darin.

> ⚡ **Abkürzung:** Der [Einzeiler aus der Übersicht](README.md#der-schnellste-weg-ein-befehl-)
> erledigt dieses und das nächste Kapitel automatisch. Er kann auch einen per
> Community Script angelegten AdGuard fertig einrichten.

---

## 1. Vorher klären: Welche IP bekommt AdGuard?

Ein DNS-Server braucht eine **feste IP-Adresse**. Alle Geräte merken sich diese
Adresse, und ändert sie sich, geht nichts mehr. Such dir eine freie Adresse aus,
in dieser Anleitung `192.168.178.53`.

Damit die FRITZ!Box diese Adresse nicht an ein anderes Gerät vergibt, nimm am
besten eine Adresse **außerhalb des DHCP-Bereichs**. Den Bereich siehst du in der
FRITZ!Box unter *Heimnetz → Netzwerk → Netzwerkeinstellungen → IPv4-Einstellungen*.
Standard ist `.20` bis `.200`. Eine Adresse wie `.53` liegt also mitten drin, ist
aber in Ordnung, solange sie gerade frei ist und du sie in der FRITZ!Box fest
zuordnest (siehe [Abschnitt 3](#3-feste-ip-in-der-fritzbox-absichern)).
Wer ganz sicher gehen will, nimmt eine Adresse über `.200`, z. B. `192.168.178.253`.

---

## 2. Container anlegen

Proxmox-Oberfläche → links deinen **Knoten** anklicken → **Shell**:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/adguard.sh)"
```

> Das Script stammt von den [Proxmox VE Community Scripts](https://community-scripts.github.io/ProxmoxVE/),
> einer großen, gepflegten Sammlung. Ansehen kannst du es vorher so:
> `curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/adguard.sh | less`

Das Script führt dich durch einige Fenster. Die Bezeichnungen sind englisch und
ändern sich gelegentlich ein wenig. Achte auf diese Punkte:

| Frage im Script | Empfehlung | Warum |
|---|---|---|
| **Container OS** | `debian` (Debian 13) | Wie dein scan2nas-Container, viel Hilfe im Netz. *Alpine* ginge auch (noch kleiner) |
| **Default / Advanced** | **Advanced** (erweitert) | Nur so kannst du eine feste IP eintragen |
| Container Type | Unprivileged | Sicherer, ist Standard |
| Root Password | ein Passwort vergeben **oder** leer lassen | Leer = automatische Anmeldung in der Proxmox-Konsole |
| Container ID / Hostname | z. B. `adguard` | Frei wählbar |
| Disk / CPU / RAM | `2` GB / `1` Kern / `512` MB | Die Vorgaben reichen locker |
| Bridge | `vmbr0` | Wie deine anderen Container |
| **IPv4** | **static**: `192.168.178.53/24` | Feste Adresse, `/24` nicht vergessen! |
| **Gateway** | `192.168.178.1` | Die FRITZ!Box |
| **IPv6** | **SLAAC** (bzw. *auto*) | Damit AdGuard eine IPv6-Adresse bekommt, die braucht Kapitel 3 |
| DNS Server / Search Domain | leer lassen | Übernimmt die Einstellung vom Host |
| SSH | nach Wunsch | Brauchst du nicht unbedingt, die Proxmox-Konsole reicht |
| Verbose Mode | No | |

Zum Schluss fragt das Script nach einer Bestätigung und baut den Container. Das
dauert 1–3 Minuten. Am Ende steht da:

```
Adguard setup has been successfully initialized!
Access it using the following URL:
http://192.168.178.53:3000
```

Diese Adresse brauchst du gleich in [Kapitel 2](02-ersteinrichtung.md). ✅

### Was das Script eingerichtet hat

| Was | Wo |
|---|---|
| Programm und Einstellungen | `/opt/AdGuardHome/` (Einstellungen: `AdGuardHome.yaml`) |
| Dienst | `AdGuardHome.service` (`systemctl status AdGuardHome`) |
| Logdateien | `/var/log/AdGuardHome.out` und `/var/log/AdGuardHome.err` |

---

## 3. Feste IP in der FRITZ!Box absichern

Der Container hat seine IP fest eingestellt. Damit die FRITZ!Box sie trotzdem nie
einem anderen Gerät gibt:

*Heimnetz → Netzwerk → Netzwerkverbindungen* → den Eintrag **adguard** suchen → Stift
→ Haken bei **„Diesem Netzwerkgerät immer die gleiche IPv4-Adresse zuweisen“** →
Übernehmen.

(Taucht der Container dort nicht auf, ist das auch kein Drama. Dann nimm künftig
einfach keine `.53` für ein anderes Gerät.)

---

## 4. Startreihenfolge: AdGuard zuerst

Ohne DNS kommen andere Container und Geräte nicht ins Internet. AdGuard soll deshalb
**als Erstes** starten, und zwar automatisch nach jedem Neustart von Proxmox.

In der Proxmox-Oberfläche: Container **adguard** → **Optionen**:

- **Beim Booten starten:** Ja
- **Start/Shutdown-Reihenfolge:** Reihenfolge `1`, Startverzögerung `15`

Oder in der Shell des Proxmox-Hosts (`<ID>` = Nummer des Containers, z. B. `110`):

```bash
pct set <ID> --onboot 1 --startup order=1,up=15
```

`up=15` heißt: Nach AdGuard wartet Proxmox 15 Sekunden, bevor der nächste Gast
startet. Bis dahin ist AdGuard bereit.

---

## 5. Kurzer Test

In der Proxmox-Shell (auf dem Host):

```bash
pct exec <ID> -- systemctl is-active AdGuardHome     # → active
```

Weiter mit **[2. Ersteinrichtung](02-ersteinrichtung.md)**.

---

### Alternative ohne Community Script

Falls du lieber alles selbst machst: Debian-13-Container anlegen (unprivilegiert,
512 MB RAM, 2 GB Platte, feste IP), dann im Container:

```bash
apt update && apt install -y curl
curl -s -S -L https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh | sh -s -- -v
```

Das ist das offizielle Installationsskript von AdGuard. Es installiert nach
`/opt/AdGuardHome` und richtet den Dienst ein. Danach geht es genauso weiter mit
Kapitel 2.
