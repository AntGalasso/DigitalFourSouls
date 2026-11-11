# ARCHITECTURE_AUDIT.md — Four Souls Digital

**Audit architetturale** — Godot 4.7.1 · GDScript · 34 carte · Fase 1 (hotseat locale)
Data: 9 novembre 2026 · Ruolo: Principal Godot Architect / Rules Designer
Stato del documento: **proposta — nessuna riga di codice modificata in attesa di approvazione**

---

## 0. Verifica eseguita e verdetto in sintesi

Prima di giudicare l'architettura ho verificato che lo stato dichiarato in `PROJECT_STATUS.md` sia reale, non narrativo:

```
"C:/Program Files/Godot_v4.7.1-stable_win64.exe" --headless --path . res://scenes/turn_loop_test.tscn
→ 23/23 self-check PASS · exit code 0
```

Quindi: **il repository è sano, il turn loop funziona, la suite di auto-verifica è reale e verde.** Non siamo davanti a un prototipo rotto, ma a un motore single-process con fondamenta concettualmente giuste e **quattro gap strutturali** che, se non chiusi ora, rendono il refactor esponenzialmente più costoso a 100+ carte.

### Verdetto

| Dimensione | Valutazione | Nota |
|---|---|---|
| Modello dati carte | **Solido** (8/10) | `CardResource` puro + pipeline CSV→`.tres` validata: è l'asset più prezioso del repo |
| Motore di regole | **Buono ma monolitico** (6/10) | `MatchController` è headless di fatto, non di contratto |
| La Pila | **Embrionale** (4/10) | C'è la struttura LIFO, manca il motore di priorità e la risoluzione a cascata generale |
| Trigger / effetti | **Incompleto e incoerente** (3/10) | 3 soli trigger cablati; i campi `effect_trigger` dei mostri sono **dati mai eseguiti** |
| Disaccoppiamento UI | **Assente** (2/10) | La UI duplica regole e muta lo stato direttamente |
| Networking | **Inesistente** (0/10) | Nessun RPC, nessun WebSocket, nessuna serializzazione |
| Testabilità | **Buona** (7/10) | 23 self-check eseguibili: rete di sicurezza preziosa per il refactor |

**Raccomandazione forte: non aggiungere carte prima di aver chiuso M1 e M2 (§5).** Ogni carta aggiunta oggi consolida tre debiti: trigger cablati a mano, effetti che parlano con la UI, stato non serializzabile.

---

## 1. Stato Attuale (Cosa c'è)

### 1.1 Mappa dei sistemi esistenti

| Livello | File | Natura | Righe ca. |
|---|---|---|---|
| Boot / config | `project.godot` | 5 autoload: `EventBus`, `GameState`, `CardEffectRegistry`, `Log`, `Rng`. Main scene = `game_scene.tscn` | — |
| Dati carta | `scripts/core/card_resource.gd` | `Resource` **puro** (34 campi `@export`), nessuna logica | ~55 |
| Effetti (base) | `scripts/core/card_effect.gd` | `RefCounted` + `class_name CardEffect`, hook `on_play`/`on_attacked`/`on_killed`/`on_event`/`get_roll_bonus`/`get_damage_bonus` | ~60 |
| Effetti (registry) | `scripts/core/card_effect_registry.gd` | Autoload che istanzia effetti, cabla trigger, applica `simple_effect`, gestisce mount/unmount per `instance_id` | ~230 |
| Pila | `scripts/core/event_stack.gd` | `RefCounted` + `class_name EventStack`: coda LIFO tipizzata (`pending_roll` / `pending_effect` / `modifier`), `push/pop/top/find/top_of_type/clear/resolve_top` | ~120 |
| Regole | `scripts/core/match_controller.gd` | `RefCounted` + `class_name MatchController`: mazzi, 2 slot mostro, 2 slot shop, buy/attack/play_loot/use_eternal_item/end_turn/die, finestra di priorità, morte, anime, win a 4 | ~792 |
| Stato | `scripts/autoload/game_state.gd` | Giocatori `Array[Dictionary]`, turno, fase, anime, scudi | ~150 |
| Eventi | `scripts/autoload/event_bus.gd` | ~30 segnali, payload `Dictionary`, naming passato/snake_case | ~80 |
| Casualità | `scripts/autoload/rng.gd` | Seam iniettabile (`var rng: Object`), `roll_die()`, `shuffle()`, `seed_rng()` | ~30 |
| Log | `scripts/autoload/log.gd` | `warn`/`error` sempre stampati (headless-safe) | ~14 |
| Effetti scripted | `scripts/cards/effects/{the_bible,soul_of_hope,money_is_power}.gd` | 3 file, effettivamente minuscoli (3-8 righe) | 3 file |
| Import | `scripts/tools/card_importer.gd` + 2 entry point | CSV → `.tres`, validazione rumorosa, idempotente | ~190 |
| UI tavolo | `scenes/game_scene.gd` | **707 righe**, costruita interamente in codice (Label/Button), overlay hotseat e priorità | 707 |
| Test self-play | `scenes/turn_loop_test.gd` | 3 round automatici + **23 self-check** (STEP A-Z) | 1201 |
| Test UI headless | `scripts/tools/ui_drive_test.gd` | Pilota i veri handler della scena hotseat (canary) | ~70 |
| Catalogo | `data/cards_base_set_template.csv` → `resources/cards/base_set/*.tres` | 34 carte: 15 mostri, 6 loot, 7 tesori, 3 personaggi, 3 eterni | 34 |

### 1.2 Turni e fasi: come funzionano davvero

La state machine **non è esplicita**. Non esiste un enum di fase né transizioni validate: le fasi sono implicite nella sequenza di chiamate.

```
begin_turn(player_id)
  ├─ GameState.current_player_index = player_id
  ├─ reset contatori (attacks_used, buys_used, loot_played,
  │                    character_effect_used, eternal_used)   ← "start phase" (ricariche)
  ├─ draw_loot(player_id)                                       ← pesca automatica 1 loot
  └─ EventBus.turn_started.emit(player_id)                      ← trigger di inizio turno

[end_turn / morte] → _finish_turn(ending_player_id)
  ├─ recharge eterno del proprietario (se recharges_on_turn_end)
  ├─ expire_shields_owned_by(owner)
  ├─ restore_hp() per TUTTI i giocatori
  ├─ hp = card.hp per TUTTI i mostri in tavola
  ├─ discard_to_hand_limit(owner, 10)
  ├─ _refill_shop() + _refill_monsters()
  ├─ EventBus.turn_ended.emit()
  └─ GameState.advance_active_player()                          ← alternanza SEMPRE
```

`GameState.current_phase` esiste (`"buy"`) ma **non viene mai più aggiornato**: è un campo morto. La "Action Phase" con ordine libero è garantita dai contatori per-turno, non da uno stato. Conseguenza: il motore non sa rispondere a "in che fase siamo?", quindi non può né validare un comando in base alla fase né **riprendere una partita a metà** (requisito implicito per la riconnessione dei telefoni).

### 1.3 Carte: due percorsi di comportamento (documentati e coerenti)

1. **Data path (default)** — `simple_effect` + `simple_effect_value`, interpretati da uno `match` in `CardEffectRegistry._apply_simple_effect`. Pattern esistenti: `gain_cents`, `gain_hp`, `damage_monster`. Copre 8 carte.
2. **Script path (escape hatch)** — `effect_script_path` → sottoclasse `CardEffect`. Copre 3 carte.

Mutua esclusione, `instance_id` per ogni copia in gioco (le copie duplicate non collidono — verificato da STEP A), unmount alla morte/scarto (STEP C). Questo è il pattern corretto e va **conservato**.

### 1.4 Trigger: cosa c'è davvero

Cablati a mano in `_wire_trigger` / `_wire_data_trigger`: **solo tre** segnali.

| Trigger dichiarabile | Cablato? | Note |
|---|---|---|
| `turn_started` | ✅ | player-scoped |
| `card_played` | ✅ | player-scoped |
| `monster_killed` | ✅ | game-scoped |
| `ON_DAMAGE` | ❌ | nessun segnale dedicato cablabile |
| `ON_DIE_ROLL` | ❌ | il tiro è solo entry di pila, nessun trigger hook |
| `ON_MONSTER_DEATH` (lato carta) | ⚠️ parziale | `notify_monster_killed` esiste ma non passa dallo stesso canale dei trigger |
| `START_OF_TURN` | ✅ | alias di `turn_started` |
| qualunque altro | ❌ | finisce in `Log.warn("no wiring for trigger ...")` |

**Incoerenza più grave del repository:** il CSV dichiara `effect_trigger` / `effect_condition` / `effect_description` per i mostri (Gurdy `on_roll: roll == 1`, Monstro `on_miss: discard 1 loot`, Fistula `on_death`), l'importer li **valida** e li scrive nei `.tres`, ma **nessun codice li legge mai**. Sono dati autorevoli che il motore ignora: la documentazione descrive un gioco che non esiste. STEP S "passa" perché verifica la *presenza dei campi*, non il loro comportamento.

### 1.5 La Pila oggi: cosa è e cosa non è

**Cosa è** (`event_stack.gd` + `_run_stack_window` + `_resolve_stack_entry`):

```
entry tipizzate: pending_roll (r#) | pending_effect (e#) | modifier (m#)
push(id auto) → finestra di priorità → resolve_top() → pop + resolver(entry)
resolve_top() cascata: modifier → riprende il pending_roll bersaglio
finestra: turno dal giocatore attivo, pass consecutivi (n) chiudono,
          auto-pass per chi non ha risposte legali (_player_has_response)
risposta: loot (ATOMICO) | eterno | "stop" (ignorato: non è una regola) | pass
```

**Cosa non è** — e sono i punti che contano per il progetto:

1. **Una entry alla volta.** Il flusso reale è `push(1) → finestra → resolve_top()`. Non esiste la finestra "aperta sulla cima della pila mentre qualcuno può ancora aggiungere", con più entry simultanee e turni di priorità multipli.
2. **Cascata hardcoded.** `resolve_top()` conosce solo il caso `modifier → pending_roll`. **Un `pending_effect` o un `pending_roll` push-ato *durante* la risoluzione non viene mai risolto**: resta in coda e viene distrutto da `reset_combat_state()` con un warning (`"found N leftover entries — clearing"`). Questo è il bug strutturale che impedisce le reazioni a catena (effetto che genera effetto).
3. **Risposta al segnale globale.** `_run_stack_window` fa `var args: Array = await EventBus.priority_given` e accetta `args[0]` come `pid` **senza verificare che coincida con il giocatore atteso**. In hotseat è innocuo; in rete è spoofing di priorità.
4. **Nessun `request_id`, nessun timeout, nessun set di risposte legali dichiarato.** La UI deduce da sola cosa è lecito (e lo fa duplicando regole, §3 C4).
5. **L'omicidio della dichiarazione d'attacco.** Il metaprompt chiede che *"dichiarazione bersaglio"* sia un elemento della pila: oggi l'attacco push-a solo il tiro. Un mostro con trigger "quando vieni attaccato" non ha un punto di aggancio.
6. **Anime, scudi, e modificatori di dado sono fuori dalla pila** (`GameState.shields`, `_monster_shields` nel controller). La pila non è la single source of truth degli effetti attivi.

### 1.6 UI del tavolo (hotseat)

`game_scene.gd` costruisce tutto in codice, nessun `.tscn` oltre al nodo radice. Funziona (verificato anche da `ui_drive_test`), ma è un **secondo motore di regole mascherato da vista**:

- decide "buy limit used / bought / too poor / limit" per disabilitare i bottoni;
- sceglie lei il bersaglio (`table_monsters[0]`) quando una carta `needs_target`;
- `_play_active_item()` scorre `items_passive` e usa **il primo item playable** trovato;
- `_play_hand_card()` fa `GameState.players[player_id]["hand"].erase(card.id)` — **la vista muta lo stato**;
- tiene `_next_player` come stato di turno parallelo al motore;
- tutta la conoscenza privata di **entrambi** i giocatori è sullo stesso schermo (ineliminabile in hotseat, ma oggi non esiste alcun punto di taglio pubblico/privato).

### 1.7 Cosa non esiste (grep-negativi verificati)

- Nessuna occorrenza di `RPC`, `multiplayer`, `MultiplayerAPI`, `WebSocket`, `ENet`, `TCPServer`.
- Nessuna classe DTO / serializer / `to_dict()` di stato.
- Nessun comando/intent: la UI chiama metodi del controller direttamente.
- Nessun test GUT (la convenzione in `CLAUDE.md` lo raccomanda per la matematica di combattimento).
- Nessuna persistenza: la partita vive solo in RAM.

### 1.8 Registro delle incoerenze documentali (da risolvere, non da ignorare)

| # | Incoerenza | Fonti in conflitto |
|---|---|---|
| D1 | **Numero di slot mostro: 2 o 3?** | `CLAUDE.md` (decisione MP05 b): *"THREE monster slots"* vs `match_controller.gd`: `MONSTER_SLOTS := 2` vs `README`/`PROJECT_STATUS`: 2 |
| D2 | **Loot per turno** | log di setup: *"each with 3¢ and 3 loot per turn"* vs `LOOT_PER_TURN := 1` (comportamento) |
| D3 | **Loot persa alla morte: casuale o la prima?** | `README`: *"1 loot a caso"* vs `die()`: `hand.pop_front()` (deterministico, la prima) |
| D4 | **Autorità delle regole di priorità** | Il regolamento fisico di Four Souls **non ha** pila/priorità: l'architettura MtG-style è una **vostra estensione**. Non esiste oggi un documento normativo che dica, per esempio, se rispondere con un Loot consuma il limite di 1 loot del turno (il codice dice sì, e per i non-attivi usa lo slot dell'effetto personaggio) |
| D5 | Metaprompt: *"perde 1$"* alla morte | implementato come 1¢ (corretto per FS); il metaprompt usa un simbolo improprio |

> D4 è la più importante: senza un "Comprehensive Rules — Digital Edition" scritto, ogni carta futura reinterpreterà la priorità a modo suo e l'engine andrà alla deriva. Lo propongo come deliverable di M1 (§5).

---

## 2. Cosa Salvare

Da **non toccare** durante il refactor. Ogni voce ha il motivo tecnico per cui è un asset.

| # | Asset | File | Perché salvarlo |
|---|---|---|---|
| S1 | **`CardResource` come dati puri** | `core/card_resource.gd` | Zero logica, 34 `@export`: sopravvive a qualunque refactor del motore ed è già il contratto della pipeline. È la ragione per cui 300 carte sono possibili. |
| S2 | **Pipeline CSV → `.tres` con validazione rumorosa** | `tools/card_importer.gd` | Valida riga per riga (script mancanti, id duplicati, interi non parsabili, campi obbligatori per tipo) e riporta **tutti** gli errori prima di scrivere. Idempotente. È un compilatore di contenuti: va esteso, non riscritto. |
| S3 | **`EventStack` come coda LIFO tipizzata** | `core/event_stack.gd` | La forma dei dati è giusta (3 tipi, id `r#`/`e#`/`m#`, `find` per riferimento, `top_of_type`, `resolver` iniettato come `Callable`). Va **esteso**, non sostituito. Il resolver iniettabile è già il seam per testare la pila senza motore. |
| S4 | **`instance_id` per copia + mount/unmount degli effetti** | `core/card_effect_registry.gd` | Risolve correttamente il problema delle copie duplicate e del lifecycle (STEP A / STEP C). È esattamente il modello che serve con 340 carte e trigger multipli. |
| S5 | **`Rng` come seam iniettabile + seed** | `autoload/rng.gd` | Determinismo già dimostrato (seed 8) e stub duck-typed nei test. È il prerequisito di **replay, anti-cheat e riproduzione bug**: vale oro in un gioco a rete. |
| S6 | **Mutatori di `GameState` che emettono eventi** | `autoload/game_state.gd` | `gain_cents`/`heal`/`apply_shield`/`gain_soul` sono il pattern "stato + notifica" già corretto: lo stato non può divergere dall'evento. Conservare la firma, cambiare il contenitore. |
| S7 | **`CardEffect` a hook minimi** | `core/card_effect.gd` | Interfaccia piccola e leggibile (`on_play`, `on_attacked`, `on_killed`, `get_roll_bonus`, `get_damage_bonus`). Da estendere con hook di reazione alla pila, senza gonfiarla. |
| S8 | **23 self-check eseguibili come golden test** | `scenes/turn_loop_test.gd` | Sono la **rete di sicurezza del refactor**: se dopo M1-M2 restano 23/23 verdi, il comportamento non è cambiato. Vanno trasformati in test GUT (stessa logica, altro runner), non buttati. |
| S9 | **Log autoload headless-safe** | `autoload/log.gd` | La lezione (push_warning invisibile in headless) è costata un bug: non regredire. |
| S10 | **Separazione `MatchController` (regole) vs driver (presentazione)** | `match_controller.gd` header | L'intenzione è già scritta e in gran parte rispettata: due driver (robot e UI) usano lo stesso motore. È la base del driver astratto di M1. |
| S11 | **`advance_active_player()` sempre eseguito a fine ending phase** | `_finish_turn` | La regola "lo step che non deve mai mancare" è isolata in un punto solo, con test dedicato (STEP U). Architetturalmente giusto: un solo punto di verità per il cambio turno. |
| S12 | **`ui_drive_test` come canary** | `tools/ui_drive_test.gd` | Pilota gli handler reali della scena: anti-regressione del flusso, non della logica. Da conservare quando la UI diventerà un adapter di comandi. |

---

## 3. Cosa Rifattorizzare (Criticità)

Ordinate per **impatto sull'obiettivo** (asimmetria PC + telefoni, fedeltà regole, scalabilità a 300+ carte). Severità: 🔴 bloccante · 🟠 alta · 🟡 media.

### C1 🔴 La Pila non è una pila multi-effetto e perde le entry generate durante la risoluzione

**Evidenza.** `EventStack.resolve_top()` cascata solo `modifier → pending_roll`; `MatchController.reset_combat_state()` fa `stack.clear("combat_reset")` con warning se restano entry. `attack()` e `play_loot()` fanno esattamente `push(1) → window → resolve_top()`.

**Impatto.** Nessuna reazione a catena possibile: un effetto che, risolvendosi, deve accodare un altro effetto (morte di un mostro che innesca X, danno che innesca Y) **non ha un percorso legale**. Con l'espansione Premium questo è il 90% delle carte interessanti. È il difetto che rende la promessa "fedeltà al 100% + espansioni" non implementabile.

**Direzione.** `EventStack` diventa un vero motore a due fasi: (a) **round di priorità** sulla cima finché tutti passano, (b) **risoluzione della cima** che può *push-are* nuove entry, con loop di drenaggio fino a pila vuota; `resolve_top()` perde la cascata hardcoded e diventa un dispatcher puro. Aggiungere check di stato (SBA) tra una risoluzione e l'altra (morte, win, target invalido → fizzling).

### C2 🔴 La finestra di priorità è un `await` su un segnale globale: non è indirizzabile né autoritativa

**Evidenza.** `_run_stack_window`: `var args: Array = await EventBus.priority_given` → `pid = args[0]` **non validato** contro `idx`; nessun `request_id`, nessun timeout, nessun set di risposte legali; `_player_has_response()` è euristica booleana.

**Impatto.** In hotseat funziona. In rete è **bloccante** per tre motivi: (1) chiunque può rispondere per chiunque; (2) non si distingue una risposta a *questa* richiesta da una in ritardo o duplicata (desync garantito con latenza mobile); (3) non esiste un "chi stiamo aspettando" da mandare al telefono giusto. Inoltre il motore **si sospende su un blob globale**, quindi non è pilotabile da più sessioni o da un server con più partite.

**Direzione.** Introdurre `PriorityRequest { request_id, expected_player_id, kind, options[], deadline_ms }` e un `Driver` iniettato con `ask(request) -> response`. Il driver hotseat mostra l'overlay, il driver test passa, il driver rete invia il prompt al telefono giusto e attende con timeout. `EventBus.priority_*` resta come **notifica di presentazione**, non come rendezvous. Le risposte portano `request_id` e vengono accettate solo dall'`expected_player_id` (single-use, idempotenti).

### C3 🔴 Nessun confine pubblico/privato: non esiste un "cosa vede il telefono N"

**Evidenza.** `GameState.players` è un `Array[Dictionary]` che contiene mano, oggetti, anime, HP di tutti. La UI legge direttamente quell'array (e `_controller.table_monsters`). Nessun DTO, nessun serializer, nessun filtro.

**Impatto.** Il requisito centrale del progetto — *il telefono vede solo la propria mano* — oggi non ha **nemmeno il punto di taglio**. Serializzare `GameState` così com'è significa spedire a ogni smartphone la mano di tutti: leak immediato, e impossibile da chiudere "dopo" senza toccare ogni consumatore.

**Direzione.** Due DTO espliciti prodotti dal motore, unica sorgente per entrambe le UI: `PublicState` (tavolo, mostri+HP, shop, pila, statistiche pubbliche, oggetti equipaggiati con stato carico/scarico) e `PrivateState[player]` (mano, obiettivi). Più `Prompt` per-player. Test automatico obbligatorio: *la vista di P2 non contiene mai un `card_id` della mano di P1*.

### C4 🔴 Regole duplicate dentro la vista

**Evidenza.** `game_scene.gd`: `buy_limit`, `is_bought`, `cents < cost`, `loot_limit`, `needs_target → table_monsters[0]`, `_play_active_item()` che usa il primo item playable, `hand.erase(...)`, `_next_player`.

**Impatto.** Ogni regola replicata è un futuro desync: la UI hotseat e il server diranno cose diverse appena la UI diventa remota (o appena una carta cambia un limite). Con tre client (tavolo + 2 telefoni) le copie diventano quattro. Inoltre impedisce l'anti-cheat: se la UI "decide", il client può mentire.

**Direzione.** La vista diventa un **adapter stupido**: disegna `PublicState`/`PrivateState`, invia `Command`, mostra `ack/rejected(reason)`. Le azioni legali arrivano dal server in `legal_actions[]` (già calcolate da chi possiede le regole). Rimuovere ogni `if` di regolamento dalla scena.

### C5 🟠 Nessun modello Command/Intent, nessun log autoritativo

**Evidenza.** La UI chiama `_controller.buy(...)`, `_controller.attack(...)`, `_controller.play_loot(...)` e muta `GameState` direttamente.

**Impatto.** Senza `Command { cmd_id, player_id, type, payload, request_id }` non c'è: validazione centralizzata, idempotenza (retry su rete mobile), replay deterministico, riconnessione, audit anti-cheat. È il tassello che rende il server *autoritativo* invece che "il PC che chiama metodi".

**Direzione.** `CommandRouter.handle(cmd) -> {ok | rejected(reason)}` + `Event[]` come effetti. Il motore non conosce né la rete né la UI: riceve comandi, restituisce eventi e stato.

### C6 🟠 Lo stato di gioco è sparso su cinque contenitori, nessuno serializzabile

**Evidenza.**

| Dove | Cosa |
|---|---|
| `GameState.players` | giocatori, mano, items, anime, HP, contatori per-turno |
| `GameState.shields` | scudi sui giocatori (owner + item) |
| `MatchController.table_monsters` | mostri in tavola (istanza, carta, HP) |
| `MatchController._monster_shields` | scudi sui mostri — **seconda semantica di scudo**, separata |
| `MatchController.{shop_slots, _*_deck, _bought, _instance_counter}` | negozio, mazzi, acquisti |
| `CardEffectRegistry.{_owned, _by_card, _owned_effects, _monster_by_instance}` | effetti montati |

**Impatto.** Impossibile fare snapshot/resume; impossibile un delta di stato; due implementazioni di "scudo" con comportamenti diversi (player: consume/expire con owner; mostro: consume senza scadenza) che divergeranno. In più `CardEffectRegistry` è un **autoload globale senza `reset()`**: dopo `reload_current_scene()` i bonus delle carte della partita precedente restano attivi (bug reale, non teorico).

**Direzione.** Un `MatchState` unico e versionato (`state_version` monotono) che contiene *tutto*, incluso pila e scudi, con `to_dict()/from_dict()`. Il registry riceve un `match_id` e si azzera a nuovo match. I mazzi diventano parte dello stato (servono per il resume e per il replay).

### C7 🟠 Fase/turno non sono una state machine

**Evidenza.** `GameState.current_phase` mai aggiornato; nessun enum; transizioni implicite; `_combat_in_progress` + `_effect_window_open` come flag booleani sparsi.

**Impatto.** Non si può validare "questo comando è legale *in questa fase*", non si può riprendere una partita a metà (riconnessione telefono durante un combattimento), e i flag booleani sono già un problema di rientranza (`attack` e `play_loot` si escludono a vicenda con due flag, non con uno stato).

**Direzione.** Enum esplicito `Phase { START, ACTION, COMBAT, END }` + tabella di transizioni legali + un solo `busy` derivato dalla fase. Requisito di accettazione: partita serializzata e ricaricata a metà COMBAT produce lo stesso stato.

### C8 🟠 I campi di trigger dei mostri sono dati morti; i modificatori di dado sono hardcodati

**Evidenza.** `effect_trigger` / `effect_condition` / `effect_description` sono scritti dall'importer e **mai letti**. `use_eternal_item()` fa `match item.eternal_action:` con tre rami hardcodati (`reroll_die`, `adjust_die`, `prevent_damage`).

**Impatto.** Doppio: (a) il catalogo **mente** — 3 mostri su 15 dichiarano comportamenti inesistenti; (b) ogni nuovo eterno/modificatore richiede codice nel controller, che è esattamente l'anti-pattern "effetti hardcodati" che il metaprompt vieta. La fedeltà dichiarata (>90%) non è verificabile finché i dati non sono eseguiti.

**Direzione.** `TriggerEngine` con eventi canonici (`ON_DAMAGE`, `ON_DIE_ROLL`, `ON_MONSTER_DEATH`, `START_OF_TURN`, `ON_ATTACK_DECLARED`, `ON_LOOT_PLAYED`) e un interprete minimo per `effect_condition` (DSL a predicati registrati, non `eval`). Gli eterni diventano effetti sulla pila come qualunque altra attivazione, con `activation_type/cost` come dati. **Test di accettazione: Gurdy, Monstro e Fistula hanno un test che ne verifica il comportamento reale.**

### C9 🟡 Fedeltà al regolamento: gap puntuali ma visibili

| Gap | Stato | Nota |
|---|---|---|
| Mano non persistente tra turni | ❌ | La loot pescata non resta in mano (limite dichiarato in README) — con 10 carte di limite, la regola del limite di mano è oggi quasi irraggiungibile |
| Loot in risposta atomico | ⚠️ semplificazione | Nessuna catena di risposte: contraddice C1 |
| Dichiarazione d'attacco non è entry di pila | ❌ | Richiesto dal metaprompt |
| Cap HP 6 | ❌ | Assente (noto) |
| Carte Curse | ❌ | Tipo presente nell'enum, nessuna carta |
| Scelta ordine effetti simultanei | ⚠️ policy fissa | Attivo → orario → registrazione: accettabile in Fase 1, ma con i telefoni la scelta diventa **un prompt**, non una policy |
| Scudi: due implementazioni | ⚠️ | Player vs mostro, semantica diversa (C6) |
| Mostri: 2 vs 3 slot | ❓ | Incoerenza D1 da decidere |
| Effetti "fino a fine turno" | ⚠️ | Solo gli scudi hanno scadenza; manca un registro generico di effetti temporanei |
| `play_loot` usato anche per item attivi | 🟡 | Semantica impropria: un item attivo non è un loot (limiti e trigger diversi) |

### C10 🟡 Accoppiamenti tecnici e fragilità di processo

1. **`setup()` non è idempotente e non c'è teardown.** `EventBus.monster_damaged.connect(...)` / `monster_killed.connect(...)` avvengono in `setup()`: due `setup()` sulla stessa istanza (restart, lobby, più partite nel processo server) → **doppio danno e doppie ricompense**. Serve `teardown()` esplicito e `setup()` idempotente.
2. **`CardEffectRegistry` globale** senza reset (vedi C6).
3. **Ordine dei mazzi dipendente dal filesystem.** `_build_decks()` itera `DirAccess` e poi mescola: il determinismo dipende dall'ordine di enumerazione dei file. Per replay su due macchine diverse (PC Windows + eventuale harness) serve un **manifest ordinato** delle carte.
4. **`_instance_counter` per-partita ma non persistito**: dopo un resume gli `instance_id` possono collidere con quelli di effetti ancora montati.
5. **`turn_loop_test` usa flag su membro per emulare il "once" nelle lambda** (commento esplicito nel file): fragile ma onesto. La migrazione a GUT con fixture esplicite lo elimina.
6. **`total_cards_at_setup` conta personaggi ed eterni** fra le "carte in catalogo": numero fuorviante in UI.
7. **Nessun test GUT** per la matematica di combattimento (raccomandato da `CLAUDE.md`), nessuna CI, nessun check di tipo statico (`gdlint`/`--check-only`).

### C11 🟡 `EventBus` ha tre ruoli incompatibili

Oggi è contemporaneamente: (a) bus di dominio interno, (b) canale di richiesta/risposta della priorità (`await`), (c) sorgente di notifiche per la UI. I tre ruoli hanno requisiti opposti (il (a) è affidabile e ordinato, il (b) deve essere indirizzabile e timeout-aware, il (c) deve essere serializzabile). **Va spezzato**: dominio (`GameEngine` → eventi), trasporto (`Driver`/`NetServer`), presentazione (DTO + notifiche "cosmetiche" per le animazioni del tavolo).

---

## 4. Proposta di Architettura Rete (PC ↔ Telefoni)

### 4.1 Le tre opzioni reali, valutate

| | **A. Godot Web export per i telefoni** | **B. PWA leggera (HTML/TS) + server Godot** | **C. WebRTC data channel P2P** |
|---|---|---|---|
| Peso sul telefono | 30-60 MB, caricamento lungo, cache fragile | **< 200 KB, istantaneo** | < 200 KB |
| Iterazione UI | rebuild + re-export + hard refresh a ogni modifica | **hot reload, secondi** | secondi |
| Riuso codice | totale (stesse scene/script) | UI telefono separata (ma è un *controller*, non il tavolo) | UI separata |
| Rischio iOS/Safari | alto (WebGL/gl_compatibility, throttle in background, audio) | **basso** | medio (ICE, permessi) |
| Logica sul client | **rischio reale** (stesso motore sul telefono = anti-cheat impossibile) | **nessuna logica**: solo view + comandi | nessuna |
| Trasporto | WebSocket | **WebSocket (raw JSON)** | data channel + signaling |
| Rete/remoto | tunneling necessario | **tunneling necessario (o relay)** | NAT traversal (ma serve signaling + TURN) |
| Costo di manutenzione | due build della stessa app | due UI, un protocollo | due UI, un protocollo, più infrastruttura |

### 4.2 Raccomandazione: **opzione B**, con C come trasporto alternativo futuro

Il punto decisivo non è tecnico ma **architetturale**: il telefono deve essere un *thin controller*. Se il telefono esegue Godot, sul telefono gira anche il motore (o parte di esso), e l'autorità del server diventa una convenzione, non un fatto. Con la PWA il client **non può** calcolare nulla: riceve stato, invia comandi. È l'unico assetto in cui l'anti-cheat è strutturale anziché promesso.

Secondo motivo, pratico: la UI telefono è fatta di **4 schermate** (mano, prompt di priorità, selezione bersaglio, dado). Renderla in HTML/TS è un giorno di lavoro e si itera in secondi; con il Web export ogni modifica di layout costa un rebuild completo e un invalidamento di cache su ogni dispositivo.

Terzo: l'export Web di Godot 4.7 su iOS Safari è il punto più fragile dell'intera catena (memoria, sospensione, throttle). Non è dove vuoi scoprire problemi, la sera del playtest.

> Se in futuro si vuole **un solo codebase**, l'opzione A resta disponibile come "kiosk controller" per un tablet dedicato al tavolo — non per i telefoni dei giocatori.

### 4.3 Architettura proposta

```
┌──────────────────────── PC — "IL TAVOLO" (server autoritativo) ───────────────────────┐
│                                                                                       │
│  GameEngine (headless, nessun Node di scena, nessuna dipendenza dagli autoload)        │
│    ├── RulesCore        (MatchController rifattorizzato: validazione + transizioni)   │
│    ├── EventStack       (pila multi-entry: push, priority round, drain, SBA)           │
│    ├── TriggerEngine    (eventi canonici + effect_trigger/condition dal catalogo)      │
│    ├── MatchState       (UNICO stato serializzabile, state_version monotono)          │
│    └── StateSerializer  (PublicState / PrivateState[p] / Prompt[p])                   │
│                                                                                       │
│  NetServer (Node)                                                                     │
│    ├── WsServer        TCPServer + WebSocketPeer.accept_stream()  :8910                │
│    ├── SessionRegistry room_code, seat↔token, display_name, presence                 │
│    ├── CommandRouter   valida → applica → Event[] → delta di stato                    │
│    └── Broadcaster     PublicState a tutti · PrivateState al singolo · Prompt mirati  │
│                                                                                       │
│  TableView (Control)   disegna SOLO i DTO — zero regole                               │
└───────────────────────────────────────────────────────────────────────────────────────┘
              ▲                                    ▲
              │ WebSocket JSON (schema_version)    │
     ┌────────┴─────────┐                 ┌────────┴─────────┐
     │ Smartphone 1     │                 │ Smartphone N     │
     │ PWA: join / mano │                 │ PWA              │
     │ prompt / dado    │                 │                  │
     └──────────────────┘                 └──────────────────┘
```

**Perché WebSocket raw e non ENet / High-Level Multiplayer:** i client non sono Godot, quindi `MultiplayerAPI` non è utilizzabile. WebSocket (RFC 6455) passa attraverso proxy, hotspot e reti captive dove ENet UDP fallisce, e `WebSocketPeer` è nella stdlib di Godot. Il costo è l'overhead TCP: irrilevante per un gioco a turni con < 50 messaggi al minuto.

**LAN (stessa Wi-Fi):** il PC espone `:8910` e mostra un **QR code** con `ws://<ip-locale>:8910/?code=ABC123`. Zero configurazione per l'utente.

**Remoto (gioco a distanza / streaming del tavolo):** **non** aprire porte sul router. Due opzioni, in ordine di preferenza: (1) **Cloudflare Tunnel** (o Tailscale) che espone il WebSocket su un hostname HTTPS/WSS — semplice, senza modifiche al codice; (2) **WebRTC data channel** con il PC come peer e un piccolo server di signaling — utile se si vuole evitare ogni dipendenza esterna, ma aggiunge ICE/STUN/TURN e non elimina il server autoritativo. Il trasporto va dietro un'interfaccia (`Transport`) così il motore non cambia.

### 4.4 Protocollo (bozza normativa)

Tutti i messaggi: JSON, `{"v": 1, ...}`, campo `type`. `schema_version` negoziato all'handshake; client con versione diversa → rifiuto esplicito (mai "adattamento silenzioso").

| Direzione | Messaggio | Contenuto |
|---|---|---|
| S→C | `hello` | `protocol, schema_version, room_code, server_name` |
| C→S | `join` | `room_code, display_name, resume_token?` |
| S→C | `seat` | `player_id, token, public_state, private_state` |
| S→C | `state` | `version, public_state, private_state (solo il tuo), legal_actions[]` |
| S→C | `prompt` | `request_id, kind: priority\|target\|choice\|roll, deadline_ms, options[]` |
| S→C | `event` | `seq, type, payload` — **suggerimenti di presentazione** (animazione dado, danno, mostro morto) |
| C→S | `cmd` | `cmd_id, type, payload, request_id?` |
| S→C | `ack` | `cmd_id, ok \| rejected(reason)` |
| S→C | `error` | `code, message` (es. `stale_state`, `not_your_prompt`) |

**Invarianti di sicurezza (non negoziabili):**

1. Il client **non riceve mai** un `card_id` che non sia suo (tranne le carte pubbliche in tavola/negozio/pila).
2. Ogni `prompt` ha un `request_id` **single-use**; una risposta con `request_id` sbagliato, scaduto o di un altro giocatore viene rifiutata con `not_your_prompt`.
3. Ogni `cmd` è **idempotente** per `cmd_id` (retry di rete mobile non duplica un acquisto).
4. `player_id` **non** è mai preso dal payload: deriva dal token di sessione (seat). Mai "fidarsi del client".
5. Il dado lo tira **il server** (`Rng`); il client riceve il valore e lo anima. Il "tiro" è un evento di presentazione, non un input.
6. Rate limit per connessione + `state_version` nei comandi per scartare comandi basati su stato vecchio (`stale_state`).
7. Nessun segreto nel client: nessun seed, nessun mazzo, nessuno stato futuro.

### 4.5 Riconnessione e presenza

- Il `token` di seat è generato dal PC e conservato dal telefono in `localStorage`; alla riconnessione il giocatore **rientra nel suo seat** senza rivelare nulla agli altri.
- `presence` (connesso / disconnesso / in attesa) è **pubblica** e mostrata sul tavolo: è informazione che nel gioco fisico è ovvia.
- Timeout di prompt configurabile (default: nessun timeout in locale, 60 s in remoto con auto-pass dichiarato a schermo). Il timer è **server-side**: il client può solo mostrarlo.

---

## 5. Piano d'Azione Step-by-Step (5 milestone)

Regola generale: **ogni milestone è giocabile e verificabile da sola**, e nessuna introduce carte nuove. Le 23 self-check devono restare verdi a ogni passo (migrandole a GUT in M1).

### M1 — Disaccoppiare il motore dal suo ambiente *(fondamenta, zero rete)*

**Deliverable**
- `GameEngine` senza dipendenze dagli autoload globali: `EventBus`, `Rng`, `CardDB`, `Log` iniettati (interfacce); `setup()` idempotente + `teardown()` esplicito; `CardEffectRegistry` con `match_id` e `reset()`.
- `PriorityEngine` + `PriorityRequest` che **sostituisce** `await EventBus.priority_given`; interfaccia `Driver` con tre implementazioni: `TestDriver` (robot), `HotseatDriver` (overlay attuale), e in M3 `NetDriver`.
- `MatchState` unico e serializzabile (`to_dict/from_dict`, `state_version`), che incorpora mostri, negozio, mazzi, scudi, pila. Eliminazione della doppia semantica di scudo.
- **`docs/COMPREHENSIVE_RULES_DIGITAL.md`**: normativa scritta della priorità/pila (risolve D4), con la decisione esplicita su cosa consuma il limite di loot e cosa può fare un giocatore non attivo.
- Migrazione dei 23 self-check a **GUT** (stessa logica, fixture esplicite, niente flag su membro).

**Acceptance:** `23/23 PASS` con driver iniettato; nessun `await` su segnale globale nel motore; snapshot → `from_dict` → snapshot identico (round-trip) su una partita a metà combattimento; nessun residuo fra due `setup()` consecutivi.

**Rischio:** è il refactor più invasivo. Mitigazione: farlo **senza** cambiare comportamento (i 23 check sono il contratto), in branch dedicato.

### M2 — Protocollo, DTO e comandi *(il confine pubblico/privato)*

**Deliverable**
- `PublicState` / `PrivateState[p]` / `Prompt` / `legal_actions[]` prodotti dal motore; `StateSerializer` con snapshot full + delta.
- `Command` + `CommandRouter` con validazione centralizzata (turno, fase, limiti, disponibilità) e `rejected(reason)` parlanti.
- `game_scene.gd` rifattorizzata a **sola vista**: disegna DTO, emette comandi, mostra rifiuti. Rimozione di `hand.erase`, `_next_player`, `buy_limit`, scelta del bersaglio, "primo item playable".
- Test di **non-leak**: la vista di P2 non contiene mai la mano di P1 (e viceversa), né carte dei mazzi.

**Acceptance:** la scena hotseat è indistinguibile per l'utente ma non contiene **nessun** `if` di regolamento; `ui_drive_test` verde; test di non-leak verde; un comando illegale risponde `rejected` con motivazione, senza effetti collaterali.

### M3 — Server WebSocket sul PC + PWA minima *(primo gioco asincrono reale)*

**Deliverable**
- `WsServer` (TCPServer + `WebSocketPeer.accept_stream`), `SessionRegistry` (room code, seat, token, reconnect), `Broadcaster`, `NetDriver` che implementa `Driver`.
- PWA (`client/`): join con QR/codice, mano, prompt di priorità (**Passa / Rispondi**), selezione bersaglio, dado animato, indicatore presenza.
- Lobby sul PC: creazione stanza, QR, elenco seat, avvio partita.

**Acceptance:** **due telefoni reali (iOS + Android) in LAN** completano un turno con finestra di priorità e un attacco; latenza < 100 ms; riconnessione entro 10 s nello stesso seat; un telefono non vede mai la mano di un altro (verificato sui payload, non a occhio).

**Rischio:** WebSocket su iOS in background → gestione esplicita della riconnessione (token + `state_version`), non "sperare che regga".

### M4 — TriggerEngine e pila completa *(fedeltà al 100%)*

**Deliverable**
- Eventi canonici: `ON_DAMAGE`, `ON_DIE_ROLL`, `ON_MONSTER_DEATH`, `START_OF_TURN`, `ON_ATTACK_DECLARED`, `ON_LOOT_PLAYED`, `ON_TURN_END`… come **contratto pubblico** del motore.
- Interprete `effect_trigger` / `effect_condition` (predicati registrati, non `eval`); **Gurdy, Monstro, Fistula diventano realmente funzionanti**.
- Pila multi-entry con round di priorità per entry, drain completo, **SBA** e **fizzling** su target invalido; "attack declared" come entry; risposte annidate (rimozione dell'atomicità del loot in risposta).
- Eterni e modificatori come **effetti sulla pila da dati** (`activation_type`, `activation_cost`), rimozione del `match` hardcodato in `use_eternal_item`.
- Registro generico degli effetti "fino a fine turno" (non solo scudi).

**Acceptance:** i 3 mostri hanno test che ne verificano il comportamento; catena di risposte a **due livelli** (Bomb → risposta → risposta) verificata; nessun effetto carta hardcodato nel controller (grep: zero `match card.id`); pila vuota garantita alla fine di ogni flusso (invariante testata).

### M5 — Remoto, robustezza e anti-cheat *(prodotto)*

**Deliverable**
- Trasporto remoto documentato (Cloudflare Tunnel / Tailscale) dietro l'interfaccia `Transport`, con fallback WebRTC data channel valutato.
- Persistenza partita (snapshot su disco + command log) → **resume** dopo crash o chiusura del PC.
- Replay deterministico da `command log` + seed; audit anti-cheat (`cmd` rifiutati, prompt scaduti, risposte fuori ordine).
- Timer di priorità opzionali, modalità spettatore/tavolo, test di carico 6 client.

**Acceptance:** partita remota completa 4 giocatori, 20 turni, **zero desync**; resume dopo kill del processo server con stato identico (hash dello snapshot); replay che riproduce esattamente la stessa partita; nessun payload contiene dati privati altrui.

### Sequenza e dipendenze

| Milestone | Prerequisito | Sblocca | Carte nuove? |
|---|---|---|---|
| M1 Fondamenta | — | tutto il resto | ❌ |
| M2 Protocollo/DTO/Comandi | M1 | M3 | ❌ |
| M3 Server + PWA | M1, M2 | playtest asimmetrico reale | ❌ |
| M4 TriggerEngine + pila completa | M1 (M2 consigliato) | catalogo fedele, espansioni | ❌ (solo i 3 mostri già dichiarati) |
| M5 Remoto/hardening | M3, M4 | gioco a distanza | ❌ |

**Solo dopo M4** ha senso riprendere l'import delle ~66 carte mancanti del set base: a quel punto una carta è una riga di CSV + (se serve) un piccolo `CardEffect`, e non consolidа ulteriore debito.

---

## 6. Decisioni che richiedono la tua approvazione

> **RATIFICATE il 2026-11-10 — questa sezione è storica.** Le cinque decisioni
> sono state approvate e sono entrate in vigore come normativa in
> `docs/RULES_NORMATIVE.md` §11: P1 = PWA + WebSocket; P2 = `MatchState` unico
> serializzabile; P3 = driver iniettato con `request_id`, validazione del
> giocatore, azioni legali e risoluzione ricorsiva; P4 = **2 slot mostro base**
> su lista dinamica; P5 = Loot gratuito solo in `action`, extra/fuori turno =
> tap del personaggio, morte con scelta del Loot da scartare. M1 è stata
> implementata di conseguenza (27/27 self-check verdi).

Prima di toccare il codice, servono cinque risposte. Le prime tre cambiano l'architettura; le ultime due cambiano le regole.

| # | Decisione | Opzioni | Mia raccomandazione |
|---|---|---|---|
| **P1** | **Client dei telefoni** | (a) PWA HTML/TS + WebSocket · (b) Godot Web export · | **(a)** — anti-cheat strutturale, iterazione in secondi, nessun engine sul telefono. Il costo è una seconda UI *controller*, non una seconda UI *tavolo* |
| **P2** | **Fonte di verità dello stato** | (a) `MatchState` unico serializzabile (mostri/negozio/mazzi/pila dentro) · (b) lasciare lo stato sparso e serializzare un aggregato in sola lettura | **(a)** — serve per resume, delta e riconnessione. (b) sembra più economico ma va rifatto in M5 |
| **P3** | **Sostituzione di `await EventBus.priority_given`** | (a) `PriorityEngine` + `Driver` iniettato · (b) mantenere il segnale e aggiungere `request_id` attorno | **(a)** — (b) non risolve lo spoofing né il multi-sessione e crea due meccanismi da mantenere |
| **P4** | **Slot mostro: 2 o 3?** | (a) 2 (come il codice) · (b) 3 (come `CLAUDE.md`) | Da decidere **guardando il regolamento fisico**: il codice e la doc si contraddicono (D1). Non posso deciderlo io: è una regola |
| **P5** | **La priorità è un'estensione homebrew: cosa consuma?** | Rispondere con un Loot fuori turno consuma (a) lo slot "effetto personaggio", (b) uno slot dedicato alle reazioni, (c) nessun limite | **(b)** se volete che la pila sia davvero usabile; **(a)** se volete che le reazioni restino rare. Va scritto in `COMPREHENSIVE_RULES_DIGITAL.md` |

Finché P1-P3 non sono ratificate non scrivo codice: sono le tre scelte che rendono il refactor non rinviabile.

---

*Fine audit. Nessun file di codice è stato modificato in questa fase. L'unico file scritto da questa fase è questo report; l'implementazione di M1 è registrata in `PROJECT_STATUS.md`.*
