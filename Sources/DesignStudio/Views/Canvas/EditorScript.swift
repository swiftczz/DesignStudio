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
      var editing = null;            // 正在行内编辑文字的元素
      var drag = null;               // 正在拖动的绝对定位元素

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
          if (sheet.ownerNode && sheet.ownerNode.id === '__ds-editor-style') continue;
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
          if (best >= 0) matched.push({ spec: best, order: order, decls: declsOf(r.style.cssText) });
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
      function rectOf(el){ var r = el.getBoundingClientRect(); return { x: r.left, y: r.top, w: r.width, h: r.height }; }

      var INLINE = ['br','b','strong','i','em','span','small','sup','sub','code','mark','u','s','a','label'];
      function isTextLeaf(el){
        if (!el || !(el.textContent || '').trim()) return false;
        for (var i = 0; i < el.children.length; i++) {
          var c = el.children[i];
          if (INLINE.indexOf(c.tagName.toLowerCase()) < 0 || c.children.length) return false;
        }
        return true;
      }
      function kindOf(el){
        var t = el.tagName.toLowerCase();
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
        'border-top-color','box-shadow','left','top','z-index','flex-grow','overflow','object-fit'];
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
                 selector: selectorFor(el), parentId: idOf(el.parentElement), childCount: el.children.length };
      }

      function serialize(){ return src ? '<!DOCTYPE html>\n' + src.documentElement.outerHTML : null; }
      function both(id, fn){ var a = live(id), b = srcEl(id); if (a) fn(a); if (b) fn(b); }
      function result(id, withTree){
        var r = { id: id, props: id != null ? props(id) : null, source: serialize() };
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
        mode = m;
        document.documentElement.classList.toggle('__ds-editing', m !== 'off');
        if (m === 'off') { hoverId = null; }
      }
      var css = document.createElement('style');
      css.id = '__ds-editor-style';
      css.textContent = 'html.__ds-editing, html.__ds-editing *{cursor:default!important;-webkit-user-select:none!important;user-select:none!important}'
        + 'html.__ds-editing [contenteditable]{cursor:text!important;-webkit-user-select:text!important;user-select:text!important;outline:none}';
      document.documentElement.appendChild(css);
      setMode('select');

      // ---------- 事件 ----------
      // 注意：pointerdown 里调用了 preventDefault，浏览器不会再派发 mousedown / mouseup，所以统一用 pointer 事件
      document.addEventListener('pointermove', function(e){
        if (mode === 'off' || editing) return;
        if (drag) {
          var dx = e.clientX - drag.x0, dy = e.clientY - drag.y0;
          if (Math.abs(dx) + Math.abs(dy) > 2) drag.moved = true;
          drag.el.style.left = Math.round(drag.l0 + dx) + 'px';
          drag.el.style.top = Math.round(drag.t0 + dy) + 'px';
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
      ['mousedown','mouseup','click','auxclick','contextmenu','submit','touchstart','dragstart'].forEach(function(t){
        document.addEventListener(t, function(e){ block(e); }, true);
      });
      document.addEventListener('pointerdown', function(e){
        if (!block(e)) return;
        if (e.button !== 0) return;
        if (editing) finishEditing();
        var id = idOf(e.target);
        if (mode === 'comment') { if (id != null) post({ type: 'commentPick', props: props(id) }); return; }
        if (id == null) { selectedId = null; post({ type: 'select', props: null }); return; }
        var el = live(id);
        var cs = window.getComputedStyle(el);
        if (id === selectedId && (cs.position === 'absolute' || cs.position === 'fixed')) {
          drag = { id: id, el: el, x0: e.clientX, y0: e.clientY, l0: parseFloat(cs.left) || 0, t0: parseFloat(cs.top) || 0, moved: false };
          try { document.documentElement.setPointerCapture(e.pointerId); } catch(_) {}
          return;
        }
        selectedId = id;
        post({ type: 'select', props: props(id) });
      }, true);
      document.addEventListener('pointerup', function(e){
        if (!block(e)) return;
        if (drag) {
          var d = drag; drag = null;
          if (d.moved) {
            var s = srcEl(d.id);
            if (s) { s.style.left = d.el.style.left; s.style.top = d.el.style.top; }
            post({ type: 'changed', result: JSON.parse(result(d.id, false)) });
          }
        }
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

      // ---------- 供 Swift 调用的接口 ----------
      window.__ds = {
        init: function(source, m){
          src = new DOMParser().parseFromString(source, 'text/html');
          maxId = 0;
          src.querySelectorAll('[' + ATTR + ']').forEach(function(el){ maxId = Math.max(maxId, +el.getAttribute(ATTR)); });
          setMode(m || 'select');
          return JSON.stringify({ tree: tree() });
        },
        setMode: setMode,
        tree: function(){ return JSON.stringify(tree()); },
        props: function(id){ selectedId = id; return JSON.stringify(props(id)); },
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
          both(id, function(el){
            Object.keys(map).forEach(function(k){
              var v = map[k];
              if (v === '' || v == null) el.style.removeProperty(k); else el.style.setProperty(k, v);
            });
            if (!el.getAttribute('style')) el.removeAttribute('style');
          });
          return result(id, true);
        },
        setText: function(id, text){ both(id, function(el){ el.textContent = text; }); return result(id, true); },
        setAttr: function(id, name, value){
          both(id, function(el){ if (value === '' || value == null) el.removeAttribute(name); else el.setAttribute(name, value); });
          return result(id, true);
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
