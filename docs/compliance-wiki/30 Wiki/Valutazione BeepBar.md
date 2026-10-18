# Valutazione BeepBar

2026-10-10. Base della prima indagine: `c9a04dc2f510fb02d0662f1c66ce0c53f54e5296`. Main locale: `3ce0ba02c10dcf51836057f7119ba0e78da3c6e4`. Remoti live/binario distribuito non verificati. Solo documentazione, nessun fix. Allineamento successivo a dev `d3a42dc775ef461f5406c85818a1e1e0f57ad6dc`: aggiunta telemetria, evidenza [[20 Sources/S-0007 BeepBar telemetria]].

**Conformità non dimostrata; nessuna conclusione di violazione dalla sola analisi statica.** [[20 Sources/S-0001 GDPR]], [[20 Sources/S-0002 EDPB ruoli]], [[20 Sources/S-0005 BeepBar codice]].

| ID | Evidenza | Valutazione e chiusura richiesta |
|---|---|---|
| C01 | Informativa dedicata non trovata nel repository | `code-backed` assenza delimitata; definire ruoli e applicabilità art. 13 |
| C02 | Token/sessioni locali, 0600/0700 | `code-backed` misura positiva; valutare rischi, log, backup, errori |
| C03 | signOut rimuove token, invoca turnOff, conserva sync.sqlite e materiali | `code-backed`; documentare residui e rimozione preservando lavoro locale |
| C04 | Aggiornamenti automatici ogni otto ore, README anche “Opt-in” | `code-backed` incoerenza; allineare descrizione, verificare payload e base |
| C05 | Cookie Polimi senza expiry persistiti; con la riproduzione nativa (#148, PR #152, non rilasciata) lo stesso file conserva anche cookie di sessione Webex e l'email Polimi (dato personale), tutti cancellati con il file. Dal 2026-10-11 l'email è presa dal profilo WeBeep e usata senza un passo di conferma esplicito (decisione del responsabile): l'utente la vede, la cambia o la rimuove in Impostazioni, ma non c'è più un'azione che ne autorizzi l'uso prima del primo Play | `code-backed`; motivare durata, minimizzazione (solo domini polimi.it/webex.com, cookie Webex con scadenza entro 12 ore esclusi, email validata e mai nei log, nessun nome) e finalità (accesso automatico a Webex); valutare se l'uso dell'email del profilo senza conferma è coperto da informazione adeguata (testo in Impostazioni, CHANGELOG) e dalla base giuridica scelta, e se Webex riceve l'indirizzo anche da utenti che non hanno mai aperto Impostazioni; provare cancellazione/failure path su turn-off, logout, cambio sito e account; verificare ruolo di Webex come destinatario dell'email e se la catena idbroker → IdP Polimi la inoltra; minimizzazione della lettura del profilo (`core_user_get_users_by_field` restituisce l'intero record, BeepBar decodifica solo `id` ed `email`); un'email appresa prima di una sessione Polimi resta legata al suo account WeBeep e viene scartata al cambio account (test di regressione in PR #152) |
| C06 | Preferiti per account restano dopo logout | `code-backed`; conservazione distinta dalla sessione, documentare e verificare rimozione |
| C07 | Log con campi pubblici; URL Recman ridotti a host/path | `code-backed` parziale; audit di campi/errori e diagnostica |
| C08 | TelemetryDeck diretto, default attivo in Release; da dev `50177f3` (PR #158) l'identità persistente è sostituita da un UUID casuale per mese UTC (cancellato all'opt-out) e il payload aggiunge solo campi a bassa cardinalità (versione principale macOS, lingua, impostazioni attive) | `code-backed` su dev 50177f3, fonte S-0007; la rotazione mensile riduce il collegamento nel tempo ma non risolve la base giuridica del default attivo né rende anonimo il dato (IP, identità entro il mese); il risalting lato server è dichiarato solo in un commento del codice SDK, non nella documentazione; verificare informativa, ruoli/contratti, conservazione, trasferimenti e base GDPR/ePrivacy prima della release; hash non prova anonimato |
| C09 | Processi assistenza/incidenti/diritti non censiti | `open-question`; documentare obblighi proporzionati ai ruoli |

## Limiti e correzioni

Non trovare l'informativa nel repo non dimostra assenza ovunque; sito pubblico non validato. Default automatico degli update non prova obbligo di consenso. File non cifrato non è automaticamente illecito. Logout non deve cancellare materiali/preferiti implicitamente. Produttore locale non è automaticamente titolare di tutti i dati universitari.

Eseguiti: lettura statica, ricerca connessioni/privacy, confronto nomi dei file main→dev, acquisizione fonti pubbliche con hash. Non eseguiti: test app, build, account reali, rete live, accesso a DB utente o assistenza.

Su dev differiscono da main RecordingsController, RecordingsStudyState, WeBeepAuthenticationController: non attribuire i finding alla release senza confronto mirato. API issue GitHub non raggiungibile durante l'indagine; nessuna assegnazione o aggiornamento remoto. [[30 Wiki/Piano di verifica]]

## Aggiornamento 2026-10-17 — issue #180

Base dev `039dc4092d29c23682ee3a8e802f40923af6ffce`; rimedi in PR separata, non ancora attribuibili a main. C02/C03: rilevati cancellazione interrotta da temporanei non rimovibili e mancato restringimento cartella sessione preesistente. C08: payload ridotto nel branch a versioni app/macOS con hash mensile; non dimostra anonimato o liceita default-on. Nuove fonti [[20 Sources/S-0008 TelemetryDeck accordo]], [[20 Sources/S-0009 TelemetryDeck FAQ]], [[20 Sources/S-0010 EDPB basi giuridiche]], [[20 Sources/S-0011 EDPB ePrivacy]], [[20 Sources/S-0012 Garante tracciamento]]. Stato e criteri puntuali nel [gate](../../privacy-release-gate.md); conformita non dimostrata.

Delta #181 dopo decisioni del 2026-10-17: scadenza sessione dopo dieci giorni dal salvataggio iniziale (rimozione attiva o al successivo avvio), backup macOS esclusi per token/sessioni, erasure per account con materiali conservati e warning/retry cronologia persistenti. I blocchi giuridici e runtime del gate rimangono aperti.


## Configurazione aggregata v2 — 2026-10-18, PR #181

Questa valutazione corrente sostituisce C08 per il nuovo protocollo, non per la release o gli eventi storici. `code-backed`: valore comune a tutte le installazioni, conteggio mensile locale, massimo un tentativo giornaliero, soli metadati versione app/macOS, avviso prima dell’invio e opt-out. `inference`: valutazione motivata favorevole art. 6(1)(f), esenzione analytics e anonimato ragionevole dell’archivio v2, basata su codice e dichiarazioni pubbliche del servizio, senza presumere cancellazioni o contratti verificati. Fonte e limiti nel [gate corrente](../../privacy-release-gate.md), riesaminato indipendentemente. Informativa candidata IT/EN e procedura operativa aggiornate; nessuna certificazione globale, sanatoria storica o verifica manuale del binario implicita.
