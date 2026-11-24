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
IDJHCiAgICAiR1NNX0FSRkNOIjogIjIwIiwgIkdTTV9CQU5EIjogIiIsICJHU01fVFhfR0FJTiI6
ICI1MCIsICJHU01fUlhfR0FJTiI6ICI0NSIsCiAgICAiR1NNX09QRU4iOiAiMSIsICJHU01fREFU
QSI6ICIwIiwgIkdTTV9TSVAiOiAiMCIsICJHU01fU0lQX1BFRVIiOiAiIiwgIkdTTV9TSVBfTE9D
QUwiOiAiIiwKICAgICMgU01TIChCZWdydWVzc3VuZyBiZWltIEVpbmJ1Y2hlbiArIEJlc3RhZXRp
Z3VuZyBiZWkgTnVtbWVybnZlcmdhYmUpCiAgICAiR1NNX1NNUyI6ICIxIiwgIkdTTV9TTVNfRlJP
TSI6ICIxMDAwIiwKICAgICMge2V4dGVybn0gPSBWb3J3YWhsLUJsb2NrICsgaW50ZXJuZSBOdW1t
ZXIgKGxlZXIgPSBudXIgZGllIGludGVybmUgTnVtbWVyKQogICAgIkdTTV9TTVNfRVhUUFJFRklY
IjogIis0OSA2NTEgNjM1NTU1IiwKICAgICJHU01fU01TX1dFTENPTUUiOiAiV2lsbGtvbW1lbiBp
bSB7bmV0en0hIER1IGJpc3QgamV0enQgZWluZ2VidWNodC4gNzMiLAogICAgIkdTTV9TTVNfTlVN
QkVSIjogIkRlaW5lIFJ1Zm51bW1lciBpbSB7bmV0en0tTmV0eiBpc3QgamV0enQge251bW1lcn0u
IEV4dGVybiBlcnJlaWNoYmFyOiB7ZXh0ZXJufSIsCiAgICAjIDRHCiAgICAiTFRFX0VBUkZDTiI6
ICIxNTc1IiwgIkxURV9OUFJCIjogIjI1IiwgIkxURV9UWF9HQUlOIjogIjgwIiwgIkxURV9SWF9H
QUlOIjogIjQwIiwKICAgICJMVEVfQVBOIjogImludGVybmV0IiwgIkxURV9UQUMiOiAiNyIsCn0K
CmRlZiBsb2FkX2NvbmYoKToKICAgIGMgPSBkaWN0KERFRkFVTFRTKQogICAgdHJ5OgogICAgICAg
IGZvciBsaW5lIGluIG9wZW4oQ09ORik6CiAgICAgICAgICAgIGxpbmUgPSBsaW5lLnN0cmlwKCkK
ICAgICAgICAgICAgaWYgbm90IGxpbmUgb3IgbGluZS5zdGFydHN3aXRoKCIjIikgb3IgIj0iIG5v
dCBpbiBsaW5lOgogICAgICAgICAgICAgICAgY29udGludWUKICAgICAgICAgICAgaywgdiA9IGxp
bmUuc3BsaXQoIj0iLCAxKQogICAgICAgICAgICBjW2suc3RyaXAoKV0gPSB2LnN0cmlwKCkuc3Ry
aXAoJyInKQogICAgZXhjZXB0IEV4Y2VwdGlvbjoKICAgICAgICBwYXNzCiAgICByZXR1cm4gYwoK
ZGVmIHNhdmVfY29uZihjKToKICAgIHRyeToKICAgICAgICBvcy5tYWtlZGlycyhvcy5wYXRoLmRp
cm5hbWUoQ09ORiksIGV4aXN0X29rPVRydWUpCiAgICAgICAgd2l0aCBvcGVuKENPTkYsICJ3Iikg
YXMgZjoKICAgICAgICAgICAgZi53cml0ZSgiIyBnOTBuZXQgLSBhdXRvbWF0aXNjaCBnZXNjaHJp
ZWJlblxuIikKICAgICAgICAgICAgZm9yIGsgaW4gc29ydGVkKGMpOgogICAgICAgICAgICAgICAg
Zi53cml0ZSgnJXM9IiVzIlxuJyAlIChrLCBjW2tdKSkKICAgIGV4Y2VwdCBFeGNlcHRpb24gYXMg
ZToKICAgICAgICBsb2coImNvbmYgc3BlaWNoZXJuOiIsIGUpCgpDID0gbG9hZF9jb25mKCkKb3Mu
bWFrZWRpcnMoV09SS0RJUiwgZXhpc3Rfb2s9VHJ1ZSkKCmRlZiBjc2V0KGssIHYpOgogICAgQ1tr
XSA9IHN0cih2KQogICAgc2F2ZV9jb25mKEMpCgpkZWYgbG9nKCphKToKICAgIHByaW50KHRpbWUu
c3RyZnRpbWUoIiVIOiVNOiVTIiksICphLCBmbHVzaD1UcnVlKQoKRkFLRSA9ICItLWZha2UiIGlu
IHN5cy5hcmd2ICAgIyBUZXN0bW9kdXMgb2huZSBlY2h0ZSBIYXJkd2FyZS9Qcm96ZXNzZQoKIyAt
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0gRnJlcXVlbnplbiAoQW56ZWlnZSkKIyBHU00tQmFlbmRlcjogaWQgLT4gKEFuemVp
Z2UsIE9zbW9jb20tQmFuZG5hbWUsIEFSRkNOLUJlcmVpY2hlLCBETChNSHopIGJlaSBBUkZDTiwg
RHVwbGV4YWJzdGFuZCkKR1NNX0JBTkRTID0gewogICAgIkdTTTg1MCI6ICAoIkdTTSA4NTAiLCAg
ICAgICAiR1NNODUwIiwgIFsoMTI4LCAyNTEpXSwgICAgICAgICAgICBsYW1iZGEgYTogODY5LjIg
KyAwLjIgKiAoYSAtIDEyOCksIDQ1KSwKICAgICJHU005MDAiOiAgKCJHU00gOTAwIChQKSIsICAg
IkdTTTkwMCIsICBbKDEsIDEyNCldLCAgICAgICAgICAgICAgbGFtYmRhIGE6IDkzNS4wICsgMC4y
ICogYSwgNDUpLAogICAgIkVHU005MDAiOiAoIkUtR1NNIDkwMCIsICAgICAiR1NNOTAwIiwgIFso
MCwgMTI0KSwgKDk3NSwgMTAyMyldLCBsYW1iZGEgYTogOTM1LjAgKyAwLjIgKiAoYSBpZiBhIDw9
IDEyNCBlbHNlIGEgLSAxMDI0KSwgNDUpLAogICAgIkRDUzE4MDAiOiAoIkRDUyAxODAwIiwgICAg
ICAiRENTMTgwMCIsIFsoNTEyLCA4ODUpXSwgICAgICAgICAgICBsYW1iZGEgYTogMTgwNS4yICsg
MC4yICogKGEgLSA1MTIpLCA5NSksCiAgICAiUENTMTkwMCI6ICgiUENTIDE5MDAiLCAgICAgICJQ
Q1MxOTAwIiwgWyg1MTIsIDgxMCldLCAgICAgICAgICAgIGxhbWJkYSBhOiAxOTMwLjIgKyAwLjIg
KiAoYSAtIDUxMiksIDgwKSwKfQojIExURS1GREQtQmFlbmRlciAoc3JzUkFOIDRHIGthbm4gbnVy
IEZERCk6IEJhbmQgLT4gKE5hbWUsIERMLVN0YXJ0IE1IeiwgTl9PZmZzLURMLCBFQVJGQ04gdm9u
LCBiaXMsIER1cGxleCBNSHopCkxURV9CQU5EUyA9IHsKICAgIDE6ICAoIjIxMDAiLCAgICAgIDIx
MTAuMCwgICAgMCwgICAgMCwgIDU5OSwgMTkwKSwKICAgIDI6ICAoIjE5MDAgUENTIiwgIDE5MzAu
MCwgIDYwMCwgIDYwMCwgMTE5OSwgIDgwKSwKICAgIDM6ICAoIjE4MDAiLCAgICAgIDE4MDUuMCwg
MTIwMCwgMTIwMCwgMTk0OSwgIDk1KSwKICAgIDQ6ICAoIkFXUyAxNzAwIiwgIDIxMTAuMCwgMTk1
MCwgMTk1MCwgMjM5OSwgNDAwKSwKICAgIDU6ICAoIjg1MCIsICAgICAgICA4NjkuMCwgMjQwMCwg
MjQwMCwgMjY0OSwgIDQ1KSwKICAgIDc6ICAoIjI2MDAiLCAgICAgIDI2MjAuMCwgMjc1MCwgMjc1
MCwgMzQ0OSwgMTIwKSwKICAgIDg6ICAoIjkwMCIsICAgICAgICA5MjUuMCwgMzQ1MCwgMzQ1MCwg
Mzc5OSwgIDQ1KSwKICAgIDEyOiAoIjcwMCBhIiwgICAgICA3MjkuMCwgNTAxMCwgNTAxMCwgNTE3
OSwgIDMwKSwKICAgIDEzOiAoIjcwMCBjIiwgICAgICA3NDYuMCwgNTE4MCwgNTE4MCwgNTI3OSwg
LTMxKSwKICAgIDE3OiAoIjcwMCBiIiwgICAgICA3MzQuMCwgNTczMCwgNTczMCwgNTg0OSwgIDMw
KSwKICAgIDIwOiAoIjgwMCBERCIsICAgICA3OTEuMCwgNjE1MCwgNjE1MCwgNjQ0OSwgLTQxKSwK
ICAgIDI1OiAoIjE5MDArIiwgICAgIDE5MzAuMCwgODA0MCwgODA0MCwgODY4OSwgIDgwKSwKICAg
IDI2OiAoIjg1MCsiLCAgICAgICA4NTkuMCwgODY5MCwgODY5MCwgOTAzOSwgIDQ1KSwKICAgIDI4
OiAoIjcwMCBBUFQiLCAgICA3NTguMCwgOTIxMCwgOTIxMCwgOTY1OSwgIDU1KSwKfQoKZGVmIF9p
bihhLCByYW5nZXMpOiByZXR1cm4gYW55KGxvIDw9IGEgPD0gaGkgZm9yIGxvLCBoaSBpbiByYW5n
ZXMpCgpkZWYgZ3NtX2JhbmQoYT1Ob25lKToKICAgICIiIkJhbmQtSUQgZnVlciBkaWUgQVJGQ046
IGdld2FlaGx0ZXMgQmFuZCwgd2VubiBkaWUgQVJGQ04gaGluZWlucGFzc3QsIHNvbnN0IGF1dG9t
YXRpc2NoLiIiIgogICAgYSA9IGludChDWyJHU01fQVJGQ04iXSBpZiBhIGlzIE5vbmUgZWxzZSBh
KQogICAgYiA9IEMuZ2V0KCJHU01fQkFORCIsICIiKQogICAgaWYgYiBpbiBHU01fQkFORFMgYW5k
IF9pbihhLCBHU01fQkFORFNbYl1bMl0pOiByZXR1cm4gYgogICAgZm9yIGsgaW4gKCJHU005MDAi
LCAiRUdTTTkwMCIsICJEQ1MxODAwIiwgIkdTTTg1MCIsICJQQ1MxOTAwIik6CiAgICAgICAgaWYg
X2luKGEsIEdTTV9CQU5EU1trXVsyXSk6IHJldHVybiBrCiAgICByZXR1cm4gIiIKCmRlZiBhcmZj
bl9iYW5kKGEpOgogICAgYiA9IGdzbV9iYW5kKGEpCiAgICByZXR1cm4gR1NNX0JBTkRTW2JdWzFd
IGlmIGIgZWxzZSAiR1NNOTAwIgoKZGVmIGFyZmNuX21oeihhLCB1bD1GYWxzZSk6CiAgICBhID0g
aW50KGEpOyBiID0gZ3NtX2JhbmQoYSkKICAgIGlmIG5vdCBiOiByZXR1cm4gMC4wCiAgICBfbCwg
X28sIF9yLCBkbCwgZHVwID0gR1NNX0JBTkRTW2JdCiAgICByZXR1cm4gcm91bmQoZGwoYSkgLSAo
ZHVwIGlmIHVsIGVsc2UgMCksIDEpCgpkZWYgZWFyZmNuX2JhbmQoZSk6CiAgICBlID0gaW50KGUp
CiAgICBmb3IgYiwgKF9uLCBfZiwgX28sIGxvLCBoaSwgX2QpIGluIExURV9CQU5EUy5pdGVtcygp
OgogICAgICAgIGlmIGxvIDw9IGUgPD0gaGk6IHJldHVybiBiCiAgICByZXR1cm4gMAoKZGVmIGVh
cmZjbl9taHooZSwgdWw9RmFsc2UpOgogICAgYiA9IGVhcmZjbl9iYW5kKGUpCiAgICBpZiBub3Qg
YjogcmV0dXJuIDAuMAogICAgX24sIGYsIG9mZiwgX2xvLCBfaGksIGR1cCA9IExURV9CQU5EU1ti
XQogICAgcmV0dXJuIHJvdW5kKGYgKyAwLjEgKiAoaW50KGUpIC0gb2ZmKSAtIChkdXAgaWYgdWwg
ZWxzZSAwKSwgMSkKCmRlZiBiYW5kX3RhYmxlcygpOgogICAgIiIiRnVlciBkYXMgV2ViaW50ZXJm
YWNlIChlaW5lIFF1ZWxsZSBmdWVyIERhZW1vbiB1bmQgQnJvd3NlcikuIiIiCiAgICBnID0gW3si
aWQiOiBrLCAibmFtZSI6IHZbMF0sICJvc21vIjogdlsxXSwgInJhbmdlcyI6IHZbMl0sICJkdXAi
OiB2WzRdLAogICAgICAgICAgImRsMCI6IFtyb3VuZCh2WzNdKGxvKSwgMSkgZm9yIGxvLCBfaGkg
aW4gdlsyXV19IGZvciBrLCB2IGluIEdTTV9CQU5EUy5pdGVtcygpXQogICAgbCA9IFt7ImJhbmQi
OiBiLCAibmFtZSI6IHZbMF0sICJmIjogdlsxXSwgIm9mZiI6IHZbMl0sICJsbyI6IHZbM10sICJo
aSI6IHZbNF0sICJkdXAiOiB2WzVdfQogICAgICAgICBmb3IgYiwgdiBpbiBMVEVfQkFORFMuaXRl
bXMoKV0KICAgIHJldHVybiB7ImdzbSI6IGcsICJsdGUiOiBsfQoKIyAtLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0gVlRZLUhp
bGZlbiAoT3Ntb2NvbSkKZGVmIHZ0eShwb3J0LCBjbWRzLCB0aW1lb3V0PTQpOgogICAgb3V0ID0g
W10KICAgIHRyeToKICAgICAgICBzID0gc29ja2V0LmNyZWF0ZV9jb25uZWN0aW9uKCgiMTI3LjAu
MC4xIiwgcG9ydCksIHRpbWVvdXQ9dGltZW91dCkKICAgICAgICBzLnNldHRpbWVvdXQodGltZW91
dCkKICAgICAgICB0aW1lLnNsZWVwKDAuMikKICAgICAgICB0cnk6IG91dC5hcHBlbmQocy5yZWN2
KDQwOTYpLmRlY29kZShlcnJvcnM9InJlcGxhY2UiKSkKICAgICAgICBleGNlcHQgRXhjZXB0aW9u
OiBwYXNzCiAgICAgICAgZm9yIGNtZCBpbiBjbWRzOgogICAgICAgICAgICBzLnNlbmRhbGwoKGNt
ZCArICJcclxuIikuZW5jb2RlKCkpOyB0aW1lLnNsZWVwKDAuMykKICAgICAgICAgICAgdHJ5OiBv
dXQuYXBwZW5kKHMucmVjdig4MTkyKS5kZWNvZGUoZXJyb3JzPSJyZXBsYWNlIikpCiAgICAgICAg
ICAgIGV4Y2VwdCBFeGNlcHRpb246IHBhc3MKICAgICAgICBzLmNsb3NlKCkKICAgIGV4Y2VwdCBF
eGNlcHRpb24gYXMgZToKICAgICAgICByZXR1cm4gIlZUWS1GZWhsZXI6ICVzIiAlIGUKICAgIHJl
dHVybiAiIi5qb2luKG91dCkKCkhMUl9WVFkgPSA0MjU4Ck1TQ19WVFkgPSA0MjU0ICAgIyBvc21v
LW1zYyBUZWxuZXQtVlRZOiBTTVMgc2VuZGVuICsgZWluZ2VidWNodGUgVGVpbG5laG1lciBhYmZy
YWdlbgoKZGVmIF9zdWIocGF0aCwgcGFpcnMpOgogICAgaWYgbm90IG9zLnBhdGguaXNmaWxlKHBh
dGgpOiByZXR1cm4KICAgIHQgPSBvcGVuKHBhdGgpLnJlYWQoKQogICAgZm9yIHBhdCwgcmVwIGlu
IHBhaXJzOgogICAgICAgIHQgPSByZS5zdWIocGF0LCByZXAsIHQsIGZsYWdzPXJlLk1VTFRJTElO
RSkKICAgIG9wZW4ocGF0aCwgInciKS53cml0ZSh0KQoKZGVmIF92dHlfc2V0KHBhdGgsIG5vZGUs
IGtleSwgZnVsbCk6CiAgICBpZiBub3Qgb3MucGF0aC5pc2ZpbGUocGF0aCk6IHJldHVybgogICAg
dCA9IG9wZW4ocGF0aCkucmVhZCgpCiAgICBpZiByZS5zZWFyY2gocmYiKD9tKV5ccyp7a2V5fShc
c3wkKSIsIHQpOgogICAgICAgIHQgPSByZS5zdWIocmYiKD9tKV5ccyp7a2V5fS4qJCIsICIgIiAr
IGZ1bGwsIHQpCiAgICBlbHNlOgogICAgICAgIHQgPSByZS5zdWIocmYiKD9tKV4oe3JlLmVzY2Fw
ZShub2RlKX1ccyopJCIsIHIiXDFcbiAiICsgZnVsbCwgdCwgY291bnQ9MSkKICAgIG9wZW4ocGF0
aCwgInciKS53cml0ZSh0KQoKZGVmIF92dHlfZGVsKHBhdGgsIGtleSk6CiAgICBpZiBub3Qgb3Mu
cGF0aC5pc2ZpbGUocGF0aCk6IHJldHVybgogICAgdCA9IG9wZW4ocGF0aCkucmVhZCgpCiAgICBv
cGVuKHBhdGgsICJ3Iikud3JpdGUocmUuc3ViKHJmIig/bSleXHMqe2tleX0uKlxuPyIsICIiLCB0
KSkKCiMgPT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
PT09PT09PT09PT09PT09IExpbWVTRFIgZnJlaSBtYWNoZW4KZGVmIF9saW1lX3NlcnZpY2UoYWN0
aW9uKToKICAgIGlmIEZBS0U6IHJldHVybgogICAgZm9yIHN2YyBpbiAoImc5MC1saW1lIiwgImc5
MGxpbWUiKToKICAgICAgICB0cnk6CiAgICAgICAgICAgIHN1YnByb2Nlc3MucnVuKFsic3lzdGVt
Y3RsIiwgYWN0aW9uLCBzdmMgKyAiLnNlcnZpY2UiXSwKICAgICAgICAgICAgICAgICAgICAgICAg
ICAgc3Rkb3V0PXN1YnByb2Nlc3MuREVWTlVMTCwgc3RkZXJyPXN1YnByb2Nlc3MuREVWTlVMTCwg
dGltZW91dD0xMCkKICAgICAgICBleGNlcHQgRXhjZXB0aW9uOiBwYXNzCgpkZWYgX2ZyZWVfbGlt
ZSgpOgogICAgIiIiQWxsZXMgYmVlbmRlbiwgd2FzIGRlbiBMaW1lU0RSIG9mZmVuIGhhZWx0LiBE
aWUgVVNCLVBsYXRpbmUgKEZYMykgTklDSFQgaGFydAogICAgcmVzZXRlbiAoZmFlbGx0IHNvbnN0
IHZvbSBCdXMpOyBiZWkgZGVyIE1pbmkgKEZUNjAxKSBoaWxmdCBlaW4gVVNCLVJlc2V0LiIiIgog
ICAgaWYgRkFLRTogcmV0dXJuCiAgICBpbXBvcnQgZmNudGwKICAgIGZvciB2aWQsIHBpZCwgaGFy
ZCBpbiAoKCIwNDAzIiwgIjYwMWYiLCBUcnVlKSwgKCIxZDUwIiwgIjYxMDgiLCBGYWxzZSkpOgog
ICAgICAgIHRyeToKICAgICAgICAgICAgb3V0ID0gc3VicHJvY2Vzcy5ydW4oWyJsc3VzYiIsICIt
ZCIsIGYie3ZpZH06e3BpZH0iXSwKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgY2Fw
dHVyZV9vdXRwdXQ9VHJ1ZSwgdGV4dD1UcnVlLCB0aW1lb3V0PTUpLnN0ZG91dAogICAgICAgICAg
ICBtID0gcmUuc2VhcmNoKHIiQnVzIChcZCspIERldmljZSAoXGQrKSIsIG91dCkKICAgICAgICAg
ICAgaWYgbm90IG06IGNvbnRpbnVlCiAgICAgICAgICAgIHBhdGggPSBmIi9kZXYvYnVzL3VzYi97
bS5ncm91cCgxKX0ve20uZ3JvdXAoMil9IgogICAgICAgICAgICB0cnk6CiAgICAgICAgICAgICAg
ICBzdWJwcm9jZXNzLnJ1bihbImZ1c2VyIiwgIi1rIiwgcGF0aF0sIHN0ZG91dD1zdWJwcm9jZXNz
LkRFVk5VTEwsCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBzdGRlcnI9c3VicHJvY2Vz
cy5ERVZOVUxMLCB0aW1lb3V0PTUpOyB0aW1lLnNsZWVwKDEuMCkKICAgICAgICAgICAgZXhjZXB0
IEV4Y2VwdGlvbjogcGFzcwogICAgICAgICAgICBpZiBoYXJkOgogICAgICAgICAgICAgICAgd2l0
aCBvcGVuKHBhdGgsICJ3YiIpIGFzIGY6IGZjbnRsLmlvY3RsKGYsIDB4NTUxNCwgMCkKICAgICAg
ICBleGNlcHQgRXhjZXB0aW9uIGFzIGU6CiAgICAgICAgICAgIGxvZygibGltZSBmcmVpOiIsIGUp
CgojID09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
PT09PT09PT09PT09PSBMaW1lU0RSLUF1c3dhaGwKIyBKZSBOZXR6IGVpbiBlaWdlbmVyIExpbWVT
RFIgKHouQi4gTGltZVNEUiBNaW5pIGZ1ZXIgR1NNLCBMaW1lU0RSIFVTQiBmdWVyIExURSkuCiMg
WnVvcmRudW5nIHVlYmVyIGRpZSBTZXJpZW5udW1tZXIgKEdTTV9ERVYgLyBMVEVfREVWKSwgbGVl
ciA9IGF1dG9tYXRpc2NoLgpMSU1FUyA9IFtdICAgICAgICAgICMgenVsZXR6dCBnZWZ1bmRlbmUg
R2VyYWV0ZSBbe3NlcmlhbCwgbmFtZSwgbWVkaWEsIC4uLn1dCgpkZWYgbGltZV9zY2FuKCk6CiAg
ICAiIiJBbmdlc2NobG9zc2VuZSBMaW1lU0RSIGZpbmRlbiAoTGltZVV0aWwsIHNvbnN0IFNvYXB5
U0RSVXRpbCkuIiIiCiAgICBnbG9iYWwgTElNRVMKICAgIGlmIEZBS0U6CiAgICAgICAgTElNRVMg
PSBbeyJzZXJpYWwiOiAiMUQzQUM0RjFBMkIzQzQiLCAibmFtZSI6ICJMaW1lU0RSIE1pbmkiLCAi
bWVkaWEiOiAiVVNCIDMuMCJ9LAogICAgICAgICAgICAgICAgIHsic2VyaWFsIjogIjAwMDkwNzAx
MDVDNjI2MkUiLCAibmFtZSI6ICJMaW1lU0RSLVVTQiIsICJtZWRpYSI6ICJVU0IgMy4wIn1dCiAg
ICAgICAgcmV0dXJuIExJTUVTCiAgICBkZXZzID0gW10KICAgIHRyeToKICAgICAgICBvdXQgPSBz
dWJwcm9jZXNzLnJ1bihbIkxpbWVVdGlsIiwgIi0tZmluZCJdLCBjYXB0dXJlX291dHB1dD1UcnVl
LCB0ZXh0PVRydWUsIHRpbWVvdXQ9MjApLnN0ZG91dAogICAgICAgIGZvciBtIGluIHJlLmZpbmRp
dGVyKHIiXFsoW15cXV0rKVxdIiwgb3V0KToKICAgICAgICAgICAgcGFydHMgPSBbcC5zdHJpcCgp
IGZvciBwIGluIG0uZ3JvdXAoMSkuc3BsaXQoIiwiKV0KICAgICAgICAgICAgZCA9IHsibmFtZSI6
IHBhcnRzWzBdfQogICAgICAgICAgICBmb3IgcCBpbiBwYXJ0c1sxOl06CiAgICAgICAgICAgICAg
ICBpZiAiPSIgaW4gcDoKICAgICAgICAgICAgICAgICAgICBrLCB2ID0gcC5zcGxpdCgiPSIsIDEp
OyBkW2suc3RyaXAoKV0gPSB2LnN0cmlwKCkKICAgICAgICAgICAgaWYgZC5nZXQoInNlcmlhbCIp
OiBkZXZzLmFwcGVuZChkKQogICAgZXhjZXB0IEV4Y2VwdGlvbiBhcyBlOgogICAgICAgIGxvZygi
TGltZVV0aWw6IiwgZSkKICAgIGlmIG5vdCBkZXZzOgogICAgICAgIHRyeToKICAgICAgICAgICAg
b3V0ID0gc3VicHJvY2Vzcy5ydW4oWyJTb2FweVNEUlV0aWwiLCAiLS1maW5kPWRyaXZlcj1saW1l
Il0sCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIGNhcHR1cmVfb3V0cHV0PVRydWUs
IHRleHQ9VHJ1ZSwgdGltZW91dD0zMCkuc3Rkb3V0CiAgICAgICAgICAgIGZvciBibGsgaW4gcmUu
c3BsaXQociJGb3VuZCBkZXZpY2UgXGQrIiwgb3V0KVsxOl06CiAgICAgICAgICAgICAgICBkID0g
ZGljdCgoay5zdHJpcCgpLCB2LnN0cmlwKCkpIGZvciBrLCB2IGluIHJlLmZpbmRhbGwociIoP20p
XlxzKihcdyspXHMqPVxzKiguKykkIiwgYmxrKSkKICAgICAgICAgICAgICAgIGlmIGQuZ2V0KCJz
ZXJpYWwiKToKICAgICAgICAgICAgICAgICAgICBkZXZzLmFwcGVuZCh7InNlcmlhbCI6IGRbInNl
cmlhbCJdLCAibWVkaWEiOiBkLmdldCgibWVkaWEiLCAiIiksCiAgICAgICAgICAgICAgICAgICAg
ICAgICAgICAgICAgICJuYW1lIjogKGQuZ2V0KCJsYWJlbCIpIG9yIGQuZ2V0KCJuYW1lIikgb3Ig
IkxpbWVTRFIiKS5zcGxpdCgiWyIpWzBdLnN0cmlwKCl9KQogICAgICAgIGV4Y2VwdCBFeGNlcHRp
b24gYXMgZToKICAgICAgICAgICAgbG9nKCJTb2FweVNEUlV0aWw6IiwgZSkKICAgIHNlZW4gPSBz
ZXQoKQogICAgTElNRVMgPSBbZCBmb3IgZCBpbiBkZXZzIGlmIG5vdCAoZFsic2VyaWFsIl0gaW4g
c2VlbiBvciBzZWVuLmFkZChkWyJzZXJpYWwiXSkpXQogICAgbG9nKCJMaW1lU0RSIGdlZnVuZGVu
OiIsICIsICIuam9pbigiJXMgJXMiICUgKGRbIm5hbWUiXSwgZFsic2VyaWFsIl0pIGZvciBkIGlu
IExJTUVTKSBvciAia2VpbmUiKQogICAgcmV0dXJuIExJTUVTCgpkZWYgbGltZV9hc3NpZ24obW9k
ZSk6CiAgICAiIiIoZ3NtX3NlcmlhbCwgbHRlX3NlcmlhbCkgZnVlciBkZW4gTW9kdXMuIExlZXJl
IFdhaGwgPSBlcnN0ZXMgR2VyYWV0LCBkYXMKICAgIG5pY2h0IHNjaG9uIGRlbSBhbmRlcmVuIE5l
dHogZ2Vob2VydC4iIiIKICAgIGRldnMgPSBMSU1FUyBvciBsaW1lX3NjYW4oKQogICAgc2VyaWFs
cyA9IFtkWyJzZXJpYWwiXSBmb3IgZCBpbiBkZXZzXQogICAgZyA9IEMuZ2V0KCJHU01fREVWIiwg
IiIpLnN0cmlwKCk7IGwgPSBDLmdldCgiTFRFX0RFViIsICIiKS5zdHJpcCgpCiAgICBmaXJzdCA9
IGxhbWJkYSBvdGhlcjogbmV4dCgocyBmb3IgcyBpbiBzZXJpYWxzIGlmIHMgIT0gb3RoZXIpLCAi
IikKICAgIGlmIG1vZGUgaW4gKCJnc20iLCAiY3NmYiIpIGFuZCBub3QgZzogZyA9IGZpcnN0KGwp
CiAgICBpZiBtb2RlIGluICgibHRlIiwgImNzZmIiKSBhbmQgbm90IGw6IGwgPSBmaXJzdChnKQog
ICAgaWYgbW9kZSA9PSAiZ3NtIjogbCA9ICIiCiAgICBpZiBtb2RlID09ICJsdGUiOiBnID0gIiIK
ICAgIHJldHVybiBnLCBsCgpkZWYgbGltZV9sYWJlbChzZXJpYWwpOgogICAgZm9yIGQgaW4gTElN
RVM6CiAgICAgICAgaWYgZFsic2VyaWFsIl0gPT0gc2VyaWFsOgogICAgICAgICAgICByZXR1cm4g
IiVzICglcykiICUgKGQuZ2V0KCJuYW1lIiwgIkxpbWVTRFIiKSwgc2VyaWFsKQogICAgcmV0dXJu
IHNlcmlhbCBvciAi4oCTIgoKIyA9PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
PT09PT09PT09PT09PT09PT09PT09PT09PT09PT0gT3Ntb2NvbS1GYWVoaWdrZWl0ZW4KX1ZUWVJF
RiA9IHt9CmRlZiBvc21vX2hhcyhiaW5hcnksIHdvcmQpOgogICAgIiIiVHJ1ZS9GYWxzZSwgb2Ig
ZWluIE9zbW9jb20tUHJvZ3JhbW0gZWluZW4gVlRZLUJlZmVobCBrZW5udDsgTm9uZSA9IHVuYmVr
YW5udC4iIiIKICAgIGlmIGJpbmFyeSBub3QgaW4gX1ZUWVJFRjoKICAgICAgICB0cnk6CiAgICAg
ICAgICAgIF9WVFlSRUZbYmluYXJ5XSA9IHN1YnByb2Nlc3MucnVuKFtiaW5hcnksICItLXZ0eS1y
ZWYteG1sIl0sIGNhcHR1cmVfb3V0cHV0PVRydWUsCiAgICAgICAgICAgICAgICAgICAgICAgICAg
ICAgICAgICAgICAgICAgICAgIHRleHQ9VHJ1ZSwgdGltZW91dD0xNSkuc3Rkb3V0CiAgICAgICAg
ZXhjZXB0IEV4Y2VwdGlvbjoKICAgICAgICAgICAgX1ZUWVJFRltiaW5hcnldID0gIiIKICAgIHJl
ZiA9IF9WVFlSRUZbYmluYXJ5XQogICAgaWYgIjx2dHlkb2MiIG5vdCBpbiByZWY6IHJldHVybiBO
b25lCiAgICByZXR1cm4gcmUuc2VhcmNoKHInaWQ9WyJcJ10lc1xiJyAlIHJlLmVzY2FwZSh3b3Jk
KSwgcmVmKSBpcyBub3QgTm9uZQoKZGVmIHR6X25vdygpOgogICAgIiIiWmVpdHpvbmUgZnVlciBO
SVRaOiAoU3R1bmRlbiwgTWludXRlbiwgU29tbWVyemVpdCAwLzEpIG9obmUgRFNULUFudGVpbC4i
IiIKICAgIGx0ID0gdGltZS5sb2NhbHRpbWUoKQogICAgZHN0ID0gMSBpZiBsdC50bV9pc2RzdCA+
IDAgZWxzZSAwCiAgICBvZmYgPSBsdC50bV9nbXRvZmYgLy8gNjAgLSBkc3QgKiA2MAogICAgaCA9
IGludChvZmYgLyA2MCk7IG0gPSBhYnMob2ZmKSAlIDYwCiAgICByZXR1cm4gaCwgbWluKCgwLCAx
NSwgMzAsIDQ1KSwga2V5PWxhbWJkYSB4OiBhYnMoeCAtIG0pKSwgZHN0CgojID09PT09PT09PT09
PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PSBH
U00gKE9zbW9jb20pCkdTTV9DT1JFID0gWwogICAgKCJzdHAiLCAib3Ntby1zdHAiLCAib3Ntby1z
dHAuY2ZnIiksCiAgICAoImhsciIsICJvc21vLWhsciIsICJvc21vLWhsci5jZmciKSwKICAgICgi
bWd3IiwgIm9zbW8tbWd3IiwgIm9zbW8tbWd3LmNmZyIpLAogICAgKCJtc2MiLCAib3Ntby1tc2Mi
LCAib3Ntby1tc2MuY2ZnIiksCiAgICAoImJzYyIsICJvc21vLWJzYyIsICJvc21vLWJzYy5jZmci
KSwKICAgICgidHJ4IiwgIm9zbW8tdHJ4LWxtcyIsICJvc21vLXRyeC1sbXMuY2ZnIiksCiAgICAo
ImJ0cyIsICJvc21vLWJ0cy10cngiLCAib3Ntby1idHMtdHJ4LmNmZyIpLApdCkdTTV9EQVRBID0g
WwogICAgKCJnZ3NuIiwgIm9zbW8tZ2dzbiIsICJvc21vLWdnc24uY2ZnIiksCiAgICAoInNnc24i
LCAib3Ntby1zZ3NuIiwgIm9zbW8tc2dzbi5jZmciKSwKICAgICgicGN1IiwgICJvc21vLXBjdSIs
ICAib3Ntby1wY3UuY2ZnIiksCl0KR1NNX1NJUCA9ICgic2lwIiwgIm9zbW8tc2lwLWNvbm5lY3Rv
ciIsICJvc21vLXNpcC1jb25uZWN0b3IuY2ZnIikKR1NNX05PTkZBVEFMID0geyJnZ3NuIiwgInNn
c24iLCAicGN1IiwgInNpcCIsICJucmYiLCAic2NwIiwgInBrb20ifQpPU01PX1NFUlZJQ0VTID0g
WyJvc21vLXN0cCIsICJvc21vLWhsciIsICJvc21vLW1ndyIsICJvc21vLW1zYyIsICJvc21vLWJz
YyIsCiAgICAgICAgICAgICAgICAgIm9zbW8tYnRzLXRyeCIsICJvc21vLXRyeC1sbXMiLCAib3Nt
by1zaXAtY29ubmVjdG9yIiwKICAgICAgICAgICAgICAgICAib3Ntby1wY3UiLCAib3Ntby1zZ3Nu
IiwgIm9zbW8tZ2dzbiJdCgpkZWYgZ3NtX2NvbXBvbmVudHMoKToKICAgIGNvbXBzID0gbGlzdChH
U01fQ09SRSkKICAgIGlmIENbIkdTTV9EQVRBIl0gPT0gIjEiOiBjb21wcyArPSBHU01fREFUQQog
ICAgaWYgQ1siR1NNX1NJUCJdID09ICIxIiBhbmQgQ1siR1NNX1NJUF9QRUVSIl06IGNvbXBzICs9
IFtHU01fU0lQXQogICAgcmV0dXJuIGNvbXBzCgpkZWYgX3RhaWxzY2FsZV9pcCgpOgogICAgdHJ5
OgogICAgICAgIG91dCA9IHN1YnByb2Nlc3MucnVuKFsidGFpbHNjYWxlIiwgImlwIiwgIi00Il0s
IGNhcHR1cmVfb3V0cHV0PVRydWUsIHRleHQ9VHJ1ZSwgdGltZW91dD01KS5zdGRvdXQKICAgICAg
ICBmb3IgbGluZSBpbiBvdXQuc3BsaXRsaW5lcygpOgogICAgICAgICAgICBpcCA9IGxpbmUuc3Ry
aXAoKQogICAgICAgICAgICBpZiByZS5tYXRjaChyIjEwMFwuXGQrXC5cZCtcLlxkKyQiLCBpcCk6
IHJldHVybiBpcAogICAgZXhjZXB0IEV4Y2VwdGlvbjogcGFzcwogICAgcmV0dXJuICIwLjAuMC4w
IgoKZGVmIF9ncHJzX2Jsb2NrKG0pOgogICAgaSA9IG0uZ3JvdXAoMSkKICAgIEwgPSBbImdwcnMg
bW9kZSBlZ3BycyIsICJncHJzIHJvdXRpbmcgYXJlYSAwIiwgImdwcnMgbmV0d29yay1jb250cm9s
LW9yZGVyIG5jMCIsCiAgICAgICAgICJncHJzIGNlbGwgYnZjaSAxMjM0IiwgImdwcnMgbnNlaSAx
MjM0IiwgImdwcnMgbnN2YyAwIG5zdmNpIDEyMzQiLAogICAgICAgICAiZ3BycyBuc3ZjIDAgbG9j
YWwgdWRwIHBvcnQgMjMwMDEiLCAiZ3BycyBuc3ZjIDAgcmVtb3RlIHVkcCBwb3J0IDIzMDAwIiwK
ICAgICAgICAgImdwcnMgbnN2YyAwIHJlbW90ZSBpcCAxMjcuMC4wLjEiXQogICAgcmV0dXJuIGkg
KyAoIlxuIiArIGkpLmpvaW4oTCkKCmRlZiBnc21fcHJlcGFyZSgpOgogICAgZm9yIF9uLCBfYiwg
Y2ZnIGluIGdzbV9jb21wb25lbnRzKCk6CiAgICAgICAgc3JjID0gb3MucGF0aC5qb2luKE9TTU9f
Q0ZHLCBjZmcpCiAgICAgICAgaWYgb3MucGF0aC5pc2ZpbGUoc3JjKTogc2h1dGlsLmNvcHkoc3Jj
LCBvcy5wYXRoLmpvaW4oV09SS0RJUiwgY2ZnKSkKICAgIGFyZmNuLCBtY2MsIG1uYyA9IGludChD
WyJHU01fQVJGQ04iXSksIENbIk1DQyJdLCBDWyJNTkMiXQogICAgZGF0YV9vbiA9IENbIkdTTV9E
QVRBIl0gPT0gIjEiOyBvcGVuX3JlZyA9IENbIkdTTV9PUEVOIl0gPT0gIjEiCiAgICBic2MgPSBv
cy5wYXRoLmpvaW4oV09SS0RJUiwgIm9zbW8tYnNjLmNmZyIpCiAgICBydWxlcyA9IFsKICAgICAg
ICAociJeKFxzKm5ldHdvcmsgY291bnRyeSBjb2RlXHMrKVxkKyIsIHIiXGc8MT4iICsgbWNjKSwK
ICAgICAgICAociJeKFxzKm1vYmlsZSBuZXR3b3JrIGNvZGVccyspXGQrIiwgciJcZzwxPiIgKyBt
bmMpLAogICAgICAgIChyIl4oXHMqYmFuZFxzKylcUysiLCByIlxnPDE+IiArIGFyZmNuX2JhbmQo
YXJmY24pKSwKICAgICAgICAociJeKFxzKmFyZmNuXHMrKVxkKyIsIHIiXGc8MT4iICsgc3RyKGFy
ZmNuKSksCiAgICAgICAgKHIiXihccyptYXhfcG93ZXJfcmVkXHMrKVxkKyIsIHIiXGc8MT4wIiks
CiAgICBdCiAgICBpZiBub3QgZGF0YV9vbjoKICAgICAgICBydWxlcy5hcHBlbmQoKHIiXihccypn
cHJzIG1vZGVccyspXFMrIiwgciJcZzwxPm5vbmUiKSkKICAgIF9zdWIoYnNjLCBydWxlcykKICAg
IGlmIGRhdGFfb246CiAgICAgICAgdCA9IG9wZW4oYnNjKS5yZWFkKCkKICAgICAgICB0ID0gcmUu
c3ViKHIiKD9tKV5ccypncHJzIChyb3V0aW5nIGFyZWF8bmV0d29yay1jb250cm9sLW9yZGVyfGNl
bGx8bnNlaXxuc3ZjKVxiLipcbj8iLCAiIiwgdCkKICAgICAgICB0ID0gcmUuc3ViKHIiKD9tKV4o
XHMqKWdwcnMgbW9kZVxzK1xTKy4qJCIsIF9ncHJzX2Jsb2NrLCB0LCBjb3VudD0xKQogICAgICAg
IGZvciB0cyBpbiAoIjUiLCAiNiIsICI3Iik6CiAgICAgICAgICAgIHQgPSByZS5zdWIocmYiKD9t
KSheXHMqdGltZXNsb3Qge3RzfVxzKlxuXHMqcGh5c19jaGFuX2NvbmZpZ1xzKylUQ0gvRlxzKiQi
LCByIlxnPDE+VENIL0ZfUERDSCIsIHQpCiAgICAgICAgb3Blbihic2MsICJ3Iikud3JpdGUodCkK
ICAgICMgTVNDOiBLZW5udW5nICsgTmFtZQogICAgX3N1Yihvcy5wYXRoLmpvaW4oV09SS0RJUiwg
Im9zbW8tbXNjLmNmZyIpLCBbCiAgICAgICAgKHIiXihccypuZXR3b3JrIGNvdW50cnkgY29kZVxz
KylcZCsiLCByIlxnPDE+IiArIG1jYyksCiAgICAgICAgKHIiXihccyptb2JpbGUgbmV0d29yayBj
b2RlXHMrKVxkKyIsIHIiXGc8MT4iICsgbW5jKSwKICAgIF0pCiAgICBtc2MgPSBvcy5wYXRoLmpv
aW4oV09SS0RJUiwgIm9zbW8tbXNjLmNmZyIpOyBobHIgPSBvcy5wYXRoLmpvaW4oV09SS0RJUiwg
Im9zbW8taGxyLmNmZyIpCiAgICBfdnR5X2RlbChtc2MsICJhdXRoZW50aWNhdGlvbiIpCiAgICAj
IE5ldHpuYW1lICsgTklUWjogTU0tSW5mb3JtYXRpb24gbWl0IE5hbWUsIFVocnplaXQgdW5kIFpl
aXR6b25lIGFucyBIYW5keQogICAgd29yZCA9IGxhbWJkYSBzOiByZS5zdWIociJbXlx3ListXSIs
ICItIiwgcyBvciAicEtPTSIpICAgICAgIyBWVFk6IGVpbiBXb3J0CiAgICBfdnR5X3NldChtc2Ms
ICJuZXR3b3JrIiwgInNob3J0IG5hbWUiLCAic2hvcnQgbmFtZSAiICsgd29yZChDLmdldCgiTkVU
TkFNRV9TSE9SVCIpIG9yIENbIk5FVE5BTUUiXSkpCiAgICBfdnR5X3NldChtc2MsICJuZXR3b3Jr
IiwgImxvbmcgbmFtZSIsICJsb25nIG5hbWUgIiArIHdvcmQoQ1siTkVUTkFNRSJdKSkKICAgIGlm
IEMuZ2V0KCJOSVRaIiwgIjEiKSA9PSAiMSI6CiAgICAgICAgX3Z0eV9zZXQobXNjLCAibmV0d29y
ayIsICJtbSBpbmZvIiwgIm1tIGluZm8gMSIpCiAgICAgICAgaWYgb3Ntb19oYXMoIm9zbW8tbXNj
IiwgInRpbWV6b25lIik6CiAgICAgICAgICAgIF92dHlfc2V0KG1zYywgIm5ldHdvcmsiLCAidGlt
ZXpvbmUiLCAidGltZXpvbmUgJWQgJWQgJWQiICUgdHpfbm93KCkpCiAgICBlbHNlOgogICAgICAg
IF92dHlfc2V0KG1zYywgIm5ldHdvcmsiLCAibW0gaW5mbyIsICJtbSBpbmZvIDAiKQogICAgICAg
IF92dHlfZGVsKG1zYywgInRpbWV6b25lIikKICAgICMgU0dzIHp1ciBPcGVuNUdTLU1NRSAobnVy
IGltIE1vZHVzIExURSArIEdTTSkKICAgIHQgPSBvcGVuKG1zYykucmVhZCgpCiAgICB0ID0gcmUu
c3ViKHIiKD9tKV5zZ3NbIFx0XSpcbig/OlsgXHRdKy4qKD86XG58JCkpKiIsICIiLCB0KQogICAg
aWYgTkVULnRlY2ggPT0gImNzZmIiOgogICAgICAgIHQgPSB0LnJzdHJpcCgiXG4iKSArICJcbnNn
c1xuIGxvY2FsLXBvcnQgJWRcbiBsb2NhbC1pcCAxMjcuMC4wLjFcbiB2bHItbmFtZSB2bHIucGtv
bS50ZXN0XG4iICUgU0dTX1BPUlQKICAgIG9wZW4obXNjLCAidyIpLndyaXRlKHQpCiAgICAjIGVp
Z2VuZXIgTGltZVNEUiBmdWVyIEdTTSAob3Ntby10cngtbG1zIHdhZWhsdCBwZXIgVGVpbHN0cmlu
ZyBkZXIgR2VyYWV0ZWxpc3RlKQogICAgdHJ4ID0gb3MucGF0aC5qb2luKFdPUktESVIsICJvc21v
LXRyeC1sbXMuY2ZnIikKICAgIGlmIG9zLnBhdGguaXNmaWxlKHRyeCk6CiAgICAgICAgaWYgTkVU
LmRldl9nc206CiAgICAgICAgICAgIF92dHlfc2V0KHRyeCwgInRyeCIsICJkZXYtYXJncyIsICJk
ZXYtYXJncyBzZXJpYWw9IiArIE5FVC5kZXZfZ3NtKQogICAgICAgIGVsc2U6CiAgICAgICAgICAg
IF92dHlfZGVsKHRyeCwgImRldi1hcmdzIikKICAgIGlmIG9wZW5fcmVnOgogICAgICAgIF92dHlf
c2V0KGhsciwgImhsciIsICJzdWJzY3JpYmVyLWNyZWF0ZS1vbi1kZW1hbmQiLCAic3Vic2NyaWJl
ci1jcmVhdGUtb24tZGVtYW5kIG5vLW1zaXNkbiBjcytwcyIpCiAgICBlbHNlOgogICAgICAgIF92
dHlfZGVsKGhsciwgInN1YnNjcmliZXItY3JlYXRlLW9uLWRlbWFuZCIpCiAgICAjIFJYLUdhaW4g
KGluc3RhbmNlLUtub3RlbiBkZXIgb3Ntby1idHMtdHJ4LmNmZykgKyBCYW5kCiAgICBidHMgPSBv
cy5wYXRoLmpvaW4oV09SS0RJUiwgIm9zbW8tYnRzLXRyeC5jZmciKQogICAgaWYgb3MucGF0aC5p
c2ZpbGUoYnRzKToKICAgICAgICBidCA9IG9wZW4oYnRzKS5yZWFkKCk7IHJnID0gaW50KENbIkdT
TV9SWF9HQUlOIl0pCiAgICAgICAgYnQgPSByZS5zdWIociIoP20pXihccypiYW5kXHMrKVxTKyIs
IHIiXGc8MT4iICsgYXJmY25fYmFuZChhcmZjbiksIGJ0KQogICAgICAgIGlmIHJlLnNlYXJjaChy
Iig/bSleXHMqb3Ntb3RyeCByeC1nYWluXGIiLCBidCk6CiAgICAgICAgICAgIGJ0ID0gcmUuc3Vi
KHIiKD9tKV4oXHMqb3Ntb3RyeCByeC1nYWluXHMrKS4qJCIsIHIiXGc8MT4lZCIgJSByZywgYnQp
CiAgICAgICAgZWxzZToKICAgICAgICAgICAgYnQgPSByZS5zdWIociIoP20pXihccyppbnN0YW5j
ZSAwXHMqKSQiLCByIlwxXG4gIG9zbW90cnggcngtZ2FpbiAlZCIgJSByZywgYnQsIGNvdW50PTEp
CiAgICAgICAgb3BlbihidHMsICJ3Iikud3JpdGUoYnQpCiAgICAjIFNJUC1UcnVuawogICAgaWYg
Q1siR1NNX1NJUCJdID09ICIxIiBhbmQgQ1siR1NNX1NJUF9QRUVSIl06CiAgICAgICAgX3Z0eV9z
ZXQobXNjLCAibXNjIiwgIm1uY2MiLCAibW5jYyBleHRlcm5hbCAvdG1wL21uY2Muc29jayIpCiAg
ICAgICAgbG9jYWwgPSBDLmdldCgiR1NNX1NJUF9MT0NBTCIpIG9yIF90YWlsc2NhbGVfaXAoKQog
ICAgICAgIHdpdGggb3Blbihvcy5wYXRoLmpvaW4oV09SS0RJUiwgIm9zbW8tc2lwLWNvbm5lY3Rv
ci5jZmciKSwgInciKSBhcyBmOgogICAgICAgICAgICBmLndyaXRlKCJtbmNjXG4gc29ja2V0LXBh
dGggL3RtcC9tbmNjLnNvY2tcbnNpcFxuIGxvY2FsICVzIDUwNjBcbiByZW1vdGUgJXMgNTA2MFxu
IgogICAgICAgICAgICAgICAgICAgICUgKGxvY2FsLCBDWyJHU01fU0lQX1BFRVIiXSkpCiAgICBl
bHNlOgogICAgICAgIF92dHlfc2V0KG1zYywgIm1zYyIsICJtbmNjIiwgIm1uY2MgaW50ZXJuYWwi
KQogICAgaWYgZGF0YV9vbiBhbmQgb3Blbl9yZWc6CiAgICAgICAgX3Z0eV9zZXQob3MucGF0aC5q
b2luKFdPUktESVIsICJvc21vLXNnc24uY2ZnIiksICJzZ3NuIiwgImF1dGgtcG9saWN5IiwgImF1
dGgtcG9saWN5IGFjY2VwdC1hbGwiKQoKIyAtLS0tIFNJTXM6IEVJTkUgTGlzdGUgZnVlciBiZWlk
ZSBOZXR6ZQojIEVpbmdldHJhZ2VuIHdpcmQgbnVyIGhpZXI7IHBLT00gc2NocmVpYnQgamVkZSBT
SU0gYXV0b21hdGlzY2ggaW5zIG9zbW8taGxyIChHU00pCiMgdW5kIGluIGRlbiBPcGVuNUdTLUhT
UyAoTFRFLCBNb25nb0RCKS4gS2kvT1BjIHZlcmxhc3NlbiBkZW4gUmVjaG5lciBuaWUKIyAoZGll
IFdlYm9iZXJmbGFlY2hlIGJla29tbXQgbnVyIElNU0kgKyBSdWZudW1tZXIgenVydWVjaykuClNJ
TVNfRklMRSA9IG9zLnBhdGguam9pbihXT1JLRElSLCAic2ltcy5qc29uIikKCmRlZiBzaW1zX2xv
YWQoKToKICAgIHRyeTogcmV0dXJuIGpzb24ubG9hZChvcGVuKFNJTVNfRklMRSkpCiAgICBleGNl
cHQgRXhjZXB0aW9uOiByZXR1cm4ge30KCmRlZiBzaW1zX3NhdmUoZCk6CiAgICB0cnk6CiAgICAg
ICAgdG1wID0gU0lNU19GSUxFICsgIi50bXAiCiAgICAgICAgd2l0aCBvcGVuKHRtcCwgInciKSBh
cyBmOiBqc29uLmR1bXAoZCwgZiwgaW5kZW50PTEpCiAgICAgICAgb3MuY2htb2QodG1wLCAwbzYw
MCk7IG9zLnJlcGxhY2UodG1wLCBTSU1TX0ZJTEUpCiAgICBleGNlcHQgRXhjZXB0aW9uIGFzIGU6
CiAgICAgICAgbG9nKCJzaW1zOiIsIGUpCgpkZWYgZ3NtX29uKCk6CiAgICByZXR1cm4gTkVULnRl
Y2ggaW4gKCJnc20iLCAiY3NmYiIpCgpkZWYgbHRlX29uKCk6CiAgICByZXR1cm4gTkVULnRlY2gg
aW4gKCJsdGUiLCAiY3NmYiIpCgpkZWYgX2hleDMyKHgpOgogICAgcmV0dXJuIHJlLnN1YihyIlte
MC05YS1mQS1GXSIsICIiLCB4IG9yICIiKS51cHBlcigpCgpkZWYgaGxyX3B1dChpbXNpLCBzKToK
ICAgIGlmIEZBS0U6IHJldHVybiBOb25lCiAgICByID0gdnR5KEhMUl9WVFksIFsiZW5hYmxlIiwg
ZiJzdWJzY3JpYmVyIGltc2kge2ltc2l9IGNyZWF0ZSIsCiAgICAgICAgICAgICAgICAgICAgICBm
InN1YnNjcmliZXIgaW1zaSB7aW1zaX0gdXBkYXRlIG1zaXNkbiB7cy5nZXQoJ21zaXNkbicpIG9y
IGltc2lbLTg6XX0iLAogICAgICAgICAgICAgICAgICAgICAgZiJzdWJzY3JpYmVyIGltc2kge2lt
c2l9IHVwZGF0ZSBhdWQzZyBtaWxlbmFnZSBrIHtzWydraSddfSBvcGMge3NbJ29wYyddfSJdKQog
ICAgcmV0dXJuIE5vbmUgaWYgIiUgIiBub3QgaW4gci5yZXBsYWNlKCIlIFN1YnNjcmliZXIgYWxy
ZWFkeSBleGlzdHMiLCAiIikgZWxzZSByLnN0cmlwKClbLTE2MDpdCgpkZWYgX2hzcygpOgogICAg
aW1wb3J0IHB5bW9uZ28KICAgIHJldHVybiBweW1vbmdvLk1vbmdvQ2xpZW50KCJtb25nb2RiOi8v
MTI3LjAuMC4xLyIsIHNlcnZlclNlbGVjdGlvblRpbWVvdXRNUz0zMDAwKVsib3BlbjVncyJdWyJz
dWJzY3JpYmVycyJdCgpkZWYgaHNzX3B1dChpbXNpLCBzKToKICAgICIiIlNJTSBpbiBkZW4gT3Bl
bjVHUy1IU1Mgc2NocmVpYmVuIChhbmxlZ2VuIG9kZXIgYWt0dWFsaXNpZXJlbiwgU1FOIGJsZWli
dCkuIiIiCiAgICBpZiBGQUtFOiByZXR1cm4gTm9uZQogICAgdHJ5OgogICAgICAgIGZyb20gYnNv
bi5pbnQ2NCBpbXBvcnQgSW50NjQKICAgICAgICBhbWJyID0geyJkb3dubGluayI6IHsidmFsdWUi
OiAxLCAidW5pdCI6IDN9LCAidXBsaW5rIjogeyJ2YWx1ZSI6IDEsICJ1bml0IjogM319ICAgIyAx
IEdiaXQvcwogICAgICAgIHNlc3MgPSB7Im5hbWUiOiBDLmdldCgiTFRFX0FQTiIpIG9yICJpbnRl
cm5ldCIsICJ0eXBlIjogMywgICAgICAgICAgIyAzID0gSVB2NHY2CiAgICAgICAgICAgICAgICAi
cW9zIjogeyJpbmRleCI6IDksICJhcnAiOiB7InByaW9yaXR5X2xldmVsIjogOCwgInByZV9lbXB0
aW9uX2NhcGFiaWxpdHkiOiAxLAogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
ICAgICAgICJwcmVfZW1wdGlvbl92dWxuZXJhYmlsaXR5IjogMX19LAogICAgICAgICAgICAgICAg
ImFtYnIiOiBhbWJyLCAicGNjX3J1bGUiOiBbXX0KICAgICAgICBfaHNzKCkudXBkYXRlX29uZSh7
Imltc2kiOiBpbXNpfSwgewogICAgICAgICAgICAiJHNldCI6IHsiaW1zaSI6IGltc2ksICJtc2lz
ZG4iOiBbc1sibXNpc2RuIl1dIGlmIHMuZ2V0KCJtc2lzZG4iKSBlbHNlIFtdLAogICAgICAgICAg
ICAgICAgICAgICAic2VjdXJpdHkuayI6IHNbImtpIl0sICJzZWN1cml0eS5vcGMiOiBzWyJvcGMi
XSwgInNlY3VyaXR5Lm9wIjogTm9uZSwKICAgICAgICAgICAgICAgICAgICAgInNlY3VyaXR5LmFt
ZiI6ICI4MDAwIiwgImFtYnIiOiBhbWJyLAogICAgICAgICAgICAgICAgICAgICAic2xpY2UiOiBb
eyJzc3QiOiAxLCAiZGVmYXVsdF9pbmRpY2F0b3IiOiBUcnVlLCAic2Vzc2lvbiI6IFtzZXNzXX1d
LAogICAgICAgICAgICAgICAgICAgICAiYWNjZXNzX3Jlc3RyaWN0aW9uX2RhdGEiOiAzMiwgInN1
YnNjcmliZXJfc3RhdHVzIjogMCwKICAgICAgICAgICAgICAgICAgICAgIm9wZXJhdG9yX2RldGVy
bWluZWRfYmFycmluZyI6IDAsCiAgICAgICAgICAgICAgICAgICAgICJuZXR3b3JrX2FjY2Vzc19t
b2RlIjogMCwgICAgICAgICMgMCA9IFBha2V0ICsgTGVpdHVuZyAtPiBrb21iaW5pZXJ0ZXIgQXR0
YWNoIChDU0ZCKQogICAgICAgICAgICAgICAgICAgICAic3Vic2NyaWJlZF9yYXVfdGF1X3RpbWVy
IjogMTJ9LAogICAgICAgICAgICAiJHNldE9uSW5zZXJ0IjogeyJzZWN1cml0eS5zcW4iOiBJbnQ2
NCg5NyksICJpbWVpc3YiOiBbXSwgIm1tZV9ob3N0IjogW10sCiAgICAgICAgICAgICAgICAgICAg
ICAgICAgICAgIm1tZV9yZWFsbSI6IFtdLCAicHVyZ2VfZmxhZyI6IFtdLCAiX192IjogMH19LCB1
cHNlcnQ9VHJ1ZSkKICAgICAgICByZXR1cm4gTm9uZQogICAgZXhjZXB0IEltcG9ydEVycm9yOgog
ICAgICAgIHJldHVybiAicHl0aG9uMy1weW1vbmdvIGZlaGx0IChJbnN0YWxsZXIgZXJuZXV0IGF1
c2Z1ZWhyZW4pIgogICAgZXhjZXB0IEV4Y2VwdGlvbiBhcyBlOgogICAgICAgIHJldHVybiAiSFNT
L01vbmdvREI6ICVzIiAlIHN0cihlKVs6MTIwXQoKZGVmIGhzc19kZWwoaW1zaSk6CiAgICBpZiBG
QUtFOiByZXR1cm4KICAgIHRyeTogX2hzcygpLmRlbGV0ZV9vbmUoeyJpbXNpIjogaW1zaX0pCiAg
ICBleGNlcHQgRXhjZXB0aW9uIGFzIGU6IGxvZygiaHNzIGxvZXNjaGVuOiIsIGUpCgpkZWYgaHNz
X3N5bmNfYWxsKCk6CiAgICBlcnJzID0gW2UgZm9yIGUgaW4gKGhzc19wdXQoaSwgcykgZm9yIGks
IHMgaW4gc2ltc19sb2FkKCkuaXRlbXMoKSkgaWYgZV0KICAgIHJldHVybiBlcnJzWzBdIGlmIGVy
cnMgZWxzZSBOb25lCgpkZWYgc2ltX2FkZChpbXNpLCBraSwgb3BjLCBtc2lzZG4pOgogICAgaW1z
aSA9IHJlLnN1YihyIlxEIiwgIiIsIGltc2kgb3IgIiIpOyBraSA9IF9oZXgzMihraSk7IG9wYyA9
IF9oZXgzMihvcGMpCiAgICBpZiBsZW4oaW1zaSkgPCAxNCBvciBsZW4oa2kpICE9IDMyIG9yIGxl
bihvcGMpICE9IDMyOgogICAgICAgIHJldHVybiAiSU1TSSAoMTUgWmlmZmVybiksIEtpIHVuZCBP
UGMgKGplIDMyIEhleCkgcHJ1ZWZlbiIKICAgIG1zaXNkbiA9IHJlLnN1YihyIlxEIiwgIiIsIG1z
aXNkbiBvciAiIikgb3IgbnVtc19sb2FkKCkuZ2V0KGltc2kpIG9yIGltc2lbLTg6XQogICAgZCA9
IHNpbXNfbG9hZCgpOyBkW2ltc2ldID0geyJraSI6IGtpLCAib3BjIjogb3BjLCAibXNpc2RuIjog
bXNpc2RufTsgc2ltc19zYXZlKGQpCiAgICBuID0gbnVtc19sb2FkKCk7IG5baW1zaV0gPSBtc2lz
ZG47IG51bXNfc2F2ZShuKSAgICAgICAgICAjIFJ1Zm51bW1lciBkYXVlcmhhZnQKICAgIGVycnMg
PSBbXQogICAgZSA9IGhzc19wdXQoaW1zaSwgZFtpbXNpXSkKICAgIGlmIGU6IGVycnMuYXBwZW5k
KGUpCiAgICBpZiBnc21fb24oKSBhbmQgbm90IEZBS0U6CiAgICAgICAgZSA9IGhscl9wdXQoaW1z
aSwgZFtpbXNpXSkKICAgICAgICBpZiBlOiBlcnJzLmFwcGVuZCgiSExSOiAiICsgZSkKICAgICAg
ICBlbHNlOiBzbXNfc2VuZChpbXNpLCBfc21zX3RleHQoQy5nZXQoIkdTTV9TTVNfTlVNQkVSIiwg
IiIpLCBudW1tZXI9bXNpc2RuKSkKICAgIHJldHVybiAoIlNJTSBnZXNwZWljaGVydCwgYWJlcjog
IiArICI7ICIuam9pbihlcnJzKSkgaWYgZXJycyBlbHNlIE5vbmUKCmRlZiBzaW1fZGVsKGltc2kp
OgogICAgaW1zaSA9IHJlLnN1YihyIlxEIiwgIiIsIGltc2kgb3IgIiIpCiAgICBkID0gc2ltc19s
b2FkKCkKICAgIGlmIGltc2kgaW4gZDoKICAgICAgICBkZWwgZFtpbXNpXTsgc2ltc19zYXZlKGQp
CiAgICBoc3NfZGVsKGltc2kpCiAgICBpZiBnc21fb24oKSBhbmQgbm90IEZBS0U6CiAgICAgICAg
dnR5KEhMUl9WVFksIFsiZW5hYmxlIiwgZiJzdWJzY3JpYmVyIGltc2kge2ltc2l9IGRlbGV0ZSJd
KQoKZGVmIF9taWdyYXRlX2x0ZV9kYigpOgogICAgIiIiQWx0ZSBzcnNFUEMtTGlzdGUgKHVzZXJf
ZGIuY3N2KSBlaW5tYWxpZyBpbiBkaWUgZ2VtZWluc2FtZSBTSU0tTGlzdGUgdWViZXJuZWhtZW4u
IiIiCiAgICB1ZGIgPSBvcy5wYXRoLmpvaW4oV09SS0RJUiwgInVzZXJfZGIuY3N2IikKICAgIGlm
IG5vdCBvcy5wYXRoLmlzZmlsZSh1ZGIpOiByZXR1cm4KICAgIGQgPSBzaW1zX2xvYWQoKTsgbnVt
cyA9IG51bXNfbG9hZCgpOyBuID0gMAogICAgZm9yIGwgaW4gb3Blbih1ZGIpLnJlYWQoKS5zcGxp
dGxpbmVzKCk6CiAgICAgICAgZiA9IGwuc3BsaXQoIiwiKQogICAgICAgIGlmIGxlbihmKSA+PSA1
IGFuZCBub3QgbC5zdGFydHN3aXRoKCIjIikgYW5kIGZbMF0gbm90IGluIGQgYW5kIGxlbihfaGV4
MzIoZlszXSkpID09IDMyOgogICAgICAgICAgICBkW2ZbMF1dID0geyJraSI6IF9oZXgzMihmWzNd
KSwgIm9wYyI6IF9oZXgzMihmWzRdKSwgIm1zaXNkbiI6IG51bXMuZ2V0KGZbMF0sICIiKX07IG4g
Kz0gMQogICAgaWYgbjogc2ltc19zYXZlKGQpCiAgICB0cnk6IG9zLnJlcGxhY2UodWRiLCB1ZGIg
KyAiLmFsdCIpCiAgICBleGNlcHQgRXhjZXB0aW9uOiBwYXNzCiAgICBsb2coZiJ7bn0gU0lNKHMp
IGF1cyBkZXIgYWx0ZW4gc3JzRVBDLUxpc3RlIHVlYmVybm9tbWVuIikKCiMgRGF1ZXJoYWZ0ZSBJ
TVNJLT5SdWZudW1tZXItWnV3ZWlzdW5nZW4gKHVlYmVybGViZW4gTmV1c3RhcnRzLCB3ZXJkZW4g
YmVpIGplZGVtCiMgR1NNLVN0YXJ0IGVybmV1dCBpbnMgSExSIGdlc2NocmllYmVuIC0gYXVjaCBm
dWVyIG9mZmVuIGFuZ2VtZWxkZXRlIFNJTXMgb2huZSBLaSkuCk5VTVNfRklMRSA9IG9zLnBhdGgu
am9pbihXT1JLRElSLCAibnVtYmVycy5qc29uIikKCmRlZiBudW1zX2xvYWQoKToKICAgIHRyeTog
cmV0dXJuIGpzb24ubG9hZChvcGVuKE5VTVNfRklMRSkpCiAgICBleGNlcHQgRXhjZXB0aW9uOiBy
ZXR1cm4ge30KCmRlZiBudW1zX3NhdmUoZCk6CiAgICB0cnk6IGpzb24uZHVtcChkLCBvcGVuKE5V
TVNfRklMRSwgInciKSkKICAgIGV4Y2VwdCBFeGNlcHRpb24gYXMgZTogbG9nKCJudW1iZXJzOiIs
IGUpCgpkZWYgZ3NtX2FwcGx5X251bWJlcnMoKToKICAgICIiIkJlaW0gR1NNLVN0YXJ0OiBhbGxl
IFNJTXMgKG1pdCBTY2hsdWVzc2VsKSArIFJ1Zm51bW1lcm4gaW5zIEhMUiBzY2hyZWliZW4uIiIi
CiAgICBpZiBGQUtFOiByZXR1cm4KICAgIGZvciBpbXNpLCBzIGluIHNpbXNfbG9hZCgpLml0ZW1z
KCk6CiAgICAgICAgZSA9IGhscl9wdXQoaW1zaSwgcykKICAgICAgICBpZiBlOiBsb2coImhscjoi
LCBpbXNpLCBlKQogICAgZCA9IG51bXNfbG9hZCgpCiAgICBpZiBub3QgZDogcmV0dXJuCiAgICBj
bWRzID0gWyJlbmFibGUiXQogICAgZm9yIGltc2ksIG1zaXNkbiBpbiBkLml0ZW1zKCk6CiAgICAg
ICAgY21kcyArPSBbZiJzdWJzY3JpYmVyIGltc2kge2ltc2l9IGNyZWF0ZSIsIGYic3Vic2NyaWJl
ciBpbXNpIHtpbXNpfSB1cGRhdGUgbXNpc2RuIHttc2lzZG59Il0KICAgIHZ0eShITFJfVlRZLCBj
bWRzKQoKZGVmIGdzbV9zaW1fbnIoaW1zaSwgbXNpc2RuKToKICAgIGltc2kgPSByZS5zdWIociJc
RCIsICIiLCBpbXNpKTsgbXNpc2RuID0gcmUuc3ViKHIiXEQiLCAiIiwgbXNpc2RuKQogICAgaWYg
bGVuKGltc2kpIDwgMTQgb3Igbm90IG1zaXNkbjogcmV0dXJuICJJTVNJICgxNSBaaWZmZXJuKSB1
bmQgUnVmbnVtbWVyIHBydWVmZW4iCiAgICBkID0gbnVtc19sb2FkKCk7IGRbaW1zaV0gPSBtc2lz
ZG47IG51bXNfc2F2ZShkKSAgICAgICAgIyBkYXVlcmhhZnQgbWVya2VuCiAgICBzID0gc2ltc19s
b2FkKCkKICAgIGlmIGltc2kgaW4gczogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
ICAgICAgICAgIyBTSU0gbWl0IFNjaGx1ZXNzZWw6IGF1Y2ggaW0gSFNTCiAgICAgICAgc1tpbXNp
XVsibXNpc2RuIl0gPSBtc2lzZG47IHNpbXNfc2F2ZShzKTsgaHNzX3B1dChpbXNpLCBzW2ltc2ld
KQogICAgaWYgbm90IEZBS0UgYW5kIGdzbV9vbigpOiAgICAgICAgICAgICAgICAgICAgICAgICAg
ICAgICAjIHNvZm9ydCBhbndlbmRlbiwgd2VubiBHU00gbGFldWZ0CiAgICAgICAgdnR5KEhMUl9W
VFksIFsiZW5hYmxlIiwgZiJzdWJzY3JpYmVyIGltc2kge2ltc2l9IGNyZWF0ZSIsCiAgICAgICAg
ICAgICAgICAgICAgICBmInN1YnNjcmliZXIgaW1zaSB7aW1zaX0gdXBkYXRlIG1zaXNkbiB7bXNp
c2RufSJdKQogICAgICAgIHNtc19zZW5kKGltc2ksIF9zbXNfdGV4dChDLmdldCgiR1NNX1NNU19O
VU1CRVIiLCAiIiksIG51bW1lcj1tc2lzZG4pKQogICAgcmV0dXJuIE5vbmUKCmRlZiBnc21fbnVt
X2RlbChpbXNpKToKICAgIGltc2kgPSByZS5zdWIociJcRCIsICIiLCBpbXNpKTsgZCA9IG51bXNf
bG9hZCgpCiAgICBpZiBpbXNpIGluIGQ6CiAgICAgICAgZGVsIGRbaW1zaV07IG51bXNfc2F2ZShk
KQogICAgaWYgbm90IEZBS0UgYW5kIGdzbV9vbigpOgogICAgICAgIHZ0eShITFJfVlRZLCBbImVu
YWJsZSIsIGYic3Vic2NyaWJlciBpbXNpIHtpbXNpfSB1cGRhdGUgbXNpc2RuICJdKQoKIyAtLS0t
IFNJTS1EYXRlbiBlcnpldWdlbiAoZnVlciBlaWdlbmUgZVNJTS1Qcm9maWxlLCB6LkIuIHNpbWxl
c3NseSkKIyBJTVNJID0gZWlnZW5lIEtlbm51bmcgKE1DQytNTkMpICsgenVmYWVsbGlnZSBNU0lO
LCBLaS9PUCB6dWZhZWxsaWcgKHNlY3JldHMpLAojIE9QYyA9IEFFU19LaShPUCkgeG9yIE9QIChN
aWxlbmFnZSwgVFMgMzUuMjA2KSwgSUNDSUQgbWl0IEx1aG4tUHJ1ZWZ6aWZmZXIuCl9TQk9YID0g
W10KZGVmIF9hZXNfdGFibGVzKCk6CiAgICBpZiBfU0JPWDogcmV0dXJuCiAgICBwID0gcSA9IDE7
IHNiID0gWzBdICogMjU2CiAgICB3aGlsZSBUcnVlOiAgICAgICAgICAgICAgICAgICAgICAgICAg
ICAgICAgICAgICMgUy1Cb3ggdWViZXIgZGFzIEludmVyc2UgaW4gR0YoMl44KQogICAgICAgIHAg
PSBwIF4gKChwIDw8IDEpICYgMHhGRikgXiAoMHgxQiBpZiBwICYgMHg4MCBlbHNlIDApCiAgICAg
ICAgcSBePSBxIDw8IDE7IHEgXj0gcSA8PCAyOyBxIF49IHEgPDwgNDsgcSAmPSAweEZGCiAgICAg
ICAgaWYgcSAmIDB4ODA6IHEgXj0gMHgwOQogICAgICAgIHggPSBxIF4gKChxIDw8IDEgfCBxID4+
IDcpICYgMHhGRikgXiAoKHEgPDwgMiB8IHEgPj4gNikgJiAweEZGKSBcCiAgICAgICAgICAgICAg
XiAoKHEgPDwgMyB8IHEgPj4gNSkgJiAweEZGKSBeICgocSA8PCA0IHwgcSA+PiA0KSAmIDB4RkYp
CiAgICAgICAgc2JbcF0gPSB4IF4gMHg2MwogICAgICAgIGlmIHAgPT0gMTogYnJlYWsKICAgIHNi
WzBdID0gMHg2MwogICAgX1NCT1guZXh0ZW5kKHNiKQoKZGVmIF94dChhKTogcmV0dXJuICgoYSA8
PCAxKSBeIDB4MUIpICYgMHhGRiBpZiBhICYgMHg4MCBlbHNlIGEgPDwgMQoKZGVmIGFlczEyOF9l
bmNyeXB0KGtleSwgYmxvY2spOgogICAgIiIiQUVTLTEyOCwgZWluIEJsb2NrIChyZWluZXMgUHl0
aG9uLCBudXIgZnVlciBkaWUgT1BjLUJlcmVjaG51bmcpLiIiIgogICAgX2Flc190YWJsZXMoKTsg
UyA9IF9TQk9YCiAgICB3ID0gW2xpc3Qoa2V5W2k6aSArIDRdKSBmb3IgaSBpbiByYW5nZSgwLCAx
NiwgNCldOyByYyA9IDEKICAgIGZvciBpIGluIHJhbmdlKDQsIDQ0KToKICAgICAgICB0ID0gbGlz
dCh3W2kgLSAxXSkKICAgICAgICBpZiBpICUgNCA9PSAwOgogICAgICAgICAgICB0ID0gW1NbYl0g
Zm9yIGIgaW4gdFsxOl0gKyB0WzoxXV07IHRbMF0gXj0gcmM7IHJjID0gX3h0KHJjKQogICAgICAg
IHcuYXBwZW5kKFthIF4gYiBmb3IgYSwgYiBpbiB6aXAod1tpIC0gNF0sIHQpXSkKICAgIHMgPSBb
YiBeIGsgZm9yIGIsIGsgaW4gemlwKGJsb2NrLCBzdW0od1swOjRdLCBbXSkpXQogICAgZm9yIHIg
aW4gcmFuZ2UoMSwgMTEpOgogICAgICAgIHMgPSBbU1tiXSBmb3IgYiBpbiBzXQogICAgICAgIHMg
PSBbc1soKGMgKyBpKSAlIDQpICogNCArIGldIGZvciBjIGluIHJhbmdlKDQpIGZvciBpIGluIHJh
bmdlKDQpXSAgICAgIyBTaGlmdFJvd3MKICAgICAgICBpZiByIDwgMTA6CiAgICAgICAgICAgIG0g
PSBbXQogICAgICAgICAgICBmb3IgYyBpbiByYW5nZSg0KToKICAgICAgICAgICAgICAgIGEgPSBz
W2MgKiA0OmMgKiA0ICsgNF07IHQgPSBhWzBdIF4gYVsxXSBeIGFbMl0gXiBhWzNdCiAgICAgICAg
ICAgICAgICBtICs9IFthW2ldIF4gdCBeIF94dChhW2ldIF4gYVsoaSArIDEpICUgNF0pIGZvciBp
IGluIHJhbmdlKDQpXQogICAgICAgICAgICBzID0gbQogICAgICAgIHMgPSBbYiBeIGsgZm9yIGIs
IGsgaW4gemlwKHMsIHN1bSh3W3IgKiA0OnIgKiA0ICsgNF0sIFtdKSldCiAgICByZXR1cm4gYnl0
ZXMocykKCmRlZiBtaWxlbmFnZV9vcGMoa19oZXgsIG9wX2hleCk6CiAgICBrLCBvcCA9IGJ5dGVz
LmZyb21oZXgoa19oZXgpLCBieXRlcy5mcm9taGV4KG9wX2hleCkKICAgIHJldHVybiBieXRlcyhh
IF4gYiBmb3IgYSwgYiBpbiB6aXAoYWVzMTI4X2VuY3J5cHQoaywgb3ApLCBvcCkpLmhleCgpLnVw
cGVyKCkKCmRlZiBsdWhuKGRpZ2l0cyk6CiAgICB0b3QgPSAwCiAgICBmb3IgaSwgY2ggaW4gZW51
bWVyYXRlKHJldmVyc2VkKGRpZ2l0cykpOgogICAgICAgIGQgPSBpbnQoY2gpCiAgICAgICAgaWYg
aSAlIDIgPT0gMDoKICAgICAgICAgICAgZCAqPSAyCiAgICAgICAgICAgIGlmIGQgPiA5OiBkIC09
IDkKICAgICAgICB0b3QgKz0gZAogICAgcmV0dXJuIHN0cigoMTAgLSB0b3QgJSAxMCkgJSAxMCkK
CmRlZiBfcmFuZF9kaWdpdHMobik6CiAgICByZXR1cm4gIiIuam9pbihzdHIoc2VjcmV0cy5yYW5k
YmVsb3coMTApKSBmb3IgXyBpbiByYW5nZShuKSkKCmRlZiBzaW1fZ2VuZXJhdGUoY291bnQ9MSwg
bXNpc2RuX3N0YXJ0PSIiLCBpY2NpZF9wcmVmaXg9IiIpOgogICAgbWNjLCBtbmMgPSBDLmdldCgi
TUNDIiwgIjAwMSIpLCBDLmdldCgiTU5DIiwgIjAxIikKICAgIGNvdW50ID0gbWF4KDEsIG1pbig1
MCwgaW50KGNvdW50IG9yIDEpKSkKICAgIHVzZWQgPSBzZXQoc2ltc19sb2FkKCkpIHwgc2V0KG51
bXNfbG9hZCgpKQogICAgdGFrZW5fbnIgPSBzZXQobnVtc19sb2FkKCkudmFsdWVzKCkpIHwge3Mu
Z2V0KCJtc2lzZG4iLCAiIikgZm9yIHMgaW4gc2ltc19sb2FkKCkudmFsdWVzKCl9CiAgICBuciA9
IGludChyZS5zdWIociJcRCIsICIiLCBtc2lzZG5fc3RhcnQgb3IgIiIpIG9yIDApCiAgICBwcmVm
ID0gcmUuc3ViKHIiXEQiLCAiIiwgaWNjaWRfcHJlZml4IG9yICIiKSBvciAoIjg5IiArIG1jYyAr
IG1uYykKICAgIHByZWYgPSBwcmVmWzoxNl0KICAgIG91dCA9IFtdCiAgICB3aGlsZSBsZW4ob3V0
KSA8IGNvdW50OgogICAgICAgIGltc2kgPSBtY2MgKyBtbmMgKyBfcmFuZF9kaWdpdHMoMTUgLSBs
ZW4obWNjKSAtIGxlbihtbmMpKQogICAgICAgIGlmIGltc2kgaW4gdXNlZDogY29udGludWUKICAg
ICAgICB1c2VkLmFkZChpbXNpKQogICAgICAgIGtpID0gc2VjcmV0cy50b2tlbl9oZXgoMTYpLnVw
cGVyKCk7IG9wID0gc2VjcmV0cy50b2tlbl9oZXgoMTYpLnVwcGVyKCkKICAgICAgICBib2R5ID0g
cHJlZiArIF9yYW5kX2RpZ2l0cygxOCAtIGxlbihwcmVmKSkKICAgICAgICBtc2lzZG4gPSAiIgog
ICAgICAgIGlmIG5yOgogICAgICAgICAgICB3aGlsZSBzdHIobnIpIGluIHRha2VuX25yOiBuciAr
PSAxCiAgICAgICAgICAgIG1zaXNkbiA9IHN0cihucik7IHRha2VuX25yLmFkZChtc2lzZG4pOyBu
ciArPSAxCiAgICAgICAgb3V0LmFwcGVuZCh7ImljY2lkIjogYm9keSArIGx1aG4oYm9keSksICJp
bXNpIjogaW1zaSwgImtpIjoga2ksICJvcCI6IG9wLAogICAgICAgICAgICAgICAgICAgICJvcGMi
OiBtaWxlbmFnZV9vcGMoa2ksIG9wKSwgImFtZiI6ICI4MDAwIiwgInNxbiI6ICIwMDAwMDAwMDAw
MjAiLAogICAgICAgICAgICAgICAgICAgICJtc2lzZG4iOiBtc2lzZG4sICJwaW4xIjogIjAwMDAi
LCAicHVrMSI6IF9yYW5kX2RpZ2l0cyg4KSwKICAgICAgICAgICAgICAgICAgICAicGluMiI6ICIw
MDAwIiwgInB1azIiOiBfcmFuZF9kaWdpdHMoOCksICJhZG0xIjogX3JhbmRfZGlnaXRzKDgpLAog
ICAgICAgICAgICAgICAgICAgICJzcG4iOiBDLmdldCgiU1BOIikgb3IgQy5nZXQoIk5FVE5BTUUi
LCAiIiksICJocGxtbiI6IG1jYyArIG1uY30pCiAgICByZXR1cm4gb3V0CgojIC0tLS0gU0lNLURh
dGVpZW4gZnVlciBkYXMgZVNJTS1Qcm9maWwgKE9QTCAvIFBOTiAvIFNQTikKIyBEaWVzZSBkcmVp
IERhdGVpZW4gbGllZ2VuIGF1ZiBkZXIgU0lNLCBuaWNodCBpbSBOZXR6LiBwS09NIGJlcmVjaG5l
dCBkaWUgV2VydGUKIyBwYXNzZW5kIHp1IEtlbm51bmcgKyBOZXR6bmFtZTsgc2llIHdlcmRlbiBp
bSBlU0lNLVByb2ZpbCBlaW5nZXRyYWdlbi4KR1NNNyA9ICgiQMKjJMKlw6jDqcO5w6zDssOHXG7D
mMO4XHLDhcOlzpRfzqbOk86bzqnOoM6ozqPOmM6eXHgxYsOGw6bDn8OJICFcIiPCpCUmJygpKiss
LS4vMDEyMzQ1Njc4OTo7PD0+PyIKICAgICAgICAiwqFBQkNERUZHSElKS0xNTk9QUVJTVFVWV1hZ
WsOEw5bDkcOcwqfCv2FiY2RlZmdoaWprbG1ub3BxcnN0dXZ3eHl6w6TDtsOxw7zDoCIpCgpkZWYg
Z3NtN19jb2RlcyhzKToKICAgIHJldHVybiBbR1NNNy5pbmRleChjaCkgaWYgY2ggaW4gR1NNNyBh
bmQgY2ggbm90IGluICJcblxyXHgxYiIgZWxzZSAweDNGIGZvciBjaCBpbiAocyBvciAiIildCgpk
ZWYgZ3NtN19wYWNrKGNvZGVzKToKICAgIGJpdHMgPSBuID0gMDsgb3V0ID0gYnl0ZWFycmF5KCkK
ICAgIGZvciBjIGluIGNvZGVzOgogICAgICAgIGJpdHMgfD0gKGMgJiAweDdGKSA8PCBuOyBuICs9
IDcKICAgICAgICB3aGlsZSBuID49IDg6CiAgICAgICAgICAgIG91dC5hcHBlbmQoYml0cyAmIDB4
RkYpOyBiaXRzID4+PSA4OyBuIC09IDgKICAgIGlmIG46IG91dC5hcHBlbmQoYml0cyAmIDB4RkYp
CiAgICByZXR1cm4gYnl0ZXMob3V0KSwgKDggLSAobGVuKGNvZGVzKSAqIDcpICUgOCkgJSA4Cgpk
ZWYgX25uX2llKHRhZywgbmFtZSk6CiAgICAiIiJOZXR6bmFtZS1JRSAoVFMgMjQuMDA4IDEwLjUu
My41YSk6IEdTTS03LCBvaG5lIExhZW5kZXJrdWVyemVsLiIiIgogICAgcGFja2VkLCBzcGFyZSA9
IGdzbTdfcGFjayhnc203X2NvZGVzKG5hbWUpKQogICAgYm9keSA9IGJ5dGVzKFsweDgwIHwgc3Bh
cmVdKSArIHBhY2tlZAogICAgcmV0dXJuIGJ5dGVzKFt0YWcsIGxlbihib2R5KV0pICsgYm9keQoK
ZGVmIHBsbW5fYmNkKG1jYywgbW5jKToKICAgIG0zID0gbW5jWzJdIGlmIGxlbihtbmMpID09IDMg
ZWxzZSAiRiIKICAgIHJldHVybiBieXRlcyhbaW50KG1jY1sxXSArIG1jY1swXSwgMTYpLCBpbnQo
bTMgKyBtY2NbMl0sIDE2KSwgaW50KG1uY1sxXSArIG1uY1swXSwgMTYpXSkKCmRlZiBzaW1fZmls
ZXMoKToKICAgIG1jYywgbW5jID0gQy5nZXQoIk1DQyIsICIiKSwgQy5nZXQoIk1OQyIsICIiKQog
ICAgZnVsbCA9IEMuZ2V0KCJORVROQU1FIikgb3IgInBLT00iOyBzaG9ydCA9IEMuZ2V0KCJORVRO
QU1FX1NIT1JUIikgb3IgZnVsbAogICAgc3BuID0gKEMuZ2V0KCJTUE4iKSBvciBmdWxsKVs6MTZd
CiAgICB0cnk6IHBsbW4gPSBwbG1uX2JjZChtY2MsIG1uYykKICAgIGV4Y2VwdCBFeGNlcHRpb246
IHBsbW4gPSBiIlx4ZmZceGZmXHhmZiIKICAgIHNwbl9iID0gYnl0ZXMoWzB4MDBdKSArIGJ5dGVz
KGdzbTdfY29kZXMoc3BuKSkgKyBiIlx4ZmYiICogKDE2IC0gbGVuKHNwbikpCiAgICBwbm4gPSBf
bm5faWUoMHg0MywgZnVsbCkgKyBfbm5faWUoMHg0NSwgc2hvcnQpCiAgICBvcGwgPSBwbG1uICsg
YiJceDAwXHgwMFx4ZmZceGZlXHgwMSIgICAgICAgICAgIyBMQUMvVEFDIDAwMDAtRkZGRSAtPiBQ
Tk4tRWludHJhZyAxCiAgICBoeCA9IGxhbWJkYSBiOiBiLmhleCgpLnVwcGVyKCkKICAgIHJldHVy
biB7InNwbiI6IGh4KHNwbl9iKSwgInBubiI6IGh4KHBubiksICJvcGwiOiBoeChvcGwpLCAicGxt
biI6IGh4KHBsbW4pLAogICAgICAgICAgICAiaHBsbW4iOiBtY2MgKyBtbmMsICJzcG5fdGV4dCI6
IHNwbiwgImZ1bGwiOiBmdWxsLCAic2hvcnQiOiBzaG9ydH0KCiMgLS0tLSBTTVMgdWViZXIgb3Nt
by1tc2MgVlRZCiMgRGllIE1TQyBwdWZmZXJ0IE1ULVNNUyBpbiBpaHJlciBEQiB1bmQgc3RlbGx0
IHNpZSBiZWltIEVpbmJ1Y2hlbiB6dSAtIGRlcgojIFRlaWxuZWhtZXIgbXVzcyBiZWltIFNlbmRl
biBhbHNvIG5pY2h0IHp3aW5nZW5kIHNjaG9uIGFuZ2VtZWxkZXQgc2Vpbi4KIyBBYnNlbmRlciBp
c3QgZWluZSBmcmVpZSBOdW1tZXIgKEdTTV9TTVNfRlJPTSksIGtlaW4gZWNodGVyIFRlaWxuZWht
ZXIgbm9ldGlnLgpkZWYgX2V4dGVybl9ucihudW1tZXIpOgogICAgIiIiSW50ZXJuZSBOdW1tZXIg
LT4gZXh0ZXJuIGVycmVpY2hiYXJlIE51bW1lciAoVm9yd2FobC1CbG9jayArIGludGVybmUgTnVt
bWVyKS4iIiIKICAgIG51bW1lciA9IHJlLnN1YihyIlxEIiwgIiIsIG51bW1lciBvciAiIikKICAg
IGlmIG5vdCBudW1tZXI6IHJldHVybiAiIgogICAgcHJlZiA9IEMuZ2V0KCJHU01fU01TX0VYVFBS
RUZJWCIsICIiKS5zdHJpcCgpCiAgICByZXR1cm4gKHByZWYgKyBudW1tZXIpIGlmIHByZWYgZWxz
ZSBudW1tZXIKCmRlZiBfc21zX3RleHQodG1wbCwgbnVtbWVyPSIiKToKICAgIHQgPSAodG1wbCBv
ciAiIikucmVwbGFjZSgie25ldHp9IiwgQy5nZXQoIk5FVE5BTUUiLCAiIikpIFwKICAgICAgICAg
ICAgICAgICAgICAucmVwbGFjZSgie2V4dGVybn0iLCBfZXh0ZXJuX25yKG51bW1lcikpLnJlcGxh
Y2UoIntudW1tZXJ9IiwgbnVtbWVyKQogICAgdCA9IHJlLnN1YihyJ1tcclxuXHQ/Il0nLCAiICIs
IHQpICAgICAgICAgICMgVlRZLVplaWxlOiBrZWluZSBVbWJydWVjaGUvVGFicy8/LUhpbGZlL1F1
b3RlcwogICAgcmV0dXJuIHJlLnN1YihyIlxzKyIsICIgIiwgdCkuc3RyaXAoKVs6MTYwXQoKZGVm
IHNtc19zZW5kKGltc2ksIHRleHQsIGZvcmNlPUZhbHNlKToKICAgIGltc2kgPSByZS5zdWIociJc
RCIsICIiLCBpbXNpIG9yICIiKQogICAgaWYgRkFLRSBvciBub3QgZ3NtX29uKCkgb3Igbm90IGlt
c2kgb3Igbm90IHRleHQ6CiAgICAgICAgcmV0dXJuCiAgICBpZiBDLmdldCgiR1NNX1NNUyIsICIx
IikgIT0gIjEiIGFuZCBub3QgZm9yY2U6ICAgIyBBdXRvLVNNUyBhdXMgKFRlc3QgaWdub3JpZXJ0
IGRhcykKICAgICAgICByZXR1cm4KICAgIGZybSA9IHJlLnN1YihyIlxEIiwgIiIsIEMuZ2V0KCJH
U01fU01TX0ZST00iLCAiIikpIG9yICIxMDAwIgogICAgciA9IHZ0eShNU0NfVlRZLCBbImVuYWJs
ZSIsCiAgICAgICAgICAgICAgICAgICAgICBmInN1YnNjcmliZXIgaW1zaSB7aW1zaX0gc21zIHNl
bmRlciBtc2lzZG4ge2ZybX0gc2VuZCB7dGV4dH0iXSkKICAgIGlmICIlICIgaW4gcjoKICAgICAg
ICBsb2coInNtcy1mZWhsZXI6IiwgKHIuc3RyaXAoKS5zcGxpdGxpbmVzKCkgb3IgW3JdKVstMV1b
OjE0MF0pCgpkZWYgc21zX3Rlc3QoaW1zaSwgdGV4dD0iIik6CiAgICBpbXNpID0gcmUuc3ViKHIi
XEQiLCAiIiwgaW1zaSBvciAiIikKICAgIGlmIGxlbihpbXNpKSA8IDE0OiAgcmV0dXJuICJJTVNJ
IGFuZ2ViZW4gKDE0LTE1IFppZmZlcm4pIgogICAgaWYgRkFLRTogICAgICAgICAgICByZXR1cm4g
IlRlc3Rtb2R1cyAoRkFLRSk6IG5pY2h0cyBnZXNlbmRldCIKICAgIGlmIG5vdCBnc21fb24oKTog
cmV0dXJuICJHU00tTmV0eiBsYWV1ZnQgbmljaHQgKEdTTSBvZGVyIExURSArIEdTTSBzdGFydGVu
KSIKICAgIHR4dCA9IF9zbXNfdGV4dCh0ZXh0KSBpZiAodGV4dCBvciAiIikuc3RyaXAoKSBlbHNl
IF9zbXNfdGV4dChDLmdldCgiR1NNX1NNU19XRUxDT01FIiwgIiIpKQogICAgc21zX3NlbmQoaW1z
aSwgdHh0LCBmb3JjZT1UcnVlKQogICAgcmV0dXJuIGYiVGVzdC1TTVMgYW4ge2ltc2l9IGdlc2Vu
ZGV0IgoKZGVmIG1zY19hdHRhY2hlZCgpOgogICAgIiIiSU1TSXMsIGRpZSBha3R1ZWxsIGluIGRl
ciBNU0MgKFZMUikgZWluZ2VidWNodCBzaW5kLiIiIgogICAgaWYgRkFLRSBvciBub3QgZ3NtX29u
KCk6CiAgICAgICAgcmV0dXJuIHNldCgpCiAgICB0eHQgPSB2dHkoTVNDX1ZUWSwgWyJlbmFibGUi
LCAic2hvdyBzdWJzY3JpYmVyIGNhY2hlIl0pCiAgICByZXR1cm4gc2V0KHJlLmZpbmRhbGwociJJ
TVNJXER7MCwzfShcZHsxNCwxNX0pIiwgdHh0KSkKCmRlZiBzbXNfd2VsY29tZV93YXRjaCgpOgog
ICAgIiIiSGludGVyZ3J1bmQ6IG5ldWUgRWluYnVjaHVuZ2VuIGVya2VubmVuIHVuZCBlaW5tYWxp
ZyBiZWdydWVzc2VuLiIiIgogICAgd2hpbGUgVHJ1ZToKICAgICAgICB0cnk6CiAgICAgICAgICAg
IGlmIGdzbV9vbigpIGFuZCBORVQuc3RhdGUgPT0gImxhZXVmdCIgYW5kIEMuZ2V0KCJHU01fU01T
IiwgIjEiKSA9PSAiMSI6CiAgICAgICAgICAgICAgICBmb3IgaW1zaSBpbiBtc2NfYXR0YWNoZWQo
KSAtIE5FVC53ZWxjb21lZDoKICAgICAgICAgICAgICAgICAgICBORVQud2VsY29tZWQuYWRkKGlt
c2kpICAgICAgIyB2b3IgZGVtIFNlbmRlbiBtZXJrZW46IGtlaW4gU3BhbSBiZWkgRmVobGVyCiAg
ICAgICAgICAgICAgICAgICAgbG9nKCJ3aWxsa29tbWVucy1zbXMgLT4iLCBpbXNpKQogICAgICAg
ICAgICAgICAgICAgIHNtc19zZW5kKGltc2ksIF9zbXNfdGV4dChDLmdldCgiR1NNX1NNU19XRUxD
T01FIiwgIiIpKSkKICAgICAgICBleGNlcHQgRXhjZXB0aW9uIGFzIGU6CiAgICAgICAgICAgIGxv
Zygic21zLXdhdGNoOiIsIGUpCiAgICAgICAgdGltZS5zbGVlcCg2KQoKIyA9PT09PT09PT09PT09
PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT0gTFRF
OiBzcnNFTkIgKEZ1bmspICsgT3BlbjVHUyAoS2VybikKIyBPcGVuNUdTIHN0YXR0IHNyc0VQQywg
d2VpbCBudXIgZGVzc2VuIE1NRSBkaWUgU0dzLVNjaG5pdHRzdGVsbGUgenVyIG9zbW8tbXNjCiMg
aGF0IChDU0ZCKS4gRGllIE9wZW41R1MtRGllbnN0ZSBsYXVmZW4gbmljaHQgdWViZXIgc3lzdGVt
ZCwgc29uZGVybiB3ZXJkZW4gdm9uCiMgcEtPTSBtaXQgZWlnZW5lbiBLb25maWdzIGdlc3RhcnRl
dCAoVm9ybGFnZTogL2V0Yy9vcGVuNWdzLyoueWFtbCkuCk81X0VUQyA9ICIvZXRjL29wZW41Z3Mi
Ck81X0RJUiA9IG9zLnBhdGguam9pbihXT1JLRElSLCAib3BlbjVncyIpCk81X05GUyA9IFsoIm5y
ZiIsICJvcGVuNWdzLW5yZmQiKSwgKCJzY3AiLCAib3BlbjVncy1zY3BkIiksICgiaHNzIiwgIm9w
ZW41Z3MtaHNzZCIpLAogICAgICAgICAgKCJwY3JmIiwgIm9wZW41Z3MtcGNyZmQiKSwgKCJzZ3dj
IiwgIm9wZW41Z3Mtc2d3Y2QiKSwgKCJzZ3d1IiwgIm9wZW41Z3Mtc2d3dWQiKSwKICAgICAgICAg
ICgic21mIiwgIm9wZW41Z3Mtc21mZCIpLCAoInVwZiIsICJvcGVuNWdzLXVwZmQiKSwgKCJtbWUi
LCAib3BlbjVncy1tbWVkIildCk81X09QVElPTkFMID0geyJucmYiLCAic2NwIn0KVUVfTkVULCBV
RV9HVyA9ICIxMC40NS4wLjAvMTYiLCAiMTAuNDUuMC4xLzE2IiAgICAgICAjIE9wZW41R1MtU3Rh
bmRhcmQgKHNtZi91cGYueWFtbCkKTlBSQl9NSFogPSB7NjogMS40LCAxNTogMywgMjU6IDUsIDUw
OiAxMCwgNzU6IDE1LCAxMDA6IDIwfQpTR1NfUE9SVCA9IDI5MTE4CgpkZWYgX3BsbW5fd2Fsayhv
LCBtY2MsIG1uYyk6CiAgICAiIiJKZWRlIFBMTU4tQW5nYWJlIChtY2MvbW5jKSBpbiBlaW5lciBP
cGVuNUdTLUtvbmZpZyBhdWYgZGllIGVpZ2VuZSBLZW5udW5nIHNldHplbi4iIiIKICAgIGlmIGlz
aW5zdGFuY2UobywgZGljdCk6CiAgICAgICAgaWYgIm1jYyIgaW4gbyBhbmQgIm1uYyIgaW4gbzoK
ICAgICAgICAgICAgb1sibWNjIl0gPSBtY2M7IG9bIm1uYyJdID0gbW5jICAgICAgIyBhbHMgVGV4
dDogZnVlaHJlbmRlIE51bGxlbiArIE1OQy1MYWVuZ2UgYmxlaWJlbgogICAgICAgIGZvciB2IGlu
IG8udmFsdWVzKCk6IF9wbG1uX3dhbGsodiwgbWNjLCBtbmMpCiAgICBlbGlmIGlzaW5zdGFuY2Uo
bywgbGlzdCk6CiAgICAgICAgZm9yIHYgaW4gbzogX3BsbW5fd2Fsayh2LCBtY2MsIG1uYykKCmRl
ZiBnc21fbGFjKCk6CiAgICB0cnk6CiAgICAgICAgdCA9IG9wZW4ob3MucGF0aC5qb2luKFdPUktE
SVIsICJvc21vLWJzYy5jZmciKSkucmVhZCgpCiAgICAgICAgbSA9IHJlLnNlYXJjaChyIig/bSle
XHMqbG9jYXRpb25fYXJlYV9jb2RlXHMrKD86bGFjXHMrKT8oMHhbMC05YS1mQS1GXSt8XGQrKSIs
IHQpCiAgICAgICAgaWYgbTogcmV0dXJuIGludChtLmdyb3VwKDEpLCAwKQogICAgZXhjZXB0IEV4
Y2VwdGlvbjogcGFzcwogICAgcmV0dXJuIDEKCmRlZiBvNV9wcmVwYXJlKGNzZmIsIGV0Yz1PNV9F
VEMsIG91dGRpcj1PNV9ESVIpOgogICAgIiIiT3BlbjVHUy1Lb25maWdzIGVyemV1Z2VuLiBSdWVj
a2dhYmU6IHtuZjogKGJpbmFyeSwgeWFtbC1wZmFkKX0gaW4gU3RhcnRyZWloZW5mb2xnZS4iIiIK
ICAgIGltcG9ydCB5YW1sCiAgICBvcy5tYWtlZGlycyhvdXRkaXIsIGV4aXN0X29rPVRydWUpCiAg
ICBtY2MsIG1uYyA9IENbIk1DQyJdLCBDWyJNTkMiXTsgdGFjID0gaW50KEMuZ2V0KCJMVEVfVEFD
Iikgb3IgNykKICAgIHBsbW4gPSB7Im1jYyI6IG1jYywgIm1uYyI6IG1uY30KICAgIG91dCA9IHt9
CiAgICBmb3IgbmYsIGJpbmFyeSBpbiBPNV9ORlM6CiAgICAgICAgc3JjID0gb3MucGF0aC5qb2lu
KGV0YywgbmYgKyAiLnlhbWwiKQogICAgICAgIGlmIG5vdCBvcy5wYXRoLmlzZmlsZShzcmMpOgog
ICAgICAgICAgICBpZiBuZiBpbiBPNV9PUFRJT05BTDogY29udGludWUKICAgICAgICAgICAgcmFp
c2UgUnVudGltZUVycm9yKGYie3NyY30gZmVobHQgLSBpc3QgT3BlbjVHUyBpbnN0YWxsaWVydD8i
KQogICAgICAgIG8gPSB5YW1sLnNhZmVfbG9hZChvcGVuKHNyYykpIG9yIHt9CiAgICAgICAgby5w
b3AoImxvZ2dlciIsIE5vbmUpICAgICAgICAgICAgICAgICAgICAgICAjIExvZyBuYWNoIHN0ZG91
dCAtPiBQcm90b2tvbGwtVGFiCiAgICAgICAgX3BsbW5fd2FsayhvLCBtY2MsIG1uYykKICAgICAg
ICBpZiBuZiA9PSAibW1lIjoKICAgICAgICAgICAgbSA9IG8uc2V0ZGVmYXVsdCgibW1lIiwge30p
CiAgICAgICAgICAgIGlmIEMuZ2V0KCJOSVRaIiwgIjEiKSA9PSAiMSI6ICAgICAgICAgICAjIEVN
TS1JbmZvcm1hdGlvbjogTmV0em5hbWUgKyBaZWl0L1plaXR6b25lCiAgICAgICAgICAgICAgICBt
WyJuZXR3b3JrX25hbWUiXSA9IHsiZnVsbCI6IENbIk5FVE5BTUUiXSwgInNob3J0IjogQy5nZXQo
Ik5FVE5BTUVfU0hPUlQiKSBvciBDWyJORVROQU1FIl19CiAgICAgICAgICAgIGVsc2U6CiAgICAg
ICAgICAgICAgICBtLnBvcCgibmV0d29ya19uYW1lIiwgTm9uZSkKICAgICAgICAgICAgdGFpID0g
bS5nZXQoInRhaSIpCiAgICAgICAgICAgIHRhaXMgPSB0YWkgaWYgaXNpbnN0YW5jZSh0YWksIGxp
c3QpIGVsc2UgKFt0YWldIGlmIGlzaW5zdGFuY2UodGFpLCBkaWN0KSBlbHNlIFtdKQogICAgICAg
ICAgICBmb3IgdCBpbiB0YWlzOiB0WyJ0YWMiXSA9IHRhYwogICAgICAgICAgICBpZiBub3QgdGFp
czogbVsidGFpIl0gPSBbeyJwbG1uX2lkIjogZGljdChwbG1uKSwgInRhYyI6IHRhY31dCiAgICAg
ICAgICAgIG5ld19mbXQgPSBpc2luc3RhbmNlKG0uZ2V0KCJzMWFwIiksIGRpY3QpICAgIyBPcGVu
NUdTID49IDIuNwogICAgICAgICAgICBvLnBvcCgic2dzYXAiLCBOb25lKTsgbS5wb3AoInNnc2Fw
IiwgTm9uZSkKICAgICAgICAgICAgaWYgY3NmYjoKICAgICAgICAgICAgICAgIG1wID0geyJ0YWki
OiB7InBsbW5faWQiOiBkaWN0KHBsbW4pLCAidGFjIjogdGFjfSwKICAgICAgICAgICAgICAgICAg
ICAgICJsYWkiOiB7InBsbW5faWQiOiBkaWN0KHBsbW4pLCAibGFjIjogZ3NtX2xhYygpfX0KICAg
ICAgICAgICAgICAgIGlmIG5ld19mbXQ6CiAgICAgICAgICAgICAgICAgICAgbVsic2dzYXAiXSA9
IHsiY2xpZW50IjogW3siYWRkcmVzcyI6ICIxMjcuMC4wLjEiLCAibG9jYWxfYWRkcmVzcyI6ICIx
MjcuMC4wLjIiLAogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
InBvcnQiOiBTR1NfUE9SVCwgIm1hcCI6IG1wfV19CiAgICAgICAgICAgICAgICBlbHNlOgogICAg
ICAgICAgICAgICAgICAgIG9bInNnc2FwIl0gPSBbeyJhZGRyIjogIjEyNy4wLjAuMSIsICJwb3J0
IjogU0dTX1BPUlQsICJtYXAiOiBtcH1dCiAgICAgICAgZHN0ID0gb3MucGF0aC5qb2luKG91dGRp
ciwgbmYgKyAiLnlhbWwiKQogICAgICAgIHdpdGggb3Blbihkc3QsICJ3IikgYXMgZjoKICAgICAg
ICAgICAgeWFtbC5zYWZlX2R1bXAobywgZiwgZGVmYXVsdF9mbG93X3N0eWxlPUZhbHNlLCBzb3J0
X2tleXM9RmFsc2UsIGFsbG93X3VuaWNvZGU9VHJ1ZSkKICAgICAgICBvdXRbbmZdID0gKGJpbmFy
eSwgZHN0KQogICAgcmV0dXJuIG91dAoKU1JTX01BUksgPSB7InNpYi5jb25mIjogciIoP20pXnNp
YjFccyo9IiwgInJyLmNvbmYiOiByIig/bSleY2VsbF9saXN0XHMqPSIsICJyYi5jb25mIjogciIo
P20pXlx3K1xzKj0ifQoKZGVmIF9zcnNfdGVtcGxhdGUobmFtZSk6CiAgICAiIiJWb3JsYWdlIHN1
Y2hlbiAtIG51ciBEYXRlaWVuLCBkaWUgd2lya2xpY2ggZGVuIGVyd2FydGV0ZW4gSW5oYWx0IGhh
YmVuCiAgICAoZWluZSBsZWVyZS9mYWxzY2hlIC9ldGMvc3JzcmFuL3NpYi5jb25mIGZ1ZWhydGUg
enUgJ3NlY3Rpb24gc2liMSBub3QgZm91bmQnKS4iIiIKICAgIGNhbmRzID0gKG9zLnBhdGguam9p
bihTUlNfQ0ZHLCBuYW1lKSwgZiIvdXNyL2xvY2FsL3NoYXJlL3Nyc3Jhbi97bmFtZX0uZXhhbXBs
ZSIsCiAgICAgICAgICAgICBmIi91c3Ivc2hhcmUvc3JzcmFuL3tuYW1lfS5leGFtcGxlIiwgZiIv
dXNyL3NoYXJlL3Nyc3Jhbi97bmFtZX0iLAogICAgICAgICAgICAgZiIvdXNyL3NoYXJlL2RvYy9z
cnNyYW4vZXhhbXBsZXMve25hbWV9LmV4YW1wbGUiKQogICAgZm9yIHAgaW4gY2FuZHM6CiAgICAg
ICAgdHJ5OiB0ID0gb3BlbihwLCBlbmNvZGluZz0idXRmLTgiLCBlcnJvcnM9InJlcGxhY2UiKS5y
ZWFkKCkKICAgICAgICBleGNlcHQgT1NFcnJvcjogY29udGludWUKICAgICAgICBpZiByZS5zZWFy
Y2goU1JTX01BUksuZ2V0KG5hbWUsIHIiXFMiKSwgdCk6IHJldHVybiBwCiAgICAgICAgbG9nKGYi
c3JzUkFOLVZvcmxhZ2Uge3B9IHVuYnJhdWNoYmFyIC0gdWViZXJzcHJ1bmdlbiIpCiAgICByZXR1
cm4gTm9uZQoKZGVmIF9kcm9wX2Jsb2NrKHQsIG5hbWUpOgogICAgIiIibGliY29uZmlnLUJsb2Nr
ICduYW1lID0geyAuLi4gfTsnIGVudGZlcm5lbiAoS2xhbW1lcm4gZ2V6YWVobHQpLiIiIgogICAg
bSA9IHJlLnNlYXJjaChyZiIoP20pXntuYW1lfVxzKj1ccypce3siLCB0KQogICAgaWYgbm90IG06
IHJldHVybiB0CiAgICBpID0gdC5pbmRleCgieyIsIG0uc3RhcnQoKSk7IGRlcHRoID0gMAogICAg
Zm9yIGogaW4gcmFuZ2UoaSwgbGVuKHQpKToKICAgICAgICBpZiB0W2pdID09ICJ7IjogZGVwdGgg
Kz0gMQogICAgICAgIGVsaWYgdFtqXSA9PSAifSI6CiAgICAgICAgICAgIGRlcHRoIC09IDEKICAg
ICAgICAgICAgaWYgZGVwdGggPT0gMDoKICAgICAgICAgICAgICAgIGsgPSBqICsgMQogICAgICAg
ICAgICAgICAgd2hpbGUgayA8IGxlbih0KSBhbmQgdFtrXSBpbiAiIFx0OyI6IGsgKz0gMQogICAg
ICAgICAgICAgICAgcmV0dXJuIHRbOm0uc3RhcnQoKV0gKyB0W2s6XQogICAgcmV0dXJuIHQKCmRl
ZiBfc2lfbWFwcGluZyh0LCBhZGQ3KToKICAgIGRlZiBmKG0pOgogICAgICAgIG51bXMgPSBbeC5z
dHJpcCgpIGZvciB4IGluIG0uZ3JvdXAoMikuc3BsaXQoIiwiKSBpZiB4LnN0cmlwKCkgYW5kIHgu
c3RyaXAoKSAhPSAiNyJdCiAgICAgICAgaWYgYWRkNzogbnVtcy5hcHBlbmQoIjciKQogICAgICAg
IHJldHVybiBtLmdyb3VwKDEpICsgIiwgIi5qb2luKG51bXMpICsgbS5ncm91cCgzKQogICAgcmV0
dXJuIHJlLnN1YihyIihzaV9tYXBwaW5nX2luZm9ccyo9XHMqXFtccyopKFteXF1dKj8pKFxzKlxd
KSIsIGYsIHQsIGNvdW50PTEpCgpkZWYgc2liX3BhdGNoKHQsIGNzZmIsIGFyZmNuKToKICAgICIi
IlNJQjcgKEdFUkFOLU5hY2hiYXIpIG51ciBpbSBDU0ZCLU1vZHVzOiBzcnNFTkIgc2NoaWNrdCBk
YXMgSGFuZHkgYmVpCiAgICBlaW5lbSBBbnJ1ZiBwZXIgUlJDLVJlbGVhc2UgbWl0IFVtbGVpdHVu
ZyBhdWYgZ2VuYXUgZGllc2UgR1NNLUZyZXF1ZW56LiIiIgogICAgdCA9IF9kcm9wX2Jsb2NrKHQs
ICJzaWI3IikKICAgIHQgPSBfc2lfbWFwcGluZyh0LCBjc2ZiKQogICAgaWYgY3NmYjoKICAgICAg
ICB0ID0gdC5yc3RyaXAoKSArIGYiIiIKCi8vIHBLT006IEdTTS1aZWxsZSBmdWVyIENTLUZhbGxi
YWNrIChBbnJ1ZmUpCnNpYjcgPQp7ewogICAgdF9yZXNlbF9nZXJhbiA9IDE7CiAgICBjYXJyaWVy
X2ZyZXFzX2luZm9fbGlzdCA9CiAgICAoCiAgICAgICAge3sKICAgICAgICAgICAgY2VsbF9yZXNl
bF9wcmlvID0gMDsKICAgICAgICAgICAgbmNjX3Blcm1pdHRlZCA9IDI1NTsKICAgICAgICAgICAg
cV9yeF9sZXZfbWluID0gMDsKICAgICAgICAgICAgdGhyZXNoX3hfaGlnaCA9IDI7CiAgICAgICAg
ICAgIHRocmVzaF94X2xvdyA9IDI7CiAgICAgICAgICAgIHN0YXJ0X2FyZmNuID0ge2FyZmNufTsK
ICAgICAgICAgICAgYmFuZF9pbmQgPSAieydwY3MxOTAwJyBpZiBnc21fYmFuZCgpID09ICdQQ1Mx
OTAwJyBlbHNlICdkY3MxODAwJ30iOwogICAgICAgICAgICBleHBsaWNpdF9saXN0X29mX2FyZmNu
cyA9ICgge2FyZmNufSApOwogICAgICAgIH19CiAgICApOwp9fTsKIiIiCiAgICByZXR1cm4gdAoK
ZGVmIGVuYl9wcmVwYXJlKGNzZmIsIHNlcmlhbCk6CiAgICBmb3IgZiBpbiAoInJyLmNvbmYiLCAi
c2liLmNvbmYiLCAicmIuY29uZiIpOgogICAgICAgIHAgPSBfc3JzX3RlbXBsYXRlKGYpCiAgICAg
ICAgaWYgbm90IHA6IHJhaXNlIFJ1bnRpbWVFcnJvcihmInNyc1JBTi1Wb3JsYWdlIHtmfSBmZWhs
dCAtIGlzdCBzcnNyYW4gaW5zdGFsbGllcnQ/IikKICAgICAgICBzaHV0aWwuY29weShwLCBvcy5w
YXRoLmpvaW4oV09SS0RJUiwgZikpCiAgICBlYXJmY24gPSBpbnQoQ1siTFRFX0VBUkZDTiJdKTsg
dGFjID0gaW50KEMuZ2V0KCJMVEVfVEFDIikgb3IgNykKICAgIHJyID0gb3MucGF0aC5qb2luKFdP
UktESVIsICJyci5jb25mIik7IHQgPSBvcGVuKHJyKS5yZWFkKCkKICAgIHQgPSByZS5zdWIociIo
P20pXihccyp0YWNccyo9XHMqKVteO10rOyIsIHIiXGc8MT4weCUwNFg7IiAlIHRhYywgdCwgY291
bnQ9MSkKICAgIHQgPSByZS5zdWIociIoP20pXihccypkbF9lYXJmY25ccyo9XHMqKVxkKzsiLCBy
IlxnPDE+JWQ7IiAlIGVhcmZjbiwgdCwgY291bnQ9MSkgICMgMS4gPSBlaWdlbmUgWmVsbGUKICAg
IG9wZW4ocnIsICJ3Iikud3JpdGUodCkKICAgIHNpYiA9IG9zLnBhdGguam9pbihXT1JLRElSLCAi
c2liLmNvbmYiKQogICAgd2l0aCBvcGVuKHNpYikgYXMgZjogdCA9IGYucmVhZCgpICAgICAgICAg
ICMgZXJzdCBsZXNlbiAtIG9wZW4oLi4uLCJ3IikgbGVlcnQgZGllIERhdGVpIHNvZm9ydAogICAg
d2l0aCBvcGVuKHNpYiwgInciKSBhcyBmOiBmLndyaXRlKHNpYl9wYXRjaCh0LCBjc2ZiLCBpbnQo
Q1siR1NNX0FSRkNOIl0pKSkKICAgIGRldiA9ICJkcml2ZXI9bGltZSIgKyAoIixzZXJpYWw9IiAr
IHNlcmlhbCBpZiBzZXJpYWwgZWxzZSAiIikKICAgIG9wZW4ob3MucGF0aC5qb2luKFdPUktESVIs
ICJlbmIuY29uZiIpLCAidyIpLndyaXRlKGYiIiIjIHBLT00gLSBhdXRvbWF0aXNjaCBlcnpldWd0
CltlbmJdCmVuYl9pZCA9IDB4MTlCCm1jYyA9IHtDWydNQ0MnXX0KbW5jID0ge0NbJ01OQyddfQpt
bWVfYWRkciA9IDEyNy4wLjAuMgpndHBfYmluZF9hZGRyID0gMTI3LjAuMS4xCnMxY19iaW5kX2Fk
ZHIgPSAxMjcuMC4xLjEKczFjX2JpbmRfcG9ydCA9IDAKbl9wcmIgPSB7aW50KENbJ0xURV9OUFJC
J10pfQoKW2VuYl9maWxlc10Kc2liX2NvbmZpZyA9IHtzaWJ9CnJyX2NvbmZpZyA9IHtycn0KcmJf
Y29uZmlnID0ge29zLnBhdGguam9pbihXT1JLRElSLCAncmIuY29uZicpfQoKW3JmXQp0eF9nYWlu
ID0ge0NbJ0xURV9UWF9HQUlOJ119CnJ4X2dhaW4gPSB7Q1snTFRFX1JYX0dBSU4nXX0KZGV2aWNl
X25hbWUgPSBzb2FweQpkZXZpY2VfYXJncyA9IHtkZXZ9CgpbbG9nXQphbGxfbGV2ZWwgPSB3YXJu
aW5nCmZpbGVuYW1lID0gc3Rkb3V0CiIiIikKCmRlZiBfcnVuKCpjbWQpOgogICAgcmV0dXJuIHN1
YnByb2Nlc3MucnVuKGxpc3QoY21kKSwgc3Rkb3V0PXN1YnByb2Nlc3MuREVWTlVMTCwgc3RkZXJy
PXN1YnByb2Nlc3MuREVWTlVMTCkucmV0dXJuY29kZQoKZGVmIHVlX25ldF91cCgpOgogICAgIiIi
VHVubmVsIGZ1ZXIgZGllIEhhbmR5LURhdGVudmVyYmluZHVuZ2VuICsgTkFUIGlucyBJbnRlcm5l
dC4iIiIKICAgIF9ydW4oIm1vZHByb2JlIiwgInNjdHAiKQogICAgX3J1bigiaXAiLCAidHVudGFw
IiwgImFkZCIsICJuYW1lIiwgIm9nc3R1biIsICJtb2RlIiwgInR1biIpCiAgICBfcnVuKCJpcCIs
ICJhZGRyIiwgInJlcGxhY2UiLCBVRV9HVywgImRldiIsICJvZ3N0dW4iKQogICAgX3J1bigiaXAi
LCAibGluayIsICJzZXQiLCAib2dzdHVuIiwgInVwIikKICAgIF9ydW4oInN5c2N0bCIsICItdyIs
ICJuZXQuaXB2NC5pcF9mb3J3YXJkPTEiKQogICAgZm9yIGNoaywgYWRkIGluICgoWyItdCIsICJu
YXQiLCAiLUMiLCAiUE9TVFJPVVRJTkciLCAiLXMiLCBVRV9ORVQsICIhIiwgIi1vIiwgIm9nc3R1
biIsICItaiIsICJNQVNRVUVSQURFIl0sCiAgICAgICAgICAgICAgICAgICAgICBbIi10IiwgIm5h
dCIsICItQSIsICJQT1NUUk9VVElORyIsICItcyIsIFVFX05FVCwgIiEiLCAiLW8iLCAib2dzdHVu
IiwgIi1qIiwgIk1BU1FVRVJBREUiXSksCiAgICAgICAgICAgICAgICAgICAgIChbIi1DIiwgIkZP
UldBUkQiLCAiLWkiLCAib2dzdHVuIiwgIi1qIiwgIkFDQ0VQVCJdLCBbIi1JIiwgIkZPUldBUkQi
LCAiLWkiLCAib2dzdHVuIiwgIi1qIiwgIkFDQ0VQVCJdKSwKICAgICAgICAgICAgICAgICAgICAg
KFsiLUMiLCAiRk9SV0FSRCIsICItbyIsICJvZ3N0dW4iLCAiLWoiLCAiQUNDRVBUIl0sIFsiLUki
LCAiRk9SV0FSRCIsICItbyIsICJvZ3N0dW4iLCAiLWoiLCAiQUNDRVBUIl0pKToKICAgICAgICBp
ZiBfcnVuKCJpcHRhYmxlcyIsICpjaGspICE9IDA6IF9ydW4oImlwdGFibGVzIiwgKmFkZCkKCmRl
ZiBmcmVxX2NsYXNoKCk6CiAgICAiIiJHU00tVHJhZWdlciBkYXJmIG5pY2h0IGltIExURS1LYW5h
bCBsaWVnZW4gKGdsZWljaGVzIEJhbmQgMTgwMCBNSHopLiIiIgogICAgdHJ5OgogICAgICAgIGcg
PSBhcmZjbl9taHooaW50KENbIkdTTV9BUkZDTiJdKSk7IGwgPSBlYXJmY25fbWh6KGludChDWyJM
VEVfRUFSRkNOIl0pKQogICAgICAgIGJ3ID0gTlBSQl9NSFouZ2V0KGludChDWyJMVEVfTlBSQiJd
KSwgNSkKICAgICAgICBpZiBnIGFuZCBsIGFuZCBhYnMoZyAtIGwpIDwgYncgLyAyICsgMC4zOgog
ICAgICAgICAgICByZXR1cm4gZiJHU00ge2d9IE1IeiBsaWVndCBpbSBMVEUtS2FuYWwge2x9IE1I
eiDCsXtidy8yOmd9IC0gYW5kZXJlIEFSRkNOL0VBUkZDTiB3YWVobGVuIgogICAgZXhjZXB0IEV4
Y2VwdGlvbjogcGFzcwogICAgcmV0dXJuIE5vbmUKCmRlZiBwcmVmbGlnaHQobW9kZSk6CiAgICBt
Y2MsIG1uYyA9IEMuZ2V0KCJNQ0MiLCAiIikuc3RyaXAoKSwgQy5nZXQoIk1OQyIsICIiKS5zdHJp
cCgpCiAgICBpZiBub3QgcmUuZnVsbG1hdGNoKHIiXGR7M30iLCBtY2MpIG9yIG5vdCByZS5mdWxs
bWF0Y2gociJcZHsyLDN9IiwgbW5jKToKICAgICAgICByZXR1cm4gIk5ldHprZW5udW5nIHBydWVm
ZW46IE1DQyAzIFppZmZlcm4sIE1OQyAyLTMgWmlmZmVybiIKICAgIGlmIG1jYyBub3QgaW4gKCIw
MDEiLCAiOTk5Iik6CiAgICAgICAgcmV0dXJuICJOdXIgVGVzdC0vUHJpdmF0a2VubnVuZ2VuOiBN
Q0MgMDAxIChUZXN0KSBvZGVyIDk5OSAocHJpdmF0KSIKICAgIGlmIG1vZGUgaW4gKCJnc20iLCAi
Y3NmYiIpIGFuZCBub3QgZ3NtX2JhbmQoKToKICAgICAgICByZXR1cm4gZiJHU00tQVJGQ04ge0Nb
J0dTTV9BUkZDTiddfSBsaWVndCBpbiBrZWluZW0gQmFuZCAtIGltIFRhYiBHU00gQmFuZCB1bmQg
S2FuYWwgd2FlaGxlbiIKICAgIGlmIG1vZGUgaW4gKCJsdGUiLCAiY3NmYiIpOgogICAgICAgIGUg
PSBpbnQoQ1siTFRFX0VBUkZDTiJdKTsgYiA9IGVhcmZjbl9iYW5kKGUpCiAgICAgICAgaWYgbm90
IGI6IHJldHVybiBmIkVBUkZDTiB7ZX0gbGllZ3QgaW4ga2VpbmVtIHVudGVyc3R1ZXR6dGVuIExU
RS1CYW5kIC0gaW0gVGFiIExURSB3YWVobGVuIgogICAgICAgIGhhbGYgPSBpbnQoTlBSQl9NSFou
Z2V0KGludChDWyJMVEVfTlBSQiJdKSwgNSkgKiA1KSAgICAgICAgIyBoYWxiZSBCYW5kYnJlaXRl
IGluIDEwMC1rSHotU2Nocml0dGVuCiAgICAgICAgbG8sIGhpID0gTFRFX0JBTkRTW2JdWzNdLCBM
VEVfQkFORFNbYl1bNF0KICAgICAgICBpZiBlIC0gaGFsZiA8IGxvIG9yIGUgKyBoYWxmID4gaGk6
CiAgICAgICAgICAgIHJldHVybiBmIkVBUkZDTiB7ZX06IHtOUFJCX01IWi5nZXQoaW50KENbJ0xU
RV9OUFJCJ10pLCA1KTpnfSBNSHogcGFzc2VuIG5pY2h0IGlucyBCYW5kIHtifSAoe2xvICsgaGFs
Zn0te2hpIC0gaGFsZn0gbW9lZ2xpY2gpIgogICAgZywgbCA9IGxpbWVfYXNzaWduKG1vZGUpCiAg
ICBpZiBtb2RlID09ICJjc2ZiIjoKICAgICAgICBpZiBub3QgRkFLRSBhbmQgKG5vdCBnIG9yIG5v
dCBsIG9yIGcgPT0gbCk6CiAgICAgICAgICAgIHJldHVybiAiTFRFICsgR1NNIGJyYXVjaHQgendl
aSB2ZXJzY2hpZWRlbmUgTGltZVNEUiAtIGltIFRhYiBTdGV1ZXJ1bmcgenVvcmRuZW4iCiAgICAg
ICAgZSA9IGZyZXFfY2xhc2goKQogICAgICAgIGlmIGU6IHJldHVybiBlCiAgICBpZiBub3QgRkFL
RToKICAgICAgICBuZWVkID0gW10KICAgICAgICBpZiBtb2RlIGluICgiZ3NtIiwgImNzZmIiKTog
bmVlZCArPSBbYiBmb3IgX24sIGIsIF9jIGluIEdTTV9DT1JFXQogICAgICAgIGlmIG1vZGUgaW4g
KCJsdGUiLCAiY3NmYiIpOgogICAgICAgICAgICBuZWVkICs9IFsic3JzZW5iIl0gKyBbYiBmb3Ig
bmYsIGIgaW4gTzVfTkZTIGlmIG5mIG5vdCBpbiBPNV9PUFRJT05BTF0KICAgICAgICAgICAgdHJ5
OiBpbXBvcnQgeWFtbCAgIyBub3FhCiAgICAgICAgICAgIGV4Y2VwdCBJbXBvcnRFcnJvcjogcmV0
dXJuICJweXRob24zLXlhbWwgZmVobHQgKEluc3RhbGxlciBlcm5ldXQgYXVzZnVlaHJlbikiCiAg
ICAgICAgbWlzcyA9IFtiIGZvciBiIGluIG5lZWQgaWYgbm90IHNodXRpbC53aGljaChiKV0KICAg
ICAgICBpZiBtaXNzOiByZXR1cm4gIkZlaGx0OiAiICsgIiwgIi5qb2luKG1pc3MpICsgIiAoSW5z
dGFsbGVyIGVybmV1dCBhdXNmdWVocmVuKSIKICAgICAgICBpZiBtb2RlID09ICJjc2ZiIiBhbmQg
b3Ntb19oYXMoIm9zbW8tbXNjIiwgInNncyIpIGlzIEZhbHNlOgogICAgICAgICAgICByZXR1cm4g
IkRpZXNlIG9zbW8tbXNjIGthbm4ga2VpbiBTR3MgKENTRkIpIC0gbmV1ZXJlIE9zbW9jb20tVmVy
c2lvbiBub2V0aWciCiAgICBORVQuZGV2X2dzbSwgTkVULmRldl9sdGUgPSBnLCBsCiAgICByZXR1
cm4gTm9uZQoKIyA9PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
PT09PT09PT09PT09PT09PT09PT0gTmV0ei1NYW5hZ2VyCk1PREVTID0geyJnc20iOiAiR1NNICgy
RykiLCAibHRlIjogIkxURSAoNEcpIiwgImNzZmIiOiAiTFRFICsgR1NNIChDU0ZCKSJ9CgpjbGFz
cyBOZXQ6CiAgICBkZWYgX19pbml0X18oc2VsZik6CiAgICAgICAgc2VsZi5sb2NrID0gdGhyZWFk
aW5nLlJMb2NrKCkKICAgICAgICBzZWxmLnRlY2ggPSBOb25lICAgICAgICAgICMgTm9uZSB8ICJn
c20iIHwgImx0ZSIgfCAiY3NmYiIKICAgICAgICBzZWxmLnN0YXRlID0gImF1cyIgICAgICAgICMg
YXVzIHwgc3RhcnRldCB8IGxhZXVmdCB8IGZlaGxlcgogICAgICAgIHNlbGYubXNnID0gIiIKICAg
ICAgICBzZWxmLnByb2NzID0ge30KICAgICAgICBzZWxmLmxvZ2xpbmVzID0gW10KICAgICAgICBz
ZWxmLnN0YXJ0ZWQgPSAwLjAKICAgICAgICBzZWxmLndlbGNvbWVkID0gc2V0KCkgICAgICMgSU1T
SXMsIGRpZSBpbiBkaWVzZXIgTmV0ei1TZXNzaW9uIHNjaG9uIGJlZ3J1ZXNzdCB3dXJkZW4KICAg
ICAgICBzZWxmLmRldl9nc20gPSBzZWxmLmRldl9sdGUgPSAiIgogICAgICAgIHNlbGYuY21kcyA9
IHt9ICAgICAgICAgICAgIyB0YWcgLT4gKGJpbmFyeSwgYXJncywgZ3J1cHBlKSBmdWVyIEVpbnpl
bC1OZXVzdGFydHMKICAgICAgICBzZWxmLmJ1c3kgPSAiIiAgICAgICAgICAgICMgbGF1ZmVuZGVy
IFRlaWwtTmV1c3RhcnQKCiAgICBkZWYgX2xvZyhzZWxmLCB0YWcsIGxpbmUpOgogICAgICAgIGxp
bmUgPSBsaW5lLnJzdHJpcCgpCiAgICAgICAgaWYgbm90IGxpbmU6IHJldHVybgogICAgICAgIHBy
aW50KGYie3RhZ306IHtsaW5lfSIsIGZsdXNoPVRydWUpICAgIyAtPiBqb3VybmFsZCwgZGFtaXQg
J2pvdXJuYWxjdGwgLXUgZzkwbmV0JyBhbGxlcyB6ZWlndAogICAgICAgIHNlbGYubG9nbGluZXMu
YXBwZW5kKGYie3RhZ306IHtsaW5lfSIpCiAgICAgICAgaWYgbGVuKHNlbGYubG9nbGluZXMpID4g
NjAwOiBzZWxmLmxvZ2xpbmVzID0gc2VsZi5sb2dsaW5lc1stNjAwOl0KICAgICAgICBsb3cgPSBs
aW5lLmxvd2VyKCkKICAgICAgICBpZiAoImZhdGFsIiBpbiBsb3cgb3IgImZhaWxlZCB0byBjcmVh
dGUgcmFkaW8iIGluIGxvdykgYW5kIHRhZyBub3QgaW4gR1NNX05PTkZBVEFMOgogICAgICAgICAg
ICBzZWxmLm1zZyA9IGYie3RhZ306IHtsaW5lWzoxMjBdfSIKCiAgICBkZWYgX3JlYWRlcihzZWxm
LCBwLCB0YWcpOgogICAgICAgIHRyeToKICAgICAgICAgICAgZm9yIHJhdyBpbiBpdGVyKHAuc3Rk
b3V0LnJlYWRsaW5lLCAiIik6CiAgICAgICAgICAgICAgICBzZWxmLl9sb2codGFnLCByYXcpCiAg
ICAgICAgZXhjZXB0IEV4Y2VwdGlvbjoKICAgICAgICAgICAgcGFzcwogICAgICAgIHJjID0gcC5w
b2xsKCkKICAgICAgICBpZiBzZWxmLnByb2NzLmdldCh0YWcpIGlzIHAgYW5kIHNlbGYuc3RhdGUg
PT0gImxhZXVmdCIgYW5kIHRhZyBub3QgaW4gR1NNX05PTkZBVEFMOgogICAgICAgICAgICBzZWxm
Lm1zZyA9IGYie3RhZ30gYmVlbmRldCAoQ29kZSB7cmN9KSAtIHNpZWhlIFByb3Rva29sbCIKCiAg
ICBkZWYgX3NwYXduKHNlbGYsIGJpbmFyeSwgYXJncywgdGFnLCBncm91cD0iIik6CiAgICAgICAg
cCA9IHN1YnByb2Nlc3MuUG9wZW4oW2JpbmFyeV0gKyBhcmdzLCBzdGRvdXQ9c3VicHJvY2Vzcy5Q
SVBFLAogICAgICAgICAgICAgICAgICAgICAgICAgICAgIHN0ZGVycj1zdWJwcm9jZXNzLlNURE9V
VCwgdGV4dD1UcnVlLCBidWZzaXplPTEpCiAgICAgICAgc2VsZi5wcm9jc1t0YWddID0gcAogICAg
ICAgIHNlbGYuY21kc1t0YWddID0gKGJpbmFyeSwgYXJncywgZ3JvdXAgb3Igc2VsZi5jbWRzLmdl
dCh0YWcsICgiIiwgW10sICIiKSlbMl0pCiAgICAgICAgdGhyZWFkaW5nLlRocmVhZCh0YXJnZXQ9
c2VsZi5fcmVhZGVyLCBhcmdzPShwLCB0YWcpLCBkYWVtb249VHJ1ZSkuc3RhcnQoKQogICAgICAg
IHJldHVybiBwCgogICAgZGVmIHN0b3Aoc2VsZik6CiAgICAgICAgd2l0aCBzZWxmLmxvY2s6CiAg
ICAgICAgICAgIGlmIEZBS0U6CiAgICAgICAgICAgICAgICBzZWxmLnRlY2ggPSBOb25lOyBzZWxm
LnN0YXRlID0gImF1cyI7IHNlbGYucHJvY3MgPSB7fTsgcmV0dXJuCiAgICAgICAgICAgIHByb2Nz
LCBzZWxmLnByb2NzID0gc2VsZi5wcm9jcywge30KICAgICAgICAgICAgc2VsZi5jbWRzID0ge30K
ICAgICAgICAgICAgZm9yIHRhZywgcCBpbiBsaXN0KHByb2NzLml0ZW1zKCkpOgogICAgICAgICAg
ICAgICAgdHJ5OiBwLnRlcm1pbmF0ZSgpCiAgICAgICAgICAgICAgICBleGNlcHQgRXhjZXB0aW9u
OiBwYXNzCiAgICAgICAgICAgIHRpbWUuc2xlZXAoMSkKICAgICAgICAgICAgZm9yIG5hbWUgaW4g
T1NNT19TRVJWSUNFUyArIFsic3JzZW5iIiwgInNyc2VwYyIsICJvcGVuNWdzLSJdOgogICAgICAg
ICAgICAgICAgdHJ5OiBzdWJwcm9jZXNzLnJ1bihbInBraWxsIiwgIi05IiwgIi1mIiwgbmFtZV0s
CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIHN0ZG91dD1zdWJwcm9jZXNzLkRF
Vk5VTEwsIHN0ZGVycj1zdWJwcm9jZXNzLkRFVk5VTEwpCiAgICAgICAgICAgICAgICBleGNlcHQg
RXhjZXB0aW9uOiBwYXNzCiAgICAgICAgICAgIGlmIHNlbGYudGVjaDoKICAgICAgICAgICAgICAg
IF9saW1lX3NlcnZpY2UoInN0YXJ0IikgICAjIEc5MC1FbXBmYW5nIHdpZWRlciBmcmVpIGdlYmVu
CiAgICAgICAgICAgIHNlbGYudGVjaCA9IE5vbmU7IHNlbGYuc3RhdGUgPSAiYXVzIjsgc2VsZi5t
c2cgPSAiZ2VzdG9wcHQiCgogICAgZGVmIHN0YXJ0KHNlbGYsIG1vZGUpOgogICAgICAgIGlmIG1v
ZGUgbm90IGluIE1PREVTOiByZXR1cm4gInVuYmVrYW5udGVyIE1vZHVzIgogICAgICAgIHdpdGgg
c2VsZi5sb2NrOgogICAgICAgICAgICBzZWxmLnN0b3AoKTsgc2VsZi50ZWNoID0gbW9kZTsgc2Vs
Zi5zdGF0ZSA9ICJzdGFydGV0Ijsgc2VsZi5tc2cgPSAiIgogICAgICAgICAgICBzZWxmLmxvZ2xp
bmVzID0gW107IHNlbGYuc3RhcnRlZCA9IHRpbWUudGltZSgpOyBzZWxmLndlbGNvbWVkID0gc2V0
KCkKICAgICAgICBlcnIgPSBwcmVmbGlnaHQobW9kZSkKICAgICAgICBpZiBlcnI6CiAgICAgICAg
ICAgIHdpdGggc2VsZi5sb2NrOiBzZWxmLnRlY2ggPSBOb25lOyBzZWxmLnN0YXRlID0gImZlaGxl
ciI7IHNlbGYubXNnID0gZXJyCiAgICAgICAgICAgIHJldHVybiBlcnIKICAgICAgICBpZiBGQUtF
OgogICAgICAgICAgICB3aXRoIHNlbGYubG9jazoKICAgICAgICAgICAgICAgIHNlbGYuc3RhdGUg
PSAibGFldWZ0Ijsgc2VsZi5tc2cgPSBNT0RFU1ttb2RlXSArICIgbGFldWZ0IChGQUtFKSIKICAg
ICAgICAgICAgICAgIGlmIG1vZGUgaW4gKCJnc20iLCAiY3NmYiIpOgogICAgICAgICAgICAgICAg
ICAgIGZvciBuLCBiLCBfYyBpbiBnc21fY29tcG9uZW50cygpOiBzZWxmLmNtZHNbbl0gPSAoYiwg
W10sICJnc20iKQogICAgICAgICAgICAgICAgaWYgbW9kZSBpbiAoImx0ZSIsICJjc2ZiIik6CiAg
ICAgICAgICAgICAgICAgICAgZm9yIG4sIGIgaW4gTzVfTkZTOiBzZWxmLmNtZHNbbl0gPSAoYiwg
W10sICJsdGUiKQogICAgICAgICAgICAgICAgICAgIHNlbGYuY21kc1siZW5iIl0gPSAoInNyc2Vu
YiIsIFtdLCAibHRlIikKICAgICAgICAgICAgcmV0dXJuIE5vbmUKICAgICAgICBnc20sIGx0ZSA9
IG1vZGUgaW4gKCJnc20iLCAiY3NmYiIpLCBtb2RlIGluICgibHRlIiwgImNzZmIiKQogICAgICAg
IHRyeToKICAgICAgICAgICAgaWYgZ3NtOgogICAgICAgICAgICAgICAgc2VsZi5fc2VydmljZXNf
b2ZmKE9TTU9fU0VSVklDRVMpCiAgICAgICAgICAgICAgICBnc21fcHJlcGFyZSgpCiAgICAgICAg
ICAgIGlmIGx0ZToKICAgICAgICAgICAgICAgIHNlbGYuX3NlcnZpY2VzX29mZihbYiBmb3IgX25m
LCBiIGluIE81X05GU10pCiAgICAgICAgICAgICAgICBuZnMgPSBvNV9wcmVwYXJlKG1vZGUgPT0g
ImNzZmIiKQogICAgICAgICAgICAgICAgZW5iX3ByZXBhcmUobW9kZSA9PSAiY3NmYiIsIHNlbGYu
ZGV2X2x0ZSkKICAgICAgICAgICAgICAgIF9ydW4oInN5c3RlbWN0bCIsICJzdGFydCIsICJtb25n
b2QiKQogICAgICAgICAgICAgICAgZSA9IGhzc19zeW5jX2FsbCgpCiAgICAgICAgICAgICAgICBp
ZiBlOiBzZWxmLl9sb2coInBrb20iLCAiSFNTOiAiICsgZSkKICAgICAgICAgICAgaWYgc2VsZi5k
ZXZfZ3NtOiBzZWxmLl9sb2coInBrb20iLCAiR1NNLUZ1bms6ICIgKyBsaW1lX2xhYmVsKHNlbGYu
ZGV2X2dzbSkpCiAgICAgICAgICAgIGlmIHNlbGYuZGV2X2x0ZTogc2VsZi5fbG9nKCJwa29tIiwg
IkxURS1GdW5rOiAiICsgbGltZV9sYWJlbChzZWxmLmRldl9sdGUpKQogICAgICAgICAgICBfbGlt
ZV9zZXJ2aWNlKCJzdG9wIik7IHRpbWUuc2xlZXAoMSk7IF9mcmVlX2xpbWUoKTsgdGltZS5zbGVl
cCgyKQogICAgICAgICAgICBpZiBnc206IHNlbGYuX3J1bl9nc20oKQogICAgICAgICAgICBpZiBs
dGU6IHNlbGYuX3J1bl9sdGUobmZzKQogICAgICAgICAgICB3aXRoIHNlbGYubG9jazogc2VsZi5z
dGF0ZSA9ICJsYWV1ZnQiOyBzZWxmLm1zZyA9IE1PREVTW21vZGVdICsgIiBnZXN0YXJ0ZXQiCiAg
ICAgICAgZXhjZXB0IEV4Y2VwdGlvbiBhcyBlOgogICAgICAgICAgICB3aXRoIHNlbGYubG9jazog
c2VsZi5zdGF0ZSA9ICJmZWhsZXIiOyBzZWxmLm1zZyA9IHN0cihlKVs6MjAwXQogICAgICAgICAg
ICByZXR1cm4gc3RyKGUpCiAgICAgICAgcmV0dXJuIE5vbmUKCiAgICAjIC0tLS0gVGVpbGUgc3Rh
cnRlbiAvIGVpbnplbG4gbmV1IHN0YXJ0ZW4gLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLQog
ICAgZGVmIF9ydW5fZ3NtKHNlbGYpOgogICAgICAgIGZvciBuYW1lLCBiaW5hcnksIGNmZyBpbiBn
c21fY29tcG9uZW50cygpOgogICAgICAgICAgICBmbGFnID0gIi1DIiBpZiBiaW5hcnkuc3RhcnRz
d2l0aCgib3Ntby10cngiKSBlbHNlICItYyIKICAgICAgICAgICAgc2VsZi5fc3Bhd24oYmluYXJ5
LCBbZmxhZywgb3MucGF0aC5qb2luKFdPUktESVIsIGNmZyldLCBuYW1lLCAiZ3NtIikKICAgICAg
ICAgICAgdGltZS5zbGVlcCg0IGlmIG5hbWUgaW4gKCJ0cngiLCkgZWxzZSAxLjIpCiAgICAgICAg
dGltZS5zbGVlcCgxKTsgZ3NtX2FwcGx5X251bWJlcnMoKSAgICMgU0lNcyArIGRhdWVyaGFmdGUg
UnVmbnVtbWVybiBpbnMgSExSCgogICAgZGVmIF9ydW5fbHRlKHNlbGYsIG5mcywgY29yZT1UcnVl
KToKICAgICAgICBpZiBjb3JlOgogICAgICAgICAgICB1ZV9uZXRfdXAoKQogICAgICAgICAgICBm
b3IgbmYsIChiaW5hcnksIHBhdGgpIGluIG5mcy5pdGVtcygpOgogICAgICAgICAgICAgICAgc2Vs
Zi5fc3Bhd24oYmluYXJ5LCBbIi1jIiwgcGF0aF0sIG5mLCAibHRlIikKICAgICAgICAgICAgICAg
IHRpbWUuc2xlZXAoMS41IGlmIG5mID09ICJtbWUiIGVsc2UgMC44KQogICAgICAgICAgICB0aW1l
LnNsZWVwKDIpCiAgICAgICAgc2VsZi5fc3Bhd24oInNyc2VuYiIsIFtvcy5wYXRoLmpvaW4oV09S
S0RJUiwgImVuYi5jb25mIildLCAiZW5iIiwgImx0ZSIpCgogICAgZGVmIF9raWxsKHNlbGYsIHRh
Z3MpOgogICAgICAgICIiIlByb3plc3NlIGJlZW5kZW4sIG9obmUgZGFzcyBkZXIgTGVzZXIgJ2Jl
ZW5kZXQnIG1lbGRldC4iIiIKICAgICAgICBwcyA9IFsodCwgc2VsZi5wcm9jcy5wb3AodCkpIGZv
ciB0IGluIGxpc3QodGFncykgaWYgdCBpbiBzZWxmLnByb2NzXQogICAgICAgIGZvciBfdCwgcCBp
biBwczoKICAgICAgICAgICAgdHJ5OiBwLnRlcm1pbmF0ZSgpCiAgICAgICAgICAgIGV4Y2VwdCBF
eGNlcHRpb246IHBhc3MKICAgICAgICBmb3IgX3QsIHAgaW4gcHM6CiAgICAgICAgICAgIHRyeTog
cC53YWl0KHRpbWVvdXQ9NikKICAgICAgICAgICAgZXhjZXB0IEV4Y2VwdGlvbjoKICAgICAgICAg
ICAgICAgIHRyeTogcC5raWxsKCk7IHAud2FpdCh0aW1lb3V0PTMpCiAgICAgICAgICAgICAgICBl
eGNlcHQgRXhjZXB0aW9uOiBwYXNzCgogICAgZGVmIHBhcnRzKHNlbGYpOgogICAgICAgICIiIldh
cyBlaW56ZWxuIG5ldSBnZXN0YXJ0ZXQgd2VyZGVuIGthbm4gKGplIG5hY2ggTW9kdXMpLiIiIgog
ICAgICAgIHQgPSBzZWxmLnRlY2ggb3IgIiIKICAgICAgICBvdXQgPSBbXQogICAgICAgIGlmIHQg
aW4gKCJnc20iLCAiY3NmYiIpOiBvdXQuYXBwZW5kKCgiZ3NtIiwgIkdTTSBrb21wbGV0dCIpKQog
ICAgICAgIGlmIHQgaW4gKCJsdGUiLCAiY3NmYiIpOiBvdXQgKz0gWygibHRlIiwgIjRHIGtvbXBs
ZXR0IiksICgiZW5iIiwgIjRHLUZ1bmsgKGVOQikiKV0KICAgICAgICByZXR1cm4gb3V0CgogICAg
ZGVmIHJlc3RhcnQoc2VsZiwgcGFydCk6CiAgICAgICAgIiIicGFydDogJ2dzbScgfCAnbHRlJyB8
ICdjb3JlJyB8ICdlbmInIHwgUHJvemVzc25hbWUgKHouQi4gJ21zYycsICdtbWUnKS4iIiIKICAg
ICAgICB3aXRoIHNlbGYubG9jazoKICAgICAgICAgICAgaWYgc2VsZi5zdGF0ZSBub3QgaW4gKCJs
YWV1ZnQiLCAiZmVobGVyIikgb3Igbm90IHNlbGYudGVjaDoKICAgICAgICAgICAgICAgIHJldHVy
biAiTmV0eiBsYWV1ZnQgbmljaHQiCiAgICAgICAgICAgIGlmIHNlbGYuYnVzeTogcmV0dXJuIGYi
TmV1c3RhcnQgdm9uIHtzZWxmLmJ1c3l9IGxhZXVmdCBub2NoIgogICAgICAgICAgICBnc20sIGx0
ZSA9IHNlbGYudGVjaCBpbiAoImdzbSIsICJjc2ZiIiksIHNlbGYudGVjaCBpbiAoImx0ZSIsICJj
c2ZiIikKICAgICAgICAgICAgaWYgcGFydCA9PSAiZ3NtIiBhbmQgbm90IGdzbSBvciBwYXJ0IGlu
ICgibHRlIiwgImVuYiIpIGFuZCBub3QgbHRlOgogICAgICAgICAgICAgICAgcmV0dXJuICJUZWls
IGlzdCBpbSBha3R1ZWxsZW4gTW9kdXMgbmljaHQgYWt0aXYiCiAgICAgICAgICAgIGlmIHBhcnQg
bm90IGluICgiZ3NtIiwgImx0ZSIsICJlbmIiKSBhbmQgcGFydCBub3QgaW4gc2VsZi5jbWRzOgog
ICAgICAgICAgICAgICAgcmV0dXJuIGYidW5iZWthbm50ZXIgVGVpbCAne3BhcnR9JyIKICAgICAg
ICAgICAgc2VsZi5idXN5ID0gcGFydAogICAgICAgIGxhYmVsID0gZGljdChzZWxmLnBhcnRzKCkp
LmdldChwYXJ0LCBwYXJ0KQogICAgICAgIHNlbGYuX2xvZygicGtvbSIsIGYiTmV1c3RhcnQ6IHts
YWJlbH0iKQogICAgICAgIHNlbGYubXNnID0gZiJ7bGFiZWx9IHN0YXJ0ZXQgbmV1IC4uLiIKICAg
ICAgICB0cnk6CiAgICAgICAgICAgIGlmIEZBS0U6CiAgICAgICAgICAgICAgICB0aW1lLnNsZWVw
KDAuNSkKICAgICAgICAgICAgZWxpZiBwYXJ0ID09ICJnc20iOgogICAgICAgICAgICAgICAgc2Vs
Zi5fa2lsbChbdCBmb3IgdCwgYyBpbiBzZWxmLmNtZHMuaXRlbXMoKSBpZiBjWzJdID09ICJnc20i
XSkKICAgICAgICAgICAgICAgIGdzbV9wcmVwYXJlKCk7IHNlbGYuX3J1bl9nc20oKQogICAgICAg
ICAgICBlbGlmIHBhcnQgPT0gImx0ZSI6CiAgICAgICAgICAgICAgICBzZWxmLl9raWxsKFt0IGZv
ciB0LCBjIGluIHNlbGYuY21kcy5pdGVtcygpIGlmIGNbMl0gPT0gImx0ZSJdKQogICAgICAgICAg
ICAgICAgbmZzID0gbzVfcHJlcGFyZShzZWxmLnRlY2ggPT0gImNzZmIiKQogICAgICAgICAgICAg
ICAgZW5iX3ByZXBhcmUoc2VsZi50ZWNoID09ICJjc2ZiIiwgc2VsZi5kZXZfbHRlKQogICAgICAg
ICAgICAgICAgZSA9IGhzc19zeW5jX2FsbCgpCiAgICAgICAgICAgICAgICBpZiBlOiBzZWxmLl9s
b2coInBrb20iLCAiSFNTOiAiICsgZSkKICAgICAgICAgICAgICAgIHNlbGYuX3J1bl9sdGUobmZz
KQogICAgICAgICAgICBlbGlmIHBhcnQgPT0gImVuYiI6CiAgICAgICAgICAgICAgICBzZWxmLl9r
aWxsKFsiZW5iIl0pOyBlbmJfcHJlcGFyZShzZWxmLnRlY2ggPT0gImNzZmIiLCBzZWxmLmRldl9s
dGUpCiAgICAgICAgICAgICAgICBzZWxmLl9ydW5fbHRlKHt9LCBjb3JlPUZhbHNlKQogICAgICAg
ICAgICBlbHNlOgogICAgICAgICAgICAgICAgYmluYXJ5LCBhcmdzLCBncnAgPSBzZWxmLmNtZHNb
cGFydF0KICAgICAgICAgICAgICAgIHNlbGYuX2tpbGwoW3BhcnRdKTsgdGltZS5zbGVlcCgwLjUp
CiAgICAgICAgICAgICAgICBzZWxmLl9zcGF3bihiaW5hcnksIGFyZ3MsIHBhcnQsIGdycCkKICAg
ICAgICAgICAgICAgIGlmIHBhcnQgPT0gImhsciI6IHRpbWUuc2xlZXAoMS41KTsgZ3NtX2FwcGx5
X251bWJlcnMoKQogICAgICAgICAgICB3aXRoIHNlbGYubG9jazogc2VsZi5zdGF0ZSA9ICJsYWV1
ZnQiOyBzZWxmLm1zZyA9IGYie2xhYmVsfSBuZXUgZ2VzdGFydGV0IgogICAgICAgICAgICByZXR1
cm4gTm9uZQogICAgICAgIGV4Y2VwdCBFeGNlcHRpb24gYXMgZToKICAgICAgICAgICAgd2l0aCBz
ZWxmLmxvY2s6IHNlbGYubXNnID0gZiJOZXVzdGFydCB7bGFiZWx9IGZlaGxnZXNjaGxhZ2VuOiB7
c3RyKGUpWzoxNjBdfSIKICAgICAgICAgICAgcmV0dXJuIHN0cihlKQogICAgICAgIGZpbmFsbHk6
CiAgICAgICAgICAgIHNlbGYuYnVzeSA9ICIiCgogICAgZGVmIHByb2NfbGlzdChzZWxmKToKICAg
ICAgICBvdXQgPSBbXQogICAgICAgIGZvciB0YWcsIChfYiwgX2EsIGdycCkgaW4gc2VsZi5jbWRz
Lml0ZW1zKCk6CiAgICAgICAgICAgIHAgPSBzZWxmLnByb2NzLmdldCh0YWcpCiAgICAgICAgICAg
IHJjID0gTm9uZSBpZiBwIGlzIE5vbmUgZWxzZSBwLnBvbGwoKQogICAgICAgICAgICBvdXQuYXBw
ZW5kKHsidGFnIjogdGFnLCAiZ3JvdXAiOiBncnAsICJydW4iOiBwIGlzIG5vdCBOb25lIGFuZCBy
YyBpcyBOb25lLAogICAgICAgICAgICAgICAgICAgICAgICAicmMiOiByYyBpZiBwIGlzIG5vdCBO
b25lIGVsc2UgIi0ifSkKICAgICAgICByZXR1cm4gb3V0CgogICAgIyBLb21wYXRpYmlsaXRhZXQK
ICAgIGRlZiBzdGFydF9nc20oc2VsZik6IHJldHVybiBzZWxmLnN0YXJ0KCJnc20iKQogICAgZGVm
IHN0YXJ0X2x0ZShzZWxmKTogcmV0dXJuIHNlbGYuc3RhcnQoImx0ZSIpCgogICAgZGVmIF9zZXJ2
aWNlc19vZmYoc2VsZiwgbmFtZXMpOgogICAgICAgIGZvciBzIGluIG5hbWVzOgogICAgICAgICAg
ICB0cnk6IHN1YnByb2Nlc3MucnVuKFsic3lzdGVtY3RsIiwgInN0b3AiLCBzLnJlcGxhY2UoIm9w
ZW41Z3MtIiwgIm9wZW41Z3MtIikgKyAiLnNlcnZpY2UiXSwKICAgICAgICAgICAgICAgICAgICAg
ICAgICAgICAgICBzdGRvdXQ9c3VicHJvY2Vzcy5ERVZOVUxMLCBzdGRlcnI9c3VicHJvY2Vzcy5E
RVZOVUxMLCB0aW1lb3V0PTgpCiAgICAgICAgICAgIGV4Y2VwdCBFeGNlcHRpb246IHBhc3MKCiAg
ICBkZWYgc3RhdHVzKHNlbGYpOgogICAgICAgIHdpdGggc2VsZi5sb2NrOgogICAgICAgICAgICBz
dCA9IHsKICAgICAgICAgICAgICAgICJ0ZWNoIjogc2VsZi50ZWNoLCAibW9kZSI6IE1PREVTLmdl
dChzZWxmLnRlY2ggb3IgIiIsICIiKSwKICAgICAgICAgICAgICAgICJzdGF0ZSI6IHNlbGYuc3Rh
dGUsICJtc2ciOiBzZWxmLm1zZywKICAgICAgICAgICAgICAgICJ1cHRpbWUiOiBpbnQodGltZS50
aW1lKCkgLSBzZWxmLnN0YXJ0ZWQpIGlmIHNlbGYuc3RhcnRlZCBhbmQgc2VsZi5zdGF0ZSA9PSAi
bGFldWZ0IiBlbHNlIDAsCiAgICAgICAgICAgICAgICAibG9nIjogc2VsZi5sb2dsaW5lc1stODA6
XSwKICAgICAgICAgICAgICAgICJjb25mIjogZGljdChDKSwKICAgICAgICAgICAgICAgICJsaW1l
cyI6IExJTUVTLAogICAgICAgICAgICAgICAgImRldiI6IHsiZ3NtIjogbGltZV9sYWJlbChzZWxm
LmRldl9nc20pIGlmIHNlbGYuZGV2X2dzbSBlbHNlICIiLAogICAgICAgICAgICAgICAgICAgICAg
ICAibHRlIjogbGltZV9sYWJlbChzZWxmLmRldl9sdGUpIGlmIHNlbGYuZGV2X2x0ZSBlbHNlICIi
fSwKICAgICAgICAgICAgICAgICJnc20iOiB7CiAgICAgICAgICAgICAgICAgICAgImFyZmNuIjog
aW50KENbIkdTTV9BUkZDTiJdKSwgImJhbmQiOiBHU01fQkFORFMuZ2V0KGdzbV9iYW5kKCksICgi
PyIsKSlbMF0sCiAgICAgICAgICAgICAgICAgICAgIm1oeiI6IGFyZmNuX21oeihpbnQoQ1siR1NN
X0FSRkNOIl0pKSwgInVsIjogYXJmY25fbWh6KGludChDWyJHU01fQVJGQ04iXSksIFRydWUpLAog
ICAgICAgICAgICAgICAgICAgICJhdHRhY2hlZCI6IHNvcnRlZChtc2NfYXR0YWNoZWQoKSkgaWYg
c2VsZi5zdGF0ZSA9PSAibGFldWZ0IiBlbHNlIFtdLAogICAgICAgICAgICAgICAgICAgICJudW1i
ZXJzIjogbnVtc19sb2FkKCksCiAgICAgICAgICAgICAgICB9LAogICAgICAgICAgICAgICAgImx0
ZSI6IHsKICAgICAgICAgICAgICAgICAgICAiZWFyZmNuIjogaW50KENbIkxURV9FQVJGQ04iXSks
ICJiYW5kIjogZWFyZmNuX2JhbmQoaW50KENbIkxURV9FQVJGQ04iXSkpLAogICAgICAgICAgICAg
ICAgICAgICJtaHoiOiBlYXJmY25fbWh6KGludChDWyJMVEVfRUFSRkNOIl0pKSwgInVsIjogZWFy
ZmNuX21oeihpbnQoQ1siTFRFX0VBUkZDTiJdKSwgVHJ1ZSksCiAgICAgICAgICAgICAgICB9LAog
ICAgICAgICAgICAgICAgImJhbmRzIjogYmFuZF90YWJsZXMoKSwKICAgICAgICAgICAgICAgICJz
aW1zIjogW3siaW1zaSI6IGksICJtc2lzZG4iOiBzLmdldCgibXNpc2RuIiwgIiIpfSBmb3IgaSwg
cyBpbiBzb3J0ZWQoc2ltc19sb2FkKCkuaXRlbXMoKSldLAogICAgICAgICAgICAgICAgInNpbWZp
bGVzIjogc2ltX2ZpbGVzKCksCiAgICAgICAgICAgICAgICAidHoiOiAiVVRDJStkOiUwMmQlcyIg
JSAodHpfbm93KClbMF0sIHR6X25vdygpWzFdLCAiICtTb21tZXJ6ZWl0IiBpZiB0el9ub3coKVsy
XSBlbHNlICIiKSwKICAgICAgICAgICAgICAgICJjbGFzaCI6IGZyZXFfY2xhc2goKSwKICAgICAg
ICAgICAgICAgICJmYWtlIjogRkFLRSwKICAgICAgICAgICAgICAgICJwYXJ0cyI6IFt7ImlkIjog
aSwgIm5hbWUiOiBufSBmb3IgaSwgbiBpbiBzZWxmLnBhcnRzKCldLAogICAgICAgICAgICAgICAg
InByb2NzIjogc2VsZi5wcm9jX2xpc3QoKSwgImJ1c3kiOiBzZWxmLmJ1c3ksCiAgICAgICAgICAg
IH0KICAgICAgICByZXR1cm4gc3QKCk5FVCA9IE5ldCgpCgojID09PT09PT09PT09PT09PT09PT09
PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PSBXZWItQVBJCmRl
ZiBoYW5kbGVfYXBpKHBhdGgsIGJvZHkpOgogICAgdHJ5OgogICAgICAgIHJlcSA9IGpzb24ubG9h
ZHMoYm9keSBvciAie30iKQogICAgZXhjZXB0IEV4Y2VwdGlvbjoKICAgICAgICByZXEgPSB7fQog
ICAgY21kID0gcGF0aC5yc3BsaXQoIi8iLCAxKVstMV0KICAgIGlmIGNtZCA9PSAic3RhdHVzIjoK
ICAgICAgICByZXR1cm4gTkVULnN0YXR1cygpCiAgICBpZiBjbWQgaW4gKCJzdGFydF9nc20iLCAi
c3RhcnRfbHRlIiwgInN0YXJ0X2NzZmIiKToKICAgICAgICBORVQuc3RhcnQoY21kWzY6XSkKICAg
IGVsaWYgY21kID09ICJzdG9wIjoKICAgICAgICBORVQuc3RvcCgpCiAgICBlbGlmIGNtZCA9PSAi
cmVzdGFydCI6CiAgICAgICAgcGFydCA9IHJlLnN1YihyIlteYS16MC05Xy1dIiwgIiIsIHN0cihy
ZXEuZ2V0KCJwYXJ0IiwgIiIpKS5sb3dlcigpKQogICAgICAgIGVyciA9IE5FVC5yZXN0YXJ0KHBh
cnQpCiAgICAgICAgaWYgZXJyOiBORVQubXNnID0gZXJyCiAgICBlbGlmIGNtZCA9PSAibGltZV9z
Y2FuIjoKICAgICAgICBuID0gbGVuKGxpbWVfc2NhbigpKTsgTkVULm1zZyA9IGYie259IExpbWVT
RFIgZ2VmdW5kZW4iCiAgICBlbGlmIGNtZCA9PSAic2V0IjoKICAgICAgICAjIGJlbGllYmlnZSBL
b25maWctS2V5cyBzZXR6ZW4gKHZhbGlkaWVydCBsaWdodCkKICAgICAgICBmb3IgaywgdiBpbiBy
ZXEuaXRlbXMoKToKICAgICAgICAgICAgaWYgayBpbiBERUZBVUxUUyBvciBrIGluIEM6CiAgICAg
ICAgICAgICAgICB2ID0gc3RyKHYpLnJlcGxhY2UoJyInLCAiIikucmVwbGFjZSgiXG4iLCAiICIp
LnN0cmlwKCkKICAgICAgICAgICAgICAgIGlmIGsgaW4gKCJNQ0MiLCAiTU5DIiwgIkxURV9UQUMi
LCAiR1NNX0FSRkNOIiwgIkxURV9FQVJGQ04iLCAiTFRFX05QUkIiKToKICAgICAgICAgICAgICAg
ICAgICB2ID0gcmUuc3ViKHIiXEQiLCAiIiwgdikKICAgICAgICAgICAgICAgICAgICBpZiBub3Qg
diBhbmQgayBub3QgaW4gKCJNQ0MiLCAiTU5DIik6IGNvbnRpbnVlICAgICAjIGxlZXIgLT4gYWx0
ZW4gV2VydCBiZWhhbHRlbgogICAgICAgICAgICAgICAgaWYgayA9PSAiR1NNX0JBTkQiIGFuZCB2
IG5vdCBpbiBHU01fQkFORFM6IHYgPSAiIgogICAgICAgICAgICAgICAgY3NldChrLCB2KQogICAg
ICAgIE5FVC5tc2cgPSAiZ2VzcGVpY2hlcnQgLSB3aXJrdCBiZWltIG5hZWNoc3RlbiBTdGFydCIK
ICAgICAgICBpZiBDLmdldCgiR1NNX0RFViIpIGFuZCBDLmdldCgiR1NNX0RFViIpID09IEMuZ2V0
KCJMVEVfREVWIik6CiAgICAgICAgICAgIE5FVC5tc2cgPSAiQWNodHVuZzogR1NNIHVuZCBMVEUg
bnV0emVuIGRlbnNlbGJlbiBMaW1lU0RSIC0gZnVlciBMVEUgKyBHU00gendlaSBHZXJhZXRlIHdh
ZWhsZW4iCiAgICBlbGlmIGNtZCBpbiAoInNpbV9hZGQiLCAiZ3NtX3NpbV9hZGQiLCAibHRlX3Np
bV9hZGQiKToKICAgICAgICBORVQubXNnID0gc2ltX2FkZChyZXEuZ2V0KCJpbXNpIiwiIiksIHJl
cS5nZXQoImtpIiwiIiksIHJlcS5nZXQoIm9wYyIsIiIpLCByZXEuZ2V0KCJtc2lzZG4iLCIiKSkg
XAogICAgICAgICAgICAgICAgICBvciAiU0lNIGdlc3BlaWNoZXJ0IChHU00gKyBMVEUpIgogICAg
ZWxpZiBjbWQgaW4gKCJzaW1fZGVsIiwgImdzbV9zaW1fZGVsIiwgImx0ZV9zaW1fZGVsIik6CiAg
ICAgICAgc2ltX2RlbChyZXEuZ2V0KCJpbXNpIiwiIikpOyBORVQubXNnID0gIlNJTSBnZWxvZXNj
aHQiCiAgICBlbGlmIGNtZCA9PSAiZ3NtX3NpbV9uciI6CiAgICAgICAgTkVULm1zZyA9IGdzbV9z
aW1fbnIocmVxLmdldCgiaW1zaSIsIiIpLCByZXEuZ2V0KCJtc2lzZG4iLCIiKSkgb3IgIlJ1Zm51
bW1lciBkYXVlcmhhZnQgenVnZXdpZXNlbiIKICAgIGVsaWYgY21kID09ICJnc21fbnVtX2RlbCI6
CiAgICAgICAgZ3NtX251bV9kZWwocmVxLmdldCgiaW1zaSIsIiIpKTsgTkVULm1zZyA9ICJSdWZu
dW1tZXItWnV3ZWlzdW5nIGdlbG9lc2NodCIKICAgIGVsaWYgY21kID09ICJzaW1fZ2VuIjoKICAg
ICAgICB0cnk6CiAgICAgICAgICAgIGdlbiA9IHNpbV9nZW5lcmF0ZShyZXEuZ2V0KCJjb3VudCIs
IDEpLCByZXEuZ2V0KCJtc2lzZG4iLCAiIiksIHJlcS5nZXQoImljY2lkIiwgIiIpKQogICAgICAg
ICAgICBORVQubXNnID0gZiJ7bGVuKGdlbil9IFNJTS1EYXRlbnNhdHovLXNhZXR6ZSBlcnpldWd0
IgogICAgICAgIGV4Y2VwdCBFeGNlcHRpb24gYXMgZToKICAgICAgICAgICAgZ2VuID0gW107IE5F
VC5tc2cgPSAiRXJ6ZXVnZW4gZmVobGdlc2NobGFnZW46ICVzIiAlIGUKICAgICAgICBzdCA9IE5F
VC5zdGF0dXMoKTsgc3RbImdlbmVyYXRlZCJdID0gZ2VuCiAgICAgICAgcmV0dXJuIHN0CiAgICBl
bGlmIGNtZCA9PSAic21zX3Rlc3QiOgogICAgICAgIE5FVC5tc2cgPSBzbXNfdGVzdChyZXEuZ2V0
KCJpbXNpIiwiIiksIHJlcS5nZXQoInRleHQiLCIiKSkKICAgIGVsc2U6CiAgICAgICAgTkVULm1z
ZyA9ICJ1bmJla2FubnQiCiAgICByZXR1cm4gTkVULnN0YXR1cygpCgojID09PT09PT09PT09PT09
PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PSBXZWIt
T2JlcmZsYWVjaGUgKEhUTUwpClBBR0UgPSByIiIiPCFkb2N0eXBlIGh0bWw+PGh0bWwgbGFuZz1k
ZT48aGVhZD48bWV0YSBjaGFyc2V0PXV0Zi04Pgo8bWV0YSBuYW1lPXZpZXdwb3J0IGNvbnRlbnQ9
IndpZHRoPWRldmljZS13aWR0aCxpbml0aWFsLXNjYWxlPTEiPgo8bWV0YSBuYW1lPXRoZW1lLWNv
bG9yIGNvbnRlbnQ9IiMwQTI0NjMiPgo8bGluayByZWw9aWNvbiBocmVmPSJkYXRhOmltYWdlL3N2
Zyt4bWw7YmFzZTY0LFBITjJaeUI0Yld4dWN6MGlhSFIwY0RvdkwzZDNkeTUzTXk1dmNtY3ZNakF3
TUM5emRtY2lJSFpwWlhkQ2IzZzlJakFnTUNBeE1ESTBJREV3TWpRaVBqeHlaV04wSUhkcFpIUm9Q
U0l4TURJMElpQm9aV2xuYUhROUlqRXdNalFpSUdacGJHdzlJaU13UVRJME5qTWlQand2Y21WamRE
NEtQR2NnZEhKaGJuTm1iM0p0UFNKMGNtRnVjMnhoZEdVb01USTNMallnTXpRM0xqQXBJSE5qWVd4
bEtERXVOalVwSWlCbWFXeHNQU0p1YjI1bElpQnpkSEp2YTJVdGJHbHVaV05oY0QwaWNtOTFibVFp
SUhOMGNtOXJaUzFzYVc1bGFtOXBiajBpY205MWJtUWlJSE4wY205clpTMTNhV1IwYUQwaU16SWlQ
Z284WnlCemRISnZhMlU5SWlOR1JrWkdSa1lpUGdvOGNHRjBhQ0JrUFNKTk1qQWdPREFnVmpJMk5p
SStQQzl3WVhSb1BnbzhZMmx5WTJ4bElHTjRQU0kzTWlJZ1kzazlJakV6TXlJZ2NqMGlOVElpUGp3
dlkybHlZMnhsUGdvOEwyYytDanhuSUhOMGNtOXJaVDBpSTBaR1JrWkdSaUkrQ2p4d1lYUm9JR1E5
SWsweE56Z2dNVFlnVVRJd05pQXhNREFnTVRjNElERTROQ0krUEM5d1lYUm9QZ284Y0dGMGFDQmtQ
U0pOTVRreUlERXdNQ0JETWpJMklEazJJREkxTUNBMk1pQXlOallnTVRZaVBqd3ZjR0YwYUQ0S1BD
OW5QZ284Y0dGMGFDQnpkSEp2YTJVOUlpTXlSVU0wUmpFaUlHUTlJazB4T1RJZ01UQXdJRU15TXpN
Z01UQXlJREkxTmlBeE9ETWdNell6SURFNE15QkJPRE1nT0RNZ01DQXdJREFnTXpZeklERTNJRUU0
TXlBNE15QXdJREFnTUNBeU9ESWdNVEU0SWo0OEwzQmhkR2crQ2p3dlp6NDhMM04yWno0PSI+Cjx0
aXRsZT5wS09NIMK3IE5ldHpzdGV1ZXJ1bmc8L3RpdGxlPgo8c3R5bGU+Cjpyb290ey0tbmF2eToj
MEEyNDYzOy0tYmc6IzA2MGYyMjstLWJnMjojMGExNzM0Oy0tY2FyZDojMGMxYTNiOy0tY2FyZDI6
IzEwMjI1MDstLWxpbmU6IzFiMmY1ZTstLWxpbmUyOiMyYTQyODg7Ci0tZmc6I2VhZjFmYjstLW11
dDojOGVhNGNhOy0tbXV0MjojNWQ3Mzk4Oy0tYWNjOiMyRUM0RjE7LS1hY2MyOiMwMDk2RDY7LS1v
azojMkVDNEYxOy0tb2tiZzojMDcyNDNiOy0tZXJyOiNmZjVkNmM7Ci0tcjowOy0tcjI6MDstLW1v
bm86dWktbW9ub3NwYWNlLFNGTW9uby1SZWd1bGFyLE1lbmxvLENvbnNvbGFzLG1vbm9zcGFjZX0K
Kntib3gtc2l6aW5nOmJvcmRlci1ib3h9aHRtbCxib2R5e21hcmdpbjowfQpib2R5e2JhY2tncm91
bmQ6bGluZWFyLWdyYWRpZW50KDE4MGRlZywjMDgxMzMwLCMwNTEwMWYpO2NvbG9yOnZhcigtLWZn
KTsKZm9udDoxNXB4LzEuNTUgc3lzdGVtLXVpLC1hcHBsZS1zeXN0ZW0sU2Vnb2UgVUksUm9ib3Rv
LHNhbnMtc2VyaWY7bWluLWhlaWdodDoxMDB2aH0KaGVhZGVye3Bvc2l0aW9uOnN0aWNreTt0b3A6
MDt6LWluZGV4OjIwO2JhY2tncm91bmQ6dmFyKC0tbmF2eSk7Ym9yZGVyLXRvcDoycHggc29saWQg
dmFyKC0tYWNjKTsKYm9yZGVyLWJvdHRvbToxcHggc29saWQgdmFyKC0tbGluZTIpO3BhZGRpbmc6
MTJweCAyMHB4O2Rpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7Z2FwOjE2cHg7ZmxleC13
cmFwOndyYXB9Ci5icmFuZHtkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2dhcDoxMnB4
fQouYnJhbmQgc3Zne2hlaWdodDozMHB4O3dpZHRoOmF1dG87ZGlzcGxheTpibG9ja30KLmJyYW5k
IC5wcm9ke2ZvbnQtc2l6ZToxMXB4O2ZvbnQtd2VpZ2h0OjcwMDtsZXR0ZXItc3BhY2luZzouMThl
bTt0ZXh0LXRyYW5zZm9ybTp1cHBlcmNhc2U7Y29sb3I6IzlmYjZkZTtwYWRkaW5nLWxlZnQ6MTJw
eDtib3JkZXItbGVmdDoxcHggc29saWQgIzI3NDA3ZX0KLmNoaXB7ZGlzcGxheTpmbGV4O2FsaWdu
LWl0ZW1zOmNlbnRlcjtnYXA6OHB4O3BhZGRpbmc6NnB4IDEycHg7Ym9yZGVyOjFweCBzb2xpZCB2
YXIoLS1saW5lMik7YmFja2dyb3VuZDojMGIxNzMzO2ZvbnQtc2l6ZToxMnB4O2ZvbnQtd2VpZ2h0
OjcwMDtsZXR0ZXItc3BhY2luZzouMDZlbTt0ZXh0LXRyYW5zZm9ybTp1cHBlcmNhc2V9Ci5kb3R7
d2lkdGg6OHB4O2hlaWdodDo4cHg7YmFja2dyb3VuZDp2YXIoLS1tdXQpfQouZG90Lm9ue2JhY2tn
cm91bmQ6dmFyKC0tYWNjKTthbmltYXRpb246cHVsc2UgMnMgaW5maW5pdGV9LmRvdC5lcnJ7YmFj
a2dyb3VuZDp2YXIoLS1lcnIpfQpAa2V5ZnJhbWVzIHB1bHNlezAle2JveC1zaGFkb3c6MCAwIDAg
MCByZ2JhKDQ2LDE5NiwyNDEsLjUpfTcwJXtib3gtc2hhZG93OjAgMCAwIDdweCByZ2JhKDQ2LDE5
NiwyNDEsMCl9MTAwJXtib3gtc2hhZG93OjAgMCAwIDAgcmdiYSg0NiwxOTYsMjQxLDApfX0KLmhz
dGF0e2Rpc3BsYXk6ZmxleDtnYXA6MThweDtmbGV4LXdyYXA6d3JhcDtjb2xvcjp2YXIoLS1tdXQp
O2ZvbnQtc2l6ZToxMnB4O21hcmdpbi1sZWZ0OmF1dG87YWxpZ24taXRlbXM6Y2VudGVyO3RleHQt
dHJhbnNmb3JtOnVwcGVyY2FzZTtsZXR0ZXItc3BhY2luZzouMDVlbX0KLmhzdGF0IGJ7Y29sb3I6
dmFyKC0tZmcpO2ZvbnQtZmFtaWx5OnZhcigtLW1vbm8pO2xldHRlci1zcGFjaW5nOjA7dGV4dC10
cmFuc2Zvcm06bm9uZX0KI21zZ3tjb2xvcjp2YXIoLS1hY2MpO2ZvbnQtc2l6ZToxMnB4O3RleHQt
dHJhbnNmb3JtOm5vbmU7bGV0dGVyLXNwYWNpbmc6MH0KLmJhZGdle2ZvbnQtc2l6ZToxMHB4O3Bh
ZGRpbmc6M3B4IDlweDtib3JkZXI6MXB4IHNvbGlkIHZhcigtLWFjYyk7Y29sb3I6dmFyKC0tYWNj
KTtmb250LXdlaWdodDo3MDA7bGV0dGVyLXNwYWNpbmc6LjEyZW19Ci53cmFwe21heC13aWR0aDox
MDYwcHg7bWFyZ2luOjAgYXV0bztwYWRkaW5nOjIycHggMTZweCA0NHB4fQouYmFubmVye2Rpc3Bs
YXk6ZmxleDtnYXA6MTFweDthbGlnbi1pdGVtczpmbGV4LXN0YXJ0O2JhY2tncm91bmQ6IzBjMWEz
Yjtib3JkZXI6MXB4IHNvbGlkIHZhcigtLWxpbmUyKTsKYm9yZGVyLWxlZnQ6M3B4IHNvbGlkICNm
MWIyNGE7Y29sb3I6I2YyZDc5ZjtwYWRkaW5nOjEycHggMTVweDtmb250LXNpemU6MTNweDttYXJn
aW4tYm90dG9tOjE4cHh9Ci5jb250cm9sc3tkaXNwbGF5OmdyaWQ7Z3JpZC10ZW1wbGF0ZS1jb2x1
bW5zOjFmciAxZnIgMWZyIGF1dG87Z2FwOjEwcHg7bWFyZ2luLWJvdHRvbToyMHB4fQpAbWVkaWEo
bWF4LXdpZHRoOjgyMHB4KXsuY29udHJvbHN7Z3JpZC10ZW1wbGF0ZS1jb2x1bW5zOjFmciAxZnJ9
fUBtZWRpYShtYXgtd2lkdGg6NDgwcHgpey5jb250cm9sc3tncmlkLXRlbXBsYXRlLWNvbHVtbnM6
MWZyfX0KLmJpZ2J0bntib3JkZXI6MXB4IHNvbGlkIHZhcigtLWxpbmUyKTtiYWNrZ3JvdW5kOiMw
YjE4MzY7Y29sb3I6dmFyKC0tZmcpOwpwYWRkaW5nOjE1cHggMThweDtmb250OmluaGVyaXQ7Zm9u
dC13ZWlnaHQ6NjAwO2N1cnNvcjpwb2ludGVyO2Rpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50
ZXI7Z2FwOjEycHg7dHJhbnNpdGlvbjouMTVzfQouYmlnYnRuOmhvdmVye2JvcmRlci1jb2xvcjp2
YXIoLS1hY2MpO2JhY2tncm91bmQ6IzBlMWY0N30uYmlnYnRuIC5pY3tmb250LXNpemU6MTZweDtj
b2xvcjp2YXIoLS1hY2MpfQouYmlnYnRuIHNtYWxse2Rpc3BsYXk6YmxvY2s7Y29sb3I6dmFyKC0t
bXV0KTtmb250LXdlaWdodDo0MDA7Zm9udC1zaXplOjExcHg7dGV4dC10cmFuc2Zvcm06dXBwZXJj
YXNlO2xldHRlci1zcGFjaW5nOi4wN2VtO21hcmdpbi10b3A6MnB4fQouYmlnYnRuLmFjdGl2ZXti
b3JkZXItY29sb3I6dmFyKC0tYWNjKTtiYWNrZ3JvdW5kOnZhcigtLW9rYmcpO2JveC1zaGFkb3c6
aW5zZXQgM3B4IDAgMCB2YXIoLS1hY2MpfS5iaWdidG4uYWN0aXZlIC5pY3tjb2xvcjp2YXIoLS1h
Y2MpfQouYmlnYnRuLnN0b3B7YmFja2dyb3VuZDojMWUxMDE2O2JvcmRlci1jb2xvcjojNTMyMzJl
O2NvbG9yOiNmZmIwYjg7anVzdGlmeS1jb250ZW50OmNlbnRlcjtmb250LXdlaWdodDo3MDA7bGV0
dGVyLXNwYWNpbmc6LjA1ZW07dGV4dC10cmFuc2Zvcm06dXBwZXJjYXNlO2ZvbnQtc2l6ZToxNHB4
fS5iaWdidG4uc3RvcDpob3Zlcntib3JkZXItY29sb3I6dmFyKC0tZXJyKX0KLnRhYnN7ZGlzcGxh
eTpmbGV4O2dhcDo0cHg7Ym9yZGVyLWJvdHRvbToxcHggc29saWQgdmFyKC0tbGluZTIpO21hcmdp
bi1ib3R0b206MjBweDtvdmVyZmxvdy14OmF1dG99Ci50YWJ7cGFkZGluZzoxMHB4IDE2cHg7Ym9y
ZGVyOjA7YmFja2dyb3VuZDowO2NvbG9yOnZhcigtLW11dCk7Zm9udDppbmhlcml0O2ZvbnQtd2Vp
Z2h0OjcwMDtmb250LXNpemU6MTJweDtsZXR0ZXItc3BhY2luZzouMDllbTt0ZXh0LXRyYW5zZm9y
bTp1cHBlcmNhc2U7Y3Vyc29yOnBvaW50ZXI7Ym9yZGVyLWJvdHRvbToycHggc29saWQgdHJhbnNw
YXJlbnQ7d2hpdGUtc3BhY2U6bm93cmFwO21hcmdpbi1ib3R0b206LTFweH0KLnRhYjpob3Zlcntj
b2xvcjp2YXIoLS1mZyl9LnRhYi5zZWx7Y29sb3I6dmFyKC0tYWNjKTtib3JkZXItYm90dG9tLWNv
bG9yOnZhcigtLWFjYyl9Ci5wYW5lbHtkaXNwbGF5Om5vbmV9LnBhbmVsLnNlbHtkaXNwbGF5OmJs
b2NrfQouZ3JpZHtkaXNwbGF5OmdyaWQ7Z2FwOjE2cHg7Z3JpZC10ZW1wbGF0ZS1jb2x1bW5zOjFm
ciAxZnJ9QG1lZGlhKG1heC13aWR0aDo3NjBweCl7LmdyaWR7Z3JpZC10ZW1wbGF0ZS1jb2x1bW5z
OjFmcn19Ci5jYXJke2JhY2tncm91bmQ6dmFyKC0tY2FyZCk7Ym9yZGVyOjFweCBzb2xpZCB2YXIo
LS1saW5lKTtwYWRkaW5nOjE4cHh9Ci5jYXJkIGgye2ZvbnQtc2l6ZToxMnB4O21hcmdpbjowO2Rp
c3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7Z2FwOjlweDt0ZXh0LXRyYW5zZm9ybTp1cHBl
cmNhc2U7bGV0dGVyLXNwYWNpbmc6LjFlbTtjb2xvcjojYzZkNmYxO2ZvbnQtd2VpZ2h0OjcwMH0K
LmNhcmQgaDI6YmVmb3Jle2NvbnRlbnQ6IiI7d2lkdGg6OXB4O2hlaWdodDo5cHg7YmFja2dyb3Vu
ZDp2YXIoLS1hY2MpO2ZsZXg6bm9uZX0KLmNhcmQgLnN1Yntjb2xvcjp2YXIoLS1tdXQpO2ZvbnQt
c2l6ZToxMnB4O21hcmdpbjo4cHggMCAxNHB4fQpsYWJlbHtkaXNwbGF5OmJsb2NrO2ZvbnQtc2l6
ZToxMXB4O2NvbG9yOnZhcigtLW11dCk7bWFyZ2luOjEzcHggMCA1cHg7Zm9udC13ZWlnaHQ6NzAw
O3RleHQtdHJhbnNmb3JtOnVwcGVyY2FzZTtsZXR0ZXItc3BhY2luZzouMDdlbX0KaW5wdXQsc2Vs
ZWN0e3dpZHRoOjEwMCU7YmFja2dyb3VuZDojMDcxNDJmO2JvcmRlcjoxcHggc29saWQgdmFyKC0t
bGluZTIpO2NvbG9yOnZhcigtLWZnKTtwYWRkaW5nOjEwcHggMTJweDtmb250OmluaGVyaXQ7b3V0
bGluZTowO3RyYW5zaXRpb246LjEyc30KaW5wdXQ6Zm9jdXMsc2VsZWN0OmZvY3Vze2JvcmRlci1j
b2xvcjp2YXIoLS1hY2MpO2JveC1zaGFkb3c6MCAwIDAgMnB4IHJnYmEoNDYsMTk2LDI0MSwuMTgp
fQoucm93e2Rpc3BsYXk6Z3JpZDtncmlkLXRlbXBsYXRlLWNvbHVtbnM6MWZyIDFmcjtnYXA6MTBw
eH0ucm93M3tkaXNwbGF5OmdyaWQ7Z3JpZC10ZW1wbGF0ZS1jb2x1bW5zOjFmciAxZnIgMWZyO2dh
cDoxMHB4fQouYnRue2JhY2tncm91bmQ6dmFyKC0tYWNjKTtjb2xvcjp2YXIoLS1uYXZ5KTtib3Jk
ZXI6MDtwYWRkaW5nOjEwcHggMThweDtmb250OmluaGVyaXQ7Zm9udC13ZWlnaHQ6NzAwO2xldHRl
ci1zcGFjaW5nOi4wNWVtO3RleHQtdHJhbnNmb3JtOnVwcGVyY2FzZTtmb250LXNpemU6MTNweDtj
dXJzb3I6cG9pbnRlcjttYXJnaW4tdG9wOjE2cHg7dHJhbnNpdGlvbjouMTJzfQouYnRuOmhvdmVy
e2JhY2tncm91bmQ6IzVhZDJmNn0uYnRuLnNlY3tiYWNrZ3JvdW5kOnRyYW5zcGFyZW50O2JvcmRl
cjoxcHggc29saWQgdmFyKC0tbGluZTIpO2NvbG9yOnZhcigtLWFjYyl9LmJ0bi5zZWM6aG92ZXJ7
Ym9yZGVyLWNvbG9yOnZhcigtLWFjYyk7YmFja2dyb3VuZDojMGIxYjQwfQouYnRuLnNte3BhZGRp
bmc6OHB4IDEzcHg7bWFyZ2luLXRvcDo0cHg7Zm9udC1zaXplOjEycHh9Ci5zd3tkaXNwbGF5OmZs
ZXg7YWxpZ24taXRlbXM6Y2VudGVyO2p1c3RpZnktY29udGVudDpzcGFjZS1iZXR3ZWVuO2dhcDox
MHB4O3BhZGRpbmc6MTNweCAwO2JvcmRlci10b3A6MXB4IHNvbGlkIHZhcigtLWxpbmUpfQouc3cu
Zmlyc3R7Ym9yZGVyLXRvcDowfS5zdyAudHtmb250LXNpemU6MTRweH0uc3cgLnQgc21hbGx7ZGlz
cGxheTpibG9jaztjb2xvcjp2YXIoLS1tdXQpO2ZvbnQtc2l6ZToxMnB4fQouc3dpdGNoe3Bvc2l0
aW9uOnJlbGF0aXZlO3dpZHRoOjQ2cHg7aGVpZ2h0OjI0cHg7ZmxleDpub25lfS5zd2l0Y2ggaW5w
dXR7b3BhY2l0eTowO3dpZHRoOjA7aGVpZ2h0OjB9Ci5zbGlkZXJ7cG9zaXRpb246YWJzb2x1dGU7
aW5zZXQ6MDtiYWNrZ3JvdW5kOiMwYjFhM2Q7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1saW5lMik7
dHJhbnNpdGlvbjouMnM7Y3Vyc29yOnBvaW50ZXJ9Ci5zbGlkZXI6YmVmb3Jle2NvbnRlbnQ6IiI7
cG9zaXRpb246YWJzb2x1dGU7aGVpZ2h0OjE2cHg7d2lkdGg6MTZweDtsZWZ0OjNweDt0b3A6M3B4
O2JhY2tncm91bmQ6dmFyKC0tbXV0KTt0cmFuc2l0aW9uOi4yc30KLnN3aXRjaCBpbnB1dDpjaGVj
a2VkKy5zbGlkZXJ7YmFja2dyb3VuZDp2YXIoLS1va2JnKTtib3JkZXItY29sb3I6dmFyKC0tYWNj
KX0uc3dpdGNoIGlucHV0OmNoZWNrZWQrLnNsaWRlcjpiZWZvcmV7dHJhbnNmb3JtOnRyYW5zbGF0
ZVgoMjJweCk7YmFja2dyb3VuZDp2YXIoLS1hY2MpfQouaGludHtmb250LXNpemU6MTJweDtjb2xv
cjp2YXIoLS1tdXQpO21hcmdpbi10b3A6MTBweDtsaW5lLWhlaWdodDoxLjV9Ci5mcmVxYm94e2Jh
Y2tncm91bmQ6IzA3MTQyZjtib3JkZXI6MXB4IHNvbGlkIHZhcigtLWxpbmUyKTtwYWRkaW5nOjEz
cHggMTZweDtkaXNwbGF5OmZsZXg7anVzdGlmeS1jb250ZW50OnNwYWNlLWJldHdlZW47YWxpZ24t
aXRlbXM6Y2VudGVyfQouZnJlcWJveCAuYmlne2ZvbnQtc2l6ZToyMnB4O2ZvbnQtd2VpZ2h0Ojcw
MDtsaW5lLWhlaWdodDoxLjE1O2ZvbnQtZmFtaWx5OnZhcigtLW1vbm8pO2NvbG9yOnZhcigtLWFj
Yyl9LmZyZXFib3ggLnNte2NvbG9yOnZhcigtLW11dCk7Zm9udC1zaXplOjEycHg7dGV4dC10cmFu
c2Zvcm06dXBwZXJjYXNlO2xldHRlci1zcGFjaW5nOi4wNmVtfQoubGlzdHJvd3tkaXNwbGF5OmZs
ZXg7anVzdGlmeS1jb250ZW50OnNwYWNlLWJldHdlZW47YWxpZ24taXRlbXM6Y2VudGVyO2JvcmRl
ci10b3A6MXB4IHNvbGlkIHZhcigtLWxpbmUpO3BhZGRpbmc6OXB4IDA7Zm9udC1zaXplOjE0cHh9
Ci5saXN0cm93OmZpcnN0LWNoaWxke2JvcmRlci10b3A6MH0udGFne2ZvbnQtZmFtaWx5OnZhcigt
LW1vbm8pO2ZvbnQtc2l6ZToxM3B4O2NvbG9yOiNjYWQ5ZjN9Ci54e2JhY2tncm91bmQ6IzFlMTAx
Njtib3JkZXI6MXB4IHNvbGlkICM1MzIzMmU7Y29sb3I6I2ZmOWJhNjtwYWRkaW5nOjRweCAxMHB4
O2N1cnNvcjpwb2ludGVyO2ZvbnQtc2l6ZToxMXB4O3RleHQtdHJhbnNmb3JtOnVwcGVyY2FzZTts
ZXR0ZXItc3BhY2luZzouMDVlbX0ueDpob3Zlcntib3JkZXItY29sb3I6dmFyKC0tZXJyKX0KLmVt
cHR5e2NvbG9yOnZhcigtLW11dDIpO2ZvbnQtc2l6ZToxM3B4O3BhZGRpbmc6OHB4IDB9Ci5sb2d7
YmFja2dyb3VuZDojMDMwYTE4O2JvcmRlcjoxcHggc29saWQgdmFyKC0tbGluZSk7cGFkZGluZzox
NHB4O2ZvbnQ6MTJweC8xLjU1IHZhcigtLW1vbm8pO2hlaWdodDo0NDBweDtvdmVyZmxvdzphdXRv
O3doaXRlLXNwYWNlOnByZS13cmFwO2NvbG9yOiM5ZmIzZDB9Ci50b29sYmFye2Rpc3BsYXk6Zmxl
eDtnYXA6OHB4O2FsaWduLWl0ZW1zOmNlbnRlcjttYXJnaW4tYm90dG9tOjEycHh9LnRvb2xiYXIg
aW5wdXR7ZmxleDoxfQouZWZ7d2lkdGg6MTAwJTtib3JkZXItY29sbGFwc2U6Y29sbGFwc2U7Zm9u
dC1zaXplOjEzcHg7bWFyZ2luLXRvcDo2cHh9LmVmIHRoe3RleHQtYWxpZ246bGVmdDtjb2xvcjp2
YXIoLS1tdXQpO2ZvbnQtc2l6ZToxMXB4O3RleHQtdHJhbnNmb3JtOnVwcGVyY2FzZTtsZXR0ZXIt
c3BhY2luZzouMDdlbTtwYWRkaW5nOjhweCA2cHg7Ym9yZGVyLWJvdHRvbToxcHggc29saWQgdmFy
KC0tbGluZTIpfS5lZiB0ZHtwYWRkaW5nOjEwcHggNnB4O2JvcmRlci1ib3R0b206MXB4IHNvbGlk
IHZhcigtLWxpbmUpO3ZlcnRpY2FsLWFsaWduOnRvcH0uZWYgY29kZXtmb250LWZhbWlseTp2YXIo
LS1tb25vKTtjb2xvcjp2YXIoLS1hY2MpO3dvcmQtYnJlYWs6YnJlYWstYWxsO3VzZXItc2VsZWN0
OmFsbH0ubXV0e2NvbG9yOnZhcigtLW11dCk7Zm9udC1zaXplOjExcHh9LmdlbndyYXB7b3ZlcmZs
b3cteDphdXRvO21hcmdpbi10b3A6MTJweH0uZ2Vud3JhcCAuZWYgdGQsLmdlbndyYXAgLmVmIHRo
e3doaXRlLXNwYWNlOm5vd3JhcH0uZ2Vud3JhcCBjb2Rle2ZvbnQtc2l6ZToxMnB4fS5idG46ZGlz
YWJsZWR7b3BhY2l0eTouNDtjdXJzb3I6ZGVmYXVsdH0ucHJvY3N7ZGlzcGxheTpncmlkO2dyaWQt
dGVtcGxhdGUtY29sdW1uczpyZXBlYXQoYXV0by1maWxsLG1pbm1heCgxMThweCwxZnIpKTtnYXA6
NnB4O21hcmdpbi10b3A6MTJweH0ucHJvY3tkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVy
O2p1c3RpZnktY29udGVudDpzcGFjZS1iZXR3ZWVuO2dhcDo2cHg7Ym9yZGVyOjFweCBzb2xpZCB2
YXIoLS1saW5lKTtib3JkZXItcmFkaXVzOjhweDtwYWRkaW5nOjRweCA0cHggNHB4IDhweDtmb250
LXNpemU6MTJweH0ucHJvYyAucGR7d2lkdGg6OHB4O2hlaWdodDo4cHg7Ym9yZGVyLXJhZGl1czo1
MCU7YmFja2dyb3VuZDp2YXIoLS1lcnIpO2ZsZXg6bm9uZX0ucHJvYyAucGQub257YmFja2dyb3Vu
ZDp2YXIoLS1vayl9LnByb2Mgc3BhbntmbGV4OjE7b3ZlcmZsb3c6aGlkZGVuO3RleHQtb3ZlcmZs
b3c6ZWxsaXBzaXN9LnByb2MgYnV0dG9ue2JvcmRlcjowO2JhY2tncm91bmQ6dHJhbnNwYXJlbnQ7
Y29sb3I6dmFyKC0tbXV0KTtjdXJzb3I6cG9pbnRlcjtmb250LXNpemU6MTVweDtwYWRkaW5nOjJw
eCA2cHg7Ym9yZGVyLXJhZGl1czo2cHh9LnByb2MgYnV0dG9uOmhvdmVye2NvbG9yOnZhcigtLWZn
KTtiYWNrZ3JvdW5kOnZhcigtLWxpbmUpfWNvZGV7Zm9udC1mYW1pbHk6dmFyKC0tbW9ubyl9QG1l
ZGlhKG1heC13aWR0aDo1NjBweCl7LnJvdywucm93M3tncmlkLXRlbXBsYXRlLWNvbHVtbnM6MWZy
fX0KPC9zdHlsZT48L2hlYWQ+PGJvZHk+CjxoZWFkZXI+CiA8ZGl2IGNsYXNzPWJyYW5kPjxzdmcg
eG1sbnM9Imh0dHA6Ly93d3cudzMub3JnLzIwMDAvc3ZnIiB2aWV3Qm94PSItMjAgLTIwIDY2OCAz
MzAiIHJvbGU9ImltZyIgYXJpYS1sYWJlbD0icEtPTSI+PGcgZmlsbD0ibm9uZSIgc3Ryb2tlLWxp
bmVjYXA9InJvdW5kIiBzdHJva2UtbGluZWpvaW49InJvdW5kIiBzdHJva2Utd2lkdGg9IjMyIj48
ZyBzdHJva2U9IiNGRkZGRkYiPjxwYXRoIGQ9Ik0yMCA4MCBWMjY2Ij48L3BhdGg+PGNpcmNsZSBj
eD0iNzIiIGN5PSIxMzMiIHI9IjUyIj48L2NpcmNsZT48cGF0aCBkPSJNMTc4IDE2IFEyMDYgMTAw
IDE3OCAxODQiPjwvcGF0aD48cGF0aCBkPSJNMTkyIDEwMCBDMjI2IDk2IDI1MCA2MiAyNjYgMTYi
PjwvcGF0aD48cGF0aCBkPSJNNDkyIDE4NCBWMzAgQzUyMiAzMCA1MzQgMTA2IDU1MiAxMDYgQzU3
MCAxMDYgNTgyIDMwIDYxMiAzMCBWMTg0Ij48L3BhdGg+PC9nPjxwYXRoIHN0cm9rZT0iIzJFQzRG
MSIgZD0iTTE5MiAxMDAgQzIzMyAxMDIgMjU2IDE4MyAzNjMgMTgzIEE4MyA4MyAwIDAgMCAzNjMg
MTcgQTgzIDgzIDAgMCAwIDI4MiAxMTgiPjwvcGF0aD48L2c+PC9zdmc+PHNwYW4gY2xhc3M9cHJv
ZD5OZXR6c3RldWVydW5nPC9zcGFuPjwvZGl2PgogPGRpdiBjbGFzcz1jaGlwPjxzcGFuIGNsYXNz
PWRvdCBpZD1kb3Q+PC9zcGFuPjxzcGFuIGlkPXN0YXRlPuKAkzwvc3Bhbj48L2Rpdj4KIDxkaXYg
Y2xhc3M9aHN0YXQ+CiAgPHNwYW4gaWQ9dGVjaGJhZGdlIGNsYXNzPWJhZGdlIHN0eWxlPWRpc3Bs
YXk6bm9uZT48L3NwYW4+CiAgPHNwYW4+RnJlcXVlbnogPGIgaWQ9ZnJlcT7igJM8L2I+PC9zcGFu
PgogIDxzcGFuPkxhdWZ6ZWl0IDxiIGlkPXVwdGltZT7igJM8L2I+PC9zcGFuPgogIDxzcGFuIGlk
PW1zZz48L3NwYW4+CiA8L2Rpdj4KPC9oZWFkZXI+CjxkaXYgY2xhc3M9d3JhcD4KIDxkaXYgY2xh
c3M9YmFubmVyPjxzcGFuPuKaoO+4jzwvc3Bhbj48c3Bhbj48Yj5OdXIgYWJnZXNjaG90dGV0IGJl
dHJlaWJlbjwvYj4g4oCTIER1bW15IExvYWQgLyBLYWJlbCArIETDpG1wZnVuZyAvIGdlc2NoaXJt
dC4gT2ZmZW5lcyBOZXR6IG9obmUgQXV0aGVudGlzaWVydW5nID0gSU1TSS1DYXRjaGVyLCB3ZW5u
IGVzIGFic3RyYWhsdC4gTnVyIGVpZ2VuZSBUZXN0LVNJTXMsIEtlbm51bmcgMDAxL3h4IChUZXN0
KSBvZGVyIDk5OS94eCAocHJpdmF0KS48L3NwYW4+PC9kaXY+CgogPGRpdiBjbGFzcz1jb250cm9s
cz4KICA8YnV0dG9uIGNsYXNzPWJpZ2J0biBpZD1idG5fZ3NtIG9uY2xpY2s9ImNtZCgnc3RhcnRf
Z3NtJykiPjxzcGFuIGNsYXNzPWljPuKWtjwvc3Bhbj48c3Bhbj5HU00gKDJHKTxzbWFsbCBpZD1n
c21fc3ViPk9zbW9jb208L3NtYWxsPjwvc3Bhbj48L2J1dHRvbj4KICA8YnV0dG9uIGNsYXNzPWJp
Z2J0biBpZD1idG5fbHRlIG9uY2xpY2s9ImNtZCgnc3RhcnRfbHRlJykiPjxzcGFuIGNsYXNzPWlj
PuKWtjwvc3Bhbj48c3Bhbj5MVEUgKDRHKTxzbWFsbCBpZD1sdGVfc3ViPnNyc1JBTiArIE9wZW41
R1M8L3NtYWxsPjwvc3Bhbj48L2J1dHRvbj4KICA8YnV0dG9uIGNsYXNzPWJpZ2J0biBpZD1idG5f
Y3NmYiBvbmNsaWNrPSJjbWQoJ3N0YXJ0X2NzZmInKSI+PHNwYW4gY2xhc3M9aWM+4pa2PC9zcGFu
PjxzcGFuPkxURSArIEdTTTxzbWFsbCBpZD1jc2ZiX3N1Yj5JbnRlcm5ldCArIEFucnVmZSAoQ1NG
Qik8L3NtYWxsPjwvc3Bhbj48L2J1dHRvbj4KICA8YnV0dG9uIGNsYXNzPSJiaWdidG4gc3RvcCIg
b25jbGljaz0iY21kKCdzdG9wJykiPuKWoCBTdG9wcGVuPC9idXR0b24+CiA8L2Rpdj4KCiA8ZGl2
IGNsYXNzPXRhYnM+CiAgPGJ1dHRvbiBjbGFzcz0idGFiIHNlbCIgZGF0YS10PXN0ZXVlcnVuZyBv
bmNsaWNrPSJ0YWIoJ3N0ZXVlcnVuZycpIj5TdGV1ZXJ1bmc8L2J1dHRvbj4KICA8YnV0dG9uIGNs
YXNzPXRhYiBkYXRhLXQ9Z3NtIG9uY2xpY2s9InRhYignZ3NtJykiPkdTTSDCtyAyRzwvYnV0dG9u
PgogIDxidXR0b24gY2xhc3M9dGFiIGRhdGEtdD1sdGUgb25jbGljaz0idGFiKCdsdGUnKSI+TFRF
IMK3IDRHPC9idXR0b24+CiAgPGJ1dHRvbiBjbGFzcz10YWIgZGF0YS10PXNpbXMgb25jbGljaz0i
dGFiKCdzaW1zJykiPlNJTXMgJiBOdW1tZXJuPC9idXR0b24+CiAgPGJ1dHRvbiBjbGFzcz10YWIg
ZGF0YS10PXByb2ZpbCBvbmNsaWNrPSJ0YWIoJ3Byb2ZpbCcpIj5TSU0tUHJvZmlsPC9idXR0b24+
CiAgPGJ1dHRvbiBjbGFzcz10YWIgZGF0YS10PWxvZyBvbmNsaWNrPSJ0YWIoJ2xvZycpIj5Qcm90
b2tvbGw8L2J1dHRvbj4KIDwvZGl2PgoKIDxkaXYgY2xhc3M9InBhbmVsIHNlbCIgaWQ9cC1zdGV1
ZXJ1bmc+CiAgPGRpdiBjbGFzcz1ncmlkPgogICA8ZGl2IGNsYXNzPWNhcmQ+CiAgICA8aDI+U3Rh
dHVzPC9oMj4KICAgIDxkaXYgY2xhc3M9ZnJlcWJveCBzdHlsZT1tYXJnaW4tdG9wOjEycHg+CiAg
ICAgPGRpdj48ZGl2IGNsYXNzPWJpZyBpZD1mcmVxMj7igJM8L2Rpdj48ZGl2IGNsYXNzPXNtIGlk
PWZyZXFzdWI+PC9kaXY+PC9kaXY+CiAgICAgPGRpdiBzdHlsZT10ZXh0LWFsaWduOnJpZ2h0Pjxk
aXYgY2xhc3M9YmlnIGlkPXRlY2gyPmF1czwvZGl2PjxkaXYgY2xhc3M9c20gaWQ9c3RhdGVzdWI+
PC9kaXY+PC9kaXY+CiAgICA8L2Rpdj4KICAgIDxkaXYgY2xhc3M9aGludCBpZD11cHRpbWVoaW50
PjwvZGl2PgogICAgPGRpdiBjbGFzcz1oaW50IGlkPWRldmhpbnQ+PC9kaXY+CiAgICA8ZGl2IGNs
YXNzPWhpbnQgaWQ9Y2xhc2ggc3R5bGU9Y29sb3I6dmFyKC0tZXJyKT48L2Rpdj4KICAgPC9kaXY+
CiAgIDxkaXYgY2xhc3M9Y2FyZD4KICAgIDxoMj5OZXVzdGFydGVuPC9oMj4KICAgIDxwIGNsYXNz
PXN1Yj5FaW56ZWxuZSBUZWlsZSBuZXUgc3RhcnRlbiwgb2huZSBkYXMgZ2FuemUgTmV0eiBhbnp1
aGFsdGVuLiBLb25maWd1cmF0aW9uIHdpcmQgZGFiZWkgbmV1IGdlc2NocmllYmVuLjwvcD4KICAg
IDxkaXYgaWQ9cGFydHMgc3R5bGU9ZGlzcGxheTpmbGV4O2dhcDo4cHg7ZmxleC13cmFwOndyYXA+
PC9kaXY+CiAgICA8ZGl2IGlkPXByb2NzIGNsYXNzPXByb2NzPjwvZGl2PgogICAgPGRpdiBjbGFz
cz1oaW50IGlkPXBhcnRoaW50PlN0YXJ0ZXQsIHNvYmFsZCBlaW4gTmV0eiBsw6R1ZnQuPC9kaXY+
CiAgIDwvZGl2PgogICA8ZGl2IGNsYXNzPWNhcmQ+CiAgICA8aDI+RnVuay1IYXJkd2FyZTwvaDI+
CiAgICA8cCBjbGFzcz1zdWI+SmUgTmV0eiBlaW4gZWlnZW5lciBMaW1lU0RSLiBGw7xyIOKAnkxU
RSArIEdTTeKAnCB6d2VpIHZlcnNjaGllZGVuZSB3w6RobGVuLjwvcD4KICAgIDxsYWJlbD5MaW1l
U0RSIGbDvHIgR1NNICgyRyk8L2xhYmVsPjxzZWxlY3QgaWQ9R1NNX0RFVj48L3NlbGVjdD4KICAg
IDxsYWJlbD5MaW1lU0RSIGbDvHIgTFRFICg0Ryk8L2xhYmVsPjxzZWxlY3QgaWQ9TFRFX0RFVj48
L3NlbGVjdD4KICAgIDxkaXYgc3R5bGU9ZGlzcGxheTpmbGV4O2dhcDo4cHg7ZmxleC13cmFwOndy
YXA+CiAgICAgPGJ1dHRvbiBjbGFzcz1idG4gb25jbGljaz0ic2F2ZShbJ0dTTV9ERVYnLCdMVEVf
REVWJ10pIj5TcGVpY2hlcm48L2J1dHRvbj4KICAgICA8YnV0dG9uIGNsYXNzPSJidG4gc2VjIiBv
bmNsaWNrPSJjbWQoJ2xpbWVfc2NhbicpIj5OZXUgc3VjaGVuPC9idXR0b24+CiAgICA8L2Rpdj4K
ICAgIDxkaXYgY2xhc3M9aGludCBpZD1saW1lbGlzdD48L2Rpdj4KICAgPC9kaXY+CiAgIDxkaXYg
Y2xhc3M9Y2FyZD4KICAgIDxoMj5OZXR6LUlkZW50aXTDpHQ8L2gyPgogICAgPHAgY2xhc3M9c3Vi
PkdpbHQgZsO8ciBHU00gdW5kIExURS4gTnVyIFRlc3RrZW5udW5nIDAwMS94eCBvZGVyIFByaXZh
dGtlbm51bmcgOTk5L3h4LjwvcD4KICAgIDxkaXYgY2xhc3M9cm93PgogICAgIDxkaXY+PGxhYmVs
Pk1DQzwvbGFiZWw+PGlucHV0IGlkPU1DQyBpbnB1dG1vZGU9bnVtZXJpYz48L2Rpdj4KICAgICA8
ZGl2PjxsYWJlbD5NTkM8L2xhYmVsPjxpbnB1dCBpZD1NTkMgaW5wdXRtb2RlPW51bWVyaWM+PC9k
aXY+CiAgICA8L2Rpdj4KICAgIDxkaXYgY2xhc3M9cm93PgogICAgIDxkaXY+PGxhYmVsPk5ldHpu
YW1lIChsYW5nKTwvbGFiZWw+PGlucHV0IGlkPU5FVE5BTUU+PC9kaXY+CiAgICAgPGRpdj48bGFi
ZWw+TmV0em5hbWUgKGt1cnopPC9sYWJlbD48aW5wdXQgaWQ9TkVUTkFNRV9TSE9SVD48L2Rpdj4K
ICAgIDwvZGl2PgogICAgPGxhYmVsPkFuYmlldGVybmFtZSAoU1BOLCBtYXguIDE2IFplaWNoZW4p
PC9sYWJlbD48aW5wdXQgaWQ9U1BOIG1heGxlbmd0aD0xNj4KICAgIDxkaXYgY2xhc3M9c3c+PGRp
diBjbGFzcz10Pk5JVFogc2VuZGVuPHNtYWxsPk5ldHpuYW1lLCBVaHJ6ZWl0IHVuZCBaZWl0em9u
ZSAoPHNwYW4gaWQ9dHo+4oCTPC9zcGFuPikgYmVpbSBFaW5idWNoZW48L3NtYWxsPjwvZGl2Pgog
ICAgIDxsYWJlbCBjbGFzcz1zd2l0Y2g+PGlucHV0IHR5cGU9Y2hlY2tib3ggaWQ9TklUWj48c3Bh
biBjbGFzcz1zbGlkZXI+PC9zcGFuPjwvbGFiZWw+PC9kaXY+CiAgICA8YnV0dG9uIGNsYXNzPSJi
dG4gc2VjIiBvbmNsaWNrPSJzYXZlKFsnTUNDJywnTU5DJywnTkVUTkFNRScsJ05FVE5BTUVfU0hP
UlQnLCdTUE4nLCdOSVRaJ10pIj5TcGVpY2hlcm48L2J1dHRvbj4KICAgIDxwIGNsYXNzPWhpbnQ+
RGFtaXQgZGFzIGlQaG9uZSBkYXMgTmV0eiBhbHMgPGI+SGVpbW5ldHo8L2I+IHNpZWh0IChrZWlu
IFJvYW1pbmcpLCBtdXNzIGRpZSBJTVNJIGRlciBlU0lNIG1pdCBNQ0MrTU5DIGJlZ2lubmVuOiA8
YiBjbGFzcz10YWcgaWQ9aHBsbW4+4oCTPC9iPuKApjwvcD4KICAgPC9kaXY+CiAgPC9kaXY+CiA8
L2Rpdj4KCiA8ZGl2IGNsYXNzPXBhbmVsIGlkPXAtZ3NtPgogIDxkaXYgY2xhc3M9Z3JpZD4KICAg
PGRpdiBjbGFzcz1jYXJkPgogICAgPGgyPkdTTS1GdW5rPC9oMj4KICAgIDxsYWJlbD5CYW5kPC9s
YWJlbD48c2VsZWN0IGlkPUdTTV9CQU5EIG9uY2hhbmdlPWdzbUJhbmQoKT48L3NlbGVjdD4KICAg
IDxkaXYgY2xhc3M9cm93IHN0eWxlPWFsaWduLWl0ZW1zOmVuZD4KICAgICA8ZGl2PjxsYWJlbD5B
UkZDTjwvbGFiZWw+PGlucHV0IGlkPUdTTV9BUkZDTiB0eXBlPW51bWJlciBpbnB1dG1vZGU9bnVt
ZXJpYyBvbmlucHV0PXVwZGF0ZUZyZXEoKT48L2Rpdj4KICAgICA8ZGl2IGNsYXNzPWZyZXFib3g+
PGRpdj48ZGl2IGNsYXNzPWJpZyBpZD1nc21fbWh6PuKAkzwvZGl2PjxkaXYgY2xhc3M9c20gaWQ9
Z3NtX2JhbmQ+PC9kaXY+PC9kaXY+PC9kaXY+CiAgICA8L2Rpdj4KICAgIDxkaXYgY2xhc3M9aGlu
dCBpZD1nc21fcmFuZ2U+PC9kaXY+CiAgICA8ZGl2IGNsYXNzPXJvdz48ZGl2PjxsYWJlbD5UWC1H
YWluPC9sYWJlbD48aW5wdXQgaWQ9R1NNX1RYX0dBSU4+PC9kaXY+CiAgICAgPGRpdj48bGFiZWw+
UlgtR2FpbiAoMOKAkzUwKTwvbGFiZWw+PGlucHV0IGlkPUdTTV9SWF9HQUlOPjwvZGl2PjwvZGl2
PgogICAgPGRpdiBjbGFzcz1oaW50PlJYLUdhaW4gaG9jaCA9IGVtcGZpbmRsaWNoZXJlciBFbXBm
YW5nICh3aWNodGlnIGbDvHIgRURHRS1VcGxpbmspLjwvZGl2PgogICAgPGJ1dHRvbiBjbGFzcz1i
dG4gb25jbGljaz0ic2F2ZShbJ0dTTV9CQU5EJywnR1NNX0FSRkNOJywnR1NNX1RYX0dBSU4nLCdH
U01fUlhfR0FJTiddKSI+U3BlaWNoZXJuPC9idXR0b24+CiAgIDwvZGl2PgogICA8ZGl2IGNsYXNz
PWNhcmQ+CiAgICA8aDI+R1NNLU9wdGlvbmVuPC9oMj4KICAgIDxkaXYgY2xhc3M9InN3IGZpcnN0
Ij48ZGl2IGNsYXNzPXQ+T2ZmZW5lIEFubWVsZHVuZzxzbWFsbD5qZWRlIFNJTSB3aXJkIGVpbmdl
YnVjaHQ8L3NtYWxsPjwvZGl2PgogICAgIDxsYWJlbCBjbGFzcz1zd2l0Y2g+PGlucHV0IHR5cGU9
Y2hlY2tib3ggaWQ9R1NNX09QRU4+PHNwYW4gY2xhc3M9c2xpZGVyPjwvc3Bhbj48L2xhYmVsPjwv
ZGl2PgogICAgPGRpdiBjbGFzcz1zdz48ZGl2IGNsYXNzPXQ+RURHRSAvIEdQUlMtRGF0ZW48c21h
bGw+UGFrZXRkYXRlbiAocGN1L3Nnc24vZ2dzbik8L3NtYWxsPjwvZGl2PgogICAgIDxsYWJlbCBj
bGFzcz1zd2l0Y2g+PGlucHV0IHR5cGU9Y2hlY2tib3ggaWQ9R1NNX0RBVEE+PHNwYW4gY2xhc3M9
c2xpZGVyPjwvc3Bhbj48L2xhYmVsPjwvZGl2PgogICAgPGRpdiBjbGFzcz1zdz48ZGl2IGNsYXNz
PXQ+U0lQLVRydW5rIHp1IEFzdGVyaXNrPHNtYWxsPkFucnVmZSBpbnMgVm9JUC9GZXN0bmV0ejwv
c21hbGw+PC9kaXY+CiAgICAgPGxhYmVsIGNsYXNzPXN3aXRjaD48aW5wdXQgdHlwZT1jaGVja2Jv
eCBpZD1HU01fU0lQPjxzcGFuIGNsYXNzPXNsaWRlcj48L3NwYW4+PC9sYWJlbD48L2Rpdj4KICAg
IDxsYWJlbD5TSVAtUGVlciAoQXN0ZXJpc2stSVApPC9sYWJlbD48aW5wdXQgaWQ9R1NNX1NJUF9Q
RUVSPgogICAgPGxhYmVsPlNJUC1Mb2NhbC1JUCAobGVlciA9IGF1dG9tYXRpc2NoKTwvbGFiZWw+
PGlucHV0IGlkPUdTTV9TSVBfTE9DQUw+CiAgICA8YnV0dG9uIGNsYXNzPWJ0biBvbmNsaWNrPSJz
YXZlKFsnR1NNX09QRU4nLCdHU01fREFUQScsJ0dTTV9TSVAnLCdHU01fU0lQX1BFRVInLCdHU01f
U0lQX0xPQ0FMJ10pIj5TcGVpY2hlcm48L2J1dHRvbj4KICAgPC9kaXY+CiAgIDxkaXYgY2xhc3M9
Y2FyZD4KICAgIDxoMj5CZWdyw7zDn3VuZ3MtU01TPC9oMj4KICAgIDxwIGNsYXNzPXN1Yj5TTVMg
YmVpbSBFaW5idWNoZW4gdW5kIGJlaSBOdW1tZXJudmVyZ2FiZS4gUGxhdHpoYWx0ZXI6IDxjb2Rl
PntuZXR6fTwvY29kZT4sIDxjb2RlPntudW1tZXJ9PC9jb2RlPiwgPGNvZGU+e2V4dGVybn08L2Nv
ZGU+LjwvcD4KICAgIDxkaXYgY2xhc3M9InN3IGZpcnN0Ij48ZGl2IGNsYXNzPXQ+U01TIGFrdGl2
PHNtYWxsPldpbGxrb21tZW4gKyBOdW1tZXJuLUJlc3TDpHRpZ3VuZzwvc21hbGw+PC9kaXY+CiAg
ICAgPGxhYmVsIGNsYXNzPXN3aXRjaD48aW5wdXQgdHlwZT1jaGVja2JveCBpZD1HU01fU01TPjxz
cGFuIGNsYXNzPXNsaWRlcj48L3NwYW4+PC9sYWJlbD48L2Rpdj4KICAgIDxsYWJlbD5BYnNlbmRl
ci1OdW1tZXI8L2xhYmVsPjxpbnB1dCBpZD1HU01fU01TX0ZST00+CiAgICA8bGFiZWw+RXh0ZXJu
ZSBWb3J3YWhsICg8Y29kZT57ZXh0ZXJufTwvY29kZT4gPSBWb3J3YWhsICsgaW50ZXJuZSBOdW1t
ZXIpPC9sYWJlbD48aW5wdXQgaWQ9R1NNX1NNU19FWFRQUkVGSVg+CiAgICA8bGFiZWw+V2lsbGtv
bW1lbnN0ZXh0IChiZWltIEVpbmJ1Y2hlbik8L2xhYmVsPjxpbnB1dCBpZD1HU01fU01TX1dFTENP
TUU+CiAgICA8bGFiZWw+QmVzdMOkdGlndW5nIChiZWkgTnVtbWVybnZlcmdhYmUpPC9sYWJlbD48
aW5wdXQgaWQ9R1NNX1NNU19OVU1CRVI+CiAgICA8YnV0dG9uIGNsYXNzPWJ0biBvbmNsaWNrPSJz
YXZlKFsnR1NNX1NNUycsJ0dTTV9TTVNfRlJPTScsJ0dTTV9TTVNfRVhUUFJFRklYJywnR1NNX1NN
U19XRUxDT01FJywnR1NNX1NNU19OVU1CRVInXSkiPlNwZWljaGVybjwvYnV0dG9uPgogICAgPHAg
Y2xhc3M9aGludD5CZWdyw7zDn3VuZyB3aXJkIGplIE5ldHotU3RhcnQgZWlubWFsIHBybyBTSU0g
Z2VzZW5kZXQgKHdpcmt0IHNvZm9ydCkuPC9wPgogICAgPGRpdiBzdHlsZT0iYm9yZGVyLXRvcDox
cHggc29saWQgdmFyKC0tbGluZSk7bWFyZ2luOjE0cHggMCI+PC9kaXY+CiAgICA8ZGl2IGNsYXNz
PXJvdz48ZGl2PjxsYWJlbD5UZXN0OiBJTVNJPC9sYWJlbD48aW5wdXQgaWQ9c21zX3Rlc3RfaW1z
aT48L2Rpdj4KICAgICA8ZGl2PjxsYWJlbD5UZXh0IChsZWVyID0gV2lsbGtvbW1lbnN0ZXh0KTwv
bGFiZWw+PGlucHV0IGlkPXNtc190ZXN0X3RleHQ+PC9kaXY+PC9kaXY+CiAgICA8YnV0dG9uIGNs
YXNzPSJidG4gc2VjIiBvbmNsaWNrPSJzbXN0ZXN0KCkiPlRlc3QtU01TIHNlbmRlbjwvYnV0dG9u
PgogICAgPHAgY2xhc3M9aGludD5TZW5kZXQgc29mb3J0IGFuIGRpZSBJTVNJIOKAkyBhdWNoIHdl
bm4g4oCeU01TIGFrdGl2IiBhdXMgaXN0LiBHU00gbXVzcyBsYXVmZW4uPC9wPgogICA8L2Rpdj4K
ICA8L2Rpdj4KICA8cCBjbGFzcz1oaW50PkZ1bmstL09wdGlvbnMtw4RuZGVydW5nZW4gd2lya2Vu
IGJlaW0gbsOkY2hzdGVuIEdTTS1TdGFydC48L3A+CiA8L2Rpdj4KCiA8ZGl2IGNsYXNzPXBhbmVs
IGlkPXAtbHRlPgogIDxkaXYgY2xhc3M9Z3JpZD4KICAgPGRpdiBjbGFzcz1jYXJkPgogICAgPGgy
PkxURS1GdW5rPC9oMj4KICAgIDxsYWJlbD5CYW5kPC9sYWJlbD48c2VsZWN0IGlkPWx0ZV9iYW5k
c2VsIG9uY2hhbmdlPWx0ZUJhbmQoKT48L3NlbGVjdD4KICAgIDxkaXYgY2xhc3M9cm93IHN0eWxl
PWFsaWduLWl0ZW1zOmVuZD4KICAgICA8ZGl2PjxsYWJlbD5FQVJGQ048L2xhYmVsPjxpbnB1dCBp
ZD1MVEVfRUFSRkNOIHR5cGU9bnVtYmVyIGlucHV0bW9kZT1udW1lcmljIG9uaW5wdXQ9dXBkYXRl
RnJlcSgpPjwvZGl2PgogICAgIDxkaXYgY2xhc3M9ZnJlcWJveD48ZGl2PjxkaXYgY2xhc3M9Ymln
IGlkPWx0ZV9taHo+4oCTPC9kaXY+PGRpdiBjbGFzcz1zbSBpZD1sdGVfYmFuZD48L2Rpdj48L2Rp
dj48L2Rpdj4KICAgIDwvZGl2PgogICAgPGRpdiBjbGFzcz1oaW50IGlkPWx0ZV9yYW5nZT48L2Rp
dj4KICAgIDxsYWJlbD5CYW5kYnJlaXRlIChQUkIpPC9sYWJlbD48c2VsZWN0IGlkPUxURV9OUFJC
IG9uY2hhbmdlPXVwZGF0ZUZyZXEoKT4KICAgICA8b3B0aW9uIHZhbHVlPTY+NiDCtyAxLjQgTUh6
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
ZWwnLHtpbXNpOml9KS50aGVuKHJlbmRlcik7fQpsZXQgQkFORFM9bnVsbDsKY29uc3QgTlBSQl9N
SFo9ezY6MS40LDE1OjMsMjU6NSw1MDoxMCw3NToxNSwxMDA6MjB9OwpmdW5jdGlvbiBpblIoYSxy
KXtyZXR1cm4gci5zb21lKHg9PmE+PXhbMF0mJmE8PXhbMV0pO30KZnVuY3Rpb24gZ3NtQmFuZE9m
KGEpe2lmKCFCQU5EUylyZXR1cm4gbnVsbDtjb25zdCBzZWw9JCgnR1NNX0JBTkQnKS52YWx1ZSxM
PUJBTkRTLmdzbTsKIGxldCBiPUwuZmluZCh4PT54LmlkPT09c2VsJiZpblIoYSx4LnJhbmdlcykp
O2lmKGIpcmV0dXJuIGI7CiBmb3IoY29uc3QgaWQgb2YgWydHU005MDAnLCdFR1NNOTAwJywnRENT
MTgwMCcsJ0dTTTg1MCcsJ1BDUzE5MDAnXSl7Yj1MLmZpbmQoeD0+eC5pZD09PWlkKTtpZihiJiZp
blIoYSxiLnJhbmdlcykpcmV0dXJuIGI7fXJldHVybiBudWxsO30KZnVuY3Rpb24gZ3NtRGwoYixh
KXtpZihiLmlkPT09J0dTTTg1MCcpcmV0dXJuIDg2OS4yKzAuMiooYS0xMjgpO2lmKGIuaWQ9PT0n
RENTMTgwMCcpcmV0dXJuIDE4MDUuMiswLjIqKGEtNTEyKTtpZihiLmlkPT09J1BDUzE5MDAnKXJl
dHVybiAxOTMwLjIrMC4yKihhLTUxMik7cmV0dXJuIDkzNSswLjIqKGE8PTEyND9hOmEtMTAyNCk7
fQpmdW5jdGlvbiBnc21JbmZvKGEpe2E9cGFyc2VJbnQoYSk7aWYoaXNOYU4oYSkpcmV0dXJue21o
ejon4oCTJyxiYW5kOidrZWluZSBnw7xsdGlnZSBBUkZDTicsb2s6ZmFsc2V9O2NvbnN0IGI9Z3Nt
QmFuZE9mKGEpO2lmKCFiKXJldHVybnttaHo6J+KAkycsYmFuZDona2VpbmUgZ8O8bHRpZ2UgQVJG
Q04nLG9rOmZhbHNlfTsKIGNvbnN0IGRsPWdzbURsKGIsYSk7cmV0dXJue21oejpkbC50b0ZpeGVk
KDEpKycgTUh6JyxiYW5kOmIubmFtZSsnIMK3IFVwbGluayAnKyhkbC1iLmR1cCkudG9GaXhlZCgx
KSsnIE1Ieicsb2s6dHJ1ZX07fQpmdW5jdGlvbiBsdGVCYW5kT2YoZSl7cmV0dXJuIEJBTkRTP0JB
TkRTLmx0ZS5maW5kKHg9PmU+PXgubG8mJmU8PXguaGkpOm51bGw7fQpmdW5jdGlvbiBsdGVJbmZv
KGUpe2U9cGFyc2VJbnQoZSk7Y29uc3QgYj1pc05hTihlKT9udWxsOmx0ZUJhbmRPZihlKTtpZigh
YilyZXR1cm57bWh6OifigJMnLGJhbmQ6J2tlaW5lIGfDvGx0aWdlIEVBUkZDTid9OwogY29uc3Qg
ZGw9Yi5mKzAuMSooZS1iLm9mZik7cmV0dXJue21oejpkbC50b0ZpeGVkKDEpKycgTUh6JyxiYW5k
OidCYW5kICcrYi5iYW5kKycgKCcrYi5uYW1lKycpIMK3IFVwbGluayAnKyhkbC1iLmR1cCkudG9G
aXhlZCgxKSsnIE1IeicsYjpifTt9CmZ1bmN0aW9uIGZpbGxCYW5kcyhzKXtpZihCQU5EU3x8IXMu
YmFuZHMpcmV0dXJuO0JBTkRTPXMuYmFuZHM7CiAkKCdHU01fQkFORCcpLmlubmVySFRNTD0nPG9w
dGlvbiB2YWx1ZT0iIj5hdXRvbWF0aXNjaCAoYXVzIEFSRkNOKTwvb3B0aW9uPicrQkFORFMuZ3Nt
Lm1hcChiPT4nPG9wdGlvbiB2YWx1ZT0iJytiLmlkKyciPicrZXNjKGIubmFtZSkrJyDCtyBBUkZD
TiAnK2IucmFuZ2VzLm1hcChyPT5yWzBdKyfigJMnK3JbMV0pLmpvaW4oJywgJykrJzwvb3B0aW9u
PicpLmpvaW4oJycpOwogJCgnbHRlX2JhbmRzZWwnKS5pbm5lckhUTUw9JzxvcHRpb24gdmFsdWU9
IiI+4oCTIEJhbmQgd8OkaGxlbiDigJM8L29wdGlvbj4nK0JBTkRTLmx0ZS5tYXAoYj0+JzxvcHRp
b24gdmFsdWU9IicrYi5iYW5kKyciPkJhbmQgJytiLmJhbmQrJyDCtyAnK2VzYyhiLm5hbWUpKycg
TUh6IMK3ICcrYi5mLnRvRml4ZWQoMCkrJ+KAkycrKGIuZisoYi5oaS1iLmxvKzEpLzEwKS50b0Zp
eGVkKDApKycgTUh6PC9vcHRpb24+Jykuam9pbignJyk7fQpmdW5jdGlvbiBnc21CYW5kKCl7Y29u
c3QgYj1CQU5EUyYmQkFORFMuZ3NtLmZpbmQoeD0+eC5pZD09PSQoJ0dTTV9CQU5EJykudmFsdWUp
LGE9cGFyc2VJbnQoJCgnR1NNX0FSRkNOJykudmFsdWUpOwogaWYoYiYmIWluUihhLGIucmFuZ2Vz
KSl7Y29uc3Qgcj1iLnJhbmdlc1tiLnJhbmdlcy5sZW5ndGg+MT8xOjBdOyQoJ0dTTV9BUkZDTicp
LnZhbHVlPU1hdGgucm91bmQoKHJbMF0rclsxXSkvMik7fXVwZGF0ZUZyZXEoKTt9CmZ1bmN0aW9u
IGx0ZUJhbmQoKXtjb25zdCBiPUJBTkRTJiZCQU5EUy5sdGUuZmluZCh4PT5TdHJpbmcoeC5iYW5k
KT09PSQoJ2x0ZV9iYW5kc2VsJykudmFsdWUpO2lmKCFiKXJldHVybjsKIGNvbnN0IGU9cGFyc2VJ
bnQoJCgnTFRFX0VBUkZDTicpLnZhbHVlKTtpZighKGU+PWIubG8mJmU8PWIuaGkpKSQoJ0xURV9F
QVJGQ04nKS52YWx1ZT1NYXRoLnJvdW5kKChiLmxvK2IuaGkpLzIpO3VwZGF0ZUZyZXEodHJ1ZSk7
fQpmdW5jdGlvbiB1cGRhdGVGcmVxKGtlZXBTZWwpe2xldCBnPWdzbUluZm8oJCgnR1NNX0FSRkNO
JykudmFsdWUpOyQoJ2dzbV9taHonKS50ZXh0Q29udGVudD1nLm1oejskKCdnc21fYmFuZCcpLnRl
eHRDb250ZW50PWcuYmFuZDsKIGNvbnN0IGdiPUJBTkRTJiZCQU5EUy5nc20uZmluZCh4PT54Lmlk
PT09JCgnR1NNX0JBTkQnKS52YWx1ZSk7CiAkKCdnc21fcmFuZ2UnKS50ZXh0Q29udGVudD1nYj8o
J0fDvGx0aWdlIEFSRkNOIGltICcrZ2IubmFtZSsnOiAnK2diLnJhbmdlcy5tYXAocj0+clswXSsn
4oCTJytyWzFdKS5qb2luKCcsICcpKTonQmFuZCDigJ5hdXRvbWF0aXNjaOKAnDogMeKAkzEyNCBH
U005MDAsIDk3NeKAkzEwMjMgRS1HU00sIDEyOOKAkzI1MSBHU004NTAsIDUxMuKAkzg4NSBEQ1Mx
ODAwLiBQQ1MxOTAwIG51ciDDvGJlciBkaWUgQmFuZHdhaGwuJzsKIGxldCBsPWx0ZUluZm8oJCgn
TFRFX0VBUkZDTicpLnZhbHVlKTskKCdsdGVfbWh6JykudGV4dENvbnRlbnQ9bC5taHo7JCgnbHRl
X2JhbmQnKS50ZXh0Q29udGVudD1sLmJhbmQ7CiBpZihsLmImJmtlZXBTZWwhPT10cnVlKSQoJ2x0
ZV9iYW5kc2VsJykudmFsdWU9U3RyaW5nKGwuYi5iYW5kKTsKIGNvbnN0IHNiPUJBTkRTJiZCQU5E
Uy5sdGUuZmluZCh4PT5TdHJpbmcoeC5iYW5kKT09PSQoJ2x0ZV9iYW5kc2VsJykudmFsdWUpOwog
aWYoc2Ipe2NvbnN0IGg9TWF0aC5yb3VuZCgoTlBSQl9NSFpbJCgnTFRFX05QUkInKS52YWx1ZV18
fDUpKjUpLGU9cGFyc2VJbnQoJCgnTFRFX0VBUkZDTicpLnZhbHVlKSxmaXQ9ZS1oPj1zYi5sbyYm
ZStoPD1zYi5oaTsKICAkKCdsdGVfcmFuZ2UnKS5pbm5lckhUTUw9J0VBUkZDTiBpbSBCYW5kICcr
c2IuYmFuZCsnOiAnKyhzYi5sbytoKSsn4oCTJysoc2IuaGktaCkrJyAoYmVpIGRpZXNlciBCYW5k
YnJlaXRlKScrKGZpdD8nJzonIMK3IDxiIHN0eWxlPWNvbG9yOnZhcigtLWVycik+cGFzc3Qgbmlj
aHQgaW5zIEJhbmQ8L2I+Jyk7fQogZWxzZSAkKCdsdGVfcmFuZ2UnKS50ZXh0Q29udGVudD0nJzt9
CmZ1bmN0aW9uIHNldHYoaWQsdil7bGV0IGVsPSQoaWQpO2lmKCFlbClyZXR1cm47aWYoZWwudHlw
ZT09PSdjaGVja2JveCcpZWwuY2hlY2tlZD0odj09PScxJ3x8dj09PXRydWUpO2Vsc2UgZWwudmFs
dWU9KHY9PW51bGw/Jyc6dik7fQpjb25zdCBGSUVMRFM9WydNQ0MnLCdNTkMnLCdORVROQU1FJywn
TkVUTkFNRV9TSE9SVCcsJ1NQTicsJ05JVFonLCdHU01fREVWJywnTFRFX0RFVicsJ0dTTV9CQU5E
JywnR1NNX0FSRkNOJywnR1NNX1RYX0dBSU4nLCdHU01fUlhfR0FJTicsJ0dTTV9TSVBfUEVFUics
J0dTTV9TSVBfTE9DQUwnLCdHU01fT1BFTicsJ0dTTV9EQVRBJywnR1NNX1NJUCcsJ0dTTV9TTVMn
LCdHU01fU01TX0ZST00nLCdHU01fU01TX0VYVFBSRUZJWCcsJ0dTTV9TTVNfV0VMQ09NRScsJ0dT
TV9TTVNfTlVNQkVSJywnTFRFX0VBUkZDTicsJ0xURV9OUFJCJywnTFRFX1RYX0dBSU4nLCdMVEVf
UlhfR0FJTicsJ0xURV9BUE4nXTsKbGV0IGZpbGxlZD1mYWxzZSxsaW1lS2V5PScnOwpmdW5jdGlv
biBsaW1lT3B0aW9ucyhzKXsKIGNvbnN0IEw9cy5saW1lc3x8W10sYz1zLmNvbmZ8fHt9LGtleT1K
U09OLnN0cmluZ2lmeShMKSsoYy5HU01fREVWfHwnJykrKGMuTFRFX0RFVnx8JycpOwogaWYoa2V5
PT09bGltZUtleSlyZXR1cm47bGltZUtleT1rZXk7CiBbJ0dTTV9ERVYnLCdMVEVfREVWJ10uZm9y
RWFjaChpZD0+e2NvbnN0IGVsPSQoaWQpLGN1cj1jW2lkXXx8Jyc7CiAgbGV0IG89JzxvcHRpb24g
dmFsdWU9IiI+YXV0b21hdGlzY2g8L29wdGlvbj4nK0wubWFwKGQ9Pic8b3B0aW9uIHZhbHVlPSIn
K2VzYyhkLnNlcmlhbCkrJyI+Jytlc2MoZC5uYW1lKSsnIMK3ICcrZXNjKGQuc2VyaWFsKSsoZC5t
ZWRpYT8nIMK3ICcrZXNjKGQubWVkaWEpOicnKSsnPC9vcHRpb24+Jykuam9pbignJyk7CiAgaWYo
Y3VyJiYhTC5zb21lKGQ9PmQuc2VyaWFsPT09Y3VyKSlvKz0nPG9wdGlvbiB2YWx1ZT0iJytlc2Mo
Y3VyKSsnIj4nK2VzYyhjdXIpKycgKG5pY2h0IGdlZnVuZGVuKTwvb3B0aW9uPic7CiAgZWwuaW5u
ZXJIVE1MPW87ZWwudmFsdWU9Y3VyO30pOwogJCgnbGltZWxpc3QnKS50ZXh0Q29udGVudD1MLmxl
bmd0aD9MLmxlbmd0aCsnIExpbWVTRFIgYW5nZXNjaGxvc3Nlbic6J0tlaW4gTGltZVNEUiBnZWZ1
bmRlbiDigJMgVVNCIHByw7xmZW4gdW5kIOKAnk5ldSBzdWNoZW7igJwuJzsKfQpmdW5jdGlvbiBy
ZWxvYWRGaWVsZHMoKXtjb25zdCBjPVMuY29uZnx8e307RklFTERTLmZvckVhY2goaz0+e2lmKGRv
Y3VtZW50LmFjdGl2ZUVsZW1lbnQhPT0kKGspKXNldHYoayxjW2tdKTt9KTtmaWxsZWQ9dHJ1ZTt1
cGRhdGVGcmVxKCk7fQpmdW5jdGlvbiBmbXQocyl7Y29uc3QgbT1NYXRoLmZsb29yKHMvNjApLGg9
TWF0aC5mbG9vcihtLzYwKTtyZXR1cm4gaD9oKydoICcrKG0lNjApKydtJzoobT9tKydtICcrKHMl
NjApKydzJzpzKydzJyk7fQpmdW5jdGlvbiByZW5kZXJsb2coKXtjb25zdCBmPSgkKCdsb2dmaWx0
ZXInKS52YWx1ZXx8JycpLnRvTG93ZXJDYXNlKCk7bGV0IEw9KFMubG9nfHxbXSk7aWYoZilMPUwu
ZmlsdGVyKHg9PngudG9Mb3dlckNhc2UoKS5pbmNsdWRlcyhmKSk7Y29uc3QgbGc9JCgnbG9nJyk7
Y29uc3QgbmVhcj1sZy5zY3JvbGxUb3ArbGcuY2xpZW50SGVpZ2h0Pj1sZy5zY3JvbGxIZWlnaHQt
NDA7bGcudGV4dENvbnRlbnQ9TC5qb2luKCdcbicpOyQoJ2xvZ2NvdW50JykudGV4dENvbnRlbnQ9
TC5sZW5ndGgrJyBaZWlsZW4nO2lmKG5lYXIpbGcuc2Nyb2xsVG9wPWxnLnNjcm9sbEhlaWdodDt9
CmZ1bmN0aW9uIHJlbmRlcihzKXtTPXM7ZmlsbEJhbmRzKHMpO2xpbWVPcHRpb25zKHMpO2lmKCFm
aWxsZWQpcmVsb2FkRmllbGRzKCk7CiBjb25zdCBydW49cy5zdGF0ZT09PSdsYWV1ZnQnLHQ9cy50
ZWNoOwogJCgnZG90JykuY2xhc3NOYW1lPSdkb3QgJysocnVuPydvbic6KHMuc3RhdGU9PT0nZmVo
bGVyJz8nZXJyJzonJykpOwogJCgnc3RhdGUnKS50ZXh0Q29udGVudD1zLnN0YXRlOyQoJ21zZycp
LnRleHRDb250ZW50PXMubXNnfHwnJzsKIGNvbnN0IHRiPSQoJ3RlY2hiYWRnZScpO2lmKHQpe3Ri
LnN0eWxlLmRpc3BsYXk9Jyc7dGIudGV4dENvbnRlbnQ9dD09PSdjc2ZiJz8nTFRFK0dTTSc6dC50
b1VwcGVyQ2FzZSgpO31lbHNlIHRiLnN0eWxlLmRpc3BsYXk9J25vbmUnOwogbGV0IGZyZXE9J+KA
kycsZnN1Yj0nJzsKIGNvbnN0IGdmPXMuZ3NtLm1oeisnIE1IeicsbGY9cy5sdGUubWh6KycgTUh6
JzsKIGlmKHQ9PT0nbHRlJyl7ZnJlcT1sZjtmc3ViPSdCYW5kICcrcy5sdGUuYmFuZCsnIMK3IEVB
UkZDTiAnK3MubHRlLmVhcmZjbjt9CiBlbHNlIGlmKHQ9PT0nZ3NtJyl7ZnJlcT1nZjtmc3ViPXMu
Z3NtLmJhbmQrJyDCtyBBUkZDTiAnK3MuZ3NtLmFyZmNuO30KIGVsc2UgaWYodD09PSdjc2ZiJyl7
ZnJlcT1sZisnIC8gJytnZjtmc3ViPSdMVEUgQicrcy5sdGUuYmFuZCsnIMK3IEdTTSBBUkZDTiAn
K3MuZ3NtLmFyZmNuO30KICQoJ2ZyZXEnKS50ZXh0Q29udGVudD1mcmVxOyQoJ2ZyZXEyJykudGV4
dENvbnRlbnQ9ZnJlcTskKCdmcmVxc3ViJykudGV4dENvbnRlbnQ9ZnN1YjsKICQoJ3RlY2gyJyku
dGV4dENvbnRlbnQ9dD8odD09PSdjc2ZiJz8nTFRFK0dTTSc6dC50b1VwcGVyQ2FzZSgpKTonYXVz
JzskKCdzdGF0ZXN1YicpLnRleHRDb250ZW50PXMuc3RhdGU7CiAkKCd1cHRpbWUnKS50ZXh0Q29u
dGVudD1zLnVwdGltZT9mbXQocy51cHRpbWUpOifigJMnOyQoJ3VwdGltZWhpbnQnKS50ZXh0Q29u
dGVudD1ydW4/KCdsw6R1ZnQgc2VpdCAnK2ZtdChzLnVwdGltZSkpOicnOwogJCgnZGV2aGludCcp
LmlubmVySFRNTD1bcy5kZXYuZ3NtPydHU00tRnVuazogPGI+Jytlc2Mocy5kZXYuZ3NtKSsnPC9i
Pic6Jycscy5kZXYubHRlPydMVEUtRnVuazogPGI+Jytlc2Mocy5kZXYubHRlKSsnPC9iPic6Jydd
LmZpbHRlcihCb29sZWFuKS5qb2luKCc8YnI+Jyk7CiAkKCdjbGFzaCcpLnRleHRDb250ZW50PXMu
Y2xhc2h8fCcnOwogW1snZ3NtJywnT3Ntb2NvbSddLFsnbHRlJywnc3JzUkFOICsgT3BlbjVHUydd
LFsnY3NmYicsJ0ludGVybmV0ICsgQW5ydWZlIChDU0ZCKSddXS5mb3JFYWNoKChbayxkXSk9Pnsk
KCdidG5fJytrKS5jbGFzc0xpc3QudG9nZ2xlKCdhY3RpdmUnLHQ9PT1rKTskKGsrJ19zdWInKS50
ZXh0Q29udGVudD10PT09az8nbMOkdWZ0JzpkO30pOwogJCgndHonKS50ZXh0Q29udGVudD1zLnR6
fHwn4oCTJzsKIGNvbnN0IGY9cy5zaW1maWxlc3x8e307JCgnaHBsbW4nKS50ZXh0Q29udGVudD1m
LmhwbG1ufHwn4oCTJzsKICQoJ2VmX3NwbicpLnRleHRDb250ZW50PWYuc3BufHwnJzskKCdlZl9z
cG5fdCcpLnRleHRDb250ZW50PSfigJ4nKyhmLnNwbl90ZXh0fHwnJykrJ+KAnCc7CiAkKCdlZl9w
bm4nKS50ZXh0Q29udGVudD1mLnBubnx8Jyc7JCgnZWZfcG5uX3QnKS50ZXh0Q29udGVudD0nbGFu
ZyDigJ4nKyhmLmZ1bGx8fCcnKSsn4oCcLCBrdXJ6IOKAnicrKGYuc2hvcnR8fCcnKSsn4oCcJzsK
ICQoJ2VmX29wbCcpLnRleHRDb250ZW50PWYub3BsfHwnJzskKCdlZl9vcGxfdCcpLnRleHRDb250
ZW50PSdLZW5udW5nICcrKGYuaHBsbW58fCcnKSsnLCBhbGxlIEdlYmlldGUg4oaSIFBOTiAxJzsK
ICQoJ2VmX2hwbG1uJykudGV4dENvbnRlbnQ9Zi5ocGxtbnx8Jyc7CiAkKCdnc21fbnVtYmVycycp
LmlubmVySFRNTD1PYmplY3QuZW50cmllcyhzLmdzbS5udW1iZXJzfHx7fSkubWFwKGU9Pic8ZGl2
IGNsYXNzPWxpc3Ryb3c+PHNwYW4gY2xhc3M9dGFnPicrZXNjKGVbMF0pKycg4oaSIDxiPicrZXNj
KGVbMV0pKyc8L2I+PC9zcGFuPjxidXR0b24gY2xhc3M9eCBvbmNsaWNrPSJudW1kZWwoXCcnK2Vz
YyhlWzBdKSsnXCcpIj5sw7ZzY2hlbjwvYnV0dG9uPjwvZGl2PicpLmpvaW4oJycpfHwnPGRpdiBj
bGFzcz1lbXB0eT5rZWluZSBadXdlaXN1bmdlbjwvZGl2Pic7CiAkKCdhdHRhY2hlZCcpLmlubmVy
SFRNTD0ocy5nc20uYXR0YWNoZWR8fFtdKS5tYXAoaT0+JzxkaXYgY2xhc3M9bGlzdHJvdz48c3Bh
biBjbGFzcz10YWc+Jytlc2MoaSkrJzwvc3Bhbj48c3BhbiBjbGFzcz10YWc+Jytlc2MoKHMuZ3Nt
Lm51bWJlcnN8fHt9KVtpXXx8JycpKyc8L3NwYW4+PC9kaXY+Jykuam9pbignJyl8fCc8ZGl2IGNs
YXNzPWVtcHR5PmtlaW5lIGVpbmdlYnVjaHQ8L2Rpdj4nOwogJCgnc2ltcycpLmlubmVySFRNTD0o
cy5zaW1zfHxbXSkubWFwKHg9Pic8ZGl2IGNsYXNzPWxpc3Ryb3c+PHNwYW4gY2xhc3M9dGFnPicr
ZXNjKHguaW1zaSkrJyDCtyA8Yj4nK2VzYyh4Lm1zaXNkbikrJzwvYj48L3NwYW4+PGJ1dHRvbiBj
bGFzcz14IG9uY2xpY2s9InNpbWRlbChcJycrZXNjKHguaW1zaSkrJ1wnKSI+bMO2c2NoZW48L2J1
dHRvbj48L2Rpdj4nKS5qb2luKCcnKXx8JzxkaXYgY2xhc3M9ZW1wdHk+bm9jaCBrZWluZSBTSU0g
ZWluZ2V0cmFnZW48L2Rpdj4nOwogcmVuZGVyUGFydHMocyk7CiByZW5kZXJsb2coKTsKfQpsZXQg
cGFydEtleT0nJzsKZnVuY3Rpb24gcmVzdGFydChwLGxhYmVsKXtpZihTLmJ1c3kpcmV0dXJuO2lm
KCFjb25maXJtKChsYWJlbHx8cCkrJyBuZXUgc3RhcnRlbj8nKSlyZXR1cm47JCgnbXNnJykudGV4
dENvbnRlbnQ9KGxhYmVsfHxwKSsnIHN0YXJ0ZXQgbmV14oCmJzthcGkoJ3Jlc3RhcnQnLHtwYXJ0
OnB9KS50aGVuKHJlbmRlcik7fQpmdW5jdGlvbiByZW5kZXJQYXJ0cyhzKXtjb25zdCBQPXMucGFy
dHN8fFtdLEw9cy5wcm9jc3x8W10sa2V5PUpTT04uc3RyaW5naWZ5KFtQLEwubWFwKHg9Plt4LnRh
Zyx4LnJ1bl0pLHMuYnVzeV0pO2lmKGtleT09PXBhcnRLZXkpcmV0dXJuO3BhcnRLZXk9a2V5Owog
JCgncGFydHMnKS5pbm5lckhUTUw9UC5tYXAoeD0+JzxidXR0b24gY2xhc3M9ImJ0biBzZWMiICcr
KHMuYnVzeT8nZGlzYWJsZWQnOicnKSsnIG9uY2xpY2s9InJlc3RhcnQoXCcnK3guaWQrJ1wnLFwn
Jytlc2MoeC5uYW1lKSsnXCcpIj7ihrsgJytlc2MoeC5uYW1lKSsnPC9idXR0b24+Jykuam9pbign
Jyk7CiAkKCdwcm9jcycpLmlubmVySFRNTD1MLm1hcCh4PT4nPGRpdiBjbGFzcz1wcm9jIHRpdGxl
PSInK2VzYyh4Lmdyb3VwLnRvVXBwZXJDYXNlKCkpKyh4LnJ1bj8nIMK3IGzDpHVmdCc6JyDCtyBi
ZWVuZGV0IChDb2RlICcrZXNjKHgucmMpKycpJykrJyI+PGkgY2xhc3M9InBkJysoeC5ydW4/JyBv
bic6JycpKyciPjwvaT48c3Bhbj4nK2VzYyh4LnRhZykrJzwvc3Bhbj48YnV0dG9uICcrKHMuYnVz
eT8nZGlzYWJsZWQnOicnKSsnIG9uY2xpY2s9InJlc3RhcnQoXCcnK2VzYyh4LnRhZykrJ1wnKSIg
YXJpYS1sYWJlbD0iJytlc2MoeC50YWcpKycgbmV1IHN0YXJ0ZW4iPuKGuzwvYnV0dG9uPjwvZGl2
PicpLmpvaW4oJycpOwogJCgncGFydGhpbnQnKS50ZXh0Q29udGVudD1zLmJ1c3k/KCdOZXVzdGFy
dCBsw6R1ZnQ6ICcrcy5idXN5KTooUC5sZW5ndGg/J0dyw7xuID0gbMOkdWZ0LCByb3QgPSBiZWVu
ZGV0LiDihrsgc3RhcnRldCBudXIgZGllc2VuIFByb3plc3MgbmV1Lic6J1N0YXJ0ZXQsIHNvYmFs
ZCBlaW4gTmV0eiBsw6R1ZnQuJyk7fQpsZXQgR0VOPVtdOwpmdW5jdGlvbiBzaW1nZW4oKXthcGko
J3NpbV9nZW4nLHtjb3VudDokKCdnZW5fbicpLnZhbHVlLG1zaXNkbjokKCdnZW5fbnInKS52YWx1
ZSxpY2NpZDokKCdnZW5faWNjaWQnKS52YWx1ZX0pLnRoZW4ocj0+e0dFTj1yLmdlbmVyYXRlZHx8
W107Z2VuZHJhdygpO3JlbmRlcihyKTt9KTt9CmNvbnN0IEdDT0xTPVtbJ2ljY2lkJywnSUNDSUQn
XSxbJ2ltc2knLCdJTVNJJ10sWydraScsJ0tpJ10sWydvcCcsJ09QJ10sWydvcGMnLCdPUGMnXSxb
J21zaXNkbicsJ1J1Zm5yLiddLFsncGluMScsJ1BJTjEnXSxbJ3B1azEnLCdQVUsxJ10sWydwaW4y
JywnUElOMiddLFsncHVrMicsJ1BVSzInXSxbJ2FkbTEnLCdBRE0xJ11dOwpmdW5jdGlvbiBnZW5k
cmF3KCl7Y29uc3QgVD0kKCdnZW5fdGFiJyk7CiBULmlubmVySFRNTD1HRU4ubGVuZ3RoPyc8dHI+
JytHQ09MUy5tYXAoYz0+Jzx0aD4nK2NbMV0rJzwvdGg+Jykuam9pbignJykrJzx0aD48L3RoPjwv
dHI+JytHRU4ubWFwKChnLGkpPT4nPHRyPicrR0NPTFMubWFwKGM9Pic8dGQ+PGNvZGU+Jytlc2Mo
Z1tjWzBdXSkrJzwvY29kZT48L3RkPicpLmpvaW4oJycpKyc8dGQ+PGJ1dHRvbiBjbGFzcz0iYnRu
IHNtIHNlYyIgb25jbGljaz0iZ2VudGFrZSgnK2krJykiPsO8YmVybmVobWVuPC9idXR0b24+PC90
ZD48L3RyPicpLmpvaW4oJycpOicnOwogWydnZW5fdGFrZScsJ2dlbl9jc3YnLCdnZW5fanNvbidd
LmZvckVhY2goaWQ9PiQoaWQpLmRpc2FibGVkPSFHRU4ubGVuZ3RoKTt9CmFzeW5jIGZ1bmN0aW9u
IGdlbnRha2UoaSl7Y29uc3QgTD1pPT09dW5kZWZpbmVkP0dFTjpbR0VOW2ldXTtsZXQgb2s9MCxs
YXN0PW51bGw7CiBmb3IoY29uc3QgZyBvZiBMKXtsYXN0PWF3YWl0IGFwaSgnc2ltX2FkZCcse2lt
c2k6Zy5pbXNpLGtpOmcua2ksb3BjOmcub3BjLG1zaXNkbjpnLm1zaXNkbn0pO2lmKCEvYWJlcnxw
cnVlZmVuLy50ZXN0KGxhc3QubXNnfHwnJykpb2srKzt9CiBpZihsYXN0KXtyZW5kZXIobGFzdCk7
JCgnbXNnJykudGV4dENvbnRlbnQ9b2srJyB2b24gJytMLmxlbmd0aCsnIFNJTShzKSBpbiBwS09N
IMO8YmVybm9tbWVuJysob2s8TC5sZW5ndGg/JyDigJMgJytsYXN0Lm1zZzonJyk7fX0KZnVuY3Rp
b24gZ2VuZGwoZm10KXtpZighR0VOLmxlbmd0aClyZXR1cm47bGV0IGRhdGEsdHlwZSxuYW1lPSdw
a29tLXNpbXMtJytuZXcgRGF0ZSgpLnRvSVNPU3RyaW5nKCkuc2xpY2UoMCwxMCk7CiBpZihmbXQ9
PT0nanNvbicpe2RhdGE9SlNPTi5zdHJpbmdpZnkoR0VOLG51bGwsMSk7dHlwZT0nYXBwbGljYXRp
b24vanNvbic7bmFtZSs9Jy5qc29uJzt9CiBlbHNle2NvbnN0IGs9T2JqZWN0LmtleXMoR0VOWzBd
KTtkYXRhPVtrLmpvaW4oJzsnKV0uY29uY2F0KEdFTi5tYXAoZz0+ay5tYXAoeD0+Z1t4XSkuam9p
bignOycpKSkuam9pbihTdHJpbmcuZnJvbUNoYXJDb2RlKDEzLDEwKSk7dHlwZT0ndGV4dC9jc3Yn
O25hbWUrPScuY3N2Jzt9CiBjb25zdCBhPWRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2EnKTthLmhy
ZWY9VVJMLmNyZWF0ZU9iamVjdFVSTChuZXcgQmxvYihbZGF0YV0se3R5cGV9KSk7YS5kb3dubG9h
ZD1uYW1lO2EuY2xpY2soKTtzZXRUaW1lb3V0KCgpPT5VUkwucmV2b2tlT2JqZWN0VVJMKGEuaHJl
ZiksMjAwMCk7fQphc3luYyBmdW5jdGlvbiBwb2xsKCl7dHJ5e3JlbmRlcihhd2FpdCBhcGkoJ3N0
YXR1cycpKTt9Y2F0Y2goZSl7fX0KdHJ5e2NvbnN0IHQ9bG9jYWxTdG9yYWdlLmdldEl0ZW0oJ3Br
b21fdGFiJyk7aWYodCYmJCgncC0nK3QpKXRhYih0KTt9Y2F0Y2goZSl7fQpwb2xsKCk7c2V0SW50
ZXJ2YWwocG9sbCwyNTAwKTsKPC9zY3JpcHQ+PC9ib2R5PjwvaHRtbD4iIiIKCmNsYXNzIEhhbmRs
ZXIoQmFzZUhUVFBSZXF1ZXN0SGFuZGxlcik6CiAgICBkZWYgbG9nX21lc3NhZ2Uoc2VsZiwgKmEp
OiBwYXNzCiAgICBkZWYgX3NlbmQoc2VsZiwgY29kZSwgYm9keSwgY3R5cGU9ImFwcGxpY2F0aW9u
L2pzb24iKToKICAgICAgICBiID0gYm9keS5lbmNvZGUoKSBpZiBpc2luc3RhbmNlKGJvZHksIHN0
cikgZWxzZSBib2R5CiAgICAgICAgc2VsZi5zZW5kX3Jlc3BvbnNlKGNvZGUpCiAgICAgICAgc2Vs
Zi5zZW5kX2hlYWRlcigiQ29udGVudC1UeXBlIiwgY3R5cGUpCiAgICAgICAgc2VsZi5zZW5kX2hl
YWRlcigiQ29udGVudC1MZW5ndGgiLCBzdHIobGVuKGIpKSkKICAgICAgICBzZWxmLmVuZF9oZWFk
ZXJzKCkKICAgICAgICB0cnk6IHNlbGYud2ZpbGUud3JpdGUoYikKICAgICAgICBleGNlcHQgRXhj
ZXB0aW9uOiBwYXNzCiAgICBkZWYgZG9fR0VUKHNlbGYpOgogICAgICAgIGlmIHNlbGYucGF0aCBp
biAoIi8iLCAiL2luZGV4Lmh0bWwiKToKICAgICAgICAgICAgc2VsZi5fc2VuZCgyMDAsIFBBR0Us
ICJ0ZXh0L2h0bWw7IGNoYXJzZXQ9dXRmLTgiKQogICAgICAgIGVsaWYgc2VsZi5wYXRoID09ICIv
YXBpL3N0YXR1cyI6CiAgICAgICAgICAgIHNlbGYuX3NlbmQoMjAwLCBqc29uLmR1bXBzKE5FVC5z
dGF0dXMoKSkpCiAgICAgICAgZWxzZToKICAgICAgICAgICAgc2VsZi5fc2VuZCg0MDQsICJ7fSIp
CiAgICBkZWYgZG9fUE9TVChzZWxmKToKICAgICAgICBuID0gaW50KHNlbGYuaGVhZGVycy5nZXQo
IkNvbnRlbnQtTGVuZ3RoIiwgMCkgb3IgMCkKICAgICAgICBib2R5ID0gc2VsZi5yZmlsZS5yZWFk
KG4pLmRlY29kZShlcnJvcnM9InJlcGxhY2UiKSBpZiBuIGVsc2UgIiIKICAgICAgICBpZiBzZWxm
LnBhdGguc3RhcnRzd2l0aCgiL2FwaS8iKToKICAgICAgICAgICAgdHJ5OgogICAgICAgICAgICAg
ICAgc2VsZi5fc2VuZCgyMDAsIGpzb24uZHVtcHMoaGFuZGxlX2FwaShzZWxmLnBhdGgsIGJvZHkp
KSkKICAgICAgICAgICAgZXhjZXB0IEV4Y2VwdGlvbiBhcyBlOgogICAgICAgICAgICAgICAgbG9n
KCJhcGk6IiwgZSk7IHNlbGYuX3NlbmQoNTAwLCBqc29uLmR1bXBzKHsiZXJyb3IiOiBzdHIoZSl9
KSkKICAgICAgICBlbHNlOgogICAgICAgICAgICBzZWxmLl9zZW5kKDQwNCwgInt9IikKCmRlZiBt
YWluKCk6CiAgICBwb3J0ID0gaW50KEMuZ2V0KCJXRUJfUE9SVCIsICI4MDgwIikpCiAgICBsb2co
ZiJnOTBuZXQgV2ViLU9iZXJmbGFlY2hlIGF1ZiBodHRwOi8vMC4wLjAuMDp7cG9ydH0gIChGQUtF
PXtGQUtFfSkiKQogICAgdGhyZWFkaW5nLlRocmVhZCh0YXJnZXQ9c21zX3dlbGNvbWVfd2F0Y2gs
IGRhZW1vbj1UcnVlKS5zdGFydCgpCiAgICB0aHJlYWRpbmcuVGhyZWFkKHRhcmdldD1saW1lX3Nj
YW4sIGRhZW1vbj1UcnVlKS5zdGFydCgpICAgIyBMaW1lU0RSIGZ1ZXIgZGllIEF1c3dhaGwgc3Vj
aGVuCiAgICB0cnk6IF9taWdyYXRlX2x0ZV9kYigpCiAgICBleGNlcHQgRXhjZXB0aW9uIGFzIGU6
IGxvZygibWlncmF0aW9uOiIsIGUpCiAgICBUaHJlYWRpbmdIVFRQU2VydmVyKCgiMC4wLjAuMCIs
IHBvcnQpLCBIYW5kbGVyKS5zZXJ2ZV9mb3JldmVyKCkKCmlmIF9fbmFtZV9fID09ICJfX21haW5f
XyI6CiAgICBtYWluKCkK
