// SVG 2: the element interfaces script sees for elements in the SVG
// namespace (the wrapper's interface is chosen in
// TBindingContext.InterfaceForNode). Their members come from the mixins
// HTML shares with them; the geometry interfaces (getBBox, the animated
// values) are not here yet.

[Exposed=Window]
interface SVGElement : Element {
};
SVGElement includes GlobalEventHandlers;
SVGElement includes HTMLOrSVGElement;
SVGElement includes ElementCSSInlineStyle;

[Exposed=Window]
interface SVGGraphicsElement : SVGElement {
};

[Exposed=Window]
interface SVGSVGElement : SVGGraphicsElement {
};
