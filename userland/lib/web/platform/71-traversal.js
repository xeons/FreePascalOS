// DOM traversal (DOM Standard 6): NodeFilter, TreeWalker and
// NodeIterator over the tree the DOM bindings give (parentNode,
// firstChild, nextSibling ...), made by document.createTreeWalker and
// createNodeIterator. Lit and the web components polyfills walk their
// templates with a TreeWalker (archive.org drew nothing without it).
// A NodeIterator is not moved when the node it rests on is removed.
(function (natives, global, internal) {
  "use strict";
  if (typeof global.Document !== "function" || typeof global.Node !== "function") return;
  const token = internal.token;
  const ACCEPT = 1, REJECT = 2, SKIP = 3;
  const state = new WeakMap();
  // The tree as the DOM has it, through the bindings' own getters: a
  // script that redefines firstChild and friends (the shadow DOM
  // polyfill) does not change what a walker sees.
  const NodePrototype = global.Node.prototype;
  function getterOf(name) {
    return Object.getOwnPropertyDescriptor(NodePrototype, name).get;
  }
  const parentOf = getterOf("parentNode"), firstOf = getterOf("firstChild"), lastOf = getterOf("lastChild"),
    nextOf = getterOf("nextSibling"), previousOf = getterOf("previousSibling"), typeOf = getterOf("nodeType");
  const parent = node => parentOf.call(node), first = node => firstOf.call(node), last = node => lastOf.call(node);
  const next = node => nextOf.call(node), previous = node => previousOf.call(node);

  const NodeFilter = {
    FILTER_ACCEPT: 1, FILTER_REJECT: 2, FILTER_SKIP: 3,
    SHOW_ALL: 0xFFFFFFFF, SHOW_ELEMENT: 0x1, SHOW_ATTRIBUTE: 0x2, SHOW_TEXT: 0x4, SHOW_CDATA_SECTION: 0x8,
    SHOW_ENTITY_REFERENCE: 0x10, SHOW_ENTITY: 0x20, SHOW_PROCESSING_INSTRUCTION: 0x40, SHOW_COMMENT: 0x80,
    SHOW_DOCUMENT: 0x100, SHOW_DOCUMENT_TYPE: 0x200, SHOW_DOCUMENT_FRAGMENT: 0x400, SHOW_NOTATION: 0x800
  };
  Object.defineProperty(global, "NodeFilter", { value: NodeFilter, writable: true, configurable: true });

  // The filter steps: whatToShow, then the filter (a function or an
  // object with acceptNode), not re-entered while it runs.
  function filterNode(data, node) {
    if (data.active) throw internal.domException("The filter is already running.", "InvalidStateError");
    const bit = 1 << (typeOf.call(node) - 1);
    if ((data.whatToShow & bit) === 0) return SKIP;
    const filter = data.filter;
    if (filter === null) return ACCEPT;
    data.active = true;
    try {
      let result;
      if (typeof filter === "function") result = filter.call(undefined, node);
      else result = filter.acceptNode.call(filter, node);
      return (Number(result) >>> 0) & 0xFFFF;
    } finally {
      data.active = false;
    }
  }

  function makeData(root, whatToShow, filter) {
    if (!(root instanceof global.Node)) throw new TypeError("parameter 1 is not of type 'Node'");
    return { root: root, whatToShow: whatToShow === undefined ? 0xFFFFFFFF : (whatToShow >>> 0),
      filter: filter === undefined || filter === null ? null : filter, active: false };
  }

  class TreeWalker {
    constructor(key, data) {
      if (key !== token) internal.illegal();
      data.current = data.root;
      state.set(this, data);
    }
    get root() { return state.get(this).root; }
    get whatToShow() { return state.get(this).whatToShow; }
    get filter() { return state.get(this).filter; }
    get currentNode() { return state.get(this).current; }
    set currentNode(node) {
      if (!(node instanceof global.Node)) throw new TypeError("The value is not a Node");
      state.get(this).current = node;
    }
    parentNode() {
      const data = state.get(this);
      let node = data.current;
      while (node !== null && node !== data.root) {
        node = parent(node);
        if (node !== null && filterNode(data, node) === ACCEPT) {
          data.current = node;
          return node;
        }
      }
      return null;
    }
    firstChild() { return traverseChildren(state.get(this), true); }
    lastChild() { return traverseChildren(state.get(this), false); }
    previousSibling() { return traverseSiblings(state.get(this), false); }
    nextSibling() { return traverseSiblings(state.get(this), true); }
    previousNode() {
      const data = state.get(this);
      let node = data.current;
      while (node !== data.root) {
        let sibling = previous(node);
        while (sibling !== null) {
          node = sibling;
          let result = filterNode(data, node);
          while (result !== REJECT && (first(node) !== null)) {
            node = last(node);
            result = filterNode(data, node);
          }
          if (result === ACCEPT) {
            data.current = node;
            return node;
          }
          sibling = previous(node);
        }
        if (node === data.root || parent(node) === null) return null;
        node = parent(node);
        if (filterNode(data, node) === ACCEPT) {
          data.current = node;
          return node;
        }
      }
      return null;
    }
    nextNode() {
      const data = state.get(this);
      let node = data.current;
      let result = ACCEPT;
      for (;;) {
        while (result !== REJECT && (first(node) !== null)) {
          node = first(node);
          result = filterNode(data, node);
          if (result === ACCEPT) {
            data.current = node;
            return node;
          }
        }
        let sibling = null;
        let temporary = node;
        while (temporary !== null) {
          if (temporary === data.root) return null;
          sibling = next(temporary);
          if (sibling !== null) {
            node = sibling;
            break;
          }
          temporary = parent(temporary);
        }
        if (temporary === null) return null;
        result = filterNode(data, node);
        if (result === ACCEPT) {
          data.current = node;
          return node;
        }
      }
    }
  }
  internal.finishInterface(TreeWalker, "TreeWalker");

  function traverseChildren(data, forward) {
    let node = forward ? first(data.current) : last(data.current);
    while (node !== null) {
      const result = filterNode(data, node);
      if (result === ACCEPT) {
        data.current = node;
        return node;
      }
      if (result === SKIP) {
        const child = forward ? first(node) : last(node);
        if (child !== null) {
          node = child;
          continue;
        }
      }
      while (node !== null) {
        const sibling = forward ? next(node) : previous(node);
        if (sibling !== null) {
          node = sibling;
          break;
        }
        const above = parent(node);
        if (above === null || above === data.root || above === data.current) return null;
        node = above;
      }
    }
    return null;
  }

  function traverseSiblings(data, forward) {
    let node = data.current;
    if (node === data.root) return null;
    for (;;) {
      let sibling = forward ? next(node) : previous(node);
      while (sibling !== null) {
        node = sibling;
        const result = filterNode(data, node);
        if (result === ACCEPT) {
          data.current = node;
          return node;
        }
        sibling = forward ? first(node) : last(node);
        if (result === REJECT || sibling === null) sibling = forward ? next(node) : previous(node);
      }
      node = parent(node);
      if (node === null || node === data.root) return null;
      if (filterNode(data, node) === ACCEPT) return null;
    }
  }

  // The node after (or before) node in tree order, within root.
  function following(node, root) {
    if (first(node) !== null) return first(node);
    while (node !== null && node !== root) {
      if (next(node) !== null) return next(node);
      node = parent(node);
    }
    return null;
  }
  function preceding(node, root) {
    if (node === root) return null;
    let sibling = previous(node);
    if (sibling === null) return parent(node);
    while (last(sibling) !== null) sibling = last(sibling);
    return sibling;
  }

  class NodeIterator {
    constructor(key, data) {
      if (key !== token) internal.illegal();
      data.reference = data.root;
      data.beforeReference = true;
      state.set(this, data);
    }
    get root() { return state.get(this).root; }
    get referenceNode() { return state.get(this).reference; }
    get pointerBeforeReferenceNode() { return state.get(this).beforeReference; }
    get whatToShow() { return state.get(this).whatToShow; }
    get filter() { return state.get(this).filter; }
    nextNode() { return traverseIterator(state.get(this), true); }
    previousNode() { return traverseIterator(state.get(this), false); }
    detach() {}
  }
  internal.finishInterface(NodeIterator, "NodeIterator");

  function traverseIterator(data, forward) {
    let node = data.reference;
    let before = data.beforeReference;
    for (;;) {
      if (forward) {
        if (!before) {
          node = following(node, data.root);
          if (node === null) return null;
        } else before = false;
      } else {
        if (before) {
          node = preceding(node, data.root);
          if (node === null) return null;
        } else before = true;
      }
      if (filterNode(data, node) === ACCEPT) break;
    }
    data.reference = node;
    data.beforeReference = before;
    return node;
  }

  internal.define(global.Document.prototype, "createTreeWalker", function createTreeWalker(root, whatToShow, filter) {
    return new TreeWalker(token, makeData(root, whatToShow, filter));
  });
  internal.define(global.Document.prototype, "createNodeIterator",
    function createNodeIterator(root, whatToShow, filter) {
      return new NodeIterator(token, makeData(root, whatToShow, filter));
    });
})
