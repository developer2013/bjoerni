#!/usr/bin/env bash
# =====================================================================
#  scan2nas – Installation IM Container (Debian 12 oder 13)
#
#  Wird normalerweise automatisch von proxmox/lxc-erstellen.sh aufgerufen.
#  Manuell (als root im Container, im Projektordner):
#
#      SCANNER_IP=192.168.178.50 bash installation/installieren.sh
#
#  Optionale Umgebungsvariablen:
#      SCANNER_IP          IP des Scanners (dringend empfohlen)
#      SCANNER_NAME        Anzeigename (Standard: "Canon TR8550")
#      NAS_ORDNER          Zielordner im Container (Standard: /mnt/nas/Scans)
#      SCANSERVJS_VERSION  z. B. v3.3.0 oder "latest" (Standard: v3.3.0)
#      KONSOLE_AUTOLOGIN   ja = Proxmox-Konsole meldet automatisch als root an
#                          (Standard: nein)
#
#  Das Skript kann gefahrlos mehrfach ausgeführt werden (z. B. für Updates).
#  Eine vorhandene /etc/scan2nas/scan2nas.conf wird NICHT überschrieben.
# =====================================================================
set -euo pipefail

QUELLE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCANNER_IP="${SCANNER_IP:-}"
SCANNER_NAME="${SCANNER_NAME:-Canon TR8550}"
NAS_ORDNER="${NAS_ORDNER:-/mnt/nas/Scans}"
SCANSERVJS_VERSION="${SCANSERVJS_VERSION:-v3.3.0}"
KONSOLE_AUTOLOGIN="${KONSOLE_AUTOLOGIN:-nein}"

export DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8 LC_ALL=C.UTF-8

info()   { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()     { printf '\033[1;32m ✔ \033[0m %s\n' "$*"; }
warn()   { printf '\033[1;33m ! \033[0m %s\n' "$*" >&2; }
fehler() { printf '\033[1;31m ✘ \033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------
#  Vorprüfungen
# ---------------------------------------------------------------------
[[ $EUID -eq 0 ]] || fehler "Bitte als root ausführen."
[[ -f /etc/debian_version ]] || fehler "Dieses Skript ist für Debian (12 oder 13) gedacht."
[[ -f "$QUELLE/programm/scan2nas.py" ]] || fehler "Projektdateien nicht gefunden unter $QUELLE."
if [[ -z $SCANNER_IP ]]; then
  warn "SCANNER_IP ist nicht gesetzt – der Scanner wird per Netzwerksuche (mDNS) gesucht."
  warn "Empfehlung: Scanner im Router eine feste IP geben und SCANNER_IP setzen."
fi

# ---------------------------------------------------------------------
#  1. Pakete
# ---------------------------------------------------------------------
info "Installiere Pakete (SANE, AirScan-Treiber, PDF-Werkzeuge, Texterkennung) …"
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
  sane-utils sane-airscan avahi-daemon libnss-mdns \
  img2pdf ocrmypdf tesseract-ocr tesseract-ocr-deu tesseract-ocr-osd \
  python3 curl ca-certificates
ok "Pakete installiert"

# avahi (mDNS) läuft in LXC-Containern nur ohne das Prozesslimit
if [[ -f /etc/avahi/avahi-daemon.conf ]] && grep -q '^rlimit-nproc' /etc/avahi/avahi-daemon.conf; then
  sed -i 's/^rlimit-nproc/#rlimit-nproc/' /etc/avahi/avahi-daemon.conf
  systemctl restart avahi-daemon || warn "avahi-daemon ließ sich nicht neu starten (nur für die Netzwerksuche nötig)."
fi

# ---------------------------------------------------------------------
#  2. scanservjs (Weboberfläche)
# ---------------------------------------------------------------------
if [[ $SCANSERVJS_VERSION == latest ]]; then
  DEB_URL="$(curl -fsSL https://api.github.com/repos/sbs20/scanservjs/releases/latest \
             | grep -m1 -oE 'https://[^"]+_all\.deb')" \
    || fehler "Konnte die neueste scanservjs-Version nicht ermitteln."
  ZIEL_VERSION="$(basename "$DEB_URL" | sed -E 's/^scanservjs_([^_]+)_all\.deb$/\1/')"
else
  ZIEL_VERSION="${SCANSERVJS_VERSION#v}-1"
  DEB_URL="https://github.com/sbs20/scanservjs/releases/download/${SCANSERVJS_VERSION}/scanservjs_${ZIEL_VERSION}_all.deb"
fi
INSTALLIERT="$(dpkg-query -W -f='${Version}' scanservjs 2>/dev/null || true)"
if [[ $INSTALLIERT == "$ZIEL_VERSION" ]]; then
  ok "scanservjs $INSTALLIERT ist bereits installiert"
else
  info "Installiere scanservjs $ZIEL_VERSION …"
  DEB_DATEI="$(mktemp --suffix=.deb)"
  curl -fsSL -o "$DEB_DATEI" "$DEB_URL" || fehler "Download fehlgeschlagen: $DEB_URL"
  chmod 644 "$DEB_DATEI"
  apt-get install -y -qq --no-install-recommends "$DEB_DATEI"
  rm -f "$DEB_DATEI"
  ok "scanservjs installiert"
fi

# ---------------------------------------------------------------------
#  3. SANE: Scanner fest eintragen
# ---------------------------------------------------------------------
info "Richte den Scanner ein …"
AIRSCAN_CONF=/etc/sane.d/airscan.conf
if [[ -f $AIRSCAN_CONF && ! -f $AIRSCAN_CONF.original ]]; then
  cp "$AIRSCAN_CONF" "$AIRSCAN_CONF.original"
fi
if [[ -n $SCANNER_IP ]]; then
  cat > "$AIRSCAN_CONF" <<EOF
# Von scan2nas angelegt ($(date +%F)). Original: airscan.conf.original
# Der Scanner ist fest eingetragen, die Netzwerksuche ist aus –
# das ist schneller und zuverlässiger als mDNS im Container.
[devices]
"$SCANNER_NAME" = http://$SCANNER_IP/eSCL, eSCL

[options]
discovery = disable
EOF
  ok "Scanner $SCANNER_NAME ($SCANNER_IP) in $AIRSCAN_CONF eingetragen"
fi

# Doppelte/langsame Backends abschalten: 'escl' meldet denselben Scanner ein
# zweites Mal, 'pixma' sucht per Broadcast und bremst 'scanimage -L' aus.
if [[ -f /etc/sane.d/dll.conf ]]; then
  sed -i -E 's/^(escl|pixma)[[:space:]]*$/#\1  # von scan2nas deaktiviert/' /etc/sane.d/dll.conf
fi

# ---------------------------------------------------------------------
#  4. scan2nas
# ---------------------------------------------------------------------
info "Installiere scan2nas …"
install -d -m 755 /opt/scan2nas /etc/scan2nas
install -m 755 "$QUELLE/programm/scan2nas.py" /opt/scan2nas/scan2nas.py
ln -sf /opt/scan2nas/scan2nas.py /usr/local/bin/scan2nas

if [[ -f /etc/scan2nas/scan2nas.conf ]]; then
  ok "Vorhandene /etc/scan2nas/scan2nas.conf bleibt unverändert"
  install -m 644 "$QUELLE/konfiguration/scan2nas.conf.beispiel" /etc/scan2nas/scan2nas.conf.beispiel
else
  install -m 644 "$QUELLE/konfiguration/scan2nas.conf.beispiel" /etc/scan2nas/scan2nas.conf
  sed -i -e "s|^SCANNER_IP=.*|SCANNER_IP=\"$SCANNER_IP\"|" \
         -e "s|^NAS_ORDNER=.*|NAS_ORDNER=\"$NAS_ORDNER\"|" /etc/scan2nas/scan2nas.conf
  ok "Konfiguration angelegt: /etc/scan2nas/scan2nas.conf"
fi

# Arbeitsordner: Gruppe 'users' (darin ist scanservjs), setgid, damit
# root (Kommandozeile) und scanservjs (Weboberfläche, Dienst) beide schreiben können.
install -d -m 2775 -o root -g users /var/lib/scan2nas /var/lib/scan2nas/warteschlange /var/lib/scan2nas/arbeit

# ---------------------------------------------------------------------
#  5. scanservjs mit scan2nas verbinden
# ---------------------------------------------------------------------
LOCAL_JS=/etc/scanservjs/config.local.js
if [[ -f $LOCAL_JS ]] && ! grep -q 'scan2nas' "$LOCAL_JS"; then
  cp "$LOCAL_JS" "$LOCAL_JS.vorher-$(date +%Y%m%d-%H%M%S)"
  warn "Eigene $LOCAL_JS gesichert und ersetzt."
fi
install -m 644 "$QUELLE/konfiguration/scanservjs-config.local.js" "$LOCAL_JS"
ok "Weboberfläche kopiert jeden Scan aufs NAS"

# ---------------------------------------------------------------------
#  6. Dienste
# ---------------------------------------------------------------------
info "Starte Dienste …"
install -m 644 "$QUELLE/systemd/scan2nas.service" /etc/systemd/system/scan2nas.service
systemctl daemon-reload
systemctl enable --quiet scanservjs scan2nas
systemctl restart scanservjs scan2nas
ok "scanservjs und scan2nas laufen"

# ---------------------------------------------------------------------
#  7. Proxmox-Konsole (Autologin)
# ---------------------------------------------------------------------
GETTY_DIR=/etc/systemd/system/container-getty@1.service.d
if [[ $KONSOLE_AUTOLOGIN == ja ]]; then
  mkdir -p "$GETTY_DIR"
  cat > "$GETTY_DIR/scan2nas-autologin.conf" <<'EOF'
# Von scan2nas angelegt: Die Proxmox-Konsole meldet automatisch als root an,
# weil für den Container kein Passwort gesetzt ist. An die Konsole kommt
# ohnehin nur, wer in Proxmox selbst angemeldet ist.
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear --keep-baud tty%I 115200,38400,9600 $TERM
EOF
  systemctl daemon-reload
  systemctl restart container-getty@1.service 2>/dev/null || true
  ok "Proxmox-Konsole meldet automatisch als root an"
elif [[ -f $GETTY_DIR/scan2nas-autologin.conf ]]; then
  rm -f "$GETTY_DIR/scan2nas-autologin.conf"
  systemctl daemon-reload
  systemctl restart container-getty@1.service 2>/dev/null || true
  ok "Autologin der Konsole abgeschaltet"
fi

# ---------------------------------------------------------------------
#  8. Selbsttest
# ---------------------------------------------------------------------
echo
scan2nas test || warn "Der Selbsttest hat Probleme gefunden – siehe docs/04-fehlerbehebung.md"

IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
echo
ok "Fertig!"
echo "   Weboberfläche:    http://${IP:-<container-ip>}:8080"
echo "   Scan per Befehl:  scan2nas scannen            (Vorlagenglas)"
echo "                     scan2nas scannen -q einzug  (Einzug, mehrere Seiten)"
echo "   Einstellungen:    /etc/scan2nas/scan2nas.conf"
