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
  FLAC's headers (RFC 9639): the STREAMINFO block and frame headers,
  with the CRC-8 that guards a frame header and the CRC-16 that guards
  a whole frame.

  A frame header starts with the 14-bit sync code 11111111111110, then
  the blocking strategy, block size, sample rate, channel assignment and
  sample size codes, the frame or sample number (UTF-8-like, up to 36
  bits), the block size and rate when the codes say they follow, and the
  CRC-8 of all of it. Codes that defer to STREAMINFO take its values.
}
unit Media.Flac.Headers;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  SysUtils;

type
  TFlacStreamInfo = record
    MinimumBlockSize, MaximumBlockSize: Integer;
    MinimumFrameSize, MaximumFrameSize: Integer;
    SampleRate: Integer;
    Channels: Integer;
    BitsPerSample: Integer;
    { 0 if not known. }
    TotalSamples: Int64;
    Md5: array[0..15] of Byte;
  end;

  TFlacChannelAssignment = (caIndependent, caLeftSide, caSideRight, caMidSide);

  TFlacFrameHeader = record
    VariableBlockSize: Boolean;
    BlockSize: Integer;
    SampleRate: Integer;
    Channels: Integer;
    Assignment: TFlacChannelAssignment;
    BitsPerSample: Integer;
    { The frame number (fixed block size) or the first sample's number. }
    CodedNumber: Int64;
    { The header's length in bytes, CRC-8 included. }
    Length: Integer;
  end;

{ Reads a STREAMINFO body (34 bytes); False if it is too short or invalid. }
function ParseFlacStreamInfo(const Body: TBytes; out Info: TFlacStreamInfo): Boolean;
{ Parses the frame header at Data (Size bytes available), checking its
  CRC-8; codes that refer to STREAMINFO take Info's values (Info may be
  all zeros when not known: such a header is then refused). }
function ParseFlacFrameHeader(Data: PByte; Size: Integer; const Info: TFlacStreamInfo;
  out Header: TFlacFrameHeader): Boolean;
{ The first sample's number of a frame with Header, given the stream's
  fixed block size (STREAMINFO's maximum). }
function FlacFirstSample(const Header: TFlacFrameHeader; const Info: TFlacStreamInfo): Int64;
function FlacCrc8(Data: PByte; Count: Integer): Byte;
function FlacCrc16(Data: PByte; Count: Integer): Word;
{ Continues a CRC-16 over one more byte. }
function FlacCrc16Step(Crc: Word; Value: Byte): Word; inline;

implementation

var
  Crc8Table: array[Byte] of Byte;
  Crc16Table: array[Byte] of Word;

procedure BuildTables;
var
  Index, Bit: Integer;
  Crc8: Byte;
  Crc16: Word;
begin
  for Index := 0 to 255 do
  begin
    Crc8 := Index;
    for Bit := 0 to 7 do
      if (Crc8 and $80) <> 0 then
        Crc8 := Byte((Crc8 shl 1) xor $07)
      else
        Crc8 := Byte(Crc8 shl 1);
    Crc8Table[Index] := Crc8;
    Crc16 := Word(Index shl 8);
    for Bit := 0 to 7 do
      if (Crc16 and $8000) <> 0 then
        Crc16 := Word((Crc16 shl 1) xor $8005)
      else
        Crc16 := Word(Crc16 shl 1);
    Crc16Table[Index] := Crc16;
  end;
end;

function FlacCrc8(Data: PByte; Count: Integer): Byte;
var
  Index: Integer;
begin
  Result := 0;
  for Index := 0 to Count - 1 do
    Result := Crc8Table[Result xor Data[Index]];
end;

function FlacCrc16Step(Crc: Word; Value: Byte): Word;
begin
  Result := Word(Crc shl 8) xor Crc16Table[(Crc shr 8) xor Value];
end;

function FlacCrc16(Data: PByte; Count: Integer): Word;
var
  Index: Integer;
begin
  Result := 0;
  for Index := 0 to Count - 1 do
    Result := FlacCrc16Step(Result, Data[Index]);
end;

function ParseFlacStreamInfo(const Body: TBytes; out Info: TFlacStreamInfo): Boolean;
var
  Bits64: QWord;
  Index: Integer;
begin
  Info := Default(TFlacStreamInfo);
  if Length(Body) < 34 then
    Exit(False);
  Info.MinimumBlockSize := (Body[0] shl 8) or Body[1];
  Info.MaximumBlockSize := (Body[2] shl 8) or Body[3];
  Info.MinimumFrameSize := (Body[4] shl 16) or (Body[5] shl 8) or Body[6];
  Info.MaximumFrameSize := (Body[7] shl 16) or (Body[8] shl 8) or Body[9];
  Bits64 := 0;
  for Index := 10 to 17 do
    Bits64 := (Bits64 shl 8) or Body[Index];
  { 20 bits of rate, 3 of channels - 1, 5 of bits - 1, 36 of samples. }
  Info.SampleRate := Integer(Bits64 shr 44);
  Info.Channels := Integer((Bits64 shr 41) and 7) + 1;
  Info.BitsPerSample := Integer((Bits64 shr 36) and 31) + 1;
  Info.TotalSamples := Int64(Bits64 and $FFFFFFFFF);
  Move(Body[18], Info.Md5[0], 16);
  Result := (Info.SampleRate > 0) and (Info.BitsPerSample >= 4) and (Info.Channels >= 1);
end;

function ParseFlacFrameHeader(Data: PByte; Size: Integer; const Info: TFlacStreamInfo;
  out Header: TFlacFrameHeader): Boolean;
const
  RateTable: array[0..11] of Integer = (0, 88200, 176400, 192000, 8000, 16000, 22050, 24000, 32000, 44100,
    48000, 96000);
  SampleSizeTable: array[0..7] of Integer = (0, 8, 12, -1, 16, 20, 24, 32);
var
  Position, BlockCode, RateCode, ChannelCode, SizeCode, Extra, Index: Integer;
  First: Byte;
  Number: Int64;
begin
  Header := Default(TFlacFrameHeader);
  Result := False;
  if Size < 6 then
    Exit;
  if (Data[0] <> $FF) or ((Data[1] and $FE) <> $F8) then
    Exit;
  Header.VariableBlockSize := (Data[1] and 1) <> 0;
  BlockCode := Data[2] shr 4;
  RateCode := Data[2] and 15;
  ChannelCode := Data[3] shr 4;
  SizeCode := (Data[3] shr 1) and 7;
  if (Data[3] and 1) <> 0 then
    Exit;
  if (BlockCode = 0) or (RateCode = 15) or (ChannelCode > 10) or (SizeCode = 3) then
    Exit;
  { The coded number: a UTF-8-like sequence of up to 7 bytes. }
  Position := 4;
  First := Data[Position];
  Inc(Position);
  if First < $80 then
  begin
    Number := First;
    Extra := 0;
  end
  else if (First and $E0) = $C0 then
  begin
    Number := First and $1F;
    Extra := 1;
  end
  else if (First and $F0) = $E0 then
  begin
    Number := First and $0F;
    Extra := 2;
  end
  else if (First and $F8) = $F0 then
  begin
    Number := First and $07;
    Extra := 3;
  end
  else if (First and $FC) = $F8 then
  begin
    Number := First and $03;
    Extra := 4;
  end
  else if (First and $FE) = $FC then
  begin
    Number := First and $01;
    Extra := 5;
  end
  else if First = $FE then
  begin
    Number := 0;
    Extra := 6;
  end
  else
    Exit;
  if Position + Extra + 3 > Size then
    Exit;
  for Index := 1 to Extra do
  begin
    if (Data[Position] and $C0) <> $80 then
      Exit;
    Number := (Number shl 6) or (Data[Position] and $3F);
    Inc(Position);
  end;
  Header.CodedNumber := Number;
  case BlockCode of
    1: Header.BlockSize := 192;
    2..5: Header.BlockSize := 576 shl (BlockCode - 2);
    6:
      begin
        Header.BlockSize := Data[Position] + 1;
        Inc(Position);
      end;
    7:
      begin
        Header.BlockSize := ((Data[Position] shl 8) or Data[Position + 1]) + 1;
        Inc(Position, 2);
      end;
  else
    Header.BlockSize := 256 shl (BlockCode - 8);
  end;
  case RateCode of
    0: Header.SampleRate := Info.SampleRate;
    1..11: Header.SampleRate := RateTable[RateCode];
    12:
      begin
        Header.SampleRate := Data[Position] * 1000;
        Inc(Position);
      end;
    13:
      begin
        Header.SampleRate := (Data[Position] shl 8) or Data[Position + 1];
        Inc(Position, 2);
      end;
    14:
      begin
        Header.SampleRate := ((Data[Position] shl 8) or Data[Position + 1]) * 10;
        Inc(Position, 2);
      end;
  end;
  if Position >= Size then
    Exit;
  if FlacCrc8(Data, Position) <> Data[Position] then
    Exit;
  Inc(Position);
  Header.Length := Position;
  case ChannelCode of
    0..7:
      begin
        Header.Channels := ChannelCode + 1;
        Header.Assignment := caIndependent;
      end;
    8:
      begin
        Header.Channels := 2;
        Header.Assignment := caLeftSide;
      end;
    9:
      begin
        Header.Channels := 2;
        Header.Assignment := caSideRight;
      end;
  else
    begin
      Header.Channels := 2;
      Header.Assignment := caMidSide;
    end;
  end;
  if SizeCode = 0 then
    Header.BitsPerSample := Info.BitsPerSample
  else
    Header.BitsPerSample := SampleSizeTable[SizeCode];
  Result := (Header.SampleRate > 0) and (Header.BitsPerSample >= 4) and (Header.BlockSize > 0);
end;

function FlacFirstSample(const Header: TFlacFrameHeader; const Info: TFlacStreamInfo): Int64;
begin
  if Header.VariableBlockSize then
    Result := Header.CodedNumber
  else if Info.MaximumBlockSize > 0 then
    Result := Header.CodedNumber * Info.MaximumBlockSize
  else
    Result := Header.CodedNumber * Header.BlockSize;
end;

initialization
  BuildTables;
end.
