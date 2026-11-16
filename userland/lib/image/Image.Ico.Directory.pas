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
  The directory of an ICO or CUR file: the same picture in several
  sizes and depths.

  The file starts with three words: 0, the type (1 icon, 2 cursor) and
  the number of entries; then 16 bytes an entry: width and height (0
  for 256), colours in the palette, a reserved byte, two words that are
  planes and bits per pixel for an icon and the hotspot for a cursor,
  the entry's size and where it is in the file. An entry is a DIB of
  twice the height (the colours, then a 1-bit mask; Image.Ico.Reading)
  or a whole PNG file.

  TIconDirectory checks every entry lies inside the file and takes each
  one's real size and depth from the entry itself when it can (the
  directory's bytes are often wrong). NearestEntry picks the entry to
  show at a size: the same size, else the smallest larger one (shrinking
  looks better than growing), else the largest; the deepest of equal
  sizes.
}
unit Image.Ico.Directory;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Image.Errors,
  Image.ByteReaders,
  Image.Codecs;

const
  IconTypeIcon = 1;
  IconTypeCursor = 2;
  IconDirectoryHeaderSize = 6;
  IconDirectoryEntrySize = 16;

type
  TIconEntry = record
    Width: LongInt;
    Height: LongInt;
    BitsPerPixel: LongInt;
    HotspotX: LongInt;
    HotspotY: LongInt;
    Offset: LongWord;
    Size: LongWord;
    IsPng: Boolean;
  end;

  TIconDirectory = class
  private
    FData: TBytes;
    FIsCursor: Boolean;
    FEntries: array of TIconEntry;
    function GetCount: LongInt;
    function GetEntry(Index: LongInt): TIconEntry;
    procedure ReadEntry(Reader: TImageByteReader; Index: LongInt);
  public
    { Reads the directory of an ICO or CUR file (raises EImageError). }
    constructor Create(const Data: TBytes);
    { The bytes of entry Index (a DIB or a PNG file). }
    function EntryBytes(Index: LongInt): TBytes;
    { The entry nearest Size pixels at Scale (1 for 100 %); -1 if none. }
    function NearestEntry(Size: LongInt; Scale: Double = 1.0): LongInt;
    { The largest entry, the deepest of equal sizes; with SkipPng only
      DIB entries count. -1 if none. }
    function LargestEntry(SkipPng: Boolean = False): LongInt;
    property Data: TBytes read FData;
    property IsCursor: Boolean read FIsCursor;
    property Count: LongInt read GetCount;
    property Entries[Index: LongInt]: TIconEntry read GetEntry;
  end;

{ True when Data starts like an ICO (ExpectedType 1) or CUR (2) file. }
function LooksLikeIconFile(const Data: TBytes; ExpectedType: LongInt): Boolean;

implementation

function LooksLikeIconFile(const Data: TBytes; ExpectedType: LongInt): Boolean;
var
  EntryCount: LongWord;
  Reserved: LongWord;
  Planes: LongWord;
  ImageSize: LongWord;
begin
  Result := False;
  if Length(Data) < IconDirectoryHeaderSize + IconDirectoryEntrySize then
    Exit;
  if (PeekWordLittle(Data, 0) <> 0) or (PeekWordLittle(Data, 2) <> LongWord(ExpectedType)) then
    Exit;
  EntryCount := PeekWordLittle(Data, 4);
  if EntryCount = 0 then
    Exit;
  { The first entry's reserved byte is zero and, for icons, its planes
    0 or 1: enough to tell an icon from other data starting with zeros. }
  Reserved := Data[IconDirectoryHeaderSize + 3];
  Planes := PeekWordLittle(Data, IconDirectoryHeaderSize + 4);
  ImageSize := PeekLongLittle(Data, IconDirectoryHeaderSize + 8);
  if (Reserved <> 0) and (Reserved <> 255) then
    Exit;
  if (ExpectedType = IconTypeIcon) and (Planes > 1) then
    Exit;
  Result := ImageSize > 0;
end;

constructor TIconDirectory.Create(const Data: TBytes);
var
  Reader: TImageByteReader;
  EntryCount: LongInt;
  FileType: LongInt;
  Index: LongInt;
begin
  inherited Create;
  FData := Data;
  Reader := TImageByteReader.Create(Data);
  try
    if Reader.ReadWordLittle <> 0 then
      RaiseImageError(ImageErrorMalformed, 'icon directory');
    FileType := Reader.ReadWordLittle;
    if (FileType <> IconTypeIcon) and (FileType <> IconTypeCursor) then
      RaiseImageError(ImageErrorMalformed, 'icon type ' + IntToStr(FileType));
    FIsCursor := FileType = IconTypeCursor;
    EntryCount := Reader.ReadWordLittle;
    if EntryCount = 0 then
      RaiseImageError(ImageErrorMalformed, 'no icon entries');
    SetLength(FEntries, EntryCount);
    for Index := 0 to EntryCount - 1 do
      ReadEntry(Reader, Index);
  finally
    Reader.Free;
  end;
end;

procedure TIconDirectory.ReadEntry(Reader: TImageByteReader; Index: LongInt);
var
  Entry: TIconEntry;
  DirectoryWidth: LongInt;
  DirectoryHeight: LongInt;
  FirstWord: LongInt;
  SecondWord: LongInt;
  Start: PtrInt;
begin
  Entry := Default(TIconEntry);
  DirectoryWidth := Reader.ReadByte;
  DirectoryHeight := Reader.ReadByte;
  Reader.Skip(2);
  FirstWord := Reader.ReadWordLittle;
  SecondWord := Reader.ReadWordLittle;
  Entry.Size := Reader.ReadLongLittle;
  Entry.Offset := Reader.ReadLongLittle;
  if DirectoryWidth = 0 then
    DirectoryWidth := 256;
  if DirectoryHeight = 0 then
    DirectoryHeight := 256;
  Entry.Width := DirectoryWidth;
  Entry.Height := DirectoryHeight;
  if FIsCursor then
  begin
    Entry.HotspotX := FirstWord;
    Entry.HotspotY := SecondWord;
  end
  else
    Entry.BitsPerPixel := SecondWord;
  if (Entry.Offset >= LongWord(Length(FData))) or (Entry.Size > LongWord(Length(FData)) - Entry.Offset) then
    RaiseImageError(ImageErrorTruncated, 'icon entry ' + IntToStr(Index));
  Start := Entry.Offset;
  Entry.IsPng := BytesStartWith(FData, PngSignature, Start);
  if Entry.IsPng then
  begin
    { The PNG's own header: width and height big-endian at 16 and 20. }
    if Entry.Size >= 24 then
    begin
      Entry.Width := (FData[Start + 18] shl 8) or FData[Start + 19];
      Entry.Height := (FData[Start + 22] shl 8) or FData[Start + 23];
    end;
    Entry.BitsPerPixel := 32;
  end
  else if Entry.Size >= 16 then
  begin
    { The DIB's own header (a 40-byte one, as icons have). }
    if PeekLongLittle(FData, Start) >= 40 then
    begin
      Entry.Width := LongInt(PeekLongLittle(FData, Start + 4));
      Entry.Height := LongInt(PeekLongLittle(FData, Start + 8)) div 2;
      Entry.BitsPerPixel := PeekWordLittle(FData, Start + 14);
    end;
  end;
  FEntries[Index] := Entry;
end;

function TIconDirectory.GetCount: LongInt;
begin
  Result := Length(FEntries);
end;

function TIconDirectory.GetEntry(Index: LongInt): TIconEntry;
begin
  Result := FEntries[Index];
end;

function TIconDirectory.EntryBytes(Index: LongInt): TBytes;
begin
  Result := SliceBytes(FData, FEntries[Index].Offset, FEntries[Index].Size);
end;

function EntrySide(const Entry: TIconEntry): LongInt;
begin
  Result := Entry.Width;
  if Entry.Height > Result then
    Result := Entry.Height;
end;

function TIconDirectory.NearestEntry(Size: LongInt; Scale: Double): LongInt;
var
  Target: LongInt;
  Index: LongInt;
  Best: LongInt;
  Side: LongInt;
  BestSide: LongInt;
  Better: Boolean;
begin
  Target := Round(Size * Scale);
  if Target < 1 then
    Target := 1;
  Best := -1;
  BestSide := 0;
  for Index := 0 to Length(FEntries) - 1 do
  begin
    Side := EntrySide(FEntries[Index]);
    if Best < 0 then
      Better := True
    else if Side = BestSide then
      Better := FEntries[Index].BitsPerPixel > FEntries[Best].BitsPerPixel
    else if (Side >= Target) and (BestSide >= Target) then
      Better := Side < BestSide
    else if (Side >= Target) <> (BestSide >= Target) then
      Better := Side >= Target
    else
      Better := Side > BestSide;
    if Better then
    begin
      Best := Index;
      BestSide := Side;
    end;
  end;
  Result := Best;
end;

function TIconDirectory.LargestEntry(SkipPng: Boolean): LongInt;
var
  Index: LongInt;
  Best: LongInt;
  Area: Int64;
  BestArea: Int64;
begin
  Best := -1;
  BestArea := -1;
  for Index := 0 to Length(FEntries) - 1 do
  begin
    if SkipPng and FEntries[Index].IsPng then
      Continue;
    Area := Int64(FEntries[Index].Width) * FEntries[Index].Height;
    if (Area > BestArea) or ((Area = BestArea) and (FEntries[Index].BitsPerPixel > FEntries[Best].BitsPerPixel)) then
    begin
      Best := Index;
      BestArea := Area;
    end;
  end;
  Result := Best;
end;

end.
