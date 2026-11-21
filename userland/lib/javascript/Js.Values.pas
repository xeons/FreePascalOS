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
  JavaScript values: 64-bit NaN-boxed words.

  A value is a QWord. Every double but NaN is stored as its own bits
  (NaN as the one canonical quiet NaN, 7FF8000000000000); the space of
  negative quiet NaNs above it carries everything else, the top 16
  bits being the tag:

    FFF9  a 32-bit integer in the low half (a number, like a double)
    FFFA  undefined, null, false, true, the hole and the exception mark
    FFFB  an object        (a TJsCell pointer in the low 48 bits)
    FFFC  a string
    FFFD  a symbol
    FFFE  a BigInt

  So numbers, booleans, null and undefined never need the heap, and a
  pointer is one mask away. Integral doubles in the int32 range are
  kept as integers (JsNumber normalises) so that indexing and loops take
  the integer paths; -0 stays a double.

  The hole marks an absent array element and a let/const binding not
  yet initialised; the exception mark is what a routine returns when it
  has thrown (the value thrown waits in the runtime).

  TJsCell is the base of everything on the garbage collected heap, and
  TJsTracer the marking half of the collector, which cells' Trace
  methods report their references to.
}
unit Js.Values;

{$mode objfpc}{$H+}
{$R-}{$Q-}

interface

type
  TJsValue = QWord;
  PJsValue = ^TJsValue;
  TJsValueArray = array[0..(MaxInt div SizeOf(TJsValue)) - 1] of TJsValue;
  PJsValueArray = ^TJsValueArray;
  TJsValueList = array of TJsValue;

const
  JsTagInteger = QWord($FFF9);
  JsTagSpecial = QWord($FFFA);
  JsTagObject = QWord($FFFB);
  JsTagString = QWord($FFFC);
  JsTagSymbol = QWord($FFFD);
  JsTagBigInt = QWord($FFFE);

  JsTagShift = 48;
  JsPayloadMask = QWord($0000FFFFFFFFFFFF);

  JsIntegerBase = QWord($FFF9000000000000);
  JsSpecialBase = QWord($FFFA000000000000);
  JsObjectBase = QWord($FFFB000000000000);
  JsStringBase = QWord($FFFC000000000000);
  JsSymbolBase = QWord($FFFD000000000000);
  JsBigIntBase = QWord($FFFE000000000000);

  JsUndefined = QWord($FFFA000000000000);
  JsNull = QWord($FFFA000000000001);
  JsFalse = QWord($FFFA000000000002);
  JsTrue = QWord($FFFA000000000003);
  JsHole = QWord($FFFA000000000004);
  JsException = QWord($FFFA000000000005);

  JsNaN = QWord($7FF8000000000000);
  JsPositiveInfinityBits = QWord($7FF0000000000000);
  JsNegativeInfinityBits = QWord($FFF0000000000000);
  JsNegativeZeroBits = QWord($8000000000000000);

type
  TJsCellKind = (
    ckString, ckSymbol, ckBigInt, ckShape, ckObject, ckCode, ckEnvironment,
    ckAccessor, ckOther);

  TJsTracer = class;

  { Everything the collector manages. Cells are kept in one list by the
    heap; Marked is the mark bit of the current collection. }
  TJsCell = class
  public
    NextCell: TJsCell;
    Marked: Boolean;
    Kind: TJsCellKind;
    { Reports every cell this one refers to. }
    procedure Trace(Tracer: TJsTracer); virtual;
    { Called for each cell about to be freed, while the marks of the
      collection are still valid (weak links are cut here). }
    procedure Dying; virtual;
    { Bytes this cell holds, its instance and its buffers. }
    function MemorySize: SizeInt; virtual;
    { Cells with weak links of their own to cut in Dying: swept during
      the collection's pause, not later. }
    class function NeedsDying: Boolean; virtual;
  end;

  TJsCellList = array of TJsCell;

  { The mark stack of the collector. }
  TJsTracer = class
  protected
    FMarkStack: TJsCellList;
    FMarkCount: Integer;
    procedure PushCell(Cell: TJsCell);
  public
    procedure MarkCell(Cell: TJsCell); inline;
    procedure MarkValue(Value: TJsValue); inline;
    procedure MarkValues(Values: PJsValue; Count: Integer);
    { Traces cells off the mark stack until it is empty. }
    procedure Drain;
  end;

function JsInteger(Value: LongInt): TJsValue; inline;
function JsDouble(Value: Double): TJsValue; inline;
{ A number: an integer when Value is one in the int32 range, not -0. }
function JsNumber(Value: Double): TJsValue; inline;
function JsBoolean(Value: Boolean): TJsValue; inline;
function JsCellValue(Base: QWord; Cell: TJsCell): TJsValue; inline;

function JsIsInteger(Value: TJsValue): Boolean; inline;
function JsIsDouble(Value: TJsValue): Boolean; inline;
function JsIsNumber(Value: TJsValue): Boolean; inline;
function JsIsUndefined(Value: TJsValue): Boolean; inline;
function JsIsNull(Value: TJsValue): Boolean; inline;
function JsIsNullish(Value: TJsValue): Boolean; inline;
function JsIsBoolean(Value: TJsValue): Boolean; inline;
function JsIsObject(Value: TJsValue): Boolean; inline;
function JsIsString(Value: TJsValue): Boolean; inline;
function JsIsSymbol(Value: TJsValue): Boolean; inline;
function JsIsBigInt(Value: TJsValue): Boolean; inline;
function JsIsCell(Value: TJsValue): Boolean; inline;
function JsIsException(Value: TJsValue): Boolean; inline;

function JsAsInteger(Value: TJsValue): LongInt; inline;
function JsAsDouble(Value: TJsValue): Double; inline;
{ The number of an integer or double value. }
function JsNumberValue(Value: TJsValue): Double; inline;
function JsAsCell(Value: TJsValue): TJsCell; inline;
function JsTag(Value: TJsValue): QWord; inline;

{ A double that is an int32, and not -0. }
function DoubleIsInt32(Value: Double; out Integer: LongInt): Boolean; inline;
function DoubleBits(Value: Double): QWord; inline;
function BitsDouble(Bits: QWord): Double; inline;
function IsNaNDouble(Value: Double): Boolean; inline;
function IsFiniteDouble(Value: Double): Boolean; inline;
{ Floor and ceiling as doubles (the runtime's Floor and Ceil give a
  32-bit integer). }
function FloorDouble(Value: Double): Double; inline;
function CeilDouble(Value: Double): Double; inline;

implementation

function FloorDouble(Value: Double): Double;
begin
  Result := Int(Value);
  if Result > Value then
    Result := Result - 1;
end;

function CeilDouble(Value: Double): Double;
begin
  Result := Int(Value);
  if Result < Value then
    Result := Result + 1;
end;

function DoubleBits(Value: Double): QWord;
begin
  Result := PQWord(@Value)^;
end;

function BitsDouble(Bits: QWord): Double;
begin
  Result := PDouble(@Bits)^;
end;

function IsNaNDouble(Value: Double): Boolean;
begin
  Result := (DoubleBits(Value) and QWord($7FFFFFFFFFFFFFFF)) > QWord($7FF0000000000000);
end;

function IsFiniteDouble(Value: Double): Boolean;
begin
  Result := (DoubleBits(Value) and QWord($7FF0000000000000)) <> QWord($7FF0000000000000);
end;

function DoubleIsInt32(Value: Double; out Integer: LongInt): Boolean;
begin
  Result := False;
  Integer := 0;
  if (Value >= -2147483648.0) and (Value <= 2147483647.0) then
  begin
    Integer := Trunc(Value);
    Result := (Integer = Value) and ((Integer <> 0) or (DoubleBits(Value) = 0));
  end;
end;

function JsInteger(Value: LongInt): TJsValue;
begin
  Result := JsIntegerBase or QWord(LongWord(Value));
end;

function JsDouble(Value: Double): TJsValue;
begin
  Result := DoubleBits(Value);
  if (Result and QWord($7FFFFFFFFFFFFFFF)) > QWord($7FF0000000000000) then
    Result := JsNaN;
end;

function JsNumber(Value: Double): TJsValue;
var
  Integer: LongInt;
begin
  if DoubleIsInt32(Value, Integer) then
    Result := JsIntegerBase or QWord(LongWord(Integer))
  else
    Result := JsDouble(Value);
end;

function JsBoolean(Value: Boolean): TJsValue;
begin
  if Value then
    Result := JsTrue
  else
    Result := JsFalse;
end;

function JsCellValue(Base: QWord; Cell: TJsCell): TJsValue;
begin
  Result := Base or QWord(PtrUInt(Cell));
end;

function JsIsInteger(Value: TJsValue): Boolean;
begin
  Result := (Value shr JsTagShift) = JsTagInteger;
end;

function JsIsDouble(Value: TJsValue): Boolean;
begin
  Result := Value < JsIntegerBase;
end;

function JsIsNumber(Value: TJsValue): Boolean;
begin
  Result := Value < JsSpecialBase;
end;

function JsIsUndefined(Value: TJsValue): Boolean;
begin
  Result := Value = JsUndefined;
end;

function JsIsNull(Value: TJsValue): Boolean;
begin
  Result := Value = JsNull;
end;

function JsIsNullish(Value: TJsValue): Boolean;
begin
  Result := (Value = JsUndefined) or (Value = JsNull);
end;

function JsIsBoolean(Value: TJsValue): Boolean;
begin
  Result := (Value = JsTrue) or (Value = JsFalse);
end;

function JsIsObject(Value: TJsValue): Boolean;
begin
  Result := (Value shr JsTagShift) = JsTagObject;
end;

function JsIsString(Value: TJsValue): Boolean;
begin
  Result := (Value shr JsTagShift) = JsTagString;
end;

function JsIsSymbol(Value: TJsValue): Boolean;
begin
  Result := (Value shr JsTagShift) = JsTagSymbol;
end;

function JsIsBigInt(Value: TJsValue): Boolean;
begin
  Result := (Value shr JsTagShift) = JsTagBigInt;
end;

function JsIsCell(Value: TJsValue): Boolean;
begin
  Result := Value >= JsObjectBase;
end;

function JsIsException(Value: TJsValue): Boolean;
begin
  Result := Value = JsException;
end;

function JsAsInteger(Value: TJsValue): LongInt;
begin
  Result := LongInt(LongWord(Value and $FFFFFFFF));
end;

function JsAsDouble(Value: TJsValue): Double;
begin
  Result := PDouble(@Value)^;
end;

function JsNumberValue(Value: TJsValue): Double;
begin
  if Value < JsIntegerBase then
    Result := PDouble(@Value)^
  else
    Result := LongInt(LongWord(Value and $FFFFFFFF));
end;

function JsAsCell(Value: TJsValue): TJsCell;
begin
  Result := TJsCell(Pointer(PtrUInt(Value and JsPayloadMask)));
end;

function JsTag(Value: TJsValue): QWord;
begin
  Result := Value shr JsTagShift;
end;

{ TJsCell }

procedure TJsCell.Trace(Tracer: TJsTracer);
begin
end;

procedure TJsCell.Dying;
begin
end;

class function TJsCell.NeedsDying: Boolean;
begin
  Result := False;
end;

function TJsCell.MemorySize: SizeInt;
begin
  Result := InstanceSize;
end;

{ TJsTracer }

procedure TJsTracer.PushCell(Cell: TJsCell);
begin
  Cell.Marked := True;
  if FMarkCount >= Length(FMarkStack) then
    SetLength(FMarkStack, Length(FMarkStack) * 2 + 256);
  FMarkStack[FMarkCount] := Cell;
  Inc(FMarkCount);
end;

procedure TJsTracer.MarkCell(Cell: TJsCell);
begin
  if (Cell <> nil) and not Cell.Marked then
    PushCell(Cell);
end;

procedure TJsTracer.MarkValue(Value: TJsValue);
var
  Cell: TJsCell;
begin
  if Value >= JsObjectBase then
  begin
    Cell := TJsCell(Pointer(PtrUInt(Value and JsPayloadMask)));
    if not Cell.Marked then
      PushCell(Cell);
  end;
end;

procedure TJsTracer.MarkValues(Values: PJsValue; Count: Integer);
var
  Index: Integer;
begin
  for Index := 0 to Count - 1 do
    MarkValue(Values[Index]);
end;

procedure TJsTracer.Drain;
var
  Cell: TJsCell;
begin
  while FMarkCount > 0 do
  begin
    Dec(FMarkCount);
    Cell := FMarkStack[FMarkCount];
    Cell.Trace(Self);
  end;
end;

end.
