// The WebAssembly namespace (WebAssembly JavaScript Interface and Web API):
// validate, compile, instantiate, compileStreaming, instantiateStreaming,
// Module, Instance, Memory, Table, Global, CompileError, LinkError and
// RuntimeError, with memory64's address types and the compile options of
// the JS string builtins (Tag, Exception and JSTag are
// 58-webassembly-exceptions.js'). This file is the WebIDL side - argument
// counts, dictionaries read in their members' order, enforced ranges and
// address values, overloads, promises settled in later tasks, streaming
// from a Response - and the engine side is Pascal (Web.Script.NativeWasm
// over libwasm): the Module, Memory, Table and Global objects are host
// objects made there with the prototypes registered below, Exported
// Functions are native functions, and the brand checks are the host
// classes'.
//
// The store is the agent's (the window's runtime, shared by its frames and
// dedicated workers; a worker's scope runs these scripts again for a
// WebAssembly object of its own). A Module is structured-cloneable within
// the agent (structuredClone, postMessage to a frame or a dedicated
// worker): the copy shares the compiled module and its compile options.
(function (natives, global, internal) {
  "use strict";
  const defineProperty = Object.defineProperty;
  const create = Object.create;
  const construct = Reflect.construct;
  const setPrototypeOf = Object.setPrototypeOf;
  const getOwnPropertyNames = Object.getOwnPropertyNames;
  const getOwnPropertyDescriptor = Object.getOwnPropertyDescriptor;
  const isFinite = Number.isFinite;
  const trunc = Math.trunc;
  const PromiseClass = Promise;
  const promiseThen = Promise.prototype.then;
  const promiseResolve = Promise.resolve.bind(Promise);
  const promiseReject = Promise.reject.bind(Promise);
  const ErrorClass = Error;
  const WeakMapClass = WeakMap;
  const weakGet = WeakMap.prototype.get;
  const weakSet = WeakMap.prototype.set;
  const toLowerCase = String.prototype.toLowerCase;
  const MODULE = 0, MEMORY = 1, TABLE = 2, GLOBAL = 3;

  function rejected(error) {
    return promiseReject(error);
  }
  function then(promise, onFulfilled, onRejected) {
    return promiseThen.call(promise, onFulfilled, onRejected);
  }
  // Settled in a task of its own, as the JS API's "queue a task" steps are.
  function inTask(work) {
    return new PromiseClass(function (resolve, reject) {
      internal.queueTask(function () {
        try {
          resolve(work());
        } catch (error) {
          reject(error);
        }
      });
    });
  }

  function requireArguments(count, needed, what) {
    if (count < needed)
      throw new TypeError(what + ": " + needed + " argument" + (needed > 1 ? "s" : "") + " required, but only " +
        count + " present.");
  }

  // WebIDL [EnforceRange] unsigned long.
  function enforceRange(value, what) {
    let number = +value;
    if (!isFinite(number)) throw new TypeError(what + " must be a finite number");
    number = trunc(number);
    if (number < 0 || number > 4294967295) throw new TypeError(what + " is outside the range of unsigned long");
    return number === 0 ? 0 : number;
  }

  // A dictionary argument: undefined and null are empty, anything else
  // that is no object is a TypeError.
  function dictionary(value, what) {
    if (value === undefined || value === null) return null;
    if (typeof value !== "object" && typeof value !== "function")
      throw new TypeError(what + ": the descriptor must be an object");
    return value;
  }
  function member(dictionaryObject, key) {
    return dictionaryObject === null ? undefined : dictionaryObject[key];
  }
  function requiredMember(dictionaryObject, key, what) {
    const value = member(dictionaryObject, key);
    if (value === undefined) throw new TypeError(what + ": the descriptor's " + key + " is required");
    return value;
  }

  // WebIDL "optional object".
  function optionalObject(value, what) {
    if (value === undefined) return undefined;
    if (value === null || (typeof value !== "object" && typeof value !== "function"))
      throw new TypeError(what + ": the import object must be an object");
    return value;
  }

  function prototypeFrom(newTarget, Class) {
    const prototype = newTarget === undefined ? undefined : newTarget.prototype;
    if (prototype === null || (typeof prototype !== "object" && typeof prototype !== "function")) return Class.prototype;
    return prototype;
  }

  // ---- errors: native error constructors of their own (callable without
  // new, Error as their prototype, no toStringTag) ----

  function makeError(name) {
    const Constructor = ({ [name]: function (message) {
      return construct(ErrorClass, arguments.length > 1 ? [message, arguments[1]] : [message],
        new.target === undefined ? Constructor : new.target);
    } })[name];
    setPrototypeOf(Constructor, ErrorClass);
    const prototype = create(ErrorClass.prototype);
    defineProperty(prototype, "constructor", { value: Constructor, writable: true, configurable: true });
    defineProperty(prototype, "name", { value: name, writable: true, configurable: true });
    defineProperty(prototype, "message", { value: "", writable: true, configurable: true });
    defineProperty(Constructor, "prototype", { value: prototype, writable: false, enumerable: false });
    return Constructor;
  }
  const CompileError = makeError("CompileError");
  const LinkError = makeError("LinkError");
  const RuntimeError = makeError("RuntimeError");

  // ---- compile options (JS String Builtins) ----

  // WebAssemblyCompileOptions: builtins (sequence<USVString>: "js-string"
  // gives the wasm:js-string imports) and importedStringConstants (the
  // import module whose globals are string constants: their names).
  const builtinNames = ["cast", "test", "fromCharCodeArray", "intoCharCodeArray", "fromCharCode", "fromCodePoint",
    "charCodeAt", "codePointAt", "length", "concat", "substring", "equals", "compare"];
  const noOptions = { builtins: [], importedStringConstants: null, jsString: false };
  const moduleOptions = new WeakMapClass();

  function compileOptions(value, what) {
    const fields = dictionary(value, what);
    if (fields === null) return noOptions;
    const builtinsValue = member(fields, "builtins");
    const builtins = [];
    if (builtinsValue !== undefined) {
      if (builtinsValue === null || (typeof builtinsValue !== "object" && typeof builtinsValue !== "function") ||
        typeof builtinsValue[Symbol.iterator] !== "function")
        throw new TypeError(what + ": builtins must be a sequence");
      for (const name of builtinsValue) builtins.push(`${name}`);
    }
    const stringsValue = member(fields, "importedStringConstants");
    const importedStringConstants = stringsValue === undefined || stringsValue === null ? null : `${stringsValue}`;
    return { builtins: builtins, importedStringConstants: importedStringConstants,
      jsString: builtins.indexOf("js-string") >= 0 };
  }

  // "Validate builtins and imported strings": no builtin set twice, every
  // builtin import and string constant import of the right type.
  function builtinsValid(module, options) {
    for (let index = 0; index < options.builtins.length; index++)
      if (options.builtins.indexOf(options.builtins[index]) !== index) return false;
    return natives.wasmValidateBuiltins(module, options.jsString, options.importedStringConstants);
  }

  // A Module object of the bytes (CompileError when they or the options'
  // imports are not valid).
  function compileWith(bytes, options, prototype) {
    const module = natives.wasmCompile(bytes, prototype);
    if (!builtinsValid(module, options))
      throw new CompileError("WebAssembly: an import does not match its builtin or string constant type");
    if (options !== noOptions) weakSet.call(moduleOptions, module, options);
    return module;
  }
  function optionsOf(module) {
    const options = weakGet.call(moduleOptions, module);
    return options === undefined ? noOptions : options;
  }
  function isBuiltinImport(options, moduleName, name) {
    return (options.jsString && moduleName === "wasm:js-string" && builtinNames.indexOf(name) >= 0) ||
      (options.importedStringConstants !== null && moduleName === options.importedStringConstants);
  }

  // ---- Module ----

  class Module {
    constructor(bytes, options = undefined) {
      requireArguments(arguments.length, 1, "WebAssembly.Module");
      const what = "WebAssembly.Module";
      return compileWith(bytes, compileOptions(options, what), prototypeFrom(new.target, Module));
    }
    static exports(moduleObject) {
      requireArguments(arguments.length, 1, "WebAssembly.Module.exports");
      natives.wasmCheck(moduleObject, MODULE);
      return natives.wasmModuleExports(moduleObject);
    }
    static imports(moduleObject) {
      requireArguments(arguments.length, 1, "WebAssembly.Module.imports");
      natives.wasmCheck(moduleObject, MODULE);
      const list = natives.wasmModuleImports(moduleObject);
      const options = optionsOf(moduleObject);
      if (options === noOptions) return list;
      const result = [];
      for (const descriptor of list)
        if (!isBuiltinImport(options, descriptor.module, descriptor.name)) result.push(descriptor);
      return result;
    }
    static customSections(moduleObject, sectionName) {
      requireArguments(arguments.length, 2, "WebAssembly.Module.customSections");
      natives.wasmCheck(moduleObject, MODULE);
      return natives.wasmCustomSections(moduleObject, `${sectionName}`);
    }
  }

  // ---- Instance ----

  const instanceExports = new WeakMapClass();

  // The objects the builtin sets and the string constants are looked up
  // in before the import object (JS API "read the imports").
  function builtinOrStringImports(list, options) {
    const map = new Map();
    if (options.jsString) map.set("wasm:js-string", natives.wasmStringBuiltins());
    if (options.importedStringConstants !== null) {
      const constants = create(null);
      for (const entry of list)
        if (entry[0] === options.importedStringConstants) constants[entry[1]] = entry[1];
      map.set(options.importedStringConstants, constants);
    }
    return map;
  }

  // JS API "read the imports": one value per import, in order, each import
  // module looked up again (getters run once per import).
  function readImports(module, importObject) {
    const list = natives.wasmImportKinds(module);
    if (list.length > 0 && importObject === undefined)
      throw new TypeError("WebAssembly: the module has imports, but no import object was given");
    const builtins = builtinOrStringImports(list, optionsOf(module));
    const values = [];
    for (let index = 0; index < list.length; index++) {
      const entry = list[index];
      const moduleName = entry[0], name = entry[1], kind = entry[2], valueType = entry[3];
      const where = "import " + JSON.stringify(moduleName) + " " + JSON.stringify(name);
      let namespace = builtins.get(moduleName);
      if (namespace === undefined || !(name in namespace)) namespace = importObject[moduleName];
      if (namespace === null || (typeof namespace !== "object" && typeof namespace !== "function"))
        throw new TypeError("WebAssembly: " + where + ": the module " + JSON.stringify(moduleName) +
          " is not an object");
      const value = namespace[name];
      switch (kind) {
        case "function":
          if (typeof value !== "function") throw new LinkError("WebAssembly: " + where + ": a function is required");
          break;
        case "global":
          if (!natives.wasmIsGlobal(value)) {
            if (valueType === "i64" && typeof value !== "bigint")
              throw new LinkError("WebAssembly: " + where + ": a BigInt or a WebAssembly.Global is required");
            if ((valueType === "i32" || valueType === "f32" || valueType === "f64") && typeof value !== "number")
              throw new LinkError("WebAssembly: " + where + ": a number or a WebAssembly.Global is required");
            if (valueType === "v128")
              throw new LinkError("WebAssembly: " + where + ": a v128 global must be a WebAssembly.Global");
          }
          break;
        case "memory":
          if (!natives.wasmIsMemory(value))
            throw new LinkError("WebAssembly: " + where + ": a WebAssembly.Memory is required");
          break;
        case "table":
          if (!natives.wasmIsTable(value))
            throw new LinkError("WebAssembly: " + where + ": a WebAssembly.Table is required");
          break;
        case "tag":
          if (!natives.wasmIsTag(value))
            throw new LinkError("WebAssembly: " + where + ": a WebAssembly.Tag is required");
          break;
      }
      values[index] = value;
    }
    return values;
  }

  class Instance {
    constructor(module, importObject = undefined) {
      requireArguments(arguments.length, 1, "WebAssembly.Instance");
      natives.wasmCheck(module, MODULE);
      const imports = optionalObject(importObject, "WebAssembly.Instance");
      const values = readImports(module, imports);
      weakSet.call(instanceExports, this, natives.wasmInstantiate(module, values));
    }
    get exports() {
      const exportsObject = weakGet.call(instanceExports, this);
      if (exportsObject === undefined) throw new TypeError("Illegal invocation: not a WebAssembly.Instance");
      return exportsObject;
    }
  }

  function newInstance(exportsObject) {
    const instance = create(Instance.prototype);
    weakSet.call(instanceExports, instance, exportsObject);
    return instance;
  }

  // JS API "asynchronously instantiate a module": the imports are read now,
  // the instance made in a task.
  function instantiateLater(module, importObject) {
    let values;
    try {
      values = readImports(module, importObject);
    } catch (error) {
      return rejected(error);
    }
    return inTask(function () {
      return newInstance(natives.wasmInstantiate(module, values));
    });
  }

  function compileLater(bytes, options) {
    return inTask(function () {
      return compileWith(bytes, options, Module.prototype);
    });
  }

  // "Instantiate a promise of a module": { module, instance }.
  function instantiateCompiled(promiseOfModule, importObject) {
    return then(promiseOfModule, function (module) {
      return then(instantiateLater(module, importObject), function (instance) {
        return { module: module, instance: instance };
      });
    });
  }

  // ---- Memory, Table, Global ----

  // memory64 and table64: an "address" member of "i32" (the default) or
  // "i64"; AddressValueToU64 converts sizes, indices and deltas -
  // [EnforceRange] unsigned long for i32, a BigInt in 0 .. 2^64-1 for i64 -
  // and results are Numbers or BigInts to match.
  function addressType(fields, what) {
    const value = member(fields, "address");
    if (value === undefined) return "i32";
    const name = `${value}`;
    if (name !== "i32" && name !== "i64") throw new TypeError(what + ": the address type must be \"i32\" or \"i64\"");
    return name;
  }
  function addressValue(value, type, what) {
    return type === "i64" ? natives.wasmToAddress(value) : enforceRange(value, what);
  }

  class Memory {
    constructor(descriptor) {
      requireArguments(arguments.length, 1, "WebAssembly.Memory");
      const what = "WebAssembly.Memory";
      const fields = dictionary(descriptor, what);
      const address = addressType(fields, what);
      const initial = addressValue(requiredMember(fields, "initial", what), address, what + ": initial");
      const maximumValue = member(fields, "maximum");
      const maximum = maximumValue === undefined ? undefined : addressValue(maximumValue, address, what + ": maximum");
      const shared = !!member(fields, "shared");
      return natives.wasmNewMemory(initial, maximum, shared, prototypeFrom(new.target, Memory), address === "i64");
    }
    grow(delta) {
      natives.wasmCheck(this, MEMORY);
      requireArguments(arguments.length, 1, "WebAssembly.Memory.grow");
      return natives.wasmMemoryGrow(this, addressValue(delta, natives.wasmAddressType(this),
        "WebAssembly.Memory.grow: delta"));
    }
    toFixedLengthBuffer() {
      natives.wasmCheck(this, MEMORY);
      return natives.wasmMemoryFixedBuffer(this);
    }
    toResizableBuffer() {
      natives.wasmCheck(this, MEMORY);
      return natives.wasmMemoryResizableBuffer(this);
    }
    get buffer() {
      natives.wasmCheck(this, MEMORY);
      return natives.wasmMemoryBuffer(this);
    }
  }

  // The JS API's value types, and the other reference types' names that
  // engines accept.
  const referenceTypes = ["externref", "anyfunc", "funcref", "anyref", "eqref", "i31ref", "structref", "arrayref",
    "nullref", "nullfuncref", "nullexternref", "exnref"];
  const valueTypes = ["i32", "i64", "f32", "f64", "v128"].concat(referenceTypes);

  function elementType(value, what) {
    const name = `${value}`;
    if (referenceTypes.indexOf(name) < 0)
      throw new TypeError(what + ": the element type must be a reference type (\"anyfunc\", \"externref\" ...)");
    return name;
  }

  class Table {
    constructor(descriptor, value = undefined) {
      requireArguments(arguments.length, 1, "WebAssembly.Table");
      const what = "WebAssembly.Table";
      const fields = dictionary(descriptor, what);
      const element = elementType(requiredMember(fields, "element", what), what);
      const address = addressType(fields, what);
      const initial = addressValue(requiredMember(fields, "initial", what), address, what + ": initial");
      const maximumValue = member(fields, "maximum");
      const maximum = maximumValue === undefined ? undefined : addressValue(maximumValue, address, what + ": maximum");
      return natives.wasmNewTable(element, initial, maximum, value, value !== undefined,
        prototypeFrom(new.target, Table), address === "i64");
    }
    grow(delta, value = undefined) {
      natives.wasmCheck(this, TABLE);
      requireArguments(arguments.length, 1, "WebAssembly.Table.grow");
      return natives.wasmTableGrow(this, addressValue(delta, natives.wasmAddressType(this),
        "WebAssembly.Table.grow: delta"), value, value !== undefined);
    }
    get(index) {
      natives.wasmCheck(this, TABLE);
      requireArguments(arguments.length, 1, "WebAssembly.Table.get");
      return natives.wasmTableGet(this, addressValue(index, natives.wasmAddressType(this),
        "WebAssembly.Table.get: index"));
    }
    set(index, value = undefined) {
      natives.wasmCheck(this, TABLE);
      requireArguments(arguments.length, 1, "WebAssembly.Table.set");
      // An undefined given is a value (a TypeError for anyfunc), as engines
      // and the tests have it.
      natives.wasmTableSet(this, addressValue(index, natives.wasmAddressType(this), "WebAssembly.Table.set: index"),
        value, arguments.length > 1);
    }
    get length() {
      natives.wasmCheck(this, TABLE);
      return natives.wasmTableLength(this);
    }
  }

  class Global {
    constructor(descriptor, v = undefined) {
      requireArguments(arguments.length, 1, "WebAssembly.Global");
      const what = "WebAssembly.Global";
      const fields = dictionary(descriptor, what);
      const mutable = !!member(fields, "mutable");
      const type = `${requiredMember(fields, "value", what)}`;
      if (valueTypes.indexOf(type) < 0) throw new TypeError(what + ": unknown value type " + JSON.stringify(type));
      return natives.wasmNewGlobal(type, mutable, v, v !== undefined, prototypeFrom(new.target, Global));
    }
    valueOf() {
      natives.wasmCheck(this, GLOBAL);
      return natives.wasmGlobalGet(this);
    }
    get value() {
      natives.wasmCheck(this, GLOBAL);
      return natives.wasmGlobalGet(this);
    }
    set value(v) {
      natives.wasmCheck(this, GLOBAL);
      natives.wasmGlobalSet(this, v);
    }
  }

  // ---- streaming (Web API) ----

  // The bytes of a Response that may hold a module: Content-Type
  // application/wasm, CORS-same-origin, status ok, body not used.
  function responseBytes(response) {
    if (!internal.isResponse(response))
      throw new TypeError("WebAssembly: the argument must be a Response or a promise of one");
    const record = internal.responseRecord(response);
    let mimeType = null;
    for (let index = 0; index < record.headers.length; index++)
      if (toLowerCase.call(record.headers[index][0]) === "content-type")
        mimeType = mimeType === null ? record.headers[index][1] : mimeType + ", " + record.headers[index][1];
    if (mimeType === null)
      throw new TypeError("WebAssembly: the response has no Content-Type (application/wasm is required)");
    mimeType = mimeType.replace(/^[\t ]+|[\t ]+$/g, "");
    if (toLowerCase.call(mimeType) !== "application/wasm")
      throw new TypeError("WebAssembly: the response's Content-Type is " + JSON.stringify(mimeType) +
        ", not application/wasm");
    if (record.type !== "basic" && record.type !== "cors" && record.type !== "default")
      throw new TypeError("WebAssembly: the response is not CORS-same-origin");
    if (record.status < 200 || record.status > 299)
      throw new TypeError("WebAssembly: the response's status is " + record.status);
    if (internal.bodyUnusable(response))
      throw new TypeError("WebAssembly: the response's body was already used");
    return internal.readBodyBytes(response);
  }

  function compileResponse(source, options) {
    return then(promiseResolve(source), function (response) {
      return then(responseBytes(response), function (bytes) {
        return compileLater(bytes, options);
      });
    });
  }

  // ---- the namespace ----

  const namespace = {
    validate(bytes, options = undefined) {
      requireArguments(arguments.length, 1, "WebAssembly.validate");
      if (options === undefined) return natives.wasmValidate(bytes);
      const copy = natives.wasmCopyBytes(bytes);
      const compileOptionsValue = compileOptions(options, "WebAssembly.validate");
      if (!natives.wasmValidate(copy)) return false;
      try {
        compileWith(copy, compileOptionsValue, Module.prototype);
        return true;
      } catch (error) {
        if (error instanceof CompileError) return false;
        throw error;
      }
    },
    compile(bytes, options = undefined) {
      try {
        requireArguments(arguments.length, 1, "WebAssembly.compile");
        const copy = natives.wasmCopyBytes(bytes);
        return compileLater(copy, compileOptions(options, "WebAssembly.compile"));
      } catch (error) {
        return rejected(error);
      }
    },
    instantiate(source, importObject = undefined, options = undefined) {
      try {
        requireArguments(arguments.length, 1, "WebAssembly.instantiate");
        if (natives.wasmIsModule(source))
          return instantiateLater(source, optionalObject(importObject, "WebAssembly.instantiate"));
        const bytes = natives.wasmCopyBytes(source);
        const imports = optionalObject(importObject, "WebAssembly.instantiate");
        return instantiateCompiled(compileLater(bytes, compileOptions(options, "WebAssembly.instantiate")), imports);
      } catch (error) {
        return rejected(error);
      }
    },
    compileStreaming(source, options = undefined) {
      try {
        requireArguments(arguments.length, 1, "WebAssembly.compileStreaming");
        return compileResponse(source, compileOptions(options, "WebAssembly.compileStreaming"));
      } catch (error) {
        return rejected(error);
      }
    },
    instantiateStreaming(source, importObject = undefined, options = undefined) {
      try {
        requireArguments(arguments.length, 1, "WebAssembly.instantiateStreaming");
        const imports = optionalObject(importObject, "WebAssembly.instantiateStreaming");
        const compileOptionsValue = compileOptions(options, "WebAssembly.instantiateStreaming");
        return instantiateCompiled(compileResponse(source, compileOptionsValue), imports);
      } catch (error) {
        return rejected(error);
      }
    }
  };
  defineProperty(namespace, Symbol.toStringTag, { value: "WebAssembly", configurable: true });

  // WebIDL interfaces in a namespace: operations and attributes enumerable,
  // a toStringTag naming the interface.
  function finish(Class, name) {
    for (const target of [Class, Class.prototype])
      for (const key of getOwnPropertyNames(target)) {
        if (key === "constructor") continue;
        if (target === Class && (key === "prototype" || key === "length" || key === "name")) continue;
        const descriptor = getOwnPropertyDescriptor(target, key);
        descriptor.enumerable = true;
        defineProperty(target, key, descriptor);
      }
    defineProperty(Class.prototype, Symbol.toStringTag, { value: "WebAssembly." + name, configurable: true });
    internal.define(namespace, name, Class);
  }
  finish(Module, "Module");
  finish(Instance, "Instance");
  finish(Memory, "Memory");
  finish(Table, "Table");
  finish(Global, "Global");
  internal.define(namespace, "CompileError", CompileError);
  internal.define(namespace, "LinkError", LinkError);
  internal.define(namespace, "RuntimeError", RuntimeError);
  internal.define(global, "WebAssembly", namespace);

  // The prototypes and errors of this realm's objects; the Tag and
  // Exception prototypes come with 58-webassembly-exceptions.js, which
  // gets what it shares with this script here.
  natives.wasmRegister(Module.prototype, Memory.prototype, Table.prototype, Global.prototype, undefined, undefined,
    CompileError, LinkError, RuntimeError);
  internal.webassembly = {
    namespace: namespace, finish: finish, requireArguments: requireArguments, dictionary: dictionary,
    requiredMember: requiredMember, member: member, prototypeFrom: prototypeFrom, enforceRange: enforceRange,
    valueTypes: valueTypes
  };

  // structuredClone and postMessage within the agent: a new Module object of
  // the same compiled module (and compile options).
  let moduleClones = 0;
  if (internal.cloneHooks === undefined) internal.cloneHooks = [];
  internal.cloneHooks.push(function (value) {
    if (!natives.wasmIsModule(value)) return undefined;
    moduleClones++;
    const made = natives.wasmCloneModule(value);
    if (optionsOf(value) !== noOptions) weakSet.call(moduleOptions, made, optionsOf(value));
    return made;
  });
  // Compile options for a Module of this realm made by another realm's
  // adoptModules (on the natives object, which that realm has).
  natives.wasmAdoptOptions = function (module, options) {
    weakSet.call(moduleOptions, module, options);
  };
  // How many Modules were cloned so far (a message for a worker that has
  // some is adopted into the worker's realm before it is delivered).
  internal.wasmModuleClones = function () {
    return moduleClones;
  };
  // A cloned value (the window's structured clone made it) given to the
  // realm of RealmNatives (a worker's scope, natives.wasmInstall): its
  // Module objects made again there, so they are that realm's Modules.
  internal.adoptModules = function (value, realmNatives) {
    const memory = new Map();
    function adopt(item) {
      if (item === null || typeof item !== "object") return item;
      if (memory.has(item)) return memory.get(item);
      if (natives.wasmIsModule(item)) {
        const made = realmNatives.wasmCloneModule(item);
        if (optionsOf(item) !== noOptions) realmNatives.wasmAdoptOptions(made, optionsOf(item));
        memory.set(item, made);
        return made;
      }
      memory.set(item, item);
      if (item instanceof Map) {
        for (const [key, entry] of Array.from(item)) {
          const newKey = adopt(key);
          if (newKey !== key) item.delete(key);
          item.set(newKey, adopt(entry));
        }
      } else if (item instanceof Set) {
        for (const entry of Array.from(item)) {
          const newEntry = adopt(entry);
          if (newEntry !== entry) {
            item.delete(entry);
            item.add(newEntry);
          }
        }
      } else if (Array.isArray(item) || Object.getPrototypeOf(item) === Object.prototype) {
        for (const key of Object.keys(item)) item[key] = adopt(item[key]);
      }
      return item;
    }
    return adopt(value);
  };
})
