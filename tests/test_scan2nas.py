"""Tests für scan2nas – laufen ohne Scanner und ohne NAS.

Aufruf im Projektordner:
    python3 -m unittest discover -s tests -v
"""
import datetime as dt
import logging
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "programm"))

import scan2nas as s  # noqa: E402

logging.disable(logging.CRITICAL)  # erwartete Warnungen nicht in die Testausgabe schreiben

# Antwort eines Canon TR8550 auf GET /eSCL/ScannerStatus (vereinfacht)
STATUS_BELEGT = """<?xml version="1.0" encoding="UTF-8"?>
<scan:ScannerStatus xmlns:scan="http://schemas.hp.com/imaging/escl/2011/05/03"
                    xmlns:pwg="http://www.pwg.org/schemas/2010/12/sm">
  <pwg:Version>2.63</pwg:Version>
  <pwg:State>Idle</pwg:State>
  <scan:Jobs><scan:JobInfo><pwg:JobState>Completed</pwg:JobState></scan:JobInfo></scan:Jobs>
  <scan:AdfState>ScannerAdfLoaded</scan:AdfState>
</scan:ScannerStatus>"""

STATUS_OHNE_EINZUG = """<?xml version="1.0"?>
<scan:ScannerStatus xmlns:scan="http://schemas.hp.com/imaging/escl/2011/05/03"
                    xmlns:pwg="http://www.pwg.org/schemas/2010/12/sm">
  <pwg:State>Processing</pwg:State>
</scan:ScannerStatus>"""


class KonfigTest(unittest.TestCase):
    def test_anfuehrungszeichen_kommentare_export(self):
        werte = s.lies_konfig_text(
            '# Kommentar\n'
            '\n'
            'SCANNER_IP="192.168.1.50"   # Drucker im Flur\n'
            "OCR_SPRACHE='deu+eng'\n"
            'export AUFLOESUNG=300 # Standard\n'
            'NAS_ORDNER=/mnt/nas/Scans\n'
        )
        self.assertEqual(werte, {
            "SCANNER_IP": "192.168.1.50",
            "OCR_SPRACHE": "deu+eng",
            "AUFLOESUNG": "300",
            "NAS_ORDNER": "/mnt/nas/Scans",
        })

    def test_fehlendes_gleichheitszeichen(self):
        with self.assertRaises(s.KonfigFehler):
            s.lies_konfig_text("SCANNER_IP 192.168.1.50")

    def test_typen(self):
        k = s.Konfiguration({"AUFLOESUNG": "600", "AUTOMATIK_AKTIV": "Ja"})
        self.assertEqual(k.zahl("AUFLOESUNG"), 600)
        self.assertTrue(k.janein("AUTOMATIK_AKTIV"))
        self.assertTrue(k.janein("OCR_AKTIV"), "Standardwert ist 'ja'")
        with self.assertRaises(s.KonfigFehler):
            s.Konfiguration({"AUFLOESUNG": "viel"}).zahl("AUFLOESUNG")
        with self.assertRaises(s.KonfigFehler):
            s.Konfiguration({"OCR_AKTIV": "vielleicht"}).janein("OCR_AKTIV")

    def test_beispielkonfiguration_ist_vollstaendig(self):
        """Jede Einstellung im Code muss in der Beispieldatei erklärt sein – und umgekehrt."""
        beispiel = Path(__file__).resolve().parents[1] / "konfiguration" / "scan2nas.conf.beispiel"
        werte = s.lies_konfig_text(beispiel.read_text(encoding="utf-8"))
        self.assertEqual(set(werte), set(s.STANDARDWERTE))
        for schluessel, wert in werte.items():
            if schluessel != "SCANNER_IP":  # Beispiel-IP weicht absichtlich ab
                self.assertEqual(wert, s.STANDARDWERTE[schluessel], f"{schluessel} weicht vom Standard ab")

    def test_escl_url(self):
        self.assertEqual(s.Konfiguration({"SCANNER_IP": "10.0.0.5"}).escl_url(), "http://10.0.0.5/eSCL")
        with self.assertRaises(s.KonfigFehler):
            s.Konfiguration({}).escl_url()


class DateinameTest(unittest.TestCase):
    ZEIT = dt.datetime(2026, 11, 12, 20, 43, 5)

    def test_standardmuster(self):
        rel = s.ziel_relpfad(s.STANDARDWERTE["DATEINAME_MUSTER"], self.ZEIT, "pdf")
        self.assertEqual(rel, Path("2026/2026-11/Scan_2026-11-12_20-43-05.pdf"))

    def test_kein_ausbruch_aus_dem_nas_ordner(self):
        rel = s.ziel_relpfad("/../../etc/%Y", self.ZEIT, ".pdf")
        self.assertEqual(rel, Path("etc/2026.pdf"))

    def test_leeres_muster(self):
        with self.assertRaises(s.KonfigFehler):
            s.ziel_relpfad("/", self.ZEIT, "pdf")

    def test_freier_dateiname(self):
        with tempfile.TemporaryDirectory() as tmp:
            ziel = Path(tmp) / "Scan.pdf"
            self.assertEqual(s.freier_dateiname(ziel), ziel)
            ziel.write_text("x")
            self.assertEqual(s.freier_dateiname(ziel).name, "Scan_2.pdf")


class StatusTest(unittest.TestCase):
    def test_einzug_belegt(self):
        status = s.status_parsen(STATUS_BELEGT)
        self.assertEqual(status.zustand, "Idle")
        self.assertTrue(status.bereit)
        self.assertTrue(status.einzug_belegt)

    def test_ohne_einzug_status(self):
        status = s.status_parsen(STATUS_OHNE_EINZUG)
        self.assertEqual(status.zustand, "Processing")
        self.assertIsNone(status.einzug)
        self.assertFalse(status.bereit)

    def test_doctype_wird_abgelehnt(self):
        boese = '<?xml version="1.0"?><!DOCTYPE x [<!ENTITY a "aaaa">]><x>&a;</x>'
        with self.assertRaises(ET.ParseError):
            s.status_parsen(boese)


class AutomatikTest(unittest.TestCase):
    BELEGT = s.ScannerStatus("Idle", "ScannerAdfLoaded")
    BELEGT_BESCHAEFTIGT = s.ScannerStatus("Processing", "ScannerAdfLoaded")
    LEER = s.ScannerStatus("Idle", "ScannerAdfEmpty")

    def test_scannt_erst_nach_wartezeit_und_nur_einmal(self):
        z = s.AutomatikZustand()
        self.assertFalse(s.soll_automatisch_scannen(z, self.BELEGT, 0, 15))
        self.assertFalse(s.soll_automatisch_scannen(z, self.BELEGT, 10, 15))
        self.assertTrue(s.soll_automatisch_scannen(z, self.BELEGT, 15, 15))
        z.erledigt = True  # so macht es automatik() nach dem Start des Scans
        self.assertFalse(s.soll_automatisch_scannen(z, self.BELEGT, 100, 15))

    def test_neuer_stapel_nach_leerem_einzug(self):
        z = s.AutomatikZustand(belegt_seit=0, erledigt=True)
        self.assertFalse(s.soll_automatisch_scannen(z, self.LEER, 20, 15))
        self.assertFalse(z.erledigt)
        self.assertFalse(s.soll_automatisch_scannen(z, self.BELEGT, 30, 15))
        self.assertTrue(s.soll_automatisch_scannen(z, self.BELEGT, 45, 15))

    def test_wartet_wenn_scanner_beschaeftigt(self):
        z = s.AutomatikZustand()
        self.assertFalse(s.soll_automatisch_scannen(z, self.BELEGT_BESCHAEFTIGT, 0, 0))
        self.assertFalse(s.soll_automatisch_scannen(z, self.BELEGT_BESCHAEFTIGT, 60, 0))
        self.assertTrue(s.soll_automatisch_scannen(z, self.BELEGT, 61, 0))


class AblageTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        basis = Path(self._tmp.name)
        self.nas_mount = basis / "nas"          # „Mountpunkt“ – existiert immer
        self.nas_mount.mkdir()
        self.nas = self.nas_mount / "Scans"     # Zielordner – existiert nur, wenn das NAS da ist
        self.ws = basis / "warteschlange"
        self.k = s.Konfiguration({"NAS_ORDNER": str(self.nas), "WARTESCHLANGE": str(self.ws)})
        self.datei = basis / "scan.pdf"
        self.datei.write_bytes(b"%PDF-1.4 test")

    def tearDown(self):
        self._tmp.cleanup()

    def test_nas_da(self):
        self.nas.mkdir()
        ziel = s.ablegen(self.datei, Path("2026/Scan.pdf"), self.k, verschieben=True)
        self.assertEqual(ziel, self.nas / "2026/Scan.pdf")
        self.assertTrue(ziel.exists())
        self.assertFalse(self.datei.exists())
        self.assertEqual([p.name for p in self.nas.rglob("*") if p.name.startswith(".")], [])

    def test_nas_weg_dann_nachliefern(self):
        ziel = s.ablegen(self.datei, Path("2026/Scan.pdf"), self.k, verschieben=False)
        self.assertEqual(ziel, self.ws / "2026/Scan.pdf")
        self.assertTrue(self.datei.exists())
        self.assertFalse(self.nas.exists(), "scan2nas darf den NAS-Ordner nie selbst anlegen")
        self.assertEqual(s.warteschlange_abarbeiten(self.k), 0)

        self.nas.mkdir()  # NAS ist wieder da
        self.assertEqual(s.warteschlange_abarbeiten(self.k), 1)
        self.assertTrue((self.nas / "2026/Scan.pdf").exists())
        self.assertEqual(s.wartende_dateien(self.ws), [])
        self.assertEqual(list(self.ws.iterdir()), [], "leere Unterordner werden aufgeräumt")

    def test_uebernehmen_behaelt_endung(self):
        self.nas.mkdir()
        bild = self.datei.with_suffix(".jpg")
        self.datei.rename(bild)
        self.assertEqual(s.uebernehmen(self.k, [str(bild)], verschieben=False), 0)
        self.assertEqual([p.suffix for p in self.nas.rglob("*") if p.is_file()], [".jpg"])
        self.assertEqual(s.uebernehmen(self.k, [str(bild.with_name("fehlt.pdf"))], False), 1)


# Simulierter Scanner: listet ein Gerät auf bzw. „scannt“ 3 Seiten aus dem Einzug
FAKE_SCANIMAGE = r'''#!/usr/bin/env python3
import sys
args = sys.argv[1:]
if "-f" in args:
    print("airscan:e0:Canon TR8550")
    sys.exit(0)
muster = [a.split("=", 1)[1] for a in args if a.startswith("--batch=")][0]
anzahl = 1 if "--batch-count=1" in args else 3
for nr in range(1, anzahl + 1):
    with open(muster % nr, "wb") as f:
        f.write(b"\xff\xd8 bild")
sys.stderr.write("scanimage: sane_start: Document feeder out of documents\n")
sys.exit(0)
'''

# Simuliertes img2pdf: schreibt die Bildnamen in die „PDF“-Datei
FAKE_IMG2PDF = r'''#!/usr/bin/env python3
import sys
args = sys.argv[1:]
ausgabe = args[args.index("-o") + 1]
bilder = [a for a in args[args.index("-o") + 2:]]
with open(ausgabe, "w") as f:
    f.write("%PDF " + " ".join(b.rsplit("/", 1)[-1] for b in bilder))
'''


class ScanAblaufTest(unittest.TestCase):
    """Kompletter Ablauf von `scannen` mit simulierten Programmen."""

    def setUp(self):
        import os
        self._tmp = tempfile.TemporaryDirectory()
        basis = Path(self._tmp.name)
        werkzeuge = basis / "bin"
        werkzeuge.mkdir()
        for name, inhalt in (("scanimage", FAKE_SCANIMAGE), ("img2pdf", FAKE_IMG2PDF)):
            pfad = werkzeuge / name
            pfad.write_text(inhalt)
            pfad.chmod(0o755)
        self._alter_path = os.environ["PATH"]
        os.environ["PATH"] = f"{werkzeuge}{os.pathsep}{self._alter_path}"
        self.nas = basis / "nas"
        self.nas.mkdir()
        self.k = s.Konfiguration({
            "NAS_ORDNER": str(self.nas),
            "WARTESCHLANGE": str(basis / "ws"),
            "ARBEITSORDNER": str(basis / "arbeit"),
            "DATEINAME_MUSTER": "Scan",
        })

    def tearDown(self):
        import os
        os.environ["PATH"] = self._alter_path
        self._tmp.cleanup()

    def test_einzug_drei_seiten(self):
        ziel = s.scannen(self.k, "einzug", "grau", 300, ocr=False)
        self.assertEqual(ziel, self.nas / "Scan.pdf")
        self.assertEqual(ziel.read_text(), "%PDF seite-001.jpg seite-002.jpg seite-003.jpg")

    def test_glas_eine_seite_und_kein_ueberschreiben(self):
        s.scannen(self.k, "glas", "farbe", 300, ocr=False)
        zweiter = s.scannen(self.k, "glas", "farbe", 300, ocr=False)
        self.assertEqual(zweiter.name, "Scan_2.pdf")
        self.assertEqual(zweiter.read_text(), "%PDF seite-001.jpg")

    def test_falsche_quelle(self):
        with self.assertRaises(s.KonfigFehler):
            s.scannen(self.k, "fax", "farbe", 300, ocr=False)


if __name__ == "__main__":
    unittest.main()
