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
  The headers of a device independent bitmap (DIB), the body of a BMP
  file and of an icon's entries.

  A DIB starts with an information header whose first four bytes are
  its size: 12 (the OS/2 core header: 16-bit sides, palette entries of
  three bytes), 16 to 64 (OS/2's second header, read as far as the
  common fields go), 40 (the usual one), 52 and 56 (with the colour
  masks, and alpha), 108 (V4: masks, colour space) or 124 (V5: an
  embedded ICC profile too). With 40 bytes and BITFIELDS or
  ALPHABITFIELDS compression the three or four masks follow the header.
  Then the palette (for 8 bits and fewer, and optionally otherwise):
  the colours used, or all 2^bits when that is 0. A positive height
  stores the lines from the bottom up, a negative one from the top
  down.

  ReadBmpInfo reads all of that, checked against the data, into a
  TBmpInfo, and says where the palette ended (where the pixels are
  when nothing says otherwise).
}
unit Image.Bmp.Headers;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Drawing.Colors,
  Image.Errors,
  Image.ByteReaders,
  Image.Model;

const
  BmpCompressionRgb = 0;
  BmpCompressionRle8 = 1;
  BmpCompressionRle4 = 2;
  BmpCompressionBitfields = 3;
  BmpCompressionJpeg = 4;
  BmpCompressionPng = 5;
  BmpCompressionAlphaBitfields = 6;

  BmpCoreHeaderSize = 12;
  BmpInfoHeaderSize = 40;
  BmpV4HeaderSize = 108;
  BmpV5HeaderSize = 124;
  BmpFileHeaderSize = 14;

  { Colour space types (V4 and V5), four characters read as a number. }
  BmpColorSpaceCalibrated = 0;
  BmpColorSpaceSrgb = $73524742;      { 'sRGB' }
  BmpColorSpaceWindows = $57696E20;   { 'Win ' }
  BmpColorSpaceLinked = $4C494E4B;    { 'LINK' }
  BmpColorSpaceEmbedded = $4D424544;  { 'MBED' }

type
  TBmpInfo = record
    HeaderSize: LongWord;
    Width: LongInt;
    { Always positive; TopDown says which way the lines go. }
    Height: LongInt;
    TopDown: Boolean;
    BitsPerPixel: LongInt;
    Compression: LongWord;
    ImageSize: LongWord;
    HorizontalPixelsPerMeter: LongInt;
    VerticalPixelsPerMeter: LongInt;
    RedMask: LongWord;
    GreenMask: LongWord;
    BlueMask: LongWord;
    AlphaMask: LongWord;
    { True when the file gave the masks (rather than the defaults). }
    HasMasks: Boolean;
    ColorSpaceType: LongWord;
    { From the start of Data; 0 when there is none. }
    ProfileOffset: PtrInt;
    ProfileSize: LongWord;
    Palette: array of TColor;
  end;

{ Reads the DIB at DibStart of Data. Returns where the palette ends.
  Raises EImageError for headers that are cut short or make no sense. }
function ReadBmpInfo(const Data: TBytes; DibStart: PtrInt; out Info: TBmpInfo): PtrInt;
{ True when Size is a size an information header may have. }
function BmpHeaderSizeKnown(Size: LongWord): Boolean;
{ Bytes from one stored line to the next: lines are padded to four. }
function BmpRowStride(Width, BitsPerPixel: LongInt): Int64;
{ The resolution in dots per inch from pixels per metre. }
function BmpResolution(const Info: TBmpInfo): TImageResolution;

implementation

function BmpHeaderSizeKnown(Size: LongWord): Boolean;
begin
  Result := (Size = BmpCoreHeaderSize) or ((Size >= 16) and (Size <= 64)) or (Size = BmpV4HeaderSize) or
    (Size = BmpV5HeaderSize);
end;

function BmpRowStride(Width, BitsPerPixel: LongInt): Int64;
begin
  Result := ((Int64(Width) * BitsPerPixel + 31) div 32) * 4;
end;

function BmpResolution(const Info: TBmpInfo): TImageResolution;
begin
  Result := MakeResolution(Info.HorizontalPixelsPerMeter * 0.0254, Info.VerticalPixelsPerMeter * 0.0254);
end;

{ True for the headers that hold the colour masks themselves (V2 to V5;
  not OS/2's second header, which is 64 bytes at most). }
function HeaderHasMasks(HeaderSize: LongWord): Boolean;
begin
  Result := (HeaderSize >= 52) and (HeaderSize <> 64);
end;

procedure SetDefaultMasks(var Info: TBmpInfo);
begin
  Info.HasMasks := False;
  Info.AlphaMask := 0;
  case Info.BitsPerPixel of
    16:
      begin
        Info.RedMask := $7C00;
        Info.GreenMask := $03E0;
        Info.BlueMask := $001F;
      end;
    24, 32:
      begin
        Info.RedMask := $00FF0000;
        Info.GreenMask := $0000FF00;
        Info.BlueMask := $000000FF;
      end;
  else
    begin
      Info.RedMask := 0;
      Info.GreenMask := 0;
      Info.BlueMask := 0;
    end;
  end;
end;

procedure ReadCoreHeader(Reader: TImageByteReader; var Info: TBmpInfo);
var
  Planes: Word;
begin
  Info.Width := Reader.ReadWordLittle;
  Info.Height := SmallInt(Reader.ReadWordLittle);
  Planes := Reader.ReadWordLittle;
  Info.BitsPerPixel := Reader.ReadWordLittle;
  Info.Compression := BmpCompressionRgb;
  if Planes <> 1 then
    RaiseImageError(ImageErrorMalformed, 'planes');
end;

procedure ReadInfoHeader(Reader: TImageByteReader; var Info: TBmpInfo; out ColorsUsed: LongWord);
var
  HeaderStart: PtrInt;
  Planes: Word;
begin
  HeaderStart := Reader.Position - 4;
  Info.Width := Reader.ReadSignedLongLittle;
  Info.Height := Reader.ReadSignedLongLittle;
  Planes := Reader.ReadWordLittle;
  Info.BitsPerPixel := Reader.ReadWordLittle;
  if Planes <> 1 then
    RaiseImageError(ImageErrorMalformed, 'planes');
  ColorsUsed := 0;
  { OS/2's second header may stop after any field; what it leaves out
    is zero. }
  if Info.HeaderSize >= 20 then
    Info.Compression := Reader.ReadLongLittle;
  if Info.HeaderSize >= 24 then
    Info.ImageSize := Reader.ReadLongLittle;
  if Info.HeaderSize >= 32 then
  begin
    Info.HorizontalPixelsPerMeter := Reader.ReadSignedLongLittle;
    Info.VerticalPixelsPerMeter := Reader.ReadSignedLongLittle;
  end;
  if Info.HeaderSize >= 36 then
    ColorsUsed := Reader.ReadLongLittle;
  if Info.HeaderSize >= 40 then
    Reader.Skip(4);
  { V2 and later: the masks are part of the header. }
  if HeaderHasMasks(Info.HeaderSize) then
  begin
    Info.RedMask := Reader.ReadLongLittle;
    Info.GreenMask := Reader.ReadLongLittle;
    Info.BlueMask := Reader.ReadLongLittle;
    if Info.HeaderSize >= 56 then
      Info.AlphaMask := Reader.ReadLongLittle;
  end;
  if Info.HeaderSize >= BmpV4HeaderSize then
  begin
    Info.ColorSpaceType := Reader.ReadLongLittle;
    { Endpoints (36 bytes) and gamma (12). }
    Reader.Skip(48);
  end;
  if Info.HeaderSize >= BmpV5HeaderSize then
  begin
    Reader.Skip(4);
    Info.ProfileOffset := Reader.ReadLongLittle;
    Info.ProfileSize := Reader.ReadLongLittle;
    if Info.ColorSpaceType = BmpColorSpaceEmbedded then
      Info.ProfileOffset := HeaderStart + Info.ProfileOffset
    else
    begin
      Info.ProfileOffset := 0;
      Info.ProfileSize := 0;
    end;
  end;
  Reader.Seek(HeaderStart + Info.HeaderSize);
end;

procedure CheckInfo(const Info: TBmpInfo);
begin
  case Info.BitsPerPixel of
    1, 4, 8, 16, 24, 32: ;
  else
    RaiseImageError(ImageErrorMalformed, 'bits per pixel ' + IntToStr(Info.BitsPerPixel));
  end;
  case Info.Compression of
    BmpCompressionRgb: ;
    BmpCompressionRle8:
      if Info.BitsPerPixel <> 8 then
        RaiseImageError(ImageErrorMalformed, 'RLE8 needs 8 bits per pixel');
    BmpCompressionRle4:
      if Info.BitsPerPixel <> 4 then
        RaiseImageError(ImageErrorMalformed, 'RLE4 needs 4 bits per pixel');
    BmpCompressionBitfields, BmpCompressionAlphaBitfields:
      if (Info.BitsPerPixel <> 16) and (Info.BitsPerPixel <> 32) then
        RaiseImageError(ImageErrorMalformed, 'bit fields need 16 or 32 bits per pixel');
    BmpCompressionJpeg, BmpCompressionPng:
      RaiseImageError(ImageErrorUnsupported, 'JPEG or PNG inside a BMP');
  else
    RaiseImageError(ImageErrorUnsupported, 'compression ' + IntToStr(Info.Compression));
  end;
  if Info.Width <= 0 then
    RaiseImageError(ImageErrorMalformed, 'width');
  if Info.Height <= 0 then
    RaiseImageError(ImageErrorMalformed, 'height');
  CheckImageSize(Info.Width, Info.Height);
end;

procedure ReadPalette(Reader: TImageByteReader; var Info: TBmpInfo; ColorsUsed: LongWord; EntrySize: LongInt);
var
  Count: LongWord;
  Index: LongInt;
  Blue: Byte;
  Green: Byte;
  Red: Byte;
begin
  Count := ColorsUsed;
  if (Count = 0) and (Info.BitsPerPixel <= 8) then
    Count := LongWord(1) shl Info.BitsPerPixel;
  if Count > 256 then
  begin
    if Info.BitsPerPixel <= 8 then
      RaiseImageError(ImageErrorMalformed, 'palette of ' + IntToStr(Count));
    { A palette for a true colour picture is only a hint: skipped. }
    Count := 0;
  end;
  if Info.BitsPerPixel > 8 then
  begin
    Reader.Skip(Count * LongWord(EntrySize));
    Count := 0;
  end;
  SetLength(Info.Palette, Count);
  for Index := 0 to LongInt(Count) - 1 do
  begin
    Blue := Reader.ReadByte;
    Green := Reader.ReadByte;
    Red := Reader.ReadByte;
    if EntrySize = 4 then
      Reader.Skip(1);
    Info.Palette[Index] := RgbColor(Red, Green, Blue);
  end;
end;

function ReadBmpInfo(const Data: TBytes; DibStart: PtrInt; out Info: TBmpInfo): PtrInt;
var
  Reader: TImageByteReader;
  ColorsUsed: LongWord;
  EntrySize: LongInt;
begin
  Info := Default(TBmpInfo);
  Reader := TImageByteReader.Create(Data);
  try
    Reader.Seek(DibStart);
    Info.HeaderSize := Reader.ReadLongLittle;
    if not BmpHeaderSizeKnown(Info.HeaderSize) then
      RaiseImageError(ImageErrorMalformed, 'header size ' + IntToStr(Info.HeaderSize));
    Reader.Need(Info.HeaderSize - 4);
    ColorsUsed := 0;
    EntrySize := 4;
    if Info.HeaderSize = BmpCoreHeaderSize then
    begin
      ReadCoreHeader(Reader, Info);
      EntrySize := 3;
    end
    else
    begin
      Info.Compression := BmpCompressionRgb;
      ReadInfoHeader(Reader, Info, ColorsUsed);
    end;
    if Info.Height < 0 then
    begin
      if Info.Height = Low(LongInt) then
        RaiseImageError(ImageErrorMalformed, 'height');
      Info.Height := -Info.Height;
      Info.TopDown := True;
    end;
    { OS/2's second header numbers its compressions differently: 3 is
      Huffman and 4 RLE24, neither supported. }
    if (Info.HeaderSize > BmpInfoHeaderSize) and not HeaderHasMasks(Info.HeaderSize) and
      (Info.Compression >= 3) then
      RaiseImageError(ImageErrorUnsupported, 'OS/2 compression ' + IntToStr(Info.Compression));
    CheckInfo(Info);
    if not (Info.Compression in [BmpCompressionBitfields, BmpCompressionAlphaBitfields]) then
      { Masks count only with bit fields, even in a header that has them. }
      SetDefaultMasks(Info)
    else
    begin
      if not HeaderHasMasks(Info.HeaderSize) then
      begin
        Info.RedMask := Reader.ReadLongLittle;
        Info.GreenMask := Reader.ReadLongLittle;
        Info.BlueMask := Reader.ReadLongLittle;
        if Info.Compression = BmpCompressionAlphaBitfields then
          Info.AlphaMask := Reader.ReadLongLittle;
      end;
      Info.HasMasks := True;
      if (Info.RedMask or Info.GreenMask or Info.BlueMask) = 0 then
        RaiseImageError(ImageErrorMalformed, 'empty colour masks');
    end;
    ReadPalette(Reader, Info, ColorsUsed, EntrySize);
    if (Info.BitsPerPixel <= 8) and (Length(Info.Palette) = 0) then
      RaiseImageError(ImageErrorMalformed, 'no palette');
    Result := Reader.Position;
  finally
    Reader.Free;
  end;
end;

end.
