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
  Object: the constructor, its static functions and Object.prototype.

  Also the property descriptor conversions (ToPropertyDescriptor,
  FromPropertyDescriptor) and integrity levels (freeze, seal) the other
  built-ins use.
}
unit Js.Builtins.Objects;

{$mode objfpc}{$H+}
{$R-}{$Q-}

interface

uses
  SysUtils,
  Js.Values,
  Js.Strings,
  Js.Symbols,
  Js.Atoms,
  Js.Shapes,
  Js.Runtime,
  Js.Objects,
  Js.Functions,
  Js.Conversions,
  Js.Operations;

procedure InstallObject(R: TJsRealm);
{ False when it threw. }
function ToPropertyDescriptor(R: TJsRealm; Value: TJsValue; out Desc: TJsPropertyDescriptor): Boolean;
function FromPropertyDescriptor(R: TJsRealm; const Desc: TJsPropertyDescriptor): TJsValue;
{ freeze (Frozen) or seal; False when it threw. }
function SetIntegrityLevel(R: TJsRealm; Target: TJsObject; Frozen: Boolean): Boolean;
function TestIntegrityLevel(R: TJsRealm; Target: TJsObject; Frozen: Boolean; out Outcome: Boolean): Boolean;
{ The class name Object.prototype.toString shows. }
function BuiltinTag(Target: TJsObject): string;

implementation

uses
  Js.Builtins.Arrays;

type
  TNative = TJsNativeCallback;

function RequireObject(R: TJsRealm; Value: TJsValue; const What: string; out Target: TJsObject): Boolean;
begin
  Target := nil;
  if not JsIsObject(Value) then
  begin
    R.ThrowTypeError(What + ' called on non-object');
    Exit(False);
  end;
  Target := JsAsObject(Value);
  Result := True;
end;

function ToPropertyDescriptor(R: TJsRealm; Value: TJsValue; out Desc: TJsPropertyDescriptor): Boolean;
var
  Source: TJsObject;
  Field: TJsValue;
  Present: Integer;

  function Fetch(Name: TJsAtomName; out Found: Boolean): TJsValue;
  begin
    Present := Source.HasProperty(R, R.Atom(Name));
    Found := Present > 0;
    if Present < 0 then
      Exit(JsException);
    if not Found then
      Exit(JsUndefined);
    Result := Source.GetValue(R, R.Atom(Name));
  end;

var
  Found: Boolean;
begin
  Desc.Value := JsUndefined;
  Desc.Getter := JsUndefined;
  Desc.Setter := JsUndefined;
  Desc.Flags := 0;
  Desc.Present := 0;
  if not JsIsObject(Value) then
  begin
    R.ThrowTypeError('Property description must be an object: ' + ValueToPascal(R, Value));
    Exit(False);
  end;
  Source := JsAsObject(Value);
  Field := Fetch(anEnumerable, Found);
  if Field = JsException then
    Exit(False);
  if Found then
  begin
    Desc.Present := Desc.Present or HasEnumerable;
    if ToBoolean(Field) then
      Desc.Flags := Desc.Flags or PropertyEnumerable;
  end;
  Field := Fetch(anConfigurable, Found);
  if Field = JsException then
    Exit(False);
  if Found then
  begin
    Desc.Present := Desc.Present or HasConfigurable;
    if ToBoolean(Field) then
      Desc.Flags := Desc.Flags or PropertyConfigurable;
  end;
  Field := Fetch(anValue, Found);
  if Field = JsException then
    Exit(False);
  if Found then
  begin
    Desc.Present := Desc.Present or HasValue;
    Desc.Value := Field;
  end;
  Field := Fetch(anWritable, Found);
  if Field = JsException then
    Exit(False);
  if Found then
  begin
    Desc.Present := Desc.Present or HasWritable;
    if ToBoolean(Field) then
      Desc.Flags := Desc.Flags or PropertyWritable;
  end;
  Field := Fetch(anGet, Found);
  if Field = JsException then
    Exit(False);
  if Found then
  begin
    if (Field <> JsUndefined) and not JsIsCallable(Field) then
    begin
      R.ThrowTypeError('Getter must be a function: ' + ValueToPascal(R, Field));
      Exit(False);
    end;
    Desc.Present := Desc.Present or HasGetter;
    Desc.Getter := Field;
  end;
  Field := Fetch(anSet, Found);
  if Field = JsException then
    Exit(False);
  if Found then
  begin
    if (Field <> JsUndefined) and not JsIsCallable(Field) then
    begin
      R.ThrowTypeError('Setter must be a function: ' + ValueToPascal(R, Field));
      Exit(False);
    end;
    Desc.Present := Desc.Present or HasSetter;
    Desc.Setter := Field;
  end;
  if ((Desc.Present and (HasGetter or HasSetter)) <> 0) and ((Desc.Present and (HasValue or HasWritable)) <> 0) then
  begin
    R.ThrowTypeError('Invalid property descriptor. Cannot both specify accessors and a value or writable attribute');
    Exit(False);
  end;
  if (Desc.Present and (HasGetter or HasSetter)) <> 0 then
    Desc.Flags := Desc.Flags or PropertyAccessor;
  Result := True;
end;

function FromPropertyDescriptor(R: TJsRealm; const Desc: TJsPropertyDescriptor): TJsValue;
var
  Target: TJsObject;
begin
  Target := R.NewPlainObject;
  if DescriptorIsAccessor(Desc) then
  begin
    Target.DefineData(R, R.Atom(anGet), Desc.Getter);
    Target.DefineData(R, R.Atom(anSet), Desc.Setter);
  end
  else
  begin
    Target.DefineData(R, R.Atom(anValue), Desc.Value);
    Target.DefineData(R, R.Atom(anWritable), JsBoolean((Desc.Flags and PropertyWritable) <> 0));
  end;
  Target.DefineData(R, R.Atom(anEnumerable), JsBoolean((Desc.Flags and PropertyEnumerable) <> 0));
  Target.DefineData(R, R.Atom(anConfigurable), JsBoolean((Desc.Flags and PropertyConfigurable) <> 0));
  Result := JsObjectValue(Target);
end;

function SetIntegrityLevel(R: TJsRealm; Target: TJsObject; Frozen: Boolean): Boolean;
var
  Keys: TJsValueList;
  Index: Integer;
  Desc, Current: TJsPropertyDescriptor;
  Outcome: Integer;
begin
  if Target.PreventExtensions(R) < 0 then
    Exit(False);
  if ((Target.ObjectFlags and ObjectExotic) = 0) and (Target.ElementCount > 0) then
  begin
    if Frozen then
      Target.ObjectFlags := Target.ObjectFlags or ObjectElementsFrozen or ObjectElementsSealed
    else
      Target.ObjectFlags := Target.ObjectFlags or ObjectElementsSealed;
  end;
  if not Target.OwnPropertyKeys(R, KeysAll, Keys) then
    Exit(False);
  for Index := 0 to High(Keys) do
  begin
    if JsIsInteger(Keys[Index]) and (JsAsInteger(Keys[Index]) < Target.ElementCount) and
      ((Target.ObjectFlags and ObjectExotic) = 0) and (Target.Elements^[JsAsInteger(Keys[Index])] <> JsHole) then
      Continue;
    Desc.Value := JsUndefined;
    Desc.Getter := JsUndefined;
    Desc.Setter := JsUndefined;
    Desc.Flags := 0;
    Desc.Present := HasConfigurable;
    if Frozen then
    begin
      Outcome := Target.GetOwnProperty(R, Keys[Index], Current);
      if Outcome < 0 then
        Exit(False);
      if (Outcome > 0) and not DescriptorIsAccessor(Current) then
        Desc.Present := Desc.Present or HasWritable;
    end;
    if Target.DefineOwnProperty(R, Keys[Index], Desc, True) < 0 then
      Exit(False);
  end;
  if (Target.ObjectClass = ocArray) and Frozen then
    Target.ObjectFlags := Target.ObjectFlags or ObjectLengthReadOnly;
  if (Target.ObjectFlags and ObjectIsPrototype) <> 0 then
    Inc(R.Runtime.PrototypeEpoch);
  Result := True;
end;

function TestIntegrityLevel(R: TJsRealm; Target: TJsObject; Frozen: Boolean; out Outcome: Boolean): Boolean;
var
  Keys: TJsValueList;
  Index, Found: Integer;
  Desc: TJsPropertyDescriptor;
begin
  Outcome := False;
  Found := Target.IsExtensible(R);
  if Found < 0 then
    Exit(False);
  Result := True;
  if Found > 0 then
    Exit;
  if not Target.OwnPropertyKeys(R, KeysAll, Keys) then
    Exit(False);
  for Index := 0 to High(Keys) do
  begin
    Found := Target.GetOwnProperty(R, Keys[Index], Desc);
    if Found < 0 then
      Exit(False);
    if Found = 0 then
      Continue;
    if (Desc.Flags and PropertyConfigurable) <> 0 then
      Exit;
    if Frozen and not DescriptorIsAccessor(Desc) and ((Desc.Flags and PropertyWritable) <> 0) then
      Exit;
  end;
  Outcome := True;
end;

function BuiltinTag(Target: TJsObject): string;
begin
  case Target.ObjectClass of
    ocArray: Result := 'Array';
    ocFunction: Result := 'Function';
    ocError: Result := 'Error';
    ocBoolean: Result := 'Boolean';
    ocNumber: Result := 'Number';
    ocString: Result := 'String';
    ocDate: Result := 'Date';
    ocRegExp: Result := 'RegExp';
    ocArguments: Result := 'Arguments';
  else
    if Target.IsCallable then
      Result := 'Function'
    else
      Result := 'Object';
  end;
end;

{ The constructor }

function ObjectConstructor(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Value: TJsValue;
  Prototype: TJsObject;
begin
  if (NewTarget <> JsUndefined) and (NewTarget <> JsObjectValue(Callee)) then
  begin
    Prototype := PrototypeFromConstructor(R, NewTarget, inObjectPrototype);
    if Prototype = nil then
      Exit(JsException);
    Exit(JsObjectValue(R.NewObject(Prototype)));
  end;
  Value := Arg(Args, ArgCount, 0);
  if JsIsNullish(Value) then
    Exit(JsObjectValue(R.NewPlainObject));
  Result := ToObject(R, Value);
end;

function ObjectGetPrototypeOf(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Value: TJsValue;
  Prototype: TJsObject;
begin
  Value := ToObject(R, Arg(Args, ArgCount, 0));
  if Value = JsException then
    Exit(JsException);
  if not JsAsObject(Value).GetPrototype(R, Prototype) then
    Exit(JsException);
  if Prototype = nil then
    Exit(JsNull);
  Result := JsObjectValue(Prototype);
end;

function ObjectSetPrototypeOf(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Value, Prototype: TJsValue;
  Outcome: Integer;
begin
  Value := Arg(Args, ArgCount, 0);
  Prototype := Arg(Args, ArgCount, 1);
  if JsIsNullish(Value) then
    Exit(R.ThrowTypeError('Object.setPrototypeOf called on null or undefined'));
  if not JsIsObject(Prototype) and (Prototype <> JsNull) then
    Exit(R.ThrowTypeError('Object prototype may only be an Object or null: ' + ValueToPascal(R, Prototype)));
  if not JsIsObject(Value) then
    Exit(Value);
  if Prototype = JsNull then
    Outcome := JsAsObject(Value).SetPrototype(R, nil)
  else
    Outcome := JsAsObject(Value).SetPrototype(R, JsAsObject(Prototype));
  if Outcome < 0 then
    Exit(JsException);
  if Outcome = 0 then
    Exit(R.ThrowTypeError('Cyclic __proto__ value or object not extensible'));
  Result := Value;
end;

function DefineProperties(R: TJsRealm; Target: TJsObject; Properties: TJsValue): Boolean;
var
  Source: TJsObject;
  Keys: TJsValueList;
  Descriptors: array of TJsPropertyDescriptor;
  Chosen: TJsValueList;
  Index, Count, Found: Integer;
  Desc: TJsPropertyDescriptor;
  Field: TJsValue;
begin
  Properties := ToObject(R, Properties);
  if Properties = JsException then
    Exit(False);
  Source := JsAsObject(Properties);
  if not Source.OwnPropertyKeys(R, KeysAll, Keys) then
    Exit(False);
  Descriptors := nil;
  Chosen := nil;
  SetLength(Descriptors, Length(Keys));
  SetLength(Chosen, Length(Keys));
  Count := 0;
  for Index := 0 to High(Keys) do
  begin
    Found := Source.GetOwnProperty(R, Keys[Index], Desc);
    if Found < 0 then
      Exit(False);
    if (Found = 0) or ((Desc.Flags and PropertyEnumerable) = 0) then
      Continue;
    Field := Source.Get(R, Keys[Index], Properties);
    if Field = JsException then
      Exit(False);
    if not ToPropertyDescriptor(R, Field, Descriptors[Count]) then
      Exit(False);
    Chosen[Count] := Keys[Index];
    Inc(Count);
  end;
  for Index := 0 to Count - 1 do
    if Target.DefineOwnProperty(R, Chosen[Index], Descriptors[Index], True) < 0 then
      Exit(False);
  Result := True;
end;

function ObjectCreate(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Prototype, Properties: TJsValue;
  Target: TJsObject;
begin
  Prototype := Arg(Args, ArgCount, 0);
  if Prototype = JsNull then
    Target := R.NewObject(nil)
  else if JsIsObject(Prototype) then
  begin
    Target := R.NewObject(JsAsObject(Prototype));
    R.NoteIsPrototype(JsAsObject(Prototype));
  end
  else
    Exit(R.ThrowTypeError('Object prototype may only be an Object or null: ' + ValueToPascal(R, Prototype)));
  Properties := Arg(Args, ArgCount, 1);
  if Properties <> JsUndefined then
    if not DefineProperties(R, Target, Properties) then
      Exit(JsException);
  Result := JsObjectValue(Target);
end;

function ObjectDefineProperty(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Target: TJsObject;
  Key: TJsValue;
  Desc: TJsPropertyDescriptor;
begin
  if not RequireObject(R, Arg(Args, ArgCount, 0), 'Object.defineProperty', Target) then
    Exit(JsException);
  Key := ToPropertyKey(R, Arg(Args, ArgCount, 1));
  if Key = JsException then
    Exit(JsException);
  if not ToPropertyDescriptor(R, Arg(Args, ArgCount, 2), Desc) then
    Exit(JsException);
  if Target.DefineOwnProperty(R, Key, Desc, True) < 0 then
    Exit(JsException);
  Result := JsObjectValue(Target);
end;

function ObjectDefineProperties(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Target: TJsObject;
begin
  if not RequireObject(R, Arg(Args, ArgCount, 0), 'Object.defineProperties', Target) then
    Exit(JsException);
  if not DefineProperties(R, Target, Arg(Args, ArgCount, 1)) then
    Exit(JsException);
  Result := JsObjectValue(Target);
end;

function ObjectGetOwnPropertyDescriptor(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Value, Key: TJsValue;
  Desc: TJsPropertyDescriptor;
  Found: Integer;
begin
  Value := ToObject(R, Arg(Args, ArgCount, 0));
  if Value = JsException then
    Exit(JsException);
  Key := ToPropertyKey(R, Arg(Args, ArgCount, 1));
  if Key = JsException then
    Exit(JsException);
  Found := JsAsObject(Value).GetOwnProperty(R, Key, Desc);
  if Found < 0 then
    Exit(JsException);
  if Found = 0 then
    Exit(JsUndefined);
  Result := FromPropertyDescriptor(R, Desc);
end;

function ObjectGetOwnPropertyDescriptors(R: TJsRealm; const This: TJsValue; Args: PJsValueArray;
  ArgCount: Integer; Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Value: TJsValue;
  Keys: TJsValueList;
  Outcome: TJsObject;
  Desc: TJsPropertyDescriptor;
  Index, Found: Integer;
begin
  Value := ToObject(R, Arg(Args, ArgCount, 0));
  if Value = JsException then
    Exit(JsException);
  if not JsAsObject(Value).OwnPropertyKeys(R, KeysAll, Keys) then
    Exit(JsException);
  Outcome := R.NewPlainObject;
  for Index := 0 to High(Keys) do
  begin
    Found := JsAsObject(Value).GetOwnProperty(R, Keys[Index], Desc);
    if Found < 0 then
      Exit(JsException);
    if Found > 0 then
      Outcome.CreateDataProperty(R, Keys[Index], FromPropertyDescriptor(R, Desc));
  end;
  Result := JsObjectValue(Outcome);
end;

{ Keys, values or entries (Kind 0, 1, 2) of the own enumerable string
  properties. }
function EnumerableOwn(R: TJsRealm; Value: TJsValue; Kind: Integer): TJsValue;
var
  Target: TJsObject;
  Keys: TJsValueList;
  Outcome: TJsArray;
  Pair: TJsArray;
  Index, Found, Mark: Integer;
  Desc: TJsPropertyDescriptor;
  Field, KeyText: TJsValue;
begin
  Value := ToObject(R, Value);
  if Value = JsException then
    Exit(JsException);
  Target := JsAsObject(Value);
  if not Target.OwnPropertyKeys(R, KeysStrings, Keys) then
    Exit(JsException);
  Outcome := R.NewArray(0);
  Mark := R.Runtime.PushRoot(JsObjectValue(Outcome));
  try
    for Index := 0 to High(Keys) do
    begin
      if ((Target.ObjectFlags and ObjectExotic) = 0) and JsIsInteger(Keys[Index]) and
        (JsAsInteger(Keys[Index]) < Target.ElementCount) and (Target.Elements^[JsAsInteger(Keys[Index])] <> JsHole) then
        Found := 1
      else
      begin
        Found := Target.GetOwnProperty(R, Keys[Index], Desc);
        if Found < 0 then
          Exit(JsException);
        if (Found > 0) and ((Desc.Flags and PropertyEnumerable) = 0) then
          Found := 0;
      end;
      if Found = 0 then
        Continue;
      KeyText := KeyToStringValue(R, Keys[Index]);
      if Kind = 0 then
      begin
        Outcome.CreateDataProperty(R, JsInteger(Outcome.ArrayLength), KeyText);
        Continue;
      end;
      Field := Target.Get(R, Keys[Index], Value);
      if Field = JsException then
        Exit(JsException);
      if Kind = 1 then
        Outcome.CreateDataProperty(R, JsInteger(Outcome.ArrayLength), Field)
      else
      begin
        Pair := R.NewArray(0);
        Pair.CreateDataProperty(R, JsInteger(0), KeyText);
        Pair.CreateDataProperty(R, JsInteger(1), Field);
        Outcome.CreateDataProperty(R, JsInteger(Outcome.ArrayLength), JsObjectValue(Pair));
      end;
    end;
  finally
    R.Runtime.PopRoots(Mark);
  end;
  Result := JsObjectValue(Outcome);
end;

function ObjectKeys(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
begin
  Result := EnumerableOwn(R, Arg(Args, ArgCount, 0), Callee.Magic);
end;

function OwnKeysOfKind(R: TJsRealm; Value: TJsValue; Filter: Integer): TJsValue;
var
  Keys: TJsValueList;
  Outcome: TJsArray;
  Index: Integer;
begin
  Value := ToObject(R, Value);
  if Value = JsException then
    Exit(JsException);
  if not JsAsObject(Value).OwnPropertyKeys(R, Filter, Keys) then
    Exit(JsException);
  Outcome := R.NewArray(0);
  for Index := 0 to High(Keys) do
    Outcome.CreateDataProperty(R, JsInteger(Index), KeyToStringValue(R, Keys[Index]));
  Result := JsObjectValue(Outcome);
end;

function ObjectGetOwnPropertyNames(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
begin
  if Callee.Magic = 0 then
    Result := OwnKeysOfKind(R, Arg(Args, ArgCount, 0), KeysStrings)
  else
    Result := OwnKeysOfKind(R, Arg(Args, ArgCount, 0), KeysSymbols);
end;

function ObjectAssign(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  TargetValue, Source, Field: TJsValue;
  From: TJsObject;
  Keys: TJsValueList;
  Index, KeyIndex, Found: Integer;
  Desc: TJsPropertyDescriptor;
begin
  TargetValue := ToObject(R, Arg(Args, ArgCount, 0));
  if TargetValue = JsException then
    Exit(JsException);
  for Index := 1 to ArgCount - 1 do
  begin
    Source := Args^[Index];
    if JsIsNullish(Source) then
      Continue;
    Source := ToObject(R, Source);
    if Source = JsException then
      Exit(JsException);
    From := JsAsObject(Source);
    if not From.OwnPropertyKeys(R, KeysAll, Keys) then
      Exit(JsException);
    for KeyIndex := 0 to High(Keys) do
    begin
      Found := From.GetOwnProperty(R, Keys[KeyIndex], Desc);
      if Found < 0 then
        Exit(JsException);
      if (Found = 0) or ((Desc.Flags and PropertyEnumerable) = 0) then
        Continue;
      Field := From.Get(R, Keys[KeyIndex], Source);
      if Field = JsException then
        Exit(JsException);
      if not SetPropertyByKey(R, TargetValue, Keys[KeyIndex], Field, True) then
        Exit(JsException);
    end;
  end;
  Result := TargetValue;
end;

function ObjectFreeze(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Value: TJsValue;
  Outcome: Boolean;
begin
  Value := Arg(Args, ArgCount, 0);
  case Callee.Magic of
    0, 1:
      begin
        if not JsIsObject(Value) then
          Exit(Value);
        if not SetIntegrityLevel(R, JsAsObject(Value), Callee.Magic = 0) then
          Exit(JsException);
        Result := Value;
      end;
    2:
      begin
        if not JsIsObject(Value) then
          Exit(Value);
        if JsAsObject(Value).PreventExtensions(R) < 0 then
          Exit(JsException);
        Result := Value;
      end;
    3, 4:
      begin
        if not JsIsObject(Value) then
          Exit(JsTrue);
        if not TestIntegrityLevel(R, JsAsObject(Value), Callee.Magic = 3, Outcome) then
          Exit(JsException);
        Result := JsBoolean(Outcome);
      end;
  else
    if not JsIsObject(Value) then
      Exit(JsFalse);
    case JsAsObject(Value).IsExtensible(R) of
      -1: Result := JsException;
      0: Result := JsFalse;
    else
      Result := JsTrue;
    end;
  end;
end;

function ObjectIs(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
begin
  Result := JsBoolean(SameValue(Arg(Args, ArgCount, 0), Arg(Args, ArgCount, 1), R.Heap));
end;

function ObjectHasOwn(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Value, Key: TJsValue;
  Desc: TJsPropertyDescriptor;
  Found: Integer;
begin
  Value := ToObject(R, Arg(Args, ArgCount, 0));
  if Value = JsException then
    Exit(JsException);
  Key := ToPropertyKey(R, Arg(Args, ArgCount, 1));
  if Key = JsException then
    Exit(JsException);
  Found := JsAsObject(Value).GetOwnProperty(R, Key, Desc);
  if Found < 0 then
    Exit(JsException);
  Result := JsBoolean(Found > 0);
end;

function ObjectFromEntries(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Entries: TJsValueList;
  Outcome: TJsObject;
  Index, Mark: Integer;
  Key, Value: TJsValue;
begin
  if not IterableToList(R, Arg(Args, ArgCount, 0), Entries) then
    Exit(JsException);
  Outcome := R.NewPlainObject;
  Mark := R.Runtime.PushRoot(JsObjectValue(Outcome));
  try
    for Index := 0 to High(Entries) do
    begin
      if not JsIsObject(Entries[Index]) then
        Exit(R.ThrowTypeError('Iterator value ' + ValueToPascal(R, Entries[Index]) + ' is not an entry object'));
      Key := GetPropertyByKey(R, Entries[Index], JsInteger(0));
      if Key = JsException then
        Exit(JsException);
      Value := GetPropertyByKey(R, Entries[Index], JsInteger(1));
      if Value = JsException then
        Exit(JsException);
      Key := ToPropertyKey(R, Key);
      if Key = JsException then
        Exit(JsException);
      Outcome.CreateDataProperty(R, Key, Value);
    end;
  finally
    R.Runtime.PopRoots(Mark);
  end;
  Result := JsObjectValue(Outcome);
end;

function ObjectGroupBy(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Items: TJsValueList;
  Outcome: TJsObject;
  Group: TJsValue;
  Index, Mark: Integer;
  Pair: array[0..1] of TJsValue;
  Key: TJsValue;
  Bucket: TJsArray;
begin
  if not JsIsCallable(Arg(Args, ArgCount, 1)) then
    Exit(R.ThrowTypeError('callback is not a function'));
  if not IterableToList(R, Arg(Args, ArgCount, 0), Items) then
    Exit(JsException);
  Outcome := R.NewObject(nil);
  Mark := R.Runtime.PushRoot(JsObjectValue(Outcome));
  try
    for Index := 0 to High(Items) do
    begin
      Pair[0] := Items[Index];
      Pair[1] := JsInteger(Index);
      Key := R.Call(Args^[1], JsUndefined, @Pair[0], 2);
      if Key = JsException then
        Exit(JsException);
      Key := ToPropertyKey(R, Key);
      if Key = JsException then
        Exit(JsException);
      Group := Outcome.GetValue(R, Key);
      if Group = JsUndefined then
      begin
        Bucket := R.NewArray(0);
        Outcome.CreateDataProperty(R, Key, JsObjectValue(Bucket));
      end
      else
        Bucket := TJsArray(JsAsObject(Group));
      Bucket.CreateDataProperty(R, JsInteger(Bucket.ArrayLength), Items[Index]);
    end;
  finally
    R.Runtime.PopRoots(Mark);
  end;
  Result := JsObjectValue(Outcome);
end;

{ Object.prototype }

function ObjectPrototypeHasOwnProperty(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Key, Value: TJsValue;
  Desc: TJsPropertyDescriptor;
  Found: Integer;
begin
  Key := ToPropertyKey(R, Arg(Args, ArgCount, 0));
  if Key = JsException then
    Exit(JsException);
  Value := ToObject(R, This);
  if Value = JsException then
    Exit(JsException);
  Found := JsAsObject(Value).GetOwnProperty(R, Key, Desc);
  if Found < 0 then
    Exit(JsException);
  Result := JsBoolean(Found > 0);
end;

function ObjectPrototypeIsPrototypeOf(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Value, Self_: TJsValue;
  Walk: TJsObject;
begin
  Value := Arg(Args, ArgCount, 0);
  if not JsIsObject(Value) then
    Exit(JsFalse);
  Self_ := ToObject(R, This);
  if Self_ = JsException then
    Exit(JsException);
  if not JsAsObject(Value).GetPrototype(R, Walk) then
    Exit(JsException);
  while Walk <> nil do
  begin
    if Walk = JsAsObject(Self_) then
      Exit(JsTrue);
    if not Walk.GetPrototype(R, Walk) then
      Exit(JsException);
  end;
  Result := JsFalse;
end;

function ObjectPrototypePropertyIsEnumerable(R: TJsRealm; const This: TJsValue; Args: PJsValueArray;
  ArgCount: Integer; Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Key, Value: TJsValue;
  Desc: TJsPropertyDescriptor;
  Found: Integer;
begin
  Key := ToPropertyKey(R, Arg(Args, ArgCount, 0));
  if Key = JsException then
    Exit(JsException);
  Value := ToObject(R, This);
  if Value = JsException then
    Exit(JsException);
  Found := JsAsObject(Value).GetOwnProperty(R, Key, Desc);
  if Found < 0 then
    Exit(JsException);
  Result := JsBoolean((Found > 0) and ((Desc.Flags and PropertyEnumerable) <> 0));
end;

function ObjectPrototypeToString(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Value, Tag: TJsValue;
  Name: string;
  ValueIsArray: Boolean;
begin
  if This = JsUndefined then
    Exit(R.NewString('[object Undefined]'));
  if This = JsNull then
    Exit(R.NewString('[object Null]'));
  Value := ToObject(R, This);
  if Value = JsException then
    Exit(JsException);
  { IsArray first: a proxy of an array is one (until it is revoked). }
  if not IsArray(R, Value, ValueIsArray) then
    Exit(JsException);
  if ValueIsArray then
    Name := 'Array'
  else
    Name := BuiltinTag(JsAsObject(Value));
  Tag := JsAsObject(Value).GetValue(R, R.Runtime.SymbolValue(wsToStringTag));
  if Tag = JsException then
    Exit(JsException);
  if JsIsString(Tag) then
    Name := StringToUtf8(R.Heap, JsAsString(Tag));
  Result := R.NewString('[object ' + Name + ']');
end;

function ObjectPrototypeToLocaleString(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
begin
  Result := CallMethod(R, This, anToString, nil, 0);
end;

function ObjectPrototypeValueOf(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
begin
  Result := ToObject(R, This);
end;

function ObjectPrototypeGetProto(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Value: TJsValue;
  Prototype: TJsObject;
begin
  Value := ToObject(R, This);
  if Value = JsException then
    Exit(JsException);
  if not JsAsObject(Value).GetPrototype(R, Prototype) then
    Exit(JsException);
  if Prototype = nil then
    Exit(JsNull);
  Result := JsObjectValue(Prototype);
end;

function ObjectPrototypeSetProto(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Prototype: TJsValue;
  Outcome: Integer;
begin
  if JsIsNullish(This) then
    Exit(R.ThrowTypeError('Object.prototype.__proto__ called on null or undefined'));
  Prototype := Arg(Args, ArgCount, 0);
  if not JsIsObject(This) or (not JsIsObject(Prototype) and (Prototype <> JsNull)) then
    Exit(JsUndefined);
  if Prototype = JsNull then
    Outcome := JsAsObject(This).SetPrototype(R, nil)
  else
    Outcome := JsAsObject(This).SetPrototype(R, JsAsObject(Prototype));
  if Outcome < 0 then
    Exit(JsException);
  if Outcome = 0 then
    Exit(R.ThrowTypeError('Cyclic __proto__ value'));
  Result := JsUndefined;
end;

procedure InstallObject(R: TJsRealm);
var
  Prototype: TJsObject;
  Constructor_: TJsNativeFunction;
  Getter, Setter: TJsNativeFunction;
begin
  Prototype := R.Intrinsics[inObjectPrototype];
  Constructor_ := DefineConstructor(R, R.GlobalObject, 'Object', @ObjectConstructor, 1, Prototype);
  R.Intrinsics[inObject] := Constructor_;
  DefineMethod(R, Constructor_, 'getPrototypeOf', @ObjectGetPrototypeOf, 1);
  DefineMethod(R, Constructor_, 'setPrototypeOf', @ObjectSetPrototypeOf, 2);
  DefineMethod(R, Constructor_, 'create', @ObjectCreate, 2);
  DefineMethod(R, Constructor_, 'defineProperty', @ObjectDefineProperty, 3);
  DefineMethod(R, Constructor_, 'defineProperties', @ObjectDefineProperties, 2);
  DefineMethod(R, Constructor_, 'getOwnPropertyDescriptor', @ObjectGetOwnPropertyDescriptor, 2);
  DefineMethod(R, Constructor_, 'getOwnPropertyDescriptors', @ObjectGetOwnPropertyDescriptors, 1);
  DefineMethod(R, Constructor_, 'getOwnPropertyNames', @ObjectGetOwnPropertyNames, 1, 0);
  DefineMethod(R, Constructor_, 'getOwnPropertySymbols', @ObjectGetOwnPropertyNames, 1, 1);
  DefineMethod(R, Constructor_, 'keys', @ObjectKeys, 1, 0);
  DefineMethod(R, Constructor_, 'values', @ObjectKeys, 1, 1);
  DefineMethod(R, Constructor_, 'entries', @ObjectKeys, 1, 2);
  DefineMethod(R, Constructor_, 'assign', @ObjectAssign, 2);
  DefineMethod(R, Constructor_, 'freeze', @ObjectFreeze, 1, 0);
  DefineMethod(R, Constructor_, 'seal', @ObjectFreeze, 1, 1);
  DefineMethod(R, Constructor_, 'preventExtensions', @ObjectFreeze, 1, 2);
  DefineMethod(R, Constructor_, 'isFrozen', @ObjectFreeze, 1, 3);
  DefineMethod(R, Constructor_, 'isSealed', @ObjectFreeze, 1, 4);
  DefineMethod(R, Constructor_, 'isExtensible', @ObjectFreeze, 1, 5);
  DefineMethod(R, Constructor_, 'is', @ObjectIs, 2);
  DefineMethod(R, Constructor_, 'hasOwn', @ObjectHasOwn, 2);
  DefineMethod(R, Constructor_, 'fromEntries', @ObjectFromEntries, 1);
  DefineMethod(R, Constructor_, 'groupBy', @ObjectGroupBy, 2);

  DefineMethod(R, Prototype, 'hasOwnProperty', @ObjectPrototypeHasOwnProperty, 1);
  DefineMethod(R, Prototype, 'isPrototypeOf', @ObjectPrototypeIsPrototypeOf, 1);
  DefineMethod(R, Prototype, 'propertyIsEnumerable', @ObjectPrototypePropertyIsEnumerable, 1);
  DefineMethod(R, Prototype, 'toString', @ObjectPrototypeToString, 0);
  DefineMethod(R, Prototype, 'toLocaleString', @ObjectPrototypeToLocaleString, 0);
  DefineMethod(R, Prototype, 'valueOf', @ObjectPrototypeValueOf, 0);
  Getter := NewNativeFunction(R, 'get __proto__', @ObjectPrototypeGetProto, 0);
  Setter := NewNativeFunction(R, 'set __proto__', @ObjectPrototypeSetProto, 1);
  Prototype.DefineAccessor(R, R.Intern('__proto__'), JsObjectValue(Getter), JsObjectValue(Setter),
    PropertyConfigurable);
end;

end.
