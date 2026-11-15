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
  The reverb effect: the sound of a room, after Jezar's Freeverb.

  Each pair of channels feeds eight comb filters in parallel (delay
  lines feeding back through a low-pass, the room's echoes dying away)
  and then four all-pass filters in series (which smear the echoes into
  a wash). The right channel's delays are a little longer than the
  left's, so the two sound apart. A channel left without a partner (in a
  mono or 5.1 voice) gets a bank of its own.

    RoomSize   0 to 1: how long the echoes last
    Damping    0 to 1: how quickly high frequencies die away
    WetLevel   how loud the reverb is
    DryLevel   how loud the sound itself is
    Width      0 to 1: how far apart the two sides' reverb sounds

  The delay lines are made when the effect first runs, for the voice's
  rate and channels (the tunings are for 44.1 kHz, and scaled).
}
unit Audio.Effects.Reverb;

{$mode objfpc}
{$pointermath on}

interface

uses
  Audio.EffectChain;

type
  TReverbParameters = record
    RoomSize: Single;
    Damping: Single;
    WetLevel: Single;
    DryLevel: Single;
    Width: Single;
  end;

function DefaultReverbParameters: TReverbParameters;
function CreateReverb(const Parameters: TReverbParameters): PAudioEffect;

implementation

uses
  Sys.Memory;

const
  CombCount = 8;
  AllPassCount = 4;
  CombTunings: array[0..CombCount - 1] of LongWord = (1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617);
  AllPassTunings: array[0..AllPassCount - 1] of LongWord = (556, 441, 341, 225);
  StereoSpread = 23;
  TuningRate = 44100;
  InputGain = 0.015;
  WetScale = 3;
  AllPassFeedback = 0.5;
  { The most channels a reverb takes, as banks: one per channel. }
  MaximumBanks = 8;

type
  TDelayLine = record
    Samples: PSingle;
    Length: LongWord;
    Position: LongWord;
    { Combs: the low-pass in their feedback. }
    Stored: Single;
  end;

  TBank = record
    Combs: array[0..CombCount - 1] of TDelayLine;
    AllPasses: array[0..AllPassCount - 1] of TDelayLine;
  end;

  PReverbState = ^TReverbState;
  TReverbState = record
    Parameters: TReverbParameters;
    Rate: LongWord;
    Channels: LongWord;
    Banks: array[0..MaximumBanks - 1] of TBank;
    BankCount: LongWord;
  end;

function DefaultReverbParameters: TReverbParameters;
begin
  Result.RoomSize := 0.5;
  Result.Damping := 0.5;
  Result.WetLevel := 1 / WetScale;
  Result.DryLevel := 1;
  Result.Width := 1;
end;

function Feedback(const Parameters: TReverbParameters): Single;
begin
  Result := Parameters.RoomSize * 0.28 + 0.7;
end;

procedure FreeLines(State: PReverbState);
var
  Bank: LongWord;
  Index: Integer;
begin
  for Bank := 0 to MaximumBanks - 1 do
  begin
    for Index := 0 to CombCount - 1 do
      FreeMemory(State^.Banks[Bank].Combs[Index].Samples);
    for Index := 0 to AllPassCount - 1 do
      FreeMemory(State^.Banks[Bank].AllPasses[Index].Samples);
  end;
  FillChar(State^.Banks, SizeOf(State^.Banks), 0);
  State^.BankCount := 0;
end;

function MakeLine(out Line: TDelayLine; Tuning, Spread, Rate: LongWord): Boolean;
begin
  FillChar(Line, SizeOf(Line), 0);
  Line.Length := QWord(Tuning + Spread) * Rate div TuningRate;
  if Line.Length < 1 then
    Line.Length := 1;
  Line.Samples := PSingle(AllocateMemory(Line.Length * SizeOf(Single)));
  Result := Line.Samples <> nil;
  if Result then
    FillChar(Line.Samples^, Line.Length * SizeOf(Single), 0);
end;

{ Banks for Rate and Channels: the odd ones (the right of a pair) with
  the spread. False if out of memory. }
function PrepareBanks(State: PReverbState; Rate, Channels: LongWord): Boolean;
var
  Bank: LongWord;
  Spread: LongWord;
  Index: Integer;
begin
  if (State^.BankCount > 0) and (State^.Rate = Rate) and (State^.Channels = Channels) then
    Exit(True);
  FreeLines(State);
  if Channels > MaximumBanks then
    Channels := MaximumBanks;
  State^.Rate := Rate;
  State^.Channels := Channels;
  for Bank := 0 to Channels - 1 do
  begin
    Spread := (Bank mod 2) * StereoSpread;
    for Index := 0 to CombCount - 1 do
      if not MakeLine(State^.Banks[Bank].Combs[Index], CombTunings[Index], Spread, Rate) then
        Exit(False);
    for Index := 0 to AllPassCount - 1 do
      if not MakeLine(State^.Banks[Bank].AllPasses[Index], AllPassTunings[Index], Spread, Rate) then
        Exit(False);
  end;
  State^.BankCount := Channels;
  Result := True;
end;

function RunComb(var Line: TDelayLine; Input, Feedback, Damping: Single): Single;
begin
  Result := Line.Samples[Line.Position];
  Line.Stored := Result * (1 - Damping) + Line.Stored * Damping;
  Line.Samples[Line.Position] := Input + Line.Stored * Feedback;
  Line.Position := (Line.Position + 1) mod Line.Length;
end;

function RunAllPass(var Line: TDelayLine; Input: Single): Single;
var
  Delayed: Single;
begin
  Delayed := Line.Samples[Line.Position];
  Result := Delayed - Input;
  Line.Samples[Line.Position] := Input + Delayed * AllPassFeedback;
  Line.Position := (Line.Position + 1) mod Line.Length;
end;

{ The reverb of one bank for a frame's Input. }
function RunBank(var Bank: TBank; Input, Feedback, Damping: Single): Single;
var
  Index: Integer;
begin
  Result := 0;
  for Index := 0 to CombCount - 1 do
    Result := Result + RunComb(Bank.Combs[Index], Input, Feedback, Damping);
  for Index := 0 to AllPassCount - 1 do
    Result := RunAllPass(Bank.AllPasses[Index], Result);
end;

procedure ReverbProcess(Effect: PAudioEffect; Samples: PSingle; Frames, Channels, Rate: LongWord);
var
  State: PReverbState;
  RoomFeedback: Single;
  Damping: Single;
  Wet: Single;
  WetSame: Single;
  WetOther: Single;
  Dry: Single;
  Frame: LongWord;
  Channel: LongWord;
  Input: Single;
  Left: Single;
  Right: Single;
  Paired: LongWord;
  Base: LongWord;
begin
  State := PReverbState(Effect^.State);
  if not PrepareBanks(State, Rate, Channels) then
    Exit;
  RoomFeedback := Feedback(State^.Parameters);
  Damping := State^.Parameters.Damping * 0.4;
  Wet := State^.Parameters.WetLevel * WetScale;
  WetSame := Wet * (State^.Parameters.Width / 2 + 0.5);
  WetOther := Wet * ((1 - State^.Parameters.Width) / 2);
  Dry := State^.Parameters.DryLevel;
  if Channels > MaximumBanks then
    Channels := MaximumBanks;
  { Channels in pairs share their input, and cross their outputs by the
    width; one left over is on its own. }
  Paired := Channels - Channels mod 2;
  for Frame := 0 to Frames - 1 do
  begin
    Channel := 0;
    while Channel < Paired do
    begin
      Base := Frame * Channels + Channel;
      Input := (Samples[Base] + Samples[Base + 1]) * InputGain;
      Left := RunBank(State^.Banks[Channel], Input, RoomFeedback, Damping);
      Right := RunBank(State^.Banks[Channel + 1], Input, RoomFeedback, Damping);
      Samples[Base] := Left * WetSame + Right * WetOther + Samples[Base] * Dry;
      Samples[Base + 1] := Right * WetSame + Left * WetOther + Samples[Base + 1] * Dry;
      Inc(Channel, 2);
    end;
    if Paired < Channels then
    begin
      Base := Frame * Channels + Paired;
      Input := Samples[Base] * 2 * InputGain;
      Left := RunBank(State^.Banks[Paired], Input, RoomFeedback, Damping);
      Samples[Base] := Left * (WetSame + WetOther) + Samples[Base] * Dry;
    end;
  end;
end;

procedure ReverbSetParameters(Effect: PAudioEffect; Parameters: Pointer; Size: LongWord);
var
  Wanted: TReverbParameters;
begin
  if Size <> SizeOf(TReverbParameters) then
    Exit;
  Wanted := TReverbParameters(Parameters^);
  if (Wanted.RoomSize < 0) or (Wanted.RoomSize > 1) or (Wanted.Damping < 0) or (Wanted.Damping > 1) or
     (Wanted.Width < 0) or (Wanted.Width > 1) or (Wanted.WetLevel < 0) or (Wanted.DryLevel < 0) then
    Exit;
  PReverbState(Effect^.State)^.Parameters := Wanted;
end;

procedure ReverbGetParameters(Effect: PAudioEffect; Parameters: Pointer; Size: LongWord);
begin
  if Size = SizeOf(TReverbParameters) then
    TReverbParameters(Parameters^) := PReverbState(Effect^.State)^.Parameters;
end;

procedure ReverbReset(Effect: PAudioEffect);
var
  State: PReverbState;
  Bank: LongWord;
  Index: Integer;
begin
  State := PReverbState(Effect^.State);
  for Bank := 0 to State^.BankCount - 1 do
    with State^.Banks[Bank] do
    begin
      for Index := 0 to CombCount - 1 do
      begin
        FillChar(Combs[Index].Samples^, Combs[Index].Length * SizeOf(Single), 0);
        Combs[Index].Stored := 0;
      end;
      for Index := 0 to AllPassCount - 1 do
        FillChar(AllPasses[Index].Samples^, AllPasses[Index].Length * SizeOf(Single), 0);
    end;
end;

procedure ReverbRelease(Effect: PAudioEffect);
begin
  FreeLines(PReverbState(Effect^.State));
  FreeEffect(Effect);
end;

{ Until the longest comb's echoes fall under a thousandth (-60 dB). }
function ReverbTail(Effect: PAudioEffect; Rate: LongWord): LongWord;
var
  Gain: Single;
  Rounds: Single;
  Longest: Single;
begin
  Gain := Feedback(PReverbState(Effect^.State)^.Parameters);
  Rounds := Ln(0.001) / Ln(Gain);
  Longest := (CombTunings[CombCount - 1] + StereoSpread) * Rate / TuningRate;
  Result := Round(Rounds * Longest);
end;

function CreateReverb(const Parameters: TReverbParameters): PAudioEffect;
begin
  Result := CreateEffect(SizeOf(TReverbState));
  if Result = nil then
    Exit;
  Result^.Process := @ReverbProcess;
  Result^.SetParameters := @ReverbSetParameters;
  Result^.GetParameters := @ReverbGetParameters;
  Result^.Reset := @ReverbReset;
  Result^.Release := @ReverbRelease;
  Result^.TailFrames := @ReverbTail;
  PReverbState(Result^.State)^.Parameters := DefaultReverbParameters;
  ReverbSetParameters(Result, @Parameters, SizeOf(Parameters));
end;

end.
