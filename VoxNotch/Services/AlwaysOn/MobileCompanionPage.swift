import Foundation

/// Self-contained page: no CDN, analytics, external fonts or remote resources.
nonisolated enum MobileCompanionPage {
  static let javascript = #"""
  'use strict';
  const $ = id => document.getElementById(id);
  const node = (tag, text, className) => {
    const element = document.createElement(tag);
    if (text !== undefined) element.textContent = text;
    if (className) element.className = className;
    return element;
  };
  function inline(parent, text) {
    const pattern = /(`[^`]+`|\*\*[^*]+\*\*|\*[^*]+\*)/g;
    let last = 0;
    for (const match of text.matchAll(pattern)) {
      parent.append(document.createTextNode(text.slice(last, match.index)));
      const token = match[0];
      const size = token.startsWith('**') ? 2 : 1;
      parent.append(node(token[0] === '`' ? 'code' : size === 2 ? 'strong' : 'em', token.slice(size, -size)));
      last = match.index + token.length;
    }
    parent.append(document.createTextNode(text.slice(last)));
  }
  // Render text through DOM nodes, never innerHTML. Model output is untrusted.
  function markdown(text) {
    const result = document.createDocumentFragment();
    const lines = text.replace(/\r\n/g, '\n').split('\n');
    let code = null, fence = null, list = null, paragraph = [];
    const flush = () => {
      if (paragraph.length) {
        const p = node('p'); inline(p, paragraph.join('\n')); result.append(p); paragraph = [];
      }
      list = null;
    };
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i];
      const marker = line.match(/^\s{0,3}(`{3,}|~{3,})(.*)$/);
      if (code) {
        if (marker && marker[1][0] === fence[0] && marker[1].length >= fence.length && !marker[2].trim()) {
          result.append(node('pre', code.join('\n'))); code = null; fence = null;
        } else code.push(line);
        continue;
      }
      if (marker) { flush(); code = []; fence = marker[1]; continue; }
      if (!line.trim()) { flush(); continue; }
      const heading = line.match(/^(#{1,6})\s+(.*)$/);
      if (heading) { flush(); const h = node('h' + Math.min(heading[1].length + 1, 6)); inline(h, heading[2]); result.append(h); continue; }
      if (i + 1 < lines.length && line.includes('|') && /^\s*\|?\s*:?-{3,}/.test(lines[i + 1])) {
        flush(); const wrap = node('div', undefined, 'table-wrap'), table = node('table');
        const cells = row => row.trim().replace(/^\|/, '').replace(/\|$/, '').split('|');
        const appendRow = (row, tag) => {
          const tr = node('tr'); cells(row).forEach(value => { const td = node(tag); inline(td, value.trim()); tr.append(td); }); table.append(tr);
        };
        appendRow(line, 'th'); i++;
        while (i + 1 < lines.length && lines[i + 1].includes('|') && lines[i + 1].trim()) appendRow(lines[++i], 'td');
        wrap.append(table); result.append(wrap); continue;
      }
      const item = line.match(/^\s*(?:([-+*])|\d+[.)])\s+(.*)$/);
      if (item) {
        if (paragraph.length) flush();
        const tag = item[1] ? 'ul' : 'ol';
        if (!list || list.localName !== tag) { list = node(tag); result.append(list); }
        const li = node('li'); inline(li, item[2]); list.append(li); continue;
      }
      if (line.startsWith('> ')) { flush(); const quote = node('blockquote'); inline(quote, line.slice(2)); result.append(quote); continue; }
      list = null; paragraph.push(line);
    }
    flush(); if (code) result.append(node('pre', code.join('\n')));
    return result;
  }

  let snapshot = null, selectedID = null, sessionID = null;
  let transcriptSignature = null, answerSignature = null;
  const nearBottom = pane => pane.scrollHeight - pane.scrollTop - pane.clientHeight < 64;
  const scrolls = new Map();
  function displayedAnswer() {
    return snapshot?.answers.find(a => a.id === (selectedID || snapshot.displayedAnswerID)) || snapshot?.answers.at(-1);
  }
  function renderAnswer() {
    const answer = displayedAnswer(), pane = $('answer'), body = $('answer-body');
    const signature = JSON.stringify(answer || null);
    const changedPage = body.dataset.answerId !== answer?.id;
    const followingBottom = nearBottom(pane);
    if (changedPage && body.dataset.answerId) scrolls.set(body.dataset.answerId, pane.scrollTop);
    if (signature !== answerSignature) {
      body.replaceChildren(answer ? markdown(answer.markdown || (answer.status === 'waiting' ? (answer.retryCount > 0 ? 'Retrying…' : 'Thinking…') : '')) : node('p', 'Waiting for an answer from your Mac.', 'muted'));
      if (answer?.error) body.append(node('p', answer.error, 'error'));
      body.dataset.answerId = answer?.id || '';
      answerSignature = signature;
      if (changedPage) pane.scrollTop = scrolls.get(answer?.id) || 0;
      else if (followingBottom) pane.scrollTop = pane.scrollHeight;
    }
    const count = snapshot?.answers.length || 0;
    const index = snapshot?.answers.findIndex(a => a.id === answer?.id) ?? -1;
    $('page').textContent = count ? `${index + 1}/${count}` : '0/0';
    $('history').max = Math.max(count - 1, 0); $('history').value = Math.max(index, 0); $('history').disabled = count < 2;
    $('history').setAttribute('aria-valuetext', `Answer ${index + 1} of ${count}`);
    $('follow').textContent = selectedID ? 'Follow Mac' : 'Following Mac';
    $('follow').disabled = !selectedID;
    $('answer-meta').textContent = answer ? [answer.template, answer.model, answer.status === 'waiting' && answer.retryCount > 0 ? 'retrying' : (['waiting', 'streaming', 'stopped'].includes(answer.status) ? answer.status : '')].filter(Boolean).join(' · ') : '';
  }
  function applySnapshot(value) {
    if (sessionID !== value.sessionID) {
      selectedID = null; scrolls.clear(); transcriptSignature = null; answerSignature = null;
      $('transcript').scrollTop = 0; $('answer-body').dataset.answerId = '';
    }
    sessionID = value.sessionID; snapshot = value;
    if (selectedID && !value.answers.some(a => a.id === selectedID)) selectedID = null;
    for (const id of scrolls.keys()) if (!value.answers.some(a => a.id === id)) scrolls.delete(id);
    $('status').textContent = value.message; $('status').dataset.live = value.status === 'running' && !value.isPaused ? 'true' : 'false';
    const signature = JSON.stringify(value.transcript);
    if (signature !== transcriptSignature) {
      const pane = $('transcript'), shouldFollow = nearBottom(pane), rows = document.createDocumentFragment();
      value.transcript.forEach(row => {
        const line = node('div', undefined, 'transcript-row' + (row.isFinal ? '' : ' partial'));
        const me = row.source === 'microphone';
        line.append(node('span', me ? 'ME' : 'THEM', me ? 'speaker me' : 'speaker them'), node('span', row.text)); rows.append(line);
      });
      if (!value.transcript.length) rows.append(node('p', value.message === 'Paused' ? 'Listening is paused on your Mac.' : 'Waiting for speech…', 'muted'));
      $('transcript-body').replaceChildren(rows); transcriptSignature = signature;
      if (shouldFollow) pane.scrollTop = pane.scrollHeight;
    }
    renderAnswer();
  }
  $('history').addEventListener('input', event => {
    selectedID = snapshot?.answers[Number(event.target.value)]?.id || null; renderAnswer();
  });
  $('follow').addEventListener('click', () => { selectedID = null; renderAnswer(); });
  $('history').addEventListener('dblclick', () => { selectedID = null; renderAnswer(); });
  function clearContent(message) {
    snapshot = null; selectedID = null; sessionID = null; answerSignature = null; transcriptSignature = null; scrolls.clear();
    $('transcript-body').replaceChildren(node('p', message, 'muted'));
    $('answer-body').replaceChildren(node('p', 'Reconnect to see answers.', 'muted'));
    $('answer-meta').textContent = ''; $('page').textContent = '0/0'; $('history').disabled = true;
    $('follow').disabled = true; $('status').textContent = message; $('status').dataset.live = 'false';
  }

  // Each device owns its layout. Rotating or entering iPad Split View keeps a
  // separate split for stacked and side-by-side panes.
  const panes = $('panes'), divider = $('pane-divider'), layoutMode = $('layout-mode');
  const defaults = {mode: 'auto', x: 0.45, y: 0.44};
  let layout = {...defaults}, drag = null;
  try {
    const saved = JSON.parse(localStorage.getItem('voxnotchMobileLayout') || 'null');
    if (saved && ['auto', 'stacked', 'columns'].includes(saved.mode)) {
      layout.mode = saved.mode;
      for (const axis of ['x', 'y']) if (Number.isFinite(saved[axis])) layout[axis] = Math.min(0.8, Math.max(0.2, saved[axis]));
    }
  } catch (_) { /* Layout still works when browser storage is unavailable. */ }
  layoutMode.value = layout.mode;
  const saveLayout = () => { try { localStorage.setItem('voxnotchMobileLayout', JSON.stringify(layout)); } catch (_) {} };
  function splitBounds(axis) {
    const rect = panes.getBoundingClientRect(), handle = divider.getBoundingClientRect();
    const available = Math.max(1, axis === 'x' ? rect.width - handle.width : rect.height - handle.height);
    const minimum = Math.min(0.45, Math.max(0.2, (axis === 'x' ? 180 : 120) / available));
    return {available, minimum, maximum: 1 - minimum};
  }
  function setSplit(axis, value, remember = true) {
    const bounds = splitBounds(axis);
    const fraction = Math.min(bounds.maximum, Math.max(bounds.minimum, value));
    if (remember) layout[axis] = fraction;
    panes.style.setProperty('--split-' + axis, String(fraction));
    divider.setAttribute('aria-valuemin', Math.round(bounds.minimum * 100));
    divider.setAttribute('aria-valuemax', Math.round(bounds.maximum * 100));
    divider.setAttribute('aria-valuenow', Math.round(fraction * 100));
    divider.setAttribute('aria-valuetext', `Transcript ${Math.round(fraction * 100)} percent`);
  }
  function updateLayout() {
    const wide = panes.clientWidth >= 600;
    const columns = wide && (layout.mode === 'columns' || (layout.mode === 'auto' && matchMedia('(min-width:750px) and (orientation:landscape)').matches));
    const axis = columns ? 'x' : 'y';
    panes.dataset.axis = axis;
    divider.setAttribute('aria-orientation', columns ? 'vertical' : 'horizontal');
    setSplit(axis, layout[axis], false);
  }
  function finishDrag(commit) {
    if (!drag) return;
    const previous = drag; drag = null;
    panes.classList.remove('resizing');
    if (divider.hasPointerCapture(previous.id)) divider.releasePointerCapture(previous.id);
    if (!commit) setSplit(previous.axis, previous.preference);
    else saveLayout();
  }
  divider.addEventListener('pointerdown', event => {
    if (drag || !event.isPrimary || event.button !== 0) return;
    const axis = panes.dataset.axis;
    drag = {id: event.pointerId, axis, coordinate: axis === 'x' ? event.clientX : event.clientY,
            fraction: Number(panes.style.getPropertyValue('--split-' + axis)), preference: layout[axis], available: splitBounds(axis).available};
    divider.setPointerCapture(event.pointerId);
    panes.classList.add('resizing');
    event.preventDefault();
  });
  divider.addEventListener('pointermove', event => {
    if (!drag || drag.id !== event.pointerId) return;
    const coordinate = drag.axis === 'x' ? event.clientX : event.clientY;
    setSplit(drag.axis, drag.fraction + (coordinate - drag.coordinate) / drag.available);
    event.preventDefault();
  });
  divider.addEventListener('pointerup', event => { if (drag?.id === event.pointerId) finishDrag(true); });
  divider.addEventListener('pointercancel', event => { if (drag?.id === event.pointerId) finishDrag(false); });
  divider.addEventListener('lostpointercapture', () => finishDrag(false));
  divider.addEventListener('keydown', event => {
    const axis = panes.dataset.axis, bounds = splitBounds(axis);
    const keys = axis === 'x' ? ['ArrowLeft', 'ArrowRight'] : ['ArrowUp', 'ArrowDown'];
    let value = Number(panes.style.getPropertyValue('--split-' + axis));
    if (event.key === keys[0]) value -= event.shiftKey ? 0.1 : 0.02;
    else if (event.key === keys[1]) value += event.shiftKey ? 0.1 : 0.02;
    else if (event.key === 'Home') value = bounds.minimum;
    else if (event.key === 'End') value = bounds.maximum;
    else return;
    event.preventDefault(); setSplit(axis, value); saveLayout();
  });
  function resetSplit() { finishDrag(false); setSplit(panes.dataset.axis, defaults[panes.dataset.axis]); saveLayout(); }
  divider.addEventListener('dblclick', resetSplit);
  $('reset-split').addEventListener('click', resetSplit);
  layoutMode.addEventListener('change', () => { finishDrag(false); layout.mode = layoutMode.value; updateLayout(); saveLayout(); });
  window.addEventListener('resize', () => { finishDrag(false); updateLayout(); });
  new ResizeObserver(updateLayout).observe(panes);
  updateLayout();

  let token = location.hash.slice(1);
  if (token) { history.replaceState(null, '', location.pathname); }
  try {
    if (/^[A-Za-z0-9_-]{43}$/.test(token)) sessionStorage.setItem('voxnotchMobileToken', token);
    else token = sessionStorage.getItem('voxnotchMobileToken') || '';
  } catch (_) { /* Private browsing can disable storage; the current tab still works. */ }
  let etag = null, timer = null, busy = false, ended = false, failures = 0;
  async function poll() {
    if (busy || ended || document.hidden) return;
    if (!/^[A-Za-z0-9_-]{43}$/.test(token)) { clearContent('Scan the QR code on your Mac to connect.'); return; }
    busy = true; const controller = new AbortController(), timeout = setTimeout(() => controller.abort(), 4000);
    try {
      const headers = {Authorization: 'Bearer ' + token}; if (etag) headers['If-None-Match'] = etag;
      const response = await fetch('/api/state', {headers, cache: 'no-store', credentials: 'omit', signal: controller.signal});
      if ([401, 403].includes(response.status)) {
        ended = true; try { sessionStorage.removeItem('voxnotchMobileToken'); } catch (_) {}
        clearContent('Connection ended. Scan a new QR code on your Mac.'); return;
      }
      if (response.status === 200) { applySnapshot(await response.json()); etag = response.headers.get('ETag'); }
      else if (response.status !== 304) throw new Error('Connection interrupted');
      failures = 0;
    } catch (_) {
      failures++; etag = null; clearContent('Reconnecting… Check that your Mac is awake and on the same Wi-Fi.');
    } finally {
      clearTimeout(timeout); busy = false;
      if (!ended) timer = setTimeout(poll, Math.min(400 * 2 ** failures, 5000));
    }
  }
  document.addEventListener('visibilitychange', () => { clearTimeout(timer); if (!document.hidden) poll(); });
  window.VoxNotchMobile = {applySnapshot, markdown, displayedAnswer, clearContent};
  poll();
  """#

  static let html = """
  <!doctype html>
  <html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
  <meta name="color-scheme" content="dark"><meta name="referrer" content="no-referrer"><title>VoxNotch · Live</title>
  <style>
  :root{color-scheme:dark;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;background:#111214;color:#f5f5f7;font-size:15px}
  *{box-sizing:border-box}body{margin:0;height:100vh;height:100dvh;display:flex;flex-direction:column;padding:env(safe-area-inset-top) env(safe-area-inset-right) env(safe-area-inset-bottom) env(safe-area-inset-left)}
  header{display:flex;align-items:center;justify-content:space-between;gap:10px;padding:10px 18px;border-bottom:1px solid #ffffff15;min-height:52px;flex-shrink:0}header strong{font-size:14px;letter-spacing:-.3px;white-space:nowrap}
  .view-controls{display:flex;align-items:center;gap:5px;flex-shrink:0}#layout-mode{font:inherit;font-size:11px;color:#d4d6dc;background:#24262b;border:1px solid #ffffff20;border-radius:8px;padding:7px 5px;min-height:34px;max-width:105px}#reset-split{font-size:17px;padding:4px 8px;min-width:34px;border-radius:8px}
  #status{font-size:11px;color:#a4a5ab;text-align:right;min-width:0;overflow-wrap:anywhere}#status[data-live=true]{color:#68d699}#status[data-live=true]:before{content:'● ';font-size:9px}
  main{--divider-size:28px;--split-y:.44;--split-x:.45;display:flex;flex-direction:column;flex:1;min-height:0;min-width:0}.pane{display:flex;flex-direction:column;min-height:0;min-width:0}.transcript-pane{flex:0 0 calc((100% - var(--divider-size)) * var(--split-y))}.answer-pane{flex:1;background:#191a1d}
  #pane-divider{flex:0 0 var(--divider-size);display:flex;align-items:center;justify-content:center;cursor:row-resize;touch-action:none;outline:none;background:#151619;border-block:1px solid #ffffff12}#pane-divider:before{content:'';width:38px;height:4px;border-radius:4px;background:#63666e}#pane-divider:hover:before,#pane-divider:focus-visible:before,.resizing #pane-divider:before{background:#66b8ff}.resizing{user-select:none;-webkit-user-select:none}
  main[data-axis=x]{flex-direction:row}main[data-axis=x] .transcript-pane{flex-basis:calc((100% - var(--divider-size)) * var(--split-x))}main[data-axis=x] #pane-divider{cursor:col-resize;border-block:0;border-inline:1px solid #ffffff12}main[data-axis=x] #pane-divider:before{height:38px;width:4px}
  .pane-heading{font-size:10px;letter-spacing:1px;color:#92949b;font-weight:650;margin:0;padding:13px 18px 6px}.scroll{overflow:auto;overscroll-behavior:contain;-webkit-overflow-scrolling:touch;flex:1;min-height:0;padding:8px 18px 20px;overflow-wrap:anywhere}
  .transcript-row{display:grid;grid-template-columns:35px 1fr;gap:8px;line-height:1.65;margin-bottom:10px}.speaker{font-size:9px;letter-spacing:.8px;font-weight:750;padding-top:4px}.me{color:#4dd68f}.them{color:#66b8ff}.partial{opacity:.65}
  .answer-heading{display:flex;align-items:center;gap:12px;padding:8px 18px 0;min-height:44px}input[type=range]{min-width:0;width:100%;accent-color:#e0e3ea;height:28px;cursor:pointer;touch-action:pan-x}#page{font-size:11px;color:#a4a5ab;font-variant-numeric:tabular-nums;white-space:nowrap}
  button{font:inherit;font-size:11px;border:1px solid #ffffff22;border-radius:20px;padding:8px 10px;background:#ffffff0d;color:#e5e5e9;white-space:nowrap;min-height:34px}button:disabled{color:#83868d;border-color:transparent;background:transparent}
  #answer-meta{font-size:10px;color:#92949b;margin:0;padding:2px 18px 6px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.markdown{font-size:15px;line-height:1.65}.markdown>*:first-child{margin-top:0}.markdown p{white-space:pre-wrap;margin:0 0 12px}.markdown h2,.markdown h3{font-size:17px;line-height:1.4;margin:16px 0 8px}.markdown h4,.markdown h5,.markdown h6{font-size:15px;margin:14px 0 6px}
  .markdown ul,.markdown ol{padding-left:22px;margin:8px 0 14px}.markdown li{margin:4px 0}.markdown pre{font:12px/1.65 ui-monospace,SFMono-Regular,Menlo,monospace;overflow:auto;overflow-wrap:normal;white-space:pre;background:#101114;border:1px solid #ffffff12;border-radius:9px;padding:12px;tab-size:4;margin:12px 0}.markdown code{font:12px ui-monospace,SFMono-Regular,Menlo,monospace;background:#ffffff0b;border-radius:4px;padding:2px 4px}.markdown blockquote{border-left:2px solid #66b8ff88;color:#b5b7be;padding-left:12px;margin:12px 0}.table-wrap{overflow:auto}table{border-collapse:collapse;font-size:12px;margin:8px 0 14px}td,th{border:1px solid #ffffff20;padding:6px 9px;text-align:left;white-space:nowrap}.muted{font-size:13px;line-height:1.6;color:#92949b}.error{color:#f4ba79}a{color:inherit}
  @media(min-width:700px){:root,.markdown{font-size:16px}.pane-heading{font-size:11px}.scroll{padding-inline:22px}header{padding-inline:22px}}
  @media(prefers-reduced-motion:reduce){*{scroll-behavior:auto!important}}
  </style></head><body>
  <header><strong>VoxNotch</strong><div class="view-controls"><select id="layout-mode" aria-label="Pane layout"><option value="auto">Auto layout</option><option value="stacked">Stacked</option><option value="columns">Side by side</option></select><button id="reset-split" aria-label="Reset pane sizes" title="Reset pane sizes">↺</button></div><span id="status" role="status">Connecting…</span></header>
  <main id="panes" data-axis="y">
    <section class="pane transcript-pane" aria-label="Live transcript"><h1 class="pane-heading">LIVE TRANSCRIPT</h1><div class="scroll" id="transcript"><div id="transcript-body"><p class="muted">Connecting to your Mac…</p></div></div></section>
    <div id="pane-divider" role="separator" tabindex="0" aria-label="Resize transcript and answers" aria-controls="transcript answer" aria-orientation="horizontal" aria-valuemin="20" aria-valuemax="80" aria-valuenow="44"></div>
    <section class="pane answer-pane" aria-label="AI answers"><h2 class="pane-heading">AI ANSWERS</h2><div class="answer-heading"><input id="history" type="range" min="0" max="0" value="0" disabled aria-label="Browse answers"><span id="page">0/0</span><button id="follow" disabled>Following Mac</button></div><p id="answer-meta"></p><div class="scroll markdown" id="answer"><div id="answer-body"><p class="muted">Waiting for an answer from your Mac.</p></div></div></section>
  </main><script>\(javascript)</script></body></html>
  """
}
