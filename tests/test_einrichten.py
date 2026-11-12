"""Tests für einrichten.sh – die Bash-Hilfsfunktionen, ohne Proxmox und ohne Dialoge.

Aufruf im Projektordner:
    python3 -m unittest discover -s tests -v
"""
import os
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

PROJEKT = Path(__file__).resolve().parents[1]
SKRIPT = PROJEKT / "einrichten.sh"

sys.path.insert(0, str(PROJEKT / "programm"))
import scan2nas  # noqa: E402  (nur für den Konfig-Parser)


def bash(befehle: str, **umgebung: str) -> subprocess.CompletedProcess:
    """Lädt einrichten.sh (ohne main auszuführen) und führt danach `befehle` aus."""
    env = dict(os.environ, SCAN2NAS_NUR_LADEN="1", **umgebung)
    return subprocess.run(["bash", "-c", f'source "{SKRIPT}"; {befehle}'],
                          capture_output=True, text=True, env=env)


class PruefFunktionenTest(unittest.TestCase):
    def ok(self, befehl: str) -> bool:
        return bash(befehl).returncode == 0

    def test_laden_startet_nichts(self):
        erg = bash("echo geladen")
        self.assertEqual(erg.returncode, 0, erg.stderr)
        self.assertEqual(erg.stdout.strip(), "geladen")

    def test_ipv4(self):
        for ip in ("192.168.178.50", "10.0.0.1", "255.255.255.255", "010.001.002.003"):
            self.assertTrue(self.ok(f"ist_ipv4 {ip}"), ip)
        for ip in ("256.1.1.1", "192.168.1", "192.168.1.1.1", "abc", "", "1.2.3.4/24"):
            self.assertFalse(self.ok(f"ist_ipv4 '{ip}'"), ip)

    def test_cidr(self):
        self.assertTrue(self.ok("ist_cidr 192.168.178.60/24"))
        for wert in ("192.168.178.60", "192.168.178.60/33", "192.168.178.60/", "x/24"):
            self.assertFalse(self.ok(f"ist_cidr '{wert}'"), wert)

    def test_hostname_und_unterordner(self):
        self.assertTrue(self.ok("ist_hostname nas.fritz.box"))
        self.assertTrue(self.ok("ist_hostname scanner-2"))
        self.assertFalse(self.ok("ist_hostname 'mein nas'"))
        self.assertFalse(self.ok("ist_hostname -nas"))
        self.assertTrue(self.ok("ist_unterordner Scans/Eingang"))
        for wert in ("", "/Scans", "../etc", "a/../b"):
            self.assertFalse(self.ok(f"ist_unterordner '{wert}'"), wert)

    def test_nas_fehler_werden_erklaert(self):
        faelle = {
            "mount error(13): Permission denied": "Passwort",
            "mount error(2): No such file or directory": "Freigabe gibt es nicht",
            "mount error(112): Host is down": "SMB-Version",
            "": "nicht erreichbar",
        }
        for meldung, erwartet in faelle.items():
            erg = bash(f"nas_fehler_erklaeren '{meldung}'")
            self.assertIn(erwartet, erg.stdout, meldung)


class KonfigSpeichernTest(unittest.TestCase):
    BOESES_PASSWORT = "Ge$heim!'x\"y z\\`date`;rm -rf /"

    def test_rundreise_mit_sonderzeichen(self):
        """Gespeichert und mit `source` gelesen muss exakt dasselbe herauskommen."""
        with tempfile.TemporaryDirectory() as tmp:
            datei = Path(tmp) / "unterordner" / "proxmox.conf"
            erg = bash(f'standardwerte_setzen; konfig_speichern "{datei}"',
                       NAS_PASSWORT=self.BOESES_PASSWORT, SCANNER_IP="192.168.178.50")
            self.assertEqual(erg.returncode, 0, erg.stderr)
            self.assertEqual(stat.S_IMODE(datei.stat().st_mode), 0o600, "nur für root lesbar")

            zurueck = subprocess.run(
                ["bash", "-c", f'source "{datei}"; printf "%s\\n%s" "$NAS_PASSWORT" "$SCANNER_IP"'],
                capture_output=True, text=True, env={"PATH": os.environ["PATH"]})
            self.assertEqual(zurueck.stdout, f"{self.BOESES_PASSWORT}\n192.168.178.50")

    def test_gleiche_einstellungen_wie_proxmox_conf_beispiel(self):
        """einrichten.sh muss genau die Einstellungen kennen, die lxc-erstellen.sh liest."""
        beispiel = scan2nas.lies_konfig_text(
            (PROJEKT / "proxmox" / "proxmox.conf.beispiel").read_text(encoding="utf-8"))
        erg = bash('printf "%s\\n" "${KONFIG_VARIABLEN[@]}"')
        self.assertEqual(set(erg.stdout.split()), set(beispiel))


# Attrappen für alles, was es nur auf einem Proxmox-Host gibt. Bash-Funktionen
# haben Vorrang vor Programmen gleichen Namens – auch in $(…)-Subshells.
ATTRAPPEN = r'''
whiptail() {
  local typ="" a
  for a in "$@"; do
    case $a in --inputbox|--passwordbox|--menu|--yesno|--msgbox|--infobox) typ=$a ;; esac
  done
  printf '%s %s\n' "$typ" "$*" >> "$PROTOKOLL"
  case $typ in
    --msgbox|--infobox) return 0 ;;
    --yesno) IFS= read -r a <&9; return "$a" ;;
    *) IFS= read -r a <&9; printf '%s' "$a" >&2 ;;   # whiptail antwortet auf stderr
  esac
}
pvesm() {
  printf 'Name Type Status Total Used Available %%\n'
  printf 'local dir active 100000000 1000 90000000 1%%\n'
  printf 'local-lvm lvmthin active 900000000 1000 800000000 1%%\n'
}
ip() {
  case "$*" in
    *"addr show dev"*)       echo "2: vmbr0    inet 192.168.178.5/24 brd 192.168.178.255 scope global vmbr0" ;;
    *"link show type bridge"*) echo "3: vmbr0: <BROADCAST,MULTICAST,UP>" ;;
    *) return 0 ;;
  esac
}
escl_modell() { if [[ $1 == 192.168.178.50 ]]; then echo "Canon TR8500 series"; else return 1; fi; }
# Das NAS kann kein SMB 3.0, aber 3.1.1 – das Skript soll selbst weiterprobieren
mount() {
  echo "mount $*" >> "$PROTOKOLL"
  case "$*" in *vers=3.0*) echo "mount error(112): Host is down" >&2; return 32 ;; esac
}
umount() { :; }
timeout() { shift; "$@"; }
apt-get() { :; }
clear() { :; }
'''


class DialogAblaufTest(unittest.TestCase):
    """Spielt den Weg „Einfach einrichten“ mit simulierten Eingaben komplett durch."""

    ANTWORTEN = [
        "einfach",           # Wie möchtest du einrichten?
        "192.168.178.50",    # gefundener Scanner
        "cifs",              # NAS-Typ
        "192.168.178.10",    # NAS-Adresse
        "scans",             # Freigabe
        "scanner",           # Benutzer
        "Ge$heim! 'x'",      # Passwort
        "Scans",             # Unterordner
        "0",                 # Zusammenfassung: Ja
    ]

    def test_einfacher_weg(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            (tmp / "antworten.txt").write_text("\n".join(self.ANTWORTEN) + "\n")
            erg = bash(ATTRAPPEN + f'''
                GESPEICHERT="{tmp}/gespeichert.conf"
                exec 9< "{tmp}/antworten.txt"
                dialoge
                source "$GESPEICHERT"
                printf "%s|" "$SCANNER_IP" "$NAS_SERVER" "$NAS_FREIGABE" "$NAS_PASSWORT" \
                             "$SMB_VERSION" "$CT_SPEICHER" "$CT_BRIDGE" "$KONSOLE_AUTOLOGIN"
            ''', PROTOKOLL=str(tmp / "protokoll.txt"))
            self.assertEqual(erg.returncode, 0, erg.stderr)
            self.assertEqual(erg.stdout.split("|")[:-1], [
                "192.168.178.50", "192.168.178.10", "scans", "Ge$heim! 'x'",
                "3.1.1", "local-lvm", "vmbr0", "ja",
            ])
            protokoll = (tmp / "protokoll.txt").read_text()
            self.assertIn("Canon TR8500 series", protokoll, "gefundener Scanner wird angezeigt")
            self.assertIn("vers=3.0", protokoll)
            self.assertIn("vers=3.1.1", protokoll, "nach error(112) wird SMB 3.1.1 probiert")
            self.assertNotIn("Ge$heim", protokoll, "Passwort darf nicht im Mount-Befehl stehen")
            self.assertEqual(list(Path("/tmp").glob("scan2nas-zugang.*")), [],
                             "temporäre Zugangsdatei wird gelöscht")

    def test_aktualisieren_fragt_nichts_weiter(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            (tmp / "gespeichert.conf").write_text("CT_NAME=scanner\nSCANNER_IP=192.168.178.50\n")
            (tmp / "antworten.txt").write_text("aktualisieren\n")
            erg = bash(ATTRAPPEN + f'''
                GESPEICHERT="{tmp}/gespeichert.conf"
                exec 9< "{tmp}/antworten.txt"
                dialoge
                echo "SCANNER_IP=$SCANNER_IP"
            ''', PROTOKOLL=str(tmp / "protokoll.txt"))
            self.assertEqual(erg.returncode, 0, erg.stderr)
            self.assertIn("SCANNER_IP=192.168.178.50", erg.stdout)
            dialoge = (tmp / "protokoll.txt").read_text().splitlines()
            self.assertEqual(len(dialoge), 1, "nur die Frage „Aktualisieren?“")
            self.assertIn("schon eingerichtet", dialoge[0])


if __name__ == "__main__":
    unittest.main()
