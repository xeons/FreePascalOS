// WebAssembly exception handling in the JavaScript Interface: Tag, Exception
// and the namespace's JSTag. The WebIDL side, after 57-webassembly.js
// (whose helpers it takes from internal.webassembly); the natives are
// Web.Script.NativeWasmExceptions'.
//
// A Tag is a tag of the agent's store (new ones made by the constructor,
// exported ones read from instances, one Tag object per tag). An Exception
// is an exception object of the store's heap: made here, or caught from
// WebAssembly (the same Exception object every time the same exception
// comes out). JSTag is the tag WebAssembly sees JavaScript exceptions
// with: catch $JSTag gets the value thrown as an externref; no Exception
// of it can be made. getArg takes the tag, as engines have it.
(function (natives, global, internal) {
  "use strict";
  const shared = internal.webassembly;
  const requireArguments = shared.requireArguments;
  const prototypeFrom = shared.prototypeFrom;
  const enforceRange = shared.enforceRange;
  const valueTypes = shared.valueTypes;
  const WeakMapClass = WeakMap;
  const weakGet = WeakMap.prototype.get;
  const weakSet = WeakMap.prototype.set;
  const ErrorClass = Error;
  const TAG = 4, EXCEPTION = 5;

  // A WebIDL sequence<T>: an object with an iterator, each item converted
  // as it is read.
  function sequence(value, what, convert) {
    if (value === null || (typeof value !== "object" && typeof value !== "function") ||
      typeof value[Symbol.iterator] !== "function")
      throw new TypeError(what + " must be a sequence");
    const items = [];
    for (const item of value) items.push(convert(item));
    return items;
  }

  function valueTypeName(value, what) {
    const name = `${value}`;
    if (valueTypes.indexOf(name) < 0) throw new TypeError(what + ": unknown value type " + JSON.stringify(name));
    return name;
  }

  class Tag {
    constructor(type) {
      requireArguments(arguments.length, 1, "WebAssembly.Tag");
      const what = "WebAssembly.Tag";
      const fields = shared.dictionary(type, what);
      const parameters = sequence(shared.requiredMember(fields, "parameters", what), what + ": parameters",
        function (item) { return valueTypeName(item, what); });
      return natives.wasmNewTag(parameters, prototypeFrom(new.target, Tag));
    }
  }

  // [[Stack]]: a string when made with traceStack, else undefined.
  const exceptionStacks = new WeakMapClass();

  function currentStack() {
    const stack = new ErrorClass().stack;
    if (typeof stack !== "string") return undefined;
    // Without this script's own frame.
    const lines = stack.split("\n");
    return lines.slice(lines.length > 1 && lines[0].indexOf("Error") === 0 ? 2 : 1).join("\n");
  }

  class Exception {
    constructor(exceptionTag, payload, options = undefined) {
      requireArguments(arguments.length, 2, "WebAssembly.Exception");
      const what = "WebAssembly.Exception";
      natives.wasmCheck(exceptionTag, TAG);
      const values = sequence(payload, what + ": the payload", function (item) { return item; });
      const fields = shared.dictionary(options, what);
      const traceStack = !!shared.member(fields, "traceStack");
      const exception = natives.wasmNewException(exceptionTag, values, prototypeFrom(new.target, Exception));
      if (traceStack) weakSet.call(exceptionStacks, exception, currentStack());
      return exception;
    }
    getArg(exceptionTag, index) {
      natives.wasmCheck(this, EXCEPTION);
      requireArguments(arguments.length, 2, "WebAssembly.Exception.getArg");
      natives.wasmCheck(exceptionTag, TAG);
      const position = enforceRange(index, "WebAssembly.Exception.getArg: index");
      if (!natives.wasmExceptionIs(this, exceptionTag))
        throw new TypeError("WebAssembly.Exception.getArg: the exception is not of that tag");
      return natives.wasmExceptionGetArg(this, position);
    }
    is(exceptionTag) {
      natives.wasmCheck(this, EXCEPTION);
      requireArguments(arguments.length, 1, "WebAssembly.Exception.is");
      natives.wasmCheck(exceptionTag, TAG);
      return natives.wasmExceptionIs(this, exceptionTag);
    }
    get stack() {
      natives.wasmCheck(this, EXCEPTION);
      return weakGet.call(exceptionStacks, this);
    }
  }

  shared.finish(Tag, "Tag");
  shared.finish(Exception, "Exception");
  Object.defineProperty(shared.namespace, "JSTag", {
    get: { JSTag() { return natives.wasmJSTag(); } }.JSTag,
    enumerable: true,
    configurable: true
  });
  // The getter as WebIDL names it.
  Object.defineProperty(Object.getOwnPropertyDescriptor(shared.namespace, "JSTag").get, "name",
    { value: "get JSTag" });
  natives.wasmRegister(undefined, undefined, undefined, undefined, Tag.prototype, Exception.prototype);
})
