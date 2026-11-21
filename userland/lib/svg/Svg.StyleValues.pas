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
  Reading the SVG properties of a computed style (libcss) as the
  renderer needs them: paints (none, a colour, a paint server reference
  with its fallback), opacities, stroke width, dashes, caps, joins and
  miter limit, fill and clip rules, stop colours, visibility, text
  anchor, paint order and non-scaling strokes. Colours come out as
  libdrawing's, currentcolor resolved.
}
unit Svg.StyleValues;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Colors,
  Drawing.Rasterizer,
  Drawing.Stroking,
  Css.Keywords,
  Css.PropertyIds,
  Css.ComputedStyle,
  Svg.Numbers;

type
  TSvgPaintKind = (SvgPaintNone, SvgPaintColor, SvgPaintServer, SvgPaintContextFill, SvgPaintContextStroke);

  TSvgPaintSpec = record
    Kind: TSvgPaintKind;
    Color: TColor;
    { A paint server's reference (its "#id" or URL) and what to use when
      it names nothing. }
    Reference: string;
    FallbackKind: TSvgPaintKind;
    FallbackColor: TColor;
  end;

  TSvgDashes = array of Double;

function CssColorToColor(Style: TCssComputedStyle; Id: TCssPropertyId): TColor;
function CurrentColorOf(Style: TCssComputedStyle): TColor;
function PaintOf(Style: TCssComputedStyle; Id: TCssPropertyId): TSvgPaintSpec;
{ An opacity property, 0 to 1. }
function OpacityOf(Style: TCssComputedStyle; Id: TCssPropertyId): Double;
function StrokeWidthOf(Style: TCssComputedStyle; const Viewport: TSvgViewport): Double;
function DashOffsetOf(Style: TCssComputedStyle; const Viewport: TSvgViewport): Double;
{ The dash pattern, nil for none (or one that draws solid). }
function DashesOf(Style: TCssComputedStyle; const Viewport: TSvgViewport): TSvgDashes;
function StrokeStyleOf(Style: TCssComputedStyle; const Viewport: TSvgViewport): TStrokeStyle;
function FillRuleOf(Style: TCssComputedStyle; Id: TCssPropertyId): TFillRule;
{ stop-color with stop-opacity applied. }
function StopColorOf(Style: TCssComputedStyle): TColor;
{ visibility is visible. }
function IsStyleVisible(Style: TCssComputedStyle): Boolean;
function TextAnchorOf(Style: TCssComputedStyle): TCssKeyword;
function StrokeBeforeFill(Style: TCssComputedStyle): Boolean;
function IsNonScalingStroke(Style: TCssComputedStyle): Boolean;
{ A paint server's reference out of a url() (its text as written). }
function ReferenceOfUrl(Style: TCssComputedStyle; Id: TCssPropertyId): string;

implementation

uses
  Css.Colors,
  Css.ColorParser,
  Css.Values,
  Css.ComputedValues;

function ToColor(const Color: TCssColor): TColor;
var
  Rgba: TCssRgba8;
begin
  Rgba := ColorToRgba8(Color);
  Result := ArgbColor(Rgba.Alpha, Rgba.Red, Rgba.Green, Rgba.Blue);
end;

function CurrentColorOf(Style: TCssComputedStyle): TColor;
begin
  Result := ToColor(Style.Color);
end;

function CssColorToColor(Style: TCssComputedStyle; Id: TCssPropertyId): TColor;
begin
  Result := ToColor(Style.ColorOf(Id));
end;

{ A colour value of a value tree; False when it is none. }
function ValueColor(Style: TCssComputedStyle; Value: TCssValue; out Color: TColor): Boolean;
var
  Resolved: TCssColor;
begin
  Color := ColorTransparent;
  if Value = nil then
    Exit(False);
  if ResolveColor(Value, Style.Color, False, Resolved) then
  begin
    Color := ToColor(Resolved);
    Exit(True);
  end;
  Result := False;
end;

function PaintOf(Style: TCssComputedStyle; Id: TCssPropertyId): TSvgPaintSpec;
var
  Value: PCssComputedValue;
  Tree: TCssValue;
  Fallback: TCssValue;
begin
  Result := Default(TSvgPaintSpec);
  Result.Kind := SvgPaintNone;
  Result.FallbackKind := SvgPaintNone;
  Value := Style.Value(Id);
  case Value^.Kind of
    cvColor:
      begin
        Result.Kind := SvgPaintColor;
        Result.Color := ToColor(ComputedToColor(Value^, Style.Color));
      end;
    cvCurrentColor:
      begin
        Result.Kind := SvgPaintColor;
        Result.Color := CurrentColorOf(Style);
      end;
    cvKeyword:
      case TCssKeyword(Value^.Keyword) of
        kwContextFill: Result.Kind := SvgPaintContextFill;
        kwContextStroke: Result.Kind := SvgPaintContextStroke;
        kwCurrentcolor:
          begin
            Result.Kind := SvgPaintColor;
            Result.Color := CurrentColorOf(Style);
          end;
      end;
    cvValue:
      begin
        Tree := Value^.Data;
        if Tree = nil then
          Exit;
        if (Tree.Kind = vkList) and (Tree.Count = 2) and (Tree.Items[0].Kind = vkUrl) then
        begin
          Result.Kind := SvgPaintServer;
          Result.Reference := Tree.Items[0].Text;
          Fallback := Tree.Items[1];
          if not Fallback.IsKeyword(kwNone) and ValueColor(Style, Fallback, Result.FallbackColor) then
            Result.FallbackKind := SvgPaintColor;
        end
        else if Tree.Kind = vkUrl then
        begin
          Result.Kind := SvgPaintServer;
          Result.Reference := Tree.Text;
        end
        else if Tree.Kind = vkKeyword then
        begin
          case Tree.Keyword of
            kwNone: ;
            kwContextFill: Result.Kind := SvgPaintContextFill;
            kwContextStroke: Result.Kind := SvgPaintContextStroke;
            else
              if ValueColor(Style, Tree, Result.Color) then
                Result.Kind := SvgPaintColor;
          end;
        end
        else if ValueColor(Style, Tree, Result.Color) then
          Result.Kind := SvgPaintColor;
      end;
  end;
end;

function ReferenceOfUrl(Style: TCssComputedStyle; Id: TCssPropertyId): string;
var
  Value: PCssComputedValue;
begin
  Result := '';
  Value := Style.Value(Id);
  if (Value^.Kind = cvValue) and (Value^.Data <> nil) and (Value^.Data.Kind = vkUrl) then
    Result := Value^.Data.Text;
end;

function OpacityOf(Style: TCssComputedStyle; Id: TCssPropertyId): Double;
var
  Value: PCssComputedValue;
begin
  Value := Style.Value(Id);
  case Value^.Kind of
    cvNumber, cvInteger: Result := Value^.Number;
    cvPercentage: Result := Value^.Percent / 100;
    else
      Result := 1;
  end;
  if Result < 0 then
    Result := 0;
  if Result > 1 then
    Result := 1;
end;

function Diagonal(const Viewport: TSvgViewport): Double;
begin
  Result := Sqrt((Sqr(Viewport.Width) + Sqr(Viewport.Height)) / 2);
end;

function LengthValue(Style: TCssComputedStyle; Id: TCssPropertyId; const Viewport: TSvgViewport): Double;
var
  Value: PCssComputedValue;
begin
  Value := Style.Value(Id);
  case Value^.Kind of
    cvNumber, cvInteger: Result := Value^.Number;
    cvLength, cvPercentage, cvLengthPercentage, cvCalc: Result := ResolveComputed(Value^, Diagonal(Viewport));
    else
      Result := 0;
  end;
end;

function StrokeWidthOf(Style: TCssComputedStyle; const Viewport: TSvgViewport): Double;
begin
  Result := LengthValue(Style, cpStrokeWidth, Viewport);
  if Result < 0 then
    Result := 0;
end;

function DashOffsetOf(Style: TCssComputedStyle; const Viewport: TSvgViewport): Double;
begin
  Result := LengthValue(Style, cpStrokeDashoffset, Viewport);
end;

function DashesOf(Style: TCssComputedStyle; const Viewport: TSvgViewport): TSvgDashes;
var
  Value: PCssComputedValue;
  Index: Integer;
  Item: TCssValue;
  Total: Double;
begin
  Result := nil;
  Value := Style.Value(cpStrokeDasharray);
  if (Value^.Kind <> cvValue) or (Value^.Data = nil) or (Value^.Data.Kind <> vkList) then
    Exit;
  SetLength(Result, Value^.Data.Count);
  Total := 0;
  for Index := 0 to Value^.Data.Count - 1 do
  begin
    Item := Value^.Data.Items[Index];
    case Item.Kind of
      vkNumber, vkInteger, vkDimension: Result[Index] := Item.Number;
      vkPercentage: Result[Index] := Item.Number * Diagonal(Viewport) / 100;
      else
        Result[Index] := 0;
    end;
    if Result[Index] < 0 then
      Exit(nil);
    Total := Total + Result[Index];
  end;
  if Total <= 0 then
    Result := nil;
end;

function StrokeStyleOf(Style: TCssComputedStyle; const Viewport: TSvgViewport): TStrokeStyle;
begin
  Result := DefaultStrokeStyle(StrokeWidthOf(Style, Viewport));
  case Style.Keyword(cpStrokeLinecap) of
    kwRound: Result.Cap := LineCapRound;
    kwSquare: Result.Cap := LineCapSquare;
    else
      Result.Cap := LineCapButt;
  end;
  case Style.Keyword(cpStrokeLinejoin) of
    kwRound: Result.Join := LineJoinRound;
    kwBevel: Result.Join := LineJoinBevel;
    kwMiterClip: Result.Join := LineJoinMiterClip;
    kwArcs: Result.Join := LineJoinArcs;
    else
      Result.Join := LineJoinMiter;
  end;
  if Style.Value(cpStrokeMiterlimit)^.Kind in [cvNumber, cvInteger] then
    Result.MiterLimit := Style.Value(cpStrokeMiterlimit)^.Number;
  if Result.MiterLimit < 1 then
    Result.MiterLimit := 1;
end;

function FillRuleOf(Style: TCssComputedStyle; Id: TCssPropertyId): TFillRule;
begin
  if Style.Keyword(Id) = kwEvenodd then
    Result := FillRuleEvenOdd
  else
    Result := FillRuleNonZero;
end;

function StopColorOf(Style: TCssComputedStyle): TColor;
var
  Opacity: Double;
begin
  Result := CssColorToColor(Style, cpStopColor);
  Opacity := OpacityOf(Style, cpStopOpacity);
  if Opacity < 1 then
    Result := WithAlpha(Result, Round(AlphaOf(Result) * Opacity));
end;

function IsStyleVisible(Style: TCssComputedStyle): Boolean;
begin
  Result := not KeywordIn(Style.Keyword(cpVisibility), [kwHidden, kwCollapse]);
end;

function TextAnchorOf(Style: TCssComputedStyle): TCssKeyword;
begin
  Result := Style.Keyword(cpTextAnchor);
end;

function StrokeBeforeFill(Style: TCssComputedStyle): Boolean;
var
  Value: PCssComputedValue;
  Index: Integer;
  Item: TCssValue;
begin
  Result := False;
  Value := Style.Value(cpPaintOrder);
  if Value^.Kind = cvKeyword then
    Exit(TCssKeyword(Value^.Keyword) = kwStroke);
  if (Value^.Kind = cvValue) and (Value^.Data <> nil) then
  begin
    if Value^.Data.Kind = vkKeyword then
      Exit(Value^.Data.Keyword = kwStroke);
    for Index := 0 to Value^.Data.Count - 1 do
    begin
      Item := Value^.Data.Items[Index];
      if Item.Kind = vkKeyword then
      begin
        if Item.Keyword = kwStroke then
          Exit(True);
        if Item.Keyword = kwFill then
          Exit(False);
      end;
    end;
  end;
end;

function IsNonScalingStroke(Style: TCssComputedStyle): Boolean;
begin
  Result := Style.Keyword(cpVectorEffect) = kwNonScalingStroke;
end;

end.
