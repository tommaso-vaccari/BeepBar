# S-0007 — BeepBar telemetria

Origine: codice pubblico integrato in `dev`, commit `50177f3905d50d9fa4252fc952a2fa8bf275de0d` (PR #158). Acquisizione: 2026-10-13. Snapshot corrente: [[10 Raw Sources/S-0007-telemetry-50177f3]]. SHA-256 e dimensione nel manifest. Lo snapshot precedente [[10 Raw Sources/S-0007-telemetry-d3a42dc]] e la sua voce nel manifest restano immutabili.

Evidenza `code-backed`: UUID casuale per mese UTC, rotazione indipendente quando il mese del segnale consentito cambia, cancellazione all'opt-out e rimozione dell'UUID permanente precedente all'avvio. Massimo un tentativo al giorno UTC; dopo un arretramento dell'orologio il primo segnale consentito mantiene l'UUID se il mese coincide con quello salvato. Payload: versione app, piattaforma, macOS principale e lingua con chiavi SDK; sincronizzazione automatica e intervallo, Risparmio dati, Registrazioni e apertura al login con chiavi personalizzate. Valori sconosciuti omessi. Registrazioni attive implica Polimi selezionato (default), non un account autenticato. Default Release attivo in App/Info.plist.

Verifica del candidato `4facd63` integrato senza modifiche funzionali: revisione indipendente pulita, 525 test e build Release verdi; regressione del recupero dell'orologio rilevata da mutazione controllata dell'identità mensile. Nessun segnale di produzione o verifica con account reale eseguito in questa consegna. La CI post-merge è documentata nella PR.

L'IP e la combinazione dei campi possono permettere al destinatario di ricollegare mesi diversi. C08 resta aperto: base giuridica del default attivo e trattamento del fornitore da verificare prima della release. Nessuna conclusione di anonimato o conformità.

[[30 Wiki/Mappa dei dati BeepBar]] · [[30 Wiki/Valutazione BeepBar]]
