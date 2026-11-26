// DOM Standard: Element, with the HTML and DOM Parsing additions
// (innerHTML, outerHTML, insertAdjacentHTML). Implemented in
// Web.Bindings.Elements.

dictionary GetHTMLOptions {
  boolean serializableShadowRoots = false;
  sequence<ShadowRoot> shadowRoots = [];
};

enum InsertPosition { "beforebegin", "afterbegin", "beforeend", "afterend" };

[Exposed=Window]
interface Element : Node {
  readonly attribute DOMString? namespaceURI;
  readonly attribute DOMString? prefix;
  readonly attribute DOMString localName;
  readonly attribute DOMString tagName;

  [Reflect] attribute DOMString id;
  [Reflect=class] attribute DOMString className;
  [SameObject, PutForwards=value] readonly attribute DOMTokenList classList;
  [Reflect] attribute DOMString slot;

  boolean hasAttributes();
  [SameObject] readonly attribute NamedNodeMap attributes;
  sequence<DOMString> getAttributeNames();
  DOMString? getAttribute(DOMString qualifiedName);
  DOMString? getAttributeNS(DOMString? namespace, DOMString localName);
  undefined setAttribute(DOMString qualifiedName, DOMString value);
  undefined setAttributeNS(DOMString? namespace, DOMString qualifiedName, DOMString value);
  undefined removeAttribute(DOMString qualifiedName);
  undefined removeAttributeNS(DOMString? namespace, DOMString localName);
  boolean toggleAttribute(DOMString qualifiedName, optional boolean force);
  boolean hasAttribute(DOMString qualifiedName);
  boolean hasAttributeNS(DOMString? namespace, DOMString localName);

  Attr? getAttributeNode(DOMString qualifiedName);
  Attr? getAttributeNodeNS(DOMString? namespace, DOMString localName);
  Attr? setAttributeNode(Attr attr);
  Attr? setAttributeNodeNS(Attr attr);
  Attr removeAttributeNode(Attr attr);

  Element? closest(DOMString selectors);
  boolean matches(DOMString selectors);
  boolean webkitMatchesSelector(DOMString selectors);

  HTMLCollection getElementsByTagName(DOMString qualifiedName);
  HTMLCollection getElementsByTagNameNS(DOMString? namespace, DOMString localName);
  HTMLCollection getElementsByClassName(DOMString classNames);

  Element? insertAdjacentElement(DOMString where, Element element);
  undefined insertAdjacentText(DOMString where, DOMString data);

  // Pointer Events
  undefined setPointerCapture(long pointerId);
  undefined releasePointerCapture(long pointerId);
  boolean hasPointerCapture(long pointerId);

  // DOM Parsing and Serialization, HTML
  attribute [LegacyNullToEmptyString] DOMString innerHTML;
  attribute [LegacyNullToEmptyString] DOMString outerHTML;
  undefined insertAdjacentHTML(DOMString position, DOMString string);
  DOMString getHTML(optional GetHTMLOptions options = {});
};
Element includes ParentNode;
Element includes NonDocumentTypeChildNode;
Element includes ChildNode;

// ARIAMixin (WAI-ARIA 1.3 10.1): role and the aria-* attributes as
// nullable reflected strings (the element references are not here).
interface mixin ARIAMixin {
  [Reflect] attribute DOMString? role;
  [Reflect=aria-atomic] attribute DOMString? ariaAtomic;
  [Reflect=aria-autocomplete] attribute DOMString? ariaAutoComplete;
  [Reflect=aria-braillelabel] attribute DOMString? ariaBrailleLabel;
  [Reflect=aria-brailleroledescription] attribute DOMString? ariaBrailleRoleDescription;
  [Reflect=aria-busy] attribute DOMString? ariaBusy;
  [Reflect=aria-checked] attribute DOMString? ariaChecked;
  [Reflect=aria-colcount] attribute DOMString? ariaColCount;
  [Reflect=aria-colindex] attribute DOMString? ariaColIndex;
  [Reflect=aria-colindextext] attribute DOMString? ariaColIndexText;
  [Reflect=aria-colspan] attribute DOMString? ariaColSpan;
  [Reflect=aria-current] attribute DOMString? ariaCurrent;
  [Reflect=aria-description] attribute DOMString? ariaDescription;
  [Reflect=aria-disabled] attribute DOMString? ariaDisabled;
  [Reflect=aria-expanded] attribute DOMString? ariaExpanded;
  [Reflect=aria-haspopup] attribute DOMString? ariaHasPopup;
  [Reflect=aria-hidden] attribute DOMString? ariaHidden;
  [Reflect=aria-invalid] attribute DOMString? ariaInvalid;
  [Reflect=aria-keyshortcuts] attribute DOMString? ariaKeyShortcuts;
  [Reflect=aria-label] attribute DOMString? ariaLabel;
  [Reflect=aria-level] attribute DOMString? ariaLevel;
  [Reflect=aria-live] attribute DOMString? ariaLive;
  [Reflect=aria-modal] attribute DOMString? ariaModal;
  [Reflect=aria-multiline] attribute DOMString? ariaMultiLine;
  [Reflect=aria-multiselectable] attribute DOMString? ariaMultiSelectable;
  [Reflect=aria-orientation] attribute DOMString? ariaOrientation;
  [Reflect=aria-placeholder] attribute DOMString? ariaPlaceholder;
  [Reflect=aria-posinset] attribute DOMString? ariaPosInSet;
  [Reflect=aria-pressed] attribute DOMString? ariaPressed;
  [Reflect=aria-readonly] attribute DOMString? ariaReadOnly;
  [Reflect=aria-relevant] attribute DOMString? ariaRelevant;
  [Reflect=aria-required] attribute DOMString? ariaRequired;
  [Reflect=aria-roledescription] attribute DOMString? ariaRoleDescription;
  [Reflect=aria-rowcount] attribute DOMString? ariaRowCount;
  [Reflect=aria-rowindex] attribute DOMString? ariaRowIndex;
  [Reflect=aria-rowindextext] attribute DOMString? ariaRowIndexText;
  [Reflect=aria-rowspan] attribute DOMString? ariaRowSpan;
  [Reflect=aria-selected] attribute DOMString? ariaSelected;
  [Reflect=aria-setsize] attribute DOMString? ariaSetSize;
  [Reflect=aria-sort] attribute DOMString? ariaSort;
  [Reflect=aria-valuemax] attribute DOMString? ariaValueMax;
  [Reflect=aria-valuemin] attribute DOMString? ariaValueMin;
  [Reflect=aria-valuenow] attribute DOMString? ariaValueNow;
  [Reflect=aria-valuetext] attribute DOMString? ariaValueText;
};
Element includes ARIAMixin;
