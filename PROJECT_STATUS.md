# PROJECT_STATUS.md — Four Souls Digital

> Fonte di verità sullo stato del progetto. Aggiornato alla fine di ogni
> metaprompt (istruzione permanente: sezione "Project status" in CLAUDE.md).
> Ultimo aggiornamento: **Metaprompt 06** (2026-08-16) — STEP 1-2,4: ordine log
> (roll prima del danno), correzioni regole a-g (2 slot, shop 10¢, azioni
> libere con limiti, heal pieno fine turno, attacco multi-roll, morte con
> penalità, personaggi + oggetti eterni); §4 in attesa del playtest (STEP 4).

## 1. Cosa è implementato (per componente)

| Componente | File | Stato | Note |
|---|---|---|---|
| Import pipeline CSV → .tres | `scripts/tools/card_importer.gd`, `import_cards.gd`, `run_import_cli.gd` | fatto | 32 carte; validazione che fallisce in modo rumoroso (script mancanti, id duplicati, campi numerici non parsabili); idempotente; entry CLI con `<csv_path> <output_dir>` opzionali; campi nuovi MP06: `is_eternal`, `eternal_action`, `recharges_on_turn_end`, `character_effect`, `eternal_item_id` |
| CardResource (dati puri) | `scripts/core/card_resource.gd` | fatto | stats, text, `simple_effect`/`simple_effect_value`, `trigger_events`, `roll_bonus`, campi eterni/personaggio (MP06) |
| CardEffect (base scripted) | `scripts/core/card_effect.gd` | fatto | hook `on_play`/`on_attacked`/`on_killed`/`on_event`/`get_roll_bonus` |
| CardEffectRegistry | `scripts/core/card_effect_registry.gd` | fatto | chiavi per `instance_id` (copie duplicate coesistono); wiring trigger via **dispatcher con policy** (giocatore attivo per primo, poi senso orario, stesso giocatore in ordine di registrazione); unmount lifecycle; switch `simple_effect` (`gain_cents`, `gain_hp`, `damage_monster`); `get_roll_bonus()` aggregato data+scripted; `unregister_card_by_card_id()` per la penalità di morte (MP06) |
| EventBus | `scripts/autoload/event_bus.gd` | fatto | segnali turno / economia / combattimento / carte / soul-win; MP06: `monster_attacked` esteso (roll/bonus/die_value, emesso PRIMA del danno), `attack_response_pending/given`, `player_died/death_resolved`, `hp_restored`, `monsters_restored`, `eternal_used` |
| GameState | `scripts/autoload/game_state.gd` | fatto | `players: Array[Dictionary]` con template esteso (max_hp, damage, limiti azione, character/eternal); `heal` con regola "a HP pieni → max HP permanente" (MP06 g); `restore_hp` (fine turno, senza regola max); win a 4 soul |
| Rng | `scripts/autoload/rng.gd` | fatto | `roll_die`/`shuffle`/`seed_rng`; `RandomNumberGenerator` iniettabile |
| Log | `scripts/autoload/log.gd` | fatto | `warn`/`error` sempre in console (headless-safe) |
| Turn loop (self-play) | `scenes/turn_loop_test.gd` | fatto | 2 giocatori, 3 round, robot buy→loot→attack, **2 slot mostro** con riempimento automatico, seed deterministico (default 8), riepilogo PROJECT_STATUS in coda; robot risponde a `attack_response_pending` e `player_died` in modo deferito; **guida il `MatchController`** (le regole vivono lì, il test decide solo le mosse) |
| MatchController (regole condivise) | `scripts/core/match_controller.gd` | fatto | `setup`/`begin_turn`/`end_turn`/`buy`/`attack`/`play_loot`/`draw_loot`/`card_resource`/`is_bought`/`use_eternal_item`; possiede **2 slot mostro** + shop; MP06: limiti per-turno (1 buy, 1 attack, 1 loot + 1 via effetto personaggio), attacco = sequenza di roll con finestra di risposta async, `die()` async con penalità (1¢ + 1 loot + 1 oggetto scelto, eterno protetto), assegnazione personaggi, `_resolve_end_of_turn` (recharge eterni + heal pieno per tutti), azioni rifiutate con motivo nel payload; driver unico per robot test E UI umana |
| Effetti scriptati | `scripts/cards/effects/*.gd` | fatto (4) | bomb, the_bible, soul_of_hope, money_is_power |
| Effetti data-driven | CSV `simple_effect` | fatto (7) | dinner/pennies/full_health/swallowed_penny + passivi sack_of_pennies/change_purse/crows_heart |
| Modificatore dati statico | CSV `roll_bonus` | fatto (1) | steven (+1) |
| Personaggi + oggetti eterni | CSV | fatto (3+3) | Isaac/D6, Judas/Belial Book, Magdalene/Yum Heart (MP06 g) — vedi §3 |
| UI (scena giocabile hotseat) | `scenes/game_scene.gd` + `.tscn` | fatto (MP06) | nessuna arte: Label/Button; attacco = click sullo slot mostro, target carte = click sul mostro, shop con TUTTE le carte insieme, overlay pass-device, log testuale, restart su morte/win; MP06: **2 slot mostro**, pulsanti RESOLVE/STOP durante l'attacco multi-roll, riga oggetti eterni (D6/Belial usabili in finestra d'attacco, Yum Heart con scelta bersaglio), overlay scelta oggetto da scartare alla morte |
| Test GUT | — | non iniziato | i self-check del turn loop fanno da guardia per ora |
| Networking | — | non iniziato | fase 3 |
| Curse | — | non iniziato | nessuna carta curse |

## 2. Catalogo carte

- **Totale: 32** (set base reale ~100, totale con espansioni ~340+ → ~9%)
- Per tipo: MONSTER 14 · LOOT 6 · TREASURE 6 · CHARACTER 3 · ITEM_ACTIVE (eterni) 3
- Per comportamento:
  - scripted (`effect_script_path`): **4** — bomb, the_bible, soul_of_hope, money_is_power
  - data-driven (`simple_effect`): **7** — dinner, pennies, full_health, swallowed_penny, sack_of_pennies, change_purse, crows_heart
  - data modifier (`roll_bonus`): **1** — steven
  - carattere/eterno (`character_effect`/`eternal_action`): **6** — isaac/judas/magdalene, eternal_d6/eternal_belial_book/eternal_yum_heart
  - vanilla (senza comportamento): **14** — tutti i mostri
- Sorgente di verità: `data/cards_base_set_template.csv` (i `.tres` sono generati, non da modificare a mano)

## 3. Fedeltà al regolamento reale di Four Souls

| Aspetto | Stato | Nota |
|---|---|---|
| Roll d'attacco 1d6 + modificatori vs die value | implementato fedelmente | bonus data + scripted aggregati da registry; **multi-roll**: si continua finché il mostro muore, il giocatore si ferma o muore (MP06 e) |
| Danno mostro / morte (hp, soul_reward, reward cents) | implementato fedelmente | per istanza, via eventi |
| Win condition (4 soul) | implementato fedelmente | il test si ferma prima (3 round) |
| Fasi del turno (main/buy/end) | **implementato** (MP06 c) | ordine libero in main phase; limiti: 1 buy, 1 attack, 1 loot + 1 via effetto personaggio per turno; End Turn esplicito in UI |
| Area mostri multipla (2 slot) | **implementato** (MP06 a) | 2 slot con riempimento automatico alla morte; target per `instance_id`; semplificato: il self-play sceglie lo slot 0, la scelta umana è già nella UI (click sullo slot) |
| Scelte del giocatore (target, acquisti, carte da giocare) | **implementato** | UI: click sullo slot mostro per attaccare, click sul mostro per il target di Bomb/Bible/oggetti, shop, carte in mano, End Turn esplicito, RESOLVE/STOP tra i roll |
| Personaggi + oggetti eterni | **implementato** (MP06 g) | assegnati in `setup` (random, seed-dipendente); Isaac=D6 (reroll), Judas=Belial Book (±1), Magdalene=Yum Heart (heal 1, a HP pieni aumenta il max); effetto personaggio = giocare 1 loot extra (anche nel turno altrui); **D6/Belial ricaricano a fine E inizio turno del proprietario** |
| Shop a 10¢ | **implementato** (MP06 b) | tutti i tesori costano 10¢ (reimportato da CSV); ogni tesoro acquistabile una sola volta per giocatore |
| Morte giocatore | **implementato** (MP06 f) | penalità: perdi 1¢, 1 loot a caso, 1 oggetto a scelta (l'eterno è protetto); poi heal pieno, il match continua |
| Heal pieno a fine turno | **implementato** (MP06 d) | tutti i giocatori e tutti i mostri in tavola tornano a HP pieni a fine turno (`restore_hp`, senza la regola del max permanente) |
| Heal a HP pieni → +max HP permanente | **implementato** (MP06 g) | `GameState.heal` (anche l'eccesso va al max); `restore_hp` (fine turno) NON aumenta il max |
| Recharge (tap/untap oggetti) | **implementato** (MP06 g) | oggetti eterni con `recharges_on_turn_end` (D6/Belial); Yum Heart si ricarica solo a inizio turno |
| Ordine/priorità effetti simultanei | **implementato** | policy deterministica: giocatore attivo per primo, poi senso orario, stesso giocatore in ordine di registrazione/acquisto; semplificato: nessuna scelta umana dell'ordine |
| Hand / discard loot | parziale | hand esiste in GameState; il loop gioca subito la loot pescata; la penalità di morte scarta 1 loot a caso; discard per reshuffle |
| Cap HP (6) | assente | heal non cappato |
| Curse | assente | — |

## 4. È giocabile da un umano oggi?

**IN ATTESA DEL PLAYTEST (STEP 4 di MP06, da fare dall'utente con `run_game.bat`).**
La UI hotseat è implementata e i self-check girano (7/7 PASS): il verdetto
diventa "SÌ (con limiti)" dopo la conferma dell'utente che ha provato una
partita vera (2 slot mostro, shop 10¢, ordine libero con limiti, heal pieno
fine turno, attacco multi-roll con RESOLVE/STOP, morte con penalità e scelta
oggetto, personaggi/eterni).

Limiti noti della versione attuale:
1. Nessuna arte: carte come Label/Button testuali.
2. Solo 2 giocatori, nessuna scelta dell'ordine effetti simultanei (policy fissa).
3. La loot pescata non si tiene in mano tra turni (hand = solo turno attivo) e il
   gioco della loot è limitato (vanilla si tiene, comportamento si gioca).
4. Le azioni "difensive" dell'avversario nel tuo turno (loot via effetto
   personaggio, oggetti eterni) sono supportate dal motore (verificato da STEP
   H/I) ma NON raggiungibili dalla UI hotseat a schermo singolo.
5. HP non cappato a 6, niente curse.

## 5. Self-check automatici presenti (in `scenes/turn_loop_test.gd`)

| Check | Verifica | Stato |
|---|---|---|
| STEP A (MP03) | coesistenza copie duplicate: 2 Sack of Pennies registrati → `turn_started` dà +6¢ (non +3) | PASS |
| STEP C (MP03) | lifecycle effetti: 5 Bomb giocate → `_effects` invariato (nessun accumulo) | PASS |
| STEP F (MP02) | aggregazione roll bonus: Steven(+1) + Money=Power a 10¢(+2) = 3 (self-contained, non tocca il match) | PASS |
| STEP G (MP06) | morte: penalità 1¢ + 1 loot + 1 oggetto (scelto), heal pieno, mostro in tavola a HP pieni a fine turno | PASS |
| STEP H (MP06) | oggetti eterni: D6 reroll + Belial ±1 modificano il roll nella finestra di risposta; ricarica a fine+inizio turno del proprietario | PASS |
| STEP I (MP06) | limiti azioni: 1 buy / 1 attack / 1 loot + 1 via effetto personaggio (anche nel turno altrui), ricarica a inizio turno del proprietario | PASS |
| STEP J (MP06) | heal a HP pieni → max HP permanente (+1 e +2, anche l'eccesso) | PASS |

I check falliscono con exit code 1 (il test è fail-fast). Il riepilogo finale
conta pass/falliti (termometro). I check girano sul turn loop a **2 slot mostro**
(post-MP06) e il robot risponde in modo deferito alle finestre di attacco e di
morte (niente deadlock).

## 6. Decisioni architetturali aperte

- **Chiuso in MP05:** (b) mostri multipli → implementati; (c) priorità effetti → policy deterministica documentata e implementata.
- **Chiuso in MP06:** (a) 2 slot mostro; (b) shop 10¢ via CSV; (c) ordine libero con limiti; (d) heal pieno fine turno; (e) attacco multi-roll async con finestra di risposta; (f) morte con penalità (1¢/1 loot/1 oggetto scelto, eterno protetto), match mai terminato dalla morte; (g) personaggi + oggetti eterni con recharge. Log: il roll d'attacco è loggato prima del danno (la scena ascolta `monster_attacked`, emesso dal controller prima del danno).
- **A bassa confidenza, aperte fino al playtest (STEP 4):** (1) il dettaglio della ricarica di D6/Belial a fine E inizio turno del proprietario (regola reale ufficiale: recharge all'inizio del turno del proprietario; il doppio evento è una scelta implementativa da validare); (2) la penalità di morte esatta (1¢ + 1 loot a caso + 1 oggetto a scelta: la scelta è umana nella UI, il robot prende il primo).
- **Prossimo:** playtest umano dell'utente → aggiornare §4 a "SÌ (con limiti)"; poi fase 2 (set base ~100 carte, arte/UI reale).