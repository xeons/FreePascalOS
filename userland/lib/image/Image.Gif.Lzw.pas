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
  GIF's LZW decompression.

  Codes are read least significant bit first, starting one bit wider
  than the minimum code size the image gives (2 to 8 bits of palette
  index; up to 11 accepted). The first codes after the literals are the
  clear code (start the table again) and the end code. Each other code
  is a string in the table, or the one about to be added (the previous
  string and its own first index); after each code the previous string
  plus the current one's first index is added, and the codes grow a bit
  wider whenever the table fills their width, up to 12 bits, where the
  table stops growing until the next clear code.

  DecodeGifLzw writes at most Count indices to Output and says how many
  it wrote: fewer when the data ends early, has its end code early, or
  holds a code that cannot be (the decoding stops there, keeping what
  came before). It never writes past Count or reads past the data.
}
unit Image.Gif.Lzw;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  SysUtils;

const
  GifMaximumCodeBits = 12;
  GifTableSize = 1 shl GifMaximumCodeBits;

{ Decodes the LZW data (the sub-blocks already joined) with the minimum
  code size MinimumCodeSize into Output (Count bytes). Returns the
  number of indices written; -1 if MinimumCodeSize is impossible. }
function DecodeGifLzw(const Data: TBytes; DataLength: PtrInt; MinimumCodeSize: LongInt; Output: PByte;
  Count: PtrInt): PtrInt;

implementation

type
  TLzwTable = record
    Prefix: array[0..GifTableSize - 1] of SmallInt;
    Suffix: array[0..GifTableSize - 1] of Byte;
    { The first index of each code's string and its length. }
    First: array[0..GifTableSize - 1] of Byte;
    Length: array[0..GifTableSize - 1] of Word;
  end;

function DecodeGifLzw(const Data: TBytes; DataLength: PtrInt; MinimumCodeSize: LongInt; Output: PByte;
  Count: PtrInt): PtrInt;
var
  Table: TLzwTable;
  ClearCode: LongInt;
  EndCode: LongInt;
  NextCode: LongInt;
  CodeBits: LongInt;
  CodeMask: LongInt;
  BitBuffer: LongWord;
  BitCount: LongInt;
  Position: PtrInt;
  Written: PtrInt;
  Code: LongInt;
  Previous: LongInt;
  StringCode: LongInt;
  StringLength: LongInt;
  Index: LongInt;
  FirstIndex: Byte;
  WritePosition: PtrInt;
  Literal: LongInt;
begin
  if (MinimumCodeSize < 1) or (MinimumCodeSize > 11) then
    Exit(-1);
  if DataLength > Length(Data) then
    DataLength := Length(Data);
  ClearCode := 1 shl MinimumCodeSize;
  EndCode := ClearCode + 1;
  for Literal := 0 to ClearCode - 1 do
  begin
    Table.Prefix[Literal] := -1;
    Table.Suffix[Literal] := Literal and $FF;
    Table.First[Literal] := Literal and $FF;
    Table.Length[Literal] := 1;
  end;
  NextCode := EndCode + 1;
  CodeBits := MinimumCodeSize + 1;
  CodeMask := (1 shl CodeBits) - 1;
  Previous := -1;
  BitBuffer := 0;
  BitCount := 0;
  Position := 0;
  Written := 0;
  while Written < Count do
  begin
    while (BitCount < CodeBits) and (Position < DataLength) do
    begin
      BitBuffer := BitBuffer or (LongWord(Data[Position]) shl BitCount);
      Inc(BitCount, 8);
      Inc(Position);
    end;
    if BitCount < CodeBits then
      Break;
    Code := BitBuffer and LongWord(CodeMask);
    BitBuffer := BitBuffer shr CodeBits;
    Dec(BitCount, CodeBits);

    if Code = ClearCode then
    begin
      NextCode := EndCode + 1;
      CodeBits := MinimumCodeSize + 1;
      CodeMask := (1 shl CodeBits) - 1;
      Previous := -1;
      Continue;
    end;
    if Code = EndCode then
      Break;

    if Previous < 0 then
    begin
      { The first code after a clear is a literal. }
      if Code >= ClearCode then
        Break;
      Output[Written] := Code;
      Inc(Written);
      Previous := Code;
      Continue;
    end;

    if Code < NextCode then
      FirstIndex := Table.First[Code]
    else if (Code = NextCode) and (NextCode < GifTableSize) then
      { The code about to be added: the previous string and its own
        first index. }
      FirstIndex := Table.First[Previous]
    else
      Break;

    { Adds the previous string and this one's first index. }
    if NextCode < GifTableSize then
    begin
      Table.Prefix[NextCode] := Previous;
      Table.Suffix[NextCode] := FirstIndex;
      Table.First[NextCode] := Table.First[Previous];
      Table.Length[NextCode] := Table.Length[Previous] + 1;
      Inc(NextCode);
      if (NextCode > CodeMask) and (CodeBits < GifMaximumCodeBits) then
      begin
        Inc(CodeBits);
        CodeMask := (1 shl CodeBits) - 1;
      end;
    end;

    { The string is written from its end back to its start. }
    StringCode := Code;
    StringLength := Table.Length[StringCode];
    WritePosition := Written + StringLength - 1;
    while StringCode >= 0 do
    begin
      if WritePosition < Count then
        Output[WritePosition] := Table.Suffix[StringCode];
      Dec(WritePosition);
      StringCode := Table.Prefix[StringCode];
    end;
    Index := StringLength;
    if Written + Index > Count then
      Index := Count - Written;
    Inc(Written, Index);
    Previous := Code;
  end;
  Result := Written;
end;

end.
