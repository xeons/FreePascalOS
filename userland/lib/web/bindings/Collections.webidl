// DOM Standard and HTML Standard collections. Implemented in
// Web.Bindings.Collections.

[Exposed=Window]
interface NodeList {
  getter Node? item(unsigned long index);
  readonly attribute unsigned long length;
  iterable<Node>;
};

[Exposed=Window, LegacyUnenumerableNamedProperties]
interface HTMLCollection {
  readonly attribute unsigned long length;
  getter Element? item(unsigned long index);
  getter Element? namedItem(DOMString name);
};

[Exposed=Window, LegacyUnenumerableNamedProperties]
interface NamedNodeMap {
  readonly attribute unsigned long length;
  getter Attr? item(unsigned long index);
  getter Attr? getNamedItem(DOMString qualifiedName);
  Attr? getNamedItemNS(DOMString? namespace, DOMString localName);
  Attr? setNamedItem(Attr attr);
  Attr? setNamedItemNS(Attr attr);
  Attr removeNamedItem(DOMString qualifiedName);
  Attr removeNamedItemNS(DOMString? namespace, DOMString localName);
};

[Exposed=Window]
interface DOMTokenList {
  readonly attribute unsigned long length;
  getter DOMString? item(unsigned long index);
  boolean contains(DOMString token);
  undefined add(DOMString... tokens);
  undefined remove(DOMString... tokens);
  boolean toggle(DOMString token, optional boolean force);
  boolean replace(DOMString token, DOMString newToken);
  boolean supports(DOMString token);
  stringifier attribute DOMString value;
  iterable<DOMString>;
};

[Exposed=Window, LegacyOverrideBuiltIns]
interface DOMStringMap {
  getter DOMString (DOMString name);
  setter undefined (DOMString name, DOMString value);
  deleter undefined (DOMString name);
};

[Exposed=Window]
interface HTMLFormControlsCollection : HTMLCollection {
};

[Exposed=Window]
interface HTMLOptionsCollection : HTMLCollection {
  attribute long selectedIndex;
  undefined add((HTMLOptionElement or HTMLOptGroupElement) element,
                optional (HTMLElement or long)? before = null);
  undefined remove(long index);
};
