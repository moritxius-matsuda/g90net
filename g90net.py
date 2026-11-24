#!/usr/bin/env python3
# =====================================================================
#  g90net - eigenes GSM(2G)- und LTE(4G)-Versuchsnetz mit Weboberflaeche
#  Steuert Osmocom (2G) und srsRAN (4G) ueber einen LimeSDR. Ein Radio =
#  immer nur EINE Technik gleichzeitig (Start der einen stoppt die andere).
#
#  !!!  NUR an Dummy Load / Kabel + Daempfung / geschirmt betreiben.
#       Ein offenes Netz ohne Authentisierung = IMSI-Catcher, wenn es
#       abstrahlt. Nur eigene Test-SIMs. Testkennung 001/01 oder 999/99.
# =====================================================================
import os, re, sys, json, time, shutil, socket, threading, subprocess
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# ------------------------------------------------------------------ Konfig
CONF = os.environ.get("G90NET_CONF", "/etc/g90net.conf")
WORKDIR = "/var/lib/g90net"
OSMO_CFG = "/etc/osmocom"
SRS_CFG = "/etc/srsran"

DEFAULTS = {
    "WEB_PORT": "8080",
    # gemeinsam
    "TECH": "gsm",            # zuletzt gestartet
    "MCC": "001", "MNC": "01", "NETNAME": "g90net",
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
    "LTE_APN": "internet",
    # SDR
    "DEV_ARGS": "driver=lime",
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
GSM_NONFATAL = {"ggsn", "sgsn", "pcu", "sip"}
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
        (r"^(\s*short name\s+).*$", r"\g<1>" + C["NETNAME"]),
        (r"^(\s*long name\s+).*$", r"\g<1>" + C["NETNAME"]),
    ])
    msc = os.path.join(WORKDIR, "osmo-msc.cfg"); hlr = os.path.join(WORKDIR, "osmo-hlr.cfg")
    _vty_del(msc, "authentication")
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

# ---- GSM-SIMs ueber osmo-hlr VTY
def gsm_sim_list():
    if FAKE: return []
    out = []
    txt = vty(HLR_VTY, ["enable", "subscriber list"])
    for m in re.finditer(r"IMSI[:\s]+(\d{14,15})", txt):
        out.append(m.group(1))
    return out

def gsm_sim_add(imsi, ki, opc, msisdn):
    imsi = re.sub(r"\D", "", imsi); ki = re.sub(r"[^0-9a-fA-F]", "", ki); opc = re.sub(r"[^0-9a-fA-F]", "", opc)
    if len(imsi) < 14 or len(ki) != 32 or len(opc) != 32:
        return "IMSI (15), Ki und OPc (je 32 Hex) pruefen"
    msisdn = re.sub(r"\D", "", msisdn) or imsi[-8:]
    if FAKE: return None
    r = vty(HLR_VTY, ["enable", f"subscriber imsi {imsi} create",
                      f"subscriber imsi {imsi} update msisdn {msisdn}",
                      f"subscriber imsi {imsi} update aud3g milenage k {ki} opc {opc}"])
    ok = "% " not in r
    if ok: sms_send(imsi, _sms_text(C.get("GSM_SMS_NUMBER", ""), nummer=msisdn))
    return None if ok else r

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
    d = nums_load()
    if not d or FAKE: return
    cmds = ["enable"]
    for imsi, msisdn in d.items():
        cmds += [f"subscriber imsi {imsi} create", f"subscriber imsi {imsi} update msisdn {msisdn}"]
    vty(HLR_VTY, cmds)

def gsm_sim_nr(imsi, msisdn):
    imsi = re.sub(r"\D", "", imsi); msisdn = re.sub(r"\D", "", msisdn)
    if len(imsi) < 14 or not msisdn: return "IMSI (15 Ziffern) und Rufnummer pruefen"
    d = nums_load(); d[imsi] = msisdn; nums_save(d)        # dauerhaft merken
    if not FAKE and NET.tech == "gsm":                      # sofort anwenden, wenn GSM laeuft
        vty(HLR_VTY, ["enable", f"subscriber imsi {imsi} create",
                      f"subscriber imsi {imsi} update msisdn {msisdn}"])
        sms_send(imsi, _sms_text(C.get("GSM_SMS_NUMBER", ""), nummer=msisdn))
    return None

def gsm_num_del(imsi):
    imsi = re.sub(r"\D", "", imsi); d = nums_load()
    if imsi in d:
        del d[imsi]; nums_save(d)
    if not FAKE and NET.tech == "gsm":
        vty(HLR_VTY, ["enable", f"subscriber imsi {imsi} update msisdn "])

def gsm_sim_del(imsi):
    imsi = re.sub(r"\D", "", imsi)
    if FAKE: return
    vty(HLR_VTY, ["enable", f"subscriber imsi {imsi} delete"])

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
    if FAKE or NET.tech != "gsm" or not imsi or not text:
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
    if NET.tech != "gsm": return "GSM-Netz laeuft nicht"
    txt = _sms_text(text) if (text or "").strip() else _sms_text(C.get("GSM_SMS_WELCOME", ""))
    sms_send(imsi, txt, force=True)
    return f"Test-SMS an {imsi} gesendet"

def msc_attached():
    """IMSIs, die aktuell in der MSC (VLR) eingebucht sind."""
    if FAKE or NET.tech != "gsm":
        return set()
    txt = vty(MSC_VTY, ["enable", "show subscriber cache"])
    return set(re.findall(r"IMSI\D{0,3}(\d{14,15})", txt))

def sms_welcome_watch():
    """Hintergrund: neue Einbuchungen erkennen und einmalig begruessen."""
    while True:
        try:
            if NET.tech == "gsm" and NET.state == "laeuft" and C.get("GSM_SMS", "1") == "1":
                for imsi in msc_attached() - NET.welcomed:
                    NET.welcomed.add(imsi)      # vor dem Senden merken: kein Spam bei Fehler
                    log("willkommens-sms ->", imsi)
                    sms_send(imsi, _sms_text(C.get("GSM_SMS_WELCOME", "")))
        except Exception as e:
            log("sms-watch:", e)
        time.sleep(6)

# ================================================================== LTE (srsRAN)
def lte_prepare():
    os.makedirs(WORKDIR, exist_ok=True)
    mcc, mnc = C["MCC"], C["MNC"]; earfcn = int(C["LTE_EARFCN"]); nprb = int(C["LTE_NPRB"])
    band = earfcn_band(earfcn)
    # srsRAN-Beispielkonfigs kopieren und patchen
    for cfg in ("enb.conf", "rr.conf", "sib.conf", "rb.conf", "epc.conf"):
        src = os.path.join(SRS_CFG, cfg)
        if os.path.isfile(src): shutil.copy(src, os.path.join(WORKDIR, cfg))
    enb = os.path.join(WORKDIR, "enb.conf")
    _sub(enb, [
        (r"^(\s*mcc\s*=\s*)\S+", r"\g<1>" + mcc),
        (r"^(\s*mnc\s*=\s*)\S+", r"\g<1>" + mnc),
        (r"^(\s*dl_earfcn\s*=\s*)\S+", r"\g<1>" + str(earfcn)),
        (r"^(\s*n_prb\s*=\s*)\S+", r"\g<1>" + str(nprb)),
        (r"^(\s*device_name\s*=\s*)\S+", r"\g<1>soapy"),
        (r"^(\s*device_args\s*=\s*).*$", r"\g<1>" + C["DEV_ARGS"]),
        (r"^(\s*tx_gain\s*=\s*)\S+", r"\g<1>" + C["LTE_TX_GAIN"]),
        (r"^(\s*rx_gain\s*=\s*)\S+", r"\g<1>" + C["LTE_RX_GAIN"]),
    ])
    epc = os.path.join(WORKDIR, "epc.conf")
    _sub(epc, [
        (r"^(\s*mcc\s*=\s*)\S+", r"\g<1>" + mcc),
        (r"^(\s*mnc\s*=\s*)\S+", r"\g<1>" + mnc),
        (r"^(\s*apn\s*=\s*)\S+", r"\g<1>" + C["LTE_APN"]),
    ])
    # user_db
    udb = os.path.join(WORKDIR, "user_db.csv")
    if not os.path.isfile(udb):
        open(udb, "w").write("# imsi,auth,ki,opc,amf,sqn,qci,ip\n")

def lte_sim_add(imsi, ki, opc, msisdn):
    imsi = re.sub(r"\D", "", imsi); ki = re.sub(r"[^0-9a-fA-F]", "", ki); opc = re.sub(r"[^0-9a-fA-F]", "", opc)
    if len(imsi) < 14 or len(ki) != 32 or len(opc) != 32:
        return "IMSI (15), Ki und OPc (je 32 Hex) pruefen"
    udb = os.path.join(WORKDIR, "user_db.csv")
    lines = []
    if os.path.isfile(udb):
        lines = [l for l in open(udb).read().splitlines() if not l.startswith(imsi + ",")]
    else:
        lines = ["# imsi,auth,ki,opc,amf,sqn,qci,ip"]
    # name,auth,key,op_type,op,amf,sqn,qci  (srsEPC Format: name,auth,imsi,key,opc,amf,sqn,qci,ip)
    lines.append("%s,mil,%s,%s,%s,9001,000000001234,7,dynamic" % (imsi, imsi, ki, opc))
    open(udb, "w").write("\n".join(lines) + "\n")
    return None

def lte_sim_list():
    udb = os.path.join(WORKDIR, "user_db.csv")
    out = []
    if os.path.isfile(udb):
        for l in open(udb).read().splitlines():
            if l and not l.startswith("#"):
                out.append(l.split(",")[0])
    return out

def lte_sim_del(imsi):
    imsi = re.sub(r"\D", "", imsi)
    udb = os.path.join(WORKDIR, "user_db.csv")
    if os.path.isfile(udb):
        lines = [l for l in open(udb).read().splitlines() if not l.startswith(imsi + ",")]
        open(udb, "w").write("\n".join(lines) + "\n")

# ================================================================== Netz-Manager
class Net:
    def __init__(self):
        self.lock = threading.RLock()
        self.tech = None          # None | "gsm" | "lte"
        self.state = "aus"        # aus | startet | laeuft | fehler
        self.msg = ""
        self.procs = {}
        self.loglines = []
        self.started = 0.0
        self.welcomed = set()     # IMSIs, die in dieser Netz-Session schon begruesst wurden

    def _log(self, tag, line):
        line = line.rstrip()
        if not line: return
        print(f"{tag}: {line}", flush=True)   # -> journald, damit 'journalctl -u g90net' alles zeigt
        self.loglines.append(f"{tag}: {line}")
        if len(self.loglines) > 400: self.loglines = self.loglines[-400:]
        low = line.lower()
        if ("fatal" in low or "failed to create radio" in low) and tag not in GSM_NONFATAL:
            self.msg = f"{tag}: {line[:120]}"

    def _reader(self, p, tag):
        try:
            for raw in iter(p.stdout.readline, ""):
                self._log(tag, raw)
        except Exception:
            pass

    def _spawn(self, binary, args, tag):
        p = subprocess.Popen([binary] + args, stdout=subprocess.PIPE,
                             stderr=subprocess.STDOUT, text=True, bufsize=1)
        self.procs[tag] = p
        threading.Thread(target=self._reader, args=(p, tag), daemon=True).start()
        return p

    def stop(self):
        with self.lock:
            if FAKE:
                self.tech=None; self.state="aus"; self.procs={}; return
            for tag, p in list(self.procs.items()):
                try: p.terminate()
                except Exception: pass
            time.sleep(1)
            for name in OSMO_SERVICES + ["srsenb", "srsepc"]:
                try: subprocess.run(["pkill", "-9", "-f", name],
                                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                except Exception: pass
            self.procs = {}
            if self.tech:
                _lime_service("start")   # G90-Empfang wieder frei geben
            self.tech = None; self.state = "aus"; self.msg = "gestoppt"

    def start_gsm(self):
        with self.lock:
            self.stop(); self.tech = "gsm"; self.state = "startet"; self.msg=""
            self.loglines = []; self.started = time.time(); self.welcomed = set()
        if FAKE:
            with self.lock: self.state = "laeuft"; self.msg = "GSM laeuft (FAKE)"
            return None
        try:
            self._prep_osmo_services_off()
            gsm_prepare()
            _lime_service("stop"); time.sleep(1); _free_lime(); time.sleep(2)
            for name, binary, cfg in gsm_components():
                flag = "-C" if binary.startswith("osmo-trx") else "-c"
                self._spawn(binary, [flag, os.path.join(WORKDIR, cfg)], name)
                time.sleep(4 if name in ("trx",) else 1.2)
            time.sleep(1); gsm_apply_numbers()   # dauerhafte Rufnummern ins HLR schreiben
            with self.lock: self.state = "laeuft"; self.msg = "GSM gestartet"
        except Exception as e:
            with self.lock: self.state = "fehler"; self.msg = str(e)
            return str(e)
        return None

    def start_lte(self):
        with self.lock:
            self.stop(); self.tech = "lte"; self.state = "startet"; self.msg=""
            self.loglines = []; self.started = time.time()
        if FAKE:
            with self.lock: self.state = "laeuft"; self.msg = "LTE laeuft (FAKE)"
            return None
        try:
            lte_prepare()
            _lime_service("stop"); time.sleep(1); _free_lime(); time.sleep(2)
            self._spawn("srsepc", [os.path.join(WORKDIR, "epc.conf"),
                                   "--hss.db_file=" + os.path.join(WORKDIR, "user_db.csv")], "epc")
            time.sleep(2)
            self._spawn("srsenb", [os.path.join(WORKDIR, "enb.conf"),
                                   "--enb_files.rr_config=" + os.path.join(WORKDIR, "rr.conf"),
                                   "--enb_files.sib_config=" + os.path.join(WORKDIR, "sib.conf"),
                                   "--enb_files.rb_config=" + os.path.join(WORKDIR, "rb.conf")], "enb")
            with self.lock: self.state = "laeuft"; self.msg = "LTE gestartet"
        except Exception as e:
            with self.lock: self.state = "fehler"; self.msg = str(e)
            return str(e)
        return None

    def _prep_osmo_services_off(self):
        for s in OSMO_SERVICES:
            try: subprocess.run(["systemctl", "stop", s + ".service"],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=8)
            except Exception: pass

    def status(self):
        with self.lock:
            st = {
                "tech": self.tech, "state": self.state, "msg": self.msg,
                "uptime": int(time.time() - self.started) if self.started and self.state == "laeuft" else 0,
                "log": self.loglines[-60:],
                "conf": dict(C),
                "gsm": {
                    "arfcn": int(C["GSM_ARFCN"]), "band": arfcn_band(int(C["GSM_ARFCN"])),
                    "mhz": arfcn_mhz(int(C["GSM_ARFCN"])),
                    "sims": gsm_sim_list() if self.tech == "gsm" else [],
                    "numbers": nums_load(),
                },
                "lte": {
                    "earfcn": int(C["LTE_EARFCN"]), "band": earfcn_band(int(C["LTE_EARFCN"])),
                    "mhz": earfcn_mhz(int(C["LTE_EARFCN"])), "sims": lte_sim_list(),
                },
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
    if cmd == "start_gsm":
        NET.start_gsm()
    elif cmd == "start_lte":
        NET.start_lte()
    elif cmd == "stop":
        NET.stop()
    elif cmd == "set":
        # beliebige Konfig-Keys setzen (validiert light)
        for k, v in req.items():
            if k in DEFAULTS or k in C:
                cset(k, str(v))
        NET.msg = "gespeichert - wirkt beim naechsten Start"
    elif cmd == "gsm_sim_add":
        NET.msg = gsm_sim_add(req.get("imsi",""), req.get("ki",""), req.get("opc",""), req.get("msisdn","")) or "SIM gespeichert"
    elif cmd == "gsm_sim_nr":
        NET.msg = gsm_sim_nr(req.get("imsi",""), req.get("msisdn","")) or "Rufnummer dauerhaft zugewiesen"
    elif cmd == "gsm_num_del":
        gsm_num_del(req.get("imsi","")); NET.msg = "Rufnummer-Zuweisung geloescht"
    elif cmd == "gsm_sim_del":
        gsm_sim_del(req.get("imsi","")); NET.msg = "SIM geloescht"
    elif cmd == "sms_test":
        NET.msg = sms_test(req.get("imsi",""), req.get("text",""))
    elif cmd == "lte_sim_add":
        NET.msg = lte_sim_add(req.get("imsi",""), req.get("ki",""), req.get("opc",""), req.get("msisdn","")) or "SIM gespeichert"
    elif cmd == "lte_sim_del":
        lte_sim_del(req.get("imsi","")); NET.msg = "SIM geloescht"
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
.controls{display:grid;grid-template-columns:1fr 1fr auto;gap:10px;margin-bottom:20px}
@media(max-width:640px){.controls{grid-template-columns:1fr}}
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
 <div class=banner><span>⚠️</span><span><b>Nur abgeschottet betreiben</b> – Dummy Load / Kabel + Dämpfung / geschirmt. Offenes Netz ohne Authentisierung = IMSI-Catcher, wenn es abstrahlt. Nur eigene Test-SIMs, Testkennung 001/01 oder 999/99.</span></div>

 <div class=controls>
  <button class=bigbtn id=btn_gsm onclick="cmd('start_gsm')"><span class=ic>▶</span><span>GSM (2G) starten<small id=gsm_sub>Osmocom</small></span></button>
  <button class=bigbtn id=btn_lte onclick="cmd('start_lte')"><span class=ic>▶</span><span>LTE (4G) starten<small id=lte_sub>srsRAN</small></span></button>
  <button class="bigbtn stop" onclick="cmd('stop')">■ Stoppen</button>
 </div>

 <div class=tabs>
  <button class="tab sel" data-t=steuerung onclick="tab('steuerung')">Steuerung</button>
  <button class=tab data-t=gsm onclick="tab('gsm')">GSM · 2G</button>
  <button class=tab data-t=lte onclick="tab('lte')">LTE · 4G</button>
  <button class=tab data-t=sims onclick="tab('sims')">SIMs & Nummern</button>
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
   </div>
   <div class=card>
    <h2>Netz-Identität</h2>
    <p class=sub>Gilt für GSM und LTE.</p>
    <div class=row3>
     <div><label>MCC</label><input id=MCC></div>
     <div><label>MNC</label><input id=MNC></div>
     <div><label>Netzname</label><input id=NETNAME></div>
    </div>
    <label>SDR dev-args</label><input id=DEV_ARGS>
    <button class="btn sec" onclick="save(['MCC','MNC','NETNAME','DEV_ARGS'])">Speichern</button>
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
    <p class=hint>LTE braucht SIMs mit Ki/OPc (Tab „SIMs"). srsRAN muss installiert sein.</p>
   </div>
  </div>
 </div>

 <div class=panel id=p-sims>
  <div class=grid>
   <div class=card>
    <h2>Nummer dauerhaft zuweisen</h2>
    <p class=sub>Auch für offen angemeldete SIMs ohne Ki – überlebt Neustarts.</p>
    <div class=row><div><label>IMSI</label><input id=gnum_imsi></div><div><label>Rufnummer</label><input id=gnum_nr></div></div>
    <button class="btn sm" onclick="simnr()">Zuweisen</button>
    <div style=margin-top:12px id=gsm_numbers></div>
   </div>
   <div class=card>
    <h2>Eingebuchte Handys</h2>
    <p class=sub>Aktuell im GSM-Netz angemeldet.</p>
    <div id=gsm_sims></div>
   </div>
   <div class=card>
    <h2>GSM-SIM mit Schlüssel</h2>
    <p class=sub>Eigene Test-SIM (Ki/OPc bekannt).</p>
    <div class=row><div><label>IMSI</label><input id=gsim_imsi></div><div><label>Rufnummer</label><input id=gsim_nr></div></div>
    <div class=row><div><label>Ki (32 Hex)</label><input id=gsim_ki></div><div><label>OPc (32 Hex)</label><input id=gsim_opc></div></div>
    <button class="btn sm" onclick="simadd('gsm')">SIM speichern</button>
   </div>
   <div class=card>
    <h2>LTE-SIMs</h2>
    <p class=sub>LTE erfordert Ki/OPc.</p>
    <div class=row><div><label>IMSI</label><input id=lsim_imsi></div><div><label>Rufnummer</label><input id=lsim_nr></div></div>
    <div class=row><div><label>Ki (32 Hex)</label><input id=lsim_ki></div><div><label>OPc (32 Hex)</label><input id=lsim_opc></div></div>
    <button class="btn sm" onclick="simadd('lte')">SIM speichern</button>
    <div style=margin-top:12px id=lte_sims></div>
   </div>
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
function cmd(c){api(c).then(render);}
function tab(n){document.querySelectorAll('.tab').forEach(t=>t.classList.toggle('sel',t.dataset.t===n));document.querySelectorAll('.panel').forEach(p=>p.classList.toggle('sel',p.id==='p-'+n));}
function save(keys){let b={};keys.forEach(k=>{let el=$(k);b[k]=el.type==='checkbox'?(el.checked?'1':'0'):el.value;});api('set',b).then(render);}
function simadd(t){const p=t==='gsm'?'gsim':'lsim';api(t+'_sim_add',{imsi:$(p+'_imsi').value,ki:$(p+'_ki').value,opc:$(p+'_opc').value,msisdn:$(p+'_nr').value}).then(render);}
function simnr(){api('gsm_sim_nr',{imsi:$('gnum_imsi').value,msisdn:$('gnum_nr').value}).then(render);}
function smstest(){api('sms_test',{imsi:$('sms_test_imsi').value,text:$('sms_test_text').value}).then(render);}
function simdel(t,i){api(t+'_sim_del',{imsi:i}).then(render);}
function numdel(i){api('gsm_num_del',{imsi:i}).then(render);}
function gsmInfo(a){a=+a||0;let m=0,b='';if(a>=1&&a<=124){m=935+0.2*a;b='GSM900';}else if(a>=512&&a<=885){m=1805.2+0.2*(a-512);b='DCS1800';}return{mhz:m?m.toFixed(1)+' MHz':'–',band:b};}
function lteInfo(e){e=+e||0;let m=0,b=0;if(e>=0&&e<=599){m=2110+0.1*e;b=1;}else if(e>=1200&&e<=1949){m=1805+0.1*(e-1200);b=3;}else if(e>=2750&&e<=3449){m=2620+0.1*(e-2750);b=7;}else if(e>=6150&&e<=6449){m=791+0.1*(e-6150);b=20;}return{mhz:m?m.toFixed(1)+' MHz':'–',band:b?'Band '+b:''};}
function updateFreq(){let g=gsmInfo($('GSM_ARFCN').value);$('gsm_mhz').textContent=g.mhz;$('gsm_band').textContent=g.band;let l=lteInfo($('LTE_EARFCN').value);$('lte_mhz').textContent=l.mhz;$('lte_band').textContent=l.band;}
function setv(id,v){let el=$(id);if(!el)return;if(el.type==='checkbox')el.checked=(v==='1'||v===true);else el.value=(v==null?'':v);}
const FIELDS=['MCC','MNC','NETNAME','DEV_ARGS','GSM_ARFCN','GSM_TX_GAIN','GSM_RX_GAIN','GSM_SIP_PEER','GSM_SIP_LOCAL','GSM_OPEN','GSM_DATA','GSM_SIP','GSM_SMS','GSM_SMS_FROM','GSM_SMS_EXTPREFIX','GSM_SMS_WELCOME','GSM_SMS_NUMBER','LTE_EARFCN','LTE_NPRB','LTE_TX_GAIN','LTE_RX_GAIN','LTE_APN'];
let filled=false;
function reloadFields(){const c=S.conf||{};FIELDS.forEach(k=>setv(k,c[k]));filled=true;updateFreq();}
function fmt(s){const m=Math.floor(s/60),h=Math.floor(m/60);return h?h+'h '+(m%60)+'m':(m?m+'m '+(s%60)+'s':s+'s');}
function renderlog(){const f=($('logfilter').value||'').toLowerCase();let L=(S.log||[]);if(f)L=L.filter(x=>x.toLowerCase().includes(f));const lg=$('log');const near=lg.scrollTop+lg.clientHeight>=lg.scrollHeight-40;lg.textContent=L.join('\n');$('logcount').textContent=L.length+' Zeilen';if(near)lg.scrollTop=lg.scrollHeight;}
function render(s){S=s;if(!filled)reloadFields();
 const run=s.state==='laeuft';
 $('dot').className='dot '+(run?'on':(s.state==='fehler'?'err':''));
 $('state').textContent=s.state;$('msg').textContent=s.msg||'';
 const tb=$('techbadge');if(s.tech){tb.style.display='';tb.textContent=s.tech.toUpperCase();}else tb.style.display='none';
 let freq='–',fsub='';
 if(s.tech==='lte'){freq=s.lte.mhz+' MHz';fsub='Band '+s.lte.band+' · EARFCN '+s.lte.earfcn;}
 else if(s.tech==='gsm'){freq=s.gsm.mhz+' MHz';fsub=s.gsm.band+' · ARFCN '+s.gsm.arfcn;}
 $('freq').textContent=freq;$('freq2').textContent=freq;$('freqsub').textContent=fsub;
 $('tech2').textContent=s.tech?s.tech.toUpperCase():'aus';$('statesub').textContent=s.state;
 $('uptime').textContent=s.uptime?fmt(s.uptime):'–';$('uptimehint').textContent=run?('läuft seit '+fmt(s.uptime)):'';
 $('btn_gsm').classList.toggle('active',s.tech==='gsm');$('btn_lte').classList.toggle('active',s.tech==='lte');
 $('gsm_sub').textContent=s.tech==='gsm'?'läuft':'Osmocom';$('lte_sub').textContent=s.tech==='lte'?'läuft':'srsRAN';
 $('gsm_numbers').innerHTML=Object.entries(s.gsm.numbers||{}).map(e=>'<div class=listrow><span class=tag>'+e[0]+' → <b>'+e[1]+'</b></span><button class=x onclick="numdel(\''+e[0]+'\')">löschen</button></div>').join('')||'<div class=empty>keine Zuweisungen</div>';
 $('gsm_sims').innerHTML=(s.gsm.sims||[]).map(i=>'<div class=listrow><span class=tag>'+i+'</span><button class=x onclick="simdel(\'gsm\',\''+i+'\')">löschen</button></div>').join('')||'<div class=empty>keine eingebucht</div>';
 $('lte_sims').innerHTML=(s.lte.sims||[]).map(i=>'<div class=listrow><span class=tag>'+i+'</span><button class=x onclick="simdel(\'lte\',\''+i+'\')">löschen</button></div>').join('')||'<div class=empty>keine</div>';
 renderlog();
}
async function poll(){try{render(await api('status'));}catch(e){}}
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
    ThreadingHTTPServer(("0.0.0.0", port), Handler).serve_forever()

if __name__ == "__main__":
    main()
