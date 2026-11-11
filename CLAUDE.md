# Four Souls Digital — Project Context

## What this is
A solo, personal/non-commercial fan project: a flat-screen (non-VR) digital
adaptation of the board game "The Binding of Isaac: Four Souls" (Edmund
McMillen / Studio71), built in Godot 4. No existing non-VR digital version
exists — that's the gap this fills. This is NOT for public distribution or
monetization until/unless explicit permission is obtained from the rights
holder. Do not add store integration, analytics, monetization, or anything
implying public release.

## Engine & stack
- Godot 4 (currently 4.7.1 stable; project created with the 4.3 feature tag),
  GDScript (not C#).
- Rendering: gl_compatibility (keep it light, this is a card game not a 3D game).
- No third-party dependencies unless explicitly requested.

## Rules are normative
`docs/RULES_NORMATIVE.md` is BINDING: turn phases, loot/tap costs, stack and
priority semantics, death penalty, slots and the public/private data boundary
all live there. If the code disagrees with that file, the code is wrong. If a
new card needs behavior the file does not describe, update the file first.

## Architecture — read before writing any card logic
1. **CardResource** (`scripts/core/card_resource.gd`) holds pure DATA for a
   card: stats, cost, text, and a behavior declaration (see below). Never put
   game logic here.
2. **Card behavior — DATA first, SCRIPTS for the complex (decision, Step A of
   Metaprompt 02).** Two mutually exclusive paths, decided per card:
   - **Data path (default):** `simple_effect` + `simple_effect_value` on
     CardResource, interpreted by a small switch in CardEffectRegistry
     (current patterns: `gain_cents`, `gain_hp`, `damage_monster`). Trivial
     cards are one CSV row, no file. Data-driven passives use `trigger_events`
     the same way scripted ones do.
   - **Script path (escape hatch):** `effect_script_path` pointing at a
     CardEffect subclass in `scripts/cards/effects/`, for cards that need
     conditions, sequencing or choices.
   - Rule of thumb: *"if it fits in one line of data, it's data; if it needs
     an if/then or a choice, it's a script."* Never set both paths on one card.
3. **CardEffect** (`scripts/core/card_effect.gd`) is the base class for
   SCRIPTED behavior only. Effects talk to the rest of the game ONLY through
   EventBus signals and GameState — never by reaching into another card's
   effect script directly.
4. **EventBus** (`scripts/autoload/event_bus.gd`) is the single source of
   truth for game events (signals). Cards subscribe, they don't call each
   other. If you need a new kind of event, add a signal here first.
5. **MatchState** (`scripts/core/match_state.gd`) is the single source of
   truth for match data: players, turn pointer, phase, table, shop, decks,
   shields, souls, counters. It is PURE data plus serialization — it never
   touches EventBus or the UI — and it can be snapshotted
   (`to_dict()`) or reduced to a per-viewer DTO (`snapshot_for(player_id)`,
   which never exposes another player's hand).
5b. **GameState** (`scripts/autoload/game_state.gd`) is a FACADE over
   MatchState: `GameState.players` / `current_player_index` / `soul_values` /
   `shields` are views on `GameState.state`. It owns the mutation helpers that
   also emit the matching EventBus signal. Never add match data anywhere else.
5c. **MatchController** (`scripts/core/match_controller.gd`) owns the rules and
   the transient resolution state (the stack, `_combat_in_progress`,
   `_effect_window_open`). It asks for input ONLY through an injected
   `MatchDriver` (`scripts/core/drivers/`), with request ids and legal-action
   lists; it never awaits a global signal for input. `setup()` starts with an
   idempotent `teardown()`, so a restart cannot inherit effects or stack
   entries. Do NOT put sockets, RPCs or JSON in the controller: that is M3's
   SocketDriver, and the engine must stay transport-agnostic.
6. **CardEffectRegistry** (`scripts/core/card_effect_registry.gd`) is the
   autoload that wires cards to behavior: instantiates scripted effects,
   subscribes `trigger_events`, applies data-driven `simple_effect`, and
   dispatches on_play / on_attacked / on_killed for the turn loop. Every card
   entering play (bought treasure, drawn monster) gets a unique `instance_id`
   from the turn loop — `_by_card`/`_owned` are keyed by instance, so
   duplicate copies of the same card never collide. `get_roll_bonus(player_id)`
   sums attack-roll modifiers (data `roll_bonus` + scripted
   `CardEffect.get_roll_bonus()`) — the turn loop queries it before hit/miss.
   Effects are **unmounted** (signals disconnected, instances dropped) when
   their card leaves the game, so `_effects` never grows without bound.
7. **Rng** (`scripts/autoload/rng.gd`) is the single source of randomness.
   Game code never calls `randi_range()`/`randomize()` directly — it uses
   `Rng.roll_die()` and `Rng.shuffle()` (driven by the injectable
   `Rng.rng`), and determinism comes from `Rng.seed_rng(seed)`.

## Known decisions (documented so they don't become silent inconsistencies)
- **Monsters on the table live in the turn loop / game scene, NOT in
  GameState** (decision, Step B of Metaprompt 02). Until Phase 2, the loop
  owns monster instances (hp, instance ids); GameState owns only players,
  turn and phase. Consequence: a card effect cannot read a monster's HP via
  GameState yet — Phase 2 will revisit whether monsters move into GameState.
- **Logging:** game code reports problems via the Log autoload
  (`Log.warn`/`Log.error`), which always prints — `push_warning`/`push_error`
  are silent in headless runs. Import tools in `scripts/tools/` may keep
  using push_error.
- **Owned cards carry instance ids too, exactly like monsters** (Metaprompt
  03, Step A). `register_card(card, player_id, instance_id)`; the loop
  assigns ids at buy time. The registry keeps no card_id-keyed state, so N
  copies of the same card behave as N independent instances.
- **CardEffects are unmounted when their card leaves the game** (Metaprompt
  03, Step C): signal connections are disconnected and instances dropped.
  Single-use loot played from hand is instantiated on the fly and unmounted
  immediately after resolving.
- **The table has TWO base monster slots** (ratifica #4; the old "three" was a
  documentation error), refilled automatically when a slot frees up, plus two
  shop slots. The table is a LIST (`MatchState.table_monsters`), so a future
  card or event may add a slot without a refactor. Targeting is by
  `instance_id` everywhere.
- **Simultaneous effects resolve in a fixed deterministic policy** (Metaprompt
  05, decision c): the registry's dispatchers re-emit triggers in active-player
  first, then clockwise, then registration (= purchase) order within a player.
  No human choice of order until the UI makes it possible.

## Project status
- `PROJECT_STATUS.md` at the project root is the single source of truth for
  project state: what's implemented per component, card catalogue counts,
  rules-fidelity checklist, human-playability verdict, self-checks, and open
  architectural decisions. Update it at the END of every metaprompt (before
  declaring done), keeping it synthetic and verifiable — not narrative.
  When the user asks about project state, answer from PROJECT_STATUS.md,
  not from memory or transcripts.

## Card import pipeline
Cards are catalogued in `data/cards_base_set_template.csv` first (cheap to
edit, easy to review), then imported into `.tres` CardResource files under
`resources/cards/base_set/` via an import script. Do not hand-write .tres
files for more than a couple of cards — always go through the CSV → import
step so the catalogue stays the single source of truth. The importer
validates the whole CSV before writing: it fails loudly (printing every
problem) on missing effect scripts, duplicate card ids, and non-integer
numeric fields. The turn-loop test (`scenes/turn_loop_test.tscn`) includes
self-checks for the duplicate-copy and effect-lifecycle guarantees, and
exits non-zero if they fail.

## Development phases (do not skip ahead)
- **Phase 1 (current): prove the architecture.** Local hotseat only, a
  small subset of the base set (~15-25 simple cards: mix of monster/loot/
  treasure with a couple of triggered effects), full turn loop (buy →
  attack → loot), no UI polish. Goal: confirm the EventBus/CardEffect
  pattern scales before investing in the remaining ~250+ cards.
- Phase 2: full base set (~100 cards), local hotseat, basic UI.
- Phase 3: online multiplayer — authoritative Godot server on the PC +
  lightweight PWA (HTML/TS) clients on phones over raw WebSocket (ratifica
  #1). NOT Godot Web export on phones and NOT ENet: the phone client must not
  contain the engine. **Status (M3): implemented** — `scripts/net/net_server.gd`
  (RFC 6455 via `TCPServer` + `WebSocketPeer.accept_stream`, seats and
  reconnect tokens, static HTTP host for `web_client/`), table mode with
  `game_scene.tscn -- --host` (renders `snapshot_for(-1)` only), gate in
  `scenes/net_test.gd`. Hotseat stays the default without `--host`.
- Phase 4: Requiem + later expansions, UI polish.
Each phase should be fully working and merged before the next starts.
Do not build multiplayer or expansion content while Phase 1 is unproven.

## Conventions
- snake_case for files and signals, PascalCase for classes.
- Every CardEffect subclass gets a short comment block: what the card does
  in plain English, quoting the card's rules text.
- Prefer small, single-purpose scripts over large ones — a 340+ card game
  will not scale if effects pile up in shared files.
- Write GUT (Godot Unit Test) tests for anything touching combat math or
  soul/win-condition logic — this is the part most likely to have subtle
  bugs and hardest to eyeball-verify. GUT itself is not vendored yet: until it
  is, the headless self-check suite in `scenes/turn_loop_test.gd` (run_test.bat,
  exit code = test result) is the gate and must stay green.

## What NOT to do without being asked
- Don't put transports inside the rules: sockets/HTTP live in `scripts/net/`
  and speak `scripts/core/match_protocol.gd`; the engine only knows
  `MatchDriver`.
- Don't scaffold monetization/store/analytics.
- Don't import the full card catalogue in one go — small batches, validated
  as you go.
- Don't reproduce card artwork or verbatim rules text beyond what's needed
  for functional UI labels.
