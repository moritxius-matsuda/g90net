#!/usr/bin/env bash
# Baut den selbstentpackenden Installer:
#   g90net-install.sh = install-head.sh (bis zur Marker-Zeile) + base64(g90net.py)
# Auf dem Zielrechner entpackt sich der Installer wieder selbst.
set -eu
cd "$(dirname "$0")"

MARK=__G90NET_PAYLOAD__
python3 -c "import py_compile; py_compile.compile('g90net.py', doraise=True)"

{
  sed "/^${MARK}\$/q" install-head.sh   # Installer-Logik bis einschliesslich Marker
  base64 g90net.py                       # danach der kodierte Daemon
} > g90net-install.sh

echo "g90net-install.sh neu gebaut ($(wc -c < g90net-install.sh) Bytes)"
