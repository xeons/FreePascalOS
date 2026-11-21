// DOM Standard: events. UI Events: UIEvent, MouseEvent, KeyboardEvent,
// FocusEvent, InputEvent (the basics). Implemented in Web.Bindings.Events.
//
// A member whose type is EventHandler is an event handler IDL attribute:
// the dispatcher keeps it (no implementation routine).

typedef EventHandlerNonNull? EventHandler;
[LegacyTreatNonObjectAsNull]
callback EventHandlerNonNull = any (Event event);

callback interface EventListener {
  undefined handleEvent(Event event);
};

dictionary EventListenerOptions {
  boolean capture = false;
};

dictionary AddEventListenerOptions : EventListenerOptions {
  boolean passive;
  boolean once = false;
  object signal;
};

[Exposed=*]
interface EventTarget {
  constructor();
  undefined addEventListener(DOMString type, EventListener? callback,
                             optional (AddEventListenerOptions or boolean) options = {});
  undefined removeEventListener(DOMString type, EventListener? callback,
                                optional (EventListenerOptions or boolean) options = {});
  boolean dispatchEvent(Event event);
};

dictionary EventInit {
  boolean bubbles = false;
  boolean cancelable = false;
  boolean composed = false;
};

[Exposed=*]
interface Event {
  constructor(DOMString type, optional EventInit eventInitDict = {});
  readonly attribute DOMString type;
  readonly attribute EventTarget? target;
  readonly attribute EventTarget? srcElement;
  readonly attribute EventTarget? currentTarget;
  sequence<EventTarget> composedPath();

  const unsigned short NONE = 0;
  const unsigned short CAPTURING_PHASE = 1;
  const unsigned short AT_TARGET = 2;
  const unsigned short BUBBLING_PHASE = 3;
  readonly attribute unsigned short eventPhase;

  undefined stopPropagation();
  attribute boolean cancelBubble;
  undefined stopImmediatePropagation();

  readonly attribute boolean bubbles;
  readonly attribute boolean cancelable;
  attribute boolean returnValue;
  undefined preventDefault();
  readonly attribute boolean defaultPrevented;
  readonly attribute boolean composed;

  readonly attribute boolean isTrusted;
  readonly attribute double timeStamp;

  undefined initEvent(DOMString type, optional boolean bubbles = false, optional boolean cancelable = false);
};

dictionary CustomEventInit : EventInit {
  any detail = null;
};

[Exposed=*]
interface CustomEvent : Event {
  constructor(DOMString type, optional CustomEventInit eventInitDict = {});
  readonly attribute any detail;
  undefined initCustomEvent(DOMString type, optional boolean bubbles = false,
                            optional boolean cancelable = false, optional any detail = null);
};

dictionary UIEventInit : EventInit {
  Window? view = null;
  long detail = 0;
};

[Exposed=Window]
interface UIEvent : Event {
  constructor(DOMString type, optional UIEventInit eventInitDict = {});
  readonly attribute Window? view;
  readonly attribute long detail;
  readonly attribute unsigned long which;
};

dictionary EventModifierInit : UIEventInit {
  boolean ctrlKey = false;
  boolean shiftKey = false;
  boolean altKey = false;
  boolean metaKey = false;
};

dictionary MouseEventInit : EventModifierInit {
  long screenX = 0;
  long screenY = 0;
  long clientX = 0;
  long clientY = 0;
  short button = 0;
  unsigned short buttons = 0;
  EventTarget? relatedTarget = null;
};

[Exposed=Window]
interface MouseEvent : UIEvent {
  constructor(DOMString type, optional MouseEventInit eventInitDict = {});
  readonly attribute long screenX;
  readonly attribute long screenY;
  readonly attribute long clientX;
  readonly attribute long clientY;
  readonly attribute long pageX;
  readonly attribute long pageY;
  readonly attribute long offsetX;
  readonly attribute long offsetY;
  readonly attribute long x;
  readonly attribute long y;
  readonly attribute boolean ctrlKey;
  readonly attribute boolean shiftKey;
  readonly attribute boolean altKey;
  readonly attribute boolean metaKey;
  readonly attribute short button;
  readonly attribute unsigned short buttons;
  readonly attribute EventTarget? relatedTarget;
  boolean getModifierState(DOMString keyArg);
};

dictionary KeyboardEventInit : EventModifierInit {
  DOMString key = "";
  DOMString code = "";
  unsigned long location = 0;
  boolean repeat = false;
  boolean isComposing = false;
  unsigned long charCode = 0;
  unsigned long keyCode = 0;
};

[Exposed=Window]
interface KeyboardEvent : UIEvent {
  constructor(DOMString type, optional KeyboardEventInit eventInitDict = {});
  const unsigned long DOM_KEY_LOCATION_STANDARD = 0x00;
  const unsigned long DOM_KEY_LOCATION_LEFT = 0x01;
  const unsigned long DOM_KEY_LOCATION_RIGHT = 0x02;
  const unsigned long DOM_KEY_LOCATION_NUMPAD = 0x03;
  readonly attribute DOMString key;
  readonly attribute DOMString code;
  readonly attribute unsigned long location;
  readonly attribute boolean ctrlKey;
  readonly attribute boolean shiftKey;
  readonly attribute boolean altKey;
  readonly attribute boolean metaKey;
  readonly attribute boolean repeat;
  readonly attribute boolean isComposing;
  readonly attribute unsigned long charCode;
  readonly attribute unsigned long keyCode;
  boolean getModifierState(DOMString keyArg);
};

dictionary FocusEventInit : UIEventInit {
  EventTarget? relatedTarget = null;
};

[Exposed=Window]
interface FocusEvent : UIEvent {
  constructor(DOMString type, optional FocusEventInit eventInitDict = {});
  readonly attribute EventTarget? relatedTarget;
};

dictionary InputEventInit : UIEventInit {
  DOMString? data = null;
  boolean isComposing = false;
  DOMString inputType = "";
};

[Exposed=Window]
interface InputEvent : UIEvent {
  constructor(DOMString type, optional InputEventInit eventInitDict = {});
  readonly attribute DOMString? data;
  readonly attribute boolean isComposing;
  readonly attribute DOMString inputType;
};

interface mixin GlobalEventHandlers {
  attribute EventHandler onabort;
  attribute EventHandler onauxclick;
  attribute EventHandler onbeforeinput;
  attribute EventHandler onblur;
  attribute EventHandler oncancel;
  attribute EventHandler onchange;
  attribute EventHandler onclick;
  attribute EventHandler onclose;
  attribute EventHandler oncontextmenu;
  attribute EventHandler oncopy;
  attribute EventHandler oncut;
  attribute EventHandler ondblclick;
  attribute EventHandler ondrag;
  attribute EventHandler ondragend;
  attribute EventHandler ondragenter;
  attribute EventHandler ondragleave;
  attribute EventHandler ondragover;
  attribute EventHandler ondragstart;
  attribute EventHandler ondrop;
  attribute EventHandler onerror;
  attribute EventHandler onfocus;
  attribute EventHandler onfocusin;
  attribute EventHandler onfocusout;
  attribute EventHandler oninput;
  attribute EventHandler oninvalid;
  attribute EventHandler onkeydown;
  attribute EventHandler onkeypress;
  attribute EventHandler onkeyup;
  attribute EventHandler onload;
  attribute EventHandler onmousedown;
  attribute EventHandler onmouseenter;
  attribute EventHandler onmouseleave;
  attribute EventHandler onmousemove;
  attribute EventHandler onmouseout;
  attribute EventHandler onmouseover;
  attribute EventHandler onmouseup;
  attribute EventHandler onpaste;
  attribute EventHandler onpointercancel;
  attribute EventHandler onpointerdown;
  attribute EventHandler onpointerenter;
  attribute EventHandler onpointerleave;
  attribute EventHandler onpointermove;
  attribute EventHandler onpointerout;
  attribute EventHandler onpointerover;
  attribute EventHandler onpointerup;
  attribute EventHandler onreset;
  attribute EventHandler onresize;
  attribute EventHandler onscroll;
  attribute EventHandler onscrollend;
  attribute EventHandler onselect;
  attribute EventHandler onsubmit;
  attribute EventHandler ontoggle;
  attribute EventHandler ontransitionend;
  attribute EventHandler onanimationend;
  attribute EventHandler onwheel;
};

interface mixin WindowEventHandlers {
  attribute EventHandler onafterprint;
  attribute EventHandler onbeforeprint;
  attribute EventHandler onbeforeunload;
  attribute EventHandler onhashchange;
  attribute EventHandler onlanguagechange;
  attribute EventHandler onmessage;
  attribute EventHandler onoffline;
  attribute EventHandler ononline;
  attribute EventHandler onpagehide;
  attribute EventHandler onpageshow;
  attribute EventHandler onpopstate;
  attribute EventHandler onrejectionhandled;
  attribute EventHandler onstorage;
  attribute EventHandler onunhandledrejection;
  attribute EventHandler onunload;
};

// CSS Animations 1 and CSS Transitions 1.
dictionary AnimationEventInit : EventInit {
  DOMString animationName = "";
  double elapsedTime = 0.0;
  DOMString pseudoElement = "";
};

[Exposed=Window]
interface AnimationEvent : Event {
  constructor(DOMString type, optional AnimationEventInit animationEventInitDict = {});
  readonly attribute DOMString animationName;
  readonly attribute double elapsedTime;
  readonly attribute DOMString pseudoElement;
};

dictionary TransitionEventInit : EventInit {
  DOMString propertyName = "";
  double elapsedTime = 0.0;
  DOMString pseudoElement = "";
};

[Exposed=Window]
interface TransitionEvent : Event {
  constructor(DOMString type, optional TransitionEventInit transitionEventInitDict = {});
  readonly attribute DOMString propertyName;
  readonly attribute double elapsedTime;
  readonly attribute DOMString pseudoElement;
};
