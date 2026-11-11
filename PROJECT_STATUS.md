# PROJECT_STATUS.md — Four Souls Digital

> Fonte di verità sullo stato del progetto. Aggiornato alla fine di ogni
> metaprompt (istruzione permanente: sezione "Project status" in CLAUDE.md).
> Ultimo aggiornamento: **Milestone 3 — server WebSocket + PWA + tavolo**
> (2026-11-11): trasporto **RFC 6455 reale** (`TCPServer` +
> `WebSocketPeer.accept_stream`, frame testo = JSON del protocollo M2) con
> posti, `reconnect_token` persistito e riconnessione che rimanda snapshot +
> richiesta pendente; **host statico integrato** sulla porta HTTP adiacente
> (8788) che serve la PWA, quindi zero runtime esterni in LAN; modalità
> **Tavolo Host** (`game_scene.tscn -- --host`) che rende SOLO
> `snapshot_for(-1)` (nessuna mano a schermo) con URL LAN, stato posti, tavolo,
> pila e log; client **PWA** mobile-first in `web_client/` (lobby, mano,
> priorità, bersagli, morte) che non calcola nessuna regola; gate di rete
> headless con due client veri. Rete **18/18**, suite **29/29**, canary UI
> **7/7**.
>
> Precedente: **Milestone 2 — protocollo e client passivo**
> (2026-11-11): **pila corretta** (un giro di pass risolve UNA sola entry,
> `resolve_one()`, con nuova finestra se resta qualcosa sotto; la Loot in
> risposta va sulla pila invece di essere atomica); protocollo di dati puri
> (`match_protocol.gd`: 8 comandi, 5 messaggi, validatore, roundtrip JSON);
> `MatchSession` = server in-process (comandi → regole, snapshot con
> `ui_actions()` calcolate dal server, `TARGET_REQUEST` invece di bersagli
> indovinati, eventi di dominio filtrati); `CommandDriver` = trasporto a
> comandi; `game_scene.gd` riscritta come client **passivo** (zero regole,
> zero mutazioni: solo snapshot + comandi), con la morte a due passi pilotata
> dal server. Suite: **29/29 PASS** (AE pila a entry singola, AF purezza del
> protocollo). Canary UI: **7/7 PASS** con il flusso di morte completo e zero
> warning di targeting.
>
> Precedente: **Milestone 1 — fondamenta** (2026-11-10): stato unico
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
| **MatchDriver (M1)** | `scripts/core/drivers/match_driver.gd`, `local_ui_driver.gd` | fatto | contratto di input del motore: richiesta con `request_id`, `player_id`, entry e `legal_actions`; risposta valida solo con identità corrispondente; `LocalUiDriver` = adapter a segnali (riferimento minimo), non più usato dalla scena |
| **MatchProtocol (M2)** | `scripts/core/match_protocol.gd` | fatto | vocabolario puro client↔server: 8 comandi (`PLAY_LOOT`, `ACTIVATE_ITEM`, `DECLARE_ATTACK`, `BUY_SHOP`, `PASS_PRIORITY`, `SELECT_TARGET`, `CHOOSE_DEATH_PENALTY`, `END_TURN`) + 5 messaggi (`STATE_SNAPSHOT`, `PRIORITY_REQUEST`, `TARGET_REQUEST`, `DEATH_PENALTY_REQUEST`, `DOMAIN_EVENT`); `validation_error()`/`is_pure()`/`to_wire()`/`from_wire()`; nessun Object/Resource sul confine (STEP AF) |
| **CommandDriver (M2)** | `scripts/core/drivers/command_driver.gd` | fatto | trasporto a comandi del `MatchDriver`: emette i messaggi del protocollo e accetta solo risposte con `request_id` E `player_id` della richiesta aperta; traduce il comando nella forma che il motore si aspetta. In M3 il socket si innesta qui |
| **MatchSession (M2)** | `scripts/core/match_session.gd` | fatto | server in-process: valida i comandi, li esegue sul `MatchController`, emette `STATE_SNAPSHOT` con la legalità calcolata dal server (`ui_actions`), chiede il bersaglio con `TARGET_REQUEST`, filtra gli eventi privati (carte pescate) e avvia il turno successivo dopo `END_TURN` o dopo una morte |
| **NetServer (M3)** | `scripts/net/net_server.gd` | fatto | server WebSocket RFC 6455 su `TCPServer` + `WebSocketPeer.accept_stream` (niente `WebSocketMultiplayerPeer`: il browser usa `new WebSocket()`), posti con `JOIN`/`reconnect_token` (persistito in `user://seats.json`), identità = posto (il `player_id` inviato dal client viene sovrascritto), snapshot per viewer, prompt pendente al reconnect, host HTTP statico per la PWA |
| **Tavolo Host (M3)** | `scripts/net/table_view.gd`, `game_scene.gd` con `-- --host` | fatto | modalità PC passiva: `snapshot_for(-1)` (nessuna mano), URL LAN grande, stato dei posti, mostri/negozio, pila con tiro pendente, conteggi mazzi, log eventi filtrato. L'hotseat resta il default senza `--host` |
| **PWA telefoni (M3)** | `web_client/index.html`, `app.js`, `style.css`, `manifest.webmanifest` | fatto | mobile-first, zero build: lobby/join+token, plancia e mano con legalità del server, modale priorità con azioni legali, selettore bersagli, morte a due passi. Connessione a `ws://<host>:<ws_port>` da `/config.json`, riconnessione con backoff |
| **Gate di rete (M3)** | `scenes/net_test.gd` + `.tscn`, `run_net_test.bat` | fatto | end-to-end headless: server vero su 127.0.0.1, HTTP/PWA, 2 client WebSocket, join, privacy mano, `TARGET_REQUEST`, finestra di priorità con azioni legali, anti-spoof, reconnect con token |
| **EventStack (MP07/M1/M2)** | `scripts/core/event_stack.gd` | fatto | coda LIFO tipizzata: `pending_roll` (r#), `pending_effect` (e#), `modifier` (m#); **`resolve_one()`** risolve UNA sola entry, quella in cima (Comprehensive Rules: un giro di pass = un oggetto). Se resta qualcosa il controller riapre la finestra prima di risolverla; guardia anti-loop nel controller |
| CardEffect (base scripted) | `scripts/core/card_effect.gd` | fatto | hook on_play/on_attacked/on_killed/on_event/get_roll_bonus/get_damage_bonus |
| CardEffectRegistry | `scripts/core/card_effect_registry.gd` | fatto | chiavi per instance_id; dispatcher policy (attivo primo, orario, ordine registrazione); switch simple_effect; unmount lifecycle |
| EventBus | `scripts/autoload/event_bus.gd` | fatto | + MP07 stack build: `active_player_advanced`, `stack_entry_pushed/resolved/cleared`, `shield_applied/consumed/expired`, `combat_state_reset`; priority_pending ora trasporta il TIPO di entry (`pending_roll`/`pending_effect`) |
| GameState | `scripts/autoload/game_state.gd` | fatto (M1: facciata) | NON possiede più stato: `players`/`current_player_index`/`phase`/`soul_values`/`shields` sono viste su `GameState.state` (MatchState); restano i mutatori che emettono gli eventi (+ `advance_active_player`, scudi, win a 4 soul value) |
| Rng | `scripts/autoload/rng.gd` | fatto | seam `rng` tipizzata Object: i test injectano stub duck-typed (FakeRng) per dadi scriptati |
| Log | `scripts/autoload/log.gd` | fatto | warn/error sempre stampati |
| Turn loop (self-play) | `scenes/turn_loop_test.gd` | fatto | il test È il driver (`ScriptedDriver` iniettato): le politiche si scambiano su `_driver.policy`, non su segnali globali; riproduce i 6 ESEMPI (U-Z) + i check M1/M2 (AA-AF) |
| MatchController | `scripts/core/match_controller.gd` | fatto (M1) | regole + stato transitorio (pila, lock) su `MatchState`; fasi start/action/combat/end; **input solo dal driver** (`_build_priority_request` → `_ask_priority` → validazione `request_id`+`player_id`); azioni legali calcolate dal motore (`_legal_actions`, usate anche dall'auto-pass) + `ui_actions()` per la UI (limiti, costi, tap: calcolati dal server); **risoluzione ricorsiva a entry singola** (`_resolve_stack`: finestra sulla cima → risolvi UNA entry → se resta qualcosa nuova finestra); Loot addebitata nel motore (1 gratuita in action, poi tap personaggio); morte con scelta del Loot; `setup()` chiama `teardown()` (idempotente) |
| Effetti scriptati | `scripts/cards/effects/*.gd` | fatto (3) | the_bible, soul_of_hope, money_is_power (bomb spostata su data path: una riga di dati) |
| Effetti data-driven | CSV `simple_effect` | fatto (8) | dinner/pennies/full_health/swallowed_penny/**bomb** + passivi sack/change_purse/crows_heart |
| Personaggi + oggetti eterni | CSV | fatto (3+3) | Isaac/D6, Judas/Belial Book (±1 immediato all'attivazione), Magdalene/Yum Heart (`prevent_damage`: scudo, non heal) |
| **UI (client passivo, M2)** | `scenes/game_scene.gd` + `.tscn`, `scripts/tools/ui_drive_test.gd` | fatto | **nessuna regola nella scena**: rende `STATE_SNAPSHOT` + il blocco `legal` del server, invia comandi, disegna `PRIORITY_REQUEST` (overlay con le azioni legali), `TARGET_REQUEST` (click sul mostro) e `DEATH_PENALTY_REQUEST` (due passi: Loot, poi oggetto). Canary headless: 7/7 PASS, morte completa inclusa |
| Test GUT | — | non iniziato (deliberato) | il self-check headless fa da guardia (29/29, exit code = esito). GUT richiede un addon da scaricare: **rinviato**, la suite headless resta il cancello finché non viene vendorizzato |
| Networking / Curse | — | non iniziati | fasi successive |

## 2. Catalogo carte

- **Totale: 34** (set base reale ~100 → ~34%)
- Per tipo: MONSTER 15 · LOOT 6 · TREASURE 7 · CHARACTER 3 · ITEM_ACTIVE (eterni) 3
- Comportamento: scripted **3** (the_bible, soul_of_hope, money_is_power) · data-driven **8** (incl. bomb=damage_monster 2) · modifier dati roll/damage bonus (steven, blood_clot, …) · carattere/eterno **6** · vanilla 14
- Sorgente di verità: `data/cards_base_set_template.csv`

## 3. Fedeltà al regolamento (differenze MP07)

| Aspetto | Stato | Nota |
|---|---|---|
| Stack/priorità reale | implementato (MP07, **corretto in M2**) | qualunque pending_* in cima apre finestra a TUTTI in ordine di turno dall'attivo; **pass consecutivi → si risolve UNA entry** (la cima), poi nuova finestra se la pila non è vuota; risposta riavvia il round dall'attivo |
| Modifier su tiri (D6/Belial) | implementato (MP07) | GENERICI sul pending_roll in cima: niente modifiche preventive (fuori finestra → "no_pending_roll"); Belial ±1 applicato ALL'ATTIVAZIONE, reroll D6 differito ALLA RISOLUZIONE ("r# value changes from X to Y") |
| Chiusura combattimento | implementato (MP07) | kill: ricompensa DA DATI CARTA (+soul boss + check vittoria automatico), discard carta mostro, refill slot, `reset_combat_state()` (stack verificato vuoto); percorso morte: STESSO reset, mai busy |
| Yum Heart | implementato (MP07) | PREVENZIONE: apply_shield → consume (0 hp persi) o expire a fine turno del PROPRIETARIO (+ recharge); bersagli anche i mostri (scudo per istanza) |
| Loot sullo stack | implementato (M2) | giocare loot = pending_effect + finestra a tutti → "X resolves"; **loot in risposta = pending_effect sulla pila** (tap addebitato subito, carta fuori dalla mano), risolta col giro di pass successivo: si può rispondere con la carta appena pescata. La semplificazione atomica di M1 è rimossa |
| Loot: costo del tap (M1, ratifica #5) | implementato | 1 giocata gratuita nella propria `action`; seconda o fuori turno → `character_tapped = true`, ricarica nella `start` del turno successivo; la carta esce dalla mano nel motore |
| Morte (M1, ratifica #5) | implementato | 1¢, tap di personaggio e oggetti, **scelta** del Loot da scartare (automatico solo con 1 carta), scelta oggetto, poi ending phase + advance |
| Slot (M1, ratifica #4) | implementato | 2 slot mostro base e 2 negozio; `table_monsters` è una lista dinamica |
| Roll d'attacco / danno / morte / win 4 soul / shop 10¢ / 2 slot / limiti azioni / heal pieno fine turno / morte-penalità | implementato | vedi metaprompt precedenti (MP05-06) |
| Ordine effetti simultanei | policy deterministica | attivo → orario → registrazione; nessuna scelta umana |
| Cap HP 6, curse | assenti | — |

## 4. È giocabile da un umano oggi?

**SÌ (con limiti) — in attesa del playtest di conferma dell'utente
(`run_game.bat`).** Da M2 la scena è un **client passivo** sul protocollo:
legge solo `STATE_SNAPSHOT` (mano propria + tavolo pubblico), non calcola
limiti né costi (arrivano dal server nel blocco `legal`) e invia comandi. La
canary headless della scena reale (`scenes/ui_drive_test.tscn`) copre turno P1
(acquisto, carta con bersaglio chiesto dal server, attacco), passaggio del
dispositivo, turno P2 fino alla **morte completa** (scelta del Loot, scelta
dell'oggetto) e ripresa del turno successivo: **7/7 PASS**, nessun blocco e
nessun warning di targeting. Limiti noti: nessuna arte; tavolo e telefoni
condividono ancora un solo processo (socket in M3).

## 5. Self-check automatici (in `scenes/turn_loop_test.gd`)

| Check | Verifica | Stato |
|---|---|---|
| STEP A/C/F/G/H/I/J/K/L/N | regressioni MP03-MP07 (copie duplicate, lifecycle, bonus aggregati, penalità morte, eterni sul pending, limiti, heal-at-max, alternanza, 3¢, shop) | PASS |
| M | "stop" su pending_roll ignorato: l'attack finisce solo per kill/morte | PASS |
| O | timing modifier: rifiutato fuori finestra, accettato nella finestra del pending_roll, rifiutato dopo | PASS |
| P | finestra chiede PRIMA l'attivo; il non-attivo risponde loot (ora **sulla pila**) + eterno | PASS |
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
| **AE (Comprehensive Rules)** | pila con `pending_roll` sotto e una Loot in risposta sopra: la traccia è `close → resolve` per OGNI entry (la prima risoluzione lascia 1 entry sulla pila), la finestra si riapre sul tiro e solo dopo il tiro si risolve (2 vs die 3 = MISS) | PASS |
| **AF (M2)** | 8 comandi e 5 messaggi sono dati puri, sopravvivono al roundtrip JSON, il validatore rifiuta tipo sconosciuto / player negativo / payload impuro; lo stato GREZZO (risorse sul tavolo) non è spedibile | PASS |

Totale: **29/29 PASS**. Exit code 1 se anche uno fallisce; riepilogo finale = termometro.
Canary separata della UI (`scenes/ui_drive_test.tscn`, client passivo): 7/7 PASS — turno P1, passaggio dispositivo, turno P2 fino alla morte completa (scelta Loot + oggetto) e ripresa del turno.

### Gate di rete M3 (`scenes/net_test.tscn`, `run_net_test.bat`) — **18/18 PASS**

| Verifica | Nota |
|---|---|
| server WebSocket + HTTP su 127.0.0.1 | porte effimere, nessuna dipendenza esterna |
| HTTP serve la PWA e `/config.json` | shell HTML + porta WS annunciata |
| due client `WebSocketPeer` fanno JOIN | P1→posto 0, P2→posto 1, token ≥ 16 byte |
| il join manda subito lo snapshot | nessuna schermata vuota |
| privacy sulla rete | P1 riceve solo `hand_count` di P2; P2 vede la propria mano |
| `PLAY_LOOT` senza bersaglio | il server risponde `TARGET_REQUEST` con i mostri |
| `SELECT_TARGET` completa il comando | il Bomb entra in pila e risolve |
| finestra di priorità via socket | arriva a P2 con le `legal_actions` del server; P1 (senza risposte) non viene interrogato |
| `PASS_PRIORITY` chiude la finestra | il Bomb risolve (hp 5 → 3) e la carta esce dalla mano |
| `player_id` falsificato | sovrascritto dal posto → `ERROR not_your_turn` |
| riconnessione col token | stesso `player_id` + snapshot immediato |

## 6. Decisioni architetturali

- **Chiuso in MP07 (stack build):** (a) modifier generici sul tipo `pending_roll`, non casi speciali; (b) Belial applicato subito, D6 alla risoluzione (fedele alle due sequenze esempio); (c) loot in risposta = atomico senza nested window (**superato in M2**: ora è un `pending_effect` sulla pila, risolto con il giro di pass successivo); (d) `reset_combat_state` unico punto di riabilitazione ATTACK, chiamato anche nel path morte; (e) **auto-pass** per i giocatori senza risposte disponibili nella finestra (fedele al testo "finestra visibile a tutti i giocatori con item/loot disponibili").
- **Strumenti:** `scenes/ui_drive_test.tscn` — driver headless che pilota la scena hotseat reale tramite i suoi handler (canary anti-regressione del flusso P1↔P2).
- **Chiuso in M1 (ratifiche #2/#3/#4/#5):** stato unico serializzabile + snapshot per vista; `GameState` = facciata; input solo dal driver con identità validata; pila risolta ricorsivamente (niente entry distrutte); `teardown()` idempotente + `CardEffectRegistry.reset()`; 2 slot mostro, Loot con costo del tap, morte con scelta del Loot. Normativa in `docs/RULES_NORMATIVE.md`.
- **Corretto in M2 (Comprehensive Rules):** un giro di pass risolve **una sola** entry (top), non un blocco; se resta qualcosa si riapre la finestra prima di risolverla. La Loot in risposta è un `pending_effect` sulla pila, non più atomica: era l'unica cosa che impediva il caso "pesco in risposta e gioco la carta appena pescata".
- **Aggiunto in M2:** protocollo puro (`match_protocol.gd`), `MatchSession` come server in-process (validazione, `TARGET_REQUEST`, legalità calcolata dal server in `ui_actions()`, eventi privati filtrati, avvio del turno successivo dopo `END_TURN`/morte), `CommandDriver`, e `game_scene.gd` ridotta a client passivo. La canary copre anche la morte a due passi.
- **Aperte:** TriggerEngine per `effect_trigger` dei mostri (M4); cap HP 6; curse; ordine di scelta tra effetti simultanei; GUT (rinviato, la suite headless resta il cancello).
- **Aggiunto in M3:** server WebSocket RFC 6455 nativo (`scripts/net/net_server.gd`) con posti e token di riconnessione, host statico integrato per la PWA, modalità Tavolo Host (`-- --host`, solo `snapshot_for(-1)`), client PWA `web_client/` e gate di rete headless con due client veri. `MatchSession` non è cambiata nelle regole: sono solo nati `snapshot_message()` e `pending_prompt()`.
- **Prossimo (M4):** TriggerEngine per gli `effect_trigger` dei mostri, poi contenuto (altre carte) e rifiniture; eventuale TLS/WSS e limite dei tentativi per il token sono fuori dal perimetro LAN casalingo.
