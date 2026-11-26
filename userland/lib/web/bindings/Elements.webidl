// DOM Standard: Element, with the HTML and DOM Parsing additions
// (innerHTML, outerHTML, insertAdjacentHTML). Implemented in
// Web.Bindings.Elements.

dictionary GetHTMLOptions {
  boolean serializableShadowRoots = false;
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
