#!/usr/bin/env bash
# =====================================================================
#  g90net - Installer fuer ein eigenes GSM(2G)- und LTE(4G)-Versuchsnetz
#  mit Weboberflaeche. Fuer Debian 13 (Server) oder Raspberry Pi OS / Pi.
#
#  Installiert Osmocom (2G), srsRAN (4G), LimeSuite und den Steuer-Daemon
#  g90net inkl. Weboberflaeche. Bedienung danach im Browser:
#      http://<IP-des-Rechners>:8080
#
#  Aufruf:
#      sudo bash g90net-install.sh           installieren
#      sudo bash g90net-install.sh --off      Dienst stoppen + abschalten
#
#  !!!  NUR an Dummy Load / Kabel + Daempfung / geschirmt. Offenes Netz ohne
#       Authentisierung = IMSI-Catcher, wenn es abstrahlt. Nur eigene
#       Test-SIMs. Testkennung 001/01 oder 999/99 - keine echten Betreiber.
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

info "srsRAN (4G) installieren"
apt-get install -y -qq srsran 2>/dev/null || apt-get install -y -qq srslte 2>/dev/null || true
have_srs || warn "srsRAN (srsenb/srsepc) nicht gefunden - 4G erst nach Nachinstallation. Auf Debian 13: 'apt install srsran'."

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
DEV_ARGS="driver=lime"
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
EOF
fi

# ---- systemd-Dienst --------------------------------------------------
info "systemd-Dienst g90net anlegen"
cat > "$UNIT" <<EOF
[Unit]
Description=g90net - GSM/LTE-Versuchsnetz mit Weboberflaeche
After=network.target

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

  Bedienung komplett im Browser: GSM (2G) oder LTE (4G) starten,
  Frequenz/Kennung/Gain einstellen, SIMs verwalten.

  WICHTIG: Nur an Dummy Load / Kabel + Daempfung / geschirmt betreiben.
  Nur eigene Test-SIMs. Testkennung 001/01 oder 999/99.
  Hinweis Raspberry Pi 3: nur USB 2.0 - LimeSDR USB braucht USB 3.0 +
  Strom; fuer 4G ist der Pi 3 sehr knapp (kleine PRB-Bandbreite waehlen).
=====================================================================
EOF
exit 0
__G90NET_PAYLOAD__
