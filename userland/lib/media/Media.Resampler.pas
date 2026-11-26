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
  Sample rate conversion: a polyphase windowed-sinc filter (Kaiser
  window, 32 taps per phase when upsampling, proportionally more when
  downsampling so the filter keeps its sharpness at the lower cut-off),
  streaming.

  The output rate over the input rate, reduced, is Up / Down: output
  sample j lies at input time j * Down / Up, whose whole part picks the
  input samples and whose fraction (one of Up phases) picks the filter.
  When Up is too large for a table of its own (rates without a small
  ratio, such as 44100 to 47999), the phase is rounded to one of
  MaximumPhases. The cut-off is just under the lower of the two Nyquist
  frequencies, so downsampling does not alias.

  Process takes interleaved frames and returns what can be computed so
  far (the filter looks half its taps ahead); Flush returns the rest,
  so the output has exactly ceil(InputFrames * Up / Down) frames.
}
unit Media.Resampler;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils;

type
  TSampleArray = array of Single;

  TResampler = class
  private
    FInputRate, FOutputRate, FChannels: Integer;
    FUp, FDown: Int64;
    FPhaseCount: Integer;
    FHalfTaps, FTaps: Integer;
    FFilters: array of Single;
    { Pending input frames (interleaved); FBufferStart is the input frame
      number of the first. }
    FBuffer: TSampleArray;
    FBufferFrames: Integer;
    FBufferStart: Int64;
    { The next output frame's input time, in 1/FUp frames. }
    FPosition: Int64;
    FInputTotal, FOutputTotal: Int64;
    procedure BuildFilters;
    procedure Append(const Samples: TSampleArray; Offset, Frames: Integer);
    function Produce(Limit: Int64): TSampleArray;
  public
    constructor Create(InputRate, OutputRate, Channels: Integer);
    { Interleaved Frames frames of Input; returns the output frames ready. }
    function Process(const Input: TSampleArray; Frames: Integer): TSampleArray;
    { The rest of the output, after the last input. }
    function Flush: TSampleArray;
    procedure Reset;
    property InputRate: Integer read FInputRate;
    property OutputRate: Integer read FOutputRate;
    property Channels: Integer read FChannels;
  end;

const
  { Half the taps at a cut-off of the input's Nyquist frequency. }
  ResamplerHalfTaps = 16;
  ResamplerMaximumHalfTaps = 256;
  ResamplerMaximumPhases = 1024;

implementation

function GreatestCommonDivisor(A, B: Int64): Int64;
var
  Remainder: Int64;
begin
  while B <> 0 do
  begin
    Remainder := A mod B;
    A := B;
    B := Remainder;
  end;
  Result := A;
end;

{ The zeroth-order modified Bessel function, for the Kaiser window. }
function BesselI0(X: Double): Double;
var
  Term, Sum, HalfX: Double;
  K: Integer;
begin
  Sum := 1;
  Term := 1;
  HalfX := X / 2;
  for K := 1 to 40 do
  begin
    Term := Term * (HalfX / K) * (HalfX / K);
    Sum := Sum + Term;
    if Term < Sum * 1e-12 then
      Break;
  end;
  Result := Sum;
end;

constructor TResampler.Create(InputRate, OutputRate, Channels: Integer);
var
  Divisor: Int64;
begin
  inherited Create;
  if (InputRate <= 0) or (OutputRate <= 0) or (Channels <= 0) then
    raise EArgumentException.Create('resampler rates and channels must be positive');
  FInputRate := InputRate;
  FOutputRate := OutputRate;
  FChannels := Channels;
  Divisor := GreatestCommonDivisor(OutputRate, InputRate);
  FUp := OutputRate div Divisor;
  FDown := InputRate div Divisor;
  if FUp <= ResamplerMaximumPhases then
    FPhaseCount := FUp
  else
    FPhaseCount := ResamplerMaximumPhases;
  FHalfTaps := ResamplerHalfTaps;
  if OutputRate < InputRate then
    FHalfTaps := (ResamplerHalfTaps * Int64(InputRate) + OutputRate - 1) div OutputRate;
  if FHalfTaps > ResamplerMaximumHalfTaps then
    FHalfTaps := ResamplerMaximumHalfTaps;
  FTaps := 2 * FHalfTaps;
  BuildFilters;
  Reset;
end;

procedure TResampler.BuildFilters;
const
  KaiserBeta = 8.6;
var
  Phase, Tap: Integer;
  Cutoff, Distance, Window, Ratio, Value, Sum: Double;
begin
  if FOutputRate < FInputRate then
    Cutoff := 0.95 * FOutputRate / FInputRate
  else
    Cutoff := 0.95;
  SetLength(FFilters, FPhaseCount * FTaps);
  for Phase := 0 to FPhaseCount - 1 do
  begin
    Sum := 0;
    for Tap := 0 to FTaps - 1 do
    begin
      { The distance from the output time (frame n + Phase / FPhaseCount)
        back to input frame n - HalfTaps + 1 + Tap. }
      Distance := (FHalfTaps - 1 - Tap) + Phase / FPhaseCount;
      Ratio := Distance / FHalfTaps;
      if Abs(Ratio) >= 1 then
        Window := 0
      else
        Window := BesselI0(KaiserBeta * Sqrt(1 - Ratio * Ratio)) / BesselI0(KaiserBeta);
      if Abs(Distance) < 1e-9 then
        Value := Cutoff
      else
        Value := Sin(Pi * Cutoff * Distance) / (Pi * Distance);
      Value := Value * Window;
      FFilters[Phase * FTaps + Tap] := Value;
      Sum := Sum + Value;
    end;
    { Unity gain at DC for every phase. }
    if Sum <> 0 then
      for Tap := 0 to FTaps - 1 do
        FFilters[Phase * FTaps + Tap] := FFilters[Phase * FTaps + Tap] / Sum;
  end;
end;

procedure TResampler.Reset;
begin
  { HalfTaps - 1 frames of silence before the first input frame, so the
    first output frame is centred on it. }
  FBufferFrames := FHalfTaps - 1;
  SetLength(FBuffer, FBufferFrames * FChannels);
  FillChar(FBuffer[0], Length(FBuffer) * SizeOf(Single), 0);
  FBufferStart := -(FHalfTaps - 1);
  FPosition := 0;
  FInputTotal := 0;
  FOutputTotal := 0;
end;

procedure TResampler.Append(const Samples: TSampleArray; Offset, Frames: Integer);
var
  Needed: Integer;
begin
  if Frames <= 0 then
    Exit;
  Needed := (FBufferFrames + Frames) * FChannels;
  if Length(FBuffer) < Needed then
    SetLength(FBuffer, Needed + Needed div 2);
  if Samples = nil then
    FillChar(FBuffer[FBufferFrames * FChannels], Frames * FChannels * SizeOf(Single), 0)
  else
    Move(Samples[Offset * FChannels], FBuffer[FBufferFrames * FChannels], Frames * FChannels * SizeOf(Single));
  Inc(FBufferFrames, Frames);
end;

function TResampler.Produce(Limit: Int64): TSampleArray;
var
  Count, Capacity, Channel, Tap, Phase: Integer;
  Frame, FirstFrame, Discard: Int64;
  Filter: PSingle;
  Source: PSingle;
  Sum: Double;
begin
  Result := nil;
  Capacity := 0;
  Count := 0;
  while FOutputTotal < Limit do
  begin
    Frame := FPosition div FUp;
    { The last input frame the filter reads must be buffered. }
    if Frame + FHalfTaps >= FBufferStart + FBufferFrames then
      Break;
    if FPhaseCount = FUp then
      Phase := FPosition mod FUp
    else
      Phase := ((FPosition mod FUp) * FPhaseCount + FUp div 2) div FUp;
    FirstFrame := Frame - FHalfTaps + 1;
    if Phase >= FPhaseCount then
    begin
      { Rounded up to the next frame's phase 0. }
      Phase := 0;
      Inc(FirstFrame);
      if FirstFrame + FTaps > FBufferStart + FBufferFrames then
        Break;
    end;
    if Count >= Capacity then
    begin
      Capacity := Capacity * 2 + 256;
      SetLength(Result, Capacity * FChannels);
    end;
    Filter := @FFilters[Phase * FTaps];
    for Channel := 0 to FChannels - 1 do
    begin
      Source := @FBuffer[(FirstFrame - FBufferStart) * FChannels + Channel];
      Sum := 0;
      for Tap := 0 to FTaps - 1 do
      begin
        Sum := Sum + Filter[Tap] * Source^;
        Inc(Source, FChannels);
      end;
      Result[Count * FChannels + Channel] := Sum;
    end;
    Inc(Count);
    Inc(FOutputTotal);
    Inc(FPosition, FDown);
  end;
  SetLength(Result, Count * FChannels);
  { Frames no later output reads go. }
  Discard := FPosition div FUp - FHalfTaps + 1 - FBufferStart;
  if Discard > FBufferFrames then
    Discard := FBufferFrames;
  if Discard > 0 then
  begin
    Move(FBuffer[Discard * FChannels], FBuffer[0], (FBufferFrames - Discard) * FChannels * SizeOf(Single));
    Dec(FBufferFrames, Discard);
    Inc(FBufferStart, Discard);
  end;
end;

function TResampler.Process(const Input: TSampleArray; Frames: Integer): TSampleArray;
begin
  Append(Input, 0, Frames);
  Inc(FInputTotal, Frames);
  Result := Produce(High(Int64));
end;

function TResampler.Flush: TSampleArray;
var
  Expected: Int64;
begin
  Expected := (FInputTotal * FUp + FDown - 1) div FDown;
  Append(nil, 0, FTaps + 1);
  Result := Produce(Expected);
end;

end.
