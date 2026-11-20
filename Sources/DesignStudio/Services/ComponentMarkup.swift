import Foundation

/// Materialize component instances in the saved HTML so every export can render them directly.
nonisolated enum ComponentMarkup {
    nonisolated struct Capture: Decodable, Sendable {
        let html: String
        let text: String?
    }

    private static let helpers = #"""
    const componentAttr = 'data-ds-component', textAttr = 'data-ds-component-text';
    const instanceAttr = 'data-ds-component-instance';
    const placement = ['position','top','right','bottom','left','inset','z-index','order','grid-area',
                       'align-self','justify-self','translate','margin-top','margin-right','margin-bottom','margin-left'];
    function element(html, doc = document) {
      const template = doc.createElement('template');
      template.innerHTML = html.trim();
      return template.content.firstElementChild;
    }
    function textNode(root) {
      const walker = root.ownerDocument.createTreeWalker(root, NodeFilter.SHOW_TEXT);
      for (let node = walker.nextNode(); node; node = walker.nextNode()) {
        if (node.data.trim() && !node.parentElement.closest('style,script,template,svg')) return node;
      }
      return null;
    }
    function rewriteIDs(root, prefix, replacement) {
      const nodes = [root, ...root.querySelectorAll('*')];
      const names = new Map();
      for (const node of nodes) {
        const id = node.id;
        if (!id || (prefix && !id.startsWith(prefix))) continue;
        const name = replacement + id.slice(prefix.length);
        names.set(id, name);
        node.id = name;
      }
      for (const node of nodes) {
        for (const attr of Array.from(node.attributes)) {
          let value = attr.value;
          if (['href','xlink:href'].includes(attr.name) && value.startsWith('#'))
            value = '#' + (names.get(value.slice(1)) || value.slice(1));
          if (['for','list','aria-labelledby','aria-describedby','aria-controls','headers'].includes(attr.name))
            value = value.split(/\s+/).map(id => names.get(id) || id).join(' ');
          value = value.replace(/url\(#([^)]+)\)/g, (all, id) => names.has(id) ? 'url(#' + names.get(id) + ')' : all);
          if (value !== attr.value) attr.value = value;
        }
      }
    }
    function instance(html, id, token, doc = document) {
      const root = element(html, doc);
      if (!root) return null;
      root.setAttribute(componentAttr, id);
      if (token) {
        root.setAttribute(instanceAttr, token);
        rewriteIDs(root, '', 'ds-' + token + '-');
      }
      return root;
    }
    """#

    static let capture = helpers + #"""

    const selected = document.querySelector('[data-ds-id="' + elementID + '"]');
    if (selected?.parentElement?.closest('[' + componentAttr + ']')) return null;
    const html = window.__ds.inlined(elementID);
    const root = html && element(html);
    if (!root || root.querySelector('[' + componentAttr + ']')) return null;
    const token = root.getAttribute(instanceAttr);
    if (token) rewriteIDs(root, 'ds-' + token + '-', '');
    const text = textNode(root);
    if (text && root.hasAttribute(textAttr) && typeof defaultText === 'string') text.data = defaultText;
    root.removeAttribute(componentAttr);
    root.removeAttribute(textAttr);
    root.removeAttribute(instanceAttr);
    placement.forEach(key => root.style.removeProperty(key));
    return JSON.stringify({html: root.outerHTML, text: text?.data ?? null});
    """#

    static let insert = helpers + #"""

    const root = instance(markup, componentID, token);
    return root ? window.__ds.insert(root.outerHTML, null, null) : null;
    """#

    static let rewrite = helpers + #"""

    return JSON.stringify(documents.map(html => {
      const doc = new DOMParser().parseFromString(html, 'text/html');
      let changed = false;
      for (const root of doc.querySelectorAll('[' + componentAttr + ']')) {
        if (root.getAttribute(componentAttr) !== componentID) continue;
        if (markup === null) {
          [componentAttr, textAttr, instanceAttr].forEach(attr => root.removeAttribute(attr));
        } else {
          const next = instance(markup, componentID, root.getAttribute(instanceAttr), doc);
          if (!next) continue;
          const override = root.getAttribute(textAttr);
          const text = textNode(next);
          if (override !== null && text) {
            text.data = override;
            next.setAttribute(textAttr, override);
          }
          for (const key of placement) {
            const value = root.style.getPropertyValue(key);
            if (value) next.style.setProperty(key, value, root.style.getPropertyPriority(key));
          }
          root.replaceWith(next);
        }
        changed = true;
      }
      if (!changed) return html;
      const doctype = doc.doctype ? new XMLSerializer().serializeToString(doc.doctype) + '\n' : '';
      return doctype + doc.documentElement.outerHTML;
    }));
    """#
}
