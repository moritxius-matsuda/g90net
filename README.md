# g90net

Steuer-Daemon mit Weboberfläche für ein eigenes **GSM (2G)- und LTE (4G)-Versuchsnetz**
auf Basis von [Osmocom](https://osmocom.org) (2G), [srsRAN](https://www.srsran.com) (4G)
und einem **LimeSDR**. Läuft auf Debian 13 / Raspberry Pi OS, bedient wird alles im Browser.

Dies ist die Software hinter dem portablen Versuchsnetz **pKOM**.

```
http://<IP-des-Rechners>:8080
```

## Funktionen

- **2G (Osmocom)** oder **4G (srsRAN)** per Klick starten/stoppen – ein Daemon steuert alle
  Komponenten (osmo-stp/hlr/mgw/msc/bsc/bts-trx/trx-lms, optional pcu/sgsn/ggsn, sip-connector).
- **Frequenz, Kennung (MCC/MNC), Sendeleistung/Gain** über die Weboberfläche.
- **SIM- und Rufnummernverwaltung** (osmo-hlr), Zuweisungen überleben Neustarts.
- **SIP-Trunk** zu einer Asterisk-Telefonanlage (osmo-sip-connector).
- **SMS** – Willkommensnachricht beim Einbuchen und Bestätigung bei Nummernvergabe.
  Platzhalter in den Texten:
  - `{netz}` – Netzname
  - `{nummer}` – interne Rufnummer
  - `{extern}` – extern erreichbare Nummer (Vorwahl-Block + interne Nummer)
- **Datenverkehr** (EDGE/GPRS bzw. LTE) mit NAT ins Uplink-Netz.
- Reines Python (Standardbibliothek), eine Datei: `g90net.py`.

## Installation

Alles steckt im selbstentpackenden Installer. Auf den Zielrechner kopieren und:

```bash
sudo bash g90net-install.sh          # installieren / aktualisieren
sudo bash g90net-install.sh --off    # Dienst stoppen + abschalten
```

Der Installer zieht die Pakete (Osmocom, srsRAN, LimeSuite), legt Standardkonfigs an,
richtet NAT ein, installiert den Daemon nach `/opt/g90net/g90net.py` und einen
systemd-Dienst `g90net.service`. Danach: `http://<IP>:8080`.

- Einstellungen: `/etc/g90net.conf` (wird auch über die Weboberfläche geschrieben)
- Log: `journalctl -u g90net -f`

## Aus dem Quellcode bauen

Der Installer `g90net-install.sh` ist `install-head.sh` (die Installer-Logik bis zur
Marker-Zeile `__G90NET_PAYLOAD__`) plus den base64-kodierten Daemon `g90net.py`.
Nach einer Änderung an `g90net.py` oder `install-head.sh` neu zusammensetzen:

```bash
./build.sh
```

## ⚠️ Rechtlicher Hinweis

Ein offenes Mobilfunknetz ohne Authentisierung ist **ein IMSI-Catcher, sobald es
abstrahlt**. Deshalb:

- **Nur** an Dummy-Load, über Kabel + Dämpfung oder in einer geschirmten Umgebung betreiben.
- Nur **eigene Test-SIMs** einbuchen.
- Nur **Testkennungen** verwenden (MCC/MNC `001/01` oder `999/99`) – keine echten Betreiberkennungen.
- Abstrahlen nur mit entsprechender Genehmigung / Zuteilung.

Die Verantwortung für den regelkonformen Betrieb liegt vollständig beim Betreiber.
