# Valutazione BeepBar

2026-10-10. Base della prima indagine: `c9a04dc2f510fb02d0662f1c66ce0c53f54e5296`. Main locale: `3ce0ba02c10dcf51836057f7119ba0e78da3c6e4`. Remoti live/binario distribuito non verificati. Solo documentazione, nessun fix. Allineamento successivo a dev `d3a42dc775ef461f5406c85818a1e1e0f57ad6dc`: aggiunta telemetria, evidenza [[20 Sources/S-0007 BeepBar telemetria]].

**Conformità non dimostrata; nessuna conclusione di violazione dalla sola analisi statica.** [[20 Sources/S-0001 GDPR]], [[20 Sources/S-0002 EDPB ruoli]], [[20 Sources/S-0005 BeepBar codice]].

| ID | Evidenza | Valutazione e chiusura richiesta |
|---|---|---|
| C01 | Informativa dedicata non trovata nel repository | `code-backed` assenza delimitata; definire ruoli e applicabilità art. 13 |
| C02 | Token/sessioni locali, 0600/0700 | `code-backed` misura positiva; valutare rischi, log, backup, errori |
| C03 | signOut rimuove token, invoca turnOff, conserva sync.sqlite e materiali | `code-backed`; documentare residui e rimozione preservando lavoro locale |
| C04 | Aggiornamenti automatici ogni otto ore, README anche “Opt-in” | `code-backed` incoerenza; allineare descrizione, verificare payload e base |
| C05 | Cookie Polimi senza expiry persistiti | `code-backed`; motivare durata e provare cancellazione/failure path |
| C06 | Preferiti per account restano dopo logout | `code-backed`; conservazione distinta dalla sessione, documentare e verificare rimozione |
| C07 | Log con campi pubblici; URL Recman ridotti a host/path | `code-backed` parziale; audit di campi/errori e diagnostica |
| C08 | TelemetryDeck diretto, default attivo in Release, identità persistente hashata e versione app | `code-backed` su dev d3a42dc; verificare informativa, ruoli/contratti, conservazione, trasferimenti e base GDPR/ePrivacy prima della release; hash non prova anonimato |
| C09 | Processi assistenza/incidenti/diritti non censiti | `open-question`; documentare obblighi proporzionati ai ruoli |

## Limiti e correzioni

Non trovare l'informativa nel repo non dimostra assenza ovunque; sito pubblico non validato. Default automatico degli update non prova obbligo di consenso. File non cifrato non è automaticamente illecito. Logout non deve cancellare materiali/preferiti implicitamente. Produttore locale non è automaticamente titolare di tutti i dati universitari.

Eseguiti: lettura statica, ricerca connessioni/privacy, confronto nomi dei file main→dev, acquisizione fonti pubbliche con hash. Non eseguiti: test app, build, account reali, rete live, accesso a DB utente o assistenza.

Su dev differiscono da main RecordingsController, RecordingsStudyState, WeBeepAuthenticationController: non attribuire i finding alla release senza confronto mirato. API issue GitHub non raggiungibile durante l'indagine; nessuna assegnazione o aggiornamento remoto. [[30 Wiki/Piano di verifica]]
