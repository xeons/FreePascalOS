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
  A TIFF file's structure: the header and the image file directories.

  The header is "II" (numbers little-endian) or "MM" (big-endian), then
  42 and the offset of the first directory as a 32-bit number; or, in
  BigTIFF, 43, the offset size (8), a zero, and the offset as 64 bits.
  A directory is a count of entries, the entries sorted by tag, and the
  offset of the next directory (0 after the last). An entry is a tag,
  a field type, a count of values and either the values themselves,
  when they fit in the entry's last field (4 bytes, 8 in BigTIFF), or
  the offset where they are.

  Every directory is a page. The chain of directories is followed with
  a check against loops (a directory already seen ends it) and against
  more than MaximumTiffPages. Values are read on demand and every one is
  checked against the data: an entry pointing outside is
  ImageErrorTruncated.
}
unit Image.Tiff.Directory;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Image.Errors,
  Image.Tiff.Tags;

const
  MaximumTiffPages = 65536;

type
  TTiffIntegerArray = array of Int64;
  TTiffNumberArray = array of Double;

  TTiffEntry = record
    Tag: LongWord;
    FieldType: LongWord;
    Count: Int64;
    { Where the values are in the file. }
    ValueOffset: Int64;
  end;

  TTiffDirectory = record
    Entries: array of TTiffEntry;
    NextOffset: Int64;
  end;

  TTiffFile = class
  private
    FData: TBytes;
    FBigEndian: Boolean;
    FBigTiff: Boolean;
    FFirstDirectoryOffset: Int64;
    procedure Need(Offset, Count: Int64);
    function ReadLong8Bits(Offset: Int64): Int64;
    { The size of an entry's values, checked to be inside the file. }
    function CheckedValueSize(constref Entry: TTiffEntry): Int64;
  public
    { Reads the header; ImageErrorUnknownFormat if it is not TIFF. }
    constructor Create(const Data: TBytes);
    function ReadWord(Offset: Int64): LongWord;
    function ReadLong(Offset: Int64): LongWord;
    function ReadLong8(Offset: Int64): Int64;
    { The directory at Offset. }
    function ReadDirectory(Offset: Int64): TTiffDirectory;
    { The offsets of every page's directory, in order. }
    function PageOffsets: TTiffIntegerArray;

    { The entry with Tag, False when there is none. }
    function FindEntry(constref Directory: TTiffDirectory; Tag: LongWord; out Entry: TTiffEntry): Boolean;
    { An entry's values as integers (BYTE, SHORT, LONG, LONG8 and their
      signed forms, IFD); a rational is its whole part. }
    function EntryIntegers(constref Entry: TTiffEntry): TTiffIntegerArray;
    { An entry's values as numbers (rationals divided out, floats). }
    function EntryNumbers(constref Entry: TTiffEntry): TTiffNumberArray;
    { An entry's values as bytes, as stored. }
    function EntryBytes(constref Entry: TTiffEntry): TBytes;
    { An ASCII entry's text, up to its first zero. }
    function EntryText(constref Entry: TTiffEntry): string;

    { The tag's first value, or Default when it is not there. }
    function IntegerOf(constref Directory: TTiffDirectory; Tag: LongWord; Default: Int64): Int64;
    function IntegersOf(constref Directory: TTiffDirectory; Tag: LongWord): TTiffIntegerArray;
    function NumberOf(constref Directory: TTiffDirectory; Tag: LongWord; Default: Double): Double;
    function NumbersOf(constref Directory: TTiffDirectory; Tag: LongWord): TTiffNumberArray;
    function BytesOf(constref Directory: TTiffDirectory; Tag: LongWord): TBytes;
    function TextOf(constref Directory: TTiffDirectory; Tag: LongWord): string;

    property Data: TBytes read FData;
    property BigEndian: Boolean read FBigEndian;
    property BigTiff: Boolean read FBigTiff;
  end;

{ True when Data starts with a TIFF or BigTIFF header. }
function LooksLikeTiff(const Data: TBytes): Boolean;

implementation

function LooksLikeTiff(const Data: TBytes): Boolean;
begin
  if Length(Data) < 8 then
    Exit(False);
  if (Data[0] = Ord('I')) and (Data[1] = Ord('I')) then
    Result := (Data[3] = 0) and ((Data[2] = 42) or (Data[2] = 43))
  else if (Data[0] = Ord('M')) and (Data[1] = Ord('M')) then
    Result := (Data[2] = 0) and ((Data[3] = 42) or (Data[3] = 43))
  else
    Result := False;
end;

constructor TTiffFile.Create(const Data: TBytes);
var
  Version: LongWord;
begin
  inherited Create;
  FData := Data;
  if not LooksLikeTiff(Data) then
    RaiseImageError(ImageErrorUnknownFormat, 'not a TIFF file');
  FBigEndian := Data[0] = Ord('M');
  Version := ReadWord(2);
  FBigTiff := Version = 43;
  if FBigTiff then
  begin
    if (ReadWord(4) <> 8) or (ReadWord(6) <> 0) then
      RaiseImageError(ImageErrorMalformed, 'BigTIFF offset size');
    FFirstDirectoryOffset := ReadLong8(8);
  end
  else
    FFirstDirectoryOffset := ReadLong(4);
end;

procedure TTiffFile.Need(Offset, Count: Int64);
begin
  if (Offset < 0) or (Count < 0) or (Offset > Length(FData)) or (Count > Length(FData) - Offset) then
    RaiseImageError(ImageErrorTruncated, 'TIFF data outside the file');
end;

function TTiffFile.ReadWord(Offset: Int64): LongWord;
begin
  Need(Offset, 2);
  if FBigEndian then
    Result := (LongWord(FData[Offset]) shl 8) or FData[Offset + 1]
  else
    Result := (LongWord(FData[Offset + 1]) shl 8) or FData[Offset];
end;

function TTiffFile.ReadLong(Offset: Int64): LongWord;
var
  FirstHalf: LongWord;
  SecondHalf: LongWord;
begin
  FirstHalf := ReadWord(Offset);
  SecondHalf := ReadWord(Offset + 2);
  if FBigEndian then
    Result := (FirstHalf shl 16) or SecondHalf
  else
    Result := (SecondHalf shl 16) or FirstHalf;
end;

function TTiffFile.ReadLong8(Offset: Int64): Int64;
var
  FirstHalf: QWord;
  SecondHalf: QWord;
  Value: QWord;
begin
  FirstHalf := ReadLong(Offset);
  SecondHalf := ReadLong(Offset + 4);
  if FBigEndian then
    Value := (FirstHalf shl 32) or SecondHalf
  else
    Value := (SecondHalf shl 32) or FirstHalf;
  if Value > QWord(High(Int64)) then
    RaiseImageError(ImageErrorMalformed, 'TIFF offset');
  Result := Int64(Value);
end;

function TTiffFile.ReadLong8Bits(Offset: Int64): Int64;
var
  FirstHalf: QWord;
  SecondHalf: QWord;
begin
  FirstHalf := ReadLong(Offset);
  SecondHalf := ReadLong(Offset + 4);
  if FBigEndian then
    Result := Int64((FirstHalf shl 32) or SecondHalf)
  else
    Result := Int64((SecondHalf shl 32) or FirstHalf);
end;

function TTiffFile.CheckedValueSize(constref Entry: TTiffEntry): Int64;
var
  TypeSize: LongInt;
begin
  TypeSize := TiffTypeSize(Entry.FieldType);
  if TypeSize = 0 then
    RaiseImageError(ImageErrorMalformed, 'TIFF field type');
  if (Entry.Count < 0) or (Entry.Count > Length(FData)) then
    RaiseImageError(ImageErrorTruncated, 'TIFF data outside the file');
  Result := Entry.Count * TypeSize;
  Need(Entry.ValueOffset, Result);
end;

function TTiffFile.ReadDirectory(Offset: Int64): TTiffDirectory;
var
  Count: Int64;
  EntrySize: LongInt;
  InlineSize: LongInt;
  Index: Int64;
  Position: Int64;
  Entry: TTiffEntry;
  ValueSize: Int64;
  TypeSize: LongInt;
begin
  Result := Default(TTiffDirectory);
  if FBigTiff then
  begin
    Count := ReadLong8(Offset);
    Position := Offset + 8;
    EntrySize := 20;
    InlineSize := 8;
  end
  else
  begin
    Count := ReadWord(Offset);
    Position := Offset + 2;
    EntrySize := 12;
    InlineSize := 4;
  end;
  if Count > Length(FData) then
    RaiseImageError(ImageErrorTruncated, 'TIFF directory');
  Need(Position, Count * EntrySize);
  SetLength(Result.Entries, Count);
  Index := 0;
  while Index < Count do
  begin
    Entry.Tag := ReadWord(Position);
    Entry.FieldType := ReadWord(Position + 2);
    if FBigTiff then
      Entry.Count := ReadLong8(Position + 4)
    else
      Entry.Count := ReadLong(Position + 4);
    TypeSize := TiffTypeSize(Entry.FieldType);
    ValueSize := Entry.Count * TypeSize;
    if (TypeSize > 0) and (Entry.Count > Length(FData)) then
      ValueSize := High(Int64);
    if ValueSize <= InlineSize then
      Entry.ValueOffset := Position + EntrySize - InlineSize
    else if FBigTiff then
      Entry.ValueOffset := ReadLong8(Position + 12)
    else
      Entry.ValueOffset := ReadLong(Position + 8);
    Result.Entries[Index] := Entry;
    Inc(Position, EntrySize);
    Inc(Index);
  end;
  if FBigTiff then
    Result.NextOffset := ReadLong8(Position)
  else
    Result.NextOffset := ReadLong(Position);
end;

function TTiffFile.PageOffsets: TTiffIntegerArray;
var
  Offset: Int64;
  Count: LongInt;
  Index: LongInt;
  Directory: TTiffDirectory;
  SeenBefore: Boolean;
begin
  Result := nil;
  Count := 0;
  Offset := FFirstDirectoryOffset;
  while (Offset <> 0) and (Count < MaximumTiffPages) do
  begin
    SeenBefore := False;
    for Index := 0 to Count - 1 do
      if Result[Index] = Offset then
        SeenBefore := True;
    if SeenBefore then
      Break;
    if Count = 0 then
      Directory := ReadDirectory(Offset)
    else
      try
        Directory := ReadDirectory(Offset);
      except
        { A broken link after the first page ends the chain there. }
        on EImageError do
          Break;
      end;
    SetLength(Result, Count + 1);
    Result[Count] := Offset;
    Inc(Count);
    Offset := Directory.NextOffset;
  end;
  if Count = 0 then
    RaiseImageError(ImageErrorMalformed, 'no TIFF directory');
end;

function TTiffFile.FindEntry(constref Directory: TTiffDirectory; Tag: LongWord; out Entry: TTiffEntry): Boolean;
var
  Index: LongInt;
begin
  for Index := 0 to Length(Directory.Entries) - 1 do
    if Directory.Entries[Index].Tag = Tag then
    begin
      Entry := Directory.Entries[Index];
      Exit(True);
    end;
  Entry := Default(TTiffEntry);
  Result := False;
end;

function TTiffFile.EntryIntegers(constref Entry: TTiffEntry): TTiffIntegerArray;
var
  TypeSize: LongInt;
  Index: Int64;
  Position: Int64;
  Denominator: LongWord;
begin
  Result := nil;
  CheckedValueSize(Entry);
  TypeSize := TiffTypeSize(Entry.FieldType);
  SetLength(Result, Entry.Count);
  Position := Entry.ValueOffset;
  Index := 0;
  while Index < Entry.Count do
  begin
    case Entry.FieldType of
      TiffTypeByte, TiffTypeUndefined, TiffTypeAscii:
        Result[Index] := FData[Position];
      TiffTypeSignedByte:
        Result[Index] := ShortInt(FData[Position]);
      TiffTypeShort:
        Result[Index] := ReadWord(Position);
      TiffTypeSignedShort:
        Result[Index] := SmallInt(ReadWord(Position));
      TiffTypeLong, TiffTypeIfd:
        Result[Index] := ReadLong(Position);
      TiffTypeSignedLong:
        Result[Index] := LongInt(ReadLong(Position));
      TiffTypeLong8, TiffTypeSignedLong8, TiffTypeIfd8:
        Result[Index] := ReadLong8(Position);
      TiffTypeRational, TiffTypeSignedRational:
        begin
          Denominator := ReadLong(Position + 4);
          if Denominator = 0 then
            Result[Index] := 0
          else
            Result[Index] := ReadLong(Position) div Denominator;
        end;
    else
      Result[Index] := 0;
    end;
    Inc(Position, TypeSize);
    Inc(Index);
  end;
end;

function TTiffFile.EntryNumbers(constref Entry: TTiffEntry): TTiffNumberArray;
var
  TypeSize: LongInt;
  Index: Int64;
  Position: Int64;
  Numerator: Double;
  Denominator: Double;
  SingleBits: LongWord;
  SingleValue: Single absolute SingleBits;
  DoubleBits: Int64;
  DoubleValue: Double absolute DoubleBits;
  Integers: TTiffIntegerArray;
begin
  Result := nil;
  CheckedValueSize(Entry);
  TypeSize := TiffTypeSize(Entry.FieldType);
  if (Entry.FieldType <> TiffTypeRational) and (Entry.FieldType <> TiffTypeSignedRational) and
    (Entry.FieldType <> TiffTypeFloat) and (Entry.FieldType <> TiffTypeDouble) then
  begin
    Integers := EntryIntegers(Entry);
    SetLength(Result, Length(Integers));
    for Index := 0 to Length(Integers) - 1 do
      Result[Index] := Integers[Index];
    Exit;
  end;
  SetLength(Result, Entry.Count);
  Position := Entry.ValueOffset;
  Index := 0;
  while Index < Entry.Count do
  begin
    case Entry.FieldType of
      TiffTypeRational:
        begin
          Numerator := ReadLong(Position);
          Denominator := ReadLong(Position + 4);
        end;
      TiffTypeSignedRational:
        begin
          Numerator := LongInt(ReadLong(Position));
          Denominator := LongInt(ReadLong(Position + 4));
        end;
      TiffTypeFloat:
        begin
          SingleBits := ReadLong(Position);
          Numerator := SingleValue;
          Denominator := 1;
        end;
    else
      begin
        DoubleBits := ReadLong8Bits(Position);
        Numerator := DoubleValue;
        Denominator := 1;
      end;
    end;
    if Denominator = 0 then
      Result[Index] := 0
    else
      Result[Index] := Numerator / Denominator;
    Inc(Position, TypeSize);
    Inc(Index);
  end;
end;

function TTiffFile.EntryBytes(constref Entry: TTiffEntry): TBytes;
var
  Size: Int64;
begin
  Size := CheckedValueSize(Entry);
  Result := Copy(FData, Entry.ValueOffset, Size);
end;

function TTiffFile.EntryText(constref Entry: TTiffEntry): string;
var
  Bytes: TBytes;
  Size: PtrInt;
begin
  Bytes := EntryBytes(Entry);
  Size := 0;
  while (Size < Length(Bytes)) and (Bytes[Size] <> 0) do
    Inc(Size);
  Result := '';
  SetLength(Result, Size);
  if Size > 0 then
    Move(Bytes[0], Result[1], Size);
end;

function TTiffFile.IntegerOf(constref Directory: TTiffDirectory; Tag: LongWord; Default: Int64): Int64;
var
  Values: TTiffIntegerArray;
begin
  Values := IntegersOf(Directory, Tag);
  if Length(Values) = 0 then
    Result := Default
  else
    Result := Values[0];
end;

function TTiffFile.IntegersOf(constref Directory: TTiffDirectory; Tag: LongWord): TTiffIntegerArray;
var
  Entry: TTiffEntry;
begin
  if FindEntry(Directory, Tag, Entry) then
    Result := EntryIntegers(Entry)
  else
    Result := nil;
end;

function TTiffFile.NumberOf(constref Directory: TTiffDirectory; Tag: LongWord; Default: Double): Double;
var
  Values: TTiffNumberArray;
begin
  Values := NumbersOf(Directory, Tag);
  if Length(Values) = 0 then
    Result := Default
  else
    Result := Values[0];
end;

function TTiffFile.NumbersOf(constref Directory: TTiffDirectory; Tag: LongWord): TTiffNumberArray;
var
  Entry: TTiffEntry;
begin
  if FindEntry(Directory, Tag, Entry) then
    Result := EntryNumbers(Entry)
  else
    Result := nil;
end;

function TTiffFile.BytesOf(constref Directory: TTiffDirectory; Tag: LongWord): TBytes;
var
  Entry: TTiffEntry;
begin
  if FindEntry(Directory, Tag, Entry) then
    Result := EntryBytes(Entry)
  else
    Result := nil;
end;

function TTiffFile.TextOf(constref Directory: TTiffDirectory; Tag: LongWord): string;
var
  Entry: TTiffEntry;
begin
  if FindEntry(Directory, Tag, Entry) then
    Result := EntryText(Entry)
  else
    Result := '';
end;

end.
