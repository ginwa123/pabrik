'use strict';

// The console's whole client: no framework, no build step.

const endpoints = {
  overview: '/api/admin/overview',
  users: '/api/admin/users',
  vms: '/api/admin/vms',
};

const MEMORY_LADDER_MIB = [256, 384, 512, 768, 1024, 1536, 2048, 3072, 4096, 6144, 8192, 12288, 16384];
const STORAGE_LADDER_MIB = [256, 512, 1024, 2048, 4096, 8192, 16384, 32768, 65536];

const CELL = 'border-b border-surface-up px-3 py-3 align-middle'; // taste-skill-ignore: real table rows
const CELL_STRONG = `${CELL} font-medium text-cream`;
const CELL_QUIET = `${CELL} text-ink-muted`;
const CELL_NUMBER = `${CELL} tabular-nums`;
const ROW = 'animate-rise motion-reduce:animate-none';
const QUIET_BUTTON = 'rounded-card px-3 py-1.5 text-link transition-colors hover:bg-surface-up';

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

function fillSelect(select, entries, selected) {
  select.textContent = '';
  entries.forEach((entry) => {
    const option = document.createElement('option');
    option.value = String(entry.value);
    option.textContent = entry.label;
    if (String(entry.value) === String(selected)) option.selected = true;
    select.appendChild(option);
  });
}

function vcpusEntries(limits, current) {
  const lowest = limits.min_vcpus || 1;
  const highest = limits.max_vcpus || 8;
  const entries = [];
  for (let value = lowest; value <= highest; value += 1) {
    entries.push({ value, label: `${value} vCPU${value === 1 ? '' : 's'}` });
  }
  if (current && !entries.some((entry) => entry.value === current)) {
    entries.push({ value: current, label: `${current} vCPUs` });
  }
  return entries;
}

function memoryEntries(limits, current) {
  const lowest = limits.min_mem_mib || 128;
  const highest = limits.max_mem_mib || 16384;
  const entries = MEMORY_LADDER_MIB
    .filter((value) => value >= lowest && value <= highest)
    .map((value) => ({ value, label: mibLabel(value) }));
  if (current && !entries.some((entry) => entry.value === current)) {
    entries.push({ value: current, label: mibLabel(current) });
    entries.sort((a, b) => a.value - b.value);
  }
  return entries;
}

function storageEntries(limits, current) {
  const highest = limits.max_disk_mib || 65536;
  const entries = [{
    value: 0,
    label: current ? `Keep ${mibLabel(current)}` : 'Keep the image as it is',
  }];
  STORAGE_LADDER_MIB
    .filter((value) => value > current && value <= highest)
    .forEach((value) => entries.push({ value, label: `${mibLabel(value)} (grow)` }));
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

function drawVms(vms, manager, limits) {
  const body = el('vms-body');
  body.textContent = '';
  vms.forEach((vm) => {
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
    if (manager) {
      action.appendChild(resizeButton(vm, limits));
    }

    body.appendChild(row);
  });
  el('vms-empty').hidden = vms.length !== 0;
}

let resizeTarget = null;

function openResize(vm, limits) {
  resizeTarget = vm;
  el('resize-title').textContent = `Resize ${workspaceLabel(vm)}`;
  fillSelect(el('resize-vcpus'), vcpusEntries(limits, vm.vcpus), vm.vcpus || limits.min_vcpus);
  fillSelect(el('resize-memory'), memoryEntries(limits, vm.mem_mib), vm.mem_mib);
  fillSelect(el('resize-storage'), storageEntries(limits, vm.disk_mib), 0);
  el('resize-dialog').showModal();
}

async function submitResize(event) {
  event.preventDefault();
  const vm = resizeTarget;
  if (!vm) return;
  const label = workspaceLabel(vm);
  const body = {
    vcpus: Number(el('resize-vcpus').value),
    mem_mib: Number(el('resize-memory').value),
    disk_mib: Number(el('resize-storage').value),
  };
  const submit = el('resize-submit');
  submit.disabled = true;
  try {
    const result = await request(`${endpoints.vms}/${encodeURIComponent(vm.workspace_id)}/resize`, {
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
    await loadVms();
  } catch (error) {
    showNotice(error.message, true);
  } finally {
    submit.disabled = false;
  }
}

async function loadVms() {
  const panel = el('vms-panel');
  try {
    const data = await request(endpoints.vms);
    panel.hidden = false;
    const manager = Boolean(data.manager);
    const limits = data.limits || {};
    el('vms-note').textContent = manager
      ? 'A resize restarts that workspace: the machine comes back in a few seconds, the processes inside it do not. Storage only grows.'
      : 'No VM manager answers on this host, so there is nothing to size here. Start pabrik with the manager and reload.';
    drawVms(data.vms || [], manager, limits);
  } catch (error) {
    // A console served by `pabrik-admin` has no manager routes at all; any
    // other failure is worth showing instead of swallowing.
    if (error.status === 404) {
      panel.hidden = true;
      return;
    }
    panel.hidden = false;
    el('vms-note').textContent = `This panel could not be read: ${error.message}`;
    drawVms([], false, {});
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
    await loadVms();
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
    if (created.temporary_password) {
      showCredential(created.user.email, created.temporary_password);
    }
    await refresh();
  } catch (error) {
    showNotice(error.message, true);
  }
}

function focusNewAccount() {
  el('new-email').focus();
  el('new-email').scrollIntoView({ behavior: 'smooth', block: 'center' });
}

document.addEventListener('DOMContentLoaded', () => {
  el('new-account-form').addEventListener('submit', createAccount);
  el('new-account-button').addEventListener('click', focusNewAccount);
  el('resize-form').addEventListener('submit', submitResize);
  el('resize-cancel').addEventListener('click', () => el('resize-dialog').close());
  el('credential-clear').addEventListener('click', clearCredential);
  refresh();
});
