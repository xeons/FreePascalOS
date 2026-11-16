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
  A JPEG's marker segments, read into the decoding's state: DQT
  (quantization tables, 8 or 16 bit), DHT (Huffman tables), SOF0, SOF1
  and SOF2 (the frame: 8-bit precision, one, three or four components
  with sampling factors 1 to 4), SOS (a scan's components, spectral
  selection and successive approximation), DRI (the restart interval)
  and the application segments: APP0 JFIF (density), APP1 EXIF
  (orientation, Image.Jpeg.Exif), APP2 ICC_PROFILE (the profile's
  chunks, put together in order by the decoder) and APP14 Adobe (the
  colour transform).

  Each routine is given the segment's payload (after its length) as
  Start and Count in the state's data, and reads nothing outside it;
  what breaks the rules raises EImageError (ImageErrorMalformed, or
  ImageErrorUnsupported for what is valid but not decoded: 12-bit
  samples, two components, a height given only later by DNL).

  The frame header also works out the geometry: each component's size,
  the MCUs, the blocks a scan covers and the blocks kept (whole MCUs).
}
unit Image.Jpeg.Markers;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Image.Errors,
  Image.Model,
  Image.Jpeg.Huffman,
  Image.Jpeg.Frames,
  Image.Jpeg.Exif;

const
  MarkerStartOfFrameBaseline = $C0;
  MarkerStartOfFrameExtended = $C1;
  MarkerStartOfFrameProgressive = $C2;
  MarkerDefineHuffmanTables = $C4;
  MarkerDefineArithmeticConditioning = $CC;
  MarkerRestartFirst = $D0;
  MarkerRestartLast = $D7;
  MarkerStartOfImage = $D8;
  MarkerEndOfImage = $D9;
  MarkerStartOfScan = $DA;
  MarkerDefineQuantizationTables = $DB;
  MarkerDefineNumberOfLines = $DC;
  MarkerDefineRestartInterval = $DD;
  MarkerApplicationFirst = $E0;
  MarkerApplicationLast = $EF;
  MarkerComment = $FE;

procedure ReadQuantizationTables(State: TJpegState; Start, Count: PtrInt);
procedure ReadHuffmanTables(State: TJpegState; Start, Count: PtrInt);
procedure ReadFrameHeader(State: TJpegState; Marker: Byte; Start, Count: PtrInt);
procedure ReadScanHeader(State: TJpegState; Start, Count: PtrInt; out Scan: TJpegScan);
procedure ReadRestartInterval(State: TJpegState; Start, Count: PtrInt);
procedure ReadApplicationSegment(State: TJpegState; Marker: Byte; Start, Count: PtrInt);
{ True for the SOF markers of frames this decoder does not decode
  (lossless, hierarchical, arithmetic coding). }
function IsUnsupportedFrameMarker(Marker: Byte): Boolean;

implementation

procedure Malformed(const Detail: string);
begin
  RaiseImageError(ImageErrorMalformed, Detail);
end;

function ByteAt(State: TJpegState; Start, Count, Offset: PtrInt): LongInt;
begin
  if (Offset < 0) or (Offset >= Count) then
    Malformed('segment too short');
  Result := State.Data[Start + Offset];
end;

function WordAt(State: TJpegState; Start, Count, Offset: PtrInt): LongInt;
begin
  Result := (ByteAt(State, Start, Count, Offset) shl 8) or ByteAt(State, Start, Count, Offset + 1);
end;

function IsUnsupportedFrameMarker(Marker: Byte): Boolean;
begin
  Result := Marker in [$C3, $C5, $C6, $C7, $C9, $CA, $CB, $CD, $CE, $CF];
end;

procedure ReadQuantizationTables(State: TJpegState; Start, Count: PtrInt);
var
  Offset: PtrInt;
  Header: LongInt;
  Precision: LongInt;
  TableIndex: LongInt;
  Index: LongInt;
  Value: LongInt;
begin
  Offset := 0;
  while Offset < Count do
  begin
    Header := ByteAt(State, Start, Count, Offset);
    Inc(Offset);
    Precision := Header shr 4;
    TableIndex := Header and 15;
    if (Precision > 1) or (TableIndex > 3) then
      Malformed('quantization table');
    for Index := 0 to 63 do
    begin
      if Precision = 0 then
      begin
        Value := ByteAt(State, Start, Count, Offset);
        Inc(Offset);
      end
      else
      begin
        Value := WordAt(State, Start, Count, Offset);
        Inc(Offset, 2);
      end;
      State.QuantizationTables[TableIndex][ZigzagToNatural[Index]] := Value;
    end;
    State.QuantizationDefined[TableIndex] := True;
  end;
end;

procedure ReadHuffmanTables(State: TJpegState; Start, Count: PtrInt);
var
  Offset: PtrInt;
  Header: LongInt;
  TableClass: LongInt;
  TableIndex: LongInt;
  Counts: TJpegHuffmanCounts;
  Symbols: array[0..255] of Byte;
  Total: LongInt;
  Index: LongInt;
  Built: Boolean;
begin
  Offset := 0;
  while Offset < Count do
  begin
    Header := ByteAt(State, Start, Count, Offset);
    Inc(Offset);
    TableClass := Header shr 4;
    TableIndex := Header and 15;
    if (TableClass > 1) or (TableIndex > 3) then
      Malformed('Huffman table');
    Total := 0;
    for Index := 1 to 16 do
    begin
      Counts[Index] := ByteAt(State, Start, Count, Offset);
      Inc(Offset);
      Inc(Total, Counts[Index]);
    end;
    if Total > 256 then
      Malformed('Huffman table too large');
    FillChar(Symbols, SizeOf(Symbols), 0);
    for Index := 0 to Total - 1 do
    begin
      Symbols[Index] := ByteAt(State, Start, Count, Offset);
      Inc(Offset);
    end;
    if TableClass = 0 then
      Built := BuildHuffmanTable(State.DcTables[TableIndex], Counts, Symbols)
    else
      Built := BuildHuffmanTable(State.AcTables[TableIndex], Counts, Symbols);
    if not Built then
      Malformed('Huffman code overflows');
  end;
end;

function DivideRoundingUp(Value, Divisor: LongInt): LongInt;
begin
  Result := (Value + Divisor - 1) div Divisor;
end;

procedure WorkOutGeometry(var Frame: TJpegFrame);
var
  Index: LongInt;
begin
  Frame.MaximumHorizontalFactor := 1;
  Frame.MaximumVerticalFactor := 1;
  for Index := 0 to Frame.ComponentCount - 1 do
  begin
    if Frame.Components[Index].HorizontalFactor > Frame.MaximumHorizontalFactor then
      Frame.MaximumHorizontalFactor := Frame.Components[Index].HorizontalFactor;
    if Frame.Components[Index].VerticalFactor > Frame.MaximumVerticalFactor then
      Frame.MaximumVerticalFactor := Frame.Components[Index].VerticalFactor;
  end;
  Frame.McusPerLine := DivideRoundingUp(Frame.Width, 8 * Frame.MaximumHorizontalFactor);
  Frame.McusPerColumn := DivideRoundingUp(Frame.Height, 8 * Frame.MaximumVerticalFactor);
  for Index := 0 to Frame.ComponentCount - 1 do
    with Frame.Components[Index] do
    begin
      Width := DivideRoundingUp(Frame.Width * HorizontalFactor, Frame.MaximumHorizontalFactor);
      Height := DivideRoundingUp(Frame.Height * VerticalFactor, Frame.MaximumVerticalFactor);
      BlocksPerLine := DivideRoundingUp(Width, 8);
      BlocksPerColumn := DivideRoundingUp(Height, 8);
      StoredBlocksPerLine := Frame.McusPerLine * HorizontalFactor;
      StoredBlocksPerColumn := Frame.McusPerColumn * VerticalFactor;
      if StoredBlocksPerLine < BlocksPerLine then
        StoredBlocksPerLine := BlocksPerLine;
      if StoredBlocksPerColumn < BlocksPerColumn then
        StoredBlocksPerColumn := BlocksPerColumn;
      PlaneStride := StoredBlocksPerLine * 8;
    end;
end;

procedure ReadFrameHeader(State: TJpegState; Marker: Byte; Start, Count: PtrInt);
var
  Frame: TJpegFrame;
  Precision: LongInt;
  Index: LongInt;
  Other: LongInt;
  Factors: LongInt;
begin
  if State.Frame.Defined then
    Malformed('a second frame');
  Frame := Default(TJpegFrame);
  Precision := ByteAt(State, Start, Count, 0);
  Frame.Height := WordAt(State, Start, Count, 1);
  Frame.Width := WordAt(State, Start, Count, 3);
  Frame.ComponentCount := ByteAt(State, Start, Count, 5);
  Frame.Progressive := Marker = MarkerStartOfFrameProgressive;
  if Precision <> 8 then
    RaiseImageError(ImageErrorUnsupported, IntToStr(Precision) + '-bit samples');
  if Frame.Width = 0 then
    Malformed('no width');
  if Frame.Height = 0 then
    RaiseImageError(ImageErrorUnsupported, 'height given by DNL');
  if not (Frame.ComponentCount in [1, 3, 4]) then
    RaiseImageError(ImageErrorUnsupported, IntToStr(Frame.ComponentCount) + ' components');
  if Count < 6 + 3 * Frame.ComponentCount then
    Malformed('frame header too short');
  CheckImageSize(Frame.Width, Frame.Height);
  for Index := 0 to Frame.ComponentCount - 1 do
    with Frame.Components[Index] do
    begin
      Identifier := ByteAt(State, Start, Count, 6 + 3 * Index);
      Factors := ByteAt(State, Start, Count, 7 + 3 * Index);
      HorizontalFactor := Factors shr 4;
      VerticalFactor := Factors and 15;
      QuantizationIndex := ByteAt(State, Start, Count, 8 + 3 * Index);
      if (HorizontalFactor < 1) or (HorizontalFactor > 4) or (VerticalFactor < 1) or (VerticalFactor > 4) then
        Malformed('sampling factors');
      if QuantizationIndex > 3 then
        Malformed('quantization table index');
      for Other := 0 to Index - 1 do
        if Frame.Components[Other].Identifier = Identifier then
          Malformed('two components with one identifier');
    end;
  { A single component is never interleaved: its MCU is one block. }
  if Frame.ComponentCount = 1 then
  begin
    Frame.Components[0].HorizontalFactor := 1;
    Frame.Components[0].VerticalFactor := 1;
  end;
  WorkOutGeometry(Frame);
  Frame.Defined := True;
  State.Frame := Frame;
end;

procedure ReadScanHeader(State: TJpegState; Start, Count: PtrInt; out Scan: TJpegScan);
var
  Index: LongInt;
  Other: LongInt;
  Identifier: LongInt;
  Tables: LongInt;
  ComponentIndex: LongInt;
  Approximation: LongInt;
begin
  Scan := Default(TJpegScan);
  if not State.Frame.Defined then
    Malformed('a scan before the frame');
  Scan.ComponentCount := ByteAt(State, Start, Count, 0);
  if (Scan.ComponentCount < 1) or (Scan.ComponentCount > State.Frame.ComponentCount) then
    Malformed('scan components');
  if Count < 4 + 2 * Scan.ComponentCount then
    Malformed('scan header too short');
  for Index := 0 to Scan.ComponentCount - 1 do
  begin
    Identifier := ByteAt(State, Start, Count, 1 + 2 * Index);
    Tables := ByteAt(State, Start, Count, 2 + 2 * Index);
    ComponentIndex := -1;
    for Other := 0 to State.Frame.ComponentCount - 1 do
      if State.Frame.Components[Other].Identifier = Identifier then
        ComponentIndex := Other;
    if ComponentIndex < 0 then
      Malformed('scan of a component not in the frame');
    for Other := 0 to Index - 1 do
      if Scan.ComponentIndices[Other] = ComponentIndex then
        Malformed('a component twice in a scan');
    if ((Tables shr 4) > 3) or ((Tables and 15) > 3) then
      Malformed('Huffman table index');
    Scan.ComponentIndices[Index] := ComponentIndex;
    State.Frame.Components[ComponentIndex].DcTableIndex := Tables shr 4;
    State.Frame.Components[ComponentIndex].AcTableIndex := Tables and 15;
  end;
  Scan.SpectralStart := ByteAt(State, Start, Count, 1 + 2 * Scan.ComponentCount);
  Scan.SpectralEnd := ByteAt(State, Start, Count, 2 + 2 * Scan.ComponentCount);
  Approximation := ByteAt(State, Start, Count, 3 + 2 * Scan.ComponentCount);
  Scan.ApproximationHigh := Approximation shr 4;
  Scan.ApproximationLow := Approximation and 15;
  if State.Frame.Progressive then
  begin
    if (Scan.SpectralStart > 63) or (Scan.SpectralEnd > 63) or (Scan.SpectralStart > Scan.SpectralEnd) or
      (Scan.ApproximationHigh > 13) or (Scan.ApproximationLow > 13) then
      Malformed('progressive scan parameters');
    if (Scan.SpectralStart = 0) and (Scan.SpectralEnd <> 0) then
      Malformed('DC and AC in one scan');
    if (Scan.SpectralStart > 0) and (Scan.ComponentCount <> 1) then
      Malformed('an AC scan of several components');
  end
  else
  begin
    Scan.SpectralStart := 0;
    Scan.SpectralEnd := 63;
    Scan.ApproximationHigh := 0;
    Scan.ApproximationLow := 0;
  end;
  { The tables the scan needs must be there. }
  for Index := 0 to Scan.ComponentCount - 1 do
    with State.Frame.Components[Scan.ComponentIndices[Index]] do
    begin
      if not State.QuantizationDefined[QuantizationIndex] then
        Malformed('no quantization table');
      if not QuantizationLatched then
      begin
        Quantization := State.QuantizationTables[QuantizationIndex];
        QuantizationLatched := True;
      end
      else if not State.Frame.Progressive then
        Quantization := State.QuantizationTables[QuantizationIndex];
      if (Scan.SpectralStart = 0) and (Scan.ApproximationHigh = 0) and not State.DcTables[DcTableIndex].Defined then
        Malformed('no DC Huffman table');
      if (Scan.SpectralEnd > 0) and not State.AcTables[AcTableIndex].Defined then
        Malformed('no AC Huffman table');
    end;
end;

procedure ReadRestartInterval(State: TJpegState; Start, Count: PtrInt);
begin
  State.RestartInterval := WordAt(State, Start, Count, 0);
end;

function SegmentStartsWith(State: TJpegState; Start, Count: PtrInt; const Text: string; WithZero: Boolean): Boolean;
var
  Index: LongInt;
  Needed: LongInt;
begin
  Needed := Length(Text);
  if WithZero then
    Inc(Needed);
  if Count < Needed then
    Exit(False);
  for Index := 1 to Length(Text) do
    if State.Data[Start + Index - 1] <> Ord(Text[Index]) then
      Exit(False);
  if WithZero and (State.Data[Start + Length(Text)] <> 0) then
    Exit(False);
  Result := True;
end;

procedure ReadIccChunk(State: TJpegState; Start, Count: PtrInt);
const
  HeaderSize = 14;
var
  Sequence: LongInt;
  Total: LongInt;
begin
  if Count < HeaderSize then
    Exit;
  Sequence := State.Data[Start + 12];
  Total := State.Data[Start + 13];
  if (Sequence < 1) or (Total < 1) or (Sequence > Total) then
    Exit;
  if Length(State.IccChunks) = 0 then
    SetLength(State.IccChunks, Total);
  if (Length(State.IccChunks) <> Total) or State.IccChunks[Sequence - 1].Present then
    Exit;
  State.IccChunks[Sequence - 1].Present := True;
  State.IccChunks[Sequence - 1].Data := Copy(State.Data, Start + HeaderSize, Count - HeaderSize);
end;

procedure ReadApplicationSegment(State: TJpegState; Marker: Byte; Start, Count: PtrInt);
begin
  case Marker of
    $E0:
      if SegmentStartsWith(State, Start, Count, 'JFIF', True) and (Count >= 12) then
      begin
        State.HasJfif := True;
        State.DensityUnits := State.Data[Start + 7];
        State.HorizontalDensity := (State.Data[Start + 8] shl 8) or State.Data[Start + 9];
        State.VerticalDensity := (State.Data[Start + 10] shl 8) or State.Data[Start + 11];
      end;
    $E1:
      if (State.ExifOrientation = 0) and SegmentStartsWith(State, Start, Count, 'Exif', True) then
        State.ExifOrientation := ReadExifOrientation(State.Data, Start, Count);
    $E2:
      if SegmentStartsWith(State, Start, Count, 'ICC_PROFILE', True) then
        ReadIccChunk(State, Start, Count);
    $EE:
      if SegmentStartsWith(State, Start, Count, 'Adobe', False) and (Count >= 12) then
      begin
        State.HasAdobe := True;
        State.AdobeTransform := State.Data[Start + 11];
      end;
  end;
end;

end.
