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
  QPACK's primitives (RFC 9204 section 4.1, from RFC 7541 section 5):
  integers with an N-bit prefix in the first byte (the rest of the byte
  belongs to the instruction) continued 7 bits at a time, and string
  literals: an H bit (Huffman coded) just above an N-bit prefixed length,
  then the bytes. Reading stops with False when the input ends early
  (an instruction stream waits for more) or Malformed when it is wrong
  (an integer over 62 bits, a bad Huffman code, a string over the
  limit).
}
unit Qpack.Primitives;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  SysUtils;

type
  TQpackOutput = record
    Data: array of Byte;
    Length: Integer;
  end;

  TQpackInput = record
    Position: PByte;
    Limit: PByte;
    Malformed: Boolean;
  end;

const
  { The longest string literal taken. }
  MaximumStringLength = 65536;

procedure InitializeInput(out Input: TQpackInput; Data: PByte; Length: PtrUInt);
function InputRemaining(constref Input: TQpackInput): PtrUInt;
{ The first byte's high bits (the instruction) without taking it. }
function PeekByte(constref Input: TQpackInput; out Value: Byte): Boolean;
function ReadPrefixedInteger(var Input: TQpackInput; PrefixBits: Integer; out Value: QWord): Boolean;
{ HuffmanBit is the H flag's bit in the first byte (the length's
  prefix is the bits below it). }
function ReadStringLiteral(var Input: TQpackInput; PrefixBits: Integer; out Text: string): Boolean;

procedure AppendByte(var Output: TQpackOutput; Value: Byte);
procedure AppendBytes(var Output: TQpackOutput; Data: PByte; Count: Integer);
{ Flags are the first byte's bits above the prefix. }
procedure AppendPrefixedInteger(var Output: TQpackOutput; Flags: Byte; PrefixBits: Integer; Value: QWord);
{ Huffman coded when that is shorter; Flags are the bits above the H
  bit. }
procedure AppendStringLiteral(var Output: TQpackOutput; Flags: Byte; PrefixBits: Integer; const Text: string);
function OutputBytes(constref Output: TQpackOutput): TBytes;

implementation

uses
  Qpack.Huffman;

procedure InitializeInput(out Input: TQpackInput; Data: PByte; Length: PtrUInt);
begin
  Input.Position := Data;
  Input.Limit := Data + Length;
  Input.Malformed := False;
end;

function InputRemaining(constref Input: TQpackInput): PtrUInt;
begin
  Result := PtrUInt(Input.Limit - Input.Position);
end;

function PeekByte(constref Input: TQpackInput; out Value: Byte): Boolean;
begin
  Value := 0;
  if Input.Position >= Input.Limit then
    Exit(False);
  Value := Input.Position^;
  Result := True;
end;

function ReadPrefixedInteger(var Input: TQpackInput; PrefixBits: Integer; out Value: QWord): Boolean;
var
  Mask: Byte;
  Cursor: PByte;
  Shift: Integer;
  Next: Byte;
begin
  Value := 0;
  if Input.Position >= Input.Limit then
    Exit(False);
  Cursor := Input.Position;
  Mask := (1 shl PrefixBits) - 1;
  Value := Cursor^ and Mask;
  Inc(Cursor);
  if Value = Mask then
  begin
    Shift := 0;
    repeat
      if Cursor >= Input.Limit then
        Exit(False);
      Next := Cursor^;
      Inc(Cursor);
      if Shift > 56 then
      begin
        Input.Malformed := True;
        Exit(False);
      end;
      Value := Value + (QWord(Next and $7F) shl Shift);
      Shift := Shift + 7;
    until (Next and $80) = 0;
    if Value > (QWord(1) shl 62) then
    begin
      Input.Malformed := True;
      Exit(False);
    end;
  end;
  Input.Position := Cursor;
  Result := True;
end;

function ReadStringLiteral(var Input: TQpackInput; PrefixBits: Integer; out Text: string): Boolean;
var
  Saved: PByte;
  Huffman: Boolean;
  Count: QWord;
begin
  Text := '';
  if Input.Position >= Input.Limit then
    Exit(False);
  Saved := Input.Position;
  Huffman := (Input.Position^ and (1 shl PrefixBits)) <> 0;
  if not ReadPrefixedInteger(Input, PrefixBits, Count) then
    Exit(False);
  if Count > MaximumStringLength then
  begin
    Input.Malformed := True;
    Exit(False);
  end;
  if Count > InputRemaining(Input) then
  begin
    Input.Position := Saved;
    Exit(False);
  end;
  if Huffman then
  begin
    if not HuffmanDecode(Input.Position, Count, Text) then
    begin
      Input.Malformed := True;
      Exit(False);
    end;
  end
  else
    SetString(Text, PChar(Input.Position), Count);
  Input.Position := Input.Position + Count;
  Result := True;
end;

procedure AppendByte(var Output: TQpackOutput; Value: Byte);
begin
  if Output.Length >= Length(Output.Data) then
    SetLength(Output.Data, Output.Length * 2 + 64);
  Output.Data[Output.Length] := Value;
  Inc(Output.Length);
end;

procedure AppendBytes(var Output: TQpackOutput; Data: PByte; Count: Integer);
begin
  if Count <= 0 then
    Exit;
  if Output.Length + Count > Length(Output.Data) then
    SetLength(Output.Data, (Output.Length + Count) * 2);
  Move(Data^, Output.Data[Output.Length], Count);
  Output.Length := Output.Length + Count;
end;

procedure AppendPrefixedInteger(var Output: TQpackOutput; Flags: Byte; PrefixBits: Integer; Value: QWord);
var
  Mask: QWord;
begin
  Mask := (QWord(1) shl PrefixBits) - 1;
  if Value < Mask then
  begin
    AppendByte(Output, Flags or Byte(Value));
    Exit;
  end;
  AppendByte(Output, Flags or Byte(Mask));
  Value := Value - Mask;
  while Value >= 128 do
  begin
    AppendByte(Output, Byte(Value and $7F) or $80);
    Value := Value shr 7;
  end;
  AppendByte(Output, Byte(Value));
end;

procedure AppendStringLiteral(var Output: TQpackOutput; Flags: Byte; PrefixBits: Integer; const Text: string);
var
  HuffmanLength: PtrUInt;
  Start: Integer;
begin
  HuffmanLength := HuffmanEncodedLength(Text);
  if HuffmanLength < PtrUInt(Length(Text)) then
  begin
    AppendPrefixedInteger(Output, Flags or (1 shl PrefixBits), PrefixBits, HuffmanLength);
    Start := Output.Length;
    if Output.Length + Integer(HuffmanLength) > Length(Output.Data) then
      SetLength(Output.Data, (Output.Length + Integer(HuffmanLength)) * 2);
    HuffmanEncode(Text, @Output.Data[Start]);
    Output.Length := Start + Integer(HuffmanLength);
  end
  else
  begin
    AppendPrefixedInteger(Output, Flags, PrefixBits, Length(Text));
    AppendBytes(Output, PByte(PChar(Text)), Length(Text));
  end;
end;

function OutputBytes(constref Output: TQpackOutput): TBytes;
begin
  Result := nil;
  SetLength(Result, Output.Length);
  if Output.Length > 0 then
    Move(Output.Data[0], Result[0], Output.Length);
end;

end.
