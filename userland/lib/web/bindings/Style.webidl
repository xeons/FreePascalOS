// CSSOM: CSSStyleDeclaration over libcss's declaration blocks.
// Implemented in Web.Bindings.Style.
//
// The CSS properties (camel-cased, dashed and -webkit- spellings) come
// from libcss's property table, not from here.
[Exposed=Window]
interface CSSStyleDeclaration {
  attribute DOMString cssText;
  readonly attribute unsigned long length;
  getter DOMString item(unsigned long index);
  DOMString getPropertyValue(DOMString property);
  DOMString getPropertyPriority(DOMString property);
  undefined setProperty(DOMString property, [LegacyNullToEmptyString] DOMString value,
                        optional [LegacyNullToEmptyString] DOMString priority = "");
  DOMString removeProperty(DOMString property);
  readonly attribute CSSRule? parentRule;
};

// What element.style and getComputedStyle give (CSSOM 6.7: the property
// attributes live on this interface).
[Exposed=Window]
interface CSSStyleProperties : CSSStyleDeclaration {
  attribute [LegacyNullToEmptyString] DOMString cssFloat;
};
