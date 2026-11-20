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
  WebIDL's conversions of JavaScript values to IDL values, driven by the
  type table: boolean, the integer types (with [EnforceRange] and
  [Clamp]), the floating point types, DOMString (with
  [LegacyNullToEmptyString]), USVString, ByteString, object, interface
  types, callback functions and interfaces, dictionaries (members read
  in order, defaults, required members), enumerations, sequences,
  records, nullable types and unions (the union algorithm's order:
  platform objects, callables, iterables, dictionaries and objects,
  booleans, numbers, strings). Overload resolution picks by argument
  count; optional arguments take their defaults.
}
unit Web.Bindings.Conversions;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Math,
  Js.Values,
  Js.Strings,
  Js.Symbols,
  Js.Shapes,
  Js.Runtime,
  Js.Objects,
  Js.Functions,
  Js.Conversions,
  Js.Operations,
  Web.Bindings.Types,
  Web.Bindings.Strings,
  Web.Bindings.Context,
  Web.Bindings.Tables;

{ Converts Value to the type; raises EBindingTypeError (What names the
  value in the message) or EBindingPendingException. }
procedure ConvertValue(Context: TBindingContext; Value: TJsValue; TypeIndex: Integer; out Converted: TBindingValue;
  const What: string);
{ The arguments of Call for the member's (or constructor's) overloads. }
procedure ConvertArguments(Context: TBindingContext; var Call: TBindingCall; FirstOverload, OverloadCount: Integer;
  const What: string);
{ The name of an interface. }
function InterfaceName(InterfaceId: Integer): string;

implementation

function InterfaceName(InterfaceId: Integer): string;
begin
  Result := BindingInterfaces[InterfaceId].Name;
end;

procedure ClearValue(out Converted: TBindingValue);
begin
  Converted.Kind := bvMissing;
  Converted.UnionMember := -1;
  Converted.Flag := False;
  Converted.Number := 0;
  Converted.Text := '';
  Converted.Native := nil;
  Converted.Script := JsUndefined;
  Converted.Items := nil;
  Converted.Keys := nil;
end;

function NumberOf(Context: TBindingContext; Value: TJsValue): Double;
begin
  if JsIsInteger(Value) then
    Exit(JsAsInteger(Value));
  if not ToDouble(Context.Engine.Realm, Value, Result) then
    raise EBindingPendingException.Create('');
end;

{ Rounds to the nearest integer, ties to even. }
function RoundHalfEven(Value: Double): Double;
var
  Floor_: Double;
begin
  Floor_ := Floor(Value);
  if Value - Floor_ > 0.5 then
    Result := Floor_ + 1
  else if Value - Floor_ < 0.5 then
    Result := Floor_
  else if Frac(Floor_ / 2) = 0 then
    Result := Floor_
  else
    Result := Floor_ + 1;
end;

function ConvertInteger(Context: TBindingContext; Value: TJsValue; Kind: TBindingTypeKind; Flags: Byte;
  const What: string): Double;
var
  Lower, Upper, Modulus, Number: Double;
begin
  case Kind of
    tkByte:
      begin Lower := -128; Upper := 127; Modulus := 256; end;
    tkOctet:
      begin Lower := 0; Upper := 255; Modulus := 256; end;
    tkShort:
      begin Lower := -32768; Upper := 32767; Modulus := 65536; end;
    tkUnsignedShort:
      begin Lower := 0; Upper := 65535; Modulus := 65536; end;
    tkLong:
      begin Lower := -2147483648.0; Upper := 2147483647.0; Modulus := 4294967296.0; end;
    tkUnsignedLong:
      begin Lower := 0; Upper := 4294967295.0; Modulus := 4294967296.0; end;
    tkLongLong:
      begin Lower := -9007199254740991.0; Upper := 9007199254740991.0; Modulus := 18446744073709551616.0; end;
  else
    begin Lower := 0; Upper := 9007199254740991.0; Modulus := 18446744073709551616.0; end;
  end;
  if JsIsInteger(Value) and (Flags and (TypeEnforceRange or TypeClamp) = 0) then
  begin
    Number := JsAsInteger(Value);
    if (Number >= Lower) and (Number <= Upper) then
      Exit(Number);
  end
  else
    Number := NumberOf(Context, Value);
  if (Flags and TypeEnforceRange) <> 0 then
  begin
    if IsNan(Number) or IsInfinite(Number) then
      RaiseTypeError(What + ' is not a finite number');
    Number := Int(Number);
    if (Number < Lower) or (Number > Upper) then
      RaiseTypeError(What + ' is outside the accepted range');
    Exit(Number);
  end;
  if (Flags and TypeClamp) <> 0 then
  begin
    if IsNan(Number) then
      Exit(0);
    Number := Min(Max(Number, Lower), Upper);
    Exit(RoundHalfEven(Number));
  end;
  if IsNan(Number) or IsInfinite(Number) then
    Exit(0);
  Number := Int(Number);
  if Number = 0 then
    Exit(0);
  if (Number >= Lower) and (Number <= Upper) then
    Exit(Number);
  Number := Number - Modulus * Floor(Number / Modulus);
  if Number > Upper then
    Number := Number - Modulus;
  Result := Number;
end;

function ConvertString(Context: TBindingContext; Value: TJsValue; Kind: TBindingTypeKind): string;
var
  Text: TJsString;
  Index: Integer;
begin
  Text := ToJsString(Context.Engine.Realm, Value);
  if Text = nil then
    raise EBindingPendingException.Create('');
  case Kind of
    tkUsvString:
      Result := JsStringToText(Context.Engine.Runtime.Heap, Text, False);
    tkByteString:
      begin
        Text.Flatten(Context.Engine.Runtime.Heap);
        SetLength(Result, Text.Length);
        for Index := 0 to Text.Length - 1 do
        begin
          if Text.CharAt(Index) > 255 then
            RaiseTypeError('the string has characters above U+00FF');
          Result[Index + 1] := Chr(Text.CharAt(Index));
        end;
      end;
  else
    Result := JsStringToText(Context.Engine.Runtime.Heap, Text, True);
  end;
end;

function GetMember(Context: TBindingContext; Target: TJsValue; const Name: string): TJsValue;
begin
  Result := GetProperty(Context.Engine.Realm, Target, Context.Engine.Realm.Intern(Name));
  if Result = JsException then
    raise EBindingPendingException.Create('');
end;

procedure ConvertDefault(Context: TBindingContext; TypeIndex: Integer; DefaultText: PChar;
  out Converted: TBindingValue; const What: string);
var
  Text: string;
begin
  Text := DefaultText;
  if (Text = '{}') and not (BindingTypes[TypeIndex].Kind in [tkDictionary, tkUnion]) then
    ClearValue(Converted)
  else if (Text = '{}') or (Text = 'undefined') then
    ConvertValue(Context, JsUndefined, TypeIndex, Converted, What)
  else if Text = '[]' then
  begin
    ClearValue(Converted);
    Converted.Kind := bvSequence;
  end
  else if Text = 'null' then
  begin
    ClearValue(Converted);
    Converted.Kind := bvNull;
    Converted.Script := JsNull;
  end
  else if (Text = 'true') or (Text = 'false') then
    ConvertValue(Context, JsBoolean(Text = 'true'), TypeIndex, Converted, What)
  else if (Text <> '') and (Text[1] = '"') then
    ConvertValue(Context, Context.TextValue(Copy(Text, 2, Length(Text) - 2)), TypeIndex, Converted, What)
  else
    ConvertValue(Context, JsNumber(StrToFloat(Text, DefaultFormatSettings)), TypeIndex, Converted, What);
end;

procedure ConvertDictionary(Context: TBindingContext; Value: TJsValue; DictionaryIndex: Integer;
  out Converted: TBindingValue; const What: string);
var
  Index: Integer;
  Member: PBindingArgument;
  MemberValue: TJsValue;
  Range: TBindingRange;
begin
  ClearValue(Converted);
  if not JsIsNullish(Value) and not JsIsObject(Value) then
    RaiseTypeError(What + ' is not an object');
  Converted.Kind := bvDictionary;
  Converted.Script := Value;
  Range := BindingDictionaries[DictionaryIndex];
  SetLength(Converted.Items, Range.Count);
  for Index := 0 to Range.Count - 1 do
  begin
    Member := @BindingDictionaryMembers[Range.First + Index];
    if JsIsObject(Value) then
      MemberValue := GetMember(Context, Value, Member^.Name)
    else
      MemberValue := JsUndefined;
    if MemberValue <> JsUndefined then
      ConvertValue(Context, MemberValue, Member^.TypeIndex, Converted.Items[Index], string(Member^.Name))
    else if (Member^.Flags and ArgumentHasDefault) <> 0 then
      ConvertDefault(Context, Member^.TypeIndex, Member^.DefaultValue, Converted.Items[Index], string(Member^.Name))
    else if (Member^.Flags and DictionaryMemberRequired) <> 0 then
      RaiseTypeError(What + ' has no ' + string(Member^.Name))
    else
      ClearValue(Converted.Items[Index]);
  end;
end;

procedure ConvertSequence(Context: TBindingContext; Value: TJsValue; ElementType: Integer;
  out Converted: TBindingValue; const What: string);
var
  Iterator: TJsIteratorRecord;
  Element: TJsValue;
  Count: Integer;
  R: TJsRealm;
begin
  ClearValue(Converted);
  R := Context.Engine.Realm;
  if not JsIsObject(Value) then
    RaiseTypeError(What + ' is not iterable');
  if not GetIterator(R, Value, False, Iterator) then
    raise EBindingPendingException.Create('');
  Converted.Kind := bvSequence;
  Converted.Script := Value;
  Count := 0;
  while IteratorStep(R, Iterator, Element) do
  begin
    if Count >= Length(Converted.Items) then
      SetLength(Converted.Items, Count * 2 + 4);
    ConvertValue(Context, Element, ElementType, Converted.Items[Count], What + ' item');
    Inc(Count);
  end;
  if R.HasException then
    raise EBindingPendingException.Create('');
  SetLength(Converted.Items, Count);
end;

procedure ConvertRecord(Context: TBindingContext; Value: TJsValue; ValueType: Integer;
  out Converted: TBindingValue; const What: string);
var
  Keys: TJsValueList;
  Index, Count, Found: Integer;
  Target: TJsObject;
  Desc: TJsPropertyDescriptor;
  R: TJsRealm;
  KeyValue: TJsValue;
begin
  ClearValue(Converted);
  R := Context.Engine.Realm;
  if not JsIsObject(Value) then
    RaiseTypeError(What + ' is not an object');
  Target := JsAsObject(Value);
  if not Target.OwnPropertyKeys(R, KeysStrings, Keys) then
    raise EBindingPendingException.Create('');
  Converted.Kind := bvRecord;
  Converted.Script := Value;
  SetLength(Converted.Keys, Length(Keys));
  SetLength(Converted.Items, Length(Keys));
  Count := 0;
  for Index := 0 to High(Keys) do
  begin
    Found := Target.GetOwnProperty(R, Keys[Index], Desc);
    if Found < 0 then
      raise EBindingPendingException.Create('');
    if (Found = 0) or ((Desc.Flags and PropertyEnumerable) = 0) then
      Continue;
    KeyValue := KeyToStringValue(R, Keys[Index]);
    Converted.Keys[Count] := ConvertString(Context, KeyValue, tkUsvString);
    ConvertValue(Context, GetPropertyByKey(R, Value, Keys[Index]), ValueType, Converted.Items[Count], What);
    Inc(Count);
  end;
  SetLength(Converted.Keys, Count);
  SetLength(Converted.Items, Count);
end;

function IsNumericKind(Kind: TBindingTypeKind): Boolean;
begin
  Result := Kind in [tkByte, tkOctet, tkShort, tkUnsignedShort, tkLong, tkUnsignedLong, tkLongLong,
    tkUnsignedLongLong, tkFloat, tkUnrestrictedFloat, tkDouble, tkUnrestrictedDouble];
end;

function HasIteratorMethod(Context: TBindingContext; Value: TJsValue): Boolean;
var
  Method: TJsValue;
begin
  Method := GetMethod(Context.Engine.Realm, Value, Context.Engine.Runtime.SymbolValue(wsIterator));
  if Method = JsException then
    raise EBindingPendingException.Create('');
  Result := Method <> JsUndefined;
end;

procedure ConvertUnion(Context: TBindingContext; Value: TJsValue; const UnionType: TBindingType;
  out Converted: TBindingValue; const What: string);
var
  Index, Member, Found: Integer;
  MemberKind: TBindingTypeKind;

  function FindKind(Kinds: array of TBindingTypeKind): Integer;
  var
    Position, KindIndex: Integer;
  begin
    for Position := 0 to UnionType.Count - 1 do
      for KindIndex := 0 to High(Kinds) do
        if BindingTypes[BindingUnionMembers[UnionType.Reference + Position]].Kind = Kinds[KindIndex] then
          Exit(Position);
    Result := -1;
  end;

  procedure Take(Position: Integer);
  begin
    ConvertValue(Context, Value, BindingUnionMembers[UnionType.Reference + Position], Converted, What);
    Converted.UnionMember := Position;
  end;

begin
  if JsIsNullish(Value) then
  begin
    Found := FindKind([tkDictionary]);
    if Found >= 0 then
    begin
      Take(Found);
      Exit;
    end;
  end;
  if JsIsObject(Value) then
  begin
    for Index := 0 to UnionType.Count - 1 do
    begin
      Member := BindingUnionMembers[UnionType.Reference + Index];
      if (BindingTypes[Member].Kind = tkInterface) and
        (Context.Unwrap(Value, BindingTypes[Member].Reference) <> nil) then
      begin
        Take(Index);
        Exit;
      end;
    end;
    if JsIsCallable(Value) then
    begin
      Found := FindKind([tkCallback]);
      if Found >= 0 then
      begin
        Take(Found);
        Exit;
      end;
    end;
    Found := FindKind([tkSequence]);
    if (Found >= 0) and HasIteratorMethod(Context, Value) then
    begin
      Take(Found);
      Exit;
    end;
    Found := FindKind([tkDictionary, tkRecord, tkCallbackInterface, tkObject, tkAny]);
    if Found >= 0 then
    begin
      Take(Found);
      Exit;
    end;
  end;
  if JsIsBoolean(Value) then
  begin
    Found := FindKind([tkBoolean]);
    if Found >= 0 then
    begin
      Take(Found);
      Exit;
    end;
  end;
  if JsIsNumber(Value) then
    for Index := 0 to UnionType.Count - 1 do
    begin
      MemberKind := BindingTypes[BindingUnionMembers[UnionType.Reference + Index]].Kind;
      if IsNumericKind(MemberKind) then
      begin
        Take(Index);
        Exit;
      end;
    end;
  Found := FindKind([tkDomString, tkUsvString, tkByteString, tkEnum]);
  if Found >= 0 then
  begin
    Take(Found);
    Exit;
  end;
  for Index := 0 to UnionType.Count - 1 do
    if IsNumericKind(BindingTypes[BindingUnionMembers[UnionType.Reference + Index]].Kind) then
    begin
      Take(Index);
      Exit;
    end;
  Found := FindKind([tkBoolean]);
  if Found >= 0 then
  begin
    Take(Found);
    Exit;
  end;
  RaiseTypeError(What + ' is not of an accepted type');
end;

procedure ConvertValue(Context: TBindingContext; Value: TJsValue; TypeIndex: Integer; out Converted: TBindingValue;
  const What: string);
var
  BindingType: PBindingType;
  Range: TBindingRange;
  Index: Integer;
  Native: TObject;
begin
  BindingType := @BindingTypes[TypeIndex];
  if (BindingType^.Kind = tkUnion) then
  begin
    if ((BindingType^.Flags and TypeNullable) <> 0) and JsIsNullish(Value) then
    begin
      ClearValue(Converted);
      Converted.Kind := bvNull;
      Converted.Script := JsNull;
      Exit;
    end;
    ConvertUnion(Context, Value, BindingType^, Converted, What);
    Exit;
  end;
  ClearValue(Converted);
  Converted.Script := Value;
  if ((BindingType^.Flags and TypeNullable) <> 0) and JsIsNullish(Value) and (BindingType^.Kind <> tkAny) then
  begin
    Converted.Kind := bvNull;
    Exit;
  end;
  case BindingType^.Kind of
    tkAny:
      if Value = JsUndefined then
        Converted.Kind := bvUndefined
      else if Value = JsNull then
        Converted.Kind := bvNull
      else
        Converted.Kind := bvScript;
    tkUndefined:
      Converted.Kind := bvUndefined;
    tkBoolean:
      begin
        Converted.Kind := bvBoolean;
        Converted.Flag := ToBoolean(Value);
      end;
    tkByte, tkOctet, tkShort, tkUnsignedShort, tkLong, tkUnsignedLong, tkLongLong, tkUnsignedLongLong:
      begin
        Converted.Kind := bvNumber;
        Converted.Number := ConvertInteger(Context, Value, BindingType^.Kind, BindingType^.Flags, What);
      end;
    tkFloat, tkDouble, tkUnrestrictedFloat, tkUnrestrictedDouble:
      begin
        Converted.Kind := bvNumber;
        Converted.Number := NumberOf(Context, Value);
        if (BindingType^.Kind in [tkFloat, tkDouble]) and
          (IsNan(Converted.Number) or IsInfinite(Converted.Number)) then
          RaiseTypeError(What + ' is not a finite number');
      end;
    tkDomString, tkUsvString, tkByteString:
      begin
        Converted.Kind := bvString;
        if ((BindingType^.Flags and TypeNullToEmptyString) <> 0) and (Value = JsNull) then
          Converted.Text := ''
        else if JsIsSymbol(Value) then
          RaiseTypeError(What + ': a symbol is not a string')
        else
          Converted.Text := ConvertString(Context, Value, BindingType^.Kind);
      end;
    tkObject:
      begin
        if not JsIsObject(Value) then
          RaiseTypeError(What + ' is not an object');
        Converted.Kind := bvScript;
      end;
    tkInterface:
      begin
        Native := Context.Unwrap(Value, BindingType^.Reference);
        if (Native = nil) or (Native = Context.Window) and (BindingType^.Reference <> InterfaceWindow) and
          not Context.IsInterface(InterfaceWindow, BindingType^.Reference) then
          RaiseTypeError(What + ' is not of type ' + InterfaceName(BindingType^.Reference));
        Converted.Kind := bvNative;
        Converted.Native := Native;
      end;
    tkCallback:
      begin
        if not JsIsCallable(Value) then
        begin
          if (BindingType^.Flags and TypeTreatNonObjectAsNull) <> 0 then
          begin
            Converted.Kind := bvNull;
            Converted.Script := JsNull;
            Exit;
          end;
          RaiseTypeError(What + ' is not a function');
        end;
        Converted.Kind := bvScript;
      end;
    tkCallbackInterface:
      begin
        if not JsIsObject(Value) then
          RaiseTypeError(What + ' is not an object');
        Converted.Kind := bvScript;
      end;
    tkDictionary:
      ConvertDictionary(Context, Value, BindingType^.Reference, Converted, What);
    tkEnum:
      begin
        if JsIsSymbol(Value) then
          RaiseTypeError(What + ': a symbol is not a string');
        Converted.Text := ConvertString(Context, Value, tkDomString);
        Range := BindingEnums[BindingType^.Reference];
        for Index := 0 to Range.Count - 1 do
          if BindingEnumValues[Range.First + Index] = Converted.Text then
          begin
            Converted.Kind := bvString;
            Converted.Number := Index;
            Exit;
          end;
        RaiseTypeError('''' + Converted.Text + ''' is not a valid value for ' + What);
      end;
    tkSequence:
      ConvertSequence(Context, Value, BindingType^.Reference, Converted, What);
    tkRecord:
      ConvertRecord(Context, Value, BindingType^.Reference, Converted, What);
    tkPromise:
      Converted.Kind := bvScript;
  end;
end;

function ChooseOverload(FirstOverload, OverloadCount, PassedCount: Integer): Integer;
var
  Index, Best: Integer;
  Overload: PBindingOverload;
begin
  if OverloadCount = 1 then
    Exit(FirstOverload);
  Best := -1;
  for Index := FirstOverload to FirstOverload + OverloadCount - 1 do
  begin
    Overload := @BindingOverloads[Index];
    if Overload^.RequiredCount > PassedCount then
      Continue;
    if (Best < 0) or (Overload^.ArgumentCount <= PassedCount) and
      (Overload^.ArgumentCount > BindingOverloads[Best].ArgumentCount) then
      Best := Index;
  end;
  if Best < 0 then
    Best := FirstOverload;
  Result := Best;
end;

procedure ConvertArguments(Context: TBindingContext; var Call: TBindingCall; FirstOverload, OverloadCount: Integer;
  const What: string);
var
  Overload: PBindingOverload;
  Argument: PBindingArgument;
  Index, Count, Position: Integer;
  Value: TJsValue;
begin
  Call.Overload := ChooseOverload(FirstOverload, OverloadCount, Call.PassedCount);
  Overload := @BindingOverloads[Call.Overload];
  if Call.PassedCount < Overload^.RequiredCount then
    RaiseTypeError(What + ': ' + IntToStr(Overload^.RequiredCount) + ' argument(s) required, but only ' +
      IntToStr(Call.PassedCount) + ' present');
  Count := Overload^.ArgumentCount;
  if (Count > 0) and ((BindingArguments[Overload^.FirstArgument + Count - 1].Flags and ArgumentVariadic) <> 0) and
    (Call.PassedCount > Count) then
    SetLength(Call.Arguments, Call.PassedCount)
  else
    SetLength(Call.Arguments, Count);
  for Index := 0 to High(Call.Arguments) do
  begin
    Position := Index;
    if Position >= Count then
      Position := Count - 1;
    Argument := @BindingArguments[Overload^.FirstArgument + Position];
    if Index < Call.PassedCount then
      Value := Call.RawArguments^[Index]
    else
      Value := JsUndefined;
    if (Index >= Call.PassedCount) or (Value = JsUndefined) and ((Argument^.Flags and ArgumentOptional) <> 0) then
    begin
      if (Argument^.Flags and ArgumentHasDefault) <> 0 then
        ConvertDefault(Context, Argument^.TypeIndex, Argument^.DefaultValue, Call.Arguments[Index],
          string(Argument^.Name))
      else if (Argument^.Flags and ArgumentOptional) <> 0 then
        ClearValue(Call.Arguments[Index])
      else
        ConvertValue(Context, Value, Argument^.TypeIndex, Call.Arguments[Index], string(Argument^.Name));
    end
    else
      ConvertValue(Context, Value, Argument^.TypeIndex, Call.Arguments[Index], string(Argument^.Name));
  end;
  if (Count > 0) and ((BindingArguments[Overload^.FirstArgument + Count - 1].Flags and ArgumentVariadic) <> 0) and
    (Call.PassedCount < Count) then
    SetLength(Call.Arguments, Count - 1);
end;

end.
