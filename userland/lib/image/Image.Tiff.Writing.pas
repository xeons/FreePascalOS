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
  Writing TIFF: little-endian classic TIFF, one page per image, 8-bit
  RGB (or RGBA, unassociated alpha, when any pixel is not opaque),
  chunky, in strips of about 64 KiB, uncompressed, LZW or deflate
  (zlib, compression 8, through libcompression), with the horizontal
  predictor if asked (not for uncompressed data). The resolution (dots
  per inch), orientation, ICC profile and the description, software and
  date in the metadata are written when there are any.

  Each page is its strips, then the values too large for their entries
  (on even offsets), then its directory; the header and each directory
  point at the next one.
}
unit Image.Tiff.Writing;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  SysUtils,
  Image.Model;

type
  TTiffWriteCompression = (TiffWriteUncompressed, TiffWriteLzw, TiffWriteDeflate);

  TTiffWriteOptions = record
    Compression: TTiffWriteCompression;
    UsePredictor: Boolean;
    { zlib's level, 0 to 9, for deflate. }
    DeflateLevel: LongInt;
  end;

{ Deflate with the predictor at level 6. }
function DefaultTiffWriteOptions: TTiffWriteOptions;
function MakeTiffWriteOptions(Compression: TTiffWriteCompression; UsePredictor: Boolean): TTiffWriteOptions;
{ A TIFF file of Image. }
function EncodeTiffImage(Image: TImage; constref Options: TTiffWriteOptions): TBytes;
{ A TIFF file with each image a page. }
function EncodeTiffPages(const Images: array of TImage; constref Options: TTiffWriteOptions): TBytes;

implementation

uses
  Compression.Buffers,
  Image.Metadata,
  Image.ByteWriters,
  Image.Tiff.Tags,
  Image.Tiff.Predictor,
  Image.Tiff.LzwEncoding;

const
  TargetStripBytes = 65536;
  ResolutionDenominator = 1000;

type
  TTiffOutEntry = record
    Tag: LongWord;
    FieldType: LongWord;
    Count: LongWord;
    Value: TBytes;
  end;
  TTiffOutEntries = array of TTiffOutEntry;

function DefaultTiffWriteOptions: TTiffWriteOptions;
begin
  Result := MakeTiffWriteOptions(TiffWriteDeflate, True);
end;

function MakeTiffWriteOptions(Compression: TTiffWriteCompression; UsePredictor: Boolean): TTiffWriteOptions;
begin
  Result.Compression := Compression;
  Result.UsePredictor := UsePredictor and (Compression <> TiffWriteUncompressed);
  Result.DeflateLevel := 6;
end;

function LongBytes(const Values: array of LongWord): TBytes;
var
  Index: LongInt;
begin
  Result := nil;
  SetLength(Result, 4 * Length(Values));
  for Index := 0 to High(Values) do
  begin
    Result[4 * Index] := Values[Index] and $FF;
    Result[4 * Index + 1] := (Values[Index] shr 8) and $FF;
    Result[4 * Index + 2] := (Values[Index] shr 16) and $FF;
    Result[4 * Index + 3] := Values[Index] shr 24;
  end;
end;

function ShortBytes(const Values: array of LongWord): TBytes;
var
  Index: LongInt;
begin
  Result := nil;
  SetLength(Result, 2 * Length(Values));
  for Index := 0 to High(Values) do
  begin
    Result[2 * Index] := Values[Index] and $FF;
    Result[2 * Index + 1] := (Values[Index] shr 8) and $FF;
  end;
end;

function TextBytes(const Text: string): TBytes;
begin
  Result := nil;
  SetLength(Result, Length(Text) + 1);
  if Length(Text) > 0 then
    Move(Text[1], Result[0], Length(Text));
  Result[Length(Text)] := 0;
end;

procedure AddEntry(var Entries: TTiffOutEntries; Tag, FieldType, Count: LongWord; const Value: TBytes);
var
  Position: LongInt;
begin
  { Kept sorted by tag, as a directory must be. }
  Position := Length(Entries);
  SetLength(Entries, Position + 1);
  while (Position > 0) and (Entries[Position - 1].Tag > Tag) do
  begin
    Entries[Position] := Entries[Position - 1];
    Dec(Position);
  end;
  Entries[Position].Tag := Tag;
  Entries[Position].FieldType := FieldType;
  Entries[Position].Count := Count;
  Entries[Position].Value := Value;
end;

procedure AddShort(var Entries: TTiffOutEntries; Tag, Value: LongWord);
begin
  AddEntry(Entries, Tag, TiffTypeShort, 1, ShortBytes([Value]));
end;

procedure AddLong(var Entries: TTiffOutEntries; Tag, Value: LongWord);
begin
  AddEntry(Entries, Tag, TiffTypeLong, 1, LongBytes([Value]));
end;

procedure AddText(var Entries: TTiffOutEntries; Tag: LongWord; const Text: string);
var
  Bytes: TBytes;
begin
  if Text = '' then
    Exit;
  Bytes := TextBytes(Text);
  AddEntry(Entries, Tag, TiffTypeAscii, Length(Bytes), Bytes);
end;

procedure AddRational(var Entries: TTiffOutEntries; Tag: LongWord; Value: Double);
begin
  AddEntry(Entries, Tag, TiffTypeRational, 1, LongBytes([LongWord(Round(Value * ResolutionDenominator)),
    ResolutionDenominator]));
end;

{ Lines Top to Top + Rows - 1 of Image as RGB or RGBA bytes. }
function StripSamples(Image: TImage; Top, Rows, SamplesPerPixel: LongInt): TBytes;
var
  Y: LongInt;
  X: LongInt;
  Line: PLongWord;
  Pixel: LongWord;
  Position: PtrInt;
begin
  Result := nil;
  SetLength(Result, PtrInt(Image.Width) * Rows * SamplesPerPixel);
  Position := 0;
  for Y := Top to Top + Rows - 1 do
  begin
    Line := Image.Line(Y);
    for X := 0 to Image.Width - 1 do
    begin
      Pixel := Line[X];
      Result[Position] := (Pixel shr 16) and $FF;
      Result[Position + 1] := (Pixel shr 8) and $FF;
      Result[Position + 2] := Pixel and $FF;
      if SamplesPerPixel = 4 then
        Result[Position + 3] := Pixel shr 24;
      Inc(Position, SamplesPerPixel);
    end;
  end;
end;

function CompressStrip(var Samples: TBytes; Rows, RowBytes, Width, SamplesPerPixel: LongInt;
  constref Options: TTiffWriteOptions): TBytes;
begin
  if Options.UsePredictor and (Length(Samples) > 0) then
    ApplyHorizontalPredictor(@Samples[0], Rows, RowBytes, Width, SamplesPerPixel);
  case Options.Compression of
    TiffWriteLzw:
      Result := EncodeTiffLzw(PByte(Samples), Length(Samples));
    TiffWriteDeflate:
      Result := CompressZlib(Samples, Options.DeflateLevel);
  else
    Result := Samples;
  end;
end;

function CompressionNumber(Compression: TTiffWriteCompression): LongWord;
begin
  case Compression of
    TiffWriteLzw: Result := TiffCompressionLzw;
    TiffWriteDeflate: Result := TiffCompressionAdobeDeflate;
  else
    Result := TiffCompressionNone;
  end;
end;

procedure AddDescription(var Entries: TTiffOutEntries; Image: TImage);
begin
  AddText(Entries, TiffTagImageDescription, Image.Metadata.GetValue(MetadataKeyDescription));
  AddText(Entries, TiffTagSoftware, Image.Metadata.GetValue(MetadataKeySoftware));
  AddText(Entries, TiffTagDateTime, Image.Metadata.GetValue(MetadataKeyDateTime));
  if Image.Orientation <> OrientationNormal then
    AddShort(Entries, TiffTagOrientation, OrientationToExif(Image.Orientation));
  if (Image.Resolution.HorizontalDpi > 0) and (Image.Resolution.VerticalDpi > 0) then
  begin
    AddRational(Entries, TiffTagXResolution, Image.Resolution.HorizontalDpi);
    AddRational(Entries, TiffTagYResolution, Image.Resolution.VerticalDpi);
    AddShort(Entries, TiffTagResolutionUnit, TiffResolutionUnitInch);
  end;
  if Length(Image.IccProfile) > 0 then
    AddEntry(Entries, TiffTagIccProfile, TiffTypeUndefined, Length(Image.IccProfile), Image.IccProfile);
end;

procedure PadToEven(Writer: TImageByteWriter);
begin
  if (Writer.Size and 1) <> 0 then
    Writer.WriteByte(0);
end;

{ Writes Image's strips and directory, points the link at PreviousLink
  (the header's or the page before's) at the directory, and gives where
  this directory's own link is. }
function WritePage(Writer: TImageByteWriter; Image: TImage; constref Options: TTiffWriteOptions;
  PreviousLink: PtrInt): PtrInt;
var
  SamplesPerPixel: LongInt;
  RowBytes: LongInt;
  RowsPerStrip: LongInt;
  StripCount: LongInt;
  Strip: LongInt;
  Top: LongInt;
  Rows: LongInt;
  Samples: TBytes;
  Compressed: TBytes;
  Offsets: array of LongWord;
  Counts: array of LongWord;
  Entries: TTiffOutEntries;
  Bits: array of LongWord;
  Index: LongInt;
  ValueOffsets: array of LongWord;
  Value: TBytes;
begin
  if Image.IsOpaque then
    SamplesPerPixel := 3
  else
    SamplesPerPixel := 4;
  RowBytes := Image.Width * SamplesPerPixel;
  RowsPerStrip := TargetStripBytes div RowBytes;
  if RowsPerStrip < 1 then
    RowsPerStrip := 1;
  if RowsPerStrip > Image.Height then
    RowsPerStrip := Image.Height;
  StripCount := (Image.Height + RowsPerStrip - 1) div RowsPerStrip;
  Offsets := nil;
  Counts := nil;
  SetLength(Offsets, StripCount);
  SetLength(Counts, StripCount);
  for Strip := 0 to StripCount - 1 do
  begin
    Top := Strip * RowsPerStrip;
    Rows := Image.Height - Top;
    if Rows > RowsPerStrip then
      Rows := RowsPerStrip;
    Samples := StripSamples(Image, Top, Rows, SamplesPerPixel);
    Compressed := CompressStrip(Samples, Rows, RowBytes, Image.Width, SamplesPerPixel, Options);
    PadToEven(Writer);
    Offsets[Strip] := Writer.Size;
    Counts[Strip] := Length(Compressed);
    Writer.WriteBytes(Compressed);
  end;

  Entries := nil;
  AddLong(Entries, TiffTagImageWidth, Image.Width);
  AddLong(Entries, TiffTagImageLength, Image.Height);
  Bits := nil;
  SetLength(Bits, SamplesPerPixel);
  for Index := 0 to SamplesPerPixel - 1 do
    Bits[Index] := 8;
  AddEntry(Entries, TiffTagBitsPerSample, TiffTypeShort, SamplesPerPixel, ShortBytes(Bits));
  AddShort(Entries, TiffTagCompression, CompressionNumber(Options.Compression));
  AddShort(Entries, TiffTagPhotometric, TiffPhotometricRgb);
  AddEntry(Entries, TiffTagStripOffsets, TiffTypeLong, StripCount, LongBytes(Offsets));
  AddShort(Entries, TiffTagSamplesPerPixel, SamplesPerPixel);
  AddLong(Entries, TiffTagRowsPerStrip, RowsPerStrip);
  AddEntry(Entries, TiffTagStripByteCounts, TiffTypeLong, StripCount, LongBytes(Counts));
  AddShort(Entries, TiffTagPlanarConfiguration, TiffPlanarChunky);
  if Options.UsePredictor then
    AddShort(Entries, TiffTagPredictor, TiffPredictorHorizontal);
  if SamplesPerPixel = 4 then
    AddShort(Entries, TiffTagExtraSamples, TiffExtraUnassociatedAlpha);
  AddDescription(Entries, Image);

  { The values that do not fit in their entries. }
  ValueOffsets := nil;
  SetLength(ValueOffsets, Length(Entries));
  for Index := 0 to Length(Entries) - 1 do
    if Length(Entries[Index].Value) > 4 then
    begin
      PadToEven(Writer);
      ValueOffsets[Index] := Writer.Size;
      Writer.WriteBytes(Entries[Index].Value);
    end;

  PadToEven(Writer);
  Writer.PatchLongLittle(PreviousLink, Writer.Size);
  Writer.WriteWordLittle(Length(Entries));
  for Index := 0 to Length(Entries) - 1 do
  begin
    Writer.WriteWordLittle(Entries[Index].Tag);
    Writer.WriteWordLittle(Entries[Index].FieldType);
    Writer.WriteLongLittle(Entries[Index].Count);
    if Length(Entries[Index].Value) > 4 then
      Writer.WriteLongLittle(ValueOffsets[Index])
    else
    begin
      Value := Entries[Index].Value;
      Writer.WriteBytes(Value);
      Writer.WriteZeros(4 - Length(Value));
    end;
  end;
  Result := Writer.Size;
  Writer.WriteLongLittle(0);
end;

function EncodeTiffPages(const Images: array of TImage; constref Options: TTiffWriteOptions): TBytes;
var
  Writer: TImageByteWriter;
  LinkOffset: PtrInt;
  Index: LongInt;
begin
  Writer := TImageByteWriter.Create;
  try
    Writer.WriteByte(Ord('I'));
    Writer.WriteByte(Ord('I'));
    Writer.WriteWordLittle(42);
    LinkOffset := Writer.Size;
    Writer.WriteLongLittle(0);
    for Index := 0 to High(Images) do
      LinkOffset := WritePage(Writer, Images[Index], Options, LinkOffset);
    Result := Writer.ToBytes;
  finally
    Writer.Free;
  end;
end;

function EncodeTiffImage(Image: TImage; constref Options: TTiffWriteOptions): TBytes;
begin
  Result := EncodeTiffPages([Image], Options);
end;

end.
