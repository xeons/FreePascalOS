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
  The shapes of the binding tables make-bindings.py writes from the
  WebIDL files (bindings/*.webidl), the converted values an
  implementation routine gets, and the call record it works on.

  Tables: an interface is a row of BindingInterfaces with a range of
  BindingMembers; an operation's member has a range of BindingOverloads,
  each a range of BindingArguments; types are rows of BindingTypes
  (unions list their member types in BindingUnionMembers; sequences and
  records name their element type). Dictionaries are ranges of
  BindingDictionaryMembers, inherited members first, each level sorted
  by name as WebIDL orders them.

  Implementation routines (TBindingHandler) get the call: the realm, the
  native object of this (a TNode, TEvent ...), the arguments converted to
  their WebIDL types, and return a JavaScript value. They report errors
  by raising EDomException (Web.Dom.Exceptions), EBindingTypeError or
  EBindingRangeError; EBindingPendingException means a JavaScript
  exception is already pending (a conversion called script that threw).
}
unit Web.Bindings.Types;

{$mode objfpc}
{$H+}
{$modeswitch advancedrecords}

interface

uses
  SysUtils,
  Js.Values,
  Js.Objects;

{$I Web.Bindings.Ids.inc}

type
  TBindingTypeKind = (
    tkAny, tkUndefined, tkBoolean, tkByte, tkOctet, tkShort, tkUnsignedShort, tkLong, tkUnsignedLong,
    tkLongLong, tkUnsignedLongLong, tkFloat, tkUnrestrictedFloat, tkDouble, tkUnrestrictedDouble,
    tkDomString, tkUsvString, tkByteString, tkObject, tkInterface, tkCallback, tkCallbackInterface,
    tkDictionary, tkEnum, tkSequence, tkRecord, tkUnion, tkPromise);

  TBindingMemberKind = (mkAttribute, mkOperation, mkConstant, mkReflected, mkEventHandler, mkStringifier);

  TBindingReflectKind = (rkNone, rkString, rkUrl, rkBoolean, rkLong, rkUnsignedLong, rkDouble, rkEnum);

const
  { TBindingType.Flags }
  TypeNullable = 1;
  TypeClamp = 2;
  TypeEnforceRange = 4;
  TypeNullToEmptyString = 8;
  TypeTreatNonObjectAsNull = 16;

  { TBindingArgument.Flags (also dictionary members: 1 is required) }
  ArgumentOptional = 1;
  ArgumentVariadic = 2;
  ArgumentHasDefault = 4;
  DictionaryMemberRequired = 1;

  { TBindingMember.Flags }
  MemberReadonly = 1;
  MemberStatic = 2;
  MemberUnforgeable = 4;
  MemberReplaceable = 8;
  MemberStringifier = 32;
  MemberPutForwards = 64;
  MemberHidden = 128;
  MemberNewObject = 256;
  MemberReflectPositive = 512;

  { TBindingInterface.Flags }
  InterfaceGlobal = 1;
  InterfaceExceptionLike = 4;
  InterfaceUnenumerableNamedProperties = 8;
  InterfaceOverrideBuiltIns = 16;
  InterfaceValueIterable = 32;
  InterfacePairIterable = 64;
  InterfaceHasConstructor = 128;
  InterfaceNamespace = 256;
  InterfaceIndexed = 512;
  InterfaceNamed = 1024;

  { The first cache slot of every wrapper: its event handlers. }
  CacheSlotEventHandlers = 0;

type
  TBindingValueKind = (bvMissing, bvUndefined, bvNull, bvBoolean, bvNumber, bvString, bvNative, bvScript,
    bvSequence, bvRecord, bvDictionary);

  TBindingValue = record
    Kind: TBindingValueKind;
    { The union member type that matched (index in its member list). }
    UnionMember: Integer;
    Flag: Boolean;
    Number: Double;
    Text: string;
    { An interface value's native object (TNode, TEvent ...). }
    Native: TObject;
    { any, object, callbacks, and the original of every value. }
    Script: TJsValue;
    { Sequence items, record values, dictionary members (by index). }
    Items: array of TBindingValue;
    { Record keys. }
    Keys: array of string;
  end;
  PBindingValue = ^TBindingValue;
  TBindingValueArray = array of TBindingValue;

  PBindingMember = ^TBindingMember;
  PBindingCall = ^TBindingCall;

  TBindingCall = record
    Realm: TJsRealm;
    { The script context (a TBindingContext). }
    Context: TObject;
    This: TJsValue;
    { The wrapper of this (a TBindingWrapper), nil for static members. }
    Wrapper: TObject;
    { This's native object. }
    Target: TObject;
    Member: PBindingMember;
    { The interface whose member (or constructor) this is. }
    InterfaceId: Integer;
    { The overload chosen. }
    Overload: Integer;
    { How many arguments the script passed. }
    PassedCount: Integer;
    RawArguments: PJsValueArray;
    Arguments: TBindingValueArray;
    NewTarget: TJsValue;
    { The argument's value (missing optional arguments are bvMissing). }
    function Text(Index: Integer): string;
    function Number(Index: Integer): Double;
    function Int(Index: Integer): Int64;
    function Flag(Index: Integer): Boolean;
    function Native(Index: Integer): TObject;
    function Script(Index: Integer): TJsValue;
    function Present(Index: Integer): Boolean;
    function IsNull(Index: Integer): Boolean;
    function Count: Integer;
  end;

  TBindingHandler = function(var Call: TBindingCall): TJsValue;

  TBindingType = record
    Kind: TBindingTypeKind;
    Flags: Byte;
    Reference: SmallInt;
    Count: SmallInt;
  end;
  PBindingType = ^TBindingType;

  TBindingArgument = record
    Name: PChar;
    TypeIndex: SmallInt;
    Flags: Byte;
    DefaultValue: PChar;
  end;
  PBindingArgument = ^TBindingArgument;

  TBindingOverload = record
    FirstArgument: SmallInt;
    ArgumentCount: Byte;
    RequiredCount: Byte;
  end;
  PBindingOverload = ^TBindingOverload;

  TBindingMember = record
    Name: PChar;
    Kind: TBindingMemberKind;
    Flags: Word;
    TypeIndex: SmallInt;
    FirstOverload: SmallInt;
    OverloadCount: Byte;
    CacheSlot: ShortInt;
    Getter: TBindingHandler;
    Setter: TBindingHandler;
    { A constant's value; a reflected number's default. }
    Value: Double;
    { A reflected attribute's content attribute; PutForwards' target. }
    Text: PChar;
    ReflectKind: TBindingReflectKind;
    EnumIndex: SmallInt;
    Missing: PChar;
    Invalid: PChar;
  end;

  TBindingInterface = record
    Name: PChar;
    Parent: SmallInt;
    Flags: Word;
    FirstMember: SmallInt;
    MemberCount: SmallInt;
    Construct: TBindingHandler;
    FirstConstructorOverload: SmallInt;
    ConstructorOverloadCount: Byte;
    ConstructorLength: Byte;
    { Member indexes (into BindingMembers) of the special operations. }
    IndexedGetter: SmallInt;
    NamedGetter: SmallInt;
    NamedSetter: TBindingHandler;
    NamedDeleter: TBindingHandler;
    { Returns a JavaScript array of the supported property names. }
    SupportedNames: TBindingHandler;
    { Pair iterators: Arguments[0] is the index; returns [key, value] or
      JsUndefined past the end. }
    PairAt: TBindingHandler;
    { Cache slots its wrappers need (with the parents' and slot 0). }
    CacheSlotCount: ShortInt;
    Alias: PChar;
  end;
  PBindingInterface = ^TBindingInterface;

  TBindingRange = record
    First: SmallInt;
    Count: SmallInt;
  end;

  TBindingElementInterface = record
    LocalName: PChar;
    InterfaceId: SmallInt;
  end;

  { A TypeError for script. }
  EBindingTypeError = class(Exception);
  { A RangeError for script. }
  EBindingRangeError = class(Exception);
  { A JavaScript exception is pending already. }
  EBindingPendingException = class(Exception);

procedure RaiseTypeError(const Message: string);
procedure RaiseRangeError(const Message: string);

implementation

procedure RaiseTypeError(const Message: string);
begin
  raise EBindingTypeError.Create(Message);
end;

procedure RaiseRangeError(const Message: string);
begin
  raise EBindingRangeError.Create(Message);
end;

function TBindingCall.Count: Integer;
begin
  Result := System.Length(Arguments);
end;

function TBindingCall.Present(Index: Integer): Boolean;
begin
  Result := (Index < System.Length(Arguments)) and (Arguments[Index].Kind <> bvMissing);
end;

function TBindingCall.IsNull(Index: Integer): Boolean;
begin
  Result := (Index >= System.Length(Arguments)) or (Arguments[Index].Kind in [bvMissing, bvNull, bvUndefined]);
end;

function TBindingCall.Text(Index: Integer): string;
begin
  Result := '';
  if Index < System.Length(Arguments) then
    Result := Arguments[Index].Text;
end;

function TBindingCall.Number(Index: Integer): Double;
begin
  Result := 0;
  if Index < System.Length(Arguments) then
    Result := Arguments[Index].Number;
end;

function TBindingCall.Int(Index: Integer): Int64;
begin
  Result := 0;
  if Index < System.Length(Arguments) then
    Result := Trunc(Arguments[Index].Number);
end;

function TBindingCall.Flag(Index: Integer): Boolean;
begin
  Result := False;
  if Index < System.Length(Arguments) then
    Result := Arguments[Index].Flag;
end;

function TBindingCall.Native(Index: Integer): TObject;
begin
  Result := nil;
  if Index < System.Length(Arguments) then
    Result := Arguments[Index].Native;
end;

function TBindingCall.Script(Index: Integer): TJsValue;
begin
  Result := JsUndefined;
  if Index < System.Length(Arguments) then
    Result := Arguments[Index].Script;
end;

end.
