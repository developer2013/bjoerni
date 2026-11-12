#!/usr/bin/env bash
# =====================================================================
#  scan2nas-kurzbefehl – Scannen per iPhone-Kurzbefehl (über SSH)
#
#  Wird als /usr/local/bin/scan2nas-kurzbefehl installiert und hat zwei Aufgaben:
#
#  1. Einen SSH-Schlüssel vom iPhone eintragen – so, dass er NUR scannen darf:
#        scan2nas-kurzbefehl schluessel 'ssh-ed25519 AAAA… Kurzbefehle'
#
#  2. Als "erzwungener Befehl" dieses Schlüssels laufen: Der Kurzbefehl
#     schickt einen Text wie "einzug" und dieses Skript startet den passenden
#     Scan. Erlaubt sind nur die Befehle aus der Liste unten – alles andere
#     wird abgelehnt. Der Text wird nie an eine Shell weitergegeben.
#
#  Anleitung: docs/05-iphone-kurzbefehl.md
# =====================================================================
set -uo pipefail

SCAN2NAS="${SCAN2NAS_BEFEHL:-/usr/local/bin/scan2nas}"
AUTH_DATEI="${SCAN2NAS_AUTH_DATEI:-/root/.ssh/authorized_keys}"
DIESES_SKRIPT="/usr/local/bin/scan2nas-kurzbefehl"
ERLAUBT="glas, glas grau, einzug, einzug farbe, foto, status"

hilfe() {
  cat <<EOF
scan2nas-kurzbefehl – Scannen per iPhone-Kurzbefehl

Einrichtung (einmalig, als root im Container):
  scan2nas-kurzbefehl schluessel 'ssh-ed25519 AAAA… Kurzbefehle'

Befehle, die der Kurzbefehl schicken darf:
  glas           eine Seite vom Vorlagenglas, Farbe
  glas grau      eine Seite vom Vorlagenglas, Graustufen
  einzug         alle Seiten aus dem Einzug, Graustufen (Dokumente)
  einzug farbe   alle Seiten aus dem Einzug, Farbe
  foto           Vorlagenglas, Farbe, 600 dpi, ohne Texterkennung
  status         ist der Scanner bereit? liegt Papier im Einzug?

Zum Ausprobieren direkt im Container:  scan2nas-kurzbefehl einzug
EOF
}

schluessel_eintragen() {
  local schluessel="$*" kern
  if [[ ! $schluessel =~ ^(ssh-ed25519|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|ssh-rsa)\ [A-Za-z0-9+/]+=*(\ .*)?$ ]]; then
    echo "✘ Das sieht nicht wie ein öffentlicher SSH-Schlüssel aus."
    echo "  Erwartet wird z. B.:  ssh-ed25519 AAAAC3Nza… (in einfachen Anführungszeichen)"
    return 1
  fi
  kern="$(printf '%s' "$schluessel" | awk '{print $2}')"
  mkdir -p "$(dirname "$AUTH_DATEI")"
  chmod 700 "$(dirname "$AUTH_DATEI")"
  touch "$AUTH_DATEI"
  chmod 600 "$AUTH_DATEI"
  if grep -qF "$kern" "$AUTH_DATEI"; then
    echo "✔ Dieser Schlüssel ist schon eingetragen."
    return 0
  fi
  # restrict = keine Shell, keine Weiterleitungen; command = nur dieses Skript
  printf 'restrict,command="%s" %s\n' "$DIESES_SKRIPT" "$schluessel" >> "$AUTH_DATEI"
  echo "✔ Schlüssel eingetragen. Er darf nur scannen ($ERLAUBT) – sonst nichts."
}

# Führt scan2nas aus und fasst das Ergebnis in zwei kurze Zeilen fürs iPhone zusammen.
scannen() {
  local ausgabe code seiten ziel pfad fehlertext
  ausgabe="$("$SCAN2NAS" scannen "$@" 2>&1)"
  code=$?
  if (( code == 0 )); then
    seiten="$(grep -oE '[0-9]+ Seite\(n\) gescannt' <<<"$ausgabe" | tail -n1)"
    ziel="$(grep -oE '(Gespeichert auf dem NAS|In der Warteschlange): .*' <<<"$ausgabe" | tail -n1)"
    echo "✅ ${seiten:-Scan fertig}"
    case $ziel in
      "Gespeichert auf dem NAS: "*) pfad="${ziel#*: }"; echo "📄 ${pfad#/mnt/nas/}" ;;
      "In der Warteschlange: "*)    echo "⏳ NAS nicht erreichbar – wird nachgeliefert" ;;
    esac
  else
    fehlertext="$(grep -E '^(FEHLER|WARNUNG): ' <<<"$ausgabe" | tail -n1 | sed -E 's/^(FEHLER|WARNUNG): //')"
    echo "❌ Scan fehlgeschlagen"
    echo "${fehlertext:-Unbekannter Fehler (Details: journalctl im Container)}"
  fi
  return "$code"
}

# --- Einrichtung und Hilfe ------------------------------------------------
case "${1:-}" in
  schluessel) shift; schluessel_eintragen "$@"; exit $? ;;
  hilfe|-h|--help) hilfe; exit 0 ;;
esac

# --- Aufruf durch den Kurzbefehl ------------------------------------------
# Über SSH steht der Text des Kurzbefehls in SSH_ORIGINAL_COMMAND,
# beim Ausprobieren im Container in den Argumenten.
roh="${SSH_ORIGINAL_COMMAND:-$*}"
read -r -a woerter <<<"$(printf '%s' "$roh" | tr '[:upper:]' '[:lower:]')"
befehl="${woerter[*]-}"

case $befehl in
  glas|"")       scannen -q glas -m farbe ;;
  "glas grau")   scannen -q glas -m grau ;;
  einzug)        scannen -q einzug -m grau ;;
  "einzug farbe") scannen -q einzug -m farbe ;;
  foto)          scannen -q glas -m farbe -d 600 --ohne-ocr ;;
  status)        "$SCAN2NAS" status 2>&1 ;;
  *)
    echo "❌ Unbekannter Befehl „${roh}“"
    echo "Erlaubt: $ERLAUBT"
    exit 2
    ;;
esac
