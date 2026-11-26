// HTML Standard 4.12.5: the canvas element's scripting, the 2D context
// (CanvasRenderingContext2D and OffscreenCanvasRenderingContext2D share
// the mixins), Path2D, CanvasGradient, CanvasPattern, TextMetrics,
// ImageData, OffscreenCanvas, ImageBitmap and ImageBitmapRenderingContext.
// Implemented in Web.Bindings.Canvas (over Web.Canvas.*); toBlob,
// convertToBlob and createImageBitmap, which settle later, are in
// platform/76-canvas.js.
//
// Overloads the dispatcher cannot tell apart by argument count (fill
// with a path or a rule, isPointInPath with or without a path, the
// ImageData constructor) are written as one operation with a union or
// any, and told apart by the implementation as WebIDL's overload
// resolution would. HTMLMediaElement stands for HTMLVideoElement (there
// is no separate interface yet); video draws nothing until media play.

typedef (HTMLImageElement or HTMLMediaElement or HTMLCanvasElement or ImageBitmap or OffscreenCanvas) CanvasImageSource;

enum PredefinedColorSpace { "srgb", "display-p3" };
enum CanvasFillRule { "nonzero", "evenodd" };
enum ImageSmoothingQuality { "low", "medium", "high" };
enum CanvasLineCap { "butt", "round", "square" };
enum CanvasLineJoin { "round", "bevel", "miter" };
enum CanvasTextAlign { "start", "end", "left", "right", "center" };
enum CanvasTextBaseline { "top", "hanging", "middle", "alphabetic", "ideographic", "bottom" };
enum CanvasDirection { "ltr", "rtl", "inherit" };
enum CanvasFontKerning { "auto", "normal", "none" };
enum CanvasFontStretch { "ultra-condensed", "extra-condensed", "condensed", "semi-condensed", "normal",
  "semi-expanded", "expanded", "extra-expanded", "ultra-expanded" };
enum CanvasFontVariantCaps { "normal", "small-caps", "all-small-caps", "petite-caps", "all-petite-caps",
  "unicase", "titling-caps" };
enum CanvasTextRendering { "auto", "optimizeSpeed", "optimizeLegibility", "geometricPrecision" };
enum OffscreenRenderingContextId { "2d", "bitmaprenderer", "webgl", "webgl2", "webgpu" };

dictionary CanvasRenderingContext2DSettings {
  boolean alpha = true;
  boolean desynchronized = false;
  PredefinedColorSpace colorSpace = "srgb";
  boolean willReadFrequently = false;
};

dictionary ImageDataSettings {
  PredefinedColorSpace colorSpace;
};

dictionary DOMMatrix2DInit {
  unrestricted double a;
  unrestricted double b;
  unrestricted double c;
  unrestricted double d;
  unrestricted double e;
  unrestricted double f;
  unrestricted double m11;
  unrestricted double m12;
  unrestricted double m21;
  unrestricted double m22;
  unrestricted double m41;
  unrestricted double m42;
};

partial interface HTMLCanvasElement {
  any getContext(DOMString contextId, optional CanvasRenderingContext2DSettings options = {});
  USVString toDataURL(optional DOMString type = "image/png", optional any quality);
  OffscreenCanvas transferControlToOffscreen();
};

interface mixin CanvasState {
  undefined save();
  undefined restore();
  undefined reset();
  boolean isContextLost();
};

interface mixin CanvasTransform {
  undefined scale(unrestricted double x, unrestricted double y);
  undefined rotate(unrestricted double angle);
  undefined translate(unrestricted double x, unrestricted double y);
  undefined transform(unrestricted double a, unrestricted double b, unrestricted double c, unrestricted double d,
    unrestricted double e, unrestricted double f);
  [NewObject] any getTransform();
  undefined setTransform(unrestricted double a, unrestricted double b, unrestricted double c, unrestricted double d,
    unrestricted double e, unrestricted double f);
  undefined setTransform(optional DOMMatrix2DInit transform = {});
  undefined resetTransform();
};

interface mixin CanvasCompositing {
  attribute unrestricted double globalAlpha;
  attribute DOMString globalCompositeOperation;
};

interface mixin CanvasImageSmoothing {
  attribute boolean imageSmoothingEnabled;
  attribute ImageSmoothingQuality imageSmoothingQuality;
};

interface mixin CanvasFillStrokeStyles {
  attribute any strokeStyle;
  attribute any fillStyle;
  CanvasGradient createLinearGradient(double x0, double y0, double x1, double y1);
  CanvasGradient createRadialGradient(double x0, double y0, double r0, double x1, double y1, double r1);
  CanvasGradient createConicGradient(double startAngle, double x, double y);
  CanvasPattern? createPattern(CanvasImageSource image, [LegacyNullToEmptyString] DOMString repetition);
};

interface mixin CanvasShadowStyles {
  attribute unrestricted double shadowOffsetX;
  attribute unrestricted double shadowOffsetY;
  attribute unrestricted double shadowBlur;
  attribute DOMString shadowColor;
};

interface mixin CanvasFilters {
  attribute DOMString filter;
};

interface mixin CanvasRect {
  undefined clearRect(unrestricted double x, unrestricted double y, unrestricted double w, unrestricted double h);
  undefined fillRect(unrestricted double x, unrestricted double y, unrestricted double w, unrestricted double h);
  undefined strokeRect(unrestricted double x, unrestricted double y, unrestricted double w, unrestricted double h);
};

interface mixin CanvasDrawPath {
  undefined beginPath();
  undefined fill(optional (Path2D or CanvasFillRule) pathOrFillRule = "nonzero",
    optional CanvasFillRule fillRule = "nonzero");
  undefined stroke(optional Path2D path);
  undefined clip(optional (Path2D or CanvasFillRule) pathOrFillRule = "nonzero",
    optional CanvasFillRule fillRule = "nonzero");
  boolean isPointInPath((Path2D or unrestricted double) pathOrX, unrestricted double xOrY,
    optional (unrestricted double or CanvasFillRule) yOrFillRule = "nonzero", optional CanvasFillRule fillRule = "nonzero");
  boolean isPointInStroke((Path2D or unrestricted double) pathOrX, unrestricted double xOrY,
    optional unrestricted double y);
};

interface mixin CanvasUserInterface {
  undefined drawFocusIfNeeded(optional (Path2D or Element) pathOrElement, optional Element element);
};

interface mixin CanvasText {
  undefined fillText(DOMString text, unrestricted double x, unrestricted double y, optional unrestricted double maxWidth);
  undefined strokeText(DOMString text, unrestricted double x, unrestricted double y,
    optional unrestricted double maxWidth);
  TextMetrics measureText(DOMString text);
};

interface mixin CanvasDrawImage {
  undefined drawImage(CanvasImageSource image, unrestricted double dx, unrestricted double dy);
  undefined drawImage(CanvasImageSource image, unrestricted double dx, unrestricted double dy, unrestricted double dw,
    unrestricted double dh);
  undefined drawImage(CanvasImageSource image, unrestricted double sx, unrestricted double sy, unrestricted double sw,
    unrestricted double sh, unrestricted double dx, unrestricted double dy, unrestricted double dw,
    unrestricted double dh);
};

interface mixin CanvasImageData {
  ImageData createImageData([EnforceRange] long sw, [EnforceRange] long sh, optional ImageDataSettings settings = {});
  ImageData createImageData(ImageData imagedata);
  ImageData getImageData([EnforceRange] long sx, [EnforceRange] long sy, [EnforceRange] long sw, [EnforceRange] long sh,
    optional ImageDataSettings settings = {});
  undefined putImageData(ImageData imagedata, [EnforceRange] long dx, [EnforceRange] long dy);
  undefined putImageData(ImageData imagedata, [EnforceRange] long dx, [EnforceRange] long dy,
    [EnforceRange] long dirtyX, [EnforceRange] long dirtyY, [EnforceRange] long dirtyWidth,
    [EnforceRange] long dirtyHeight);
};

interface mixin CanvasPathDrawingStyles {
  attribute unrestricted double lineWidth;
  attribute CanvasLineCap lineCap;
  attribute CanvasLineJoin lineJoin;
  attribute unrestricted double miterLimit;
  undefined setLineDash(sequence<unrestricted double> segments);
  sequence<unrestricted double> getLineDash();
  attribute unrestricted double lineDashOffset;
};

interface mixin CanvasTextDrawingStyles {
  attribute DOMString font;
  attribute CanvasTextAlign textAlign;
  attribute CanvasTextBaseline textBaseline;
  attribute CanvasDirection direction;
  attribute DOMString letterSpacing;
  attribute CanvasFontKerning fontKerning;
  attribute CanvasFontStretch fontStretch;
  attribute CanvasFontVariantCaps fontVariantCaps;
  attribute CanvasTextRendering textRendering;
  attribute DOMString wordSpacing;
};

interface mixin CanvasPath {
  undefined closePath();
  undefined moveTo(unrestricted double x, unrestricted double y);
  undefined lineTo(unrestricted double x, unrestricted double y);
  undefined quadraticCurveTo(unrestricted double cpx, unrestricted double cpy, unrestricted double x,
    unrestricted double y);
  undefined bezierCurveTo(unrestricted double cp1x, unrestricted double cp1y, unrestricted double cp2x,
    unrestricted double cp2y, unrestricted double x, unrestricted double y);
  undefined arcTo(unrestricted double x1, unrestricted double y1, unrestricted double x2, unrestricted double y2,
    unrestricted double radius);
  undefined rect(unrestricted double x, unrestricted double y, unrestricted double w, unrestricted double h);
  undefined roundRect(unrestricted double x, unrestricted double y, unrestricted double w, unrestricted double h,
    optional any radii = 0);
  undefined arc(unrestricted double x, unrestricted double y, unrestricted double radius,
    unrestricted double startAngle, unrestricted double endAngle, optional boolean counterclockwise = false);
  undefined ellipse(unrestricted double x, unrestricted double y, unrestricted double radiusX,
    unrestricted double radiusY, unrestricted double rotation, unrestricted double startAngle,
    unrestricted double endAngle, optional boolean counterclockwise = false);
};

[Exposed=(Window,Worker)]
interface CanvasRenderingContext2D {
  readonly attribute HTMLCanvasElement canvas;
  CanvasRenderingContext2DSettings getContextAttributes();
};
CanvasRenderingContext2D includes CanvasState;
CanvasRenderingContext2D includes CanvasTransform;
CanvasRenderingContext2D includes CanvasCompositing;
CanvasRenderingContext2D includes CanvasImageSmoothing;
CanvasRenderingContext2D includes CanvasFillStrokeStyles;
CanvasRenderingContext2D includes CanvasShadowStyles;
CanvasRenderingContext2D includes CanvasFilters;
CanvasRenderingContext2D includes CanvasRect;
CanvasRenderingContext2D includes CanvasDrawPath;
CanvasRenderingContext2D includes CanvasUserInterface;
CanvasRenderingContext2D includes CanvasText;
CanvasRenderingContext2D includes CanvasDrawImage;
CanvasRenderingContext2D includes CanvasImageData;
CanvasRenderingContext2D includes CanvasPathDrawingStyles;
CanvasRenderingContext2D includes CanvasTextDrawingStyles;
CanvasRenderingContext2D includes CanvasPath;

[Exposed=(Window,Worker)]
interface OffscreenCanvasRenderingContext2D {
  readonly attribute OffscreenCanvas canvas;
};
OffscreenCanvasRenderingContext2D includes CanvasState;
OffscreenCanvasRenderingContext2D includes CanvasTransform;
OffscreenCanvasRenderingContext2D includes CanvasCompositing;
OffscreenCanvasRenderingContext2D includes CanvasImageSmoothing;
OffscreenCanvasRenderingContext2D includes CanvasFillStrokeStyles;
OffscreenCanvasRenderingContext2D includes CanvasShadowStyles;
OffscreenCanvasRenderingContext2D includes CanvasFilters;
OffscreenCanvasRenderingContext2D includes CanvasRect;
OffscreenCanvasRenderingContext2D includes CanvasDrawPath;
OffscreenCanvasRenderingContext2D includes CanvasText;
OffscreenCanvasRenderingContext2D includes CanvasDrawImage;
OffscreenCanvasRenderingContext2D includes CanvasImageData;
OffscreenCanvasRenderingContext2D includes CanvasPathDrawingStyles;
OffscreenCanvasRenderingContext2D includes CanvasTextDrawingStyles;
OffscreenCanvasRenderingContext2D includes CanvasPath;

[Exposed=(Window,Worker)]
interface CanvasGradient {
  undefined addColorStop(double offset, DOMString color);
};

[Exposed=(Window,Worker)]
interface CanvasPattern {
  undefined setTransform(optional DOMMatrix2DInit transform = {});
};

[Exposed=(Window,Worker)]
interface TextMetrics {
  readonly attribute double width;
  readonly attribute double actualBoundingBoxLeft;
  readonly attribute double actualBoundingBoxRight;
  readonly attribute double fontBoundingBoxAscent;
  readonly attribute double fontBoundingBoxDescent;
  readonly attribute double actualBoundingBoxAscent;
  readonly attribute double actualBoundingBoxDescent;
  readonly attribute double emHeightAscent;
  readonly attribute double emHeightDescent;
  readonly attribute double hangingBaseline;
  readonly attribute double alphabeticBaseline;
  readonly attribute double ideographicBaseline;
};

[Exposed=(Window,Worker), Serializable]
interface ImageData {
  constructor(any dataOrWidth, [EnforceRange] unsigned long widthOrHeight, optional any heightOrSettings,
    optional ImageDataSettings settings = {});
  readonly attribute unsigned long width;
  readonly attribute unsigned long height;
  readonly attribute Uint8ClampedArray data;
  readonly attribute PredefinedColorSpace colorSpace;
};

[Exposed=(Window,Worker)]
interface Path2D {
  constructor(optional (Path2D or DOMString) path);
  undefined addPath(Path2D path, optional DOMMatrix2DInit transform = {});
};
Path2D includes CanvasPath;

[Exposed=(Window,Worker), Serializable, Transferable]
interface ImageBitmap {
  readonly attribute unsigned long width;
  readonly attribute unsigned long height;
  undefined close();
};

[Exposed=(Window,Worker)]
interface ImageBitmapRenderingContext {
  readonly attribute any canvas;
  undefined transferFromImageBitmap(ImageBitmap? bitmap);
};

[Exposed=(Window,Worker), Transferable]
interface OffscreenCanvas : EventTarget {
  constructor([EnforceRange] unsigned long long width, [EnforceRange] unsigned long long height);
  attribute [EnforceRange] unsigned long long width;
  attribute [EnforceRange] unsigned long long height;
  any getContext(OffscreenRenderingContextId contextId, optional CanvasRenderingContext2DSettings options = {});
  ImageBitmap transferToImageBitmap();
  attribute EventHandler oncontextlost;
  attribute EventHandler oncontextrestored;
};
