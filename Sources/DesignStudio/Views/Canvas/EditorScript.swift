import Foundation

/// 注入每个画板 WKWebView 的编辑脚本。
///
/// 页面加载的是带 `data-ds-id` 编号的 HTML；脚本同时维护一份未执行脚本的「源码 DOM」（DOMParser 解析），
/// 所有编辑都会同时作用于实时页面和源码 DOM，再把源码序列化回传，避免把脚本运行后生成的内容写进源码。
/// 悬停框、选中框都由 SwiftUI 绘制，页面里不插入任何辅助元素。
nonisolated enum EditorScript {
    static let errorHook = #"""
    (function(){
      function send(msg){ try { window.webkit.messageHandlers.ds.postMessage(JSON.stringify({type:'error', message:String(msg)})); } catch(_){} }
      window.addEventListener('error', function(e){ if (e && e.message) send(e.message + (e.lineno ? ' (line ' + e.lineno + ')' : '')); });
      window.addEventListener('unhandledrejection', function(e){ send('Unhandled promise rejection: ' + (e.reason && e.reason.message || e.reason)); });
      window.alert = function(){}; window.confirm = function(){ return true; }; window.prompt = function(){ return null; };
      window.open = function(){ return null; };
    })();
    """#

    static let editor = #"""
    (function(){
      if (window.__ds) return;
      var ATTR = 'data-ds-id';
      var mode = 'select';           // select | comment | off
      var src = null;                // 源码 DOM
      var maxId = 0;
      var selectedId = null, hoverId = null;
      var selectedIds = [];          // ⇧ 点击多选时的全部元素（最后一个为主选中，与 selectedId 相同）
      var editing = null;            // 正在行内编辑文字的元素
      var drag = null;               // 按下后可能开始的拖动：move（绝对定位）/ offset（⌥ 自由移动）/ reorder（流式布局里调整顺序）
      var trackedIds = [], geometryFrame = null, lastGeometry = null;

      function isStickyNote(el){ return el.hasAttribute('data-sticky-note'); }

      function post(m){ try { window.webkit.messageHandlers.ds.postMessage(JSON.stringify(m)); } catch(_){} }
      function live(id){ return id == null ? null : document.querySelector('[' + ATTR + '="' + id + '"]'); }
      function srcEl(id){ return (src && id != null) ? src.querySelector('[' + ATTR + '="' + id + '"]') : null; }
      function idOf(el){
        while (el && el.nodeType === 1) {
          var v = el.getAttribute(ATTR);
          if (v && el !== document.body) return +v;
          el = el.parentElement;
        }
        return null;
      }

      // ---- 样式展开：把元素命中的 CSS 规则合并成行内样式（代码面板用）----
      var VOID = ['area','base','br','col','embed','hr','img','input','link','meta','source','track','wbr'];
      var INHERITED = ['color','font-family','font-size','font-weight','line-height','letter-spacing'];
      function splitTop(text, sep){
        var out = [], depth = 0, quote = null, cur = '';
        for (var i = 0; i < text.length; i++) {
          var ch = text[i];
          if (quote) { if (ch === quote) quote = null; }
          else if (ch === '"' || ch === "'") quote = ch;
          else if (ch === '(') depth++;
          else if (ch === ')') depth--;
          else if (ch === sep && depth === 0) { out.push(cur); cur = ''; continue; }
          cur += ch;
        }
        if (cur.trim()) out.push(cur);
        return out;
      }
      function declsOf(cssText){
        return splitTop(cssText || '', ';').map(function(d){
          var i = d.indexOf(':'); if (i < 0) return null;
          var name = d.slice(0, i).trim().toLowerCase(), value = d.slice(i + 1).trim(), imp = false;
          if (/!important$/i.test(value)) { imp = true; value = value.replace(/\s*!important$/i, ''); }
          return name && value ? { name: name, value: value, imp: imp } : null;
        }).filter(Boolean);
      }
      function specificity(sel){
        var ids = (sel.match(/#[\w-]+/g) || []).length;
        var cls = (sel.match(/\.[\w-]+|\[[^\]]*\]|:(?!:)[\w-]+/g) || []).length;
        var rest = sel.replace(/#[\w-]+|\.[\w-]+|\[[^\]]*\]|::?[\w-]+(\([^)]*\))?/g, ' ');
        var types = (rest.match(/(^|[\s>+~])[a-zA-Z][\w-]*/g) || []).length;
        return ids * 10000 + cls * 100 + types;
      }
      var ruleCache = null;
      function styleRules(){
        if (ruleCache) return ruleCache;
        var list = [];
        function walk(rules){
          for (var i = 0; i < rules.length; i++) {
            var r = rules[i];
            if (r.selectorText != null && r.style) list.push(r);
            else if (r.media && r.cssRules) { if (window.matchMedia(r.media.mediaText).matches) walk(r.cssRules); }
            else if (r.conditionText != null && r.cssRules) { try { if (CSS.supports(r.conditionText)) walk(r.cssRules); } catch(_) { walk(r.cssRules); } }
            else if (r.cssRules) walk(r.cssRules);
          }
        }
        for (var i = 0; i < document.styleSheets.length; i++) {
          var sheet = document.styleSheets[i];
          // 编辑器自己注入的样式（选择模式下的光标等）不属于设计
          if (sheet.ownerNode && (sheet.ownerNode.id === '__ds-editor-style' || sheet.ownerNode.id === '__ds-fit-style')) continue;
          try { walk(sheet.cssRules); } catch(_) {}
        }
        ruleCache = list;
        setTimeout(function(){ ruleCache = null; }, 0);
        return list;
      }
      function hex(v){
        return v.replace(/rgba?\((\d+),\s*(\d+),\s*(\d+)(?:,\s*([\d.]+))?\)/g, function(m, r, g, b, a){
          if (a != null && +a < 1) return m;
          return '#' + [r, g, b].map(function(x){ return (+x).toString(16).padStart(2, '0'); }).join('').toUpperCase();
        });
      }
      function resolveVars(value, cs){
        for (var n = 0; n < 6 && value.indexOf('var(') >= 0; n++) {
          value = value.replace(/var\(\s*(--[\w-]+)\s*(?:,\s*([^()]*(?:\([^()]*\)[^()]*)*))?\)/g, function(m, name, fb){
            var v = cs.getPropertyValue(name).trim();
            return v || (fb != null ? fb.trim() : m);
          });
        }
        return value;
      }
      // 元素最终生效的声明：按特异性 + 先后顺序层叠，再叠加行内样式
      function cascade(el, inlineText, root){
        var matched = [];
        styleRules().forEach(function(r, order){
          var best = -1;
          splitTop(r.selectorText, ',').forEach(function(sel){
            sel = sel.trim();
            // 通配的重置规则（* { box-sizing… }）对所有元素都一样，不展开
            if (/^\*(::?[\w-]+)*$/.test(sel)) return;
            try { if (el.matches(sel)) best = Math.max(best, specificity(sel)); } catch(_) {}
          });
          // 网页画板把 vh 换成了像素，代码里仍显示原始写法
          if (best >= 0) matched.push({ spec: best, order: order, decls: declsOf(vhOriginal.get(r) || r.style.cssText) });
        });
        matched.sort(function(a, b){ return a.spec - b.spec || a.order - b.order; });
        matched.push({ decls: declsOf(inlineText) });
        var map = new Map();
        matched.forEach(function(m){
          m.decls.forEach(function(d){
            var prev = map.get(d.name);
            if (prev && prev.imp && !d.imp) return;
            map.delete(d.name);
            map.set(d.name, d);
          });
        });
        // 去掉不独立表达样式的声明：变量定义、inherit 之类的关键字（WebKit 会把 `font: inherit` 拆成十几条），
        // 以及简写展开出来的默认字体细项
        var NOISY_FONT = /^font-(variant|stretch|width|feature|kerning|optical|variation|size-adjust|palette|synthesis|language)/;
        map.forEach(function(d, name){
          var v = d.value.toLowerCase();
          if (name.indexOf('--') === 0 || ['inherit', 'unset', 'revert', 'revert-layer'].indexOf(v) >= 0
              || NOISY_FONT.test(name) && ['normal', 'initial', 'auto', 'none'].indexOf(v) >= 0) map.delete(name);
        });
        var cs = window.getComputedStyle(el), out = [];
        map.forEach(function(d){
          out.push(d.name + ': ' + hex(resolveVars(d.value, cs)).replace(/"/g, "'"));
        });
        // 顶层元素补上从祖先继承来的文字样式，让代码可以单独使用
        if (root) {
          INHERITED.forEach(function(name){
            if (map.has(name) || (name === 'font-family' || name === 'font-size' || name === 'font-weight') && map.has('font')) return;
            var v = cs.getPropertyValue(name);
            if (!v || v === 'normal') return;
            out.push(name + ': ' + hex(v).replace(/"/g, "'"));
          });
        }
        return out;
      }
      function escAttr(v){ return String(v).replace(/&/g, '&amp;').replace(/"/g, '&quot;'); }
      function escText(v){ return String(v).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;'); }
      function tagName(el){ return el.namespaceURI === 'http://www.w3.org/1999/xhtml' ? el.tagName.toLowerCase() : el.tagName; }
      function openTag(el, pad){
        var parts = [], style = el.__decls || [];
        for (var i = 0; i < el.attributes.length; i++) {
          var a = el.attributes[i];
          if (a.name !== 'style') parts.push(a.name + '="' + escAttr(a.value) + '"');
        }
        var head = '<' + tagName(el) + (parts.length ? ' ' + parts.join(' ') : '');
        if (!style.length) return head + '>';
        if (pad == null || style.length <= 2) return head + ' style="' + escAttr(style.join('; ')) + '">';
        return head + ' style="\n' + style.map(function(d){ return pad + '  ' + escAttr(d) + ';'; }).join('\n') + '">';
      }
      function inlineHTML(el){
        var t = tagName(el);
        if (VOID.indexOf(t) >= 0) return openTag(el, null);
        var inner = '';
        el.childNodes.forEach(function(c){
          if (c.nodeType === 1) inner += inlineHTML(c);
          else if (c.nodeType === 3) inner += escText(c.textContent);
        });
        return openTag(el, null) + inner + '</' + t + '>';
      }
      function pretty(el, depth){
        var pad = '  '.repeat(depth), t = tagName(el);
        var open = pad + openTag(el, pad);
        if (VOID.indexOf(t) >= 0) return open;
        var kids = Array.prototype.slice.call(el.childNodes);
        var hasText = kids.some(function(c){ return c.nodeType === 3 && c.textContent.trim(); });
        var elems = kids.filter(function(c){ return c.nodeType === 1; });
        if (!elems.length || hasText) {
          var inner = '';
          kids.forEach(function(c){
            if (c.nodeType === 1) inner += inlineHTML(c);
            else if (c.nodeType === 3) inner += escText(hasText ? c.textContent : '');
          });
          return open + inner.trim() + '</' + t + '>';
        }
        return open + '\n' + elems.map(function(c){ return pretty(c, depth + 1); }).join('\n') + '\n' + pad + '</' + t + '>';
      }
      function rectOf(el){
        // 编组是 display:contents，本身没有盒子：用子元素的范围
        if (window.getComputedStyle(el).display === 'contents') {
          var l = Infinity, t = Infinity, rr = -Infinity, b = -Infinity;
          Array.prototype.forEach.call(el.children, function(c){
            var q = rectOf(c); if (!q.w && !q.h) return;
            l = Math.min(l, q.x); t = Math.min(t, q.y); rr = Math.max(rr, q.x + q.w); b = Math.max(b, q.y + q.h);
          });
          if (l === Infinity) return { x: 0, y: 0, w: 0, h: 0 };
          return { x: l, y: t, w: rr - l, h: b - t };
        }
        var r = el.getBoundingClientRect(); return { x: r.left, y: r.top, w: r.width, h: r.height };
      }

      // 点击只是选中的起点。悬停过渡、祖先的变换和网页重新排版都会继续改变边界。
      function updateTrackedGeometry(){
        geometryFrame = null;
        if (mode === 'off' || !trackedIds.length) return;
        if (drag && drag.started) {
          lastGeometry = null;
        } else {
          var rects = trackedIds.map(function(id){
            var el = live(id);
            return el ? { id: id, rect: rectOf(el) } : null;
          }).filter(Boolean);
          var geometry = JSON.stringify(rects);
          if (geometry !== lastGeometry) {
            lastGeometry = geometry;
            post({ type: 'selectionGeometry', geometry: rects });
          }
        }
        geometryFrame = requestAnimationFrame(updateTrackedGeometry);
      }
      function trackSelection(ids){
        trackedIds = ids;
        lastGeometry = null;
        if (geometryFrame !== null) cancelAnimationFrame(geometryFrame);
        geometryFrame = mode !== 'off' && ids.length ? requestAnimationFrame(updateTrackedGeometry) : null;
      }
      function isGroup(el){ return !!el && el.hasAttribute('data-group'); }
      // 多选：主选中变了（单击、脚本编辑）时，多选集合回到只有它一个
      function syncIds(){
        if (selectedId == null) selectedIds = [];
        else if (selectedIds.indexOf(selectedId) < 0) selectedIds = [selectedId];
      }
      function multiInfo(){
        syncIds();
        if (selectedIds.length < 2) return null;
        return selectedIds.map(function(id){ var el = live(id); return el ? { id: id, rect: rectOf(el) } : null; }).filter(Boolean);
      }
      function postSelect(id){
        post({ type: 'select', props: id != null ? props(id) : null, multi: multiInfo() });
      }

      var INLINE = ['br','b','strong','i','em','span','small','sup','sub','code','mark','u','s','a','label'];
      function isTextLeaf(el){
        if (el && isStickyNote(el)) return true;
        if (!el || !(el.textContent || '').trim()) return false;
        for (var i = 0; i < el.children.length; i++) {
          var c = el.children[i];
          if (INLINE.indexOf(c.tagName.toLowerCase()) < 0 || c.children.length) return false;
        }
        return true;
      }
      function kindOf(el){
        var t = el.tagName.toLowerCase();
        if (isGroup(el)) return 'group';
        if (isStickyNote(el)) return 'note';
        if (el.hasAttribute('data-pencil-stroke')) return 'pencil';
        if (['img','svg','picture','canvas','video'].indexOf(t) >= 0) return 'image';
        if (t === 'button' || el.getAttribute('role') === 'button') return 'button';
        if (['input','textarea','select'].indexOf(t) >= 0) return 'input';
        if (t === 'a') return 'link';
        var cs = window.getComputedStyle(el);
        if (cs.display.indexOf('grid') >= 0) return 'grid';
        if (cs.display.indexOf('flex') >= 0) return cs.flexDirection.indexOf('column') === 0 ? 'column' : 'row';
        if (isTextLeaf(el)) return 'text';
        return 'box';
      }
      function snippet(el){ return (el.textContent || '').trim().replace(/\s+/g, ' ').slice(0, 48); }

      function esc(s){ return (window.CSS && CSS.escape) ? CSS.escape(s) : s; }
      function selectorFor(el){
        if (!el || el.nodeType !== 1) return '';
        if (el.id) return '#' + esc(el.id);
        var parts = [];
        while (el && el.nodeType === 1 && el !== document.body && el !== document.documentElement && parts.length < 5) {
          if (el.id) { parts.unshift('#' + esc(el.id)); break; }
          var p = el.tagName.toLowerCase();
          var cls = (el.getAttribute('class') || '').trim().split(/\s+/).filter(Boolean).slice(0, 2);
          if (cls.length) p += '.' + cls.map(esc).join('.');
          var parent = el.parentElement;
          if (parent) {
            var same = Array.prototype.filter.call(parent.children, function(c){ return c.tagName === el.tagName; });
            if (same.length > 1) p += ':nth-of-type(' + (same.indexOf(el) + 1) + ')';
          }
          parts.unshift(p);
          el = parent;
        }
        return parts.join(' > ');
      }

      // ---------- 图层树：结构来自源码 DOM，类型来自实时页面 ----------
      var SKIP = ['script','style','link','meta','template','noscript','br','title'];
      function tree(){
        var root = src ? src.body : document.body;
        function walk(sEl, depth){
          var nodes = [];
          for (var i = 0; i < sEl.children.length; i++) {
            var c = sEl.children[i];
            var t = c.tagName.toLowerCase();
            if (SKIP.indexOf(t) >= 0) continue;
            var id = +c.getAttribute(ATTR);
            if (!id) continue;
            var l = live(id);
            var k = l ? kindOf(l) : 'box';
            var n = { id: id, tag: t, kind: k,
                      name: c.getAttribute('data-name') || c.getAttribute('aria-label') || '',
                      text: (k === 'text' || k === 'button' || k === 'link') ? snippet(c) : '',
                      hidden: l ? window.getComputedStyle(l).display === 'none' : false };
            if (depth < 40 && k !== 'text' && t !== 'svg') {
              var ch = walk(c, depth + 1);
              if (ch.length) n.children = ch;
            }
            nodes.push(n);
          }
          return nodes;
        }
        return root ? walk(root, 0) : [];
      }

      // ---------- 属性 ----------
      var KEYS = ['display','position','width','height','flex-direction','flex-wrap','align-items','justify-content',
        'gap','padding-top','padding-right','padding-bottom','padding-left','margin-top','margin-right','margin-bottom',
        'margin-left','font-family','font-weight','font-size','line-height','letter-spacing','color','text-align',
        'background-color','background-image','opacity','border-top-left-radius','border-top-width','border-top-style',
        'border-top-color','box-shadow','left','top','z-index','flex-grow','overflow','object-fit','font-style','text-decoration-line'];
      function props(id){
        var el = live(id);
        if (!el) return null;
        var s = srcEl(id) || el;
        var cs = window.getComputedStyle(el);
        var style = {};
        KEYS.forEach(function(k){ style[k] = cs.getPropertyValue(k); });
        var inline = {};
        for (var i = 0; i < s.style.length; i++) { var k = s.style[i]; inline[k] = s.style.getPropertyValue(k); }
        return { id: id, tag: el.tagName.toLowerCase(), kind: kindOf(el),
                 name: s.getAttribute('data-name') || '',
                 text: isTextLeaf(el) ? (s.textContent || '') : null,
                 rect: rectOf(el), style: style, inline: inline,
                 src: el.getAttribute('src') || '', href: el.getAttribute('href') || '',
                 selector: selectorFor(el), parentId: idOf(el.parentElement), childCount: el.children.length,
                 isGroup: isGroup(el), prototypeLinkID: s.getAttribute('data-ds-prototype-link') };
      }

      function serialize(){ return src ? '<!DOCTYPE html>\n' + src.documentElement.outerHTML : null; }
      function both(id, fn){ var a = live(id), b = srcEl(id); if (a) fn(a); if (b) fn(b); }
      function stripPrototypeLinks(root){
        if (!root) return;
        root.removeAttribute('data-ds-prototype-link');
        root.querySelectorAll('[data-ds-prototype-link]').forEach(function(el){ el.removeAttribute('data-ds-prototype-link'); });
      }
      function setInlineStyle(el, map){
        Object.keys(map).forEach(function(k){
          var v = map[k];
          if (v === '' || v == null) el.style.removeProperty(k); else el.style.setProperty(k, v);
        });
        if (!el.getAttribute('style')) el.removeAttribute('style');
      }
      function result(id, withTree){
        var r = { id: id, props: id != null ? props(id) : null, source: serialize(), multi: multiInfo() };
        if (withTree) r.tree = tree();
        return JSON.stringify(r);
      }

      // 给一棵新插入的子树分配编号（实时页面和源码使用相同编号）
      function stamp(liveRoot, srcRoot){
        var a = [liveRoot].concat(Array.prototype.slice.call(liveRoot.querySelectorAll('*')));
        var b = [srcRoot].concat(Array.prototype.slice.call(srcRoot.querySelectorAll('*')));
        for (var i = 0; i < a.length; i++) {
          var tag = a[i].tagName.toLowerCase();
          if (SKIP.indexOf(tag) >= 0) continue;
          maxId += 1;
          a[i].setAttribute(ATTR, String(maxId));
          if (b[i]) b[i].setAttribute(ATTR, String(maxId));
        }
        return +liveRoot.getAttribute(ATTR);
      }
      function fragment(html, doc){
        var t = doc.createElement('template');
        t.innerHTML = html.trim();
        return t.content.firstElementChild;
      }

      function setMode(m){
        if (m !== 'select' && editing) finishEditing();
        mode = m;
        document.documentElement.classList.toggle('__ds-editing', m !== 'off');
        if (m === 'off') { hoverId = null; }
        trackSelection(trackedIds);
      }
      var css = document.createElement('style');
      css.id = '__ds-editor-style';
      css.textContent = 'html.__ds-editing, html.__ds-editing *{cursor:default!important;-webkit-user-select:none!important;user-select:none!important}'
        + 'html.__ds-editing [contenteditable]{cursor:text!important;-webkit-user-select:text!important;user-select:text!important;outline:none}'
        + 'html.__ds-editing [data-sticky-note]:empty:not([contenteditable])::before{content:"双击编辑便签";opacity:.5}';
      document.documentElement.appendChild(css);
      setMode('select');

      // ---------- 事件 ----------
      // 注意：pointerdown 里调用了 preventDefault，浏览器不会再派发 mousedown / mouseup，所以统一用 pointer 事件
      function elemSiblings(el){
        return el.parentElement ? Array.prototype.filter.call(el.parentElement.children, function(c){ return c.hasAttribute(ATTR); }) : [];
      }
      // 流式布局里拖动：指针越过相邻元素的中线就把元素移过去（只看与当前位置方向一致的那一侧，不会来回抖动）
      function reorderTo(el, x, y){
        var parent = el.parentElement;
        if (!parent) return false;
        var pcs = window.getComputedStyle(parent);
        var isGrid = pcs.display.indexOf('grid') >= 0;
        var horizontal = pcs.display.indexOf('flex') >= 0 && pcs.flexDirection.indexOf('row') === 0;
        var best = null, bestD = Infinity;
        elemSiblings(el).forEach(function(sib){
          if (sib === el) return;
          var r = sib.getBoundingClientRect();
          var cx = Math.max(r.left, Math.min(x, r.right)), cy = Math.max(r.top, Math.min(y, r.bottom));
          var d = (x - cx) * (x - cx) + (y - cy) * (y - cy);
          if (d < bestD) { bestD = d; best = sib; }
        });
        if (!best) return false;
        var r = best.getBoundingClientRect();
        var forward = !!(el.compareDocumentPosition(best) & Node.DOCUMENT_POSITION_FOLLOWING);
        var inRow = y >= r.top && y <= r.bottom;
        var past = (horizontal || (isGrid && inRow))
          ? (forward ? x > r.left + r.width / 2 : x < r.left + r.width / 2)
          : (forward ? y > r.top + r.height / 2 : y < r.top + r.height / 2);
        if (!past) return false;
        if (forward) best.after(el); else best.before(el);
        return true;
      }
      document.addEventListener('pointermove', function(e){
        if (mode === 'off' || editing) return;
        if (drag) {
          var dx = e.clientX - drag.x0, dy = e.clientY - drag.y0;
          if (!drag.started) {
            if (Math.abs(dx) + Math.abs(dy) < 4) return;
            drag.started = true;
            // 普通点击保留原始目标，以便 WebKit 把双击交给文字或便签。
            try { document.documentElement.setPointerCapture(e.pointerId); } catch(_) {}
            if (drag.selectOnStart) { selectedId = drag.id; post({ type: 'select', props: props(drag.id) }); }
            if (drag.kind === 'offset' && window.getComputedStyle(drag.el).position === 'static') drag.el.style.position = 'relative';
            if (drag.kind === 'reorder') {
              // 拖动时元素跟着指针走（临时的 transform，松手后还原），越过相邻元素的中线时在布局里换位
              var st = drag.el.style;
              drag.saved = { transform: st.transform, opacity: st.opacity, zIndex: st.zIndex, position: st.position, transition: st.transition };
              var r0 = drag.el.getBoundingClientRect();
              drag.grabX = drag.x0 - r0.left; drag.grabY = drag.y0 - r0.top;
              drag.tx = 0; drag.ty = 0;
              st.transition = 'none';
              st.opacity = '0.85';
              st.zIndex = '2147483000';
              if (window.getComputedStyle(drag.el).position === 'static') st.position = 'relative';
            }
          }
          if (drag.kind === 'reorder') {
            if (reorderTo(drag.el, e.clientX, e.clientY)) drag.reordered = true;
            // 当前在布局里的位置（去掉临时位移），让元素保持在指针下方
            var rr = drag.el.getBoundingClientRect();
            var slotX = rr.left - drag.tx, slotY = rr.top - drag.ty;
            drag.tx = e.clientX - drag.grabX - slotX;
            drag.ty = e.clientY - drag.grabY - slotY;
            drag.el.style.transform = 'translate(' + Math.round(drag.tx) + 'px,' + Math.round(drag.ty) + 'px)' + (drag.saved.transform ? ' ' + drag.saved.transform : '');
          } else {
            drag.el.style.left = Math.round(drag.l0 + dx) + 'px';
            drag.el.style.top = Math.round(drag.t0 + dy) + 'px';
          }
          post({ type: 'dragging', id: drag.id, rect: rectOf(drag.el) });
          return;
        }
        var id = idOf(e.target);
        if (id !== hoverId) {
          hoverId = id;
          var el = live(id);
          post({ type: 'hover', id: id, rect: el ? rectOf(el) : null });
        }
      }, true);
      document.addEventListener('pointerout', function(e){
        if (!e.relatedTarget && hoverId != null) { hoverId = null; post({ type: 'hover', id: null, rect: null }); }
      }, true);

      function block(e){
        if (mode === 'off') return false;
        if (editing && editing.contains(e.target)) return false;
        e.preventDefault(); e.stopPropagation();
        return true;
      }
      ['mousedown','mouseup','click','auxclick','submit','touchstart','dragstart'].forEach(function(t){
        document.addEventListener(t, function(e){ block(e); }, true);
      });
      document.addEventListener('pointerdown', function(e){
        if (!block(e)) return;
        if (e.button !== 0) return;
        if (editing) finishEditing();
        var id = idOf(e.target);
        if (mode === 'comment') { if (id != null) post({ type: 'commentPick', props: props(id) }); return; }
        if (id == null) { selectedId = null; selectedIds = []; post({ type: 'select', props: null }); return; }
        // ⇧ / ⌘ 点击：加入 / 移出多选（不拖动）
        if ((e.shiftKey || e.metaKey) && mode === 'select') {
          syncIds();
          var at = selectedIds.indexOf(id);
          if (at >= 0) selectedIds.splice(at, 1);
          else {
            // 不能同时选中元素和它的父 / 子元素：去掉有包含关系的那些
            var target = live(id);
            selectedIds = selectedIds.filter(function(x){ var o = live(x); return o && !o.contains(target) && !target.contains(o); });
            selectedIds.push(id);
          }
          selectedId = selectedIds.length ? selectedIds[selectedIds.length - 1] : null;
          postSelect(selectedId);
          return;
        }
        // 普通点击会结束多选
        syncIds();
        if (selectedIds.length > 1) { selectedIds = [id]; selectedId = id; postSelect(id); }
        // 在已选中的元素内部按下：拖动时拖的是这个已选中的元素；没拖动就当作点击，选中最里层的元素
        var dragId = id;
        var selEl = selectedId != null ? live(selectedId) : null;
        if (selEl && selEl !== document.body && selEl.contains(e.target)) dragId = selectedId;
        else if (id !== selectedId) { selectedId = id; post({ type: 'select', props: props(id) }); }
        var el = live(dragId);
        if (!el || el === document.body) return;
        var cs = window.getComputedStyle(el);
        var absolute = cs.position === 'absolute' || cs.position === 'fixed';
        var kind = absolute ? 'move' : (e.altKey ? 'offset' : 'reorder');
        // 没有可以换位的兄弟元素时，拖动就是自由移动位置
        if (kind === 'reorder' && elemSiblings(el).length < 2) kind = 'offset';
        drag = { id: dragId, clickId: id, el: el, kind: kind, x0: e.clientX, y0: e.clientY, started: false,
                 selectOnStart: dragId !== selectedId,
                 l0: parseFloat(absolute ? cs.left : el.style.left) || 0, t0: parseFloat(absolute ? cs.top : el.style.top) || 0 };
      }, true);
      document.addEventListener('pointerup', function(e){
        if (!block(e)) return;
        if (!drag) return;
        var d = drag; drag = null;
        if (!d.started) {
          // 没拖动：普通点击，选中指针下最里层的元素
          if (d.clickId !== selectedId) { selectedId = d.clickId; post({ type: 'select', props: props(d.clickId) }); }
          return;
        }
        var s = srcEl(d.id);
        if (!s) return;
        if (d.kind === 'reorder' && !d.reordered) {
          // 没有越过相邻元素换位：当作自由移动，元素留在松手的位置（相对定位偏移）
          var st0 = d.el.style, sv0 = d.saved || {};
          ['transform', 'opacity', 'zIndex', 'position', 'transition'].forEach(function(k){ st0[k] = sv0[k] || ''; });
          if (window.getComputedStyle(d.el).position === 'static') st0.position = 'relative';
          st0.left = Math.round(d.l0 + (d.tx || 0)) + 'px';
          st0.top = Math.round(d.t0 + (d.ty || 0)) + 'px';
          s.style.position = st0.position;
          s.style.left = st0.left; s.style.top = st0.top;
          post({ type: 'changed', result: JSON.parse(result(d.id, false)) });
          return;
        }
        if (d.kind === 'reorder') {
          var st = d.el.style, sv = d.saved || {};
          ['transform', 'opacity', 'zIndex', 'position', 'transition'].forEach(function(k){ st[k] = sv[k] || ''; });
          if (!d.el.getAttribute('style')) d.el.removeAttribute('style');
          // 把源码 DOM 里的元素移到与实时页面相同的位置
          var next = d.el.nextElementSibling;
          while (next && !next.hasAttribute(ATTR)) next = next.nextElementSibling;
          var srcNext = next ? srcEl(+next.getAttribute(ATTR)) : null;
          var srcParent = srcEl(idOf(d.el.parentElement)) || s.parentElement;
          if (srcNext) srcNext.before(s); else srcParent.appendChild(s);
          post({ type: 'changed', result: JSON.parse(result(d.id, true)) });
        } else {
          if (d.el.style.position) s.style.position = d.el.style.position;
          s.style.left = d.el.style.left; s.style.top = d.el.style.top;
          post({ type: 'changed', result: JSON.parse(result(d.id, false)) });
        }
      }, true);
      // 右键：选中元素（在已选中的元素内部右键时保持选中），交给应用弹出菜单
      document.addEventListener('contextmenu', function(e){
        if (!block(e) || mode !== 'select') return;
        if (editing) finishEditing();
        var id = idOf(e.target);
        syncIds();
        var inMulti = selectedIds.length > 1 && selectedIds.some(function(x){ var o = live(x); return o && o.contains(e.target); });
        var selEl = selectedId != null ? live(selectedId) : null;
        if (inMulti) id = selectedId;
        else if (selEl && selEl !== document.body && selEl.contains(e.target)) id = selectedId;
        if (!inMulti && (id !== selectedId || selectedIds.length > 1)) { selectedId = id; selectedIds = id != null ? [id] : []; postSelect(id); }
        var info = null;
        if (id != null) {
          var el = live(id), sibs = elemSiblings(el), i = sibs.indexOf(el);
          info = { isFirst: i <= 0, isLast: i === sibs.length - 1, hasChildren: !!el.querySelector('[' + ATTR + ']'),
                   isGroup: isGroup(el), count: Math.max(selectedIds.length, 1) };
        }
        post({ type: 'contextMenu', id: id, x: e.clientX, y: e.clientY, info: info });
      }, true);
      document.addEventListener('dblclick', function(e){
        if (!block(e) || mode !== 'select') return;
        var id = idOf(e.target);
        var el = live(id);
        if (!el || !isTextLeaf(el)) return;
        editing = el;
        selectedId = id;
        el.setAttribute('contenteditable', 'plaintext-only');
        el.focus();
        var range = document.createRange(); range.selectNodeContents(el);
        var sel = window.getSelection(); sel.removeAllRanges(); sel.addRange(range);
        post({ type: 'editing', id: id });
      }, true);
      function finishEditing(){
        if (!editing) return;
        var el = editing; editing = null;
        el.removeAttribute('contenteditable');
        var id = +el.getAttribute(ATTR);
        var s = srcEl(id);
        var text = el.innerText.replace(/\n+$/, '');
        if (isStickyNote(el)) el.textContent = text;
        if (s && s.textContent !== text) {
          s.textContent = text; el.textContent = text;
          post({ type: 'changed', result: JSON.parse(result(id, true)) });
        } else {
          post({ type: 'select', props: props(id) });
        }
      }
      document.addEventListener('focusout', function(e){ if (editing && e.target === editing) finishEditing(); }, true);
      document.addEventListener('keydown', function(e){
        if (editing) {
          if (e.key === 'Escape' || (e.key === 'Enter' && !e.shiftKey)) { e.preventDefault(); editing.blur(); }
          return;
        }
        if (mode === 'off') return;
        // ⌘ / ⌃ 组合键不拦截，交给应用菜单（撤销、复制、全屏、缩放等快捷键）
        if (e.metaKey || e.ctrlKey) return;
        e.preventDefault(); e.stopPropagation();
        post({ type: 'key', key: e.key, meta: e.metaKey, shift: e.shiftKey, alt: e.altKey, ctrl: e.ctrlKey });
      }, true);

      // ---------- 网页画板：高度随内容 ----------
      // 网页按真实浏览器的视口高度排版（vh 固定为一屏，不随画板变高而变高），
      // 再把整页内容高度报给 Swift，画板随之变高，内容不会被画板截掉。
      var fit = { on: false, vh: 900, last: -1, timer: null, observer: null };
      var vhOriginal = new WeakMap(), pinnedRules = [];
      var VH_RE = /(-?\d*\.?\d+)(dvh|svh|lvh|vh|vmin|vmax)\b/gi;
      function vhToPx(text){
        var vw = document.documentElement.clientWidth || window.innerWidth;
        return text.replace(VH_RE, function(m, n, unit){
          unit = unit.toLowerCase();
          var base = unit === 'vmin' ? Math.min(vw, fit.vh) : unit === 'vmax' ? Math.max(vw, fit.vh) : fit.vh;
          return (Math.round(parseFloat(n) * base) / 100) + 'px';
        });
      }
      function pinStyle(style){
        var changes = [];
        for (var i = 0; i < style.length; i++) {
          var name = style[i], v = style.getPropertyValue(name);
          VH_RE.lastIndex = 0;
          if (v && VH_RE.test(v)) changes.push([name, v, style.getPropertyPriority(name)]);
        }
        changes.forEach(function(c){ style.setProperty(c[0], vhToPx(c[1]), c[2]); });
        return changes.length > 0;
      }
      function pinRules(rules){
        for (var i = 0; i < rules.length; i++) {
          var r = rules[i];
          if (r.style) {
            var before = r.style.cssText;
            if (pinStyle(r.style) && !vhOriginal.has(r)) { vhOriginal.set(r, before); pinnedRules.push([r, before]); }
          } else if (r.cssRules) { try { pinRules(r.cssRules); } catch(_) {} }
        }
      }
      function pinViewportUnits(){
        for (var i = 0; i < document.styleSheets.length; i++) {
          var sheet = document.styleSheets[i], owner = sheet.ownerNode;
          if (owner && (owner.id === '__ds-editor-style' || owner.id === '__ds-fit-style')) continue;
          try { pinRules(sheet.cssRules); } catch(_) {}   // 跨域样式表读不到规则
        }
        document.querySelectorAll('[style]').forEach(function(el){ pinStyle(el.style); });
      }
      function unpinViewportUnits(){
        pinnedRules.forEach(function(p){ p[0].style.cssText = p[1]; vhOriginal.delete(p[0]); });
        pinnedRules = [];
      }
      function contentHeight(){
        var b = document.body; if (!b) return 0;
        var cs = window.getComputedStyle(b);
        // body 上的 overflow:hidden 会作用到整个视口，超出一屏的内容也算进来，画板长高后就能看到
        var h = Math.max(b.scrollHeight, b.offsetHeight);
        return Math.ceil(h + (parseFloat(cs.marginTop) || 0) + (parseFloat(cs.marginBottom) || 0));
      }
      function applyFitStyle(){
        var s = document.getElementById('__ds-fit-style');
        if (!fit.on) { if (s) s.remove(); return; }
        if (!s) { s = document.createElement('style'); s.id = '__ds-fit-style'; document.documentElement.appendChild(s); }
        // 页面不能把自己锁成画板高度：html / body 随内容增高，至少一屏
        s.textContent = 'html,body{height:auto!important;max-height:none!important}body{min-height:' + fit.vh + 'px!important}';
      }
      function scheduleFit(force){
        if (!fit.on) return;
        if (force) fit.last = -1;
        clearTimeout(fit.timer);
        fit.timer = setTimeout(function(){
          pinViewportUnits();
          var h = contentHeight();
          if (h > 0 && Math.abs(h - fit.last) > 1) { fit.last = h; post({ type: 'contentHeight', h: h }); }
        }, 120);
      }
      window.addEventListener('resize', function(){ scheduleFit(true); });
      window.addEventListener('load', function(){ scheduleFit(true); });

      // ---------- 供 Swift 调用的接口 ----------
      window.__ds = {
        // 画布共用样式改了：就地替换，不重新加载画板
        setShared: function(css){
          var s = document.getElementById('__ds-shared');
          if (!s) { s = document.createElement('style'); s.id = '__ds-shared'; (document.head || document.documentElement).prepend(s); }
          s.textContent = css || '';
          scheduleFit(true);
        },
        fitContent: function(on, vh){
          fit.on = !!on;
          if (vh) fit.vh = vh;
          applyFitStyle();
          if (fit.on) {
            if (!fit.observer && window.ResizeObserver) fit.observer = new ResizeObserver(function(){ scheduleFit(false); });
            if (fit.observer && document.body) fit.observer.observe(document.body);
            pinViewportUnits();
            scheduleFit(true);
          } else {
            if (fit.observer) fit.observer.disconnect();
            unpinViewportUnits();
          }
        },
        init: function(source, m){
          src = new DOMParser().parseFromString(source, 'text/html');
          maxId = 0;
          src.querySelectorAll('[' + ATTR + ']').forEach(function(el){ maxId = Math.max(maxId, +el.getAttribute(ATTR)); });
          setMode(m || 'select');
          return JSON.stringify({ tree: tree() });
        },
        setMode: setMode,
        trackSelection: trackSelection,
        tree: function(){ return JSON.stringify(tree()); },
        props: function(id){ selectedId = id; selectedIds = id != null ? [id] : []; return JSON.stringify(props(id)); },
        rect: function(id){ var el = live(id); return el ? JSON.stringify(rectOf(el)) : null; },
        locate: function(selector){
          try { var el = document.querySelector(selector); var id = idOf(el); return id == null ? null : JSON.stringify({ id: id, rect: rectOf(live(id)) }); }
          catch(_) { return null; }
        },
        outer: function(id){
          var s = srcEl(id); if (!s) return null;
          var c = s.cloneNode(true);
          [c].concat(Array.prototype.slice.call(c.querySelectorAll('[' + ATTR + ']'))).forEach(function(x){ x.removeAttribute(ATTR); });
          return c.outerHTML;
        },
        // 代码面板：样式展开后的元素代码（命中的 CSS 规则合并为行内样式，去掉 class）
        inlined: function(id){
          var s = srcEl(id); if (!s) return null;
          var c = s.cloneNode(true);
          [c].concat(Array.prototype.slice.call(c.querySelectorAll('[' + ATTR + ']'))).forEach(function(x){
            var l = live(x.getAttribute(ATTR));
            x.__decls = l ? cascade(l, x.getAttribute('style') || '', x === c) : declsOf(x.getAttribute('style') || '').map(function(d){ return d.name + ': ' + d.value; });
            x.removeAttribute(ATTR);
            x.removeAttribute('class');
            x.removeAttribute('style');
          });
          return pretty(c, 0);
        },
        setStyle: function(id, map){
          both(id, function(el){ setInlineStyle(el, map); });
          return result(id, true);
        },
        patchElement: function(id, text, style){
          var a = live(id), b = srcEl(id);
          if (!a || !b || (text !== null && (a.childElementCount || b.childElementCount))) return null;
          [a, b].forEach(function(el){
            if (text !== null) el.textContent = text;
            if (style !== null) setInlineStyle(el, style);
          });
          return result(id, true);
        },
        // 右键菜单的编辑操作（实时页面和源码 DOM 同步修改）
        moveToEdge: function(id, last){
          both(id, function(el){
            var p = el.parentElement; if (!p) return;
            if (last) p.appendChild(el); else p.insertBefore(el, p.firstChild);
          });
          return result(id, true);
        },
        wrap: function(id, html){
          var a = live(id), b = srcEl(id);
          var wa = fragment(html, document), wb = fragment(html, src || document);
          if (!a || !b || !wa || !wb) return result(id, false);
          var nid = stamp(wa, wb);
          a.before(wa); wa.appendChild(a);
          b.before(wb); wb.appendChild(b);
          selectedId = nid;
          return result(nid, true);
        },
        flip: function(id, axis){
          var token = axis === 'x' ? 'scaleX(-1)' : 'scaleY(-1)';
          both(id, function(el){
            var t = el.style.transform || '';
            t = t.indexOf(token) >= 0 ? t.replace(token, '').replace(/\s+/g, ' ').trim() : (t + ' ' + token).trim();
            if (t) el.style.transform = t; else el.style.removeProperty('transform');
            if (!el.getAttribute('style')) el.removeAttribute('style');
          });
          return result(id, false);
        },
        insertAfter: function(id, html){
          var a = live(id), b = srcEl(id);
          var na = fragment(html, document), nb = fragment(html, src || document);
          if (!a || !b || !na || !nb) return result(null, false);
          [na, nb].forEach(stripPrototypeLinks);
          var nid = stamp(na, nb);
          a.after(na); b.after(nb);
          selectedId = nid;
          return result(nid, true);
        },
        // 拷贝属性：元素最终生效的样式（不含定位相关的属性），粘贴时作为行内样式写入
        styleOf: function(id){
          var el = live(id), s = srcEl(id); if (!el || !s) return null;
          var skip = /^(position|left|top|right|bottom|inset|z-index|order|grid-(area|row|column).*|margin.*|translate)$/;
          var out = {};
          cascade(el, s.getAttribute('style') || '', false).forEach(function(d){
            var i = d.indexOf(': ');
            var name = d.slice(0, i), value = d.slice(i + 2);
            if (!skip.test(name)) out[name] = value;
          });
          return JSON.stringify(out);
        },
        setText: function(id, text){ both(id, function(el){ el.textContent = text; }); return result(id, true); },
        setAttr: function(id, name, value){
          both(id, function(el){ if (value === '' || value == null) el.removeAttribute(name); else el.setAttribute(name, value); });
          return result(id, true);
        },
        // 编组：把一个或多个元素（按文档顺序）放进 display:contents 的容器，不改变原来的布局
        groupMany: function(ids){
          var pairs = ids.map(function(id){ return { a: live(id), b: srcEl(id) }; }).filter(function(p){ return p.a && p.b; });
          if (!pairs.length) return result(selectedId, false);
          pairs.sort(function(x, y){ return (x.a.compareDocumentPosition(y.a) & Node.DOCUMENT_POSITION_FOLLOWING) ? -1 : 1; });
          var html = '<div data-name="编组" data-group="" style="display:contents"></div>';
          var wa = fragment(html, document), wb = fragment(html, src || document);
          var nid = stamp(wa, wb);
          pairs[0].a.before(wa); pairs[0].b.before(wb);
          pairs.forEach(function(p){ wa.appendChild(p.a); wb.appendChild(p.b); });
          selectedId = nid; selectedIds = [nid];
          return result(nid, true);
        },
        // 取消编组：子元素放回原处，并全部选中
        ungroup: function(id){
          var a = live(id), b = srcEl(id);
          if (!a || !b || !isGroup(a)) return result(id, false);
          var kids = Array.prototype.filter.call(a.children, function(c){ return c.hasAttribute(ATTR); })
            .map(function(c){ return +c.getAttribute(ATTR); });
          [a, b].forEach(function(el){
            while (el.firstChild) el.parentNode.insertBefore(el.firstChild, el);
            el.remove();
          });
          selectedIds = kids;
          selectedId = kids.length ? kids[kids.length - 1] : null;
          return result(selectedId, true);
        },
        removeMany: function(ids){
          ids.forEach(function(id){ both(id, function(el){ el.remove(); }); });
          selectedId = null; selectedIds = [];
          return result(null, true);
        },
        remove: function(id){
          both(id, function(el){ el.remove(); });
          selectedId = null;
          return result(null, true);
        },
        duplicate: function(id){
          var a = live(id), b = srcEl(id);
          if (!a || !b) return result(id, false);
          var ca = a.cloneNode(true), cb = b.cloneNode(true);
          [ca, cb].forEach(stripPrototypeLinks);
          var nid = stamp(ca, cb);
          a.after(ca); b.after(cb);
          var cs = window.getComputedStyle(ca);
          if (cs.position === 'absolute' || cs.position === 'fixed') {
            var l = (parseFloat(cs.left) || 0) + 16 + 'px', t = (parseFloat(cs.top) || 0) + 16 + 'px';
            ca.style.left = l; ca.style.top = t; cb.style.left = l; cb.style.top = t;
          }
          selectedId = nid;
          return result(nid, true);
        },
        // 在 body 中插入元素；给出坐标时使用绝对定位
        insert: function(html, x, y){
          var a = fragment(html, document), b = fragment(html, src || document);
          if (!a) return result(null, false);
          [a, b].forEach(stripPrototypeLinks);
          var nid = stamp(a, b || a.cloneNode(true));
          if (x != null && y != null) {
            [a, b].forEach(function(el){ if (!el) return; el.style.position = 'absolute'; el.style.left = Math.round(x) + 'px'; el.style.top = Math.round(y) + 'px'; });
          }
          document.body.appendChild(a);
          if (src && b) src.body.appendChild(b);
          selectedId = nid;
          return result(nid, true);
        },
        replaceOuter: function(id, html){
          var a = live(id), b = srcEl(id);
          var na = fragment(html, document), nb = fragment(html, src || document);
          if (!a || !b || !na || !nb) return result(id, false);
          var nid = stamp(na, nb);
          a.replaceWith(na); b.replaceWith(nb);
          selectedId = nid;
          return result(nid, true);
        },
        setVar: function(name, value){
          if (value == null) document.documentElement.style.removeProperty(name);
          else document.documentElement.style.setProperty(name, value);
        },
        contentSize: function(){ return JSON.stringify({ w: document.documentElement.scrollWidth, h: document.documentElement.scrollHeight }); }
      };
      // DOM 就绪即可初始化，不必等外部字体等资源加载完成
      post({ type: 'ready' });
    })();
    """#
}
