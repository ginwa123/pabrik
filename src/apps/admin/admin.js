'use strict';

// The console's whole client. The page arrives rendered, so this file does only
// what a page cannot: the resize dialog, the search over the rows it was sent,
// and the writes. Every write ends in a reload — post/redirect/get, with
// sessionStorage standing in for the message cookie there is no session for.

const endpoints = {
  users: '/api/admin/users',
  machines: '/api/admin/vms',
};

const MEMORY_LADDER_MIB = [256, 384, 512, 768, 1024, 1536, 2048, 3072, 4096, 6144, 8192, 12288, 16384];
const STORAGE_LADDER_MIB = [256, 512, 1024, 2048, 4096, 8192, 16384, 32768, 65536];

const el = (id) => document.getElementById(id);

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

function roleLabel(role) {
  if (role === 'admin') return 'Owner';
  if (role === 'bot') return 'Bot';
  return 'User';
}

/* ── what a write says on the page it reloads ───────────────────────────── */

const FLASH_KEY = 'pabrik.admin.flash';

/// The message (and maybe a password) the next page shows, once.
function flash(next) {
  try {
    window.sessionStorage.setItem(FLASH_KEY, JSON.stringify(next));
  } catch (error) {
    // Private mode refuses storage. The write still stands; it just arrives
    // without a sentence to explain it.
  }
}

function drawFlash() {
  let raw = null;
  try {
    raw = window.sessionStorage.getItem(FLASH_KEY);
    if (raw) window.sessionStorage.removeItem(FLASH_KEY);
  } catch (error) {
    return;
  }
  if (!raw) return;
  let saved = null;
  try {
    saved = JSON.parse(raw);
  } catch (error) {
    return;
  }
  if (!saved) return;
  if (saved.notice) showNotice(saved.notice, Boolean(saved.error));
  if (saved.email && saved.password) showCredential(saved.email, saved.password);
}

/// Send one write. A success reloads, and the server draws the new state; a
/// refusal stays where it is and says why, so the dialog keeps what was typed.
async function write(path, options, message) {
  try {
    const result = await request(path, options);
    flash(message(result));
    window.location.reload();
  } catch (error) {
    showNotice(error.message, true);
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

/// The account a row is about. The row is the server's, so its first cell holds
/// the address the message should name.
function rowEmail(node) {
  const row = node.closest('tr');
  const first = row ? row.children[0] : null;
  return first ? first.textContent.trim() : '';
}

/* ── the size fields: a number you type, and the presets worth trying ───── */

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

/* ── the resize dialog ──────────────────────────────────────────────────── */

/// The limits the page carries as its own JSON, so the dialog can refuse a size
/// the manager would refuse without asking anybody.
function pageLimits() {
  const node = el('resize-limits');
  if (!node) return {};
  try {
    return JSON.parse(node.textContent) || {};
  } catch (error) {
    return {};
  }
}

let resizeTarget = null;
let resizeLimits = {};

/// The row's Resize button carries the machine's size, so opening the dialog
/// reads the document rather than the manager.
function openResize(button) {
  const vm = {
    id: button.dataset.workspace,
    name: button.dataset.name,
    vcpus: Number(button.dataset.vcpus) || 0,
    mem_mib: Number(button.dataset.memMib) || 0,
    disk_mib: Number(button.dataset.diskMib) || 0,
  };
  resizeTarget = vm;
  resizeLimits = pageLimits();
  el('resize-title').textContent = `Resize ${vm.name}`;

  const cpus = vm.vcpus || resizeLimits.min_vcpus || 1;
  combos.vcpus.set(vcpusEntries(resizeLimits, vm.vcpus), String(cpus));

  const memory = vm.mem_mib || resizeLimits.min_mem_mib || 128;
  combos.memory.set(memoryEntries(resizeLimits, vm.mem_mib), gibText(memory));

  // Storage is the one field whose empty value means something, so its
  // placeholder is the sentence a "Keep" option used to carry.
  combos.storage.set(storageEntries(resizeLimits, vm.disk_mib), '');
  combos.storage.input.placeholder = vm.disk_mib ? `Keep ${mibLabel(vm.disk_mib)}` : 'Keep the image as it is';

  el('resize-dialog').showModal();
}

async function submitResize(event) {
  event.preventDefault();
  const vm = resizeTarget;
  if (!vm) return;
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

  const submit = el('resize-submit');
  submit.disabled = true;
  try {
    const result = await request(`${endpoints.machines}/${encodeURIComponent(vm.id)}/resize`, {
      method: 'POST',
      body: {
        vcpus: checks[0].result.value,
        mem_mib: checks[1].result.value,
        disk_mib: checks[2].result.value,
      },
    });
    const ready = result.state === 'ready';
    flash({
      notice: ready
        ? `${vm.name} is back with ${result.vcpus} vCPU${result.vcpus === 1 ? '' : 's'}, ${mibLabel(result.mem_mib)} memory and ${mibLabel(result.disk_mib)} storage.`
        : `${vm.name} did not come up: ${result.state} ${result.last_error}`,
      error: !ready,
    });
    window.location.reload();
  } catch (error) {
    showNotice(error.message, true);
    submit.disabled = false;
  }
}

/* ── the two tables, and the one dialog that adds a row ─────────────────── */

/// One listener per table, on the element: the rows are the server's markup, so
/// nothing has to be re-bound when the page is drawn again.
function wireAccounts() {
  const body = el('accounts-body');
  if (!body) return;

  body.addEventListener('change', (event) => {
    const select = event.target.closest('[data-action="role"]');
    if (!select) return;
    const email = rowEmail(select);
    const role = roleLabel(select.value);
    write(`${endpoints.users}/${encodeURIComponent(select.dataset.userId)}`, {
      method: 'PATCH',
      body: { role: select.value },
    }, () => ({ notice: `${email} is now ${role}.` }));
  });

  body.addEventListener('click', (event) => {
    const button = event.target.closest('[data-action]');
    if (!button) return;
    const email = rowEmail(button);
    const id = encodeURIComponent(button.dataset.userId);

    if (button.dataset.action === 'toggle-active') {
      const signingIn = button.textContent.trim() === 'Disabled';
      write(`${endpoints.users}/${id}`, {
        method: 'PATCH',
        body: { is_active: signingIn },
      }, () => ({ notice: `${email} ${signingIn ? 'may sign in again' : 'may no longer sign in'}.` }));
    } else if (button.dataset.action === 'reset-password') {
      write(`${endpoints.users}/${id}/password`, { method: 'POST', body: {} }, (result) => ({
        notice: result.temporary_password
          ? `A temporary password for ${email} is in "Handed out".`
          : `Password reset for ${email}.`,
        email,
        password: result.temporary_password || '',
      }));
    }
  });
}

function wireMachines() {
  const body = el('machines-body');
  if (body) {
    body.addEventListener('click', (event) => {
      const button = event.target.closest('[data-action="resize"]');
      if (button) openResize(button);
    });
  }

  const input = el('machines-search');
  if (!input || !body) return;
  const rows = Array.from(body.querySelectorAll('tr'));
  const empty = el('machines-empty');

  const apply = () => {
    const needle = input.value.trim().toLowerCase();
    let shown = 0;
    rows.forEach((row) => {
      const match = !needle || row.textContent.toLowerCase().includes(needle);
      row.hidden = !match;
      if (match) shown += 1;
    });
    if (!empty) return;
    if (rows.length === 0) {
      empty.textContent = 'This installation runs no machines yet.';
      empty.hidden = false;
    } else if (shown === 0) {
      empty.textContent = `No workspace matches “${input.value.trim()}”.`;
      empty.hidden = false;
    } else {
      empty.hidden = true;
    }
  };

  input.addEventListener('input', apply);
  input.addEventListener('keydown', (event) => {
    if (event.key !== 'Escape' || !input.value) return;
    event.preventDefault();
    input.value = '';
    apply();
  });
}

/// The dialog is in the shell, but the button that opens it belongs to the
/// accounts section — which is not on the machines page, so its absence is
/// ordinary rather than a fault.
function wireAccountDialog() {
  const form = el('new-account-form');
  if (!form) return;

  form.addEventListener('submit', (event) => {
    event.preventDefault();
    const email = el('new-email').value.trim();
    write(endpoints.users, {
      method: 'POST',
      body: {
        email,
        name: el('new-name').value.trim(),
        role: el('new-role').value,
        password: el('new-password').value,
      },
    }, (created) => ({
      notice: created.temporary_password
        ? `A temporary password for ${email} is in "Handed out".`
        : `${email} was created.`,
      email,
      password: created.temporary_password || '',
    }));
  });

  const button = el('new-account-button');
  if (button) {
    button.addEventListener('click', () => {
      el('account-dialog').showModal();
      el('new-email').focus();
    });
  }

  const cancel = el('account-cancel');
  if (cancel) cancel.addEventListener('click', () => el('account-dialog').close());
}

document.addEventListener('DOMContentLoaded', () => {
  combos.vcpus = setupCombo('resize-vcpus', 'vcpu');
  combos.memory = setupCombo('resize-memory', 'gib');
  combos.storage = setupCombo('resize-storage', 'gib');
  el('resize-form').addEventListener('submit', submitResize);
  el('resize-cancel').addEventListener('click', () => el('resize-dialog').close());
  el('credential-clear').addEventListener('click', clearCredential);

  drawFlash();
  wireAccounts();
  wireMachines();
  wireAccountDialog();
});
