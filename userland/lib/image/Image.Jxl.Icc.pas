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
  JPEG XL's embedded ICC profile (ISO/IEC 18181-1 annex B.3).

  The profile is entropy coded byte by byte (41 contexts chosen by the
  kinds of the two bytes before), and what comes out is not the profile
  yet but a description of it: its size and a command stream, then
  data. The 128-byte header is stored as differences from a predicted
  header; the tag table as commands naming common tags (with the
  offsets and sizes following from the previous tag unless given); the
  rest as commands that insert bytes, insert them de-interleaved
  ("shuffled", for arrays of 16- and 32-bit numbers), predict numbers
  linearly from the ones before them, or write common tag types. The
  profile is rebuilt exactly as libjxl does.
}
unit Image.Jxl.Icc;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Image.Errors,
  Image.Jxl.BitReader;

{ Reads the encoded profile that follows the image headers and returns
  the profile. }
function ReadJxlIccProfile(Reader: TJxlBitReader): TBytes;
{ Rebuilds a profile from its decoded description (exposed for tests). }
function UnpredictJxlIccProfile(const Encoded: TBytes): TBytes;

implementation

uses
  Image.Jxl.Entropy;

const
  IccContextCount = 41;
  IccHeaderSize = 128;
  MaximumEncodedSize = 1 shl 28;

  CommandTagUnknown = 1;
  CommandTagTrc = 2;
  CommandTagXyz = 3;
  CommandTagStringFirst = 4;
  CommandInsert = 1;
  CommandShuffle2 = 2;
  CommandShuffle4 = 3;
  CommandPredict = 4;
  CommandXyz = 10;
  CommandTypeStartFirst = 16;
  FlagBitOffset = 64;
  FlagBitSize = 128;

  TagStrings: array[0..16] of string[4] = (
    'cprt', 'wtpt', 'bkpt', 'rXYZ', 'gXYZ', 'bXYZ', 'kXYZ', 'rTRC', 'gTRC', 'bTRC', 'kTRC', 'chad',
    'desc', 'chrm', 'dmnd', 'dmdd', 'lumi');
  TypeStrings: array[0..7] of string[4] = (
    'XYZ ', 'desc', 'text', 'mluc', 'para', 'curv', 'sf32', 'gbd ');

  InitialHeaderPrediction: array[0..IccHeaderSize - 1] of Byte = (
    0, 0, 0, 0, 0, 0, 0, 0, 4, 0, 0, 0, Ord('m'), Ord('n'), Ord('t'), Ord('r'),
    Ord('R'), Ord('G'), Ord('B'), Ord(' '), Ord('X'), Ord('Y'), Ord('Z'), Ord(' '), 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, Ord('a'), Ord('c'), Ord('s'), Ord('p'), 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 246, 214, 0, 1, 0, 0, 0, 0, 211, 45,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);

type
  { The profile being rebuilt. }
  TIccOutput = record
    Bytes: TBytes;
    Count: PtrInt;
  end;

procedure RaiseBadProfile;
begin
  RaiseImageError(ImageErrorMalformed, 'JPEG XL: bad ICC profile');
end;

procedure AppendByte(var Output: TIccOutput; Value: Byte);
begin
  if Output.Count >= Length(Output.Bytes) then
    RaiseBadProfile;
  Output.Bytes[Output.Count] := Value;
  Inc(Output.Count);
end;

procedure AppendUint32(var Output: TIccOutput; Value: QWord);
begin
  if Value > $FFFFFFFF then
    RaiseBadProfile;
  AppendByte(Output, (Value shr 24) and $FF);
  AppendByte(Output, (Value shr 16) and $FF);
  AppendByte(Output, (Value shr 8) and $FF);
  AppendByte(Output, Value and $FF);
end;

procedure AppendKeyword(var Output: TIccOutput; const Keyword: string);
var
  Index: LongInt;
begin
  for Index := 1 to 4 do
    AppendByte(Output, Ord(Keyword[Index]));
end;

function ByteKind1(Value: Byte): LongInt;
begin
  if (Value >= Ord('a')) and (Value <= Ord('z')) then Exit(0);
  if (Value >= Ord('A')) and (Value <= Ord('Z')) then Exit(0);
  if (Value >= Ord('0')) and (Value <= Ord('9')) then Exit(1);
  if (Value = Ord('.')) or (Value = Ord(',')) then Exit(1);
  if Value = 0 then Exit(2);
  if Value = 1 then Exit(3);
  if Value < 16 then Exit(4);
  if Value = 255 then Exit(6);
  if Value > 240 then Exit(5);
  Result := 7;
end;

function ByteKind2(Value: Byte): LongInt;
begin
  if (Value >= Ord('a')) and (Value <= Ord('z')) then Exit(0);
  if (Value >= Ord('A')) and (Value <= Ord('Z')) then Exit(0);
  if (Value >= Ord('0')) and (Value <= Ord('9')) then Exit(1);
  if (Value = Ord('.')) or (Value = Ord(',')) then Exit(1);
  if Value < 16 then Exit(2);
  if Value > 240 then Exit(3);
  Result := 4;
end;

function IccContext(Index: PtrInt; Previous1, Previous2: Byte): LongInt;
begin
  if Index <= 128 then
    Exit(0);
  Result := 1 + ByteKind1(Previous1) + ByteKind2(Previous2) * 8;
end;

function DecodeVarInt(const Data: TBytes; Limit: PtrInt; var Position: PtrInt): QWord;
var
  Index: LongInt;
  Value: Byte;
begin
  Result := 0;
  for Index := 0 to 8 do
  begin
    if Position >= Limit then
      RaiseBadProfile;
    Value := Data[Position];
    Inc(Position);
    Result := Result or (QWord(Value and $7F) shl (7 * Index));
    if (Value and $80) = 0 then
      Exit;
  end;
  if Position >= Limit then
    RaiseBadProfile;
  Value := Data[Position];
  Inc(Position);
  if (Value and $FE) <> 0 then
    RaiseBadProfile;
  Result := Result or (QWord(Value and 1) shl 63);
end;

procedure CheckOutOfBounds(Start, Count: QWord; Size: PtrInt);
begin
  if (Start + Count > QWord(Size)) or (Start + Count < Start) then
    RaiseBadProfile;
end;

{ De-interleaves Data: the input is a Width-column matrix read column by
  column. }
procedure Shuffle(var Data: TBytes; Width: LongInt);
var
  Size: PtrInt;
  Height: PtrInt;
  Output: TBytes;
  OutputIndex: PtrInt;
  InputIndex: PtrInt;
  Column: PtrInt;
begin
  Size := Length(Data);
  if Size = 0 then
    Exit;
  Height := (Size + Width - 1) div Width;
  SetLength(Output, Size);
  Column := 0;
  InputIndex := 0;
  for OutputIndex := 0 to Size - 1 do
  begin
    Output[OutputIndex] := Data[InputIndex];
    Inc(InputIndex, Height);
    if InputIndex >= Size then
    begin
      Inc(Column);
      InputIndex := Column;
    end;
  end;
  Data := Output;
end;

procedure PredictHeader(const Output: TIccOutput; var Header: array of Byte; Position: LongInt);
var
  Icc: TBytes;
begin
  Icc := Output.Bytes;
  if (Position = 8) and (Output.Count >= 8) then
  begin
    Header[80] := Icc[4];
    Header[81] := Icc[5];
    Header[82] := Icc[6];
    Header[83] := Icc[7];
  end;
  if (Position = 41) and (Output.Count >= 41) then
  begin
    if Icc[40] = Ord('A') then
    begin
      Header[41] := Ord('P');
      Header[42] := Ord('P');
      Header[43] := Ord('L');
    end;
    if Icc[40] = Ord('M') then
    begin
      Header[41] := Ord('S');
      Header[42] := Ord('F');
      Header[43] := Ord('T');
    end;
  end;
  if (Position = 42) and (Output.Count >= 42) then
  begin
    if (Icc[40] = Ord('S')) and (Icc[41] = Ord('G')) then
    begin
      Header[42] := Ord('I');
      Header[43] := Ord(' ');
    end;
    if (Icc[40] = Ord('S')) and (Icc[41] = Ord('U')) then
    begin
      Header[42] := Ord('N');
      Header[43] := Ord('W');
    end;
  end;
end;

function PredictValue(P1, P2, P3: Int64; Order: LongInt): Int64;
begin
  case Order of
    0: Result := P1;
    1: Result := 2 * P1 - P2;
  else
    Result := 3 * P1 - 3 * P2 + P3;
  end;
end;

{ The big-endian 32-bit number at Position, or 0 unless it lies below
  Limit. }
function LoadUint32Below(const Data: TBytes; Limit, Position: PtrInt): Int64;
begin
  if (Position < 0) or (Position + 4 > Limit) then
    Exit(0);
  Result := (Int64(Data[Position]) shl 24) or (Int64(Data[Position + 1]) shl 16) or
    (Int64(Data[Position + 2]) shl 8) or Int64(Data[Position + 3]);
end;

function LinearPredict(const Data: TBytes; Start, Index, Stride: PtrInt; Width, Order: LongInt): Byte;
var
  Position: PtrInt;
  Base: PtrInt;
  P1: Int64;
  P2: Int64;
  P3: Int64;
  Predicted: Int64;
begin
  Position := Start + Index;
  if Width = 1 then
  begin
    Predicted := PredictValue(Data[Position - Stride], Data[Position - Stride * 2], Data[Position - Stride * 3], Order);
    Result := Byte(Predicted and $FF);
  end
  else if Width = 2 then
  begin
    Base := Start + (Index and not PtrInt(1));
    P1 := (Int64(Data[Base - Stride]) shl 8) + Data[Base - Stride + 1];
    P2 := (Int64(Data[Base - Stride * 2]) shl 8) + Data[Base - Stride * 2 + 1];
    P3 := (Int64(Data[Base - Stride * 3]) shl 8) + Data[Base - Stride * 3 + 1];
    Predicted := PredictValue(P1, P2, P3, Order) and $FFFF;
    if (Index and 1) <> 0 then
      Result := Byte(Predicted and $FF)
    else
      Result := Byte((Predicted shr 8) and $FF);
  end
  else
  begin
    Base := Start + (Index and not PtrInt(3));
    P1 := LoadUint32Below(Data, Position, Base - Stride);
    P2 := LoadUint32Below(Data, Position, Base - Stride * 2);
    P3 := LoadUint32Below(Data, Position, Base - Stride * 3);
    Predicted := PredictValue(P1, P2, P3, Order) and $FFFFFFFF;
    Result := Byte((Predicted shr ((3 - (Index and 3)) * 8)) and $FF);
  end;
end;

function UnpredictJxlIccProfile(const Encoded: TBytes): TBytes;
var
  Size: PtrInt;
  Position: PtrInt;
  CommandPosition: PtrInt;
  CommandsEnd: PtrInt;
  OutputSize: QWord;
  CommandsSize: QWord;
  Header: array[0..IccHeaderSize - 1] of Byte;
  Output: TIccOutput;
  Index: PtrInt;
  TagCount: QWord;
  PreviousTagStart: QWord;
  PreviousTagSize: QWord;
  TagStart: QWord;
  TagSize: QWord;
  Command: Byte;
  TagCode: Byte;
  Tag: string;
  Count: QWord;
  Shuffled: TBytes;
  Flags: Byte;
  Width: LongInt;
  Order: LongInt;
  Stride: QWord;
  Start: PtrInt;
begin
  Size := Length(Encoded);
  Position := 0;
  OutputSize := DecodeVarInt(Encoded, Size, Position);
  CommandsSize := DecodeVarInt(Encoded, Size, Position);
  { No command makes more than 36 bytes of one byte of its own. }
  if (OutputSize > $FFFFFFFF) or (CommandsSize > $FFFFFFFF) or (OutputSize > QWord(Size) * 40 + 256) then
    RaiseBadProfile;
  CheckOutOfBounds(Position, CommandsSize, Size);
  CommandPosition := Position;
  CommandsEnd := CommandPosition + PtrInt(CommandsSize);
  Position := CommandsEnd;
  SetLength(Output.Bytes, OutputSize);
  Output.Count := 0;
  Move(InitialHeaderPrediction, Header, SizeOf(Header));
  Header[0] := (OutputSize shr 24) and $FF;
  Header[1] := (OutputSize shr 16) and $FF;
  Header[2] := (OutputSize shr 8) and $FF;
  Header[3] := OutputSize and $FF;
  for Index := 0 to IccHeaderSize do
  begin
    if QWord(Output.Count) = OutputSize then
    begin
      if (CommandPosition <> CommandsEnd) or (Position <> Size) then
        RaiseBadProfile;
      Exit(Output.Bytes);
    end;
    if Index = IccHeaderSize then
      Break;
    PredictHeader(Output, Header, Index);
    if Position >= Size then
      RaiseBadProfile;
    AppendByte(Output, Byte((Encoded[Position] + Header[Index]) and $FF));
    Inc(Position);
  end;
  if CommandPosition >= CommandsEnd then
    RaiseBadProfile;
  { The tag table. }
  TagCount := DecodeVarInt(Encoded, CommandsEnd, CommandPosition);
  if TagCount <> 0 then
  begin
    Dec(TagCount);
    AppendUint32(Output, TagCount);
    PreviousTagStart := IccHeaderSize + TagCount * 12;
    PreviousTagSize := 0;
    while True do
    begin
      if QWord(Output.Count) > OutputSize then
        RaiseBadProfile;
      if CommandPosition >= CommandsEnd then
        Break;
      Command := Encoded[CommandPosition];
      Inc(CommandPosition);
      TagCode := Command and 63;
      if TagCode = 0 then
        Break;
      if TagCode = CommandTagUnknown then
      begin
        CheckOutOfBounds(Position, 4, Size);
        Tag := Chr(Encoded[Position]) + Chr(Encoded[Position + 1]) + Chr(Encoded[Position + 2]) +
          Chr(Encoded[Position + 3]);
        Inc(Position, 4);
      end
      else if TagCode = CommandTagTrc then
        Tag := 'rTRC'
      else if TagCode = CommandTagXyz then
        Tag := 'rXYZ'
      else
      begin
        if TagCode - CommandTagStringFirst >= Length(TagStrings) then
          RaiseBadProfile;
        Tag := TagStrings[TagCode - CommandTagStringFirst];
      end;
      AppendKeyword(Output, Tag);
      TagSize := PreviousTagSize;
      if (Tag = 'rXYZ') or (Tag = 'gXYZ') or (Tag = 'bXYZ') or (Tag = 'kXYZ') or (Tag = 'wtpt') or
        (Tag = 'bkpt') or (Tag = 'lumi') then
        TagSize := 20;
      if (Command and FlagBitOffset) <> 0 then
        TagStart := DecodeVarInt(Encoded, CommandsEnd, CommandPosition)
      else
      begin
        if PreviousTagStart > $FFFFFFFF then
          RaiseBadProfile;
        TagStart := PreviousTagStart + PreviousTagSize;
      end;
      AppendUint32(Output, TagStart);
      if (Command and FlagBitSize) <> 0 then
        TagSize := DecodeVarInt(Encoded, CommandsEnd, CommandPosition);
      AppendUint32(Output, TagSize);
      PreviousTagStart := TagStart;
      PreviousTagSize := TagSize;
      if TagCode = CommandTagTrc then
      begin
        AppendKeyword(Output, 'gTRC');
        AppendUint32(Output, TagStart);
        AppendUint32(Output, TagSize);
        AppendKeyword(Output, 'bTRC');
        AppendUint32(Output, TagStart);
        AppendUint32(Output, TagSize);
      end;
      if TagCode = CommandTagXyz then
      begin
        AppendKeyword(Output, 'gXYZ');
        AppendUint32(Output, TagStart + TagSize);
        AppendUint32(Output, TagSize);
        AppendKeyword(Output, 'bXYZ');
        AppendUint32(Output, TagStart + TagSize * 2);
        AppendUint32(Output, TagSize);
      end;
    end;
  end;
  { The main content. }
  while True do
  begin
    if QWord(Output.Count) > OutputSize then
      RaiseBadProfile;
    if CommandPosition >= CommandsEnd then
      Break;
    Command := Encoded[CommandPosition];
    Inc(CommandPosition);
    if Command = CommandInsert then
    begin
      Count := DecodeVarInt(Encoded, CommandsEnd, CommandPosition);
      CheckOutOfBounds(Position, Count, Size);
      for Index := 1 to PtrInt(Count) do
      begin
        AppendByte(Output, Encoded[Position]);
        Inc(Position);
      end;
    end
    else if (Command = CommandShuffle2) or (Command = CommandShuffle4) then
    begin
      Count := DecodeVarInt(Encoded, CommandsEnd, CommandPosition);
      CheckOutOfBounds(Position, Count, Size);
      Shuffled := Copy(Encoded, Position, PtrInt(Count));
      if Command = CommandShuffle2 then
        Shuffle(Shuffled, 2)
      else
        Shuffle(Shuffled, 4);
      for Index := 0 to High(Shuffled) do
        AppendByte(Output, Shuffled[Index]);
      Inc(Position, PtrInt(Count));
    end
    else if Command = CommandPredict then
    begin
      CheckOutOfBounds(CommandPosition, 2, CommandsEnd);
      Flags := Encoded[CommandPosition];
      Inc(CommandPosition);
      Width := (Flags and 3) + 1;
      if Width = 3 then
        RaiseBadProfile;
      Order := (Flags and 12) shr 2;
      if Order = 3 then
        RaiseBadProfile;
      Stride := Width;
      if (Flags and 16) <> 0 then
      begin
        Stride := DecodeVarInt(Encoded, CommandsEnd, CommandPosition);
        if Stride < QWord(Width) then
          RaiseBadProfile;
      end;
      if (Output.Count = 0) or (QWord((Output.Count - 1) shr 2) < Stride) then
        RaiseBadProfile;
      Count := DecodeVarInt(Encoded, CommandsEnd, CommandPosition);
      CheckOutOfBounds(Position, Count, Size);
      Shuffled := Copy(Encoded, Position, PtrInt(Count));
      if Width > 1 then
        Shuffle(Shuffled, Width);
      Start := Output.Count;
      for Index := 0 to High(Shuffled) do
        AppendByte(Output, Byte((LinearPredict(Output.Bytes, Start, Index, PtrInt(Stride), Width, Order)
          + Shuffled[Index]) and $FF));
      Inc(Position, PtrInt(Count));
    end
    else if Command = CommandXyz then
    begin
      AppendKeyword(Output, 'XYZ ');
      for Index := 1 to 4 do
        AppendByte(Output, 0);
      CheckOutOfBounds(Position, 12, Size);
      for Index := 1 to 12 do
      begin
        AppendByte(Output, Encoded[Position]);
        Inc(Position);
      end;
    end
    else if (Command >= CommandTypeStartFirst) and (Command < CommandTypeStartFirst + Length(TypeStrings)) then
    begin
      AppendKeyword(Output, TypeStrings[Command - CommandTypeStartFirst]);
      for Index := 1 to 4 do
        AppendByte(Output, 0);
    end
    else
      RaiseBadProfile;
  end;
  if (Position <> Size) or (QWord(Output.Count) <> OutputSize) then
    RaiseBadProfile;
  Result := Output.Bytes;
end;

function ReadJxlIccProfile(Reader: TJxlBitReader): TBytes;
var
  EncodedSize: QWord;
  Code: TJxlEntropyCode;
  SymbolReader: TJxlSymbolReader;
  Encoded: TBytes;
  Index: PtrInt;
  Previous1: Byte;
  Previous2: Byte;
begin
  EncodedSize := Reader.ReadU64;
  if EncodedSize > MaximumEncodedSize then
    RaiseBadProfile;
  { Every byte takes at least a little of the codestream; a size far
    beyond what is left is a lie. }
  if EncodedSize > QWord(Reader.TotalBits - Reader.BitPosition) * 32 + 1024 then
    RaiseImageError(ImageErrorTruncated, 'JPEG XL ICC profile');
  Code := ReadJxlEntropyCode(Reader, IccContextCount);
  try
    SymbolReader := TJxlSymbolReader.Create(Code, Reader);
    try
      SetLength(Encoded, EncodedSize);
      for Index := 0 to PtrInt(EncodedSize) - 1 do
      begin
        if Index > 0 then
          Previous1 := Encoded[Index - 1]
        else
          Previous1 := 0;
        if Index > 1 then
          Previous2 := Encoded[Index - 2]
        else
          Previous2 := 0;
        Encoded[Index] := Byte(SymbolReader.ReadUint(IccContext(Index, Previous1, Previous2)) and $FF);
      end;
      SymbolReader.CheckFinalState;
    finally
      SymbolReader.Free;
    end;
  finally
    Code.Free;
  end;
  Result := UnpredictJxlIccProfile(Encoded);
end;

end.
