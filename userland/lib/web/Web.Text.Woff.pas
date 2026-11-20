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
  Web font files as TrueType data: WOFF 1.0 (W3C, 2012) unwrapped to
  the sfnt it carries (each table zlib-compressed or stored), TrueType
  and OpenType data as they are. WOFF2 (Brotli with table transforms)
  is not read yet.
}
unit Web.Text.Woff;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils;

type
  TWebFontKind = (WebFontUnknown, WebFontTrueType, WebFontOpenTypeCff, WebFontWoff, WebFontWoff2,
    WebFontCollection);

{ What the bytes are, by their signature. }
function DetectWebFontKind(const Data: TBytes): TWebFontKind;
{ The sfnt (TrueType) data of a web font file: WOFF unwrapped, sfnt
  data as it is; nil for what cannot be read. }
function WebFontToSfnt(const Data: TBytes): TBytes;

implementation

uses
  Compression.DecodeResults,
  Compression.BufferInflate;

const
  WoffHeaderSize = 44;
  WoffDirectoryEntrySize = 20;
  SfntDirectoryEntrySize = 16;
  MaximumTables = 256;
  MaximumSfntBytes = 32 * 1024 * 1024;

function ReadBig32(const Data: TBytes; Offset: SizeInt): LongWord;
begin
  Result := (LongWord(Data[Offset]) shl 24) or (LongWord(Data[Offset + 1]) shl 16) or
    (LongWord(Data[Offset + 2]) shl 8) or LongWord(Data[Offset + 3]);
end;

function ReadBig16(const Data: TBytes; Offset: SizeInt): Word;
begin
  Result := (Word(Data[Offset]) shl 8) or Word(Data[Offset + 1]);
end;

procedure WriteBig32(var Data: TBytes; Offset: SizeInt; Value: LongWord);
begin
  Data[Offset] := Byte(Value shr 24);
  Data[Offset + 1] := Byte(Value shr 16);
  Data[Offset + 2] := Byte(Value shr 8);
  Data[Offset + 3] := Byte(Value);
end;

procedure WriteBig16(var Data: TBytes; Offset: SizeInt; Value: Word);
begin
  Data[Offset] := Byte(Value shr 8);
  Data[Offset + 1] := Byte(Value);
end;

function DetectWebFontKind(const Data: TBytes): TWebFontKind;
var
  Signature: LongWord;
begin
  Result := WebFontUnknown;
  if Length(Data) < 4 then
    Exit;
  Signature := ReadBig32(Data, 0);
  case Signature of
    $00010000, $74727565 { 'true' }:
      Result := WebFontTrueType;
    $4F54544F { 'OTTO' }:
      Result := WebFontOpenTypeCff;
    $774F4646 { 'wOFF' }:
      Result := WebFontWoff;
    $774F4632 { 'wOF2' }:
      Result := WebFontWoff2;
    $74746366 { 'ttcf' }:
      Result := WebFontCollection;
  end;
end;

{ Inflates a zlib stream (2 byte header, deflate data, Adler-32) into
  exactly OutputSize bytes. }
function InflateZlib(const Data: TBytes; Offset, Count: SizeInt; var Output: TBytes; OutputOffset,
  OutputSize: SizeInt): Boolean;
var
  State: TBufferInflateState;
  InputUsed, OutputUsed: SizeUInt;
begin
  Result := False;
  if Count < 6 then
    Exit;
  if (Data[Offset] and $0F) <> 8 then
    Exit;
  if InflateIntoBuffer(State, @Data[Offset + 2], Count - 2, InputUsed, @Output[OutputOffset], OutputSize,
    OutputUsed) <> DecodeSucceeded then
    Exit;
  Result := SizeInt(OutputUsed) = OutputSize;
end;

function UnwrapWoff(const Data: TBytes): TBytes;
var
  Flavor: LongWord;
  TableCount, Index, SearchRange, EntrySelector: Integer;
  TotalSfntSize, TableOffset, CompressedLength, OriginalLength, Checksum, Tag: LongWord;
  Entry, OutputOffset, DirectoryOffset: SizeInt;
begin
  Result := nil;
  if Length(Data) < WoffHeaderSize then
    Exit;
  Flavor := ReadBig32(Data, 4);
  if ReadBig32(Data, 8) <> LongWord(Length(Data)) then
    Exit;
  TableCount := ReadBig16(Data, 12);
  TotalSfntSize := ReadBig32(Data, 16);
  if (TableCount = 0) or (TableCount > MaximumTables) or (TotalSfntSize > MaximumSfntBytes) then
    Exit;
  if WoffHeaderSize + TableCount * WoffDirectoryEntrySize > Length(Data) then
    Exit;
  SetLength(Result, TotalSfntSize);
  FillChar(Result[0], TotalSfntSize, 0);
  { The sfnt header. }
  WriteBig32(Result, 0, Flavor);
  WriteBig16(Result, 4, TableCount);
  SearchRange := 1;
  EntrySelector := 0;
  while SearchRange * 2 <= TableCount do
  begin
    SearchRange := SearchRange * 2;
    Inc(EntrySelector);
  end;
  WriteBig16(Result, 6, SearchRange * 16);
  WriteBig16(Result, 8, EntrySelector);
  WriteBig16(Result, 10, TableCount * 16 - SearchRange * 16);
  OutputOffset := 12 + TableCount * SfntDirectoryEntrySize;
  for Index := 0 to TableCount - 1 do
  begin
    Entry := WoffHeaderSize + Index * WoffDirectoryEntrySize;
    Tag := ReadBig32(Data, Entry);
    TableOffset := ReadBig32(Data, Entry + 4);
    CompressedLength := ReadBig32(Data, Entry + 8);
    OriginalLength := ReadBig32(Data, Entry + 12);
    Checksum := ReadBig32(Data, Entry + 16);
    if (QWord(TableOffset) + CompressedLength > QWord(Length(Data))) or
       (QWord(OutputOffset) + OriginalLength > QWord(TotalSfntSize)) or (CompressedLength > OriginalLength) then
      Exit(nil);
    if CompressedLength = OriginalLength then
    begin
      if OriginalLength > 0 then
        Move(Data[TableOffset], Result[OutputOffset], OriginalLength);
    end
    else if not InflateZlib(Data, TableOffset, CompressedLength, Result, OutputOffset, OriginalLength) then
      Exit(nil);
    DirectoryOffset := 12 + Index * SfntDirectoryEntrySize;
    WriteBig32(Result, DirectoryOffset, Tag);
    WriteBig32(Result, DirectoryOffset + 4, Checksum);
    WriteBig32(Result, DirectoryOffset + 8, OutputOffset);
    WriteBig32(Result, DirectoryOffset + 12, OriginalLength);
    { Tables start on four byte boundaries. }
    OutputOffset := OutputOffset + ((OriginalLength + 3) and not 3);
  end;
end;

function WebFontToSfnt(const Data: TBytes): TBytes;
begin
  case DetectWebFontKind(Data) of
    WebFontTrueType, WebFontOpenTypeCff:
      Result := Data;
    WebFontWoff:
      Result := UnwrapWoff(Data);
  else
    Result := nil;
  end;
end;

end.
