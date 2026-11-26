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
  What the containers need to know of the audio codecs' packets without
  decoding them: Opus packet durations (the TOC byte, RFC 6716 3.1) and
  the OpusHead fields (RFC 7845 5.1), FLAC frame block sizes and the
  STREAMINFO fields, MPEG audio frame lengths, and which codec an Ogg stream's first packet
  belongs to.
}
unit Media.Ogg.Codecs;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Media.Packets;

type
  TOpusHead = record
    Valid: Boolean;
    Channels: Integer;
    PreSkip: Integer;
    InputRate: Integer;
  end;

  TStreamInfo = record
    Valid: Boolean;
    SampleRate: Integer;
    Channels: Integer;
    BitsPerSample: Integer;
    TotalSamples: Int64;
  end;

{ Samples (at 48 kHz) an Opus packet decodes to; 0 if it is malformed. }
function OpusPacketDuration(const Packet: TBytes): Integer;
function ReadOpusHead(const Head: TBytes): TOpusHead;
{ Samples per channel in the MPEG audio frame Packet starts with (1152
  for MPEG-1 Layer II and III, 576 for MPEG-2 and 2.5 Layer III, 384 for
  Layer I); 0 if it is not one. }
function MpegAudioFrameSamples(const Packet: TBytes): Integer;
{ The block size of the FLAC frame Packet starts with; 0 if it is not one. }
function FlacFrameBlockSize(const Packet: TBytes): Integer;
{ The fields of a 34-byte STREAMINFO block body. }
function ReadStreamInfo(const Body: TBytes): TStreamInfo;
{ The codec of an Ogg stream from its first packet. }
function OggCodecOf(const FirstPacket: TBytes): TCodecId;

implementation

uses
  Media.ByteReaders;

function OpusPacketDuration(const Packet: TBytes): Integer;
var
  Config, FrameSamples, FrameCount: Integer;
begin
  Result := 0;
  if Length(Packet) < 1 then
    Exit;
  Config := Packet[0] shr 3;
  if Config < 12 then
    case Config and 3 of
      0: FrameSamples := 480;
      1: FrameSamples := 960;
      2: FrameSamples := 1920;
    else
      FrameSamples := 2880;
    end
  else if Config < 16 then
  begin
    if (Config and 1) = 0 then
      FrameSamples := 480
    else
      FrameSamples := 960;
  end
  else
    FrameSamples := 120 shl (Config and 3);
  case Packet[0] and 3 of
    0: FrameCount := 1;
    1, 2: FrameCount := 2;
  else
    begin
      if Length(Packet) < 2 then
        Exit;
      FrameCount := Packet[1] and 63;
    end;
  end;
  Result := FrameSamples * FrameCount;
  { RFC 6716: at most 120 ms in a packet. }
  if Result > 5760 then
    Result := 0;
end;

function ReadOpusHead(const Head: TBytes): TOpusHead;
begin
  Result := Default(TOpusHead);
  if (Length(Head) < 19) or (FourCCAt(Head, 0) <> 'Opus') or (FourCCAt(Head, 4) <> 'Head') then
    Exit;
  if (Head[8] and $F0) <> 0 then
    Exit;
  Result.Channels := Head[9];
  Result.PreSkip := LittleEndian16(Head, 10);
  Result.InputRate := LittleEndian32(Head, 12);
  Result.Valid := Result.Channels > 0;
end;

function MpegAudioFrameSamples(const Packet: TBytes): Integer;
var
  Version, Layer: Integer;
begin
  Result := 0;
  if (Length(Packet) < 4) or (Packet[0] <> $FF) or ((Packet[1] and $E0) <> $E0) then
    Exit;
  Version := (Packet[1] shr 3) and 3;
  Layer := (Packet[1] shr 1) and 3;
  case Layer of
    3: Result := 384;
    2: Result := 1152;
    1:
      if Version = 3 then
        Result := 1152
      else
        Result := 576;
  end;
end;

function FlacFrameBlockSize(const Packet: TBytes): Integer;
var
  Code, Position, Extra: Integer;
  First: Byte;
begin
  Result := 0;
  if (Length(Packet) < 6) or (Packet[0] <> $FF) or ((Packet[1] and $FE) <> $F8) then
    Exit;
  Code := Packet[2] shr 4;
  { Past the UTF-8 coded frame or sample number. }
  Position := 4;
  First := Packet[Position];
  Extra := 0;
  if (First and $80) = 0 then
    Extra := 0
  else if (First and $E0) = $C0 then
    Extra := 1
  else if (First and $F0) = $E0 then
    Extra := 2
  else if (First and $F8) = $F0 then
    Extra := 3
  else if (First and $FC) = $F8 then
    Extra := 4
  else if (First and $FE) = $FC then
    Extra := 5
  else if First = $FE then
    Extra := 6
  else
    Exit;
  Inc(Position, 1 + Extra);
  case Code of
    1: Result := 192;
    2..5: Result := 576 shl (Code - 2);
    6:
      if Position < Length(Packet) then
        Result := Packet[Position] + 1;
    7:
      if Position + 1 < Length(Packet) then
        Result := ((Packet[Position] shl 8) or Packet[Position + 1]) + 1;
    8..15: Result := 256 shl (Code - 8);
  end;
end;

function ReadStreamInfo(const Body: TBytes): TStreamInfo;
begin
  Result := Default(TStreamInfo);
  if Length(Body) < 34 then
    Exit;
  Result.SampleRate := (LongWord(Body[10]) shl 12) or (LongWord(Body[11]) shl 4) or (Body[12] shr 4);
  Result.Channels := ((Body[12] shr 1) and 7) + 1;
  Result.BitsPerSample := (((Body[12] and 1) shl 4) or (Body[13] shr 4)) + 1;
  Result.TotalSamples := (Int64(Body[13] and 15) shl 32) or BigEndian32(Body, 14);
  Result.Valid := Result.SampleRate > 0;
end;

function OggCodecOf(const FirstPacket: TBytes): TCodecId;
var
  Length7: Boolean;
begin
  Result := codecUnknown;
  Length7 := Length(FirstPacket) >= 7;
  if (Length(FirstPacket) >= 8) and (FourCCAt(FirstPacket, 0) = 'Opus') and (FourCCAt(FirstPacket, 4) = 'Head') then
    Result := codecOpus
  else if Length7 and (FirstPacket[0] = 1) and (FourCCAt(FirstPacket, 1) = 'vorb') and (FirstPacket[5] = Ord('i'))
    and (FirstPacket[6] = Ord('s')) then
    Result := codecVorbis
  else if (Length(FirstPacket) >= 13) and (FirstPacket[0] = $7F) and (FourCCAt(FirstPacket, 1) = 'FLAC') then
    Result := codecFlac
  else if Length7 and (FirstPacket[0] = $80) and (FourCCAt(FirstPacket, 1) = 'theo') then
    Result := codecTheora;
end;

end.
