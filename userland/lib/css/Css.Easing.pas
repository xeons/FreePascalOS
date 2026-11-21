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
  Easing functions (CSS Easing Functions 2): linear, the cubic Bézier
  keywords and cubic-bezier(), steps() with its jump terms and
  step-start/step-end, and linear() with its stops. Values come as
  libcss parses them (ParseEasing: a keyword or a function).
}
unit Css.Easing;

{$mode objfpc}
{$H+}

interface

uses
  Css.Values;

{ The eased progress for an input progress (0 to 1, may lie outside
  for fill modes). Easing nil is ease. BeforeFlag: the step functions'
  "before flag" (the animation is in its before phase). }
function EasedProgress(Easing: TCssValue; Progress: Double; BeforeFlag: Boolean = False): Double;
{ The I-th item of a comma list of easings, repeating as the list does
  (nil for none). }
function EasingAt(List: TCssValue; Index: Integer): TCssValue;

implementation

uses
  Math, Css.Keywords;

function CubicBezier(X1, Y1, X2, Y2, Progress: Double): Double;
var
  Low, High, Middle, X: Double;
  Step: Integer;

  function Coordinate(P1, P2, T: Double): Double;
  begin
    Result := 3 * (1 - T) * (1 - T) * T * P1 + 3 * (1 - T) * T * T * P2 + T * T * T;
  end;

begin
  if Progress <= 0 then
  begin
    { Beyond the ends: the tangent there. }
    if X1 > 0 then
      Exit(Progress * Y1 / X1);
    if (Y1 = 0) and (X2 > 0) then
      Exit(Progress * Y2 / X2);
    Exit(0);
  end;
  if Progress >= 1 then
  begin
    if X2 < 1 then
      Exit(1 + (Progress - 1) * (Y2 - 1) / (X2 - 1));
    if (Y2 = 1) and (X1 < 1) then
      Exit(1 + (Progress - 1) * (Y1 - 1) / (X1 - 1));
    Exit(1);
  end;
  { X(t) is monotonic for x in [0, 1]: bisection. }
  Low := 0;
  High := 1;
  Middle := Progress;
  for Step := 1 to 40 do
  begin
    Middle := (Low + High) / 2;
    X := Coordinate(X1, X2, Middle);
    if Abs(X - Progress) < 1E-7 then
      Break;
    if X < Progress then
      Low := Middle
    else
      High := Middle;
  end;
  Result := Coordinate(Y1, Y2, Middle);
end;

function Steps(Count: Integer; Position: TCssKeyword; Progress: Double; BeforeFlag: Boolean): Double;
var
  Jumps, Current: Integer;
begin
  if Count < 1 then
    Count := 1;
  if Position = kwJumpNone then
    Jumps := Count - 1
  else if Position = kwJumpBoth then
    Jumps := Count + 1
  else
    Jumps := Count;
  if Jumps < 1 then
    Jumps := 1;
  Current := Floor(Progress * Count);
  if KeywordIn(Position, [kwJumpStart, kwStart, kwJumpBoth]) then
    Inc(Current);
  if BeforeFlag and (Frac(Progress * Count) = 0) then
    Dec(Current);
  if (Progress >= 0) and (Current < 0) then
    Current := 0;
  if (Progress <= 1) and (Current > Jumps) then
    Current := Jumps;
  if Position = kwJumpNone then
    Result := Current / Jumps
  else if Position = kwJumpBoth then
    Result := Current / Jumps
  else
    Result := Current / Count;
end;

function NumberOf(Value: TCssValue): Double;
begin
  if (Value <> nil) and (Value.Kind in [vkNumber, vkInteger]) then
    Result := Value.Number
  else if (Value <> nil) and (Value.Kind = vkPercentage) then
    Result := Value.Number / 100
  else
    Result := 0;
end;

{ linear(): stops of output and optional input percentages, laid out as
  the spec does (missing inputs spread evenly). }
function LinearStops(Easing: TCssValue; Progress: Double): Double;
var
  Outputs, Inputs: array of Double;
  Count, Index, Item, Last, Next, Fill: Integer;
  Value: TCssValue;
  Span: Double;
begin
  Outputs := nil;
  Inputs := nil;
  for Item := 0 to Easing.Count - 1 do
  begin
    Value := Easing.Items[Item];
    if Value.Kind = vkList then
    begin
      { output then one or two input percentages }
      if Value.Count = 0 then
        Continue;
      for Index := 1 to Max(1, Value.Count - 1) do
      begin
        SetLength(Outputs, Length(Outputs) + 1);
        SetLength(Inputs, Length(Inputs) + 1);
        Outputs[High(Outputs)] := NumberOf(Value.Items[0]);
        if Index < Value.Count then
          Inputs[High(Inputs)] := NumberOf(Value.Items[Index])
        else
          Inputs[High(Inputs)] := NaN;
      end;
    end
    else
    begin
      SetLength(Outputs, Length(Outputs) + 1);
      SetLength(Inputs, Length(Inputs) + 1);
      Outputs[High(Outputs)] := NumberOf(Value);
      Inputs[High(Inputs)] := NaN;
    end;
  end;
  Count := Length(Outputs);
  if Count = 0 then
    Exit(Progress);
  if Count = 1 then
    Exit(Outputs[0]);
  if IsNan(Inputs[0]) then
    Inputs[0] := 0;
  if IsNan(Inputs[Count - 1]) then
    Inputs[Count - 1] := Max(1, Inputs[0]);
  for Index := 1 to Count - 1 do
    if not IsNan(Inputs[Index]) and (Inputs[Index] < Inputs[Index - 1]) and not IsNan(Inputs[Index - 1]) then
      Inputs[Index] := Inputs[Index - 1];
  Last := 0;
  Index := 1;
  while Index < Count do
  begin
    if not IsNan(Inputs[Index]) then
    begin
      Next := Index;
      Span := (Inputs[Next] - Inputs[Last]) / (Next - Last);
      for Fill := Last + 1 to Next - 1 do
        Inputs[Fill] := Inputs[Last] + Span * (Fill - Last);
      Last := Next;
    end;
    Inc(Index);
  end;
  if Progress <= Inputs[0] then
    Exit(Outputs[0]);
  for Index := 1 to Count - 1 do
    if Progress <= Inputs[Index] then
    begin
      if Inputs[Index] = Inputs[Index - 1] then
        Exit(Outputs[Index]);
      Exit(Outputs[Index - 1] + (Outputs[Index] - Outputs[Index - 1]) * (Progress - Inputs[Index - 1]) /
        (Inputs[Index] - Inputs[Index - 1]));
    end;
  Result := Outputs[Count - 1];
end;

function EasedProgress(Easing: TCssValue; Progress: Double; BeforeFlag: Boolean): Double;
var
  Position: TCssKeyword;
begin
  if Easing = nil then
    Exit(CubicBezier(0.25, 0.1, 0.25, 1, Progress));
  case Easing.Kind of
    vkKeyword:
      case Easing.Keyword of
        kwLinear: Result := Progress;
        kwEaseIn: Result := CubicBezier(0.42, 0, 1, 1, Progress);
        kwEaseOut: Result := CubicBezier(0, 0, 0.58, 1, Progress);
        kwEaseInOut: Result := CubicBezier(0.42, 0, 0.58, 1, Progress);
        kwStepStart: Result := Steps(1, kwJumpStart, Progress, BeforeFlag);
        kwStepEnd: Result := Steps(1, kwJumpEnd, Progress, BeforeFlag);
      else
        Result := CubicBezier(0.25, 0.1, 0.25, 1, Progress);
      end;
    vkFunction:
      if (Easing.Text = 'cubic-bezier') and (Easing.Count = 4) then
        Result := CubicBezier(NumberOf(Easing.Items[0]), NumberOf(Easing.Items[1]), NumberOf(Easing.Items[2]),
          NumberOf(Easing.Items[3]), Progress)
      else if (Easing.Text = 'steps') and (Easing.Count >= 1) then
      begin
        Position := kwJumpEnd;
        if (Easing.Count >= 2) and (Easing.Items[1].Kind = vkKeyword) then
          Position := Easing.Items[1].Keyword;
        Result := Steps(Round(NumberOf(Easing.Items[0])), Position, Progress, BeforeFlag);
      end
      else if Easing.Text = 'linear' then
        Result := LinearStops(Easing, Progress)
      else
        Result := Progress;
  else
    Result := Progress;
  end;
end;

function EasingAt(List: TCssValue; Index: Integer): TCssValue;
begin
  Result := nil;
  if List = nil then
    Exit;
  if (List.Kind = vkList) and (List.Separator = lsComma) then
  begin
    if List.Count = 0 then
      Exit;
    Result := List.Items[Index mod List.Count];
  end
  else
    Result := List;
end;

end.
