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
  Uncompressed audio: 8-bit unsigned, 16, 24 and 32-bit signed integer
  and 32 and 64-bit float samples, little or big-endian, interleaved, to
  floats. Integers are divided by 2^(bits - 1), so the conversion is
  exact and reversible.
}
unit Media.Pcm;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Media.Frames,
  Media.Packets,
  Media.AudioDecoders;

type
  TPcmDecoder = class(TAudioDecoder)
  private
    FBits: Integer;
    FFloat, FBigEndian: Boolean;
  public
    procedure Configure(Track: TMediaTrack); override;
    function Decode(const Packet: TMediaPacket; var Output: TAudioBuffer): Boolean; override;
  end;

{ Converts Count samples at Source (Bits wide, Float or integer, BigEndian
  or not) to floats at Target. }
procedure ConvertPcmSamples(Source: PByte; Count, Bits: Integer; Float, BigEndian: Boolean; Target: PSingle);

implementation

uses
  Media.Errors;

function LoadSample(Source: PByte; Bytes: Integer; BigEndian: Boolean): LongWord; inline;
var
  Index: Integer;
begin
  Result := 0;
  if BigEndian then
    for Index := 0 to Bytes - 1 do
      Result := (Result shl 8) or Source[Index]
  else
    for Index := Bytes - 1 downto 0 do
      Result := (Result shl 8) or Source[Index];
end;

procedure ConvertPcmSamples(Source: PByte; Count, Bits: Integer; Float, BigEndian: Boolean; Target: PSingle);
var
  Index, Bytes: Integer;
  Raw: LongWord;
  Raw64: QWord;
  Value: LongInt;
begin
  Bytes := Bits div 8;
  for Index := 0 to Count - 1 do
  begin
    if Float and (Bits = 64) then
    begin
      if BigEndian then
        Raw64 := (QWord(LoadSample(Source, 4, True)) shl 32) or LoadSample(Source + 4, 4, True)
      else
        Raw64 := LoadSample(Source, 4, False) or (QWord(LoadSample(Source + 4, 4, False)) shl 32);
      Target[Index] := PDouble(@Raw64)^;
    end
    else
    begin
      Raw := LoadSample(Source, Bytes, BigEndian);
      if Float then
        Target[Index] := PSingle(@Raw)^
      else
        case Bits of
          8: Target[Index] := (LongInt(Raw) - 128) / 128;
          16: Target[Index] := SmallInt(Raw) / 32768;
          24:
            begin
              Value := LongInt(Raw shl 8) div 256;
              Target[Index] := Value / 8388608;
            end;
        else
          Target[Index] := LongInt(Raw) / 2147483648.0;
        end;
    end;
    Inc(Source, Bytes);
  end;
end;

procedure TPcmDecoder.Configure(Track: TMediaTrack);
begin
  FBits := Track.BitsPerSample;
  FFloat := Track.PcmFloat;
  FBigEndian := Track.PcmBigEndian;
  FSampleRate := Track.SampleRate;
  FChannels := Track.Channels;
  if (FChannels < 1) or (FSampleRate < 1) then
    MediaFail('PCM track without channels or rate');
  if FFloat and not (FBits in [32, 64]) then
    MediaFailUnsupported(Format('%d-bit float PCM', [FBits]));
  if not FFloat and not (FBits in [8, 16, 24, 32]) then
    MediaFailUnsupported(Format('%d-bit PCM', [FBits]));
  FPendingSkip := Track.CodecDelay;
end;

function TPcmDecoder.Decode(const Packet: TMediaPacket; var Output: TAudioBuffer): Boolean;
var
  FrameBytes, Frames: Integer;
begin
  FrameBytes := FChannels * (FBits div 8);
  Frames := Length(Packet.Data) div FrameBytes;
  Output.SampleRate := FSampleRate;
  Output.Channels := FChannels;
  Output.PresentationTime := Packet.PresentationTime;
  Output.Samples := nil;
  SetLength(Output.Samples, Frames * FChannels);
  if Frames > 0 then
    ConvertPcmSamples(@Packet.Data[0], Frames * FChannels, FBits, FFloat, FBigEndian, @Output.Samples[0]);
  ApplyTrim(Output, Packet);
  Result := True;
end;

end.
