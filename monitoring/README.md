# Überwachung des Portals (`monitoring/`)

Meldet Probleme des Portal-Betriebs (`portal/`, künftig auch die Website) per Mail an `alert@bike-maintainer.de`,
ohne dass jemand nachsehen muss: App oder Website nicht erreichbar, Zertifikat läuft ab, Fehler häufen sich,
Platte oder Speicher voll, Mail-Tageslimit fast erreicht, auffällig viele fehlgeschlagene Logins. Dazu Dashboards
und eine durchsuchbare Ansicht aller Container-Logs. Der Haushaltsmodus wird nicht überwacht.

Entwurf und Entscheidungen: [`docs/specs/2026-11-04-monitoring-design.md`](../docs/specs/2026-11-04-monitoring-design.md).

## Aufbau

| Container | Aufgabe | Speichergrenze |
|---|---|---|
| `bike-maintainer-alloy` | sammelt alles: Logs der Container `bike-maintainer-*` (kürzt IP-Adressen), Host- und Container-Metriken, Backend-Metriken (Port 8081), Erreichbarkeits- und TLS-Checks | 384 MB |
| `bike-maintainer-prometheus` | speichert Metriken (alle 15 s, 30 Tage) | 512 MB |
| `bike-maintainer-loki` | speichert Logs (14 Tage) | 512 MB |
| `bike-maintainer-grafana` | Dashboards, Log-Suche, Alarme per Mail | 384 MB |

Im Normalbetrieb zusammen etwa 500–900 MB. Der Stack läuft unabhängig von `portal/` weiter, auch wenn das Portal
ausfällt. Es werden **keine Ports** veröffentlicht: Grafana ist nur über den nginx-proxy-manager erreichbar,
Prometheus und Loki nur innerhalb des Stacks. Keiner der Dienste meldet Nutzungsdaten nach außen.

Bewusst nicht abgedeckt: ein Totalausfall des ganzen Servers – dann fällt auch die Überwachung aus und es kommt
keine Mail.

## Einrichtung

1. **Netz** (einmalig, gemeinsam mit `portal/`): `docker network create bike-maintainer-monitoring`
2. **Portal** mit dem Stand, der das Backend in dieses Netz hängt, neu starten (`cd portal && docker compose up -d`).
3. **Postfach** `alert@bike-maintainer.de` (oder eine Weiterleitung) bei IONOS anlegen – sonst gehen die Alarme ins
   Leere.
4. **DNS:** `monitoring.bike-maintainer.de` auf den Server zeigen lassen.
5. **`.env`:**

   ```bash
   cd monitoring
   cp .env.example .env    # PROXY_NETWORK, BM_GRAFANA_ADMIN_PASSWORD, BM_SMTP_PASSWORD eintragen
   docker compose up -d
   ```

6. **Proxy-Host** im nginx-proxy-manager: `monitoring.bike-maintainer.de` → `http://bike-maintainer-grafana:3000`,
   SSL mit Let's Encrypt, „Force SSL“ an. Anmeldung in Grafana als `admin` mit `BM_GRAFANA_ADMIN_PASSWORD`.
7. **Prüfen**, dass der Server seine eigenen öffentlichen Adressen erreicht (die Checks laufen bewusst über DNS,
   Proxy und TLS): in Grafana unter *Explore* → Prometheus `probe_success` muss für `app` und `website` `1` sein.
   Falls `0`: `docker exec bike-maintainer-alloy wget -qO- https://app.bike-maintainer.de | head -c 100`.
8. **Speicher** nach ein paar Stunden ansehen: `docker stats --no-stream`.

## Logs und Datenschutz

Alloy liest die Logs aller Container, deren Name mit `bike-maintainer-` beginnt (nicht die der Überwachung
selbst), und speichert sie in Loki – mit den Labels `container`, `level` (`ERROR`, `WARN`, `INFO`, …) und `stream`.
**Bevor** etwas gespeichert wird, kürzt Alloy IP-Adressen: IPv4 auf das letzte Byte genullt (`203.0.113.17` →
`203.0.113.0`), IPv6 auf das /48-Präfix (`2001:db8:abcd:12::1` → `2001:db8:abcd::`). Nach 14 Tagen löscht Loki die
Logs. Das Backend loggt keine E-Mail-Adressen, Tokens oder Passwörter.

Textbaustein für die Datenschutzerklärung:

> Zur Sicherheit und Fehlerbehebung werden Server-Protokolle (Zeitpunkt, aufgerufene Adresse, Statuscode,
> Browserkennung) gespeichert. IP-Adressen werden dabei vor der Speicherung gekürzt (IPv4: letztes Byte, IPv6: auf
> das /48-Präfix), sodass kein Bezug zu einer Person mehr hergestellt werden kann. Die Protokolle werden nach 14 Tagen
> automatisch gelöscht und nicht an Dritte weitergegeben. Rechtsgrundlage ist Art. 6 Abs. 1 lit. f DSGVO.

**Nicht durch diesen Stack abgedeckt:** Der nginx-proxy-manager auf dem Host schreibt eigene Zugriffs-Logs mit
vollen IP-Adressen in sein Daten-Volume. Deren Aufbewahrung dort prüfen und ebenfalls in der Datenschutzerklärung
nennen.

## Lokal ausprobieren (gegen `dev/`)

```bash
cd dev && docker compose up -d && cd ..             # Dev-Stack zuerst
docker network create bike-maintainer-monitoring   # einmalig
cd monitoring
docker compose --env-file .env.dev -f compose.yaml -f compose.dev.yaml up -d
```

Grafana: <http://localhost:8300> (`admin` / `dev-admin-password`), Alarm-Mails landen in Mailpit
(<http://localhost:8026>). `compose.dev.yaml` sammelt die Container `bike-maintainer-dev-*` ein und prüft
Frontend und Website per HTTP im Docker-Netz.
