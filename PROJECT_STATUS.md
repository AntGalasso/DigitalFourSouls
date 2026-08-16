# PROJECT_STATUS.md — Four Souls Digital

> Fonte di verità sullo stato del progetto. Aggiornato alla fine di ogni
> metaprompt (istruzione permanente: sezione "Project status" in CLAUDE.md).
> Ultimo aggiornamento: **Metaprompt 05** (2026-08-16) — STEP 3-5: scena
> giocabile da umano (hotseat) costruita su `MatchController` condiviso;
> §4 in attesa del playtest (STEP 6).

## 1. Cosa è implementato (per componente)

| Componente | File | Stato | Note |
|---|---|---|---|
| Import pipeline CSV → .tres | `scripts/tools/card_importer.gd`, `import_cards.gd`, `run_import_cli.gd` | fatto | 26 carte; validazione che fallisce in modo rumoroso (script mancanti, id duplicati, campi numerici non parsabili); idempotente; entry CLI con `<csv_path> <output_dir>` opzionali |
| CardResource (dati puri) | `scripts/core/card_resource.gd` | fatto | stats, text, `simple_effect`/`simple_effect_value`, `trigger_events`, `roll_bonus` |
| CardEffect (base scripted) | `scripts/core/card_effect.gd` | fatto | hook `on_play`/`on_attacked`/`on_killed`/`on_event`/`get_roll_bonus` |
| CardEffectRegistry | `scripts/core/card_effect_registry.gd` | fatto | chiavi per `instance_id` (copie duplicate coesistono); wiring trigger `turn_started`/`card_played`/`monster_killed` (scripted + data) via **dispatcher con policy** (giocatore attivo per primo, poi senso orario, stesso giocatore in ordine di registrazione); unmount lifecycle (nessuna crescita di `_effects`); switch `simple_effect` (`gain_cents`, `gain_hp`, `damage_monster`); `get_roll_bonus()` aggregato data+scripted |
| EventBus | `scripts/autoload/event_bus.gd` | fatto | segnali turno / economia / combattimento / carte / soul-win |
| GameState | `scripts/autoload/game_state.gd` | fatto | `players: Array[Dictionary]`; helper `gain_cents`/`gain_soul`/`damage_player`/`heal`; win a 4 soul |
| Rng | `scripts/autoload/rng.gd` | fatto | `roll_die`/`shuffle`/`seed_rng`; `RandomNumberGenerator` iniettabile |
| Log | `scripts/autoload/log.gd` | fatto | `warn`/`error` sempre in console (headless-safe) |
| Turn loop (self-play) | `scenes/turn_loop_test.gd` | fatto | 2 giocatori, 3 round, buy→attack→loot automatici, **3 slot mostro** con riempimento automatico, seed deterministico (default 8), riepilogo PROJECT_STATUS in coda; **guida il `MatchController`** (le regole vivono lì, il test decide solo le mosse del robot) |
| MatchController (regole condivise) | `scripts/core/match_controller.gd` | fatto | `setup`/`begin_turn`/`end_turn`/`buy`/`attack`/`play_loot`/`draw_loot`/`card_resource`/`is_bought`; possiede 3 slot mostro + shop; driver unico per robot test E UI umana (nessuna duplicazione di regole) |
| Effetti scriptati | `scripts/cards/effects/*.gd` | fatto (4) | bomb, the_bible, soul_of_hope, money_is_power |
| Effetti data-driven | CSV `simple_effect` | fatto (7) | dinner/pennies/full_health/swallowed_penny + passivi sack_of_pennies/change_purse/crows_heart |
| Modificatore dati statico | CSV `roll_bonus` | fatto (1) | steven (+1) |
| UI (scena giocabile hotseat) | `scenes/game_scene.gd` + `.tscn` | fatto (MP05) | nessuna arte: Label/Button; attacco = click sullo slot mostro, target carte = click sul mostro, shop con TUTTE le carte insieme, overlay pass-device, log testuale, restart su morte/win |
| Test GUT | — | non iniziato | i self-check del turn loop fanno da guardia per ora |
| Networking | — | non iniziato | fase 3 |
| Personaggi | — | non iniziato | `character_id` nel template, nessuna carta character |
| Curse | — | non iniziato | nessuna carta curse |

## 2. Catalogo carte

- **Totale: 26** (set base reale ~100, totale con espansioni ~340+ → ~8%)
- Per tipo: MONSTER 14 · LOOT 6 · TREASURE 6 · CHARACTER 0 · SOUL 0 · CURSE 0
- Per comportamento:
  - scripted (`effect_script_path`): **4** — bomb, the_bible, soul_of_hope, money_is_power
  - data-driven (`simple_effect`): **7** — dinner, pennies, full_health, swallowed_penny, sack_of_pennies, change_purse, crows_heart
  - data modifier (`roll_bonus`): **1** — steven
  - vanilla (senza comportamento): **14** — tutti i mostri
- Sorgente di verità: `data/cards_base_set_template.csv` (i `.tres` sono generati, non da modificare a mano)

## 3. Fedeltà al regolamento reale di Four Souls

| Aspetto | Stato | Nota |
|---|---|---|
| Roll d'attacco 1d6 + modificatori vs die value | implementato fedelmente | bonus data + scripted aggregati da registry |
| Danno mostro / morte (hp, soul_reward, reward cents) | implementato fedelmente | per istanza, via eventi |
| Win condition (4 soul) | implementato fedelmente | il test si ferma prima (3 round) |
| Fasi del turno (main/buy/end) | semplificato | ordine fisso buy→attack→loot; nel regolamento l'ordine in main phase è libero |
| Area mostri multipla (3 slot) | **implementato** (MP05) | 3 slot con riempimento automatico alla morte; target per `instance_id`; semplificato: il self-play sceglie lo slot 0, la scelta umana arriva con la UI |
| Scelte del giocatore (target, acquisti, carte da giocare) | **implementato** (MP05) | UI: click sullo slot mostro per attaccare, click sul mostro per il target di Bomb/Bible/oggetti, shop con tutte le carte visibili, carte in mano giocabili, End Turn esplicito (hotseat) |
| Personaggi | assente | hp/cents fissi, nessuna carta character |
| Interazione fra giocatori (attaccarsi, furto, pagamenti) | assente | il danno mostro va all'attaccante invece che a "random player" |
| Curse | assente | — |
| Ordine/priorità effetti simultanei | **implementato** (MP05) | policy deterministica: giocatore attivo per primo, poi senso orario, stesso giocatore in ordine di registrazione/acquisto; semplificato: nessuna scelta umana dell'ordine |
| Hand / discard loot | parziale | hand esiste in GameState; il loop gioca subito la loot pescata; discard solo per reshuffle |
| Morte giocatore | semplificato | hp=0 → match over; regola reale: scarti, respawn, penalità |
| Recharge (tap/untap oggetti) | assente | — |
| Cap HP (6) | assente | heal non cappato |

## 4. È giocabile da un umano oggi?

**NO — in attesa del playtest (STEP 6 di MP05).** La UI hotseat è implementata
(`scenes/game_scene.tscn`, lanciabile con `run_game.bat` o F5): il verdetto
diventa "SÌ (con limiti)" dopo la conferma dell'utente che ha provato una
partita vera (attacco per slot, target carte, acquisti dallo shop intero,
passaggio di turno).

Limiti noti della versione attuale:
1. Nessuna arte: carte come Label/Button testuali.
2. Solo 2 giocatori, nessuna scelta dell'ordine effetti simultanei (policy fissa).
3. La loot pescata non si tiene in mano tra turni (hand = solo turno attivo) e il
   gioco della loot è limitato (vanilla si tiene, comportamento si gioca).
4. Morte = match over (niente respawn/scarti/penalità), HP non cappato a 6,
   niente recharge, personaggi non implementati.

## 5. Self-check automatici presenti (in `scenes/turn_loop_test.gd`)

| Check | Verifica | Stato |
|---|---|---|
| STEP A (MP03) | coesistenza copie duplicate: 2 Sack of Pennies registrati → `turn_started` dà +6¢ (non +3) | PASS |
| STEP C (MP03) | lifecycle effetti: 5 Bomb giocate → `_effects` invariato (nessun accumulo) | PASS |
| STEP F (MP02) | aggregazione roll bonus: Steven(+1) + Money=Power a 10¢(+2) = 3 | PASS |

I tre check falliscono con exit code 1 (il test è fail-fast). Il riepilogo finale
conta pass/falliti (termometro, §3 del Metaprompt 04). I check girano sul turn
loop a **3 slot mostro** (post-MP05).

## 6. Decisioni architetturali aperte

- **Chiuso in MP05:** (b) mostri multipli → 3 slot implementati; (c) priorità effetti → policy deterministica documentata e implementata (entrambe semplificate rispetto alla scelta umana, che arriva con la UI).
- **Fatto in MP05 (STEP 3-5):** `MatchController` come unico proprietario delle regole (usato sia dal self-play test sia dalla scena umana); UI hotseat minimale (attacco/target per click, shop intero, overlay pass-device); `run_game.bat` + main_scene puntata su `game_scene.tscn`.
- **Prossimo:** playtest umano dell'utente → aggiornare §4 a "SÌ (con limiti)" (STEP 6); poi fase 2 (set base ~100 carte, arte/UI reale).
