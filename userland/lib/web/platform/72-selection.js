// Ranges and the selection, the parts over layout and the event loop:
// Range.getClientRects and getBoundingClientRect (the layout's line
// rectangles of the text in the range and the boxes of the elements in
// it), and the selectionchange event, fired at the document in a task
// after the selection changed (by script or by the user), once however
// many changes came before it ran.
(function (natives, global, internal) {
  "use strict";
  const token = internal.token;
  const setTimeoutOf = global.setTimeout;
  const DOMRectOf = global.DOMRect;
  const DOMRectListOf = global.DOMRectList;

  function rectsOf(range) {
    const flat = natives.rangeRects(range);
    const scroll = natives.viewportScroll();
    const rects = [];
    for (let index = 0; index + 3 < flat.length; index += 4)
      rects.push(new DOMRectOf(flat[index] - scroll[0], flat[index + 1] - scroll[1], flat[index + 2], flat[index + 3]));
    return rects;
  }

  const RangePrototype = global.Range.prototype;
  Object.defineProperty(RangePrototype, "getClientRects", { configurable: true, enumerable: true, writable: true,
    value: function getClientRects() {
      return new DOMRectListOf(token, rectsOf(this));
    } });
  Object.defineProperty(RangePrototype, "getBoundingClientRect", { configurable: true, enumerable: true, writable: true,
    value: function getBoundingClientRect() {
      const rects = rectsOf(this);
      if (rects.length === 0) return new DOMRectOf(0, 0, 0, 0);
      let left = Infinity, top = Infinity, right = -Infinity, bottom = -Infinity;
      for (const rect of rects) {
        if (rect.width === 0 && rect.height === 0 && rects.length > 1) continue;
        left = Math.min(left, rect.left);
        top = Math.min(top, rect.top);
        right = Math.max(right, rect.right);
        bottom = Math.max(bottom, rect.bottom);
      }
      if (left === Infinity) return new DOMRectOf(0, 0, 0, 0);
      return new DOMRectOf(left, top, right - left, bottom - top);
    } });

  internal.defineHandler(global.Document.prototype, "selectionchange");

  let pending = false;
  natives.onSelectionChange = function () {
    if (pending || typeof setTimeoutOf !== "function") return;
    pending = true;
    setTimeoutOf.call(global, function () {
      pending = false;
      const document = global.document;
      if (document) document.dispatchEvent(new Event("selectionchange"));
    }, 0);
  };
})
