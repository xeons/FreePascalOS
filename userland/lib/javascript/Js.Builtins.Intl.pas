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
  A minimal Intl: one locale, en-US, whatever is asked for (locale tags
  are checked and canonicalized, then resolve to en-US).

  NumberFormat: decimal, percent, currency (symbols of the common
  currencies, else the code) and unit styles; fraction, integer and
  significant digits (rounding half away from zero on the exact
  value), grouping, sign display; format, formatToParts,
  resolvedOptions. DateTimeFormat: the en-US patterns for the date and
  time fields and for dateStyle/timeStyle, 12 or 24 hour clocks, the
  local time zone or UTC; format, formatToParts. Collator: code point
  order, case- and accent-insensitive for the base and accent
  sensitivities, numeric collation. PluralRules: the English cardinal
  and ordinal categories. Segmenter: grapheme clusters (combining
  marks, ZWJ emoji sequences, regional indicator pairs, Hangul syllable
  sequences, CR LF), words and sentences. ListFormat: conjunctions,
  disjunctions and unit lists. Number, BigInt and Date toLocaleString
  use them.
}
unit Js.Builtins.Intl;

{$mode objfpc}{$H+}
{$R-}{$Q-}

interface

uses
  Js.Interpreter;

procedure InstallIntl(R: TJsInterpreterRealm);

implementation

uses
  SysUtils,
  Math,
  Character,
  Js.Values,
  Js.Heap,
  Js.Strings,
  Js.Symbols,
  Js.Atoms,
  Js.Shapes,
  Js.Runtime,
  Js.Objects,
  Js.Functions,
  Js.Conversions,
  Js.Operations,
  Js.BigIntegers,
  Js.Platform,
  Js.Normalization,
  Js.Builtins.Number,
  Js.Builtins.Date,
  Js.Builtins.Iterators;

type
  TIntlKind = (ikNumberFormat, ikDateTimeFormat, ikCollator, ikPluralRules, ikSegmenter, ikListFormat);

  TIntlObject = class(TJsObject)
  public
    IntlKind: TIntlKind;
    { Options as text (style, currency, month...), and numbers. }
    Settings: array of string;
    Values: array of string;
    MinimumIntegerDigits, MinimumFractionDigits, MaximumFractionDigits: Integer;
    MinimumSignificantDigits, MaximumSignificantDigits: Integer;
    BoundFunction: TJsValue;
    procedure Trace(Tracer: TJsTracer); override;
    function Setting(const Name: string): string;
    procedure Put(const Name, Value: string);
  end;

  { A segmented string and an iterator over its segments. }
  TSegments = class(TJsObject)
  public
    Input: TJsValue;
    Granularity: string;
    Starts: array of Integer;
    WordLike: array of Boolean;
    Position: Integer;
    procedure Trace(Tracer: TJsTracer); override;
  end;

var
  SegmentsPrototype, SegmentIteratorPrototype: array of TJsObject;

procedure TIntlObject.Trace(Tracer: TJsTracer);
begin
  inherited Trace(Tracer);
  Tracer.MarkValue(BoundFunction);
end;

function TIntlObject.Setting(const Name: string): string;
var
  Index: Integer;
begin
  for Index := 0 to High(Settings) do
    if Settings[Index] = Name then
      Exit(Values[Index]);
  Result := '';
end;

procedure TIntlObject.Put(const Name, Value: string);
begin
  SetLength(Settings, Length(Settings) + 1);
  SetLength(Values, Length(Values) + 1);
  Settings[High(Settings)] := Name;
  Values[High(Values)] := Value;
end;

procedure TSegments.Trace(Tracer: TJsTracer);
begin
  inherited Trace(Tracer);
  Tracer.MarkValue(Input);
end;

{ Locales }

{ A BCP 47 tag, canonical case (en-us: en-US); '' when malformed. }
function CanonicalTag(const Tag: string): string;
var
  Parts: TStringArray;
  Index, Position: Integer;
  Part: string;
begin
  Result := '';
  if Tag = '' then
    Exit;
  Parts := Tag.Split(['-', '_']);
  for Index := 0 to High(Parts) do
  begin
    Part := Parts[Index];
    if (Length(Part) = 0) or (Length(Part) > 8) then
      Exit('');
    for Position := 1 to Length(Part) do
      if not (Part[Position] in ['a'..'z', 'A'..'Z', '0'..'9']) then
        Exit('');
    if Index = 0 then
    begin
      if (Length(Part) < 2) or (Length(Part) > 8) then
        Exit('');
      Part := LowerCase(Part);
    end
    else if Length(Part) = 2 then
      Part := UpperCase(Part)
    else if Length(Part) = 4 then
      Part := UpperCase(Part[1]) + LowerCase(Copy(Part, 2, 3))
    else
      Part := LowerCase(Part);
    if Result <> '' then
      Result := Result + '-';
    Result := Result + Part;
  end;
end;

{ CanonicalizeLocaleList: False (a RangeError or TypeError thrown) when
  a tag is malformed. }
function LocaleList(R: TJsRealm; Locales: TJsValue; out List: TStringArray): Boolean;
var
  Length_, Index: Int64;
  Item: TJsValue;
  Tag: string;
  Items: TJsValueList;
begin
  List := nil;
  if Locales = JsUndefined then
    Exit(True);
  Items := nil;
  if JsIsString(Locales) then
  begin
    SetLength(Items, 1);
    Items[0] := Locales;
  end
  else
  begin
    Item := ToObject(R, Locales);
    if Item = JsException then
      Exit(False);
    if not LengthOfArrayLike(R, JsAsObject(Item), Length_) then
      Exit(False);
    SetLength(Items, Length_);
    for Index := 0 to Length_ - 1 do
    begin
      Items[Index] := JsAsObject(Item).Get(R, IndexKey(R, Index), Item);
      if Items[Index] = JsException then
        Exit(False);
    end;
  end;
  for Index := 0 to High(Items) do
  begin
    if not JsIsString(Items[Index]) and not JsIsObject(Items[Index]) then
    begin
      R.ThrowTypeError('Language ID should be string or object.');
      Exit(False);
    end;
    Item := ToStringValue(R, Items[Index]);
    if Item = JsException then
      Exit(False);
    Tag := CanonicalTag(StringToUtf8(R.Heap, JsAsString(Item)));
    if Tag = '' then
    begin
      R.ThrowRangeError('Incorrect locale information provided');
      Exit(False);
    end;
    SetLength(List, Length(List) + 1);
    List[High(List)] := Tag;
  end;
  Result := True;
end;

function IntlGetCanonicalLocales(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  List: TStringArray;
  Output: TJsArray;
  Index: Integer;
begin
  if not LocaleList(R, Arg(Args, ArgCount, 0), List) then
    Exit(JsException);
  Output := R.NewArray(0);
  for Index := 0 to High(List) do
    Output.CreateDataProperty(R, JsInteger(Index), R.NewString(List[Index]));
  Result := JsObjectValue(Output);
end;

{ supportedLocalesOf: the English ones. }
function IntlSupportedLocales(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  List: TStringArray;
  Output: TJsArray;
  Index: Integer;
begin
  if not LocaleList(R, Arg(Args, ArgCount, 0), List) then
    Exit(JsException);
  Output := R.NewArray(0);
  for Index := 0 to High(List) do
    if (List[Index] = 'en') or (Copy(List[Index], 1, 3) = 'en-') then
      Output.CreateDataProperty(R, JsInteger(LongInt(Output.ArrayLength)), R.NewString(List[Index]));
  Result := JsObjectValue(Output);
end;

{ Options }

{ GetOption for a string: '' when absent; False when it threw or the
  value is not one of Allowed (a RangeError). }
function StringOption(R: TJsRealm; Options: TJsObject; const Name: string; const Allowed: array of string;
  out Value: string): Boolean;
var
  Raw: TJsValue;
  Index: Integer;
begin
  Value := '';
  if Options = nil then
    Exit(True);
  Raw := Options.GetValue(R, R.Intern(Name));
  if Raw = JsException then
    Exit(False);
  if Raw = JsUndefined then
    Exit(True);
  if JsIsBoolean(Raw) and (Length(Allowed) = 0) then
  begin
    if Raw = JsTrue then
      Value := 'true'
    else
      Value := 'false';
    Exit(True);
  end;
  Raw := ToStringValue(R, Raw);
  if Raw = JsException then
    Exit(False);
  Value := StringToUtf8(R.Heap, JsAsString(Raw));
  if Length(Allowed) = 0 then
    Exit(True);
  for Index := 0 to High(Allowed) do
    if Allowed[Index] = Value then
      Exit(True);
  R.ThrowRangeError('Value ' + Value + ' out of range for options property ' + Name);
  Result := False;
end;

function NumberOption(R: TJsRealm; Options: TJsObject; const Name: string; Minimum, Maximum, Default: Integer;
  out Value: Integer): Boolean;
var
  Raw: TJsValue;
  Number: Double;
begin
  Value := Default;
  if Options = nil then
    Exit(True);
  Raw := Options.GetValue(R, R.Intern(Name));
  if Raw = JsException then
    Exit(False);
  if Raw = JsUndefined then
    Exit(True);
  if not ToDouble(R, Raw, Number) then
    Exit(False);
  if IsNaNDouble(Number) or (Number < Minimum) or (Number > Maximum) then
  begin
    R.ThrowRangeError(Name + ' value is out of range.');
    Exit(False);
  end;
  Value := Trunc(Number);
  Result := True;
end;

function OptionsObject(R: TJsRealm; Options: TJsValue; out Target: TJsObject): Boolean;
var
  Converted: TJsValue;
begin
  Target := nil;
  if Options = JsUndefined then
    Exit(True);
  Converted := ToObject(R, Options);
  if Converted = JsException then
    Exit(False);
  Target := JsAsObject(Converted);
  Result := True;
end;

function NewIntl(R: TJsRealm; NewTarget: TJsValue; Kind: TIntlKind; Fallback: TJsObject): TIntlObject;
var
  Prototype: TJsObject;
begin
  Prototype := Fallback;
  if NewTarget <> JsUndefined then
  begin
    Prototype := PrototypeFromConstructor(R, NewTarget, inObjectPrototype);
    if Prototype = nil then
      Exit(nil);
  end;
  Result := TIntlObject(R.NewObjectOfClass(TIntlObject, Prototype, ocObject));
  Result.IntlKind := Kind;
  Result.BoundFunction := JsUndefined;
  Result.Put('locale', 'en-US');
end;

function ThisIntl(R: TJsRealm; Value: TJsValue; Kind: TIntlKind; out Target: TIntlObject): Boolean;
begin
  Target := nil;
  if JsIsObject(Value) and (JsAsObject(Value) is TIntlObject) and (TIntlObject(JsAsObject(Value)).IntlKind = Kind) then
  begin
    Target := TIntlObject(JsAsObject(Value));
    Exit(True);
  end;
  R.ThrowTypeError('Method called on incompatible receiver');
  Result := False;
end;

{ NumberFormat }

const
  CurrencyCodes: array[0..9] of string = ('USD', 'EUR', 'GBP', 'JPY', 'CNY', 'INR', 'KRW', 'CAD', 'AUD', 'MXN');
  CurrencySymbols: array[0..9] of string = ('$', '€', '£', '¥', 'CN¥', '₹', '₩', 'CA$', 'A$', 'MX$');
  CurrencyNames: array[0..9] of string = ('US dollars', 'euros', 'British pounds', 'Japanese yen',
    'Chinese yuan', 'Indian rupees', 'South Korean won', 'Canadian dollars', 'Australian dollars',
    'Mexican pesos');
  UnitNames: array[0..20] of string = ('kilometer', 'meter', 'centimeter', 'millimeter', 'kilogram', 'gram',
    'second', 'minute', 'hour', 'day', 'byte', 'kilobyte', 'megabyte', 'gigabyte', 'celsius', 'fahrenheit',
    'liter', 'mile', 'foot', 'inch', 'percent');
  UnitShort: array[0..20] of string = ('km', 'm', 'cm', 'mm', 'kg', 'g', 'sec', 'min', 'hr', 'day', 'byte', 'kB',
    'MB', 'GB', '°C', '°F', 'L', 'mi', 'ft', 'in', '%');

function CurrencyIndex(const Code: string): Integer;
var
  Index: Integer;
begin
  for Index := 0 to High(CurrencyCodes) do
    if CurrencyCodes[Index] = Code then
      Exit(Index);
  Result := -1;
end;

function UnitIndex(const Name: string): Integer;
var
  Index: Integer;
begin
  for Index := 0 to High(UnitNames) do
    if UnitNames[Index] = Name then
      Exit(Index);
  Result := -1;
end;

function UnitText(const Name: string; Long: Boolean; Plural: Boolean): string;
var
  Split: Integer;
begin
  Split := Pos('-per-', Name);
  if Split > 0 then
  begin
    Result := Copy(Name, Split + 5, MaxInt);
    if Long then
      Exit(UnitText(Copy(Name, 1, Split - 1), True, Plural) + ' per ' + UnitText(Result, True, False));
    { Per hour, per second: h, s. }
    if Result = 'hour' then
      Result := 'h'
    else if Result = 'second' then
      Result := 's'
    else
      Result := UnitText(Result, False, False);
    Exit(UnitText(Copy(Name, 1, Split - 1), False, Plural) + '/' + Result);
  end;
  if Long then
  begin
    Result := Name;
    if Plural then
      Result := Result + 's';
    if Name = 'foot' then
      if Plural then
        Result := 'feet';
    if Name = 'inch' then
      if Plural then
        Result := 'inches';
    Exit;
  end;
  Result := UnitShort[UnitIndex(Name)];
end;

function InitializeNumberFormat(R: TJsRealm; Target: TIntlObject; Locales, OptionsValue: TJsValue): Boolean;
var
  List: TStringArray;
  Options: TJsObject;
  Style, Currency, CurrencyDisplay, UnitName, UnitDisplay, Grouping, Sign, Notation: string;
  Digits, MinimumDefault, MaximumDefault: Integer;
begin
  Result := False;
  if not LocaleList(R, Locales, List) then
    Exit;
  if not OptionsObject(R, OptionsValue, Options) then
    Exit;
  if not StringOption(R, Options, 'style', ['decimal', 'percent', 'currency', 'unit'], Style) or
    not StringOption(R, Options, 'currency', [], Currency) or
    not StringOption(R, Options, 'currencyDisplay', ['symbol', 'narrowSymbol', 'code', 'name'], CurrencyDisplay) or
    not StringOption(R, Options, 'unit', [], UnitName) or
    not StringOption(R, Options, 'unitDisplay', ['short', 'narrow', 'long'], UnitDisplay) or
    not StringOption(R, Options, 'notation', ['standard', 'scientific', 'engineering', 'compact'], Notation) then
    Exit;
  if Style = '' then
    Style := 'decimal';
  Currency := UpperCase(Currency);
  if (Style = 'currency') and (Currency = '') then
    begin R.ThrowTypeError('Currency code is required with currency style.'); Exit; end;
  if (Style = 'unit') and ((UnitName = '') or ((UnitIndex(UnitName) < 0) and (Pos('-per-', UnitName) = 0))) then
    begin R.ThrowRangeError('Invalid unit argument for Intl.NumberFormat() ''' + UnitName + ''''); Exit; end;
  if CurrencyDisplay = '' then
    CurrencyDisplay := 'symbol';
  if UnitDisplay = '' then
    UnitDisplay := 'short';
  if Notation = '' then
    Notation := 'standard';
  Target.Put('style', Style);
  Target.Put('currency', Currency);
  Target.Put('currencyDisplay', CurrencyDisplay);
  Target.Put('unit', UnitName);
  Target.Put('unitDisplay', UnitDisplay);
  Target.Put('notation', Notation);
  MinimumDefault := 0;
  MaximumDefault := 3;
  if Style = 'currency' then
  begin
    Digits := 2;
    if (Currency = 'JPY') or (Currency = 'KRW') then
      Digits := 0;
    MinimumDefault := Digits;
    MaximumDefault := Digits;
  end
  else if Style = 'percent' then
    MaximumDefault := 0;
  if not NumberOption(R, Options, 'minimumIntegerDigits', 1, 21, 1, Target.MinimumIntegerDigits) or
    not NumberOption(R, Options, 'minimumFractionDigits', 0, 100, -1, Target.MinimumFractionDigits) or
    not NumberOption(R, Options, 'maximumFractionDigits', 0, 100, -1, Target.MaximumFractionDigits) or
    not NumberOption(R, Options, 'minimumSignificantDigits', 1, 21, 0, Target.MinimumSignificantDigits) or
    not NumberOption(R, Options, 'maximumSignificantDigits', 1, 21, 0, Target.MaximumSignificantDigits) then
    Exit;
  if Target.MinimumFractionDigits < 0 then
  begin
    Target.MinimumFractionDigits := MinimumDefault;
    if (Target.MaximumFractionDigits >= 0) and (Target.MinimumFractionDigits > Target.MaximumFractionDigits) then
      Target.MinimumFractionDigits := Target.MaximumFractionDigits;
  end;
  if Target.MaximumFractionDigits < 0 then
    Target.MaximumFractionDigits := Max(Target.MinimumFractionDigits, MaximumDefault)
  else if Target.MaximumFractionDigits < Target.MinimumFractionDigits then
    begin R.ThrowRangeError('maximumFractionDigits value is out of range.'); Exit; end;
  if (Target.MaximumSignificantDigits > 0) or (Target.MinimumSignificantDigits > 0) then
  begin
    if Target.MinimumSignificantDigits = 0 then
      Target.MinimumSignificantDigits := 1;
    if Target.MaximumSignificantDigits = 0 then
      Target.MaximumSignificantDigits := 21;
    if Target.MaximumSignificantDigits < Target.MinimumSignificantDigits then
      begin R.ThrowRangeError('maximumSignificantDigits value is out of range.'); Exit; end;
  end;
  if not StringOption(R, Options, 'useGrouping', [], Grouping) or
    not StringOption(R, Options, 'signDisplay', ['auto', 'never', 'always', 'exceptZero', 'negative'], Sign) then
    Exit;
  if (Grouping = '') or (Grouping = 'true') then
    Grouping := 'auto';
  Target.Put('useGrouping', Grouping);
  if Sign = '' then
    Sign := 'auto';
  Target.Put('signDisplay', Sign);
  Result := True;
end;

function NumberFormatConstructor(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Target: TIntlObject;
  Constructor_: TJsValue;
  Mark: Integer;
begin
  Constructor_ := NewTarget;
  if Constructor_ = JsUndefined then
    Constructor_ := JsObjectValue(Callee);
  Target := NewIntl(R, Constructor_, ikNumberFormat, nil);
  if Target = nil then
    Exit(JsException);
  Mark := R.Runtime.PushRoot(JsObjectValue(Target));
  try
    if not InitializeNumberFormat(R, Target, Arg(Args, ArgCount, 0), Arg(Args, ArgCount, 1)) then
      Exit(JsException);
  finally
    R.Runtime.PopRoots(Mark);
  end;
  Result := JsObjectValue(Target);
end;

type
  TNumberPart = record
    PartType: string;
    Value: string;
  end;
  TNumberParts = array of TNumberPart;

procedure AddPart(var Parts: TNumberParts; const PartType, Value: string);
begin
  if Value = '' then
    Exit;
  SetLength(Parts, Length(Parts) + 1);
  Parts[High(Parts)].PartType := PartType;
  Parts[High(Parts)].Value := Value;
end;

{ The digits of |Value| as the format wants them: integer and fraction. }
procedure NumberDigits(Heap: TJsHeap; Format: TIntlObject; Value: Double; out IntegerDigits, FractionDigits: string);
var
  Digits, Text: string;
  Exponent, Point, Count: Integer;
begin
  if Format.MaximumSignificantDigits > 0 then
  begin
    if Value = 0 then
    begin
      Digits := '0';
      Exponent := 0;
    end
    else
      PrecisionDigits(Heap, Value, Format.MaximumSignificantDigits, Digits, Exponent);
    { Trailing zeros beyond the minimum significant digits go. }
    Count := Length(Digits);
    while (Count > Format.MinimumSignificantDigits) and (Digits[Count] = '0') do
      Dec(Count);
    SetLength(Digits, Count);
    Point := Exponent + 1;
    if Point <= 0 then
    begin
      IntegerDigits := '0';
      FractionDigits := StringOfChar('0', -Point) + Digits;
    end
    else if Point >= Length(Digits) then
    begin
      IntegerDigits := Digits + StringOfChar('0', Point - Length(Digits));
      FractionDigits := '';
    end
    else
    begin
      IntegerDigits := Copy(Digits, 1, Point);
      FractionDigits := Copy(Digits, Point + 1, MaxInt);
    end;
  end
  else
  begin
    Text := FormatFixed(Heap, Value, Format.MaximumFractionDigits);
    Point := Pos('.', Text);
    if Point = 0 then
    begin
      IntegerDigits := Text;
      FractionDigits := '';
    end
    else
    begin
      IntegerDigits := Copy(Text, 1, Point - 1);
      FractionDigits := Copy(Text, Point + 1, MaxInt);
    end;
    Count := Length(FractionDigits);
    while (Count > Format.MinimumFractionDigits) and (FractionDigits[Count] = '0') do
      Dec(Count);
    SetLength(FractionDigits, Count);
  end;
  while Length(IntegerDigits) < Format.MinimumIntegerDigits do
    IntegerDigits := '0' + IntegerDigits;
end;

function FormatNumberParts(R: TJsRealm; Format: TIntlObject; Value: TJsValue): TNumberParts;
var
  Number: Double;
  Negative, IsZero: Boolean;
  IntegerDigits, FractionDigits, Style, Sign, Currency, Display, Grouping, UnitName, Symbol: string;
  Index, Group, Known: Integer;
  Big: TJsBigInt;
begin
  Result := nil;
  Style := Format.Setting('style');
  Sign := Format.Setting('signDisplay');
  Grouping := Format.Setting('useGrouping');
  if JsIsBigInt(Value) then
  begin
    Big := TJsBigInt(JsAsCell(Value));
    Negative := Big.Negative;
    IsZero := Big.IsZero;
    IntegerDigits := BigIntToText(Big, 10);
    if Negative then
      Delete(IntegerDigits, 1, 1);
    FractionDigits := StringOfChar('0', Format.MinimumFractionDigits);
    Number := 0;
  end
  else
  begin
    Number := JsNumberValue(Value);
    Negative := (Number < 0) or (DoubleBits(Number) = JsNegativeZeroBits);
    if Style = 'percent' then
      Number := Number * 100;
    IsZero := Number = 0;
    if not IsNaNDouble(Number) and IsFiniteDouble(Number) then
    begin
      NumberDigits(R.Heap, Format, Abs(Number), IntegerDigits, FractionDigits);
      IsZero := (StringReplace(IntegerDigits + FractionDigits, '0', '', [rfReplaceAll]) = '');
    end;
  end;
  if IsNaNDouble(Number) then
    Negative := False;
  case Sign of
    'never': ;
    'always':
      if Negative then
        AddPart(Result, 'minusSign', '-')
      else
        AddPart(Result, 'plusSign', '+');
    'exceptZero':
      if not IsZero and not IsNaNDouble(Number) then
        if Negative then
          AddPart(Result, 'minusSign', '-')
        else
          AddPart(Result, 'plusSign', '+');
    'negative':
      if Negative and not IsZero then
        AddPart(Result, 'minusSign', '-');
  else
    if Negative then
      AddPart(Result, 'minusSign', '-');
  end;
  Currency := Format.Setting('currency');
  Display := Format.Setting('currencyDisplay');
  Known := CurrencyIndex(Currency);
  if (Style = 'currency') and (Display <> 'name') then
  begin
    if (Display = 'code') or (Known < 0) then
      AddPart(Result, 'currency', Currency + #$C2#$A0)
    else if (Display = 'narrowSymbol') and (Known >= 0) then
      AddPart(Result, 'currency', Copy(CurrencySymbols[Known], Length(CurrencySymbols[Known]), 1))
    else
      AddPart(Result, 'currency', CurrencySymbols[Known]);
    if (Display = 'code') or (Known < 0) then
    begin
      { The code and a no-break space: one part each in ICU. }
      Result[High(Result)].Value := Currency;
      AddPart(Result, 'literal', #$C2#$A0);
    end;
  end;
  if IsNaNDouble(Number) then
    AddPart(Result, 'nan', 'NaN')
  else if not IsFiniteDouble(Number) then
    AddPart(Result, 'infinity', '∞')
  else
  begin
    if (Grouping <> 'false') and ((Grouping <> 'min2') or (Length(IntegerDigits) >= 5)) and
      (Length(IntegerDigits) > 3) then
    begin
      Group := Length(IntegerDigits) mod 3;
      if Group = 0 then
        Group := 3;
      AddPart(Result, 'integer', Copy(IntegerDigits, 1, Group));
      Index := Group + 1;
      while Index <= Length(IntegerDigits) do
      begin
        AddPart(Result, 'group', ',');
        AddPart(Result, 'integer', Copy(IntegerDigits, Index, 3));
        Inc(Index, 3);
      end;
    end
    else
      AddPart(Result, 'integer', IntegerDigits);
    if FractionDigits <> '' then
    begin
      AddPart(Result, 'decimal', '.');
      AddPart(Result, 'fraction', FractionDigits);
    end;
  end;
  if Style = 'percent' then
    AddPart(Result, 'percentSign', '%')
  else if (Style = 'currency') and (Display = 'name') then
  begin
    AddPart(Result, 'literal', ' ');
    if Known >= 0 then
      AddPart(Result, 'currency', CurrencyNames[Known])
    else
      AddPart(Result, 'currency', Currency);
  end
  else if Style = 'unit' then
  begin
    UnitName := Format.Setting('unit');
    Symbol := UnitText(UnitName, Format.Setting('unitDisplay') = 'long', not ((Number = 1) and (FractionDigits = '')));
    if (UnitName = 'percent') or (UnitName = 'celsius') or (UnitName = 'fahrenheit') then
      AddPart(Result, 'unit', Symbol)
    else
    begin
      AddPart(Result, 'literal', ' ');
      AddPart(Result, 'unit', Symbol);
    end;
  end;
end;

function FormatNumberText(R: TJsRealm; Format: TIntlObject; Value: TJsValue): string;
var
  Parts: TNumberParts;
  Index: Integer;
begin
  Parts := FormatNumberParts(R, Format, Value);
  Result := '';
  for Index := 0 to High(Parts) do
    Result := Result + Parts[Index].Value;
end;

function NumericArgument(R: TJsRealm; Value: TJsValue): TJsValue;
begin
  if JsIsBigInt(Value) or JsIsNumber(Value) then
    Exit(Value);
  Result := ToNumeric(R, Value);
end;

function NumberFormatFormat(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Value: TJsValue;
begin
  Value := NumericArgument(R, Arg(Args, ArgCount, 0));
  if Value = JsException then
    Exit(JsException);
  Result := R.NewString(FormatNumberText(R, TIntlObject(JsAsObject(Callee.Data)), Value));
end;

function PartsArray(R: TJsRealm; const Parts: TNumberParts): TJsValue;
var
  Output: TJsArray;
  Item: TJsObject;
  Index: Integer;
begin
  Output := R.NewArray(0);
  for Index := 0 to High(Parts) do
  begin
    Item := R.NewPlainObject;
    Item.CreateDataProperty(R, R.Intern('type'), R.NewString(Parts[Index].PartType));
    Item.CreateDataProperty(R, R.Intern('value'), R.NewString(Parts[Index].Value));
    Output.CreateDataProperty(R, JsInteger(Index), JsObjectValue(Item));
  end;
  Result := JsObjectValue(Output);
end;

{ The format getter (0) and formatToParts (1) of NumberFormat and
  DateTimeFormat; compare of Collator; select of PluralRules. }
function BoundGetter(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue; forward;

function NumberFormatToParts(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Target: TIntlObject;
  Value: TJsValue;
begin
  if not ThisIntl(R, This, ikNumberFormat, Target) then
    Exit(JsException);
  Value := NumericArgument(R, Arg(Args, ArgCount, 0));
  if Value = JsException then
    Exit(JsException);
  Result := PartsArray(R, FormatNumberParts(R, Target, Value));
end;

procedure PutString(R: TJsRealm; Target: TJsObject; const Name, Value: string);
begin
  if Value <> '' then
    Target.CreateDataProperty(R, R.Intern(Name), R.NewString(Value));
end;

function NumberResolvedOptions(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Target: TIntlObject;
  Output: TJsObject;
  Grouping: string;
begin
  if not ThisIntl(R, This, ikNumberFormat, Target) then
    Exit(JsException);
  Output := R.NewPlainObject;
  PutString(R, Output, 'locale', 'en-US');
  PutString(R, Output, 'numberingSystem', 'latn');
  PutString(R, Output, 'style', Target.Setting('style'));
  if Target.Setting('style') = 'currency' then
  begin
    PutString(R, Output, 'currency', Target.Setting('currency'));
    PutString(R, Output, 'currencyDisplay', Target.Setting('currencyDisplay'));
    PutString(R, Output, 'currencySign', 'standard');
  end;
  if Target.Setting('style') = 'unit' then
  begin
    PutString(R, Output, 'unit', Target.Setting('unit'));
    PutString(R, Output, 'unitDisplay', Target.Setting('unitDisplay'));
  end;
  Output.CreateDataProperty(R, R.Intern('minimumIntegerDigits'), JsInteger(Target.MinimumIntegerDigits));
  if Target.MaximumSignificantDigits > 0 then
  begin
    Output.CreateDataProperty(R, R.Intern('minimumSignificantDigits'), JsInteger(Target.MinimumSignificantDigits));
    Output.CreateDataProperty(R, R.Intern('maximumSignificantDigits'), JsInteger(Target.MaximumSignificantDigits));
  end
  else
  begin
    Output.CreateDataProperty(R, R.Intern('minimumFractionDigits'), JsInteger(Target.MinimumFractionDigits));
    Output.CreateDataProperty(R, R.Intern('maximumFractionDigits'), JsInteger(Target.MaximumFractionDigits));
  end;
  Grouping := Target.Setting('useGrouping');
  if Grouping = 'false' then
    Output.CreateDataProperty(R, R.Intern('useGrouping'), JsFalse)
  else
    PutString(R, Output, 'useGrouping', Grouping);
  PutString(R, Output, 'notation', Target.Setting('notation'));
  PutString(R, Output, 'signDisplay', Target.Setting('signDisplay'));
  PutString(R, Output, 'roundingMode', 'halfExpand');
  Result := JsObjectValue(Output);
end;

{ DateTimeFormat }

const
  MonthLong: array[0..11] of string = ('January', 'February', 'March', 'April', 'May', 'June', 'July', 'August',
    'September', 'October', 'November', 'December');
  WeekdayLong: array[0..6] of string = ('Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday',
    'Saturday');
  DateFields: array[0..8] of string = ('weekday', 'era', 'year', 'month', 'day', 'hour', 'minute', 'second',
    'timeZoneName');

function DateTimeFormatSetup(R: TJsRealm; Target: TIntlObject; Options: TJsObject; Required, Defaults: string): Boolean;
var
  Value, TimeZone, HourCycle, Hour12: string;
  Index: Integer;
  HasDate, HasTime, NeedDefaults: Boolean;
begin
  Result := False;
  for Index := 0 to High(DateFields) do
  begin
    case Index of
      0: if not StringOption(R, Options, 'weekday', ['narrow', 'short', 'long'], Value) then Exit;
      1: if not StringOption(R, Options, 'era', ['narrow', 'short', 'long'], Value) then Exit;
      2, 4: if not StringOption(R, Options, DateFields[Index], ['2-digit', 'numeric'], Value) then Exit;
      3: if not StringOption(R, Options, 'month', ['2-digit', 'numeric', 'narrow', 'short', 'long'], Value) then Exit;
      5, 6, 7: if not StringOption(R, Options, DateFields[Index], ['2-digit', 'numeric'], Value) then Exit;
    else
      if not StringOption(R, Options, 'timeZoneName', ['short', 'long', 'shortOffset', 'longOffset', 'shortGeneric',
        'longGeneric'], Value) then
        Exit;
    end;
    Target.Put(DateFields[Index], Value);
  end;
  if not StringOption(R, Options, 'timeZone', [], TimeZone) or
    not StringOption(R, Options, 'hourCycle', ['h11', 'h12', 'h23', 'h24'], HourCycle) or
    not StringOption(R, Options, 'hour12', [], Hour12) or
    not StringOption(R, Options, 'dateStyle', ['full', 'long', 'medium', 'short'], Value) then
    Exit;
  Target.Put('dateStyle', Value);
  if not StringOption(R, Options, 'timeStyle', ['full', 'long', 'medium', 'short'], Value) then
    Exit;
  Target.Put('timeStyle', Value);
  if not NumberOption(R, Options, 'fractionalSecondDigits', 1, 3, 0, Target.MinimumFractionDigits) then
    Exit;
  if ((Target.Setting('dateStyle') <> '') or (Target.Setting('timeStyle') <> '')) then
    for Index := 0 to High(DateFields) do
      if Target.Setting(DateFields[Index]) <> '' then
      begin
        R.ThrowTypeError('Can''t set option ' + DateFields[Index] + ' when dateStyle or timeStyle is used');
        Exit;
      end;
  if (UpperCase(TimeZone) = 'UTC') or (UpperCase(TimeZone) = 'ETC/UTC') or (UpperCase(TimeZone) = 'GMT') or
    (UpperCase(TimeZone) = 'ETC/GMT') then
    TimeZone := 'UTC'
  else if TimeZone = '' then
    TimeZone := 'local';
  Target.Put('timeZone', TimeZone);
  if Hour12 = 'false' then
    HourCycle := 'h23'
  else if Hour12 = 'true' then
    HourCycle := 'h12'
  else if HourCycle = '' then
    HourCycle := 'h12';
  Target.Put('hourCycle', HourCycle);
  HasDate := (Target.Setting('weekday') <> '') or (Target.Setting('year') <> '') or (Target.Setting('month') <> '') or
    (Target.Setting('day') <> '') or (Target.Setting('dateStyle') <> '');
  HasTime := (Target.Setting('hour') <> '') or (Target.Setting('minute') <> '') or (Target.Setting('second') <> '') or
    (Target.Setting('timeStyle') <> '') or (Target.MinimumFractionDigits > 0);
  if Required = 'date' then
    NeedDefaults := not HasDate
  else if Required = 'time' then
    NeedDefaults := not HasTime
  else
    NeedDefaults := not HasDate and not HasTime;
  if (Target.Setting('dateStyle') <> '') or (Target.Setting('timeStyle') <> '') then
    NeedDefaults := False;
  if NeedDefaults then
  begin
    if (Defaults = 'date') or (Defaults = 'all') then
    begin
      Target.Put('year', 'numeric');
      Target.Put('month', 'numeric');
      Target.Put('day', 'numeric');
    end;
    if (Defaults = 'time') or (Defaults = 'all') then
    begin
      Target.Put('hour', 'numeric');
      Target.Put('minute', '2-digit');
      Target.Put('second', '2-digit');
    end;
  end;
  Result := True;
end;

{ The last value put for a name wins (the defaults come after). }
function LastSetting(Target: TIntlObject; const Name: string): string;
var
  Index: Integer;
begin
  Result := '';
  for Index := High(Target.Settings) downto 0 do
    if Target.Settings[Index] = Name then
      Exit(Target.Values[Index]);
end;

function InitializeDateTimeFormat(R: TJsRealm; Target: TIntlObject; Locales, OptionsValue: TJsValue;
  const Required, Defaults: string): Boolean;
var
  List: TStringArray;
  Options: TJsObject;
begin
  Result := LocaleList(R, Locales, List) and OptionsObject(R, OptionsValue, Options) and
    DateTimeFormatSetup(R, Target, Options, Required, Defaults);
end;

function DateTimeFormatConstructor(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Target: TIntlObject;
  Constructor_: TJsValue;
  Mark: Integer;
begin
  Constructor_ := NewTarget;
  if Constructor_ = JsUndefined then
    Constructor_ := JsObjectValue(Callee);
  Target := NewIntl(R, Constructor_, ikDateTimeFormat, nil);
  if Target = nil then
    Exit(JsException);
  Mark := R.Runtime.PushRoot(JsObjectValue(Target));
  try
    if not InitializeDateTimeFormat(R, Target, Arg(Args, ArgCount, 0), Arg(Args, ArgCount, 1), 'any', 'date') then
      Exit(JsException);
  finally
    R.Runtime.PopRoots(Mark);
  end;
  Result := JsObjectValue(Target);
end;

function TwoDigits(Value: Integer): string;
begin
  Result := IntToStr(Value);
  if Length(Result) < 2 then
    Result := '0' + Result;
end;

function Format3(Value: Integer): string;
begin
  Result := IntToStr(Value);
  while Length(Result) < 3 do
    Result := '0' + Result;
end;

function ZoneText(Format: TIntlObject; Time: Double; Long: Boolean): string;
var
  Offset: Integer;
begin
  if Format.Setting('timeZone') = 'UTC' then
  begin
    if Long then
      Exit('Coordinated Universal Time');
    Exit('UTC');
  end;
  if Long and Assigned(JsZoneName) then
    Exit(JsZoneName(Time));
  Offset := Round(LocalOffset(Time) / 60000);
  if Offset = 0 then
    Exit('GMT');
  if Offset < 0 then
    Result := 'GMT-'
  else
    Result := 'GMT+';
  Result := Result + IntToStr(Abs(Offset) div 60);
  if Abs(Offset) mod 60 <> 0 then
    Result := Result + ':' + TwoDigits(Abs(Offset) mod 60);
end;

procedure DateParts(Format: TIntlObject; Time: Double; var Parts: TNumberParts);
var
  T: Double;
  WeekdayStyle, Year, Month, Day, Hour, Minute, Second, DateStyle, TimeStyle, Cycle, ZoneName: string;
  HourValue: Integer;
  HasDate, HasTime, TextMonth: Boolean;

  procedure Literal(const Text: string);
  begin
    AddPart(Parts, 'literal', Text);
  end;

begin
  if Format.Setting('timeZone') = 'UTC' then
    T := Time
  else
    T := LocalTime(Time);
  DateStyle := Format.Setting('dateStyle');
  TimeStyle := Format.Setting('timeStyle');
  WeekdayStyle := LastSetting(Format, 'weekday');
  Year := LastSetting(Format, 'year');
  Month := LastSetting(Format, 'month');
  Day := LastSetting(Format, 'day');
  Hour := LastSetting(Format, 'hour');
  Minute := LastSetting(Format, 'minute');
  Second := LastSetting(Format, 'second');
  ZoneName := LastSetting(Format, 'timeZoneName');
  case DateStyle of
    'full': begin WeekdayStyle := 'long'; Month := 'long'; Day := 'numeric'; Year := 'numeric'; end;
    'long': begin Month := 'long'; Day := 'numeric'; Year := 'numeric'; end;
    'medium': begin Month := 'short'; Day := 'numeric'; Year := 'numeric'; end;
    'short': begin Month := 'numeric'; Day := 'numeric'; Year := '2-digit'; end;
  end;
  case TimeStyle of
    'full': begin Hour := 'numeric'; Minute := '2-digit'; Second := '2-digit'; ZoneName := 'long'; end;
    'long': begin Hour := 'numeric'; Minute := '2-digit'; Second := '2-digit'; ZoneName := 'short'; end;
    'medium': begin Hour := 'numeric'; Minute := '2-digit'; Second := '2-digit'; end;
    'short': begin Hour := 'numeric'; Minute := '2-digit'; end;
  end;
  HasDate := (WeekdayStyle <> '') or (Year <> '') or (Month <> '') or (Day <> '');
  HasTime := (Hour <> '') or (Minute <> '') or (Second <> '');
  TextMonth := (Month = 'long') or (Month = 'short') or (Month = 'narrow');
  if HasDate then
  begin
    if WeekdayStyle <> '' then
    begin
      case WeekdayStyle of
        'long': AddPart(Parts, 'weekday', WeekdayLong[WeekDay(T)]);
        'short': AddPart(Parts, 'weekday', Copy(WeekdayLong[WeekDay(T)], 1, 3));
      else
        AddPart(Parts, 'weekday', Copy(WeekdayLong[WeekDay(T)], 1, 1));
      end;
      if (Year <> '') or (Month <> '') or (Day <> '') then
        Literal(', ');
    end;
    if TextMonth then
    begin
      case Month of
        'long': AddPart(Parts, 'month', MonthLong[MonthFromTime(T)]);
        'short': AddPart(Parts, 'month', Copy(MonthLong[MonthFromTime(T)], 1, 3));
      else
        AddPart(Parts, 'month', Copy(MonthLong[MonthFromTime(T)], 1, 1));
      end;
      if Day <> '' then
      begin
        Literal(' ');
        if Day = '2-digit' then
          AddPart(Parts, 'day', TwoDigits(DateFromTime(T)))
        else
          AddPart(Parts, 'day', IntToStr(DateFromTime(T)));
      end;
      if Year <> '' then
      begin
        if Day <> '' then
          Literal(', ')
        else
          Literal(' ');
      end;
    end
    else
    begin
      if Month <> '' then
      begin
        if Month = '2-digit' then
          AddPart(Parts, 'month', TwoDigits(MonthFromTime(T) + 1))
        else
          AddPart(Parts, 'month', IntToStr(MonthFromTime(T) + 1));
        if (Day <> '') or (Year <> '') then
          Literal('/');
      end;
      if Day <> '' then
      begin
        if Day = '2-digit' then
          AddPart(Parts, 'day', TwoDigits(DateFromTime(T)))
        else
          AddPart(Parts, 'day', IntToStr(DateFromTime(T)));
        if Year <> '' then
          Literal('/');
      end;
    end;
    if Year <> '' then
    begin
      if Year = '2-digit' then
        AddPart(Parts, 'year', TwoDigits(Trunc(YearFromTime(T)) mod 100))
      else
        AddPart(Parts, 'year', IntToStr(Trunc(YearFromTime(T))));
    end;
  end;
  if HasTime then
  begin
    if HasDate then
    begin
      if (DateStyle = 'full') or (DateStyle = 'long') then
        Literal(' at ')
      else
        Literal(', ');
    end;
    Cycle := Format.Setting('hourCycle');
    HourValue := HourFromTime(T);
    if Hour <> '' then
    begin
      if (Cycle = 'h12') or (Cycle = 'h11') then
      begin
        HourValue := HourValue mod 12;
        if (HourValue = 0) and (Cycle = 'h12') then
          HourValue := 12;
      end;
      if (Hour = '2-digit') or (((Cycle = 'h23') or (Cycle = 'h24')) and (Minute <> '')) then
        AddPart(Parts, 'hour', TwoDigits(HourValue))
      else
        AddPart(Parts, 'hour', IntToStr(HourValue));
    end;
    if Minute <> '' then
    begin
      if Hour <> '' then
        Literal(':');
      AddPart(Parts, 'minute', TwoDigits(MinFromTime(T)));
    end;
    if Second <> '' then
    begin
      if (Hour <> '') or (Minute <> '') then
        Literal(':');
      AddPart(Parts, 'second', TwoDigits(SecFromTime(T)));
      if Format.MinimumFractionDigits > 0 then
      begin
        Literal('.');
        AddPart(Parts, 'fractionalSecond', Copy(Format3(MsFromTime(T)), 1, Format.MinimumFractionDigits));
      end;
    end;
    if (Hour <> '') and ((Cycle = 'h12') or (Cycle = 'h11')) then
    begin
      Literal(' ');
      if HourFromTime(T) >= 12 then
        AddPart(Parts, 'dayPeriod', 'PM')
      else
        AddPart(Parts, 'dayPeriod', 'AM');
    end;
  end;
  if ZoneName <> '' then
  begin
    Literal(' ');
    AddPart(Parts, 'timeZoneName', ZoneText(Format, Time, (ZoneName = 'long') or (ZoneName = 'longGeneric')));
  end;
end;

function DateTimeValue(R: TJsRealm; Value: TJsValue; out Time: Double): Boolean;
begin
  if Value = JsUndefined then
    Time := JsCurrentTime()
  else if not DateTimeOf(Value, Time) then
  begin
    if not ToDouble(R, Value, Time) then
      Exit(False);
  end;
  if IsNaNDouble(Time) or not IsFiniteDouble(Time) or (Abs(Time) > 8.64e15) then
  begin
    R.ThrowRangeError('Invalid time value');
    Exit(False);
  end;
  Result := True;
end;

function FormatDateText(Format: TIntlObject; Time: Double): string;
var
  Parts: TNumberParts;
  Index: Integer;
begin
  Parts := nil;
  DateParts(Format, Time, Parts);
  Result := '';
  for Index := 0 to High(Parts) do
    Result := Result + Parts[Index].Value;
end;

function DateTimeFormatFormat(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Time: Double;
begin
  if not DateTimeValue(R, Arg(Args, ArgCount, 0), Time) then
    Exit(JsException);
  Result := R.NewString(FormatDateText(TIntlObject(JsAsObject(Callee.Data)), Time));
end;

function DateTimeFormatToParts(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Target: TIntlObject;
  Time: Double;
  Parts: TNumberParts;
begin
  if not ThisIntl(R, This, ikDateTimeFormat, Target) then
    Exit(JsException);
  if not DateTimeValue(R, Arg(Args, ArgCount, 0), Time) then
    Exit(JsException);
  Parts := nil;
  DateParts(Target, Time, Parts);
  Result := PartsArray(R, Parts);
end;

function DateResolvedOptions(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Target: TIntlObject;
  Output: TJsObject;
  Index: Integer;
  Zone: string;
begin
  if not ThisIntl(R, This, ikDateTimeFormat, Target) then
    Exit(JsException);
  Output := R.NewPlainObject;
  PutString(R, Output, 'locale', 'en-US');
  PutString(R, Output, 'calendar', 'gregory');
  PutString(R, Output, 'numberingSystem', 'latn');
  Zone := Target.Setting('timeZone');
  if Zone = 'local' then
  begin
    Zone := 'UTC';
    if Assigned(JsZoneName) and (LocalOffset(JsCurrentTime()) <> 0) then
      Zone := 'Etc/Unknown';
  end;
  PutString(R, Output, 'timeZone', Zone);
  if (LastSetting(Target, 'hour') <> '') or (Target.Setting('timeStyle') <> '') then
  begin
    PutString(R, Output, 'hourCycle', Target.Setting('hourCycle'));
    Output.CreateDataProperty(R, R.Intern('hour12'), JsBoolean((Target.Setting('hourCycle') = 'h12') or
      (Target.Setting('hourCycle') = 'h11')));
  end;
  for Index := 0 to High(DateFields) do
    PutString(R, Output, DateFields[Index], LastSetting(Target, DateFields[Index]));
  PutString(R, Output, 'dateStyle', Target.Setting('dateStyle'));
  PutString(R, Output, 'timeStyle', Target.Setting('timeStyle'));
  Result := JsObjectValue(Output);
end;

{ Collator }

function CollatorConstructor(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Target: TIntlObject;
  List: TStringArray;
  Options: TJsObject;
  Value: string;
begin
  if not LocaleList(R, Arg(Args, ArgCount, 0), List) then
    Exit(JsException);
  if not OptionsObject(R, Arg(Args, ArgCount, 1), Options) then
    Exit(JsException);
  if NewTarget = JsUndefined then
    Target := NewIntl(R, JsObjectValue(Callee), ikCollator, nil)
  else
    Target := NewIntl(R, NewTarget, ikCollator, nil);
  if Target = nil then
    Exit(JsException);
  if not StringOption(R, Options, 'usage', ['sort', 'search'], Value) then
    Exit(JsException);
  if Value = '' then
    Value := 'sort';
  Target.Put('usage', Value);
  if not StringOption(R, Options, 'sensitivity', ['base', 'accent', 'case', 'variant'], Value) then
    Exit(JsException);
  if Value = '' then
    Value := 'variant';
  Target.Put('sensitivity', Value);
  if not StringOption(R, Options, 'numeric', [], Value) then
    Exit(JsException);
  if Value = '' then
    Value := 'false';
  Target.Put('numeric', Value);
  if not StringOption(R, Options, 'ignorePunctuation', [], Value) then
    Exit(JsException);
  if Value = '' then
    Value := 'false';
  Target.Put('ignorePunctuation', Value);
  Result := JsObjectValue(Target);
end;

{ The collation key of a text: its code points, for base sensitivity
  without marks and case, for accent without case. }
function LowerText(const Text: UnicodeString): UnicodeString;
var
  Index: Integer;
begin
  Result := Text;
  for Index := 1 to Length(Result) do
    if (Ord(Result[Index]) < $D800) or (Ord(Result[Index]) > $DFFF) then
      Result[Index] := TCharacter.ToLower(Result[Index]);
end;

function CollationText(const Text: UnicodeString; const Sensitivity: string): UnicodeString;
var
  Index: Integer;
  Decomposed: UnicodeString;
begin
  if (Sensitivity = 'variant') or (Sensitivity = 'case') then
    Exit(Text);
  if Sensitivity = 'base' then
  begin
    Decomposed := NormalizeText(Text, nfD);
    Result := '';
    for Index := 1 to Length(Decomposed) do
      if CombiningClass(Ord(Decomposed[Index])) = 0 then
        Result := Result + Decomposed[Index];
    Exit(LowerText(Result));
  end;
  Result := LowerText(Text);
end;

function StripZeros(const Digits: string): string;
var
  Start: Integer;
begin
  Start := 1;
  while (Start < Length(Digits)) and (Digits[Start] = '0') do
    Inc(Start);
  Result := Copy(Digits, Start, MaxInt);
end;

function CompareCodePoints(const First, Second: UnicodeString; Numeric: Boolean): Integer;
var
  I, J, StartI, StartJ: Integer;
  A, B: Word;
  NumberA, NumberB: string;
begin
  I := 1;
  J := 1;
  while (I <= Length(First)) and (J <= Length(Second)) do
  begin
    A := Ord(First[I]);
    B := Ord(Second[J]);
    if Numeric and (A >= Ord('0')) and (A <= Ord('9')) and (B >= Ord('0')) and (B <= Ord('9')) then
    begin
      StartI := I;
      while (I <= Length(First)) and (First[I] >= '0') and (First[I] <= '9') do
        Inc(I);
      StartJ := J;
      while (J <= Length(Second)) and (Second[J] >= '0') and (Second[J] <= '9') do
        Inc(J);
      NumberA := StripZeros(string(Copy(First, StartI, I - StartI)));
      NumberB := StripZeros(string(Copy(Second, StartJ, J - StartJ)));
      if Length(NumberA) <> Length(NumberB) then
        Exit(Sign(Length(NumberA) - Length(NumberB)));
      if NumberA <> NumberB then
      begin
        if NumberA < NumberB then
          Exit(-1);
        Exit(1);
      end;
      Continue;
    end;
    if A <> B then
    begin
      { Surrogates sort after the rest of the BMP, as code points do. }
      if (A >= $D800) and (A <= $DFFF) and not ((B >= $D800) and (B <= $DFFF)) and (B >= $E000) then
        Exit(1);
      if (B >= $D800) and (B <= $DFFF) and not ((A >= $D800) and (A <= $DFFF)) and (A >= $E000) then
        Exit(-1);
      Exit(Sign(Integer(A) - Integer(B)));
    end;
    Inc(I);
    Inc(J);
  end;
  Result := Sign((Length(First) - I) - (Length(Second) - J));
end;

function CollatorCompare(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Target: TIntlObject;
  First, Second: TJsString;
  Sensitivity: string;
begin
  Target := TIntlObject(JsAsObject(Callee.Data));
  First := ToJsString(R, Arg(Args, ArgCount, 0));
  if First = nil then
    Exit(JsException);
  Second := ToJsString(R, Arg(Args, ArgCount, 1));
  if Second = nil then
    Exit(JsException);
  Sensitivity := Target.Setting('sensitivity');
  Result := JsInteger(CompareCodePoints(CollationText(StringToUnicode(R.Heap, First), Sensitivity),
    CollationText(StringToUnicode(R.Heap, Second), Sensitivity), Target.Setting('numeric') = 'true'));
end;

function CollatorResolvedOptions(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Target: TIntlObject;
  Output: TJsObject;
begin
  if not ThisIntl(R, This, ikCollator, Target) then
    Exit(JsException);
  Output := R.NewPlainObject;
  PutString(R, Output, 'locale', 'en-US');
  PutString(R, Output, 'usage', Target.Setting('usage'));
  PutString(R, Output, 'sensitivity', Target.Setting('sensitivity'));
  Output.CreateDataProperty(R, R.Intern('ignorePunctuation'), JsBoolean(Target.Setting('ignorePunctuation') = 'true'));
  PutString(R, Output, 'collation', 'default');
  Output.CreateDataProperty(R, R.Intern('numeric'), JsBoolean(Target.Setting('numeric') = 'true'));
  PutString(R, Output, 'caseFirst', 'false');
  Result := JsObjectValue(Output);
end;

{ PluralRules }

function PluralRulesConstructor(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Target: TIntlObject;
  List: TStringArray;
  Options: TJsObject;
  Value: string;
begin
  if NewTarget = JsUndefined then
    Exit(R.ThrowTypeError('Constructor Intl.PluralRules requires ''new'''));
  if not LocaleList(R, Arg(Args, ArgCount, 0), List) then
    Exit(JsException);
  if not OptionsObject(R, Arg(Args, ArgCount, 1), Options) then
    Exit(JsException);
  Target := NewIntl(R, NewTarget, ikPluralRules, nil);
  if Target = nil then
    Exit(JsException);
  if not StringOption(R, Options, 'type', ['cardinal', 'ordinal'], Value) then
    Exit(JsException);
  if Value = '' then
    Value := 'cardinal';
  Target.Put('type', Value);
  Target.MinimumIntegerDigits := 1;
  Target.MinimumFractionDigits := 0;
  Target.MaximumFractionDigits := 3;
  if not NumberOption(R, Options, 'minimumFractionDigits', 0, 100, 0, Target.MinimumFractionDigits) or
    not NumberOption(R, Options, 'maximumFractionDigits', 0, 100, 3, Target.MaximumFractionDigits) then
    Exit(JsException);
  Target.Put('style', 'decimal');
  Target.Put('useGrouping', 'false');
  Target.Put('signDisplay', 'never');
  Result := JsObjectValue(Target);
end;

function PluralRulesSelect(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Target: TIntlObject;
  Number: Double;
  Text: string;
  Whole, LastTwo: Int64;
begin
  if not ThisIntl(R, This, ikPluralRules, Target) then
    Exit(JsException);
  if not ToDouble(R, Arg(Args, ArgCount, 0), Number) then
    Exit(JsException);
  if IsNaNDouble(Number) or not IsFiniteDouble(Number) then
    Exit(R.NewString('other'));
  Text := FormatNumberText(R, Target, JsNumber(Abs(Number)));
  if Target.Setting('type') = 'ordinal' then
  begin
    if Pos('.', Text) > 0 then
      Exit(R.NewString('other'));
    Whole := StrToInt64Def(Text, 0);
    LastTwo := Whole mod 100;
    if (Whole mod 10 = 1) and (LastTwo <> 11) then
      Exit(R.NewString('one'));
    if (Whole mod 10 = 2) and (LastTwo <> 12) then
      Exit(R.NewString('two'));
    if (Whole mod 10 = 3) and (LastTwo <> 13) then
      Exit(R.NewString('few'));
    Exit(R.NewString('other'));
  end;
  if Text = '1' then
    Result := R.NewString('one')
  else
    Result := R.NewString('other');
end;

function PluralResolvedOptions(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Target: TIntlObject;
  Output: TJsObject;
  Categories: TJsArray;
begin
  if not ThisIntl(R, This, ikPluralRules, Target) then
    Exit(JsException);
  Output := R.NewPlainObject;
  PutString(R, Output, 'locale', 'en-US');
  PutString(R, Output, 'type', Target.Setting('type'));
  Categories := R.NewArray(0);
  if Target.Setting('type') = 'ordinal' then
  begin
    Categories.CreateDataProperty(R, JsInteger(0), R.NewString('few'));
    Categories.CreateDataProperty(R, JsInteger(1), R.NewString('one'));
    Categories.CreateDataProperty(R, JsInteger(2), R.NewString('two'));
    Categories.CreateDataProperty(R, JsInteger(3), R.NewString('other'));
  end
  else
  begin
    Categories.CreateDataProperty(R, JsInteger(0), R.NewString('one'));
    Categories.CreateDataProperty(R, JsInteger(1), R.NewString('other'));
  end;
  Output.CreateDataProperty(R, R.Intern('pluralCategories'), JsObjectValue(Categories));
  Result := JsObjectValue(Output);
end;

{ Segmenter }

function SegmenterConstructor(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Target: TIntlObject;
  List: TStringArray;
  Options: TJsObject;
  Value: string;
begin
  if NewTarget = JsUndefined then
    Exit(R.ThrowTypeError('Constructor Intl.Segmenter requires ''new'''));
  if not LocaleList(R, Arg(Args, ArgCount, 0), List) then
    Exit(JsException);
  if not OptionsObject(R, Arg(Args, ArgCount, 1), Options) then
    Exit(JsException);
  Target := NewIntl(R, NewTarget, ikSegmenter, nil);
  if Target = nil then
    Exit(JsException);
  if not StringOption(R, Options, 'granularity', ['grapheme', 'word', 'sentence'], Value) then
    Exit(JsException);
  if Value = '' then
    Value := 'grapheme';
  Target.Put('granularity', Value);
  Result := JsObjectValue(Target);
end;

function CodePointAt(const Text: UnicodeString; Index: Integer; out Size: Integer): LongWord;
begin
  Result := Ord(Text[Index]);
  Size := 1;
  if (Result >= $D800) and (Result <= $DBFF) and (Index < Length(Text)) and (Ord(Text[Index + 1]) >= $DC00) and
    (Ord(Text[Index + 1]) <= $DFFF) then
  begin
    Result := $10000 + ((Result - $D800) shl 10) + (Ord(Text[Index + 1]) - $DC00);
    Size := 2;
  end;
end;

function IsExtend(CodePoint: LongWord): Boolean;
begin
  case CodePoint of
    $0300..$036F, $0483..$0489, $0591..$05BD, $0610..$061A, $064B..$065F, $0900..$0903, $093A..$094F,
    $1AB0..$1AFF, $1DC0..$1DFF, $200C, $200D, $20D0..$20FF, $FE00..$FE0F, $FE20..$FE2F, $1F3FB..$1F3FF,
    $E0020..$E007F, $E0100..$E01EF:
      Exit(True);
  end;
  if CodePoint > $FFFF then
    Exit(False);
  Result := TCharacter.GetUnicodeCategory(WideChar(CodePoint)) in [TUnicodeCategory.ucNonSpacingMark,
    TUnicodeCategory.ucEnclosingMark, TUnicodeCategory.ucCombiningMark];
end;

function IsPictographic(CodePoint: LongWord): Boolean;
begin
  case CodePoint of
    $00A9, $00AE, $203C, $2049, $2122, $2139, $2194..$21AA, $231A..$23FF, $24C2, $25AA..$27BF, $2934, $2935,
    $2B05..$2B55, $3030, $303D, $3297, $3299, $1F000..$1FAFF:
      Result := True;
  else
    Result := False;
  end;
end;

type
  THangulKind = (hkNone, hkLead, hkVowel, hkTrail, hkSyllableLV, hkSyllableLVT);

function HangulKindOf(CodePoint: LongWord): THangulKind;
begin
  case CodePoint of
    $1100..$115F, $A960..$A97C: Result := hkLead;
    $1160..$11A7, $D7B0..$D7C6: Result := hkVowel;
    $11A8..$11FF, $D7CB..$D7FB: Result := hkTrail;
    $AC00..$D7A3:
      if (CodePoint - $AC00) mod 28 = 0 then
        Result := hkSyllableLV
      else
        Result := hkSyllableLVT;
  else
    Result := hkNone;
  end;
end;

{ Whether a grapheme cluster continues between Before and After
  (Previous: the code point before Before; Regional: regional
  indicators in a row before After). }
function GraphemeContinues(Previous, Before, After: LongWord; Regional: Integer): Boolean;
var
  KindBefore, KindAfter: THangulKind;
begin
  if (Before = 13) and (After = 10) then
    Exit(True);
  if (Before = 10) or (Before = 13) or (After = 10) or (After = 13) then
    Exit(False);
  KindBefore := HangulKindOf(Before);
  KindAfter := HangulKindOf(After);
  if (KindBefore = hkLead) and (KindAfter in [hkLead, hkVowel, hkSyllableLV, hkSyllableLVT]) then
    Exit(True);
  if (KindBefore in [hkVowel, hkSyllableLV]) and (KindAfter in [hkVowel, hkTrail]) then
    Exit(True);
  if (KindBefore in [hkTrail, hkSyllableLVT]) and (KindAfter = hkTrail) then
    Exit(True);
  if IsExtend(After) then
    Exit(True);
  if (Before = $200D) and IsPictographic(After) then
    Exit(True);
  if (Before >= $1F1E6) and (Before <= $1F1FF) and (After >= $1F1E6) and (After <= $1F1FF) then
    Exit(Regional mod 2 = 1);
  Result := False;
end;

function IsWordCharacter(CodePoint: LongWord): Boolean;
begin
  if CodePoint < 128 then
    Exit(Char(CodePoint) in ['a'..'z', 'A'..'Z', '0'..'9', '_']);
  if CodePoint > $FFFF then
    Exit(not IsPictographic(CodePoint));
  Result := TCharacter.IsLetterOrDigit(WideChar(CodePoint)) or IsExtend(CodePoint) or (CodePoint = $2019);
end;

procedure SegmentText(Segments: TSegments; const Text: UnicodeString);
var
  Index, Size, Regional, Count: Integer;
  Previous, Before, After: LongWord;
  Starts: array of Integer;
  WordLike: array of Boolean;
  InWord, Continues: Boolean;

  procedure Start(Position: Integer; IsWord: Boolean);
  begin
    SetLength(Starts, Count + 1);
    SetLength(WordLike, Count + 1);
    Starts[Count] := Position;
    WordLike[Count] := IsWord;
    Inc(Count);
  end;

begin
  Starts := nil;
  WordLike := nil;
  Count := 0;
  Index := 1;
  Previous := 0;
  Before := 0;
  Regional := 0;
  InWord := False;
  while Index <= Length(Text) do
  begin
    After := CodePointAt(Text, Index, Size);
    if Index = 1 then
      Continues := False
    else if Segments.Granularity = 'grapheme' then
      Continues := GraphemeContinues(Previous, Before, After, Regional)
    else if Segments.Granularity = 'word' then
      Continues := GraphemeContinues(Previous, Before, After, Regional) or
        (InWord and IsWordCharacter(After)) or
        (not InWord and IsJsSpace(Before) and IsJsSpace(After)) or
        (InWord and ((After = Ord('''')) or (After = Ord('.'))) and (Index + Size <= Length(Text)) and
        IsWordCharacter(Ord(Text[Index + Size])) and (Before <> Ord('.')))
    else
      Continues := not ((Index > 2) and IsJsSpace(Before) and (Count > 0) and
        CharInSet(Char(Previous and $7F), ['.', '!', '?']) and not IsJsSpace(After)) and
        not ((Index > 1) and ((Before = 10) and not IsJsSpace(After)));
    if not Continues then
    begin
      InWord := IsWordCharacter(After);
      Start(Index - 1, (Segments.Granularity = 'word') and InWord);
    end
    else if (Segments.Granularity = 'word') and IsWordCharacter(After) then
      InWord := True;
    if (After >= $1F1E6) and (After <= $1F1FF) then
      Inc(Regional)
    else
      Regional := 0;
    if Segments.Granularity = 'sentence' then
    begin
      if not IsJsSpace(After) then
        Previous := After;
    end
    else
      Previous := Before;
    Before := After;
    Inc(Index, Size);
  end;
  Segments.Starts := Starts;
  Segments.WordLike := WordLike;
end;

function SegmentData(R: TJsRealm; Segments: TSegments; Index: Integer): TJsValue;
var
  Item: TJsObject;
  Input: TJsString;
  Finish: Integer;
begin
  Input := JsAsString(Segments.Input);
  if Index + 1 < Length(Segments.Starts) then
    Finish := Segments.Starts[Index + 1]
  else
    Finish := Input.Length;
  Item := R.NewPlainObject;
  Item.CreateDataProperty(R, R.Intern('segment'), JsStringValue(SubString(R.Heap, Input, Segments.Starts[Index],
    Finish - Segments.Starts[Index])));
  Item.CreateDataProperty(R, R.Intern('index'), JsInteger(Segments.Starts[Index]));
  Item.CreateDataProperty(R, R.Intern('input'), Segments.Input);
  if Segments.Granularity = 'word' then
    Item.CreateDataProperty(R, R.Intern('isWordLike'), JsBoolean(Segments.WordLike[Index]));
  Result := JsObjectValue(Item);
end;

function SegmenterSegment(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Target: TIntlObject;
  Text: TJsString;
  Segments: TSegments;
begin
  if not ThisIntl(R, This, ikSegmenter, Target) then
    Exit(JsException);
  Text := ToJsString(R, Arg(Args, ArgCount, 0));
  if Text = nil then
    Exit(JsException);
  Segments := TSegments(R.NewObjectOfClass(TSegments, TJsObject(JsAsObject(Callee.Data)), ocObject));
  Segments.Input := JsStringValue(Text);
  Segments.Granularity := Target.Setting('granularity');
  SegmentText(Segments, StringToUnicode(R.Heap, Text));
  Result := JsObjectValue(Segments);
end;

function SegmentsContaining(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Segments: TSegments;
  Number: Double;
  Index: Integer;
begin
  if not JsIsObject(This) or not (JsAsObject(This) is TSegments) then
    Exit(R.ThrowTypeError('Method called on incompatible receiver'));
  Segments := TSegments(JsAsObject(This));
  if not ToIntegerOrInfinity(R, Arg(Args, ArgCount, 0), Number) then
    Exit(JsException);
  if (Number < 0) or (Number >= JsAsString(Segments.Input).Length) then
    Exit(JsUndefined);
  Index := High(Segments.Starts);
  while (Index > 0) and (Segments.Starts[Index] > Number) do
    Dec(Index);
  Result := SegmentData(R, Segments, Index);
end;

function SegmentsIterator(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Source, Iterator: TSegments;
begin
  if not JsIsObject(This) or not (JsAsObject(This) is TSegments) then
    Exit(R.ThrowTypeError('Method called on incompatible receiver'));
  Source := TSegments(JsAsObject(This));
  Iterator := TSegments(R.NewObjectOfClass(TSegments, TJsObject(JsAsObject(Callee.Data)), ocIterator));
  Iterator.Input := Source.Input;
  Iterator.Granularity := Source.Granularity;
  Iterator.Starts := Source.Starts;
  Iterator.WordLike := Source.WordLike;
  Result := JsObjectValue(Iterator);
end;

function SegmentIteratorNext(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Iterator: TSegments;
begin
  if not JsIsObject(This) or not (JsAsObject(This) is TSegments) then
    Exit(R.ThrowTypeError('Method called on incompatible receiver'));
  Iterator := TSegments(JsAsObject(This));
  if Iterator.Position >= Length(Iterator.Starts) then
    Exit(CreateIterResult(R, JsUndefined, True));
  Result := CreateIterResult(R, SegmentData(R, Iterator, Iterator.Position), False);
  Inc(Iterator.Position);
end;

function SegmenterResolvedOptions(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Target: TIntlObject;
  Output: TJsObject;
begin
  if not ThisIntl(R, This, ikSegmenter, Target) then
    Exit(JsException);
  Output := R.NewPlainObject;
  PutString(R, Output, 'locale', 'en-US');
  PutString(R, Output, 'granularity', Target.Setting('granularity'));
  Result := JsObjectValue(Output);
end;

{ ListFormat }

function ListFormatConstructor(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Target: TIntlObject;
  List: TStringArray;
  Options: TJsObject;
  Value: string;
begin
  if NewTarget = JsUndefined then
    Exit(R.ThrowTypeError('Constructor Intl.ListFormat requires ''new'''));
  if not LocaleList(R, Arg(Args, ArgCount, 0), List) then
    Exit(JsException);
  if not OptionsObject(R, Arg(Args, ArgCount, 1), Options) then
    Exit(JsException);
  Target := NewIntl(R, NewTarget, ikListFormat, nil);
  if Target = nil then
    Exit(JsException);
  if not StringOption(R, Options, 'type', ['conjunction', 'disjunction', 'unit'], Value) then
    Exit(JsException);
  if Value = '' then
    Value := 'conjunction';
  Target.Put('type', Value);
  if not StringOption(R, Options, 'style', ['long', 'short', 'narrow'], Value) then
    Exit(JsException);
  if Value = '' then
    Value := 'long';
  Target.Put('style', Value);
  Result := JsObjectValue(Target);
end;

function ListFormatParts(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  out Parts: TNumberParts): Boolean;
var
  Target: TIntlObject;
  Values: TJsValueList;
  Index: Integer;
  Last, Kind, Style: string;
begin
  Parts := nil;
  Result := False;
  if not ThisIntl(R, This, ikListFormat, Target) then
    Exit;
  Values := nil;
  if (Arg(Args, ArgCount, 0) <> JsUndefined) and not IterableToList(R, Args^[0], Values) then
    Exit;
  for Index := 0 to High(Values) do
    if not JsIsString(Values[Index]) then
    begin
      R.ThrowTypeError('Iterable yielded ' + ValueToPascal(R, Values[Index]) + ' which is not a string');
      Exit;
    end;
  Kind := Target.Setting('type');
  Style := Target.Setting('style');
  if Kind = 'disjunction' then
    Last := ' or '
  else if Kind = 'unit' then
  begin
    if Style = 'narrow' then
      Last := ' '
    else
      Last := ', ';
  end
  else if Style = 'long' then
    Last := ' and '
  else
    Last := ' & ';
  if (Kind = 'conjunction') and (Style = 'narrow') then
    Last := ', ';
  for Index := 0 to High(Values) do
  begin
    if Index > 0 then
    begin
      if Index < High(Values) then
      begin
        if (Kind = 'unit') and (Style = 'narrow') then
          AddPart(Parts, 'literal', ' ')
        else
          AddPart(Parts, 'literal', ', ');
      end
      else if (Length(Values) > 2) and (Kind <> 'unit') and not ((Kind = 'conjunction') and (Style = 'narrow')) then
        AddPart(Parts, 'literal', ',' + Last)
      else
        AddPart(Parts, 'literal', Last);
    end;
    AddPart(Parts, 'element', StringToUtf8(R.Heap, JsAsString(Values[Index])));
  end;
  Result := True;
end;

function ListFormatFormat(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Parts: TNumberParts;
  Text: string;
  Index: Integer;
begin
  if not ListFormatParts(R, This, Args, ArgCount, Parts) then
    Exit(JsException);
  if Callee.Magic = 1 then
    Exit(PartsArray(R, Parts));
  Text := '';
  for Index := 0 to High(Parts) do
    Text := Text + Parts[Index].Value;
  Result := R.NewString(Text);
end;

{ The bound functions: format of NumberFormat (Magic 0) and
  DateTimeFormat (1), compare of Collator (2). }
function BoundGetter(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
const
  Kinds: array[0..2] of TIntlKind = (ikNumberFormat, ikDateTimeFormat, ikCollator);
var
  Target: TIntlObject;
  Bound: TJsNativeFunction;
begin
  if not ThisIntl(R, This, Kinds[Callee.Magic], Target) then
    Exit(JsException);
  if Target.BoundFunction = JsUndefined then
  begin
    case Callee.Magic of
      0: Bound := NewNativeFunction(R, '', @NumberFormatFormat, 1);
      1: Bound := NewNativeFunction(R, '', @DateTimeFormatFormat, 1);
    else
      Bound := NewNativeFunction(R, '', @CollatorCompare, 2);
    end;
    Bound.Data := This;
    Target.BoundFunction := JsObjectValue(Bound);
  end;
  Result := Target.BoundFunction;
end;

{ toLocaleString }

function NumberLocaleString(R: TJsRealm; Value: TJsValue; Locales, Options: TJsValue): TJsValue;
var
  Format: TIntlObject;
  Mark: Integer;
begin
  Format := NewIntl(R, JsUndefined, ikNumberFormat, R.Intrinsics[inObjectPrototype]);
  Mark := R.Runtime.PushRoot(JsObjectValue(Format));
  try
    if not InitializeNumberFormat(R, Format, Locales, Options) then
      Exit(JsException);
    Result := R.NewString(FormatNumberText(R, Format, Value));
  finally
    R.Runtime.PopRoots(Mark);
  end;
end;

function DateLocaleString(R: TJsRealm; Time: Double; Kind: Integer; Locales, Options: TJsValue): TJsValue;
const
  Required: array[0..2] of string = ('any', 'date', 'time');
  Defaults: array[0..2] of string = ('all', 'date', 'time');
var
  Format: TIntlObject;
  Mark: Integer;
begin
  Format := NewIntl(R, JsUndefined, ikDateTimeFormat, R.Intrinsics[inObjectPrototype]);
  Mark := R.Runtime.PushRoot(JsObjectValue(Format));
  try
    if not InitializeDateTimeFormat(R, Format, Locales, Options, Required[Kind], Defaults[Kind]) then
      Exit(JsException);
    Result := R.NewString(FormatDateText(Format, Time));
  finally
    R.Runtime.PopRoots(Mark);
  end;
end;

function BigIntToLocaleString(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Value: TJsValue;
begin
  Value := This;
  if JsIsObject(Value) and (JsAsObject(Value).ObjectClass = ocBigInt) then
    Value := TJsPrimitiveObject(JsAsObject(Value)).PrimitiveValue;
  if not JsIsBigInt(Value) then
    Exit(R.ThrowTypeError('BigInt.prototype.toLocaleString requires a BigInt'));
  Result := NumberLocaleString(R, Value, Arg(Args, ArgCount, 0), Arg(Args, ArgCount, 1));
end;

function StringLocaleCompare(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  First, Second: TJsString;
begin
  if JsIsNullish(This) then
    Exit(R.ThrowTypeError('String.prototype.localeCompare called on null or undefined'));
  First := ToJsString(R, This);
  if First = nil then
    Exit(JsException);
  Second := ToJsString(R, Arg(Args, ArgCount, 0));
  if Second = nil then
    Exit(JsException);
  Result := JsInteger(CompareCodePoints(StringToUnicode(R.Heap, First), StringToUnicode(R.Heap, Second), False));
end;

procedure InstallIntl(R: TJsInterpreterRealm);
var
  Intl, Prototype, Segments, SegmentIterator: TJsObject;
  Constructor_: TJsNativeFunction;
  Getter: TJsValue;

  function AddConstructor(const Name: string; Callback: TJsNativeCallback; Length: Integer): TJsObject;
  begin
    Result := R.NewObject(R.Intrinsics[inObjectPrototype]);
    Constructor_ := DefineConstructor(R, Intl, Name, Callback, Length, Result);
    DefineMethod(R, Constructor_, 'supportedLocalesOf', @IntlSupportedLocales, 1);
    Result.DefineData(R, R.Runtime.SymbolValue(wsToStringTag), R.NewString('Intl.' + Name), PropertyConfigurable);
  end;

  procedure AddBound(Target: TJsObject; const Name: string; Magic: Integer);
  begin
    Getter := JsObjectValue(NewNativeFunction(R, 'get ' + Name, @BoundGetter, 0, Magic));
    Target.DefineAccessor(R, R.Intern(Name), Getter, JsUndefined, PropertyConfigurable);
  end;

begin
  Intl := R.NewObject(R.Intrinsics[inObjectPrototype]);
  R.GlobalObject.DefineData(R, R.Intern('Intl'), JsObjectValue(Intl), PropertyHidden);
  Intl.DefineData(R, R.Runtime.SymbolValue(wsToStringTag), R.NewString('Intl'), PropertyConfigurable);
  DefineMethod(R, Intl, 'getCanonicalLocales', @IntlGetCanonicalLocales, 1);

  Prototype := AddConstructor('NumberFormat', @NumberFormatConstructor, 0);
  AddBound(Prototype, 'format', 0);
  DefineMethod(R, Prototype, 'formatToParts', @NumberFormatToParts, 1);
  DefineMethod(R, Prototype, 'resolvedOptions', @NumberResolvedOptions, 0);

  Prototype := AddConstructor('DateTimeFormat', @DateTimeFormatConstructor, 0);
  AddBound(Prototype, 'format', 1);
  DefineMethod(R, Prototype, 'formatToParts', @DateTimeFormatToParts, 1);
  DefineMethod(R, Prototype, 'resolvedOptions', @DateResolvedOptions, 0);

  Prototype := AddConstructor('Collator', @CollatorConstructor, 0);
  AddBound(Prototype, 'compare', 2);
  DefineMethod(R, Prototype, 'resolvedOptions', @CollatorResolvedOptions, 0);

  Prototype := AddConstructor('PluralRules', @PluralRulesConstructor, 0);
  DefineMethod(R, Prototype, 'select', @PluralRulesSelect, 1);
  DefineMethod(R, Prototype, 'resolvedOptions', @PluralResolvedOptions, 0);

  Prototype := AddConstructor('Segmenter', @SegmenterConstructor, 0);
  Segments := R.NewObject(R.Intrinsics[inObjectPrototype]);
  SegmentIterator := R.NewObject(R.Intrinsics[inIteratorPrototype]);
  DefineMethod(R, Prototype, 'segment', @SegmenterSegment, 1);
  TJsNativeFunction(JsAsObject(Prototype.GetValue(R, R.Intern('segment')))).Data := JsObjectValue(Segments);
  DefineMethod(R, Prototype, 'resolvedOptions', @SegmenterResolvedOptions, 0);
  DefineMethod(R, Segments, 'containing', @SegmentsContaining, 1);
  DefineSymbolMethod(R, Segments, wsIterator, '[Symbol.iterator]', @SegmentsIterator, 0);
  TJsNativeFunction(JsAsObject(Segments.GetValue(R, R.Runtime.SymbolValue(wsIterator)))).Data :=
    JsObjectValue(SegmentIterator);
  DefineMethod(R, SegmentIterator, 'next', @SegmentIteratorNext, 0);
  SegmentIterator.DefineData(R, R.Runtime.SymbolValue(wsToStringTag), R.NewString('Segmenter String Iterator'),
    PropertyConfigurable);

  Prototype := AddConstructor('ListFormat', @ListFormatConstructor, 0);
  DefineMethod(R, Prototype, 'format', @ListFormatFormat, 1, 0);
  DefineMethod(R, Prototype, 'formatToParts', @ListFormatFormat, 1, 1);

  DefineMethod(R, R.Intrinsics[inBigIntPrototype], 'toLocaleString', @BigIntToLocaleString, 0);
  DefineMethod(R, R.Intrinsics[inStringPrototype], 'localeCompare', @StringLocaleCompare, 1);
  JsNumberLocaleHook := @NumberLocaleString;
  JsDateLocaleHook := @DateLocaleString;
end;

end.
