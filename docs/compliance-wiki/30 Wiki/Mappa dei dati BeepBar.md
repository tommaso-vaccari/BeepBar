# Mappa dei dati BeepBar

Analisi statica: 2026-10-10, dev c9a04dc. [[20 Sources/S-0005 BeepBar codice]]. Aggiornamento telemetria su dev d3a42dc: [[20 Sources/S-0007 BeepBar telemetria]]. Non inventaria tutte le risorse terze delle pagine web.

| Operazione | Dati e destinatario | Conservazione | Evidenza/stato |
|---|---|---|---|
| Login Moodle | Credenziali nel flusso web ateneo; token mobile verso Moodle | WebKit non persistente; credential.token in Application Support/Beepbar | WeBeepAuthenticationController login web; FileTokenStore: `code-backed` |
| Sync | Token, richieste corsi e materiali verso il sito scelto | Cartella materiali; metadati sync.sqlite | WeBeepAPIClient, databaseDirectory: `code-backed`; schema completo da censire |
| Archivio Polimi | Cookie SSO e account ID; richieste ai servizi Polimi | recordings-session.plist; domini polimi.it, cookie scaduti filtrati, quelli senza expiry ammessi | RecmanSessionCodec, RecordingsSessionStore: `code-backed` |
| Preferiti registrazioni | Metadati registrazione, corso, destinazione, account ID | UserDefaults per account; sopravvivono a logout/disattivazione | RecordingsController.studyKey/loadStudy/turnOff: `code-backed` |
| Riproduzione | URL Webex nel browser predefinito | Browser esterno, non controllato da BeepBar | RecmanWebSession: lettura statica; altri destinatari da verificare |
| Aggiornamenti | Appcast/download GitHub e servizi di consegna | Presso fornitore; durata specifica non verificata | Info.plist, UpdaterController; [[20 Sources/S-0003 Sparkle aggiornamenti]], [[20 Sources/S-0004 GitHub privacy]] |
| Telemetria giornaliera | App ID pubblico, hash stabile di UUID installazione + App ID, versione app verso TelemetryDeck; IP visibile al destinatario di rete | UUID e ultimo tentativo in UserDefaults; conservazione fornitore da verificare | DailyTelemetry.swift; default attivo in Release, opt-out nelle impostazioni, massimo un tentativo al giorno: `code-backed` su d3a42dc |
| Log locali | Eventi e contatori nel log unificato macOS | Gestione OS, durata non verificata | BeepbarApp/RecmanWebSession: lettura statica, audit completo aperto |
| Assistenza | Eventuali allegati inviati volontariamente | Canali e processo non censiti | `open-question`; nessun dato acquisito |

`code-backed` — Token/cookie senza cifratura applicativa osservata, creati 0600 in cartelle 0700. Permessi non isolano dal software dello stesso utente. FileVault/backup non verificati: non è una violazione dimostrata.

`source-backed` — Sparkle: YES abilita controlli automatici; profiling default NO. [[20 Sources/S-0003 Sparkle aggiornamenti]]

`code-backed` — Configurazione BeepBar: YES, intervallo 28800 secondi; nessuna attivazione esplicita del profiling nei file ispezionati. README dice “Opt-in” ma descrive anche il default attivo: incoerenza. La precedente assenza di telemetria era limitata a c9a04dc ed è superata da d3a42dc: ora presente integrazione diretta TelemetryDeck senza SDK; verifica runtime aperta.

`inference` — Una richiesta a GitHub espone almeno l'IP al destinatario di rete. La policy generale non dimostra che lo sviluppatore riceva gli IP; ruoli/contratti/trasferimenti non si deducono dal solo URL.

[[30 Wiki/GDPR per applicazioni locali]] · [[30 Wiki/Valutazione BeepBar]] · [[30 Wiki/Piano di verifica]]
