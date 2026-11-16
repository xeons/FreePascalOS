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
  What the PNG writer says beside the pixels, the reverse of
  Image.Png.Ancillary:

    the ICC profile        iCCP ('ICC Profile', zlib)
    'ColorSpace' sRGB      sRGB (with 'RenderingIntent')
    the resolution         pHYs, in pixels per metre
    the orientation        eXIf, a TIFF structure of one entry
    the metadata           tEXt, or iTXt when the text is not ASCII

  Metadata keys that are not PNG keywords (1 to 79 printable ASCII
  characters, no space at either end), and those the decoders work
  out themselves ('ColorSpace', 'Gamma', 'Chromaticities',
  'RenderingIntent', 'ModificationTime', hotspots, page counts), are
  not written as text.
}
unit Image.Png.MetadataWriting;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Image.Model,
  Image.ByteWriters;

{ The chunks that go before the image data. }
procedure WriteMetadataChunks(Writer: TImageByteWriter; Image: TImage);

implementation

uses
  Image.Metadata,
  Image.Png.Chunks,
  Image.Png.Ancillary,
  Compression.Buffers;

const
  ProfileName = 'ICC Profile';
  DerivedKeys: array[0..7] of string = (MetadataKeyColorSpace, MetadataKeyGamma, MetadataKeyChromaticities,
    MetadataKeyRenderingIntent, MetadataKeyModificationTime, MetadataKeyHotspotX, MetadataKeyHotspotY,
    MetadataKeyPageCount);
  RenderingIntentNames: array[0..3] of string = ('Perceptual', 'RelativeColorimetric', 'Saturation',
    'AbsoluteColorimetric');
  OrientationTag = $0112;
  ShortType = 3;

procedure AppendText(var Payload: TBytes; const Text: RawByteString);
var
  Start: PtrInt;
begin
  if Text = '' then
    Exit;
  Start := Length(Payload);
  SetLength(Payload, Start + Length(Text));
  Move(Text[1], Payload[Start], Length(Text));
end;

procedure AppendByte(var Payload: TBytes; Value: Byte);
begin
  SetLength(Payload, Length(Payload) + 1);
  Payload[High(Payload)] := Value;
end;

procedure AppendBytes(var Payload: TBytes; const Bytes: TBytes);
var
  Start: PtrInt;
begin
  if Length(Bytes) = 0 then
    Exit;
  Start := Length(Payload);
  SetLength(Payload, Start + Length(Bytes));
  Move(Bytes[0], Payload[Start], Length(Bytes));
end;

function IsAscii(const Text: string): Boolean;
var
  Index: LongInt;
begin
  for Index := 1 to Length(Text) do
    if Ord(Text[Index]) >= $80 then
      Exit(False);
  Result := True;
end;

function IsKeyword(const Key: string): Boolean;
var
  Index: LongInt;
begin
  if (Length(Key) < 1) or (Length(Key) > 79) or (Key[1] = ' ') or (Key[Length(Key)] = ' ') then
    Exit(False);
  for Index := 1 to Length(Key) do
    if (Ord(Key[Index]) < 32) or (Ord(Key[Index]) > 126) then
      Exit(False);
  Result := True;
end;

function IsDerivedKey(const Key: string): Boolean;
var
  Index: LongInt;
begin
  for Index := 0 to High(DerivedKeys) do
    if SameText(Key, DerivedKeys[Index]) then
      Exit(True);
  Result := False;
end;

procedure WriteTextChunk(Writer: TImageByteWriter; const Key, Value: string);
var
  Payload: TBytes;
begin
  Payload := nil;
  AppendText(Payload, Key);
  AppendByte(Payload, 0);
  if IsAscii(Value) then
  begin
    AppendText(Payload, Value);
    WritePngChunkBytes(Writer, PngChunkText, Payload);
  end
  else
  begin
    { Not compressed, no language, no translated keyword. }
    AppendByte(Payload, 0);
    AppendByte(Payload, 0);
    AppendByte(Payload, 0);
    AppendByte(Payload, 0);
    AppendText(Payload, Value);
    WritePngChunkBytes(Writer, PngChunkInternationalText, Payload);
  end;
end;

procedure WriteTexts(Writer: TImageByteWriter; Metadata: TImageMetadata);
var
  Index: LongInt;
begin
  for Index := 0 to Metadata.Count - 1 do
    if IsKeyword(Metadata.Keys[Index]) and not IsDerivedKey(Metadata.Keys[Index]) then
      WriteTextChunk(Writer, Metadata.Keys[Index], Metadata.Values[Index]);
end;

procedure WriteProfile(Writer: TImageByteWriter; const Profile: TBytes);
var
  Payload: TBytes;
begin
  Payload := nil;
  AppendText(Payload, ProfileName);
  AppendByte(Payload, 0);
  AppendByte(Payload, 0);
  AppendBytes(Payload, CompressZlib(Profile));
  WritePngChunkBytes(Writer, PngChunkIccProfile, Payload);
end;

procedure WriteStandardRgb(Writer: TImageByteWriter; Metadata: TImageMetadata);
var
  Intent: Byte;
  Index: LongInt;
begin
  Intent := 0;
  for Index := 0 to High(RenderingIntentNames) do
    if SameText(Metadata.GetValue(MetadataKeyRenderingIntent), RenderingIntentNames[Index]) then
      Intent := Index;
  WritePngChunk(Writer, PngChunkStandardRgb, @Intent, 1);
end;

procedure PutLongBig(var Payload: TBytes; Offset: PtrInt; Value: LongWord);
begin
  Payload[Offset] := Value shr 24;
  Payload[Offset + 1] := (Value shr 16) and $FF;
  Payload[Offset + 2] := (Value shr 8) and $FF;
  Payload[Offset + 3] := Value and $FF;
end;

procedure WritePhysicalSize(Writer: TImageByteWriter; constref Resolution: TImageResolution);
var
  Payload: TBytes;
  Vertical: Double;
begin
  Vertical := Resolution.VerticalDpi;
  if Vertical <= 0 then
    Vertical := Resolution.HorizontalDpi;
  Payload := nil;
  SetLength(Payload, 9);
  PutLongBig(Payload, 0, Round(Resolution.HorizontalDpi / PngMetresPerInch));
  PutLongBig(Payload, 4, Round(Vertical / PngMetresPerInch));
  Payload[8] := 1;
  WritePngChunkBytes(Writer, PngChunkPhysicalSize, Payload);
end;

{ A big-endian TIFF structure: the header, then one directory of one
  entry, the orientation. }
procedure WriteExif(Writer: TImageByteWriter; Orientation: TImageOrientation);
var
  Payload: TBytes;
begin
  Payload := nil;
  SetLength(Payload, 26);
  FillChar(Payload[0], Length(Payload), 0);
  Payload[0] := Ord('M');
  Payload[1] := Ord('M');
  Payload[3] := 42;
  PutLongBig(Payload, 4, 8);
  Payload[9] := 1;
  Payload[10] := OrientationTag shr 8;
  Payload[11] := OrientationTag and $FF;
  Payload[13] := ShortType;
  PutLongBig(Payload, 14, 1);
  Payload[19] := OrientationToExif(Orientation);
  WritePngChunkBytes(Writer, PngChunkExif, Payload);
end;

procedure WriteMetadataChunks(Writer: TImageByteWriter; Image: TImage);
begin
  if Length(Image.IccProfile) > 0 then
    WriteProfile(Writer, Image.IccProfile)
  else if SameText(Image.Metadata.GetValue(MetadataKeyColorSpace), 'sRGB') then
    WriteStandardRgb(Writer, Image.Metadata);
  if Image.Resolution.HorizontalDpi > 0 then
    WritePhysicalSize(Writer, Image.Resolution);
  if Image.Orientation <> OrientationNormal then
    WriteExif(Writer, Image.Orientation);
  WriteTexts(Writer, Image.Metadata);
end;

end.
