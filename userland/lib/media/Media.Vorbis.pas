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
  The Vorbis I decoder (Xiph.Org Vorbis I specification).

  Configured from the three header packets (Track.Headers; a single
  Xiph-laced block, as Matroska's CodecPrivate, is split too), it
  decodes each audio packet (section 4.3): the mode and window flags,
  each channel's floor, the residues of each submap, inverse coupling,
  floor times residue, the inverse MDCT, the window, and the overlap with
  the previous block. A packet returns the samples from the centre of
  the previous block to the centre of its own, so the first returns none.
  Channels come out in the WAVE order (Media.Frames), reordered from
  Vorbis' (section 4.3.9) for 3 to 8 channels.
}
unit Media.Vorbis;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  SysUtils,
  Media.Frames,
  Media.Packets,
  Media.AudioDecoders,
  Media.Vorbis.BitReader,
  Media.Vorbis.Floors,
  Media.Vorbis.Residues,
  Media.Vorbis.Headers,
  Media.Vorbis.Mdct;

type
  TVorbisChannelState = record
    Spectrum: array of Single;
    Samples: array of Single;
    { The windowed second half of the previous block. }
    Previous: array of Single;
    Floor: TFloorChannelData;
  end;

  TVorbisDecoder = class(TAudioDecoder)
  private
    FSetup: TVorbisSetup;
    FMdcts: array[0..1] of TVorbisMdct;
    { Rising window slopes for the short and the long block sides. }
    FSlopes: array[0..1] of array of Single;
    FChannelStates: array of TVorbisChannelState;
    FFloorUnused: TChannelFlags;
    FDoNotDecode: TChannelFlags;
    FSubmapVectors: TResidueVectors;
    FSubmapFlags: TChannelFlags;
    FCurve: array of Single;
    FHavePrevious: Boolean;
    FPreviousLength, FPreviousRightStart: Integer;
    { Output channel j takes Vorbis channel FChannelOrder[j]. }
    FChannelOrder: array of Integer;
    procedure Prepare;
    procedure DecodeSpectra(var Reader: TVorbisBitReader; const Mapping: TVorbisMapping; HalfSize: Integer);
    procedure ApplyWindow(var State: TVorbisChannelState; Size, LeftStart, LeftEnd, RightStart, RightEnd: Integer);
  public
    destructor Destroy; override;
    procedure Configure(Track: TMediaTrack); override;
    { Configures from the three header packets directly. }
    procedure ConfigureFromHeaders(const Identification, Comment, Setup: TBytes);
    function Decode(const Packet: TMediaPacket; var Output: TAudioBuffer): Boolean; override;
    procedure Reset; override;
  end;

{ Splits a Xiph-laced block of header packets (a count less one, the
  sizes of all but the last in 255-runs, then the packets); nil if it is
  not one. }
function SplitXiphLacedHeaders(const Block: TBytes): THeaderPackets;

implementation

uses
  Media.Errors;

function SplitXiphLacedHeaders(const Block: TBytes): THeaderPackets;
var
  Count, Index, Position, Size, Total: Integer;
  Sizes: array of Integer;
begin
  Result := nil;
  if Length(Block) < 1 then
    Exit;
  Count := Block[0] + 1;
  Sizes := nil;
  SetLength(Sizes, Count);
  Position := 1;
  Total := 0;
  for Index := 0 to Count - 2 do
  begin
    Size := 0;
    repeat
      if Position >= Length(Block) then
        Exit(nil);
      Inc(Size, Block[Position]);
      Inc(Position);
    until Block[Position - 1] <> 255;
    Sizes[Index] := Size;
    Inc(Total, Size);
  end;
  Sizes[Count - 1] := Length(Block) - Position - Total;
  if Sizes[Count - 1] < 0 then
    Exit(nil);
  SetLength(Result, Count);
  for Index := 0 to Count - 1 do
  begin
    SetLength(Result[Index], Sizes[Index]);
    if Sizes[Index] > 0 then
      Move(Block[Position], Result[Index][0], Sizes[Index]);
    Inc(Position, Sizes[Index]);
  end;
end;

destructor TVorbisDecoder.Destroy;
begin
  FSetup.Free;
  FMdcts[0].Free;
  FMdcts[1].Free;
  inherited Destroy;
end;

procedure TVorbisDecoder.Configure(Track: TMediaTrack);
var
  Headers: THeaderPackets;
begin
  Headers := Track.Headers;
  if (Length(Headers) = 1) and not IsVorbisHeader(Headers[0], 1) then
    Headers := SplitXiphLacedHeaders(Headers[0]);
  if Length(Headers) < 3 then
    MediaFail('Vorbis track without its three headers');
  ConfigureFromHeaders(Headers[0], Headers[1], Headers[2]);
  FPendingSkip := Track.CodecDelay;
end;

procedure TVorbisDecoder.ConfigureFromHeaders(const Identification, Comment, Setup: TBytes);
begin
  FreeAndNil(FSetup);
  FSetup := TVorbisSetup.Create;
  FSetup.ReadIdentification(Identification);
  FSetup.ReadComment(Comment);
  FSetup.ReadSetup(Setup);
  FSampleRate := FSetup.SampleRate;
  FChannels := FSetup.Channels;
  Prepare;
  Reset;
end;

procedure TVorbisDecoder.Prepare;
const
  { Vorbis channel order to the WAVE order, by channel count. }
  Order3: array[0..2] of Integer = (0, 2, 1);
  Order5: array[0..4] of Integer = (0, 2, 1, 3, 4);
  Order6: array[0..5] of Integer = (0, 2, 1, 5, 3, 4);
  Order7: array[0..6] of Integer = (0, 2, 1, 6, 5, 3, 4);
  Order8: array[0..7] of Integer = (0, 2, 1, 7, 5, 6, 3, 4);
var
  SizeIndex, Index, Side, Channel, LongHalf: Integer;
  Inner: Double;
begin
  for SizeIndex := 0 to 1 do
  begin
    FreeAndNil(FMdcts[SizeIndex]);
    FMdcts[SizeIndex] := TVorbisMdct.Create(FSetup.BlockSizes[SizeIndex]);
    Side := FSetup.BlockSizes[SizeIndex] div 2;
    SetLength(FSlopes[SizeIndex], Side);
    for Index := 0 to Side - 1 do
    begin
      Inner := Sin((Index + 0.5) / Side * Pi / 2);
      FSlopes[SizeIndex][Index] := Sin(Pi / 2 * Inner * Inner);
    end;
  end;
  LongHalf := FSetup.BlockSizes[1] div 2;
  SetLength(FChannelStates, FChannels);
  for Channel := 0 to FChannels - 1 do
  begin
    SetLength(FChannelStates[Channel].Spectrum, LongHalf);
    SetLength(FChannelStates[Channel].Samples, FSetup.BlockSizes[1]);
    SetLength(FChannelStates[Channel].Previous, LongHalf);
  end;
  SetLength(FFloorUnused, FChannels);
  SetLength(FDoNotDecode, FChannels);
  SetLength(FSubmapVectors, FChannels);
  SetLength(FSubmapFlags, FChannels);
  SetLength(FCurve, LongHalf);
  SetLength(FChannelOrder, FChannels);
  for Channel := 0 to FChannels - 1 do
    case FChannels of
      3: FChannelOrder[Channel] := Order3[Channel];
      5: FChannelOrder[Channel] := Order5[Channel];
      6: FChannelOrder[Channel] := Order6[Channel];
      7: FChannelOrder[Channel] := Order7[Channel];
      8: FChannelOrder[Channel] := Order8[Channel];
    else
      FChannelOrder[Channel] := Channel;
    end;
end;

procedure TVorbisDecoder.Reset;
begin
  FHavePrevious := False;
  FPreviousLength := 0;
  FPreviousRightStart := 0;
end;

procedure TVorbisDecoder.DecodeSpectra(var Reader: TVorbisBitReader; const Mapping: TVorbisMapping;
  HalfSize: Integer);
var
  Channel, Step, Submap, Count, Index: Integer;
  Magnitude, Angle: PSingle;
  MagnitudeValue, AngleValue: Single;
begin
  for Channel := 0 to FChannels - 1 do
  begin
    Submap := Mapping.Mux[Channel];
    FFloorUnused[Channel] := not FSetup.Floors[Mapping.SubmapFloors[Submap]].Decode(Reader, FSetup.Codebooks,
      FChannelStates[Channel].Floor);
    FDoNotDecode[Channel] := FFloorUnused[Channel];
  end;
  { Coupled channels are decoded if either of them is used. }
  for Step := 0 to Mapping.CouplingSteps - 1 do
    if not FDoNotDecode[Mapping.Magnitudes[Step]] or not FDoNotDecode[Mapping.Angles[Step]] then
    begin
      FDoNotDecode[Mapping.Magnitudes[Step]] := False;
      FDoNotDecode[Mapping.Angles[Step]] := False;
    end;
  for Submap := 0 to Mapping.Submaps - 1 do
  begin
    Count := 0;
    for Channel := 0 to FChannels - 1 do
      if Mapping.Mux[Channel] = Submap then
      begin
        FSubmapVectors[Count] := @FChannelStates[Channel].Spectrum[0];
        FSubmapFlags[Count] := FDoNotDecode[Channel];
        Inc(Count);
      end;
    if Count > 0 then
      FSetup.Residues[Mapping.SubmapResidues[Submap]].Decode(Reader, FSetup.Codebooks, FSubmapVectors,
        FSubmapFlags, Count, HalfSize);
  end;
  for Step := Mapping.CouplingSteps - 1 downto 0 do
  begin
    Magnitude := @FChannelStates[Mapping.Magnitudes[Step]].Spectrum[0];
    Angle := @FChannelStates[Mapping.Angles[Step]].Spectrum[0];
    for Index := 0 to HalfSize - 1 do
    begin
      MagnitudeValue := Magnitude[Index];
      AngleValue := Angle[Index];
      if MagnitudeValue > 0 then
      begin
        if AngleValue > 0 then
          Angle[Index] := MagnitudeValue - AngleValue
        else
        begin
          Angle[Index] := MagnitudeValue;
          Magnitude[Index] := MagnitudeValue + AngleValue;
        end;
      end
      else if AngleValue > 0 then
        Angle[Index] := MagnitudeValue + AngleValue
      else
      begin
        Angle[Index] := MagnitudeValue;
        Magnitude[Index] := MagnitudeValue - AngleValue;
      end;
    end;
  end;
  for Channel := 0 to FChannels - 1 do
    if FFloorUnused[Channel] then
      FillChar(FChannelStates[Channel].Spectrum[0], HalfSize * SizeOf(Single), 0)
    else
    begin
      FSetup.Floors[Mapping.SubmapFloors[Mapping.Mux[Channel]]].Synthesize(FChannelStates[Channel].Floor, HalfSize,
        @FCurve[0]);
      for Index := 0 to HalfSize - 1 do
        FChannelStates[Channel].Spectrum[Index] := FChannelStates[Channel].Spectrum[Index] * FCurve[Index];
    end;
end;

procedure TVorbisDecoder.ApplyWindow(var State: TVorbisChannelState; Size, LeftStart, LeftEnd, RightStart,
  RightEnd: Integer);
var
  Index: Integer;
  Slope: PSingle;
  Samples: PSingle;
begin
  Samples := @State.Samples[0];
  for Index := 0 to LeftStart - 1 do
    Samples[Index] := 0;
  if LeftEnd - LeftStart = FSetup.BlockSizes[0] div 2 then
    Slope := @FSlopes[0][0]
  else
    Slope := @FSlopes[1][0];
  for Index := LeftStart to LeftEnd - 1 do
    Samples[Index] := Samples[Index] * Slope[Index - LeftStart];
  if RightEnd - RightStart = FSetup.BlockSizes[0] div 2 then
    Slope := @FSlopes[0][0]
  else
    Slope := @FSlopes[1][0];
  for Index := RightStart to RightEnd - 1 do
    Samples[Index] := Samples[Index] * Slope[RightEnd - 1 - Index];
  for Index := RightEnd to Size - 1 do
    Samples[Index] := 0;
end;

function TVorbisDecoder.Decode(const Packet: TMediaPacket; var Output: TAudioBuffer): Boolean;
var
  Reader: TVorbisBitReader;
  ModeNumber, Size, HalfSize, LeftStart, LeftEnd, RightStart, RightEnd, ShortQuarter, Count, Frame, Channel,
  OutputChannel, Source: Integer;
  PreviousFlag, NextFlag: Boolean;
  Mode: TVorbisMode;
  State: ^TVorbisChannelState;
  Value: Single;
  Target: PSingle;
begin
  Result := True;
  Output.SampleRate := FSampleRate;
  Output.Channels := FChannels;
  Output.PresentationTime := Packet.PresentationTime;
  Output.Samples := nil;
  if FSetup = nil then
    MediaFail('Vorbis decoder not configured');
  if Length(Packet.Data) = 0 then
    Exit;
  StartBitReader(Reader, @Packet.Data[0], Length(Packet.Data));
  { Header packets (odd type bytes) carry no audio. }
  if ReadBit(Reader) then
    Exit;
  ModeNumber := ReadBits(Reader, VorbisIntegerLog(Length(FSetup.Modes) - 1));
  if Reader.EndOfPacket then
    Exit;
  if ModeNumber >= Length(FSetup.Modes) then
    MediaFail('Vorbis packet names a missing mode');
  Mode := FSetup.Modes[ModeNumber];
  if Mode.LongBlock then
  begin
    Size := FSetup.BlockSizes[1];
    PreviousFlag := ReadBit(Reader);
    NextFlag := ReadBit(Reader);
  end
  else
  begin
    Size := FSetup.BlockSizes[0];
    PreviousFlag := False;
    NextFlag := False;
  end;
  HalfSize := Size div 2;
  ShortQuarter := FSetup.BlockSizes[0] div 4;
  if Mode.LongBlock and not PreviousFlag then
  begin
    LeftStart := Size div 4 - ShortQuarter;
    LeftEnd := Size div 4 + ShortQuarter;
  end
  else
  begin
    LeftStart := 0;
    LeftEnd := HalfSize;
  end;
  if Mode.LongBlock and not NextFlag then
  begin
    RightStart := Size * 3 div 4 - ShortQuarter;
    RightEnd := Size * 3 div 4 + ShortQuarter;
  end
  else
  begin
    RightStart := HalfSize;
    RightEnd := Size;
  end;
  DecodeSpectra(Reader, FSetup.Mappings[Mode.Mapping], HalfSize);
  for Channel := 0 to FChannels - 1 do
  begin
    State := @FChannelStates[Channel];
    FMdcts[Ord(Mode.LongBlock)].Inverse(@State^.Spectrum[0], @State^.Samples[0]);
    ApplyWindow(State^, Size, LeftStart, LeftEnd, RightStart, RightEnd);
  end;
  if FHavePrevious then
  begin
    Count := FPreviousRightStart + (HalfSize - LeftStart);
    SetLength(Output.Samples, Count * FChannels);
    for OutputChannel := 0 to FChannels - 1 do
    begin
      Source := FChannelOrder[OutputChannel];
      State := @FChannelStates[Source];
      Target := @Output.Samples[OutputChannel];
      for Frame := 0 to Count - 1 do
      begin
        if Frame < FPreviousLength then
          Value := State^.Previous[Frame]
        else
          Value := 0;
        if Frame >= FPreviousRightStart then
          Value := Value + State^.Samples[Frame - FPreviousRightStart + LeftStart];
        Target[Frame * FChannels] := Value;
      end;
    end;
  end;
  { Keep the second half, up to where the right window ends. }
  FPreviousLength := RightEnd - HalfSize;
  FPreviousRightStart := RightStart - HalfSize;
  for Channel := 0 to FChannels - 1 do
    Move(FChannelStates[Channel].Samples[HalfSize], FChannelStates[Channel].Previous[0],
      FPreviousLength * SizeOf(Single));
  FHavePrevious := True;
  ApplyTrim(Output, Packet);
end;

end.
