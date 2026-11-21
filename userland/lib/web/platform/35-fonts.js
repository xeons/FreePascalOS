// CSS Font Loading: FontFace, FontFaceSet and document.fonts. The engine
// loads the @font-face fonts of style sheets itself; script-made faces
// are kept in the set, and load() and ready settle at once (there is no
// font for script to wait on).
(function (natives, global, internal) {
  "use strict";
  const token = internal.token;
  const faceData = new WeakMap();

  class FontFace {
    constructor(family, source, descriptors) {
      if (arguments.length < 2) throw new TypeError("Failed to construct 'FontFace': 2 arguments required.");
      const options = descriptors == null ? {} : descriptors;
      const state = { family: String(family), status: "unloaded", style: options.style || "normal",
        weight: String(options.weight || "normal"), stretch: options.stretch || "normal",
        unicodeRange: options.unicodeRange || "U+0-10FFFF", display: options.display || "auto",
        featureSettings: options.featureSettings || "normal", ascentOverride: "normal", descentOverride: "normal",
        lineGapOverride: "normal" };
      state.loaded = new Promise(function (resolve) { state.resolve = resolve; });
      faceData.set(this, state);
      if (typeof source !== "string") {
        state.status = "loaded";
        state.resolve(this);
      }
    }
    get family() { return faceData.get(this).family; }
    set family(value) { faceData.get(this).family = String(value); }
    get style() { return faceData.get(this).style; }
    get weight() { return faceData.get(this).weight; }
    get stretch() { return faceData.get(this).stretch; }
    get unicodeRange() { return faceData.get(this).unicodeRange; }
    get display() { return faceData.get(this).display; }
    get featureSettings() { return faceData.get(this).featureSettings; }
    get ascentOverride() { return faceData.get(this).ascentOverride; }
    get descentOverride() { return faceData.get(this).descentOverride; }
    get lineGapOverride() { return faceData.get(this).lineGapOverride; }
    get status() { return faceData.get(this).status; }
    get loaded() { return faceData.get(this).loaded; }
    load() {
      const state = faceData.get(this);
      if (state.status === "unloaded") {
        state.status = "loaded";
        state.resolve(this);
      }
      return state.loaded;
    }
  }
  internal.finishInterface(FontFace, "FontFace");

  const setData = new WeakMap();
  class FontFaceSet extends EventTarget {
    constructor(key) {
      if (key !== token) internal.illegal();
      super();
      setData.set(this, { faces: new Set(), ready: Promise.resolve(this) });
    }
    get size() { return setData.get(this).faces.size; }
    get status() { return "loaded"; }
    get ready() { return setData.get(this).ready; }
    add(font) {
      if (!(font instanceof FontFace)) throw new TypeError("Failed to execute 'add' on 'FontFaceSet': parameter 1 " +
        "is not of type 'FontFace'.");
      setData.get(this).faces.add(font);
      return this;
    }
    delete(font) { return setData.get(this).faces.delete(font); }
    clear() { setData.get(this).faces.clear(); }
    has(font) { return setData.get(this).faces.has(font); }
    load(font, text) {
      const faces = Array.from(setData.get(this).faces);
      return Promise.all(faces.map(function (face) { return face.load(); })).then(function () { return []; });
    }
    check(font, text) { return true; }
    forEach(callback, thisArgument) {
      for (const face of setData.get(this).faces) callback.call(thisArgument, face, face, this);
    }
    *entries() { for (const face of setData.get(this).faces) yield [face, face]; }
    *keys() { yield* setData.get(this).faces; }
    *values() { yield* setData.get(this).faces; }
    [Symbol.iterator]() { return this.values(); }
  }
  for (const name of ["loading", "loadingdone", "loadingerror"])
    internal.defineHandler(FontFaceSet.prototype, name);
  internal.finishInterface(FontFaceSet, "FontFaceSet");

  let fonts = null;
  Object.defineProperty(global.Document.prototype, "fonts", {
    get: function () {
      if (fonts === null) fonts = new FontFaceSet(token);
      return fonts;
    },
    configurable: true,
    enumerable: true
  });
})
