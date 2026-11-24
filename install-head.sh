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
