# PROJECT_STATUS.md — Four Souls Digital

> Fonte di verità sullo stato del progetto. Aggiornato alla fine di ogni
> metaprompt (istruzione permanente: sezione "Project status" in CLAUDE.md).
> Ultimo aggiornamento: **Milestone 1 — fondamenta** (2026-11-10): stato unico
> serializzabile (`MatchState`) con snapshot per-vista (la mano altrui non
> esce mai dal confine pubblico), `GameState` ridotto a facciata, input via
> `MatchDriver` iniettato con `request_id`/`player_id` validati e azioni
> legali calcolate dal motore, risoluzione ricorsiva della pila (le entry
> create durante una risoluzione non vengono più distrutte),
> `setup()`/`teardown()` idempotenti e `CardEffectRegistry.reset()`,
> normative scritte in `docs/RULES_NORMATIVE.md` (slot 2, Loot/tap, morte con
> scelta del Loot). Self-check: **27/27 PASS** (STEP U-Z + AA-AD).
>
> Precedente: **Metaprompt 07 — stack build** (2026-08-24): coda/stack
> eventi tipizzata (`EventStack`: pending_roll / pending_effect / modifier) con
> `resolve_top()` e cascata modifier→roll; `advance_active_player()` SEMPRE a
> fine ending phase; combattimento = roll → finestra priorità → risoluzione →
> danno → morte → ricompensa da dati carta → refill → `reset_combat_state()`
> su OGNI percorso (morte inclusa); D6/Belial come modifier generici sul
> pending_roll (Belial applicato all'attivazione, reroll D6 differito alla
> risoluzione); Yum Heart = scudo di PREVENZIONE (apply/consume/expire), non
> cura; i 6 ESEMPI del metaprompt sono test eseguibili (STEP U-Z, 23/23 PASS).

## 1. Cosa è implementato (per componente)

| Componente | File | Stato | Note |
|---|---|---|---|
| Import pipeline CSV → .tres | `scripts/tools/card_importer.gd`, `import_cards.gd`, `run_import_cli.gd` | fatto | 34 carte; validazione rumorosa (script mancanti, id duplicati, numeri non parsabili); idempotente |
| CardResource (dati puri) | `scripts/core/card_resource.gd` | fatto | stats, text, simple_effect, trigger_events, roll_bonus/damage_bonus, campi eterni/personaggio/boss |
| **MatchState (M1)** | `scripts/core/match_state.gd` | fatto | UNICO stato di partita, puro e serializzabile: `to_dict()` (immagine autoritativa) / `load_from_dict()` (roundtrip con re-resolution delle carte) / `snapshot_for(player_id)` (DTO per vista: mano propria completa, altrui solo come conteggio) |
| **MatchDriver (M1)** | `scripts/core/drivers/match_driver.gd`, `local_ui_driver.gd` | fatto | contratto di input del motore: richiesta con `request_id`, `player_id`, entry e `legal_actions`; risposta valida solo con identità corrispondente; `LocalUiDriver` = adapter hotseat (await su `priority_given`/`player_death_resolved`); M3 aggiunge il SocketDriver senza toccare il motore |
| **EventStack (MP07/M1)** | `scripts/core/event_stack.gd` | fatto | coda LIFO tipizzata: `pending_roll` (r#), `pending_effect` (e#), `modifier` (m#); **`resolve_batch()`** risolve in un blocco le entry presenti alla chiusura della finestra (niente cascata hardcoded modifier→roll) con guardia anti-loop; le entry create durante la risoluzione ottengono una nuova finestra nel loop del controller |
| CardEffect (base scripted) | `scripts/core/card_effect.gd` | fatto | hook on_play/on_attacked/on_killed/on_event/get_roll_bonus/get_damage_bonus |
| CardEffectRegistry | `scripts/core/card_effect_registry.gd` | fatto | chiavi per instance_id; dispatcher policy (attivo primo, orario, ordine registrazione); switch simple_effect; unmount lifecycle |
| EventBus | `scripts/autoload/event_bus.gd` | fatto | + MP07 stack build: `active_player_advanced`, `stack_entry_pushed/resolved/cleared`, `shield_applied/consumed/expired`, `combat_state_reset`; priority_pending ora trasporta il TIPO di entry (`pending_roll`/`pending_effect`) |
| GameState | `scripts/autoload/game_state.gd` | fatto (M1: facciata) | NON possiede più stato: `players`/`current_player_index`/`phase`/`soul_values`/`shields` sono viste su `GameState.state` (MatchState); restano i mutatori che emettono gli eventi (+ `advance_active_player`, scudi, win a 4 soul value) |
| Rng | `scripts/autoload/rng.gd` | fatto | seam `rng` tipizzata Object: i test injectano stub duck-typed (FakeRng) per dadi scriptati |
| Log | `scripts/autoload/log.gd` | fatto | warn/error sempre stampati |
| Turn loop (self-play) | `scenes/turn_loop_test.gd` | fatto | il test È il driver (`ScriptedDriver` iniettato): le politiche si scambiano su `_driver.policy`, non su segnali globali; riproduce i 6 ESEMPI (U-Z) + i check M1 (AA-AD) |
| MatchController | `scripts/core/match_controller.gd` | fatto (M1) | regole + stato transitorio (pila, lock) su `MatchState`; fasi start/action/combat/end; **input solo dal driver** (`_build_priority_request` → `_ask_priority` → validazione `request_id`+`player_id`); azioni legali calcolate dal motore (`_legal_actions`, usate anche dall'auto-pass); **risoluzione ricorsiva** (`_resolve_stack`: finestra per cima, blocco LIFO, repeat) con guardia; Loot addebitata nel motore (1 gratuita in action, poi tap personaggio); morte con scelta del Loot; `setup()` chiama `teardown()` (idempotente) |
| Effetti scriptati | `scripts/cards/effects/*.gd` | fatto (3) | the_bible, soul_of_hope, money_is_power (bomb spostata su data path: una riga di dati) |
| Effetti data-driven | CSV `simple_effect` | fatto (8) | dinner/pennies/full_health/swallowed_penny/**bomb** + passivi sack/change_purse/crows_heart |
| Personaggi + oggetti eterni | CSV | fatto (3+3) | Isaac/D6, Judas/Belial Book (±1 immediato all'attivazione), Magdalene/Yum Heart (`prevent_damage`: scudo, non heal) |
| UI (scena giocabile hotseat) | `scenes/game_scene.gd` + `.tscn` | NON TOCCATA in MP07 | compatibile: `get_pending_roll()` shim letto dallo stack; le finestre usano gli stessi segnali priority_*; nota cosmetica: label "heal" sul bottone Yum Heart ormai storicizzata (il motore applica lo scudo) |
| Test GUT | — | non iniziato (deliberato) | il self-check headless fa da guardia (27/27, exit code = esito). GUT richiede un addon da scaricare: da decidere in M2, non vendored ora |
| Networking / Curse | — | non iniziati | fasi successive |

## 2. Catalogo carte

- **Totale: 34** (set base reale ~100 → ~34%)
- Per tipo: MONSTER 15 · LOOT 6 · TREASURE 7 · CHARACTER 3 · ITEM_ACTIVE (eterni) 3
- Comportamento: scripted **3** (the_bible, soul_of_hope, money_is_power) · data-driven **8** (incl. bomb=damage_monster 2) · modifier dati roll/damage bonus (steven, blood_clot, …) · carattere/eterno **6** · vanilla 14
- Sorgente di verità: `data/cards_base_set_template.csv`

## 3. Fedeltà al regolamento (differenze MP07)

| Aspetto | Stato | Nota |
|---|---|---|
| Stack/priorità reale | implementato (MP07) | qualunque pending_* in cima apre finestra a TUTTI i giocatori in ordine di turno dal giocatore attivo; pass consecutivi → resolve_top LIFO; risposta riavvia il round dall'attivo |
| Modifier su tiri (D6/Belial) | implementato (MP07) | GENERICI sul pending_roll in cima: niente modifiche preventive (fuori finestra → "no_pending_roll"); Belial ±1 applicato ALL'ATTIVAZIONE, reroll D6 differito ALLA RISOLUZIONE ("r# value changes from X to Y") |
| Chiusura combattimento | implementato (MP07) | kill: ricompensa DA DATI CARTA (+soul boss + check vittoria automatico), discard carta mostro, refill slot, `reset_combat_state()` (stack verificato vuoto); percorso morte: STESSO reset, mai busy |
| Yum Heart | implementato (MP07) | PREVENZIONE: apply_shield → consume (0 hp persi) o expire a fine turno del PROPRIETARIO (+ recharge); bersagli anche i mostri (scudo per istanza) |
| Loot sullo stack | implementato (MP07) | giocare loot = pending_effect + finestra a tutti → "X resolves"; loot in risposta atomico (semplificazione documentata) |
| Loot: costo del tap (M1, ratifica #5) | implementato | 1 giocata gratuita nella propria `action`; seconda o fuori turno → `character_tapped = true`, ricarica nella `start` del turno successivo; la carta esce dalla mano nel motore |
| Morte (M1, ratifica #5) | implementato | 1¢, tap di personaggio e oggetti, **scelta** del Loot da scartare (automatico solo con 1 carta), scelta oggetto, poi ending phase + advance |
| Slot (M1, ratifica #4) | implementato | 2 slot mostro base e 2 negozio; `table_monsters` è una lista dinamica |
| Roll d'attacco / danno / morte / win 4 soul / shop 10¢ / 2 slot / limiti azioni / heal pieno fine turno / morte-penalità | implementato | vedi metaprompt precedenti (MP05-06) |
| Ordine effetti simultanei | policy deterministica | attivo → orario → registrazione; nessuna scelta umana |
| Cap HP 6, curse | assenti | — |

## 4. È giocabile da un umano oggi?

**SÌ (con limiti) — in attesa del playtest di conferma dell'utente
(`run_game.bat`).** Fix post-playtest (MP07 hotfix): le finestre di priorità
ora chiedono SOLO i giocatori con risposte disponibili (il resto auto-passa:
"passes priority … (no responses available)") — niente più cambio-dispositivo
a ogni tiro se nessuno può rispondere; `await` sulle giocate loot della UI
(eliminati SCRIPT ERROR a ogni carta); Yum Heart di nuovo utilizzabile
(ramo `prevent_damage` nella UI, bersaglio a scelta); rifiuti d'attacco
ora loggati invece che silenziosi. Verificato con driver headless della
scena reale (`scenes/ui_drive_test.tscn`): P1 e P2 comprano/giocano/
attaccano/chiudono turno senza blocchi. Limiti noti: loot-in-risposta
atomico; nessuna arte.

## 5. Self-check automatici (in `scenes/turn_loop_test.gd`)

| Check | Verifica | Stato |
|---|---|---|
| STEP A/C/F/G/H/I/J/K/L/N | regressioni MP03-MP07 (copie duplicate, lifecycle, bonus aggregati, penalità morte, eterni sul pending, limiti, heal-at-max, alternanza, 3¢, shop) | PASS |
| M | "stop" su pending_roll ignorato: l'attack finisce solo per kill/morte | PASS |
| O | timing modifier: rifiutato fuori finestra, accettato nella finestra del pending_roll, rifiutato dopo | PASS |
| P | finestra chiede PRIMA l'attivo; il non-attivo risponde loot (atomico) + eterno | PASS |
| R/S/T | descrizioni item, campi effetto mostri, soul boss contano doppio, win a 4 | PASS |
| **U (ESEMPIO 1)** | ending phase nell'ordine heal_players→heal_monsters→discard→refill poi `advance_active_player` SEMPRE; 4 cicli P1→P2→P1→P2; il draw spetta al NUOVO attivo | PASS |
| **V (ESEMPIO 2)** | roll grezzo 2 → PUSH pending_roll → priorità [P1,P2]: P2 (non attivo) attiva D6 → PUSH modifier → restart dall'attivo → risoluzione: "reroll 2→5" poi "5 vs die 3 HIT"; ricompensa da dati carta; stack vuoto | PASS |
| **W (ESEMPIO 2b)** | raw 3 → Belial +1 APPLICATO ALL'ATTIVAZIONE (valore 4 pre-risoluzione) → "4 vs die 4 HIT" | PASS |
| **X (ESEMPIO 3)** | kill: reset x1 + re-attack al turno successivo OK; morte: outcome player_died, reset x1, stack vuoto, mai "busy" | PASS |
| **Y (ESEMPIO 4)** | scudo applicato/consumato (99 danni assorbiti, 0 hp persi)/scaduto a fine turno proprietario + recharge | PASS |
| **Z (ESEMPIO 5)** | Bomb → pending_effect; la finestra chiede [attivo, NON-attivo]; "Bomb resolves: Gaper takes 2 damage" | PASS |
| **AA (ratifica #3)** | risposta con `request_id` scaduto → pass; risposta di un altro giocatore → pass; risposta correttamente legata → accettata | PASS |
| **AB (ratifica #2)** | `snapshot_for(0)` contiene la mano di P1 e solo il CONTEGGIO di quella di P2; `snapshot_for(-1)` (tavolo) non contiene nessuna mano | PASS |
| **AC** | `to_dict()` → `load_from_dict()` conserva giocatori, mani, mazzi, tavolo, negozio, fase, anime e ri-risolve le carte | PASS |
| **AD** | `teardown()` due volte: zero effetti, zero scudi, zero giocatori, pila distrutta; lo stesso controller torna giocabile con un nuovo `setup()` | PASS |

Totale: **27/27 PASS**. Exit code 1 se anche uno fallisce; riepilogo finale = termometro.
Canary separata della UI hotseat: `scenes/ui_drive_test.tscn` (turno P1 → passaggio dispositivo → turno P2, con finestre di priorità e chiusura combattimento).

## 6. Decisioni architetturali

- **Chiuso in MP07 (stack build):** (a) modifier generici sul tipo `pending_roll`, non casi speciali; (b) Belial applicato subito, D6 alla risoluzione (fedele alle due sequenze esempio); (c) loot in risposta = atomico senza nested window (semplificazione Fase 1, da rivedere se servono catene di risposte); (d) `reset_combat_state` unico punto di riabilitazione ATTACK, chiamato anche nel path morte; (e) **auto-pass** per i giocatori senza risposte disponibili nella finestra (fedele al testo "finestra visibile a tutti i giocatori con item/loot disponibili").
- **Strumenti:** `scenes/ui_drive_test.tscn` — driver headless che pilota la scena hotseat reale tramite i suoi handler (canary anti-regressione del flusso P1↔P2).
- **Chiuso in M1 (ratifiche #2/#3/#4/#5):** stato unico serializzabile + snapshot per vista; `GameState` = facciata; input solo dal driver con identità validata; pila risolta ricorsivamente (niente entry distrutte); `teardown()` idempotente + `CardEffectRegistry.reset()`; 2 slot mostro, Loot con costo del tap, morte con scelta del Loot. Normativa in `docs/RULES_NORMATIVE.md`.
- **Aperte:** TriggerEngine per `effect_trigger` dei mostri (M4); cap HP 6; curse; ordine di scelta tra effetti simultanei; GUT da valutare in M2.
- **Prossimo (M2):** protocollo comandi + DTO di rete sui snapshot già esistenti; UI che legge solo snapshot e non tocca più `GameState`; migrazione possibile del self-check a GUT.
