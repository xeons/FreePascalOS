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
  Decoding a JPEG file, start to end.

  The markers are read in turn (Image.Jpeg.Markers); each scan's
  entropy coded data follows its SOS header and runs to the next
  marker. Sequential frames are decoded into samples scan by scan
  (Image.Jpeg.Baseline), progressive ones into coefficients
  (Image.Jpeg.Progressive) turned into samples after the last scan.
  Then every line of the picture is brought up to full size in each
  component (Image.Jpeg.Upsampling) and converted to colours
  (Image.Jpeg.Color).

  The colour space: one component is grey; three are YCbCr unless an
  Adobe segment says there is no transform, or there is neither a JFIF
  nor an Adobe segment and the components are called R, G and B; four
  are CMYK, or YCCK when the Adobe segment says so. A container that
  knows better (TIFF's photometric interpretation) can force three
  components to be YCbCr or RGB (DecodeJpegImageWithTransform).

  A file that ends early, or whose data breaks off, keeps what was
  decoded (blocks not reached are mid grey) as long as the frame header
  and the start of a scan were read; with less it is ImageErrorTruncated.
  A broken segment after the first scan also ends the decoding there,
  and so does a thousandth scan.

  Besides the pixels: the EXIF orientation (the pixels are not turned),
  the JFIF density as the resolution, the ICC profile put together from
  its APP2 chunks (only when every chunk is there), the comment and
  'ColorSpace' in the metadata.
}
unit Image.Jpeg.Decoder;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  SysUtils,
  Image.Errors,
  Image.Model;

type
  { How three-component data is turned into colours: as the file says
    (JFIF, Adobe segment, component names), or as a container that
    knows better says (TIFF's photometric interpretation). }
  TJpegColorTransform = (JpegTransformAutomatic, JpegTransformYCbCr, JpegTransformNone);

{ Data's JPEG file as an image. }
function DecodeJpegImage(const Data: TBytes): TImage;
{ The same, with the colour transform of three components forced. }
function DecodeJpegImageWithTransform(const Data: TBytes; Transform: TJpegColorTransform): TImage;

implementation

uses
  Image.Metadata,
  Image.Jpeg.Huffman,
  Image.Jpeg.Frames,
  Image.Jpeg.Markers,
  Image.Jpeg.Baseline,
  Image.Jpeg.Progressive,
  Image.Jpeg.Upsampling,
  Image.Jpeg.Color;

const
  { More scans than any encoder writes: a file of nothing but scan
    headers must not walk the picture over and over for ever. }
  MaximumScans = 1000;

type
  TJpegColorSpace = (JpegGrey, JpegYCbCr, JpegRgb, JpegCmyk, JpegYcck);

const
  ColorSpaceNames: array[TJpegColorSpace] of string = ('Grey', 'YCbCr', 'RGB', 'CMYK', 'YCCK');

{ The position of the next marker's code (after its $FF and any fill
  bytes) at or after Position, or the data's size. }
function FindMarker(const Data: TBytes; Position: PtrInt): PtrInt;
var
  Size: PtrInt;
  Next: Byte;
begin
  Size := Length(Data);
  while Position + 1 < Size do
  begin
    if Data[Position] = $FF then
    begin
      Next := Data[Position + 1];
      if (Next <> 0) and (Next <> $FF) and not ((Next >= MarkerRestartFirst) and (Next <= MarkerRestartLast)) then
        Exit(Position + 1);
    end;
    Inc(Position);
  end;
  Result := Size;
end;

procedure AllocateComponents(State: TJpegState);
var
  Index: LongInt;
  SampleCount: PtrInt;
begin
  for Index := 0 to State.Frame.ComponentCount - 1 do
    with State.Frame.Components[Index] do
    begin
      SampleCount := PtrInt(StoredBlocksPerLine) * 8 * PtrInt(StoredBlocksPerColumn) * 8;
      SetLength(Plane, SampleCount);
      FillChar(Plane[0], SampleCount, 128);
      if State.Frame.Progressive then
        SetLength(Coefficients, SampleCount);
    end;
end;

function ChooseColorSpace(State: TJpegState; Transform: TJpegColorTransform): TJpegColorSpace;
begin
  case State.Frame.ComponentCount of
    1:
      Result := JpegGrey;
    3:
      if Transform = JpegTransformYCbCr then
        Result := JpegYCbCr
      else if Transform = JpegTransformNone then
        Result := JpegRgb
      else if State.HasAdobe then
      begin
        if State.AdobeTransform = 0 then
          Result := JpegRgb
        else
          Result := JpegYCbCr;
      end
      else if (not State.HasJfif) and (State.Frame.Components[0].Identifier = Ord('R')) and
        (State.Frame.Components[1].Identifier = Ord('G')) and (State.Frame.Components[2].Identifier = Ord('B')) then
        Result := JpegRgb
      else
        Result := JpegYCbCr;
  else
    if State.HasAdobe and (State.AdobeTransform = 2) then
      Result := JpegYcck
    else
      Result := JpegCmyk;
  end;
end;

procedure ProduceColors(State: TJpegState; Image: TImage; Transform: TJpegColorTransform);
var
  ColorSpace: TJpegColorSpace;
  Buffers: array[0..JpegMaximumComponents - 1] of TBytes;
  Lines: array[0..JpegMaximumComponents - 1] of PByte;
  Index: LongInt;
  Y: LongInt;
  Width: LongInt;
begin
  ColorSpace := ChooseColorSpace(State, Transform);
  Image.Metadata.SetValue(MetadataKeyColorSpace, ColorSpaceNames[ColorSpace]);
  for Index := 0 to State.Frame.ComponentCount - 1 do
    SetLength(Buffers[Index], UpsampleBufferSize(State.Frame));
  Width := State.Frame.Width;
  for Y := 0 to State.Frame.Height - 1 do
  begin
    for Index := 0 to State.Frame.ComponentCount - 1 do
      Lines[Index] := UpsampleLine(State.Frame, State.Frame.Components[Index], Y, @Buffers[Index][0]);
    case ColorSpace of
      JpegGrey: ConvertGreyLine(Lines[0], Image.Line(Y), Width);
      JpegYCbCr: ConvertYCbCrLine(Lines[0], Lines[1], Lines[2], Image.Line(Y), Width);
      JpegRgb: ConvertRgbLine(Lines[0], Lines[1], Lines[2], Image.Line(Y), Width);
      JpegCmyk: ConvertCmykLine(Lines[0], Lines[1], Lines[2], Lines[3], Image.Line(Y), Width, State.HasAdobe);
      JpegYcck: ConvertYcckLine(Lines[0], Lines[1], Lines[2], Lines[3], Image.Line(Y), Width);
    end;
  end;
end;

function JoinIccChunks(State: TJpegState): TBytes;
var
  Index: LongInt;
  Size: PtrInt;
  Offset: PtrInt;
begin
  Result := nil;
  Size := 0;
  for Index := 0 to Length(State.IccChunks) - 1 do
  begin
    if not State.IccChunks[Index].Present then
      Exit;
    Inc(Size, Length(State.IccChunks[Index].Data));
  end;
  SetLength(Result, Size);
  Offset := 0;
  for Index := 0 to Length(State.IccChunks) - 1 do
    if Length(State.IccChunks[Index].Data) > 0 then
    begin
      Move(State.IccChunks[Index].Data[0], Result[Offset], Length(State.IccChunks[Index].Data));
      Inc(Offset, Length(State.IccChunks[Index].Data));
    end;
end;

procedure SetProperties(State: TJpegState; Image: TImage; const Comment: string);
begin
  Image.SourceFormatName := 'JPEG';
  Image.SourceBitsPerPixel := 8 * State.Frame.ComponentCount;
  Image.SourceHasAlpha := False;
  Image.Orientation := OrientationFromExif(State.ExifOrientation);
  if State.HasJfif and (State.HorizontalDensity > 0) and (State.VerticalDensity > 0) then
    case State.DensityUnits of
      1: Image.Resolution := MakeResolution(State.HorizontalDensity, State.VerticalDensity);
      2: Image.Resolution := MakeResolution(State.HorizontalDensity * 2.54, State.VerticalDensity * 2.54);
    end;
  Image.IccProfile := JoinIccChunks(State);
  if Comment <> '' then
    Image.Metadata.SetValue(MetadataKeyComment, Comment);
end;

function SegmentText(const Data: TBytes; Start, Count: PtrInt): string;
begin
  Result := '';
  SetLength(Result, Count);
  if Count > 0 then
    Move(Data[Start], Result[1], Count);
  while (Result <> '') and (Result[Length(Result)] = #0) do
    SetLength(Result, Length(Result) - 1);
end;

procedure DecodeScan(State: TJpegState; Start, Count: PtrInt; var Position: PtrInt);
var
  Scan: TJpegScan;
  Reader: TJpegBitReader;
begin
  if State.ScansDecoded >= MaximumScans then
    RaiseImageError(ImageErrorMalformed, 'too many scans');
  ReadScanHeader(State, Start, Count, Scan);
  if State.ScansDecoded = 0 then
    AllocateComponents(State);
  StartBitReader(Reader, @State.Data[0], Length(State.Data), Start + Count);
  if State.Frame.Progressive then
    DecodeProgressiveScan(State, Scan, Reader)
  else
    DecodeSequentialScan(State, Scan, Reader);
  Inc(State.ScansDecoded);
  Position := Reader.Position;
end;

{ Reads one segment (Marker's, payload Start and Count). }
procedure ReadSegment(State: TJpegState; Marker: Byte; Start, Count: PtrInt; var Position: PtrInt;
  var Comment: string);
begin
  case Marker of
    MarkerStartOfFrameBaseline, MarkerStartOfFrameExtended, MarkerStartOfFrameProgressive:
      ReadFrameHeader(State, Marker, Start, Count);
    MarkerDefineHuffmanTables:
      ReadHuffmanTables(State, Start, Count);
    MarkerDefineQuantizationTables:
      ReadQuantizationTables(State, Start, Count);
    MarkerDefineRestartInterval:
      ReadRestartInterval(State, Start, Count);
    MarkerStartOfScan:
      DecodeScan(State, Start, Count, Position);
    MarkerComment:
      if Comment = '' then
        Comment := SegmentText(State.Data, Start, Count);
    MarkerApplicationFirst..MarkerApplicationLast:
      ReadApplicationSegment(State, Marker, Start, Count);
  else
    if IsUnsupportedFrameMarker(Marker) then
      RaiseImageError(ImageErrorUnsupported, 'lossless, hierarchical or arithmetic coded JPEG');
  end;
end;

procedure ReadMarkers(State: TJpegState; var Comment: string);
var
  Data: TBytes;
  Size: PtrInt;
  Position: PtrInt;
  Marker: Byte;
  SegmentLength: LongInt;
  Start: PtrInt;
  Count: PtrInt;
begin
  Data := State.Data;
  Size := Length(Data);
  Position := 2;
  while True do
  begin
    Position := FindMarker(Data, Position);
    if Position >= Size then
    begin
      State.DataEnded := True;
      Exit;
    end;
    Marker := Data[Position];
    Inc(Position);
    if Marker = MarkerEndOfImage then
      Exit;
    if (Marker = MarkerStartOfImage) or (Marker = $01) then
      Continue;
    if Position + 2 > Size then
    begin
      State.DataEnded := True;
      Exit;
    end;
    SegmentLength := (Data[Position] shl 8) or Data[Position + 1];
    if SegmentLength < 2 then
      RaiseImageError(ImageErrorMalformed, 'segment length');
    Start := Position + 2;
    Count := SegmentLength - 2;
    if Start + Count > Size then
    begin
      State.DataEnded := True;
      Exit;
    end;
    Position := Start + Count;
    if State.ScansDecoded = 0 then
      ReadSegment(State, Marker, Start, Count, Position, Comment)
    else
      try
        ReadSegment(State, Marker, Start, Count, Position, Comment);
      except
        on EImageError do
        begin
          State.DataEnded := True;
          Exit;
        end;
      end;
  end;
end;

function DecodeJpegImage(const Data: TBytes): TImage;
begin
  Result := DecodeJpegImageWithTransform(Data, JpegTransformAutomatic);
end;

function DecodeJpegImageWithTransform(const Data: TBytes; Transform: TJpegColorTransform): TImage;
var
  State: TJpegState;
  Comment: string;
  Image: TImage;
begin
  if (Length(Data) < 3) or (Data[0] <> $FF) or (Data[1] <> MarkerStartOfImage) then
    RaiseImageError(ImageErrorUnknownFormat, 'not a JPEG file');
  Comment := '';
  State := TJpegState.Create;
  try
    State.Data := Data;
    ReadMarkers(State, Comment);
    if not State.Frame.Defined then
      RaiseImageError(ImageErrorTruncated, 'no frame');
    if State.ScansDecoded = 0 then
      RaiseImageError(ImageErrorTruncated, 'no scan');
    if State.Frame.Progressive then
      FinishProgressiveFrame(State);
    Image := TImage.Create(State.Frame.Width, State.Frame.Height);
    try
      ProduceColors(State, Image, Transform);
      SetProperties(State, Image, Comment);
    except
      Image.Free;
      raise;
    end;
    Result := Image;
  finally
    State.Free;
  end;
end;

end.
