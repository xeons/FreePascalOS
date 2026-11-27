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
  The abstract operations of type conversion and comparison.

  ToPrimitive (calling Symbol.toPrimitive, valueOf, toString), ToNumber,
  ToNumeric, ToString, ToObject, ToPropertyKey, the integer conversions,
  typeof, loose equality and the relational comparison. Each that can
  run JavaScript or throw takes the realm and returns JsException (or
  False) when it threw.

  Numbers print as the specification says (Number::toString): the
  shortest digits that read back as the same double, in plain notation
  for exponents from -7 to 20 and in exponential notation otherwise.
  Strings read as numbers by the StringNumericLiteral grammar
  (whitespace around, Infinity, 0x / 0o / 0b, no trailing garbage).
}
unit Js.Conversions;

{$mode objfpc}{$H+}
{$R-}{$Q-}

interface

uses
  SysUtils,
  Math,
  Js.Values,
  Js.Heap,
  Js.Strings,
  Js.Symbols,
  Js.Atoms,
  Js.Runtime,
  Js.Objects,
  Js.Functions,
  Js.BigIntegers;

type
  TJsPreferredType = (ptDefault, ptNumber, ptString);

{ Whether Value is an object with [[IsHTMLDDA]] (document.all). }
function IsHtmlDda(Value: TJsValue): Boolean;
function ToBoolean(Value: TJsValue): Boolean;
function ToPrimitive(R: TJsRealm; Value: TJsValue; Preferred: TJsPreferredType = ptDefault): TJsValue;
function ToNumber(R: TJsRealm; Value: TJsValue): TJsValue;
function ToNumeric(R: TJsRealm; Value: TJsValue): TJsValue;
{ False when it threw. }
function ToDouble(R: TJsRealm; Value: TJsValue; out Number: Double): Boolean;
function ToStringValue(R: TJsRealm; Value: TJsValue): TJsValue;
{ nil when it threw. }
function ToJsString(R: TJsRealm; Value: TJsValue): TJsString;
function ToObject(R: TJsRealm; Value: TJsValue): TJsValue;
function ToPropertyKey(R: TJsRealm; Value: TJsValue): TJsValue;
function ToInt32(R: TJsRealm; Value: TJsValue; out Integer32: LongInt): Boolean;
function ToUint32(R: TJsRealm; Value: TJsValue; out Unsigned32: LongWord): Boolean;
function ToIntegerOrInfinity(R: TJsRealm; Value: TJsValue; out Number: Double): Boolean;
{ ToLength: 0 .. 2^53 - 1. }
function ToLength(R: TJsRealm; Value: TJsValue; out Length: Int64): Boolean;
{ A relative index argument (slice, at...) clamped to 0..Length. }
function RelativeIndex(R: TJsRealm; Value: TJsValue; Length: Int64; Default: Int64; out Index: Int64): Boolean;
function DoubleToInt32(Value: Double): LongInt;
function DoubleToUint32(Value: Double): LongWord;

function NumberToString(Value: Double): string;
function NumberToJsString(R: TJsRealm; Value: Double): TJsString;
function NumberToRadixString(Value: Double; Radix: Integer): string;
{ The shortest round-trip digits and the decimal exponent:
  Value = 0.Digits * 10^Exponent. }
procedure ShortestDigits(Value: Double; out Digits: string; out Exponent: Integer);
function StringToNumber(R: TJsRealm; Text: TJsString): Double;
function TextToNumber(const Text: string): Double;
function IsJsSpace(Code: Word): Boolean;

{ An integer key's string. }
function KeyToStringValue(R: TJsRealm; Key: TJsValue): TJsValue;
function KeyToPascal(R: TJsRealm; Key: TJsValue): string;
function ValueToPascal(R: TJsRealm; Value: TJsValue): string;
{ Throws an error whose message names a key (KeyToPascal) or a value
  (ValueToPascal) between two texts. The message is made in here: a
  caller that made it itself would need a string of its own, costing it
  an exception frame on every call, thrown or not. }
function ThrowNamingKey(R: TJsRealm; Kind: TJsErrorKind; const Before: string; Key: TJsValue;
  const After: string): TJsValue;
function ThrowNamingValue(R: TJsRealm; Kind: TJsErrorKind; const Before: string; Value: TJsValue;
  const After: string): TJsValue;

function TypeofValue(R: TJsRealm; Value: TJsValue): TJsValue;
{ ==; False when it threw. }
function LooselyEquals(R: TJsRealm; First, Second: TJsValue; out Equal: Boolean): Boolean;
{ First < Second: 1 true, 0 false, 2 undefined (a NaN), -1 thrown. }
function LessThan(R: TJsRealm; First, Second: TJsValue; LeftFirst: Boolean): Integer;
function InstanceOf(R: TJsRealm; Value, Target: TJsValue): TJsValue;
function OrdinaryHasInstance(R: TJsRealm; Constructor_, Value: TJsValue): TJsValue;
function StringFromValue(R: TJsRealm; Value: TJsValue): TJsString; inline;

implementation

function StringFromValue(R: TJsRealm; Value: TJsValue): TJsString;
begin
  Result := JsAsString(Value);
end;

function IsJsSpace(Code: Word): Boolean;
begin
  case Code of
    9, 10, 11, 12, 13, 32, $A0, $1680, $2000..$200A, $2028, $2029, $202F, $205F, $3000, $FEFF:
      Result := True;
  else
    Result := False;
  end;
end;

function IsHtmlDda(Value: TJsValue): Boolean;
begin
  Result := JsIsObject(Value) and ((JsAsObject(Value).ObjectFlags and ObjectHtmlDda) <> 0);
end;

function ToBoolean(Value: TJsValue): Boolean;
var
  Number: Double;
begin
  if Value = JsTrue then
    Exit(True);
  if (Value = JsFalse) or (Value = JsUndefined) or (Value = JsNull) then
    Exit(False);
  if JsIsInteger(Value) then
    Exit(JsAsInteger(Value) <> 0);
  if JsIsDouble(Value) then
  begin
    Number := JsAsDouble(Value);
    Exit(not ((Number = 0) or IsNaNDouble(Number)));
  end;
  if JsIsString(Value) then
    Exit(JsAsString(Value).Length > 0);
  if JsIsBigInt(Value) then
    Exit(not TJsBigInt(JsAsCell(Value)).IsZero);
  Result := not IsHtmlDda(Value);
end;

function ToPrimitive(R: TJsRealm; Value: TJsValue; Preferred: TJsPreferredType): TJsValue;
var
  Target: TJsObject;
  Exotic, Method, HintValue, Outcome: TJsValue;
  Names: array[0..1] of TJsAtomName;
  Index: Integer;
begin
  if not JsIsObject(Value) then
    Exit(Value);
  Target := JsAsObject(Value);
  Exotic := Target.GetValue(R, R.Runtime.SymbolValue(wsToPrimitive));
  if Exotic = JsException then
    Exit(JsException);
  if not JsIsNullish(Exotic) then
  begin
    if not JsIsCallable(Exotic) then
      Exit(R.ThrowTypeError('Symbol.toPrimitive is not a function'));
    case Preferred of
      ptNumber: HintValue := R.Atom(anNumber);
      ptString: HintValue := R.Atom(anString);
    else
      HintValue := R.Atom(anDefault);
    end;
    Outcome := R.Call(Exotic, Value, @HintValue, 1);
    if Outcome = JsException then
      Exit(JsException);
    if JsIsObject(Outcome) then
      Exit(R.ThrowTypeError('Cannot convert object to primitive value'));
    Exit(Outcome);
  end;
  if Preferred = ptString then
  begin
    Names[0] := anToString;
    Names[1] := anValueOf;
  end
  else
  begin
    Names[0] := anValueOf;
    Names[1] := anToString;
  end;
  for Index := 0 to 1 do
  begin
    Method := Target.GetValue(R, R.Atom(Names[Index]));
    if Method = JsException then
      Exit(JsException);
    if JsIsCallable(Method) then
    begin
      Outcome := R.Call(Method, Value, nil, 0);
      if Outcome = JsException then
        Exit(JsException);
      if not JsIsObject(Outcome) then
        Exit(Outcome);
    end;
  end;
  Result := R.ThrowTypeError('Cannot convert object to primitive value');
end;

function ToNumber(R: TJsRealm; Value: TJsValue): TJsValue;
begin
  if JsIsNumber(Value) then
    Exit(Value);
  case Value of
    JsUndefined: Exit(JsNaN);
    JsNull, JsFalse: Exit(JsInteger(0));
    JsTrue: Exit(JsInteger(1));
  end;
  if JsIsString(Value) then
    Exit(JsNumber(StringToNumber(R, JsAsString(Value))));
  if JsIsSymbol(Value) then
    Exit(R.ThrowTypeError('Cannot convert a Symbol value to a number'));
  if JsIsBigInt(Value) then
    Exit(R.ThrowTypeError('Cannot convert a BigInt value to a number'));
  Value := ToPrimitive(R, Value, ptNumber);
  if Value = JsException then
    Exit(JsException);
  Result := ToNumber(R, Value);
end;

function ToNumeric(R: TJsRealm; Value: TJsValue): TJsValue;
begin
  if JsIsNumber(Value) or JsIsBigInt(Value) then
    Exit(Value);
  Value := ToPrimitive(R, Value, ptNumber);
  if Value = JsException then
    Exit(JsException);
  if JsIsBigInt(Value) then
    Exit(Value);
  Result := ToNumber(R, Value);
end;

function ToDouble(R: TJsRealm; Value: TJsValue; out Number: Double): Boolean;
begin
  if not JsIsNumber(Value) then
  begin
    Value := ToNumber(R, Value);
    if Value = JsException then
    begin
      Number := 0;
      Exit(False);
    end;
  end;
  Number := JsNumberValue(Value);
  Result := True;
end;

{ The decimal text of an integer, written straight into a new string. }
function IntegerToJsString(R: TJsRealm; Value: LongInt): TJsString;
var
  Characters: array[0..11] of Byte;
  Position: Integer;
  Magnitude: LongWord;
begin
  Position := High(Characters) + 1;
  if Value < 0 then
    Magnitude := LongWord(-Int64(Value))
  else
    Magnitude := LongWord(Value);
  repeat
    Dec(Position);
    Characters[Position] := Ord('0') + Magnitude mod 10;
    Magnitude := Magnitude div 10;
  until Magnitude = 0;
  if Value < 0 then
  begin
    Dec(Position);
    Characters[Position] := Ord('-');
  end;
  Result := NewLatin1String(R.Heap, @Characters[Position], High(Characters) + 1 - Position);
end;

{ Apart from ToStringValue, which then needs no text of its own. }
function BigIntToStringValue(R: TJsRealm; Value: TJsValue): TJsValue;
begin
  Result := R.NewString(BigIntToText(TJsBigInt(JsAsCell(Value)), 10));
end;

function ToStringValue(R: TJsRealm; Value: TJsValue): TJsValue;
begin
  if JsIsString(Value) then
    Exit(Value);
  if JsIsInteger(Value) then
  begin
    if (JsAsInteger(Value) >= 0) and (JsAsInteger(Value) < 10) then
      Exit(JsStringValue(R.Runtime.CharacterString(Ord('0') + JsAsInteger(Value))));
    Exit(JsStringValue(IntegerToJsString(R, JsAsInteger(Value))));
  end;
  if JsIsDouble(Value) then
    Exit(JsStringValue(NumberToJsString(R, JsAsDouble(Value))));
  case Value of
    JsUndefined: Exit(R.Atom(anUndefined));
    JsNull: Exit(R.Atom(anNull));
    JsTrue: Exit(R.Atom(anTrue));
    JsFalse: Exit(R.Atom(anFalse));
  end;
  if JsIsSymbol(Value) then
    Exit(R.ThrowTypeError('Cannot convert a Symbol value to a string'));
  if JsIsBigInt(Value) then
    Exit(BigIntToStringValue(R, Value));
  Value := ToPrimitive(R, Value, ptString);
  if Value = JsException then
    Exit(JsException);
  Result := ToStringValue(R, Value);
end;

function ToJsString(R: TJsRealm; Value: TJsValue): TJsString;
begin
  Value := ToStringValue(R, Value);
  if Value = JsException then
    Exit(nil);
  Result := JsAsString(Value);
end;

function ToObject(R: TJsRealm; Value: TJsValue): TJsValue;
var
  Wrapper: TJsPrimitiveObject;
begin
  if JsIsObject(Value) then
    Exit(Value);
  if JsIsNullish(Value) then
    Exit(R.ThrowTypeError('Cannot convert undefined or null to object'));
  if JsIsNumber(Value) then
    Wrapper := TJsPrimitiveObject(R.NewObjectOfClass(TJsPrimitiveObject, R.Intrinsics[inNumberPrototype], ocNumber))
  else if JsIsString(Value) then
  begin
    Wrapper := TJsPrimitiveObject(R.NewObjectOfClass(TJsPrimitiveObject, R.Intrinsics[inStringPrototype], ocString));
    Wrapper.ObjectFlags := Wrapper.ObjectFlags or ObjectExotic;
  end
  else if JsIsBoolean(Value) then
    Wrapper := TJsPrimitiveObject(R.NewObjectOfClass(TJsPrimitiveObject, R.Intrinsics[inBooleanPrototype], ocBoolean))
  else if JsIsSymbol(Value) then
    Wrapper := TJsPrimitiveObject(R.NewObjectOfClass(TJsPrimitiveObject, R.Intrinsics[inSymbolPrototype], ocSymbol))
  else
    Wrapper := TJsPrimitiveObject(R.NewObjectOfClass(TJsPrimitiveObject, R.Intrinsics[inBigIntPrototype], ocBigInt));
  Wrapper.PrimitiveValue := Value;
  Result := JsObjectValue(Wrapper);
end;

function ToPropertyKey(R: TJsRealm; Value: TJsValue): TJsValue;
var
  Number: Double;
  Text: TJsString;
  Index: LongWord;
begin
  if JsIsInteger(Value) then
  begin
    if JsAsInteger(Value) >= 0 then
      Exit(Value);
    Exit(JsStringValue(R.Runtime.Atoms.Intern(IntegerToJsString(R, JsAsInteger(Value)))));
  end;
  if JsIsString(Value) then
  begin
    Text := JsAsString(Value);
    Text.Flatten(R.Heap);
    if Text.ArrayIndex(Index) and (Index <= 2147483647) then
      Exit(JsInteger(LongInt(Index)));
    Exit(JsStringValue(R.Runtime.Atoms.Intern(Text)));
  end;
  if JsIsSymbol(Value) then
    Exit(Value);
  if JsIsDouble(Value) then
  begin
    Number := JsAsDouble(Value);
    if Number = 0 then
      Exit(JsInteger(0));
    Exit(JsStringValue(R.Runtime.Atoms.Intern(NumberToJsString(R, Number))));
  end;
  Value := ToPrimitive(R, Value, ptString);
  if Value = JsException then
    Exit(JsException);
  if not JsIsString(Value) and not JsIsSymbol(Value) and not JsIsNumber(Value) then
  begin
    Value := ToStringValue(R, Value);
    if Value = JsException then
      Exit(JsException);
  end;
  Result := ToPropertyKey(R, Value);
end;

function DoubleToInt32(Value: Double): LongInt;
var
  Truncated, Modulus: Double;
begin
  if IsNaNDouble(Value) or not IsFiniteDouble(Value) then
    Exit(0);
  if (Value >= -2147483648.0) and (Value <= 2147483647.0) then
    Exit(Trunc(Value));
  Truncated := Int(Value);
  Modulus := Truncated - FloorDouble(Truncated / 4294967296.0) * 4294967296.0;
  Result := LongInt(LongWord(Trunc(Modulus)));
end;

function DoubleToUint32(Value: Double): LongWord;
begin
  Result := LongWord(DoubleToInt32(Value));
end;

function ToInt32(R: TJsRealm; Value: TJsValue; out Integer32: LongInt): Boolean;
var
  Number: Double;
begin
  if JsIsInteger(Value) then
  begin
    Integer32 := JsAsInteger(Value);
    Exit(True);
  end;
  Integer32 := 0;
  if not ToDouble(R, Value, Number) then
    Exit(False);
  Integer32 := DoubleToInt32(Number);
  Result := True;
end;

function ToUint32(R: TJsRealm; Value: TJsValue; out Unsigned32: LongWord): Boolean;
var
  Integer32: LongInt;
begin
  Result := ToInt32(R, Value, Integer32);
  Unsigned32 := LongWord(Integer32);
end;

function ToIntegerOrInfinity(R: TJsRealm; Value: TJsValue; out Number: Double): Boolean;
begin
  if JsIsInteger(Value) then
  begin
    Number := JsAsInteger(Value);
    Exit(True);
  end;
  if not ToDouble(R, Value, Number) then
    Exit(False);
  if IsNaNDouble(Number) then
    Number := 0
  else if IsFiniteDouble(Number) then
    Number := Int(Number);
  if Number = 0 then
    Number := 0;
  Result := True;
end;

function ToLength(R: TJsRealm; Value: TJsValue; out Length: Int64): Boolean;
var
  Number: Double;
begin
  Length := 0;
  if JsIsInteger(Value) then
  begin
    if JsAsInteger(Value) > 0 then
      Length := JsAsInteger(Value);
    Exit(True);
  end;
  if not ToIntegerOrInfinity(R, Value, Number) then
    Exit(False);
  if Number <= 0 then
    Length := 0
  else if Number >= 9007199254740991.0 then
    Length := 9007199254740991
  else
    Length := Trunc(Number);
  Result := True;
end;

function RelativeIndex(R: TJsRealm; Value: TJsValue; Length: Int64; Default: Int64; out Index: Int64): Boolean;
var
  Number: Double;
begin
  Index := Default;
  if Value = JsUndefined then
    Exit(True);
  if not ToIntegerOrInfinity(R, Value, Number) then
    Exit(False);
  if Number < 0 then
  begin
    Number := Length + Number;
    if Number < 0 then
      Number := 0;
  end
  else if Number > Length then
    Number := Length;
  Index := Trunc(Number);
  Result := True;
end;

{ Number to text }

{ Value in exponent form with Precision significant digits, correctly
  rounded ("d.dddE+xx"), when that reads back as Value. }
function RoundTripText(Value: Double; Precision: Integer; out Text: string): Boolean;
var
  Check: Double;
  Code: Integer;
begin
  Text := FloatToStrF(Value, ffExponent, Precision, 0, DefaultFormatSettings);
  Val(Text, Check, Code);
  Result := (Code = 0) and (Check = Value);
end;

{ The shortest digits are those of the first precision whose correctly
  rounded text reads back as Value. Up to 15 digits there is no need to
  try each: half a double's spacing is under a fifth of the spacing of
  15-digit decimals, so a round trip of k <= 15 digits exists exactly
  when the 15-digit rounding reads back, and is that rounding without
  its trailing zeros. Only 16 and 17 digits are left to try. Subnormal
  doubles have fewer bits, wider spacing, and try every precision. }
procedure ShortestDigits(Value: Double; out Digits: string; out Exponent: Integer);
const
  SmallestNormal = 2.2250738585072014e-308;
var
  Position, Code, ExponentPosition, Precision: Integer;
  Text, Mantissa: string;
begin
  Digits := '';
  Exponent := 0;
  if Abs(Value) >= SmallestNormal then
    Precision := 15
  else
    Precision := 1;
  while not RoundTripText(Value, Precision, Text) and (Precision < 17) do
    Inc(Precision);
  { Text: d.dddE+xx }
  { The runtime leaves out a zero exponent. }
  ExponentPosition := Pos('E', Text);
  if ExponentPosition = 0 then
  begin
    Mantissa := Text;
    Exponent := 0;
  end
  else
  begin
    Mantissa := Copy(Text, 1, ExponentPosition - 1);
    Val(Copy(Text, ExponentPosition + 1, MaxInt), Exponent, Code);
  end;
  SetLength(Digits, System.Length(Mantissa));
  Code := 0;
  for Position := 1 to System.Length(Mantissa) do
    if Mantissa[Position] in ['0'..'9'] then
    begin
      Inc(Code);
      Digits[Code] := Mantissa[Position];
    end;
  while (Code > 1) and (Digits[Code] = '0') do
    Dec(Code);
  SetLength(Digits, Code);
  Inc(Exponent);
end;

function NumberToString(Value: Double): string;
var
  Digits: string;
  Exponent, Count: Integer;
  Integer32: LongInt;
begin
  if IsNaNDouble(Value) then
    Exit('NaN');
  if Value = 0 then
    Exit('0');
  if not IsFiniteDouble(Value) then
  begin
    if Value > 0 then
      Exit('Infinity');
    Exit('-Infinity');
  end;
  if DoubleIsInt32(Value, Integer32) then
    Exit(IntToStr(Integer32));
  if Value < 0 then
    Exit('-' + NumberToString(-Value));
  ShortestDigits(Value, Digits, Exponent);
  Count := Length(Digits);
  if (Count <= Exponent) and (Exponent <= 21) then
    Result := Digits + StringOfChar('0', Exponent - Count)
  else if (0 < Exponent) and (Exponent <= 21) then
    Result := Copy(Digits, 1, Exponent) + '.' + Copy(Digits, Exponent + 1, MaxInt)
  else if (-6 < Exponent) and (Exponent <= 0) then
    Result := '0.' + StringOfChar('0', -Exponent) + Digits
  else
  begin
    Result := Digits[1];
    if Count > 1 then
      Result := Result + '.' + Copy(Digits, 2, MaxInt);
    if Exponent - 1 >= 0 then
      Result := Result + 'e+' + IntToStr(Exponent - 1)
    else
      Result := Result + 'e-' + IntToStr(1 - Exponent);
  end;
end;

{ A number through its text: apart from NumberToJsString so that int32
  values, written directly, skip setting up and freeing the text. }
function NumberTextToJsString(R: TJsRealm; Value: Double): TJsString;
var
  Text: string;
begin
  Text := NumberToString(Value);
  Result := NewLatin1String(R.Heap, PByte(PChar(Text)), Length(Text));
end;

function NumberToJsString(R: TJsRealm; Value: Double): TJsString;
var
  Integer32: LongInt;
begin
  if DoubleIsInt32(Value, Integer32) then
    Exit(IntegerToJsString(R, Integer32));
  Result := NumberTextToJsString(R, Value);
end;

function NumberToRadixString(Value: Double; Radix: Integer): string;
const
  DigitCharacters = '0123456789abcdefghijklmnopqrstuvwxyz';
var
  Negative: Boolean;
  IntegerPart, Fraction, Digit: Double;
  Whole, Fractional: string;
  Count: Integer;
begin
  if IsNaNDouble(Value) then
    Exit('NaN');
  if not IsFiniteDouble(Value) then
  begin
    if Value > 0 then
      Exit('Infinity');
    Exit('-Infinity');
  end;
  if Value = 0 then
    Exit('0');
  Negative := Value < 0;
  Value := Abs(Value);
  IntegerPart := Int(Value);
  Fraction := Value - IntegerPart;
  Whole := '';
  repeat
    Digit := IntegerPart - Int(IntegerPart / Radix) * Radix;
    Whole := DigitCharacters[Trunc(Digit) + 1] + Whole;
    IntegerPart := Int(IntegerPart / Radix);
  until IntegerPart < 1;
  Fractional := '';
  Count := 0;
  while (Fraction > 0) and (Count < 52) do
  begin
    Fraction := Fraction * Radix;
    Digit := Int(Fraction);
    Fractional := Fractional + DigitCharacters[Trunc(Digit) + 1];
    Fraction := Fraction - Digit;
    Inc(Count);
  end;
  Result := Whole;
  if Fractional <> '' then
    Result := Result + '.' + Fractional;
  if Negative then
    Result := '-' + Result;
end;

{ Text to number }

function TextToNumber(const Text: string): Double;
var
  Start, Finish, Position, Code, Radix: Integer;
  Body: string;
  Negative, SawDigit: Boolean;
  Value: Double;

  function DigitOf(Character: Char): Integer;
  begin
    case Character of
      '0'..'9': Result := Ord(Character) - Ord('0');
      'a'..'z': Result := Ord(Character) - Ord('a') + 10;
      'A'..'Z': Result := Ord(Character) - Ord('A') + 10;
    else
      Result := 99;
    end;
  end;

begin
  Start := 1;
  Finish := Length(Text);
  while (Start <= Finish) and (Text[Start] in [#9, #10, #11, #12, #13, ' ']) do
    Inc(Start);
  while (Finish >= Start) and (Text[Finish] in [#9, #10, #11, #12, #13, ' ']) do
    Dec(Finish);
  if Start > Finish then
    Exit(0);
  Body := Copy(Text, Start, Finish - Start + 1);
  if (Length(Body) > 2) and (Body[1] = '0') and (Body[2] in ['x', 'X', 'o', 'O', 'b', 'B']) then
  begin
    case Body[2] of
      'x', 'X': Radix := 16;
      'o', 'O': Radix := 8;
    else
      Radix := 2;
    end;
    Value := 0;
    for Position := 3 to Length(Body) do
    begin
      if DigitOf(Body[Position]) >= Radix then
        Exit(BitsDouble(JsNaN));
      Value := Value * Radix + DigitOf(Body[Position]);
    end;
    Exit(Value);
  end;
  Negative := False;
  Position := 1;
  if Body[1] in ['+', '-'] then
  begin
    Negative := Body[1] = '-';
    Position := 2;
  end;
  if Copy(Body, Position, MaxInt) = 'Infinity' then
  begin
    if Negative then
      Exit(NegInfinity);
    Exit(Infinity);
  end;
  { Validate: digits [. digits] [e [+-] digits] }
  SawDigit := False;
  Start := Position;
  while (Position <= Length(Body)) and (Body[Position] in ['0'..'9']) do
  begin
    Inc(Position);
    SawDigit := True;
  end;
  if (Position <= Length(Body)) and (Body[Position] = '.') then
  begin
    Inc(Position);
    while (Position <= Length(Body)) and (Body[Position] in ['0'..'9']) do
    begin
      Inc(Position);
      SawDigit := True;
    end;
  end;
  if not SawDigit then
    Exit(BitsDouble(JsNaN));
  if (Position <= Length(Body)) and (Body[Position] in ['e', 'E']) then
  begin
    Inc(Position);
    if (Position <= Length(Body)) and (Body[Position] in ['+', '-']) then
      Inc(Position);
    if (Position > Length(Body)) or not (Body[Position] in ['0'..'9']) then
      Exit(BitsDouble(JsNaN));
    while (Position <= Length(Body)) and (Body[Position] in ['0'..'9']) do
      Inc(Position);
  end;
  if Position <= Length(Body) then
    Exit(BitsDouble(JsNaN));
  Body := Copy(Body, Start, MaxInt);
  if Body[1] = '.' then
    Body := '0' + Body;
  Position := Pos('.', Body);
  if (Position > 0) and ((Position = Length(Body)) or (Body[Position + 1] in ['e', 'E'])) then
    Insert('0', Body, Position + 1);
  Val(Body, Value, Code);
  if Code <> 0 then
    Exit(BitsDouble(JsNaN));
  if Negative then
    Value := -Value;
  Result := Value;
end;

{ Units Start..Finish of Text when they are up to 9 decimal digits,
  perhaps after a minus sign: the common case, read without the text. }
function ShortDecimalValue(Text: TJsString; Start, Finish: Integer; out Value: Double): Boolean;
var
  Index: Integer;
  Negative: Boolean;
  Code: Word;
  Magnitude: LongInt;
begin
  Result := False;
  Negative := (Start < Finish) and (Text.CharAt(Start) = Ord('-'));
  if Negative then
    Inc(Start);
  if (Finish < Start) or (Finish - Start >= 9) then
    Exit;
  Magnitude := 0;
  for Index := Start to Finish do
  begin
    Code := Text.CharAt(Index);
    if (Code < Ord('0')) or (Code > Ord('9')) then
      Exit;
    Magnitude := Magnitude * 10 + (Code - Ord('0'));
  end;
  Value := Magnitude;
  if Negative then
    Value := -Value;
  Result := True;
end;

function TrimmedTextToNumber(Text: TJsString; Start, Finish: Integer): Double;
var
  Ascii: string;
  Index: Integer;
  Code: Word;
begin
  Ascii := '';
  SetLength(Ascii, Finish - Start + 1);
  for Index := Start to Finish do
  begin
    Code := Text.CharAt(Index);
    if Code > 127 then
      Exit(BitsDouble(JsNaN));
    Ascii[Index - Start + 1] := Char(Code);
  end;
  Result := TextToNumber(Ascii);
end;

function StringToNumber(R: TJsRealm; Text: TJsString): Double;
var
  Start, Finish: Integer;
begin
  Text.Flatten(R.Heap);
  Start := 0;
  Finish := Text.Length - 1;
  while (Start <= Finish) and IsJsSpace(Text.CharAt(Start)) do
    Inc(Start);
  while (Finish >= Start) and IsJsSpace(Text.CharAt(Finish)) do
    Dec(Finish);
  if not ShortDecimalValue(Text, Start, Finish, Result) then
    Result := TrimmedTextToNumber(Text, Start, Finish);
end;

function KeyToStringValue(R: TJsRealm; Key: TJsValue): TJsValue;
begin
  if JsIsInteger(Key) then
    Result := ToStringValue(R, Key)
  else
    Result := Key;
end;

function KeyToPascal(R: TJsRealm; Key: TJsValue): string;
begin
  if JsIsInteger(Key) then
    Exit(IntToStr(JsAsInteger(Key)));
  if JsIsString(Key) then
    Exit(StringToUtf8(R.Heap, JsAsString(Key)));
  if JsIsSymbol(Key) then
  begin
    if JsAsSymbol(Key).Description = nil then
      Exit('Symbol()');
    Exit('Symbol(' + StringToUtf8(R.Heap, JsAsSymbol(Key).Description) + ')');
  end;
  Result := '';
end;

function ThrowNamingKey(R: TJsRealm; Kind: TJsErrorKind; const Before: string; Key: TJsValue;
  const After: string): TJsValue;
begin
  Result := R.ThrowError(Kind, Before + KeyToPascal(R, Key) + After);
end;

function ThrowNamingValue(R: TJsRealm; Kind: TJsErrorKind; const Before: string; Value: TJsValue;
  const After: string): TJsValue;
begin
  Result := R.ThrowError(Kind, Before + ValueToPascal(R, Value) + After);
end;

{ A short description for messages (never runs JavaScript). }
function ValueToPascal(R: TJsRealm; Value: TJsValue): string;
begin
  if JsIsString(Value) then
    Exit(StringToUtf8(R.Heap, JsAsString(Value)));
  if JsIsNumber(Value) then
    Exit(NumberToString(JsNumberValue(Value)));
  case Value of
    JsUndefined: Exit('undefined');
    JsNull: Exit('null');
    JsTrue: Exit('true');
    JsFalse: Exit('false');
  end;
  if JsIsSymbol(Value) then
    Exit(KeyToPascal(R, Value));
  if JsIsBigInt(Value) then
    Exit(BigIntToText(TJsBigInt(JsAsCell(Value)), 10) + 'n');
  if JsIsCallable(Value) then
    Exit('function');
  Result := 'object';
end;

function TypeofValue(R: TJsRealm; Value: TJsValue): TJsValue;
begin
  if JsIsNumber(Value) then
    Exit(R.Atom(anNumber));
  if JsIsString(Value) then
    Exit(R.Atom(anString));
  case Value of
    JsUndefined: Exit(R.Atom(anUndefined));
    JsNull: Exit(R.Atom(anObject));
    JsTrue, JsFalse: Exit(R.Atom(anBoolean));
  end;
  if JsIsSymbol(Value) then
    Exit(R.Atom(anSymbol));
  if JsIsBigInt(Value) then
    Exit(R.Atom(anBigInt));
  if IsHtmlDda(Value) then
    Exit(R.Atom(anUndefined));
  if JsIsCallable(Value) then
    Exit(R.Atom(anFunction));
  Result := R.Atom(anObject);
end;

function BigIntFromString(R: TJsRealm; Text: TJsString): TJsBigInt;
var
  Pascal: string;
  Negative: Boolean;
  Radix: Integer;
begin
  Pascal := Trim(StringToUtf8(R.Heap, Text));
  if Pascal = '' then
    Exit(BigIntFromInt64(R.Heap, 0));
  Negative := False;
  Radix := 10;
  if (Length(Pascal) > 2) and (Pascal[1] = '0') and (Pascal[2] in ['x', 'X', 'o', 'O', 'b', 'B']) then
  begin
    case Pascal[2] of
      'x', 'X': Radix := 16;
      'o', 'O': Radix := 8;
    else
      Radix := 2;
    end;
    Delete(Pascal, 1, 2);
  end
  else if Pascal[1] in ['+', '-'] then
  begin
    Negative := Pascal[1] = '-';
    Delete(Pascal, 1, 1);
  end;
  Result := BigIntFromText(R.Heap, Pascal, Radix, Negative);
end;

function LooselyEquals(R: TJsRealm; First, Second: TJsValue; out Equal: Boolean): Boolean;
var
  Converted: TJsValue;
  Big: TJsBigInt;
begin
  Result := True;
  Equal := False;
  while True do
  begin
    if JsIsNumber(First) and JsIsNumber(Second) then
    begin
      Equal := JsNumberValue(First) = JsNumberValue(Second);
      Exit;
    end;
    if JsIsNullish(First) and JsIsNullish(Second) then
    begin
      Equal := True;
      Exit;
    end;
    if (JsTag(First) = JsTag(Second)) and not JsIsNumber(First) then
    begin
      Equal := StrictEquals(First, Second, R.Heap);
      Exit;
    end;
    if JsIsNullish(First) or JsIsNullish(Second) then
    begin
      Equal := IsHtmlDda(First) or IsHtmlDda(Second);
      Exit;
    end;
    if JsIsNumber(First) and JsIsString(Second) then
    begin
      Second := ToNumber(R, Second);
      Continue;
    end;
    if JsIsString(First) and JsIsNumber(Second) then
    begin
      First := ToNumber(R, First);
      Continue;
    end;
    if JsIsBigInt(First) and JsIsString(Second) then
    begin
      Big := BigIntFromString(R, JsAsString(Second));
      if Big = nil then
        Exit;
      Second := JsCellValue(JsBigIntBase, Big);
      Continue;
    end;
    if JsIsString(First) and JsIsBigInt(Second) then
    begin
      Converted := First;
      First := Second;
      Second := Converted;
      Continue;
    end;
    if JsIsBoolean(First) then
    begin
      First := ToNumber(R, First);
      Continue;
    end;
    if JsIsBoolean(Second) then
    begin
      Second := ToNumber(R, Second);
      Continue;
    end;
    if JsIsObject(Second) and not JsIsObject(First) then
    begin
      Second := ToPrimitive(R, Second);
      if Second = JsException then
        Exit(False);
      Continue;
    end;
    if JsIsObject(First) and not JsIsObject(Second) then
    begin
      First := ToPrimitive(R, First);
      if First = JsException then
        Exit(False);
      Continue;
    end;
    if JsIsBigInt(First) and JsIsNumber(Second) then
    begin
      if IsNaNDouble(JsNumberValue(Second)) then
        Exit;
      Equal := BigIntCompareDouble(TJsBigInt(JsAsCell(First)), JsNumberValue(Second)) = 0;
      Exit;
    end;
    if JsIsNumber(First) and JsIsBigInt(Second) then
    begin
      Converted := First;
      First := Second;
      Second := Converted;
      Continue;
    end;
    Exit;
  end;
end;

function LessThan(R: TJsRealm; First, Second: TJsValue; LeftFirst: Boolean): Integer;
var
  A, B: Double;
  Big: TJsBigInt;
begin
  if JsIsInteger(First) and JsIsInteger(Second) then
    Exit(Ord(JsAsInteger(First) < JsAsInteger(Second)));
  if LeftFirst then
  begin
    First := ToPrimitive(R, First, ptNumber);
    if First = JsException then
      Exit(-1);
    Second := ToPrimitive(R, Second, ptNumber);
    if Second = JsException then
      Exit(-1);
  end
  else
  begin
    Second := ToPrimitive(R, Second, ptNumber);
    if Second = JsException then
      Exit(-1);
    First := ToPrimitive(R, First, ptNumber);
    if First = JsException then
      Exit(-1);
  end;
  if JsIsString(First) and JsIsString(Second) then
    Exit(Ord(CompareStrings(R.Heap, JsAsString(First), JsAsString(Second)) < 0));
  if JsIsBigInt(First) and JsIsString(Second) then
  begin
    Big := BigIntFromString(R, JsAsString(Second));
    if Big = nil then
      Exit(2);
    Exit(Ord(BigIntCompare(TJsBigInt(JsAsCell(First)), Big) < 0));
  end;
  if JsIsString(First) and JsIsBigInt(Second) then
  begin
    Big := BigIntFromString(R, JsAsString(First));
    if Big = nil then
      Exit(2);
    Exit(Ord(BigIntCompare(Big, TJsBigInt(JsAsCell(Second))) < 0));
  end;
  First := ToNumeric(R, First);
  if First = JsException then
    Exit(-1);
  Second := ToNumeric(R, Second);
  if Second = JsException then
    Exit(-1);
  if JsIsBigInt(First) and JsIsBigInt(Second) then
    Exit(Ord(BigIntCompare(TJsBigInt(JsAsCell(First)), TJsBigInt(JsAsCell(Second))) < 0));
  if JsIsBigInt(First) then
  begin
    B := JsNumberValue(Second);
    if IsNaNDouble(B) then
      Exit(2);
    Exit(Ord(BigIntCompareDouble(TJsBigInt(JsAsCell(First)), B) < 0));
  end;
  if JsIsBigInt(Second) then
  begin
    A := JsNumberValue(First);
    if IsNaNDouble(A) then
      Exit(2);
    Exit(Ord(BigIntCompareDouble(TJsBigInt(JsAsCell(Second)), A) > 0));
  end;
  A := JsNumberValue(First);
  B := JsNumberValue(Second);
  if IsNaNDouble(A) or IsNaNDouble(B) then
    Exit(2);
  Result := Ord(A < B);
end;

function OrdinaryHasInstance(R: TJsRealm; Constructor_, Value: TJsValue): TJsValue;
var
  Prototype: TJsValue;
  Walk: TJsObject;
  Target: TJsObject;
begin
  if not JsIsCallable(Constructor_) then
    Exit(JsFalse);
  Target := JsAsObject(Constructor_);
  if Target is TJsBoundFunction then
    Exit(InstanceOf(R, Value, TJsBoundFunction(Target).Target));
  if not JsIsObject(Value) then
    Exit(JsFalse);
  Prototype := Target.GetValue(R, R.PrototypeKey);
  if Prototype = JsException then
    Exit(JsException);
  if not JsIsObject(Prototype) then
    Exit(R.ThrowTypeError('Function has non-object prototype in instanceof check'));
  if not JsAsObject(Value).GetPrototype(R, Walk) then
    Exit(JsException);
  while Walk <> nil do
  begin
    if Walk = JsAsObject(Prototype) then
      Exit(JsTrue);
    if not Walk.GetPrototype(R, Walk) then
      Exit(JsException);
  end;
  Result := JsFalse;
end;

function InstanceOf(R: TJsRealm; Value, Target: TJsValue): TJsValue;
var
  Handler, Outcome: TJsValue;
begin
  if not JsIsObject(Target) then
    Exit(R.ThrowTypeError('Right-hand side of ''instanceof'' is not an object'));
  Handler := JsAsObject(Target).GetValue(R, R.Runtime.SymbolValue(wsHasInstance));
  if Handler = JsException then
    Exit(JsException);
  if not JsIsNullish(Handler) then
  begin
    Outcome := R.Call(Handler, Target, @Value, 1);
    if Outcome = JsException then
      Exit(JsException);
    Exit(JsBoolean(ToBoolean(Outcome)));
  end;
  if not JsIsCallable(Target) then
    Exit(R.ThrowTypeError('Right-hand side of ''instanceof'' is not callable'));
  Result := OrdinaryHasInstance(R, Target, Value);
end;

function ConvertForArrayLength(R: TJsRealm; Value: TJsValue): TJsValue;
var
  Number: Double;
  Unsigned: LongWord;
begin
  if not ToUint32(R, Value, Unsigned) then
    Exit(JsException);
  if not ToDouble(R, Value, Number) then
    Exit(JsException);
  if Number <> Unsigned then
    Exit(R.ThrowRangeError('Invalid array length'));
  Result := JsNumber(Unsigned);
end;

initialization
  JsToNumberHook := @ConvertForArrayLength;
end.
