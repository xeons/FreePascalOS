// The CSSOM's asynchronous member: CSSStyleSheet.replace (the sheet's
// rules replaced as replaceSync does, the promise settled after; @import
// rules are dropped, not loaded, as for constructed sheets).
(function (natives, global, internal) {
  "use strict";
  const Sheet = global.CSSStyleSheet;
  const replaceSync = Sheet.prototype.replaceSync;
  Object.defineProperty(Sheet.prototype, "replace", { configurable: true, enumerable: true, writable: true,
    value: function replace(text) {
      try {
        replaceSync.call(this, text);
        return Promise.resolve(this);
      } catch (error) {
        return Promise.reject(error);
      }
    } });
})
