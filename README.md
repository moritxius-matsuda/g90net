# g90net

Steuer-Daemon mit Weboberfläche für ein eigenes **GSM (2G)- und LTE (4G)-Versuchsnetz**
auf Basis von [Osmocom](https://osmocom.org) (2G), [srsRAN](https://www.srsran.com) +
[Open5GS](https://open5gs.org) (4G) und **LimeSDR**. Läuft auf Debian 13, bedient wird alles im Browser.

Dies ist die Software hinter dem portablen Versuchsnetz **pKOM**.

```
http://<IP-des-Rechners>:8080
```

## Funktionen

- Drei Betriebsarten per Klick:
  - **GSM (2G)** – Osmocom (osmo-stp/hlr/mgw/msc/bsc/bts-trx/trx-lms, optional pcu/sgsn/ggsn, sip-connector)
  - **LTE (4G)** – srsENB als Funk, Open5GS als Kern (MME/HSS/PCRF/SGW/SMF/UPF), Internet per NAT
  - **LTE + GSM (CSFB)** – beide Netze gleichzeitig auf **zwei LimeSDR**. Das Handy bucht
    sich kombiniert in 4G ein (Internet), Anrufe fallen über die **SGs-Schnittstelle**
    (Open5GS-MME ↔ osmo-msc) kurz auf GSM zurück und laufen über den SIP-Trunk.
    SMS gehen direkt über SGs. srsENB leitet per SIB7/RRC-Release auf die GSM-Frequenz um.
- **LimeSDR-Auswahl je Netz** im Webinterface (z. B. LimeSDR Mini für GSM, LimeSDR USB für LTE).
- **SIMs nur einmal eintragen** – pKOM schreibt sie automatisch ins osmo-hlr (GSM) und in
  den Open5GS-HSS (LTE, MongoDB). Ki/OPc bleiben auf dem Rechner.
- **Netzkennung** (nur Test-MCC 001 oder Privat-MCC 999), Netzname lang/kurz, Anbietername.
- **NITZ** – Netzname, Uhrzeit und Zeitzone ans Handy (GSM: MM-Information, LTE: EMM-Information).
- **SIM-Profil** – fertige Hex-Werte für **SPN**, **PNN** und **OPL** zum Eintragen ins eSIM-Profil.
- **Bandauswahl** – GSM 850/900/E-900/1800/1900 und 14 LTE-FDD-Bänder (1, 2, 3, 4, 5, 7, 8, 12, 13, 17, 20, 25, 26, 28) mit Down-/Uplink-Anzeige und Prüfung, ob der Kanal ins Band passt.
- **Neustarten einzelner Teile** – GSM, 4G komplett, nur der 4G-Funk (eNB) oder einzelne Prozesse (z. B. msc, mme), ohne das Netz anzuhalten.
- **Anrufliste und Einzelverbindungsnachweis** – alle Gespräche über GSM (auch CSFB aus LTE) mit Von/An, Richtung, Status und Dauer; Filter nach SIM und Monat, EVN als CSV, Zielnummern auf Wunsch gekürzt.
- **4G-Datenlast mit Historie** – Download/Upload und CPU als Kurve über 10 Minuten, 24 Stunden und 7 Tage, dazu Datenvolumen pro Tag.
- **SIM-Daten erzeugen** – IMSI (passend zu MCC/MNC), Ki, OP und OPc (Milenage), ICCID mit Luhn-Prüfziffer, PIN/PUK/ADM1; mit einem Klick in pKOM übernehmen oder als CSV/JSON speichern.
- **SIP-Trunk** zu einer Asterisk-Telefonanlage (osmo-sip-connector).
- **SMS** – Willkommensnachricht beim Einbuchen und Bestätigung bei Nummernvergabe.
  Platzhalter in den Texten:
  - `{netz}` – Netzname
  - `{nummer}` – interne Rufnummer
  - `{extern}` – extern erreichbare Nummer (Vorwahl-Block + interne Nummer)
- Eine Python-Datei: `g90net.py` (Standardbibliothek + python3-yaml/python3-pymongo für LTE).

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
