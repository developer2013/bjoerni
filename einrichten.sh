#!/usr/bin/env bash
# =====================================================================
#  scan2nas – Einrichtung mit einem einzigen Befehl
#  (im Stil der Proxmox VE Community Scripts)
#
#  In der Shell des Proxmox-Hosts als root:
#
#    bash -c "$(curl -fsSL https://raw.githubusercontent.com/developer2013/bjoerni/main/einrichten.sh)"
#
#  Das Skript …
#    1. fragt alle Einstellungen in Dialogfenstern ab,
#    2. sucht den Scanner automatisch im Netzwerk,
#    3. testet den Zugang zum NAS, BEVOR irgendetwas verändert wird,
#    4. lädt das Projekt herunter und ruft proxmox/lxc-erstellen.sh auf.
#
#  Ein zweiter Aufruf bietet "Aktualisieren" an (Einstellungen bleiben).
#
#  Optionale Umgebungsvariablen:
#    SCAN2NAS_REF=main             anderer Branch oder Tag
#    SCAN2NAS_KONFIG=/pfad.conf    ohne Dialoge mit dieser Datei einrichten
#    GITHUB_TOKEN=…                nur nötig, falls das Repository privat ist
#                                  (oder: GitHub-CLI angemeldet, dann automatisch)
#
#  Privates Repository? Dann statt curl die GitHub-CLI benutzen:
#    apt install -y gh && gh auth login
#    bash -c "$(gh api -H 'Accept: application/vnd.github.v3.raw' repos/developer2013/bjoerni/contents/einrichten.sh)"
# =====================================================================
set -euo pipefail

REPO="developer2013/bjoerni"
REF="${SCAN2NAS_REF:-main}"
GESPEICHERT="/root/.scan2nas/proxmox.conf"
TITEL="scan2nas"
HINTERGRUND="scan2nas – Scans vom Canon TR8550 über Proxmox aufs NAS"

# Alle Einstellungen, die gespeichert und an proxmox/lxc-erstellen.sh übergeben werden
KONFIG_VARIABLEN=(
  CT_ID CT_NAME CT_SPEICHER TEMPLATE_SPEICHER CT_BRIDGE CT_IP CT_GATEWAY CT_VLAN
  CT_KERNE CT_RAM CT_SWAP CT_DISK CT_PASSWORT CT_SSH_SCHLUESSEL KONSOLE_AUTOLOGIN
  SCANNER_IP
  NAS_TYP NAS_SERVER NAS_FREIGABE NAS_BENUTZER NAS_PASSWORT NAS_DOMAENE SMB_VERSION
  NAS_UNTERORDNER HOST_MOUNTPUNKT
)

info()   { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()     { printf '\033[1;32m ✔ \033[0m %s\n' "$*"; }
warn()   { printf '\033[1;33m ! \033[0m %s\n' "$*" >&2; }
fehler() { printf '\033[1;31m ✘ \033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------
#  Prüf- und Hilfsfunktionen (ohne Dialoge – werden auch getestet)
# ---------------------------------------------------------------------
ist_ipv4() {
  local teil
  [[ $1 =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  for teil in "${BASH_REMATCH[@]:1}"; do
    (( 10#$teil <= 255 )) || return 1
  done
}

ist_cidr() {   # z. B. 192.168.178.60/24
  [[ $1 == */* ]] || return 1
  ist_ipv4 "${1%/*}" || return 1
  [[ ${1#*/} =~ ^[0-9]{1,2}$ ]] || return 1
  (( ${1#*/} >= 1 && ${1#*/} <= 32 ))
}

ist_zahl() { [[ $1 =~ ^[0-9]+$ ]]; }

ist_hostname() { [[ $1 =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]; }

ist_unterordner() {   # relativ, ohne Leerzeichen-Probleme, ohne ..
  [[ -n $1 && $1 != /* && $1 != *..* ]]
}

standardwerte_setzen() {
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
  KONSOLE_AUTOLOGIN="${KONSOLE_AUTOLOGIN:-ja}"
  SCANNER_IP="${SCANNER_IP:-}"
  NAS_TYP="${NAS_TYP:-cifs}"
  NAS_SERVER="${NAS_SERVER:-}"
  NAS_FREIGABE="${NAS_FREIGABE:-scans}"
  NAS_BENUTZER="${NAS_BENUTZER:-scanner}"
  NAS_PASSWORT="${NAS_PASSWORT:-}"
  NAS_DOMAENE="${NAS_DOMAENE:-}"
  SMB_VERSION="${SMB_VERSION:-3.0}"
  NAS_UNTERORDNER="${NAS_UNTERORDNER:-Scans}"
  HOST_MOUNTPUNKT="${HOST_MOUNTPUNKT:-/mnt/scan2nas}"
}

# Schreibt alle Einstellungen so, dass "source" sie exakt zurückliest –
# auch Passwörter mit $ ! ' " Leerzeichen usw. (printf %q).
konfig_speichern() {
  local datei="$1" var
  ( umask 077
    mkdir -p "$(dirname "$datei")"
    { echo "# scan2nas – gespeicherte Einstellungen ($(date '+%F %T'))"
      echo "# Erzeugt von einrichten.sh. Enthält das NAS-Passwort – nur für root lesbar."
      for var in "${KONFIG_VARIABLEN[@]}"; do
        printf '%s=%q\n' "$var" "${!var-}"
      done
    } > "$datei" )
  chmod 600 "$datei"
}

# Gibt den Modellnamen aus, wenn unter der IP ein eSCL-Scanner antwortet.
escl_modell() {
  local antwort modell
  antwort="$(curl -fsS -m 2 "http://$1/eSCL/ScannerCapabilities" 2>/dev/null)" || return 1
  [[ $antwort == *ScannerCapabilities* ]] || return 1
  modell="$(grep -o '<pwg:MakeAndModel>[^<]*' <<<"$antwort" | head -n1 | cut -d'>' -f2 || true)"
  printf '%s\n' "${modell:-eSCL-Scanner}"
}

nas_fehler_erklaeren() {
  local m="$1"
  case $m in
    *"error(13)"*)                 echo "Benutzername oder Passwort ist falsch – oder der Benutzer hat kein Recht auf die Freigabe." ;;
    *"error(2)"*)                  echo "Diese Freigabe gibt es nicht. Gemeint ist der NAME der Freigabe (z. B. scans), nicht ein Ordnerpfad." ;;
    *"error(112)"*|*"error(95)"*)  echo "Das NAS spricht keine passende SMB-Version (3.0, 3.1.1 und 2.1 wurden probiert)." ;;
    *"access denied"*)             echo "Das NAS verweigert den Zugriff. Bei NFS: Client-IP in den Freigaberegeln muss die des Proxmox-Hosts sein." ;;
    *"No such file"*)              echo "Diesen Exportpfad gibt es auf dem NAS nicht." ;;
    *"error(115)"*|*"error(113)"*|*"timed out"*|"") echo "Das NAS ist nicht erreichbar – IP-Adresse falsch, NAS aus oder Firewall?" ;;
    *)                             echo "Unbekannter Fehler." ;;
  esac
  printf '\nMeldung: %s\n' "${m:-Zeitüberschreitung}"
}

aktive_speicher() {   # $1 = Inhaltstyp (rootdir | vztmpl)
  pvesm status -content "$1" 2>/dev/null | awk 'NR>1 && $3=="active" {print $1}'
}

speicher_vorschlagen() {   # $1 = Inhaltstyp, weitere = bevorzugte Namen
  local liste kandidat
  liste="$(aktive_speicher "$1")"
  shift
  for kandidat in "$@"; do
    if grep -qx "$kandidat" <<<"$liste"; then echo "$kandidat"; return; fi
  done
  head -n1 <<<"$liste"
}

# ---------------------------------------------------------------------
#  Dialoge (whiptail). Die Helfer schreiben ihr Ergebnis per printf -v in
#  eine Variable – so kann "abbruch" das ganze Skript beenden (aus einem
#  $(…) heraus ginge das nicht).
# ---------------------------------------------------------------------
abbruch() { clear; warn "Abgebrochen – es wurde nichts verändert."; exit 0; }

eingabe() {   # eingabe VARIABLE "Frage" "Vorgabe"
  local antwort
  antwort="$(whiptail --backtitle "$HINTERGRUND" --title "$TITEL" \
             --inputbox "$2" 14 76 "${3:-}" 3>&1 1>&2 2>&3)" || abbruch
  printf -v "$1" '%s' "$antwort"
}

passwort() {   # passwort VARIABLE "Frage"
  local antwort
  antwort="$(whiptail --backtitle "$HINTERGRUND" --title "$TITEL" \
             --passwordbox "$2" 14 76 3>&1 1>&2 2>&3)" || abbruch
  printf -v "$1" '%s' "$antwort"
}

auswahl() {   # auswahl VARIABLE "Frage" "Vorauswahl" schluessel1 text1 schluessel2 text2 …
  local var="$1" frage="$2" vorgabe="$3" antwort
  shift 3
  local extra=()
  if [[ -n $vorgabe ]]; then extra=(--default-item "$vorgabe"); fi
  antwort="$(whiptail --backtitle "$HINTERGRUND" --title "$TITEL" ${extra[@]+"${extra[@]}"} \
             --menu "$frage" 22 78 10 "$@" 3>&1 1>&2 2>&3)" || abbruch
  printf -v "$var" '%s' "$antwort"
}

janein() {   # janein "Frage" [--defaultno]  → 0 = Ja
  whiptail --backtitle "$HINTERGRUND" --title "$TITEL" ${2:+"$2"} --yesno "$1" 22 78
}

hinweis() { whiptail --backtitle "$HINTERGRUND" --title "$TITEL" --msgbox "$1" 20 78; }

bitte_warten() { whiptail --backtitle "$HINTERGRUND" --title "$TITEL" --infobox "$1" 9 66; }

# ---------------------------------------------------------------------
#  Einzelne Dialogschritte
# ---------------------------------------------------------------------
container_automatisch() {
  local s
  s="$(speicher_vorschlagen rootdir "$CT_SPEICHER" local-lvm local-zfs)"
  if [[ -n $s ]]; then CT_SPEICHER="$s"; fi
  s="$(speicher_vorschlagen vztmpl "$TEMPLATE_SPEICHER" local)"
  if [[ -n $s ]]; then TEMPLATE_SPEICHER="$s"; fi
  if ! ip link show "$CT_BRIDGE" >/dev/null 2>&1; then
    s="$(ip -o link show type bridge 2>/dev/null | awk -F': ' '{print $2; exit}')"
    if [[ -n $s ]]; then CT_BRIDGE="${s%%@*}"; fi
  fi
}

container_dialoge() {
  local wert eintraege=() name typ frei var

  while true; do
    eingabe CT_NAME "Name des Containers:" "$CT_NAME"
    if ist_hostname "$CT_NAME"; then break; fi
    hinweis "Bitte nur Buchstaben, Ziffern und Bindestriche verwenden."
  done

  while true; do
    eingabe CT_ID "Container-ID\n\nLeer lassen = automatisch (nächste freie ID bzw. vorhandener Container mit dem Namen '$CT_NAME')." "$CT_ID"
    if [[ -z $CT_ID ]] || { ist_zahl "$CT_ID" && (( CT_ID >= 100 )); }; then break; fi
    hinweis "Die Container-ID muss eine Zahl ab 100 sein (oder leer)."
  done

  eintraege=()
  while read -r name typ _ _ _ frei _; do
    eintraege+=("$name" "$typ, frei: $(( frei / 1024 / 1024 )) GB")
  done < <(pvesm status -content rootdir 2>/dev/null | awk 'NR>1 && $3=="active"')
  if (( ${#eintraege[@]} > 2 )); then
    auswahl CT_SPEICHER "Auf welchem Speicher soll die Festplatte des Containers liegen?" "$CT_SPEICHER" "${eintraege[@]}"
  elif (( ${#eintraege[@]} == 2 )); then
    CT_SPEICHER="${eintraege[0]}"
  fi
  wert="$(speicher_vorschlagen vztmpl "$TEMPLATE_SPEICHER" local)"
  if [[ -n $wert ]]; then TEMPLATE_SPEICHER="$wert"; fi

  eintraege=()
  while read -r name; do
    eintraege+=("${name%%@*}" "Netzwerkbrücke")
  done < <(ip -o link show type bridge 2>/dev/null | awk -F': ' '{print $2}')
  if (( ${#eintraege[@]} > 2 )); then
    auswahl CT_BRIDGE "Über welche Netzwerkbrücke soll der Container ins Netz?" "$CT_BRIDGE" "${eintraege[@]}"
  elif (( ${#eintraege[@]} == 2 )); then
    CT_BRIDGE="${eintraege[0]}"
  fi

  auswahl wert "Wie bekommt der Container seine IP-Adresse?" "$([[ $CT_IP == dhcp ]] && echo dhcp || echo fest)" \
    dhcp "automatisch vom Router (DHCP)" \
    fest "feste IP-Adresse eintragen"
  if [[ $wert == dhcp ]]; then
    CT_IP="dhcp"; CT_GATEWAY=""
  else
    while true; do
      eingabe CT_IP "Feste IP-Adresse MIT Netzmaske, z. B. 192.168.178.60/24:" "$([[ $CT_IP == dhcp ]] || echo "$CT_IP")"
      if ist_cidr "$CT_IP"; then break; fi
      hinweis "Das ist keine gültige Adresse. Beispiel: 192.168.178.60/24"
    done
    while true; do
      eingabe CT_GATEWAY "Gateway (meist der Router), z. B. 192.168.178.1:" "$CT_GATEWAY"
      if ist_ipv4 "$CT_GATEWAY"; then break; fi
      hinweis "Das ist keine gültige IP-Adresse."
    done
  fi

  while true; do
    eingabe CT_VLAN "VLAN-Tag (leer lassen, wenn du keine VLANs nutzt):" "$CT_VLAN"
    if [[ -z $CT_VLAN ]] || ist_zahl "$CT_VLAN"; then break; fi
    hinweis "Der VLAN-Tag muss eine Zahl sein."
  done

  for var in CT_KERNE:"CPU-Kerne" CT_RAM:"Arbeitsspeicher in MB" CT_DISK:"Festplatte in GB"; do
    name="${var%%:*}"
    while true; do
      eingabe "$name" "${var#*:}:" "${!name}"
      if ist_zahl "${!name}" && (( ${!name} > 0 )); then break; fi
      hinweis "Bitte eine Zahl größer 0 eingeben."
    done
  done

  passwort CT_PASSWORT "root-Passwort für den Container (optional)\n\nLeer lassen = kein Passwort. Die Proxmox-Konsole meldet dich dann automatisch als root an (wie bei den Community Scripts)."
  if [[ -n $CT_PASSWORT ]]; then KONSOLE_AUTOLOGIN="nein"; else KONSOLE_AUTOLOGIN="ja"; fi
}

scanner_suchen() {
  SCANNER_TREFFER=()
  local adresse netz zeile
  adresse="$(ip -4 -o addr show dev "$CT_BRIDGE" 2>/dev/null | awk '{print $4; exit}')"
  if [[ -z $adresse ]]; then return 0; fi
  adresse="${adresse%/*}"
  netz="${adresse%.*}"
  bitte_warten "Suche Scanner im Netz $netz.0/24 …\n\n(dauert bis zu 10 Sekunden)"
  export -f escl_modell
  while IFS= read -r zeile; do
    if [[ -n $zeile ]]; then SCANNER_TREFFER+=("$zeile"); fi
  done < <(seq 1 254 \
           | xargs -P 64 -I{} bash -c 'm="$(escl_modell "$1")" && printf "%s|%s\n" "$1" "$m"' _ "$netz.{}" 2>/dev/null \
           | sort -t. -k4,4n || true)
}

scanner_dialog() {
  local eintraege=() zeile wahl=""
  SCANNER_MODELL=""
  scanner_suchen
  if (( ${#SCANNER_TREFFER[@]} > 0 )); then
    for zeile in "${SCANNER_TREFFER[@]}"; do
      eintraege+=("${zeile%%|*}" "${zeile#*|}")
    done
    eintraege+=(manuell "IP-Adresse selbst eingeben")
    auswahl wahl "Diese Scanner habe ich gefunden. Welcher ist deiner?" "$SCANNER_IP" "${eintraege[@]}"
    if [[ $wahl != manuell ]]; then
      SCANNER_IP="$wahl"
      for zeile in "${SCANNER_TREFFER[@]}"; do
        if [[ ${zeile%%|*} == "$wahl" ]]; then SCANNER_MODELL="${zeile#*|}"; fi
      done
      return 0
    fi
  else
    hinweis "Ich habe im Netz keinen Scanner gefunden.\n\nIst der Drucker eingeschaltet und im selben Netzwerk? Du kannst die IP-Adresse auch selbst eingeben (steht im Router oder am Drucker unter den LAN-Einstellungen)."
  fi

  while true; do
    eingabe SCANNER_IP "IP-Adresse des Canon TR8550:\n\nTipp: Gib dem Drucker im Router eine feste IP, damit er immer gefunden wird." "$SCANNER_IP"
    if ! ist_ipv4 "$SCANNER_IP"; then hinweis "Das ist keine gültige IP-Adresse."; continue; fi
    bitte_warten "Frage den Scanner unter $SCANNER_IP …"
    if SCANNER_MODELL="$(escl_modell "$SCANNER_IP")"; then return 0; fi
    SCANNER_MODELL=""
    if janein "Unter $SCANNER_IP antwortet kein Scanner (eSCL).\n\nTrotzdem diese Adresse verwenden? (z. B. wenn der Drucker gerade aus ist)" --defaultno; then
      return 0
    fi
  done
}

nas_testen() {
  local mp zugang="" quelle meldung="" version ergebnis=1
  mp="$(mktemp -d /tmp/scan2nas-test.XXXXXX)"
  bitte_warten "Teste den Zugang zum NAS …"
  if [[ $NAS_TYP == cifs ]]; then
    command -v mount.cifs >/dev/null 2>&1 || apt-get install -y -qq cifs-utils >/dev/null
    zugang="$(mktemp /tmp/scan2nas-zugang.XXXXXX)"   # mktemp legt die Datei mit 0600 an
    { printf 'username=%s\npassword=%s\n' "$NAS_BENUTZER" "$NAS_PASSWORT"
      if [[ -n $NAS_DOMAENE ]]; then printf 'domain=%s\n' "$NAS_DOMAENE"; fi
    } > "$zugang"
    quelle="//$NAS_SERVER/${NAS_FREIGABE#/}"
    for version in "$SMB_VERSION" 3.0 3.1.1 2.1; do
      if meldung="$(timeout 25 mount -t cifs -o "credentials=$zugang,vers=$version" "$quelle" "$mp" 2>&1)"; then
        SMB_VERSION="$version"; ergebnis=0; break
      fi
      # nur bei Versionsproblemen eine andere SMB-Version probieren
      [[ $meldung == *"error(95)"* || $meldung == *"error(112)"* ]] || break
    done
  else
    command -v mount.nfs >/dev/null 2>&1 || apt-get install -y -qq nfs-common >/dev/null
    quelle="$NAS_SERVER:$NAS_FREIGABE"
    if meldung="$(timeout 25 mount -t nfs "$quelle" "$mp" 2>&1)"; then ergebnis=0; fi
  fi
  if (( ergebnis == 0 )); then
    umount "$mp" 2>/dev/null || umount -l "$mp" 2>/dev/null || true
  else
    NAS_FEHLER="$(nas_fehler_erklaeren "$meldung")"
  fi
  if [[ -n $zugang ]]; then rm -f "$zugang"; fi
  rmdir "$mp" 2>/dev/null || true
  return "$ergebnis"
}

nas_dialoge() {
  local neues_passwort
  while true; do
    auswahl NAS_TYP "Wie ist dein NAS freigegeben?" "$NAS_TYP" \
      cifs "SMB / Windows-Freigabe (Synology, QNAP, FRITZ!Box …) – empfohlen" \
      nfs  "NFS-Freigabe (für Fortgeschrittene)"

    while true; do
      eingabe NAS_SERVER "IP-Adresse (oder Name) des NAS:" "$NAS_SERVER"
      if ist_ipv4 "$NAS_SERVER" || ist_hostname "$NAS_SERVER"; then break; fi
      hinweis "Das ist keine gültige Adresse."
    done

    if [[ $NAS_TYP == cifs ]]; then
      while true; do
        eingabe NAS_FREIGABE "Name der Freigabe auf dem NAS:\n\nBeispiel: scans  (ergibt //$NAS_SERVER/scans)" "$NAS_FREIGABE"
        NAS_FREIGABE="${NAS_FREIGABE#/}"
        if [[ -n $NAS_FREIGABE && $NAS_FREIGABE != *" "* ]]; then break; fi
        hinweis "Bitte den Namen der Freigabe eingeben (ohne Leerzeichen)."
      done
      while true; do
        eingabe NAS_BENUTZER "Benutzername auf dem NAS (mit Schreibrecht auf die Freigabe):" "$NAS_BENUTZER"
        if [[ -n $NAS_BENUTZER ]]; then break; fi
      done
      if [[ -n $NAS_PASSWORT ]]; then
        passwort neues_passwort "Passwort für '$NAS_BENUTZER':\n\n(leer lassen = bisheriges Passwort behalten)"
        if [[ -n $neues_passwort ]]; then NAS_PASSWORT="$neues_passwort"; fi
      else
        passwort NAS_PASSWORT "Passwort für '$NAS_BENUTZER':"
      fi
    else
      while true; do
        eingabe NAS_FREIGABE "Exportpfad der NFS-Freigabe, z. B. /volume1/scans:" "$([[ $NAS_FREIGABE == /* ]] && echo "$NAS_FREIGABE")"
        if [[ $NAS_FREIGABE == /* && $NAS_FREIGABE != *" "* ]]; then break; fi
        hinweis "Der Exportpfad muss mit / beginnen (ohne Leerzeichen)."
      done
    fi

    while true; do
      eingabe NAS_UNTERORDNER "In welchen Ordner innerhalb der Freigabe sollen die Scans?\n\n(wird angelegt, falls er fehlt)" "$NAS_UNTERORDNER"
      if ist_unterordner "$NAS_UNTERORDNER" && [[ $NAS_UNTERORDNER != *" "* ]]; then break; fi
      hinweis "Bitte einen Ordnernamen ohne / am Anfang, ohne .. und ohne Leerzeichen eingeben."
    done

    if nas_testen; then return 0; fi
    janein "Der Zugang zum NAS hat nicht geklappt:\n\n$NAS_FEHLER\n\nEingaben korrigieren?" || abbruch
  done
}

zusammenfassung() {
  local netz nas konsole
  if [[ $CT_IP == dhcp ]]; then netz="DHCP über $CT_BRIDGE"; else netz="$CT_IP, Gateway $CT_GATEWAY, über $CT_BRIDGE"; fi
  if [[ -n $CT_VLAN ]]; then netz+=", VLAN $CT_VLAN"; fi
  if [[ $NAS_TYP == cifs ]]; then
    nas="SMB //$NAS_SERVER/$NAS_FREIGABE (Benutzer $NAS_BENUTZER, SMB $SMB_VERSION)"
  else
    nas="NFS $NAS_SERVER:$NAS_FREIGABE"
  fi
  if [[ $KONSOLE_AUTOLOGIN == ja ]]; then konsole="automatisch als root"; else konsole="mit Passwort"; fi

  janein "Bitte prüfen:

 Scanner:      $SCANNER_IP ${SCANNER_MODELL:+($SCANNER_MODELL)}
 NAS:          $nas
 Scan-Ordner:  $NAS_UNTERORDNER

 Container:    $CT_NAME, ID ${CT_ID:-automatisch}
               $CT_KERNE Kerne, $CT_RAM MB RAM, $CT_DISK GB auf $CT_SPEICHER
 Netzwerk:     $netz
 Konsole:      $konsole

Jetzt einrichten? Das dauert beim ersten Mal ca. 5–10 Minuten." || abbruch
}

dialoge() {
  local modus art
  if [[ -f $GESPEICHERT ]]; then
    # shellcheck source=/dev/null
    source "$GESPEICHERT"
    standardwerte_setzen
    auswahl modus "scan2nas ist auf diesem Host schon eingerichtet (Container '$CT_NAME').\n\nWas möchtest du tun?" "aktualisieren" \
      aktualisieren "Neueste Version installieren, Einstellungen behalten" \
      aendern       "Einstellungen ändern (bisherige Werte sind vorausgefüllt)" \
      abbrechen     "Nichts tun"
    case $modus in
      aktualisieren) return 0 ;;
      abbrechen)     abbruch ;;
    esac
  else
    standardwerte_setzen
    hinweis "Willkommen bei scan2nas!

Dieser Assistent richtet auf deinem Proxmox einen kleinen Container ein, der die Scans von deinem Canon TR8550 holt und als durchsuchbares PDF auf dein NAS legt.

Du brauchst:
 • den Drucker eingeschaltet im selben Netzwerk
 • eine Freigabe auf dem NAS und einen Benutzer mit Schreibrecht

Erst wenn du am Ende alles bestätigst, wird etwas verändert."
  fi

  auswahl art "Wie möchtest du einrichten?" "einfach" \
    einfach   "Empfohlen: nur Scanner und NAS abfragen, Rest automatisch" \
    erweitert "Container-ID, Speicher, Netzwerk und Ressourcen selbst festlegen"
  container_automatisch
  if [[ $art == erweitert ]]; then container_dialoge; fi

  scanner_dialog
  nas_dialoge
  zusammenfassung
  konfig_speichern "$GESPEICHERT"
}

# ---------------------------------------------------------------------
#  Vorprüfung, Download, Installation
# ---------------------------------------------------------------------
vorpruefungen() {
  [[ $EUID -eq 0 ]] || fehler "Bitte als root ausführen."
  if ! command -v pct >/dev/null 2>&1 || [[ ! -d /etc/pve ]]; then
    fehler "Das ist kein Proxmox-Host. Bitte in der Shell des Proxmox-Hosts ausführen (Proxmox-Oberfläche → Knoten → Shell)."
  fi
  if [[ ! -t 0 || ! -t 1 ]]; then
    fehler "Kein Terminal gefunden. Bitte genau so starten:  bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/$REPO/main/einrichten.sh)\""
  fi
  local version
  version="$(pveversion 2>/dev/null | grep -oE 'pve-manager/[0-9]+' | cut -d/ -f2 || true)"
  if [[ -n $version ]] && (( version < 8 )); then
    warn "Proxmox VE $version ist älter als getestet (8 und 9) – es kann trotzdem klappen."
  fi
  local programm
  for programm in curl tar; do
    command -v "$programm" >/dev/null 2>&1 || fehler "$programm fehlt (apt install $programm)."
  done
  if ! command -v whiptail >/dev/null 2>&1; then
    info "Installiere whiptail (für die Dialogfenster) …"
    apt-get install -y -qq whiptail >/dev/null
  fi
  curl -fsS -m 10 -o /dev/null https://github.com \
    || fehler "Keine Verbindung zu github.com – hat der Proxmox-Host Internet?"
}

repo_holen() {
  ARBEIT="$(mktemp -d /tmp/scan2nas.XXXXXX)"
  trap 'rm -rf "$ARBEIT"' EXIT
  local url="https://github.com/$REPO/archive/$REF.tar.gz"
  local kopf=() token="${GITHUB_TOKEN:-}"
  # Privates Repository: Anmeldung der GitHub-CLI nutzen, falls vorhanden (gh auth login)
  if [[ -z $token ]] && command -v gh >/dev/null 2>&1; then
    token="$(gh auth token 2>/dev/null || true)"
  fi
  if [[ -n $token ]]; then
    url="https://api.github.com/repos/$REPO/tarball/$REF"
    kopf=(-H "Authorization: Bearer $token")
  fi
  info "Lade scan2nas herunter ($REPO, $REF) …"
  curl -fsSL ${kopf[@]+"${kopf[@]}"} "$url" | tar -xz -C "$ARBEIT" --strip-components=1 \
    || fehler "Download fehlgeschlagen: $url"
  [[ -f $ARBEIT/proxmox/lxc-erstellen.sh ]] || fehler "Heruntergeladenes Projekt ist unvollständig."
}

installieren() {
  local konfig="$1"
  clear
  printf '\033[1;36m%s\033[0m\n' \
    "  ┌──────────────────────────────────────────────┐" \
    "  │  scan2nas · Canon TR8550 → Proxmox → NAS     │" \
    "  └──────────────────────────────────────────────┘"
  echo
  repo_holen
  if bash "$ARBEIT/proxmox/lxc-erstellen.sh" "$konfig"; then
    echo
    ok "Einstellungen gespeichert in $konfig"
    echo "   Später aktualisieren: denselben Befehl noch einmal ausführen → „Aktualisieren“"
    echo "   Anleitung:            https://github.com/$REPO"
  else
    echo
    fehler "Die Einrichtung wurde abgebrochen (Grund siehe oben). Deine Eingaben sind gespeichert:
   Befehl erneut ausführen → „Einstellungen ändern“.
   Hilfe: https://github.com/$REPO/blob/main/docs/04-fehlerbehebung.md"
  fi
}

main() {
  vorpruefungen
  if [[ -n ${SCAN2NAS_KONFIG:-} ]]; then
    [[ -f $SCAN2NAS_KONFIG ]] || fehler "SCAN2NAS_KONFIG=$SCAN2NAS_KONFIG gibt es nicht."
    installieren "$SCAN2NAS_KONFIG"
  else
    dialoge
    installieren "$GESPEICHERT"
  fi
}

# Mit SCAN2NAS_NUR_LADEN=1 werden nur die Funktionen geladen (für die Tests).
if [[ ${SCAN2NAS_NUR_LADEN:-} != 1 ]]; then
  main "$@"
fi
