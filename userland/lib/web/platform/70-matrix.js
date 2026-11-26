// Geometry Interfaces Module Level 1, section 6: DOMMatrixReadOnly and
// DOMMatrix (with the legacy alias WebKitCSSMatrix): 4x4 matrices with
// their is2D flag, made from a sequence of 6 or 16 numbers, a CSS
// transform list (matrix, matrix3d, translate*, scale*, rotate*, skew*;
// absolute lengths and angles), another matrix or a typed array; the
// immutable operations returning new matrices, the *Self ones changing
// the matrix, inverse, transformPoint, the typed array, JSON and string
// forms. A canvas context's getTransform returns one.
(function (natives, global, internal) {
  "use strict";
  const matrixData = new WeakMap();
  const names = ["m11", "m12", "m13", "m14", "m21", "m22", "m23", "m24", "m31", "m32", "m33", "m34",
    "m41", "m42", "m43", "m44"];
  const identity = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1];

  // Values are kept column by column: m11 m12 m13 m14 m21 ... m44, so
  // index (4 * column + row) for the column-vector form.
  function state(matrix) {
    const data = matrixData.get(matrix);
    if (data === undefined) throw new TypeError("Illegal invocation");
    return data;
  }

  function multiplyValues(a, b) {
    const result = new Array(16);
    for (let column = 0; column < 4; column++)
      for (let row = 0; row < 4; row++) {
        let sum = 0;
        for (let k = 0; k < 4; k++) sum += a[4 * k + row] * b[4 * column + k];
        result[4 * column + row] = sum;
      }
    return result;
  }

  function sameValueZero(x, y) {
    return x === y || (x !== x && y !== y);
  }

  // "Validate and fixup" a DOMMatrixInit (2D only when is2D says so).
  function fixup(init) {
    const source = init === undefined || init === null ? {} : init;
    if (typeof source !== "object" && typeof source !== "function")
      throw new TypeError("The matrix init is not an object.");
    const pairs = [["a", "m11", 1], ["b", "m12", 0], ["c", "m21", 0], ["d", "m22", 1], ["e", "m41", 0],
      ["f", "m42", 0]];
    const values = identity.slice();
    const read = {};
    for (const name of ["a", "b", "c", "d", "e", "f"].concat(names))
      if (source[name] !== undefined) read[name] = Number(source[name]);
    for (const [short, long, fallback] of pairs) {
      if (short in read && long in read && !sameValueZero(read[short], read[long]))
        throw new TypeError("The matrix members " + short + " and " + long + " do not match.");
      const value = long in read ? read[long] : short in read ? read[short] : fallback;
      values[names.indexOf(long)] = value;
    }
    const threeD = ["m13", "m14", "m23", "m24", "m31", "m32", "m34", "m43"];
    for (const name of threeD.concat(["m33", "m44"]))
      if (name in read) values[names.indexOf(name)] = read[name];
    const flat = threeD.every(function (name) { return !(name in read) || read[name] === 0; }) &&
      (!("m33" in read) || read.m33 === 1) && (!("m44" in read) || read.m44 === 1);
    let is2D = flat;
    if (source.is2D !== undefined) {
      if (source.is2D && !flat) throw new TypeError("A 2D matrix cannot have 3D members.");
      is2D = Boolean(source.is2D);
    }
    return { values: values, is2D: is2D };
  }

  // CSS transform lists ("none", "translate(10px, 5px) rotate(45deg)").
  function parseTransformList(text) {
    const source = String(text).trim();
    if (source === "" || source.toLowerCase() === "none") return { values: identity.slice(), is2D: true };
    let values = identity.slice();
    let is2D = true;
    const pattern = /\s*([a-zA-Z0-9]+)\(([^()]*)\)\s*/y;
    let position = 0;
    while (position < source.length) {
      pattern.lastIndex = position;
      const match = pattern.exec(source);
      if (match === null) throw internal.domException("Failed to parse '" + source + "'.", "SyntaxError");
      position = pattern.lastIndex;
      const name = match[1].toLowerCase();
      const parts = match[2].trim() === "" ? [] : match[2].split(/\s*,\s*|\s+/);
      const step = transformFunction(name, parts, source);
      if (!step.is2D) is2D = false;
      values = multiplyValues(values, step.values);
    }
    return { values: values, is2D: is2D };
  }

  function lengthValue(text, source) {
    const match = /^([+-]?(?:\d+\.?\d*|\.\d+)(?:e[+-]?\d+)?)(px|cm|mm|q|in|pt|pc)?$/i.exec(text);
    if (match === null || (match[2] === undefined && Number(match[1]) !== 0))
      throw internal.domException("Failed to parse '" + source + "'.", "SyntaxError");
    const factors = { px: 1, cm: 96 / 2.54, mm: 96 / 25.4, q: 96 / 101.6, in: 96, pt: 4 / 3, pc: 16 };
    return Number(match[1]) * (match[2] === undefined ? 1 : factors[match[2].toLowerCase()]);
  }

  function angleValue(text, source) {
    const match = /^([+-]?(?:\d+\.?\d*|\.\d+)(?:e[+-]?\d+)?)(deg|rad|grad|turn)?$/i.exec(text);
    if (match === null || (match[2] === undefined && Number(match[1]) !== 0))
      throw internal.domException("Failed to parse '" + source + "'.", "SyntaxError");
    const unit = match[2] === undefined ? "deg" : match[2].toLowerCase();
    const factors = { deg: 1, rad: 180 / Math.PI, grad: 0.9, turn: 360 };
    return Number(match[1]) * factors[unit];
  }

  function numberValue(text, source) {
    if (!/^[+-]?(?:\d+\.?\d*|\.\d+)(?:e[+-]?\d+)?$/i.test(text))
      throw internal.domException("Failed to parse '" + source + "'.", "SyntaxError");
    return Number(text);
  }

  function rotationValues(x, y, z, degrees) {
    const length = Math.sqrt(x * x + y * y + z * z);
    if (length === 0) return identity.slice();
    x /= length; y /= length; z /= length;
    const angle = degrees * Math.PI / 180;
    const sc = Math.sin(angle / 2) * Math.cos(angle / 2);
    const sq = Math.sin(angle / 2) * Math.sin(angle / 2);
    return [1 - 2 * (y * y + z * z) * sq, 2 * (x * y * sq + z * sc), 2 * (x * z * sq - y * sc), 0,
      2 * (x * y * sq - z * sc), 1 - 2 * (x * x + z * z) * sq, 2 * (y * z * sq + x * sc), 0,
      2 * (x * z * sq + y * sc), 2 * (y * z * sq - x * sc), 1 - 2 * (x * x + y * y) * sq, 0,
      0, 0, 0, 1];
  }

  function translation(x, y, z) {
    return [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, x, y, z, 1];
  }

  function scaling(x, y, z) {
    return [x, 0, 0, 0, 0, y, 0, 0, 0, 0, z, 0, 0, 0, 0, 1];
  }

  function skewing(xDegrees, yDegrees) {
    return [1, Math.tan(yDegrees * Math.PI / 180), 0, 0, Math.tan(xDegrees * Math.PI / 180), 1, 0, 0,
      0, 0, 1, 0, 0, 0, 0, 1];
  }

  function transformFunction(name, parts, source) {
    const count = parts.length;
    function need(min, max) {
      if (count < min || count > max) throw internal.domException("Failed to parse '" + source + "'.", "SyntaxError");
    }
    switch (name) {
      case "matrix": {
        need(6, 6);
        const n = parts.map(function (part) { return numberValue(part, source); });
        return { values: [n[0], n[1], 0, 0, n[2], n[3], 0, 0, 0, 0, 1, 0, n[4], n[5], 0, 1], is2D: true };
      }
      case "matrix3d":
        need(16, 16);
        return { values: parts.map(function (part) { return numberValue(part, source); }), is2D: false };
      case "translate":
        need(1, 2);
        return { values: translation(lengthValue(parts[0], source), count > 1 ? lengthValue(parts[1], source) : 0, 0),
          is2D: true };
      case "translatex": need(1, 1); return { values: translation(lengthValue(parts[0], source), 0, 0), is2D: true };
      case "translatey": need(1, 1); return { values: translation(0, lengthValue(parts[0], source), 0), is2D: true };
      case "translatez": need(1, 1); return { values: translation(0, 0, lengthValue(parts[0], source)), is2D: false };
      case "translate3d":
        need(3, 3);
        return { values: translation(lengthValue(parts[0], source), lengthValue(parts[1], source),
          lengthValue(parts[2], source)), is2D: false };
      case "scale": {
        need(1, 2);
        const x = numberValue(parts[0], source);
        return { values: scaling(x, count > 1 ? numberValue(parts[1], source) : x, 1), is2D: true };
      }
      case "scalex": need(1, 1); return { values: scaling(numberValue(parts[0], source), 1, 1), is2D: true };
      case "scaley": need(1, 1); return { values: scaling(1, numberValue(parts[0], source), 1), is2D: true };
      case "scalez": need(1, 1); return { values: scaling(1, 1, numberValue(parts[0], source)), is2D: false };
      case "scale3d":
        need(3, 3);
        return { values: scaling(numberValue(parts[0], source), numberValue(parts[1], source),
          numberValue(parts[2], source)), is2D: false };
      case "rotate": case "rotatez":
        need(1, 1);
        return { values: rotationValues(0, 0, 1, angleValue(parts[0], source)), is2D: name === "rotate" };
      case "rotatex": need(1, 1); return { values: rotationValues(1, 0, 0, angleValue(parts[0], source)), is2D: false };
      case "rotatey": need(1, 1); return { values: rotationValues(0, 1, 0, angleValue(parts[0], source)), is2D: false };
      case "rotate3d":
        need(4, 4);
        return { values: rotationValues(numberValue(parts[0], source), numberValue(parts[1], source),
          numberValue(parts[2], source), angleValue(parts[3], source)), is2D: false };
      case "skew":
        need(1, 2);
        return { values: skewing(angleValue(parts[0], source), count > 1 ? angleValue(parts[1], source) : 0), is2D: true };
      case "skewx": need(1, 1); return { values: skewing(angleValue(parts[0], source), 0), is2D: true };
      case "skewy": need(1, 1); return { values: skewing(0, angleValue(parts[0], source)), is2D: true };
      case "perspective": {
        need(1, 1);
        const distance = lengthValue(parts[0], source);
        const values = identity.slice();
        if (distance !== 0) values[11] = -1 / distance;
        return { values: values, is2D: false };
      }
    }
    throw internal.domException("Failed to parse '" + source + "'.", "SyntaxError");
  }

  function create(Class, values, is2D) {
    const matrix = Object.create(Class.prototype);
    matrixData.set(matrix, { values: values, is2D: is2D });
    return matrix;
  }

  function fromSequence(sequence) {
    const numbers = Array.from(sequence, Number);
    if (numbers.length === 6)
      return { values: [numbers[0], numbers[1], 0, 0, numbers[2], numbers[3], 0, 0, 0, 0, 1, 0, numbers[4],
        numbers[5], 0, 1], is2D: true };
    if (numbers.length === 16) return { values: numbers, is2D: false };
    throw new TypeError("The sequence must contain 6 or 16 numbers.");
  }

  function inverseOf(data) {
    const m = data.values;
    const inv = new Array(16);
    inv[0] = m[5] * m[10] * m[15] - m[5] * m[11] * m[14] - m[9] * m[6] * m[15] + m[9] * m[7] * m[14] +
      m[13] * m[6] * m[11] - m[13] * m[7] * m[10];
    inv[4] = -m[4] * m[10] * m[15] + m[4] * m[11] * m[14] + m[8] * m[6] * m[15] - m[8] * m[7] * m[14] -
      m[12] * m[6] * m[11] + m[12] * m[7] * m[10];
    inv[8] = m[4] * m[9] * m[15] - m[4] * m[11] * m[13] - m[8] * m[5] * m[15] + m[8] * m[7] * m[13] +
      m[12] * m[5] * m[11] - m[12] * m[7] * m[9];
    inv[12] = -m[4] * m[9] * m[14] + m[4] * m[10] * m[13] + m[8] * m[5] * m[14] - m[8] * m[6] * m[13] -
      m[12] * m[5] * m[10] + m[12] * m[6] * m[9];
    inv[1] = -m[1] * m[10] * m[15] + m[1] * m[11] * m[14] + m[9] * m[2] * m[15] - m[9] * m[3] * m[14] -
      m[13] * m[2] * m[11] + m[13] * m[3] * m[10];
    inv[5] = m[0] * m[10] * m[15] - m[0] * m[11] * m[14] - m[8] * m[2] * m[15] + m[8] * m[3] * m[14] +
      m[12] * m[2] * m[11] - m[12] * m[3] * m[10];
    inv[9] = -m[0] * m[9] * m[15] + m[0] * m[11] * m[13] + m[8] * m[1] * m[15] - m[8] * m[3] * m[13] -
      m[12] * m[1] * m[11] + m[12] * m[3] * m[9];
    inv[13] = m[0] * m[9] * m[14] - m[0] * m[10] * m[13] - m[8] * m[1] * m[14] + m[8] * m[2] * m[13] +
      m[12] * m[1] * m[10] - m[12] * m[2] * m[9];
    inv[2] = m[1] * m[6] * m[15] - m[1] * m[7] * m[14] - m[5] * m[2] * m[15] + m[5] * m[3] * m[14] +
      m[13] * m[2] * m[7] - m[13] * m[3] * m[6];
    inv[6] = -m[0] * m[6] * m[15] + m[0] * m[7] * m[14] + m[4] * m[2] * m[15] - m[4] * m[3] * m[14] -
      m[12] * m[2] * m[7] + m[12] * m[3] * m[6];
    inv[10] = m[0] * m[5] * m[15] - m[0] * m[7] * m[13] - m[4] * m[1] * m[15] + m[4] * m[3] * m[13] +
      m[12] * m[1] * m[7] - m[12] * m[3] * m[5];
    inv[14] = -m[0] * m[5] * m[14] + m[0] * m[6] * m[13] + m[4] * m[1] * m[14] - m[4] * m[2] * m[13] -
      m[12] * m[1] * m[6] + m[12] * m[2] * m[5];
    inv[3] = -m[1] * m[6] * m[11] + m[1] * m[7] * m[10] + m[5] * m[2] * m[11] - m[5] * m[3] * m[10] -
      m[9] * m[2] * m[7] + m[9] * m[3] * m[6];
    inv[7] = m[0] * m[6] * m[11] - m[0] * m[7] * m[10] - m[4] * m[2] * m[11] + m[4] * m[3] * m[10] +
      m[8] * m[2] * m[7] - m[8] * m[3] * m[6];
    inv[11] = -m[0] * m[5] * m[11] + m[0] * m[7] * m[9] + m[4] * m[1] * m[11] - m[4] * m[3] * m[9] -
      m[8] * m[1] * m[7] + m[8] * m[3] * m[5];
    inv[15] = m[0] * m[5] * m[10] - m[0] * m[6] * m[9] - m[4] * m[1] * m[10] + m[4] * m[2] * m[9] +
      m[8] * m[1] * m[6] - m[8] * m[2] * m[5];
    const determinant = m[0] * inv[0] + m[1] * inv[4] + m[2] * inv[8] + m[3] * inv[12];
    if (determinant === 0 || !Number.isFinite(determinant))
      return { values: new Array(16).fill(NaN), is2D: false };
    return { values: inv.map(function (value) { return value / determinant; }), is2D: data.is2D };
  }

  // The *Self operations on a state; the immutable ones run them on a copy.
  const operations = {
    multiply(data, other) {
      const init = fixup(other);
      data.values = multiplyValues(data.values, init.values);
      data.is2D = data.is2D && init.is2D;
    },
    preMultiply(data, other) {
      const init = fixup(other);
      data.values = multiplyValues(init.values, data.values);
      data.is2D = data.is2D && init.is2D;
    },
    translate(data, tx, ty, tz) {
      tx = Number(tx === undefined ? 0 : tx);
      ty = Number(ty === undefined ? 0 : ty);
      tz = Number(tz === undefined ? 0 : tz);
      data.values = multiplyValues(data.values, translation(tx, ty, tz));
      if (tz !== 0) data.is2D = false;
    },
    scale(data, sx, sy, sz, ox, oy, oz) {
      sx = Number(sx === undefined ? 1 : sx);
      sy = sy === undefined ? sx : Number(sy);
      sz = Number(sz === undefined ? 1 : sz);
      ox = Number(ox === undefined ? 0 : ox);
      oy = Number(oy === undefined ? 0 : oy);
      oz = Number(oz === undefined ? 0 : oz);
      let values = multiplyValues(data.values, translation(ox, oy, oz));
      values = multiplyValues(values, scaling(sx, sy, sz));
      data.values = multiplyValues(values, translation(-ox, -oy, -oz));
      if (sz !== 1 || oz !== 0) data.is2D = false;
    },
    scale3d(data, scale, ox, oy, oz) {
      scale = Number(scale === undefined ? 1 : scale);
      operations.scale(data, scale, scale, scale, ox, oy, oz);
    },
    rotate(data, rx, ry, rz) {
      rx = Number(rx === undefined ? 0 : rx);
      if (ry === undefined && rz === undefined) {
        rz = rx;
        rx = 0;
        ry = 0;
      }
      ry = Number(ry === undefined ? 0 : ry);
      rz = Number(rz === undefined ? 0 : rz);
      if (rx !== 0 || ry !== 0) data.is2D = false;
      data.values = multiplyValues(data.values, rotationValues(0, 0, 1, rz));
      data.values = multiplyValues(data.values, rotationValues(0, 1, 0, ry));
      data.values = multiplyValues(data.values, rotationValues(1, 0, 0, rx));
    },
    rotateFromVector(data, x, y) {
      x = Number(x === undefined ? 0 : x);
      y = Number(y === undefined ? 0 : y);
      const angle = x === 0 && y === 0 ? 0 : Math.atan2(y, x) * 180 / Math.PI;
      data.values = multiplyValues(data.values, rotationValues(0, 0, 1, angle));
    },
    rotateAxisAngle(data, x, y, z, angle) {
      x = Number(x === undefined ? 0 : x);
      y = Number(y === undefined ? 0 : y);
      z = Number(z === undefined ? 0 : z);
      angle = Number(angle === undefined ? 0 : angle);
      data.values = multiplyValues(data.values, rotationValues(x, y, z, angle));
      if (x !== 0 || y !== 0) data.is2D = false;
    },
    skewX(data, sx) {
      data.values = multiplyValues(data.values, skewing(Number(sx === undefined ? 0 : sx), 0));
    },
    skewY(data, sy) {
      data.values = multiplyValues(data.values, skewing(0, Number(sy === undefined ? 0 : sy)));
    },
    invert(data) {
      const inverse = inverseOf(data);
      data.values = inverse.values;
      data.is2D = inverse.is2D;
    }
  };

  class DOMMatrixReadOnly {
    constructor(init) {
      let data;
      if (init === undefined) data = { values: identity.slice(), is2D: true };
      else if (typeof init === "string") data = parseTransformList(init);
      else if (init !== null && typeof init === "object" && Symbol.iterator in init) data = fromSequence(init);
      else throw new TypeError("Failed to construct 'DOMMatrix': The provided value is not a string or a sequence.");
      matrixData.set(this, data);
    }
    static fromMatrix(other) {
      const init = fixup(other);
      return create(this, init.values, init.is2D);
    }
    static fromFloat32Array(array) {
      if (!(array instanceof Float32Array)) throw new TypeError("The argument is not a Float32Array.");
      const data = fromSequence(array);
      return create(this, data.values, data.is2D);
    }
    static fromFloat64Array(array) {
      if (!(array instanceof Float64Array)) throw new TypeError("The argument is not a Float64Array.");
      const data = fromSequence(array);
      return create(this, data.values, data.is2D);
    }
    get a() { return state(this).values[0]; }
    get b() { return state(this).values[1]; }
    get c() { return state(this).values[4]; }
    get d() { return state(this).values[5]; }
    get e() { return state(this).values[12]; }
    get f() { return state(this).values[13]; }
    get is2D() { return state(this).is2D; }
    get isIdentity() {
      const values = state(this).values;
      return values.every(function (value, index) { return value === identity[index]; });
    }
    translate(tx, ty, tz) { return derived(this, "translate", arguments); }
    scale(sx, sy, sz, ox, oy, oz) { return derived(this, "scale", arguments); }
    scaleNonUniform(sx, sy) {
      return derived(this, "scale", [sx === undefined ? 1 : sx, sy === undefined ? 1 : sy, 1, 0, 0, 0]);
    }
    scale3d(scale, ox, oy, oz) { return derived(this, "scale3d", arguments); }
    rotate(rx, ry, rz) { return derived(this, "rotate", arguments); }
    rotateFromVector(x, y) { return derived(this, "rotateFromVector", arguments); }
    rotateAxisAngle(x, y, z, angle) { return derived(this, "rotateAxisAngle", arguments); }
    skewX(sx) { return derived(this, "skewX", arguments); }
    skewY(sy) { return derived(this, "skewY", arguments); }
    multiply(other) { return derived(this, "multiply", arguments); }
    flipX() { return derived(this, "multiply", [{ a: -1 }]); }
    flipY() { return derived(this, "multiply", [{ d: -1 }]); }
    inverse() { return derived(this, "invert", []); }
    transformPoint(point) {
      const source = point === undefined || point === null ? {} : point;
      const x = Number(source.x === undefined ? 0 : source.x);
      const y = Number(source.y === undefined ? 0 : source.y);
      const z = Number(source.z === undefined ? 0 : source.z);
      const w = Number(source.w === undefined ? 1 : source.w);
      const m = state(this).values;
      return new global.DOMPoint(m[0] * x + m[4] * y + m[8] * z + m[12] * w, m[1] * x + m[5] * y + m[9] * z + m[13] * w,
        m[2] * x + m[6] * y + m[10] * z + m[14] * w, m[3] * x + m[7] * y + m[11] * z + m[15] * w);
    }
    toFloat32Array() { return new Float32Array(state(this).values); }
    toFloat64Array() { return new Float64Array(state(this).values); }
    toJSON() {
      const data = state(this);
      const result = { a: this.a, b: this.b, c: this.c, d: this.d, e: this.e, f: this.f };
      names.forEach(function (name, index) { result[name] = data.values[index]; });
      result.is2D = data.is2D;
      result.isIdentity = this.isIdentity;
      return result;
    }
    toString() {
      const data = state(this);
      if (!data.values.every(Number.isFinite))
        throw internal.domException("Cannot serialize a matrix with non-finite values.", "InvalidStateError");
      if (data.is2D)
        return "matrix(" + [this.a, this.b, this.c, this.d, this.e, this.f].map(String).join(", ") + ")";
      return "matrix3d(" + data.values.map(String).join(", ") + ")";
    }
  }
  names.forEach(function (name, index) {
    Object.defineProperty(DOMMatrixReadOnly.prototype, name, {
      configurable: true, enumerable: true, get: function () { return state(this).values[index]; } });
  });

  function derived(matrix, operation, args) {
    const data = state(matrix);
    const copy = { values: data.values.slice(), is2D: data.is2D };
    operations[operation].apply(null, [copy].concat(Array.prototype.slice.call(args)));
    return create(global.DOMMatrix, copy.values, copy.is2D);
  }

  class DOMMatrix extends DOMMatrixReadOnly {
    multiplySelf(other) { operations.multiply(state(this), other); return this; }
    preMultiplySelf(other) { operations.preMultiply(state(this), other); return this; }
    translateSelf(tx, ty, tz) { operations.translate(state(this), tx, ty, tz); return this; }
    scaleSelf(sx, sy, sz, ox, oy, oz) { operations.scale(state(this), sx, sy, sz, ox, oy, oz); return this; }
    scale3dSelf(scale, ox, oy, oz) { operations.scale3d(state(this), scale, ox, oy, oz); return this; }
    rotateSelf(rx, ry, rz) { operations.rotate.apply(null, [state(this)].concat(Array.prototype.slice.call(arguments))); return this; }
    rotateFromVectorSelf(x, y) { operations.rotateFromVector(state(this), x, y); return this; }
    rotateAxisAngleSelf(x, y, z, angle) { operations.rotateAxisAngle(state(this), x, y, z, angle); return this; }
    skewXSelf(sx) { operations.skewX(state(this), sx); return this; }
    skewYSelf(sy) { operations.skewY(state(this), sy); return this; }
    invertSelf() { operations.invert(state(this)); return this; }
    setMatrixValue(text) {
      const parsed = parseTransformList(text);
      const data = state(this);
      data.values = parsed.values;
      data.is2D = parsed.is2D;
      return this;
    }
  }
  const twoD = { a: 0, b: 1, c: 4, d: 5, e: 12, f: 13 };
  Object.keys(twoD).forEach(function (name) {
    Object.defineProperty(DOMMatrix.prototype, name, {
      configurable: true, enumerable: true,
      get: function () { return state(this).values[twoD[name]]; },
      set: function (value) { state(this).values[twoD[name]] = Number(value); } });
  });
  names.forEach(function (name, index) {
    const flat = ["m13", "m14", "m23", "m24", "m31", "m32", "m34", "m43"].indexOf(name) >= 0;
    const unit = name === "m33" || name === "m44";
    Object.defineProperty(DOMMatrix.prototype, name, {
      configurable: true, enumerable: true,
      get: function () { return state(this).values[index]; },
      set: function (value) {
        const data = state(this);
        data.values[index] = Number(value);
        if ((flat && data.values[index] !== 0) || (unit && data.values[index] !== 1)) data.is2D = false;
      } });
  });
  internal.finishInterface(DOMMatrixReadOnly, "DOMMatrixReadOnly");
  internal.finishInterface(DOMMatrix, "DOMMatrix");
  // WebIDL [LegacyWindowAlias=(SVGMatrix, WebKitCSSMatrix)]: the same interface object.
  Object.defineProperty(global, "WebKitCSSMatrix", { configurable: true, writable: true, value: DOMMatrix });
  Object.defineProperty(global, "SVGMatrix", { configurable: true, writable: true, value: DOMMatrix });
})
