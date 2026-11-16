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
  GIF's LZW compression, the other way round from Image.Gif.Lzw.

  The longest string already in the table is followed while the next
  index extends it; then its code is written and the string plus that
  index added. The table is found by hashing (code, index) pairs. The
  decoder adds each entry one code later than the encoder, so the code
  width grows when the encoder's next code passes 2^width rather than
  reaching it, and the end code is written as wide as the decoder will
  read it then. A full table (4096 codes) is started again with a clear
  code.
}
unit Image.Gif.LzwEncoding;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Image.ByteWriters;

{ Count indices (each below 2^MinimumCodeSize, which is 2 to 8)
  compressed into Writer as GIF's LZW code stream, before sub-blocks. }
procedure EncodeGifLzw(Indices: PByte; Count: PtrInt; MinimumCodeSize: LongInt; Writer: TImageByteWriter);

implementation

const
  MaximumCodeBits = 12;
  TableLimit = 1 shl MaximumCodeBits;
  HashSize = 8191;

type
  TCodeWriter = record
    Writer: TImageByteWriter;
    Buffer: LongWord;
    BitCount: LongInt;
  end;

procedure WriteCode(var CodeWriter: TCodeWriter; Code, Bits: LongInt);
begin
  CodeWriter.Buffer := CodeWriter.Buffer or (LongWord(Code) shl CodeWriter.BitCount);
  Inc(CodeWriter.BitCount, Bits);
  while CodeWriter.BitCount >= 8 do
  begin
    CodeWriter.Writer.WriteByte(CodeWriter.Buffer and $FF);
    CodeWriter.Buffer := CodeWriter.Buffer shr 8;
    Dec(CodeWriter.BitCount, 8);
  end;
end;

procedure FlushCodes(var CodeWriter: TCodeWriter);
begin
  if CodeWriter.BitCount > 0 then
    CodeWriter.Writer.WriteByte(CodeWriter.Buffer and $FF);
  CodeWriter.Buffer := 0;
  CodeWriter.BitCount := 0;
end;

procedure EncodeGifLzw(Indices: PByte; Count: PtrInt; MinimumCodeSize: LongInt; Writer: TImageByteWriter);
var
  HashKeys: array[0..HashSize - 1] of LongInt;
  HashCodes: array[0..HashSize - 1] of SmallInt;
  CodeWriter: TCodeWriter;
  ClearCode: LongInt;
  EndCode: LongInt;
  NextCode: LongInt;
  CodeBits: LongInt;
  Prefix: LongInt;
  Position: PtrInt;
  Index: LongInt;
  Key: LongInt;
  Slot: LongInt;
  Found: Boolean;

  procedure ResetTable;
  begin
    FillDWord(HashKeys, HashSize, LongWord(-1));
    NextCode := EndCode + 1;
    CodeBits := MinimumCodeSize + 1;
  end;

begin
  CodeWriter.Writer := Writer;
  CodeWriter.Buffer := 0;
  CodeWriter.BitCount := 0;
  ClearCode := 1 shl MinimumCodeSize;
  EndCode := ClearCode + 1;
  FillChar(HashCodes, SizeOf(HashCodes), 0);
  ResetTable;
  WriteCode(CodeWriter, ClearCode, CodeBits);
  if Count > 0 then
  begin
    Prefix := Indices[0];
    Position := 1;
    while Position < Count do
    begin
      Index := Indices[Position];
      Inc(Position);
      Key := (Prefix shl 8) or Index;
      Slot := Key mod HashSize;
      Found := False;
      while HashKeys[Slot] <> -1 do
      begin
        if HashKeys[Slot] = Key then
        begin
          Found := True;
          Break;
        end;
        Inc(Slot);
        if Slot = HashSize then
          Slot := 0;
      end;
      if Found then
      begin
        Prefix := HashCodes[Slot];
        Continue;
      end;
      WriteCode(CodeWriter, Prefix, CodeBits);
      HashKeys[Slot] := Key;
      HashCodes[Slot] := NextCode;
      Inc(NextCode);
      if (NextCode > (1 shl CodeBits)) and (CodeBits < MaximumCodeBits) then
        Inc(CodeBits);
      if NextCode >= TableLimit then
      begin
        WriteCode(CodeWriter, ClearCode, CodeBits);
        ResetTable;
      end;
      Prefix := Index;
    end;
    WriteCode(CodeWriter, Prefix, CodeBits);
    { The decoder adds an entry for that code before reading on. }
    if (NextCode >= (1 shl CodeBits)) and (CodeBits < MaximumCodeBits) then
      Inc(CodeBits);
  end;
  WriteCode(CodeWriter, EndCode, CodeBits);
  FlushCodes(CodeWriter);
end;

end.
