# 2. Installation

Es gibt zwei Wege:

- **[A. Automatisch](#a-automatische-installation-empfohlen)**: Ein Skript auf dem
  Proxmox-Host erledigt alles (empfohlen).
- **[B. Von Hand](#b-manuelle-installation)**: Für den Fall, dass du jeden Schritt
  selbst machen willst oder schon einen Container hast.

---

## A. Automatische Installation (empfohlen)

Auf dem **Proxmox-Host** als root, im Projektordner:

```bash
cd ~/bjoerni
cp proxmox/proxmox.conf.beispiel proxmox/proxmox.conf
nano proxmox/proxmox.conf
```

Trag mindestens das hier ein:

```bash
SCANNER_IP="192.168.178.50"     # feste IP des Canon TR8550
NAS_TYP="cifs"                  # SMB-Freigabe
NAS_SERVER="192.168.178.10"     # IP des NAS
NAS_FREIGABE="scans"            # Name der Freigabe
NAS_BENUTZER="scanner"
NAS_PASSWORT='DeinPasswort'     # in einfachen Anführungszeichen!
```

Speichern mit `Strg+O`, `Enter`, Beenden mit `Strg+X`. Dann:

```bash
bash ./proxmox/lxc-erstellen.sh
```

### Was das Skript macht

| Schritt | Was passiert | Wo |
|---|---|---|
| 1 | Speichert die NAS-Zugangsdaten in `/root/.scan2nas-smb` (nur für root lesbar) | Host |
| 2 | Trägt das NAS in `/etc/fstab` ein (eine Sicherung `/etc/fstab.scan2nas-…` wird angelegt) und hängt es unter `/mnt/scan2nas` ein | Host |
| 3 | Legt den Ordner `Scans` auf dem NAS an und testet, ob der Container dort schreiben darf | Host |
| 4 | Lädt das aktuelle Debian-Template und legt einen **unprivilegierten** Container `scanner` an (2 Kerne, 1 GB RAM, 8 GB Platte, startet automatisch mit) | Host |
| 5 | Reicht das NAS in den Container durch: Host `/mnt/scan2nas` → Container `/mnt/nas` | Host |
| 6 | Richtet die Startreihenfolge (erst das NAS, dann die Container) und den **NAS-Wächter** ein | Host |
| 7 | Startet den Container, kopiert die Projektdateien hinein und ruft `installation/installieren.sh` auf | Container |
| 8 | Installiert SANE, sane-airscan, scanservjs, ocrmypdf, Texterkennung Deutsch | Container |
| 9 | Trägt den Scanner fest ein, legt `/etc/scan2nas/scan2nas.conf` an und startet die Dienste | Container |
| 10 | Selbsttest (`scan2nas test`) | Container |

Am Ende sieht die Ausgabe ungefähr so aus:

```
scan2nas 1.0.0 – Selbsttest (Konfiguration: /etc/scan2nas/scan2nas.conf)

 ✔ scanimage ist installiert
 ✔ img2pdf ist installiert
 ✔ ocrmypdf ist installiert
 ✔ OCR-Sprache deu ist installiert
 ✔ Scanner antwortet per eSCL (http://192.168.178.50/eSCL): Zustand Idle, Einzug ScannerAdfEmpty
 ✔ SANE findet den Scanner: airscan:e0:Canon TR8550
 ✔ NAS-Ordner /mnt/nas/Scans ist beschreibbar
 ✔ Warteschlange: 0 Datei(en)
 ✔ Einzug-Automatik ist aus

Alles in Ordnung.

 ✔  Alles eingerichtet!
   Container:       105 (scanner)   –   Konsole: pct enter 105
   Weboberfläche:   http://192.168.178.61:8080
```

> **Was ist der NAS-Wächter?** Nach einem Stromausfall startet Proxmox oft schneller
> als das NAS. Dann klappt das Einhängen beim Booten nicht und der Container sieht
> nur einen leeren Ordner. Der Wächter (`scan2nas-nas-waechter.timer`) prüft alle
> 5 Minuten, ob das NAS da ist. Sobald es erreichbar ist, hängt er es ein und startet
> den Container neu. Scans, die in der Zwischenzeit entstehen, sammelt scan2nas
> in seiner Warteschlange. Es geht also nichts verloren.

### Tipp: Feste Adresse für die Weboberfläche

Gib auch dem **Container** im Router eine feste IP oder trag sie direkt in
`proxmox.conf` ein (`CT_IP="192.168.178.60/24"`, `CT_GATEWAY="192.168.178.1"`).
Dann kannst du dir die Weboberfläche als Lesezeichen speichern oder auf dem Handy
zum Startbildschirm hinzufügen.

---

## Updates einspielen

Auf dem Proxmox-Host:

```bash
cd ~/bjoerni
git pull
bash ./proxmox/lxc-erstellen.sh
```

Das Skript erkennt den vorhandenen Container und legt keinen neuen an. Es startet
ihn neu und installiert die aktuelle Version. Deine Einstellungen in
`/etc/scan2nas/scan2nas.conf` bleiben erhalten. Neue Optionen findest du danach in
`/etc/scan2nas/scan2nas.conf.beispiel`.

---

## B. Manuelle Installation

### B1. Container anlegen (Proxmox-Oberfläche)

*Erstelle CT* → Hostname `scanner`, **Unprivilegierter Container: ja**,
**Nesting: ja** → Template `debian-13-standard` → 8 GB Platte → 2 Kerne → 1024 MB RAM
→ Netzwerk `vmbr0`, DHCP oder feste IP → fertig. Den Container noch **nicht** starten.

### B2. NAS auf dem Host einhängen

```bash
# Zugangsdaten (nur für root lesbar)
cat > /root/.scan2nas-smb <<'EOF'
username=scanner
password=DeinPasswort
EOF
chmod 600 /root/.scan2nas-smb

mkdir -p /mnt/scan2nas
echo '//192.168.178.10/scans /mnt/scan2nas cifs credentials=/root/.scan2nas-smb,uid=100000,gid=100000,file_mode=0666,dir_mode=0777,iocharset=utf8,vers=3.0,_netdev,nofail 0 0' >> /etc/fstab
systemctl daemon-reload
mount /mnt/scan2nas
mkdir -p /mnt/scan2nas/Scans
```

`uid=100000,gid=100000` sorgt dafür, dass die Dateien im Container *root* gehören.
`file_mode=0666,dir_mode=0777` erlaubt auch dem Benutzer der Weboberfläche das Schreiben.

### B3. NAS in den Container durchreichen

```bash
pct set <ID> -mp0 /mnt/scan2nas,mp=/mnt/nas
pct start <ID>
```

### B4. Im Container installieren

Projektdateien in den Container bringen, z. B. vom Host aus:

```bash
tar -C ~/bjoerni --exclude=.git --exclude='*.conf' -czf /tmp/scan2nas.tar.gz .
pct push <ID> /tmp/scan2nas.tar.gz /root/scan2nas.tar.gz
pct enter <ID>
```

Im Container:

```bash
mkdir -p /root/scan2nas-quelle && tar -xzf /root/scan2nas.tar.gz -C /root/scan2nas-quelle
cd /root/scan2nas-quelle
SCANNER_IP=192.168.178.50 bash installation/installieren.sh
```

---

## Deinstallation

**Container entfernen** (Proxmox-Oberfläche: Container → *Mehr → Entfernen*) oder:

```bash
pct stop <ID> && pct destroy <ID>
```

**Auf dem Host aufräumen:**

```bash
systemctl disable --now scan2nas-nas-waechter.timer
rm -f /etc/systemd/system/scan2nas-nas-waechter.{service,timer} \
      /usr/local/sbin/scan2nas-nas-waechter \
      /etc/systemd/system/pve-guests.service.d/scan2nas.conf
umount /mnt/scan2nas
nano /etc/fstab        # die Zeile mit /mnt/scan2nas und den Kommentar darüber löschen
rm -f /root/.scan2nas-smb
systemctl daemon-reload
```

Die Scans auf dem NAS bleiben natürlich erhalten.
