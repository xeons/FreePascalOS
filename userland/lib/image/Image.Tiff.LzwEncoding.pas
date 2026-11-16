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
  TIFF's LZW (compression 5) encoded, as libtiff encodes it: a clear
  code first, codes from the highest bit, the width grown when the next
  free code no longer fits (the decoder, one code behind, grows it one
  code early), a clear code when the table reaches 4094 entries, and
  the end code at the width the decoder will be at after the last code.

  The table of strings is a hash of (prefix code, next byte) with open
  addressing, emptied at each clear code.
}
unit Image.Tiff.LzwEncoding;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  SysUtils;

{ Count bytes at Input as TIFF LZW data. }
function EncodeTiffLzw(Input: PByte; Count: PtrInt): TBytes;

implementation

const
  ClearCode = 256;
  EndCode = 257;
  FirstFreeCode = 258;
  LastCodeBeforeClear = 4094;
  MinimumWidth = 9;
  HashSize = 9973;

type
  TLzwHashEntry = record
    Key: LongInt;
    Code: LongInt;
  end;

  TLzwEncoder = record
    Output: TBytes;
    Size: PtrInt;
    BitBuffer: LongWord;
    BitsInBuffer: LongInt;
    Width: LongInt;
    NextCode: LongInt;
    Hash: array[0..HashSize - 1] of TLzwHashEntry;
  end;
  PLzwEncoder = ^TLzwEncoder;

procedure PutByte(Encoder: PLzwEncoder; Value: Byte);
begin
  if Encoder^.Size >= Length(Encoder^.Output) then
    SetLength(Encoder^.Output, 2 * Length(Encoder^.Output) + 64);
  Encoder^.Output[Encoder^.Size] := Value;
  Inc(Encoder^.Size);
end;

procedure PutCode(Encoder: PLzwEncoder; Code: LongInt);
begin
  Encoder^.BitBuffer := (Encoder^.BitBuffer shl Encoder^.Width) or LongWord(Code);
  Inc(Encoder^.BitsInBuffer, Encoder^.Width);
  while Encoder^.BitsInBuffer >= 8 do
  begin
    PutByte(Encoder, (Encoder^.BitBuffer shr (Encoder^.BitsInBuffer - 8)) and $FF);
    Dec(Encoder^.BitsInBuffer, 8);
  end;
end;

procedure FlushBits(Encoder: PLzwEncoder);
begin
  if Encoder^.BitsInBuffer > 0 then
    PutByte(Encoder, (Encoder^.BitBuffer shl (8 - Encoder^.BitsInBuffer)) and $FF);
  Encoder^.BitsInBuffer := 0;
end;

procedure ClearTable(Encoder: PLzwEncoder);
var
  Index: LongInt;
begin
  for Index := 0 to HashSize - 1 do
    Encoder^.Hash[Index].Key := -1;
  Encoder^.NextCode := FirstFreeCode;
end;

function HashSlot(Key: LongInt): LongInt;
begin
  Result := LongInt((LongWord(Key) * 2654435761) mod HashSize);
end;

{ The code of (Prefix, Value), or -1; Slot is where it is or would go. }
function FindString(Encoder: PLzwEncoder; Key: LongInt; out Slot: LongInt): LongInt;
begin
  Slot := HashSlot(Key);
  while Encoder^.Hash[Slot].Key >= 0 do
  begin
    if Encoder^.Hash[Slot].Key = Key then
      Exit(Encoder^.Hash[Slot].Code);
    Inc(Slot);
    if Slot = HashSize then
      Slot := 0;
  end;
  Result := -1;
end;

{ After a code is put out: the table has one more entry, or is full. }
procedure CountEntry(Encoder: PLzwEncoder);
begin
  Inc(Encoder^.NextCode);
  if Encoder^.NextCode = LastCodeBeforeClear then
  begin
    PutCode(Encoder, ClearCode);
    ClearTable(Encoder);
    Encoder^.Width := MinimumWidth;
  end
  else if Encoder^.NextCode >= (1 shl Encoder^.Width) then
    Inc(Encoder^.Width);
end;

function EncodeTiffLzw(Input: PByte; Count: PtrInt): TBytes;
var
  Encoder: PLzwEncoder;
  Prefix: LongInt;
  Position: PtrInt;
  Value: Byte;
  Key: LongInt;
  Slot: LongInt;
  Found: LongInt;
begin
  New(Encoder);
  try
    Encoder^.Output := nil;
    SetLength(Encoder^.Output, Count div 2 + 64);
    Encoder^.Size := 0;
    Encoder^.BitBuffer := 0;
    Encoder^.BitsInBuffer := 0;
    Encoder^.Width := MinimumWidth;
    ClearTable(Encoder);
    PutCode(Encoder, ClearCode);
    if Count > 0 then
    begin
      Prefix := Input[0];
      Position := 1;
      while Position < Count do
      begin
        Value := Input[Position];
        Inc(Position);
        Key := (Prefix shl 8) or Value;
        Found := FindString(Encoder, Key, Slot);
        if Found >= 0 then
        begin
          Prefix := Found;
          Continue;
        end;
        PutCode(Encoder, Prefix);
        Encoder^.Hash[Slot].Key := Key;
        Encoder^.Hash[Slot].Code := Encoder^.NextCode;
        CountEntry(Encoder);
        Prefix := Value;
      end;
      PutCode(Encoder, Prefix);
      CountEntry(Encoder);
    end;
    PutCode(Encoder, EndCode);
    FlushBits(Encoder);
    Result := Copy(Encoder^.Output, 0, Encoder^.Size);
  finally
    Dispose(Encoder);
  end;
end;

end.
