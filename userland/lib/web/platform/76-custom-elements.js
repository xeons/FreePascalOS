// CustomStateSet is a setlike<DOMString> (bindings/CustomElements.webidl
// writes its members out): its @@iterator is values(), as WebIDL says.
(function (natives, global, internal) {
  "use strict";
  const StateSet = global.CustomStateSet;
  Object.defineProperty(StateSet.prototype, Symbol.iterator, { configurable: true, enumerable: false,
    writable: true, value: StateSet.prototype.values });
})
