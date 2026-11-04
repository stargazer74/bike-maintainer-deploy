# Überwachung des Portal-Betriebs – Design

Stand: 2026-11-04 · Tickets: stargazer74/bike-maintainer-deploy#9 (Stack), stargazer74/bike-maintainer-backend#71
(Anwendungsmetriken)

## Ziel

Ausfälle und Probleme des Portals früh bemerken, ohne aktiv nachzusehen: App oder Website nicht erreichbar, Fehler
häufen sich, auffällige Log-Meldungen, Platte oder Speicher voll, Zertifikat läuft ab, Mail-Tageslimit fast erreicht,
Angriffe auf Logins.

**Erfolg:** Bei jedem der genannten Probleme kommt innerhalb weniger Minuten eine Mail an `alert@bike-maintainer.de`;
nach der Behebung eine Entwarnung. Logs aller Portal-Container sind in Grafana durchsuch- und filterbar.

## Abgrenzung

- **Nur der Portal-Betrieb** (`portal/`): App (Backend, Frontend, MariaDB), Website (WordPress, sobald
  stargazer74/bike-maintainer-deploy#7 umgesetzt ist) und der Host. Der Haushaltsmodus (`household/`) wird nicht
  überwacht und bekommt nichts davon.
- **Alles läuft auf dem Portal-Server.** Ein Totalausfall des Servers (oder des Monitoring-Stacks selbst) wird nicht
  gemeldet – bewusst in Kauf genommen; ein Check von außen kann später ergänzt werden.
- **Nicht enthalten:** eigene MariaDB-Metriken (eigener DB-Nutzer nötig; Plattenplatz kommt vom Host, Pool-Zustand vom
  Backend), Alertmanager (Grafana alarmiert selbst), Bestandsmetriken (Nutzer, Fahrzeuge, Aufgaben) und
  Haushaltsmetriken (Profilauswahl) – siehe „Später“.

## Rahmenbedingungen

- Server: 7,76 GiB RAM, bestehende Container zusammen ca. 2 GiB. Der Stack bekommt feste Speichergrenzen
  (Summe ca. 1,7 GB), erwarteter Normalbetrieb 600–900 MB.
- Nur OSI-Open-Source, keine Dritten (Privacy first). Werkzeuge: Prometheus (Apache 2.0), Loki (AGPLv3),
  Alloy (Apache 2.0), Grafana (AGPLv3). Graylog bewusst nicht (SSPL, schwer).
- Deploy-Repo ist pull-only: offizielle Images, Konfiguration per Bind-Mount, kein `build:`.

## Architektur

Neues Verzeichnis `monitoring/` im Deploy-Repo mit eigener `compose.yaml`, `.env.example` und Konfiguration. Eigener
Lebenszyklus: Wird das Portal neu gestartet oder fällt es aus, läuft die Überwachung weiter und meldet das.

| Container | Aufgabe | Speichergrenze |
|---|---|---|
| `bike-maintainer-alloy` | Sammelt alles: Logs der Container `bike-maintainer-*` (Docker-Socket, nur lesend), Host-Metriken (eingebauter Unix-Exporter, `/proc`, `/sys`, `/` nur lesend), Container-Metriken (eingebauter cAdvisor), Backend-Metriken (`bike-maintainer-backend:8081/actuator/prometheus`), Erreichbarkeits- und TLS-Checks (eingebauter Blackbox-Exporter) auf `https://app.bike-maintainer.de` und `https://bike-maintainer.de`. Kürzt IPs in Logs vor dem Versand. Schickt Metriken per Remote-Write an Prometheus, Logs an Loki. | 384 MB |
| `bike-maintainer-prometheus` | Speichert Metriken (Remote-Write-Empfänger), Intervall 15 s, Aufbewahrung 30 Tage | 512 MB |
| `bike-maintainer-loki` | Speichert Logs, Single-Binary, Dateisystem, Aufbewahrung 14 Tage (Compactor löscht) | 512 MB |
| `bike-maintainer-grafana` | Dashboards, Log-Suche, Alarme per Mail | 256 MB |

Alle Images mit fester Version (Major.Minor gepinnt), Daten in benannten Volumes.

### Netze

- **`bike-maintainer-monitoring`** (extern, einmalig per `docker network create bike-maintainer-monitoring`): Alloy
  und – aus `portal/` – das Backend. Nur so erreicht Alloy den Management-Port 8081. Beide Stacks deklarieren das Netz
  als `external`, keiner hängt vom Start des anderen ab.
- **Proxy-Netz** (`PROXY_NETWORK`, wie in `portal/`): nur Grafana; der nginx-proxy-manager leitet
  `monitoring.bike-maintainer.de` mit TLS auf `bike-maintainer-grafana:3000`.
- **Internes Netz** des Monitoring-Stacks: Prometheus und Loki, nur dort erreichbar.
- Die Erreichbarkeits-Checks gehen bewusst über die öffentlichen Adressen (DNS, nginx-proxy-manager, TLS), damit
  Proxy und Zertifikat mitgeprüft werden. Voraussetzung: Der Server erreicht seine eigene öffentliche Adresse (bei
  Root-Servern üblich; bei der Einrichtung mit `curl -I https://app.bike-maintainer.de` aus dem Alloy-Container
  prüfen).
- Es werden **keine Ports** auf dem Host veröffentlicht. Port 8081 ist container-intern (`management.server.port`)
  und nicht über den Proxy erreichbar.

### Änderungen in `portal/compose.yaml`

- Healthchecks: Backend (`/actuator/health` auf 8081), Frontend (nginx antwortet auf `/`).
- `depends_on` mit `condition: service_healthy` (Frontend wartet auf Backend).
- Backend zusätzlich im Netz `bike-maintainer-monitoring`.
- Backend loggt als JSON: `LOGGING_STRUCTURED_FORMAT_CONSOLE=ecs`.

## Logs

- Alloy liest die Logs aller laufenden Container, deren Name mit `bike-maintainer-` beginnt (damit auch die Website,
  sobald sie im Portal läuft). Labels: `container`, `level` (aus JSON bzw. per Muster), `stream`.
- **IP-Kürzung vor dem Speichern** (Alloy, `loki.process`/`stage.replace`): IPv4 auf das letzte Byte genullt
  (`203.0.113.17` → `203.0.113.0`), IPv6 auf /48 (`2001:db8:abcd:12::1` → `2001:db8:abcd::`). Gilt für alle
  Container. Rate-Limit und Kontosperre im Backend arbeiten unverändert mit vollen IPs im Speicher.
- Aufbewahrung **14 Tage**, danach löscht der Loki-Compactor.
- Datenschutzerklärung: Hinweis auf Server-Logs mit gekürzten IPs, 14 Tage (README nennt den Textbaustein).

## Backend (backend#71)

### Metriken

- `micrometer-registry-prometheus`; `/actuator/prometheus` nur auf dem Management-Port 8081
  (`management.endpoints.web.exposure.include=health,prometheus`).
- Gemeinsame Tags: `application=bike-maintainer`, `mode=portal|household`.
- Standardmetriken: `http.server.requests` mit Histogramm (Perzentile p50/p95), JVM, HikariCP, Tomcat, Prozess/Uptime.
- Fachliche Metriken, Präfix `bm.`, gezählt in den Components (ArchUnit), nur Tags mit wenigen festen Werten (keine
  IDs, E-Mails, Namen, freien Pfade):

| Metrik | Art | Tags |
|---|---|---|
| `bm.auth.login` | Counter | `result=success\|bad_credentials\|locked\|disabled\|unverified` |
| `bm.auth.lockout` | Counter | – |
| `bm.auth.registration` | Counter | `step=started\|verified` |
| `bm.auth.password_reset` | Counter | `step=requested\|completed` |
| `bm.protection.altcha_failed` | Counter | – |
| `bm.protection.rate_limited` | Counter | `group` (feste Endpunktgruppen, z. B. `login`, `registration`, `password_reset`) |
| `bm.mail.sent` | Counter | `type` (Mail-Art), `result=success\|failure` |
| `bm.mail.quota.used`, `bm.mail.quota.limit` | Gauge | – |
| `bm.report.generated` | Timer | `type=report\|checklist`, `result=success\|failure` |

Die genauen Werte von `result`, `group` und `type` richten sich nach den im Code vorhandenen Fällen; sie werden in
`docs/metrics.md` festgehalten.

### Strukturierte Logs

- Spring-Boot-eigenes Structured Logging, Format ECS, nur im Portal per Umgebungsvariable eingeschaltet; Haushalt
  und lokale Entwicklung behalten Textlogs.
- Ein Request-Filter legt `http.method` und das **Pfad-Muster** (`/api/v1/vehicles/{vehicleId}`, nie die konkrete URL,
  keine Query-Parameter) in den MDC und räumt ihn nach der Anfrage wieder ab.
- Bestehende Log-Ausgaben werden durchgesehen: keine E-Mail-Adressen (Mail-Logs maskieren bereits), Tokens,
  Passwörter oder freien Nutzereingaben.

### Tests

- Unit-Tests mit `SimpleMeterRegistry`: jeder Zähler steigt beim zugehörigen Vorgang.
- `/actuator/prometheus` antwortet auf 8081 und ist auf 8080 nicht erreichbar.
- Filter: Pfad-Muster im MDC während der Anfrage, danach leer.
- `./mvnw verify` grün inkl. Coverage-Gate.

### Doku

`docs/metrics.md`: alle `bm.`-Metriken mit Bedeutung, Tags und Werten.

## Alarme

Grafana-managed Alerts, provisioniert aus `monitoring/grafana/provisioning/` (Datenquellen, Kontaktpunkt,
Benachrichtigungsrichtlinie, Regeln, Dashboards) – Änderungen nur über Git.

- **Mail:** SMTP IONOS (`smtp.ionos.de:587`, STARTTLS) als `noreply@bike-maintainer.de`, Passwort aus `.env`.
  Empfänger `BM_ALERT_EMAIL`, Standard `alert@bike-maintainer.de` (Postfach oder Weiterleitung muss bei IONOS
  existieren).
- **Richtlinie:** Gruppierung nach Regel, Wiederholung nach 4 h, Entwarnung bei Behebung.
- **Regeln (Startwerte):**

| Bereich | Alarm, wenn … |
|---|---|
| Erreichbarkeit | App oder Website > 2 min nicht erreichbar (Blackbox über den Proxy, HTTPS) |
| TLS | Zertifikat von App oder Website läuft in < 14 Tagen ab |
| Backend | Backend-Metriken fehlen > 3 min · 5xx-Quote > 5 % über 5 min bei ≥ 20 Anfragen |
| Logs | > 10 ERROR-Zeilen eines Containers in 5 min |
| Sicherheit | > 30 fehlgeschlagene Logins in 15 min · > 50 Rate-Limit-Treffer in 15 min |
| Mail | ≥ 3 fehlgeschlagene Mails in 15 min · Tageslimit ≥ 80 % |
| Host | Root-Dateisystem > 85 % belegt · verfügbarer RAM < 10 % über 10 min |
| Container | Portal-Container > 2 Neustarts in 15 min oder fehlt |
| Selbstüberwachung | Keine Daten von Alloy > 5 min |

## Dashboards

Als JSON provisioniert:

1. **Portal-Überblick:** Erreichbarkeit, Zertifikatsablauf, Anfragen/Fehlerquote, Antwortzeiten p50/p95, Host
   (CPU, RAM, Platte), Speicher pro Container.
2. **Backend:** JVM, Verbindungspool, Logins und Schutz, Mails und Tageslimit, Berichte.
3. **Logs:** Filter nach Container und Level, Volltextsuche.

## Zugriff und Sicherheit

- Grafana nur über `https://monitoring.bike-maintainer.de` (nginx-proxy-manager, TLS); Admin-Passwort aus `.env`
  (Pflicht), keine Selbstregistrierung, kein anonymer Zugriff, keine Telemetrie/Update-Checks nach außen
  (`GF_ANALYTICS_*` aus), keine Gravatar-Bilder.
- Prometheus, Loki und Port 8081 nur in internen Netzen.
- Docker-Socket und Host-Pfade nur lesend in Alloy.

## Lokaler Test

Override-Datei `monitoring/compose.dev.yaml`: Container-Muster `bike-maintainer-dev-*`, Checks auf
`http://bike-maintainer-dev-frontend` und `http://bike-maintainer-dev-website`, Mail an Mailpit des Dev-Stacks,
Grafana auf `127.0.0.1`-Port. Nachzuweisen im Dev-Stack: Dashboards mit Daten, Log-Suche mit gekürzten IPs, ein
ausgelöster Alarm (Frontend gestoppt) samt Mail und Entwarnung in Mailpit.

## Umsetzung

Gleicher Branch-Name `feature/monitoring` in backend und deploy; je ein PR.

1. **Backend (backend#71):** Metriken, JSON-Logs, MDC-Filter, Tests, `docs/metrics.md`. Wirksam ab dem nächsten
   Backend-Release.
2. **Deploy – Portal:** Healthchecks, Monitoring-Netz, JSON-Logs; README (Netz einmalig anlegen).
3. **Deploy – `monitoring/`:** Compose, Alloy-, Prometheus-, Loki-Konfiguration, Grafana-Provisioning, Dev-Override;
   README: Einrichtung, Proxy-Host und DNS für `monitoring.`, Postfach `alert@`, Testalarm, Datenschutz-Hinweis.

Tickets: deploy#9 wird um diese Entscheidungen ergänzt; Unter-Tickets für Schritt 2 und 3; backend#71 bekommt die
strukturierten Logs und die zurückgestellten Metriken als „später“.

## Später

- Bestandsmetriken (Nutzer aktiv/unbestätigt, Fahrzeuge, Aufgaben nach Status) als gecachte Gauges.
- Haushaltsmetriken (Profilauswahl).
- Check von außen (Totalausfall des Servers).
- Loki durch VictoriaLogs ersetzen, falls der Speicher knapp wird.
