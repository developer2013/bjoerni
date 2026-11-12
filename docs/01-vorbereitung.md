# 1. Vorbereitung

Bevor du das Installationsskript startest, brauchst du vier Dinge:

1. [Feste IP-Adresse für den Scanner](#1-feste-ip-adresse-für-den-scanner)
2. [Eine Freigabe auf dem NAS](#2-freigabe-auf-dem-nas)
3. [Einen Blick auf Proxmox](#3-proxmox)
4. [Zugriff auf dieses Repository](#4-zugriff-auf-dieses-repository)

---

## 1. Feste IP-Adresse für den Scanner

Der Container spricht den Scanner direkt über seine IP-Adresse an. Ändert sich
die Adresse (z. B. nach einem Router-Neustart), findet er ihn nicht mehr. Deshalb
sollte der Scanner **im Router immer dieselbe Adresse** bekommen.

**FRITZ!Box:** *Heimnetz → Netzwerk → Netzwerkverbindungen* → beim Drucker auf
den Stift klicken → Haken bei **„Diesem Netzwerkgerät immer die gleiche
IPv4-Adresse zuweisen“** → Übernehmen.
Bei anderen Routern heißt das meist „DHCP-Reservierung“ oder „statische Zuweisung“.

Die aktuelle IP-Adresse siehst du im Router oder am Drucker selbst
(Display: *Einstellungen → LAN-Einstellungen*, je nach Firmware leicht anders benannt).

### Prüfen, ob der Scanner per eSCL erreichbar ist

Öffne im Browser (am PC im selben Netz):

```
http://<SCANNER-IP>/eSCL/ScannerCapabilities
```

Siehst du eine lange XML-Seite mit Einträgen wie `<scan:Platen>` (Vorlagenglas)
und `<scan:Adf>` (Einzug), ist alles bereit. ✅

Kommt eine Fehlermeldung, öffne `http://<SCANNER-IP>/`, also die Weboberfläche
des Druckers. Prüfe dort in den LAN-Einstellungen, ob **Bonjour/AirPrint**
eingeschaltet ist. Der TR8550 meldet sich im Netz als *„Canon TR8500 series“*.

---

## 2. Freigabe auf dem NAS

Du brauchst auf dem NAS:

- einen **freigegebenen Ordner**, z. B. `scans`
- einen **Benutzer**, z. B. `scanner`, mit **Lese- und Schreibrecht** auf diesen Ordner

Am einfachsten ist **SMB** (auch „Windows-Freigabe“ oder CIFS genannt). Das kann
jedes NAS. NFS geht auch, ist aber beim Thema Rechte etwas kniffliger (siehe unten).

### Synology (DSM 7)

1. *Systemsteuerung → Gemeinsamer Ordner → Erstellen* → Name `scans`
2. *Systemsteuerung → Benutzer und Gruppe → Erstellen* → Benutzer `scanner`,
   Berechtigung für `scans`: **Lesen/Schreiben**
3. *Systemsteuerung → Dateidienste → SMB* muss aktiviert sein (Standard)

### QNAP

1. *Systemsteuerung → Berechtigung → Freigabeordner → Erstellen* → `scans`
2. *Systemsteuerung → Berechtigung → Benutzer → Erstellen* → `scanner` mit
   Lese-/Schreibzugriff auf `scans`

### FRITZ!Box mit USB-Festplatte (FRITZ!NAS)

1. *Heimnetz → USB/Speicher → Heimnetzfreigabe* aktivieren
2. *System → FRITZ!Box-Benutzer* → Benutzer anlegen mit Recht
   **„Zugang zu NAS-Inhalten“** (Lesen und Schreiben)
3. In `proxmox.conf`: `NAS_SERVER="192.168.178.1"` und als `NAS_FREIGABE` den
   Namen des Speichers (steht in FRITZ!NAS, z. B. `FRITZ.NAS` oder der Name des USB-Sticks)
4. Falls das Einhängen scheitert: `SMB_VERSION="2.1"` probieren

### Windows-PC als „NAS“

Ordner → Rechtsklick → *Eigenschaften → Freigabe → Erweiterte Freigabe* →
Freigeben, Berechtigungen: Benutzer mit **Ändern**. Als Benutzer eignet sich ein
lokales Windows-Konto. Ein Microsoft-Konto klappt oft nicht.

### NFS statt SMB (für Fortgeschrittene)

Der Container läuft „unprivilegiert“: Sein Benutzer *root* erscheint gegenüber
dem NAS als Benutzer-ID **100000**. Damit er schreiben darf, gibt es zwei Wege:

- **Empfohlen:** In den NFS-Regeln des NAS **alle Benutzer auf einen Benutzer
  abbilden** (Synology: *Squash → „Alle Benutzer zu admin zuordnen“*).
- Oder dem Ordner auf dem NAS Schreibrecht für alle geben (`chmod 777`).

Als Client-IP in den NFS-Regeln die IP des **Proxmox-Hosts** eintragen, nicht die
des Containers. Das NAS wird ja auf dem Host eingehängt.

---

## 3. Proxmox

- Proxmox VE **8 oder 9**
- Der Host braucht **Internet** (für das Debian-Template und die Pakete)
- Du brauchst eine **root-Shell** auf dem Host: in der Proxmox-Oberfläche links
  auf den Knoten klicken → **Shell**, oder per SSH

Zwei Werte aus `proxmox.conf` solltest du kurz prüfen:

| Einstellung | Bedeutung | Wo nachschauen? |
|---|---|---|
| `CT_SPEICHER` | Speicher für die Container-Festplatte | *Rechenzentrum → Storage*. Meist `local-lvm`, bei ZFS-Installation `local-zfs` |
| `CT_BRIDGE` | Netzwerkbrücke | *Knoten → System → Netzwerk*. Meist `vmbr0` |

---

## 4. Zugriff auf dieses Repository

**Für den Einzeiler brauchst du nichts weiter.** Der curl-Befehl aus der
[README](../README.md#schnellstart-ein-einziger-befehl) lädt alles selbst herunter.

**Nur falls das Repository privat ist:** curl kann dann nicht darauf zugreifen,
weil GitHub private Dateien nur an angemeldete Nutzer ausliefert. Auch eine
Einladung als Mitarbeiter ändert daran nichts. Am einfachsten geht es dann mit der
GitHub-CLI. Du meldest dich einmal per Browser-Code an und musst keinen Token
abtippen:

```bash
apt install -y gh
gh auth login      # GitHub.com → HTTPS → "Login with a web browser" → Code auf github.com/login/device eingeben
bash -c "$(gh api -H 'Accept: application/vnd.github.v3.raw' repos/developer2013/bjoerni/contents/einrichten.sh)"
```

Der Assistent nutzt die gh-Anmeldung danach automatisch auch für den Download.

### Projekt als Ordner auf den Host holen (für die Wege B und C)

Willst du lieber mit der Konfigurationsdatei arbeiten oder alles von Hand machen
(siehe [Installation](02-installation.md)), brauchst du das Projekt als Ordner.

**a) Öffentliches Repository:**

```bash
apt install -y git
git clone https://github.com/developer2013/bjoerni.git
```

**b) Privates Repository mit Zugriffstoken:**
Auf GitHub *Settings → Developer settings → Personal access tokens →
Fine-grained tokens → Generate new token*. Unter *Repository access* nur `bjoerni`
auswählen, bei *Permissions → Contents* **Read-only** setzen. Dann auf dem Host:

```bash
apt install -y git
git clone https://github.com/developer2013/bjoerni.git
# Benutzername: dein GitHub-Name
# Passwort:     der Token (nicht dein GitHub-Passwort!)
```

**c) Privates Repository mit der GitHub-CLI:**

```bash
apt install -y gh git
gh auth login          # Anweisungen folgen
gh repo clone developer2013/bjoerni
```

**d) Als ZIP:** Auf GitHub *Code → Download ZIP*, dann vom PC auf den Host kopieren:

```bash
scp bjoerni-main.zip root@<PROXMOX-IP>:/root/
# auf dem Host:
apt install -y unzip && unzip bjoerni-main.zip && mv bjoerni-main bjoerni
```

Weiter geht's mit **[2. Installation](02-installation.md)**.
