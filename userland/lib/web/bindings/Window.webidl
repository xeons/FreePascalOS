// HTML Standard: Window (the global object), Location (read only until
// navigation lands), Navigator, History (through the environment), and
// the WindowOrWorkerGlobalScope members. Implemented in
// Web.Bindings.Window. console and queueMicrotask are libjavascript's.
// The timers are there only when the environment provides them.

dictionary StructuredSerializeOptions {
  sequence<object> transfer = [];
};

[Global=Window, Exposed=Window, LegacyUnenumerableNamedProperties]
interface Window : EventTarget {
  [LegacyUnforgeable] readonly attribute Window window;
  [Replaceable] readonly attribute Window self;
  [LegacyUnforgeable] readonly attribute Document document;
  attribute DOMString name;
  [PutForwards=href, LegacyUnforgeable] readonly attribute Location location;
  readonly attribute History history;
  readonly attribute boolean closed;
  undefined close();
  undefined stop();
  undefined focus();
  undefined blur();

  [Replaceable] readonly attribute Window frames;
  [Replaceable] readonly attribute unsigned long length;
  [LegacyUnforgeable] readonly attribute Window? top;
  [Replaceable] readonly attribute Window? parent;
  readonly attribute Element? frameElement;

  readonly attribute Navigator navigator;
  readonly attribute boolean originAgentCluster;

  undefined alert(optional DOMString message = "");
  boolean confirm(optional DOMString message = "");
  DOMString? prompt(optional DOMString message = "", optional DOMString default = "");
  undefined print();

  // CSSOM View basics
  [Replaceable] readonly attribute long innerWidth;
  [Replaceable] readonly attribute long innerHeight;
  [Replaceable] readonly attribute double scrollX;
  [Replaceable] readonly attribute double pageXOffset;
  [Replaceable] readonly attribute double scrollY;
  [Replaceable] readonly attribute double pageYOffset;
  [Replaceable] readonly attribute double devicePixelRatio;
  CSSStyleDeclaration getComputedStyle(Element elt, optional DOMString? pseudoElt);

  // WindowOrWorkerGlobalScope
  [Replaceable] readonly attribute USVString origin;
  readonly attribute boolean isSecureContext;
  readonly attribute boolean crossOriginIsolated;
  DOMString btoa(DOMString data);
  ByteString atob(DOMString data);
  long setTimeout(any handler, optional long timeout = 0, any... arguments);
  undefined clearTimeout(optional long id = 0);
  long setInterval(any handler, optional long timeout = 0, any... arguments);
  undefined clearInterval(optional long id = 0);
  any structuredClone(any value, optional StructuredSerializeOptions options = {});
};
Window includes GlobalEventHandlers;
Window includes WindowEventHandlers;

[Exposed=Window]
interface Location {
  stringifier readonly attribute USVString href;
  readonly attribute USVString origin;
  readonly attribute USVString protocol;
  readonly attribute USVString host;
  readonly attribute USVString hostname;
  readonly attribute USVString port;
  readonly attribute USVString pathname;
  readonly attribute USVString search;
  readonly attribute USVString hash;
  undefined assign(USVString url);
  undefined replace(USVString url);
  undefined reload();
};

enum ScrollRestoration { "auto", "manual" };

[Exposed=Window]
interface History {
  readonly attribute unsigned long length;
  attribute ScrollRestoration scrollRestoration;
  readonly attribute any state;
  undefined go(optional long delta = 0);
  undefined back();
  undefined forward();
  undefined pushState(any data, DOMString unused, optional USVString? url = null);
  undefined replaceState(any data, DOMString unused, optional USVString? url = null);
};

[Exposed=Window]
interface Navigator {
  readonly attribute DOMString appCodeName;
  readonly attribute DOMString appName;
  readonly attribute DOMString appVersion;
  readonly attribute DOMString platform;
  readonly attribute DOMString product;
  readonly attribute DOMString productSub;
  readonly attribute DOMString userAgent;
  readonly attribute DOMString vendor;
  readonly attribute DOMString vendorSub;
  readonly attribute DOMString language;
  readonly attribute FrozenArray<DOMString> languages;
  readonly attribute boolean onLine;
  readonly attribute boolean cookieEnabled;
  readonly attribute boolean pdfViewerEnabled;
  readonly attribute unsigned long long hardwareConcurrency;
  readonly attribute boolean webdriver;
  boolean javaEnabled();
};
