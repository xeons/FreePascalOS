// CSSOM: style sheets and their rules (CSS Object Model 6.1 to 6.4),
// constructable style sheets and adoptedStyleSheets. Implemented in
// Web.Bindings.StyleSheets over libcss's sheets (Css.Stylesheets), the
// document's sheet objects (Web.Style.DocumentSheets); replace() is in
// platform/74-cssom.js.

[Exposed=Window]
interface MediaList {
  stringifier attribute [LegacyNullToEmptyString] DOMString mediaText;
  readonly attribute unsigned long length;
  getter DOMString? item(unsigned long index);
  undefined appendMedium(DOMString medium);
  undefined deleteMedium(DOMString medium);
};

[Exposed=Window]
interface StyleSheet {
  readonly attribute DOMString type;
  readonly attribute USVString? href;
  readonly attribute Node? ownerNode;
  readonly attribute CSSStyleSheet? parentStyleSheet;
  readonly attribute DOMString? title;
  [SameObject, PutForwards=mediaText] readonly attribute MediaList media;
  attribute boolean disabled;
};

dictionary CSSStyleSheetInit {
  DOMString baseURL;
  DOMString media = "";
  boolean disabled = false;
};

[Exposed=Window]
interface CSSStyleSheet : StyleSheet {
  constructor(optional CSSStyleSheetInit options = {});
  readonly attribute CSSRule? ownerRule;
  [SameObject] readonly attribute CSSRuleList cssRules;
  unsigned long insertRule(DOMString rule, optional unsigned long index = 0);
  undefined deleteRule(unsigned long index);
  undefined replaceSync(USVString text);
  [SameObject] readonly attribute CSSRuleList rules;
  long addRule(optional DOMString selector = "undefined", optional DOMString style = "undefined",
               optional unsigned long index);
  undefined removeRule(optional unsigned long index = 0);
};

[Exposed=Window]
interface StyleSheetList {
  getter CSSStyleSheet? item(unsigned long index);
  readonly attribute unsigned long length;
};

[Exposed=Window]
interface CSSRuleList {
  getter CSSRule? item(unsigned long index);
  readonly attribute unsigned long length;
};

[Exposed=Window]
interface CSSRule {
  attribute DOMString cssText;
  readonly attribute CSSRule? parentRule;
  readonly attribute CSSStyleSheet? parentStyleSheet;
  readonly attribute unsigned short type;
  const unsigned short STYLE_RULE = 1;
  const unsigned short CHARSET_RULE = 2;
  const unsigned short IMPORT_RULE = 3;
  const unsigned short MEDIA_RULE = 4;
  const unsigned short FONT_FACE_RULE = 5;
  const unsigned short PAGE_RULE = 6;
  const unsigned short KEYFRAMES_RULE = 7;
  const unsigned short KEYFRAME_RULE = 8;
  const unsigned short MARGIN_RULE = 9;
  const unsigned short NAMESPACE_RULE = 10;
  const unsigned short COUNTER_STYLE_RULE = 11;
  const unsigned short SUPPORTS_RULE = 12;
  const unsigned short FONT_FEATURE_VALUES_RULE = 14;
};

[Exposed=Window]
interface CSSGroupingRule : CSSRule {
  [SameObject] readonly attribute CSSRuleList cssRules;
  unsigned long insertRule(DOMString rule, optional unsigned long index = 0);
  undefined deleteRule(unsigned long index);
};

[Exposed=Window]
interface CSSStyleRule : CSSGroupingRule {
  attribute DOMString selectorText;
  [SameObject, PutForwards=cssText] readonly attribute CSSStyleProperties style;
};

[Exposed=Window]
interface CSSConditionRule : CSSGroupingRule {
  readonly attribute DOMString conditionText;
};

[Exposed=Window]
interface CSSMediaRule : CSSConditionRule {
  [SameObject, PutForwards=mediaText] readonly attribute MediaList media;
  readonly attribute boolean matches;
};

[Exposed=Window]
interface CSSSupportsRule : CSSConditionRule {
  readonly attribute boolean matches;
};

[Exposed=Window]
interface CSSLayerBlockRule : CSSGroupingRule {
  readonly attribute DOMString name;
};

[Exposed=Window]
interface CSSImportRule : CSSRule {
  readonly attribute USVString href;
  [SameObject, PutForwards=mediaText] readonly attribute MediaList media;
  [SameObject] readonly attribute CSSStyleSheet? styleSheet;
  readonly attribute DOMString? layerName;
  readonly attribute DOMString? supportsText;
};

[Exposed=Window]
interface CSSNamespaceRule : CSSRule {
  readonly attribute DOMString namespaceURI;
  readonly attribute DOMString prefix;
};

[Exposed=Window]
interface CSSFontFaceRule : CSSRule {
};

[Exposed=Window]
interface CSSKeyframeRule : CSSRule {
  attribute DOMString keyText;
  [SameObject, PutForwards=cssText] readonly attribute CSSStyleProperties style;
};

[Exposed=Window]
interface CSSKeyframesRule : CSSRule {
  attribute DOMString name;
  [SameObject] readonly attribute CSSRuleList cssRules;
  readonly attribute unsigned long length;
  getter CSSKeyframeRule? item(unsigned long index);
  undefined appendRule(DOMString rule);
  undefined deleteRule(DOMString select);
  CSSKeyframeRule? findRule(DOMString select);
};

partial interface Document {
  [SameObject] readonly attribute StyleSheetList styleSheets;
  attribute any adoptedStyleSheets;
};

partial interface ShadowRoot {
  attribute any adoptedStyleSheets;
};

partial interface HTMLStyleElement {
  readonly attribute CSSStyleSheet? sheet;
};

partial interface HTMLLinkElement {
  readonly attribute CSSStyleSheet? sheet;
};
