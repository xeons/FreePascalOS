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
  WOFF 2.0 (W3C Recommendation, 2018) unwrapped to the sfnt font it
  carries.

  The file: a 48-byte header, a table directory (each table's tag, as
  one of 63 known tags or spelled out, its length and, for a
  transformed table, the transformed length, in variable-length
  numbers), then every table one after another in a single Brotli
  stream (libcompression's TBrotliDecoder).

  Two tables may be transformed. glyf (with loca, which is then empty)
  is split into streams: contour counts, point counts, point flags,
  coordinates packed as triplets, composite glyph data, bounding boxes
  and instructions; it is put back together glyph by glyph into
  ordinary TrueType glyph data with its loca (the loca format the
  transform names, written into head as well). hmtx may leave out the
  left side bearings, which are then each glyph's xMin. Every other
  table is as it was. Collections (a "ttcf" flavour) are not read.

  The result is a font Font.TrueType opens; anything that does not add
  up (a stream running short, a length out of reason, Brotli failing)
  gives nil.
}
unit Web.Text.Woff2;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils;

{ The sfnt data of WOFF2 file Data; nil if it cannot be read. }
function UnwrapWoff2(const Data: TBytes): TBytes;

implementation

uses
  Compression.StreamingDecoders,
  Compression.BrotliDecoder;

const
  HeaderSize = 48;
  MaximumTables = 256;
  MaximumSfntBytes = 48 * 1024 * 1024;
  CollectionFlavor = $74746366;
  ArbitraryTag = 63;
  KnownTags: array[0..62] of string[4] = (
    'cmap', 'head', 'hhea', 'hmtx', 'maxp', 'name', 'OS/2', 'post', 'cvt ', 'fpgm', 'glyf', 'loca', 'prep',
    'CFF ', 'VORG', 'EBDT', 'EBLC', 'gasp', 'hdmx', 'kern', 'LTSH', 'PCLT', 'VDMX', 'vhea', 'vmtx', 'BASE',
    'GDEF', 'GPOS', 'GSUB', 'EBSC', 'JSTF', 'MATH', 'CBDT', 'CBLC', 'COLR', 'CPAL', 'SVG ', 'sbix', 'acnt',
    'avar', 'bdat', 'bloc', 'bsln', 'cvar', 'fdsc', 'feat', 'fmtx', 'fvar', 'gvar', 'hsty', 'just', 'lcar',
    'mort', 'morx', 'opbd', 'prop', 'trak', 'Zapf', 'Silf', 'Glat', 'Gloc', 'Feat', 'Sill');

  { Simple glyph flags (TrueType). }
  FlagOnCurve = $01;
  FlagXShort = $02;
  FlagYShort = $04;
  FlagXSameOrPositive = $10;
  FlagYSameOrPositive = $20;
  FlagOverlapSimple = $40;
  { Composite glyph flags. }
  ArgumentsAreWords = $0001;
  HaveScale = $0008;
  MoreComponents = $0020;
  HaveXAndYScale = $0040;
  HaveTwoByTwo = $0080;
  HaveInstructions = $0100;

type
  EWoff2 = class(Exception);

  TTableEntry = record
    Tag: string[4];
    OriginalLength: LongWord;
    TransformLength: LongWord;
    Transformed: Boolean;
    { Where it is in the decompressed stream. }
    Offset: SizeInt;
    { The table as it goes into the font. }
    Output: TBytes;
  end;

  { Reading a run of bytes, every read checked. }
  TByteStream = record
    Data: PByte;
    Size: SizeInt;
    Position: SizeInt;
  end;

  { Writing glyph data. }
  TByteBuilder = record
    Bytes: TBytes;
    Count: SizeInt;
  end;

procedure Fail;
begin
  raise EWoff2.Create('broken WOFF2 data');
end;

function MakeStream(Data: PByte; Size: SizeInt): TByteStream;
begin
  Result.Data := Data;
  Result.Size := Size;
  Result.Position := 0;
end;

function ReadU8(var Stream: TByteStream): LongWord;
begin
  if Stream.Position >= Stream.Size then
    Fail;
  Result := Stream.Data[Stream.Position];
  Inc(Stream.Position);
end;

function ReadU16(var Stream: TByteStream): LongWord;
begin
  Result := ReadU8(Stream) shl 8;
  Result := Result or ReadU8(Stream);
end;

function ReadS16(var Stream: TByteStream): LongInt;
begin
  Result := SmallInt(Word(ReadU16(Stream)));
end;

function ReadU32(var Stream: TByteStream): LongWord;
begin
  Result := ReadU16(Stream) shl 16;
  Result := Result or ReadU16(Stream);
end;

{ UIntBase128: seven bits a byte, the top bit saying more follow; at
  most five bytes, no leading zeros, no overflow. }
function ReadBase128(var Stream: TByteStream): LongWord;
var
  Index: LongInt;
  Value: QWord;
  Next: LongWord;
begin
  Value := 0;
  for Index := 1 to 5 do
  begin
    Next := ReadU8(Stream);
    if (Index = 1) and (Next = $80) then
      Fail;
    Value := (Value shl 7) or (Next and $7F);
    if Value > $FFFFFFFF then
      Fail;
    if (Next and $80) = 0 then
      Exit(LongWord(Value));
  end;
  Fail;
  Result := 0;
end;

{ 255UInt16. }
function Read255UShort(var Stream: TByteStream): LongWord;
var
  Code: LongWord;
begin
  Code := ReadU8(Stream);
  case Code of
    253: Result := ReadU16(Stream);
    255: Result := ReadU8(Stream) + 253;
    254: Result := ReadU8(Stream) + 506;
  else
    Result := Code;
  end;
end;

procedure TakeBytes(var Stream: TByteStream; Count: SizeInt; out Start: PByte);
begin
  if (Count < 0) or (Count > Stream.Size - Stream.Position) then
    Fail;
  Start := Stream.Data + Stream.Position;
  Inc(Stream.Position, Count);
end;

procedure Reserve(var Builder: TByteBuilder; Count: SizeInt);
begin
  if Builder.Count + Count > Length(Builder.Bytes) then
    SetLength(Builder.Bytes, 2 * Length(Builder.Bytes) + Count + 1024);
end;

procedure PutU8(var Builder: TByteBuilder; Value: LongWord);
begin
  Reserve(Builder, 1);
  Builder.Bytes[Builder.Count] := Byte(Value);
  Inc(Builder.Count);
end;

procedure PutU16(var Builder: TByteBuilder; Value: LongWord);
begin
  PutU8(Builder, (Value shr 8) and $FF);
  PutU8(Builder, Value and $FF);
end;

procedure PutU32(var Builder: TByteBuilder; Value: LongWord);
begin
  PutU16(Builder, Value shr 16);
  PutU16(Builder, Value and $FFFF);
end;

procedure PutBytes(var Builder: TByteBuilder; Source: PByte; Count: SizeInt);
begin
  if Count <= 0 then
    Exit;
  Reserve(Builder, Count);
  Move(Source^, Builder.Bytes[Builder.Count], Count);
  Inc(Builder.Count, Count);
end;

procedure PadTo(var Builder: TByteBuilder; Alignment: SizeInt);
begin
  while Builder.Count mod Alignment <> 0 do
    PutU8(Builder, 0);
end;

function BigEndian16(const Bytes: TBytes; Offset: SizeInt): LongWord;
begin
  if Offset + 2 > Length(Bytes) then
    Fail;
  Result := (LongWord(Bytes[Offset]) shl 8) or Bytes[Offset + 1];
end;

procedure SetBigEndian16(var Bytes: TBytes; Offset: SizeInt; Value: LongWord);
begin
  if Offset + 2 > Length(Bytes) then
    Fail;
  Bytes[Offset] := Byte(Value shr 8);
  Bytes[Offset + 1] := Byte(Value);
end;

{ --- glyf -------------------------------------------------------------- }

function WithSign(Flag: LongWord; Value: LongInt): LongInt;
begin
  if (Flag and 1) <> 0 then
    Result := Value
  else
    Result := -Value;
end;

{ A simple glyph's points from its flags and coordinate triplets. }
procedure DecodeTriplets(var Flags, Glyphs: TByteStream; PointCount: LongInt; var Xs, Ys: array of LongInt;
  var OnCurve: array of Boolean);
var
  Index: LongInt;
  Flag: LongWord;
  B0, B1, B2, B3: LongInt;
  DeltaX, DeltaY: LongInt;
  X, Y: LongInt;
begin
  X := 0;
  Y := 0;
  for Index := 0 to PointCount - 1 do
  begin
    Flag := ReadU8(Flags);
    OnCurve[Index] := (Flag shr 7) = 0;
    Flag := Flag and $7F;
    if Flag < 10 then
    begin
      B0 := ReadU8(Glyphs);
      DeltaX := 0;
      DeltaY := WithSign(Flag, LongInt((Flag and 14) shl 7) + B0);
    end
    else if Flag < 20 then
    begin
      B0 := ReadU8(Glyphs);
      DeltaX := WithSign(Flag, LongInt(((Flag - 10) and 14) shl 7) + B0);
      DeltaY := 0;
    end
    else if Flag < 84 then
    begin
      B0 := LongInt(Flag) - 20;
      B1 := ReadU8(Glyphs);
      DeltaX := WithSign(Flag, 1 + (B0 and $30) + (B1 shr 4));
      DeltaY := WithSign(Flag shr 1, 1 + ((B0 and $0C) shl 2) + (B1 and $0F));
    end
    else if Flag < 120 then
    begin
      B0 := LongInt(Flag) - 84;
      B1 := ReadU8(Glyphs);
      B2 := ReadU8(Glyphs);
      DeltaX := WithSign(Flag, 1 + ((B0 div 12) shl 8) + B1);
      DeltaY := WithSign(Flag shr 1, 1 + (((B0 mod 12) shr 2) shl 8) + B2);
    end
    else if Flag < 124 then
    begin
      B1 := ReadU8(Glyphs);
      B2 := ReadU8(Glyphs);
      B3 := ReadU8(Glyphs);
      DeltaX := WithSign(Flag, (B1 shl 4) + (B2 shr 4));
      DeltaY := WithSign(Flag shr 1, ((B2 and $0F) shl 8) + B3);
    end
    else
    begin
      B0 := ReadU8(Glyphs);
      B1 := ReadU8(Glyphs);
      B2 := ReadU8(Glyphs);
      B3 := ReadU8(Glyphs);
      DeltaX := WithSign(Flag, (B0 shl 8) + B1);
      DeltaY := WithSign(Flag shr 1, (B2 shl 8) + B3);
    end;
    X := X + DeltaX;
    Y := Y + DeltaY;
    if (Abs(X) > 32767) or (Abs(Y) > 32767) then
      Fail;
    Xs[Index] := X;
    Ys[Index] := Y;
  end;
end;

{ The points as TrueType stores them: a flag a point (short or same
  coordinates), then the x deltas, then the y deltas. }
procedure WriteSimplePoints(var Builder: TByteBuilder; PointCount: LongInt; const Xs, Ys: array of LongInt;
  const OnCurve: array of Boolean; Overlap: Boolean);
var
  Index: LongInt;
  Flag: LongWord;
  DeltaX, DeltaY: LongInt;
  PreviousX, PreviousY: LongInt;
begin
  PreviousX := 0;
  PreviousY := 0;
  for Index := 0 to PointCount - 1 do
  begin
    DeltaX := Xs[Index] - PreviousX;
    DeltaY := Ys[Index] - PreviousY;
    Flag := 0;
    if OnCurve[Index] then
      Flag := Flag or FlagOnCurve;
    if (Index = 0) and Overlap then
      Flag := Flag or FlagOverlapSimple;
    if DeltaX = 0 then
      Flag := Flag or FlagXSameOrPositive
    else if Abs(DeltaX) < 256 then
    begin
      Flag := Flag or FlagXShort;
      if DeltaX > 0 then
        Flag := Flag or FlagXSameOrPositive;
    end;
    if DeltaY = 0 then
      Flag := Flag or FlagYSameOrPositive
    else if Abs(DeltaY) < 256 then
    begin
      Flag := Flag or FlagYShort;
      if DeltaY > 0 then
        Flag := Flag or FlagYSameOrPositive;
    end;
    PutU8(Builder, Flag);
    PreviousX := Xs[Index];
    PreviousY := Ys[Index];
  end;
  PreviousX := 0;
  for Index := 0 to PointCount - 1 do
  begin
    DeltaX := Xs[Index] - PreviousX;
    if DeltaX <> 0 then
    begin
      if Abs(DeltaX) < 256 then
        PutU8(Builder, Abs(DeltaX))
      else
        PutU16(Builder, Word(SmallInt(DeltaX)));
    end;
    PreviousX := Xs[Index];
  end;
  PreviousY := 0;
  for Index := 0 to PointCount - 1 do
  begin
    DeltaY := Ys[Index] - PreviousY;
    if DeltaY <> 0 then
    begin
      if Abs(DeltaY) < 256 then
        PutU8(Builder, Abs(DeltaY))
      else
        PutU16(Builder, Word(SmallInt(DeltaY)));
    end;
    PreviousY := Ys[Index];
  end;
end;

{ A composite glyph's components from the composite stream, copied as
  they are; whether one wants instructions. }
function CopyComposite(var Composites: TByteStream; var Builder: TByteBuilder): Boolean;
var
  Flags: LongWord;
  Size: SizeInt;
  Start: PByte;
  FlagsAt: SizeInt;
begin
  Result := False;
  repeat
    FlagsAt := Composites.Position;
    Flags := ReadU16(Composites);
    Size := 2;
    if (Flags and ArgumentsAreWords) <> 0 then
      Inc(Size, 4)
    else
      Inc(Size, 2);
    if (Flags and HaveScale) <> 0 then
      Inc(Size, 2)
    else if (Flags and HaveXAndYScale) <> 0 then
      Inc(Size, 4)
    else if (Flags and HaveTwoByTwo) <> 0 then
      Inc(Size, 8);
    if (Flags and HaveInstructions) <> 0 then
      Result := True;
    Composites.Position := FlagsAt;
    TakeBytes(Composites, 2 + Size, Start);
    PutBytes(Builder, Start, 2 + Size);
  until (Flags and MoreComponents) = 0;
end;

{ glyf and loca rebuilt from the transformed glyf table; GlyphCount and
  the loca format come from its header. XMins gets each glyph's xMin
  (for hmtx). }
procedure RebuildGlyphs(const Transformed: TBytes; out Glyf, Loca: TBytes; out IndexFormat: LongWord;
  out XMins: array of SmallInt; out GlyphCount: LongWord);
var
  Header: TByteStream;
  OptionFlags: LongWord;
  Sizes: array[0..6] of LongWord;
  Streams: array[0..6] of TByteStream;
  Overlaps: TByteStream;
  HasOverlaps: Boolean;
  Position: SizeInt;
  Index: LongInt;
  Glyph: LongWord;
  ContourCount: LongInt;
  PointCount: LongInt;
  Contour: LongInt;
  EndPoints: array of LongInt;
  Xs, Ys: array of LongInt;
  OnCurve: array of Boolean;
  BoxBitmap: PByte;
  BoxBitmapSize: SizeInt;
  HasBox: Boolean;
  XMin, YMin, XMax, YMax: LongInt;
  InstructionLength: LongWord;
  Instructions: PByte;
  Builder: TByteBuilder;
  Offsets: array of SizeInt;
  WantsInstructions: Boolean;
  Overlap: Boolean;
begin
  Header := MakeStream(@Transformed[0], Length(Transformed));
  ReadU16(Header);
  OptionFlags := ReadU16(Header);
  GlyphCount := ReadU16(Header);
  IndexFormat := ReadU16(Header);
  if (IndexFormat > 1) or (GlyphCount = 0) or (GlyphCount > LongWord(Length(XMins))) then
    Fail;
  for Index := 0 to 6 do
    Sizes[Index] := ReadU32(Header);
  Position := Header.Position;
  for Index := 0 to 6 do
  begin
    if QWord(Position) + Sizes[Index] > QWord(Length(Transformed)) then
      Fail;
    Streams[Index] := MakeStream(@Transformed[Position], Sizes[Index]);
    Position := Position + SizeInt(Sizes[Index]);
  end;
  HasOverlaps := (OptionFlags and 1) <> 0;
  Overlaps := MakeStream(nil, 0);
  if HasOverlaps then
  begin
    if Position + SizeInt((GlyphCount + 7) shr 3) > Length(Transformed) then
      Fail;
    Overlaps := MakeStream(@Transformed[Position], (GlyphCount + 7) shr 3);
  end;
  { The bounding boxes: a bit a glyph (padded to four bytes), then the
    boxes of the glyphs whose bit is set. }
  BoxBitmapSize := ((GlyphCount + 31) shr 5) shl 2;
  TakeBytes(Streams[5], BoxBitmapSize, BoxBitmap);
  Builder.Bytes := nil;
  Builder.Count := 0;
  SetLength(Offsets, GlyphCount + 1);
  for Glyph := 0 to GlyphCount - 1 do
  begin
    Offsets[Glyph] := Builder.Count;
    XMins[Glyph] := 0;
    ContourCount := ReadS16(Streams[0]);
    HasBox := (BoxBitmap[Glyph shr 3] and ($80 shr (Glyph and 7))) <> 0;
    if HasBox then
    begin
      XMin := ReadS16(Streams[5]);
      YMin := ReadS16(Streams[5]);
      XMax := ReadS16(Streams[5]);
      YMax := ReadS16(Streams[5]);
    end;
    if ContourCount = 0 then
    begin
      if HasBox then
        Fail;
      Continue;
    end;
    if ContourCount > 0 then
    begin
      { A simple glyph. }
      SetLength(EndPoints, ContourCount);
      PointCount := 0;
      for Contour := 0 to ContourCount - 1 do
      begin
        PointCount := PointCount + LongInt(Read255UShort(Streams[1]));
        if PointCount > 65535 then
          Fail;
        EndPoints[Contour] := PointCount - 1;
      end;
      SetLength(Xs, PointCount);
      SetLength(Ys, PointCount);
      SetLength(OnCurve, PointCount);
      DecodeTriplets(Streams[2], Streams[3], PointCount, Xs, Ys, OnCurve);
      if not HasBox then
      begin
        XMin := 0;
        YMin := 0;
        XMax := 0;
        YMax := 0;
        for Index := 0 to PointCount - 1 do
        begin
          if (Index = 0) or (Xs[Index] < XMin) then
            XMin := Xs[Index];
          if (Index = 0) or (Xs[Index] > XMax) then
            XMax := Xs[Index];
          if (Index = 0) or (Ys[Index] < YMin) then
            YMin := Ys[Index];
          if (Index = 0) or (Ys[Index] > YMax) then
            YMax := Ys[Index];
        end;
      end;
      InstructionLength := Read255UShort(Streams[3]);
      TakeBytes(Streams[6], InstructionLength, Instructions);
      Overlap := HasOverlaps and ((Overlaps.Data[Glyph shr 3] and ($80 shr (Glyph and 7))) <> 0);
      PutU16(Builder, Word(SmallInt(ContourCount)));
      PutU16(Builder, Word(SmallInt(XMin)));
      PutU16(Builder, Word(SmallInt(YMin)));
      PutU16(Builder, Word(SmallInt(XMax)));
      PutU16(Builder, Word(SmallInt(YMax)));
      for Contour := 0 to ContourCount - 1 do
        PutU16(Builder, EndPoints[Contour]);
      PutU16(Builder, InstructionLength);
      PutBytes(Builder, Instructions, InstructionLength);
      WriteSimplePoints(Builder, PointCount, Xs, Ys, OnCurve, Overlap);
    end
    else
    begin
      { A composite glyph: its box must be given. }
      if (ContourCount <> -1) or not HasBox then
        Fail;
      PutU16(Builder, $FFFF);
      PutU16(Builder, Word(SmallInt(XMin)));
      PutU16(Builder, Word(SmallInt(YMin)));
      PutU16(Builder, Word(SmallInt(XMax)));
      PutU16(Builder, Word(SmallInt(YMax)));
      WantsInstructions := CopyComposite(Streams[4], Builder);
      if WantsInstructions then
      begin
        InstructionLength := Read255UShort(Streams[3]);
        TakeBytes(Streams[6], InstructionLength, Instructions);
        PutU16(Builder, InstructionLength);
        PutBytes(Builder, Instructions, InstructionLength);
      end;
    end;
    XMins[Glyph] := XMin;
    PadTo(Builder, 4);
  end;
  Offsets[GlyphCount] := Builder.Count;
  if (IndexFormat = 0) and (Builder.Count > 2 * $FFFF) then
    Fail;
  SetLength(Builder.Bytes, Builder.Count);
  Glyf := Builder.Bytes;
  Builder.Bytes := nil;
  Builder.Count := 0;
  for Glyph := 0 to GlyphCount do
    if IndexFormat = 0 then
      PutU16(Builder, Offsets[Glyph] div 2)
    else
      PutU32(Builder, Offsets[Glyph]);
  SetLength(Builder.Bytes, Builder.Count);
  Loca := Builder.Bytes;
end;

{ --- hmtx -------------------------------------------------------------- }

function RebuildMetrics(const Transformed: TBytes; MetricCount, GlyphCount: LongWord;
  const XMins: array of SmallInt): TBytes;
var
  Stream: TByteStream;
  Flags: LongWord;
  Advances: array of LongWord;
  Bearings: array of LongInt;
  Glyph: LongWord;
  Builder: TByteBuilder;
begin
  if (MetricCount = 0) or (MetricCount > GlyphCount) then
    Fail;
  Stream := MakeStream(@Transformed[0], Length(Transformed));
  Flags := ReadU8(Stream);
  SetLength(Advances, MetricCount);
  SetLength(Bearings, GlyphCount);
  for Glyph := 0 to MetricCount - 1 do
    Advances[Glyph] := ReadU16(Stream);
  for Glyph := 0 to MetricCount - 1 do
    if (Flags and 1) <> 0 then
      Bearings[Glyph] := XMins[Glyph]
    else
      Bearings[Glyph] := ReadS16(Stream);
  for Glyph := MetricCount to GlyphCount - 1 do
    if (Flags and 2) <> 0 then
      Bearings[Glyph] := XMins[Glyph]
    else
      Bearings[Glyph] := ReadS16(Stream);
  Builder.Bytes := nil;
  Builder.Count := 0;
  for Glyph := 0 to MetricCount - 1 do
  begin
    PutU16(Builder, Advances[Glyph]);
    PutU16(Builder, Word(SmallInt(Bearings[Glyph])));
  end;
  for Glyph := MetricCount to GlyphCount - 1 do
    PutU16(Builder, Word(SmallInt(Bearings[Glyph])));
  SetLength(Builder.Bytes, Builder.Count);
  Result := Builder.Bytes;
end;

{ --- the file ------------------------------------------------------------ }

function Decompress(Data: PByte; Count: SizeInt; Size: SizeInt): TBytes;
var
  Decoder: TBrotliDecoder;
  Written: SizeInt;
  Outcome: TDecompressResult;
  Spare: Byte;
begin
  Result := nil;
  SetLength(Result, Size);
  Decoder := TBrotliDecoder.Create;
  try
    Decoder.SetInput(Data, Count);
    if Size > 0 then
    begin
      Outcome := Decoder.Decompress(@Result[0], Size, Written);
      if Written <> Size then
        Fail;
    end
    else
      Outcome := DecompressOutputFull;
    { Nothing may follow. }
    if Outcome <> DecompressFinished then
    begin
      Outcome := Decoder.Decompress(@Spare, 1, Written);
      if (Outcome <> DecompressFinished) or (Written <> 0) then
        Fail;
    end;
  finally
    Decoder.Free;
  end;
end;

function FindTable(const Tables: array of TTableEntry; const Tag: string): LongInt;
var
  Index: LongInt;
begin
  for Index := 0 to High(Tables) do
    if Tables[Index].Tag = Tag then
      Exit(Index);
  Result := -1;
end;

{ The sfnt: its header, the directory sorted by tag, the tables each on
  four bytes. }
function AssembleFont(Flavor: LongWord; var Tables: array of TTableEntry): TBytes;
var
  Order: array of LongInt;
  Index, Other, Swap: LongInt;
  Builder: TByteBuilder;
  SearchRange, EntrySelector: LongWord;
  TableOffset: SizeInt;
  Count: LongInt;
  Entry: ^TTableEntry;
begin
  Count := Length(Tables);
  SetLength(Order, Count);
  for Index := 0 to Count - 1 do
    Order[Index] := Index;
  for Index := 1 to Count - 1 do
  begin
    Other := Index;
    while (Other > 0) and (Tables[Order[Other - 1]].Tag > Tables[Order[Other]].Tag) do
    begin
      Swap := Order[Other];
      Order[Other] := Order[Other - 1];
      Order[Other - 1] := Swap;
      Dec(Other);
    end;
  end;
  Builder.Bytes := nil;
  Builder.Count := 0;
  PutU32(Builder, Flavor);
  PutU16(Builder, Count);
  SearchRange := 1;
  EntrySelector := 0;
  while SearchRange * 2 <= LongWord(Count) do
  begin
    SearchRange := SearchRange * 2;
    Inc(EntrySelector);
  end;
  PutU16(Builder, SearchRange * 16);
  PutU16(Builder, EntrySelector);
  PutU16(Builder, LongWord(Count) * 16 - SearchRange * 16);
  TableOffset := 12 + 16 * Count;
  for Index := 0 to Count - 1 do
  begin
    Entry := @Tables[Order[Index]];
    PutU8(Builder, Ord(Entry^.Tag[1]));
    PutU8(Builder, Ord(Entry^.Tag[2]));
    PutU8(Builder, Ord(Entry^.Tag[3]));
    PutU8(Builder, Ord(Entry^.Tag[4]));
    PutU32(Builder, 0);
    PutU32(Builder, TableOffset);
    PutU32(Builder, Length(Entry^.Output));
    TableOffset := TableOffset + ((Length(Entry^.Output) + 3) and not 3);
  end;
  for Index := 0 to Count - 1 do
  begin
    if Length(Tables[Order[Index]].Output) > 0 then
      PutBytes(Builder, @Tables[Order[Index]].Output[0], Length(Tables[Order[Index]].Output));
    PadTo(Builder, 4);
  end;
  SetLength(Builder.Bytes, Builder.Count);
  Result := Builder.Bytes;
end;

function Unwrap(const Data: TBytes): TBytes;
var
  Stream: TByteStream;
  Flavor: LongWord;
  TableCount: LongWord;
  CompressedSize: LongWord;
  Tables: array of TTableEntry;
  Index: LongInt;
  Flags: LongWord;
  TagIndex: LongWord;
  TagValue: LongWord;
  Version: LongWord;
  Total: QWord;
  Stored: TBytes;
  GlyfIndex, LocaIndex, HmtxIndex, HeadIndex, HheaIndex, MaxpIndex: LongInt;
  XMins: array of SmallInt;
  GlyphCount: LongWord;
  IndexFormat: LongWord;
  Length_: LongWord;
begin
  Result := nil;
  if Length(Data) < HeaderSize then
    Exit;
  Stream := MakeStream(@Data[0], Length(Data));
  if ReadU32(Stream) <> $774F4632 then
    Exit;
  Flavor := ReadU32(Stream);
  if (Flavor = CollectionFlavor) or (ReadU32(Stream) <> LongWord(Length(Data))) then
    Exit;
  TableCount := ReadU16(Stream);
  ReadU16(Stream);
  if (ReadU32(Stream) > MaximumSfntBytes) or (TableCount = 0) or (TableCount > MaximumTables) then
    Exit;
  CompressedSize := ReadU32(Stream);
  Stream.Position := HeaderSize;
  SetLength(Tables, TableCount);
  Total := 0;
  for Index := 0 to TableCount - 1 do
  begin
    Flags := ReadU8(Stream);
    TagIndex := Flags and $3F;
    Version := (Flags shr 6) and 3;
    if TagIndex = ArbitraryTag then
    begin
      TagValue := ReadU32(Stream);
      Tables[Index].Tag := Chr(TagValue shr 24) + Chr((TagValue shr 16) and $FF) + Chr((TagValue shr 8) and $FF) +
        Chr(TagValue and $FF);
    end
    else
      Tables[Index].Tag := KnownTags[TagIndex];
    Tables[Index].OriginalLength := ReadBase128(Stream);
    if (Tables[Index].Tag = 'glyf') or (Tables[Index].Tag = 'loca') then
      Tables[Index].Transformed := Version = 0
    else
      Tables[Index].Transformed := Version <> 0;
    if Tables[Index].Transformed then
      Tables[Index].TransformLength := ReadBase128(Stream)
    else
      Tables[Index].TransformLength := Tables[Index].OriginalLength;
    if Tables[Index].Transformed and (Tables[Index].Tag <> 'glyf') and (Tables[Index].Tag <> 'loca') and
       (Tables[Index].Tag <> 'hmtx') then
      Exit;
    Tables[Index].Offset := Total;
    Total := Total + Tables[Index].TransformLength;
    if Total > MaximumSfntBytes then
      Exit;
  end;
  if QWord(Stream.Position) + CompressedSize > QWord(Length(Data)) then
    Exit;
  Stored := Decompress(@Data[Stream.Position], CompressedSize, Total);
  for Index := 0 to TableCount - 1 do
    if not Tables[Index].Transformed then
      Tables[Index].Output := Copy(Stored, Tables[Index].Offset, Tables[Index].OriginalLength);
  GlyfIndex := FindTable(Tables, 'glyf');
  LocaIndex := FindTable(Tables, 'loca');
  HmtxIndex := FindTable(Tables, 'hmtx');
  HeadIndex := FindTable(Tables, 'head');
  HheaIndex := FindTable(Tables, 'hhea');
  MaxpIndex := FindTable(Tables, 'maxp');
  if (GlyfIndex >= 0) <> (LocaIndex >= 0) then
    Exit;
  SetLength(XMins, 65536);
  GlyphCount := 0;
  if (GlyfIndex >= 0) and Tables[GlyfIndex].Transformed then
  begin
    if not Tables[LocaIndex].Transformed or (Tables[LocaIndex].TransformLength <> 0) or (HeadIndex < 0) then
      Exit;
    RebuildGlyphs(Copy(Stored, Tables[GlyfIndex].Offset, Tables[GlyfIndex].TransformLength), Tables[GlyfIndex].Output,
      Tables[LocaIndex].Output, IndexFormat, XMins, GlyphCount);
    { head's loca format follows the rebuilt loca. }
    SetBigEndian16(Tables[HeadIndex].Output, 50, IndexFormat);
  end
  else if (GlyfIndex >= 0) and Tables[LocaIndex].Transformed then
    Exit;
  if (HmtxIndex >= 0) and Tables[HmtxIndex].Transformed then
  begin
    if (GlyphCount = 0) or (HheaIndex < 0) or (MaxpIndex < 0) then
      Exit;
    if BigEndian16(Tables[MaxpIndex].Output, 4) <> GlyphCount then
      Exit;
    Length_ := BigEndian16(Tables[HheaIndex].Output, 34);
    Tables[HmtxIndex].Output := RebuildMetrics(Copy(Stored, Tables[HmtxIndex].Offset, Tables[HmtxIndex].TransformLength),
      Length_, GlyphCount, XMins);
  end;
  Result := AssembleFont(Flavor, Tables);
end;

function UnwrapWoff2(const Data: TBytes): TBytes;
begin
  try
    Result := Unwrap(Data);
  except
    on Exception do
      Result := nil;
  end;
end;

end.
