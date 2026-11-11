# Normativa tecnica delle regole — Four Souls Digital

**Stato: VINCOLANTE.** Questo documento è la fonte di verità per ogni regola
implementata nel motore. Se il codice contraddice questo file, il codice è
sbagliato. Se una carta o un'espansione richiede un comportamento non previsto
qui, prima si aggiorna questo documento, poi si scrive il codice.

Riferimento: *The Binding of Isaac: Four Souls* (regolamento ufficiale) +
le ratifiche #1–#5 approvate per questo progetto (registrate in §11).

Convenzioni: i nomi dei campi sono quelli del codice (`snake_case`, inglese);
la prosa è in italiano.

---

## 1. Modello di stato

1. Esiste **un solo** oggetto di stato per partita: `MatchState`
   (`scripts/core/match_state.gd`). Contiene giocatori, puntatore al turno,
   fase, tavolo, negozio, mazzi, scarti, scudi, anime, contatori.
2. `GameState` (autoload) è una **facciata**: non possiede dati propri,
   espone `state` e i mutatori che emettono gli eventi. Nessun altro file
   tiene stato di partita.
3. Lo stato è **serializzabile**: `to_dict()` produce l'immagine autoritativa
   (contiene le mani: non va mai inviata a un client),
   `snapshot_for(player_id)` produce il DTO per una singola vista.
4. `MatchController` tiene solo stato **transitorio di risoluzione**: la pila,
   `_combat_in_progress`, `_effect_window_open`. Non è stato di partita e non
   viene serializzato.

## 2. Confine pubblico / privato (ratifica #2)

| Dato | Tavolo (`snapshot_for(-1)`) | Client di P (`snapshot_for(P)`) |
|---|---|---|
| Personaggio, HP/max, danni, cent, anime, oggetti in tavola | visibile | visibile |
| Mostri in tavola (id, hp, die, boss, effetto) | visibile | visibile |
| Negozio (carta, costo, descrizione) | visibile | visibile |
| Turno, fase, round, vincitore | visibile | visibile |
| Ordine/contenuto dei mazzi | solo conteggi | solo conteggi |
| **Mano di P** | **solo conteggio** | **elenco completo** |
| Mano degli altri | solo conteggio | solo conteggio |

Regola: un client non riceve mai l'identità delle carte nella mano altrui, né
l'ordine dei mazzi. La UI non calcola regole: rende lo snapshot ed emette
intenzioni.

## 3. Struttura del turno

Fasi (`MatchState.phase`), in ordine:

1. **`start`** — il giocatore attivo:
   - ripristina `attacks_used = 0`, `buys_used = 0`, `loot_played = 0`;
   - **untap**: `character_tapped = false`, `tapped_items = []`;
   - ricarica l'oggetto eterno (`eternal_used = false`);
   - pesca `LOOT_PER_TURN` (= 1) carte Loot;
   - emette `turn_started`.
2. **`action`** — ordine libero: comprare (1), attaccare (1), giocare Loot
   (1 gratuita, poi si paga con il tap del personaggio), usare oggetti.
3. **`combat`** — durante una sequenza d'attacco. Ci si entra con `attack()`
   e si esce con `reset_combat_state()`.
4. **`end`** — fase finale, sempre eseguita in quest'ordine:
   `heal_all_players` → `heal_all_monsters` → `discard_to_hand_limit(10)` →
   `refill_empty_slots(shop e mostri)` → ricarica oggetti eterni del
   proprietario → scadenza degli scudi non consumati → **avanzamento del
   giocatore attivo** (passo che non può mai mancare).

Regola: la fase `end` non fa untap. L'untap avviene solo nella fase `start`
del proprietario.

## 4. Azioni consentite

| Azione | Limite | Chi |
|---|---|---|
| Comprare | 1 per turno, ogni tesoro una sola volta per giocatore | giocatore attivo |
| Attaccare | 1 per turno; sequenza di roll fino a morte del mostro o del giocatore | giocatore attivo |
| Giocare Loot | 1 gratuita nella propria `action`; ogni ulteriore giocata costa il **tap del personaggio** | chiunque, se può pagare |
| Usare oggetto eterno | 1 per turno del proprietario (ricarica a inizio turno; D6/Belial anche a fine turno) | chiunque, nella finestra |
| Rispondere in priorità | vedi §6 | chiunque abbia un'azione legale |

## 5. Loot e tap del personaggio (ratifica #5)

1. Ogni giocatore ha **1 giocata Loot gratuita**, utilizzabile **solo** nella
   propria fase `action`.
2. Ogni altra giocata Loot — seconda nel proprio turno, oppure **qualsiasi**
   giocata fuori dal proprio turno (in risposta sulla pila) — costa il
   **tap della Carta Personaggio**: `character_tapped = true`.
3. Un personaggio tappato non può pagare un'altra giocata finché il
   proprietario non entra nella fase `start` del proprio turno successivo.
4. La giocata viene **addebitata prima** dell'apertura della finestra; se
   l'azione non è legale viene rifiutata senza effetti.
5. La carta giocata **esce dalla mano nel motore** (`play_loot`), mai nella UI.
6. Il tap del personaggio **non** dipende più dall'effetto dichiarato sulla
   carta personaggio: il costo è il tap, non un'abilità speciale. Il campo
   `character_effect` delle carte non è più un prerequisito per giocare
   Loot fuori turno.

## 6. Pila (LIFO) e priorità (ratifica #3)

1. Ogni evento che richiede risoluzione è un'entry tipizzata sulla pila:
   `pending_roll` (tiro), `pending_effect` (carta giocata), `modifier`
   (D6/Belial). La pila è LIFO: l'ultima entry inserita si risolve per prima.
2. Quando un'entry è in cima, si apre una **finestra di priorità** a tutti i
   giocatori in ordine di turno a partire dal giocatore attivo.
3. Un giocatore **senza azioni legali viene saltato automaticamente**
   (auto-pass); chi ha azioni legali viene interrogato e può passare.
4. **Pass consecutivi pari al numero di giocatori** chiudono la finestra.
   Una risposta valida azzera il conteggio e riparte dal giocatore attivo.
5. Alla chiusura si risolvono, in un solo blocco LIFO, le entry presenti in
   quel momento (modificatore → tiro, ecc.).
6. **Risoluzione ricorsiva**: se un'entry, risolvendosi, ne inserisce altre,
   queste vengono risolte **prima** che il motore torni al chiamante, con una
   nuova finestra per la nuova cima. Nessuna entry può essere distrutta
   silenziosamente.
7. L'input passa **solo** dal driver (`MatchDriver`): richiesta con
   `request_id`, `player_id`, `legal_actions`; la risposta è valida solo se
   entrambi gli identificativi coincidono. Risposta scaduta o di un altro
   giocatore = **pass**, mai un'azione.
8. L'elenco delle azioni legali lo calcola il motore (`_legal_actions`): un
   client non inventa opzioni.
9. "STOP attack" **non esiste**: un attacco termina solo con la morte del
   mostro o del giocatore.
10. Le giocate Loot in risposta sono **atomiche** (nessuna finestra annidata):
    semplificazione dichiarata della fase 1, da rivedere in M4.

## 7. Combattimento e danni

1. Attacco: 1d6 + bonus di roll. Se `roll >= die_value` del mostro → HIT.
2. Danno inflitto = `damage` del personaggio + bonus degli oggetti. Mai un
   valore fisso nel resolver.
3. MISS → il giocatore attaccante subisce 1 danno.
4. HP del giocatore ≤ 0 → morte (§8), anche a metà attacco.
5. `reset_combat_state()` gira su **ogni** uscita dall'attacco (kill, morte,
   errore) e verifica che la pila sia vuota.
6. Yum Heart è **prevenzione**, non cura: annulla l'intera istanza di danno,
   si consuma, oppure scade a fine turno del proprietario (che la ricarica).

## 8. Morte (ratifica #5)

La morte **non** termina la partita. Penalità, in quest'ordine:

1. perde **1 cent** (se ne ha);
2. **tappezza** la Carta Personaggio e tutti i propri oggetti
   (`character_tapped = true`, `tapped_items`; si untappano nella fase `start`
   del turno successivo del proprietario);
3. **sceglie** 1 carta Loot dalla propria mano da scartare. Fallback automatico
   **solo** se la mano contiene esattamente 1 carta. Con 0 carte nessuna
   scelta;
4. **sceglie** 1 oggetto da perdere (l'oggetto eterno è protetto).

Poi si esegue la fase `end` completa, **incluso** l'avanzamento del giocatore
attivo. La scelta passa dal driver con lo stesso contratto di identità della
priorità.

## 9. Tavolo, negozio, anime

1. **Slot mostro base: 2** (ratifica #4). La struttura è una **lista
   dinamica**: una carta o un evento futuro può aggiungere uno slot senza
   refactor. Riempimento automatico a inizio partita, dopo ogni morte e in
   fase `end`.
2. **Slot negozio: 2**, riempiti dal mazzo tesori, ricaricati dopo ogni
   acquisto e in fase `end`.
3. Ricompense dei mostri **dai dati della carta**: boss → la propria anima
   (`soul_value`, di norma 2); mostro con `soul_reward` → quell'anima;
   altrimenti 1 cent.
4. Vittoria: la **somma dei valori** delle anime raggiunge **4**. Un boss è
   **una** carta anima che vale 2.

## 10. Registro delle incoerenze chiuse

| # | Incoerenza | Risoluzione normativa |
|---|---|---|
| D1 | `CLAUDE.md` diceva 3 slot mostro, il codice 2 | **2 slot base** (ratifica #4), lista dinamica |
| D2 | Il log di setup stampava "3 loot per turn" | **1 Loot per turno** (`LOOT_PER_TURN = 1`) |
| D3 | README diceva "1 loot a caso" alla morte | **il giocatore sceglie**; automatico solo con 1 carta |
| D4 | La pila/priorità era descritta come homebrew | **esiste nel regolamento ufficiale** (ratifica #3): è normativa |
| D5 | "perde 1$" vs 1¢ nel codice | **1 cent** (`cents`) |

## 11. Ratifiche recepite

- **#1** Client telefoni: PWA HTML/TS + WebSocket raw verso il server Godot.
  Nessun export Godot Web sui telefoni.
- **#2** Stato unico serializzabile + snapshot filtrati; UI passiva.
- **#3** Pila e priorità native; driver iniettato con `request_id`,
  validazione del giocatore, azioni legali, risoluzione ricorsiva.
- **#4** 2 slot mostro base (lista dinamica), allineamento della doc.
- **#5** Loot gratuito solo in `action`; extra/fuori turno = tap del
  personaggio; morte con scelta del Loot da scartare, tap di personaggio e
  oggetti.

## 12. Cosa NON è ancora normato (lacune dichiarate)

1. Ordine di scelta tra effetti simultanei: policy fissa (attivo → senso orario
   → ordine di acquisto). Nessuna scelta umana.
2. Carte con `effect_trigger` (`on_roll`, `on_death`, `on_miss`): i campi sono
   dichiarati e validati ma **non eseguiti** dal motore. Non usare quei campi
   come se funzionassero: è compito di M4 (TriggerEngine).
3. Cap massimo degli HP (regolamento: 6). Oggi non applicato.
4. Carte Curse, espansioni, modalità oltre 2 giocatori.
