/* Zapret Control · Keenetic — frontend */
(() => {
'use strict';

const $ = (id) => document.getElementById(id);
const state = {
  busy: false,
  status: null,
  jobRunning: false,
  readonly: false,
  configs: [],
  selected: new Set(),
  selectedInit: false,
  source: 'all',
  sites: { testing: false, defs: [], results: [], timer: null },
  auto: { running: false, polling: false, timer: null, results: [], done: null },
};

const esc = (v) => String(v ?? '').replace(/[&<>"']/g, (c) => ({
  '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
}[c]));

const parse = (text) => String(text).replace(/\r/g, '').split('\n')
  .filter((l) => l.length > 0).map((l) => l.split('|'));

async function api(action, params = {}, options = {}) {
  const q = new URLSearchParams(params);
  q.set('_', Date.now());
  const res = await fetch(`/control.cgi?${action}&${q.toString()}`, {
    cache: 'no-store',
    ...options,
  });
  const text = await res.text();
  if (!res.ok) throw new Error(text || `HTTP ${res.status}`);
  return text;
}

function toast(message, type = 'info') {
  const box = $('toasts');
  const el = document.createElement('div');
  el.className = `toast ${type}`;
  el.textContent = message;
  box.appendChild(el);
  setTimeout(() => el.remove(), 4200);
}

const sourceClass = (s) => s === 'Flowseal' ? 'badge-flowseal'
  : s === 'Bol-van' ? 'badge-bolvan' : 'badge-user';

const modeLabel = (m) => m === 'all' ? 'весь трафик'
  : m === 'list' ? 'user.list' : 'свой режим';

function refreshButtons() {
  const busy = state.busy || state.auto.running || state.sites.testing;
  document.querySelectorAll('#btnAuto, #btnTestSites, .config-actions button, #btnRestart, #btnStop, #btnStart, #btnRestore, #resultModalApply, #resultsBody button')
    .forEach((b) => { b.disabled = busy; });
  if (state.readonly) {
    document.querySelectorAll('#btnAuto, #btnRestart, #btnStop, #btnStart, #btnRestore, [data-act="apply"], [data-act="apply-test"], [data-save], #resultModalApply, [data-auto-apply]')
      .forEach((b) => { b.disabled = true; });
  }
  $('btnAuto').disabled = state.readonly || state.busy || state.auto.running;
  $('btnTestSites').disabled = state.busy || state.auto.running || state.sites.testing;
  $('btnCancelAuto').hidden = !state.auto.running;
}

/* ------------------------------------------------------------------ status */
async function loadStatus() {
  try {
    const rows = parse(await api('get_status'));
    const r = rows.find((x) => x[0] === 'STATUS');
    if (!r) throw new Error('нет ответа');
    const [, status, init, conf, name, mode, pid, job, ro] = r;
    state.status = status;
    state.jobRunning = job === '1';
    state.readonly = ro === '1';
    const roBadge = $('roBadge');
    if (roBadge) roBadge.hidden = !state.readonly;

    const online = status === 'RUNNING';
    const installed = status !== 'NOT_INSTALLED';
    const top = $('topStatus');
    top.className = `top-status ${online ? 'online' : installed ? 'offline' : 'unknown'}`;
    $('topStatusText').textContent = online ? 'Активен' : installed ? 'Остановлен' : 'Не установлен';

    const ring = $('statusRing');
    ring.className = `status-ring ${online ? 'online' : 'offline'}`;
    $('statusTitle').textContent = online ? 'Zapret активен' : installed ? 'Zapret остановлен' : 'Zapret не найден';
    $('statusSub').textContent = online ? 'nfqws обрабатывает трафик'
      : installed ? 'Служба установлена, но не запущена' : 'Не найден init-скрипт nfqws';

    $('currentConfig').textContent = name || '—';
    $('currentMode').textContent = mode === 'all' ? 'Весь трафик'
      : mode === 'list' ? 'Только user.list' : mode === 'custom' ? 'Свой' : '—';
    $('currentPid').textContent = pid || '—';
    $('currentConf').textContent = conf || '—';
    refreshButtons();
  } catch (e) {
    $('topStatus').className = 'top-status offline';
    $('topStatusText').textContent = 'Нет связи';
    $('statusTitle').textContent = 'Ошибка связи';
    $('statusSub').textContent = e.message;
  }
}

/* ----------------------------------------------------------------- configs */
async function loadConfigs(force = false) {
  try {
    const rows = parse(await api('get_configs', force ? { refresh: 1 } : {}));
    const info = rows.find((r) => r[0] === 'INFO') || [];
    state.configs = rows.filter((r) => r[0] === 'CFG').map((r) => ({
      id: r[1], source: r[2], name: r[3], tcp: r[4] || '', quic: r[5] || '', cur: r[6] === '1',
    }));

    const ids = new Set(state.configs.map((c) => c.id));
    if (!state.selectedInit) {
      state.configs.forEach((c) => state.selected.add(c.id));
      state.selectedInit = true;
    } else {
      [...state.selected].forEach((id) => { if (!ids.has(id)) state.selected.delete(id); });
    }

    $('configsHint').textContent = `${state.configs.length} конфигураций · ${info[3] && info[3] !== '-' ? 'flowseal найден' : 'flowseal не найден'}`;
    renderConfigs();
    updateSelected();
  } catch (e) {
    $('configList').innerHTML = `<div class="empty">Ошибка загрузки: ${esc(e.message)}</div>`;
  }
}

function renderConfigs() {
  const list = state.configs.filter((c) => state.source === 'all' || c.source === state.source);
  if (!list.length) {
    $('configList').innerHTML = '<div class="empty">В этой группе нет конфигураций</div>';
    return;
  }
  $('configList').innerHTML = list.map((c) => {
    const checked = state.selected.has(c.id) ? 'checked' : '';
    const current = c.cur ? '<span class="badge badge-current">текущий</span>' : '';
    const quic = c.quic ? '<span class="badge badge-soft">QUIC</span>' : '';
    return `<article class="config ${c.cur ? 'current' : ''}" data-id="${esc(c.id)}">
      <div class="config-top">
        <label class="check" title="Участвует в подборе"><input type="checkbox" class="cfg-check" data-id="${esc(c.id)}" ${checked}></label>
        <div class="config-title"><b title="${esc(c.name)}">${esc(c.name)}</b>
          <span class="badge ${sourceClass(c.source)}">${esc(c.source)}</span>${current}${quic}
        </div>
      </div>
      <code class="args" title="${esc(c.tcp)}">${esc(c.tcp || '—')}</code>
      <div class="config-actions">
        <button type="button" class="btn btn-sm btn-primary" data-act="apply-test">Применить и проверить</button>
        <button type="button" class="btn btn-sm btn-ghost" data-act="apply">Применить</button>
        ${c.cur ? '<button type="button" class="btn btn-sm btn-ghost" data-act="test">Проверить сайты</button>' : ''}
      </div>
    </article>`;
  }).join('');
  refreshButtons();
}

function updateSelected() {
  const total = state.configs.length;
  $('selectedCount').textContent = `${state.selected.size} выбрано`;
  $('selectAll').checked = total > 0 && state.selected.size === total;
  $('selectAll').indeterminate = state.selected.size > 0 && state.selected.size < total;
}

async function applyConfig(id, testAfter) {
  if (state.busy || state.auto.running) return;
  if (state.readonly) { toast('Панель в режиме только чтения', 'err'); return; }
  const cfg = state.configs.find((c) => c.id === id);
  const label = cfg ? cfg.name : id;
  const msg = `Применить конфигурацию «${label}»?` +
    (testAfter ? '\n\nПосле применения будут проверены сайты.' : '') +
    '\n\nzapret будет перезапущен. Текущий конфиг сохранится в .zm2k.bak.';
  if (!confirm(msg)) return;
  state.busy = true;
  refreshButtons();
  toast('Применяю конфигурацию…', 'info');
  try {
    const rows = parse(await api('apply_config', { id, mode: $('finalMode').value }));
    const r = rows[0] || ['ERROR'];
    if (r[0] === 'OK') {
      toast(`Конфигурация применена (${modeLabel(r[3])})`, 'ok');
      await Promise.all([loadStatus(), loadConfigs()]);
      if (testAfter) await runSiteTests();
    } else if (r[0] === 'BUSY') {
      toast(r[1] || 'Сейчас выполняется другая операция', 'err');
    } else {
      toast(r.slice(1).join('|') || 'Не удалось применить конфигурацию', 'err');
    }
  } catch (e) {
    toast(`Ошибка: ${e.message}`, 'err');
  } finally {
    state.busy = false;
    refreshButtons();
  }
}

/* --------------------------------------------------------------- site tests */
function siteUrl(name) {
  const d = state.sites.defs.find((s) => s.name === name);
  return d ? d.url : '';
}

async function loadSiteDefs() {
  try {
    const text = await fetch(`sites.list?_=${Date.now()}`).then((r) => r.text());
    state.sites.defs = text.replace(/\r/g, '').split('\n')
      .filter((l) => l.trim() && !l.trim().startsWith('#'))
      .map((l) => {
        const [name, url, weight] = l.split('|');
        return { name: (name || '').trim(), url: (url || '').trim(), weight: parseInt(weight, 10) || 1 };
      }).filter((s) => s.name && s.url);
    if (!state.sites.testing && !state.sites.results.length) renderSitesIdle();
  } catch (e) {
    if (!state.sites.testing && !state.sites.results.length) {
      $('siteGrid').innerHTML = '<div class="empty">Не удалось загрузить sites.list</div>';
    }
  }
}

function siteCard(r) {
  const ok = !!r.ok;
  const code = r.code && r.code !== '000' ? r.code : '';
  const sub = ok ? `${code || 200} · ${r.ms || 0} мс` : (code ? `${code} · ${r.ms || 0} мс` : 'недоступен');
  const url = siteUrl(r.name);
  const title = r.err ? `${r.name} — ${r.err}` : (url || r.name);
  return `<div class="site ${ok ? 'ok' : 'fail'}" title="${esc(title)}">
    <span class="sdot"></span>
    <div><b>${esc(r.name)}</b><small>${esc(sub)}</small></div>
    <span class="smark">${ok ? '✓' : '✕'}</span>
  </div>`;
}

function siteGroup(title, list, cls, pending) {
  if (!list.length) return '';
  const cards = list.map((s) => pending
    ? `<div class="site wait"><span class="sdot"></span><div><b>${esc(s.name)}</b><small>проверка…</small></div></div>`
    : siteCard(s)).join('');
  return `<div class="site-group">
    <div class="site-group-head ${cls}"><span>${title}</span><b>${list.length}</b></div>
    <div class="site-grid">${cards}</div>
  </div>`;
}

function renderSitesIdle() {
  const defs = state.sites.defs;
  if (!defs.length) {
    $('siteGrid').innerHTML = '<div class="empty">Список сайтов пуст</div>';
    return;
  }
  $('siteGrid').innerHTML = `<div class="site-group">
    <div class="site-group-head"><span>Сайты для проверки</span><b>${defs.length}</b></div>
    <div class="site-grid">${defs.map((s) => `<div class="site" title="${esc(s.url)}"><span class="sdot"></span>
      <div><b>${esc(s.name)}</b><small>не проверялся</small></div></div>`).join('')}</div>
  </div>`;
  $('sitesSummary').textContent = 'Проверка ещё не запускалась — нажмите «Проверить».';
}

function renderSitesTesting() {
  const defs = state.sites.defs;
  $('siteGrid').innerHTML = defs.length
    ? `<div class="site-group">
        <div class="site-group-head"><span>Проверяются</span><b>${defs.length}</b></div>
        <div class="site-grid">${defs.map((s) => `<div class="site wait"><span class="sdot"></span>
          <div><b>${esc(s.name)}</b><small>проверка…</small></div></div>`).join('')}</div>
      </div>`
    : '<div class="empty">Проверка…</div>';
  $('sitesSummary').textContent = 'Проверка доступности…';
}

function renderSites(results, elapsed) {
  if (!results.length) {
    $('siteGrid').innerHTML = '<div class="empty">Проверка не вернула результатов</div>';
    $('sitesSummary').textContent = 'Нет результатов проверки';
    return;
  }
  const ok = results.filter((r) => r.ok);
  const fail = results.filter((r) => !r.ok);
  const score = ok.reduce((a, r) => a + (parseInt(r.weight, 10) || 1), 0);
  const maxScore = results.reduce((a, r) => a + (parseInt(r.weight, 10) || 1), 0);
  $('siteGrid').innerHTML =
    siteGroup('Работают', ok, 'ok', false) +
    siteGroup('Не работают', fail, 'fail', false);
  $('sitesSummary').innerHTML = `<b>${ok.length}/${results.length}</b> сайтов работают · счёт ${score}/${maxScore}${elapsed ? ` · ${esc(elapsed)} с` : ''}`;
}

async function runSiteTests() {
  if (state.sites.testing || state.auto.running) return;
  state.sites.testing = true;
  refreshButtons();
  renderSitesTesting();
  const started = Date.now();
  state.sites.timer = setInterval(() => {
    $('sitesSummary').textContent = `Проверка доступности… ${Math.round((Date.now() - started) / 1000)} с`;
  }, 500);
  try {
    const text = await api('test_sites');
    const rows = parse(text);
    const busy = rows.find((r) => r[0] === 'BUSY');
    if (busy) {
      toast(busy[1] || 'Занято', 'err');
      if (state.sites.results.length) renderSites(state.sites.results);
      else renderSitesIdle();
      return;
    }
    const errRow = rows.find((r) => r[0] === 'ERROR');
    if (errRow) throw new Error(errRow.slice(1).join('|') || 'ошибка проверки');
    const modeRow = rows.find((r) => r[0] === 'MODE');
    const results = rows.filter((r) => r[0] === 'SITE').map((r) => ({
      name: r[1], ok: r[2] === '1', code: r[3], ms: r[4], size: r[5],
      weight: r[6], err: r.slice(7).join('|'),
    }));
    const end = rows.find((r) => r[0] === 'TEST' && r[1] === 'end');
    state.sites.results = results;
    renderSites(results, end && end[2]);
    const passed = results.filter((r) => r.ok).length;
    if (modeRow && modeRow[1] === 'list') {
      toast('Режим user.list: сайты вне списка могут быть недоступны', 'info');
    }
    toast(results.length
      ? (passed === results.length ? 'Все сайты доступны' : `Доступно ${passed} из ${results.length}`)
      : 'Проверка не вернула результатов',
      results.length && passed === results.length ? 'ok' : 'err');
  } catch (e) {
    $('sitesSummary').textContent = `Ошибка проверки: ${e.message}`;
    $('siteGrid').innerHTML = `<div class="empty">${esc(e.message)}</div>`;
    toast(`Ошибка проверки: ${e.message}`, 'err');
  } finally {
    clearInterval(state.sites.timer);
    state.sites.timer = null;
    state.sites.testing = false;
    refreshButtons();
  }
}

/* ----------------------------------------------------------------- autotest */
const phaseLabel = (p) => ({
  init: 'Подготовка…', apply: 'Применяю конфигурацию…', test: 'Проверяю сайты…',
  'apply-best': 'Применяю лучший конфиг…', restore: 'Возвращаю исходный конфиг…',
  finished: 'Готово', cancelled: 'Отменено', idle: 'Ожидание',
}[p] || p || 'Работа…');

function updateAutoProgress(job) {
  const stage = job[1] || 'init';
  const idx = parseInt(job[2], 10) || 0;
  const total = parseInt(job[3], 10) || 0;
  const phase = job[4] || 'init';
  const name = job[7] || '';
  const src = job[6] || '';
  const pct = total ? Math.min(100, Math.round((idx / total) * 100)) : 0;

  $('autoProgressWrap').hidden = false;
  $('autoBar').style.width = `${pct}%`;
  $('autoCounter').textContent = `${idx} / ${total}`;
  $('autoPhase').textContent = phaseLabel(phase);
  $('autoCurrent').innerHTML = name
    ? `<b>${esc(name)}</b> <span class="badge ${sourceClass(src)}">${esc(src)}</span>`
    : '';
  $('autoBadge').textContent = stage === 'running' ? 'идёт подбор' : stage;
  $('autoBadge').className = `badge ${stage === 'running' ? 'badge-soft' : 'badge-soft'}`;
}

function renderMiniSites(sites) {
  const box = $('autoSites');
  if (!sites.length) { box.innerHTML = ''; return; }
  const uniq = new Map();
  sites.forEach((s) => uniq.set(s.name, s));
  box.innerHTML = [...uniq.values()].slice(0, 16).map((s) => {
    const cls = s.ok ? 'ok' : 'fail';
    return `<span class="${cls}" title="${esc(s.err || '')}">${s.ok ? '✓' : '✕'} ${esc(s.name)}</span>`;
  }).join('');
}

function cmpResults(a, b) {
  return (b.score - a.score) || (b.passed - a.passed) || (a.avg - b.avg);
}

function renderResults(results) {
  if (!results.length) {
    $('resultsBody').innerHTML = '<tr><td colspan="7" class="empty">Результатов пока нет. Запустите подбор.</td></tr>';
    return;
  }
  const sorted = [...results].sort(cmpResults);
  const bestId = sorted[0].id;
  $('resultsBody').innerHTML = sorted.map((r, i) => {
    const status = (r.status || '').toLowerCase();
    return `<tr class="row ${r.id === bestId ? 'best' : ''}" data-result-id="${esc(r.id)}" title="Показать сайты конфигурации">
      <td class="rank">${r.id === bestId ? '★' : i + 1}</td>
      <td><div class="cfg-name" title="${esc(r.name)}">${esc(r.name)}</div></td>
      <td><span class="badge ${sourceClass(r.src)}">${esc(r.src)}</span></td>
      <td class="score">${esc(r.score)}</td>
      <td><span class="pass ${status}">${esc(r.passed)}/${esc(r.total)}</span></td>
      <td class="avg">${esc(r.avg)} мс</td>
      <td class="actions-cell">
        <button type="button" class="btn btn-sm btn-ghost" data-result-open="${esc(r.id)}"><svg class="icon"><use href="#i-globe"/></svg>Сайты</button>
        <button type="button" class="btn btn-sm btn-primary" data-auto-apply="${esc(r.id)}">Применить</button>
      </td>
    </tr>`;
  }).join('');
}

function parseDone(row) {
  return {
    id: row[1] || '', score: row[2] || '0', passed: row[3] || '0',
    avg: row[4] || '0', name: row[5] || '', src: row[6] || '',
    applied: row[7] === '1', cancelled: row[8] === '1',
  };
}

function renderDone() {
  const d = state.auto.done;
  const results = [...state.auto.results].sort(cmpResults);
  const box = $('autoSummary');
  box.hidden = false;

  if (!results.length) {
    box.innerHTML = '<div class="best-card"><div class="crown"><svg class="icon"><use href="#i-x"/></svg></div><div><b>Нет результатов</b><small>Не удалось проверить конфигурации</small></div></div>';
    return;
  }

  const best = results[0];
  const bestFs = results.filter((r) => r.src === 'Flowseal')[0];
  const bestBv = results.filter((r) => r.src === 'Bol-van')[0];
  const total = best.total || '?';
  const cancelled = d && d.cancelled;

  box.innerHTML = `
    <div class="best-card">
      <div class="crown"><svg class="icon"><use href="#i-crown"/></svg></div>
      <div>
        <b>${cancelled ? 'Подбор отменён' : `Лучший конфиг: ${esc(best.name)}`}</b>
        <small>${esc(best.passed)}/${esc(total)} сайтов · счёт ${esc(best.score)} · ${esc(best.avg)} мс${d && d.applied ? ' · уже применён' : ''}</small>
      </div>
      <button type="button" class="btn btn-primary btn-sm" data-apply-best="${esc(best.id)}">Применить и проверить</button>
      <button type="button" class="btn btn-ghost btn-sm" data-apply-only="${esc(best.id)}">Только применить</button>
    </div>
    <div class="best-sources">
      ${bestFs ? `<div class="src-best">Лучший Flowseal: <b>${esc(bestFs.name)}</b> · ${esc(bestFs.passed)}/${esc(bestFs.total)}</div>` : ''}
      ${bestBv ? `<div class="src-best">Лучший Bol-van: <b>${esc(bestBv.name)}</b> · ${esc(bestBv.passed)}/${esc(bestBv.total)}</div>` : ''}
    </div>`;
}

function stopAutoPolling() {
  state.auto.polling = false;
  if (state.auto.timer) clearTimeout(state.auto.timer);
  state.auto.timer = null;
}

async function pollAuto() {
  const rows = parse(await api('autotest_status'));
  const job = rows.find((r) => r[0] === 'JOB') || ['JOB', 'idle'];
  const stage = job[1];

  if (stage === 'idle') {
    state.auto.running = false;
    stopAutoPolling();
    refreshButtons();
    return;
  }
  if (stage === 'dead') {
    state.auto.running = false;
    stopAutoPolling();
    $('autoBadge').textContent = 'ошибка';
    $('autoPhase').textContent = 'Фоновый процесс завершился';
    toast('Фоновый процесс автоподбора завершился', 'err');
    refreshButtons();
    await loadStatus();
    return;
  }
  if (stage === 'error') {
    state.auto.running = false;
    stopAutoPolling();
    $('autoBadge').textContent = 'ошибка';
    $('autoPhase').textContent = 'Ошибка запуска';
    toast('Не удалось запустить подбор', 'err');
    refreshButtons();
    return;
  }

  state.auto.running = true;
  updateAutoProgress(job);

  const results = rows.filter((r) => r[0] === 'RESULT').map((r) => ({
    id: r[1], src: r[2], name: r[3], score: parseInt(r[4], 10) || 0,
    passed: parseInt(r[5], 10) || 0, total: parseInt(r[6], 10) || 0,
    avg: parseInt(r[7], 10) || 0, status: r[8] || 'FAIL',
  }));
  state.auto.results = results;
  renderResults(results);

  const sites = rows.filter((r) => r[0] === 'SITE').map((r) => ({
    name: r[1], ok: r[2] === '1', code: r[3], ms: r[4], weight: r[6], err: r.slice(7).join('|'),
  }));
  renderMiniSites(sites);

  const logs = rows.filter((r) => r[0] === 'LOG').map((r) => r.slice(1).join('|'));
  if (logs.length) {
    $('autoLog').hidden = false;
    $('autoLog').textContent = logs.slice(-8).join('\n');
  }

  const done = rows.find((r) => r[0] === 'DONE');
  if (done || stage === 'done') {
    if (done) state.auto.done = parseDone(done);
    state.auto.running = false;
    stopAutoPolling();
    renderDone();
    $('autoProgressWrap').hidden = true;
    $('autoBadge').textContent = 'готов';
    refreshButtons();
    await Promise.all([loadStatus(), loadConfigs()]);
    if (state.auto.done && state.auto.done.applied) toast('Лучший конфиг применён', 'ok');
    return;
  }

  refreshButtons();
}

function startAutoPolling() {
  if (state.auto.polling) return;
  state.auto.polling = true;
  const tick = async () => {
    if (!state.auto.polling) return;
    try { await pollAuto(); } catch (e) { console.error(e); }
    if (state.auto.polling) state.auto.timer = setTimeout(tick, 1800);
  };
  tick();
}

async function startAuto() {
  if (state.busy || state.auto.running) return;
  if (state.readonly) { toast('Панель в режиме только чтения', 'err'); return; }
  const ids = [...state.selected];
  if (!ids.length) { toast('Выберите хотя бы одну конфигурацию', 'err'); return; }
  const applyBest = $('autoApply').checked;
  if (!confirm(`Запустить автоподбор для ${ids.length} конфигураций?\n\n` +
    'Во время проверки zapret будет перезапускаться, интернет может кратко прерываться.\n' +
    (applyBest ? 'В конце будет применён лучший конфиг.' : 'В конце исходный конфиг будет восстановлен.'))) return;

  state.busy = true;
  refreshButtons();
  $('autoSummary').hidden = true;
  $('autoProgressWrap').hidden = false;
  $('autoBar').style.width = '0%';
  $('autoCounter').textContent = '0 / 0';
  $('autoPhase').textContent = 'Запуск…';
  $('autoCurrent').textContent = '';
  $('autoSites').innerHTML = '';
  $('autoLog').hidden = true;
  $('autoBadge').textContent = 'запуск';
  $('resultsBody').innerHTML = '<tr><td colspan="7" class="empty">Запуск подбора…</td></tr>';
  state.auto.results = [];
  state.auto.done = null;

  try {
    const rows = parse(await api('autotest_start', {
      ids: ids.join(','),
      mode: $('finalMode').value,
      apply: $('autoApply').checked ? 1 : 0,
    }));
    const r = rows[0] || ['ERROR'];
    if (r[0] === 'STARTED') {
      state.auto.running = true;
      toast('Подбор запущен — это может занять несколько минут', 'info');
      startAutoPolling();
    } else if (r[0] === 'BUSY') {
      toast(r[1] || 'Уже выполняется', 'err');
      state.auto.running = false;
    } else {
      toast(r.slice(1).join('|') || 'Ошибка запуска', 'err');
      state.auto.running = false;
    }
  } catch (e) {
    toast(`Ошибка запуска: ${e.message}`, 'err');
    state.auto.running = false;
  } finally {
    state.busy = false;
    refreshButtons();
  }
}

async function resumeAuto() {
  try {
    const rows = parse(await api('autotest_status'));
    const job = rows.find((r) => r[0] === 'JOB') || ['JOB', 'idle'];
    const stage = job[1];
    if (stage === 'idle') return;

    const results = rows.filter((r) => r[0] === 'RESULT').map((r) => ({
      id: r[1], src: r[2], name: r[3], score: parseInt(r[4], 10) || 0,
      passed: parseInt(r[5], 10) || 0, total: parseInt(r[6], 10) || 0,
      avg: parseInt(r[7], 10) || 0, status: r[8] || 'FAIL',
    }));
    if (results.length) { state.auto.results = results; renderResults(results); }

    const done = rows.find((r) => r[0] === 'DONE');
    if (done) {
      state.auto.done = parseDone(done);
      renderDone();
      $('autoProgressWrap').hidden = true;
      $('autoBadge').textContent = 'готов';
      return;
    }
    if (stage === 'running' || stage === 'starting') {
      state.auto.running = true;
      updateAutoProgress(job);
      startAutoPolling();
      refreshButtons();
    }
  } catch (e) {
    /* backend may be unavailable at first paint */
  }
}

/* -------------------------------------------------------------------- lists */
const LIST_FILES = [
  ['user.list', 'user.list — домены'],
  ['exclude.list', 'exclude.list — исключения'],
  ['ipset.list', 'ipset.list — IP'],
  ['ipset_exclude.list', 'ipset_exclude.list — IP-исключения'],
  ['sites.list', 'sites.list — проверяемые сайты'],
  ['nfqws.conf', 'nfqws.conf — конфиг'],
];

function renderLists() {
  $('lists').innerHTML = LIST_FILES.map(([file, label]) => `
    <div class="acc" data-file="${esc(file)}">
      <button type="button" class="acc-head">
        <span class="file"><svg class="icon"><use href="#i-edit"/></svg><span>${esc(label)}</span></span>
        <span class="meta" data-meta></span>
        <span class="chev">›</span>
      </button>
      <div class="acc-body"><div class="empty">Загрузка…</div></div>
    </div>`).join('');
}

async function loadList(file, body) {
  body.innerHTML = '<div class="empty">Загрузка…</div>';
  try {
    const text = await api('get_list', { file });
    const rows = parse(text);
    const head = rows[0] || [];
    if (head[0] !== 'LIST') {
      body.innerHTML = `<div class="empty">${esc(head.slice(1).join('|') || 'Ошибка')}</div>`;
      return;
    }
    const content = text.replace(/\r/g, '').split('\n').slice(1).join('\n')
      .replace(/\nTRUNC\|1\s*$/, '');
    const meta = body.parentElement.querySelector('[data-meta]');
    if (meta) meta.textContent = `${head[3] || 0} стр.`;
    body.innerHTML = `
      <pre></pre>
      <div class="acc-actions">
        <button type="button" class="btn btn-sm btn-ghost" data-edit><svg class="icon"><use href="#i-edit"/></svg>Редактировать</button>
        <button type="button" class="btn btn-sm btn-ghost" data-reload><svg class="icon"><use href="#i-refresh"/></svg>Обновить</button>
      </div>
      <div class="acc-note">${file === 'nfqws.conf' ? 'Осторожно: неверный конфиг остановит nfqws.' : 'Изменения сохраняются с резервной копией .bak.'}</div>`;
    body.querySelector('pre').textContent = content;

    body.querySelector('[data-reload]').onclick = () => loadList(file, body);
    body.querySelector('[data-edit]').onclick = () => editList(file, body, content);
  } catch (e) {
    body.innerHTML = `<div class="empty">Ошибка: ${esc(e.message)}</div>`;
  }
}

function editList(file, body, content) {
  body.innerHTML = `
    <textarea spellcheck="false"></textarea>
    <div class="acc-actions">
      <button type="button" class="btn btn-sm btn-primary" data-save>Сохранить</button>
      <button type="button" class="btn btn-sm btn-ghost" data-cancel>Отмена</button>
    </div>
    <div class="acc-note">Файл: ${esc(file)}</div>`;
  const ta = body.querySelector('textarea');
  ta.value = content;
  ta.focus();
  body.querySelector('[data-cancel]').onclick = () => loadList(file, body);
  body.querySelector('[data-save]').onclick = async () => {
    if (file === 'nfqws.conf' && !confirm('Сохранить изменения в nfqws.conf? Неверный конфиг остановит nfqws.')) return;
    const btn = body.querySelector('[data-save]');
    btn.disabled = true;
    try {
      const res = await fetch(`/control.cgi?save_list&file=${encodeURIComponent(file)}&_=${Date.now()}`, {
        method: 'POST', body: ta.value,
      });
      const rows = parse(await res.text());
      const r = rows[0] || ['ERROR'];
      if (r[0] === 'OK') {
        toast(`Сохранено: ${file} (${r[2]} байт)`, 'ok');
        if (file === 'sites.list') await loadSiteDefs();
        await loadList(file, body);
        await loadConfigs();
      } else {
        toast(r.slice(1).join('|') || 'Ошибка сохранения', 'err');
        btn.disabled = false;
      }
    } catch (e) {
      toast(`Ошибка сохранения: ${e.message}`, 'err');
      btn.disabled = false;
    }
  };
}

/* --------------------------------------------------------------- interfaces */
async function loadIfaces() {
  const box = $('ifaces');
  box.innerHTML = '<div class="empty">Загрузка…</div>';
  try {
    const rows = parse(await api('get_ifaces'));
    const list = rows.filter((r) => r[0] === 'IFACE' && r[1] !== 'NAME');
    box.innerHTML = list.length ? list.map((r) => {
      const up = r[4] === 'up';
      return `<div class="iface ${up ? 'up' : 'down'}">
        <span class="idot"></span>
        <div><b title="${esc(r[2])}">${esc(r[2])}</b><small>${esc(r[1])}</small></div>
        <span class="ip">${esc(r[3])}</span>
      </div>`;
    }).join('') : '<div class="empty">Интерфейсы не найдены</div>';
  } catch (e) {
    box.innerHTML = `<div class="empty">Ошибка: ${esc(e.message)}</div>`;
  }
}

/* --------------------------------------------------------------------- logs */
async function loadLog(src) {
  $('logView').textContent = 'Загрузка…';
  try {
    const text = await api('get_log', { src });
    const rows = parse(text);
    const head = rows[0] || [];
    if (head[0] === 'LOG') {
      $('logPath').textContent = head[2] || '';
      $('logView').textContent = text.replace(/\r/g, '').split('\n').slice(1).join('\n') || '(пусто)';
    } else {
      $('logPath').textContent = '';
      $('logView').textContent = head.slice(1).join('|') || 'Ошибка';
    }
  } catch (e) {
    $('logView').textContent = `Ошибка: ${e.message}`;
  }
}

/* ----------------------------------------------------------- result details */
function closeResult() {
  $('resultModal').hidden = true;
  document.body.classList.remove('modal-open');
  $('resultModalApply').hidden = true;
  $('resultModalApply').dataset.id = '';
}

function resultSitesHtml(sites) {
  const ok = sites.filter((s) => s.ok);
  const fail = sites.filter((s) => !s.ok);
  return `<div class="res-groups">
    ${siteGroup('Работают', ok, 'ok', false)}
    ${siteGroup('Не работают', fail, 'fail', false)}
  </div>`;
}

async function openResult(id) {
  const modal = $('resultModal');
  const applyBtn = $('resultModalApply');
  modal.hidden = false;
  document.body.classList.add('modal-open');
  $('resultModalTitle').textContent = 'Сайты конфигурации';
  $('resultModalSub').textContent = id;
  $('resultModalBody').innerHTML = '<div class="empty">Загрузка данных…</div>';
  $('resultModalHint').textContent = '';
  applyBtn.hidden = true;
  applyBtn.dataset.id = '';

  try {
    const rows = parse(await api('get_result_sites', { id }));
    const err = rows.find((r) => r[0] === 'ERROR');
    if (err) {
      $('resultModalBody').innerHTML = `<div class="res-note">${esc(err.slice(1).join('|') || 'Нет данных')}</div>`;
      return;
    }
    const meta = rows.find((r) => r[0] === 'META') || [];
    const sites = rows.filter((r) => r[0] === 'SITE').map((r) => ({
      name: r[1], ok: r[2] === '1', code: r[3], ms: r[4], size: r[5],
      weight: r[6], err: r.slice(7).join('|'),
    }));
    const name = meta[3] || id;
    const src = meta[2] || '';
    const score = meta[4] || sites.filter((s) => s.ok).reduce((a, s) => a + (parseInt(s.weight, 10) || 1), 0);
    const passed = meta[5] || String(sites.filter((s) => s.ok).length);
    const total = meta[6] || String(sites.length);
    const avg = meta[7] || '—';

    $('resultModalTitle').textContent = name;
    $('resultModalSub').textContent = `${id}${src ? ` · ${src}` : ''}${meta[8] ? ` · ${meta[8]}` : ''}`;
    $('resultModalBody').innerHTML = `
      <div class="res-meta">
        <div><span>Счёт</span><b>${esc(score)}</b></div>
        <div><span>Сайты</span><b>${esc(passed)}/${esc(total)}</b></div>
        <div><span>Ср. время</span><b>${esc(avg)} мс</b></div>
        <div><span>Источник</span><b>${esc(src || '—')}</b></div>
      </div>
      ${sites.length ? resultSitesHtml(sites) : '<div class="res-note">Для этой конфигурации нет данных по сайтам.</div>'}`;

    if (!state.readonly) {
      applyBtn.hidden = false;
      applyBtn.dataset.id = id;
      $('resultModalHint').textContent = 'Применение перезапустит zapret и проверит сайты.';
    }
  } catch (e) {
    $('resultModalBody').innerHTML = `<div class="res-note">Ошибка: ${esc(e.message)}</div>`;
  }
}

/* --------------------------------------------------------------------- bind */
function bind() {
  $('btnRefreshStatus').onclick = async (e) => {
    const b = e.currentTarget;
    b.classList.add('spin');
    await loadStatus();
    setTimeout(() => b.classList.remove('spin'), 500);
  };
  $('btnRestart').onclick = () => {
    if (confirm('Перезапустить zapret?')) simpleAction('restart_zapret', 'Перезапуск');
  };
  $('btnStop').onclick = () => {
    if (confirm('Остановить zapret? Обход DPI перестанет работать.')) simpleAction('stop_zapret', 'Остановка');
  };
  $('btnStart').onclick = () => simpleAction('start_zapret', 'Запуск');
  $('btnRestore').onclick = () => {
    if (confirm('Вернуть исходный nfqws.conf из резервной копии?')) simpleAction('restore_original', 'Восстановление');
  };

  $('btnTestSites').onclick = runSiteTests;
  $('btnAuto').onclick = startAuto;
  $('btnCancelAuto').onclick = async () => {
    try { await api('autotest_cancel'); toast('Отмена запрошена', 'info'); } catch (e) { toast(e.message, 'err'); }
  };

  $('btnRefreshConfigs').onclick = async (e) => {
    const b = e.currentTarget;
    b.classList.add('spin');
    await loadConfigs(true);
    setTimeout(() => b.classList.remove('spin'), 500);
  };

  $('sourceTabs').addEventListener('click', (e) => {
    const b = e.target.closest('.tab');
    if (!b) return;
    state.source = b.dataset.source;
    $('sourceTabs').querySelectorAll('.tab').forEach((t) => t.classList.toggle('active', t === b));
    renderConfigs();
  });

  $('selectAll').addEventListener('change', (e) => {
    if (e.target.checked) state.configs.forEach((c) => state.selected.add(c.id));
    else state.selected.clear();
    renderConfigs();
    updateSelected();
  });

  $('configList').addEventListener('click', (e) => {
    const btn = e.target.closest('button[data-act]');
    if (!btn) return;
    const card = btn.closest('.config');
    if (!card) return;
    const id = card.dataset.id;
    if (btn.dataset.act === 'test') runSiteTests();
    else applyConfig(id, btn.dataset.act === 'apply-test');
  });

  $('configList').addEventListener('change', (e) => {
    const cb = e.target.closest('.cfg-check');
    if (!cb) return;
    if (cb.checked) state.selected.add(cb.dataset.id);
    else state.selected.delete(cb.dataset.id);
    updateSelected();
  });

  $('resultsBody').addEventListener('click', (e) => {
    const apply = e.target.closest('button[data-auto-apply]');
    if (apply) { applyConfig(apply.dataset.autoApply, true); return; }
    const open = e.target.closest('button[data-result-open]');
    const row = e.target.closest('tr[data-result-id]');
    const id = open ? open.dataset.resultOpen : row ? row.dataset.resultId : '';
    if (id) openResult(id);
  });

  $('resultModal').addEventListener('click', (e) => {
    if (e.target.closest('[data-modal-close]')) closeResult();
  });
  $('resultModalApply').onclick = () => {
    const id = $('resultModalApply').dataset.id;
    if (!id) return;
    closeResult();
    applyConfig(id, true);
  };
  document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape' && !$('resultModal').hidden) closeResult();
  });

  $('autoSummary').addEventListener('click', (e) => {
    const b = e.target.closest('button');
    if (!b) return;
    if (b.dataset.applyBest) applyConfig(b.dataset.applyBest, true);
    else if (b.dataset.applyOnly) applyConfig(b.dataset.applyOnly, false);
  });

  $('lists').addEventListener('click', (e) => {
    const head = e.target.closest('.acc-head');
    if (!head) return;
    const acc = head.closest('.acc');
    const body = acc.querySelector('.acc-body');
    const wasOpen = acc.classList.contains('open');
    acc.classList.toggle('open');
    if (!wasOpen && body.querySelector('.empty')) loadList(acc.dataset.file, body);
  });

  $('btnRefreshIfaces').onclick = (e) => {
    const b = e.currentTarget;
    b.classList.add('spin');
    loadIfaces().finally(() => setTimeout(() => b.classList.remove('spin'), 500));
  };

  document.querySelectorAll('[data-log]').forEach((tab) => {
    tab.onclick = () => {
      document.querySelectorAll('[data-log]').forEach((t) => t.classList.toggle('active', t === tab));
      loadLog(tab.dataset.log);
    };
  });
}

async function simpleAction(action, label) {
  if (state.busy || state.auto.running) return;
  state.busy = true;
  refreshButtons();
  try {
    const rows = parse(await api(action));
    const r = rows[0] || ['ERROR'];
    if (r[0] === 'OK') toast(`${label}: готово`, 'ok');
    else toast(r.slice(1).join('|') || `${label}: ошибка`, 'err');
    await Promise.all([loadStatus(), loadConfigs()]);
  } catch (e) {
    toast(`${label}: ${e.message}`, 'err');
  } finally {
    state.busy = false;
    refreshButtons();
  }
}

document.addEventListener('DOMContentLoaded', async () => {
  bind();
  renderLists();
  await Promise.allSettled([loadStatus(), loadConfigs(), loadSiteDefs(), loadIfaces()]);
  await resumeAuto();
  loadLog('nfqws');
  refreshButtons();
  setInterval(loadStatus, 15000);
});
})();
