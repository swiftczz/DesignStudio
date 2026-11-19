import Foundation

/// 把一个画布的所有画板打包成一个可以直接用浏览器打开的 HTML 文件。
///
/// 每个画板仍是完整独立的 HTML，放在各自的 iframe（srcdoc）里：有自己的窗口宽度、样式和脚本，
/// 互不干扰，和画布上看到的一致。外层页面只负责排版：
/// - 画布：按画布上的位置平铺，可缩放；
/// - 逐个：左侧列表 + 单个画板，← → 切换（幻灯片项目默认这种）。
/// 网页画板（高度随内容）在 iframe 里同样把 vh 固定为一屏，并按整页内容设置高度。
nonisolated enum CanvasBundle {
    private struct Board: Encodable {
        var name: String
        var html: String
        var x: Double
        var y: Double
        var w: Double
        var h: Double
        var auto: Bool
        var vh: Double
    }

    private struct Payload: Encodable {
        var title: String
        var mode: String
        var boards: [Board]
    }

    static func make(title: String, artboards: [Artboard], kind: ProjectKind) -> String {
        let boards = artboards.map {
            Board(name: $0.name, html: $0.html, x: $0.x, y: $0.y, w: $0.width, h: $0.height,
                  auto: $0.fitsContent(in: kind), vh: $0.viewportHeight)
        }
        let payload = Payload(title: title, mode: kind == .slides ? "single" : "canvas", boards: boards)
        let json = (try? JSONEncoder().encode(payload)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        // 放进 <script> 里的数据不能出现 </script> 或 <!--：JSON 字符串里的 < 全部转义
        let data = json.replacingOccurrences(of: "<", with: "\\u003c")
        return template
            .replacingOccurrences(of: "__TITLE__", with: title.htmlEscaped)
            .replacingOccurrences(of: "__DATA__", with: data)
    }

    private static let template = #"""
    <!DOCTYPE html>
    <html lang="zh-CN">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <meta name="generator" content="DesignStudio">
    <title>__TITLE__</title>
    <style>
    :root{--bg:#EDEEF1;--bar:rgba(255,255,255,.82);--ink:#1F2328;--muted:#6B7280;--line:rgba(0,0,0,.08);
      --chip:rgba(0,0,0,.05);--chip-on:#FFFFFF;--hover:rgba(0,0,0,.06);
      --shadow:0 0 0 1px rgba(0,0,0,.04),0 2px 6px rgba(0,0,0,.06),0 12px 32px rgba(0,0,0,.06)}
    @media (prefers-color-scheme: dark){:root{--bg:#1B1B1E;--bar:rgba(38,38,42,.82);--ink:#ECECEE;--muted:#9A9AA2;
      --line:rgba(255,255,255,.08);--chip:rgba(255,255,255,.07);--chip-on:rgba(255,255,255,.16);--hover:rgba(255,255,255,.08);
      --shadow:0 0 0 1px rgba(255,255,255,.05),0 12px 32px rgba(0,0,0,.35)}}
    *{box-sizing:border-box}
    html,body{margin:0;height:100%}
    body{display:flex;flex-direction:column;background:var(--bg);color:var(--ink);
      font:13px/1.4 -apple-system,BlinkMacSystemFont,"PingFang SC","Segoe UI","Microsoft YaHei",sans-serif;-webkit-font-smoothing:antialiased}
    header{flex:none;display:flex;align-items:center;gap:12px;height:48px;padding:0 16px;background:var(--bar);
      border-bottom:1px solid var(--line);-webkit-backdrop-filter:saturate(1.6) blur(16px);backdrop-filter:saturate(1.6) blur(16px);z-index:2}
    header h1{margin:0;font-size:14px;font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;min-width:0}
    .muted{color:var(--muted);white-space:nowrap}
    .spacer{flex:1}
    .seg{display:flex;padding:2px;border-radius:8px;background:var(--chip)}
    button{appearance:none;border:0;background:transparent;color:inherit;font:inherit;cursor:pointer}
    .seg button{padding:4px 12px;border-radius:6px}
    .seg button[aria-pressed="true"]{background:var(--chip-on);box-shadow:0 1px 2px rgba(0,0,0,.1)}
    .tools{display:flex;align-items:center;gap:2px}
    .tool{min-width:28px;height:28px;padding:0 8px;border-radius:7px}
    .tool:hover{background:var(--hover)}
    #zoom{min-width:52px;text-align:center;font-variant-numeric:tabular-nums}
    #canvas-wrap{flex:1;min-height:0;overflow:auto}
    #canvas{position:relative;margin:64px auto 96px}
    .board{position:absolute}
    .label{position:absolute;left:0;bottom:100%;max-width:100%;margin-bottom:8px;padding:0;font-size:12px;color:var(--muted);
      white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
    .label:hover{color:var(--ink)}
    .frame{position:relative;overflow:hidden;background:#FFFFFF;box-shadow:var(--shadow)}
    .frame iframe{display:block;border:0;background:#FFFFFF;transform-origin:0 0}
    #single{flex:1;min-height:0;display:none}
    body.single #canvas-wrap,body.single #canvas-tools{display:none}
    body.single #single{display:flex}
    body:not(.single) #single-tools{display:none}
    #list{flex:none;width:232px;overflow:auto;padding:12px 8px;border-right:1px solid var(--line)}
    #list button{display:flex;gap:8px;width:100%;padding:7px 10px;border-radius:7px;text-align:left}
    #list button:hover{background:var(--hover)}
    #list button[aria-current="true"]{background:var(--chip-on);box-shadow:0 1px 2px rgba(0,0,0,.08)}
    #list .n{flex:none;width:20px;color:var(--muted);font-variant-numeric:tabular-nums}
    #list .t{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
    #view{flex:1;min-width:0;overflow:auto;padding:40px 32px 64px}
    #view .frame{margin:0 auto}
    @media (max-width:720px){#list{display:none}#view{padding:16px}header .muted{display:none}}
    </style>
    </head>
    <body>
    <header>
      <h1 id="title"></h1>
      <span class="muted" id="count"></span>
      <div class="spacer"></div>
      <div class="tools" id="canvas-tools">
        <button class="tool" id="zoom-out" title="缩小">−</button>
        <button class="tool" id="zoom" title="适应窗口">100%</button>
        <button class="tool" id="zoom-in" title="放大">+</button>
      </div>
      <div class="tools" id="single-tools">
        <button class="tool" id="prev" title="上一个（←）">‹</button>
        <span class="muted" id="pos"></span>
        <button class="tool" id="next" title="下一个（→）">›</button>
      </div>
      <div class="seg" role="group" aria-label="查看方式">
        <button id="mode-canvas" aria-pressed="true">画布</button>
        <button id="mode-single" aria-pressed="false">逐个</button>
      </div>
    </header>
    <main id="canvas-wrap"><div id="canvas"></div></main>
    <div id="single"><nav id="list"></nav><main id="view"></main></div>
    <script type="application/json" id="ds-data">__DATA__</script>
    <script>
    (function(){
      var data = JSON.parse(document.getElementById('ds-data').textContent);
      var boards = data.boards || [];
      var $ = function(id){ return document.getElementById(id); };
      $('title').textContent = data.title;
      $('count').textContent = boards.length + ' 个画板';

      // ---------- 网页画板：vh 固定为一屏，高度按整页内容 ----------
      var VH = /(-?\d*\.?\d+)(dvh|svh|lvh|vh|vmin|vmax)\b/gi;
      function pinStyle(style, vh, vw){
        var changes = [];
        for (var i = 0; i < style.length; i++) {
          var name = style[i], v = style.getPropertyValue(name);
          VH.lastIndex = 0;
          if (v && VH.test(v)) changes.push([name, v, style.getPropertyPriority(name)]);
        }
        changes.forEach(function(c){
          style.setProperty(c[0], c[1].replace(VH, function(m, n, u){
            u = u.toLowerCase();
            var base = u === 'vmin' ? Math.min(vw, vh) : u === 'vmax' ? Math.max(vw, vh) : vh;
            return (Math.round(parseFloat(n) * base) / 100) + 'px';
          }), c[2]);
        });
      }
      function pinRules(rules, vh, vw){
        for (var i = 0; i < rules.length; i++) {
          var r = rules[i];
          if (r.style) pinStyle(r.style, vh, vw);
          else if (r.cssRules) { try { pinRules(r.cssRules, vh, vw); } catch(e) {} }
        }
      }
      function pinDocument(doc, vh, vw){
        for (var i = 0; i < doc.styleSheets.length; i++) {
          try { pinRules(doc.styleSheets[i].cssRules, vh, vw); } catch(e) {}
        }
        doc.querySelectorAll('[style]').forEach(function(el){ pinStyle(el.style, vh, vw); });
      }

      // ---------- 画板外框 ----------
      function makeFrame(b, onHeight){
        var frame = document.createElement('div');
        frame.className = 'frame';
        var f = document.createElement('iframe');
        f.setAttribute('sandbox', 'allow-scripts allow-same-origin allow-forms allow-modals allow-popups');
        f.setAttribute('title', b.name);
        f.style.width = b.w + 'px';
        f.style.height = b.h + 'px';
        frame.appendChild(f);
        var st = { b: b, frame: frame, iframe: f, h: b.h, scale: 1 };
        if (b.auto) f.addEventListener('load', function(){ fitContent(st, onHeight); });
        f.srcdoc = b.html;
        return st;
      }
      function fitContent(st, onHeight){
        var doc, win;
        try { doc = st.iframe.contentDocument; win = st.iframe.contentWindow; } catch(e) {}
        if (!doc || !doc.body) return;   // 读不到时保持画布上量好的高度
        var vh = st.b.vh, vw = st.b.w;
        var s = doc.createElement('style');
        s.textContent = 'html,body{height:auto!important;max-height:none!important}body{min-height:' + vh + 'px!important}';
        doc.documentElement.appendChild(s);
        var timer = null;
        function measure(){
          pinDocument(doc, vh, vw);
          var b = doc.body, cs = win.getComputedStyle(b);
          var h = Math.ceil(Math.max(b.scrollHeight, b.offsetHeight) + (parseFloat(cs.marginTop) || 0) + (parseFloat(cs.marginBottom) || 0));
          h = Math.min(Math.max(h, vh), 30000);
          if (Math.abs(h - st.h) > 1) { st.h = h; st.iframe.style.height = h + 'px'; setScale(st, st.scale); onHeight(); }
        }
        measure();
        if (win.ResizeObserver) new win.ResizeObserver(function(){ clearTimeout(timer); timer = setTimeout(measure, 120); }).observe(doc.body);
      }
      function setScale(st, s){
        st.scale = s;
        st.iframe.style.transform = s === 1 ? '' : 'scale(' + s + ')';
        st.frame.style.width = st.b.w * s + 'px';
        st.frame.style.height = st.h * s + 'px';
      }

      // ---------- 画布：按画布位置平铺 ----------
      var canvas = $('canvas'), wrap = $('canvas-wrap'), zoom = 1, canvasStates = null, fitted = false;
      var STEPS = [0.05, 0.1, 0.15, 0.2, 0.25, 0.33, 0.5, 0.67, 0.75, 1, 1.25, 1.5, 2];
      function bounds(){
        var minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
        canvasStates.forEach(function(st){
          minX = Math.min(minX, st.b.x); minY = Math.min(minY, st.b.y);
          maxX = Math.max(maxX, st.b.x + st.b.w); maxY = Math.max(maxY, st.b.y + st.h);
        });
        return { x: minX, y: minY, w: maxX - minX, h: maxY - minY };
      }
      function layout(){
        if (!canvasStates || !canvasStates.length) return;
        var r = bounds();
        canvas.style.width = r.w * zoom + 'px';
        canvas.style.height = r.h * zoom + 'px';
        canvasStates.forEach(function(st){
          st.el.style.left = (st.b.x - r.x) * zoom + 'px';
          st.el.style.top = (st.b.y - r.y) * zoom + 'px';
          setScale(st, zoom);
        });
        $('zoom').textContent = Math.round(zoom * 100) + '%';
      }
      function fitZoom(){
        if (!canvasStates || !canvasStates.length) return;
        var r = bounds();
        zoom = Math.min(1, Math.max(0.05, (wrap.clientWidth - 96) / r.w));
        layout();
      }
      function setZoom(z, cx, cy){
        var rect = canvas.getBoundingClientRect();
        if (cx == null) { cx = wrap.clientWidth / 2 + wrap.getBoundingClientRect().left; cy = wrap.clientHeight / 2 + wrap.getBoundingClientRect().top; }
        var px = (cx - rect.left) / zoom, py = (cy - rect.top) / zoom;
        zoom = Math.min(2, Math.max(0.05, z));
        layout();
        var r2 = canvas.getBoundingClientRect();
        wrap.scrollLeft += r2.left + px * zoom - cx;
        wrap.scrollTop += r2.top + py * zoom - cy;
      }
      function step(dir){
        var next = dir > 0 ? STEPS.find(function(s){ return s > zoom + 0.001; }) : STEPS.slice().reverse().find(function(s){ return s < zoom - 0.001; });
        if (next) setZoom(next);
      }
      function buildCanvas(){
        if (canvasStates) return;
        canvasStates = boards.map(function(b, i){
          var el = document.createElement('div');
          el.className = 'board';
          var label = document.createElement('button');
          label.className = 'label';
          label.textContent = b.name;
          label.title = '逐个查看「' + b.name + '」';
          label.onclick = function(){ show('single', i); };
          var st = makeFrame(b, layout);
          st.el = el;
          el.appendChild(label);
          el.appendChild(st.frame);
          canvas.appendChild(el);
          return st;
        });
      }
      $('zoom-in').onclick = function(){ step(1); };
      $('zoom-out').onclick = function(){ step(-1); };
      $('zoom').onclick = fitZoom;
      wrap.addEventListener('wheel', function(e){
        if (!e.ctrlKey && !e.metaKey) return;   // 触控板捏合 / ⌘ + 滚轮缩放
        e.preventDefault();
        setZoom(zoom * Math.exp(-e.deltaY * 0.01), e.clientX, e.clientY);
      }, { passive: false });

      // ---------- 逐个：一次一个画板 ----------
      var current = 0, single = null;
      var list = $('list'), view = $('view');
      boards.forEach(function(b, i){
        var btn = document.createElement('button');
        btn.innerHTML = '<span class="n"></span><span class="t"></span>';
        btn.querySelector('.n').textContent = i + 1;
        btn.querySelector('.t').textContent = b.name;
        btn.title = b.name + '（' + Math.round(b.w) + ' × ' + (b.auto ? '自适应' : Math.round(b.h)) + '）';
        btn.onclick = function(){ show('single', i); };
        list.appendChild(btn);
      });
      function fitSingle(){
        if (!single) return;
        var availW = view.clientWidth - 64, availH = view.clientHeight - 104;
        var s = Math.min(1, availW / single.b.w);
        if (!single.b.auto) s = Math.min(s, availH / single.h);   // 固定尺寸的画板完整放进窗口
        setScale(single, Math.max(0.05, s));
      }
      function showSingle(i){
        current = (i + boards.length) % boards.length;
        view.innerHTML = '';
        single = makeFrame(boards[current], fitSingle);
        view.appendChild(single.frame);
        view.scrollTop = 0;
        fitSingle();
        $('pos').textContent = (current + 1) + ' / ' + boards.length;
        Array.prototype.forEach.call(list.children, function(btn, k){ btn.setAttribute('aria-current', String(k === current)); });
        var active = list.children[current];
        if (active && active.scrollIntoView) active.scrollIntoView({ block: 'nearest' });
      }
      $('prev').onclick = function(){ show('single', current - 1); };
      $('next').onclick = function(){ show('single', current + 1); };

      // ---------- 切换 ----------
      var mode = null;
      function show(m, i){
        mode = m;
        document.body.classList.toggle('single', m === 'single');
        $('mode-canvas').setAttribute('aria-pressed', String(m === 'canvas'));
        $('mode-single').setAttribute('aria-pressed', String(m === 'single'));
        if (m === 'single') {
          showSingle(i == null ? current : i);
          history.replaceState(null, '', '#' + (current + 1));
        } else {
          buildCanvas();
          if (!fitted) { fitted = true; fitZoom(); } else layout();
          history.replaceState(null, '', location.pathname + location.search);
        }
      }
      $('mode-canvas').onclick = function(){ show('canvas'); };
      $('mode-single').onclick = function(){ show('single'); };
      document.addEventListener('keydown', function(e){
        if (mode !== 'single' || e.metaKey || e.ctrlKey || e.altKey) return;
        if (e.key === 'ArrowRight' || e.key === 'PageDown') { e.preventDefault(); show('single', current + 1); }
        if (e.key === 'ArrowLeft' || e.key === 'PageUp') { e.preventDefault(); show('single', current - 1); }
      });
      window.addEventListener('resize', function(){ if (mode === 'single') fitSingle(); });

      if (!boards.length) { $('count').textContent = '没有画板'; return; }
      var hash = parseInt(location.hash.slice(1), 10);
      if (hash >= 1 && hash <= boards.length) show('single', hash - 1);
      else show(data.mode === 'single' ? 'single' : 'canvas', 0);
    })();
    </script>
    </body>
    </html>
    """#
}
