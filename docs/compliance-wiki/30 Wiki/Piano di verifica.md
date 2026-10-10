# Piano di verifica

Aperto, 2026-10-10. Base/limiti in [[30 Wiki/Valutazione BeepBar]]. Questo piano non autorizza modifiche funzionali.

1. **Ruoli.** Per ogni flusso identificare finalità/mezzi, destinatari e accesso effettivo. Distinguere software locale, atenei, distribuzione e assistenza. Chiusura: matrice motivata, basi applicabili e questioni residue.
2. **Inventario.** Censire SQLite, preferenze, sessioni, log, cache, notifiche, clipboard e temporanei; confrontare dev/main. Solo fixture sintetiche. Chiusura: dati, destinatari, durata e rimozione per archivio.
3. **Rete/SDK.** Fissare versione Sparkle risolta, richieste updater e risorse webview; includere TelemetryDeck (default attivo, identificatore persistente, opt-out, informativa, base GDPR/ePrivacy, contratti, conservazione e trasferimenti); verificare policy atenei/Webex e regime ePrivacy. Chiusura: destinatari/payload, distinguendo osservazioni da inferenze.
4. **Conservazione.** Verificare logout, disattivazione, cambio account, riavvio, cancellazione fallita e scritture tardive; includere preferiti. Chiusura: sessioni rimosse come dichiarato, residui espliciti, nessuna perdita di materiali. Eventuale pulsante di cancellazione richiede decisione separata.
5. **Documenti/processi.** Preparare informativa secondo i ruoli, istruzioni di rimozione, assistenza e incidenti; valutare registro, contratti, DPIA/DPO e trasferimenti ove applicabili. Chiusura: documenti coerenti con comportamento verificato.
6. **Release (prima della prossima release).** Completare la passata finale GDPR prima di integrare dev in main. L’integrazione della wiki in dev non chiude la verifica di conformità. Riesaminare SHA/binario destinato agli utenti e i punti giuridici controversi. Chiusura: nessun claim “full compliant” con lacune aperte. Nessuna release o modifica del sito implicita.

Prima di implementare/coordinare recuperare issue e dipendenze secondo AGENTS.md. [[30 Wiki/Mappa dei dati BeepBar]] · [[30 Wiki/GDPR per applicazioni locali]] · [[PROTOCOL]]
