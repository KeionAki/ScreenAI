(function () {
  'use strict';
  var $ = function (id) { return document.getElementById(id); };
  var store = {
    get: function (k, d) { try { var v = localStorage.getItem(k); return v === null ? d : JSON.parse(v); } catch (e) { return d; } },
    set: function (k, v) { try { localStorage.setItem(k, JSON.stringify(v)); } catch (e) {} },
    del: function (k) { try { localStorage.removeItem(k); } catch (e) {} }
  };

  var token = store.get('screenai_token', null);
  var keep = store.get('screenai_keep', 100);
  var sound = store.get('screenai_sound', true);
  var newestTop = store.get('screenai_newest_top', true);
  var ws = null, connected = false, manualClose = false, reconnectTimer = null, reconnectIndex = 0;
  var RECONNECT_DELAYS = [2000, 5000, 10000, 30000];
  var cards = {}; // id -> {el, body, badge, text, kind}
  var order = []; // ids in insertion order
  var audioCtx = null;
  var currentView = 'live';
  var secure = window.isSecureContext === true;
  var wakeOn = store.get('screenai_wake', true);
  var wakeLock = null;
  var wsFailures = 0;
  var certGuideDismissed = false;

  // ---------- helpers ----------
  function pad(n) { return (n < 10 ? '0' : '') + n; }
  function fmtTime(ms) { var d = new Date(ms); return pad(d.getHours()) + ':' + pad(d.getMinutes()) + ':' + pad(d.getSeconds()); }
  function fmtDateTime(ms) { var d = new Date(ms); return d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate()) + ' ' + fmtTime(ms); }
  function el(tag, cls, text) { var e = document.createElement(tag); if (cls) e.className = cls; if (text !== undefined) e.textContent = text; return e; }
  function setStatus(state, text) {
    var dot = $('statusDot');
    dot.className = 'dot ' + state;
    $('statusText').textContent = text;
  }
  function copyText(text) {
    if (navigator.clipboard && navigator.clipboard.writeText) {
      return navigator.clipboard.writeText(text).catch(function () { return legacyCopy(text); });
    }
    return Promise.resolve(legacyCopy(text));
  }
  function legacyCopy(text) {
    var ta = document.createElement('textarea');
    ta.value = text; ta.setAttribute('readonly', ''); ta.style.position = 'fixed'; ta.style.top = '-1000px';
    document.body.appendChild(ta);
    ta.select(); ta.setSelectionRange(0, text.length);
    var ok = false;
    try { ok = document.execCommand('copy'); } catch (e) {}
    document.body.removeChild(ta);
    return ok;
  }
  function unlockAudio() {
    try {
      var AC = window.AudioContext || window.webkitAudioContext;
      if (!AC) return;
      if (!audioCtx) audioCtx = new AC();
      if (audioCtx.state === 'suspended') audioCtx.resume();
      var o = audioCtx.createOscillator(), g = audioCtx.createGain();
      g.gain.value = 0.0001; o.connect(g); g.connect(audioCtx.destination); o.start(); o.stop(audioCtx.currentTime + 0.05);
    } catch (e) {}
  }
  function beep() {
    if (!sound || !audioCtx) return;
    try {
      if (audioCtx.state === 'suspended') audioCtx.resume();
      var t = audioCtx.currentTime;
      [[880, 0], [1320, 0.12]].forEach(function (p) {
        var o = audioCtx.createOscillator(), g = audioCtx.createGain();
        o.type = 'sine'; o.frequency.value = p[0];
        g.gain.setValueAtTime(0.0001, t + p[1]);
        g.gain.exponentialRampToValueAtTime(0.25, t + p[1] + 0.01);
        g.gain.exponentialRampToValueAtTime(0.0001, t + p[1] + 0.14);
        o.connect(g); g.connect(audioCtx.destination);
        o.start(t + p[1]); o.stop(t + p[1] + 0.16);
      });
    } catch (e) {}
  }

  // ---------- wake lock ----------
  function requestWakeLock() {
    if (!secure || !wakeOn || !connected || !('wakeLock' in navigator) || wakeLock) return;
    navigator.wakeLock.request('screen').then(function (lock) {
      wakeLock = lock;
      lock.addEventListener('release', function () { wakeLock = null; });
    }).catch(function () {});
  }
  function releaseWakeLock() {
    if (wakeLock) { try { wakeLock.release(); } catch (e) {} wakeLock = null; }
  }

  // ---------- certificate guide ----------
  function maybeShowCertGuide() {
    if (!secure || certGuideDismissed || wsFailures < 2) return;
    fetch('/api/status', { cache: 'no-store' }).then(function (r) {
      if (r.ok) $('certGuide').classList.remove('hidden');
    }).catch(function () {});
  }

  // ---------- views ----------
  function showView(name) {
    currentView = name;
    $('viewPair').classList.toggle('hidden', name !== 'pair');
    $('viewLive').classList.toggle('hidden', name !== 'live');
    $('viewHistory').classList.toggle('hidden', name !== 'history');
    $('tabs').classList.toggle('hidden', name === 'pair');
    var tabs = document.querySelectorAll('.tab');
    for (var i = 0; i < tabs.length; i++) tabs[i].classList.toggle('active', tabs[i].getAttribute('data-view') === name);
    if (name === 'history') loadHistory(true);
  }

  // ---------- cards ----------
  function insertCard(elem) {
    var list = $('liveList');
    if (newestTop) list.insertBefore(elem, list.firstChild); else list.appendChild(elem);
    $('liveEmpty').classList.add('hidden');
    if (!newestTop) window.scrollTo(0, document.body.scrollHeight);
  }
  function makeCard(id, kind, source, ts) {
    var card = el('div', 'card ' + kind);
    var meta = el('div', 'meta');
    var time = el('span', 'time', fmtTime(ts || Date.now()));
    var src = el('span', 'src', source || '');
    var badge = el('span', 'badge');
    meta.appendChild(time); meta.appendChild(src); meta.appendChild(badge);
    var body = el('div', 'body');
    var actions = el('div', 'actions');
    var copyBtn = el('button', '', '复制');
    copyBtn.addEventListener('click', function () {
      var rec = cards[id];
      copyText(rec ? rec.text : body.textContent).then(function () { copyBtn.textContent = '已复制'; setTimeout(function () { copyBtn.textContent = '复制'; }, 1200); });
    });
    actions.appendChild(copyBtn);
    card.appendChild(meta); card.appendChild(body); card.appendChild(actions);
    var rec = { el: card, body: body, badge: badge, time: time, text: '', kind: kind };
    if (id) { cards[id] = rec; order.push(id); }
    setBadge(rec, kind);
    insertCard(card);
    trimCards();
    return rec;
  }
  function setBadge(rec, kind) {
    rec.kind = kind;
    rec.el.className = 'card ' + kind + (kind === 'new' ? ' new' : '');
    if (kind === 'pending') { rec.badge.className = 'badge pending'; rec.badge.textContent = '分析中'; }
    else if (kind === 'success' || kind === 'new') { rec.badge.className = 'badge ok'; rec.badge.textContent = '完成'; rec.el.className = 'card success' + (kind === 'new' ? ' new' : ''); }
    else if (kind === 'error') { rec.badge.className = 'badge err'; rec.badge.textContent = '错误'; }
    else if (kind === 'status') { rec.badge.className = 'badge'; rec.badge.textContent = '提示'; }
  }
  function renderPending(rec) {
    rec.body.innerHTML = '';
    var sp = el('span', 'spinner');
    rec.body.appendChild(sp);
    if (rec.text) { rec.body.appendChild(document.createTextNode(rec.text)); rec.body.appendChild(el('span', 'cursor')); }
    else rec.body.appendChild(document.createTextNode(rec.note || '正在分析截图…'));
  }
  function trimCards() {
    var max = Math.max(10, keep | 0);
    while (order.length > max) {
      var oldestId = newestTop ? order[0] : order[0];
      var rec = cards[oldestId];
      if (rec && rec.kind === 'pending') break;
      order.shift();
      if (rec) { if (rec.el.parentNode) rec.el.parentNode.removeChild(rec.el); delete cards[oldestId]; }
    }
  }
  function clearLive() {
    cards = {}; order = [];
    $('liveList').innerHTML = '';
    $('liveEmpty').classList.remove('hidden');
  }

  // ---------- messages ----------
  function handleMessage(m) {
    switch (m.type) {
      case 'auth_ok':
        connected = true; reconnectIndex = 0; wsFailures = 0;
        setStatus('on', '已连接');
        $('certGuide').classList.add('hidden');
        requestWakeLock();
        break;
      case 'auth_failed':
        unpair('登录已失效，请重新输入验证码');
        break;
      case 'heartbeat':
        send({ type: 'pong' });
        break;
      case 'analysis_started': {
        var rec = cards[m.id];
        if (!rec) rec = makeCard(m.id, 'pending', m.capture_source, m.timestamp);
        rec.text = ''; rec.note = ''; rec.time.textContent = fmtTime(m.timestamp || Date.now());
        setBadge(rec, 'pending'); renderPending(rec);
        break;
      }
      case 'analysis_thinking': {
        var rt = cards[m.id];
        if (!rt) rt = makeCard(m.id, 'pending', '', Date.now());
        if (!rt.text) { rt.note = '思考中… ' + (m.chars || 0) + ' 字'; renderPending(rt); }
        break;
      }
      case 'analysis_partial': {
        var r = cards[m.id];
        if (!r) r = makeCard(m.id, 'pending', '', Date.now());
        r.text += (m.delta || '');
        r.note = '';
        renderPending(r);
        break;
      }
      case 'analysis_result': {
        var rr = cards[m.id];
        if (!rr) rr = makeCard(m.id, 'success', m.capture_source, m.timestamp);
        rr.text = m.result || '';
        rr.body.textContent = rr.text;
        rr.time.textContent = fmtTime(m.timestamp || Date.now());
        setBadge(rr, 'new');
        var latency = m.latency_ms ? ' · ' + (m.latency_ms / 1000).toFixed(1) + 's' : '';
        rr.badge.textContent = '完成' + latency;
        setTimeout(function () { if (rr.kind === 'new') setBadge(rr, 'success'); rr.badge.textContent = '完成' + latency; }, 4000);
        beep();
        break;
      }
      case 'error': {
        var re = m.id ? cards[m.id] : null;
        if (!re) re = makeCard(m.id || ('e' + Date.now()), 'error', m.capture_source, m.timestamp);
        re.text = m.error_message || '未知错误';
        re.body.textContent = re.text;
        setBadge(re, 'error');
        break;
      }
      case 'status_change': {
        var rs = makeCard('s' + (m.id || Date.now()), 'status', '', m.timestamp);
        rs.text = m.message || '';
        rs.body.textContent = rs.text;
        setBadge(rs, 'status');
        break;
      }
      default: break;
    }
  }

  // ---------- websocket ----------
  function send(obj) { if (ws && ws.readyState === 1) { try { ws.send(JSON.stringify(obj)); } catch (e) {} } }
  function connect() {
    if (!token) { showView('pair'); return; }
    if (ws && (ws.readyState === 0 || ws.readyState === 1)) return;
    clearTimeout(reconnectTimer);
    manualClose = false;
    setStatus('wait', '连接中…');
    var proto = location.protocol === 'https:' ? 'wss://' : 'ws://';
    try { ws = new WebSocket(proto + location.host + '/ws'); } catch (e) { scheduleReconnect(); return; }
    var opened = false;
    ws.onopen = function () { opened = true; send({ type: 'auth', token: token }); };
    ws.onmessage = function (ev) { var m; try { m = JSON.parse(ev.data); } catch (e) { return; } handleMessage(m); };
    ws.onclose = function (ev) {
      connected = false;
      ws = null;
      releaseWakeLock();
      if (manualClose || !token) return;
      if (ev && (ev.code === 4003 || ev.code === 4001)) { unpair('登录已失效，请重新输入验证码'); return; }
      if (!opened) { wsFailures++; maybeShowCertGuide(); }
      setStatus('off', '已断开，重连中…');
      scheduleReconnect();
    };
    ws.onerror = function () {};
  }
  function scheduleReconnect() {
    clearTimeout(reconnectTimer);
    var delay = RECONNECT_DELAYS[Math.min(reconnectIndex, RECONNECT_DELAYS.length - 1)];
    reconnectIndex++;
    reconnectTimer = setTimeout(connect, delay);
  }
  function disconnect() {
    manualClose = true;
    clearTimeout(reconnectTimer);
    if (ws) { try { ws.close(); } catch (e) {} ws = null; }
    connected = false;
  }
  function unpair(msg) {
    disconnect();
    token = null; store.del('screenai_token');
    setStatus('off', '未连接');
    $('pairError').textContent = msg || '';
    showView('pair');
  }

  // ---------- pairing ----------
  function pair() {
    var code = ($('codeInput').value || '').replace(/\D/g, '');
    if (code.length !== 6) { $('pairError').textContent = '请输入 6 位验证码'; return; }
    unlockAudio();
    $('connectBtn').disabled = true;
    $('pairError').textContent = '';
    fetch('/api/auth', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ code: code }) })
      .then(function (r) { return r.json().then(function (j) { return { ok: r.ok, j: j }; }); })
      .then(function (res) {
        $('connectBtn').disabled = false;
        if (res.j && res.j.success && res.j.token) {
          token = res.j.token; store.set('screenai_token', token);
          $('codeInput').value = '';
          showView('live');
          connect();
        } else {
          $('pairError').textContent = (res.j && res.j.error) || '验证失败';
        }
      })
      .catch(function () { $('connectBtn').disabled = false; $('pairError').textContent = '无法连接到 Mac，请确认在同一 Wi‑Fi 且地址正确'; });
  }

  // ---------- history ----------
  var historyLoadedDates = false;
  function api(path) {
    return fetch(path, { headers: { 'Authorization': 'Bearer ' + token } }).then(function (r) {
      if (r.status === 401) { unpair('登录已失效，请重新输入验证码'); throw new Error('unauthorized'); }
      return r.json();
    });
  }
  function loadHistory(refreshDates) {
    if (!token) return;
    if (refreshDates || !historyLoadedDates) {
      api('/api/history/dates').then(function (j) {
        historyLoadedDates = true;
        var sel = $('dateSelect'); var cur = sel.value;
        sel.innerHTML = '<option value="">最近</option>';
        (j.dates || []).forEach(function (d) { var o = document.createElement('option'); o.value = d; o.textContent = d; sel.appendChild(o); });
        sel.value = cur;
      }).catch(function () {});
    }
    var date = $('dateSelect').value, q = $('searchInput').value || '';
    var url = '/api/history?limit=300' + (date ? '&date=' + encodeURIComponent(date) : '') + (q ? '&q=' + encodeURIComponent(q) : '');
    api(url).then(function (j) {
      var list = $('historyList'); list.innerHTML = '';
      var recs = j.records || [];
      $('historyEmpty').classList.toggle('hidden', recs.length > 0);
      var lastDay = '';
      recs.forEach(function (r) {
        var day = fmtDateTime(r.timestamp).slice(0, 10);
        if (day !== lastDay) { list.appendChild(el('div', 'hint small', day)); lastDay = day; }
        var card = el('div', 'card ' + (r.status === 'success' ? 'success' : 'error'));
        var meta = el('div', 'meta');
        meta.appendChild(el('span', 'time', fmtTime(r.timestamp)));
        meta.appendChild(el('span', 'src', r.capture_source || ''));
        var b = el('span', 'badge ' + (r.status === 'success' ? 'ok' : 'err'), r.status === 'success' ? (r.model || '完成') : '错误');
        meta.appendChild(b);
        var body = el('div', 'body', r.status === 'success' ? (r.result || '') : (r.error_message || r.result || ''));
        body.style.maxHeight = '4.5em'; body.style.overflow = 'hidden';
        card.addEventListener('click', function () { body.style.maxHeight = body.style.maxHeight ? '' : '4.5em'; });
        var actions = el('div', 'actions');
        var cp = el('button', '', '复制');
        cp.addEventListener('click', function (ev) { ev.stopPropagation(); copyText(r.result || r.error_message || '').then(function () { cp.textContent = '已复制'; setTimeout(function () { cp.textContent = '复制'; }, 1200); }); });
        actions.appendChild(cp);
        card.appendChild(meta); card.appendChild(body); card.appendChild(actions);
        list.appendChild(card);
      });
    }).catch(function () {});
  }
  function exportHistory() {
    if (!token) return;
    var date = $('dateSelect').value;
    var url = '/api/history/export' + (date ? '?from=' + date + '&to=' + date : '');
    fetch(url, { headers: { 'Authorization': 'Bearer ' + token } }).then(function (r) { return r.blob(); }).then(function (blob) {
      var a = document.createElement('a');
      a.href = URL.createObjectURL(blob);
      a.download = 'screenai-history' + (date ? '-' + date : '') + '.csv';
      document.body.appendChild(a); a.click(); document.body.removeChild(a);
      setTimeout(function () { URL.revokeObjectURL(a.href); }, 5000);
    }).catch(function () { window.open(url + (url.indexOf('?') > 0 ? '&' : '?') + 'token=' + encodeURIComponent(token), '_blank'); });
  }

  // ---------- settings sheet ----------
  function openSettings() {
    $('keepInput').value = keep;
    $('soundToggle').checked = !!sound;
    $('newestTopToggle').checked = !!newestTop;
    $('wakeToggle').checked = !!wakeOn;
    $('wakeRow').classList.toggle('hidden', !(secure && ('wakeLock' in navigator)));
    $('aboutLine').textContent = 'ScreenAI · ' + location.host + (secure ? ' · HTTPS' : ' · HTTP') + (token ? ' · 已配对' : ' · 未配对');
    $('settingsSheet').classList.remove('hidden');
  }
  function closeSettings() {
    var k = parseInt($('keepInput').value, 10);
    if (!isNaN(k)) { keep = Math.min(500, Math.max(10, k)); store.set('screenai_keep', keep); }
    sound = $('soundToggle').checked; store.set('screenai_sound', sound);
    var nt = $('newestTopToggle').checked;
    if (nt !== newestTop) {
      newestTop = nt; store.set('screenai_newest_top', newestTop);
      var list = $('liveList'); var items = Array.prototype.slice.call(list.children).reverse();
      list.innerHTML = ''; items.forEach(function (c) { list.appendChild(c); });
    }
    wakeOn = $('wakeToggle').checked; store.set('screenai_wake', wakeOn);
    if (wakeOn) requestWakeLock(); else releaseWakeLock();
    if (sound) unlockAudio();
    trimCards();
    $('settingsSheet').classList.add('hidden');
  }

  // ---------- wiring ----------
  $('connectBtn').addEventListener('click', pair);
  $('codeInput').addEventListener('keydown', function (e) { if (e.key === 'Enter') pair(); });
  $('codeInput').addEventListener('input', function () { var v = this.value.replace(/\D/g, '').slice(0, 6); if (v !== this.value) this.value = v; if (v.length === 6) pair(); });
  $('settingsBtn').addEventListener('click', openSettings);
  $('closeSettingsBtn').addEventListener('click', closeSettings);
  $('settingsSheet').addEventListener('click', function (e) { if (e.target === this) closeSettings(); });
  $('clearLiveBtn').addEventListener('click', function () { clearLive(); closeSettings(); });
  $('unpairBtn').addEventListener('click', function () { closeSettings(); unpair(''); });
  $('dateSelect').addEventListener('change', function () { loadHistory(false); });
  $('searchInput').addEventListener('change', function () { loadHistory(false); });
  $('searchInput').addEventListener('keydown', function (e) { if (e.key === 'Enter') { loadHistory(false); this.blur(); } });
  $('exportBtn').addEventListener('click', exportHistory);
  var tabs = document.querySelectorAll('.tab');
  for (var i = 0; i < tabs.length; i++) tabs[i].addEventListener('click', function () { unlockAudio(); showView(this.getAttribute('data-view')); });
  $('certRetryBtn').addEventListener('click', function () { $('certGuide').classList.add('hidden'); wsFailures = 0; reconnectIndex = 0; disconnect(); connect(); });
  $('certLaterBtn').addEventListener('click', function () { certGuideDismissed = true; $('certGuide').classList.add('hidden'); });
  document.addEventListener('visibilitychange', function () {
    if (document.hidden) return;
    if (token && !connected) { reconnectIndex = 0; connect(); } else { requestWakeLock(); }
  });
  window.addEventListener('online', function () { if (token && !connected) { reconnectIndex = 0; connect(); } });
  window.addEventListener('pageshow', function () { if (token && !connected) connect(); });

  var standalone = window.navigator.standalone === true || (window.matchMedia && window.matchMedia('(display-mode: standalone)').matches);
  if (!standalone && /iPhone|iPad/.test(navigator.userAgent)) $('installHint').classList.remove('hidden');

  if (secure) {
    $('certLink').classList.remove('hidden');
    if ('serviceWorker' in navigator) {
      navigator.serviceWorker.register('/sw.js').catch(function () {});
    }
  } else {
    fetch('/api/status', { cache: 'no-store' }).then(function (r) { return r.json(); }).then(function (st) {
      if (st && st.https_port) {
        var u = 'https://' + location.hostname + ':' + st.https_port + '/';
        $('httpsLink').textContent = u; $('httpsLink').href = u;
        $('httpsHint').classList.remove('hidden');
      }
    }).catch(function () {});
  }

  if (token) { showView('live'); connect(); } else { showView('pair'); setStatus('off', '未连接'); }
})();
