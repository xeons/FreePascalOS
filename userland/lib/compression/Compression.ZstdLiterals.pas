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
  The literals section of a Zstandard compressed block (RFC 8878
  section 3.1.1.3.1): a header of 1 to 5 bytes giving the kind and the
  sizes, then the literals raw (used where they are, not copied), one
  byte to repeat, or Huffman coded in one or four streams with a new
  tree or the previous block's (treeless).
}
unit Compression.ZstdLiterals;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  Compression.Errors,
  Compression.ZstdHuffman;

type
  { What the literals section leaves for the sequences. }
  TZstdLiteralsState = record
    { The tree a treeless section uses; HasTable once one was read in
      this frame. }
    Table: TZstdHuffmanTable;
    HasTable: Boolean;
  end;

{ Reads the section at the start of Block (BlockSize bytes). Literals
  points at the literals afterwards: into Block for raw ones, into
  Buffer (at least BlockMaximum bytes) otherwise. SectionSize is the
  section's size. }
function ReadZstdLiterals(Block: PByte; BlockSize: SizeUInt; BlockMaximum: SizeUInt; var State: TZstdLiteralsState;
  Buffer: PByte; out Literals: PByte; out LiteralCount: SizeUInt; out SectionSize: SizeUInt): TCompressionError;

implementation

const
  LiteralsRaw = 0;
  LiteralsRle = 1;
  LiteralsCompressed = 2;
  LiteralsTreeless = 3;

function ReadZstdLiterals(Block: PByte; BlockSize: SizeUInt; BlockMaximum: SizeUInt; var State: TZstdLiteralsState;
  Buffer: PByte; out Literals: PByte; out LiteralCount: SizeUInt; out SectionSize: SizeUInt): TCompressionError;
var
  Kind: Integer;
  SizeFormat: Integer;
  HeaderSize: SizeUInt;
  RegeneratedSize: SizeUInt;
  CompressedSize: SizeUInt;
  FourStreams: Boolean;
  Header: QWord;
  Index: Integer;
  TreeSize: SizeUInt;
begin
  Result := CompressionErrorCorruptBlock;
  Literals := nil;
  LiteralCount := 0;
  SectionSize := 0;
  if BlockSize < 1 then
    Exit;
  Kind := Block[0] and 3;
  SizeFormat := (Block[0] shr 2) and 3;
  CompressedSize := 0;
  FourStreams := False;
  if (Kind = LiteralsRaw) or (Kind = LiteralsRle) then
  begin
    case SizeFormat of
      0, 2:
        begin
          HeaderSize := 1;
          RegeneratedSize := Block[0] shr 3;
        end;
      1:
        begin
          HeaderSize := 2;
          if BlockSize < HeaderSize then
            Exit;
          RegeneratedSize := (Block[0] shr 4) or (SizeUInt(Block[1]) shl 4);
        end;
    else
      begin
        HeaderSize := 3;
        if BlockSize < HeaderSize then
          Exit;
        RegeneratedSize := (Block[0] shr 4) or (SizeUInt(Block[1]) shl 4) or (SizeUInt(Block[2]) shl 12);
      end;
    end;
  end
  else
  begin
    { 3, 3, 4 or 5 header bytes: both sizes of 10, 10, 14 or 18 bits. }
    FourStreams := SizeFormat <> 0;
    case SizeFormat of
      0, 1: HeaderSize := 3;
      2: HeaderSize := 4;
    else
      HeaderSize := 5;
    end;
    if BlockSize < HeaderSize then
      Exit;
    Header := 0;
    for Index := HeaderSize - 1 downto 0 do
      Header := (Header shl 8) or Block[Index];
    Header := Header shr 4;
    case SizeFormat of
      0, 1:
        begin
          RegeneratedSize := Header and $3FF;
          CompressedSize := (Header shr 10) and $3FF;
        end;
      2:
        begin
          RegeneratedSize := Header and $3FFF;
          CompressedSize := (Header shr 14) and $3FFF;
        end;
    else
      begin
        RegeneratedSize := Header and $3FFFF;
        CompressedSize := (Header shr 18) and $3FFFF;
      end;
    end;
  end;
  if RegeneratedSize > BlockMaximum then
    Exit;
  LiteralCount := RegeneratedSize;

  case Kind of
    LiteralsRaw:
      begin
        if HeaderSize + RegeneratedSize > BlockSize then
          Exit;
        Literals := Block + HeaderSize;
        SectionSize := HeaderSize + RegeneratedSize;
      end;
    LiteralsRle:
      begin
        if HeaderSize + 1 > BlockSize then
          Exit;
        FillChar(Buffer^, RegeneratedSize, Block[HeaderSize]);
        Literals := Buffer;
        SectionSize := HeaderSize + 1;
      end;
  else
    begin
      if HeaderSize + CompressedSize > BlockSize then
        Exit;
      SectionSize := HeaderSize + CompressedSize;
      TreeSize := 0;
      if Kind = LiteralsCompressed then
      begin
        Result := ReadZstdHuffmanTable(Block + HeaderSize, CompressedSize, State.Table, TreeSize);
        if Result <> CompressionErrorNone then
          Exit;
        State.HasTable := True;
      end
      else if not State.HasTable then
        Exit(CompressionErrorCorruptBlock);
      Result := DecodeZstdHuffmanLiterals(State.Table, Block + HeaderSize + TreeSize, CompressedSize - TreeSize,
        FourStreams, Buffer, RegeneratedSize);
      if Result <> CompressionErrorNone then
        Exit;
      Literals := Buffer;
    end;
  end;
  Result := CompressionErrorNone;
end;

end.
