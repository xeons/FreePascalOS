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
  What a PNG says beside its pixels, put into the image.

    tEXt  keyword, a zero, Latin-1 text           metadata (as UTF-8)
    zTXt  keyword, a zero, method 0, zlib text    metadata
    iTXt  keyword, compressed or not, language,   metadata (UTF-8)
          translated keyword, UTF-8 text
    pHYs  pixels per unit both ways, the unit     resolution (unit 1, the
                                                  metre, as dots per inch)
    iCCP  profile name, method 0, zlib profile    the ICC profile
    gAMA  gamma x 100000                          'Gamma'
    cHRM  white point and primaries x 100000      'Chromaticities'
    sRGB  rendering intent                        'ColorSpace' sRGB and
                                                  'RenderingIntent'
    tIME  last modification                       'ModificationTime'
    eXIf  a TIFF structure, as in a JPEG's EXIF   the orientation

  The text's keyword is the metadata key ('Title', 'Author',
  'Description', 'Software', 'Comment'...). These chunks are optional,
  so one whose content does not make sense (a keyword with no end, data
  that does not decompress) is passed over rather than refusing the
  picture; colours are not corrected for gamma or chromaticities.
}
unit Image.Png.Ancillary;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Image.Model,
  Image.Png.Chunks;

const
  MetadataKeyGamma = 'Gamma';
  MetadataKeyChromaticities = 'Chromaticities';
  MetadataKeyRenderingIntent = 'RenderingIntent';
  MetadataKeyModificationTime = 'ModificationTime';

  { Bounds on what compressed text and profiles may expand to. }
  MaximumTextSize = 4 * 1024 * 1024;
  MaximumProfileSize = 64 * 1024 * 1024;

  PngMetresPerInch = 0.0254;

{ Puts what Chunk says into Image; False when it is not one of the
  chunks above. }
function ReadAncillaryChunk(const Data: TBytes; constref Chunk: TPngChunk; Image: TImage): Boolean;
{ Latin-1 text as UTF-8. }
function Latin1ToUtf8(const Text: RawByteString): string;

implementation

uses
  Image.Metadata,
  Image.Jpeg.Exif,
  Compression.Errors,
  Compression.Formats,
  Compression.Buffers;

const
  MaximumKeywordLength = 79;
  RenderingIntentNames: array[0..3] of string = ('Perceptual', 'RelativeColorimetric', 'Saturation',
    'AbsoluteColorimetric');

var
  NumberFormat: TFormatSettings;

function Latin1ToUtf8(const Text: RawByteString): string;
var
  Index: LongInt;
  Value: Byte;
  OutputLength: LongInt;
  Position: LongInt;
begin
  OutputLength := 0;
  for Index := 1 to Length(Text) do
    if Ord(Text[Index]) < $80 then
      Inc(OutputLength)
    else
      Inc(OutputLength, 2);
  Result := '';
  SetLength(Result, OutputLength);
  Position := 1;
  for Index := 1 to Length(Text) do
  begin
    Value := Ord(Text[Index]);
    if Value < $80 then
    begin
      Result[Position] := Chr(Value);
      Inc(Position);
    end
    else
    begin
      Result[Position] := Chr($C0 or (Value shr 6));
      Result[Position + 1] := Chr($80 or (Value and $3F));
      Inc(Position, 2);
    end;
  end;
end;

{ Bytes Start to Start + Count - 1 of Data as a string, unchanged. }
function BytesAsText(const Data: TBytes; Start, Count: PtrInt): RawByteString;
begin
  Result := '';
  SetLength(Result, Count);
  if Count > 0 then
    Move(Data[Start], Result[1], Count);
end;

function BytesToText(const Bytes: TBytes): RawByteString;
begin
  Result := BytesAsText(Bytes, 0, Length(Bytes));
end;

{ The position (in the file) of the zero ending the text that starts
  at Start, looking no further than Limit (exclusive); -1 if none. }
function FindZero(const Data: TBytes; Start, Limit: PtrInt): PtrInt;
var
  Position: PtrInt;
begin
  for Position := Start to Limit - 1 do
    if Data[Position] = 0 then
      Exit(Position);
  Result := -1;
end;

{ The chunk's keyword and where what follows it starts; False when it
  has no proper keyword. }
function ReadKeyword(const Data: TBytes; constref Chunk: TPngChunk; out Keyword: string; out Rest: PtrInt): Boolean;
var
  Limit: PtrInt;
  Zero: PtrInt;
begin
  Limit := Chunk.DataOffset + Chunk.DataLength;
  Zero := FindZero(Data, Chunk.DataOffset, Limit);
  Result := (Zero > Chunk.DataOffset) and (Zero - Chunk.DataOffset <= MaximumKeywordLength);
  if not Result then
    Exit;
  Keyword := Latin1ToUtf8(BytesAsText(Data, Chunk.DataOffset, Zero - Chunk.DataOffset));
  Rest := Zero + 1;
end;

function Inflate(const Data: TBytes; Start, Count: PtrInt; MaximumSize: Int64; out Output: TBytes): Boolean;
begin
  Output := nil;
  if Count <= 0 then
    Exit(False);
  try
    Output := DecompressBuffer(@Data[Start], Count, FormatZlib, MaximumSize);
    Result := True;
  except
    on ECompressionError do
      Result := False;
  end;
end;

procedure ReadText(const Data: TBytes; constref Chunk: TPngChunk; Image: TImage);
var
  Keyword: string;
  Rest: PtrInt;
begin
  if ReadKeyword(Data, Chunk, Keyword, Rest) then
    Image.Metadata.SetValue(Keyword, Latin1ToUtf8(BytesAsText(Data, Rest, Chunk.DataOffset + Chunk.DataLength - Rest)));
end;

procedure ReadCompressedText(const Data: TBytes; constref Chunk: TPngChunk; Image: TImage);
var
  Keyword: string;
  Rest: PtrInt;
  Text: TBytes;
  Limit: PtrInt;
begin
  Limit := Chunk.DataOffset + Chunk.DataLength;
  if not ReadKeyword(Data, Chunk, Keyword, Rest) or (Rest >= Limit) or (Data[Rest] <> 0) then
    Exit;
  if Inflate(Data, Rest + 1, Limit - Rest - 1, MaximumTextSize, Text) then
    Image.Metadata.SetValue(Keyword, Latin1ToUtf8(BytesToText(Text)));
end;

procedure ReadInternationalText(const Data: TBytes; constref Chunk: TPngChunk; Image: TImage);
var
  Keyword: string;
  Rest: PtrInt;
  Limit: PtrInt;
  Compressed: Boolean;
  LanguageEnd: PtrInt;
  TranslatedEnd: PtrInt;
  Text: TBytes;
begin
  Limit := Chunk.DataOffset + Chunk.DataLength;
  if not ReadKeyword(Data, Chunk, Keyword, Rest) or (Rest + 2 > Limit) then
    Exit;
  Compressed := Data[Rest] <> 0;
  if Compressed and (Data[Rest + 1] <> 0) then
    Exit;
  LanguageEnd := FindZero(Data, Rest + 2, Limit);
  if LanguageEnd < 0 then
    Exit;
  TranslatedEnd := FindZero(Data, LanguageEnd + 1, Limit);
  if TranslatedEnd < 0 then
    Exit;
  Rest := TranslatedEnd + 1;
  if Compressed then
  begin
    if not Inflate(Data, Rest, Limit - Rest, MaximumTextSize, Text) then
      Exit;
    Image.Metadata.SetValue(Keyword, BytesToText(Text));
  end
  else
    Image.Metadata.SetValue(Keyword, BytesAsText(Data, Rest, Limit - Rest));
end;

procedure ReadPhysicalSize(const Data: TBytes; constref Chunk: TPngChunk; Image: TImage);
var
  Horizontal: LongWord;
  Vertical: LongWord;
begin
  if Chunk.DataLength <> 9 then
    Exit;
  Horizontal := ChunkLong(Data, Chunk, 0);
  Vertical := ChunkLong(Data, Chunk, 4);
  if (ChunkByte(Data, Chunk, 8) = 1) and (Horizontal > 0) and (Vertical > 0) then
    Image.Resolution := MakeResolution(Horizontal * PngMetresPerInch, Vertical * PngMetresPerInch);
end;

procedure ReadIccProfile(const Data: TBytes; constref Chunk: TPngChunk; Image: TImage);
var
  Name: string;
  Rest: PtrInt;
  Limit: PtrInt;
  Profile: TBytes;
begin
  Limit := Chunk.DataOffset + Chunk.DataLength;
  if not ReadKeyword(Data, Chunk, Name, Rest) or (Rest >= Limit) or (Data[Rest] <> 0) then
    Exit;
  if Inflate(Data, Rest + 1, Limit - Rest - 1, MaximumProfileSize, Profile) then
    Image.IccProfile := Profile;
end;

function FixedPoint(Value: LongWord): string;
begin
  Result := FormatFloat('0.00000', Value / 100000, NumberFormat);
end;

procedure ReadGamma(const Data: TBytes; constref Chunk: TPngChunk; Image: TImage);
begin
  if Chunk.DataLength = 4 then
    Image.Metadata.SetValue(MetadataKeyGamma, FixedPoint(ChunkLong(Data, Chunk, 0)));
end;

procedure ReadChromaticities(const Data: TBytes; constref Chunk: TPngChunk; Image: TImage);
var
  Index: LongInt;
  Text: string;
begin
  if Chunk.DataLength <> 32 then
    Exit;
  Text := '';
  for Index := 0 to 7 do
  begin
    if Index > 0 then
      Text := Text + ' ';
    Text := Text + FixedPoint(ChunkLong(Data, Chunk, 4 * Index));
  end;
  Image.Metadata.SetValue(MetadataKeyChromaticities, Text);
end;

procedure ReadStandardRgb(const Data: TBytes; constref Chunk: TPngChunk; Image: TImage);
var
  Intent: Byte;
begin
  if Chunk.DataLength <> 1 then
    Exit;
  Intent := ChunkByte(Data, Chunk, 0);
  Image.Metadata.SetValue(MetadataKeyColorSpace, 'sRGB');
  if Intent <= High(RenderingIntentNames) then
    Image.Metadata.SetValue(MetadataKeyRenderingIntent, RenderingIntentNames[Intent]);
end;

procedure ReadTime(const Data: TBytes; constref Chunk: TPngChunk; Image: TImage);
begin
  if Chunk.DataLength <> 7 then
    Exit;
  Image.Metadata.SetValue(MetadataKeyModificationTime, Format('%.4d-%.2d-%.2d %.2d:%.2d:%.2d',
    [ChunkWord(Data, Chunk, 0), ChunkByte(Data, Chunk, 2), ChunkByte(Data, Chunk, 3), ChunkByte(Data, Chunk, 4),
     ChunkByte(Data, Chunk, 5), ChunkByte(Data, Chunk, 6)]));
end;

procedure ReadExif(const Data: TBytes; constref Chunk: TPngChunk; Image: TImage);
var
  Orientation: LongInt;
begin
  Orientation := ReadTiffOrientation(Data, Chunk.DataOffset, Chunk.DataLength);
  if Orientation <> 0 then
    Image.Orientation := OrientationFromExif(Orientation);
end;

function ReadAncillaryChunk(const Data: TBytes; constref Chunk: TPngChunk; Image: TImage): Boolean;
begin
  Result := True;
  case Chunk.ChunkType of
    PngChunkText: ReadText(Data, Chunk, Image);
    PngChunkCompressedText: ReadCompressedText(Data, Chunk, Image);
    PngChunkInternationalText: ReadInternationalText(Data, Chunk, Image);
    PngChunkPhysicalSize: ReadPhysicalSize(Data, Chunk, Image);
    PngChunkIccProfile: ReadIccProfile(Data, Chunk, Image);
    PngChunkGamma: ReadGamma(Data, Chunk, Image);
    PngChunkChromaticities: ReadChromaticities(Data, Chunk, Image);
    PngChunkStandardRgb: ReadStandardRgb(Data, Chunk, Image);
    PngChunkTime: ReadTime(Data, Chunk, Image);
    PngChunkExif: ReadExif(Data, Chunk, Image);
  else
    Result := False;
  end;
end;

initialization
  NumberFormat := DefaultFormatSettings;
  NumberFormat.DecimalSeparator := '.';
end.
