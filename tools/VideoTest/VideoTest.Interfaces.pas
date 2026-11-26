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
  libvideo's interface: codec names, the frame records' layout and
  colour fields, timestamps, the IVF reader's checks, and the boolean
  decoder against a stream written here bit by bit.
}
unit VideoTest.Interfaces;

{$mode objfpc}
{$H+}

interface

{ Checks the interface with the streams of Directory. }
procedure CheckInterfaces(const Directory: string);

implementation

uses
  SysUtils, TestChecks, Media.Frames, Media.Packets, Media.VideoDecoders, Video.BoolDecoder, Video.Ivf,
  Video.MediaDecoders, VideoTest.Streams;

procedure CheckCodecNames;
var
  Decoder: TVideoDecoder;
begin
  Check(VideoDecoderRegistered(codecVp8) and VideoDecoderRegistered(codecVp9), 'VP8 and VP9 registered with libmedia');
  Decoder := CreateVideoDecoder(codecVp8);
  Check(Decoder is TVp8MediaDecoder, 'a VP8 decoder');
  Decoder.Free;
  Decoder := CreateVideoDecoder(codecVp9);
  Check(Decoder is TVp9MediaDecoder, 'a VP9 decoder');
  Decoder.Free;
end;

{ Encodes Bits (with their probabilities) as VP8's boolean encoder does
  (RFC 6386 section 7.3). }
function EncodeBools(const Bits, Probabilities: array of LongInt): TBytes;
var
  Low, Range, Split: LongWord;
  BitCount, Index, Shift: LongInt;
  Output: TBytes;
  Count: LongInt;

  procedure AddOne(Position: LongInt);
  begin
    while (Position >= 0) and (Output[Position] = 255) do
    begin
      Output[Position] := 0;
      Dec(Position);
    end;
    if Position >= 0 then
      Inc(Output[Position]);
  end;

  procedure Emit(Value: Byte);
  begin
    if Count >= Length(Output) then
      SetLength(Output, 2 * Count + 16);
    Output[Count] := Value;
    Inc(Count);
  end;

begin
  Output := nil;
  Count := 0;
  Low := 0;
  Range := 255;
  BitCount := 24;
  for Index := 0 to High(Bits) do
  begin
    Split := 1 + (((Range - 1) * LongWord(Probabilities[Index])) shr 8);
    if Bits[Index] <> 0 then
    begin
      Low := Low + Split;
      Range := Range - Split;
    end
    else
      Range := Split;
    while Range < 128 do
    begin
      Range := Range shl 1;
      if (Low and (LongWord(1) shl 31)) <> 0 then
        AddOne(Count - 1);
      Low := Low shl 1;
      Dec(BitCount);
      if BitCount = 0 then
      begin
        Emit(Byte(Low shr 24));
        Low := Low and $FFFFFF;
        BitCount := 8;
      end;
    end;
  end;
  for Shift := 0 to 31 do
  begin
    if (Low and (LongWord(1) shl 31)) <> 0 then
      AddOne(Count - 1);
    Low := Low shl 1;
    Dec(BitCount);
    if BitCount = 0 then
    begin
      Emit(Byte(Low shr 24));
      Low := Low and $FFFFFF;
      BitCount := 8;
    end;
  end;
  SetLength(Output, Count);
  Result := Output;
end;

procedure CheckBoolDecoder;
var
  Bits, Probabilities: array of LongInt;
  Data: TBytes;
  Decoder: TBoolDecoder;
  Index, Mismatches: LongInt;
  State: LongWord;
begin
  SetLength(Bits, 5000);
  SetLength(Probabilities, 5000);
  State := 1;
  for Index := 0 to High(Bits) do
  begin
    State := LongWord((QWord(State) * 1664525 + 1013904223) and $FFFFFFFF);
    Probabilities[Index] := 1 + (State shr 24) mod 255;
    State := LongWord((QWord(State) * 1664525 + 1013904223) and $FFFFFFFF);
    Bits[Index] := Ord(LongInt((State shr 24) and 255) >= Probabilities[Index]);
  end;
  Data := EncodeBools(Bits, Probabilities);
  Decoder.Init(@Data[0], Length(Data));
  Mismatches := 0;
  for Index := 0 to High(Bits) do
    if Decoder.ReadBool(Probabilities[Index]) <> Bits[Index] then
      Inc(Mismatches);
  Check(Mismatches = 0, 'the boolean decoder reads what a boolean encoder wrote (5000 bits)');
  Check(not Decoder.HasError, 'no error reading within the data');
  for Index := 0 to 200 do
    Decoder.ReadBit;
  Check(Decoder.HasError, 'reading past the end is noticed');
end;

procedure CheckIvf(const Directory: string);
var
  Data: TBytes;
  Reader: TIvfReader;
  Frame: TIvfFrame;
  Count: LongInt;
  Refused: Boolean;
begin
  Data := LoadFile(IncludeTrailingPathDelimiter(Directory) + 'vp9-default.ivf');
  Reader := TIvfReader.Create(Data);
  try
    Check(Reader.FourCC = 'VP90', 'IVF four character code');
    Check((Reader.Width = 176) and (Reader.Height = 144), 'IVF size');
    Count := 0;
    while Reader.ReadFrame(Frame) do
      Inc(Count);
    Check(Count = 30, 'IVF frames');
  finally
    Reader.Free;
  end;
  Refused := False;
  try
    TIvfReader.Create(Copy(Data, 4, 100)).Free;
  except
    on EIvfError do
      Refused := True;
  end;
  Check(Refused, 'not an IVF file is refused');
  Refused := False;
  SetLength(Data, 60);
  Reader := TIvfReader.Create(Data);
  try
    try
      while Reader.ReadFrame(Frame) do;
    except
      on EIvfError do
        Refused := True;
    end;
  finally
    Reader.Free;
  end;
  Check(Refused, 'a cut IVF frame is refused');
end;

procedure CheckFrameRecords(const Directory: string);
var
  Reader: TIvfReader;
  Decoder: TVideoDecoder;
  Packet: TIvfFrame;
  Frame: TVideoFrame;
  Got: Boolean;
begin
  Reader := TIvfReader.Create(LoadFile(IncludeTrailingPathDelimiter(Directory) + 'vp9-profile2-10bit.ivf'));
  Decoder := CreateIvfDecoder(Reader.FourCC, 1);
  try
    Got := False;
    while (not Got) and Reader.ReadFrame(Packet) do
    begin
      Decoder.SendPacket(MakePacket(Packet.Data, Packet.Timestamp + 1000));
      Got := Decoder.ReceiveFrame(Frame);
    end;
    Check(Got, 'a 10-bit picture');
    Check((Frame.Width = 176) and (Frame.Height = 144) and (Frame.BitDepth = 10) and (Frame.Layout = pl420),
      '10-bit 4:2:0 frame record');
    Check((Frame.Planes[1].Width = 88) and (Frame.Planes[1].Height = 72) and (Frame.Planes[0].Stride = 352),
      'plane sizes and strides (2 bytes a sample)');
    Check(Frame.PresentationTime = Packet.Timestamp + 1000, 'the packet''s timestamp');
  finally
    Decoder.Free;
    Reader.Free;
  end;
  Reader := TIvfReader.Create(LoadFile(IncludeTrailingPathDelimiter(Directory) + 'vp8-profile2.ivf'));
  Decoder := CreateIvfDecoder(Reader.FourCC, 1);
  try
    Got := False;
    while (not Got) and Reader.ReadFrame(Packet) do
    begin
      Decoder.SendPacket(MakePacket(Packet.Data, Packet.Timestamp));
      Got := Decoder.ReceiveFrame(Frame);
    end;
    Check(Got and (Frame.Width = 99) and (Frame.Height = 67) and (Frame.Planes[1].Width = 50) and
      (Frame.Planes[1].Height = 34) and (Frame.BitDepth = 8) and (Frame.MatrixCoefficients = 6) and
      not Frame.FullRange, 'VP8 frame record (odd size, BT.601 limited range)');
  finally
    Decoder.Free;
    Reader.Free;
  end;
end;

procedure CheckInterfaces(const Directory: string);
begin
  CheckCodecNames;
  CheckBoolDecoder;
  CheckIvf(Directory);
  CheckFrameRecords(Directory);
end;

end.
