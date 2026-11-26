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

  This file follows the Opus reference decoder (RFC 6716, libopus 1.5.2),
  which carries this notice:

  Copyright (c) 2001-2011 Xiph.Org, Skype Limited, Octasic,
                          Jean-Marc Valin, Timothy B. Terriberry,
                          CSIRO, Gregory Maxwell, Mark Borgerding,
                          Erik de Castro Lopo

  Redistribution and use in source and binary forms, with or without
  modification, are permitted provided that the following conditions
  are met:
  - Redistributions of source code must retain the above copyright
    notice, this list of conditions and the following disclaimer.
  - Redistributions in binary form must reproduce the above copyright
    notice, this list of conditions and the following disclaimer in the
    documentation and/or other materials provided with the distribution.
  - Neither the name of Internet Society, IETF or IETF Trust, nor the
    names of specific contributors, may be used to endorse or promote
    products derived from this software without specific prior written
    permission.

  THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
  "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
  LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
  A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
  OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
  SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
  LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
  DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
  THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
  (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
  OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
}

{
  Opus packets (RFC 6716 section 3): the table-of-contents byte (mode,
  bandwidth, frame duration, channels) and the frame packing codes 0 to
  3 (one frame, two equal frames, two frames with a length, or up to 48
  frames, constant or variable size, with padding); and the
  self-delimited form multistream packets use (RFC 6716 appendix B).
}
unit Media.Opus.Packets;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

const
  OpusModeSilkOnly = 1000;
  OpusModeHybrid = 1001;
  OpusModeCeltOnly = 1002;
  OpusBandwidthNarrowband = 1101;
  OpusBandwidthMediumband = 1102;
  OpusBandwidthWideband = 1103;
  OpusBandwidthSuperWideband = 1104;
  OpusBandwidthFullband = 1105;
  OpusMaximumFrames = 48;

type
  TOpusFrameSizes = array[0..OpusMaximumFrames - 1] of SmallInt;

function OpusPacketMode(Data: PByte): Integer;
function OpusPacketBandwidth(Data: PByte): Integer;
function OpusPacketSamplesPerFrame(Data: PByte; SampleRate: LongInt): Integer;
function OpusPacketChannels(Data: PByte): Integer;
{ The number of frames in the packet, their sizes and the offset of the
  first; PacketLength is the bytes the packet used (with padding, for
  self-delimited packets). Returns -1 for a malformed packet. }
function OpusParsePacket(Data: PByte; Length: LongInt; SelfDelimited: Boolean; out Sizes: TOpusFrameSizes;
  out PayloadOffset: Integer; out PacketLength: LongInt): Integer;
{ The samples per channel the packet decodes to at SampleRate; -1 if malformed. }
function OpusPacketSampleCount(Data: PByte; Length: LongInt; SampleRate: LongInt): Integer;

implementation

function OpusPacketMode(Data: PByte): Integer;
begin
  if (Data[0] and $80) <> 0 then
    Result := OpusModeCeltOnly
  else if (Data[0] and $60) = $60 then
    Result := OpusModeHybrid
  else
    Result := OpusModeSilkOnly;
end;

function OpusPacketBandwidth(Data: PByte): Integer;
begin
  if (Data[0] and $80) <> 0 then
  begin
    Result := OpusBandwidthMediumband + ((Data[0] shr 5) and 3);
    if Result = OpusBandwidthMediumband then
      Result := OpusBandwidthNarrowband;
  end
  else if (Data[0] and $60) = $60 then
  begin
    if (Data[0] and $10) <> 0 then
      Result := OpusBandwidthFullband
    else
      Result := OpusBandwidthSuperWideband;
  end
  else
    Result := OpusBandwidthNarrowband + ((Data[0] shr 5) and 3);
end;

function OpusPacketSamplesPerFrame(Data: PByte; SampleRate: LongInt): Integer;
var
  Size: Integer;
begin
  if (Data[0] and $80) <> 0 then
  begin
    Size := (Data[0] shr 3) and 3;
    Result := (SampleRate shl Size) div 400;
  end
  else if (Data[0] and $60) = $60 then
  begin
    if (Data[0] and $08) <> 0 then
      Result := SampleRate div 50
    else
      Result := SampleRate div 100;
  end
  else
  begin
    Size := (Data[0] shr 3) and 3;
    if Size = 3 then
      Result := SampleRate * 60 div 1000
    else
      Result := (SampleRate shl Size) div 100;
  end;
end;

function OpusPacketChannels(Data: PByte): Integer;
begin
  if (Data[0] and 4) <> 0 then
    Result := 2
  else
    Result := 1;
end;

function ParseSize(Data: PByte; Length: LongInt; out Size: SmallInt): Integer;
begin
  if Length < 1 then
  begin
    Size := -1;
    Result := -1;
  end
  else if Data[0] < 252 then
  begin
    Size := Data[0];
    Result := 1;
  end
  else if Length < 2 then
  begin
    Size := -1;
    Result := -1;
  end
  else
  begin
    Size := 4 * Data[1] + Data[0];
    Result := 2;
  end;
end;

function OpusParsePacket(Data: PByte; Length: LongInt; SelfDelimited: Boolean; out Sizes: TOpusFrameSizes;
  out PayloadOffset: Integer; out PacketLength: LongInt): Integer;
var
  Index, Bytes, Count, FrameSize, Padding, PadByte, Temp: Integer;
  Constant: Boolean;
  LastSize: LongInt;
  Start: PByte;
  Control, Toc: Byte;
begin
  FillChar(Sizes, SizeOf(Sizes), 0);
  PayloadOffset := 0;
  PacketLength := 0;
  if Length <= 0 then
    Exit(-1);
  Start := Data;
  FrameSize := OpusPacketSamplesPerFrame(Data, 48000);
  Constant := False;
  Padding := 0;
  Toc := Data^;
  Inc(Data);
  Dec(Length);
  LastSize := Length;
  case Toc and 3 of
    0: Count := 1;
    1:
      begin
        Count := 2;
        Constant := True;
        if not SelfDelimited then
        begin
          if (Length and 1) <> 0 then
            Exit(-1);
          LastSize := Length div 2;
          Sizes[0] := LastSize;
        end;
      end;
    2:
      begin
        Count := 2;
        Bytes := ParseSize(Data, Length, Sizes[0]);
        Dec(Length, Bytes);
        if (Sizes[0] < 0) or (Sizes[0] > Length) then
          Exit(-1);
        Inc(Data, Bytes);
        LastSize := Length - Sizes[0];
      end;
  else
    begin
      if Length < 1 then
        Exit(-1);
      Control := Data^;
      Inc(Data);
      Count := Control and $3F;
      if (Count <= 0) or (FrameSize * Count > 5760) then
        Exit(-1);
      Dec(Length);
      if (Control and $40) <> 0 then
        repeat
          if Length <= 0 then
            Exit(-1);
          PadByte := Data^;
          Inc(Data);
          Dec(Length);
          if PadByte = 255 then
            Temp := 254
          else
            Temp := PadByte;
          Dec(Length, Temp);
          Inc(Padding, Temp);
        until PadByte <> 255;
      if Length < 0 then
        Exit(-1);
      Constant := (Control and $80) = 0;
      if not Constant then
      begin
        LastSize := Length;
        for Index := 0 to Count - 2 do
        begin
          Bytes := ParseSize(Data, Length, Sizes[Index]);
          Dec(Length, Bytes);
          if (Sizes[Index] < 0) or (Sizes[Index] > Length) then
            Exit(-1);
          Inc(Data, Bytes);
          Dec(LastSize, Bytes + Sizes[Index]);
        end;
        if LastSize < 0 then
          Exit(-1);
      end
      else if not SelfDelimited then
      begin
        LastSize := Length div Count;
        if LastSize * Count <> Length then
          Exit(-1);
        for Index := 0 to Count - 2 do
          Sizes[Index] := LastSize;
      end;
    end;
  end;
  if SelfDelimited then
  begin
    Bytes := ParseSize(Data, Length, Sizes[Count - 1]);
    Dec(Length, Bytes);
    if (Sizes[Count - 1] < 0) or (Sizes[Count - 1] > Length) then
      Exit(-1);
    Inc(Data, Bytes);
    if Constant then
    begin
      if Sizes[Count - 1] * Count > Length then
        Exit(-1);
      for Index := 0 to Count - 2 do
        Sizes[Index] := Sizes[Count - 1];
    end
    else if Bytes + Sizes[Count - 1] > LastSize then
      Exit(-1);
  end
  else
  begin
    if LastSize > 1275 then
      Exit(-1);
    Sizes[Count - 1] := LastSize;
  end;
  PayloadOffset := Data - Start;
  for Index := 0 to Count - 1 do
    Inc(Data, Sizes[Index]);
  PacketLength := Padding + (Data - Start);
  Result := Count;
end;

function OpusPacketSampleCount(Data: PByte; Length: LongInt; SampleRate: LongInt): Integer;
var
  Count: Integer;
begin
  if Length < 1 then
    Exit(-1);
  case Data[0] and 3 of
    0: Count := 1;
    1, 2: Count := 2;
  else
    begin
      if Length < 2 then
        Exit(-1);
      Count := Data[1] and $3F;
    end;
  end;
  Result := Count * OpusPacketSamplesPerFrame(Data, SampleRate);
  if Result * 25 > SampleRate * 3 then
    Result := -1;
end;

end.
