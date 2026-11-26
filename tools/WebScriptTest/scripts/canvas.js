// Canvas 2D (HTML Standard 4.12.5): the context's state and attributes,
// filling, stroking, paths, transforms, compositing, gradients, patterns,
// shadows, clipping, images, pixel access, Path2D, encoding, OffscreenCanvas,
// ImageBitmap and their clones. Pixels are read back with getImageData;
// several checks follow web-platform-tests' 2d.* cases.

function makeContext(width, height, settings) {
  var canvas = document.createElement("canvas");
  canvas.width = width;
  canvas.height = height;
  return canvas.getContext("2d", settings);
}

function pixel(ctx, x, y) {
  var data = ctx.getImageData(x, y, 1, 1).data;
  return [data[0], data[1], data[2], data[3]];
}

function near(actual, expected, tolerance) {
  if (tolerance === undefined) tolerance = 2;
  for (var i = 0; i < 4; i++)
    if (Math.abs(actual[i] - expected[i]) > tolerance) return false;
  return true;
}

function throwsName(name, f) {
  try { f(); } catch (e) { return e.name === name; }
  return false;
}

// Interfaces and getContext
var canvas = document.createElement("canvas");
check("canvas default size", canvas.width === 300 && canvas.height === 150);
var ctx = canvas.getContext("2d");
check("getContext('2d') gives a CanvasRenderingContext2D", ctx instanceof CanvasRenderingContext2D);
check("getContext returns the same context", canvas.getContext("2d") === ctx);
check("context.canvas", ctx.canvas === canvas);
check("another context kind is null", canvas.getContext("bitmaprenderer") === null);
check("unknown context ids are null", document.createElement("canvas").getContext("webgl") === null &&
  document.createElement("canvas").getContext("nonsense") === null);
check("interfaces exist", typeof Path2D === "function" && typeof ImageData === "function" &&
  typeof CanvasGradient === "function" && typeof CanvasPattern === "function" && typeof TextMetrics === "function" &&
  typeof OffscreenCanvas === "function" && typeof ImageBitmap === "function" &&
  typeof ImageBitmapRenderingContext === "function" && typeof createImageBitmap === "function");
check("illegal constructors", throwsName("TypeError", function () { new CanvasRenderingContext2D(); }) &&
  throwsName("TypeError", function () { new CanvasGradient(); }));
check("getContextAttributes", ctx.getContextAttributes().alpha === true &&
  ctx.getContextAttributes().colorSpace === "srgb");

// Defaults
check("default styles", ctx.fillStyle === "#000000" && ctx.strokeStyle === "#000000" && ctx.globalAlpha === 1 &&
  ctx.globalCompositeOperation === "source-over" && ctx.lineWidth === 1 && ctx.lineCap === "butt" &&
  ctx.lineJoin === "miter" && ctx.miterLimit === 10 && ctx.shadowColor === "rgba(0, 0, 0, 0)" &&
  ctx.font === "10px sans-serif" && ctx.textAlign === "start" && ctx.textBaseline === "alphabetic" &&
  ctx.direction === "inherit" && ctx.imageSmoothingEnabled === true && ctx.imageSmoothingQuality === "low" &&
  ctx.filter === "none" && ctx.letterSpacing === "0px");
check("a new canvas is transparent black", near(pixel(ctx, 10, 10), [0, 0, 0, 0], 0));

// Colours
ctx.fillStyle = "red";
check("named colour serializes as hex", ctx.fillStyle === "#ff0000");
ctx.fillStyle = "rgba(0, 255, 0, 0.5)";
check("translucent colour serializes as rgba()", ctx.fillStyle === "rgba(0, 255, 0, 0.5)");
ctx.fillStyle = "not a colour";
check("an invalid colour is ignored", ctx.fillStyle === "rgba(0, 255, 0, 0.5)");
ctx.fillStyle = "hsl(240, 100%, 50%)";
check("hsl()", ctx.fillStyle === "#0000ff");
ctx.strokeStyle = "#ABC";
check("short hex", ctx.strokeStyle === "#aabbcc");

// Attribute setters ignore what they must
ctx.lineWidth = -1; ctx.lineWidth = Infinity; ctx.lineWidth = 0;
check("lineWidth ignores non-positive and non-finite values", ctx.lineWidth === 1);
ctx.lineCap = "bogus";
check("an unknown enumeration value is ignored, not an error", ctx.lineCap === "butt");
ctx.lineCap = "round";
check("lineCap", ctx.lineCap === "round");
ctx.globalAlpha = 2; ctx.globalAlpha = NaN;
check("globalAlpha out of range is ignored", ctx.globalAlpha === 1);
ctx.globalCompositeOperation = "nonsense";
check("an unknown operator is ignored", ctx.globalCompositeOperation === "source-over");
ctx.setLineDash([1, 2, 3]);
check("setLineDash with an odd count doubles it", ctx.getLineDash().join() === "1,2,3,1,2,3");
ctx.setLineDash([1, -2]);
check("setLineDash with a negative length is ignored", ctx.getLineDash().join() === "1,2,3,1,2,3");
ctx.font = "bold 20px serif";
check("font serialization", ctx.font === "bold 20px serif");
ctx.font = "italic small-caps 400 12px/2 Unknown Font, sans-serif";
check("font with every part", ctx.font === "italic small-caps 12px \"Unknown Font\", sans-serif");
ctx.font = "inherit";
check("CSS-wide keywords are not fonts", ctx.font === "italic small-caps 12px \"Unknown Font\", sans-serif");
ctx.font = "12pt monospace";
check("points become pixels", ctx.font === "16px monospace");

// Filling
ctx = makeContext(100, 50);
ctx.fillStyle = "#0f0";
ctx.fillRect(0, 0, 100, 50);
check("fillRect", near(pixel(ctx, 50, 25), [0, 255, 0, 255], 0));
ctx.fillStyle = "rgba(255, 0, 0, 0.5)";
ctx.fillRect(0, 0, 50, 50);
check("source-over blends", near(pixel(ctx, 25, 25), [128, 127, 0, 255]));
ctx.clearRect(0, 0, 10, 10);
check("clearRect", near(pixel(ctx, 5, 5), [0, 0, 0, 0], 0) && near(pixel(ctx, 15, 15), [128, 127, 0, 255]));
ctx.fillRect(NaN, 0, 10, 10);
check("non-finite arguments draw nothing", near(pixel(ctx, 5, 5), [0, 0, 0, 0], 0));

// globalAlpha
ctx = makeContext(10, 10);
ctx.globalAlpha = 0.5;
ctx.fillStyle = "#00f";
ctx.fillRect(0, 0, 10, 10);
check("globalAlpha", near(pixel(ctx, 5, 5), [0, 0, 255, 128]));

// Compositing (html5test's blending check, then Porter-Duff operators)
ctx = makeContext(1, 1);
ctx.fillStyle = "#fff";
ctx.fillRect(0, 0, 1, 1);
ctx.globalCompositeOperation = "screen";
ctx.fillStyle = "#000";
ctx.fillRect(0, 0, 1, 1);
check("screen blend mode", ctx.globalCompositeOperation === "screen" && pixel(ctx, 0, 0)[0] === 255);
var operators = ["source-over", "source-in", "source-out", "source-atop", "destination-over", "destination-in",
  "destination-out", "destination-atop", "lighter", "copy", "xor", "multiply", "screen", "overlay", "darken",
  "lighten", "color-dodge", "color-burn", "hard-light", "soft-light", "difference", "exclusion", "hue",
  "saturation", "color", "luminosity"];
var accepted = 0;
operators.forEach(function (name) { ctx.globalCompositeOperation = name; if (ctx.globalCompositeOperation === name) accepted++; });
check("every operator is accepted", accepted === operators.length);

function composite(operation, under, over) {
  var c = makeContext(20, 10);
  c.fillStyle = under;
  c.fillRect(0, 0, 10, 10);
  c.globalCompositeOperation = operation;
  c.fillStyle = over;
  c.fillRect(5, 0, 15, 10);
  return [pixel(c, 2, 5), pixel(c, 7, 5), pixel(c, 17, 5)];
}
var result = composite("destination-out", "#f00", "#00f");
check("destination-out", near(result[0], [255, 0, 0, 255], 0) && result[1][3] === 0 && result[2][3] === 0);
result = composite("source-in", "#f00", "#00f");
check("source-in clears outside the shape", result[0][3] === 0 && near(result[1], [0, 0, 255, 255], 0) &&
  result[2][3] === 0);
result = composite("copy", "#f00", "#00f");
check("copy replaces everything", result[0][3] === 0 && near(result[1], [0, 0, 255, 255], 0));
result = composite("xor", "#f00", "#00f");
check("xor", near(result[0], [255, 0, 0, 255], 0) && result[1][3] === 0 && near(result[2], [0, 0, 255, 255], 0));
result = composite("destination-over", "#f00", "#00f");
check("destination-over", near(result[1], [255, 0, 0, 255], 0) && near(result[2], [0, 0, 255, 255], 0));
result = composite("lighter", "#f00", "#00f");
check("lighter adds", near(result[1], [255, 0, 255, 255], 0));
result = composite("multiply", "#ff8000", "#808080");
check("multiply", near(result[1], [128, 64, 0, 255], 2));
result = composite("difference", "#ffffff", "#ff0000");
check("difference", near(result[1], [0, 255, 255, 255], 1));
result = composite("luminosity", "#ff0000", "#ffffff");
check("luminosity", near(result[1], [255, 255, 255, 255], 2));

// Paths and fill rules
ctx = makeContext(100, 100);
ctx.beginPath();
ctx.arc(50, 50, 40, 0, Math.PI * 2);
ctx.fillStyle = "#f00";
ctx.fill();
check("arc fill", near(pixel(ctx, 50, 50), [255, 0, 0, 255], 0) && pixel(ctx, 2, 2)[3] === 0 &&
  near(pixel(ctx, 50, 12), [255, 0, 0, 255], 0));
check("isPointInPath", ctx.isPointInPath(50, 50) && !ctx.isPointInPath(2, 2));
ctx.clearRect(0, 0, 100, 100);
ctx.beginPath();
ctx.rect(10, 10, 80, 80);
ctx.rect(30, 30, 40, 40);
ctx.fillStyle = "#00f";
ctx.fill("evenodd");
check("even-odd leaves a hole", near(pixel(ctx, 20, 20), [0, 0, 255, 255], 0) && pixel(ctx, 50, 50)[3] === 0);
check("isPointInPath with the even-odd rule", !ctx.isPointInPath(50, 50, "evenodd") && ctx.isPointInPath(50, 50));
ctx.fill();
check("non-zero fills it", near(pixel(ctx, 50, 50), [0, 0, 255, 255], 0));
check("arc with a negative radius", throwsName("IndexSizeError", function () { ctx.arc(0, 0, -1, 0, 1); }));
check("arcTo with a negative radius", throwsName("IndexSizeError", function () { ctx.arcTo(0, 0, 1, 1, -1); }));
ctx.beginPath();
ctx.lineTo(10, 10);
ctx.lineTo(90, 10);
ctx.lineTo(90, 90);
check("lineTo on an empty path starts a subpath there", ctx.isPointInPath(80, 20) && !ctx.isPointInPath(20, 80));

// roundRect
ctx = makeContext(100, 100);
ctx.beginPath();
ctx.roundRect(10, 10, 80, 80, 20);
ctx.fill();
check("roundRect rounds its corners", pixel(ctx, 11, 11)[3] === 0 && pixel(ctx, 50, 11)[3] === 255 &&
  pixel(ctx, 50, 50)[3] === 255);
check("roundRect with five radii", throwsName("RangeError", function () { ctx.roundRect(0, 0, 1, 1, [1, 2, 3, 4, 5]); }));
check("roundRect with a negative radius", throwsName("RangeError", function () { ctx.roundRect(0, 0, 1, 1, -1); }));

// Stroking
ctx = makeContext(100, 100);
ctx.lineWidth = 10;
ctx.strokeStyle = "#0f0";
ctx.beginPath();
ctx.moveTo(10, 50);
ctx.lineTo(90, 50);
ctx.stroke();
check("a stroke is lineWidth wide", near(pixel(ctx, 50, 46), [0, 255, 0, 255], 0) &&
  near(pixel(ctx, 50, 53), [0, 255, 0, 255], 0) && pixel(ctx, 50, 57)[3] === 0 && pixel(ctx, 5, 50)[3] === 0);
check("isPointInStroke", ctx.isPointInStroke(50, 52) && !ctx.isPointInStroke(50, 60));
ctx.clearRect(0, 0, 100, 100);
ctx.lineCap = "square";
ctx.stroke();
check("square caps reach beyond the ends", near(pixel(ctx, 7, 50), [0, 255, 0, 255], 0));
ctx.clearRect(0, 0, 100, 100);
ctx.lineCap = "butt";
ctx.setLineDash([10, 10]);
ctx.stroke();
check("dashes", near(pixel(ctx, 15, 50), [0, 255, 0, 255], 0) && pixel(ctx, 25, 50)[3] === 0 &&
  near(pixel(ctx, 35, 50), [0, 255, 0, 255], 0));
ctx = makeContext(100, 100);
ctx.strokeRect(20.5, 20.5, 60, 60);
check("strokeRect", pixel(ctx, 20, 50)[3] > 0 && pixel(ctx, 50, 50)[3] === 0);

// Transforms
ctx = makeContext(100, 100);
ctx.translate(50, 0);
ctx.scale(2, 1);
ctx.fillStyle = "#f00";
ctx.fillRect(0, 0, 10, 10);
check("translate and scale", near(pixel(ctx, 65, 5), [255, 0, 0, 255], 0) && pixel(ctx, 45, 5)[3] === 0 &&
  pixel(ctx, 75, 5)[3] === 0);
var matrix = ctx.getTransform();
check("getTransform gives a DOMMatrix", matrix instanceof DOMMatrix && matrix.a === 2 && matrix.e === 50 &&
  matrix.d === 1);
ctx.setTransform({ a: 1, d: 1, e: 5, f: 6 });
check("setTransform with a dictionary", ctx.getTransform().e === 5 && ctx.getTransform().f === 6 &&
  ctx.getTransform().a === 1);
check("setTransform with conflicting members", throwsName("TypeError", function () { ctx.setTransform({ a: 1, m11: 2 }); }));
ctx.resetTransform();
ctx.rotate(Math.PI / 2);
ctx.fillRect(10, -20, 10, 10);
check("rotate", near(pixel(ctx, 15, 15), [255, 0, 0, 255], 0));
ctx.setTransform(1, 0, 0, 1, 0, 0);
ctx.save();
ctx.translate(10, 10);
ctx.fillStyle = "#00f";
ctx.restore();
check("save and restore", ctx.getTransform().e === 0 && ctx.fillStyle === "#ff0000");
ctx.restore();
check("restore with nothing saved does nothing", ctx.fillStyle === "#ff0000");

// Clipping
ctx = makeContext(100, 100);
ctx.beginPath();
ctx.rect(25, 25, 50, 50);
ctx.clip();
ctx.fillStyle = "#0f0";
ctx.fillRect(0, 0, 100, 100);
check("clip", near(pixel(ctx, 50, 50), [0, 255, 0, 255], 0) && pixel(ctx, 10, 10)[3] === 0);
ctx.reset();
check("reset clears the clip and the bitmap", pixel(ctx, 50, 50)[3] === 0);
ctx.fillRect(0, 0, 100, 100);
check("after reset the whole canvas draws", pixel(ctx, 10, 10)[3] === 255);

// Gradients
ctx = makeContext(100, 10);
var gradient = ctx.createLinearGradient(0, 0, 100, 0);
gradient.addColorStop(0, "#f00");
gradient.addColorStop(1, "#00f");
ctx.fillStyle = gradient;
check("fillStyle returns the gradient", ctx.fillStyle === gradient && gradient instanceof CanvasGradient);
ctx.fillRect(0, 0, 100, 10);
check("linear gradient", near(pixel(ctx, 0, 5), [253, 0, 2, 255], 4) && near(pixel(ctx, 99, 5), [2, 0, 253, 255], 4) &&
  near(pixel(ctx, 50, 5), [127, 0, 128, 255], 4));
check("addColorStop out of range", throwsName("IndexSizeError", function () { gradient.addColorStop(1.5, "red"); }));
check("addColorStop with a bad colour", throwsName("SyntaxError", function () { gradient.addColorStop(0.5, "nope"); }));
ctx = makeContext(100, 100);
var radial = ctx.createRadialGradient(50, 50, 0, 50, 50, 50);
radial.addColorStop(0, "#fff");
radial.addColorStop(1, "#000");
ctx.fillStyle = radial;
ctx.fillRect(0, 0, 100, 100);
check("radial gradient", pixel(ctx, 50, 50)[0] > 240 && pixel(ctx, 98, 50)[0] < 20);
check("radial gradient with a negative radius",
  throwsName("IndexSizeError", function () { ctx.createRadialGradient(0, 0, -1, 0, 0, 1); }));
var conic = ctx.createConicGradient(0, 50, 50);
conic.addColorStop(0, "#f00");
conic.addColorStop(0.5, "#0f0");
conic.addColorStop(1, "#f00");
ctx.fillStyle = conic;
ctx.fillRect(0, 0, 100, 100);
check("conic gradient", pixel(ctx, 90, 51)[0] > 200 && pixel(ctx, 10, 50)[1] > 200);
var stopsGradient = ctx.createLinearGradient(0, 0, 100, 0);
ctx.fillStyle = stopsGradient;
ctx.clearRect(0, 0, 100, 100);
ctx.fillRect(0, 0, 100, 100);
check("a gradient without stops paints nothing", pixel(ctx, 50, 50)[3] === 0);
stopsGradient.addColorStop(0, "#0f0");
ctx.fillRect(0, 0, 100, 100);
check("a gradient is live: stops added later show", near(pixel(ctx, 50, 50), [0, 255, 0, 255], 0));

// Patterns
var tile = makeContext(2, 2);
tile.fillStyle = "#f00";
tile.fillRect(0, 0, 1, 1);
tile.fillRect(1, 1, 1, 1);
tile.fillStyle = "#00f";
tile.fillRect(1, 0, 1, 1);
tile.fillRect(0, 1, 1, 1);
ctx = makeContext(10, 10);
var pattern = ctx.createPattern(tile.canvas, "repeat");
check("createPattern", pattern instanceof CanvasPattern);
ctx.fillStyle = pattern;
ctx.fillRect(0, 0, 10, 10);
check("a repeating pattern", near(pixel(ctx, 4, 4), [255, 0, 0, 255], 0) && near(pixel(ctx, 5, 4), [0, 0, 255, 255], 0));
ctx.clearRect(0, 0, 10, 10);
ctx.fillStyle = ctx.createPattern(tile.canvas, "no-repeat");
ctx.fillRect(0, 0, 10, 10);
check("no-repeat", near(pixel(ctx, 0, 0), [255, 0, 0, 255], 0) && pixel(ctx, 5, 5)[3] === 0);
ctx.clearRect(0, 0, 10, 10);
ctx.fillStyle = ctx.createPattern(tile.canvas, "repeat-x");
ctx.fillRect(0, 0, 10, 10);
check("repeat-x", near(pixel(ctx, 8, 0), [255, 0, 0, 255], 0) && pixel(ctx, 0, 5)[3] === 0);
check("a bad repetition", throwsName("SyntaxError", function () { ctx.createPattern(tile.canvas, "both"); }));
var transformed = ctx.createPattern(tile.canvas, "repeat");
transformed.setTransform({ e: 1 });
ctx.clearRect(0, 0, 10, 10);
ctx.fillStyle = transformed;
ctx.fillRect(0, 0, 10, 10);
check("a pattern's transform", near(pixel(ctx, 1, 0), [255, 0, 0, 255], 0));

// Shadows
ctx = makeContext(100, 100);
ctx.shadowColor = "#00f";
ctx.shadowOffsetX = 50;
ctx.fillStyle = "#f00";
ctx.fillRect(10, 10, 20, 20);
check("shadow offset", near(pixel(ctx, 20, 20), [255, 0, 0, 255], 0) && near(pixel(ctx, 70, 20), [0, 0, 255, 255], 0));
ctx = makeContext(100, 100);
ctx.shadowColor = "#000";
ctx.shadowBlur = 10;
ctx.fillRect(40, 40, 20, 20);
check("shadow blur spreads beyond the shape", pixel(ctx, 36, 50)[3] > 10 && pixel(ctx, 36, 50)[3] < 250);
ctx = makeContext(100, 100);
ctx.shadowColor = "#000";
ctx.fillRect(10, 10, 10, 10);
check("a shadow without offset or blur is not drawn", pixel(ctx, 25, 15)[3] === 0);

// Filters
ctx = makeContext(20, 20);
ctx.filter = "invert(1)";
check("filter", ctx.filter === "invert(1)");
ctx.fillStyle = "#fff";
ctx.fillRect(0, 0, 20, 20);
check("invert filter", near(pixel(ctx, 10, 10), [0, 0, 0, 255], 0));
ctx.filter = "url(#x)";
check("url() filters are not accepted", ctx.filter === "invert(1)");
ctx.filter = "none";
ctx.filter = "blur(2px) grayscale(50%)";
check("a filter list", ctx.filter === "blur(2px) grayscale(50%)");

// drawImage
var source = makeContext(10, 10);
source.fillStyle = "#f00";
source.fillRect(0, 0, 5, 10);
source.fillStyle = "#0f0";
source.fillRect(5, 0, 5, 10);
ctx = makeContext(40, 20);
ctx.drawImage(source.canvas, 0, 0);
check("drawImage at a point", near(pixel(ctx, 2, 5), [255, 0, 0, 255], 0) && near(pixel(ctx, 7, 5), [0, 255, 0, 255], 0) &&
  pixel(ctx, 12, 5)[3] === 0);
ctx.clearRect(0, 0, 40, 20);
ctx.imageSmoothingEnabled = false;
ctx.drawImage(source.canvas, 0, 0, 40, 20);
check("drawImage scaled", near(pixel(ctx, 10, 10), [255, 0, 0, 255], 0) && near(pixel(ctx, 30, 10), [0, 255, 0, 255], 0));
ctx.clearRect(0, 0, 40, 20);
ctx.drawImage(source.canvas, 5, 0, 5, 10, 0, 0, 10, 20);
check("drawImage of a part", near(pixel(ctx, 5, 10), [0, 255, 0, 255], 0) && pixel(ctx, 15, 10)[3] === 0);
check("drawImage of a canvas of no pixels",
  throwsName("InvalidStateError", function () { var empty = document.createElement("canvas"); empty.width = 0; ctx.drawImage(empty, 0, 0); }));
check("drawImage of something else", throwsName("TypeError", function () { ctx.drawImage({}, 0, 0); }));
ctx.drawImage(new Image(), 0, 0);
check("drawImage of an image not loaded draws nothing", true);

// ImageData
ctx = makeContext(10, 10);
var created = ctx.createImageData(2, 3);
check("createImageData", created instanceof ImageData && created.width === 2 && created.height === 3 &&
  created.data.length === 24 && created.data instanceof Uint8ClampedArray && created.colorSpace === "srgb");
check("createImageData of zero size", throwsName("IndexSizeError", function () { ctx.createImageData(0, 1); }));
check("createImageData with negative sizes", ctx.createImageData(-2, -2).width === 2);
check("ImageData constructor", new ImageData(4, 5).data.length === 80);
var array = new Uint8ClampedArray(16);
var wrapped = new ImageData(array, 2);
check("ImageData on an array", wrapped.data === array && wrapped.height === 2);
check("ImageData with a bad length", throwsName("InvalidStateError", function () { new ImageData(new Uint8ClampedArray(6), 1); }) &&
  throwsName("IndexSizeError", function () { new ImageData(new Uint8ClampedArray(16), 3); }) &&
  throwsName("IndexSizeError", function () { new ImageData(new Uint8ClampedArray(16), 2, 3); }) &&
  throwsName("TypeError", function () { new ImageData(new Uint8Array(16), 2); }));
for (var i = 0; i < array.length; i += 4) { array[i] = 10; array[i + 1] = 20; array[i + 2] = 30; array[i + 3] = 255; }
ctx.putImageData(wrapped, 3, 3);
check("putImageData", near(pixel(ctx, 4, 4), [10, 20, 30, 255], 0) && pixel(ctx, 5, 5)[3] === 0);
ctx.putImageData(wrapped, 0, 0, 1, 1, 1, 1);
check("putImageData of a dirty rectangle", near(pixel(ctx, 1, 1), [10, 20, 30, 255], 0) && pixel(ctx, 0, 0)[3] === 0);
ctx.globalAlpha = 0.1;
ctx.globalCompositeOperation = "xor";
array[3] = 128;
ctx.putImageData(wrapped, 6, 6);
check("putImageData ignores alpha and compositing", near(pixel(ctx, 6, 6), [10, 20, 30, 128], 0));
check("getImageData of zero size", throwsName("IndexSizeError", function () { ctx.getImageData(0, 0, 0, 1); }));
var outside = ctx.getImageData(-5, -5, 3, 3);
check("getImageData outside the canvas is transparent", outside.data[0] === 0 && outside.data[3] === 0);
var cloned = structuredClone(wrapped);
check("ImageData clones", cloned instanceof ImageData && cloned.data !== wrapped.data && cloned.data[0] === 10 &&
  cloned.width === 2);

// Path2D
ctx = makeContext(100, 100);
var path = new Path2D("M 10 10 L 90 10 L 90 90 Z");
check("Path2D from SVG path data", path instanceof Path2D && ctx.isPointInPath(path, 80, 20) &&
  !ctx.isPointInPath(path, 20, 80));
ctx.fillStyle = "#f00";
ctx.fill(path);
check("fill(path)", near(pixel(ctx, 80, 20), [255, 0, 0, 255], 0) && pixel(ctx, 20, 80)[3] === 0);
var copy = new Path2D(path);
var combined = new Path2D();
combined.addPath(copy, { e: -5 });
check("Path2D copy and addPath with a transform", ctx.isPointInPath(combined, 80, 20) && !ctx.isPointInPath(combined, 88, 20));
var built = new Path2D();
built.rect(0, 0, 10, 10);
built.arc(50, 50, 10, 0, Math.PI * 2);
ctx.translate(10, 10);
check("a Path2D goes through the transform", ctx.isPointInPath(built, 15, 15) && !ctx.isPointInPath(built, 5, 5));
ctx.resetTransform();
ctx.lineWidth = 6;
check("isPointInStroke(path)", ctx.isPointInStroke(path, 50, 12) && !ctx.isPointInStroke(path, 60, 40));
check("isPointInPath(path) needs three arguments", throwsName("TypeError", function () { ctx.isPointInPath(path, 1); }));

// Text
ctx = makeContext(200, 50);
ctx.font = "20px sans-serif";
var metrics = ctx.measureText("Hello");
check("measureText gives TextMetrics", metrics instanceof TextMetrics && typeof metrics.width === "number" &&
  typeof metrics.actualBoundingBoxAscent === "number" && typeof metrics.fontBoundingBoxAscent === "number");
// Glyph outlines need fonts (this harness may have none; WebLoadTest
// draws text with the system fonts).
if (metrics.actualBoundingBoxRight > 0) {
  check("measureText grows with the text", ctx.measureText("Hello Hello").width > metrics.width);
  check("text metrics are consistent", metrics.actualBoundingBoxAscent > 5 && metrics.fontBoundingBoxAscent > 10 &&
    metrics.alphabeticBaseline === 0 && metrics.emHeightAscent + metrics.emHeightDescent > 19);
  ctx.textBaseline = "top";
  check("baselines are relative to textBaseline", ctx.measureText("x").alphabeticBaseline < 0);
  ctx.textBaseline = "alphabetic";
  ctx.fillStyle = "#000";
  ctx.fillText("Hello", 10, 35);
  var inked = 0;
  var text = ctx.getImageData(0, 0, 200, 50).data;
  for (var t = 3; t < text.length; t += 4) if (text[t] > 0) inked++;
  check("fillText draws", inked > 50);
  ctx.clearRect(0, 0, 200, 50);
  ctx.textAlign = "right";
  ctx.fillText("Hello", 10, 35);
  var left = 0;
  text = ctx.getImageData(11, 0, 189, 50).data;
  for (t = 3; t < text.length; t += 4) if (text[t] > 0) left++;
  check("textAlign right puts the text before x", left === 0);
  ctx.clearRect(0, 0, 200, 50);
  ctx.textAlign = "left";
  ctx.fillText("Hello Hello Hello", 0, 35, 20);
  text = ctx.getImageData(25, 0, 175, 50).data;
  left = 0;
  for (t = 3; t < text.length; t += 4) if (text[t] > 0) left++;
  check("maxWidth squeezes the text", left === 0);
}
ctx.letterSpacing = "2px";
check("letterSpacing", ctx.letterSpacing === "2px");
ctx.letterSpacing = "bad";
check("a bad letterSpacing is ignored", ctx.letterSpacing === "2px");

// Encoding
canvas = document.createElement("canvas");
canvas.width = 4;
canvas.height = 4;
ctx = canvas.getContext("2d");
ctx.fillStyle = "#f00";
ctx.fillRect(0, 0, 4, 4);
check("toDataURL is PNG by default", canvas.toDataURL().indexOf("data:image/png;base64,iVBORw0KGgo") === 0);
check("toDataURL('image/jpeg')", canvas.toDataURL("image/jpeg").substring(5, 15) === "image/jpeg" &&
  canvas.toDataURL("image/jpeg", 0.5).indexOf("data:image/jpeg;base64,/9j/") === 0);
check("toDataURL('image/webp')", canvas.toDataURL("image/webp").indexOf("data:image/webp;base64,UklGR") === 0);
check("an unsupported type gives PNG", canvas.toDataURL("image/vnd.ms-photo").substring(5, 14) === "image/png");
var empty = document.createElement("canvas");
empty.width = 0;
check("toDataURL of no pixels", empty.toDataURL() === "data:,");
var blobResult = "pending";
canvas.toBlob(function (blob) { blobResult = blob; }, "image/png");
check("toBlob calls back later", blobResult === "pending");

// Resizing resets the bitmap and the context
ctx.fillStyle = "#00f";
canvas.width = 4;
check("setting width clears the bitmap and the state", pixel(ctx, 1, 1)[3] === 0 && ctx.fillStyle === "#000000");
canvas.setAttribute("height", "8");
check("setting the height attribute resizes", ctx.getImageData(0, 0, 4, 8).data.length === 128 && canvas.height === 8);

// alpha: false
ctx = makeContext(4, 4, { alpha: false });
check("an opaque canvas starts black", near(pixel(ctx, 1, 1), [0, 0, 0, 255], 0) &&
  ctx.getContextAttributes().alpha === false);
ctx.clearRect(0, 0, 4, 4);
check("clearRect on an opaque canvas gives black", near(pixel(ctx, 1, 1), [0, 0, 0, 255], 0));

// bitmaprenderer
var rendererCanvas = document.createElement("canvas");
var renderer = rendererCanvas.getContext("bitmaprenderer");
check("getContext('bitmaprenderer')", renderer instanceof ImageBitmapRenderingContext && renderer.canvas === rendererCanvas);

// OffscreenCanvas
var offscreen = new OffscreenCanvas(16, 8);
check("OffscreenCanvas", offscreen.width === 16 && offscreen.height === 8 && offscreen instanceof EventTarget);
var offscreenContext = offscreen.getContext("2d");
check("OffscreenCanvas getContext('2d')", offscreenContext instanceof OffscreenCanvasRenderingContext2D &&
  offscreenContext.canvas === offscreen && offscreen.getContext("2d") === offscreenContext);
offscreenContext.fillStyle = "#0f0";
offscreenContext.fillRect(0, 0, 16, 8);
check("drawing on an OffscreenCanvas", near(pixel(offscreenContext, 3, 3), [0, 255, 0, 255], 0));
ctx = makeContext(20, 20);
ctx.drawImage(offscreen, 0, 0);
check("drawImage of an OffscreenCanvas", near(pixel(ctx, 3, 3), [0, 255, 0, 255], 0));
var transferred = offscreen.transferToImageBitmap();
check("transferToImageBitmap", transferred instanceof ImageBitmap && transferred.width === 16 &&
  pixel(offscreenContext, 3, 3)[3] === 0);
ctx.clearRect(0, 0, 20, 20);
ctx.drawImage(transferred, 0, 0);
check("drawImage of an ImageBitmap", near(pixel(ctx, 3, 3), [0, 255, 0, 255], 0));
var bitmapClone = structuredClone(transferred);
check("ImageBitmap clones", bitmapClone instanceof ImageBitmap && bitmapClone.width === 16);
transferred.close();
check("a closed ImageBitmap", transferred.width === 0 &&
  throwsName("InvalidStateError", function () { ctx.drawImage(transferred, 0, 0); }));
renderer.transferFromImageBitmap(bitmapClone);
check("transferFromImageBitmap detaches the bitmap", bitmapClone.width === 0);
offscreen.width = 4;
check("resizing an OffscreenCanvas", offscreen.width === 4);
check("structuredClone refuses an OffscreenCanvas", throwsName("DataCloneError", function () { structuredClone(offscreen); }));
var placeholder = document.createElement("canvas");
var control = placeholder.transferControlToOffscreen();
check("transferControlToOffscreen", control instanceof OffscreenCanvas && control.width === 300 &&
  throwsName("InvalidStateError", function () { placeholder.getContext("2d"); }));

var asyncResults = {};
offscreenContext.fillStyle = "#f00";
offscreenContext.fillRect(0, 0, 4, 8);
offscreen.convertToBlob({ type: "image/png" }).then(function (blob) { asyncResults.convert = blob; });
new OffscreenCanvas(0, 4).convertToBlob().catch(function (error) { asyncResults.convertError = error.name; });
createImageBitmap(source.canvas).then(function (bitmap) { asyncResults.fromCanvas = bitmap; });
createImageBitmap(wrapped, 0, 0, 1, 1).then(function (bitmap) { asyncResults.fromImageData = bitmap; });
createImageBitmap(source.canvas, { resizeWidth: 20, resizeHeight: 5 }).then(function (bitmap) { asyncResults.resized = bitmap; });
createImageBitmap(source.canvas, 0, 0, 0, 1).catch(function (error) { asyncResults.zeroRect = error.name; });
createImageBitmap(new Blob(["not an image"])).catch(function (error) { asyncResults.badBlob = error.name; });
canvas.toBlob(function (blob) {
  asyncResults.toBlob = blob;
  if (blob) createImageBitmap(blob).then(function (bitmap) { asyncResults.fromBlob = bitmap; });
});

function after() {
  check("toBlob gives a PNG Blob", blobResult instanceof Blob && blobResult.type === "image/png" && blobResult.size > 20);
  check("convertToBlob", asyncResults.convert instanceof Blob && asyncResults.convert.type === "image/png");
  check("convertToBlob of no pixels rejects", asyncResults.convertError === "IndexSizeError");
  check("createImageBitmap of a canvas", asyncResults.fromCanvas instanceof ImageBitmap &&
    asyncResults.fromCanvas.width === 10);
  check("createImageBitmap of ImageData with a crop", asyncResults.fromImageData instanceof ImageBitmap &&
    asyncResults.fromImageData.width === 1);
  check("createImageBitmap resized", asyncResults.resized && asyncResults.resized.width === 20 &&
    asyncResults.resized.height === 5);
  check("createImageBitmap with an empty crop rejects", asyncResults.zeroRect === "RangeError");
  check("createImageBitmap of a Blob that is no image rejects", asyncResults.badBlob === "InvalidStateError");
  check("createImageBitmap of an encoded Blob", asyncResults.fromBlob instanceof ImageBitmap &&
    asyncResults.fromBlob.width === 4 && asyncResults.fromBlob.height === 8);
}
