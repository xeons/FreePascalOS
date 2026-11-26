// DOM Standard: Node and the node kinds other than Document and Element,
// with the ParentNode, ChildNode and NonDocumentTypeChildNode mixins.
// Implemented in Web.Bindings.Nodes.

dictionary GetRootNodeOptions {
  boolean composed = false;
};

[Exposed=Window]
interface Node : EventTarget {
  const unsigned short ELEMENT_NODE = 1;
  const unsigned short ATTRIBUTE_NODE = 2;
  const unsigned short TEXT_NODE = 3;
  const unsigned short CDATA_SECTION_NODE = 4;
  const unsigned short ENTITY_REFERENCE_NODE = 5;
  const unsigned short ENTITY_NODE = 6;
  const unsigned short PROCESSING_INSTRUCTION_NODE = 7;
  const unsigned short COMMENT_NODE = 8;
  const unsigned short DOCUMENT_NODE = 9;
  const unsigned short DOCUMENT_TYPE_NODE = 10;
  const unsigned short DOCUMENT_FRAGMENT_NODE = 11;
  const unsigned short NOTATION_NODE = 12;
  readonly attribute unsigned short nodeType;
  readonly attribute DOMString nodeName;

  readonly attribute USVString baseURI;

  readonly attribute boolean isConnected;
  readonly attribute Document? ownerDocument;
  Node getRootNode(optional GetRootNodeOptions options = {});
  readonly attribute Node? parentNode;
  readonly attribute Element? parentElement;
  boolean hasChildNodes();
  [SameObject] readonly attribute NodeList childNodes;
  readonly attribute Node? firstChild;
  readonly attribute Node? lastChild;
  readonly attribute Node? previousSibling;
  readonly attribute Node? nextSibling;

  attribute DOMString? nodeValue;
  attribute DOMString? textContent;
  undefined normalize();

  [NewObject] Node cloneNode(optional boolean deep = false);
  boolean isEqualNode(Node? otherNode);
  boolean isSameNode(Node? otherNode);

  const unsigned short DOCUMENT_POSITION_DISCONNECTED = 0x01;
  const unsigned short DOCUMENT_POSITION_PRECEDING = 0x02;
  const unsigned short DOCUMENT_POSITION_FOLLOWING = 0x04;
  const unsigned short DOCUMENT_POSITION_CONTAINS = 0x08;
  const unsigned short DOCUMENT_POSITION_CONTAINED_BY = 0x10;
  const unsigned short DOCUMENT_POSITION_IMPLEMENTATION_SPECIFIC = 0x20;
  unsigned short compareDocumentPosition(Node other);
  boolean contains(Node? other);

  DOMString? lookupPrefix(DOMString? namespace);
  DOMString? lookupNamespaceURI(DOMString? prefix);
  boolean isDefaultNamespace(DOMString? namespace);

  Node insertBefore(Node node, Node? child);
  Node appendChild(Node node);
  Node replaceChild(Node node, Node child);
  Node removeChild(Node child);
};

interface mixin ParentNode {
  [SameObject] readonly attribute HTMLCollection children;
  readonly attribute Element? firstElementChild;
  readonly attribute Element? lastElementChild;
  readonly attribute unsigned long childElementCount;

  undefined prepend((Node or DOMString)... nodes);
  undefined append((Node or DOMString)... nodes);
  undefined replaceChildren((Node or DOMString)... nodes);
  [CEReactions] undefined moveBefore(Node node, Node? child);

  Element? querySelector(DOMString selectors);
  [NewObject] NodeList querySelectorAll(DOMString selectors);
};

interface mixin NonElementParentNode {
  Element? getElementById(DOMString elementId);
};

interface mixin NonDocumentTypeChildNode {
  readonly attribute Element? previousElementSibling;
  readonly attribute Element? nextElementSibling;
};

interface mixin ChildNode {
  undefined before((Node or DOMString)... nodes);
  undefined after((Node or DOMString)... nodes);
  undefined replaceWith((Node or DOMString)... nodes);
  undefined remove();
};

[Exposed=Window]
interface DocumentFragment : Node {
  constructor();
};
DocumentFragment includes NonElementParentNode;
DocumentFragment includes ParentNode;

[Exposed=Window]
interface DocumentType : Node {
  readonly attribute DOMString name;
  readonly attribute DOMString publicId;
  readonly attribute DOMString systemId;
};
DocumentType includes ChildNode;

[Exposed=Window]
interface CharacterData : Node {
  attribute [LegacyNullToEmptyString] DOMString data;
  readonly attribute unsigned long length;
  DOMString substringData(unsigned long offset, unsigned long count);
  undefined appendData(DOMString data);
  undefined insertData(unsigned long offset, DOMString data);
  undefined deleteData(unsigned long offset, unsigned long count);
  undefined replaceData(unsigned long offset, unsigned long count, DOMString data);
};
CharacterData includes NonDocumentTypeChildNode;
CharacterData includes ChildNode;

[Exposed=Window]
interface Text : CharacterData {
  constructor(optional DOMString data = "");
  [NewObject] Text splitText(unsigned long offset);
  readonly attribute DOMString wholeText;
};

[Exposed=Window]
interface CDATASection : Text {
};

[Exposed=Window]
interface ProcessingInstruction : CharacterData {
  readonly attribute DOMString target;
};

[Exposed=Window]
interface Comment : CharacterData {
  constructor(optional DOMString data = "");
};

[Exposed=Window]
interface Attr : Node {
  readonly attribute DOMString? namespaceURI;
  readonly attribute DOMString? prefix;
  readonly attribute DOMString localName;
  readonly attribute DOMString name;
  attribute DOMString value;
  readonly attribute Element? ownerElement;
  readonly attribute boolean specified;
};
