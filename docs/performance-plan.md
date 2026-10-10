# BeepBar — Direzione del prodotto e roadmap delle prestazioni

Ultima revisione: 9 ottobre 2026. Questo documento definisce gli obiettivi stabili dell’app, i vincoli delle ottimizzazioni e il lavoro ancora da completare. Le schede tecniche documentano le evidenze disponibili; le issue collegate coordinano il lavoro residuo. Questo documento è condiviso su `dev`.

## Direzione

**Vogliamo la massima reattività e le migliori prestazioni ottenibili sui Mac supportati, mantenendo integralmente funzionalità, freschezza, affidabilità e protezione dei dati promesse da BeepBar.**

L’obiettivo è ridurre al minimo il tempo tra un’azione e il suo risultato utile, il costo di ogni sincronizzazione e le risorse consumate durante la giornata. L’app deve restare pronta anche mentre lavora: aprire il menu, consultare materiali, scorrere una lista o annullare non deve attendere lavoro non pertinente.

“Massime prestazioni” è una direzione di miglioramento continuo, da dimostrare sui percorsi reali e sui dispositivi supportati. Raggiungere un budget non chiude il lavoro se resta uno spreco rilevante e correggibile. Non significa massimizzare il throughput a ogni costo: una sync più veloce che rende la UI meno reattiva o aumenta sensibilmente memoria, energia o traffico richiede una valutazione esplicita del compromesso.

## Scopo dell’app

**BeepBar permette a uno studente di avere sul Mac i materiali aggiornati dei corsi scelti, continuare a lavorare sulle proprie copie senza perdere annotazioni e accedere alle registrazioni disponibili, con un’app nativa che richiede poca attenzione e poche risorse.**

Il flusso principale è: scegliere piattaforma, account, cartella e corsi; lasciare che i controlli automatici mantengano disponibili i materiali; aprire l’app quando serve consultare novità, intervenire su una scelta o avviare una sincronizzazione. La barra dei menu rende accessibili stato e azioni senza richiedere una finestra sempre aperta.

Questa formulazione deriva da [README](../README.md), [specifica di comportamento](sync-behavior.it.md), verificati sul codice dell’audit. Distingue gli obiettivi del prodotto dalle garanzie già implementate: per esempio, mostrare immediatamente i corsi salvati anche dopo un riavvio è un obiettivo ancora da completare con I8.

### Obiettivi per l’utente

| Obiettivo | Risultato atteso e criterio di successo | Interventi collegati |
|---|---|---|
| Avere i materiali pronti per studiare | I corsi selezionati sono sincronizzati nella cartella scelta; i nuovi materiali e gli aggiornamenti vengono acquisiti con la frequenza configurata, nei limiti delle politiche esplicite di rete/energia. I controlli non vengono diradati per migliorare i benchmark. | I2, I4, I5 |
| Poter annotare e modificare le proprie copie con fiducia | Le modifiche locali restano protette; aggiornamenti incompatibili, rimozioni e spostamenti che richiedono una decisione restano visibili fino alla scelta. Errori di rete, crash o dati remoti incompleti non giustificano cancellazioni o perdita di lavoro. | Vincolo per tutti gli interventi; in particolare I2/I4 |
| Trovare subito ciò che serve | Menu, finestra, materiali e registrazioni rispondono rapidamente. I contenuti già noti restano consultabili senza attendere la rete; i file già scaricati restano normali file locali utilizzabili anche offline. L’app mostra quando le informazioni non sono ancora aggiornate. | I3, I6, I7, I8, I10 |
| Capire cosa è successo e cosa fare | Stato, ultimo risultato, novità, errori e scelte pendenti sono coerenti tra menu e pagine. Completamento e annullamento corrispondono al lavoro reale; un dato vecchio o un errore non diventano un falso successo. | I3, I4, I5, I6, I9b |
| Accedere alle registrazioni con pochi passaggi | Per gli account supportati, la pagina recupera le registrazioni dei corsi selezionati quando viene aperta e permette di riprodurle nel browser o copiarne il link. Le richieste seguono la selezione e le azioni dell’utente; la funzione non grava sulla normale sync dei file. | I9, I10 |
| Lasciare l’app aperta durante la giornata senza doverla gestire | Consumo trascurabile quando non c’è lavoro dovuto; costi limitati e prevedibili durante sync e consultazione. Riapertura, aggiornamento dell’app e ripresa dopo un errore conservano dati, impostazioni e possibilità di recupero. | I1, I2, I5, I6, I7, I9c |

### Ambito e confini

- **Materiali dei corsi:** acquisizione da WeBeep/Moodle supportati verso il Mac, organizzazione delle cartelle, aggiornamenti e gestione esplicita dei conflitti. Le modifiche locali non vengono caricate su Moodle; estendere a una sincronizzazione bidirezionale richiederebbe un progetto distinto.
- **File locali:** restano accessibili dal Finder e dalle applicazioni preferite. La protezione durante la sync non costituisce un sistema di backup o una cronologia completa: per esempio un file seguito cancellato localmente viene riscaricato secondo la specifica, e Attività mostra l’ultima sync.
- **Registrazioni:** consultazione su richiesta e apertura nel browser per la piattaforma supportata. La sync dei materiali non scarica i video; la funzione conserva una sessione separata e rispetta disattivazione, logout e cambio account.
- **Esperienza macOS:** interfaccia nativa, barra dei menu, azioni semplici e localizzate, lavoro automatico discreto. Architettura e cache sono mezzi per questi risultati, non obiettivi autonomi.
- **Dati e identità:** credenziali, sessioni e stato persistito restano separati secondo il loro ruolo; cache e task non devono mescolare utenti o siti. Le misure di sviluppo usano fixture, senza coinvolgere l’account o i file reali dell’utente.

### Criterio di priorità

Ogni proposta deve indicare **quale obiettivo migliora, quale percorso reale costa troppo o si comporta male, quale prova lo dimostra e come si verifica il risultato**. Dare precedenza ai difetti che minacciano dati/correttezza o impediscono un’azione; poi al costo dei percorsi frequenti e ai ritardi percepibili, tenendo conto di diffusione, dimensione e rischio della modifica. Un caso raro riprodotto resta nel piano con la sua frequenza ignota dichiarata.

Nessun risparmio compensa una regressione nelle garanzie. Tra due soluzioni corrette, preferire quella più semplice che produce un beneficio misurabile. Una proposta senza evidenza sufficiente resta un’indagine delimitata, non un’implementazione già decisa.

## Principi del prodotto e vincoli delle ottimizzazioni

I principi definiscono condizioni verificabili per lo sviluppo condiviso. La correttezza e la protezione dei dati prevalgono sui risultati dei benchmark. La specifica di comportamento vigente resta il contratto: quando una proposta lo cambia, serve una decisione esplicita e l’aggiornamento di entrambe le versioni linguistiche.

1. **Proteggere i dati dell’utente.** Non perdere né sostituire modifiche locali senza la scelta prevista dalla sincronizzazione a tre vie. Conservare controlli al momento dell’azione, atomicità, journal e recupero. Un’ottimizzazione è accettabile solo se conserva le prove contro modifiche concorrenti, percorsi non sicuri e interruzioni; non basta che passi il caso ordinario.
2. **Rispondere subito e mostrare contenuti utili.** Menu, icona, finestra e comandi devono reagire entro i rispettivi budget, anche durante sync e recupero. All’apertura mostrare subito i dati già conosciuti, aggiornandoli in background; al primo uso mostrare immediatamente uno stato utilizzabile. Una finestra vuota ma già aperta non soddisfa questa promessa.
3. **Essere quasi gratuita a riposo.** Con finestra chiusa e nessuna operazione dovuta, evitare lavoro CPU, rete, scritture, timer e crescita di memoria. I controlli pianificati, gli aggiornamenti e le operazioni richieste devono avere uno scopo e un costo misurabile. Al termine rilasciare task e risorse; mantenere cache soltanto con limiti e un beneficio dimostrato.
4. **Far crescere il costo con il lavoro necessario.** Evitare riletture, hash, query, scritture e pubblicazioni identiche. Distinguere il lavoro necessario a rilevare cambiamenti da quello necessario ad applicarli: una sync invariata può ancora richiedere metadati e verifiche locali. Non saltare il controllo di un file cancellato sul Mac solo perché il server non segnala novità.
5. **Non comprare efficienza riducendo la freschezza.** Rispettare l’intervallo scelto e acquisire le novità quando disponibili; risparmiare rendendo i controlli più economici. Restano le eccezioni esplicite della specifica, incluse le politiche energetiche e di rete. Cambiarle è una scelta di prodotto, non un’ottimizzazione trasparente.
6. **Limitare le risorse durante il lavoro, non dopo.** Memoria, risposta di rete, concorrenza e code devono avere limiti effettivi. Rifiutare un payload solo dopo averlo caricato interamente non ne limita il costo. I file grandi devono essere elaborati a blocchi; le liste grandi non devono generare lavoro UI proporzionale a tutti gli elementi a ogni evento.
7. **Rendere l’annullamento reale e lo stato comprensibile.** Fermare rapidamente le fasi interrompibili; completare o recuperare in sicurezza quelle già entrate in una modifica atomica. Non dichiarare successo, freschezza o annullamento completo quando non sono veri. Distinguere dati salvati, aggiornamento in corso, pausa, errore e azione richiesta; un risultato tardivo non deve riattivare un’operazione conclusa.
8. **Conservare identità e compatibilità.** Cache e risultati asincroni devono appartenere al sito, account, root e operazione corretti. Logout e cambio account devono impedire la ricomparsa di dati o sessioni precedenti. Supportare utenti che saltano release; ogni modifica ai dati persistiti richiede migrazione e compatibilità/rollback verificati.
9. **Dimostrare il beneficio con la modifica minima necessaria.** Prima identificare un percorso concreto, poi misurare o riprodurre il problema, infine intervenire. Riportare anche risultati negativi e limiti. Nessuna riscrittura generale, cache aggiuntiva o tuning senza evidenza sufficiente a giustificarne costo e rischio.

### Budget e significato delle misure

I budget sono obiettivi provvisori, non risultati già raggiunti. Una baseline non li sostituisce automaticamente. Ogni eccezione o revisione va motivata.

| Momento | Criterio |
|---|---|
| Riposo per 30 minuti | CPU prossima a zero, nessun risveglio/lavoro attribuibile senza scopo, zero rete e scritture fuori dai controlli/operazioni dovuti |
| Dopo 10 sync o chiusura finestra | Memoria vicina al livello stabilizzato precedente (obiettivo ±2 MB), nessun task o timer residuo non necessario |
| Avvio e menu | Icona entro 200 ms; `menuNeedsUpdate` entro 1 ms; icona coerente nello stesso turno main-actor dello stato |
| UI | Nessun blocco del main thread oltre 16 ms; misurare anche scorrimento e azioni durante la sync |
| Finestra | Key entro 250 ms a freddo / 100 ms a caldo; primo contenuto utile misurato separatamente e disponibile senza attendere rete quando già conosciuto |
| Sync invariata | ≤50 ms di lavoro locale/1.000 file; zero hash, modifiche DB e scritture non necessarie; minimo numero di richieste compatibile con la correttezza |
| File nuovi/aggiornati | Memoria indipendente dalla dimensione del file; misurare throughput, CPU e letture prima di attribuire il limite alla rete |
| Annullamento | p95 <1 s nelle fasi interrompibili, compresi file grandi; sicurezza del completamento/recupero nelle fasi atomiche |

## Risultati obbligatori nelle PR: incremento e confronto con main

Comando unico riproducibile: [`scripts/benchmark.sh compare`](benchmarks.md#reproducible-ref-comparisons-single-agent-command); seguire prerequisiti, policy di compatibilità e passi per agenti. Conservare report e limiti; validazione tooling distinta dai benefici applicativi.

Ogni PR di performance deve riportare due confronti distinti, con SHA esatti e link ai report: **base dev della PR → HEAD finale** per attribuire il beneficio alla modifica, e **main → HEAD finale** per quantificare il risultato cumulativo rispetto alla release. Alla chiusura di D13 ripetere l'intera baseline su main e dev finali. Verificare i riferimenti remoti prima delle misure; fissare lo SHA di main per il ciclo e non cambiare silenziosamente il riferimento se arriva una release. Un confronto con un main successivo è una nuova serie dichiarata.

Usare la stessa macchina, Release arm64, alimentazione e condizioni termiche confrontabili, dataset, rete sintetica, warm-up, campioni e harness equivalente su entrambi i commit. Un vecchio report dev non è automaticamente una baseline main. Conservare JSON e comandi; se cambia il corpus o lo strumento, rieseguire entrambi i lati oppure dichiarare il confronto non disponibile.

La descrizione della PR include una tabella con scenario/metrica/unità, main, base dev, HEAD, delta assoluto e percentuale per entrambi i confronti. Separare CPU, tempo trascorso, memoria, lavoro DB/I/O/rete e annullamento; includere peggioramenti, dispersione e limiti. Per costi riportare riduzione `(prima - dopo) / prima × 100`; per throughput incremento `(dopo - prima) / prima × 100`. Con baseline zero riportare solo delta assoluto, senza percentuale. Non sommare percentuali di task o corpus differenti né trasformare benchmark Core in una promessa sulla reattività dell'intera app.

Se manca una misura confrontabile, scrivere **non misurato** e indicare il comando/prossimo passo; non sostituire numeri con deduzioni dal codice. Per fix di correttezza senza beneficio temporale dimostrato riportare la regressione red/green e i conteggi pertinenti; per PR solo documentali dichiarare non applicabile. Il report finale deve permettere affermazioni delimitate come «sync invariata: X% meno CPU rispetto a main», non «app X% più veloce» senza misure end-to-end dedicate.

## Review e battle testing obbligatori

1. Un reviewer senior indipendente, che non ha scritto la modifica, esamina l’intero diff contro i principi qui definiti e le specifiche IT/EN. Per lavoro affidato ad agenti usare un subagente indipendente; il responsabile della modifica non può autocertificare la review.
2. Il reviewer cerca bug, regressioni, failure path mancanti e test che passerebbero anche con codice rotto. Ogni finding actionable è classificato P0/P1/P2 e collegato al percorso e alla prova necessaria.
3. Correggere il finding, aggiungere una regressione pertinente e ripetere la review fino a CLEAN, senza P0/P1/P2 aperti. Se emerge almeno un P0, la review successiva deve essere di un reviewer diverso; per soli P1/P2 lo stesso reviewer riverifica fix e diff completo.
4. Ogni intervento va battle tested: percorso reale interessato, edge case, errore e cancellazione pertinenti, vecchi dati/migrazioni, cambio lingua/identità e ciò che vedono utenti esistenti quando applicabili. Non aggiungere test rituali che copiano l’implementazione o asseriscono soltanto che una funzione sia stata chiamata.
5. Dimostrare la sensibilità della regressione: fallisce sul comportamento precedente e passa col fix; per una feature rimuovere o invertire il comportamento con una mutation controllata e ottenere un’aspettativa fallita, non un errore di compilazione. Mutazioni di spostamenti/cancellazioni filesystem soltanto in una copia usa e getta. Conservare comando, SHA, esito red e green; niente stash indiscriminati.
6. Test mirati durante l’iterazione, poi suite completa e build Release sul commit finale pulito. Reiterare le verifiche coinvolte dopo modifiche; CI verde pre/post-merge. Una build riuscita non dimostra comportamento UI o login reale: riportare i limiti e la validazione manuale mancante. Le indagini senza fix chiudono solo con evidenza e decisione motivata.

## Organizzazione del team

La roadmap definisce direzione, principi e criteri; le issue sono la fonte dello stato operativo, del responsabile e delle dipendenze. Seguire [il workflow condiviso](team-workflow.md). Una issue rappresenta una consegna delimitata, oppure un’indagine con una decisione finale: non tutte le ipotesi giustificano già un fix.

Prima di iniziare, assegnarsi la issue e indicare branch, base dev/SHA e dipendenze. Alla pausa lasciare nella issue HEAD, PR, verifiche eseguite, lavoro aperto e prossimo passo. Una PR chiude la issue solo dopo integrazione in `dev`; la release su `main` è una decisione separata.

Non lavorare contemporaneamente sugli stessi percorsi senza concordare l’ordine. D06 precede D08/D10 nel controller autenticazione; D09 precede D12 nelle registrazioni. D07 può partire in parallelo a D06, coordinando eventuali hook nel controller. I fix indipendenti I1/I4/I9b/I11 non devono aspettare la conclusione delle misure UI.

## Consegne integrate

| Consegna | PR | Risultato |
|---|---|---|
| D01 / I9a | [#89](https://github.com/tommaso-vaccari/BeepBar/pull/89) | Richieste di registrazioni accodate rimosse quando il corso viene deselezionato; Play/Copia conservati. |
| D02 / I2a | [#90](https://github.com/tommaso-vaccari/BeepBar/pull/90) | Una sola lettura autorevole delle baseline, recovery ed errori conservati. |
| D03 / I2b | [#91](https://github.com/tommaso-vaccari/BeepBar/pull/91) | Backfill indicizzato soltanto quando esistono candidati legacy; nessuna cache permanente. |
| D04 / I2c | [#92](https://github.com/tommaso-vaccari/BeepBar/pull/92) | Zero UPDATE per override invariati; al massimo uno per modulo rinominato con nomi concordi. |
| D05 / I6 riepilogo | [#93](https://github.com/tommaso-vaccari/BeepBar/pull/93) | Restore senza riscritture, decode fuori dal main, migrazione legacy e nuovi risultati conservati. |
| D08 / I3 | [#133](https://github.com/tommaso-vaccari/BeepBar/pull/133) | Throttle del progresso prima del main actor: ingressi solo per aggiornamenti accettati e totali finali, run superate e tardive ignorate, cadenze 200 ms/1 s conservate. |
| D11 / I10 Attività | [#139](https://github.com/tommaso-vaccari/BeepBar/pull/139) | Corso espanso paginato: prime 200 righe, «Mostra altri» fino all’ultima, ID stabili e univoci, ritorno a una pagina alla chiusura o con un nuovo riepilogo. Ultima riga ancora raggiungibile solo costruendo le precedenti. |
| R02 / migrazioni all’avvio | [#134](https://github.com/tommaso-vaccari/BeepBar/pull/134) | Indagine conclusa senza modifiche al codice di produzione: aperture successive senza scritture di righe o pagine (~1,1 ms a 15k file, fuori dal main actor); riparazione una tantum ~7,5 ms a 15k. `SyncDatabase.migrate` resta completa a ogni apertura. Aggiunti lo scenario benchmark `startup` e i test di regressione. |
| R05 / metadati incrementali Moodle | [#143](https://github.com/tommaso-vaccari/BeepBar/pull/143) | Indagine conclusa con esito negativo: le API «aggiornamenti da» di Moodle non segnalano moduli rimossi, spostamenti, rinomine di sezione e visibilità né riducono le richieste; la scansione completa per corso resta. Solo documentazione: nessun cambiamento al codice, nessuna verifica di test o build. |

Verificate su dev `81ee436749b6a11eebf75fdabd247639310563c7`: suite finale 620 test, build Release, review indipendenti e CI pre/post-merge verdi. Le PR integrate non equivalgono a una release installata.

D08 / I3 ([#133](https://github.com/tommaso-vaccari/BeepBar/pull/133)): verificata su `bb5943b` con 685 test, build Release, review indipendente CLEAN al terzo round, mutazioni macOS (hop prima del throttle: 10.000 ingressi per 10.000 eventi contro un massimo di 2; cadenze unificate o invertite rilevate) e CI verde; fluidità UI non misurata (D07 non integrata).

D11 / I10 Attività ([#139](https://github.com/tommaso-vaccari/BeepBar/pull/139)): verificata su `9543abe` con 678 test, build Release, review indipendente CLEAN al secondo round e CI verde; budget UI non misurati (D07 non integrata).

R05 ([#143](https://github.com/tommaso-vaccari/BeepBar/pull/143)): [rapporto](moodle-incremental-metadata.md) basato sul sorgente Moodle `main` `f20534726a59`, con review indipendente dei riferimenti. Nessun dato reale o account usato; confronti prestazionali base dev → HEAD / main → HEAD non applicabili (nessun codice). Restano possibili solo indagini future distinte, ciascuna da misurare prima: batching via `tool_mobile_call_external_functions` e presenza di `contenthash` su WeBeep (solo con autorizzazione esplicita).

R02 ([#134](https://github.com/tommaso-vaccari/BeepBar/pull/134), [#110](https://github.com/tommaso-vaccari/BeepBar/issues/110)): misurato il lavoro di `BootstrapService.prepare` (apertura con migrazione, `registerRoot`, recovery) su un database sintetico con lo schema attuale degradato (`LegacyDatabaseFixture`: metà righe senza modulo, 40 righe semi-attribuite, versioni registrate cancellate, tabelle e indice successivi rimossi). Release arm64, Mac17,3 Apple M5/32 GB, macOS 27.0.1, alimentazione AC, stato termico nominale, una warm-up e cinque run, comando `scripts/benchmark.sh startup`, commit `5ad8f36` (codice identico alla testa della PR: i commit successivi toccano solo la documentazione); rapporti JSON locali non versionati.

| Avvio | File | Avvio intero mediana / p95 | Apertura+migrazione mediana / p95 | CPU mediana | Disco scritto | Picco memoria | Lavoro DB |
|---|---|---|---|---|---|---|---|
| primo dopo l’aggiornamento | 15.000 | 7,53 / 7,66 ms | 7,43 / 7,55 ms | 6,6 ms | 3564 KiB | 8,0 MiB | 47 righe, 230 pagine |
| primo dopo l’aggiornamento | 100.000 | 57,53 / 57,87 ms | 57,39 / 57,73 ms | 40,8 ms | 20.740 KiB | 20,9 MiB | 47 righe, 1242 pagine |
| successivi | 0 | 0,37 / 0,44 ms | 0,31 / 0,36 ms | 0,49 ms | 36 KiB | 3,5 MiB | 0 righe, 0 pagine |
| successivi | 15.000 | 1,13 / 1,18 ms | 1,07 / 1,11 ms | 1,2 ms | 36 KiB | 4,7 MiB | 0 righe, 0 pagine |
| successivi | 100.000 | 5,65 / 5,70 ms | 5,57 / 5,60 ms | 5,9 ms | 36–48 KiB | 20,8 MiB | 0 righe, 0 pagine |

Tutti i controlli superati: riparazione delle sole righe semi-attribuite e delle 7 versioni, tabelle e indice ripristinati, file tracciati conservati, recovery vuota, aperture successive identiche, senza righe o pagine scritte e senza lavoro di attribuzione dei moduli (contatori di backfill e override a zero, misurati sulla connessione dell’avvio). I ~36 KiB scritti per avvio senza pagine DB sono probabilmente i file `-wal`/`-shm` ricreati alla riapertura (non verificato); le due transazioni vuote di migrazione e `registerRoot` non scrivono pagine. La CPU include il thread da 1 ms che campiona il picco di memoria, quindi negli avvii sotto il millisecondo può superare il tempo reale. «Avvio successivo» è una nuova connessione SQLite sullo stesso file: la cache delle pagine del sistema resta calda. Allocazioni non misurate (solo picco di memoria). **Decisione:** nessuna modifica a `SyncDatabase.migrate`. Il costo per avvio resta sotto i budget, non scrive e gira sull’attore di `BootstrapService` mentre il menu mostra lo stato di avvio; una guardia di versione salterebbe le riparazioni che ogni apertura esegue di proposito (gruppi di colonne lasciati a metà da build precedenti, [PR #61](https://github.com/tommaso-vaccari/BeepBar/pull/61); tabelle e indici mancanti; righe semi-attribuite) in cambio di meno di 1 ms a 15k file (la parte che cresce con il database: 1,07 − 0,31 ms) e circa 5,3 ms a 100k. Schema invariato: downgrade e riapertura non cambiano. Release saltate: `StartupMigrationTests` apre un database con lo schema di v2.0.106 (`0dfa75a`, prima della proprietà dei moduli e dei piazzamenti) e 15.000 file tracciati; il primo avvio aggiunge colonne, tabelle, indice e versioni in un solo commit con 4 righe cambiate (le versioni) e nessuna riga di `items` riscritta, quelli successivi non scrivono nulla (debug macOS arm64: 5,0 ms il primo, 0,9 ms i successivi; non misurato in Release). La fixture del benchmark modella invece una tabella `items` semi-attribuita. Prove di regressione: `StartupMigrationTests` (Core, eseguibile anche su Linux) e i test dello scenario `startup`. Mutazioni in worktree usa e getta: senza l’UPDATE di riparazione falliscono `StartupMigrationTests` (righe semi-attribuite rimaste) e entrambe le fasi dello scenario; senza la clausola `WHERE` dell’UPDATE di riparazione falliscono i tre test di `StartupMigrationTests` (il primo avvio da v2.0.106 cambierebbe 15.004 righe invece di 4); senza la clausola `WHERE` dell’upsert di `registerRoot` falliscono le asserzioni «avvii successivi senza scritture» di test e scenario. Confronti: base dev → HEAD non applicabile (nessun cambiamento in `Sources/BeepbarCore`, `Sources/BeepbarApp` o `Package.swift`: i numeri HEAD misurano dev `ed6670f`); main → HEAD non misurato, perché l’harness corrente di dev non compila contro main `3ce0ba0` (`OwnershipBackfillCounters`, `moduleOverrideUpdateAttempts`), limite precedente a questa PR. Fluidità dell’avvio nell’app (icona, finestra) non misurata: richiede D07. Verificata su `5ad8f36` con la suite completa (692 test Swift Testing e 14 XCTest), i test Python di `benchmark_compare.py`, la build Release e le mutazioni sopra; CI macOS verde su `14fca41`, ultima testa con codice (i commit successivi cambiano solo commenti e documentazione). Review indipendente con lo stesso revisore per tre round (solo P1 e P2, nessun P0); l’esito finale è registrato in [#134](https://github.com/tommaso-vaccari/BeepBar/pull/134) e [#110](https://github.com/tommaso-vaccari/BeepBar/issues/110).

Misure sintetiche Release arm64, M5/32 GB, AC, una warm-up e sette run: D04, corpus invariato con override da 15k, CPU mediana 474,867→413,631 ms, p95 478,502→416,123; UPDATE/commit 15.000→0. Picco memoria mediano 44,376→47,063 MiB: aumento registrato, nessun risparmio memoria rivendicato; la memoria stabilizzata dopo dieci sync non è stata misurata. D05, JSON da 1.133.014 byte/15k dettagli, restore async mediana 42,622→21,986 ms, p95 43,028→22,382; scritture 2→0. Sono misure con fixture, non fluidità UI, main occupancy, energia o servizio reale. Non confrontare corpus differenti. Vedere [comandi benchmark](benchmarks.md).

## Lavoro aperto e issue

[Tracker di consegna](https://github.com/tommaso-vaccari/BeepBar/issues/116). Gli assegnatari correnti e le prese in carico sono nelle singole issue; concordare eventuali riassegnazioni prima di lavorare.

| Task | Branch | Dipendenze | Issue |
|---|---|---|---|
| D07 | `perf/isolated-ui-harness` | Nessuna | [#95](https://github.com/tommaso-vaccari/BeepBar/issues/95) |
| D09 | `perf/recordings-session-io` | D01, D07 | [#97](https://github.com/tommaso-vaccari/BeepBar/issues/97) |
| D10 | `feature/cached-course-list` | D06, D07, D08 | [#98](https://github.com/tommaso-vaccari/BeepBar/issues/98) |
| D12 | `perf/recordings-derived-state` | D07, D09 | [#100](https://github.com/tommaso-vaccari/BeepBar/issues/100) |
| D13 | `docs/performance-results` | D06, D07, D08, D09, D10, D11, D12 | [#101](https://github.com/tommaso-vaccari/BeepBar/issues/101) |
| I1 | `fix/bounded-metadata-response` | Nessuna | [#102](https://github.com/tommaso-vaccari/BeepBar/issues/102) |
| I9b | `fix/recordings-seen-overflow` | Nessuna | [#106](https://github.com/tommaso-vaccari/BeepBar/issues/106) |
| I9d | `perf/recordings-play-priority` | D07 | [#107](https://github.com/tommaso-vaccari/BeepBar/issues/107) |
| R01 | `perf/sync-summary-persistence` | D07 | [#109](https://github.com/tommaso-vaccari/BeepBar/issues/109) |
| R03 | `perf/directory-traversal-profile` | Nessuna | [#111](https://github.com/tommaso-vaccari/BeepBar/issues/111) |
| R04 | `fix/recordings-javascript-lifecycle` | Nessuna | [#112](https://github.com/tommaso-vaccari/BeepBar/issues/112) |
| R06 | `test/recordings-acknowledgement-race` | Nessuna | [#114](https://github.com/tommaso-vaccari/BeepBar/issues/114) |
| R07 | `docs/recordings-live-validation` | Nessuna | [#115](https://github.com/tommaso-vaccari/BeepBar/issues/115) |

## Backlog già esistente

Non duplicare queste issue. Prima di avviarle ricontrollare lo stato su dev: alcune richieste possono essere già soddisfatte; le estensioni di prodotto restano separate dai fix di performance.

- [#88 — Streamline CI while preserving validation and release behavior](https://github.com/tommaso-vaccari/BeepBar/issues/88)
- [#87 — Allow downloading recordings for offline viewing](https://github.com/tommaso-vaccari/BeepBar/issues/87)
- [#70 — Mettere in quarantena i file scaricati, come fanno i browser](https://github.com/tommaso-vaccari/BeepBar/issues/70)
- [#64 — Interruttore in Impostazioni per disattivare le notifiche (attive di default)](https://github.com/tommaso-vaccari/BeepBar/issues/64)
- [#56 — Uniformare il nome in BeepBar: testo dell'app, link e README](https://github.com/tommaso-vaccari/BeepBar/issues/56)
- [#8 — Extend beyond WeBeep to general Moodle instances](https://github.com/tommaso-vaccari/BeepBar/issues/8)

## Schede operative

I percorsi sono relativi al repository. Le righe si riferiscono al commit dell’audit; i nomi delle funzioni identificano il codice anche dopo un rebase.

### I1 — Limitare i metadati prima di caricare l’intera risposta

**Problema:** `Sources/BeepbarCore/Network/WeBeepAPIClient.swift:329`, `request`, usa `session.data(for:)` e controlla `data.count <= limit` soltanto dopo. Il limite rifiuta il risultato ma non limita ricezione e memoria. Una risposta enorme o prolungata consuma risorse prima del controllo. Difetto confermato dal codice; nessun incidente di produzione osservato.

**Intervento:** ricezione incrementale limitata, con annullamento appena i byte effettivi superano il limite della funzione. Content-Length può anticipare il rifiuto, ma non sostituire il conteggio. Conservare il rifiuto dei redirect della sessione standard, autenticazione, content-type e mappatura errori. Mantenere l’iniezione di `URLSession` usata dai test: cambiare trasporto non deve bypassare le fixture. Verificare la dimensione del corpo consegnato al decoder anche con decompressione. Evitare callback per byte sul main actor.

**Accettazione:** fixture chunked interrotta al limite più un buffering di trasporto limitato; header assente, falso o eccessivo non aggirano il controllo; JSON valido esattamente al limite accettato. Annullamento ed errori API mantengono il significato. Una sonda di memoria dimostra che il costo non cresce con l’intero corpo sovradimensionato. Eseguire `WeBeepAPIClientTests` e test degli errori sync. Nessun payload anomalo sul servizio reale.

**Stato e prove (#102):** proposta su `fix/bounded-metadata-response`, base dev `ac68333`, implementazione `3d94bda`; non integrata. Ricezione incrementale per task sulla sessione originale, controllo dei chunk decompressi prima di appendere, annullamento al primo superamento e conservazione delle classificazioni errore/redirect/auth. Regressione red: tutti i cinque casi header ricevono 16 MiB sulla base; green: stop a 1 MiB + 16 KiB. La [validazione dedicata](metadata-response-validation.md) riporta limiti inclusivi 1/2/4 MiB, gzip loopback, cancellazione e sonda RSS Release: con body 16/128 MiB il picco candidato resta circa 15,3 MB, contro 48,2/284,6 MB della base. Misura su batteria, descrittiva del bound; confronti standard base-dev → HEAD e main → HEAD non misurati (nessun confronto coordinato su alimentazione AC). Dopo disponibilità di Xcode 27.0, `swift test` standard è green (666 test totali) e il target app Release è BUILD SUCCEEDED sul commit `819462d`. [PR #127](https://github.com/tommaso-vaccari/BeepBar/pull/127) aperta verso dev. La review del proprietario ha trovato P1 cancellazione tra creazione task e installazione continuation su `096570b`; iterazione `1e65515` conserva il primo risultato terminale e garantisce completamento unico. Regresso deterministico red sul vecchio bridge (due assertion), green ripristinato; successo anticipato/duplicati e 30 gare coperti. Merge `f23b8ee` include dev `713033c`; 694 test e Release verdi su `1e65515`. Nuova review approva il protocollo; follow-up `d4c0012` conserva compilazione/test Core Linux dopo il merge di dev, con fixture CFNetwork/RSS solo Darwin. SHA finale, review CLEAN e CI sono registrati nella issue/PR prima della consegna.

### I2 — Eliminare il lavoro DB inutile nella riconciliazione invariata

**Completata tramite D02/D03/D04 (#90/#91/#92).** Una lettura autorevole dopo backfill, query indicizzata dei candidati legacy e aggiornamenti override solo per modulo rinominato con metadata concordi. Recovery, modifiche locali, ownership e destinazioni personalizzate conservati. Le prove e i limiti sono nelle consegne e nei report locali; non ripetere implementazione o benchmark su vecchi finding/linee di codice. Eventuali ulteriori interventi DB richiedono nuova evidenza.

### I3 — Applicare il throttle prima del main actor

**Implementata tramite D08 (#96, [PR #133](https://github.com/tommaso-vaccari/BeepBar/pull/133)):** il throttle e il token di run (`SyncProgressRun`) vivono in un relay protetto da lock, consultato dalla callback sul task del sync; il main actor viene attraversato soltanto per gli aggiornamenti accettati e per i totali finali. `endOperation` ritira il token, quindi callback tardive di una run annullata o conclusa, e le run rifiutate da `beginTransfer`, non toccano più lo store. Prova in `SyncProgressStoreTests`: 10.000 eventi da un task detached producono al massimo 2 + ⌊durata/200 ms⌋ ingressi sul main actor (contatore `mainActorEntries`, incrementato all'ingresso di `progressAccepted` prima di ogni guardia, così un hop spostato prima del throttle lo fa salire a 10.000), cadenze 200 ms manuale e 1 s automatica distinte da un intervallo di 400 ms tra due eventi, totali finali consegnati, eventi fuori ordine, di run superate (anche dopo la chiusura della run attiva) e successivi alla chiusura ignorati. Nessuna misura di fluidità UI: il contatore prova il numero di salti, non la reattività (I7). Non eseguibile su Linux: suite completa e build Release verificate su macOS (Apple M2) e in CI su `bb5943b`.

**Evidenza originale:** entrambe le callback sync chiamano `publishProgress` del controller main-actor (`Sources/BeepbarApp/WeBeepAuthenticationController.swift:2303`) prima del relay/throttle di `SyncProgressStore`. Anche gli eventi scartati fanno quindi il primo salto sul main actor.

**Intervento:** alimentare direttamente relay/store fuori dal main; entrarvi soltanto per gli aggiornamenti accettati e lo stato terminale. Conservare identità dell’operazione, cadenza manuale/automatica e aggiornamento del menu. Un progresso accodato di una vecchia run non deve sovrascrivere completamento o run successiva.

**Accettazione:** test deterministico con 10.000 eventi che conta gli ingressi sul main actor, non soltanto i valori pubblicati. Il numero dipende dalle finestre del throttle, non dai file; totali finali sempre consegnati, annullamento senza spinner residuo, callback vecchie ignorate. Eseguire i test di completamento/redraw; usare I7 per verificare l’effetto sulla reattività. Il solo contatore non dimostra fluidità visiva.

### I4 — Verificare l’annullamento oltre il download

**I4a implementata ([#103](https://github.com/tommaso-vaccari/BeepBar/issues/103)):** lettura path con annullamento cooperativo, completamento unico e rilascio monitor/timer, anche quando la cancellazione precede l’installazione o compete con callback e timeout. Il controller scarta la lettura annullata prima di avviare sync. Provider sintetico senza risposta: completamento entro 100 ms senza sleep arbitrari; 30 gare concorrenti e Data Saver coperti. Mutazione isolata senza i due fix: otto assertion falliscono, incluse richieste inviate dopo cancellazione. Gate finali e CI riportati nella PR/issue; nessuna misura di latenza UI implicita.

**I4b implementata ([#104](https://github.com/tommaso-vaccari/BeepBar/issues/104)):** checkpoint prima e dopo l’hash e tra chunk da 1 MiB; l’ispezione ordinaria, gli snapshot preliminari, la finalizzazione dello staging e la lettura/copia dei conflitti rispondono alla cancellazione. Un hash incompleto non entra nella cache; una copia interrotta elimina solo il proprio staging. Il planner propaga CancellationError invece di trattarlo come file illeggibile.

**Classificazione verificata dei chiamanti:**
- `inspect`: letture preliminari ManualSync/ConflictResolver cooperativi; RecoveryCoordinator e verifica dopo conservazione del conflitto completano senza cancellazione.
- `snapshotRegularFile`: riconciliazione SyncCoordinator, controlli iniziali RemoteChangeResolver e preview ModulePathMigrator cooperativi; recupero RemoteMoveJournal e controllo prima del cestino completano senza cancellazione.
- Importazione download già cooperativa; `finalize`, validazione e copia incoming sono preparazione prima del journal, quindi cooperativi.
- `conflictArtifact`: consultazione ordinaria cooperativa; recupero e rimozione dopo risoluzione DB completano senza cancellazione.
- Validazione move/swap, controllo installazione, hash displaced/rollback, `stagedArtifact` di recovery e discard di recovery completano senza cancellazione. Il confine durevole è `beginOperation`/`beginRemoteMoves`, prima dello swap: interrompere da quel punto richiede completamento o recovery, non abbandono dell’artefatto.

**Prove:** fixture isolate da 64 MiB annullano il task durante cinque percorsi reali di lettura/copia dopo 8 MiB. Verificano stop dei chunk, byte locali/incoming intatti, staging parziale rimosso e assenza di cache parziale. Cancellazione ai tre confini journal/filesystem/commit e recovery già annullata conservano baseline, conflitti e journal coerenti. Mutazione isolata che rimuove i checkpoint: sei failure; mutazione che rende interrompibili le letture durevoli: sette failure. Due regressioni aggiunte dopo review esercitano il consumer reale della cache (installazione senza nuova inspect) e il ramo conflitto dopo journal: le rispettive mutazioni mirate producono altre tre failure. Suite InterruptedSyncRecoveryTests, ConflictResolverTests e ModuleMoveRecoveryTests incluse nei gate. Review indipendente, suite completa, build Release e CI pre/post-merge nella PR/issue.

**Misura riproducibile:** `BEEPBAR_HASH_CANCEL_REPORT=1 swift test -c release -Xswiftc -DDEBUG --filter releaseCancellationLatency`. Ottimizzazione Release; DEBUG abilita soltanto i seam degli app test preesistenti, nessun ramo DEBUG nel Core. Due warm-up e venti campioni per percorso; cancellazione durante lettura dopo 8 MiB, latenza fino al risultato del task. Mac17,3 / Apple M5, alimentazione AC, nessun warning termico registrato, fixture APFS calda da 64 MiB. p95 misurati (ms): inspect 0,033; snapshot 0,010; finalize 0,010; incoming 0,009; copia incoming 0,133 (massimo 0,143). Misura sul codice `74f4b3c`; i campioni quantificano consegna cooperativa a un checkpoint controllato, non il ritardo di una read bloccante. Non preempta read/fsync bloccanti o idratazione cloud; non dimostra latenza UI né p95 universale su altri filesystem.

### I5 — Mantenere coerente lo scheduler senza ripartire a ogni cambio conteggio

**Implementata per [#105](https://github.com/tommaso-vaccari/BeepBar/issues/105).** La chiave dello scheduler distingue selezione vuota/non vuota; cambiare corsi senza svuotarla conserva la registrazione e la scadenza. Le transizioni di recovery invalidano o ripristinano la pianificazione una volta sola. Una generazione identifica il timer, un’altra invalida le risposte rete quando cambia selezione: una callback di un timer rimosso termina senza leggere la rete; cambiare selezione rimuove comunque la pausa Risparmio dati (§6).

**Prova riproducibile:** tre regressioni controller con scheduler e clock sintetici, account/root/DB e rete isolati; sul codice originale compilato falliscono 14 assertion. A clock 120 s, aggiungere un secondo corso conserva la scadenza a 28.800 s invece di spostarla a 28.920 s; registrazioni 2→1. Coperti 1→0, 0→1, recovery ripetuto, callback obsolete e risposta path sospesa durante un cambio selezione. Tutti i 27 test Risparmio dati passano dopo il fix. Review indipendente, suite completa, build Release e CI pre/post merge sono gate riportati nella PR/issue. Questi conteggi dimostrano eliminazione di reset inutili e correttezza, non latenza UI, consumo energetico o frequenza reale dei risvegli macOS; nessuna misura live con account reale eseguita.

### I6 — Separare ripristino e salvataggio; non pubblicare valori identici

**Riepilogo D05 integrato tramite PR #93.** Restore valido senza riscritture, decoder detached con controllo generazione/identità, migrazione legacy una tantum e nuovi risultati persistiti. Misura finale, test e limiti nella consegna D05; non ripetere il fix.

**D06 — Implementata nella PR collegata a [#94](https://github.com/tommaso-vaccari/BeepBar/issues/94).** `refreshCourseList` confronta i corsi dopo ordinamento prima di assegnare `@Published`; `restoreScopes` confronta la selezione canonica con il valore persistito prima di salvarlo. Ripara comunque valori mancanti, duplicati o obsoleti. Le guardie esistenti su cartelle e selezione, errori e feedback sono conservate. Dieci refresh identici via rete mock: pubblicazioni corsi 10→0, scritture selezione 10→0. Riordino remoto equivalente ignorato; rinomina/rimozione ancora pubblicate, selezione cambiata salvata una volta. Otto assertion falliscono sul codice originale; suite mirate refresh/finalizzazione/Risparmio dati verdi. Suite completa, build Release, review e CI sono gate registrati nella PR/issue. Il conteggio dimostra meno lavoro, non latenza o fluidità UI: misure visive restano D07.

**Indagine separata dopo I7:** encoding di un nuovo risultato da 15k dettagli costa circa 19 ms nella calibrazione sintetica e resta nel percorso esistente. Misurare occupazione main a fine sync con fixture UI isolate. Se il costo viola il budget, progettare persistenza ordinata asincrona: snapshot immutabile, ordine dei risultati, invalidazione account/root, errori, flush al quit e nessuna perdita dell’ultimo risultato. Non basta detached fire-and-forget; definire questi gate prima del fix. D05 non dimostra il budget globale UI ≤16 ms.

### I7 — Predisporre misure ripetibili di UI e avvio

**Intervento:** fixture UI con preferenze univoche, credenziali sintetiche, DB/root temporanei, rete mock, scheduler e aggiornamenti reali disattivati. Riutilizzare l’iniezione delle dipendenze. Non avviare una build locale che condivida identità e dati con l’app installata. Conservare soltanto strumenti utili, senza dati personali.

Aggiungere signpost per icona pronta, finestra pronta, primo contenuto corsi, Attività e Registrazioni. `ui.configurationWindow` da solo non misura la visibilità dei dati. Scenari: avvio freddo/caldo/offline, riapertura durante sync, 100/500 corsi, un corso Attività espanso con 1k/15k elementi, registrazioni con 1k/5k elementi e raffiche di progresso.

**Accettazione:** un comando documentato per fixture, Release arm64 e almeno cinque run confrontabili con tracce del main thread. Verificare i budget e riportare separatamente primo contenuto e finestra key. Osservazione idle di 30 minuti e memoria dopo dieci cicli apertura/sync/chiusura; distinguere controlli pianificati da polling inutile. Ampliare i campioni prima di affermare un p95 affidabile. Dipendenza per le misure I8/I10, non ostacolo ai fix I1/I2.

### I8 — Mostrare i corsi conosciuti prima della rete

**Evidenza:** il controller nasce con lista vuota e il caricamento all’apertura dipende da bootstrap e refresh remoto. Non esiste una cache persistente della lista corsi per la presentazione; gli scope locali da soli non ne costituiscono l’intero contenuto.

**Intervento:** snapshot limitato e versionato, per sito/account, con data e stato di aggiornamento espliciti. Caricarlo indipendentemente dalla rete e riconciliare in background. Non trattare iscrizioni salvate come autorizzazione aggiornata e non saltare metadati sync sulla base della cache. Cartelle dal DB autorevole; invalidazione a logout/cambio sito/account e rifiuto dei risultati tardivi. Al primo uso senza snapshot, stato di caricamento immediato.

**Accettazione:** I7 dimostra primo contenuto noto senza attesa della rete, offline e durante sync. Test account A→B, cambio sito/root, cache corrotta/vecchia, corsi rimossi/rinominati e refresh tardivo. Limiti di dimensione/età espliciti e verificati; nessun token nello snapshot. Confrontare latenza e byte persistiti. È una feature con design e review, non una semplice memoizzazione.

### I9 — Registrazioni: correttezza e risorse

**I9a — Integrata con D01 #89 (dev `39683c2`).** La regressione `removedQueuedCourseDoesNotLoad(copy:staleSelection:)` verifica rimozione/riselezione, spinner e azioni Play/Copia. Review e 605 test/Release/CI verdi. Prove nella PR collegata. Non ripetere il fix: mantenere la regressione nei cambi successivi alle registrazioni.

**I9b — Fix proposto per [#106](https://github.com/tommaso-vaccari/BeepBar/issues/106), [PR #131](https://github.com/tommaso-vaccari/BeepBar/pull/131) aperta verso dev, non ancora integrata.** Finding ricontrollato su dev `ac68333`: cap globale 5.000 presente. Storico SQLite esatto indicizzato per account/corso/anno, baseline e ID transazionali, query soltanto sugli ID correnti e cache pagine 2 MiB. Nessuna eviction automatica: rimozioni temporanee/corsi deselezionati non dimostrano che gli ID siano inutili; reset a disattivazione/logout/cambio account tramite namespace UUID persistito, invalidazione worker e cleanup serializzata, ritentata se fallisce. Migrazione v1 conserva sopravvissuti/baseline solo con owner della sessione verificato: ID già persi restano nuovi finché riconosciuti, senza promessa di recupero esatto. Date non usate come checkpoint. Prima review ha rifiutato il checkpoint `30c7f14`: lookup Debug 10k ID ~52,5 ms sul main, reset poco affidabile con delete fallita, snapshot non atomici e aggregato duplicato. Iterazione sposta SQLite in actor seriale, isNew solo memoria, lista/stato visto pubblicati insieme, reset tombstone e revisioni per read/ack concorrenti, aggregato rimosso. Costo disco: 5.001 ID32char 299.008 B, 10k ID 581.632 B; memoria proporzionale agli elenchi in uso. Prove/comandi/limiti nel [report #106](reports/recordings-seen-overflow.md); confronti UI base-dev→HEAD/main→HEAD non misurati, nessuna fluidità app-wide rivendicata. Review indipendente e sette mutation rosse hanno approvato l’implementazione `378175a`; 671 test e Release verdi su quel commit. Ripresa PR #131: merge `b0a5477` con dev `713033c`, conflitti risolti mantenendo Watchlist e storico atomico; full suite 696 PASS, fixture aggiornata `8b1e67e` 57 PASS. Review indipendente integrazione `7491f27` approvata, full suite 696 PASS e Release verde; follow-up import POSIX esplicito Darwin/Glibc per Linux Core, esecuzione Linux non disponibile locale. CI online resta gate; frequenza reale oltre soglia non misurata.

**I9c — I/O sessione sul main (performance).** `RecordingsSessionStore.swift:33/39` legge/scrive sincronicamente; il controller main-actor lo usa nel ripristino e in `saveSession` (589). Ingresso pagina e avvio worker possono rileggere la stessa sessione. Spostare serializzazione e I/O su un esecutore dedicato e riusare uno snapshot validato nel ciclo di apertura. Preservare atomicità e ownership. La fingerprint evita già salvataggi identici: mantenerla. Serializzare save/delete e validare un’epoca di sessione al commit nello store; una guardia nel controller prima di un `await` non basta a evitare una riscrittura successiva al logout. Conservare permessi 0700/0600 e rename atomico. Accettazione: niente I/O sul main nelle tracce I7; store lento non blocca la UI; logout/disattivazione/cambio account impediscono che una scrittura tardiva ricrei la vecchia sessione. Conservare i test di lifecycle.

**I9d — Play attende una lista di background già in corso (miglioria).** `drain` aspetta una richiesta per volta; inserire Play in testa supera soltanto i job ancora accodati. Il test esistente `aPlayDroppedWithTheBatchSaysWhy` esercita già questo ordine. Misurare con lista lenta/bloccata prima di introdurre annullamento per job e preemption. Se implementato: Play parte rapidamente nonostante una lista non pertinente; un solo driver controlla il browser; ultimo click prevalente; liste interrotte ancora necessarie riprendibili. Non navigare contemporaneamente sullo stesso WebView.

### I10 — Limitare il lavoro delle grandi liste

**Attività — D11 integrata tramite PR [#139](https://github.com/tommaso-vaccari/BeepBar/pull/139) ([#99](https://github.com/tommaso-vaccari/BeepBar/issues/99)).** Finding originale: `ActivityPage.swift` costruiva tutte le righe di file/spostamenti/errori di un corso espanso in un `VStack` interno; il `LazyVStack` esterno rende lazy i corsi, non le righe. Intervento: paginazione limitata con modello di riga puro in Core (`ActivityRowLayout`, `nonisolated static`). Un corso espanso costruisce solo le prime 200 righe (errore corso, nuovi/aggiornati, spostati, non aggiornati, nell’ordine di prima) e visita solo quelle; «Mostra altri N» rivela passi crescenti (200, 400, 800… fino al totale: 15000 righe dopo sette clic su «Mostra altri») e l’ultimo passo termina esattamente sull’ultima riga. Le righe mostrate sono sempre un prefisso del corso: ID `corso/tipo/idRemoto` stabili tra refresh, univoci tra corsi e tipi (lo stesso id remoto aggiornato e spostato nello stesso sync resta distinto), suffisso deterministico per eventuali ripetizioni nello stesso gruppo. Le righe rivelate tornano a una pagina quando il corso viene chiuso o arriva un nuovo riepilogo, così una nuova espansione non ricostruisce tutto. Azioni (clic apre, menu contestuale mostra nel Finder), segnalazione problemi, hint di accessibilità, «Mostra nel Finder» della cartella e testi via `tr` conservati; nessuna modifica a dati persistiti o alla sync.

**Criterio #99 soddisfatto solo in parte:** primo elemento ed espansione sono limitati a una pagina, ma raggiungere l’ultima riga di un corso grande costruisce ancora tutte le righe fino a essa (`VStack` interno non lazy; l’ultimo passo di un corso da 15000 righe passa da 12800 a 15000). Il costo resta richiesto esplicitamente dall’utente, non pagato all’apertura.

Evidenza: undici test in `Tests/BeepbarCoreTests/ActivityRowLayoutTests.swift` (ordine e contenuto, taglio pagine tra gruppi senza salti/ripetizioni, univocità tra tipi e corsi, id ripetuto stabile tra pagine, stabilità tra refresh, limiti e clamp, multiplo esatto senza pagina vuota, passi fino a 15000, corso vuoto/una riga, testi, ritorno a una pagina). Mutazioni controllate su copia usa e getta (prefisso tipo rimosso dagli id, ordine spostati/falliti invertito, clamp rimosso, passo costante, suffisso duplicati rimosso, reset rimosso) fanno fallire le asserzioni attese: dettagli nella PR. `swift test` completo (678 test) e build Release CI verdi in locale (Apple M2, macOS) su `9543abe`; CI macOS verde sullo stesso SHA. **Non misurato:** budget di espansione/scorrimento (I7 1k/15k), occupazione main, allocazioni e confronti base dev → HEAD / main → HEAD, perché l’harness UI di D07 non è integrato; la riduzione dimostrata è strutturale (righe costruite ≤ mostrate), non una misura. Prossimo passo dopo D07: misurare espansione e «Mostra altri» con 1k/15k elementi e valutare un `LazyVStack` interno per rendere lazy anche le pagine già rivelate.

**Registrazioni:** ordinamento/raggruppamento, filtri e scansioni `newCount` si ripetono con aggiornamenti del controller osservato. Profilare `RecordingsPresentation` e `RecordingsPage`; solo dopo introdurre cache derivate per revisione effettiva della lista e input di presentazione. Invalidare per lingua/fuso orario, ricerca e stato visto. Confrontare allocazioni, valutazioni dei body e scorrimento. Se visite a molti corsi/anni mostrano crescita, definire retention limitata di liste e URL playback, preservando la riapertura immediata già prevista.

### I11 — Errori nelle opzioni benchmark rifiutati prima del lavoro

**Consegna [#108](https://github.com/tommaso-vaccari/BeepBar/issues/108).** Il parser condiviso col test valida opzioni per comando, duplicati, valori mancanti e domini numerici prima di creare output o avviare scenari. `baseline --output` ora termina con usage/64; il flag resta `--out`. Controllate anche somme dei campioni/arrotondamento del corpus e conversioni MiB: input non rappresentabili non causano trap. Default, warmup zero e opzioni valide conservati; `--json` per scenari/idle, `--out` per baseline.

Prova red/green: il parser originale produce 20 assertion fallite; la review ha trovato overflow, riprodotti con altre cinque assertion fallite prima della correzione. Il parser finale passa 37 casi parametrizzati. Il binario Release rifiuta sette invocazioni invalide con exit 64, usage e nessun output; una sync sintetica da un file conserva JSON e successo. Review indipendente reiterata fino a CLEAN. Suite completa, build Release e CI sono gate della PR collegata alla issue. Nessun miglioramento runtime dell’app rivendicato.

## Indagini con una condizione precisa per procedere

Sono attività concrete di verifica, non ottimizzazioni già giustificate.

**R06 / [#114](https://github.com/tommaso-vaccari/BeepBar/issues/114), checkpoint 2026-10-09.** Verificata l’unica failure del run `37899467406`, attempt 1, nell’assertion di riavvio dopo `markSeen`; attempt 2 verde sullo stesso SHA `39683c2ba7b173672ece501f57054e37085a45d5`. Controller e test invariati su dev `ac68333265a68b3f1e01e7f0958c3aae31cc7850`. Analizzati ordine pubblicazione/defaults e isolamento UUID delle fixture; la causa resta non confermata. La toolchain locale Command Line Tools non compila le macro Testing/SwiftUI e non esegue xcodebuild: zero ripetizioni completate, suite e Release non verificate sul candidato. Nessun fix, nessuna chiusura: restano ripetizioni isolate/parallele con account distinti e cattura defaults/pubblicazioni prima del riavvio. [Rapporto con comandi, evidenze e prossimo esperimento](recordings-acknowledgement-investigation.md). Confronti prestazionali base dev → HEAD / main → HEAD non applicabili a questa consegna documentale; nessun beneficio runtime rivendicato.

| Candidato | Prossimo esperimento e criterio decisionale |
|---|---|
| Migrazioni ripetute all’avvio | Concluso da R02 ([#134](https://github.com/tommaso-vaccari/BeepBar/pull/134)): nessuna guardia di versione. Le aperture successive costano ~1,1 ms a 15k file (~5,7 ms a 100k) senza scritture di righe o pagine, fuori dal main actor; la riparazione una tantum ~7,5 ms a 15k. Riaprire solo se lo scenario `startup` supera i budget o se la migrazione inizia a scrivere ad ogni avvio. |
| Attraversamento directory e flag | Contare `openat`/stat/fchflags in `FileStore.directoryFD` ed `existingRegularFiles` su percorsi profondi/condivisi. Provare un riuso limitato all’operazione solo con beneficio CPU misurato. Preservare no-follow, contenimento, sostituzione root e permessi; non eliminare i controlli di esistenza locale. |
| JavaScript dopo chiusura/annullamento | `RecmanWebSession.run` (419) usa una continuation per `callAsyncJavaScript` senza timeout/cancellazione propri. Riprodurre Promise irrisolta e chiusura in WebView isolato; verificare se le callback native liberano il task. Introdurre completamento limitato e una sola volta se emerge hang/retention. Non è un leak di produzione già confermato. |
| Metadati incrementali Moodle | Concluso da R05 ([#143](https://github.com/tommaso-vaccari/BeepBar/pull/143)): non implementare cursori temporali né `core_course_check_updates`/`core_course_get_updates_since`. Non vedono moduli rimossi, spostamenti, rinomine di sezione, visibilità/gruppi e non riducono le richieste; la scansione completa per corso resta il contratto. Nessuna riduzione di frequenza. |

## Garanzie tecniche da preservare

- SQLite FULL, journal, installazione atomica e recupero restano vincoli. I test di processo non dimostrano la resistenza alla perdita di alimentazione; intervenire su `fsync` richiede una verifica di durabilità dedicata.
- L’ultimo hash prima di eliminare il vecchio inode protegge scritture da descrittori già aperti o mmap. Ogni riduzione dei controlli deve fornire una garanzia equivalente, provata contro modifiche concorrenti.
- Conservare memoria limitata durante elaborazione dei file grandi, assenza di scritture DB invarianti inutili, corretto completamento UI e uscita dal menu. Un’ottimizzazione non deve reintrodurre regressioni in questi percorsi.
- La specifica §6 governa Low Power Mode e Risparmio dati. Modificarne pause e ripresa è un cambiamento di comportamento, da decidere e documentare separatamente.

### Verifica CI dopo I1/I9b — #145

La run dev [38074940605](https://github.com/tommaso-vaccari/BeepBar/actions/runs/38074940605), base `6e64e4e`, è fallita nelle assertion di selezione persistita e rilancio dopo reset dello storico. I due test isolati, la suite completa (727 test) e 20 ripetizioni delle suite controller sono passati localmente sulla base: la causa CFPreferences è un’ipotesi, non un bug produzione riprodotto. Il follow-up [#145](https://github.com/tommaso-vaccari/BeepBar/issues/145) isola in memoria le preferenze delle sole fixture controller e chiude il browser originario prima del rilancio simulato; conserva assertion e test reali cross-handle di persistenza. La regressione della fixture verifica getter tipizzati, conteggio scritture, rimozione, isolamento e assenza di scritture nel dominio persistente. Review indipendente clean; 30 ripetizioni delle suite mirate (65 test) verdi. Ripristinando la fixture nativa, la nuova regressione fallisce (dominio persistente e conteggio rimozione). Suite completa, Release e CI sul commit finale sono gate della PR; nessuna modifica runtime o beneficio prestazionale rivendicato, confronti base dev/main non applicabili.
