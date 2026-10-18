'use strict';

// Fixed kind order = fixed palette slot order. A kind keeps its color whatever is on screen.
const KINDS = [
  ['javascript', 'JavaScript'],
  ['python', 'Python'],
  ['apple', 'Xcode & Swift'],
  ['jvm', 'Android, JVM & Flutter'],
  ['models', 'AI models'],
  ['toolchains', 'Toolchains & editors'],
  ['sessions', 'AI sessions'],
  ['docker', 'Docker & VMs'],
];
const KIND_NAME = Object.fromEntries(KINDS);
const GROUP_NAME = { safe: 'Safe to remove', review: 'Let me review first' };
const kcolor = (k) => `var(--k-${k})`;

const $ = (s) => document.querySelector(s);
const $$ = (s) => [...document.querySelectorAll(s)];
const bridge = (msg) => window.webkit?.messageHandlers?.bridge?.postMessage(msg);

const state = { data: null, items: [], selected: new Set(), prefs: null, group: 'all', query: '' };

// ---------- formatting ----------
function fmt(b) {
  const u = ['B', 'KB', 'MB', 'GB', 'TB'];
  let v = Math.max(0, b), i = 0;
  while (v >= 1000 && i < u.length - 1) { v /= 1000; i++; }
  const s = i === 0 || v >= 100 ? v.toFixed(0) : v >= 10 ? v.toFixed(1) : v.toFixed(2);
  return `${s} ${u[i]}`;
}
const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
// Effect text marks commands with backticks; show them as code.
const rich = (s) => esc(s).replace(/`([^`]+)`/g, '<code>$1</code>');
const when = (iso) => new Date(iso).toLocaleString(undefined, { dateStyle: 'medium', timeStyle: 'short' });
const delta = (it) => (it.prevBytes != null ? it.bytes - it.prevBytes : 0);
const sum = (arr, f = (x) => x) => arr.reduce((a, x) => a + f(x), 0);

function countUp(el, to, format, dur = 900) {
  const t0 = performance.now();
  const step = (t) => {
    const p = Math.min(1, (t - t0) / dur);
    el.textContent = format(p === 1 ? to : to * (1 - Math.pow(2, -10 * p)));
    if (p < 1) requestAnimationFrame(step);
  };
  requestAnimationFrame(step);
}

function toast(msg) {
  const t = $('#toast');
  t.textContent = msg;
  t.classList.add('show');
  clearTimeout(toast.h);
  toast.h = setTimeout(() => t.classList.remove('show'), 2400);
}

// ---------- bridge from Swift ----------
window.App = {
  receive(msg) {
    switch (msg.type) {
      case 'prefs': {
        const first = !state.prefs;
        state.prefs = msg;
        $$('input[name=prot]').forEach((r) => (r.checked = r.value === msg.protected));
        $('#csvPath').textContent = msg.csvPath;
        if (first && msg.protected !== 'ask') requestScan();
        break;
      }
      case 'scanStarted': showView('scanning'); setScanning(true); break;
      case 'progress':
        $('#scanPath').textContent = msg.path;
        $('#foundCount').textContent = msg.found;
        break;
      case 'result': setScanning(false); load(msg.payload); break;
      case 'cleanStarted': cleanStarted(msg.ids); break;
      case 'cleanLog': if (msg.idx != null && $(`#cs${msg.idx} pre`)) appendOut($(`#cs${msg.idx} pre`), msg.text); break;
      case 'cleanStep': cleanStep(msg); break;
      case 'cleanDone': cleanDone(msg); break;
      case 'error': toast(msg.message); break;
    }
  },
};

function setScanning(on) {
  $$('#scanBtn, #scanBtn2').forEach((b) => (b.disabled = on));
  $('#scanBtn span').textContent = on ? 'Scanning…' : 'Scan again';
}

function showView(v) {
  $('#empty').classList.toggle('hidden', v !== 'empty');
  $('#scanning').classList.toggle('hidden', v !== 'scanning');
  $('#results').classList.toggle('hidden', v !== 'results');
}

function requestScan() {
  if (state.prefs?.protected === 'ask') { openModal('#askModal'); return; }
  bridge({ cmd: 'scan' });
}

// ---------- results ----------
function load(data) {
  state.data = data;
  state.items = data.items.map((it, i) => ({ ...it, i }));
  const keep = new Set(state.items.filter((it) => state.selected.has(it.id)).map((it) => it.id));
  state.selected = keep;
  showView('results');
  const prev = data.previousScanAt ? ` · previous scan ${when(data.previousScanAt)}` : ' · first scan';
  $('#subtitle').textContent = `Scanned ${when(data.scannedAt)} in ${(data.durationMs / 1000).toFixed(1)}s${prev}. Sizes only, read-only.`;
  renderStats();
  renderLegend();
  renderTreemap();
  renderDonut();
  renderBars();
  renderGrowth();
  renderList();
  renderSkipped();
  updateSelection();
}

function renderStats() {
  const its = state.items;
  const safe = its.filter((i) => i.group === 'safe'), review = its.filter((i) => i.group === 'review');
  const grew = its.filter((i) => i.grew);
  countUp($('[data-count=total]'), sum(its, (i) => i.bytes), fmt);
  countUp($('[data-count=safe]'), sum(safe, (i) => i.bytes), fmt);
  countUp($('[data-count=review]'), sum(review, (i) => i.bytes), fmt);
  $('#statTotalSub').textContent = `${its.length} folders ≥ ${fmt(state.data.minBytes)}`;
  $('#statSafeSub').textContent = `${safe.length} folders, regenerated or re-downloaded when needed`;
  $('#statReviewSub').textContent = `${review.length} folders: sessions, models, Docker, toolchains`;
  if (!state.data.previousScanAt) {
    $('[data-count=grew]').textContent = '—';
    $('#statGrewSub').textContent = 'First scan. Baseline saved.';
  } else {
    countUp($('[data-count=grew]'), sum(grew, delta), (v) => '+' + fmt(v));
    $('#statGrewSub').textContent = `${grew.length} folder${grew.length === 1 ? '' : 's'} grew · ${state.items.filter((i) => i.isNew).length} new`;
  }
}

function renderLegend() {
  const present = new Set(state.items.map((i) => i.kind));
  $('#legend').innerHTML = KINDS.filter(([k]) => present.has(k))
    .map(([k, n]) => `<span><i class="dot" style="background:${kcolor(k)}"></i>${esc(n)}</span>`).join('');
}

// ---------- treemap (squarified) ----------
function squarify(values, x, y, w, h) {
  const total = sum(values);
  const out = [];
  if (!total || w <= 0 || h <= 0) return out;
  const scale = (w * h) / total;
  const areas = values.map((v) => v * scale);
  const rect = { x, y, w, h };
  const worst = (row, side) => {
    const s = sum(row), mx = Math.max(...row), mn = Math.min(...row);
    return Math.max((side * side * mx) / (s * s), (s * s) / (side * side * mn));
  };
  const lay = (row) => {
    const s = sum(row);
    if (rect.w >= rect.h) {
      const cw = s / rect.h; let yy = rect.y;
      for (const a of row) { out.push({ x: rect.x, y: yy, w: cw, h: a / cw }); yy += a / cw; }
      rect.x += cw; rect.w -= cw;
    } else {
      const rh = s / rect.w; let xx = rect.x;
      for (const a of row) { out.push({ x: xx, y: rect.y, w: a / rh, h: rh }); xx += a / rh; }
      rect.y += rh; rect.h -= rh;
    }
  };
  let row = [], i = 0;
  while (i < areas.length) {
    const side = Math.min(rect.w, rect.h);
    if (!row.length || worst([...row, areas[i]], side) <= worst(row, side)) { row.push(areas[i]); i++; }
    else { lay(row); row = []; }
  }
  if (row.length) lay(row);
  return out;
}

function renderTreemap() {
  const el = $('#treemap');
  const W = el.clientWidth, H = el.clientHeight, HEAD = 30, GAP = 14;
  const groups = ['safe', 'review'].map((g) => {
    const items = state.items.filter((i) => i.group === g).sort((a, b) => b.bytes - a.bytes);
    return { g, items, total: sum(items, (i) => i.bytes) };
  });
  const all = sum(groups, (g) => g.total);
  let html = '';
  let x = 0;
  const live = groups.filter((g) => g.total > 0);
  for (const grp of groups) {
    if (!grp.total) continue;
    // Each side gets at least 22% so neither collapses to an unreadable sliver.
    const share = live.length === 1 ? 1 : Math.min(0.78, Math.max(0.22, grp.total / all));
    const gw = live.length === 1 ? W : grp === live[0] ? (W - GAP) * share : W - x;
    html += `<div class="tm-group" style="left:${x}px;top:0;width:${gw}px;height:${H}px">
      <div class="tm-head"><i class="dot ${grp.g}"></i>${GROUP_NAME[grp.g]} <small>${fmt(grp.total)} · ${grp.items.length}</small></div>`;
    const rects = squarify(grp.items.map((i) => i.bytes), 0, HEAD, gw, H - HEAD);
    rects.forEach((r, j) => {
      const it = grp.items[j];
      const w = Math.max(0, r.w - 2), h = Math.max(0, r.h - 2);
      const big = w > 90 && h > 44, mid = w > 56 && h > 24;
      html += `<div class="tm-tile${big || mid ? '' : ' tiny'}${state.selected.has(it.id) ? ' sel' : ''}" data-i="${it.i}"
        style="--c:${kcolor(it.kind)};left:${r.x + 1}px;top:${r.y + 1}px;width:${w}px;height:${h}px">
        ${big ? `<span class="n">${esc(it.label)}</span>` : ''}${mid ? `<span class="s">${fmt(it.bytes)}</span>` : ''}
        ${it.grew && mid ? '<span class="flag" title="Grew since last scan">▲</span>' : ''}<span class="chk">✓</span></div>`;
    });
    html += '</div>';
    x += gw + GAP;
  }
  if (!all) html = `<div class="tm-empty" style="inset:0">Nothing over ${fmt(state.data.minBytes)} found.</div>`;
  el.innerHTML = html;
}

// ---------- donut ----------
function renderDonut() {
  const svg = $('#donut');
  const byKind = KINDS.map(([k, n]) => ({ k, n, v: sum(state.items.filter((i) => i.kind === k), (i) => i.bytes) }))
    .filter((d) => d.v > 0).sort((a, b) => b.v - a.v);
  // Up to 6 segments; the tail folds into "Other".
  let segs = byKind;
  if (byKind.length > 6) {
    const tail = byKind.slice(5);
    segs = [...byKind.slice(0, 5), { k: 'other', n: `Other (${tail.map((t) => t.n).join(', ')})`, v: sum(tail, (t) => t.v), short: 'Other' }];
  }
  const total = sum(segs, (s) => s.v);
  const cx = 110, cy = 110, r1 = 104, r0 = 74;
  const pt = (r, a) => `${(cx + r * Math.sin(a)).toFixed(2)} ${(cy - r * Math.cos(a)).toFixed(2)}`;
  let a = 0, paths = '';
  segs.forEach((s, j) => {
    const a1 = a + Math.min((s.v / total) * Math.PI * 2, Math.PI * 2 - 1e-4);
    const large = a1 - a > Math.PI ? 1 : 0;
    paths += `<path data-j="${j}" fill="${kcolor(s.k)}" d="M ${pt(r1, a)} A ${r1} ${r1} 0 ${large} 1 ${pt(r1, a1)} L ${pt(r0, a1)} A ${r0} ${r0} 0 ${large} 0 ${pt(r0, a)} Z"/>`;
    a = a1;
  });
  svg.innerHTML = `${paths}<text class="c1" x="110" y="112">${fmt(total)}</text><text class="c2" x="110" y="132">found</text>`;
  $('#donutLegend').innerHTML = segs.map((s, j) =>
    `<li data-j="${j}"><i class="dot" style="background:${kcolor(s.k)}"></i><span title="${esc(s.n)}">${esc(s.short || s.n)}</span><b>${fmt(s.v)}</b><small>${Math.round((s.v / total) * 100)}%</small></li>`).join('');
  const hot = (j) => {
    svg.classList.toggle('hovering', j != null);
    $$('#donut path').forEach((p) => p.classList.toggle('hot', +p.dataset.j === j));
  };
  $$('#donut path, #donutLegend li').forEach((el) => {
    el.addEventListener('mouseenter', (e) => {
      const s = segs[+el.dataset.j];
      hot(+el.dataset.j);
      showTip(e, `<h5><i class="dot" style="background:${kcolor(s.k)}"></i>${esc(s.n)}</h5><div class="big">${fmt(s.v)}</div><div class="e">${Math.round((s.v / total) * 100)}% of everything found</div>`);
    });
    el.addEventListener('mousemove', moveTip);
    el.addEventListener('mouseleave', () => { hot(null); hideTip(); });
  });
}

// ---------- bars ----------
function barRow(it, value, max, label, valText, up) {
  return `<div class="bar" data-i="${it.i}" style="--c:${kcolor(it.kind)}">
    <span class="l" title="${esc(it.displayPath)}">${esc(label)}</span>
    <span class="t"><i style="width:${Math.max(0.5, (value / max) * 100)}%"></i></span>
    <span class="v${up ? ' up' : ''}">${valText}</span></div>`;
}

function renderBars() {
  const top = [...state.items].sort((a, b) => b.bytes - a.bytes).slice(0, 10);
  const max = top[0]?.bytes || 1;
  $('#bars').innerHTML = top.map((it) => barRow(it, it.bytes, max, it.label, fmt(it.bytes))).join('') || '<p class="empty-note">Nothing found.</p>';
}

function renderGrowth() {
  const d = state.data;
  const hint = $('#sinceHint');
  if (!d.previousScanAt) {
    hint.textContent = '';
    $('#growth').innerHTML = `<p class="empty-note">First scan. Sizes were saved to <code>${esc(d.csvPath)}</code>. Next time DevDisk reads that file first and flags what grew.</p>`;
    return;
  }
  hint.textContent = `vs ${when(d.previousScanAt)}`;
  const grew = state.items.filter((i) => i.grew).sort((a, b) => delta(b) - delta(a)).slice(0, 8);
  const max = delta(grew[0] || {}) || 1;
  let html = grew.map((it) => barRow(it, delta(it), max, it.label, `▲ +${fmt(delta(it))}`, true)).join('');
  if (!grew.length) html = '<p class="empty-note">Nothing grew noticeably since the last scan.</p>';
  const fresh = state.items.filter((i) => i.isNew).length;
  const extra = [fresh && `${fresh} new folder${fresh > 1 ? 's' : ''} appeared`, d.gone.length && `${d.gone.length} gone (${fmt(sum(d.gone, (g) => g.bytes))})`].filter(Boolean);
  if (extra.length) html += `<p class="hint" style="padding:8px 4px 0">${extra.join(' · ')}</p>`;
  $('#growth').innerHTML = html;
}

// ---------- list ----------
function renderList() {
  const q = state.query.toLowerCase();
  const match = (it) => !q || it.label.toLowerCase().includes(q) || it.displayPath.toLowerCase().includes(q) || KIND_NAME[it.kind].toLowerCase().includes(q);
  let html = '';
  for (const g of ['safe', 'review']) {
    if (state.group !== 'all' && state.group !== g) continue;
    const items = state.items.filter((i) => i.group === g && match(i)).sort((a, b) => b.bytes - a.bytes);
    if (!items.length) continue;
    const allOn = items.every((i) => state.selected.has(i.id));
    html += `<div class="grp-title"><i class="dot ${g}"></i>${GROUP_NAME[g]} <small>${fmt(sum(items, (i) => i.bytes))} · ${items.length}</small>
      <button class="ghost" data-tickall="${g}">${allOn ? 'Untick all' : 'Tick all'}</button></div>`;
    for (const it of items) html += rowHTML(it);
  }
  $('#list').innerHTML = html || '<p class="empty-note">No matches.</p>';
}

// The shell equivalent of DevDisk's Move to Trash, e.g. mv ~/'My App/.build' ~/.Trash/
function trashCmd(it) {
  const q = (p) => (/^[\w@%+=:,.\/-]+$/.test(p) ? p : `'${p.replace(/'/g, `'\\''`)}'`);
  const p = it.displayPath.startsWith('~/') ? `~/${q(it.displayPath.slice(2))}` : q(it.displayPath);
  return `mv ${p} ~/.Trash/`;
}

// What removal does and whether it can be undone.
function howHTML(it) {
  return it.command
    ? `<span>Runs</span><code>${esc(it.command)}</code><span class="undo no">Can't be undone: the tool deletes it directly, not via the Trash</span>`
    : `<span>Moves to Trash, same as</span><code>${esc(trashCmd(it))}</code><span class="undo yes">↩ Undoable: drag it out of the Trash until you empty it</span>`;
}

function rowHTML(it) {
  const d = delta(it);
  const badges = [
    `<span class="badge kind" style="--c:${kcolor(it.kind)}">${esc(KIND_NAME[it.kind])}</span>`,
    it.grew ? `<span class="badge up">▲ grew +${fmt(d)}</span>` : '',
    it.isNew ? '<span class="badge new">new</span>' : '',
  ].join('');
  const how = howHTML(it);
  const was = it.prevBytes != null && d !== 0 ? `<small>was ${fmt(it.prevBytes)}</small>` : '';
  return `<div class="row" data-i="${it.i}">
    <input type="checkbox" ${state.selected.has(it.id) ? 'checked' : ''} aria-label="Select ${esc(it.label)}">
    <div><div class="ttl">${esc(it.label)} ${badges}</div>
      <div class="path" ${it.path.startsWith('/') ? `title="Reveal in Finder"` : ''}>${esc(it.displayPath)}</div>
      <div class="eff">If deleted: ${rich(it.effect)}</div>
      <div class="how">${how}</div></div>
    <div class="size">${fmt(it.bytes)}${was}</div></div>`;
}

function renderSkipped() {
  const d = state.data;
  const list = [...d.skipped.map((s) => `<li><code>${esc(s.path)}</code>: ${esc(s.reason)}</li>`), ...d.notes.map((n) => `<li>${esc(n)}</li>`)];
  if (d.hiddenSmall) list.push(`<li>${d.hiddenSmall} matching folders under ${fmt(d.minBytes)} aren't shown</li>`);
  $('#skippedCount').textContent = `(${d.skipped.length})`;
  $('#skippedList').innerHTML = list.join('');
}

// ---------- selection ----------
function toggle(id, on) {
  if (on ?? !state.selected.has(id)) state.selected.add(id); else state.selected.delete(id);
}

function updateSelection() {
  const sel = state.items.filter((i) => state.selected.has(i.id));
  $$('.tm-tile').forEach((t) => t.classList.toggle('sel', state.selected.has(state.items[+t.dataset.i].id)));
  $$('.row').forEach((r) => (r.querySelector('input').checked = state.selected.has(state.items[+r.dataset.i].id)));
  $$('[data-tickall]').forEach((b) => {
    const g = b.dataset.tickall;
    const rows = $$('.row').map((r) => state.items[+r.dataset.i]).filter((i) => i.group === g);
    b.textContent = rows.length && rows.every((i) => state.selected.has(i.id)) ? 'Untick all' : 'Tick all';
  });
  $('#selCount').textContent = sel.length;
  $('#selSize').textContent = fmt(sum(sel, (i) => i.bytes));
  $('#selbar').classList.toggle('show', sel.length > 0);
}

// ---------- cleanup ----------
const STATUS = {
  pending: ['○', ''], running: ['●', 'running…'], done: ['✓', ''], trashed: ['✓', ''],
  failed: ['✕', ''], nothing: ['!', ''], missing: ['–', ''], skipped: ['–', ''], stopped: ['■', 'stopped'], notRun: ['○', 'not run'],
};

function selectedItems() {
  return state.items.filter((i) => state.selected.has(i.id))
    .sort((a, b) => (a.group === b.group ? b.bytes - a.bytes : a.group === 'safe' ? -1 : 1));
}

function openConfirm() {
  const items = selectedItems();
  state.pending = items;
  const total = sum(items, (i) => i.bytes);
  const trash = items.filter((i) => !i.command).length;
  $('#confirmSub').textContent = `${items.length} item${items.length === 1 ? '' : 's'}, ${fmt(total)}. ` +
    `${items.length - trash} run their tool's clean command${trash ? `, ${trash} move to the Trash` : ''}.`;
  let html = '';
  for (const g of ['safe', 'review']) {
    const gi = items.filter((i) => i.group === g);
    if (!gi.length) continue;
    html += `<div class="c-grp ${g}"><i class="dot ${g}"></i>${GROUP_NAME[g]} <small>${fmt(sum(gi, (i) => i.bytes))} · ${gi.length}</small>
      ${g === 'review' ? '<small>⚠ Check each of these before you continue</small>' : ''}</div>`;
    html += gi.map((it) => `<div class="c-row"><div><b>${esc(it.label)}</b><div class="p">${esc(it.displayPath)}</div>
      <div class="a how">${howHTML(it)}</div>
      <div class="a">If deleted: ${rich(it.effect)}</div></div><div class="s">${fmt(it.bytes)}</div></div>`).join('');
  }
  $('#confirmList').innerHTML = html;
  $('#confirmGo').textContent = `Remove ${items.length} item${items.length === 1 ? '' : 's'} (${fmt(total)})`;
  openModal('#confirmModal');
}

function cleanStarted(ids) {
  const byId = Object.fromEntries(state.items.map((i) => [i.id, i]));
  state.clean = { items: ids.map((id) => byId[id]), status: ids.map(() => 'pending'), freed: 0, trashed: 0, running: true };
  $('#cleanSteps').innerHTML = state.clean.items.map((it, k) => `<div class="cs pending" id="cs${k}">
    <div class="cs-head"><span class="ic">○</span><span><b>${esc(it.label)}</b> <span class="hint">${fmt(it.bytes)} · ${esc(it.displayPath)}</span></span><span class="r"></span></div>
    <pre></pre></div>`).join('');
  $('#cleanTitle').textContent = 'Cleaning up…';
  $('#cleanFoot').textContent = 'Output stays here so you can review it.';
  $('#cleanStop').classList.remove('hidden');
  $('#cleanStop').disabled = false;
  ['#cleanClose', '#cleanRescan', '#cleanLogBtn'].forEach((s) => $(s).classList.add('hidden'));
  cleanProgress();
  openModal('#cleanModal');
}

function cleanProgress() {
  const c = state.clean;
  const finished = c.status.filter((s) => s !== 'pending' && s !== 'running').length;
  $('#cleanBar').style.width = `${(finished / c.items.length) * 100}%`;
  $('#cleanSub').textContent = `${finished} of ${c.items.length} · freed ${fmt(c.freed)}${c.trashed ? ` · ${fmt(c.trashed)} in Trash` : ''}`;
}

// Keep the log readable: strip color codes and let \r progress lines overwrite themselves.
function appendOut(pre, text) {
  text = text.replace(/\x1b\[[0-9;?]*[A-Za-z]/g, '').replace(/\r\n/g, '\n');
  const parts = text.split('\r');
  let cur = pre.textContent + parts[0];
  for (let k = 1; k < parts.length; k++) cur = cur.slice(0, cur.lastIndexOf('\n') + 1) + parts[k];
  if (cur.length > 200000) cur = '…\n' + cur.slice(-200000);
  const box = $('#cleanSteps');
  const stick = box.scrollHeight - box.scrollTop - box.clientHeight < 40;
  pre.textContent = cur;
  pre.scrollTop = pre.scrollHeight;
  if (stick) box.scrollTop = box.scrollHeight;
}

function cleanStep(m) {
  const c = state.clean, el = $(`#cs${m.idx}`);
  if (!c || !el) return;
  c.status[m.idx] = m.status;
  if (m.status === 'trashed') c.trashed += m.freed; else c.freed += m.freed;
  el.className = `cs ${m.status}`;
  el.querySelector('.ic').textContent = STATUS[m.status][0];
  const r = el.querySelector('.r');
  const ok = m.status === 'done' || m.status === 'trashed';
  r.className = `r ${ok ? 'ok' : ['failed', 'missing'].includes(m.status) ? 'bad' : m.status === 'nothing' ? 'warn' : ''}`;
  r.textContent = m.status === 'trashed' ? `moved to Trash (${fmt(m.freed)})`
    : m.status === 'done' ? (m.freed ? `freed ${fmt(m.freed)}` : m.message || 'done')
    : m.message || STATUS[m.status][1];
  if (m.status === 'running') el.scrollIntoView({ block: 'nearest' });
  cleanProgress();
}

function cleanDone(m) {
  const c = state.clean;
  c.running = false;
  c.logPath = m.logPath;
  // Untick what's gone; keep failures ticked so they're easy to retry.
  c.items.forEach((it, k) => { if (['done', 'trashed'].includes(c.status[k])) state.selected.delete(it.id); });
  updateSelection();
  const n = m.counts || {};
  const bad = (n.failed || 0) + (n.missing || 0), none = n.nothing || 0;
  $('#cleanTitle').textContent = m.stopped ? 'Cleanup stopped' : bad ? 'Cleanup finished with problems' : 'Cleanup finished';
  $('#cleanSub').textContent = `Freed ${fmt(m.freed)}${m.trashed ? `, plus ${fmt(m.trashed)} in the Trash (empty it to get that space back)` : ''} · ${m.seconds}s` +
    (bad ? ` · ${bad} didn't complete` : '') + (none ? ` · ${none} had nothing to remove` : '');
  $('#cleanBar').style.width = '100%';
  $('#cleanFoot').textContent = `Log saved to ${m.logDisplay}`;
  $('#cleanStop').classList.add('hidden');
  ['#cleanClose', '#cleanRescan', '#cleanLogBtn'].forEach((s) => $(s).classList.remove('hidden'));
}

// ---------- tooltip ----------
function showTip(e, html) { const t = $('#tip'); t.innerHTML = html; t.classList.add('show'); moveTip(e); }
function moveTip(e) {
  const t = $('#tip'), pad = 14, r = t.getBoundingClientRect();
  let x = e.clientX + pad, y = e.clientY + pad;
  if (x + r.width > innerWidth - 8) x = e.clientX - r.width - pad;
  if (y + r.height > innerHeight - 8) y = e.clientY - r.height - pad;
  t.style.left = `${Math.max(8, x)}px`; t.style.top = `${Math.max(8, y)}px`;
}
function hideTip() { $('#tip').classList.remove('show'); }
function itemTip(it) {
  const d = delta(it);
  return `<h5><i class="dot" style="background:${kcolor(it.kind)}"></i>${esc(it.label)}</h5>
    <div class="p">${esc(it.displayPath)}</div>
    <div class="big">${fmt(it.bytes)} ${it.grew ? `<span class="badge up">▲ +${fmt(d)}</span>` : ''}${it.isNew ? '<span class="badge new">new</span>' : ''}</div>
    <div class="e">${esc(GROUP_NAME[it.group])} · ${esc(KIND_NAME[it.kind])}</div>
    <div class="e" style="margin-top:6px">If deleted: ${rich(it.effect)}</div>
    <div class="e" style="margin-top:6px">${it.command ? `Clean with <code>${esc(it.command.split('\n')[0])}</code>${it.command.includes('\n') ? ' …' : ''} · can't be undone` : `Moves to Trash (<code>${esc(trashCmd(it))}</code>) · undoable`}</div>`;
}

// ---------- modals ----------
function openModal(sel) { $(sel).classList.remove('hidden'); }
function closeModals() { $$('.modal').forEach((m) => m.classList.add('hidden')); }

// ---------- events ----------
document.addEventListener('DOMContentLoaded', () => {
  $$('#scanBtn, #scanBtn2').forEach((b) => b.addEventListener('click', requestScan));
  $('#settingsBtn').addEventListener('click', () => openModal('#settingsModal'));
  $$('input[name=prot]').forEach((r) => r.addEventListener('change', () => bridge({ cmd: 'setProtected', value: r.value })));
  $('#askAllow').addEventListener('click', () => { closeModals(); bridge({ cmd: 'setProtected', value: 'allow' }); bridge({ cmd: 'scan' }); });
  $('#askSkip').addEventListener('click', () => { closeModals(); bridge({ cmd: 'setProtected', value: 'skip' }); bridge({ cmd: 'scan' }); });
  $$('[data-close]').forEach((b) => b.addEventListener('click', closeModals));
  $$('.modal').forEach((m) => m.addEventListener('click', (e) => { if (e.target === m && !['askModal', 'cleanModal'].includes(m.id)) closeModals(); }));
  document.addEventListener('keydown', (e) => { if (e.key === 'Escape' && $('#askModal').classList.contains('hidden') && $('#cleanModal').classList.contains('hidden')) closeModals(); });

  // Treemap + bars: hover tooltip, click to tick.
  const hoverable = '.tm-tile, .bar';
  document.addEventListener('mouseover', (e) => {
    const el = e.target.closest(hoverable);
    if (el && !el.contains(e.relatedTarget)) showTip(e, itemTip(state.items[+el.dataset.i]));
  });
  document.addEventListener('mousemove', (e) => { if (e.target.closest(hoverable)) moveTip(e); });
  document.addEventListener('mouseout', (e) => {
    const el = e.target.closest(hoverable);
    if (el && !el.contains(e.relatedTarget)) hideTip();
  });
  $('#treemap').addEventListener('click', (e) => {
    const t = e.target.closest('.tm-tile');
    if (t) { toggle(state.items[+t.dataset.i].id); updateSelection(); }
  });

  $('#list').addEventListener('click', (e) => {
    const all = e.target.closest('[data-tickall]');
    if (all) {
      const rows = $$('.row').map((r) => state.items[+r.dataset.i]).filter((i) => i.group === all.dataset.tickall);
      const on = !rows.every((i) => state.selected.has(i.id));
      rows.forEach((i) => toggle(i.id, on));
      return updateSelection();
    }
    const row = e.target.closest('.row');
    if (!row) return;
    const it = state.items[+row.dataset.i];
    if (e.target.closest('.path')) { if (it.path.startsWith('/')) bridge({ cmd: 'reveal', path: it.path }); return; }
    if (e.target.matches('input')) { toggle(it.id, e.target.checked); updateSelection(); }
  });

  $$('#groupSeg button').forEach((b) => b.addEventListener('click', () => {
    $$('#groupSeg button').forEach((x) => x.classList.toggle('on', x === b));
    state.group = b.dataset.g;
    renderList(); updateSelection();
  }));
  $('#search').addEventListener('input', (e) => { state.query = e.target.value; renderList(); updateSelection(); });
  $('#clearSel').addEventListener('click', () => { state.selected.clear(); updateSelection(); });
  $('#genBtn').addEventListener('click', openConfirm);
  $('#confirmGo').addEventListener('click', () => { closeModals(); bridge({ cmd: 'clean', ids: state.pending.map((i) => i.id) }); });
  $('#cleanStop').addEventListener('click', (e) => { e.target.disabled = true; e.target.textContent = 'Stopping…'; bridge({ cmd: 'stopClean' }); });
  $('#cleanLogBtn').addEventListener('click', () => bridge({ cmd: 'reveal', path: state.clean.logPath }));
  $('#cleanClose').addEventListener('click', () => { closeModals(); toast('Sizes shown are from before the cleanup. Scan again to refresh.'); });
  $('#cleanRescan').addEventListener('click', () => { closeModals(); requestScan(); });

  // Spotlight cards follow the pointer.
  document.addEventListener('pointermove', (e) => {
    const c = e.target.closest?.('.spot');
    if (!c) return;
    const r = c.getBoundingClientRect();
    c.style.setProperty('--mx', `${e.clientX - r.left}px`);
    c.style.setProperty('--my', `${e.clientY - r.top}px`);
  });

  let rt;
  new ResizeObserver(() => { clearTimeout(rt); rt = setTimeout(() => state.data && (renderTreemap(), updateSelection()), 80); }).observe($('#treemap'));

  bridge({ cmd: 'ready' });
});
