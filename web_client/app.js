'use strict';

/**
 * Four Souls — phone client (M3).
 *
 * Pure presentation. It renders STATE_SNAPSHOT (including the server-computed
 * `legal` block) and turns taps into protocol COMMANDS. It never decides a
 * rule: not a cost, not a limit, not a target, not a death penalty. Everything
 * arrives already decided by the authoritative Godot server on the PC.
 */

const TOKEN_KEY = 'foursouls.token';
const SEAT_KEY = 'foursouls.seat';
const LOG_LIMIT = 40;

const state = {
  ws: null,
  wsPort: 8787,
  token: localStorage.getItem(TOKEN_KEY) || '',
  seat: localStorage.getItem(SEAT_KEY) !== null ? Number(localStorage.getItem(SEAT_KEY)) : -1,
  joined: false,
  playerId: 0,
  snapshot: null,
  legal: {},
  prompt: null,
  deathLoot: null,
  log: [],
  net: 'connessione…',
  retry: 0,
  // M4: the reaction countdown. The SERVER is the clock; this only animates
  // the bar between two snapshots.
  window: null,
  rotated: new Set(),
  swipedAt: 0,
};

const $ = (id) => document.getElementById(id);

function esc(value) {
  return String(value).replace(/[&<>"']/g, (c) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
  }[c]));
}

/** `loot_bomb` -> "Bomb": the phone has no card catalogue, only ids. */
function pretty(id) {
  if (!id) return '—';
  return String(id)
    .replace(/^(loot|treasure|monster|character|eternal|item)_/, '')
    .replace(/#\d+$/, '')
    .replace(/_/g, ' ')
    .replace(/\b\w/g, (m) => m.toUpperCase());
}

let toastTimer = 0;
function toast(text) {
  const node = $('toast');
  node.textContent = text;
  node.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { node.hidden = true; }, 2600);
}

// --- Transport ---------------------------------------------------------------

async function boot() {
  try {
    const cfg = await fetch('config.json', { cache: 'no-store' }).then((r) => r.json());
    state.wsPort = Number(cfg.ws_port) || 8787;
  } catch (err) {
    state.wsPort = 8787;
  }
  connect();
  render();
}

function connect() {
  const url = `ws://${location.hostname}:${state.wsPort}`;
  let ws;
  try {
    ws = new WebSocket(url);
  } catch (err) {
    state.net = 'websocket non disponibile';
    render();
    return;
  }
  state.ws = ws;
  state.net = 'connessione…';
  render();
  ws.addEventListener('open', () => {
    state.retry = 0;
    // A saved token or an already chosen seat means "reconnect / claim now".
    // A brand new phone sees the LOBBY and picks its seat with a tap.
    if (state.token !== '' || state.seat >= 0) {
      state.net = 'connesso';
      sendJoin();
    } else {
      state.net = 'connesso — scegli un posto';
    }
    render();
  });
  ws.addEventListener('close', () => {
    state.joined = false;
    state.prompt = null;
    state.net = 'disconnesso — riconnessione…';
    render();
    scheduleReconnect();
  });
  ws.addEventListener('error', () => { state.net = 'errore di rete'; render(); });
  ws.addEventListener('message', (event) => {
    let msg;
    try { msg = JSON.parse(event.data); } catch (err) { return; }
    handleMessage(msg);
  });
}

function scheduleReconnect() {
  const delay = Math.min(8000, 400 * Math.pow(1.6, state.retry++));
  setTimeout(() => {
    if (!state.ws || state.ws.readyState !== WebSocket.OPEN) connect();
  }, delay);
}

function sendRaw(obj) {
  if (!state.ws || state.ws.readyState !== WebSocket.OPEN) {
    toast('non connesso al tavolo');
    return false;
  }
  state.ws.send(JSON.stringify(obj));
  return true;
}

function sendJoin() {
  sendRaw({
    kind: 'command', schema_version: 1, type: 'JOIN',
    player_id: 0, request_id: '',
    payload: { seat: state.seat, token: state.token },
  });
}

function send(type, payload, requestId) {
  return sendRaw({
    kind: 'command', schema_version: 1, type,
    player_id: state.playerId || 0,
    request_id: requestId || '',
    payload: payload || {},
  });
}

// --- Incoming ----------------------------------------------------------------

function handleMessage(msg) {
  const payload = msg.payload || {};
  switch (msg.type) {
    case 'JOIN_OK':
      state.joined = true;
      state.playerId = Number(payload.player_id) || 0;
      state.seat = Number(payload.seat);
      state.token = String(payload.reconnect_token || '');
      localStorage.setItem(TOKEN_KEY, state.token);
      localStorage.setItem(SEAT_KEY, String(state.seat));
      state.net = `P${state.playerId + 1} · connesso`;
      break;
    case 'JOIN_REJECTED':
      state.joined = false;
      state.seat = -1;
      localStorage.removeItem(SEAT_KEY);
      state.net = 'posto non disponibile';
      toast('Posto occupato: scegli l’altro.');
      break;
    case 'STATE_SNAPSHOT':
      state.snapshot = payload.snapshot || null;
      state.legal = payload.legal || {};
      if (String(payload.window_kind || '') === '') {
        state.prompt = null;
        state.window = null;
      }
      break;
    case 'PRIORITY_REQUEST':
      state.prompt = Object.assign({ kind: 'priority' }, payload);
      state.window = makeWindow(payload);
      break;
    case 'TARGET_REQUEST':
      state.prompt = Object.assign({ kind: 'target' }, payload);
      state.window = null;   // the countdown is PAUSED while you pick
      break;
    case 'DEATH_PENALTY_REQUEST':
      state.prompt = Object.assign({ kind: 'death' }, payload);
      state.deathLoot = null;
      break;
    case 'DOMAIN_EVENT':
      addLog(payload);
      break;
    case 'ERROR':
      toast(`${payload.code}: comando rifiutato`);
      break;
    default:
      break;
  }
  render();
}

/** Server-provided countdown: {total, remaining, at} (ms, monotonic-ish). */
function makeWindow(payload) {
  const total = Number(payload.window_total_ms || 0);
  if (total <= 0) return null;
  const remaining = Number(payload.window_remaining_ms ?? total);
  return { total, remaining, at: performance.now() };
}

function windowLeftMs() {
  const w = state.window;
  if (!w) return 0;
  return Math.max(0, w.remaining - (performance.now() - w.at));
}

/** Keeps the bar fluid and drops the modal when the server's clock runs out. */
function tickCountdown() {
  const box = document.querySelector('.countdown');
  const left = windowLeftMs();
  if (box && state.window) {
    const pct = state.window.total > 0 ? (left / state.window.total) * 100 : 0;
    const bar = box.querySelector('i');
    const label = box.querySelector('span');
    if (bar) bar.style.width = pct + '%';
    if (label) label.textContent = (left / 1000).toFixed(1) + ' s';
    box.classList.toggle('urgent', left < 600);
  }
  if (state.prompt && state.window && left <= 0) {
    state.prompt = null;
    state.window = null;
    render();
  }
}

function addLog(payload) {
  const data = payload.data || {};
  const privateTo = Number(payload.private_to ?? -1);
  const visible = privateTo < 0 || privateTo === state.playerId;
  const who = `P${(Number(data.player_id) || 0) + 1}`;
  const card = visible && data.card_id ? pretty(data.card_id) : 'una carta';
  const text = {
    card_drawn: `${who} pesca ${card}`,
    card_played: `${who} gioca ${card}`,
    card_discarded: `${who} scarta ${card}`,
    item_bought: `${who} compra ${card}`,
    monster_attacked: `${who} attacca: ${data.roll} vs die ${data.die_value} → ${Number(data.roll) >= Number(data.die_value) ? 'HIT' : 'MISS'}`,
    monster_killed: 'mostro ucciso',
    eternal_used: `${who} attiva ${card}`,
    souls_changed: `${who}: anime ${data.total_value}/4`,
    turn_started: `— turno di ${who} —`,
    trigger_pushed: `trigger: ${pretty(data.card_id)} (${data.trigger})`,
    effect_fizzled: `${pretty(data.card_id)} fizzla: bersaglio sparito`,
    target_expired: 'scelta del bersaglio scaduta',
    game_won: `*** ${who} VINCE ***`,
  }[String(payload.event || '')];
  if (!text) return;
  state.log.push(text);
  if (state.log.length > LOG_LIMIT) state.log.shift();
}

// --- Views -------------------------------------------------------------------

function render() {
  $('turn').textContent = state.joined && state.snapshot
    ? `Turno ${state.snapshot.turn_number} · P${state.snapshot.current_player_index + 1} · ${state.snapshot.phase}`
    : 'Four Souls';
  $('net').textContent = state.net;
  $('net').className = state.joined ? 'ok' : 'wait';
  $('app').innerHTML = state.joined ? boardHtml() : lobbyHtml();
  const modal = modalHtml();
  $('modal').innerHTML = modal;
  $('modal').hidden = modal === '';
}

function lobbyHtml() {
  const reconnect = state.token
    ? `<p class="hint">Riconnessione al posto salvato…</p>`
    : `<p class="hint">Scegli il tuo posto al tavolo.</p>`;
  return `
    <section class="panel">
      <h1>Four Souls</h1>
      ${reconnect}
      <div class="row">
        <button class="seat" data-action="join" data-seat="0">Giocatore 1</button>
        <button class="seat" data-action="join" data-seat="1">Giocatore 2</button>
      </div>
      <button class="wide secondary" data-action="join" data-seat="-1">Posto libero</button>
      <p class="hint">Il telefono diventa il tuo controller: carte, priorità e bersagli arrivano qui.</p>
    </section>`;
}

function boardHtml() {
  const s = state.snapshot;
  if (!s) return `<p class="hint pad">In attesa dello stato…</p>`;
  const me = s.players[s.viewer_player_id] || s.players[0];
  const others = s.players.filter((p) => p.id !== me.id);
  return [
    mePanel(me),
    others.map(otherPanel).join(''),
    monstersHtml(s),
    shopHtml(s),
    handHtml(me),
    itemsHtml(me),
    `<button class="wide" data-action="end-turn" ${state.legal.can_end_turn ? '' : 'disabled'}>Fine turno</button>`,
    logHtml(),
  ].join('');
}

function mePanel(p) {
  const tapped = p.character_tapped
    ? '<span class="tag tapped">TAPPATO</span>'
    : '<span class="tag">pronto</span>';
  return `
    <section class="panel me">
      <h2>${esc(pretty(p.character_id))} ${tapped}</h2>
      <div class="stats">
        <span>HP <b>${p.hp}/${p.max_hp}</b></span>
        <span><b>${p.cents}</b>¢</span>
        <span>anime <b>${p.soul_value}/4</b></span>
      </div>
      <div class="hint">eterno: ${esc(pretty(p.eternal_item_id))}${p.eternal_used ? ' (scaricato)' : ''}</div>
    </section>`;
}

function otherPanel(p) {
  return `
    <section class="panel other">
      <h2>P${p.id + 1} · ${esc(pretty(p.character_id))}</h2>
      <div class="stats">
        <span>HP <b>${p.hp}/${p.max_hp}</b></span>
        <span><b>${p.cents}</b>¢</span>
        <span>anime <b>${p.soul_value}/4</b></span>
      </div>
      <div class="hint">${p.hand_count} carte in mano · ${p.items_passive.length} oggetti${p.character_tapped ? ' · personaggio tappato' : ''}</div>
    </section>`;
}

function monstersHtml(s) {
  if (!s.table_monsters.length) return `<section class="panel"><h3>Mostri</h3><p class="hint">nessuno</p></section>`;
  const attackable = Boolean(state.legal.can_attack);
  return `
    <section class="panel">
      <h3>Mostri ${attackable ? '' : '<span class="hint">(non puoi attaccare ora)</span>'}</h3>
      <div class="grid">
        ${s.table_monsters.map((m) => `
          <button class="monster" data-action="attack" data-monster="${esc(m.instance_id)}" ${attackable ? '' : 'disabled'}>
            <strong>${esc(m.display_name)}</strong>
            <small>die ${m.die_value} · hp ${m.hp}${m.is_boss ? ' · BOSS' : ''}${m.shielded ? ' · scudo' : ''}</small>
          </button>`).join('')}
      </div>
    </section>`;
}

function shopHtml(s) {
  const legalBySlot = {};
  for (const entry of state.legal.shop || []) legalBySlot[entry.slot] = entry;
  return `
    <section class="panel">
      <h3>Negozio</h3>
      <div class="grid">
        ${s.shop_slots.map((slot, index) => {
          const legal = legalBySlot[index] || { buyable: false, reason: '' };
          return `<button class="shop" data-action="buy" data-slot="${index}" ${legal.buyable ? '' : 'disabled'}>
            <strong>${esc(slot.display_name)}</strong>
            <small>${slot.cost_cents}¢${legal.buyable ? '' : ' · ' + esc(reasonText(legal.reason))}</small>
          </button>`;
        }).join('')}
      </div>
    </section>`;
}

function reasonText(reason) {
  return {
    not_your_turn: 'non è il tuo turno',
    buy_used: 'acquisto usato',
    already_bought: 'già comprata',
    too_poor: 'troppo caro',
  }[reason] || '';
}

function handHtml(me) {
  const playable = new Set(state.legal.loot_playable || []);
  if (!me.hand.length) {
    return `<section class="panel"><h3>La tua mano</h3><p class="hint">vuota</p></section>`;
  }
  return `
    <section class="panel">
      <h3>La tua mano</h3>
      <div class="grid">
        ${me.hand.map((cardId) => `
          <button class="card playable" data-action="play" data-card="${esc(cardId)}" ${playable.has(cardId) ? '' : 'disabled'}>
            <strong>${esc(pretty(cardId))}</strong>
            <small>${playable.has(cardId) ? 'trascina in alto per giocare' : 'non giocabile ora'}</small>
          </button>`).join('')}
      </div>
      ${playable.size ? '<p class="hint">Swipe verso l’alto (o tap) per lanciare la carta sul tavolo.</p>' : '<p class="hint">Nessuna Loot giocabile ora: serve una finestra di priorità o la tua fase azione con il personaggio pronto.</p>'}
    </section>`;
}

/** "I miei oggetti": tap = rotate 90° (tap state), playable ones also fire. */
function itemsHtml(me) {
  if (!me) return '';
  const owned = me.items_passive || [];
  const eternal = me.eternal_item_id || '';
  if (!owned.length && !eternal) return '';
  const playable = new Set(state.legal.items_playable || []);
  const spent = new Set(me.tapped_items || []);
  const card = (id, label, isTapped, usable) => `
    <button class="item${isTapped ? ' tapped' : ''}" data-action="tap-item" data-card="${esc(id)}">
      <strong>${esc(pretty(id))}</strong>
      <small>${label}</small>
    </button>`;
  const eternalCard = eternal
    ? card(eternal, me.eternal_used ? 'eterno · scarico' : 'eterno · pronto',
        me.eternal_used || state.rotated.has(eternal), false)
    : '';
  return `
    <section class="panel">
      <h3>I miei oggetti</h3>
      <div class="grid">
        ${eternalCard}
        ${owned.map((id) => card(id, playable.has(id) ? 'tap = attiva' : 'tap = gira',
          spent.has(id) || state.rotated.has(id), playable.has(id))).join('')}
      </div>
      <p class="hint">Tap su un oggetto: lo giri di 90° (tappato).</p>
    </section>`;
}

function logHtml() {
  if (!state.log.length) return '';
  return `<section class="panel log"><h3>Eventi</h3>${state.log.map((line) => `<p>${esc(line)}</p>`).join('')}</section>`;
}

// --- Requests (modals) -------------------------------------------------------

function modalHtml() {
  const prompt = state.prompt;
  if (!prompt) return '';
  if (prompt.kind === 'priority') return priorityModal(prompt);
  if (prompt.kind === 'target') return targetModal(prompt);
  if (prompt.kind === 'death') return deathModal(prompt);
  return '';
}

function wrap(inner) {
  return `<div class="modal"><div class="modal-card">${inner}</div></div>`;
}

function priorityModal(prompt) {
  const actions = (prompt.legal_actions || []).map((action) => {
    if (action.action === 'loot') {
      return `<button data-action="loot-response" data-card="${esc(action.card_id)}">Gioca ${esc(pretty(action.card_id))}</button>`;
    }
    if (action.action === 'eternal') return eternalButtons(action);
    if (action.action === 'resolve') return `<button class="secondary" data-action="resolve">Risolvi</button>`;
    return '';
  }).join('');
  const total = Number(prompt.window_total_ms || 0);
  const countdown = total > 0
    ? `<div class="countdown"><div class="track"><i style="width:100%"></i></div><span>${(total / 1000).toFixed(1)} s</span></div>`
    : '';
  return wrap(`
    <h2>Priorità: ${esc(prompt.stack_type)}</h2>
    ${countdown}
    <p class="hint">${esc(stackHint(prompt))}</p>
    ${actions}
    <button class="wide secondary" data-action="pass">Passa subito</button>`);
}

/** What is actually on top of the pile, in words a player reads fast. */
function stackHint(prompt) {
  const entry = prompt.entry || {};
  if (prompt.stack_type === 'pending_roll') {
    return `Tiro pendente: ${entry.value} vs dado ${entry.die_value} — reagisci ora o lascia scadere.`;
  }
  if (prompt.stack_type === 'trigger') {
    return `Trigger di ${pretty(entry.card_id)} (${entry.trigger || ''}) — reagisci ora o lascia scadere.`;
  }
  return `${pretty(entry.card_id || '')} — reagisci ora o lascia scadere.`;
}

function eternalButtons(action) {
  const item = pretty((state.legal.eternal || {}).item_id || '');
  if (action.item_action === 'reroll_die') {
    return `<button data-action="eternal" data-eternal="reroll">${esc(item)}: tira di nuovo</button>`;
  }
  if (action.item_action === 'adjust_die') {
    return `<button data-action="eternal" data-delta="1">${esc(item)} +1</button>
            <button data-action="eternal" data-delta="-1">${esc(item)} -1</button>`;
  }
  if (action.item_action === 'prevent_damage') {
    return (state.snapshot.players || []).map((p) =>
      `<button data-action="eternal" data-target="${p.id}">${esc(item)} su P${p.id + 1}</button>`).join('');
  }
  return '';
}

function targetModal(prompt) {
  const options = prompt.options || [];
  return wrap(`
    <h2>Scegli un bersaglio</h2>
    <p class="hint">Il server ha bisogno di sapere su chi agisce la carta.</p>
    <div class="grid">
      ${options.map((option) => `<button class="monster" data-action="target" data-target="${esc(option.instance_id)}">
        <strong>${esc(option.display_name || pretty(option.card_id))}</strong>
        <small>die ${option.die_value} · hp ${option.hp}</small>
      </button>`).join('')}
    </div>
    <button class="wide secondary" data-action="cancel-target">Annulla</button>`);
}

function deathModal(prompt) {
  const penalty = prompt.penalty || {};
  const lootOptions = penalty.loot_options || [];
  const itemOptions = penalty.item_options || [];
  if (state.deathLoot === null) {
    if (!lootOptions.length) return deathItemStep(prompt, itemOptions);
    return wrap(`
      <h2>Sei morto</h2>
      <p class="hint">Scegli 1 carta Loot da scartare.</p>
      ${lootOptions.map((cardId) =>
        `<button data-action="death-loot" data-card="${esc(cardId)}">${esc(pretty(cardId))}</button>`).join('')}`);
  }
  return deathItemStep(prompt, itemOptions);
}

function deathItemStep(prompt, itemOptions) {
  if (!itemOptions.length) {
    finishDeath('');
    return wrap(`<h2>Sei morto</h2><p class="hint">Nessun oggetto da perdere.</p>`);
  }
  return wrap(`
    <h2>Sei morto</h2>
    <p class="hint">Scegli 1 oggetto da perdere (l’eterno è protetto).</p>
    ${itemOptions.map((cardId) =>
      `<button data-action="death-item" data-card="${esc(cardId)}">${esc(pretty(cardId))}</button>`).join('')}`);
}

function finishDeath(itemId) {
  const prompt = state.prompt;
  if (!prompt) return;
  send('CHOOSE_DEATH_PENALTY', { loot_id: state.deathLoot || '', item_id: itemId }, prompt.request_id);
  state.prompt = null;
  state.deathLoot = null;
  render();
}

// --- Input -------------------------------------------------------------------

document.addEventListener('click', (event) => {
  const node = event.target.closest('[data-action]');
  if (!node) return;
  const action = node.dataset.action;
  const prompt = state.prompt;
  switch (action) {
    case 'join':
      state.seat = Number(node.dataset.seat);
      localStorage.setItem(SEAT_KEY, String(state.seat));
      if (!state.ws || state.ws.readyState !== WebSocket.OPEN) connect();
      else sendJoin();
      break;
    case 'buy':
      send('BUY_SHOP', { slot: Number(node.dataset.slot) });
      break;
    case 'play':
      // A swipe already played this card: do not play it twice on the click.
      if (Date.now() - state.swipedAt < 400) break;
      send('PLAY_LOOT', { card_id: node.dataset.card });
      break;
    case 'item':
      send('PLAY_LOOT', { card_id: node.dataset.card });
      break;
    case 'tap-item': {
      const id = node.dataset.card;
      if (state.rotated.has(id)) state.rotated.delete(id);
      else state.rotated.add(id);
      if ((state.legal.items_playable || []).includes(id)) send('PLAY_LOOT', { card_id: id });
      break;
    }
    case 'attack':
      send('DECLARE_ATTACK', { target_id: node.dataset.monster });
      break;
    case 'end-turn':
      send('END_TURN', {});
      break;
    case 'pass':
    case 'resolve':
      if (prompt) send('PASS_PRIORITY', {}, prompt.request_id);
      state.prompt = null;
      break;
    case 'loot-response':
      if (prompt) send('PLAY_LOOT', { card_id: node.dataset.card }, prompt.request_id);
      state.prompt = null;
      break;
    case 'eternal': {
      if (!prompt) break;
      const payload = {};
      if (node.dataset.delta) payload.delta = Number(node.dataset.delta);
      if (node.dataset.target) payload.target_id = Number(node.dataset.target);
      send('ACTIVATE_ITEM', payload, prompt.request_id);
      state.prompt = null;
      break;
    }
    case 'target':
      if (prompt) send('SELECT_TARGET', { target_id: node.dataset.target }, prompt.request_id);
      state.prompt = null;
      break;
    case 'cancel-target':
      if (prompt) send('SELECT_TARGET', { target_id: '' }, prompt.request_id);
      state.prompt = null;
      break;
    case 'death-loot':
      state.deathLoot = node.dataset.card || '';
      break;
    case 'death-item':
      finishDeath(node.dataset.card || '');
      return;
    default:
      break;
  }
  render();
});

// --- Swipe-up: drag a loot card towards the table --------------------------

let drag = null;

document.addEventListener('pointerdown', (event) => {
  const card = event.target.closest('[data-action="play"]');
  if (!card || card.disabled) return;
  drag = { card, startY: event.clientY, startX: event.clientX, id: event.pointerId };
  try { card.setPointerCapture(event.pointerId); } catch (err) { /* older browsers */ }
});

document.addEventListener('pointermove', (event) => {
  if (!drag || event.pointerId !== drag.id) return;
  const dy = event.clientY - drag.startY;
  const dx = event.clientX - drag.startX;
  if (dy < 0 && Math.abs(dy) > Math.abs(dx)) {
    event.preventDefault();
    drag.card.style.transform = `translateY(${dy}px)`;
    drag.card.classList.toggle('armed', dy < -70);
  }
});

document.addEventListener('pointerup', (event) => {
  if (!drag || event.pointerId !== drag.id) return;
  const dy = event.clientY - drag.startY;
  const card = drag.card;
  drag = null;
  card.style.transform = '';
  card.classList.remove('armed');
  if (dy < -70) {
    state.swipedAt = Date.now();
    send('PLAY_LOOT', { card_id: card.dataset.card });
  }
});

setInterval(tickCountdown, 80);

document.addEventListener('visibilitychange', () => {
  if (document.visibilityState === 'visible' && (!state.ws || state.ws.readyState !== WebSocket.OPEN)) {
    state.retry = 0;
    connect();
  }
});

boot();
