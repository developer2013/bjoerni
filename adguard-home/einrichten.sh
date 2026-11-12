#!/usr/bin/env bash
# =====================================================================
#  AdGuard Home auf Proxmox – Einrichtung mit einem einzigen Befehl
#
#  In der Shell des Proxmox-Hosts als root:
#
#    bash -c "$(curl -fsSL https://raw.githubusercontent.com/developer2013/bjoerni/main/adguard-home/einrichten.sh)"
#
#  Das Skript findet deinen AdGuard-Container (z. B. vom Community Script)
#  oder legt einen neuen an und stellt alles so ein, wie es die Anleitung in
#  adguard-home/ beschreibt:
#    • Einrichtungsassistent (Benutzer, Passwort, Ports 80 und 53)
#    • verschlüsselte Upstream-DNS (Quad9, DNS4EU) mit Bootstrap und Fallback
#    • Gerätenamen über den Router, DNSSEC, Ratenlimit-Ausnahme für den Router
#    • Sperrlisten (HaGeZi), Internetsicherheit, Protokoll 7 / Statistik 30 Tage
#    • eigene Namen wie scanner.lan, drucker.lan, proxmox.lan
#    • feste IP und Startreihenfolge in Proxmox (AdGuard startet zuerst)
#  Die FRITZ!Box stellst du danach selbst um – das Skript zeigt dir die Werte.
#
#  Mehrfach ausführen ist gefahrlos: Vorhandenes wird erkannt und nicht doppelt
#  angelegt. Dein AdGuard-Passwort wird nirgends gespeichert.
# =====================================================================
set -euo pipefail

TITEL="AdGuard Home"
HINTERGRUND="AdGuard Home auf Proxmox – Werbung und Tracker im ganzen Heimnetz blocken"
ANLEITUNG="https://github.com/developer2013/bjoerni/tree/main/adguard-home"

# Adressen und Ports (die AG_*-Werte lassen sich für Tests überschreiben)
AG_IP="${AG_IP:-}"
AG_SETUP_PORT="${AG_SETUP_PORT:-3000}"
AG_WEB_PORT="${AG_WEB_PORT:-80}"
AG_DNS_PORT="${AG_DNS_PORT:-53}"
AG_BIND_IP="${AG_BIND_IP:-0.0.0.0}"

UPSTREAMS=(https://dns.quad9.net/dns-query https://unfiltered.joindns4.eu/dns-query)
BOOTSTRAP=(9.9.9.9 149.112.112.112)
FALLBACK=(9.9.9.9)
KATALOG="https://adguardteam.github.io/HostlistsRegistry/assets"
LISTE_NORMAL="$KATALOG/filter_34.txt"   # HaGeZi's Normal Blocklist
LISTE_PRO="$KATALOG/filter_48.txt"      # HaGeZi's Pro Blocklist
LISTE_THREAT="$KATALOG/filter_44.txt"   # HaGeZi's Threat Intelligence Feeds
PROTOKOLL_MS=$(( 7 * 24 * 3600 * 1000 ))
STATISTIK_MS=$(( 30 * 24 * 3600 * 1000 ))

info()   { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()     { printf '\033[1;32m ✔ \033[0m %s\n' "$*"; }
warn()   { printf '\033[1;33m ! \033[0m %s\n' "$*" >&2; }
fehler() { printf '\033[1;31m ✘ \033[0m %s\n' "$*" >&2; exit 1; }

TEMP_DATEIEN=()
aufraeumen() { if (( ${#TEMP_DATEIEN[@]} )); then rm -f "${TEMP_DATEIEN[@]}"; fi; }
trap aufraeumen EXIT

# =====================================================================
#  Reine Hilfsfunktionen (ohne Netzwerk – werden getestet)
# =====================================================================
json_liste() { printf '%s\n' "$@" | jq -R . | jq -s -c .; }

ist_ipv4() {
  local teil
  [[ $1 =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  for teil in "${BASH_REMATCH[@]:1}"; do (( 10#$teil <= 255 )) || return 1; done
}

ist_cidr() {
  [[ $1 == */* ]] || return 1
  ist_ipv4 "${1%/*}" || return 1
  [[ ${1#*/} =~ ^[0-9]{1,2}$ ]] && (( ${1#*/} >= 8 && ${1#*/} <= 32 ))
}

# AdGuard verlangt 8 bis 72 Zeichen (72 Byte ist die Grenze von bcrypt).
passwort_pruefen() {
  local laenge
  laenge="$(LC_ALL=C; printf '%s' "$1" | wc -c | tr -d ' ')"
  (( laenge >= 8 && laenge <= 72 ))
}

# DNS-Einstellungen als JSON. $1 Router-IP, $2 ja/nein FRITZ!Box,
# $3 bisherige Ratenlimit-Ausnahmen (JSON-Liste) – der Router kommt dazu.
json_dns_config() {
  local router="$1" fritzbox="$2" bisher="${3:-[]}"
  local upstreams=("${UPSTREAMS[@]}")
  if [[ $fritzbox == ja ]]; then upstreams+=("[/fritz.box/]$router"); fi
  jq -n -c \
    --argjson upstream "$(json_liste "${upstreams[@]}")" \
    --argjson bootstrap "$(json_liste "${BOOTSTRAP[@]}")" \
    --argjson fallback "$(json_liste "${FALLBACK[@]}")" \
    --argjson bisher "$bisher" \
    --arg router "$router" \
    '{upstream_dns: $upstream, bootstrap_dns: $bootstrap, fallback_dns: $fallback,
      upstream_mode: "load_balance",
      local_ptr_upstreams: [$router], use_private_ptr_resolvers: true, resolve_clients: true,
      dnssec_enabled: true, protection_enabled: true,
      ratelimit_whitelist: (($bisher // []) + [$router] | unique)}'
}

json_upstream_test() {
  local router="$1" fritzbox="$2" upstreams=("${UPSTREAMS[@]}")
  if [[ $fritzbox == ja ]]; then upstreams+=("[/fritz.box/]$router"); fi
  jq -n -c --argjson u "$(json_liste "${upstreams[@]}")" --argjson b "$(json_liste "${BOOTSTRAP[@]}")" \
    '{upstream_dns: $u, bootstrap_dns: $b, fallback_dns: [], private_upstream: []}'
}

# Erstkonfiguration. Benutzer und Passwort kommen über die Umgebung
# (AG_BENUTZER, AG_PASSWORT) – so tauchen sie in keiner Prozessliste auf.
json_ersteinrichtung() {
  jq -n -c --arg ip "$AG_BIND_IP" --argjson web "$AG_WEB_PORT" --argjson dns "$AG_DNS_PORT" \
    '{web: {ip: $ip, port: $web}, dns: {ip: $ip, port: $dns}, language: "de",
      username: $ENV.AG_BENUTZER, password: $ENV.AG_PASSWORT}'
}

# Welche Sperrlisten fehlen noch? $1 = Antwort von /filtering/status, Rest = URLs
fehlende_listen() {
  local status="$1" url
  shift
  for url in "$@"; do
    if ! jq -e --arg u "$url" '[.filters[]?.url] | index($u)' <<<"$status" >/dev/null; then
      echo "$url"
    fi
  done
}

# Plant die DNS-Umschreibungen. $1 = Antwort von /rewrite/list, Rest = "domain=ip".
# Ausgabe je Zeile: "neu <domain> <ip>" | "gleich <domain> <ip>" | "anders <domain> <alt> <neu>"
umschreibungen_planen() {
  local liste="$1" eintrag domain ip alt
  shift
  for eintrag in "$@"; do
    domain="${eintrag%%=*}"; ip="${eintrag#*=}"
    alt="$(jq -r --arg d "$domain" '[.[]? | select(.domain == $d) | .answer] | first // empty' <<<"$liste")"
    if [[ -z $alt ]]; then echo "neu $domain $ip"
    elif [[ $alt == "$ip" ]]; then echo "gleich $domain $ip"
    else echo "anders $domain $alt $ip"
    fi
  done
}

# =====================================================================
#  AdGuard-API (/control, Basic-Auth)
# =====================================================================
AG_CURL_KONFIG=/dev/null
AG_HTTP=""
AG_ANTWORT=""

# Der Anmelde-Header steht in einer temporären 0600-Datei, nie auf der Kommandozeile.
ag_zugang_setzen() {
  AG_CURL_KONFIG="$(mktemp)"
  TEMP_DATEIEN+=("$AG_CURL_KONFIG")
  printf 'header = "Authorization: Basic %s"\n' \
    "$(printf '%s:%s' "$1" "$2" | base64 | tr -d '\n')" > "$AG_CURL_KONFIG"
}

# ag_api METHODE PFAD [JSON] – setzt AG_HTTP und AG_ANTWORT, Erfolg = HTTP 2xx
ag_api() {
  local methode="$1" pfad="$2" daten="${3-}" roh
  local args=(-sS -m "${AG_ZEITLIMIT:-30}" -X "$methode" -K "$AG_CURL_KONFIG" -w $'\n%{http_code}')
  if [[ -n $daten ]]; then args+=(-H 'Content-Type: application/json' --data-binary @-); fi
  if ! roh="$(printf '%s' "$daten" | curl "${args[@]}" "http://$AG_IP:$AG_WEB_PORT/control$pfad" 2>&1)"; then
    AG_HTTP="000"; AG_ANTWORT="$roh"; return 1
  fi
  AG_HTTP="${roh##*$'\n'}"
  AG_ANTWORT="${roh%$'\n'*}"
  [[ $AG_HTTP == 2* ]]
}

ag_setup_offen() {
  curl -fsS -m 5 -o /dev/null "http://$AG_IP:$AG_SETUP_PORT/control/install/get_addresses" 2>/dev/null
}

ag_web_antwortet() {
  curl -sS -m 3 -o /dev/null "http://$AG_IP:$AG_WEB_PORT/control/status" 2>/dev/null
}

ag_ersteinrichtung() {   # Benutzer, Passwort
  local roh code
  roh="$(json_ersteinrichtung | curl -sS -m 60 -H 'Content-Type: application/json' --data-binary @- \
          -w $'\n%{http_code}' "http://$AG_IP:$AG_SETUP_PORT/control/install/configure" 2>&1)" || {
    AG_ANTWORT="$roh"; return 1; }
  code="${roh##*$'\n'}"
  AG_ANTWORT="${roh%$'\n'*}"
  [[ $code == 200 ]] || return 1
  local i
  for i in $(seq 1 30); do
    if ag_web_antwortet; then return 0; fi
    sleep 1
  done
  AG_ANTWORT="AdGuard antwortet nach der Einrichtung nicht auf Port $AG_WEB_PORT."
  return 1
}

ag_anmelden_pruefen() { ag_api GET /status; }

# Prüft die Upstream-Server. Setzt UPSTREAM_FEHLER (leer = alle OK).
ag_upstreams_testen() {
  UPSTREAM_FEHLER=""
  AG_ZEITLIMIT=60 ag_api POST /test_upstream_dns "$(json_upstream_test "$1" "$2")" || {
    UPSTREAM_FEHLER="Test nicht möglich (HTTP $AG_HTTP): $AG_ANTWORT"; return 1; }
  UPSTREAM_FEHLER="$(jq -r 'to_entries[] | select(.value != "OK") | "\(.key): \(.value)"' <<<"$AG_ANTWORT")"
}

# Wendet alle Einstellungen an. $1 Router, $2 ja/nein FRITZ!Box, $3 Filterstufe
# (normal|pro|keine), $4 ja/nein Threat-Liste, weitere: "domain=ip" für Umschreibungen.
# Schreibt jede Änderung als Zeile nach stdout.
ag_einstellungen_anwenden() {
  local router="$1" fritzbox="$2" stufe="$3" threat="$4"
  shift 4
  local bisher listen=() url name zeile art domain wert neu

  ag_api GET /dns_info || { echo "FEHLER DNS-Einstellungen lesen (HTTP $AG_HTTP)"; return 1; }
  bisher="$(jq -c '.ratelimit_whitelist // []' <<<"$AG_ANTWORT")"
  ag_api POST /dns_config "$(json_dns_config "$router" "$fritzbox" "$bisher")" \
    || { echo "FEHLER DNS-Einstellungen speichern (HTTP $AG_HTTP): $AG_ANTWORT"; return 1; }
  echo "OK Upstream-DNS: Quad9 + DNS4EU (verschlüsselt), Bootstrap, Fallback"
  echo "OK Gerätenamen über $router, DNSSEC an, Ratenlimit-Ausnahme für $router"

  ag_api POST /safebrowsing/enable || { echo "FEHLER Internetsicherheit (HTTP $AG_HTTP)"; return 1; }
  echo "OK Webservice für Internetsicherheit an"

  ag_api GET /querylog/config || { echo "FEHLER Protokoll lesen (HTTP $AG_HTTP)"; return 1; }
  ag_api PUT /querylog/config/update "$(jq -c --argjson ms "$PROTOKOLL_MS" '.enabled = true | .interval = $ms' <<<"$AG_ANTWORT")" \
    || { echo "FEHLER Protokoll speichern (HTTP $AG_HTTP): $AG_ANTWORT"; return 1; }
  ag_api GET /stats/config || { echo "FEHLER Statistik lesen (HTTP $AG_HTTP)"; return 1; }
  ag_api PUT /stats/config/update "$(jq -c --argjson ms "$STATISTIK_MS" '.enabled = true | .interval = $ms' <<<"$AG_ANTWORT")" \
    || { echo "FEHLER Statistik speichern (HTTP $AG_HTTP): $AG_ANTWORT"; return 1; }
  echo "OK Abfrageprotokoll 7 Tage, Statistik 30 Tage"

  case $stufe in
    normal) listen+=("$LISTE_NORMAL") ;;
    pro)    listen+=("$LISTE_PRO") ;;
  esac
  if [[ $threat == ja ]]; then listen+=("$LISTE_THREAT"); fi
  if (( ${#listen[@]} )); then
    ag_api GET /filtering/status || { echo "FEHLER Filter lesen (HTTP $AG_HTTP)"; return 1; }
    while IFS= read -r url; do
      [[ -n $url ]] || continue
      case $url in
        "$LISTE_NORMAL") name="HaGeZi's Normal Blocklist" ;;
        "$LISTE_PRO")    name="HaGeZi's Pro Blocklist" ;;
        *)               name="HaGeZi's Threat Intelligence Feeds" ;;
      esac
      AG_ZEITLIMIT=180 ag_api POST /filtering/add_url \
        "$(jq -n -c --arg n "$name" --arg u "$url" '{name: $n, url: $u, whitelist: false}')" \
        || { echo "FEHLER Sperrliste $name (HTTP $AG_HTTP): $AG_ANTWORT"; return 1; }
      echo "OK Sperrliste hinzugefügt: $name"
    done < <(fehlende_listen "$AG_ANTWORT" "${listen[@]}")
  fi

  if (( $# )); then
    ag_api GET /rewrite/list || { echo "FEHLER Umschreibungen lesen (HTTP $AG_HTTP)"; return 1; }
    while read -r art domain wert neu; do
      case $art in
        neu)
          ag_api POST /rewrite/add "$(jq -n -c --arg d "$domain" --arg a "$wert" '{domain: $d, answer: $a, enabled: true}')" \
            || { echo "FEHLER Umschreibung $domain (HTTP $AG_HTTP): $AG_ANTWORT"; return 1; }
          echo "OK Name: $domain → $wert" ;;
        gleich) echo "OK Name: $domain → $wert (gab es schon)" ;;
        anders) echo "HINWEIS $domain zeigt schon auf $wert, nicht auf $neu – nicht geändert" ;;
      esac
    done < <(umschreibungen_planen "$AG_ANTWORT" "$@")
  fi
}

# Blockt AdGuard Werbung? (doubleclick.net steht in jeder Liste)
ag_blockiert_werbung() {
  ag_api GET "/filtering/check_host?name=doubleclick.net" \
    && [[ "$(jq -r '.reason' <<<"$AG_ANTWORT")" == FilteredBlackList ]]
}

# =====================================================================
#  Dialoge (whiptail) – Ergebnis per printf -v, damit "abbruch" greift
# =====================================================================
abbruch() { clear; warn "Abgebrochen – es wurde nichts verändert, was nicht schon angezeigt wurde."; exit 0; }

eingabe() {
  local antwort
  antwort="$(whiptail --backtitle "$HINTERGRUND" --title "$TITEL" --inputbox "$2" 14 76 "${3:-}" 3>&1 1>&2 2>&3)" || abbruch
  printf -v "$1" '%s' "$antwort"
}
passwort() {
  local antwort
  antwort="$(whiptail --backtitle "$HINTERGRUND" --title "$TITEL" --passwordbox "$2" 14 76 3>&1 1>&2 2>&3)" || abbruch
  printf -v "$1" '%s' "$antwort"
}
auswahl() {
  local var="$1" frage="$2" vorgabe="$3" antwort extra=()
  shift 3
  if [[ -n $vorgabe ]]; then extra=(--default-item "$vorgabe"); fi
  antwort="$(whiptail --backtitle "$HINTERGRUND" --title "$TITEL" ${extra[@]+"${extra[@]}"} \
             --menu "$frage" 22 78 10 "$@" 3>&1 1>&2 2>&3)" || abbruch
  printf -v "$var" '%s' "$antwort"
}
mehrfachauswahl() {   # VARIABLE(Array) "Frage" schluessel text ON|OFF …
  local var="$1" frage="$2" antwort
  shift 2
  antwort="$(whiptail --backtitle "$HINTERGRUND" --title "$TITEL" --separate-output \
             --checklist "$frage" 22 78 10 "$@" 3>&1 1>&2 2>&3)" || abbruch
  eval "$var=()"
  local zeile
  while IFS= read -r zeile; do
    if [[ -n $zeile ]]; then eval "$var+=(\"\$zeile\")"; fi
  done <<<"$antwort"
}
janein() { whiptail --backtitle "$HINTERGRUND" --title "$TITEL" ${2:+"$2"} --yesno "$1" 22 78; }
hinweis() { whiptail --backtitle "$HINTERGRUND" --title "$TITEL" --msgbox "$1" 20 78; }
bitte_warten() { whiptail --backtitle "$HINTERGRUND" --title "$TITEL" --infobox "$1" 9 66; }

# =====================================================================
#  Proxmox
# =====================================================================
container_ipv4() {   # gibt "a.b.c.d/nn" aus (iproute2 und busybox)
  pct exec "$1" -- ip -4 addr show eth0 2>/dev/null | awk '/inet / {print $2; exit}'
}
container_ula() {
  pct exec "$1" -- ip -6 addr show eth0 2>/dev/null | awk '/inet6 fd/ && !/temporary/ {sub(/\/.*/, "", $2); print $2; exit}'
}
host_gateway() { ip route show default 2>/dev/null | awk '{print $3; exit}'; }
host_ipv4() { ip -4 -o addr show dev "${1:-vmbr0}" 2>/dev/null | awk '{print $4; exit}'; }

adguard_container_suchen() {
  GEFUNDEN=()
  local id status name
  while read -r id status name; do
    [[ $status == running ]] || continue
    if pct exec "$id" -- test -x /opt/AdGuardHome/AdGuardHome 2>/dev/null; then
      GEFUNDEN+=("$id|$name")
    fi
  done < <(pct list 2>/dev/null | awk 'NR>1 {print $1, $2, $NF}')
}

container_ip_festmachen() {   # $1 ID – macht aus DHCP die aktuelle Adresse fest
  local id="$1" net0 adresse gw neu
  net0="$(pct config "$id" | sed -n 's/^net0: //p')"
  [[ $net0 == *ip=dhcp* ]] || return 0
  adresse="$(container_ipv4 "$id")"
  gw="$(pct exec "$id" -- ip route 2>/dev/null | awk '/^default/ {print $3; exit}')"
  if [[ -z $adresse || -z $gw ]]; then
    warn "Konnte die aktuelle IP von Container $id nicht ermitteln – bitte im Router fest zuweisen."
    return 0
  fi
  if janein "Der AdGuard-Container $id bekommt seine IP per DHCP ($adresse).\n\nEin DNS-Server braucht aber eine FESTE Adresse – ändert sie sich, hat das ganze Haus kein Internet.\n\nSoll ich die jetzige Adresse $adresse fest einstellen? (Gateway $gw)"; then
    neu="${net0/ip=dhcp/ip=$adresse,gw=$gw}"
    pct set "$id" -net0 "$neu"
    FEST_GEMACHT="$adresse"
  fi
}

proxmox_startreihenfolge() {
  pct set "$1" --onboot 1 --startup order=1,up=15
}

template_besorgen() {
  local liste
  pveam update >/dev/null 2>&1 || true
  liste="$(pveam available --section system 2>/dev/null | awk '{print $2}')"
  TEMPLATE="$(grep -E '^debian-13-standard_.*_amd64\.tar\.(zst|xz|gz)$' <<<"$liste" | sort -V | tail -n1 || true)"
  if [[ -z $TEMPLATE ]]; then
    TEMPLATE="$(grep -E '^debian-12-standard_.*_amd64\.tar\.(zst|xz|gz)$' <<<"$liste" | sort -V | tail -n1 || true)"
  fi
  [[ -n $TEMPLATE ]] || fehler "Kein Debian-Template gefunden ('pveam available --section system')."
  if ! pveam list local 2>/dev/null | grep -qF "$TEMPLATE"; then
    info "Lade $TEMPLATE herunter …"
    pveam download local "$TEMPLATE" >/dev/null
  fi
}

neuen_container_anlegen() {   # nutzt NEU_IP (CIDR), NEU_GW, NEU_SPEICHER
  local id
  id="$(pvesh get /cluster/nextid)"
  info "Lege Container $id (adguard) an …"
  template_besorgen
  pct create "$id" "local:vztmpl/$TEMPLATE" \
    --hostname adguard --ostype debian --unprivileged 1 --features nesting=1 \
    --cores 1 --memory 512 --swap 512 --rootfs "$NEU_SPEICHER:2" \
    --net0 "name=eth0,bridge=vmbr0,ip=$NEU_IP,gw=$NEU_GW,ip6=auto" \
    --onboot 1 --startup order=1,up=15 --timezone host --cmode shell \
    --description "AdGuard Home – eingerichtet mit $ANLEITUNG" >/dev/null
  pct start "$id"
  info "Warte auf Internet im Container …"
  local i
  for i in $(seq 1 60); do
    if pct exec "$id" -- getent hosts github.com >/dev/null 2>&1; then break; fi
    [[ $i -lt 60 ]] || fehler "Der neue Container hat kein Internet – IP ($NEU_IP) und Gateway ($NEU_GW) prüfen."
    sleep 2
  done
  info "Installiere AdGuard Home (offizielles Installationsskript) …"
  pct exec "$id" -- bash -c 'apt-get update -qq && apt-get install -y -qq curl ca-certificates >/dev/null \
    && curl -s -S -L https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh | sh -s -- -v' \
    || fehler "Installation von AdGuard Home fehlgeschlagen (Meldungen siehe oben)."
  CT_ID="$id"
  ok "AdGuard Home in Container $id installiert"
}

# =====================================================================
#  Ablauf
# =====================================================================
vorpruefungen() {
  [[ $EUID -eq 0 ]] || fehler "Bitte als root ausführen."
  if ! command -v pct >/dev/null 2>&1 || [[ ! -d /etc/pve ]]; then
    fehler "Das ist kein Proxmox-Host. Bitte in der Shell des Proxmox-Hosts ausführen (Knoten → Shell)."
  fi
  if [[ ! -t 0 || ! -t 1 ]]; then
    fehler "Kein Terminal. Bitte genau so starten:  bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/developer2013/bjoerni/main/adguard-home/einrichten.sh)\""
  fi
  local paket
  for paket in whiptail jq curl; do
    if ! command -v "$paket" >/dev/null 2>&1; then
      info "Installiere $paket …"
      apt-get install -y -qq "$paket" >/dev/null
    fi
  done
}

container_waehlen() {
  local eintraege=() zeile wahl ip
  bitte_warten "Suche AdGuard Home in deinen Containern …"
  adguard_container_suchen
  for zeile in "${GEFUNDEN[@]+"${GEFUNDEN[@]}"}"; do
    ip="$(container_ipv4 "${zeile%%|*}")"
    eintraege+=("${zeile%%|*}" "${zeile#*|}  (${ip%/*})")
  done
  eintraege+=(neu "Neuen AdGuard-Container anlegen")
  if (( ${#GEFUNDEN[@]} )); then
    auswahl wahl "Diesen AdGuard-Container habe ich gefunden. Welchen soll ich einrichten?" "${GEFUNDEN[0]%%|*}" "${eintraege[@]}"
  else
    auswahl wahl "Ich habe keinen laufenden Container mit AdGuard Home gefunden.\n(Ein ausgeschalteter Container wird nicht erkannt – dann erst starten.)" "neu" "${eintraege[@]}"
  fi

  if [[ $wahl == neu ]]; then
    local netz gw vorschlag
    netz="$(host_ipv4)"; gw="$(host_gateway)"
    vorschlag="${netz%.*}.53/${netz#*/}"
    while true; do
      eingabe NEU_IP "Feste IP-Adresse für AdGuard MIT Netzmaske:\n\n(Vorschlag: Endung .53 – wie der DNS-Port. Die Adresse darf noch nicht vergeben sein!)" "$vorschlag"
      if ist_cidr "$NEU_IP"; then break; fi
      hinweis "Das ist keine gültige Adresse. Beispiel: 192.168.178.53/24"
    done
    while true; do
      eingabe NEU_GW "Gateway (der Router):" "$gw"
      if ist_ipv4 "$NEU_GW"; then break; fi
      hinweis "Das ist keine gültige IP-Adresse."
    done
    NEU_SPEICHER="$(pvesm status -content rootdir 2>/dev/null | awk 'NR>1 && $3=="active" {print $1}' | grep -xE 'local-lvm|local-zfs' | head -n1 || true)"
    NEU_SPEICHER="${NEU_SPEICHER:-local-lvm}"
    janein "Neuen Container anlegen?\n\n IP:        $NEU_IP\n Gateway:   $NEU_GW\n Speicher:  $NEU_SPEICHER\n Größe:     1 Kern, 512 MB RAM, 2 GB" || abbruch
    clear
    neuen_container_anlegen
  else
    CT_ID="$wahl"
  fi
  AG_IP="$(container_ipv4 "$CT_ID")"
  AG_IP="${AG_IP%/*}"
  [[ -n $AG_IP ]] || fehler "Konnte die IP-Adresse von Container $CT_ID nicht ermitteln."
}

zugang_klaeren() {
  local passwort2
  if ag_setup_offen; then
    hinweis "AdGuard Home ist noch nicht eingerichtet – ich erledige den Einrichtungsassistenten jetzt für dich.\n\nDu legst gleich den Benutzer und das Passwort für die AdGuard-Weboberfläche fest.\nDanach ist sie unter http://$AG_IP erreichbar."
    eingabe AG_BENUTZER "Benutzername für die AdGuard-Weboberfläche:" "admin"
    while true; do
      passwort AG_PASSWORT "Passwort (8 bis 72 Zeichen):"
      if ! passwort_pruefen "$AG_PASSWORT"; then hinweis "Das Passwort muss 8 bis 72 Zeichen lang sein."; continue; fi
      passwort passwort2 "Passwort zur Sicherheit noch einmal:"
      if [[ $AG_PASSWORT == "$passwort2" ]]; then break; fi
      hinweis "Die Passwörter stimmen nicht überein."
    done
    bitte_warten "Richte AdGuard Home ein …"
    export AG_BENUTZER AG_PASSWORT
    ag_ersteinrichtung "$AG_BENUTZER" "$AG_PASSWORT" \
      || fehler "Einrichtung fehlgeschlagen: $AG_ANTWORT  (Port 80 oder 53 belegt? Siehe Kapitel 6 der Anleitung.)"
    export -n AG_PASSWORT   # ab hier nicht mehr an Kindprozesse weitergeben
  else
    if ! ag_web_antwortet; then
      eingabe AG_WEB_PORT "AdGuard antwortet nicht auf Port $AG_WEB_PORT.\n\nAuf welchem Port läuft deine AdGuard-Weboberfläche?" "$AG_WEB_PORT"
      ag_web_antwortet || fehler "Unter http://$AG_IP:$AG_WEB_PORT antwortet kein AdGuard Home."
    fi
    local versuch
    for versuch in 1 2 3; do
      eingabe AG_BENUTZER "Benutzername deiner AdGuard-Weboberfläche (http://$AG_IP:$AG_WEB_PORT):" "${AG_BENUTZER:-admin}"
      passwort AG_PASSWORT "Passwort für '$AG_BENUTZER':"
      ag_zugang_setzen "$AG_BENUTZER" "$AG_PASSWORT"
      if ag_anmelden_pruefen; then return 0; fi
      hinweis "Anmeldung fehlgeschlagen (HTTP $AG_HTTP).\n\nAchtung: Nach 5 Fehlversuchen sperrt AdGuard die Anmeldung für 15 Minuten.\nPasswort vergessen? Kapitel 5 der Anleitung."
    done
    abbruch
  fi
  ag_zugang_setzen "$AG_BENUTZER" "$AG_PASSWORT"
  ag_anmelden_pruefen || fehler "Anmeldung nach der Einrichtung fehlgeschlagen (HTTP $AG_HTTP)."
}

einstellungen_abfragen() {
  local gw scan_ip drucker_ip nas_ip proxmox_ip eintraege=()
  gw="$(host_gateway)"
  while true; do
    eingabe ROUTER "IP-Adresse deines Routers (z. B. der FRITZ!Box):\n\nÜber ihn zeigt AdGuard Gerätenamen statt IP-Adressen an." "${ROUTER:-$gw}"
    if ist_ipv4 "$ROUTER"; then break; fi
    hinweis "Das ist keine gültige IP-Adresse."
  done
  FRITZBOX="nein"
  if curl -s -m 3 "http://$ROUTER/" 2>/dev/null | grep -qi 'fritz'; then FRITZBOX="ja"; fi

  auswahl FILTERSTUFE "Wie streng soll gefiltert werden?\n\n(Der „AdGuard DNS filter“ ist immer aktiv.)" "pro" \
    pro    "Empfohlen: HaGeZi Pro – viel weg, selten etwas kaputt" \
    normal "Familie: HaGeZi Normal – macht praktisch nie etwas kaputt" \
    keine  "Nur den eingebauten AdGuard DNS filter"
  THREAT="nein"
  if janein "Zusätzlich vor Phishing, Schadsoftware und Betrugsseiten schützen?\n\n(HaGeZi Threat Intelligence – macht praktisch nie Probleme.)"; then THREAT="ja"; fi

  # Eigene Namen – was wir kennen, wird vorgeschlagen
  proxmox_ip="$(host_ipv4)"; proxmox_ip="${proxmox_ip%/*}"
  eintraege+=("adguard.lan=$AG_IP" "AdGuard selbst → http://adguard.lan" ON)
  if [[ -n $proxmox_ip ]]; then eintraege+=("proxmox.lan=$proxmox_ip" "Proxmox → https://proxmox.lan:8006" ON); fi
  local scanner_id
  scanner_id="$(pct list 2>/dev/null | awk 'NR>1 && $NF=="scanner" && $2=="running" {print $1; exit}')"
  if [[ -n $scanner_id ]]; then
    scan_ip="$(container_ipv4 "$scanner_id")"; scan_ip="${scan_ip%/*}"
    if [[ -n $scan_ip ]]; then eintraege+=("scanner.lan=$scan_ip" "scan2nas → http://scanner.lan:8080" ON); fi
  fi
  if [[ -f /root/.scan2nas/proxmox.conf ]]; then
    drucker_ip="$(sed -n "s/^SCANNER_IP=//p" /root/.scan2nas/proxmox.conf | tr -d "'\"")"
    nas_ip="$(sed -n "s/^NAS_SERVER=//p" /root/.scan2nas/proxmox.conf | tr -d "'\"")"
    if ist_ipv4 "${drucker_ip:-x}"; then eintraege+=("drucker.lan=$drucker_ip" "Canon TR8550 → http://drucker.lan" ON); fi
    if ist_ipv4 "${nas_ip:-x}"; then eintraege+=("nas.lan=$nas_ip" "NAS → http://nas.lan" ON); fi
  fi
  mehrfachauswahl NAMEN "Eigene Namen statt IP-Adressen (DNS-Umschreibungen).\nLeertaste = an/aus, Enter = weiter:" "${eintraege[@]}"
}

zusammenfassung() {
  local namen="" eintrag
  for eintrag in "${NAMEN[@]+"${NAMEN[@]}"}"; do namen+=$'\n'"               ${eintrag%%=*} → ${eintrag#*=}"; done
  janein "Bitte prüfen:

 AdGuard:      Container $CT_ID, http://$AG_IP${FEST_GEMACHT:+  (IP wird fest)}
 Upstream-DNS: Quad9 + DNS4EU, verschlüsselt (ersetzt die bisherigen)
 Router:       $ROUTER $( [[ $FRITZBOX == ja ]] && echo '(FRITZ!Box erkannt)')
 Filter:       AdGuard DNS filter$( case $FILTERSTUFE in pro) echo ' + HaGeZi Pro';; normal) echo ' + HaGeZi Normal';; esac )$( [[ $THREAT == ja ]] && echo ' + Threat Intelligence')
 Namen:${namen:- keine}
 Proxmox:      startet AdGuard als Erstes

Jetzt übernehmen?" || abbruch
}

main() {
  vorpruefungen
  hinweis "Willkommen!

Dieser Assistent richtet AdGuard Home auf deinem Proxmox komplett ein – genau so, wie es die Anleitung beschreibt:
 • verschlüsselte DNS-Server, DNSSEC, Gerätenamen
 • Sperrlisten gegen Werbung, Tracker und Betrug
 • eigene Namen wie scanner.lan
 • feste IP und Startreihenfolge

Hast du AdGuard schon (z. B. per Community Script), wird es gefunden und nur eingestellt."
  container_waehlen
  FEST_GEMACHT=""
  container_ip_festmachen "$CT_ID"
  zugang_klaeren
  einstellungen_abfragen
  zusammenfassung

  clear
  printf '\033[1;36m%s\033[0m\n\n' "  AdGuard Home · Container $CT_ID · http://$AG_IP"
  if [[ -n $FEST_GEMACHT ]]; then ok "Feste IP eingestellt: $FEST_GEMACHT"; fi
  info "Teste die verschlüsselten DNS-Server …"
  if ! ag_upstreams_testen "$ROUTER" "$FRITZBOX" || [[ -n $UPSTREAM_FEHLER ]]; then
    warn "Nicht alle DNS-Server antworten:"; printf '    %s\n' "$UPSTREAM_FEHLER" >&2
    janein "Nicht alle DNS-Server antworten:\n\n$UPSTREAM_FEHLER\n\nTrotzdem übernehmen?" --defaultno || abbruch
  else
    ok "Quad9 und DNS4EU antworten"
  fi
  info "Übernehme die Einstellungen …"
  local zeile ergebnis=0
  while IFS= read -r zeile; do
    case $zeile in
      OK\ *)      ok "${zeile#OK }" ;;
      HINWEIS\ *) warn "${zeile#HINWEIS }" ;;
      FEHLER\ *)  warn "${zeile#FEHLER }"; ergebnis=1 ;;
    esac
  done < <(ag_einstellungen_anwenden "$ROUTER" "$FRITZBOX" "$FILTERSTUFE" "$THREAT" "${NAMEN[@]+"${NAMEN[@]}"}" || echo "FEHLER Abbruch")
  (( ergebnis == 0 )) || fehler "Nicht alles konnte übernommen werden (siehe oben). Du kannst das Skript einfach noch einmal starten."
  proxmox_startreihenfolge "$CT_ID"
  ok "Proxmox: AdGuard startet nach einem Neustart als Erstes"
  if ag_blockiert_werbung; then ok "Test: doubleclick.net wird blockiert"; else warn "Test: doubleclick.net wird (noch) nicht blockiert – Filter laden evtl. noch."; fi

  local ula
  ula="$(container_ula "$CT_ID" || true)"
  echo
  ok "AdGuard Home ist eingerichtet!  Weboberfläche: http://$AG_IP"
  echo
  printf '\033[1m%s\033[0m\n' "  Letzter Schritt – im Router umstellen (Anleitung Kapitel 3):"
  if [[ $FRITZBOX == ja ]]; then
    echo "   FRITZ!Box → Heimnetz → Netzwerk → Netzwerkeinstellungen"
    echo "     IPv4-Einstellungen → Lokaler DNS-Server:   $AG_IP"
    if [[ -n $ula ]]; then
      echo "     IPv6-Einstellungen → ☑ DNSv6-Server auch über Router Advertisement bekanntgeben"
      echo "                          Lokaler DNSv6-Server: $ula"
    else
      echo "     IPv6: Erst „Unique Local Addresses (ULA) immer zuweisen“ aktivieren, Container"
      echo "           neu starten und dieses Skript noch einmal ausführen – dann steht hier die Adresse."
    fi
  else
    echo "   In den DHCP-Einstellungen deines Routers als DNS-Server eintragen:  $AG_IP"
  fi
  echo
  echo "   Danach auf den Geräten WLAN kurz aus- und einschalten."
  echo "   Anleitung: $ANLEITUNG/03-fritzbox-und-router.md"
}

# Mit ADGUARD_NUR_LADEN=1 werden nur die Funktionen geladen (für die Tests).
if [[ ${ADGUARD_NUR_LADEN:-} != 1 ]]; then
  main "$@"
fi
