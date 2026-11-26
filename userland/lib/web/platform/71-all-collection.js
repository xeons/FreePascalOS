// HTML Standard 2.6.2.1 and 3.1.5: document.all, an HTMLAllCollection
// with [[IsHTMLDDA]] (natives.markHtmlDda): it is every element of the
// document in tree order, by index and by name (id, or the name of the
// elements that have one), and callable as item(); yet typeof gives
// "undefined" and it is false, so the old "if (document.all)" browser
// tests take the standard path. Libraries rely on both halves (Polymer
// resin compares values with document.all).
(function (natives, global, internal) {
  "use strict";
  const DocumentClass = global.Document;
  if (typeof DocumentClass !== "function" || typeof natives.markHtmlDda !== "function") return;
  const NAMED = new Set(["a", "button", "embed", "form", "frame", "frameset", "iframe", "img", "input", "map",
    "meta", "object", "select", "textarea"]);
  const HTML_NAMESPACE = "http://www.w3.org/1999/xhtml";
  const elementLists = new WeakMap();
  const collections = new WeakMap();

  function listOf(collection) {
    const list = elementLists.get(collection);
    if (list === undefined) throw new TypeError("Illegal invocation");
    return list;
  }

  function isIndex(key) {
    return typeof key === "string" && /^(0|[1-9][0-9]*)$/.test(key) && Number(key) < 4294967295;
  }

  function hasName(element, name) {
    if (element.id === name) return true;
    return element.namespaceURI === HTML_NAMESPACE && NAMED.has(element.localName) &&
      element.getAttribute("name") === name;
  }

  function namedItem(list, name) {
    const found = [];
    for (let index = 0; index < list.length; index++)
      if (hasName(list[index], name)) found.push(list[index]);
    if (found.length === 0) return null;
    return found.length === 1 ? found[0] : Object.freeze(found);
  }

  function item(list, nameOrIndex) {
    if (nameOrIndex === undefined) return null;
    const key = String(nameOrIndex);
    if (isIndex(key)) {
      const element = list[Number(key)];
      return element === undefined ? null : element;
    }
    return namedItem(list, key);
  }

  class HTMLAllCollection {
    constructor() {
      internal.illegal();
    }
    get length() { return listOf(this).length; }
    item(nameOrIndex) { return item(listOf(this), nameOrIndex); }
    namedItem(name) {
      if (arguments.length < 1)
        throw new TypeError("Failed to execute 'namedItem' on 'HTMLAllCollection': 1 argument required, but only 0 " +
          "present.");
      return namedItem(listOf(this), String(name));
    }
    *[Symbol.iterator]() {
      const list = listOf(this);
      for (let index = 0; index < list.length; index++) yield list[index];
    }
  }
  const prototype = HTMLAllCollection.prototype;
  Object.defineProperty(prototype, Symbol.toStringTag, { value: "HTMLAllCollection", configurable: true });
  for (const name of ["length", "item", "namedItem"]) {
    const descriptor = Object.getOwnPropertyDescriptor(prototype, name);
    descriptor.enumerable = true;
    Object.defineProperty(prototype, name, descriptor);
  }
  internal.define(global, "HTMLAllCollection", HTMLAllCollection);

  function makeCollection(document) {
    const list = document.getElementsByTagName("*");
    const handler = {
      get(target, key, receiver) {
        if (isIndex(key)) return list[Number(key)];
        if (typeof key === "symbol" || key in prototype) return Reflect.get(prototype, key, receiver);
        const found = namedItem(list, key);
        return found === null ? undefined : found;
      },
      has(target, key) {
        if (isIndex(key)) return Number(key) < list.length;
        if (typeof key === "symbol" || key in prototype) return key in prototype;
        return namedItem(list, key) !== null;
      },
      getOwnPropertyDescriptor(target, key) {
        let value;
        if (isIndex(key)) value = list[Number(key)];
        else if (typeof key === "string" && !(key in prototype)) {
          const found = namedItem(list, key);
          value = found === null ? undefined : found;
        }
        if (value === undefined) return Reflect.getOwnPropertyDescriptor(target, key);
        return { value: value, writable: false, enumerable: isIndex(key), configurable: true };
      },
      ownKeys(target) {
        const keys = [];
        for (let index = 0; index < list.length; index++) keys.push(String(index));
        return keys.concat(Reflect.ownKeys(target));
      },
      set() { return false; },
      defineProperty() { return false; },
      deleteProperty(target, key) { return !(isIndex(key) && Number(key) < list.length); },
      getPrototypeOf() { return prototype; },
      apply(target, thisArgument, args) { return item(list, args[0]); }
    };
    // An arrow function is callable and has no prototype property of its
    // own to keep the proxy's answers consistent with.
    const collection = new Proxy(() => {}, handler);
    elementLists.set(collection, list);
    natives.markHtmlDda(collection);
    return collection;
  }

  Object.defineProperty(DocumentClass.prototype, "all", {
    get: function () {
      if (!(this instanceof DocumentClass)) throw new TypeError("Illegal invocation");
      let collection = collections.get(this);
      if (collection === undefined) {
        collection = makeCollection(this);
        collections.set(this, collection);
      }
      return collection;
    },
    enumerable: true,
    configurable: true
  });
})
