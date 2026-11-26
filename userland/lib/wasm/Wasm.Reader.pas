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
  A cursor over a module's bytes (spec section 5.1-5.2): bytes, LEB128
  integers with the spec's rules for malformed encodings, floating point
  bits and UTF-8 names.

  LEB128: an N-bit integer takes at most ceil(N / 7) bytes ("integer
  representation too long" past that), and the bits of the last byte
  beyond N must be zero for an unsigned integer and copies of the sign
  bit for a signed one ("integer too large"). Running past the end of
  the range the reader was given is "unexpected end". Offsets in errors
  are from the start of the module.
}
unit Wasm.Reader;

{$mode objfpc}
{$H+}
{$modeswitch advancedrecords}
{$R-}
{$Q-}

interface

uses
  SysUtils,
  Wasm.Errors;

type
  TWasmReader = record
    Bytes: PByte;      { the module's first byte }
    Position: SizeInt; { the next byte, from Bytes }
    Limit: SizeInt;    { the end of the range being read }
    procedure Initialize(ABytes: PByte; AStart, ALimit: SizeInt);
    function AtEnd: Boolean; inline;
    function Remaining: SizeInt; inline;
    procedure Fail(const Message: AnsiString);
    procedure FailAt(AtOffset: SizeInt; const Message: AnsiString);
    function ReadByte: Byte; inline;
    function PeekByte: Byte; inline;
    function ReadU32: Cardinal;
    function ReadS32: Int32;
    function ReadS33: Int64;
    function ReadS64: Int64;
    function ReadU64: QWord;
    function ReadF32Bits: DWord;
    function ReadF64Bits: QWord;
    procedure ReadRaw(Destination: Pointer; Count: SizeInt);
    procedure Skip(Count: SizeInt);
    { A length-prefixed UTF-8 name; malformed UTF-8 is an error. }
    function ReadName: AnsiString;
  end;

{ Whether Bytes[0..Count) is well formed UTF-8 (no overlong forms, no
  surrogates, nothing above U+10FFFF). }
function IsValidUtf8(Bytes: PByte; Count: SizeInt): Boolean;

implementation

uses
  Wasm.Limits;

procedure TWasmReader.Initialize(ABytes: PByte; AStart, ALimit: SizeInt);
begin
  Bytes := ABytes;
  Position := AStart;
  Limit := ALimit;
end;

function TWasmReader.AtEnd: Boolean;
begin
  Result := Position >= Limit;
end;

function TWasmReader.Remaining: SizeInt;
begin
  Result := Limit - Position;
end;

procedure TWasmReader.Fail(const Message: AnsiString);
begin
  raise EWasmMalformed.CreateAt(Position, Message);
end;

procedure TWasmReader.FailAt(AtOffset: SizeInt; const Message: AnsiString);
begin
  raise EWasmMalformed.CreateAt(AtOffset, Message);
end;

function TWasmReader.ReadByte: Byte;
begin
  if Position >= Limit then
    Fail('unexpected end');
  Result := Bytes[Position];
  Inc(Position);
end;

function TWasmReader.PeekByte: Byte;
begin
  if Position >= Limit then
    Fail('unexpected end');
  Result := Bytes[Position];
end;

function TWasmReader.ReadU32: Cardinal;
var
  Value: Byte;
  Shift: Integer;
begin
  Result := 0;
  Shift := 0;
  repeat
    Value := ReadByte;
    if Shift = 28 then
    begin
      if Value and $80 <> 0 then
        Fail('integer representation too long');
      if Value and $70 <> 0 then
        Fail('integer too large');
    end;
    Result := Result or (Cardinal(Value and $7F) shl Shift);
    Inc(Shift, 7);
  until Value and $80 = 0;
end;

function TWasmReader.ReadS32: Int32;
var
  Value: Byte;
  Shift: Integer;
  Accumulator: Cardinal;
begin
  Accumulator := 0;
  Shift := 0;
  repeat
    Value := ReadByte;
    if Shift = 28 then
    begin
      if Value and $80 <> 0 then
        Fail('integer representation too long');
      if (Value and $78 <> 0) and (Value and $78 <> $78) then
        Fail('integer too large');
    end;
    Accumulator := Accumulator or (Cardinal(Value and $7F) shl Shift);
    Inc(Shift, 7);
  until Value and $80 = 0;
  if (Shift < 32) and (Value and $40 <> 0) then
    Accumulator := Accumulator or (Cardinal($FFFFFFFF) shl Shift);
  Result := Int32(Accumulator);
end;

function TWasmReader.ReadS33: Int64;
var
  Value: Byte;
  Shift: Integer;
  Accumulator: QWord;
begin
  Accumulator := 0;
  Shift := 0;
  repeat
    Value := ReadByte;
    if Shift = 28 then
    begin
      if Value and $80 <> 0 then
        Fail('integer representation too long');
      if (Value and $70 <> 0) and (Value and $70 <> $70) then
        Fail('integer too large');
    end;
    Accumulator := Accumulator or (QWord(Value and $7F) shl Shift);
    Inc(Shift, 7);
  until Value and $80 = 0;
  if (Shift < 64) and (Value and $40 <> 0) then
    Accumulator := Accumulator or (QWord($FFFFFFFFFFFFFFFF) shl Shift);
  Result := Int64(Accumulator);
end;

function TWasmReader.ReadS64: Int64;
var
  Value: Byte;
  Shift: Integer;
  Accumulator: QWord;
begin
  Accumulator := 0;
  Shift := 0;
  repeat
    Value := ReadByte;
    if Shift = 63 then
    begin
      if Value and $80 <> 0 then
        Fail('integer representation too long');
      if (Value and $7F <> 0) and (Value and $7F <> $7F) then
        Fail('integer too large');
    end;
    Accumulator := Accumulator or (QWord(Value and $7F) shl Shift);
    Inc(Shift, 7);
  until Value and $80 = 0;
  if (Shift < 64) and (Value and $40 <> 0) then
    Accumulator := Accumulator or (QWord($FFFFFFFFFFFFFFFF) shl Shift);
  Result := Int64(Accumulator);
end;

function TWasmReader.ReadU64: QWord;
var
  Value: Byte;
  Shift: Integer;
begin
  Result := 0;
  Shift := 0;
  repeat
    Value := ReadByte;
    if Shift = 63 then
    begin
      if Value and $80 <> 0 then
        Fail('integer representation too long');
      if Value and $7E <> 0 then
        Fail('integer too large');
    end;
    Result := Result or (QWord(Value and $7F) shl Shift);
    Inc(Shift, 7);
  until Value and $80 = 0;
end;

function TWasmReader.ReadF32Bits: DWord;
begin
  ReadRaw(@Result, 4);
  Result := LEtoN(Result);
end;

function TWasmReader.ReadF64Bits: QWord;
begin
  ReadRaw(@Result, 8);
  Result := LEtoN(Result);
end;

procedure TWasmReader.ReadRaw(Destination: Pointer; Count: SizeInt);
begin
  if (Count < 0) or (Count > Limit - Position) then
    Fail('unexpected end');
  Move(Bytes[Position], Destination^, Count);
  Inc(Position, Count);
end;

procedure TWasmReader.Skip(Count: SizeInt);
begin
  if (Count < 0) or (Count > Limit - Position) then
    Fail('unexpected end');
  Inc(Position, Count);
end;

function TWasmReader.ReadName: AnsiString;
var
  Count: Cardinal;
begin
  Count := ReadU32;
  if Count > Limit - Position then
    Fail('length out of bounds');
  if Count > MaximumStringLength then
    Fail('name too long');
  if not IsValidUtf8(@Bytes[Position], Count) then
    Fail('malformed UTF-8 encoding');
  SetLength(Result, Count);
  if Count > 0 then
    Move(Bytes[Position], Result[1], Count);
  Inc(Position, Count);
end;

function IsValidUtf8(Bytes: PByte; Count: SizeInt): Boolean;
var
  Index, Needed, Continuation: SizeInt;
  Lead: Byte;
  CodePoint, Smallest: Cardinal;
begin
  Index := 0;
  while Index < Count do
  begin
    Lead := Bytes[Index];
    if Lead < $80 then
    begin
      Inc(Index);
      Continue;
    end;
    if Lead and $E0 = $C0 then
    begin
      Needed := 1;
      CodePoint := Lead and $1F;
      Smallest := $80;
    end
    else if Lead and $F0 = $E0 then
    begin
      Needed := 2;
      CodePoint := Lead and $0F;
      Smallest := $800;
    end
    else if Lead and $F8 = $F0 then
    begin
      Needed := 3;
      CodePoint := Lead and $07;
      Smallest := $10000;
    end
    else
      Exit(False);
    if Index + Needed >= Count then
      Exit(False);
    for Continuation := 1 to Needed do
    begin
      if Bytes[Index + Continuation] and $C0 <> $80 then
        Exit(False);
      CodePoint := (CodePoint shl 6) or (Bytes[Index + Continuation] and $3F);
    end;
    if (CodePoint < Smallest) or (CodePoint > $10FFFF) or ((CodePoint >= $D800) and (CodePoint <= $DFFF)) then
      Exit(False);
    Inc(Index, Needed + 1);
  end;
  Result := True;
end;

end.
