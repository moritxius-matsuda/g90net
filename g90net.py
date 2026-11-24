#!/usr/bin/env python3
# =====================================================================
#  g90net - eigenes GSM(2G)- und LTE(4G)-Versuchsnetz mit Weboberflaeche
#  2G: Osmocom. 4G: srsENB (Funk) + Open5GS (Kern). Je Netz ein eigener
#  LimeSDR (Auswahl im Webinterface). Modus "LTE + GSM" = CSFB: Handy bucht
#  in 4G (Internet) ein, Anrufe fallen ueber SGs kurz auf GSM zurueck.
#  SIMs werden nur einmal eingetragen (osmo-hlr + Open5GS-HSS automatisch).
#
#  !!!  NUR an Dummy Load / Kabel + Daempfung / geschirmt betreiben.
#       Ein offenes Netz ohne Authentisierung = IMSI-Catcher, wenn es
#       abstrahlt. Nur eigene Test-SIMs. Testkennung 001/01 oder 999/99.
# =====================================================================
import os, re, sys, json, time, shutil, socket, secrets, threading, subprocess
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# ------------------------------------------------------------------ Konfig
CONF = os.environ.get("G90NET_CONF", "/etc/g90net.conf")
WORKDIR = os.environ.get("G90NET_WORKDIR", "/var/lib/g90net")
OSMO_CFG = "/etc/osmocom"
SRS_CFG = "/etc/srsran"

DEFAULTS = {
    "WEB_PORT": "8080",
    # gemeinsam
    "TECH": "gsm",            # zuletzt gestartet
    "MCC": "001", "MNC": "01", "NETNAME": "pKOM", "NETNAME_SHORT": "pKOM", "SPN": "pKOM",
    "NITZ": "1",              # Netzname + Uhrzeit/Zeitzone ans Handy senden (GSM: MM-Info, LTE: EMM-Info)
    # LimeSDR je Netz (Seriennummer, leer = automatisch)
    "GSM_DEV": "", "LTE_DEV": "",
    # 2G
    "GSM_ARFCN": "20", "GSM_TX_GAIN": "50", "GSM_RX_GAIN": "45",
    "GSM_OPEN": "1", "GSM_DATA": "0", "GSM_SIP": "0", "GSM_SIP_PEER": "", "GSM_SIP_LOCAL": "",
    # SMS (Begruessung beim Einbuchen + Bestaetigung bei Nummernvergabe)
    "GSM_SMS": "1", "GSM_SMS_FROM": "1000",
    # {extern} = Vorwahl-Block + interne Nummer (leer = nur die interne Nummer)
    "GSM_SMS_EXTPREFIX": "+49 651 635555",
    "GSM_SMS_WELCOME": "Willkommen im {netz}! Du bist jetzt eingebucht. 73",
    "GSM_SMS_NUMBER": "Deine Rufnummer im {netz}-Netz ist jetzt {nummer}. Extern erreichbar: {extern}",
    # 4G
    "LTE_EARFCN": "1575", "LTE_NPRB": "25", "LTE_TX_GAIN": "80", "LTE_RX_GAIN": "40",
    "LTE_APN": "internet", "LTE_TAC": "7",
}

def load_conf():
    c = dict(DEFAULTS)
    try:
        for line in open(CONF):
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            c[k.strip()] = v.strip().strip('"')
    except Exception:
        pass
    return c

def save_conf(c):
    try:
        os.makedirs(os.path.dirname(CONF), exist_ok=True)
        with open(CONF, "w") as f:
            f.write("# g90net - automatisch geschrieben\n")
            for k in sorted(c):
                f.write('%s="%s"\n' % (k, c[k]))
    except Exception as e:
        log("conf speichern:", e)

C = load_conf()
os.makedirs(WORKDIR, exist_ok=True)

def cset(k, v):
    C[k] = str(v)
    save_conf(C)

def log(*a):
    print(time.strftime("%H:%M:%S"), *a, flush=True)

FAKE = "--fake" in sys.argv   # Testmodus ohne echte Hardware/Prozesse

# ------------------------------------------------------------------ Frequenzen (Anzeige)
def arfcn_band(a):
    a = int(a)
    if 1 <= a <= 124:   return "GSM900"
    if 512 <= a <= 885: return "DCS1800"
    if 128 <= a <= 251: return "GSM850"
    if 975 <= a <= 1023:return "EGSM900"
    return "GSM900"

def arfcn_mhz(a):
    a = int(a)
    if 1 <= a <= 124:    return round(935 + 0.2 * a, 1)
    if 512 <= a <= 885:  return round(1805.2 + 0.2 * (a - 512), 1)
    if 128 <= a <= 251:  return round(869 + 0.2 * (a - 128), 1)
    return 0.0

def earfcn_mhz(e):
    e = int(e)
    # Band 3 (1800): DL 1805-1880, EARFCN 1200-1949
    if 1200 <= e <= 1949: return round(1805.0 + 0.1 * (e - 1200), 1)
    # Band 1 (2100): EARFCN 0-599
    if 0 <= e <= 599:     return round(2110.0 + 0.1 * e, 1)
    # Band 7 (2600): 2750-3449
    if 2750 <= e <= 3449: return round(2620.0 + 0.1 * (e - 2750), 1)
    # Band 20 (800): 6150-6449
    if 6150 <= e <= 6449: return round(791.0 + 0.1 * (e - 6150), 1)
    return 0.0

def earfcn_band(e):
    e = int(e)
    if 0 <= e <= 599:     return 1
    if 1200 <= e <= 1949: return 3
    if 2750 <= e <= 3449: return 7
    if 6150 <= e <= 6449: return 20
    return 3

# ------------------------------------------------------------------ VTY-Hilfen (Osmocom)
def vty(port, cmds, timeout=4):
    out = []
    try:
        s = socket.create_connection(("127.0.0.1", port), timeout=timeout)
        s.settimeout(timeout)
        time.sleep(0.2)
        try: out.append(s.recv(4096).decode(errors="replace"))
        except Exception: pass
        for cmd in cmds:
            s.sendall((cmd + "\r\n").encode()); time.sleep(0.3)
            try: out.append(s.recv(8192).decode(errors="replace"))
            except Exception: pass
        s.close()
    except Exception as e:
        return "VTY-Fehler: %s" % e
    return "".join(out)

HLR_VTY = 4258
MSC_VTY = 4254   # osmo-msc Telnet-VTY: SMS senden + eingebuchte Teilnehmer abfragen

def _sub(path, pairs):
    if not os.path.isfile(path): return
    t = open(path).read()
    for pat, rep in pairs:
        t = re.sub(pat, rep, t, flags=re.MULTILINE)
    open(path, "w").write(t)

def _vty_set(path, node, key, full):
    if not os.path.isfile(path): return
    t = open(path).read()
    if re.search(rf"(?m)^\s*{key}(\s|$)", t):
        t = re.sub(rf"(?m)^\s*{key}.*$", " " + full, t)
    else:
        t = re.sub(rf"(?m)^({re.escape(node)}\s*)$", r"\1\n " + full, t, count=1)
    open(path, "w").write(t)

def _vty_del(path, key):
    if not os.path.isfile(path): return
    t = open(path).read()
    open(path, "w").write(re.sub(rf"(?m)^\s*{key}.*\n?", "", t))

# ================================================================== LimeSDR frei machen
def _lime_service(action):
    if FAKE: return
    for svc in ("g90-lime", "g90lime"):
        try:
            subprocess.run(["systemctl", action, svc + ".service"],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
        except Exception: pass

def _free_lime():
    """Alles beenden, was den LimeSDR offen haelt. Die USB-Platine (FX3) NICHT hart
    reseten (faellt sonst vom Bus); bei der Mini (FT601) hilft ein USB-Reset."""
    if FAKE: return
    import fcntl
    for vid, pid, hard in (("0403", "601f", True), ("1d50", "6108", False)):
        try:
            out = subprocess.run(["lsusb", "-d", f"{vid}:{pid}"],
                                 capture_output=True, text=True, timeout=5).stdout
            m = re.search(r"Bus (\d+) Device (\d+)", out)
            if not m: continue
            path = f"/dev/bus/usb/{m.group(1)}/{m.group(2)}"
            try:
                subprocess.run(["fuser", "-k", path], stdout=subprocess.DEVNULL,
                               stderr=subprocess.DEVNULL, timeout=5); time.sleep(1.0)
            except Exception: pass
            if hard:
                with open(path, "wb") as f: fcntl.ioctl(f, 0x5514, 0)
        except Exception as e:
            log("lime frei:", e)

# ================================================================== LimeSDR-Auswahl
# Je Netz ein eigener LimeSDR (z.B. LimeSDR Mini fuer GSM, LimeSDR USB fuer LTE).
# Zuordnung ueber die Seriennummer (GSM_DEV / LTE_DEV), leer = automatisch.
LIMES = []          # zuletzt gefundene Geraete [{serial, name, media, ...}]

def lime_scan():
    """Angeschlossene LimeSDR finden (LimeUtil, sonst SoapySDRUtil)."""
    global LIMES
    if FAKE:
        LIMES = [{"serial": "1D3AC4F1A2B3C4", "name": "LimeSDR Mini", "media": "USB 3.0"},
                 {"serial": "0009070105C6262E", "name": "LimeSDR-USB", "media": "USB 3.0"}]
        return LIMES
    devs = []
    try:
        out = subprocess.run(["LimeUtil", "--find"], capture_output=True, text=True, timeout=20).stdout
        for m in re.finditer(r"\[([^\]]+)\]", out):
            parts = [p.strip() for p in m.group(1).split(",")]
            d = {"name": parts[0]}
            for p in parts[1:]:
                if "=" in p:
                    k, v = p.split("=", 1); d[k.strip()] = v.strip()
            if d.get("serial"): devs.append(d)
    except Exception as e:
        log("LimeUtil:", e)
    if not devs:
        try:
            out = subprocess.run(["SoapySDRUtil", "--find=driver=lime"],
                                 capture_output=True, text=True, timeout=30).stdout
            for blk in re.split(r"Found device \d+", out)[1:]:
                d = dict((k.strip(), v.strip()) for k, v in re.findall(r"(?m)^\s*(\w+)\s*=\s*(.+)$", blk))
                if d.get("serial"):
                    devs.append({"serial": d["serial"], "media": d.get("media", ""),
                                 "name": (d.get("label") or d.get("name") or "LimeSDR").split("[")[0].strip()})
        except Exception as e:
            log("SoapySDRUtil:", e)
    seen = set()
    LIMES = [d for d in devs if not (d["serial"] in seen or seen.add(d["serial"]))]
    log("LimeSDR gefunden:", ", ".join("%s %s" % (d["name"], d["serial"]) for d in LIMES) or "keine")
    return LIMES

def lime_assign(mode):
    """(gsm_serial, lte_serial) fuer den Modus. Leere Wahl = erstes Geraet, das
    nicht schon dem anderen Netz gehoert."""
    devs = LIMES or lime_scan()
    serials = [d["serial"] for d in devs]
    g = C.get("GSM_DEV", "").strip(); l = C.get("LTE_DEV", "").strip()
    first = lambda other: next((s for s in serials if s != other), "")
    if mode in ("gsm", "csfb") and not g: g = first(l)
    if mode in ("lte", "csfb") and not l: l = first(g)
    if mode == "gsm": l = ""
    if mode == "lte": g = ""
    return g, l

def lime_label(serial):
    for d in LIMES:
        if d["serial"] == serial:
            return "%s (%s)" % (d.get("name", "LimeSDR"), serial)
    return serial or "–"

# ================================================================== Osmocom-Faehigkeiten
_VTYREF = {}
def osmo_has(binary, word):
    """True/False, ob ein Osmocom-Programm einen VTY-Befehl kennt; None = unbekannt."""
    if binary not in _VTYREF:
        try:
            _VTYREF[binary] = subprocess.run([binary, "--vty-ref-xml"], capture_output=True,
                                             text=True, timeout=15).stdout
        except Exception:
            _VTYREF[binary] = ""
    ref = _VTYREF[binary]
    if "<vtydoc" not in ref: return None
    return re.search(r'id=["\']%s\b' % re.escape(word), ref) is not None

def tz_now():
    """Zeitzone fuer NITZ: (Stunden, Minuten, Sommerzeit 0/1) ohne DST-Anteil."""
    lt = time.localtime()
    dst = 1 if lt.tm_isdst > 0 else 0
    off = lt.tm_gmtoff // 60 - dst * 60
    h = int(off / 60); m = abs(off) % 60
    return h, min((0, 15, 30, 45), key=lambda x: abs(x - m)), dst

# ================================================================== GSM (Osmocom)
GSM_CORE = [
    ("stp", "osmo-stp", "osmo-stp.cfg"),
    ("hlr", "osmo-hlr", "osmo-hlr.cfg"),
    ("mgw", "osmo-mgw", "osmo-mgw.cfg"),
    ("msc", "osmo-msc", "osmo-msc.cfg"),
    ("bsc", "osmo-bsc", "osmo-bsc.cfg"),
    ("trx", "osmo-trx-lms", "osmo-trx-lms.cfg"),
    ("bts", "osmo-bts-trx", "osmo-bts-trx.cfg"),
]
GSM_DATA = [
    ("ggsn", "osmo-ggsn", "osmo-ggsn.cfg"),
    ("sgsn", "osmo-sgsn", "osmo-sgsn.cfg"),
    ("pcu",  "osmo-pcu",  "osmo-pcu.cfg"),
]
GSM_SIP = ("sip", "osmo-sip-connector", "osmo-sip-connector.cfg")
GSM_NONFATAL = {"ggsn", "sgsn", "pcu", "sip", "nrf", "scp", "pkom"}
OSMO_SERVICES = ["osmo-stp", "osmo-hlr", "osmo-mgw", "osmo-msc", "osmo-bsc",
                 "osmo-bts-trx", "osmo-trx-lms", "osmo-sip-connector",
                 "osmo-pcu", "osmo-sgsn", "osmo-ggsn"]

def gsm_components():
    comps = list(GSM_CORE)
    if C["GSM_DATA"] == "1": comps += GSM_DATA
    if C["GSM_SIP"] == "1" and C["GSM_SIP_PEER"]: comps += [GSM_SIP]
    return comps

def _tailscale_ip():
    try:
        out = subprocess.run(["tailscale", "ip", "-4"], capture_output=True, text=True, timeout=5).stdout
        for line in out.splitlines():
            ip = line.strip()
            if re.match(r"100\.\d+\.\d+\.\d+$", ip): return ip
    except Exception: pass
    return "0.0.0.0"

def _gprs_block(m):
    i = m.group(1)
    L = ["gprs mode egprs", "gprs routing area 0", "gprs network-control-order nc0",
         "gprs cell bvci 1234", "gprs nsei 1234", "gprs nsvc 0 nsvci 1234",
         "gprs nsvc 0 local udp port 23001", "gprs nsvc 0 remote udp port 23000",
         "gprs nsvc 0 remote ip 127.0.0.1"]
    return i + ("\n" + i).join(L)

def gsm_prepare():
    for _n, _b, cfg in gsm_components():
        src = os.path.join(OSMO_CFG, cfg)
        if os.path.isfile(src): shutil.copy(src, os.path.join(WORKDIR, cfg))
    arfcn, mcc, mnc = int(C["GSM_ARFCN"]), C["MCC"], C["MNC"]
    data_on = C["GSM_DATA"] == "1"; open_reg = C["GSM_OPEN"] == "1"
    bsc = os.path.join(WORKDIR, "osmo-bsc.cfg")
    rules = [
        (r"^(\s*network country code\s+)\d+", r"\g<1>" + mcc),
        (r"^(\s*mobile network code\s+)\d+", r"\g<1>" + mnc),
        (r"^(\s*band\s+)\S+", r"\g<1>" + arfcn_band(arfcn)),
        (r"^(\s*arfcn\s+)\d+", r"\g<1>" + str(arfcn)),
        (r"^(\s*max_power_red\s+)\d+", r"\g<1>0"),
    ]
    if not data_on:
        rules.append((r"^(\s*gprs mode\s+)\S+", r"\g<1>none"))
    _sub(bsc, rules)
    if data_on:
        t = open(bsc).read()
        t = re.sub(r"(?m)^\s*gprs (routing area|network-control-order|cell|nsei|nsvc)\b.*\n?", "", t)
        t = re.sub(r"(?m)^(\s*)gprs mode\s+\S+.*$", _gprs_block, t, count=1)
        for ts in ("5", "6", "7"):
            t = re.sub(rf"(?m)(^\s*timeslot {ts}\s*\n\s*phys_chan_config\s+)TCH/F\s*$", r"\g<1>TCH/F_PDCH", t)
        open(bsc, "w").write(t)
    # MSC: Kennung + Name
    _sub(os.path.join(WORKDIR, "osmo-msc.cfg"), [
        (r"^(\s*network country code\s+)\d+", r"\g<1>" + mcc),
        (r"^(\s*mobile network code\s+)\d+", r"\g<1>" + mnc),
    ])
    msc = os.path.join(WORKDIR, "osmo-msc.cfg"); hlr = os.path.join(WORKDIR, "osmo-hlr.cfg")
    _vty_del(msc, "authentication")
    # Netzname + NITZ: MM-Information mit Name, Uhrzeit und Zeitzone ans Handy
    word = lambda s: re.sub(r"[^\w.+-]", "-", s or "pKOM")      # VTY: ein Wort
    _vty_set(msc, "network", "short name", "short name " + word(C.get("NETNAME_SHORT") or C["NETNAME"]))
    _vty_set(msc, "network", "long name", "long name " + word(C["NETNAME"]))
    if C.get("NITZ", "1") == "1":
        _vty_set(msc, "network", "mm info", "mm info 1")
        if osmo_has("osmo-msc", "timezone"):
            _vty_set(msc, "network", "timezone", "timezone %d %d %d" % tz_now())
    else:
        _vty_set(msc, "network", "mm info", "mm info 0")
        _vty_del(msc, "timezone")
    # SGs zur Open5GS-MME (nur im Modus LTE + GSM)
    t = open(msc).read()
    t = re.sub(r"(?m)^sgs[ \t]*\n(?:[ \t]+.*(?:\n|$))*", "", t)
    if NET.tech == "csfb":
        t = t.rstrip("\n") + "\nsgs\n local-port %d\n local-ip 127.0.0.1\n vlr-name vlr.pkom.test\n" % SGS_PORT
    open(msc, "w").write(t)
    # eigener LimeSDR fuer GSM (osmo-trx-lms waehlt per Teilstring der Geraeteliste)
    trx = os.path.join(WORKDIR, "osmo-trx-lms.cfg")
    if os.path.isfile(trx):
        if NET.dev_gsm:
            _vty_set(trx, "trx", "dev-args", "dev-args serial=" + NET.dev_gsm)
        else:
            _vty_del(trx, "dev-args")
    if open_reg:
        _vty_set(hlr, "hlr", "subscriber-create-on-demand", "subscriber-create-on-demand no-msisdn cs+ps")
    else:
        _vty_del(hlr, "subscriber-create-on-demand")
    # RX-Gain (instance-Knoten der osmo-bts-trx.cfg)
    bts = os.path.join(WORKDIR, "osmo-bts-trx.cfg")
    if os.path.isfile(bts):
        bt = open(bts).read(); rg = int(C["GSM_RX_GAIN"])
        if re.search(r"(?m)^\s*osmotrx rx-gain\b", bt):
            bt = re.sub(r"(?m)^(\s*osmotrx rx-gain\s+).*$", r"\g<1>%d" % rg, bt)
        else:
            bt = re.sub(r"(?m)^(\s*instance 0\s*)$", r"\1\n  osmotrx rx-gain %d" % rg, bt, count=1)
        open(bts, "w").write(bt)
    # SIP-Trunk
    if C["GSM_SIP"] == "1" and C["GSM_SIP_PEER"]:
        _vty_set(msc, "msc", "mncc", "mncc external /tmp/mncc.sock")
        local = C.get("GSM_SIP_LOCAL") or _tailscale_ip()
        with open(os.path.join(WORKDIR, "osmo-sip-connector.cfg"), "w") as f:
            f.write("mncc\n socket-path /tmp/mncc.sock\nsip\n local %s 5060\n remote %s 5060\n"
                    % (local, C["GSM_SIP_PEER"]))
    else:
        _vty_set(msc, "msc", "mncc", "mncc internal")
    if data_on and open_reg:
        _vty_set(os.path.join(WORKDIR, "osmo-sgsn.cfg"), "sgsn", "auth-policy", "auth-policy accept-all")

# ---- SIMs: EINE Liste fuer beide Netze
# Eingetragen wird nur hier; pKOM schreibt jede SIM automatisch ins osmo-hlr (GSM)
# und in den Open5GS-HSS (LTE, MongoDB). Ki/OPc verlassen den Rechner nie
# (die Weboberflaeche bekommt nur IMSI + Rufnummer zurueck).
SIMS_FILE = os.path.join(WORKDIR, "sims.json")

def sims_load():
    try: return json.load(open(SIMS_FILE))
    except Exception: return {}

def sims_save(d):
    try:
        tmp = SIMS_FILE + ".tmp"
        with open(tmp, "w") as f: json.dump(d, f, indent=1)
        os.chmod(tmp, 0o600); os.replace(tmp, SIMS_FILE)
    except Exception as e:
        log("sims:", e)

def gsm_on():
    return NET.tech in ("gsm", "csfb")

def lte_on():
    return NET.tech in ("lte", "csfb")

def _hex32(x):
    return re.sub(r"[^0-9a-fA-F]", "", x or "").upper()

def hlr_put(imsi, s):
    if FAKE: return None
    r = vty(HLR_VTY, ["enable", f"subscriber imsi {imsi} create",
                      f"subscriber imsi {imsi} update msisdn {s.get('msisdn') or imsi[-8:]}",
                      f"subscriber imsi {imsi} update aud3g milenage k {s['ki']} opc {s['opc']}"])
    return None if "% " not in r.replace("% Subscriber already exists", "") else r.strip()[-160:]

def _hss():
    import pymongo
    return pymongo.MongoClient("mongodb://127.0.0.1/", serverSelectionTimeoutMS=3000)["open5gs"]["subscribers"]

def hss_put(imsi, s):
    """SIM in den Open5GS-HSS schreiben (anlegen oder aktualisieren, SQN bleibt)."""
    if FAKE: return None
    try:
        from bson.int64 import Int64
        ambr = {"downlink": {"value": 1, "unit": 3}, "uplink": {"value": 1, "unit": 3}}   # 1 Gbit/s
        sess = {"name": C.get("LTE_APN") or "internet", "type": 3,          # 3 = IPv4v6
                "qos": {"index": 9, "arp": {"priority_level": 8, "pre_emption_capability": 1,
                                            "pre_emption_vulnerability": 1}},
                "ambr": ambr, "pcc_rule": []}
        _hss().update_one({"imsi": imsi}, {
            "$set": {"imsi": imsi, "msisdn": [s["msisdn"]] if s.get("msisdn") else [],
                     "security.k": s["ki"], "security.opc": s["opc"], "security.op": None,
                     "security.amf": "8000", "ambr": ambr,
                     "slice": [{"sst": 1, "default_indicator": True, "session": [sess]}],
                     "access_restriction_data": 32, "subscriber_status": 0,
                     "operator_determined_barring": 0,
                     "network_access_mode": 0,        # 0 = Paket + Leitung -> kombinierter Attach (CSFB)
                     "subscribed_rau_tau_timer": 12},
            "$setOnInsert": {"security.sqn": Int64(97), "imeisv": [], "mme_host": [],
                             "mme_realm": [], "purge_flag": [], "__v": 0}}, upsert=True)
        return None
    except ImportError:
        return "python3-pymongo fehlt (Installer erneut ausfuehren)"
    except Exception as e:
        return "HSS/MongoDB: %s" % str(e)[:120]

def hss_del(imsi):
    if FAKE: return
    try: _hss().delete_one({"imsi": imsi})
    except Exception as e: log("hss loeschen:", e)

def hss_sync_all():
    errs = [e for e in (hss_put(i, s) for i, s in sims_load().items()) if e]
    return errs[0] if errs else None

def sim_add(imsi, ki, opc, msisdn):
    imsi = re.sub(r"\D", "", imsi or ""); ki = _hex32(ki); opc = _hex32(opc)
    if len(imsi) < 14 or len(ki) != 32 or len(opc) != 32:
        return "IMSI (15 Ziffern), Ki und OPc (je 32 Hex) pruefen"
    msisdn = re.sub(r"\D", "", msisdn or "") or nums_load().get(imsi) or imsi[-8:]
    d = sims_load(); d[imsi] = {"ki": ki, "opc": opc, "msisdn": msisdn}; sims_save(d)
    n = nums_load(); n[imsi] = msisdn; nums_save(n)          # Rufnummer dauerhaft
    errs = []
    e = hss_put(imsi, d[imsi])
    if e: errs.append(e)
    if gsm_on() and not FAKE:
        e = hlr_put(imsi, d[imsi])
        if e: errs.append("HLR: " + e)
        else: sms_send(imsi, _sms_text(C.get("GSM_SMS_NUMBER", ""), nummer=msisdn))
    return ("SIM gespeichert, aber: " + "; ".join(errs)) if errs else None

def sim_del(imsi):
    imsi = re.sub(r"\D", "", imsi or "")
    d = sims_load()
    if imsi in d:
        del d[imsi]; sims_save(d)
    hss_del(imsi)
    if gsm_on() and not FAKE:
        vty(HLR_VTY, ["enable", f"subscriber imsi {imsi} delete"])

def _migrate_lte_db():
    """Alte srsEPC-Liste (user_db.csv) einmalig in die gemeinsame SIM-Liste uebernehmen."""
    udb = os.path.join(WORKDIR, "user_db.csv")
    if not os.path.isfile(udb): return
    d = sims_load(); nums = nums_load(); n = 0
    for l in open(udb).read().splitlines():
        f = l.split(",")
        if len(f) >= 5 and not l.startswith("#") and f[0] not in d and len(_hex32(f[3])) == 32:
            d[f[0]] = {"ki": _hex32(f[3]), "opc": _hex32(f[4]), "msisdn": nums.get(f[0], "")}; n += 1
    if n: sims_save(d)
    try: os.replace(udb, udb + ".alt")
    except Exception: pass
    log(f"{n} SIM(s) aus der alten srsEPC-Liste uebernommen")

# Dauerhafte IMSI->Rufnummer-Zuweisungen (ueberleben Neustarts, werden bei jedem
# GSM-Start erneut ins HLR geschrieben - auch fuer offen angemeldete SIMs ohne Ki).
NUMS_FILE = os.path.join(WORKDIR, "numbers.json")

def nums_load():
    try: return json.load(open(NUMS_FILE))
    except Exception: return {}

def nums_save(d):
    try: json.dump(d, open(NUMS_FILE, "w"))
    except Exception as e: log("numbers:", e)

def gsm_apply_numbers():
    """Beim GSM-Start: alle SIMs (mit Schluessel) + Rufnummern ins HLR schreiben."""
    if FAKE: return
    for imsi, s in sims_load().items():
        e = hlr_put(imsi, s)
        if e: log("hlr:", imsi, e)
    d = nums_load()
    if not d: return
    cmds = ["enable"]
    for imsi, msisdn in d.items():
        cmds += [f"subscriber imsi {imsi} create", f"subscriber imsi {imsi} update msisdn {msisdn}"]
    vty(HLR_VTY, cmds)

def gsm_sim_nr(imsi, msisdn):
    imsi = re.sub(r"\D", "", imsi); msisdn = re.sub(r"\D", "", msisdn)
    if len(imsi) < 14 or not msisdn: return "IMSI (15 Ziffern) und Rufnummer pruefen"
    d = nums_load(); d[imsi] = msisdn; nums_save(d)        # dauerhaft merken
    s = sims_load()
    if imsi in s:                                           # SIM mit Schluessel: auch im HSS
        s[imsi]["msisdn"] = msisdn; sims_save(s); hss_put(imsi, s[imsi])
    if not FAKE and gsm_on():                               # sofort anwenden, wenn GSM laeuft
        vty(HLR_VTY, ["enable", f"subscriber imsi {imsi} create",
                      f"subscriber imsi {imsi} update msisdn {msisdn}"])
        sms_send(imsi, _sms_text(C.get("GSM_SMS_NUMBER", ""), nummer=msisdn))
    return None

def gsm_num_del(imsi):
    imsi = re.sub(r"\D", "", imsi); d = nums_load()
    if imsi in d:
        del d[imsi]; nums_save(d)
    if not FAKE and gsm_on():
        vty(HLR_VTY, ["enable", f"subscriber imsi {imsi} update msisdn "])

# ---- SIM-Daten erzeugen (fuer eigene eSIM-Profile, z.B. simlessly)
# IMSI = eigene Kennung (MCC+MNC) + zufaellige MSIN, Ki/OP zufaellig (secrets),
# OPc = AES_Ki(OP) xor OP (Milenage, TS 35.206), ICCID mit Luhn-Pruefziffer.
_SBOX = []
def _aes_tables():
    if _SBOX: return
    p = q = 1; sb = [0] * 256
    while True:                                    # S-Box ueber das Inverse in GF(2^8)
        p = p ^ ((p << 1) & 0xFF) ^ (0x1B if p & 0x80 else 0)
        q ^= q << 1; q ^= q << 2; q ^= q << 4; q &= 0xFF
        if q & 0x80: q ^= 0x09
        x = q ^ ((q << 1 | q >> 7) & 0xFF) ^ ((q << 2 | q >> 6) & 0xFF) \
              ^ ((q << 3 | q >> 5) & 0xFF) ^ ((q << 4 | q >> 4) & 0xFF)
        sb[p] = x ^ 0x63
        if p == 1: break
    sb[0] = 0x63
    _SBOX.extend(sb)

def _xt(a): return ((a << 1) ^ 0x1B) & 0xFF if a & 0x80 else a << 1

def aes128_encrypt(key, block):
    """AES-128, ein Block (reines Python, nur fuer die OPc-Berechnung)."""
    _aes_tables(); S = _SBOX
    w = [list(key[i:i + 4]) for i in range(0, 16, 4)]; rc = 1
    for i in range(4, 44):
        t = list(w[i - 1])
        if i % 4 == 0:
            t = [S[b] for b in t[1:] + t[:1]]; t[0] ^= rc; rc = _xt(rc)
        w.append([a ^ b for a, b in zip(w[i - 4], t)])
    s = [b ^ k for b, k in zip(block, sum(w[0:4], []))]
    for r in range(1, 11):
        s = [S[b] for b in s]
        s = [s[((c + i) % 4) * 4 + i] for c in range(4) for i in range(4)]     # ShiftRows
        if r < 10:
            m = []
            for c in range(4):
                a = s[c * 4:c * 4 + 4]; t = a[0] ^ a[1] ^ a[2] ^ a[3]
                m += [a[i] ^ t ^ _xt(a[i] ^ a[(i + 1) % 4]) for i in range(4)]
            s = m
        s = [b ^ k for b, k in zip(s, sum(w[r * 4:r * 4 + 4], []))]
    return bytes(s)

def milenage_opc(k_hex, op_hex):
    k, op = bytes.fromhex(k_hex), bytes.fromhex(op_hex)
    return bytes(a ^ b for a, b in zip(aes128_encrypt(k, op), op)).hex().upper()

def luhn(digits):
    tot = 0
    for i, ch in enumerate(reversed(digits)):
        d = int(ch)
        if i % 2 == 0:
            d *= 2
            if d > 9: d -= 9
        tot += d
    return str((10 - tot % 10) % 10)

def _rand_digits(n):
    return "".join(str(secrets.randbelow(10)) for _ in range(n))

def sim_generate(count=1, msisdn_start="", iccid_prefix=""):
    mcc, mnc = C.get("MCC", "001"), C.get("MNC", "01")
    count = max(1, min(50, int(count or 1)))
    used = set(sims_load()) | set(nums_load())
    taken_nr = set(nums_load().values()) | {s.get("msisdn", "") for s in sims_load().values()}
    nr = int(re.sub(r"\D", "", msisdn_start or "") or 0)
    pref = re.sub(r"\D", "", iccid_prefix or "") or ("89" + mcc + mnc)
    pref = pref[:16]
    out = []
    while len(out) < count:
        imsi = mcc + mnc + _rand_digits(15 - len(mcc) - len(mnc))
        if imsi in used: continue
        used.add(imsi)
        ki = secrets.token_hex(16).upper(); op = secrets.token_hex(16).upper()
        body = pref + _rand_digits(18 - len(pref))
        msisdn = ""
        if nr:
            while str(nr) in taken_nr: nr += 1
            msisdn = str(nr); taken_nr.add(msisdn); nr += 1
        out.append({"iccid": body + luhn(body), "imsi": imsi, "ki": ki, "op": op,
                    "opc": milenage_opc(ki, op), "amf": "8000", "sqn": "000000000020",
                    "msisdn": msisdn, "pin1": "0000", "puk1": _rand_digits(8),
                    "pin2": "0000", "puk2": _rand_digits(8), "adm1": _rand_digits(8),
                    "spn": C.get("SPN") or C.get("NETNAME", ""), "hplmn": mcc + mnc})
    return out

# ---- SIM-Dateien fuer das eSIM-Profil (OPL / PNN / SPN)
# Diese drei Dateien liegen auf der SIM, nicht im Netz. pKOM berechnet die Werte
# passend zu Kennung + Netzname; sie werden im eSIM-Profil eingetragen.
GSM7 = ("@£$¥èéùìòÇ\nØø\rÅåΔ_ΦΓΛΩΠΨΣΘΞ\x1bÆæßÉ !\"#¤%&'()*+,-./0123456789:;<=>?"
        "¡ABCDEFGHIJKLMNOPQRSTUVWXYZÄÖÑÜ§¿abcdefghijklmnopqrstuvwxyzäöñüà")

def gsm7_codes(s):
    return [GSM7.index(ch) if ch in GSM7 and ch not in "\n\r\x1b" else 0x3F for ch in (s or "")]

def gsm7_pack(codes):
    bits = n = 0; out = bytearray()
    for c in codes:
        bits |= (c & 0x7F) << n; n += 7
        while n >= 8:
            out.append(bits & 0xFF); bits >>= 8; n -= 8
    if n: out.append(bits & 0xFF)
    return bytes(out), (8 - (len(codes) * 7) % 8) % 8

def _nn_ie(tag, name):
    """Netzname-IE (TS 24.008 10.5.3.5a): GSM-7, ohne Laenderkuerzel."""
    packed, spare = gsm7_pack(gsm7_codes(name))
    body = bytes([0x80 | spare]) + packed
    return bytes([tag, len(body)]) + body

def plmn_bcd(mcc, mnc):
    m3 = mnc[2] if len(mnc) == 3 else "F"
    return bytes([int(mcc[1] + mcc[0], 16), int(m3 + mcc[2], 16), int(mnc[1] + mnc[0], 16)])

def sim_files():
    mcc, mnc = C.get("MCC", ""), C.get("MNC", "")
    full = C.get("NETNAME") or "pKOM"; short = C.get("NETNAME_SHORT") or full
    spn = (C.get("SPN") or full)[:16]
    try: plmn = plmn_bcd(mcc, mnc)
    except Exception: plmn = b"\xff\xff\xff"
    spn_b = bytes([0x00]) + bytes(gsm7_codes(spn)) + b"\xff" * (16 - len(spn))
    pnn = _nn_ie(0x43, full) + _nn_ie(0x45, short)
    opl = plmn + b"\x00\x00\xff\xfe\x01"          # LAC/TAC 0000-FFFE -> PNN-Eintrag 1
    hx = lambda b: b.hex().upper()
    return {"spn": hx(spn_b), "pnn": hx(pnn), "opl": hx(opl), "plmn": hx(plmn),
            "hplmn": mcc + mnc, "spn_text": spn, "full": full, "short": short}

# ---- SMS ueber osmo-msc VTY
# Die MSC puffert MT-SMS in ihrer DB und stellt sie beim Einbuchen zu - der
# Teilnehmer muss beim Senden also nicht zwingend schon angemeldet sein.
# Absender ist eine freie Nummer (GSM_SMS_FROM), kein echter Teilnehmer noetig.
def _extern_nr(nummer):
    """Interne Nummer -> extern erreichbare Nummer (Vorwahl-Block + interne Nummer)."""
    nummer = re.sub(r"\D", "", nummer or "")
    if not nummer: return ""
    pref = C.get("GSM_SMS_EXTPREFIX", "").strip()
    return (pref + nummer) if pref else nummer

def _sms_text(tmpl, nummer=""):
    t = (tmpl or "").replace("{netz}", C.get("NETNAME", "")) \
                    .replace("{extern}", _extern_nr(nummer)).replace("{nummer}", nummer)
    t = re.sub(r'[\r\n\t?"]', " ", t)          # VTY-Zeile: keine Umbrueche/Tabs/?-Hilfe/Quotes
    return re.sub(r"\s+", " ", t).strip()[:160]

def sms_send(imsi, text, force=False):
    imsi = re.sub(r"\D", "", imsi or "")
    if FAKE or not gsm_on() or not imsi or not text:
        return
    if C.get("GSM_SMS", "1") != "1" and not force:   # Auto-SMS aus (Test ignoriert das)
        return
    frm = re.sub(r"\D", "", C.get("GSM_SMS_FROM", "")) or "1000"
    r = vty(MSC_VTY, ["enable",
                      f"subscriber imsi {imsi} sms sender msisdn {frm} send {text}"])
    if "% " in r:
        log("sms-fehler:", (r.strip().splitlines() or [r])[-1][:140])

def sms_test(imsi, text=""):
    imsi = re.sub(r"\D", "", imsi or "")
    if len(imsi) < 14:  return "IMSI angeben (14-15 Ziffern)"
    if FAKE:            return "Testmodus (FAKE): nichts gesendet"
    if not gsm_on(): return "GSM-Netz laeuft nicht (GSM oder LTE + GSM starten)"
    txt = _sms_text(text) if (text or "").strip() else _sms_text(C.get("GSM_SMS_WELCOME", ""))
    sms_send(imsi, txt, force=True)
    return f"Test-SMS an {imsi} gesendet"

def msc_attached():
    """IMSIs, die aktuell in der MSC (VLR) eingebucht sind."""
    if FAKE or not gsm_on():
        return set()
    txt = vty(MSC_VTY, ["enable", "show subscriber cache"])
    return set(re.findall(r"IMSI\D{0,3}(\d{14,15})", txt))

def sms_welcome_watch():
    """Hintergrund: neue Einbuchungen erkennen und einmalig begruessen."""
    while True:
        try:
            if gsm_on() and NET.state == "laeuft" and C.get("GSM_SMS", "1") == "1":
                for imsi in msc_attached() - NET.welcomed:
                    NET.welcomed.add(imsi)      # vor dem Senden merken: kein Spam bei Fehler
                    log("willkommens-sms ->", imsi)
                    sms_send(imsi, _sms_text(C.get("GSM_SMS_WELCOME", "")))
        except Exception as e:
            log("sms-watch:", e)
        time.sleep(6)

# ================================================================== LTE: srsENB (Funk) + Open5GS (Kern)
# Open5GS statt srsEPC, weil nur dessen MME die SGs-Schnittstelle zur osmo-msc
# hat (CSFB). Die Open5GS-Dienste laufen nicht ueber systemd, sondern werden von
# pKOM mit eigenen Konfigs gestartet (Vorlage: /etc/open5gs/*.yaml).
O5_ETC = "/etc/open5gs"
O5_DIR = os.path.join(WORKDIR, "open5gs")
O5_NFS = [("nrf", "open5gs-nrfd"), ("scp", "open5gs-scpd"), ("hss", "open5gs-hssd"),
          ("pcrf", "open5gs-pcrfd"), ("sgwc", "open5gs-sgwcd"), ("sgwu", "open5gs-sgwud"),
          ("smf", "open5gs-smfd"), ("upf", "open5gs-upfd"), ("mme", "open5gs-mmed")]
O5_OPTIONAL = {"nrf", "scp"}
UE_NET, UE_GW = "10.45.0.0/16", "10.45.0.1/16"       # Open5GS-Standard (smf/upf.yaml)
NPRB_MHZ = {6: 1.4, 15: 3, 25: 5, 50: 10, 75: 15, 100: 20}
SGS_PORT = 29118

def _plmn_walk(o, mcc, mnc):
    """Jede PLMN-Angabe (mcc/mnc) in einer Open5GS-Konfig auf die eigene Kennung setzen."""
    if isinstance(o, dict):
        if "mcc" in o and "mnc" in o:
            o["mcc"] = mcc; o["mnc"] = mnc      # als Text: fuehrende Nullen + MNC-Laenge bleiben
        for v in o.values(): _plmn_walk(v, mcc, mnc)
    elif isinstance(o, list):
        for v in o: _plmn_walk(v, mcc, mnc)

def gsm_lac():
    try:
        t = open(os.path.join(WORKDIR, "osmo-bsc.cfg")).read()
        m = re.search(r"(?m)^\s*location_area_code\s+(?:lac\s+)?(0x[0-9a-fA-F]+|\d+)", t)
        if m: return int(m.group(1), 0)
    except Exception: pass
    return 1

def o5_prepare(csfb, etc=O5_ETC, outdir=O5_DIR):
    """Open5GS-Konfigs erzeugen. Rueckgabe: {nf: (binary, yaml-pfad)} in Startreihenfolge."""
    import yaml
    os.makedirs(outdir, exist_ok=True)
    mcc, mnc = C["MCC"], C["MNC"]; tac = int(C.get("LTE_TAC") or 7)
    plmn = {"mcc": mcc, "mnc": mnc}
    out = {}
    for nf, binary in O5_NFS:
        src = os.path.join(etc, nf + ".yaml")
        if not os.path.isfile(src):
            if nf in O5_OPTIONAL: continue
            raise RuntimeError(f"{src} fehlt - ist Open5GS installiert?")
        o = yaml.safe_load(open(src)) or {}
        o.pop("logger", None)                       # Log nach stdout -> Protokoll-Tab
        _plmn_walk(o, mcc, mnc)
        if nf == "mme":
            m = o.setdefault("mme", {})
            if C.get("NITZ", "1") == "1":           # EMM-Information: Netzname + Zeit/Zeitzone
                m["network_name"] = {"full": C["NETNAME"], "short": C.get("NETNAME_SHORT") or C["NETNAME"]}
            else:
                m.pop("network_name", None)
            tai = m.get("tai")
            tais = tai if isinstance(tai, list) else ([tai] if isinstance(tai, dict) else [])
            for t in tais: t["tac"] = tac
            if not tais: m["tai"] = [{"plmn_id": dict(plmn), "tac": tac}]
            new_fmt = isinstance(m.get("s1ap"), dict)   # Open5GS >= 2.7
            o.pop("sgsap", None); m.pop("sgsap", None)
            if csfb:
                mp = {"tai": {"plmn_id": dict(plmn), "tac": tac},
                      "lai": {"plmn_id": dict(plmn), "lac": gsm_lac()}}
                if new_fmt:
                    m["sgsap"] = {"client": [{"address": "127.0.0.1", "local_address": "127.0.0.2",
                                              "port": SGS_PORT, "map": mp}]}
                else:
                    o["sgsap"] = [{"addr": "127.0.0.1", "port": SGS_PORT, "map": mp}]
        dst = os.path.join(outdir, nf + ".yaml")
        with open(dst, "w") as f:
            yaml.safe_dump(o, f, default_flow_style=False, sort_keys=False, allow_unicode=True)
        out[nf] = (binary, dst)
    return out

SRS_MARK = {"sib.conf": r"(?m)^sib1\s*=", "rr.conf": r"(?m)^cell_list\s*=", "rb.conf": r"(?m)^\w+\s*="}

def _srs_template(name):
    """Vorlage suchen - nur Dateien, die wirklich den erwarteten Inhalt haben
    (eine leere/falsche /etc/srsran/sib.conf fuehrte zu 'section sib1 not found')."""
    cands = (os.path.join(SRS_CFG, name), f"/usr/local/share/srsran/{name}.example",
             f"/usr/share/srsran/{name}.example", f"/usr/share/srsran/{name}",
             f"/usr/share/doc/srsran/examples/{name}.example")
    for p in cands:
        try: t = open(p, encoding="utf-8", errors="replace").read()
        except OSError: continue
        if re.search(SRS_MARK.get(name, r"\S"), t): return p
        log(f"srsRAN-Vorlage {p} unbrauchbar - uebersprungen")
    return None

def _drop_block(t, name):
    """libconfig-Block 'name = { ... };' entfernen (Klammern gezaehlt)."""
    m = re.search(rf"(?m)^{name}\s*=\s*\{{", t)
    if not m: return t
    i = t.index("{", m.start()); depth = 0
    for j in range(i, len(t)):
        if t[j] == "{": depth += 1
        elif t[j] == "}":
            depth -= 1
            if depth == 0:
                k = j + 1
                while k < len(t) and t[k] in " \t;": k += 1
                return t[:m.start()] + t[k:]
    return t

def _si_mapping(t, add7):
    def f(m):
        nums = [x.strip() for x in m.group(2).split(",") if x.strip() and x.strip() != "7"]
        if add7: nums.append("7")
        return m.group(1) + ", ".join(nums) + m.group(3)
    return re.sub(r"(si_mapping_info\s*=\s*\[\s*)([^\]]*?)(\s*\])", f, t, count=1)

def sib_patch(t, csfb, arfcn):
    """SIB7 (GERAN-Nachbar) nur im CSFB-Modus: srsENB schickt das Handy bei
    einem Anruf per RRC-Release mit Umleitung auf genau diese GSM-Frequenz."""
    t = _drop_block(t, "sib7")
    t = _si_mapping(t, csfb)
    if csfb:
        t = t.rstrip() + f"""

// pKOM: GSM-Zelle fuer CS-Fallback (Anrufe)
sib7 =
{{
    t_resel_geran = 1;
    carrier_freqs_info_list =
    (
        {{
            cell_resel_prio = 0;
            ncc_permitted = 255;
            q_rx_lev_min = 0;
            thresh_x_high = 2;
            thresh_x_low = 2;
            start_arfcn = {arfcn};
            band_ind = "dcs1800";
            explicit_list_of_arfcns = ( {arfcn} );
        }}
    );
}};
"""
    return t

def enb_prepare(csfb, serial):
    for f in ("rr.conf", "sib.conf", "rb.conf"):
        p = _srs_template(f)
        if not p: raise RuntimeError(f"srsRAN-Vorlage {f} fehlt - ist srsran installiert?")
        shutil.copy(p, os.path.join(WORKDIR, f))
    earfcn = int(C["LTE_EARFCN"]); tac = int(C.get("LTE_TAC") or 7)
    rr = os.path.join(WORKDIR, "rr.conf"); t = open(rr).read()
    t = re.sub(r"(?m)^(\s*tac\s*=\s*)[^;]+;", r"\g<1>0x%04X;" % tac, t, count=1)
    t = re.sub(r"(?m)^(\s*dl_earfcn\s*=\s*)\d+;", r"\g<1>%d;" % earfcn, t, count=1)  # 1. = eigene Zelle
    open(rr, "w").write(t)
    sib = os.path.join(WORKDIR, "sib.conf")
    with open(sib) as f: t = f.read()          # erst lesen - open(...,"w") leert die Datei sofort
    with open(sib, "w") as f: f.write(sib_patch(t, csfb, int(C["GSM_ARFCN"])))
    dev = "driver=lime" + (",serial=" + serial if serial else "")
    open(os.path.join(WORKDIR, "enb.conf"), "w").write(f"""# pKOM - automatisch erzeugt
[enb]
enb_id = 0x19B
mcc = {C['MCC']}
mnc = {C['MNC']}
mme_addr = 127.0.0.2
gtp_bind_addr = 127.0.1.1
s1c_bind_addr = 127.0.1.1
s1c_bind_port = 0
n_prb = {int(C['LTE_NPRB'])}

[enb_files]
sib_config = {sib}
rr_config = {rr}
rb_config = {os.path.join(WORKDIR, 'rb.conf')}

[rf]
tx_gain = {C['LTE_TX_GAIN']}
rx_gain = {C['LTE_RX_GAIN']}
device_name = soapy
device_args = {dev}

[log]
all_level = warning
filename = stdout
""")

def _run(*cmd):
    return subprocess.run(list(cmd), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode

def ue_net_up():
    """Tunnel fuer die Handy-Datenverbindungen + NAT ins Internet."""
    _run("modprobe", "sctp")
    _run("ip", "tuntap", "add", "name", "ogstun", "mode", "tun")
    _run("ip", "addr", "replace", UE_GW, "dev", "ogstun")
    _run("ip", "link", "set", "ogstun", "up")
    _run("sysctl", "-w", "net.ipv4.ip_forward=1")
    for chk, add in ((["-t", "nat", "-C", "POSTROUTING", "-s", UE_NET, "!", "-o", "ogstun", "-j", "MASQUERADE"],
                      ["-t", "nat", "-A", "POSTROUTING", "-s", UE_NET, "!", "-o", "ogstun", "-j", "MASQUERADE"]),
                     (["-C", "FORWARD", "-i", "ogstun", "-j", "ACCEPT"], ["-I", "FORWARD", "-i", "ogstun", "-j", "ACCEPT"]),
                     (["-C", "FORWARD", "-o", "ogstun", "-j", "ACCEPT"], ["-I", "FORWARD", "-o", "ogstun", "-j", "ACCEPT"])):
        if _run("iptables", *chk) != 0: _run("iptables", *add)

def freq_clash():
    """GSM-Traeger darf nicht im LTE-Kanal liegen (gleiches Band 1800 MHz)."""
    try:
        g = arfcn_mhz(int(C["GSM_ARFCN"])); l = earfcn_mhz(int(C["LTE_EARFCN"]))
        bw = NPRB_MHZ.get(int(C["LTE_NPRB"]), 5)
        if g and l and abs(g - l) < bw / 2 + 0.3:
            return f"GSM {g} MHz liegt im LTE-Kanal {l} MHz ±{bw/2:g} - andere ARFCN/EARFCN waehlen"
    except Exception: pass
    return None

def preflight(mode):
    mcc, mnc = C.get("MCC", "").strip(), C.get("MNC", "").strip()
    if not re.fullmatch(r"\d{3}", mcc) or not re.fullmatch(r"\d{2,3}", mnc):
        return "Netzkennung pruefen: MCC 3 Ziffern, MNC 2-3 Ziffern"
    if mcc not in ("001", "999"):
        return "Nur Test-/Privatkennungen: MCC 001 (Test) oder 999 (privat)"
    g, l = lime_assign(mode)
    if mode == "csfb":
        if not FAKE and (not g or not l or g == l):
            return "LTE + GSM braucht zwei verschiedene LimeSDR - im Tab Steuerung zuordnen"
        e = freq_clash()
        if e: return e
    if not FAKE:
        need = []
        if mode in ("gsm", "csfb"): need += [b for _n, b, _c in GSM_CORE]
        if mode in ("lte", "csfb"):
            need += ["srsenb"] + [b for nf, b in O5_NFS if nf not in O5_OPTIONAL]
            try: import yaml  # noqa
            except ImportError: return "python3-yaml fehlt (Installer erneut ausfuehren)"
        miss = [b for b in need if not shutil.which(b)]
        if miss: return "Fehlt: " + ", ".join(miss) + " (Installer erneut ausfuehren)"
        if mode == "csfb" and osmo_has("osmo-msc", "sgs") is False:
            return "Diese osmo-msc kann kein SGs (CSFB) - neuere Osmocom-Version noetig"
    NET.dev_gsm, NET.dev_lte = g, l
    return None

# ================================================================== Netz-Manager
MODES = {"gsm": "GSM (2G)", "lte": "LTE (4G)", "csfb": "LTE + GSM (CSFB)"}

class Net:
    def __init__(self):
        self.lock = threading.RLock()
        self.tech = None          # None | "gsm" | "lte" | "csfb"
        self.state = "aus"        # aus | startet | laeuft | fehler
        self.msg = ""
        self.procs = {}
        self.loglines = []
        self.started = 0.0
        self.welcomed = set()     # IMSIs, die in dieser Netz-Session schon begruesst wurden
        self.dev_gsm = self.dev_lte = ""

    def _log(self, tag, line):
        line = line.rstrip()
        if not line: return
        print(f"{tag}: {line}", flush=True)   # -> journald, damit 'journalctl -u g90net' alles zeigt
        self.loglines.append(f"{tag}: {line}")
        if len(self.loglines) > 600: self.loglines = self.loglines[-600:]
        low = line.lower()
        if ("fatal" in low or "failed to create radio" in low) and tag not in GSM_NONFATAL:
            self.msg = f"{tag}: {line[:120]}"

    def _reader(self, p, tag):
        try:
            for raw in iter(p.stdout.readline, ""):
                self._log(tag, raw)
        except Exception:
            pass
        rc = p.poll()
        if self.procs.get(tag) is p and self.state == "laeuft" and tag not in GSM_NONFATAL:
            self.msg = f"{tag} beendet (Code {rc}) - siehe Protokoll"

    def _spawn(self, binary, args, tag):
        p = subprocess.Popen([binary] + args, stdout=subprocess.PIPE,
                             stderr=subprocess.STDOUT, text=True, bufsize=1)
        self.procs[tag] = p
        threading.Thread(target=self._reader, args=(p, tag), daemon=True).start()
        return p

    def stop(self):
        with self.lock:
            if FAKE:
                self.tech = None; self.state = "aus"; self.procs = {}; return
            procs, self.procs = self.procs, {}
            for tag, p in list(procs.items()):
                try: p.terminate()
                except Exception: pass
            time.sleep(1)
            for name in OSMO_SERVICES + ["srsenb", "srsepc", "open5gs-"]:
                try: subprocess.run(["pkill", "-9", "-f", name],
                                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                except Exception: pass
            if self.tech:
                _lime_service("start")   # G90-Empfang wieder frei geben
            self.tech = None; self.state = "aus"; self.msg = "gestoppt"

    def start(self, mode):
        if mode not in MODES: return "unbekannter Modus"
        with self.lock:
            self.stop(); self.tech = mode; self.state = "startet"; self.msg = ""
            self.loglines = []; self.started = time.time(); self.welcomed = set()
        err = preflight(mode)
        if err:
            with self.lock: self.tech = None; self.state = "fehler"; self.msg = err
            return err
        if FAKE:
            with self.lock: self.state = "laeuft"; self.msg = MODES[mode] + " laeuft (FAKE)"
            return None
        gsm, lte = mode in ("gsm", "csfb"), mode in ("lte", "csfb")
        try:
            if gsm:
                self._services_off(OSMO_SERVICES)
                gsm_prepare()
            if lte:
                self._services_off([b for _nf, b in O5_NFS])
                nfs = o5_prepare(mode == "csfb")
                enb_prepare(mode == "csfb", self.dev_lte)
                _run("systemctl", "start", "mongod")
                e = hss_sync_all()
                if e: self._log("pkom", "HSS: " + e)
            if self.dev_gsm: self._log("pkom", "GSM-Funk: " + lime_label(self.dev_gsm))
            if self.dev_lte: self._log("pkom", "LTE-Funk: " + lime_label(self.dev_lte))
            _lime_service("stop"); time.sleep(1); _free_lime(); time.sleep(2)
            if gsm:
                for name, binary, cfg in gsm_components():
                    flag = "-C" if binary.startswith("osmo-trx") else "-c"
                    self._spawn(binary, [flag, os.path.join(WORKDIR, cfg)], name)
                    time.sleep(4 if name in ("trx",) else 1.2)
                time.sleep(1); gsm_apply_numbers()   # SIMs + dauerhafte Rufnummern ins HLR
            if lte:
                ue_net_up()
                for nf, (binary, path) in nfs.items():
                    self._spawn(binary, ["-c", path], nf)
                    time.sleep(1.5 if nf == "mme" else 0.8)
                time.sleep(2)
                self._spawn("srsenb", [os.path.join(WORKDIR, "enb.conf")], "enb")
            with self.lock: self.state = "laeuft"; self.msg = MODES[mode] + " gestartet"
        except Exception as e:
            with self.lock: self.state = "fehler"; self.msg = str(e)[:200]
            return str(e)
        return None

    # Kompatibilitaet
    def start_gsm(self): return self.start("gsm")
    def start_lte(self): return self.start("lte")

    def _services_off(self, names):
        for s in names:
            try: subprocess.run(["systemctl", "stop", s.replace("open5gs-", "open5gs-") + ".service"],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=8)
            except Exception: pass

    def status(self):
        with self.lock:
            st = {
                "tech": self.tech, "mode": MODES.get(self.tech or "", ""),
                "state": self.state, "msg": self.msg,
                "uptime": int(time.time() - self.started) if self.started and self.state == "laeuft" else 0,
                "log": self.loglines[-80:],
                "conf": dict(C),
                "limes": LIMES,
                "dev": {"gsm": lime_label(self.dev_gsm) if self.dev_gsm else "",
                        "lte": lime_label(self.dev_lte) if self.dev_lte else ""},
                "gsm": {
                    "arfcn": int(C["GSM_ARFCN"]), "band": arfcn_band(int(C["GSM_ARFCN"])),
                    "mhz": arfcn_mhz(int(C["GSM_ARFCN"])),
                    "attached": sorted(msc_attached()) if self.state == "laeuft" else [],
                    "numbers": nums_load(),
                },
                "lte": {
                    "earfcn": int(C["LTE_EARFCN"]), "band": earfcn_band(int(C["LTE_EARFCN"])),
                    "mhz": earfcn_mhz(int(C["LTE_EARFCN"])),
                },
                "sims": [{"imsi": i, "msisdn": s.get("msisdn", "")} for i, s in sorted(sims_load().items())],
                "simfiles": sim_files(),
                "tz": "UTC%+d:%02d%s" % (tz_now()[0], tz_now()[1], " +Sommerzeit" if tz_now()[2] else ""),
                "clash": freq_clash(),
                "fake": FAKE,
            }
        return st

NET = Net()

# ================================================================== Web-API
def handle_api(path, body):
    try:
        req = json.loads(body or "{}")
    except Exception:
        req = {}
    cmd = path.rsplit("/", 1)[-1]
    if cmd == "status":
        return NET.status()
    if cmd in ("start_gsm", "start_lte", "start_csfb"):
        NET.start(cmd[6:])
    elif cmd == "stop":
        NET.stop()
    elif cmd == "lime_scan":
        n = len(lime_scan()); NET.msg = f"{n} LimeSDR gefunden"
    elif cmd == "set":
        # beliebige Konfig-Keys setzen (validiert light)
        for k, v in req.items():
            if k in DEFAULTS or k in C:
                v = str(v).replace('"', "").replace("\n", " ").strip()
                if k in ("MCC", "MNC", "LTE_TAC"): v = re.sub(r"\D", "", v)
                cset(k, v)
        NET.msg = "gespeichert - wirkt beim naechsten Start"
        if C.get("GSM_DEV") and C.get("GSM_DEV") == C.get("LTE_DEV"):
            NET.msg = "Achtung: GSM und LTE nutzen denselben LimeSDR - fuer LTE + GSM zwei Geraete waehlen"
    elif cmd in ("sim_add", "gsm_sim_add", "lte_sim_add"):
        NET.msg = sim_add(req.get("imsi",""), req.get("ki",""), req.get("opc",""), req.get("msisdn","")) \
                  or "SIM gespeichert (GSM + LTE)"
    elif cmd in ("sim_del", "gsm_sim_del", "lte_sim_del"):
        sim_del(req.get("imsi","")); NET.msg = "SIM geloescht"
    elif cmd == "gsm_sim_nr":
        NET.msg = gsm_sim_nr(req.get("imsi",""), req.get("msisdn","")) or "Rufnummer dauerhaft zugewiesen"
    elif cmd == "gsm_num_del":
        gsm_num_del(req.get("imsi","")); NET.msg = "Rufnummer-Zuweisung geloescht"
    elif cmd == "sim_gen":
        try:
            gen = sim_generate(req.get("count", 1), req.get("msisdn", ""), req.get("iccid", ""))
            NET.msg = f"{len(gen)} SIM-Datensatz/-saetze erzeugt"
        except Exception as e:
            gen = []; NET.msg = "Erzeugen fehlgeschlagen: %s" % e
        st = NET.status(); st["generated"] = gen
        return st
    elif cmd == "sms_test":
        NET.msg = sms_test(req.get("imsi",""), req.get("text",""))
    else:
        NET.msg = "unbekannt"
    return NET.status()

# ================================================================== Web-Oberflaeche (HTML)
PAGE = r"""<!doctype html><html lang=de><head><meta charset=utf-8>
<meta name=viewport content="width=device-width,initial-scale=1">
<meta name=theme-color content="#0A2463">
<link rel=icon href="data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAxMDI0IDEwMjQiPjxyZWN0IHdpZHRoPSIxMDI0IiBoZWlnaHQ9IjEwMjQiIGZpbGw9IiMwQTI0NjMiPjwvcmVjdD4KPGcgdHJhbnNmb3JtPSJ0cmFuc2xhdGUoMTI3LjYgMzQ3LjApIHNjYWxlKDEuNjUpIiBmaWxsPSJub25lIiBzdHJva2UtbGluZWNhcD0icm91bmQiIHN0cm9rZS1saW5lam9pbj0icm91bmQiIHN0cm9rZS13aWR0aD0iMzIiPgo8ZyBzdHJva2U9IiNGRkZGRkYiPgo8cGF0aCBkPSJNMjAgODAgVjI2NiI+PC9wYXRoPgo8Y2lyY2xlIGN4PSI3MiIgY3k9IjEzMyIgcj0iNTIiPjwvY2lyY2xlPgo8L2c+CjxnIHN0cm9rZT0iI0ZGRkZGRiI+CjxwYXRoIGQ9Ik0xNzggMTYgUTIwNiAxMDAgMTc4IDE4NCI+PC9wYXRoPgo8cGF0aCBkPSJNMTkyIDEwMCBDMjI2IDk2IDI1MCA2MiAyNjYgMTYiPjwvcGF0aD4KPC9nPgo8cGF0aCBzdHJva2U9IiMyRUM0RjEiIGQ9Ik0xOTIgMTAwIEMyMzMgMTAyIDI1NiAxODMgMzYzIDE4MyBBODMgODMgMCAwIDAgMzYzIDE3IEE4MyA4MyAwIDAgMCAyODIgMTE4Ij48L3BhdGg+CjwvZz48L3N2Zz4=">
<title>pKOM · Netzsteuerung</title>
<style>
:root{--navy:#0A2463;--bg:#060f22;--bg2:#0a1734;--card:#0c1a3b;--card2:#102250;--line:#1b2f5e;--line2:#2a4288;
--fg:#eaf1fb;--mut:#8ea4ca;--mut2:#5d7398;--acc:#2EC4F1;--acc2:#0096D6;--ok:#2EC4F1;--okbg:#07243b;--err:#ff5d6c;
--r:0;--r2:0;--mono:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace}
*{box-sizing:border-box}html,body{margin:0}
body{background:linear-gradient(180deg,#081330,#05101f);color:var(--fg);
font:15px/1.55 system-ui,-apple-system,Segoe UI,Roboto,sans-serif;min-height:100vh}
header{position:sticky;top:0;z-index:20;background:var(--navy);border-top:2px solid var(--acc);
border-bottom:1px solid var(--line2);padding:12px 20px;display:flex;align-items:center;gap:16px;flex-wrap:wrap}
.brand{display:flex;align-items:center;gap:12px}
.brand svg{height:30px;width:auto;display:block}
.brand .prod{font-size:11px;font-weight:700;letter-spacing:.18em;text-transform:uppercase;color:#9fb6de;padding-left:12px;border-left:1px solid #27407e}
.chip{display:flex;align-items:center;gap:8px;padding:6px 12px;border:1px solid var(--line2);background:#0b1733;font-size:12px;font-weight:700;letter-spacing:.06em;text-transform:uppercase}
.dot{width:8px;height:8px;background:var(--mut)}
.dot.on{background:var(--acc);animation:pulse 2s infinite}.dot.err{background:var(--err)}
@keyframes pulse{0%{box-shadow:0 0 0 0 rgba(46,196,241,.5)}70%{box-shadow:0 0 0 7px rgba(46,196,241,0)}100%{box-shadow:0 0 0 0 rgba(46,196,241,0)}}
.hstat{display:flex;gap:18px;flex-wrap:wrap;color:var(--mut);font-size:12px;margin-left:auto;align-items:center;text-transform:uppercase;letter-spacing:.05em}
.hstat b{color:var(--fg);font-family:var(--mono);letter-spacing:0;text-transform:none}
#msg{color:var(--acc);font-size:12px;text-transform:none;letter-spacing:0}
.badge{font-size:10px;padding:3px 9px;border:1px solid var(--acc);color:var(--acc);font-weight:700;letter-spacing:.12em}
.wrap{max-width:1060px;margin:0 auto;padding:22px 16px 44px}
.banner{display:flex;gap:11px;align-items:flex-start;background:#0c1a3b;border:1px solid var(--line2);
border-left:3px solid #f1b24a;color:#f2d79f;padding:12px 15px;font-size:13px;margin-bottom:18px}
.controls{display:grid;grid-template-columns:1fr 1fr 1fr auto;gap:10px;margin-bottom:20px}
@media(max-width:820px){.controls{grid-template-columns:1fr 1fr}}@media(max-width:480px){.controls{grid-template-columns:1fr}}
.bigbtn{border:1px solid var(--line2);background:#0b1836;color:var(--fg);
padding:15px 18px;font:inherit;font-weight:600;cursor:pointer;display:flex;align-items:center;gap:12px;transition:.15s}
.bigbtn:hover{border-color:var(--acc);background:#0e1f47}.bigbtn .ic{font-size:16px;color:var(--acc)}
.bigbtn small{display:block;color:var(--mut);font-weight:400;font-size:11px;text-transform:uppercase;letter-spacing:.07em;margin-top:2px}
.bigbtn.active{border-color:var(--acc);background:var(--okbg);box-shadow:inset 3px 0 0 var(--acc)}.bigbtn.active .ic{color:var(--acc)}
.bigbtn.stop{background:#1e1016;border-color:#53232e;color:#ffb0b8;justify-content:center;font-weight:700;letter-spacing:.05em;text-transform:uppercase;font-size:14px}.bigbtn.stop:hover{border-color:var(--err)}
.tabs{display:flex;gap:4px;border-bottom:1px solid var(--line2);margin-bottom:20px;overflow-x:auto}
.tab{padding:10px 16px;border:0;background:0;color:var(--mut);font:inherit;font-weight:700;font-size:12px;letter-spacing:.09em;text-transform:uppercase;cursor:pointer;border-bottom:2px solid transparent;white-space:nowrap;margin-bottom:-1px}
.tab:hover{color:var(--fg)}.tab.sel{color:var(--acc);border-bottom-color:var(--acc)}
.panel{display:none}.panel.sel{display:block}
.grid{display:grid;gap:16px;grid-template-columns:1fr 1fr}@media(max-width:760px){.grid{grid-template-columns:1fr}}
.card{background:var(--card);border:1px solid var(--line);padding:18px}
.card h2{font-size:12px;margin:0;display:flex;align-items:center;gap:9px;text-transform:uppercase;letter-spacing:.1em;color:#c6d6f1;font-weight:700}
.card h2:before{content:"";width:9px;height:9px;background:var(--acc);flex:none}
.card .sub{color:var(--mut);font-size:12px;margin:8px 0 14px}
label{display:block;font-size:11px;color:var(--mut);margin:13px 0 5px;font-weight:700;text-transform:uppercase;letter-spacing:.07em}
input,select{width:100%;background:#07142f;border:1px solid var(--line2);color:var(--fg);padding:10px 12px;font:inherit;outline:0;transition:.12s}
input:focus,select:focus{border-color:var(--acc);box-shadow:0 0 0 2px rgba(46,196,241,.18)}
.row{display:grid;grid-template-columns:1fr 1fr;gap:10px}.row3{display:grid;grid-template-columns:1fr 1fr 1fr;gap:10px}
.btn{background:var(--acc);color:var(--navy);border:0;padding:10px 18px;font:inherit;font-weight:700;letter-spacing:.05em;text-transform:uppercase;font-size:13px;cursor:pointer;margin-top:16px;transition:.12s}
.btn:hover{background:#5ad2f6}.btn.sec{background:transparent;border:1px solid var(--line2);color:var(--acc)}.btn.sec:hover{border-color:var(--acc);background:#0b1b40}
.btn.sm{padding:8px 13px;margin-top:4px;font-size:12px}
.sw{display:flex;align-items:center;justify-content:space-between;gap:10px;padding:13px 0;border-top:1px solid var(--line)}
.sw.first{border-top:0}.sw .t{font-size:14px}.sw .t small{display:block;color:var(--mut);font-size:12px}
.switch{position:relative;width:46px;height:24px;flex:none}.switch input{opacity:0;width:0;height:0}
.slider{position:absolute;inset:0;background:#0b1a3d;border:1px solid var(--line2);transition:.2s;cursor:pointer}
.slider:before{content:"";position:absolute;height:16px;width:16px;left:3px;top:3px;background:var(--mut);transition:.2s}
.switch input:checked+.slider{background:var(--okbg);border-color:var(--acc)}.switch input:checked+.slider:before{transform:translateX(22px);background:var(--acc)}
.hint{font-size:12px;color:var(--mut);margin-top:10px;line-height:1.5}
.freqbox{background:#07142f;border:1px solid var(--line2);padding:13px 16px;display:flex;justify-content:space-between;align-items:center}
.freqbox .big{font-size:22px;font-weight:700;line-height:1.15;font-family:var(--mono);color:var(--acc)}.freqbox .sm{color:var(--mut);font-size:12px;text-transform:uppercase;letter-spacing:.06em}
.listrow{display:flex;justify-content:space-between;align-items:center;border-top:1px solid var(--line);padding:9px 0;font-size:14px}
.listrow:first-child{border-top:0}.tag{font-family:var(--mono);font-size:13px;color:#cad9f3}
.x{background:#1e1016;border:1px solid #53232e;color:#ff9ba6;padding:4px 10px;cursor:pointer;font-size:11px;text-transform:uppercase;letter-spacing:.05em}.x:hover{border-color:var(--err)}
.empty{color:var(--mut2);font-size:13px;padding:8px 0}
.log{background:#030a18;border:1px solid var(--line);padding:14px;font:12px/1.55 var(--mono);height:440px;overflow:auto;white-space:pre-wrap;color:#9fb3d0}
.toolbar{display:flex;gap:8px;align-items:center;margin-bottom:12px}.toolbar input{flex:1}
.ef{width:100%;border-collapse:collapse;font-size:13px;margin-top:6px}.ef th{text-align:left;color:var(--mut);font-size:11px;text-transform:uppercase;letter-spacing:.07em;padding:8px 6px;border-bottom:1px solid var(--line2)}.ef td{padding:10px 6px;border-bottom:1px solid var(--line);vertical-align:top}.ef code{font-family:var(--mono);color:var(--acc);word-break:break-all;user-select:all}.mut{color:var(--mut);font-size:11px}.genwrap{overflow-x:auto;margin-top:12px}.genwrap .ef td,.genwrap .ef th{white-space:nowrap}.genwrap code{font-size:12px}.btn:disabled{opacity:.4;cursor:default}code{font-family:var(--mono)}@media(max-width:560px){.row,.row3{grid-template-columns:1fr}}
</style></head><body>
<header>
 <div class=brand><svg xmlns="http://www.w3.org/2000/svg" viewBox="-20 -20 668 330" role="img" aria-label="pKOM"><g fill="none" stroke-linecap="round" stroke-linejoin="round" stroke-width="32"><g stroke="#FFFFFF"><path d="M20 80 V266"></path><circle cx="72" cy="133" r="52"></circle><path d="M178 16 Q206 100 178 184"></path><path d="M192 100 C226 96 250 62 266 16"></path><path d="M492 184 V30 C522 30 534 106 552 106 C570 106 582 30 612 30 V184"></path></g><path stroke="#2EC4F1" d="M192 100 C233 102 256 183 363 183 A83 83 0 0 0 363 17 A83 83 0 0 0 282 118"></path></g></svg><span class=prod>Netzsteuerung</span></div>
 <div class=chip><span class=dot id=dot></span><span id=state>–</span></div>
 <div class=hstat>
  <span id=techbadge class=badge style=display:none></span>
  <span>Frequenz <b id=freq>–</b></span>
  <span>Laufzeit <b id=uptime>–</b></span>
  <span id=msg></span>
 </div>
</header>
<div class=wrap>
 <div class=banner><span>⚠️</span><span><b>Nur abgeschottet betreiben</b> – Dummy Load / Kabel + Dämpfung / geschirmt. Offenes Netz ohne Authentisierung = IMSI-Catcher, wenn es abstrahlt. Nur eigene Test-SIMs, Kennung 001/xx (Test) oder 999/xx (privat).</span></div>

 <div class=controls>
  <button class=bigbtn id=btn_gsm onclick="cmd('start_gsm')"><span class=ic>▶</span><span>GSM (2G)<small id=gsm_sub>Osmocom</small></span></button>
  <button class=bigbtn id=btn_lte onclick="cmd('start_lte')"><span class=ic>▶</span><span>LTE (4G)<small id=lte_sub>srsRAN + Open5GS</small></span></button>
  <button class=bigbtn id=btn_csfb onclick="cmd('start_csfb')"><span class=ic>▶</span><span>LTE + GSM<small id=csfb_sub>Internet + Anrufe (CSFB)</small></span></button>
  <button class="bigbtn stop" onclick="cmd('stop')">■ Stoppen</button>
 </div>

 <div class=tabs>
  <button class="tab sel" data-t=steuerung onclick="tab('steuerung')">Steuerung</button>
  <button class=tab data-t=gsm onclick="tab('gsm')">GSM · 2G</button>
  <button class=tab data-t=lte onclick="tab('lte')">LTE · 4G</button>
  <button class=tab data-t=sims onclick="tab('sims')">SIMs & Nummern</button>
  <button class=tab data-t=profil onclick="tab('profil')">SIM-Profil</button>
  <button class=tab data-t=log onclick="tab('log')">Protokoll</button>
 </div>

 <div class="panel sel" id=p-steuerung>
  <div class=grid>
   <div class=card>
    <h2>Status</h2>
    <div class=freqbox style=margin-top:12px>
     <div><div class=big id=freq2>–</div><div class=sm id=freqsub></div></div>
     <div style=text-align:right><div class=big id=tech2>aus</div><div class=sm id=statesub></div></div>
    </div>
    <div class=hint id=uptimehint></div>
    <div class=hint id=devhint></div>
    <div class=hint id=clash style=color:var(--err)></div>
   </div>
   <div class=card>
    <h2>Funk-Hardware</h2>
    <p class=sub>Je Netz ein eigener LimeSDR. Für „LTE + GSM“ zwei verschiedene wählen.</p>
    <label>LimeSDR für GSM (2G)</label><select id=GSM_DEV></select>
    <label>LimeSDR für LTE (4G)</label><select id=LTE_DEV></select>
    <div style=display:flex;gap:8px;flex-wrap:wrap>
     <button class=btn onclick="save(['GSM_DEV','LTE_DEV'])">Speichern</button>
     <button class="btn sec" onclick="cmd('lime_scan')">Neu suchen</button>
    </div>
    <div class=hint id=limelist></div>
   </div>
   <div class=card>
    <h2>Netz-Identität</h2>
    <p class=sub>Gilt für GSM und LTE. Nur Testkennung 001/xx oder Privatkennung 999/xx.</p>
    <div class=row>
     <div><label>MCC</label><input id=MCC inputmode=numeric></div>
     <div><label>MNC</label><input id=MNC inputmode=numeric></div>
    </div>
    <div class=row>
     <div><label>Netzname (lang)</label><input id=NETNAME></div>
     <div><label>Netzname (kurz)</label><input id=NETNAME_SHORT></div>
    </div>
    <label>Anbietername (SPN, max. 16 Zeichen)</label><input id=SPN maxlength=16>
    <div class=sw><div class=t>NITZ senden<small>Netzname, Uhrzeit und Zeitzone (<span id=tz>–</span>) beim Einbuchen</small></div>
     <label class=switch><input type=checkbox id=NITZ><span class=slider></span></label></div>
    <button class="btn sec" onclick="save(['MCC','MNC','NETNAME','NETNAME_SHORT','SPN','NITZ'])">Speichern</button>
    <p class=hint>Damit das iPhone das Netz als <b>Heimnetz</b> sieht (kein Roaming), muss die IMSI der eSIM mit MCC+MNC beginnen: <b class=tag id=hplmn>–</b>…</p>
   </div>
  </div>
 </div>

 <div class=panel id=p-gsm>
  <div class=grid>
   <div class=card>
    <h2>GSM-Funk</h2>
    <div class=row style=align-items:end>
     <div><label>ARFCN</label><input id=GSM_ARFCN oninput=updateFreq()></div>
     <div class=freqbox><div><div class=big id=gsm_mhz>–</div><div class=sm id=gsm_band></div></div></div>
    </div>
    <div class=hint>1–124 = GSM900 · 512–885 = DCS1800</div>
    <div class=row><div><label>TX-Gain</label><input id=GSM_TX_GAIN></div>
     <div><label>RX-Gain (0–50)</label><input id=GSM_RX_GAIN></div></div>
    <div class=hint>RX-Gain hoch = empfindlicherer Empfang (wichtig für EDGE-Uplink).</div>
    <button class=btn onclick="save(['GSM_ARFCN','GSM_TX_GAIN','GSM_RX_GAIN'])">Speichern</button>
   </div>
   <div class=card>
    <h2>GSM-Optionen</h2>
    <div class="sw first"><div class=t>Offene Anmeldung<small>jede SIM wird eingebucht</small></div>
     <label class=switch><input type=checkbox id=GSM_OPEN><span class=slider></span></label></div>
    <div class=sw><div class=t>EDGE / GPRS-Daten<small>Paketdaten (pcu/sgsn/ggsn)</small></div>
     <label class=switch><input type=checkbox id=GSM_DATA><span class=slider></span></label></div>
    <div class=sw><div class=t>SIP-Trunk zu Asterisk<small>Anrufe ins VoIP/Festnetz</small></div>
     <label class=switch><input type=checkbox id=GSM_SIP><span class=slider></span></label></div>
    <label>SIP-Peer (Asterisk-IP)</label><input id=GSM_SIP_PEER>
    <label>SIP-Local-IP (leer = automatisch)</label><input id=GSM_SIP_LOCAL>
    <button class=btn onclick="save(['GSM_OPEN','GSM_DATA','GSM_SIP','GSM_SIP_PEER','GSM_SIP_LOCAL'])">Speichern</button>
   </div>
   <div class=card>
    <h2>Begrüßungs-SMS</h2>
    <p class=sub>SMS beim Einbuchen und bei Nummernvergabe. Platzhalter: <code>{netz}</code>, <code>{nummer}</code>, <code>{extern}</code>.</p>
    <div class="sw first"><div class=t>SMS aktiv<small>Willkommen + Nummern-Bestätigung</small></div>
     <label class=switch><input type=checkbox id=GSM_SMS><span class=slider></span></label></div>
    <label>Absender-Nummer</label><input id=GSM_SMS_FROM>
    <label>Externe Vorwahl (<code>{extern}</code> = Vorwahl + interne Nummer)</label><input id=GSM_SMS_EXTPREFIX>
    <label>Willkommenstext (beim Einbuchen)</label><input id=GSM_SMS_WELCOME>
    <label>Bestätigung (bei Nummernvergabe)</label><input id=GSM_SMS_NUMBER>
    <button class=btn onclick="save(['GSM_SMS','GSM_SMS_FROM','GSM_SMS_EXTPREFIX','GSM_SMS_WELCOME','GSM_SMS_NUMBER'])">Speichern</button>
    <p class=hint>Begrüßung wird je Netz-Start einmal pro SIM gesendet (wirkt sofort).</p>
    <div style="border-top:1px solid var(--line);margin:14px 0"></div>
    <div class=row><div><label>Test: IMSI</label><input id=sms_test_imsi></div>
     <div><label>Text (leer = Willkommenstext)</label><input id=sms_test_text></div></div>
    <button class="btn sec" onclick="smstest()">Test-SMS senden</button>
    <p class=hint>Sendet sofort an die IMSI – auch wenn „SMS aktiv" aus ist. GSM muss laufen.</p>
   </div>
  </div>
  <p class=hint>Funk-/Options-Änderungen wirken beim nächsten GSM-Start.</p>
 </div>

 <div class=panel id=p-lte>
  <div class=grid>
   <div class=card>
    <h2>LTE-Funk</h2>
    <div class=row style=align-items:end>
     <div><label>EARFCN</label><input id=LTE_EARFCN oninput=updateFreq()></div>
     <div class=freqbox><div><div class=big id=lte_mhz>–</div><div class=sm id=lte_band></div></div></div>
    </div>
    <label>Bandbreite (PRB)</label><select id=LTE_NPRB>
     <option value=6>6 · 1.4 MHz</option><option value=15>15 · 3 MHz</option>
     <option value=25>25 · 5 MHz</option><option value=50>50 · 10 MHz</option>
     <option value=75>75 · 15 MHz</option><option value=100>100 · 20 MHz</option></select>
    <div class=hint>Schwache Hardware (Pi): klein wählen (6–25).</div>
    <button class=btn onclick="save(['LTE_EARFCN','LTE_NPRB'])">Speichern</button>
   </div>
   <div class=card>
    <h2>LTE-Parameter</h2>
    <div class=row><div><label>TX-Gain</label><input id=LTE_TX_GAIN></div>
     <div><label>RX-Gain</label><input id=LTE_RX_GAIN></div></div>
    <label>APN</label><input id=LTE_APN>
    <button class=btn onclick="save(['LTE_TX_GAIN','LTE_RX_GAIN','LTE_APN'])">Speichern</button>
    <p class=hint>LTE braucht SIMs mit Ki/OPc (Tab „SIMs“). Kern: Open5GS, Handy-Netz 10.45.0.0/16 mit NAT ins Internet. Bei „LTE + GSM“ darf die GSM-Frequenz nicht im LTE-Kanal liegen.</p>
   </div>
  </div>
 </div>

 <div class=panel id=p-sims>
  <div class="card" style="margin-bottom:16px">
   <h2>SIM-Daten erzeugen</h2>
   <p class=sub>Für eigene eSIM-Profile (z.&nbsp;B. simlessly): IMSI passend zur Kennung, zufällige Schlüssel (Ki, OP → OPc nach Milenage), ICCID mit Prüfziffer, PIN/PUK/ADM. Bleibt nur im Browser, bis du es übernimmst.</p>
   <div class=row3>
    <div><label>Anzahl (1–50)</label><input id=gen_n type=number min=1 max=50 value=1></div>
    <div><label>Erste Rufnummer (leer = keine)</label><input id=gen_nr inputmode=numeric placeholder="z. B. 9201"></div>
    <div><label>ICCID-Präfix (leer = 89+MCC+MNC)</label><input id=gen_iccid inputmode=numeric></div>
   </div>
   <div style=display:flex;gap:8px;flex-wrap:wrap>
    <button class=btn onclick="simgen()">Erzeugen</button>
    <button class="btn sec" id=gen_take onclick="gentake()" disabled>Alle in pKOM übernehmen</button>
    <button class="btn sec" id=gen_csv onclick="gendl('csv')" disabled>CSV</button>
    <button class="btn sec" id=gen_json onclick="gendl('json')" disabled>JSON</button>
   </div>
   <div class=genwrap><table class=ef id=gen_tab></table></div>
   <p class=hint>AMF 8000, SQN-Start 000000000020, Algorithmus Milenage. Im eSIM-Profil die IMSI, Ki und OPc (oder OP) eintragen; dazu SPN/PNN/OPL aus dem Tab „SIM-Profil“.</p>
  </div>
  <div class=grid>
   <div class=card>
    <h2>SIM eintragen</h2>
    <p class=sub>Einmal eintragen – pKOM schreibt sie automatisch ins GSM-HLR und in den LTE-HSS.</p>
    <div class=row><div><label>IMSI</label><input id=sim_imsi inputmode=numeric></div><div><label>Rufnummer</label><input id=sim_nr inputmode=numeric></div></div>
    <div class=row><div><label>Ki (32 Hex)</label><input id=sim_ki autocomplete=off></div><div><label>OPc (32 Hex)</label><input id=sim_opc autocomplete=off></div></div>
    <button class="btn sm" onclick="simadd()">SIM speichern</button>
    <div style=margin-top:12px id=sims></div>
   </div>
   <div class=card>
    <h2>Eingebuchte Handys</h2>
    <p class=sub>Aktuell im Sprachnetz (MSC) angemeldet – bei „LTE + GSM“ auch über LTE/SGs.</p>
    <div id=attached></div>
   </div>
   <div class=card>
    <h2>Nummer dauerhaft zuweisen</h2>
    <p class=sub>Auch für offen angemeldete GSM-SIMs ohne Ki – überlebt Neustarts.</p>
    <div class=row><div><label>IMSI</label><input id=gnum_imsi></div><div><label>Rufnummer</label><input id=gnum_nr></div></div>
    <button class="btn sm" onclick="simnr()">Zuweisen</button>
    <div style=margin-top:12px id=gsm_numbers></div>
   </div>
  </div>
 </div>

 <div class=panel id=p-profil>
  <div class=card>
   <h2>Werte für das eSIM-Profil</h2>
   <p class=sub>OPL, PNN und SPN sind Dateien <b>auf der SIM</b> – das Netz kann sie nicht setzen. Diese Werte passen zu Kennung und Netzname oben und werden im eSIM-Profil (z.&nbsp;B. simlessly) eingetragen. NITZ schickt pKOM selbst.</p>
   <table class=ef>
    <tr><th>Datei</th><th>Inhalt</th><th>Wert (Hex)</th></tr>
    <tr><td><b>SPN</b><br><span class=mut>EF 6F46</span></td><td id=ef_spn_t></td><td><code id=ef_spn></code></td></tr>
    <tr><td><b>PNN</b><br><span class=mut>EF 6FC5, Eintrag 1</span></td><td id=ef_pnn_t></td><td><code id=ef_pnn></code></td></tr>
    <tr><td><b>OPL</b><br><span class=mut>EF 6FC6, Eintrag 1</span></td><td id=ef_opl_t></td><td><code id=ef_opl></code></td></tr>
    <tr><td><b>HPLMN</b><br><span class=mut>IMSI-Anfang</span></td><td>Heimnetz-Kennung</td><td><code id=ef_hplmn></code></td></tr>
   </table>
   <p class=hint>Datensätze bei fester Länge mit <code>FF</code> auffüllen. In der USIM-Diensttabelle (UST) müssen die Dienste <b>17</b> (SPN), <b>45</b> (PNN) und <b>46</b> (OPL) aktiv sein. Ändern sich Kennung oder Name, die Werte hier neu übernehmen.</p>
  </div>
 </div>

 <div class=panel id=p-log>
  <div class=card>
   <div class=toolbar><h2 style=margin:0>Protokoll</h2><input id=logfilter placeholder="filtern… z.B. GPRS, TBF, error" oninput=renderlog()><span class=badge id=logcount></span></div>
   <div class=log id=log></div>
  </div>
 </div>
</div>
<script>
let S={};
async function api(c,b){const r=await fetch('/api/'+c,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(b||{})});return r.json();}
function $(i){return document.getElementById(i);}
function esc(s){return String(s==null?'':s).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));}
function cmd(c){if(c.startsWith('start'))$('msg').textContent='startet…';api(c).then(r=>{if(c==='lime_scan')limeKey='';render(r);});}
function tab(n){document.querySelectorAll('.tab').forEach(t=>t.classList.toggle('sel',t.dataset.t===n));document.querySelectorAll('.panel').forEach(p=>p.classList.toggle('sel',p.id==='p-'+n));try{localStorage.setItem('pkom_tab',n);}catch(e){}}
function save(keys){let b={};keys.forEach(k=>{let el=$(k);b[k]=el.type==='checkbox'?(el.checked?'1':'0'):el.value;});api('set',b).then(r=>{filled=false;render(r);});}
function simadd(){api('sim_add',{imsi:$('sim_imsi').value,ki:$('sim_ki').value,opc:$('sim_opc').value,msisdn:$('sim_nr').value}).then(r=>{if(!/aber|pruefen/.test(r.msg||'')){['sim_imsi','sim_ki','sim_opc','sim_nr'].forEach(i=>$(i).value='');}render(r);});}
function simnr(){api('gsm_sim_nr',{imsi:$('gnum_imsi').value,msisdn:$('gnum_nr').value}).then(render);}
function smstest(){api('sms_test',{imsi:$('sms_test_imsi').value,text:$('sms_test_text').value}).then(render);}
function simdel(i){if(confirm('SIM '+i+' aus GSM und LTE löschen?'))api('sim_del',{imsi:i}).then(render);}
function numdel(i){api('gsm_num_del',{imsi:i}).then(render);}
function gsmInfo(a){a=+a||0;let m=0,b='';if(a>=1&&a<=124){m=935+0.2*a;b='GSM900';}else if(a>=512&&a<=885){m=1805.2+0.2*(a-512);b='DCS1800';}return{mhz:m?m.toFixed(1)+' MHz':'–',band:b};}
function lteInfo(e){e=+e||0;let m=0,b=0;if(e>=0&&e<=599){m=2110+0.1*e;b=1;}else if(e>=1200&&e<=1949){m=1805+0.1*(e-1200);b=3;}else if(e>=2750&&e<=3449){m=2620+0.1*(e-2750);b=7;}else if(e>=6150&&e<=6449){m=791+0.1*(e-6150);b=20;}return{mhz:m?m.toFixed(1)+' MHz':'–',band:b?'Band '+b:''};}
function updateFreq(){let g=gsmInfo($('GSM_ARFCN').value);$('gsm_mhz').textContent=g.mhz;$('gsm_band').textContent=g.band;let l=lteInfo($('LTE_EARFCN').value);$('lte_mhz').textContent=l.mhz;$('lte_band').textContent=l.band;}
function setv(id,v){let el=$(id);if(!el)return;if(el.type==='checkbox')el.checked=(v==='1'||v===true);else el.value=(v==null?'':v);}
const FIELDS=['MCC','MNC','NETNAME','NETNAME_SHORT','SPN','NITZ','GSM_DEV','LTE_DEV','GSM_ARFCN','GSM_TX_GAIN','GSM_RX_GAIN','GSM_SIP_PEER','GSM_SIP_LOCAL','GSM_OPEN','GSM_DATA','GSM_SIP','GSM_SMS','GSM_SMS_FROM','GSM_SMS_EXTPREFIX','GSM_SMS_WELCOME','GSM_SMS_NUMBER','LTE_EARFCN','LTE_NPRB','LTE_TX_GAIN','LTE_RX_GAIN','LTE_APN'];
let filled=false,limeKey='';
function limeOptions(s){
 const L=s.limes||[],c=s.conf||{},key=JSON.stringify(L)+(c.GSM_DEV||'')+(c.LTE_DEV||'');
 if(key===limeKey)return;limeKey=key;
 ['GSM_DEV','LTE_DEV'].forEach(id=>{const el=$(id),cur=c[id]||'';
  let o='<option value="">automatisch</option>'+L.map(d=>'<option value="'+esc(d.serial)+'">'+esc(d.name)+' · '+esc(d.serial)+(d.media?' · '+esc(d.media):'')+'</option>').join('');
  if(cur&&!L.some(d=>d.serial===cur))o+='<option value="'+esc(cur)+'">'+esc(cur)+' (nicht gefunden)</option>';
  el.innerHTML=o;el.value=cur;});
 $('limelist').textContent=L.length?L.length+' LimeSDR angeschlossen':'Kein LimeSDR gefunden – USB prüfen und „Neu suchen“.';
}
function reloadFields(){const c=S.conf||{};FIELDS.forEach(k=>{if(document.activeElement!==$(k))setv(k,c[k]);});filled=true;updateFreq();}
function fmt(s){const m=Math.floor(s/60),h=Math.floor(m/60);return h?h+'h '+(m%60)+'m':(m?m+'m '+(s%60)+'s':s+'s');}
function renderlog(){const f=($('logfilter').value||'').toLowerCase();let L=(S.log||[]);if(f)L=L.filter(x=>x.toLowerCase().includes(f));const lg=$('log');const near=lg.scrollTop+lg.clientHeight>=lg.scrollHeight-40;lg.textContent=L.join('\n');$('logcount').textContent=L.length+' Zeilen';if(near)lg.scrollTop=lg.scrollHeight;}
function render(s){S=s;limeOptions(s);if(!filled)reloadFields();
 const run=s.state==='laeuft',t=s.tech;
 $('dot').className='dot '+(run?'on':(s.state==='fehler'?'err':''));
 $('state').textContent=s.state;$('msg').textContent=s.msg||'';
 const tb=$('techbadge');if(t){tb.style.display='';tb.textContent=t==='csfb'?'LTE+GSM':t.toUpperCase();}else tb.style.display='none';
 let freq='–',fsub='';
 const gf=s.gsm.mhz+' MHz',lf=s.lte.mhz+' MHz';
 if(t==='lte'){freq=lf;fsub='Band '+s.lte.band+' · EARFCN '+s.lte.earfcn;}
 else if(t==='gsm'){freq=gf;fsub=s.gsm.band+' · ARFCN '+s.gsm.arfcn;}
 else if(t==='csfb'){freq=lf+' / '+gf;fsub='LTE B'+s.lte.band+' · GSM ARFCN '+s.gsm.arfcn;}
 $('freq').textContent=freq;$('freq2').textContent=freq;$('freqsub').textContent=fsub;
 $('tech2').textContent=t?(t==='csfb'?'LTE+GSM':t.toUpperCase()):'aus';$('statesub').textContent=s.state;
 $('uptime').textContent=s.uptime?fmt(s.uptime):'–';$('uptimehint').textContent=run?('läuft seit '+fmt(s.uptime)):'';
 $('devhint').innerHTML=[s.dev.gsm?'GSM-Funk: <b>'+esc(s.dev.gsm)+'</b>':'',s.dev.lte?'LTE-Funk: <b>'+esc(s.dev.lte)+'</b>':''].filter(Boolean).join('<br>');
 $('clash').textContent=s.clash||'';
 [['gsm','Osmocom'],['lte','srsRAN + Open5GS'],['csfb','Internet + Anrufe (CSFB)']].forEach(([k,d])=>{$('btn_'+k).classList.toggle('active',t===k);$(k+'_sub').textContent=t===k?'läuft':d;});
 $('tz').textContent=s.tz||'–';
 const f=s.simfiles||{};$('hplmn').textContent=f.hplmn||'–';
 $('ef_spn').textContent=f.spn||'';$('ef_spn_t').textContent='„'+(f.spn_text||'')+'“';
 $('ef_pnn').textContent=f.pnn||'';$('ef_pnn_t').textContent='lang „'+(f.full||'')+'“, kurz „'+(f.short||'')+'“';
 $('ef_opl').textContent=f.opl||'';$('ef_opl_t').textContent='Kennung '+(f.hplmn||'')+', alle Gebiete → PNN 1';
 $('ef_hplmn').textContent=f.hplmn||'';
 $('gsm_numbers').innerHTML=Object.entries(s.gsm.numbers||{}).map(e=>'<div class=listrow><span class=tag>'+esc(e[0])+' → <b>'+esc(e[1])+'</b></span><button class=x onclick="numdel(\''+esc(e[0])+'\')">löschen</button></div>').join('')||'<div class=empty>keine Zuweisungen</div>';
 $('attached').innerHTML=(s.gsm.attached||[]).map(i=>'<div class=listrow><span class=tag>'+esc(i)+'</span><span class=tag>'+esc((s.gsm.numbers||{})[i]||'')+'</span></div>').join('')||'<div class=empty>keine eingebucht</div>';
 $('sims').innerHTML=(s.sims||[]).map(x=>'<div class=listrow><span class=tag>'+esc(x.imsi)+' · <b>'+esc(x.msisdn)+'</b></span><button class=x onclick="simdel(\''+esc(x.imsi)+'\')">löschen</button></div>').join('')||'<div class=empty>noch keine SIM eingetragen</div>';
 renderlog();
}
let GEN=[];
function simgen(){api('sim_gen',{count:$('gen_n').value,msisdn:$('gen_nr').value,iccid:$('gen_iccid').value}).then(r=>{GEN=r.generated||[];gendraw();render(r);});}
const GCOLS=[['iccid','ICCID'],['imsi','IMSI'],['ki','Ki'],['op','OP'],['opc','OPc'],['msisdn','Rufnr.'],['pin1','PIN1'],['puk1','PUK1'],['pin2','PIN2'],['puk2','PUK2'],['adm1','ADM1']];
function gendraw(){const T=$('gen_tab');
 T.innerHTML=GEN.length?'<tr>'+GCOLS.map(c=>'<th>'+c[1]+'</th>').join('')+'<th></th></tr>'+GEN.map((g,i)=>'<tr>'+GCOLS.map(c=>'<td><code>'+esc(g[c[0]])+'</code></td>').join('')+'<td><button class="btn sm sec" onclick="gentake('+i+')">übernehmen</button></td></tr>').join(''):'';
 ['gen_take','gen_csv','gen_json'].forEach(id=>$(id).disabled=!GEN.length);}
async function gentake(i){const L=i===undefined?GEN:[GEN[i]];let ok=0,last=null;
 for(const g of L){last=await api('sim_add',{imsi:g.imsi,ki:g.ki,opc:g.opc,msisdn:g.msisdn});if(!/aber|pruefen/.test(last.msg||''))ok++;}
 if(last){render(last);$('msg').textContent=ok+' von '+L.length+' SIM(s) in pKOM übernommen'+(ok<L.length?' – '+last.msg:'');}}
function gendl(fmt){if(!GEN.length)return;let data,type,name='pkom-sims-'+new Date().toISOString().slice(0,10);
 if(fmt==='json'){data=JSON.stringify(GEN,null,1);type='application/json';name+='.json';}
 else{const k=Object.keys(GEN[0]);data=[k.join(';')].concat(GEN.map(g=>k.map(x=>g[x]).join(';'))).join(String.fromCharCode(13,10));type='text/csv';name+='.csv';}
 const a=document.createElement('a');a.href=URL.createObjectURL(new Blob([data],{type}));a.download=name;a.click();setTimeout(()=>URL.revokeObjectURL(a.href),2000);}
async function poll(){try{render(await api('status'));}catch(e){}}
try{const t=localStorage.getItem('pkom_tab');if(t&&$('p-'+t))tab(t);}catch(e){}
poll();setInterval(poll,2500);
</script></body></html>"""

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _send(self, code, body, ctype="application/json"):
        b = body.encode() if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        try: self.wfile.write(b)
        except Exception: pass
    def do_GET(self):
        if self.path in ("/", "/index.html"):
            self._send(200, PAGE, "text/html; charset=utf-8")
        elif self.path == "/api/status":
            self._send(200, json.dumps(NET.status()))
        else:
            self._send(404, "{}")
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0) or 0)
        body = self.rfile.read(n).decode(errors="replace") if n else ""
        if self.path.startswith("/api/"):
            try:
                self._send(200, json.dumps(handle_api(self.path, body)))
            except Exception as e:
                log("api:", e); self._send(500, json.dumps({"error": str(e)}))
        else:
            self._send(404, "{}")

def main():
    port = int(C.get("WEB_PORT", "8080"))
    log(f"g90net Web-Oberflaeche auf http://0.0.0.0:{port}  (FAKE={FAKE})")
    threading.Thread(target=sms_welcome_watch, daemon=True).start()
    threading.Thread(target=lime_scan, daemon=True).start()   # LimeSDR fuer die Auswahl suchen
    try: _migrate_lte_db()
    except Exception as e: log("migration:", e)
    ThreadingHTTPServer(("0.0.0.0", port), Handler).serve_forever()

if __name__ == "__main__":
    main()
