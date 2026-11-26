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
  The audio decoder: what every audio codec is.

  Configure takes the track (its Headers, rate and channels); Decode
  then turns one packet into a buffer of interleaved floats in the WAVE
  channel order (Media.Frames), applying the packet's TrimStart and
  TrimEnd and the codec's own start delay. A packet can decode to no
  samples (Vorbis' first). Reset forgets the state carried from packet
  to packet, for a seek.

  A broken packet raises EMediaError; the decoder can be given the next
  one.
}
unit Media.AudioDecoders;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Media.Frames,
  Media.Packets;

type
  TAudioDecoder = class
  protected
    FSampleRate: Integer;
    FChannels: Integer;
    { Samples still to drop at the start (codec delay), decremented as
      they are dropped by ApplyTrim. }
    FPendingSkip: Integer;
    { Drops FPendingSkip, then TrimStart and TrimEnd frames, from Buffer. }
    procedure ApplyTrim(var Buffer: TAudioBuffer; const Packet: TMediaPacket);
  public
    constructor Create; virtual;
    procedure Configure(Track: TMediaTrack); virtual; abstract;
    function Decode(const Packet: TMediaPacket; var Output: TAudioBuffer): Boolean; virtual; abstract;
    procedure Reset; virtual;
    property SampleRate: Integer read FSampleRate;
    property Channels: Integer read FChannels;
  end;

  TAudioDecoderClass = class of TAudioDecoder;

{ Removes Count sample frames from the start (FromStart) or the end of
  Buffer (all of them if there are fewer). }
procedure DropAudioFrames(var Buffer: TAudioBuffer; Count: Integer; FromStart: Boolean);

implementation

procedure DropAudioFrames(var Buffer: TAudioBuffer; Count: Integer; FromStart: Boolean);
var
  Frames, Remaining, Channels: Integer;
begin
  if Count <= 0 then
    Exit;
  Channels := Buffer.Channels;
  Frames := AudioFrameCount(Buffer);
  if Count >= Frames then
  begin
    SetLength(Buffer.Samples, 0);
    Exit;
  end;
  Remaining := Frames - Count;
  if FromStart then
    Move(Buffer.Samples[Count * Channels], Buffer.Samples[0], Remaining * Channels * SizeOf(Single));
  SetLength(Buffer.Samples, Remaining * Channels);
end;

constructor TAudioDecoder.Create;
begin
  inherited Create;
end;

procedure TAudioDecoder.ApplyTrim(var Buffer: TAudioBuffer; const Packet: TMediaPacket);
var
  Frames, Skipped: Integer;
begin
  if FPendingSkip > 0 then
  begin
    Frames := AudioFrameCount(Buffer);
    Skipped := FPendingSkip;
    if Skipped > Frames then
      Skipped := Frames;
    DropAudioFrames(Buffer, Skipped, True);
    Dec(FPendingSkip, Skipped);
  end;
  DropAudioFrames(Buffer, Packet.TrimEnd, False);
  DropAudioFrames(Buffer, Packet.TrimStart, True);
end;

procedure TAudioDecoder.Reset;
begin
end;

end.
