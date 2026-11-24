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
ZSh0KQogICAgc2liID0gb3MucGF0aC5qb2luKFdPUktESVIsICJzaWIuY29uZiIpCiAgICBvcGVu
KHNpYiwgInciKS53cml0ZShzaWJfcGF0Y2gob3BlbihzaWIpLnJlYWQoKSwgY3NmYiwgaW50KENb
IkdTTV9BUkZDTiJdKSkpCiAgICBkZXYgPSAiZHJpdmVyPWxpbWUiICsgKCIsc2VyaWFsPSIgKyBz
ZXJpYWwgaWYgc2VyaWFsIGVsc2UgIiIpCiAgICBvcGVuKG9zLnBhdGguam9pbihXT1JLRElSLCAi
ZW5iLmNvbmYiKSwgInciKS53cml0ZShmIiIiIyBwS09NIC0gYXV0b21hdGlzY2ggZXJ6ZXVndApb
ZW5iXQplbmJfaWQgPSAweDE5QgptY2MgPSB7Q1snTUNDJ119Cm1uYyA9IHtDWydNTkMnXX0KbW1l
X2FkZHIgPSAxMjcuMC4wLjIKZ3RwX2JpbmRfYWRkciA9IDEyNy4wLjEuMQpzMWNfYmluZF9hZGRy
ID0gMTI3LjAuMS4xCnMxY19iaW5kX3BvcnQgPSAwCm5fcHJiID0ge2ludChDWydMVEVfTlBSQidd
KX0KCltlbmJfZmlsZXNdCnNpYl9jb25maWcgPSB7c2lifQpycl9jb25maWcgPSB7cnJ9CnJiX2Nv
bmZpZyA9IHtvcy5wYXRoLmpvaW4oV09SS0RJUiwgJ3JiLmNvbmYnKX0KCltyZl0KdHhfZ2FpbiA9
IHtDWydMVEVfVFhfR0FJTiddfQpyeF9nYWluID0ge0NbJ0xURV9SWF9HQUlOJ119CmRldmljZV9u
YW1lID0gc29hcHkKZGV2aWNlX2FyZ3MgPSB7ZGV2fQoKW2xvZ10KYWxsX2xldmVsID0gd2Fybmlu
ZwpmaWxlbmFtZSA9IHN0ZG91dAoiIiIpCgpkZWYgX3J1bigqY21kKToKICAgIHJldHVybiBzdWJw
cm9jZXNzLnJ1bihsaXN0KGNtZCksIHN0ZG91dD1zdWJwcm9jZXNzLkRFVk5VTEwsIHN0ZGVycj1z
dWJwcm9jZXNzLkRFVk5VTEwpLnJldHVybmNvZGUKCmRlZiB1ZV9uZXRfdXAoKToKICAgICIiIlR1
bm5lbCBmdWVyIGRpZSBIYW5keS1EYXRlbnZlcmJpbmR1bmdlbiArIE5BVCBpbnMgSW50ZXJuZXQu
IiIiCiAgICBfcnVuKCJtb2Rwcm9iZSIsICJzY3RwIikKICAgIF9ydW4oImlwIiwgInR1bnRhcCIs
ICJhZGQiLCAibmFtZSIsICJvZ3N0dW4iLCAibW9kZSIsICJ0dW4iKQogICAgX3J1bigiaXAiLCAi
YWRkciIsICJyZXBsYWNlIiwgVUVfR1csICJkZXYiLCAib2dzdHVuIikKICAgIF9ydW4oImlwIiwg
ImxpbmsiLCAic2V0IiwgIm9nc3R1biIsICJ1cCIpCiAgICBfcnVuKCJzeXNjdGwiLCAiLXciLCAi
bmV0LmlwdjQuaXBfZm9yd2FyZD0xIikKICAgIGZvciBjaGssIGFkZCBpbiAoKFsiLXQiLCAibmF0
IiwgIi1DIiwgIlBPU1RST1VUSU5HIiwgIi1zIiwgVUVfTkVULCAiISIsICItbyIsICJvZ3N0dW4i
LCAiLWoiLCAiTUFTUVVFUkFERSJdLAogICAgICAgICAgICAgICAgICAgICAgWyItdCIsICJuYXQi
LCAiLUEiLCAiUE9TVFJPVVRJTkciLCAiLXMiLCBVRV9ORVQsICIhIiwgIi1vIiwgIm9nc3R1biIs
ICItaiIsICJNQVNRVUVSQURFIl0pLAogICAgICAgICAgICAgICAgICAgICAoWyItQyIsICJGT1JX
QVJEIiwgIi1pIiwgIm9nc3R1biIsICItaiIsICJBQ0NFUFQiXSwgWyItSSIsICJGT1JXQVJEIiwg
Ii1pIiwgIm9nc3R1biIsICItaiIsICJBQ0NFUFQiXSksCiAgICAgICAgICAgICAgICAgICAgIChb
Ii1DIiwgIkZPUldBUkQiLCAiLW8iLCAib2dzdHVuIiwgIi1qIiwgIkFDQ0VQVCJdLCBbIi1JIiwg
IkZPUldBUkQiLCAiLW8iLCAib2dzdHVuIiwgIi1qIiwgIkFDQ0VQVCJdKSk6CiAgICAgICAgaWYg
X3J1bigiaXB0YWJsZXMiLCAqY2hrKSAhPSAwOiBfcnVuKCJpcHRhYmxlcyIsICphZGQpCgpkZWYg
ZnJlcV9jbGFzaCgpOgogICAgIiIiR1NNLVRyYWVnZXIgZGFyZiBuaWNodCBpbSBMVEUtS2FuYWwg
bGllZ2VuIChnbGVpY2hlcyBCYW5kIDE4MDAgTUh6KS4iIiIKICAgIHRyeToKICAgICAgICBnID0g
YXJmY25fbWh6KGludChDWyJHU01fQVJGQ04iXSkpOyBsID0gZWFyZmNuX21oeihpbnQoQ1siTFRF
X0VBUkZDTiJdKSkKICAgICAgICBidyA9IE5QUkJfTUhaLmdldChpbnQoQ1siTFRFX05QUkIiXSks
IDUpCiAgICAgICAgaWYgZyBhbmQgbCBhbmQgYWJzKGcgLSBsKSA8IGJ3IC8gMiArIDAuMzoKICAg
ICAgICAgICAgcmV0dXJuIGYiR1NNIHtnfSBNSHogbGllZ3QgaW0gTFRFLUthbmFsIHtsfSBNSHog
wrF7YncvMjpnfSAtIGFuZGVyZSBBUkZDTi9FQVJGQ04gd2FlaGxlbiIKICAgIGV4Y2VwdCBFeGNl
cHRpb246IHBhc3MKICAgIHJldHVybiBOb25lCgpkZWYgcHJlZmxpZ2h0KG1vZGUpOgogICAgbWNj
LCBtbmMgPSBDLmdldCgiTUNDIiwgIiIpLnN0cmlwKCksIEMuZ2V0KCJNTkMiLCAiIikuc3RyaXAo
KQogICAgaWYgbm90IHJlLmZ1bGxtYXRjaChyIlxkezN9IiwgbWNjKSBvciBub3QgcmUuZnVsbG1h
dGNoKHIiXGR7MiwzfSIsIG1uYyk6CiAgICAgICAgcmV0dXJuICJOZXR6a2VubnVuZyBwcnVlZmVu
OiBNQ0MgMyBaaWZmZXJuLCBNTkMgMi0zIFppZmZlcm4iCiAgICBpZiBtY2Mgbm90IGluICgiMDAx
IiwgIjk5OSIpOgogICAgICAgIHJldHVybiAiTnVyIFRlc3QtL1ByaXZhdGtlbm51bmdlbjogTUND
IDAwMSAoVGVzdCkgb2RlciA5OTkgKHByaXZhdCkiCiAgICBnLCBsID0gbGltZV9hc3NpZ24obW9k
ZSkKICAgIGlmIG1vZGUgPT0gImNzZmIiOgogICAgICAgIGlmIG5vdCBGQUtFIGFuZCAobm90IGcg
b3Igbm90IGwgb3IgZyA9PSBsKToKICAgICAgICAgICAgcmV0dXJuICJMVEUgKyBHU00gYnJhdWNo
dCB6d2VpIHZlcnNjaGllZGVuZSBMaW1lU0RSIC0gaW0gVGFiIFN0ZXVlcnVuZyB6dW9yZG5lbiIK
ICAgICAgICBlID0gZnJlcV9jbGFzaCgpCiAgICAgICAgaWYgZTogcmV0dXJuIGUKICAgIGlmIG5v
dCBGQUtFOgogICAgICAgIG5lZWQgPSBbXQogICAgICAgIGlmIG1vZGUgaW4gKCJnc20iLCAiY3Nm
YiIpOiBuZWVkICs9IFtiIGZvciBfbiwgYiwgX2MgaW4gR1NNX0NPUkVdCiAgICAgICAgaWYgbW9k
ZSBpbiAoImx0ZSIsICJjc2ZiIik6CiAgICAgICAgICAgIG5lZWQgKz0gWyJzcnNlbmIiXSArIFti
IGZvciBuZiwgYiBpbiBPNV9ORlMgaWYgbmYgbm90IGluIE81X09QVElPTkFMXQogICAgICAgICAg
ICB0cnk6IGltcG9ydCB5YW1sICAjIG5vcWEKICAgICAgICAgICAgZXhjZXB0IEltcG9ydEVycm9y
OiByZXR1cm4gInB5dGhvbjMteWFtbCBmZWhsdCAoSW5zdGFsbGVyIGVybmV1dCBhdXNmdWVocmVu
KSIKICAgICAgICBtaXNzID0gW2IgZm9yIGIgaW4gbmVlZCBpZiBub3Qgc2h1dGlsLndoaWNoKGIp
XQogICAgICAgIGlmIG1pc3M6IHJldHVybiAiRmVobHQ6ICIgKyAiLCAiLmpvaW4obWlzcykgKyAi
IChJbnN0YWxsZXIgZXJuZXV0IGF1c2Z1ZWhyZW4pIgogICAgICAgIGlmIG1vZGUgPT0gImNzZmIi
IGFuZCBvc21vX2hhcygib3Ntby1tc2MiLCAic2dzIikgaXMgRmFsc2U6CiAgICAgICAgICAgIHJl
dHVybiAiRGllc2Ugb3Ntby1tc2Mga2FubiBrZWluIFNHcyAoQ1NGQikgLSBuZXVlcmUgT3Ntb2Nv
bS1WZXJzaW9uIG5vZXRpZyIKICAgIE5FVC5kZXZfZ3NtLCBORVQuZGV2X2x0ZSA9IGcsIGwKICAg
IHJldHVybiBOb25lCgojID09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
PT09PT09PT09PT09PT09PT09PT09PT09PSBOZXR6LU1hbmFnZXIKTU9ERVMgPSB7ImdzbSI6ICJH
U00gKDJHKSIsICJsdGUiOiAiTFRFICg0RykiLCAiY3NmYiI6ICJMVEUgKyBHU00gKENTRkIpIn0K
CmNsYXNzIE5ldDoKICAgIGRlZiBfX2luaXRfXyhzZWxmKToKICAgICAgICBzZWxmLmxvY2sgPSB0
aHJlYWRpbmcuUkxvY2soKQogICAgICAgIHNlbGYudGVjaCA9IE5vbmUgICAgICAgICAgIyBOb25l
IHwgImdzbSIgfCAibHRlIiB8ICJjc2ZiIgogICAgICAgIHNlbGYuc3RhdGUgPSAiYXVzIiAgICAg
ICAgIyBhdXMgfCBzdGFydGV0IHwgbGFldWZ0IHwgZmVobGVyCiAgICAgICAgc2VsZi5tc2cgPSAi
IgogICAgICAgIHNlbGYucHJvY3MgPSB7fQogICAgICAgIHNlbGYubG9nbGluZXMgPSBbXQogICAg
ICAgIHNlbGYuc3RhcnRlZCA9IDAuMAogICAgICAgIHNlbGYud2VsY29tZWQgPSBzZXQoKSAgICAg
IyBJTVNJcywgZGllIGluIGRpZXNlciBOZXR6LVNlc3Npb24gc2Nob24gYmVncnVlc3N0IHd1cmRl
bgogICAgICAgIHNlbGYuZGV2X2dzbSA9IHNlbGYuZGV2X2x0ZSA9ICIiCgogICAgZGVmIF9sb2co
c2VsZiwgdGFnLCBsaW5lKToKICAgICAgICBsaW5lID0gbGluZS5yc3RyaXAoKQogICAgICAgIGlm
IG5vdCBsaW5lOiByZXR1cm4KICAgICAgICBwcmludChmInt0YWd9OiB7bGluZX0iLCBmbHVzaD1U
cnVlKSAgICMgLT4gam91cm5hbGQsIGRhbWl0ICdqb3VybmFsY3RsIC11IGc5MG5ldCcgYWxsZXMg
emVpZ3QKICAgICAgICBzZWxmLmxvZ2xpbmVzLmFwcGVuZChmInt0YWd9OiB7bGluZX0iKQogICAg
ICAgIGlmIGxlbihzZWxmLmxvZ2xpbmVzKSA+IDYwMDogc2VsZi5sb2dsaW5lcyA9IHNlbGYubG9n
bGluZXNbLTYwMDpdCiAgICAgICAgbG93ID0gbGluZS5sb3dlcigpCiAgICAgICAgaWYgKCJmYXRh
bCIgaW4gbG93IG9yICJmYWlsZWQgdG8gY3JlYXRlIHJhZGlvIiBpbiBsb3cpIGFuZCB0YWcgbm90
IGluIEdTTV9OT05GQVRBTDoKICAgICAgICAgICAgc2VsZi5tc2cgPSBmInt0YWd9OiB7bGluZVs6
MTIwXX0iCgogICAgZGVmIF9yZWFkZXIoc2VsZiwgcCwgdGFnKToKICAgICAgICB0cnk6CiAgICAg
ICAgICAgIGZvciByYXcgaW4gaXRlcihwLnN0ZG91dC5yZWFkbGluZSwgIiIpOgogICAgICAgICAg
ICAgICAgc2VsZi5fbG9nKHRhZywgcmF3KQogICAgICAgIGV4Y2VwdCBFeGNlcHRpb246CiAgICAg
ICAgICAgIHBhc3MKICAgICAgICByYyA9IHAucG9sbCgpCiAgICAgICAgaWYgc2VsZi5wcm9jcy5n
ZXQodGFnKSBpcyBwIGFuZCBzZWxmLnN0YXRlID09ICJsYWV1ZnQiIGFuZCB0YWcgbm90IGluIEdT
TV9OT05GQVRBTDoKICAgICAgICAgICAgc2VsZi5tc2cgPSBmInt0YWd9IGJlZW5kZXQgKENvZGUg
e3JjfSkgLSBzaWVoZSBQcm90b2tvbGwiCgogICAgZGVmIF9zcGF3bihzZWxmLCBiaW5hcnksIGFy
Z3MsIHRhZyk6CiAgICAgICAgcCA9IHN1YnByb2Nlc3MuUG9wZW4oW2JpbmFyeV0gKyBhcmdzLCBz
dGRvdXQ9c3VicHJvY2Vzcy5QSVBFLAogICAgICAgICAgICAgICAgICAgICAgICAgICAgIHN0ZGVy
cj1zdWJwcm9jZXNzLlNURE9VVCwgdGV4dD1UcnVlLCBidWZzaXplPTEpCiAgICAgICAgc2VsZi5w
cm9jc1t0YWddID0gcAogICAgICAgIHRocmVhZGluZy5UaHJlYWQodGFyZ2V0PXNlbGYuX3JlYWRl
ciwgYXJncz0ocCwgdGFnKSwgZGFlbW9uPVRydWUpLnN0YXJ0KCkKICAgICAgICByZXR1cm4gcAoK
ICAgIGRlZiBzdG9wKHNlbGYpOgogICAgICAgIHdpdGggc2VsZi5sb2NrOgogICAgICAgICAgICBp
ZiBGQUtFOgogICAgICAgICAgICAgICAgc2VsZi50ZWNoID0gTm9uZTsgc2VsZi5zdGF0ZSA9ICJh
dXMiOyBzZWxmLnByb2NzID0ge307IHJldHVybgogICAgICAgICAgICBwcm9jcywgc2VsZi5wcm9j
cyA9IHNlbGYucHJvY3MsIHt9CiAgICAgICAgICAgIGZvciB0YWcsIHAgaW4gbGlzdChwcm9jcy5p
dGVtcygpKToKICAgICAgICAgICAgICAgIHRyeTogcC50ZXJtaW5hdGUoKQogICAgICAgICAgICAg
ICAgZXhjZXB0IEV4Y2VwdGlvbjogcGFzcwogICAgICAgICAgICB0aW1lLnNsZWVwKDEpCiAgICAg
ICAgICAgIGZvciBuYW1lIGluIE9TTU9fU0VSVklDRVMgKyBbInNyc2VuYiIsICJzcnNlcGMiLCAi
b3BlbjVncy0iXToKICAgICAgICAgICAgICAgIHRyeTogc3VicHJvY2Vzcy5ydW4oWyJwa2lsbCIs
ICItOSIsICItZiIsIG5hbWVdLAogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBz
dGRvdXQ9c3VicHJvY2Vzcy5ERVZOVUxMLCBzdGRlcnI9c3VicHJvY2Vzcy5ERVZOVUxMKQogICAg
ICAgICAgICAgICAgZXhjZXB0IEV4Y2VwdGlvbjogcGFzcwogICAgICAgICAgICBpZiBzZWxmLnRl
Y2g6CiAgICAgICAgICAgICAgICBfbGltZV9zZXJ2aWNlKCJzdGFydCIpICAgIyBHOTAtRW1wZmFu
ZyB3aWVkZXIgZnJlaSBnZWJlbgogICAgICAgICAgICBzZWxmLnRlY2ggPSBOb25lOyBzZWxmLnN0
YXRlID0gImF1cyI7IHNlbGYubXNnID0gImdlc3RvcHB0IgoKICAgIGRlZiBzdGFydChzZWxmLCBt
b2RlKToKICAgICAgICBpZiBtb2RlIG5vdCBpbiBNT0RFUzogcmV0dXJuICJ1bmJla2FubnRlciBN
b2R1cyIKICAgICAgICB3aXRoIHNlbGYubG9jazoKICAgICAgICAgICAgc2VsZi5zdG9wKCk7IHNl
bGYudGVjaCA9IG1vZGU7IHNlbGYuc3RhdGUgPSAic3RhcnRldCI7IHNlbGYubXNnID0gIiIKICAg
ICAgICAgICAgc2VsZi5sb2dsaW5lcyA9IFtdOyBzZWxmLnN0YXJ0ZWQgPSB0aW1lLnRpbWUoKTsg
c2VsZi53ZWxjb21lZCA9IHNldCgpCiAgICAgICAgZXJyID0gcHJlZmxpZ2h0KG1vZGUpCiAgICAg
ICAgaWYgZXJyOgogICAgICAgICAgICB3aXRoIHNlbGYubG9jazogc2VsZi50ZWNoID0gTm9uZTsg
c2VsZi5zdGF0ZSA9ICJmZWhsZXIiOyBzZWxmLm1zZyA9IGVycgogICAgICAgICAgICByZXR1cm4g
ZXJyCiAgICAgICAgaWYgRkFLRToKICAgICAgICAgICAgd2l0aCBzZWxmLmxvY2s6IHNlbGYuc3Rh
dGUgPSAibGFldWZ0Ijsgc2VsZi5tc2cgPSBNT0RFU1ttb2RlXSArICIgbGFldWZ0IChGQUtFKSIK
ICAgICAgICAgICAgcmV0dXJuIE5vbmUKICAgICAgICBnc20sIGx0ZSA9IG1vZGUgaW4gKCJnc20i
LCAiY3NmYiIpLCBtb2RlIGluICgibHRlIiwgImNzZmIiKQogICAgICAgIHRyeToKICAgICAgICAg
ICAgaWYgZ3NtOgogICAgICAgICAgICAgICAgc2VsZi5fc2VydmljZXNfb2ZmKE9TTU9fU0VSVklD
RVMpCiAgICAgICAgICAgICAgICBnc21fcHJlcGFyZSgpCiAgICAgICAgICAgIGlmIGx0ZToKICAg
ICAgICAgICAgICAgIHNlbGYuX3NlcnZpY2VzX29mZihbYiBmb3IgX25mLCBiIGluIE81X05GU10p
CiAgICAgICAgICAgICAgICBuZnMgPSBvNV9wcmVwYXJlKG1vZGUgPT0gImNzZmIiKQogICAgICAg
ICAgICAgICAgZW5iX3ByZXBhcmUobW9kZSA9PSAiY3NmYiIsIHNlbGYuZGV2X2x0ZSkKICAgICAg
ICAgICAgICAgIF9ydW4oInN5c3RlbWN0bCIsICJzdGFydCIsICJtb25nb2QiKQogICAgICAgICAg
ICAgICAgZSA9IGhzc19zeW5jX2FsbCgpCiAgICAgICAgICAgICAgICBpZiBlOiBzZWxmLl9sb2co
InBrb20iLCAiSFNTOiAiICsgZSkKICAgICAgICAgICAgaWYgc2VsZi5kZXZfZ3NtOiBzZWxmLl9s
b2coInBrb20iLCAiR1NNLUZ1bms6ICIgKyBsaW1lX2xhYmVsKHNlbGYuZGV2X2dzbSkpCiAgICAg
ICAgICAgIGlmIHNlbGYuZGV2X2x0ZTogc2VsZi5fbG9nKCJwa29tIiwgIkxURS1GdW5rOiAiICsg
bGltZV9sYWJlbChzZWxmLmRldl9sdGUpKQogICAgICAgICAgICBfbGltZV9zZXJ2aWNlKCJzdG9w
Iik7IHRpbWUuc2xlZXAoMSk7IF9mcmVlX2xpbWUoKTsgdGltZS5zbGVlcCgyKQogICAgICAgICAg
ICBpZiBnc206CiAgICAgICAgICAgICAgICBmb3IgbmFtZSwgYmluYXJ5LCBjZmcgaW4gZ3NtX2Nv
bXBvbmVudHMoKToKICAgICAgICAgICAgICAgICAgICBmbGFnID0gIi1DIiBpZiBiaW5hcnkuc3Rh
cnRzd2l0aCgib3Ntby10cngiKSBlbHNlICItYyIKICAgICAgICAgICAgICAgICAgICBzZWxmLl9z
cGF3bihiaW5hcnksIFtmbGFnLCBvcy5wYXRoLmpvaW4oV09SS0RJUiwgY2ZnKV0sIG5hbWUpCiAg
ICAgICAgICAgICAgICAgICAgdGltZS5zbGVlcCg0IGlmIG5hbWUgaW4gKCJ0cngiLCkgZWxzZSAx
LjIpCiAgICAgICAgICAgICAgICB0aW1lLnNsZWVwKDEpOyBnc21fYXBwbHlfbnVtYmVycygpICAg
IyBTSU1zICsgZGF1ZXJoYWZ0ZSBSdWZudW1tZXJuIGlucyBITFIKICAgICAgICAgICAgaWYgbHRl
OgogICAgICAgICAgICAgICAgdWVfbmV0X3VwKCkKICAgICAgICAgICAgICAgIGZvciBuZiwgKGJp
bmFyeSwgcGF0aCkgaW4gbmZzLml0ZW1zKCk6CiAgICAgICAgICAgICAgICAgICAgc2VsZi5fc3Bh
d24oYmluYXJ5LCBbIi1jIiwgcGF0aF0sIG5mKQogICAgICAgICAgICAgICAgICAgIHRpbWUuc2xl
ZXAoMS41IGlmIG5mID09ICJtbWUiIGVsc2UgMC44KQogICAgICAgICAgICAgICAgdGltZS5zbGVl
cCgyKQogICAgICAgICAgICAgICAgc2VsZi5fc3Bhd24oInNyc2VuYiIsIFtvcy5wYXRoLmpvaW4o
V09SS0RJUiwgImVuYi5jb25mIildLCAiZW5iIikKICAgICAgICAgICAgd2l0aCBzZWxmLmxvY2s6
IHNlbGYuc3RhdGUgPSAibGFldWZ0Ijsgc2VsZi5tc2cgPSBNT0RFU1ttb2RlXSArICIgZ2VzdGFy
dGV0IgogICAgICAgIGV4Y2VwdCBFeGNlcHRpb24gYXMgZToKICAgICAgICAgICAgd2l0aCBzZWxm
LmxvY2s6IHNlbGYuc3RhdGUgPSAiZmVobGVyIjsgc2VsZi5tc2cgPSBzdHIoZSlbOjIwMF0KICAg
ICAgICAgICAgcmV0dXJuIHN0cihlKQogICAgICAgIHJldHVybiBOb25lCgogICAgIyBLb21wYXRp
YmlsaXRhZXQKICAgIGRlZiBzdGFydF9nc20oc2VsZik6IHJldHVybiBzZWxmLnN0YXJ0KCJnc20i
KQogICAgZGVmIHN0YXJ0X2x0ZShzZWxmKTogcmV0dXJuIHNlbGYuc3RhcnQoImx0ZSIpCgogICAg
ZGVmIF9zZXJ2aWNlc19vZmYoc2VsZiwgbmFtZXMpOgogICAgICAgIGZvciBzIGluIG5hbWVzOgog
ICAgICAgICAgICB0cnk6IHN1YnByb2Nlc3MucnVuKFsic3lzdGVtY3RsIiwgInN0b3AiLCBzLnJl
cGxhY2UoIm9wZW41Z3MtIiwgIm9wZW41Z3MtIikgKyAiLnNlcnZpY2UiXSwKICAgICAgICAgICAg
ICAgICAgICAgICAgICAgICAgICBzdGRvdXQ9c3VicHJvY2Vzcy5ERVZOVUxMLCBzdGRlcnI9c3Vi
cHJvY2Vzcy5ERVZOVUxMLCB0aW1lb3V0PTgpCiAgICAgICAgICAgIGV4Y2VwdCBFeGNlcHRpb246
IHBhc3MKCiAgICBkZWYgc3RhdHVzKHNlbGYpOgogICAgICAgIHdpdGggc2VsZi5sb2NrOgogICAg
ICAgICAgICBzdCA9IHsKICAgICAgICAgICAgICAgICJ0ZWNoIjogc2VsZi50ZWNoLCAibW9kZSI6
IE1PREVTLmdldChzZWxmLnRlY2ggb3IgIiIsICIiKSwKICAgICAgICAgICAgICAgICJzdGF0ZSI6
IHNlbGYuc3RhdGUsICJtc2ciOiBzZWxmLm1zZywKICAgICAgICAgICAgICAgICJ1cHRpbWUiOiBp
bnQodGltZS50aW1lKCkgLSBzZWxmLnN0YXJ0ZWQpIGlmIHNlbGYuc3RhcnRlZCBhbmQgc2VsZi5z
dGF0ZSA9PSAibGFldWZ0IiBlbHNlIDAsCiAgICAgICAgICAgICAgICAibG9nIjogc2VsZi5sb2ds
aW5lc1stODA6XSwKICAgICAgICAgICAgICAgICJjb25mIjogZGljdChDKSwKICAgICAgICAgICAg
ICAgICJsaW1lcyI6IExJTUVTLAogICAgICAgICAgICAgICAgImRldiI6IHsiZ3NtIjogbGltZV9s
YWJlbChzZWxmLmRldl9nc20pIGlmIHNlbGYuZGV2X2dzbSBlbHNlICIiLAogICAgICAgICAgICAg
ICAgICAgICAgICAibHRlIjogbGltZV9sYWJlbChzZWxmLmRldl9sdGUpIGlmIHNlbGYuZGV2X2x0
ZSBlbHNlICIifSwKICAgICAgICAgICAgICAgICJnc20iOiB7CiAgICAgICAgICAgICAgICAgICAg
ImFyZmNuIjogaW50KENbIkdTTV9BUkZDTiJdKSwgImJhbmQiOiBhcmZjbl9iYW5kKGludChDWyJH
U01fQVJGQ04iXSkpLAogICAgICAgICAgICAgICAgICAgICJtaHoiOiBhcmZjbl9taHooaW50KENb
IkdTTV9BUkZDTiJdKSksCiAgICAgICAgICAgICAgICAgICAgImF0dGFjaGVkIjogc29ydGVkKG1z
Y19hdHRhY2hlZCgpKSBpZiBzZWxmLnN0YXRlID09ICJsYWV1ZnQiIGVsc2UgW10sCiAgICAgICAg
ICAgICAgICAgICAgIm51bWJlcnMiOiBudW1zX2xvYWQoKSwKICAgICAgICAgICAgICAgIH0sCiAg
ICAgICAgICAgICAgICAibHRlIjogewogICAgICAgICAgICAgICAgICAgICJlYXJmY24iOiBpbnQo
Q1siTFRFX0VBUkZDTiJdKSwgImJhbmQiOiBlYXJmY25fYmFuZChpbnQoQ1siTFRFX0VBUkZDTiJd
KSksCiAgICAgICAgICAgICAgICAgICAgIm1oeiI6IGVhcmZjbl9taHooaW50KENbIkxURV9FQVJG
Q04iXSkpLAogICAgICAgICAgICAgICAgfSwKICAgICAgICAgICAgICAgICJzaW1zIjogW3siaW1z
aSI6IGksICJtc2lzZG4iOiBzLmdldCgibXNpc2RuIiwgIiIpfSBmb3IgaSwgcyBpbiBzb3J0ZWQo
c2ltc19sb2FkKCkuaXRlbXMoKSldLAogICAgICAgICAgICAgICAgInNpbWZpbGVzIjogc2ltX2Zp
bGVzKCksCiAgICAgICAgICAgICAgICAidHoiOiAiVVRDJStkOiUwMmQlcyIgJSAodHpfbm93KClb
MF0sIHR6X25vdygpWzFdLCAiICtTb21tZXJ6ZWl0IiBpZiB0el9ub3coKVsyXSBlbHNlICIiKSwK
ICAgICAgICAgICAgICAgICJjbGFzaCI6IGZyZXFfY2xhc2goKSwKICAgICAgICAgICAgICAgICJm
YWtlIjogRkFLRSwKICAgICAgICAgICAgfQogICAgICAgIHJldHVybiBzdAoKTkVUID0gTmV0KCkK
CiMgPT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
PT09PT09PT09PT09IFdlYi1BUEkKZGVmIGhhbmRsZV9hcGkocGF0aCwgYm9keSk6CiAgICB0cnk6
CiAgICAgICAgcmVxID0ganNvbi5sb2Fkcyhib2R5IG9yICJ7fSIpCiAgICBleGNlcHQgRXhjZXB0
aW9uOgogICAgICAgIHJlcSA9IHt9CiAgICBjbWQgPSBwYXRoLnJzcGxpdCgiLyIsIDEpWy0xXQog
ICAgaWYgY21kID09ICJzdGF0dXMiOgogICAgICAgIHJldHVybiBORVQuc3RhdHVzKCkKICAgIGlm
IGNtZCBpbiAoInN0YXJ0X2dzbSIsICJzdGFydF9sdGUiLCAic3RhcnRfY3NmYiIpOgogICAgICAg
IE5FVC5zdGFydChjbWRbNjpdKQogICAgZWxpZiBjbWQgPT0gInN0b3AiOgogICAgICAgIE5FVC5z
dG9wKCkKICAgIGVsaWYgY21kID09ICJsaW1lX3NjYW4iOgogICAgICAgIG4gPSBsZW4obGltZV9z
Y2FuKCkpOyBORVQubXNnID0gZiJ7bn0gTGltZVNEUiBnZWZ1bmRlbiIKICAgIGVsaWYgY21kID09
ICJzZXQiOgogICAgICAgICMgYmVsaWViaWdlIEtvbmZpZy1LZXlzIHNldHplbiAodmFsaWRpZXJ0
IGxpZ2h0KQogICAgICAgIGZvciBrLCB2IGluIHJlcS5pdGVtcygpOgogICAgICAgICAgICBpZiBr
IGluIERFRkFVTFRTIG9yIGsgaW4gQzoKICAgICAgICAgICAgICAgIHYgPSBzdHIodikucmVwbGFj
ZSgnIicsICIiKS5yZXBsYWNlKCJcbiIsICIgIikuc3RyaXAoKQogICAgICAgICAgICAgICAgaWYg
ayBpbiAoIk1DQyIsICJNTkMiLCAiTFRFX1RBQyIpOiB2ID0gcmUuc3ViKHIiXEQiLCAiIiwgdikK
ICAgICAgICAgICAgICAgIGNzZXQoaywgdikKICAgICAgICBORVQubXNnID0gImdlc3BlaWNoZXJ0
IC0gd2lya3QgYmVpbSBuYWVjaHN0ZW4gU3RhcnQiCiAgICAgICAgaWYgQy5nZXQoIkdTTV9ERVYi
KSBhbmQgQy5nZXQoIkdTTV9ERVYiKSA9PSBDLmdldCgiTFRFX0RFViIpOgogICAgICAgICAgICBO
RVQubXNnID0gIkFjaHR1bmc6IEdTTSB1bmQgTFRFIG51dHplbiBkZW5zZWxiZW4gTGltZVNEUiAt
IGZ1ZXIgTFRFICsgR1NNIHp3ZWkgR2VyYWV0ZSB3YWVobGVuIgogICAgZWxpZiBjbWQgaW4gKCJz
aW1fYWRkIiwgImdzbV9zaW1fYWRkIiwgImx0ZV9zaW1fYWRkIik6CiAgICAgICAgTkVULm1zZyA9
IHNpbV9hZGQocmVxLmdldCgiaW1zaSIsIiIpLCByZXEuZ2V0KCJraSIsIiIpLCByZXEuZ2V0KCJv
cGMiLCIiKSwgcmVxLmdldCgibXNpc2RuIiwiIikpIFwKICAgICAgICAgICAgICAgICAgb3IgIlNJ
TSBnZXNwZWljaGVydCAoR1NNICsgTFRFKSIKICAgIGVsaWYgY21kIGluICgic2ltX2RlbCIsICJn
c21fc2ltX2RlbCIsICJsdGVfc2ltX2RlbCIpOgogICAgICAgIHNpbV9kZWwocmVxLmdldCgiaW1z
aSIsIiIpKTsgTkVULm1zZyA9ICJTSU0gZ2Vsb2VzY2h0IgogICAgZWxpZiBjbWQgPT0gImdzbV9z
aW1fbnIiOgogICAgICAgIE5FVC5tc2cgPSBnc21fc2ltX25yKHJlcS5nZXQoImltc2kiLCIiKSwg
cmVxLmdldCgibXNpc2RuIiwiIikpIG9yICJSdWZudW1tZXIgZGF1ZXJoYWZ0IHp1Z2V3aWVzZW4i
CiAgICBlbGlmIGNtZCA9PSAiZ3NtX251bV9kZWwiOgogICAgICAgIGdzbV9udW1fZGVsKHJlcS5n
ZXQoImltc2kiLCIiKSk7IE5FVC5tc2cgPSAiUnVmbnVtbWVyLVp1d2Vpc3VuZyBnZWxvZXNjaHQi
CiAgICBlbGlmIGNtZCA9PSAic2ltX2dlbiI6CiAgICAgICAgdHJ5OgogICAgICAgICAgICBnZW4g
PSBzaW1fZ2VuZXJhdGUocmVxLmdldCgiY291bnQiLCAxKSwgcmVxLmdldCgibXNpc2RuIiwgIiIp
LCByZXEuZ2V0KCJpY2NpZCIsICIiKSkKICAgICAgICAgICAgTkVULm1zZyA9IGYie2xlbihnZW4p
fSBTSU0tRGF0ZW5zYXR6Ly1zYWV0emUgZXJ6ZXVndCIKICAgICAgICBleGNlcHQgRXhjZXB0aW9u
IGFzIGU6CiAgICAgICAgICAgIGdlbiA9IFtdOyBORVQubXNnID0gIkVyemV1Z2VuIGZlaGxnZXNj
aGxhZ2VuOiAlcyIgJSBlCiAgICAgICAgc3QgPSBORVQuc3RhdHVzKCk7IHN0WyJnZW5lcmF0ZWQi
XSA9IGdlbgogICAgICAgIHJldHVybiBzdAogICAgZWxpZiBjbWQgPT0gInNtc190ZXN0IjoKICAg
ICAgICBORVQubXNnID0gc21zX3Rlc3QocmVxLmdldCgiaW1zaSIsIiIpLCByZXEuZ2V0KCJ0ZXh0
IiwiIikpCiAgICBlbHNlOgogICAgICAgIE5FVC5tc2cgPSAidW5iZWthbm50IgogICAgcmV0dXJu
IE5FVC5zdGF0dXMoKQoKIyA9PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
PT09PT09PT09PT09PT09PT09PT09PT09PT0gV2ViLU9iZXJmbGFlY2hlIChIVE1MKQpQQUdFID0g
ciIiIjwhZG9jdHlwZSBodG1sPjxodG1sIGxhbmc9ZGU+PGhlYWQ+PG1ldGEgY2hhcnNldD11dGYt
OD4KPG1ldGEgbmFtZT12aWV3cG9ydCBjb250ZW50PSJ3aWR0aD1kZXZpY2Utd2lkdGgsaW5pdGlh
bC1zY2FsZT0xIj4KPG1ldGEgbmFtZT10aGVtZS1jb2xvciBjb250ZW50PSIjMEEyNDYzIj4KPGxp
bmsgcmVsPWljb24gaHJlZj0iZGF0YTppbWFnZS9zdmcreG1sO2Jhc2U2NCxQSE4yWnlCNGJXeHVj
ejBpYUhSMGNEb3ZMM2QzZHk1M015NXZjbWN2TWpBd01DOXpkbWNpSUhacFpYZENiM2c5SWpBZ01D
QXhNREkwSURFd01qUWlQanh5WldOMElIZHBaSFJvUFNJeE1ESTBJaUJvWldsbmFIUTlJakV3TWpR
aUlHWnBiR3c5SWlNd1FUSTBOak1pUGp3dmNtVmpkRDRLUEdjZ2RISmhibk5tYjNKdFBTSjBjbUZ1
YzJ4aGRHVW9NVEkzTGpZZ016UTNMakFwSUhOallXeGxLREV1TmpVcElpQm1hV3hzUFNKdWIyNWxJ
aUJ6ZEhKdmEyVXRiR2x1WldOaGNEMGljbTkxYm1RaUlITjBjbTlyWlMxc2FXNWxhbTlwYmowaWNt
OTFibVFpSUhOMGNtOXJaUzEzYVdSMGFEMGlNeklpUGdvOFp5QnpkSEp2YTJVOUlpTkdSa1pHUmtZ
aVBnbzhjR0YwYUNCa1BTSk5NakFnT0RBZ1ZqSTJOaUkrUEM5d1lYUm9QZ284WTJseVkyeGxJR040
UFNJM01pSWdZM2s5SWpFek15SWdjajBpTlRJaVBqd3ZZMmx5WTJ4bFBnbzhMMmMrQ2p4bklITjBj
bTlyWlQwaUkwWkdSa1pHUmlJK0NqeHdZWFJvSUdROUlrMHhOemdnTVRZZ1VUSXdOaUF4TURBZ01U
YzRJREU0TkNJK1BDOXdZWFJvUGdvOGNHRjBhQ0JrUFNKTk1Ua3lJREV3TUNCRE1qSTJJRGsySURJ
MU1DQTJNaUF5TmpZZ01UWWlQand2Y0dGMGFENEtQQzluUGdvOGNHRjBhQ0J6ZEhKdmEyVTlJaU15
UlVNMFJqRWlJR1E5SWsweE9USWdNVEF3SUVNeU16TWdNVEF5SURJMU5pQXhPRE1nTXpZeklERTRN
eUJCT0RNZ09ETWdNQ0F3SURBZ016WXpJREUzSUVFNE15QTRNeUF3SURBZ01DQXlPRElnTVRFNElq
NDhMM0JoZEdnK0Nqd3ZaejQ4TDNOMlp6ND0iPgo8dGl0bGU+cEtPTSDCtyBOZXR6c3RldWVydW5n
PC90aXRsZT4KPHN0eWxlPgo6cm9vdHstLW5hdnk6IzBBMjQ2MzstLWJnOiMwNjBmMjI7LS1iZzI6
IzBhMTczNDstLWNhcmQ6IzBjMWEzYjstLWNhcmQyOiMxMDIyNTA7LS1saW5lOiMxYjJmNWU7LS1s
aW5lMjojMmE0Mjg4OwotLWZnOiNlYWYxZmI7LS1tdXQ6IzhlYTRjYTstLW11dDI6IzVkNzM5ODst
LWFjYzojMkVDNEYxOy0tYWNjMjojMDA5NkQ2Oy0tb2s6IzJFQzRGMTstLW9rYmc6IzA3MjQzYjst
LWVycjojZmY1ZDZjOwotLXI6MDstLXIyOjA7LS1tb25vOnVpLW1vbm9zcGFjZSxTRk1vbm8tUmVn
dWxhcixNZW5sbyxDb25zb2xhcyxtb25vc3BhY2V9Cip7Ym94LXNpemluZzpib3JkZXItYm94fWh0
bWwsYm9keXttYXJnaW46MH0KYm9keXtiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCgxODBkZWcs
IzA4MTMzMCwjMDUxMDFmKTtjb2xvcjp2YXIoLS1mZyk7CmZvbnQ6MTVweC8xLjU1IHN5c3RlbS11
aSwtYXBwbGUtc3lzdGVtLFNlZ29lIFVJLFJvYm90byxzYW5zLXNlcmlmO21pbi1oZWlnaHQ6MTAw
dmh9CmhlYWRlcntwb3NpdGlvbjpzdGlja3k7dG9wOjA7ei1pbmRleDoyMDtiYWNrZ3JvdW5kOnZh
cigtLW5hdnkpO2JvcmRlci10b3A6MnB4IHNvbGlkIHZhcigtLWFjYyk7CmJvcmRlci1ib3R0b206
MXB4IHNvbGlkIHZhcigtLWxpbmUyKTtwYWRkaW5nOjEycHggMjBweDtkaXNwbGF5OmZsZXg7YWxp
Z24taXRlbXM6Y2VudGVyO2dhcDoxNnB4O2ZsZXgtd3JhcDp3cmFwfQouYnJhbmR7ZGlzcGxheTpm
bGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtnYXA6MTJweH0KLmJyYW5kIHN2Z3toZWlnaHQ6MzBweDt3
aWR0aDphdXRvO2Rpc3BsYXk6YmxvY2t9Ci5icmFuZCAucHJvZHtmb250LXNpemU6MTFweDtmb250
LXdlaWdodDo3MDA7bGV0dGVyLXNwYWNpbmc6LjE4ZW07dGV4dC10cmFuc2Zvcm06dXBwZXJjYXNl
O2NvbG9yOiM5ZmI2ZGU7cGFkZGluZy1sZWZ0OjEycHg7Ym9yZGVyLWxlZnQ6MXB4IHNvbGlkICMy
NzQwN2V9Ci5jaGlwe2Rpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7Z2FwOjhweDtwYWRk
aW5nOjZweCAxMnB4O2JvcmRlcjoxcHggc29saWQgdmFyKC0tbGluZTIpO2JhY2tncm91bmQ6IzBi
MTczMztmb250LXNpemU6MTJweDtmb250LXdlaWdodDo3MDA7bGV0dGVyLXNwYWNpbmc6LjA2ZW07
dGV4dC10cmFuc2Zvcm06dXBwZXJjYXNlfQouZG90e3dpZHRoOjhweDtoZWlnaHQ6OHB4O2JhY2tn
cm91bmQ6dmFyKC0tbXV0KX0KLmRvdC5vbntiYWNrZ3JvdW5kOnZhcigtLWFjYyk7YW5pbWF0aW9u
OnB1bHNlIDJzIGluZmluaXRlfS5kb3QuZXJye2JhY2tncm91bmQ6dmFyKC0tZXJyKX0KQGtleWZy
YW1lcyBwdWxzZXswJXtib3gtc2hhZG93OjAgMCAwIDAgcmdiYSg0NiwxOTYsMjQxLC41KX03MCV7
Ym94LXNoYWRvdzowIDAgMCA3cHggcmdiYSg0NiwxOTYsMjQxLDApfTEwMCV7Ym94LXNoYWRvdzow
IDAgMCAwIHJnYmEoNDYsMTk2LDI0MSwwKX19Ci5oc3RhdHtkaXNwbGF5OmZsZXg7Z2FwOjE4cHg7
ZmxleC13cmFwOndyYXA7Y29sb3I6dmFyKC0tbXV0KTtmb250LXNpemU6MTJweDttYXJnaW4tbGVm
dDphdXRvO2FsaWduLWl0ZW1zOmNlbnRlcjt0ZXh0LXRyYW5zZm9ybTp1cHBlcmNhc2U7bGV0dGVy
LXNwYWNpbmc6LjA1ZW19Ci5oc3RhdCBie2NvbG9yOnZhcigtLWZnKTtmb250LWZhbWlseTp2YXIo
LS1tb25vKTtsZXR0ZXItc3BhY2luZzowO3RleHQtdHJhbnNmb3JtOm5vbmV9CiNtc2d7Y29sb3I6
dmFyKC0tYWNjKTtmb250LXNpemU6MTJweDt0ZXh0LXRyYW5zZm9ybTpub25lO2xldHRlci1zcGFj
aW5nOjB9Ci5iYWRnZXtmb250LXNpemU6MTBweDtwYWRkaW5nOjNweCA5cHg7Ym9yZGVyOjFweCBz
b2xpZCB2YXIoLS1hY2MpO2NvbG9yOnZhcigtLWFjYyk7Zm9udC13ZWlnaHQ6NzAwO2xldHRlci1z
cGFjaW5nOi4xMmVtfQoud3JhcHttYXgtd2lkdGg6MTA2MHB4O21hcmdpbjowIGF1dG87cGFkZGlu
ZzoyMnB4IDE2cHggNDRweH0KLmJhbm5lcntkaXNwbGF5OmZsZXg7Z2FwOjExcHg7YWxpZ24taXRl
bXM6ZmxleC1zdGFydDtiYWNrZ3JvdW5kOiMwYzFhM2I7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1s
aW5lMik7CmJvcmRlci1sZWZ0OjNweCBzb2xpZCAjZjFiMjRhO2NvbG9yOiNmMmQ3OWY7cGFkZGlu
ZzoxMnB4IDE1cHg7Zm9udC1zaXplOjEzcHg7bWFyZ2luLWJvdHRvbToxOHB4fQouY29udHJvbHN7
ZGlzcGxheTpncmlkO2dyaWQtdGVtcGxhdGUtY29sdW1uczoxZnIgMWZyIDFmciBhdXRvO2dhcDox
MHB4O21hcmdpbi1ib3R0b206MjBweH0KQG1lZGlhKG1heC13aWR0aDo4MjBweCl7LmNvbnRyb2xz
e2dyaWQtdGVtcGxhdGUtY29sdW1uczoxZnIgMWZyfX1AbWVkaWEobWF4LXdpZHRoOjQ4MHB4KXsu
Y29udHJvbHN7Z3JpZC10ZW1wbGF0ZS1jb2x1bW5zOjFmcn19Ci5iaWdidG57Ym9yZGVyOjFweCBz
b2xpZCB2YXIoLS1saW5lMik7YmFja2dyb3VuZDojMGIxODM2O2NvbG9yOnZhcigtLWZnKTsKcGFk
ZGluZzoxNXB4IDE4cHg7Zm9udDppbmhlcml0O2ZvbnQtd2VpZ2h0OjYwMDtjdXJzb3I6cG9pbnRl
cjtkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2dhcDoxMnB4O3RyYW5zaXRpb246LjE1
c30KLmJpZ2J0bjpob3Zlcntib3JkZXItY29sb3I6dmFyKC0tYWNjKTtiYWNrZ3JvdW5kOiMwZTFm
NDd9LmJpZ2J0biAuaWN7Zm9udC1zaXplOjE2cHg7Y29sb3I6dmFyKC0tYWNjKX0KLmJpZ2J0biBz
bWFsbHtkaXNwbGF5OmJsb2NrO2NvbG9yOnZhcigtLW11dCk7Zm9udC13ZWlnaHQ6NDAwO2ZvbnQt
c2l6ZToxMXB4O3RleHQtdHJhbnNmb3JtOnVwcGVyY2FzZTtsZXR0ZXItc3BhY2luZzouMDdlbTtt
YXJnaW4tdG9wOjJweH0KLmJpZ2J0bi5hY3RpdmV7Ym9yZGVyLWNvbG9yOnZhcigtLWFjYyk7YmFj
a2dyb3VuZDp2YXIoLS1va2JnKTtib3gtc2hhZG93Omluc2V0IDNweCAwIDAgdmFyKC0tYWNjKX0u
YmlnYnRuLmFjdGl2ZSAuaWN7Y29sb3I6dmFyKC0tYWNjKX0KLmJpZ2J0bi5zdG9we2JhY2tncm91
bmQ6IzFlMTAxNjtib3JkZXItY29sb3I6IzUzMjMyZTtjb2xvcjojZmZiMGI4O2p1c3RpZnktY29u
dGVudDpjZW50ZXI7Zm9udC13ZWlnaHQ6NzAwO2xldHRlci1zcGFjaW5nOi4wNWVtO3RleHQtdHJh
bnNmb3JtOnVwcGVyY2FzZTtmb250LXNpemU6MTRweH0uYmlnYnRuLnN0b3A6aG92ZXJ7Ym9yZGVy
LWNvbG9yOnZhcigtLWVycil9Ci50YWJze2Rpc3BsYXk6ZmxleDtnYXA6NHB4O2JvcmRlci1ib3R0
b206MXB4IHNvbGlkIHZhcigtLWxpbmUyKTttYXJnaW4tYm90dG9tOjIwcHg7b3ZlcmZsb3cteDph
dXRvfQoudGFie3BhZGRpbmc6MTBweCAxNnB4O2JvcmRlcjowO2JhY2tncm91bmQ6MDtjb2xvcjp2
YXIoLS1tdXQpO2ZvbnQ6aW5oZXJpdDtmb250LXdlaWdodDo3MDA7Zm9udC1zaXplOjEycHg7bGV0
dGVyLXNwYWNpbmc6LjA5ZW07dGV4dC10cmFuc2Zvcm06dXBwZXJjYXNlO2N1cnNvcjpwb2ludGVy
O2JvcmRlci1ib3R0b206MnB4IHNvbGlkIHRyYW5zcGFyZW50O3doaXRlLXNwYWNlOm5vd3JhcDtt
YXJnaW4tYm90dG9tOi0xcHh9Ci50YWI6aG92ZXJ7Y29sb3I6dmFyKC0tZmcpfS50YWIuc2Vse2Nv
bG9yOnZhcigtLWFjYyk7Ym9yZGVyLWJvdHRvbS1jb2xvcjp2YXIoLS1hY2MpfQoucGFuZWx7ZGlz
cGxheTpub25lfS5wYW5lbC5zZWx7ZGlzcGxheTpibG9ja30KLmdyaWR7ZGlzcGxheTpncmlkO2dh
cDoxNnB4O2dyaWQtdGVtcGxhdGUtY29sdW1uczoxZnIgMWZyfUBtZWRpYShtYXgtd2lkdGg6NzYw
cHgpey5ncmlke2dyaWQtdGVtcGxhdGUtY29sdW1uczoxZnJ9fQouY2FyZHtiYWNrZ3JvdW5kOnZh
cigtLWNhcmQpO2JvcmRlcjoxcHggc29saWQgdmFyKC0tbGluZSk7cGFkZGluZzoxOHB4fQouY2Fy
ZCBoMntmb250LXNpemU6MTJweDttYXJnaW46MDtkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2Vu
dGVyO2dhcDo5cHg7dGV4dC10cmFuc2Zvcm06dXBwZXJjYXNlO2xldHRlci1zcGFjaW5nOi4xZW07
Y29sb3I6I2M2ZDZmMTtmb250LXdlaWdodDo3MDB9Ci5jYXJkIGgyOmJlZm9yZXtjb250ZW50OiIi
O3dpZHRoOjlweDtoZWlnaHQ6OXB4O2JhY2tncm91bmQ6dmFyKC0tYWNjKTtmbGV4Om5vbmV9Ci5j
YXJkIC5zdWJ7Y29sb3I6dmFyKC0tbXV0KTtmb250LXNpemU6MTJweDttYXJnaW46OHB4IDAgMTRw
eH0KbGFiZWx7ZGlzcGxheTpibG9jaztmb250LXNpemU6MTFweDtjb2xvcjp2YXIoLS1tdXQpO21h
cmdpbjoxM3B4IDAgNXB4O2ZvbnQtd2VpZ2h0OjcwMDt0ZXh0LXRyYW5zZm9ybTp1cHBlcmNhc2U7
bGV0dGVyLXNwYWNpbmc6LjA3ZW19CmlucHV0LHNlbGVjdHt3aWR0aDoxMDAlO2JhY2tncm91bmQ6
IzA3MTQyZjtib3JkZXI6MXB4IHNvbGlkIHZhcigtLWxpbmUyKTtjb2xvcjp2YXIoLS1mZyk7cGFk
ZGluZzoxMHB4IDEycHg7Zm9udDppbmhlcml0O291dGxpbmU6MDt0cmFuc2l0aW9uOi4xMnN9Cmlu
cHV0OmZvY3VzLHNlbGVjdDpmb2N1c3tib3JkZXItY29sb3I6dmFyKC0tYWNjKTtib3gtc2hhZG93
OjAgMCAwIDJweCByZ2JhKDQ2LDE5NiwyNDEsLjE4KX0KLnJvd3tkaXNwbGF5OmdyaWQ7Z3JpZC10
ZW1wbGF0ZS1jb2x1bW5zOjFmciAxZnI7Z2FwOjEwcHh9LnJvdzN7ZGlzcGxheTpncmlkO2dyaWQt
dGVtcGxhdGUtY29sdW1uczoxZnIgMWZyIDFmcjtnYXA6MTBweH0KLmJ0bntiYWNrZ3JvdW5kOnZh
cigtLWFjYyk7Y29sb3I6dmFyKC0tbmF2eSk7Ym9yZGVyOjA7cGFkZGluZzoxMHB4IDE4cHg7Zm9u
dDppbmhlcml0O2ZvbnQtd2VpZ2h0OjcwMDtsZXR0ZXItc3BhY2luZzouMDVlbTt0ZXh0LXRyYW5z
Zm9ybTp1cHBlcmNhc2U7Zm9udC1zaXplOjEzcHg7Y3Vyc29yOnBvaW50ZXI7bWFyZ2luLXRvcDox
NnB4O3RyYW5zaXRpb246LjEyc30KLmJ0bjpob3ZlcntiYWNrZ3JvdW5kOiM1YWQyZjZ9LmJ0bi5z
ZWN7YmFja2dyb3VuZDp0cmFuc3BhcmVudDtib3JkZXI6MXB4IHNvbGlkIHZhcigtLWxpbmUyKTtj
b2xvcjp2YXIoLS1hY2MpfS5idG4uc2VjOmhvdmVye2JvcmRlci1jb2xvcjp2YXIoLS1hY2MpO2Jh
Y2tncm91bmQ6IzBiMWI0MH0KLmJ0bi5zbXtwYWRkaW5nOjhweCAxM3B4O21hcmdpbi10b3A6NHB4
O2ZvbnQtc2l6ZToxMnB4fQouc3d7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtqdXN0
aWZ5LWNvbnRlbnQ6c3BhY2UtYmV0d2VlbjtnYXA6MTBweDtwYWRkaW5nOjEzcHggMDtib3JkZXIt
dG9wOjFweCBzb2xpZCB2YXIoLS1saW5lKX0KLnN3LmZpcnN0e2JvcmRlci10b3A6MH0uc3cgLnR7
Zm9udC1zaXplOjE0cHh9LnN3IC50IHNtYWxse2Rpc3BsYXk6YmxvY2s7Y29sb3I6dmFyKC0tbXV0
KTtmb250LXNpemU6MTJweH0KLnN3aXRjaHtwb3NpdGlvbjpyZWxhdGl2ZTt3aWR0aDo0NnB4O2hl
aWdodDoyNHB4O2ZsZXg6bm9uZX0uc3dpdGNoIGlucHV0e29wYWNpdHk6MDt3aWR0aDowO2hlaWdo
dDowfQouc2xpZGVye3Bvc2l0aW9uOmFic29sdXRlO2luc2V0OjA7YmFja2dyb3VuZDojMGIxYTNk
O2JvcmRlcjoxcHggc29saWQgdmFyKC0tbGluZTIpO3RyYW5zaXRpb246LjJzO2N1cnNvcjpwb2lu
dGVyfQouc2xpZGVyOmJlZm9yZXtjb250ZW50OiIiO3Bvc2l0aW9uOmFic29sdXRlO2hlaWdodDox
NnB4O3dpZHRoOjE2cHg7bGVmdDozcHg7dG9wOjNweDtiYWNrZ3JvdW5kOnZhcigtLW11dCk7dHJh
bnNpdGlvbjouMnN9Ci5zd2l0Y2ggaW5wdXQ6Y2hlY2tlZCsuc2xpZGVye2JhY2tncm91bmQ6dmFy
KC0tb2tiZyk7Ym9yZGVyLWNvbG9yOnZhcigtLWFjYyl9LnN3aXRjaCBpbnB1dDpjaGVja2VkKy5z
bGlkZXI6YmVmb3Jle3RyYW5zZm9ybTp0cmFuc2xhdGVYKDIycHgpO2JhY2tncm91bmQ6dmFyKC0t
YWNjKX0KLmhpbnR7Zm9udC1zaXplOjEycHg7Y29sb3I6dmFyKC0tbXV0KTttYXJnaW4tdG9wOjEw
cHg7bGluZS1oZWlnaHQ6MS41fQouZnJlcWJveHtiYWNrZ3JvdW5kOiMwNzE0MmY7Ym9yZGVyOjFw
eCBzb2xpZCB2YXIoLS1saW5lMik7cGFkZGluZzoxM3B4IDE2cHg7ZGlzcGxheTpmbGV4O2p1c3Rp
ZnktY29udGVudDpzcGFjZS1iZXR3ZWVuO2FsaWduLWl0ZW1zOmNlbnRlcn0KLmZyZXFib3ggLmJp
Z3tmb250LXNpemU6MjJweDtmb250LXdlaWdodDo3MDA7bGluZS1oZWlnaHQ6MS4xNTtmb250LWZh
bWlseTp2YXIoLS1tb25vKTtjb2xvcjp2YXIoLS1hY2MpfS5mcmVxYm94IC5zbXtjb2xvcjp2YXIo
LS1tdXQpO2ZvbnQtc2l6ZToxMnB4O3RleHQtdHJhbnNmb3JtOnVwcGVyY2FzZTtsZXR0ZXItc3Bh
Y2luZzouMDZlbX0KLmxpc3Ryb3d7ZGlzcGxheTpmbGV4O2p1c3RpZnktY29udGVudDpzcGFjZS1i
ZXR3ZWVuO2FsaWduLWl0ZW1zOmNlbnRlcjtib3JkZXItdG9wOjFweCBzb2xpZCB2YXIoLS1saW5l
KTtwYWRkaW5nOjlweCAwO2ZvbnQtc2l6ZToxNHB4fQoubGlzdHJvdzpmaXJzdC1jaGlsZHtib3Jk
ZXItdG9wOjB9LnRhZ3tmb250LWZhbWlseTp2YXIoLS1tb25vKTtmb250LXNpemU6MTNweDtjb2xv
cjojY2FkOWYzfQoueHtiYWNrZ3JvdW5kOiMxZTEwMTY7Ym9yZGVyOjFweCBzb2xpZCAjNTMyMzJl
O2NvbG9yOiNmZjliYTY7cGFkZGluZzo0cHggMTBweDtjdXJzb3I6cG9pbnRlcjtmb250LXNpemU6
MTFweDt0ZXh0LXRyYW5zZm9ybTp1cHBlcmNhc2U7bGV0dGVyLXNwYWNpbmc6LjA1ZW19Lng6aG92
ZXJ7Ym9yZGVyLWNvbG9yOnZhcigtLWVycil9Ci5lbXB0eXtjb2xvcjp2YXIoLS1tdXQyKTtmb250
LXNpemU6MTNweDtwYWRkaW5nOjhweCAwfQoubG9ne2JhY2tncm91bmQ6IzAzMGExODtib3JkZXI6
MXB4IHNvbGlkIHZhcigtLWxpbmUpO3BhZGRpbmc6MTRweDtmb250OjEycHgvMS41NSB2YXIoLS1t
b25vKTtoZWlnaHQ6NDQwcHg7b3ZlcmZsb3c6YXV0bzt3aGl0ZS1zcGFjZTpwcmUtd3JhcDtjb2xv
cjojOWZiM2QwfQoudG9vbGJhcntkaXNwbGF5OmZsZXg7Z2FwOjhweDthbGlnbi1pdGVtczpjZW50
ZXI7bWFyZ2luLWJvdHRvbToxMnB4fS50b29sYmFyIGlucHV0e2ZsZXg6MX0KLmVme3dpZHRoOjEw
MCU7Ym9yZGVyLWNvbGxhcHNlOmNvbGxhcHNlO2ZvbnQtc2l6ZToxM3B4O21hcmdpbi10b3A6NnB4
fS5lZiB0aHt0ZXh0LWFsaWduOmxlZnQ7Y29sb3I6dmFyKC0tbXV0KTtmb250LXNpemU6MTFweDt0
ZXh0LXRyYW5zZm9ybTp1cHBlcmNhc2U7bGV0dGVyLXNwYWNpbmc6LjA3ZW07cGFkZGluZzo4cHgg
NnB4O2JvcmRlci1ib3R0b206MXB4IHNvbGlkIHZhcigtLWxpbmUyKX0uZWYgdGR7cGFkZGluZzox
MHB4IDZweDtib3JkZXItYm90dG9tOjFweCBzb2xpZCB2YXIoLS1saW5lKTt2ZXJ0aWNhbC1hbGln
bjp0b3B9LmVmIGNvZGV7Zm9udC1mYW1pbHk6dmFyKC0tbW9ubyk7Y29sb3I6dmFyKC0tYWNjKTt3
b3JkLWJyZWFrOmJyZWFrLWFsbDt1c2VyLXNlbGVjdDphbGx9Lm11dHtjb2xvcjp2YXIoLS1tdXQp
O2ZvbnQtc2l6ZToxMXB4fS5nZW53cmFwe292ZXJmbG93LXg6YXV0bzttYXJnaW4tdG9wOjEycHh9
LmdlbndyYXAgLmVmIHRkLC5nZW53cmFwIC5lZiB0aHt3aGl0ZS1zcGFjZTpub3dyYXB9Lmdlbndy
YXAgY29kZXtmb250LXNpemU6MTJweH0uYnRuOmRpc2FibGVke29wYWNpdHk6LjQ7Y3Vyc29yOmRl
ZmF1bHR9Y29kZXtmb250LWZhbWlseTp2YXIoLS1tb25vKX1AbWVkaWEobWF4LXdpZHRoOjU2MHB4
KXsucm93LC5yb3cze2dyaWQtdGVtcGxhdGUtY29sdW1uczoxZnJ9fQo8L3N0eWxlPjwvaGVhZD48
Ym9keT4KPGhlYWRlcj4KIDxkaXYgY2xhc3M9YnJhbmQ+PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53
My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9Ii0yMCAtMjAgNjY4IDMzMCIgcm9sZT0iaW1nIiBhcmlh
LWxhYmVsPSJwS09NIj48ZyBmaWxsPSJub25lIiBzdHJva2UtbGluZWNhcD0icm91bmQiIHN0cm9r
ZS1saW5lam9pbj0icm91bmQiIHN0cm9rZS13aWR0aD0iMzIiPjxnIHN0cm9rZT0iI0ZGRkZGRiI+
PHBhdGggZD0iTTIwIDgwIFYyNjYiPjwvcGF0aD48Y2lyY2xlIGN4PSI3MiIgY3k9IjEzMyIgcj0i
NTIiPjwvY2lyY2xlPjxwYXRoIGQ9Ik0xNzggMTYgUTIwNiAxMDAgMTc4IDE4NCI+PC9wYXRoPjxw
YXRoIGQ9Ik0xOTIgMTAwIEMyMjYgOTYgMjUwIDYyIDI2NiAxNiI+PC9wYXRoPjxwYXRoIGQ9Ik00
OTIgMTg0IFYzMCBDNTIyIDMwIDUzNCAxMDYgNTUyIDEwNiBDNTcwIDEwNiA1ODIgMzAgNjEyIDMw
IFYxODQiPjwvcGF0aD48L2c+PHBhdGggc3Ryb2tlPSIjMkVDNEYxIiBkPSJNMTkyIDEwMCBDMjMz
IDEwMiAyNTYgMTgzIDM2MyAxODMgQTgzIDgzIDAgMCAwIDM2MyAxNyBBODMgODMgMCAwIDAgMjgy
IDExOCI+PC9wYXRoPjwvZz48L3N2Zz48c3BhbiBjbGFzcz1wcm9kPk5ldHpzdGV1ZXJ1bmc8L3Nw
YW4+PC9kaXY+CiA8ZGl2IGNsYXNzPWNoaXA+PHNwYW4gY2xhc3M9ZG90IGlkPWRvdD48L3NwYW4+
PHNwYW4gaWQ9c3RhdGU+4oCTPC9zcGFuPjwvZGl2PgogPGRpdiBjbGFzcz1oc3RhdD4KICA8c3Bh
biBpZD10ZWNoYmFkZ2UgY2xhc3M9YmFkZ2Ugc3R5bGU9ZGlzcGxheTpub25lPjwvc3Bhbj4KICA8
c3Bhbj5GcmVxdWVueiA8YiBpZD1mcmVxPuKAkzwvYj48L3NwYW4+CiAgPHNwYW4+TGF1ZnplaXQg
PGIgaWQ9dXB0aW1lPuKAkzwvYj48L3NwYW4+CiAgPHNwYW4gaWQ9bXNnPjwvc3Bhbj4KIDwvZGl2
Pgo8L2hlYWRlcj4KPGRpdiBjbGFzcz13cmFwPgogPGRpdiBjbGFzcz1iYW5uZXI+PHNwYW4+4pqg
77iPPC9zcGFuPjxzcGFuPjxiPk51ciBhYmdlc2Nob3R0ZXQgYmV0cmVpYmVuPC9iPiDigJMgRHVt
bXkgTG9hZCAvIEthYmVsICsgRMOkbXBmdW5nIC8gZ2VzY2hpcm10LiBPZmZlbmVzIE5ldHogb2hu
ZSBBdXRoZW50aXNpZXJ1bmcgPSBJTVNJLUNhdGNoZXIsIHdlbm4gZXMgYWJzdHJhaGx0LiBOdXIg
ZWlnZW5lIFRlc3QtU0lNcywgS2VubnVuZyAwMDEveHggKFRlc3QpIG9kZXIgOTk5L3h4IChwcml2
YXQpLjwvc3Bhbj48L2Rpdj4KCiA8ZGl2IGNsYXNzPWNvbnRyb2xzPgogIDxidXR0b24gY2xhc3M9
YmlnYnRuIGlkPWJ0bl9nc20gb25jbGljaz0iY21kKCdzdGFydF9nc20nKSI+PHNwYW4gY2xhc3M9
aWM+4pa2PC9zcGFuPjxzcGFuPkdTTSAoMkcpPHNtYWxsIGlkPWdzbV9zdWI+T3Ntb2NvbTwvc21h
bGw+PC9zcGFuPjwvYnV0dG9uPgogIDxidXR0b24gY2xhc3M9YmlnYnRuIGlkPWJ0bl9sdGUgb25j
bGljaz0iY21kKCdzdGFydF9sdGUnKSI+PHNwYW4gY2xhc3M9aWM+4pa2PC9zcGFuPjxzcGFuPkxU
RSAoNEcpPHNtYWxsIGlkPWx0ZV9zdWI+c3JzUkFOICsgT3BlbjVHUzwvc21hbGw+PC9zcGFuPjwv
YnV0dG9uPgogIDxidXR0b24gY2xhc3M9YmlnYnRuIGlkPWJ0bl9jc2ZiIG9uY2xpY2s9ImNtZCgn
c3RhcnRfY3NmYicpIj48c3BhbiBjbGFzcz1pYz7ilrY8L3NwYW4+PHNwYW4+TFRFICsgR1NNPHNt
YWxsIGlkPWNzZmJfc3ViPkludGVybmV0ICsgQW5ydWZlIChDU0ZCKTwvc21hbGw+PC9zcGFuPjwv
YnV0dG9uPgogIDxidXR0b24gY2xhc3M9ImJpZ2J0biBzdG9wIiBvbmNsaWNrPSJjbWQoJ3N0b3An
KSI+4pagIFN0b3BwZW48L2J1dHRvbj4KIDwvZGl2PgoKIDxkaXYgY2xhc3M9dGFicz4KICA8YnV0
dG9uIGNsYXNzPSJ0YWIgc2VsIiBkYXRhLXQ9c3RldWVydW5nIG9uY2xpY2s9InRhYignc3RldWVy
dW5nJykiPlN0ZXVlcnVuZzwvYnV0dG9uPgogIDxidXR0b24gY2xhc3M9dGFiIGRhdGEtdD1nc20g
b25jbGljaz0idGFiKCdnc20nKSI+R1NNIMK3IDJHPC9idXR0b24+CiAgPGJ1dHRvbiBjbGFzcz10
YWIgZGF0YS10PWx0ZSBvbmNsaWNrPSJ0YWIoJ2x0ZScpIj5MVEUgwrcgNEc8L2J1dHRvbj4KICA8
YnV0dG9uIGNsYXNzPXRhYiBkYXRhLXQ9c2ltcyBvbmNsaWNrPSJ0YWIoJ3NpbXMnKSI+U0lNcyAm
IE51bW1lcm48L2J1dHRvbj4KICA8YnV0dG9uIGNsYXNzPXRhYiBkYXRhLXQ9cHJvZmlsIG9uY2xp
Y2s9InRhYigncHJvZmlsJykiPlNJTS1Qcm9maWw8L2J1dHRvbj4KICA8YnV0dG9uIGNsYXNzPXRh
YiBkYXRhLXQ9bG9nIG9uY2xpY2s9InRhYignbG9nJykiPlByb3Rva29sbDwvYnV0dG9uPgogPC9k
aXY+CgogPGRpdiBjbGFzcz0icGFuZWwgc2VsIiBpZD1wLXN0ZXVlcnVuZz4KICA8ZGl2IGNsYXNz
PWdyaWQ+CiAgIDxkaXYgY2xhc3M9Y2FyZD4KICAgIDxoMj5TdGF0dXM8L2gyPgogICAgPGRpdiBj
bGFzcz1mcmVxYm94IHN0eWxlPW1hcmdpbi10b3A6MTJweD4KICAgICA8ZGl2PjxkaXYgY2xhc3M9
YmlnIGlkPWZyZXEyPuKAkzwvZGl2PjxkaXYgY2xhc3M9c20gaWQ9ZnJlcXN1Yj48L2Rpdj48L2Rp
dj4KICAgICA8ZGl2IHN0eWxlPXRleHQtYWxpZ246cmlnaHQ+PGRpdiBjbGFzcz1iaWcgaWQ9dGVj
aDI+YXVzPC9kaXY+PGRpdiBjbGFzcz1zbSBpZD1zdGF0ZXN1Yj48L2Rpdj48L2Rpdj4KICAgIDwv
ZGl2PgogICAgPGRpdiBjbGFzcz1oaW50IGlkPXVwdGltZWhpbnQ+PC9kaXY+CiAgICA8ZGl2IGNs
YXNzPWhpbnQgaWQ9ZGV2aGludD48L2Rpdj4KICAgIDxkaXYgY2xhc3M9aGludCBpZD1jbGFzaCBz
dHlsZT1jb2xvcjp2YXIoLS1lcnIpPjwvZGl2PgogICA8L2Rpdj4KICAgPGRpdiBjbGFzcz1jYXJk
PgogICAgPGgyPkZ1bmstSGFyZHdhcmU8L2gyPgogICAgPHAgY2xhc3M9c3ViPkplIE5ldHogZWlu
IGVpZ2VuZXIgTGltZVNEUi4gRsO8ciDigJ5MVEUgKyBHU03igJwgendlaSB2ZXJzY2hpZWRlbmUg
d8OkaGxlbi48L3A+CiAgICA8bGFiZWw+TGltZVNEUiBmw7xyIEdTTSAoMkcpPC9sYWJlbD48c2Vs
ZWN0IGlkPUdTTV9ERVY+PC9zZWxlY3Q+CiAgICA8bGFiZWw+TGltZVNEUiBmw7xyIExURSAoNEcp
PC9sYWJlbD48c2VsZWN0IGlkPUxURV9ERVY+PC9zZWxlY3Q+CiAgICA8ZGl2IHN0eWxlPWRpc3Bs
YXk6ZmxleDtnYXA6OHB4O2ZsZXgtd3JhcDp3cmFwPgogICAgIDxidXR0b24gY2xhc3M9YnRuIG9u
Y2xpY2s9InNhdmUoWydHU01fREVWJywnTFRFX0RFViddKSI+U3BlaWNoZXJuPC9idXR0b24+CiAg
ICAgPGJ1dHRvbiBjbGFzcz0iYnRuIHNlYyIgb25jbGljaz0iY21kKCdsaW1lX3NjYW4nKSI+TmV1
IHN1Y2hlbjwvYnV0dG9uPgogICAgPC9kaXY+CiAgICA8ZGl2IGNsYXNzPWhpbnQgaWQ9bGltZWxp
c3Q+PC9kaXY+CiAgIDwvZGl2PgogICA8ZGl2IGNsYXNzPWNhcmQ+CiAgICA8aDI+TmV0ei1JZGVu
dGl0w6R0PC9oMj4KICAgIDxwIGNsYXNzPXN1Yj5HaWx0IGbDvHIgR1NNIHVuZCBMVEUuIE51ciBU
ZXN0a2VubnVuZyAwMDEveHggb2RlciBQcml2YXRrZW5udW5nIDk5OS94eC48L3A+CiAgICA8ZGl2
IGNsYXNzPXJvdz4KICAgICA8ZGl2PjxsYWJlbD5NQ0M8L2xhYmVsPjxpbnB1dCBpZD1NQ0MgaW5w
dXRtb2RlPW51bWVyaWM+PC9kaXY+CiAgICAgPGRpdj48bGFiZWw+TU5DPC9sYWJlbD48aW5wdXQg
aWQ9TU5DIGlucHV0bW9kZT1udW1lcmljPjwvZGl2PgogICAgPC9kaXY+CiAgICA8ZGl2IGNsYXNz
PXJvdz4KICAgICA8ZGl2PjxsYWJlbD5OZXR6bmFtZSAobGFuZyk8L2xhYmVsPjxpbnB1dCBpZD1O
RVROQU1FPjwvZGl2PgogICAgIDxkaXY+PGxhYmVsPk5ldHpuYW1lIChrdXJ6KTwvbGFiZWw+PGlu
cHV0IGlkPU5FVE5BTUVfU0hPUlQ+PC9kaXY+CiAgICA8L2Rpdj4KICAgIDxsYWJlbD5BbmJpZXRl
cm5hbWUgKFNQTiwgbWF4LiAxNiBaZWljaGVuKTwvbGFiZWw+PGlucHV0IGlkPVNQTiBtYXhsZW5n
dGg9MTY+CiAgICA8ZGl2IGNsYXNzPXN3PjxkaXYgY2xhc3M9dD5OSVRaIHNlbmRlbjxzbWFsbD5O
ZXR6bmFtZSwgVWhyemVpdCB1bmQgWmVpdHpvbmUgKDxzcGFuIGlkPXR6PuKAkzwvc3Bhbj4pIGJl
aW0gRWluYnVjaGVuPC9zbWFsbD48L2Rpdj4KICAgICA8bGFiZWwgY2xhc3M9c3dpdGNoPjxpbnB1
dCB0eXBlPWNoZWNrYm94IGlkPU5JVFo+PHNwYW4gY2xhc3M9c2xpZGVyPjwvc3Bhbj48L2xhYmVs
PjwvZGl2PgogICAgPGJ1dHRvbiBjbGFzcz0iYnRuIHNlYyIgb25jbGljaz0ic2F2ZShbJ01DQycs
J01OQycsJ05FVE5BTUUnLCdORVROQU1FX1NIT1JUJywnU1BOJywnTklUWiddKSI+U3BlaWNoZXJu
PC9idXR0b24+CiAgICA8cCBjbGFzcz1oaW50PkRhbWl0IGRhcyBpUGhvbmUgZGFzIE5ldHogYWxz
IDxiPkhlaW1uZXR6PC9iPiBzaWVodCAoa2VpbiBSb2FtaW5nKSwgbXVzcyBkaWUgSU1TSSBkZXIg
ZVNJTSBtaXQgTUNDK01OQyBiZWdpbm5lbjogPGIgY2xhc3M9dGFnIGlkPWhwbG1uPuKAkzwvYj7i
gKY8L3A+CiAgIDwvZGl2PgogIDwvZGl2PgogPC9kaXY+CgogPGRpdiBjbGFzcz1wYW5lbCBpZD1w
LWdzbT4KICA8ZGl2IGNsYXNzPWdyaWQ+CiAgIDxkaXYgY2xhc3M9Y2FyZD4KICAgIDxoMj5HU00t
RnVuazwvaDI+CiAgICA8ZGl2IGNsYXNzPXJvdyBzdHlsZT1hbGlnbi1pdGVtczplbmQ+CiAgICAg
PGRpdj48bGFiZWw+QVJGQ048L2xhYmVsPjxpbnB1dCBpZD1HU01fQVJGQ04gb25pbnB1dD11cGRh
dGVGcmVxKCk+PC9kaXY+CiAgICAgPGRpdiBjbGFzcz1mcmVxYm94PjxkaXY+PGRpdiBjbGFzcz1i
aWcgaWQ9Z3NtX21oej7igJM8L2Rpdj48ZGl2IGNsYXNzPXNtIGlkPWdzbV9iYW5kPjwvZGl2Pjwv
ZGl2PjwvZGl2PgogICAgPC9kaXY+CiAgICA8ZGl2IGNsYXNzPWhpbnQ+MeKAkzEyNCA9IEdTTTkw
MCDCtyA1MTLigJM4ODUgPSBEQ1MxODAwPC9kaXY+CiAgICA8ZGl2IGNsYXNzPXJvdz48ZGl2Pjxs
YWJlbD5UWC1HYWluPC9sYWJlbD48aW5wdXQgaWQ9R1NNX1RYX0dBSU4+PC9kaXY+CiAgICAgPGRp
dj48bGFiZWw+UlgtR2FpbiAoMOKAkzUwKTwvbGFiZWw+PGlucHV0IGlkPUdTTV9SWF9HQUlOPjwv
ZGl2PjwvZGl2PgogICAgPGRpdiBjbGFzcz1oaW50PlJYLUdhaW4gaG9jaCA9IGVtcGZpbmRsaWNo
ZXJlciBFbXBmYW5nICh3aWNodGlnIGbDvHIgRURHRS1VcGxpbmspLjwvZGl2PgogICAgPGJ1dHRv
biBjbGFzcz1idG4gb25jbGljaz0ic2F2ZShbJ0dTTV9BUkZDTicsJ0dTTV9UWF9HQUlOJywnR1NN
X1JYX0dBSU4nXSkiPlNwZWljaGVybjwvYnV0dG9uPgogICA8L2Rpdj4KICAgPGRpdiBjbGFzcz1j
YXJkPgogICAgPGgyPkdTTS1PcHRpb25lbjwvaDI+CiAgICA8ZGl2IGNsYXNzPSJzdyBmaXJzdCI+
PGRpdiBjbGFzcz10Pk9mZmVuZSBBbm1lbGR1bmc8c21hbGw+amVkZSBTSU0gd2lyZCBlaW5nZWJ1
Y2h0PC9zbWFsbD48L2Rpdj4KICAgICA8bGFiZWwgY2xhc3M9c3dpdGNoPjxpbnB1dCB0eXBlPWNo
ZWNrYm94IGlkPUdTTV9PUEVOPjxzcGFuIGNsYXNzPXNsaWRlcj48L3NwYW4+PC9sYWJlbD48L2Rp
dj4KICAgIDxkaXYgY2xhc3M9c3c+PGRpdiBjbGFzcz10PkVER0UgLyBHUFJTLURhdGVuPHNtYWxs
PlBha2V0ZGF0ZW4gKHBjdS9zZ3NuL2dnc24pPC9zbWFsbD48L2Rpdj4KICAgICA8bGFiZWwgY2xh
c3M9c3dpdGNoPjxpbnB1dCB0eXBlPWNoZWNrYm94IGlkPUdTTV9EQVRBPjxzcGFuIGNsYXNzPXNs
aWRlcj48L3NwYW4+PC9sYWJlbD48L2Rpdj4KICAgIDxkaXYgY2xhc3M9c3c+PGRpdiBjbGFzcz10
PlNJUC1UcnVuayB6dSBBc3RlcmlzazxzbWFsbD5BbnJ1ZmUgaW5zIFZvSVAvRmVzdG5ldHo8L3Nt
YWxsPjwvZGl2PgogICAgIDxsYWJlbCBjbGFzcz1zd2l0Y2g+PGlucHV0IHR5cGU9Y2hlY2tib3gg
aWQ9R1NNX1NJUD48c3BhbiBjbGFzcz1zbGlkZXI+PC9zcGFuPjwvbGFiZWw+PC9kaXY+CiAgICA8
bGFiZWw+U0lQLVBlZXIgKEFzdGVyaXNrLUlQKTwvbGFiZWw+PGlucHV0IGlkPUdTTV9TSVBfUEVF
Uj4KICAgIDxsYWJlbD5TSVAtTG9jYWwtSVAgKGxlZXIgPSBhdXRvbWF0aXNjaCk8L2xhYmVsPjxp
bnB1dCBpZD1HU01fU0lQX0xPQ0FMPgogICAgPGJ1dHRvbiBjbGFzcz1idG4gb25jbGljaz0ic2F2
ZShbJ0dTTV9PUEVOJywnR1NNX0RBVEEnLCdHU01fU0lQJywnR1NNX1NJUF9QRUVSJywnR1NNX1NJ
UF9MT0NBTCddKSI+U3BlaWNoZXJuPC9idXR0b24+CiAgIDwvZGl2PgogICA8ZGl2IGNsYXNzPWNh
cmQ+CiAgICA8aDI+QmVncsO8w591bmdzLVNNUzwvaDI+CiAgICA8cCBjbGFzcz1zdWI+U01TIGJl
aW0gRWluYnVjaGVuIHVuZCBiZWkgTnVtbWVybnZlcmdhYmUuIFBsYXR6aGFsdGVyOiA8Y29kZT57
bmV0en08L2NvZGU+LCA8Y29kZT57bnVtbWVyfTwvY29kZT4sIDxjb2RlPntleHRlcm59PC9jb2Rl
Pi48L3A+CiAgICA8ZGl2IGNsYXNzPSJzdyBmaXJzdCI+PGRpdiBjbGFzcz10PlNNUyBha3Rpdjxz
bWFsbD5XaWxsa29tbWVuICsgTnVtbWVybi1CZXN0w6R0aWd1bmc8L3NtYWxsPjwvZGl2PgogICAg
IDxsYWJlbCBjbGFzcz1zd2l0Y2g+PGlucHV0IHR5cGU9Y2hlY2tib3ggaWQ9R1NNX1NNUz48c3Bh
biBjbGFzcz1zbGlkZXI+PC9zcGFuPjwvbGFiZWw+PC9kaXY+CiAgICA8bGFiZWw+QWJzZW5kZXIt
TnVtbWVyPC9sYWJlbD48aW5wdXQgaWQ9R1NNX1NNU19GUk9NPgogICAgPGxhYmVsPkV4dGVybmUg
Vm9yd2FobCAoPGNvZGU+e2V4dGVybn08L2NvZGU+ID0gVm9yd2FobCArIGludGVybmUgTnVtbWVy
KTwvbGFiZWw+PGlucHV0IGlkPUdTTV9TTVNfRVhUUFJFRklYPgogICAgPGxhYmVsPldpbGxrb21t
ZW5zdGV4dCAoYmVpbSBFaW5idWNoZW4pPC9sYWJlbD48aW5wdXQgaWQ9R1NNX1NNU19XRUxDT01F
PgogICAgPGxhYmVsPkJlc3TDpHRpZ3VuZyAoYmVpIE51bW1lcm52ZXJnYWJlKTwvbGFiZWw+PGlu
cHV0IGlkPUdTTV9TTVNfTlVNQkVSPgogICAgPGJ1dHRvbiBjbGFzcz1idG4gb25jbGljaz0ic2F2
ZShbJ0dTTV9TTVMnLCdHU01fU01TX0ZST00nLCdHU01fU01TX0VYVFBSRUZJWCcsJ0dTTV9TTVNf
V0VMQ09NRScsJ0dTTV9TTVNfTlVNQkVSJ10pIj5TcGVpY2hlcm48L2J1dHRvbj4KICAgIDxwIGNs
YXNzPWhpbnQ+QmVncsO8w591bmcgd2lyZCBqZSBOZXR6LVN0YXJ0IGVpbm1hbCBwcm8gU0lNIGdl
c2VuZGV0ICh3aXJrdCBzb2ZvcnQpLjwvcD4KICAgIDxkaXYgc3R5bGU9ImJvcmRlci10b3A6MXB4
IHNvbGlkIHZhcigtLWxpbmUpO21hcmdpbjoxNHB4IDAiPjwvZGl2PgogICAgPGRpdiBjbGFzcz1y
b3c+PGRpdj48bGFiZWw+VGVzdDogSU1TSTwvbGFiZWw+PGlucHV0IGlkPXNtc190ZXN0X2ltc2k+
PC9kaXY+CiAgICAgPGRpdj48bGFiZWw+VGV4dCAobGVlciA9IFdpbGxrb21tZW5zdGV4dCk8L2xh
YmVsPjxpbnB1dCBpZD1zbXNfdGVzdF90ZXh0PjwvZGl2PjwvZGl2PgogICAgPGJ1dHRvbiBjbGFz
cz0iYnRuIHNlYyIgb25jbGljaz0ic21zdGVzdCgpIj5UZXN0LVNNUyBzZW5kZW48L2J1dHRvbj4K
ICAgIDxwIGNsYXNzPWhpbnQ+U2VuZGV0IHNvZm9ydCBhbiBkaWUgSU1TSSDigJMgYXVjaCB3ZW5u
IOKAnlNNUyBha3RpdiIgYXVzIGlzdC4gR1NNIG11c3MgbGF1ZmVuLjwvcD4KICAgPC9kaXY+CiAg
PC9kaXY+CiAgPHAgY2xhc3M9aGludD5GdW5rLS9PcHRpb25zLcOEbmRlcnVuZ2VuIHdpcmtlbiBi
ZWltIG7DpGNoc3RlbiBHU00tU3RhcnQuPC9wPgogPC9kaXY+CgogPGRpdiBjbGFzcz1wYW5lbCBp
ZD1wLWx0ZT4KICA8ZGl2IGNsYXNzPWdyaWQ+CiAgIDxkaXYgY2xhc3M9Y2FyZD4KICAgIDxoMj5M
VEUtRnVuazwvaDI+CiAgICA8ZGl2IGNsYXNzPXJvdyBzdHlsZT1hbGlnbi1pdGVtczplbmQ+CiAg
ICAgPGRpdj48bGFiZWw+RUFSRkNOPC9sYWJlbD48aW5wdXQgaWQ9TFRFX0VBUkZDTiBvbmlucHV0
PXVwZGF0ZUZyZXEoKT48L2Rpdj4KICAgICA8ZGl2IGNsYXNzPWZyZXFib3g+PGRpdj48ZGl2IGNs
YXNzPWJpZyBpZD1sdGVfbWh6PuKAkzwvZGl2PjxkaXYgY2xhc3M9c20gaWQ9bHRlX2JhbmQ+PC9k
aXY+PC9kaXY+PC9kaXY+CiAgICA8L2Rpdj4KICAgIDxsYWJlbD5CYW5kYnJlaXRlIChQUkIpPC9s
YWJlbD48c2VsZWN0IGlkPUxURV9OUFJCPgogICAgIDxvcHRpb24gdmFsdWU9Nj42IMK3IDEuNCBN
SHo8L29wdGlvbj48b3B0aW9uIHZhbHVlPTE1PjE1IMK3IDMgTUh6PC9vcHRpb24+CiAgICAgPG9w
dGlvbiB2YWx1ZT0yNT4yNSDCtyA1IE1Iejwvb3B0aW9uPjxvcHRpb24gdmFsdWU9NTA+NTAgwrcg
MTAgTUh6PC9vcHRpb24+CiAgICAgPG9wdGlvbiB2YWx1ZT03NT43NSDCtyAxNSBNSHo8L29wdGlv
bj48b3B0aW9uIHZhbHVlPTEwMD4xMDAgwrcgMjAgTUh6PC9vcHRpb24+PC9zZWxlY3Q+CiAgICA8
ZGl2IGNsYXNzPWhpbnQ+U2Nod2FjaGUgSGFyZHdhcmUgKFBpKToga2xlaW4gd8OkaGxlbiAoNuKA
kzI1KS48L2Rpdj4KICAgIDxidXR0b24gY2xhc3M9YnRuIG9uY2xpY2s9InNhdmUoWydMVEVfRUFS
RkNOJywnTFRFX05QUkInXSkiPlNwZWljaGVybjwvYnV0dG9uPgogICA8L2Rpdj4KICAgPGRpdiBj
bGFzcz1jYXJkPgogICAgPGgyPkxURS1QYXJhbWV0ZXI8L2gyPgogICAgPGRpdiBjbGFzcz1yb3c+
PGRpdj48bGFiZWw+VFgtR2FpbjwvbGFiZWw+PGlucHV0IGlkPUxURV9UWF9HQUlOPjwvZGl2Pgog
ICAgIDxkaXY+PGxhYmVsPlJYLUdhaW48L2xhYmVsPjxpbnB1dCBpZD1MVEVfUlhfR0FJTj48L2Rp
dj48L2Rpdj4KICAgIDxsYWJlbD5BUE48L2xhYmVsPjxpbnB1dCBpZD1MVEVfQVBOPgogICAgPGJ1
dHRvbiBjbGFzcz1idG4gb25jbGljaz0ic2F2ZShbJ0xURV9UWF9HQUlOJywnTFRFX1JYX0dBSU4n
LCdMVEVfQVBOJ10pIj5TcGVpY2hlcm48L2J1dHRvbj4KICAgIDxwIGNsYXNzPWhpbnQ+TFRFIGJy
YXVjaHQgU0lNcyBtaXQgS2kvT1BjIChUYWIg4oCeU0lNc+KAnCkuIEtlcm46IE9wZW41R1MsIEhh
bmR5LU5ldHogMTAuNDUuMC4wLzE2IG1pdCBOQVQgaW5zIEludGVybmV0LiBCZWkg4oCeTFRFICsg
R1NN4oCcIGRhcmYgZGllIEdTTS1GcmVxdWVueiBuaWNodCBpbSBMVEUtS2FuYWwgbGllZ2VuLjwv
cD4KICAgPC9kaXY+CiAgPC9kaXY+CiA8L2Rpdj4KCiA8ZGl2IGNsYXNzPXBhbmVsIGlkPXAtc2lt
cz4KICA8ZGl2IGNsYXNzPSJjYXJkIiBzdHlsZT0ibWFyZ2luLWJvdHRvbToxNnB4Ij4KICAgPGgy
PlNJTS1EYXRlbiBlcnpldWdlbjwvaDI+CiAgIDxwIGNsYXNzPXN1Yj5Gw7xyIGVpZ2VuZSBlU0lN
LVByb2ZpbGUgKHouJm5ic3A7Qi4gc2ltbGVzc2x5KTogSU1TSSBwYXNzZW5kIHp1ciBLZW5udW5n
LCB6dWbDpGxsaWdlIFNjaGzDvHNzZWwgKEtpLCBPUCDihpIgT1BjIG5hY2ggTWlsZW5hZ2UpLCBJ
Q0NJRCBtaXQgUHLDvGZ6aWZmZXIsIFBJTi9QVUsvQURNLiBCbGVpYnQgbnVyIGltIEJyb3dzZXIs
IGJpcyBkdSBlcyDDvGJlcm5pbW1zdC48L3A+CiAgIDxkaXYgY2xhc3M9cm93Mz4KICAgIDxkaXY+
PGxhYmVsPkFuemFobCAoMeKAkzUwKTwvbGFiZWw+PGlucHV0IGlkPWdlbl9uIHR5cGU9bnVtYmVy
IG1pbj0xIG1heD01MCB2YWx1ZT0xPjwvZGl2PgogICAgPGRpdj48bGFiZWw+RXJzdGUgUnVmbnVt
bWVyIChsZWVyID0ga2VpbmUpPC9sYWJlbD48aW5wdXQgaWQ9Z2VuX25yIGlucHV0bW9kZT1udW1l
cmljIHBsYWNlaG9sZGVyPSJ6LiBCLiA5MjAxIj48L2Rpdj4KICAgIDxkaXY+PGxhYmVsPklDQ0lE
LVByw6RmaXggKGxlZXIgPSA4OStNQ0MrTU5DKTwvbGFiZWw+PGlucHV0IGlkPWdlbl9pY2NpZCBp
bnB1dG1vZGU9bnVtZXJpYz48L2Rpdj4KICAgPC9kaXY+CiAgIDxkaXYgc3R5bGU9ZGlzcGxheTpm
bGV4O2dhcDo4cHg7ZmxleC13cmFwOndyYXA+CiAgICA8YnV0dG9uIGNsYXNzPWJ0biBvbmNsaWNr
PSJzaW1nZW4oKSI+RXJ6ZXVnZW48L2J1dHRvbj4KICAgIDxidXR0b24gY2xhc3M9ImJ0biBzZWMi
IGlkPWdlbl90YWtlIG9uY2xpY2s9ImdlbnRha2UoKSIgZGlzYWJsZWQ+QWxsZSBpbiBwS09NIMO8
YmVybmVobWVuPC9idXR0b24+CiAgICA8YnV0dG9uIGNsYXNzPSJidG4gc2VjIiBpZD1nZW5fY3N2
IG9uY2xpY2s9ImdlbmRsKCdjc3YnKSIgZGlzYWJsZWQ+Q1NWPC9idXR0b24+CiAgICA8YnV0dG9u
IGNsYXNzPSJidG4gc2VjIiBpZD1nZW5fanNvbiBvbmNsaWNrPSJnZW5kbCgnanNvbicpIiBkaXNh
YmxlZD5KU09OPC9idXR0b24+CiAgIDwvZGl2PgogICA8ZGl2IGNsYXNzPWdlbndyYXA+PHRhYmxl
IGNsYXNzPWVmIGlkPWdlbl90YWI+PC90YWJsZT48L2Rpdj4KICAgPHAgY2xhc3M9aGludD5BTUYg
ODAwMCwgU1FOLVN0YXJ0IDAwMDAwMDAwMDAyMCwgQWxnb3JpdGhtdXMgTWlsZW5hZ2UuIEltIGVT
SU0tUHJvZmlsIGRpZSBJTVNJLCBLaSB1bmQgT1BjIChvZGVyIE9QKSBlaW50cmFnZW47IGRhenUg
U1BOL1BOTi9PUEwgYXVzIGRlbSBUYWIg4oCeU0lNLVByb2ZpbOKAnC48L3A+CiAgPC9kaXY+CiAg
PGRpdiBjbGFzcz1ncmlkPgogICA8ZGl2IGNsYXNzPWNhcmQ+CiAgICA8aDI+U0lNIGVpbnRyYWdl
bjwvaDI+CiAgICA8cCBjbGFzcz1zdWI+RWlubWFsIGVpbnRyYWdlbiDigJMgcEtPTSBzY2hyZWli
dCBzaWUgYXV0b21hdGlzY2ggaW5zIEdTTS1ITFIgdW5kIGluIGRlbiBMVEUtSFNTLjwvcD4KICAg
IDxkaXYgY2xhc3M9cm93PjxkaXY+PGxhYmVsPklNU0k8L2xhYmVsPjxpbnB1dCBpZD1zaW1faW1z
aSBpbnB1dG1vZGU9bnVtZXJpYz48L2Rpdj48ZGl2PjxsYWJlbD5SdWZudW1tZXI8L2xhYmVsPjxp
bnB1dCBpZD1zaW1fbnIgaW5wdXRtb2RlPW51bWVyaWM+PC9kaXY+PC9kaXY+CiAgICA8ZGl2IGNs
YXNzPXJvdz48ZGl2PjxsYWJlbD5LaSAoMzIgSGV4KTwvbGFiZWw+PGlucHV0IGlkPXNpbV9raSBh
dXRvY29tcGxldGU9b2ZmPjwvZGl2PjxkaXY+PGxhYmVsPk9QYyAoMzIgSGV4KTwvbGFiZWw+PGlu
cHV0IGlkPXNpbV9vcGMgYXV0b2NvbXBsZXRlPW9mZj48L2Rpdj48L2Rpdj4KICAgIDxidXR0b24g
Y2xhc3M9ImJ0biBzbSIgb25jbGljaz0ic2ltYWRkKCkiPlNJTSBzcGVpY2hlcm48L2J1dHRvbj4K
ICAgIDxkaXYgc3R5bGU9bWFyZ2luLXRvcDoxMnB4IGlkPXNpbXM+PC9kaXY+CiAgIDwvZGl2Pgog
ICA8ZGl2IGNsYXNzPWNhcmQ+CiAgICA8aDI+RWluZ2VidWNodGUgSGFuZHlzPC9oMj4KICAgIDxw
IGNsYXNzPXN1Yj5Ba3R1ZWxsIGltIFNwcmFjaG5ldHogKE1TQykgYW5nZW1lbGRldCDigJMgYmVp
IOKAnkxURSArIEdTTeKAnCBhdWNoIMO8YmVyIExURS9TR3MuPC9wPgogICAgPGRpdiBpZD1hdHRh
Y2hlZD48L2Rpdj4KICAgPC9kaXY+CiAgIDxkaXYgY2xhc3M9Y2FyZD4KICAgIDxoMj5OdW1tZXIg
ZGF1ZXJoYWZ0IHp1d2Vpc2VuPC9oMj4KICAgIDxwIGNsYXNzPXN1Yj5BdWNoIGbDvHIgb2ZmZW4g
YW5nZW1lbGRldGUgR1NNLVNJTXMgb2huZSBLaSDigJMgw7xiZXJsZWJ0IE5ldXN0YXJ0cy48L3A+
CiAgICA8ZGl2IGNsYXNzPXJvdz48ZGl2PjxsYWJlbD5JTVNJPC9sYWJlbD48aW5wdXQgaWQ9Z251
bV9pbXNpPjwvZGl2PjxkaXY+PGxhYmVsPlJ1Zm51bW1lcjwvbGFiZWw+PGlucHV0IGlkPWdudW1f
bnI+PC9kaXY+PC9kaXY+CiAgICA8YnV0dG9uIGNsYXNzPSJidG4gc20iIG9uY2xpY2s9InNpbW5y
KCkiPlp1d2Vpc2VuPC9idXR0b24+CiAgICA8ZGl2IHN0eWxlPW1hcmdpbi10b3A6MTJweCBpZD1n
c21fbnVtYmVycz48L2Rpdj4KICAgPC9kaXY+CiAgPC9kaXY+CiA8L2Rpdj4KCiA8ZGl2IGNsYXNz
PXBhbmVsIGlkPXAtcHJvZmlsPgogIDxkaXYgY2xhc3M9Y2FyZD4KICAgPGgyPldlcnRlIGbDvHIg
ZGFzIGVTSU0tUHJvZmlsPC9oMj4KICAgPHAgY2xhc3M9c3ViPk9QTCwgUE5OIHVuZCBTUE4gc2lu
ZCBEYXRlaWVuIDxiPmF1ZiBkZXIgU0lNPC9iPiDigJMgZGFzIE5ldHoga2FubiBzaWUgbmljaHQg
c2V0emVuLiBEaWVzZSBXZXJ0ZSBwYXNzZW4genUgS2VubnVuZyB1bmQgTmV0em5hbWUgb2JlbiB1
bmQgd2VyZGVuIGltIGVTSU0tUHJvZmlsICh6LiZuYnNwO0IuIHNpbWxlc3NseSkgZWluZ2V0cmFn
ZW4uIE5JVFogc2NoaWNrdCBwS09NIHNlbGJzdC48L3A+CiAgIDx0YWJsZSBjbGFzcz1lZj4KICAg
IDx0cj48dGg+RGF0ZWk8L3RoPjx0aD5JbmhhbHQ8L3RoPjx0aD5XZXJ0IChIZXgpPC90aD48L3Ry
PgogICAgPHRyPjx0ZD48Yj5TUE48L2I+PGJyPjxzcGFuIGNsYXNzPW11dD5FRiA2RjQ2PC9zcGFu
PjwvdGQ+PHRkIGlkPWVmX3Nwbl90PjwvdGQ+PHRkPjxjb2RlIGlkPWVmX3Nwbj48L2NvZGU+PC90
ZD48L3RyPgogICAgPHRyPjx0ZD48Yj5QTk48L2I+PGJyPjxzcGFuIGNsYXNzPW11dD5FRiA2RkM1
LCBFaW50cmFnIDE8L3NwYW4+PC90ZD48dGQgaWQ9ZWZfcG5uX3Q+PC90ZD48dGQ+PGNvZGUgaWQ9
ZWZfcG5uPjwvY29kZT48L3RkPjwvdHI+CiAgICA8dHI+PHRkPjxiPk9QTDwvYj48YnI+PHNwYW4g
Y2xhc3M9bXV0PkVGIDZGQzYsIEVpbnRyYWcgMTwvc3Bhbj48L3RkPjx0ZCBpZD1lZl9vcGxfdD48
L3RkPjx0ZD48Y29kZSBpZD1lZl9vcGw+PC9jb2RlPjwvdGQ+PC90cj4KICAgIDx0cj48dGQ+PGI+
SFBMTU48L2I+PGJyPjxzcGFuIGNsYXNzPW11dD5JTVNJLUFuZmFuZzwvc3Bhbj48L3RkPjx0ZD5I
ZWltbmV0ei1LZW5udW5nPC90ZD48dGQ+PGNvZGUgaWQ9ZWZfaHBsbW4+PC9jb2RlPjwvdGQ+PC90
cj4KICAgPC90YWJsZT4KICAgPHAgY2xhc3M9aGludD5EYXRlbnPDpHR6ZSBiZWkgZmVzdGVyIEzD
pG5nZSBtaXQgPGNvZGU+RkY8L2NvZGU+IGF1ZmbDvGxsZW4uIEluIGRlciBVU0lNLURpZW5zdHRh
YmVsbGUgKFVTVCkgbcO8c3NlbiBkaWUgRGllbnN0ZSA8Yj4xNzwvYj4gKFNQTiksIDxiPjQ1PC9i
PiAoUE5OKSB1bmQgPGI+NDY8L2I+IChPUEwpIGFrdGl2IHNlaW4uIMOEbmRlcm4gc2ljaCBLZW5u
dW5nIG9kZXIgTmFtZSwgZGllIFdlcnRlIGhpZXIgbmV1IMO8YmVybmVobWVuLjwvcD4KICA8L2Rp
dj4KIDwvZGl2PgoKIDxkaXYgY2xhc3M9cGFuZWwgaWQ9cC1sb2c+CiAgPGRpdiBjbGFzcz1jYXJk
PgogICA8ZGl2IGNsYXNzPXRvb2xiYXI+PGgyIHN0eWxlPW1hcmdpbjowPlByb3Rva29sbDwvaDI+
PGlucHV0IGlkPWxvZ2ZpbHRlciBwbGFjZWhvbGRlcj0iZmlsdGVybuKApiB6LkIuIEdQUlMsIFRC
RiwgZXJyb3IiIG9uaW5wdXQ9cmVuZGVybG9nKCk+PHNwYW4gY2xhc3M9YmFkZ2UgaWQ9bG9nY291
bnQ+PC9zcGFuPjwvZGl2PgogICA8ZGl2IGNsYXNzPWxvZyBpZD1sb2c+PC9kaXY+CiAgPC9kaXY+
CiA8L2Rpdj4KPC9kaXY+CjxzY3JpcHQ+CmxldCBTPXt9Owphc3luYyBmdW5jdGlvbiBhcGkoYyxi
KXtjb25zdCByPWF3YWl0IGZldGNoKCcvYXBpLycrYyx7bWV0aG9kOidQT1NUJyxoZWFkZXJzOnsn
Q29udGVudC1UeXBlJzonYXBwbGljYXRpb24vanNvbid9LGJvZHk6SlNPTi5zdHJpbmdpZnkoYnx8
e30pfSk7cmV0dXJuIHIuanNvbigpO30KZnVuY3Rpb24gJChpKXtyZXR1cm4gZG9jdW1lbnQuZ2V0
RWxlbWVudEJ5SWQoaSk7fQpmdW5jdGlvbiBlc2Mocyl7cmV0dXJuIFN0cmluZyhzPT1udWxsPycn
OnMpLnJlcGxhY2UoL1smPD4iJ10vZyxjPT4oeycmJzonJmFtcDsnLCc8JzonJmx0OycsJz4nOicm
Z3Q7JywnIic6JyZxdW90OycsIiciOicmIzM5Oyd9W2NdKSk7fQpmdW5jdGlvbiBjbWQoYyl7aWYo
Yy5zdGFydHNXaXRoKCdzdGFydCcpKSQoJ21zZycpLnRleHRDb250ZW50PSdzdGFydGV04oCmJzth
cGkoYykudGhlbihyPT57aWYoYz09PSdsaW1lX3NjYW4nKWxpbWVLZXk9Jyc7cmVuZGVyKHIpO30p
O30KZnVuY3Rpb24gdGFiKG4pe2RvY3VtZW50LnF1ZXJ5U2VsZWN0b3JBbGwoJy50YWInKS5mb3JF
YWNoKHQ9PnQuY2xhc3NMaXN0LnRvZ2dsZSgnc2VsJyx0LmRhdGFzZXQudD09PW4pKTtkb2N1bWVu
dC5xdWVyeVNlbGVjdG9yQWxsKCcucGFuZWwnKS5mb3JFYWNoKHA9PnAuY2xhc3NMaXN0LnRvZ2ds
ZSgnc2VsJyxwLmlkPT09J3AtJytuKSk7dHJ5e2xvY2FsU3RvcmFnZS5zZXRJdGVtKCdwa29tX3Rh
Yicsbik7fWNhdGNoKGUpe319CmZ1bmN0aW9uIHNhdmUoa2V5cyl7bGV0IGI9e307a2V5cy5mb3JF
YWNoKGs9PntsZXQgZWw9JChrKTtiW2tdPWVsLnR5cGU9PT0nY2hlY2tib3gnPyhlbC5jaGVja2Vk
PycxJzonMCcpOmVsLnZhbHVlO30pO2FwaSgnc2V0JyxiKS50aGVuKHI9PntmaWxsZWQ9ZmFsc2U7
cmVuZGVyKHIpO30pO30KZnVuY3Rpb24gc2ltYWRkKCl7YXBpKCdzaW1fYWRkJyx7aW1zaTokKCdz
aW1faW1zaScpLnZhbHVlLGtpOiQoJ3NpbV9raScpLnZhbHVlLG9wYzokKCdzaW1fb3BjJykudmFs
dWUsbXNpc2RuOiQoJ3NpbV9ucicpLnZhbHVlfSkudGhlbihyPT57aWYoIS9hYmVyfHBydWVmZW4v
LnRlc3Qoci5tc2d8fCcnKSl7WydzaW1faW1zaScsJ3NpbV9raScsJ3NpbV9vcGMnLCdzaW1fbnIn
XS5mb3JFYWNoKGk9PiQoaSkudmFsdWU9JycpO31yZW5kZXIocik7fSk7fQpmdW5jdGlvbiBzaW1u
cigpe2FwaSgnZ3NtX3NpbV9ucicse2ltc2k6JCgnZ251bV9pbXNpJykudmFsdWUsbXNpc2RuOiQo
J2dudW1fbnInKS52YWx1ZX0pLnRoZW4ocmVuZGVyKTt9CmZ1bmN0aW9uIHNtc3Rlc3QoKXthcGko
J3Ntc190ZXN0Jyx7aW1zaTokKCdzbXNfdGVzdF9pbXNpJykudmFsdWUsdGV4dDokKCdzbXNfdGVz
dF90ZXh0JykudmFsdWV9KS50aGVuKHJlbmRlcik7fQpmdW5jdGlvbiBzaW1kZWwoaSl7aWYoY29u
ZmlybSgnU0lNICcraSsnIGF1cyBHU00gdW5kIExURSBsw7ZzY2hlbj8nKSlhcGkoJ3NpbV9kZWwn
LHtpbXNpOml9KS50aGVuKHJlbmRlcik7fQpmdW5jdGlvbiBudW1kZWwoaSl7YXBpKCdnc21fbnVt
X2RlbCcse2ltc2k6aX0pLnRoZW4ocmVuZGVyKTt9CmZ1bmN0aW9uIGdzbUluZm8oYSl7YT0rYXx8
MDtsZXQgbT0wLGI9Jyc7aWYoYT49MSYmYTw9MTI0KXttPTkzNSswLjIqYTtiPSdHU005MDAnO31l
bHNlIGlmKGE+PTUxMiYmYTw9ODg1KXttPTE4MDUuMiswLjIqKGEtNTEyKTtiPSdEQ1MxODAwJzt9
cmV0dXJue21oejptP20udG9GaXhlZCgxKSsnIE1Ieic6J+KAkycsYmFuZDpifTt9CmZ1bmN0aW9u
IGx0ZUluZm8oZSl7ZT0rZXx8MDtsZXQgbT0wLGI9MDtpZihlPj0wJiZlPD01OTkpe209MjExMCsw
LjEqZTtiPTE7fWVsc2UgaWYoZT49MTIwMCYmZTw9MTk0OSl7bT0xODA1KzAuMSooZS0xMjAwKTti
PTM7fWVsc2UgaWYoZT49Mjc1MCYmZTw9MzQ0OSl7bT0yNjIwKzAuMSooZS0yNzUwKTtiPTc7fWVs
c2UgaWYoZT49NjE1MCYmZTw9NjQ0OSl7bT03OTErMC4xKihlLTYxNTApO2I9MjA7fXJldHVybntt
aHo6bT9tLnRvRml4ZWQoMSkrJyBNSHonOifigJMnLGJhbmQ6Yj8nQmFuZCAnK2I6Jyd9O30KZnVu
Y3Rpb24gdXBkYXRlRnJlcSgpe2xldCBnPWdzbUluZm8oJCgnR1NNX0FSRkNOJykudmFsdWUpOyQo
J2dzbV9taHonKS50ZXh0Q29udGVudD1nLm1oejskKCdnc21fYmFuZCcpLnRleHRDb250ZW50PWcu
YmFuZDtsZXQgbD1sdGVJbmZvKCQoJ0xURV9FQVJGQ04nKS52YWx1ZSk7JCgnbHRlX21oeicpLnRl
eHRDb250ZW50PWwubWh6OyQoJ2x0ZV9iYW5kJykudGV4dENvbnRlbnQ9bC5iYW5kO30KZnVuY3Rp
b24gc2V0dihpZCx2KXtsZXQgZWw9JChpZCk7aWYoIWVsKXJldHVybjtpZihlbC50eXBlPT09J2No
ZWNrYm94JyllbC5jaGVja2VkPSh2PT09JzEnfHx2PT09dHJ1ZSk7ZWxzZSBlbC52YWx1ZT0odj09
bnVsbD8nJzp2KTt9CmNvbnN0IEZJRUxEUz1bJ01DQycsJ01OQycsJ05FVE5BTUUnLCdORVROQU1F
X1NIT1JUJywnU1BOJywnTklUWicsJ0dTTV9ERVYnLCdMVEVfREVWJywnR1NNX0FSRkNOJywnR1NN
X1RYX0dBSU4nLCdHU01fUlhfR0FJTicsJ0dTTV9TSVBfUEVFUicsJ0dTTV9TSVBfTE9DQUwnLCdH
U01fT1BFTicsJ0dTTV9EQVRBJywnR1NNX1NJUCcsJ0dTTV9TTVMnLCdHU01fU01TX0ZST00nLCdH
U01fU01TX0VYVFBSRUZJWCcsJ0dTTV9TTVNfV0VMQ09NRScsJ0dTTV9TTVNfTlVNQkVSJywnTFRF
X0VBUkZDTicsJ0xURV9OUFJCJywnTFRFX1RYX0dBSU4nLCdMVEVfUlhfR0FJTicsJ0xURV9BUE4n
XTsKbGV0IGZpbGxlZD1mYWxzZSxsaW1lS2V5PScnOwpmdW5jdGlvbiBsaW1lT3B0aW9ucyhzKXsK
IGNvbnN0IEw9cy5saW1lc3x8W10sYz1zLmNvbmZ8fHt9LGtleT1KU09OLnN0cmluZ2lmeShMKSso
Yy5HU01fREVWfHwnJykrKGMuTFRFX0RFVnx8JycpOwogaWYoa2V5PT09bGltZUtleSlyZXR1cm47
bGltZUtleT1rZXk7CiBbJ0dTTV9ERVYnLCdMVEVfREVWJ10uZm9yRWFjaChpZD0+e2NvbnN0IGVs
PSQoaWQpLGN1cj1jW2lkXXx8Jyc7CiAgbGV0IG89JzxvcHRpb24gdmFsdWU9IiI+YXV0b21hdGlz
Y2g8L29wdGlvbj4nK0wubWFwKGQ9Pic8b3B0aW9uIHZhbHVlPSInK2VzYyhkLnNlcmlhbCkrJyI+
Jytlc2MoZC5uYW1lKSsnIMK3ICcrZXNjKGQuc2VyaWFsKSsoZC5tZWRpYT8nIMK3ICcrZXNjKGQu
bWVkaWEpOicnKSsnPC9vcHRpb24+Jykuam9pbignJyk7CiAgaWYoY3VyJiYhTC5zb21lKGQ9PmQu
c2VyaWFsPT09Y3VyKSlvKz0nPG9wdGlvbiB2YWx1ZT0iJytlc2MoY3VyKSsnIj4nK2VzYyhjdXIp
KycgKG5pY2h0IGdlZnVuZGVuKTwvb3B0aW9uPic7CiAgZWwuaW5uZXJIVE1MPW87ZWwudmFsdWU9
Y3VyO30pOwogJCgnbGltZWxpc3QnKS50ZXh0Q29udGVudD1MLmxlbmd0aD9MLmxlbmd0aCsnIExp
bWVTRFIgYW5nZXNjaGxvc3Nlbic6J0tlaW4gTGltZVNEUiBnZWZ1bmRlbiDigJMgVVNCIHByw7xm
ZW4gdW5kIOKAnk5ldSBzdWNoZW7igJwuJzsKfQpmdW5jdGlvbiByZWxvYWRGaWVsZHMoKXtjb25z
dCBjPVMuY29uZnx8e307RklFTERTLmZvckVhY2goaz0+e2lmKGRvY3VtZW50LmFjdGl2ZUVsZW1l
bnQhPT0kKGspKXNldHYoayxjW2tdKTt9KTtmaWxsZWQ9dHJ1ZTt1cGRhdGVGcmVxKCk7fQpmdW5j
dGlvbiBmbXQocyl7Y29uc3QgbT1NYXRoLmZsb29yKHMvNjApLGg9TWF0aC5mbG9vcihtLzYwKTty
ZXR1cm4gaD9oKydoICcrKG0lNjApKydtJzoobT9tKydtICcrKHMlNjApKydzJzpzKydzJyk7fQpm
dW5jdGlvbiByZW5kZXJsb2coKXtjb25zdCBmPSgkKCdsb2dmaWx0ZXInKS52YWx1ZXx8JycpLnRv
TG93ZXJDYXNlKCk7bGV0IEw9KFMubG9nfHxbXSk7aWYoZilMPUwuZmlsdGVyKHg9PngudG9Mb3dl
ckNhc2UoKS5pbmNsdWRlcyhmKSk7Y29uc3QgbGc9JCgnbG9nJyk7Y29uc3QgbmVhcj1sZy5zY3Jv
bGxUb3ArbGcuY2xpZW50SGVpZ2h0Pj1sZy5zY3JvbGxIZWlnaHQtNDA7bGcudGV4dENvbnRlbnQ9
TC5qb2luKCdcbicpOyQoJ2xvZ2NvdW50JykudGV4dENvbnRlbnQ9TC5sZW5ndGgrJyBaZWlsZW4n
O2lmKG5lYXIpbGcuc2Nyb2xsVG9wPWxnLnNjcm9sbEhlaWdodDt9CmZ1bmN0aW9uIHJlbmRlcihz
KXtTPXM7bGltZU9wdGlvbnMocyk7aWYoIWZpbGxlZClyZWxvYWRGaWVsZHMoKTsKIGNvbnN0IHJ1
bj1zLnN0YXRlPT09J2xhZXVmdCcsdD1zLnRlY2g7CiAkKCdkb3QnKS5jbGFzc05hbWU9J2RvdCAn
KyhydW4/J29uJzoocy5zdGF0ZT09PSdmZWhsZXInPydlcnInOicnKSk7CiAkKCdzdGF0ZScpLnRl
eHRDb250ZW50PXMuc3RhdGU7JCgnbXNnJykudGV4dENvbnRlbnQ9cy5tc2d8fCcnOwogY29uc3Qg
dGI9JCgndGVjaGJhZGdlJyk7aWYodCl7dGIuc3R5bGUuZGlzcGxheT0nJzt0Yi50ZXh0Q29udGVu
dD10PT09J2NzZmInPydMVEUrR1NNJzp0LnRvVXBwZXJDYXNlKCk7fWVsc2UgdGIuc3R5bGUuZGlz
cGxheT0nbm9uZSc7CiBsZXQgZnJlcT0n4oCTJyxmc3ViPScnOwogY29uc3QgZ2Y9cy5nc20ubWh6
KycgTUh6JyxsZj1zLmx0ZS5taHorJyBNSHonOwogaWYodD09PSdsdGUnKXtmcmVxPWxmO2ZzdWI9
J0JhbmQgJytzLmx0ZS5iYW5kKycgwrcgRUFSRkNOICcrcy5sdGUuZWFyZmNuO30KIGVsc2UgaWYo
dD09PSdnc20nKXtmcmVxPWdmO2ZzdWI9cy5nc20uYmFuZCsnIMK3IEFSRkNOICcrcy5nc20uYXJm
Y247fQogZWxzZSBpZih0PT09J2NzZmInKXtmcmVxPWxmKycgLyAnK2dmO2ZzdWI9J0xURSBCJytz
Lmx0ZS5iYW5kKycgwrcgR1NNIEFSRkNOICcrcy5nc20uYXJmY247fQogJCgnZnJlcScpLnRleHRD
b250ZW50PWZyZXE7JCgnZnJlcTInKS50ZXh0Q29udGVudD1mcmVxOyQoJ2ZyZXFzdWInKS50ZXh0
Q29udGVudD1mc3ViOwogJCgndGVjaDInKS50ZXh0Q29udGVudD10Pyh0PT09J2NzZmInPydMVEUr
R1NNJzp0LnRvVXBwZXJDYXNlKCkpOidhdXMnOyQoJ3N0YXRlc3ViJykudGV4dENvbnRlbnQ9cy5z
dGF0ZTsKICQoJ3VwdGltZScpLnRleHRDb250ZW50PXMudXB0aW1lP2ZtdChzLnVwdGltZSk6J+KA
kyc7JCgndXB0aW1laGludCcpLnRleHRDb250ZW50PXJ1bj8oJ2zDpHVmdCBzZWl0ICcrZm10KHMu
dXB0aW1lKSk6Jyc7CiAkKCdkZXZoaW50JykuaW5uZXJIVE1MPVtzLmRldi5nc20/J0dTTS1GdW5r
OiA8Yj4nK2VzYyhzLmRldi5nc20pKyc8L2I+JzonJyxzLmRldi5sdGU/J0xURS1GdW5rOiA8Yj4n
K2VzYyhzLmRldi5sdGUpKyc8L2I+JzonJ10uZmlsdGVyKEJvb2xlYW4pLmpvaW4oJzxicj4nKTsK
ICQoJ2NsYXNoJykudGV4dENvbnRlbnQ9cy5jbGFzaHx8Jyc7CiBbWydnc20nLCdPc21vY29tJ10s
WydsdGUnLCdzcnNSQU4gKyBPcGVuNUdTJ10sWydjc2ZiJywnSW50ZXJuZXQgKyBBbnJ1ZmUgKENT
RkIpJ11dLmZvckVhY2goKFtrLGRdKT0+eyQoJ2J0bl8nK2spLmNsYXNzTGlzdC50b2dnbGUoJ2Fj
dGl2ZScsdD09PWspOyQoaysnX3N1YicpLnRleHRDb250ZW50PXQ9PT1rPydsw6R1ZnQnOmQ7fSk7
CiAkKCd0eicpLnRleHRDb250ZW50PXMudHp8fCfigJMnOwogY29uc3QgZj1zLnNpbWZpbGVzfHx7
fTskKCdocGxtbicpLnRleHRDb250ZW50PWYuaHBsbW58fCfigJMnOwogJCgnZWZfc3BuJykudGV4
dENvbnRlbnQ9Zi5zcG58fCcnOyQoJ2VmX3Nwbl90JykudGV4dENvbnRlbnQ9J+KAnicrKGYuc3Bu
X3RleHR8fCcnKSsn4oCcJzsKICQoJ2VmX3BubicpLnRleHRDb250ZW50PWYucG5ufHwnJzskKCdl
Zl9wbm5fdCcpLnRleHRDb250ZW50PSdsYW5nIOKAnicrKGYuZnVsbHx8JycpKyfigJwsIGt1cnog
4oCeJysoZi5zaG9ydHx8JycpKyfigJwnOwogJCgnZWZfb3BsJykudGV4dENvbnRlbnQ9Zi5vcGx8
fCcnOyQoJ2VmX29wbF90JykudGV4dENvbnRlbnQ9J0tlbm51bmcgJysoZi5ocGxtbnx8JycpKycs
IGFsbGUgR2ViaWV0ZSDihpIgUE5OIDEnOwogJCgnZWZfaHBsbW4nKS50ZXh0Q29udGVudD1mLmhw
bG1ufHwnJzsKICQoJ2dzbV9udW1iZXJzJykuaW5uZXJIVE1MPU9iamVjdC5lbnRyaWVzKHMuZ3Nt
Lm51bWJlcnN8fHt9KS5tYXAoZT0+JzxkaXYgY2xhc3M9bGlzdHJvdz48c3BhbiBjbGFzcz10YWc+
Jytlc2MoZVswXSkrJyDihpIgPGI+Jytlc2MoZVsxXSkrJzwvYj48L3NwYW4+PGJ1dHRvbiBjbGFz
cz14IG9uY2xpY2s9Im51bWRlbChcJycrZXNjKGVbMF0pKydcJykiPmzDtnNjaGVuPC9idXR0b24+
PC9kaXY+Jykuam9pbignJyl8fCc8ZGl2IGNsYXNzPWVtcHR5PmtlaW5lIFp1d2Vpc3VuZ2VuPC9k
aXY+JzsKICQoJ2F0dGFjaGVkJykuaW5uZXJIVE1MPShzLmdzbS5hdHRhY2hlZHx8W10pLm1hcChp
PT4nPGRpdiBjbGFzcz1saXN0cm93PjxzcGFuIGNsYXNzPXRhZz4nK2VzYyhpKSsnPC9zcGFuPjxz
cGFuIGNsYXNzPXRhZz4nK2VzYygocy5nc20ubnVtYmVyc3x8e30pW2ldfHwnJykrJzwvc3Bhbj48
L2Rpdj4nKS5qb2luKCcnKXx8JzxkaXYgY2xhc3M9ZW1wdHk+a2VpbmUgZWluZ2VidWNodDwvZGl2
Pic7CiAkKCdzaW1zJykuaW5uZXJIVE1MPShzLnNpbXN8fFtdKS5tYXAoeD0+JzxkaXYgY2xhc3M9
bGlzdHJvdz48c3BhbiBjbGFzcz10YWc+Jytlc2MoeC5pbXNpKSsnIMK3IDxiPicrZXNjKHgubXNp
c2RuKSsnPC9iPjwvc3Bhbj48YnV0dG9uIGNsYXNzPXggb25jbGljaz0ic2ltZGVsKFwnJytlc2Mo
eC5pbXNpKSsnXCcpIj5sw7ZzY2hlbjwvYnV0dG9uPjwvZGl2PicpLmpvaW4oJycpfHwnPGRpdiBj
bGFzcz1lbXB0eT5ub2NoIGtlaW5lIFNJTSBlaW5nZXRyYWdlbjwvZGl2Pic7CiByZW5kZXJsb2co
KTsKfQpsZXQgR0VOPVtdOwpmdW5jdGlvbiBzaW1nZW4oKXthcGkoJ3NpbV9nZW4nLHtjb3VudDok
KCdnZW5fbicpLnZhbHVlLG1zaXNkbjokKCdnZW5fbnInKS52YWx1ZSxpY2NpZDokKCdnZW5faWNj
aWQnKS52YWx1ZX0pLnRoZW4ocj0+e0dFTj1yLmdlbmVyYXRlZHx8W107Z2VuZHJhdygpO3JlbmRl
cihyKTt9KTt9CmNvbnN0IEdDT0xTPVtbJ2ljY2lkJywnSUNDSUQnXSxbJ2ltc2knLCdJTVNJJ10s
WydraScsJ0tpJ10sWydvcCcsJ09QJ10sWydvcGMnLCdPUGMnXSxbJ21zaXNkbicsJ1J1Zm5yLidd
LFsncGluMScsJ1BJTjEnXSxbJ3B1azEnLCdQVUsxJ10sWydwaW4yJywnUElOMiddLFsncHVrMics
J1BVSzInXSxbJ2FkbTEnLCdBRE0xJ11dOwpmdW5jdGlvbiBnZW5kcmF3KCl7Y29uc3QgVD0kKCdn
ZW5fdGFiJyk7CiBULmlubmVySFRNTD1HRU4ubGVuZ3RoPyc8dHI+JytHQ09MUy5tYXAoYz0+Jzx0
aD4nK2NbMV0rJzwvdGg+Jykuam9pbignJykrJzx0aD48L3RoPjwvdHI+JytHRU4ubWFwKChnLGkp
PT4nPHRyPicrR0NPTFMubWFwKGM9Pic8dGQ+PGNvZGU+Jytlc2MoZ1tjWzBdXSkrJzwvY29kZT48
L3RkPicpLmpvaW4oJycpKyc8dGQ+PGJ1dHRvbiBjbGFzcz0iYnRuIHNtIHNlYyIgb25jbGljaz0i
Z2VudGFrZSgnK2krJykiPsO8YmVybmVobWVuPC9idXR0b24+PC90ZD48L3RyPicpLmpvaW4oJycp
OicnOwogWydnZW5fdGFrZScsJ2dlbl9jc3YnLCdnZW5fanNvbiddLmZvckVhY2goaWQ9PiQoaWQp
LmRpc2FibGVkPSFHRU4ubGVuZ3RoKTt9CmFzeW5jIGZ1bmN0aW9uIGdlbnRha2UoaSl7Y29uc3Qg
TD1pPT09dW5kZWZpbmVkP0dFTjpbR0VOW2ldXTtsZXQgb2s9MCxsYXN0PW51bGw7CiBmb3IoY29u
c3QgZyBvZiBMKXtsYXN0PWF3YWl0IGFwaSgnc2ltX2FkZCcse2ltc2k6Zy5pbXNpLGtpOmcua2ks
b3BjOmcub3BjLG1zaXNkbjpnLm1zaXNkbn0pO2lmKCEvYWJlcnxwcnVlZmVuLy50ZXN0KGxhc3Qu
bXNnfHwnJykpb2srKzt9CiBpZihsYXN0KXtyZW5kZXIobGFzdCk7JCgnbXNnJykudGV4dENvbnRl
bnQ9b2srJyB2b24gJytMLmxlbmd0aCsnIFNJTShzKSBpbiBwS09NIMO8YmVybm9tbWVuJysob2s8
TC5sZW5ndGg/JyDigJMgJytsYXN0Lm1zZzonJyk7fX0KZnVuY3Rpb24gZ2VuZGwoZm10KXtpZigh
R0VOLmxlbmd0aClyZXR1cm47bGV0IGRhdGEsdHlwZSxuYW1lPSdwa29tLXNpbXMtJytuZXcgRGF0
ZSgpLnRvSVNPU3RyaW5nKCkuc2xpY2UoMCwxMCk7CiBpZihmbXQ9PT0nanNvbicpe2RhdGE9SlNP
Ti5zdHJpbmdpZnkoR0VOLG51bGwsMSk7dHlwZT0nYXBwbGljYXRpb24vanNvbic7bmFtZSs9Jy5q
c29uJzt9CiBlbHNle2NvbnN0IGs9T2JqZWN0LmtleXMoR0VOWzBdKTtkYXRhPVtrLmpvaW4oJzsn
KV0uY29uY2F0KEdFTi5tYXAoZz0+ay5tYXAoeD0+Z1t4XSkuam9pbignOycpKSkuam9pbihTdHJp
bmcuZnJvbUNoYXJDb2RlKDEzLDEwKSk7dHlwZT0ndGV4dC9jc3YnO25hbWUrPScuY3N2Jzt9CiBj
b25zdCBhPWRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2EnKTthLmhyZWY9VVJMLmNyZWF0ZU9iamVj
dFVSTChuZXcgQmxvYihbZGF0YV0se3R5cGV9KSk7YS5kb3dubG9hZD1uYW1lO2EuY2xpY2soKTtz
ZXRUaW1lb3V0KCgpPT5VUkwucmV2b2tlT2JqZWN0VVJMKGEuaHJlZiksMjAwMCk7fQphc3luYyBm
dW5jdGlvbiBwb2xsKCl7dHJ5e3JlbmRlcihhd2FpdCBhcGkoJ3N0YXR1cycpKTt9Y2F0Y2goZSl7
fX0KdHJ5e2NvbnN0IHQ9bG9jYWxTdG9yYWdlLmdldEl0ZW0oJ3Brb21fdGFiJyk7aWYodCYmJCgn
cC0nK3QpKXRhYih0KTt9Y2F0Y2goZSl7fQpwb2xsKCk7c2V0SW50ZXJ2YWwocG9sbCwyNTAwKTsK
PC9zY3JpcHQ+PC9ib2R5PjwvaHRtbD4iIiIKCmNsYXNzIEhhbmRsZXIoQmFzZUhUVFBSZXF1ZXN0
SGFuZGxlcik6CiAgICBkZWYgbG9nX21lc3NhZ2Uoc2VsZiwgKmEpOiBwYXNzCiAgICBkZWYgX3Nl
bmQoc2VsZiwgY29kZSwgYm9keSwgY3R5cGU9ImFwcGxpY2F0aW9uL2pzb24iKToKICAgICAgICBi
ID0gYm9keS5lbmNvZGUoKSBpZiBpc2luc3RhbmNlKGJvZHksIHN0cikgZWxzZSBib2R5CiAgICAg
ICAgc2VsZi5zZW5kX3Jlc3BvbnNlKGNvZGUpCiAgICAgICAgc2VsZi5zZW5kX2hlYWRlcigiQ29u
dGVudC1UeXBlIiwgY3R5cGUpCiAgICAgICAgc2VsZi5zZW5kX2hlYWRlcigiQ29udGVudC1MZW5n
dGgiLCBzdHIobGVuKGIpKSkKICAgICAgICBzZWxmLmVuZF9oZWFkZXJzKCkKICAgICAgICB0cnk6
IHNlbGYud2ZpbGUud3JpdGUoYikKICAgICAgICBleGNlcHQgRXhjZXB0aW9uOiBwYXNzCiAgICBk
ZWYgZG9fR0VUKHNlbGYpOgogICAgICAgIGlmIHNlbGYucGF0aCBpbiAoIi8iLCAiL2luZGV4Lmh0
bWwiKToKICAgICAgICAgICAgc2VsZi5fc2VuZCgyMDAsIFBBR0UsICJ0ZXh0L2h0bWw7IGNoYXJz
ZXQ9dXRmLTgiKQogICAgICAgIGVsaWYgc2VsZi5wYXRoID09ICIvYXBpL3N0YXR1cyI6CiAgICAg
ICAgICAgIHNlbGYuX3NlbmQoMjAwLCBqc29uLmR1bXBzKE5FVC5zdGF0dXMoKSkpCiAgICAgICAg
ZWxzZToKICAgICAgICAgICAgc2VsZi5fc2VuZCg0MDQsICJ7fSIpCiAgICBkZWYgZG9fUE9TVChz
ZWxmKToKICAgICAgICBuID0gaW50KHNlbGYuaGVhZGVycy5nZXQoIkNvbnRlbnQtTGVuZ3RoIiwg
MCkgb3IgMCkKICAgICAgICBib2R5ID0gc2VsZi5yZmlsZS5yZWFkKG4pLmRlY29kZShlcnJvcnM9
InJlcGxhY2UiKSBpZiBuIGVsc2UgIiIKICAgICAgICBpZiBzZWxmLnBhdGguc3RhcnRzd2l0aCgi
L2FwaS8iKToKICAgICAgICAgICAgdHJ5OgogICAgICAgICAgICAgICAgc2VsZi5fc2VuZCgyMDAs
IGpzb24uZHVtcHMoaGFuZGxlX2FwaShzZWxmLnBhdGgsIGJvZHkpKSkKICAgICAgICAgICAgZXhj
ZXB0IEV4Y2VwdGlvbiBhcyBlOgogICAgICAgICAgICAgICAgbG9nKCJhcGk6IiwgZSk7IHNlbGYu
X3NlbmQoNTAwLCBqc29uLmR1bXBzKHsiZXJyb3IiOiBzdHIoZSl9KSkKICAgICAgICBlbHNlOgog
ICAgICAgICAgICBzZWxmLl9zZW5kKDQwNCwgInt9IikKCmRlZiBtYWluKCk6CiAgICBwb3J0ID0g
aW50KEMuZ2V0KCJXRUJfUE9SVCIsICI4MDgwIikpCiAgICBsb2coZiJnOTBuZXQgV2ViLU9iZXJm
bGFlY2hlIGF1ZiBodHRwOi8vMC4wLjAuMDp7cG9ydH0gIChGQUtFPXtGQUtFfSkiKQogICAgdGhy
ZWFkaW5nLlRocmVhZCh0YXJnZXQ9c21zX3dlbGNvbWVfd2F0Y2gsIGRhZW1vbj1UcnVlKS5zdGFy
dCgpCiAgICB0aHJlYWRpbmcuVGhyZWFkKHRhcmdldD1saW1lX3NjYW4sIGRhZW1vbj1UcnVlKS5z
dGFydCgpICAgIyBMaW1lU0RSIGZ1ZXIgZGllIEF1c3dhaGwgc3VjaGVuCiAgICB0cnk6IF9taWdy
YXRlX2x0ZV9kYigpCiAgICBleGNlcHQgRXhjZXB0aW9uIGFzIGU6IGxvZygibWlncmF0aW9uOiIs
IGUpCiAgICBUaHJlYWRpbmdIVFRQU2VydmVyKCgiMC4wLjAuMCIsIHBvcnQpLCBIYW5kbGVyKS5z
ZXJ2ZV9mb3JldmVyKCkKCmlmIF9fbmFtZV9fID09ICJfX21haW5fXyI6CiAgICBtYWluKCkK
