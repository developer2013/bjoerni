"""Tests für programm/kurzbefehl.sh – den Zugang für den iPhone-Kurzbefehl.

Wichtigster Punkt: Nur die erlaubten Befehle dürfen durchkommen.

Aufruf im Projektordner:
    python3 -m unittest discover -s tests -v
"""
import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

SKRIPT = Path(__file__).resolve().parents[1] / "programm" / "kurzbefehl.sh"

# Simuliertes scan2nas: merkt sich die Argumente und gibt typische Meldungen aus
FAKE_SCAN2NAS = r'''#!/usr/bin/env bash
echo "$*" >> "$PROTOKOLL"
case "$*" in
  *papierlos*) echo "FEHLER: Der Scanner hat keine Seite geliefert (Exit-Code 7). Liegt Papier im Einzug?" >&2; exit 1 ;;
  status*)     echo "Zustand: Idle"; echo "Einzug:  ScannerAdfLoaded" ;;
  *)           echo "INFO: 3 Seite(n) gescannt – erstelle PDF …" >&2
               echo "INFO: Gespeichert auf dem NAS: /mnt/nas/Scans/2026/2026-11/Scan_2026-11-12_21-50-00.pdf" >&2 ;;
esac
'''


class KurzbefehlTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.fake = self.tmp / "scan2nas"
        self.fake.write_text(FAKE_SCAN2NAS)
        self.fake.chmod(0o755)
        self.protokoll = self.tmp / "aufrufe.txt"
        self.auth = self.tmp / "ssh" / "authorized_keys"

    def tearDown(self):
        self._tmp.cleanup()

    def starte(self, *argumente, ssh_befehl=None):
        env = dict(os.environ, SCAN2NAS_BEFEHL=str(self.fake), PROTOKOLL=str(self.protokoll),
                   SCAN2NAS_AUTH_DATEI=str(self.auth))
        env.pop("SSH_ORIGINAL_COMMAND", None)
        if ssh_befehl is not None:
            env["SSH_ORIGINAL_COMMAND"] = ssh_befehl
        return subprocess.run(["bash", str(SKRIPT), *argumente], capture_output=True, text=True, env=env)

    def aufrufe(self):
        return self.protokoll.read_text().splitlines() if self.protokoll.exists() else []

    # --- erlaubte Befehle ------------------------------------------------
    def test_befehle_werden_richtig_uebersetzt(self):
        faelle = {
            "einzug": "scannen -q einzug -m grau",
            "Einzug  Farbe": "scannen -q einzug -m farbe",   # Groß/klein und Leerzeichen egal
            "glas": "scannen -q glas -m farbe",
            "glas grau": "scannen -q glas -m grau",
            "foto": "scannen -q glas -m farbe -d 600 --ohne-ocr",
            "status": "status",
        }
        for text, erwartet in faelle.items():
            self.protokoll.unlink(missing_ok=True)
            erg = self.starte(ssh_befehl=text)
            self.assertEqual(erg.returncode, 0, f"{text}: {erg.stdout}{erg.stderr}")
            self.assertEqual(self.aufrufe(), [erwartet], text)

    def test_kurze_rueckmeldung_fuers_iphone(self):
        erg = self.starte(ssh_befehl="einzug")
        self.assertEqual(erg.stdout.splitlines(), [
            "✅ 3 Seite(n) gescannt",
            "📄 Scans/2026/2026-11/Scan_2026-11-12_21-50-00.pdf",
        ])

    def test_fehler_wird_verstaendlich_gemeldet(self):
        # Trick: Der Fake scheitert, wenn "papierlos" in den Argumenten steht.
        env_fake = self.fake.read_text().replace("*papierlos*", "*einzug*")
        self.fake.write_text(env_fake)
        erg = self.starte(ssh_befehl="einzug")
        self.assertNotEqual(erg.returncode, 0)
        self.assertIn("❌ Scan fehlgeschlagen", erg.stdout)
        self.assertIn("Liegt Papier im Einzug?", erg.stdout)

    def test_leeres_skriptfeld_scannt_nicht(self):
        erg = self.starte(ssh_befehl="")
        self.assertEqual(erg.returncode, 0, erg.stderr)
        self.assertEqual(self.aufrufe(), ["status"], "leer = nur Status, kein Scan")
        self.assertIn("Tipp", erg.stdout)

    def test_aufruf_ohne_ssh_zum_ausprobieren(self):
        erg = self.starte("einzug", "farbe")
        self.assertEqual(erg.returncode, 0, erg.stderr)
        self.assertEqual(self.aufrufe(), ["scannen -q einzug -m farbe"])

    # --- alles andere muss abgelehnt werden ---------------------------------
    def test_fremde_befehle_werden_abgelehnt(self):
        for boese in ("rm -rf /", "einzug; reboot", "einzug && cat /etc/shadow", "$(reboot)",
                      "bash", "scannen -q einzug", "einzug farbe extra", "test"):
            erg = self.starte(ssh_befehl=boese)
            self.assertEqual(erg.returncode, 2, boese)
            self.assertIn("Unbekannter Befehl", erg.stdout)
        self.assertEqual(self.aufrufe(), [], "scan2nas darf nie aufgerufen worden sein")

    # --- Schlüssel eintragen -------------------------------------------------
    def test_schluessel_wird_eingeschraenkt_eingetragen(self):
        schluessel = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBeispielSchluesselNurZumTesten1234 Kurzbefehle auf iPhone"
        erg = self.starte("schluessel", schluessel)
        self.assertEqual(erg.returncode, 0, erg.stdout)
        inhalt = self.auth.read_text()
        self.assertEqual(inhalt, f'restrict,command="/usr/local/bin/scan2nas-kurzbefehl" {schluessel}\n')
        self.assertEqual(stat.S_IMODE(self.auth.stat().st_mode), 0o600)

        erg = self.starte("schluessel", schluessel)
        self.assertIn("schon eingetragen", erg.stdout)
        self.assertEqual(self.auth.read_text().count("ssh-ed25519"), 1, "nicht doppelt eintragen")

    def test_unsinn_wird_nicht_als_schluessel_eingetragen(self):
        for unsinn in ("hallo", "ssh-ed25519", 'ssh-ed25519 AAAA" ; reboot', ""):
            erg = self.starte("schluessel", unsinn)
            self.assertNotEqual(erg.returncode, 0, unsinn)
        self.assertFalse(self.auth.exists())


if __name__ == "__main__":
    unittest.main()
