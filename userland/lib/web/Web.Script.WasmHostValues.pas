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
  JavaScript values as libwasm's host references (the JS API's "host
  value cache"): the word an externref holds for a JavaScript value.

  libwasm reads a reference word as null (0), an i31 (odd), an object of
  its heap, or a pointer the embedder owns, which must be even. A
  JavaScript value is a NaN-boxed word (Js.Values): objects, strings,
  symbols, BigInts, undefined and false are even and are their own
  word; null is the null reference. Numbers are never their own word -
  an integer's word or a double's bits may be odd, zero (+0) or look
  like a heap address - and neither is true (odd): a number in the i31
  range is an i31 (the JS API converts it so, any.convert_extern then
  sees an i31), and every other number and true goes into a box, a cell
  of the JavaScript heap holding the value, whose word is the box's
  address under the integer tag (no JavaScript value uses that tag in a
  host word, since numbers are always boxed or i31s).

  A box lives while something marks it: the agent's tracing gives every
  host word it finds in the store to MarkHostWord. Boxes are not shared:
  two conversions of 2.5 make two boxes (host references have no
  identity in WebAssembly).
}
unit Web.Script.WasmHostValues;

{$mode objfpc}
{$H+}

interface

uses
  Js.Values,
  Js.Objects;

type
  { A number (or true) given to WebAssembly as a host reference. }
  TWasmHostBox = class(TJsCell)
  public
    Value: TJsValue;
    procedure Trace(Tracer: TJsTracer); override;
  end;

{ Whether Value is a Number that the JS API turns into an i31 (an
  integer in -2^30 .. 2^30-1, -0 excepted). }
function IsI31Number(Value: TJsValue; out Integer31: LongInt): Boolean;
{ The host word of a JavaScript value that is neither null nor an i31
  number nor a WebAssembly object (a box for other numbers and true). }
function HostWordOf(R: TJsRealm; Value: TJsValue): Pointer;
{ The JavaScript value of a host word (made by HostWordOf). }
function HostValueOf(Word: Pointer): TJsValue;
{ Marks what a host word keeps (the box, or the value's cell). }
procedure MarkHostWord(Tracer: TJsTracer; Word: Pointer);

implementation

const
  BoxTag = QWord($FFF9);

procedure TWasmHostBox.Trace(Tracer: TJsTracer);
begin
  Tracer.MarkValue(Value);
end;

function IsI31Number(Value: TJsValue; out Integer31: LongInt): Boolean;
var
  Number: Double;
begin
  Result := False;
  Integer31 := 0;
  if JsIsInteger(Value) then
    Integer31 := JsAsInteger(Value)
  else if JsIsDouble(Value) then
  begin
    { An integral double; not -0, which stays a host value so that it
      comes back as -0 (as engines have it). }
    Number := JsAsDouble(Value);
    if not ((Number >= -1073741824.0) and (Number < 1073741824.0) and (Frac(Number) = 0)) or
      (Value = JsNegativeZeroBits) then
      Exit;
    Integer31 := Trunc(Number);
  end
  else
    Exit;
  Result := (Integer31 >= -(1 shl 30)) and (Integer31 < (1 shl 30));
end;

function NeedsBox(Value: TJsValue): Boolean; inline;
begin
  Result := JsIsNumber(Value) or (Value and 1 <> 0);
end;

function HostWordOf(R: TJsRealm; Value: TJsValue): Pointer;
var
  Box: TWasmHostBox;
begin
  if not NeedsBox(Value) then
    Exit(Pointer(PtrUInt(Value)));
  Box := TWasmHostBox.Create;
  Box.Value := Value;
  R.Heap.Register(Box, ckOther);
  Result := Pointer(PtrUInt((BoxTag shl JsTagShift) or QWord(PtrUInt(Box))));
end;

function IsBoxWord(Word: Pointer): Boolean; inline;
begin
  Result := (QWord(PtrUInt(Word)) shr JsTagShift) = BoxTag;
end;

function BoxOf(Word: Pointer): TWasmHostBox; inline;
begin
  Result := TWasmHostBox(Pointer(PtrUInt(QWord(PtrUInt(Word)) and JsPayloadMask)));
end;

function HostValueOf(Word: Pointer): TJsValue;
begin
  if IsBoxWord(Word) then
    Result := BoxOf(Word).Value
  else
    Result := TJsValue(PtrUInt(Word));
end;

procedure MarkHostWord(Tracer: TJsTracer; Word: Pointer);
begin
  if IsBoxWord(Word) then
    Tracer.MarkCell(BoxOf(Word))
  else
    Tracer.MarkValue(TJsValue(PtrUInt(Word)));
end;

end.
