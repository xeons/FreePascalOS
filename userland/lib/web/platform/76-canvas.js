// The canvas operations that settle later (HTML Standard 4.12.5):
// HTMLCanvasElement.toBlob (the callback in a task), OffscreenCanvas
// convertToBlob and createImageBitmap (promises), over the natives of
// Web.Script.NativeCanvas, which encode with libimage, decode Blobs and
// crop, resize and flip the bitmaps. The structured clone of ImageData
// and ImageBitmap (serializable) and the transfer of ImageBitmap and
// OffscreenCanvas (transferable) to workers go through the clone hooks
// and internal.cloneWithTransfer, which the workers' postMessage uses.
(function (natives, global, internal) {
  "use strict";
  const defineProperty = Object.defineProperty;
  const BlobClass = global.Blob;
  const ImageDataClass = global.ImageData;
  const ImageBitmapClass = global.ImageBitmap;
  const OffscreenCanvasClass = global.OffscreenCanvas;
  // Taken now: page script may replace window.structuredClone.
  const structuredCloneOf = global.structuredClone;

  function defineOperation(target, name, value) {
    defineProperty(target, name, { configurable: true, enumerable: true, writable: true, value: value });
  }

  function makeBlob(encoded) {
    return new BlobClass([encoded[0]], { type: encoded[1] });
  }

  // HTMLCanvasElement.toBlob(callback, type, quality)
  defineOperation(global.HTMLCanvasElement.prototype, "toBlob", function toBlob(callback, type, quality) {
    if (arguments.length < 1)
      throw new TypeError("Failed to execute 'toBlob' on 'HTMLCanvasElement': 1 argument required, but only 0 present.");
    if (typeof callback !== "function")
      throw new TypeError("Failed to execute 'toBlob' on 'HTMLCanvasElement': parameter 1 is not of type 'BlobCallback'.");
    const encoded = natives.canvasEncode(this, type === undefined ? "image/png" : String(type), quality, false);
    internal.queueTask(function () {
      callback(encoded === null ? null : makeBlob(encoded));
    });
  });

  // OffscreenCanvas.convertToBlob(options)
  defineOperation(OffscreenCanvasClass.prototype, "convertToBlob", function convertToBlob(options) {
    const canvas = this;
    return new Promise(function (resolve) {
      if (!(canvas instanceof OffscreenCanvasClass)) throw new TypeError("Illegal invocation");
      const init = options === undefined || options === null ? {} : options;
      if (typeof init !== "object" && typeof init !== "function")
        throw new TypeError("Failed to execute 'convertToBlob': the options are not an object.");
      const type = init.type === undefined ? "image/png" : String(init.type);
      const quality = init.quality === undefined ? undefined : Number(init.quality);
      resolve(makeBlob(natives.canvasEncode(canvas, type, quality, true)));
    });
  });

  // WebIDL [EnforceRange] long and unsigned long.
  function enforceLong(value, what) {
    const number = Number(value);
    if (!Number.isFinite(number))
      throw new TypeError("Failed to execute 'createImageBitmap': " + what + " is not a finite number.");
    const integer = Math.trunc(number);
    if (integer < -2147483648 || integer > 2147483647)
      throw new TypeError("Failed to execute 'createImageBitmap': " + what + " is outside the 'long' value range.");
    return integer;
  }

  function enforceUnsigned(value, what) {
    const integer = Math.trunc(Number(value));
    if (!Number.isFinite(Number(value)) || integer < 0 || integer > 4294967295)
      throw new TypeError("Failed to execute 'createImageBitmap': " + what +
        " is outside the 'unsigned long' value range.");
    return integer;
  }

  const orientations = ["from-image", "flipY", "none"];
  const premultiplies = ["none", "premultiply", "default"];
  const conversions = ["none", "default"];
  const qualities = ["pixelated", "low", "medium", "high"];

  function enumMember(value, list, fallback, what) {
    if (value === undefined) return fallback;
    const text = String(value);
    if (list.indexOf(text) < 0)
      throw new TypeError("Failed to execute 'createImageBitmap': '" + text + "' is not a valid value for " + what + ".");
    return text;
  }

  // ImageBitmapOptions, in dictionary member order.
  function readOptions(options) {
    if (options === undefined || options === null) options = {};
    if (typeof options !== "object" && typeof options !== "function")
      throw new TypeError("Failed to execute 'createImageBitmap': the options are not an object.");
    const result = {};
    enumMember(options.colorSpaceConversion, conversions, "default", "colorSpaceConversion");
    result.orientation = enumMember(options.imageOrientation, orientations, "from-image", "imageOrientation");
    enumMember(options.premultiplyAlpha, premultiplies, "default", "premultiplyAlpha");
    result.resizeHeight = options.resizeHeight === undefined ? 0 : enforceUnsigned(options.resizeHeight, "resizeHeight");
    result.hasResizeHeight = options.resizeHeight !== undefined;
    result.quality = enumMember(options.resizeQuality, qualities, "low", "resizeQuality");
    result.resizeWidth = options.resizeWidth === undefined ? 0 : enforceUnsigned(options.resizeWidth, "resizeWidth");
    result.hasResizeWidth = options.resizeWidth !== undefined;
    return result;
  }

  // createImageBitmap(image, options) and
  // createImageBitmap(image, sx, sy, sw, sh, options)
  defineOperation(global, "createImageBitmap", function createImageBitmap(image, sx, sy, sw, sh, options) {
    const count = arguments.length;
    return new Promise(function (resolve, reject) {
      if (count < 1)
        throw new TypeError("Failed to execute 'createImageBitmap': 1 argument required, but only 0 present.");
      if (count === 3 || count === 4)
        throw new TypeError("Failed to execute 'createImageBitmap': no overload takes " + count + " arguments.");
      const hasRect = count >= 5;
      let rect = [0, 0, 0, 0];
      let settings;
      if (hasRect) {
        rect = [enforceLong(sx, "sx"), enforceLong(sy, "sy"), enforceLong(sw, "sw"), enforceLong(sh, "sh")];
        settings = readOptions(options);
      } else
        settings = readOptions(sx);
      if (image === null || typeof image !== "object")
        throw new TypeError("Failed to execute 'createImageBitmap': the provided value is not of type " +
          "'(Blob or HTMLCanvasElement or HTMLImageElement or HTMLVideoElement or ImageBitmap or ImageData or " +
          "OffscreenCanvas)'.");
      if (hasRect && (rect[2] === 0 || rect[3] === 0))
        throw new RangeError("Failed to execute 'createImageBitmap': The crop rect " +
          (rect[2] === 0 ? "width" : "height") + " is 0.");
      if ((settings.hasResizeWidth && settings.resizeWidth === 0) ||
          (settings.hasResizeHeight && settings.resizeHeight === 0))
        throw internal.domException("Failed to execute 'createImageBitmap': The resize width or height is 0.",
          "InvalidStateError");
      const flip = settings.orientation === "flipY";
      const pixelated = settings.quality === "pixelated";
      if (image instanceof BlobClass) {
        image.arrayBuffer().then(function (buffer) {
          resolve(natives.imageBitmapFromBytes(new Uint8Array(buffer), hasRect, rect[0], rect[1], rect[2], rect[3],
            settings.resizeWidth, settings.resizeHeight, flip, pixelated));
        }).catch(function (error) {
          reject(error instanceof DOMException ? error :
            internal.domException("The source image could not be decoded.", "InvalidStateError"));
        });
        return;
      }
      resolve(natives.imageBitmapFrom(image, hasRect, rect[0], rect[1], rect[2], rect[3], settings.resizeWidth,
        settings.resizeHeight, flip, pixelated));
    });
  });

  // Structured clone: ImageData and ImageBitmap are serializable,
  // ImageBitmap and OffscreenCanvas transferable.
  let transferring = null;
  function isCanvasTransferable(value) {
    return value instanceof ImageBitmapClass || value instanceof OffscreenCanvasClass;
  }
  if (internal.cloneHooks === undefined) internal.cloneHooks = [];
  internal.cloneHooks.push(function (value) {
    if (value instanceof ImageDataClass) return natives.cloneCanvasObject(value, false);
    if (isCanvasTransferable(value)) {
      const moving = transferring !== null && transferring.has(value);
      if (moving) transferring.delete(value);
      return natives.cloneCanvasObject(value, moving);
    }
    return undefined;
  });

  // The workers' postMessage: the message cloned with the canvas objects
  // of the transfer list moved rather than copied (MessagePorts are the
  // messaging code's).
  internal.cloneWithTransfer = function (message, transferOrOptions) {
    let transfer = transferOrOptions;
    if (transfer !== null && typeof transfer === "object" && !(Symbol.iterator in transfer))
      transfer = transfer.transfer;
    const list = transfer === undefined || transfer === null ? [] : Array.from(transfer);
    const moving = new Set();
    for (const item of list)
      if (isCanvasTransferable(item)) {
        if (moving.has(item))
          throw internal.domException("Failed to execute 'postMessage': An object appears twice in the transfer " +
            "list.", "DataCloneError");
        moving.add(item);
      }
    const outer = transferring;
    transferring = moving;
    try {
      return structuredCloneOf(message);
    } finally {
      transferring = outer;
      for (const item of moving) natives.detachCanvasObject(item);
    }
  };
})
