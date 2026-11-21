// HTML Standard: HTMLElement and the element interfaces. [LocalNames]
// (an extension) lists the HTML elements a wrapper of the interface is
// made for. [Reflect] attributes reflect a content attribute (the name
// given, or the attribute's own in lower case) and need no routine:
// DOMString, USVString with [ReflectURL], boolean, long and unsigned
// long ([ReflectDefault] for a missing or bad value, [ReflectPositive]
// for "limited to only positive numbers"), double, and enumerated
// attributes ([ReflectEnum] keywords, [ReflectMissing], [ReflectInvalid]).
// The rest is in Web.Bindings.HtmlElements.

dictionary FocusOptions {
  boolean preventScroll = false;
  boolean focusVisible;
};

[Exposed=Window,
 LocalNames=(abbr, acronym, address, article, aside, b, basefont, bdi, bdo, big, center, cite, code,
             dd, dfn, dt, em, figcaption, figure, footer, header, hgroup, i, kbd, main, mark, nav,
             nobr, noembed, noframes, noscript, plaintext, rb, rp, rt, rtc, ruby, s, samp, search,
             section, small, strike, strong, sub, summary, sup, tt, u, var, wbr)]
interface HTMLElement : Element {
  [Reflect] attribute DOMString title;
  [Reflect] attribute DOMString lang;
  attribute boolean translate;
  [Reflect, ReflectEnum=("ltr", "rtl", "auto"), ReflectMissing="", ReflectInvalid=""] attribute DOMString dir;

  [Reflect] attribute boolean hidden;
  [Reflect] attribute boolean inert;
  undefined click();
  [Reflect] attribute DOMString accessKey;
  [Reflect] attribute boolean draggable;
  [Reflect] attribute DOMString autocapitalize;
  [Reflect] attribute DOMString enterKeyHint;
  [Reflect] attribute DOMString inputMode;
  [Reflect] attribute DOMString nonce;
  [Reflect] attribute boolean autofocus;
  attribute long tabIndex;
  undefined focus(optional FocusOptions options = {});
  undefined blur();

  [LegacyNullToEmptyString] attribute DOMString innerText;
  [LegacyNullToEmptyString] attribute DOMString outerText;

  attribute DOMString contentEditable;
  readonly attribute boolean isContentEditable;
  [Reflect] attribute DOMString popover;

  [SameObject] readonly attribute DOMStringMap dataset;
  [SameObject, PutForwards=cssText] readonly attribute CSSStyleDeclaration style;

  readonly attribute Element? offsetParent;
  readonly attribute long offsetTop;
  readonly attribute long offsetLeft;
  readonly attribute long offsetWidth;
  readonly attribute long offsetHeight;
};
HTMLElement includes GlobalEventHandlers;

[Exposed=Window]
interface HTMLUnknownElement : HTMLElement { };

interface mixin HTMLHyperlinkElementUtils {
  [ReflectURL=href] stringifier attribute USVString href;
  readonly attribute USVString origin;
  attribute USVString protocol;
  attribute USVString username;
  attribute USVString password;
  attribute USVString host;
  attribute USVString hostname;
  attribute USVString port;
  attribute USVString pathname;
  attribute USVString search;
  attribute USVString hash;
};

[Exposed=Window, LocalNames=(a)]
interface HTMLAnchorElement : HTMLElement {
  [Reflect] attribute DOMString target;
  [Reflect] attribute DOMString download;
  [Reflect] attribute USVString ping;
  [Reflect] attribute DOMString rel;
  [SameObject, PutForwards=value] readonly attribute DOMTokenList relList;
  [Reflect] attribute DOMString hreflang;
  [Reflect] attribute DOMString type;
  attribute DOMString text;
  [Reflect=referrerpolicy] attribute DOMString referrerPolicy;
  [Reflect] attribute DOMString coords;
  [Reflect] attribute DOMString charset;
  [Reflect] attribute DOMString name;
  [Reflect] attribute DOMString rev;
  [Reflect] attribute DOMString shape;
};
HTMLAnchorElement includes HTMLHyperlinkElementUtils;

[Exposed=Window, LocalNames=(area)]
interface HTMLAreaElement : HTMLElement {
  [Reflect] attribute DOMString alt;
  [Reflect] attribute DOMString coords;
  [Reflect] attribute DOMString shape;
  [Reflect] attribute DOMString target;
  [Reflect] attribute DOMString download;
  [Reflect] attribute DOMString rel;
  [Reflect=referrerpolicy] attribute DOMString referrerPolicy;
};
HTMLAreaElement includes HTMLHyperlinkElementUtils;

[Exposed=Window, LocalNames=(img)]
interface HTMLImageElement : HTMLElement {
  [Reflect] attribute DOMString alt;
  [ReflectURL] attribute USVString src;
  [Reflect] attribute USVString srcset;
  [Reflect] attribute DOMString sizes;
  [Reflect=crossorigin, ReflectEnum=("anonymous", "use-credentials"), ReflectMissing="", ReflectInvalid="anonymous"]
    attribute DOMString crossOrigin;
  [Reflect] attribute DOMString useMap;
  [Reflect] attribute boolean isMap;
  [Reflect, ReflectDefault=0] attribute unsigned long width;
  [Reflect, ReflectDefault=0] attribute unsigned long height;
  readonly attribute unsigned long naturalWidth;
  readonly attribute unsigned long naturalHeight;
  readonly attribute boolean complete;
  readonly attribute USVString currentSrc;
  [Reflect=referrerpolicy] attribute DOMString referrerPolicy;
  [Reflect, ReflectEnum=("sync", "async", "auto"), ReflectMissing="auto", ReflectInvalid="auto"] attribute DOMString decoding;
  [Reflect, ReflectEnum=("lazy", "eager"), ReflectMissing="eager", ReflectInvalid="eager"] attribute DOMString loading;
  [Reflect] attribute DOMString name;
  [Reflect] attribute DOMString align;
  [Reflect] attribute DOMString border;
};

[Exposed=Window, LocalNames=(input)]
interface HTMLInputElement : HTMLElement {
  [Reflect] attribute DOMString accept;
  [Reflect] attribute DOMString alt;
  [Reflect] attribute DOMString autocomplete;
  [Reflect=checked] attribute boolean defaultChecked;
  attribute boolean checked;
  [Reflect] attribute DOMString dirName;
  [Reflect] attribute boolean disabled;
  readonly attribute HTMLFormElement? form;
  [ReflectURL] attribute USVString formAction;
  [Reflect] attribute boolean formNoValidate;
  [Reflect] attribute DOMString formTarget;
  [Reflect, ReflectDefault=0] attribute unsigned long height;
  attribute boolean indeterminate;
  [Reflect] attribute DOMString max;
  [Reflect, ReflectDefault=-1] attribute long maxLength;
  [Reflect] attribute DOMString min;
  [Reflect, ReflectDefault=-1] attribute long minLength;
  [Reflect] attribute boolean multiple;
  [Reflect] attribute DOMString name;
  [Reflect] attribute DOMString pattern;
  [Reflect] attribute DOMString placeholder;
  [Reflect] attribute boolean readOnly;
  [Reflect] attribute boolean required;
  [Reflect, ReflectDefault=20, ReflectPositive] attribute unsigned long size;
  [ReflectURL] attribute USVString src;
  [Reflect] attribute DOMString step;
  attribute DOMString type;
  [Reflect=value] attribute DOMString defaultValue;
  [LegacyNullToEmptyString] attribute DOMString value;
  attribute unrestricted double valueAsNumber;
  [Reflect, ReflectDefault=0] attribute unsigned long width;
  readonly attribute boolean willValidate;
  boolean checkValidity();
  boolean reportValidity();
  undefined setCustomValidity(DOMString error);
  undefined select();
  attribute unsigned long? selectionStart;
  attribute unsigned long? selectionEnd;
  attribute DOMString? selectionDirection;
  undefined setSelectionRange(unsigned long start, unsigned long end, optional DOMString direction);
  [Reflect] attribute DOMString align;
  [Reflect] attribute DOMString useMap;
};

[Exposed=Window, LocalNames=(button)]
interface HTMLButtonElement : HTMLElement {
  [Reflect] attribute boolean disabled;
  readonly attribute HTMLFormElement? form;
  [ReflectURL] attribute USVString formAction;
  [Reflect] attribute boolean formNoValidate;
  [Reflect] attribute DOMString formTarget;
  [Reflect] attribute DOMString name;
  [Reflect, ReflectEnum=("submit", "reset", "button"), ReflectMissing="submit", ReflectInvalid="submit"]
    attribute DOMString type;
  [Reflect] attribute DOMString value;
  readonly attribute boolean willValidate;
  boolean checkValidity();
  boolean reportValidity();
  undefined setCustomValidity(DOMString error);
};

[Exposed=Window, LocalNames=(textarea)]
interface HTMLTextAreaElement : HTMLElement {
  [Reflect] attribute DOMString autocomplete;
  [Reflect, ReflectDefault=20, ReflectPositive] attribute unsigned long cols;
  [Reflect] attribute DOMString dirName;
  [Reflect] attribute boolean disabled;
  readonly attribute HTMLFormElement? form;
  [Reflect, ReflectDefault=-1] attribute long maxLength;
  [Reflect, ReflectDefault=-1] attribute long minLength;
  [Reflect] attribute DOMString name;
  [Reflect] attribute DOMString placeholder;
  [Reflect] attribute boolean readOnly;
  [Reflect] attribute boolean required;
  [Reflect, ReflectDefault=2, ReflectPositive] attribute unsigned long rows;
  [Reflect] attribute DOMString wrap;
  readonly attribute DOMString type;
  attribute DOMString defaultValue;
  [LegacyNullToEmptyString] attribute DOMString value;
  readonly attribute unsigned long textLength;
  readonly attribute boolean willValidate;
  boolean checkValidity();
  boolean reportValidity();
  undefined setCustomValidity(DOMString error);
  undefined select();
  attribute unsigned long selectionStart;
  attribute unsigned long selectionEnd;
  attribute DOMString selectionDirection;
  undefined setSelectionRange(unsigned long start, unsigned long end, optional DOMString direction);
};

[Exposed=Window, LocalNames=(select)]
interface HTMLSelectElement : HTMLElement {
  [Reflect] attribute DOMString autocomplete;
  [Reflect] attribute boolean disabled;
  readonly attribute HTMLFormElement? form;
  [Reflect] attribute boolean multiple;
  [Reflect] attribute DOMString name;
  [Reflect] attribute boolean required;
  [Reflect, ReflectDefault=0] attribute unsigned long size;
  readonly attribute DOMString type;
  [SameObject] readonly attribute HTMLOptionsCollection options;
  readonly attribute unsigned long length;
  Element? item(unsigned long index);
  HTMLOptionElement? namedItem(DOMString name);
  undefined add((HTMLOptionElement or HTMLOptGroupElement) element,
                optional (HTMLElement or long)? before = null);
  undefined remove(optional long index);
  [SameObject] readonly attribute HTMLCollection selectedOptions;
  attribute long selectedIndex;
  attribute DOMString value;
  readonly attribute boolean willValidate;
  boolean checkValidity();
  boolean reportValidity();
  undefined setCustomValidity(DOMString error);
};

[Exposed=Window, LocalNames=(option)]
interface HTMLOptionElement : HTMLElement {
  [Reflect] attribute boolean disabled;
  readonly attribute HTMLFormElement? form;
  [Reflect] attribute DOMString label;
  [Reflect=selected] attribute boolean defaultSelected;
  attribute boolean selected;
  attribute DOMString value;
  attribute DOMString text;
  readonly attribute long index;
};

[Exposed=Window, LocalNames=(optgroup)]
interface HTMLOptGroupElement : HTMLElement {
  [Reflect] attribute boolean disabled;
  [Reflect] attribute DOMString label;
};

[Exposed=Window, LocalNames=(form)]
interface HTMLFormElement : HTMLElement {
  [Reflect=accept-charset] attribute DOMString acceptCharset;
  [ReflectURL] attribute USVString action;
  [Reflect] attribute DOMString autocomplete;
  [Reflect, ReflectEnum=("application/x-www-form-urlencoded", "multipart/form-data", "text/plain"),
   ReflectMissing="application/x-www-form-urlencoded", ReflectInvalid="application/x-www-form-urlencoded"]
    attribute DOMString enctype;
  [Reflect=enctype, ReflectEnum=("application/x-www-form-urlencoded", "multipart/form-data", "text/plain"),
   ReflectMissing="application/x-www-form-urlencoded", ReflectInvalid="application/x-www-form-urlencoded"]
    attribute DOMString encoding;
  [Reflect, ReflectEnum=("get", "post", "dialog"), ReflectMissing="get", ReflectInvalid="get"]
    attribute DOMString method;
  [Reflect] attribute DOMString name;
  [Reflect] attribute boolean noValidate;
  [Reflect] attribute DOMString target;
  [Reflect] attribute DOMString rel;
  [SameObject] readonly attribute HTMLFormControlsCollection elements;
  readonly attribute unsigned long length;
  undefined submit();
  undefined requestSubmit(optional HTMLElement? submitter = null);
  undefined reset();
  boolean checkValidity();
  boolean reportValidity();
};

[Exposed=Window, LocalNames=(label)]
interface HTMLLabelElement : HTMLElement {
  readonly attribute HTMLFormElement? form;
  [Reflect=for] attribute DOMString htmlFor;
  readonly attribute HTMLElement? control;
};

[Exposed=Window, LocalNames=(fieldset)]
interface HTMLFieldSetElement : HTMLElement {
  [Reflect] attribute boolean disabled;
  readonly attribute HTMLFormElement? form;
  [Reflect] attribute DOMString name;
  readonly attribute DOMString type;
};

[Exposed=Window, LocalNames=(legend)]
interface HTMLLegendElement : HTMLElement {
  readonly attribute HTMLFormElement? form;
  [Reflect] attribute DOMString align;
};

[Exposed=Window, LocalNames=(output)]
interface HTMLOutputElement : HTMLElement {
  readonly attribute HTMLFormElement? form;
  [Reflect] attribute DOMString name;
  readonly attribute DOMString type;
  attribute DOMString defaultValue;
  attribute DOMString value;
};

[Exposed=Window, LocalNames=(script)]
interface HTMLScriptElement : HTMLElement {
  [ReflectURL] attribute USVString src;
  [Reflect] attribute DOMString type;
  [Reflect] attribute boolean noModule;
  attribute boolean async;
  [Reflect] attribute boolean defer;
  [Reflect=crossorigin, ReflectEnum=("anonymous", "use-credentials"), ReflectMissing="", ReflectInvalid="anonymous"]
    attribute DOMString crossOrigin;
  attribute DOMString text;
  [Reflect] attribute DOMString integrity;
  [Reflect=referrerpolicy] attribute DOMString referrerPolicy;
  [Reflect] attribute DOMString charset;
  [Reflect] attribute DOMString event;
  [Reflect=for] attribute DOMString htmlFor;
  static boolean supports(DOMString type);
};

[Exposed=Window, LocalNames=(style)]
interface HTMLStyleElement : HTMLElement {
  attribute boolean disabled;
  [Reflect] attribute DOMString media;
  [Reflect] attribute DOMString type;
  [SameObject, PutForwards=value] readonly attribute DOMTokenList blocking;
};

[Exposed=Window, LocalNames=(link)]
interface HTMLLinkElement : HTMLElement {
  [ReflectURL] attribute USVString href;
  [Reflect=crossorigin, ReflectEnum=("anonymous", "use-credentials"), ReflectMissing="", ReflectInvalid="anonymous"]
    attribute DOMString crossOrigin;
  [Reflect] attribute DOMString rel;
  [Reflect] attribute DOMString as;
  [SameObject, PutForwards=value] readonly attribute DOMTokenList relList;
  [Reflect] attribute DOMString media;
  [Reflect] attribute DOMString integrity;
  [Reflect] attribute DOMString hreflang;
  [Reflect] attribute DOMString type;
  [Reflect] attribute USVString imageSrcset;
  [Reflect] attribute DOMString imageSizes;
  [Reflect=referrerpolicy] attribute DOMString referrerPolicy;
  [Reflect] attribute boolean disabled;
  [Reflect] attribute DOMString charset;
  [Reflect] attribute DOMString rev;
  [Reflect] attribute DOMString target;
};

[Exposed=Window, LocalNames=(meta)]
interface HTMLMetaElement : HTMLElement {
  [Reflect] attribute DOMString name;
  [Reflect=http-equiv] attribute DOMString httpEquiv;
  [Reflect] attribute DOMString content;
  [Reflect] attribute DOMString media;
  [Reflect] attribute DOMString scheme;
};

[Exposed=Window, LocalNames=(title)]
interface HTMLTitleElement : HTMLElement {
  attribute DOMString text;
};

[Exposed=Window, LocalNames=(base)]
interface HTMLBaseElement : HTMLElement {
  [ReflectURL] attribute USVString href;
  [Reflect] attribute DOMString target;
};

[Exposed=Window, LocalNames=(head)]
interface HTMLHeadElement : HTMLElement { };

[Exposed=Window, LocalNames=(html)]
interface HTMLHtmlElement : HTMLElement {
  [Reflect] attribute DOMString version;
};

[Exposed=Window, LocalNames=(body)]
interface HTMLBodyElement : HTMLElement {
  [Reflect] attribute DOMString text;
  [Reflect] attribute DOMString link;
  [Reflect=vlink] attribute DOMString vLink;
  [Reflect=alink] attribute DOMString aLink;
  [Reflect=bgcolor] attribute DOMString bgColor;
  [Reflect] attribute DOMString background;
};
HTMLBodyElement includes WindowEventHandlers;

[Exposed=Window, LocalNames=(template)]
interface HTMLTemplateElement : HTMLElement {
  readonly attribute DocumentFragment content;
  [Reflect=shadowrootmode, ReflectEnum=("open", "closed"), ReflectMissing="", ReflectInvalid=""]
    attribute DOMString shadowRootMode;
};

[Exposed=Window, LocalNames=(slot)]
interface HTMLSlotElement : HTMLElement {
  [Reflect] attribute DOMString name;
};

[Exposed=Window, LocalNames=(div)]
interface HTMLDivElement : HTMLElement {
  [Reflect] attribute DOMString align;
};

[Exposed=Window, LocalNames=(span)]
interface HTMLSpanElement : HTMLElement { };

[Exposed=Window, LocalNames=(p)]
interface HTMLParagraphElement : HTMLElement {
  [Reflect] attribute DOMString align;
};

[Exposed=Window, LocalNames=(h1, h2, h3, h4, h5, h6)]
interface HTMLHeadingElement : HTMLElement {
  [Reflect] attribute DOMString align;
};

[Exposed=Window, LocalNames=(br)]
interface HTMLBRElement : HTMLElement {
  [Reflect] attribute DOMString clear;
};

[Exposed=Window, LocalNames=(hr)]
interface HTMLHRElement : HTMLElement {
  [Reflect] attribute DOMString align;
  [Reflect] attribute DOMString color;
  [Reflect=noshade] attribute boolean noShade;
  [Reflect] attribute DOMString size;
  [Reflect] attribute DOMString width;
};

[Exposed=Window, LocalNames=(pre, listing, xmp)]
interface HTMLPreElement : HTMLElement {
  [Reflect, ReflectDefault=0] attribute long width;
};

[Exposed=Window, LocalNames=(blockquote, q)]
interface HTMLQuoteElement : HTMLElement {
  [ReflectURL] attribute USVString cite;
};

[Exposed=Window, LocalNames=(ins, del)]
interface HTMLModElement : HTMLElement {
  [ReflectURL] attribute USVString cite;
  [Reflect=datetime] attribute DOMString dateTime;
};

[Exposed=Window, LocalNames=(ol)]
interface HTMLOListElement : HTMLElement {
  [Reflect] attribute boolean reversed;
  [Reflect, ReflectDefault=1] attribute long start;
  [Reflect] attribute DOMString type;
  [Reflect] attribute boolean compact;
};

[Exposed=Window, LocalNames=(ul)]
interface HTMLUListElement : HTMLElement {
  [Reflect] attribute boolean compact;
  [Reflect] attribute DOMString type;
};

[Exposed=Window, LocalNames=(menu)]
interface HTMLMenuElement : HTMLElement {
  [Reflect] attribute boolean compact;
};

[Exposed=Window, LocalNames=(li)]
interface HTMLLIElement : HTMLElement {
  [Reflect, ReflectDefault=0] attribute long value;
  [Reflect] attribute DOMString type;
};

[Exposed=Window, LocalNames=(dl)]
interface HTMLDListElement : HTMLElement {
  [Reflect] attribute boolean compact;
};

[Exposed=Window, LocalNames=(data)]
interface HTMLDataElement : HTMLElement {
  [Reflect] attribute DOMString value;
};

[Exposed=Window, LocalNames=(time)]
interface HTMLTimeElement : HTMLElement {
  [Reflect=datetime] attribute DOMString dateTime;
};

[Exposed=Window, LocalNames=(iframe)]
interface HTMLIFrameElement : HTMLElement {
  [ReflectURL] attribute USVString src;
  [Reflect] attribute DOMString srcdoc;
  [Reflect] attribute DOMString name;
  [SameObject, PutForwards=value] readonly attribute DOMTokenList sandbox;
  [Reflect] attribute DOMString allow;
  [Reflect] attribute boolean allowFullscreen;
  [Reflect] attribute DOMString width;
  [Reflect] attribute DOMString height;
  [Reflect=referrerpolicy] attribute DOMString referrerPolicy;
  [Reflect, ReflectEnum=("lazy", "eager"), ReflectMissing="eager", ReflectInvalid="eager"] attribute DOMString loading;
  readonly attribute Document? contentDocument;
  readonly attribute Window? contentWindow;
  [Reflect] attribute DOMString align;
  [Reflect] attribute DOMString scrolling;
  [Reflect=frameborder] attribute DOMString frameBorder;
};

[Exposed=Window, LocalNames=(embed)]
interface HTMLEmbedElement : HTMLElement {
  [ReflectURL] attribute USVString src;
  [Reflect] attribute DOMString type;
  [Reflect] attribute DOMString width;
  [Reflect] attribute DOMString height;
};

[Exposed=Window, LocalNames=(object)]
interface HTMLObjectElement : HTMLElement {
  [ReflectURL] attribute USVString data;
  [Reflect] attribute DOMString type;
  [Reflect] attribute DOMString name;
  readonly attribute HTMLFormElement? form;
  [Reflect] attribute DOMString width;
  [Reflect] attribute DOMString height;
};

[Exposed=Window, LocalNames=(audio, video)]
interface HTMLMediaElement : HTMLElement {
  [ReflectURL] attribute USVString src;
  [Reflect=crossorigin, ReflectEnum=("anonymous", "use-credentials"), ReflectMissing="", ReflectInvalid="anonymous"]
    attribute DOMString crossOrigin;
  [Reflect, ReflectEnum=("none", "metadata", "auto"), ReflectMissing="metadata", ReflectInvalid="auto"]
    attribute DOMString preload;
  [Reflect] attribute boolean autoplay;
  [Reflect] attribute boolean loop;
  [Reflect] attribute boolean controls;
  [Reflect=muted] attribute boolean defaultMuted;
  readonly attribute boolean paused;
};

[Exposed=Window, LocalNames=(source)]
interface HTMLSourceElement : HTMLElement {
  [ReflectURL] attribute USVString src;
  [Reflect] attribute DOMString type;
  [Reflect] attribute USVString srcset;
  [Reflect] attribute DOMString sizes;
  [Reflect] attribute DOMString media;
};

[Exposed=Window, LocalNames=(canvas)]
interface HTMLCanvasElement : HTMLElement {
  [Reflect, ReflectDefault=300] attribute unsigned long width;
  [Reflect, ReflectDefault=150] attribute unsigned long height;
};

[Exposed=Window, LocalNames=(table)]
interface HTMLTableElement : HTMLElement {
  [Reflect] attribute DOMString align;
  [Reflect] attribute DOMString border;
  [Reflect] attribute DOMString frame;
  [Reflect] attribute DOMString rules;
  [Reflect] attribute DOMString summary;
  [Reflect] attribute DOMString width;
  [Reflect=bgcolor] attribute DOMString bgColor;
  [Reflect=cellpadding] attribute DOMString cellPadding;
  [Reflect=cellspacing] attribute DOMString cellSpacing;
};

[Exposed=Window, LocalNames=(caption)]
interface HTMLTableCaptionElement : HTMLElement {
  [Reflect] attribute DOMString align;
};

[Exposed=Window, LocalNames=(thead, tbody, tfoot)]
interface HTMLTableSectionElement : HTMLElement {
  [Reflect] attribute DOMString align;
};

[Exposed=Window, LocalNames=(tr)]
interface HTMLTableRowElement : HTMLElement {
  [Reflect] attribute DOMString align;
  [Reflect=bgcolor] attribute DOMString bgColor;
};

[Exposed=Window, LocalNames=(td, th)]
interface HTMLTableCellElement : HTMLElement {
  [Reflect, ReflectDefault=1, ReflectPositive] attribute unsigned long colSpan;
  [Reflect, ReflectDefault=1] attribute unsigned long rowSpan;
  [Reflect] attribute DOMString headers;
  [Reflect] attribute DOMString scope;
  [Reflect] attribute DOMString abbr;
  [Reflect] attribute DOMString align;
  [Reflect] attribute DOMString axis;
  [Reflect] attribute DOMString height;
  [Reflect] attribute DOMString width;
  [Reflect=nowrap] attribute boolean noWrap;
  [Reflect=bgcolor] attribute DOMString bgColor;
};

[Exposed=Window, LocalNames=(col, colgroup)]
interface HTMLTableColElement : HTMLElement {
  [Reflect, ReflectDefault=1, ReflectPositive] attribute unsigned long span;
  [Reflect] attribute DOMString align;
  [Reflect] attribute DOMString width;
};

[Exposed=Window, LocalNames=(details)]
interface HTMLDetailsElement : HTMLElement {
  [Reflect] attribute DOMString name;
  [Reflect] attribute boolean open;
};

[Exposed=Window, LocalNames=(dialog)]
interface HTMLDialogElement : HTMLElement {
  [Reflect] attribute boolean open;
  attribute DOMString returnValue;
};

[Exposed=Window, LocalNames=(progress)]
interface HTMLProgressElement : HTMLElement {
  [Reflect, ReflectDefault=0] attribute double value;
  [Reflect, ReflectDefault=1] attribute double max;
};

[Exposed=Window, LocalNames=(meter)]
interface HTMLMeterElement : HTMLElement {
  [Reflect, ReflectDefault=0] attribute double value;
  [Reflect, ReflectDefault=0] attribute double min;
  [Reflect, ReflectDefault=1] attribute double max;
  [Reflect, ReflectDefault=0] attribute double low;
  [Reflect, ReflectDefault=1] attribute double high;
  [Reflect, ReflectDefault=0] attribute double optimum;
};

[Exposed=Window, LocalNames=(map)]
interface HTMLMapElement : HTMLElement {
  [Reflect] attribute DOMString name;
};

[Exposed=Window, LocalNames=(picture)]
interface HTMLPictureElement : HTMLElement { };

[Exposed=Window, LocalNames=(datalist)]
interface HTMLDataListElement : HTMLElement { };

[Exposed=Window, LocalNames=(track)]
interface HTMLTrackElement : HTMLElement {
  [Reflect] attribute DOMString kind;
  [ReflectURL] attribute USVString src;
  [Reflect] attribute DOMString srclang;
  [Reflect] attribute DOMString label;
  [Reflect] attribute boolean default;
};

[Exposed=Window, LocalNames=(param)]
interface HTMLParamElement : HTMLElement {
  [Reflect] attribute DOMString name;
  [Reflect] attribute DOMString value;
};

[Exposed=Window, LocalNames=(font)]
interface HTMLFontElement : HTMLElement {
  [Reflect] attribute DOMString color;
  [Reflect] attribute DOMString face;
  [Reflect] attribute DOMString size;
};

[Exposed=Window, LocalNames=(dir)]
interface HTMLDirectoryElement : HTMLElement {
  [Reflect] attribute boolean compact;
};

[Exposed=Window, LocalNames=(frameset)]
interface HTMLFrameSetElement : HTMLElement {
  [Reflect] attribute DOMString cols;
  [Reflect] attribute DOMString rows;
};

[Exposed=Window, LocalNames=(frame)]
interface HTMLFrameElement : HTMLElement {
  [Reflect] attribute DOMString name;
  [ReflectURL] attribute USVString src;
};

[Exposed=Window, LocalNames=(marquee)]
interface HTMLMarqueeElement : HTMLElement {
  [Reflect] attribute DOMString behavior;
  [Reflect] attribute DOMString direction;
};
