'use strict';

// Admin console — talks to /api/admin/* and draws the result.

const endpoints = {
  overview: '/api/admin/overview',
  users: '/api/admin/users',
  vms: '/api/admin/vms',
};

const el = (id) => document.getElementById(id);

function showNotice(message, isError) {
  const notice = el('notice');
  notice.textContent = message;
  notice.classList.toggle('is-error', Boolean(isError));
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
    const detail = payload && payload.error ? payload.error : 'Request failed';
    const failure = new Error(detail);
    failure.status = response.status;
    throw failure;
  }
  return payload;
}

function roleLabel(role) {
  if (role === 'admin') return 'Owner';
  if (role === 'bot') return 'Bot';
  return 'User';
}

function drawCounts(counts) {
  el('count-total').textContent = String(counts.total_users);
  el('count-active').textContent = String(counts.active_users);
  el('count-owners').textContent = String(counts.admin_users);
  el('count-bots').textContent = String(counts.bot_users);
  el('count-sessions').textContent = String(counts.active_sessions);
}

function cell(row, className) {
  const td = document.createElement('td');
  if (className) td.className = className;
  row.appendChild(td);
  return td;
}

function roleSelect(user, refresh) {
  const select = document.createElement('select');
  select.className = 'role-select';
  ['user', 'admin', 'bot'].forEach((role) => {
    const option = document.createElement('option');
    option.value = role;
    option.textContent = roleLabel(role);
    if (role === user.role) option.selected = true;
    select.appendChild(option);
  });
  select.addEventListener('change', () => {
    changeUser(user.id, { role: select.value }, refresh);
  });
  return select;
}

function statusButton(user, refresh) {
  const button = document.createElement('button');
  button.type = 'button';
  button.className = user.is_active ? 'status-button' : 'status-button is-off';
  button.textContent = user.is_active ? 'Active' : 'Disabled';
  button.addEventListener('click', () => {
    changeUser(user.id, { is_active: !user.is_active }, refresh);
  });
  return button;
}

function resetButton(user, refresh) {
  const button = document.createElement('button');
  button.type = 'button';
  button.className = 'button';
  button.textContent = 'Reset password';
  button.addEventListener('click', () => {
    resetPassword(user, refresh);
  });
  return button;
}

function drawUsers(users) {
  const body = el('accounts-body');
  body.textContent = '';
  users.forEach((user) => {
    const row = document.createElement('tr');

    const email = cell(row, 'account-email');
    email.textContent = user.email;

    const name = cell(row, 'account-name');
    name.textContent = user.name || 'No name';

    const role = cell(row);
    role.appendChild(roleSelect(user, refresh));

    const status = cell(row);
    status.appendChild(statusButton(user, refresh));

    const actions = cell(row);
    actions.appendChild(resetButton(user, refresh));

    body.appendChild(row);
  });
  el('accounts-empty').hidden = users.length !== 0;
}

function numberInput(id, value, min, max) {
  const input = document.createElement('input');
  input.type = 'number';
  input.className = 'vm-input';
  input.value = String(value);
  input.min = String(min);
  input.max = String(max);
  input.id = id;
  return input;
}

function drawVms(vms, manager, limits) {
  const body = el('vms-body');
  body.textContent = '';
  vms.forEach((vm) => {
    const row = document.createElement('tr');

    const name = cell(row, 'account-email');
    name.textContent = vm.workspace_name || vm.workspace_id;

    const state = cell(row, 'vm-state');
    state.textContent = vm.last_error ? `${vm.state}: ${vm.last_error}` : vm.state;

    const size = cell(row);
    size.textContent = vm.vcpus ? `${vm.vcpus} vCPU / ${vm.mem_mib} MiB` : 'not running';

    const action = cell(row);
    if (manager) {
      const form = document.createElement('div');
      form.className = 'vm-form';
      const vcpus = numberInput('', vm.vcpus || limits.min_vcpus, limits.min_vcpus, limits.max_vcpus);
      const mem = numberInput('', vm.mem_mib || limits.min_mem_mib, limits.min_mem_mib, limits.max_mem_mib);
      const button = document.createElement('button');
      button.type = 'button';
      button.className = 'button';
      button.textContent = 'Restart with this size';
      button.addEventListener('click', () => {
        resizeVm(vm, Number(vcpus.value), Number(mem.value));
      });
      form.append(vcpus, mem, button);
      action.appendChild(form);
    }

    body.appendChild(row);
  });
  el('vms-empty').hidden = vms.length !== 0;
}

async function loadVms() {
  const panel = el('vms-panel');
  try {
    const data = await request(endpoints.vms);
    panel.hidden = false;
    el('vms-manager').textContent = data.manager
      ? 'Changing vCPUs or memory restarts that workspace\'s VM: the guest comes back in a few seconds, the processes inside it do not.'
      : 'No VM manager answered on this host, so there is nothing to size here.';
    drawVms(data.vms || [], Boolean(data.manager), data.limits || { min_vcpus: 1, max_vcpus: 8, min_mem_mib: 128, max_mem_mib: 16384 });
  } catch (error) {
    // A console served by `pabrik-admin` has no manager routes at all.
    panel.hidden = true;
  }
}

async function resizeVm(vm, vcpus, mem_mib) {
  const label = vm.workspace_name || vm.workspace_id;
  try {
    const result = await request(`${endpoints.vms}/${encodeURIComponent(vm.workspace_id)}/resize`, {
      method: 'POST',
      body: { vcpus: vcpus, mem_mib: mem_mib },
    });
    const ready = result.state === 'ready';
    showNotice(
      ready
        ? `${label} is back with ${result.vcpus} vCPU / ${result.mem_mib} MiB.`
        : `${label} did not come up: ${result.state} ${result.last_error}`,
      !ready
    );
    await loadVms();
  } catch (error) {
    showNotice(error.message, true);
  }
}

function showCredential(email, password) {
  el('credential-for').textContent = email;
  el('credential-value').textContent = password;
  el('credential-line').hidden = false;
  el('credential-empty').hidden = true;
}

function clearCredential() {
  el('credential-for').textContent = '';
  el('credential-value').textContent = '';
  el('credential-line').hidden = true;
  el('credential-empty').hidden = false;
}

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

async function changeUser(id, patch, done) {
  try {
    await request(`${endpoints.users}/${encodeURIComponent(id)}`, {
      method: 'PATCH',
      body: patch,
    });
    await done();
  } catch (error) {
    showNotice(error.message, true);
  }
}

async function resetPassword(user, done) {
  try {
    const result = await request(
      `${endpoints.users}/${encodeURIComponent(user.id)}/password`,
      { method: 'POST', body: {} }
    );
    if (result.temporary_password) {
      showCredential(user.email, result.temporary_password);
    } else {
      showNotice(`Password reset for ${user.email}.`, false);
    }
    await done();
  } catch (error) {
    showNotice(error.message, true);
  }
}

function createAccount(event) {
  event.preventDefault();
  const form = event.target;
  const body = {
    email: el('new-email').value.trim(),
    name: el('new-name').value.trim(),
    role: el('new-role').value,
    password: el('new-password').value,
  };
  request(endpoints.users, { method: 'POST', body: body })
    .then((created) => {
      form.reset();
      if (created.temporary_password) {
        showCredential(created.user.email, created.temporary_password);
      }
      return refresh();
    })
    .catch((error) => showNotice(error.message, true));
}

function scrollToForm() {
  el('new-account-panel').scrollIntoView({ behavior: 'smooth', block: 'start' });
  el('new-email').focus();
}

document.addEventListener('DOMContentLoaded', () => {
  el('new-account-form').addEventListener('submit', createAccount);
  el('new-account-button').addEventListener('click', scrollToForm);
  el('credential-clear').addEventListener('click', clearCredential);
  refresh();
});
