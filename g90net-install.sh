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
dl9nc20gPSBzZWxmLmRldl9sdGUgPSAiIgogICAgICAgIHNlbGYuY21kcyA9IHt9ICAgICAgICAg
ICAgIyB0YWcgLT4gKGJpbmFyeSwgYXJncywgZ3J1cHBlKSBmdWVyIEVpbnplbC1OZXVzdGFydHMK
ICAgICAgICBzZWxmLmJ1c3kgPSAiIiAgICAgICAgICAgICMgbGF1ZmVuZGVyIFRlaWwtTmV1c3Rh
cnQKCiAgICBkZWYgX2xvZyhzZWxmLCB0YWcsIGxpbmUpOgogICAgICAgIGxpbmUgPSBsaW5lLnJz
dHJpcCgpCiAgICAgICAgaWYgbm90IGxpbmU6IHJldHVybgogICAgICAgIHByaW50KGYie3RhZ306
IHtsaW5lfSIsIGZsdXNoPVRydWUpICAgIyAtPiBqb3VybmFsZCwgZGFtaXQgJ2pvdXJuYWxjdGwg
LXUgZzkwbmV0JyBhbGxlcyB6ZWlndAogICAgICAgIHNlbGYubG9nbGluZXMuYXBwZW5kKGYie3Rh
Z306IHtsaW5lfSIpCiAgICAgICAgaWYgbGVuKHNlbGYubG9nbGluZXMpID4gNjAwOiBzZWxmLmxv
Z2xpbmVzID0gc2VsZi5sb2dsaW5lc1stNjAwOl0KICAgICAgICBsb3cgPSBsaW5lLmxvd2VyKCkK
ICAgICAgICBpZiAoImZhdGFsIiBpbiBsb3cgb3IgImZhaWxlZCB0byBjcmVhdGUgcmFkaW8iIGlu
IGxvdykgYW5kIHRhZyBub3QgaW4gR1NNX05PTkZBVEFMOgogICAgICAgICAgICBzZWxmLm1zZyA9
IGYie3RhZ306IHtsaW5lWzoxMjBdfSIKCiAgICBkZWYgX3JlYWRlcihzZWxmLCBwLCB0YWcpOgog
ICAgICAgIHRyeToKICAgICAgICAgICAgZm9yIHJhdyBpbiBpdGVyKHAuc3Rkb3V0LnJlYWRsaW5l
LCAiIik6CiAgICAgICAgICAgICAgICBzZWxmLl9sb2codGFnLCByYXcpCiAgICAgICAgZXhjZXB0
IEV4Y2VwdGlvbjoKICAgICAgICAgICAgcGFzcwogICAgICAgIHJjID0gcC5wb2xsKCkKICAgICAg
ICBpZiBzZWxmLnByb2NzLmdldCh0YWcpIGlzIHAgYW5kIHNlbGYuc3RhdGUgPT0gImxhZXVmdCIg
YW5kIHRhZyBub3QgaW4gR1NNX05PTkZBVEFMOgogICAgICAgICAgICBzZWxmLm1zZyA9IGYie3Rh
Z30gYmVlbmRldCAoQ29kZSB7cmN9KSAtIHNpZWhlIFByb3Rva29sbCIKCiAgICBkZWYgX3NwYXdu
KHNlbGYsIGJpbmFyeSwgYXJncywgdGFnLCBncm91cD0iIik6CiAgICAgICAgcCA9IHN1YnByb2Nl
c3MuUG9wZW4oW2JpbmFyeV0gKyBhcmdzLCBzdGRvdXQ9c3VicHJvY2Vzcy5QSVBFLAogICAgICAg
ICAgICAgICAgICAgICAgICAgICAgIHN0ZGVycj1zdWJwcm9jZXNzLlNURE9VVCwgdGV4dD1UcnVl
LCBidWZzaXplPTEpCiAgICAgICAgc2VsZi5wcm9jc1t0YWddID0gcAogICAgICAgIHNlbGYuY21k
c1t0YWddID0gKGJpbmFyeSwgYXJncywgZ3JvdXAgb3Igc2VsZi5jbWRzLmdldCh0YWcsICgiIiwg
W10sICIiKSlbMl0pCiAgICAgICAgdGhyZWFkaW5nLlRocmVhZCh0YXJnZXQ9c2VsZi5fcmVhZGVy
LCBhcmdzPShwLCB0YWcpLCBkYWVtb249VHJ1ZSkuc3RhcnQoKQogICAgICAgIHJldHVybiBwCgog
ICAgZGVmIHN0b3Aoc2VsZik6CiAgICAgICAgd2l0aCBzZWxmLmxvY2s6CiAgICAgICAgICAgIGlm
IEZBS0U6CiAgICAgICAgICAgICAgICBzZWxmLnRlY2ggPSBOb25lOyBzZWxmLnN0YXRlID0gImF1
cyI7IHNlbGYucHJvY3MgPSB7fTsgcmV0dXJuCiAgICAgICAgICAgIHByb2NzLCBzZWxmLnByb2Nz
ID0gc2VsZi5wcm9jcywge30KICAgICAgICAgICAgc2VsZi5jbWRzID0ge30KICAgICAgICAgICAg
Zm9yIHRhZywgcCBpbiBsaXN0KHByb2NzLml0ZW1zKCkpOgogICAgICAgICAgICAgICAgdHJ5OiBw
LnRlcm1pbmF0ZSgpCiAgICAgICAgICAgICAgICBleGNlcHQgRXhjZXB0aW9uOiBwYXNzCiAgICAg
ICAgICAgIHRpbWUuc2xlZXAoMSkKICAgICAgICAgICAgZm9yIG5hbWUgaW4gT1NNT19TRVJWSUNF
UyArIFsic3JzZW5iIiwgInNyc2VwYyIsICJvcGVuNWdzLSJdOgogICAgICAgICAgICAgICAgdHJ5
OiBzdWJwcm9jZXNzLnJ1bihbInBraWxsIiwgIi05IiwgIi1mIiwgbmFtZV0sCiAgICAgICAgICAg
ICAgICAgICAgICAgICAgICAgICAgICAgIHN0ZG91dD1zdWJwcm9jZXNzLkRFVk5VTEwsIHN0ZGVy
cj1zdWJwcm9jZXNzLkRFVk5VTEwpCiAgICAgICAgICAgICAgICBleGNlcHQgRXhjZXB0aW9uOiBw
YXNzCiAgICAgICAgICAgIGlmIHNlbGYudGVjaDoKICAgICAgICAgICAgICAgIF9saW1lX3NlcnZp
Y2UoInN0YXJ0IikgICAjIEc5MC1FbXBmYW5nIHdpZWRlciBmcmVpIGdlYmVuCiAgICAgICAgICAg
IHNlbGYudGVjaCA9IE5vbmU7IHNlbGYuc3RhdGUgPSAiYXVzIjsgc2VsZi5tc2cgPSAiZ2VzdG9w
cHQiCgogICAgZGVmIHN0YXJ0KHNlbGYsIG1vZGUpOgogICAgICAgIGlmIG1vZGUgbm90IGluIE1P
REVTOiByZXR1cm4gInVuYmVrYW5udGVyIE1vZHVzIgogICAgICAgIHdpdGggc2VsZi5sb2NrOgog
ICAgICAgICAgICBzZWxmLnN0b3AoKTsgc2VsZi50ZWNoID0gbW9kZTsgc2VsZi5zdGF0ZSA9ICJz
dGFydGV0Ijsgc2VsZi5tc2cgPSAiIgogICAgICAgICAgICBzZWxmLmxvZ2xpbmVzID0gW107IHNl
bGYuc3RhcnRlZCA9IHRpbWUudGltZSgpOyBzZWxmLndlbGNvbWVkID0gc2V0KCkKICAgICAgICBl
cnIgPSBwcmVmbGlnaHQobW9kZSkKICAgICAgICBpZiBlcnI6CiAgICAgICAgICAgIHdpdGggc2Vs
Zi5sb2NrOiBzZWxmLnRlY2ggPSBOb25lOyBzZWxmLnN0YXRlID0gImZlaGxlciI7IHNlbGYubXNn
ID0gZXJyCiAgICAgICAgICAgIHJldHVybiBlcnIKICAgICAgICBpZiBGQUtFOgogICAgICAgICAg
ICB3aXRoIHNlbGYubG9jazoKICAgICAgICAgICAgICAgIHNlbGYuc3RhdGUgPSAibGFldWZ0Ijsg
c2VsZi5tc2cgPSBNT0RFU1ttb2RlXSArICIgbGFldWZ0IChGQUtFKSIKICAgICAgICAgICAgICAg
IGlmIG1vZGUgaW4gKCJnc20iLCAiY3NmYiIpOgogICAgICAgICAgICAgICAgICAgIGZvciBuLCBi
LCBfYyBpbiBnc21fY29tcG9uZW50cygpOiBzZWxmLmNtZHNbbl0gPSAoYiwgW10sICJnc20iKQog
ICAgICAgICAgICAgICAgaWYgbW9kZSBpbiAoImx0ZSIsICJjc2ZiIik6CiAgICAgICAgICAgICAg
ICAgICAgZm9yIG4sIGIgaW4gTzVfTkZTOiBzZWxmLmNtZHNbbl0gPSAoYiwgW10sICJsdGUiKQog
ICAgICAgICAgICAgICAgICAgIHNlbGYuY21kc1siZW5iIl0gPSAoInNyc2VuYiIsIFtdLCAibHRl
IikKICAgICAgICAgICAgcmV0dXJuIE5vbmUKICAgICAgICBnc20sIGx0ZSA9IG1vZGUgaW4gKCJn
c20iLCAiY3NmYiIpLCBtb2RlIGluICgibHRlIiwgImNzZmIiKQogICAgICAgIHRyeToKICAgICAg
ICAgICAgaWYgZ3NtOgogICAgICAgICAgICAgICAgc2VsZi5fc2VydmljZXNfb2ZmKE9TTU9fU0VS
VklDRVMpCiAgICAgICAgICAgICAgICBnc21fcHJlcGFyZSgpCiAgICAgICAgICAgIGlmIGx0ZToK
ICAgICAgICAgICAgICAgIHNlbGYuX3NlcnZpY2VzX29mZihbYiBmb3IgX25mLCBiIGluIE81X05G
U10pCiAgICAgICAgICAgICAgICBuZnMgPSBvNV9wcmVwYXJlKG1vZGUgPT0gImNzZmIiKQogICAg
ICAgICAgICAgICAgZW5iX3ByZXBhcmUobW9kZSA9PSAiY3NmYiIsIHNlbGYuZGV2X2x0ZSkKICAg
ICAgICAgICAgICAgIF9ydW4oInN5c3RlbWN0bCIsICJzdGFydCIsICJtb25nb2QiKQogICAgICAg
ICAgICAgICAgZSA9IGhzc19zeW5jX2FsbCgpCiAgICAgICAgICAgICAgICBpZiBlOiBzZWxmLl9s
b2coInBrb20iLCAiSFNTOiAiICsgZSkKICAgICAgICAgICAgaWYgc2VsZi5kZXZfZ3NtOiBzZWxm
Ll9sb2coInBrb20iLCAiR1NNLUZ1bms6ICIgKyBsaW1lX2xhYmVsKHNlbGYuZGV2X2dzbSkpCiAg
ICAgICAgICAgIGlmIHNlbGYuZGV2X2x0ZTogc2VsZi5fbG9nKCJwa29tIiwgIkxURS1GdW5rOiAi
ICsgbGltZV9sYWJlbChzZWxmLmRldl9sdGUpKQogICAgICAgICAgICBfbGltZV9zZXJ2aWNlKCJz
dG9wIik7IHRpbWUuc2xlZXAoMSk7IF9mcmVlX2xpbWUoKTsgdGltZS5zbGVlcCgyKQogICAgICAg
ICAgICBpZiBnc206IHNlbGYuX3J1bl9nc20oKQogICAgICAgICAgICBpZiBsdGU6IHNlbGYuX3J1
bl9sdGUobmZzKQogICAgICAgICAgICB3aXRoIHNlbGYubG9jazogc2VsZi5zdGF0ZSA9ICJsYWV1
ZnQiOyBzZWxmLm1zZyA9IE1PREVTW21vZGVdICsgIiBnZXN0YXJ0ZXQiCiAgICAgICAgZXhjZXB0
IEV4Y2VwdGlvbiBhcyBlOgogICAgICAgICAgICB3aXRoIHNlbGYubG9jazogc2VsZi5zdGF0ZSA9
ICJmZWhsZXIiOyBzZWxmLm1zZyA9IHN0cihlKVs6MjAwXQogICAgICAgICAgICByZXR1cm4gc3Ry
KGUpCiAgICAgICAgcmV0dXJuIE5vbmUKCiAgICAjIC0tLS0gVGVpbGUgc3RhcnRlbiAvIGVpbnpl
bG4gbmV1IHN0YXJ0ZW4gLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLQogICAgZGVmIF9ydW5f
Z3NtKHNlbGYpOgogICAgICAgIGZvciBuYW1lLCBiaW5hcnksIGNmZyBpbiBnc21fY29tcG9uZW50
cygpOgogICAgICAgICAgICBmbGFnID0gIi1DIiBpZiBiaW5hcnkuc3RhcnRzd2l0aCgib3Ntby10
cngiKSBlbHNlICItYyIKICAgICAgICAgICAgc2VsZi5fc3Bhd24oYmluYXJ5LCBbZmxhZywgb3Mu
cGF0aC5qb2luKFdPUktESVIsIGNmZyldLCBuYW1lLCAiZ3NtIikKICAgICAgICAgICAgdGltZS5z
bGVlcCg0IGlmIG5hbWUgaW4gKCJ0cngiLCkgZWxzZSAxLjIpCiAgICAgICAgdGltZS5zbGVlcCgx
KTsgZ3NtX2FwcGx5X251bWJlcnMoKSAgICMgU0lNcyArIGRhdWVyaGFmdGUgUnVmbnVtbWVybiBp
bnMgSExSCgogICAgZGVmIF9ydW5fbHRlKHNlbGYsIG5mcywgY29yZT1UcnVlKToKICAgICAgICBp
ZiBjb3JlOgogICAgICAgICAgICB1ZV9uZXRfdXAoKQogICAgICAgICAgICBmb3IgbmYsIChiaW5h
cnksIHBhdGgpIGluIG5mcy5pdGVtcygpOgogICAgICAgICAgICAgICAgc2VsZi5fc3Bhd24oYmlu
YXJ5LCBbIi1jIiwgcGF0aF0sIG5mLCAibHRlIikKICAgICAgICAgICAgICAgIHRpbWUuc2xlZXAo
MS41IGlmIG5mID09ICJtbWUiIGVsc2UgMC44KQogICAgICAgICAgICB0aW1lLnNsZWVwKDIpCiAg
ICAgICAgc2VsZi5fc3Bhd24oInNyc2VuYiIsIFtvcy5wYXRoLmpvaW4oV09SS0RJUiwgImVuYi5j
b25mIildLCAiZW5iIiwgImx0ZSIpCgogICAgZGVmIF9raWxsKHNlbGYsIHRhZ3MpOgogICAgICAg
ICIiIlByb3plc3NlIGJlZW5kZW4sIG9obmUgZGFzcyBkZXIgTGVzZXIgJ2JlZW5kZXQnIG1lbGRl
dC4iIiIKICAgICAgICBwcyA9IFsodCwgc2VsZi5wcm9jcy5wb3AodCkpIGZvciB0IGluIGxpc3Qo
dGFncykgaWYgdCBpbiBzZWxmLnByb2NzXQogICAgICAgIGZvciBfdCwgcCBpbiBwczoKICAgICAg
ICAgICAgdHJ5OiBwLnRlcm1pbmF0ZSgpCiAgICAgICAgICAgIGV4Y2VwdCBFeGNlcHRpb246IHBh
c3MKICAgICAgICBmb3IgX3QsIHAgaW4gcHM6CiAgICAgICAgICAgIHRyeTogcC53YWl0KHRpbWVv
dXQ9NikKICAgICAgICAgICAgZXhjZXB0IEV4Y2VwdGlvbjoKICAgICAgICAgICAgICAgIHRyeTog
cC5raWxsKCk7IHAud2FpdCh0aW1lb3V0PTMpCiAgICAgICAgICAgICAgICBleGNlcHQgRXhjZXB0
aW9uOiBwYXNzCgogICAgZGVmIHBhcnRzKHNlbGYpOgogICAgICAgICIiIldhcyBlaW56ZWxuIG5l
dSBnZXN0YXJ0ZXQgd2VyZGVuIGthbm4gKGplIG5hY2ggTW9kdXMpLiIiIgogICAgICAgIHQgPSBz
ZWxmLnRlY2ggb3IgIiIKICAgICAgICBvdXQgPSBbXQogICAgICAgIGlmIHQgaW4gKCJnc20iLCAi
Y3NmYiIpOiBvdXQuYXBwZW5kKCgiZ3NtIiwgIkdTTSBrb21wbGV0dCIpKQogICAgICAgIGlmIHQg
aW4gKCJsdGUiLCAiY3NmYiIpOiBvdXQgKz0gWygibHRlIiwgIjRHIGtvbXBsZXR0IiksICgiZW5i
IiwgIjRHLUZ1bmsgKGVOQikiKV0KICAgICAgICByZXR1cm4gb3V0CgogICAgZGVmIHJlc3RhcnQo
c2VsZiwgcGFydCk6CiAgICAgICAgIiIicGFydDogJ2dzbScgfCAnbHRlJyB8ICdjb3JlJyB8ICdl
bmInIHwgUHJvemVzc25hbWUgKHouQi4gJ21zYycsICdtbWUnKS4iIiIKICAgICAgICB3aXRoIHNl
bGYubG9jazoKICAgICAgICAgICAgaWYgc2VsZi5zdGF0ZSBub3QgaW4gKCJsYWV1ZnQiLCAiZmVo
bGVyIikgb3Igbm90IHNlbGYudGVjaDoKICAgICAgICAgICAgICAgIHJldHVybiAiTmV0eiBsYWV1
ZnQgbmljaHQiCiAgICAgICAgICAgIGlmIHNlbGYuYnVzeTogcmV0dXJuIGYiTmV1c3RhcnQgdm9u
IHtzZWxmLmJ1c3l9IGxhZXVmdCBub2NoIgogICAgICAgICAgICBnc20sIGx0ZSA9IHNlbGYudGVj
aCBpbiAoImdzbSIsICJjc2ZiIiksIHNlbGYudGVjaCBpbiAoImx0ZSIsICJjc2ZiIikKICAgICAg
ICAgICAgaWYgcGFydCA9PSAiZ3NtIiBhbmQgbm90IGdzbSBvciBwYXJ0IGluICgibHRlIiwgImVu
YiIpIGFuZCBub3QgbHRlOgogICAgICAgICAgICAgICAgcmV0dXJuICJUZWlsIGlzdCBpbSBha3R1
ZWxsZW4gTW9kdXMgbmljaHQgYWt0aXYiCiAgICAgICAgICAgIGlmIHBhcnQgbm90IGluICgiZ3Nt
IiwgImx0ZSIsICJlbmIiKSBhbmQgcGFydCBub3QgaW4gc2VsZi5jbWRzOgogICAgICAgICAgICAg
ICAgcmV0dXJuIGYidW5iZWthbm50ZXIgVGVpbCAne3BhcnR9JyIKICAgICAgICAgICAgc2VsZi5i
dXN5ID0gcGFydAogICAgICAgIGxhYmVsID0gZGljdChzZWxmLnBhcnRzKCkpLmdldChwYXJ0LCBw
YXJ0KQogICAgICAgIHNlbGYuX2xvZygicGtvbSIsIGYiTmV1c3RhcnQ6IHtsYWJlbH0iKQogICAg
ICAgIHNlbGYubXNnID0gZiJ7bGFiZWx9IHN0YXJ0ZXQgbmV1IC4uLiIKICAgICAgICB0cnk6CiAg
ICAgICAgICAgIGlmIEZBS0U6CiAgICAgICAgICAgICAgICB0aW1lLnNsZWVwKDAuNSkKICAgICAg
ICAgICAgZWxpZiBwYXJ0ID09ICJnc20iOgogICAgICAgICAgICAgICAgc2VsZi5fa2lsbChbdCBm
b3IgdCwgYyBpbiBzZWxmLmNtZHMuaXRlbXMoKSBpZiBjWzJdID09ICJnc20iXSkKICAgICAgICAg
ICAgICAgIGdzbV9wcmVwYXJlKCk7IHNlbGYuX3J1bl9nc20oKQogICAgICAgICAgICBlbGlmIHBh
cnQgPT0gImx0ZSI6CiAgICAgICAgICAgICAgICBzZWxmLl9raWxsKFt0IGZvciB0LCBjIGluIHNl
bGYuY21kcy5pdGVtcygpIGlmIGNbMl0gPT0gImx0ZSJdKQogICAgICAgICAgICAgICAgbmZzID0g
bzVfcHJlcGFyZShzZWxmLnRlY2ggPT0gImNzZmIiKQogICAgICAgICAgICAgICAgZW5iX3ByZXBh
cmUoc2VsZi50ZWNoID09ICJjc2ZiIiwgc2VsZi5kZXZfbHRlKQogICAgICAgICAgICAgICAgZSA9
IGhzc19zeW5jX2FsbCgpCiAgICAgICAgICAgICAgICBpZiBlOiBzZWxmLl9sb2coInBrb20iLCAi
SFNTOiAiICsgZSkKICAgICAgICAgICAgICAgIHNlbGYuX3J1bl9sdGUobmZzKQogICAgICAgICAg
ICBlbGlmIHBhcnQgPT0gImVuYiI6CiAgICAgICAgICAgICAgICBzZWxmLl9raWxsKFsiZW5iIl0p
OyBlbmJfcHJlcGFyZShzZWxmLnRlY2ggPT0gImNzZmIiLCBzZWxmLmRldl9sdGUpCiAgICAgICAg
ICAgICAgICBzZWxmLl9ydW5fbHRlKHt9LCBjb3JlPUZhbHNlKQogICAgICAgICAgICBlbHNlOgog
ICAgICAgICAgICAgICAgYmluYXJ5LCBhcmdzLCBncnAgPSBzZWxmLmNtZHNbcGFydF0KICAgICAg
ICAgICAgICAgIHNlbGYuX2tpbGwoW3BhcnRdKTsgdGltZS5zbGVlcCgwLjUpCiAgICAgICAgICAg
ICAgICBzZWxmLl9zcGF3bihiaW5hcnksIGFyZ3MsIHBhcnQsIGdycCkKICAgICAgICAgICAgICAg
IGlmIHBhcnQgPT0gImhsciI6IHRpbWUuc2xlZXAoMS41KTsgZ3NtX2FwcGx5X251bWJlcnMoKQog
ICAgICAgICAgICB3aXRoIHNlbGYubG9jazogc2VsZi5zdGF0ZSA9ICJsYWV1ZnQiOyBzZWxmLm1z
ZyA9IGYie2xhYmVsfSBuZXUgZ2VzdGFydGV0IgogICAgICAgICAgICByZXR1cm4gTm9uZQogICAg
ICAgIGV4Y2VwdCBFeGNlcHRpb24gYXMgZToKICAgICAgICAgICAgd2l0aCBzZWxmLmxvY2s6IHNl
bGYubXNnID0gZiJOZXVzdGFydCB7bGFiZWx9IGZlaGxnZXNjaGxhZ2VuOiB7c3RyKGUpWzoxNjBd
fSIKICAgICAgICAgICAgcmV0dXJuIHN0cihlKQogICAgICAgIGZpbmFsbHk6CiAgICAgICAgICAg
IHNlbGYuYnVzeSA9ICIiCgogICAgZGVmIHByb2NfbGlzdChzZWxmKToKICAgICAgICBvdXQgPSBb
XQogICAgICAgIGZvciB0YWcsIChfYiwgX2EsIGdycCkgaW4gc2VsZi5jbWRzLml0ZW1zKCk6CiAg
ICAgICAgICAgIHAgPSBzZWxmLnByb2NzLmdldCh0YWcpCiAgICAgICAgICAgIHJjID0gTm9uZSBp
ZiBwIGlzIE5vbmUgZWxzZSBwLnBvbGwoKQogICAgICAgICAgICBvdXQuYXBwZW5kKHsidGFnIjog
dGFnLCAiZ3JvdXAiOiBncnAsICJydW4iOiBwIGlzIG5vdCBOb25lIGFuZCByYyBpcyBOb25lLAog
ICAgICAgICAgICAgICAgICAgICAgICAicmMiOiByYyBpZiBwIGlzIG5vdCBOb25lIGVsc2UgIi0i
fSkKICAgICAgICByZXR1cm4gb3V0CgogICAgIyBLb21wYXRpYmlsaXRhZXQKICAgIGRlZiBzdGFy
dF9nc20oc2VsZik6IHJldHVybiBzZWxmLnN0YXJ0KCJnc20iKQogICAgZGVmIHN0YXJ0X2x0ZShz
ZWxmKTogcmV0dXJuIHNlbGYuc3RhcnQoImx0ZSIpCgogICAgZGVmIF9zZXJ2aWNlc19vZmYoc2Vs
ZiwgbmFtZXMpOgogICAgICAgIGZvciBzIGluIG5hbWVzOgogICAgICAgICAgICB0cnk6IHN1YnBy
b2Nlc3MucnVuKFsic3lzdGVtY3RsIiwgInN0b3AiLCBzLnJlcGxhY2UoIm9wZW41Z3MtIiwgIm9w
ZW41Z3MtIikgKyAiLnNlcnZpY2UiXSwKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBz
dGRvdXQ9c3VicHJvY2Vzcy5ERVZOVUxMLCBzdGRlcnI9c3VicHJvY2Vzcy5ERVZOVUxMLCB0aW1l
b3V0PTgpCiAgICAgICAgICAgIGV4Y2VwdCBFeGNlcHRpb246IHBhc3MKCiAgICBkZWYgc3RhdHVz
KHNlbGYpOgogICAgICAgIHdpdGggc2VsZi5sb2NrOgogICAgICAgICAgICBzdCA9IHsKICAgICAg
ICAgICAgICAgICJ0ZWNoIjogc2VsZi50ZWNoLCAibW9kZSI6IE1PREVTLmdldChzZWxmLnRlY2gg
b3IgIiIsICIiKSwKICAgICAgICAgICAgICAgICJzdGF0ZSI6IHNlbGYuc3RhdGUsICJtc2ciOiBz
ZWxmLm1zZywKICAgICAgICAgICAgICAgICJ1cHRpbWUiOiBpbnQodGltZS50aW1lKCkgLSBzZWxm
LnN0YXJ0ZWQpIGlmIHNlbGYuc3RhcnRlZCBhbmQgc2VsZi5zdGF0ZSA9PSAibGFldWZ0IiBlbHNl
IDAsCiAgICAgICAgICAgICAgICAibG9nIjogc2VsZi5sb2dsaW5lc1stODA6XSwKICAgICAgICAg
ICAgICAgICJjb25mIjogZGljdChDKSwKICAgICAgICAgICAgICAgICJsaW1lcyI6IExJTUVTLAog
ICAgICAgICAgICAgICAgImRldiI6IHsiZ3NtIjogbGltZV9sYWJlbChzZWxmLmRldl9nc20pIGlm
IHNlbGYuZGV2X2dzbSBlbHNlICIiLAogICAgICAgICAgICAgICAgICAgICAgICAibHRlIjogbGlt
ZV9sYWJlbChzZWxmLmRldl9sdGUpIGlmIHNlbGYuZGV2X2x0ZSBlbHNlICIifSwKICAgICAgICAg
ICAgICAgICJnc20iOiB7CiAgICAgICAgICAgICAgICAgICAgImFyZmNuIjogaW50KENbIkdTTV9B
UkZDTiJdKSwgImJhbmQiOiBhcmZjbl9iYW5kKGludChDWyJHU01fQVJGQ04iXSkpLAogICAgICAg
ICAgICAgICAgICAgICJtaHoiOiBhcmZjbl9taHooaW50KENbIkdTTV9BUkZDTiJdKSksCiAgICAg
ICAgICAgICAgICAgICAgImF0dGFjaGVkIjogc29ydGVkKG1zY19hdHRhY2hlZCgpKSBpZiBzZWxm
LnN0YXRlID09ICJsYWV1ZnQiIGVsc2UgW10sCiAgICAgICAgICAgICAgICAgICAgIm51bWJlcnMi
OiBudW1zX2xvYWQoKSwKICAgICAgICAgICAgICAgIH0sCiAgICAgICAgICAgICAgICAibHRlIjog
ewogICAgICAgICAgICAgICAgICAgICJlYXJmY24iOiBpbnQoQ1siTFRFX0VBUkZDTiJdKSwgImJh
bmQiOiBlYXJmY25fYmFuZChpbnQoQ1siTFRFX0VBUkZDTiJdKSksCiAgICAgICAgICAgICAgICAg
ICAgIm1oeiI6IGVhcmZjbl9taHooaW50KENbIkxURV9FQVJGQ04iXSkpLAogICAgICAgICAgICAg
ICAgfSwKICAgICAgICAgICAgICAgICJzaW1zIjogW3siaW1zaSI6IGksICJtc2lzZG4iOiBzLmdl
dCgibXNpc2RuIiwgIiIpfSBmb3IgaSwgcyBpbiBzb3J0ZWQoc2ltc19sb2FkKCkuaXRlbXMoKSld
LAogICAgICAgICAgICAgICAgInNpbWZpbGVzIjogc2ltX2ZpbGVzKCksCiAgICAgICAgICAgICAg
ICAidHoiOiAiVVRDJStkOiUwMmQlcyIgJSAodHpfbm93KClbMF0sIHR6X25vdygpWzFdLCAiICtT
b21tZXJ6ZWl0IiBpZiB0el9ub3coKVsyXSBlbHNlICIiKSwKICAgICAgICAgICAgICAgICJjbGFz
aCI6IGZyZXFfY2xhc2goKSwKICAgICAgICAgICAgICAgICJmYWtlIjogRkFLRSwKICAgICAgICAg
ICAgICAgICJwYXJ0cyI6IFt7ImlkIjogaSwgIm5hbWUiOiBufSBmb3IgaSwgbiBpbiBzZWxmLnBh
cnRzKCldLAogICAgICAgICAgICAgICAgInByb2NzIjogc2VsZi5wcm9jX2xpc3QoKSwgImJ1c3ki
OiBzZWxmLmJ1c3ksCiAgICAgICAgICAgIH0KICAgICAgICByZXR1cm4gc3QKCk5FVCA9IE5ldCgp
CgojID09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
PT09PT09PT09PT09PSBXZWItQVBJCmRlZiBoYW5kbGVfYXBpKHBhdGgsIGJvZHkpOgogICAgdHJ5
OgogICAgICAgIHJlcSA9IGpzb24ubG9hZHMoYm9keSBvciAie30iKQogICAgZXhjZXB0IEV4Y2Vw
dGlvbjoKICAgICAgICByZXEgPSB7fQogICAgY21kID0gcGF0aC5yc3BsaXQoIi8iLCAxKVstMV0K
ICAgIGlmIGNtZCA9PSAic3RhdHVzIjoKICAgICAgICByZXR1cm4gTkVULnN0YXR1cygpCiAgICBp
ZiBjbWQgaW4gKCJzdGFydF9nc20iLCAic3RhcnRfbHRlIiwgInN0YXJ0X2NzZmIiKToKICAgICAg
ICBORVQuc3RhcnQoY21kWzY6XSkKICAgIGVsaWYgY21kID09ICJzdG9wIjoKICAgICAgICBORVQu
c3RvcCgpCiAgICBlbGlmIGNtZCA9PSAicmVzdGFydCI6CiAgICAgICAgcGFydCA9IHJlLnN1Yihy
IlteYS16MC05Xy1dIiwgIiIsIHN0cihyZXEuZ2V0KCJwYXJ0IiwgIiIpKS5sb3dlcigpKQogICAg
ICAgIGVyciA9IE5FVC5yZXN0YXJ0KHBhcnQpCiAgICAgICAgaWYgZXJyOiBORVQubXNnID0gZXJy
CiAgICBlbGlmIGNtZCA9PSAibGltZV9zY2FuIjoKICAgICAgICBuID0gbGVuKGxpbWVfc2Nhbigp
KTsgTkVULm1zZyA9IGYie259IExpbWVTRFIgZ2VmdW5kZW4iCiAgICBlbGlmIGNtZCA9PSAic2V0
IjoKICAgICAgICAjIGJlbGllYmlnZSBLb25maWctS2V5cyBzZXR6ZW4gKHZhbGlkaWVydCBsaWdo
dCkKICAgICAgICBmb3IgaywgdiBpbiByZXEuaXRlbXMoKToKICAgICAgICAgICAgaWYgayBpbiBE
RUZBVUxUUyBvciBrIGluIEM6CiAgICAgICAgICAgICAgICB2ID0gc3RyKHYpLnJlcGxhY2UoJyIn
LCAiIikucmVwbGFjZSgiXG4iLCAiICIpLnN0cmlwKCkKICAgICAgICAgICAgICAgIGlmIGsgaW4g
KCJNQ0MiLCAiTU5DIiwgIkxURV9UQUMiKTogdiA9IHJlLnN1YihyIlxEIiwgIiIsIHYpCiAgICAg
ICAgICAgICAgICBjc2V0KGssIHYpCiAgICAgICAgTkVULm1zZyA9ICJnZXNwZWljaGVydCAtIHdp
cmt0IGJlaW0gbmFlY2hzdGVuIFN0YXJ0IgogICAgICAgIGlmIEMuZ2V0KCJHU01fREVWIikgYW5k
IEMuZ2V0KCJHU01fREVWIikgPT0gQy5nZXQoIkxURV9ERVYiKToKICAgICAgICAgICAgTkVULm1z
ZyA9ICJBY2h0dW5nOiBHU00gdW5kIExURSBudXR6ZW4gZGVuc2VsYmVuIExpbWVTRFIgLSBmdWVy
IExURSArIEdTTSB6d2VpIEdlcmFldGUgd2FlaGxlbiIKICAgIGVsaWYgY21kIGluICgic2ltX2Fk
ZCIsICJnc21fc2ltX2FkZCIsICJsdGVfc2ltX2FkZCIpOgogICAgICAgIE5FVC5tc2cgPSBzaW1f
YWRkKHJlcS5nZXQoImltc2kiLCIiKSwgcmVxLmdldCgia2kiLCIiKSwgcmVxLmdldCgib3BjIiwi
IiksIHJlcS5nZXQoIm1zaXNkbiIsIiIpKSBcCiAgICAgICAgICAgICAgICAgIG9yICJTSU0gZ2Vz
cGVpY2hlcnQgKEdTTSArIExURSkiCiAgICBlbGlmIGNtZCBpbiAoInNpbV9kZWwiLCAiZ3NtX3Np
bV9kZWwiLCAibHRlX3NpbV9kZWwiKToKICAgICAgICBzaW1fZGVsKHJlcS5nZXQoImltc2kiLCIi
KSk7IE5FVC5tc2cgPSAiU0lNIGdlbG9lc2NodCIKICAgIGVsaWYgY21kID09ICJnc21fc2ltX25y
IjoKICAgICAgICBORVQubXNnID0gZ3NtX3NpbV9ucihyZXEuZ2V0KCJpbXNpIiwiIiksIHJlcS5n
ZXQoIm1zaXNkbiIsIiIpKSBvciAiUnVmbnVtbWVyIGRhdWVyaGFmdCB6dWdld2llc2VuIgogICAg
ZWxpZiBjbWQgPT0gImdzbV9udW1fZGVsIjoKICAgICAgICBnc21fbnVtX2RlbChyZXEuZ2V0KCJp
bXNpIiwiIikpOyBORVQubXNnID0gIlJ1Zm51bW1lci1adXdlaXN1bmcgZ2Vsb2VzY2h0IgogICAg
ZWxpZiBjbWQgPT0gInNpbV9nZW4iOgogICAgICAgIHRyeToKICAgICAgICAgICAgZ2VuID0gc2lt
X2dlbmVyYXRlKHJlcS5nZXQoImNvdW50IiwgMSksIHJlcS5nZXQoIm1zaXNkbiIsICIiKSwgcmVx
LmdldCgiaWNjaWQiLCAiIikpCiAgICAgICAgICAgIE5FVC5tc2cgPSBmIntsZW4oZ2VuKX0gU0lN
LURhdGVuc2F0ei8tc2FldHplIGVyemV1Z3QiCiAgICAgICAgZXhjZXB0IEV4Y2VwdGlvbiBhcyBl
OgogICAgICAgICAgICBnZW4gPSBbXTsgTkVULm1zZyA9ICJFcnpldWdlbiBmZWhsZ2VzY2hsYWdl
bjogJXMiICUgZQogICAgICAgIHN0ID0gTkVULnN0YXR1cygpOyBzdFsiZ2VuZXJhdGVkIl0gPSBn
ZW4KICAgICAgICByZXR1cm4gc3QKICAgIGVsaWYgY21kID09ICJzbXNfdGVzdCI6CiAgICAgICAg
TkVULm1zZyA9IHNtc190ZXN0KHJlcS5nZXQoImltc2kiLCIiKSwgcmVxLmdldCgidGV4dCIsIiIp
KQogICAgZWxzZToKICAgICAgICBORVQubXNnID0gInVuYmVrYW5udCIKICAgIHJldHVybiBORVQu
c3RhdHVzKCkKCiMgPT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
PT09PT09PT09PT09PT09PT09PT09IFdlYi1PYmVyZmxhZWNoZSAoSFRNTCkKUEFHRSA9IHIiIiI8
IWRvY3R5cGUgaHRtbD48aHRtbCBsYW5nPWRlPjxoZWFkPjxtZXRhIGNoYXJzZXQ9dXRmLTg+Cjxt
ZXRhIG5hbWU9dmlld3BvcnQgY29udGVudD0id2lkdGg9ZGV2aWNlLXdpZHRoLGluaXRpYWwtc2Nh
bGU9MSI+CjxtZXRhIG5hbWU9dGhlbWUtY29sb3IgY29udGVudD0iIzBBMjQ2MyI+CjxsaW5rIHJl
bD1pY29uIGhyZWY9ImRhdGE6aW1hZ2Uvc3ZnK3htbDtiYXNlNjQsUEhOMlp5QjRiV3h1Y3owaWFI
UjBjRG92TDNkM2R5NTNNeTV2Y21jdk1qQXdNQzl6ZG1jaUlIWnBaWGRDYjNnOUlqQWdNQ0F4TURJ
MElERXdNalFpUGp4eVpXTjBJSGRwWkhSb1BTSXhNREkwSWlCb1pXbG5hSFE5SWpFd01qUWlJR1pw
Ykd3OUlpTXdRVEkwTmpNaVBqd3ZjbVZqZEQ0S1BHY2dkSEpoYm5ObWIzSnRQU0owY21GdWMyeGhk
R1VvTVRJM0xqWWdNelEzTGpBcElITmpZV3hsS0RFdU5qVXBJaUJtYVd4c1BTSnViMjVsSWlCemRI
SnZhMlV0YkdsdVpXTmhjRDBpY205MWJtUWlJSE4wY205clpTMXNhVzVsYW05cGJqMGljbTkxYm1R
aUlITjBjbTlyWlMxM2FXUjBhRDBpTXpJaVBnbzhaeUJ6ZEhKdmEyVTlJaU5HUmtaR1JrWWlQZ284
Y0dGMGFDQmtQU0pOTWpBZ09EQWdWakkyTmlJK1BDOXdZWFJvUGdvOFkybHlZMnhsSUdONFBTSTNN
aUlnWTNrOUlqRXpNeUlnY2owaU5USWlQand2WTJseVkyeGxQZ284TDJjK0NqeG5JSE4wY205clpU
MGlJMFpHUmtaR1JpSStDanh3WVhSb0lHUTlJazB4TnpnZ01UWWdVVEl3TmlBeE1EQWdNVGM0SURF
NE5DSStQQzl3WVhSb1BnbzhjR0YwYUNCa1BTSk5NVGt5SURFd01DQkRNakkySURrMklESTFNQ0Ey
TWlBeU5qWWdNVFlpUGp3dmNHRjBhRDRLUEM5blBnbzhjR0YwYUNCemRISnZhMlU5SWlNeVJVTTBS
akVpSUdROUlrMHhPVElnTVRBd0lFTXlNek1nTVRBeUlESTFOaUF4T0RNZ016WXpJREU0TXlCQk9E
TWdPRE1nTUNBd0lEQWdNell6SURFM0lFRTRNeUE0TXlBd0lEQWdNQ0F5T0RJZ01URTRJajQ4TDNC
aGRHZytDand2Wno0OEwzTjJaejQ9Ij4KPHRpdGxlPnBLT00gwrcgTmV0enN0ZXVlcnVuZzwvdGl0
bGU+CjxzdHlsZT4KOnJvb3R7LS1uYXZ5OiMwQTI0NjM7LS1iZzojMDYwZjIyOy0tYmcyOiMwYTE3
MzQ7LS1jYXJkOiMwYzFhM2I7LS1jYXJkMjojMTAyMjUwOy0tbGluZTojMWIyZjVlOy0tbGluZTI6
IzJhNDI4ODsKLS1mZzojZWFmMWZiOy0tbXV0OiM4ZWE0Y2E7LS1tdXQyOiM1ZDczOTg7LS1hY2M6
IzJFQzRGMTstLWFjYzI6IzAwOTZENjstLW9rOiMyRUM0RjE7LS1va2JnOiMwNzI0M2I7LS1lcnI6
I2ZmNWQ2YzsKLS1yOjA7LS1yMjowOy0tbW9ubzp1aS1tb25vc3BhY2UsU0ZNb25vLVJlZ3VsYXIs
TWVubG8sQ29uc29sYXMsbW9ub3NwYWNlfQoqe2JveC1zaXppbmc6Ym9yZGVyLWJveH1odG1sLGJv
ZHl7bWFyZ2luOjB9CmJvZHl7YmFja2dyb3VuZDpsaW5lYXItZ3JhZGllbnQoMTgwZGVnLCMwODEz
MzAsIzA1MTAxZik7Y29sb3I6dmFyKC0tZmcpOwpmb250OjE1cHgvMS41NSBzeXN0ZW0tdWksLWFw
cGxlLXN5c3RlbSxTZWdvZSBVSSxSb2JvdG8sc2Fucy1zZXJpZjttaW4taGVpZ2h0OjEwMHZofQpo
ZWFkZXJ7cG9zaXRpb246c3RpY2t5O3RvcDowO3otaW5kZXg6MjA7YmFja2dyb3VuZDp2YXIoLS1u
YXZ5KTtib3JkZXItdG9wOjJweCBzb2xpZCB2YXIoLS1hY2MpOwpib3JkZXItYm90dG9tOjFweCBz
b2xpZCB2YXIoLS1saW5lMik7cGFkZGluZzoxMnB4IDIwcHg7ZGlzcGxheTpmbGV4O2FsaWduLWl0
ZW1zOmNlbnRlcjtnYXA6MTZweDtmbGV4LXdyYXA6d3JhcH0KLmJyYW5ke2Rpc3BsYXk6ZmxleDth
bGlnbi1pdGVtczpjZW50ZXI7Z2FwOjEycHh9Ci5icmFuZCBzdmd7aGVpZ2h0OjMwcHg7d2lkdGg6
YXV0bztkaXNwbGF5OmJsb2NrfQouYnJhbmQgLnByb2R7Zm9udC1zaXplOjExcHg7Zm9udC13ZWln
aHQ6NzAwO2xldHRlci1zcGFjaW5nOi4xOGVtO3RleHQtdHJhbnNmb3JtOnVwcGVyY2FzZTtjb2xv
cjojOWZiNmRlO3BhZGRpbmctbGVmdDoxMnB4O2JvcmRlci1sZWZ0OjFweCBzb2xpZCAjMjc0MDdl
fQouY2hpcHtkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2dhcDo4cHg7cGFkZGluZzo2
cHggMTJweDtib3JkZXI6MXB4IHNvbGlkIHZhcigtLWxpbmUyKTtiYWNrZ3JvdW5kOiMwYjE3MzM7
Zm9udC1zaXplOjEycHg7Zm9udC13ZWlnaHQ6NzAwO2xldHRlci1zcGFjaW5nOi4wNmVtO3RleHQt
dHJhbnNmb3JtOnVwcGVyY2FzZX0KLmRvdHt3aWR0aDo4cHg7aGVpZ2h0OjhweDtiYWNrZ3JvdW5k
OnZhcigtLW11dCl9Ci5kb3Qub257YmFja2dyb3VuZDp2YXIoLS1hY2MpO2FuaW1hdGlvbjpwdWxz
ZSAycyBpbmZpbml0ZX0uZG90LmVycntiYWNrZ3JvdW5kOnZhcigtLWVycil9CkBrZXlmcmFtZXMg
cHVsc2V7MCV7Ym94LXNoYWRvdzowIDAgMCAwIHJnYmEoNDYsMTk2LDI0MSwuNSl9NzAle2JveC1z
aGFkb3c6MCAwIDAgN3B4IHJnYmEoNDYsMTk2LDI0MSwwKX0xMDAle2JveC1zaGFkb3c6MCAwIDAg
MCByZ2JhKDQ2LDE5NiwyNDEsMCl9fQouaHN0YXR7ZGlzcGxheTpmbGV4O2dhcDoxOHB4O2ZsZXgt
d3JhcDp3cmFwO2NvbG9yOnZhcigtLW11dCk7Zm9udC1zaXplOjEycHg7bWFyZ2luLWxlZnQ6YXV0
bzthbGlnbi1pdGVtczpjZW50ZXI7dGV4dC10cmFuc2Zvcm06dXBwZXJjYXNlO2xldHRlci1zcGFj
aW5nOi4wNWVtfQouaHN0YXQgYntjb2xvcjp2YXIoLS1mZyk7Zm9udC1mYW1pbHk6dmFyKC0tbW9u
byk7bGV0dGVyLXNwYWNpbmc6MDt0ZXh0LXRyYW5zZm9ybTpub25lfQojbXNne2NvbG9yOnZhcigt
LWFjYyk7Zm9udC1zaXplOjEycHg7dGV4dC10cmFuc2Zvcm06bm9uZTtsZXR0ZXItc3BhY2luZzow
fQouYmFkZ2V7Zm9udC1zaXplOjEwcHg7cGFkZGluZzozcHggOXB4O2JvcmRlcjoxcHggc29saWQg
dmFyKC0tYWNjKTtjb2xvcjp2YXIoLS1hY2MpO2ZvbnQtd2VpZ2h0OjcwMDtsZXR0ZXItc3BhY2lu
ZzouMTJlbX0KLndyYXB7bWF4LXdpZHRoOjEwNjBweDttYXJnaW46MCBhdXRvO3BhZGRpbmc6MjJw
eCAxNnB4IDQ0cHh9Ci5iYW5uZXJ7ZGlzcGxheTpmbGV4O2dhcDoxMXB4O2FsaWduLWl0ZW1zOmZs
ZXgtc3RhcnQ7YmFja2dyb3VuZDojMGMxYTNiO2JvcmRlcjoxcHggc29saWQgdmFyKC0tbGluZTIp
Owpib3JkZXItbGVmdDozcHggc29saWQgI2YxYjI0YTtjb2xvcjojZjJkNzlmO3BhZGRpbmc6MTJw
eCAxNXB4O2ZvbnQtc2l6ZToxM3B4O21hcmdpbi1ib3R0b206MThweH0KLmNvbnRyb2xze2Rpc3Bs
YXk6Z3JpZDtncmlkLXRlbXBsYXRlLWNvbHVtbnM6MWZyIDFmciAxZnIgYXV0bztnYXA6MTBweDtt
YXJnaW4tYm90dG9tOjIwcHh9CkBtZWRpYShtYXgtd2lkdGg6ODIwcHgpey5jb250cm9sc3tncmlk
LXRlbXBsYXRlLWNvbHVtbnM6MWZyIDFmcn19QG1lZGlhKG1heC13aWR0aDo0ODBweCl7LmNvbnRy
b2xze2dyaWQtdGVtcGxhdGUtY29sdW1uczoxZnJ9fQouYmlnYnRue2JvcmRlcjoxcHggc29saWQg
dmFyKC0tbGluZTIpO2JhY2tncm91bmQ6IzBiMTgzNjtjb2xvcjp2YXIoLS1mZyk7CnBhZGRpbmc6
MTVweCAxOHB4O2ZvbnQ6aW5oZXJpdDtmb250LXdlaWdodDo2MDA7Y3Vyc29yOnBvaW50ZXI7ZGlz
cGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtnYXA6MTJweDt0cmFuc2l0aW9uOi4xNXN9Ci5i
aWdidG46aG92ZXJ7Ym9yZGVyLWNvbG9yOnZhcigtLWFjYyk7YmFja2dyb3VuZDojMGUxZjQ3fS5i
aWdidG4gLmlje2ZvbnQtc2l6ZToxNnB4O2NvbG9yOnZhcigtLWFjYyl9Ci5iaWdidG4gc21hbGx7
ZGlzcGxheTpibG9jaztjb2xvcjp2YXIoLS1tdXQpO2ZvbnQtd2VpZ2h0OjQwMDtmb250LXNpemU6
MTFweDt0ZXh0LXRyYW5zZm9ybTp1cHBlcmNhc2U7bGV0dGVyLXNwYWNpbmc6LjA3ZW07bWFyZ2lu
LXRvcDoycHh9Ci5iaWdidG4uYWN0aXZle2JvcmRlci1jb2xvcjp2YXIoLS1hY2MpO2JhY2tncm91
bmQ6dmFyKC0tb2tiZyk7Ym94LXNoYWRvdzppbnNldCAzcHggMCAwIHZhcigtLWFjYyl9LmJpZ2J0
bi5hY3RpdmUgLmlje2NvbG9yOnZhcigtLWFjYyl9Ci5iaWdidG4uc3RvcHtiYWNrZ3JvdW5kOiMx
ZTEwMTY7Ym9yZGVyLWNvbG9yOiM1MzIzMmU7Y29sb3I6I2ZmYjBiODtqdXN0aWZ5LWNvbnRlbnQ6
Y2VudGVyO2ZvbnQtd2VpZ2h0OjcwMDtsZXR0ZXItc3BhY2luZzouMDVlbTt0ZXh0LXRyYW5zZm9y
bTp1cHBlcmNhc2U7Zm9udC1zaXplOjE0cHh9LmJpZ2J0bi5zdG9wOmhvdmVye2JvcmRlci1jb2xv
cjp2YXIoLS1lcnIpfQoudGFic3tkaXNwbGF5OmZsZXg7Z2FwOjRweDtib3JkZXItYm90dG9tOjFw
eCBzb2xpZCB2YXIoLS1saW5lMik7bWFyZ2luLWJvdHRvbToyMHB4O292ZXJmbG93LXg6YXV0b30K
LnRhYntwYWRkaW5nOjEwcHggMTZweDtib3JkZXI6MDtiYWNrZ3JvdW5kOjA7Y29sb3I6dmFyKC0t
bXV0KTtmb250OmluaGVyaXQ7Zm9udC13ZWlnaHQ6NzAwO2ZvbnQtc2l6ZToxMnB4O2xldHRlci1z
cGFjaW5nOi4wOWVtO3RleHQtdHJhbnNmb3JtOnVwcGVyY2FzZTtjdXJzb3I6cG9pbnRlcjtib3Jk
ZXItYm90dG9tOjJweCBzb2xpZCB0cmFuc3BhcmVudDt3aGl0ZS1zcGFjZTpub3dyYXA7bWFyZ2lu
LWJvdHRvbTotMXB4fQoudGFiOmhvdmVye2NvbG9yOnZhcigtLWZnKX0udGFiLnNlbHtjb2xvcjp2
YXIoLS1hY2MpO2JvcmRlci1ib3R0b20tY29sb3I6dmFyKC0tYWNjKX0KLnBhbmVse2Rpc3BsYXk6
bm9uZX0ucGFuZWwuc2Vse2Rpc3BsYXk6YmxvY2t9Ci5ncmlke2Rpc3BsYXk6Z3JpZDtnYXA6MTZw
eDtncmlkLXRlbXBsYXRlLWNvbHVtbnM6MWZyIDFmcn1AbWVkaWEobWF4LXdpZHRoOjc2MHB4KXsu
Z3JpZHtncmlkLXRlbXBsYXRlLWNvbHVtbnM6MWZyfX0KLmNhcmR7YmFja2dyb3VuZDp2YXIoLS1j
YXJkKTtib3JkZXI6MXB4IHNvbGlkIHZhcigtLWxpbmUpO3BhZGRpbmc6MThweH0KLmNhcmQgaDJ7
Zm9udC1zaXplOjEycHg7bWFyZ2luOjA7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtn
YXA6OXB4O3RleHQtdHJhbnNmb3JtOnVwcGVyY2FzZTtsZXR0ZXItc3BhY2luZzouMWVtO2NvbG9y
OiNjNmQ2ZjE7Zm9udC13ZWlnaHQ6NzAwfQouY2FyZCBoMjpiZWZvcmV7Y29udGVudDoiIjt3aWR0
aDo5cHg7aGVpZ2h0OjlweDtiYWNrZ3JvdW5kOnZhcigtLWFjYyk7ZmxleDpub25lfQouY2FyZCAu
c3Vie2NvbG9yOnZhcigtLW11dCk7Zm9udC1zaXplOjEycHg7bWFyZ2luOjhweCAwIDE0cHh9Cmxh
YmVse2Rpc3BsYXk6YmxvY2s7Zm9udC1zaXplOjExcHg7Y29sb3I6dmFyKC0tbXV0KTttYXJnaW46
MTNweCAwIDVweDtmb250LXdlaWdodDo3MDA7dGV4dC10cmFuc2Zvcm06dXBwZXJjYXNlO2xldHRl
ci1zcGFjaW5nOi4wN2VtfQppbnB1dCxzZWxlY3R7d2lkdGg6MTAwJTtiYWNrZ3JvdW5kOiMwNzE0
MmY7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1saW5lMik7Y29sb3I6dmFyKC0tZmcpO3BhZGRpbmc6
MTBweCAxMnB4O2ZvbnQ6aW5oZXJpdDtvdXRsaW5lOjA7dHJhbnNpdGlvbjouMTJzfQppbnB1dDpm
b2N1cyxzZWxlY3Q6Zm9jdXN7Ym9yZGVyLWNvbG9yOnZhcigtLWFjYyk7Ym94LXNoYWRvdzowIDAg
MCAycHggcmdiYSg0NiwxOTYsMjQxLC4xOCl9Ci5yb3d7ZGlzcGxheTpncmlkO2dyaWQtdGVtcGxh
dGUtY29sdW1uczoxZnIgMWZyO2dhcDoxMHB4fS5yb3cze2Rpc3BsYXk6Z3JpZDtncmlkLXRlbXBs
YXRlLWNvbHVtbnM6MWZyIDFmciAxZnI7Z2FwOjEwcHh9Ci5idG57YmFja2dyb3VuZDp2YXIoLS1h
Y2MpO2NvbG9yOnZhcigtLW5hdnkpO2JvcmRlcjowO3BhZGRpbmc6MTBweCAxOHB4O2ZvbnQ6aW5o
ZXJpdDtmb250LXdlaWdodDo3MDA7bGV0dGVyLXNwYWNpbmc6LjA1ZW07dGV4dC10cmFuc2Zvcm06
dXBwZXJjYXNlO2ZvbnQtc2l6ZToxM3B4O2N1cnNvcjpwb2ludGVyO21hcmdpbi10b3A6MTZweDt0
cmFuc2l0aW9uOi4xMnN9Ci5idG46aG92ZXJ7YmFja2dyb3VuZDojNWFkMmY2fS5idG4uc2Vje2Jh
Y2tncm91bmQ6dHJhbnNwYXJlbnQ7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1saW5lMik7Y29sb3I6
dmFyKC0tYWNjKX0uYnRuLnNlYzpob3Zlcntib3JkZXItY29sb3I6dmFyKC0tYWNjKTtiYWNrZ3Jv
dW5kOiMwYjFiNDB9Ci5idG4uc217cGFkZGluZzo4cHggMTNweDttYXJnaW4tdG9wOjRweDtmb250
LXNpemU6MTJweH0KLnN3e2Rpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7anVzdGlmeS1j
b250ZW50OnNwYWNlLWJldHdlZW47Z2FwOjEwcHg7cGFkZGluZzoxM3B4IDA7Ym9yZGVyLXRvcDox
cHggc29saWQgdmFyKC0tbGluZSl9Ci5zdy5maXJzdHtib3JkZXItdG9wOjB9LnN3IC50e2ZvbnQt
c2l6ZToxNHB4fS5zdyAudCBzbWFsbHtkaXNwbGF5OmJsb2NrO2NvbG9yOnZhcigtLW11dCk7Zm9u
dC1zaXplOjEycHh9Ci5zd2l0Y2h7cG9zaXRpb246cmVsYXRpdmU7d2lkdGg6NDZweDtoZWlnaHQ6
MjRweDtmbGV4Om5vbmV9LnN3aXRjaCBpbnB1dHtvcGFjaXR5OjA7d2lkdGg6MDtoZWlnaHQ6MH0K
LnNsaWRlcntwb3NpdGlvbjphYnNvbHV0ZTtpbnNldDowO2JhY2tncm91bmQ6IzBiMWEzZDtib3Jk
ZXI6MXB4IHNvbGlkIHZhcigtLWxpbmUyKTt0cmFuc2l0aW9uOi4ycztjdXJzb3I6cG9pbnRlcn0K
LnNsaWRlcjpiZWZvcmV7Y29udGVudDoiIjtwb3NpdGlvbjphYnNvbHV0ZTtoZWlnaHQ6MTZweDt3
aWR0aDoxNnB4O2xlZnQ6M3B4O3RvcDozcHg7YmFja2dyb3VuZDp2YXIoLS1tdXQpO3RyYW5zaXRp
b246LjJzfQouc3dpdGNoIGlucHV0OmNoZWNrZWQrLnNsaWRlcntiYWNrZ3JvdW5kOnZhcigtLW9r
YmcpO2JvcmRlci1jb2xvcjp2YXIoLS1hY2MpfS5zd2l0Y2ggaW5wdXQ6Y2hlY2tlZCsuc2xpZGVy
OmJlZm9yZXt0cmFuc2Zvcm06dHJhbnNsYXRlWCgyMnB4KTtiYWNrZ3JvdW5kOnZhcigtLWFjYyl9
Ci5oaW50e2ZvbnQtc2l6ZToxMnB4O2NvbG9yOnZhcigtLW11dCk7bWFyZ2luLXRvcDoxMHB4O2xp
bmUtaGVpZ2h0OjEuNX0KLmZyZXFib3h7YmFja2dyb3VuZDojMDcxNDJmO2JvcmRlcjoxcHggc29s
aWQgdmFyKC0tbGluZTIpO3BhZGRpbmc6MTNweCAxNnB4O2Rpc3BsYXk6ZmxleDtqdXN0aWZ5LWNv
bnRlbnQ6c3BhY2UtYmV0d2VlbjthbGlnbi1pdGVtczpjZW50ZXJ9Ci5mcmVxYm94IC5iaWd7Zm9u
dC1zaXplOjIycHg7Zm9udC13ZWlnaHQ6NzAwO2xpbmUtaGVpZ2h0OjEuMTU7Zm9udC1mYW1pbHk6
dmFyKC0tbW9ubyk7Y29sb3I6dmFyKC0tYWNjKX0uZnJlcWJveCAuc217Y29sb3I6dmFyKC0tbXV0
KTtmb250LXNpemU6MTJweDt0ZXh0LXRyYW5zZm9ybTp1cHBlcmNhc2U7bGV0dGVyLXNwYWNpbmc6
LjA2ZW19Ci5saXN0cm93e2Rpc3BsYXk6ZmxleDtqdXN0aWZ5LWNvbnRlbnQ6c3BhY2UtYmV0d2Vl
bjthbGlnbi1pdGVtczpjZW50ZXI7Ym9yZGVyLXRvcDoxcHggc29saWQgdmFyKC0tbGluZSk7cGFk
ZGluZzo5cHggMDtmb250LXNpemU6MTRweH0KLmxpc3Ryb3c6Zmlyc3QtY2hpbGR7Ym9yZGVyLXRv
cDowfS50YWd7Zm9udC1mYW1pbHk6dmFyKC0tbW9ubyk7Zm9udC1zaXplOjEzcHg7Y29sb3I6I2Nh
ZDlmM30KLnh7YmFja2dyb3VuZDojMWUxMDE2O2JvcmRlcjoxcHggc29saWQgIzUzMjMyZTtjb2xv
cjojZmY5YmE2O3BhZGRpbmc6NHB4IDEwcHg7Y3Vyc29yOnBvaW50ZXI7Zm9udC1zaXplOjExcHg7
dGV4dC10cmFuc2Zvcm06dXBwZXJjYXNlO2xldHRlci1zcGFjaW5nOi4wNWVtfS54OmhvdmVye2Jv
cmRlci1jb2xvcjp2YXIoLS1lcnIpfQouZW1wdHl7Y29sb3I6dmFyKC0tbXV0Mik7Zm9udC1zaXpl
OjEzcHg7cGFkZGluZzo4cHggMH0KLmxvZ3tiYWNrZ3JvdW5kOiMwMzBhMTg7Ym9yZGVyOjFweCBz
b2xpZCB2YXIoLS1saW5lKTtwYWRkaW5nOjE0cHg7Zm9udDoxMnB4LzEuNTUgdmFyKC0tbW9ubyk7
aGVpZ2h0OjQ0MHB4O292ZXJmbG93OmF1dG87d2hpdGUtc3BhY2U6cHJlLXdyYXA7Y29sb3I6Izlm
YjNkMH0KLnRvb2xiYXJ7ZGlzcGxheTpmbGV4O2dhcDo4cHg7YWxpZ24taXRlbXM6Y2VudGVyO21h
cmdpbi1ib3R0b206MTJweH0udG9vbGJhciBpbnB1dHtmbGV4OjF9Ci5lZnt3aWR0aDoxMDAlO2Jv
cmRlci1jb2xsYXBzZTpjb2xsYXBzZTtmb250LXNpemU6MTNweDttYXJnaW4tdG9wOjZweH0uZWYg
dGh7dGV4dC1hbGlnbjpsZWZ0O2NvbG9yOnZhcigtLW11dCk7Zm9udC1zaXplOjExcHg7dGV4dC10
cmFuc2Zvcm06dXBwZXJjYXNlO2xldHRlci1zcGFjaW5nOi4wN2VtO3BhZGRpbmc6OHB4IDZweDti
b3JkZXItYm90dG9tOjFweCBzb2xpZCB2YXIoLS1saW5lMil9LmVmIHRke3BhZGRpbmc6MTBweCA2
cHg7Ym9yZGVyLWJvdHRvbToxcHggc29saWQgdmFyKC0tbGluZSk7dmVydGljYWwtYWxpZ246dG9w
fS5lZiBjb2Rle2ZvbnQtZmFtaWx5OnZhcigtLW1vbm8pO2NvbG9yOnZhcigtLWFjYyk7d29yZC1i
cmVhazpicmVhay1hbGw7dXNlci1zZWxlY3Q6YWxsfS5tdXR7Y29sb3I6dmFyKC0tbXV0KTtmb250
LXNpemU6MTFweH0uZ2Vud3JhcHtvdmVyZmxvdy14OmF1dG87bWFyZ2luLXRvcDoxMnB4fS5nZW53
cmFwIC5lZiB0ZCwuZ2Vud3JhcCAuZWYgdGh7d2hpdGUtc3BhY2U6bm93cmFwfS5nZW53cmFwIGNv
ZGV7Zm9udC1zaXplOjEycHh9LmJ0bjpkaXNhYmxlZHtvcGFjaXR5Oi40O2N1cnNvcjpkZWZhdWx0
fS5wcm9jc3tkaXNwbGF5OmdyaWQ7Z3JpZC10ZW1wbGF0ZS1jb2x1bW5zOnJlcGVhdChhdXRvLWZp
bGwsbWlubWF4KDExOHB4LDFmcikpO2dhcDo2cHg7bWFyZ2luLXRvcDoxMnB4fS5wcm9je2Rpc3Bs
YXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7anVzdGlmeS1jb250ZW50OnNwYWNlLWJldHdlZW47
Z2FwOjZweDtib3JkZXI6MXB4IHNvbGlkIHZhcigtLWxpbmUpO2JvcmRlci1yYWRpdXM6OHB4O3Bh
ZGRpbmc6NHB4IDRweCA0cHggOHB4O2ZvbnQtc2l6ZToxMnB4fS5wcm9jIC5wZHt3aWR0aDo4cHg7
aGVpZ2h0OjhweDtib3JkZXItcmFkaXVzOjUwJTtiYWNrZ3JvdW5kOnZhcigtLWVycik7ZmxleDpu
b25lfS5wcm9jIC5wZC5vbntiYWNrZ3JvdW5kOnZhcigtLW9rKX0ucHJvYyBzcGFue2ZsZXg6MTtv
dmVyZmxvdzpoaWRkZW47dGV4dC1vdmVyZmxvdzplbGxpcHNpc30ucHJvYyBidXR0b257Ym9yZGVy
OjA7YmFja2dyb3VuZDp0cmFuc3BhcmVudDtjb2xvcjp2YXIoLS1tdXQpO2N1cnNvcjpwb2ludGVy
O2ZvbnQtc2l6ZToxNXB4O3BhZGRpbmc6MnB4IDZweDtib3JkZXItcmFkaXVzOjZweH0ucHJvYyBi
dXR0b246aG92ZXJ7Y29sb3I6dmFyKC0tZmcpO2JhY2tncm91bmQ6dmFyKC0tbGluZSl9Y29kZXtm
b250LWZhbWlseTp2YXIoLS1tb25vKX1AbWVkaWEobWF4LXdpZHRoOjU2MHB4KXsucm93LC5yb3cz
e2dyaWQtdGVtcGxhdGUtY29sdW1uczoxZnJ9fQo8L3N0eWxlPjwvaGVhZD48Ym9keT4KPGhlYWRl
cj4KIDxkaXYgY2xhc3M9YnJhbmQ+PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9z
dmciIHZpZXdCb3g9Ii0yMCAtMjAgNjY4IDMzMCIgcm9sZT0iaW1nIiBhcmlhLWxhYmVsPSJwS09N
Ij48ZyBmaWxsPSJub25lIiBzdHJva2UtbGluZWNhcD0icm91bmQiIHN0cm9rZS1saW5lam9pbj0i
cm91bmQiIHN0cm9rZS13aWR0aD0iMzIiPjxnIHN0cm9rZT0iI0ZGRkZGRiI+PHBhdGggZD0iTTIw
IDgwIFYyNjYiPjwvcGF0aD48Y2lyY2xlIGN4PSI3MiIgY3k9IjEzMyIgcj0iNTIiPjwvY2lyY2xl
PjxwYXRoIGQ9Ik0xNzggMTYgUTIwNiAxMDAgMTc4IDE4NCI+PC9wYXRoPjxwYXRoIGQ9Ik0xOTIg
MTAwIEMyMjYgOTYgMjUwIDYyIDI2NiAxNiI+PC9wYXRoPjxwYXRoIGQ9Ik00OTIgMTg0IFYzMCBD
NTIyIDMwIDUzNCAxMDYgNTUyIDEwNiBDNTcwIDEwNiA1ODIgMzAgNjEyIDMwIFYxODQiPjwvcGF0
aD48L2c+PHBhdGggc3Ryb2tlPSIjMkVDNEYxIiBkPSJNMTkyIDEwMCBDMjMzIDEwMiAyNTYgMTgz
IDM2MyAxODMgQTgzIDgzIDAgMCAwIDM2MyAxNyBBODMgODMgMCAwIDAgMjgyIDExOCI+PC9wYXRo
PjwvZz48L3N2Zz48c3BhbiBjbGFzcz1wcm9kPk5ldHpzdGV1ZXJ1bmc8L3NwYW4+PC9kaXY+CiA8
ZGl2IGNsYXNzPWNoaXA+PHNwYW4gY2xhc3M9ZG90IGlkPWRvdD48L3NwYW4+PHNwYW4gaWQ9c3Rh
dGU+4oCTPC9zcGFuPjwvZGl2PgogPGRpdiBjbGFzcz1oc3RhdD4KICA8c3BhbiBpZD10ZWNoYmFk
Z2UgY2xhc3M9YmFkZ2Ugc3R5bGU9ZGlzcGxheTpub25lPjwvc3Bhbj4KICA8c3Bhbj5GcmVxdWVu
eiA8YiBpZD1mcmVxPuKAkzwvYj48L3NwYW4+CiAgPHNwYW4+TGF1ZnplaXQgPGIgaWQ9dXB0aW1l
PuKAkzwvYj48L3NwYW4+CiAgPHNwYW4gaWQ9bXNnPjwvc3Bhbj4KIDwvZGl2Pgo8L2hlYWRlcj4K
PGRpdiBjbGFzcz13cmFwPgogPGRpdiBjbGFzcz1iYW5uZXI+PHNwYW4+4pqg77iPPC9zcGFuPjxz
cGFuPjxiPk51ciBhYmdlc2Nob3R0ZXQgYmV0cmVpYmVuPC9iPiDigJMgRHVtbXkgTG9hZCAvIEth
YmVsICsgRMOkbXBmdW5nIC8gZ2VzY2hpcm10LiBPZmZlbmVzIE5ldHogb2huZSBBdXRoZW50aXNp
ZXJ1bmcgPSBJTVNJLUNhdGNoZXIsIHdlbm4gZXMgYWJzdHJhaGx0LiBOdXIgZWlnZW5lIFRlc3Qt
U0lNcywgS2VubnVuZyAwMDEveHggKFRlc3QpIG9kZXIgOTk5L3h4IChwcml2YXQpLjwvc3Bhbj48
L2Rpdj4KCiA8ZGl2IGNsYXNzPWNvbnRyb2xzPgogIDxidXR0b24gY2xhc3M9YmlnYnRuIGlkPWJ0
bl9nc20gb25jbGljaz0iY21kKCdzdGFydF9nc20nKSI+PHNwYW4gY2xhc3M9aWM+4pa2PC9zcGFu
PjxzcGFuPkdTTSAoMkcpPHNtYWxsIGlkPWdzbV9zdWI+T3Ntb2NvbTwvc21hbGw+PC9zcGFuPjwv
YnV0dG9uPgogIDxidXR0b24gY2xhc3M9YmlnYnRuIGlkPWJ0bl9sdGUgb25jbGljaz0iY21kKCdz
dGFydF9sdGUnKSI+PHNwYW4gY2xhc3M9aWM+4pa2PC9zcGFuPjxzcGFuPkxURSAoNEcpPHNtYWxs
IGlkPWx0ZV9zdWI+c3JzUkFOICsgT3BlbjVHUzwvc21hbGw+PC9zcGFuPjwvYnV0dG9uPgogIDxi
dXR0b24gY2xhc3M9YmlnYnRuIGlkPWJ0bl9jc2ZiIG9uY2xpY2s9ImNtZCgnc3RhcnRfY3NmYicp
Ij48c3BhbiBjbGFzcz1pYz7ilrY8L3NwYW4+PHNwYW4+TFRFICsgR1NNPHNtYWxsIGlkPWNzZmJf
c3ViPkludGVybmV0ICsgQW5ydWZlIChDU0ZCKTwvc21hbGw+PC9zcGFuPjwvYnV0dG9uPgogIDxi
dXR0b24gY2xhc3M9ImJpZ2J0biBzdG9wIiBvbmNsaWNrPSJjbWQoJ3N0b3AnKSI+4pagIFN0b3Bw
ZW48L2J1dHRvbj4KIDwvZGl2PgoKIDxkaXYgY2xhc3M9dGFicz4KICA8YnV0dG9uIGNsYXNzPSJ0
YWIgc2VsIiBkYXRhLXQ9c3RldWVydW5nIG9uY2xpY2s9InRhYignc3RldWVydW5nJykiPlN0ZXVl
cnVuZzwvYnV0dG9uPgogIDxidXR0b24gY2xhc3M9dGFiIGRhdGEtdD1nc20gb25jbGljaz0idGFi
KCdnc20nKSI+R1NNIMK3IDJHPC9idXR0b24+CiAgPGJ1dHRvbiBjbGFzcz10YWIgZGF0YS10PWx0
ZSBvbmNsaWNrPSJ0YWIoJ2x0ZScpIj5MVEUgwrcgNEc8L2J1dHRvbj4KICA8YnV0dG9uIGNsYXNz
PXRhYiBkYXRhLXQ9c2ltcyBvbmNsaWNrPSJ0YWIoJ3NpbXMnKSI+U0lNcyAmIE51bW1lcm48L2J1
dHRvbj4KICA8YnV0dG9uIGNsYXNzPXRhYiBkYXRhLXQ9cHJvZmlsIG9uY2xpY2s9InRhYigncHJv
ZmlsJykiPlNJTS1Qcm9maWw8L2J1dHRvbj4KICA8YnV0dG9uIGNsYXNzPXRhYiBkYXRhLXQ9bG9n
IG9uY2xpY2s9InRhYignbG9nJykiPlByb3Rva29sbDwvYnV0dG9uPgogPC9kaXY+CgogPGRpdiBj
bGFzcz0icGFuZWwgc2VsIiBpZD1wLXN0ZXVlcnVuZz4KICA8ZGl2IGNsYXNzPWdyaWQ+CiAgIDxk
aXYgY2xhc3M9Y2FyZD4KICAgIDxoMj5TdGF0dXM8L2gyPgogICAgPGRpdiBjbGFzcz1mcmVxYm94
IHN0eWxlPW1hcmdpbi10b3A6MTJweD4KICAgICA8ZGl2PjxkaXYgY2xhc3M9YmlnIGlkPWZyZXEy
PuKAkzwvZGl2PjxkaXYgY2xhc3M9c20gaWQ9ZnJlcXN1Yj48L2Rpdj48L2Rpdj4KICAgICA8ZGl2
IHN0eWxlPXRleHQtYWxpZ246cmlnaHQ+PGRpdiBjbGFzcz1iaWcgaWQ9dGVjaDI+YXVzPC9kaXY+
PGRpdiBjbGFzcz1zbSBpZD1zdGF0ZXN1Yj48L2Rpdj48L2Rpdj4KICAgIDwvZGl2PgogICAgPGRp
diBjbGFzcz1oaW50IGlkPXVwdGltZWhpbnQ+PC9kaXY+CiAgICA8ZGl2IGNsYXNzPWhpbnQgaWQ9
ZGV2aGludD48L2Rpdj4KICAgIDxkaXYgY2xhc3M9aGludCBpZD1jbGFzaCBzdHlsZT1jb2xvcjp2
YXIoLS1lcnIpPjwvZGl2PgogICA8L2Rpdj4KICAgPGRpdiBjbGFzcz1jYXJkPgogICAgPGgyPk5l
dXN0YXJ0ZW48L2gyPgogICAgPHAgY2xhc3M9c3ViPkVpbnplbG5lIFRlaWxlIG5ldSBzdGFydGVu
LCBvaG5lIGRhcyBnYW56ZSBOZXR6IGFuenVoYWx0ZW4uIEtvbmZpZ3VyYXRpb24gd2lyZCBkYWJl
aSBuZXUgZ2VzY2hyaWViZW4uPC9wPgogICAgPGRpdiBpZD1wYXJ0cyBzdHlsZT1kaXNwbGF5OmZs
ZXg7Z2FwOjhweDtmbGV4LXdyYXA6d3JhcD48L2Rpdj4KICAgIDxkaXYgaWQ9cHJvY3MgY2xhc3M9
cHJvY3M+PC9kaXY+CiAgICA8ZGl2IGNsYXNzPWhpbnQgaWQ9cGFydGhpbnQ+U3RhcnRldCwgc29i
YWxkIGVpbiBOZXR6IGzDpHVmdC48L2Rpdj4KICAgPC9kaXY+CiAgIDxkaXYgY2xhc3M9Y2FyZD4K
ICAgIDxoMj5GdW5rLUhhcmR3YXJlPC9oMj4KICAgIDxwIGNsYXNzPXN1Yj5KZSBOZXR6IGVpbiBl
aWdlbmVyIExpbWVTRFIuIEbDvHIg4oCeTFRFICsgR1NN4oCcIHp3ZWkgdmVyc2NoaWVkZW5lIHfD
pGhsZW4uPC9wPgogICAgPGxhYmVsPkxpbWVTRFIgZsO8ciBHU00gKDJHKTwvbGFiZWw+PHNlbGVj
dCBpZD1HU01fREVWPjwvc2VsZWN0PgogICAgPGxhYmVsPkxpbWVTRFIgZsO8ciBMVEUgKDRHKTwv
bGFiZWw+PHNlbGVjdCBpZD1MVEVfREVWPjwvc2VsZWN0PgogICAgPGRpdiBzdHlsZT1kaXNwbGF5
OmZsZXg7Z2FwOjhweDtmbGV4LXdyYXA6d3JhcD4KICAgICA8YnV0dG9uIGNsYXNzPWJ0biBvbmNs
aWNrPSJzYXZlKFsnR1NNX0RFVicsJ0xURV9ERVYnXSkiPlNwZWljaGVybjwvYnV0dG9uPgogICAg
IDxidXR0b24gY2xhc3M9ImJ0biBzZWMiIG9uY2xpY2s9ImNtZCgnbGltZV9zY2FuJykiPk5ldSBz
dWNoZW48L2J1dHRvbj4KICAgIDwvZGl2PgogICAgPGRpdiBjbGFzcz1oaW50IGlkPWxpbWVsaXN0
PjwvZGl2PgogICA8L2Rpdj4KICAgPGRpdiBjbGFzcz1jYXJkPgogICAgPGgyPk5ldHotSWRlbnRp
dMOkdDwvaDI+CiAgICA8cCBjbGFzcz1zdWI+R2lsdCBmw7xyIEdTTSB1bmQgTFRFLiBOdXIgVGVz
dGtlbm51bmcgMDAxL3h4IG9kZXIgUHJpdmF0a2VubnVuZyA5OTkveHguPC9wPgogICAgPGRpdiBj
bGFzcz1yb3c+CiAgICAgPGRpdj48bGFiZWw+TUNDPC9sYWJlbD48aW5wdXQgaWQ9TUNDIGlucHV0
bW9kZT1udW1lcmljPjwvZGl2PgogICAgIDxkaXY+PGxhYmVsPk1OQzwvbGFiZWw+PGlucHV0IGlk
PU1OQyBpbnB1dG1vZGU9bnVtZXJpYz48L2Rpdj4KICAgIDwvZGl2PgogICAgPGRpdiBjbGFzcz1y
b3c+CiAgICAgPGRpdj48bGFiZWw+TmV0em5hbWUgKGxhbmcpPC9sYWJlbD48aW5wdXQgaWQ9TkVU
TkFNRT48L2Rpdj4KICAgICA8ZGl2PjxsYWJlbD5OZXR6bmFtZSAoa3Vyeik8L2xhYmVsPjxpbnB1
dCBpZD1ORVROQU1FX1NIT1JUPjwvZGl2PgogICAgPC9kaXY+CiAgICA8bGFiZWw+QW5iaWV0ZXJu
YW1lIChTUE4sIG1heC4gMTYgWmVpY2hlbik8L2xhYmVsPjxpbnB1dCBpZD1TUE4gbWF4bGVuZ3Ro
PTE2PgogICAgPGRpdiBjbGFzcz1zdz48ZGl2IGNsYXNzPXQ+TklUWiBzZW5kZW48c21hbGw+TmV0
em5hbWUsIFVocnplaXQgdW5kIFplaXR6b25lICg8c3BhbiBpZD10ej7igJM8L3NwYW4+KSBiZWlt
IEVpbmJ1Y2hlbjwvc21hbGw+PC9kaXY+CiAgICAgPGxhYmVsIGNsYXNzPXN3aXRjaD48aW5wdXQg
dHlwZT1jaGVja2JveCBpZD1OSVRaPjxzcGFuIGNsYXNzPXNsaWRlcj48L3NwYW4+PC9sYWJlbD48
L2Rpdj4KICAgIDxidXR0b24gY2xhc3M9ImJ0biBzZWMiIG9uY2xpY2s9InNhdmUoWydNQ0MnLCdN
TkMnLCdORVROQU1FJywnTkVUTkFNRV9TSE9SVCcsJ1NQTicsJ05JVFonXSkiPlNwZWljaGVybjwv
YnV0dG9uPgogICAgPHAgY2xhc3M9aGludD5EYW1pdCBkYXMgaVBob25lIGRhcyBOZXR6IGFscyA8
Yj5IZWltbmV0ejwvYj4gc2llaHQgKGtlaW4gUm9hbWluZyksIG11c3MgZGllIElNU0kgZGVyIGVT
SU0gbWl0IE1DQytNTkMgYmVnaW5uZW46IDxiIGNsYXNzPXRhZyBpZD1ocGxtbj7igJM8L2I+4oCm
PC9wPgogICA8L2Rpdj4KICA8L2Rpdj4KIDwvZGl2PgoKIDxkaXYgY2xhc3M9cGFuZWwgaWQ9cC1n
c20+CiAgPGRpdiBjbGFzcz1ncmlkPgogICA8ZGl2IGNsYXNzPWNhcmQ+CiAgICA8aDI+R1NNLUZ1
bms8L2gyPgogICAgPGRpdiBjbGFzcz1yb3cgc3R5bGU9YWxpZ24taXRlbXM6ZW5kPgogICAgIDxk
aXY+PGxhYmVsPkFSRkNOPC9sYWJlbD48aW5wdXQgaWQ9R1NNX0FSRkNOIG9uaW5wdXQ9dXBkYXRl
RnJlcSgpPjwvZGl2PgogICAgIDxkaXYgY2xhc3M9ZnJlcWJveD48ZGl2PjxkaXYgY2xhc3M9Ymln
IGlkPWdzbV9taHo+4oCTPC9kaXY+PGRpdiBjbGFzcz1zbSBpZD1nc21fYmFuZD48L2Rpdj48L2Rp
dj48L2Rpdj4KICAgIDwvZGl2PgogICAgPGRpdiBjbGFzcz1oaW50PjHigJMxMjQgPSBHU005MDAg
wrcgNTEy4oCTODg1ID0gRENTMTgwMDwvZGl2PgogICAgPGRpdiBjbGFzcz1yb3c+PGRpdj48bGFi
ZWw+VFgtR2FpbjwvbGFiZWw+PGlucHV0IGlkPUdTTV9UWF9HQUlOPjwvZGl2PgogICAgIDxkaXY+
PGxhYmVsPlJYLUdhaW4gKDDigJM1MCk8L2xhYmVsPjxpbnB1dCBpZD1HU01fUlhfR0FJTj48L2Rp
dj48L2Rpdj4KICAgIDxkaXYgY2xhc3M9aGludD5SWC1HYWluIGhvY2ggPSBlbXBmaW5kbGljaGVy
ZXIgRW1wZmFuZyAod2ljaHRpZyBmw7xyIEVER0UtVXBsaW5rKS48L2Rpdj4KICAgIDxidXR0b24g
Y2xhc3M9YnRuIG9uY2xpY2s9InNhdmUoWydHU01fQVJGQ04nLCdHU01fVFhfR0FJTicsJ0dTTV9S
WF9HQUlOJ10pIj5TcGVpY2hlcm48L2J1dHRvbj4KICAgPC9kaXY+CiAgIDxkaXYgY2xhc3M9Y2Fy
ZD4KICAgIDxoMj5HU00tT3B0aW9uZW48L2gyPgogICAgPGRpdiBjbGFzcz0ic3cgZmlyc3QiPjxk
aXYgY2xhc3M9dD5PZmZlbmUgQW5tZWxkdW5nPHNtYWxsPmplZGUgU0lNIHdpcmQgZWluZ2VidWNo
dDwvc21hbGw+PC9kaXY+CiAgICAgPGxhYmVsIGNsYXNzPXN3aXRjaD48aW5wdXQgdHlwZT1jaGVj
a2JveCBpZD1HU01fT1BFTj48c3BhbiBjbGFzcz1zbGlkZXI+PC9zcGFuPjwvbGFiZWw+PC9kaXY+
CiAgICA8ZGl2IGNsYXNzPXN3PjxkaXYgY2xhc3M9dD5FREdFIC8gR1BSUy1EYXRlbjxzbWFsbD5Q
YWtldGRhdGVuIChwY3Uvc2dzbi9nZ3NuKTwvc21hbGw+PC9kaXY+CiAgICAgPGxhYmVsIGNsYXNz
PXN3aXRjaD48aW5wdXQgdHlwZT1jaGVja2JveCBpZD1HU01fREFUQT48c3BhbiBjbGFzcz1zbGlk
ZXI+PC9zcGFuPjwvbGFiZWw+PC9kaXY+CiAgICA8ZGl2IGNsYXNzPXN3PjxkaXYgY2xhc3M9dD5T
SVAtVHJ1bmsgenUgQXN0ZXJpc2s8c21hbGw+QW5ydWZlIGlucyBWb0lQL0Zlc3RuZXR6PC9zbWFs
bD48L2Rpdj4KICAgICA8bGFiZWwgY2xhc3M9c3dpdGNoPjxpbnB1dCB0eXBlPWNoZWNrYm94IGlk
PUdTTV9TSVA+PHNwYW4gY2xhc3M9c2xpZGVyPjwvc3Bhbj48L2xhYmVsPjwvZGl2PgogICAgPGxh
YmVsPlNJUC1QZWVyIChBc3Rlcmlzay1JUCk8L2xhYmVsPjxpbnB1dCBpZD1HU01fU0lQX1BFRVI+
CiAgICA8bGFiZWw+U0lQLUxvY2FsLUlQIChsZWVyID0gYXV0b21hdGlzY2gpPC9sYWJlbD48aW5w
dXQgaWQ9R1NNX1NJUF9MT0NBTD4KICAgIDxidXR0b24gY2xhc3M9YnRuIG9uY2xpY2s9InNhdmUo
WydHU01fT1BFTicsJ0dTTV9EQVRBJywnR1NNX1NJUCcsJ0dTTV9TSVBfUEVFUicsJ0dTTV9TSVBf
TE9DQUwnXSkiPlNwZWljaGVybjwvYnV0dG9uPgogICA8L2Rpdj4KICAgPGRpdiBjbGFzcz1jYXJk
PgogICAgPGgyPkJlZ3LDvMOfdW5ncy1TTVM8L2gyPgogICAgPHAgY2xhc3M9c3ViPlNNUyBiZWlt
IEVpbmJ1Y2hlbiB1bmQgYmVpIE51bW1lcm52ZXJnYWJlLiBQbGF0emhhbHRlcjogPGNvZGU+e25l
dHp9PC9jb2RlPiwgPGNvZGU+e251bW1lcn08L2NvZGU+LCA8Y29kZT57ZXh0ZXJufTwvY29kZT4u
PC9wPgogICAgPGRpdiBjbGFzcz0ic3cgZmlyc3QiPjxkaXYgY2xhc3M9dD5TTVMgYWt0aXY8c21h
bGw+V2lsbGtvbW1lbiArIE51bW1lcm4tQmVzdMOkdGlndW5nPC9zbWFsbD48L2Rpdj4KICAgICA8
bGFiZWwgY2xhc3M9c3dpdGNoPjxpbnB1dCB0eXBlPWNoZWNrYm94IGlkPUdTTV9TTVM+PHNwYW4g
Y2xhc3M9c2xpZGVyPjwvc3Bhbj48L2xhYmVsPjwvZGl2PgogICAgPGxhYmVsPkFic2VuZGVyLU51
bW1lcjwvbGFiZWw+PGlucHV0IGlkPUdTTV9TTVNfRlJPTT4KICAgIDxsYWJlbD5FeHRlcm5lIFZv
cndhaGwgKDxjb2RlPntleHRlcm59PC9jb2RlPiA9IFZvcndhaGwgKyBpbnRlcm5lIE51bW1lcik8
L2xhYmVsPjxpbnB1dCBpZD1HU01fU01TX0VYVFBSRUZJWD4KICAgIDxsYWJlbD5XaWxsa29tbWVu
c3RleHQgKGJlaW0gRWluYnVjaGVuKTwvbGFiZWw+PGlucHV0IGlkPUdTTV9TTVNfV0VMQ09NRT4K
ICAgIDxsYWJlbD5CZXN0w6R0aWd1bmcgKGJlaSBOdW1tZXJudmVyZ2FiZSk8L2xhYmVsPjxpbnB1
dCBpZD1HU01fU01TX05VTUJFUj4KICAgIDxidXR0b24gY2xhc3M9YnRuIG9uY2xpY2s9InNhdmUo
WydHU01fU01TJywnR1NNX1NNU19GUk9NJywnR1NNX1NNU19FWFRQUkVGSVgnLCdHU01fU01TX1dF
TENPTUUnLCdHU01fU01TX05VTUJFUiddKSI+U3BlaWNoZXJuPC9idXR0b24+CiAgICA8cCBjbGFz
cz1oaW50PkJlZ3LDvMOfdW5nIHdpcmQgamUgTmV0ei1TdGFydCBlaW5tYWwgcHJvIFNJTSBnZXNl
bmRldCAod2lya3Qgc29mb3J0KS48L3A+CiAgICA8ZGl2IHN0eWxlPSJib3JkZXItdG9wOjFweCBz
b2xpZCB2YXIoLS1saW5lKTttYXJnaW46MTRweCAwIj48L2Rpdj4KICAgIDxkaXYgY2xhc3M9cm93
PjxkaXY+PGxhYmVsPlRlc3Q6IElNU0k8L2xhYmVsPjxpbnB1dCBpZD1zbXNfdGVzdF9pbXNpPjwv
ZGl2PgogICAgIDxkaXY+PGxhYmVsPlRleHQgKGxlZXIgPSBXaWxsa29tbWVuc3RleHQpPC9sYWJl
bD48aW5wdXQgaWQ9c21zX3Rlc3RfdGV4dD48L2Rpdj48L2Rpdj4KICAgIDxidXR0b24gY2xhc3M9
ImJ0biBzZWMiIG9uY2xpY2s9InNtc3Rlc3QoKSI+VGVzdC1TTVMgc2VuZGVuPC9idXR0b24+CiAg
ICA8cCBjbGFzcz1oaW50PlNlbmRldCBzb2ZvcnQgYW4gZGllIElNU0kg4oCTIGF1Y2ggd2VubiDi
gJ5TTVMgYWt0aXYiIGF1cyBpc3QuIEdTTSBtdXNzIGxhdWZlbi48L3A+CiAgIDwvZGl2PgogIDwv
ZGl2PgogIDxwIGNsYXNzPWhpbnQ+RnVuay0vT3B0aW9ucy3DhG5kZXJ1bmdlbiB3aXJrZW4gYmVp
bSBuw6RjaHN0ZW4gR1NNLVN0YXJ0LjwvcD4KIDwvZGl2PgoKIDxkaXYgY2xhc3M9cGFuZWwgaWQ9
cC1sdGU+CiAgPGRpdiBjbGFzcz1ncmlkPgogICA8ZGl2IGNsYXNzPWNhcmQ+CiAgICA8aDI+TFRF
LUZ1bms8L2gyPgogICAgPGRpdiBjbGFzcz1yb3cgc3R5bGU9YWxpZ24taXRlbXM6ZW5kPgogICAg
IDxkaXY+PGxhYmVsPkVBUkZDTjwvbGFiZWw+PGlucHV0IGlkPUxURV9FQVJGQ04gb25pbnB1dD11
cGRhdGVGcmVxKCk+PC9kaXY+CiAgICAgPGRpdiBjbGFzcz1mcmVxYm94PjxkaXY+PGRpdiBjbGFz
cz1iaWcgaWQ9bHRlX21oej7igJM8L2Rpdj48ZGl2IGNsYXNzPXNtIGlkPWx0ZV9iYW5kPjwvZGl2
PjwvZGl2PjwvZGl2PgogICAgPC9kaXY+CiAgICA8bGFiZWw+QmFuZGJyZWl0ZSAoUFJCKTwvbGFi
ZWw+PHNlbGVjdCBpZD1MVEVfTlBSQj4KICAgICA8b3B0aW9uIHZhbHVlPTY+NiDCtyAxLjQgTUh6
PC9vcHRpb24+PG9wdGlvbiB2YWx1ZT0xNT4xNSDCtyAzIE1Iejwvb3B0aW9uPgogICAgIDxvcHRp
b24gdmFsdWU9MjU+MjUgwrcgNSBNSHo8L29wdGlvbj48b3B0aW9uIHZhbHVlPTUwPjUwIMK3IDEw
IE1Iejwvb3B0aW9uPgogICAgIDxvcHRpb24gdmFsdWU9NzU+NzUgwrcgMTUgTUh6PC9vcHRpb24+
PG9wdGlvbiB2YWx1ZT0xMDA+MTAwIMK3IDIwIE1Iejwvb3B0aW9uPjwvc2VsZWN0PgogICAgPGRp
diBjbGFzcz1oaW50PlNjaHdhY2hlIEhhcmR3YXJlIChQaSk6IGtsZWluIHfDpGhsZW4gKDbigJMy
NSkuPC9kaXY+CiAgICA8YnV0dG9uIGNsYXNzPWJ0biBvbmNsaWNrPSJzYXZlKFsnTFRFX0VBUkZD
TicsJ0xURV9OUFJCJ10pIj5TcGVpY2hlcm48L2J1dHRvbj4KICAgPC9kaXY+CiAgIDxkaXYgY2xh
c3M9Y2FyZD4KICAgIDxoMj5MVEUtUGFyYW1ldGVyPC9oMj4KICAgIDxkaXYgY2xhc3M9cm93Pjxk
aXY+PGxhYmVsPlRYLUdhaW48L2xhYmVsPjxpbnB1dCBpZD1MVEVfVFhfR0FJTj48L2Rpdj4KICAg
ICA8ZGl2PjxsYWJlbD5SWC1HYWluPC9sYWJlbD48aW5wdXQgaWQ9TFRFX1JYX0dBSU4+PC9kaXY+
PC9kaXY+CiAgICA8bGFiZWw+QVBOPC9sYWJlbD48aW5wdXQgaWQ9TFRFX0FQTj4KICAgIDxidXR0
b24gY2xhc3M9YnRuIG9uY2xpY2s9InNhdmUoWydMVEVfVFhfR0FJTicsJ0xURV9SWF9HQUlOJywn
TFRFX0FQTiddKSI+U3BlaWNoZXJuPC9idXR0b24+CiAgICA8cCBjbGFzcz1oaW50PkxURSBicmF1
Y2h0IFNJTXMgbWl0IEtpL09QYyAoVGFiIOKAnlNJTXPigJwpLiBLZXJuOiBPcGVuNUdTLCBIYW5k
eS1OZXR6IDEwLjQ1LjAuMC8xNiBtaXQgTkFUIGlucyBJbnRlcm5ldC4gQmVpIOKAnkxURSArIEdT
TeKAnCBkYXJmIGRpZSBHU00tRnJlcXVlbnogbmljaHQgaW0gTFRFLUthbmFsIGxpZWdlbi48L3A+
CiAgIDwvZGl2PgogIDwvZGl2PgogPC9kaXY+CgogPGRpdiBjbGFzcz1wYW5lbCBpZD1wLXNpbXM+
CiAgPGRpdiBjbGFzcz0iY2FyZCIgc3R5bGU9Im1hcmdpbi1ib3R0b206MTZweCI+CiAgIDxoMj5T
SU0tRGF0ZW4gZXJ6ZXVnZW48L2gyPgogICA8cCBjbGFzcz1zdWI+RsO8ciBlaWdlbmUgZVNJTS1Q
cm9maWxlICh6LiZuYnNwO0IuIHNpbWxlc3NseSk6IElNU0kgcGFzc2VuZCB6dXIgS2VubnVuZywg
enVmw6RsbGlnZSBTY2hsw7xzc2VsIChLaSwgT1Ag4oaSIE9QYyBuYWNoIE1pbGVuYWdlKSwgSUND
SUQgbWl0IFByw7xmemlmZmVyLCBQSU4vUFVLL0FETS4gQmxlaWJ0IG51ciBpbSBCcm93c2VyLCBi
aXMgZHUgZXMgw7xiZXJuaW1tc3QuPC9wPgogICA8ZGl2IGNsYXNzPXJvdzM+CiAgICA8ZGl2Pjxs
YWJlbD5BbnphaGwgKDHigJM1MCk8L2xhYmVsPjxpbnB1dCBpZD1nZW5fbiB0eXBlPW51bWJlciBt
aW49MSBtYXg9NTAgdmFsdWU9MT48L2Rpdj4KICAgIDxkaXY+PGxhYmVsPkVyc3RlIFJ1Zm51bW1l
ciAobGVlciA9IGtlaW5lKTwvbGFiZWw+PGlucHV0IGlkPWdlbl9uciBpbnB1dG1vZGU9bnVtZXJp
YyBwbGFjZWhvbGRlcj0iei4gQi4gOTIwMSI+PC9kaXY+CiAgICA8ZGl2PjxsYWJlbD5JQ0NJRC1Q
csOkZml4IChsZWVyID0gODkrTUNDK01OQyk8L2xhYmVsPjxpbnB1dCBpZD1nZW5faWNjaWQgaW5w
dXRtb2RlPW51bWVyaWM+PC9kaXY+CiAgIDwvZGl2PgogICA8ZGl2IHN0eWxlPWRpc3BsYXk6Zmxl
eDtnYXA6OHB4O2ZsZXgtd3JhcDp3cmFwPgogICAgPGJ1dHRvbiBjbGFzcz1idG4gb25jbGljaz0i
c2ltZ2VuKCkiPkVyemV1Z2VuPC9idXR0b24+CiAgICA8YnV0dG9uIGNsYXNzPSJidG4gc2VjIiBp
ZD1nZW5fdGFrZSBvbmNsaWNrPSJnZW50YWtlKCkiIGRpc2FibGVkPkFsbGUgaW4gcEtPTSDDvGJl
cm5laG1lbjwvYnV0dG9uPgogICAgPGJ1dHRvbiBjbGFzcz0iYnRuIHNlYyIgaWQ9Z2VuX2NzdiBv
bmNsaWNrPSJnZW5kbCgnY3N2JykiIGRpc2FibGVkPkNTVjwvYnV0dG9uPgogICAgPGJ1dHRvbiBj
bGFzcz0iYnRuIHNlYyIgaWQ9Z2VuX2pzb24gb25jbGljaz0iZ2VuZGwoJ2pzb24nKSIgZGlzYWJs
ZWQ+SlNPTjwvYnV0dG9uPgogICA8L2Rpdj4KICAgPGRpdiBjbGFzcz1nZW53cmFwPjx0YWJsZSBj
bGFzcz1lZiBpZD1nZW5fdGFiPjwvdGFibGU+PC9kaXY+CiAgIDxwIGNsYXNzPWhpbnQ+QU1GIDgw
MDAsIFNRTi1TdGFydCAwMDAwMDAwMDAwMjAsIEFsZ29yaXRobXVzIE1pbGVuYWdlLiBJbSBlU0lN
LVByb2ZpbCBkaWUgSU1TSSwgS2kgdW5kIE9QYyAob2RlciBPUCkgZWludHJhZ2VuOyBkYXp1IFNQ
Ti9QTk4vT1BMIGF1cyBkZW0gVGFiIOKAnlNJTS1Qcm9maWzigJwuPC9wPgogIDwvZGl2PgogIDxk
aXYgY2xhc3M9Z3JpZD4KICAgPGRpdiBjbGFzcz1jYXJkPgogICAgPGgyPlNJTSBlaW50cmFnZW48
L2gyPgogICAgPHAgY2xhc3M9c3ViPkVpbm1hbCBlaW50cmFnZW4g4oCTIHBLT00gc2NocmVpYnQg
c2llIGF1dG9tYXRpc2NoIGlucyBHU00tSExSIHVuZCBpbiBkZW4gTFRFLUhTUy48L3A+CiAgICA8
ZGl2IGNsYXNzPXJvdz48ZGl2PjxsYWJlbD5JTVNJPC9sYWJlbD48aW5wdXQgaWQ9c2ltX2ltc2kg
aW5wdXRtb2RlPW51bWVyaWM+PC9kaXY+PGRpdj48bGFiZWw+UnVmbnVtbWVyPC9sYWJlbD48aW5w
dXQgaWQ9c2ltX25yIGlucHV0bW9kZT1udW1lcmljPjwvZGl2PjwvZGl2PgogICAgPGRpdiBjbGFz
cz1yb3c+PGRpdj48bGFiZWw+S2kgKDMyIEhleCk8L2xhYmVsPjxpbnB1dCBpZD1zaW1fa2kgYXV0
b2NvbXBsZXRlPW9mZj48L2Rpdj48ZGl2PjxsYWJlbD5PUGMgKDMyIEhleCk8L2xhYmVsPjxpbnB1
dCBpZD1zaW1fb3BjIGF1dG9jb21wbGV0ZT1vZmY+PC9kaXY+PC9kaXY+CiAgICA8YnV0dG9uIGNs
YXNzPSJidG4gc20iIG9uY2xpY2s9InNpbWFkZCgpIj5TSU0gc3BlaWNoZXJuPC9idXR0b24+CiAg
ICA8ZGl2IHN0eWxlPW1hcmdpbi10b3A6MTJweCBpZD1zaW1zPjwvZGl2PgogICA8L2Rpdj4KICAg
PGRpdiBjbGFzcz1jYXJkPgogICAgPGgyPkVpbmdlYnVjaHRlIEhhbmR5czwvaDI+CiAgICA8cCBj
bGFzcz1zdWI+QWt0dWVsbCBpbSBTcHJhY2huZXR6IChNU0MpIGFuZ2VtZWxkZXQg4oCTIGJlaSDi
gJ5MVEUgKyBHU03igJwgYXVjaCDDvGJlciBMVEUvU0dzLjwvcD4KICAgIDxkaXYgaWQ9YXR0YWNo
ZWQ+PC9kaXY+CiAgIDwvZGl2PgogICA8ZGl2IGNsYXNzPWNhcmQ+CiAgICA8aDI+TnVtbWVyIGRh
dWVyaGFmdCB6dXdlaXNlbjwvaDI+CiAgICA8cCBjbGFzcz1zdWI+QXVjaCBmw7xyIG9mZmVuIGFu
Z2VtZWxkZXRlIEdTTS1TSU1zIG9obmUgS2kg4oCTIMO8YmVybGVidCBOZXVzdGFydHMuPC9wPgog
ICAgPGRpdiBjbGFzcz1yb3c+PGRpdj48bGFiZWw+SU1TSTwvbGFiZWw+PGlucHV0IGlkPWdudW1f
aW1zaT48L2Rpdj48ZGl2PjxsYWJlbD5SdWZudW1tZXI8L2xhYmVsPjxpbnB1dCBpZD1nbnVtX25y
PjwvZGl2PjwvZGl2PgogICAgPGJ1dHRvbiBjbGFzcz0iYnRuIHNtIiBvbmNsaWNrPSJzaW1ucigp
Ij5adXdlaXNlbjwvYnV0dG9uPgogICAgPGRpdiBzdHlsZT1tYXJnaW4tdG9wOjEycHggaWQ9Z3Nt
X251bWJlcnM+PC9kaXY+CiAgIDwvZGl2PgogIDwvZGl2PgogPC9kaXY+CgogPGRpdiBjbGFzcz1w
YW5lbCBpZD1wLXByb2ZpbD4KICA8ZGl2IGNsYXNzPWNhcmQ+CiAgIDxoMj5XZXJ0ZSBmw7xyIGRh
cyBlU0lNLVByb2ZpbDwvaDI+CiAgIDxwIGNsYXNzPXN1Yj5PUEwsIFBOTiB1bmQgU1BOIHNpbmQg
RGF0ZWllbiA8Yj5hdWYgZGVyIFNJTTwvYj4g4oCTIGRhcyBOZXR6IGthbm4gc2llIG5pY2h0IHNl
dHplbi4gRGllc2UgV2VydGUgcGFzc2VuIHp1IEtlbm51bmcgdW5kIE5ldHpuYW1lIG9iZW4gdW5k
IHdlcmRlbiBpbSBlU0lNLVByb2ZpbCAoei4mbmJzcDtCLiBzaW1sZXNzbHkpIGVpbmdldHJhZ2Vu
LiBOSVRaIHNjaGlja3QgcEtPTSBzZWxic3QuPC9wPgogICA8dGFibGUgY2xhc3M9ZWY+CiAgICA8
dHI+PHRoPkRhdGVpPC90aD48dGg+SW5oYWx0PC90aD48dGg+V2VydCAoSGV4KTwvdGg+PC90cj4K
ICAgIDx0cj48dGQ+PGI+U1BOPC9iPjxicj48c3BhbiBjbGFzcz1tdXQ+RUYgNkY0Njwvc3Bhbj48
L3RkPjx0ZCBpZD1lZl9zcG5fdD48L3RkPjx0ZD48Y29kZSBpZD1lZl9zcG4+PC9jb2RlPjwvdGQ+
PC90cj4KICAgIDx0cj48dGQ+PGI+UE5OPC9iPjxicj48c3BhbiBjbGFzcz1tdXQ+RUYgNkZDNSwg
RWludHJhZyAxPC9zcGFuPjwvdGQ+PHRkIGlkPWVmX3Bubl90PjwvdGQ+PHRkPjxjb2RlIGlkPWVm
X3Bubj48L2NvZGU+PC90ZD48L3RyPgogICAgPHRyPjx0ZD48Yj5PUEw8L2I+PGJyPjxzcGFuIGNs
YXNzPW11dD5FRiA2RkM2LCBFaW50cmFnIDE8L3NwYW4+PC90ZD48dGQgaWQ9ZWZfb3BsX3Q+PC90
ZD48dGQ+PGNvZGUgaWQ9ZWZfb3BsPjwvY29kZT48L3RkPjwvdHI+CiAgICA8dHI+PHRkPjxiPkhQ
TE1OPC9iPjxicj48c3BhbiBjbGFzcz1tdXQ+SU1TSS1BbmZhbmc8L3NwYW4+PC90ZD48dGQ+SGVp
bW5ldHotS2VubnVuZzwvdGQ+PHRkPjxjb2RlIGlkPWVmX2hwbG1uPjwvY29kZT48L3RkPjwvdHI+
CiAgIDwvdGFibGU+CiAgIDxwIGNsYXNzPWhpbnQ+RGF0ZW5zw6R0emUgYmVpIGZlc3RlciBMw6Ru
Z2UgbWl0IDxjb2RlPkZGPC9jb2RlPiBhdWZmw7xsbGVuLiBJbiBkZXIgVVNJTS1EaWVuc3R0YWJl
bGxlIChVU1QpIG3DvHNzZW4gZGllIERpZW5zdGUgPGI+MTc8L2I+IChTUE4pLCA8Yj40NTwvYj4g
KFBOTikgdW5kIDxiPjQ2PC9iPiAoT1BMKSBha3RpdiBzZWluLiDDhG5kZXJuIHNpY2ggS2VubnVu
ZyBvZGVyIE5hbWUsIGRpZSBXZXJ0ZSBoaWVyIG5ldSDDvGJlcm5laG1lbi48L3A+CiAgPC9kaXY+
CiA8L2Rpdj4KCiA8ZGl2IGNsYXNzPXBhbmVsIGlkPXAtbG9nPgogIDxkaXYgY2xhc3M9Y2FyZD4K
ICAgPGRpdiBjbGFzcz10b29sYmFyPjxoMiBzdHlsZT1tYXJnaW46MD5Qcm90b2tvbGw8L2gyPjxp
bnB1dCBpZD1sb2dmaWx0ZXIgcGxhY2Vob2xkZXI9ImZpbHRlcm7igKYgei5CLiBHUFJTLCBUQkYs
IGVycm9yIiBvbmlucHV0PXJlbmRlcmxvZygpPjxzcGFuIGNsYXNzPWJhZGdlIGlkPWxvZ2NvdW50
Pjwvc3Bhbj48L2Rpdj4KICAgPGRpdiBjbGFzcz1sb2cgaWQ9bG9nPjwvZGl2PgogIDwvZGl2Pgog
PC9kaXY+CjwvZGl2Pgo8c2NyaXB0PgpsZXQgUz17fTsKYXN5bmMgZnVuY3Rpb24gYXBpKGMsYil7
Y29uc3Qgcj1hd2FpdCBmZXRjaCgnL2FwaS8nK2Mse21ldGhvZDonUE9TVCcsaGVhZGVyczp7J0Nv
bnRlbnQtVHlwZSc6J2FwcGxpY2F0aW9uL2pzb24nfSxib2R5OkpTT04uc3RyaW5naWZ5KGJ8fHt9
KX0pO3JldHVybiByLmpzb24oKTt9CmZ1bmN0aW9uICQoaSl7cmV0dXJuIGRvY3VtZW50LmdldEVs
ZW1lbnRCeUlkKGkpO30KZnVuY3Rpb24gZXNjKHMpe3JldHVybiBTdHJpbmcocz09bnVsbD8nJzpz
KS5yZXBsYWNlKC9bJjw+IiddL2csYz0+KHsnJic6JyZhbXA7JywnPCc6JyZsdDsnLCc+JzonJmd0
OycsJyInOicmcXVvdDsnLCInIjonJiMzOTsnfVtjXSkpO30KZnVuY3Rpb24gY21kKGMpe2lmKGMu
c3RhcnRzV2l0aCgnc3RhcnQnKSkkKCdtc2cnKS50ZXh0Q29udGVudD0nc3RhcnRldOKApic7YXBp
KGMpLnRoZW4ocj0+e2lmKGM9PT0nbGltZV9zY2FuJylsaW1lS2V5PScnO3JlbmRlcihyKTt9KTt9
CmZ1bmN0aW9uIHRhYihuKXtkb2N1bWVudC5xdWVyeVNlbGVjdG9yQWxsKCcudGFiJykuZm9yRWFj
aCh0PT50LmNsYXNzTGlzdC50b2dnbGUoJ3NlbCcsdC5kYXRhc2V0LnQ9PT1uKSk7ZG9jdW1lbnQu
cXVlcnlTZWxlY3RvckFsbCgnLnBhbmVsJykuZm9yRWFjaChwPT5wLmNsYXNzTGlzdC50b2dnbGUo
J3NlbCcscC5pZD09PSdwLScrbikpO3RyeXtsb2NhbFN0b3JhZ2Uuc2V0SXRlbSgncGtvbV90YWIn
LG4pO31jYXRjaChlKXt9fQpmdW5jdGlvbiBzYXZlKGtleXMpe2xldCBiPXt9O2tleXMuZm9yRWFj
aChrPT57bGV0IGVsPSQoayk7YltrXT1lbC50eXBlPT09J2NoZWNrYm94Jz8oZWwuY2hlY2tlZD8n
MSc6JzAnKTplbC52YWx1ZTt9KTthcGkoJ3NldCcsYikudGhlbihyPT57ZmlsbGVkPWZhbHNlO3Jl
bmRlcihyKTt9KTt9CmZ1bmN0aW9uIHNpbWFkZCgpe2FwaSgnc2ltX2FkZCcse2ltc2k6JCgnc2lt
X2ltc2knKS52YWx1ZSxraTokKCdzaW1fa2knKS52YWx1ZSxvcGM6JCgnc2ltX29wYycpLnZhbHVl
LG1zaXNkbjokKCdzaW1fbnInKS52YWx1ZX0pLnRoZW4ocj0+e2lmKCEvYWJlcnxwcnVlZmVuLy50
ZXN0KHIubXNnfHwnJykpe1snc2ltX2ltc2knLCdzaW1fa2knLCdzaW1fb3BjJywnc2ltX25yJ10u
Zm9yRWFjaChpPT4kKGkpLnZhbHVlPScnKTt9cmVuZGVyKHIpO30pO30KZnVuY3Rpb24gc2ltbnIo
KXthcGkoJ2dzbV9zaW1fbnInLHtpbXNpOiQoJ2dudW1faW1zaScpLnZhbHVlLG1zaXNkbjokKCdn
bnVtX25yJykudmFsdWV9KS50aGVuKHJlbmRlcik7fQpmdW5jdGlvbiBzbXN0ZXN0KCl7YXBpKCdz
bXNfdGVzdCcse2ltc2k6JCgnc21zX3Rlc3RfaW1zaScpLnZhbHVlLHRleHQ6JCgnc21zX3Rlc3Rf
dGV4dCcpLnZhbHVlfSkudGhlbihyZW5kZXIpO30KZnVuY3Rpb24gc2ltZGVsKGkpe2lmKGNvbmZp
cm0oJ1NJTSAnK2krJyBhdXMgR1NNIHVuZCBMVEUgbMO2c2NoZW4/JykpYXBpKCdzaW1fZGVsJyx7
aW1zaTppfSkudGhlbihyZW5kZXIpO30KZnVuY3Rpb24gbnVtZGVsKGkpe2FwaSgnZ3NtX251bV9k
ZWwnLHtpbXNpOml9KS50aGVuKHJlbmRlcik7fQpmdW5jdGlvbiBnc21JbmZvKGEpe2E9K2F8fDA7
bGV0IG09MCxiPScnO2lmKGE+PTEmJmE8PTEyNCl7bT05MzUrMC4yKmE7Yj0nR1NNOTAwJzt9ZWxz
ZSBpZihhPj01MTImJmE8PTg4NSl7bT0xODA1LjIrMC4yKihhLTUxMik7Yj0nRENTMTgwMCc7fXJl
dHVybnttaHo6bT9tLnRvRml4ZWQoMSkrJyBNSHonOifigJMnLGJhbmQ6Yn07fQpmdW5jdGlvbiBs
dGVJbmZvKGUpe2U9K2V8fDA7bGV0IG09MCxiPTA7aWYoZT49MCYmZTw9NTk5KXttPTIxMTArMC4x
KmU7Yj0xO31lbHNlIGlmKGU+PTEyMDAmJmU8PTE5NDkpe209MTgwNSswLjEqKGUtMTIwMCk7Yj0z
O31lbHNlIGlmKGU+PTI3NTAmJmU8PTM0NDkpe209MjYyMCswLjEqKGUtMjc1MCk7Yj03O31lbHNl
IGlmKGU+PTYxNTAmJmU8PTY0NDkpe209NzkxKzAuMSooZS02MTUwKTtiPTIwO31yZXR1cm57bWh6
Om0/bS50b0ZpeGVkKDEpKycgTUh6Jzon4oCTJyxiYW5kOmI/J0JhbmQgJytiOicnfTt9CmZ1bmN0
aW9uIHVwZGF0ZUZyZXEoKXtsZXQgZz1nc21JbmZvKCQoJ0dTTV9BUkZDTicpLnZhbHVlKTskKCdn
c21fbWh6JykudGV4dENvbnRlbnQ9Zy5taHo7JCgnZ3NtX2JhbmQnKS50ZXh0Q29udGVudD1nLmJh
bmQ7bGV0IGw9bHRlSW5mbygkKCdMVEVfRUFSRkNOJykudmFsdWUpOyQoJ2x0ZV9taHonKS50ZXh0
Q29udGVudD1sLm1oejskKCdsdGVfYmFuZCcpLnRleHRDb250ZW50PWwuYmFuZDt9CmZ1bmN0aW9u
IHNldHYoaWQsdil7bGV0IGVsPSQoaWQpO2lmKCFlbClyZXR1cm47aWYoZWwudHlwZT09PSdjaGVj
a2JveCcpZWwuY2hlY2tlZD0odj09PScxJ3x8dj09PXRydWUpO2Vsc2UgZWwudmFsdWU9KHY9PW51
bGw/Jyc6dik7fQpjb25zdCBGSUVMRFM9WydNQ0MnLCdNTkMnLCdORVROQU1FJywnTkVUTkFNRV9T
SE9SVCcsJ1NQTicsJ05JVFonLCdHU01fREVWJywnTFRFX0RFVicsJ0dTTV9BUkZDTicsJ0dTTV9U
WF9HQUlOJywnR1NNX1JYX0dBSU4nLCdHU01fU0lQX1BFRVInLCdHU01fU0lQX0xPQ0FMJywnR1NN
X09QRU4nLCdHU01fREFUQScsJ0dTTV9TSVAnLCdHU01fU01TJywnR1NNX1NNU19GUk9NJywnR1NN
X1NNU19FWFRQUkVGSVgnLCdHU01fU01TX1dFTENPTUUnLCdHU01fU01TX05VTUJFUicsJ0xURV9F
QVJGQ04nLCdMVEVfTlBSQicsJ0xURV9UWF9HQUlOJywnTFRFX1JYX0dBSU4nLCdMVEVfQVBOJ107
CmxldCBmaWxsZWQ9ZmFsc2UsbGltZUtleT0nJzsKZnVuY3Rpb24gbGltZU9wdGlvbnMocyl7CiBj
b25zdCBMPXMubGltZXN8fFtdLGM9cy5jb25mfHx7fSxrZXk9SlNPTi5zdHJpbmdpZnkoTCkrKGMu
R1NNX0RFVnx8JycpKyhjLkxURV9ERVZ8fCcnKTsKIGlmKGtleT09PWxpbWVLZXkpcmV0dXJuO2xp
bWVLZXk9a2V5OwogWydHU01fREVWJywnTFRFX0RFViddLmZvckVhY2goaWQ9Pntjb25zdCBlbD0k
KGlkKSxjdXI9Y1tpZF18fCcnOwogIGxldCBvPSc8b3B0aW9uIHZhbHVlPSIiPmF1dG9tYXRpc2No
PC9vcHRpb24+JytMLm1hcChkPT4nPG9wdGlvbiB2YWx1ZT0iJytlc2MoZC5zZXJpYWwpKyciPicr
ZXNjKGQubmFtZSkrJyDCtyAnK2VzYyhkLnNlcmlhbCkrKGQubWVkaWE/JyDCtyAnK2VzYyhkLm1l
ZGlhKTonJykrJzwvb3B0aW9uPicpLmpvaW4oJycpOwogIGlmKGN1ciYmIUwuc29tZShkPT5kLnNl
cmlhbD09PWN1cikpbys9JzxvcHRpb24gdmFsdWU9IicrZXNjKGN1cikrJyI+Jytlc2MoY3VyKSsn
IChuaWNodCBnZWZ1bmRlbik8L29wdGlvbj4nOwogIGVsLmlubmVySFRNTD1vO2VsLnZhbHVlPWN1
cjt9KTsKICQoJ2xpbWVsaXN0JykudGV4dENvbnRlbnQ9TC5sZW5ndGg/TC5sZW5ndGgrJyBMaW1l
U0RSIGFuZ2VzY2hsb3NzZW4nOidLZWluIExpbWVTRFIgZ2VmdW5kZW4g4oCTIFVTQiBwcsO8ZmVu
IHVuZCDigJ5OZXUgc3VjaGVu4oCcLic7Cn0KZnVuY3Rpb24gcmVsb2FkRmllbGRzKCl7Y29uc3Qg
Yz1TLmNvbmZ8fHt9O0ZJRUxEUy5mb3JFYWNoKGs9PntpZihkb2N1bWVudC5hY3RpdmVFbGVtZW50
IT09JChrKSlzZXR2KGssY1trXSk7fSk7ZmlsbGVkPXRydWU7dXBkYXRlRnJlcSgpO30KZnVuY3Rp
b24gZm10KHMpe2NvbnN0IG09TWF0aC5mbG9vcihzLzYwKSxoPU1hdGguZmxvb3IobS82MCk7cmV0
dXJuIGg/aCsnaCAnKyhtJTYwKSsnbSc6KG0/bSsnbSAnKyhzJTYwKSsncyc6cysncycpO30KZnVu
Y3Rpb24gcmVuZGVybG9nKCl7Y29uc3QgZj0oJCgnbG9nZmlsdGVyJykudmFsdWV8fCcnKS50b0xv
d2VyQ2FzZSgpO2xldCBMPShTLmxvZ3x8W10pO2lmKGYpTD1MLmZpbHRlcih4PT54LnRvTG93ZXJD
YXNlKCkuaW5jbHVkZXMoZikpO2NvbnN0IGxnPSQoJ2xvZycpO2NvbnN0IG5lYXI9bGcuc2Nyb2xs
VG9wK2xnLmNsaWVudEhlaWdodD49bGcuc2Nyb2xsSGVpZ2h0LTQwO2xnLnRleHRDb250ZW50PUwu
am9pbignXG4nKTskKCdsb2djb3VudCcpLnRleHRDb250ZW50PUwubGVuZ3RoKycgWmVpbGVuJztp
ZihuZWFyKWxnLnNjcm9sbFRvcD1sZy5zY3JvbGxIZWlnaHQ7fQpmdW5jdGlvbiByZW5kZXIocyl7
Uz1zO2xpbWVPcHRpb25zKHMpO2lmKCFmaWxsZWQpcmVsb2FkRmllbGRzKCk7CiBjb25zdCBydW49
cy5zdGF0ZT09PSdsYWV1ZnQnLHQ9cy50ZWNoOwogJCgnZG90JykuY2xhc3NOYW1lPSdkb3QgJyso
cnVuPydvbic6KHMuc3RhdGU9PT0nZmVobGVyJz8nZXJyJzonJykpOwogJCgnc3RhdGUnKS50ZXh0
Q29udGVudD1zLnN0YXRlOyQoJ21zZycpLnRleHRDb250ZW50PXMubXNnfHwnJzsKIGNvbnN0IHRi
PSQoJ3RlY2hiYWRnZScpO2lmKHQpe3RiLnN0eWxlLmRpc3BsYXk9Jyc7dGIudGV4dENvbnRlbnQ9
dD09PSdjc2ZiJz8nTFRFK0dTTSc6dC50b1VwcGVyQ2FzZSgpO31lbHNlIHRiLnN0eWxlLmRpc3Bs
YXk9J25vbmUnOwogbGV0IGZyZXE9J+KAkycsZnN1Yj0nJzsKIGNvbnN0IGdmPXMuZ3NtLm1oeisn
IE1IeicsbGY9cy5sdGUubWh6KycgTUh6JzsKIGlmKHQ9PT0nbHRlJyl7ZnJlcT1sZjtmc3ViPSdC
YW5kICcrcy5sdGUuYmFuZCsnIMK3IEVBUkZDTiAnK3MubHRlLmVhcmZjbjt9CiBlbHNlIGlmKHQ9
PT0nZ3NtJyl7ZnJlcT1nZjtmc3ViPXMuZ3NtLmJhbmQrJyDCtyBBUkZDTiAnK3MuZ3NtLmFyZmNu
O30KIGVsc2UgaWYodD09PSdjc2ZiJyl7ZnJlcT1sZisnIC8gJytnZjtmc3ViPSdMVEUgQicrcy5s
dGUuYmFuZCsnIMK3IEdTTSBBUkZDTiAnK3MuZ3NtLmFyZmNuO30KICQoJ2ZyZXEnKS50ZXh0Q29u
dGVudD1mcmVxOyQoJ2ZyZXEyJykudGV4dENvbnRlbnQ9ZnJlcTskKCdmcmVxc3ViJykudGV4dENv
bnRlbnQ9ZnN1YjsKICQoJ3RlY2gyJykudGV4dENvbnRlbnQ9dD8odD09PSdjc2ZiJz8nTFRFK0dT
TSc6dC50b1VwcGVyQ2FzZSgpKTonYXVzJzskKCdzdGF0ZXN1YicpLnRleHRDb250ZW50PXMuc3Rh
dGU7CiAkKCd1cHRpbWUnKS50ZXh0Q29udGVudD1zLnVwdGltZT9mbXQocy51cHRpbWUpOifigJMn
OyQoJ3VwdGltZWhpbnQnKS50ZXh0Q29udGVudD1ydW4/KCdsw6R1ZnQgc2VpdCAnK2ZtdChzLnVw
dGltZSkpOicnOwogJCgnZGV2aGludCcpLmlubmVySFRNTD1bcy5kZXYuZ3NtPydHU00tRnVuazog
PGI+Jytlc2Mocy5kZXYuZ3NtKSsnPC9iPic6Jycscy5kZXYubHRlPydMVEUtRnVuazogPGI+Jytl
c2Mocy5kZXYubHRlKSsnPC9iPic6JyddLmZpbHRlcihCb29sZWFuKS5qb2luKCc8YnI+Jyk7CiAk
KCdjbGFzaCcpLnRleHRDb250ZW50PXMuY2xhc2h8fCcnOwogW1snZ3NtJywnT3Ntb2NvbSddLFsn
bHRlJywnc3JzUkFOICsgT3BlbjVHUyddLFsnY3NmYicsJ0ludGVybmV0ICsgQW5ydWZlIChDU0ZC
KSddXS5mb3JFYWNoKChbayxkXSk9PnskKCdidG5fJytrKS5jbGFzc0xpc3QudG9nZ2xlKCdhY3Rp
dmUnLHQ9PT1rKTskKGsrJ19zdWInKS50ZXh0Q29udGVudD10PT09az8nbMOkdWZ0JzpkO30pOwog
JCgndHonKS50ZXh0Q29udGVudD1zLnR6fHwn4oCTJzsKIGNvbnN0IGY9cy5zaW1maWxlc3x8e307
JCgnaHBsbW4nKS50ZXh0Q29udGVudD1mLmhwbG1ufHwn4oCTJzsKICQoJ2VmX3NwbicpLnRleHRD
b250ZW50PWYuc3BufHwnJzskKCdlZl9zcG5fdCcpLnRleHRDb250ZW50PSfigJ4nKyhmLnNwbl90
ZXh0fHwnJykrJ+KAnCc7CiAkKCdlZl9wbm4nKS50ZXh0Q29udGVudD1mLnBubnx8Jyc7JCgnZWZf
cG5uX3QnKS50ZXh0Q29udGVudD0nbGFuZyDigJ4nKyhmLmZ1bGx8fCcnKSsn4oCcLCBrdXJ6IOKA
nicrKGYuc2hvcnR8fCcnKSsn4oCcJzsKICQoJ2VmX29wbCcpLnRleHRDb250ZW50PWYub3BsfHwn
JzskKCdlZl9vcGxfdCcpLnRleHRDb250ZW50PSdLZW5udW5nICcrKGYuaHBsbW58fCcnKSsnLCBh
bGxlIEdlYmlldGUg4oaSIFBOTiAxJzsKICQoJ2VmX2hwbG1uJykudGV4dENvbnRlbnQ9Zi5ocGxt
bnx8Jyc7CiAkKCdnc21fbnVtYmVycycpLmlubmVySFRNTD1PYmplY3QuZW50cmllcyhzLmdzbS5u
dW1iZXJzfHx7fSkubWFwKGU9Pic8ZGl2IGNsYXNzPWxpc3Ryb3c+PHNwYW4gY2xhc3M9dGFnPicr
ZXNjKGVbMF0pKycg4oaSIDxiPicrZXNjKGVbMV0pKyc8L2I+PC9zcGFuPjxidXR0b24gY2xhc3M9
eCBvbmNsaWNrPSJudW1kZWwoXCcnK2VzYyhlWzBdKSsnXCcpIj5sw7ZzY2hlbjwvYnV0dG9uPjwv
ZGl2PicpLmpvaW4oJycpfHwnPGRpdiBjbGFzcz1lbXB0eT5rZWluZSBadXdlaXN1bmdlbjwvZGl2
Pic7CiAkKCdhdHRhY2hlZCcpLmlubmVySFRNTD0ocy5nc20uYXR0YWNoZWR8fFtdKS5tYXAoaT0+
JzxkaXYgY2xhc3M9bGlzdHJvdz48c3BhbiBjbGFzcz10YWc+Jytlc2MoaSkrJzwvc3Bhbj48c3Bh
biBjbGFzcz10YWc+Jytlc2MoKHMuZ3NtLm51bWJlcnN8fHt9KVtpXXx8JycpKyc8L3NwYW4+PC9k
aXY+Jykuam9pbignJyl8fCc8ZGl2IGNsYXNzPWVtcHR5PmtlaW5lIGVpbmdlYnVjaHQ8L2Rpdj4n
OwogJCgnc2ltcycpLmlubmVySFRNTD0ocy5zaW1zfHxbXSkubWFwKHg9Pic8ZGl2IGNsYXNzPWxp
c3Ryb3c+PHNwYW4gY2xhc3M9dGFnPicrZXNjKHguaW1zaSkrJyDCtyA8Yj4nK2VzYyh4Lm1zaXNk
bikrJzwvYj48L3NwYW4+PGJ1dHRvbiBjbGFzcz14IG9uY2xpY2s9InNpbWRlbChcJycrZXNjKHgu
aW1zaSkrJ1wnKSI+bMO2c2NoZW48L2J1dHRvbj48L2Rpdj4nKS5qb2luKCcnKXx8JzxkaXYgY2xh
c3M9ZW1wdHk+bm9jaCBrZWluZSBTSU0gZWluZ2V0cmFnZW48L2Rpdj4nOwogcmVuZGVyUGFydHMo
cyk7CiByZW5kZXJsb2coKTsKfQpsZXQgcGFydEtleT0nJzsKZnVuY3Rpb24gcmVzdGFydChwLGxh
YmVsKXtpZihTLmJ1c3kpcmV0dXJuO2lmKCFjb25maXJtKChsYWJlbHx8cCkrJyBuZXUgc3RhcnRl
bj8nKSlyZXR1cm47JCgnbXNnJykudGV4dENvbnRlbnQ9KGxhYmVsfHxwKSsnIHN0YXJ0ZXQgbmV1
4oCmJzthcGkoJ3Jlc3RhcnQnLHtwYXJ0OnB9KS50aGVuKHJlbmRlcik7fQpmdW5jdGlvbiByZW5k
ZXJQYXJ0cyhzKXtjb25zdCBQPXMucGFydHN8fFtdLEw9cy5wcm9jc3x8W10sa2V5PUpTT04uc3Ry
aW5naWZ5KFtQLEwubWFwKHg9Plt4LnRhZyx4LnJ1bl0pLHMuYnVzeV0pO2lmKGtleT09PXBhcnRL
ZXkpcmV0dXJuO3BhcnRLZXk9a2V5OwogJCgncGFydHMnKS5pbm5lckhUTUw9UC5tYXAoeD0+Jzxi
dXR0b24gY2xhc3M9ImJ0biBzZWMiICcrKHMuYnVzeT8nZGlzYWJsZWQnOicnKSsnIG9uY2xpY2s9
InJlc3RhcnQoXCcnK3guaWQrJ1wnLFwnJytlc2MoeC5uYW1lKSsnXCcpIj7ihrsgJytlc2MoeC5u
YW1lKSsnPC9idXR0b24+Jykuam9pbignJyk7CiAkKCdwcm9jcycpLmlubmVySFRNTD1MLm1hcCh4
PT4nPGRpdiBjbGFzcz1wcm9jIHRpdGxlPSInK2VzYyh4Lmdyb3VwLnRvVXBwZXJDYXNlKCkpKyh4
LnJ1bj8nIMK3IGzDpHVmdCc6JyDCtyBiZWVuZGV0IChDb2RlICcrZXNjKHgucmMpKycpJykrJyI+
PGkgY2xhc3M9InBkJysoeC5ydW4/JyBvbic6JycpKyciPjwvaT48c3Bhbj4nK2VzYyh4LnRhZykr
Jzwvc3Bhbj48YnV0dG9uICcrKHMuYnVzeT8nZGlzYWJsZWQnOicnKSsnIG9uY2xpY2s9InJlc3Rh
cnQoXCcnK2VzYyh4LnRhZykrJ1wnKSIgYXJpYS1sYWJlbD0iJytlc2MoeC50YWcpKycgbmV1IHN0
YXJ0ZW4iPuKGuzwvYnV0dG9uPjwvZGl2PicpLmpvaW4oJycpOwogJCgncGFydGhpbnQnKS50ZXh0
Q29udGVudD1zLmJ1c3k/KCdOZXVzdGFydCBsw6R1ZnQ6ICcrcy5idXN5KTooUC5sZW5ndGg/J0dy
w7xuID0gbMOkdWZ0LCByb3QgPSBiZWVuZGV0LiDihrsgc3RhcnRldCBudXIgZGllc2VuIFByb3pl
c3MgbmV1Lic6J1N0YXJ0ZXQsIHNvYmFsZCBlaW4gTmV0eiBsw6R1ZnQuJyk7fQpsZXQgR0VOPVtd
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
