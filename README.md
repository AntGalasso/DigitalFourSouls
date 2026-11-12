# Four Souls Digital

Adattamento digitale **flat-screen (non VR)** del gioco da tavolo
*The Binding of Isaac: Four Souls* (Edmund McMillen / Studio71), in Godot 4.

> **Progetto personale non commerciale.** Non è prevista distribuzione
> pubblica o monetizzazione finché non si ottiene il permesso esplicito dal
> detentore dei diritti. Nessuna arte delle carte è riprodotta: le carte sono
> Label/Button testuali con testo funzionale minimo.

## Stato del progetto

Vedi `PROJECT_STATUS.md` (fonte di verità): fase 1 (provare l'architettura) in
corso — hotseat locale, 34 carte, turn loop completo, **29 self-check**
automatici che passano. Regole normate in `docs/RULES_NORMATIVE.md`; la UI è
un client passivo sul protocollo comandi/snapshot. **M3**: il PC può fare da
server WebSocket + host PWA e i telefoni giocano dal browser (`run_table.bat`);
non ancora espansioni (fase 4). **M4**: tavolo visivo, priorità a riflessi
(2,0 s, con pausa durante il targeting), trigger data-driven in ordine APNAP,
fizzling, 2–4 giocatori, swipe e rotazione oggetti sul telefono.

In modalità tavolo il PC è pubblico e mostra solo `snapshot_for(-1)`: carte
mostro con barra vita, negozio, Pila ("chi gioca cosa su chi"), plance con
personaggio e oggetti ruotati di 90° quando tappati, e la barra del countdown.

## Requisiti

- Godot 4.7.1 (progetto creato con feature tag 4.3)
- Renderer: `gl_compatibility` (card game, non 3D)
- Nessuna dipendenza di terze parti

## Come si avvia

| Comando | Cosa fa |
|---|---|
| `run_import.bat` | Reimporta `data/cards_base_set_template.csv` → `resources/cards/base_set/*.tres` (valida prima di scrivere, fallisce con tutti gli errori stampati) |
| `run_test.bat` | Turn loop headless (self-play, seed 8): 3 round + 29 self-check (A–AF); exit 0 solo se tutti passano |
| `run_game.bat` | Partita hotseat 2 giocatori con la UI (main scene) |
| `run_table.bat` | Modalità **Tavolo Host**: server WebSocket (8787) + HTTP/PWA (8788); apri sul telefono l'URL LAN mostrato a schermo |
| `run_net_test.bat` | Gate di rete headless: server vero + 2 client WebSocket (join, privacy, bersaglio, priorità, anti-spoof, reconnect) |
| `run_priority_test.bat` | Gate M4 headless: countdown 2 s con auto-risoluzione, pausa su bersaglio, trigger APNAP, fizzling, 3–4 giocatori |

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
5. **MatchState** (`scripts/core/match_state.gd`) — unico stato della partita,
   serializzabile (`to_dict()`) e filtrabile per vista
   (`snapshot_for(player_id)`: la mano altrui non esce mai dal server).
   **GameState** (`scripts/autoload/game_state.gd`) è solo una facciata su
   `GameState.state`.
6. **MatchDriver** (`scripts/core/drivers/`) — l'unico modo in cui il motore
   chiede input: richiesta con `request_id` + `player_id` + azioni legali.
   `CommandDriver` è il trasporto a comandi; la UI parla il **protocollo
   puro** (`match_protocol.gd`: 8 comandi, 5 messaggi) tramite `MatchSession`,
   il server in-process che valida i comandi, calcola la legalità e filtra gli
   snapshot. In M3 un socket sostituisce il trasporto, non le regole.
7. **CardEffectRegistry** (`scripts/core/card_effect_registry.gd`) — collega
   carte e comportamento: istanzia gli effetti scripted, sottoscrive i
   `trigger_events`, applica i `simple_effect`, dispaccia on_play/on_attacked/
   on_killed. Ogni carta in gioco ha un `instance_id` unico (le copie
   duplicate non collidono). Gli effetti vengono **smontati** quando la carta
   esce dal gioco (nessuna crescita di `_effects`).
8. **MatchController** (`scripts/core/match_controller.gd`) — unico proprietario
   delle regole: setup/teardown, turno, buy/attack/play_loot/draw_loot, morte,
   personaggi/oggetti eterni, pila e priorità. Usato sia dal test self-play sia
   dalla UI umana (nessuna duplicazione di regole).
9. **Rng** (`scripts/autoload/rng.gd`) — unica fonte di casualità:
   `Rng.roll_die()` / `Rng.shuffle()`, deterministico con `Rng.seed_rng(seed)`.
   Mai `randi_range()` diretto nel codice di gioco.
10. **Rete (M3)** — `scripts/net/net_server.gd` (WebSocket RFC 6455 su
   `TCPServer` + `WebSocketPeer.accept_stream`, più host statico per la PWA) e
   `web_client/` (client dei telefoni). Il telefono parla solo il protocollo di
   `match_protocol.gd`; il **posto** decide il `player_id`, quindi un client
   non può agire per un altro. Il PC in modalità tavolo (`-- --host`) rende
   solo `snapshot_for(-1)`: nessuna mano a schermo.

## Regole implementate (fase 1)

- Turno: fasi start → action → combat → end. Ordine libero in `action` con
  limiti: **1 buy, 1 attack, 1 Loot gratuita**; ogni Loot successiva o fuori
  turno costa il **tap della Carta Personaggio** (si untappa nella start del
  turno successivo).
- Attacco: **sequenza di roll** 1d6 + modificatori vs die value dello slot
  scelto, con finestra di risposta tra un roll e l'altro (RESOLVE/STOP in UI;
  lì si possono usare oggetti eterni come D6/Belial).
- **2 slot mostro**, riempiti automaticamente alla morte; target per
  `instance_id`.
- Shop: tutti i tesori a **10¢**, ogni tesoro acquistabile una sola volta per
  giocatore.
- Fine turno: **heal pieno** per tutti i giocatori e i mostri in tavola;
  ricarica degli oggetti eterni del proprietario.
- **Morte**: penalità (perde 1¢, tappa personaggio e oggetti, **sceglie** 1
  Loot dalla mano da scartare — automatico solo con 1 carta — e 1 oggetto;
  l'eterno è protetto), poi si continua; il match non termina mai per morte.
- **Heal a HP pieni → +max HP permanente** (regola del regolamento reale).
- **Personaggi**: Isaac (D6 reroll), Judas (Belial Book ±1), Magdalene (Yum
  Heart) — 2 HP, 1 danno; gli oggetti eterni si usano nelle finestre di
  priorità e si ricaricano a inizio turno del proprietario.
- Win a 4 soul.

## Set carte (34)

15 mostri · 6 loot · 7 tesori (10¢) · 3 personaggi · 3 oggetti eterni
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
| STEP K–T | alternanza turni, morte-penalità, eterni, limiti, shop, timing, priorità, danno, campi carta, anime |
| STEP U–Z | i 6 ESEMPI (turno completo, D6, Belial, chiusura combattimento, Yum Heart, Loot sulla pila) |
| STEP AA–AD | identità della richiesta (request/player id), privacy degli snapshot, roundtrip di MatchState, teardown idempotente |
| STEP AE | pila: un giro di pass risolve **una sola** entry (traccia `close → resolve` per ogni entry, finestra riaperta prima del tiro) |
| STEP AF | protocollo: 8 comandi + 5 messaggi sono dati puri, roundtrip JSON, payload impuro rifiutato |
| GATE M3 | rete end-to-end (`scenes/net_test.gd`): 18/18 — HTTP/PWA, join con token, privacy della mano, `TARGET_REQUEST`, finestra di priorità, anti-spoof, riconnessione |

## Limiti noti della versione attuale

1. Nessuna arte (carte testuali).
2. Solo 2 giocatori; ordine effetti simultanei a policy fissa (nessuna scelta).
3. Il confine pubblico/privato è calcolato dal server (`snapshot_for`) ma la
   UI hotseat legge ancora lo stato locale: i telefoni arrivano in M3.
4. Gli `effect_trigger` dei mostri sono dichiarati e validati ma non ancora
   eseguiti dal motore (TriggerEngine, M4).
5. HP non cappato a 6; nessuna carta curse.