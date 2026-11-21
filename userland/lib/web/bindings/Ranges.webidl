// DOM Standard 5 (ranges) and the Selection API. Implemented in
// Web.Bindings.Ranges over Web.Dom's live ranges and document selection;
// the client rects of a range come from platform/70-geometry.js.

[Exposed=Window]
interface AbstractRange {
  readonly attribute Node startContainer;
  readonly attribute unsigned long startOffset;
  readonly attribute Node endContainer;
  readonly attribute unsigned long endOffset;
  readonly attribute boolean collapsed;
};

dictionary StaticRangeInit {
  required Node startContainer;
  required unsigned long startOffset;
  required Node endContainer;
  required unsigned long endOffset;
};

[Exposed=Window]
interface StaticRange : AbstractRange {
  constructor(StaticRangeInit init);
};

[Exposed=Window]
interface Range : AbstractRange {
  constructor();

  readonly attribute Node commonAncestorContainer;

  undefined setStart(Node node, unsigned long offset);
  undefined setEnd(Node node, unsigned long offset);
  undefined setStartBefore(Node node);
  undefined setStartAfter(Node node);
  undefined setEndBefore(Node node);
  undefined setEndAfter(Node node);
  undefined collapse(optional boolean toStart = false);
  undefined selectNode(Node node);
  undefined selectNodeContents(Node node);

  const unsigned short START_TO_START = 0;
  const unsigned short START_TO_END = 1;
  const unsigned short END_TO_END = 2;
  const unsigned short END_TO_START = 3;
  short compareBoundaryPoints(unsigned short how, Range sourceRange);

  undefined deleteContents();
  [NewObject] DocumentFragment extractContents();
  [NewObject] DocumentFragment cloneContents();
  undefined insertNode(Node node);
  undefined surroundContents(Node newParent);

  [NewObject] Range cloneRange();
  undefined detach();

  boolean isPointInRange(Node node, unsigned long offset);
  short comparePoint(Node node, unsigned long offset);

  boolean intersectsNode(Node node);

  [NewObject] DocumentFragment createContextualFragment(DOMString string);

  stringifier;
};

[Exposed=Window]
interface Selection {
  readonly attribute Node? anchorNode;
  readonly attribute unsigned long anchorOffset;
  readonly attribute Node? focusNode;
  readonly attribute unsigned long focusOffset;
  readonly attribute boolean isCollapsed;
  readonly attribute unsigned long rangeCount;
  readonly attribute DOMString type;
  readonly attribute DOMString direction;
  Range getRangeAt(unsigned long index);
  undefined addRange(Range range);
  undefined removeRange(Range range);
  undefined removeAllRanges();
  undefined empty();
  undefined collapse(Node? node, optional unsigned long offset = 0);
  undefined setPosition(Node? node, optional unsigned long offset = 0);
  undefined collapseToStart();
  undefined collapseToEnd();
  undefined extend(Node node, optional unsigned long offset = 0);
  undefined setBaseAndExtent(Node anchorNode, unsigned long anchorOffset, Node focusNode, unsigned long focusOffset);
  undefined selectAllChildren(Node node);
  undefined modify(optional DOMString alter = "", optional DOMString direction = "", optional DOMString granularity = "");
  undefined deleteFromDocument();
  boolean containsNode(Node node, optional boolean allowPartialContainment = false);
  stringifier;
};

partial interface Document {
  [NewObject] Range createRange();
  Selection? getSelection();
};

partial interface Window {
  Selection? getSelection();
};
