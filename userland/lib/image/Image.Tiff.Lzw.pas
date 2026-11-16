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
  TIFF's LZW (compression 5) decoded.

  Codes are 9 to 12 bits, packed from the highest bit of each byte.
  256 clears the table (and the width goes back to 9), 257 ends the
  data; 258 onwards are the strings the table learns, each the string
  of the code before with the first byte of the next. Unlike GIF, the
  width grows one code early: as soon as the next free code plus one
  no longer fits (after code 510 is learnt the codes are 10 bits).

  Files from before TIFF 6 (libtiff's "old-style" LZW) pack codes from
  the lowest bit, like GIF, and grow the width only when the next free
  code does not fit; they are told apart by their first two bytes (a
  clear code written from the lowest bit gives 0, then a byte with its
  lowest bit set), as libtiff tells them apart.

  The decoder writes into the room it is given and stops when it is
  full, at the end code or at the end of the data; a code not yet in
  the table ends the data there (what was decoded stays).
}
unit Image.Tiff.Lzw;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

{ Decodes Count bytes at Input into Output (Capacity bytes); gives how
  many bytes were written. }
function DecodeTiffLzw(Input: PByte; Count: PtrInt; Output: PByte; Capacity: PtrInt): PtrInt;
{ True when the data is old-style (codes from the lowest bit). }
function IsOldStyleLzw(Input: PByte; Count: PtrInt): Boolean;

implementation

const
  ClearCode = 256;
  EndCode = 257;
  FirstFreeCode = 258;
  TableSize = 4096;
  MinimumWidth = 9;
  MaximumWidth = 12;

type
  TLzwTable = record
    Prefix: array[0..TableSize - 1] of Word;
    Suffix: array[0..TableSize - 1] of Byte;
    { The first byte of each code's string. }
    First: array[0..TableSize - 1] of Byte;
    StringLength: array[0..TableSize - 1] of Word;
  end;

  TLzwBitReader = record
    Input: PByte;
    Count: PtrInt;
    Position: PtrInt;
    Buffer: QWord;
    BitsInBuffer: LongInt;
    LowestFirst: Boolean;
  end;

function IsOldStyleLzw(Input: PByte; Count: PtrInt): Boolean;
begin
  Result := (Count >= 2) and (Input[0] = 0) and ((Input[1] and 1) <> 0);
end;

{ The next code of Width bits, or -1 at the end of the data. }
function ReadCode(var Reader: TLzwBitReader; Width: LongInt): LongInt;
begin
  while Reader.BitsInBuffer < Width do
  begin
    if Reader.Position >= Reader.Count then
      Exit(-1);
    if Reader.LowestFirst then
      Reader.Buffer := Reader.Buffer or (QWord(Reader.Input[Reader.Position]) shl Reader.BitsInBuffer)
    else
      Reader.Buffer := (Reader.Buffer shl 8) or Reader.Input[Reader.Position];
    Inc(Reader.Position);
    Inc(Reader.BitsInBuffer, 8);
  end;
  if Reader.LowestFirst then
  begin
    Result := Reader.Buffer and ((QWord(1) shl Width) - 1);
    Reader.Buffer := Reader.Buffer shr Width;
  end
  else
    Result := (Reader.Buffer shr (Reader.BitsInBuffer - Width)) and ((QWord(1) shl Width) - 1);
  Dec(Reader.BitsInBuffer, Width);
end;

procedure ResetTable(var Table: TLzwTable);
var
  Code: LongInt;
begin
  for Code := 0 to 255 do
  begin
    Table.Prefix[Code] := 0;
    Table.Suffix[Code] := Code;
    Table.First[Code] := Code;
    Table.StringLength[Code] := 1;
  end;
end;

{ Writes Code's string at Output + Written, as much as fits. }
function WriteString(constref Table: TLzwTable; Code: LongInt; Output: PByte; Written, Capacity: PtrInt): PtrInt;
var
  Length: PtrInt;
  Position: PtrInt;
begin
  Length := Table.StringLength[Code];
  Position := Written + Length - 1;
  while Code >= 0 do
  begin
    if Position < Capacity then
      Output[Position] := Table.Suffix[Code];
    Dec(Position);
    if Code < 256 then
      Break;
    Code := Table.Prefix[Code];
  end;
  Result := Written + Length;
  if Result > Capacity then
    Result := Capacity;
end;

function DecodeTiffLzw(Input: PByte; Count: PtrInt; Output: PByte; Capacity: PtrInt): PtrInt;
var
  Table: ^TLzwTable;
  Reader: TLzwBitReader;
  OldStyle: Boolean;
  Width: LongInt;
  NextCode: LongInt;
  Code: LongInt;
  PreviousCode: LongInt;
  EarlyChange: LongInt;
begin
  Result := 0;
  OldStyle := IsOldStyleLzw(Input, Count);
  Reader := Default(TLzwBitReader);
  Reader.Input := Input;
  Reader.Count := Count;
  Reader.LowestFirst := OldStyle;
  if OldStyle then
    EarlyChange := 0
  else
    EarlyChange := 1;
  New(Table);
  try
    ResetTable(Table^);
    Width := MinimumWidth;
    NextCode := FirstFreeCode;
    PreviousCode := -1;
    while Result < Capacity do
    begin
      Code := ReadCode(Reader, Width);
      if (Code < 0) or (Code = EndCode) then
        Break;
      if Code = ClearCode then
      begin
        Width := MinimumWidth;
        NextCode := FirstFreeCode;
        PreviousCode := -1;
        Continue;
      end;
      if PreviousCode < 0 then
      begin
        if Code > 255 then
          Break;
        Result := WriteString(Table^, Code, Output, Result, Capacity);
        PreviousCode := Code;
        Continue;
      end;
      if Code > NextCode then
        Break;
      if (Code = NextCode) and (NextCode >= TableSize) then
        Break;
      if NextCode < TableSize then
      begin
        Table^.Prefix[NextCode] := PreviousCode;
        Table^.First[NextCode] := Table^.First[PreviousCode];
        if Code = NextCode then
          Table^.Suffix[NextCode] := Table^.First[PreviousCode]
        else
          Table^.Suffix[NextCode] := Table^.First[Code];
        Table^.StringLength[NextCode] := Table^.StringLength[PreviousCode] + 1;
        Inc(NextCode);
        if (NextCode + EarlyChange >= (1 shl Width)) and (Width < MaximumWidth) then
          Inc(Width);
      end;
      Result := WriteString(Table^, Code, Output, Result, Capacity);
      PreviousCode := Code;
    end;
  finally
    Dispose(Table);
  end;
end;

end.
