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
  Reading computed values the way layout uses them: lengths that may be
  auto or a percentage of a basis that may be unknown, the box model
  edges, sizes with box-sizing, and the keywords layout branches on.
}
unit Web.Layout.Values;

{$mode objfpc}
{$H+}

interface

uses
  Css.ComputedStyle, Css.ComputedValues, Css.PropertyIds, Css.Keywords, Web.Layout.Boxes;

const
  { An unknown (indefinite) size. }
  Indefinite = -1;

{ Whether the value is auto (or another keyword that is not a length:
  none, min-content ...). }
function IsAutoValue(Style: TCssComputedStyle; Id: TCssPropertyId): Boolean;
{ Whether the value holds a percentage (or a calc() with one). }
function HasPercentage(Style: TCssComputedStyle; Id: TCssPropertyId): Boolean;
{ The length with percentages against Basis. A percentage of an
  indefinite basis is Fallback; auto is Fallback. }
function LengthOf(Style: TCssComputedStyle; Id: TCssPropertyId; Basis: Double; Fallback: Double = 0): Double;
{ False for auto (and for a percentage of an indefinite basis). }
function TryLength(Style: TCssComputedStyle; Id: TCssPropertyId; Basis: Double; out Value: Single): Boolean;

{ Fills a box's margins (auto as 0), borders and padding from its style,
  percentages against the containing block's width. }
procedure ResolveBoxEdges(Box: TLayoutBox; ContainingWidth: Double);
function HorizontalEdges(Box: TLayoutBox): Double; inline;
function VerticalEdges(Box: TLayoutBox): Double; inline;
{ border + padding, left and right / top and bottom. }
function HorizontalBorderPadding(Box: TLayoutBox): Double; inline;
function VerticalBorderPadding(Box: TLayoutBox): Double; inline;

{ The used width or height (border box) the style asks for, or
  Indefinite for auto; box-sizing taken into account. }
function SpecifiedBorderBoxWidth(Box: TLayoutBox; ContainingWidth: Double): Double;
function SpecifiedBorderBoxHeight(Box: TLayoutBox; ContainingHeight: Double): Double;
{ min-/max- width and height as border box sizes (max: Indefinite for none). }
function MinBorderBoxWidth(Box: TLayoutBox; ContainingWidth: Double): Double;
function MaxBorderBoxWidth(Box: TLayoutBox; ContainingWidth: Double): Double;
function MinBorderBoxHeight(Box: TLayoutBox; ContainingHeight: Double): Double;
function MaxBorderBoxHeight(Box: TLayoutBox; ContainingHeight: Double): Double;
function ClampWidth(Box: TLayoutBox; Width, ContainingWidth: Double): Double;
function ClampHeight(Box: TLayoutBox; Height, ContainingHeight: Double): Double;

{ The used line-height in px for a style and its font. }
function UsedLineHeight(Style: TCssComputedStyle): Double;
function DisplayKeyword(Style: TCssComputedStyle): TCssKeyword;
{ Whether overflow clips (x or y not visible). }
function OverflowClips(Style: TCssComputedStyle): Boolean;
{ Whether the box must be a stacking context (z-index on a positioned
  box, opacity below 1, transform, filter, isolation, ...). }
function MakesStackingContext(Box: TLayoutBox): Boolean;
function ZIndexOf(Style: TCssComputedStyle): Integer;
{ Whether mask-image has a layer other than none. }
function HasMaskImage(Style: TCssComputedStyle): Boolean;

implementation

uses
  Css.Values, Web.Text.FontInstances;

function IsAutoValue(Style: TCssComputedStyle; Id: TCssPropertyId): Boolean;
begin
  Result := Style.Value(Id)^.Kind in [cvKeyword, cvNone, cvValue];
end;

function HasPercentage(Style: TCssComputedStyle; Id: TCssPropertyId): Boolean;
begin
  Result := Style.Value(Id)^.Kind in [cvPercentage, cvLengthPercentage, cvCalc];
end;

function TryLength(Style: TCssComputedStyle; Id: TCssPropertyId; Basis: Double; out Value: Single): Boolean;
var
  Computed: PCssComputedValue;
begin
  Computed := Style.Value(Id);
  Value := 0;
  case Computed^.Kind of
    cvLength:
      begin
        Value := Computed^.Number;
        Result := True;
      end;
    cvNumber, cvInteger:
      begin
        Value := Computed^.Number;
        Result := True;
      end;
    cvPercentage, cvLengthPercentage, cvCalc:
      begin
        if Basis < 0 then
          Exit(False);
        Value := ResolveComputed(Computed^, Basis);
        Result := True;
      end;
  else
    Result := False;
  end;
end;

function LengthOf(Style: TCssComputedStyle; Id: TCssPropertyId; Basis: Double; Fallback: Double): Double;
var
  Value: Single;
begin
  if TryLength(Style, Id, Basis, Value) then
    Result := Value
  else
    Result := Fallback;
end;

procedure ResolveBoxEdges(Box: TLayoutBox; ContainingWidth: Double);
var
  Style: TCssComputedStyle;
  Basis: Double;
begin
  Style := Box.Style;
  Basis := ContainingWidth;
  if Basis < 0 then
    Basis := 0;
  Box.Margin[sideTop] := LengthOf(Style, cpMarginTop, Basis);
  Box.Margin[sideRight] := LengthOf(Style, cpMarginRight, Basis);
  Box.Margin[sideBottom] := LengthOf(Style, cpMarginBottom, Basis);
  Box.Margin[sideLeft] := LengthOf(Style, cpMarginLeft, Basis);
  Box.Padding[sideTop] := Abs(LengthOf(Style, cpPaddingTop, Basis));
  Box.Padding[sideRight] := Abs(LengthOf(Style, cpPaddingRight, Basis));
  Box.Padding[sideBottom] := Abs(LengthOf(Style, cpPaddingBottom, Basis));
  Box.Padding[sideLeft] := Abs(LengthOf(Style, cpPaddingLeft, Basis));
  Box.Border[sideTop] := Style.Value(cpBorderTopWidth)^.Number;
  Box.Border[sideRight] := Style.Value(cpBorderRightWidth)^.Number;
  Box.Border[sideBottom] := Style.Value(cpBorderBottomWidth)^.Number;
  Box.Border[sideLeft] := Style.Value(cpBorderLeftWidth)^.Number;
  { Collapsing table borders: halves of the edges, and no padding on the
    table (CSS 2.2 17.6.2). }
  if bfCollapsedBorders in Box.Flags then
    if Box is TTableCellBox then
      Box.Border := TTableCellBox(Box).CollapsedBorder
    else if Box is TTableBox then
    begin
      Box.Border := TTableBox(Box).CollapsedBorder;
      Box.Padding[sideTop] := 0;
      Box.Padding[sideRight] := 0;
      Box.Padding[sideBottom] := 0;
      Box.Padding[sideLeft] := 0;
    end;
end;

function HorizontalEdges(Box: TLayoutBox): Double;
begin
  Result := Box.Margin[sideLeft] + Box.Margin[sideRight] + HorizontalBorderPadding(Box);
end;

function VerticalEdges(Box: TLayoutBox): Double;
begin
  Result := Box.Margin[sideTop] + Box.Margin[sideBottom] + VerticalBorderPadding(Box);
end;

function HorizontalBorderPadding(Box: TLayoutBox): Double;
begin
  Result := Box.Border[sideLeft] + Box.Border[sideRight] + Box.Padding[sideLeft] + Box.Padding[sideRight];
end;

function VerticalBorderPadding(Box: TLayoutBox): Double;
begin
  Result := Box.Border[sideTop] + Box.Border[sideBottom] + Box.Padding[sideTop] + Box.Padding[sideBottom];
end;

function IsBorderBox(Box: TLayoutBox): Boolean; inline;
begin
  Result := Box.Style.Keyword(cpBoxSizing) = kwBorderBox;
end;

function ToBorderBoxWidth(Box: TLayoutBox; Value: Double): Double;
begin
  if IsBorderBox(Box) then
  begin
    Result := Value;
    if Result < HorizontalBorderPadding(Box) then
      Result := HorizontalBorderPadding(Box);
  end
  else
  begin
    if Value < 0 then
      Value := 0;
    Result := Value + HorizontalBorderPadding(Box);
  end;
end;

function ToBorderBoxHeight(Box: TLayoutBox; Value: Double): Double;
begin
  if IsBorderBox(Box) then
  begin
    Result := Value;
    if Result < VerticalBorderPadding(Box) then
      Result := VerticalBorderPadding(Box);
  end
  else
  begin
    if Value < 0 then
      Value := 0;
    Result := Value + VerticalBorderPadding(Box);
  end;
end;

function SpecifiedBorderBoxWidth(Box: TLayoutBox; ContainingWidth: Double): Double;
var
  Value: Single;
begin
  if not TryLength(Box.Style, cpWidth, ContainingWidth, Value) then
    Exit(Indefinite);
  Result := ToBorderBoxWidth(Box, Value);
end;

function SpecifiedBorderBoxHeight(Box: TLayoutBox; ContainingHeight: Double): Double;
var
  Value: Single;
begin
  if not TryLength(Box.Style, cpHeight, ContainingHeight, Value) then
    Exit(Indefinite);
  Result := ToBorderBoxHeight(Box, Value);
end;

function MinBorderBoxWidth(Box: TLayoutBox; ContainingWidth: Double): Double;
var
  Value: Single;
begin
  if not TryLength(Box.Style, cpMinWidth, ContainingWidth, Value) then
    Exit(HorizontalBorderPadding(Box));
  Result := ToBorderBoxWidth(Box, Value);
end;

function MaxBorderBoxWidth(Box: TLayoutBox; ContainingWidth: Double): Double;
var
  Value: Single;
begin
  if not TryLength(Box.Style, cpMaxWidth, ContainingWidth, Value) then
    Exit(Indefinite);
  Result := ToBorderBoxWidth(Box, Value);
end;

function MinBorderBoxHeight(Box: TLayoutBox; ContainingHeight: Double): Double;
var
  Value: Single;
begin
  if not TryLength(Box.Style, cpMinHeight, ContainingHeight, Value) then
    Exit(VerticalBorderPadding(Box));
  Result := ToBorderBoxHeight(Box, Value);
end;

function MaxBorderBoxHeight(Box: TLayoutBox; ContainingHeight: Double): Double;
var
  Value: Single;
begin
  if not TryLength(Box.Style, cpMaxHeight, ContainingHeight, Value) then
    Exit(Indefinite);
  Result := ToBorderBoxHeight(Box, Value);
end;

function ClampWidth(Box: TLayoutBox; Width, ContainingWidth: Double): Double;
var
  Limit: Double;
begin
  Result := Width;
  Limit := MaxBorderBoxWidth(Box, ContainingWidth);
  if (Limit >= 0) and (Result > Limit) then
    Result := Limit;
  Limit := MinBorderBoxWidth(Box, ContainingWidth);
  if Result < Limit then
    Result := Limit;
end;

function ClampHeight(Box: TLayoutBox; Height, ContainingHeight: Double): Double;
var
  Limit: Double;
begin
  Result := Height;
  Limit := MaxBorderBoxHeight(Box, ContainingHeight);
  if (Limit >= 0) and (Result > Limit) then
    Result := Limit;
  Limit := MinBorderBoxHeight(Box, ContainingHeight);
  if Result < Limit then
    Result := Limit;
end;

function UsedLineHeight(Style: TCssComputedStyle): Double;
var
  Value: PCssComputedValue;
  Font: TTextFont;
begin
  Value := Style.Value(cpLineHeight);
  case Value^.Kind of
    cvLength:
      Result := Value^.Number;
    cvNumber, cvInteger:
      Result := Value^.Number * Style.FontSize;
    cvPercentage:
      Result := Value^.Percent * Style.FontSize / 100;
  else
    begin
      Font := TextFontOf(Style);
      Result := Font.Ascent + Font.Descent + Font.LineGap;
    end;
  end;
end;

function DisplayKeyword(Style: TCssComputedStyle): TCssKeyword;
var
  Value: PCssComputedValue;
  Index: Integer;
  HasInline, HasFlowRoot: Boolean;
begin
  Value := Style.Value(cpDisplay);
  if Value^.Kind = cvKeyword then
    Exit(TCssKeyword(Value^.Keyword));
  Result := kwBlock;
  if (Value^.Kind = cvValue) and (Value^.Data <> nil) then
  begin
    HasInline := False;
    HasFlowRoot := False;
    for Index := 0 to Value^.Data.Count - 1 do
    begin
      if Value^.Data.Items[Index].IsKeyword(kwInline) then
        HasInline := True;
      if Value^.Data.Items[Index].IsKeyword(kwFlowRoot) then
        HasFlowRoot := True;
    end;
    if HasInline then
      Result := kwInlineListItem
    else if HasFlowRoot then
      Result := kwListItem
    else
      Result := kwListItem;
  end;
end;

function OverflowClips(Style: TCssComputedStyle): Boolean;
begin
  Result := (Style.Keyword(cpOverflowX) <> kwVisible) or (Style.Keyword(cpOverflowY) <> kwVisible);
end;

function ZIndexOf(Style: TCssComputedStyle): Integer;
var
  Value: PCssComputedValue;
begin
  Value := Style.Value(cpZIndex);
  if Value^.Kind in [cvInteger, cvNumber] then
    Result := Round(Value^.Number)
  else
    Result := 0;
end;

function HasMaskImage(Style: TCssComputedStyle): Boolean;
var
  Images: PCssComputedValue;
  Index: Integer;
begin
  Result := False;
  if Style = nil then
    Exit;
  Images := Style.Value(cpMaskImage);
  if (Images^.Kind <> cvValue) or (Images^.Data = nil) then
    Exit;
  if Images^.Data.Kind <> vkList then
    Exit(Images^.Data.Kind <> vkKeyword);
  for Index := 0 to Images^.Data.Count - 1 do
    if Images^.Data.Items[Index].Kind <> vkKeyword then
      Exit(True);
end;

function MakesStackingContext(Box: TLayoutBox): Boolean;
var
  Style: TCssComputedStyle;
  ZValue: PCssComputedValue;
begin
  Style := Box.Style;
  if bfRootElement in Box.Flags then
    Exit(True);
  ZValue := Style.Value(cpZIndex);
  if (ZValue^.Kind in [cvInteger, cvNumber]) and (Box.IsPositioned or
     ((Box.Parent <> nil) and (Box.Parent.Kind in [bkFlex, bkGrid]))) then
    Exit(True);
  if bfFixed in Box.Flags then
    Exit(True);
  if bfSticky in Box.Flags then
    Exit(True);
  if Style.Value(cpOpacity)^.Number < 1 then
    Exit(True);
  if Style.Value(cpTransform)^.Kind <> cvKeyword then
    Exit(True);
  if Style.Keyword(cpIsolation) = kwIsolate then
    Exit(True);
  if HasMaskImage(Style) then
    Exit(True);
  if Style.Value(cpFilter)^.Kind <> cvKeyword then
    Exit(True);
  Result := False;
end;

end.
