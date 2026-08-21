# Four Souls Digital

Adattamento digitale **flat-screen (non VR)** del gioco da tavolo
*The Binding of Isaac: Four Souls* (Edmund McMillen / Studio71), in Godot 4.

> **Progetto personale non commerciale.** Non è prevista distribuzione
> pubblica o monetizzazione finché non si ottiene il permesso esplicito dal
> detentore dei diritti. Nessuna arte delle carte è riprodotta: le carte sono
> Label/Button testuali con testo funzionale minimo.

## Stato del progetto

Vedi `PROJECT_STATUS.md` (fonte di verità): fase 1 (provare l'architettura) in
corso — hotseat locale, 32 carte, turn loop completo, 7 self-check automatici
che passano. Non ancora multiplayer (fase 3) né espansioni (fase 4).

## Requisiti

- Godot 4.7.1 (progetto creato con feature tag 4.3)
- Renderer: `gl_compatibility` (card game, non 3D)
- Nessuna dipendenza di terze parti

## Come si avvia

| Comando | Cosa fa |
|---|---|
| `run_import.bat` | Reimporta `data/cards_base_set_template.csv` → `resources/cards/base_set/*.tres` (valida prima di scrivere, fallisce con tutti gli errori stampati) |
| `run_test.bat` | Turn loop headless (self-play, seed 8): 3 round + 7 self-check (A, C, F, G, H, I, J); exit 0 solo se tutti passano |
| `run_game.bat` | Partita hotseat 2 giocatori con la UI (main scene) |

## Architettura (in breve)

1. **CardResource** (`scripts/core/card_resource.gd`) — dati puri della carta:
   stats, costo, testo, dichiarazione di comportamento. Nessuna logica.
2. **Due percorsi di comportamento, esclusivi** (mai entrambi su una carta):
   - *Data path* (default): `simple_effect` + `simple_effect_value` interpretati
     da `CardEffectRegistry` (`gain_cents`, `gain_hp`, `damage_monster`).
   - *Script path* (escape hatch): `effect_script_path` → sottoclasse di
     `CardEffect` in `scripts/cards/effects/` per condizioni/sequenze/scelte.
   - Regola pratica: *"se sta in una riga di dati è dati; se serve un if/then o
     una scelta, è uno script."*
3. **CardEffect** (`scripts/core/card_effect.gd`) — base per il comportamento
   scripted; parla col resto del gioco SOLO via segnali EventBus e GameState.
4. **EventBus** (`scripts/autoload/event_bus.gd`) — unica fonte di verità per
   gli eventi di gioco. Le carte si sottoscrivono, non si chiamano tra loro.
5. **GameState** (`scripts/autoload/game_state.gd`) — unica fonte di verità per
   lo stato della partita (giocatori, turno, fase). I mostri in tavola vivono
   nel turn loop / scena, NON qui (decisione documentata in CLAUDE.md).
6. **CardEffectRegistry** (`scripts/core/card_effect_registry.gd`) — collega
   carte e comportamento: istanzia gli effetti scripted, sottoscrive i
   `trigger_events`, applica i `simple_effect`, dispaccia on_play/on_attacked/
   on_killed. Ogni carta in gioco ha un `instance_id` unico (le copie
   duplicate non collidono). Gli effetti vengono **smontati** quando la carta
   esce dal gioco (nessuna crescita di `_effects`).
7. **MatchController** (`scripts/core/match_controller.gd`) — unico proprietario
   delle regole: setup, turno, buy/attack/play_loot/draw_loot, morte,
   personaggi/oggetti eterni. Usato sia dal test self-play sia dalla UI umana
   (nessuna duplicazione di regole).
8. **Rng** (`scripts/autoload/rng.gd`) — unica fonte di casualità:
   `Rng.roll_die()` / `Rng.shuffle()`, deterministico con `Rng.seed_rng(seed)`.
   Mai `randi_range()` diretto nel codice di gioco.

## Regole implementate (fase 1)

- Turno: ordine libero in main phase con limiti — **1 buy, 1 attack, 1 loot +
  1 via effetto personaggio** per turno (end turn esplicito in UI).
- Attacco: **sequenza di roll** 1d6 + modificatori vs die value dello slot
  scelto, con finestra di risposta tra un roll e l'altro (RESOLVE/STOP in UI;
  lì si possono usare oggetti eterni come D6/Belial).
- **2 slot mostro**, riempiti automaticamente alla morte; target per
  `instance_id`.
- Shop: tutti i tesori a **10¢**, ogni tesoro acquistabile una sola volta per
  giocatore.
- Fine turno: **heal pieno** per tutti i giocatori e i mostri in tavola;
  ricarica degli oggetti eterni del proprietario.
- **Morte**: penalità (1¢, 1 loot a caso, 1 oggetto a scelta — l'eterno è
  protetto), poi si continua; il match non termina mai per morte.
- **Heal a HP pieni → +max HP permanente** (regola del regolamento reale).
- **Personaggi**: Isaac (D6 reroll), Judas (Belial Book ±1), Magdalene (Yum
  Heart heal 1) — 2 HP, 1 danno; l'effetto personaggio è "gioca 1 loot extra",
  usabile anche nel turno altrui; ricarica a inizio turno del proprietario.
- Win a 4 soul.

## Set carte (32)

14 mostri · 6 loot · 6 tesori (10¢) · 3 personaggi · 3 oggetti eterni
— 4 scripted, 7 data-driven, 1 modificatore di roll statico, 6 carattere/
eterno, 14 vanilla. Sorgente di verità: `data/cards_base_set_template.csv`
(i `.tres` sono generati dall'importer, non da modificare a mano).

## Self-check (in `scenes/turn_loop_test.gd`)

| Check | Verifica |
|---|---|
| STEP A | coesistenza copie duplicate (2 Sack of Pennies → +6¢) |
| STEP C | lifecycle effetti (5 Bomb → nessun accumulo in `_effects`) |
| STEP F | aggregazione roll bonus (Steven + Money=Power = 3) |
| STEP G | morte: penalità + heal pieno a fine turno |
| STEP H | oggetti eterni (D6/Belial) in finestra d'attacco + ricarica |
| STEP I | limiti azioni + effetto personaggio (anche cross-turn) |
| STEP J | heal a HP pieni → +max HP |

## Limiti noti della versione attuale

1. Nessuna arte (carte testuali).
2. Solo 2 giocatori; ordine effetti simultanei a policy fissa (nessuna scelta).
3. La loot pescata non si tiene in mano tra turni (hand = solo turno attivo).
4. Le azioni difensive dell'avversario nel tuo turno (loot via effetto
   personaggio, oggetti eterni) esistono nel motore ma non sono raggiungibili
   dalla UI hotseat a schermo singolo.
5. HP non cappato a 6; nessuna carta curse.