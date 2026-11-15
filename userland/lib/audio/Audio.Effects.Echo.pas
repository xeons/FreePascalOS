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
  The echo effect: the sound comes back after DelayMilliseconds, and
  again, each time Feedback times as loud. WetDryMix is how much of the
  output is echo (0: none, 1: only the echo).

  The delay line holds up to MaximumEchoMilliseconds of every channel;
  it is made when the effect first runs, for the voice's rate and
  channels, and again if they change.
}
unit Audio.Effects.Echo;

{$mode objfpc}
{$pointermath on}

interface

uses
  Audio.EffectChain;

const
  MaximumEchoMilliseconds = 2000;

type
  TEchoParameters = record
    WetDryMix: Single;
    Feedback: Single;
    DelayMilliseconds: Single;
  end;

function DefaultEchoParameters: TEchoParameters;
function CreateEcho(const Parameters: TEchoParameters): PAudioEffect;

implementation

uses
  Sys.Memory;

type
  PEchoState = ^TEchoState;
  TEchoState = record
    Parameters: TEchoParameters;
    Line: PSingle;
    LineFrames: LongWord;
    Rate: LongWord;
    Channels: LongWord;
    Position: LongWord;
  end;

function DefaultEchoParameters: TEchoParameters;
begin
  Result.WetDryMix := 0.5;
  Result.Feedback := 0.5;
  Result.DelayMilliseconds := 500;
end;

{ Makes the delay line for Rate and Channels; False if out of memory. }
function PrepareLine(State: PEchoState; Rate, Channels: LongWord): Boolean;
begin
  if (State^.Line <> nil) and (State^.Rate = Rate) and (State^.Channels = Channels) then
    Exit(True);
  FreeMemory(State^.Line);
  State^.LineFrames := QWord(Rate) * MaximumEchoMilliseconds div 1000;
  State^.Line := PSingle(AllocateMemory(State^.LineFrames * Channels * SizeOf(Single)));
  State^.Rate := Rate;
  State^.Channels := Channels;
  State^.Position := 0;
  if State^.Line = nil then
    Exit(False);
  FillChar(State^.Line^, State^.LineFrames * Channels * SizeOf(Single), 0);
  Result := True;
end;

procedure EchoProcess(Effect: PAudioEffect; Samples: PSingle; Frames, Channels, Rate: LongWord);
var
  State: PEchoState;
  Delay: LongWord;
  Frame: LongWord;
  Channel: LongWord;
  ReadAt: LongWord;
  Input: Single;
  Echoed: Single;
  Wet: Single;
begin
  State := PEchoState(Effect^.State);
  if not PrepareLine(State, Rate, Channels) then
    Exit;
  Delay := Round(State^.Parameters.DelayMilliseconds * Rate / 1000);
  if Delay < 1 then
    Delay := 1;
  if Delay > State^.LineFrames then
    Delay := State^.LineFrames;
  Wet := State^.Parameters.WetDryMix;
  for Frame := 0 to Frames - 1 do
  begin
    ReadAt := (State^.Position + State^.LineFrames - Delay) mod State^.LineFrames;
    for Channel := 0 to Channels - 1 do
    begin
      Input := Samples[Frame * Channels + Channel];
      Echoed := State^.Line[ReadAt * Channels + Channel];
      State^.Line[State^.Position * Channels + Channel] := Input + Echoed * State^.Parameters.Feedback;
      Samples[Frame * Channels + Channel] := Input * (1 - Wet) + Echoed * Wet;
    end;
    State^.Position := (State^.Position + 1) mod State^.LineFrames;
  end;
end;

procedure EchoSetParameters(Effect: PAudioEffect; Parameters: Pointer; Size: LongWord);
var
  Wanted: TEchoParameters;
begin
  if Size <> SizeOf(TEchoParameters) then
    Exit;
  Wanted := TEchoParameters(Parameters^);
  if (Wanted.WetDryMix < 0) or (Wanted.WetDryMix > 1) or (Wanted.Feedback < 0) or (Wanted.Feedback >= 1) or
     (Wanted.DelayMilliseconds < 1) or (Wanted.DelayMilliseconds > MaximumEchoMilliseconds) then
    Exit;
  PEchoState(Effect^.State)^.Parameters := Wanted;
end;

procedure EchoGetParameters(Effect: PAudioEffect; Parameters: Pointer; Size: LongWord);
begin
  if Size = SizeOf(TEchoParameters) then
    TEchoParameters(Parameters^) := PEchoState(Effect^.State)^.Parameters;
end;

procedure EchoReset(Effect: PAudioEffect);
var
  State: PEchoState;
begin
  State := PEchoState(Effect^.State);
  if State^.Line <> nil then
    FillChar(State^.Line^, State^.LineFrames * State^.Channels * SizeOf(Single), 0);
end;

procedure EchoRelease(Effect: PAudioEffect);
begin
  FreeMemory(PEchoState(Effect^.State)^.Line);
  FreeEffect(Effect);
end;

{ Until the echoes fall under a thousandth (-60 dB). }
function EchoTail(Effect: PAudioEffect; Rate: LongWord): LongWord;
var
  Parameters: ^TEchoParameters;
  Repeats: Single;
begin
  Parameters := @PEchoState(Effect^.State)^.Parameters;
  if Parameters^.Feedback <= 0.001 then
    Repeats := 1
  else
    Repeats := 1 + Ln(0.001) / Ln(Parameters^.Feedback);
  Result := Round(Repeats * Parameters^.DelayMilliseconds * Rate / 1000);
end;

function CreateEcho(const Parameters: TEchoParameters): PAudioEffect;
begin
  Result := CreateEffect(SizeOf(TEchoState));
  if Result = nil then
    Exit;
  Result^.Process := @EchoProcess;
  Result^.SetParameters := @EchoSetParameters;
  Result^.GetParameters := @EchoGetParameters;
  Result^.Reset := @EchoReset;
  Result^.Release := @EchoRelease;
  Result^.TailFrames := @EchoTail;
  PEchoState(Result^.State)^.Parameters := DefaultEchoParameters;
  EchoSetParameters(Result, @Parameters, SizeOf(Parameters));
end;

end.
