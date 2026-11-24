#!/usr/bin/env bash
# =====================================================================
#  g90net - Installer fuer ein eigenes GSM(2G)- und LTE(4G)-Versuchsnetz
#  mit Weboberflaeche. Fuer Debian 13 (Server) oder Raspberry Pi OS / Pi.
#
#  Installiert Osmocom (2G), srsRAN + Open5GS + MongoDB (4G), LimeSuite und
#  den Steuer-Daemon g90net inkl. Weboberflaeche. Mit zwei LimeSDR laeuft
#  "LTE + GSM" (CSFB): Internet ueber 4G, Anrufe/SMS ueber GSM + SIP-Trunk.
#  Bedienung danach im Browser:
#      http://<IP-des-Rechners>:8080
#
#  Aufruf:
#      sudo bash g90net-install.sh           installieren
#      sudo bash g90net-install.sh --off      Dienst stoppen + abschalten
#
#  !!!  NUR an Dummy Load / Kabel + Daempfung / geschirmt. Offenes Netz ohne
#       Authentisierung = IMSI-Catcher, wenn es abstrahlt. Nur eigene
#       Test-SIMs. Kennung 001/xx (Test) oder 999/xx (privat) - keine echten Betreiber.
# =====================================================================
# Kein 'set -e': der Installer besteht aus vielen Best-Effort-Schritten (Pakete, Konfigs
# nachziehen, NAT). Kritische Schritte sind unten explizit mit 'die' abgesichert.
set -u

CONF=/etc/g90net.conf
APPDIR=/opt/g90net
PY=$APPDIR/g90net.py
UNIT=/etc/systemd/system/g90net.service
WEB_PORT="${WEB_PORT:-8080}"

info() { echo -e "\e[1;32m==>\e[0m $*"; }
warn() { echo -e "\e[1;33m!!  $*\e[0m"; }
die()  { echo -e "\e[1;31mFEHLER:\e[0m $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Bitte als root ausfuehren:  sudo bash $0"

if [[ ${1:-} == --off ]]; then
  info "g90net abschalten"
  systemctl disable --now g90net.service 2>/dev/null || true
  exit 0
fi

export DEBIAN_FRONTEND=noninteractive
. /etc/os-release 2>/dev/null || true
info "System: ${PRETTY_NAME:-unbekannt} / $(uname -m)"

# ---- Abhaengigkeiten -------------------------------------------------
info "Pakete installieren (kann dauern)"
apt-get update -qq || true
# Basis
# Essentials einzeln, damit ein fehlendes Paket nicht die ganze Liste abbricht
for pkg in python3 iptables usbutils curl ca-certificates gnupg psmisc; do
  apt-get install -y -qq "$pkg" 2>/dev/null || warn "Paket $pkg nicht installierbar (ggf. schon vorhanden)"
done
# LimeSDR
apt-get install -y -qq limesuite liblimesuite-dev soapysdr-tools soapysdr-module-lms7 2>/dev/null || \
  apt-get install -y -qq limesuite soapysdr-tools 2>/dev/null || true

OSMO_BINS="osmo-trx-lms osmo-bts-trx osmo-bsc osmo-mgw osmo-msc osmo-hlr osmo-stp osmo-sip-connector osmo-pcu osmo-sgsn osmo-ggsn"
have_osmo() { for b in $OSMO_BINS; do command -v "$b" >/dev/null 2>&1 || return 1; done; }
have_srs()  { command -v srsenb >/dev/null 2>&1 && command -v srsepc >/dev/null 2>&1; }

info "Osmocom (2G) installieren"
apt-get install -y -qq $OSMO_BINS 2>/dev/null || true
if ! have_osmo; then
  warn "Nicht alles in den Standardquellen - binde Osmocom-Repo ein"
  for FEED in "Debian_13" "Debian_Testing" "Debian_Unstable" "Raspbian_12"; do
    BASE="https://downloads.osmocom.org/packages/osmocom:/latest/${FEED}"
    if curl -fsSL "$BASE/Release.key" -o /tmp/osmo.key 2>/dev/null; then
      gpg --dearmor < /tmp/osmo.key > /usr/share/keyrings/osmocom.gpg 2>/dev/null || cp /tmp/osmo.key /usr/share/keyrings/osmocom.gpg
      echo "deb [signed-by=/usr/share/keyrings/osmocom.gpg] ${BASE}/ ./" > /etc/apt/sources.list.d/osmocom-latest.list
      apt-get update -qq 2>/dev/null && apt-get install -y -qq $OSMO_BINS 2>/dev/null || true
      have_osmo && { info "Osmocom aus $FEED"; break; }
      rm -f /etc/apt/sources.list.d/osmocom-latest.list
    fi
  done
fi
have_osmo || warn "Nicht alle Osmocom-Binaries vorhanden - GSM meldet beim Start, was fehlt."

info "srsRAN (4G-Funk) installieren"
apt-get install -y -qq srsran 2>/dev/null || apt-get install -y -qq srslte 2>/dev/null || true
command -v srsenb >/dev/null 2>&1 || warn "srsenb nicht gefunden - 4G erst nach 'apt install srsran'."

# ---- Open5GS (4G-Kern mit SGs fuer CSFB) + MongoDB (Teilnehmer-DB) --------
info "Python-Module fuer Open5GS-Steuerung"
apt-get install -y -qq python3-yaml python3-pymongo iproute2 2>/dev/null || warn "python3-yaml/python3-pymongo nicht installierbar"

have_o5() { command -v open5gs-mmed >/dev/null 2>&1 && command -v open5gs-hssd >/dev/null 2>&1; }
info "Open5GS (4G-Kern) installieren"
apt-get install -y -qq open5gs 2>/dev/null || true
if ! have_o5; then
  warn "Open5GS nicht in den Standardquellen - binde Open5GS-Repo ein"
  for FEED in "Debian_13" "Debian_12"; do
    BASE="https://download.opensuse.org/repositories/home:/acetcom:/open5gs:/latest/${FEED}"
    if curl -fsSL "$BASE/Release.key" -o /tmp/o5.key 2>/dev/null; then
      gpg --dearmor < /tmp/o5.key > /usr/share/keyrings/open5gs.gpg 2>/dev/null || cp /tmp/o5.key /usr/share/keyrings/open5gs.gpg
      echo "deb [signed-by=/usr/share/keyrings/open5gs.gpg] ${BASE}/ ./" > /etc/apt/sources.list.d/open5gs.list
      apt-get update -qq 2>/dev/null && apt-get install -y -qq open5gs 2>/dev/null || true
      have_o5 && { info "Open5GS aus $FEED"; break; }
      rm -f /etc/apt/sources.list.d/open5gs.list
    fi
  done
fi
have_o5 || warn "Open5GS fehlt - LTE und 'LTE + GSM' melden beim Start, was fehlt."

if ! command -v mongod >/dev/null 2>&1; then
  if [[ $(uname -m) == x86_64 ]] && ! grep -qw avx /proc/cpuinfo; then
    warn "CPU ohne AVX: aktuelle MongoDB laeuft hier nicht - LTE-Teilnehmer-DB nicht moeglich."
  else
    info "MongoDB (Teilnehmer-DB fuer Open5GS) installieren"
    curl -fsSL https://pgp.mongodb.com/server-8.0.asc | gpg --dearmor > /usr/share/keyrings/mongodb-8.0.gpg 2>/dev/null || true
    for CN in trixie bookworm; do
      echo "deb [signed-by=/usr/share/keyrings/mongodb-8.0.gpg] https://repo.mongodb.org/apt/debian ${CN}/mongodb-org/8.0 main" \
        > /etc/apt/sources.list.d/mongodb-org-8.0.list
      apt-get update -qq 2>/dev/null && apt-get install -y -qq mongodb-org 2>/dev/null || true
      command -v mongod >/dev/null 2>&1 && { info "MongoDB aus Zweig $CN"; break; }
    done
    command -v mongod >/dev/null 2>&1 || { rm -f /etc/apt/sources.list.d/mongodb-org-8.0.list; warn "MongoDB nicht installierbar"; }
  fi
fi
command -v mongod >/dev/null 2>&1 && systemctl enable --now mongod >/dev/null 2>&1 || true

# SCTP (S1AP + SGs) beim Booten laden
modprobe sctp 2>/dev/null || warn "Kernelmodul sctp nicht ladbar"
echo sctp > /etc/modules-load.d/pkom-sctp.conf

# ---- Standardkonfigs bereitstellen ----------------------------------
mkdir -p /etc/osmocom /etc/srsran /var/lib/g90net
# Osmocom: Beispielkonfigs aus der Paket-Doku nachziehen, falls /etc/osmocom leer
for f in osmo-stp.cfg osmo-hlr.cfg osmo-msc.cfg osmo-bsc.cfg osmo-bts-trx.cfg osmo-trx-lms.cfg osmo-mgw.cfg osmo-sgsn.cfg osmo-ggsn.cfg osmo-pcu.cfg osmo-sip-connector.cfg; do
  if [[ ! -f /etc/osmocom/$f ]]; then
    src=$(find /usr/share/doc -name "$f*" 2>/dev/null | head -1)
    [[ -n "$src" ]] && { zcat -f "$src" > /etc/osmocom/$f 2>/dev/null || cp "$src" /etc/osmocom/$f 2>/dev/null; } || true
  fi
done
# srsRAN: Beispielkonfigs nachziehen
for f in enb.conf rr.conf sib.conf rb.conf epc.conf; do
  if [[ ! -f /etc/srsran/$f ]]; then
    src=$(find /usr/share/srsran /usr/share/doc -name "$f*" 2>/dev/null | grep -iE 'srs|enb|epc' | head -1)
    [[ -n "$src" ]] && cp "$src" /etc/srsran/$f 2>/dev/null || true
  fi
done

# Automatisch startende Osmocom-Dienste abschalten (g90net steuert selbst)
info "Automatische Osmocom-/srsRAN-Dienste abschalten"
for s in osmo-stp osmo-hlr osmo-mgw osmo-msc osmo-bsc osmo-bts-trx osmo-trx-lms osmo-sip-connector osmo-pcu osmo-sgsn osmo-ggsn srsenb srsepc; do
  systemctl disable --now "${s}.service" 2>/dev/null || true
done
# Open5GS-Dienste ebenso (pKOM startet den Kern selbst mit eigener Konfig)
for u in $(systemctl list-unit-files 'open5gs-*' --no-legend 2>/dev/null | awk '{print $1}'); do
  systemctl disable --now "$u" 2>/dev/null || true
done

# Alte, in die G90-App eingebaute Mobilfunk-Dienste entfernen
# (das Versuchsnetz ist jetzt nur noch dieses eigenstaendige Programm)
for s in g90-cell g90-gsm; do
  if [[ -f /etc/systemd/system/${s}.service ]]; then
    info "Alten Dienst ${s} entfernen"
    systemctl disable --now "${s}.service" 2>/dev/null || true
    rm -f "/etc/systemd/system/${s}.service"
  fi
done
rm -f /opt/g90remote/g90cell.py /opt/g90remote/g90gsm.py

# ---- NAT fuer Datenverkehr (EDGE/LTE) -------------------------------
info "IP-Weiterleitung + NAT einrichten"
sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
grep -q '^net.ipv4.ip_forward=1' /etc/sysctl.conf 2>/dev/null || echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
UPLINK=$(ip route get 8.8.8.8 2>/dev/null | grep -oP 'dev \K\S+' | head -1 || true)
if [[ -n ${UPLINK:-} ]]; then
  iptables -t nat -C POSTROUTING -o "$UPLINK" -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -o "$UPLINK" -j MASQUERADE
  echo "    NAT ueber $UPLINK"
fi

# ---- Daemon entpacken ------------------------------------------------
info "Steuer-Daemon + Weboberflaeche nach $PY"
mkdir -p "$APPDIR"
sed -n '/^__G90NET_PAYLOAD__$/,$p' "$0" | tail -n +2 | base64 -d > "$PY.new"
[[ -s "$PY.new" ]] || die "Payload-Entpacken fehlgeschlagen"
python3 -c "import py_compile; py_compile.compile('$PY.new', doraise=True)" || die "Daemon fehlerhaft entpackt"
mv -f "$PY.new" "$PY"; chmod 755 "$PY"
python3 -c "import json,socket,http.server" || die "python3 unvollstaendig"

# ---- Konfig anlegen --------------------------------------------------
if [[ ! -f $CONF ]]; then
  info "Standardkonfig $CONF anlegen"
  cat > "$CONF" <<EOF
# g90net / pKOM - Einstellungen (werden auch ueber die Weboberflaeche geschrieben)
WEB_PORT="$WEB_PORT"
MCC="001"
MNC="01"
NETNAME="pKOM"
NETNAME_SHORT="pKOM"
SPN="pKOM"
NITZ="1"
GSM_DEV=""
LTE_DEV=""
GSM_ARFCN="20"
GSM_TX_GAIN="50"
GSM_RX_GAIN="45"
GSM_OPEN="1"
GSM_DATA="0"
GSM_SIP="0"
GSM_SIP_PEER=""
GSM_SIP_LOCAL=""
GSM_SMS="1"
GSM_SMS_FROM="1000"
GSM_SMS_EXTPREFIX="+49 651 635555"
GSM_SMS_WELCOME="Willkommen im {netz}! Du bist jetzt eingebucht. 73"
GSM_SMS_NUMBER="Deine Rufnummer im {netz}-Netz ist jetzt {nummer}. Extern erreichbar: {extern}"
LTE_EARFCN="1575"
LTE_NPRB="25"
LTE_TX_GAIN="80"
LTE_RX_GAIN="40"
LTE_APN="internet"
LTE_TAC="7"
EOF
fi

# ---- systemd-Dienst --------------------------------------------------
info "systemd-Dienst g90net anlegen"
cat > "$UNIT" <<EOF
[Unit]
Description=g90net / pKOM - GSM/LTE-Versuchsnetz mit Weboberflaeche
After=network.target mongod.service
Wants=mongod.service

[Service]
User=root
Environment=G90NET_CONF=$CONF
ExecStart=/usr/bin/python3 -u $PY
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable g90net.service >/dev/null 2>&1
systemctl restart g90net.service

if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow "${WEB_PORT}/tcp" >/dev/null 2>&1 && echo "    ufw: Port ${WEB_PORT}/tcp frei"
fi

IP=$(hostname -I 2>/dev/null | awk '{print $1}')
sleep 2
cat <<EOF

=====================================================================
  g90net ist installiert.

  Weboberflaeche:   http://${IP:-<diese-IP>}:${WEB_PORT}
  Log:              journalctl -u g90net -f
  Abschalten:       sudo bash $0 --off

  Bedienung komplett im Browser:
   - Steuerung: LimeSDR je Netz zuordnen, Kennung/Netzname/NITZ
   - GSM, LTE oder "LTE + GSM" (CSFB, zwei LimeSDR) starten
   - SIMs einmal eintragen (GSM-HLR + LTE-HSS automatisch)
   - SIM-Profil: OPL/PNN/SPN-Werte fuer die eSIM

  WICHTIG: Nur an Dummy Load / Kabel + Daempfung / geschirmt betreiben.
  Nur eigene Test-SIMs. Kennung 001/xx oder 999/xx.
  Hinweis Raspberry Pi 3: nur USB 2.0 - LimeSDR USB braucht USB 3.0 +
  Strom; fuer 4G ist der Pi 3 sehr knapp (kleine PRB-Bandbreite waehlen).
=====================================================================
EOF
exit 0
__G90NET_PAYLOAD__
IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwojID09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PQojICBnOTBuZXQgLSBlaWdlbmVz
IEdTTSgyRyktIHVuZCBMVEUoNEcpLVZlcnN1Y2hzbmV0eiBtaXQgV2Vib2JlcmZsYWVjaGUKIyAg
Mkc6IE9zbW9jb20uIDRHOiBzcnNFTkIgKEZ1bmspICsgT3BlbjVHUyAoS2VybikuIEplIE5ldHog
ZWluIGVpZ2VuZXIKIyAgTGltZVNEUiAoQXVzd2FobCBpbSBXZWJpbnRlcmZhY2UpLiBNb2R1cyAi
TFRFICsgR1NNIiA9IENTRkI6IEhhbmR5IGJ1Y2h0CiMgIGluIDRHIChJbnRlcm5ldCkgZWluLCBB
bnJ1ZmUgZmFsbGVuIHVlYmVyIFNHcyBrdXJ6IGF1ZiBHU00genVydWVjay4KIyAgU0lNcyB3ZXJk
ZW4gbnVyIGVpbm1hbCBlaW5nZXRyYWdlbiAob3Ntby1obHIgKyBPcGVuNUdTLUhTUyBhdXRvbWF0
aXNjaCkuCiMKIyAgISEhICBOVVIgYW4gRHVtbXkgTG9hZCAvIEthYmVsICsgRGFlbXBmdW5nIC8g
Z2VzY2hpcm10IGJldHJlaWJlbi4KIyAgICAgICBFaW4gb2ZmZW5lcyBOZXR6IG9obmUgQXV0aGVu
dGlzaWVydW5nID0gSU1TSS1DYXRjaGVyLCB3ZW5uIGVzCiMgICAgICAgYWJzdHJhaGx0LiBOdXIg
ZWlnZW5lIFRlc3QtU0lNcy4gVGVzdGtlbm51bmcgMDAxLzAxIG9kZXIgOTk5Lzk5LgojID09PT09
PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
PT09PT09PQppbXBvcnQgb3MsIHJlLCBzeXMsIGpzb24sIHRpbWUsIHNodXRpbCwgc29ja2V0LCB0
aHJlYWRpbmcsIHN1YnByb2Nlc3MKZnJvbSBodHRwLnNlcnZlciBpbXBvcnQgQmFzZUhUVFBSZXF1
ZXN0SGFuZGxlciwgVGhyZWFkaW5nSFRUUFNlcnZlcgoKIyAtLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0gS29uZmlnCkNPTkYg
PSBvcy5lbnZpcm9uLmdldCgiRzkwTkVUX0NPTkYiLCAiL2V0Yy9nOTBuZXQuY29uZiIpCldPUktE
SVIgPSBvcy5lbnZpcm9uLmdldCgiRzkwTkVUX1dPUktESVIiLCAiL3Zhci9saWIvZzkwbmV0IikK
T1NNT19DRkcgPSAiL2V0Yy9vc21vY29tIgpTUlNfQ0ZHID0gIi9ldGMvc3JzcmFuIgoKREVGQVVM
VFMgPSB7CiAgICAiV0VCX1BPUlQiOiAiODA4MCIsCiAgICAjIGdlbWVpbnNhbQogICAgIlRFQ0gi
OiAiZ3NtIiwgICAgICAgICAgICAjIHp1bGV0enQgZ2VzdGFydGV0CiAgICAiTUNDIjogIjAwMSIs
ICJNTkMiOiAiMDEiLCAiTkVUTkFNRSI6ICJwS09NIiwgIk5FVE5BTUVfU0hPUlQiOiAicEtPTSIs
ICJTUE4iOiAicEtPTSIsCiAgICAiTklUWiI6ICIxIiwgICAgICAgICAgICAgICMgTmV0em5hbWUg
KyBVaHJ6ZWl0L1plaXR6b25lIGFucyBIYW5keSBzZW5kZW4gKEdTTTogTU0tSW5mbywgTFRFOiBF
TU0tSW5mbykKICAgICMgTGltZVNEUiBqZSBOZXR6IChTZXJpZW5udW1tZXIsIGxlZXIgPSBhdXRv
bWF0aXNjaCkKICAgICJHU01fREVWIjogIiIsICJMVEVfREVWIjogIiIsCiAgICAjIDJHCiAgICAi
R1NNX0FSRkNOIjogIjIwIiwgIkdTTV9UWF9HQUlOIjogIjUwIiwgIkdTTV9SWF9HQUlOIjogIjQ1
IiwKICAgICJHU01fT1BFTiI6ICIxIiwgIkdTTV9EQVRBIjogIjAiLCAiR1NNX1NJUCI6ICIwIiwg
IkdTTV9TSVBfUEVFUiI6ICIiLCAiR1NNX1NJUF9MT0NBTCI6ICIiLAogICAgIyBTTVMgKEJlZ3J1
ZXNzdW5nIGJlaW0gRWluYnVjaGVuICsgQmVzdGFldGlndW5nIGJlaSBOdW1tZXJudmVyZ2FiZSkK
ICAgICJHU01fU01TIjogIjEiLCAiR1NNX1NNU19GUk9NIjogIjEwMDAiLAogICAgIyB7ZXh0ZXJu
fSA9IFZvcndhaGwtQmxvY2sgKyBpbnRlcm5lIE51bW1lciAobGVlciA9IG51ciBkaWUgaW50ZXJu
ZSBOdW1tZXIpCiAgICAiR1NNX1NNU19FWFRQUkVGSVgiOiAiKzQ5IDY1MSA2MzU1NTUiLAogICAg
IkdTTV9TTVNfV0VMQ09NRSI6ICJXaWxsa29tbWVuIGltIHtuZXR6fSEgRHUgYmlzdCBqZXR6dCBl
aW5nZWJ1Y2h0LiA3MyIsCiAgICAiR1NNX1NNU19OVU1CRVIiOiAiRGVpbmUgUnVmbnVtbWVyIGlt
IHtuZXR6fS1OZXR6IGlzdCBqZXR6dCB7bnVtbWVyfS4gRXh0ZXJuIGVycmVpY2hiYXI6IHtleHRl
cm59IiwKICAgICMgNEcKICAgICJMVEVfRUFSRkNOIjogIjE1NzUiLCAiTFRFX05QUkIiOiAiMjUi
LCAiTFRFX1RYX0dBSU4iOiAiODAiLCAiTFRFX1JYX0dBSU4iOiAiNDAiLAogICAgIkxURV9BUE4i
OiAiaW50ZXJuZXQiLCAiTFRFX1RBQyI6ICI3IiwKfQoKZGVmIGxvYWRfY29uZigpOgogICAgYyA9
IGRpY3QoREVGQVVMVFMpCiAgICB0cnk6CiAgICAgICAgZm9yIGxpbmUgaW4gb3BlbihDT05GKToK
ICAgICAgICAgICAgbGluZSA9IGxpbmUuc3RyaXAoKQogICAgICAgICAgICBpZiBub3QgbGluZSBv
ciBsaW5lLnN0YXJ0c3dpdGgoIiMiKSBvciAiPSIgbm90IGluIGxpbmU6CiAgICAgICAgICAgICAg
ICBjb250aW51ZQogICAgICAgICAgICBrLCB2ID0gbGluZS5zcGxpdCgiPSIsIDEpCiAgICAgICAg
ICAgIGNbay5zdHJpcCgpXSA9IHYuc3RyaXAoKS5zdHJpcCgnIicpCiAgICBleGNlcHQgRXhjZXB0
aW9uOgogICAgICAgIHBhc3MKICAgIHJldHVybiBjCgpkZWYgc2F2ZV9jb25mKGMpOgogICAgdHJ5
OgogICAgICAgIG9zLm1ha2VkaXJzKG9zLnBhdGguZGlybmFtZShDT05GKSwgZXhpc3Rfb2s9VHJ1
ZSkKICAgICAgICB3aXRoIG9wZW4oQ09ORiwgInciKSBhcyBmOgogICAgICAgICAgICBmLndyaXRl
KCIjIGc5MG5ldCAtIGF1dG9tYXRpc2NoIGdlc2NocmllYmVuXG4iKQogICAgICAgICAgICBmb3Ig
ayBpbiBzb3J0ZWQoYyk6CiAgICAgICAgICAgICAgICBmLndyaXRlKCclcz0iJXMiXG4nICUgKGss
IGNba10pKQogICAgZXhjZXB0IEV4Y2VwdGlvbiBhcyBlOgogICAgICAgIGxvZygiY29uZiBzcGVp
Y2hlcm46IiwgZSkKCkMgPSBsb2FkX2NvbmYoKQpvcy5tYWtlZGlycyhXT1JLRElSLCBleGlzdF9v
az1UcnVlKQoKZGVmIGNzZXQoaywgdik6CiAgICBDW2tdID0gc3RyKHYpCiAgICBzYXZlX2NvbmYo
QykKCmRlZiBsb2coKmEpOgogICAgcHJpbnQodGltZS5zdHJmdGltZSgiJUg6JU06JVMiKSwgKmEs
IGZsdXNoPVRydWUpCgpGQUtFID0gIi0tZmFrZSIgaW4gc3lzLmFyZ3YgICAjIFRlc3Rtb2R1cyBv
aG5lIGVjaHRlIEhhcmR3YXJlL1Byb3plc3NlCgojIC0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLSBGcmVxdWVuemVuIChBbnpl
aWdlKQpkZWYgYXJmY25fYmFuZChhKToKICAgIGEgPSBpbnQoYSkKICAgIGlmIDEgPD0gYSA8PSAx
MjQ6ICAgcmV0dXJuICJHU005MDAiCiAgICBpZiA1MTIgPD0gYSA8PSA4ODU6IHJldHVybiAiRENT
MTgwMCIKICAgIGlmIDEyOCA8PSBhIDw9IDI1MTogcmV0dXJuICJHU004NTAiCiAgICBpZiA5NzUg
PD0gYSA8PSAxMDIzOnJldHVybiAiRUdTTTkwMCIKICAgIHJldHVybiAiR1NNOTAwIgoKZGVmIGFy
ZmNuX21oeihhKToKICAgIGEgPSBpbnQoYSkKICAgIGlmIDEgPD0gYSA8PSAxMjQ6ICAgIHJldHVy
biByb3VuZCg5MzUgKyAwLjIgKiBhLCAxKQogICAgaWYgNTEyIDw9IGEgPD0gODg1OiAgcmV0dXJu
IHJvdW5kKDE4MDUuMiArIDAuMiAqIChhIC0gNTEyKSwgMSkKICAgIGlmIDEyOCA8PSBhIDw9IDI1
MTogIHJldHVybiByb3VuZCg4NjkgKyAwLjIgKiAoYSAtIDEyOCksIDEpCiAgICByZXR1cm4gMC4w
CgpkZWYgZWFyZmNuX21oeihlKToKICAgIGUgPSBpbnQoZSkKICAgICMgQmFuZCAzICgxODAwKTog
REwgMTgwNS0xODgwLCBFQVJGQ04gMTIwMC0xOTQ5CiAgICBpZiAxMjAwIDw9IGUgPD0gMTk0OTog
cmV0dXJuIHJvdW5kKDE4MDUuMCArIDAuMSAqIChlIC0gMTIwMCksIDEpCiAgICAjIEJhbmQgMSAo
MjEwMCk6IEVBUkZDTiAwLTU5OQogICAgaWYgMCA8PSBlIDw9IDU5OTogICAgIHJldHVybiByb3Vu
ZCgyMTEwLjAgKyAwLjEgKiBlLCAxKQogICAgIyBCYW5kIDcgKDI2MDApOiAyNzUwLTM0NDkKICAg
IGlmIDI3NTAgPD0gZSA8PSAzNDQ5OiByZXR1cm4gcm91bmQoMjYyMC4wICsgMC4xICogKGUgLSAy
NzUwKSwgMSkKICAgICMgQmFuZCAyMCAoODAwKTogNjE1MC02NDQ5CiAgICBpZiA2MTUwIDw9IGUg
PD0gNjQ0OTogcmV0dXJuIHJvdW5kKDc5MS4wICsgMC4xICogKGUgLSA2MTUwKSwgMSkKICAgIHJl
dHVybiAwLjAKCmRlZiBlYXJmY25fYmFuZChlKToKICAgIGUgPSBpbnQoZSkKICAgIGlmIDAgPD0g
ZSA8PSA1OTk6ICAgICByZXR1cm4gMQogICAgaWYgMTIwMCA8PSBlIDw9IDE5NDk6IHJldHVybiAz
CiAgICBpZiAyNzUwIDw9IGUgPD0gMzQ0OTogcmV0dXJuIDcKICAgIGlmIDYxNTAgPD0gZSA8PSA2
NDQ5OiByZXR1cm4gMjAKICAgIHJldHVybiAzCgojIC0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLSBWVFktSGlsZmVuIChPc21v
Y29tKQpkZWYgdnR5KHBvcnQsIGNtZHMsIHRpbWVvdXQ9NCk6CiAgICBvdXQgPSBbXQogICAgdHJ5
OgogICAgICAgIHMgPSBzb2NrZXQuY3JlYXRlX2Nvbm5lY3Rpb24oKCIxMjcuMC4wLjEiLCBwb3J0
KSwgdGltZW91dD10aW1lb3V0KQogICAgICAgIHMuc2V0dGltZW91dCh0aW1lb3V0KQogICAgICAg
IHRpbWUuc2xlZXAoMC4yKQogICAgICAgIHRyeTogb3V0LmFwcGVuZChzLnJlY3YoNDA5NikuZGVj
b2RlKGVycm9ycz0icmVwbGFjZSIpKQogICAgICAgIGV4Y2VwdCBFeGNlcHRpb246IHBhc3MKICAg
ICAgICBmb3IgY21kIGluIGNtZHM6CiAgICAgICAgICAgIHMuc2VuZGFsbCgoY21kICsgIlxyXG4i
KS5lbmNvZGUoKSk7IHRpbWUuc2xlZXAoMC4zKQogICAgICAgICAgICB0cnk6IG91dC5hcHBlbmQo
cy5yZWN2KDgxOTIpLmRlY29kZShlcnJvcnM9InJlcGxhY2UiKSkKICAgICAgICAgICAgZXhjZXB0
IEV4Y2VwdGlvbjogcGFzcwogICAgICAgIHMuY2xvc2UoKQogICAgZXhjZXB0IEV4Y2VwdGlvbiBh
cyBlOgogICAgICAgIHJldHVybiAiVlRZLUZlaGxlcjogJXMiICUgZQogICAgcmV0dXJuICIiLmpv
aW4ob3V0KQoKSExSX1ZUWSA9IDQyNTgKTVNDX1ZUWSA9IDQyNTQgICAjIG9zbW8tbXNjIFRlbG5l
dC1WVFk6IFNNUyBzZW5kZW4gKyBlaW5nZWJ1Y2h0ZSBUZWlsbmVobWVyIGFiZnJhZ2VuCgpkZWYg
X3N1YihwYXRoLCBwYWlycyk6CiAgICBpZiBub3Qgb3MucGF0aC5pc2ZpbGUocGF0aCk6IHJldHVy
bgogICAgdCA9IG9wZW4ocGF0aCkucmVhZCgpCiAgICBmb3IgcGF0LCByZXAgaW4gcGFpcnM6CiAg
ICAgICAgdCA9IHJlLnN1YihwYXQsIHJlcCwgdCwgZmxhZ3M9cmUuTVVMVElMSU5FKQogICAgb3Bl
bihwYXRoLCAidyIpLndyaXRlKHQpCgpkZWYgX3Z0eV9zZXQocGF0aCwgbm9kZSwga2V5LCBmdWxs
KToKICAgIGlmIG5vdCBvcy5wYXRoLmlzZmlsZShwYXRoKTogcmV0dXJuCiAgICB0ID0gb3Blbihw
YXRoKS5yZWFkKCkKICAgIGlmIHJlLnNlYXJjaChyZiIoP20pXlxzKntrZXl9KFxzfCQpIiwgdCk6
CiAgICAgICAgdCA9IHJlLnN1YihyZiIoP20pXlxzKntrZXl9LiokIiwgIiAiICsgZnVsbCwgdCkK
ICAgIGVsc2U6CiAgICAgICAgdCA9IHJlLnN1YihyZiIoP20pXih7cmUuZXNjYXBlKG5vZGUpfVxz
KikkIiwgciJcMVxuICIgKyBmdWxsLCB0LCBjb3VudD0xKQogICAgb3BlbihwYXRoLCAidyIpLndy
aXRlKHQpCgpkZWYgX3Z0eV9kZWwocGF0aCwga2V5KToKICAgIGlmIG5vdCBvcy5wYXRoLmlzZmls
ZShwYXRoKTogcmV0dXJuCiAgICB0ID0gb3BlbihwYXRoKS5yZWFkKCkKICAgIG9wZW4ocGF0aCwg
InciKS53cml0ZShyZS5zdWIocmYiKD9tKV5ccyp7a2V5fS4qXG4/IiwgIiIsIHQpKQoKIyA9PT09
PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
PT09PT0gTGltZVNEUiBmcmVpIG1hY2hlbgpkZWYgX2xpbWVfc2VydmljZShhY3Rpb24pOgogICAg
aWYgRkFLRTogcmV0dXJuCiAgICBmb3Igc3ZjIGluICgiZzkwLWxpbWUiLCAiZzkwbGltZSIpOgog
ICAgICAgIHRyeToKICAgICAgICAgICAgc3VicHJvY2Vzcy5ydW4oWyJzeXN0ZW1jdGwiLCBhY3Rp
b24sIHN2YyArICIuc2VydmljZSJdLAogICAgICAgICAgICAgICAgICAgICAgICAgICBzdGRvdXQ9
c3VicHJvY2Vzcy5ERVZOVUxMLCBzdGRlcnI9c3VicHJvY2Vzcy5ERVZOVUxMLCB0aW1lb3V0PTEw
KQogICAgICAgIGV4Y2VwdCBFeGNlcHRpb246IHBhc3MKCmRlZiBfZnJlZV9saW1lKCk6CiAgICAi
IiJBbGxlcyBiZWVuZGVuLCB3YXMgZGVuIExpbWVTRFIgb2ZmZW4gaGFlbHQuIERpZSBVU0ItUGxh
dGluZSAoRlgzKSBOSUNIVCBoYXJ0CiAgICByZXNldGVuIChmYWVsbHQgc29uc3Qgdm9tIEJ1cyk7
IGJlaSBkZXIgTWluaSAoRlQ2MDEpIGhpbGZ0IGVpbiBVU0ItUmVzZXQuIiIiCiAgICBpZiBGQUtF
OiByZXR1cm4KICAgIGltcG9ydCBmY250bAogICAgZm9yIHZpZCwgcGlkLCBoYXJkIGluICgoIjA0
MDMiLCAiNjAxZiIsIFRydWUpLCAoIjFkNTAiLCAiNjEwOCIsIEZhbHNlKSk6CiAgICAgICAgdHJ5
OgogICAgICAgICAgICBvdXQgPSBzdWJwcm9jZXNzLnJ1bihbImxzdXNiIiwgIi1kIiwgZiJ7dmlk
fTp7cGlkfSJdLAogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBjYXB0dXJlX291dHB1
dD1UcnVlLCB0ZXh0PVRydWUsIHRpbWVvdXQ9NSkuc3Rkb3V0CiAgICAgICAgICAgIG0gPSByZS5z
ZWFyY2gociJCdXMgKFxkKykgRGV2aWNlIChcZCspIiwgb3V0KQogICAgICAgICAgICBpZiBub3Qg
bTogY29udGludWUKICAgICAgICAgICAgcGF0aCA9IGYiL2Rldi9idXMvdXNiL3ttLmdyb3VwKDEp
fS97bS5ncm91cCgyKX0iCiAgICAgICAgICAgIHRyeToKICAgICAgICAgICAgICAgIHN1YnByb2Nl
c3MucnVuKFsiZnVzZXIiLCAiLWsiLCBwYXRoXSwgc3Rkb3V0PXN1YnByb2Nlc3MuREVWTlVMTCwK
ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIHN0ZGVycj1zdWJwcm9jZXNzLkRFVk5VTEws
IHRpbWVvdXQ9NSk7IHRpbWUuc2xlZXAoMS4wKQogICAgICAgICAgICBleGNlcHQgRXhjZXB0aW9u
OiBwYXNzCiAgICAgICAgICAgIGlmIGhhcmQ6CiAgICAgICAgICAgICAgICB3aXRoIG9wZW4ocGF0
aCwgIndiIikgYXMgZjogZmNudGwuaW9jdGwoZiwgMHg1NTE0LCAwKQogICAgICAgIGV4Y2VwdCBF
eGNlcHRpb24gYXMgZToKICAgICAgICAgICAgbG9nKCJsaW1lIGZyZWk6IiwgZSkKCiMgPT09PT09
PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
PT09IExpbWVTRFItQXVzd2FobAojIEplIE5ldHogZWluIGVpZ2VuZXIgTGltZVNEUiAoei5CLiBM
aW1lU0RSIE1pbmkgZnVlciBHU00sIExpbWVTRFIgVVNCIGZ1ZXIgTFRFKS4KIyBadW9yZG51bmcg
dWViZXIgZGllIFNlcmllbm51bW1lciAoR1NNX0RFViAvIExURV9ERVYpLCBsZWVyID0gYXV0b21h
dGlzY2guCkxJTUVTID0gW10gICAgICAgICAgIyB6dWxldHp0IGdlZnVuZGVuZSBHZXJhZXRlIFt7
c2VyaWFsLCBuYW1lLCBtZWRpYSwgLi4ufV0KCmRlZiBsaW1lX3NjYW4oKToKICAgICIiIkFuZ2Vz
Y2hsb3NzZW5lIExpbWVTRFIgZmluZGVuIChMaW1lVXRpbCwgc29uc3QgU29hcHlTRFJVdGlsKS4i
IiIKICAgIGdsb2JhbCBMSU1FUwogICAgaWYgRkFLRToKICAgICAgICBMSU1FUyA9IFt7InNlcmlh
bCI6ICIxRDNBQzRGMUEyQjNDNCIsICJuYW1lIjogIkxpbWVTRFIgTWluaSIsICJtZWRpYSI6ICJV
U0IgMy4wIn0sCiAgICAgICAgICAgICAgICAgeyJzZXJpYWwiOiAiMDAwOTA3MDEwNUM2MjYyRSIs
ICJuYW1lIjogIkxpbWVTRFItVVNCIiwgIm1lZGlhIjogIlVTQiAzLjAifV0KICAgICAgICByZXR1
cm4gTElNRVMKICAgIGRldnMgPSBbXQogICAgdHJ5OgogICAgICAgIG91dCA9IHN1YnByb2Nlc3Mu
cnVuKFsiTGltZVV0aWwiLCAiLS1maW5kIl0sIGNhcHR1cmVfb3V0cHV0PVRydWUsIHRleHQ9VHJ1
ZSwgdGltZW91dD0yMCkuc3Rkb3V0CiAgICAgICAgZm9yIG0gaW4gcmUuZmluZGl0ZXIociJcWyhb
XlxdXSspXF0iLCBvdXQpOgogICAgICAgICAgICBwYXJ0cyA9IFtwLnN0cmlwKCkgZm9yIHAgaW4g
bS5ncm91cCgxKS5zcGxpdCgiLCIpXQogICAgICAgICAgICBkID0geyJuYW1lIjogcGFydHNbMF19
CiAgICAgICAgICAgIGZvciBwIGluIHBhcnRzWzE6XToKICAgICAgICAgICAgICAgIGlmICI9IiBp
biBwOgogICAgICAgICAgICAgICAgICAgIGssIHYgPSBwLnNwbGl0KCI9IiwgMSk7IGRbay5zdHJp
cCgpXSA9IHYuc3RyaXAoKQogICAgICAgICAgICBpZiBkLmdldCgic2VyaWFsIik6IGRldnMuYXBw
ZW5kKGQpCiAgICBleGNlcHQgRXhjZXB0aW9uIGFzIGU6CiAgICAgICAgbG9nKCJMaW1lVXRpbDoi
LCBlKQogICAgaWYgbm90IGRldnM6CiAgICAgICAgdHJ5OgogICAgICAgICAgICBvdXQgPSBzdWJw
cm9jZXNzLnJ1bihbIlNvYXB5U0RSVXRpbCIsICItLWZpbmQ9ZHJpdmVyPWxpbWUiXSwKICAgICAg
ICAgICAgICAgICAgICAgICAgICAgICAgICAgY2FwdHVyZV9vdXRwdXQ9VHJ1ZSwgdGV4dD1UcnVl
LCB0aW1lb3V0PTMwKS5zdGRvdXQKICAgICAgICAgICAgZm9yIGJsayBpbiByZS5zcGxpdChyIkZv
dW5kIGRldmljZSBcZCsiLCBvdXQpWzE6XToKICAgICAgICAgICAgICAgIGQgPSBkaWN0KChrLnN0
cmlwKCksIHYuc3RyaXAoKSkgZm9yIGssIHYgaW4gcmUuZmluZGFsbChyIig/bSleXHMqKFx3Kylc
cyo9XHMqKC4rKSQiLCBibGspKQogICAgICAgICAgICAgICAgaWYgZC5nZXQoInNlcmlhbCIpOgog
ICAgICAgICAgICAgICAgICAgIGRldnMuYXBwZW5kKHsic2VyaWFsIjogZFsic2VyaWFsIl0sICJt
ZWRpYSI6IGQuZ2V0KCJtZWRpYSIsICIiKSwKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
ICAgIm5hbWUiOiAoZC5nZXQoImxhYmVsIikgb3IgZC5nZXQoIm5hbWUiKSBvciAiTGltZVNEUiIp
LnNwbGl0KCJbIilbMF0uc3RyaXAoKX0pCiAgICAgICAgZXhjZXB0IEV4Y2VwdGlvbiBhcyBlOgog
ICAgICAgICAgICBsb2coIlNvYXB5U0RSVXRpbDoiLCBlKQogICAgc2VlbiA9IHNldCgpCiAgICBM
SU1FUyA9IFtkIGZvciBkIGluIGRldnMgaWYgbm90IChkWyJzZXJpYWwiXSBpbiBzZWVuIG9yIHNl
ZW4uYWRkKGRbInNlcmlhbCJdKSldCiAgICBsb2coIkxpbWVTRFIgZ2VmdW5kZW46IiwgIiwgIi5q
b2luKCIlcyAlcyIgJSAoZFsibmFtZSJdLCBkWyJzZXJpYWwiXSkgZm9yIGQgaW4gTElNRVMpIG9y
ICJrZWluZSIpCiAgICByZXR1cm4gTElNRVMKCmRlZiBsaW1lX2Fzc2lnbihtb2RlKToKICAgICIi
Iihnc21fc2VyaWFsLCBsdGVfc2VyaWFsKSBmdWVyIGRlbiBNb2R1cy4gTGVlcmUgV2FobCA9IGVy
c3RlcyBHZXJhZXQsIGRhcwogICAgbmljaHQgc2Nob24gZGVtIGFuZGVyZW4gTmV0eiBnZWhvZXJ0
LiIiIgogICAgZGV2cyA9IExJTUVTIG9yIGxpbWVfc2NhbigpCiAgICBzZXJpYWxzID0gW2RbInNl
cmlhbCJdIGZvciBkIGluIGRldnNdCiAgICBnID0gQy5nZXQoIkdTTV9ERVYiLCAiIikuc3RyaXAo
KTsgbCA9IEMuZ2V0KCJMVEVfREVWIiwgIiIpLnN0cmlwKCkKICAgIGZpcnN0ID0gbGFtYmRhIG90
aGVyOiBuZXh0KChzIGZvciBzIGluIHNlcmlhbHMgaWYgcyAhPSBvdGhlciksICIiKQogICAgaWYg
bW9kZSBpbiAoImdzbSIsICJjc2ZiIikgYW5kIG5vdCBnOiBnID0gZmlyc3QobCkKICAgIGlmIG1v
ZGUgaW4gKCJsdGUiLCAiY3NmYiIpIGFuZCBub3QgbDogbCA9IGZpcnN0KGcpCiAgICBpZiBtb2Rl
ID09ICJnc20iOiBsID0gIiIKICAgIGlmIG1vZGUgPT0gImx0ZSI6IGcgPSAiIgogICAgcmV0dXJu
IGcsIGwKCmRlZiBsaW1lX2xhYmVsKHNlcmlhbCk6CiAgICBmb3IgZCBpbiBMSU1FUzoKICAgICAg
ICBpZiBkWyJzZXJpYWwiXSA9PSBzZXJpYWw6CiAgICAgICAgICAgIHJldHVybiAiJXMgKCVzKSIg
JSAoZC5nZXQoIm5hbWUiLCAiTGltZVNEUiIpLCBzZXJpYWwpCiAgICByZXR1cm4gc2VyaWFsIG9y
ICLigJMiCgojID09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
PT09PT09PT09PT09PT09PT09PSBPc21vY29tLUZhZWhpZ2tlaXRlbgpfVlRZUkVGID0ge30KZGVm
IG9zbW9faGFzKGJpbmFyeSwgd29yZCk6CiAgICAiIiJUcnVlL0ZhbHNlLCBvYiBlaW4gT3Ntb2Nv
bS1Qcm9ncmFtbSBlaW5lbiBWVFktQmVmZWhsIGtlbm50OyBOb25lID0gdW5iZWthbm50LiIiIgog
ICAgaWYgYmluYXJ5IG5vdCBpbiBfVlRZUkVGOgogICAgICAgIHRyeToKICAgICAgICAgICAgX1ZU
WVJFRltiaW5hcnldID0gc3VicHJvY2Vzcy5ydW4oW2JpbmFyeSwgIi0tdnR5LXJlZi14bWwiXSwg
Y2FwdHVyZV9vdXRwdXQ9VHJ1ZSwKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
ICAgICAgICAgdGV4dD1UcnVlLCB0aW1lb3V0PTE1KS5zdGRvdXQKICAgICAgICBleGNlcHQgRXhj
ZXB0aW9uOgogICAgICAgICAgICBfVlRZUkVGW2JpbmFyeV0gPSAiIgogICAgcmVmID0gX1ZUWVJF
RltiaW5hcnldCiAgICBpZiAiPHZ0eWRvYyIgbm90IGluIHJlZjogcmV0dXJuIE5vbmUKICAgIHJl
dHVybiByZS5zZWFyY2gocidpZD1bIlwnXSVzXGInICUgcmUuZXNjYXBlKHdvcmQpLCByZWYpIGlz
IG5vdCBOb25lCgpkZWYgdHpfbm93KCk6CiAgICAiIiJaZWl0em9uZSBmdWVyIE5JVFo6IChTdHVu
ZGVuLCBNaW51dGVuLCBTb21tZXJ6ZWl0IDAvMSkgb2huZSBEU1QtQW50ZWlsLiIiIgogICAgbHQg
PSB0aW1lLmxvY2FsdGltZSgpCiAgICBkc3QgPSAxIGlmIGx0LnRtX2lzZHN0ID4gMCBlbHNlIDAK
ICAgIG9mZiA9IGx0LnRtX2dtdG9mZiAvLyA2MCAtIGRzdCAqIDYwCiAgICBoID0gaW50KG9mZiAv
IDYwKTsgbSA9IGFicyhvZmYpICUgNjAKICAgIHJldHVybiBoLCBtaW4oKDAsIDE1LCAzMCwgNDUp
LCBrZXk9bGFtYmRhIHg6IGFicyh4IC0gbSkpLCBkc3QKCiMgPT09PT09PT09PT09PT09PT09PT09
PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09IEdTTSAoT3Ntb2Nv
bSkKR1NNX0NPUkUgPSBbCiAgICAoInN0cCIsICJvc21vLXN0cCIsICJvc21vLXN0cC5jZmciKSwK
ICAgICgiaGxyIiwgIm9zbW8taGxyIiwgIm9zbW8taGxyLmNmZyIpLAogICAgKCJtZ3ciLCAib3Nt
by1tZ3ciLCAib3Ntby1tZ3cuY2ZnIiksCiAgICAoIm1zYyIsICJvc21vLW1zYyIsICJvc21vLW1z
Yy5jZmciKSwKICAgICgiYnNjIiwgIm9zbW8tYnNjIiwgIm9zbW8tYnNjLmNmZyIpLAogICAgKCJ0
cngiLCAib3Ntby10cngtbG1zIiwgIm9zbW8tdHJ4LWxtcy5jZmciKSwKICAgICgiYnRzIiwgIm9z
bW8tYnRzLXRyeCIsICJvc21vLWJ0cy10cnguY2ZnIiksCl0KR1NNX0RBVEEgPSBbCiAgICAoImdn
c24iLCAib3Ntby1nZ3NuIiwgIm9zbW8tZ2dzbi5jZmciKSwKICAgICgic2dzbiIsICJvc21vLXNn
c24iLCAib3Ntby1zZ3NuLmNmZyIpLAogICAgKCJwY3UiLCAgIm9zbW8tcGN1IiwgICJvc21vLXBj
dS5jZmciKSwKXQpHU01fU0lQID0gKCJzaXAiLCAib3Ntby1zaXAtY29ubmVjdG9yIiwgIm9zbW8t
c2lwLWNvbm5lY3Rvci5jZmciKQpHU01fTk9ORkFUQUwgPSB7Imdnc24iLCAic2dzbiIsICJwY3Ui
LCAic2lwIiwgIm5yZiIsICJzY3AiLCAicGtvbSJ9Ck9TTU9fU0VSVklDRVMgPSBbIm9zbW8tc3Rw
IiwgIm9zbW8taGxyIiwgIm9zbW8tbWd3IiwgIm9zbW8tbXNjIiwgIm9zbW8tYnNjIiwKICAgICAg
ICAgICAgICAgICAib3Ntby1idHMtdHJ4IiwgIm9zbW8tdHJ4LWxtcyIsICJvc21vLXNpcC1jb25u
ZWN0b3IiLAogICAgICAgICAgICAgICAgICJvc21vLXBjdSIsICJvc21vLXNnc24iLCAib3Ntby1n
Z3NuIl0KCmRlZiBnc21fY29tcG9uZW50cygpOgogICAgY29tcHMgPSBsaXN0KEdTTV9DT1JFKQog
ICAgaWYgQ1siR1NNX0RBVEEiXSA9PSAiMSI6IGNvbXBzICs9IEdTTV9EQVRBCiAgICBpZiBDWyJH
U01fU0lQIl0gPT0gIjEiIGFuZCBDWyJHU01fU0lQX1BFRVIiXTogY29tcHMgKz0gW0dTTV9TSVBd
CiAgICByZXR1cm4gY29tcHMKCmRlZiBfdGFpbHNjYWxlX2lwKCk6CiAgICB0cnk6CiAgICAgICAg
b3V0ID0gc3VicHJvY2Vzcy5ydW4oWyJ0YWlsc2NhbGUiLCAiaXAiLCAiLTQiXSwgY2FwdHVyZV9v
dXRwdXQ9VHJ1ZSwgdGV4dD1UcnVlLCB0aW1lb3V0PTUpLnN0ZG91dAogICAgICAgIGZvciBsaW5l
IGluIG91dC5zcGxpdGxpbmVzKCk6CiAgICAgICAgICAgIGlwID0gbGluZS5zdHJpcCgpCiAgICAg
ICAgICAgIGlmIHJlLm1hdGNoKHIiMTAwXC5cZCtcLlxkK1wuXGQrJCIsIGlwKTogcmV0dXJuIGlw
CiAgICBleGNlcHQgRXhjZXB0aW9uOiBwYXNzCiAgICByZXR1cm4gIjAuMC4wLjAiCgpkZWYgX2dw
cnNfYmxvY2sobSk6CiAgICBpID0gbS5ncm91cCgxKQogICAgTCA9IFsiZ3BycyBtb2RlIGVncHJz
IiwgImdwcnMgcm91dGluZyBhcmVhIDAiLCAiZ3BycyBuZXR3b3JrLWNvbnRyb2wtb3JkZXIgbmMw
IiwKICAgICAgICAgImdwcnMgY2VsbCBidmNpIDEyMzQiLCAiZ3BycyBuc2VpIDEyMzQiLCAiZ3By
cyBuc3ZjIDAgbnN2Y2kgMTIzNCIsCiAgICAgICAgICJncHJzIG5zdmMgMCBsb2NhbCB1ZHAgcG9y
dCAyMzAwMSIsICJncHJzIG5zdmMgMCByZW1vdGUgdWRwIHBvcnQgMjMwMDAiLAogICAgICAgICAi
Z3BycyBuc3ZjIDAgcmVtb3RlIGlwIDEyNy4wLjAuMSJdCiAgICByZXR1cm4gaSArICgiXG4iICsg
aSkuam9pbihMKQoKZGVmIGdzbV9wcmVwYXJlKCk6CiAgICBmb3IgX24sIF9iLCBjZmcgaW4gZ3Nt
X2NvbXBvbmVudHMoKToKICAgICAgICBzcmMgPSBvcy5wYXRoLmpvaW4oT1NNT19DRkcsIGNmZykK
ICAgICAgICBpZiBvcy5wYXRoLmlzZmlsZShzcmMpOiBzaHV0aWwuY29weShzcmMsIG9zLnBhdGgu
am9pbihXT1JLRElSLCBjZmcpKQogICAgYXJmY24sIG1jYywgbW5jID0gaW50KENbIkdTTV9BUkZD
TiJdKSwgQ1siTUNDIl0sIENbIk1OQyJdCiAgICBkYXRhX29uID0gQ1siR1NNX0RBVEEiXSA9PSAi
MSI7IG9wZW5fcmVnID0gQ1siR1NNX09QRU4iXSA9PSAiMSIKICAgIGJzYyA9IG9zLnBhdGguam9p
bihXT1JLRElSLCAib3Ntby1ic2MuY2ZnIikKICAgIHJ1bGVzID0gWwogICAgICAgIChyIl4oXHMq
bmV0d29yayBjb3VudHJ5IGNvZGVccyspXGQrIiwgciJcZzwxPiIgKyBtY2MpLAogICAgICAgIChy
Il4oXHMqbW9iaWxlIG5ldHdvcmsgY29kZVxzKylcZCsiLCByIlxnPDE+IiArIG1uYyksCiAgICAg
ICAgKHIiXihccypiYW5kXHMrKVxTKyIsIHIiXGc8MT4iICsgYXJmY25fYmFuZChhcmZjbikpLAog
ICAgICAgIChyIl4oXHMqYXJmY25ccyspXGQrIiwgciJcZzwxPiIgKyBzdHIoYXJmY24pKSwKICAg
ICAgICAociJeKFxzKm1heF9wb3dlcl9yZWRccyspXGQrIiwgciJcZzwxPjAiKSwKICAgIF0KICAg
IGlmIG5vdCBkYXRhX29uOgogICAgICAgIHJ1bGVzLmFwcGVuZCgociJeKFxzKmdwcnMgbW9kZVxz
KylcUysiLCByIlxnPDE+bm9uZSIpKQogICAgX3N1Yihic2MsIHJ1bGVzKQogICAgaWYgZGF0YV9v
bjoKICAgICAgICB0ID0gb3Blbihic2MpLnJlYWQoKQogICAgICAgIHQgPSByZS5zdWIociIoP20p
XlxzKmdwcnMgKHJvdXRpbmcgYXJlYXxuZXR3b3JrLWNvbnRyb2wtb3JkZXJ8Y2VsbHxuc2VpfG5z
dmMpXGIuKlxuPyIsICIiLCB0KQogICAgICAgIHQgPSByZS5zdWIociIoP20pXihccyopZ3BycyBt
b2RlXHMrXFMrLiokIiwgX2dwcnNfYmxvY2ssIHQsIGNvdW50PTEpCiAgICAgICAgZm9yIHRzIGlu
ICgiNSIsICI2IiwgIjciKToKICAgICAgICAgICAgdCA9IHJlLnN1YihyZiIoP20pKF5ccyp0aW1l
c2xvdCB7dHN9XHMqXG5ccypwaHlzX2NoYW5fY29uZmlnXHMrKVRDSC9GXHMqJCIsIHIiXGc8MT5U
Q0gvRl9QRENIIiwgdCkKICAgICAgICBvcGVuKGJzYywgInciKS53cml0ZSh0KQogICAgIyBNU0M6
IEtlbm51bmcgKyBOYW1lCiAgICBfc3ViKG9zLnBhdGguam9pbihXT1JLRElSLCAib3Ntby1tc2Mu
Y2ZnIiksIFsKICAgICAgICAociJeKFxzKm5ldHdvcmsgY291bnRyeSBjb2RlXHMrKVxkKyIsIHIi
XGc8MT4iICsgbWNjKSwKICAgICAgICAociJeKFxzKm1vYmlsZSBuZXR3b3JrIGNvZGVccyspXGQr
IiwgciJcZzwxPiIgKyBtbmMpLAogICAgXSkKICAgIG1zYyA9IG9zLnBhdGguam9pbihXT1JLRElS
LCAib3Ntby1tc2MuY2ZnIik7IGhsciA9IG9zLnBhdGguam9pbihXT1JLRElSLCAib3Ntby1obHIu
Y2ZnIikKICAgIF92dHlfZGVsKG1zYywgImF1dGhlbnRpY2F0aW9uIikKICAgICMgTmV0em5hbWUg
KyBOSVRaOiBNTS1JbmZvcm1hdGlvbiBtaXQgTmFtZSwgVWhyemVpdCB1bmQgWmVpdHpvbmUgYW5z
IEhhbmR5CiAgICB3b3JkID0gbGFtYmRhIHM6IHJlLnN1YihyIlteXHcuKy1dIiwgIi0iLCBzIG9y
ICJwS09NIikgICAgICAjIFZUWTogZWluIFdvcnQKICAgIF92dHlfc2V0KG1zYywgIm5ldHdvcmsi
LCAic2hvcnQgbmFtZSIsICJzaG9ydCBuYW1lICIgKyB3b3JkKEMuZ2V0KCJORVROQU1FX1NIT1JU
Iikgb3IgQ1siTkVUTkFNRSJdKSkKICAgIF92dHlfc2V0KG1zYywgIm5ldHdvcmsiLCAibG9uZyBu
YW1lIiwgImxvbmcgbmFtZSAiICsgd29yZChDWyJORVROQU1FIl0pKQogICAgaWYgQy5nZXQoIk5J
VFoiLCAiMSIpID09ICIxIjoKICAgICAgICBfdnR5X3NldChtc2MsICJuZXR3b3JrIiwgIm1tIGlu
Zm8iLCAibW0gaW5mbyAxIikKICAgICAgICBpZiBvc21vX2hhcygib3Ntby1tc2MiLCAidGltZXpv
bmUiKToKICAgICAgICAgICAgX3Z0eV9zZXQobXNjLCAibmV0d29yayIsICJ0aW1lem9uZSIsICJ0
aW1lem9uZSAlZCAlZCAlZCIgJSB0el9ub3coKSkKICAgIGVsc2U6CiAgICAgICAgX3Z0eV9zZXQo
bXNjLCAibmV0d29yayIsICJtbSBpbmZvIiwgIm1tIGluZm8gMCIpCiAgICAgICAgX3Z0eV9kZWwo
bXNjLCAidGltZXpvbmUiKQogICAgIyBTR3MgenVyIE9wZW41R1MtTU1FIChudXIgaW0gTW9kdXMg
TFRFICsgR1NNKQogICAgdCA9IG9wZW4obXNjKS5yZWFkKCkKICAgIHQgPSByZS5zdWIociIoP20p
XnNnc1sgXHRdKlxuKD86WyBcdF0rLiooPzpcbnwkKSkqIiwgIiIsIHQpCiAgICBpZiBORVQudGVj
aCA9PSAiY3NmYiI6CiAgICAgICAgdCA9IHQucnN0cmlwKCJcbiIpICsgIlxuc2dzXG4gbG9jYWwt
cG9ydCAlZFxuIGxvY2FsLWlwIDEyNy4wLjAuMVxuIHZsci1uYW1lIHZsci5wa29tLnRlc3RcbiIg
JSBTR1NfUE9SVAogICAgb3Blbihtc2MsICJ3Iikud3JpdGUodCkKICAgICMgZWlnZW5lciBMaW1l
U0RSIGZ1ZXIgR1NNIChvc21vLXRyeC1sbXMgd2FlaGx0IHBlciBUZWlsc3RyaW5nIGRlciBHZXJh
ZXRlbGlzdGUpCiAgICB0cnggPSBvcy5wYXRoLmpvaW4oV09SS0RJUiwgIm9zbW8tdHJ4LWxtcy5j
ZmciKQogICAgaWYgb3MucGF0aC5pc2ZpbGUodHJ4KToKICAgICAgICBpZiBORVQuZGV2X2dzbToK
ICAgICAgICAgICAgX3Z0eV9zZXQodHJ4LCAidHJ4IiwgImRldi1hcmdzIiwgImRldi1hcmdzIHNl
cmlhbD0iICsgTkVULmRldl9nc20pCiAgICAgICAgZWxzZToKICAgICAgICAgICAgX3Z0eV9kZWwo
dHJ4LCAiZGV2LWFyZ3MiKQogICAgaWYgb3Blbl9yZWc6CiAgICAgICAgX3Z0eV9zZXQoaGxyLCAi
aGxyIiwgInN1YnNjcmliZXItY3JlYXRlLW9uLWRlbWFuZCIsICJzdWJzY3JpYmVyLWNyZWF0ZS1v
bi1kZW1hbmQgbm8tbXNpc2RuIGNzK3BzIikKICAgIGVsc2U6CiAgICAgICAgX3Z0eV9kZWwoaGxy
LCAic3Vic2NyaWJlci1jcmVhdGUtb24tZGVtYW5kIikKICAgICMgUlgtR2FpbiAoaW5zdGFuY2Ut
S25vdGVuIGRlciBvc21vLWJ0cy10cnguY2ZnKQogICAgYnRzID0gb3MucGF0aC5qb2luKFdPUktE
SVIsICJvc21vLWJ0cy10cnguY2ZnIikKICAgIGlmIG9zLnBhdGguaXNmaWxlKGJ0cyk6CiAgICAg
ICAgYnQgPSBvcGVuKGJ0cykucmVhZCgpOyByZyA9IGludChDWyJHU01fUlhfR0FJTiJdKQogICAg
ICAgIGlmIHJlLnNlYXJjaChyIig/bSleXHMqb3Ntb3RyeCByeC1nYWluXGIiLCBidCk6CiAgICAg
ICAgICAgIGJ0ID0gcmUuc3ViKHIiKD9tKV4oXHMqb3Ntb3RyeCByeC1nYWluXHMrKS4qJCIsIHIi
XGc8MT4lZCIgJSByZywgYnQpCiAgICAgICAgZWxzZToKICAgICAgICAgICAgYnQgPSByZS5zdWIo
ciIoP20pXihccyppbnN0YW5jZSAwXHMqKSQiLCByIlwxXG4gIG9zbW90cnggcngtZ2FpbiAlZCIg
JSByZywgYnQsIGNvdW50PTEpCiAgICAgICAgb3BlbihidHMsICJ3Iikud3JpdGUoYnQpCiAgICAj
IFNJUC1UcnVuawogICAgaWYgQ1siR1NNX1NJUCJdID09ICIxIiBhbmQgQ1siR1NNX1NJUF9QRUVS
Il06CiAgICAgICAgX3Z0eV9zZXQobXNjLCAibXNjIiwgIm1uY2MiLCAibW5jYyBleHRlcm5hbCAv
dG1wL21uY2Muc29jayIpCiAgICAgICAgbG9jYWwgPSBDLmdldCgiR1NNX1NJUF9MT0NBTCIpIG9y
IF90YWlsc2NhbGVfaXAoKQogICAgICAgIHdpdGggb3Blbihvcy5wYXRoLmpvaW4oV09SS0RJUiwg
Im9zbW8tc2lwLWNvbm5lY3Rvci5jZmciKSwgInciKSBhcyBmOgogICAgICAgICAgICBmLndyaXRl
KCJtbmNjXG4gc29ja2V0LXBhdGggL3RtcC9tbmNjLnNvY2tcbnNpcFxuIGxvY2FsICVzIDUwNjBc
biByZW1vdGUgJXMgNTA2MFxuIgogICAgICAgICAgICAgICAgICAgICUgKGxvY2FsLCBDWyJHU01f
U0lQX1BFRVIiXSkpCiAgICBlbHNlOgogICAgICAgIF92dHlfc2V0KG1zYywgIm1zYyIsICJtbmNj
IiwgIm1uY2MgaW50ZXJuYWwiKQogICAgaWYgZGF0YV9vbiBhbmQgb3Blbl9yZWc6CiAgICAgICAg
X3Z0eV9zZXQob3MucGF0aC5qb2luKFdPUktESVIsICJvc21vLXNnc24uY2ZnIiksICJzZ3NuIiwg
ImF1dGgtcG9saWN5IiwgImF1dGgtcG9saWN5IGFjY2VwdC1hbGwiKQoKIyAtLS0tIFNJTXM6IEVJ
TkUgTGlzdGUgZnVlciBiZWlkZSBOZXR6ZQojIEVpbmdldHJhZ2VuIHdpcmQgbnVyIGhpZXI7IHBL
T00gc2NocmVpYnQgamVkZSBTSU0gYXV0b21hdGlzY2ggaW5zIG9zbW8taGxyIChHU00pCiMgdW5k
IGluIGRlbiBPcGVuNUdTLUhTUyAoTFRFLCBNb25nb0RCKS4gS2kvT1BjIHZlcmxhc3NlbiBkZW4g
UmVjaG5lciBuaWUKIyAoZGllIFdlYm9iZXJmbGFlY2hlIGJla29tbXQgbnVyIElNU0kgKyBSdWZu
dW1tZXIgenVydWVjaykuClNJTVNfRklMRSA9IG9zLnBhdGguam9pbihXT1JLRElSLCAic2ltcy5q
c29uIikKCmRlZiBzaW1zX2xvYWQoKToKICAgIHRyeTogcmV0dXJuIGpzb24ubG9hZChvcGVuKFNJ
TVNfRklMRSkpCiAgICBleGNlcHQgRXhjZXB0aW9uOiByZXR1cm4ge30KCmRlZiBzaW1zX3NhdmUo
ZCk6CiAgICB0cnk6CiAgICAgICAgdG1wID0gU0lNU19GSUxFICsgIi50bXAiCiAgICAgICAgd2l0
aCBvcGVuKHRtcCwgInciKSBhcyBmOiBqc29uLmR1bXAoZCwgZiwgaW5kZW50PTEpCiAgICAgICAg
b3MuY2htb2QodG1wLCAwbzYwMCk7IG9zLnJlcGxhY2UodG1wLCBTSU1TX0ZJTEUpCiAgICBleGNl
cHQgRXhjZXB0aW9uIGFzIGU6CiAgICAgICAgbG9nKCJzaW1zOiIsIGUpCgpkZWYgZ3NtX29uKCk6
CiAgICByZXR1cm4gTkVULnRlY2ggaW4gKCJnc20iLCAiY3NmYiIpCgpkZWYgbHRlX29uKCk6CiAg
ICByZXR1cm4gTkVULnRlY2ggaW4gKCJsdGUiLCAiY3NmYiIpCgpkZWYgX2hleDMyKHgpOgogICAg
cmV0dXJuIHJlLnN1YihyIlteMC05YS1mQS1GXSIsICIiLCB4IG9yICIiKS51cHBlcigpCgpkZWYg
aGxyX3B1dChpbXNpLCBzKToKICAgIGlmIEZBS0U6IHJldHVybiBOb25lCiAgICByID0gdnR5KEhM
Ul9WVFksIFsiZW5hYmxlIiwgZiJzdWJzY3JpYmVyIGltc2kge2ltc2l9IGNyZWF0ZSIsCiAgICAg
ICAgICAgICAgICAgICAgICBmInN1YnNjcmliZXIgaW1zaSB7aW1zaX0gdXBkYXRlIG1zaXNkbiB7
cy5nZXQoJ21zaXNkbicpIG9yIGltc2lbLTg6XX0iLAogICAgICAgICAgICAgICAgICAgICAgZiJz
dWJzY3JpYmVyIGltc2kge2ltc2l9IHVwZGF0ZSBhdWQzZyBtaWxlbmFnZSBrIHtzWydraSddfSBv
cGMge3NbJ29wYyddfSJdKQogICAgcmV0dXJuIE5vbmUgaWYgIiUgIiBub3QgaW4gci5yZXBsYWNl
KCIlIFN1YnNjcmliZXIgYWxyZWFkeSBleGlzdHMiLCAiIikgZWxzZSByLnN0cmlwKClbLTE2MDpd
CgpkZWYgX2hzcygpOgogICAgaW1wb3J0IHB5bW9uZ28KICAgIHJldHVybiBweW1vbmdvLk1vbmdv
Q2xpZW50KCJtb25nb2RiOi8vMTI3LjAuMC4xLyIsIHNlcnZlclNlbGVjdGlvblRpbWVvdXRNUz0z
MDAwKVsib3BlbjVncyJdWyJzdWJzY3JpYmVycyJdCgpkZWYgaHNzX3B1dChpbXNpLCBzKToKICAg
ICIiIlNJTSBpbiBkZW4gT3BlbjVHUy1IU1Mgc2NocmVpYmVuIChhbmxlZ2VuIG9kZXIgYWt0dWFs
aXNpZXJlbiwgU1FOIGJsZWlidCkuIiIiCiAgICBpZiBGQUtFOiByZXR1cm4gTm9uZQogICAgdHJ5
OgogICAgICAgIGZyb20gYnNvbi5pbnQ2NCBpbXBvcnQgSW50NjQKICAgICAgICBhbWJyID0geyJk
b3dubGluayI6IHsidmFsdWUiOiAxLCAidW5pdCI6IDN9LCAidXBsaW5rIjogeyJ2YWx1ZSI6IDEs
ICJ1bml0IjogM319ICAgIyAxIEdiaXQvcwogICAgICAgIHNlc3MgPSB7Im5hbWUiOiBDLmdldCgi
TFRFX0FQTiIpIG9yICJpbnRlcm5ldCIsICJ0eXBlIjogMywgICAgICAgICAgIyAzID0gSVB2NHY2
CiAgICAgICAgICAgICAgICAicW9zIjogeyJpbmRleCI6IDksICJhcnAiOiB7InByaW9yaXR5X2xl
dmVsIjogOCwgInByZV9lbXB0aW9uX2NhcGFiaWxpdHkiOiAxLAogICAgICAgICAgICAgICAgICAg
ICAgICAgICAgICAgICAgICAgICAgICAgICJwcmVfZW1wdGlvbl92dWxuZXJhYmlsaXR5IjogMX19
LAogICAgICAgICAgICAgICAgImFtYnIiOiBhbWJyLCAicGNjX3J1bGUiOiBbXX0KICAgICAgICBf
aHNzKCkudXBkYXRlX29uZSh7Imltc2kiOiBpbXNpfSwgewogICAgICAgICAgICAiJHNldCI6IHsi
aW1zaSI6IGltc2ksICJtc2lzZG4iOiBbc1sibXNpc2RuIl1dIGlmIHMuZ2V0KCJtc2lzZG4iKSBl
bHNlIFtdLAogICAgICAgICAgICAgICAgICAgICAic2VjdXJpdHkuayI6IHNbImtpIl0sICJzZWN1
cml0eS5vcGMiOiBzWyJvcGMiXSwgInNlY3VyaXR5Lm9wIjogTm9uZSwKICAgICAgICAgICAgICAg
ICAgICAgInNlY3VyaXR5LmFtZiI6ICI4MDAwIiwgImFtYnIiOiBhbWJyLAogICAgICAgICAgICAg
ICAgICAgICAic2xpY2UiOiBbeyJzc3QiOiAxLCAiZGVmYXVsdF9pbmRpY2F0b3IiOiBUcnVlLCAi
c2Vzc2lvbiI6IFtzZXNzXX1dLAogICAgICAgICAgICAgICAgICAgICAiYWNjZXNzX3Jlc3RyaWN0
aW9uX2RhdGEiOiAzMiwgInN1YnNjcmliZXJfc3RhdHVzIjogMCwKICAgICAgICAgICAgICAgICAg
ICAgIm9wZXJhdG9yX2RldGVybWluZWRfYmFycmluZyI6IDAsCiAgICAgICAgICAgICAgICAgICAg
ICJuZXR3b3JrX2FjY2Vzc19tb2RlIjogMCwgICAgICAgICMgMCA9IFBha2V0ICsgTGVpdHVuZyAt
PiBrb21iaW5pZXJ0ZXIgQXR0YWNoIChDU0ZCKQogICAgICAgICAgICAgICAgICAgICAic3Vic2Ny
aWJlZF9yYXVfdGF1X3RpbWVyIjogMTJ9LAogICAgICAgICAgICAiJHNldE9uSW5zZXJ0IjogeyJz
ZWN1cml0eS5zcW4iOiBJbnQ2NCg5NyksICJpbWVpc3YiOiBbXSwgIm1tZV9ob3N0IjogW10sCiAg
ICAgICAgICAgICAgICAgICAgICAgICAgICAgIm1tZV9yZWFsbSI6IFtdLCAicHVyZ2VfZmxhZyI6
IFtdLCAiX192IjogMH19LCB1cHNlcnQ9VHJ1ZSkKICAgICAgICByZXR1cm4gTm9uZQogICAgZXhj
ZXB0IEltcG9ydEVycm9yOgogICAgICAgIHJldHVybiAicHl0aG9uMy1weW1vbmdvIGZlaGx0IChJ
bnN0YWxsZXIgZXJuZXV0IGF1c2Z1ZWhyZW4pIgogICAgZXhjZXB0IEV4Y2VwdGlvbiBhcyBlOgog
ICAgICAgIHJldHVybiAiSFNTL01vbmdvREI6ICVzIiAlIHN0cihlKVs6MTIwXQoKZGVmIGhzc19k
ZWwoaW1zaSk6CiAgICBpZiBGQUtFOiByZXR1cm4KICAgIHRyeTogX2hzcygpLmRlbGV0ZV9vbmUo
eyJpbXNpIjogaW1zaX0pCiAgICBleGNlcHQgRXhjZXB0aW9uIGFzIGU6IGxvZygiaHNzIGxvZXNj
aGVuOiIsIGUpCgpkZWYgaHNzX3N5bmNfYWxsKCk6CiAgICBlcnJzID0gW2UgZm9yIGUgaW4gKGhz
c19wdXQoaSwgcykgZm9yIGksIHMgaW4gc2ltc19sb2FkKCkuaXRlbXMoKSkgaWYgZV0KICAgIHJl
dHVybiBlcnJzWzBdIGlmIGVycnMgZWxzZSBOb25lCgpkZWYgc2ltX2FkZChpbXNpLCBraSwgb3Bj
LCBtc2lzZG4pOgogICAgaW1zaSA9IHJlLnN1YihyIlxEIiwgIiIsIGltc2kgb3IgIiIpOyBraSA9
IF9oZXgzMihraSk7IG9wYyA9IF9oZXgzMihvcGMpCiAgICBpZiBsZW4oaW1zaSkgPCAxNCBvciBs
ZW4oa2kpICE9IDMyIG9yIGxlbihvcGMpICE9IDMyOgogICAgICAgIHJldHVybiAiSU1TSSAoMTUg
WmlmZmVybiksIEtpIHVuZCBPUGMgKGplIDMyIEhleCkgcHJ1ZWZlbiIKICAgIG1zaXNkbiA9IHJl
LnN1YihyIlxEIiwgIiIsIG1zaXNkbiBvciAiIikgb3IgbnVtc19sb2FkKCkuZ2V0KGltc2kpIG9y
IGltc2lbLTg6XQogICAgZCA9IHNpbXNfbG9hZCgpOyBkW2ltc2ldID0geyJraSI6IGtpLCAib3Bj
Ijogb3BjLCAibXNpc2RuIjogbXNpc2RufTsgc2ltc19zYXZlKGQpCiAgICBuID0gbnVtc19sb2Fk
KCk7IG5baW1zaV0gPSBtc2lzZG47IG51bXNfc2F2ZShuKSAgICAgICAgICAjIFJ1Zm51bW1lciBk
YXVlcmhhZnQKICAgIGVycnMgPSBbXQogICAgZSA9IGhzc19wdXQoaW1zaSwgZFtpbXNpXSkKICAg
IGlmIGU6IGVycnMuYXBwZW5kKGUpCiAgICBpZiBnc21fb24oKSBhbmQgbm90IEZBS0U6CiAgICAg
ICAgZSA9IGhscl9wdXQoaW1zaSwgZFtpbXNpXSkKICAgICAgICBpZiBlOiBlcnJzLmFwcGVuZCgi
SExSOiAiICsgZSkKICAgICAgICBlbHNlOiBzbXNfc2VuZChpbXNpLCBfc21zX3RleHQoQy5nZXQo
IkdTTV9TTVNfTlVNQkVSIiwgIiIpLCBudW1tZXI9bXNpc2RuKSkKICAgIHJldHVybiAoIlNJTSBn
ZXNwZWljaGVydCwgYWJlcjogIiArICI7ICIuam9pbihlcnJzKSkgaWYgZXJycyBlbHNlIE5vbmUK
CmRlZiBzaW1fZGVsKGltc2kpOgogICAgaW1zaSA9IHJlLnN1YihyIlxEIiwgIiIsIGltc2kgb3Ig
IiIpCiAgICBkID0gc2ltc19sb2FkKCkKICAgIGlmIGltc2kgaW4gZDoKICAgICAgICBkZWwgZFtp
bXNpXTsgc2ltc19zYXZlKGQpCiAgICBoc3NfZGVsKGltc2kpCiAgICBpZiBnc21fb24oKSBhbmQg
bm90IEZBS0U6CiAgICAgICAgdnR5KEhMUl9WVFksIFsiZW5hYmxlIiwgZiJzdWJzY3JpYmVyIGlt
c2kge2ltc2l9IGRlbGV0ZSJdKQoKZGVmIF9taWdyYXRlX2x0ZV9kYigpOgogICAgIiIiQWx0ZSBz
cnNFUEMtTGlzdGUgKHVzZXJfZGIuY3N2KSBlaW5tYWxpZyBpbiBkaWUgZ2VtZWluc2FtZSBTSU0t
TGlzdGUgdWViZXJuZWhtZW4uIiIiCiAgICB1ZGIgPSBvcy5wYXRoLmpvaW4oV09SS0RJUiwgInVz
ZXJfZGIuY3N2IikKICAgIGlmIG5vdCBvcy5wYXRoLmlzZmlsZSh1ZGIpOiByZXR1cm4KICAgIGQg
PSBzaW1zX2xvYWQoKTsgbnVtcyA9IG51bXNfbG9hZCgpOyBuID0gMAogICAgZm9yIGwgaW4gb3Bl
bih1ZGIpLnJlYWQoKS5zcGxpdGxpbmVzKCk6CiAgICAgICAgZiA9IGwuc3BsaXQoIiwiKQogICAg
ICAgIGlmIGxlbihmKSA+PSA1IGFuZCBub3QgbC5zdGFydHN3aXRoKCIjIikgYW5kIGZbMF0gbm90
IGluIGQgYW5kIGxlbihfaGV4MzIoZlszXSkpID09IDMyOgogICAgICAgICAgICBkW2ZbMF1dID0g
eyJraSI6IF9oZXgzMihmWzNdKSwgIm9wYyI6IF9oZXgzMihmWzRdKSwgIm1zaXNkbiI6IG51bXMu
Z2V0KGZbMF0sICIiKX07IG4gKz0gMQogICAgaWYgbjogc2ltc19zYXZlKGQpCiAgICB0cnk6IG9z
LnJlcGxhY2UodWRiLCB1ZGIgKyAiLmFsdCIpCiAgICBleGNlcHQgRXhjZXB0aW9uOiBwYXNzCiAg
ICBsb2coZiJ7bn0gU0lNKHMpIGF1cyBkZXIgYWx0ZW4gc3JzRVBDLUxpc3RlIHVlYmVybm9tbWVu
IikKCiMgRGF1ZXJoYWZ0ZSBJTVNJLT5SdWZudW1tZXItWnV3ZWlzdW5nZW4gKHVlYmVybGViZW4g
TmV1c3RhcnRzLCB3ZXJkZW4gYmVpIGplZGVtCiMgR1NNLVN0YXJ0IGVybmV1dCBpbnMgSExSIGdl
c2NocmllYmVuIC0gYXVjaCBmdWVyIG9mZmVuIGFuZ2VtZWxkZXRlIFNJTXMgb2huZSBLaSkuCk5V
TVNfRklMRSA9IG9zLnBhdGguam9pbihXT1JLRElSLCAibnVtYmVycy5qc29uIikKCmRlZiBudW1z
X2xvYWQoKToKICAgIHRyeTogcmV0dXJuIGpzb24ubG9hZChvcGVuKE5VTVNfRklMRSkpCiAgICBl
eGNlcHQgRXhjZXB0aW9uOiByZXR1cm4ge30KCmRlZiBudW1zX3NhdmUoZCk6CiAgICB0cnk6IGpz
b24uZHVtcChkLCBvcGVuKE5VTVNfRklMRSwgInciKSkKICAgIGV4Y2VwdCBFeGNlcHRpb24gYXMg
ZTogbG9nKCJudW1iZXJzOiIsIGUpCgpkZWYgZ3NtX2FwcGx5X251bWJlcnMoKToKICAgICIiIkJl
aW0gR1NNLVN0YXJ0OiBhbGxlIFNJTXMgKG1pdCBTY2hsdWVzc2VsKSArIFJ1Zm51bW1lcm4gaW5z
IEhMUiBzY2hyZWliZW4uIiIiCiAgICBpZiBGQUtFOiByZXR1cm4KICAgIGZvciBpbXNpLCBzIGlu
IHNpbXNfbG9hZCgpLml0ZW1zKCk6CiAgICAgICAgZSA9IGhscl9wdXQoaW1zaSwgcykKICAgICAg
ICBpZiBlOiBsb2coImhscjoiLCBpbXNpLCBlKQogICAgZCA9IG51bXNfbG9hZCgpCiAgICBpZiBu
b3QgZDogcmV0dXJuCiAgICBjbWRzID0gWyJlbmFibGUiXQogICAgZm9yIGltc2ksIG1zaXNkbiBp
biBkLml0ZW1zKCk6CiAgICAgICAgY21kcyArPSBbZiJzdWJzY3JpYmVyIGltc2kge2ltc2l9IGNy
ZWF0ZSIsIGYic3Vic2NyaWJlciBpbXNpIHtpbXNpfSB1cGRhdGUgbXNpc2RuIHttc2lzZG59Il0K
ICAgIHZ0eShITFJfVlRZLCBjbWRzKQoKZGVmIGdzbV9zaW1fbnIoaW1zaSwgbXNpc2RuKToKICAg
IGltc2kgPSByZS5zdWIociJcRCIsICIiLCBpbXNpKTsgbXNpc2RuID0gcmUuc3ViKHIiXEQiLCAi
IiwgbXNpc2RuKQogICAgaWYgbGVuKGltc2kpIDwgMTQgb3Igbm90IG1zaXNkbjogcmV0dXJuICJJ
TVNJICgxNSBaaWZmZXJuKSB1bmQgUnVmbnVtbWVyIHBydWVmZW4iCiAgICBkID0gbnVtc19sb2Fk
KCk7IGRbaW1zaV0gPSBtc2lzZG47IG51bXNfc2F2ZShkKSAgICAgICAgIyBkYXVlcmhhZnQgbWVy
a2VuCiAgICBzID0gc2ltc19sb2FkKCkKICAgIGlmIGltc2kgaW4gczogICAgICAgICAgICAgICAg
ICAgICAgICAgICAgICAgICAgICAgICAgICAgIyBTSU0gbWl0IFNjaGx1ZXNzZWw6IGF1Y2ggaW0g
SFNTCiAgICAgICAgc1tpbXNpXVsibXNpc2RuIl0gPSBtc2lzZG47IHNpbXNfc2F2ZShzKTsgaHNz
X3B1dChpbXNpLCBzW2ltc2ldKQogICAgaWYgbm90IEZBS0UgYW5kIGdzbV9vbigpOiAgICAgICAg
ICAgICAgICAgICAgICAgICAgICAgICAjIHNvZm9ydCBhbndlbmRlbiwgd2VubiBHU00gbGFldWZ0
CiAgICAgICAgdnR5KEhMUl9WVFksIFsiZW5hYmxlIiwgZiJzdWJzY3JpYmVyIGltc2kge2ltc2l9
IGNyZWF0ZSIsCiAgICAgICAgICAgICAgICAgICAgICBmInN1YnNjcmliZXIgaW1zaSB7aW1zaX0g
dXBkYXRlIG1zaXNkbiB7bXNpc2RufSJdKQogICAgICAgIHNtc19zZW5kKGltc2ksIF9zbXNfdGV4
dChDLmdldCgiR1NNX1NNU19OVU1CRVIiLCAiIiksIG51bW1lcj1tc2lzZG4pKQogICAgcmV0dXJu
IE5vbmUKCmRlZiBnc21fbnVtX2RlbChpbXNpKToKICAgIGltc2kgPSByZS5zdWIociJcRCIsICIi
LCBpbXNpKTsgZCA9IG51bXNfbG9hZCgpCiAgICBpZiBpbXNpIGluIGQ6CiAgICAgICAgZGVsIGRb
aW1zaV07IG51bXNfc2F2ZShkKQogICAgaWYgbm90IEZBS0UgYW5kIGdzbV9vbigpOgogICAgICAg
IHZ0eShITFJfVlRZLCBbImVuYWJsZSIsIGYic3Vic2NyaWJlciBpbXNpIHtpbXNpfSB1cGRhdGUg
bXNpc2RuICJdKQoKIyAtLS0tIFNJTS1EYXRlaWVuIGZ1ZXIgZGFzIGVTSU0tUHJvZmlsIChPUEwg
LyBQTk4gLyBTUE4pCiMgRGllc2UgZHJlaSBEYXRlaWVuIGxpZWdlbiBhdWYgZGVyIFNJTSwgbmlj
aHQgaW0gTmV0ei4gcEtPTSBiZXJlY2huZXQgZGllIFdlcnRlCiMgcGFzc2VuZCB6dSBLZW5udW5n
ICsgTmV0em5hbWU7IHNpZSB3ZXJkZW4gaW0gZVNJTS1Qcm9maWwgZWluZ2V0cmFnZW4uCkdTTTcg
PSAoIkDCoyTCpcOow6nDucOsw7LDh1xuw5jDuFxyw4XDpc6UX86mzpPOm86pzqDOqM6jzpjOnlx4
MWLDhsOmw5/DiSAhXCIjwqQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8iCiAgICAgICAgIsKh
QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVrDhMOWw5HDnMKnwr9hYmNkZWZnaGlqa2xtbm9wcXJz
dHV2d3h5esOkw7bDscO8w6AiKQoKZGVmIGdzbTdfY29kZXMocyk6CiAgICByZXR1cm4gW0dTTTcu
aW5kZXgoY2gpIGlmIGNoIGluIEdTTTcgYW5kIGNoIG5vdCBpbiAiXG5cclx4MWIiIGVsc2UgMHgz
RiBmb3IgY2ggaW4gKHMgb3IgIiIpXQoKZGVmIGdzbTdfcGFjayhjb2Rlcyk6CiAgICBiaXRzID0g
biA9IDA7IG91dCA9IGJ5dGVhcnJheSgpCiAgICBmb3IgYyBpbiBjb2RlczoKICAgICAgICBiaXRz
IHw9IChjICYgMHg3RikgPDwgbjsgbiArPSA3CiAgICAgICAgd2hpbGUgbiA+PSA4OgogICAgICAg
ICAgICBvdXQuYXBwZW5kKGJpdHMgJiAweEZGKTsgYml0cyA+Pj0gODsgbiAtPSA4CiAgICBpZiBu
OiBvdXQuYXBwZW5kKGJpdHMgJiAweEZGKQogICAgcmV0dXJuIGJ5dGVzKG91dCksICg4IC0gKGxl
bihjb2RlcykgKiA3KSAlIDgpICUgOAoKZGVmIF9ubl9pZSh0YWcsIG5hbWUpOgogICAgIiIiTmV0
em5hbWUtSUUgKFRTIDI0LjAwOCAxMC41LjMuNWEpOiBHU00tNywgb2huZSBMYWVuZGVya3Vlcnpl
bC4iIiIKICAgIHBhY2tlZCwgc3BhcmUgPSBnc203X3BhY2soZ3NtN19jb2RlcyhuYW1lKSkKICAg
IGJvZHkgPSBieXRlcyhbMHg4MCB8IHNwYXJlXSkgKyBwYWNrZWQKICAgIHJldHVybiBieXRlcyhb
dGFnLCBsZW4oYm9keSldKSArIGJvZHkKCmRlZiBwbG1uX2JjZChtY2MsIG1uYyk6CiAgICBtMyA9
IG1uY1syXSBpZiBsZW4obW5jKSA9PSAzIGVsc2UgIkYiCiAgICByZXR1cm4gYnl0ZXMoW2ludCht
Y2NbMV0gKyBtY2NbMF0sIDE2KSwgaW50KG0zICsgbWNjWzJdLCAxNiksIGludChtbmNbMV0gKyBt
bmNbMF0sIDE2KV0pCgpkZWYgc2ltX2ZpbGVzKCk6CiAgICBtY2MsIG1uYyA9IEMuZ2V0KCJNQ0Mi
LCAiIiksIEMuZ2V0KCJNTkMiLCAiIikKICAgIGZ1bGwgPSBDLmdldCgiTkVUTkFNRSIpIG9yICJw
S09NIjsgc2hvcnQgPSBDLmdldCgiTkVUTkFNRV9TSE9SVCIpIG9yIGZ1bGwKICAgIHNwbiA9IChD
LmdldCgiU1BOIikgb3IgZnVsbClbOjE2XQogICAgdHJ5OiBwbG1uID0gcGxtbl9iY2QobWNjLCBt
bmMpCiAgICBleGNlcHQgRXhjZXB0aW9uOiBwbG1uID0gYiJceGZmXHhmZlx4ZmYiCiAgICBzcG5f
YiA9IGJ5dGVzKFsweDAwXSkgKyBieXRlcyhnc203X2NvZGVzKHNwbikpICsgYiJceGZmIiAqICgx
NiAtIGxlbihzcG4pKQogICAgcG5uID0gX25uX2llKDB4NDMsIGZ1bGwpICsgX25uX2llKDB4NDUs
IHNob3J0KQogICAgb3BsID0gcGxtbiArIGIiXHgwMFx4MDBceGZmXHhmZVx4MDEiICAgICAgICAg
ICMgTEFDL1RBQyAwMDAwLUZGRkUgLT4gUE5OLUVpbnRyYWcgMQogICAgaHggPSBsYW1iZGEgYjog
Yi5oZXgoKS51cHBlcigpCiAgICByZXR1cm4geyJzcG4iOiBoeChzcG5fYiksICJwbm4iOiBoeChw
bm4pLCAib3BsIjogaHgob3BsKSwgInBsbW4iOiBoeChwbG1uKSwKICAgICAgICAgICAgImhwbG1u
IjogbWNjICsgbW5jLCAic3BuX3RleHQiOiBzcG4sICJmdWxsIjogZnVsbCwgInNob3J0Ijogc2hv
cnR9CgojIC0tLS0gU01TIHVlYmVyIG9zbW8tbXNjIFZUWQojIERpZSBNU0MgcHVmZmVydCBNVC1T
TVMgaW4gaWhyZXIgREIgdW5kIHN0ZWxsdCBzaWUgYmVpbSBFaW5idWNoZW4genUgLSBkZXIKIyBU
ZWlsbmVobWVyIG11c3MgYmVpbSBTZW5kZW4gYWxzbyBuaWNodCB6d2luZ2VuZCBzY2hvbiBhbmdl
bWVsZGV0IHNlaW4uCiMgQWJzZW5kZXIgaXN0IGVpbmUgZnJlaWUgTnVtbWVyIChHU01fU01TX0ZS
T00pLCBrZWluIGVjaHRlciBUZWlsbmVobWVyIG5vZXRpZy4KZGVmIF9leHRlcm5fbnIobnVtbWVy
KToKICAgICIiIkludGVybmUgTnVtbWVyIC0+IGV4dGVybiBlcnJlaWNoYmFyZSBOdW1tZXIgKFZv
cndhaGwtQmxvY2sgKyBpbnRlcm5lIE51bW1lcikuIiIiCiAgICBudW1tZXIgPSByZS5zdWIociJc
RCIsICIiLCBudW1tZXIgb3IgIiIpCiAgICBpZiBub3QgbnVtbWVyOiByZXR1cm4gIiIKICAgIHBy
ZWYgPSBDLmdldCgiR1NNX1NNU19FWFRQUkVGSVgiLCAiIikuc3RyaXAoKQogICAgcmV0dXJuIChw
cmVmICsgbnVtbWVyKSBpZiBwcmVmIGVsc2UgbnVtbWVyCgpkZWYgX3Ntc190ZXh0KHRtcGwsIG51
bW1lcj0iIik6CiAgICB0ID0gKHRtcGwgb3IgIiIpLnJlcGxhY2UoIntuZXR6fSIsIEMuZ2V0KCJO
RVROQU1FIiwgIiIpKSBcCiAgICAgICAgICAgICAgICAgICAgLnJlcGxhY2UoIntleHRlcm59Iiwg
X2V4dGVybl9ucihudW1tZXIpKS5yZXBsYWNlKCJ7bnVtbWVyfSIsIG51bW1lcikKICAgIHQgPSBy
ZS5zdWIocidbXHJcblx0PyJdJywgIiAiLCB0KSAgICAgICAgICAjIFZUWS1aZWlsZToga2VpbmUg
VW1icnVlY2hlL1RhYnMvPy1IaWxmZS9RdW90ZXMKICAgIHJldHVybiByZS5zdWIociJccysiLCAi
ICIsIHQpLnN0cmlwKClbOjE2MF0KCmRlZiBzbXNfc2VuZChpbXNpLCB0ZXh0LCBmb3JjZT1GYWxz
ZSk6CiAgICBpbXNpID0gcmUuc3ViKHIiXEQiLCAiIiwgaW1zaSBvciAiIikKICAgIGlmIEZBS0Ug
b3Igbm90IGdzbV9vbigpIG9yIG5vdCBpbXNpIG9yIG5vdCB0ZXh0OgogICAgICAgIHJldHVybgog
ICAgaWYgQy5nZXQoIkdTTV9TTVMiLCAiMSIpICE9ICIxIiBhbmQgbm90IGZvcmNlOiAgICMgQXV0
by1TTVMgYXVzIChUZXN0IGlnbm9yaWVydCBkYXMpCiAgICAgICAgcmV0dXJuCiAgICBmcm0gPSBy
ZS5zdWIociJcRCIsICIiLCBDLmdldCgiR1NNX1NNU19GUk9NIiwgIiIpKSBvciAiMTAwMCIKICAg
IHIgPSB2dHkoTVNDX1ZUWSwgWyJlbmFibGUiLAogICAgICAgICAgICAgICAgICAgICAgZiJzdWJz
Y3JpYmVyIGltc2kge2ltc2l9IHNtcyBzZW5kZXIgbXNpc2RuIHtmcm19IHNlbmQge3RleHR9Il0p
CiAgICBpZiAiJSAiIGluIHI6CiAgICAgICAgbG9nKCJzbXMtZmVobGVyOiIsIChyLnN0cmlwKCku
c3BsaXRsaW5lcygpIG9yIFtyXSlbLTFdWzoxNDBdKQoKZGVmIHNtc190ZXN0KGltc2ksIHRleHQ9
IiIpOgogICAgaW1zaSA9IHJlLnN1YihyIlxEIiwgIiIsIGltc2kgb3IgIiIpCiAgICBpZiBsZW4o
aW1zaSkgPCAxNDogIHJldHVybiAiSU1TSSBhbmdlYmVuICgxNC0xNSBaaWZmZXJuKSIKICAgIGlm
IEZBS0U6ICAgICAgICAgICAgcmV0dXJuICJUZXN0bW9kdXMgKEZBS0UpOiBuaWNodHMgZ2VzZW5k
ZXQiCiAgICBpZiBub3QgZ3NtX29uKCk6IHJldHVybiAiR1NNLU5ldHogbGFldWZ0IG5pY2h0IChH
U00gb2RlciBMVEUgKyBHU00gc3RhcnRlbikiCiAgICB0eHQgPSBfc21zX3RleHQodGV4dCkgaWYg
KHRleHQgb3IgIiIpLnN0cmlwKCkgZWxzZSBfc21zX3RleHQoQy5nZXQoIkdTTV9TTVNfV0VMQ09N
RSIsICIiKSkKICAgIHNtc19zZW5kKGltc2ksIHR4dCwgZm9yY2U9VHJ1ZSkKICAgIHJldHVybiBm
IlRlc3QtU01TIGFuIHtpbXNpfSBnZXNlbmRldCIKCmRlZiBtc2NfYXR0YWNoZWQoKToKICAgICIi
IklNU0lzLCBkaWUgYWt0dWVsbCBpbiBkZXIgTVNDIChWTFIpIGVpbmdlYnVjaHQgc2luZC4iIiIK
ICAgIGlmIEZBS0Ugb3Igbm90IGdzbV9vbigpOgogICAgICAgIHJldHVybiBzZXQoKQogICAgdHh0
ID0gdnR5KE1TQ19WVFksIFsiZW5hYmxlIiwgInNob3cgc3Vic2NyaWJlciBjYWNoZSJdKQogICAg
cmV0dXJuIHNldChyZS5maW5kYWxsKHIiSU1TSVxEezAsM30oXGR7MTQsMTV9KSIsIHR4dCkpCgpk
ZWYgc21zX3dlbGNvbWVfd2F0Y2goKToKICAgICIiIkhpbnRlcmdydW5kOiBuZXVlIEVpbmJ1Y2h1
bmdlbiBlcmtlbm5lbiB1bmQgZWlubWFsaWcgYmVncnVlc3Nlbi4iIiIKICAgIHdoaWxlIFRydWU6
CiAgICAgICAgdHJ5OgogICAgICAgICAgICBpZiBnc21fb24oKSBhbmQgTkVULnN0YXRlID09ICJs
YWV1ZnQiIGFuZCBDLmdldCgiR1NNX1NNUyIsICIxIikgPT0gIjEiOgogICAgICAgICAgICAgICAg
Zm9yIGltc2kgaW4gbXNjX2F0dGFjaGVkKCkgLSBORVQud2VsY29tZWQ6CiAgICAgICAgICAgICAg
ICAgICAgTkVULndlbGNvbWVkLmFkZChpbXNpKSAgICAgICMgdm9yIGRlbSBTZW5kZW4gbWVya2Vu
OiBrZWluIFNwYW0gYmVpIEZlaGxlcgogICAgICAgICAgICAgICAgICAgIGxvZygid2lsbGtvbW1l
bnMtc21zIC0+IiwgaW1zaSkKICAgICAgICAgICAgICAgICAgICBzbXNfc2VuZChpbXNpLCBfc21z
X3RleHQoQy5nZXQoIkdTTV9TTVNfV0VMQ09NRSIsICIiKSkpCiAgICAgICAgZXhjZXB0IEV4Y2Vw
dGlvbiBhcyBlOgogICAgICAgICAgICBsb2coInNtcy13YXRjaDoiLCBlKQogICAgICAgIHRpbWUu
c2xlZXAoNikKCiMgPT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
PT09PT09PT09PT09PT09PT09PT09IExURTogc3JzRU5CIChGdW5rKSArIE9wZW41R1MgKEtlcm4p
CiMgT3BlbjVHUyBzdGF0dCBzcnNFUEMsIHdlaWwgbnVyIGRlc3NlbiBNTUUgZGllIFNHcy1TY2hu
aXR0c3RlbGxlIHp1ciBvc21vLW1zYwojIGhhdCAoQ1NGQikuIERpZSBPcGVuNUdTLURpZW5zdGUg
bGF1ZmVuIG5pY2h0IHVlYmVyIHN5c3RlbWQsIHNvbmRlcm4gd2VyZGVuIHZvbgojIHBLT00gbWl0
IGVpZ2VuZW4gS29uZmlncyBnZXN0YXJ0ZXQgKFZvcmxhZ2U6IC9ldGMvb3BlbjVncy8qLnlhbWwp
LgpPNV9FVEMgPSAiL2V0Yy9vcGVuNWdzIgpPNV9ESVIgPSBvcy5wYXRoLmpvaW4oV09SS0RJUiwg
Im9wZW41Z3MiKQpPNV9ORlMgPSBbKCJucmYiLCAib3BlbjVncy1ucmZkIiksICgic2NwIiwgIm9w
ZW41Z3Mtc2NwZCIpLCAoImhzcyIsICJvcGVuNWdzLWhzc2QiKSwKICAgICAgICAgICgicGNyZiIs
ICJvcGVuNWdzLXBjcmZkIiksICgic2d3YyIsICJvcGVuNWdzLXNnd2NkIiksICgic2d3dSIsICJv
cGVuNWdzLXNnd3VkIiksCiAgICAgICAgICAoInNtZiIsICJvcGVuNWdzLXNtZmQiKSwgKCJ1cGYi
LCAib3BlbjVncy11cGZkIiksICgibW1lIiwgIm9wZW41Z3MtbW1lZCIpXQpPNV9PUFRJT05BTCA9
IHsibnJmIiwgInNjcCJ9ClVFX05FVCwgVUVfR1cgPSAiMTAuNDUuMC4wLzE2IiwgIjEwLjQ1LjAu
MS8xNiIgICAgICAgIyBPcGVuNUdTLVN0YW5kYXJkIChzbWYvdXBmLnlhbWwpCk5QUkJfTUhaID0g
ezY6IDEuNCwgMTU6IDMsIDI1OiA1LCA1MDogMTAsIDc1OiAxNSwgMTAwOiAyMH0KU0dTX1BPUlQg
PSAyOTExOAoKZGVmIF9wbG1uX3dhbGsobywgbWNjLCBtbmMpOgogICAgIiIiSmVkZSBQTE1OLUFu
Z2FiZSAobWNjL21uYykgaW4gZWluZXIgT3BlbjVHUy1Lb25maWcgYXVmIGRpZSBlaWdlbmUgS2Vu
bnVuZyBzZXR6ZW4uIiIiCiAgICBpZiBpc2luc3RhbmNlKG8sIGRpY3QpOgogICAgICAgIGlmICJt
Y2MiIGluIG8gYW5kICJtbmMiIGluIG86CiAgICAgICAgICAgIG9bIm1jYyJdID0gbWNjOyBvWyJt
bmMiXSA9IG1uYyAgICAgICMgYWxzIFRleHQ6IGZ1ZWhyZW5kZSBOdWxsZW4gKyBNTkMtTGFlbmdl
IGJsZWliZW4KICAgICAgICBmb3IgdiBpbiBvLnZhbHVlcygpOiBfcGxtbl93YWxrKHYsIG1jYywg
bW5jKQogICAgZWxpZiBpc2luc3RhbmNlKG8sIGxpc3QpOgogICAgICAgIGZvciB2IGluIG86IF9w
bG1uX3dhbGsodiwgbWNjLCBtbmMpCgpkZWYgZ3NtX2xhYygpOgogICAgdHJ5OgogICAgICAgIHQg
PSBvcGVuKG9zLnBhdGguam9pbihXT1JLRElSLCAib3Ntby1ic2MuY2ZnIikpLnJlYWQoKQogICAg
ICAgIG0gPSByZS5zZWFyY2gociIoP20pXlxzKmxvY2F0aW9uX2FyZWFfY29kZVxzKyg/OmxhY1xz
Kyk/KDB4WzAtOWEtZkEtRl0rfFxkKykiLCB0KQogICAgICAgIGlmIG06IHJldHVybiBpbnQobS5n
cm91cCgxKSwgMCkKICAgIGV4Y2VwdCBFeGNlcHRpb246IHBhc3MKICAgIHJldHVybiAxCgpkZWYg
bzVfcHJlcGFyZShjc2ZiLCBldGM9TzVfRVRDLCBvdXRkaXI9TzVfRElSKToKICAgICIiIk9wZW41
R1MtS29uZmlncyBlcnpldWdlbi4gUnVlY2tnYWJlOiB7bmY6IChiaW5hcnksIHlhbWwtcGZhZCl9
IGluIFN0YXJ0cmVpaGVuZm9sZ2UuIiIiCiAgICBpbXBvcnQgeWFtbAogICAgb3MubWFrZWRpcnMo
b3V0ZGlyLCBleGlzdF9vaz1UcnVlKQogICAgbWNjLCBtbmMgPSBDWyJNQ0MiXSwgQ1siTU5DIl07
IHRhYyA9IGludChDLmdldCgiTFRFX1RBQyIpIG9yIDcpCiAgICBwbG1uID0geyJtY2MiOiBtY2Ms
ICJtbmMiOiBtbmN9CiAgICBvdXQgPSB7fQogICAgZm9yIG5mLCBiaW5hcnkgaW4gTzVfTkZTOgog
ICAgICAgIHNyYyA9IG9zLnBhdGguam9pbihldGMsIG5mICsgIi55YW1sIikKICAgICAgICBpZiBu
b3Qgb3MucGF0aC5pc2ZpbGUoc3JjKToKICAgICAgICAgICAgaWYgbmYgaW4gTzVfT1BUSU9OQUw6
IGNvbnRpbnVlCiAgICAgICAgICAgIHJhaXNlIFJ1bnRpbWVFcnJvcihmIntzcmN9IGZlaGx0IC0g
aXN0IE9wZW41R1MgaW5zdGFsbGllcnQ/IikKICAgICAgICBvID0geWFtbC5zYWZlX2xvYWQob3Bl
bihzcmMpKSBvciB7fQogICAgICAgIG8ucG9wKCJsb2dnZXIiLCBOb25lKSAgICAgICAgICAgICAg
ICAgICAgICAgIyBMb2cgbmFjaCBzdGRvdXQgLT4gUHJvdG9rb2xsLVRhYgogICAgICAgIF9wbG1u
X3dhbGsobywgbWNjLCBtbmMpCiAgICAgICAgaWYgbmYgPT0gIm1tZSI6CiAgICAgICAgICAgIG0g
PSBvLnNldGRlZmF1bHQoIm1tZSIsIHt9KQogICAgICAgICAgICBpZiBDLmdldCgiTklUWiIsICIx
IikgPT0gIjEiOiAgICAgICAgICAgIyBFTU0tSW5mb3JtYXRpb246IE5ldHpuYW1lICsgWmVpdC9a
ZWl0em9uZQogICAgICAgICAgICAgICAgbVsibmV0d29ya19uYW1lIl0gPSB7ImZ1bGwiOiBDWyJO
RVROQU1FIl0sICJzaG9ydCI6IEMuZ2V0KCJORVROQU1FX1NIT1JUIikgb3IgQ1siTkVUTkFNRSJd
fQogICAgICAgICAgICBlbHNlOgogICAgICAgICAgICAgICAgbS5wb3AoIm5ldHdvcmtfbmFtZSIs
IE5vbmUpCiAgICAgICAgICAgIHRhaSA9IG0uZ2V0KCJ0YWkiKQogICAgICAgICAgICB0YWlzID0g
dGFpIGlmIGlzaW5zdGFuY2UodGFpLCBsaXN0KSBlbHNlIChbdGFpXSBpZiBpc2luc3RhbmNlKHRh
aSwgZGljdCkgZWxzZSBbXSkKICAgICAgICAgICAgZm9yIHQgaW4gdGFpczogdFsidGFjIl0gPSB0
YWMKICAgICAgICAgICAgaWYgbm90IHRhaXM6IG1bInRhaSJdID0gW3sicGxtbl9pZCI6IGRpY3Qo
cGxtbiksICJ0YWMiOiB0YWN9XQogICAgICAgICAgICBuZXdfZm10ID0gaXNpbnN0YW5jZShtLmdl
dCgiczFhcCIpLCBkaWN0KSAgICMgT3BlbjVHUyA+PSAyLjcKICAgICAgICAgICAgby5wb3AoInNn
c2FwIiwgTm9uZSk7IG0ucG9wKCJzZ3NhcCIsIE5vbmUpCiAgICAgICAgICAgIGlmIGNzZmI6CiAg
ICAgICAgICAgICAgICBtcCA9IHsidGFpIjogeyJwbG1uX2lkIjogZGljdChwbG1uKSwgInRhYyI6
IHRhY30sCiAgICAgICAgICAgICAgICAgICAgICAibGFpIjogeyJwbG1uX2lkIjogZGljdChwbG1u
KSwgImxhYyI6IGdzbV9sYWMoKX19CiAgICAgICAgICAgICAgICBpZiBuZXdfZm10OgogICAgICAg
ICAgICAgICAgICAgIG1bInNnc2FwIl0gPSB7ImNsaWVudCI6IFt7ImFkZHJlc3MiOiAiMTI3LjAu
MC4xIiwgImxvY2FsX2FkZHJlc3MiOiAiMTI3LjAuMC4yIiwKICAgICAgICAgICAgICAgICAgICAg
ICAgICAgICAgICAgICAgICAgICAgICAgICJwb3J0IjogU0dTX1BPUlQsICJtYXAiOiBtcH1dfQog
ICAgICAgICAgICAgICAgZWxzZToKICAgICAgICAgICAgICAgICAgICBvWyJzZ3NhcCJdID0gW3si
YWRkciI6ICIxMjcuMC4wLjEiLCAicG9ydCI6IFNHU19QT1JULCAibWFwIjogbXB9XQogICAgICAg
IGRzdCA9IG9zLnBhdGguam9pbihvdXRkaXIsIG5mICsgIi55YW1sIikKICAgICAgICB3aXRoIG9w
ZW4oZHN0LCAidyIpIGFzIGY6CiAgICAgICAgICAgIHlhbWwuc2FmZV9kdW1wKG8sIGYsIGRlZmF1
bHRfZmxvd19zdHlsZT1GYWxzZSwgc29ydF9rZXlzPUZhbHNlLCBhbGxvd191bmljb2RlPVRydWUp
CiAgICAgICAgb3V0W25mXSA9IChiaW5hcnksIGRzdCkKICAgIHJldHVybiBvdXQKCmRlZiBfc3Jz
X3RlbXBsYXRlKG5hbWUpOgogICAgZm9yIHAgaW4gKG9zLnBhdGguam9pbihTUlNfQ0ZHLCBuYW1l
KSwgZiIvdXNyL3NoYXJlL3Nyc3Jhbi97bmFtZX0uZXhhbXBsZSIsCiAgICAgICAgICAgICAgZiIv
dXNyL3NoYXJlL3Nyc3Jhbi97bmFtZX0iLCBmIi91c3Ivc2hhcmUvZG9jL3Nyc3Jhbi9leGFtcGxl
cy97bmFtZX0uZXhhbXBsZSIpOgogICAgICAgIGlmIG9zLnBhdGguaXNmaWxlKHApOiByZXR1cm4g
cAogICAgcmV0dXJuIE5vbmUKCmRlZiBfZHJvcF9ibG9jayh0LCBuYW1lKToKICAgICIiImxpYmNv
bmZpZy1CbG9jayAnbmFtZSA9IHsgLi4uIH07JyBlbnRmZXJuZW4gKEtsYW1tZXJuIGdlemFlaGx0
KS4iIiIKICAgIG0gPSByZS5zZWFyY2gocmYiKD9tKV57bmFtZX1ccyo9XHMqXHt7IiwgdCkKICAg
IGlmIG5vdCBtOiByZXR1cm4gdAogICAgaSA9IHQuaW5kZXgoInsiLCBtLnN0YXJ0KCkpOyBkZXB0
aCA9IDAKICAgIGZvciBqIGluIHJhbmdlKGksIGxlbih0KSk6CiAgICAgICAgaWYgdFtqXSA9PSAi
eyI6IGRlcHRoICs9IDEKICAgICAgICBlbGlmIHRbal0gPT0gIn0iOgogICAgICAgICAgICBkZXB0
aCAtPSAxCiAgICAgICAgICAgIGlmIGRlcHRoID09IDA6CiAgICAgICAgICAgICAgICBrID0gaiAr
IDEKICAgICAgICAgICAgICAgIHdoaWxlIGsgPCBsZW4odCkgYW5kIHRba10gaW4gIiBcdDsiOiBr
ICs9IDEKICAgICAgICAgICAgICAgIHJldHVybiB0WzptLnN0YXJ0KCldICsgdFtrOl0KICAgIHJl
dHVybiB0CgpkZWYgX3NpX21hcHBpbmcodCwgYWRkNyk6CiAgICBkZWYgZihtKToKICAgICAgICBu
dW1zID0gW3guc3RyaXAoKSBmb3IgeCBpbiBtLmdyb3VwKDIpLnNwbGl0KCIsIikgaWYgeC5zdHJp
cCgpIGFuZCB4LnN0cmlwKCkgIT0gIjciXQogICAgICAgIGlmIGFkZDc6IG51bXMuYXBwZW5kKCI3
IikKICAgICAgICByZXR1cm4gbS5ncm91cCgxKSArICIsICIuam9pbihudW1zKSArIG0uZ3JvdXAo
MykKICAgIHJldHVybiByZS5zdWIociIoc2lfbWFwcGluZ19pbmZvXHMqPVxzKlxbXHMqKShbXlxd
XSo/KShccypcXSkiLCBmLCB0LCBjb3VudD0xKQoKZGVmIHNpYl9wYXRjaCh0LCBjc2ZiLCBhcmZj
bik6CiAgICAiIiJTSUI3IChHRVJBTi1OYWNoYmFyKSBudXIgaW0gQ1NGQi1Nb2R1czogc3JzRU5C
IHNjaGlja3QgZGFzIEhhbmR5IGJlaQogICAgZWluZW0gQW5ydWYgcGVyIFJSQy1SZWxlYXNlIG1p
dCBVbWxlaXR1bmcgYXVmIGdlbmF1IGRpZXNlIEdTTS1GcmVxdWVuei4iIiIKICAgIHQgPSBfZHJv
cF9ibG9jayh0LCAic2liNyIpCiAgICB0ID0gX3NpX21hcHBpbmcodCwgY3NmYikKICAgIGlmIGNz
ZmI6CiAgICAgICAgdCA9IHQucnN0cmlwKCkgKyBmIiIiCgovLyBwS09NOiBHU00tWmVsbGUgZnVl
ciBDUy1GYWxsYmFjayAoQW5ydWZlKQpzaWI3ID0Ke3sKICAgIHRfcmVzZWxfZ2VyYW4gPSAxOwog
ICAgY2Fycmllcl9mcmVxc19pbmZvX2xpc3QgPQogICAgKAogICAgICAgIHt7CiAgICAgICAgICAg
IGNlbGxfcmVzZWxfcHJpbyA9IDA7CiAgICAgICAgICAgIG5jY19wZXJtaXR0ZWQgPSAyNTU7CiAg
ICAgICAgICAgIHFfcnhfbGV2X21pbiA9IDA7CiAgICAgICAgICAgIHRocmVzaF94X2hpZ2ggPSAy
OwogICAgICAgICAgICB0aHJlc2hfeF9sb3cgPSAyOwogICAgICAgICAgICBzdGFydF9hcmZjbiA9
IHthcmZjbn07CiAgICAgICAgICAgIGJhbmRfaW5kID0gImRjczE4MDAiOwogICAgICAgICAgICBl
eHBsaWNpdF9saXN0X29mX2FyZmNucyA9ICgge2FyZmNufSApOwogICAgICAgIH19CiAgICApOwp9
fTsKIiIiCiAgICByZXR1cm4gdAoKZGVmIGVuYl9wcmVwYXJlKGNzZmIsIHNlcmlhbCk6CiAgICBm
b3IgZiBpbiAoInJyLmNvbmYiLCAic2liLmNvbmYiLCAicmIuY29uZiIpOgogICAgICAgIHAgPSBf
c3JzX3RlbXBsYXRlKGYpCiAgICAgICAgaWYgbm90IHA6IHJhaXNlIFJ1bnRpbWVFcnJvcihmInNy
c1JBTi1Wb3JsYWdlIHtmfSBmZWhsdCAtIGlzdCBzcnNyYW4gaW5zdGFsbGllcnQ/IikKICAgICAg
ICBzaHV0aWwuY29weShwLCBvcy5wYXRoLmpvaW4oV09SS0RJUiwgZikpCiAgICBlYXJmY24gPSBp
bnQoQ1siTFRFX0VBUkZDTiJdKTsgdGFjID0gaW50KEMuZ2V0KCJMVEVfVEFDIikgb3IgNykKICAg
IHJyID0gb3MucGF0aC5qb2luKFdPUktESVIsICJyci5jb25mIik7IHQgPSBvcGVuKHJyKS5yZWFk
KCkKICAgIHQgPSByZS5zdWIociIoP20pXihccyp0YWNccyo9XHMqKVteO10rOyIsIHIiXGc8MT4w
eCUwNFg7IiAlIHRhYywgdCwgY291bnQ9MSkKICAgIHQgPSByZS5zdWIociIoP20pXihccypkbF9l
YXJmY25ccyo9XHMqKVxkKzsiLCByIlxnPDE+JWQ7IiAlIGVhcmZjbiwgdCwgY291bnQ9MSkgICMg
MS4gPSBlaWdlbmUgWmVsbGUKICAgIG9wZW4ocnIsICJ3Iikud3JpdGUodCkKICAgIHNpYiA9IG9z
LnBhdGguam9pbihXT1JLRElSLCAic2liLmNvbmYiKQogICAgb3BlbihzaWIsICJ3Iikud3JpdGUo
c2liX3BhdGNoKG9wZW4oc2liKS5yZWFkKCksIGNzZmIsIGludChDWyJHU01fQVJGQ04iXSkpKQog
ICAgZGV2ID0gImRyaXZlcj1saW1lIiArICgiLHNlcmlhbD0iICsgc2VyaWFsIGlmIHNlcmlhbCBl
bHNlICIiKQogICAgb3Blbihvcy5wYXRoLmpvaW4oV09SS0RJUiwgImVuYi5jb25mIiksICJ3Iiku
d3JpdGUoZiIiIiMgcEtPTSAtIGF1dG9tYXRpc2NoIGVyemV1Z3QKW2VuYl0KZW5iX2lkID0gMHgx
OUIKbWNjID0ge0NbJ01DQyddfQptbmMgPSB7Q1snTU5DJ119Cm1tZV9hZGRyID0gMTI3LjAuMC4y
Cmd0cF9iaW5kX2FkZHIgPSAxMjcuMC4xLjEKczFjX2JpbmRfYWRkciA9IDEyNy4wLjEuMQpzMWNf
YmluZF9wb3J0ID0gMApuX3ByYiA9IHtpbnQoQ1snTFRFX05QUkInXSl9CgpbZW5iX2ZpbGVzXQpz
aWJfY29uZmlnID0ge3NpYn0KcnJfY29uZmlnID0ge3JyfQpyYl9jb25maWcgPSB7b3MucGF0aC5q
b2luKFdPUktESVIsICdyYi5jb25mJyl9CgpbcmZdCnR4X2dhaW4gPSB7Q1snTFRFX1RYX0dBSU4n
XX0KcnhfZ2FpbiA9IHtDWydMVEVfUlhfR0FJTiddfQpkZXZpY2VfbmFtZSA9IHNvYXB5CmRldmlj
ZV9hcmdzID0ge2Rldn0KCltsb2ddCmFsbF9sZXZlbCA9IHdhcm5pbmcKZmlsZW5hbWUgPSBzdGRv
dXQKIiIiKQoKZGVmIF9ydW4oKmNtZCk6CiAgICByZXR1cm4gc3VicHJvY2Vzcy5ydW4obGlzdChj
bWQpLCBzdGRvdXQ9c3VicHJvY2Vzcy5ERVZOVUxMLCBzdGRlcnI9c3VicHJvY2Vzcy5ERVZOVUxM
KS5yZXR1cm5jb2RlCgpkZWYgdWVfbmV0X3VwKCk6CiAgICAiIiJUdW5uZWwgZnVlciBkaWUgSGFu
ZHktRGF0ZW52ZXJiaW5kdW5nZW4gKyBOQVQgaW5zIEludGVybmV0LiIiIgogICAgX3J1bigibW9k
cHJvYmUiLCAic2N0cCIpCiAgICBfcnVuKCJpcCIsICJ0dW50YXAiLCAiYWRkIiwgIm5hbWUiLCAi
b2dzdHVuIiwgIm1vZGUiLCAidHVuIikKICAgIF9ydW4oImlwIiwgImFkZHIiLCAicmVwbGFjZSIs
IFVFX0dXLCAiZGV2IiwgIm9nc3R1biIpCiAgICBfcnVuKCJpcCIsICJsaW5rIiwgInNldCIsICJv
Z3N0dW4iLCAidXAiKQogICAgX3J1bigic3lzY3RsIiwgIi13IiwgIm5ldC5pcHY0LmlwX2Zvcndh
cmQ9MSIpCiAgICBmb3IgY2hrLCBhZGQgaW4gKChbIi10IiwgIm5hdCIsICItQyIsICJQT1NUUk9V
VElORyIsICItcyIsIFVFX05FVCwgIiEiLCAiLW8iLCAib2dzdHVuIiwgIi1qIiwgIk1BU1FVRVJB
REUiXSwKICAgICAgICAgICAgICAgICAgICAgIFsiLXQiLCAibmF0IiwgIi1BIiwgIlBPU1RST1VU
SU5HIiwgIi1zIiwgVUVfTkVULCAiISIsICItbyIsICJvZ3N0dW4iLCAiLWoiLCAiTUFTUVVFUkFE
RSJdKSwKICAgICAgICAgICAgICAgICAgICAgKFsiLUMiLCAiRk9SV0FSRCIsICItaSIsICJvZ3N0
dW4iLCAiLWoiLCAiQUNDRVBUIl0sIFsiLUkiLCAiRk9SV0FSRCIsICItaSIsICJvZ3N0dW4iLCAi
LWoiLCAiQUNDRVBUIl0pLAogICAgICAgICAgICAgICAgICAgICAoWyItQyIsICJGT1JXQVJEIiwg
Ii1vIiwgIm9nc3R1biIsICItaiIsICJBQ0NFUFQiXSwgWyItSSIsICJGT1JXQVJEIiwgIi1vIiwg
Im9nc3R1biIsICItaiIsICJBQ0NFUFQiXSkpOgogICAgICAgIGlmIF9ydW4oImlwdGFibGVzIiwg
KmNoaykgIT0gMDogX3J1bigiaXB0YWJsZXMiLCAqYWRkKQoKZGVmIGZyZXFfY2xhc2goKToKICAg
ICIiIkdTTS1UcmFlZ2VyIGRhcmYgbmljaHQgaW0gTFRFLUthbmFsIGxpZWdlbiAoZ2xlaWNoZXMg
QmFuZCAxODAwIE1IeikuIiIiCiAgICB0cnk6CiAgICAgICAgZyA9IGFyZmNuX21oeihpbnQoQ1si
R1NNX0FSRkNOIl0pKTsgbCA9IGVhcmZjbl9taHooaW50KENbIkxURV9FQVJGQ04iXSkpCiAgICAg
ICAgYncgPSBOUFJCX01IWi5nZXQoaW50KENbIkxURV9OUFJCIl0pLCA1KQogICAgICAgIGlmIGcg
YW5kIGwgYW5kIGFicyhnIC0gbCkgPCBidyAvIDIgKyAwLjM6CiAgICAgICAgICAgIHJldHVybiBm
IkdTTSB7Z30gTUh6IGxpZWd0IGltIExURS1LYW5hbCB7bH0gTUh6IMKxe2J3LzI6Z30gLSBhbmRl
cmUgQVJGQ04vRUFSRkNOIHdhZWhsZW4iCiAgICBleGNlcHQgRXhjZXB0aW9uOiBwYXNzCiAgICBy
ZXR1cm4gTm9uZQoKZGVmIHByZWZsaWdodChtb2RlKToKICAgIG1jYywgbW5jID0gQy5nZXQoIk1D
QyIsICIiKS5zdHJpcCgpLCBDLmdldCgiTU5DIiwgIiIpLnN0cmlwKCkKICAgIGlmIG5vdCByZS5m
dWxsbWF0Y2gociJcZHszfSIsIG1jYykgb3Igbm90IHJlLmZ1bGxtYXRjaChyIlxkezIsM30iLCBt
bmMpOgogICAgICAgIHJldHVybiAiTmV0emtlbm51bmcgcHJ1ZWZlbjogTUNDIDMgWmlmZmVybiwg
TU5DIDItMyBaaWZmZXJuIgogICAgaWYgbWNjIG5vdCBpbiAoIjAwMSIsICI5OTkiKToKICAgICAg
ICByZXR1cm4gIk51ciBUZXN0LS9Qcml2YXRrZW5udW5nZW46IE1DQyAwMDEgKFRlc3QpIG9kZXIg
OTk5IChwcml2YXQpIgogICAgZywgbCA9IGxpbWVfYXNzaWduKG1vZGUpCiAgICBpZiBtb2RlID09
ICJjc2ZiIjoKICAgICAgICBpZiBub3QgRkFLRSBhbmQgKG5vdCBnIG9yIG5vdCBsIG9yIGcgPT0g
bCk6CiAgICAgICAgICAgIHJldHVybiAiTFRFICsgR1NNIGJyYXVjaHQgendlaSB2ZXJzY2hpZWRl
bmUgTGltZVNEUiAtIGltIFRhYiBTdGV1ZXJ1bmcgenVvcmRuZW4iCiAgICAgICAgZSA9IGZyZXFf
Y2xhc2goKQogICAgICAgIGlmIGU6IHJldHVybiBlCiAgICBpZiBub3QgRkFLRToKICAgICAgICBu
ZWVkID0gW10KICAgICAgICBpZiBtb2RlIGluICgiZ3NtIiwgImNzZmIiKTogbmVlZCArPSBbYiBm
b3IgX24sIGIsIF9jIGluIEdTTV9DT1JFXQogICAgICAgIGlmIG1vZGUgaW4gKCJsdGUiLCAiY3Nm
YiIpOgogICAgICAgICAgICBuZWVkICs9IFsic3JzZW5iIl0gKyBbYiBmb3IgbmYsIGIgaW4gTzVf
TkZTIGlmIG5mIG5vdCBpbiBPNV9PUFRJT05BTF0KICAgICAgICAgICAgdHJ5OiBpbXBvcnQgeWFt
bCAgIyBub3FhCiAgICAgICAgICAgIGV4Y2VwdCBJbXBvcnRFcnJvcjogcmV0dXJuICJweXRob24z
LXlhbWwgZmVobHQgKEluc3RhbGxlciBlcm5ldXQgYXVzZnVlaHJlbikiCiAgICAgICAgbWlzcyA9
IFtiIGZvciBiIGluIG5lZWQgaWYgbm90IHNodXRpbC53aGljaChiKV0KICAgICAgICBpZiBtaXNz
OiByZXR1cm4gIkZlaGx0OiAiICsgIiwgIi5qb2luKG1pc3MpICsgIiAoSW5zdGFsbGVyIGVybmV1
dCBhdXNmdWVocmVuKSIKICAgICAgICBpZiBtb2RlID09ICJjc2ZiIiBhbmQgb3Ntb19oYXMoIm9z
bW8tbXNjIiwgInNncyIpIGlzIEZhbHNlOgogICAgICAgICAgICByZXR1cm4gIkRpZXNlIG9zbW8t
bXNjIGthbm4ga2VpbiBTR3MgKENTRkIpIC0gbmV1ZXJlIE9zbW9jb20tVmVyc2lvbiBub2V0aWci
CiAgICBORVQuZGV2X2dzbSwgTkVULmRldl9sdGUgPSBnLCBsCiAgICByZXR1cm4gTm9uZQoKIyA9
PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
PT09PT09PT0gTmV0ei1NYW5hZ2VyCk1PREVTID0geyJnc20iOiAiR1NNICgyRykiLCAibHRlIjog
IkxURSAoNEcpIiwgImNzZmIiOiAiTFRFICsgR1NNIChDU0ZCKSJ9CgpjbGFzcyBOZXQ6CiAgICBk
ZWYgX19pbml0X18oc2VsZik6CiAgICAgICAgc2VsZi5sb2NrID0gdGhyZWFkaW5nLlJMb2NrKCkK
ICAgICAgICBzZWxmLnRlY2ggPSBOb25lICAgICAgICAgICMgTm9uZSB8ICJnc20iIHwgImx0ZSIg
fCAiY3NmYiIKICAgICAgICBzZWxmLnN0YXRlID0gImF1cyIgICAgICAgICMgYXVzIHwgc3RhcnRl
dCB8IGxhZXVmdCB8IGZlaGxlcgogICAgICAgIHNlbGYubXNnID0gIiIKICAgICAgICBzZWxmLnBy
b2NzID0ge30KICAgICAgICBzZWxmLmxvZ2xpbmVzID0gW10KICAgICAgICBzZWxmLnN0YXJ0ZWQg
PSAwLjAKICAgICAgICBzZWxmLndlbGNvbWVkID0gc2V0KCkgICAgICMgSU1TSXMsIGRpZSBpbiBk
aWVzZXIgTmV0ei1TZXNzaW9uIHNjaG9uIGJlZ3J1ZXNzdCB3dXJkZW4KICAgICAgICBzZWxmLmRl
dl9nc20gPSBzZWxmLmRldl9sdGUgPSAiIgoKICAgIGRlZiBfbG9nKHNlbGYsIHRhZywgbGluZSk6
CiAgICAgICAgbGluZSA9IGxpbmUucnN0cmlwKCkKICAgICAgICBpZiBub3QgbGluZTogcmV0dXJu
CiAgICAgICAgcHJpbnQoZiJ7dGFnfToge2xpbmV9IiwgZmx1c2g9VHJ1ZSkgICAjIC0+IGpvdXJu
YWxkLCBkYW1pdCAnam91cm5hbGN0bCAtdSBnOTBuZXQnIGFsbGVzIHplaWd0CiAgICAgICAgc2Vs
Zi5sb2dsaW5lcy5hcHBlbmQoZiJ7dGFnfToge2xpbmV9IikKICAgICAgICBpZiBsZW4oc2VsZi5s
b2dsaW5lcykgPiA2MDA6IHNlbGYubG9nbGluZXMgPSBzZWxmLmxvZ2xpbmVzWy02MDA6XQogICAg
ICAgIGxvdyA9IGxpbmUubG93ZXIoKQogICAgICAgIGlmICgiZmF0YWwiIGluIGxvdyBvciAiZmFp
bGVkIHRvIGNyZWF0ZSByYWRpbyIgaW4gbG93KSBhbmQgdGFnIG5vdCBpbiBHU01fTk9ORkFUQUw6
CiAgICAgICAgICAgIHNlbGYubXNnID0gZiJ7dGFnfToge2xpbmVbOjEyMF19IgoKICAgIGRlZiBf
cmVhZGVyKHNlbGYsIHAsIHRhZyk6CiAgICAgICAgdHJ5OgogICAgICAgICAgICBmb3IgcmF3IGlu
IGl0ZXIocC5zdGRvdXQucmVhZGxpbmUsICIiKToKICAgICAgICAgICAgICAgIHNlbGYuX2xvZyh0
YWcsIHJhdykKICAgICAgICBleGNlcHQgRXhjZXB0aW9uOgogICAgICAgICAgICBwYXNzCiAgICAg
ICAgcmMgPSBwLnBvbGwoKQogICAgICAgIGlmIHNlbGYucHJvY3MuZ2V0KHRhZykgaXMgcCBhbmQg
c2VsZi5zdGF0ZSA9PSAibGFldWZ0IiBhbmQgdGFnIG5vdCBpbiBHU01fTk9ORkFUQUw6CiAgICAg
ICAgICAgIHNlbGYubXNnID0gZiJ7dGFnfSBiZWVuZGV0IChDb2RlIHtyY30pIC0gc2llaGUgUHJv
dG9rb2xsIgoKICAgIGRlZiBfc3Bhd24oc2VsZiwgYmluYXJ5LCBhcmdzLCB0YWcpOgogICAgICAg
IHAgPSBzdWJwcm9jZXNzLlBvcGVuKFtiaW5hcnldICsgYXJncywgc3Rkb3V0PXN1YnByb2Nlc3Mu
UElQRSwKICAgICAgICAgICAgICAgICAgICAgICAgICAgICBzdGRlcnI9c3VicHJvY2Vzcy5TVERP
VVQsIHRleHQ9VHJ1ZSwgYnVmc2l6ZT0xKQogICAgICAgIHNlbGYucHJvY3NbdGFnXSA9IHAKICAg
ICAgICB0aHJlYWRpbmcuVGhyZWFkKHRhcmdldD1zZWxmLl9yZWFkZXIsIGFyZ3M9KHAsIHRhZyks
IGRhZW1vbj1UcnVlKS5zdGFydCgpCiAgICAgICAgcmV0dXJuIHAKCiAgICBkZWYgc3RvcChzZWxm
KToKICAgICAgICB3aXRoIHNlbGYubG9jazoKICAgICAgICAgICAgaWYgRkFLRToKICAgICAgICAg
ICAgICAgIHNlbGYudGVjaCA9IE5vbmU7IHNlbGYuc3RhdGUgPSAiYXVzIjsgc2VsZi5wcm9jcyA9
IHt9OyByZXR1cm4KICAgICAgICAgICAgcHJvY3MsIHNlbGYucHJvY3MgPSBzZWxmLnByb2NzLCB7
fQogICAgICAgICAgICBmb3IgdGFnLCBwIGluIGxpc3QocHJvY3MuaXRlbXMoKSk6CiAgICAgICAg
ICAgICAgICB0cnk6IHAudGVybWluYXRlKCkKICAgICAgICAgICAgICAgIGV4Y2VwdCBFeGNlcHRp
b246IHBhc3MKICAgICAgICAgICAgdGltZS5zbGVlcCgxKQogICAgICAgICAgICBmb3IgbmFtZSBp
biBPU01PX1NFUlZJQ0VTICsgWyJzcnNlbmIiLCAic3JzZXBjIiwgIm9wZW41Z3MtIl06CiAgICAg
ICAgICAgICAgICB0cnk6IHN1YnByb2Nlc3MucnVuKFsicGtpbGwiLCAiLTkiLCAiLWYiLCBuYW1l
XSwKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgc3Rkb3V0PXN1YnByb2Nlc3Mu
REVWTlVMTCwgc3RkZXJyPXN1YnByb2Nlc3MuREVWTlVMTCkKICAgICAgICAgICAgICAgIGV4Y2Vw
dCBFeGNlcHRpb246IHBhc3MKICAgICAgICAgICAgaWYgc2VsZi50ZWNoOgogICAgICAgICAgICAg
ICAgX2xpbWVfc2VydmljZSgic3RhcnQiKSAgICMgRzkwLUVtcGZhbmcgd2llZGVyIGZyZWkgZ2Vi
ZW4KICAgICAgICAgICAgc2VsZi50ZWNoID0gTm9uZTsgc2VsZi5zdGF0ZSA9ICJhdXMiOyBzZWxm
Lm1zZyA9ICJnZXN0b3BwdCIKCiAgICBkZWYgc3RhcnQoc2VsZiwgbW9kZSk6CiAgICAgICAgaWYg
bW9kZSBub3QgaW4gTU9ERVM6IHJldHVybiAidW5iZWthbm50ZXIgTW9kdXMiCiAgICAgICAgd2l0
aCBzZWxmLmxvY2s6CiAgICAgICAgICAgIHNlbGYuc3RvcCgpOyBzZWxmLnRlY2ggPSBtb2RlOyBz
ZWxmLnN0YXRlID0gInN0YXJ0ZXQiOyBzZWxmLm1zZyA9ICIiCiAgICAgICAgICAgIHNlbGYubG9n
bGluZXMgPSBbXTsgc2VsZi5zdGFydGVkID0gdGltZS50aW1lKCk7IHNlbGYud2VsY29tZWQgPSBz
ZXQoKQogICAgICAgIGVyciA9IHByZWZsaWdodChtb2RlKQogICAgICAgIGlmIGVycjoKICAgICAg
ICAgICAgd2l0aCBzZWxmLmxvY2s6IHNlbGYudGVjaCA9IE5vbmU7IHNlbGYuc3RhdGUgPSAiZmVo
bGVyIjsgc2VsZi5tc2cgPSBlcnIKICAgICAgICAgICAgcmV0dXJuIGVycgogICAgICAgIGlmIEZB
S0U6CiAgICAgICAgICAgIHdpdGggc2VsZi5sb2NrOiBzZWxmLnN0YXRlID0gImxhZXVmdCI7IHNl
bGYubXNnID0gTU9ERVNbbW9kZV0gKyAiIGxhZXVmdCAoRkFLRSkiCiAgICAgICAgICAgIHJldHVy
biBOb25lCiAgICAgICAgZ3NtLCBsdGUgPSBtb2RlIGluICgiZ3NtIiwgImNzZmIiKSwgbW9kZSBp
biAoImx0ZSIsICJjc2ZiIikKICAgICAgICB0cnk6CiAgICAgICAgICAgIGlmIGdzbToKICAgICAg
ICAgICAgICAgIHNlbGYuX3NlcnZpY2VzX29mZihPU01PX1NFUlZJQ0VTKQogICAgICAgICAgICAg
ICAgZ3NtX3ByZXBhcmUoKQogICAgICAgICAgICBpZiBsdGU6CiAgICAgICAgICAgICAgICBzZWxm
Ll9zZXJ2aWNlc19vZmYoW2IgZm9yIF9uZiwgYiBpbiBPNV9ORlNdKQogICAgICAgICAgICAgICAg
bmZzID0gbzVfcHJlcGFyZShtb2RlID09ICJjc2ZiIikKICAgICAgICAgICAgICAgIGVuYl9wcmVw
YXJlKG1vZGUgPT0gImNzZmIiLCBzZWxmLmRldl9sdGUpCiAgICAgICAgICAgICAgICBfcnVuKCJz
eXN0ZW1jdGwiLCAic3RhcnQiLCAibW9uZ29kIikKICAgICAgICAgICAgICAgIGUgPSBoc3Nfc3lu
Y19hbGwoKQogICAgICAgICAgICAgICAgaWYgZTogc2VsZi5fbG9nKCJwa29tIiwgIkhTUzogIiAr
IGUpCiAgICAgICAgICAgIGlmIHNlbGYuZGV2X2dzbTogc2VsZi5fbG9nKCJwa29tIiwgIkdTTS1G
dW5rOiAiICsgbGltZV9sYWJlbChzZWxmLmRldl9nc20pKQogICAgICAgICAgICBpZiBzZWxmLmRl
dl9sdGU6IHNlbGYuX2xvZygicGtvbSIsICJMVEUtRnVuazogIiArIGxpbWVfbGFiZWwoc2VsZi5k
ZXZfbHRlKSkKICAgICAgICAgICAgX2xpbWVfc2VydmljZSgic3RvcCIpOyB0aW1lLnNsZWVwKDEp
OyBfZnJlZV9saW1lKCk7IHRpbWUuc2xlZXAoMikKICAgICAgICAgICAgaWYgZ3NtOgogICAgICAg
ICAgICAgICAgZm9yIG5hbWUsIGJpbmFyeSwgY2ZnIGluIGdzbV9jb21wb25lbnRzKCk6CiAgICAg
ICAgICAgICAgICAgICAgZmxhZyA9ICItQyIgaWYgYmluYXJ5LnN0YXJ0c3dpdGgoIm9zbW8tdHJ4
IikgZWxzZSAiLWMiCiAgICAgICAgICAgICAgICAgICAgc2VsZi5fc3Bhd24oYmluYXJ5LCBbZmxh
Zywgb3MucGF0aC5qb2luKFdPUktESVIsIGNmZyldLCBuYW1lKQogICAgICAgICAgICAgICAgICAg
IHRpbWUuc2xlZXAoNCBpZiBuYW1lIGluICgidHJ4IiwpIGVsc2UgMS4yKQogICAgICAgICAgICAg
ICAgdGltZS5zbGVlcCgxKTsgZ3NtX2FwcGx5X251bWJlcnMoKSAgICMgU0lNcyArIGRhdWVyaGFm
dGUgUnVmbnVtbWVybiBpbnMgSExSCiAgICAgICAgICAgIGlmIGx0ZToKICAgICAgICAgICAgICAg
IHVlX25ldF91cCgpCiAgICAgICAgICAgICAgICBmb3IgbmYsIChiaW5hcnksIHBhdGgpIGluIG5m
cy5pdGVtcygpOgogICAgICAgICAgICAgICAgICAgIHNlbGYuX3NwYXduKGJpbmFyeSwgWyItYyIs
IHBhdGhdLCBuZikKICAgICAgICAgICAgICAgICAgICB0aW1lLnNsZWVwKDEuNSBpZiBuZiA9PSAi
bW1lIiBlbHNlIDAuOCkKICAgICAgICAgICAgICAgIHRpbWUuc2xlZXAoMikKICAgICAgICAgICAg
ICAgIHNlbGYuX3NwYXduKCJzcnNlbmIiLCBbb3MucGF0aC5qb2luKFdPUktESVIsICJlbmIuY29u
ZiIpXSwgImVuYiIpCiAgICAgICAgICAgIHdpdGggc2VsZi5sb2NrOiBzZWxmLnN0YXRlID0gImxh
ZXVmdCI7IHNlbGYubXNnID0gTU9ERVNbbW9kZV0gKyAiIGdlc3RhcnRldCIKICAgICAgICBleGNl
cHQgRXhjZXB0aW9uIGFzIGU6CiAgICAgICAgICAgIHdpdGggc2VsZi5sb2NrOiBzZWxmLnN0YXRl
ID0gImZlaGxlciI7IHNlbGYubXNnID0gc3RyKGUpWzoyMDBdCiAgICAgICAgICAgIHJldHVybiBz
dHIoZSkKICAgICAgICByZXR1cm4gTm9uZQoKICAgICMgS29tcGF0aWJpbGl0YWV0CiAgICBkZWYg
c3RhcnRfZ3NtKHNlbGYpOiByZXR1cm4gc2VsZi5zdGFydCgiZ3NtIikKICAgIGRlZiBzdGFydF9s
dGUoc2VsZik6IHJldHVybiBzZWxmLnN0YXJ0KCJsdGUiKQoKICAgIGRlZiBfc2VydmljZXNfb2Zm
KHNlbGYsIG5hbWVzKToKICAgICAgICBmb3IgcyBpbiBuYW1lczoKICAgICAgICAgICAgdHJ5OiBz
dWJwcm9jZXNzLnJ1bihbInN5c3RlbWN0bCIsICJzdG9wIiwgcy5yZXBsYWNlKCJvcGVuNWdzLSIs
ICJvcGVuNWdzLSIpICsgIi5zZXJ2aWNlIl0sCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
ICAgc3Rkb3V0PXN1YnByb2Nlc3MuREVWTlVMTCwgc3RkZXJyPXN1YnByb2Nlc3MuREVWTlVMTCwg
dGltZW91dD04KQogICAgICAgICAgICBleGNlcHQgRXhjZXB0aW9uOiBwYXNzCgogICAgZGVmIHN0
YXR1cyhzZWxmKToKICAgICAgICB3aXRoIHNlbGYubG9jazoKICAgICAgICAgICAgc3QgPSB7CiAg
ICAgICAgICAgICAgICAidGVjaCI6IHNlbGYudGVjaCwgIm1vZGUiOiBNT0RFUy5nZXQoc2VsZi50
ZWNoIG9yICIiLCAiIiksCiAgICAgICAgICAgICAgICAic3RhdGUiOiBzZWxmLnN0YXRlLCAibXNn
Ijogc2VsZi5tc2csCiAgICAgICAgICAgICAgICAidXB0aW1lIjogaW50KHRpbWUudGltZSgpIC0g
c2VsZi5zdGFydGVkKSBpZiBzZWxmLnN0YXJ0ZWQgYW5kIHNlbGYuc3RhdGUgPT0gImxhZXVmdCIg
ZWxzZSAwLAogICAgICAgICAgICAgICAgImxvZyI6IHNlbGYubG9nbGluZXNbLTgwOl0sCiAgICAg
ICAgICAgICAgICAiY29uZiI6IGRpY3QoQyksCiAgICAgICAgICAgICAgICAibGltZXMiOiBMSU1F
UywKICAgICAgICAgICAgICAgICJkZXYiOiB7ImdzbSI6IGxpbWVfbGFiZWwoc2VsZi5kZXZfZ3Nt
KSBpZiBzZWxmLmRldl9nc20gZWxzZSAiIiwKICAgICAgICAgICAgICAgICAgICAgICAgImx0ZSI6
IGxpbWVfbGFiZWwoc2VsZi5kZXZfbHRlKSBpZiBzZWxmLmRldl9sdGUgZWxzZSAiIn0sCiAgICAg
ICAgICAgICAgICAiZ3NtIjogewogICAgICAgICAgICAgICAgICAgICJhcmZjbiI6IGludChDWyJH
U01fQVJGQ04iXSksICJiYW5kIjogYXJmY25fYmFuZChpbnQoQ1siR1NNX0FSRkNOIl0pKSwKICAg
ICAgICAgICAgICAgICAgICAibWh6IjogYXJmY25fbWh6KGludChDWyJHU01fQVJGQ04iXSkpLAog
ICAgICAgICAgICAgICAgICAgICJhdHRhY2hlZCI6IHNvcnRlZChtc2NfYXR0YWNoZWQoKSkgaWYg
c2VsZi5zdGF0ZSA9PSAibGFldWZ0IiBlbHNlIFtdLAogICAgICAgICAgICAgICAgICAgICJudW1i
ZXJzIjogbnVtc19sb2FkKCksCiAgICAgICAgICAgICAgICB9LAogICAgICAgICAgICAgICAgImx0
ZSI6IHsKICAgICAgICAgICAgICAgICAgICAiZWFyZmNuIjogaW50KENbIkxURV9FQVJGQ04iXSks
ICJiYW5kIjogZWFyZmNuX2JhbmQoaW50KENbIkxURV9FQVJGQ04iXSkpLAogICAgICAgICAgICAg
ICAgICAgICJtaHoiOiBlYXJmY25fbWh6KGludChDWyJMVEVfRUFSRkNOIl0pKSwKICAgICAgICAg
ICAgICAgIH0sCiAgICAgICAgICAgICAgICAic2ltcyI6IFt7Imltc2kiOiBpLCAibXNpc2RuIjog
cy5nZXQoIm1zaXNkbiIsICIiKX0gZm9yIGksIHMgaW4gc29ydGVkKHNpbXNfbG9hZCgpLml0ZW1z
KCkpXSwKICAgICAgICAgICAgICAgICJzaW1maWxlcyI6IHNpbV9maWxlcygpLAogICAgICAgICAg
ICAgICAgInR6IjogIlVUQyUrZDolMDJkJXMiICUgKHR6X25vdygpWzBdLCB0el9ub3coKVsxXSwg
IiArU29tbWVyemVpdCIgaWYgdHpfbm93KClbMl0gZWxzZSAiIiksCiAgICAgICAgICAgICAgICAi
Y2xhc2giOiBmcmVxX2NsYXNoKCksCiAgICAgICAgICAgICAgICAiZmFrZSI6IEZBS0UsCiAgICAg
ICAgICAgIH0KICAgICAgICByZXR1cm4gc3QKCk5FVCA9IE5ldCgpCgojID09PT09PT09PT09PT09
PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PSBXZWIt
QVBJCmRlZiBoYW5kbGVfYXBpKHBhdGgsIGJvZHkpOgogICAgdHJ5OgogICAgICAgIHJlcSA9IGpz
b24ubG9hZHMoYm9keSBvciAie30iKQogICAgZXhjZXB0IEV4Y2VwdGlvbjoKICAgICAgICByZXEg
PSB7fQogICAgY21kID0gcGF0aC5yc3BsaXQoIi8iLCAxKVstMV0KICAgIGlmIGNtZCA9PSAic3Rh
dHVzIjoKICAgICAgICByZXR1cm4gTkVULnN0YXR1cygpCiAgICBpZiBjbWQgaW4gKCJzdGFydF9n
c20iLCAic3RhcnRfbHRlIiwgInN0YXJ0X2NzZmIiKToKICAgICAgICBORVQuc3RhcnQoY21kWzY6
XSkKICAgIGVsaWYgY21kID09ICJzdG9wIjoKICAgICAgICBORVQuc3RvcCgpCiAgICBlbGlmIGNt
ZCA9PSAibGltZV9zY2FuIjoKICAgICAgICBuID0gbGVuKGxpbWVfc2NhbigpKTsgTkVULm1zZyA9
IGYie259IExpbWVTRFIgZ2VmdW5kZW4iCiAgICBlbGlmIGNtZCA9PSAic2V0IjoKICAgICAgICAj
IGJlbGllYmlnZSBLb25maWctS2V5cyBzZXR6ZW4gKHZhbGlkaWVydCBsaWdodCkKICAgICAgICBm
b3IgaywgdiBpbiByZXEuaXRlbXMoKToKICAgICAgICAgICAgaWYgayBpbiBERUZBVUxUUyBvciBr
IGluIEM6CiAgICAgICAgICAgICAgICB2ID0gc3RyKHYpLnJlcGxhY2UoJyInLCAiIikucmVwbGFj
ZSgiXG4iLCAiICIpLnN0cmlwKCkKICAgICAgICAgICAgICAgIGlmIGsgaW4gKCJNQ0MiLCAiTU5D
IiwgIkxURV9UQUMiKTogdiA9IHJlLnN1YihyIlxEIiwgIiIsIHYpCiAgICAgICAgICAgICAgICBj
c2V0KGssIHYpCiAgICAgICAgTkVULm1zZyA9ICJnZXNwZWljaGVydCAtIHdpcmt0IGJlaW0gbmFl
Y2hzdGVuIFN0YXJ0IgogICAgICAgIGlmIEMuZ2V0KCJHU01fREVWIikgYW5kIEMuZ2V0KCJHU01f
REVWIikgPT0gQy5nZXQoIkxURV9ERVYiKToKICAgICAgICAgICAgTkVULm1zZyA9ICJBY2h0dW5n
OiBHU00gdW5kIExURSBudXR6ZW4gZGVuc2VsYmVuIExpbWVTRFIgLSBmdWVyIExURSArIEdTTSB6
d2VpIEdlcmFldGUgd2FlaGxlbiIKICAgIGVsaWYgY21kIGluICgic2ltX2FkZCIsICJnc21fc2lt
X2FkZCIsICJsdGVfc2ltX2FkZCIpOgogICAgICAgIE5FVC5tc2cgPSBzaW1fYWRkKHJlcS5nZXQo
Imltc2kiLCIiKSwgcmVxLmdldCgia2kiLCIiKSwgcmVxLmdldCgib3BjIiwiIiksIHJlcS5nZXQo
Im1zaXNkbiIsIiIpKSBcCiAgICAgICAgICAgICAgICAgIG9yICJTSU0gZ2VzcGVpY2hlcnQgKEdT
TSArIExURSkiCiAgICBlbGlmIGNtZCBpbiAoInNpbV9kZWwiLCAiZ3NtX3NpbV9kZWwiLCAibHRl
X3NpbV9kZWwiKToKICAgICAgICBzaW1fZGVsKHJlcS5nZXQoImltc2kiLCIiKSk7IE5FVC5tc2cg
PSAiU0lNIGdlbG9lc2NodCIKICAgIGVsaWYgY21kID09ICJnc21fc2ltX25yIjoKICAgICAgICBO
RVQubXNnID0gZ3NtX3NpbV9ucihyZXEuZ2V0KCJpbXNpIiwiIiksIHJlcS5nZXQoIm1zaXNkbiIs
IiIpKSBvciAiUnVmbnVtbWVyIGRhdWVyaGFmdCB6dWdld2llc2VuIgogICAgZWxpZiBjbWQgPT0g
ImdzbV9udW1fZGVsIjoKICAgICAgICBnc21fbnVtX2RlbChyZXEuZ2V0KCJpbXNpIiwiIikpOyBO
RVQubXNnID0gIlJ1Zm51bW1lci1adXdlaXN1bmcgZ2Vsb2VzY2h0IgogICAgZWxpZiBjbWQgPT0g
InNtc190ZXN0IjoKICAgICAgICBORVQubXNnID0gc21zX3Rlc3QocmVxLmdldCgiaW1zaSIsIiIp
LCByZXEuZ2V0KCJ0ZXh0IiwiIikpCiAgICBlbHNlOgogICAgICAgIE5FVC5tc2cgPSAidW5iZWth
bm50IgogICAgcmV0dXJuIE5FVC5zdGF0dXMoKQoKIyA9PT09PT09PT09PT09PT09PT09PT09PT09
PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT0gV2ViLU9iZXJmbGFlY2hl
IChIVE1MKQpQQUdFID0gciIiIjwhZG9jdHlwZSBodG1sPjxodG1sIGxhbmc9ZGU+PGhlYWQ+PG1l
dGEgY2hhcnNldD11dGYtOD4KPG1ldGEgbmFtZT12aWV3cG9ydCBjb250ZW50PSJ3aWR0aD1kZXZp
Y2Utd2lkdGgsaW5pdGlhbC1zY2FsZT0xIj4KPG1ldGEgbmFtZT10aGVtZS1jb2xvciBjb250ZW50
PSIjMEEyNDYzIj4KPGxpbmsgcmVsPWljb24gaHJlZj0iZGF0YTppbWFnZS9zdmcreG1sO2Jhc2U2
NCxQSE4yWnlCNGJXeHVjejBpYUhSMGNEb3ZMM2QzZHk1M015NXZjbWN2TWpBd01DOXpkbWNpSUha
cFpYZENiM2c5SWpBZ01DQXhNREkwSURFd01qUWlQanh5WldOMElIZHBaSFJvUFNJeE1ESTBJaUJv
WldsbmFIUTlJakV3TWpRaUlHWnBiR3c5SWlNd1FUSTBOak1pUGp3dmNtVmpkRDRLUEdjZ2RISmhi
bk5tYjNKdFBTSjBjbUZ1YzJ4aGRHVW9NVEkzTGpZZ016UTNMakFwSUhOallXeGxLREV1TmpVcElp
Qm1hV3hzUFNKdWIyNWxJaUJ6ZEhKdmEyVXRiR2x1WldOaGNEMGljbTkxYm1RaUlITjBjbTlyWlMx
c2FXNWxhbTlwYmowaWNtOTFibVFpSUhOMGNtOXJaUzEzYVdSMGFEMGlNeklpUGdvOFp5QnpkSEp2
YTJVOUlpTkdSa1pHUmtZaVBnbzhjR0YwYUNCa1BTSk5NakFnT0RBZ1ZqSTJOaUkrUEM5d1lYUm9Q
Z284WTJseVkyeGxJR040UFNJM01pSWdZM2s5SWpFek15SWdjajBpTlRJaVBqd3ZZMmx5WTJ4bFBn
bzhMMmMrQ2p4bklITjBjbTlyWlQwaUkwWkdSa1pHUmlJK0NqeHdZWFJvSUdROUlrMHhOemdnTVRZ
Z1VUSXdOaUF4TURBZ01UYzRJREU0TkNJK1BDOXdZWFJvUGdvOGNHRjBhQ0JrUFNKTk1Ua3lJREV3
TUNCRE1qSTJJRGsySURJMU1DQTJNaUF5TmpZZ01UWWlQand2Y0dGMGFENEtQQzluUGdvOGNHRjBh
Q0J6ZEhKdmEyVTlJaU15UlVNMFJqRWlJR1E5SWsweE9USWdNVEF3SUVNeU16TWdNVEF5SURJMU5p
QXhPRE1nTXpZeklERTRNeUJCT0RNZ09ETWdNQ0F3SURBZ016WXpJREUzSUVFNE15QTRNeUF3SURB
Z01DQXlPRElnTVRFNElqNDhMM0JoZEdnK0Nqd3ZaejQ4TDNOMlp6ND0iPgo8dGl0bGU+cEtPTSDC
tyBOZXR6c3RldWVydW5nPC90aXRsZT4KPHN0eWxlPgo6cm9vdHstLW5hdnk6IzBBMjQ2MzstLWJn
OiMwNjBmMjI7LS1iZzI6IzBhMTczNDstLWNhcmQ6IzBjMWEzYjstLWNhcmQyOiMxMDIyNTA7LS1s
aW5lOiMxYjJmNWU7LS1saW5lMjojMmE0Mjg4OwotLWZnOiNlYWYxZmI7LS1tdXQ6IzhlYTRjYTst
LW11dDI6IzVkNzM5ODstLWFjYzojMkVDNEYxOy0tYWNjMjojMDA5NkQ2Oy0tb2s6IzJFQzRGMTst
LW9rYmc6IzA3MjQzYjstLWVycjojZmY1ZDZjOwotLXI6MDstLXIyOjA7LS1tb25vOnVpLW1vbm9z
cGFjZSxTRk1vbm8tUmVndWxhcixNZW5sbyxDb25zb2xhcyxtb25vc3BhY2V9Cip7Ym94LXNpemlu
Zzpib3JkZXItYm94fWh0bWwsYm9keXttYXJnaW46MH0KYm9keXtiYWNrZ3JvdW5kOmxpbmVhci1n
cmFkaWVudCgxODBkZWcsIzA4MTMzMCwjMDUxMDFmKTtjb2xvcjp2YXIoLS1mZyk7CmZvbnQ6MTVw
eC8xLjU1IHN5c3RlbS11aSwtYXBwbGUtc3lzdGVtLFNlZ29lIFVJLFJvYm90byxzYW5zLXNlcmlm
O21pbi1oZWlnaHQ6MTAwdmh9CmhlYWRlcntwb3NpdGlvbjpzdGlja3k7dG9wOjA7ei1pbmRleDoy
MDtiYWNrZ3JvdW5kOnZhcigtLW5hdnkpO2JvcmRlci10b3A6MnB4IHNvbGlkIHZhcigtLWFjYyk7
CmJvcmRlci1ib3R0b206MXB4IHNvbGlkIHZhcigtLWxpbmUyKTtwYWRkaW5nOjEycHggMjBweDtk
aXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2dhcDoxNnB4O2ZsZXgtd3JhcDp3cmFwfQou
YnJhbmR7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtnYXA6MTJweH0KLmJyYW5kIHN2
Z3toZWlnaHQ6MzBweDt3aWR0aDphdXRvO2Rpc3BsYXk6YmxvY2t9Ci5icmFuZCAucHJvZHtmb250
LXNpemU6MTFweDtmb250LXdlaWdodDo3MDA7bGV0dGVyLXNwYWNpbmc6LjE4ZW07dGV4dC10cmFu
c2Zvcm06dXBwZXJjYXNlO2NvbG9yOiM5ZmI2ZGU7cGFkZGluZy1sZWZ0OjEycHg7Ym9yZGVyLWxl
ZnQ6MXB4IHNvbGlkICMyNzQwN2V9Ci5jaGlwe2Rpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50
ZXI7Z2FwOjhweDtwYWRkaW5nOjZweCAxMnB4O2JvcmRlcjoxcHggc29saWQgdmFyKC0tbGluZTIp
O2JhY2tncm91bmQ6IzBiMTczMztmb250LXNpemU6MTJweDtmb250LXdlaWdodDo3MDA7bGV0dGVy
LXNwYWNpbmc6LjA2ZW07dGV4dC10cmFuc2Zvcm06dXBwZXJjYXNlfQouZG90e3dpZHRoOjhweDto
ZWlnaHQ6OHB4O2JhY2tncm91bmQ6dmFyKC0tbXV0KX0KLmRvdC5vbntiYWNrZ3JvdW5kOnZhcigt
LWFjYyk7YW5pbWF0aW9uOnB1bHNlIDJzIGluZmluaXRlfS5kb3QuZXJye2JhY2tncm91bmQ6dmFy
KC0tZXJyKX0KQGtleWZyYW1lcyBwdWxzZXswJXtib3gtc2hhZG93OjAgMCAwIDAgcmdiYSg0Niwx
OTYsMjQxLC41KX03MCV7Ym94LXNoYWRvdzowIDAgMCA3cHggcmdiYSg0NiwxOTYsMjQxLDApfTEw
MCV7Ym94LXNoYWRvdzowIDAgMCAwIHJnYmEoNDYsMTk2LDI0MSwwKX19Ci5oc3RhdHtkaXNwbGF5
OmZsZXg7Z2FwOjE4cHg7ZmxleC13cmFwOndyYXA7Y29sb3I6dmFyKC0tbXV0KTtmb250LXNpemU6
MTJweDttYXJnaW4tbGVmdDphdXRvO2FsaWduLWl0ZW1zOmNlbnRlcjt0ZXh0LXRyYW5zZm9ybTp1
cHBlcmNhc2U7bGV0dGVyLXNwYWNpbmc6LjA1ZW19Ci5oc3RhdCBie2NvbG9yOnZhcigtLWZnKTtm
b250LWZhbWlseTp2YXIoLS1tb25vKTtsZXR0ZXItc3BhY2luZzowO3RleHQtdHJhbnNmb3JtOm5v
bmV9CiNtc2d7Y29sb3I6dmFyKC0tYWNjKTtmb250LXNpemU6MTJweDt0ZXh0LXRyYW5zZm9ybTpu
b25lO2xldHRlci1zcGFjaW5nOjB9Ci5iYWRnZXtmb250LXNpemU6MTBweDtwYWRkaW5nOjNweCA5
cHg7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1hY2MpO2NvbG9yOnZhcigtLWFjYyk7Zm9udC13ZWln
aHQ6NzAwO2xldHRlci1zcGFjaW5nOi4xMmVtfQoud3JhcHttYXgtd2lkdGg6MTA2MHB4O21hcmdp
bjowIGF1dG87cGFkZGluZzoyMnB4IDE2cHggNDRweH0KLmJhbm5lcntkaXNwbGF5OmZsZXg7Z2Fw
OjExcHg7YWxpZ24taXRlbXM6ZmxleC1zdGFydDtiYWNrZ3JvdW5kOiMwYzFhM2I7Ym9yZGVyOjFw
eCBzb2xpZCB2YXIoLS1saW5lMik7CmJvcmRlci1sZWZ0OjNweCBzb2xpZCAjZjFiMjRhO2NvbG9y
OiNmMmQ3OWY7cGFkZGluZzoxMnB4IDE1cHg7Zm9udC1zaXplOjEzcHg7bWFyZ2luLWJvdHRvbTox
OHB4fQouY29udHJvbHN7ZGlzcGxheTpncmlkO2dyaWQtdGVtcGxhdGUtY29sdW1uczoxZnIgMWZy
IDFmciBhdXRvO2dhcDoxMHB4O21hcmdpbi1ib3R0b206MjBweH0KQG1lZGlhKG1heC13aWR0aDo4
MjBweCl7LmNvbnRyb2xze2dyaWQtdGVtcGxhdGUtY29sdW1uczoxZnIgMWZyfX1AbWVkaWEobWF4
LXdpZHRoOjQ4MHB4KXsuY29udHJvbHN7Z3JpZC10ZW1wbGF0ZS1jb2x1bW5zOjFmcn19Ci5iaWdi
dG57Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1saW5lMik7YmFja2dyb3VuZDojMGIxODM2O2NvbG9y
OnZhcigtLWZnKTsKcGFkZGluZzoxNXB4IDE4cHg7Zm9udDppbmhlcml0O2ZvbnQtd2VpZ2h0OjYw
MDtjdXJzb3I6cG9pbnRlcjtkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2dhcDoxMnB4
O3RyYW5zaXRpb246LjE1c30KLmJpZ2J0bjpob3Zlcntib3JkZXItY29sb3I6dmFyKC0tYWNjKTti
YWNrZ3JvdW5kOiMwZTFmNDd9LmJpZ2J0biAuaWN7Zm9udC1zaXplOjE2cHg7Y29sb3I6dmFyKC0t
YWNjKX0KLmJpZ2J0biBzbWFsbHtkaXNwbGF5OmJsb2NrO2NvbG9yOnZhcigtLW11dCk7Zm9udC13
ZWlnaHQ6NDAwO2ZvbnQtc2l6ZToxMXB4O3RleHQtdHJhbnNmb3JtOnVwcGVyY2FzZTtsZXR0ZXIt
c3BhY2luZzouMDdlbTttYXJnaW4tdG9wOjJweH0KLmJpZ2J0bi5hY3RpdmV7Ym9yZGVyLWNvbG9y
OnZhcigtLWFjYyk7YmFja2dyb3VuZDp2YXIoLS1va2JnKTtib3gtc2hhZG93Omluc2V0IDNweCAw
IDAgdmFyKC0tYWNjKX0uYmlnYnRuLmFjdGl2ZSAuaWN7Y29sb3I6dmFyKC0tYWNjKX0KLmJpZ2J0
bi5zdG9we2JhY2tncm91bmQ6IzFlMTAxNjtib3JkZXItY29sb3I6IzUzMjMyZTtjb2xvcjojZmZi
MGI4O2p1c3RpZnktY29udGVudDpjZW50ZXI7Zm9udC13ZWlnaHQ6NzAwO2xldHRlci1zcGFjaW5n
Oi4wNWVtO3RleHQtdHJhbnNmb3JtOnVwcGVyY2FzZTtmb250LXNpemU6MTRweH0uYmlnYnRuLnN0
b3A6aG92ZXJ7Ym9yZGVyLWNvbG9yOnZhcigtLWVycil9Ci50YWJze2Rpc3BsYXk6ZmxleDtnYXA6
NHB4O2JvcmRlci1ib3R0b206MXB4IHNvbGlkIHZhcigtLWxpbmUyKTttYXJnaW4tYm90dG9tOjIw
cHg7b3ZlcmZsb3cteDphdXRvfQoudGFie3BhZGRpbmc6MTBweCAxNnB4O2JvcmRlcjowO2JhY2tn
cm91bmQ6MDtjb2xvcjp2YXIoLS1tdXQpO2ZvbnQ6aW5oZXJpdDtmb250LXdlaWdodDo3MDA7Zm9u
dC1zaXplOjEycHg7bGV0dGVyLXNwYWNpbmc6LjA5ZW07dGV4dC10cmFuc2Zvcm06dXBwZXJjYXNl
O2N1cnNvcjpwb2ludGVyO2JvcmRlci1ib3R0b206MnB4IHNvbGlkIHRyYW5zcGFyZW50O3doaXRl
LXNwYWNlOm5vd3JhcDttYXJnaW4tYm90dG9tOi0xcHh9Ci50YWI6aG92ZXJ7Y29sb3I6dmFyKC0t
ZmcpfS50YWIuc2Vse2NvbG9yOnZhcigtLWFjYyk7Ym9yZGVyLWJvdHRvbS1jb2xvcjp2YXIoLS1h
Y2MpfQoucGFuZWx7ZGlzcGxheTpub25lfS5wYW5lbC5zZWx7ZGlzcGxheTpibG9ja30KLmdyaWR7
ZGlzcGxheTpncmlkO2dhcDoxNnB4O2dyaWQtdGVtcGxhdGUtY29sdW1uczoxZnIgMWZyfUBtZWRp
YShtYXgtd2lkdGg6NzYwcHgpey5ncmlke2dyaWQtdGVtcGxhdGUtY29sdW1uczoxZnJ9fQouY2Fy
ZHtiYWNrZ3JvdW5kOnZhcigtLWNhcmQpO2JvcmRlcjoxcHggc29saWQgdmFyKC0tbGluZSk7cGFk
ZGluZzoxOHB4fQouY2FyZCBoMntmb250LXNpemU6MTJweDttYXJnaW46MDtkaXNwbGF5OmZsZXg7
YWxpZ24taXRlbXM6Y2VudGVyO2dhcDo5cHg7dGV4dC10cmFuc2Zvcm06dXBwZXJjYXNlO2xldHRl
ci1zcGFjaW5nOi4xZW07Y29sb3I6I2M2ZDZmMTtmb250LXdlaWdodDo3MDB9Ci5jYXJkIGgyOmJl
Zm9yZXtjb250ZW50OiIiO3dpZHRoOjlweDtoZWlnaHQ6OXB4O2JhY2tncm91bmQ6dmFyKC0tYWNj
KTtmbGV4Om5vbmV9Ci5jYXJkIC5zdWJ7Y29sb3I6dmFyKC0tbXV0KTtmb250LXNpemU6MTJweDtt
YXJnaW46OHB4IDAgMTRweH0KbGFiZWx7ZGlzcGxheTpibG9jaztmb250LXNpemU6MTFweDtjb2xv
cjp2YXIoLS1tdXQpO21hcmdpbjoxM3B4IDAgNXB4O2ZvbnQtd2VpZ2h0OjcwMDt0ZXh0LXRyYW5z
Zm9ybTp1cHBlcmNhc2U7bGV0dGVyLXNwYWNpbmc6LjA3ZW19CmlucHV0LHNlbGVjdHt3aWR0aDox
MDAlO2JhY2tncm91bmQ6IzA3MTQyZjtib3JkZXI6MXB4IHNvbGlkIHZhcigtLWxpbmUyKTtjb2xv
cjp2YXIoLS1mZyk7cGFkZGluZzoxMHB4IDEycHg7Zm9udDppbmhlcml0O291dGxpbmU6MDt0cmFu
c2l0aW9uOi4xMnN9CmlucHV0OmZvY3VzLHNlbGVjdDpmb2N1c3tib3JkZXItY29sb3I6dmFyKC0t
YWNjKTtib3gtc2hhZG93OjAgMCAwIDJweCByZ2JhKDQ2LDE5NiwyNDEsLjE4KX0KLnJvd3tkaXNw
bGF5OmdyaWQ7Z3JpZC10ZW1wbGF0ZS1jb2x1bW5zOjFmciAxZnI7Z2FwOjEwcHh9LnJvdzN7ZGlz
cGxheTpncmlkO2dyaWQtdGVtcGxhdGUtY29sdW1uczoxZnIgMWZyIDFmcjtnYXA6MTBweH0KLmJ0
bntiYWNrZ3JvdW5kOnZhcigtLWFjYyk7Y29sb3I6dmFyKC0tbmF2eSk7Ym9yZGVyOjA7cGFkZGlu
ZzoxMHB4IDE4cHg7Zm9udDppbmhlcml0O2ZvbnQtd2VpZ2h0OjcwMDtsZXR0ZXItc3BhY2luZzou
MDVlbTt0ZXh0LXRyYW5zZm9ybTp1cHBlcmNhc2U7Zm9udC1zaXplOjEzcHg7Y3Vyc29yOnBvaW50
ZXI7bWFyZ2luLXRvcDoxNnB4O3RyYW5zaXRpb246LjEyc30KLmJ0bjpob3ZlcntiYWNrZ3JvdW5k
OiM1YWQyZjZ9LmJ0bi5zZWN7YmFja2dyb3VuZDp0cmFuc3BhcmVudDtib3JkZXI6MXB4IHNvbGlk
IHZhcigtLWxpbmUyKTtjb2xvcjp2YXIoLS1hY2MpfS5idG4uc2VjOmhvdmVye2JvcmRlci1jb2xv
cjp2YXIoLS1hY2MpO2JhY2tncm91bmQ6IzBiMWI0MH0KLmJ0bi5zbXtwYWRkaW5nOjhweCAxM3B4
O21hcmdpbi10b3A6NHB4O2ZvbnQtc2l6ZToxMnB4fQouc3d7ZGlzcGxheTpmbGV4O2FsaWduLWl0
ZW1zOmNlbnRlcjtqdXN0aWZ5LWNvbnRlbnQ6c3BhY2UtYmV0d2VlbjtnYXA6MTBweDtwYWRkaW5n
OjEzcHggMDtib3JkZXItdG9wOjFweCBzb2xpZCB2YXIoLS1saW5lKX0KLnN3LmZpcnN0e2JvcmRl
ci10b3A6MH0uc3cgLnR7Zm9udC1zaXplOjE0cHh9LnN3IC50IHNtYWxse2Rpc3BsYXk6YmxvY2s7
Y29sb3I6dmFyKC0tbXV0KTtmb250LXNpemU6MTJweH0KLnN3aXRjaHtwb3NpdGlvbjpyZWxhdGl2
ZTt3aWR0aDo0NnB4O2hlaWdodDoyNHB4O2ZsZXg6bm9uZX0uc3dpdGNoIGlucHV0e29wYWNpdHk6
MDt3aWR0aDowO2hlaWdodDowfQouc2xpZGVye3Bvc2l0aW9uOmFic29sdXRlO2luc2V0OjA7YmFj
a2dyb3VuZDojMGIxYTNkO2JvcmRlcjoxcHggc29saWQgdmFyKC0tbGluZTIpO3RyYW5zaXRpb246
LjJzO2N1cnNvcjpwb2ludGVyfQouc2xpZGVyOmJlZm9yZXtjb250ZW50OiIiO3Bvc2l0aW9uOmFi
c29sdXRlO2hlaWdodDoxNnB4O3dpZHRoOjE2cHg7bGVmdDozcHg7dG9wOjNweDtiYWNrZ3JvdW5k
OnZhcigtLW11dCk7dHJhbnNpdGlvbjouMnN9Ci5zd2l0Y2ggaW5wdXQ6Y2hlY2tlZCsuc2xpZGVy
e2JhY2tncm91bmQ6dmFyKC0tb2tiZyk7Ym9yZGVyLWNvbG9yOnZhcigtLWFjYyl9LnN3aXRjaCBp
bnB1dDpjaGVja2VkKy5zbGlkZXI6YmVmb3Jle3RyYW5zZm9ybTp0cmFuc2xhdGVYKDIycHgpO2Jh
Y2tncm91bmQ6dmFyKC0tYWNjKX0KLmhpbnR7Zm9udC1zaXplOjEycHg7Y29sb3I6dmFyKC0tbXV0
KTttYXJnaW4tdG9wOjEwcHg7bGluZS1oZWlnaHQ6MS41fQouZnJlcWJveHtiYWNrZ3JvdW5kOiMw
NzE0MmY7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1saW5lMik7cGFkZGluZzoxM3B4IDE2cHg7ZGlz
cGxheTpmbGV4O2p1c3RpZnktY29udGVudDpzcGFjZS1iZXR3ZWVuO2FsaWduLWl0ZW1zOmNlbnRl
cn0KLmZyZXFib3ggLmJpZ3tmb250LXNpemU6MjJweDtmb250LXdlaWdodDo3MDA7bGluZS1oZWln
aHQ6MS4xNTtmb250LWZhbWlseTp2YXIoLS1tb25vKTtjb2xvcjp2YXIoLS1hY2MpfS5mcmVxYm94
IC5zbXtjb2xvcjp2YXIoLS1tdXQpO2ZvbnQtc2l6ZToxMnB4O3RleHQtdHJhbnNmb3JtOnVwcGVy
Y2FzZTtsZXR0ZXItc3BhY2luZzouMDZlbX0KLmxpc3Ryb3d7ZGlzcGxheTpmbGV4O2p1c3RpZnkt
Y29udGVudDpzcGFjZS1iZXR3ZWVuO2FsaWduLWl0ZW1zOmNlbnRlcjtib3JkZXItdG9wOjFweCBz
b2xpZCB2YXIoLS1saW5lKTtwYWRkaW5nOjlweCAwO2ZvbnQtc2l6ZToxNHB4fQoubGlzdHJvdzpm
aXJzdC1jaGlsZHtib3JkZXItdG9wOjB9LnRhZ3tmb250LWZhbWlseTp2YXIoLS1tb25vKTtmb250
LXNpemU6MTNweDtjb2xvcjojY2FkOWYzfQoueHtiYWNrZ3JvdW5kOiMxZTEwMTY7Ym9yZGVyOjFw
eCBzb2xpZCAjNTMyMzJlO2NvbG9yOiNmZjliYTY7cGFkZGluZzo0cHggMTBweDtjdXJzb3I6cG9p
bnRlcjtmb250LXNpemU6MTFweDt0ZXh0LXRyYW5zZm9ybTp1cHBlcmNhc2U7bGV0dGVyLXNwYWNp
bmc6LjA1ZW19Lng6aG92ZXJ7Ym9yZGVyLWNvbG9yOnZhcigtLWVycil9Ci5lbXB0eXtjb2xvcjp2
YXIoLS1tdXQyKTtmb250LXNpemU6MTNweDtwYWRkaW5nOjhweCAwfQoubG9ne2JhY2tncm91bmQ6
IzAzMGExODtib3JkZXI6MXB4IHNvbGlkIHZhcigtLWxpbmUpO3BhZGRpbmc6MTRweDtmb250OjEy
cHgvMS41NSB2YXIoLS1tb25vKTtoZWlnaHQ6NDQwcHg7b3ZlcmZsb3c6YXV0bzt3aGl0ZS1zcGFj
ZTpwcmUtd3JhcDtjb2xvcjojOWZiM2QwfQoudG9vbGJhcntkaXNwbGF5OmZsZXg7Z2FwOjhweDth
bGlnbi1pdGVtczpjZW50ZXI7bWFyZ2luLWJvdHRvbToxMnB4fS50b29sYmFyIGlucHV0e2ZsZXg6
MX0KLmVme3dpZHRoOjEwMCU7Ym9yZGVyLWNvbGxhcHNlOmNvbGxhcHNlO2ZvbnQtc2l6ZToxM3B4
O21hcmdpbi10b3A6NnB4fS5lZiB0aHt0ZXh0LWFsaWduOmxlZnQ7Y29sb3I6dmFyKC0tbXV0KTtm
b250LXNpemU6MTFweDt0ZXh0LXRyYW5zZm9ybTp1cHBlcmNhc2U7bGV0dGVyLXNwYWNpbmc6LjA3
ZW07cGFkZGluZzo4cHggNnB4O2JvcmRlci1ib3R0b206MXB4IHNvbGlkIHZhcigtLWxpbmUyKX0u
ZWYgdGR7cGFkZGluZzoxMHB4IDZweDtib3JkZXItYm90dG9tOjFweCBzb2xpZCB2YXIoLS1saW5l
KTt2ZXJ0aWNhbC1hbGlnbjp0b3B9LmVmIGNvZGV7Zm9udC1mYW1pbHk6dmFyKC0tbW9ubyk7Y29s
b3I6dmFyKC0tYWNjKTt3b3JkLWJyZWFrOmJyZWFrLWFsbDt1c2VyLXNlbGVjdDphbGx9Lm11dHtj
b2xvcjp2YXIoLS1tdXQpO2ZvbnQtc2l6ZToxMXB4fWNvZGV7Zm9udC1mYW1pbHk6dmFyKC0tbW9u
byl9QG1lZGlhKG1heC13aWR0aDo1NjBweCl7LnJvdywucm93M3tncmlkLXRlbXBsYXRlLWNvbHVt
bnM6MWZyfX0KPC9zdHlsZT48L2hlYWQ+PGJvZHk+CjxoZWFkZXI+CiA8ZGl2IGNsYXNzPWJyYW5k
PjxzdmcgeG1sbnM9Imh0dHA6Ly93d3cudzMub3JnLzIwMDAvc3ZnIiB2aWV3Qm94PSItMjAgLTIw
IDY2OCAzMzAiIHJvbGU9ImltZyIgYXJpYS1sYWJlbD0icEtPTSI+PGcgZmlsbD0ibm9uZSIgc3Ry
b2tlLWxpbmVjYXA9InJvdW5kIiBzdHJva2UtbGluZWpvaW49InJvdW5kIiBzdHJva2Utd2lkdGg9
IjMyIj48ZyBzdHJva2U9IiNGRkZGRkYiPjxwYXRoIGQ9Ik0yMCA4MCBWMjY2Ij48L3BhdGg+PGNp
cmNsZSBjeD0iNzIiIGN5PSIxMzMiIHI9IjUyIj48L2NpcmNsZT48cGF0aCBkPSJNMTc4IDE2IFEy
MDYgMTAwIDE3OCAxODQiPjwvcGF0aD48cGF0aCBkPSJNMTkyIDEwMCBDMjI2IDk2IDI1MCA2MiAy
NjYgMTYiPjwvcGF0aD48cGF0aCBkPSJNNDkyIDE4NCBWMzAgQzUyMiAzMCA1MzQgMTA2IDU1MiAx
MDYgQzU3MCAxMDYgNTgyIDMwIDYxMiAzMCBWMTg0Ij48L3BhdGg+PC9nPjxwYXRoIHN0cm9rZT0i
IzJFQzRGMSIgZD0iTTE5MiAxMDAgQzIzMyAxMDIgMjU2IDE4MyAzNjMgMTgzIEE4MyA4MyAwIDAg
MCAzNjMgMTcgQTgzIDgzIDAgMCAwIDI4MiAxMTgiPjwvcGF0aD48L2c+PC9zdmc+PHNwYW4gY2xh
c3M9cHJvZD5OZXR6c3RldWVydW5nPC9zcGFuPjwvZGl2PgogPGRpdiBjbGFzcz1jaGlwPjxzcGFu
IGNsYXNzPWRvdCBpZD1kb3Q+PC9zcGFuPjxzcGFuIGlkPXN0YXRlPuKAkzwvc3Bhbj48L2Rpdj4K
IDxkaXYgY2xhc3M9aHN0YXQ+CiAgPHNwYW4gaWQ9dGVjaGJhZGdlIGNsYXNzPWJhZGdlIHN0eWxl
PWRpc3BsYXk6bm9uZT48L3NwYW4+CiAgPHNwYW4+RnJlcXVlbnogPGIgaWQ9ZnJlcT7igJM8L2I+
PC9zcGFuPgogIDxzcGFuPkxhdWZ6ZWl0IDxiIGlkPXVwdGltZT7igJM8L2I+PC9zcGFuPgogIDxz
cGFuIGlkPW1zZz48L3NwYW4+CiA8L2Rpdj4KPC9oZWFkZXI+CjxkaXYgY2xhc3M9d3JhcD4KIDxk
aXYgY2xhc3M9YmFubmVyPjxzcGFuPuKaoO+4jzwvc3Bhbj48c3Bhbj48Yj5OdXIgYWJnZXNjaG90
dGV0IGJldHJlaWJlbjwvYj4g4oCTIER1bW15IExvYWQgLyBLYWJlbCArIETDpG1wZnVuZyAvIGdl
c2NoaXJtdC4gT2ZmZW5lcyBOZXR6IG9obmUgQXV0aGVudGlzaWVydW5nID0gSU1TSS1DYXRjaGVy
LCB3ZW5uIGVzIGFic3RyYWhsdC4gTnVyIGVpZ2VuZSBUZXN0LVNJTXMsIEtlbm51bmcgMDAxL3h4
IChUZXN0KSBvZGVyIDk5OS94eCAocHJpdmF0KS48L3NwYW4+PC9kaXY+CgogPGRpdiBjbGFzcz1j
b250cm9scz4KICA8YnV0dG9uIGNsYXNzPWJpZ2J0biBpZD1idG5fZ3NtIG9uY2xpY2s9ImNtZCgn
c3RhcnRfZ3NtJykiPjxzcGFuIGNsYXNzPWljPuKWtjwvc3Bhbj48c3Bhbj5HU00gKDJHKTxzbWFs
bCBpZD1nc21fc3ViPk9zbW9jb208L3NtYWxsPjwvc3Bhbj48L2J1dHRvbj4KICA8YnV0dG9uIGNs
YXNzPWJpZ2J0biBpZD1idG5fbHRlIG9uY2xpY2s9ImNtZCgnc3RhcnRfbHRlJykiPjxzcGFuIGNs
YXNzPWljPuKWtjwvc3Bhbj48c3Bhbj5MVEUgKDRHKTxzbWFsbCBpZD1sdGVfc3ViPnNyc1JBTiAr
IE9wZW41R1M8L3NtYWxsPjwvc3Bhbj48L2J1dHRvbj4KICA8YnV0dG9uIGNsYXNzPWJpZ2J0biBp
ZD1idG5fY3NmYiBvbmNsaWNrPSJjbWQoJ3N0YXJ0X2NzZmInKSI+PHNwYW4gY2xhc3M9aWM+4pa2
PC9zcGFuPjxzcGFuPkxURSArIEdTTTxzbWFsbCBpZD1jc2ZiX3N1Yj5JbnRlcm5ldCArIEFucnVm
ZSAoQ1NGQik8L3NtYWxsPjwvc3Bhbj48L2J1dHRvbj4KICA8YnV0dG9uIGNsYXNzPSJiaWdidG4g
c3RvcCIgb25jbGljaz0iY21kKCdzdG9wJykiPuKWoCBTdG9wcGVuPC9idXR0b24+CiA8L2Rpdj4K
CiA8ZGl2IGNsYXNzPXRhYnM+CiAgPGJ1dHRvbiBjbGFzcz0idGFiIHNlbCIgZGF0YS10PXN0ZXVl
cnVuZyBvbmNsaWNrPSJ0YWIoJ3N0ZXVlcnVuZycpIj5TdGV1ZXJ1bmc8L2J1dHRvbj4KICA8YnV0
dG9uIGNsYXNzPXRhYiBkYXRhLXQ9Z3NtIG9uY2xpY2s9InRhYignZ3NtJykiPkdTTSDCtyAyRzwv
YnV0dG9uPgogIDxidXR0b24gY2xhc3M9dGFiIGRhdGEtdD1sdGUgb25jbGljaz0idGFiKCdsdGUn
KSI+TFRFIMK3IDRHPC9idXR0b24+CiAgPGJ1dHRvbiBjbGFzcz10YWIgZGF0YS10PXNpbXMgb25j
bGljaz0idGFiKCdzaW1zJykiPlNJTXMgJiBOdW1tZXJuPC9idXR0b24+CiAgPGJ1dHRvbiBjbGFz
cz10YWIgZGF0YS10PXByb2ZpbCBvbmNsaWNrPSJ0YWIoJ3Byb2ZpbCcpIj5TSU0tUHJvZmlsPC9i
dXR0b24+CiAgPGJ1dHRvbiBjbGFzcz10YWIgZGF0YS10PWxvZyBvbmNsaWNrPSJ0YWIoJ2xvZycp
Ij5Qcm90b2tvbGw8L2J1dHRvbj4KIDwvZGl2PgoKIDxkaXYgY2xhc3M9InBhbmVsIHNlbCIgaWQ9
cC1zdGV1ZXJ1bmc+CiAgPGRpdiBjbGFzcz1ncmlkPgogICA8ZGl2IGNsYXNzPWNhcmQ+CiAgICA8
aDI+U3RhdHVzPC9oMj4KICAgIDxkaXYgY2xhc3M9ZnJlcWJveCBzdHlsZT1tYXJnaW4tdG9wOjEy
cHg+CiAgICAgPGRpdj48ZGl2IGNsYXNzPWJpZyBpZD1mcmVxMj7igJM8L2Rpdj48ZGl2IGNsYXNz
PXNtIGlkPWZyZXFzdWI+PC9kaXY+PC9kaXY+CiAgICAgPGRpdiBzdHlsZT10ZXh0LWFsaWduOnJp
Z2h0PjxkaXYgY2xhc3M9YmlnIGlkPXRlY2gyPmF1czwvZGl2PjxkaXYgY2xhc3M9c20gaWQ9c3Rh
dGVzdWI+PC9kaXY+PC9kaXY+CiAgICA8L2Rpdj4KICAgIDxkaXYgY2xhc3M9aGludCBpZD11cHRp
bWVoaW50PjwvZGl2PgogICAgPGRpdiBjbGFzcz1oaW50IGlkPWRldmhpbnQ+PC9kaXY+CiAgICA8
ZGl2IGNsYXNzPWhpbnQgaWQ9Y2xhc2ggc3R5bGU9Y29sb3I6dmFyKC0tZXJyKT48L2Rpdj4KICAg
PC9kaXY+CiAgIDxkaXYgY2xhc3M9Y2FyZD4KICAgIDxoMj5GdW5rLUhhcmR3YXJlPC9oMj4KICAg
IDxwIGNsYXNzPXN1Yj5KZSBOZXR6IGVpbiBlaWdlbmVyIExpbWVTRFIuIEbDvHIg4oCeTFRFICsg
R1NN4oCcIHp3ZWkgdmVyc2NoaWVkZW5lIHfDpGhsZW4uPC9wPgogICAgPGxhYmVsPkxpbWVTRFIg
ZsO8ciBHU00gKDJHKTwvbGFiZWw+PHNlbGVjdCBpZD1HU01fREVWPjwvc2VsZWN0PgogICAgPGxh
YmVsPkxpbWVTRFIgZsO8ciBMVEUgKDRHKTwvbGFiZWw+PHNlbGVjdCBpZD1MVEVfREVWPjwvc2Vs
ZWN0PgogICAgPGRpdiBzdHlsZT1kaXNwbGF5OmZsZXg7Z2FwOjhweDtmbGV4LXdyYXA6d3JhcD4K
ICAgICA8YnV0dG9uIGNsYXNzPWJ0biBvbmNsaWNrPSJzYXZlKFsnR1NNX0RFVicsJ0xURV9ERVYn
XSkiPlNwZWljaGVybjwvYnV0dG9uPgogICAgIDxidXR0b24gY2xhc3M9ImJ0biBzZWMiIG9uY2xp
Y2s9ImNtZCgnbGltZV9zY2FuJykiPk5ldSBzdWNoZW48L2J1dHRvbj4KICAgIDwvZGl2PgogICAg
PGRpdiBjbGFzcz1oaW50IGlkPWxpbWVsaXN0PjwvZGl2PgogICA8L2Rpdj4KICAgPGRpdiBjbGFz
cz1jYXJkPgogICAgPGgyPk5ldHotSWRlbnRpdMOkdDwvaDI+CiAgICA8cCBjbGFzcz1zdWI+R2ls
dCBmw7xyIEdTTSB1bmQgTFRFLiBOdXIgVGVzdGtlbm51bmcgMDAxL3h4IG9kZXIgUHJpdmF0a2Vu
bnVuZyA5OTkveHguPC9wPgogICAgPGRpdiBjbGFzcz1yb3c+CiAgICAgPGRpdj48bGFiZWw+TUND
PC9sYWJlbD48aW5wdXQgaWQ9TUNDIGlucHV0bW9kZT1udW1lcmljPjwvZGl2PgogICAgIDxkaXY+
PGxhYmVsPk1OQzwvbGFiZWw+PGlucHV0IGlkPU1OQyBpbnB1dG1vZGU9bnVtZXJpYz48L2Rpdj4K
ICAgIDwvZGl2PgogICAgPGRpdiBjbGFzcz1yb3c+CiAgICAgPGRpdj48bGFiZWw+TmV0em5hbWUg
KGxhbmcpPC9sYWJlbD48aW5wdXQgaWQ9TkVUTkFNRT48L2Rpdj4KICAgICA8ZGl2PjxsYWJlbD5O
ZXR6bmFtZSAoa3Vyeik8L2xhYmVsPjxpbnB1dCBpZD1ORVROQU1FX1NIT1JUPjwvZGl2PgogICAg
PC9kaXY+CiAgICA8bGFiZWw+QW5iaWV0ZXJuYW1lIChTUE4sIG1heC4gMTYgWmVpY2hlbik8L2xh
YmVsPjxpbnB1dCBpZD1TUE4gbWF4bGVuZ3RoPTE2PgogICAgPGRpdiBjbGFzcz1zdz48ZGl2IGNs
YXNzPXQ+TklUWiBzZW5kZW48c21hbGw+TmV0em5hbWUsIFVocnplaXQgdW5kIFplaXR6b25lICg8
c3BhbiBpZD10ej7igJM8L3NwYW4+KSBiZWltIEVpbmJ1Y2hlbjwvc21hbGw+PC9kaXY+CiAgICAg
PGxhYmVsIGNsYXNzPXN3aXRjaD48aW5wdXQgdHlwZT1jaGVja2JveCBpZD1OSVRaPjxzcGFuIGNs
YXNzPXNsaWRlcj48L3NwYW4+PC9sYWJlbD48L2Rpdj4KICAgIDxidXR0b24gY2xhc3M9ImJ0biBz
ZWMiIG9uY2xpY2s9InNhdmUoWydNQ0MnLCdNTkMnLCdORVROQU1FJywnTkVUTkFNRV9TSE9SVCcs
J1NQTicsJ05JVFonXSkiPlNwZWljaGVybjwvYnV0dG9uPgogICAgPHAgY2xhc3M9aGludD5EYW1p
dCBkYXMgaVBob25lIGRhcyBOZXR6IGFscyA8Yj5IZWltbmV0ejwvYj4gc2llaHQgKGtlaW4gUm9h
bWluZyksIG11c3MgZGllIElNU0kgZGVyIGVTSU0gbWl0IE1DQytNTkMgYmVnaW5uZW46IDxiIGNs
YXNzPXRhZyBpZD1ocGxtbj7igJM8L2I+4oCmPC9wPgogICA8L2Rpdj4KICA8L2Rpdj4KIDwvZGl2
PgoKIDxkaXYgY2xhc3M9cGFuZWwgaWQ9cC1nc20+CiAgPGRpdiBjbGFzcz1ncmlkPgogICA8ZGl2
IGNsYXNzPWNhcmQ+CiAgICA8aDI+R1NNLUZ1bms8L2gyPgogICAgPGRpdiBjbGFzcz1yb3cgc3R5
bGU9YWxpZ24taXRlbXM6ZW5kPgogICAgIDxkaXY+PGxhYmVsPkFSRkNOPC9sYWJlbD48aW5wdXQg
aWQ9R1NNX0FSRkNOIG9uaW5wdXQ9dXBkYXRlRnJlcSgpPjwvZGl2PgogICAgIDxkaXYgY2xhc3M9
ZnJlcWJveD48ZGl2PjxkaXYgY2xhc3M9YmlnIGlkPWdzbV9taHo+4oCTPC9kaXY+PGRpdiBjbGFz
cz1zbSBpZD1nc21fYmFuZD48L2Rpdj48L2Rpdj48L2Rpdj4KICAgIDwvZGl2PgogICAgPGRpdiBj
bGFzcz1oaW50PjHigJMxMjQgPSBHU005MDAgwrcgNTEy4oCTODg1ID0gRENTMTgwMDwvZGl2Pgog
ICAgPGRpdiBjbGFzcz1yb3c+PGRpdj48bGFiZWw+VFgtR2FpbjwvbGFiZWw+PGlucHV0IGlkPUdT
TV9UWF9HQUlOPjwvZGl2PgogICAgIDxkaXY+PGxhYmVsPlJYLUdhaW4gKDDigJM1MCk8L2xhYmVs
PjxpbnB1dCBpZD1HU01fUlhfR0FJTj48L2Rpdj48L2Rpdj4KICAgIDxkaXYgY2xhc3M9aGludD5S
WC1HYWluIGhvY2ggPSBlbXBmaW5kbGljaGVyZXIgRW1wZmFuZyAod2ljaHRpZyBmw7xyIEVER0Ut
VXBsaW5rKS48L2Rpdj4KICAgIDxidXR0b24gY2xhc3M9YnRuIG9uY2xpY2s9InNhdmUoWydHU01f
QVJGQ04nLCdHU01fVFhfR0FJTicsJ0dTTV9SWF9HQUlOJ10pIj5TcGVpY2hlcm48L2J1dHRvbj4K
ICAgPC9kaXY+CiAgIDxkaXYgY2xhc3M9Y2FyZD4KICAgIDxoMj5HU00tT3B0aW9uZW48L2gyPgog
ICAgPGRpdiBjbGFzcz0ic3cgZmlyc3QiPjxkaXYgY2xhc3M9dD5PZmZlbmUgQW5tZWxkdW5nPHNt
YWxsPmplZGUgU0lNIHdpcmQgZWluZ2VidWNodDwvc21hbGw+PC9kaXY+CiAgICAgPGxhYmVsIGNs
YXNzPXN3aXRjaD48aW5wdXQgdHlwZT1jaGVja2JveCBpZD1HU01fT1BFTj48c3BhbiBjbGFzcz1z
bGlkZXI+PC9zcGFuPjwvbGFiZWw+PC9kaXY+CiAgICA8ZGl2IGNsYXNzPXN3PjxkaXYgY2xhc3M9
dD5FREdFIC8gR1BSUy1EYXRlbjxzbWFsbD5QYWtldGRhdGVuIChwY3Uvc2dzbi9nZ3NuKTwvc21h
bGw+PC9kaXY+CiAgICAgPGxhYmVsIGNsYXNzPXN3aXRjaD48aW5wdXQgdHlwZT1jaGVja2JveCBp
ZD1HU01fREFUQT48c3BhbiBjbGFzcz1zbGlkZXI+PC9zcGFuPjwvbGFiZWw+PC9kaXY+CiAgICA8
ZGl2IGNsYXNzPXN3PjxkaXYgY2xhc3M9dD5TSVAtVHJ1bmsgenUgQXN0ZXJpc2s8c21hbGw+QW5y
dWZlIGlucyBWb0lQL0Zlc3RuZXR6PC9zbWFsbD48L2Rpdj4KICAgICA8bGFiZWwgY2xhc3M9c3dp
dGNoPjxpbnB1dCB0eXBlPWNoZWNrYm94IGlkPUdTTV9TSVA+PHNwYW4gY2xhc3M9c2xpZGVyPjwv
c3Bhbj48L2xhYmVsPjwvZGl2PgogICAgPGxhYmVsPlNJUC1QZWVyIChBc3Rlcmlzay1JUCk8L2xh
YmVsPjxpbnB1dCBpZD1HU01fU0lQX1BFRVI+CiAgICA8bGFiZWw+U0lQLUxvY2FsLUlQIChsZWVy
ID0gYXV0b21hdGlzY2gpPC9sYWJlbD48aW5wdXQgaWQ9R1NNX1NJUF9MT0NBTD4KICAgIDxidXR0
b24gY2xhc3M9YnRuIG9uY2xpY2s9InNhdmUoWydHU01fT1BFTicsJ0dTTV9EQVRBJywnR1NNX1NJ
UCcsJ0dTTV9TSVBfUEVFUicsJ0dTTV9TSVBfTE9DQUwnXSkiPlNwZWljaGVybjwvYnV0dG9uPgog
ICA8L2Rpdj4KICAgPGRpdiBjbGFzcz1jYXJkPgogICAgPGgyPkJlZ3LDvMOfdW5ncy1TTVM8L2gy
PgogICAgPHAgY2xhc3M9c3ViPlNNUyBiZWltIEVpbmJ1Y2hlbiB1bmQgYmVpIE51bW1lcm52ZXJn
YWJlLiBQbGF0emhhbHRlcjogPGNvZGU+e25ldHp9PC9jb2RlPiwgPGNvZGU+e251bW1lcn08L2Nv
ZGU+LCA8Y29kZT57ZXh0ZXJufTwvY29kZT4uPC9wPgogICAgPGRpdiBjbGFzcz0ic3cgZmlyc3Qi
PjxkaXYgY2xhc3M9dD5TTVMgYWt0aXY8c21hbGw+V2lsbGtvbW1lbiArIE51bW1lcm4tQmVzdMOk
dGlndW5nPC9zbWFsbD48L2Rpdj4KICAgICA8bGFiZWwgY2xhc3M9c3dpdGNoPjxpbnB1dCB0eXBl
PWNoZWNrYm94IGlkPUdTTV9TTVM+PHNwYW4gY2xhc3M9c2xpZGVyPjwvc3Bhbj48L2xhYmVsPjwv
ZGl2PgogICAgPGxhYmVsPkFic2VuZGVyLU51bW1lcjwvbGFiZWw+PGlucHV0IGlkPUdTTV9TTVNf
RlJPTT4KICAgIDxsYWJlbD5FeHRlcm5lIFZvcndhaGwgKDxjb2RlPntleHRlcm59PC9jb2RlPiA9
IFZvcndhaGwgKyBpbnRlcm5lIE51bW1lcik8L2xhYmVsPjxpbnB1dCBpZD1HU01fU01TX0VYVFBS
RUZJWD4KICAgIDxsYWJlbD5XaWxsa29tbWVuc3RleHQgKGJlaW0gRWluYnVjaGVuKTwvbGFiZWw+
PGlucHV0IGlkPUdTTV9TTVNfV0VMQ09NRT4KICAgIDxsYWJlbD5CZXN0w6R0aWd1bmcgKGJlaSBO
dW1tZXJudmVyZ2FiZSk8L2xhYmVsPjxpbnB1dCBpZD1HU01fU01TX05VTUJFUj4KICAgIDxidXR0
b24gY2xhc3M9YnRuIG9uY2xpY2s9InNhdmUoWydHU01fU01TJywnR1NNX1NNU19GUk9NJywnR1NN
X1NNU19FWFRQUkVGSVgnLCdHU01fU01TX1dFTENPTUUnLCdHU01fU01TX05VTUJFUiddKSI+U3Bl
aWNoZXJuPC9idXR0b24+CiAgICA8cCBjbGFzcz1oaW50PkJlZ3LDvMOfdW5nIHdpcmQgamUgTmV0
ei1TdGFydCBlaW5tYWwgcHJvIFNJTSBnZXNlbmRldCAod2lya3Qgc29mb3J0KS48L3A+CiAgICA8
ZGl2IHN0eWxlPSJib3JkZXItdG9wOjFweCBzb2xpZCB2YXIoLS1saW5lKTttYXJnaW46MTRweCAw
Ij48L2Rpdj4KICAgIDxkaXYgY2xhc3M9cm93PjxkaXY+PGxhYmVsPlRlc3Q6IElNU0k8L2xhYmVs
PjxpbnB1dCBpZD1zbXNfdGVzdF9pbXNpPjwvZGl2PgogICAgIDxkaXY+PGxhYmVsPlRleHQgKGxl
ZXIgPSBXaWxsa29tbWVuc3RleHQpPC9sYWJlbD48aW5wdXQgaWQ9c21zX3Rlc3RfdGV4dD48L2Rp
dj48L2Rpdj4KICAgIDxidXR0b24gY2xhc3M9ImJ0biBzZWMiIG9uY2xpY2s9InNtc3Rlc3QoKSI+
VGVzdC1TTVMgc2VuZGVuPC9idXR0b24+CiAgICA8cCBjbGFzcz1oaW50PlNlbmRldCBzb2ZvcnQg
YW4gZGllIElNU0kg4oCTIGF1Y2ggd2VubiDigJ5TTVMgYWt0aXYiIGF1cyBpc3QuIEdTTSBtdXNz
IGxhdWZlbi48L3A+CiAgIDwvZGl2PgogIDwvZGl2PgogIDxwIGNsYXNzPWhpbnQ+RnVuay0vT3B0
aW9ucy3DhG5kZXJ1bmdlbiB3aXJrZW4gYmVpbSBuw6RjaHN0ZW4gR1NNLVN0YXJ0LjwvcD4KIDwv
ZGl2PgoKIDxkaXYgY2xhc3M9cGFuZWwgaWQ9cC1sdGU+CiAgPGRpdiBjbGFzcz1ncmlkPgogICA8
ZGl2IGNsYXNzPWNhcmQ+CiAgICA8aDI+TFRFLUZ1bms8L2gyPgogICAgPGRpdiBjbGFzcz1yb3cg
c3R5bGU9YWxpZ24taXRlbXM6ZW5kPgogICAgIDxkaXY+PGxhYmVsPkVBUkZDTjwvbGFiZWw+PGlu
cHV0IGlkPUxURV9FQVJGQ04gb25pbnB1dD11cGRhdGVGcmVxKCk+PC9kaXY+CiAgICAgPGRpdiBj
bGFzcz1mcmVxYm94PjxkaXY+PGRpdiBjbGFzcz1iaWcgaWQ9bHRlX21oej7igJM8L2Rpdj48ZGl2
IGNsYXNzPXNtIGlkPWx0ZV9iYW5kPjwvZGl2PjwvZGl2PjwvZGl2PgogICAgPC9kaXY+CiAgICA8
bGFiZWw+QmFuZGJyZWl0ZSAoUFJCKTwvbGFiZWw+PHNlbGVjdCBpZD1MVEVfTlBSQj4KICAgICA8
b3B0aW9uIHZhbHVlPTY+NiDCtyAxLjQgTUh6PC9vcHRpb24+PG9wdGlvbiB2YWx1ZT0xNT4xNSDC
tyAzIE1Iejwvb3B0aW9uPgogICAgIDxvcHRpb24gdmFsdWU9MjU+MjUgwrcgNSBNSHo8L29wdGlv
bj48b3B0aW9uIHZhbHVlPTUwPjUwIMK3IDEwIE1Iejwvb3B0aW9uPgogICAgIDxvcHRpb24gdmFs
dWU9NzU+NzUgwrcgMTUgTUh6PC9vcHRpb24+PG9wdGlvbiB2YWx1ZT0xMDA+MTAwIMK3IDIwIE1I
ejwvb3B0aW9uPjwvc2VsZWN0PgogICAgPGRpdiBjbGFzcz1oaW50PlNjaHdhY2hlIEhhcmR3YXJl
IChQaSk6IGtsZWluIHfDpGhsZW4gKDbigJMyNSkuPC9kaXY+CiAgICA8YnV0dG9uIGNsYXNzPWJ0
biBvbmNsaWNrPSJzYXZlKFsnTFRFX0VBUkZDTicsJ0xURV9OUFJCJ10pIj5TcGVpY2hlcm48L2J1
dHRvbj4KICAgPC9kaXY+CiAgIDxkaXYgY2xhc3M9Y2FyZD4KICAgIDxoMj5MVEUtUGFyYW1ldGVy
PC9oMj4KICAgIDxkaXYgY2xhc3M9cm93PjxkaXY+PGxhYmVsPlRYLUdhaW48L2xhYmVsPjxpbnB1
dCBpZD1MVEVfVFhfR0FJTj48L2Rpdj4KICAgICA8ZGl2PjxsYWJlbD5SWC1HYWluPC9sYWJlbD48
aW5wdXQgaWQ9TFRFX1JYX0dBSU4+PC9kaXY+PC9kaXY+CiAgICA8bGFiZWw+QVBOPC9sYWJlbD48
aW5wdXQgaWQ9TFRFX0FQTj4KICAgIDxidXR0b24gY2xhc3M9YnRuIG9uY2xpY2s9InNhdmUoWydM
VEVfVFhfR0FJTicsJ0xURV9SWF9HQUlOJywnTFRFX0FQTiddKSI+U3BlaWNoZXJuPC9idXR0b24+
CiAgICA8cCBjbGFzcz1oaW50PkxURSBicmF1Y2h0IFNJTXMgbWl0IEtpL09QYyAoVGFiIOKAnlNJ
TXPigJwpLiBLZXJuOiBPcGVuNUdTLCBIYW5keS1OZXR6IDEwLjQ1LjAuMC8xNiBtaXQgTkFUIGlu
cyBJbnRlcm5ldC4gQmVpIOKAnkxURSArIEdTTeKAnCBkYXJmIGRpZSBHU00tRnJlcXVlbnogbmlj
aHQgaW0gTFRFLUthbmFsIGxpZWdlbi48L3A+CiAgIDwvZGl2PgogIDwvZGl2PgogPC9kaXY+Cgog
PGRpdiBjbGFzcz1wYW5lbCBpZD1wLXNpbXM+CiAgPGRpdiBjbGFzcz1ncmlkPgogICA8ZGl2IGNs
YXNzPWNhcmQ+CiAgICA8aDI+U0lNIGVpbnRyYWdlbjwvaDI+CiAgICA8cCBjbGFzcz1zdWI+RWlu
bWFsIGVpbnRyYWdlbiDigJMgcEtPTSBzY2hyZWlidCBzaWUgYXV0b21hdGlzY2ggaW5zIEdTTS1I
TFIgdW5kIGluIGRlbiBMVEUtSFNTLjwvcD4KICAgIDxkaXYgY2xhc3M9cm93PjxkaXY+PGxhYmVs
PklNU0k8L2xhYmVsPjxpbnB1dCBpZD1zaW1faW1zaSBpbnB1dG1vZGU9bnVtZXJpYz48L2Rpdj48
ZGl2PjxsYWJlbD5SdWZudW1tZXI8L2xhYmVsPjxpbnB1dCBpZD1zaW1fbnIgaW5wdXRtb2RlPW51
bWVyaWM+PC9kaXY+PC9kaXY+CiAgICA8ZGl2IGNsYXNzPXJvdz48ZGl2PjxsYWJlbD5LaSAoMzIg
SGV4KTwvbGFiZWw+PGlucHV0IGlkPXNpbV9raSBhdXRvY29tcGxldGU9b2ZmPjwvZGl2PjxkaXY+
PGxhYmVsPk9QYyAoMzIgSGV4KTwvbGFiZWw+PGlucHV0IGlkPXNpbV9vcGMgYXV0b2NvbXBsZXRl
PW9mZj48L2Rpdj48L2Rpdj4KICAgIDxidXR0b24gY2xhc3M9ImJ0biBzbSIgb25jbGljaz0ic2lt
YWRkKCkiPlNJTSBzcGVpY2hlcm48L2J1dHRvbj4KICAgIDxkaXYgc3R5bGU9bWFyZ2luLXRvcDox
MnB4IGlkPXNpbXM+PC9kaXY+CiAgIDwvZGl2PgogICA8ZGl2IGNsYXNzPWNhcmQ+CiAgICA8aDI+
RWluZ2VidWNodGUgSGFuZHlzPC9oMj4KICAgIDxwIGNsYXNzPXN1Yj5Ba3R1ZWxsIGltIFNwcmFj
aG5ldHogKE1TQykgYW5nZW1lbGRldCDigJMgYmVpIOKAnkxURSArIEdTTeKAnCBhdWNoIMO8YmVy
IExURS9TR3MuPC9wPgogICAgPGRpdiBpZD1hdHRhY2hlZD48L2Rpdj4KICAgPC9kaXY+CiAgIDxk
aXYgY2xhc3M9Y2FyZD4KICAgIDxoMj5OdW1tZXIgZGF1ZXJoYWZ0IHp1d2Vpc2VuPC9oMj4KICAg
IDxwIGNsYXNzPXN1Yj5BdWNoIGbDvHIgb2ZmZW4gYW5nZW1lbGRldGUgR1NNLVNJTXMgb2huZSBL
aSDigJMgw7xiZXJsZWJ0IE5ldXN0YXJ0cy48L3A+CiAgICA8ZGl2IGNsYXNzPXJvdz48ZGl2Pjxs
YWJlbD5JTVNJPC9sYWJlbD48aW5wdXQgaWQ9Z251bV9pbXNpPjwvZGl2PjxkaXY+PGxhYmVsPlJ1
Zm51bW1lcjwvbGFiZWw+PGlucHV0IGlkPWdudW1fbnI+PC9kaXY+PC9kaXY+CiAgICA8YnV0dG9u
IGNsYXNzPSJidG4gc20iIG9uY2xpY2s9InNpbW5yKCkiPlp1d2Vpc2VuPC9idXR0b24+CiAgICA8
ZGl2IHN0eWxlPW1hcmdpbi10b3A6MTJweCBpZD1nc21fbnVtYmVycz48L2Rpdj4KICAgPC9kaXY+
CiAgPC9kaXY+CiA8L2Rpdj4KCiA8ZGl2IGNsYXNzPXBhbmVsIGlkPXAtcHJvZmlsPgogIDxkaXYg
Y2xhc3M9Y2FyZD4KICAgPGgyPldlcnRlIGbDvHIgZGFzIGVTSU0tUHJvZmlsPC9oMj4KICAgPHAg
Y2xhc3M9c3ViPk9QTCwgUE5OIHVuZCBTUE4gc2luZCBEYXRlaWVuIDxiPmF1ZiBkZXIgU0lNPC9i
PiDigJMgZGFzIE5ldHoga2FubiBzaWUgbmljaHQgc2V0emVuLiBEaWVzZSBXZXJ0ZSBwYXNzZW4g
enUgS2VubnVuZyB1bmQgTmV0em5hbWUgb2JlbiB1bmQgd2VyZGVuIGltIGVTSU0tUHJvZmlsICh6
LiZuYnNwO0IuIHNpbWxlc3NseSkgZWluZ2V0cmFnZW4uIE5JVFogc2NoaWNrdCBwS09NIHNlbGJz
dC48L3A+CiAgIDx0YWJsZSBjbGFzcz1lZj4KICAgIDx0cj48dGg+RGF0ZWk8L3RoPjx0aD5Jbmhh
bHQ8L3RoPjx0aD5XZXJ0IChIZXgpPC90aD48L3RyPgogICAgPHRyPjx0ZD48Yj5TUE48L2I+PGJy
PjxzcGFuIGNsYXNzPW11dD5FRiA2RjQ2PC9zcGFuPjwvdGQ+PHRkIGlkPWVmX3Nwbl90PjwvdGQ+
PHRkPjxjb2RlIGlkPWVmX3Nwbj48L2NvZGU+PC90ZD48L3RyPgogICAgPHRyPjx0ZD48Yj5QTk48
L2I+PGJyPjxzcGFuIGNsYXNzPW11dD5FRiA2RkM1LCBFaW50cmFnIDE8L3NwYW4+PC90ZD48dGQg
aWQ9ZWZfcG5uX3Q+PC90ZD48dGQ+PGNvZGUgaWQ9ZWZfcG5uPjwvY29kZT48L3RkPjwvdHI+CiAg
ICA8dHI+PHRkPjxiPk9QTDwvYj48YnI+PHNwYW4gY2xhc3M9bXV0PkVGIDZGQzYsIEVpbnRyYWcg
MTwvc3Bhbj48L3RkPjx0ZCBpZD1lZl9vcGxfdD48L3RkPjx0ZD48Y29kZSBpZD1lZl9vcGw+PC9j
b2RlPjwvdGQ+PC90cj4KICAgIDx0cj48dGQ+PGI+SFBMTU48L2I+PGJyPjxzcGFuIGNsYXNzPW11
dD5JTVNJLUFuZmFuZzwvc3Bhbj48L3RkPjx0ZD5IZWltbmV0ei1LZW5udW5nPC90ZD48dGQ+PGNv
ZGUgaWQ9ZWZfaHBsbW4+PC9jb2RlPjwvdGQ+PC90cj4KICAgPC90YWJsZT4KICAgPHAgY2xhc3M9
aGludD5EYXRlbnPDpHR6ZSBiZWkgZmVzdGVyIEzDpG5nZSBtaXQgPGNvZGU+RkY8L2NvZGU+IGF1
ZmbDvGxsZW4uIEluIGRlciBVU0lNLURpZW5zdHRhYmVsbGUgKFVTVCkgbcO8c3NlbiBkaWUgRGll
bnN0ZSA8Yj4xNzwvYj4gKFNQTiksIDxiPjQ1PC9iPiAoUE5OKSB1bmQgPGI+NDY8L2I+IChPUEwp
IGFrdGl2IHNlaW4uIMOEbmRlcm4gc2ljaCBLZW5udW5nIG9kZXIgTmFtZSwgZGllIFdlcnRlIGhp
ZXIgbmV1IMO8YmVybmVobWVuLjwvcD4KICA8L2Rpdj4KIDwvZGl2PgoKIDxkaXYgY2xhc3M9cGFu
ZWwgaWQ9cC1sb2c+CiAgPGRpdiBjbGFzcz1jYXJkPgogICA8ZGl2IGNsYXNzPXRvb2xiYXI+PGgy
IHN0eWxlPW1hcmdpbjowPlByb3Rva29sbDwvaDI+PGlucHV0IGlkPWxvZ2ZpbHRlciBwbGFjZWhv
bGRlcj0iZmlsdGVybuKApiB6LkIuIEdQUlMsIFRCRiwgZXJyb3IiIG9uaW5wdXQ9cmVuZGVybG9n
KCk+PHNwYW4gY2xhc3M9YmFkZ2UgaWQ9bG9nY291bnQ+PC9zcGFuPjwvZGl2PgogICA8ZGl2IGNs
YXNzPWxvZyBpZD1sb2c+PC9kaXY+CiAgPC9kaXY+CiA8L2Rpdj4KPC9kaXY+CjxzY3JpcHQ+Cmxl
dCBTPXt9Owphc3luYyBmdW5jdGlvbiBhcGkoYyxiKXtjb25zdCByPWF3YWl0IGZldGNoKCcvYXBp
LycrYyx7bWV0aG9kOidQT1NUJyxoZWFkZXJzOnsnQ29udGVudC1UeXBlJzonYXBwbGljYXRpb24v
anNvbid9LGJvZHk6SlNPTi5zdHJpbmdpZnkoYnx8e30pfSk7cmV0dXJuIHIuanNvbigpO30KZnVu
Y3Rpb24gJChpKXtyZXR1cm4gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoaSk7fQpmdW5jdGlvbiBl
c2Mocyl7cmV0dXJuIFN0cmluZyhzPT1udWxsPycnOnMpLnJlcGxhY2UoL1smPD4iJ10vZyxjPT4o
eycmJzonJmFtcDsnLCc8JzonJmx0OycsJz4nOicmZ3Q7JywnIic6JyZxdW90OycsIiciOicmIzM5
Oyd9W2NdKSk7fQpmdW5jdGlvbiBjbWQoYyl7aWYoYy5zdGFydHNXaXRoKCdzdGFydCcpKSQoJ21z
ZycpLnRleHRDb250ZW50PSdzdGFydGV04oCmJzthcGkoYykudGhlbihyPT57aWYoYz09PSdsaW1l
X3NjYW4nKWxpbWVLZXk9Jyc7cmVuZGVyKHIpO30pO30KZnVuY3Rpb24gdGFiKG4pe2RvY3VtZW50
LnF1ZXJ5U2VsZWN0b3JBbGwoJy50YWInKS5mb3JFYWNoKHQ9PnQuY2xhc3NMaXN0LnRvZ2dsZSgn
c2VsJyx0LmRhdGFzZXQudD09PW4pKTtkb2N1bWVudC5xdWVyeVNlbGVjdG9yQWxsKCcucGFuZWwn
KS5mb3JFYWNoKHA9PnAuY2xhc3NMaXN0LnRvZ2dsZSgnc2VsJyxwLmlkPT09J3AtJytuKSk7dHJ5
e2xvY2FsU3RvcmFnZS5zZXRJdGVtKCdwa29tX3RhYicsbik7fWNhdGNoKGUpe319CmZ1bmN0aW9u
IHNhdmUoa2V5cyl7bGV0IGI9e307a2V5cy5mb3JFYWNoKGs9PntsZXQgZWw9JChrKTtiW2tdPWVs
LnR5cGU9PT0nY2hlY2tib3gnPyhlbC5jaGVja2VkPycxJzonMCcpOmVsLnZhbHVlO30pO2FwaSgn
c2V0JyxiKS50aGVuKHI9PntmaWxsZWQ9ZmFsc2U7cmVuZGVyKHIpO30pO30KZnVuY3Rpb24gc2lt
YWRkKCl7YXBpKCdzaW1fYWRkJyx7aW1zaTokKCdzaW1faW1zaScpLnZhbHVlLGtpOiQoJ3NpbV9r
aScpLnZhbHVlLG9wYzokKCdzaW1fb3BjJykudmFsdWUsbXNpc2RuOiQoJ3NpbV9ucicpLnZhbHVl
fSkudGhlbihyPT57aWYoIS9hYmVyfHBydWVmZW4vLnRlc3Qoci5tc2d8fCcnKSl7WydzaW1faW1z
aScsJ3NpbV9raScsJ3NpbV9vcGMnLCdzaW1fbnInXS5mb3JFYWNoKGk9PiQoaSkudmFsdWU9Jycp
O31yZW5kZXIocik7fSk7fQpmdW5jdGlvbiBzaW1ucigpe2FwaSgnZ3NtX3NpbV9ucicse2ltc2k6
JCgnZ251bV9pbXNpJykudmFsdWUsbXNpc2RuOiQoJ2dudW1fbnInKS52YWx1ZX0pLnRoZW4ocmVu
ZGVyKTt9CmZ1bmN0aW9uIHNtc3Rlc3QoKXthcGkoJ3Ntc190ZXN0Jyx7aW1zaTokKCdzbXNfdGVz
dF9pbXNpJykudmFsdWUsdGV4dDokKCdzbXNfdGVzdF90ZXh0JykudmFsdWV9KS50aGVuKHJlbmRl
cik7fQpmdW5jdGlvbiBzaW1kZWwoaSl7aWYoY29uZmlybSgnU0lNICcraSsnIGF1cyBHU00gdW5k
IExURSBsw7ZzY2hlbj8nKSlhcGkoJ3NpbV9kZWwnLHtpbXNpOml9KS50aGVuKHJlbmRlcik7fQpm
dW5jdGlvbiBudW1kZWwoaSl7YXBpKCdnc21fbnVtX2RlbCcse2ltc2k6aX0pLnRoZW4ocmVuZGVy
KTt9CmZ1bmN0aW9uIGdzbUluZm8oYSl7YT0rYXx8MDtsZXQgbT0wLGI9Jyc7aWYoYT49MSYmYTw9
MTI0KXttPTkzNSswLjIqYTtiPSdHU005MDAnO31lbHNlIGlmKGE+PTUxMiYmYTw9ODg1KXttPTE4
MDUuMiswLjIqKGEtNTEyKTtiPSdEQ1MxODAwJzt9cmV0dXJue21oejptP20udG9GaXhlZCgxKSsn
IE1Ieic6J+KAkycsYmFuZDpifTt9CmZ1bmN0aW9uIGx0ZUluZm8oZSl7ZT0rZXx8MDtsZXQgbT0w
LGI9MDtpZihlPj0wJiZlPD01OTkpe209MjExMCswLjEqZTtiPTE7fWVsc2UgaWYoZT49MTIwMCYm
ZTw9MTk0OSl7bT0xODA1KzAuMSooZS0xMjAwKTtiPTM7fWVsc2UgaWYoZT49Mjc1MCYmZTw9MzQ0
OSl7bT0yNjIwKzAuMSooZS0yNzUwKTtiPTc7fWVsc2UgaWYoZT49NjE1MCYmZTw9NjQ0OSl7bT03
OTErMC4xKihlLTYxNTApO2I9MjA7fXJldHVybnttaHo6bT9tLnRvRml4ZWQoMSkrJyBNSHonOifi
gJMnLGJhbmQ6Yj8nQmFuZCAnK2I6Jyd9O30KZnVuY3Rpb24gdXBkYXRlRnJlcSgpe2xldCBnPWdz
bUluZm8oJCgnR1NNX0FSRkNOJykudmFsdWUpOyQoJ2dzbV9taHonKS50ZXh0Q29udGVudD1nLm1o
ejskKCdnc21fYmFuZCcpLnRleHRDb250ZW50PWcuYmFuZDtsZXQgbD1sdGVJbmZvKCQoJ0xURV9F
QVJGQ04nKS52YWx1ZSk7JCgnbHRlX21oeicpLnRleHRDb250ZW50PWwubWh6OyQoJ2x0ZV9iYW5k
JykudGV4dENvbnRlbnQ9bC5iYW5kO30KZnVuY3Rpb24gc2V0dihpZCx2KXtsZXQgZWw9JChpZCk7
aWYoIWVsKXJldHVybjtpZihlbC50eXBlPT09J2NoZWNrYm94JyllbC5jaGVja2VkPSh2PT09JzEn
fHx2PT09dHJ1ZSk7ZWxzZSBlbC52YWx1ZT0odj09bnVsbD8nJzp2KTt9CmNvbnN0IEZJRUxEUz1b
J01DQycsJ01OQycsJ05FVE5BTUUnLCdORVROQU1FX1NIT1JUJywnU1BOJywnTklUWicsJ0dTTV9E
RVYnLCdMVEVfREVWJywnR1NNX0FSRkNOJywnR1NNX1RYX0dBSU4nLCdHU01fUlhfR0FJTicsJ0dT
TV9TSVBfUEVFUicsJ0dTTV9TSVBfTE9DQUwnLCdHU01fT1BFTicsJ0dTTV9EQVRBJywnR1NNX1NJ
UCcsJ0dTTV9TTVMnLCdHU01fU01TX0ZST00nLCdHU01fU01TX0VYVFBSRUZJWCcsJ0dTTV9TTVNf
V0VMQ09NRScsJ0dTTV9TTVNfTlVNQkVSJywnTFRFX0VBUkZDTicsJ0xURV9OUFJCJywnTFRFX1RY
X0dBSU4nLCdMVEVfUlhfR0FJTicsJ0xURV9BUE4nXTsKbGV0IGZpbGxlZD1mYWxzZSxsaW1lS2V5
PScnOwpmdW5jdGlvbiBsaW1lT3B0aW9ucyhzKXsKIGNvbnN0IEw9cy5saW1lc3x8W10sYz1zLmNv
bmZ8fHt9LGtleT1KU09OLnN0cmluZ2lmeShMKSsoYy5HU01fREVWfHwnJykrKGMuTFRFX0RFVnx8
JycpOwogaWYoa2V5PT09bGltZUtleSlyZXR1cm47bGltZUtleT1rZXk7CiBbJ0dTTV9ERVYnLCdM
VEVfREVWJ10uZm9yRWFjaChpZD0+e2NvbnN0IGVsPSQoaWQpLGN1cj1jW2lkXXx8Jyc7CiAgbGV0
IG89JzxvcHRpb24gdmFsdWU9IiI+YXV0b21hdGlzY2g8L29wdGlvbj4nK0wubWFwKGQ9Pic8b3B0
aW9uIHZhbHVlPSInK2VzYyhkLnNlcmlhbCkrJyI+Jytlc2MoZC5uYW1lKSsnIMK3ICcrZXNjKGQu
c2VyaWFsKSsoZC5tZWRpYT8nIMK3ICcrZXNjKGQubWVkaWEpOicnKSsnPC9vcHRpb24+Jykuam9p
bignJyk7CiAgaWYoY3VyJiYhTC5zb21lKGQ9PmQuc2VyaWFsPT09Y3VyKSlvKz0nPG9wdGlvbiB2
YWx1ZT0iJytlc2MoY3VyKSsnIj4nK2VzYyhjdXIpKycgKG5pY2h0IGdlZnVuZGVuKTwvb3B0aW9u
Pic7CiAgZWwuaW5uZXJIVE1MPW87ZWwudmFsdWU9Y3VyO30pOwogJCgnbGltZWxpc3QnKS50ZXh0
Q29udGVudD1MLmxlbmd0aD9MLmxlbmd0aCsnIExpbWVTRFIgYW5nZXNjaGxvc3Nlbic6J0tlaW4g
TGltZVNEUiBnZWZ1bmRlbiDigJMgVVNCIHByw7xmZW4gdW5kIOKAnk5ldSBzdWNoZW7igJwuJzsK
fQpmdW5jdGlvbiByZWxvYWRGaWVsZHMoKXtjb25zdCBjPVMuY29uZnx8e307RklFTERTLmZvckVh
Y2goaz0+e2lmKGRvY3VtZW50LmFjdGl2ZUVsZW1lbnQhPT0kKGspKXNldHYoayxjW2tdKTt9KTtm
aWxsZWQ9dHJ1ZTt1cGRhdGVGcmVxKCk7fQpmdW5jdGlvbiBmbXQocyl7Y29uc3QgbT1NYXRoLmZs
b29yKHMvNjApLGg9TWF0aC5mbG9vcihtLzYwKTtyZXR1cm4gaD9oKydoICcrKG0lNjApKydtJzoo
bT9tKydtICcrKHMlNjApKydzJzpzKydzJyk7fQpmdW5jdGlvbiByZW5kZXJsb2coKXtjb25zdCBm
PSgkKCdsb2dmaWx0ZXInKS52YWx1ZXx8JycpLnRvTG93ZXJDYXNlKCk7bGV0IEw9KFMubG9nfHxb
XSk7aWYoZilMPUwuZmlsdGVyKHg9PngudG9Mb3dlckNhc2UoKS5pbmNsdWRlcyhmKSk7Y29uc3Qg
bGc9JCgnbG9nJyk7Y29uc3QgbmVhcj1sZy5zY3JvbGxUb3ArbGcuY2xpZW50SGVpZ2h0Pj1sZy5z
Y3JvbGxIZWlnaHQtNDA7bGcudGV4dENvbnRlbnQ9TC5qb2luKCdcbicpOyQoJ2xvZ2NvdW50Jyku
dGV4dENvbnRlbnQ9TC5sZW5ndGgrJyBaZWlsZW4nO2lmKG5lYXIpbGcuc2Nyb2xsVG9wPWxnLnNj
cm9sbEhlaWdodDt9CmZ1bmN0aW9uIHJlbmRlcihzKXtTPXM7bGltZU9wdGlvbnMocyk7aWYoIWZp
bGxlZClyZWxvYWRGaWVsZHMoKTsKIGNvbnN0IHJ1bj1zLnN0YXRlPT09J2xhZXVmdCcsdD1zLnRl
Y2g7CiAkKCdkb3QnKS5jbGFzc05hbWU9J2RvdCAnKyhydW4/J29uJzoocy5zdGF0ZT09PSdmZWhs
ZXInPydlcnInOicnKSk7CiAkKCdzdGF0ZScpLnRleHRDb250ZW50PXMuc3RhdGU7JCgnbXNnJyku
dGV4dENvbnRlbnQ9cy5tc2d8fCcnOwogY29uc3QgdGI9JCgndGVjaGJhZGdlJyk7aWYodCl7dGIu
c3R5bGUuZGlzcGxheT0nJzt0Yi50ZXh0Q29udGVudD10PT09J2NzZmInPydMVEUrR1NNJzp0LnRv
VXBwZXJDYXNlKCk7fWVsc2UgdGIuc3R5bGUuZGlzcGxheT0nbm9uZSc7CiBsZXQgZnJlcT0n4oCT
Jyxmc3ViPScnOwogY29uc3QgZ2Y9cy5nc20ubWh6KycgTUh6JyxsZj1zLmx0ZS5taHorJyBNSHon
OwogaWYodD09PSdsdGUnKXtmcmVxPWxmO2ZzdWI9J0JhbmQgJytzLmx0ZS5iYW5kKycgwrcgRUFS
RkNOICcrcy5sdGUuZWFyZmNuO30KIGVsc2UgaWYodD09PSdnc20nKXtmcmVxPWdmO2ZzdWI9cy5n
c20uYmFuZCsnIMK3IEFSRkNOICcrcy5nc20uYXJmY247fQogZWxzZSBpZih0PT09J2NzZmInKXtm
cmVxPWxmKycgLyAnK2dmO2ZzdWI9J0xURSBCJytzLmx0ZS5iYW5kKycgwrcgR1NNIEFSRkNOICcr
cy5nc20uYXJmY247fQogJCgnZnJlcScpLnRleHRDb250ZW50PWZyZXE7JCgnZnJlcTInKS50ZXh0
Q29udGVudD1mcmVxOyQoJ2ZyZXFzdWInKS50ZXh0Q29udGVudD1mc3ViOwogJCgndGVjaDInKS50
ZXh0Q29udGVudD10Pyh0PT09J2NzZmInPydMVEUrR1NNJzp0LnRvVXBwZXJDYXNlKCkpOidhdXMn
OyQoJ3N0YXRlc3ViJykudGV4dENvbnRlbnQ9cy5zdGF0ZTsKICQoJ3VwdGltZScpLnRleHRDb250
ZW50PXMudXB0aW1lP2ZtdChzLnVwdGltZSk6J+KAkyc7JCgndXB0aW1laGludCcpLnRleHRDb250
ZW50PXJ1bj8oJ2zDpHVmdCBzZWl0ICcrZm10KHMudXB0aW1lKSk6Jyc7CiAkKCdkZXZoaW50Jyku
aW5uZXJIVE1MPVtzLmRldi5nc20/J0dTTS1GdW5rOiA8Yj4nK2VzYyhzLmRldi5nc20pKyc8L2I+
JzonJyxzLmRldi5sdGU/J0xURS1GdW5rOiA8Yj4nK2VzYyhzLmRldi5sdGUpKyc8L2I+JzonJ10u
ZmlsdGVyKEJvb2xlYW4pLmpvaW4oJzxicj4nKTsKICQoJ2NsYXNoJykudGV4dENvbnRlbnQ9cy5j
bGFzaHx8Jyc7CiBbWydnc20nLCdPc21vY29tJ10sWydsdGUnLCdzcnNSQU4gKyBPcGVuNUdTJ10s
Wydjc2ZiJywnSW50ZXJuZXQgKyBBbnJ1ZmUgKENTRkIpJ11dLmZvckVhY2goKFtrLGRdKT0+eyQo
J2J0bl8nK2spLmNsYXNzTGlzdC50b2dnbGUoJ2FjdGl2ZScsdD09PWspOyQoaysnX3N1YicpLnRl
eHRDb250ZW50PXQ9PT1rPydsw6R1ZnQnOmQ7fSk7CiAkKCd0eicpLnRleHRDb250ZW50PXMudHp8
fCfigJMnOwogY29uc3QgZj1zLnNpbWZpbGVzfHx7fTskKCdocGxtbicpLnRleHRDb250ZW50PWYu
aHBsbW58fCfigJMnOwogJCgnZWZfc3BuJykudGV4dENvbnRlbnQ9Zi5zcG58fCcnOyQoJ2VmX3Nw
bl90JykudGV4dENvbnRlbnQ9J+KAnicrKGYuc3BuX3RleHR8fCcnKSsn4oCcJzsKICQoJ2VmX3Bu
bicpLnRleHRDb250ZW50PWYucG5ufHwnJzskKCdlZl9wbm5fdCcpLnRleHRDb250ZW50PSdsYW5n
IOKAnicrKGYuZnVsbHx8JycpKyfigJwsIGt1cnog4oCeJysoZi5zaG9ydHx8JycpKyfigJwnOwog
JCgnZWZfb3BsJykudGV4dENvbnRlbnQ9Zi5vcGx8fCcnOyQoJ2VmX29wbF90JykudGV4dENvbnRl
bnQ9J0tlbm51bmcgJysoZi5ocGxtbnx8JycpKycsIGFsbGUgR2ViaWV0ZSDihpIgUE5OIDEnOwog
JCgnZWZfaHBsbW4nKS50ZXh0Q29udGVudD1mLmhwbG1ufHwnJzsKICQoJ2dzbV9udW1iZXJzJyku
aW5uZXJIVE1MPU9iamVjdC5lbnRyaWVzKHMuZ3NtLm51bWJlcnN8fHt9KS5tYXAoZT0+JzxkaXYg
Y2xhc3M9bGlzdHJvdz48c3BhbiBjbGFzcz10YWc+Jytlc2MoZVswXSkrJyDihpIgPGI+Jytlc2Mo
ZVsxXSkrJzwvYj48L3NwYW4+PGJ1dHRvbiBjbGFzcz14IG9uY2xpY2s9Im51bWRlbChcJycrZXNj
KGVbMF0pKydcJykiPmzDtnNjaGVuPC9idXR0b24+PC9kaXY+Jykuam9pbignJyl8fCc8ZGl2IGNs
YXNzPWVtcHR5PmtlaW5lIFp1d2Vpc3VuZ2VuPC9kaXY+JzsKICQoJ2F0dGFjaGVkJykuaW5uZXJI
VE1MPShzLmdzbS5hdHRhY2hlZHx8W10pLm1hcChpPT4nPGRpdiBjbGFzcz1saXN0cm93PjxzcGFu
IGNsYXNzPXRhZz4nK2VzYyhpKSsnPC9zcGFuPjxzcGFuIGNsYXNzPXRhZz4nK2VzYygocy5nc20u
bnVtYmVyc3x8e30pW2ldfHwnJykrJzwvc3Bhbj48L2Rpdj4nKS5qb2luKCcnKXx8JzxkaXYgY2xh
c3M9ZW1wdHk+a2VpbmUgZWluZ2VidWNodDwvZGl2Pic7CiAkKCdzaW1zJykuaW5uZXJIVE1MPShz
LnNpbXN8fFtdKS5tYXAoeD0+JzxkaXYgY2xhc3M9bGlzdHJvdz48c3BhbiBjbGFzcz10YWc+Jytl
c2MoeC5pbXNpKSsnIMK3IDxiPicrZXNjKHgubXNpc2RuKSsnPC9iPjwvc3Bhbj48YnV0dG9uIGNs
YXNzPXggb25jbGljaz0ic2ltZGVsKFwnJytlc2MoeC5pbXNpKSsnXCcpIj5sw7ZzY2hlbjwvYnV0
dG9uPjwvZGl2PicpLmpvaW4oJycpfHwnPGRpdiBjbGFzcz1lbXB0eT5ub2NoIGtlaW5lIFNJTSBl
aW5nZXRyYWdlbjwvZGl2Pic7CiByZW5kZXJsb2coKTsKfQphc3luYyBmdW5jdGlvbiBwb2xsKCl7
dHJ5e3JlbmRlcihhd2FpdCBhcGkoJ3N0YXR1cycpKTt9Y2F0Y2goZSl7fX0KdHJ5e2NvbnN0IHQ9
bG9jYWxTdG9yYWdlLmdldEl0ZW0oJ3Brb21fdGFiJyk7aWYodCYmJCgncC0nK3QpKXRhYih0KTt9
Y2F0Y2goZSl7fQpwb2xsKCk7c2V0SW50ZXJ2YWwocG9sbCwyNTAwKTsKPC9zY3JpcHQ+PC9ib2R5
PjwvaHRtbD4iIiIKCmNsYXNzIEhhbmRsZXIoQmFzZUhUVFBSZXF1ZXN0SGFuZGxlcik6CiAgICBk
ZWYgbG9nX21lc3NhZ2Uoc2VsZiwgKmEpOiBwYXNzCiAgICBkZWYgX3NlbmQoc2VsZiwgY29kZSwg
Ym9keSwgY3R5cGU9ImFwcGxpY2F0aW9uL2pzb24iKToKICAgICAgICBiID0gYm9keS5lbmNvZGUo
KSBpZiBpc2luc3RhbmNlKGJvZHksIHN0cikgZWxzZSBib2R5CiAgICAgICAgc2VsZi5zZW5kX3Jl
c3BvbnNlKGNvZGUpCiAgICAgICAgc2VsZi5zZW5kX2hlYWRlcigiQ29udGVudC1UeXBlIiwgY3R5
cGUpCiAgICAgICAgc2VsZi5zZW5kX2hlYWRlcigiQ29udGVudC1MZW5ndGgiLCBzdHIobGVuKGIp
KSkKICAgICAgICBzZWxmLmVuZF9oZWFkZXJzKCkKICAgICAgICB0cnk6IHNlbGYud2ZpbGUud3Jp
dGUoYikKICAgICAgICBleGNlcHQgRXhjZXB0aW9uOiBwYXNzCiAgICBkZWYgZG9fR0VUKHNlbGYp
OgogICAgICAgIGlmIHNlbGYucGF0aCBpbiAoIi8iLCAiL2luZGV4Lmh0bWwiKToKICAgICAgICAg
ICAgc2VsZi5fc2VuZCgyMDAsIFBBR0UsICJ0ZXh0L2h0bWw7IGNoYXJzZXQ9dXRmLTgiKQogICAg
ICAgIGVsaWYgc2VsZi5wYXRoID09ICIvYXBpL3N0YXR1cyI6CiAgICAgICAgICAgIHNlbGYuX3Nl
bmQoMjAwLCBqc29uLmR1bXBzKE5FVC5zdGF0dXMoKSkpCiAgICAgICAgZWxzZToKICAgICAgICAg
ICAgc2VsZi5fc2VuZCg0MDQsICJ7fSIpCiAgICBkZWYgZG9fUE9TVChzZWxmKToKICAgICAgICBu
ID0gaW50KHNlbGYuaGVhZGVycy5nZXQoIkNvbnRlbnQtTGVuZ3RoIiwgMCkgb3IgMCkKICAgICAg
ICBib2R5ID0gc2VsZi5yZmlsZS5yZWFkKG4pLmRlY29kZShlcnJvcnM9InJlcGxhY2UiKSBpZiBu
IGVsc2UgIiIKICAgICAgICBpZiBzZWxmLnBhdGguc3RhcnRzd2l0aCgiL2FwaS8iKToKICAgICAg
ICAgICAgdHJ5OgogICAgICAgICAgICAgICAgc2VsZi5fc2VuZCgyMDAsIGpzb24uZHVtcHMoaGFu
ZGxlX2FwaShzZWxmLnBhdGgsIGJvZHkpKSkKICAgICAgICAgICAgZXhjZXB0IEV4Y2VwdGlvbiBh
cyBlOgogICAgICAgICAgICAgICAgbG9nKCJhcGk6IiwgZSk7IHNlbGYuX3NlbmQoNTAwLCBqc29u
LmR1bXBzKHsiZXJyb3IiOiBzdHIoZSl9KSkKICAgICAgICBlbHNlOgogICAgICAgICAgICBzZWxm
Ll9zZW5kKDQwNCwgInt9IikKCmRlZiBtYWluKCk6CiAgICBwb3J0ID0gaW50KEMuZ2V0KCJXRUJf
UE9SVCIsICI4MDgwIikpCiAgICBsb2coZiJnOTBuZXQgV2ViLU9iZXJmbGFlY2hlIGF1ZiBodHRw
Oi8vMC4wLjAuMDp7cG9ydH0gIChGQUtFPXtGQUtFfSkiKQogICAgdGhyZWFkaW5nLlRocmVhZCh0
YXJnZXQ9c21zX3dlbGNvbWVfd2F0Y2gsIGRhZW1vbj1UcnVlKS5zdGFydCgpCiAgICB0aHJlYWRp
bmcuVGhyZWFkKHRhcmdldD1saW1lX3NjYW4sIGRhZW1vbj1UcnVlKS5zdGFydCgpICAgIyBMaW1l
U0RSIGZ1ZXIgZGllIEF1c3dhaGwgc3VjaGVuCiAgICB0cnk6IF9taWdyYXRlX2x0ZV9kYigpCiAg
ICBleGNlcHQgRXhjZXB0aW9uIGFzIGU6IGxvZygibWlncmF0aW9uOiIsIGUpCiAgICBUaHJlYWRp
bmdIVFRQU2VydmVyKCgiMC4wLjAuMCIsIHBvcnQpLCBIYW5kbGVyKS5zZXJ2ZV9mb3JldmVyKCkK
CmlmIF9fbmFtZV9fID09ICJfX21haW5fXyI6CiAgICBtYWluKCkK
