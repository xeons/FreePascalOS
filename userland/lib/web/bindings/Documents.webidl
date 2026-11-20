// DOM Standard and HTML Standard: Document and DOMImplementation.
// Implemented in Web.Bindings.Documents.

dictionary ElementCreationOptions {
  DOMString is;
};

enum DocumentReadyState { "loading", "interactive", "complete" };
enum DocumentVisibilityState { "visible", "hidden" };

[Exposed=Window]
interface Document : Node {
  constructor();

  [SameObject] readonly attribute DOMImplementation implementation;
  readonly attribute USVString URL;
  readonly attribute USVString documentURI;
  readonly attribute DOMString compatMode;
  readonly attribute DOMString characterSet;
  readonly attribute DOMString charset;
  readonly attribute DOMString inputEncoding;
  readonly attribute DOMString contentType;

  readonly attribute DocumentType? doctype;
  readonly attribute Element? documentElement;
  HTMLCollection getElementsByTagName(DOMString qualifiedName);
  HTMLCollection getElementsByTagNameNS(DOMString? namespace, DOMString localName);
  HTMLCollection getElementsByClassName(DOMString classNames);

  [NewObject] Element createElement(DOMString localName, optional (DOMString or ElementCreationOptions) options = {});
  [NewObject] Element createElementNS(DOMString? namespace, DOMString qualifiedName,
                                      optional (DOMString or ElementCreationOptions) options = {});
  [NewObject] DocumentFragment createDocumentFragment();
  [NewObject] Text createTextNode(DOMString data);
  [NewObject] CDATASection createCDATASection(DOMString data);
  [NewObject] Comment createComment(DOMString data);
  [NewObject] ProcessingInstruction createProcessingInstruction(DOMString target, DOMString data);

  [NewObject] Node importNode(Node node, optional boolean deep = false);
  Node adoptNode(Node node);

  [NewObject] Attr createAttribute(DOMString localName);
  [NewObject] Attr createAttributeNS(DOMString? namespace, DOMString qualifiedName);

  [NewObject] Event createEvent(DOMString interface);

  // HTML Standard
  [LegacyUnforgeable] readonly attribute Location? location;
  attribute USVString domain;
  readonly attribute USVString referrer;
  attribute USVString cookie;
  readonly attribute DOMString lastModified;
  readonly attribute DocumentReadyState readyState;

  attribute DOMString title;
  attribute DOMString dir;
  attribute HTMLElement? body;
  readonly attribute HTMLHeadElement? head;
  [SameObject] readonly attribute HTMLCollection images;
  [SameObject] readonly attribute HTMLCollection embeds;
  [SameObject] readonly attribute HTMLCollection plugins;
  [SameObject] readonly attribute HTMLCollection links;
  [SameObject] readonly attribute HTMLCollection forms;
  [SameObject] readonly attribute HTMLCollection scripts;
  NodeList getElementsByName(DOMString elementName);
  readonly attribute HTMLOrSVGScriptElement? currentScript;

  Document open(optional DOMString unused1, optional DOMString unused2);
  undefined close();
  undefined write(DOMString... text);
  undefined writeln(DOMString... text);

  readonly attribute Window? defaultView;
  boolean hasFocus();
  readonly attribute Element? activeElement;

  readonly attribute boolean hidden;
  readonly attribute DocumentVisibilityState visibilityState;

  attribute EventHandler onreadystatechange;
  attribute EventHandler onvisibilitychange;
};
Document includes NonElementParentNode;
Document includes ParentNode;
Document includes GlobalEventHandlers;

typedef HTMLScriptElement HTMLOrSVGScriptElement;

[Exposed=Window]
interface DOMImplementation {
  [NewObject] DocumentType createDocumentType(DOMString name, DOMString publicId, DOMString systemId);
  [NewObject] Document createDocument(DOMString? namespace, [LegacyNullToEmptyString] DOMString qualifiedName,
                                       optional DocumentType? doctype = null);
  [NewObject] Document createHTMLDocument(optional DOMString title);
  boolean hasFeature();
};
