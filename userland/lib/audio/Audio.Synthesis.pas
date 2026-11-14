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
  Tone synthesis: sine waves as 16-bit samples, made with a table of a
  sine's quarter period and a fixed point phase, so a tone keeps its
  pitch exactly over any length and pieces join without clicks.
}
unit Audio.Synthesis;

{$mode objfpc}
{$pointermath on}

interface

type
  TToneGenerator = record
    { Phase and step per sample, in 1/2^32 of a period. }
    Phase: LongWord;
    Step: LongWord;
    Amplitude: LongInt;
  end;

{ A tone of Frequency Hz at Rate samples a second; Amplitude 0-32767. }
procedure StartTone(out Generator: TToneGenerator; Frequency, Rate: LongWord; Amplitude: LongInt);
{ Fills Frames frames of Channels samples each (the same on every
  channel). }
procedure FillTone(var Generator: TToneGenerator; Samples: PSmallInt; Frames, Channels: LongWord);

implementation

const
  QuarterSteps = 256;

var
  QuarterSine: array[0..QuarterSteps] of LongInt;
  TableReady: Boolean = False;

{ sin(x) for x in [0, pi/2] from its series, good to far better than a
  16-bit sample needs. }
function SineOfQuarter(Index: Integer): Double;
var
  X: Double;
  Term: Double;
  Sum: Double;
  N: Integer;
begin
  X := (Index / QuarterSteps) * (Pi / 2);
  Term := X;
  Sum := X;
  for N := 1 to 9 do
  begin
    Term := -Term * X * X / ((2 * N) * (2 * N + 1));
    Sum := Sum + Term;
  end;
  Result := Sum;
end;

procedure PrepareTable;
var
  Index: Integer;
begin
  if TableReady then
    Exit;
  for Index := 0 to QuarterSteps do
    QuarterSine[Index] := Round(SineOfQuarter(Index) * 65536);
  TableReady := True;
end;

{ sin of Phase (a full period is 2^32), times 65536. }
function SineOfPhase(Phase: LongWord): LongInt;
var
  Quarter: LongWord;
  Position: LongWord;
begin
  Quarter := Phase shr 30;
  { The top 2 bits pick the quarter, the next 8 the place in it. }
  Position := (Phase shr 22) and (QuarterSteps - 1);
  case Quarter of
    0: Result := QuarterSine[Position];
    1: Result := QuarterSine[QuarterSteps - Position];
    2: Result := -QuarterSine[Position];
  else
    Result := -QuarterSine[QuarterSteps - Position];
  end;
end;

procedure StartTone(out Generator: TToneGenerator; Frequency, Rate: LongWord; Amplitude: LongInt);
begin
  PrepareTable;
  Generator.Phase := 0;
  Generator.Step := LongWord((QWord(Frequency) shl 32) div Rate);
  Generator.Amplitude := Amplitude;
end;

procedure FillTone(var Generator: TToneGenerator; Samples: PSmallInt; Frames, Channels: LongWord);
var
  Frame: LongWord;
  Channel: LongWord;
  Value: SmallInt;
begin
  for Frame := 0 to Frames - 1 do
  begin
    Value := SmallInt((Int64(SineOfPhase(Generator.Phase)) * Generator.Amplitude) div 65536);
    for Channel := 0 to Channels - 1 do
      Samples[Frame * Channels + Channel] := Value;
    Generator.Phase := Generator.Phase + Generator.Step;
  end;
end;

end.
