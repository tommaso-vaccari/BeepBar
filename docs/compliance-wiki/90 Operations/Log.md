# Log

## [2026-10-10] ingest | Avvio Compliance Wiki

Quattro fonti ufficiali, gist Karpathy originale alla revisione ac46de1 ed estratti del codice pubblico dev c9a04dc. Creati schema, schede, quadro normativo, mappa dati, valutazione e piano. Nessun dato personale/chat acquisito. Indagine statica, conformità aperta; nessun fix, commit, push o release. Fonti/hash nel manifest; verifica in [[90 Operations/Lint 2026-10-10]].

## [2026-10-11] update | Riproduzione nativa delle registrazioni (#148)

Aggiornate mappa dei dati (file di sessione con cookie Webex ed email Polimi, posizione di riproduzione, riproduzione nativa) e valutazione C05 sul branch feature/rnp-app-integration, analisi statica del codice. Nessuna nuova fonte esterna; la passata GDPR sul binario prima della release resta aperta. Test e build non eseguiti nell'ambiente di sviluppo (Linux).

## [2026-10-11] update | Email Polimi dal profilo senza conferma (#148)

Decisione del responsabile: l'email del profilo WeBeep è usata per l'accesso a Webex senza conferma esplicita, letta al primo Play. Aggiornate mappa dei dati (riga sessione Webex/email, marcatore di rimozione per account) e C05 (manca ora un'azione dell'utente prima dell'uso: da valutare informazione e base). Analisi statica sul branch fix/rnp-email-confirmed-by-default; test e build non eseguiti (Linux). Nessuna nuova fonte esterna.

## [2026-10-12] update | Riproduzione nativa verificata su macOS (PR #152)

Test completi e build Release eseguiti su macOS sul branch della PR #152, dopo il merge di dev. La review indipendente ha trovato un caso in cui l'email di un account restava in memoria dopo un cambio account senza sessione Polimi: corretto, con test di regressione. Mappa e C05 aggiornate: riferimento alla PR, minimizzazione della lettura del profilo, inoltro dell'email lungo la catena idbroker → IdP Polimi da verificare. Nessuna nuova fonte esterna; la passata GDPR sul binario prima della release resta aperta.

## [2026-10-10] integrate | Preparazione integrazione in dev

Allineamento a origin/dev d3a42dc: integrazione telemetria sopraggiunta rispetto a c9a04dc. Aggiunta fonte codice S-0007 e aggiornate mappa, valutazione e piano; gli snapshot originari restano immutabili. Integrazione della wiki autorizzata; passata finale GDPR prima della prossima release registrata nel piano e nel protocollo release di AGENTS.md. Nessun comportamento dell’app modificato.

## [2026-10-11] update | Elenco corsi salvato (PR #138)

Aggiunta alla mappa dei dati la riga del nuovo file locale `course-list.json` (D10, #98): contenuto, assenza di destinatari, limiti, permessi ed eventi di eliminazione, verificati sul codice del branch della PR. Minimizzazione: niente token né ID utente Moodle, l'account è riconosciuto da un'impronta unidirezionale. Nessuna nuova fonte; valutazione e piano invariati. Da riverificare quando la PR arriva in dev e nella passata GDPR pre-release.

## [2026-10-12] update | Elenco corsi salvato: conservazione (PR #138)

Riga della mappa dei dati corretta dopo la seconda review: aggiunti `savedAt` e la versione del formato; il limite di 30 giorni era applicato solo alla lettura (apertura della finestra), quindi un utente che usa solo la barra dei menu conservava un elenco scaduto. Ora il file scaduto viene eliminato anche all'avvio e a ogni sync, e la credenziale assente all'avvio lo elimina anche con il recupero bloccato; verificato sul codice e con test del branch della PR. Nessuna nuova fonte; valutazione e piano invariati.

## [2026-10-12] update | Telemetria: identificativo mensile e campi del payload

Sul branch `feature/telemetry-monthly-identity` (non ancora in dev): l'UUID permanente di installazione è sostituito da un UUID casuale per mese UTC, rigenerato in modo indipendente a ogni cambio di mese e cancellato all'opt-out; l'UUID della prima build dev viene cancellato all'avvio. Il payload usa le chiavi standard dell'SDK TelemetryDeck per versione app, piattaforma, versione principale di macOS e lingua, più cinque impostazioni `BeepBar.*` a bassa cardinalità. Aggiornate mappa dei dati, C08 e piano di verifica; nessuna nuova fonte, S-0007 resta lo snapshot di d3a42dc e va rinnovato quando il branch arriva in dev. C08 resta aperto.
