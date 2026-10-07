# Comportamento della sincronizzazione

Questo documento descrive cosa fa BeepBar in ogni situazione di sincronizzazione e cosa vede l'utente. È il riferimento per sviluppo e code review: una PR che cambia uno di questi comportamenti aggiorna questo documento (e la versione inglese, [`sync-behavior.en.md`](sync-behavior.en.md)) nello stesso cambiamento.

## Garanzie

Valgono in ogni caso descritto sotto.

1. **Nessun file locale viene sovrascritto o cancellato senza una tua scelta.** Quando BeepBar non può sapere cosa preferisci, lascia il file dov'è e ti chiede.
2. **Si valuta solo ciò che Moodle ha mostrato davvero.** Un corso che in quella sincronizzazione non si è caricato (non accessibile, errore del server, rete assente), un corso disattivato o da cui sei stato disiscritto non produce cambiamenti sui suoi file.
3. **Ogni azione ricontrolla lo stato al momento in cui avviene.** Se nel frattempo il file è cambiato, l'azione non fa nulla e resta da decidere. Se la destinazione si è occupata, niente viene sovrascritto: un file spostato per seguire Moodle arriva con un numero (sezione 4.1), le altre azioni non fanno nulla.
4. **Un aggiornamento dell'app non riorganizza niente da solo.** Le nuove regole valgono per ciò che succede su Moodle da quel momento in poi.

## Termini

- **File seguito**: un file che BeepBar ha scaricato e di cui ricorda contenuto e posizione.
- **Modificato**: il contenuto sul Mac è diverso da quello che BeepBar ha scaricato l'ultima volta (per esempio appunti su un PDF).
- **Posizione su Moodle**: la sezione e il modulo in cui il professore ha messo il file. Determinano la cartella locale.

## 1. Materiali nuovi e aggiornati

| Situazione | Cosa fa BeepBar | Cosa vedi |
|---|---|---|
| Un materiale nuovo su Moodle | Lo scarica nella cartella che corrisponde a sezione e modulo | "Nuovi" in Attività |
| Il nome è già preso da un altro file nella stessa cartella | Lo scarica con un numero, per esempio `Slide (1).pdf` | "Nuovi" |
| Il professore aggiorna un file che non hai modificato | Sostituisce la copia sul Mac con quella nuova | "Aggiornati" |
| Hai modificato un file e su Moodle non è cambiato | Non tocca la tua versione | "Modifiche tue" |
| Hai modificato un file e il professore lo aggiorna | Tiene la tua versione e conserva a parte quella nuova: diventa un conflitto (sezione 3) | Voce in Conflitti |
| Su Moodle cambia solo la data o la revisione, non il contenuto | Nulla, e non lo riscarica | Nessuna novità |
| Un materiale non scaricabile (file esterno, link con credenziali) | Non lo scarica | — |

## 2. Cose che fai tu sul Mac

| Situazione | Cosa fa BeepBar | Cosa vedi |
|---|---|---|
| Cancelli un file seguito | Al sync successivo lo scarica di nuovo nello stesso posto | "Nuovi" |
| Sposti o rinomini un file seguito dal Finder | Lo considera cancellato: riscarica l'originale nella posizione di prima; la copia spostata non viene più seguita | "Nuovi" |
| Cancelli la cartella di un corso | La ricrea e riscarica i materiali | "Nuovi" |
| Al posto di un file seguito c'è una cartella | Salta quel file, gli altri continuano | "Non aggiornati" |

Per spostare file in modo che BeepBar continui a seguirli si usano "Organizza cartelle" o la rinomina della cartella del corso (sezione 5).

## 3. Conflitti

Un conflitto nasce quando un file è stato modificato sia da te sia su Moodle. La versione di Moodle viene conservata a parte; la tua resta al suo posto finché non scegli.

| Scelta | Cosa succede |
|---|---|
| **Mantieni la mia** | La tua versione resta; la copia di Moodle viene scartata. Un futuro aggiornamento del professore apre un nuovo conflitto. |
| **Usa la versione remota** | La versione di Moodle sostituisce la tua. Se nel frattempo avevi modificato di nuovo il file, resta un solo conflitto aggiornato, mai due. |

Finché un conflitto è aperto, quel file non viene spostato né aggiornato (vedi sezione 4).

## 4. Il professore riorganizza o rimuove materiali

Tutte le scelte di questa sezione compaiono nella pagina **Conflitti**, nella sezione **Spostati o rimossi su Moodle**, e restano lì finché non scegli. Una voce sparisce da sola se non serve più (il file ricompare su Moodle dov'era, oppure lo sposti o lo cancelli tu).

### 4.1 Lo stesso file cambia posto (spostato in un'altra sezione, modulo rinominato)

| Il tuo file | Cosa fa BeepBar | Cosa vedi |
|---|---|---|
| Non modificato | Lo sposta nella nuova cartella, senza riscaricarlo. La vecchia cartella, se resta vuota, viene rimossa | "Spostati" in Attività |
| Modificato | Non lo tocca | Voce in Conflitti: **Sposta la mia versione nella nuova cartella** / **Lascia qui** |
| Con un conflitto aperto | Aspetta che il conflitto sia risolto, poi applica la riga "non modificato" o "modificato" | — |

"Lascia qui": BeepBar continua a seguire il file dove l'hai lasciato; i futuri aggiornamenti del professore arrivano lì.

Rinominare una sezione o un modulo conta come spostamento: tutti i file che contiene seguono il nuovo nome.

Se nella nuova posizione c'è già un file con lo stesso nome, niente viene sovrascritto:

- Se quel file si sta spostando anche lui nello stesso sync (per esempio il professore ha scambiato i nomi di due sezioni), BeepBar sposta i file nell'ordine giusto e scambia in un solo passaggio i file che si sono scambiati di posto, senza nomi temporanei. Alla fine ogni file è al suo posto con il suo nome. Solo su un disco che non sa scambiare due file in un passaggio (alcuni dischi di rete o esterni) uno dei due arriva con un numero.
- Se è un file diverso (un altro materiale con lo stesso nome, o un tuo file), vale la stessa regola dei download: il file spostato arriva con un numero, per esempio `testo (1).pdf`. Vale anche per "Sposta la mia versione nella nuova cartella".

### 4.2 Il file viene cancellato e ricaricato altrove con lo stesso contenuto

Per Moodle è un file nuovo; BeepBar lo riconosce perché il contenuto è identico.

| Il tuo file | Cosa fa BeepBar | Cosa vedi |
|---|---|---|
| Non modificato | Lo sposta nella nuova posizione invece di scaricarne una seconda copia | "Spostati" |
| Modificato | Scarica la copia nuova nella nuova posizione e non tocca la tua | Voce in Conflitti: **Sostituisci la copia nuova con la mia versione** / **Tieni entrambe** / **Sposta la mia nel Cestino** |

Se il file viene ricaricato esattamente nello stesso posto, BeepBar continua a seguire la copia che hai, modificata o no: non la riscarica e non chiede niente, perché su Moodle il contenuto non è cambiato.

"Sostituisci" mette nel Cestino la copia appena scaricata (che non hai mai toccato) e porta la tua al suo posto; da lì in poi un aggiornamento del professore diventa un conflitto. Se durante questa azione il tuo file cambia o la destinazione si occupa, il tuo file resta dov’è e la scelta resta aperta. La copia scaricata resta recuperabile nel Cestino; il sync successivo la ripristina se la sua posizione è ancora libera.

BeepBar riconosce solo un file ricaricato nello stesso corso, e solo quando Moodle fornisce l'impronta del contenuto del file. Se lo stesso contenuto compare in più posti, BeepBar non indovina: la copia nuova si scarica normalmente e il vecchio file viene trattato come rimosso (4.3). Succede lo stesso se la copia non modificata non si può spostare (per esempio perché nel frattempo qualcos'altro ha preso il suo nuovo posto).

Se il download della copia nuova non è riuscito, riprova la sincronizzazione prima di spostare quella vecchia nel Cestino. BeepBar consente questa scelta solo quando esiste una copia scaricata separata; puoi conservarla anche se l'hai modificata.

### 4.3 Il file viene rimosso da Moodle

| Il tuo file | Cosa fa BeepBar | Cosa vedi |
|---|---|---|
| Modificato o no | Non lo cancella mai da solo | Voce in Conflitti: **Tieni** / **Sposta nel Cestino** (se l'hai modificato, la voce lo dice) |

- **Tieni**: il file resta ed esce dalla sincronizzazione: diventa un tuo file normale e non viene più segnalato. Se in seguito ricompare su Moodle con lo stesso contenuto, BeepBar torna a seguirlo; con contenuto diverso diventa un conflitto.
- **Sposta nel Cestino**: il file va nel Cestino di macOS, da cui si può recuperare.
- Un file ancora visibile su Moodle ma diventato non scaricabile non è considerato rimosso.
- Un modulo nascosto temporaneamente appare come rimosso; se torna visibile prima che tu scelga, la voce sparisce.
- Un file conta come rimosso solo se Moodle ha mostrato il suo corso per intero: se in quel sync una sezione, un modulo o una voce di quel modulo è stata omessa o non si è potuta leggere, niente lì dentro viene considerato rimosso, e le voci già aperte restano come sono.

### 4.4 Cosa non fa spostare niente

- Le modifiche alle regole con cui BeepBar costruisce i percorsi in una nuova versione dell'app.
- La rinomina della cartella di un corso e le regole di "Organizza cartelle" (sezione 5).
- Il primo sync dopo l'aggiornamento: BeepBar registra dove si trova ogni file e segue solo gli spostamenti successivi. I file già in una cartella vecchia restano dove sono; raggiungono gli altri file del loro modulo solo se su Moodle quel modulo viene spostato di nuovo.

Al primo sync dopo l'aggiornamento, i file che il professore aveva rimosso da Moodle prima dell'aggiornamento, e che sono ancora sul Mac, compaiono tutti insieme in Conflitti come rimossi: non viene cancellato niente, e scegli tu file per file. I file seguiti da versioni molto vecchie di BeepBar, che non registravano il corso, non vengono mai segnalati come rimossi.

## 5. Cartelle e organizzazione

| Azione | Cosa succede |
|---|---|
| Rinomini la cartella di un corso | Viene rinominata sul disco; BeepBar continua a seguire tutti i file. Se il nome è già occupato, lo dice e non cambia nulla |
| "Organizza cartelle": dai una cartella a un modulo | Anteprima, poi sposta i file del modulo; quelli modificati vengono spostati senza essere sovrascritti; una destinazione occupata blocca l'operazione |
| "Ripristina layout Moodle" | Riporta i file del modulo nella struttura di Moodle, con la stessa anteprima |

## 6. Corsi, rete e sync automatico

- Un corso che Moodle rifiuta (non più iscritto, nascosto, riservato) non blocca gli altri; compare come "Corso non accessibile" nei dettagli.
- Se tutti i corsi falliscono per un problema del sito o della connessione, il sync viene segnalato come non riuscito e nessun file viene toccato.
- **[PR #76]** Il sync automatico usa qualsiasi rete, compreso l'hotspot del telefono, come "Sincronizza ora".
- Il sync automatico viene rimandato, non saltato, se c'è il Risparmio energetico o un'altra operazione in corso.
- **[PR #76]** Con "Risparmio dati" attivo (Impostazioni, spento di default), il sync automatico si mette in pausa quando il Mac usa l'hotspot del telefono o una rete con la Modalità dati ridotti, e riprende da solo su un'altra rete. Se il Mac passa a una di queste reti durante un sync automatico, il sync si ferma al download successivo e viene rimandato senza segnalare un errore: i file già scaricati restano, e l'ultimo risultato resta visibile (un errore precedente non viene più mostrato, perché quel sync l'ha superato). Una connessione davvero assente resta "Connessione assente". "Sincronizza ora" scarica sempre, su qualsiasi rete.
- **[PR #76]** La pausa compare solo al posto di "Pronto", del risultato di un sync completato o di "Connessione assente": conflitti, materiali non aggiornati, altri errori, accesso scaduto e cartella da scegliere restano in primo piano. Sparisce quando parte un sync automatico, con "Sincronizza ora", quando spegni Risparmio dati o il sync automatico, cambi Frequenza o i corsi selezionati, o quando cambiano l'account o la cartella.

- Durante l'aggiornamento dei corsi, i loro interruttori sono disabilitati; una scelta ancora in salvataggio viene applicata prima di ripristinare la lista aggiornata.
- Annullare durante i controlli finali termina il sync senza mostrare un risultato completato o inviare la sua notifica. Quando compare il completamento o l'errore, il sync è terminato e l'invio della notifica non può lasciare attivo Annulla.
- Un aggiornamento in ritardo non può sostituire lo stato di un sync avviato nel frattempo, di un account disconnesso o di una cartella di sincronizzazione diversa.
- Se le scelte in sospeso non si possono leggere, le ultime liste mostrate restano visibili e il sync segnala un errore locale; non registra una sincronizzazione riuscita. Anche una selezione dei corsi illeggibile fa fallire l'aggiornamento o il sync automatico, invece di essere trattata come vuota.

- Una notifica in attesa del controllo dei permessi viene scartata se il suo account, la cartella di sincronizzazione o il risultato sono stati sostituiti; scartarla non registra la condizione come già notificata.

## 7. Dove vedi cosa

| Posto | Contenuto |
|---|---|
| **Home** | Un avviso che porta a Conflitti finché qualcosa aspetta una tua scelta, compresi i file spostati o rimossi su Moodle. **[PR #76]** Con Risparmio dati in pausa, la scheda in alto dice "In pausa per Risparmio dati" e spiega perché e come riprende, al posto del riepilogo dell'ultimo sync (che resta in Attività); dopo un sync completato mostra ancora quando è stato |
| **Attività** | Solo l'ultima sincronizzazione: nuovi, aggiornati, modifiche tue, non aggiornati, spostati, e i file modificati spostati su Moodle che ora aspettano in Conflitti. Un clic apre il file dove si trova ora, anche se un sync successivo l'ha spostato; il menu del tasto destro lo mostra anche nel Finder. Si aprono direttamente solo i documenti; tutto il resto (script, app, immagini disco, tipi sconosciuti) viene solo mostrato nel Finder. Un file che non è più dove BeepBar l'ha messo, anche se sostituito con un alias Finder, viene segnalato sulla sua riga; se manca il permesso di lettura, la riga segnala il problema e non apre niente |
| **Conflitti** | Tutto ciò che aspetta una tua scelta, finché non scegli: conflitti e file spostati o rimossi su Moodle. Una scelta rifiutata o non riuscita mostra il motivo in questa pagina; una scelta successiva cancella il vecchio messaggio |
| **Menu bar** | Lo stato dell'ultimo sync. Nessun testo nuovo per spostamenti e rimozioni. **[PR #76]** Con Risparmio dati in pausa, "In pausa per Risparmio dati" e il motivo: "In attesa del Wi-Fi" o "Modalità dati ridotti attiva"; l'icona mostra il simbolo di pausa |
| **Accesso** | Onboarding e Impostazioni mostrano l'accesso non riuscito accanto al pulsante; il tentativo successivo cancella il vecchio messaggio. Un tentativo non riuscito non sostituisce un account esistente. La scelta dell'università resta bloccata durante l'accesso; verifica, nuovo accesso e disconnessione aspettano la conclusione di un controllo dell'account in corso |
| **Notifiche** | Come oggi (nuovi materiali, conflitti). Nessuna notifica nuova per spostamenti e rimozioni. Si possono spegnere in Impostazioni: da spente non ne parte nessuna, e un conflitto ancora aperto può essere notificato al sync automatico successivo alla riaccensione. Un clic apre Conflitti, Attività o Corsi. Compaiono anche quando BeepBar è in primo piano |

## Registrazioni delle lezioni

Senza una sessione salvata riutilizzabile, aprendo la pagina compare subito una spiegazione della funzione con l'accesso Polimi, prima di recuperare le registrazioni; una sessione riutilizzabile esistente viene usata automaticamente.

Registrazioni è attiva di default per gli account Polimi. Disattivandola in Impostazioni, la pagina scompare e la scelta rimane salvata tra gli avvii. La barra laterale mostra solo i corsi selezionati per la sincronizzazione, anche quelli senza codice o anno identificabile. La ricerca in archivio richiede sia il codice del corso sia l’anno accademico. Le registrazioni vengono recuperate quando la pagina è aperta e riprodotte nel browser predefinito; la sincronizzazione dei file non le scarica. La sessione Polimi viene salvata in un file locale separato e rimossa disabilitando Registrazioni, disconnettendo o cambiando account. Alla scadenza serve un nuovo accesso.
