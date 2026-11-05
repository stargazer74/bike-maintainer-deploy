# Überwachung des Portals (`monitoring/`)

Meldet Probleme des Portal-Betriebs (`portal/`, künftig auch die Website) per Mail an `BM_ALERT_EMAIL`,
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
| `bike-maintainer-docker-proxy` | einziger Zugang zum Docker-Socket, nur lesend (siehe unten) | 64 MB |

Im Normalbetrieb zusammen etwa 500–900 MB. Der Stack läuft unabhängig von `portal/` weiter, auch wenn das Portal
ausfällt. Es werden **keine Ports** veröffentlicht: Grafana ist nur über den nginx-proxy-manager erreichbar,
Prometheus und Loki nur innerhalb des Stacks. Keiner der Dienste meldet Nutzungsdaten nach außen.

Bewusst nicht abgedeckt: ein Totalausfall des ganzen Servers – dann fällt auch die Überwachung aus und es kommt
keine Mail.

## Einrichtung

1. **Netz** (einmalig, gemeinsam mit `portal/`): `docker network create bike-maintainer-monitoring`
2. **Portal** mit dem Stand, der das Backend in dieses Netz hängt, neu starten (`cd portal && docker compose up -d`).
3. **Postfach** für die Alarme (`BM_ALERT_EMAIL`, oder eine Weiterleitung) beim Mailanbieter anlegen – sonst gehen
   die Alarme ins Leere.
4. **DNS:** die Adresse für Grafana (z. B. `monitoring.example.com`) auf den Server zeigen lassen.
5. **`.env`:**

   ```bash
   cd monitoring
   cp .env.example .env    # alle Werte ohne Standard eintragen (siehe Kommentare)
   docker compose up -d
   ```

6. **Proxy-Host** im nginx-proxy-manager: Adresse aus `BM_GRAFANA_URL` → `http://bike-maintainer-grafana:3000`,
   SSL mit Let's Encrypt, „Force SSL“ an. Anmeldung in Grafana als `admin` mit `BM_GRAFANA_ADMIN_PASSWORD`.
7. **Prüfen**, dass der Server seine eigenen öffentlichen Adressen erreicht (die Checks laufen bewusst über DNS,
   Proxy und TLS): in Grafana unter *Explore* → Prometheus `probe_success` muss für `app` und `website` `1` sein.
   Falls `0`: `docker exec bike-maintainer-alloy sh -c 'wget -qO- "$BM_PROBE_APP_URL"' | head -c 100`.
8. **Speicher** nach ein paar Stunden ansehen: `docker stats --no-stream`.

## Alarme

Alle Alarme gehen per Mail an `BM_ALERT_EMAIL`, Absender ist das SMTP-Postfach
(`BM_SMTP_USER`). Eine Mail pro Regel, solange das Problem besteht alle 4 Stunden eine
Erinnerung, danach eine Entwarnung (`[RESOLVED]`). Regeln, Empfänger und Richtlinie liegen als Dateien in
`grafana/provisioning/alerting/` – Änderungen über Git, nicht in der Oberfläche. Startwerte:

| Regel | Alarm, wenn … |
|---|---|
| App oder Website nicht erreichbar | Check über Proxy und TLS schlägt > 2 min fehl |
| Zertifikat läuft bald ab | Zertifikat von App oder Website läuft in < 14 Tagen ab |
| Backend-Metriken fehlen | Backend liefert > 3 min keine Metriken |
| 5xx-Quote hoch | > 5 % Serverfehler über 5 min (bei mindestens 20 Anfragen) |
| ERROR-Logs gehäuft | > 10 ERROR-Zeilen eines Containers in 5 min |
| Viele fehlgeschlagene Logins | > 30 in 15 min |
| Viele Rate-Limit-Treffer | > 50 in 15 min |
| Mail-Zustellung fehlgeschlagen | ≥ 3 nicht zugestellte Mails in 15 min |
| Mail-Tageslimit fast erreicht | ≥ 80 % des Tageslimits verbraucht |
| Platte fast voll | Root-Dateisystem > 85 % belegt (10 min) |
| Wenig Arbeitsspeicher | < 10 % verfügbar (10 min) |
| Container startet neu | ein Portal-Container > 2 Neustarts in 15 min |
| Portal-Container fehlt | Backend, Frontend, Datenbank oder Website seit > 2 min nicht gesehen |
| Keine Daten von Alloy | > 5 min keine Daten vom Sammler – die Überwachung ist blind |

**Testalarm** nach der Einrichtung:

1. Grafana → *Alerting* → *Contact points* → `email` → *Test*: Testmail kommt an `BM_ALERT_EMAIL` an.
2. `docker stop bike-maintainer-frontend` → nach etwa 3 Minuten Mail „App oder Website nicht erreichbar“;
   `docker start bike-maintainer-frontend` → einige Minuten später die Entwarnung.

## Dashboards

Im Grafana-Ordner **Portal** (Dateien in `grafana/dashboards/`, Änderungen über Git):

- **Portal-Überblick:** Erreichbarkeit, Restlaufzeit der Zertifikate, Anfragen und Fehlerquote, Antwortzeiten
  (p50/p95), CPU, Arbeitsspeicher und Platte des Servers, Speicher pro Container.
- **Backend:** JVM-Heap, Datenbank-Verbindungen, Anmeldungen, Schutzmechanismen (Rate-Limit, ALTCHA, Kontosperren),
  Registrierungen und Passwort-Zurücksetzen, Mails und Tageslimit, PDF-Erzeugung. Bedeutung der Metriken:
  `docs/metrics.md` im Backend-Repo.
- **Logs:** ERROR-Zeilen pro Container, Logs mit Filter nach Container und Level und einem Suchfeld.

Neu entstandene Zähler zeigen ihr allererstes Ereignis nicht (Prometheus braucht zwei Messpunkte für `increase`).

## Logs und Datenschutz

Alloy liest die Logs aller Container, deren Name mit `bike-maintainer-` beginnt (nicht die der Überwachung
selbst), und speichert sie in Loki – mit den Labels `container`, `level` (`ERROR`, `WARN`, `INFO`, …) und `stream`.
**Bevor** etwas gespeichert wird, kürzt Alloy IP-Adressen: IPv4 auf das letzte Byte genullt (`203.0.113.17` →
`203.0.113.0`), IPv6 auf das /48-Präfix (`2001:db8:abcd:12::1` → `2001:db8:abcd::`). Nach 14 Tagen löscht Loki die
Logs. Außerdem schwärzt Alloy Parameter `token=`, `key=` und `code=` in URLs (die Links aus den Konto-Mails stehen
sonst im Zugriffs-Log des Frontends) und den Teil vor dem `@` von E-Mail-Adressen (`***@example.org`). Das Backend
loggt selbst keine E-Mail-Adressen, Tokens oder Passwörter.

Textbaustein für die Datenschutzerklärung:

> Zur Sicherheit und Fehlerbehebung werden Server-Protokolle (Zeitpunkt, aufgerufene Adresse, Statuscode,
> Browserkennung) gespeichert. IP-Adressen werden dabei vor der Speicherung gekürzt (IPv4: letztes Byte, IPv6: auf
> das /48-Präfix), sodass kein Bezug zu einer Person mehr hergestellt werden kann. Die Protokolle werden nach 14 Tagen
> automatisch gelöscht und nicht an Dritte weitergegeben. Rechtsgrundlage ist Art. 6 Abs. 1 lit. f DSGVO.

**Nicht durch diesen Stack abgedeckt:** Der nginx-proxy-manager auf dem Host schreibt eigene Zugriffs-Logs mit
vollen IP-Adressen in sein Daten-Volume. Deren Aufbewahrung dort prüfen und ebenfalls in der Datenschutzerklärung
nennen.

## Rechte von Alloy

Den Docker-Socket hat nur `bike-maintainer-docker-proxy`
([tecnativa/docker-socket-proxy](https://github.com/Tecnativa/docker-socket-proxy)). Er lässt ausschließlich
lesende Abfragen zu Containern, Netzwerken, Info und Version durch; alles, was etwas verändert (Container starten,
`exec`, Images, Volumes, …), beantwortet er mit 403. Alloy spricht die Docker-API nur über ihn an – ein übernommenes
Alloy kann also keine Container auf dem Host starten.

Alloy selbst läuft weiterhin als root, weil cAdvisor `/var/lib/docker` lesen muss, und bekommt `/`, `/proc`, `/sys`
und `/var/lib/docker` des Hosts nur lesend eingehängt (Host-Metriken wie der Plattenplatz). Lesen kann es damit
weiterhin alle Dateien des Hosts; Alloy hat aber keinen Port nach außen und läuft aus dem offiziellen Image.

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
