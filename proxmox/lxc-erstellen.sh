#!/usr/bin/env bash
# =====================================================================
#  scan2nas – alles auf dem Proxmox-Host einrichten
#
#  Aufruf als root auf dem Proxmox-Host, im Projektordner:
#      ./proxmox/lxc-erstellen.sh                 (nutzt proxmox/proxmox.conf)
#      ./proxmox/lxc-erstellen.sh /pfad/zu/meine.conf
#
#  Was passiert?
#    1. NAS-Freigabe auf dem Host einhängen (über /etc/fstab, auch nach Neustart)
#    2. Unprivilegierten Debian-Container anlegen (oder vorhandenen wiederverwenden)
#    3. NAS per Bind-Mount in den Container durchreichen  (Host /mnt/scan2nas → Container /mnt/nas)
#    4. Startreihenfolge und NAS-Wächter einrichten (für Stromausfälle)
#    5. Container (neu) starten und scan2nas darin installieren
#
#  Mehrfach ausführen ist gefahrlos – so spielst du auch Updates ein.
# =====================================================================
set -euo pipefail

SKRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SKRIPT_DIR")"
KONFIG="${1:-$SKRIPT_DIR/proxmox.conf}"
CT_MOUNTPUNKT="/mnt/nas"
FSTAB_KOMMENTAR="# scan2nas: NAS-Freigabe für den Scanner-Container"

info()   { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()     { printf '\033[1;32m ✔ \033[0m %s\n' "$*"; }
warn()   { printf '\033[1;33m ! \033[0m %s\n' "$*" >&2; }
fehler() { printf '\033[1;31m ✘ \033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------
#  Vorprüfungen und Einstellungen
# ---------------------------------------------------------------------
[[ $EUID -eq 0 ]] || fehler "Bitte als root ausführen."
command -v pct >/dev/null 2>&1 \
  || fehler "pct nicht gefunden – dieses Skript muss auf dem Proxmox-HOST laufen (nicht im Container)."
[[ -f $KONFIG ]] \
  || fehler "Konfiguration $KONFIG fehlt. Erst: cp proxmox/proxmox.conf.beispiel proxmox/proxmox.conf && nano proxmox/proxmox.conf"

# shellcheck source=proxmox.conf.beispiel
source "$KONFIG"

CT_ID="${CT_ID:-}"
CT_NAME="${CT_NAME:-scanner}"
CT_SPEICHER="${CT_SPEICHER:-local-lvm}"
TEMPLATE_SPEICHER="${TEMPLATE_SPEICHER:-local}"
CT_BRIDGE="${CT_BRIDGE:-vmbr0}"
CT_IP="${CT_IP:-dhcp}"
CT_GATEWAY="${CT_GATEWAY:-}"
CT_VLAN="${CT_VLAN:-}"
CT_KERNE="${CT_KERNE:-2}"
CT_RAM="${CT_RAM:-1024}"
CT_SWAP="${CT_SWAP:-512}"
CT_DISK="${CT_DISK:-8}"
CT_PASSWORT="${CT_PASSWORT:-}"
CT_SSH_SCHLUESSEL="${CT_SSH_SCHLUESSEL:-}"
if [[ -z ${CT_PASSWORT} ]]; then
  KONSOLE_AUTOLOGIN="${KONSOLE_AUTOLOGIN:-ja}"
else
  KONSOLE_AUTOLOGIN="${KONSOLE_AUTOLOGIN:-nein}"
fi
SCANNER_IP="${SCANNER_IP:-}"
NAS_TYP="${NAS_TYP:-cifs}"
NAS_SERVER="${NAS_SERVER:-}"
NAS_FREIGABE="${NAS_FREIGABE:-}"
NAS_BENUTZER="${NAS_BENUTZER:-}"
NAS_PASSWORT="${NAS_PASSWORT:-}"
NAS_DOMAENE="${NAS_DOMAENE:-}"
SMB_VERSION="${SMB_VERSION:-3.0}"
NAS_UNTERORDNER="${NAS_UNTERORDNER:-Scans}"
HOST_MOUNTPUNKT="${HOST_MOUNTPUNKT:-/mnt/scan2nas}"

[[ -n $SCANNER_IP ]] || fehler "SCANNER_IP fehlt in $KONFIG."
[[ -n $NAS_SERVER && -n $NAS_FREIGABE ]] || fehler "NAS_SERVER und NAS_FREIGABE müssen in $KONFIG gesetzt sein."
case $NAS_TYP in
  cifs) [[ -n $NAS_BENUTZER ]] || fehler "NAS_BENUTZER fehlt (für NAS_TYP=cifs nötig)." ;;
  nfs)  ;;
  *)    fehler "NAS_TYP muss 'cifs' oder 'nfs' sein (ist: '$NAS_TYP')." ;;
esac
case $NAS_UNTERORDNER in
  ""|/*|*..*) fehler "NAS_UNTERORDNER muss ein relativer Ordnername sein, z. B. 'Scans'." ;;
esac
if [[ -n $CT_SSH_SCHLUESSEL && ! -f $CT_SSH_SCHLUESSEL ]]; then
  fehler "SSH-Schlüssel $CT_SSH_SCHLUESSEL nicht gefunden."
fi

# ---------------------------------------------------------------------
#  1. NAS auf dem Host einhängen
# ---------------------------------------------------------------------
nas_einhaengen() {
  local geraet optionen
  if [[ $NAS_TYP == cifs ]]; then
    command -v mount.cifs >/dev/null 2>&1 || { info "Installiere cifs-utils …"; apt-get install -y -qq cifs-utils; }
    local zugang=/root/.scan2nas-smb
    # Zugangsdaten in eigener Datei (nur für root lesbar) statt in der fstab
    ( umask 077
      { printf 'username=%s\n' "$NAS_BENUTZER"
        printf 'password=%s\n' "$NAS_PASSWORT"
        if [[ -n $NAS_DOMAENE ]]; then printf 'domain=%s\n' "$NAS_DOMAENE"; fi
      } > "$zugang" )
    chmod 600 "$zugang"
    geraet="//$NAS_SERVER/${NAS_FREIGABE#/}"
    # uid/gid 100000 = root im unprivilegierten Container.
    # file_mode/dir_mode: jeder Benutzer im Container darf schreiben (scanservjs, root).
    optionen="credentials=$zugang,uid=100000,gid=100000,file_mode=0666,dir_mode=0777,iocharset=utf8,vers=$SMB_VERSION,_netdev,nofail"
  else
    command -v mount.nfs >/dev/null 2>&1 || { info "Installiere nfs-common …"; apt-get install -y -qq nfs-common; }
    geraet="$NAS_SERVER:$NAS_FREIGABE"
    optionen="defaults,_netdev,nofail"
  fi
  info "Hänge das NAS auf dem Host ein ($geraet → $HOST_MOUNTPUNKT) …"
  mkdir -p "$HOST_MOUNTPUNKT"

  # Eine alte scan2nas-Zeile (oder eine andere Zeile für diesen Mountpunkt) ersetzen
  if grep -qF "$FSTAB_KOMMENTAR" /etc/fstab || awk -v mp="$HOST_MOUNTPUNKT" '$2==mp {f=1} END {exit !f}' /etc/fstab; then
    cp /etc/fstab "/etc/fstab.scan2nas-$(date +%Y%m%d-%H%M%S)"
    awk -v mp="$HOST_MOUNTPUNKT" -v k="$FSTAB_KOMMENTAR" '$0 != k && $2 != mp' /etc/fstab > /etc/fstab.scan2nas-neu
    cat /etc/fstab.scan2nas-neu > /etc/fstab   # cat statt mv: Rechte der fstab bleiben erhalten
    rm -f /etc/fstab.scan2nas-neu
  fi
  printf '%s\n%s %s %s %s 0 0\n' "$FSTAB_KOMMENTAR" "$geraet" "$HOST_MOUNTPUNKT" "$NAS_TYP" "$optionen" >> /etc/fstab
  systemctl daemon-reload

  if mountpoint -q "$HOST_MOUNTPUNKT" && [[ "$(findmnt -no SOURCE "$HOST_MOUNTPUNKT")" == "$geraet" ]]; then
    ok "NAS ist bereits eingehängt"
  else
    if mountpoint -q "$HOST_MOUNTPUNKT"; then umount "$HOST_MOUNTPUNKT"; fi
    mount "$HOST_MOUNTPUNKT" \
      || fehler "Das NAS konnte nicht eingehängt werden. Prüfe NAS_SERVER, NAS_FREIGABE, Benutzer, Passwort und SMB_VERSION – siehe docs/04-fehlerbehebung.md"
    mountpoint -q "$HOST_MOUNTPUNKT" || fehler "$HOST_MOUNTPUNKT ist nach dem mount kein Mountpunkt – bitte 'dmesg | tail' prüfen."
    ok "NAS eingehängt"
  fi

  mkdir -p "$HOST_MOUNTPUNKT/$NAS_UNTERORDNER" \
    || fehler "Konnte den Ordner '$NAS_UNTERORDNER' auf dem NAS nicht anlegen – fehlt das Schreibrecht?"
  # Schreibtest mit der Benutzerkennung, die root im Container auf dem Host hat (100000)
  local probe="$HOST_MOUNTPUNKT/$NAS_UNTERORDNER/.scan2nas-schreibtest"
  if setpriv --reuid=100000 --regid=100000 --clear-groups touch "$probe" 2>/dev/null; then
    rm -f "$probe"
    ok "Schreibtest auf dem NAS (als Container-Benutzer) erfolgreich"
  else
    warn "Der Container dürfte nicht in '$NAS_UNTERORDNER' schreiben können."
    if [[ $NAS_TYP == nfs ]]; then
      warn "Bei NFS auf dem NAS 'alle Benutzer auf admin/guest abbilden' (squash all) einstellen – siehe docs/01-vorbereitung.md"
    fi
  fi
}

# ---------------------------------------------------------------------
#  2. Container anlegen oder wiederverwenden
# ---------------------------------------------------------------------
template_besorgen() {
  info "Suche das aktuelle Debian-Template …"
  pveam update >/dev/null 2>&1 || warn "pveam update fehlgeschlagen – nutze die vorhandene Liste."
  local liste
  liste="$(pveam available --section system 2>/dev/null | awk '{print $2}')"
  TEMPLATE="$(grep -E '^debian-13-standard_.*_amd64\.tar\.(zst|xz|gz)$' <<<"$liste" | sort -V | tail -n1 || true)"
  if [[ -z $TEMPLATE ]]; then
    TEMPLATE="$(grep -E '^debian-12-standard_.*_amd64\.tar\.(zst|xz|gz)$' <<<"$liste" | sort -V | tail -n1 || true)"
  fi
  [[ -n $TEMPLATE ]] || fehler "Kein Debian-Template gefunden ('pveam available --section system')."
  if pveam list "$TEMPLATE_SPEICHER" 2>/dev/null | grep -qF "$TEMPLATE"; then
    ok "Template vorhanden: $TEMPLATE"
  else
    info "Lade $TEMPLATE herunter …"
    pveam download "$TEMPLATE_SPEICHER" "$TEMPLATE"
  fi
}

container_anlegen() {
  # Gibt es den Container schon?
  if [[ -n $CT_ID ]] && pct status "$CT_ID" >/dev/null 2>&1; then
    local name
    name="$(pct config "$CT_ID" | awk '/^hostname:/ {print $2}')"
    [[ $name == "$CT_NAME" ]] \
      || fehler "Container $CT_ID gibt es schon, er heißt aber '$name' statt '$CT_NAME'. Andere CT_ID wählen oder CT_ID leer lassen."
    ok "Nutze vorhandenen Container $CT_ID ($CT_NAME)"
    return
  fi
  if [[ -z $CT_ID ]]; then
    local vorhanden
    vorhanden="$(pct list | awk -v n="$CT_NAME" 'NR>1 && $NF==n {print $1; exit}')"
    if [[ -n $vorhanden ]]; then
      CT_ID="$vorhanden"
      ok "Nutze vorhandenen Container $CT_ID ($CT_NAME)"
      return
    fi
    CT_ID="$(pvesh get /cluster/nextid)"
  fi

  template_besorgen
  local netz="name=eth0,bridge=$CT_BRIDGE"
  if [[ $CT_IP == dhcp ]]; then
    netz+=",ip=dhcp"
  else
    netz+=",ip=$CT_IP"
    if [[ -n $CT_GATEWAY ]]; then netz+=",gw=$CT_GATEWAY"; fi
  fi
  if [[ -n $CT_VLAN ]]; then netz+=",tag=$CT_VLAN"; fi

  local optionen=(
    --hostname "$CT_NAME"
    --ostype debian
    --unprivileged 1
    --features nesting=1
    --cores "$CT_KERNE"
    --memory "$CT_RAM"
    --swap "$CT_SWAP"
    --rootfs "$CT_SPEICHER:$CT_DISK"
    --net0 "$netz"
    --onboot 1
    --timezone host
    --description "scan2nas: Scans vom Canon TR8550 aufs NAS – https://github.com/developer2013/bjoerni"
  )
  if [[ -n $CT_PASSWORT ]]; then optionen+=(--password "$CT_PASSWORT"); fi
  if [[ -n $CT_SSH_SCHLUESSEL ]]; then optionen+=(--ssh-public-keys "$CT_SSH_SCHLUESSEL"); fi

  info "Lege Container $CT_ID ($CT_NAME) an …"
  pct create "$CT_ID" "$TEMPLATE_SPEICHER:vztmpl/$TEMPLATE" "${optionen[@]}"
  ok "Container $CT_ID angelegt"
}

# ---------------------------------------------------------------------
#  3. NAS in den Container durchreichen
# ---------------------------------------------------------------------
bind_mount_einrichten() {
  local soll="$HOST_MOUNTPUNKT,mp=$CT_MOUNTPUNKT"
  local ist
  ist="$(pct config "$CT_ID" | awk '/^mp0:/ {sub(/^mp0: */, ""); print}')"
  if [[ $ist == "$soll"* ]]; then
    ok "NAS ist bereits in den Container durchgereicht"
    return
  fi
  [[ -z $ist ]] || fehler "mp0 ist im Container $CT_ID schon anders belegt ($ist). Bitte von Hand prüfen."
  pct set "$CT_ID" -mp0 "$soll"
  ok "NAS ist im Container unter $CT_MOUNTPUNKT sichtbar"
}

# ---------------------------------------------------------------------
#  4. Startreihenfolge + NAS-Wächter
# ---------------------------------------------------------------------
host_dienste_einrichten() {
  local unit
  unit="$(systemd-escape -p --suffix=mount "$HOST_MOUNTPUNKT")"

  mkdir -p /etc/systemd/system/pve-guests.service.d
  cat > /etc/systemd/system/pve-guests.service.d/scan2nas.conf <<EOF
# Von scan2nas angelegt: Gäste erst starten, nachdem das NAS eingehängt wurde.
# Klappt das Einhängen nicht, starten sie trotzdem – dann hilft der NAS-Wächter.
[Unit]
Wants=$unit
After=$unit
EOF

  cat > /usr/local/sbin/scan2nas-nas-waechter <<EOF
#!/usr/bin/env bash
# Von scan2nas angelegt – läuft alle 5 Minuten (scan2nas-nas-waechter.timer).
# Ist das NAS nicht eingehängt (z. B. weil es nach einem Stromausfall länger
# zum Hochfahren brauchte als Proxmox), wird es eingehängt und der Container
# neu gestartet – erst dann sieht er die Freigabe. Bis dahin sammelt scan2nas
# die Scans in seiner Warteschlange, es geht also nichts verloren.
MP="$HOST_MOUNTPUNKT"
CT="$CT_ID"
mountpoint -q "\$MP" && exit 0
logger -t scan2nas "NAS unter \$MP ist nicht eingehängt – versuche es"
if mount "\$MP" 2>/dev/null && mountpoint -q "\$MP"; then
  logger -t scan2nas "NAS eingehängt – starte Container \$CT neu"
  if pct status "\$CT" 2>/dev/null | grep -q running; then pct reboot "\$CT"; fi
fi
EOF
  chmod 755 /usr/local/sbin/scan2nas-nas-waechter

  cat > /etc/systemd/system/scan2nas-nas-waechter.service <<'EOF'
[Unit]
Description=scan2nas – prüft, ob das NAS eingehängt ist
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/scan2nas-nas-waechter
EOF

  cat > /etc/systemd/system/scan2nas-nas-waechter.timer <<'EOF'
[Unit]
Description=scan2nas – NAS-Wächter alle 5 Minuten

[Timer]
OnBootSec=3min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now --quiet scan2nas-nas-waechter.timer
  ok "Startreihenfolge und NAS-Wächter eingerichtet"
}

# ---------------------------------------------------------------------
#  5. Container starten und scan2nas installieren
# ---------------------------------------------------------------------
im_container_installieren() {
  if [[ "$(pct status "$CT_ID")" == *running* ]]; then
    info "Starte Container $CT_ID neu (damit er das NAS sicher sieht) …"
    pct reboot "$CT_ID"
  else
    info "Starte Container $CT_ID …"
    pct start "$CT_ID"
  fi

  info "Warte auf Internet im Container …"
  local i
  for i in $(seq 1 60); do
    if pct exec "$CT_ID" -- getent hosts deb.debian.org >/dev/null 2>&1; then break; fi
    [[ $i -lt 60 ]] || fehler "Der Container hat nach 2 Minuten noch kein Internet – CT_IP, CT_GATEWAY und CT_BRIDGE prüfen."
    sleep 2
  done
  ok "Netzwerk ist da"

  info "Kopiere die Projektdateien in den Container …"
  local paket
  paket="$(mktemp --suffix=.tar.gz)"
  # *.conf wird ausgelassen: keine Dateien mit Passwörtern in den Container kopieren
  tar -C "$REPO_DIR" --exclude='./.git' --exclude='*.conf' -czf "$paket" .
  pct push "$CT_ID" "$paket" /root/scan2nas-quelle.tar.gz
  rm -f "$paket"
  pct exec "$CT_ID" -- bash -c 'rm -rf /root/scan2nas-quelle && mkdir -p /root/scan2nas-quelle \
    && tar -xzf /root/scan2nas-quelle.tar.gz -C /root/scan2nas-quelle && rm -f /root/scan2nas-quelle.tar.gz'

  info "Installiere scan2nas im Container (dauert beim ersten Mal ein paar Minuten) …"
  pct exec "$CT_ID" -- env LANG=C.UTF-8 LC_ALL=C.UTF-8 \
    SCANNER_IP="$SCANNER_IP" NAS_ORDNER="$CT_MOUNTPUNKT/$NAS_UNTERORDNER" \
    KONSOLE_AUTOLOGIN="$KONSOLE_AUTOLOGIN" \
    bash /root/scan2nas-quelle/installation/installieren.sh
}

# ---------------------------------------------------------------------
#  Los geht's
# ---------------------------------------------------------------------
nas_einhaengen
container_anlegen
bind_mount_einrichten
host_dienste_einrichten
im_container_installieren

CT_ADRESSE="$(pct exec "$CT_ID" -- hostname -I 2>/dev/null | awk '{print $1}' || true)"
echo
ok "Alles eingerichtet!"
echo "   Container:       $CT_ID ($CT_NAME)   –   Konsole: pct enter $CT_ID"
echo "   Weboberfläche:   http://${CT_ADRESSE:-<container-ip>}:8080"
echo "   Scans landen in: $NAS_TYP $NAS_SERVER → $NAS_FREIGABE/$NAS_UNTERORDNER"
echo
echo "   Tipp: Im Router dem Container eine feste IP geben (oder CT_IP setzen),"
echo "         dann bleibt die Adresse der Weboberfläche immer gleich."
