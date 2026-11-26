// XMLSerializer (DOM Parsing and Serialization, "produce an XML
// serialization" with the require well-formed flag unset): elements with
// the namespace declarations their prefixes need (a namespace prefix map
// per element, generated ns1, ns2 ... prefixes when a prefix is taken),
// attributes, text and CDATA, comments, processing instructions, the
// document type, documents and fragments. HTML elements without children
// close as "<br />", other childless elements as "<x/>"; a template
// serializes its contents. XMLHttpRequest sends a Document this way.
(function (natives, global, internal) {
  "use strict";
  if (typeof global.Node !== "function") return;
  const HTML_NS = "http://www.w3.org/1999/xhtml";
  const XML_NS = "http://www.w3.org/XML/1998/namespace";
  const XMLNS_NS = "http://www.w3.org/2000/xmlns/";
  const VOID_ELEMENTS = new Set(["area", "base", "basefont", "bgsound", "br", "col", "embed", "frame", "hr", "img",
    "input", "keygen", "link", "menuitem", "meta", "param", "source", "track", "wbr"]);

  function escapeText(text) {
    return text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  }
  function escapeAttribute(text) {
    return text.replace(/&/g, "&amp;").replace(/"/g, "&quot;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
      .replace(/\t/g, "&#x9;").replace(/\n/g, "&#xA;").replace(/\r/g, "&#xD;");
  }

  // A namespace prefix map: namespace (null as "") -> prefixes, newest last.
  function copyMap(map) {
    const copy = new Map();
    for (const [namespace, prefixes] of map) copy.set(namespace, prefixes.slice());
    return copy;
  }
  function addToMap(map, namespace, prefix) {
    const key = namespace === null ? "" : namespace;
    const prefixes = map.get(key);
    if (prefixes === undefined) map.set(key, [prefix]);
    else prefixes.push(prefix);
  }
  function preferredPrefix(map, namespace, preferred) {
    const prefixes = map.get(namespace === null ? "" : namespace);
    if (prefixes === undefined) return null;
    if (prefixes.indexOf(preferred) >= 0) return preferred;
    return prefixes[prefixes.length - 1];
  }
  function generatePrefix(map, namespace, state) {
    const prefix = "ns" + state.index;
    state.index++;
    addToMap(map, namespace, prefix);
    return prefix;
  }
  // The xmlns attributes of an element go into the map; returns the
  // default namespace it declares (null when none).
  function recordNamespaces(element, map, localPrefixes) {
    let defaultNamespace = null;
    for (const attribute of Array.from(element.attributes)) {
      if (attribute.namespaceURI !== XMLNS_NS) continue;
      if (attribute.prefix === null) {
        defaultNamespace = attribute.value;
        continue;
      }
      const prefix = attribute.localName;
      const namespace = attribute.value;
      const prefixes = map.get(namespace);
      if (prefixes !== undefined && prefixes.indexOf(prefix) >= 0) continue;
      addToMap(map, namespace, prefix);
      localPrefixes[prefix] = namespace;
    }
    return defaultNamespace;
  }

  function serializeAttributes(element, map, localPrefixes, ignoreDefault, state) {
    let result = "";
    for (const attribute of Array.from(element.attributes)) {
      const namespace = attribute.namespaceURI;
      let candidate = null;
      if (namespace === XMLNS_NS) {
        if (attribute.prefix === null && ignoreDefault) continue;
        if (attribute.prefix !== null && localPrefixes[attribute.localName] !== attribute.value &&
          preferredPrefix(map, attribute.value, attribute.localName) !== attribute.localName) continue;
        candidate = "xmlns";
        if (attribute.prefix === null) candidate = null;
      } else if (namespace !== null) {
        candidate = preferredPrefix(map, namespace, attribute.prefix);
        if (namespace === XML_NS) candidate = "xml";
        else if (candidate === null) {
          candidate = generatePrefix(map, namespace, state);
          result += " xmlns:" + candidate + "=\"" + escapeAttribute(namespace) + "\"";
        }
      }
      result += " " + (candidate !== null ? candidate + ":" : "") +
        (namespace === XMLNS_NS && attribute.prefix === null ? "xmlns" : attribute.localName) +
        "=\"" + escapeAttribute(attribute.value) + "\"";
    }
    return result;
  }

  function serializeElement(element, namespace, parentMap, state) {
    const map = copyMap(parentMap);
    const localPrefixes = Object.create(null);
    const localDefault = recordNamespaces(element, map, localPrefixes);
    const elementNamespace = element.namespaceURI;
    let inherited = namespace;
    let ignoreDefault = false;
    let qualifiedName;
    let markup = "<";
    if (inherited === elementNamespace) {
      if (localDefault !== null) ignoreDefault = true;
      qualifiedName = elementNamespace === XML_NS ? "xml:" + element.localName : element.localName;
      markup += qualifiedName;
    } else {
      let prefix = element.prefix;
      const candidate = prefix === "xmlns" ? null : preferredPrefix(map, elementNamespace, prefix);
      if (candidate !== null && (candidate !== "" || elementNamespace === XML_NS)) {
        qualifiedName = candidate + ":" + element.localName;
        if (localDefault !== null && localDefault !== XML_NS) inherited = localDefault === "" ? null : localDefault;
        markup += qualifiedName;
      } else if (prefix !== null) {
        if (prefix in localPrefixes) prefix = generatePrefix(map, elementNamespace, state);
        else addToMap(map, elementNamespace, prefix);
        qualifiedName = prefix + ":" + element.localName;
        markup += qualifiedName + " xmlns:" + prefix + "=\"" + escapeAttribute(elementNamespace || "") + "\"";
        if (localDefault !== null) inherited = localDefault === "" ? null : localDefault;
      } else if (localDefault === null || localDefault !== (elementNamespace || "")) {
        ignoreDefault = true;
        qualifiedName = element.localName;
        inherited = elementNamespace;
        markup += qualifiedName + " xmlns=\"" + escapeAttribute(elementNamespace || "") + "\"";
      } else {
        qualifiedName = element.localName;
        inherited = elementNamespace;
        markup += qualifiedName;
      }
    }
    markup += serializeAttributes(element, map, localPrefixes, ignoreDefault, state);
    const children = elementNamespace === HTML_NS && element.localName === "template" && element.content ?
      element.content.childNodes : element.childNodes;
    if (children.length === 0) {
      if (elementNamespace === HTML_NS) {
        if (VOID_ELEMENTS.has(element.localName)) return markup + " />";
      } else {
        return markup + "/>";
      }
    }
    markup += ">";
    for (const child of Array.from(children)) markup += serialize(child, inherited, map, state);
    return markup + "</" + qualifiedName + ">";
  }

  function serialize(node, namespace, map, state) {
    switch (node.nodeType) {
      case 1: return serializeElement(node, namespace, map, state);
      case 3: return escapeText(node.data);
      case 4: return "<![CDATA[" + node.data + "]]>";
      case 7: return "<?" + node.target + " " + node.data + "?>";
      case 8: return "<!--" + node.data + "-->";
      case 10: {
        let markup = "<!DOCTYPE " + node.name;
        if (node.publicId !== "") markup += " PUBLIC \"" + node.publicId + "\"";
        else if (node.systemId !== "") markup += " SYSTEM";
        if (node.systemId !== "") markup += " \"" + node.systemId + "\"";
        return markup + ">";
      }
      case 9: case 11: {
        let markup = "";
        for (const child of Array.from(node.childNodes)) markup += serialize(child, namespace, map, state);
        return markup;
      }
      case 2: return "";
      default: return "";
    }
  }

  function serializeToString(root) {
    const map = new Map();
    addToMap(map, XML_NS, "xml");
    return serialize(root, null, map, { index: 1 });
  }
  internal.serializeXml = serializeToString;

  class XMLSerializer {
    serializeToString(root) {
      if (!(root instanceof global.Node)) throw new TypeError("serializeToString needs a Node");
      return serializeToString(root);
    }
  }
  internal.finishInterface(XMLSerializer, "XMLSerializer");
})
