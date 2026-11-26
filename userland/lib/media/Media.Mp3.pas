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
  The MPEG audio Layer III decoder (MPEG-1, MPEG-2 LSF and MPEG-2.5; all
  bit rates, free format, mono, stereo, mid/side and intensity stereo):
  the audio decoder libmedia gives MP3 tracks.

  Packets can be whole frames (an .mp3 file, MP4, Matroska) or any
  pieces of the stream (MP3 in WAV): what arrives is gathered, and
  frames are taken from it as they are complete. Finding the first frame
  (and finding the stream again after damage) needs a header that matches
  the next frame's; after that each frame whose header matches the last
  is taken as soon as it is all there. Bytes that are no frame (tags,
  garbage) are skipped.

  The output starts with the track's CodecDelay (the encoder's delay
  plus the decoder's 529 samples, from a LAME tag) dropped, and each
  packet's TrimEnd is honoured (the encoder's padding at the end).
}
unit Media.Mp3;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  SysUtils,
  Media.Frames,
  Media.Packets,
  Media.AudioDecoders,
  Media.Mp3.FrameDecoder;

type
  TMp3Decoder = class(TAudioDecoder)
  private
    FFrameDecoder: TMp3FrameDecoder;
    FInput: TBytes;
    FInputStart, FInputEnd: Integer;
    FLastHeader: array[0..3] of Byte;
    FSynchronised: Boolean;
    FFreeFormatBytes: Integer;
    FFrameSamples: array[0..Mp3MaximumFrameSamples - 1] of Single;
    FConfiguredDelay: Integer;
    procedure Append(const Data: TBytes);
    procedure Consume(Count: Integer);
    { The length of the next frame at the start of the input, 0 if more
      data is needed; skips what is no frame. }
    function NextFrameBytes: Integer;
    function FindFrame(out FrameBytes: Integer): Boolean;
    procedure AddSamples(var Output: TAudioBuffer; var Count: Integer; Frames, ChannelCount: Integer);
  public
    constructor Create; override;
    destructor Destroy; override;
    procedure Configure(Track: TMediaTrack); override;
    function Decode(const Packet: TMediaPacket; var Output: TAudioBuffer): Boolean; override;
    procedure Reset; override;
  end;

implementation

uses
  Media.Errors,
  Media.Mp3.Header;

constructor TMp3Decoder.Create;
begin
  inherited Create;
  FFrameDecoder := TMp3FrameDecoder.Create;
end;

destructor TMp3Decoder.Destroy;
begin
  FFrameDecoder.Free;
  inherited Destroy;
end;

procedure TMp3Decoder.Configure(Track: TMediaTrack);
begin
  FSampleRate := Track.SampleRate;
  FChannels := Track.Channels;
  FConfiguredDelay := Track.CodecDelay;
  FPendingSkip := FConfiguredDelay;
  FInputStart := 0;
  FInputEnd := 0;
  FSynchronised := False;
end;

procedure TMp3Decoder.Reset;
begin
  FFrameDecoder.Reset;
  FInputStart := 0;
  FInputEnd := 0;
  FSynchronised := False;
  FPendingSkip := 0;
end;

procedure TMp3Decoder.Append(const Data: TBytes);
var
  Count: Integer;
begin
  Count := Length(Data);
  if Count = 0 then
    Exit;
  if FInputStart > 0 then
  begin
    if FInputEnd > FInputStart then
      Move(FInput[FInputStart], FInput[0], FInputEnd - FInputStart);
    Dec(FInputEnd, FInputStart);
    FInputStart := 0;
  end;
  if FInputEnd + Count > Length(FInput) then
    SetLength(FInput, (FInputEnd + Count) * 2);
  Move(Data[0], FInput[FInputEnd], Count);
  Inc(FInputEnd, Count);
end;

procedure TMp3Decoder.Consume(Count: Integer);
begin
  Inc(FInputStart, Count);
  if FInputStart >= FInputEnd then
  begin
    FInputStart := 0;
    FInputEnd := 0;
  end;
end;

function TMp3Decoder.FindFrame(out FrameBytes: Integer): Boolean;
var
  Available, Offset, Size, Probe, NextSize: Integer;
  Here: PByte;
begin
  FrameBytes := 0;
  Available := FInputEnd - FInputStart;
  Offset := 0;
  while Offset <= Available - Mp3HeaderSize do
  begin
    Here := @FInput[FInputStart + Offset];
    if HeaderIsValid(Here) and (HeaderLayer(Here) = 1) then
    begin
      Size := 0;
      if HeaderIsFreeFormat(Here) then
      begin
        { Free format: the frame ends where the next matching header is. }
        Probe := Mp3HeaderSize;
        while (Probe < Mp3MaximumFreeFormatBytes) and (Offset + Probe + Mp3HeaderSize <= Available) do
        begin
          if HeadersMatch(Here, Here + Probe) then
          begin
            NextSize := Probe - HeaderPadding(Here) + HeaderPadding(Here + Probe);
            if (Offset + Probe + NextSize + Mp3HeaderSize > Available) or HeadersMatch(Here, Here + Probe + NextSize) then
            begin
              Size := Probe;
              FFreeFormatBytes := Probe - HeaderPadding(Here);
              Break;
            end;
          end;
          Inc(Probe);
        end;
        if (Size = 0) and (Offset + Mp3MaximumFreeFormatBytes + Mp3HeaderSize > Available) then
        begin
          { Maybe more data shows the next header. }
          Consume(Offset);
          Exit(False);
        end;
      end
      else
        Size := HeaderFullFrameBytes(Here, FFreeFormatBytes);
      if Size > 0 then
      begin
        if Offset + Size > Available then
        begin
          Consume(Offset);
          Exit(False);
        end;
        if Offset + Size = Available then
        begin
          { A whole frame and nothing after it: a packet of one frame. }
          Consume(Offset);
          FrameBytes := Size;
          Exit(True);
        end;
        if Offset + Size + Mp3HeaderSize > Available then
        begin
          Consume(Offset);
          Exit(False);
        end;
        if HeadersMatch(Here, Here + Size) then
        begin
          Consume(Offset);
          FrameBytes := Size;
          Exit(True);
        end;
      end;
    end;
    Inc(Offset);
  end;
  { Nothing yet: keep the last bytes, which may start a header. }
  if Available > Mp3HeaderSize - 1 then
    Consume(Available - (Mp3HeaderSize - 1));
  Result := False;
end;

function TMp3Decoder.NextFrameBytes: Integer;
var
  Available, Size: Integer;
  Here: PByte;
begin
  Result := 0;
  Available := FInputEnd - FInputStart;
  if Available < Mp3HeaderSize then
    Exit;
  Here := @FInput[FInputStart];
  if FSynchronised and HeadersMatch(@FLastHeader[0], Here) then
  begin
    Size := HeaderFullFrameBytes(Here, FFreeFormatBytes);
    if (Size > Mp3HeaderSize) and (Size <= Available) then
      Exit(Size);
    if Size > Available then
      Exit(0);
  end;
  FSynchronised := False;
  if FindFrame(Size) then
  begin
    FSynchronised := True;
    Result := Size;
  end;
end;

procedure TMp3Decoder.AddSamples(var Output: TAudioBuffer; var Count: Integer; Frames, ChannelCount: Integer);
var
  Needed: Integer;
begin
  Needed := (Count + Frames) * ChannelCount;
  if Length(Output.Samples) < Needed then
    SetLength(Output.Samples, Needed);
  Move(FFrameSamples[0], Output.Samples[Count * ChannelCount], Frames * ChannelCount * SizeOf(Single));
  Inc(Count, Frames);
end;

function TMp3Decoder.Decode(const Packet: TMediaPacket; var Output: TAudioBuffer): Boolean;
var
  FrameBytes, Count, Frames, ChannelCount, Rate: Integer;
  Here: PByte;
  Status: TMp3FrameStatus;
begin
  Append(Packet.Data);
  Output.Samples := nil;
  Output.PresentationTime := Packet.PresentationTime;
  Output.SampleRate := FSampleRate;
  Output.Channels := FChannels;
  Count := 0;
  repeat
    FrameBytes := NextFrameBytes;
    if FrameBytes = 0 then
      Break;
    Here := @FInput[FInputStart];
    Move(Here^, FLastHeader[0], Mp3HeaderSize);
    ChannelCount := HeaderChannels(Here);
    Rate := HeaderSampleRate(Here);
    Frames := HeaderFrameSamples(Here);
    if (Count > 0) and ((ChannelCount <> Output.Channels) or (Rate <> Output.SampleRate)) then
      { The stream changed format: the rest waits for the next call. }
      Break;
    Output.Channels := ChannelCount;
    Output.SampleRate := Rate;
    FChannels := ChannelCount;
    FSampleRate := Rate;
    Status := FFrameDecoder.DecodeFrame(Here, FrameBytes, @FFrameSamples[0]);
    Consume(FrameBytes);
    if Status = mfUnsupported then
      MediaFailUnsupported('MPEG audio layers I and II are not decoded');
    AddSamples(Output, Count, Frames, ChannelCount);
  until False;
  if Output.Channels > 0 then
    SetLength(Output.Samples, Count * Output.Channels);
  ApplyTrim(Output, Packet);
  Result := True;
end;

end.
