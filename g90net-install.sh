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
PT09PT09PQppbXBvcnQgb3MsIHJlLCBzeXMsIGpzb24sIHRpbWUsIHNodXRpbCwgc29ja2V0LCBz
ZWNyZXRzLCB0aHJlYWRpbmcsIHN1YnByb2Nlc3MKZnJvbSBodHRwLnNlcnZlciBpbXBvcnQgQmFz
ZUhUVFBSZXF1ZXN0SGFuZGxlciwgVGhyZWFkaW5nSFRUUFNlcnZlcgoKIyAtLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0gS29u
ZmlnCkNPTkYgPSBvcy5lbnZpcm9uLmdldCgiRzkwTkVUX0NPTkYiLCAiL2V0Yy9nOTBuZXQuY29u
ZiIpCldPUktESVIgPSBvcy5lbnZpcm9uLmdldCgiRzkwTkVUX1dPUktESVIiLCAiL3Zhci9saWIv
ZzkwbmV0IikKT1NNT19DRkcgPSAiL2V0Yy9vc21vY29tIgpTUlNfQ0ZHID0gIi9ldGMvc3JzcmFu
IgoKREVGQVVMVFMgPSB7CiAgICAiV0VCX1BPUlQiOiAiODA4MCIsCiAgICAjIGdlbWVpbnNhbQog
ICAgIlRFQ0giOiAiZ3NtIiwgICAgICAgICAgICAjIHp1bGV0enQgZ2VzdGFydGV0CiAgICAiTUND
IjogIjAwMSIsICJNTkMiOiAiMDEiLCAiTkVUTkFNRSI6ICJwS09NIiwgIk5FVE5BTUVfU0hPUlQi
OiAicEtPTSIsICJTUE4iOiAicEtPTSIsCiAgICAiTklUWiI6ICIxIiwgICAgICAgICAgICAgICMg
TmV0em5hbWUgKyBVaHJ6ZWl0L1plaXR6b25lIGFucyBIYW5keSBzZW5kZW4gKEdTTTogTU0tSW5m
bywgTFRFOiBFTU0tSW5mbykKICAgICMgTGltZVNEUiBqZSBOZXR6IChTZXJpZW5udW1tZXIsIGxl
ZXIgPSBhdXRvbWF0aXNjaCkKICAgICJHU01fREVWIjogIiIsICJMVEVfREVWIjogIiIsCiAgICAj
IDJHCiAgICAiR1NNX0FSRkNOIjogIjIwIiwgIkdTTV9UWF9HQUlOIjogIjUwIiwgIkdTTV9SWF9H
QUlOIjogIjQ1IiwKICAgICJHU01fT1BFTiI6ICIxIiwgIkdTTV9EQVRBIjogIjAiLCAiR1NNX1NJ
UCI6ICIwIiwgIkdTTV9TSVBfUEVFUiI6ICIiLCAiR1NNX1NJUF9MT0NBTCI6ICIiLAogICAgIyBT
TVMgKEJlZ3J1ZXNzdW5nIGJlaW0gRWluYnVjaGVuICsgQmVzdGFldGlndW5nIGJlaSBOdW1tZXJu
dmVyZ2FiZSkKICAgICJHU01fU01TIjogIjEiLCAiR1NNX1NNU19GUk9NIjogIjEwMDAiLAogICAg
IyB7ZXh0ZXJufSA9IFZvcndhaGwtQmxvY2sgKyBpbnRlcm5lIE51bW1lciAobGVlciA9IG51ciBk
aWUgaW50ZXJuZSBOdW1tZXIpCiAgICAiR1NNX1NNU19FWFRQUkVGSVgiOiAiKzQ5IDY1MSA2MzU1
NTUiLAogICAgIkdTTV9TTVNfV0VMQ09NRSI6ICJXaWxsa29tbWVuIGltIHtuZXR6fSEgRHUgYmlz
dCBqZXR6dCBlaW5nZWJ1Y2h0LiA3MyIsCiAgICAiR1NNX1NNU19OVU1CRVIiOiAiRGVpbmUgUnVm
bnVtbWVyIGltIHtuZXR6fS1OZXR6IGlzdCBqZXR6dCB7bnVtbWVyfS4gRXh0ZXJuIGVycmVpY2hi
YXI6IHtleHRlcm59IiwKICAgICMgNEcKICAgICJMVEVfRUFSRkNOIjogIjE1NzUiLCAiTFRFX05Q
UkIiOiAiMjUiLCAiTFRFX1RYX0dBSU4iOiAiODAiLCAiTFRFX1JYX0dBSU4iOiAiNDAiLAogICAg
IkxURV9BUE4iOiAiaW50ZXJuZXQiLCAiTFRFX1RBQyI6ICI3IiwKfQoKZGVmIGxvYWRfY29uZigp
OgogICAgYyA9IGRpY3QoREVGQVVMVFMpCiAgICB0cnk6CiAgICAgICAgZm9yIGxpbmUgaW4gb3Bl
bihDT05GKToKICAgICAgICAgICAgbGluZSA9IGxpbmUuc3RyaXAoKQogICAgICAgICAgICBpZiBu
b3QgbGluZSBvciBsaW5lLnN0YXJ0c3dpdGgoIiMiKSBvciAiPSIgbm90IGluIGxpbmU6CiAgICAg
ICAgICAgICAgICBjb250aW51ZQogICAgICAgICAgICBrLCB2ID0gbGluZS5zcGxpdCgiPSIsIDEp
CiAgICAgICAgICAgIGNbay5zdHJpcCgpXSA9IHYuc3RyaXAoKS5zdHJpcCgnIicpCiAgICBleGNl
cHQgRXhjZXB0aW9uOgogICAgICAgIHBhc3MKICAgIHJldHVybiBjCgpkZWYgc2F2ZV9jb25mKGMp
OgogICAgdHJ5OgogICAgICAgIG9zLm1ha2VkaXJzKG9zLnBhdGguZGlybmFtZShDT05GKSwgZXhp
c3Rfb2s9VHJ1ZSkKICAgICAgICB3aXRoIG9wZW4oQ09ORiwgInciKSBhcyBmOgogICAgICAgICAg
ICBmLndyaXRlKCIjIGc5MG5ldCAtIGF1dG9tYXRpc2NoIGdlc2NocmllYmVuXG4iKQogICAgICAg
ICAgICBmb3IgayBpbiBzb3J0ZWQoYyk6CiAgICAgICAgICAgICAgICBmLndyaXRlKCclcz0iJXMi
XG4nICUgKGssIGNba10pKQogICAgZXhjZXB0IEV4Y2VwdGlvbiBhcyBlOgogICAgICAgIGxvZygi
Y29uZiBzcGVpY2hlcm46IiwgZSkKCkMgPSBsb2FkX2NvbmYoKQpvcy5tYWtlZGlycyhXT1JLRElS
LCBleGlzdF9vaz1UcnVlKQoKZGVmIGNzZXQoaywgdik6CiAgICBDW2tdID0gc3RyKHYpCiAgICBz
YXZlX2NvbmYoQykKCmRlZiBsb2coKmEpOgogICAgcHJpbnQodGltZS5zdHJmdGltZSgiJUg6JU06
JVMiKSwgKmEsIGZsdXNoPVRydWUpCgpGQUtFID0gIi0tZmFrZSIgaW4gc3lzLmFyZ3YgICAjIFRl
c3Rtb2R1cyBvaG5lIGVjaHRlIEhhcmR3YXJlL1Byb3plc3NlCgojIC0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLSBGcmVxdWVu
emVuIChBbnplaWdlKQpkZWYgYXJmY25fYmFuZChhKToKICAgIGEgPSBpbnQoYSkKICAgIGlmIDEg
PD0gYSA8PSAxMjQ6ICAgcmV0dXJuICJHU005MDAiCiAgICBpZiA1MTIgPD0gYSA8PSA4ODU6IHJl
dHVybiAiRENTMTgwMCIKICAgIGlmIDEyOCA8PSBhIDw9IDI1MTogcmV0dXJuICJHU004NTAiCiAg
ICBpZiA5NzUgPD0gYSA8PSAxMDIzOnJldHVybiAiRUdTTTkwMCIKICAgIHJldHVybiAiR1NNOTAw
IgoKZGVmIGFyZmNuX21oeihhKToKICAgIGEgPSBpbnQoYSkKICAgIGlmIDEgPD0gYSA8PSAxMjQ6
ICAgIHJldHVybiByb3VuZCg5MzUgKyAwLjIgKiBhLCAxKQogICAgaWYgNTEyIDw9IGEgPD0gODg1
OiAgcmV0dXJuIHJvdW5kKDE4MDUuMiArIDAuMiAqIChhIC0gNTEyKSwgMSkKICAgIGlmIDEyOCA8
PSBhIDw9IDI1MTogIHJldHVybiByb3VuZCg4NjkgKyAwLjIgKiAoYSAtIDEyOCksIDEpCiAgICBy
ZXR1cm4gMC4wCgpkZWYgZWFyZmNuX21oeihlKToKICAgIGUgPSBpbnQoZSkKICAgICMgQmFuZCAz
ICgxODAwKTogREwgMTgwNS0xODgwLCBFQVJGQ04gMTIwMC0xOTQ5CiAgICBpZiAxMjAwIDw9IGUg
PD0gMTk0OTogcmV0dXJuIHJvdW5kKDE4MDUuMCArIDAuMSAqIChlIC0gMTIwMCksIDEpCiAgICAj
IEJhbmQgMSAoMjEwMCk6IEVBUkZDTiAwLTU5OQogICAgaWYgMCA8PSBlIDw9IDU5OTogICAgIHJl
dHVybiByb3VuZCgyMTEwLjAgKyAwLjEgKiBlLCAxKQogICAgIyBCYW5kIDcgKDI2MDApOiAyNzUw
LTM0NDkKICAgIGlmIDI3NTAgPD0gZSA8PSAzNDQ5OiByZXR1cm4gcm91bmQoMjYyMC4wICsgMC4x
ICogKGUgLSAyNzUwKSwgMSkKICAgICMgQmFuZCAyMCAoODAwKTogNjE1MC02NDQ5CiAgICBpZiA2
MTUwIDw9IGUgPD0gNjQ0OTogcmV0dXJuIHJvdW5kKDc5MS4wICsgMC4xICogKGUgLSA2MTUwKSwg
MSkKICAgIHJldHVybiAwLjAKCmRlZiBlYXJmY25fYmFuZChlKToKICAgIGUgPSBpbnQoZSkKICAg
IGlmIDAgPD0gZSA8PSA1OTk6ICAgICByZXR1cm4gMQogICAgaWYgMTIwMCA8PSBlIDw9IDE5NDk6
IHJldHVybiAzCiAgICBpZiAyNzUwIDw9IGUgPD0gMzQ0OTogcmV0dXJuIDcKICAgIGlmIDYxNTAg
PD0gZSA8PSA2NDQ5OiByZXR1cm4gMjAKICAgIHJldHVybiAzCgojIC0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLSBWVFktSGls
ZmVuIChPc21vY29tKQpkZWYgdnR5KHBvcnQsIGNtZHMsIHRpbWVvdXQ9NCk6CiAgICBvdXQgPSBb
XQogICAgdHJ5OgogICAgICAgIHMgPSBzb2NrZXQuY3JlYXRlX2Nvbm5lY3Rpb24oKCIxMjcuMC4w
LjEiLCBwb3J0KSwgdGltZW91dD10aW1lb3V0KQogICAgICAgIHMuc2V0dGltZW91dCh0aW1lb3V0
KQogICAgICAgIHRpbWUuc2xlZXAoMC4yKQogICAgICAgIHRyeTogb3V0LmFwcGVuZChzLnJlY3Yo
NDA5NikuZGVjb2RlKGVycm9ycz0icmVwbGFjZSIpKQogICAgICAgIGV4Y2VwdCBFeGNlcHRpb246
IHBhc3MKICAgICAgICBmb3IgY21kIGluIGNtZHM6CiAgICAgICAgICAgIHMuc2VuZGFsbCgoY21k
ICsgIlxyXG4iKS5lbmNvZGUoKSk7IHRpbWUuc2xlZXAoMC4zKQogICAgICAgICAgICB0cnk6IG91
dC5hcHBlbmQocy5yZWN2KDgxOTIpLmRlY29kZShlcnJvcnM9InJlcGxhY2UiKSkKICAgICAgICAg
ICAgZXhjZXB0IEV4Y2VwdGlvbjogcGFzcwogICAgICAgIHMuY2xvc2UoKQogICAgZXhjZXB0IEV4
Y2VwdGlvbiBhcyBlOgogICAgICAgIHJldHVybiAiVlRZLUZlaGxlcjogJXMiICUgZQogICAgcmV0
dXJuICIiLmpvaW4ob3V0KQoKSExSX1ZUWSA9IDQyNTgKTVNDX1ZUWSA9IDQyNTQgICAjIG9zbW8t
bXNjIFRlbG5ldC1WVFk6IFNNUyBzZW5kZW4gKyBlaW5nZWJ1Y2h0ZSBUZWlsbmVobWVyIGFiZnJh
Z2VuCgpkZWYgX3N1YihwYXRoLCBwYWlycyk6CiAgICBpZiBub3Qgb3MucGF0aC5pc2ZpbGUocGF0
aCk6IHJldHVybgogICAgdCA9IG9wZW4ocGF0aCkucmVhZCgpCiAgICBmb3IgcGF0LCByZXAgaW4g
cGFpcnM6CiAgICAgICAgdCA9IHJlLnN1YihwYXQsIHJlcCwgdCwgZmxhZ3M9cmUuTVVMVElMSU5F
KQogICAgb3BlbihwYXRoLCAidyIpLndyaXRlKHQpCgpkZWYgX3Z0eV9zZXQocGF0aCwgbm9kZSwg
a2V5LCBmdWxsKToKICAgIGlmIG5vdCBvcy5wYXRoLmlzZmlsZShwYXRoKTogcmV0dXJuCiAgICB0
ID0gb3BlbihwYXRoKS5yZWFkKCkKICAgIGlmIHJlLnNlYXJjaChyZiIoP20pXlxzKntrZXl9KFxz
fCQpIiwgdCk6CiAgICAgICAgdCA9IHJlLnN1YihyZiIoP20pXlxzKntrZXl9LiokIiwgIiAiICsg
ZnVsbCwgdCkKICAgIGVsc2U6CiAgICAgICAgdCA9IHJlLnN1YihyZiIoP20pXih7cmUuZXNjYXBl
KG5vZGUpfVxzKikkIiwgciJcMVxuICIgKyBmdWxsLCB0LCBjb3VudD0xKQogICAgb3BlbihwYXRo
LCAidyIpLndyaXRlKHQpCgpkZWYgX3Z0eV9kZWwocGF0aCwga2V5KToKICAgIGlmIG5vdCBvcy5w
YXRoLmlzZmlsZShwYXRoKTogcmV0dXJuCiAgICB0ID0gb3BlbihwYXRoKS5yZWFkKCkKICAgIG9w
ZW4ocGF0aCwgInciKS53cml0ZShyZS5zdWIocmYiKD9tKV5ccyp7a2V5fS4qXG4/IiwgIiIsIHQp
KQoKIyA9PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
PT09PT09PT09PT09PT0gTGltZVNEUiBmcmVpIG1hY2hlbgpkZWYgX2xpbWVfc2VydmljZShhY3Rp
b24pOgogICAgaWYgRkFLRTogcmV0dXJuCiAgICBmb3Igc3ZjIGluICgiZzkwLWxpbWUiLCAiZzkw
bGltZSIpOgogICAgICAgIHRyeToKICAgICAgICAgICAgc3VicHJvY2Vzcy5ydW4oWyJzeXN0ZW1j
dGwiLCBhY3Rpb24sIHN2YyArICIuc2VydmljZSJdLAogICAgICAgICAgICAgICAgICAgICAgICAg
ICBzdGRvdXQ9c3VicHJvY2Vzcy5ERVZOVUxMLCBzdGRlcnI9c3VicHJvY2Vzcy5ERVZOVUxMLCB0
aW1lb3V0PTEwKQogICAgICAgIGV4Y2VwdCBFeGNlcHRpb246IHBhc3MKCmRlZiBfZnJlZV9saW1l
KCk6CiAgICAiIiJBbGxlcyBiZWVuZGVuLCB3YXMgZGVuIExpbWVTRFIgb2ZmZW4gaGFlbHQuIERp
ZSBVU0ItUGxhdGluZSAoRlgzKSBOSUNIVCBoYXJ0CiAgICByZXNldGVuIChmYWVsbHQgc29uc3Qg
dm9tIEJ1cyk7IGJlaSBkZXIgTWluaSAoRlQ2MDEpIGhpbGZ0IGVpbiBVU0ItUmVzZXQuIiIiCiAg
ICBpZiBGQUtFOiByZXR1cm4KICAgIGltcG9ydCBmY250bAogICAgZm9yIHZpZCwgcGlkLCBoYXJk
IGluICgoIjA0MDMiLCAiNjAxZiIsIFRydWUpLCAoIjFkNTAiLCAiNjEwOCIsIEZhbHNlKSk6CiAg
ICAgICAgdHJ5OgogICAgICAgICAgICBvdXQgPSBzdWJwcm9jZXNzLnJ1bihbImxzdXNiIiwgIi1k
IiwgZiJ7dmlkfTp7cGlkfSJdLAogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBjYXB0
dXJlX291dHB1dD1UcnVlLCB0ZXh0PVRydWUsIHRpbWVvdXQ9NSkuc3Rkb3V0CiAgICAgICAgICAg
IG0gPSByZS5zZWFyY2gociJCdXMgKFxkKykgRGV2aWNlIChcZCspIiwgb3V0KQogICAgICAgICAg
ICBpZiBub3QgbTogY29udGludWUKICAgICAgICAgICAgcGF0aCA9IGYiL2Rldi9idXMvdXNiL3tt
Lmdyb3VwKDEpfS97bS5ncm91cCgyKX0iCiAgICAgICAgICAgIHRyeToKICAgICAgICAgICAgICAg
IHN1YnByb2Nlc3MucnVuKFsiZnVzZXIiLCAiLWsiLCBwYXRoXSwgc3Rkb3V0PXN1YnByb2Nlc3Mu
REVWTlVMTCwKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIHN0ZGVycj1zdWJwcm9jZXNz
LkRFVk5VTEwsIHRpbWVvdXQ9NSk7IHRpbWUuc2xlZXAoMS4wKQogICAgICAgICAgICBleGNlcHQg
RXhjZXB0aW9uOiBwYXNzCiAgICAgICAgICAgIGlmIGhhcmQ6CiAgICAgICAgICAgICAgICB3aXRo
IG9wZW4ocGF0aCwgIndiIikgYXMgZjogZmNudGwuaW9jdGwoZiwgMHg1NTE0LCAwKQogICAgICAg
IGV4Y2VwdCBFeGNlcHRpb24gYXMgZToKICAgICAgICAgICAgbG9nKCJsaW1lIGZyZWk6IiwgZSkK
CiMgPT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
PT09PT09PT09PT09IExpbWVTRFItQXVzd2FobAojIEplIE5ldHogZWluIGVpZ2VuZXIgTGltZVNE
UiAoei5CLiBMaW1lU0RSIE1pbmkgZnVlciBHU00sIExpbWVTRFIgVVNCIGZ1ZXIgTFRFKS4KIyBa
dW9yZG51bmcgdWViZXIgZGllIFNlcmllbm51bW1lciAoR1NNX0RFViAvIExURV9ERVYpLCBsZWVy
ID0gYXV0b21hdGlzY2guCkxJTUVTID0gW10gICAgICAgICAgIyB6dWxldHp0IGdlZnVuZGVuZSBH
ZXJhZXRlIFt7c2VyaWFsLCBuYW1lLCBtZWRpYSwgLi4ufV0KCmRlZiBsaW1lX3NjYW4oKToKICAg
ICIiIkFuZ2VzY2hsb3NzZW5lIExpbWVTRFIgZmluZGVuIChMaW1lVXRpbCwgc29uc3QgU29hcHlT
RFJVdGlsKS4iIiIKICAgIGdsb2JhbCBMSU1FUwogICAgaWYgRkFLRToKICAgICAgICBMSU1FUyA9
IFt7InNlcmlhbCI6ICIxRDNBQzRGMUEyQjNDNCIsICJuYW1lIjogIkxpbWVTRFIgTWluaSIsICJt
ZWRpYSI6ICJVU0IgMy4wIn0sCiAgICAgICAgICAgICAgICAgeyJzZXJpYWwiOiAiMDAwOTA3MDEw
NUM2MjYyRSIsICJuYW1lIjogIkxpbWVTRFItVVNCIiwgIm1lZGlhIjogIlVTQiAzLjAifV0KICAg
ICAgICByZXR1cm4gTElNRVMKICAgIGRldnMgPSBbXQogICAgdHJ5OgogICAgICAgIG91dCA9IHN1
YnByb2Nlc3MucnVuKFsiTGltZVV0aWwiLCAiLS1maW5kIl0sIGNhcHR1cmVfb3V0cHV0PVRydWUs
IHRleHQ9VHJ1ZSwgdGltZW91dD0yMCkuc3Rkb3V0CiAgICAgICAgZm9yIG0gaW4gcmUuZmluZGl0
ZXIociJcWyhbXlxdXSspXF0iLCBvdXQpOgogICAgICAgICAgICBwYXJ0cyA9IFtwLnN0cmlwKCkg
Zm9yIHAgaW4gbS5ncm91cCgxKS5zcGxpdCgiLCIpXQogICAgICAgICAgICBkID0geyJuYW1lIjog
cGFydHNbMF19CiAgICAgICAgICAgIGZvciBwIGluIHBhcnRzWzE6XToKICAgICAgICAgICAgICAg
IGlmICI9IiBpbiBwOgogICAgICAgICAgICAgICAgICAgIGssIHYgPSBwLnNwbGl0KCI9IiwgMSk7
IGRbay5zdHJpcCgpXSA9IHYuc3RyaXAoKQogICAgICAgICAgICBpZiBkLmdldCgic2VyaWFsIik6
IGRldnMuYXBwZW5kKGQpCiAgICBleGNlcHQgRXhjZXB0aW9uIGFzIGU6CiAgICAgICAgbG9nKCJM
aW1lVXRpbDoiLCBlKQogICAgaWYgbm90IGRldnM6CiAgICAgICAgdHJ5OgogICAgICAgICAgICBv
dXQgPSBzdWJwcm9jZXNzLnJ1bihbIlNvYXB5U0RSVXRpbCIsICItLWZpbmQ9ZHJpdmVyPWxpbWUi
XSwKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgY2FwdHVyZV9vdXRwdXQ9VHJ1ZSwg
dGV4dD1UcnVlLCB0aW1lb3V0PTMwKS5zdGRvdXQKICAgICAgICAgICAgZm9yIGJsayBpbiByZS5z
cGxpdChyIkZvdW5kIGRldmljZSBcZCsiLCBvdXQpWzE6XToKICAgICAgICAgICAgICAgIGQgPSBk
aWN0KChrLnN0cmlwKCksIHYuc3RyaXAoKSkgZm9yIGssIHYgaW4gcmUuZmluZGFsbChyIig/bSle
XHMqKFx3Kylccyo9XHMqKC4rKSQiLCBibGspKQogICAgICAgICAgICAgICAgaWYgZC5nZXQoInNl
cmlhbCIpOgogICAgICAgICAgICAgICAgICAgIGRldnMuYXBwZW5kKHsic2VyaWFsIjogZFsic2Vy
aWFsIl0sICJtZWRpYSI6IGQuZ2V0KCJtZWRpYSIsICIiKSwKICAgICAgICAgICAgICAgICAgICAg
ICAgICAgICAgICAgIm5hbWUiOiAoZC5nZXQoImxhYmVsIikgb3IgZC5nZXQoIm5hbWUiKSBvciAi
TGltZVNEUiIpLnNwbGl0KCJbIilbMF0uc3RyaXAoKX0pCiAgICAgICAgZXhjZXB0IEV4Y2VwdGlv
biBhcyBlOgogICAgICAgICAgICBsb2coIlNvYXB5U0RSVXRpbDoiLCBlKQogICAgc2VlbiA9IHNl
dCgpCiAgICBMSU1FUyA9IFtkIGZvciBkIGluIGRldnMgaWYgbm90IChkWyJzZXJpYWwiXSBpbiBz
ZWVuIG9yIHNlZW4uYWRkKGRbInNlcmlhbCJdKSldCiAgICBsb2coIkxpbWVTRFIgZ2VmdW5kZW46
IiwgIiwgIi5qb2luKCIlcyAlcyIgJSAoZFsibmFtZSJdLCBkWyJzZXJpYWwiXSkgZm9yIGQgaW4g
TElNRVMpIG9yICJrZWluZSIpCiAgICByZXR1cm4gTElNRVMKCmRlZiBsaW1lX2Fzc2lnbihtb2Rl
KToKICAgICIiIihnc21fc2VyaWFsLCBsdGVfc2VyaWFsKSBmdWVyIGRlbiBNb2R1cy4gTGVlcmUg
V2FobCA9IGVyc3RlcyBHZXJhZXQsIGRhcwogICAgbmljaHQgc2Nob24gZGVtIGFuZGVyZW4gTmV0
eiBnZWhvZXJ0LiIiIgogICAgZGV2cyA9IExJTUVTIG9yIGxpbWVfc2NhbigpCiAgICBzZXJpYWxz
ID0gW2RbInNlcmlhbCJdIGZvciBkIGluIGRldnNdCiAgICBnID0gQy5nZXQoIkdTTV9ERVYiLCAi
Iikuc3RyaXAoKTsgbCA9IEMuZ2V0KCJMVEVfREVWIiwgIiIpLnN0cmlwKCkKICAgIGZpcnN0ID0g
bGFtYmRhIG90aGVyOiBuZXh0KChzIGZvciBzIGluIHNlcmlhbHMgaWYgcyAhPSBvdGhlciksICIi
KQogICAgaWYgbW9kZSBpbiAoImdzbSIsICJjc2ZiIikgYW5kIG5vdCBnOiBnID0gZmlyc3QobCkK
ICAgIGlmIG1vZGUgaW4gKCJsdGUiLCAiY3NmYiIpIGFuZCBub3QgbDogbCA9IGZpcnN0KGcpCiAg
ICBpZiBtb2RlID09ICJnc20iOiBsID0gIiIKICAgIGlmIG1vZGUgPT0gImx0ZSI6IGcgPSAiIgog
ICAgcmV0dXJuIGcsIGwKCmRlZiBsaW1lX2xhYmVsKHNlcmlhbCk6CiAgICBmb3IgZCBpbiBMSU1F
UzoKICAgICAgICBpZiBkWyJzZXJpYWwiXSA9PSBzZXJpYWw6CiAgICAgICAgICAgIHJldHVybiAi
JXMgKCVzKSIgJSAoZC5nZXQoIm5hbWUiLCAiTGltZVNEUiIpLCBzZXJpYWwpCiAgICByZXR1cm4g
c2VyaWFsIG9yICLigJMiCgojID09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
PT09PT09PT09PT09PT09PT09PT09PT09PT09PSBPc21vY29tLUZhZWhpZ2tlaXRlbgpfVlRZUkVG
ID0ge30KZGVmIG9zbW9faGFzKGJpbmFyeSwgd29yZCk6CiAgICAiIiJUcnVlL0ZhbHNlLCBvYiBl
aW4gT3Ntb2NvbS1Qcm9ncmFtbSBlaW5lbiBWVFktQmVmZWhsIGtlbm50OyBOb25lID0gdW5iZWth
bm50LiIiIgogICAgaWYgYmluYXJ5IG5vdCBpbiBfVlRZUkVGOgogICAgICAgIHRyeToKICAgICAg
ICAgICAgX1ZUWVJFRltiaW5hcnldID0gc3VicHJvY2Vzcy5ydW4oW2JpbmFyeSwgIi0tdnR5LXJl
Zi14bWwiXSwgY2FwdHVyZV9vdXRwdXQ9VHJ1ZSwKICAgICAgICAgICAgICAgICAgICAgICAgICAg
ICAgICAgICAgICAgICAgICAgdGV4dD1UcnVlLCB0aW1lb3V0PTE1KS5zdGRvdXQKICAgICAgICBl
eGNlcHQgRXhjZXB0aW9uOgogICAgICAgICAgICBfVlRZUkVGW2JpbmFyeV0gPSAiIgogICAgcmVm
ID0gX1ZUWVJFRltiaW5hcnldCiAgICBpZiAiPHZ0eWRvYyIgbm90IGluIHJlZjogcmV0dXJuIE5v
bmUKICAgIHJldHVybiByZS5zZWFyY2gocidpZD1bIlwnXSVzXGInICUgcmUuZXNjYXBlKHdvcmQp
LCByZWYpIGlzIG5vdCBOb25lCgpkZWYgdHpfbm93KCk6CiAgICAiIiJaZWl0em9uZSBmdWVyIE5J
VFo6IChTdHVuZGVuLCBNaW51dGVuLCBTb21tZXJ6ZWl0IDAvMSkgb2huZSBEU1QtQW50ZWlsLiIi
IgogICAgbHQgPSB0aW1lLmxvY2FsdGltZSgpCiAgICBkc3QgPSAxIGlmIGx0LnRtX2lzZHN0ID4g
MCBlbHNlIDAKICAgIG9mZiA9IGx0LnRtX2dtdG9mZiAvLyA2MCAtIGRzdCAqIDYwCiAgICBoID0g
aW50KG9mZiAvIDYwKTsgbSA9IGFicyhvZmYpICUgNjAKICAgIHJldHVybiBoLCBtaW4oKDAsIDE1
LCAzMCwgNDUpLCBrZXk9bGFtYmRhIHg6IGFicyh4IC0gbSkpLCBkc3QKCiMgPT09PT09PT09PT09
PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09IEdT
TSAoT3Ntb2NvbSkKR1NNX0NPUkUgPSBbCiAgICAoInN0cCIsICJvc21vLXN0cCIsICJvc21vLXN0
cC5jZmciKSwKICAgICgiaGxyIiwgIm9zbW8taGxyIiwgIm9zbW8taGxyLmNmZyIpLAogICAgKCJt
Z3ciLCAib3Ntby1tZ3ciLCAib3Ntby1tZ3cuY2ZnIiksCiAgICAoIm1zYyIsICJvc21vLW1zYyIs
ICJvc21vLW1zYy5jZmciKSwKICAgICgiYnNjIiwgIm9zbW8tYnNjIiwgIm9zbW8tYnNjLmNmZyIp
LAogICAgKCJ0cngiLCAib3Ntby10cngtbG1zIiwgIm9zbW8tdHJ4LWxtcy5jZmciKSwKICAgICgi
YnRzIiwgIm9zbW8tYnRzLXRyeCIsICJvc21vLWJ0cy10cnguY2ZnIiksCl0KR1NNX0RBVEEgPSBb
CiAgICAoImdnc24iLCAib3Ntby1nZ3NuIiwgIm9zbW8tZ2dzbi5jZmciKSwKICAgICgic2dzbiIs
ICJvc21vLXNnc24iLCAib3Ntby1zZ3NuLmNmZyIpLAogICAgKCJwY3UiLCAgIm9zbW8tcGN1Iiwg
ICJvc21vLXBjdS5jZmciKSwKXQpHU01fU0lQID0gKCJzaXAiLCAib3Ntby1zaXAtY29ubmVjdG9y
IiwgIm9zbW8tc2lwLWNvbm5lY3Rvci5jZmciKQpHU01fTk9ORkFUQUwgPSB7Imdnc24iLCAic2dz
biIsICJwY3UiLCAic2lwIiwgIm5yZiIsICJzY3AiLCAicGtvbSJ9Ck9TTU9fU0VSVklDRVMgPSBb
Im9zbW8tc3RwIiwgIm9zbW8taGxyIiwgIm9zbW8tbWd3IiwgIm9zbW8tbXNjIiwgIm9zbW8tYnNj
IiwKICAgICAgICAgICAgICAgICAib3Ntby1idHMtdHJ4IiwgIm9zbW8tdHJ4LWxtcyIsICJvc21v
LXNpcC1jb25uZWN0b3IiLAogICAgICAgICAgICAgICAgICJvc21vLXBjdSIsICJvc21vLXNnc24i
LCAib3Ntby1nZ3NuIl0KCmRlZiBnc21fY29tcG9uZW50cygpOgogICAgY29tcHMgPSBsaXN0KEdT
TV9DT1JFKQogICAgaWYgQ1siR1NNX0RBVEEiXSA9PSAiMSI6IGNvbXBzICs9IEdTTV9EQVRBCiAg
ICBpZiBDWyJHU01fU0lQIl0gPT0gIjEiIGFuZCBDWyJHU01fU0lQX1BFRVIiXTogY29tcHMgKz0g
W0dTTV9TSVBdCiAgICByZXR1cm4gY29tcHMKCmRlZiBfdGFpbHNjYWxlX2lwKCk6CiAgICB0cnk6
CiAgICAgICAgb3V0ID0gc3VicHJvY2Vzcy5ydW4oWyJ0YWlsc2NhbGUiLCAiaXAiLCAiLTQiXSwg
Y2FwdHVyZV9vdXRwdXQ9VHJ1ZSwgdGV4dD1UcnVlLCB0aW1lb3V0PTUpLnN0ZG91dAogICAgICAg
IGZvciBsaW5lIGluIG91dC5zcGxpdGxpbmVzKCk6CiAgICAgICAgICAgIGlwID0gbGluZS5zdHJp
cCgpCiAgICAgICAgICAgIGlmIHJlLm1hdGNoKHIiMTAwXC5cZCtcLlxkK1wuXGQrJCIsIGlwKTog
cmV0dXJuIGlwCiAgICBleGNlcHQgRXhjZXB0aW9uOiBwYXNzCiAgICByZXR1cm4gIjAuMC4wLjAi
CgpkZWYgX2dwcnNfYmxvY2sobSk6CiAgICBpID0gbS5ncm91cCgxKQogICAgTCA9IFsiZ3BycyBt
b2RlIGVncHJzIiwgImdwcnMgcm91dGluZyBhcmVhIDAiLCAiZ3BycyBuZXR3b3JrLWNvbnRyb2wt
b3JkZXIgbmMwIiwKICAgICAgICAgImdwcnMgY2VsbCBidmNpIDEyMzQiLCAiZ3BycyBuc2VpIDEy
MzQiLCAiZ3BycyBuc3ZjIDAgbnN2Y2kgMTIzNCIsCiAgICAgICAgICJncHJzIG5zdmMgMCBsb2Nh
bCB1ZHAgcG9ydCAyMzAwMSIsICJncHJzIG5zdmMgMCByZW1vdGUgdWRwIHBvcnQgMjMwMDAiLAog
ICAgICAgICAiZ3BycyBuc3ZjIDAgcmVtb3RlIGlwIDEyNy4wLjAuMSJdCiAgICByZXR1cm4gaSAr
ICgiXG4iICsgaSkuam9pbihMKQoKZGVmIGdzbV9wcmVwYXJlKCk6CiAgICBmb3IgX24sIF9iLCBj
ZmcgaW4gZ3NtX2NvbXBvbmVudHMoKToKICAgICAgICBzcmMgPSBvcy5wYXRoLmpvaW4oT1NNT19D
RkcsIGNmZykKICAgICAgICBpZiBvcy5wYXRoLmlzZmlsZShzcmMpOiBzaHV0aWwuY29weShzcmMs
IG9zLnBhdGguam9pbihXT1JLRElSLCBjZmcpKQogICAgYXJmY24sIG1jYywgbW5jID0gaW50KENb
IkdTTV9BUkZDTiJdKSwgQ1siTUNDIl0sIENbIk1OQyJdCiAgICBkYXRhX29uID0gQ1siR1NNX0RB
VEEiXSA9PSAiMSI7IG9wZW5fcmVnID0gQ1siR1NNX09QRU4iXSA9PSAiMSIKICAgIGJzYyA9IG9z
LnBhdGguam9pbihXT1JLRElSLCAib3Ntby1ic2MuY2ZnIikKICAgIHJ1bGVzID0gWwogICAgICAg
IChyIl4oXHMqbmV0d29yayBjb3VudHJ5IGNvZGVccyspXGQrIiwgciJcZzwxPiIgKyBtY2MpLAog
ICAgICAgIChyIl4oXHMqbW9iaWxlIG5ldHdvcmsgY29kZVxzKylcZCsiLCByIlxnPDE+IiArIG1u
YyksCiAgICAgICAgKHIiXihccypiYW5kXHMrKVxTKyIsIHIiXGc8MT4iICsgYXJmY25fYmFuZChh
cmZjbikpLAogICAgICAgIChyIl4oXHMqYXJmY25ccyspXGQrIiwgciJcZzwxPiIgKyBzdHIoYXJm
Y24pKSwKICAgICAgICAociJeKFxzKm1heF9wb3dlcl9yZWRccyspXGQrIiwgciJcZzwxPjAiKSwK
ICAgIF0KICAgIGlmIG5vdCBkYXRhX29uOgogICAgICAgIHJ1bGVzLmFwcGVuZCgociJeKFxzKmdw
cnMgbW9kZVxzKylcUysiLCByIlxnPDE+bm9uZSIpKQogICAgX3N1Yihic2MsIHJ1bGVzKQogICAg
aWYgZGF0YV9vbjoKICAgICAgICB0ID0gb3Blbihic2MpLnJlYWQoKQogICAgICAgIHQgPSByZS5z
dWIociIoP20pXlxzKmdwcnMgKHJvdXRpbmcgYXJlYXxuZXR3b3JrLWNvbnRyb2wtb3JkZXJ8Y2Vs
bHxuc2VpfG5zdmMpXGIuKlxuPyIsICIiLCB0KQogICAgICAgIHQgPSByZS5zdWIociIoP20pXihc
cyopZ3BycyBtb2RlXHMrXFMrLiokIiwgX2dwcnNfYmxvY2ssIHQsIGNvdW50PTEpCiAgICAgICAg
Zm9yIHRzIGluICgiNSIsICI2IiwgIjciKToKICAgICAgICAgICAgdCA9IHJlLnN1YihyZiIoP20p
KF5ccyp0aW1lc2xvdCB7dHN9XHMqXG5ccypwaHlzX2NoYW5fY29uZmlnXHMrKVRDSC9GXHMqJCIs
IHIiXGc8MT5UQ0gvRl9QRENIIiwgdCkKICAgICAgICBvcGVuKGJzYywgInciKS53cml0ZSh0KQog
ICAgIyBNU0M6IEtlbm51bmcgKyBOYW1lCiAgICBfc3ViKG9zLnBhdGguam9pbihXT1JLRElSLCAi
b3Ntby1tc2MuY2ZnIiksIFsKICAgICAgICAociJeKFxzKm5ldHdvcmsgY291bnRyeSBjb2RlXHMr
KVxkKyIsIHIiXGc8MT4iICsgbWNjKSwKICAgICAgICAociJeKFxzKm1vYmlsZSBuZXR3b3JrIGNv
ZGVccyspXGQrIiwgciJcZzwxPiIgKyBtbmMpLAogICAgXSkKICAgIG1zYyA9IG9zLnBhdGguam9p
bihXT1JLRElSLCAib3Ntby1tc2MuY2ZnIik7IGhsciA9IG9zLnBhdGguam9pbihXT1JLRElSLCAi
b3Ntby1obHIuY2ZnIikKICAgIF92dHlfZGVsKG1zYywgImF1dGhlbnRpY2F0aW9uIikKICAgICMg
TmV0em5hbWUgKyBOSVRaOiBNTS1JbmZvcm1hdGlvbiBtaXQgTmFtZSwgVWhyemVpdCB1bmQgWmVp
dHpvbmUgYW5zIEhhbmR5CiAgICB3b3JkID0gbGFtYmRhIHM6IHJlLnN1YihyIlteXHcuKy1dIiwg
Ii0iLCBzIG9yICJwS09NIikgICAgICAjIFZUWTogZWluIFdvcnQKICAgIF92dHlfc2V0KG1zYywg
Im5ldHdvcmsiLCAic2hvcnQgbmFtZSIsICJzaG9ydCBuYW1lICIgKyB3b3JkKEMuZ2V0KCJORVRO
QU1FX1NIT1JUIikgb3IgQ1siTkVUTkFNRSJdKSkKICAgIF92dHlfc2V0KG1zYywgIm5ldHdvcmsi
LCAibG9uZyBuYW1lIiwgImxvbmcgbmFtZSAiICsgd29yZChDWyJORVROQU1FIl0pKQogICAgaWYg
Qy5nZXQoIk5JVFoiLCAiMSIpID09ICIxIjoKICAgICAgICBfdnR5X3NldChtc2MsICJuZXR3b3Jr
IiwgIm1tIGluZm8iLCAibW0gaW5mbyAxIikKICAgICAgICBpZiBvc21vX2hhcygib3Ntby1tc2Mi
LCAidGltZXpvbmUiKToKICAgICAgICAgICAgX3Z0eV9zZXQobXNjLCAibmV0d29yayIsICJ0aW1l
em9uZSIsICJ0aW1lem9uZSAlZCAlZCAlZCIgJSB0el9ub3coKSkKICAgIGVsc2U6CiAgICAgICAg
X3Z0eV9zZXQobXNjLCAibmV0d29yayIsICJtbSBpbmZvIiwgIm1tIGluZm8gMCIpCiAgICAgICAg
X3Z0eV9kZWwobXNjLCAidGltZXpvbmUiKQogICAgIyBTR3MgenVyIE9wZW41R1MtTU1FIChudXIg
aW0gTW9kdXMgTFRFICsgR1NNKQogICAgdCA9IG9wZW4obXNjKS5yZWFkKCkKICAgIHQgPSByZS5z
dWIociIoP20pXnNnc1sgXHRdKlxuKD86WyBcdF0rLiooPzpcbnwkKSkqIiwgIiIsIHQpCiAgICBp
ZiBORVQudGVjaCA9PSAiY3NmYiI6CiAgICAgICAgdCA9IHQucnN0cmlwKCJcbiIpICsgIlxuc2dz
XG4gbG9jYWwtcG9ydCAlZFxuIGxvY2FsLWlwIDEyNy4wLjAuMVxuIHZsci1uYW1lIHZsci5wa29t
LnRlc3RcbiIgJSBTR1NfUE9SVAogICAgb3Blbihtc2MsICJ3Iikud3JpdGUodCkKICAgICMgZWln
ZW5lciBMaW1lU0RSIGZ1ZXIgR1NNIChvc21vLXRyeC1sbXMgd2FlaGx0IHBlciBUZWlsc3RyaW5n
IGRlciBHZXJhZXRlbGlzdGUpCiAgICB0cnggPSBvcy5wYXRoLmpvaW4oV09SS0RJUiwgIm9zbW8t
dHJ4LWxtcy5jZmciKQogICAgaWYgb3MucGF0aC5pc2ZpbGUodHJ4KToKICAgICAgICBpZiBORVQu
ZGV2X2dzbToKICAgICAgICAgICAgX3Z0eV9zZXQodHJ4LCAidHJ4IiwgImRldi1hcmdzIiwgImRl
di1hcmdzIHNlcmlhbD0iICsgTkVULmRldl9nc20pCiAgICAgICAgZWxzZToKICAgICAgICAgICAg
X3Z0eV9kZWwodHJ4LCAiZGV2LWFyZ3MiKQogICAgaWYgb3Blbl9yZWc6CiAgICAgICAgX3Z0eV9z
ZXQoaGxyLCAiaGxyIiwgInN1YnNjcmliZXItY3JlYXRlLW9uLWRlbWFuZCIsICJzdWJzY3JpYmVy
LWNyZWF0ZS1vbi1kZW1hbmQgbm8tbXNpc2RuIGNzK3BzIikKICAgIGVsc2U6CiAgICAgICAgX3Z0
eV9kZWwoaGxyLCAic3Vic2NyaWJlci1jcmVhdGUtb24tZGVtYW5kIikKICAgICMgUlgtR2FpbiAo
aW5zdGFuY2UtS25vdGVuIGRlciBvc21vLWJ0cy10cnguY2ZnKQogICAgYnRzID0gb3MucGF0aC5q
b2luKFdPUktESVIsICJvc21vLWJ0cy10cnguY2ZnIikKICAgIGlmIG9zLnBhdGguaXNmaWxlKGJ0
cyk6CiAgICAgICAgYnQgPSBvcGVuKGJ0cykucmVhZCgpOyByZyA9IGludChDWyJHU01fUlhfR0FJ
TiJdKQogICAgICAgIGlmIHJlLnNlYXJjaChyIig/bSleXHMqb3Ntb3RyeCByeC1nYWluXGIiLCBi
dCk6CiAgICAgICAgICAgIGJ0ID0gcmUuc3ViKHIiKD9tKV4oXHMqb3Ntb3RyeCByeC1nYWluXHMr
KS4qJCIsIHIiXGc8MT4lZCIgJSByZywgYnQpCiAgICAgICAgZWxzZToKICAgICAgICAgICAgYnQg
PSByZS5zdWIociIoP20pXihccyppbnN0YW5jZSAwXHMqKSQiLCByIlwxXG4gIG9zbW90cnggcngt
Z2FpbiAlZCIgJSByZywgYnQsIGNvdW50PTEpCiAgICAgICAgb3BlbihidHMsICJ3Iikud3JpdGUo
YnQpCiAgICAjIFNJUC1UcnVuawogICAgaWYgQ1siR1NNX1NJUCJdID09ICIxIiBhbmQgQ1siR1NN
X1NJUF9QRUVSIl06CiAgICAgICAgX3Z0eV9zZXQobXNjLCAibXNjIiwgIm1uY2MiLCAibW5jYyBl
eHRlcm5hbCAvdG1wL21uY2Muc29jayIpCiAgICAgICAgbG9jYWwgPSBDLmdldCgiR1NNX1NJUF9M
T0NBTCIpIG9yIF90YWlsc2NhbGVfaXAoKQogICAgICAgIHdpdGggb3Blbihvcy5wYXRoLmpvaW4o
V09SS0RJUiwgIm9zbW8tc2lwLWNvbm5lY3Rvci5jZmciKSwgInciKSBhcyBmOgogICAgICAgICAg
ICBmLndyaXRlKCJtbmNjXG4gc29ja2V0LXBhdGggL3RtcC9tbmNjLnNvY2tcbnNpcFxuIGxvY2Fs
ICVzIDUwNjBcbiByZW1vdGUgJXMgNTA2MFxuIgogICAgICAgICAgICAgICAgICAgICUgKGxvY2Fs
LCBDWyJHU01fU0lQX1BFRVIiXSkpCiAgICBlbHNlOgogICAgICAgIF92dHlfc2V0KG1zYywgIm1z
YyIsICJtbmNjIiwgIm1uY2MgaW50ZXJuYWwiKQogICAgaWYgZGF0YV9vbiBhbmQgb3Blbl9yZWc6
CiAgICAgICAgX3Z0eV9zZXQob3MucGF0aC5qb2luKFdPUktESVIsICJvc21vLXNnc24uY2ZnIiks
ICJzZ3NuIiwgImF1dGgtcG9saWN5IiwgImF1dGgtcG9saWN5IGFjY2VwdC1hbGwiKQoKIyAtLS0t
IFNJTXM6IEVJTkUgTGlzdGUgZnVlciBiZWlkZSBOZXR6ZQojIEVpbmdldHJhZ2VuIHdpcmQgbnVy
IGhpZXI7IHBLT00gc2NocmVpYnQgamVkZSBTSU0gYXV0b21hdGlzY2ggaW5zIG9zbW8taGxyIChH
U00pCiMgdW5kIGluIGRlbiBPcGVuNUdTLUhTUyAoTFRFLCBNb25nb0RCKS4gS2kvT1BjIHZlcmxh
c3NlbiBkZW4gUmVjaG5lciBuaWUKIyAoZGllIFdlYm9iZXJmbGFlY2hlIGJla29tbXQgbnVyIElN
U0kgKyBSdWZudW1tZXIgenVydWVjaykuClNJTVNfRklMRSA9IG9zLnBhdGguam9pbihXT1JLRElS
LCAic2ltcy5qc29uIikKCmRlZiBzaW1zX2xvYWQoKToKICAgIHRyeTogcmV0dXJuIGpzb24ubG9h
ZChvcGVuKFNJTVNfRklMRSkpCiAgICBleGNlcHQgRXhjZXB0aW9uOiByZXR1cm4ge30KCmRlZiBz
aW1zX3NhdmUoZCk6CiAgICB0cnk6CiAgICAgICAgdG1wID0gU0lNU19GSUxFICsgIi50bXAiCiAg
ICAgICAgd2l0aCBvcGVuKHRtcCwgInciKSBhcyBmOiBqc29uLmR1bXAoZCwgZiwgaW5kZW50PTEp
CiAgICAgICAgb3MuY2htb2QodG1wLCAwbzYwMCk7IG9zLnJlcGxhY2UodG1wLCBTSU1TX0ZJTEUp
CiAgICBleGNlcHQgRXhjZXB0aW9uIGFzIGU6CiAgICAgICAgbG9nKCJzaW1zOiIsIGUpCgpkZWYg
Z3NtX29uKCk6CiAgICByZXR1cm4gTkVULnRlY2ggaW4gKCJnc20iLCAiY3NmYiIpCgpkZWYgbHRl
X29uKCk6CiAgICByZXR1cm4gTkVULnRlY2ggaW4gKCJsdGUiLCAiY3NmYiIpCgpkZWYgX2hleDMy
KHgpOgogICAgcmV0dXJuIHJlLnN1YihyIlteMC05YS1mQS1GXSIsICIiLCB4IG9yICIiKS51cHBl
cigpCgpkZWYgaGxyX3B1dChpbXNpLCBzKToKICAgIGlmIEZBS0U6IHJldHVybiBOb25lCiAgICBy
ID0gdnR5KEhMUl9WVFksIFsiZW5hYmxlIiwgZiJzdWJzY3JpYmVyIGltc2kge2ltc2l9IGNyZWF0
ZSIsCiAgICAgICAgICAgICAgICAgICAgICBmInN1YnNjcmliZXIgaW1zaSB7aW1zaX0gdXBkYXRl
IG1zaXNkbiB7cy5nZXQoJ21zaXNkbicpIG9yIGltc2lbLTg6XX0iLAogICAgICAgICAgICAgICAg
ICAgICAgZiJzdWJzY3JpYmVyIGltc2kge2ltc2l9IHVwZGF0ZSBhdWQzZyBtaWxlbmFnZSBrIHtz
WydraSddfSBvcGMge3NbJ29wYyddfSJdKQogICAgcmV0dXJuIE5vbmUgaWYgIiUgIiBub3QgaW4g
ci5yZXBsYWNlKCIlIFN1YnNjcmliZXIgYWxyZWFkeSBleGlzdHMiLCAiIikgZWxzZSByLnN0cmlw
KClbLTE2MDpdCgpkZWYgX2hzcygpOgogICAgaW1wb3J0IHB5bW9uZ28KICAgIHJldHVybiBweW1v
bmdvLk1vbmdvQ2xpZW50KCJtb25nb2RiOi8vMTI3LjAuMC4xLyIsIHNlcnZlclNlbGVjdGlvblRp
bWVvdXRNUz0zMDAwKVsib3BlbjVncyJdWyJzdWJzY3JpYmVycyJdCgpkZWYgaHNzX3B1dChpbXNp
LCBzKToKICAgICIiIlNJTSBpbiBkZW4gT3BlbjVHUy1IU1Mgc2NocmVpYmVuIChhbmxlZ2VuIG9k
ZXIgYWt0dWFsaXNpZXJlbiwgU1FOIGJsZWlidCkuIiIiCiAgICBpZiBGQUtFOiByZXR1cm4gTm9u
ZQogICAgdHJ5OgogICAgICAgIGZyb20gYnNvbi5pbnQ2NCBpbXBvcnQgSW50NjQKICAgICAgICBh
bWJyID0geyJkb3dubGluayI6IHsidmFsdWUiOiAxLCAidW5pdCI6IDN9LCAidXBsaW5rIjogeyJ2
YWx1ZSI6IDEsICJ1bml0IjogM319ICAgIyAxIEdiaXQvcwogICAgICAgIHNlc3MgPSB7Im5hbWUi
OiBDLmdldCgiTFRFX0FQTiIpIG9yICJpbnRlcm5ldCIsICJ0eXBlIjogMywgICAgICAgICAgIyAz
ID0gSVB2NHY2CiAgICAgICAgICAgICAgICAicW9zIjogeyJpbmRleCI6IDksICJhcnAiOiB7InBy
aW9yaXR5X2xldmVsIjogOCwgInByZV9lbXB0aW9uX2NhcGFiaWxpdHkiOiAxLAogICAgICAgICAg
ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICJwcmVfZW1wdGlvbl92dWxuZXJhYmls
aXR5IjogMX19LAogICAgICAgICAgICAgICAgImFtYnIiOiBhbWJyLCAicGNjX3J1bGUiOiBbXX0K
ICAgICAgICBfaHNzKCkudXBkYXRlX29uZSh7Imltc2kiOiBpbXNpfSwgewogICAgICAgICAgICAi
JHNldCI6IHsiaW1zaSI6IGltc2ksICJtc2lzZG4iOiBbc1sibXNpc2RuIl1dIGlmIHMuZ2V0KCJt
c2lzZG4iKSBlbHNlIFtdLAogICAgICAgICAgICAgICAgICAgICAic2VjdXJpdHkuayI6IHNbImtp
Il0sICJzZWN1cml0eS5vcGMiOiBzWyJvcGMiXSwgInNlY3VyaXR5Lm9wIjogTm9uZSwKICAgICAg
ICAgICAgICAgICAgICAgInNlY3VyaXR5LmFtZiI6ICI4MDAwIiwgImFtYnIiOiBhbWJyLAogICAg
ICAgICAgICAgICAgICAgICAic2xpY2UiOiBbeyJzc3QiOiAxLCAiZGVmYXVsdF9pbmRpY2F0b3Ii
OiBUcnVlLCAic2Vzc2lvbiI6IFtzZXNzXX1dLAogICAgICAgICAgICAgICAgICAgICAiYWNjZXNz
X3Jlc3RyaWN0aW9uX2RhdGEiOiAzMiwgInN1YnNjcmliZXJfc3RhdHVzIjogMCwKICAgICAgICAg
ICAgICAgICAgICAgIm9wZXJhdG9yX2RldGVybWluZWRfYmFycmluZyI6IDAsCiAgICAgICAgICAg
ICAgICAgICAgICJuZXR3b3JrX2FjY2Vzc19tb2RlIjogMCwgICAgICAgICMgMCA9IFBha2V0ICsg
TGVpdHVuZyAtPiBrb21iaW5pZXJ0ZXIgQXR0YWNoIChDU0ZCKQogICAgICAgICAgICAgICAgICAg
ICAic3Vic2NyaWJlZF9yYXVfdGF1X3RpbWVyIjogMTJ9LAogICAgICAgICAgICAiJHNldE9uSW5z
ZXJ0IjogeyJzZWN1cml0eS5zcW4iOiBJbnQ2NCg5NyksICJpbWVpc3YiOiBbXSwgIm1tZV9ob3N0
IjogW10sCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIm1tZV9yZWFsbSI6IFtdLCAicHVy
Z2VfZmxhZyI6IFtdLCAiX192IjogMH19LCB1cHNlcnQ9VHJ1ZSkKICAgICAgICByZXR1cm4gTm9u
ZQogICAgZXhjZXB0IEltcG9ydEVycm9yOgogICAgICAgIHJldHVybiAicHl0aG9uMy1weW1vbmdv
IGZlaGx0IChJbnN0YWxsZXIgZXJuZXV0IGF1c2Z1ZWhyZW4pIgogICAgZXhjZXB0IEV4Y2VwdGlv
biBhcyBlOgogICAgICAgIHJldHVybiAiSFNTL01vbmdvREI6ICVzIiAlIHN0cihlKVs6MTIwXQoK
ZGVmIGhzc19kZWwoaW1zaSk6CiAgICBpZiBGQUtFOiByZXR1cm4KICAgIHRyeTogX2hzcygpLmRl
bGV0ZV9vbmUoeyJpbXNpIjogaW1zaX0pCiAgICBleGNlcHQgRXhjZXB0aW9uIGFzIGU6IGxvZygi
aHNzIGxvZXNjaGVuOiIsIGUpCgpkZWYgaHNzX3N5bmNfYWxsKCk6CiAgICBlcnJzID0gW2UgZm9y
IGUgaW4gKGhzc19wdXQoaSwgcykgZm9yIGksIHMgaW4gc2ltc19sb2FkKCkuaXRlbXMoKSkgaWYg
ZV0KICAgIHJldHVybiBlcnJzWzBdIGlmIGVycnMgZWxzZSBOb25lCgpkZWYgc2ltX2FkZChpbXNp
LCBraSwgb3BjLCBtc2lzZG4pOgogICAgaW1zaSA9IHJlLnN1YihyIlxEIiwgIiIsIGltc2kgb3Ig
IiIpOyBraSA9IF9oZXgzMihraSk7IG9wYyA9IF9oZXgzMihvcGMpCiAgICBpZiBsZW4oaW1zaSkg
PCAxNCBvciBsZW4oa2kpICE9IDMyIG9yIGxlbihvcGMpICE9IDMyOgogICAgICAgIHJldHVybiAi
SU1TSSAoMTUgWmlmZmVybiksIEtpIHVuZCBPUGMgKGplIDMyIEhleCkgcHJ1ZWZlbiIKICAgIG1z
aXNkbiA9IHJlLnN1YihyIlxEIiwgIiIsIG1zaXNkbiBvciAiIikgb3IgbnVtc19sb2FkKCkuZ2V0
KGltc2kpIG9yIGltc2lbLTg6XQogICAgZCA9IHNpbXNfbG9hZCgpOyBkW2ltc2ldID0geyJraSI6
IGtpLCAib3BjIjogb3BjLCAibXNpc2RuIjogbXNpc2RufTsgc2ltc19zYXZlKGQpCiAgICBuID0g
bnVtc19sb2FkKCk7IG5baW1zaV0gPSBtc2lzZG47IG51bXNfc2F2ZShuKSAgICAgICAgICAjIFJ1
Zm51bW1lciBkYXVlcmhhZnQKICAgIGVycnMgPSBbXQogICAgZSA9IGhzc19wdXQoaW1zaSwgZFtp
bXNpXSkKICAgIGlmIGU6IGVycnMuYXBwZW5kKGUpCiAgICBpZiBnc21fb24oKSBhbmQgbm90IEZB
S0U6CiAgICAgICAgZSA9IGhscl9wdXQoaW1zaSwgZFtpbXNpXSkKICAgICAgICBpZiBlOiBlcnJz
LmFwcGVuZCgiSExSOiAiICsgZSkKICAgICAgICBlbHNlOiBzbXNfc2VuZChpbXNpLCBfc21zX3Rl
eHQoQy5nZXQoIkdTTV9TTVNfTlVNQkVSIiwgIiIpLCBudW1tZXI9bXNpc2RuKSkKICAgIHJldHVy
biAoIlNJTSBnZXNwZWljaGVydCwgYWJlcjogIiArICI7ICIuam9pbihlcnJzKSkgaWYgZXJycyBl
bHNlIE5vbmUKCmRlZiBzaW1fZGVsKGltc2kpOgogICAgaW1zaSA9IHJlLnN1YihyIlxEIiwgIiIs
IGltc2kgb3IgIiIpCiAgICBkID0gc2ltc19sb2FkKCkKICAgIGlmIGltc2kgaW4gZDoKICAgICAg
ICBkZWwgZFtpbXNpXTsgc2ltc19zYXZlKGQpCiAgICBoc3NfZGVsKGltc2kpCiAgICBpZiBnc21f
b24oKSBhbmQgbm90IEZBS0U6CiAgICAgICAgdnR5KEhMUl9WVFksIFsiZW5hYmxlIiwgZiJzdWJz
Y3JpYmVyIGltc2kge2ltc2l9IGRlbGV0ZSJdKQoKZGVmIF9taWdyYXRlX2x0ZV9kYigpOgogICAg
IiIiQWx0ZSBzcnNFUEMtTGlzdGUgKHVzZXJfZGIuY3N2KSBlaW5tYWxpZyBpbiBkaWUgZ2VtZWlu
c2FtZSBTSU0tTGlzdGUgdWViZXJuZWhtZW4uIiIiCiAgICB1ZGIgPSBvcy5wYXRoLmpvaW4oV09S
S0RJUiwgInVzZXJfZGIuY3N2IikKICAgIGlmIG5vdCBvcy5wYXRoLmlzZmlsZSh1ZGIpOiByZXR1
cm4KICAgIGQgPSBzaW1zX2xvYWQoKTsgbnVtcyA9IG51bXNfbG9hZCgpOyBuID0gMAogICAgZm9y
IGwgaW4gb3Blbih1ZGIpLnJlYWQoKS5zcGxpdGxpbmVzKCk6CiAgICAgICAgZiA9IGwuc3BsaXQo
IiwiKQogICAgICAgIGlmIGxlbihmKSA+PSA1IGFuZCBub3QgbC5zdGFydHN3aXRoKCIjIikgYW5k
IGZbMF0gbm90IGluIGQgYW5kIGxlbihfaGV4MzIoZlszXSkpID09IDMyOgogICAgICAgICAgICBk
W2ZbMF1dID0geyJraSI6IF9oZXgzMihmWzNdKSwgIm9wYyI6IF9oZXgzMihmWzRdKSwgIm1zaXNk
biI6IG51bXMuZ2V0KGZbMF0sICIiKX07IG4gKz0gMQogICAgaWYgbjogc2ltc19zYXZlKGQpCiAg
ICB0cnk6IG9zLnJlcGxhY2UodWRiLCB1ZGIgKyAiLmFsdCIpCiAgICBleGNlcHQgRXhjZXB0aW9u
OiBwYXNzCiAgICBsb2coZiJ7bn0gU0lNKHMpIGF1cyBkZXIgYWx0ZW4gc3JzRVBDLUxpc3RlIHVl
YmVybm9tbWVuIikKCiMgRGF1ZXJoYWZ0ZSBJTVNJLT5SdWZudW1tZXItWnV3ZWlzdW5nZW4gKHVl
YmVybGViZW4gTmV1c3RhcnRzLCB3ZXJkZW4gYmVpIGplZGVtCiMgR1NNLVN0YXJ0IGVybmV1dCBp
bnMgSExSIGdlc2NocmllYmVuIC0gYXVjaCBmdWVyIG9mZmVuIGFuZ2VtZWxkZXRlIFNJTXMgb2hu
ZSBLaSkuCk5VTVNfRklMRSA9IG9zLnBhdGguam9pbihXT1JLRElSLCAibnVtYmVycy5qc29uIikK
CmRlZiBudW1zX2xvYWQoKToKICAgIHRyeTogcmV0dXJuIGpzb24ubG9hZChvcGVuKE5VTVNfRklM
RSkpCiAgICBleGNlcHQgRXhjZXB0aW9uOiByZXR1cm4ge30KCmRlZiBudW1zX3NhdmUoZCk6CiAg
ICB0cnk6IGpzb24uZHVtcChkLCBvcGVuKE5VTVNfRklMRSwgInciKSkKICAgIGV4Y2VwdCBFeGNl
cHRpb24gYXMgZTogbG9nKCJudW1iZXJzOiIsIGUpCgpkZWYgZ3NtX2FwcGx5X251bWJlcnMoKToK
ICAgICIiIkJlaW0gR1NNLVN0YXJ0OiBhbGxlIFNJTXMgKG1pdCBTY2hsdWVzc2VsKSArIFJ1Zm51
bW1lcm4gaW5zIEhMUiBzY2hyZWliZW4uIiIiCiAgICBpZiBGQUtFOiByZXR1cm4KICAgIGZvciBp
bXNpLCBzIGluIHNpbXNfbG9hZCgpLml0ZW1zKCk6CiAgICAgICAgZSA9IGhscl9wdXQoaW1zaSwg
cykKICAgICAgICBpZiBlOiBsb2coImhscjoiLCBpbXNpLCBlKQogICAgZCA9IG51bXNfbG9hZCgp
CiAgICBpZiBub3QgZDogcmV0dXJuCiAgICBjbWRzID0gWyJlbmFibGUiXQogICAgZm9yIGltc2ks
IG1zaXNkbiBpbiBkLml0ZW1zKCk6CiAgICAgICAgY21kcyArPSBbZiJzdWJzY3JpYmVyIGltc2kg
e2ltc2l9IGNyZWF0ZSIsIGYic3Vic2NyaWJlciBpbXNpIHtpbXNpfSB1cGRhdGUgbXNpc2RuIHtt
c2lzZG59Il0KICAgIHZ0eShITFJfVlRZLCBjbWRzKQoKZGVmIGdzbV9zaW1fbnIoaW1zaSwgbXNp
c2RuKToKICAgIGltc2kgPSByZS5zdWIociJcRCIsICIiLCBpbXNpKTsgbXNpc2RuID0gcmUuc3Vi
KHIiXEQiLCAiIiwgbXNpc2RuKQogICAgaWYgbGVuKGltc2kpIDwgMTQgb3Igbm90IG1zaXNkbjog
cmV0dXJuICJJTVNJICgxNSBaaWZmZXJuKSB1bmQgUnVmbnVtbWVyIHBydWVmZW4iCiAgICBkID0g
bnVtc19sb2FkKCk7IGRbaW1zaV0gPSBtc2lzZG47IG51bXNfc2F2ZShkKSAgICAgICAgIyBkYXVl
cmhhZnQgbWVya2VuCiAgICBzID0gc2ltc19sb2FkKCkKICAgIGlmIGltc2kgaW4gczogICAgICAg
ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIyBTSU0gbWl0IFNjaGx1ZXNzZWw6
IGF1Y2ggaW0gSFNTCiAgICAgICAgc1tpbXNpXVsibXNpc2RuIl0gPSBtc2lzZG47IHNpbXNfc2F2
ZShzKTsgaHNzX3B1dChpbXNpLCBzW2ltc2ldKQogICAgaWYgbm90IEZBS0UgYW5kIGdzbV9vbigp
OiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAjIHNvZm9ydCBhbndlbmRlbiwgd2VubiBH
U00gbGFldWZ0CiAgICAgICAgdnR5KEhMUl9WVFksIFsiZW5hYmxlIiwgZiJzdWJzY3JpYmVyIGlt
c2kge2ltc2l9IGNyZWF0ZSIsCiAgICAgICAgICAgICAgICAgICAgICBmInN1YnNjcmliZXIgaW1z
aSB7aW1zaX0gdXBkYXRlIG1zaXNkbiB7bXNpc2RufSJdKQogICAgICAgIHNtc19zZW5kKGltc2ks
IF9zbXNfdGV4dChDLmdldCgiR1NNX1NNU19OVU1CRVIiLCAiIiksIG51bW1lcj1tc2lzZG4pKQog
ICAgcmV0dXJuIE5vbmUKCmRlZiBnc21fbnVtX2RlbChpbXNpKToKICAgIGltc2kgPSByZS5zdWIo
ciJcRCIsICIiLCBpbXNpKTsgZCA9IG51bXNfbG9hZCgpCiAgICBpZiBpbXNpIGluIGQ6CiAgICAg
ICAgZGVsIGRbaW1zaV07IG51bXNfc2F2ZShkKQogICAgaWYgbm90IEZBS0UgYW5kIGdzbV9vbigp
OgogICAgICAgIHZ0eShITFJfVlRZLCBbImVuYWJsZSIsIGYic3Vic2NyaWJlciBpbXNpIHtpbXNp
fSB1cGRhdGUgbXNpc2RuICJdKQoKIyAtLS0tIFNJTS1EYXRlbiBlcnpldWdlbiAoZnVlciBlaWdl
bmUgZVNJTS1Qcm9maWxlLCB6LkIuIHNpbWxlc3NseSkKIyBJTVNJID0gZWlnZW5lIEtlbm51bmcg
KE1DQytNTkMpICsgenVmYWVsbGlnZSBNU0lOLCBLaS9PUCB6dWZhZWxsaWcgKHNlY3JldHMpLAoj
IE9QYyA9IEFFU19LaShPUCkgeG9yIE9QIChNaWxlbmFnZSwgVFMgMzUuMjA2KSwgSUNDSUQgbWl0
IEx1aG4tUHJ1ZWZ6aWZmZXIuCl9TQk9YID0gW10KZGVmIF9hZXNfdGFibGVzKCk6CiAgICBpZiBf
U0JPWDogcmV0dXJuCiAgICBwID0gcSA9IDE7IHNiID0gWzBdICogMjU2CiAgICB3aGlsZSBUcnVl
OiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICMgUy1Cb3ggdWViZXIgZGFzIElu
dmVyc2UgaW4gR0YoMl44KQogICAgICAgIHAgPSBwIF4gKChwIDw8IDEpICYgMHhGRikgXiAoMHgx
QiBpZiBwICYgMHg4MCBlbHNlIDApCiAgICAgICAgcSBePSBxIDw8IDE7IHEgXj0gcSA8PCAyOyBx
IF49IHEgPDwgNDsgcSAmPSAweEZGCiAgICAgICAgaWYgcSAmIDB4ODA6IHEgXj0gMHgwOQogICAg
ICAgIHggPSBxIF4gKChxIDw8IDEgfCBxID4+IDcpICYgMHhGRikgXiAoKHEgPDwgMiB8IHEgPj4g
NikgJiAweEZGKSBcCiAgICAgICAgICAgICAgXiAoKHEgPDwgMyB8IHEgPj4gNSkgJiAweEZGKSBe
ICgocSA8PCA0IHwgcSA+PiA0KSAmIDB4RkYpCiAgICAgICAgc2JbcF0gPSB4IF4gMHg2MwogICAg
ICAgIGlmIHAgPT0gMTogYnJlYWsKICAgIHNiWzBdID0gMHg2MwogICAgX1NCT1guZXh0ZW5kKHNi
KQoKZGVmIF94dChhKTogcmV0dXJuICgoYSA8PCAxKSBeIDB4MUIpICYgMHhGRiBpZiBhICYgMHg4
MCBlbHNlIGEgPDwgMQoKZGVmIGFlczEyOF9lbmNyeXB0KGtleSwgYmxvY2spOgogICAgIiIiQUVT
LTEyOCwgZWluIEJsb2NrIChyZWluZXMgUHl0aG9uLCBudXIgZnVlciBkaWUgT1BjLUJlcmVjaG51
bmcpLiIiIgogICAgX2Flc190YWJsZXMoKTsgUyA9IF9TQk9YCiAgICB3ID0gW2xpc3Qoa2V5W2k6
aSArIDRdKSBmb3IgaSBpbiByYW5nZSgwLCAxNiwgNCldOyByYyA9IDEKICAgIGZvciBpIGluIHJh
bmdlKDQsIDQ0KToKICAgICAgICB0ID0gbGlzdCh3W2kgLSAxXSkKICAgICAgICBpZiBpICUgNCA9
PSAwOgogICAgICAgICAgICB0ID0gW1NbYl0gZm9yIGIgaW4gdFsxOl0gKyB0WzoxXV07IHRbMF0g
Xj0gcmM7IHJjID0gX3h0KHJjKQogICAgICAgIHcuYXBwZW5kKFthIF4gYiBmb3IgYSwgYiBpbiB6
aXAod1tpIC0gNF0sIHQpXSkKICAgIHMgPSBbYiBeIGsgZm9yIGIsIGsgaW4gemlwKGJsb2NrLCBz
dW0od1swOjRdLCBbXSkpXQogICAgZm9yIHIgaW4gcmFuZ2UoMSwgMTEpOgogICAgICAgIHMgPSBb
U1tiXSBmb3IgYiBpbiBzXQogICAgICAgIHMgPSBbc1soKGMgKyBpKSAlIDQpICogNCArIGldIGZv
ciBjIGluIHJhbmdlKDQpIGZvciBpIGluIHJhbmdlKDQpXSAgICAgIyBTaGlmdFJvd3MKICAgICAg
ICBpZiByIDwgMTA6CiAgICAgICAgICAgIG0gPSBbXQogICAgICAgICAgICBmb3IgYyBpbiByYW5n
ZSg0KToKICAgICAgICAgICAgICAgIGEgPSBzW2MgKiA0OmMgKiA0ICsgNF07IHQgPSBhWzBdIF4g
YVsxXSBeIGFbMl0gXiBhWzNdCiAgICAgICAgICAgICAgICBtICs9IFthW2ldIF4gdCBeIF94dChh
W2ldIF4gYVsoaSArIDEpICUgNF0pIGZvciBpIGluIHJhbmdlKDQpXQogICAgICAgICAgICBzID0g
bQogICAgICAgIHMgPSBbYiBeIGsgZm9yIGIsIGsgaW4gemlwKHMsIHN1bSh3W3IgKiA0OnIgKiA0
ICsgNF0sIFtdKSldCiAgICByZXR1cm4gYnl0ZXMocykKCmRlZiBtaWxlbmFnZV9vcGMoa19oZXgs
IG9wX2hleCk6CiAgICBrLCBvcCA9IGJ5dGVzLmZyb21oZXgoa19oZXgpLCBieXRlcy5mcm9taGV4
KG9wX2hleCkKICAgIHJldHVybiBieXRlcyhhIF4gYiBmb3IgYSwgYiBpbiB6aXAoYWVzMTI4X2Vu
Y3J5cHQoaywgb3ApLCBvcCkpLmhleCgpLnVwcGVyKCkKCmRlZiBsdWhuKGRpZ2l0cyk6CiAgICB0
b3QgPSAwCiAgICBmb3IgaSwgY2ggaW4gZW51bWVyYXRlKHJldmVyc2VkKGRpZ2l0cykpOgogICAg
ICAgIGQgPSBpbnQoY2gpCiAgICAgICAgaWYgaSAlIDIgPT0gMDoKICAgICAgICAgICAgZCAqPSAy
CiAgICAgICAgICAgIGlmIGQgPiA5OiBkIC09IDkKICAgICAgICB0b3QgKz0gZAogICAgcmV0dXJu
IHN0cigoMTAgLSB0b3QgJSAxMCkgJSAxMCkKCmRlZiBfcmFuZF9kaWdpdHMobik6CiAgICByZXR1
cm4gIiIuam9pbihzdHIoc2VjcmV0cy5yYW5kYmVsb3coMTApKSBmb3IgXyBpbiByYW5nZShuKSkK
CmRlZiBzaW1fZ2VuZXJhdGUoY291bnQ9MSwgbXNpc2RuX3N0YXJ0PSIiLCBpY2NpZF9wcmVmaXg9
IiIpOgogICAgbWNjLCBtbmMgPSBDLmdldCgiTUNDIiwgIjAwMSIpLCBDLmdldCgiTU5DIiwgIjAx
IikKICAgIGNvdW50ID0gbWF4KDEsIG1pbig1MCwgaW50KGNvdW50IG9yIDEpKSkKICAgIHVzZWQg
PSBzZXQoc2ltc19sb2FkKCkpIHwgc2V0KG51bXNfbG9hZCgpKQogICAgdGFrZW5fbnIgPSBzZXQo
bnVtc19sb2FkKCkudmFsdWVzKCkpIHwge3MuZ2V0KCJtc2lzZG4iLCAiIikgZm9yIHMgaW4gc2lt
c19sb2FkKCkudmFsdWVzKCl9CiAgICBuciA9IGludChyZS5zdWIociJcRCIsICIiLCBtc2lzZG5f
c3RhcnQgb3IgIiIpIG9yIDApCiAgICBwcmVmID0gcmUuc3ViKHIiXEQiLCAiIiwgaWNjaWRfcHJl
Zml4IG9yICIiKSBvciAoIjg5IiArIG1jYyArIG1uYykKICAgIHByZWYgPSBwcmVmWzoxNl0KICAg
IG91dCA9IFtdCiAgICB3aGlsZSBsZW4ob3V0KSA8IGNvdW50OgogICAgICAgIGltc2kgPSBtY2Mg
KyBtbmMgKyBfcmFuZF9kaWdpdHMoMTUgLSBsZW4obWNjKSAtIGxlbihtbmMpKQogICAgICAgIGlm
IGltc2kgaW4gdXNlZDogY29udGludWUKICAgICAgICB1c2VkLmFkZChpbXNpKQogICAgICAgIGtp
ID0gc2VjcmV0cy50b2tlbl9oZXgoMTYpLnVwcGVyKCk7IG9wID0gc2VjcmV0cy50b2tlbl9oZXgo
MTYpLnVwcGVyKCkKICAgICAgICBib2R5ID0gcHJlZiArIF9yYW5kX2RpZ2l0cygxOCAtIGxlbihw
cmVmKSkKICAgICAgICBtc2lzZG4gPSAiIgogICAgICAgIGlmIG5yOgogICAgICAgICAgICB3aGls
ZSBzdHIobnIpIGluIHRha2VuX25yOiBuciArPSAxCiAgICAgICAgICAgIG1zaXNkbiA9IHN0cihu
cik7IHRha2VuX25yLmFkZChtc2lzZG4pOyBuciArPSAxCiAgICAgICAgb3V0LmFwcGVuZCh7Imlj
Y2lkIjogYm9keSArIGx1aG4oYm9keSksICJpbXNpIjogaW1zaSwgImtpIjoga2ksICJvcCI6IG9w
LAogICAgICAgICAgICAgICAgICAgICJvcGMiOiBtaWxlbmFnZV9vcGMoa2ksIG9wKSwgImFtZiI6
ICI4MDAwIiwgInNxbiI6ICIwMDAwMDAwMDAwMjAiLAogICAgICAgICAgICAgICAgICAgICJtc2lz
ZG4iOiBtc2lzZG4sICJwaW4xIjogIjAwMDAiLCAicHVrMSI6IF9yYW5kX2RpZ2l0cyg4KSwKICAg
ICAgICAgICAgICAgICAgICAicGluMiI6ICIwMDAwIiwgInB1azIiOiBfcmFuZF9kaWdpdHMoOCks
ICJhZG0xIjogX3JhbmRfZGlnaXRzKDgpLAogICAgICAgICAgICAgICAgICAgICJzcG4iOiBDLmdl
dCgiU1BOIikgb3IgQy5nZXQoIk5FVE5BTUUiLCAiIiksICJocGxtbiI6IG1jYyArIG1uY30pCiAg
ICByZXR1cm4gb3V0CgojIC0tLS0gU0lNLURhdGVpZW4gZnVlciBkYXMgZVNJTS1Qcm9maWwgKE9Q
TCAvIFBOTiAvIFNQTikKIyBEaWVzZSBkcmVpIERhdGVpZW4gbGllZ2VuIGF1ZiBkZXIgU0lNLCBu
aWNodCBpbSBOZXR6LiBwS09NIGJlcmVjaG5ldCBkaWUgV2VydGUKIyBwYXNzZW5kIHp1IEtlbm51
bmcgKyBOZXR6bmFtZTsgc2llIHdlcmRlbiBpbSBlU0lNLVByb2ZpbCBlaW5nZXRyYWdlbi4KR1NN
NyA9ICgiQMKjJMKlw6jDqcO5w6zDssOHXG7DmMO4XHLDhcOlzpRfzqbOk86bzqnOoM6ozqPOmM6e
XHgxYsOGw6bDn8OJICFcIiPCpCUmJygpKissLS4vMDEyMzQ1Njc4OTo7PD0+PyIKICAgICAgICAi
wqFBQkNERUZHSElKS0xNTk9QUVJTVFVWV1hZWsOEw5bDkcOcwqfCv2FiY2RlZmdoaWprbG1ub3Bx
cnN0dXZ3eHl6w6TDtsOxw7zDoCIpCgpkZWYgZ3NtN19jb2RlcyhzKToKICAgIHJldHVybiBbR1NN
Ny5pbmRleChjaCkgaWYgY2ggaW4gR1NNNyBhbmQgY2ggbm90IGluICJcblxyXHgxYiIgZWxzZSAw
eDNGIGZvciBjaCBpbiAocyBvciAiIildCgpkZWYgZ3NtN19wYWNrKGNvZGVzKToKICAgIGJpdHMg
PSBuID0gMDsgb3V0ID0gYnl0ZWFycmF5KCkKICAgIGZvciBjIGluIGNvZGVzOgogICAgICAgIGJp
dHMgfD0gKGMgJiAweDdGKSA8PCBuOyBuICs9IDcKICAgICAgICB3aGlsZSBuID49IDg6CiAgICAg
ICAgICAgIG91dC5hcHBlbmQoYml0cyAmIDB4RkYpOyBiaXRzID4+PSA4OyBuIC09IDgKICAgIGlm
IG46IG91dC5hcHBlbmQoYml0cyAmIDB4RkYpCiAgICByZXR1cm4gYnl0ZXMob3V0KSwgKDggLSAo
bGVuKGNvZGVzKSAqIDcpICUgOCkgJSA4CgpkZWYgX25uX2llKHRhZywgbmFtZSk6CiAgICAiIiJO
ZXR6bmFtZS1JRSAoVFMgMjQuMDA4IDEwLjUuMy41YSk6IEdTTS03LCBvaG5lIExhZW5kZXJrdWVy
emVsLiIiIgogICAgcGFja2VkLCBzcGFyZSA9IGdzbTdfcGFjayhnc203X2NvZGVzKG5hbWUpKQog
ICAgYm9keSA9IGJ5dGVzKFsweDgwIHwgc3BhcmVdKSArIHBhY2tlZAogICAgcmV0dXJuIGJ5dGVz
KFt0YWcsIGxlbihib2R5KV0pICsgYm9keQoKZGVmIHBsbW5fYmNkKG1jYywgbW5jKToKICAgIG0z
ID0gbW5jWzJdIGlmIGxlbihtbmMpID09IDMgZWxzZSAiRiIKICAgIHJldHVybiBieXRlcyhbaW50
KG1jY1sxXSArIG1jY1swXSwgMTYpLCBpbnQobTMgKyBtY2NbMl0sIDE2KSwgaW50KG1uY1sxXSAr
IG1uY1swXSwgMTYpXSkKCmRlZiBzaW1fZmlsZXMoKToKICAgIG1jYywgbW5jID0gQy5nZXQoIk1D
QyIsICIiKSwgQy5nZXQoIk1OQyIsICIiKQogICAgZnVsbCA9IEMuZ2V0KCJORVROQU1FIikgb3Ig
InBLT00iOyBzaG9ydCA9IEMuZ2V0KCJORVROQU1FX1NIT1JUIikgb3IgZnVsbAogICAgc3BuID0g
KEMuZ2V0KCJTUE4iKSBvciBmdWxsKVs6MTZdCiAgICB0cnk6IHBsbW4gPSBwbG1uX2JjZChtY2Ms
IG1uYykKICAgIGV4Y2VwdCBFeGNlcHRpb246IHBsbW4gPSBiIlx4ZmZceGZmXHhmZiIKICAgIHNw
bl9iID0gYnl0ZXMoWzB4MDBdKSArIGJ5dGVzKGdzbTdfY29kZXMoc3BuKSkgKyBiIlx4ZmYiICog
KDE2IC0gbGVuKHNwbikpCiAgICBwbm4gPSBfbm5faWUoMHg0MywgZnVsbCkgKyBfbm5faWUoMHg0
NSwgc2hvcnQpCiAgICBvcGwgPSBwbG1uICsgYiJceDAwXHgwMFx4ZmZceGZlXHgwMSIgICAgICAg
ICAgIyBMQUMvVEFDIDAwMDAtRkZGRSAtPiBQTk4tRWludHJhZyAxCiAgICBoeCA9IGxhbWJkYSBi
OiBiLmhleCgpLnVwcGVyKCkKICAgIHJldHVybiB7InNwbiI6IGh4KHNwbl9iKSwgInBubiI6IGh4
KHBubiksICJvcGwiOiBoeChvcGwpLCAicGxtbiI6IGh4KHBsbW4pLAogICAgICAgICAgICAiaHBs
bW4iOiBtY2MgKyBtbmMsICJzcG5fdGV4dCI6IHNwbiwgImZ1bGwiOiBmdWxsLCAic2hvcnQiOiBz
aG9ydH0KCiMgLS0tLSBTTVMgdWViZXIgb3Ntby1tc2MgVlRZCiMgRGllIE1TQyBwdWZmZXJ0IE1U
LVNNUyBpbiBpaHJlciBEQiB1bmQgc3RlbGx0IHNpZSBiZWltIEVpbmJ1Y2hlbiB6dSAtIGRlcgoj
IFRlaWxuZWhtZXIgbXVzcyBiZWltIFNlbmRlbiBhbHNvIG5pY2h0IHp3aW5nZW5kIHNjaG9uIGFu
Z2VtZWxkZXQgc2Vpbi4KIyBBYnNlbmRlciBpc3QgZWluZSBmcmVpZSBOdW1tZXIgKEdTTV9TTVNf
RlJPTSksIGtlaW4gZWNodGVyIFRlaWxuZWhtZXIgbm9ldGlnLgpkZWYgX2V4dGVybl9ucihudW1t
ZXIpOgogICAgIiIiSW50ZXJuZSBOdW1tZXIgLT4gZXh0ZXJuIGVycmVpY2hiYXJlIE51bW1lciAo
Vm9yd2FobC1CbG9jayArIGludGVybmUgTnVtbWVyKS4iIiIKICAgIG51bW1lciA9IHJlLnN1Yihy
IlxEIiwgIiIsIG51bW1lciBvciAiIikKICAgIGlmIG5vdCBudW1tZXI6IHJldHVybiAiIgogICAg
cHJlZiA9IEMuZ2V0KCJHU01fU01TX0VYVFBSRUZJWCIsICIiKS5zdHJpcCgpCiAgICByZXR1cm4g
KHByZWYgKyBudW1tZXIpIGlmIHByZWYgZWxzZSBudW1tZXIKCmRlZiBfc21zX3RleHQodG1wbCwg
bnVtbWVyPSIiKToKICAgIHQgPSAodG1wbCBvciAiIikucmVwbGFjZSgie25ldHp9IiwgQy5nZXQo
Ik5FVE5BTUUiLCAiIikpIFwKICAgICAgICAgICAgICAgICAgICAucmVwbGFjZSgie2V4dGVybn0i
LCBfZXh0ZXJuX25yKG51bW1lcikpLnJlcGxhY2UoIntudW1tZXJ9IiwgbnVtbWVyKQogICAgdCA9
IHJlLnN1YihyJ1tcclxuXHQ/Il0nLCAiICIsIHQpICAgICAgICAgICMgVlRZLVplaWxlOiBrZWlu
ZSBVbWJydWVjaGUvVGFicy8/LUhpbGZlL1F1b3RlcwogICAgcmV0dXJuIHJlLnN1YihyIlxzKyIs
ICIgIiwgdCkuc3RyaXAoKVs6MTYwXQoKZGVmIHNtc19zZW5kKGltc2ksIHRleHQsIGZvcmNlPUZh
bHNlKToKICAgIGltc2kgPSByZS5zdWIociJcRCIsICIiLCBpbXNpIG9yICIiKQogICAgaWYgRkFL
RSBvciBub3QgZ3NtX29uKCkgb3Igbm90IGltc2kgb3Igbm90IHRleHQ6CiAgICAgICAgcmV0dXJu
CiAgICBpZiBDLmdldCgiR1NNX1NNUyIsICIxIikgIT0gIjEiIGFuZCBub3QgZm9yY2U6ICAgIyBB
dXRvLVNNUyBhdXMgKFRlc3QgaWdub3JpZXJ0IGRhcykKICAgICAgICByZXR1cm4KICAgIGZybSA9
IHJlLnN1YihyIlxEIiwgIiIsIEMuZ2V0KCJHU01fU01TX0ZST00iLCAiIikpIG9yICIxMDAwIgog
ICAgciA9IHZ0eShNU0NfVlRZLCBbImVuYWJsZSIsCiAgICAgICAgICAgICAgICAgICAgICBmInN1
YnNjcmliZXIgaW1zaSB7aW1zaX0gc21zIHNlbmRlciBtc2lzZG4ge2ZybX0gc2VuZCB7dGV4dH0i
XSkKICAgIGlmICIlICIgaW4gcjoKICAgICAgICBsb2coInNtcy1mZWhsZXI6IiwgKHIuc3RyaXAo
KS5zcGxpdGxpbmVzKCkgb3IgW3JdKVstMV1bOjE0MF0pCgpkZWYgc21zX3Rlc3QoaW1zaSwgdGV4
dD0iIik6CiAgICBpbXNpID0gcmUuc3ViKHIiXEQiLCAiIiwgaW1zaSBvciAiIikKICAgIGlmIGxl
bihpbXNpKSA8IDE0OiAgcmV0dXJuICJJTVNJIGFuZ2ViZW4gKDE0LTE1IFppZmZlcm4pIgogICAg
aWYgRkFLRTogICAgICAgICAgICByZXR1cm4gIlRlc3Rtb2R1cyAoRkFLRSk6IG5pY2h0cyBnZXNl
bmRldCIKICAgIGlmIG5vdCBnc21fb24oKTogcmV0dXJuICJHU00tTmV0eiBsYWV1ZnQgbmljaHQg
KEdTTSBvZGVyIExURSArIEdTTSBzdGFydGVuKSIKICAgIHR4dCA9IF9zbXNfdGV4dCh0ZXh0KSBp
ZiAodGV4dCBvciAiIikuc3RyaXAoKSBlbHNlIF9zbXNfdGV4dChDLmdldCgiR1NNX1NNU19XRUxD
T01FIiwgIiIpKQogICAgc21zX3NlbmQoaW1zaSwgdHh0LCBmb3JjZT1UcnVlKQogICAgcmV0dXJu
IGYiVGVzdC1TTVMgYW4ge2ltc2l9IGdlc2VuZGV0IgoKZGVmIG1zY19hdHRhY2hlZCgpOgogICAg
IiIiSU1TSXMsIGRpZSBha3R1ZWxsIGluIGRlciBNU0MgKFZMUikgZWluZ2VidWNodCBzaW5kLiIi
IgogICAgaWYgRkFLRSBvciBub3QgZ3NtX29uKCk6CiAgICAgICAgcmV0dXJuIHNldCgpCiAgICB0
eHQgPSB2dHkoTVNDX1ZUWSwgWyJlbmFibGUiLCAic2hvdyBzdWJzY3JpYmVyIGNhY2hlIl0pCiAg
ICByZXR1cm4gc2V0KHJlLmZpbmRhbGwociJJTVNJXER7MCwzfShcZHsxNCwxNX0pIiwgdHh0KSkK
CmRlZiBzbXNfd2VsY29tZV93YXRjaCgpOgogICAgIiIiSGludGVyZ3J1bmQ6IG5ldWUgRWluYnVj
aHVuZ2VuIGVya2VubmVuIHVuZCBlaW5tYWxpZyBiZWdydWVzc2VuLiIiIgogICAgd2hpbGUgVHJ1
ZToKICAgICAgICB0cnk6CiAgICAgICAgICAgIGlmIGdzbV9vbigpIGFuZCBORVQuc3RhdGUgPT0g
ImxhZXVmdCIgYW5kIEMuZ2V0KCJHU01fU01TIiwgIjEiKSA9PSAiMSI6CiAgICAgICAgICAgICAg
ICBmb3IgaW1zaSBpbiBtc2NfYXR0YWNoZWQoKSAtIE5FVC53ZWxjb21lZDoKICAgICAgICAgICAg
ICAgICAgICBORVQud2VsY29tZWQuYWRkKGltc2kpICAgICAgIyB2b3IgZGVtIFNlbmRlbiBtZXJr
ZW46IGtlaW4gU3BhbSBiZWkgRmVobGVyCiAgICAgICAgICAgICAgICAgICAgbG9nKCJ3aWxsa29t
bWVucy1zbXMgLT4iLCBpbXNpKQogICAgICAgICAgICAgICAgICAgIHNtc19zZW5kKGltc2ksIF9z
bXNfdGV4dChDLmdldCgiR1NNX1NNU19XRUxDT01FIiwgIiIpKSkKICAgICAgICBleGNlcHQgRXhj
ZXB0aW9uIGFzIGU6CiAgICAgICAgICAgIGxvZygic21zLXdhdGNoOiIsIGUpCiAgICAgICAgdGlt
ZS5zbGVlcCg2KQoKIyA9PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
PT09PT09PT09PT09PT09PT09PT09PT0gTFRFOiBzcnNFTkIgKEZ1bmspICsgT3BlbjVHUyAoS2Vy
bikKIyBPcGVuNUdTIHN0YXR0IHNyc0VQQywgd2VpbCBudXIgZGVzc2VuIE1NRSBkaWUgU0dzLVNj
aG5pdHRzdGVsbGUgenVyIG9zbW8tbXNjCiMgaGF0IChDU0ZCKS4gRGllIE9wZW41R1MtRGllbnN0
ZSBsYXVmZW4gbmljaHQgdWViZXIgc3lzdGVtZCwgc29uZGVybiB3ZXJkZW4gdm9uCiMgcEtPTSBt
aXQgZWlnZW5lbiBLb25maWdzIGdlc3RhcnRldCAoVm9ybGFnZTogL2V0Yy9vcGVuNWdzLyoueWFt
bCkuCk81X0VUQyA9ICIvZXRjL29wZW41Z3MiCk81X0RJUiA9IG9zLnBhdGguam9pbihXT1JLRElS
LCAib3BlbjVncyIpCk81X05GUyA9IFsoIm5yZiIsICJvcGVuNWdzLW5yZmQiKSwgKCJzY3AiLCAi
b3BlbjVncy1zY3BkIiksICgiaHNzIiwgIm9wZW41Z3MtaHNzZCIpLAogICAgICAgICAgKCJwY3Jm
IiwgIm9wZW41Z3MtcGNyZmQiKSwgKCJzZ3djIiwgIm9wZW41Z3Mtc2d3Y2QiKSwgKCJzZ3d1Iiwg
Im9wZW41Z3Mtc2d3dWQiKSwKICAgICAgICAgICgic21mIiwgIm9wZW41Z3Mtc21mZCIpLCAoInVw
ZiIsICJvcGVuNWdzLXVwZmQiKSwgKCJtbWUiLCAib3BlbjVncy1tbWVkIildCk81X09QVElPTkFM
ID0geyJucmYiLCAic2NwIn0KVUVfTkVULCBVRV9HVyA9ICIxMC40NS4wLjAvMTYiLCAiMTAuNDUu
MC4xLzE2IiAgICAgICAjIE9wZW41R1MtU3RhbmRhcmQgKHNtZi91cGYueWFtbCkKTlBSQl9NSFog
PSB7NjogMS40LCAxNTogMywgMjU6IDUsIDUwOiAxMCwgNzU6IDE1LCAxMDA6IDIwfQpTR1NfUE9S
VCA9IDI5MTE4CgpkZWYgX3BsbW5fd2FsayhvLCBtY2MsIG1uYyk6CiAgICAiIiJKZWRlIFBMTU4t
QW5nYWJlIChtY2MvbW5jKSBpbiBlaW5lciBPcGVuNUdTLUtvbmZpZyBhdWYgZGllIGVpZ2VuZSBL
ZW5udW5nIHNldHplbi4iIiIKICAgIGlmIGlzaW5zdGFuY2UobywgZGljdCk6CiAgICAgICAgaWYg
Im1jYyIgaW4gbyBhbmQgIm1uYyIgaW4gbzoKICAgICAgICAgICAgb1sibWNjIl0gPSBtY2M7IG9b
Im1uYyJdID0gbW5jICAgICAgIyBhbHMgVGV4dDogZnVlaHJlbmRlIE51bGxlbiArIE1OQy1MYWVu
Z2UgYmxlaWJlbgogICAgICAgIGZvciB2IGluIG8udmFsdWVzKCk6IF9wbG1uX3dhbGsodiwgbWNj
LCBtbmMpCiAgICBlbGlmIGlzaW5zdGFuY2UobywgbGlzdCk6CiAgICAgICAgZm9yIHYgaW4gbzog
X3BsbW5fd2Fsayh2LCBtY2MsIG1uYykKCmRlZiBnc21fbGFjKCk6CiAgICB0cnk6CiAgICAgICAg
dCA9IG9wZW4ob3MucGF0aC5qb2luKFdPUktESVIsICJvc21vLWJzYy5jZmciKSkucmVhZCgpCiAg
ICAgICAgbSA9IHJlLnNlYXJjaChyIig/bSleXHMqbG9jYXRpb25fYXJlYV9jb2RlXHMrKD86bGFj
XHMrKT8oMHhbMC05YS1mQS1GXSt8XGQrKSIsIHQpCiAgICAgICAgaWYgbTogcmV0dXJuIGludCht
Lmdyb3VwKDEpLCAwKQogICAgZXhjZXB0IEV4Y2VwdGlvbjogcGFzcwogICAgcmV0dXJuIDEKCmRl
ZiBvNV9wcmVwYXJlKGNzZmIsIGV0Yz1PNV9FVEMsIG91dGRpcj1PNV9ESVIpOgogICAgIiIiT3Bl
bjVHUy1Lb25maWdzIGVyemV1Z2VuLiBSdWVja2dhYmU6IHtuZjogKGJpbmFyeSwgeWFtbC1wZmFk
KX0gaW4gU3RhcnRyZWloZW5mb2xnZS4iIiIKICAgIGltcG9ydCB5YW1sCiAgICBvcy5tYWtlZGly
cyhvdXRkaXIsIGV4aXN0X29rPVRydWUpCiAgICBtY2MsIG1uYyA9IENbIk1DQyJdLCBDWyJNTkMi
XTsgdGFjID0gaW50KEMuZ2V0KCJMVEVfVEFDIikgb3IgNykKICAgIHBsbW4gPSB7Im1jYyI6IG1j
YywgIm1uYyI6IG1uY30KICAgIG91dCA9IHt9CiAgICBmb3IgbmYsIGJpbmFyeSBpbiBPNV9ORlM6
CiAgICAgICAgc3JjID0gb3MucGF0aC5qb2luKGV0YywgbmYgKyAiLnlhbWwiKQogICAgICAgIGlm
IG5vdCBvcy5wYXRoLmlzZmlsZShzcmMpOgogICAgICAgICAgICBpZiBuZiBpbiBPNV9PUFRJT05B
TDogY29udGludWUKICAgICAgICAgICAgcmFpc2UgUnVudGltZUVycm9yKGYie3NyY30gZmVobHQg
LSBpc3QgT3BlbjVHUyBpbnN0YWxsaWVydD8iKQogICAgICAgIG8gPSB5YW1sLnNhZmVfbG9hZChv
cGVuKHNyYykpIG9yIHt9CiAgICAgICAgby5wb3AoImxvZ2dlciIsIE5vbmUpICAgICAgICAgICAg
ICAgICAgICAgICAjIExvZyBuYWNoIHN0ZG91dCAtPiBQcm90b2tvbGwtVGFiCiAgICAgICAgX3Bs
bW5fd2FsayhvLCBtY2MsIG1uYykKICAgICAgICBpZiBuZiA9PSAibW1lIjoKICAgICAgICAgICAg
bSA9IG8uc2V0ZGVmYXVsdCgibW1lIiwge30pCiAgICAgICAgICAgIGlmIEMuZ2V0KCJOSVRaIiwg
IjEiKSA9PSAiMSI6ICAgICAgICAgICAjIEVNTS1JbmZvcm1hdGlvbjogTmV0em5hbWUgKyBaZWl0
L1plaXR6b25lCiAgICAgICAgICAgICAgICBtWyJuZXR3b3JrX25hbWUiXSA9IHsiZnVsbCI6IENb
Ik5FVE5BTUUiXSwgInNob3J0IjogQy5nZXQoIk5FVE5BTUVfU0hPUlQiKSBvciBDWyJORVROQU1F
Il19CiAgICAgICAgICAgIGVsc2U6CiAgICAgICAgICAgICAgICBtLnBvcCgibmV0d29ya19uYW1l
IiwgTm9uZSkKICAgICAgICAgICAgdGFpID0gbS5nZXQoInRhaSIpCiAgICAgICAgICAgIHRhaXMg
PSB0YWkgaWYgaXNpbnN0YW5jZSh0YWksIGxpc3QpIGVsc2UgKFt0YWldIGlmIGlzaW5zdGFuY2Uo
dGFpLCBkaWN0KSBlbHNlIFtdKQogICAgICAgICAgICBmb3IgdCBpbiB0YWlzOiB0WyJ0YWMiXSA9
IHRhYwogICAgICAgICAgICBpZiBub3QgdGFpczogbVsidGFpIl0gPSBbeyJwbG1uX2lkIjogZGlj
dChwbG1uKSwgInRhYyI6IHRhY31dCiAgICAgICAgICAgIG5ld19mbXQgPSBpc2luc3RhbmNlKG0u
Z2V0KCJzMWFwIiksIGRpY3QpICAgIyBPcGVuNUdTID49IDIuNwogICAgICAgICAgICBvLnBvcCgi
c2dzYXAiLCBOb25lKTsgbS5wb3AoInNnc2FwIiwgTm9uZSkKICAgICAgICAgICAgaWYgY3NmYjoK
ICAgICAgICAgICAgICAgIG1wID0geyJ0YWkiOiB7InBsbW5faWQiOiBkaWN0KHBsbW4pLCAidGFj
IjogdGFjfSwKICAgICAgICAgICAgICAgICAgICAgICJsYWkiOiB7InBsbW5faWQiOiBkaWN0KHBs
bW4pLCAibGFjIjogZ3NtX2xhYygpfX0KICAgICAgICAgICAgICAgIGlmIG5ld19mbXQ6CiAgICAg
ICAgICAgICAgICAgICAgbVsic2dzYXAiXSA9IHsiY2xpZW50IjogW3siYWRkcmVzcyI6ICIxMjcu
MC4wLjEiLCAibG9jYWxfYWRkcmVzcyI6ICIxMjcuMC4wLjIiLAogICAgICAgICAgICAgICAgICAg
ICAgICAgICAgICAgICAgICAgICAgICAgICAgInBvcnQiOiBTR1NfUE9SVCwgIm1hcCI6IG1wfV19
CiAgICAgICAgICAgICAgICBlbHNlOgogICAgICAgICAgICAgICAgICAgIG9bInNnc2FwIl0gPSBb
eyJhZGRyIjogIjEyNy4wLjAuMSIsICJwb3J0IjogU0dTX1BPUlQsICJtYXAiOiBtcH1dCiAgICAg
ICAgZHN0ID0gb3MucGF0aC5qb2luKG91dGRpciwgbmYgKyAiLnlhbWwiKQogICAgICAgIHdpdGgg
b3Blbihkc3QsICJ3IikgYXMgZjoKICAgICAgICAgICAgeWFtbC5zYWZlX2R1bXAobywgZiwgZGVm
YXVsdF9mbG93X3N0eWxlPUZhbHNlLCBzb3J0X2tleXM9RmFsc2UsIGFsbG93X3VuaWNvZGU9VHJ1
ZSkKICAgICAgICBvdXRbbmZdID0gKGJpbmFyeSwgZHN0KQogICAgcmV0dXJuIG91dAoKZGVmIF9z
cnNfdGVtcGxhdGUobmFtZSk6CiAgICBmb3IgcCBpbiAob3MucGF0aC5qb2luKFNSU19DRkcsIG5h
bWUpLCBmIi91c3Ivc2hhcmUvc3JzcmFuL3tuYW1lfS5leGFtcGxlIiwKICAgICAgICAgICAgICBm
Ii91c3Ivc2hhcmUvc3JzcmFuL3tuYW1lfSIsIGYiL3Vzci9zaGFyZS9kb2Mvc3JzcmFuL2V4YW1w
bGVzL3tuYW1lfS5leGFtcGxlIik6CiAgICAgICAgaWYgb3MucGF0aC5pc2ZpbGUocCk6IHJldHVy
biBwCiAgICByZXR1cm4gTm9uZQoKZGVmIF9kcm9wX2Jsb2NrKHQsIG5hbWUpOgogICAgIiIibGli
Y29uZmlnLUJsb2NrICduYW1lID0geyAuLi4gfTsnIGVudGZlcm5lbiAoS2xhbW1lcm4gZ2V6YWVo
bHQpLiIiIgogICAgbSA9IHJlLnNlYXJjaChyZiIoP20pXntuYW1lfVxzKj1ccypce3siLCB0KQog
ICAgaWYgbm90IG06IHJldHVybiB0CiAgICBpID0gdC5pbmRleCgieyIsIG0uc3RhcnQoKSk7IGRl
cHRoID0gMAogICAgZm9yIGogaW4gcmFuZ2UoaSwgbGVuKHQpKToKICAgICAgICBpZiB0W2pdID09
ICJ7IjogZGVwdGggKz0gMQogICAgICAgIGVsaWYgdFtqXSA9PSAifSI6CiAgICAgICAgICAgIGRl
cHRoIC09IDEKICAgICAgICAgICAgaWYgZGVwdGggPT0gMDoKICAgICAgICAgICAgICAgIGsgPSBq
ICsgMQogICAgICAgICAgICAgICAgd2hpbGUgayA8IGxlbih0KSBhbmQgdFtrXSBpbiAiIFx0OyI6
IGsgKz0gMQogICAgICAgICAgICAgICAgcmV0dXJuIHRbOm0uc3RhcnQoKV0gKyB0W2s6XQogICAg
cmV0dXJuIHQKCmRlZiBfc2lfbWFwcGluZyh0LCBhZGQ3KToKICAgIGRlZiBmKG0pOgogICAgICAg
IG51bXMgPSBbeC5zdHJpcCgpIGZvciB4IGluIG0uZ3JvdXAoMikuc3BsaXQoIiwiKSBpZiB4LnN0
cmlwKCkgYW5kIHguc3RyaXAoKSAhPSAiNyJdCiAgICAgICAgaWYgYWRkNzogbnVtcy5hcHBlbmQo
IjciKQogICAgICAgIHJldHVybiBtLmdyb3VwKDEpICsgIiwgIi5qb2luKG51bXMpICsgbS5ncm91
cCgzKQogICAgcmV0dXJuIHJlLnN1YihyIihzaV9tYXBwaW5nX2luZm9ccyo9XHMqXFtccyopKFte
XF1dKj8pKFxzKlxdKSIsIGYsIHQsIGNvdW50PTEpCgpkZWYgc2liX3BhdGNoKHQsIGNzZmIsIGFy
ZmNuKToKICAgICIiIlNJQjcgKEdFUkFOLU5hY2hiYXIpIG51ciBpbSBDU0ZCLU1vZHVzOiBzcnNF
TkIgc2NoaWNrdCBkYXMgSGFuZHkgYmVpCiAgICBlaW5lbSBBbnJ1ZiBwZXIgUlJDLVJlbGVhc2Ug
bWl0IFVtbGVpdHVuZyBhdWYgZ2VuYXUgZGllc2UgR1NNLUZyZXF1ZW56LiIiIgogICAgdCA9IF9k
cm9wX2Jsb2NrKHQsICJzaWI3IikKICAgIHQgPSBfc2lfbWFwcGluZyh0LCBjc2ZiKQogICAgaWYg
Y3NmYjoKICAgICAgICB0ID0gdC5yc3RyaXAoKSArIGYiIiIKCi8vIHBLT006IEdTTS1aZWxsZSBm
dWVyIENTLUZhbGxiYWNrIChBbnJ1ZmUpCnNpYjcgPQp7ewogICAgdF9yZXNlbF9nZXJhbiA9IDE7
CiAgICBjYXJyaWVyX2ZyZXFzX2luZm9fbGlzdCA9CiAgICAoCiAgICAgICAge3sKICAgICAgICAg
ICAgY2VsbF9yZXNlbF9wcmlvID0gMDsKICAgICAgICAgICAgbmNjX3Blcm1pdHRlZCA9IDI1NTsK
ICAgICAgICAgICAgcV9yeF9sZXZfbWluID0gMDsKICAgICAgICAgICAgdGhyZXNoX3hfaGlnaCA9
IDI7CiAgICAgICAgICAgIHRocmVzaF94X2xvdyA9IDI7CiAgICAgICAgICAgIHN0YXJ0X2FyZmNu
ID0ge2FyZmNufTsKICAgICAgICAgICAgYmFuZF9pbmQgPSAiZGNzMTgwMCI7CiAgICAgICAgICAg
IGV4cGxpY2l0X2xpc3Rfb2ZfYXJmY25zID0gKCB7YXJmY259ICk7CiAgICAgICAgfX0KICAgICk7
Cn19OwoiIiIKICAgIHJldHVybiB0CgpkZWYgZW5iX3ByZXBhcmUoY3NmYiwgc2VyaWFsKToKICAg
IGZvciBmIGluICgicnIuY29uZiIsICJzaWIuY29uZiIsICJyYi5jb25mIik6CiAgICAgICAgcCA9
IF9zcnNfdGVtcGxhdGUoZikKICAgICAgICBpZiBub3QgcDogcmFpc2UgUnVudGltZUVycm9yKGYi
c3JzUkFOLVZvcmxhZ2Uge2Z9IGZlaGx0IC0gaXN0IHNyc3JhbiBpbnN0YWxsaWVydD8iKQogICAg
ICAgIHNodXRpbC5jb3B5KHAsIG9zLnBhdGguam9pbihXT1JLRElSLCBmKSkKICAgIGVhcmZjbiA9
IGludChDWyJMVEVfRUFSRkNOIl0pOyB0YWMgPSBpbnQoQy5nZXQoIkxURV9UQUMiKSBvciA3KQog
ICAgcnIgPSBvcy5wYXRoLmpvaW4oV09SS0RJUiwgInJyLmNvbmYiKTsgdCA9IG9wZW4ocnIpLnJl
YWQoKQogICAgdCA9IHJlLnN1YihyIig/bSleKFxzKnRhY1xzKj1ccyopW147XSs7IiwgciJcZzwx
PjB4JTA0WDsiICUgdGFjLCB0LCBjb3VudD0xKQogICAgdCA9IHJlLnN1YihyIig/bSleKFxzKmRs
X2VhcmZjblxzKj1ccyopXGQrOyIsIHIiXGc8MT4lZDsiICUgZWFyZmNuLCB0LCBjb3VudD0xKSAg
IyAxLiA9IGVpZ2VuZSBaZWxsZQogICAgb3BlbihyciwgInciKS53cml0ZSh0KQogICAgc2liID0g
b3MucGF0aC5qb2luKFdPUktESVIsICJzaWIuY29uZiIpCiAgICBvcGVuKHNpYiwgInciKS53cml0
ZShzaWJfcGF0Y2gob3BlbihzaWIpLnJlYWQoKSwgY3NmYiwgaW50KENbIkdTTV9BUkZDTiJdKSkp
CiAgICBkZXYgPSAiZHJpdmVyPWxpbWUiICsgKCIsc2VyaWFsPSIgKyBzZXJpYWwgaWYgc2VyaWFs
IGVsc2UgIiIpCiAgICBvcGVuKG9zLnBhdGguam9pbihXT1JLRElSLCAiZW5iLmNvbmYiKSwgInci
KS53cml0ZShmIiIiIyBwS09NIC0gYXV0b21hdGlzY2ggZXJ6ZXVndApbZW5iXQplbmJfaWQgPSAw
eDE5QgptY2MgPSB7Q1snTUNDJ119Cm1uYyA9IHtDWydNTkMnXX0KbW1lX2FkZHIgPSAxMjcuMC4w
LjIKZ3RwX2JpbmRfYWRkciA9IDEyNy4wLjEuMQpzMWNfYmluZF9hZGRyID0gMTI3LjAuMS4xCnMx
Y19iaW5kX3BvcnQgPSAwCm5fcHJiID0ge2ludChDWydMVEVfTlBSQiddKX0KCltlbmJfZmlsZXNd
CnNpYl9jb25maWcgPSB7c2lifQpycl9jb25maWcgPSB7cnJ9CnJiX2NvbmZpZyA9IHtvcy5wYXRo
LmpvaW4oV09SS0RJUiwgJ3JiLmNvbmYnKX0KCltyZl0KdHhfZ2FpbiA9IHtDWydMVEVfVFhfR0FJ
TiddfQpyeF9nYWluID0ge0NbJ0xURV9SWF9HQUlOJ119CmRldmljZV9uYW1lID0gc29hcHkKZGV2
aWNlX2FyZ3MgPSB7ZGV2fQoKW2xvZ10KYWxsX2xldmVsID0gd2FybmluZwpmaWxlbmFtZSA9IHN0
ZG91dAoiIiIpCgpkZWYgX3J1bigqY21kKToKICAgIHJldHVybiBzdWJwcm9jZXNzLnJ1bihsaXN0
KGNtZCksIHN0ZG91dD1zdWJwcm9jZXNzLkRFVk5VTEwsIHN0ZGVycj1zdWJwcm9jZXNzLkRFVk5V
TEwpLnJldHVybmNvZGUKCmRlZiB1ZV9uZXRfdXAoKToKICAgICIiIlR1bm5lbCBmdWVyIGRpZSBI
YW5keS1EYXRlbnZlcmJpbmR1bmdlbiArIE5BVCBpbnMgSW50ZXJuZXQuIiIiCiAgICBfcnVuKCJt
b2Rwcm9iZSIsICJzY3RwIikKICAgIF9ydW4oImlwIiwgInR1bnRhcCIsICJhZGQiLCAibmFtZSIs
ICJvZ3N0dW4iLCAibW9kZSIsICJ0dW4iKQogICAgX3J1bigiaXAiLCAiYWRkciIsICJyZXBsYWNl
IiwgVUVfR1csICJkZXYiLCAib2dzdHVuIikKICAgIF9ydW4oImlwIiwgImxpbmsiLCAic2V0Iiwg
Im9nc3R1biIsICJ1cCIpCiAgICBfcnVuKCJzeXNjdGwiLCAiLXciLCAibmV0LmlwdjQuaXBfZm9y
d2FyZD0xIikKICAgIGZvciBjaGssIGFkZCBpbiAoKFsiLXQiLCAibmF0IiwgIi1DIiwgIlBPU1RS
T1VUSU5HIiwgIi1zIiwgVUVfTkVULCAiISIsICItbyIsICJvZ3N0dW4iLCAiLWoiLCAiTUFTUVVF
UkFERSJdLAogICAgICAgICAgICAgICAgICAgICAgWyItdCIsICJuYXQiLCAiLUEiLCAiUE9TVFJP
VVRJTkciLCAiLXMiLCBVRV9ORVQsICIhIiwgIi1vIiwgIm9nc3R1biIsICItaiIsICJNQVNRVUVS
QURFIl0pLAogICAgICAgICAgICAgICAgICAgICAoWyItQyIsICJGT1JXQVJEIiwgIi1pIiwgIm9n
c3R1biIsICItaiIsICJBQ0NFUFQiXSwgWyItSSIsICJGT1JXQVJEIiwgIi1pIiwgIm9nc3R1biIs
ICItaiIsICJBQ0NFUFQiXSksCiAgICAgICAgICAgICAgICAgICAgIChbIi1DIiwgIkZPUldBUkQi
LCAiLW8iLCAib2dzdHVuIiwgIi1qIiwgIkFDQ0VQVCJdLCBbIi1JIiwgIkZPUldBUkQiLCAiLW8i
LCAib2dzdHVuIiwgIi1qIiwgIkFDQ0VQVCJdKSk6CiAgICAgICAgaWYgX3J1bigiaXB0YWJsZXMi
LCAqY2hrKSAhPSAwOiBfcnVuKCJpcHRhYmxlcyIsICphZGQpCgpkZWYgZnJlcV9jbGFzaCgpOgog
ICAgIiIiR1NNLVRyYWVnZXIgZGFyZiBuaWNodCBpbSBMVEUtS2FuYWwgbGllZ2VuIChnbGVpY2hl
cyBCYW5kIDE4MDAgTUh6KS4iIiIKICAgIHRyeToKICAgICAgICBnID0gYXJmY25fbWh6KGludChD
WyJHU01fQVJGQ04iXSkpOyBsID0gZWFyZmNuX21oeihpbnQoQ1siTFRFX0VBUkZDTiJdKSkKICAg
ICAgICBidyA9IE5QUkJfTUhaLmdldChpbnQoQ1siTFRFX05QUkIiXSksIDUpCiAgICAgICAgaWYg
ZyBhbmQgbCBhbmQgYWJzKGcgLSBsKSA8IGJ3IC8gMiArIDAuMzoKICAgICAgICAgICAgcmV0dXJu
IGYiR1NNIHtnfSBNSHogbGllZ3QgaW0gTFRFLUthbmFsIHtsfSBNSHogwrF7YncvMjpnfSAtIGFu
ZGVyZSBBUkZDTi9FQVJGQ04gd2FlaGxlbiIKICAgIGV4Y2VwdCBFeGNlcHRpb246IHBhc3MKICAg
IHJldHVybiBOb25lCgpkZWYgcHJlZmxpZ2h0KG1vZGUpOgogICAgbWNjLCBtbmMgPSBDLmdldCgi
TUNDIiwgIiIpLnN0cmlwKCksIEMuZ2V0KCJNTkMiLCAiIikuc3RyaXAoKQogICAgaWYgbm90IHJl
LmZ1bGxtYXRjaChyIlxkezN9IiwgbWNjKSBvciBub3QgcmUuZnVsbG1hdGNoKHIiXGR7MiwzfSIs
IG1uYyk6CiAgICAgICAgcmV0dXJuICJOZXR6a2VubnVuZyBwcnVlZmVuOiBNQ0MgMyBaaWZmZXJu
LCBNTkMgMi0zIFppZmZlcm4iCiAgICBpZiBtY2Mgbm90IGluICgiMDAxIiwgIjk5OSIpOgogICAg
ICAgIHJldHVybiAiTnVyIFRlc3QtL1ByaXZhdGtlbm51bmdlbjogTUNDIDAwMSAoVGVzdCkgb2Rl
ciA5OTkgKHByaXZhdCkiCiAgICBnLCBsID0gbGltZV9hc3NpZ24obW9kZSkKICAgIGlmIG1vZGUg
PT0gImNzZmIiOgogICAgICAgIGlmIG5vdCBGQUtFIGFuZCAobm90IGcgb3Igbm90IGwgb3IgZyA9
PSBsKToKICAgICAgICAgICAgcmV0dXJuICJMVEUgKyBHU00gYnJhdWNodCB6d2VpIHZlcnNjaGll
ZGVuZSBMaW1lU0RSIC0gaW0gVGFiIFN0ZXVlcnVuZyB6dW9yZG5lbiIKICAgICAgICBlID0gZnJl
cV9jbGFzaCgpCiAgICAgICAgaWYgZTogcmV0dXJuIGUKICAgIGlmIG5vdCBGQUtFOgogICAgICAg
IG5lZWQgPSBbXQogICAgICAgIGlmIG1vZGUgaW4gKCJnc20iLCAiY3NmYiIpOiBuZWVkICs9IFti
IGZvciBfbiwgYiwgX2MgaW4gR1NNX0NPUkVdCiAgICAgICAgaWYgbW9kZSBpbiAoImx0ZSIsICJj
c2ZiIik6CiAgICAgICAgICAgIG5lZWQgKz0gWyJzcnNlbmIiXSArIFtiIGZvciBuZiwgYiBpbiBP
NV9ORlMgaWYgbmYgbm90IGluIE81X09QVElPTkFMXQogICAgICAgICAgICB0cnk6IGltcG9ydCB5
YW1sICAjIG5vcWEKICAgICAgICAgICAgZXhjZXB0IEltcG9ydEVycm9yOiByZXR1cm4gInB5dGhv
bjMteWFtbCBmZWhsdCAoSW5zdGFsbGVyIGVybmV1dCBhdXNmdWVocmVuKSIKICAgICAgICBtaXNz
ID0gW2IgZm9yIGIgaW4gbmVlZCBpZiBub3Qgc2h1dGlsLndoaWNoKGIpXQogICAgICAgIGlmIG1p
c3M6IHJldHVybiAiRmVobHQ6ICIgKyAiLCAiLmpvaW4obWlzcykgKyAiIChJbnN0YWxsZXIgZXJu
ZXV0IGF1c2Z1ZWhyZW4pIgogICAgICAgIGlmIG1vZGUgPT0gImNzZmIiIGFuZCBvc21vX2hhcygi
b3Ntby1tc2MiLCAic2dzIikgaXMgRmFsc2U6CiAgICAgICAgICAgIHJldHVybiAiRGllc2Ugb3Nt
by1tc2Mga2FubiBrZWluIFNHcyAoQ1NGQikgLSBuZXVlcmUgT3Ntb2NvbS1WZXJzaW9uIG5vZXRp
ZyIKICAgIE5FVC5kZXZfZ3NtLCBORVQuZGV2X2x0ZSA9IGcsIGwKICAgIHJldHVybiBOb25lCgoj
ID09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
PT09PT09PT09PSBOZXR6LU1hbmFnZXIKTU9ERVMgPSB7ImdzbSI6ICJHU00gKDJHKSIsICJsdGUi
OiAiTFRFICg0RykiLCAiY3NmYiI6ICJMVEUgKyBHU00gKENTRkIpIn0KCmNsYXNzIE5ldDoKICAg
IGRlZiBfX2luaXRfXyhzZWxmKToKICAgICAgICBzZWxmLmxvY2sgPSB0aHJlYWRpbmcuUkxvY2so
KQogICAgICAgIHNlbGYudGVjaCA9IE5vbmUgICAgICAgICAgIyBOb25lIHwgImdzbSIgfCAibHRl
IiB8ICJjc2ZiIgogICAgICAgIHNlbGYuc3RhdGUgPSAiYXVzIiAgICAgICAgIyBhdXMgfCBzdGFy
dGV0IHwgbGFldWZ0IHwgZmVobGVyCiAgICAgICAgc2VsZi5tc2cgPSAiIgogICAgICAgIHNlbGYu
cHJvY3MgPSB7fQogICAgICAgIHNlbGYubG9nbGluZXMgPSBbXQogICAgICAgIHNlbGYuc3RhcnRl
ZCA9IDAuMAogICAgICAgIHNlbGYud2VsY29tZWQgPSBzZXQoKSAgICAgIyBJTVNJcywgZGllIGlu
IGRpZXNlciBOZXR6LVNlc3Npb24gc2Nob24gYmVncnVlc3N0IHd1cmRlbgogICAgICAgIHNlbGYu
ZGV2X2dzbSA9IHNlbGYuZGV2X2x0ZSA9ICIiCgogICAgZGVmIF9sb2coc2VsZiwgdGFnLCBsaW5l
KToKICAgICAgICBsaW5lID0gbGluZS5yc3RyaXAoKQogICAgICAgIGlmIG5vdCBsaW5lOiByZXR1
cm4KICAgICAgICBwcmludChmInt0YWd9OiB7bGluZX0iLCBmbHVzaD1UcnVlKSAgICMgLT4gam91
cm5hbGQsIGRhbWl0ICdqb3VybmFsY3RsIC11IGc5MG5ldCcgYWxsZXMgemVpZ3QKICAgICAgICBz
ZWxmLmxvZ2xpbmVzLmFwcGVuZChmInt0YWd9OiB7bGluZX0iKQogICAgICAgIGlmIGxlbihzZWxm
LmxvZ2xpbmVzKSA+IDYwMDogc2VsZi5sb2dsaW5lcyA9IHNlbGYubG9nbGluZXNbLTYwMDpdCiAg
ICAgICAgbG93ID0gbGluZS5sb3dlcigpCiAgICAgICAgaWYgKCJmYXRhbCIgaW4gbG93IG9yICJm
YWlsZWQgdG8gY3JlYXRlIHJhZGlvIiBpbiBsb3cpIGFuZCB0YWcgbm90IGluIEdTTV9OT05GQVRB
TDoKICAgICAgICAgICAgc2VsZi5tc2cgPSBmInt0YWd9OiB7bGluZVs6MTIwXX0iCgogICAgZGVm
IF9yZWFkZXIoc2VsZiwgcCwgdGFnKToKICAgICAgICB0cnk6CiAgICAgICAgICAgIGZvciByYXcg
aW4gaXRlcihwLnN0ZG91dC5yZWFkbGluZSwgIiIpOgogICAgICAgICAgICAgICAgc2VsZi5fbG9n
KHRhZywgcmF3KQogICAgICAgIGV4Y2VwdCBFeGNlcHRpb246CiAgICAgICAgICAgIHBhc3MKICAg
ICAgICByYyA9IHAucG9sbCgpCiAgICAgICAgaWYgc2VsZi5wcm9jcy5nZXQodGFnKSBpcyBwIGFu
ZCBzZWxmLnN0YXRlID09ICJsYWV1ZnQiIGFuZCB0YWcgbm90IGluIEdTTV9OT05GQVRBTDoKICAg
ICAgICAgICAgc2VsZi5tc2cgPSBmInt0YWd9IGJlZW5kZXQgKENvZGUge3JjfSkgLSBzaWVoZSBQ
cm90b2tvbGwiCgogICAgZGVmIF9zcGF3bihzZWxmLCBiaW5hcnksIGFyZ3MsIHRhZyk6CiAgICAg
ICAgcCA9IHN1YnByb2Nlc3MuUG9wZW4oW2JpbmFyeV0gKyBhcmdzLCBzdGRvdXQ9c3VicHJvY2Vz
cy5QSVBFLAogICAgICAgICAgICAgICAgICAgICAgICAgICAgIHN0ZGVycj1zdWJwcm9jZXNzLlNU
RE9VVCwgdGV4dD1UcnVlLCBidWZzaXplPTEpCiAgICAgICAgc2VsZi5wcm9jc1t0YWddID0gcAog
ICAgICAgIHRocmVhZGluZy5UaHJlYWQodGFyZ2V0PXNlbGYuX3JlYWRlciwgYXJncz0ocCwgdGFn
KSwgZGFlbW9uPVRydWUpLnN0YXJ0KCkKICAgICAgICByZXR1cm4gcAoKICAgIGRlZiBzdG9wKHNl
bGYpOgogICAgICAgIHdpdGggc2VsZi5sb2NrOgogICAgICAgICAgICBpZiBGQUtFOgogICAgICAg
ICAgICAgICAgc2VsZi50ZWNoID0gTm9uZTsgc2VsZi5zdGF0ZSA9ICJhdXMiOyBzZWxmLnByb2Nz
ID0ge307IHJldHVybgogICAgICAgICAgICBwcm9jcywgc2VsZi5wcm9jcyA9IHNlbGYucHJvY3Ms
IHt9CiAgICAgICAgICAgIGZvciB0YWcsIHAgaW4gbGlzdChwcm9jcy5pdGVtcygpKToKICAgICAg
ICAgICAgICAgIHRyeTogcC50ZXJtaW5hdGUoKQogICAgICAgICAgICAgICAgZXhjZXB0IEV4Y2Vw
dGlvbjogcGFzcwogICAgICAgICAgICB0aW1lLnNsZWVwKDEpCiAgICAgICAgICAgIGZvciBuYW1l
IGluIE9TTU9fU0VSVklDRVMgKyBbInNyc2VuYiIsICJzcnNlcGMiLCAib3BlbjVncy0iXToKICAg
ICAgICAgICAgICAgIHRyeTogc3VicHJvY2Vzcy5ydW4oWyJwa2lsbCIsICItOSIsICItZiIsIG5h
bWVdLAogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBzdGRvdXQ9c3VicHJvY2Vz
cy5ERVZOVUxMLCBzdGRlcnI9c3VicHJvY2Vzcy5ERVZOVUxMKQogICAgICAgICAgICAgICAgZXhj
ZXB0IEV4Y2VwdGlvbjogcGFzcwogICAgICAgICAgICBpZiBzZWxmLnRlY2g6CiAgICAgICAgICAg
ICAgICBfbGltZV9zZXJ2aWNlKCJzdGFydCIpICAgIyBHOTAtRW1wZmFuZyB3aWVkZXIgZnJlaSBn
ZWJlbgogICAgICAgICAgICBzZWxmLnRlY2ggPSBOb25lOyBzZWxmLnN0YXRlID0gImF1cyI7IHNl
bGYubXNnID0gImdlc3RvcHB0IgoKICAgIGRlZiBzdGFydChzZWxmLCBtb2RlKToKICAgICAgICBp
ZiBtb2RlIG5vdCBpbiBNT0RFUzogcmV0dXJuICJ1bmJla2FubnRlciBNb2R1cyIKICAgICAgICB3
aXRoIHNlbGYubG9jazoKICAgICAgICAgICAgc2VsZi5zdG9wKCk7IHNlbGYudGVjaCA9IG1vZGU7
IHNlbGYuc3RhdGUgPSAic3RhcnRldCI7IHNlbGYubXNnID0gIiIKICAgICAgICAgICAgc2VsZi5s
b2dsaW5lcyA9IFtdOyBzZWxmLnN0YXJ0ZWQgPSB0aW1lLnRpbWUoKTsgc2VsZi53ZWxjb21lZCA9
IHNldCgpCiAgICAgICAgZXJyID0gcHJlZmxpZ2h0KG1vZGUpCiAgICAgICAgaWYgZXJyOgogICAg
ICAgICAgICB3aXRoIHNlbGYubG9jazogc2VsZi50ZWNoID0gTm9uZTsgc2VsZi5zdGF0ZSA9ICJm
ZWhsZXIiOyBzZWxmLm1zZyA9IGVycgogICAgICAgICAgICByZXR1cm4gZXJyCiAgICAgICAgaWYg
RkFLRToKICAgICAgICAgICAgd2l0aCBzZWxmLmxvY2s6IHNlbGYuc3RhdGUgPSAibGFldWZ0Ijsg
c2VsZi5tc2cgPSBNT0RFU1ttb2RlXSArICIgbGFldWZ0IChGQUtFKSIKICAgICAgICAgICAgcmV0
dXJuIE5vbmUKICAgICAgICBnc20sIGx0ZSA9IG1vZGUgaW4gKCJnc20iLCAiY3NmYiIpLCBtb2Rl
IGluICgibHRlIiwgImNzZmIiKQogICAgICAgIHRyeToKICAgICAgICAgICAgaWYgZ3NtOgogICAg
ICAgICAgICAgICAgc2VsZi5fc2VydmljZXNfb2ZmKE9TTU9fU0VSVklDRVMpCiAgICAgICAgICAg
ICAgICBnc21fcHJlcGFyZSgpCiAgICAgICAgICAgIGlmIGx0ZToKICAgICAgICAgICAgICAgIHNl
bGYuX3NlcnZpY2VzX29mZihbYiBmb3IgX25mLCBiIGluIE81X05GU10pCiAgICAgICAgICAgICAg
ICBuZnMgPSBvNV9wcmVwYXJlKG1vZGUgPT0gImNzZmIiKQogICAgICAgICAgICAgICAgZW5iX3By
ZXBhcmUobW9kZSA9PSAiY3NmYiIsIHNlbGYuZGV2X2x0ZSkKICAgICAgICAgICAgICAgIF9ydW4o
InN5c3RlbWN0bCIsICJzdGFydCIsICJtb25nb2QiKQogICAgICAgICAgICAgICAgZSA9IGhzc19z
eW5jX2FsbCgpCiAgICAgICAgICAgICAgICBpZiBlOiBzZWxmLl9sb2coInBrb20iLCAiSFNTOiAi
ICsgZSkKICAgICAgICAgICAgaWYgc2VsZi5kZXZfZ3NtOiBzZWxmLl9sb2coInBrb20iLCAiR1NN
LUZ1bms6ICIgKyBsaW1lX2xhYmVsKHNlbGYuZGV2X2dzbSkpCiAgICAgICAgICAgIGlmIHNlbGYu
ZGV2X2x0ZTogc2VsZi5fbG9nKCJwa29tIiwgIkxURS1GdW5rOiAiICsgbGltZV9sYWJlbChzZWxm
LmRldl9sdGUpKQogICAgICAgICAgICBfbGltZV9zZXJ2aWNlKCJzdG9wIik7IHRpbWUuc2xlZXAo
MSk7IF9mcmVlX2xpbWUoKTsgdGltZS5zbGVlcCgyKQogICAgICAgICAgICBpZiBnc206CiAgICAg
ICAgICAgICAgICBmb3IgbmFtZSwgYmluYXJ5LCBjZmcgaW4gZ3NtX2NvbXBvbmVudHMoKToKICAg
ICAgICAgICAgICAgICAgICBmbGFnID0gIi1DIiBpZiBiaW5hcnkuc3RhcnRzd2l0aCgib3Ntby10
cngiKSBlbHNlICItYyIKICAgICAgICAgICAgICAgICAgICBzZWxmLl9zcGF3bihiaW5hcnksIFtm
bGFnLCBvcy5wYXRoLmpvaW4oV09SS0RJUiwgY2ZnKV0sIG5hbWUpCiAgICAgICAgICAgICAgICAg
ICAgdGltZS5zbGVlcCg0IGlmIG5hbWUgaW4gKCJ0cngiLCkgZWxzZSAxLjIpCiAgICAgICAgICAg
ICAgICB0aW1lLnNsZWVwKDEpOyBnc21fYXBwbHlfbnVtYmVycygpICAgIyBTSU1zICsgZGF1ZXJo
YWZ0ZSBSdWZudW1tZXJuIGlucyBITFIKICAgICAgICAgICAgaWYgbHRlOgogICAgICAgICAgICAg
ICAgdWVfbmV0X3VwKCkKICAgICAgICAgICAgICAgIGZvciBuZiwgKGJpbmFyeSwgcGF0aCkgaW4g
bmZzLml0ZW1zKCk6CiAgICAgICAgICAgICAgICAgICAgc2VsZi5fc3Bhd24oYmluYXJ5LCBbIi1j
IiwgcGF0aF0sIG5mKQogICAgICAgICAgICAgICAgICAgIHRpbWUuc2xlZXAoMS41IGlmIG5mID09
ICJtbWUiIGVsc2UgMC44KQogICAgICAgICAgICAgICAgdGltZS5zbGVlcCgyKQogICAgICAgICAg
ICAgICAgc2VsZi5fc3Bhd24oInNyc2VuYiIsIFtvcy5wYXRoLmpvaW4oV09SS0RJUiwgImVuYi5j
b25mIildLCAiZW5iIikKICAgICAgICAgICAgd2l0aCBzZWxmLmxvY2s6IHNlbGYuc3RhdGUgPSAi
bGFldWZ0Ijsgc2VsZi5tc2cgPSBNT0RFU1ttb2RlXSArICIgZ2VzdGFydGV0IgogICAgICAgIGV4
Y2VwdCBFeGNlcHRpb24gYXMgZToKICAgICAgICAgICAgd2l0aCBzZWxmLmxvY2s6IHNlbGYuc3Rh
dGUgPSAiZmVobGVyIjsgc2VsZi5tc2cgPSBzdHIoZSlbOjIwMF0KICAgICAgICAgICAgcmV0dXJu
IHN0cihlKQogICAgICAgIHJldHVybiBOb25lCgogICAgIyBLb21wYXRpYmlsaXRhZXQKICAgIGRl
ZiBzdGFydF9nc20oc2VsZik6IHJldHVybiBzZWxmLnN0YXJ0KCJnc20iKQogICAgZGVmIHN0YXJ0
X2x0ZShzZWxmKTogcmV0dXJuIHNlbGYuc3RhcnQoImx0ZSIpCgogICAgZGVmIF9zZXJ2aWNlc19v
ZmYoc2VsZiwgbmFtZXMpOgogICAgICAgIGZvciBzIGluIG5hbWVzOgogICAgICAgICAgICB0cnk6
IHN1YnByb2Nlc3MucnVuKFsic3lzdGVtY3RsIiwgInN0b3AiLCBzLnJlcGxhY2UoIm9wZW41Z3Mt
IiwgIm9wZW41Z3MtIikgKyAiLnNlcnZpY2UiXSwKICAgICAgICAgICAgICAgICAgICAgICAgICAg
ICAgICBzdGRvdXQ9c3VicHJvY2Vzcy5ERVZOVUxMLCBzdGRlcnI9c3VicHJvY2Vzcy5ERVZOVUxM
LCB0aW1lb3V0PTgpCiAgICAgICAgICAgIGV4Y2VwdCBFeGNlcHRpb246IHBhc3MKCiAgICBkZWYg
c3RhdHVzKHNlbGYpOgogICAgICAgIHdpdGggc2VsZi5sb2NrOgogICAgICAgICAgICBzdCA9IHsK
ICAgICAgICAgICAgICAgICJ0ZWNoIjogc2VsZi50ZWNoLCAibW9kZSI6IE1PREVTLmdldChzZWxm
LnRlY2ggb3IgIiIsICIiKSwKICAgICAgICAgICAgICAgICJzdGF0ZSI6IHNlbGYuc3RhdGUsICJt
c2ciOiBzZWxmLm1zZywKICAgICAgICAgICAgICAgICJ1cHRpbWUiOiBpbnQodGltZS50aW1lKCkg
LSBzZWxmLnN0YXJ0ZWQpIGlmIHNlbGYuc3RhcnRlZCBhbmQgc2VsZi5zdGF0ZSA9PSAibGFldWZ0
IiBlbHNlIDAsCiAgICAgICAgICAgICAgICAibG9nIjogc2VsZi5sb2dsaW5lc1stODA6XSwKICAg
ICAgICAgICAgICAgICJjb25mIjogZGljdChDKSwKICAgICAgICAgICAgICAgICJsaW1lcyI6IExJ
TUVTLAogICAgICAgICAgICAgICAgImRldiI6IHsiZ3NtIjogbGltZV9sYWJlbChzZWxmLmRldl9n
c20pIGlmIHNlbGYuZGV2X2dzbSBlbHNlICIiLAogICAgICAgICAgICAgICAgICAgICAgICAibHRl
IjogbGltZV9sYWJlbChzZWxmLmRldl9sdGUpIGlmIHNlbGYuZGV2X2x0ZSBlbHNlICIifSwKICAg
ICAgICAgICAgICAgICJnc20iOiB7CiAgICAgICAgICAgICAgICAgICAgImFyZmNuIjogaW50KENb
IkdTTV9BUkZDTiJdKSwgImJhbmQiOiBhcmZjbl9iYW5kKGludChDWyJHU01fQVJGQ04iXSkpLAog
ICAgICAgICAgICAgICAgICAgICJtaHoiOiBhcmZjbl9taHooaW50KENbIkdTTV9BUkZDTiJdKSks
CiAgICAgICAgICAgICAgICAgICAgImF0dGFjaGVkIjogc29ydGVkKG1zY19hdHRhY2hlZCgpKSBp
ZiBzZWxmLnN0YXRlID09ICJsYWV1ZnQiIGVsc2UgW10sCiAgICAgICAgICAgICAgICAgICAgIm51
bWJlcnMiOiBudW1zX2xvYWQoKSwKICAgICAgICAgICAgICAgIH0sCiAgICAgICAgICAgICAgICAi
bHRlIjogewogICAgICAgICAgICAgICAgICAgICJlYXJmY24iOiBpbnQoQ1siTFRFX0VBUkZDTiJd
KSwgImJhbmQiOiBlYXJmY25fYmFuZChpbnQoQ1siTFRFX0VBUkZDTiJdKSksCiAgICAgICAgICAg
ICAgICAgICAgIm1oeiI6IGVhcmZjbl9taHooaW50KENbIkxURV9FQVJGQ04iXSkpLAogICAgICAg
ICAgICAgICAgfSwKICAgICAgICAgICAgICAgICJzaW1zIjogW3siaW1zaSI6IGksICJtc2lzZG4i
OiBzLmdldCgibXNpc2RuIiwgIiIpfSBmb3IgaSwgcyBpbiBzb3J0ZWQoc2ltc19sb2FkKCkuaXRl
bXMoKSldLAogICAgICAgICAgICAgICAgInNpbWZpbGVzIjogc2ltX2ZpbGVzKCksCiAgICAgICAg
ICAgICAgICAidHoiOiAiVVRDJStkOiUwMmQlcyIgJSAodHpfbm93KClbMF0sIHR6X25vdygpWzFd
LCAiICtTb21tZXJ6ZWl0IiBpZiB0el9ub3coKVsyXSBlbHNlICIiKSwKICAgICAgICAgICAgICAg
ICJjbGFzaCI6IGZyZXFfY2xhc2goKSwKICAgICAgICAgICAgICAgICJmYWtlIjogRkFLRSwKICAg
ICAgICAgICAgfQogICAgICAgIHJldHVybiBzdAoKTkVUID0gTmV0KCkKCiMgPT09PT09PT09PT09
PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09IFdl
Yi1BUEkKZGVmIGhhbmRsZV9hcGkocGF0aCwgYm9keSk6CiAgICB0cnk6CiAgICAgICAgcmVxID0g
anNvbi5sb2Fkcyhib2R5IG9yICJ7fSIpCiAgICBleGNlcHQgRXhjZXB0aW9uOgogICAgICAgIHJl
cSA9IHt9CiAgICBjbWQgPSBwYXRoLnJzcGxpdCgiLyIsIDEpWy0xXQogICAgaWYgY21kID09ICJz
dGF0dXMiOgogICAgICAgIHJldHVybiBORVQuc3RhdHVzKCkKICAgIGlmIGNtZCBpbiAoInN0YXJ0
X2dzbSIsICJzdGFydF9sdGUiLCAic3RhcnRfY3NmYiIpOgogICAgICAgIE5FVC5zdGFydChjbWRb
NjpdKQogICAgZWxpZiBjbWQgPT0gInN0b3AiOgogICAgICAgIE5FVC5zdG9wKCkKICAgIGVsaWYg
Y21kID09ICJsaW1lX3NjYW4iOgogICAgICAgIG4gPSBsZW4obGltZV9zY2FuKCkpOyBORVQubXNn
ID0gZiJ7bn0gTGltZVNEUiBnZWZ1bmRlbiIKICAgIGVsaWYgY21kID09ICJzZXQiOgogICAgICAg
ICMgYmVsaWViaWdlIEtvbmZpZy1LZXlzIHNldHplbiAodmFsaWRpZXJ0IGxpZ2h0KQogICAgICAg
IGZvciBrLCB2IGluIHJlcS5pdGVtcygpOgogICAgICAgICAgICBpZiBrIGluIERFRkFVTFRTIG9y
IGsgaW4gQzoKICAgICAgICAgICAgICAgIHYgPSBzdHIodikucmVwbGFjZSgnIicsICIiKS5yZXBs
YWNlKCJcbiIsICIgIikuc3RyaXAoKQogICAgICAgICAgICAgICAgaWYgayBpbiAoIk1DQyIsICJN
TkMiLCAiTFRFX1RBQyIpOiB2ID0gcmUuc3ViKHIiXEQiLCAiIiwgdikKICAgICAgICAgICAgICAg
IGNzZXQoaywgdikKICAgICAgICBORVQubXNnID0gImdlc3BlaWNoZXJ0IC0gd2lya3QgYmVpbSBu
YWVjaHN0ZW4gU3RhcnQiCiAgICAgICAgaWYgQy5nZXQoIkdTTV9ERVYiKSBhbmQgQy5nZXQoIkdT
TV9ERVYiKSA9PSBDLmdldCgiTFRFX0RFViIpOgogICAgICAgICAgICBORVQubXNnID0gIkFjaHR1
bmc6IEdTTSB1bmQgTFRFIG51dHplbiBkZW5zZWxiZW4gTGltZVNEUiAtIGZ1ZXIgTFRFICsgR1NN
IHp3ZWkgR2VyYWV0ZSB3YWVobGVuIgogICAgZWxpZiBjbWQgaW4gKCJzaW1fYWRkIiwgImdzbV9z
aW1fYWRkIiwgImx0ZV9zaW1fYWRkIik6CiAgICAgICAgTkVULm1zZyA9IHNpbV9hZGQocmVxLmdl
dCgiaW1zaSIsIiIpLCByZXEuZ2V0KCJraSIsIiIpLCByZXEuZ2V0KCJvcGMiLCIiKSwgcmVxLmdl
dCgibXNpc2RuIiwiIikpIFwKICAgICAgICAgICAgICAgICAgb3IgIlNJTSBnZXNwZWljaGVydCAo
R1NNICsgTFRFKSIKICAgIGVsaWYgY21kIGluICgic2ltX2RlbCIsICJnc21fc2ltX2RlbCIsICJs
dGVfc2ltX2RlbCIpOgogICAgICAgIHNpbV9kZWwocmVxLmdldCgiaW1zaSIsIiIpKTsgTkVULm1z
ZyA9ICJTSU0gZ2Vsb2VzY2h0IgogICAgZWxpZiBjbWQgPT0gImdzbV9zaW1fbnIiOgogICAgICAg
IE5FVC5tc2cgPSBnc21fc2ltX25yKHJlcS5nZXQoImltc2kiLCIiKSwgcmVxLmdldCgibXNpc2Ru
IiwiIikpIG9yICJSdWZudW1tZXIgZGF1ZXJoYWZ0IHp1Z2V3aWVzZW4iCiAgICBlbGlmIGNtZCA9
PSAiZ3NtX251bV9kZWwiOgogICAgICAgIGdzbV9udW1fZGVsKHJlcS5nZXQoImltc2kiLCIiKSk7
IE5FVC5tc2cgPSAiUnVmbnVtbWVyLVp1d2Vpc3VuZyBnZWxvZXNjaHQiCiAgICBlbGlmIGNtZCA9
PSAic2ltX2dlbiI6CiAgICAgICAgdHJ5OgogICAgICAgICAgICBnZW4gPSBzaW1fZ2VuZXJhdGUo
cmVxLmdldCgiY291bnQiLCAxKSwgcmVxLmdldCgibXNpc2RuIiwgIiIpLCByZXEuZ2V0KCJpY2Np
ZCIsICIiKSkKICAgICAgICAgICAgTkVULm1zZyA9IGYie2xlbihnZW4pfSBTSU0tRGF0ZW5zYXR6
Ly1zYWV0emUgZXJ6ZXVndCIKICAgICAgICBleGNlcHQgRXhjZXB0aW9uIGFzIGU6CiAgICAgICAg
ICAgIGdlbiA9IFtdOyBORVQubXNnID0gIkVyemV1Z2VuIGZlaGxnZXNjaGxhZ2VuOiAlcyIgJSBl
CiAgICAgICAgc3QgPSBORVQuc3RhdHVzKCk7IHN0WyJnZW5lcmF0ZWQiXSA9IGdlbgogICAgICAg
IHJldHVybiBzdAogICAgZWxpZiBjbWQgPT0gInNtc190ZXN0IjoKICAgICAgICBORVQubXNnID0g
c21zX3Rlc3QocmVxLmdldCgiaW1zaSIsIiIpLCByZXEuZ2V0KCJ0ZXh0IiwiIikpCiAgICBlbHNl
OgogICAgICAgIE5FVC5tc2cgPSAidW5iZWthbm50IgogICAgcmV0dXJuIE5FVC5zdGF0dXMoKQoK
IyA9PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
PT09PT09PT09PT0gV2ViLU9iZXJmbGFlY2hlIChIVE1MKQpQQUdFID0gciIiIjwhZG9jdHlwZSBo
dG1sPjxodG1sIGxhbmc9ZGU+PGhlYWQ+PG1ldGEgY2hhcnNldD11dGYtOD4KPG1ldGEgbmFtZT12
aWV3cG9ydCBjb250ZW50PSJ3aWR0aD1kZXZpY2Utd2lkdGgsaW5pdGlhbC1zY2FsZT0xIj4KPG1l
dGEgbmFtZT10aGVtZS1jb2xvciBjb250ZW50PSIjMEEyNDYzIj4KPGxpbmsgcmVsPWljb24gaHJl
Zj0iZGF0YTppbWFnZS9zdmcreG1sO2Jhc2U2NCxQSE4yWnlCNGJXeHVjejBpYUhSMGNEb3ZMM2Qz
ZHk1M015NXZjbWN2TWpBd01DOXpkbWNpSUhacFpYZENiM2c5SWpBZ01DQXhNREkwSURFd01qUWlQ
anh5WldOMElIZHBaSFJvUFNJeE1ESTBJaUJvWldsbmFIUTlJakV3TWpRaUlHWnBiR3c5SWlNd1FU
STBOak1pUGp3dmNtVmpkRDRLUEdjZ2RISmhibk5tYjNKdFBTSjBjbUZ1YzJ4aGRHVW9NVEkzTGpZ
Z016UTNMakFwSUhOallXeGxLREV1TmpVcElpQm1hV3hzUFNKdWIyNWxJaUJ6ZEhKdmEyVXRiR2x1
WldOaGNEMGljbTkxYm1RaUlITjBjbTlyWlMxc2FXNWxhbTlwYmowaWNtOTFibVFpSUhOMGNtOXJa
UzEzYVdSMGFEMGlNeklpUGdvOFp5QnpkSEp2YTJVOUlpTkdSa1pHUmtZaVBnbzhjR0YwYUNCa1BT
Sk5NakFnT0RBZ1ZqSTJOaUkrUEM5d1lYUm9QZ284WTJseVkyeGxJR040UFNJM01pSWdZM2s5SWpF
ek15SWdjajBpTlRJaVBqd3ZZMmx5WTJ4bFBnbzhMMmMrQ2p4bklITjBjbTlyWlQwaUkwWkdSa1pH
UmlJK0NqeHdZWFJvSUdROUlrMHhOemdnTVRZZ1VUSXdOaUF4TURBZ01UYzRJREU0TkNJK1BDOXdZ
WFJvUGdvOGNHRjBhQ0JrUFNKTk1Ua3lJREV3TUNCRE1qSTJJRGsySURJMU1DQTJNaUF5TmpZZ01U
WWlQand2Y0dGMGFENEtQQzluUGdvOGNHRjBhQ0J6ZEhKdmEyVTlJaU15UlVNMFJqRWlJR1E5SWsw
eE9USWdNVEF3SUVNeU16TWdNVEF5SURJMU5pQXhPRE1nTXpZeklERTRNeUJCT0RNZ09ETWdNQ0F3
SURBZ016WXpJREUzSUVFNE15QTRNeUF3SURBZ01DQXlPRElnTVRFNElqNDhMM0JoZEdnK0Nqd3Za
ejQ4TDNOMlp6ND0iPgo8dGl0bGU+cEtPTSDCtyBOZXR6c3RldWVydW5nPC90aXRsZT4KPHN0eWxl
Pgo6cm9vdHstLW5hdnk6IzBBMjQ2MzstLWJnOiMwNjBmMjI7LS1iZzI6IzBhMTczNDstLWNhcmQ6
IzBjMWEzYjstLWNhcmQyOiMxMDIyNTA7LS1saW5lOiMxYjJmNWU7LS1saW5lMjojMmE0Mjg4Owot
LWZnOiNlYWYxZmI7LS1tdXQ6IzhlYTRjYTstLW11dDI6IzVkNzM5ODstLWFjYzojMkVDNEYxOy0t
YWNjMjojMDA5NkQ2Oy0tb2s6IzJFQzRGMTstLW9rYmc6IzA3MjQzYjstLWVycjojZmY1ZDZjOwot
LXI6MDstLXIyOjA7LS1tb25vOnVpLW1vbm9zcGFjZSxTRk1vbm8tUmVndWxhcixNZW5sbyxDb25z
b2xhcyxtb25vc3BhY2V9Cip7Ym94LXNpemluZzpib3JkZXItYm94fWh0bWwsYm9keXttYXJnaW46
MH0KYm9keXtiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCgxODBkZWcsIzA4MTMzMCwjMDUxMDFm
KTtjb2xvcjp2YXIoLS1mZyk7CmZvbnQ6MTVweC8xLjU1IHN5c3RlbS11aSwtYXBwbGUtc3lzdGVt
LFNlZ29lIFVJLFJvYm90byxzYW5zLXNlcmlmO21pbi1oZWlnaHQ6MTAwdmh9CmhlYWRlcntwb3Np
dGlvbjpzdGlja3k7dG9wOjA7ei1pbmRleDoyMDtiYWNrZ3JvdW5kOnZhcigtLW5hdnkpO2JvcmRl
ci10b3A6MnB4IHNvbGlkIHZhcigtLWFjYyk7CmJvcmRlci1ib3R0b206MXB4IHNvbGlkIHZhcigt
LWxpbmUyKTtwYWRkaW5nOjEycHggMjBweDtkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVy
O2dhcDoxNnB4O2ZsZXgtd3JhcDp3cmFwfQouYnJhbmR7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1z
OmNlbnRlcjtnYXA6MTJweH0KLmJyYW5kIHN2Z3toZWlnaHQ6MzBweDt3aWR0aDphdXRvO2Rpc3Bs
YXk6YmxvY2t9Ci5icmFuZCAucHJvZHtmb250LXNpemU6MTFweDtmb250LXdlaWdodDo3MDA7bGV0
dGVyLXNwYWNpbmc6LjE4ZW07dGV4dC10cmFuc2Zvcm06dXBwZXJjYXNlO2NvbG9yOiM5ZmI2ZGU7
cGFkZGluZy1sZWZ0OjEycHg7Ym9yZGVyLWxlZnQ6MXB4IHNvbGlkICMyNzQwN2V9Ci5jaGlwe2Rp
c3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7Z2FwOjhweDtwYWRkaW5nOjZweCAxMnB4O2Jv
cmRlcjoxcHggc29saWQgdmFyKC0tbGluZTIpO2JhY2tncm91bmQ6IzBiMTczMztmb250LXNpemU6
MTJweDtmb250LXdlaWdodDo3MDA7bGV0dGVyLXNwYWNpbmc6LjA2ZW07dGV4dC10cmFuc2Zvcm06
dXBwZXJjYXNlfQouZG90e3dpZHRoOjhweDtoZWlnaHQ6OHB4O2JhY2tncm91bmQ6dmFyKC0tbXV0
KX0KLmRvdC5vbntiYWNrZ3JvdW5kOnZhcigtLWFjYyk7YW5pbWF0aW9uOnB1bHNlIDJzIGluZmlu
aXRlfS5kb3QuZXJye2JhY2tncm91bmQ6dmFyKC0tZXJyKX0KQGtleWZyYW1lcyBwdWxzZXswJXti
b3gtc2hhZG93OjAgMCAwIDAgcmdiYSg0NiwxOTYsMjQxLC41KX03MCV7Ym94LXNoYWRvdzowIDAg
MCA3cHggcmdiYSg0NiwxOTYsMjQxLDApfTEwMCV7Ym94LXNoYWRvdzowIDAgMCAwIHJnYmEoNDYs
MTk2LDI0MSwwKX19Ci5oc3RhdHtkaXNwbGF5OmZsZXg7Z2FwOjE4cHg7ZmxleC13cmFwOndyYXA7
Y29sb3I6dmFyKC0tbXV0KTtmb250LXNpemU6MTJweDttYXJnaW4tbGVmdDphdXRvO2FsaWduLWl0
ZW1zOmNlbnRlcjt0ZXh0LXRyYW5zZm9ybTp1cHBlcmNhc2U7bGV0dGVyLXNwYWNpbmc6LjA1ZW19
Ci5oc3RhdCBie2NvbG9yOnZhcigtLWZnKTtmb250LWZhbWlseTp2YXIoLS1tb25vKTtsZXR0ZXIt
c3BhY2luZzowO3RleHQtdHJhbnNmb3JtOm5vbmV9CiNtc2d7Y29sb3I6dmFyKC0tYWNjKTtmb250
LXNpemU6MTJweDt0ZXh0LXRyYW5zZm9ybTpub25lO2xldHRlci1zcGFjaW5nOjB9Ci5iYWRnZXtm
b250LXNpemU6MTBweDtwYWRkaW5nOjNweCA5cHg7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1hY2Mp
O2NvbG9yOnZhcigtLWFjYyk7Zm9udC13ZWlnaHQ6NzAwO2xldHRlci1zcGFjaW5nOi4xMmVtfQou
d3JhcHttYXgtd2lkdGg6MTA2MHB4O21hcmdpbjowIGF1dG87cGFkZGluZzoyMnB4IDE2cHggNDRw
eH0KLmJhbm5lcntkaXNwbGF5OmZsZXg7Z2FwOjExcHg7YWxpZ24taXRlbXM6ZmxleC1zdGFydDti
YWNrZ3JvdW5kOiMwYzFhM2I7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1saW5lMik7CmJvcmRlci1s
ZWZ0OjNweCBzb2xpZCAjZjFiMjRhO2NvbG9yOiNmMmQ3OWY7cGFkZGluZzoxMnB4IDE1cHg7Zm9u
dC1zaXplOjEzcHg7bWFyZ2luLWJvdHRvbToxOHB4fQouY29udHJvbHN7ZGlzcGxheTpncmlkO2dy
aWQtdGVtcGxhdGUtY29sdW1uczoxZnIgMWZyIDFmciBhdXRvO2dhcDoxMHB4O21hcmdpbi1ib3R0
b206MjBweH0KQG1lZGlhKG1heC13aWR0aDo4MjBweCl7LmNvbnRyb2xze2dyaWQtdGVtcGxhdGUt
Y29sdW1uczoxZnIgMWZyfX1AbWVkaWEobWF4LXdpZHRoOjQ4MHB4KXsuY29udHJvbHN7Z3JpZC10
ZW1wbGF0ZS1jb2x1bW5zOjFmcn19Ci5iaWdidG57Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1saW5l
Mik7YmFja2dyb3VuZDojMGIxODM2O2NvbG9yOnZhcigtLWZnKTsKcGFkZGluZzoxNXB4IDE4cHg7
Zm9udDppbmhlcml0O2ZvbnQtd2VpZ2h0OjYwMDtjdXJzb3I6cG9pbnRlcjtkaXNwbGF5OmZsZXg7
YWxpZ24taXRlbXM6Y2VudGVyO2dhcDoxMnB4O3RyYW5zaXRpb246LjE1c30KLmJpZ2J0bjpob3Zl
cntib3JkZXItY29sb3I6dmFyKC0tYWNjKTtiYWNrZ3JvdW5kOiMwZTFmNDd9LmJpZ2J0biAuaWN7
Zm9udC1zaXplOjE2cHg7Y29sb3I6dmFyKC0tYWNjKX0KLmJpZ2J0biBzbWFsbHtkaXNwbGF5OmJs
b2NrO2NvbG9yOnZhcigtLW11dCk7Zm9udC13ZWlnaHQ6NDAwO2ZvbnQtc2l6ZToxMXB4O3RleHQt
dHJhbnNmb3JtOnVwcGVyY2FzZTtsZXR0ZXItc3BhY2luZzouMDdlbTttYXJnaW4tdG9wOjJweH0K
LmJpZ2J0bi5hY3RpdmV7Ym9yZGVyLWNvbG9yOnZhcigtLWFjYyk7YmFja2dyb3VuZDp2YXIoLS1v
a2JnKTtib3gtc2hhZG93Omluc2V0IDNweCAwIDAgdmFyKC0tYWNjKX0uYmlnYnRuLmFjdGl2ZSAu
aWN7Y29sb3I6dmFyKC0tYWNjKX0KLmJpZ2J0bi5zdG9we2JhY2tncm91bmQ6IzFlMTAxNjtib3Jk
ZXItY29sb3I6IzUzMjMyZTtjb2xvcjojZmZiMGI4O2p1c3RpZnktY29udGVudDpjZW50ZXI7Zm9u
dC13ZWlnaHQ6NzAwO2xldHRlci1zcGFjaW5nOi4wNWVtO3RleHQtdHJhbnNmb3JtOnVwcGVyY2Fz
ZTtmb250LXNpemU6MTRweH0uYmlnYnRuLnN0b3A6aG92ZXJ7Ym9yZGVyLWNvbG9yOnZhcigtLWVy
cil9Ci50YWJze2Rpc3BsYXk6ZmxleDtnYXA6NHB4O2JvcmRlci1ib3R0b206MXB4IHNvbGlkIHZh
cigtLWxpbmUyKTttYXJnaW4tYm90dG9tOjIwcHg7b3ZlcmZsb3cteDphdXRvfQoudGFie3BhZGRp
bmc6MTBweCAxNnB4O2JvcmRlcjowO2JhY2tncm91bmQ6MDtjb2xvcjp2YXIoLS1tdXQpO2ZvbnQ6
aW5oZXJpdDtmb250LXdlaWdodDo3MDA7Zm9udC1zaXplOjEycHg7bGV0dGVyLXNwYWNpbmc6LjA5
ZW07dGV4dC10cmFuc2Zvcm06dXBwZXJjYXNlO2N1cnNvcjpwb2ludGVyO2JvcmRlci1ib3R0b206
MnB4IHNvbGlkIHRyYW5zcGFyZW50O3doaXRlLXNwYWNlOm5vd3JhcDttYXJnaW4tYm90dG9tOi0x
cHh9Ci50YWI6aG92ZXJ7Y29sb3I6dmFyKC0tZmcpfS50YWIuc2Vse2NvbG9yOnZhcigtLWFjYyk7
Ym9yZGVyLWJvdHRvbS1jb2xvcjp2YXIoLS1hY2MpfQoucGFuZWx7ZGlzcGxheTpub25lfS5wYW5l
bC5zZWx7ZGlzcGxheTpibG9ja30KLmdyaWR7ZGlzcGxheTpncmlkO2dhcDoxNnB4O2dyaWQtdGVt
cGxhdGUtY29sdW1uczoxZnIgMWZyfUBtZWRpYShtYXgtd2lkdGg6NzYwcHgpey5ncmlke2dyaWQt
dGVtcGxhdGUtY29sdW1uczoxZnJ9fQouY2FyZHtiYWNrZ3JvdW5kOnZhcigtLWNhcmQpO2JvcmRl
cjoxcHggc29saWQgdmFyKC0tbGluZSk7cGFkZGluZzoxOHB4fQouY2FyZCBoMntmb250LXNpemU6
MTJweDttYXJnaW46MDtkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2dhcDo5cHg7dGV4
dC10cmFuc2Zvcm06dXBwZXJjYXNlO2xldHRlci1zcGFjaW5nOi4xZW07Y29sb3I6I2M2ZDZmMTtm
b250LXdlaWdodDo3MDB9Ci5jYXJkIGgyOmJlZm9yZXtjb250ZW50OiIiO3dpZHRoOjlweDtoZWln
aHQ6OXB4O2JhY2tncm91bmQ6dmFyKC0tYWNjKTtmbGV4Om5vbmV9Ci5jYXJkIC5zdWJ7Y29sb3I6
dmFyKC0tbXV0KTtmb250LXNpemU6MTJweDttYXJnaW46OHB4IDAgMTRweH0KbGFiZWx7ZGlzcGxh
eTpibG9jaztmb250LXNpemU6MTFweDtjb2xvcjp2YXIoLS1tdXQpO21hcmdpbjoxM3B4IDAgNXB4
O2ZvbnQtd2VpZ2h0OjcwMDt0ZXh0LXRyYW5zZm9ybTp1cHBlcmNhc2U7bGV0dGVyLXNwYWNpbmc6
LjA3ZW19CmlucHV0LHNlbGVjdHt3aWR0aDoxMDAlO2JhY2tncm91bmQ6IzA3MTQyZjtib3JkZXI6
MXB4IHNvbGlkIHZhcigtLWxpbmUyKTtjb2xvcjp2YXIoLS1mZyk7cGFkZGluZzoxMHB4IDEycHg7
Zm9udDppbmhlcml0O291dGxpbmU6MDt0cmFuc2l0aW9uOi4xMnN9CmlucHV0OmZvY3VzLHNlbGVj
dDpmb2N1c3tib3JkZXItY29sb3I6dmFyKC0tYWNjKTtib3gtc2hhZG93OjAgMCAwIDJweCByZ2Jh
KDQ2LDE5NiwyNDEsLjE4KX0KLnJvd3tkaXNwbGF5OmdyaWQ7Z3JpZC10ZW1wbGF0ZS1jb2x1bW5z
OjFmciAxZnI7Z2FwOjEwcHh9LnJvdzN7ZGlzcGxheTpncmlkO2dyaWQtdGVtcGxhdGUtY29sdW1u
czoxZnIgMWZyIDFmcjtnYXA6MTBweH0KLmJ0bntiYWNrZ3JvdW5kOnZhcigtLWFjYyk7Y29sb3I6
dmFyKC0tbmF2eSk7Ym9yZGVyOjA7cGFkZGluZzoxMHB4IDE4cHg7Zm9udDppbmhlcml0O2ZvbnQt
d2VpZ2h0OjcwMDtsZXR0ZXItc3BhY2luZzouMDVlbTt0ZXh0LXRyYW5zZm9ybTp1cHBlcmNhc2U7
Zm9udC1zaXplOjEzcHg7Y3Vyc29yOnBvaW50ZXI7bWFyZ2luLXRvcDoxNnB4O3RyYW5zaXRpb246
LjEyc30KLmJ0bjpob3ZlcntiYWNrZ3JvdW5kOiM1YWQyZjZ9LmJ0bi5zZWN7YmFja2dyb3VuZDp0
cmFuc3BhcmVudDtib3JkZXI6MXB4IHNvbGlkIHZhcigtLWxpbmUyKTtjb2xvcjp2YXIoLS1hY2Mp
fS5idG4uc2VjOmhvdmVye2JvcmRlci1jb2xvcjp2YXIoLS1hY2MpO2JhY2tncm91bmQ6IzBiMWI0
MH0KLmJ0bi5zbXtwYWRkaW5nOjhweCAxM3B4O21hcmdpbi10b3A6NHB4O2ZvbnQtc2l6ZToxMnB4
fQouc3d7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtqdXN0aWZ5LWNvbnRlbnQ6c3Bh
Y2UtYmV0d2VlbjtnYXA6MTBweDtwYWRkaW5nOjEzcHggMDtib3JkZXItdG9wOjFweCBzb2xpZCB2
YXIoLS1saW5lKX0KLnN3LmZpcnN0e2JvcmRlci10b3A6MH0uc3cgLnR7Zm9udC1zaXplOjE0cHh9
LnN3IC50IHNtYWxse2Rpc3BsYXk6YmxvY2s7Y29sb3I6dmFyKC0tbXV0KTtmb250LXNpemU6MTJw
eH0KLnN3aXRjaHtwb3NpdGlvbjpyZWxhdGl2ZTt3aWR0aDo0NnB4O2hlaWdodDoyNHB4O2ZsZXg6
bm9uZX0uc3dpdGNoIGlucHV0e29wYWNpdHk6MDt3aWR0aDowO2hlaWdodDowfQouc2xpZGVye3Bv
c2l0aW9uOmFic29sdXRlO2luc2V0OjA7YmFja2dyb3VuZDojMGIxYTNkO2JvcmRlcjoxcHggc29s
aWQgdmFyKC0tbGluZTIpO3RyYW5zaXRpb246LjJzO2N1cnNvcjpwb2ludGVyfQouc2xpZGVyOmJl
Zm9yZXtjb250ZW50OiIiO3Bvc2l0aW9uOmFic29sdXRlO2hlaWdodDoxNnB4O3dpZHRoOjE2cHg7
bGVmdDozcHg7dG9wOjNweDtiYWNrZ3JvdW5kOnZhcigtLW11dCk7dHJhbnNpdGlvbjouMnN9Ci5z
d2l0Y2ggaW5wdXQ6Y2hlY2tlZCsuc2xpZGVye2JhY2tncm91bmQ6dmFyKC0tb2tiZyk7Ym9yZGVy
LWNvbG9yOnZhcigtLWFjYyl9LnN3aXRjaCBpbnB1dDpjaGVja2VkKy5zbGlkZXI6YmVmb3Jle3Ry
YW5zZm9ybTp0cmFuc2xhdGVYKDIycHgpO2JhY2tncm91bmQ6dmFyKC0tYWNjKX0KLmhpbnR7Zm9u
dC1zaXplOjEycHg7Y29sb3I6dmFyKC0tbXV0KTttYXJnaW4tdG9wOjEwcHg7bGluZS1oZWlnaHQ6
MS41fQouZnJlcWJveHtiYWNrZ3JvdW5kOiMwNzE0MmY7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1s
aW5lMik7cGFkZGluZzoxM3B4IDE2cHg7ZGlzcGxheTpmbGV4O2p1c3RpZnktY29udGVudDpzcGFj
ZS1iZXR3ZWVuO2FsaWduLWl0ZW1zOmNlbnRlcn0KLmZyZXFib3ggLmJpZ3tmb250LXNpemU6MjJw
eDtmb250LXdlaWdodDo3MDA7bGluZS1oZWlnaHQ6MS4xNTtmb250LWZhbWlseTp2YXIoLS1tb25v
KTtjb2xvcjp2YXIoLS1hY2MpfS5mcmVxYm94IC5zbXtjb2xvcjp2YXIoLS1tdXQpO2ZvbnQtc2l6
ZToxMnB4O3RleHQtdHJhbnNmb3JtOnVwcGVyY2FzZTtsZXR0ZXItc3BhY2luZzouMDZlbX0KLmxp
c3Ryb3d7ZGlzcGxheTpmbGV4O2p1c3RpZnktY29udGVudDpzcGFjZS1iZXR3ZWVuO2FsaWduLWl0
ZW1zOmNlbnRlcjtib3JkZXItdG9wOjFweCBzb2xpZCB2YXIoLS1saW5lKTtwYWRkaW5nOjlweCAw
O2ZvbnQtc2l6ZToxNHB4fQoubGlzdHJvdzpmaXJzdC1jaGlsZHtib3JkZXItdG9wOjB9LnRhZ3tm
b250LWZhbWlseTp2YXIoLS1tb25vKTtmb250LXNpemU6MTNweDtjb2xvcjojY2FkOWYzfQoueHti
YWNrZ3JvdW5kOiMxZTEwMTY7Ym9yZGVyOjFweCBzb2xpZCAjNTMyMzJlO2NvbG9yOiNmZjliYTY7
cGFkZGluZzo0cHggMTBweDtjdXJzb3I6cG9pbnRlcjtmb250LXNpemU6MTFweDt0ZXh0LXRyYW5z
Zm9ybTp1cHBlcmNhc2U7bGV0dGVyLXNwYWNpbmc6LjA1ZW19Lng6aG92ZXJ7Ym9yZGVyLWNvbG9y
OnZhcigtLWVycil9Ci5lbXB0eXtjb2xvcjp2YXIoLS1tdXQyKTtmb250LXNpemU6MTNweDtwYWRk
aW5nOjhweCAwfQoubG9ne2JhY2tncm91bmQ6IzAzMGExODtib3JkZXI6MXB4IHNvbGlkIHZhcigt
LWxpbmUpO3BhZGRpbmc6MTRweDtmb250OjEycHgvMS41NSB2YXIoLS1tb25vKTtoZWlnaHQ6NDQw
cHg7b3ZlcmZsb3c6YXV0bzt3aGl0ZS1zcGFjZTpwcmUtd3JhcDtjb2xvcjojOWZiM2QwfQoudG9v
bGJhcntkaXNwbGF5OmZsZXg7Z2FwOjhweDthbGlnbi1pdGVtczpjZW50ZXI7bWFyZ2luLWJvdHRv
bToxMnB4fS50b29sYmFyIGlucHV0e2ZsZXg6MX0KLmVme3dpZHRoOjEwMCU7Ym9yZGVyLWNvbGxh
cHNlOmNvbGxhcHNlO2ZvbnQtc2l6ZToxM3B4O21hcmdpbi10b3A6NnB4fS5lZiB0aHt0ZXh0LWFs
aWduOmxlZnQ7Y29sb3I6dmFyKC0tbXV0KTtmb250LXNpemU6MTFweDt0ZXh0LXRyYW5zZm9ybTp1
cHBlcmNhc2U7bGV0dGVyLXNwYWNpbmc6LjA3ZW07cGFkZGluZzo4cHggNnB4O2JvcmRlci1ib3R0
b206MXB4IHNvbGlkIHZhcigtLWxpbmUyKX0uZWYgdGR7cGFkZGluZzoxMHB4IDZweDtib3JkZXIt
Ym90dG9tOjFweCBzb2xpZCB2YXIoLS1saW5lKTt2ZXJ0aWNhbC1hbGlnbjp0b3B9LmVmIGNvZGV7
Zm9udC1mYW1pbHk6dmFyKC0tbW9ubyk7Y29sb3I6dmFyKC0tYWNjKTt3b3JkLWJyZWFrOmJyZWFr
LWFsbDt1c2VyLXNlbGVjdDphbGx9Lm11dHtjb2xvcjp2YXIoLS1tdXQpO2ZvbnQtc2l6ZToxMXB4
fS5nZW53cmFwe292ZXJmbG93LXg6YXV0bzttYXJnaW4tdG9wOjEycHh9LmdlbndyYXAgLmVmIHRk
LC5nZW53cmFwIC5lZiB0aHt3aGl0ZS1zcGFjZTpub3dyYXB9LmdlbndyYXAgY29kZXtmb250LXNp
emU6MTJweH0uYnRuOmRpc2FibGVke29wYWNpdHk6LjQ7Y3Vyc29yOmRlZmF1bHR9Y29kZXtmb250
LWZhbWlseTp2YXIoLS1tb25vKX1AbWVkaWEobWF4LXdpZHRoOjU2MHB4KXsucm93LC5yb3cze2dy
aWQtdGVtcGxhdGUtY29sdW1uczoxZnJ9fQo8L3N0eWxlPjwvaGVhZD48Ym9keT4KPGhlYWRlcj4K
IDxkaXYgY2xhc3M9YnJhbmQ+PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmci
IHZpZXdCb3g9Ii0yMCAtMjAgNjY4IDMzMCIgcm9sZT0iaW1nIiBhcmlhLWxhYmVsPSJwS09NIj48
ZyBmaWxsPSJub25lIiBzdHJva2UtbGluZWNhcD0icm91bmQiIHN0cm9rZS1saW5lam9pbj0icm91
bmQiIHN0cm9rZS13aWR0aD0iMzIiPjxnIHN0cm9rZT0iI0ZGRkZGRiI+PHBhdGggZD0iTTIwIDgw
IFYyNjYiPjwvcGF0aD48Y2lyY2xlIGN4PSI3MiIgY3k9IjEzMyIgcj0iNTIiPjwvY2lyY2xlPjxw
YXRoIGQ9Ik0xNzggMTYgUTIwNiAxMDAgMTc4IDE4NCI+PC9wYXRoPjxwYXRoIGQ9Ik0xOTIgMTAw
IEMyMjYgOTYgMjUwIDYyIDI2NiAxNiI+PC9wYXRoPjxwYXRoIGQ9Ik00OTIgMTg0IFYzMCBDNTIy
IDMwIDUzNCAxMDYgNTUyIDEwNiBDNTcwIDEwNiA1ODIgMzAgNjEyIDMwIFYxODQiPjwvcGF0aD48
L2c+PHBhdGggc3Ryb2tlPSIjMkVDNEYxIiBkPSJNMTkyIDEwMCBDMjMzIDEwMiAyNTYgMTgzIDM2
MyAxODMgQTgzIDgzIDAgMCAwIDM2MyAxNyBBODMgODMgMCAwIDAgMjgyIDExOCI+PC9wYXRoPjwv
Zz48L3N2Zz48c3BhbiBjbGFzcz1wcm9kPk5ldHpzdGV1ZXJ1bmc8L3NwYW4+PC9kaXY+CiA8ZGl2
IGNsYXNzPWNoaXA+PHNwYW4gY2xhc3M9ZG90IGlkPWRvdD48L3NwYW4+PHNwYW4gaWQ9c3RhdGU+
4oCTPC9zcGFuPjwvZGl2PgogPGRpdiBjbGFzcz1oc3RhdD4KICA8c3BhbiBpZD10ZWNoYmFkZ2Ug
Y2xhc3M9YmFkZ2Ugc3R5bGU9ZGlzcGxheTpub25lPjwvc3Bhbj4KICA8c3Bhbj5GcmVxdWVueiA8
YiBpZD1mcmVxPuKAkzwvYj48L3NwYW4+CiAgPHNwYW4+TGF1ZnplaXQgPGIgaWQ9dXB0aW1lPuKA
kzwvYj48L3NwYW4+CiAgPHNwYW4gaWQ9bXNnPjwvc3Bhbj4KIDwvZGl2Pgo8L2hlYWRlcj4KPGRp
diBjbGFzcz13cmFwPgogPGRpdiBjbGFzcz1iYW5uZXI+PHNwYW4+4pqg77iPPC9zcGFuPjxzcGFu
PjxiPk51ciBhYmdlc2Nob3R0ZXQgYmV0cmVpYmVuPC9iPiDigJMgRHVtbXkgTG9hZCAvIEthYmVs
ICsgRMOkbXBmdW5nIC8gZ2VzY2hpcm10LiBPZmZlbmVzIE5ldHogb2huZSBBdXRoZW50aXNpZXJ1
bmcgPSBJTVNJLUNhdGNoZXIsIHdlbm4gZXMgYWJzdHJhaGx0LiBOdXIgZWlnZW5lIFRlc3QtU0lN
cywgS2VubnVuZyAwMDEveHggKFRlc3QpIG9kZXIgOTk5L3h4IChwcml2YXQpLjwvc3Bhbj48L2Rp
dj4KCiA8ZGl2IGNsYXNzPWNvbnRyb2xzPgogIDxidXR0b24gY2xhc3M9YmlnYnRuIGlkPWJ0bl9n
c20gb25jbGljaz0iY21kKCdzdGFydF9nc20nKSI+PHNwYW4gY2xhc3M9aWM+4pa2PC9zcGFuPjxz
cGFuPkdTTSAoMkcpPHNtYWxsIGlkPWdzbV9zdWI+T3Ntb2NvbTwvc21hbGw+PC9zcGFuPjwvYnV0
dG9uPgogIDxidXR0b24gY2xhc3M9YmlnYnRuIGlkPWJ0bl9sdGUgb25jbGljaz0iY21kKCdzdGFy
dF9sdGUnKSI+PHNwYW4gY2xhc3M9aWM+4pa2PC9zcGFuPjxzcGFuPkxURSAoNEcpPHNtYWxsIGlk
PWx0ZV9zdWI+c3JzUkFOICsgT3BlbjVHUzwvc21hbGw+PC9zcGFuPjwvYnV0dG9uPgogIDxidXR0
b24gY2xhc3M9YmlnYnRuIGlkPWJ0bl9jc2ZiIG9uY2xpY2s9ImNtZCgnc3RhcnRfY3NmYicpIj48
c3BhbiBjbGFzcz1pYz7ilrY8L3NwYW4+PHNwYW4+TFRFICsgR1NNPHNtYWxsIGlkPWNzZmJfc3Vi
PkludGVybmV0ICsgQW5ydWZlIChDU0ZCKTwvc21hbGw+PC9zcGFuPjwvYnV0dG9uPgogIDxidXR0
b24gY2xhc3M9ImJpZ2J0biBzdG9wIiBvbmNsaWNrPSJjbWQoJ3N0b3AnKSI+4pagIFN0b3BwZW48
L2J1dHRvbj4KIDwvZGl2PgoKIDxkaXYgY2xhc3M9dGFicz4KICA8YnV0dG9uIGNsYXNzPSJ0YWIg
c2VsIiBkYXRhLXQ9c3RldWVydW5nIG9uY2xpY2s9InRhYignc3RldWVydW5nJykiPlN0ZXVlcnVu
ZzwvYnV0dG9uPgogIDxidXR0b24gY2xhc3M9dGFiIGRhdGEtdD1nc20gb25jbGljaz0idGFiKCdn
c20nKSI+R1NNIMK3IDJHPC9idXR0b24+CiAgPGJ1dHRvbiBjbGFzcz10YWIgZGF0YS10PWx0ZSBv
bmNsaWNrPSJ0YWIoJ2x0ZScpIj5MVEUgwrcgNEc8L2J1dHRvbj4KICA8YnV0dG9uIGNsYXNzPXRh
YiBkYXRhLXQ9c2ltcyBvbmNsaWNrPSJ0YWIoJ3NpbXMnKSI+U0lNcyAmIE51bW1lcm48L2J1dHRv
bj4KICA8YnV0dG9uIGNsYXNzPXRhYiBkYXRhLXQ9cHJvZmlsIG9uY2xpY2s9InRhYigncHJvZmls
JykiPlNJTS1Qcm9maWw8L2J1dHRvbj4KICA8YnV0dG9uIGNsYXNzPXRhYiBkYXRhLXQ9bG9nIG9u
Y2xpY2s9InRhYignbG9nJykiPlByb3Rva29sbDwvYnV0dG9uPgogPC9kaXY+CgogPGRpdiBjbGFz
cz0icGFuZWwgc2VsIiBpZD1wLXN0ZXVlcnVuZz4KICA8ZGl2IGNsYXNzPWdyaWQ+CiAgIDxkaXYg
Y2xhc3M9Y2FyZD4KICAgIDxoMj5TdGF0dXM8L2gyPgogICAgPGRpdiBjbGFzcz1mcmVxYm94IHN0
eWxlPW1hcmdpbi10b3A6MTJweD4KICAgICA8ZGl2PjxkaXYgY2xhc3M9YmlnIGlkPWZyZXEyPuKA
kzwvZGl2PjxkaXYgY2xhc3M9c20gaWQ9ZnJlcXN1Yj48L2Rpdj48L2Rpdj4KICAgICA8ZGl2IHN0
eWxlPXRleHQtYWxpZ246cmlnaHQ+PGRpdiBjbGFzcz1iaWcgaWQ9dGVjaDI+YXVzPC9kaXY+PGRp
diBjbGFzcz1zbSBpZD1zdGF0ZXN1Yj48L2Rpdj48L2Rpdj4KICAgIDwvZGl2PgogICAgPGRpdiBj
bGFzcz1oaW50IGlkPXVwdGltZWhpbnQ+PC9kaXY+CiAgICA8ZGl2IGNsYXNzPWhpbnQgaWQ9ZGV2
aGludD48L2Rpdj4KICAgIDxkaXYgY2xhc3M9aGludCBpZD1jbGFzaCBzdHlsZT1jb2xvcjp2YXIo
LS1lcnIpPjwvZGl2PgogICA8L2Rpdj4KICAgPGRpdiBjbGFzcz1jYXJkPgogICAgPGgyPkZ1bmst
SGFyZHdhcmU8L2gyPgogICAgPHAgY2xhc3M9c3ViPkplIE5ldHogZWluIGVpZ2VuZXIgTGltZVNE
Ui4gRsO8ciDigJ5MVEUgKyBHU03igJwgendlaSB2ZXJzY2hpZWRlbmUgd8OkaGxlbi48L3A+CiAg
ICA8bGFiZWw+TGltZVNEUiBmw7xyIEdTTSAoMkcpPC9sYWJlbD48c2VsZWN0IGlkPUdTTV9ERVY+
PC9zZWxlY3Q+CiAgICA8bGFiZWw+TGltZVNEUiBmw7xyIExURSAoNEcpPC9sYWJlbD48c2VsZWN0
IGlkPUxURV9ERVY+PC9zZWxlY3Q+CiAgICA8ZGl2IHN0eWxlPWRpc3BsYXk6ZmxleDtnYXA6OHB4
O2ZsZXgtd3JhcDp3cmFwPgogICAgIDxidXR0b24gY2xhc3M9YnRuIG9uY2xpY2s9InNhdmUoWydH
U01fREVWJywnTFRFX0RFViddKSI+U3BlaWNoZXJuPC9idXR0b24+CiAgICAgPGJ1dHRvbiBjbGFz
cz0iYnRuIHNlYyIgb25jbGljaz0iY21kKCdsaW1lX3NjYW4nKSI+TmV1IHN1Y2hlbjwvYnV0dG9u
PgogICAgPC9kaXY+CiAgICA8ZGl2IGNsYXNzPWhpbnQgaWQ9bGltZWxpc3Q+PC9kaXY+CiAgIDwv
ZGl2PgogICA8ZGl2IGNsYXNzPWNhcmQ+CiAgICA8aDI+TmV0ei1JZGVudGl0w6R0PC9oMj4KICAg
IDxwIGNsYXNzPXN1Yj5HaWx0IGbDvHIgR1NNIHVuZCBMVEUuIE51ciBUZXN0a2VubnVuZyAwMDEv
eHggb2RlciBQcml2YXRrZW5udW5nIDk5OS94eC48L3A+CiAgICA8ZGl2IGNsYXNzPXJvdz4KICAg
ICA8ZGl2PjxsYWJlbD5NQ0M8L2xhYmVsPjxpbnB1dCBpZD1NQ0MgaW5wdXRtb2RlPW51bWVyaWM+
PC9kaXY+CiAgICAgPGRpdj48bGFiZWw+TU5DPC9sYWJlbD48aW5wdXQgaWQ9TU5DIGlucHV0bW9k
ZT1udW1lcmljPjwvZGl2PgogICAgPC9kaXY+CiAgICA8ZGl2IGNsYXNzPXJvdz4KICAgICA8ZGl2
PjxsYWJlbD5OZXR6bmFtZSAobGFuZyk8L2xhYmVsPjxpbnB1dCBpZD1ORVROQU1FPjwvZGl2Pgog
ICAgIDxkaXY+PGxhYmVsPk5ldHpuYW1lIChrdXJ6KTwvbGFiZWw+PGlucHV0IGlkPU5FVE5BTUVf
U0hPUlQ+PC9kaXY+CiAgICA8L2Rpdj4KICAgIDxsYWJlbD5BbmJpZXRlcm5hbWUgKFNQTiwgbWF4
LiAxNiBaZWljaGVuKTwvbGFiZWw+PGlucHV0IGlkPVNQTiBtYXhsZW5ndGg9MTY+CiAgICA8ZGl2
IGNsYXNzPXN3PjxkaXYgY2xhc3M9dD5OSVRaIHNlbmRlbjxzbWFsbD5OZXR6bmFtZSwgVWhyemVp
dCB1bmQgWmVpdHpvbmUgKDxzcGFuIGlkPXR6PuKAkzwvc3Bhbj4pIGJlaW0gRWluYnVjaGVuPC9z
bWFsbD48L2Rpdj4KICAgICA8bGFiZWwgY2xhc3M9c3dpdGNoPjxpbnB1dCB0eXBlPWNoZWNrYm94
IGlkPU5JVFo+PHNwYW4gY2xhc3M9c2xpZGVyPjwvc3Bhbj48L2xhYmVsPjwvZGl2PgogICAgPGJ1
dHRvbiBjbGFzcz0iYnRuIHNlYyIgb25jbGljaz0ic2F2ZShbJ01DQycsJ01OQycsJ05FVE5BTUUn
LCdORVROQU1FX1NIT1JUJywnU1BOJywnTklUWiddKSI+U3BlaWNoZXJuPC9idXR0b24+CiAgICA8
cCBjbGFzcz1oaW50PkRhbWl0IGRhcyBpUGhvbmUgZGFzIE5ldHogYWxzIDxiPkhlaW1uZXR6PC9i
PiBzaWVodCAoa2VpbiBSb2FtaW5nKSwgbXVzcyBkaWUgSU1TSSBkZXIgZVNJTSBtaXQgTUNDK01O
QyBiZWdpbm5lbjogPGIgY2xhc3M9dGFnIGlkPWhwbG1uPuKAkzwvYj7igKY8L3A+CiAgIDwvZGl2
PgogIDwvZGl2PgogPC9kaXY+CgogPGRpdiBjbGFzcz1wYW5lbCBpZD1wLWdzbT4KICA8ZGl2IGNs
YXNzPWdyaWQ+CiAgIDxkaXYgY2xhc3M9Y2FyZD4KICAgIDxoMj5HU00tRnVuazwvaDI+CiAgICA8
ZGl2IGNsYXNzPXJvdyBzdHlsZT1hbGlnbi1pdGVtczplbmQ+CiAgICAgPGRpdj48bGFiZWw+QVJG
Q048L2xhYmVsPjxpbnB1dCBpZD1HU01fQVJGQ04gb25pbnB1dD11cGRhdGVGcmVxKCk+PC9kaXY+
CiAgICAgPGRpdiBjbGFzcz1mcmVxYm94PjxkaXY+PGRpdiBjbGFzcz1iaWcgaWQ9Z3NtX21oej7i
gJM8L2Rpdj48ZGl2IGNsYXNzPXNtIGlkPWdzbV9iYW5kPjwvZGl2PjwvZGl2PjwvZGl2PgogICAg
PC9kaXY+CiAgICA8ZGl2IGNsYXNzPWhpbnQ+MeKAkzEyNCA9IEdTTTkwMCDCtyA1MTLigJM4ODUg
PSBEQ1MxODAwPC9kaXY+CiAgICA8ZGl2IGNsYXNzPXJvdz48ZGl2PjxsYWJlbD5UWC1HYWluPC9s
YWJlbD48aW5wdXQgaWQ9R1NNX1RYX0dBSU4+PC9kaXY+CiAgICAgPGRpdj48bGFiZWw+UlgtR2Fp
biAoMOKAkzUwKTwvbGFiZWw+PGlucHV0IGlkPUdTTV9SWF9HQUlOPjwvZGl2PjwvZGl2PgogICAg
PGRpdiBjbGFzcz1oaW50PlJYLUdhaW4gaG9jaCA9IGVtcGZpbmRsaWNoZXJlciBFbXBmYW5nICh3
aWNodGlnIGbDvHIgRURHRS1VcGxpbmspLjwvZGl2PgogICAgPGJ1dHRvbiBjbGFzcz1idG4gb25j
bGljaz0ic2F2ZShbJ0dTTV9BUkZDTicsJ0dTTV9UWF9HQUlOJywnR1NNX1JYX0dBSU4nXSkiPlNw
ZWljaGVybjwvYnV0dG9uPgogICA8L2Rpdj4KICAgPGRpdiBjbGFzcz1jYXJkPgogICAgPGgyPkdT
TS1PcHRpb25lbjwvaDI+CiAgICA8ZGl2IGNsYXNzPSJzdyBmaXJzdCI+PGRpdiBjbGFzcz10Pk9m
ZmVuZSBBbm1lbGR1bmc8c21hbGw+amVkZSBTSU0gd2lyZCBlaW5nZWJ1Y2h0PC9zbWFsbD48L2Rp
dj4KICAgICA8bGFiZWwgY2xhc3M9c3dpdGNoPjxpbnB1dCB0eXBlPWNoZWNrYm94IGlkPUdTTV9P
UEVOPjxzcGFuIGNsYXNzPXNsaWRlcj48L3NwYW4+PC9sYWJlbD48L2Rpdj4KICAgIDxkaXYgY2xh
c3M9c3c+PGRpdiBjbGFzcz10PkVER0UgLyBHUFJTLURhdGVuPHNtYWxsPlBha2V0ZGF0ZW4gKHBj
dS9zZ3NuL2dnc24pPC9zbWFsbD48L2Rpdj4KICAgICA8bGFiZWwgY2xhc3M9c3dpdGNoPjxpbnB1
dCB0eXBlPWNoZWNrYm94IGlkPUdTTV9EQVRBPjxzcGFuIGNsYXNzPXNsaWRlcj48L3NwYW4+PC9s
YWJlbD48L2Rpdj4KICAgIDxkaXYgY2xhc3M9c3c+PGRpdiBjbGFzcz10PlNJUC1UcnVuayB6dSBB
c3RlcmlzazxzbWFsbD5BbnJ1ZmUgaW5zIFZvSVAvRmVzdG5ldHo8L3NtYWxsPjwvZGl2PgogICAg
IDxsYWJlbCBjbGFzcz1zd2l0Y2g+PGlucHV0IHR5cGU9Y2hlY2tib3ggaWQ9R1NNX1NJUD48c3Bh
biBjbGFzcz1zbGlkZXI+PC9zcGFuPjwvbGFiZWw+PC9kaXY+CiAgICA8bGFiZWw+U0lQLVBlZXIg
KEFzdGVyaXNrLUlQKTwvbGFiZWw+PGlucHV0IGlkPUdTTV9TSVBfUEVFUj4KICAgIDxsYWJlbD5T
SVAtTG9jYWwtSVAgKGxlZXIgPSBhdXRvbWF0aXNjaCk8L2xhYmVsPjxpbnB1dCBpZD1HU01fU0lQ
X0xPQ0FMPgogICAgPGJ1dHRvbiBjbGFzcz1idG4gb25jbGljaz0ic2F2ZShbJ0dTTV9PUEVOJywn
R1NNX0RBVEEnLCdHU01fU0lQJywnR1NNX1NJUF9QRUVSJywnR1NNX1NJUF9MT0NBTCddKSI+U3Bl
aWNoZXJuPC9idXR0b24+CiAgIDwvZGl2PgogICA8ZGl2IGNsYXNzPWNhcmQ+CiAgICA8aDI+QmVn
csO8w591bmdzLVNNUzwvaDI+CiAgICA8cCBjbGFzcz1zdWI+U01TIGJlaW0gRWluYnVjaGVuIHVu
ZCBiZWkgTnVtbWVybnZlcmdhYmUuIFBsYXR6aGFsdGVyOiA8Y29kZT57bmV0en08L2NvZGU+LCA8
Y29kZT57bnVtbWVyfTwvY29kZT4sIDxjb2RlPntleHRlcm59PC9jb2RlPi48L3A+CiAgICA8ZGl2
IGNsYXNzPSJzdyBmaXJzdCI+PGRpdiBjbGFzcz10PlNNUyBha3RpdjxzbWFsbD5XaWxsa29tbWVu
ICsgTnVtbWVybi1CZXN0w6R0aWd1bmc8L3NtYWxsPjwvZGl2PgogICAgIDxsYWJlbCBjbGFzcz1z
d2l0Y2g+PGlucHV0IHR5cGU9Y2hlY2tib3ggaWQ9R1NNX1NNUz48c3BhbiBjbGFzcz1zbGlkZXI+
PC9zcGFuPjwvbGFiZWw+PC9kaXY+CiAgICA8bGFiZWw+QWJzZW5kZXItTnVtbWVyPC9sYWJlbD48
aW5wdXQgaWQ9R1NNX1NNU19GUk9NPgogICAgPGxhYmVsPkV4dGVybmUgVm9yd2FobCAoPGNvZGU+
e2V4dGVybn08L2NvZGU+ID0gVm9yd2FobCArIGludGVybmUgTnVtbWVyKTwvbGFiZWw+PGlucHV0
IGlkPUdTTV9TTVNfRVhUUFJFRklYPgogICAgPGxhYmVsPldpbGxrb21tZW5zdGV4dCAoYmVpbSBF
aW5idWNoZW4pPC9sYWJlbD48aW5wdXQgaWQ9R1NNX1NNU19XRUxDT01FPgogICAgPGxhYmVsPkJl
c3TDpHRpZ3VuZyAoYmVpIE51bW1lcm52ZXJnYWJlKTwvbGFiZWw+PGlucHV0IGlkPUdTTV9TTVNf
TlVNQkVSPgogICAgPGJ1dHRvbiBjbGFzcz1idG4gb25jbGljaz0ic2F2ZShbJ0dTTV9TTVMnLCdH
U01fU01TX0ZST00nLCdHU01fU01TX0VYVFBSRUZJWCcsJ0dTTV9TTVNfV0VMQ09NRScsJ0dTTV9T
TVNfTlVNQkVSJ10pIj5TcGVpY2hlcm48L2J1dHRvbj4KICAgIDxwIGNsYXNzPWhpbnQ+QmVncsO8
w591bmcgd2lyZCBqZSBOZXR6LVN0YXJ0IGVpbm1hbCBwcm8gU0lNIGdlc2VuZGV0ICh3aXJrdCBz
b2ZvcnQpLjwvcD4KICAgIDxkaXYgc3R5bGU9ImJvcmRlci10b3A6MXB4IHNvbGlkIHZhcigtLWxp
bmUpO21hcmdpbjoxNHB4IDAiPjwvZGl2PgogICAgPGRpdiBjbGFzcz1yb3c+PGRpdj48bGFiZWw+
VGVzdDogSU1TSTwvbGFiZWw+PGlucHV0IGlkPXNtc190ZXN0X2ltc2k+PC9kaXY+CiAgICAgPGRp
dj48bGFiZWw+VGV4dCAobGVlciA9IFdpbGxrb21tZW5zdGV4dCk8L2xhYmVsPjxpbnB1dCBpZD1z
bXNfdGVzdF90ZXh0PjwvZGl2PjwvZGl2PgogICAgPGJ1dHRvbiBjbGFzcz0iYnRuIHNlYyIgb25j
bGljaz0ic21zdGVzdCgpIj5UZXN0LVNNUyBzZW5kZW48L2J1dHRvbj4KICAgIDxwIGNsYXNzPWhp
bnQ+U2VuZGV0IHNvZm9ydCBhbiBkaWUgSU1TSSDigJMgYXVjaCB3ZW5uIOKAnlNNUyBha3RpdiIg
YXVzIGlzdC4gR1NNIG11c3MgbGF1ZmVuLjwvcD4KICAgPC9kaXY+CiAgPC9kaXY+CiAgPHAgY2xh
c3M9aGludD5GdW5rLS9PcHRpb25zLcOEbmRlcnVuZ2VuIHdpcmtlbiBiZWltIG7DpGNoc3RlbiBH
U00tU3RhcnQuPC9wPgogPC9kaXY+CgogPGRpdiBjbGFzcz1wYW5lbCBpZD1wLWx0ZT4KICA8ZGl2
IGNsYXNzPWdyaWQ+CiAgIDxkaXYgY2xhc3M9Y2FyZD4KICAgIDxoMj5MVEUtRnVuazwvaDI+CiAg
ICA8ZGl2IGNsYXNzPXJvdyBzdHlsZT1hbGlnbi1pdGVtczplbmQ+CiAgICAgPGRpdj48bGFiZWw+
RUFSRkNOPC9sYWJlbD48aW5wdXQgaWQ9TFRFX0VBUkZDTiBvbmlucHV0PXVwZGF0ZUZyZXEoKT48
L2Rpdj4KICAgICA8ZGl2IGNsYXNzPWZyZXFib3g+PGRpdj48ZGl2IGNsYXNzPWJpZyBpZD1sdGVf
bWh6PuKAkzwvZGl2PjxkaXYgY2xhc3M9c20gaWQ9bHRlX2JhbmQ+PC9kaXY+PC9kaXY+PC9kaXY+
CiAgICA8L2Rpdj4KICAgIDxsYWJlbD5CYW5kYnJlaXRlIChQUkIpPC9sYWJlbD48c2VsZWN0IGlk
PUxURV9OUFJCPgogICAgIDxvcHRpb24gdmFsdWU9Nj42IMK3IDEuNCBNSHo8L29wdGlvbj48b3B0
aW9uIHZhbHVlPTE1PjE1IMK3IDMgTUh6PC9vcHRpb24+CiAgICAgPG9wdGlvbiB2YWx1ZT0yNT4y
NSDCtyA1IE1Iejwvb3B0aW9uPjxvcHRpb24gdmFsdWU9NTA+NTAgwrcgMTAgTUh6PC9vcHRpb24+
CiAgICAgPG9wdGlvbiB2YWx1ZT03NT43NSDCtyAxNSBNSHo8L29wdGlvbj48b3B0aW9uIHZhbHVl
PTEwMD4xMDAgwrcgMjAgTUh6PC9vcHRpb24+PC9zZWxlY3Q+CiAgICA8ZGl2IGNsYXNzPWhpbnQ+
U2Nod2FjaGUgSGFyZHdhcmUgKFBpKToga2xlaW4gd8OkaGxlbiAoNuKAkzI1KS48L2Rpdj4KICAg
IDxidXR0b24gY2xhc3M9YnRuIG9uY2xpY2s9InNhdmUoWydMVEVfRUFSRkNOJywnTFRFX05QUkIn
XSkiPlNwZWljaGVybjwvYnV0dG9uPgogICA8L2Rpdj4KICAgPGRpdiBjbGFzcz1jYXJkPgogICAg
PGgyPkxURS1QYXJhbWV0ZXI8L2gyPgogICAgPGRpdiBjbGFzcz1yb3c+PGRpdj48bGFiZWw+VFgt
R2FpbjwvbGFiZWw+PGlucHV0IGlkPUxURV9UWF9HQUlOPjwvZGl2PgogICAgIDxkaXY+PGxhYmVs
PlJYLUdhaW48L2xhYmVsPjxpbnB1dCBpZD1MVEVfUlhfR0FJTj48L2Rpdj48L2Rpdj4KICAgIDxs
YWJlbD5BUE48L2xhYmVsPjxpbnB1dCBpZD1MVEVfQVBOPgogICAgPGJ1dHRvbiBjbGFzcz1idG4g
b25jbGljaz0ic2F2ZShbJ0xURV9UWF9HQUlOJywnTFRFX1JYX0dBSU4nLCdMVEVfQVBOJ10pIj5T
cGVpY2hlcm48L2J1dHRvbj4KICAgIDxwIGNsYXNzPWhpbnQ+TFRFIGJyYXVjaHQgU0lNcyBtaXQg
S2kvT1BjIChUYWIg4oCeU0lNc+KAnCkuIEtlcm46IE9wZW41R1MsIEhhbmR5LU5ldHogMTAuNDUu
MC4wLzE2IG1pdCBOQVQgaW5zIEludGVybmV0LiBCZWkg4oCeTFRFICsgR1NN4oCcIGRhcmYgZGll
IEdTTS1GcmVxdWVueiBuaWNodCBpbSBMVEUtS2FuYWwgbGllZ2VuLjwvcD4KICAgPC9kaXY+CiAg
PC9kaXY+CiA8L2Rpdj4KCiA8ZGl2IGNsYXNzPXBhbmVsIGlkPXAtc2ltcz4KICA8ZGl2IGNsYXNz
PSJjYXJkIiBzdHlsZT0ibWFyZ2luLWJvdHRvbToxNnB4Ij4KICAgPGgyPlNJTS1EYXRlbiBlcnpl
dWdlbjwvaDI+CiAgIDxwIGNsYXNzPXN1Yj5Gw7xyIGVpZ2VuZSBlU0lNLVByb2ZpbGUgKHouJm5i
c3A7Qi4gc2ltbGVzc2x5KTogSU1TSSBwYXNzZW5kIHp1ciBLZW5udW5nLCB6dWbDpGxsaWdlIFNj
aGzDvHNzZWwgKEtpLCBPUCDihpIgT1BjIG5hY2ggTWlsZW5hZ2UpLCBJQ0NJRCBtaXQgUHLDvGZ6
aWZmZXIsIFBJTi9QVUsvQURNLiBCbGVpYnQgbnVyIGltIEJyb3dzZXIsIGJpcyBkdSBlcyDDvGJl
cm5pbW1zdC48L3A+CiAgIDxkaXYgY2xhc3M9cm93Mz4KICAgIDxkaXY+PGxhYmVsPkFuemFobCAo
MeKAkzUwKTwvbGFiZWw+PGlucHV0IGlkPWdlbl9uIHR5cGU9bnVtYmVyIG1pbj0xIG1heD01MCB2
YWx1ZT0xPjwvZGl2PgogICAgPGRpdj48bGFiZWw+RXJzdGUgUnVmbnVtbWVyIChsZWVyID0ga2Vp
bmUpPC9sYWJlbD48aW5wdXQgaWQ9Z2VuX25yIGlucHV0bW9kZT1udW1lcmljIHBsYWNlaG9sZGVy
PSJ6LiBCLiA5MjAxIj48L2Rpdj4KICAgIDxkaXY+PGxhYmVsPklDQ0lELVByw6RmaXggKGxlZXIg
PSA4OStNQ0MrTU5DKTwvbGFiZWw+PGlucHV0IGlkPWdlbl9pY2NpZCBpbnB1dG1vZGU9bnVtZXJp
Yz48L2Rpdj4KICAgPC9kaXY+CiAgIDxkaXYgc3R5bGU9ZGlzcGxheTpmbGV4O2dhcDo4cHg7Zmxl
eC13cmFwOndyYXA+CiAgICA8YnV0dG9uIGNsYXNzPWJ0biBvbmNsaWNrPSJzaW1nZW4oKSI+RXJ6
ZXVnZW48L2J1dHRvbj4KICAgIDxidXR0b24gY2xhc3M9ImJ0biBzZWMiIGlkPWdlbl90YWtlIG9u
Y2xpY2s9ImdlbnRha2UoKSIgZGlzYWJsZWQ+QWxsZSBpbiBwS09NIMO8YmVybmVobWVuPC9idXR0
b24+CiAgICA8YnV0dG9uIGNsYXNzPSJidG4gc2VjIiBpZD1nZW5fY3N2IG9uY2xpY2s9ImdlbmRs
KCdjc3YnKSIgZGlzYWJsZWQ+Q1NWPC9idXR0b24+CiAgICA8YnV0dG9uIGNsYXNzPSJidG4gc2Vj
IiBpZD1nZW5fanNvbiBvbmNsaWNrPSJnZW5kbCgnanNvbicpIiBkaXNhYmxlZD5KU09OPC9idXR0
b24+CiAgIDwvZGl2PgogICA8ZGl2IGNsYXNzPWdlbndyYXA+PHRhYmxlIGNsYXNzPWVmIGlkPWdl
bl90YWI+PC90YWJsZT48L2Rpdj4KICAgPHAgY2xhc3M9aGludD5BTUYgODAwMCwgU1FOLVN0YXJ0
IDAwMDAwMDAwMDAyMCwgQWxnb3JpdGhtdXMgTWlsZW5hZ2UuIEltIGVTSU0tUHJvZmlsIGRpZSBJ
TVNJLCBLaSB1bmQgT1BjIChvZGVyIE9QKSBlaW50cmFnZW47IGRhenUgU1BOL1BOTi9PUEwgYXVz
IGRlbSBUYWIg4oCeU0lNLVByb2ZpbOKAnC48L3A+CiAgPC9kaXY+CiAgPGRpdiBjbGFzcz1ncmlk
PgogICA8ZGl2IGNsYXNzPWNhcmQ+CiAgICA8aDI+U0lNIGVpbnRyYWdlbjwvaDI+CiAgICA8cCBj
bGFzcz1zdWI+RWlubWFsIGVpbnRyYWdlbiDigJMgcEtPTSBzY2hyZWlidCBzaWUgYXV0b21hdGlz
Y2ggaW5zIEdTTS1ITFIgdW5kIGluIGRlbiBMVEUtSFNTLjwvcD4KICAgIDxkaXYgY2xhc3M9cm93
PjxkaXY+PGxhYmVsPklNU0k8L2xhYmVsPjxpbnB1dCBpZD1zaW1faW1zaSBpbnB1dG1vZGU9bnVt
ZXJpYz48L2Rpdj48ZGl2PjxsYWJlbD5SdWZudW1tZXI8L2xhYmVsPjxpbnB1dCBpZD1zaW1fbnIg
aW5wdXRtb2RlPW51bWVyaWM+PC9kaXY+PC9kaXY+CiAgICA8ZGl2IGNsYXNzPXJvdz48ZGl2Pjxs
YWJlbD5LaSAoMzIgSGV4KTwvbGFiZWw+PGlucHV0IGlkPXNpbV9raSBhdXRvY29tcGxldGU9b2Zm
PjwvZGl2PjxkaXY+PGxhYmVsPk9QYyAoMzIgSGV4KTwvbGFiZWw+PGlucHV0IGlkPXNpbV9vcGMg
YXV0b2NvbXBsZXRlPW9mZj48L2Rpdj48L2Rpdj4KICAgIDxidXR0b24gY2xhc3M9ImJ0biBzbSIg
b25jbGljaz0ic2ltYWRkKCkiPlNJTSBzcGVpY2hlcm48L2J1dHRvbj4KICAgIDxkaXYgc3R5bGU9
bWFyZ2luLXRvcDoxMnB4IGlkPXNpbXM+PC9kaXY+CiAgIDwvZGl2PgogICA8ZGl2IGNsYXNzPWNh
cmQ+CiAgICA8aDI+RWluZ2VidWNodGUgSGFuZHlzPC9oMj4KICAgIDxwIGNsYXNzPXN1Yj5Ba3R1
ZWxsIGltIFNwcmFjaG5ldHogKE1TQykgYW5nZW1lbGRldCDigJMgYmVpIOKAnkxURSArIEdTTeKA
nCBhdWNoIMO8YmVyIExURS9TR3MuPC9wPgogICAgPGRpdiBpZD1hdHRhY2hlZD48L2Rpdj4KICAg
PC9kaXY+CiAgIDxkaXYgY2xhc3M9Y2FyZD4KICAgIDxoMj5OdW1tZXIgZGF1ZXJoYWZ0IHp1d2Vp
c2VuPC9oMj4KICAgIDxwIGNsYXNzPXN1Yj5BdWNoIGbDvHIgb2ZmZW4gYW5nZW1lbGRldGUgR1NN
LVNJTXMgb2huZSBLaSDigJMgw7xiZXJsZWJ0IE5ldXN0YXJ0cy48L3A+CiAgICA8ZGl2IGNsYXNz
PXJvdz48ZGl2PjxsYWJlbD5JTVNJPC9sYWJlbD48aW5wdXQgaWQ9Z251bV9pbXNpPjwvZGl2Pjxk
aXY+PGxhYmVsPlJ1Zm51bW1lcjwvbGFiZWw+PGlucHV0IGlkPWdudW1fbnI+PC9kaXY+PC9kaXY+
CiAgICA8YnV0dG9uIGNsYXNzPSJidG4gc20iIG9uY2xpY2s9InNpbW5yKCkiPlp1d2Vpc2VuPC9i
dXR0b24+CiAgICA8ZGl2IHN0eWxlPW1hcmdpbi10b3A6MTJweCBpZD1nc21fbnVtYmVycz48L2Rp
dj4KICAgPC9kaXY+CiAgPC9kaXY+CiA8L2Rpdj4KCiA8ZGl2IGNsYXNzPXBhbmVsIGlkPXAtcHJv
ZmlsPgogIDxkaXYgY2xhc3M9Y2FyZD4KICAgPGgyPldlcnRlIGbDvHIgZGFzIGVTSU0tUHJvZmls
PC9oMj4KICAgPHAgY2xhc3M9c3ViPk9QTCwgUE5OIHVuZCBTUE4gc2luZCBEYXRlaWVuIDxiPmF1
ZiBkZXIgU0lNPC9iPiDigJMgZGFzIE5ldHoga2FubiBzaWUgbmljaHQgc2V0emVuLiBEaWVzZSBX
ZXJ0ZSBwYXNzZW4genUgS2VubnVuZyB1bmQgTmV0em5hbWUgb2JlbiB1bmQgd2VyZGVuIGltIGVT
SU0tUHJvZmlsICh6LiZuYnNwO0IuIHNpbWxlc3NseSkgZWluZ2V0cmFnZW4uIE5JVFogc2NoaWNr
dCBwS09NIHNlbGJzdC48L3A+CiAgIDx0YWJsZSBjbGFzcz1lZj4KICAgIDx0cj48dGg+RGF0ZWk8
L3RoPjx0aD5JbmhhbHQ8L3RoPjx0aD5XZXJ0IChIZXgpPC90aD48L3RyPgogICAgPHRyPjx0ZD48
Yj5TUE48L2I+PGJyPjxzcGFuIGNsYXNzPW11dD5FRiA2RjQ2PC9zcGFuPjwvdGQ+PHRkIGlkPWVm
X3Nwbl90PjwvdGQ+PHRkPjxjb2RlIGlkPWVmX3Nwbj48L2NvZGU+PC90ZD48L3RyPgogICAgPHRy
Pjx0ZD48Yj5QTk48L2I+PGJyPjxzcGFuIGNsYXNzPW11dD5FRiA2RkM1LCBFaW50cmFnIDE8L3Nw
YW4+PC90ZD48dGQgaWQ9ZWZfcG5uX3Q+PC90ZD48dGQ+PGNvZGUgaWQ9ZWZfcG5uPjwvY29kZT48
L3RkPjwvdHI+CiAgICA8dHI+PHRkPjxiPk9QTDwvYj48YnI+PHNwYW4gY2xhc3M9bXV0PkVGIDZG
QzYsIEVpbnRyYWcgMTwvc3Bhbj48L3RkPjx0ZCBpZD1lZl9vcGxfdD48L3RkPjx0ZD48Y29kZSBp
ZD1lZl9vcGw+PC9jb2RlPjwvdGQ+PC90cj4KICAgIDx0cj48dGQ+PGI+SFBMTU48L2I+PGJyPjxz
cGFuIGNsYXNzPW11dD5JTVNJLUFuZmFuZzwvc3Bhbj48L3RkPjx0ZD5IZWltbmV0ei1LZW5udW5n
PC90ZD48dGQ+PGNvZGUgaWQ9ZWZfaHBsbW4+PC9jb2RlPjwvdGQ+PC90cj4KICAgPC90YWJsZT4K
ICAgPHAgY2xhc3M9aGludD5EYXRlbnPDpHR6ZSBiZWkgZmVzdGVyIEzDpG5nZSBtaXQgPGNvZGU+
RkY8L2NvZGU+IGF1ZmbDvGxsZW4uIEluIGRlciBVU0lNLURpZW5zdHRhYmVsbGUgKFVTVCkgbcO8
c3NlbiBkaWUgRGllbnN0ZSA8Yj4xNzwvYj4gKFNQTiksIDxiPjQ1PC9iPiAoUE5OKSB1bmQgPGI+
NDY8L2I+IChPUEwpIGFrdGl2IHNlaW4uIMOEbmRlcm4gc2ljaCBLZW5udW5nIG9kZXIgTmFtZSwg
ZGllIFdlcnRlIGhpZXIgbmV1IMO8YmVybmVobWVuLjwvcD4KICA8L2Rpdj4KIDwvZGl2PgoKIDxk
aXYgY2xhc3M9cGFuZWwgaWQ9cC1sb2c+CiAgPGRpdiBjbGFzcz1jYXJkPgogICA8ZGl2IGNsYXNz
PXRvb2xiYXI+PGgyIHN0eWxlPW1hcmdpbjowPlByb3Rva29sbDwvaDI+PGlucHV0IGlkPWxvZ2Zp
bHRlciBwbGFjZWhvbGRlcj0iZmlsdGVybuKApiB6LkIuIEdQUlMsIFRCRiwgZXJyb3IiIG9uaW5w
dXQ9cmVuZGVybG9nKCk+PHNwYW4gY2xhc3M9YmFkZ2UgaWQ9bG9nY291bnQ+PC9zcGFuPjwvZGl2
PgogICA8ZGl2IGNsYXNzPWxvZyBpZD1sb2c+PC9kaXY+CiAgPC9kaXY+CiA8L2Rpdj4KPC9kaXY+
CjxzY3JpcHQ+CmxldCBTPXt9Owphc3luYyBmdW5jdGlvbiBhcGkoYyxiKXtjb25zdCByPWF3YWl0
IGZldGNoKCcvYXBpLycrYyx7bWV0aG9kOidQT1NUJyxoZWFkZXJzOnsnQ29udGVudC1UeXBlJzon
YXBwbGljYXRpb24vanNvbid9LGJvZHk6SlNPTi5zdHJpbmdpZnkoYnx8e30pfSk7cmV0dXJuIHIu
anNvbigpO30KZnVuY3Rpb24gJChpKXtyZXR1cm4gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoaSk7
fQpmdW5jdGlvbiBlc2Mocyl7cmV0dXJuIFN0cmluZyhzPT1udWxsPycnOnMpLnJlcGxhY2UoL1sm
PD4iJ10vZyxjPT4oeycmJzonJmFtcDsnLCc8JzonJmx0OycsJz4nOicmZ3Q7JywnIic6JyZxdW90
OycsIiciOicmIzM5Oyd9W2NdKSk7fQpmdW5jdGlvbiBjbWQoYyl7aWYoYy5zdGFydHNXaXRoKCdz
dGFydCcpKSQoJ21zZycpLnRleHRDb250ZW50PSdzdGFydGV04oCmJzthcGkoYykudGhlbihyPT57
aWYoYz09PSdsaW1lX3NjYW4nKWxpbWVLZXk9Jyc7cmVuZGVyKHIpO30pO30KZnVuY3Rpb24gdGFi
KG4pe2RvY3VtZW50LnF1ZXJ5U2VsZWN0b3JBbGwoJy50YWInKS5mb3JFYWNoKHQ9PnQuY2xhc3NM
aXN0LnRvZ2dsZSgnc2VsJyx0LmRhdGFzZXQudD09PW4pKTtkb2N1bWVudC5xdWVyeVNlbGVjdG9y
QWxsKCcucGFuZWwnKS5mb3JFYWNoKHA9PnAuY2xhc3NMaXN0LnRvZ2dsZSgnc2VsJyxwLmlkPT09
J3AtJytuKSk7dHJ5e2xvY2FsU3RvcmFnZS5zZXRJdGVtKCdwa29tX3RhYicsbik7fWNhdGNoKGUp
e319CmZ1bmN0aW9uIHNhdmUoa2V5cyl7bGV0IGI9e307a2V5cy5mb3JFYWNoKGs9PntsZXQgZWw9
JChrKTtiW2tdPWVsLnR5cGU9PT0nY2hlY2tib3gnPyhlbC5jaGVja2VkPycxJzonMCcpOmVsLnZh
bHVlO30pO2FwaSgnc2V0JyxiKS50aGVuKHI9PntmaWxsZWQ9ZmFsc2U7cmVuZGVyKHIpO30pO30K
ZnVuY3Rpb24gc2ltYWRkKCl7YXBpKCdzaW1fYWRkJyx7aW1zaTokKCdzaW1faW1zaScpLnZhbHVl
LGtpOiQoJ3NpbV9raScpLnZhbHVlLG9wYzokKCdzaW1fb3BjJykudmFsdWUsbXNpc2RuOiQoJ3Np
bV9ucicpLnZhbHVlfSkudGhlbihyPT57aWYoIS9hYmVyfHBydWVmZW4vLnRlc3Qoci5tc2d8fCcn
KSl7WydzaW1faW1zaScsJ3NpbV9raScsJ3NpbV9vcGMnLCdzaW1fbnInXS5mb3JFYWNoKGk9PiQo
aSkudmFsdWU9JycpO31yZW5kZXIocik7fSk7fQpmdW5jdGlvbiBzaW1ucigpe2FwaSgnZ3NtX3Np
bV9ucicse2ltc2k6JCgnZ251bV9pbXNpJykudmFsdWUsbXNpc2RuOiQoJ2dudW1fbnInKS52YWx1
ZX0pLnRoZW4ocmVuZGVyKTt9CmZ1bmN0aW9uIHNtc3Rlc3QoKXthcGkoJ3Ntc190ZXN0Jyx7aW1z
aTokKCdzbXNfdGVzdF9pbXNpJykudmFsdWUsdGV4dDokKCdzbXNfdGVzdF90ZXh0JykudmFsdWV9
KS50aGVuKHJlbmRlcik7fQpmdW5jdGlvbiBzaW1kZWwoaSl7aWYoY29uZmlybSgnU0lNICcraSsn
IGF1cyBHU00gdW5kIExURSBsw7ZzY2hlbj8nKSlhcGkoJ3NpbV9kZWwnLHtpbXNpOml9KS50aGVu
KHJlbmRlcik7fQpmdW5jdGlvbiBudW1kZWwoaSl7YXBpKCdnc21fbnVtX2RlbCcse2ltc2k6aX0p
LnRoZW4ocmVuZGVyKTt9CmZ1bmN0aW9uIGdzbUluZm8oYSl7YT0rYXx8MDtsZXQgbT0wLGI9Jyc7
aWYoYT49MSYmYTw9MTI0KXttPTkzNSswLjIqYTtiPSdHU005MDAnO31lbHNlIGlmKGE+PTUxMiYm
YTw9ODg1KXttPTE4MDUuMiswLjIqKGEtNTEyKTtiPSdEQ1MxODAwJzt9cmV0dXJue21oejptP20u
dG9GaXhlZCgxKSsnIE1Ieic6J+KAkycsYmFuZDpifTt9CmZ1bmN0aW9uIGx0ZUluZm8oZSl7ZT0r
ZXx8MDtsZXQgbT0wLGI9MDtpZihlPj0wJiZlPD01OTkpe209MjExMCswLjEqZTtiPTE7fWVsc2Ug
aWYoZT49MTIwMCYmZTw9MTk0OSl7bT0xODA1KzAuMSooZS0xMjAwKTtiPTM7fWVsc2UgaWYoZT49
Mjc1MCYmZTw9MzQ0OSl7bT0yNjIwKzAuMSooZS0yNzUwKTtiPTc7fWVsc2UgaWYoZT49NjE1MCYm
ZTw9NjQ0OSl7bT03OTErMC4xKihlLTYxNTApO2I9MjA7fXJldHVybnttaHo6bT9tLnRvRml4ZWQo
MSkrJyBNSHonOifigJMnLGJhbmQ6Yj8nQmFuZCAnK2I6Jyd9O30KZnVuY3Rpb24gdXBkYXRlRnJl
cSgpe2xldCBnPWdzbUluZm8oJCgnR1NNX0FSRkNOJykudmFsdWUpOyQoJ2dzbV9taHonKS50ZXh0
Q29udGVudD1nLm1oejskKCdnc21fYmFuZCcpLnRleHRDb250ZW50PWcuYmFuZDtsZXQgbD1sdGVJ
bmZvKCQoJ0xURV9FQVJGQ04nKS52YWx1ZSk7JCgnbHRlX21oeicpLnRleHRDb250ZW50PWwubWh6
OyQoJ2x0ZV9iYW5kJykudGV4dENvbnRlbnQ9bC5iYW5kO30KZnVuY3Rpb24gc2V0dihpZCx2KXts
ZXQgZWw9JChpZCk7aWYoIWVsKXJldHVybjtpZihlbC50eXBlPT09J2NoZWNrYm94JyllbC5jaGVj
a2VkPSh2PT09JzEnfHx2PT09dHJ1ZSk7ZWxzZSBlbC52YWx1ZT0odj09bnVsbD8nJzp2KTt9CmNv
bnN0IEZJRUxEUz1bJ01DQycsJ01OQycsJ05FVE5BTUUnLCdORVROQU1FX1NIT1JUJywnU1BOJywn
TklUWicsJ0dTTV9ERVYnLCdMVEVfREVWJywnR1NNX0FSRkNOJywnR1NNX1RYX0dBSU4nLCdHU01f
UlhfR0FJTicsJ0dTTV9TSVBfUEVFUicsJ0dTTV9TSVBfTE9DQUwnLCdHU01fT1BFTicsJ0dTTV9E
QVRBJywnR1NNX1NJUCcsJ0dTTV9TTVMnLCdHU01fU01TX0ZST00nLCdHU01fU01TX0VYVFBSRUZJ
WCcsJ0dTTV9TTVNfV0VMQ09NRScsJ0dTTV9TTVNfTlVNQkVSJywnTFRFX0VBUkZDTicsJ0xURV9O
UFJCJywnTFRFX1RYX0dBSU4nLCdMVEVfUlhfR0FJTicsJ0xURV9BUE4nXTsKbGV0IGZpbGxlZD1m
YWxzZSxsaW1lS2V5PScnOwpmdW5jdGlvbiBsaW1lT3B0aW9ucyhzKXsKIGNvbnN0IEw9cy5saW1l
c3x8W10sYz1zLmNvbmZ8fHt9LGtleT1KU09OLnN0cmluZ2lmeShMKSsoYy5HU01fREVWfHwnJykr
KGMuTFRFX0RFVnx8JycpOwogaWYoa2V5PT09bGltZUtleSlyZXR1cm47bGltZUtleT1rZXk7CiBb
J0dTTV9ERVYnLCdMVEVfREVWJ10uZm9yRWFjaChpZD0+e2NvbnN0IGVsPSQoaWQpLGN1cj1jW2lk
XXx8Jyc7CiAgbGV0IG89JzxvcHRpb24gdmFsdWU9IiI+YXV0b21hdGlzY2g8L29wdGlvbj4nK0wu
bWFwKGQ9Pic8b3B0aW9uIHZhbHVlPSInK2VzYyhkLnNlcmlhbCkrJyI+Jytlc2MoZC5uYW1lKSsn
IMK3ICcrZXNjKGQuc2VyaWFsKSsoZC5tZWRpYT8nIMK3ICcrZXNjKGQubWVkaWEpOicnKSsnPC9v
cHRpb24+Jykuam9pbignJyk7CiAgaWYoY3VyJiYhTC5zb21lKGQ9PmQuc2VyaWFsPT09Y3VyKSlv
Kz0nPG9wdGlvbiB2YWx1ZT0iJytlc2MoY3VyKSsnIj4nK2VzYyhjdXIpKycgKG5pY2h0IGdlZnVu
ZGVuKTwvb3B0aW9uPic7CiAgZWwuaW5uZXJIVE1MPW87ZWwudmFsdWU9Y3VyO30pOwogJCgnbGlt
ZWxpc3QnKS50ZXh0Q29udGVudD1MLmxlbmd0aD9MLmxlbmd0aCsnIExpbWVTRFIgYW5nZXNjaGxv
c3Nlbic6J0tlaW4gTGltZVNEUiBnZWZ1bmRlbiDigJMgVVNCIHByw7xmZW4gdW5kIOKAnk5ldSBz
dWNoZW7igJwuJzsKfQpmdW5jdGlvbiByZWxvYWRGaWVsZHMoKXtjb25zdCBjPVMuY29uZnx8e307
RklFTERTLmZvckVhY2goaz0+e2lmKGRvY3VtZW50LmFjdGl2ZUVsZW1lbnQhPT0kKGspKXNldHYo
ayxjW2tdKTt9KTtmaWxsZWQ9dHJ1ZTt1cGRhdGVGcmVxKCk7fQpmdW5jdGlvbiBmbXQocyl7Y29u
c3QgbT1NYXRoLmZsb29yKHMvNjApLGg9TWF0aC5mbG9vcihtLzYwKTtyZXR1cm4gaD9oKydoICcr
KG0lNjApKydtJzoobT9tKydtICcrKHMlNjApKydzJzpzKydzJyk7fQpmdW5jdGlvbiByZW5kZXJs
b2coKXtjb25zdCBmPSgkKCdsb2dmaWx0ZXInKS52YWx1ZXx8JycpLnRvTG93ZXJDYXNlKCk7bGV0
IEw9KFMubG9nfHxbXSk7aWYoZilMPUwuZmlsdGVyKHg9PngudG9Mb3dlckNhc2UoKS5pbmNsdWRl
cyhmKSk7Y29uc3QgbGc9JCgnbG9nJyk7Y29uc3QgbmVhcj1sZy5zY3JvbGxUb3ArbGcuY2xpZW50
SGVpZ2h0Pj1sZy5zY3JvbGxIZWlnaHQtNDA7bGcudGV4dENvbnRlbnQ9TC5qb2luKCdcbicpOyQo
J2xvZ2NvdW50JykudGV4dENvbnRlbnQ9TC5sZW5ndGgrJyBaZWlsZW4nO2lmKG5lYXIpbGcuc2Ny
b2xsVG9wPWxnLnNjcm9sbEhlaWdodDt9CmZ1bmN0aW9uIHJlbmRlcihzKXtTPXM7bGltZU9wdGlv
bnMocyk7aWYoIWZpbGxlZClyZWxvYWRGaWVsZHMoKTsKIGNvbnN0IHJ1bj1zLnN0YXRlPT09J2xh
ZXVmdCcsdD1zLnRlY2g7CiAkKCdkb3QnKS5jbGFzc05hbWU9J2RvdCAnKyhydW4/J29uJzoocy5z
dGF0ZT09PSdmZWhsZXInPydlcnInOicnKSk7CiAkKCdzdGF0ZScpLnRleHRDb250ZW50PXMuc3Rh
dGU7JCgnbXNnJykudGV4dENvbnRlbnQ9cy5tc2d8fCcnOwogY29uc3QgdGI9JCgndGVjaGJhZGdl
Jyk7aWYodCl7dGIuc3R5bGUuZGlzcGxheT0nJzt0Yi50ZXh0Q29udGVudD10PT09J2NzZmInPydM
VEUrR1NNJzp0LnRvVXBwZXJDYXNlKCk7fWVsc2UgdGIuc3R5bGUuZGlzcGxheT0nbm9uZSc7CiBs
ZXQgZnJlcT0n4oCTJyxmc3ViPScnOwogY29uc3QgZ2Y9cy5nc20ubWh6KycgTUh6JyxsZj1zLmx0
ZS5taHorJyBNSHonOwogaWYodD09PSdsdGUnKXtmcmVxPWxmO2ZzdWI9J0JhbmQgJytzLmx0ZS5i
YW5kKycgwrcgRUFSRkNOICcrcy5sdGUuZWFyZmNuO30KIGVsc2UgaWYodD09PSdnc20nKXtmcmVx
PWdmO2ZzdWI9cy5nc20uYmFuZCsnIMK3IEFSRkNOICcrcy5nc20uYXJmY247fQogZWxzZSBpZih0
PT09J2NzZmInKXtmcmVxPWxmKycgLyAnK2dmO2ZzdWI9J0xURSBCJytzLmx0ZS5iYW5kKycgwrcg
R1NNIEFSRkNOICcrcy5nc20uYXJmY247fQogJCgnZnJlcScpLnRleHRDb250ZW50PWZyZXE7JCgn
ZnJlcTInKS50ZXh0Q29udGVudD1mcmVxOyQoJ2ZyZXFzdWInKS50ZXh0Q29udGVudD1mc3ViOwog
JCgndGVjaDInKS50ZXh0Q29udGVudD10Pyh0PT09J2NzZmInPydMVEUrR1NNJzp0LnRvVXBwZXJD
YXNlKCkpOidhdXMnOyQoJ3N0YXRlc3ViJykudGV4dENvbnRlbnQ9cy5zdGF0ZTsKICQoJ3VwdGlt
ZScpLnRleHRDb250ZW50PXMudXB0aW1lP2ZtdChzLnVwdGltZSk6J+KAkyc7JCgndXB0aW1laGlu
dCcpLnRleHRDb250ZW50PXJ1bj8oJ2zDpHVmdCBzZWl0ICcrZm10KHMudXB0aW1lKSk6Jyc7CiAk
KCdkZXZoaW50JykuaW5uZXJIVE1MPVtzLmRldi5nc20/J0dTTS1GdW5rOiA8Yj4nK2VzYyhzLmRl
di5nc20pKyc8L2I+JzonJyxzLmRldi5sdGU/J0xURS1GdW5rOiA8Yj4nK2VzYyhzLmRldi5sdGUp
Kyc8L2I+JzonJ10uZmlsdGVyKEJvb2xlYW4pLmpvaW4oJzxicj4nKTsKICQoJ2NsYXNoJykudGV4
dENvbnRlbnQ9cy5jbGFzaHx8Jyc7CiBbWydnc20nLCdPc21vY29tJ10sWydsdGUnLCdzcnNSQU4g
KyBPcGVuNUdTJ10sWydjc2ZiJywnSW50ZXJuZXQgKyBBbnJ1ZmUgKENTRkIpJ11dLmZvckVhY2go
KFtrLGRdKT0+eyQoJ2J0bl8nK2spLmNsYXNzTGlzdC50b2dnbGUoJ2FjdGl2ZScsdD09PWspOyQo
aysnX3N1YicpLnRleHRDb250ZW50PXQ9PT1rPydsw6R1ZnQnOmQ7fSk7CiAkKCd0eicpLnRleHRD
b250ZW50PXMudHp8fCfigJMnOwogY29uc3QgZj1zLnNpbWZpbGVzfHx7fTskKCdocGxtbicpLnRl
eHRDb250ZW50PWYuaHBsbW58fCfigJMnOwogJCgnZWZfc3BuJykudGV4dENvbnRlbnQ9Zi5zcG58
fCcnOyQoJ2VmX3Nwbl90JykudGV4dENvbnRlbnQ9J+KAnicrKGYuc3BuX3RleHR8fCcnKSsn4oCc
JzsKICQoJ2VmX3BubicpLnRleHRDb250ZW50PWYucG5ufHwnJzskKCdlZl9wbm5fdCcpLnRleHRD
b250ZW50PSdsYW5nIOKAnicrKGYuZnVsbHx8JycpKyfigJwsIGt1cnog4oCeJysoZi5zaG9ydHx8
JycpKyfigJwnOwogJCgnZWZfb3BsJykudGV4dENvbnRlbnQ9Zi5vcGx8fCcnOyQoJ2VmX29wbF90
JykudGV4dENvbnRlbnQ9J0tlbm51bmcgJysoZi5ocGxtbnx8JycpKycsIGFsbGUgR2ViaWV0ZSDi
hpIgUE5OIDEnOwogJCgnZWZfaHBsbW4nKS50ZXh0Q29udGVudD1mLmhwbG1ufHwnJzsKICQoJ2dz
bV9udW1iZXJzJykuaW5uZXJIVE1MPU9iamVjdC5lbnRyaWVzKHMuZ3NtLm51bWJlcnN8fHt9KS5t
YXAoZT0+JzxkaXYgY2xhc3M9bGlzdHJvdz48c3BhbiBjbGFzcz10YWc+Jytlc2MoZVswXSkrJyDi
hpIgPGI+Jytlc2MoZVsxXSkrJzwvYj48L3NwYW4+PGJ1dHRvbiBjbGFzcz14IG9uY2xpY2s9Im51
bWRlbChcJycrZXNjKGVbMF0pKydcJykiPmzDtnNjaGVuPC9idXR0b24+PC9kaXY+Jykuam9pbign
Jyl8fCc8ZGl2IGNsYXNzPWVtcHR5PmtlaW5lIFp1d2Vpc3VuZ2VuPC9kaXY+JzsKICQoJ2F0dGFj
aGVkJykuaW5uZXJIVE1MPShzLmdzbS5hdHRhY2hlZHx8W10pLm1hcChpPT4nPGRpdiBjbGFzcz1s
aXN0cm93PjxzcGFuIGNsYXNzPXRhZz4nK2VzYyhpKSsnPC9zcGFuPjxzcGFuIGNsYXNzPXRhZz4n
K2VzYygocy5nc20ubnVtYmVyc3x8e30pW2ldfHwnJykrJzwvc3Bhbj48L2Rpdj4nKS5qb2luKCcn
KXx8JzxkaXYgY2xhc3M9ZW1wdHk+a2VpbmUgZWluZ2VidWNodDwvZGl2Pic7CiAkKCdzaW1zJyku
aW5uZXJIVE1MPShzLnNpbXN8fFtdKS5tYXAoeD0+JzxkaXYgY2xhc3M9bGlzdHJvdz48c3BhbiBj
bGFzcz10YWc+Jytlc2MoeC5pbXNpKSsnIMK3IDxiPicrZXNjKHgubXNpc2RuKSsnPC9iPjwvc3Bh
bj48YnV0dG9uIGNsYXNzPXggb25jbGljaz0ic2ltZGVsKFwnJytlc2MoeC5pbXNpKSsnXCcpIj5s
w7ZzY2hlbjwvYnV0dG9uPjwvZGl2PicpLmpvaW4oJycpfHwnPGRpdiBjbGFzcz1lbXB0eT5ub2No
IGtlaW5lIFNJTSBlaW5nZXRyYWdlbjwvZGl2Pic7CiByZW5kZXJsb2coKTsKfQpsZXQgR0VOPVtd
OwpmdW5jdGlvbiBzaW1nZW4oKXthcGkoJ3NpbV9nZW4nLHtjb3VudDokKCdnZW5fbicpLnZhbHVl
LG1zaXNkbjokKCdnZW5fbnInKS52YWx1ZSxpY2NpZDokKCdnZW5faWNjaWQnKS52YWx1ZX0pLnRo
ZW4ocj0+e0dFTj1yLmdlbmVyYXRlZHx8W107Z2VuZHJhdygpO3JlbmRlcihyKTt9KTt9CmNvbnN0
IEdDT0xTPVtbJ2ljY2lkJywnSUNDSUQnXSxbJ2ltc2knLCdJTVNJJ10sWydraScsJ0tpJ10sWydv
cCcsJ09QJ10sWydvcGMnLCdPUGMnXSxbJ21zaXNkbicsJ1J1Zm5yLiddLFsncGluMScsJ1BJTjEn
XSxbJ3B1azEnLCdQVUsxJ10sWydwaW4yJywnUElOMiddLFsncHVrMicsJ1BVSzInXSxbJ2FkbTEn
LCdBRE0xJ11dOwpmdW5jdGlvbiBnZW5kcmF3KCl7Y29uc3QgVD0kKCdnZW5fdGFiJyk7CiBULmlu
bmVySFRNTD1HRU4ubGVuZ3RoPyc8dHI+JytHQ09MUy5tYXAoYz0+Jzx0aD4nK2NbMV0rJzwvdGg+
Jykuam9pbignJykrJzx0aD48L3RoPjwvdHI+JytHRU4ubWFwKChnLGkpPT4nPHRyPicrR0NPTFMu
bWFwKGM9Pic8dGQ+PGNvZGU+Jytlc2MoZ1tjWzBdXSkrJzwvY29kZT48L3RkPicpLmpvaW4oJycp
Kyc8dGQ+PGJ1dHRvbiBjbGFzcz0iYnRuIHNtIHNlYyIgb25jbGljaz0iZ2VudGFrZSgnK2krJyki
PsO8YmVybmVobWVuPC9idXR0b24+PC90ZD48L3RyPicpLmpvaW4oJycpOicnOwogWydnZW5fdGFr
ZScsJ2dlbl9jc3YnLCdnZW5fanNvbiddLmZvckVhY2goaWQ9PiQoaWQpLmRpc2FibGVkPSFHRU4u
bGVuZ3RoKTt9CmFzeW5jIGZ1bmN0aW9uIGdlbnRha2UoaSl7Y29uc3QgTD1pPT09dW5kZWZpbmVk
P0dFTjpbR0VOW2ldXTtsZXQgb2s9MCxsYXN0PW51bGw7CiBmb3IoY29uc3QgZyBvZiBMKXtsYXN0
PWF3YWl0IGFwaSgnc2ltX2FkZCcse2ltc2k6Zy5pbXNpLGtpOmcua2ksb3BjOmcub3BjLG1zaXNk
bjpnLm1zaXNkbn0pO2lmKCEvYWJlcnxwcnVlZmVuLy50ZXN0KGxhc3QubXNnfHwnJykpb2srKzt9
CiBpZihsYXN0KXtyZW5kZXIobGFzdCk7JCgnbXNnJykudGV4dENvbnRlbnQ9b2srJyB2b24gJytM
Lmxlbmd0aCsnIFNJTShzKSBpbiBwS09NIMO8YmVybm9tbWVuJysob2s8TC5sZW5ndGg/JyDigJMg
JytsYXN0Lm1zZzonJyk7fX0KZnVuY3Rpb24gZ2VuZGwoZm10KXtpZighR0VOLmxlbmd0aClyZXR1
cm47bGV0IGRhdGEsdHlwZSxuYW1lPSdwa29tLXNpbXMtJytuZXcgRGF0ZSgpLnRvSVNPU3RyaW5n
KCkuc2xpY2UoMCwxMCk7CiBpZihmbXQ9PT0nanNvbicpe2RhdGE9SlNPTi5zdHJpbmdpZnkoR0VO
LG51bGwsMSk7dHlwZT0nYXBwbGljYXRpb24vanNvbic7bmFtZSs9Jy5qc29uJzt9CiBlbHNle2Nv
bnN0IGs9T2JqZWN0LmtleXMoR0VOWzBdKTtkYXRhPVtrLmpvaW4oJzsnKV0uY29uY2F0KEdFTi5t
YXAoZz0+ay5tYXAoeD0+Z1t4XSkuam9pbignOycpKSkuam9pbihTdHJpbmcuZnJvbUNoYXJDb2Rl
KDEzLDEwKSk7dHlwZT0ndGV4dC9jc3YnO25hbWUrPScuY3N2Jzt9CiBjb25zdCBhPWRvY3VtZW50
LmNyZWF0ZUVsZW1lbnQoJ2EnKTthLmhyZWY9VVJMLmNyZWF0ZU9iamVjdFVSTChuZXcgQmxvYihb
ZGF0YV0se3R5cGV9KSk7YS5kb3dubG9hZD1uYW1lO2EuY2xpY2soKTtzZXRUaW1lb3V0KCgpPT5V
UkwucmV2b2tlT2JqZWN0VVJMKGEuaHJlZiksMjAwMCk7fQphc3luYyBmdW5jdGlvbiBwb2xsKCl7
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
