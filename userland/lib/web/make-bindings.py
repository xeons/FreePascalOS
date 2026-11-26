#!/usr/bin/env python3
# FreePascalOS
# Copyright (C) 2026 Brandon Scott
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

"""Writes libweb's script binding tables (at build time) from the WebIDL
files in userland/lib/web/bindings:

    Web.Bindings.Ids.inc            interface ids, dictionary member and
                                    enum value indexes (constants)
    Web.Bindings.Tables.inc         the tables Web.Bindings.Tables installs:
                                    types, arguments, overloads, members,
                                    interfaces, dictionaries, enums, the
                                    HTML element interfaces by local name
    Web.Bindings.<File>.Members.inc the implementation routines File.webidl
                                    needs, declared for Web.Bindings.<File>

A routine is named after the interface (or mixin) that declares the
member: Node_appendChild, Node_get_firstChild, Node_set_textContent,
Event_constructor, DOMStringMap_namedGetter, URLSearchParams_pairAt,
URLSearchParams_stringifier. [Reflect] attributes and EventHandler
attributes have none (the dispatcher handles them).

The WebIDL understood: interfaces (with inheritance, partial, mixins and
includes), namespaces, dictionaries (with inheritance), enums, callbacks,
callback interfaces, typedefs; constants, attributes (readonly, static,
stringifier), operations (static, getter/setter/deleter, overloads,
optional arguments with defaults, variadic arguments), constructors,
iterable<V> and iterable<K, V>, stringifier; types with nullable, union,
sequence, FrozenArray, record and Promise forms. Extended attributes
used: Global, Exposed (ignored), LegacyUnforgeable, Replaceable,
SameObject, NewObject, PutForwards, LegacyNullToEmptyString, Clamp,
EnforceRange, LegacyTreatNonObjectAsNull, LegacyUnenumerableNamedProperties,
LegacyOverrideBuiltIns, LegacyWindowAlias, ExceptionLike, and the
extensions LocalNames, Reflect, ReflectURL, ReflectDefault,
ReflectPositive, ReflectEnum, ReflectMissing, ReflectInvalid.

    python3 userland/lib/web/make-bindings.py <output directory>
"""

import os
import re
import sys

BINDINGS_DIRECTORY = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'bindings')

TOKEN_PATTERN = re.compile(r'''
    (?P<space>\s+|//[^\n]*|/\*.*?\*/)
  | (?P<string>"[^"]*")
  | (?P<number>-?(?:0[xX][0-9A-Fa-f]+|[0-9]+\.[0-9]*(?:[eE][+-]?[0-9]+)?|[0-9]+(?:[eE][+-]?[0-9]+)?|Infinity)|NaN)
  | (?P<identifier>[A-Za-z_][A-Za-z0-9_-]*)
  | (?P<ellipsis>\.\.\.)
  | (?P<other>[{}()\[\];:,=<>?*])
''', re.VERBOSE | re.DOTALL)


class IdlError(Exception):
    pass


def tokenize(text, file_name):
    tokens = []
    position = 0
    while position < len(text):
        match = TOKEN_PATTERN.match(text, position)
        if match is None:
            line = text.count('\n', 0, position) + 1
            raise IdlError('%s:%d: unexpected %r' % (file_name, line, text[position]))
        position = match.end()
        if match.lastgroup == 'space':
            continue
        tokens.append(match.group())
    tokens.append('')
    return tokens


class TypeSpec:
    """A WebIDL type as parsed: name (or 'union'), nullable, inner types,
    extended attributes."""

    def __init__(self, name, inner=None, nullable=False, attributes=None):
        self.name = name
        self.inner = inner or []
        self.nullable = nullable
        self.attributes = attributes or {}


class Argument:
    def __init__(self, name, type_spec, optional, variadic, default):
        self.name = name
        self.type = type_spec
        self.optional = optional
        self.variadic = variadic
        self.default = default


class Member:
    def __init__(self, kind, name, owner):
        self.kind = kind            # const, attribute, operation, constructor, stringifier, iterable
        self.name = name
        self.owner = owner          # the interface or mixin that declares it
        self.group = None           # the file it came from
        self.type = None
        self.arguments = []
        self.readonly = False
        self.static = False
        self.stringifier = False
        self.specials = []
        self.value = None
        self.attributes = {}


class Definition:
    def __init__(self, kind, name, group):
        self.kind = kind            # interface, mixin, namespace, dictionary, enum, callback, callback interface, typedef
        self.name = name
        self.group = group
        self.parent = None
        self.members = []
        self.attributes = {}
        self.includes = []
        self.values = []
        self.type = None


class Parser:
    def __init__(self, tokens, file_name, group):
        self.tokens = tokens
        self.position = 0
        self.file_name = file_name
        self.group = group

    def peek(self, offset=0):
        return self.tokens[self.position + offset]

    def take(self, expected=None):
        token = self.tokens[self.position]
        if expected is not None and token != expected:
            raise IdlError('%s: expected %r, found %r near %r' % (
                self.file_name, expected, token, ' '.join(self.tokens[max(0, self.position - 8):self.position + 3])))
        self.position += 1
        return token

    def accept(self, token):
        if self.peek() == token:
            self.position += 1
            return True
        return False

    def extended_attributes(self):
        result = {}
        if not self.accept('['):
            return result
        while True:
            name = self.take()
            value = True
            if self.accept('='):
                if self.accept('('):
                    items = []
                    while not self.accept(')'):
                        items.append(self.take().strip('"'))
                        self.accept(',')
                    value = items
                else:
                    value = self.take()
                    if value.startswith('"'):
                        value = value[1:-1]
            result[name] = value
            if self.accept(']'):
                return result
            self.take(',')

    def type_spec(self):
        attributes = self.extended_attributes()
        if self.accept('('):
            inner = [self.type_spec()]
            while self.accept('or'):
                inner.append(self.type_spec())
            self.take(')')
            spec = TypeSpec('union', inner)
        else:
            name = self.take()
            if name == 'unsigned':
                name += ' ' + self.take()
                if name == 'unsigned long' and self.peek() == 'long':
                    name += ' ' + self.take()
            elif name == 'long' and self.peek() == 'long':
                name += ' ' + self.take()
            elif name == 'unrestricted':
                name += ' ' + self.take()
            inner = []
            if name in ('sequence', 'FrozenArray', 'Promise', 'record', 'ObservableArray') and self.accept('<'):
                inner.append(self.type_spec())
                while self.accept(','):
                    inner.append(self.type_spec())
                self.take('>')
            spec = TypeSpec(name, inner)
        if self.accept('?'):
            spec.nullable = True
        spec.attributes.update(attributes)
        return spec

    def default_value(self):
        if self.accept('['):
            self.take(']')
            return '[]'
        if self.accept('{'):
            self.take('}')
            return '{}'
        return self.take()

    def arguments(self):
        self.take('(')
        result = []
        while not self.accept(')'):
            attributes = self.extended_attributes()
            optional = self.accept('optional')
            spec = self.type_spec()
            spec.attributes.update(attributes)
            variadic = self.accept('...')
            name = self.take()
            default = None
            if self.accept('='):
                default = self.default_value()
            result.append(Argument(name, spec, optional or variadic, variadic, default))
            self.accept(',')
        return result

    def member(self, owner):
        attributes = self.extended_attributes()
        token = self.peek()
        if token == 'const':
            self.take()
            member = Member('const', None, owner)
            member.type = self.type_spec()
            member.name = self.take()
            self.take('=')
            member.value = self.take()
        elif token == 'constructor':
            self.take()
            member = Member('constructor', 'constructor', owner)
            member.arguments = self.arguments()
        elif token in ('iterable', 'async_iterable', 'maplike', 'setlike'):
            self.take()
            member = Member('iterable', token, owner)
            self.take('<')
            member.arguments = [self.type_spec()]
            while self.accept(','):
                member.arguments.append(self.type_spec())
            self.take('>')
        elif token == 'stringifier' and self.peek(1) == ';':
            self.take()
            member = Member('stringifier', 'toString', owner)
        else:
            static = self.accept('static')
            stringifier = self.accept('stringifier')
            self.accept('inherit')
            readonly = self.accept('readonly')
            if self.accept('attribute'):
                member = Member('attribute', None, owner)
                member.type = self.type_spec()
                member.name = self.take()
                member.readonly = readonly
            else:
                specials = []
                while self.peek() in ('getter', 'setter', 'deleter'):
                    specials.append(self.take())
                member = Member('operation', None, owner)
                member.type = self.type_spec()
                member.specials = specials
                if self.peek() != '(':
                    member.name = self.take()
                member.arguments = self.arguments()
            member.static = static
            member.stringifier = stringifier
        self.take(';')
        member.attributes = attributes
        member.group = self.group
        return member

    def body(self, owner):
        self.take('{')
        members = []
        while not self.accept('}'):
            members.append(self.member(owner))
        self.take(';')
        return members

    def definitions(self):
        result = []
        while self.peek() != '':
            attributes = self.extended_attributes()
            partial = self.accept('partial')
            token = self.take()
            if token == 'interface' and self.peek() == 'mixin':
                self.take()
                definition = Definition('mixin', self.take(), self.group)
                definition.members = self.body(definition.name)
            elif token in ('interface', 'namespace'):
                definition = Definition(token, self.take(), self.group)
                if self.accept(':'):
                    definition.parent = self.take()
                definition.members = self.body(definition.name)
            elif token == 'dictionary':
                definition = Definition('dictionary', self.take(), self.group)
                if self.accept(':'):
                    definition.parent = self.take()
                self.take('{')
                while not self.accept('}'):
                    member_attributes = self.extended_attributes()
                    required = self.accept('required')
                    member = Member('field', None, definition.name)
                    member.type = self.type_spec()
                    member.name = self.take()
                    member.readonly = required
                    if self.accept('='):
                        member.value = self.default_value()
                    member.attributes = member_attributes
                    self.take(';')
                    definition.members.append(member)
                self.take(';')
            elif token == 'enum':
                definition = Definition('enum', self.take(), self.group)
                self.take('{')
                while not self.accept('}'):
                    definition.values.append(self.take()[1:-1])
                    self.accept(',')
                self.take(';')
            elif token == 'callback':
                if self.accept('interface'):
                    definition = Definition('callback interface', self.take(), self.group)
                    definition.members = self.body(definition.name)
                else:
                    definition = Definition('callback', self.take(), self.group)
                    self.take('=')
                    definition.type = self.type_spec()
                    definition.members = [Member('operation', 'call', definition.name)]
                    definition.members[0].arguments = self.arguments()
                    self.take(';')
            elif token == 'typedef':
                spec = self.type_spec()
                definition = Definition('typedef', self.take(), self.group)
                definition.type = spec
                self.take(';')
            else:
                # Name includes Mixin;
                name = token
                self.take('includes')
                mixin = self.take()
                self.take(';')
                definition = Definition('includes', name, self.group)
                definition.parent = mixin
            definition.attributes = attributes
            definition.partial = partial
            result.append(definition)
        return result


# ---------------------------------------------------------------- model

PRIMITIVE_KINDS = {
    'any': 'tkAny', 'undefined': 'tkUndefined', 'void': 'tkUndefined', 'boolean': 'tkBoolean',
    'byte': 'tkByte', 'octet': 'tkOctet', 'short': 'tkShort', 'unsigned short': 'tkUnsignedShort',
    'long': 'tkLong', 'unsigned long': 'tkUnsignedLong', 'long long': 'tkLongLong',
    'unsigned long long': 'tkUnsignedLongLong', 'float': 'tkFloat', 'unrestricted float': 'tkUnrestrictedFloat',
    'double': 'tkDouble', 'unrestricted double': 'tkUnrestrictedDouble', 'DOMString': 'tkDomString',
    'USVString': 'tkUsvString', 'ByteString': 'tkByteString', 'object': 'tkObject',
}

TYPE_FLAGS = {'nullable': 1, 'Clamp': 2, 'EnforceRange': 4, 'LegacyNullToEmptyString': 8,
              'LegacyTreatNonObjectAsNull': 16}


class Model:
    def __init__(self, definitions):
        self.definitions = {}
        self.order = []
        self.includes = []
        for definition in definitions:
            if definition.kind == 'includes':
                self.includes.append(definition)
                continue
            existing = self.definitions.get(definition.name)
            if existing is not None:
                if not (definition.partial or existing.partial):
                    raise IdlError('%s defined twice' % definition.name)
                existing.members.extend(definition.members)
                if not definition.partial:
                    existing.group = definition.group
                    existing.parent = definition.parent
                    existing.attributes.update(definition.attributes)
                    existing.partial = False
                continue
            self.definitions[definition.name] = definition
            self.order.append(definition)
        for include in self.includes:
            self.find(include.name, ('interface',)).includes.append(include.parent)
        self.interfaces = [d for d in self.order if d.kind in ('interface', 'namespace')]
        self.interfaces = self.sorted_by_inheritance(self.interfaces)
        self.interface_ids = {d.name: index for index, d in enumerate(self.interfaces)}
        self.dictionaries = [d for d in self.order if d.kind == 'dictionary']
        self.dictionary_ids = {d.name: index for index, d in enumerate(self.dictionaries)}
        self.enums = [d for d in self.order if d.kind == 'enum']
        self.enum_ids = {d.name: index for index, d in enumerate(self.enums)}
        self.types = []
        self.type_keys = {}
        self.union_members = []
        self.arguments = []
        self.overloads = []
        self.members = []
        self.enum_values = []
        self.reflect_enums = []
        self.reflect_enum_keys = {}
        self.dictionary_members = []
        self.declarations = {}

    def find(self, name, kinds):
        definition = self.definitions.get(name)
        if definition is None or definition.kind not in kinds:
            raise IdlError('unknown %s %s' % ('/'.join(kinds), name))
        return definition

    def sorted_by_inheritance(self, interfaces):
        placed = []
        names = set()
        pending = list(interfaces)
        while pending:
            progress = False
            for definition in list(pending):
                if definition.parent is None or definition.parent in names:
                    placed.append(definition)
                    names.add(definition.name)
                    pending.remove(definition)
                    progress = True
            if not progress:
                raise IdlError('unknown parents: %s' % ', '.join(d.parent for d in pending))
        return placed

    # Types

    def resolve_typedef(self, spec):
        definition = self.definitions.get(spec.name)
        if definition is not None and definition.kind == 'typedef':
            inner = definition.type
            resolved = TypeSpec(inner.name, inner.inner, inner.nullable or spec.nullable, dict(inner.attributes))
            resolved.attributes.update(spec.attributes)
            return self.resolve_typedef(resolved)
        return spec

    def type_index(self, spec):
        spec = self.resolve_typedef(spec)
        flags = 0
        if spec.nullable:
            flags |= TYPE_FLAGS['nullable']
        for name in ('Clamp', 'EnforceRange', 'LegacyNullToEmptyString'):
            if name in spec.attributes:
                flags |= TYPE_FLAGS[name]
        reference = -1
        count = 0
        if spec.name == 'union':
            kind = 'tkUnion'
            members = [self.type_index(inner) for inner in spec.inner]
            reference = len(self.union_members)
            count = len(members)
            key = ('union', tuple(members), flags)
            if key in self.type_keys:
                return self.type_keys[key]
            self.union_members.extend(members)
        elif spec.name in PRIMITIVE_KINDS:
            kind = PRIMITIVE_KINDS[spec.name]
        elif spec.name in ('sequence', 'FrozenArray', 'ObservableArray'):
            kind = 'tkSequence'
            reference = self.type_index(spec.inner[0])
        elif spec.name == 'record':
            kind = 'tkRecord'
            reference = self.type_index(spec.inner[1])
        elif spec.name == 'Promise':
            kind = 'tkPromise'
        elif spec.name in ('ArrayBuffer', 'ArrayBufferView', 'BufferSource', 'AllowSharedBufferSource',
                           'Uint8Array', 'Uint8ClampedArray'):
            kind = 'tkObject'
        else:
            definition = self.definitions.get(spec.name)
            if definition is None:
                raise IdlError('unknown type %s' % spec.name)
            if definition.kind == 'interface':
                kind = 'tkInterface'
                reference = self.interface_ids[spec.name]
            elif definition.kind == 'dictionary':
                kind = 'tkDictionary'
                reference = self.dictionary_ids[spec.name]
            elif definition.kind == 'enum':
                kind = 'tkEnum'
                reference = self.enum_ids[spec.name]
            elif definition.kind == 'callback':
                kind = 'tkCallback'
                if 'LegacyTreatNonObjectAsNull' in definition.attributes:
                    flags |= TYPE_FLAGS['LegacyTreatNonObjectAsNull']
            elif definition.kind == 'callback interface':
                kind = 'tkCallbackInterface'
            else:
                raise IdlError('type %s is a %s' % (spec.name, definition.kind))
        key = (kind, flags, reference, count)
        if key not in self.type_keys:
            self.type_keys[key] = len(self.types)
            self.types.append(key)
        return self.type_keys[key]

    def argument_range(self, arguments):
        first = len(self.arguments)
        for argument in arguments:
            flags = 0
            if argument.optional:
                flags |= 1
            if argument.variadic:
                flags |= 2
            if argument.default is not None:
                flags |= 4
            self.arguments.append((argument.name, self.type_index(argument.type), flags, argument.default))
        required = 0
        for index, argument in enumerate(arguments):
            if not argument.optional:
                required = index + 1
        return first, len(arguments), required

    def overload_range(self, operations):
        first = len(self.overloads)
        for operation in operations:
            first_argument, count, required = self.argument_range(operation.arguments)
            self.overloads.append((first_argument, count, required))
        return first, len(operations)

    def declare(self, group, routine):
        self.declarations.setdefault(group, [])
        if routine not in self.declarations[group]:
            self.declarations[group].append(routine)

    def reflect_enum(self, keywords):
        key = tuple(keywords)
        if key not in self.reflect_enum_keys:
            self.reflect_enum_keys[key] = len(self.reflect_enums)
            self.reflect_enums.append(key)
        return self.reflect_enum_keys[key]

    # Interfaces

    def own_members(self, definition):
        members = list(definition.members)
        for mixin_name in definition.includes:
            mixin = self.find(mixin_name, ('mixin',))
            members.extend(mixin.members)
        return members

    def cache_slots_before(self, definition):
        if definition.parent is None:
            return 1
        parent = self.find(definition.parent, ('interface',))
        return self.cache_slots_before(parent) + self.cache_slot_count(parent)

    def cache_slot_count(self, definition):
        return sum(1 for member in self.own_members(definition)
                   if member.kind == 'attribute' and 'SameObject' in member.attributes)

    def build(self):
        self.interface_rows = []
        for definition in self.interfaces:
            row = self.build_interface(definition)
            self.inherit_special_operations(row)
            self.interface_rows.append(row)
        self.dictionary_rows = []
        for definition in self.dictionaries:
            first = len(self.dictionary_members)
            for member in self.flattened_dictionary_members(definition):
                flags = 0
                if member.readonly:
                    flags |= 1
                if member.value is not None:
                    flags |= 4
                self.dictionary_members.append((member.name, self.type_index(member.type), flags, member.value))
            self.dictionary_rows.append((definition.name, first, len(self.dictionary_members) - first))
        self.enum_rows = []
        for definition in self.enums:
            self.enum_rows.append((definition.name, len(self.enum_values), len(definition.values)))
            self.enum_values.extend(definition.values)

    def inherit_special_operations(self, row):
        """An interface without its own indexed or named property operations
        and iterable declaration has its parent's."""
        if row['parent'] < 0:
            return
        parent = self.interface_rows[row['parent']]
        if row['indexed'] < 0 and parent['indexed'] >= 0:
            row['indexed'] = parent['indexed']
            row['flags'] |= parent['flags'] & 512
        if row['named'] < 0 and parent['named'] >= 0:
            row['named'] = parent['named']
            row['supported_names'] = parent['supported_names']
            row['flags'] |= parent['flags'] & (1024 | 8 | 16)
        for key in ('named_setter', 'named_deleter', 'pair_at'):
            if row[key] == 'nil':
                row[key] = parent[key]
        if not row['flags'] & (32 | 64):
            row['flags'] |= parent['flags'] & (32 | 64)

    def flattened_dictionary_members(self, definition):
        members = []
        if definition.parent is not None:
            members.extend(self.flattened_dictionary_members(self.find(definition.parent, ('dictionary',))))
        members.extend(sorted(definition.members, key=lambda member: member.name))
        return members

    def build_interface(self, definition):
        flags = 0
        attributes = definition.attributes
        if 'Global' in attributes:
            flags |= 1
        if 'ExceptionLike' in attributes:
            flags |= 4
        if 'LegacyUnenumerableNamedProperties' in attributes:
            flags |= 8
        if 'LegacyOverrideBuiltIns' in attributes:
            flags |= 16
        if definition.kind == 'namespace':
            flags |= 256
        prefix = definition.name
        members = self.own_members(definition)
        first_member = len(self.members)
        cache_slot = self.cache_slots_before(definition)
        constructors = [member for member in members if member.kind == 'constructor']
        construct = 'nil'
        constructor_first, constructor_count, constructor_length = -1, 0, 0
        if constructors:
            flags |= 128
            construct = '@%s_constructor' % prefix
            self.declare(definition.group, ('%s_constructor' % prefix, 'constructor'))
            constructor_first, constructor_count = self.overload_range(constructors)
            constructor_length = min(self.overloads[constructor_first + index][2] for index in range(constructor_count))
        indexed_getter = -1
        named_getter = -1
        named_setter = 'nil'
        named_deleter = 'nil'
        supported_names = 'nil'
        pair_at = 'nil'
        operations = {}
        operation_order = []
        for member in members:
            if member.kind == 'operation':
                key = (member.name, member.static, tuple(member.specials) if member.name is None else ())
                if key not in operations:
                    operations[key] = []
                    operation_order.append(key)
                operations[key].append(member)
        emitted_operations = set()
        for member in members:
            owner = member.owner
            if member.kind == 'const':
                self.members.append(dict(name=member.name, kind='mkConstant', flags=0,
                                         type=self.type_index(member.type), value=constant_value(member.value)))
            elif member.kind == 'attribute':
                row = self.attribute_row(member, owner, cache_slot)
                if 'SameObject' in member.attributes:
                    cache_slot += 1
                self.members.append(row)
            elif member.kind == 'operation':
                key = (member.name, member.static, tuple(member.specials) if member.name is None else ())
                if key in emitted_operations:
                    continue
                emitted_operations.add(key)
                group = operations[key]
                index = len(self.members)
                row = self.operation_row(member, owner, group)
                self.members.append(row)
                if 'getter' in member.specials:
                    first_type = self.resolve_typedef(member.arguments[0].type).name
                    if first_type == 'unsigned long':
                        indexed_getter = index
                        flags |= 512
                    else:
                        named_getter = index
                        flags |= 1024
                        supported_names = '@%s_supportedNames' % owner
                        self.declare(member.group, ('%s_supportedNames' % owner, 'names'))
                if 'setter' in member.specials:
                    named_setter = row['getter']
                if 'deleter' in member.specials:
                    named_deleter = row['getter']
            elif member.kind == 'stringifier':
                routine = '%s_stringifier' % owner
                self.declare(member.group, (routine, 'operation'))
                self.members.append(dict(name='toString', kind='mkStringifier', flags=0,
                                         type=self.type_index(TypeSpec('DOMString')), getter='@' + routine))
            elif member.kind == 'iterable':
                if len(member.arguments) == 1:
                    flags |= 32
                else:
                    flags |= 64
                    pair_at = '@%s_pairAt' % owner
                    self.declare(member.group, ('%s_pairAt' % owner, 'operation'))
        alias = attributes.get('LegacyWindowAlias')
        return dict(name=definition.name,
                    parent=self.interface_ids[definition.parent] if definition.parent else -1,
                    flags=flags, first=first_member, count=len(self.members) - first_member,
                    construct=construct, constructor_first=constructor_first,
                    constructor_count=constructor_count, constructor_length=constructor_length,
                    indexed=indexed_getter, named=named_getter, named_setter=named_setter,
                    named_deleter=named_deleter, supported_names=supported_names, pair_at=pair_at,
                    cache_slots=cache_slot, alias=alias if isinstance(alias, str) else None,
                    local_names=attributes.get('LocalNames', []))

    def attribute_row(self, member, owner, cache_slot):
        attributes = member.attributes
        flags = 0
        if member.readonly:
            flags |= 1
        if member.static:
            flags |= 2
        if 'LegacyUnforgeable' in attributes:
            flags |= 4
        if 'Replaceable' in attributes:
            flags |= 8
        if member.stringifier:
            flags |= 32
        text = None
        if 'PutForwards' in attributes:
            flags |= 64
            text = attributes['PutForwards']
        row = dict(name=member.name, flags=flags, type=self.type_index(member.type), text=text,
                   cache=cache_slot if 'SameObject' in attributes else -1)
        if member.type.name == 'EventHandler':
            row['kind'] = 'mkEventHandler'
            return row
        if 'Reflect' in attributes or 'ReflectURL' in attributes:
            row['kind'] = 'mkReflected'
            content = attributes.get('Reflect', attributes.get('ReflectURL'))
            row['text'] = content if isinstance(content, str) else member.name.lower()
            type_name = self.resolve_typedef(member.type).name
            if 'ReflectURL' in attributes:
                row['reflect'] = 'rkUrl'
            elif 'ReflectEnum' in attributes:
                row['reflect'] = 'rkEnum'
                row['enum'] = self.reflect_enum(attributes['ReflectEnum'])
                row['missing'] = attributes.get('ReflectMissing', '')
                row['invalid'] = attributes.get('ReflectInvalid', '')
            elif type_name == 'boolean':
                row['reflect'] = 'rkBoolean'
            elif type_name == 'long':
                row['reflect'] = 'rkLong'
            elif type_name == 'unsigned long':
                row['reflect'] = 'rkUnsignedLong'
            elif type_name == 'double':
                row['reflect'] = 'rkDouble'
            else:
                row['reflect'] = 'rkString'
            row['value'] = constant_value(attributes.get('ReflectDefault', '0'))
            if 'ReflectPositive' in attributes:
                row['flags'] |= 512
            return row
        row['kind'] = 'mkAttribute'
        getter = '%s_get_%s' % (owner, member.name)
        row['getter'] = '@' + getter
        self.declare(member.group, (getter, 'getter'))
        if not member.readonly:
            setter = '%s_set_%s' % (owner, member.name)
            row['setter'] = '@' + setter
            self.declare(member.group, (setter, 'setter'))
        return row

    def operation_row(self, member, owner, group):
        flags = 0
        if member.static:
            flags |= 2
        if 'NewObject' in member.attributes:
            flags |= 256
        if member.name is None:
            flags |= 128
            special = member.specials[0]
            routine = '%s_named%s' % (owner, special.capitalize())
            name = ''
        else:
            routine = '%s_%s' % (owner, member.name)
            name = member.name
        if 'LegacyUnforgeable' in member.attributes:
            flags |= 4
        self.declare(member.group, (routine, 'operation'))
        first, count = self.overload_range(group)
        return dict(name=name, kind='mkOperation', flags=flags, type=self.type_index(member.type),
                    first_overload=first, overload_count=count, getter='@' + routine)


def constant_value(text):
    text = str(text)
    if text in ('true', 'false'):
        return '1' if text == 'true' else '0'
    if text.lower().startswith('0x') or text.lower().startswith('-0x'):
        return str(int(text, 16))
    return text


# ---------------------------------------------------------------- output

def pascal_text(text):
    if text is None:
        return 'nil'
    return "'" + text.replace("'", "''") + "'"


def pascal_identifier(text):
    parts = re.split(r'[^A-Za-z0-9]+', text)
    return ''.join(part[:1].upper() + part[1:] for part in parts if part)


def write_ids(model, path):
    lines = ['{ Generated by make-bindings.py from bindings/*.webidl: do not edit. }', '', 'const']
    for index, definition in enumerate(model.interfaces):
        lines.append('  Interface%s = %d;' % (definition.name, index))
    lines.append('  InterfaceCount = %d;' % len(model.interfaces))
    lines.append('')
    position = 0
    for name, first, count in model.dictionary_rows:
        lines.append('  Dictionary%s = %d;' % (name, model.dictionary_ids[name]))
        for index in range(count):
            member = model.dictionary_members[first + index]
            lines.append('  %s_%s = %d;' % (name, member[0], index))
        position += 1
    lines.append('')
    handlers = sorted(set(member['name'] for member in model.members if member['kind'] == 'mkEventHandler'))
    lines.append('  { The event handler attribute names (sorted). }')
    lines.append('  EventHandlerNames: array[0..%d] of string = (' % (len(handlers) - 1))
    lines.append(',\n'.join("    '%s'" % name for name in handlers) + ');')
    lines.append('')
    for name, first, count in model.enum_rows:
        lines.append('  Enum%s = %d;' % (name, model.enum_ids[name]))
        for index in range(count):
            value = model.enum_values[first + index]
            lines.append('  %s%s = %d;' % (name, pascal_identifier(value) or 'Empty', index))
    with open(path, 'w') as output:
        output.write('\n'.join(lines) + '\n')


def write_tables(model, path):
    out = ['{ Generated by make-bindings.py from bindings/*.webidl: do not edit. }', '']

    out.append('const')
    out.append('  BindingTypes: array[0..%d] of TBindingType = (' % (len(model.types) - 1))
    rows = ['    (Kind: %s; Flags: %d; Reference: %d; Count: %d)' % key for key in model.types]
    out.append(',\n'.join(rows) + ');')
    out.append('')

    out.append('  BindingUnionMembers: array[0..%d] of SmallInt = (%s);' % (
        max(len(model.union_members), 1) - 1, ', '.join(str(v) for v in model.union_members) or '0'))
    out.append('')

    out.append('  BindingArguments: array[0..%d] of TBindingArgument = (' % (max(len(model.arguments), 1) - 1))
    rows = ['    (Name: %s; TypeIndex: %d; Flags: %d; DefaultValue: %s)' % (
        pascal_text(name), type_index, flags, pascal_text(default)) for name, type_index, flags, default in model.arguments]
    out.append(',\n'.join(rows or ["    (Name: nil; TypeIndex: 0; Flags: 0; DefaultValue: nil)"]) + ');')
    out.append('')

    out.append('  BindingOverloads: array[0..%d] of TBindingOverload = (' % (max(len(model.overloads), 1) - 1))
    rows = ['    (FirstArgument: %d; ArgumentCount: %d; RequiredCount: %d)' % row for row in model.overloads]
    out.append(',\n'.join(rows) + ');')
    out.append('')

    out.append('  BindingReflectEnumKeywords: array[0..%d] of PChar = (' % (
        max(sum(len(k) for k in model.reflect_enums), 1) - 1))
    keywords = []
    starts = []
    for keys in model.reflect_enums:
        starts.append((len(keywords), len(keys)))
        keywords.extend(keys)
    out.append(',\n'.join('    ' + pascal_text(k) for k in keywords) + ');')
    out.append('  BindingReflectEnums: array[0..%d] of TBindingRange = (' % (max(len(starts), 1) - 1))
    out.append(',\n'.join('    (First: %d; Count: %d)' % s for s in starts) + ');')
    out.append('')

    out.append('  BindingMembers: array[0..%d] of TBindingMember = (' % (len(model.members) - 1))
    rows = []
    for member in model.members:
        rows.append('    (Name: %s; Kind: %s; Flags: %d; TypeIndex: %d; FirstOverload: %d; OverloadCount: %d;\n'
                    '     CacheSlot: %d; Getter: %s; Setter: %s; Value: %s; Text: %s; ReflectKind: %s;\n'
                    '     EnumIndex: %d; Missing: %s; Invalid: %s)' % (
                        pascal_text(member['name']), member['kind'], member.get('flags', 0), member.get('type', 0),
                        member.get('first_overload', -1), member.get('overload_count', 0), member.get('cache', -1),
                        member.get('getter', 'nil'), member.get('setter', 'nil'), member.get('value', '0'),
                        pascal_text(member.get('text')), member.get('reflect', 'rkNone'), member.get('enum', -1),
                        pascal_text(member.get('missing')), pascal_text(member.get('invalid'))))
    out.append(',\n'.join(rows) + ');')
    out.append('')

    out.append('  BindingInterfaces: array[0..%d] of TBindingInterface = (' % (len(model.interface_rows) - 1))
    rows = []
    for row in model.interface_rows:
        rows.append('    (Name: %s; Parent: %d; Flags: %d; FirstMember: %d; MemberCount: %d;\n'
                    '     Construct: %s; FirstConstructorOverload: %d; ConstructorOverloadCount: %d;\n'
                    '     ConstructorLength: %d; IndexedGetter: %d; NamedGetter: %d; NamedSetter: %s;\n'
                    '     NamedDeleter: %s; SupportedNames: %s; PairAt: %s; CacheSlotCount: %d; Alias: %s)' % (
                        pascal_text(row['name']), row['parent'], row['flags'], row['first'], row['count'],
                        row['construct'], row['constructor_first'], row['constructor_count'],
                        row['constructor_length'], row['indexed'], row['named'], row['named_setter'],
                        row['named_deleter'], row['supported_names'], row['pair_at'], row['cache_slots'],
                        pascal_text(row['alias'])))
    out.append(',\n'.join(rows) + ');')
    out.append('')

    out.append('  BindingDictionaryMembers: array[0..%d] of TBindingArgument = (' % (
        max(len(model.dictionary_members), 1) - 1))
    rows = ['    (Name: %s; TypeIndex: %d; Flags: %d; DefaultValue: %s)' % (
        pascal_text(name), type_index, flags, pascal_text(default))
        for name, type_index, flags, default in model.dictionary_members]
    out.append(',\n'.join(rows) + ');')
    out.append('  BindingDictionaries: array[0..%d] of TBindingRange = (' % (max(len(model.dictionary_rows), 1) - 1))
    out.append(',\n'.join('    (First: %d; Count: %d)' % (first, count)
                          for _, first, count in model.dictionary_rows) + ');')
    out.append('')

    out.append('  BindingEnumValues: array[0..%d] of PChar = (' % (max(len(model.enum_values), 1) - 1))
    out.append(',\n'.join('    ' + pascal_text(v) for v in model.enum_values) + ');')
    out.append('  BindingEnums: array[0..%d] of TBindingRange = (' % (max(len(model.enum_rows), 1) - 1))
    out.append(',\n'.join('    (First: %d; Count: %d)' % (first, count) for _, first, count in model.enum_rows) + ');')
    out.append('')

    element_rows = []
    for index, row in enumerate(model.interface_rows):
        for local_name in row['local_names']:
            element_rows.append((local_name, index))
    out.append('  BindingElementInterfaces: array[0..%d] of TBindingElementInterface = (' % (len(element_rows) - 1))
    out.append(',\n'.join('    (LocalName: %s; InterfaceId: %d)' % (pascal_text(name), index)
                          for name, index in element_rows) + ');')
    with open(path, 'w') as output:
        output.write('\n'.join(out) + '\n')


def write_declarations(model, output_directory):
    for group, routines in model.declarations.items():
        lines = ['{ Generated by make-bindings.py from bindings/%s.webidl: do not edit.' % group,
                 '  The routines Web.Bindings.%s implements. }' % group, '']
        for routine, _ in sorted(routines):
            lines.append('function %s(var Call: TBindingCall): TJsValue;' % routine)
        path = os.path.join(output_directory, 'Web.Bindings.%s.Members.inc' % group)
        with open(path, 'w') as output:
            output.write('\n'.join(lines) + '\n')


PLATFORM_DIRECTORY = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'platform')


def pascal_line(line):
    """One source line as a Pascal string expression (pieces of at most
    200 characters, control characters as #n)."""
    pieces = []
    literal = ''
    for character in line:
        code = ord(character)
        if code > 127:
            raise IdlError('platform scripts must be ASCII (use \\u escapes)')
        if character == "'":
            literal += "''"
        elif code >= 32:
            literal += character
        else:
            if literal:
                pieces.append("'%s'" % literal)
                literal = ''
            pieces.append('#%d' % code)
        if len(literal) > 200:
            pieces.append("'%s'" % literal)
            literal = ''
    if literal or not pieces:
        pieces.append("'%s'" % literal)
    return ' + '.join(pieces)


def write_platform_sources(path):
    """Web.Script.PlatformSources.inc: the platform scripts (platform/*.js),
    in file name order, each as an array of its lines."""
    names = sorted(name for name in os.listdir(PLATFORM_DIRECTORY) if name.endswith('.js'))
    lines = ['{ Generated by make-bindings.py from userland/lib/web/platform/*.js. }', 'const',
             '  PlatformScriptCount = %d;' % len(names),
             '  PlatformScriptNames: array[0..%d] of string = (' % (len(names) - 1)]
    lines.append(',\n'.join("    '%s'" % name for name in names) + ');')
    for index, name in enumerate(names):
        with open(os.path.join(PLATFORM_DIRECTORY, name), encoding='utf-8') as source:
            text = source.read().rstrip('\n').split('\n')
        lines.append('  PlatformScript%dLines: array[0..%d] of string = (' % (index, len(text) - 1))
        lines.append(',\n'.join('    ' + pascal_line(line) for line in text) + ');')
    lines.append('')
    lines.append('{ The source of platform script Index (its lines joined). }')
    lines.append('function PlatformScriptSource(Index: Integer): string;')
    lines.append('')
    lines.append('implementation')
    lines.append('')
    lines.append('function JoinLines(const Lines: array of string): string;')
    lines.append('var')
    lines.append('  Index: Integer;')
    lines.append('begin')
    lines.append("  Result := '';")
    lines.append('  for Index := 0 to High(Lines) do')
    lines.append('    Result := Result + Lines[Index] + #10;')
    lines.append('end;')
    lines.append('')
    lines.append('function PlatformScriptSource(Index: Integer): string;')
    lines.append('begin')
    lines.append('  case Index of')
    for index in range(len(names)):
        lines.append('    %d: Result := JoinLines(PlatformScript%dLines);' % (index, index))
    lines.append('  else')
    lines.append("    Result := '';")
    lines.append('  end;')
    lines.append('end;')
    with open(path, 'w') as output:
        output.write('\n'.join(lines) + '\n')


def main():
    if len(sys.argv) != 2:
        sys.exit('usage: make-bindings.py <output directory>')
    output_directory = sys.argv[1]
    os.makedirs(output_directory, exist_ok=True)
    definitions = []
    groups = []
    for file_name in sorted(os.listdir(BINDINGS_DIRECTORY)):
        if not file_name.endswith('.webidl'):
            continue
        group = file_name[:-len('.webidl')]
        groups.append(group)
        path = os.path.join(BINDINGS_DIRECTORY, file_name)
        with open(path, encoding='utf-8') as source:
            parser = Parser(tokenize(source.read(), file_name), file_name, group)
        definitions.extend(parser.definitions())
    model = Model(definitions)
    model.build()
    for group in groups:
        model.declarations.setdefault(group, [])
    write_ids(model, os.path.join(output_directory, 'Web.Bindings.Ids.inc'))
    write_tables(model, os.path.join(output_directory, 'Web.Bindings.Tables.inc'))
    write_declarations(model, output_directory)
    write_platform_sources(os.path.join(output_directory, 'Web.Script.PlatformSources.inc'))


if __name__ == '__main__':
    try:
        main()
    except IdlError as error:
        sys.exit('make-bindings.py: %s' % error)
