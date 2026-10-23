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
      body.replaceChildren(answer ? markdown(answer.markdown || (answer.status === 'waiting' ? 'Thinking…' : '')) : node('p', 'Waiting for an answer from your Mac.', 'muted'));
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
    $('answer-meta').textContent = answer ? [answer.template, answer.model, ['waiting', 'streaming', 'stopped'].includes(answer.status) ? answer.status : ''].filter(Boolean).join(' · ') : '';
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
  header{display:flex;align-items:center;justify-content:space-between;gap:12px;padding:14px 18px;border-bottom:1px solid #ffffff15;min-height:52px}header strong{font-size:14px;letter-spacing:-.3px;white-space:nowrap}
  #status{font-size:11px;color:#a4a5ab;text-align:right;max-width:70%}#status[data-live=true]{color:#68d699}#status[data-live=true]:before{content:'● ';font-size:9px}
  main{display:flex;flex-direction:column;flex:1;min-height:0}.pane{display:flex;flex-direction:column;min-height:0;min-width:0}.transcript-pane{flex:0 0 44%;border-bottom:1px solid #ffffff20}.answer-pane{flex:1;background:#191a1d}
  .pane-heading{font-size:10px;letter-spacing:1px;color:#92949b;font-weight:650;margin:0;padding:13px 18px 6px}.scroll{overflow:auto;overscroll-behavior:contain;-webkit-overflow-scrolling:touch;flex:1;min-height:0;padding:8px 18px 20px;overflow-wrap:anywhere}
  .transcript-row{display:grid;grid-template-columns:35px 1fr;gap:8px;line-height:1.65;margin-bottom:10px}.speaker{font-size:9px;letter-spacing:.8px;font-weight:750;padding-top:4px}.me{color:#4dd68f}.them{color:#66b8ff}.partial{opacity:.65}
  .answer-heading{display:flex;align-items:center;gap:12px;padding:8px 18px 0;min-height:44px}input[type=range]{min-width:0;width:100%;accent-color:#e0e3ea;height:28px;cursor:pointer;touch-action:pan-x}#page{font-size:11px;color:#a4a5ab;font-variant-numeric:tabular-nums;white-space:nowrap}
  button{font:inherit;font-size:11px;border:1px solid #ffffff22;border-radius:20px;padding:8px 10px;background:#ffffff0d;color:#e5e5e9;white-space:nowrap;min-height:34px}button:disabled{color:#83868d;border-color:transparent;background:transparent}
  #answer-meta{font-size:10px;color:#92949b;margin:0;padding:2px 18px 6px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.markdown{font-size:15px;line-height:1.65}.markdown>*:first-child{margin-top:0}.markdown p{white-space:pre-wrap;margin:0 0 12px}.markdown h2,.markdown h3{font-size:17px;line-height:1.4;margin:16px 0 8px}.markdown h4,.markdown h5,.markdown h6{font-size:15px;margin:14px 0 6px}
  .markdown ul,.markdown ol{padding-left:22px;margin:8px 0 14px}.markdown li{margin:4px 0}.markdown pre{font:12px/1.65 ui-monospace,SFMono-Regular,Menlo,monospace;overflow:auto;overflow-wrap:normal;white-space:pre;background:#101114;border:1px solid #ffffff12;border-radius:9px;padding:12px;tab-size:4;margin:12px 0}.markdown code{font:12px ui-monospace,SFMono-Regular,Menlo,monospace;background:#ffffff0b;border-radius:4px;padding:2px 4px}.markdown blockquote{border-left:2px solid #66b8ff88;color:#b5b7be;padding-left:12px;margin:12px 0}.table-wrap{overflow:auto}table{border-collapse:collapse;font-size:12px;margin:8px 0 14px}td,th{border:1px solid #ffffff20;padding:6px 9px;text-align:left;white-space:nowrap}.muted{font-size:13px;line-height:1.6;color:#92949b}.error{color:#f4ba79}a{color:inherit}
  @media(min-width:750px) and (orientation:landscape){main{flex-direction:row}.transcript-pane{flex:0 0 45%;border-bottom:0;border-right:1px solid #ffffff20}.answer-pane{flex:1}}
  @media(prefers-reduced-motion:reduce){*{scroll-behavior:auto!important}}
  </style></head><body>
  <header><strong>VoxNotch</strong><span id="status" role="status">Connecting…</span></header>
  <main>
    <section class="pane transcript-pane" aria-label="Live transcript"><h1 class="pane-heading">LIVE TRANSCRIPT</h1><div class="scroll" id="transcript"><div id="transcript-body"><p class="muted">Connecting to your Mac…</p></div></div></section>
    <section class="pane answer-pane" aria-label="AI answers"><h2 class="pane-heading">AI ANSWERS</h2><div class="answer-heading"><input id="history" type="range" min="0" max="0" value="0" disabled aria-label="Browse answers"><span id="page">0/0</span><button id="follow" disabled>Following Mac</button></div><p id="answer-meta"></p><div class="scroll markdown" id="answer"><div id="answer-body"><p class="muted">Waiting for an answer from your Mac.</p></div></div></section>
  </main><script>\(javascript)</script></body></html>
  """
}
