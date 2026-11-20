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
  Reflected IDL attributes (HTML Standard 2.6.1), driven by the member
  table: strings, URLs (resolved against the document's base URL),
  booleans, long and unsigned long (the rules for parsing integers, a
  default for a missing or bad value, "limited to only positive
  numbers"), double, and enumerated attributes (keywords matched without
  regard to ASCII case, missing and invalid value defaults).
}
unit Web.Bindings.Reflection;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Math,
  Js.Values,
  Js.Conversions,
  Web.Atoms,
  Web.Namespaces,
  Web.Dom,
  Web.Dom.Exceptions,
  Web.Bindings.Types,
  Web.Bindings.Context;

function GetReflected(Context: TBindingContext; Element: TElement; Member: PBindingMember;
  EnumKeywords: PPChar; EnumCount: Integer): TJsValue;
{ Value is already converted to the attribute's type. }
procedure SetReflected(Context: TBindingContext; Element: TElement; Member: PBindingMember;
  const Value: TBindingValue);

{ The HTML rules for parsing integers and floating-point numbers. }
function ParseHtmlInteger(const Text: string; out Value: Int64): Boolean;
function ParseHtmlFloat(const Text: string; out Value: Double): Boolean;

implementation

uses
  Web.Bindings.UrlResolution;

function IsHtmlSpace(Character: Char): Boolean; inline;
begin
  Result := Character in [#9, #10, #12, #13, ' '];
end;

function ParseHtmlInteger(const Text: string; out Value: Int64): Boolean;
var
  Index: Integer;
  Negative: Boolean;
begin
  Value := 0;
  Index := 1;
  while (Index <= Length(Text)) and IsHtmlSpace(Text[Index]) do
    Inc(Index);
  Negative := False;
  if (Index <= Length(Text)) and (Text[Index] in ['-', '+']) then
  begin
    Negative := Text[Index] = '-';
    Inc(Index);
  end;
  if (Index > Length(Text)) or not (Text[Index] in ['0'..'9']) then
    Exit(False);
  while (Index <= Length(Text)) and (Text[Index] in ['0'..'9']) do
  begin
    if Value < 10000000000 then
      Value := Value * 10 + (Ord(Text[Index]) - Ord('0'));
    Inc(Index);
  end;
  if Negative then
    Value := -Value;
  Result := True;
end;

function ParseHtmlFloat(const Text: string; out Value: Double): Boolean;
var
  Index, Start: Integer;
  Number: string;
  Settings: TFormatSettings;
begin
  Value := 0;
  Index := 1;
  while (Index <= Length(Text)) and IsHtmlSpace(Text[Index]) do
    Inc(Index);
  Start := Index;
  if (Index <= Length(Text)) and (Text[Index] in ['-', '+']) then
    Inc(Index);
  while (Index <= Length(Text)) and (Text[Index] in ['0'..'9']) do
    Inc(Index);
  if (Index <= Length(Text)) and (Text[Index] = '.') then
  begin
    Inc(Index);
    while (Index <= Length(Text)) and (Text[Index] in ['0'..'9']) do
      Inc(Index);
  end;
  if (Index <= Length(Text)) and (Text[Index] in ['e', 'E']) then
  begin
    Inc(Index);
    if (Index <= Length(Text)) and (Text[Index] in ['-', '+']) then
      Inc(Index);
    while (Index <= Length(Text)) and (Text[Index] in ['0'..'9']) do
      Inc(Index);
  end;
  Number := Copy(Text, Start, Index - Start);
  if (Number <> '') and (Number[1] = '+') then
    Delete(Number, 1, 1);
  Settings := DefaultFormatSettings;
  Settings.DecimalSeparator := '.';
  Result := TryStrToFloat(Number, Value, Settings) and not IsInfinite(Value) and not IsNan(Value);
end;

function AttributeAtomOf(Member: PBindingMember): TAtom;
begin
  Result := Atomize(string(Member^.Text));
end;

function GetReflected(Context: TBindingContext; Element: TElement; Member: PBindingMember;
  EnumKeywords: PPChar; EnumCount: Integer): TJsValue;
var
  Name: TAtom;
  Index: Integer;
  Text, Resolved: string;
  Number: Int64;
  Real: Double;
begin
  Name := AttributeAtomOf(Member);
  Index := Element.AttributeIndexOf(Name);
  if Index >= 0 then
    Text := Element.AttributeAt(Index)^.Value
  else
    Text := '';
  case Member^.ReflectKind of
    rkBoolean:
      Result := JsBoolean(Index >= 0);
    rkUrl:
      if Index < 0 then
        Result := Context.TextValue('')
      else if ResolveUrlText(Element.NodeDocument, Text, Resolved) then
        Result := Context.TextValue(Resolved)
      else
        Result := Context.TextValue(Text);
    rkLong:
      if (Index >= 0) and ParseHtmlInteger(Text, Number) and (Number >= -2147483648) and (Number <= 2147483647) then
        Result := JsNumber(Number)
      else
        Result := JsNumber(Member^.Value);
    rkUnsignedLong:
      if (Index >= 0) and ParseHtmlInteger(Text, Number) and (Number >= 0) and (Number <= 2147483647) and
        not (((Member^.Flags and MemberReflectPositive) <> 0) and (Number = 0)) then
        Result := JsNumber(Number)
      else
        Result := JsNumber(Member^.Value);
    rkDouble:
      if (Index >= 0) and ParseHtmlFloat(Text, Real) then
        Result := JsNumber(Real)
      else
        Result := JsNumber(Member^.Value);
    rkEnum:
      begin
        if Index < 0 then
          Exit(Context.TextValue(string(Member^.Missing)));
        for Number := 0 to EnumCount - 1 do
          if SameText(string(EnumKeywords[Number]), Text) then
            Exit(Context.TextValue(string(EnumKeywords[Number])));
        if (Text = '') and (Member^.Missing <> nil) and (string(Member^.Missing) = '') then
          Result := Context.TextValue('')
        else
          Result := Context.TextValue(string(Member^.Invalid));
      end;
  else
    Result := Context.TextValue(Text);
  end;
end;

procedure SetReflected(Context: TBindingContext; Element: TElement; Member: PBindingMember;
  const Value: TBindingValue);
var
  Name: TAtom;
  Number: Double;
begin
  Name := AttributeAtomOf(Member);
  case Member^.ReflectKind of
    rkBoolean:
      if Value.Flag then
        Element.SetAttributeAtom(Name, NamespaceNone, '')
      else
        Element.RemoveAttributeAtom(Name);
    rkLong:
      Element.SetAttributeAtom(Name, NamespaceNone, IntToStr(Trunc(Value.Number)));
    rkUnsignedLong:
      begin
        Number := Value.Number;
        if ((Member^.Flags and MemberReflectPositive) <> 0) and (Number = 0) then
          RaiseDomError(IndexSizeError, 'the value must be positive');
        if Number > 2147483647 then
          Number := Member^.Value;
        Element.SetAttributeAtom(Name, NamespaceNone, IntToStr(Trunc(Number)));
      end;
    rkDouble:
      Element.SetAttributeAtom(Name, NamespaceNone, NumberToString(Value.Number));
  else
    Element.SetAttributeAtom(Name, NamespaceNone, Value.Text);
  end;
end;

end.
