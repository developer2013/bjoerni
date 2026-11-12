"""Tests für adguard-home/einrichten.sh.

1. Reine Hilfsfunktionen (JSON bauen, Passwort prüfen, Listen/Namen planen).
2. Die komplette API-Abfolge gegen eine nachgebaute AdGuard-Home-API.
   Die Attrappe hält sich an AdGuards openapi.yaml (v0.107.x) und lehnt alles
   ab, was dort nicht erlaubt ist: unbekannte Felder, falsche Typen, fehlende
   Pflichtfelder, fehlende oder falsche Anmeldung, doppelte Sperrlisten.

Aufruf im Projektordner:
    python3 -m unittest discover -s tests -v
"""
import base64
import copy
import json
import os
import subprocess
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

SKRIPT = Path(__file__).resolve().parents[1] / "adguard-home" / "einrichten.sh"
KATALOG = "https://adguardteam.github.io/HostlistsRegistry/assets"


def bash(befehle: str, **umgebung: str) -> subprocess.CompletedProcess:
    env = dict(os.environ, ADGUARD_NUR_LADEN="1", **umgebung)
    return subprocess.run(["bash", "-c", f'source "{SKRIPT}"; {befehle}'],
                          capture_output=True, text=True, env=env, timeout=60)


# ---------------------------------------------------------------------------
# 1. Hilfsfunktionen
# ---------------------------------------------------------------------------
class HilfsfunktionenTest(unittest.TestCase):
    def json(self, befehl: str, **umgebung: str):
        erg = bash(befehl, **umgebung)
        self.assertEqual(erg.returncode, 0, erg.stderr)
        return json.loads(erg.stdout)

    def test_dns_config_mit_fritzbox(self):
        d = self.json("json_dns_config 192.168.100.1 ja '[\"10.0.0.9\",\"192.168.100.1\"]'")
        self.assertEqual(d["upstream_dns"], ["https://dns.quad9.net/dns-query",
                                             "https://unfiltered.joindns4.eu/dns-query",
                                             "[/fritz.box/]192.168.100.1"])
        self.assertEqual(d["bootstrap_dns"], ["9.9.9.9", "149.112.112.112"])
        self.assertEqual(d["local_ptr_upstreams"], ["192.168.100.1"])
        self.assertEqual(d["ratelimit_whitelist"], ["10.0.0.9", "192.168.100.1"], "zusammengeführt, ohne Doppel")
        self.assertEqual(d["upstream_mode"], "load_balance")
        self.assertTrue(d["dnssec_enabled"] and d["use_private_ptr_resolvers"] and d["resolve_clients"])

    def test_dns_config_ohne_fritzbox(self):
        d = self.json("json_dns_config 10.0.0.1 nein")
        self.assertNotIn("[/fritz.box/]10.0.0.1", d["upstream_dns"])
        self.assertEqual(d["ratelimit_whitelist"], ["10.0.0.1"])

    def test_ersteinrichtung_ohne_passwort_in_argumenten(self):
        d = self.json("json_ersteinrichtung", AG_BENUTZER="admin", AG_PASSWORT='Ge$heim "1"',
                      AG_WEB_PORT="80", AG_DNS_PORT="53")
        self.assertEqual(d, {"web": {"ip": "0.0.0.0", "port": 80}, "dns": {"ip": "0.0.0.0", "port": 53},
                             "language": "de", "username": "admin", "password": 'Ge$heim "1"'})

    def test_passwortlaenge(self):
        for pw, erwartet in (("1234567", 1), ("12345678", 0), ("x" * 72, 0), ("x" * 73, 1), ("äöüäöüäö", 0)):
            self.assertEqual(bash(f"passwort_pruefen '{pw}'").returncode, erwartet, pw)

    def test_fehlende_listen(self):
        status = json.dumps({"filters": [{"url": f"{KATALOG}/filter_1.txt"}, {"url": f"{KATALOG}/filter_48.txt"}]})
        erg = bash(f"fehlende_listen '{status}' {KATALOG}/filter_48.txt {KATALOG}/filter_44.txt")
        self.assertEqual(erg.stdout.split(), [f"{KATALOG}/filter_44.txt"])

    def test_umschreibungen_planen(self):
        liste = json.dumps([{"domain": "scanner.lan", "answer": "192.168.100.60", "enabled": True},
                            {"domain": "nas.lan", "answer": "192.168.100.99", "enabled": True}])
        erg = bash(f"umschreibungen_planen '{liste}' scanner.lan=192.168.100.60 nas.lan=192.168.100.56 adguard.lan=192.168.100.53")
        self.assertEqual(erg.stdout.splitlines(), [
            "gleich scanner.lan 192.168.100.60",
            "anders nas.lan 192.168.100.99 192.168.100.56",
            "neu adguard.lan 192.168.100.53",
        ])

    def test_cidr(self):
        self.assertEqual(bash("ist_cidr 192.168.100.53/24").returncode, 0)
        self.assertNotEqual(bash("ist_cidr 192.168.100.53").returncode, 0)


# ---------------------------------------------------------------------------
# 2. Nachgebaute AdGuard-Home-API
# ---------------------------------------------------------------------------
DNS_CONFIG_FELDER = {
    "bootstrap_dns": list, "upstream_dns": list, "fallback_dns": list, "upstream_mode": str,
    "local_ptr_upstreams": list, "use_private_ptr_resolvers": bool, "resolve_clients": bool,
    "dnssec_enabled": bool, "protection_enabled": bool, "ratelimit": int, "ratelimit_whitelist": list,
}


class FalscheAnfrage(Exception):
    pass


class AttrappenZustand:
    def __init__(self):
        self.eingerichtet = False
        self.zugang = None
        self.dns = {"upstream_dns": ["https://dns10.quad9.net/dns-query"], "bootstrap_dns": ["9.9.9.10"],
                    "fallback_dns": [], "upstream_mode": "load_balance", "local_ptr_upstreams": [],
                    "use_private_ptr_resolvers": False, "resolve_clients": False, "dnssec_enabled": False,
                    "protection_enabled": True, "ratelimit": 20, "ratelimit_whitelist": ["10.0.0.9"]}
        self.querylog = {"enabled": True, "interval": 7776000000, "anonymize_client_ip": True,
                         "ignored": ["ignoriert.example"], "ignored_enabled": True}
        self.stats = {"enabled": True, "interval": 86400000, "ignored": ["stats.example"], "ignored_enabled": True}
        self.filter = [{"url": f"{KATALOG}/filter_1.txt", "name": "AdGuard DNS filter", "enabled": True}]
        self.rewrites = []
        self.safebrowsing = False
        self.anfragen = []
        self.fehler = []


def baue_handler(z: AttrappenZustand):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def antworte(self, code, daten=None):
            koerper = b"" if daten is None else json.dumps(daten).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(koerper)))
            self.end_headers()
            self.wfile.write(koerper)

        def koerper(self):
            laenge = int(self.headers.get("Content-Length") or 0)
            if not laenge:
                return None
            if self.headers.get("Content-Type") != "application/json":
                raise FalscheAnfrage("Content-Type muss application/json sein")
            return json.loads(self.rfile.read(laenge))

        def angemeldet(self):
            kopf = self.headers.get("Authorization", "")
            return z.zugang and kopf == "Basic " + base64.b64encode(z.zugang.encode()).decode()

        def bearbeite(self, methode):
            pfad = urlparse(self.path).path
            z.anfragen.append(f"{methode} {pfad}")
            try:
                daten = self.koerper()
                code, antwort = self.route(methode, pfad, daten)
            except FalscheAnfrage as f:
                z.fehler.append(f"{methode} {pfad}: {f}")
                code, antwort = 400, {"message": str(f)}
            self.antworte(code, antwort)

        def do_GET(self):
            self.bearbeite("GET")

        def do_POST(self):
            self.bearbeite("POST")

        def do_PUT(self):
            self.bearbeite("PUT")

        def route(self, m, p, d):
            # --- Einrichtungsassistent -------------------------------------
            if not z.eingerichtet:
                if (m, p) == ("GET", "/control/install/get_addresses"):
                    return 200, {"interfaces": {}, "web_port": 3000, "dns_port": 53}
                if (m, p) == ("POST", "/control/install/configure"):
                    if set(d) - {"web", "dns", "username", "password", "language"}:
                        raise FalscheAnfrage(f"unbekannte Felder {set(d)}")
                    for teil in ("web", "dns"):
                        if not isinstance(d[teil].get("ip"), str) or not isinstance(d[teil].get("port"), int):
                            raise FalscheAnfrage(f"{teil} braucht ip (Text) und port (Zahl)")
                    if not 8 <= len(d["password"].encode()) <= 72:
                        return 422, {"message": "password too weak"}
                    z.eingerichtet, z.zugang = True, f"{d['username']}:{d['password']}"
                    return 200, None
                return 403, None
            if p.startswith("/control/install/"):
                return 403, None
            if not self.angemeldet():
                return 401, None
            # --- normale API -----------------------------------------------
            if (m, p) == ("GET", "/control/status"):
                return 200, {"running": True, "version": "v0.107.80", "protection_enabled": True}
            if (m, p) == ("GET", "/control/dns_info"):
                return 200, copy.deepcopy(z.dns)
            if (m, p) == ("POST", "/control/dns_config"):
                for feld, wert in d.items():
                    if feld not in DNS_CONFIG_FELDER or not isinstance(wert, DNS_CONFIG_FELDER[feld]):
                        raise FalscheAnfrage(f"Feld {feld}={wert!r} passt nicht zu DNSConfig")
                if d.get("upstream_mode") not in (None, "load_balance", "parallel", "fastest_addr"):
                    raise FalscheAnfrage("upstream_mode ungültig")
                z.dns.update(d)
                return 200, None
            if (m, p) == ("POST", "/control/test_upstream_dns"):
                if set(d) - {"upstream_dns", "bootstrap_dns", "fallback_dns", "private_upstream"}:
                    raise FalscheAnfrage("unbekannte Felder in UpstreamsConfig")
                return 200, {u: "OK" for u in d["upstream_dns"]}
            if (m, p) == ("POST", "/control/safebrowsing/enable"):
                if d is not None:
                    raise FalscheAnfrage("safebrowsing/enable erwartet keinen Inhalt")
                z.safebrowsing = True
                return 200, None
            if (m, p) == ("GET", "/control/querylog/config"):
                return 200, copy.deepcopy(z.querylog)
            if (m, p) == ("PUT", "/control/querylog/config/update"):
                if {"enabled", "interval", "anonymize_client_ip", "ignored"} - set(d):
                    raise FalscheAnfrage("Pflichtfelder fehlen (enabled, interval, anonymize_client_ip, ignored)")
                z.querylog = d
                return 200, None
            if (m, p) == ("GET", "/control/stats/config"):
                return 200, copy.deepcopy(z.stats)
            if (m, p) == ("PUT", "/control/stats/config/update"):
                if {"enabled", "interval", "ignored"} - set(d):
                    raise FalscheAnfrage("Pflichtfelder fehlen (enabled, interval, ignored)")
                z.stats = d
                return 200, None
            if (m, p) == ("GET", "/control/filtering/status"):
                return 200, {"enabled": True, "interval": 24, "filters": copy.deepcopy(z.filter)}
            if (m, p) == ("POST", "/control/filtering/add_url"):
                if set(d) != {"name", "url", "whitelist"} or d["whitelist"] is not False:
                    raise FalscheAnfrage(f"AddUrlRequest falsch: {d}")
                if any(f["url"] == d["url"] for f in z.filter):
                    return 400, {"message": "filter URL already added"}
                z.filter.append({"url": d["url"], "name": d["name"], "enabled": True})
                return 200, None
            if (m, p) == ("GET", "/control/rewrite/list"):
                return 200, copy.deepcopy(z.rewrites)
            if (m, p) == ("POST", "/control/rewrite/add"):
                if set(d) - {"domain", "answer", "enabled"} or not {"domain", "answer"} <= set(d):
                    raise FalscheAnfrage(f"RewriteEntry falsch: {d}")
                z.rewrites.append(d)
                return 200, None
            if (m, p) == ("GET", "/control/filtering/check_host"):
                name = parse_qs(urlparse(self.path).query).get("name", [""])[0]
                return 200, {"reason": "FilteredBlackList" if name == "doubleclick.net" else "NotFilteredNotFound"}
            raise FalscheAnfrage("unbekannter Endpunkt")

    return Handler


class ServerBasis(unittest.TestCase):
    """Startet die API-Attrappe auf einem freien Port."""

    def setUp(self):
        self.z = AttrappenZustand()
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), baue_handler(self.z))
        self.port = str(self.server.server_address[1])
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()

    def skript(self, befehle: str, **umgebung) -> subprocess.CompletedProcess:
        return bash(befehle, AG_IP="127.0.0.1", AG_SETUP_PORT=self.port, AG_WEB_PORT=self.port, **umgebung)



class ApiAblaufTest(ServerBasis):
    ANWENDEN = ('ag_einstellungen_anwenden 192.168.100.1 ja pro ja '
                'scanner.lan=192.168.100.60 adguard.lan=192.168.100.53')

    def test_kompletter_ablauf_und_wiederholung(self):
        erg = self.skript(f'''
            ag_setup_offen || {{ echo "Setup nicht erkannt"; exit 1; }}
            ag_ersteinrichtung "$AG_BENUTZER" "$AG_PASSWORT" || {{ echo "Erstkonfiguration: $AG_ANTWORT"; exit 1; }}
            ag_zugang_setzen "$AG_BENUTZER" "$AG_PASSWORT"
            ag_anmelden_pruefen || {{ echo "Anmeldung: $AG_HTTP"; exit 1; }}
            ag_upstreams_testen 192.168.100.1 ja; echo "UPSTREAM_FEHLER=[$UPSTREAM_FEHLER]"
            {self.ANWENDEN}
            ag_blockiert_werbung && echo "BLOCKIERT"
        ''', AG_BENUTZER="admin", AG_PASSWORT="Sehr$icher 123")
        self.assertEqual(erg.returncode, 0, erg.stdout + erg.stderr)
        self.assertEqual(self.z.fehler, [], "Das Skript hat etwas geschickt, das nicht zur API passt")
        self.assertIn("UPSTREAM_FEHLER=[]", erg.stdout)
        self.assertIn("BLOCKIERT", erg.stdout)
        self.assertNotIn("FEHLER", erg.stdout.replace("UPSTREAM_FEHLER", ""))

        # Ergebnis in AdGuard
        self.assertEqual(self.z.zugang, "admin:Sehr$icher 123")
        self.assertIn("[/fritz.box/]192.168.100.1", self.z.dns["upstream_dns"])
        self.assertEqual(self.z.dns["ratelimit_whitelist"], ["10.0.0.9", "192.168.100.1"])
        self.assertTrue(self.z.dns["dnssec_enabled"])
        self.assertTrue(self.z.safebrowsing)
        self.assertEqual(self.z.querylog["interval"], 7 * 24 * 3600 * 1000)
        self.assertEqual(self.z.querylog["ignored"], ["ignoriert.example"], "übrige Einstellungen bleiben")
        self.assertTrue(self.z.querylog["anonymize_client_ip"])
        self.assertEqual(self.z.stats["interval"], 30 * 24 * 3600 * 1000)
        self.assertEqual(self.z.stats["ignored"], ["stats.example"])
        self.assertEqual([f["url"] for f in self.z.filter],
                         [f"{KATALOG}/filter_1.txt", f"{KATALOG}/filter_48.txt", f"{KATALOG}/filter_44.txt"])
        self.assertEqual({r["domain"]: r["answer"] for r in self.z.rewrites},
                         {"scanner.lan": "192.168.100.60", "adguard.lan": "192.168.100.53"})

        # Zweiter Lauf: nichts doppelt, kein Fehler
        erg = self.skript(f'ag_zugang_setzen admin "Sehr\\$icher 123"; {self.ANWENDEN}')
        self.assertEqual(erg.returncode, 0, erg.stdout + erg.stderr)
        self.assertEqual(len(self.z.filter), 3)
        self.assertEqual(len(self.z.rewrites), 2)
        self.assertIn("gab es schon", erg.stdout)
        self.assertEqual(self.z.fehler, [])

    def test_falsches_passwort_wird_erkannt(self):
        self.z.eingerichtet, self.z.zugang = True, "admin:richtig123"
        erg = self.skript('ag_zugang_setzen admin falsch123; if ! ag_anmelden_pruefen; then echo "HTTP=$AG_HTTP"; fi')
        self.assertIn("HTTP=401", erg.stdout)
        erg = self.skript('ag_zugang_setzen admin richtig123; ag_anmelden_pruefen && echo "HTTP=$AG_HTTP"')
        self.assertIn("HTTP=200", erg.stdout)

    def test_zu_kurzes_passwort_lehnt_adguard_ab(self):
        erg = self.skript('ag_ersteinrichtung admin kurz || echo "ABGELEHNT"', AG_BENUTZER="admin", AG_PASSWORT="kurz")
        self.assertIn("ABGELEHNT", erg.stdout)
        self.assertFalse(self.z.eingerichtet)


# ---------------------------------------------------------------------------
# 3. Kompletter Dialogablauf (main) mit Attrappen für Proxmox und whiptail
# ---------------------------------------------------------------------------
PROXMOX_ATTRAPPEN = r'''
vorpruefungen() { :; }          # root-/Proxmox-Prüfung gibt es auf dem Testrechner nicht
clear() { :; }
whiptail() {
  local typ="" a
  for a in "$@"; do
    case $a in --inputbox|--passwordbox|--menu|--yesno|--msgbox|--infobox|--checklist) typ=$a ;; esac
  done
  printf '%s %s\n' "$typ" "$*" >> "$PROTOKOLL"
  case $typ in
    --msgbox|--infobox) return 0 ;;
    --yesno) IFS= read -r a <&9; return "$a" ;;
    --checklist) IFS= read -r a <&9; printf '%s\n' "${a//|/$'\n'}" >&2 ;;
    *) IFS= read -r a <&9; printf '%s' "$a" >&2 ;;
  esac
}
pct() {
  echo "pct $*" >> "$PROTOKOLL"
  case "$*" in
    list) printf 'VMID       Status     Lock         Name\n101        running                 adguard\n104        running                 paperless-ngx\n107        running                 scanner\n' ;;
    "exec 101 -- test -x /opt/AdGuardHome/AdGuardHome") return 0 ;;
    "exec "*" -- test -x /opt/AdGuardHome/AdGuardHome") return 1 ;;
    "exec 101 -- ip -4 addr show eth0") echo "    inet 127.0.0.1/8 scope global eth0" ;;
    "exec 107 -- ip -4 addr show eth0") echo "    inet 192.168.100.60/24 brd 192.168.100.255 scope global eth0" ;;
    "exec 101 -- ip -6 addr show eth0") echo "    inet6 fd00::be24:11ff:fe2a:7c3d/64 scope global dynamic mngtmpaddr" ;;
    "exec 101 -- ip route") echo "default via 192.168.100.1 dev eth0" ;;
    "config 101") echo "net0: name=eth0,bridge=vmbr0,hwaddr=BC:24:11:00:00:01,ip=dhcp,ip6=auto,type=veth" ;;
    set*) return 0 ;;
    *) return 1 ;;
  esac
}
ip() {
  case "$*" in
    "route show default") echo "default via 192.168.100.1 dev vmbr0 proto kernel onlink" ;;
    "-4 -o addr show dev vmbr0") echo "5: vmbr0    inet 192.168.100.11/24 scope global vmbr0" ;;
  esac
}
# FRITZ!Box-Erkennung: die Startseite des Routers enthält "FRITZ!Box"
curl() {
  if [[ $* == *"http://192.168.100.1/"* ]]; then echo "<title>FRITZ!Box</title>"; return 0; fi
  command curl "$@"
}
'''


class DialogAblaufTest(ServerBasis):
    ANTWORTEN = [
        "101",                                            # gefundener AdGuard-Container
        "0",                                              # DHCP-Adresse fest machen? Ja
        "admin",                                          # Benutzer
        "Sehr$icher 123",                                 # Passwort
        "Sehr$icher 123",                                 # Passwort wiederholt
        "192.168.100.1",                                  # Router
        "pro",                                            # Filterstufe
        "0",                                              # Threat Intelligence? Ja
        "adguard.lan=127.0.0.1|scanner.lan=192.168.100.60",  # eigene Namen
        "0",                                              # Zusammenfassung: Ja
    ]

    def test_main_mit_vorhandenem_container(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            (tmp / "antworten.txt").write_text("\n".join(self.ANTWORTEN) + "\n")
            protokoll = tmp / "protokoll.txt"
            erg = self.skript(PROXMOX_ATTRAPPEN + f'exec 9< "{tmp}/antworten.txt"; main',
                              PROTOKOLL=str(protokoll))
            text = protokoll.read_text()
            self.assertEqual(erg.returncode, 0, erg.stdout + erg.stderr)
            self.assertEqual(self.z.fehler, [])

            # Proxmox: feste IP (hwaddr & Co. bleiben erhalten) und Startreihenfolge
            self.assertIn("pct set 101 -net0 name=eth0,bridge=vmbr0,hwaddr=BC:24:11:00:00:01,"
                          "ip=127.0.0.1/8,gw=192.168.100.1,ip6=auto,type=veth", text)
            self.assertIn("pct set 101 --onboot 1 --startup order=1,up=15", text)
            # Vorschläge und Erkennung
            self.assertIn("scanner.lan=192.168.100.60", text, "scan2nas-Container wird als Name vorgeschlagen")
            self.assertIn("FRITZ!Box erkannt", text)
            # AdGuard wurde eingerichtet
            self.assertEqual(self.z.zugang, "admin:Sehr$icher 123")
            self.assertIn("[/fritz.box/]192.168.100.1", self.z.dns["upstream_dns"])
            self.assertEqual({r["domain"] for r in self.z.rewrites}, {"adguard.lan", "scanner.lan"})
            # Abschluss mit den Werten für die FRITZ!Box
            self.assertIn("Lokaler DNS-Server:   127.0.0.1", erg.stdout)
            self.assertIn("Lokaler DNSv6-Server: fd00::be24:11ff:fe2a:7c3d", erg.stdout)
            self.assertNotIn("Sehr$icher", text, "Passwort darf nirgends protokolliert werden")


if __name__ == "__main__":
    unittest.main()
