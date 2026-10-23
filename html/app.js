const $ = (s, r = document) => r.querySelector(s);
const state = { garage: null, garages: [], vehicles: [], canManage: false, transfer: { enabled: false, fee: 0 }, recover: { enabled: false, fee: 0 }, manageOnly: false, transferPlate: null, recoverPlate: null, filter: 'all', view: 'list', query: '', sort: 'relevance', open: null, trunks: {}, selLoc: null, thumbnails: {} };

/* Running outside FiveM (plain browser)? Use the built-in mock server below. */
const IN_BROWSER = typeof GetParentResourceName !== 'function';

const post = (name, data = {}) => {
  if (IN_BROWSER) return Promise.resolve(mock.handle(name, data));
  return fetch(`https://${GetParentResourceName()}/${name}`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(data),
  }).catch(() => {});
};

const I = {
  star:  '<svg viewBox="0 0 24 24"><path d="M12 3l2.7 5.8 6.3.7-4.7 4.3 1.3 6.2L12 16.8 6.4 20l1.3-6.2L3 9.5l6.3-.7z"/></svg>',
  chev:  '<svg viewBox="0 0 24 24"><path d="M6 9l6 6 6-6"/></svg>',
  pin:   '<svg viewBox="0 0 24 24"><path d="M12 21s-6-5.6-6-10a6 6 0 0112 0c0 4.4-6 10-6 10z"/><circle cx="12" cy="11" r="2"/></svg>',
  fuel:  '<svg viewBox="0 0 24 24"><path d="M5 20V5h9v15M3 20h13M14 9h3l2 2v6a1.5 1.5 0 01-3 0v-3h-2"/></svg>',
  engine:'<svg viewBox="0 0 24 24"><path d="M4 9h3l1-2h6l1 2h2v7H4zM2 12v3M20 11h2"/></svg>',
  body:  '<svg viewBox="0 0 24 24"><path d="M12 3l8 3v6c0 5-3.5 8-8 9-4.5-1-8-4-8-9V6z"/></svg>',
  drive: '<svg viewBox="0 0 24 24"><path d="M5 12h14M13 6l6 6-6 6"/></svg>',
  clock: '<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="8"/><path d="M12 8v4l3 2"/></svg>',
  trash: '<svg viewBox="0 0 24 24"><path d="M5 7h14M10 7V4h4v3M7 7l1 13h8l1-13"/></svg>',
  box:   '<svg viewBox="0 0 24 24"><path d="M3 8l9-4 9 4v9l-9 4-9-4zM3 8l9 4 9-4M12 12v9"/></svg>',
  swap:  '<svg viewBox="0 0 24 24"><path d="M4 8h14M14 4l4 4-4 4M20 16H6M10 12l-4 4 4 4"/></svg>',
  recover:'<svg viewBox="0 0 24 24"><path d="M21 12a9 9 0 11-3-6.7M21 3v6h-6"/></svg>',
};

const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const level = v => (v < 25 ? 'low' : v < 50 ? 'mid' : '');
const garageById = id => state.garages.find(g => g.id === id);

/* ───────── filtering ───────── */
const here = v => v.state === 'stored' && v.garage === state.garage?.id;
const filters = [
  ['all',        'All',         () => true],
  ['favourites', 'Favourites',  v => v.favourite],
  ['here',       'Parked here', here],
  ['impounded',  'Impounded',   v => v.state === 'impounded'],
];

function visible() {
  const q = state.query.trim().toLowerCase();
  const f = filters.find(x => x[0] === state.filter)[2];
  const by = {
    relevance: (a, b) => (here(b) - here(a)) || (b.favourite - a.favourite) || a.label.localeCompare(b.label),
    name:      (a, b) => a.label.localeCompare(b.label),
    fuel:      (a, b) => a.fuel - b.fuel,
    engine:    (a, b) => a.engine - b.engine,
  }[state.sort];
  return state.vehicles
    .filter(f)
    .filter(v => !q || v.label.toLowerCase().includes(q) || v.plate.toLowerCase().includes(q))
    .sort(by);
}

/* ───────── rendering ───────── */
function renderHeader() {
  const g = state.garage; if (!g) return;
  $('#garageName').textContent = g.name;
  $('#garageTag').classList.toggle('hidden', !g.private);
  $('#spaceText').textContent = `${state.vehicles.filter(here).length}`;
  $('#manageBtn').classList.toggle('hidden', !state.canManage);
}

function renderFilters() {
  $('#filters').innerHTML = filters.map(([key, label, fn]) =>
    `<button data-f="${key}" class="${state.filter === key ? 'on' : ''}">${label}<em>${state.vehicles.filter(fn).length}</em></button>`
  ).join('');
}

function whereLabel(v) {
  if (v.state === 'impounded') return `<span class="where imp">Impounded</span>`;
  if (v.state === 'out')       return `<span class="where out">Out</span>`;
  const g = garageById(v.garage);
  const name = g ? g.name : 'Unknown';
  return `<span class="where ${here(v) ? 'here' : 'away'}">${I.pin}${esc(name)}</span>`;
}

function stat(label, icon, val) {
  return `<div class="stat">
    <div class="stat-label">${icon}${label}</div>
    <div class="stat-val">${val}<small>%</small></div>
    <div class="bar"><i class="${level(val)}" style="--v:${val}%"></i></div>
  </div>`;
}

function trunkHtml(plate) {
  const t = state.trunks[plate];
  if (!t) return '';
  let head = 'Trunk', body;
  if (t.loading) body = '<div class="trunk-msg">Checking the trunk…</div>';
  else if (t.error) body = `<div class="trunk-msg">${esc(t.error)}</div>`;
  else if (!t.supported) body = '<div class="trunk-msg">Trunk contents are not available. No supported inventory script was found.</div>';
  else if (!t.items.length) body = '<div class="trunk-msg">The trunk is empty.</div>';
  else {
    const total = t.items.reduce((n, i) => n + i.count, 0);
    head = `Trunk<em>${total.toLocaleString()} item${total === 1 ? '' : 's'}</em>`;
    body = `<div class="trunk-items">${t.items.map(i =>
      `<span class="item" title="${esc(i.name)}">${esc(i.label)}<em>×${i.count.toLocaleString()}</em></span>`).join('')}</div>`;
  }
  return `<div class="trunk-head">${I.box}${head}</div>${body}`;
}

function toggleTrunk(plate) {
  if (state.trunks[plate]) delete state.trunks[plate];
  else { state.trunks[plate] = { loading: true }; post('trunk', { plate }); }
  paintTrunk(plate);
}

function paintTrunk(plate) {
  const row = [...document.querySelectorAll('#list .row')].find(r => r.dataset.plate === plate);
  if (!row) return;
  const box = row.querySelector('.trunk');
  box.innerHTML = trunkHtml(plate);
  box.classList.toggle('show', !!state.trunks[plate]);
  row.querySelector('[data-act="trunk"]')?.classList.toggle('on', !!state.trunks[plate]);
}

function actions(v) {
  let main;
  if (here(v)) main = `<button class="btn solid sm" data-act="drive">${I.drive}Drive</button>`;
  else if (v.state === 'out' && state.garage && state.recover.enabled) main = `<button class="btn solid sm" data-act="recover">${I.recover}Recover${state.recover.fee > 0 ? ` · $${state.recover.fee.toLocaleString()}` : ''}</button>`;
  else if (v.state === 'stored' && garageById(v.garage)) main = `<button class="btn sm" data-act="waypoint">${I.pin}Set waypoint</button>`;
  else main = `<button class="btn sm" disabled>Unavailable</button>`;
  const canTransfer = state.transfer.enabled && state.garage && v.state === 'stored' && garageById(v.garage) && v.garage !== state.garage.id;
  const move = canTransfer ? `<button class="btn sm" data-act="transfer">${I.swap}Transfer here</button>` : '';
  const trunk = `<button class="btn sm ${state.trunks[v.plate] ? 'on' : ''}" data-act="trunk">${I.box}Trunk</button>`;
  return `<div class="actions">${main}${move}${trunk}<span class="sp"></span>
    <button class="icon star ${v.favourite ? 'on' : ''}" data-act="fav" aria-label="Favourite">${I.star}</button></div>`;
}

function thumbUrl(v) {
  // Custom thumbnail from data/thumbnails.json (server sends it in the payload).
  // Keys are case-insensitive (the server normalises them to lowercase).
  const m = (v.model || '').toLowerCase();
  if (m && state.thumbnails && state.thumbnails[m]) return state.thumbnails[m];
  // Fall back to the docs.fivem.net vehicle thumbnail (works for stock GTA cars only).
  return `https://docs.fivem.net/vehicles/${encodeURIComponent(v.model)}.webp`;
}

function card(v) {
  const open = state.open === v.plate;
  const mi = v.mileage > 0 ? `<span class="mi">${I.clock}${Math.round(v.mileage).toLocaleString()} mi</span>` : '';
  return `<article class="row ${open ? 'open' : ''} ${v.favourite ? 'fav' : ''}" data-plate="${esc(v.plate)}">
    <div class="row-main">
      <img class="thumb" loading="lazy" alt="" src="${esc(thumbUrl(v))}" onerror="this.classList.add('none');this.removeAttribute('src')">
      <div class="info"><div class="name">${esc(v.label)}</div><div class="meta"><span class="plate">${esc(v.plate)}</span>${mi}</div></div>
      ${whereLabel(v)}
      <button class="icon star ${v.favourite ? 'on' : ''}" data-act="fav" aria-label="Favourite">${I.star}</button>
      <span class="icon chev">${I.chev}</span>
    </div>
    <div class="detail"><div class="detail-in"><div class="detail-pad">
      <div class="stats">${stat('Fuel', I.fuel, v.fuel)}${stat('Engine', I.engine, v.engine)}${stat('Body', I.body, v.body)}</div>
      ${actions(v)}
      <div class="trunk ${state.trunks[v.plate] ? 'show' : ''}">${trunkHtml(v.plate)}</div>
    </div></div></div>
  </article>`;
}

function renderList(animate = false) {
  const list = $('#list');
  const top = list.scrollTop;
  list.classList.toggle('grid', state.view === 'grid');
  const items = visible();
  $('#count').textContent = `${items.length} vehicle(s)`;

  if (!items.length) {
    list.innerHTML = `<div class="empty"><b>No vehicles found</b>${state.vehicles.length ? 'Try a different filter or search.' : 'Sit in a vehicle and use /addveh to register it.'}</div>`;
    return;
  }
  list.style.scrollBehavior = 'auto';
  list.innerHTML = items.map(card).join('');
  list.scrollTop = animate ? 0 : top;
  list.style.scrollBehavior = '';

  if (animate) {
    list.querySelectorAll('.row').forEach((r, i) => {
      if (i > 11) return;
      r.style.setProperty('--i', i);
      r.classList.add('in');
    });
  }
}

function renderLocations() {
  const bays = g => (g.spawns && g.spawns.length) || 1;
  if (state.selLoc != null && !garageById(state.selLoc)) state.selLoc = null;
  $('#locCount').textContent = state.garages.length ? `(${state.garages.length})` : '';
  $('#locList').innerHTML = state.garages.length ? state.garages.map(g => {
    const n = bays(g);
    return `<li class="loc ${g.id === state.selLoc ? 'sel' : ''}" data-id="${g.id}" title="${esc(g.name)}">
      <button class="loc-head" data-loc="select">
        <span class="loc-ico">${I.pin}</span>
        <span class="n">${esc(g.name)}<small>${n} bay${n === 1 ? '' : 's'}</small></span>
        ${g.private ? '<span class="priv-dot" title="Private"></span>' : ''}
      </button>
    </li>`;
  }).join('') : `<li class="none"><div class="n">No locations yet<small>Add one on the left.</small></div></li>`;
  renderLocDetail();
}

function renderLocDetail() {
  const box = $('#locDetail');
  const g = state.selLoc != null ? garageById(state.selLoc) : null;
  if (!g) { box.className = 'loc-detail none'; box.removeAttribute('data-id'); box.innerHTML = 'Select a location to manage it.'; return; }
  const n = (g.spawns && g.spawns.length) || 1;
  box.className = 'loc-detail';
  box.dataset.id = g.id;
  box.innerHTML = `<div class="ld-info">
      <div class="ld-name">${esc(g.name)}</div>
      <div class="ld-meta">${g.private ? 'Private' : 'Public'} · ${g.zone ? `${g.zone.points.length}-point area` : 'Radius only'} · ${n} bay${n === 1 ? '' : 's'}</div>
    </div>
    <div class="actions">
      <button class="btn sm" data-loc="spawns">Bays</button>
      <button class="btn sm" data-loc="redraw">Redraw</button>
      <button class="btn sm" data-loc="waypoint">Waypoint</button>
      <button class="icon del" data-loc="delete" aria-label="Delete ${esc(g.name)}">${I.trash}</button>
    </div>`;
}

function renderTransfer() {
  const v = state.vehicles.find(x => x.plate === state.transferPlate);
  const to = state.garage;
  if (!v || !to) return;
  const from = garageById(v.garage);
  const fee = state.transfer.fee;
  const hint = $('#transferHint');
  hint.classList.remove('warn');
  hint.innerHTML = `Move <b>${esc(v.label)}</b> (${esc(v.plate)}) from <b>${esc(from ? from.name : 'Unknown')}</b> to <b>${esc(to.name)}</b>?`
    + (fee > 0 ? ` A fee of <b>$${fee.toLocaleString()}</b> applies.` : '');
  $('#transferConfirm').disabled = false;
}

function openTransfer(plate) {
  state.transferPlate = plate;
  renderTransfer();
  $('#transferModal').classList.add('show');
}

function renderRecover() {
  const v = state.vehicles.find(x => x.plate === state.recoverPlate);
  const to = state.garage;
  if (!v || !to) return;
  const fee = state.recover.fee;
  const hint = $('#recoverHint');
  hint.classList.remove('warn');
  hint.innerHTML = `Recover <b>${esc(v.label)}</b> (${esc(v.plate)}) and deliver it to <b>${esc(to.name)}</b>?`
    + (fee > 0 ? ` A fee of <b>$${fee.toLocaleString()}</b> applies.` : ' No fee applies.');
  $('#recoverConfirm').disabled = false;
}

function openRecover(plate) {
  state.recoverPlate = plate;
  renderRecover();
  $('#recoverModal').classList.add('show');
}

function render(animate = false) { renderHeader(); renderFilters(); renderList(animate); renderLocations(); if ($('#transferModal').classList.contains('show')) renderTransfer(); if ($('#recoverModal').classList.contains('show')) renderRecover(); }

/* ───────── events ───────── */
$('#list').addEventListener('click', e => {
  const row = e.target.closest('.row'); if (!row) return;
  const plate = row.dataset.plate;
  const act = e.target.closest('[data-act]')?.dataset.act;

  if (act === 'fav') { post('favourite', { plate }); return; }
  if (act === 'drive') { post('drive', { plate }); return; }
  if (act === 'transfer') { openTransfer(plate); return; }
  if (act === 'recover') { openRecover(plate); return; }
  if (act === 'trunk') { toggleTrunk(plate); return; }
  if (act === 'waypoint') {
    const v = state.vehicles.find(x => x.plate === plate);
    const g = garageById(v.garage);
    if (g) post('waypoint', { x: g.coords.x, y: g.coords.y });
    return;
  }
  if (e.target.closest('.detail')) return;
  const wasOpen = state.open === plate;
  state.open = wasOpen ? null : plate;
  document.querySelectorAll('#list .row.open').forEach(r => r.classList.remove('open'));
  if (!wasOpen) {
    row.classList.add('open');
    setTimeout(() => row.scrollIntoView({ block: 'nearest', behavior: 'smooth' }), 260);
  }
});

$('#filters').addEventListener('click', e => {
  const b = e.target.closest('[data-f]'); if (!b) return;
  state.filter = b.dataset.f; state.open = null; renderFilters(); renderList(true);
});

$('#sort').addEventListener('change', e => { state.sort = e.target.value; renderList(true); });
$('#search').addEventListener('input', e => { state.query = e.target.value; renderList(); });

$('#viewList').onclick = () => { state.view = 'list'; $('#viewList').classList.add('on'); $('#viewGrid').classList.remove('on'); renderList(true); };
$('#viewGrid').onclick = () => { state.view = 'grid'; $('#viewGrid').classList.add('on'); $('#viewList').classList.remove('on'); renderList(true); };

$('#closeBtn').onclick = () => post('close');
$('#manageBtn').onclick = () => { renderLocations(); $('#modal').classList.add('show'); setTimeout(() => $('#locName').focus(), 120); };
$('#modalClose').onclick = closeManage;
$('#transferClose').onclick = () => $('#transferModal').classList.remove('show');

/* Opened with /bgarage manage there is no garage behind the dialog, so closing it closes everything */
function closeManage() {
  $('#modal').classList.remove('show');
  if (state.manageOnly) post('close');
}

const closeTransfer = () => $('#transferModal').classList.remove('show');
$('#transferCancel').onclick = closeTransfer;
$('#transferConfirm').onclick = () => {
  if (!state.garage || !state.transferPlate) return;
  const v = state.vehicles.find(x => x.plate === state.transferPlate);
  post('transfer', { plate: state.transferPlate, to: state.garage.id, label: v ? v.label : null });
  closeTransfer();
};

$('#recoverClose').onclick = () => $('#recoverModal').classList.remove('show');
$('#recoverCancel').onclick = () => $('#recoverModal').classList.remove('show');
$('#recoverConfirm').onclick = () => {
  if (!state.garage || !state.recoverPlate) return;
  post('recover', { plate: state.recoverPlate });
  $('#recoverModal').classList.remove('show');
};

$('#locAdd').onclick = () => {
  const name = $('#locName').value.trim();
  if (name.length < 2) return toast('Enter a name for the location.', 'error');
  post('addLocation', { name, private: $('#locPrivate').checked });
  $('#locName').value = '';
  $('#locPrivate').checked = false;
};

$('#locList').addEventListener('click', e => {
  const b = e.target.closest('[data-loc="select"]'); if (!b) return;
  const id = Number(b.closest('li').dataset.id);
  state.selLoc = state.selLoc === id ? null : id;
  renderLocations();
});

$('#locDetail').addEventListener('click', e => {
  const b = e.target.closest('[data-loc]'); if (!b) return;
  const id = Number($('#locDetail').dataset.id);
  if (b.dataset.loc === 'delete') post('deleteLocation', { id });
  if (b.dataset.loc === 'spawns') { $('#modal').classList.remove('show'); post('editSpawns', { id, loc: garageById(id) }); }
  if (b.dataset.loc === 'redraw') { $('#modal').classList.remove('show'); post('redrawLocation', { id }); }
  if (b.dataset.loc === 'waypoint') { const g = garageById(id); if (g) post('waypoint', { x: g.coords.x, y: g.coords.y }); }
});

window.addEventListener('keydown', e => {
  if (e.key !== 'Escape' || $('#panel').classList.contains('hidden')) return;
  if ($('#recoverModal').classList.contains('show')) $('#recoverModal').classList.remove('show');
  else if ($('#transferModal').classList.contains('show')) $('#transferModal').classList.remove('show');
  else if ($('#modal').classList.contains('show')) closeManage();
  else post('close');
});

/* ───────── toast ───────── */
let toastTimer;
function toast(text, kind = 'info') {
  const t = $('#toast');
  t.textContent = text; t.className = `toast ${kind}`;
  void t.offsetWidth; t.classList.add('show');
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => t.classList.remove('show'), 3200);
}

/* ───────── messages from Lua ───────── */
function apply(d, animate = false) {
  Object.assign(state, {
    garage: d.garage || null,
    garages: d.garages,
    vehicles: d.vehicles || [],
    canManage: d.canManage,
    transfer: d.transfer || { enabled: false, fee: 0 },
    recover: d.recover || { enabled: false, fee: 0 },
    thumbnails: d.thumbnails || state.thumbnails || {},
  });
  render(animate);
}

let leaveTimer;
window.addEventListener('message', ({ data: m }) => {
  switch (m.action) {
    case 'open': {
      clearTimeout(leaveTimer);
      state.manageOnly = false;
      $('#panel').classList.remove('manage-only');
      Object.assign(state, { filter: 'all', query: '', sort: 'relevance', open: null, trunks: {} });
      $('#search').value = '';
      $('#sort').value = 'relevance';
      apply(m.data, true);
      const p = $('#panel');
      p.classList.remove('hidden', 'enter', 'leave'); void p.offsetWidth; p.classList.add('enter');
      break;
    }
    case 'manage': {
      clearTimeout(leaveTimer);
      state.manageOnly = true;
      $('#transferModal').classList.remove('show');
      $('#recoverModal').classList.remove('show');
      apply(m.data);
      const p = $('#panel');
      p.classList.add('manage-only');
      p.classList.remove('hidden', 'enter', 'leave'); void p.offsetWidth; p.classList.add('enter');
      renderLocations();
      $('#modal').classList.add('show');
      setTimeout(() => $('#locName').focus(), 120);
      break;
    }
    case 'update': apply(m.data); break;
    case 'close': {
      const p = $('#panel');
      $('#modal').classList.remove('show');
      $('#transferModal').classList.remove('show');
      $('#recoverModal').classList.remove('show');
      if (p.classList.contains('hidden')) break;
      p.classList.remove('enter'); p.classList.add('leave');
      leaveTimer = setTimeout(() => { p.classList.add('hidden'); p.classList.remove('leave', 'manage-only'); state.manageOnly = false; }, 160);
      break;
    }
    case 'trunk': {
      const d = m.data || {};
      if (!state.trunks[d.plate]) break; // closed again while loading
      state.trunks[d.plate] = { supported: d.supported !== false, items: d.items || [], error: d.error };
      paintTrunk(d.plate);
      break;
    }
    case 'toast': toast(m.text, m.kind); break;
    case 'prompt':
      $('#prompt').classList.toggle('show', !!m.text);
      if (m.text) $('#prompt span').textContent = m.text;
      break;
  }
});

/* ───────── browser preview (mock server) ───────── */
const mock = {
  garage: 1,
  garages: [
    { id: 1, name: 'Legion Square',    slots: 12, private: false, coords: { x: 215.9, y: -810.1 }, spawns: [{}, {}, {}] },
    { id: 2, name: 'Vinewood Collection', slots: 6, private: true, coords: { x: 365.1, y: 295.5 } },
    { id: 3, name: 'Mirror Park',      slots: 8,  private: false, coords: { x: 1033.5, y: -763.2 } },
  ],
  vehicles: [
    { plate: 'ENUS 1', mileage: 4734,  model: 'paragon',  label: 'Enus Paragon',       fuel: 76,  engine: 100, body: 100, state: 'stored', garage: 1, favourite: true },
    { plate: 'GTO 88', mileage: 1144,  model: 'italigto', label: 'Grotti Itali GTO',   fuel: 98,  engine: 94,  body: 88,  state: 'stored', garage: 1, favourite: false },
    { plate: 'OMAGGIO', mileage: 203, model: 'turismo2', label: 'Grotti Turismo Omaggio', fuel: 41, engine: 72, body: 65, state: 'stored', garage: 1, favourite: false },
    { plate: 'XO CLUB', mileage: 301, model: 'torero2',  label: 'Pegassi Torero XO',  fuel: 22,  engine: 100, body: 97,  state: 'stored', garage: 1, favourite: false },
    { plate: 'RETRO 6', mileage: 17622, model: 'elegy',    label: 'Annis Elegy Retro Custom', fuel: 60, engine: 18, body: 40, state: 'stored', garage: 2, favourite: true },
    { plate: 'MIDNIGHT', mileage: 7754,model: 'jester3',  label: 'Dinka Jester RR',    fuel: 85,  engine: 100, body: 100, state: 'stored', garage: 3, favourite: true },
    { plate: 'PACIFIC', mileage: 2013, model: 'cometS2',  label: 'Pfister Comet S2 Cabrio', fuel: 30, engine: 80, body: 76, state: 'impounded', garage: null, favourite: false },
    { plate: 'SILENT', mileage: 2589,  model: 'neon',     label: 'Pfister Neon',       fuel: 55,  engine: 90,  body: 90,  state: 'out', garage: null, favourite: false },
  ],
  data() {
    return {
      garage: this.garages.find(g => g.id === this.garage),
      garages: this.garages,
      vehicles: this.vehicles,
      canManage: true,
      transfer: { enabled: true, fee: 250 },
      recover: { enabled: true, fee: 5000 },
      thumbnails: this.thumbnails,
    };
  },
  thumbnails: {
    // Demonstrate custom thumbnails in the browser preview. In-game these come from
    // data/thumbnails.json, sent to the NUI by the server. Try any URL below.
    'italigto': 'https://docs.fivem.net/vehicles/italigto.webp',
    'paragon':  'https://docs.fivem.net/vehicles/paragon.webp',
  },
  handle(name, d) {
    switch (name) {
      case 'close':
        window.postMessage({ action: 'close' }, '*');
        break;
      case 'favourite': {
        const v = this.vehicles.find(x => x.plate === d.plate); if (v) v.favourite = !v.favourite;
        apply(this.data()); break;
      }
      case 'drive': {
        const v = this.vehicles.find(x => x.plate === d.plate);
        if (v) { v.state = 'out'; v.garage = null; }
        apply(this.data()); toast(`${v.label} brought out.`, 'success'); break;
      }
      case 'transfer': {
        const v = this.vehicles.find(x => x.plate === d.plate);
        const g = this.garages.find(x => x.id === d.to);
        if (!v || !g || v.state !== 'stored') break;
        v.garage = g.id;
        apply(this.data()); toast(`${v.label} transferred to ${g.name}.`, 'success'); break;
      }
      case 'recover': {
        const v = this.vehicles.find(x => x.plate === d.plate);
        if (!v || v.state !== 'out') break;
        v.state = 'stored'; v.garage = this.garage;
        apply(this.data()); toast(`${v.label} recovered to ${this.garages.find(g => g.id === this.garage).name} (in-game this would fail if someone is driving it).`, 'success'); break;
      }
      case 'addLocation': {
        const id = Math.max(...this.garages.map(g => g.id)) + 1;
        const zone = { points: [{x:0,y:0},{x:5,y:0},{x:5,y:5},{x:0,y:5}], minZ: 0, maxZ: 4 };
        this.garages.push({ id, name: d.name, private: d.private, coords: { x: 2.5, y: 2.5 }, zone });
        apply(this.data()); toast(`Location "${d.name}" added (drawing is in-game only).`, 'success'); break;
      }
      case 'redrawLocation': toast('Drawing is only available in-game.', 'info'); break;
      case 'editSpawns': toast('Placing bays is only available in-game.', 'info'); break;
      case 'deleteLocation': {
        if (this.garages.length < 2) { toast('Keep at least one location in the preview.', 'error'); break; }
        this.garages = this.garages.filter(g => g.id !== d.id);
        this.vehicles.forEach(v => { if (v.garage === d.id) { v.state = 'out'; v.garage = null; } });
        if (this.garage === d.id) this.garage = this.garages[0].id;
        apply(this.data()); toast('Location deleted.', 'success'); break;
      }
      case 'waypoint': toast('Waypoint set.', 'success'); break;
      case 'trunk': {
        const stock = {
          'ENUS 1':  [['Spare tyre', 1], ['Repair kit', 3], ['Water', 6]],
          'GTO 88':  [],
          'OMAGGIO': [['Lockpick', 4], ['Bandage', 10], ['Sandwich', 2], ['Phone', 1], ['Radio', 1]],
        };
        const items = (stock[d.plate] || [['Jerry can', 1]]).map(([label, count]) => ({ name: label.toLowerCase().replace(/ /g, '_'), label, count }));
        setTimeout(() => window.postMessage({ action: 'trunk', data: { plate: d.plate, supported: true, items } }, '*'), 350);
        break;
      }
    }
  },
};

if (IN_BROWSER) {
  document.body.classList.add('dev');
  const bar = document.createElement('div');
  bar.className = 'devbar';
  bar.innerHTML = `
    <span>Browser preview</span>
    <button data-d="open">Open garage</button>
    <button data-d="prompt">Toggle prompt</button>
    <button data-d="manage">/bgarage manage</button>
    <select id="devGarage"></select>`;
  document.body.appendChild(bar);

  const sel = $('#devGarage');
  const fillSel = () => { sel.innerHTML = mock.garages.map(g => `<option value="${g.id}" ${g.id === mock.garage ? 'selected' : ''}>${esc(g.name)}</option>`).join(''); };
  fillSel();
  sel.onchange = () => { mock.garage = Number(sel.value); if (!$('#panel').classList.contains('hidden')) apply(mock.data()); };

  let promptOn = false;
  bar.addEventListener('click', e => {
    const k = e.target.dataset.d;
    if (k === 'open') { fillSel(); window.postMessage({ action: 'open', data: mock.data() }, '*'); }
    if (k === 'manage') { window.postMessage({ action: 'manage', data: { garages: mock.garages, vehicles: [], canManage: true, transfer: { enabled: true, fee: 250 }, recover: { enabled: true, fee: 5000 } } }, '*'); }
    if (k === 'prompt') { promptOn = !promptOn; window.postMessage({ action: 'prompt', text: promptOn ? 'Open garage' : null }, '*'); }
  });

  window.postMessage({ action: 'open', data: mock.data() }, '*');
}
