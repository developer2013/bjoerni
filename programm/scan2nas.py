#!/usr/bin/env python3
"""
scan2nas – holt Scans vom Canon TR8550 (oder jedem anderen eSCL/AirScan-Scanner)
und legt sie als durchsuchbares PDF auf dem NAS ab.

Befehle:
  scan2nas scannen [--quelle glas|einzug] [--modus farbe|grau] [--dpi N] [--ohne-ocr]
  scan2nas uebernehmen DATEI [DATEI ...]   wird von scanservjs nach jedem Scan aufgerufen
  scan2nas automatik                        Hintergrunddienst (Warteschlange + Einzug-Automatik)
  scan2nas warteschlange                    wartende Scans sofort aufs NAS schieben
  scan2nas status                           Scannerstatus per eSCL abfragen
  scan2nas test                             alles prüfen: Programme, Scanner, NAS

Es wird nur die Python-Standardbibliothek benutzt – keine pip-Pakete nötig.
Externe Programme: scanimage (sane-utils + sane-airscan), img2pdf, ocrmypdf (optional).
"""
from __future__ import annotations

import argparse
import datetime as dt
import fcntl
import logging
import os
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import urllib.request
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Dict, List, Optional

VERSION = "1.0.0"
STANDARD_KONFIG = "/etc/scan2nas/scan2nas.conf"

# Maximale Laufzeiten externer Programme (Sekunden)
ZEITLIMIT_GERAETESUCHE = 90
ZEITLIMIT_SCAN = 30 * 60      # ein voller Einzug (20 Blatt) braucht einige Minuten
ZEITLIMIT_OCR = 30 * 60

log = logging.getLogger("scan2nas")

# Alle Einstellungen mit ihren Standardwerten. Die Konfigurationsdatei
# (/etc/scan2nas/scan2nas.conf) überschreibt nur, was dort gesetzt ist.
STANDARDWERTE: Dict[str, str] = {
    # Scanner
    "SCANNER_IP": "",
    "SCANNER_GERAET": "",            # leer = automatisch suchen
    "SCANNER_FILTER": "airscan:",    # Teiltext, an dem das richtige Gerät erkannt wird
    "ESCL_URL": "",                  # leer = http://<SCANNER_IP>/eSCL
    # Scan-Einstellungen
    "AUFLOESUNG": "300",
    "MODUS": "farbe",                # farbe | grau
    "QUELLE": "glas",                # glas | einzug
    "BILDFORMAT": "jpeg",            # jpeg | png | tiff
    # Namen, die das SANE-Backend erwartet (sane-airscan)
    "SANE_QUELLE_GLAS": "Flatbed",
    "SANE_QUELLE_EINZUG": "ADF",
    "SANE_MODUS_FARBE": "Color",
    "SANE_MODUS_GRAU": "Gray",
    # Texterkennung
    "OCR_AKTIV": "ja",
    "OCR_SPRACHE": "deu",
    "OCR_OPTIONEN": "--rotate-pages --deskew --optimize 1",
    # Ablage
    "NAS_ORDNER": "/mnt/nas/Scans",
    "DATEINAME_MUSTER": "%Y/%Y-%m/Scan_%Y-%m-%d_%H-%M-%S",
    "WARTESCHLANGE": "/var/lib/scan2nas/warteschlange",
    "ARBEITSORDNER": "/var/lib/scan2nas/arbeit",
    "WARTESCHLANGE_INTERVALL": "300",
    # Einzug-Automatik
    "AUTOMATIK_AKTIV": "nein",
    "AUTOMATIK_INTERVALL": "5",
    "AUTOMATIK_WARTEZEIT": "15",
    "AUTOMATIK_MODUS": "grau",
    # Weboberfläche (scanservjs)
    "WEB_AUSGABE": "/var/lib/scanservjs/output",
    "WEB_AUFBEWAHRUNG_TAGE": "7",
    # Sonstiges
    "LOGLEVEL": "INFO",
}

BILDENDUNGEN = {"jpeg": "jpg", "png": "png", "tiff": "tif"}


# ---------------------------------------------------------------------------
# Fehlerklassen
# ---------------------------------------------------------------------------
class KonfigFehler(Exception):
    """Die Konfiguration ist fehlerhaft."""


class ScanFehler(Exception):
    """Beim Scannen ist etwas schiefgegangen."""


# ---------------------------------------------------------------------------
# Konfiguration
# ---------------------------------------------------------------------------
def lies_konfig_text(text: str) -> Dict[str, str]:
    """Liest Zeilen im Format SCHLUESSEL="wert" (wie eine Shell-Datei).

    Erlaubt sind Kommentare (#), Leerzeilen, einfache oder doppelte
    Anführungszeichen und ein vorangestelltes 'export'.
    """
    werte: Dict[str, str] = {}
    for nr, roh in enumerate(text.splitlines(), start=1):
        zeile = roh.strip()
        if not zeile or zeile.startswith("#"):
            continue
        if "=" not in zeile:
            raise KonfigFehler(f"Zeile {nr}: Gleichheitszeichen fehlt: {roh!r}")
        schluessel, wert = zeile.split("=", 1)
        schluessel = schluessel.strip()
        if schluessel.startswith("export "):
            schluessel = schluessel[len("export "):].strip()
        if not schluessel.replace("_", "").isalnum():
            raise KonfigFehler(f"Zeile {nr}: ungültiger Name {schluessel!r}")
        wert = wert.strip()
        if wert[:1] in ("'", '"'):
            ende = wert.find(wert[0], 1)
            if ende == -1:
                raise KonfigFehler(f"Zeile {nr}: schließendes Anführungszeichen fehlt")
            wert = wert[1:ende]
        else:
            wert = wert.split("#", 1)[0].strip()
        werte[schluessel] = wert
    return werte


class Konfiguration:
    """Zugriff auf die Einstellungen mit Typprüfung und deutschen Fehlermeldungen."""

    def __init__(self, werte: Dict[str, str], quelle: str = "(Standardwerte)"):
        self.quelle = quelle
        self._werte = dict(STANDARDWERTE)
        for schluessel in werte:
            if schluessel not in STANDARDWERTE:
                log.warning("Unbekannte Einstellung %s in %s wird ignoriert.", schluessel, quelle)
        self._werte.update({k: v for k, v in werte.items() if k in STANDARDWERTE})

    @classmethod
    def laden(cls, pfad: str) -> "Konfiguration":
        datei = Path(pfad)
        if not datei.exists():
            log.warning("Konfiguration %s nicht gefunden – nutze Standardwerte.", datei)
            return cls({})
        return cls(lies_konfig_text(datei.read_text(encoding="utf-8")), str(datei))

    def text(self, schluessel: str) -> str:
        return self._werte[schluessel]

    def zahl(self, schluessel: str) -> int:
        wert = self._werte[schluessel]
        try:
            return int(wert)
        except ValueError:
            raise KonfigFehler(f"{schluessel} muss eine ganze Zahl sein, ist aber {wert!r}") from None

    def janein(self, schluessel: str) -> bool:
        wert = self._werte[schluessel].strip().lower()
        if wert in ("ja", "j", "an", "true", "yes", "1"):
            return True
        if wert in ("nein", "n", "aus", "false", "no", "0", ""):
            return False
        raise KonfigFehler(f"{schluessel} muss 'ja' oder 'nein' sein, ist aber {wert!r}")

    def pfad(self, schluessel: str) -> Path:
        return Path(self._werte[schluessel])

    def escl_url(self) -> str:
        if self.text("ESCL_URL"):
            return self.text("ESCL_URL").rstrip("/")
        if not self.text("SCANNER_IP"):
            raise KonfigFehler("SCANNER_IP ist nicht gesetzt (in /etc/scan2nas/scan2nas.conf eintragen).")
        return f"http://{self.text('SCANNER_IP')}/eSCL"


# ---------------------------------------------------------------------------
# Dateinamen und Ablage
# ---------------------------------------------------------------------------
def ziel_relpfad(muster: str, zeitpunkt: dt.datetime, endung: str) -> Path:
    """Baut aus DATEINAME_MUSTER (strftime-Platzhalter) den Pfad relativ zum NAS-Ordner.

    Beispiel: "%Y/%Y-%m/Scan_%Y-%m-%d_%H-%M-%S" -> 2026/2026-11/Scan_2026-11-12_20-43-05.pdf
    Aus Sicherheitsgründen werden ".." und absolute Pfade entfernt.
    """
    roh = zeitpunkt.strftime(muster)
    teile = [t for t in roh.replace("\\", "/").split("/") if t not in ("", ".", "..")]
    if not teile:
        raise KonfigFehler(f"DATEINAME_MUSTER {muster!r} ergibt einen leeren Dateinamen.")
    return Path(*teile[:-1]) / f"{teile[-1]}.{endung.lstrip('.')}"


def freier_dateiname(ziel: Path) -> Path:
    """Hängt _2, _3 … an, falls es die Datei schon gibt – überschrieben wird nie."""
    if not ziel.exists():
        return ziel
    for nummer in range(2, 10000):
        kandidat = ziel.with_name(f"{ziel.stem}_{nummer}{ziel.suffix}")
        if not kandidat.exists():
            return kandidat
    raise OSError(f"Kein freier Dateiname für {ziel} gefunden.")


def sicher_kopieren(quelle: Path, ziel: Path) -> Path:
    """Kopiert zuerst in eine versteckte .teil-Datei und benennt dann um.

    So taucht auf dem NAS nie eine halb geschriebene Datei auf (wichtig, falls
    z. B. paperless-ngx den Ordner überwacht).
    """
    ziel.parent.mkdir(parents=True, exist_ok=True)
    ziel = freier_dateiname(ziel)
    temp = ziel.with_name(f".{ziel.name}.teil")
    try:
        shutil.copyfile(quelle, temp)  # copyfile: keine Rechte/Zeitstempel – CIFS mag kein chmod
        os.replace(temp, ziel)
    except BaseException:
        if temp.exists():
            temp.unlink()
        raise
    return ziel


def nas_verfuegbar(nas_ordner: Path) -> bool:
    """Der NAS-Ordner muss existieren und beschreibbar sein.

    Wichtig: scan2nas legt den NAS-Ordner selbst NIE an. Fehlt er, ist das NAS
    nicht eingehängt – dann würden wir sonst in den leeren lokalen Mountpunkt
    schreiben und die Dateien wären später unter dem NAS „versteckt“.
    """
    return nas_ordner.is_dir() and os.access(nas_ordner, os.W_OK)


def ablegen(datei: Path, relpfad: Path, k: Konfiguration, verschieben: bool) -> Path:
    """Legt eine fertige Datei auf dem NAS ab – oder in der Warteschlange, falls das NAS fehlt."""
    nas = k.pfad("NAS_ORDNER")
    if nas_verfuegbar(nas):
        try:
            ziel = sicher_kopieren(datei, nas / relpfad)
            if verschieben:
                datei.unlink()
            log.info("Gespeichert auf dem NAS: %s", ziel)
            return ziel
        except OSError as fehler:
            log.warning("Schreiben aufs NAS fehlgeschlagen (%s) – Datei kommt in die Warteschlange.", fehler)
    else:
        log.warning("NAS-Ordner %s ist nicht erreichbar – Datei kommt in die Warteschlange.", nas)

    ziel = sicher_kopieren(datei, k.pfad("WARTESCHLANGE") / relpfad)
    if verschieben:
        datei.unlink()
    log.info("In der Warteschlange: %s (wird automatisch nachgeliefert)", ziel)
    return ziel


def wartende_dateien(warteschlange: Path) -> List[Path]:
    if not warteschlange.is_dir():
        return []
    return sorted(p for p in warteschlange.rglob("*") if p.is_file() and not p.name.startswith("."))


def leere_ordner_entfernen(wurzel: Path) -> None:
    for ordner in sorted((p for p in wurzel.rglob("*") if p.is_dir()), reverse=True):
        try:
            ordner.rmdir()  # klappt nur, wenn der Ordner leer ist
        except OSError:
            pass


def warteschlange_abarbeiten(k: Konfiguration) -> int:
    """Schiebt wartende Dateien aufs NAS. Gibt die Anzahl erfolgreich gelieferter Dateien zurück."""
    warteschlange = k.pfad("WARTESCHLANGE")
    dateien = wartende_dateien(warteschlange)
    if not dateien:
        return 0
    nas = k.pfad("NAS_ORDNER")
    if not nas_verfuegbar(nas):
        log.info("%d Datei(en) warten, NAS-Ordner %s ist noch nicht erreichbar.", len(dateien), nas)
        return 0
    geliefert = 0
    for datei in dateien:
        try:
            ziel = sicher_kopieren(datei, nas / datei.relative_to(warteschlange))
            datei.unlink()
            geliefert += 1
            log.info("Nachgeliefert: %s", ziel)
        except OSError as fehler:
            log.warning("Nachliefern von %s fehlgeschlagen: %s", datei, fehler)
            break
    leere_ordner_entfernen(warteschlange)
    return geliefert


def web_ausgabe_aufraeumen(k: Konfiguration) -> None:
    """Löscht alte lokale Kopien der Weboberfläche (die NAS-Kopie bleibt natürlich)."""
    tage = k.zahl("WEB_AUFBEWAHRUNG_TAGE")
    ordner = k.pfad("WEB_AUSGABE")
    if tage <= 0 or not ordner.is_dir():
        return
    grenze = time.time() - tage * 86400
    for datei in ordner.iterdir():
        try:
            if datei.is_file() and datei.stat().st_mtime < grenze:
                datei.unlink()
                log.info("Alte lokale Kopie der Weboberfläche gelöscht: %s", datei.name)
        except OSError as fehler:
            log.warning("Konnte %s nicht löschen: %s", datei, fehler)


# ---------------------------------------------------------------------------
# Scanner: Status per eSCL
# ---------------------------------------------------------------------------
@dataclass
class ScannerStatus:
    zustand: str              # Idle, Processing, Testing, Stopped, Down …
    einzug: Optional[str]     # ScannerAdfLoaded, ScannerAdfEmpty … oder None, wenn nicht gemeldet

    @property
    def bereit(self) -> bool:
        return self.zustand == "Idle"

    @property
    def einzug_belegt(self) -> bool:
        return self.einzug == "ScannerAdfLoaded"


def status_parsen(xml_text: str) -> ScannerStatus:
    """Wertet die Antwort von GET <eSCL>/ScannerStatus aus (Namensräume werden ignoriert)."""
    # Schutz vor XXE/„Billion Laughs“ ohne Zusatzpaket: eine eSCL-Antwort braucht
    # nie eine DOCTYPE- oder ENTITY-Deklaration – also gar nicht erst parsen.
    if "<!DOCTYPE" in xml_text.upper() or "<!ENTITY" in xml_text.upper():
        raise ET.ParseError("XML mit DOCTYPE/ENTITY wird aus Sicherheitsgründen abgelehnt")
    wurzel = ET.fromstring(xml_text)
    zustand: Optional[str] = None
    einzug: Optional[str] = None
    for element in wurzel:
        name = element.tag.rsplit("}", 1)[-1]
        if name == "State":
            zustand = (element.text or "").strip()
        elif name == "AdfState":
            einzug = (element.text or "").strip()
    return ScannerStatus(zustand or "Unbekannt", einzug)


def lies_status(k: Konfiguration, zeitlimit: float = 5.0) -> ScannerStatus:
    url = f"{k.escl_url()}/ScannerStatus"
    with urllib.request.urlopen(url, timeout=zeitlimit) as antwort:  # noqa: S310 (nur LAN)
        return status_parsen(antwort.read().decode("utf-8", errors="replace"))


# ---------------------------------------------------------------------------
# Scannen
# ---------------------------------------------------------------------------
def finde_geraet(k: Konfiguration) -> str:
    """Liefert den SANE-Gerätenamen, z. B. 'airscan:e0:Canon TR8550'."""
    if k.text("SCANNER_GERAET"):
        return k.text("SCANNER_GERAET")
    try:
        erg = subprocess.run(["scanimage", "-f", "%d%n"], capture_output=True, text=True,
                             timeout=ZEITLIMIT_GERAETESUCHE)
    except FileNotFoundError:
        raise ScanFehler("scanimage fehlt – bitte 'apt install sane-utils sane-airscan' ausführen.") from None
    except subprocess.TimeoutExpired:
        raise ScanFehler("Die Scanner-Suche hat zu lange gedauert (scanimage -L).") from None
    geraete = [z.strip() for z in erg.stdout.splitlines() if z.strip()]
    filter_text = k.text("SCANNER_FILTER").lower()
    passend = [g for g in geraete if filter_text in g.lower()]
    if not passend:
        gefunden = ", ".join(geraete) if geraete else "keine"
        raise ScanFehler(
            "Kein passender Scanner gefunden (Filter: "
            f"{k.text('SCANNER_FILTER')!r}, gefunden: {gefunden}). "
            "Ist der Scanner an und stimmt die IP in /etc/sane.d/airscan.conf?"
        )
    return passend[0]


class ScanSperre:
    """Verhindert, dass zwei Scans gleichzeitig laufen (z. B. Automatik + Befehl)."""

    def __init__(self, ordner: Path):
        ordner.mkdir(parents=True, exist_ok=True)
        self._pfad = ordner / ".scan.sperre"
        self._datei = None

    def __enter__(self) -> "ScanSperre":
        self._datei = open(self._pfad, "w")
        try:
            fcntl.flock(self._datei, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            self._datei.close()
            raise ScanFehler("Es läuft bereits ein Scan – bitte kurz warten.") from None
        return self

    def __exit__(self, *_: object) -> None:
        if self._datei:
            fcntl.flock(self._datei, fcntl.LOCK_UN)
            self._datei.close()


def ocr_anwenden(pdf: Path, k: Konfiguration) -> Path:
    """Macht das PDF durchsuchbar. Klappt das nicht, wird das PDF ohne OCR gespeichert."""
    if not shutil.which("ocrmypdf"):
        log.warning("ocrmypdf ist nicht installiert – PDF wird ohne Texterkennung gespeichert.")
        return pdf
    ausgabe = pdf.with_name(pdf.stem + "-ocr.pdf")
    befehl = (["ocrmypdf", "-l", k.text("OCR_SPRACHE"), "--output-type", "pdf"]
              + shlex.split(k.text("OCR_OPTIONEN")) + [str(pdf), str(ausgabe)])
    log.info("Texterkennung läuft …")
    try:
        erg = subprocess.run(befehl, capture_output=True, text=True, timeout=ZEITLIMIT_OCR)
    except subprocess.TimeoutExpired:
        log.warning("Texterkennung hat zu lange gedauert – PDF wird ohne OCR gespeichert.")
        return pdf
    if erg.returncode == 0 and ausgabe.exists():
        return ausgabe
    log.warning("Texterkennung fehlgeschlagen (Exit-Code %d) – PDF wird ohne OCR gespeichert.\n%s",
                erg.returncode, erg.stderr.strip()[-2000:])
    return pdf


def scannen(k: Konfiguration, quelle: str, modus: str, dpi: int, ocr: bool) -> Path:
    """Scannt eine Seite (Glas) oder den ganzen Einzug, baut ein PDF und legt es ab."""
    sane_quelle = {"glas": k.text("SANE_QUELLE_GLAS"), "einzug": k.text("SANE_QUELLE_EINZUG")}.get(quelle)
    sane_modus = {"farbe": k.text("SANE_MODUS_FARBE"), "grau": k.text("SANE_MODUS_GRAU")}.get(modus)
    if sane_quelle is None:
        raise KonfigFehler(f"Unbekannte Quelle {quelle!r} – erlaubt: glas, einzug")
    if sane_modus is None:
        raise KonfigFehler(f"Unbekannter Modus {modus!r} – erlaubt: farbe, grau")
    format_ = k.text("BILDFORMAT").lower()
    if format_ not in BILDENDUNGEN:
        raise KonfigFehler(f"BILDFORMAT {format_!r} wird nicht unterstützt – erlaubt: jpeg, png, tiff")
    endung = BILDENDUNGEN[format_]

    arbeitsordner = k.pfad("ARBEITSORDNER")
    with ScanSperre(arbeitsordner):
        geraet = finde_geraet(k)
        zeitpunkt = dt.datetime.now()
        with tempfile.TemporaryDirectory(prefix="scan-", dir=arbeitsordner) as tmp:
            tmp_pfad = Path(tmp)
            befehl = ["scanimage", "-d", geraet, "--source", sane_quelle, "--mode", sane_modus,
                      "--resolution", str(dpi), f"--format={format_}",
                      f"--batch={tmp_pfad}/seite-%03d.{endung}"]
            if quelle == "glas":
                befehl.append("--batch-count=1")
            log.info("Scanne von %s (%s, %d dpi) mit %s …", quelle, modus, dpi, geraet)
            try:
                erg = subprocess.run(befehl, capture_output=True, text=True, timeout=ZEITLIMIT_SCAN)
            except subprocess.TimeoutExpired:
                raise ScanFehler("Der Scan hat zu lange gedauert und wurde abgebrochen.") from None

            # scanimage schreibt jede Seite erst als *.part und benennt sie fertig um –
            # hier landen also nur vollständige Seiten.
            seiten = sorted(p for p in tmp_pfad.glob(f"seite-*.{endung}") if p.stat().st_size > 0)
            if not seiten:
                hinweis = " Liegt Papier im Einzug?" if quelle == "einzug" else ""
                raise ScanFehler(f"Der Scanner hat keine Seite geliefert (Exit-Code {erg.returncode}).{hinweis}\n"
                                 f"{erg.stderr.strip()}")
            if erg.returncode != 0:
                log.warning("scanimage meldet Exit-Code %d, %d Seite(n) sind aber angekommen: %s",
                            erg.returncode, len(seiten), erg.stderr.strip())
            log.info("%d Seite(n) gescannt – erstelle PDF …", len(seiten))

            pdf = tmp_pfad / "scan.pdf"
            try:
                subprocess.run(["img2pdf", f"--imgsize={dpi}dpi", "-o", str(pdf)] + [str(s) for s in seiten],
                               check=True, capture_output=True, text=True)
            except FileNotFoundError:
                raise ScanFehler("img2pdf fehlt – bitte 'apt install img2pdf' ausführen.") from None
            except subprocess.CalledProcessError as fehler:
                raise ScanFehler(f"PDF konnte nicht erstellt werden: {fehler.stderr.strip()}") from None

            if ocr:
                pdf = ocr_anwenden(pdf, k)
            relpfad = ziel_relpfad(k.text("DATEINAME_MUSTER"), zeitpunkt, "pdf")
            return ablegen(pdf, relpfad, k, verschieben=True)


# ---------------------------------------------------------------------------
# Einzug-Automatik
# ---------------------------------------------------------------------------
@dataclass
class AutomatikZustand:
    belegt_seit: Optional[float] = None  # seit wann liegt (ununterbrochen) Papier im Einzug?
    erledigt: bool = False               # wurde dieser Stapel schon gescannt bzw. bewusst übersprungen?


def soll_automatisch_scannen(z: AutomatikZustand, status: ScannerStatus, jetzt: float,
                             wartezeit: float) -> bool:
    """Entscheidet, ob die Automatik jetzt den Einzug scannen soll (und merkt sich den Zustand).

    Regeln:
    * Erst wenn das Papier `wartezeit` Sekunden ununterbrochen im Einzug liegt –
      so bleibt Zeit, den Stapel fertig einzulegen oder am Gerät „Kopieren“ zu drücken.
    * Jeder Stapel wird nur EINMAL gescannt. Schlägt der Scan fehl (z. B. Papierstau),
      wird nicht endlos neu versucht; erst nach Herausnehmen und neu Einlegen.
    * Nur wenn der Scanner frei ist (nicht gerade druckt, kopiert oder scannt).
    """
    if not status.einzug_belegt:
        z.belegt_seit = None
        z.erledigt = False
        return False
    if z.belegt_seit is None:
        z.belegt_seit = jetzt
    if z.erledigt or not status.bereit:
        return False
    return jetzt - z.belegt_seit >= wartezeit


def schlafen(sekunden: float, abbrechen: Callable[[], bool]) -> None:
    ende = time.monotonic() + sekunden
    while not abbrechen() and time.monotonic() < ende:
        time.sleep(min(0.5, max(0.0, ende - time.monotonic())))


def automatik(k: Konfiguration) -> int:
    """Hintergrunddienst: liefert die Warteschlange nach und scannt optional den Einzug."""
    gestoppt = False

    def beenden(_signum: int, _frame: object) -> None:
        nonlocal gestoppt
        gestoppt = True

    signal.signal(signal.SIGTERM, beenden)
    signal.signal(signal.SIGINT, beenden)

    aktiv = k.janein("AUTOMATIK_AKTIV")
    intervall = max(1, k.zahl("AUTOMATIK_INTERVALL"))
    wartezeit = max(0, k.zahl("AUTOMATIK_WARTEZEIT"))
    ws_intervall = max(10, k.zahl("WARTESCHLANGE_INTERVALL"))
    if aktiv:
        k.escl_url()  # prüft früh, ob SCANNER_IP gesetzt ist

    log.info("Hintergrunddienst gestartet (Version %s, Einzug-Automatik: %s).", VERSION, "an" if aktiv else "aus")
    zustand = AutomatikZustand()
    erste_abfrage = True
    scanner_weg_gemeldet = False
    kein_einzug_gemeldet = False
    letzte_wartung = 0.0

    while not gestoppt:
        jetzt = time.monotonic()
        if jetzt - letzte_wartung >= ws_intervall or letzte_wartung == 0.0:
            try:
                warteschlange_abarbeiten(k)
                web_ausgabe_aufraeumen(k)
            except OSError as fehler:
                log.warning("Wartung fehlgeschlagen: %s", fehler)
            letzte_wartung = jetzt

        if aktiv:
            status: Optional[ScannerStatus] = None
            try:
                status = lies_status(k)
                if scanner_weg_gemeldet:
                    log.info("Scanner ist wieder erreichbar.")
                    scanner_weg_gemeldet = False
            except (OSError, ET.ParseError) as fehler:
                if not scanner_weg_gemeldet:
                    log.warning("Scanner nicht erreichbar (%s) – versuche es weiter. "
                                "Schläft er vielleicht oder ist aus?", fehler)
                    scanner_weg_gemeldet = True

            if status is not None:
                if status.einzug is None and not kein_einzug_gemeldet:
                    log.warning("Der Scanner meldet keinen Einzug-Status (AdfState) – "
                                "die Einzug-Automatik kann mit diesem Gerät nicht funktionieren.")
                    kein_einzug_gemeldet = True
                if erste_abfrage:
                    # Liegt beim Start schon Papier drin, könnte das ein Rest sein – lieber nicht scannen.
                    erste_abfrage = False
                    if status.einzug_belegt:
                        zustand.belegt_seit, zustand.erledigt = jetzt, True
                        log.info("Beim Start liegt schon Papier im Einzug – wird nicht automatisch "
                                 "gescannt. Bitte herausnehmen und neu einlegen.")
                elif soll_automatisch_scannen(zustand, status, jetzt, wartezeit):
                    zustand.erledigt = True
                    log.info("Papier im Einzug erkannt – starte automatischen Scan.")
                    try:
                        scannen(k, "einzug", k.text("AUTOMATIK_MODUS"), k.zahl("AUFLOESUNG"),
                                k.janein("OCR_AKTIV"))
                    except (ScanFehler, KonfigFehler, OSError, subprocess.SubprocessError) as fehler:
                        log.error("Automatischer Scan fehlgeschlagen: %s", fehler)

        schlafen(intervall, lambda: gestoppt)

    log.info("Hintergrunddienst beendet.")
    return 0


# ---------------------------------------------------------------------------
# Übernahme von Dateien (z. B. aus der Weboberfläche)
# ---------------------------------------------------------------------------
def uebernehmen(k: Konfiguration, dateien: List[str], verschieben: bool) -> int:
    fehler = 0
    for name in dateien:
        datei = Path(name)
        if not datei.is_file():
            log.error("Datei nicht gefunden: %s", datei)
            fehler += 1
            continue
        zeitpunkt = dt.datetime.fromtimestamp(datei.stat().st_mtime)
        endung = datei.suffix.lstrip(".") or "dat"
        ablegen(datei, ziel_relpfad(k.text("DATEINAME_MUSTER"), zeitpunkt, endung), k, verschieben)
    return 1 if fehler else 0


# ---------------------------------------------------------------------------
# Diagnose
# ---------------------------------------------------------------------------
def test(k: Konfiguration) -> int:
    """Prüft alles, was für einen erfolgreichen Scan nötig ist, und gibt eine Übersicht aus."""
    probleme = 0

    def zeile(ok: Optional[bool], text: str) -> None:
        nonlocal probleme
        zeichen = {True: "✔", False: "✘", None: "!"}[ok]
        if ok is False:
            probleme += 1
        print(f" {zeichen} {text}")

    print(f"scan2nas {VERSION} – Selbsttest (Konfiguration: {k.quelle})\n")

    for programm, paket, pflicht in (("scanimage", "sane-utils", True), ("img2pdf", "img2pdf", True),
                                     ("ocrmypdf", "ocrmypdf", False)):
        if shutil.which(programm):
            zeile(True, f"{programm} ist installiert")
        else:
            zeile(False if pflicht else None, f"{programm} fehlt (apt install {paket})")

    if k.janein("OCR_AKTIV") and shutil.which("tesseract"):
        sprachen = subprocess.run(["tesseract", "--list-langs"], capture_output=True, text=True).stdout.split()
        sprache_ok = all(s in sprachen for s in k.text("OCR_SPRACHE").split("+"))
        zeile(sprache_ok or None, f"OCR-Sprache {k.text('OCR_SPRACHE')} "
              + ("ist installiert" if sprache_ok else "fehlt (apt install tesseract-ocr-deu)"))

    try:
        status = lies_status(k)
        einzug = status.einzug or "wird nicht gemeldet"
        zeile(True, f"Scanner antwortet per eSCL ({k.escl_url()}): Zustand {status.zustand}, Einzug {einzug}")
    except KonfigFehler as fehler:
        zeile(False, str(fehler))
    except (OSError, ET.ParseError) as fehler:
        zeile(False, f"Scanner antwortet nicht unter {k.escl_url()}: {fehler}")

    try:
        zeile(True, f"SANE findet den Scanner: {finde_geraet(k)}")
    except ScanFehler as fehler:
        zeile(False, str(fehler))

    nas = k.pfad("NAS_ORDNER")
    if nas_verfuegbar(nas):
        probe = nas / ".scan2nas-schreibtest"
        try:
            probe.write_text("ok", encoding="utf-8")
            probe.unlink()
            zeile(True, f"NAS-Ordner {nas} ist beschreibbar")
        except OSError as fehler:
            zeile(False, f"NAS-Ordner {nas} ist nicht beschreibbar: {fehler}")
    else:
        zeile(False, f"NAS-Ordner {nas} fehlt oder ist nicht beschreibbar – ist das NAS eingehängt?")

    anzahl = len(wartende_dateien(k.pfad("WARTESCHLANGE")))
    zeile(True if anzahl == 0 else None, f"Warteschlange: {anzahl} Datei(en)")
    zeile(None if k.janein("AUTOMATIK_AKTIV") else True,
          f"Einzug-Automatik ist {'AN' if k.janein('AUTOMATIK_AKTIV') else 'aus'}")

    print("\nAlles in Ordnung." if probleme == 0 else f"\n{probleme} Problem(e) gefunden – siehe docs/04-fehlerbehebung.md")
    return 0 if probleme == 0 else 1


# ---------------------------------------------------------------------------
# Kommandozeile
# ---------------------------------------------------------------------------
def logging_einrichten(stufe: str) -> None:
    for level, name in ((logging.DEBUG, "DEBUG"), (logging.INFO, "INFO"),
                        (logging.WARNING, "WARNUNG"), (logging.ERROR, "FEHLER")):
        logging.addLevelName(level, name)
    logging.basicConfig(level=getattr(logging, stufe.upper(), logging.INFO),
                        format="%(levelname)s: %(message)s", stream=sys.stderr)


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        prog="scan2nas", description="Holt Scans vom Scanner und legt sie als PDF auf dem NAS ab.")
    parser.add_argument("-k", "--konfig", default=os.environ.get("SCAN2NAS_KONFIG", STANDARD_KONFIG),
                        help=f"Konfigurationsdatei (Standard: {STANDARD_KONFIG})")
    parser.add_argument("-v", "--ausfuehrlich", action="store_true", help="mehr Ausgaben (Debug)")
    parser.add_argument("--version", action="version", version=f"scan2nas {VERSION}")
    befehle = parser.add_subparsers(dest="befehl", metavar="BEFEHL")
    befehle.required = True

    p = befehle.add_parser("scannen", help="einen Scan starten und aufs NAS speichern")
    p.add_argument("-q", "--quelle", choices=["glas", "einzug"], help="Vorlagenglas oder Einzug (ADF)")
    p.add_argument("-m", "--modus", choices=["farbe", "grau"], help="Farbe oder Graustufen")
    p.add_argument("-d", "--dpi", type=int, help="Auflösung, z. B. 150, 300, 600")
    p.add_argument("--ohne-ocr", action="store_true", help="keine Texterkennung")

    p = befehle.add_parser("uebernehmen", help="vorhandene Datei(en) aufs NAS legen")
    p.add_argument("dateien", nargs="+", metavar="DATEI")
    p.add_argument("--verschieben", action="store_true", help="Original danach löschen")

    befehle.add_parser("automatik", help="Hintergrunddienst (Warteschlange + Einzug-Automatik)")
    befehle.add_parser("warteschlange", help="wartende Scans jetzt aufs NAS schieben")
    befehle.add_parser("status", help="Scannerstatus anzeigen")
    befehle.add_parser("test", help="Selbsttest: Programme, Scanner, NAS")

    args = parser.parse_args(argv)
    os.umask(0o002)  # neue Dateien/Ordner auch für die Gruppe 'users' beschreibbar (scanservjs)
    logging_einrichten("INFO")

    try:
        k = Konfiguration.laden(args.konfig)
        stufe = "DEBUG" if args.ausfuehrlich else k.text("LOGLEVEL").upper()
        logging.getLogger().setLevel(getattr(logging, stufe, logging.INFO))

        if args.befehl == "scannen":
            scannen(k, args.quelle or k.text("QUELLE"), args.modus or k.text("MODUS"),
                    args.dpi or k.zahl("AUFLOESUNG"), k.janein("OCR_AKTIV") and not args.ohne_ocr)
            return 0
        if args.befehl == "uebernehmen":
            return uebernehmen(k, args.dateien, args.verschieben)
        if args.befehl == "automatik":
            return automatik(k)
        if args.befehl == "warteschlange":
            anzahl = warteschlange_abarbeiten(k)
            rest = len(wartende_dateien(k.pfad("WARTESCHLANGE")))
            print(f"{anzahl} Datei(en) nachgeliefert, {rest} warten noch.")
            return 0 if rest == 0 else 1
        if args.befehl == "status":
            status = lies_status(k)
            print(f"Zustand: {status.zustand}")
            print(f"Einzug:  {status.einzug or 'wird nicht gemeldet'}")
            return 0
        if args.befehl == "test":
            return test(k)
    except KonfigFehler as fehler:
        log.error("Konfigurationsfehler: %s", fehler)
        return 2
    except ScanFehler as fehler:
        log.error("%s", fehler)
        return 1
    except OSError as fehler:
        log.error("%s", fehler)
        return 1
    except KeyboardInterrupt:
        return 130
    return 2


if __name__ == "__main__":
    sys.exit(main())
