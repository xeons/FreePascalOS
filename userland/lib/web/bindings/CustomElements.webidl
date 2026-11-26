// HTML Standard 4.13: custom elements (CustomElementRegistry, the
// [HTMLConstructor] steps, ElementInternals with form-associated custom
// elements, CustomStateSet) and ValidityState. Implemented in
// Web.Bindings.CustomElements. The element interfaces' constructors are
// [HTMLConstructor]: make-bindings.py points them all at
// HTMLConstructor_construct.

dictionary ElementDefinitionOptions {
  DOMString extends;
};

[Exposed=Window]
interface CustomElementRegistry {
  undefined define(DOMString name, any constructor, optional ElementDefinitionOptions options = {});
  any get(DOMString name);
  DOMString? getName(any constructor);
  any whenDefined(DOMString name);
  undefined upgrade(Node root);
};

partial interface Window {
  [SameObject] readonly attribute CustomElementRegistry customElements;
};

partial interface HTMLElement {
  ElementInternals attachInternals();
};

dictionary ValidityStateFlags {
  boolean valueMissing = false;
  boolean typeMismatch = false;
  boolean patternMismatch = false;
  boolean tooLong = false;
  boolean tooShort = false;
  boolean rangeUnderflow = false;
  boolean rangeOverflow = false;
  boolean stepMismatch = false;
  boolean badInput = false;
  boolean customError = false;
};

[Exposed=Window]
interface ElementInternals {
  readonly attribute ShadowRoot? shadowRoot;

  undefined setFormValue(any value, optional any state);
  readonly attribute HTMLFormElement? form;
  undefined setValidity(optional ValidityStateFlags flags = {}, optional DOMString message,
                        optional HTMLElement anchor);
  readonly attribute boolean willValidate;
  readonly attribute ValidityState validity;
  readonly attribute DOMString validationMessage;
  boolean checkValidity();
  boolean reportValidity();
  readonly attribute NodeList labels;

  [SameObject] readonly attribute CustomStateSet states;

  // ARIA reflection (ARIAMixin): kept as given.
  attribute DOMString? role;
  attribute DOMString? ariaLabel;
  attribute DOMString? ariaChecked;
  attribute DOMString? ariaDisabled;
  attribute DOMString? ariaExpanded;
  attribute DOMString? ariaHidden;
  attribute DOMString? ariaPressed;
  attribute DOMString? ariaSelected;
  attribute DOMString? ariaValueNow;
};

[Exposed=Window]
interface ValidityState {
  readonly attribute boolean valueMissing;
  readonly attribute boolean typeMismatch;
  readonly attribute boolean patternMismatch;
  readonly attribute boolean tooLong;
  readonly attribute boolean tooShort;
  readonly attribute boolean rangeUnderflow;
  readonly attribute boolean rangeOverflow;
  readonly attribute boolean stepMismatch;
  readonly attribute boolean badInput;
  readonly attribute boolean customError;
  readonly attribute boolean valid;
};

// A setlike<DOMString> written out; platform/76-custom-elements.js
// makes @@iterator values().
[Exposed=Window]
interface CustomStateSet {
  readonly attribute unsigned long size;
  CustomStateSet add(DOMString value);
  boolean delete(DOMString value);
  boolean has(DOMString value);
  undefined clear();
  undefined forEach(any callback, optional any thisArg);
  any values();
  any keys();
  any entries();
};
