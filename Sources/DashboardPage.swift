/// 控制台页面（单文件 HTML，由 DashboardServer 在 http://localhost 上提供）
enum DashboardPage {
    static let html = #"""
<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>LiveCaption 控制台</title>
<style>
:root {
  --bg: #f4f3ef; --card: #ffffff; --ink: #1d1d1f; --muted: #6e6e73; --line: #e3e1da;
  --accent: #d6402f; --accent-ink: #ffffff; --ok: #1f8a4c; --warn: #b7791f; --soft: #f0eee8;
  --sel: #1d1d1f; --sel-ink: #ffffff;
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg: #161617; --card: #212123; --ink: #f2f2f4; --muted: #9a9aa1; --line: #343437;
    --accent: #ff5a47; --accent-ink: #1a0a08; --ok: #4cc27f; --warn: #e0a84a; --soft: #2a2a2d;
    --sel: #f2f2f4; --sel-ink: #161617;
  }
}
* { box-sizing: border-box; }
[hidden] { display: none !important; }
body {
  margin: 0; background: var(--bg); color: var(--ink);
  font: 15px/1.5 -apple-system, BlinkMacSystemFont, "PingFang SC", "Helvetica Neue", sans-serif;
  -webkit-font-smoothing: antialiased;
}
.wrap { max-width: 1120px; margin: 0 auto; padding: 24px 16px 48px; }
header { display: flex; align-items: center; gap: 12px; margin-bottom: 20px; flex-wrap: wrap; }
h1 { font-size: 20px; margin: 0; letter-spacing: -0.01em; }
h2 { font-size: 13px; font-weight: 600; color: var(--muted); margin: 0 0 12px; letter-spacing: 0.04em; }
.pill { font-size: 12px; font-weight: 600; padding: 3px 10px; border-radius: 999px; background: var(--soft); color: var(--muted); }
.pill.recording { background: var(--accent); color: var(--accent-ink); }
.pill.paused { background: var(--warn); color: #fff; }
.spacer { flex: 1; }
.file { font-size: 13px; color: var(--muted); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; max-width: 100%; }
.card { background: var(--card); border: 1px solid var(--line); border-radius: 14px; padding: 18px; }
.grid { display: grid; grid-template-columns: minmax(0, 1.25fr) minmax(0, 1fr); gap: 16px; margin-top: 16px; align-items: start; }
.col { display: grid; gap: 16px; min-width: 0; }
@media (max-width: 820px) { .grid { grid-template-columns: minmax(0, 1fr); } }

/* 录制区 */
.hero { display: grid; grid-template-columns: auto minmax(0, 1fr); gap: 20px; align-items: center; }
@media (max-width: 600px) { .hero { grid-template-columns: minmax(0, 1fr); } }
.controls { display: flex; flex-direction: column; gap: 8px; min-width: 190px; }
button { font: inherit; color: inherit; cursor: pointer; border: 1px solid var(--line); background: var(--card);
  border-radius: 10px; padding: 8px 14px; }
button:hover { background: var(--soft); }
button:disabled { opacity: 0.45; cursor: default; }
button.primary { background: var(--accent); border-color: var(--accent); color: var(--accent-ink); font-weight: 600;
  font-size: 16px; padding: 12px 18px; }
button.primary:hover { filter: brightness(1.06); background: var(--accent); }
button.small { font-size: 13px; padding: 4px 10px; border-radius: 8px; }
.hint { font-size: 12px; color: var(--muted); }
.meter-row { display: flex; align-items: center; gap: 10px; margin-bottom: 12px; }
.meter { flex: 1; height: 8px; border-radius: 999px; background: var(--soft); overflow: hidden; }
.meter > i { display: block; height: 100%; width: 0; background: var(--ok); border-radius: 999px; transition: width 0.12s linear; }
.meter.dead { outline: 1px dashed var(--warn); outline-offset: 1px; }
.meter-label { font-size: 12px; color: var(--muted); min-width: 118px; text-align: right; font-variant-numeric: tabular-nums; }
.meter-label.bad { color: var(--warn); font-weight: 600; }
.live { background: var(--soft); border-radius: 10px; padding: 12px 14px; height: 168px; overflow-y: auto; }
.live p { margin: 0 0 6px; }
.live time { color: var(--muted); font-size: 12px; margin-right: 8px; font-variant-numeric: tabular-nums; }
.live .partial { color: var(--muted); }
.live .empty { color: var(--muted); }
.banner { margin-bottom: 16px; padding: 12px 14px; border-radius: 12px; border: 1px solid var(--warn);
  display: flex; gap: 12px; align-items: flex-start; white-space: pre-wrap; }
.banner span { flex: 1; }

/* 记录列表 */
.list { display: grid; gap: 2px; max-height: 420px; overflow-y: auto; margin: 0 -8px; }
.rec { display: flex; align-items: center; gap: 10px; padding: 8px; border-radius: 8px; cursor: pointer; min-width: 0; }
.rec:hover, .rec.open { background: var(--soft); }
.rec .name { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.rec .meta { font-size: 12px; color: var(--muted); white-space: nowrap; font-variant-numeric: tabular-nums; }
.badge { font-size: 11px; font-weight: 600; padding: 1px 7px; border-radius: 999px; background: var(--soft); color: var(--muted); white-space: nowrap; }
.badge.on { background: var(--ok); color: #fff; }
.badge.now { background: var(--accent); color: var(--accent-ink); }
.viewer { margin-top: 12px; border-top: 1px solid var(--line); padding-top: 12px; }
.viewer-head { display: flex; align-items: center; gap: 8px; margin-bottom: 8px; flex-wrap: wrap; }
.viewer-head b { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.viewer pre { margin: 0; white-space: pre-wrap; word-break: break-word; font: 14px/1.6 inherit; max-height: 360px;
  overflow-y: auto; background: var(--soft); border-radius: 10px; padding: 12px 14px; }

/* 表单 */
.row { display: flex; align-items: center; gap: 12px; padding: 8px 0; border-top: 1px solid var(--line); flex-wrap: wrap; }
.row:first-of-type { border-top: 0; padding-top: 0; }
.row > label { flex: 1; min-width: 96px; }
select { font: inherit; color: inherit; background: var(--card); border: 1px solid var(--line); border-radius: 8px; padding: 5px 8px; max-width: 100%; }
.seg { display: inline-flex; border: 1px solid var(--line); border-radius: 9px; overflow: hidden; }
.seg button { border: 0; border-radius: 0; padding: 5px 12px; font-size: 13px; background: transparent; }
.seg button + button { border-left: 1px solid var(--line); }
.seg button.on { background: var(--sel); color: var(--sel-ink); }
.choice { display: flex; gap: 10px; align-items: flex-start; padding: 10px; border: 1px solid var(--line); border-radius: 10px;
  cursor: pointer; margin-bottom: 8px; }
.choice.on { border-color: var(--sel); box-shadow: inset 0 0 0 1px var(--sel); }
.choice .dot { width: 14px; height: 14px; border-radius: 50%; border: 2px solid var(--muted); margin-top: 4px; flex: none; }
.choice.on .dot { border-color: var(--sel); background: var(--sel); box-shadow: inset 0 0 0 2px var(--card); }
.choice .body { flex: 1; min-width: 0; }
.choice small { display: block; color: var(--muted); }
.sub { margin: 4px 0 0 0; padding-left: 12px; border-left: 2px solid var(--line); }
.sub.off { opacity: 0.5; }
.switch { position: relative; width: 38px; height: 22px; flex: none; }
.switch input { opacity: 0; width: 100%; height: 100%; margin: 0; cursor: pointer; position: absolute; z-index: 1; }
.switch i { position: absolute; inset: 0; background: var(--line); border-radius: 999px; transition: background 0.15s; }
.switch i::after { content: ""; position: absolute; width: 18px; height: 18px; left: 2px; top: 2px; background: #fff;
  border-radius: 50%; transition: transform 0.15s; box-shadow: 0 1px 2px rgba(0,0,0,0.25); }
.switch input:checked + i { background: var(--ok); }
.switch input:checked + i::after { transform: translateX(16px); }
.switch input:focus-visible + i { outline: 2px solid var(--sel); outline-offset: 2px; }
.status-line { font-size: 13px; color: var(--muted); margin-top: 8px; }
.ai { display: flex; gap: 8px; flex-wrap: wrap; }
.offline { position: fixed; left: 50%; bottom: 20px; transform: translateX(-50%); background: var(--ink); color: var(--bg);
  padding: 8px 16px; border-radius: 999px; font-size: 13px; display: none; }
</style>
</head>
<body>
<div class="wrap">
  <header>
    <h1>LiveCaption</h1>
    <span class="pill" id="pill">空闲</span>
    <span class="spacer"></span>
    <span class="file" id="file"></span>
  </header>

  <div class="banner card" id="banner" hidden><span id="banner-text"></span><button class="small" id="banner-close">知道了</button></div>

  <section class="card">
    <div class="hero">
      <div class="controls" id="controls"></div>
      <div style="min-width:0">
        <div class="meter-row">
          <div class="meter" id="meter"><i></i></div>
          <div class="meter-label" id="meter-label">未在录制</div>
        </div>
        <div class="live" id="live"></div>
      </div>
    </div>
  </section>

  <div class="grid">
    <div class="col">
      <section class="card">
        <h2>之前的记录</h2>
        <div class="list" id="list"></div>
        <div class="viewer" id="viewer" hidden>
          <div class="viewer-head">
            <b id="viewer-name"></b>
            <button class="small" id="viewer-continue">接着写入这个文件</button>
            <button class="small" id="viewer-copy">复制全文</button>
            <button class="small" id="viewer-reveal">在访达中显示</button>
            <button class="small" id="viewer-close">关闭</button>
          </div>
          <pre id="viewer-text"></pre>
        </div>
        <div class="status-line" id="folder"></div>
      </section>
    </div>

    <div class="col">
      <section class="card">
        <h2>识别模型</h2>
        <div id="engines"></div>
      </section>

      <section class="card">
        <h2>设置</h2>
        <div class="row"><label for="source">音频来源</label><select id="source"></select></div>
        <div class="row"><label for="locale">识别语言</label><select id="locale"></select></div>
        <div class="row"><label>字幕字号</label><div class="seg" id="fontSize"></div></div>
        <div class="row"><label>字幕背景</label><div class="seg" id="opacity"></div></div>
        <div class="row"><label for="panelVisible">显示字幕条</label><span class="switch"><input type="checkbox" id="panelVisible"><i></i></span></div>
        <div class="row"><label for="clickThrough">锁定字幕条（鼠标可穿透）</label><span class="switch"><input type="checkbox" id="clickThrough"><i></i></span></div>
        <div class="row"><label for="dashboardOnLaunch">启动时打开控制台</label><span class="switch"><input type="checkbox" id="dashboardOnLaunch"><i></i></span></div>
        <div class="row"><label>字幕条位置</label><button class="small" id="resetPosition">回到默认位置</button></div>
      </section>

      <section class="card">
        <h2 id="ai-title">交给桌面 AI</h2>
        <div class="ai" id="ai"></div>
      </section>
    </div>
  </div>
</div>
<div class="offline" id="offline">LiveCaption 没有在运行，打开应用后这里会自动恢复</div>

<script>
const $ = id => document.getElementById(id);
const el = (tag, cls, text) => { const e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; };
let S = null, openName = null, lastSig = '', lastListSig = '', lastState = '', dismissedError = 0;

async function api(path, body) {
  const options = body ? { method: 'POST', headers: { 'Content-Type': 'application/json', 'X-LiveCaption': '1' }, body: JSON.stringify(body) } : {};
  const response = await fetch(path, options);
  const data = await response.json();
  if (!response.ok) throw new Error(data.error || '请求失败');
  return data;
}
async function act(action, extra) {
  try { render(await api('/api/action', Object.assign({ action }, extra || {}))); loadList(); }
  catch (e) { showBanner(e.message); }
}
async function setting(patch) {
  try { lastSig = ''; render(await api('/api/settings', patch)); }
  catch (e) { showBanner(e.message); }
}
function showBanner(text) { $('banner-text').textContent = text; $('banner').hidden = false; }

function render(state) {
  S = state;
  $('offline').style.display = 'none';

  // 状态
  const busy = state.starting || state.finishing;
  const label = state.finishing ? '正在收尾…' : state.starting ? '正在启动…' : { idle: '空闲', recording: '录制中', paused: '已暂停' }[state.state];
  $('pill').textContent = label;
  $('pill').className = 'pill ' + (state.state === 'idle' ? '' : state.state);
  $('file').textContent = state.currentFile ? '正在写入：' + state.currentFile : '';
  document.title = (state.state === 'recording' ? '● ' : '') + 'LiveCaption 控制台';

  // 按钮（只在状态变化时重建，避免点击时被替换）
  const controlSig = state.state + '|' + busy;
  if (controlSig !== lastState) {
    lastState = controlSig;
    const box = $('controls');
    box.replaceChildren();
    const add = (text, action, primary) => {
      const b = el('button', primary ? 'primary' : '', text);
      b.disabled = state.finishing;
      b.onclick = () => act(action);
      box.append(b);
    };
    if (state.state === 'idle') add('● 开始新记录', 'start', true);
    if (state.state === 'recording') { add('⏸ 暂停', 'pause', true); add('⏹ 结束本次记录', 'end'); }
    if (state.state === 'paused') { add('▶ 继续', 'resume', true); add('⏹ 结束本次记录', 'end'); }
    box.append(el('div', 'hint', '快捷键 ⌥⌘P：开始 / 暂停 / 继续'));
    loadList();
  }

  // 音量条
  const meter = $('meter'), meterLabel = $('meter-label');
  meter.firstElementChild.style.width = (state.running ? Math.round(state.level * 100) : 0) + '%';
  meter.classList.toggle('dead', state.running && !state.receiving);
  meterLabel.classList.toggle('bad', state.running && !state.receiving);
  meterLabel.textContent = !state.running ? '未在录制'
    : !state.receiving ? '没有收到声音'
    : state.level < 0.1 ? '收到的是静音' : '收到声音 ' + Math.round(state.level * 100) + '%';

  // 实时字幕
  const live = $('live');
  const liveSig = state.lineCount + '|' + state.partial + '|' + state.status + '|' + state.state + '|' + (state.lines.length ? state.lines[state.lines.length - 1].text : '');
  if (live.dataset.sig !== liveSig) {
    live.dataset.sig = liveSig;
    const stick = live.scrollHeight - live.scrollTop - live.clientHeight < 40;
    live.replaceChildren();
    for (const line of state.lines) {
      const p = el('p'); p.append(el('time', '', line.time), document.createTextNode(line.text)); live.append(p);
    }
    if (state.partial) live.append(el('p', 'partial', state.partial));
    if (!state.lines.length && !state.partial) {
      live.append(el('p', 'empty', state.status || (state.running ? '正在聆听…请开始说话' : '点「开始新记录」后，字幕会实时显示在这里和屏幕上的字幕条里')));
    } else if (state.status) {
      live.append(el('p', 'empty', state.status));
    }
    if (stick) live.scrollTop = live.scrollHeight;
  }

  // 错误
  if (state.error && state.error.id !== dismissedError) {
    $('banner').dataset.id = state.error.id;
    showBanner(state.error.message);
  }

  // 模型 / 设置（内容没变就不重建，避免下拉框正开着被重置）
  const sig = JSON.stringify([state.settings, state.options, state.whisper, state.ai, state.running]);
  if (sig !== lastSig) { lastSig = sig; renderControls(state); }
}

function renderControls(state) {
  const s = state.settings, o = state.options;

  // 引擎和 Whisper 模型
  const engines = $('engines');
  engines.replaceChildren();
  for (const engine of o.engines) {
    const box = el('div', 'choice' + (engine.id === s.engine ? ' on' : ''));
    box.append(el('span', 'dot'));
    const body = el('div', 'body');
    body.append(el('b', '', engine.name), el('small', '', engine.note));
    box.append(body);
    box.onclick = () => { if (engine.id !== s.engine) setting({ engine: engine.id }); };
    engines.append(box);
  }
  const sub = el('div', 'sub' + (s.engine === 'whisper' ? '' : ' off'));
  for (const model of o.models) {
    const row = el('div', 'rec' + (model.id === s.whisperModel ? ' open' : ''));
    row.append(el('span', 'name', model.name));
    row.append(el('span', 'badge' + (model.loaded ? ' on' : ''), model.loaded ? '已就绪' : model.downloaded ? '已下载' : '未下载'));
    row.onclick = () => { if (model.id !== s.whisperModel) setting({ whisperModel: model.id }); };
    sub.append(row);
  }
  const autoRow = el('div', 'row');
  const autoLabel = el('label', '', '自动检测语言（多种语言混着说时打开）');
  autoLabel.htmlFor = 'whisperAuto';
  autoRow.append(autoLabel, makeSwitch('whisperAuto', s.whisperAuto));
  sub.append(autoRow);
  const current = o.models.find(m => m.id === s.whisperModel);
  const preload = el('button', 'small', current && current.loaded ? '模型已就绪 ✓' : state.whisper.loading ? '正在准备…' : current && current.downloaded ? '提前加载模型' : '提前下载并加载模型');
  preload.disabled = (current && current.loaded) || state.whisper.loading;
  preload.onclick = () => act('preloadWhisper');
  sub.append(preload);
  if (state.whisper.status) sub.append(el('div', 'status-line', state.whisper.status));
  engines.append(sub);

  // 下拉框
  fillSelect($('source'), o.sources, s.source);
  fillSelect($('locale'), o.languages.map(l => ({ id: l.id, name: l.name + (l.supported ? '' : '（系统识别不支持）') })), s.locale);
  fillSeg($('fontSize'), o.fontSizes, s.fontSize, v => setting({ fontSize: v }));
  fillSeg($('opacity'), o.opacities, s.opacity, v => setting({ opacity: v }));
  for (const key of ['panelVisible', 'clickThrough', 'dashboardOnLaunch']) $(key).checked = !!s[key];

  // AI
  $('ai-title').textContent = '交给桌面 AI' + (state.ai.app ? '（' + state.ai.app + '）' : '');
  const ai = $('ai');
  ai.replaceChildren();
  for (const request of state.ai.requests) {
    const b = el('button', 'small', request);
    b.onclick = () => act('sendToAI', { request });
    ai.append(b);
  }
}

function makeSwitch(id, checked) {
  const wrap = el('span', 'switch');
  const input = el('input'); input.type = 'checkbox'; input.id = id; input.checked = checked;
  input.onchange = () => setting({ [id]: input.checked });
  wrap.append(input, el('i'));
  return wrap;
}
function fillSelect(select, items, value) {
  if (document.activeElement === select) return;
  select.replaceChildren();
  for (const item of items) { const opt = el('option', '', item.name); opt.value = item.id; select.append(opt); }
  select.value = value;
}
function fillSeg(box, items, value, onPick) {
  box.replaceChildren();
  for (const item of items) {
    const b = el('button', Math.abs(item.value - value) < 0.001 ? 'on' : '', item.name);
    b.onclick = () => onPick(item.value);
    box.append(b);
  }
}

// 记录列表
async function loadList() {
  let data;
  try { data = await api('/api/recordings'); } catch (e) { return; }
  const sig = JSON.stringify(data.recordings) + '|' + openName;
  if (sig === lastListSig) return;
  lastListSig = sig;
  const list = $('list');
  list.replaceChildren();
  if (!data.recordings.length) list.append(el('div', 'rec', '还没有记录。开始一次新记录后会出现在这里。'));
  for (const rec of data.recordings) {
    const row = el('div', 'rec' + (rec.name === openName ? ' open' : ''));
    row.append(el('span', 'name', rec.name));
    if (rec.active) row.append(el('span', 'badge now', '进行中'));
    row.append(el('span', 'meta', rec.modified + ' · ' + (rec.size < 1024 ? rec.size + ' B' : (rec.size / 1024).toFixed(1) + ' KB')));
    row.onclick = () => openRecording(rec.name);
    list.append(row);
  }
  if (S) $('folder').textContent = '保存位置：' + S.folder;
  if (openName && data.recordings.some(r => r.name === openName && r.active)) openRecording(openName, true);
}
async function openRecording(name, quiet) {
  try {
    const data = await api('/api/recording?name=' + encodeURIComponent(name));
    openName = name;
    $('viewer-name').textContent = data.name;
    const pre = $('viewer-text');
    const stick = quiet && pre.scrollHeight - pre.scrollTop - pre.clientHeight < 40;
    pre.textContent = data.text;
    if (stick) pre.scrollTop = pre.scrollHeight;
    $('viewer').hidden = false;
    $('viewer-continue').disabled = !S || S.state !== 'idle';
    if (!quiet) { lastListSig = ''; loadList(); }
  } catch (e) { if (!quiet) showBanner(e.message); }
}

$('viewer-close').onclick = () => { openName = null; $('viewer').hidden = true; lastListSig = ''; loadList(); };
$('viewer-continue').onclick = () => act('continue', { name: openName });
$('viewer-reveal').onclick = () => act('reveal', { name: openName });
$('viewer-copy').onclick = async () => {
  try { await navigator.clipboard.writeText($('viewer-text').textContent); $('viewer-copy').textContent = '已复制 ✓'; }
  catch (e) { $('viewer-copy').textContent = '复制失败'; }
  setTimeout(() => { $('viewer-copy').textContent = '复制全文'; }, 1500);
};
$('banner-close').onclick = () => {
  dismissedError = Number($('banner').dataset.id || 0);
  $('banner').hidden = true;
  if (dismissedError) api('/api/action', { action: 'dismissError' }).catch(() => {});
};
$('source').onchange = e => setting({ source: e.target.value });
$('locale').onchange = e => setting({ locale: e.target.value });
$('resetPosition').onclick = () => act('resetPosition');
for (const key of ['panelVisible', 'clickThrough', 'dashboardOnLaunch']) $(key).onchange = e => setting({ [key]: e.target.checked });

async function poll() {
  try { render(await api('/api/state')); }
  catch (e) { $('offline').style.display = 'block'; }
  setTimeout(poll, document.hidden ? 2000 : 300);
}
poll();
setInterval(loadList, 4000);
</script>
</body>
</html>
"""#
}
