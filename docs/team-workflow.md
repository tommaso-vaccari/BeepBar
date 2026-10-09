# Workflow di sviluppo condiviso

Le modifiche ordinarie partono da `dev` aggiornata e aprono PR con base esplicita `dev`. `main` contiene le release: non aprire né integrare una PR verso `main` senza una decisione esplicita di rilascio.

## Prendere e riprendere un task

1. Leggere [Performance Plan](performance-plan.md), issue e specifiche [IT](sync-behavior.it.md)/[EN](sync-behavior.en.md). Ricontrollare il finding sul codice corrente: le righe dell’audit storico non sono riferimenti immutabili.
2. Assegnarsi la issue prima di iniziare. Nella issue indicare branch, base/SHA, dipendenze ancora aperte e criterio di completamento. Un task non assegnato resta disponibile; non assegnare colleghi senza accordo.
3. Una PR per consegna coerente. Usare branch `fix/`, `perf/`, `feature/` o `docs/` descrittivi, commit brevi in inglese con prefisso appropriato e PR in inglese con problema, modifica, verifiche e limiti. Niente attribuzione a strumenti o agenti.
4. Aggiornare la issue quando cambia lo stato. Alla pausa riportare HEAD remoto, PR, modifiche non committate, test eseguiti sullo SHA esatto, rilievi aperti, blocco e prossimo comando/passo. Non affidare informazioni indispensabili alla chat locale.
5. Prima di modificare un percorso già occupato da un’altra issue, concordare sequenza o stack. PR indipendenti verso dev; PR dipendenti non integrate verso il predecessore, con dipendenza e ordine di merge dichiarati. Dopo il merge del predecessore aggiornare e retargettare il successore verso dev, ripetendo i gate.

## Gate di consegna

- Prima del fix riprodurre il bug o misurare lo spreco; regressioni che falliscono senza il comportamento corretto, fixture sintetiche. Per mutazioni filesystem usare una copia usa e getta; niente stash indiscriminati o mutazioni distruttive nel checkout di lavoro.
- Misure Release confrontabili: macchina, alimentazione, termica, dataset, warm-up/campioni, comando e SHA. Distinguere latenza, CPU, main occupancy, picco memoria, statement tentati, righe e commit. Conservare risultati negativi e limiti; una misura Core non dimostra fluidità UI.
- Review indipendente per le modifiche di codice. Correggere i finding e reiterare fino a clean; un P0 richiede un altro reviewer, P1/P2 lo stesso reviewer. Nuove modifiche invalidano le verifiche non più riferite all’HEAD finale.
- Test mirati, poi `swift test` e `xcodebuild -project Beepbar.xcodeproj -target Beepbar -configuration Release build CODE_SIGNING_ALLOWED=NO` sul commit finale pulito e aggiornato con dev. Per cambi al quit eseguire anche `scripts/quit-probe.sh`. Ogni nuovo file sorgente app va registrato nel progetto Xcode.
- Aggiornare entrambe le specifiche se cambia il comportamento; CHANGELOG solo per benefici percepibili. Documentare verifiche manuali non eseguite e perché. Una indagine può chiudersi senza fix se l’esito e la decisione sono motivati.
- PR con `Closes #<issue>` solo quando copre tutti i criteri. Attendere CI verde, integrare con merge commit in dev e verificare anche la CI post-merge. Se questa fallisce, riportare il task in verifica e correggere. Non chiudere task incompleti solo perché la PR è aperta.

## Garanzie e isolamento

- Nessuna riduzione di freschezza per migliorare i benchmark; nessuna perdita o sovrascrittura di modifiche locali, garanzie three-way, containment/no-follow, SQLite FULL, atomicità, journal e recovery conservate. Compatibilità per utenti che saltano release e rollback da valutare prima di migrazioni.
- I callback AppKit restano `nonisolated`, leggono snapshot e passano al main actor con `Task { @MainActor in … }`. Non introdurre accesso sincrono al main actor o scorciatoie di isolamento. Per il quit dal menu il lavoro asincrono finisce prima di chiamare terminate; non attendere main-actor work dentro il loop di `applicationShouldTerminate`.
- Test di UI/sessioni usano preferenze, account, DB/root e rete sintetici; niente lancio della normale build con identità/dati dell’app installata. Una prova live con account reale è un’attività manuale esplicita, non una side effect dei test.
- Test multilingua: stringhe tramite `tr`, dati bilingui persistiti compatibili; non cambiare `AppLanguage.current` globale durante test paralleli. Snapshot/cache e risultati asincroni rispettano account, sito, root e generazione.
- Rimuovere solo temporanei propri verificati. Conservare prove utili e rollback finché necessari; nessuna cancellazione di file sconosciuti, dati utente o cache utili.

## Documenti condivisi

- [Direzione e Performance Plan](performance-plan.md): obiettivi, vincoli, consegne e issue.
- [Specifica IT](sync-behavior.it.md) e [EN](sync-behavior.en.md): contratto del comportamento e criteri di conformità funzionale.
- [Benchmark](benchmarks.md): comandi e significato delle misure.
- [Verifica registrazioni](recordings-validation.md): evidenze datate e limiti; non sostituisce una validazione live corrente.
