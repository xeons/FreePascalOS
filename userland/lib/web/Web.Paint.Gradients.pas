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
  CSS gradients (CSS Images 3 and 4): linear-gradient and
  radial-gradient and their repeating forms, from libcss's checked
  function values.

  A gradient is prepared once for its box (the gradient line or ray,
  the color stops with their positions fixed up as the specification
  says: the first at 0, the last at 1, missing ones spread evenly, none
  before an earlier one) and then gives the color at any point.
  Colors are interpolated in premultiplied sRGB.

  For drawing many pixels a ramp is made from the prepared gradient:
  the colours at RampSteps + 1 even steps between each pair of stops.
  A point's position along the line or ray still picks the pair (so a
  hard stop stays as sharp as the pixel grid allows), the step nearest
  its weight between them gives the colour, within one level of the
  exact one.
}
unit Web.Paint.Gradients;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  Drawing.Colors, Css.Values;

type
  TGradientStop = record
    Position: Single;
    Red, Green, Blue, Alpha: Single;
  end;

  TPreparedGradient = record
    Radial: Boolean;
    Repeating: Boolean;
    { Linear: the line's direction and length, through the centre. }
    CentreX, CentreY: Single;
    DirectionX, DirectionY, LineLength: Single;
    { Radial: the ray's radii. }
    RadiusX, RadiusY: Single;
    Stops: array of TGradientStop;
    StopCount: Integer;
  end;

{ False if the value is not a gradient this engine draws. Box in the
  same units as the points asked for later. }
function PrepareGradient(Gradient: TCssValue; BoxX, BoxY, BoxWidth, BoxHeight: Single; CurrentColor: TColor;
  out Prepared: TPreparedGradient): Boolean;
function GradientColorAt(const Prepared: TPreparedGradient; X, Y: Single): TColor;

const
  { The colours worked out between two stops. }
  RampSteps = 256;

type
  TGradientRamp = record
    { Between stop I - 1 and stop I (I from 1): RampSteps + 1 colours
      from (I - 1) * (RampSteps + 1). }
    Colors: array of TColor;
    { RampSteps over the distance between the pair's stops (0: a hard
      stop). }
    StepScales: array of Single;
    { Before the first stop and after the last. }
    FirstColor, LastColor: TColor;
    { A repeating gradient: positions wrap into WrapStart .. WrapStart +
      WrapSpan. }
    Wraps: Boolean;
    WrapStart, WrapSpan: Single;
  end;

{ The ramp of a prepared gradient, its colours at Opacity (0-255). }
procedure PrepareGradientRamp(const Prepared: TPreparedGradient; Opacity: Byte; out Ramp: TGradientRamp);
{ The colour at Position along the gradient line (0 at its start, 1 at
  its end) or ray. }
function RampColorAt(const Prepared: TPreparedGradient; const Ramp: TGradientRamp; Position: Single): TColor;

{ A point's position on the gradient from a part that depends on its X
  only and one that depends on its Y only (worked out once per column
  and once per row), in the order GradientColorAt works it out (the same
  position to the last bit): their sum along the line for a linear
  gradient, the square root of their sum for a radial one. }
function GradientColumnTerm(const Prepared: TPreparedGradient; X: Single): Single;
function GradientRowTerm(const Prepared: TPreparedGradient; Y: Single): Single;
function GradientPosition(const Prepared: TPreparedGradient; ColumnTerm, RowTerm: Single): Single; inline;
{ Whether the colour changes along X, along Y. }
procedure GradientVariation(const Prepared: TPreparedGradient; out AlongX, AlongY: Boolean);

implementation

uses
  Math, Css.Keywords, Css.Colors, Css.Units;

function IsColorStop(Item: TCssValue): Boolean;
var
  Index: Integer;
begin
  if Item.Kind = vkColor then
    Exit(True);
  if (Item.Kind = vkKeyword) and (KeywordIn(Item.Keyword, [kwCurrentcolor, kwTransparent])) then
    Exit(True);
  Result := False;
  if Item.Kind = vkList then
    for Index := 0 to Item.Count - 1 do
      if IsColorStop(Item.Items[Index]) then
        Exit(True);
end;

function AngleOf(Item: TCssValue): Single;
begin
  case Item.UnitValue of
    cuRad: Result := Item.Number;
    cuGrad: Result := Item.Number * Pi / 200;
    cuTurn: Result := Item.Number * 2 * Pi;
  else
    Result := Item.Number * Pi / 180;
  end;
end;

procedure AddStop(var Prepared: TPreparedGradient; Color: TColor; Position: Single);
var
  Alpha: Single;
begin
  if Prepared.StopCount >= Length(Prepared.Stops) then
    SetLength(Prepared.Stops, Prepared.StopCount * 2 + 4);
  Alpha := AlphaOf(Color) / 255;
  Prepared.Stops[Prepared.StopCount].Position := Position;
  Prepared.Stops[Prepared.StopCount].Alpha := Alpha;
  Prepared.Stops[Prepared.StopCount].Red := RedOf(Color) * Alpha;
  Prepared.Stops[Prepared.StopCount].Green := GreenOf(Color) * Alpha;
  Prepared.Stops[Prepared.StopCount].Blue := BlueOf(Color) * Alpha;
  Inc(Prepared.StopCount);
end;

function CssToColor(const Color: TCssColor): TColor;
var
  Rgba: TCssRgba8;
begin
  Rgba := ColorToRgba8(Color);
  Result := ArgbColor(Rgba.Alpha, Rgba.Red, Rgba.Green, Rgba.Blue);
end;

const
  NoPosition = -1e30;
  { Singles do not hold NoPosition exactly: compare against a limit. }
  NoPositionLimit = -1e20;

procedure ReadStops(var Prepared: TPreparedGradient; Gradient: TCssValue; First: Integer; LineLength: Single;
  CurrentColor: TColor);
var
  Index, Part, Start, Finish, Step: Integer;
  Item, Piece: TCssValue;
  Color: TColor;
  Position, Previous: Single;
  Positions: array of Single;

  function PositionOf(Value: TCssValue): Single;
  begin
    if Value.Kind = vkPercentage then
      Result := Value.Number / 100
    else if LineLength > 0 then
      Result := Value.Number / LineLength
    else
      Result := 0;
  end;

begin
  Prepared.StopCount := 0;
  Positions := nil;
  for Index := First to Gradient.Count - 1 do
  begin
    Item := Gradient.Items[Index];
    Color := CurrentColor;
    Position := NoPosition;
    if Item.Kind <> vkList then
    begin
      if Item.Kind = vkColor then
        Color := CssToColor(Item.Color)
      else if (Item.Kind = vkKeyword) and (Item.Keyword = kwTransparent) then
        Color := 0
      else
      begin
        { A lone position: a color hint, approximated by a stop between. }
        Continue;
      end;
      AddStop(Prepared, Color, NoPosition);
      Continue;
    end;
    Part := 0;
    Piece := nil;
    for Part := 0 to Item.Count - 1 do
    begin
      Piece := Item.Items[Part];
      if Piece.Kind = vkColor then
        Color := CssToColor(Piece.Color)
      else if (Piece.Kind = vkKeyword) and (Piece.Keyword = kwTransparent) then
        Color := 0;
    end;
    Start := Prepared.StopCount;
    for Part := 0 to Item.Count - 1 do
    begin
      Piece := Item.Items[Part];
      if Piece.Kind in [vkPercentage, vkDimension, vkNumber] then
        AddStop(Prepared, Color, PositionOf(Piece));
    end;
    if Prepared.StopCount = Start then
      AddStop(Prepared, Color, NoPosition);
  end;
  if Prepared.StopCount = 0 then
    Exit;
  { Fix up the positions. }
  if Prepared.Stops[0].Position < NoPositionLimit then
    Prepared.Stops[0].Position := 0;
  if Prepared.Stops[Prepared.StopCount - 1].Position < NoPositionLimit then
    Prepared.Stops[Prepared.StopCount - 1].Position := 1;
  Previous := Prepared.Stops[0].Position;
  for Index := 1 to Prepared.StopCount - 1 do
    if Prepared.Stops[Index].Position >= NoPositionLimit then
    begin
      if Prepared.Stops[Index].Position < Previous then
        Prepared.Stops[Index].Position := Previous;
      Previous := Prepared.Stops[Index].Position;
    end;
  Index := 1;
  while Index < Prepared.StopCount do
  begin
    if Prepared.Stops[Index].Position < NoPositionLimit then
    begin
      Start := Index - 1;
      Finish := Index;
      while Prepared.Stops[Finish].Position < NoPositionLimit do
        Inc(Finish);
      for Step := Start + 1 to Finish - 1 do
        Prepared.Stops[Step].Position := Prepared.Stops[Start].Position +
          (Prepared.Stops[Finish].Position - Prepared.Stops[Start].Position) * (Step - Start) / (Finish - Start);
      Index := Finish;
    end;
    Inc(Index);
  end;
end;

procedure SideAngle(Item: TCssValue; Width, Height: Single; var Angle: Single);
var
  Index: Integer;
  Horizontal, Vertical: Integer;
begin
  Horizontal := 0;
  Vertical := 0;
  for Index := 0 to Item.Count - 1 do
    case Item.Items[Index].Keyword of
      kwLeft: Horizontal := -1;
      kwRight: Horizontal := 1;
      kwTop: Vertical := -1;
      kwBottom: Vertical := 1;
    end;
  if (Horizontal <> 0) and (Vertical <> 0) then
    { The corner: perpendicular to the diagonal between the other two. }
    Angle := ArcTan2(Horizontal * Height, -Vertical * Width)
  else if Horizontal <> 0 then
    Angle := Horizontal * Pi / 2
  else if Vertical > 0 then
    Angle := Pi
  else if Vertical < 0 then
    Angle := 0;
end;

function PositionValue(Value: TCssValue; Size: Single): Single;
begin
  Result := Size / 2;
  if Value = nil then
    Exit;
  case Value.Kind of
    vkPercentage: Result := Value.Number * Size / 100;
    vkDimension, vkNumber: Result := Value.Number;
    vkKeyword:
      case Value.Keyword of
        kwLeft, kwTop: Result := 0;
        kwRight, kwBottom: Result := Size;
      end;
  end;
end;

procedure RadialShape(Item: TCssValue; Width, Height: Single; var Prepared: TPreparedGradient; BoxX, BoxY: Single);
var
  Index: Integer;
  Piece, AtPosition: TCssValue;
  Circle, SeenAt: Boolean;
  Lengths: array[0..1] of Single;
  LengthCount: Integer;
  SizeKeyword: TCssKeyword;
  CentreX, CentreY, Left, Right, Top, Bottom, Ratio: Single;
begin
  Circle := False;
  SeenAt := False;
  AtPosition := nil;
  LengthCount := 0;
  SizeKeyword := kwFarthestCorner;
  CentreX := Width / 2;
  CentreY := Height / 2;
  if Item <> nil then
    for Index := 0 to Item.Count - 1 do
    begin
      Piece := Item.Items[Index];
      if SeenAt then
      begin
        AtPosition := Piece;
        Continue;
      end;
      if Piece.Kind = vkKeyword then
        case Piece.Keyword of
          kwCircle: Circle := True;
          kwEllipse: Circle := False;
          kwAt: SeenAt := True;
          kwClosestSide, kwClosestCorner, kwFarthestSide, kwFarthestCorner: SizeKeyword := Piece.Keyword;
        end
      else if (Piece.Kind in [vkDimension, vkPercentage, vkNumber]) and (LengthCount < 2) then
      begin
        if Piece.Kind = vkPercentage then
        begin
          if LengthCount = 0 then
            Lengths[LengthCount] := Piece.Number * Width / 100
          else
            Lengths[LengthCount] := Piece.Number * Height / 100;
        end
        else
          Lengths[LengthCount] := Piece.Number;
        Inc(LengthCount);
      end;
    end;
  if AtPosition <> nil then
  begin
    if (AtPosition.Kind = vkList) and (AtPosition.Count >= 2) then
    begin
      CentreX := PositionValue(AtPosition.Items[0], Width);
      CentreY := PositionValue(AtPosition.Items[1], Height);
    end
    else if AtPosition.Kind = vkKeyword then
    begin
      if KeywordIn(AtPosition.Keyword, [kwLeft, kwRight]) then
        CentreX := PositionValue(AtPosition, Width)
      else if KeywordIn(AtPosition.Keyword, [kwTop, kwBottom]) then
        CentreY := PositionValue(AtPosition, Height);
    end
    else
      CentreX := PositionValue(AtPosition, Width);
  end;
  Prepared.CentreX := BoxX + CentreX;
  Prepared.CentreY := BoxY + CentreY;
  Left := Abs(CentreX);
  Right := Abs(Width - CentreX);
  Top := Abs(CentreY);
  Bottom := Abs(Height - CentreY);
  if LengthCount = 1 then
  begin
    Prepared.RadiusX := Lengths[0];
    Prepared.RadiusY := Lengths[0];
    Exit;
  end;
  if LengthCount = 2 then
  begin
    Prepared.RadiusX := Lengths[0];
    Prepared.RadiusY := Lengths[1];
    Exit;
  end;
  case SizeKeyword of
    kwClosestSide:
      begin
        Prepared.RadiusX := Min(Left, Right);
        Prepared.RadiusY := Min(Top, Bottom);
      end;
    kwFarthestSide:
      begin
        Prepared.RadiusX := Max(Left, Right);
        Prepared.RadiusY := Max(Top, Bottom);
      end;
    kwClosestCorner:
      begin
        Prepared.RadiusX := Min(Left, Right);
        Prepared.RadiusY := Min(Top, Bottom);
      end;
  else
    begin
      Prepared.RadiusX := Max(Left, Right);
      Prepared.RadiusY := Max(Top, Bottom);
    end;
  end;
  if Circle then
  begin
    if KeywordIn(SizeKeyword, [kwClosestSide, kwFarthestSide]) then
    begin
      if SizeKeyword = kwClosestSide then
        Prepared.RadiusX := Min(Prepared.RadiusX, Prepared.RadiusY)
      else
        Prepared.RadiusX := Max(Prepared.RadiusX, Prepared.RadiusY);
    end
    else
      Prepared.RadiusX := Sqrt(Sqr(Prepared.RadiusX) + Sqr(Prepared.RadiusY));
    Prepared.RadiusY := Prepared.RadiusX;
  end
  else if KeywordIn(SizeKeyword, [kwClosestCorner, kwFarthestCorner]) then
  begin
    { The ellipse through the corner with the sides' ratio. }
    Ratio := Sqrt(2);
    Prepared.RadiusX := Prepared.RadiusX * Ratio;
    Prepared.RadiusY := Prepared.RadiusY * Ratio;
  end;
end;

function PrepareGradient(Gradient: TCssValue; BoxX, BoxY, BoxWidth, BoxHeight: Single; CurrentColor: TColor;
  out Prepared: TPreparedGradient): Boolean;
var
  Angle: Single;
  First: Integer;
  Lead: TCssValue;
  Name: string;
begin
  Prepared := Default(TPreparedGradient);
  Result := False;
  if (Gradient = nil) or (Gradient.Kind <> vkFunction) or (Gradient.Count = 0) then
    Exit;
  Name := Gradient.Text;
  Prepared.Repeating := Copy(Name, 1, 10) = 'repeating-';
  if Prepared.Repeating then
    Delete(Name, 1, 10);
  Lead := Gradient.Items[0];
  First := 0;
  if not IsColorStop(Lead) then
    First := 1;
  if (Name = 'linear-gradient') or (Name = '-webkit-linear-gradient') then
  begin
    Angle := Pi;
    if First = 1 then
    begin
      if Lead.Kind = vkDimension then
        Angle := AngleOf(Lead)
      else if (Lead.Kind = vkList) and (Lead.Count > 0) and (Lead.Items[0].Kind = vkDimension) then
        Angle := AngleOf(Lead.Items[0])
      else if Lead.Kind = vkList then
        SideAngle(Lead, BoxWidth, BoxHeight, Angle)
      else if Lead.Kind = vkKeyword then
        SideAngle(Gradient, BoxWidth, BoxHeight, Angle);
    end;
    Prepared.DirectionX := Sin(Angle);
    Prepared.DirectionY := -Cos(Angle);
    Prepared.LineLength := Abs(BoxWidth * Sin(Angle)) + Abs(BoxHeight * Cos(Angle));
    Prepared.CentreX := BoxX + BoxWidth / 2;
    Prepared.CentreY := BoxY + BoxHeight / 2;
    ReadStops(Prepared, Gradient, First, Prepared.LineLength, CurrentColor);
  end
  else if (Name = 'radial-gradient') or (Name = '-webkit-radial-gradient') then
  begin
    Prepared.Radial := True;
    if First = 1 then
      RadialShape(Lead, BoxWidth, BoxHeight, Prepared, BoxX, BoxY)
    else
      RadialShape(nil, BoxWidth, BoxHeight, Prepared, BoxX, BoxY);
    ReadStops(Prepared, Gradient, First, Prepared.RadiusX, CurrentColor);
  end
  else
    Exit;
  Result := Prepared.StopCount > 0;
end;

{ The colour Weight of the way from Low to High. }
function MixedStopColor(const Low, High: TGradientStop; Weight: Single): TColor;
var
  Alpha: Single;
begin
  Alpha := Low.Alpha + (High.Alpha - Low.Alpha) * Weight;
  if Alpha <= 0.002 then
    Exit(0);
  Result := ArgbColor(Round(Alpha * 255), Round(EnsureRange((Low.Red + (High.Red - Low.Red) * Weight) / Alpha, 0, 255)),
    Round(EnsureRange((Low.Green + (High.Green - Low.Green) * Weight) / Alpha, 0, 255)),
    Round(EnsureRange((Low.Blue + (High.Blue - Low.Blue) * Weight) / Alpha, 0, 255)));
end;

{ Repeating: the position brought into the first repetition. }
function WrappedPosition(const Prepared: TPreparedGradient; Position: Single): Single;
var
  First, Span: Single;
begin
  Result := Position;
  First := Prepared.Stops[0].Position;
  Span := Prepared.Stops[Prepared.StopCount - 1].Position - First;
  if Span > 0.0001 then
    Result := First + (Position - First) - Span * Floor((Position - First) / Span);
end;

function GradientColorAt(const Prepared: TPreparedGradient; X, Y: Single): TColor;
var
  Position, Span, Weight: Single;
  Index: Integer;
  Low, High: TGradientStop;
begin
  if Prepared.Radial then
  begin
    if (Prepared.RadiusX <= 0) or (Prepared.RadiusY <= 0) then
      Position := 1
    else
      Position := Sqrt(Sqr((X - Prepared.CentreX) / Prepared.RadiusX) + Sqr((Y - Prepared.CentreY) / Prepared.RadiusY));
  end
  else if Prepared.LineLength <= 0 then
    Position := 0
  else
    Position := ((X - Prepared.CentreX) * Prepared.DirectionX + (Y - Prepared.CentreY) * Prepared.DirectionY) /
      Prepared.LineLength + 0.5;
  if Prepared.Repeating then
    Position := WrappedPosition(Prepared, Position);
  if Position <= Prepared.Stops[0].Position then
  begin
    Low := Prepared.Stops[0];
    High := Low;
    Weight := 0;
  end
  else if Position >= Prepared.Stops[Prepared.StopCount - 1].Position then
  begin
    Low := Prepared.Stops[Prepared.StopCount - 1];
    High := Low;
    Weight := 0;
  end
  else
  begin
    Index := 1;
    while (Index < Prepared.StopCount - 1) and (Prepared.Stops[Index].Position < Position) do
      Inc(Index);
    Low := Prepared.Stops[Index - 1];
    High := Prepared.Stops[Index];
    Span := High.Position - Low.Position;
    if Span <= 0 then
      Weight := 1
    else
      Weight := (Position - Low.Position) / Span;
  end;
  Result := MixedStopColor(Low, High, Weight);
end;

function FadedColor(Color: TColor; Opacity: Byte): TColor; inline;
begin
  if Opacity = 255 then
    Result := Color
  else
    Result := FadeColor(Color, Opacity);
end;

procedure PrepareGradientRamp(const Prepared: TPreparedGradient; Opacity: Byte; out Ramp: TGradientRamp);
var
  Pair, Step, Last: Integer;
  Span: Single;
begin
  Ramp := Default(TGradientRamp);
  Last := Prepared.StopCount - 1;
  if Last < 0 then
    Exit;
  Ramp.FirstColor := FadedColor(MixedStopColor(Prepared.Stops[0], Prepared.Stops[0], 0), Opacity);
  Ramp.LastColor := FadedColor(MixedStopColor(Prepared.Stops[Last], Prepared.Stops[Last], 0), Opacity);
  SetLength(Ramp.Colors, Max(1, Last) * (RampSteps + 1));
  SetLength(Ramp.StepScales, Max(1, Last + 1));
  for Pair := 1 to Last do
  begin
    Span := Prepared.Stops[Pair].Position - Prepared.Stops[Pair - 1].Position;
    if Span <= 0 then
      Ramp.StepScales[Pair] := 0
    else
      Ramp.StepScales[Pair] := RampSteps / Span;
    for Step := 0 to RampSteps do
      Ramp.Colors[(Pair - 1) * (RampSteps + 1) + Step] :=
        FadedColor(MixedStopColor(Prepared.Stops[Pair - 1], Prepared.Stops[Pair], Step / RampSteps), Opacity);
  end;
  Ramp.WrapStart := Prepared.Stops[0].Position;
  Ramp.WrapSpan := Prepared.Stops[Last].Position - Ramp.WrapStart;
  Ramp.Wraps := Prepared.Repeating and (Ramp.WrapSpan > 0.0001);
end;

function GradientColumnTerm(const Prepared: TPreparedGradient; X: Single): Single;
begin
  if Prepared.Radial then
  begin
    if (Prepared.RadiusX <= 0) or (Prepared.RadiusY <= 0) then
      Result := 0
    else
      Result := Sqr((X - Prepared.CentreX) / Prepared.RadiusX);
  end
  else
    Result := (X - Prepared.CentreX) * Prepared.DirectionX;
end;

function GradientRowTerm(const Prepared: TPreparedGradient; Y: Single): Single;
begin
  if Prepared.Radial then
  begin
    { A ray of no length: everything at its end. }
    if (Prepared.RadiusX <= 0) or (Prepared.RadiusY <= 0) then
      Result := 1
    else
      Result := Sqr((Y - Prepared.CentreY) / Prepared.RadiusY);
  end
  else
    Result := (Y - Prepared.CentreY) * Prepared.DirectionY;
end;

function GradientPosition(const Prepared: TPreparedGradient; ColumnTerm, RowTerm: Single): Single;
begin
  if Prepared.Radial then
    Result := Sqrt(ColumnTerm + RowTerm)
  else if Prepared.LineLength <= 0 then
    Result := 0
  else
    Result := (ColumnTerm + RowTerm) / Prepared.LineLength + 0.5;
end;

procedure GradientVariation(const Prepared: TPreparedGradient; out AlongX, AlongY: Boolean);
const
  { A direction this small is a rounding error of the sine or cosine of
    a right angle. }
  Negligible = 1E-6;
begin
  if Prepared.Radial then
  begin
    AlongX := (Prepared.RadiusX > 0) and (Prepared.RadiusY > 0);
    AlongY := AlongX;
  end
  else
  begin
    AlongX := (Prepared.LineLength > 0) and (Abs(Prepared.DirectionX) >= Negligible);
    AlongY := (Prepared.LineLength > 0) and (Abs(Prepared.DirectionY) >= Negligible);
  end;
end;

function RampColorAt(const Prepared: TPreparedGradient; const Ramp: TGradientRamp; Position: Single): TColor;
var
  Stops: ^TGradientStop;
  Index, Last, Step, Repetitions: Integer;
  Quotient: Single;
begin
  Stops := @Prepared.Stops[0];
  if Ramp.Wraps then
  begin
    { As WrappedPosition, with Floor as Trunc (one less below zero). }
    Quotient := (Position - Ramp.WrapStart) / Ramp.WrapSpan;
    Repetitions := Trunc(Quotient);
    if Repetitions > Quotient then
      Dec(Repetitions);
    Position := Ramp.WrapStart + (Position - Ramp.WrapStart) - Ramp.WrapSpan * Repetitions;
  end;
  if Position <= Stops[0].Position then
    Exit(Ramp.FirstColor);
  Last := Prepared.StopCount - 1;
  if Position >= Stops[Last].Position then
    Exit(Ramp.LastColor);
  Index := 1;
  while (Index < Last) and (Stops[Index].Position < Position) do
    Inc(Index);
  if Ramp.StepScales[Index] = 0 then
    Step := RampSteps
  else
  begin
    Step := Trunc((Position - Stops[Index - 1].Position) * Ramp.StepScales[Index] + 0.5);
    if Step > RampSteps then
      Step := RampSteps
    else if Step < 0 then
      Step := 0;
  end;
  Result := Ramp.Colors[(Index - 1) * (RampSteps + 1) + Step];
end;

end.
