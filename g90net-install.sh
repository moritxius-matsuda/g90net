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
SELF=$(readlink -f "$0")

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
# Debian 13 hat kein srsRAN-Paket mehr -> einmalig aus dem Quelltext bauen (dauert 20-60 min)
apt-get install -y -qq srsran 2>/dev/null || true
if ! command -v srsenb >/dev/null 2>&1; then
  info "srsRAN 4G aus dem Quelltext bauen (einmalig, bitte warten)"
  apt-get install -y -qq build-essential cmake git pkg-config libfftw3-dev libmbedtls-dev     libboost-program-options-dev libconfig++-dev libsctp-dev libsoapysdr-dev 2>/dev/null     || warn "Build-Pakete fuer srsRAN unvollstaendig"
  SRC=/usr/local/src/srsRAN_4G; LOG=/var/log/pkom-srsran-build.log
  if [[ -d $SRC/.git ]]; then git -C $SRC pull -q --ff-only || true
  else git clone -q --depth 1 https://github.com/srsran/srsRAN_4G.git $SRC || warn "srsRAN-Quelltext nicht ladbar"; fi
  if [[ -d $SRC ]]; then
    MEMK=$(awk '/MemTotal/{print $2}' /proc/meminfo); SWAPK=$(awk '/SwapTotal/{print $2}' /proc/meminfo)
    TMPSWAP=""
    # Die grossen ASN.1-Dateien brauchen je Compiler ~2 GB RAM -> bei wenig Speicher Auslagerung anlegen
    if (( MEMK + SWAPK < 8000000 )); then
      TMPSWAP=/var/tmp/pkom-build.swap
      info "Wenig Arbeitsspeicher ($((MEMK/1024)) MB) - lege voruebergehend 4 GB Auslagerung an"
      { fallocate -l 4G $TMPSWAP 2>/dev/null || dd if=/dev/zero of=$TMPSWAP bs=1M count=4096 status=none; }         && chmod 600 $TMPSWAP && mkswap $TMPSWAP >/dev/null && swapon $TMPSWAP || { warn "Auslagerung nicht moeglich"; rm -f $TMPSWAP; TMPSWAP=""; }
    fi
    J=$(nproc); MAXJ=$(( MEMK / 2000000 )); (( MAXJ < 1 )) && MAXJ=1; (( J > MAXJ )) && J=$MAXJ
    info "Baue mit $J Kern(en) - Fortschritt: tail -f $LOG"
    (
      mkdir -p $SRC/build && cd $SRC/build || exit 1
      cmake .. -DCMAKE_BUILD_TYPE=Release -DENABLE_WERROR=OFF -DENABLE_SRSUE=OFF -DENABLE_SRSEPC=OFF         -DENABLE_GUI=OFF -DENABLE_HARDSIM=OFF -DENABLE_UHD=OFF -DENABLE_BLADERF=OFF -DENABLE_SKIQ=OFF         -DENABLE_ZEROMQ=OFF -DENABLE_SOAPYSDR=ON -DENABLE_RF_PLUGINS=ON >$LOG 2>&1 || exit 1
      # erst parallel, bei Fehler (z. B. Speicher) einzeln weiterbauen
      make -j"$J" >>$LOG 2>&1 || { echo "=== Wiederholung mit -j1 ===" >>$LOG; make -j1 >>$LOG 2>&1; } || exit 1
      make install >>$LOG 2>&1 && ldconfig
    ) || {
      warn "srsRAN-Build fehlgeschlagen - letzte Fehler:"
      grep -E "error|Error|Killed|fatal" $LOG | tail -15 | sed 's/^/     /'
    }
    [[ -n $TMPSWAP ]] && { swapoff $TMPSWAP; rm -f $TMPSWAP; }
    grep -q "Found libSOAPYSDR" $LOG || warn "srsRAN ohne SoapySDR gebaut - LimeSDR fehlt (libsoapysdr-dev?)"
  fi
fi
command -v srsenb >/dev/null 2>&1 && info "srsenb: $(command -v srsenb)" || warn "srsenb fehlt - 4G nicht moeglich (Log: /var/log/pkom-srsran-build.log)."

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

# MongoDB: ab 5.0 ist AVX Pflicht. Ohne AVX -> MongoDB 4.4 (letzte Version ohne AVX)
MONGO44=mongodb-linux-x86_64-debian10-4.4.29
MONGO44_SHA=dd254701bebe1050f96cbb6928f0c7f66b541747dcf4881e4517cb1f435c2b8e
SSL11=libssl1.1_1.1.1w-0+deb11u1_amd64.deb
SSL11_SHA=aadf8b4b197335645b230c2839b4517aa444fd2e8f434e5438c48a18857988f7
mongo44() {
  info "CPU ohne AVX - installiere MongoDB 4.4 (laeuft ohne AVX, nur lokal auf 127.0.0.1)"
  apt-get install -y -qq libcurl4t64 2>/dev/null || apt-get install -y -qq libcurl4 2>/dev/null || true
  local T; T=$(mktemp -d)
  if ! ldconfig -p | grep -q 'libssl.so.1.1 '; then
    curl -fsSL -o "$T/$SSL11" "https://deb.debian.org/debian/pool/main/o/openssl/$SSL11"       && echo "$SSL11_SHA  $T/$SSL11" | sha256sum -c --quiet       && dpkg -i "$T/$SSL11" >/dev/null 2>&1 || { warn "libssl1.1 nicht installierbar"; rm -rf "$T"; return 1; }
  fi
  curl -fsSL -o "$T/m.tgz" "https://fastdl.mongodb.org/linux/$MONGO44.tgz"     && echo "$MONGO44_SHA  $T/m.tgz" | sha256sum -c --quiet     || { warn "MongoDB 4.4 Download/Pruefsumme fehlgeschlagen"; rm -rf "$T"; return 1; }
  tar xzf "$T/m.tgz" -C "$T" && install -m 755 "$T/$MONGO44/bin/mongod" /usr/local/bin/mongod
  rm -rf "$T"
  id mongodb >/dev/null 2>&1 || useradd -r -s /usr/sbin/nologin -d /var/lib/mongodb mongodb
  mkdir -p /var/lib/mongodb /var/log/mongodb && chown mongodb: /var/lib/mongodb /var/log/mongodb
  cat > /etc/systemd/system/mongod.service <<'MUNIT'
[Unit]
Description=MongoDB 4.4 (pKOM Teilnehmer-DB, ohne AVX)
After=network.target
[Service]
User=mongodb
ExecStart=/usr/local/bin/mongod --bind_ip 127.0.0.1 --port 27017 --dbpath /var/lib/mongodb --logpath /var/log/mongodb/mongod.log --logappend
Restart=on-failure
LimitNOFILE=64000
[Install]
WantedBy=multi-user.target
MUNIT
  systemctl daemon-reload
}
if ! command -v mongod >/dev/null 2>&1; then
  if [[ $(uname -m) == x86_64 ]] && ! grep -qw avx /proc/cpuinfo; then
    mongo44 || warn "MongoDB fehlt - LTE-Teilnehmer-DB nicht moeglich."
  else
    info "MongoDB (Teilnehmer-DB fuer Open5GS) installieren"
    curl -fsSL https://pgp.mongodb.com/server-8.0.asc | gpg --dearmor > /usr/share/keyrings/mongodb-8.0.gpg 2>/dev/null || true
    for CN in trixie bookworm; do
      echo "deb [signed-by=/usr/share/keyrings/mongodb-8.0.gpg] https://repo.mongodb.org/apt/debian ${CN}/mongodb-org/8.0 main"         > /etc/apt/sources.list.d/mongodb-org-8.0.list
      apt-get update -qq 2>/dev/null && apt-get install -y -qq mongodb-org 2>/dev/null || true
      command -v mongod >/dev/null 2>&1 && { info "MongoDB aus Zweig $CN"; break; }
    done
    command -v mongod >/dev/null 2>&1 || { rm -f /etc/apt/sources.list.d/mongodb-org-8.0.list; warn "MongoDB nicht installierbar"; }
  fi
fi
if command -v mongod >/dev/null 2>&1; then
  systemctl enable --now mongod >/dev/null 2>&1 || true
  sleep 3; systemctl is-active --quiet mongod && info "MongoDB laeuft" || warn "mongod startet nicht - 'journalctl -u mongod'"
fi

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
for f in enb.conf rr.conf sib.conf rb.conf; do
  # leere oder fehlende Datei durch die mitgelieferte Vorlage ersetzen (genauer Name, nicht *.mbsfn.*)
  if [[ ! -s /etc/srsran/$f ]]; then
    for src in /usr/local/share/srsran/$f.example /usr/share/srsran/$f.example; do
      [[ -s $src ]] && { cp "$src" /etc/srsran/$f; break; }
    done
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
sed -n '/^__G90NET_PAYLOAD__$/,$p' "$SELF" | tail -n +2 | base64 -d > "$PY.new"
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
ZSkKICAgICAgICBvdXRbbmZdID0gKGJpbmFyeSwgZHN0KQogICAgcmV0dXJuIG91dAoKU1JTX01B
UksgPSB7InNpYi5jb25mIjogciIoP20pXnNpYjFccyo9IiwgInJyLmNvbmYiOiByIig/bSleY2Vs
bF9saXN0XHMqPSIsICJyYi5jb25mIjogciIoP20pXlx3K1xzKj0ifQoKZGVmIF9zcnNfdGVtcGxh
dGUobmFtZSk6CiAgICAiIiJWb3JsYWdlIHN1Y2hlbiAtIG51ciBEYXRlaWVuLCBkaWUgd2lya2xp
Y2ggZGVuIGVyd2FydGV0ZW4gSW5oYWx0IGhhYmVuCiAgICAoZWluZSBsZWVyZS9mYWxzY2hlIC9l
dGMvc3JzcmFuL3NpYi5jb25mIGZ1ZWhydGUgenUgJ3NlY3Rpb24gc2liMSBub3QgZm91bmQnKS4i
IiIKICAgIGNhbmRzID0gKG9zLnBhdGguam9pbihTUlNfQ0ZHLCBuYW1lKSwgZiIvdXNyL2xvY2Fs
L3NoYXJlL3Nyc3Jhbi97bmFtZX0uZXhhbXBsZSIsCiAgICAgICAgICAgICBmIi91c3Ivc2hhcmUv
c3JzcmFuL3tuYW1lfS5leGFtcGxlIiwgZiIvdXNyL3NoYXJlL3Nyc3Jhbi97bmFtZX0iLAogICAg
ICAgICAgICAgZiIvdXNyL3NoYXJlL2RvYy9zcnNyYW4vZXhhbXBsZXMve25hbWV9LmV4YW1wbGUi
KQogICAgZm9yIHAgaW4gY2FuZHM6CiAgICAgICAgdHJ5OiB0ID0gb3BlbihwLCBlbmNvZGluZz0i
dXRmLTgiLCBlcnJvcnM9InJlcGxhY2UiKS5yZWFkKCkKICAgICAgICBleGNlcHQgT1NFcnJvcjog
Y29udGludWUKICAgICAgICBpZiByZS5zZWFyY2goU1JTX01BUksuZ2V0KG5hbWUsIHIiXFMiKSwg
dCk6IHJldHVybiBwCiAgICAgICAgbG9nKGYic3JzUkFOLVZvcmxhZ2Uge3B9IHVuYnJhdWNoYmFy
IC0gdWViZXJzcHJ1bmdlbiIpCiAgICByZXR1cm4gTm9uZQoKZGVmIF9kcm9wX2Jsb2NrKHQsIG5h
bWUpOgogICAgIiIibGliY29uZmlnLUJsb2NrICduYW1lID0geyAuLi4gfTsnIGVudGZlcm5lbiAo
S2xhbW1lcm4gZ2V6YWVobHQpLiIiIgogICAgbSA9IHJlLnNlYXJjaChyZiIoP20pXntuYW1lfVxz
Kj1ccypce3siLCB0KQogICAgaWYgbm90IG06IHJldHVybiB0CiAgICBpID0gdC5pbmRleCgieyIs
IG0uc3RhcnQoKSk7IGRlcHRoID0gMAogICAgZm9yIGogaW4gcmFuZ2UoaSwgbGVuKHQpKToKICAg
ICAgICBpZiB0W2pdID09ICJ7IjogZGVwdGggKz0gMQogICAgICAgIGVsaWYgdFtqXSA9PSAifSI6
CiAgICAgICAgICAgIGRlcHRoIC09IDEKICAgICAgICAgICAgaWYgZGVwdGggPT0gMDoKICAgICAg
ICAgICAgICAgIGsgPSBqICsgMQogICAgICAgICAgICAgICAgd2hpbGUgayA8IGxlbih0KSBhbmQg
dFtrXSBpbiAiIFx0OyI6IGsgKz0gMQogICAgICAgICAgICAgICAgcmV0dXJuIHRbOm0uc3RhcnQo
KV0gKyB0W2s6XQogICAgcmV0dXJuIHQKCmRlZiBfc2lfbWFwcGluZyh0LCBhZGQ3KToKICAgIGRl
ZiBmKG0pOgogICAgICAgIG51bXMgPSBbeC5zdHJpcCgpIGZvciB4IGluIG0uZ3JvdXAoMikuc3Bs
aXQoIiwiKSBpZiB4LnN0cmlwKCkgYW5kIHguc3RyaXAoKSAhPSAiNyJdCiAgICAgICAgaWYgYWRk
NzogbnVtcy5hcHBlbmQoIjciKQogICAgICAgIHJldHVybiBtLmdyb3VwKDEpICsgIiwgIi5qb2lu
KG51bXMpICsgbS5ncm91cCgzKQogICAgcmV0dXJuIHJlLnN1YihyIihzaV9tYXBwaW5nX2luZm9c
cyo9XHMqXFtccyopKFteXF1dKj8pKFxzKlxdKSIsIGYsIHQsIGNvdW50PTEpCgpkZWYgc2liX3Bh
dGNoKHQsIGNzZmIsIGFyZmNuKToKICAgICIiIlNJQjcgKEdFUkFOLU5hY2hiYXIpIG51ciBpbSBD
U0ZCLU1vZHVzOiBzcnNFTkIgc2NoaWNrdCBkYXMgSGFuZHkgYmVpCiAgICBlaW5lbSBBbnJ1ZiBw
ZXIgUlJDLVJlbGVhc2UgbWl0IFVtbGVpdHVuZyBhdWYgZ2VuYXUgZGllc2UgR1NNLUZyZXF1ZW56
LiIiIgogICAgdCA9IF9kcm9wX2Jsb2NrKHQsICJzaWI3IikKICAgIHQgPSBfc2lfbWFwcGluZyh0
LCBjc2ZiKQogICAgaWYgY3NmYjoKICAgICAgICB0ID0gdC5yc3RyaXAoKSArIGYiIiIKCi8vIHBL
T006IEdTTS1aZWxsZSBmdWVyIENTLUZhbGxiYWNrIChBbnJ1ZmUpCnNpYjcgPQp7ewogICAgdF9y
ZXNlbF9nZXJhbiA9IDE7CiAgICBjYXJyaWVyX2ZyZXFzX2luZm9fbGlzdCA9CiAgICAoCiAgICAg
ICAge3sKICAgICAgICAgICAgY2VsbF9yZXNlbF9wcmlvID0gMDsKICAgICAgICAgICAgbmNjX3Bl
cm1pdHRlZCA9IDI1NTsKICAgICAgICAgICAgcV9yeF9sZXZfbWluID0gMDsKICAgICAgICAgICAg
dGhyZXNoX3hfaGlnaCA9IDI7CiAgICAgICAgICAgIHRocmVzaF94X2xvdyA9IDI7CiAgICAgICAg
ICAgIHN0YXJ0X2FyZmNuID0ge2FyZmNufTsKICAgICAgICAgICAgYmFuZF9pbmQgPSAiZGNzMTgw
MCI7CiAgICAgICAgICAgIGV4cGxpY2l0X2xpc3Rfb2ZfYXJmY25zID0gKCB7YXJmY259ICk7CiAg
ICAgICAgfX0KICAgICk7Cn19OwoiIiIKICAgIHJldHVybiB0CgpkZWYgZW5iX3ByZXBhcmUoY3Nm
Yiwgc2VyaWFsKToKICAgIGZvciBmIGluICgicnIuY29uZiIsICJzaWIuY29uZiIsICJyYi5jb25m
Iik6CiAgICAgICAgcCA9IF9zcnNfdGVtcGxhdGUoZikKICAgICAgICBpZiBub3QgcDogcmFpc2Ug
UnVudGltZUVycm9yKGYic3JzUkFOLVZvcmxhZ2Uge2Z9IGZlaGx0IC0gaXN0IHNyc3JhbiBpbnN0
YWxsaWVydD8iKQogICAgICAgIHNodXRpbC5jb3B5KHAsIG9zLnBhdGguam9pbihXT1JLRElSLCBm
KSkKICAgIGVhcmZjbiA9IGludChDWyJMVEVfRUFSRkNOIl0pOyB0YWMgPSBpbnQoQy5nZXQoIkxU
RV9UQUMiKSBvciA3KQogICAgcnIgPSBvcy5wYXRoLmpvaW4oV09SS0RJUiwgInJyLmNvbmYiKTsg
dCA9IG9wZW4ocnIpLnJlYWQoKQogICAgdCA9IHJlLnN1YihyIig/bSleKFxzKnRhY1xzKj1ccyop
W147XSs7IiwgciJcZzwxPjB4JTA0WDsiICUgdGFjLCB0LCBjb3VudD0xKQogICAgdCA9IHJlLnN1
YihyIig/bSleKFxzKmRsX2VhcmZjblxzKj1ccyopXGQrOyIsIHIiXGc8MT4lZDsiICUgZWFyZmNu
LCB0LCBjb3VudD0xKSAgIyAxLiA9IGVpZ2VuZSBaZWxsZQogICAgb3BlbihyciwgInciKS53cml0
ZSh0KQogICAgc2liID0gb3MucGF0aC5qb2luKFdPUktESVIsICJzaWIuY29uZiIpCiAgICB3aXRo
IG9wZW4oc2liKSBhcyBmOiB0ID0gZi5yZWFkKCkgICAgICAgICAgIyBlcnN0IGxlc2VuIC0gb3Bl
biguLi4sInciKSBsZWVydCBkaWUgRGF0ZWkgc29mb3J0CiAgICB3aXRoIG9wZW4oc2liLCAidyIp
IGFzIGY6IGYud3JpdGUoc2liX3BhdGNoKHQsIGNzZmIsIGludChDWyJHU01fQVJGQ04iXSkpKQog
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
InNpbV9nZW4iOgogICAgICAgIHRyeToKICAgICAgICAgICAgZ2VuID0gc2ltX2dlbmVyYXRlKHJl
cS5nZXQoImNvdW50IiwgMSksIHJlcS5nZXQoIm1zaXNkbiIsICIiKSwgcmVxLmdldCgiaWNjaWQi
LCAiIikpCiAgICAgICAgICAgIE5FVC5tc2cgPSBmIntsZW4oZ2VuKX0gU0lNLURhdGVuc2F0ei8t
c2FldHplIGVyemV1Z3QiCiAgICAgICAgZXhjZXB0IEV4Y2VwdGlvbiBhcyBlOgogICAgICAgICAg
ICBnZW4gPSBbXTsgTkVULm1zZyA9ICJFcnpldWdlbiBmZWhsZ2VzY2hsYWdlbjogJXMiICUgZQog
ICAgICAgIHN0ID0gTkVULnN0YXR1cygpOyBzdFsiZ2VuZXJhdGVkIl0gPSBnZW4KICAgICAgICBy
ZXR1cm4gc3QKICAgIGVsaWYgY21kID09ICJzbXNfdGVzdCI6CiAgICAgICAgTkVULm1zZyA9IHNt
c190ZXN0KHJlcS5nZXQoImltc2kiLCIiKSwgcmVxLmdldCgidGV4dCIsIiIpKQogICAgZWxzZToK
ICAgICAgICBORVQubXNnID0gInVuYmVrYW5udCIKICAgIHJldHVybiBORVQuc3RhdHVzKCkKCiMg
PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
PT09PT09PT09IFdlYi1PYmVyZmxhZWNoZSAoSFRNTCkKUEFHRSA9IHIiIiI8IWRvY3R5cGUgaHRt
bD48aHRtbCBsYW5nPWRlPjxoZWFkPjxtZXRhIGNoYXJzZXQ9dXRmLTg+CjxtZXRhIG5hbWU9dmll
d3BvcnQgY29udGVudD0id2lkdGg9ZGV2aWNlLXdpZHRoLGluaXRpYWwtc2NhbGU9MSI+CjxtZXRh
IG5hbWU9dGhlbWUtY29sb3IgY29udGVudD0iIzBBMjQ2MyI+CjxsaW5rIHJlbD1pY29uIGhyZWY9
ImRhdGE6aW1hZ2Uvc3ZnK3htbDtiYXNlNjQsUEhOMlp5QjRiV3h1Y3owaWFIUjBjRG92TDNkM2R5
NTNNeTV2Y21jdk1qQXdNQzl6ZG1jaUlIWnBaWGRDYjNnOUlqQWdNQ0F4TURJMElERXdNalFpUGp4
eVpXTjBJSGRwWkhSb1BTSXhNREkwSWlCb1pXbG5hSFE5SWpFd01qUWlJR1pwYkd3OUlpTXdRVEkw
TmpNaVBqd3ZjbVZqZEQ0S1BHY2dkSEpoYm5ObWIzSnRQU0owY21GdWMyeGhkR1VvTVRJM0xqWWdN
elEzTGpBcElITmpZV3hsS0RFdU5qVXBJaUJtYVd4c1BTSnViMjVsSWlCemRISnZhMlV0YkdsdVpX
TmhjRDBpY205MWJtUWlJSE4wY205clpTMXNhVzVsYW05cGJqMGljbTkxYm1RaUlITjBjbTlyWlMx
M2FXUjBhRDBpTXpJaVBnbzhaeUJ6ZEhKdmEyVTlJaU5HUmtaR1JrWWlQZ284Y0dGMGFDQmtQU0pO
TWpBZ09EQWdWakkyTmlJK1BDOXdZWFJvUGdvOFkybHlZMnhsSUdONFBTSTNNaUlnWTNrOUlqRXpN
eUlnY2owaU5USWlQand2WTJseVkyeGxQZ284TDJjK0NqeG5JSE4wY205clpUMGlJMFpHUmtaR1Jp
SStDanh3WVhSb0lHUTlJazB4TnpnZ01UWWdVVEl3TmlBeE1EQWdNVGM0SURFNE5DSStQQzl3WVhS
b1BnbzhjR0YwYUNCa1BTSk5NVGt5SURFd01DQkRNakkySURrMklESTFNQ0EyTWlBeU5qWWdNVFlp
UGp3dmNHRjBhRDRLUEM5blBnbzhjR0YwYUNCemRISnZhMlU5SWlNeVJVTTBSakVpSUdROUlrMHhP
VElnTVRBd0lFTXlNek1nTVRBeUlESTFOaUF4T0RNZ016WXpJREU0TXlCQk9ETWdPRE1nTUNBd0lE
QWdNell6SURFM0lFRTRNeUE0TXlBd0lEQWdNQ0F5T0RJZ01URTRJajQ4TDNCaGRHZytDand2Wno0
OEwzTjJaejQ9Ij4KPHRpdGxlPnBLT00gwrcgTmV0enN0ZXVlcnVuZzwvdGl0bGU+CjxzdHlsZT4K
OnJvb3R7LS1uYXZ5OiMwQTI0NjM7LS1iZzojMDYwZjIyOy0tYmcyOiMwYTE3MzQ7LS1jYXJkOiMw
YzFhM2I7LS1jYXJkMjojMTAyMjUwOy0tbGluZTojMWIyZjVlOy0tbGluZTI6IzJhNDI4ODsKLS1m
ZzojZWFmMWZiOy0tbXV0OiM4ZWE0Y2E7LS1tdXQyOiM1ZDczOTg7LS1hY2M6IzJFQzRGMTstLWFj
YzI6IzAwOTZENjstLW9rOiMyRUM0RjE7LS1va2JnOiMwNzI0M2I7LS1lcnI6I2ZmNWQ2YzsKLS1y
OjA7LS1yMjowOy0tbW9ubzp1aS1tb25vc3BhY2UsU0ZNb25vLVJlZ3VsYXIsTWVubG8sQ29uc29s
YXMsbW9ub3NwYWNlfQoqe2JveC1zaXppbmc6Ym9yZGVyLWJveH1odG1sLGJvZHl7bWFyZ2luOjB9
CmJvZHl7YmFja2dyb3VuZDpsaW5lYXItZ3JhZGllbnQoMTgwZGVnLCMwODEzMzAsIzA1MTAxZik7
Y29sb3I6dmFyKC0tZmcpOwpmb250OjE1cHgvMS41NSBzeXN0ZW0tdWksLWFwcGxlLXN5c3RlbSxT
ZWdvZSBVSSxSb2JvdG8sc2Fucy1zZXJpZjttaW4taGVpZ2h0OjEwMHZofQpoZWFkZXJ7cG9zaXRp
b246c3RpY2t5O3RvcDowO3otaW5kZXg6MjA7YmFja2dyb3VuZDp2YXIoLS1uYXZ5KTtib3JkZXIt
dG9wOjJweCBzb2xpZCB2YXIoLS1hY2MpOwpib3JkZXItYm90dG9tOjFweCBzb2xpZCB2YXIoLS1s
aW5lMik7cGFkZGluZzoxMnB4IDIwcHg7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtn
YXA6MTZweDtmbGV4LXdyYXA6d3JhcH0KLmJyYW5ke2Rpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpj
ZW50ZXI7Z2FwOjEycHh9Ci5icmFuZCBzdmd7aGVpZ2h0OjMwcHg7d2lkdGg6YXV0bztkaXNwbGF5
OmJsb2NrfQouYnJhbmQgLnByb2R7Zm9udC1zaXplOjExcHg7Zm9udC13ZWlnaHQ6NzAwO2xldHRl
ci1zcGFjaW5nOi4xOGVtO3RleHQtdHJhbnNmb3JtOnVwcGVyY2FzZTtjb2xvcjojOWZiNmRlO3Bh
ZGRpbmctbGVmdDoxMnB4O2JvcmRlci1sZWZ0OjFweCBzb2xpZCAjMjc0MDdlfQouY2hpcHtkaXNw
bGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2dhcDo4cHg7cGFkZGluZzo2cHggMTJweDtib3Jk
ZXI6MXB4IHNvbGlkIHZhcigtLWxpbmUyKTtiYWNrZ3JvdW5kOiMwYjE3MzM7Zm9udC1zaXplOjEy
cHg7Zm9udC13ZWlnaHQ6NzAwO2xldHRlci1zcGFjaW5nOi4wNmVtO3RleHQtdHJhbnNmb3JtOnVw
cGVyY2FzZX0KLmRvdHt3aWR0aDo4cHg7aGVpZ2h0OjhweDtiYWNrZ3JvdW5kOnZhcigtLW11dCl9
Ci5kb3Qub257YmFja2dyb3VuZDp2YXIoLS1hY2MpO2FuaW1hdGlvbjpwdWxzZSAycyBpbmZpbml0
ZX0uZG90LmVycntiYWNrZ3JvdW5kOnZhcigtLWVycil9CkBrZXlmcmFtZXMgcHVsc2V7MCV7Ym94
LXNoYWRvdzowIDAgMCAwIHJnYmEoNDYsMTk2LDI0MSwuNSl9NzAle2JveC1zaGFkb3c6MCAwIDAg
N3B4IHJnYmEoNDYsMTk2LDI0MSwwKX0xMDAle2JveC1zaGFkb3c6MCAwIDAgMCByZ2JhKDQ2LDE5
NiwyNDEsMCl9fQouaHN0YXR7ZGlzcGxheTpmbGV4O2dhcDoxOHB4O2ZsZXgtd3JhcDp3cmFwO2Nv
bG9yOnZhcigtLW11dCk7Zm9udC1zaXplOjEycHg7bWFyZ2luLWxlZnQ6YXV0bzthbGlnbi1pdGVt
czpjZW50ZXI7dGV4dC10cmFuc2Zvcm06dXBwZXJjYXNlO2xldHRlci1zcGFjaW5nOi4wNWVtfQou
aHN0YXQgYntjb2xvcjp2YXIoLS1mZyk7Zm9udC1mYW1pbHk6dmFyKC0tbW9ubyk7bGV0dGVyLXNw
YWNpbmc6MDt0ZXh0LXRyYW5zZm9ybTpub25lfQojbXNne2NvbG9yOnZhcigtLWFjYyk7Zm9udC1z
aXplOjEycHg7dGV4dC10cmFuc2Zvcm06bm9uZTtsZXR0ZXItc3BhY2luZzowfQouYmFkZ2V7Zm9u
dC1zaXplOjEwcHg7cGFkZGluZzozcHggOXB4O2JvcmRlcjoxcHggc29saWQgdmFyKC0tYWNjKTtj
b2xvcjp2YXIoLS1hY2MpO2ZvbnQtd2VpZ2h0OjcwMDtsZXR0ZXItc3BhY2luZzouMTJlbX0KLndy
YXB7bWF4LXdpZHRoOjEwNjBweDttYXJnaW46MCBhdXRvO3BhZGRpbmc6MjJweCAxNnB4IDQ0cHh9
Ci5iYW5uZXJ7ZGlzcGxheTpmbGV4O2dhcDoxMXB4O2FsaWduLWl0ZW1zOmZsZXgtc3RhcnQ7YmFj
a2dyb3VuZDojMGMxYTNiO2JvcmRlcjoxcHggc29saWQgdmFyKC0tbGluZTIpOwpib3JkZXItbGVm
dDozcHggc29saWQgI2YxYjI0YTtjb2xvcjojZjJkNzlmO3BhZGRpbmc6MTJweCAxNXB4O2ZvbnQt
c2l6ZToxM3B4O21hcmdpbi1ib3R0b206MThweH0KLmNvbnRyb2xze2Rpc3BsYXk6Z3JpZDtncmlk
LXRlbXBsYXRlLWNvbHVtbnM6MWZyIDFmciAxZnIgYXV0bztnYXA6MTBweDttYXJnaW4tYm90dG9t
OjIwcHh9CkBtZWRpYShtYXgtd2lkdGg6ODIwcHgpey5jb250cm9sc3tncmlkLXRlbXBsYXRlLWNv
bHVtbnM6MWZyIDFmcn19QG1lZGlhKG1heC13aWR0aDo0ODBweCl7LmNvbnRyb2xze2dyaWQtdGVt
cGxhdGUtY29sdW1uczoxZnJ9fQouYmlnYnRue2JvcmRlcjoxcHggc29saWQgdmFyKC0tbGluZTIp
O2JhY2tncm91bmQ6IzBiMTgzNjtjb2xvcjp2YXIoLS1mZyk7CnBhZGRpbmc6MTVweCAxOHB4O2Zv
bnQ6aW5oZXJpdDtmb250LXdlaWdodDo2MDA7Y3Vyc29yOnBvaW50ZXI7ZGlzcGxheTpmbGV4O2Fs
aWduLWl0ZW1zOmNlbnRlcjtnYXA6MTJweDt0cmFuc2l0aW9uOi4xNXN9Ci5iaWdidG46aG92ZXJ7
Ym9yZGVyLWNvbG9yOnZhcigtLWFjYyk7YmFja2dyb3VuZDojMGUxZjQ3fS5iaWdidG4gLmlje2Zv
bnQtc2l6ZToxNnB4O2NvbG9yOnZhcigtLWFjYyl9Ci5iaWdidG4gc21hbGx7ZGlzcGxheTpibG9j
aztjb2xvcjp2YXIoLS1tdXQpO2ZvbnQtd2VpZ2h0OjQwMDtmb250LXNpemU6MTFweDt0ZXh0LXRy
YW5zZm9ybTp1cHBlcmNhc2U7bGV0dGVyLXNwYWNpbmc6LjA3ZW07bWFyZ2luLXRvcDoycHh9Ci5i
aWdidG4uYWN0aXZle2JvcmRlci1jb2xvcjp2YXIoLS1hY2MpO2JhY2tncm91bmQ6dmFyKC0tb2ti
Zyk7Ym94LXNoYWRvdzppbnNldCAzcHggMCAwIHZhcigtLWFjYyl9LmJpZ2J0bi5hY3RpdmUgLmlj
e2NvbG9yOnZhcigtLWFjYyl9Ci5iaWdidG4uc3RvcHtiYWNrZ3JvdW5kOiMxZTEwMTY7Ym9yZGVy
LWNvbG9yOiM1MzIzMmU7Y29sb3I6I2ZmYjBiODtqdXN0aWZ5LWNvbnRlbnQ6Y2VudGVyO2ZvbnQt
d2VpZ2h0OjcwMDtsZXR0ZXItc3BhY2luZzouMDVlbTt0ZXh0LXRyYW5zZm9ybTp1cHBlcmNhc2U7
Zm9udC1zaXplOjE0cHh9LmJpZ2J0bi5zdG9wOmhvdmVye2JvcmRlci1jb2xvcjp2YXIoLS1lcnIp
fQoudGFic3tkaXNwbGF5OmZsZXg7Z2FwOjRweDtib3JkZXItYm90dG9tOjFweCBzb2xpZCB2YXIo
LS1saW5lMik7bWFyZ2luLWJvdHRvbToyMHB4O292ZXJmbG93LXg6YXV0b30KLnRhYntwYWRkaW5n
OjEwcHggMTZweDtib3JkZXI6MDtiYWNrZ3JvdW5kOjA7Y29sb3I6dmFyKC0tbXV0KTtmb250Omlu
aGVyaXQ7Zm9udC13ZWlnaHQ6NzAwO2ZvbnQtc2l6ZToxMnB4O2xldHRlci1zcGFjaW5nOi4wOWVt
O3RleHQtdHJhbnNmb3JtOnVwcGVyY2FzZTtjdXJzb3I6cG9pbnRlcjtib3JkZXItYm90dG9tOjJw
eCBzb2xpZCB0cmFuc3BhcmVudDt3aGl0ZS1zcGFjZTpub3dyYXA7bWFyZ2luLWJvdHRvbTotMXB4
fQoudGFiOmhvdmVye2NvbG9yOnZhcigtLWZnKX0udGFiLnNlbHtjb2xvcjp2YXIoLS1hY2MpO2Jv
cmRlci1ib3R0b20tY29sb3I6dmFyKC0tYWNjKX0KLnBhbmVse2Rpc3BsYXk6bm9uZX0ucGFuZWwu
c2Vse2Rpc3BsYXk6YmxvY2t9Ci5ncmlke2Rpc3BsYXk6Z3JpZDtnYXA6MTZweDtncmlkLXRlbXBs
YXRlLWNvbHVtbnM6MWZyIDFmcn1AbWVkaWEobWF4LXdpZHRoOjc2MHB4KXsuZ3JpZHtncmlkLXRl
bXBsYXRlLWNvbHVtbnM6MWZyfX0KLmNhcmR7YmFja2dyb3VuZDp2YXIoLS1jYXJkKTtib3JkZXI6
MXB4IHNvbGlkIHZhcigtLWxpbmUpO3BhZGRpbmc6MThweH0KLmNhcmQgaDJ7Zm9udC1zaXplOjEy
cHg7bWFyZ2luOjA7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtnYXA6OXB4O3RleHQt
dHJhbnNmb3JtOnVwcGVyY2FzZTtsZXR0ZXItc3BhY2luZzouMWVtO2NvbG9yOiNjNmQ2ZjE7Zm9u
dC13ZWlnaHQ6NzAwfQouY2FyZCBoMjpiZWZvcmV7Y29udGVudDoiIjt3aWR0aDo5cHg7aGVpZ2h0
OjlweDtiYWNrZ3JvdW5kOnZhcigtLWFjYyk7ZmxleDpub25lfQouY2FyZCAuc3Vie2NvbG9yOnZh
cigtLW11dCk7Zm9udC1zaXplOjEycHg7bWFyZ2luOjhweCAwIDE0cHh9CmxhYmVse2Rpc3BsYXk6
YmxvY2s7Zm9udC1zaXplOjExcHg7Y29sb3I6dmFyKC0tbXV0KTttYXJnaW46MTNweCAwIDVweDtm
b250LXdlaWdodDo3MDA7dGV4dC10cmFuc2Zvcm06dXBwZXJjYXNlO2xldHRlci1zcGFjaW5nOi4w
N2VtfQppbnB1dCxzZWxlY3R7d2lkdGg6MTAwJTtiYWNrZ3JvdW5kOiMwNzE0MmY7Ym9yZGVyOjFw
eCBzb2xpZCB2YXIoLS1saW5lMik7Y29sb3I6dmFyKC0tZmcpO3BhZGRpbmc6MTBweCAxMnB4O2Zv
bnQ6aW5oZXJpdDtvdXRsaW5lOjA7dHJhbnNpdGlvbjouMTJzfQppbnB1dDpmb2N1cyxzZWxlY3Q6
Zm9jdXN7Ym9yZGVyLWNvbG9yOnZhcigtLWFjYyk7Ym94LXNoYWRvdzowIDAgMCAycHggcmdiYSg0
NiwxOTYsMjQxLC4xOCl9Ci5yb3d7ZGlzcGxheTpncmlkO2dyaWQtdGVtcGxhdGUtY29sdW1uczox
ZnIgMWZyO2dhcDoxMHB4fS5yb3cze2Rpc3BsYXk6Z3JpZDtncmlkLXRlbXBsYXRlLWNvbHVtbnM6
MWZyIDFmciAxZnI7Z2FwOjEwcHh9Ci5idG57YmFja2dyb3VuZDp2YXIoLS1hY2MpO2NvbG9yOnZh
cigtLW5hdnkpO2JvcmRlcjowO3BhZGRpbmc6MTBweCAxOHB4O2ZvbnQ6aW5oZXJpdDtmb250LXdl
aWdodDo3MDA7bGV0dGVyLXNwYWNpbmc6LjA1ZW07dGV4dC10cmFuc2Zvcm06dXBwZXJjYXNlO2Zv
bnQtc2l6ZToxM3B4O2N1cnNvcjpwb2ludGVyO21hcmdpbi10b3A6MTZweDt0cmFuc2l0aW9uOi4x
MnN9Ci5idG46aG92ZXJ7YmFja2dyb3VuZDojNWFkMmY2fS5idG4uc2Vje2JhY2tncm91bmQ6dHJh
bnNwYXJlbnQ7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1saW5lMik7Y29sb3I6dmFyKC0tYWNjKX0u
YnRuLnNlYzpob3Zlcntib3JkZXItY29sb3I6dmFyKC0tYWNjKTtiYWNrZ3JvdW5kOiMwYjFiNDB9
Ci5idG4uc217cGFkZGluZzo4cHggMTNweDttYXJnaW4tdG9wOjRweDtmb250LXNpemU6MTJweH0K
LnN3e2Rpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7anVzdGlmeS1jb250ZW50OnNwYWNl
LWJldHdlZW47Z2FwOjEwcHg7cGFkZGluZzoxM3B4IDA7Ym9yZGVyLXRvcDoxcHggc29saWQgdmFy
KC0tbGluZSl9Ci5zdy5maXJzdHtib3JkZXItdG9wOjB9LnN3IC50e2ZvbnQtc2l6ZToxNHB4fS5z
dyAudCBzbWFsbHtkaXNwbGF5OmJsb2NrO2NvbG9yOnZhcigtLW11dCk7Zm9udC1zaXplOjEycHh9
Ci5zd2l0Y2h7cG9zaXRpb246cmVsYXRpdmU7d2lkdGg6NDZweDtoZWlnaHQ6MjRweDtmbGV4Om5v
bmV9LnN3aXRjaCBpbnB1dHtvcGFjaXR5OjA7d2lkdGg6MDtoZWlnaHQ6MH0KLnNsaWRlcntwb3Np
dGlvbjphYnNvbHV0ZTtpbnNldDowO2JhY2tncm91bmQ6IzBiMWEzZDtib3JkZXI6MXB4IHNvbGlk
IHZhcigtLWxpbmUyKTt0cmFuc2l0aW9uOi4ycztjdXJzb3I6cG9pbnRlcn0KLnNsaWRlcjpiZWZv
cmV7Y29udGVudDoiIjtwb3NpdGlvbjphYnNvbHV0ZTtoZWlnaHQ6MTZweDt3aWR0aDoxNnB4O2xl
ZnQ6M3B4O3RvcDozcHg7YmFja2dyb3VuZDp2YXIoLS1tdXQpO3RyYW5zaXRpb246LjJzfQouc3dp
dGNoIGlucHV0OmNoZWNrZWQrLnNsaWRlcntiYWNrZ3JvdW5kOnZhcigtLW9rYmcpO2JvcmRlci1j
b2xvcjp2YXIoLS1hY2MpfS5zd2l0Y2ggaW5wdXQ6Y2hlY2tlZCsuc2xpZGVyOmJlZm9yZXt0cmFu
c2Zvcm06dHJhbnNsYXRlWCgyMnB4KTtiYWNrZ3JvdW5kOnZhcigtLWFjYyl9Ci5oaW50e2ZvbnQt
c2l6ZToxMnB4O2NvbG9yOnZhcigtLW11dCk7bWFyZ2luLXRvcDoxMHB4O2xpbmUtaGVpZ2h0OjEu
NX0KLmZyZXFib3h7YmFja2dyb3VuZDojMDcxNDJmO2JvcmRlcjoxcHggc29saWQgdmFyKC0tbGlu
ZTIpO3BhZGRpbmc6MTNweCAxNnB4O2Rpc3BsYXk6ZmxleDtqdXN0aWZ5LWNvbnRlbnQ6c3BhY2Ut
YmV0d2VlbjthbGlnbi1pdGVtczpjZW50ZXJ9Ci5mcmVxYm94IC5iaWd7Zm9udC1zaXplOjIycHg7
Zm9udC13ZWlnaHQ6NzAwO2xpbmUtaGVpZ2h0OjEuMTU7Zm9udC1mYW1pbHk6dmFyKC0tbW9ubyk7
Y29sb3I6dmFyKC0tYWNjKX0uZnJlcWJveCAuc217Y29sb3I6dmFyKC0tbXV0KTtmb250LXNpemU6
MTJweDt0ZXh0LXRyYW5zZm9ybTp1cHBlcmNhc2U7bGV0dGVyLXNwYWNpbmc6LjA2ZW19Ci5saXN0
cm93e2Rpc3BsYXk6ZmxleDtqdXN0aWZ5LWNvbnRlbnQ6c3BhY2UtYmV0d2VlbjthbGlnbi1pdGVt
czpjZW50ZXI7Ym9yZGVyLXRvcDoxcHggc29saWQgdmFyKC0tbGluZSk7cGFkZGluZzo5cHggMDtm
b250LXNpemU6MTRweH0KLmxpc3Ryb3c6Zmlyc3QtY2hpbGR7Ym9yZGVyLXRvcDowfS50YWd7Zm9u
dC1mYW1pbHk6dmFyKC0tbW9ubyk7Zm9udC1zaXplOjEzcHg7Y29sb3I6I2NhZDlmM30KLnh7YmFj
a2dyb3VuZDojMWUxMDE2O2JvcmRlcjoxcHggc29saWQgIzUzMjMyZTtjb2xvcjojZmY5YmE2O3Bh
ZGRpbmc6NHB4IDEwcHg7Y3Vyc29yOnBvaW50ZXI7Zm9udC1zaXplOjExcHg7dGV4dC10cmFuc2Zv
cm06dXBwZXJjYXNlO2xldHRlci1zcGFjaW5nOi4wNWVtfS54OmhvdmVye2JvcmRlci1jb2xvcjp2
YXIoLS1lcnIpfQouZW1wdHl7Y29sb3I6dmFyKC0tbXV0Mik7Zm9udC1zaXplOjEzcHg7cGFkZGlu
Zzo4cHggMH0KLmxvZ3tiYWNrZ3JvdW5kOiMwMzBhMTg7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1s
aW5lKTtwYWRkaW5nOjE0cHg7Zm9udDoxMnB4LzEuNTUgdmFyKC0tbW9ubyk7aGVpZ2h0OjQ0MHB4
O292ZXJmbG93OmF1dG87d2hpdGUtc3BhY2U6cHJlLXdyYXA7Y29sb3I6IzlmYjNkMH0KLnRvb2xi
YXJ7ZGlzcGxheTpmbGV4O2dhcDo4cHg7YWxpZ24taXRlbXM6Y2VudGVyO21hcmdpbi1ib3R0b206
MTJweH0udG9vbGJhciBpbnB1dHtmbGV4OjF9Ci5lZnt3aWR0aDoxMDAlO2JvcmRlci1jb2xsYXBz
ZTpjb2xsYXBzZTtmb250LXNpemU6MTNweDttYXJnaW4tdG9wOjZweH0uZWYgdGh7dGV4dC1hbGln
bjpsZWZ0O2NvbG9yOnZhcigtLW11dCk7Zm9udC1zaXplOjExcHg7dGV4dC10cmFuc2Zvcm06dXBw
ZXJjYXNlO2xldHRlci1zcGFjaW5nOi4wN2VtO3BhZGRpbmc6OHB4IDZweDtib3JkZXItYm90dG9t
OjFweCBzb2xpZCB2YXIoLS1saW5lMil9LmVmIHRke3BhZGRpbmc6MTBweCA2cHg7Ym9yZGVyLWJv
dHRvbToxcHggc29saWQgdmFyKC0tbGluZSk7dmVydGljYWwtYWxpZ246dG9wfS5lZiBjb2Rle2Zv
bnQtZmFtaWx5OnZhcigtLW1vbm8pO2NvbG9yOnZhcigtLWFjYyk7d29yZC1icmVhazpicmVhay1h
bGw7dXNlci1zZWxlY3Q6YWxsfS5tdXR7Y29sb3I6dmFyKC0tbXV0KTtmb250LXNpemU6MTFweH0u
Z2Vud3JhcHtvdmVyZmxvdy14OmF1dG87bWFyZ2luLXRvcDoxMnB4fS5nZW53cmFwIC5lZiB0ZCwu
Z2Vud3JhcCAuZWYgdGh7d2hpdGUtc3BhY2U6bm93cmFwfS5nZW53cmFwIGNvZGV7Zm9udC1zaXpl
OjEycHh9LmJ0bjpkaXNhYmxlZHtvcGFjaXR5Oi40O2N1cnNvcjpkZWZhdWx0fWNvZGV7Zm9udC1m
YW1pbHk6dmFyKC0tbW9ubyl9QG1lZGlhKG1heC13aWR0aDo1NjBweCl7LnJvdywucm93M3tncmlk
LXRlbXBsYXRlLWNvbHVtbnM6MWZyfX0KPC9zdHlsZT48L2hlYWQ+PGJvZHk+CjxoZWFkZXI+CiA8
ZGl2IGNsYXNzPWJyYW5kPjxzdmcgeG1sbnM9Imh0dHA6Ly93d3cudzMub3JnLzIwMDAvc3ZnIiB2
aWV3Qm94PSItMjAgLTIwIDY2OCAzMzAiIHJvbGU9ImltZyIgYXJpYS1sYWJlbD0icEtPTSI+PGcg
ZmlsbD0ibm9uZSIgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIiBzdHJva2UtbGluZWpvaW49InJvdW5k
IiBzdHJva2Utd2lkdGg9IjMyIj48ZyBzdHJva2U9IiNGRkZGRkYiPjxwYXRoIGQ9Ik0yMCA4MCBW
MjY2Ij48L3BhdGg+PGNpcmNsZSBjeD0iNzIiIGN5PSIxMzMiIHI9IjUyIj48L2NpcmNsZT48cGF0
aCBkPSJNMTc4IDE2IFEyMDYgMTAwIDE3OCAxODQiPjwvcGF0aD48cGF0aCBkPSJNMTkyIDEwMCBD
MjI2IDk2IDI1MCA2MiAyNjYgMTYiPjwvcGF0aD48cGF0aCBkPSJNNDkyIDE4NCBWMzAgQzUyMiAz
MCA1MzQgMTA2IDU1MiAxMDYgQzU3MCAxMDYgNTgyIDMwIDYxMiAzMCBWMTg0Ij48L3BhdGg+PC9n
PjxwYXRoIHN0cm9rZT0iIzJFQzRGMSIgZD0iTTE5MiAxMDAgQzIzMyAxMDIgMjU2IDE4MyAzNjMg
MTgzIEE4MyA4MyAwIDAgMCAzNjMgMTcgQTgzIDgzIDAgMCAwIDI4MiAxMTgiPjwvcGF0aD48L2c+
PC9zdmc+PHNwYW4gY2xhc3M9cHJvZD5OZXR6c3RldWVydW5nPC9zcGFuPjwvZGl2PgogPGRpdiBj
bGFzcz1jaGlwPjxzcGFuIGNsYXNzPWRvdCBpZD1kb3Q+PC9zcGFuPjxzcGFuIGlkPXN0YXRlPuKA
kzwvc3Bhbj48L2Rpdj4KIDxkaXYgY2xhc3M9aHN0YXQ+CiAgPHNwYW4gaWQ9dGVjaGJhZGdlIGNs
YXNzPWJhZGdlIHN0eWxlPWRpc3BsYXk6bm9uZT48L3NwYW4+CiAgPHNwYW4+RnJlcXVlbnogPGIg
aWQ9ZnJlcT7igJM8L2I+PC9zcGFuPgogIDxzcGFuPkxhdWZ6ZWl0IDxiIGlkPXVwdGltZT7igJM8
L2I+PC9zcGFuPgogIDxzcGFuIGlkPW1zZz48L3NwYW4+CiA8L2Rpdj4KPC9oZWFkZXI+CjxkaXYg
Y2xhc3M9d3JhcD4KIDxkaXYgY2xhc3M9YmFubmVyPjxzcGFuPuKaoO+4jzwvc3Bhbj48c3Bhbj48
Yj5OdXIgYWJnZXNjaG90dGV0IGJldHJlaWJlbjwvYj4g4oCTIER1bW15IExvYWQgLyBLYWJlbCAr
IETDpG1wZnVuZyAvIGdlc2NoaXJtdC4gT2ZmZW5lcyBOZXR6IG9obmUgQXV0aGVudGlzaWVydW5n
ID0gSU1TSS1DYXRjaGVyLCB3ZW5uIGVzIGFic3RyYWhsdC4gTnVyIGVpZ2VuZSBUZXN0LVNJTXMs
IEtlbm51bmcgMDAxL3h4IChUZXN0KSBvZGVyIDk5OS94eCAocHJpdmF0KS48L3NwYW4+PC9kaXY+
CgogPGRpdiBjbGFzcz1jb250cm9scz4KICA8YnV0dG9uIGNsYXNzPWJpZ2J0biBpZD1idG5fZ3Nt
IG9uY2xpY2s9ImNtZCgnc3RhcnRfZ3NtJykiPjxzcGFuIGNsYXNzPWljPuKWtjwvc3Bhbj48c3Bh
bj5HU00gKDJHKTxzbWFsbCBpZD1nc21fc3ViPk9zbW9jb208L3NtYWxsPjwvc3Bhbj48L2J1dHRv
bj4KICA8YnV0dG9uIGNsYXNzPWJpZ2J0biBpZD1idG5fbHRlIG9uY2xpY2s9ImNtZCgnc3RhcnRf
bHRlJykiPjxzcGFuIGNsYXNzPWljPuKWtjwvc3Bhbj48c3Bhbj5MVEUgKDRHKTxzbWFsbCBpZD1s
dGVfc3ViPnNyc1JBTiArIE9wZW41R1M8L3NtYWxsPjwvc3Bhbj48L2J1dHRvbj4KICA8YnV0dG9u
IGNsYXNzPWJpZ2J0biBpZD1idG5fY3NmYiBvbmNsaWNrPSJjbWQoJ3N0YXJ0X2NzZmInKSI+PHNw
YW4gY2xhc3M9aWM+4pa2PC9zcGFuPjxzcGFuPkxURSArIEdTTTxzbWFsbCBpZD1jc2ZiX3N1Yj5J
bnRlcm5ldCArIEFucnVmZSAoQ1NGQik8L3NtYWxsPjwvc3Bhbj48L2J1dHRvbj4KICA8YnV0dG9u
IGNsYXNzPSJiaWdidG4gc3RvcCIgb25jbGljaz0iY21kKCdzdG9wJykiPuKWoCBTdG9wcGVuPC9i
dXR0b24+CiA8L2Rpdj4KCiA8ZGl2IGNsYXNzPXRhYnM+CiAgPGJ1dHRvbiBjbGFzcz0idGFiIHNl
bCIgZGF0YS10PXN0ZXVlcnVuZyBvbmNsaWNrPSJ0YWIoJ3N0ZXVlcnVuZycpIj5TdGV1ZXJ1bmc8
L2J1dHRvbj4KICA8YnV0dG9uIGNsYXNzPXRhYiBkYXRhLXQ9Z3NtIG9uY2xpY2s9InRhYignZ3Nt
JykiPkdTTSDCtyAyRzwvYnV0dG9uPgogIDxidXR0b24gY2xhc3M9dGFiIGRhdGEtdD1sdGUgb25j
bGljaz0idGFiKCdsdGUnKSI+TFRFIMK3IDRHPC9idXR0b24+CiAgPGJ1dHRvbiBjbGFzcz10YWIg
ZGF0YS10PXNpbXMgb25jbGljaz0idGFiKCdzaW1zJykiPlNJTXMgJiBOdW1tZXJuPC9idXR0b24+
CiAgPGJ1dHRvbiBjbGFzcz10YWIgZGF0YS10PXByb2ZpbCBvbmNsaWNrPSJ0YWIoJ3Byb2ZpbCcp
Ij5TSU0tUHJvZmlsPC9idXR0b24+CiAgPGJ1dHRvbiBjbGFzcz10YWIgZGF0YS10PWxvZyBvbmNs
aWNrPSJ0YWIoJ2xvZycpIj5Qcm90b2tvbGw8L2J1dHRvbj4KIDwvZGl2PgoKIDxkaXYgY2xhc3M9
InBhbmVsIHNlbCIgaWQ9cC1zdGV1ZXJ1bmc+CiAgPGRpdiBjbGFzcz1ncmlkPgogICA8ZGl2IGNs
YXNzPWNhcmQ+CiAgICA8aDI+U3RhdHVzPC9oMj4KICAgIDxkaXYgY2xhc3M9ZnJlcWJveCBzdHls
ZT1tYXJnaW4tdG9wOjEycHg+CiAgICAgPGRpdj48ZGl2IGNsYXNzPWJpZyBpZD1mcmVxMj7igJM8
L2Rpdj48ZGl2IGNsYXNzPXNtIGlkPWZyZXFzdWI+PC9kaXY+PC9kaXY+CiAgICAgPGRpdiBzdHls
ZT10ZXh0LWFsaWduOnJpZ2h0PjxkaXYgY2xhc3M9YmlnIGlkPXRlY2gyPmF1czwvZGl2PjxkaXYg
Y2xhc3M9c20gaWQ9c3RhdGVzdWI+PC9kaXY+PC9kaXY+CiAgICA8L2Rpdj4KICAgIDxkaXYgY2xh
c3M9aGludCBpZD11cHRpbWVoaW50PjwvZGl2PgogICAgPGRpdiBjbGFzcz1oaW50IGlkPWRldmhp
bnQ+PC9kaXY+CiAgICA8ZGl2IGNsYXNzPWhpbnQgaWQ9Y2xhc2ggc3R5bGU9Y29sb3I6dmFyKC0t
ZXJyKT48L2Rpdj4KICAgPC9kaXY+CiAgIDxkaXYgY2xhc3M9Y2FyZD4KICAgIDxoMj5GdW5rLUhh
cmR3YXJlPC9oMj4KICAgIDxwIGNsYXNzPXN1Yj5KZSBOZXR6IGVpbiBlaWdlbmVyIExpbWVTRFIu
IEbDvHIg4oCeTFRFICsgR1NN4oCcIHp3ZWkgdmVyc2NoaWVkZW5lIHfDpGhsZW4uPC9wPgogICAg
PGxhYmVsPkxpbWVTRFIgZsO8ciBHU00gKDJHKTwvbGFiZWw+PHNlbGVjdCBpZD1HU01fREVWPjwv
c2VsZWN0PgogICAgPGxhYmVsPkxpbWVTRFIgZsO8ciBMVEUgKDRHKTwvbGFiZWw+PHNlbGVjdCBp
ZD1MVEVfREVWPjwvc2VsZWN0PgogICAgPGRpdiBzdHlsZT1kaXNwbGF5OmZsZXg7Z2FwOjhweDtm
bGV4LXdyYXA6d3JhcD4KICAgICA8YnV0dG9uIGNsYXNzPWJ0biBvbmNsaWNrPSJzYXZlKFsnR1NN
X0RFVicsJ0xURV9ERVYnXSkiPlNwZWljaGVybjwvYnV0dG9uPgogICAgIDxidXR0b24gY2xhc3M9
ImJ0biBzZWMiIG9uY2xpY2s9ImNtZCgnbGltZV9zY2FuJykiPk5ldSBzdWNoZW48L2J1dHRvbj4K
ICAgIDwvZGl2PgogICAgPGRpdiBjbGFzcz1oaW50IGlkPWxpbWVsaXN0PjwvZGl2PgogICA8L2Rp
dj4KICAgPGRpdiBjbGFzcz1jYXJkPgogICAgPGgyPk5ldHotSWRlbnRpdMOkdDwvaDI+CiAgICA8
cCBjbGFzcz1zdWI+R2lsdCBmw7xyIEdTTSB1bmQgTFRFLiBOdXIgVGVzdGtlbm51bmcgMDAxL3h4
IG9kZXIgUHJpdmF0a2VubnVuZyA5OTkveHguPC9wPgogICAgPGRpdiBjbGFzcz1yb3c+CiAgICAg
PGRpdj48bGFiZWw+TUNDPC9sYWJlbD48aW5wdXQgaWQ9TUNDIGlucHV0bW9kZT1udW1lcmljPjwv
ZGl2PgogICAgIDxkaXY+PGxhYmVsPk1OQzwvbGFiZWw+PGlucHV0IGlkPU1OQyBpbnB1dG1vZGU9
bnVtZXJpYz48L2Rpdj4KICAgIDwvZGl2PgogICAgPGRpdiBjbGFzcz1yb3c+CiAgICAgPGRpdj48
bGFiZWw+TmV0em5hbWUgKGxhbmcpPC9sYWJlbD48aW5wdXQgaWQ9TkVUTkFNRT48L2Rpdj4KICAg
ICA8ZGl2PjxsYWJlbD5OZXR6bmFtZSAoa3Vyeik8L2xhYmVsPjxpbnB1dCBpZD1ORVROQU1FX1NI
T1JUPjwvZGl2PgogICAgPC9kaXY+CiAgICA8bGFiZWw+QW5iaWV0ZXJuYW1lIChTUE4sIG1heC4g
MTYgWmVpY2hlbik8L2xhYmVsPjxpbnB1dCBpZD1TUE4gbWF4bGVuZ3RoPTE2PgogICAgPGRpdiBj
bGFzcz1zdz48ZGl2IGNsYXNzPXQ+TklUWiBzZW5kZW48c21hbGw+TmV0em5hbWUsIFVocnplaXQg
dW5kIFplaXR6b25lICg8c3BhbiBpZD10ej7igJM8L3NwYW4+KSBiZWltIEVpbmJ1Y2hlbjwvc21h
bGw+PC9kaXY+CiAgICAgPGxhYmVsIGNsYXNzPXN3aXRjaD48aW5wdXQgdHlwZT1jaGVja2JveCBp
ZD1OSVRaPjxzcGFuIGNsYXNzPXNsaWRlcj48L3NwYW4+PC9sYWJlbD48L2Rpdj4KICAgIDxidXR0
b24gY2xhc3M9ImJ0biBzZWMiIG9uY2xpY2s9InNhdmUoWydNQ0MnLCdNTkMnLCdORVROQU1FJywn
TkVUTkFNRV9TSE9SVCcsJ1NQTicsJ05JVFonXSkiPlNwZWljaGVybjwvYnV0dG9uPgogICAgPHAg
Y2xhc3M9aGludD5EYW1pdCBkYXMgaVBob25lIGRhcyBOZXR6IGFscyA8Yj5IZWltbmV0ejwvYj4g
c2llaHQgKGtlaW4gUm9hbWluZyksIG11c3MgZGllIElNU0kgZGVyIGVTSU0gbWl0IE1DQytNTkMg
YmVnaW5uZW46IDxiIGNsYXNzPXRhZyBpZD1ocGxtbj7igJM8L2I+4oCmPC9wPgogICA8L2Rpdj4K
ICA8L2Rpdj4KIDwvZGl2PgoKIDxkaXYgY2xhc3M9cGFuZWwgaWQ9cC1nc20+CiAgPGRpdiBjbGFz
cz1ncmlkPgogICA8ZGl2IGNsYXNzPWNhcmQ+CiAgICA8aDI+R1NNLUZ1bms8L2gyPgogICAgPGRp
diBjbGFzcz1yb3cgc3R5bGU9YWxpZ24taXRlbXM6ZW5kPgogICAgIDxkaXY+PGxhYmVsPkFSRkNO
PC9sYWJlbD48aW5wdXQgaWQ9R1NNX0FSRkNOIG9uaW5wdXQ9dXBkYXRlRnJlcSgpPjwvZGl2Pgog
ICAgIDxkaXYgY2xhc3M9ZnJlcWJveD48ZGl2PjxkaXYgY2xhc3M9YmlnIGlkPWdzbV9taHo+4oCT
PC9kaXY+PGRpdiBjbGFzcz1zbSBpZD1nc21fYmFuZD48L2Rpdj48L2Rpdj48L2Rpdj4KICAgIDwv
ZGl2PgogICAgPGRpdiBjbGFzcz1oaW50PjHigJMxMjQgPSBHU005MDAgwrcgNTEy4oCTODg1ID0g
RENTMTgwMDwvZGl2PgogICAgPGRpdiBjbGFzcz1yb3c+PGRpdj48bGFiZWw+VFgtR2FpbjwvbGFi
ZWw+PGlucHV0IGlkPUdTTV9UWF9HQUlOPjwvZGl2PgogICAgIDxkaXY+PGxhYmVsPlJYLUdhaW4g
KDDigJM1MCk8L2xhYmVsPjxpbnB1dCBpZD1HU01fUlhfR0FJTj48L2Rpdj48L2Rpdj4KICAgIDxk
aXYgY2xhc3M9aGludD5SWC1HYWluIGhvY2ggPSBlbXBmaW5kbGljaGVyZXIgRW1wZmFuZyAod2lj
aHRpZyBmw7xyIEVER0UtVXBsaW5rKS48L2Rpdj4KICAgIDxidXR0b24gY2xhc3M9YnRuIG9uY2xp
Y2s9InNhdmUoWydHU01fQVJGQ04nLCdHU01fVFhfR0FJTicsJ0dTTV9SWF9HQUlOJ10pIj5TcGVp
Y2hlcm48L2J1dHRvbj4KICAgPC9kaXY+CiAgIDxkaXYgY2xhc3M9Y2FyZD4KICAgIDxoMj5HU00t
T3B0aW9uZW48L2gyPgogICAgPGRpdiBjbGFzcz0ic3cgZmlyc3QiPjxkaXYgY2xhc3M9dD5PZmZl
bmUgQW5tZWxkdW5nPHNtYWxsPmplZGUgU0lNIHdpcmQgZWluZ2VidWNodDwvc21hbGw+PC9kaXY+
CiAgICAgPGxhYmVsIGNsYXNzPXN3aXRjaD48aW5wdXQgdHlwZT1jaGVja2JveCBpZD1HU01fT1BF
Tj48c3BhbiBjbGFzcz1zbGlkZXI+PC9zcGFuPjwvbGFiZWw+PC9kaXY+CiAgICA8ZGl2IGNsYXNz
PXN3PjxkaXYgY2xhc3M9dD5FREdFIC8gR1BSUy1EYXRlbjxzbWFsbD5QYWtldGRhdGVuIChwY3Uv
c2dzbi9nZ3NuKTwvc21hbGw+PC9kaXY+CiAgICAgPGxhYmVsIGNsYXNzPXN3aXRjaD48aW5wdXQg
dHlwZT1jaGVja2JveCBpZD1HU01fREFUQT48c3BhbiBjbGFzcz1zbGlkZXI+PC9zcGFuPjwvbGFi
ZWw+PC9kaXY+CiAgICA8ZGl2IGNsYXNzPXN3PjxkaXYgY2xhc3M9dD5TSVAtVHJ1bmsgenUgQXN0
ZXJpc2s8c21hbGw+QW5ydWZlIGlucyBWb0lQL0Zlc3RuZXR6PC9zbWFsbD48L2Rpdj4KICAgICA8
bGFiZWwgY2xhc3M9c3dpdGNoPjxpbnB1dCB0eXBlPWNoZWNrYm94IGlkPUdTTV9TSVA+PHNwYW4g
Y2xhc3M9c2xpZGVyPjwvc3Bhbj48L2xhYmVsPjwvZGl2PgogICAgPGxhYmVsPlNJUC1QZWVyIChB
c3Rlcmlzay1JUCk8L2xhYmVsPjxpbnB1dCBpZD1HU01fU0lQX1BFRVI+CiAgICA8bGFiZWw+U0lQ
LUxvY2FsLUlQIChsZWVyID0gYXV0b21hdGlzY2gpPC9sYWJlbD48aW5wdXQgaWQ9R1NNX1NJUF9M
T0NBTD4KICAgIDxidXR0b24gY2xhc3M9YnRuIG9uY2xpY2s9InNhdmUoWydHU01fT1BFTicsJ0dT
TV9EQVRBJywnR1NNX1NJUCcsJ0dTTV9TSVBfUEVFUicsJ0dTTV9TSVBfTE9DQUwnXSkiPlNwZWlj
aGVybjwvYnV0dG9uPgogICA8L2Rpdj4KICAgPGRpdiBjbGFzcz1jYXJkPgogICAgPGgyPkJlZ3LD
vMOfdW5ncy1TTVM8L2gyPgogICAgPHAgY2xhc3M9c3ViPlNNUyBiZWltIEVpbmJ1Y2hlbiB1bmQg
YmVpIE51bW1lcm52ZXJnYWJlLiBQbGF0emhhbHRlcjogPGNvZGU+e25ldHp9PC9jb2RlPiwgPGNv
ZGU+e251bW1lcn08L2NvZGU+LCA8Y29kZT57ZXh0ZXJufTwvY29kZT4uPC9wPgogICAgPGRpdiBj
bGFzcz0ic3cgZmlyc3QiPjxkaXYgY2xhc3M9dD5TTVMgYWt0aXY8c21hbGw+V2lsbGtvbW1lbiAr
IE51bW1lcm4tQmVzdMOkdGlndW5nPC9zbWFsbD48L2Rpdj4KICAgICA8bGFiZWwgY2xhc3M9c3dp
dGNoPjxpbnB1dCB0eXBlPWNoZWNrYm94IGlkPUdTTV9TTVM+PHNwYW4gY2xhc3M9c2xpZGVyPjwv
c3Bhbj48L2xhYmVsPjwvZGl2PgogICAgPGxhYmVsPkFic2VuZGVyLU51bW1lcjwvbGFiZWw+PGlu
cHV0IGlkPUdTTV9TTVNfRlJPTT4KICAgIDxsYWJlbD5FeHRlcm5lIFZvcndhaGwgKDxjb2RlPntl
eHRlcm59PC9jb2RlPiA9IFZvcndhaGwgKyBpbnRlcm5lIE51bW1lcik8L2xhYmVsPjxpbnB1dCBp
ZD1HU01fU01TX0VYVFBSRUZJWD4KICAgIDxsYWJlbD5XaWxsa29tbWVuc3RleHQgKGJlaW0gRWlu
YnVjaGVuKTwvbGFiZWw+PGlucHV0IGlkPUdTTV9TTVNfV0VMQ09NRT4KICAgIDxsYWJlbD5CZXN0
w6R0aWd1bmcgKGJlaSBOdW1tZXJudmVyZ2FiZSk8L2xhYmVsPjxpbnB1dCBpZD1HU01fU01TX05V
TUJFUj4KICAgIDxidXR0b24gY2xhc3M9YnRuIG9uY2xpY2s9InNhdmUoWydHU01fU01TJywnR1NN
X1NNU19GUk9NJywnR1NNX1NNU19FWFRQUkVGSVgnLCdHU01fU01TX1dFTENPTUUnLCdHU01fU01T
X05VTUJFUiddKSI+U3BlaWNoZXJuPC9idXR0b24+CiAgICA8cCBjbGFzcz1oaW50PkJlZ3LDvMOf
dW5nIHdpcmQgamUgTmV0ei1TdGFydCBlaW5tYWwgcHJvIFNJTSBnZXNlbmRldCAod2lya3Qgc29m
b3J0KS48L3A+CiAgICA8ZGl2IHN0eWxlPSJib3JkZXItdG9wOjFweCBzb2xpZCB2YXIoLS1saW5l
KTttYXJnaW46MTRweCAwIj48L2Rpdj4KICAgIDxkaXYgY2xhc3M9cm93PjxkaXY+PGxhYmVsPlRl
c3Q6IElNU0k8L2xhYmVsPjxpbnB1dCBpZD1zbXNfdGVzdF9pbXNpPjwvZGl2PgogICAgIDxkaXY+
PGxhYmVsPlRleHQgKGxlZXIgPSBXaWxsa29tbWVuc3RleHQpPC9sYWJlbD48aW5wdXQgaWQ9c21z
X3Rlc3RfdGV4dD48L2Rpdj48L2Rpdj4KICAgIDxidXR0b24gY2xhc3M9ImJ0biBzZWMiIG9uY2xp
Y2s9InNtc3Rlc3QoKSI+VGVzdC1TTVMgc2VuZGVuPC9idXR0b24+CiAgICA8cCBjbGFzcz1oaW50
PlNlbmRldCBzb2ZvcnQgYW4gZGllIElNU0kg4oCTIGF1Y2ggd2VubiDigJ5TTVMgYWt0aXYiIGF1
cyBpc3QuIEdTTSBtdXNzIGxhdWZlbi48L3A+CiAgIDwvZGl2PgogIDwvZGl2PgogIDxwIGNsYXNz
PWhpbnQ+RnVuay0vT3B0aW9ucy3DhG5kZXJ1bmdlbiB3aXJrZW4gYmVpbSBuw6RjaHN0ZW4gR1NN
LVN0YXJ0LjwvcD4KIDwvZGl2PgoKIDxkaXYgY2xhc3M9cGFuZWwgaWQ9cC1sdGU+CiAgPGRpdiBj
bGFzcz1ncmlkPgogICA8ZGl2IGNsYXNzPWNhcmQ+CiAgICA8aDI+TFRFLUZ1bms8L2gyPgogICAg
PGRpdiBjbGFzcz1yb3cgc3R5bGU9YWxpZ24taXRlbXM6ZW5kPgogICAgIDxkaXY+PGxhYmVsPkVB
UkZDTjwvbGFiZWw+PGlucHV0IGlkPUxURV9FQVJGQ04gb25pbnB1dD11cGRhdGVGcmVxKCk+PC9k
aXY+CiAgICAgPGRpdiBjbGFzcz1mcmVxYm94PjxkaXY+PGRpdiBjbGFzcz1iaWcgaWQ9bHRlX21o
ej7igJM8L2Rpdj48ZGl2IGNsYXNzPXNtIGlkPWx0ZV9iYW5kPjwvZGl2PjwvZGl2PjwvZGl2Pgog
ICAgPC9kaXY+CiAgICA8bGFiZWw+QmFuZGJyZWl0ZSAoUFJCKTwvbGFiZWw+PHNlbGVjdCBpZD1M
VEVfTlBSQj4KICAgICA8b3B0aW9uIHZhbHVlPTY+NiDCtyAxLjQgTUh6PC9vcHRpb24+PG9wdGlv
biB2YWx1ZT0xNT4xNSDCtyAzIE1Iejwvb3B0aW9uPgogICAgIDxvcHRpb24gdmFsdWU9MjU+MjUg
wrcgNSBNSHo8L29wdGlvbj48b3B0aW9uIHZhbHVlPTUwPjUwIMK3IDEwIE1Iejwvb3B0aW9uPgog
ICAgIDxvcHRpb24gdmFsdWU9NzU+NzUgwrcgMTUgTUh6PC9vcHRpb24+PG9wdGlvbiB2YWx1ZT0x
MDA+MTAwIMK3IDIwIE1Iejwvb3B0aW9uPjwvc2VsZWN0PgogICAgPGRpdiBjbGFzcz1oaW50PlNj
aHdhY2hlIEhhcmR3YXJlIChQaSk6IGtsZWluIHfDpGhsZW4gKDbigJMyNSkuPC9kaXY+CiAgICA8
YnV0dG9uIGNsYXNzPWJ0biBvbmNsaWNrPSJzYXZlKFsnTFRFX0VBUkZDTicsJ0xURV9OUFJCJ10p
Ij5TcGVpY2hlcm48L2J1dHRvbj4KICAgPC9kaXY+CiAgIDxkaXYgY2xhc3M9Y2FyZD4KICAgIDxo
Mj5MVEUtUGFyYW1ldGVyPC9oMj4KICAgIDxkaXYgY2xhc3M9cm93PjxkaXY+PGxhYmVsPlRYLUdh
aW48L2xhYmVsPjxpbnB1dCBpZD1MVEVfVFhfR0FJTj48L2Rpdj4KICAgICA8ZGl2PjxsYWJlbD5S
WC1HYWluPC9sYWJlbD48aW5wdXQgaWQ9TFRFX1JYX0dBSU4+PC9kaXY+PC9kaXY+CiAgICA8bGFi
ZWw+QVBOPC9sYWJlbD48aW5wdXQgaWQ9TFRFX0FQTj4KICAgIDxidXR0b24gY2xhc3M9YnRuIG9u
Y2xpY2s9InNhdmUoWydMVEVfVFhfR0FJTicsJ0xURV9SWF9HQUlOJywnTFRFX0FQTiddKSI+U3Bl
aWNoZXJuPC9idXR0b24+CiAgICA8cCBjbGFzcz1oaW50PkxURSBicmF1Y2h0IFNJTXMgbWl0IEtp
L09QYyAoVGFiIOKAnlNJTXPigJwpLiBLZXJuOiBPcGVuNUdTLCBIYW5keS1OZXR6IDEwLjQ1LjAu
MC8xNiBtaXQgTkFUIGlucyBJbnRlcm5ldC4gQmVpIOKAnkxURSArIEdTTeKAnCBkYXJmIGRpZSBH
U00tRnJlcXVlbnogbmljaHQgaW0gTFRFLUthbmFsIGxpZWdlbi48L3A+CiAgIDwvZGl2PgogIDwv
ZGl2PgogPC9kaXY+CgogPGRpdiBjbGFzcz1wYW5lbCBpZD1wLXNpbXM+CiAgPGRpdiBjbGFzcz0i
Y2FyZCIgc3R5bGU9Im1hcmdpbi1ib3R0b206MTZweCI+CiAgIDxoMj5TSU0tRGF0ZW4gZXJ6ZXVn
ZW48L2gyPgogICA8cCBjbGFzcz1zdWI+RsO8ciBlaWdlbmUgZVNJTS1Qcm9maWxlICh6LiZuYnNw
O0IuIHNpbWxlc3NseSk6IElNU0kgcGFzc2VuZCB6dXIgS2VubnVuZywgenVmw6RsbGlnZSBTY2hs
w7xzc2VsIChLaSwgT1Ag4oaSIE9QYyBuYWNoIE1pbGVuYWdlKSwgSUNDSUQgbWl0IFByw7xmemlm
ZmVyLCBQSU4vUFVLL0FETS4gQmxlaWJ0IG51ciBpbSBCcm93c2VyLCBiaXMgZHUgZXMgw7xiZXJu
aW1tc3QuPC9wPgogICA8ZGl2IGNsYXNzPXJvdzM+CiAgICA8ZGl2PjxsYWJlbD5BbnphaGwgKDHi
gJM1MCk8L2xhYmVsPjxpbnB1dCBpZD1nZW5fbiB0eXBlPW51bWJlciBtaW49MSBtYXg9NTAgdmFs
dWU9MT48L2Rpdj4KICAgIDxkaXY+PGxhYmVsPkVyc3RlIFJ1Zm51bW1lciAobGVlciA9IGtlaW5l
KTwvbGFiZWw+PGlucHV0IGlkPWdlbl9uciBpbnB1dG1vZGU9bnVtZXJpYyBwbGFjZWhvbGRlcj0i
ei4gQi4gOTIwMSI+PC9kaXY+CiAgICA8ZGl2PjxsYWJlbD5JQ0NJRC1QcsOkZml4IChsZWVyID0g
ODkrTUNDK01OQyk8L2xhYmVsPjxpbnB1dCBpZD1nZW5faWNjaWQgaW5wdXRtb2RlPW51bWVyaWM+
PC9kaXY+CiAgIDwvZGl2PgogICA8ZGl2IHN0eWxlPWRpc3BsYXk6ZmxleDtnYXA6OHB4O2ZsZXgt
d3JhcDp3cmFwPgogICAgPGJ1dHRvbiBjbGFzcz1idG4gb25jbGljaz0ic2ltZ2VuKCkiPkVyemV1
Z2VuPC9idXR0b24+CiAgICA8YnV0dG9uIGNsYXNzPSJidG4gc2VjIiBpZD1nZW5fdGFrZSBvbmNs
aWNrPSJnZW50YWtlKCkiIGRpc2FibGVkPkFsbGUgaW4gcEtPTSDDvGJlcm5laG1lbjwvYnV0dG9u
PgogICAgPGJ1dHRvbiBjbGFzcz0iYnRuIHNlYyIgaWQ9Z2VuX2NzdiBvbmNsaWNrPSJnZW5kbCgn
Y3N2JykiIGRpc2FibGVkPkNTVjwvYnV0dG9uPgogICAgPGJ1dHRvbiBjbGFzcz0iYnRuIHNlYyIg
aWQ9Z2VuX2pzb24gb25jbGljaz0iZ2VuZGwoJ2pzb24nKSIgZGlzYWJsZWQ+SlNPTjwvYnV0dG9u
PgogICA8L2Rpdj4KICAgPGRpdiBjbGFzcz1nZW53cmFwPjx0YWJsZSBjbGFzcz1lZiBpZD1nZW5f
dGFiPjwvdGFibGU+PC9kaXY+CiAgIDxwIGNsYXNzPWhpbnQ+QU1GIDgwMDAsIFNRTi1TdGFydCAw
MDAwMDAwMDAwMjAsIEFsZ29yaXRobXVzIE1pbGVuYWdlLiBJbSBlU0lNLVByb2ZpbCBkaWUgSU1T
SSwgS2kgdW5kIE9QYyAob2RlciBPUCkgZWludHJhZ2VuOyBkYXp1IFNQTi9QTk4vT1BMIGF1cyBk
ZW0gVGFiIOKAnlNJTS1Qcm9maWzigJwuPC9wPgogIDwvZGl2PgogIDxkaXYgY2xhc3M9Z3JpZD4K
ICAgPGRpdiBjbGFzcz1jYXJkPgogICAgPGgyPlNJTSBlaW50cmFnZW48L2gyPgogICAgPHAgY2xh
c3M9c3ViPkVpbm1hbCBlaW50cmFnZW4g4oCTIHBLT00gc2NocmVpYnQgc2llIGF1dG9tYXRpc2No
IGlucyBHU00tSExSIHVuZCBpbiBkZW4gTFRFLUhTUy48L3A+CiAgICA8ZGl2IGNsYXNzPXJvdz48
ZGl2PjxsYWJlbD5JTVNJPC9sYWJlbD48aW5wdXQgaWQ9c2ltX2ltc2kgaW5wdXRtb2RlPW51bWVy
aWM+PC9kaXY+PGRpdj48bGFiZWw+UnVmbnVtbWVyPC9sYWJlbD48aW5wdXQgaWQ9c2ltX25yIGlu
cHV0bW9kZT1udW1lcmljPjwvZGl2PjwvZGl2PgogICAgPGRpdiBjbGFzcz1yb3c+PGRpdj48bGFi
ZWw+S2kgKDMyIEhleCk8L2xhYmVsPjxpbnB1dCBpZD1zaW1fa2kgYXV0b2NvbXBsZXRlPW9mZj48
L2Rpdj48ZGl2PjxsYWJlbD5PUGMgKDMyIEhleCk8L2xhYmVsPjxpbnB1dCBpZD1zaW1fb3BjIGF1
dG9jb21wbGV0ZT1vZmY+PC9kaXY+PC9kaXY+CiAgICA8YnV0dG9uIGNsYXNzPSJidG4gc20iIG9u
Y2xpY2s9InNpbWFkZCgpIj5TSU0gc3BlaWNoZXJuPC9idXR0b24+CiAgICA8ZGl2IHN0eWxlPW1h
cmdpbi10b3A6MTJweCBpZD1zaW1zPjwvZGl2PgogICA8L2Rpdj4KICAgPGRpdiBjbGFzcz1jYXJk
PgogICAgPGgyPkVpbmdlYnVjaHRlIEhhbmR5czwvaDI+CiAgICA8cCBjbGFzcz1zdWI+QWt0dWVs
bCBpbSBTcHJhY2huZXR6IChNU0MpIGFuZ2VtZWxkZXQg4oCTIGJlaSDigJ5MVEUgKyBHU03igJwg
YXVjaCDDvGJlciBMVEUvU0dzLjwvcD4KICAgIDxkaXYgaWQ9YXR0YWNoZWQ+PC9kaXY+CiAgIDwv
ZGl2PgogICA8ZGl2IGNsYXNzPWNhcmQ+CiAgICA8aDI+TnVtbWVyIGRhdWVyaGFmdCB6dXdlaXNl
bjwvaDI+CiAgICA8cCBjbGFzcz1zdWI+QXVjaCBmw7xyIG9mZmVuIGFuZ2VtZWxkZXRlIEdTTS1T
SU1zIG9obmUgS2kg4oCTIMO8YmVybGVidCBOZXVzdGFydHMuPC9wPgogICAgPGRpdiBjbGFzcz1y
b3c+PGRpdj48bGFiZWw+SU1TSTwvbGFiZWw+PGlucHV0IGlkPWdudW1faW1zaT48L2Rpdj48ZGl2
PjxsYWJlbD5SdWZudW1tZXI8L2xhYmVsPjxpbnB1dCBpZD1nbnVtX25yPjwvZGl2PjwvZGl2Pgog
ICAgPGJ1dHRvbiBjbGFzcz0iYnRuIHNtIiBvbmNsaWNrPSJzaW1ucigpIj5adXdlaXNlbjwvYnV0
dG9uPgogICAgPGRpdiBzdHlsZT1tYXJnaW4tdG9wOjEycHggaWQ9Z3NtX251bWJlcnM+PC9kaXY+
CiAgIDwvZGl2PgogIDwvZGl2PgogPC9kaXY+CgogPGRpdiBjbGFzcz1wYW5lbCBpZD1wLXByb2Zp
bD4KICA8ZGl2IGNsYXNzPWNhcmQ+CiAgIDxoMj5XZXJ0ZSBmw7xyIGRhcyBlU0lNLVByb2ZpbDwv
aDI+CiAgIDxwIGNsYXNzPXN1Yj5PUEwsIFBOTiB1bmQgU1BOIHNpbmQgRGF0ZWllbiA8Yj5hdWYg
ZGVyIFNJTTwvYj4g4oCTIGRhcyBOZXR6IGthbm4gc2llIG5pY2h0IHNldHplbi4gRGllc2UgV2Vy
dGUgcGFzc2VuIHp1IEtlbm51bmcgdW5kIE5ldHpuYW1lIG9iZW4gdW5kIHdlcmRlbiBpbSBlU0lN
LVByb2ZpbCAoei4mbmJzcDtCLiBzaW1sZXNzbHkpIGVpbmdldHJhZ2VuLiBOSVRaIHNjaGlja3Qg
cEtPTSBzZWxic3QuPC9wPgogICA8dGFibGUgY2xhc3M9ZWY+CiAgICA8dHI+PHRoPkRhdGVpPC90
aD48dGg+SW5oYWx0PC90aD48dGg+V2VydCAoSGV4KTwvdGg+PC90cj4KICAgIDx0cj48dGQ+PGI+
U1BOPC9iPjxicj48c3BhbiBjbGFzcz1tdXQ+RUYgNkY0Njwvc3Bhbj48L3RkPjx0ZCBpZD1lZl9z
cG5fdD48L3RkPjx0ZD48Y29kZSBpZD1lZl9zcG4+PC9jb2RlPjwvdGQ+PC90cj4KICAgIDx0cj48
dGQ+PGI+UE5OPC9iPjxicj48c3BhbiBjbGFzcz1tdXQ+RUYgNkZDNSwgRWludHJhZyAxPC9zcGFu
PjwvdGQ+PHRkIGlkPWVmX3Bubl90PjwvdGQ+PHRkPjxjb2RlIGlkPWVmX3Bubj48L2NvZGU+PC90
ZD48L3RyPgogICAgPHRyPjx0ZD48Yj5PUEw8L2I+PGJyPjxzcGFuIGNsYXNzPW11dD5FRiA2RkM2
LCBFaW50cmFnIDE8L3NwYW4+PC90ZD48dGQgaWQ9ZWZfb3BsX3Q+PC90ZD48dGQ+PGNvZGUgaWQ9
ZWZfb3BsPjwvY29kZT48L3RkPjwvdHI+CiAgICA8dHI+PHRkPjxiPkhQTE1OPC9iPjxicj48c3Bh
biBjbGFzcz1tdXQ+SU1TSS1BbmZhbmc8L3NwYW4+PC90ZD48dGQ+SGVpbW5ldHotS2VubnVuZzwv
dGQ+PHRkPjxjb2RlIGlkPWVmX2hwbG1uPjwvY29kZT48L3RkPjwvdHI+CiAgIDwvdGFibGU+CiAg
IDxwIGNsYXNzPWhpbnQ+RGF0ZW5zw6R0emUgYmVpIGZlc3RlciBMw6RuZ2UgbWl0IDxjb2RlPkZG
PC9jb2RlPiBhdWZmw7xsbGVuLiBJbiBkZXIgVVNJTS1EaWVuc3R0YWJlbGxlIChVU1QpIG3DvHNz
ZW4gZGllIERpZW5zdGUgPGI+MTc8L2I+IChTUE4pLCA8Yj40NTwvYj4gKFBOTikgdW5kIDxiPjQ2
PC9iPiAoT1BMKSBha3RpdiBzZWluLiDDhG5kZXJuIHNpY2ggS2VubnVuZyBvZGVyIE5hbWUsIGRp
ZSBXZXJ0ZSBoaWVyIG5ldSDDvGJlcm5laG1lbi48L3A+CiAgPC9kaXY+CiA8L2Rpdj4KCiA8ZGl2
IGNsYXNzPXBhbmVsIGlkPXAtbG9nPgogIDxkaXYgY2xhc3M9Y2FyZD4KICAgPGRpdiBjbGFzcz10
b29sYmFyPjxoMiBzdHlsZT1tYXJnaW46MD5Qcm90b2tvbGw8L2gyPjxpbnB1dCBpZD1sb2dmaWx0
ZXIgcGxhY2Vob2xkZXI9ImZpbHRlcm7igKYgei5CLiBHUFJTLCBUQkYsIGVycm9yIiBvbmlucHV0
PXJlbmRlcmxvZygpPjxzcGFuIGNsYXNzPWJhZGdlIGlkPWxvZ2NvdW50Pjwvc3Bhbj48L2Rpdj4K
ICAgPGRpdiBjbGFzcz1sb2cgaWQ9bG9nPjwvZGl2PgogIDwvZGl2PgogPC9kaXY+CjwvZGl2Pgo8
c2NyaXB0PgpsZXQgUz17fTsKYXN5bmMgZnVuY3Rpb24gYXBpKGMsYil7Y29uc3Qgcj1hd2FpdCBm
ZXRjaCgnL2FwaS8nK2Mse21ldGhvZDonUE9TVCcsaGVhZGVyczp7J0NvbnRlbnQtVHlwZSc6J2Fw
cGxpY2F0aW9uL2pzb24nfSxib2R5OkpTT04uc3RyaW5naWZ5KGJ8fHt9KX0pO3JldHVybiByLmpz
b24oKTt9CmZ1bmN0aW9uICQoaSl7cmV0dXJuIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKGkpO30K
ZnVuY3Rpb24gZXNjKHMpe3JldHVybiBTdHJpbmcocz09bnVsbD8nJzpzKS5yZXBsYWNlKC9bJjw+
IiddL2csYz0+KHsnJic6JyZhbXA7JywnPCc6JyZsdDsnLCc+JzonJmd0OycsJyInOicmcXVvdDsn
LCInIjonJiMzOTsnfVtjXSkpO30KZnVuY3Rpb24gY21kKGMpe2lmKGMuc3RhcnRzV2l0aCgnc3Rh
cnQnKSkkKCdtc2cnKS50ZXh0Q29udGVudD0nc3RhcnRldOKApic7YXBpKGMpLnRoZW4ocj0+e2lm
KGM9PT0nbGltZV9zY2FuJylsaW1lS2V5PScnO3JlbmRlcihyKTt9KTt9CmZ1bmN0aW9uIHRhYihu
KXtkb2N1bWVudC5xdWVyeVNlbGVjdG9yQWxsKCcudGFiJykuZm9yRWFjaCh0PT50LmNsYXNzTGlz
dC50b2dnbGUoJ3NlbCcsdC5kYXRhc2V0LnQ9PT1uKSk7ZG9jdW1lbnQucXVlcnlTZWxlY3RvckFs
bCgnLnBhbmVsJykuZm9yRWFjaChwPT5wLmNsYXNzTGlzdC50b2dnbGUoJ3NlbCcscC5pZD09PSdw
LScrbikpO3RyeXtsb2NhbFN0b3JhZ2Uuc2V0SXRlbSgncGtvbV90YWInLG4pO31jYXRjaChlKXt9
fQpmdW5jdGlvbiBzYXZlKGtleXMpe2xldCBiPXt9O2tleXMuZm9yRWFjaChrPT57bGV0IGVsPSQo
ayk7YltrXT1lbC50eXBlPT09J2NoZWNrYm94Jz8oZWwuY2hlY2tlZD8nMSc6JzAnKTplbC52YWx1
ZTt9KTthcGkoJ3NldCcsYikudGhlbihyPT57ZmlsbGVkPWZhbHNlO3JlbmRlcihyKTt9KTt9CmZ1
bmN0aW9uIHNpbWFkZCgpe2FwaSgnc2ltX2FkZCcse2ltc2k6JCgnc2ltX2ltc2knKS52YWx1ZSxr
aTokKCdzaW1fa2knKS52YWx1ZSxvcGM6JCgnc2ltX29wYycpLnZhbHVlLG1zaXNkbjokKCdzaW1f
bnInKS52YWx1ZX0pLnRoZW4ocj0+e2lmKCEvYWJlcnxwcnVlZmVuLy50ZXN0KHIubXNnfHwnJykp
e1snc2ltX2ltc2knLCdzaW1fa2knLCdzaW1fb3BjJywnc2ltX25yJ10uZm9yRWFjaChpPT4kKGkp
LnZhbHVlPScnKTt9cmVuZGVyKHIpO30pO30KZnVuY3Rpb24gc2ltbnIoKXthcGkoJ2dzbV9zaW1f
bnInLHtpbXNpOiQoJ2dudW1faW1zaScpLnZhbHVlLG1zaXNkbjokKCdnbnVtX25yJykudmFsdWV9
KS50aGVuKHJlbmRlcik7fQpmdW5jdGlvbiBzbXN0ZXN0KCl7YXBpKCdzbXNfdGVzdCcse2ltc2k6
JCgnc21zX3Rlc3RfaW1zaScpLnZhbHVlLHRleHQ6JCgnc21zX3Rlc3RfdGV4dCcpLnZhbHVlfSku
dGhlbihyZW5kZXIpO30KZnVuY3Rpb24gc2ltZGVsKGkpe2lmKGNvbmZpcm0oJ1NJTSAnK2krJyBh
dXMgR1NNIHVuZCBMVEUgbMO2c2NoZW4/JykpYXBpKCdzaW1fZGVsJyx7aW1zaTppfSkudGhlbihy
ZW5kZXIpO30KZnVuY3Rpb24gbnVtZGVsKGkpe2FwaSgnZ3NtX251bV9kZWwnLHtpbXNpOml9KS50
aGVuKHJlbmRlcik7fQpmdW5jdGlvbiBnc21JbmZvKGEpe2E9K2F8fDA7bGV0IG09MCxiPScnO2lm
KGE+PTEmJmE8PTEyNCl7bT05MzUrMC4yKmE7Yj0nR1NNOTAwJzt9ZWxzZSBpZihhPj01MTImJmE8
PTg4NSl7bT0xODA1LjIrMC4yKihhLTUxMik7Yj0nRENTMTgwMCc7fXJldHVybnttaHo6bT9tLnRv
Rml4ZWQoMSkrJyBNSHonOifigJMnLGJhbmQ6Yn07fQpmdW5jdGlvbiBsdGVJbmZvKGUpe2U9K2V8
fDA7bGV0IG09MCxiPTA7aWYoZT49MCYmZTw9NTk5KXttPTIxMTArMC4xKmU7Yj0xO31lbHNlIGlm
KGU+PTEyMDAmJmU8PTE5NDkpe209MTgwNSswLjEqKGUtMTIwMCk7Yj0zO31lbHNlIGlmKGU+PTI3
NTAmJmU8PTM0NDkpe209MjYyMCswLjEqKGUtMjc1MCk7Yj03O31lbHNlIGlmKGU+PTYxNTAmJmU8
PTY0NDkpe209NzkxKzAuMSooZS02MTUwKTtiPTIwO31yZXR1cm57bWh6Om0/bS50b0ZpeGVkKDEp
KycgTUh6Jzon4oCTJyxiYW5kOmI/J0JhbmQgJytiOicnfTt9CmZ1bmN0aW9uIHVwZGF0ZUZyZXEo
KXtsZXQgZz1nc21JbmZvKCQoJ0dTTV9BUkZDTicpLnZhbHVlKTskKCdnc21fbWh6JykudGV4dENv
bnRlbnQ9Zy5taHo7JCgnZ3NtX2JhbmQnKS50ZXh0Q29udGVudD1nLmJhbmQ7bGV0IGw9bHRlSW5m
bygkKCdMVEVfRUFSRkNOJykudmFsdWUpOyQoJ2x0ZV9taHonKS50ZXh0Q29udGVudD1sLm1oejsk
KCdsdGVfYmFuZCcpLnRleHRDb250ZW50PWwuYmFuZDt9CmZ1bmN0aW9uIHNldHYoaWQsdil7bGV0
IGVsPSQoaWQpO2lmKCFlbClyZXR1cm47aWYoZWwudHlwZT09PSdjaGVja2JveCcpZWwuY2hlY2tl
ZD0odj09PScxJ3x8dj09PXRydWUpO2Vsc2UgZWwudmFsdWU9KHY9PW51bGw/Jyc6dik7fQpjb25z
dCBGSUVMRFM9WydNQ0MnLCdNTkMnLCdORVROQU1FJywnTkVUTkFNRV9TSE9SVCcsJ1NQTicsJ05J
VFonLCdHU01fREVWJywnTFRFX0RFVicsJ0dTTV9BUkZDTicsJ0dTTV9UWF9HQUlOJywnR1NNX1JY
X0dBSU4nLCdHU01fU0lQX1BFRVInLCdHU01fU0lQX0xPQ0FMJywnR1NNX09QRU4nLCdHU01fREFU
QScsJ0dTTV9TSVAnLCdHU01fU01TJywnR1NNX1NNU19GUk9NJywnR1NNX1NNU19FWFRQUkVGSVgn
LCdHU01fU01TX1dFTENPTUUnLCdHU01fU01TX05VTUJFUicsJ0xURV9FQVJGQ04nLCdMVEVfTlBS
QicsJ0xURV9UWF9HQUlOJywnTFRFX1JYX0dBSU4nLCdMVEVfQVBOJ107CmxldCBmaWxsZWQ9ZmFs
c2UsbGltZUtleT0nJzsKZnVuY3Rpb24gbGltZU9wdGlvbnMocyl7CiBjb25zdCBMPXMubGltZXN8
fFtdLGM9cy5jb25mfHx7fSxrZXk9SlNPTi5zdHJpbmdpZnkoTCkrKGMuR1NNX0RFVnx8JycpKyhj
LkxURV9ERVZ8fCcnKTsKIGlmKGtleT09PWxpbWVLZXkpcmV0dXJuO2xpbWVLZXk9a2V5OwogWydH
U01fREVWJywnTFRFX0RFViddLmZvckVhY2goaWQ9Pntjb25zdCBlbD0kKGlkKSxjdXI9Y1tpZF18
fCcnOwogIGxldCBvPSc8b3B0aW9uIHZhbHVlPSIiPmF1dG9tYXRpc2NoPC9vcHRpb24+JytMLm1h
cChkPT4nPG9wdGlvbiB2YWx1ZT0iJytlc2MoZC5zZXJpYWwpKyciPicrZXNjKGQubmFtZSkrJyDC
tyAnK2VzYyhkLnNlcmlhbCkrKGQubWVkaWE/JyDCtyAnK2VzYyhkLm1lZGlhKTonJykrJzwvb3B0
aW9uPicpLmpvaW4oJycpOwogIGlmKGN1ciYmIUwuc29tZShkPT5kLnNlcmlhbD09PWN1cikpbys9
JzxvcHRpb24gdmFsdWU9IicrZXNjKGN1cikrJyI+Jytlc2MoY3VyKSsnIChuaWNodCBnZWZ1bmRl
bik8L29wdGlvbj4nOwogIGVsLmlubmVySFRNTD1vO2VsLnZhbHVlPWN1cjt9KTsKICQoJ2xpbWVs
aXN0JykudGV4dENvbnRlbnQ9TC5sZW5ndGg/TC5sZW5ndGgrJyBMaW1lU0RSIGFuZ2VzY2hsb3Nz
ZW4nOidLZWluIExpbWVTRFIgZ2VmdW5kZW4g4oCTIFVTQiBwcsO8ZmVuIHVuZCDigJ5OZXUgc3Vj
aGVu4oCcLic7Cn0KZnVuY3Rpb24gcmVsb2FkRmllbGRzKCl7Y29uc3QgYz1TLmNvbmZ8fHt9O0ZJ
RUxEUy5mb3JFYWNoKGs9PntpZihkb2N1bWVudC5hY3RpdmVFbGVtZW50IT09JChrKSlzZXR2KGss
Y1trXSk7fSk7ZmlsbGVkPXRydWU7dXBkYXRlRnJlcSgpO30KZnVuY3Rpb24gZm10KHMpe2NvbnN0
IG09TWF0aC5mbG9vcihzLzYwKSxoPU1hdGguZmxvb3IobS82MCk7cmV0dXJuIGg/aCsnaCAnKyht
JTYwKSsnbSc6KG0/bSsnbSAnKyhzJTYwKSsncyc6cysncycpO30KZnVuY3Rpb24gcmVuZGVybG9n
KCl7Y29uc3QgZj0oJCgnbG9nZmlsdGVyJykudmFsdWV8fCcnKS50b0xvd2VyQ2FzZSgpO2xldCBM
PShTLmxvZ3x8W10pO2lmKGYpTD1MLmZpbHRlcih4PT54LnRvTG93ZXJDYXNlKCkuaW5jbHVkZXMo
ZikpO2NvbnN0IGxnPSQoJ2xvZycpO2NvbnN0IG5lYXI9bGcuc2Nyb2xsVG9wK2xnLmNsaWVudEhl
aWdodD49bGcuc2Nyb2xsSGVpZ2h0LTQwO2xnLnRleHRDb250ZW50PUwuam9pbignXG4nKTskKCds
b2djb3VudCcpLnRleHRDb250ZW50PUwubGVuZ3RoKycgWmVpbGVuJztpZihuZWFyKWxnLnNjcm9s
bFRvcD1sZy5zY3JvbGxIZWlnaHQ7fQpmdW5jdGlvbiByZW5kZXIocyl7Uz1zO2xpbWVPcHRpb25z
KHMpO2lmKCFmaWxsZWQpcmVsb2FkRmllbGRzKCk7CiBjb25zdCBydW49cy5zdGF0ZT09PSdsYWV1
ZnQnLHQ9cy50ZWNoOwogJCgnZG90JykuY2xhc3NOYW1lPSdkb3QgJysocnVuPydvbic6KHMuc3Rh
dGU9PT0nZmVobGVyJz8nZXJyJzonJykpOwogJCgnc3RhdGUnKS50ZXh0Q29udGVudD1zLnN0YXRl
OyQoJ21zZycpLnRleHRDb250ZW50PXMubXNnfHwnJzsKIGNvbnN0IHRiPSQoJ3RlY2hiYWRnZScp
O2lmKHQpe3RiLnN0eWxlLmRpc3BsYXk9Jyc7dGIudGV4dENvbnRlbnQ9dD09PSdjc2ZiJz8nTFRF
K0dTTSc6dC50b1VwcGVyQ2FzZSgpO31lbHNlIHRiLnN0eWxlLmRpc3BsYXk9J25vbmUnOwogbGV0
IGZyZXE9J+KAkycsZnN1Yj0nJzsKIGNvbnN0IGdmPXMuZ3NtLm1oeisnIE1IeicsbGY9cy5sdGUu
bWh6KycgTUh6JzsKIGlmKHQ9PT0nbHRlJyl7ZnJlcT1sZjtmc3ViPSdCYW5kICcrcy5sdGUuYmFu
ZCsnIMK3IEVBUkZDTiAnK3MubHRlLmVhcmZjbjt9CiBlbHNlIGlmKHQ9PT0nZ3NtJyl7ZnJlcT1n
Zjtmc3ViPXMuZ3NtLmJhbmQrJyDCtyBBUkZDTiAnK3MuZ3NtLmFyZmNuO30KIGVsc2UgaWYodD09
PSdjc2ZiJyl7ZnJlcT1sZisnIC8gJytnZjtmc3ViPSdMVEUgQicrcy5sdGUuYmFuZCsnIMK3IEdT
TSBBUkZDTiAnK3MuZ3NtLmFyZmNuO30KICQoJ2ZyZXEnKS50ZXh0Q29udGVudD1mcmVxOyQoJ2Zy
ZXEyJykudGV4dENvbnRlbnQ9ZnJlcTskKCdmcmVxc3ViJykudGV4dENvbnRlbnQ9ZnN1YjsKICQo
J3RlY2gyJykudGV4dENvbnRlbnQ9dD8odD09PSdjc2ZiJz8nTFRFK0dTTSc6dC50b1VwcGVyQ2Fz
ZSgpKTonYXVzJzskKCdzdGF0ZXN1YicpLnRleHRDb250ZW50PXMuc3RhdGU7CiAkKCd1cHRpbWUn
KS50ZXh0Q29udGVudD1zLnVwdGltZT9mbXQocy51cHRpbWUpOifigJMnOyQoJ3VwdGltZWhpbnQn
KS50ZXh0Q29udGVudD1ydW4/KCdsw6R1ZnQgc2VpdCAnK2ZtdChzLnVwdGltZSkpOicnOwogJCgn
ZGV2aGludCcpLmlubmVySFRNTD1bcy5kZXYuZ3NtPydHU00tRnVuazogPGI+Jytlc2Mocy5kZXYu
Z3NtKSsnPC9iPic6Jycscy5kZXYubHRlPydMVEUtRnVuazogPGI+Jytlc2Mocy5kZXYubHRlKSsn
PC9iPic6JyddLmZpbHRlcihCb29sZWFuKS5qb2luKCc8YnI+Jyk7CiAkKCdjbGFzaCcpLnRleHRD
b250ZW50PXMuY2xhc2h8fCcnOwogW1snZ3NtJywnT3Ntb2NvbSddLFsnbHRlJywnc3JzUkFOICsg
T3BlbjVHUyddLFsnY3NmYicsJ0ludGVybmV0ICsgQW5ydWZlIChDU0ZCKSddXS5mb3JFYWNoKChb
ayxkXSk9PnskKCdidG5fJytrKS5jbGFzc0xpc3QudG9nZ2xlKCdhY3RpdmUnLHQ9PT1rKTskKGsr
J19zdWInKS50ZXh0Q29udGVudD10PT09az8nbMOkdWZ0JzpkO30pOwogJCgndHonKS50ZXh0Q29u
dGVudD1zLnR6fHwn4oCTJzsKIGNvbnN0IGY9cy5zaW1maWxlc3x8e307JCgnaHBsbW4nKS50ZXh0
Q29udGVudD1mLmhwbG1ufHwn4oCTJzsKICQoJ2VmX3NwbicpLnRleHRDb250ZW50PWYuc3BufHwn
JzskKCdlZl9zcG5fdCcpLnRleHRDb250ZW50PSfigJ4nKyhmLnNwbl90ZXh0fHwnJykrJ+KAnCc7
CiAkKCdlZl9wbm4nKS50ZXh0Q29udGVudD1mLnBubnx8Jyc7JCgnZWZfcG5uX3QnKS50ZXh0Q29u
dGVudD0nbGFuZyDigJ4nKyhmLmZ1bGx8fCcnKSsn4oCcLCBrdXJ6IOKAnicrKGYuc2hvcnR8fCcn
KSsn4oCcJzsKICQoJ2VmX29wbCcpLnRleHRDb250ZW50PWYub3BsfHwnJzskKCdlZl9vcGxfdCcp
LnRleHRDb250ZW50PSdLZW5udW5nICcrKGYuaHBsbW58fCcnKSsnLCBhbGxlIEdlYmlldGUg4oaS
IFBOTiAxJzsKICQoJ2VmX2hwbG1uJykudGV4dENvbnRlbnQ9Zi5ocGxtbnx8Jyc7CiAkKCdnc21f
bnVtYmVycycpLmlubmVySFRNTD1PYmplY3QuZW50cmllcyhzLmdzbS5udW1iZXJzfHx7fSkubWFw
KGU9Pic8ZGl2IGNsYXNzPWxpc3Ryb3c+PHNwYW4gY2xhc3M9dGFnPicrZXNjKGVbMF0pKycg4oaS
IDxiPicrZXNjKGVbMV0pKyc8L2I+PC9zcGFuPjxidXR0b24gY2xhc3M9eCBvbmNsaWNrPSJudW1k
ZWwoXCcnK2VzYyhlWzBdKSsnXCcpIj5sw7ZzY2hlbjwvYnV0dG9uPjwvZGl2PicpLmpvaW4oJycp
fHwnPGRpdiBjbGFzcz1lbXB0eT5rZWluZSBadXdlaXN1bmdlbjwvZGl2Pic7CiAkKCdhdHRhY2hl
ZCcpLmlubmVySFRNTD0ocy5nc20uYXR0YWNoZWR8fFtdKS5tYXAoaT0+JzxkaXYgY2xhc3M9bGlz
dHJvdz48c3BhbiBjbGFzcz10YWc+Jytlc2MoaSkrJzwvc3Bhbj48c3BhbiBjbGFzcz10YWc+Jytl
c2MoKHMuZ3NtLm51bWJlcnN8fHt9KVtpXXx8JycpKyc8L3NwYW4+PC9kaXY+Jykuam9pbignJyl8
fCc8ZGl2IGNsYXNzPWVtcHR5PmtlaW5lIGVpbmdlYnVjaHQ8L2Rpdj4nOwogJCgnc2ltcycpLmlu
bmVySFRNTD0ocy5zaW1zfHxbXSkubWFwKHg9Pic8ZGl2IGNsYXNzPWxpc3Ryb3c+PHNwYW4gY2xh
c3M9dGFnPicrZXNjKHguaW1zaSkrJyDCtyA8Yj4nK2VzYyh4Lm1zaXNkbikrJzwvYj48L3NwYW4+
PGJ1dHRvbiBjbGFzcz14IG9uY2xpY2s9InNpbWRlbChcJycrZXNjKHguaW1zaSkrJ1wnKSI+bMO2
c2NoZW48L2J1dHRvbj48L2Rpdj4nKS5qb2luKCcnKXx8JzxkaXYgY2xhc3M9ZW1wdHk+bm9jaCBr
ZWluZSBTSU0gZWluZ2V0cmFnZW48L2Rpdj4nOwogcmVuZGVybG9nKCk7Cn0KbGV0IEdFTj1bXTsK
ZnVuY3Rpb24gc2ltZ2VuKCl7YXBpKCdzaW1fZ2VuJyx7Y291bnQ6JCgnZ2VuX24nKS52YWx1ZSxt
c2lzZG46JCgnZ2VuX25yJykudmFsdWUsaWNjaWQ6JCgnZ2VuX2ljY2lkJykudmFsdWV9KS50aGVu
KHI9PntHRU49ci5nZW5lcmF0ZWR8fFtdO2dlbmRyYXcoKTtyZW5kZXIocik7fSk7fQpjb25zdCBH
Q09MUz1bWydpY2NpZCcsJ0lDQ0lEJ10sWydpbXNpJywnSU1TSSddLFsna2knLCdLaSddLFsnb3An
LCdPUCddLFsnb3BjJywnT1BjJ10sWydtc2lzZG4nLCdSdWZuci4nXSxbJ3BpbjEnLCdQSU4xJ10s
WydwdWsxJywnUFVLMSddLFsncGluMicsJ1BJTjInXSxbJ3B1azInLCdQVUsyJ10sWydhZG0xJywn
QURNMSddXTsKZnVuY3Rpb24gZ2VuZHJhdygpe2NvbnN0IFQ9JCgnZ2VuX3RhYicpOwogVC5pbm5l
ckhUTUw9R0VOLmxlbmd0aD8nPHRyPicrR0NPTFMubWFwKGM9Pic8dGg+JytjWzFdKyc8L3RoPicp
LmpvaW4oJycpKyc8dGg+PC90aD48L3RyPicrR0VOLm1hcCgoZyxpKT0+Jzx0cj4nK0dDT0xTLm1h
cChjPT4nPHRkPjxjb2RlPicrZXNjKGdbY1swXV0pKyc8L2NvZGU+PC90ZD4nKS5qb2luKCcnKSsn
PHRkPjxidXR0b24gY2xhc3M9ImJ0biBzbSBzZWMiIG9uY2xpY2s9ImdlbnRha2UoJytpKycpIj7D
vGJlcm5laG1lbjwvYnV0dG9uPjwvdGQ+PC90cj4nKS5qb2luKCcnKTonJzsKIFsnZ2VuX3Rha2Un
LCdnZW5fY3N2JywnZ2VuX2pzb24nXS5mb3JFYWNoKGlkPT4kKGlkKS5kaXNhYmxlZD0hR0VOLmxl
bmd0aCk7fQphc3luYyBmdW5jdGlvbiBnZW50YWtlKGkpe2NvbnN0IEw9aT09PXVuZGVmaW5lZD9H
RU46W0dFTltpXV07bGV0IG9rPTAsbGFzdD1udWxsOwogZm9yKGNvbnN0IGcgb2YgTCl7bGFzdD1h
d2FpdCBhcGkoJ3NpbV9hZGQnLHtpbXNpOmcuaW1zaSxraTpnLmtpLG9wYzpnLm9wYyxtc2lzZG46
Zy5tc2lzZG59KTtpZighL2FiZXJ8cHJ1ZWZlbi8udGVzdChsYXN0Lm1zZ3x8JycpKW9rKys7fQog
aWYobGFzdCl7cmVuZGVyKGxhc3QpOyQoJ21zZycpLnRleHRDb250ZW50PW9rKycgdm9uICcrTC5s
ZW5ndGgrJyBTSU0ocykgaW4gcEtPTSDDvGJlcm5vbW1lbicrKG9rPEwubGVuZ3RoPycg4oCTICcr
bGFzdC5tc2c6JycpO319CmZ1bmN0aW9uIGdlbmRsKGZtdCl7aWYoIUdFTi5sZW5ndGgpcmV0dXJu
O2xldCBkYXRhLHR5cGUsbmFtZT0ncGtvbS1zaW1zLScrbmV3IERhdGUoKS50b0lTT1N0cmluZygp
LnNsaWNlKDAsMTApOwogaWYoZm10PT09J2pzb24nKXtkYXRhPUpTT04uc3RyaW5naWZ5KEdFTixu
dWxsLDEpO3R5cGU9J2FwcGxpY2F0aW9uL2pzb24nO25hbWUrPScuanNvbic7fQogZWxzZXtjb25z
dCBrPU9iamVjdC5rZXlzKEdFTlswXSk7ZGF0YT1bay5qb2luKCc7JyldLmNvbmNhdChHRU4ubWFw
KGc9PmsubWFwKHg9PmdbeF0pLmpvaW4oJzsnKSkpLmpvaW4oU3RyaW5nLmZyb21DaGFyQ29kZSgx
MywxMCkpO3R5cGU9J3RleHQvY3N2JztuYW1lKz0nLmNzdic7fQogY29uc3QgYT1kb2N1bWVudC5j
cmVhdGVFbGVtZW50KCdhJyk7YS5ocmVmPVVSTC5jcmVhdGVPYmplY3RVUkwobmV3IEJsb2IoW2Rh
dGFdLHt0eXBlfSkpO2EuZG93bmxvYWQ9bmFtZTthLmNsaWNrKCk7c2V0VGltZW91dCgoKT0+VVJM
LnJldm9rZU9iamVjdFVSTChhLmhyZWYpLDIwMDApO30KYXN5bmMgZnVuY3Rpb24gcG9sbCgpe3Ry
eXtyZW5kZXIoYXdhaXQgYXBpKCdzdGF0dXMnKSk7fWNhdGNoKGUpe319CnRyeXtjb25zdCB0PWxv
Y2FsU3RvcmFnZS5nZXRJdGVtKCdwa29tX3RhYicpO2lmKHQmJiQoJ3AtJyt0KSl0YWIodCk7fWNh
dGNoKGUpe30KcG9sbCgpO3NldEludGVydmFsKHBvbGwsMjUwMCk7Cjwvc2NyaXB0PjwvYm9keT48
L2h0bWw+IiIiCgpjbGFzcyBIYW5kbGVyKEJhc2VIVFRQUmVxdWVzdEhhbmRsZXIpOgogICAgZGVm
IGxvZ19tZXNzYWdlKHNlbGYsICphKTogcGFzcwogICAgZGVmIF9zZW5kKHNlbGYsIGNvZGUsIGJv
ZHksIGN0eXBlPSJhcHBsaWNhdGlvbi9qc29uIik6CiAgICAgICAgYiA9IGJvZHkuZW5jb2RlKCkg
aWYgaXNpbnN0YW5jZShib2R5LCBzdHIpIGVsc2UgYm9keQogICAgICAgIHNlbGYuc2VuZF9yZXNw
b25zZShjb2RlKQogICAgICAgIHNlbGYuc2VuZF9oZWFkZXIoIkNvbnRlbnQtVHlwZSIsIGN0eXBl
KQogICAgICAgIHNlbGYuc2VuZF9oZWFkZXIoIkNvbnRlbnQtTGVuZ3RoIiwgc3RyKGxlbihiKSkp
CiAgICAgICAgc2VsZi5lbmRfaGVhZGVycygpCiAgICAgICAgdHJ5OiBzZWxmLndmaWxlLndyaXRl
KGIpCiAgICAgICAgZXhjZXB0IEV4Y2VwdGlvbjogcGFzcwogICAgZGVmIGRvX0dFVChzZWxmKToK
ICAgICAgICBpZiBzZWxmLnBhdGggaW4gKCIvIiwgIi9pbmRleC5odG1sIik6CiAgICAgICAgICAg
IHNlbGYuX3NlbmQoMjAwLCBQQUdFLCAidGV4dC9odG1sOyBjaGFyc2V0PXV0Zi04IikKICAgICAg
ICBlbGlmIHNlbGYucGF0aCA9PSAiL2FwaS9zdGF0dXMiOgogICAgICAgICAgICBzZWxmLl9zZW5k
KDIwMCwganNvbi5kdW1wcyhORVQuc3RhdHVzKCkpKQogICAgICAgIGVsc2U6CiAgICAgICAgICAg
IHNlbGYuX3NlbmQoNDA0LCAie30iKQogICAgZGVmIGRvX1BPU1Qoc2VsZik6CiAgICAgICAgbiA9
IGludChzZWxmLmhlYWRlcnMuZ2V0KCJDb250ZW50LUxlbmd0aCIsIDApIG9yIDApCiAgICAgICAg
Ym9keSA9IHNlbGYucmZpbGUucmVhZChuKS5kZWNvZGUoZXJyb3JzPSJyZXBsYWNlIikgaWYgbiBl
bHNlICIiCiAgICAgICAgaWYgc2VsZi5wYXRoLnN0YXJ0c3dpdGgoIi9hcGkvIik6CiAgICAgICAg
ICAgIHRyeToKICAgICAgICAgICAgICAgIHNlbGYuX3NlbmQoMjAwLCBqc29uLmR1bXBzKGhhbmRs
ZV9hcGkoc2VsZi5wYXRoLCBib2R5KSkpCiAgICAgICAgICAgIGV4Y2VwdCBFeGNlcHRpb24gYXMg
ZToKICAgICAgICAgICAgICAgIGxvZygiYXBpOiIsIGUpOyBzZWxmLl9zZW5kKDUwMCwganNvbi5k
dW1wcyh7ImVycm9yIjogc3RyKGUpfSkpCiAgICAgICAgZWxzZToKICAgICAgICAgICAgc2VsZi5f
c2VuZCg0MDQsICJ7fSIpCgpkZWYgbWFpbigpOgogICAgcG9ydCA9IGludChDLmdldCgiV0VCX1BP
UlQiLCAiODA4MCIpKQogICAgbG9nKGYiZzkwbmV0IFdlYi1PYmVyZmxhZWNoZSBhdWYgaHR0cDov
LzAuMC4wLjA6e3BvcnR9ICAoRkFLRT17RkFLRX0pIikKICAgIHRocmVhZGluZy5UaHJlYWQodGFy
Z2V0PXNtc193ZWxjb21lX3dhdGNoLCBkYWVtb249VHJ1ZSkuc3RhcnQoKQogICAgdGhyZWFkaW5n
LlRocmVhZCh0YXJnZXQ9bGltZV9zY2FuLCBkYWVtb249VHJ1ZSkuc3RhcnQoKSAgICMgTGltZVNE
UiBmdWVyIGRpZSBBdXN3YWhsIHN1Y2hlbgogICAgdHJ5OiBfbWlncmF0ZV9sdGVfZGIoKQogICAg
ZXhjZXB0IEV4Y2VwdGlvbiBhcyBlOiBsb2coIm1pZ3JhdGlvbjoiLCBlKQogICAgVGhyZWFkaW5n
SFRUUFNlcnZlcigoIjAuMC4wLjAiLCBwb3J0KSwgSGFuZGxlcikuc2VydmVfZm9yZXZlcigpCgpp
ZiBfX25hbWVfXyA9PSAiX19tYWluX18iOgogICAgbWFpbigpCg==
