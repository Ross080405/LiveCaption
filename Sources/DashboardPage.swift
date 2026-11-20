/// 控制台页面（单文件 HTML，由 DashboardServer 在 http://localhost 上提供；应用主窗口里显示的也是它）
///
/// 设计思路：
/// - 一屏只有一件主要的事：没在记录时是「开始」，记录时是正在出现的字幕。
/// - 之前的记录收在左侧的「记录库」里，默认收起；打开一份就是全幅的阅读视图（渲染 Markdown）。
/// - 设置收在右侧抽屉里；每次都可能要改的（音频来源、语言）留在开始按钮旁边。
/// - 名字不挡路：可以先起名再开始，也可以按规则自动起名，之后随时点标题改名。
enum DashboardPage {
    static let html = #"""
<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>LiveCaption</title>
<link rel="icon" type="image/png" href="/icon.png">
<style>
/* 视觉语言：柔和的填充色块代替描边，大圆角 / 胶囊形，无衬线字体靠字重和灰度分层，只有一个强调色 */
:root {
  --bg: #f4f4f5; --panel: #ececee; --card: #ffffff; --fill: #e9e9ec; --hover: #dfdfe3;
  --ink: #111113; --muted: #6c6c73; --faint: #a3a3ab; --line: rgba(0, 0, 0, 0.07);
  --accent: #ef5f1a; --accent-ink: #ffffff; --rec: #f0443a; --ok: #1f9d57; --warn: #c27c12;
  --shadow: 0 18px 50px rgba(20, 20, 30, 0.16), 0 2px 6px rgba(20, 20, 30, 0.06);
  --r-s: 12px; --r-m: 18px; --r-l: 26px;
  --ui: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Inter", "PingFang SC", "PingFang TC", "Helvetica Neue", sans-serif;
  --serif: "New York", ui-serif, "Iowan Old Style", Charter, "Songti SC", "STSong", Georgia, serif;
  --mono: ui-monospace, "SF Mono", Menlo, monospace;
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg: #0d0d0e; --panel: #131314; --card: #1c1c1e; --fill: #222224; --hover: #2c2c2f;
    --ink: #f3f3f4; --muted: #9b9ba2; --faint: #63636a; --line: rgba(255, 255, 255, 0.07);
    --accent: #f26a1f; --accent-ink: #ffffff; --rec: #ff5146; --ok: #3ecf7c; --warn: #e5a53a;
    --shadow: 0 18px 50px rgba(0, 0, 0, 0.6), 0 0 0 1px rgba(255, 255, 255, 0.05);
  }
}
* { box-sizing: border-box; }
[hidden] { display: none !important; }
html { scroll-padding-top: 80px; }
body { margin: 0; background: var(--bg); color: var(--ink); font: 16px/1.55 var(--ui); letter-spacing: -0.003em;
  -webkit-font-smoothing: antialiased; text-rendering: optimizeLegibility; }
button, input, select { font: inherit; color: inherit; letter-spacing: inherit; }
button { cursor: pointer; border: 0; background: var(--fill); border-radius: 999px; padding: 8px 16px; font-size: 14px; font-weight: 500;
  transition: background 0.15s ease, transform 0.12s ease, opacity 0.15s ease; }
button:hover { background: var(--hover); }
button:active { transform: scale(0.97); }
button:disabled { opacity: 0.4; cursor: default; transform: none; }
button:focus-visible, input:focus-visible, select:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; }
button.ghost { background: transparent; color: var(--muted); }
button.ghost:hover { background: var(--fill); color: var(--ink); }
button.icon { background: transparent; padding: 0; width: 38px; height: 38px; display: inline-grid; place-items: center; color: var(--muted); }
button.icon:hover { background: var(--fill); color: var(--ink); }
button.icon svg { width: 19px; height: 19px; fill: none; stroke: currentColor; stroke-width: 1.7; stroke-linecap: round; stroke-linejoin: round; }
button.link { padding: 0; background: none; color: var(--muted); font-size: inherit; font-weight: inherit; border-radius: 6px; }
button.link:hover { color: var(--ink); background: none; }
button.primary { background: var(--accent); color: var(--accent-ink); font-weight: 600; }
button.primary:hover { background: var(--accent); filter: brightness(1.08); }
kbd { font: 500 12px var(--ui); color: var(--muted); background: var(--fill); border-radius: 7px; padding: 2px 7px; }

/* 骨架：左侧记录库（默认收起）+ 主区 */
.app { display: grid; grid-template-columns: 0 minmax(0, 1fr); min-height: 100vh; transition: grid-template-columns 0.26s cubic-bezier(0.3, 0.7, 0.2, 1); }
.app.lib-open { grid-template-columns: 324px minmax(0, 1fr); }
.lib { position: sticky; top: 0; height: 100vh; overflow: hidden; visibility: hidden; padding: 10px 0 10px 10px; }
.app.lib-open .lib { visibility: visible; }
.lib-inner { width: 314px; height: 100%; display: flex; flex-direction: column; background: var(--panel); border-radius: var(--r-l); overflow: hidden; }
.lib-head { display: flex; gap: 6px; padding: 12px 10px 6px 12px; align-items: center; }
.lib-head input { flex: 1; min-width: 0; border: 0; background: var(--fill); border-radius: 999px; padding: 9px 16px; font-size: 14px; }
.lib-head input::placeholder { color: var(--faint); }
.lib-list { flex: 1; overflow-y: auto; padding: 0 8px 12px; scrollbar-width: thin; }
.lib-group { font-size: 12px; font-weight: 600; color: var(--faint); padding: 16px 12px 6px; }
.rec { display: block; width: 100%; text-align: left; background: transparent; border-radius: var(--r-m); padding: 10px 12px; font-size: 15px; }
.rec:hover { background: var(--fill); }
.rec:active { transform: none; }
.rec.on { background: var(--hover); }
.rec b { display: flex; gap: 7px; align-items: center; font-weight: 600; letter-spacing: -0.01em; }
.rec b span { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.rec b i { flex: none; width: 8px; height: 8px; border-radius: 50%; background: var(--rec); }
.rec small { display: block; color: var(--muted); font-size: 13px; font-weight: 400; margin-top: 1px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.rec small time { font-variant-numeric: tabular-nums; margin-right: 7px; color: var(--faint); }
.lib-empty { color: var(--muted); font-size: 14px; padding: 18px 12px; }
.lib-foot { padding: 10px 20px 14px; font-size: 12px; color: var(--faint); }
@media (max-width: 900px) {
  .app, .app.lib-open { grid-template-columns: 0 minmax(0, 1fr); }
  .lib { position: fixed; z-index: 30; left: 0; width: 324px; max-width: 90vw; transform: translateX(-104%); transition: transform 0.26s cubic-bezier(0.3, 0.7, 0.2, 1); }
  .lib-inner { width: 100%; box-shadow: var(--shadow); }
  .app.lib-open .lib { transform: none; }
}

.main { min-width: 0; display: flex; flex-direction: column; }
.top { position: sticky; top: 0; z-index: 10; display: flex; align-items: center; gap: 8px; padding: 10px 16px;
  background: color-mix(in srgb, var(--bg) 82%, transparent); backdrop-filter: saturate(1.6) blur(18px); -webkit-backdrop-filter: saturate(1.6) blur(18px); }
.brand { display: flex; align-items: center; gap: 8px; font-weight: 600; font-size: 16px; letter-spacing: -0.015em; }
.brand img { border-radius: 8px; }
.spacer { flex: 1; }
.chip { display: inline-flex; align-items: center; gap: 8px; font-size: 13px; font-weight: 600; padding: 7px 14px; font-variant-numeric: tabular-nums; }
.dot { width: 9px; height: 9px; border-radius: 50%; background: var(--faint); flex: none; }
.dot.recording { background: var(--rec); box-shadow: 0 0 0 0 var(--rec); animation: pulse 1.8s ease-out infinite; }
.dot.paused { background: var(--warn); }
@keyframes pulse { 0% { box-shadow: 0 0 0 0 color-mix(in srgb, var(--rec) 55%, transparent); } 100% { box-shadow: 0 0 0 9px transparent; } }
@media (prefers-reduced-motion: reduce) { .dot.recording { animation: none; } .app, .lib, .sheet, button { transition: none !important; } }

.notice { margin: 6px auto 0; width: min(720px, calc(100% - 32px)); border-radius: var(--r-m); padding: 14px 16px 14px 18px;
  display: flex; gap: 12px; align-items: center; white-space: pre-wrap; background: color-mix(in srgb, var(--warn) 14%, var(--card)); font-size: 14px; }
.notice > div, .notice > span { flex: 1; min-width: 0; }
.notice small { display: block; color: var(--muted); }
a.button { text-decoration: none; background: var(--accent); color: var(--accent-ink); font-weight: 600; font-size: 14px; border-radius: 999px; padding: 8px 16px; white-space: nowrap; }
body.is-offline .view { opacity: 0.4; pointer-events: none; }

.view { flex: 1; width: min(780px, 100%); margin: 0 auto; padding: 0 20px 96px; }

/* 空闲：只有「开始」 */
.stage { min-height: calc(100vh - 160px); display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 22px; text-align: center; }
.title-input { width: min(520px, 100%); border: 0; background: var(--fill); text-align: center; border-radius: 999px;
  font: 600 20px/1.4 var(--ui); letter-spacing: -0.02em; padding: 14px 24px; margin-bottom: 8px; }
.title-input::placeholder { color: var(--faint); font-weight: 500; }
.record { width: 104px; height: 104px; border-radius: 50%; background: var(--card); padding: 0; display: grid; place-items: center;
  box-shadow: 0 10px 30px color-mix(in srgb, var(--rec) 26%, transparent), 0 0 0 1px var(--line); }
.record:hover { background: var(--card); transform: scale(1.05); }
.record:active { transform: scale(0.96); }
.record i { width: 68px; height: 68px; border-radius: 50%; background: var(--rec); transition: border-radius 0.2s ease, transform 0.2s ease; }
.record:hover i { transform: scale(0.94); }
.stage-label { font-size: 20px; font-weight: 600; letter-spacing: -0.02em; margin-top: -4px; display: flex; align-items: center; gap: 10px; }
.quick { display: flex; gap: 8px; flex-wrap: wrap; justify-content: center; }
.quick select { appearance: none; -webkit-appearance: none; border: 0; background: var(--fill); border-radius: 999px;
  padding: 8px 18px; font-size: 14px; font-weight: 500; max-width: 250px; text-overflow: ellipsis; cursor: pointer; transition: background 0.15s ease; }
.quick select:hover { background: var(--hover); }
.name-hint { font-size: 14px; color: var(--muted); }
.name-hint code { font: 500 13px var(--ui); color: var(--ink); }
.stage-foot { margin-top: 14px; font-size: 14px; min-height: 22px; }

/* 记录中 */
.session { position: sticky; top: 58px; z-index: 9; margin: 0 -8px; padding: 6px 8px 0; background: var(--bg); }
.session-card { background: var(--card); border-radius: var(--r-l); padding: 14px 14px 12px 20px; box-shadow: 0 0 0 1px var(--line); }
.session-row { display: flex; align-items: center; gap: 12px; flex-wrap: wrap; }
.session-title { flex: 1; min-width: 120px; font: 600 19px/1.3 var(--ui); letter-spacing: -0.02em; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; cursor: text;
  border-radius: 10px; padding: 3px 8px; margin-left: -8px; }
.session-title:hover { background: var(--fill); }
.clock { font-variant-numeric: tabular-nums; color: var(--muted); font-size: 15px; font-weight: 500; }
.session-status { font-size: 13px; color: var(--muted); margin-top: 4px; min-height: 0; }
.session-status:empty { display: none; }
.session-status.bad { color: var(--warn); font-weight: 600; }
.meter { height: 4px; border-radius: 999px; background: var(--fill); margin: 12px 6px 0 0; overflow: hidden; }
.meter i { display: block; height: 100%; width: 0; border-radius: 999px; background: var(--ok); transition: width 0.12s linear; }
.meter.dead i { width: 100% !important; background: var(--warn); opacity: 0.6; }
.title-edit { width: 100%; font: inherit; letter-spacing: inherit; border: 0; background: transparent; padding: 0; }
.title-edit:focus { outline: none; }
.live-foot { display: flex; gap: 6px; flex-wrap: wrap; align-items: center; margin-top: 28px; font-size: 14px; color: var(--muted); }
.live-foot span { margin-right: 4px; }
.latest { position: fixed; bottom: 24px; left: 50%; transform: translateX(-50%); z-index: 12; background: var(--ink); color: var(--bg); padding: 10px 20px; font-weight: 600; box-shadow: var(--shadow); }
.latest:hover { background: var(--ink); opacity: 0.9; }
.latest:active { transform: translateX(-50%) scale(0.97); }

/* 正文排版（字幕和 Markdown 共用） */
.doc { font: 16.5px/1.7 var(--ui); padding-top: 22px; overflow-wrap: break-word; }
body.serif .doc { font: 17.5px/1.75 var(--serif); letter-spacing: 0; }
.doc h1 { font-size: 28px; line-height: 1.25; letter-spacing: -0.025em; margin: 0.4em 0 0.6em; }
.doc h2 { font-size: 21px; letter-spacing: -0.02em; margin: 1.6em 0 0.5em; }
.doc h3 { font-size: 18px; letter-spacing: -0.015em; margin: 1.4em 0 0.4em; }
.doc h4, .doc h5, .doc h6 { font-size: 16px; margin: 1.2em 0 0.3em; }
.doc > :first-child { margin-top: 0; }
.doc p { margin: 0 0 0.9em; }
.doc ul, .doc ol { margin: 0 0 0.9em; padding-left: 1.4em; }
.doc li { margin: 0.2em 0; }
.doc li::marker { color: var(--faint); }
.doc li.task { list-style: none; margin-left: -1.3em; }
.doc li.task input { accent-color: var(--accent); }
.doc blockquote { margin: 0 0 0.9em; padding: 12px 18px; border-radius: var(--r-m); background: var(--fill); color: var(--muted); }
.doc blockquote > :last-child { margin-bottom: 0; }
.doc hr { border: 0; height: 1px; background: var(--line); margin: 1.8em 0; }
.doc a { color: var(--accent); text-decoration: none; }
.doc a:hover { text-decoration: underline; text-underline-offset: 3px; }
.doc code { font: 0.86em var(--mono); background: var(--fill); border-radius: 7px; padding: 0.15em 0.42em; }
.doc pre { background: var(--fill); border-radius: var(--r-m); padding: 14px 18px; overflow-x: auto; margin: 0 0 0.9em; }
.doc pre code { background: none; padding: 0; font-size: 13px; line-height: 1.6; }
.doc table { border-collapse: separate; border-spacing: 0; font-size: 14.5px; line-height: 1.5; margin: 0 0 1em; display: block; overflow-x: auto; }
.doc th, .doc td { padding: 8px 14px; text-align: left; border-bottom: 1px solid var(--line); }
.doc th { background: var(--fill); font-weight: 600; border-bottom: 0; }
.doc th:first-child { border-radius: var(--r-s) 0 0 var(--r-s); }
.doc th:last-child { border-radius: 0 var(--r-s) var(--r-s) 0; }
.doc .cue { display: grid; grid-template-columns: 66px minmax(0, 1fr); gap: 8px; margin: 0 0 0.5em; }
.doc .cue time { font: 500 12px/2.4 var(--ui); color: var(--faint); font-variant-numeric: tabular-nums; user-select: none; -webkit-user-select: none; }
.doc .cue p { margin: 0; }
.doc .quiet, .doc .cue.partial p { color: var(--muted); }
body.no-time .doc .cue { grid-template-columns: minmax(0, 1fr); }
body.no-time .doc .cue time { display: none; }
.doc .sep { display: flex; justify-content: center; margin: 1.4em 0; }
.doc .sep::before { content: none; }
.doc .sep { font-size: 12px; font-weight: 500; color: var(--muted); }
.doc .sep { width: fit-content; margin-left: auto; margin-right: auto; background: var(--fill); border-radius: 999px; padding: 4px 14px; }
@media (max-width: 560px) {
  .doc .cue { grid-template-columns: minmax(0, 1fr); gap: 0; }
  .doc .cue time { line-height: 1.4; }
}

/* 实时字幕：一句一个气泡 */
#live-doc { padding-top: 18px; }
#live-doc .cue { margin-bottom: 8px; align-items: start; }
#live-doc .cue p { justify-self: start; background: var(--card); border-radius: 20px; padding: 10px 18px; box-shadow: 0 0 0 1px var(--line); }
#live-doc .cue time { line-height: 3.7; text-align: right; padding-right: 2px; }
#live-doc .cue.partial p { background: transparent; box-shadow: inset 0 0 0 1.5px var(--line); color: var(--muted); }
#live-doc .quiet { text-align: center; padding: 40px 0; font-size: 15px; }

/* 阅读视图 */
.reader-bar { position: sticky; top: 58px; z-index: 9; background: var(--bg); display: flex; align-items: center; gap: 2px; flex-wrap: wrap; margin: 0 -8px; padding: 6px 8px 10px; }
.reader-bar button { padding: 7px 13px; }
.reader-card { background: var(--card); border-radius: var(--r-l); padding: 30px 36px 36px; box-shadow: 0 0 0 1px var(--line); }
@media (max-width: 560px) { .reader-card { padding: 22px 20px 26px; } }
.reader-meta { color: var(--faint); font-size: 13px; font-weight: 500; font-variant-numeric: tabular-nums; }
.reader-title { font: 700 30px/1.2 var(--ui); letter-spacing: -0.03em; margin: 6px 0 0 -8px; padding: 2px 8px; cursor: text; border-radius: 12px; overflow-wrap: break-word; }
.reader-title.editable:hover { background: var(--fill); }
button.danger:hover { color: var(--rec); }
.editor { display: block; width: 100%; min-height: 55vh; margin-top: 22px; border: 0; resize: none; overflow: hidden; background: var(--fill); color: var(--ink);
  border-radius: var(--r-m); padding: 18px 20px; font: 15.5px/1.75 var(--ui); letter-spacing: inherit; tab-size: 2; }
.editor:focus { outline: none; box-shadow: inset 0 0 0 2px color-mix(in srgb, var(--accent) 55%, transparent); }
button.toggle.on { color: var(--ink); background: var(--fill); }

/* 设置：浮在右侧的圆角面板 */
.scrim { position: fixed; inset: 0; z-index: 40; background: rgba(0, 0, 0, 0.36); backdrop-filter: blur(3px); -webkit-backdrop-filter: blur(3px); }
.sheet { position: fixed; z-index: 41; top: 10px; right: 10px; bottom: 10px; width: min(440px, calc(100vw - 20px)); background: var(--bg); border-radius: var(--r-l);
  box-shadow: var(--shadow); overflow-y: auto; padding: 16px 16px 32px; scrollbar-width: thin; }
.sheet-head { display: flex; align-items: center; padding: 0 0 0 10px; }
.sheet-head b { flex: 1; font-size: 20px; font-weight: 700; letter-spacing: -0.025em; }
.sheet h2 { font-size: 13px; font-weight: 600; color: var(--muted); margin: 22px 10px 8px; }
.group { background: var(--card); border-radius: var(--r-m); padding: 4px 16px; box-shadow: 0 0 0 1px var(--line); }
.row { display: flex; align-items: center; gap: 12px; padding: 12px 0; border-top: 1px solid var(--line); flex-wrap: wrap; font-size: 15px; min-height: 52px; }
.group > .row:first-child { border-top: 0; }
.row > label, .row > span.label { flex: 1; min-width: 96px; }
.sheet select { appearance: none; -webkit-appearance: none; border: 0; background: var(--fill); border-radius: 999px; padding: 7px 16px; font-size: 14px; font-weight: 500; max-width: 100%; cursor: pointer; text-overflow: ellipsis; }
.sheet input[type=text] { border: 0; background: var(--fill); border-radius: var(--r-s); padding: 10px 14px; max-width: 100%; }
.seg { display: inline-flex; background: var(--fill); border-radius: 999px; padding: 3px; gap: 2px; }
.seg button { background: transparent; padding: 5px 13px; font-size: 13px; color: var(--muted); }
.seg button:hover { background: transparent; color: var(--ink); }
.seg button.on { background: var(--card); color: var(--ink); font-weight: 600; box-shadow: 0 1px 3px rgba(0, 0, 0, 0.16); }
.help { font-size: 13px; color: var(--muted); margin: 6px 0 0; }
.help code { font: 500 13px var(--ui); color: var(--ink); }
.pattern { width: 100%; font: 14px var(--mono) !important; }
.tokens { display: flex; flex-wrap: wrap; gap: 6px; }
.tokens button { font: 12px var(--mono); padding: 4px 10px; color: var(--muted); }
.choice { display: flex; gap: 10px; align-items: flex-start; padding: 12px 16px; background: var(--fill); border-radius: var(--r-m); cursor: pointer; margin: 8px 0; transition: box-shadow 0.15s ease; }
.choice.on { box-shadow: inset 0 0 0 2px var(--accent); }
.choice b { font-weight: 600; }
.choice small { display: block; color: var(--muted); font-size: 13px; }
.model { display: flex; align-items: center; gap: 10px; padding: 9px 14px; border-radius: var(--r-s); cursor: pointer; font-size: 14px; }
.model:hover, .model.on { background: var(--fill); }
.model span:first-child { flex: 1; min-width: 0; }
.badge { font-size: 11px; font-weight: 600; padding: 2px 9px; border-radius: 999px; background: var(--fill); color: var(--muted); white-space: nowrap; }
.badge.on { background: color-mix(in srgb, var(--ok) 18%, transparent); color: var(--ok); }
.sub { padding-bottom: 8px; }
.sub.off { opacity: 0.45; }
.sub > button { margin-top: 6px; }
.switch { position: relative; width: 46px; height: 28px; flex: none; }
.switch input { opacity: 0; width: 100%; height: 100%; margin: 0; cursor: pointer; position: absolute; z-index: 1; }
.switch i { position: absolute; inset: 0; background: var(--hover); border-radius: 999px; transition: background 0.18s; }
.switch i::after { content: ""; position: absolute; width: 22px; height: 22px; left: 3px; top: 3px; background: #fff; border-radius: 50%; transition: transform 0.2s cubic-bezier(0.3, 0.7, 0.2, 1); box-shadow: 0 1px 3px rgba(0,0,0,0.3); }
.switch input:checked + i { background: var(--accent); }
.switch input:checked + i::after { transform: translateX(18px); }
.switch input:focus-visible + i { outline: 2px solid var(--accent); outline-offset: 2px; }

.toast { position: fixed; bottom: 24px; left: 50%; transform: translateX(-50%); z-index: 50; background: var(--ink); color: var(--bg); border-radius: 999px; padding: 10px 20px; font-size: 14px; font-weight: 500; box-shadow: var(--shadow); max-width: calc(100vw - 32px); }
.drop { position: fixed; inset: 12px; z-index: 60; border: 2px dashed var(--accent); border-radius: 30px; background: color-mix(in srgb, var(--bg) 88%, transparent); display: grid; place-items: center; font: 600 20px var(--ui); letter-spacing: -0.02em; pointer-events: none; }
.onboard { position: fixed; inset: 0; z-index: 70; background: var(--bg); overflow-y: auto; display: grid; justify-items: center; align-items: start; padding: 48px 20px; }
.onboard-card { width: min(580px, 100%); margin: auto 0; }
.onboard-card > img { border-radius: 22px; display: block; margin-bottom: 20px; }
.onboard h1 { font-size: 32px; line-height: 1.2; letter-spacing: -0.03em; margin: 0 0 8px; }
.onboard .lead { font-size: 17px; color: var(--muted); margin: 0 0 28px; }
.onboard h2 { font-size: 13px; font-weight: 600; color: var(--muted); margin: 26px 10px 8px; }
.perm { display: flex; align-items: center; gap: 14px; padding: 14px 0; border-top: 1px solid var(--line); }
.perm:first-child { border-top: 0; }
.perm > div:first-child { flex: 1; min-width: 0; }
.perm b { font-weight: 600; }
.perm small { display: block; color: var(--muted); font-size: 13px; margin-top: 1px; }
.perm .acts { display: flex; gap: 6px; flex-wrap: wrap; justify-content: flex-end; }
.perm .badge { font-size: 13px; padding: 5px 13px; }
.ob-foot { display: flex; align-items: center; gap: 14px; margin-top: 28px; flex-wrap: wrap; }
.ob-foot .help { flex: 1; min-width: 200px; margin: 0; }
button.big { font-size: 16px; padding: 12px 26px; }

/* 实时字幕：正在说的那一句，最新的词最浅，越早说出来的越深；定稿（写进文档）后整句变实 */
#live-doc .cue.partial p { color: var(--ink); }
#live-partial p::after { content: ""; display: inline-block; width: 7px; height: 7px; margin-left: 7px; border-radius: 50%; background: var(--faint);
  vertical-align: 1px; animation: breathe 1.1s ease-in-out infinite; }
.w { opacity: 0; transition: opacity 0.6s ease; }
@keyframes breathe { 50% { opacity: 0.25; transform: scale(0.7); } }
#live-lines .cue.settle p { animation: settle 0.6s ease both; }
@keyframes settle { 0% { color: color-mix(in srgb, var(--ink) 55%, transparent); } 100% { color: var(--ink); } }
@media (prefers-reduced-motion: reduce) { .w { transition: none; } #live-lines .cue.settle p, #live-partial p::after { animation: none; } }
.share-tools { display:flex; flex-wrap:wrap; align-items:center; gap:8px; margin-top:12px; }
.speaker-badge { display:inline-block; font-size:12px; font-weight:700; color:var(--accent, #315fca); background:rgba(70,110,220,.1); border-radius:6px; padding:1px 7px; margin-right:8px; vertical-align:middle; }
.reader-share { margin:0 0 22px; padding-bottom:18px; border-bottom:1px solid var(--line); }
.speaker-status { font-size:12px; color:var(--muted); margin-top:8px; }
</style>
</head>
<body>
<div class="app" id="app">
  <aside class="lib" id="lib" aria-label="记录库">
    <div class="lib-inner">
      <div class="lib-head">
        <input type="search" id="q" placeholder="搜索记录" aria-label="搜索记录">
        <button class="icon" id="lib-close" title="收起记录库" aria-label="收起记录库"><svg viewBox="0 0 20 20"><path d="M12 5l-5 5 5 5"/></svg></button>
      </div>
      <div class="lib-list" id="list"></div>
      <div class="lib-foot" id="lib-foot"></div>
    </div>
  </aside>

  <div class="main">
    <header class="top">
      <button class="icon" id="lib-toggle" title="记录库（/）" aria-label="记录库"><svg viewBox="0 0 20 20"><rect x="3" y="4" width="14" height="12" rx="2.5"/><path d="M8 4v12"/></svg></button>
      <span class="brand"><img src="/icon.png" alt="" width="26" height="26">LiveCaption</span>
      <span class="spacer"></span>
      <button class="chip" id="chip" hidden title="回到实时字幕"><i class="dot" id="chip-dot"></i><span id="chip-text"></span></button>
      <button class="icon" id="settings-open" title="设置" aria-label="设置"><svg viewBox="0 0 20 20"><path d="M4 6h7M15 6h1M4 14h1M9 14h7"/><circle cx="13" cy="6" r="2"/><circle cx="7" cy="14" r="2"/></svg></button>
    </header>

    <div class="notice" id="offline" hidden>
      <div><b>LiveCaption 没有在运行</b><small>这个页面由 LiveCaption 应用提供。打开应用后会自动恢复。</small></div>
      <a class="button" href="livecaption://open">打开 LiveCaption</a>
    </div>
    <div class="notice" id="banner" hidden><span id="banner-text"></span><button id="banner-close">知道了</button></div>

    <!-- 实时 -->
    <main class="view" id="view-live">
      <div class="stage" id="stage">
        <input class="title-input" id="title" placeholder="给这次记录起个名字" maxlength="80" autocomplete="off" hidden>
        <button class="record" id="start" aria-label="开始记录"><i></i></button>
        <div class="stage-label">开始记录<kbd>⌥⌘P</kbd></div>
        <div class="quick">
          <select id="q-source" aria-label="音频来源"></select>
          <select id="q-locale" aria-label="识别语言"></select>
        </div>
        <label class="help"><input type="checkbox" id="q-speakers"> 实时区分说话人 A / B / C / D</label>
        <p class="help">本机分人 · 最多 4 人 · 首次下载模型 · 标签会稍后校正</p>
        <div class="name-hint"><span id="name-hint"></span> · <button class="link" id="name-mode"></button></div>
        <div class="stage-foot"><button class="link" id="stage-lib"></button></div>
      </div>

      <div id="live" hidden>
        <div class="session"><div class="session-card">
          <div class="session-row">
            <i class="dot" id="s-dot"></i>
            <div class="session-title" id="s-title" title="点一下改名"></div>
            <span class="clock" id="s-clock"></span>
            <span id="s-buttons" style="display:flex;gap:8px"></span>
          </div>
          <div class="session-status" id="s-status"></div>
          <div class="meter" id="meter"><i></i></div>
          <div class="speaker-status" id="speaker-status"></div>
          <div class="share-tools">
            <button id="live-copy">复制全文</button>
            <button id="live-md">导出 Markdown</button>
            <button id="live-txt">导出 TXT</button>
            <span class="help">含时间与说话人；未定稿文字标为「识别中」</span>
          </div>
        </div></div>
        <div class="doc" id="live-doc">
          <div id="live-lines"></div>
          <div class="cue partial" id="live-partial" hidden><time></time><p></p></div>
          <p class="quiet" id="live-note" hidden></p>
        </div>
        <div class="live-foot" id="live-foot"></div>
      </div>
      <button class="latest" id="latest" hidden>↓ 回到最新</button>
    </main>

    <!-- 阅读 -->
    <main class="view" id="view-reader" hidden>
      <div class="reader-bar">
        <button class="ghost" id="r-back">← 返回</button>
        <span class="spacer"></span>
        <button class="ghost toggle" id="r-font" title="切换到衬线字体">Aa</button>
        <button class="ghost toggle" id="r-time" title="显示 / 隐藏时间戳">时间</button>
        <button class="ghost" id="r-edit" title="直接修改这份记录的文字">编辑</button>
        <button class="ghost" id="r-cancel" hidden>取消</button>
        <button class="primary" id="r-save" hidden title="保存（⌘S）">保存</button>

        <button class="ghost" id="r-continue">接着写入</button>
        <button class="ghost" id="r-reveal">在访达中显示</button>
        <button class="ghost danger" id="r-trash">移到废纸篓</button>
      </div>
      <div class="reader-card">
        <div class="share-tools reader-share" id="reader-share">
          <span class="help">分享 transcript</span>
          <button class="primary" id="r-copy">复制全文</button>
          <button id="r-md">导出 Markdown</button>
          <button id="r-txt">导出 TXT</button>
        </div>
        <div class="reader-meta" id="r-meta"></div>
        <div class="reader-title" id="r-title"></div>
        <div class="doc" id="r-doc"></div>
        <textarea class="editor" id="r-editor" spellcheck="false" hidden aria-label="编辑记录内容"></textarea>
      </div>
    </main>
  </div>
</div>

<div class="scrim" id="scrim" hidden></div>
<aside class="sheet" id="sheet" hidden aria-label="设置">
  <div class="sheet-head"><b>设置</b><button class="icon" id="settings-close" aria-label="关闭设置"><svg viewBox="0 0 20 20"><path d="M5 5l10 10M15 5L5 15"/></svg></button></div>

  <h2>保存与命名</h2>
  <div class="group">
  <div class="row"><span class="label">新记录的名字</span><div class="seg" id="namingMode"></div></div>
  <div class="row">
    <label for="pattern" style="flex-basis:100%">命名规则</label>
    <input type="text" class="pattern" id="pattern" maxlength="120" spellcheck="false" autocomplete="off">
    <div class="tokens" id="tokens" style="flex-basis:100%"></div>
    <p class="help" style="flex-basis:100%">现在开始会保存为 <code id="pattern-preview"></code> · <button class="link" id="pattern-reset">恢复默认</button></p>
    <p class="help" id="pattern-note" style="flex-basis:100%"></p>
  </div>
  <div class="row"><span class="label" id="folder" style="font-size:13px;color:var(--muted);overflow-wrap:anywhere"></span><button id="folder-reveal">在访达中显示</button></div>
  </div>

  <h2>识别</h2>
  <div class="group">
  <div class="row"><label for="source">音频来源</label><select id="source"></select></div>
  <div class="row"><label for="locale">识别语言</label><select id="locale"></select></div>
  <div class="row"><label for="speakerLabels">实时区分说话人 A/B/C/D</label><span class="switch"><input type="checkbox" id="speakerLabels"><i></i></span></div>
  <p class="help" style="padding:0 16px 12px">最多 4 人，按声音自动分组。标签会稍晚出现并校正；? 表示尚未确定，A+B 表示重叠发言。新记录重新编号；暂停后保留。结束记录后可切换。</p>
  <div class="row" style="display:block"><div id="engines"></div></div>
  </div>

  <h2>字幕条</h2>
  <div class="group">
  <div class="row"><label for="panelVisible">显示字幕条</label><span class="switch"><input type="checkbox" id="panelVisible"><i></i></span></div>
  <div class="row"><label for="clickThrough">锁定（鼠标可穿透）</label><span class="switch"><input type="checkbox" id="clickThrough"><i></i></span></div>
  <div class="row"><span class="label">字号</span><div class="seg" id="fontSize"></div></div>
  <div class="row"><span class="label">背景</span><div class="seg" id="opacity"></div></div>
  <div class="row"><span class="label">位置</span><button id="resetPosition">回到默认位置</button></div>
  </div>

  <h2>通用</h2>
  <div class="group">
  <div class="row"><label for="dashboardOnLaunch">启动时打开主窗口</label><span class="switch"><input type="checkbox" id="dashboardOnLaunch"><i></i></span></div>
  <div class="row"><span class="label">权限和新手引导</span><button id="ob-reopen">重新查看</button></div>
  </div>
</aside>

<div class="onboard" id="onboard" hidden>
  <div class="onboard-card">
    <img src="/icon.png" alt="" width="76" height="76">
    <h1>欢迎使用 LiveCaption</h1>
    <p class="lead">把听到的声音实时变成字幕。识别全部在这台 Mac 上完成，音频不会上传。</p>
    <h2>先允许它听声音</h2>
    <div class="group" id="ob-perms"></div>
    <h2>选一个识别引擎（以后可以在设置里换）</h2>
    <div id="ob-engines"></div>
    <div class="ob-foot">
      <button class="primary big" id="ob-done">开始使用</button>
      <p class="help" id="ob-note"></p>
      <button class="link" id="ob-skip" style="font-size:14px">跳过</button>
    </div>
  </div>
</div>

<div class="toast" id="toast" hidden></div>
<div class="drop" id="drop" hidden>松手预览这个 Markdown 文件</div>

<script>
const $ = id => document.getElementById(id);
const el = (tag, cls, text) => { const e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; };
const prefs = {
  get(key, fallback) { try { const v = localStorage.getItem('lc.' + key); return v == null ? fallback : v; } catch (e) { return fallback; } },
  set(key, value) { try { localStorage.setItem('lc.' + key, value); } catch (e) {} },
};
const stem = name => name.replace(/\.(md|markdown|txt)$/i, '');
const pad = n => String(n).padStart(2, '0');

let S = null;            // 应用状态（每 0.3 秒刷新）
let recs = [];           // 记录库
let doc = null;          // 阅读视图里打开的：{ name, text, local }
let lastOnboardSig = '';
let dismissedError = 0, lastSettingsSig = '', lastButtonsSig = '', lastLiveSig = '', lastListSig = '';

// ---------- 和应用通信 ----------
async function api(path, body) {
  const options = body ? { method: 'POST', headers: { 'Content-Type': 'application/json', 'X-LiveCaption': '1' }, body: JSON.stringify(body) } : {};
  let response;
  try { response = await fetch(path, options); }
  catch (e) { setOffline(true); const err = new Error('offline'); err.offline = true; throw err; }
  const data = await response.json();
  if (!response.ok) throw new Error(data.error || '请求失败');
  return data;
}
async function act(action, extra) {
  try { const data = await api('/api/action', Object.assign({ action }, extra || {})); render(data); loadList(); return data; }
  catch (e) { if (!e.offline) showBanner(e.message); return null; }
}
async function setting(patch) {
  try { lastSettingsSig = ''; render(await api('/api/settings', patch)); }
  catch (e) { if (!e.offline) showBanner(e.message); }
}
function setOffline(offline) {
  $('offline').hidden = !offline;
  document.body.classList.toggle('is-offline', offline);
  if (offline) document.title = 'LiveCaption（未运行）';
}
function showBanner(text) { $('banner-text').textContent = text; $('banner').hidden = false; }
let toastTimer = 0;
function toast(text) {
  $('toast').textContent = text; $('toast').hidden = false;
  clearTimeout(toastTimer); toastTimer = setTimeout(() => { $('toast').hidden = true; }, 2200);
}

// ---------- Markdown ----------
const esc = s => s.replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
function inline(source) {
  const codes = [];
  let s = esc(source).replace(/`([^`]+)`/g, (m, code) => { codes.push(code); return '\u0001' + (codes.length - 1) + '\u0001'; });
  s = s.replace(/\[([^\]]+)\]\((https?:\/\/[^\s)]+)\)/g, '<a href="$2" target="_blank" rel="noopener noreferrer">$1</a>')
       .replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>')
       .replace(/(^|[^*\w])\*([^*\s][^*]*)\*/g, '$1<em>$2</em>')
       .replace(/~~([^~]+)~~/g, '<del>$1</del>');
  return s.replace(/\u0001(\d+)\u0001/g, (m, i) => '<code>' + codes[i] + '</code>');
}
function captionMarkup(text) {
  const match = text.match(/^\[([A-D?](?:\+[A-D])?)\]\s*(.*)$/);
  if (!match) return inline(text);
  return '<span class="speaker-badge">' + (match[1] === '?' ? '待识别' : '说话人 ' + match[1]) + '</span>' + inline(match[2]);
}
const CUE = /^\[(\d{1,2}:\d{2}(?::\d{2})?)\]\s*(.*)$/;
const SEP = /^——\s*(.+?)\s*——$/;
const LIST = /^\s*([-*+]|\d+[.)])\s+(.*)$/;
const TABLE_RULE = /^\s*\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?\s*$/;
const cells = line => line.trim().replace(/^\||\|$/g, '').split('|').map(c => c.trim());
function markdown(text) {
  const lines = text.replace(/\r\n?/g, '\n').split('\n');
  const out = [];
  let i = 0;
  const special = line => /^(#{1,6})\s/.test(line) || /^```/.test(line) || /^>/.test(line) || LIST.test(line) || CUE.test(line) || SEP.test(line.trim()) || /^(-{3,}|\*{3,}|_{3,})\s*$/.test(line);
  while (i < lines.length) {
    const line = lines[i], trimmed = line.trim();
    let m;
    if (!trimmed) { i++; continue; }
    if (/^```/.test(trimmed)) {
      const code = []; i++;
      while (i < lines.length && !/^```/.test(lines[i].trim())) code.push(lines[i++]);
      i++;
      out.push('<pre><code>' + esc(code.join('\n')) + '</code></pre>');
    } else if ((m = trimmed.match(/^(#{1,6})\s+(.*?)\s*#*$/))) {
      out.push('<h' + m[1].length + '>' + inline(m[2]) + '</h' + m[1].length + '>'); i++;
    } else if (/^(-{3,}|\*{3,}|_{3,})$/.test(trimmed)) {
      out.push('<hr>'); i++;
    } else if ((m = trimmed.match(SEP))) {
      out.push('<div class="sep">' + inline(m[1]) + '</div>'); i++;
    } else if ((m = trimmed.match(CUE))) {
      const pending = m[2].endsWith(' …（识别中）');
      out.push('<div class="cue' + (pending ? ' partial' : '') + '"><time>' + m[1] + '</time><p>' + captionMarkup(pending ? m[2].slice(0, -7) + ' …' : m[2]) + '</p></div>'); i++;
    } else if (/^>/.test(trimmed)) {
      const quote = [];
      while (i < lines.length && /^\s*>/.test(lines[i])) quote.push(lines[i++].replace(/^\s*>\s?/, ''));
      out.push('<blockquote>' + markdown(quote.join('\n')) + '</blockquote>');
    } else if (LIST.test(line)) {
      const ordered = /^\s*\d/.test(line), items = [];
      while (i < lines.length && (m = lines[i].match(LIST))) {
        const task = m[2].match(/^\[([ xX])\]\s+(.*)$/);
        items.push(task ? '<li class="task"><input type="checkbox" disabled' + (task[1] === ' ' ? '' : ' checked') + '> ' + inline(task[2]) + '</li>' : '<li>' + inline(m[2]) + '</li>');
        i++;
      }
      out.push((ordered ? '<ol>' : '<ul>') + items.join('') + (ordered ? '</ol>' : '</ul>'));
    } else if (line.includes('|') && i + 1 < lines.length && TABLE_RULE.test(lines[i + 1])) {
      const head = cells(line), rows = [];
      i += 2;
      while (i < lines.length && lines[i].includes('|') && lines[i].trim()) rows.push(cells(lines[i++]));
      out.push('<table><thead><tr>' + head.map(c => '<th>' + inline(c) + '</th>').join('') + '</tr></thead><tbody>'
        + rows.map(r => '<tr>' + r.map(c => '<td>' + inline(c) + '</td>').join('') + '</tr>').join('') + '</tbody></table>');
    } else {
      const para = [];
      while (i < lines.length && lines[i].trim() && !special(lines[i])) para.push(inline(lines[i++].trim()));
      out.push('<p>' + para.join('<br>') + '</p>');
    }
  }
  return out.join('\n');
}

// ---------- 视图切换 ----------
function showView() {
  $('view-live').hidden = !!doc;
  $('view-reader').hidden = !doc;
  if (doc) renderReader();
  renderList();
  if (S) render(S);
}
function goLive() { if (!leaveEditing()) return; doc = null; if (location.hash) location.hash = ''; showView(); }
async function route() {
  const m = location.hash.match(/^#r\/(.+)$/);
  if (!m) { if (!(doc && doc.local)) { doc = null; showView(); } return; }
  const name = decodeURIComponent(m[1]);
  try {
    const data = await api('/api/recording?name=' + encodeURIComponent(name));
    editing = false;
    doc = { name: data.name, text: data.text, ts: data.ts };
    showView();
    window.scrollTo(0, 0);
  } catch (e) {
    if (!e.offline) { toast('找不到这份记录'); goLive(); }
  }
}
window.addEventListener('hashchange', route);
const openRecording = name => { if (leaveEditing()) location.hash = 'r/' + encodeURIComponent(name); };

// ---------- 主渲染 ----------
function render(state) {
  S = state;
  setOffline(false);
  const busy = state.starting || state.finishing;
  const active = state.state !== 'idle';
  const stateLabel = state.finishing ? '正在收尾…' : state.starting ? '正在启动…' : { idle: '空闲', recording: '记录中', paused: '已暂停' }[state.state];
  const elapsed = (state.elapsed >= 3600 ? Math.floor(state.elapsed / 3600) + ':' + pad(Math.floor(state.elapsed % 3600 / 60)) : Math.floor(state.elapsed / 60)) + ':' + pad(state.elapsed % 60);
  document.title = (state.state === 'recording' ? '● ' : state.state === 'paused' ? '⏸ ' : '') + (active ? stem(state.currentFile) + ' · ' : '') + 'LiveCaption';

  // 顶栏的状态胶囊：只在看别的记录时出现，点一下回到实时
  $('chip').hidden = !(active && doc);
  $('chip-dot').className = 'dot ' + state.state;
  $('chip-text').textContent = stateLabel + ' ' + elapsed;

  // 空闲：开始
  $('stage').hidden = active;
  $('live').hidden = !active;
  if (!active) {
    const ask = state.naming.mode === 'ask';
    $('title').hidden = !ask;
    $('start').disabled = busy;
    $('name-hint').replaceChildren(ask ? '留空则叫 ' : '会自动命名为 ', el('code', '', state.naming.preview));
    $('name-mode').textContent = ask ? '改为自动命名' : '改为先起名字';
    fillSelect($('q-source'), state.options.sources, state.settings.source);
    fillSelect($('q-locale'), state.options.languages, state.settings.locale);
    $('latest').hidden = true;
  } else {
    // 记录中
    $('s-dot').className = 'dot ' + state.state;
    if (!$('s-title').dataset.editing) $('s-title').textContent = stem(state.currentFile);
    $('s-clock').textContent = elapsed;
    const sig = state.state + '|' + busy;
    if (sig !== lastButtonsSig) {
      lastButtonsSig = sig;
      const box = $('s-buttons');
      box.replaceChildren();
      const add = (text, action, cls) => { const b = el('button', cls, text); b.disabled = state.finishing; b.onclick = () => act(action); box.append(b); };
      if (state.state === 'recording') add('暂停', 'pause', 'primary'); else add('继续', 'resume', 'primary');
      add('结束', 'end', '');
    }
    $('speaker-status').textContent = state.settings.speakerLabels ? (state.speakerStatus || '实时分人 · 等待声音') : '实时分人已关闭';
    for (const id of ['live-copy', 'live-md', 'live-txt']) $(id).disabled = !state.lineCount && !state.partial;
    const dead = state.running && !state.receiving;
    $('meter').classList.toggle('dead', dead);
    $('meter').firstElementChild.style.width = (state.running ? Math.round(state.level * 100) : 0) + '%';
    $('s-status').classList.toggle('bad', dead);
    $('s-status').textContent = dead ? '没有收到声音：检查音频来源和系统权限'
      : state.state === 'paused' ? '已暂停 · 继续后接着写入这份记录'
      : busy ? stateLabel
      : state.running && state.level < 0.1 ? '在听，但现在很安静' : '';

    const liveSig = JSON.stringify([state.lines, state.partial, state.partialSpeaker, state.status]);
    if (liveSig !== lastLiveSig) {
      lastLiveSig = liveSig;
      const atBottom = window.innerHeight + window.scrollY >= document.documentElement.scrollHeight - 80;
      renderLiveLines(state);
      renderPartial((state.partialSpeaker ? '[' + state.partialSpeaker + '] ' : '') + state.partial);
      const note = state.status || (!state.lines.length && !state.partial && state.running ? '正在聆听…说的话会出现在这里。' : '');
      $('live-note').hidden = !note;
      $('live-note').textContent = note;
      if (!doc) { if (atBottom) window.scrollTo(0, document.documentElement.scrollHeight); else $('latest').hidden = false; }
    }

    const foot = $('live-foot');
    if (foot.dataset.sig !== state.ai.app + '|' + state.ai.requests.length) {
      foot.dataset.sig = state.ai.app + '|' + state.ai.requests.length;
      foot.replaceChildren(el('span', '', '交给 ' + (state.ai.app || '桌面 AI') + '：'));
      for (const request of state.ai.requests) { const b = el('button', 'ghost', request); b.onclick = () => act('sendToAI', { request }); foot.append(b); }
    }
  }
  if (!active) { lastButtonsSig = ''; lastLiveSig = ''; }

  // 阅读视图里「接着写入」只在空闲时可用
  $('r-continue').disabled = active || state.finishing;
  $('q-speakers').checked = state.settings.speakerLabels;

  if (state.error && state.error.id !== dismissedError) { $('banner').dataset.id = state.error.id; showBanner(state.error.message); }

  renderOnboarding(state);
  $('pattern-preview').textContent = state.naming.preview;
  const settingsSig = JSON.stringify([state.settings, state.options, state.whisper, state.running, state.naming.mode, state.naming.pattern, state.folder]);
  if (settingsSig !== lastSettingsSig) { lastSettingsSig = settingsSig; renderSettings(state); }
}

// ---------- 新手引导 ----------
const PERMS = [
  { id: 'microphone', name: '麦克风', note: '听现场的声音：上课、开会、面对面交谈。' },
  { id: 'speech', name: '语音识别', note: '使用「系统识别」引擎时需要。' },
  { id: 'screen', name: '系统声音（可选）', note: '给视频、网课、线上会议出字幕。需要「屏幕与系统录音」权限，允许后要重新打开应用才生效。' },
];
function renderOnboarding(state) {
  const ob = state.onboarding;
  $('onboard').hidden = !ob.show;
  if (!ob.show) { lastOnboardSig = ''; return; }
  const sig = JSON.stringify([ob.permissions, state.settings.engine, state.settings.whisperModel, state.options.models, state.whisper]);
  if (sig === lastOnboardSig) return;
  lastOnboardSig = sig;

  const perms = $('ob-perms');
  perms.replaceChildren();
  for (const perm of PERMS) {
    const status = ob.permissions[perm.id];
    const row = el('div', 'perm'), text = el('div'), acts = el('div', 'acts');
    text.append(el('b', '', perm.name), el('small', '', perm.note));
    const button = (label, action, extra, cls) => { const b = el('button', cls, label); b.onclick = () => act(action, extra); acts.append(b); };
    if (status === 'granted') acts.append(el('span', 'badge on', '已允许'));
    else if (status === 'ask') button('允许', 'requestPermission', { kind: perm.id }, perm.id === 'screen' ? '' : 'primary');
    else {
      button('打开系统设置', 'requestPermission', { kind: perm.id });
      if (status === 'pending') button('重新打开应用', 'relaunch', null, 'primary');
    }
    row.append(text, acts);
    perms.append(row);
  }

  const engines = $('ob-engines');
  engines.replaceChildren();
  const model = state.options.models.find(m => m.id === state.settings.whisperModel);
  for (const engine of state.options.engines) {
    const on = engine.id === state.settings.engine;
    const box = el('div', 'choice' + (on ? ' on' : '')), body = el('div');
    body.style.flex = '1';
    body.append(el('b', '', engine.name), el('small', '', engine.note));
    box.append(body);
    if (engine.id === 'whisper' && on) {
      const ready = model && model.loaded;
      const b = el('button', ready ? '' : 'primary', ready ? '模型已就绪 ✓' : state.whisper.loading ? '正在准备…' : model && model.downloaded ? '加载模型' : '下载模型');
      b.disabled = ready || state.whisper.loading;
      b.onclick = e => { e.stopPropagation(); act('preloadWhisper'); };
      box.append(b);
      if (state.whisper.status) body.append(el('small', '', state.whisper.status));
    }
    box.onclick = () => { if (!on) setting({ engine: engine.id }); };
    engines.append(box);
  }

  const p = ob.permissions;
  const canListen = p.microphone === 'granted' || p.screen === 'granted';
  const needsSpeech = state.settings.engine === 'apple' && p.speech !== 'granted';
  $('ob-done').disabled = !canListen || needsSpeech;
  $('ob-note').textContent = !canListen ? '先允许麦克风，才能开始。'
    : needsSpeech ? '「系统识别」还需要允许语音识别。'
    : state.settings.engine === 'whisper' && !(model && model.loaded) ? '模型没准备好也可以先开始，第一次记录时会自动下载。' : '都准备好了。';
}

// ---------- 实时字幕的动画 ----------
// 已定稿的句子：只增量更新，新的一句「落定」时气泡亮一下
function renderLiveLines(state) {
  const box = $('live-lines');
  const base = state.lineCount - state.lines.length;
  if (box.dataset.base !== String(base) || box.childElementCount > state.lines.length) {
    box.replaceChildren(); box.dataset.base = base;
  }
  state.lines.forEach((line, i) => {
    let row = box.children[i];
    if (!row) { row = el('div', 'cue'); row.append(el('time'), el('p')); box.append(row); }
    row.firstElementChild.textContent = line.time;
    const signature = JSON.stringify([line.speaker, line.text]);
    if (row.dataset.sig !== signature) {
      row.dataset.sig = signature;
      const p = row.lastElementChild; p.replaceChildren();
      if (line.speaker) p.append(el('span', 'speaker-badge', line.speaker === '?' ? '待识别' : '说话人 ' + line.speaker));
      p.append(document.createTextNode(line.text));
    }
  });
}
// 正在说的半句：最新的词最浅，后面每多说一个词，前面的就深一级（约 7 个词后变实）
const TOKEN = /\s+|[\u3040-\u30ff\u3400-\u9fff\uac00-\ud7af]|[^\s\u3040-\u30ff\u3400-\u9fff\uac00-\ud7af]+/g;
function renderPartial(text) {
  const row = $('live-partial'), p = row.lastElementChild;
  row.hidden = !text;
  if (!text) { p.replaceChildren(); return; }
  const tokens = text.match(TOKEN) || [];
  const nodes = Array.from(p.childNodes);
  let same = 0;
  while (same < tokens.length && same < nodes.length && nodes[same].textContent === tokens[same]) same++;
  for (const node of nodes.slice(same)) node.remove();
  for (const token of tokens.slice(same)) {
    if (/^\s+$/.test(token)) p.append(token); else p.append(el('span', 'w', token));
  }
  const words = Array.from(p.querySelectorAll('.w'));
  const cjk = /[\u3040-\u30ff\u3400-\u9fff\uac00-\ud7af]/;
  // 先让新词以透明状态画出来一帧，再设目标深浅，这样它们是「淡入」而不是直接出现
  requestAnimationFrame(() => {
    let depth = 0;
    for (let i = words.length - 1; i >= 0; i--) {
      words[i].style.opacity = Math.min(1, 0.22 + depth);
      depth += cjk.test(words[i].textContent) ? 0.06 : 0.13;
    }
  });
}

function renderSettings(state) {
  const s = state.settings, o = state.options, n = state.naming;
  $('speakerLabels').checked = s.speakerLabels;
  $('speakerLabels').disabled = state.state !== 'idle' || state.finishing;
  fillSeg($('namingMode'), [{ value: 'pattern', name: '自动命名' }, { value: 'ask', name: '开始前先起名' }], n.mode, v => setting({ namingMode: v }));
  if (document.activeElement !== $('pattern')) $('pattern').value = n.pattern;
  $('pattern-note').textContent = n.mode === 'ask' ? '先起名时，名字留空就按这条规则来。' : '重名时会自动加上 (2)、(3)。记录开始后点标题可以随时改名。';
  const tokens = $('tokens');
  if (!tokens.childElementCount) for (const t of n.tokens) {
    const b = el('button', '', t.token); b.title = t.note;
    b.onclick = () => {
      const input = $('pattern'), at = input.selectionStart == null ? input.value.length : input.selectionStart;
      input.value = input.value.slice(0, at) + t.token + input.value.slice(input.selectionEnd == null ? at : input.selectionEnd);
      input.focus(); input.setSelectionRange(at + t.token.length, at + t.token.length);
      setting({ namePattern: input.value });
    };
    tokens.append(b);
  }
  $('folder').textContent = '保存在 ' + state.folder.replace(/^\/Users\/[^/]+/, '~');

  fillSelect($('source'), o.sources, s.source);
  fillSelect($('locale'), o.languages.map(l => ({ id: l.id, name: l.name + (l.supported ? '' : '（系统识别不支持）') })), s.locale);

  const engines = $('engines');
  engines.replaceChildren();
  for (const engine of o.engines) {
    const box = el('div', 'choice' + (engine.id === s.engine ? ' on' : ''));
    const body = el('div'); body.append(el('b', '', engine.name), el('small', '', engine.note));
    box.append(body);
    box.onclick = () => { if (engine.id !== s.engine) setting({ engine: engine.id }); };
    engines.append(box);
  }
  const sub = el('div', 'sub' + (s.engine === 'whisper' ? '' : ' off'));
  for (const model of o.models) {
    const row = el('div', 'model' + (model.id === s.whisperModel ? ' on' : ''));
    row.append(el('span', '', model.name), el('span', 'badge' + (model.loaded ? ' on' : ''), model.loaded ? '已就绪' : model.downloaded ? '已下载' : '未下载'));
    row.onclick = () => { if (model.id !== s.whisperModel) setting({ whisperModel: model.id }); };
    sub.append(row);
  }
  const autoRow = el('div', 'row');
  const autoLabel = el('label', '', '自动检测语言（多种语言混着说时打开）'); autoLabel.htmlFor = 'whisperAuto';
  const sw = el('span', 'switch'), input = el('input'); input.type = 'checkbox'; input.id = 'whisperAuto'; input.checked = s.whisperAuto;
  input.onchange = () => setting({ whisperAuto: input.checked });
  sw.append(input, el('i')); autoRow.append(autoLabel, sw); sub.append(autoRow);
  const current = o.models.find(m => m.id === s.whisperModel);
  const preload = el('button', '', current && current.loaded ? '模型已就绪 ✓' : state.whisper.loading ? '正在准备…' : current && current.downloaded ? '提前加载模型' : '提前下载并加载模型');
  preload.disabled = (current && current.loaded) || state.whisper.loading;
  preload.onclick = () => act('preloadWhisper');
  sub.append(preload);
  if (state.whisper.status) sub.append(el('p', 'help', state.whisper.status));
  engines.append(sub);

  fillSeg($('fontSize'), o.fontSizes, s.fontSize, v => setting({ fontSize: v }));
  fillSeg($('opacity'), o.opacities, s.opacity, v => setting({ opacity: v }));
  for (const key of ['panelVisible', 'clickThrough', 'dashboardOnLaunch']) $(key).checked = !!s[key];
}
function fillSelect(select, items, value) {
  if (document.activeElement === select) return;
  const sig = JSON.stringify(items) + value;
  if (select.dataset.sig === sig) return;
  select.dataset.sig = sig;
  select.replaceChildren();
  for (const item of items) { const opt = el('option', '', item.name); opt.value = item.id; select.append(opt); }
  select.value = value;
}
function fillSeg(box, items, value, onPick) {
  box.replaceChildren();
  for (const item of items) {
    const on = typeof value === 'number' ? Math.abs(item.value - value) < 0.001 : item.value === value;
    const b = el('button', on ? 'on' : '', item.name);
    b.onclick = () => onPick(item.value);
    box.append(b);
  }
}

// ---------- 记录库 ----------
function groupOf(ts) {
  const now = new Date(), today = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime(), t = ts * 1000;
  if (t >= today) return '今天';
  if (t >= today - 864e5) return '昨天';
  if (t >= today - 6 * 864e5) return '过去 7 天';
  const d = new Date(t);
  return d.getFullYear() + ' 年 ' + (d.getMonth() + 1) + ' 月';
}
function timeOf(ts) {
  const d = new Date(ts * 1000), clock = pad(d.getHours()) + ':' + pad(d.getMinutes());
  return ['今天', '昨天'].includes(groupOf(ts)) ? clock : (d.getMonth() + 1) + '月' + d.getDate() + '日';
}
async function loadList() {
  let data;
  try { data = await api('/api/recordings'); } catch (e) { return; }
  recs = data.recordings;
  renderList();
  // 正在看的那份还在记录：跟着更新
  if (doc && !doc.local && recs.some(r => r.name === doc.name && r.active)) {
    try {
      const fresh = await api('/api/recording?name=' + encodeURIComponent(doc.name));
      if (doc && doc.name === fresh.name) { doc.ts = fresh.ts; if (doc.text !== fresh.text) { doc.text = fresh.text; renderReader(); } }
    } catch (e) {}
  }
}
function renderList() {
  const query = $('q').value.trim().toLowerCase();
  const sig = JSON.stringify(recs) + '|' + query + '|' + (doc ? doc.name : '');
  $('stage-lib').textContent = recs.length ? '记录库 · ' + recs.length + ' 份' : '';
  $('lib-foot').textContent = recs.length + ' 份记录';
  if (sig === lastListSig) return;
  lastListSig = sig;
  const list = $('list');
  list.replaceChildren();
  const shown = recs.filter(r => !query || r.name.toLowerCase().includes(query) || r.snippet.toLowerCase().includes(query));
  if (!shown.length) { list.append(el('div', 'lib-empty', recs.length ? '没有找到匹配的记录。' : '还没有记录。结束第一次记录后会出现在这里。')); return; }
  let group = '';
  for (const rec of shown) {
    const g = groupOf(rec.ts);
    if (g !== group) { group = g; list.append(el('div', 'lib-group', g)); }
    const row = el('button', 'rec' + (doc && !doc.local && doc.name === rec.name ? ' on' : ''));
    const title = el('b'); if (rec.active) title.append(el('i')); title.append(el('span', '', stem(rec.name)));
    const sub = el('small'); sub.append(el('time', '', timeOf(rec.ts)), rec.snippet || '（空）');
    row.append(title, sub);
    row.onclick = () => { openRecording(rec.name); if (window.innerWidth <= 900) setLibrary(false); };
    list.append(row);
  }
}
function setLibrary(open) {
  $('app').classList.toggle('lib-open', open);
  prefs.set('lib', open ? '1' : '0');
  if (open) loadList();
}

// ---------- 阅读视图 ----------
function renderReader() {
  if (!doc) return;
  const rec = recs.find(r => r.name === doc.name);
  const title = $('r-title');
  if (!title.dataset.editing) title.textContent = stem(doc.name);
  title.classList.toggle('editable', !doc.local);
  title.title = doc.local ? '' : '点一下改名';
  $('r-meta').textContent = doc.local ? '拖进来预览的文件（没有保存到记录库）'
    : rec ? rec.modified + (rec.active ? ' · 正在记录' : '') + ' · ' + doc.text.length.toLocaleString() + ' 字符' : '';
  // 正文第一行如果就是和标题一样的一级标题，不重复显示
  const body = doc.text.replace(/^\s*#\s+(.*)\n/, (m, h) => (h.trim() === stem(doc.name) || h.trim() === '实时字幕记录') ? '' : m);
  if (!editing) $('r-doc').innerHTML = markdown(body);
  // 编辑时只留「取消 / 保存」；拖进来的文件和正在记录的那份不能编辑（记录中的文件会被新字幕不断重写）
  const canEdit = !doc.local && !(rec && rec.active);
  if (editing && !canEdit) editing = false;
  $('r-doc').hidden = editing;
  $('r-editor').hidden = !editing;
  $('r-edit').hidden = editing || !canEdit;
  $('r-save').hidden = $('r-cancel').hidden = !editing;
  $('reader-share').hidden = editing;
  for (const id of ['r-font', 'r-time', 'r-copy']) $(id).hidden = editing;
  for (const id of ['r-md', 'r-txt']) $(id).hidden = editing || !!doc.local;
  for (const id of ['r-continue', 'r-reveal', 'r-trash']) $(id).hidden = editing || !!doc.local;
  $('r-trash').disabled = !!(rec && rec.active);
  $('r-font').classList.toggle('on', document.body.classList.contains('serif'));
  $('r-time').classList.toggle('on', !document.body.classList.contains('no-time'));
}
// ---------- 编辑 ----------
let editing = false;
const isDirty = () => editing && doc && $('r-editor').value !== doc.text;
/// 要离开编辑状态（返回、打开别的记录）时调用；有没保存的修改就先问一句。返回 false 表示留下
function leaveEditing() {
  if (isDirty() && !confirm('放弃没保存的修改？\n刚才改的内容不会写进文件。')) return false;
  editing = false;
  return true;
}
function growEditor() {
  const editor = $('r-editor'), y = window.scrollY;
  editor.style.height = 'auto';
  editor.style.height = editor.scrollHeight + 2 + 'px';
  window.scrollTo(0, y);
}
function startEditing() {
  if (!doc || doc.local) return;
  editing = true;
  $('r-editor').value = doc.text;
  renderReader();
  growEditor();
  $('r-editor').focus();
  $('r-editor').setSelectionRange(0, 0);
}
async function saveEditing() {
  if (!editing || !doc) return;
  const text = $('r-editor').value;
  if (text === doc.text) { editing = false; renderReader(); return; }
  if (new Blob([text]).size > 900000) { showBanner('这份记录太大了（超过 900 KB），没法在这里保存。请用「在访达中显示」找到文件后用别的编辑器改。'); return; }
  const data = await act('save', { name: doc.name, text, ts: doc.ts });
  if (!data) return;                      // 失败的原因已经显示在上面的提示里，留在编辑状态
  doc.text = text; doc.ts = data.saved;
  editing = false;
  renderReader();
  toast('已保存');
}
$('r-edit').onclick = startEditing;
$('r-save').onclick = saveEditing;
$('r-cancel').onclick = () => { if (leaveEditing()) renderReader(); };
$('r-editor').oninput = growEditor;
$('r-editor').onkeydown = e => { if (e.key === 'Escape' && !e.isComposing) { e.preventDefault(); $('r-cancel').click(); } };
window.addEventListener('beforeunload', e => { if (isDirty()) { e.preventDefault(); e.returnValue = ''; } });

/// 把标题变成输入框；回车 / 失焦保存，Esc 取消
function editTitle(node, name, save) {
  if (node.dataset.editing) return;
  node.dataset.editing = '1';
  const input = el('input', 'title-edit'); input.value = stem(name); input.maxLength = 80;
  node.replaceChildren(input); input.focus(); input.select();
  let done = false;
  const finish = commit => {
    if (done) return; done = true;
    const value = input.value.trim();
    delete node.dataset.editing;
    node.textContent = stem(name);
    if (commit && value && value !== stem(name)) save(value);
  };
  input.onkeydown = e => { if (e.isComposing) return; if (e.key === 'Enter') finish(true); else if (e.key === 'Escape') finish(false); };
  input.onblur = () => finish(true);
}
async function rename(name, to) {
  const data = await act('rename', { name, to });
  if (!data) return;
  toast('已改名为「' + stem(data.renamed) + '」');
  if (doc && !doc.local && doc.name === name) { doc.name = data.renamed; history.replaceState(null, '', '#r/' + encodeURIComponent(data.renamed)); renderReader(); }
}

// ---------- 事件 ----------
$('start').onclick = () => { const title = $('title').hidden ? '' : $('title').value; $('title').value = ''; act('start', { title }); };
$('title').onkeydown = e => { if (e.key === 'Enter' && !e.isComposing) $('start').click(); };
$('name-mode').onclick = async () => {
  const ask = S && S.naming.mode !== 'ask';
  await setting({ namingMode: ask ? 'ask' : 'pattern' });
  if (ask) $('title').focus();
};
$('q-source').onchange = e => setting({ source: e.target.value });
$('q-locale').onchange = e => setting({ locale: e.target.value });
$('q-speakers').onchange = e => setting({ speakerLabels: e.target.checked });
$('speakerLabels').onchange = e => setting({ speakerLabels: e.target.checked });
$('live-copy').onclick = async () => { if (await act('copy')) toast('已复制全文（含时间与说话人）'); };
$('live-md').onclick = () => act('export', { format: 'md' });
$('live-txt').onclick = () => act('export', { format: 'txt' });
$('r-md').onclick = () => act('export', { name: doc.name, format: 'md' });
$('r-txt').onclick = () => act('export', { name: doc.name, format: 'txt' });
$('source').onchange = e => setting({ source: e.target.value });
$('locale').onchange = e => setting({ locale: e.target.value });
$('stage-lib').onclick = () => setLibrary(true);
$('lib-toggle').onclick = () => setLibrary(!$('app').classList.contains('lib-open'));
$('lib-close').onclick = () => setLibrary(false);
$('q').oninput = renderList;
$('chip').onclick = goLive;
$('latest').onclick = () => { window.scrollTo({ top: document.documentElement.scrollHeight, behavior: 'smooth' }); $('latest').hidden = true; };
window.addEventListener('scroll', () => {
  if (window.innerHeight + window.scrollY >= document.documentElement.scrollHeight - 80) $('latest').hidden = true;
}, { passive: true });
$('s-title').onclick = () => { if (S && S.currentFile) editTitle($('s-title'), S.currentFile, to => rename(S.currentFile, to)); };

$('r-back').onclick = goLive;
$('r-title').onclick = () => { if (doc && !doc.local) editTitle($('r-title'), doc.name, to => rename(doc.name, to)); };
$('r-font').onclick = () => { prefs.set('serif', document.body.classList.toggle('serif') ? '1' : '0'); renderReader(); };
$('r-time').onclick = () => { prefs.set('noTime', document.body.classList.toggle('no-time') ? '1' : '0'); renderReader(); };
$('r-copy').onclick = async () => {
  if (!doc.local) { if (await act('copy', { name: doc.name })) toast('已复制全文'); return; }
  try { await navigator.clipboard.writeText(doc.text); toast('已复制全文'); } catch (e) { toast('复制失败'); }
};
$('r-continue').onclick = async () => { const name = doc.name; if (await act('continue', { name })) goLive(); };
$('r-reveal').onclick = () => act('reveal', { name: doc.name });
$('r-trash').onclick = async () => {
  const name = doc.name;
  if (!confirm('把「' + stem(name) + '」移到废纸篓？\n之后可以从废纸篓里放回原处。')) return;
  if (await act('trash', { name })) { toast('已移到废纸篓'); goLive(); }
};

const openSheet = open => { $('sheet').hidden = !open; $('scrim').hidden = !open; };
$('settings-open').onclick = () => openSheet(true);
$('settings-close').onclick = () => openSheet(false);
$('scrim').onclick = () => openSheet(false);
let patternTimer = 0;
$('pattern').oninput = e => { clearTimeout(patternTimer); patternTimer = setTimeout(() => setting({ namePattern: e.target.value }), 350); };
$('pattern-reset').onclick = () => { $('pattern').value = S.naming.defaultPattern; setting({ namePattern: S.naming.defaultPattern }); };
$('folder-reveal').onclick = () => act('reveal');
$('resetPosition').onclick = () => act('resetPosition');
$('ob-done').onclick = () => act('finishOnboarding');
$('ob-skip').onclick = () => act('finishOnboarding');
$('ob-reopen').onclick = () => { openSheet(false); act('showOnboarding'); };
for (const key of ['panelVisible', 'clickThrough', 'dashboardOnLaunch']) $(key).onchange = e => setting({ [key]: e.target.checked });
$('banner-close').onclick = () => {
  dismissedError = Number($('banner').dataset.id || 0);
  $('banner').hidden = true;
  if (dismissedError) api('/api/action', { action: 'dismissError' }).catch(() => {});
};

document.addEventListener('keydown', e => {
  if ((e.metaKey || e.ctrlKey) && e.key === 's' && editing) { e.preventDefault(); saveEditing(); return; }
  const typing = /^(INPUT|TEXTAREA|SELECT)$/.test(document.activeElement.tagName);
  if (e.key === 'Escape' && !typing) {
    if (!$('sheet').hidden) openSheet(false);
    else if (doc) goLive();
    else if (window.innerWidth <= 900) setLibrary(false);
  } else if (e.key === '/' && !typing && !e.metaKey && !e.ctrlKey) {
    e.preventDefault(); setLibrary(true); $('q').focus();
  }
});

// 把任意 .md / .txt 文件拖进来预览
let dragDepth = 0;
const hasFiles = e => e.dataTransfer && Array.from(e.dataTransfer.types || []).includes('Files');
window.addEventListener('dragenter', e => { if (hasFiles(e)) { dragDepth++; $('drop').hidden = false; } });
window.addEventListener('dragleave', e => { if (hasFiles(e) && --dragDepth <= 0) { dragDepth = 0; $('drop').hidden = true; } });
window.addEventListener('dragover', e => { if (hasFiles(e)) e.preventDefault(); });
window.addEventListener('drop', async e => {
  if (!hasFiles(e)) return;
  e.preventDefault(); dragDepth = 0; $('drop').hidden = true;
  const file = e.dataTransfer.files[0];
  if (!file) return;
  if (!/\.(md|markdown|txt)$/i.test(file.name)) { toast('只能预览 .md / .txt 文件'); return; }
  doc = { name: file.name, text: await file.text(), local: true };
  if (location.hash) history.replaceState(null, '', location.pathname);
  showView(); window.scrollTo(0, 0);
});

// ---------- 启动 ----------
document.body.classList.toggle('serif', prefs.get('serif', '0') === '1');
document.body.classList.toggle('no-time', prefs.get('noTime', '0') === '1');
if (prefs.get('lib', '0') === '1' && window.innerWidth > 900) $('app').classList.add('lib-open');
async function poll() {
  try { render(await api('/api/state')); }
  catch (e) { if (!e.offline) setOffline(true); }
  setTimeout(poll, document.hidden ? 2000 : 300);
}
poll();
loadList().then(route);
setInterval(loadList, 4000);
</script>
</body>
</html>
"""#
}
