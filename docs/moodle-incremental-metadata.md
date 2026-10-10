# R05 — Metadati incrementali Moodle: fattibilità, copertura e decisione

Issue: [#113](https://github.com/tommaso-vaccari/BeepBar/issues/113). Indagine documentale, nessuna modifica al codice. Risponde alla riga «Metadati incrementali Moodle» di [performance-plan.md](performance-plan.md#indagini-con-una-condizione-precisa-per-procedere).

**Esito in una riga:** Moodle espone API di «aggiornamenti dal timestamp» (`core_course_check_updates`, `core_course_get_updates_since`), ma per costruzione non segnalano rimozioni, spostamenti tra sezioni, rinomine di sezione, file cancellati dentro una cartella né cambi di visibilità/gruppo; usano confronti stretti su timestamp del server e non riducono il numero di richieste per corso. Un sync corretto dovrebbe comunque eseguire la scansione completa per coprire quei casi, quindi non c'è risparmio da ottenere senza ridurre copertura o freschezza. **Decisione: la scansione completa per corso resta l'unico percorso; nessuna implementazione incrementale.** I dettagli, le fonti e i rilievi collaterali seguono.

## 1. Metodo e limiti dell'indagine

- Fonti primarie: sorgente ufficiale `moodle/moodle`, branch `main`, commit `f20534726a59a4b64d168bc4a70fc9518251613e` (3 ottobre 2026), `public/version.php` = `6.0dev (Build: 20261005)`. Nel branch `main` l'albero vive sotto `public/`; nelle release 4.x/5.0 gli stessi file stanno alla radice (es. `course/externallib.php`). Le annotazioni `@since` nel sorgente datano ogni funzione alla versione che l'ha introdotta e valgono anche per i siti più vecchi.
- Dall'ambiente di lavoro `docs.moodle.org`, `moodledev.io` e `tracker.moodle.org` non erano raggiungibili (DNS negato) e `raw.githubusercontent.com` rispondeva 404: la verifica è stata fatta su un clone shallow del repository. Gli URL delle pagine pubbliche sono riportati in §9 per la review a campione e per il lettore; le citazioni con riga si riferiscono al commit sopra.
- Nessuna chiamata al servizio reale, nessun token, nessun dato di account. Il set di funzioni che WeBeep abilita per il servizio usato dall'app non è verificabile offline: BeepBar lo riceve già in `core_webservice_get_site_info` (`functions[].name`) e lo conserva in `WeBeepSiteInfo.availableFunctions`; un controllo futuro può leggerlo da lì senza esporre il token (§7).
- Nessuna misura di prestazioni: non ci sono numeri «prima/dopo» perché non viene proposta alcuna modifica. Le stime di richieste e byte in §6 sono conteggi derivati dalle firme delle API, non misure.

## 2. Come BeepBar usa i metadati oggi

Codice su `dev` `713033c`.

| Passo | Funzione Moodle | Dove | Cosa ne ricava |
|---|---|---|---|
| Validazione token | `core_webservice_get_site_info` | `WeBeepAPIClient.validateToken` | `userid`, `siteurl` (deve coincidere con il sito atteso), elenco `functions`: l'app rifiuta un sito senza `core_enrol_get_users_courses` e `core_course_get_contents` (`missingRequiredFunction`). Limite risposta 1 MiB. |
| Elenco corsi | `core_enrol_get_users_courses` (`userid`) | `WeBeepAPIClient.fetchCourses` | `id`, `shortname`, `displayname/fullname`, `visible`, `startdate`, `enddate`. Limite 2 MiB, max 2000 corsi. |
| Contenuti di ogni corso selezionato | `core_course_get_contents` (`courseid`, senza `options`) | `WeBeepAPIClient.fetchContents`, una richiesta per corso, concorrenza `mode.metadataConcurrency` in `SyncCoordinator.prepareItems` | Sezioni → moduli → `contents[]` di tipo `file`: `filename`, `filepath`, `filesize`, `timemodified`, `fileurl`, `isexternalfile`, e `contenthash` se presente. Limite 4 MiB, max 1000 sezioni. |
| Download | `fileurl` (`webservice/pluginfile.php`) | `RemoteDownloader` | Solo URL del sito, senza credenziali in query. |

Dalla risposta di `core_course_get_contents` dipendono tutte le garanzie della specifica ([IT](sync-behavior.it.md), [EN](sync-behavior.en.md)):

- **Identità del file** = `"\(courseID):\(module.id):\(filepath):\(filename)"`. Un cambio di modulo cambia identità (nuovo file + file sparito); un cambio di sezione no.
- **Revisione** = `contenthash` se Moodle lo fornisce, altrimenti `"\(timemodified):\(filesize)"`. `SyncPlanner.decide` confronta la revisione con la baseline per distinguere «nessuna operazione» da «adotta la nuova baseline»; il contenuto reale viene comunque verificato con l'hash locale quando serve.
- **Posizione locale** = cartella corso + nome sezione (salvo «material…») + nome modulo + `filepath` (`LocalPathPolicy.destination`). `RemotePlacement` registra `(sectionName, moduleName, isSingleFileResource)`: la **rinomina di una sezione o di un modulo** e lo **spostamento in un'altra sezione** sono rilevati confrontando i nomi presenti nella risposta completa (`followRemoteMoves`, §4.1 della specifica).
- **Rimozioni e ricaricamenti** (§4.2–4.3): un file tracciato conta come sparito solo se il suo corso è stato elencato **per intero** (`RemoteCourseContents.isComplete`) e il suo modulo non ha voci scartate (`modulesWithDroppedEntries`); altrimenti «non conoscibile in questo sync» e le scelte già aperte restano. Il ricaricamento altrove è riconosciuto solo con `contenthash` identico e univoco nel corso.
- **Visibilità e gruppi**: non esiste gestione esplicita. Moodle omette dalla risposta i moduli non visibili all'utente (vedi §4), quindi «modulo nascosto» appare come «file rimosso» e la voce sparisce quando torna visibile, esattamente come descritto in §4.3 della specifica. Un corso che il sito rifiuta è un errore di quel corso (`courseFailure`), non del sync; se tutti i corsi falliscono con errori di sito/connessione, fallisce il sync.
- **Risposte incomplete ed errori**: `LossyArray` scarta la singola voce malformata, contando `issueCount` e marcando modulo/corso come incompleti; errori HTTP, content-type, dimensione, redirect e `invalidtoken` hanno mappature dedicate (`WeBeepAPIError`, `SyncServiceFailure`).
- **Checkpoint**: i metadati sono letti ogni run e usati solo per quel run; non esiste un cursore persistente «ultimo timestamp visto». Lo stato durevole è nelle baseline, nei placement, nei conflitti e nel journal (`SyncTransactionCoordinator`), che un run interrotto lascia recuperabili. Un run con nulla di nuovo non scrive (budget «Run with nothing new»).

Il «costo di un run invariato» lato rete è quindi: 1 richiesta corsi + N richieste contenuti (N = corsi selezionati) + i byte JSON di ogni corso intero. Le verifiche locali (file cancellati sul Mac, file modificati, conflitti) non dipendono dai metadati e restano dovute in ogni caso (principio 4 del piano).

## 3. Funzioni candidate: versione, servizio, permessi, firma

Tutte dichiarate in `public/lib/db/services.php` (o nei `db/services.php` del plugin) con `'services' => [MOODLE_OFFICIAL_MOBILE_SERVICE]`: sono disponibili a un token del servizio mobile ufficiale, oppure a un servizio personalizzato in cui l'amministratore le ha aggiunte. Nessuna di queste richiede capability aggiuntive rispetto all'accesso al corso (`validate_context` sul contesto corso o modulo), tranne dove indicato.

| Funzione | `@since` | Firma (parametri → ritorno) | Dichiarazione | Nota |
|---|---|---|---|---|
| `core_course_get_contents` | 2.2; `options` 2.9; campi file `mimetype`, `isexternalfile`, `repositorytype`, `uservisible`, `availabilityinfo` 3.3 | `courseid`, `options[{name,value}]` con `excludemodules`, `excludecontents`, `includestealthmodules`, `sectionid`, `sectionnumber`, `cmid`, `modname`, `modid` → `[section{id,name,…,modules[{id,name,modname,uservisible,…,contents[]}]}]` | `services.php:552–560`, `'capabilities' => 'moodle/course:update, moodle/course:viewhiddencourses'` (documentative: la funzione lavora anche senza, limitandosi a ciò che l'utente vede) | È la funzione usata oggi. `course/externallib.php:59–135` (parametri), `93–445` (corpo). |
| `core_course_check_updates` | 3.2 | `courseid`, `tocheck[{contextlevel:'module', id:cmid, since}]`, `filter[]` ∈ {`configuration`, `fileareas`, `completion`, `ratings`, `comments`, `gradeitems`, `outcomes`} → `{instances[{contextlevel,id,updates[{name,timeupdated?,itemids?}]}], warnings[]}` | `services.php:744–752` | `course/externallib.php:3538–3665`; delega a `course_check_updates` (`course/lib.php:3216–3270`). |
| `core_course_get_updates_since` | 3.3 | `courseid`, `since`, `filter[]` → come sopra | `services.php:753–761` | `course/externallib.php:3667–3760`: costruisce `tocheck` con **tutti i moduli `uservisible`** del corso e chiama `check_updates`. |
| `core_course_get_course_module` | 3.0 | `cmid` → `{cm{id,course,module,name,modname,instance,section,sectionnum,groupmode,visible,…}, warnings}` | `services.php:561–568` | Un modulo per richiesta, **senza** l'elenco dei file. `course/externallib.php:2963`. |
| `core_course_get_course_module_by_instance` | 3.0 | `module`, `instance` → come sopra | `services.php:569–576` | Idem. |
| `mod_resource_get_resources_by_courses` | 3.3 | `courseids[]` (vuoto = tutti i corsi dell'utente) → `{resources[{id,coursemodule,course,name,intro,…,contentfiles[]}], warnings}` | `mod/resource/db/services.php`, `'capabilities' => 'mod/resource:view'` | Più corsi in una richiesta, ma solo moduli `resource`; `contentfiles` via `util::get_area_files` (`filename, filepath, filesize, fileurl, timemodified, mimetype, isexternalfile, repositorytype`); **nessun nome di sezione**. `mod/resource/classes/external.php:127–170`. |
| `mod_folder_get_folders_by_courses` | 3.3 | `courseids[]` → `{folders[…], warnings}` | `mod/folder/db/services.php`, `'capabilities' => 'mod/folder:view'` | La descrizione ufficiale avverte: «this WS is not returning the folder contents». `mod/folder/classes/external.php:126–167`. |
| `core_files_get_files` | 2.2; campi aggiuntivi 2.9 | `contextid`, `component`, `filearea`, `itemid`, `filepath`, `filename`, `modified` («timestamp to return files changed after this time»), `contextlevel`, `instanceid` → `{parents[], files[]}` | `services.php:952–959` | Un contesto (= un modulo) per richiesta; browsing, non elenco di corso. `files/externallib.php:52–200`. |
| `core_webservice_get_site_info` | 2.2 | `serviceshortnames[]` → `{userid, siteurl, functions[{name,version}], release?, version?, advancedfeatures[], …}` | `services.php:2842–2849` | Già usata: `functions` è l'elenco autorevole di ciò che il token può chiamare. `webservice/externallib.php:63–236`. |
| `core_enrol_get_users_courses` | 2.2 | `userid`, `returnusercount` → `[{id, shortname, fullname, displayname, visible, hidden, startdate, enddate, lastaccess, …}]` | `services.php:901–909`, `'capabilities' => 'moodle/course:viewparticipants'` (documentativa) | Già usata. Nessun timestamp di «ultimo cambiamento dei contenuti». `enrol/externallib.php:406–570`. |
| `tool_mobile_call_external_functions` | 3.7 | `requests[{function, arguments(JSON), settingfilter, settingfileurl, settinglang}]` → `{responses[{error, data, exception?}]}` | `admin/tool/mobile/db/services.php:76–83`, `'type' => 'write'` | Batching di più funzioni in una richiesta HTTP. `admin/tool/mobile/classes/external.php:506–`. |
| `tool_mobile_get_config`, `tool_mobile_get_public_config`, `tool_mobile_get_content`, `tool_mobile_get_plugins_supporting_mobile` | 3.2–3.5 | configurazione del sito / contenuti per l'app mobile | `admin/tool/mobile/db/services.php` | Non riguardano i contenuti dei corsi: nessun uso per il sync. |

## 4. Cosa segnalano davvero `check_updates` e `get_updates_since`

Lettura di `course/lib.php:3216–3270` (`course_check_updates`) e `3690–3790` (`course_check_module_updates_since`), più i callback `resource_check_updates_since` (`mod/resource/lib.php:561–564`) e `folder_check_updates_since` (`mod/folder/lib.php:806–809`), entrambi `course_check_module_updates_since($cm, $from, ['content'], $filter)`.

Per ogni modulo richiesto:

1. `get_fast_modinfo($course)->get_cm($id)` fallisce per un modulo **cancellato** o di un altro corso → warning `cmidnotincourse` (solo in `check_updates`, dove il client passa gli id; `get_updates_since` enumera i moduli esistenti e visibili, quindi un modulo cancellato semplicemente **non compare**).
2. `!$cm->uservisible` → warning `nonuservisible` in `check_updates`; **saltato in silenzio** in `get_updates_since`. `uservisible` incorpora visibilità del modulo e della sezione, restrizioni di accesso (date, gruppi, raggruppamenti, completamento) e iscrizione.
3. Modulo senza callback `<mod>_check_updates_since` → warning `missingcallback`. Lo implementano 21 moduli core, inclusi `resource`, `folder`, `book`, `imscp`, `page`, `url`, `label`; i sei che esportano file in `get_contents` (`book`, `folder`, `imscp`, `page`, `resource`, `url`) lo implementano tutti.
4. Aree valutate (ridotte con `filter`):
   - `configuration`: `updated = $mod->timemodified > $from`, dove `$mod` è la **riga dell'istanza** (`{resource}`/`{folder}`), non `course_modules`.
   - `fileareas`: `get_area_files(contextid, 'mod_<x>', ['content','intro'], …, $updatedsince = $from)` → SQL `f.timemodified > :time` (`lib/filestorage/file_storage.php:619–640`); riporta `contentfiles`/`introfiles` con gli `itemids` (id delle righe `files`) dei soli file **esistenti** con timestamp maggiore.
   - `completion`, `gradeitems`, `outcomes`, `comments`, `ratings`: non pertinenti ai file.
5. La risposta include **solo** le istanze con almeno un'area `updated = true` (`course/externallib.php:3595–3620`); il resto è silenzio, indistinguibile da «modulo non controllato».

Quali operazioni del docente toccano `timemodified` dell'istanza o delle righe `files` (verificato in `course/format/classes/local/cmactions.php`, Moodle 5.2+/6.0; le funzioni globali `set_coursemodule_*`/`moveto_module` di `course/lib.php` vi delegano):

| Operazione su Moodle | `configuration` | `contentfiles` | Nota |
|---|---|---|---|
| Carica/sostituisce un file in resource/folder | sì (salvataggio form: `resource_update_instance` imposta `timemodified`) | sì (nuova riga `files`) | Coperto. |
| Cancella un file dentro una cartella (`folder`) | solo se il docente salva il form del modulo; non con la cancellazione inline del file manager | **no**: una riga cancellata non ha timestamp da confrontare | Non coperto in modo affidabile. |
| Rinomina il modulo | sì (`cmactions::rename` scrive `timemodified` sull'istanza; test `test_check_updates`, `course/tests/externallib_test.php:3297`) | — | Coperto, ma senza il nuovo nome: serve comunque una `get_contents`. |
| Nasconde/mostra il modulo | sì (`cmactions::set_visibility` scrive `timemodified` sull'istanza) | — | Nascosto: il modulo diventa non `uservisible` e **sparisce** dalla risposta di `get_updates_since` senza alcuna segnalazione. Mostrato: compare come `configuration`. |
| Sposta il modulo in un'altra sezione (`move_before`, `move_end_section`) | **no** (`course_add_cm_to_section` aggiorna `course_modules.section` e `course_sections.sequence`) | no | Non coperto: BeepBar lo tratta come spostamento (§4.1 della specifica) e lo rileva solo dal nome sezione nella risposta completa. |
| Rinomina una sezione | no (tabella `course_sections`) | no | Non coperto; `check_updates` supporta solo `contextlevel = 'module'` (warning `contextlevelnotsupported`). |
| Cancella il modulo | nessuna voce (`get_updates_since`) / `cmidnotincourse` (`check_updates` con id espliciti) | — | Coperto solo chiedendo esplicitamente ogni modulo noto: N moduli nella richiesta, e un modulo mai visto dall'app non può essere chiesto. |
| Cambia restrizioni di accesso, gruppi, raggruppamento | dipende dal percorso di salvataggio (`course_modules.availability`, non l'istanza) | no | Il modulo può entrare/uscire da `uservisible` senza traccia. |
| Nasconde/mostra una sezione | no | no | Tutti i moduli della sezione escono/entrano da `uservisible` senza traccia. |
| Cambia iscrizione o visibilità del corso | — | — | `validate_context` fallisce (eccezione), come oggi. |

Semantica temporale: tutti i confronti sono `> $from` con timestamp **del server** (`time()` di PHP). Un `since` calcolato dall'orologio del Mac è esposto allo skew; un `since` uguale all'ultimo `timemodified` visto perde ogni modifica avvenuta nello stesso secondo; un run fallito a metà richiede di non avanzare il cursore, cioè uno stato persistente nuovo per corso, con migrazione e rollback (principio 8).

## 5. Copertura: scansione completa contro incrementale + fallback

Eventi che la specifica obbliga a gestire e come li vede ciascun approccio. «Incrementale» = `core_course_get_updates_since(courseid, since)` per corso, seguita da `core_course_get_contents` con `cmid` per i soli moduli segnalati.

| Evento | Scansione completa (oggi) | Incrementale | Serve il fallback completo? |
|---|---|---|---|
| Nuovo file in un modulo esistente | sì | sì (`contentfiles`) | no |
| Nuovo modulo con file | sì | sì (`configuration`: istanza creata dopo `since`) | no |
| File sostituito (stesso nome) | sì, via `timemodified:filesize` o `contenthash` | sì | no |
| File cancellato da una cartella (§4.3) | sì (manca dall'elenco completo) | **no** | sì |
| Modulo cancellato (§4.3) | sì | no con `get_updates_since`; sì con `check_updates` solo per id già noti | sì |
| Modulo spostato di sezione (§4.1) | sì (nome sezione) | **no** | sì |
| Sezione rinominata (§4.1: «tutti i file che contiene seguono il nuovo nome») | sì | **no** | sì |
| Modulo rinominato (§4.1) | sì | segnalato, ma il nome arriva solo con `get_contents` | parziale |
| Modulo/sezione nascosti (§4.3: «appare come rimosso») | sì | **no** (silenzio) | sì |
| Modulo/sezione di nuovo visibili («la voce sparisce») | sì | sì come `configuration` solo per il modulo; non per la sezione | sì |
| Restrizioni di gruppo/accesso che cambiano `uservisible` | sì | **no** | sì |
| File ricaricato altrove con stesso `contenthash` (§4.2) | sì, quando il sito fornisce `contenthash` | no (nuovo e sparito arrivano in run diversi o mai) | sì |
| Risposta incompleta/voce malformata | gestita per modulo e per corso (`isComplete`) | i `warnings` coprono solo id chiesti; il silenzio non è distinguibile | sì |
| Corso non più accessibile | errore per corso | errore per corso | — |
| Clock skew / stesso secondo | non applicabile | perdita silenziosa | sì |
| Run interrotto | nessuno stato da riconciliare | cursore da non avanzare, nuova persistenza | — |

Ne segue che l'incrementale non può sostituire la scansione completa per nessun run: ogni voce «sì» nell'ultima colonna è un evento che, senza la risposta completa, resterebbe invisibile per sempre (non «in ritardo»: `get_updates_since` non lo segnalerà mai nemmeno al run successivo). Un «fallback periodico» (ad esempio una scansione completa ogni K run) sarebbe esattamente «rilevare gli spostamenti e le rimozioni con meno frequenza di quella scelta dall'utente»: una riduzione di freschezza, vietata dal principio 5 e dal piano («Freshness is not a budget to cut»).

## 6. Costo: richieste e byte

Notazione: N corsi selezionati, M_c moduli con file nel corso c, U_c moduli con aggiornamenti nel corso c dall'ultimo run.

| Approccio | Richieste per run | Byte per run | Note |
|---|---|---|---|
| Completa (oggi) | 1 + N | elenco corsi + Σ_c (JSON intero del corso c) | Il JSON intero include anche moduli non-file (forum, pagine, url) e campi non usati (descrizioni HTML, completamento, date). |
| Incrementale con fallback corretto | 1 + N (`get_updates_since`) + Σ_c U_c (`get_contents` con `cmid`) **+ N (`get_contents` completa, per §5)** | ≥ completa | Peggiore in richieste; i byte non scendono perché la completa resta dovuta. |
| Incrementale senza fallback (non ammissibile) | 1 + N + Σ_c U_c | elenco corsi + Σ_c piccola risposta + Σ_c U_c (JSON di un modulo) | Risparmio di byte reale solo nel run invariato; nessun risparmio di richieste (N resta); perde gli eventi di §5. |
| `check_updates` con id espliciti (per coprire le cancellazioni) | come sopra, con corpo di richiesta proporzionale a Σ_c M_c | come sopra | Richiede di inviare ogni modulo noto ad ogni run. |
| `tool_mobile_call_external_functions` (batch) | 1 + ⌈N / k⌉ | come completa | Riduce solo il numero di round trip; la risposta è la concatenazione delle N risposte. |

Osservazioni:

- Il numero di richieste di un run invariato non può scendere sotto 1 + N con le API per corso; l'unica leva su N è il batching (`tool_mobile_call_external_functions`, oppure le funzioni `*_by_courses` che però non danno sezioni e non coprono `folder`). Il batching è neutro per la correttezza (stesse risposte), ma: è una funzione `'type' => 'write'` del servizio mobile (da verificare in `availableFunctions`); una risposta concatenata è grande quanto la somma e va contro il bounding per funzione di I1 (#102) e la concorrenza per corso già usata per l'annullamento; le risposte arrivano insieme invece che man mano. Non è una proposta di questa indagine: senza un conto delle richieste misurato su un corpus realistico (`net.*` del harness, `BenchmarkUpstream`) non si può dire che i round trip siano un costo rilevante rispetto ai byte.
- I byte della scansione completa si possono ridurre solo scartando campi inutili, e `core_course_get_contents` non offre proiezioni: `excludecontents` toglie proprio i file, `modname` filtra un solo tipo per richiesta. Nessuna opzione applicabile.
- Lato locale, il costo di un run invariato è già disaccoppiato dalla dimensione del JSON per quanto riguarda hash e scritture (budget «Run with nothing new»: nessun hash, nessuna scrittura); resta il decode JSON, proporzionale ai byte, che l'incrementale ridurrebbe soltanto nei run in cui non serve il fallback, cioè mai (§5).

Numeri reali non misurati: non esistono misure di byte per corso su WeBeep in repository, e produrle richiederebbe una chiamata autorizzata con account reale (fuori ambito). Il harness registra già `net.contentsRequests` e `net.metadataBytes` per il corpus sintetico; sono i contatori da usare se una proposta futura volesse quantificare il batching.

## 7. Rischi di un'implementazione incrementale

1. **Perdita silenziosa di eventi** (§5): rimozioni, spostamenti, rinomine di sezione, visibilità. Violerebbe §4 della specifica e il principio 1 (le voci «rimosso/spostato» sono ciò che protegge il lavoro locale dalla confusione con i materiali).
2. **Timestamp non autorevoli**: `since` dall'orologio del client, confronti stretti, modifiche nello stesso secondo, modifiche retrodatate da restore/import (il `timemodified` di un file importato è quello originale). Il piano vieta esplicitamente di saltare scansioni su timestamp o cache non autorevoli.
3. **Nuovo stato persistente**: cursore per corso (o per modulo), da non avanzare su run falliti/annullati, da invalidare a cambio account/sito/root, con migrazione e rollback (principio 8). Oggi il sync non ha cursori e questo è parte della sua semplicità di recupero.
4. **Dipendenza da funzioni del servizio mobile**: `check_updates`/`get_updates_since`/`call_external_functions` esistono solo se il servizio del token le include; l'app dovrebbe mantenere due percorsi di codice e due set di test, il secondo non verificabile senza il sito reale.
5. **Interazione con I1 (#102)**: la ricezione limitata è pensata per risposte per corso; un batch o risposte di dimensione variabile per modulo cambiano i limiti e il comportamento al superamento.
6. **Costo di review e battle test** senza beneficio dimostrato: il principio 9 richiede di misurare un percorso concreto prima di intervenire; qui l'analisi delle firme mostra che il risparmio atteso è nullo sotto i vincoli di correttezza.

## 8. Decisione

- **Non implementare** metadati incrementali con `core_course_check_updates` / `core_course_get_updates_since` né con cursori temporali di qualsiasi forma. La scansione completa `core_course_get_contents` per ogni corso selezionato ad ogni run resta il contratto: è l'unica risposta che rende decidibili rimozioni, spostamenti, rinomine e visibilità, ed è ciò su cui `isComplete`/`modulesWithDroppedEntries` fondano la protezione di §4.3.
- **Nessuna riduzione di frequenza** o scansione «ogni K run»: sarebbe una riduzione di freschezza.
- **Nessuna sostituzione** con `mod_resource_get_resources_by_courses` / `mod_folder_get_folders_by_courses` / `core_files_get_files`: non forniscono sezioni, non coprono i contenuti delle cartelle, o moltiplicano le richieste.
- La riga «Metadati incrementali Moodle» del piano si chiude con esito negativo motivato; non resta lavoro aperto su questo tema.
- Idee che restano aperte **solo come indagini future distinte**, ciascuna con una misura prima di qualsiasi codice: (a) batching dei round trip via `tool_mobile_call_external_functions`, condizionato alla presenza in `availableFunctions`, a un conteggio richieste misurato e alla compatibilità con I1; (b) verificare, con autorizzazione esplicita e senza salvare dati reali, se WeBeep restituisce `contenthash` (§9, rilievo 1).

## 9. Rilievi collaterali emersi

1. **`contenthash` non è un campo di `core_course_get_contents`** nel sorgente ufficiale (`course/externallib.php:555–600`, `mod/resource/lib.php:451–477`, `mod/folder/lib.php:320–345`; la cronologia di `course/upgrade.txt` per 3.2/3.3/3.6/3.7 non lo introduce mai). BeepBar lo legge come opzionale e la specifica §4.2 dichiara il riconoscimento del ricaricamento «solo quando Moodle fornisce l'impronta»: comportamento coerente, nessun bug. Va però messo in chiaro che, su un Moodle non modificato, il ramo «ricaricato altrove» non si attiva mai e la revisione è sempre `timemodified:filesize`. Il piano e la specifica non promettono altro; se in futuro si volesse rendere §4.2 effettivo servirebbe un'altra fonte dell'impronta (nessuna funzione tra quelle esaminate la espone).
2. Le `capabilities` elencate in `services.php` per `core_course_get_contents` e `core_enrol_get_users_courses` sono documentative (Moodle le mostra all'amministratore quando crea un servizio); il codice applica solo `validate_context` e la visibilità effettiva. Non cambia nulla per l'app.
3. In Moodle `main` le funzioni globali `course_delete_module`, `set_coursemodule_visible`, `set_coursemodule_name`, `moveto_module` sono deprecate (5.2) a favore di `core_courseformat\local\cmactions`; la semantica dei timestamp descritta in §4 è quella delle nuove classi. Per siti 4.x le funzioni globali scrivevano le stesse tabelle.

## 10. Fonti

Sorgente (commit `f20534726a59a4b64d168bc4a70fc9518251613e`, `main`; percorsi sotto `public/`):

- `course/externallib.php`: `get_course_contents_parameters` 59–85, `get_course_contents` 93–445 (visibilità corso 164–176, filtro `uservisible` 240–242, contenuti solo se `uservisible` 342–375, sezioni non visibili svuotate 411–427), `get_course_contents_returns` 555–600, `get_course_module` 2963, `check_updates_parameters/check_updates/check_updates_returns` 3538–3665, `get_updates_since_*` 3667–3760.
- `course/lib.php`: `course_check_updates` 3216–3270, `course_check_module_updates_since` 3690–3790, `set_coursemodule_visible` 697, `set_coursemodule_name` 709, `course_delete_module` 734 (deprecata 5.2), `moveto_module` 1195.
- `course/format/classes/local/cmactions.php`: `rename`, `set_visibility`, `move_before` (648), `move_end_section` (687).
- `course/tests/externallib_test.php`: `test_check_updates` 3297.
- `course/upgrade.txt`: sezioni 3.2, 3.3, 3.6, 3.7 (campi aggiunti a `get_course_contents`).
- `lib/db/services.php`: 552–576, 736–761, 901–909, 952–959, 2842–2849.
- `lib/filestorage/file_storage.php`: `get_area_files` 619–640 (`$updatedsince`, `f.timemodified > :time`).
- `mod/resource/lib.php`: `resource_get_file_areas` 298, `resource_export_contents` 451, `resource_check_updates_since` 561. `mod/resource/db/services.php`, `mod/resource/classes/external.php` 107–175.
- `mod/folder/lib.php`: `folder_get_file_areas` 191, `folder_check_updates_since` 806. `mod/folder/db/services.php`, `mod/folder/classes/external.php` 106–170.
- `files/externallib.php`: `get_files_parameters` 52–72, `get_files` 89–200.
- `webservice/externallib.php`: `get_site_info` 63–236.
- `enrol/externallib.php`: `get_users_courses` 406–570.
- `admin/tool/mobile/db/services.php`: 28–100; `admin/tool/mobile/classes/external.php`: `call_external_functions` (`@since 3.7`).

Pagine pubbliche corrispondenti (non raggiungibili da questo ambiente; da verificare a campione in review):

- https://github.com/moodle/moodle/blob/main/public/course/externallib.php
- https://github.com/moodle/moodle/blob/main/public/course/lib.php
- https://github.com/moodle/moodle/blob/main/public/lib/db/services.php
- https://github.com/moodle/moodle/blob/main/public/mod/resource/lib.php
- https://github.com/moodle/moodle/blob/main/public/mod/folder/lib.php
- https://github.com/moodle/moodle/blob/main/public/course/format/classes/local/cmactions.php
- https://github.com/moodle/moodle/blob/main/public/course/upgrade.txt
- https://docs.moodle.org/dev/Web_service_API_functions (tabella delle funzioni con versione di introduzione)
- https://moodledev.io/docs/apis/subsystems/external/functions (dichiarazione delle funzioni esterne, `services`, `capabilities`)
- https://moodledev.io/general/app/development/ (uso di `core_course_check_updates` da parte della Moodle App)

Codice BeepBar (`dev` `713033c`): `Sources/BeepbarCore/Network/WeBeepAPIClient.swift`, `Sources/BeepbarCore/Sync/SyncCoordinator.swift` (`prepareItems`, `followRemoteMoves`, `vanishedFiles`), `SyncPlanner.swift`, `RemoteMovePolicy.swift`, `LocalPathPolicy.swift`, `SyncTransactionCoordinator.swift`, `Sources/BeepbarBenchmarkKit/BenchmarkUpstream.swift` (contatori `net.*`).
