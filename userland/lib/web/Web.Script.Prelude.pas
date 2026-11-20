{
  FreePascalOS
  Copyright (C) 2026 Brandon Scott

  This program is free software: you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation, either version 3 of the License, or
  (at your option) any later version.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with this program.  If not, see <https://www.gnu.org/licenses/>.
}

{
  Parts of the window written in JavaScript, where that is simplest and
  speed does not matter: structuredClone's serialization and
  deserialization in one walk (HTML Standard 2.7: primitives, plain
  objects and arrays, Boolean, Number, String and BigInt objects, Date,
  RegExp, Map, Set and errors, with cycles; anything else, platform
  objects included, is a DataCloneError).
}
unit Web.Script.Prelude;

{$mode objfpc}
{$H+}

interface

const
  StructuredCloneSource =
    '(function () {' + LineEnding +
    '  "use strict";' + LineEnding +
    '  const toString = Object.prototype.toString;' + LineEnding +
    '  function refuse(what) {' + LineEnding +
    '    throw new DOMException(what + " cannot be cloned", "DataCloneError");' + LineEnding +
    '  }' + LineEnding +
    '  function properties(source, copy, memory) {' + LineEnding +
    '    for (const key of Object.keys(source)) copy[key] = clone(source[key], memory);' + LineEnding +
    '    return copy;' + LineEnding +
    '  }' + LineEnding +
    '  function clone(value, memory) {' + LineEnding +
    '    if (typeof value === "symbol") refuse("a symbol");' + LineEnding +
    '    if (typeof value === "function") refuse("a function");' + LineEnding +
    '    if (typeof value !== "object" || value === null) return value;' + LineEnding +
    '    if (memory.has(value)) return memory.get(value);' + LineEnding +
    '    let copy;' + LineEnding +
    '    if (Array.isArray(value)) {' + LineEnding +
    '      copy = new Array(value.length);' + LineEnding +
    '      memory.set(value, copy);' + LineEnding +
    '      return properties(value, copy, memory);' + LineEnding +
    '    }' + LineEnding +
    '    const tag = toString.call(value);' + LineEnding +
    '    switch (tag) {' + LineEnding +
    '      case "[object Boolean]": copy = new Boolean(value.valueOf()); break;' + LineEnding +
    '      case "[object Number]": copy = new Number(value.valueOf()); break;' + LineEnding +
    '      case "[object String]": copy = new String(value.valueOf()); break;' + LineEnding +
    '      case "[object BigInt]": copy = Object(value.valueOf()); break;' + LineEnding +
    '      case "[object Date]": copy = new Date(value.getTime()); break;' + LineEnding +
    '      case "[object RegExp]": copy = new RegExp(value.source, value.flags); break;' + LineEnding +
    '      case "[object Map]":' + LineEnding +
    '        copy = new Map();' + LineEnding +
    '        memory.set(value, copy);' + LineEnding +
    '        for (const [key, item] of value) copy.set(clone(key, memory), clone(item, memory));' + LineEnding +
    '        return copy;' + LineEnding +
    '      case "[object Set]":' + LineEnding +
    '        copy = new Set();' + LineEnding +
    '        memory.set(value, copy);' + LineEnding +
    '        for (const item of value) copy.add(clone(item, memory));' + LineEnding +
    '        return copy;' + LineEnding +
    '      case "[object Error]":' + LineEnding +
    '        copy = new Error(String(value.message));' + LineEnding +
    '        if (typeof value.name === "string") copy.name = value.name;' + LineEnding +
    '        break;' + LineEnding +
    '      case "[object Object]":' + LineEnding +
    '        copy = {};' + LineEnding +
    '        memory.set(value, copy);' + LineEnding +
    '        return properties(value, copy, memory);' + LineEnding +
    '      default:' + LineEnding +
    '        refuse(tag.slice(8, -1));' + LineEnding +
    '    }' + LineEnding +
    '    memory.set(value, copy);' + LineEnding +
    '    return copy;' + LineEnding +
    '  }' + LineEnding +
    '  return function structuredClone(value) { return clone(value, new Map()); };' + LineEnding +
    '})()';

implementation

end.
