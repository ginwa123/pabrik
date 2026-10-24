'use strict';

// The console's whole client: no framework, no build step.

const endpoints = {
  overview: '/api/admin/overview',
  users: '/api/admin/users',
  machines: '/api/admin/vms',
};

const SECTIONS = ['accounts', 'machines'];
const DEFAULT_SECTION = 'accounts';
/// Where the console lives. A section is a real path under it, not a
/// `#fragment`, so the address bar, a pasted link and the back button all name
/// the same thing.
const BASE_PATH = '/admin';
const MEMORY_LADDER_MIB = [256, 384, 512, 768, 1024, 1536, 2048, 3072, 4096, 6144, 8192, 12288, 16384];
const STORAGE_LADDER_MIB = [256, 512, 1024, 2048, 4096, 8192, 16384, 32768, 65536];

const CELL = 'border-b border-surface-up px-3 py-3 align-middle'; // taste-skill-ignore: real table rows
const CELL_STRONG = `${CELL} font-medium text-cream`;
const CELL_QUIET = `${CELL} text-ink-muted`;
const CELL_NUMBER = `${CELL} tabular-nums`;
const ROW = 'animate-rise motion-reduce:animate-none';
const QUIET_BUTTON = 'rounded-card px-3 py-1.5 text-link transition-colors hover:bg-surface-up';

const el = (id) => document.getElementById(id);

let currentSection = 'accounts';
let machinesLoaded = false;

function showNotice(message, isError) {
  const notice = el('notice');
  notice.textContent = message;
  notice.classList.toggle('notice-error', Boolean(isError));
  notice.hidden = false;
}

function clearNotice() {
  const notice = el('notice');
  notice.hidden = true;
  notice.textContent = '';
}

async function request(path, options) {
  const opts = options || {};
  const init = { method: opts.method || 'GET' };
  if (opts.body !== undefined) {
    init.headers = { 'Content-Type': 'application/json' };
    init.body = JSON.stringify(opts.body);
  }
  const response = await fetch(path, init);
  const text = await response.text();
  let payload = null;
  if (text) {
    try {
      payload = JSON.parse(text);
    } catch (parseError) {
      payload = null;
    }
  }
  if (!response.ok) {
    const detail = payload && payload.error ? payload.error : `Request failed (${response.status})`;
    const failure = new Error(detail);
    failure.status = response.status;
    throw failure;
  }
  return payload;
}

function mibLabel(mib) {
  const size = Number(mib) || 0;
  if (size <= 0) return 'not started';
  if (size >= 1024) {
    const gib = size / 1024;
    return `${Number.isInteger(gib) ? gib : gib.toFixed(1)} GiB`;
  }
  return `${size} MiB`;
}

/* The resize dialog speaks one unit per field, so a size is written the way it
   is typed into the field: 0.5 for 512 MiB, 1.5 for 1536 MiB. */
function gibText(mib) {
  const size = Number(mib) || 0;
  if (size <= 0) return '';
  const gib = size / 1024;
  return Number.isInteger(gib) ? String(gib) : String(Number(gib.toFixed(3)));
}

function gibLabel(mib) {
  return gibText(mib) ? `${gibText(mib)} GiB` : '0 GiB';
}


function workspaceLabel(vm) {
  return vm.workspace_name || vm.workspace_id;
}

function roleLabel(role) {
  if (role === 'admin') return 'Owner';
  if (role === 'bot') return 'Bot';
  return 'User';
}

function cell(row, className) {
  const td = document.createElement('td');
  if (className) td.className = className;
  row.appendChild(td);
  return td;
}

/* ── the console's navigation: one section at a time ────────────────────── */

/// The section the address bar is asking for. `/admin` and `/admin/` are the
/// front door and show Accounts; anything that is not a section falls back to
/// it too, so a stale bookmark still lands somewhere useful.
function sectionFromPath() {
  const path = window.location.pathname.replace(/\/+$/, '');
  const name = path.startsWith(`${BASE_PATH}/`) ? path.slice(BASE_PATH.length + 1) : '';
  return SECTIONS.includes(name) ? name : DEFAULT_SECTION;
}

function showSection(name) {
  currentSection = SECTIONS.includes(name) ? name : DEFAULT_SECTION;
  SECTIONS.forEach((section) => {
    el(`section-${section}`).hidden = section !== currentSection;
  });
  document.querySelectorAll('.nav-item').forEach((button) => {
    button.setAttribute('aria-pressed', String(button.dataset.section === currentSection));
  });
  if (currentSection === 'machines' && !machinesLoaded) loadMachines();
}

/// A click on the rail: draw the section, and give it the address it names —
/// unless that is already the address being shown, so clicking the open section
/// does not stack history entries.
function goToSection(name) {
  showSection(name);
  if (!window.location.protocol.startsWith('http')) return;
  if (sectionFromPath() === currentSection) return;
  window.history.pushState({ section: currentSection }, '', `${BASE_PATH}/${currentSection}`);
}

/* ── counts ─────────────────────────────────────────────────────────────── */

function drawCounts(counts) {
  el('count-total').textContent = String(counts.total_users);
  el('count-active').textContent = String(counts.active_users);
  el('count-owners').textContent = String(counts.admin_users);
  el('count-bots').textContent = String(counts.bot_users);
  el('count-sessions').textContent = String(counts.active_sessions);
}

/* ── accounts ───────────────────────────────────────────────────────────── */

function roleSelect(user) {
  const select = document.createElement('select');
  select.className = 'role-select';
  select.setAttribute('aria-label', `Role for ${user.email}`);
  ['user', 'admin', 'bot'].forEach((role) => {
    const option = document.createElement('option');
    option.value = role;
    option.textContent = roleLabel(role);
    if (role === user.role) option.selected = true;
    select.appendChild(option);
  });
  select.addEventListener('change', () => {
    changeUser(user.id, { role: select.value });
  });
  return select;
}

function statusButton(user) {
  const button = document.createElement('button');
  button.type = 'button';
  button.className = user.is_active ? 'status-on' : 'status-on status-off';
  button.textContent = user.is_active ? 'Active' : 'Disabled';
  button.setAttribute('aria-label', `Switch ${user.email} ${user.is_active ? 'off' : 'on'}`);
  button.addEventListener('click', () => {
    changeUser(user.id, { is_active: !user.is_active });
  });
  return button;
}

function resetButton(user) {
  const button = document.createElement('button');
  button.type = 'button';
  button.className = QUIET_BUTTON;
  button.textContent = 'Reset password';
  button.addEventListener('click', () => {
    resetPassword(user);
  });
  return button;
}

function drawUsers(users) {
  const body = el('accounts-body');
  body.textContent = '';
  users.forEach((user) => {
    const row = document.createElement('tr');
    row.className = ROW;

    const email = cell(row, CELL_STRONG);
    email.textContent = user.email;

    const name = cell(row, CELL_QUIET);
    name.textContent = user.name || 'No name';

    cell(row).appendChild(roleSelect(user));
    cell(row).appendChild(statusButton(user));
    cell(row).appendChild(resetButton(user));

    body.appendChild(row);
  });
  el('accounts-empty').hidden = users.length !== 0;
}

/* ── workspace machines and their resize menu ───────────────────────────── */

const AMOUNT = /^([0-9]+(?:[.,][0-9]+)?)\s*(vcpus?|cpus?|cores?|gib?|gb|g|mib?|mb|m)?$/i;

/* "2", "2 vCPU", "16gib", "512 MiB": a field reads the number and whatever unit
   was typed with it, and falls back to the field's own unit when there is none.
   Returns null for text that is not a size at all. */
function parseAmount(text) {
  const match = AMOUNT.exec(String(text == null ? '' : text).trim());
  if (!match) return null;
  const value = Number(match[1].replace(',', '.'));
  if (!Number.isFinite(value)) return null;
  const suffix = (match[2] || '').toLowerCase();
  let kind = '';
  if (suffix.startsWith('vc') || suffix.startsWith('cp') || suffix.startsWith('co')) kind = 'vcpu';
  else if (suffix === 'gib' || suffix === 'gb' || suffix === 'g') kind = 'gib';
  else if (suffix === 'mib' || suffix === 'mb' || suffix === 'm') kind = 'mib';
  return { value, kind };
}

/* An entry as the list draws it: `label` is the size it offers, `text` is what
   the field holds once it is picked, `keys` is what typing filters on. */
function sizeEntry(value, label, note, text) {
  return {
    value,
    label,
    note,
    text,
    keys: text ? [String(text), String(value)] : ['keep'],
  };
}

const combos = {};

/* ── one size field: a number you type, and the presets worth trying ─────── */

function setupCombo(inputId, unit) {
  const input = el(inputId);
  const root = input.closest('.combo');
  const list = root.querySelector('[data-combo-list]');
  const pop = root.querySelector('[data-combo-pop]');
  const empty = root.querySelector('[data-combo-note]');
  const toggle = root.querySelector('[data-combo-toggle]');
  const error = el(`${inputId}-error`);

  let entries = [];
  let active = -1;
  let open = false;
  // Only text the operator typed narrows the list. Opening the field on the
  // size the machine already runs must still show every preset.
  let typed = false;

  const options = () => Array.from(list.children);

  function setError(message) {
    error.textContent = message || '';
    error.hidden = !message;
    if (message) {
      input.setAttribute('aria-invalid', 'true');
      input.setAttribute('aria-describedby', `${inputId}-error`);
    } else {
      input.removeAttribute('aria-invalid');
      input.removeAttribute('aria-describedby');
    }
  }

  function highlight(index) {
    const all = options();
    active = index >= 0 && index < all.length ? index : -1;
    all.forEach((option, position) => {
      option.dataset.active = String(position === active);
    });
    const option = all[active];
    if (!option) {
      input.removeAttribute('aria-activedescendant');
      return;
    }
    input.setAttribute('aria-activedescendant', option.id);
    if (typeof option.scrollIntoView === 'function') option.scrollIntoView({ block: 'nearest' });
  }

  /* A dialog scrolls its own content, so the list is measured against the
     dialog's edge, not the window's: it opens upward when the room is there. */
  function place() {
    const rect = input.getBoundingClientRect();
    const dialog = input.closest('dialog');
    const frame = dialog ? dialog.getBoundingClientRect() : { top: 0, bottom: window.innerHeight };
    const below = frame.bottom - rect.bottom - 16;
    const above = rect.top - frame.top - 16;
    pop.dataset.place = pop.offsetHeight > below && above > below ? 'up' : 'down';
  }

  function draw() {
    const needle = typed ? input.value.trim().toLowerCase() : '';
    const shown = entries.filter((entry) => !needle
      || entry.keys.some((key) => key.startsWith(needle)));
    list.textContent = '';
    shown.forEach((entry, position) => {
      const option = document.createElement('li');
      option.className = 'combo-option';
      option.id = `${inputId}-option-${position}`;
      option.setAttribute('role', 'option');
      option.dataset.value = String(entry.value);
      option.dataset.active = 'false';
      const label = document.createElement('span');
      label.textContent = entry.label;
      option.appendChild(label);
      if (entry.note) {
        const note = document.createElement('span');
        note.className = 'combo-option-note';
        note.textContent = entry.note;
        option.appendChild(note);
      }
      option.addEventListener('mousedown', (event) => event.preventDefault());
      option.addEventListener('click', () => pick(entry));
      list.appendChild(option);
    });
    empty.hidden = shown.length !== 0;
    highlight(-1);
  }

  function openList() {
    if (open) return;
    open = true;
    pop.hidden = false;
    input.setAttribute('aria-expanded', 'true');
    draw();
    place();
  }

  function closeList() {
    if (!open) return;
    open = false;
    pop.hidden = true;
    input.setAttribute('aria-expanded', 'false');
    highlight(-1);
  }

  function pick(entry) {
    input.value = entry.text;
    typed = false;
    closeList();
    setError('');
    input.focus();
  }

  /* Typed sizes are rewritten the way the field states them: "512 MiB" becomes
     "0.5", and a zero-padded number loses the padding. Text that is not a size
     is left alone for the submit's own check to name. */
  function normalize() {
    const parsed = parseAmount(input.value);
    if (!parsed) return;
    if (unit === 'vcpu') {
      if (parsed.kind && parsed.kind !== 'vcpu') return;
      if (Number.isInteger(parsed.value)) input.value = String(parsed.value);
      return;
    }
    if (parsed.kind === 'vcpu') return;
    const mib = Math.round(parsed.kind === 'mib' ? parsed.value : parsed.value * 1024);
    if (mib > 0) input.value = gibText(mib);
  }

  input.addEventListener('input', () => {
    typed = true;
    setError('');
    if (!open) {
      openList();
      return;
    }
    draw();
    place();
  });
  input.addEventListener('click', openList);
  input.addEventListener('blur', () => {
    closeList();
    normalize();
  });
  input.addEventListener('keydown', (event) => {
    if (event.key === 'ArrowDown') {
      event.preventDefault();
      if (!open) openList();
      highlight(active < 0 ? 0 : active + 1);
    } else if (event.key === 'ArrowUp') {
      event.preventDefault();
      if (!open) openList();
      highlight(active < 0 ? options().length - 1 : active - 1);
    } else if (event.key === 'Enter') {
      // Only a highlighted preset takes the Enter. Anything else submits the
      // number that was typed, which is the point of a free-text field.
      if (open && active >= 0 && options()[active]) {
        event.preventDefault();
        const chosen = entries.find((entry) => String(entry.value) === options()[active].dataset.value);
        if (chosen) pick(chosen);
      }
    } else if (event.key === 'Escape') {
      if (open) {
        event.preventDefault();
        closeList();
      }
    } else if (event.key === 'Tab') {
      closeList();
    }
  });
  toggle.addEventListener('mousedown', (event) => event.preventDefault());
  toggle.addEventListener('click', () => {
    if (open) {
      closeList();
      return;
    }
    openList();
    input.focus();
  });

  return {
    input,
    setError,
    set(next, text) {
      entries = next;
      input.value = text;
      typed = false;
      closeList();
      setError('');
    },
  };
}

function vcpusEntries(limits, current) {
  const lowest = limits.min_vcpus || 1;
  const highest = limits.max_vcpus || 8;
  const entries = [];
  for (let value = lowest; value <= highest; value += 1) {
    entries.push(sizeEntry(value, `${value} vCPU${value === 1 ? '' : 's'}`, value === current ? 'now' : '', String(value)));
  }
  if (current && !entries.some((entry) => entry.value === current)) {
    entries.push(sizeEntry(current, `${current} vCPUs`, 'now', String(current)));
    entries.sort((a, b) => a.value - b.value);
  }
  return entries;
}

function memoryEntries(limits, current) {
  const lowest = limits.min_mem_mib || 128;
  const highest = limits.max_mem_mib || 16384;
  const entries = MEMORY_LADDER_MIB
    .filter((value) => value >= lowest && value <= highest)
    .map((value) => sizeEntry(value, gibLabel(value), value === current ? 'now' : '', gibText(value)));
  if (current && !entries.some((entry) => entry.value === current)) {
    entries.push(sizeEntry(current, gibLabel(current), 'now', gibText(current)));
    entries.sort((a, b) => a.value - b.value);
  }
  return entries;
}

function storageEntries(limits, current) {
  const highest = limits.max_disk_mib || 65536;
  const entries = [sizeEntry(
    0,
    current ? `Keep ${mibLabel(current)}` : 'Keep the image as it is',
    'now',
    '',
  )];
  STORAGE_LADDER_MIB
    .filter((value) => value > current && value <= highest)
    .forEach((value) => entries.push(sizeEntry(value, gibLabel(value), 'grow', gibText(value))));
  return entries;
}


function resizeButton(vm, limits) {
  const button = document.createElement('button');
  button.type = 'button';
  button.className = QUIET_BUTTON;
  button.textContent = 'Resize';
  button.addEventListener('click', () => {
    openResize(vm, limits);
  });
  return button;
}

let machinesRead = [];
let machinesManager = false;
let machinesLimits = {};
let machineFilter = '';

function machineMatches(vm, needle) {
  if (!needle) return true;
  return [workspaceLabel(vm), vm.workspace_id, vm.state, vm.last_error]
    .some((field) => String(field || '').toLowerCase().includes(needle));
}

/* The table draws what the search box left. The list is read once, so typing
   narrows it without asking the manager anything. */
function renderMachines() {
  const body = el('machines-body');
  const needle = machineFilter.trim().toLowerCase();
  const shown = machinesRead.filter((vm) => machineMatches(vm, needle));
  body.textContent = '';
  shown.forEach((vm) => {
    const row = document.createElement('tr');
    row.className = ROW;

    const name = cell(row, CELL_STRONG);
    name.textContent = workspaceLabel(vm);

    const state = cell(row, CELL_QUIET);
    state.textContent = vm.last_error ? `${vm.state}: ${vm.last_error}` : vm.state;

    const vcpus = cell(row, CELL_NUMBER);
    vcpus.textContent = vm.vcpus ? String(vm.vcpus) : 'none';

    const memory = cell(row, CELL_NUMBER);
    memory.textContent = mibLabel(vm.mem_mib);

    const storage = cell(row, CELL_NUMBER);
    storage.textContent = mibLabel(vm.disk_mib);

    const action = cell(row);
    if (machinesManager) {
      action.appendChild(resizeButton(vm, machinesLimits));
    }

    body.appendChild(row);
  });

  // A search box is only worth drawing beside a list it can narrow, and the
  // empty line has to say which kind of empty this is.
  el('machines-search').hidden = !(machinesManager && machinesRead.length > 0);
  const empty = el('machines-empty');
  if (machinesRead.length === 0) {
    empty.textContent = 'This installation runs no machines yet.';
    empty.hidden = false;
  } else if (shown.length === 0) {
    empty.textContent = `No workspace matches “${machineFilter.trim()}”.`;
    empty.hidden = false;
  } else {
    empty.hidden = true;
  }
}

function drawMachines(machines, manager, limits) {
  machinesRead = machines;
  machinesManager = manager;
  machinesLimits = limits || {};
  renderMachines();
}

/* ── what a typed size has to be, in the manager's own limits ────────────── */

function readVcpus(text, limits) {
  const lowest = limits.min_vcpus || 1;
  const highest = limits.max_vcpus || 8;
  const parsed = parseAmount(text);
  if (!parsed) return { error: 'vCPUs is a plain count, like 2.' };
  if (parsed.kind && parsed.kind !== 'vcpu') return { error: 'vCPUs is a plain count, like 2.' };
  if (!Number.isInteger(parsed.value)) return { error: 'vCPUs is a whole number, like 2.' };
  if (parsed.value < lowest || parsed.value > highest) {
    return { error: `vCPUs run from ${lowest} to ${highest}.` };
  }
  return { value: parsed.value };
}

function readMemory(text, limits) {
  const lowest = limits.min_mem_mib || 128;
  const highest = limits.max_mem_mib || 16384;
  const step = limits.mem_step_mib || 128;
  const parsed = parseAmount(text);
  if (!parsed) return { error: 'Memory is a number of GiB, like 2 or 0.5.' };
  if (parsed.kind === 'vcpu') return { error: 'Memory is a size of GiB, like 2.' };
  const mib = Math.round(parsed.kind === 'mib' ? parsed.value : parsed.value * 1024);
  if (!(mib > 0)) return { error: 'Memory is a size larger than zero.' };
  if (mib < lowest || mib > highest) {
    return { error: `Memory runs from ${gibLabel(lowest)} to ${gibLabel(highest)}.` };
  }
  // Firecracker lays the guest's memory out in 128 MiB steps and refuses
  // anything else at boot, so the field refuses it before the request leaves.
  if (mib % step !== 0) {
    const below = Math.floor(mib / step) * step;
    const above = Math.min(highest, below + step);
    return { error: `Memory goes in ${gibLabel(step)} steps: use ${gibLabel(below)} or ${gibLabel(above)}.` };
  }
  return { value: mib };
}

function readStorage(text, limits, current) {
  const lowest = limits.min_disk_mib || 128;
  const highest = limits.max_disk_mib || 65536;
  // An empty field is not a mistake: it is "leave the disk alone".
  if (!String(text == null ? '' : text).trim()) return { value: 0 };
  const parsed = parseAmount(text);
  if (!parsed) return { error: 'Storage is a number of GiB, like 8.' };
  if (parsed.kind === 'vcpu') return { error: 'Storage is a size of GiB, like 8.' };
  const mib = Math.round(parsed.kind === 'mib' ? parsed.value : parsed.value * 1024);
  if (!(mib > 0)) return { error: 'Storage is a size larger than zero, or empty to keep it.' };
  if (mib < lowest || mib > highest) {
    return { error: `Storage runs from ${gibLabel(lowest)} to ${gibLabel(highest)}.` };
  }
  if (mib <= (Number(current) || 0)) {
    return { error: `Storage only grows: this machine already has ${mibLabel(current)}.` };
  }
  return { value: mib };
}

let resizeTarget = null;
let resizeLimits = {};

function openResize(vm, limits) {
  resizeTarget = vm;
  resizeLimits = limits || {};
  el('resize-title').textContent = `Resize ${workspaceLabel(vm)}`;

  const nowCpus = Number(vm.vcpus) || 0;
  const cpus = nowCpus || resizeLimits.min_vcpus || 1;
  combos.vcpus.set(vcpusEntries(resizeLimits, nowCpus), String(cpus));

  const nowMem = Number(vm.mem_mib) || 0;
  const memory = nowMem || resizeLimits.min_mem_mib || 128;
  combos.memory.set(memoryEntries(resizeLimits, nowMem), gibText(memory));

  // Storage is the one field whose empty value means something, so its
  // placeholder is the sentence the old "Keep" option used to carry.
  const disk = Number(vm.disk_mib) || 0;
  combos.storage.set(storageEntries(resizeLimits, disk), '');
  combos.storage.input.placeholder = disk ? `Keep ${mibLabel(disk)}` : 'Keep the image as it is';

  el('resize-dialog').showModal();
}

async function submitResize(event) {
  event.preventDefault();
  const vm = resizeTarget;
  if (!vm) return;
  const label = workspaceLabel(vm);
  const checks = [
    { combo: combos.vcpus, result: readVcpus(combos.vcpus.input.value, resizeLimits) },
    { combo: combos.memory, result: readMemory(combos.memory.input.value, resizeLimits) },
    { combo: combos.storage, result: readStorage(combos.storage.input.value, resizeLimits, vm.disk_mib) },
  ];
  let firstRefused = null;
  checks.forEach(({ combo, result }) => {
    combo.setError(result.error || '');
    if (result.error && !firstRefused) firstRefused = combo;
  });
  if (firstRefused) {
    firstRefused.input.focus();
    return;
  }
  const body = {
    vcpus: checks[0].result.value,
    mem_mib: checks[1].result.value,
    disk_mib: checks[2].result.value,
  };
  const submit = el('resize-submit');
  submit.disabled = true;
  try {
    const result = await request(`${endpoints.machines}/${encodeURIComponent(vm.workspace_id)}/resize`, {
      method: 'POST',
      body,
    });
    el('resize-dialog').close();
    const ready = result.state === 'ready';
    showNotice(
      ready
        ? `${label} is back with ${result.vcpus} vCPU${result.vcpus === 1 ? '' : 's'}, ${mibLabel(result.mem_mib)} memory and ${mibLabel(result.disk_mib)} storage.`
        : `${label} did not come up: ${result.state} ${result.last_error}`,
      !ready
    );
    await loadMachines();
  } catch (error) {
    showNotice(error.message, true);
  } finally {
    submit.disabled = false;
  }
}

async function loadMachines() {
  machinesLoaded = true;
  const note = el('machines-note');
  try {
    const data = await request(endpoints.machines);
    const manager = Boolean(data.manager);
    const limits = data.limits || {};
    // The panel is a table; it only explains itself when there is something to
    // explain, because the resize dialog already says what a resize costs.
    if (manager) {
      note.hidden = true;
      note.textContent = '';
    } else {
      // The endpoint says which kind of "no manager" it is; that sentence is the
      // only thing standing between an operator and a mystery.
      note.hidden = false;
      note.textContent = data.manager_reason
        || 'No VM manager answers on this host, so there is nothing to size here.';
    }
    drawMachines(data.vms || [], manager, limits);
  } catch (error) {
    // A console served by `pabrik-admin` has no manager routes at all; any
    // other failure is worth showing instead of swallowing.
    note.hidden = false;
    note.textContent = error.status === 404
      ? 'This console has no machines to show: the endpoint is not part of this build.'
      : `These machines could not be read: ${error.message}`;
    drawMachines([], false, {});
  }
}

/* ── handing out a password ─────────────────────────────────────────────── */

function showCredential(email, password) {
  el('credential-for').textContent = email;
  el('credential-value').textContent = password;
  el('credential-panel').hidden = false;
}

function clearCredential() {
  el('credential-for').textContent = '';
  el('credential-value').textContent = '';
  el('credential-panel').hidden = true;
}

/* ── refresh and the writes ─────────────────────────────────────────────── */

async function refresh() {
  try {
    const [counts, list] = await Promise.all([
      request(endpoints.overview),
      request(endpoints.users),
    ]);
    drawCounts(counts);
    drawUsers(list.users || []);
    clearNotice();
    if (machinesLoaded) await loadMachines();
  } catch (error) {
    showNotice(error.message, true);
  }
}

async function changeUser(id, patch) {
  try {
    await request(`${endpoints.users}/${encodeURIComponent(id)}`, {
      method: 'PATCH',
      body: patch,
    });
    await refresh();
  } catch (error) {
    showNotice(error.message, true);
  }
}

async function resetPassword(user) {
  try {
    const result = await request(
      `${endpoints.users}/${encodeURIComponent(user.id)}/password`,
      { method: 'POST', body: {} }
    );
    if (result.temporary_password) {
      showCredential(user.email, result.temporary_password);
      showNotice(`A temporary password for ${user.email} is in "Handed out".`, false);
    } else {
      showNotice(`Password reset for ${user.email}.`, false);
    }
    await refresh();
  } catch (error) {
    showNotice(error.message, true);
  }
}

async function createAccount(event) {
  event.preventDefault();
  const body = {
    email: el('new-email').value.trim(),
    name: el('new-name').value.trim(),
    role: el('new-role').value,
    password: el('new-password').value,
  };
  try {
    const created = await request(endpoints.users, { method: 'POST', body });
    el('new-account-form').reset();
    el('account-dialog').close();
    goToSection('accounts');
    if (created.temporary_password) {
      showCredential(created.user.email, created.temporary_password);
    }
    await refresh();
  } catch (error) {
    showNotice(error.message, true);
  }
}

function openAccountDialog() {
  el('account-dialog').showModal();
  el('new-email').focus();
}

document.addEventListener('DOMContentLoaded', () => {
  document.querySelectorAll('.nav-item').forEach((button) => {
    button.addEventListener('click', () => goToSection(button.dataset.section));
  });
  // The three size fields: a number that is typed, and the presets beside it.
  combos.vcpus = setupCombo('resize-vcpus', 'vcpu');
  combos.memory = setupCombo('resize-memory', 'gib');
  combos.storage = setupCombo('resize-storage', 'gib');
  el('new-account-form').addEventListener('submit', createAccount);
  // Searching the machines list is a filter on what was already read, so it
  // never waits on the manager.
  el('machines-search').addEventListener('input', (event) => {
    machineFilter = event.target.value;
    renderMachines();
  });
  el('machines-search').addEventListener('keydown', (event) => {
    if (event.key !== 'Escape' || !machineFilter) return;
    event.preventDefault();
    el('machines-search').value = '';
    machineFilter = '';
    renderMachines();
  });
  el('new-account-button').addEventListener('click', openAccountDialog);
  el('account-cancel').addEventListener('click', () => el('account-dialog').close());
  el('resize-form').addEventListener('submit', submitResize);
  el('resize-cancel').addEventListener('click', () => el('resize-dialog').close());
  el('credential-clear').addEventListener('click', clearCredential);
  // A section is addressable: a pasted `/admin/machines` and the back button
  // both land on the section they name.
  window.addEventListener('popstate', () => {
    showSection(sectionFromPath());
  });
  showSection(sectionFromPath());
  refresh();
});
