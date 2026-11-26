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
  Multistream Opus (RFC 7845 section 5.1.1, RFC 6716 appendix B): up to
  255 streams in one packet, all but the last self-delimited, the first
  CoupledCount of them stereo; the channel mapping says which stream
  channel each output channel is (255: silence). Also the soft clipper
  the reference applies before 16-bit output.
}
unit Media.Opus.Multistream;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  Media.Opus.StreamDecoder;

type
  TOpusMultistreamDecoder = class
  private
    FSampleRate: LongInt;
    FChannels: Integer;
    FStreamCount: Integer;
    FCoupledCount: Integer;
    FMapping: array[0..254] of Byte;
    FStreams: array of TOpusStreamDecoder;
    FBuffer: array of Single;
    function GetFinalRange: LongWord;
  public
    { Mapping has Channels entries. }
    constructor Create(SampleRate: LongInt; Channels, StreamCount, CoupledCount: Integer; const Mapping: array of Byte);
    destructor Destroy; override;
    procedure Reset;
    procedure SetGain(GainQ8: Integer);
    { Decodes a packet (Data = nil: conceal FrameSize samples) into Pcm
      (Channels interleaved, room for FrameSize per channel); returns the
      samples per channel or -1. }
    function Decode(Data: PByte; Length: LongInt; Pcm: PSingle; FrameSize: Integer; DecodeFec: Boolean): Integer;
    property Channels: Integer read FChannels;
    property SampleRate: LongInt read FSampleRate;
    { The XOR of the streams' final ranges (one stream: its own). }
    property FinalRange: LongWord read GetFinalRange;
  end;

{ The reference's soft clipper over N frames of C channels: keeps
  samples within -1..1 without hard edges; Memory (C entries) carries
  the clipping state from call to call. }
procedure OpusSoftClip(X: PSingle; N, C: Integer; Memory: PSingle);

implementation

uses
  Math;

constructor TOpusMultistreamDecoder.Create(SampleRate: LongInt; Channels, StreamCount, CoupledCount: Integer;
  const Mapping: array of Byte);
var
  Index: Integer;
begin
  inherited Create;
  FSampleRate := SampleRate;
  FChannels := Channels;
  FStreamCount := StreamCount;
  FCoupledCount := CoupledCount;
  for Index := 0 to Channels - 1 do
    FMapping[Index] := Mapping[Index];
  SetLength(FStreams, StreamCount);
  for Index := 0 to StreamCount - 1 do
    if Index < CoupledCount then
      FStreams[Index] := TOpusStreamDecoder.Create(SampleRate, 2)
    else
      FStreams[Index] := TOpusStreamDecoder.Create(SampleRate, 1);
  SetLength(FBuffer, 2 * 5760);
end;

destructor TOpusMultistreamDecoder.Destroy;
var
  Index: Integer;
begin
  for Index := 0 to High(FStreams) do
    FStreams[Index].Free;
  inherited Destroy;
end;

procedure TOpusMultistreamDecoder.Reset;
var
  Index: Integer;
begin
  for Index := 0 to High(FStreams) do
    FStreams[Index].Reset;
end;

procedure TOpusMultistreamDecoder.SetGain(GainQ8: Integer);
var
  Index: Integer;
begin
  for Index := 0 to High(FStreams) do
    FStreams[Index].DecodeGain := GainQ8;
end;

function TOpusMultistreamDecoder.GetFinalRange: LongWord;
var
  Index: Integer;
begin
  Result := 0;
  for Index := 0 to High(FStreams) do
    Result := Result xor FStreams[Index].FinalRange;
end;

function TOpusMultistreamDecoder.Decode(Data: PByte; Length: LongInt; Pcm: PSingle; FrameSize: Integer;
  DecodeFec: Boolean): Integer;
var
  Stream, Channel, Index, Returned, Samples, StreamChannel, StreamChannels: Integer;
  PacketLength: LongInt;
  Lost: Boolean;
  Source: Integer;
begin
  if FrameSize > 5760 then
    FrameSize := 5760;
  Lost := (Data = nil) or (Length = 0);
  Samples := FrameSize;
  for Channel := 0 to FChannels - 1 do
    for Index := 0 to FrameSize - 1 do
      Pcm[Index * FChannels + Channel] := 0;
  Returned := FrameSize;
  for Stream := 0 to FStreamCount - 1 do
  begin
    if Lost then
      Returned := FStreams[Stream].Decode(nil, 0, @FBuffer[0], FrameSize, DecodeFec, False, PacketLength)
    else
    begin
      if Length <= 0 then
        Exit(-1);
      Returned := FStreams[Stream].Decode(Data, Length, @FBuffer[0], FrameSize, DecodeFec,
        Stream <> FStreamCount - 1, PacketLength);
      if Stream <> FStreamCount - 1 then
      begin
        Inc(Data, PacketLength);
        Dec(Length, PacketLength);
      end;
    end;
    if Returned < 0 then
      Exit(-1);
    if Stream = 0 then
      Samples := Returned
    else if Returned <> Samples then
      Exit(-1);
    StreamChannels := FStreams[Stream].Channels;
    for Channel := 0 to FChannels - 1 do
    begin
      Source := FMapping[Channel];
      if Source = 255 then
        Continue;
      if Stream < FCoupledCount then
      begin
        if Source div 2 <> Stream then
          Continue;
        StreamChannel := Source mod 2;
      end
      else
      begin
        if Source - FCoupledCount <> Stream then
          Continue;
        StreamChannel := 0;
      end;
      for Index := 0 to Samples - 1 do
        Pcm[Index * FChannels + Channel] := FBuffer[Index * StreamChannels + StreamChannel];
    end;
  end;
  Result := Samples;
end;

procedure OpusSoftClip(X: PSingle; N, C: Integer; Memory: PSingle);
var
  Channel, Index, Current, Start, Finish, PeakPosition: Integer;
  A, X0, MaximumValue, Delta, Offset: Single;
  Pointer: PSingle;
  Special: Boolean;
begin
  if (C < 1) or (N < 1) then
    Exit;
  for Index := 0 to N * C - 1 do
    X[Index] := Max(-2.0, Min(2.0, X[Index]));
  for Channel := 0 to C - 1 do
  begin
    Pointer := X + Channel;
    A := Memory[Channel];
    for Index := 0 to N - 1 do
    begin
      if Pointer[Index * C] * A >= 0 then
        Break;
      Pointer[Index * C] := Pointer[Index * C] + A * Pointer[Index * C] * Pointer[Index * C];
    end;
    Current := 0;
    X0 := Pointer[0];
    while True do
    begin
      Index := Current;
      while Index < N do
      begin
        if (Pointer[Index * C] > 1) or (Pointer[Index * C] < -1) then
          Break;
        Inc(Index);
      end;
      if Index = N then
      begin
        A := 0;
        Break;
      end;
      PeakPosition := Index;
      Start := Index;
      Finish := Index;
      MaximumValue := Abs(Pointer[Index * C]);
      while (Start > 0) and (Pointer[Index * C] * Pointer[(Start - 1) * C] >= 0) do
        Dec(Start);
      while (Finish < N) and (Pointer[Index * C] * Pointer[Finish * C] >= 0) do
      begin
        if Abs(Pointer[Finish * C]) > MaximumValue then
        begin
          MaximumValue := Abs(Pointer[Finish * C]);
          PeakPosition := Finish;
        end;
        Inc(Finish);
      end;
      Special := (Start = 0) and (Pointer[Index * C] * Pointer[0] >= 0);
      A := (MaximumValue - 1) / (MaximumValue * MaximumValue);
      A := A + A * 2.4e-7;
      if Pointer[Index * C] > 0 then
        A := -A;
      for Index := Start to Finish - 1 do
        Pointer[Index * C] := Pointer[Index * C] + A * Pointer[Index * C] * Pointer[Index * C];
      if Special and (PeakPosition >= 2) then
      begin
        Offset := X0 - Pointer[0];
        Delta := Offset / PeakPosition;
        for Index := Current to PeakPosition - 1 do
        begin
          Offset := Offset - Delta;
          Pointer[Index * C] := Pointer[Index * C] + Offset;
          Pointer[Index * C] := Max(-1.0, Min(1.0, Pointer[Index * C]));
        end;
      end;
      Current := Finish;
      if Current = N then
        Break;
    end;
    Memory[Channel] := A;
  end;
end;

end.
