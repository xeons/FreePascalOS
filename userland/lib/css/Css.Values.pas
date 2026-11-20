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
  Specified values: what a declaration's value parses to.

  A value is an immutable, reference counted node: a keyword, a number
  or dimension, a color, a string or URL, a custom identifier, a math
  function, a list (space, comma or slash separated), a function with
  arguments (gradients, transforms, counters, ...), or the raw tokens of
  a value that still has var() in it (and of custom properties).

  Ownership: a new value has one reference, held by whoever created
  it; containers (lists, functions, declarations, computed styles)
  hold one reference to each value in them. AddRef shares a value,
  Release drops a reference and frees it with the last one.
}
unit Css.Values;

{$mode objfpc}
{$H+}

interface

uses
  Css.Tokens, Css.Units, Css.Keywords, Css.Colors, Css.Calc;

type
  TCssValueKind = (vkKeyword, vkNumber, vkInteger, vkPercentage, vkDimension, vkColor,
    vkString, vkUrl, vkCustomIdent, vkCalc, vkList, vkFunction, vkUnparsed);

  TCssListSeparator = (lsSpace, lsComma, lsSlash);

  TCssValue = class;
  TCssValueArray = array of TCssValue;

  TCssValue = class
  private
    FReferences: LongInt;
  public
    Kind: TCssValueKind;
    Keyword: TCssKeyword;
    Number: Double;
    UnitValue: TCssUnit;
    Color: TCssColor;
    { String, URL, custom identifier, function name (lowercase). }
    Text: string;
    Items: TCssValueArray;
    Separator: TCssListSeparator;
    Calc: TCssCalcNode;
    { The tokens of an unparsed value (one with var(), or a custom
      property's), ending with EOF. }
    Tokens: TCssTokenArray;
    { An unparsed value of a longhand that came from a shorthand: the
      shorthand's property id (else -1). }
    Shorthand: Integer;
    constructor Create(AKind: TCssValueKind);
    destructor Destroy; override;
    function AddRef: TCssValue;
    procedure Release;
    procedure Add(Item: TCssValue);
    function Count: Integer;
    function IsKeyword(Wanted: TCssKeyword): Boolean; inline;
    { Whether this is a number, dimension or percentage of value 0. }
    function IsZero: Boolean;
    function Serialize: string;
    function Equals(Other: TCssValue): Boolean; reintroduce;
    property References: LongInt read FReferences;
  end;

function NewKeyword(Keyword: TCssKeyword): TCssValue;
function NewNumber(Value: Double): TCssValue;
function NewInteger(Value: Integer): TCssValue;
function NewPercentage(Value: Double): TCssValue;
function NewDimension(Value: Double; UnitValue: TCssUnit): TCssValue;
function NewColor(const Color: TCssColor): TCssValue;
function NewString(const Text: string): TCssValue;
function NewUrl(const Url: string): TCssValue;
function NewCustomIdent(const Name: string): TCssValue;
function NewCalc(Node: TCssCalcNode): TCssValue;
function NewList(Separator: TCssListSeparator): TCssValue;
function NewFunction(const Name: string): TCssValue;
function NewUnparsed(const Tokens: TCssTokenArray): TCssValue;
{ A list of the given items (taking their references). }
function NewListOf(Separator: TCssListSeparator; const Items: array of TCssValue): TCssValue;
{ A bracketed list of grid line names. }
function NewLineNames: TCssValue;

procedure ReleaseValue(var Value: TCssValue);
function SerializeValueOrEmpty(Value: TCssValue): string;
function CssWideKeyword(Keyword: TCssKeyword): Boolean; inline;

{ Live value nodes (for the memory report). }
var
  LiveValueCount: Integer = 0;

implementation

uses
  SysUtils, Css.Serialization;

constructor TCssValue.Create(AKind: TCssValueKind);
begin
  inherited Create;
  Kind := AKind;
  FReferences := 1;
  Shorthand := -1;
  InterlockedIncrement(LiveValueCount);
end;

destructor TCssValue.Destroy;
var
  Index: Integer;
begin
  for Index := 0 to High(Items) do
    Items[Index].Release;
  Calc.Free;
  InterlockedDecrement(LiveValueCount);
  inherited Destroy;
end;

function TCssValue.AddRef: TCssValue;
begin
  if Self <> nil then
    InterlockedIncrement(FReferences);
  Result := Self;
end;

procedure TCssValue.Release;
begin
  if Self = nil then
    Exit;
  if InterlockedDecrement(FReferences) = 0 then
    Free;
end;

procedure TCssValue.Add(Item: TCssValue);
begin
  SetLength(Items, Length(Items) + 1);
  Items[High(Items)] := Item;
end;

function TCssValue.Count: Integer;
begin
  Result := Length(Items);
end;

function TCssValue.IsKeyword(Wanted: TCssKeyword): Boolean;
begin
  Result := (Self <> nil) and (Kind = vkKeyword) and (Keyword = Wanted);
end;

function TCssValue.IsZero: Boolean;
begin
  Result := (Kind in [vkNumber, vkInteger, vkPercentage, vkDimension]) and (Number = 0);
end;

function SerializeItems(Value: TCssValue): string;
var
  Index: Integer;
  Glue: string;
begin
  case Value.Separator of
    lsComma: Glue := ', ';
    lsSlash: Glue := ' / ';
  else
    Glue := ' ';
  end;
  Result := '';
  for Index := 0 to High(Value.Items) do
  begin
    if Index > 0 then
      Result := Result + Glue;
    Result := Result + Value.Items[Index].Serialize;
  end;
end;

{ A family name of several identifiers keeps its spaces. }
function SerializeIdentifierWords(const Text: string): string;
var
  Words: TStringArray;
  Index: Integer;
begin
  if Pos(' ', Text) = 0 then
    Exit(SerializeIdentifier(Text));
  Words := Text.Split([' ']);
  Result := '';
  for Index := 0 to High(Words) do
  begin
    if Index > 0 then
      Result := Result + ' ';
    Result := Result + SerializeIdentifier(Words[Index]);
  end;
end;

function TCssValue.Serialize: string;
begin
  case Kind of
    vkKeyword: Result := KeywordName(Keyword);
    vkNumber: Result := SerializeNumber(Number);
    vkInteger: Result := IntToStr(Round(Number));
    vkPercentage: Result := SerializeNumber(Number) + '%';
    vkDimension: Result := SerializeNumber(Number) + CssUnitName(UnitValue);
    vkColor: Result := SerializeColor(Color);
    vkString: Result := SerializeString(Text);
    vkUrl: Result := SerializeUrl(Text);
    vkCustomIdent: Result := SerializeIdentifierWords(Text);
    vkCalc: Result := SerializeCalc(Calc);
    vkList:
      if Text = '[' then
        Result := '[' + SerializeItems(Self) + ']'
      else
        Result := SerializeItems(Self);
    vkFunction: Result := Text + '(' + SerializeItems(Self) + ')';
    vkUnparsed: Result := SerializeTokenArray(Tokens);
  else
    Result := '';
  end;
end;

function TCssValue.Equals(Other: TCssValue): Boolean;
var
  Index: Integer;
begin
  if Self = Other then
    Exit(True);
  if (Self = nil) or (Other = nil) or (Kind <> Other.Kind) then
    Exit(False);
  case Kind of
    vkKeyword: Result := Keyword = Other.Keyword;
    vkNumber, vkInteger, vkPercentage: Result := Number = Other.Number;
    vkDimension: Result := (Number = Other.Number) and (UnitValue = Other.UnitValue);
    vkColor: Result := SameColor(Color, Other.Color);
    vkString, vkUrl, vkCustomIdent: Result := Text = Other.Text;
    vkList, vkFunction:
      begin
        Result := (Text = Other.Text) and (Separator = Other.Separator) and (Length(Items) = Length(Other.Items));
        if Result then
          for Index := 0 to High(Items) do
            if not Items[Index].Equals(Other.Items[Index]) then
              Exit(False);
      end;
  else
    Result := Serialize = Other.Serialize;
  end;
end;

function NewKeyword(Keyword: TCssKeyword): TCssValue;
begin
  Result := TCssValue.Create(vkKeyword);
  Result.Keyword := Keyword;
end;

function NewNumber(Value: Double): TCssValue;
begin
  Result := TCssValue.Create(vkNumber);
  Result.Number := Value;
end;

function NewInteger(Value: Integer): TCssValue;
begin
  Result := TCssValue.Create(vkInteger);
  Result.Number := Value;
end;

function NewPercentage(Value: Double): TCssValue;
begin
  Result := TCssValue.Create(vkPercentage);
  Result.Number := Value;
  Result.UnitValue := cuPercent;
end;

function NewDimension(Value: Double; UnitValue: TCssUnit): TCssValue;
begin
  Result := TCssValue.Create(vkDimension);
  Result.Number := Value;
  Result.UnitValue := UnitValue;
end;

function NewColor(const Color: TCssColor): TCssValue;
begin
  Result := TCssValue.Create(vkColor);
  Result.Color := Color;
end;

function NewString(const Text: string): TCssValue;
begin
  Result := TCssValue.Create(vkString);
  Result.Text := Text;
end;

function NewUrl(const Url: string): TCssValue;
begin
  Result := TCssValue.Create(vkUrl);
  Result.Text := Url;
end;

function NewCustomIdent(const Name: string): TCssValue;
begin
  Result := TCssValue.Create(vkCustomIdent);
  Result.Text := Name;
end;

function NewCalc(Node: TCssCalcNode): TCssValue;
begin
  Result := TCssValue.Create(vkCalc);
  Result.Calc := Node;
end;

function NewList(Separator: TCssListSeparator): TCssValue;
begin
  Result := TCssValue.Create(vkList);
  Result.Separator := Separator;
end;

function NewFunction(const Name: string): TCssValue;
begin
  Result := TCssValue.Create(vkFunction);
  Result.Text := Name;
  Result.Separator := lsComma;
end;

function NewUnparsed(const Tokens: TCssTokenArray): TCssValue;
begin
  Result := TCssValue.Create(vkUnparsed);
  Result.Tokens := Tokens;
end;

function NewListOf(Separator: TCssListSeparator; const Items: array of TCssValue): TCssValue;
var
  Index: Integer;
begin
  Result := NewList(Separator);
  for Index := 0 to High(Items) do
    if Items[Index] <> nil then
      Result.Add(Items[Index]);
end;

function NewLineNames: TCssValue;
begin
  Result := NewList(lsSpace);
  Result.Text := '[';
end;

procedure ReleaseValue(var Value: TCssValue);
begin
  if Value <> nil then
  begin
    Value.Release;
    Value := nil;
  end;
end;

function SerializeValueOrEmpty(Value: TCssValue): string;
begin
  if Value = nil then
    Result := ''
  else
    Result := Value.Serialize;
end;

function CssWideKeyword(Keyword: TCssKeyword): Boolean;
begin
  Result := (Keyword >= kwInitial) and (Keyword <= kwRevertLayer);
end;

end.
