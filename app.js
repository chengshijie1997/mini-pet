(function () {
  var PET_LOW_BALANCE = 10; // 余额低于这个数，宠物会担心
  var state = { online: false, stale: false, balance: null, pricing: null, lastSync: 0, error: null };

  // DeepSeek 优惠时段：UTC 16:30 - 00:30，也就是北京时间 00:30 - 08:30
  function offsetMinutes(spec, fallback) {
    var m = /^(\d{1,2}):(\d{2})$/.exec(spec || '');
    if (!m) return fallback;
    return Number(m[1]) * 60 + Number(m[2]);
  }

  function windowBounds(nowMs) {
    var offPeak = (state.pricing && state.pricing.offPeak) || {};
    var startMin = offsetMinutes(offPeak.utcStart, 16 * 60 + 30);
    var endMin = offsetMinutes(offPeak.utcEnd, 30);
    var d = new Date(nowMs);
    var dayStart = Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate());
    var dayMin = nowMs - dayStart;

    var startToday = dayStart + startMin * 60000;
    var endToday = dayStart + (24 * 60 + endMin) * 60000;

    if (dayMin >= startMin * 60000) return { start: startToday, end: endToday, discount: true };
    if (dayMin < endMin * 60000) return { start: startToday - 86400000, end: endToday - 86400000, discount: true };
    return { start: endToday - 86400000, end: startToday, discount: false };
  }

  function clock(ts) {
    return new Date(ts).toLocaleTimeString('zh-CN', { hour12: false, hour: '2-digit', minute: '2-digit' });
  }

  function hms(ms) {
    var total = Math.max(0, Math.round(ms / 1000));
    var h = Math.floor(total / 3600);
    var m = Math.floor((total % 3600) / 60);
    var s = total % 60;
    return (h < 10 ? '0' : '') + h + ':' + (m < 10 ? '0' : '') + m + ':' + (s < 10 ? '0' : '') + s;
  }

  function money(n) {
    return Number(n).toFixed(2);
  }

  var el = function (id) { return document.getElementById(id); };

  function renderPeriod() {
    var now = Date.now();
    var w = windowBounds(now);
    var offPeak = (state.pricing && state.pricing.offPeak) || {};
    var label = w.discount ? (offPeak.label || '优惠时段') : (offPeak.labelStandard || '标准时段');

    el('periodCard').dataset.state = w.discount ? 'discount' : 'standard';
    el('periodBadge').textContent = (w.discount ? '💸 ' : '💳 ') + label;
    el('periodRemain').textContent = hms(w.end - now) + ' 后切换';
    el('periodNow').textContent = '当前段 ' + clock(w.start) + ' - ' + clock(w.end);
    el('periodNext').textContent = '下一切换 ' + clock(w.end);
    el('periodBar').style.width = Math.min(100, Math.max(0, ((now - w.start) / (w.end - w.start)) * 100)).toFixed(1) + '%';
    el('periodNote').textContent = offPeak.note || '北京时间 00:30 - 08:30 为 DeepSeek 优惠时段';
    return w;
  }

  function renderModels(w) {
    var list = el('modelList');
    var models = (state.pricing && state.pricing.models) || [];
    list.innerHTML = '';
    if (!models.length) {
      var empty = document.createElement('li');
      empty.innerHTML = '<span>没读到 pricing.json</span><b>—</b>';
      list.appendChild(empty);
      return;
    }
    models.forEach(function (m) {
      var row = document.createElement('li');
      var name = document.createElement('span');
      name.textContent = m.name;
      var val = document.createElement('b');
      if (w.discount) {
        val.textContent = '省 ' + m.offPeakPct + '% · 实付 ' + (100 - m.offPeakPct) + '%';
        val.style.color = 'var(--good)';
      } else {
        val.textContent = '标准价';
      }
      row.appendChild(name);
      row.appendChild(val);
      list.appendChild(row);
    });
  }

  function renderPet(w) {
    var pet = el('pet');
    var bubble = el('bubble');
    var b = state.balance;
    var offPeakPct = (state.pricing && state.pricing.models && state.pricing.models[0] && state.pricing.models[0].offPeakPct) || 50;
    el('propText').textContent = '-' + offPeakPct + '%';

    if (!state.online) {
      pet.dataset.mood = 'idle';
      bubble.textContent = '还没连上本地服务，余额看不到。时段我照样在数：现在是' + (w.discount ? '优惠时段 💸' : '标准时段') + '。';
      return;
    }
    if (b && !b.ok) {
      pet.dataset.mood = 'worried';
      bubble.textContent = '余额没查出来：' + b.error + ' 现在还是' + (w.discount ? '优惠时段' : '标准时段') + '。';
      return;
    }
    if (b && b.ok && b.total < PET_LOW_BALANCE) {
      pet.dataset.mood = 'worried';
      bubble.textContent = '余额只剩 ' + money(b.total) + ' ' + b.currency + ' 了，记得充值。' + (w.discount ? '好在现在是优惠时段，还能再省一点。' : '');
      return;
    }
    if (w.discount) {
      pet.dataset.mood = 'happy';
      bubble.textContent = '现在是优惠时段，最多能省 ' + offPeakPct + '%，还剩 ' + hms(w.end - Date.now()) + '。';
      return;
    }
    pet.dataset.mood = 'idle';
    bubble.textContent = '现在是标准时段。再过 ' + hms(w.end - Date.now()) + ' 到 ' + clock(w.end) + ' 就是优惠时段了。';
  }

  function renderBalance() {
    var b = state.balance;
    var card = el('balanceCard');
    if (!state.online) {
      card.dataset.state = 'unknown';
      el('balanceNum').textContent = '--';
      el('balanceGranted').textContent = '--';
      el('balanceTopped').textContent = '--';
      el('balanceAvail').textContent = '未连接';
      el('balanceNote').textContent = '双击 启动.cmd 起本地服务，再刷新本页就能读余额。';
      return;
    }
    if (!b || !b.ok) {
      card.dataset.state = 'error';
      el('balanceNum').textContent = '读取失败';
      el('balanceGranted').textContent = '--';
      el('balanceTopped').textContent = '--';
      el('balanceAvail').textContent = '否';
      el('balanceNote').textContent = (b && b.error) || '未知错误';
      return;
    }
    card.dataset.state = 'ok';
    el('balanceNum').textContent = money(b.total);
    el('balanceCur').textContent = b.currency;
    el('balanceGranted').textContent = money(b.granted) + ' ' + b.currency;
    el('balanceTopped').textContent = money(b.toppedUp) + ' ' + b.currency;
    el('balanceAvail').textContent = b.isAvailable ? '可以调用' : '已停用';
    el('balanceNote').textContent = '更新于 ' + new Date(b.checkedAt).toLocaleTimeString('zh-CN', { hour12: false });
  }

  function renderConnection() {
    el('connDot').dataset.state = state.online ? (state.stale ? 'stale' : 'online') : 'offline';
    el('foot').textContent = state.online
      ? '已连本地服务 · 余额每 30 秒自动刷新 · 来源 DeepSeek /user/balance'
      : '未连接本地服务：余额不可用，时段仍按本地时间计算';
  }

  function render() {
    var w = renderPeriod();
    renderModels(w);
    renderBalance();
    renderConnection();
    renderPet(w);
  }

  var refreshing = false;
  function refresh() {
    if (refreshing) return;
    refreshing = true;
    el('refreshBtn').disabled = true;
    fetch('api/status', { cache: 'no-store' })
      .then(function (res) {
        if (!res.ok) throw new Error('HTTP ' + res.status);
        return res.json();
      })
      .then(function (data) {
        state.online = true;
        state.stale = false;
        state.pricing = data.pricing;
        state.balance = data.balance;
        state.lastSync = Date.now();
        state.error = null;
      })
      .catch(function (err) {
        state.error = err.message;
        if (state.online) { state.stale = true; } else { state.online = false; }
      })
      .then(function () {
        refreshing = false;
        el('refreshBtn').disabled = false;
        render();
      });
  }

  el('refreshBtn').addEventListener('click', refresh);

  render();
  refresh();
  setInterval(render, 1000);
  setInterval(refresh, 30000);
})();
