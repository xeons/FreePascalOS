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
  MPEG audio frame headers (ISO 11172-3 2.4.1.3, ISO 13818-3 and the
  MPEG-2.5 extension): the 4 bytes that start every frame, what they say
  (version, layer, bit rate, sample rate, channel mode, padding) and how
  long the frame is.

  Two headers belong to the same stream when version, layer, sample rate
  and free format agree (HeadersMatch); that is how frames are found and
  checked (a sync word alone happens by chance in audio data).
}
unit Media.Mp3.Header;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

const
  Mp3HeaderSize = 4;
  { The longest free format frame accepted (more than the standard's
    largest, 320 kbit/s at 32 kHz is 1440). }
  Mp3MaximumFreeFormatBytes = 2304;
  Mp3ModeJointStereo = 1;
  Mp3ModeMono = 3;

function HeaderIsValid(Header: PByte): Boolean;
function HeadersMatch(First, Second: PByte): Boolean;
function HeaderIsMpeg1(Header: PByte): Boolean; inline;
function HeaderIsMpeg25(Header: PByte): Boolean; inline;
function HeaderLayer(Header: PByte): Integer; inline;
function HeaderIsMono(Header: PByte): Boolean; inline;
function HeaderChannels(Header: PByte): Integer; inline;
function HeaderIsMidSideStereo(Header: PByte): Boolean; inline;
function HeaderHasIntensityStereo(Header: PByte): Boolean; inline;
function HeaderHasMidSide(Header: PByte): Boolean; inline;
function HeaderIsFreeFormat(Header: PByte): Boolean; inline;
function HeaderHasCrc(Header: PByte): Boolean; inline;
function HeaderChannelMode(Header: PByte): Integer; inline;
{ The sample rate index over all versions: 0-2 MPEG-2.5, 3-5 MPEG-2,
  6-8 MPEG-1 (44.1, 48, 32 kHz order within each). }
function HeaderRateIndex(Header: PByte): Integer; inline;
function HeaderBitrateKbps(Header: PByte): Integer;
function HeaderSampleRate(Header: PByte): Integer;
function HeaderFrameSamples(Header: PByte): Integer;
function HeaderPadding(Header: PByte): Integer;
{ The frame's length without padding; FreeFormatBytes for a free format
  frame (whose header has no bit rate). }
function HeaderFrameBytes(Header: PByte; FreeFormatBytes: Integer): Integer;
{ The length of a whole frame (with padding). }
function HeaderFullFrameBytes(Header: PByte; FreeFormatBytes: Integer): Integer;

implementation

function HeaderIsMpeg1(Header: PByte): Boolean;
begin
  Result := (Header[1] and $08) <> 0;
end;

function HeaderIsMpeg25(Header: PByte): Boolean;
begin
  Result := (Header[1] and $10) = 0;
end;

function HeaderLayer(Header: PByte): Integer;
begin
  { 1 for layer III, 2 for layer II, 3 for layer I (the field's value). }
  Result := (Header[1] shr 1) and 3;
end;

function HeaderIsMono(Header: PByte): Boolean;
begin
  Result := (Header[3] and $C0) = $C0;
end;

function HeaderChannels(Header: PByte): Integer;
begin
  if HeaderIsMono(Header) then
    Result := 1
  else
    Result := 2;
end;

function HeaderIsMidSideStereo(Header: PByte): Boolean;
begin
  Result := (Header[3] and $E0) = $60;
end;

function HeaderHasIntensityStereo(Header: PByte): Boolean;
begin
  Result := (Header[3] and $10) <> 0;
end;

function HeaderHasMidSide(Header: PByte): Boolean;
begin
  Result := (Header[3] and $20) <> 0;
end;

function HeaderIsFreeFormat(Header: PByte): Boolean;
begin
  Result := (Header[2] and $F0) = 0;
end;

function HeaderHasCrc(Header: PByte): Boolean;
begin
  Result := (Header[1] and 1) = 0;
end;

function HeaderChannelMode(Header: PByte): Integer;
begin
  Result := (Header[3] shr 6) and 3;
end;

function HeaderRateIndex(Header: PByte): Integer;
begin
  Result := ((Header[2] shr 2) and 3) + (((Header[1] shr 3) and 1) + ((Header[1] shr 4) and 1)) * 3;
end;

function HeaderIsValid(Header: PByte): Boolean;
begin
  Result := (Header[0] = $FF) and (((Header[1] and $F0) = $F0) or ((Header[1] and $FE) = $E2))
    and (HeaderLayer(Header) <> 0) and ((Header[2] shr 4) <> 15) and (((Header[2] shr 2) and 3) <> 3);
end;

function HeadersMatch(First, Second: PByte): Boolean;
begin
  Result := HeaderIsValid(Second) and (((First[1] xor Second[1]) and $FE) = 0)
    and (((First[2] xor Second[2]) and $0C) = 0) and (HeaderIsFreeFormat(First) = HeaderIsFreeFormat(Second));
end;

function HeaderBitrateKbps(Header: PByte): Integer;
const
  HalfRates: array[0..1, 0..2, 0..14] of Byte = (
    ((0, 4, 8, 12, 16, 20, 24, 28, 32, 40, 48, 56, 64, 72, 80),
     (0, 4, 8, 12, 16, 20, 24, 28, 32, 40, 48, 56, 64, 72, 80),
     (0, 16, 24, 28, 32, 40, 48, 56, 64, 72, 80, 88, 96, 112, 128)),
    ((0, 16, 20, 24, 28, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160),
     (0, 16, 24, 28, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192),
     (0, 16, 32, 48, 64, 80, 96, 112, 128, 144, 160, 176, 192, 208, 224)));
var
  Version: Integer;
begin
  if HeaderIsMpeg1(Header) then
    Version := 1
  else
    Version := 0;
  Result := 2 * HalfRates[Version, HeaderLayer(Header) - 1, Header[2] shr 4];
end;

function HeaderSampleRate(Header: PByte): Integer;
const
  Rates: array[0..2] of Integer = (44100, 48000, 32000);
begin
  Result := Rates[(Header[2] shr 2) and 3];
  if not HeaderIsMpeg1(Header) then
    Result := Result shr 1;
  if HeaderIsMpeg25(Header) then
    Result := Result shr 1;
end;

function HeaderFrameSamples(Header: PByte): Integer;
begin
  if (Header[1] and 6) = 6 then
    Result := 384
  else if (Header[1] and 14) = 2 then
    Result := 576
  else
    Result := 1152;
end;

function HeaderPadding(Header: PByte): Integer;
begin
  if (Header[2] and 2) = 0 then
    Result := 0
  else if (Header[1] and 6) = 6 then
    Result := 4
  else
    Result := 1;
end;

function HeaderFrameBytes(Header: PByte; FreeFormatBytes: Integer): Integer;
begin
  Result := HeaderFrameSamples(Header) * HeaderBitrateKbps(Header) * 125 div HeaderSampleRate(Header);
  if (Header[1] and 6) = 6 then
    Result := Result and not 3;
  if Result = 0 then
    Result := FreeFormatBytes;
end;

function HeaderFullFrameBytes(Header: PByte; FreeFormatBytes: Integer): Integer;
begin
  Result := HeaderFrameBytes(Header, FreeFormatBytes);
  if Result > 0 then
    Inc(Result, HeaderPadding(Header));
end;

end.
