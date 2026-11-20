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
  Binary data: ArrayBuffer and SharedArrayBuffer objects, the typed
  arrays viewing them, and DataView.

  A buffer owns a block of bytes (zeroed when made), or wraps memory a
  host handed over: then a free procedure the host chose is called
  when the buffer dies or is detached (none: the host keeps the memory
  alive itself). A resizable buffer reallocates its block on resize,
  so the data pointer is valid only until the next call into
  JavaScript. A detached buffer has no data and length 0. The block
  counts towards the heap's bytes, so large buffers make collections
  come sooner.

  A typed array is an integer-indexed exotic object: the canonical
  numeric keys ("0", "-0", "1.5", "Infinity"...) are its elements or
  nothing, never ordinary properties; other keys are ordinary. Its
  window on the buffer is a byte offset and either a fixed length or,
  on a resizable buffer, all the bytes after the offset (length
  tracking). A window past the buffer's end (after a shrink) or on a
  detached buffer is out of bounds: length 0, reads undefined, writes
  ignored.

  TypedArrayGet and TypedArraySet are the element paths the
  interpreter's indexed access and the built-ins share. Writing
  converts first (ToNumber or ToBigInt can run JavaScript, which may
  detach or shrink the buffer) and checks the index after.
}
unit Js.ArrayBuffers;

{$mode objfpc}{$H+}
{$R-}{$Q-}

interface

uses
  Js.Values,
  Js.Heap,
  Js.Strings,
  Js.Shapes,
  Js.Runtime,
  Js.Objects;

type
  TJsTypedArrayKind = (taInt8, taUint8, taUint8Clamped, taInt16, taUint16, taInt32, taUint32, taFloat16,
    taFloat32, taFloat64, taBigInt64, taBigUint64);

  { Frees memory a host handed to NewExternalArrayBuffer. }
  TJsBufferFreeProc = procedure(Data: Pointer; ByteLength: SizeInt; Context: Pointer);

  TJsArrayBuffer = class(TJsObject)
  public
    Data: PByte;
    ByteLength: SizeInt;
    { Resizable (growable) buffers: the most bytes they may hold. }
    MaxByteLength: SizeInt;
    Resizable: Boolean;
    Shared: Boolean;
    Detached: Boolean;
    { The memory is the host's: FreeProc (if any) releases it. }
    External: Boolean;
    FreeProc: TJsBufferFreeProc;
    FreeContext: Pointer;
    destructor Destroy; override;
    function MemorySize: SizeInt; override;
    { Lets go of the data without freeing it (transfer, the host taking
      it): the buffer is detached. }
    procedure ReleaseData;
    { Frees the data and detaches. }
    procedure Detach;
  end;

  TJsTypedArray = class(TJsObject)
  public
    Buffer: TJsArrayBuffer;
    ElementKind: TJsTypedArrayKind;
    ByteOffset: SizeInt;
    { Elements, when not length tracking. }
    FixedLength: SizeInt;
    { ByteOffset + FixedLength * element size. }
    FixedByteEnd: SizeInt;
    LengthTracking: Boolean;
    procedure Trace(Tracer: TJsTracer); override;
    { The element count now (0 when out of bounds). }
    function CurrentLength: SizeInt; inline;
    function IsOutOfBounds: Boolean;
    function ElementSize: Integer; inline;
    function ElementAddress(Index: SizeInt): PByte; inline;
    function GetOwnProperty(R: TJsRealm; Key: TJsValue; out Desc: TJsPropertyDescriptor): Integer; override;
    function DefineOwnProperty(R: TJsRealm; Key: TJsValue; const Desc: TJsPropertyDescriptor;
      ThrowOnFailure: Boolean): Integer; override;
    function HasProperty(R: TJsRealm; Key: TJsValue): Integer; override;
    function Get(R: TJsRealm; Key, Receiver: TJsValue): TJsValue; override;
    function SetValue(R: TJsRealm; Key, Value, Receiver: TJsValue): Integer; override;
    function DeleteProperty(R: TJsRealm; Key: TJsValue): Integer; override;
    function OwnPropertyKeys(R: TJsRealm; Filter: Integer; out Keys: TJsValueList): Boolean; override;
  end;

  TJsDataView = class(TJsObject)
  public
    Buffer: TJsArrayBuffer;
    ByteOffset: SizeInt;
    FixedByteLength: SizeInt;
    LengthTracking: Boolean;
    procedure Trace(Tracer: TJsTracer); override;
    { The view's byte length now; -1 when out of bounds. }
    function CurrentByteLength: SizeInt;
  end;

const
  TypedArrayElementSizes: array[TJsTypedArrayKind] of Byte = (1, 1, 1, 2, 2, 4, 4, 2, 4, 8, 8, 8);
  TypedArrayNames: array[TJsTypedArrayKind] of string = ('Int8Array', 'Uint8Array', 'Uint8ClampedArray',
    'Int16Array', 'Uint16Array', 'Int32Array', 'Uint32Array', 'Float16Array', 'Float32Array', 'Float64Array',
    'BigInt64Array', 'BigUint64Array');
  { The largest buffer made (bytes). }
  MaximumArrayBufferLength = SizeInt(2147483647);

  TypedArrayPrototypes: array[TJsTypedArrayKind] of TJsIntrinsic = (inInt8ArrayPrototype,
    inUint8ArrayPrototype, inUint8ClampedArrayPrototype, inInt16ArrayPrototype, inUint16ArrayPrototype,
    inInt32ArrayPrototype, inUint32ArrayPrototype, inFloat16ArrayPrototype, inFloat32ArrayPrototype,
    inFloat64ArrayPrototype, inBigInt64ArrayPrototype, inBigUint64ArrayPrototype);
  TypedArrayConstructors: array[TJsTypedArrayKind] of TJsIntrinsic = (inInt8Array, inUint8Array,
    inUint8ClampedArray, inInt16Array, inUint16Array, inInt32Array, inUint32Array, inFloat16Array,
    inFloat32Array, inFloat64Array, inBigInt64Array, inBigUint64Array);

function IsBigIntKind(Kind: TJsTypedArrayKind): Boolean; inline;

{ Half precision. }
function HalfToDouble(Half: Word): Double;
function DoubleToHalf(Value: Double): Word;
{ The conversions of typed array stores. }
function DoubleToUint8Clamped(Value: Double): Byte;

{ A number or BigInt read from raw bytes in the platform's order. }
function ReadElement(R: TJsRealm; Kind: TJsTypedArrayKind; Address: PByte): TJsValue;
{ Writes a number (a BigInt for the BigInt kinds) already converted. }
procedure WriteElement(R: TJsRealm; Kind: TJsTypedArrayKind; Address: PByte; Value: TJsValue);
{ ToNumber, or ToBigInt for the BigInt kinds. }
function ConvertForKind(R: TJsRealm; Kind: TJsTypedArrayKind; Value: TJsValue): TJsValue;

{ The element, or undefined when Index is not valid. }
function TypedArrayGet(R: TJsRealm; Target: TJsTypedArray; Index: SizeInt): TJsValue; inline;
{ Converts Value and stores it when Index is (still) valid; False
  when the conversion threw. }
function TypedArraySet(R: TJsRealm; Target: TJsTypedArray; Index: SizeInt; Value: TJsValue): Boolean;
{ ToIndex: an integer in 0 .. 2^53-1, else a RangeError. }
function ToIndex(R: TJsRealm; Value: TJsValue; out Index: Int64): Boolean;
{ A key that is a canonical numeric string (but not an integer key). }
function IsCanonicalNumericKey(R: TJsRealm; Key: TJsValue): Boolean;

{ A new buffer of ByteLength zero bytes; nil (a RangeError thrown) when
  too big. MaxByteLength < 0: not resizable. }
function NewArrayBuffer(R: TJsRealm; Prototype: TJsObject; ByteLength: SizeInt; MaxByteLength: SizeInt = -1;
  Shared: Boolean = False): TJsArrayBuffer;
{ A buffer on memory the host owns (no copy). }
function NewExternalArrayBuffer(R: TJsRealm; Data: Pointer; ByteLength: SizeInt; FreeProc: TJsBufferFreeProc;
  Context: Pointer): TJsArrayBuffer;
{ Changes a resizable buffer's length (new bytes are zero); False when
  memory ran out (nothing thrown). }
function ResizeArrayBuffer(R: TJsRealm; Buffer: TJsArrayBuffer; NewByteLength: SizeInt): Boolean;
{ A typed array on Buffer. Length < 0: length tracking. }
function NewTypedArrayObject(R: TJsRealm; Prototype: TJsObject; Kind: TJsTypedArrayKind; Buffer: TJsArrayBuffer;
  ByteOffset, Length: SizeInt): TJsTypedArray;
{ Detaches a buffer and hands its bytes to the caller, who frees them
  with FreeMem (memory a host lent is copied first and given back).
  False when the buffer is already detached or the copy failed. }
function TakeArrayBufferData(R: TJsRealm; Buffer: TJsArrayBuffer; out Data: Pointer; out ByteLength: SizeInt): Boolean;
{ The bytes an ArrayBuffer, SharedArrayBuffer, typed array or DataView
  shows (a view: its window). False for anything else, or a detached
  or out of bounds one. }
function BufferSourceBytes(Value: TJsValue; out Data: PByte; out ByteLength: SizeInt): Boolean;

implementation

uses
  SysUtils,
  Math,
  Js.BigIntegers,
  Js.Conversions,
  Js.Builtins.BigInt;

function IsBigIntKind(Kind: TJsTypedArrayKind): Boolean;
begin
  Result := Kind >= taBigInt64;
end;

{ Half precision }

function HalfToDouble(Half: Word): Double;
var
  Exponent, Fraction: Integer;
begin
  Exponent := (Half shr 10) and $1F;
  Fraction := Half and $3FF;
  if Exponent = 0 then
    Result := Fraction * (Double(1) / 16777216)
  else if Exponent = 31 then
  begin
    if Fraction = 0 then
      Result := BitsDouble(JsPositiveInfinityBits)
    else
      Result := BitsDouble(JsNaN);
  end
  else
    Result := ldexp(1024 + Fraction, Exponent - 25);
  if (Half and $8000) <> 0 then
    Result := -Result;
end;

function DoubleToHalf(Value: Double): Word;
var
  Bits, Mantissa, Remainder, Halfway: QWord;
  Sign: Word;
  Exponent, Shift: Integer;
  HalfMantissa: QWord;
begin
  Bits := DoubleBits(Value);
  Sign := Word((Bits shr 48) and $8000);
  if IsNaNDouble(Value) then
    Exit($7E00);
  Exponent := Integer((Bits shr 52) and $7FF);
  if Exponent = $7FF then
    Exit(Sign or $7C00);
  Mantissa := Bits and QWord($000FFFFFFFFFFFFF);
  if Exponent = 0 then
    Exit(Sign);
  Exponent := Exponent - 1023;
  if Exponent < -25 then
    Exit(Sign);
  if Exponent >= -14 then
  begin
    HalfMantissa := Mantissa shr 42;
    Remainder := Mantissa and ((QWord(1) shl 42) - 1);
    Halfway := QWord(1) shl 41;
    if (Remainder > Halfway) or ((Remainder = Halfway) and ((HalfMantissa and 1) <> 0)) then
      Inc(HalfMantissa);
    if HalfMantissa = 1024 then
    begin
      HalfMantissa := 0;
      Inc(Exponent);
    end;
    if Exponent + 15 >= 31 then
      Exit(Sign or $7C00);
    Exit(Sign or Word((Exponent + 15) shl 10) or Word(HalfMantissa));
  end;
  { A subnormal half (or the smallest normal after rounding up). }
  Mantissa := Mantissa or (QWord(1) shl 52);
  Shift := 42 + (-14 - Exponent);
  HalfMantissa := Mantissa shr Shift;
  Remainder := Mantissa and ((QWord(1) shl Shift) - 1);
  Halfway := QWord(1) shl (Shift - 1);
  if (Remainder > Halfway) or ((Remainder = Halfway) and ((HalfMantissa and 1) <> 0)) then
    Inc(HalfMantissa);
  Result := Sign or Word(HalfMantissa);
end;

function DoubleToUint8Clamped(Value: Double): Byte;
var
  Floor: Double;
begin
  if IsNaNDouble(Value) or (Value <= 0) then
    Exit(0);
  if Value >= 255 then
    Exit(255);
  Floor := Int(Value);
  if Floor + 0.5 < Value then
    Exit(Byte(Trunc(Floor) + 1));
  if Value < Floor + 0.5 then
    Exit(Byte(Trunc(Floor)));
  if (Trunc(Floor) and 1) = 0 then
    Result := Byte(Trunc(Floor))
  else
    Result := Byte(Trunc(Floor) + 1);
end;

{ Elements }

function BigIntFromUnsigned(R: TJsRealm; Value: QWord): TJsValue;
var
  Digits: TJsDigits;
begin
  Digits := nil;
  SetLength(Digits, 2);
  Digits[0] := LongWord(Value);
  Digits[1] := LongWord(Value shr 32);
  Result := JsCellValue(JsBigIntBase, NewBigInt(R.Heap, False, Digits));
end;

function ReadElement(R: TJsRealm; Kind: TJsTypedArrayKind; Address: PByte): TJsValue;
begin
  case Kind of
    taInt8: Result := JsInteger(ShortInt(Address^));
    taUint8, taUint8Clamped: Result := JsInteger(Address^);
    taInt16: Result := JsInteger(PSmallInt(Address)^);
    taUint16: Result := JsInteger(PWord(Address)^);
    taInt32: Result := JsInteger(PLongInt(Address)^);
    taUint32: Result := JsNumber(PLongWord(Address)^);
    taFloat16: Result := JsNumber(HalfToDouble(PWord(Address)^));
    taFloat32: Result := JsNumber(PSingle(Address)^);
    taFloat64: Result := JsNumber(PDouble(Address)^);
    taBigInt64: Result := JsCellValue(JsBigIntBase, BigIntFromInt64(R.Heap, PInt64(Address)^));
  else
    Result := BigIntFromUnsigned(R, PQWord(Address)^);
  end;
end;

procedure WriteElement(R: TJsRealm; Kind: TJsTypedArrayKind; Address: PByte; Value: TJsValue);
var
  Number: Double;
  Integer32: LongInt;
begin
  if Kind >= taBigInt64 then
  begin
    PInt64(Address)^ := BigIntToInt64(TJsBigInt(JsAsCell(Value)));
    Exit;
  end;
  if JsIsInteger(Value) then
  begin
    Integer32 := JsAsInteger(Value);
    case Kind of
      taInt8, taUint8: Address^ := Byte(Integer32);
      taUint8Clamped:
        if Integer32 < 0 then
          Address^ := 0
        else if Integer32 > 255 then
          Address^ := 255
        else
          Address^ := Byte(Integer32);
      taInt16, taUint16: PWord(Address)^ := Word(Integer32);
      taInt32, taUint32: PLongInt(Address)^ := Integer32;
      taFloat16: PWord(Address)^ := DoubleToHalf(Integer32);
      taFloat32: PSingle(Address)^ := Integer32;
      taFloat64: PDouble(Address)^ := Integer32;
    end;
    Exit;
  end;
  Number := JsNumberValue(Value);
  case Kind of
    taInt8, taUint8: Address^ := Byte(DoubleToInt32(Number));
    taUint8Clamped: Address^ := DoubleToUint8Clamped(Number);
    taInt16, taUint16: PWord(Address)^ := Word(DoubleToInt32(Number));
    taInt32, taUint32: PLongInt(Address)^ := DoubleToInt32(Number);
    taFloat16: PWord(Address)^ := DoubleToHalf(Number);
    taFloat32: PSingle(Address)^ := Number;
    taFloat64: PDouble(Address)^ := Number;
  end;
end;

function ConvertForKind(R: TJsRealm; Kind: TJsTypedArrayKind; Value: TJsValue): TJsValue;
begin
  if Kind >= taBigInt64 then
  begin
    if JsIsBigInt(Value) then
      Exit(Value);
    Exit(ToBigIntValue(R, Value));
  end;
  if JsIsNumber(Value) then
    Exit(Value);
  Result := ToNumber(R, Value);
end;

function ToIndex(R: TJsRealm; Value: TJsValue; out Index: Int64): Boolean;
var
  Number: Double;
begin
  Index := 0;
  if JsIsInteger(Value) and (JsAsInteger(Value) >= 0) then
  begin
    Index := JsAsInteger(Value);
    Exit(True);
  end;
  if not ToIntegerOrInfinity(R, Value, Number) then
    Exit(False);
  if (Number < 0) or (Number > 9007199254740991.0) then
  begin
    R.ThrowRangeError('Invalid index: ' + NumberToString(Number));
    Exit(False);
  end;
  Index := Trunc(Number);
  Result := True;
end;

function IsCanonicalNumericKey(R: TJsRealm; Key: TJsValue): Boolean;
var
  Text: TJsString;
  First: Word;
  Number: Double;
begin
  Result := False;
  if not JsIsString(Key) then
    Exit;
  Text := JsAsString(Key);
  if Text.Length = 0 then
    Exit;
  First := Text.CharAt(0);
  if not (((First >= Ord('0')) and (First <= Ord('9'))) or (First = Ord('-')) or (First = Ord('I')) or
    (First = Ord('N'))) then
    Exit;
  if StringEqualsAscii(Text, '-0') then
    Exit(True);
  Number := StringToNumber(R, Text);
  Result := StringEqualsAscii(Text, NumberToString(Number));
end;

{ TJsArrayBuffer }

destructor TJsArrayBuffer.Destroy;
begin
  Detach;
  inherited Destroy;
end;

function TJsArrayBuffer.MemorySize: SizeInt;
begin
  Result := inherited MemorySize;
  if not External then
    Inc(Result, ByteLength);
end;

procedure TJsArrayBuffer.ReleaseData;
begin
  Data := nil;
  ByteLength := 0;
  Detached := True;
  External := False;
  FreeProc := nil;
end;

procedure TJsArrayBuffer.Detach;
begin
  if Data <> nil then
  begin
    if External then
    begin
      if Assigned(FreeProc) then
        FreeProc(Data, ByteLength, FreeContext);
    end
    else
      FreeMem(Data);
  end;
  ReleaseData;
end;

{ TJsTypedArray }

procedure TJsTypedArray.Trace(Tracer: TJsTracer);
begin
  inherited Trace(Tracer);
  Tracer.MarkCell(Buffer);
end;

function TJsTypedArray.ElementSize: Integer;
begin
  Result := TypedArrayElementSizes[ElementKind];
end;

function TJsTypedArray.CurrentLength: SizeInt;
begin
  if not LengthTracking then
  begin
    if FixedByteEnd <= Buffer.ByteLength then
      Exit(FixedLength);
    Exit(0);
  end;
  if ByteOffset > Buffer.ByteLength then
    Exit(0);
  Result := (Buffer.ByteLength - ByteOffset) div TypedArrayElementSizes[ElementKind];
end;

function TJsTypedArray.IsOutOfBounds: Boolean;
begin
  if Buffer.Detached then
    Exit(True);
  if LengthTracking then
    Result := ByteOffset > Buffer.ByteLength
  else
    Result := FixedByteEnd > Buffer.ByteLength;
end;

function TJsTypedArray.ElementAddress(Index: SizeInt): PByte;
begin
  Result := Buffer.Data + ByteOffset + Index * TypedArrayElementSizes[ElementKind];
end;

function TypedArrayGet(R: TJsRealm; Target: TJsTypedArray; Index: SizeInt): TJsValue;
begin
  if (Index < 0) or (Index >= Target.CurrentLength) then
    Exit(JsUndefined);
  Result := ReadElement(R, Target.ElementKind, Target.ElementAddress(Index));
end;

function TypedArraySet(R: TJsRealm; Target: TJsTypedArray; Index: SizeInt; Value: TJsValue): Boolean;
begin
  Value := ConvertForKind(R, Target.ElementKind, Value);
  if Value = JsException then
    Exit(False);
  if (Index >= 0) and (Index < Target.CurrentLength) then
    WriteElement(R, Target.ElementKind, Target.ElementAddress(Index), Value);
  Result := True;
end;

{ A numeric key: Index is the element (-1 when not an integer index). }
function NumericKey(R: TJsRealm; Key: TJsValue; out Index: SizeInt): Boolean; inline;
begin
  if JsIsInteger(Key) then
  begin
    Index := JsAsInteger(Key);
    Exit(True);
  end;
  Index := -1;
  Result := JsIsString(Key) and IsCanonicalNumericKey(R, Key);
end;

function TJsTypedArray.GetOwnProperty(R: TJsRealm; Key: TJsValue; out Desc: TJsPropertyDescriptor): Integer;
var
  Index: SizeInt;
begin
  if NumericKey(R, Key, Index) then
  begin
    if (Index < 0) or (Index >= CurrentLength) then
      Exit(0);
    Desc := DataDescriptor(ReadElement(R, ElementKind, ElementAddress(Index)), PropertyDefault);
    Exit(1);
  end;
  Result := inherited GetOwnProperty(R, Key, Desc);
end;

function TJsTypedArray.DefineOwnProperty(R: TJsRealm; Key: TJsValue; const Desc: TJsPropertyDescriptor;
  ThrowOnFailure: Boolean): Integer;
var
  Index: SizeInt;

  function Refuse: Integer;
  begin
    if ThrowOnFailure then
    begin
      R.ThrowTypeError('Cannot redefine property: ' + KeyToPascal(R, Key));
      Exit(-1);
    end;
    Result := 0;
  end;

begin
  if NumericKey(R, Key, Index) then
  begin
    if (Index < 0) or (Index >= CurrentLength) then
      Exit(Refuse);
    if (((Desc.Present and HasConfigurable) <> 0) and ((Desc.Flags and PropertyConfigurable) = 0)) or
      (((Desc.Present and HasEnumerable) <> 0) and ((Desc.Flags and PropertyEnumerable) = 0)) or
      ((Desc.Present and (HasGetter or HasSetter)) <> 0) or
      (((Desc.Present and HasWritable) <> 0) and ((Desc.Flags and PropertyWritable) = 0)) then
      Exit(Refuse);
    if (Desc.Present and HasValue) <> 0 then
      if not TypedArraySet(R, Self, Index, Desc.Value) then
        Exit(-1);
    Exit(1);
  end;
  Result := inherited DefineOwnProperty(R, Key, Desc, ThrowOnFailure);
end;

function TJsTypedArray.HasProperty(R: TJsRealm; Key: TJsValue): Integer;
var
  Index: SizeInt;
  Found: Integer;
  Desc: TJsPropertyDescriptor;
begin
  if NumericKey(R, Key, Index) then
  begin
    if (Index >= 0) and (Index < CurrentLength) then
      Exit(1);
    Exit(0);
  end;
  Found := inherited GetOwnProperty(R, Key, Desc);
  if Found <> 0 then
    Exit(Found);
  if Proto = nil then
    Exit(0);
  Result := Proto.HasProperty(R, Key);
end;

function TJsTypedArray.Get(R: TJsRealm; Key, Receiver: TJsValue): TJsValue;
var
  Index: SizeInt;
  Found: Integer;
  Desc: TJsPropertyDescriptor;
begin
  if NumericKey(R, Key, Index) then
    Exit(TypedArrayGet(R, Self, Index));
  Found := inherited GetOwnProperty(R, Key, Desc);
  if Found < 0 then
    Exit(JsException);
  if Found > 0 then
  begin
    if not DescriptorIsAccessor(Desc) then
      Exit(Desc.Value);
    if Desc.Getter = JsUndefined then
      Exit(JsUndefined);
    Exit(R.Call(Desc.Getter, Receiver, nil, 0));
  end;
  if Proto = nil then
    Exit(JsUndefined);
  Result := Proto.Get(R, Key, Receiver);
end;

function TJsTypedArray.SetValue(R: TJsRealm; Key, Value, Receiver: TJsValue): Integer;
var
  Index: SizeInt;
begin
  if NumericKey(R, Key, Index) then
  begin
    if Receiver = JsObjectValue(Self) then
    begin
      if not TypedArraySet(R, Self, Index, Value) then
        Exit(-1);
      Exit(1);
    end;
    if (Index < 0) or (Index >= CurrentLength) then
      Exit(1);
  end;
  Result := SetSlow(R, Key, Value, Receiver);
end;

function TJsTypedArray.DeleteProperty(R: TJsRealm; Key: TJsValue): Integer;
var
  Index: SizeInt;
begin
  if NumericKey(R, Key, Index) then
  begin
    if (Index >= 0) and (Index < CurrentLength) then
      Exit(0);
    Exit(1);
  end;
  Result := inherited DeleteProperty(R, Key);
end;

function TJsTypedArray.OwnPropertyKeys(R: TJsRealm; Filter: Integer; out Keys: TJsValueList): Boolean;
var
  Named: TJsValueList;
  Count, Index: SizeInt;
begin
  Keys := nil;
  if not inherited OwnPropertyKeys(R, Filter, Named) then
    Exit(False);
  Count := 0;
  if (Filter and KeysStrings) <> 0 then
    Count := CurrentLength;
  SetLength(Keys, Count + System.Length(Named));
  for Index := 0 to Count - 1 do
    Keys[Index] := JsInteger(LongInt(Index));
  for Index := 0 to High(Named) do
    Keys[Count + Index] := Named[Index];
  Result := True;
end;

{ TJsDataView }

procedure TJsDataView.Trace(Tracer: TJsTracer);
begin
  inherited Trace(Tracer);
  Tracer.MarkCell(Buffer);
end;

function TJsDataView.CurrentByteLength: SizeInt;
begin
  if Buffer.Detached then
    Exit(-1);
  if LengthTracking then
  begin
    if ByteOffset > Buffer.ByteLength then
      Exit(-1);
    Exit(Buffer.ByteLength - ByteOffset);
  end;
  if ByteOffset + FixedByteLength > Buffer.ByteLength then
    Exit(-1);
  Result := FixedByteLength;
end;

{ Making them }

function AllocateZeroed(R: TJsRealm; ByteLength: SizeInt; out Data: PByte): Boolean;
begin
  Data := nil;
  if (ByteLength < 0) or (ByteLength > MaximumArrayBufferLength) then
    Exit(False);
  if (R.Heap.MemoryLimit > 0) and (R.Heap.BytesAllocated + ByteLength > R.Heap.MemoryLimit) then
    Exit(False);
  if ByteLength = 0 then
    Exit(True);
  try
    Data := AllocMem(ByteLength);
  except
    on EOutOfMemory do
      Exit(False);
  end;
  Result := Data <> nil;
end;

function NewArrayBuffer(R: TJsRealm; Prototype: TJsObject; ByteLength: SizeInt; MaxByteLength: SizeInt;
  Shared: Boolean): TJsArrayBuffer;
var
  Data: PByte;
begin
  if not AllocateZeroed(R, ByteLength, Data) then
  begin
    R.ThrowRangeError('Array buffer allocation failed');
    Exit(nil);
  end;
  Result := TJsArrayBuffer(R.NewObjectOfClass(TJsArrayBuffer, Prototype, ocArrayBuffer));
  Result.Data := Data;
  Result.ByteLength := ByteLength;
  Result.Shared := Shared;
  Result.Resizable := MaxByteLength >= 0;
  if Result.Resizable then
    Result.MaxByteLength := MaxByteLength
  else
    Result.MaxByteLength := ByteLength;
  R.Heap.Account(ByteLength);
end;

function NewExternalArrayBuffer(R: TJsRealm; Data: Pointer; ByteLength: SizeInt; FreeProc: TJsBufferFreeProc;
  Context: Pointer): TJsArrayBuffer;
begin
  Result := TJsArrayBuffer(R.NewObjectOfClass(TJsArrayBuffer, R.Intrinsics[inArrayBufferPrototype],
    ocArrayBuffer));
  Result.Data := Data;
  Result.ByteLength := ByteLength;
  Result.MaxByteLength := ByteLength;
  Result.External := True;
  Result.FreeProc := FreeProc;
  Result.FreeContext := Context;
end;

function ResizeArrayBuffer(R: TJsRealm; Buffer: TJsArrayBuffer; NewByteLength: SizeInt): Boolean;
var
  Data: PByte;
begin
  if NewByteLength = Buffer.ByteLength then
    Exit(True);
  if NewByteLength = 0 then
    Data := nil
  else
  begin
    if (NewByteLength > Buffer.ByteLength) and (R.Heap.MemoryLimit > 0) and
      (R.Heap.BytesAllocated + NewByteLength - Buffer.ByteLength > R.Heap.MemoryLimit) then
      Exit(False);
    try
      Data := AllocMem(NewByteLength);
    except
      on EOutOfMemory do
        Exit(False);
    end;
    if Data = nil then
      Exit(False);
    if Buffer.ByteLength < NewByteLength then
      Move(Buffer.Data^, Data^, Buffer.ByteLength)
    else
      Move(Buffer.Data^, Data^, NewByteLength);
  end;
  if Buffer.External then
  begin
    { The host's memory goes back to it; the copy is the engine's. }
    if Assigned(Buffer.FreeProc) and (Buffer.Data <> nil) then
      Buffer.FreeProc(Buffer.Data, Buffer.ByteLength, Buffer.FreeContext);
    Buffer.External := False;
    Buffer.FreeProc := nil;
    R.Heap.Account(NewByteLength);
  end
  else
  begin
    if Buffer.Data <> nil then
      FreeMem(Buffer.Data);
    R.Heap.Account(NewByteLength - Buffer.ByteLength);
  end;
  Buffer.Data := Data;
  Buffer.ByteLength := NewByteLength;
  Result := True;
end;

function NewTypedArrayObject(R: TJsRealm; Prototype: TJsObject; Kind: TJsTypedArrayKind; Buffer: TJsArrayBuffer;
  ByteOffset, Length: SizeInt): TJsTypedArray;
begin
  Result := TJsTypedArray(R.NewObjectOfClass(TJsTypedArray, Prototype, ocTypedArray));
  Result.ObjectFlags := Result.ObjectFlags or ObjectExotic;
  Result.Buffer := Buffer;
  Result.ElementKind := Kind;
  Result.ByteOffset := ByteOffset;
  Result.LengthTracking := Length < 0;
  if Length < 0 then
    Length := 0;
  Result.FixedLength := Length;
  Result.FixedByteEnd := ByteOffset + Length * TypedArrayElementSizes[Kind];
end;

function TakeArrayBufferData(R: TJsRealm; Buffer: TJsArrayBuffer; out Data: Pointer; out ByteLength: SizeInt): Boolean;
begin
  Data := nil;
  ByteLength := 0;
  if Buffer.Detached then
    Exit(False);
  ByteLength := Buffer.ByteLength;
  if Buffer.External or (Buffer.Data = nil) then
  begin
    try
      Data := GetMem(ByteLength + 1);
    except
      on EOutOfMemory do
        Exit(False);
    end;
    if ByteLength > 0 then
      Move(Buffer.Data^, Data^, ByteLength);
    Buffer.Detach;
    Exit(True);
  end;
  Data := Buffer.Data;
  R.Heap.Account(-ByteLength);
  Buffer.ReleaseData;
  Result := True;
end;

function BufferSourceBytes(Value: TJsValue; out Data: PByte; out ByteLength: SizeInt): Boolean;
var
  Target: TJsObject;
  View: TJsTypedArray;
  DataView: TJsDataView;
begin
  Data := nil;
  ByteLength := 0;
  Result := False;
  if not JsIsObject(Value) then
    Exit;
  Target := JsAsObject(Value);
  if Target is TJsArrayBuffer then
  begin
    if TJsArrayBuffer(Target).Detached then
      Exit;
    Data := TJsArrayBuffer(Target).Data;
    ByteLength := TJsArrayBuffer(Target).ByteLength;
    Exit(True);
  end;
  if Target is TJsTypedArray then
  begin
    View := TJsTypedArray(Target);
    if View.IsOutOfBounds then
      Exit;
    Data := View.Buffer.Data + View.ByteOffset;
    ByteLength := View.CurrentLength * View.ElementSize;
    Exit(True);
  end;
  if Target is TJsDataView then
  begin
    DataView := TJsDataView(Target);
    ByteLength := DataView.CurrentByteLength;
    if ByteLength < 0 then
    begin
      ByteLength := 0;
      Exit;
    end;
    Data := DataView.Buffer.Data + DataView.ByteOffset;
    Exit(True);
  end;
end;

end.
