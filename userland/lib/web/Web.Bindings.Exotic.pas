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
  Legacy platform objects (WebIDL 3.9): wrappers of interfaces with an
  indexed or named getter (NodeList, HTMLCollection, NamedNodeMap,
  DOMTokenList, DOMStringMap, CSSStyleDeclaration's indices) answer the
  internal methods through the special operations: [[GetOwnProperty]]
  gives the supported indices and the visible named properties (not
  shadowed by the prototype chain unless [LegacyOverrideBuiltIns]),
  [[DefineOwnProperty]] and [[Set]] go to a named setter, [[Delete]] to
  a named deleter, [[OwnPropertyKeys]] lists indices, then names, then
  the object's own properties.
}
unit Web.Bindings.Exotic;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Js.Values,
  Js.Heap,
  Js.Strings,
  Js.Runtime,
  Js.Shapes,
  Js.Objects,
  Js.Conversions,
  Web.Bindings.Types,
  Web.Bindings.Strings,
  Web.Bindings.Context,
  Web.Bindings.Tables,
  Web.Bindings.Dispatch;

type
  TIndexedWrapper = class(TBindingWrapper)
  private
    function Info: PBindingInterface;
    function IndexedItem(R: TJsRealm; Index: LongInt; out Value: TJsValue): Integer;
    function NamedItem(R: TJsRealm; Key: TJsValue; out Value: TJsValue): Integer;
    function NameIsShadowed(R: TJsRealm; Key: TJsValue): Integer;
    function CallNamedSetter(R: TJsRealm; Key, Value: TJsValue): Integer;
  public
    function GetOwnProperty(R: TJsRealm; Key: TJsValue; out Desc: TJsPropertyDescriptor): Integer; override;
    function DefineOwnProperty(R: TJsRealm; Key: TJsValue; const Desc: TJsPropertyDescriptor;
      ThrowOnFailure: Boolean): Integer; override;
    function SetValue(R: TJsRealm; Key, Value, Receiver: TJsValue): Integer; override;
    function DeleteProperty(R: TJsRealm; Key: TJsValue): Integer; override;
    function OwnPropertyKeys(R: TJsRealm; Filter: Integer; out Keys: TJsValueList): Boolean; override;
  end;

implementation

function TIndexedWrapper.Info: PBindingInterface;
begin
  Result := @BindingInterfaces[Binding.InterfaceId];
end;

function KeyIsIndex(Key: TJsValue; out Index: LongInt): Boolean;
begin
  Result := JsIsInteger(Key) and (JsAsInteger(Key) >= 0);
  if Result then
    Index := JsAsInteger(Key)
  else
    Index := -1;
end;

{ 1 with Value, 0 when the index is not supported, -1 thrown. }
function TIndexedWrapper.IndexedItem(R: TJsRealm; Index: LongInt; out Value: TJsValue): Integer;
var
  Arguments: TBindingValueArray;
  Member: Integer;
begin
  Value := JsUndefined;
  Member := Info^.IndexedGetter;
  if (Member < 0) or (NativeData = nil) then
    Exit(0);
  SetLength(Arguments, 1);
  Arguments[0].Kind := bvNumber;
  Arguments[0].Number := Index;
  if not CallSpecial(Binding.Context, BindingMembers[Member].Getter, Self, Binding.InterfaceId, Arguments, Value) then
    Exit(-1);
  if JsIsNullish(Value) then
    Exit(0);
  Result := 1;
end;

function TIndexedWrapper.NamedItem(R: TJsRealm; Key: TJsValue; out Value: TJsValue): Integer;
var
  Arguments: TBindingValueArray;
  Member: Integer;
begin
  Value := JsUndefined;
  Member := Info^.NamedGetter;
  if (Member < 0) or not JsIsString(Key) or (NativeData = nil) then
    Exit(0);
  SetLength(Arguments, 1);
  Arguments[0].Kind := bvString;
  Arguments[0].Text := JsStringToText(R.Heap, JsAsString(Key));
  if not CallSpecial(Binding.Context, BindingMembers[Member].Getter, Self, Binding.InterfaceId, Arguments, Value) then
    Exit(-1);
  if JsIsNullish(Value) then
    Exit(0);
  Result := 1;
end;

{ The named property visibility algorithm: 1 when an own or inherited
  property hides the name. }
function TIndexedWrapper.NameIsShadowed(R: TJsRealm; Key: TJsValue): Integer;
var
  PropertyFlags: Byte;
begin
  if (Info^.Flags and InterfaceOverrideBuiltIns) <> 0 then
  begin
    if Shape.Find(Key, PropertyFlags) >= 0 then
      Exit(1);
    Exit(0);
  end;
  if Shape.Find(Key, PropertyFlags) >= 0 then
    Exit(1);
  if Proto = nil then
    Exit(0);
  Result := Proto.HasProperty(R, Key);
end;

function TIndexedWrapper.GetOwnProperty(R: TJsRealm; Key: TJsValue; out Desc: TJsPropertyDescriptor): Integer;
var
  Index: LongInt;
  Value: TJsValue;
  Found: Integer;
  Flags: Byte;
begin
  if KeyIsIndex(Key, Index) and (Info^.IndexedGetter >= 0) then
  begin
    Found := IndexedItem(R, Index, Value);
    if Found <> 0 then
    begin
      if Found > 0 then
        Desc := DataDescriptor(Value, PropertyEnumerable or PropertyConfigurable);
      Exit(Found);
    end;
    Exit(inherited GetOwnProperty(R, Key, Desc));
  end;
  if (Info^.NamedGetter >= 0) and JsIsString(Key) then
  begin
    Found := NameIsShadowed(R, Key);
    if Found < 0 then
      Exit(-1);
    if Found = 0 then
    begin
      Found := NamedItem(R, Key, Value);
      if Found <> 0 then
      begin
        if Found > 0 then
        begin
          Flags := PropertyConfigurable;
          if (Info^.Flags and InterfaceUnenumerableNamedProperties) = 0 then
            Flags := Flags or PropertyEnumerable;
          if Assigned(Info^.NamedSetter) then
            Flags := Flags or PropertyWritable;
          Desc := DataDescriptor(Value, Flags);
        end;
        Exit(Found);
      end;
    end;
  end;
  Result := inherited GetOwnProperty(R, Key, Desc);
end;

function TIndexedWrapper.CallNamedSetter(R: TJsRealm; Key, Value: TJsValue): Integer;
var
  Arguments: TBindingValueArray;
  Text: TJsString;
  Ignored: TJsValue;
begin
  SetLength(Arguments, 2);
  Arguments[0].Kind := bvString;
  Arguments[0].Text := JsStringToText(R.Heap, JsAsString(Key));
  Text := ToJsString(R, Value);
  if Text = nil then
    Exit(-1);
  Arguments[1].Kind := bvString;
  Arguments[1].Text := JsStringToText(R.Heap, Text);
  if not CallSpecial(Binding.Context, Info^.NamedSetter, Self, Binding.InterfaceId, Arguments, Ignored) then
    Exit(-1);
  Result := 1;
end;

function TIndexedWrapper.DefineOwnProperty(R: TJsRealm; Key: TJsValue; const Desc: TJsPropertyDescriptor;
  ThrowOnFailure: Boolean): Integer;
var
  Index: LongInt;
begin
  if KeyIsIndex(Key, Index) and (Info^.IndexedGetter >= 0) then
  begin
    if ThrowOnFailure then
    begin
      R.ThrowTypeError('cannot define an index of this collection');
      Exit(-1);
    end;
    Exit(0);
  end;
  if Assigned(Info^.NamedSetter) and JsIsString(Key) and ((Desc.Present and (HasGetter or HasSetter)) = 0) then
  begin
    if (Info^.Flags and InterfaceOverrideBuiltIns) <> 0 then
      Exit(CallNamedSetter(R, Key, Desc.Value));
    if NameIsShadowed(R, Key) = 0 then
      Exit(CallNamedSetter(R, Key, Desc.Value));
  end;
  Result := inherited DefineOwnProperty(R, Key, Desc, ThrowOnFailure);
end;

function TIndexedWrapper.SetValue(R: TJsRealm; Key, Value, Receiver: TJsValue): Integer;
var
  Index: LongInt;
  PropertyFlags: Byte;
begin
  if Receiver = JsObjectValue(Self) then
  begin
    if Assigned(Info^.NamedSetter) and JsIsString(Key) then
      if ((Info^.Flags and InterfaceOverrideBuiltIns) <> 0) or (Shape.Find(Key, PropertyFlags) < 0) and
        ((Proto = nil) or (Proto.HasProperty(R, Key) = 0)) then
        Exit(CallNamedSetter(R, Key, Value));
    if KeyIsIndex(Key, Index) and (Info^.IndexedGetter >= 0) then
      Exit(0);
  end;
  Result := inherited SetValue(R, Key, Value, Receiver);
end;

function TIndexedWrapper.DeleteProperty(R: TJsRealm; Key: TJsValue): Integer;
var
  Index: LongInt;
  Value, Ignored: TJsValue;
  Found: Integer;
  Arguments: TBindingValueArray;
begin
  if KeyIsIndex(Key, Index) and (Info^.IndexedGetter >= 0) then
  begin
    Found := IndexedItem(R, Index, Value);
    if Found < 0 then
      Exit(-1);
    if Found > 0 then
      Exit(0);
  end
  else if (Info^.NamedGetter >= 0) and JsIsString(Key) and (NameIsShadowed(R, Key) = 0) then
  begin
    Found := NamedItem(R, Key, Value);
    if Found < 0 then
      Exit(-1);
    if Found > 0 then
    begin
      if not Assigned(Info^.NamedDeleter) then
        Exit(0);
      SetLength(Arguments, 1);
      Arguments[0].Kind := bvString;
      Arguments[0].Text := JsStringToText(R.Heap, JsAsString(Key));
      if not CallSpecial(Binding.Context, Info^.NamedDeleter, Self, Binding.InterfaceId, Arguments, Ignored) then
        Exit(-1);
      Exit(1);
    end;
  end;
  Result := inherited DeleteProperty(R, Key);
end;

function TIndexedWrapper.OwnPropertyKeys(R: TJsRealm; Filter: Integer; out Keys: TJsValueList): Boolean;
var
  Index, Count, Position, Found: LongInt;
  Value, Names: TJsValue;
  Own: TJsValueList;
  Arguments: TBindingValueArray;
begin
  Keys := nil;
  Arguments := nil;
  Count := 0;
  if ((Filter and KeysStrings) <> 0) and (Info^.IndexedGetter >= 0) then
  begin
    Index := 0;
    repeat
      Found := IndexedItem(R, Index, Value);
      if Found < 0 then
        Exit(False);
      if Found > 0 then
      begin
        if Count >= Length(Keys) then
          SetLength(Keys, Count * 2 + 8);
        Keys[Count] := JsInteger(Index);
        Inc(Count);
        Inc(Index);
      end;
    until Found = 0;
  end;
  if ((Filter and KeysStrings) <> 0) and (Info^.NamedGetter >= 0) and Assigned(Info^.SupportedNames) then
  begin
    if not CallSpecial(Binding.Context, Info^.SupportedNames, Self, Binding.InterfaceId, Arguments, Names) then
      Exit(False);
    if JsIsObject(Names) and (JsAsObject(Names) is TJsArray) then
      for Position := 1 to TJsArray(JsAsObject(Names)).ArrayLength do
      begin
        if Count >= Length(Keys) then
          SetLength(Keys, Count * 2 + 8);
        Keys[Count] := ToPropertyKey(R, JsAsObject(Names).GetValue(R, JsInteger(Position - 1)));
        Inc(Count);
      end;
  end;
  if not inherited OwnPropertyKeys(R, Filter, Own) then
    Exit(False);
  SetLength(Keys, Count + Length(Own));
  for Position := 0 to High(Own) do
    Keys[Count + Position] := Own[Position];
  Result := True;
end;

end.
