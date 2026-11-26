// DOM Standard 4.8 (shadow roots), 4.2.2 (slots) and the HTML Standard's
// slot element and getHTML/setHTMLUnsafe. Implemented in
// Web.Bindings.Shadow over Web.Dom's shadow trees.

enum ShadowRootMode { "open", "closed" };
enum SlotAssignmentMode { "manual", "named" };

dictionary ShadowRootInit {
  required ShadowRootMode mode;
  boolean delegatesFocus = false;
  SlotAssignmentMode slotAssignment = "named";
  boolean clonable = false;
  boolean serializable = false;
};

[Exposed=Window]
interface ShadowRoot : DocumentFragment {
  readonly attribute ShadowRootMode mode;
  readonly attribute boolean delegatesFocus;
  readonly attribute SlotAssignmentMode slotAssignment;
  readonly attribute boolean clonable;
  readonly attribute boolean serializable;
  readonly attribute Element host;
  attribute EventHandler onslotchange;

  // DocumentOrShadowRoot (adoptedStyleSheets: StyleSheets.webidl)
  readonly attribute Element? activeElement;

  // HTML: DOM parsing and serialization
  attribute [LegacyNullToEmptyString] DOMString innerHTML;
  undefined setHTMLUnsafe(DOMString html);
  DOMString getHTML(optional GetHTMLOptions options = {});
};

partial interface Element {
  ShadowRoot attachShadow(ShadowRootInit init);
  readonly attribute ShadowRoot? shadowRoot;
  [SameObject, PutForwards=value] readonly attribute DOMTokenList part;
  undefined setHTMLUnsafe(DOMString html);
};

interface mixin Slottable {
  readonly attribute HTMLSlotElement? assignedSlot;
};
Element includes Slottable;
Text includes Slottable;

dictionary AssignedNodesOptions {
  boolean flatten = false;
};

partial interface HTMLSlotElement {
  sequence<Node> assignedNodes(optional AssignedNodesOptions options = {});
  sequence<Element> assignedElements(optional AssignedNodesOptions options = {});
  undefined assign((Element or Text)... nodes);
};
