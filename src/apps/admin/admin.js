'use strict';

// Admin console — talks to /api/admin/* and draws the result.

const endpoints = {
  overview: '/api/admin/overview',
  users: '/api/admin/users',
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
