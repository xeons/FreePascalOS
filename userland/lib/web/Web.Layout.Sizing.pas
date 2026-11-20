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
  Intrinsic sizes: a box's min-content and max-content widths (CSS
  Sizing 3), what shrink-to-fit widths, flex bases and table columns
  are made of.

  Inline content gives the widest unbreakable piece (min) and the
  widest line between forced breaks (max), from the same measured items
  line layout uses; block children give the widest child with its
  margins; a flex row adds its items' widths, a column takes the
  widest; a replaced box its intrinsic or specified width. A fixed
  width is both. The result is kept on the box until it changes.
}
unit Web.Layout.Sizing;

{$mode objfpc}
{$H+}

interface

uses
  Web.Layout.Boxes;

{ Border box widths. }
procedure IntrinsicWidths(Box: TLayoutBox; out MinWidth, MaxWidth: Single);
{ The widths of the content (with border and padding), whatever the
  box's own width property says. }
procedure ContentIntrinsicWidths(Box: TLayoutBox; out MinWidth, MaxWidth: Single);
{ The shrink-to-fit border box width in Available (CSS 2.2 10.3.5). }
function ShrinkToFitWidth(Box: TLayoutBox; Available: Single): Single;
{ Fixed (non-percentage) margins left + right. }
function FixedHorizontalMargins(Box: TLayoutBox): Single;

implementation

uses
  Css.ComputedValues, Css.PropertyIds, Css.Keywords, Web.Layout.Values, Web.Layout.InlineItems,
  Web.Layout.Inline, Web.Layout.Replaced, Web.Layout.Table;

function FixedLength(Box: TLayoutBox; Id: TCssPropertyId): Single;
var
  Value: PCssComputedValue;
begin
  Value := Box.Style.Value(Id);
  if Value^.Kind = cvLength then
    Result := Value^.Number
  else
    Result := 0;
end;

function FixedHorizontalMargins(Box: TLayoutBox): Single;
begin
  Result := FixedLength(Box, cpMarginLeft) + FixedLength(Box, cpMarginRight);
end;

function FixedBorderPadding(Box: TLayoutBox): Single;
begin
  Result := Box.Style.Value(cpBorderLeftWidth)^.Number + Box.Style.Value(cpBorderRightWidth)^.Number +
    Abs(FixedLength(Box, cpPaddingLeft)) + Abs(FixedLength(Box, cpPaddingRight));
end;

function EdgeOfStyle(Box: TLayoutBox; Start: Boolean): Single;
begin
  if Start then
    Result := FixedLength(Box, cpMarginLeft) + Box.Style.Value(cpBorderLeftWidth)^.Number +
      Abs(FixedLength(Box, cpPaddingLeft))
  else
    Result := FixedLength(Box, cpMarginRight) + Box.Style.Value(cpBorderRightWidth)^.Number +
      Abs(FixedLength(Box, cpPaddingRight));
end;

procedure InlineContentWidths(Box: TLayoutBox; out MinWidth, MaxWidth: Single);
var
  Items: TInlineItems;
  Index: Integer;
  Item: PInlineItem;
  Run, Line, ChildMin, ChildMax, Indent: Single;
begin
  Items := InlineItemsOf(Box);
  MinWidth := 0;
  MaxWidth := 0;
  Run := 0;
  Indent := LengthOf(Box.Style, cpTextIndent, 0);
  Line := Indent;
  for Index := 0 to Items.Count - 1 do
  begin
    Item := @Items.Items[Index];
    case Item^.Kind of
      ikText:
        begin
          Run := Run + Item^.Width;
          Line := Line + Item^.Width;
          if Item^.CanBreakAfter or (Index = Items.Count - 1) then
          begin
            if Run - Item^.TrailingSpace > MinWidth then
              MinWidth := Run - Item^.TrailingSpace;
            Run := 0;
          end;
        end;
      ikOpen:
        begin
          Run := Run + EdgeOfStyle(Item^.Box, True);
          Line := Line + EdgeOfStyle(Item^.Box, True);
        end;
      ikClose:
        begin
          Run := Run + EdgeOfStyle(Item^.Box, False);
          Line := Line + EdgeOfStyle(Item^.Box, False);
        end;
      ikAtomic, ikFloat:
        begin
          IntrinsicWidths(Item^.Box, ChildMin, ChildMax);
          ChildMin := ChildMin + FixedHorizontalMargins(Item^.Box);
          ChildMax := ChildMax + FixedHorizontalMargins(Item^.Box);
          if Run + ChildMin > MinWidth then
            MinWidth := Run + ChildMin;
          Run := 0;
          Line := Line + ChildMax;
        end;
      ikBlock:
        begin
          IntrinsicWidths(Item^.Box, ChildMin, ChildMax);
          if ChildMin + FixedHorizontalMargins(Item^.Box) > MinWidth then
            MinWidth := ChildMin + FixedHorizontalMargins(Item^.Box);
          if ChildMax + FixedHorizontalMargins(Item^.Box) > MaxWidth then
            MaxWidth := ChildMax + FixedHorizontalMargins(Item^.Box);
          Line := 0;
          Run := 0;
        end;
      ikForcedBreak:
        begin
          if Line > MaxWidth then
            MaxWidth := Line;
          Line := 0;
          if Run > MinWidth then
            MinWidth := Run;
          Run := 0;
        end;
    end;
  end;
  if Run > MinWidth then
    MinWidth := Run;
  if Line > MaxWidth then
    MaxWidth := Line;
  { Trailing spaces of the last line hang. }
  if (Items.Count > 0) and (Items.Items[Items.Count - 1].Kind = ikText) then
    MaxWidth := MaxWidth - Items.Items[Items.Count - 1].TrailingSpace;
  if MaxWidth < MinWidth then
    MaxWidth := MinWidth;
end;

procedure BlockChildrenWidths(Box: TLayoutBox; out MinWidth, MaxWidth: Single);
var
  Child: TLayoutBox;
  ChildMin, ChildMax, Margins, FloatRun: Single;
begin
  MinWidth := 0;
  MaxWidth := 0;
  FloatRun := 0;
  Child := Box.FirstChild;
  while Child <> nil do
  begin
    if not Child.IsAbsolutelyPositioned and not (bfOutsideMarker in Child.Flags) then
    begin
      IntrinsicWidths(Child, ChildMin, ChildMax);
      Margins := FixedHorizontalMargins(Child);
      if ChildMin + Margins > MinWidth then
        MinWidth := ChildMin + Margins;
      if Child.IsFloating then
      begin
        FloatRun := FloatRun + ChildMax + Margins;
        if FloatRun > MaxWidth then
          MaxWidth := FloatRun;
      end
      else
      begin
        FloatRun := 0;
        if ChildMax + Margins > MaxWidth then
          MaxWidth := ChildMax + Margins;
      end;
    end;
    Child := Child.NextSibling;
  end;
end;

procedure FlexChildrenWidths(Box: TLayoutBox; out MinWidth, MaxWidth: Single);
var
  Child: TLayoutBox;
  ChildMin, ChildMax, Margins, Gap: Single;
  Row, Wraps: Boolean;
  Count: Integer;
begin
  MinWidth := 0;
  MaxWidth := 0;
  Row := KeywordIn(Box.Style.Keyword(cpFlexDirection), [kwRow, kwRowReverse]);
  Wraps := Box.Style.Keyword(cpFlexWrap) <> kwNowrap;
  Gap := LengthOf(Box.Style, cpColumnGap, 0);
  Count := 0;
  Child := Box.FirstChild;
  while Child <> nil do
  begin
    if not Child.IsAbsolutelyPositioned then
    begin
      IntrinsicWidths(Child, ChildMin, ChildMax);
      Margins := FixedHorizontalMargins(Child);
      if Row then
      begin
        MaxWidth := MaxWidth + ChildMax + Margins;
        if Wraps then
        begin
          if ChildMin + Margins > MinWidth then
            MinWidth := ChildMin + Margins;
        end
        else
          MinWidth := MinWidth + ChildMin + Margins;
        Inc(Count);
      end
      else
      begin
        if ChildMin + Margins > MinWidth then
          MinWidth := ChildMin + Margins;
        if ChildMax + Margins > MaxWidth then
          MaxWidth := ChildMax + Margins;
      end;
    end;
    Child := Child.NextSibling;
  end;
  if Row and (Count > 1) then
  begin
    MaxWidth := MaxWidth + Gap * (Count - 1);
    if not Wraps then
      MinWidth := MinWidth + Gap * (Count - 1);
  end;
end;

procedure ContentIntrinsicWidths(Box: TLayoutBox; out MinWidth, MaxWidth: Single);
var
  Edges: Single;
begin
  Edges := FixedBorderPadding(Box);
  case Box.Kind of
    bkReplaced:
      begin
        MaxWidth := ReplacedContentWidth(TReplacedBox(Box), -1);
        MinWidth := MaxWidth;
        if HasPercentage(Box.Style, cpWidth) or HasPercentage(Box.Style, cpMaxWidth) then
          MinWidth := 0;
        Exit;
      end;
    bkFlex, bkGrid:
      FlexChildrenWidths(Box, MinWidth, MaxWidth);
    bkTable:
      begin
        TableIntrinsicWidths(Box, MinWidth, MaxWidth);
        Exit;
      end;
    bkText, bkLineBreak, bkInline:
      begin
        MinWidth := 0;
        MaxWidth := 0;
      end;
  else
    if bfChildrenInline in Box.Flags then
      InlineContentWidths(Box, MinWidth, MaxWidth)
    else
      BlockChildrenWidths(Box, MinWidth, MaxWidth);
  end;
  MinWidth := MinWidth + Edges;
  MaxWidth := MaxWidth + Edges;
end;

procedure IntrinsicWidths(Box: TLayoutBox; out MinWidth, MaxWidth: Single);
var
  Specified, Edges, MinLimit, MaxLimit: Single;
  Value: PCssComputedValue;
begin
  if (Box.MinContentWidth >= 0) and (Box.MaxContentWidth >= 0) then
  begin
    MinWidth := Box.MinContentWidth;
    MaxWidth := Box.MaxContentWidth;
    Exit;
  end;
  Edges := FixedBorderPadding(Box);
  Value := Box.Style.Value(cpWidth);
  if (Value^.Kind = cvLength) and (Box.Kind <> bkInline) then
  begin
    Specified := Value^.Number;
    if Box.Style.Keyword(cpBoxSizing) = kwBorderBox then
    begin
      if Specified < Edges then
        Specified := Edges;
    end
    else
      Specified := Specified + Edges;
    MinWidth := Specified;
    MaxWidth := Specified;
  end
  else
    ContentIntrinsicWidths(Box, MinWidth, MaxWidth);
  { min-width and max-width with fixed lengths. }
  Value := Box.Style.Value(cpMaxWidth);
  if Value^.Kind = cvLength then
  begin
    MaxLimit := Value^.Number;
    if Box.Style.Keyword(cpBoxSizing) <> kwBorderBox then
      MaxLimit := MaxLimit + Edges;
    if MaxWidth > MaxLimit then
      MaxWidth := MaxLimit;
    if MinWidth > MaxLimit then
      MinWidth := MaxLimit;
  end;
  Value := Box.Style.Value(cpMinWidth);
  if Value^.Kind = cvLength then
  begin
    MinLimit := Value^.Number;
    if Box.Style.Keyword(cpBoxSizing) <> kwBorderBox then
      MinLimit := MinLimit + Edges;
    if MinWidth < MinLimit then
      MinWidth := MinLimit;
    if MaxWidth < MinLimit then
      MaxWidth := MinLimit;
  end;
  if MaxWidth < MinWidth then
    MaxWidth := MinWidth;
  Box.MinContentWidth := MinWidth;
  Box.MaxContentWidth := MaxWidth;
end;

function ShrinkToFitWidth(Box: TLayoutBox; Available: Single): Single;
var
  MinWidth, MaxWidth: Single;
begin
  IntrinsicWidths(Box, MinWidth, MaxWidth);
  Result := Available;
  if Result > MaxWidth then
    Result := MaxWidth;
  if Result < MinWidth then
    Result := MinWidth;
end;

end.
