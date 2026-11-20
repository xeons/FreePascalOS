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
  Laying out one box, whatever its kind.

  LayoutBox resolves the box's margins, borders and padding, its used
  width (filling the containing block with auto margins per CSS 2.2
  10.3.3, shrink-to-fit, or given), lays out its contents with the
  formatting context its kind has (block flow, inline content, flex,
  table, replaced), its height (auto from the contents, or specified,
  min/max clamped), and, when it is positioned, its absolutely
  positioned descendants. The box's own position is the caller's to
  set.

  Incremental layout: a box that is not dirty, was laid out for the
  same input and does not depend on floats or containing blocks outside
  it keeps its previous layout and is skipped.
}
unit Web.Layout.Dispatch;

{$mode objfpc}
{$H+}

interface

uses
  Web.Layout.Boxes, Web.Layout.Context;

procedure LayoutBox(Box: TLayoutBox; const Input: TLayoutInput);
{ An input for the children of a box: the content width and height
  (Indefinite when unknown) and the width mode, the rest inherited. }
function MakeChildInput(const Parent: TLayoutInput; ContentWidth, ContentHeight: Single;
  Mode: TWidthMode): TLayoutInput;
{ Sets Box.Width (and auto margins) for the input. }
procedure ComputeUsedWidth(Box: TLayoutBox; const Input: TLayoutInput);
{ Box.Height from the content height (content box) and the style. }
procedure ComputeUsedHeight(Box: TLayoutBox; const Input: TLayoutInput; ContentHeight: Single);
{ The definite content height of a laid out box for its children's
  percentages, or Indefinite. }
function DefiniteContentHeight(Box: TLayoutBox; const Input: TLayoutInput): Single;
{ relative position offsets. }
procedure ComputeRelativeOffset(Box: TLayoutBox; ContainingWidth, ContainingHeight: Single);

var
  BoxesLaidOut: Int64 = 0;
  BoxesSkipped: Int64 = 0;

implementation

uses
  Css.ComputedValues, Css.PropertyIds, Css.Keywords, Web.Layout.Values, Web.Layout.Sizing, Web.Layout.Block,
  Web.Layout.Replaced, Web.Layout.Flex, Web.Layout.Grid, Web.Layout.Table, Web.Layout.Positioned;

function MakeChildInput(const Parent: TLayoutInput; ContentWidth, ContentHeight: Single;
  Mode: TWidthMode): TLayoutInput;
begin
  Result := Parent;
  Result.AvailableWidth := ContentWidth;
  Result.ContainingHeight := ContentHeight;
  Result.WidthMode := Mode;
  Result.FixedWidth := -1;
  Result.FixedHeight := -1;
end;

procedure ComputeUsedWidth(Box: TLayoutBox; const Input: TLayoutInput);
var
  Available, Specified, Remaining: Single;
  LeftAuto, RightAuto: Boolean;
begin
  Available := Input.AvailableWidth;
  if Available < 0 then
    Available := 0;
  LeftAuto := IsAutoValue(Box.Style, cpMarginLeft);
  RightAuto := IsAutoValue(Box.Style, cpMarginRight);
  case Input.WidthMode of
    wmFixed:
      begin
        Box.Width := Input.FixedWidth;
        Exit;
      end;
    wmShrinkToFit:
      begin
        Specified := SpecifiedBorderBoxWidth(Box, Input.AvailableWidth);
        if Specified < 0 then
          Specified := ShrinkToFitWidth(Box, Available - Box.Margin[sideLeft] - Box.Margin[sideRight]);
        Box.Width := ClampWidth(Box, Specified, Input.AvailableWidth);
        Exit;
      end;
  end;
  Specified := SpecifiedBorderBoxWidth(Box, Input.AvailableWidth);
  if Specified < 0 then
  begin
    Box.Width := ClampWidth(Box, Available - Box.Margin[sideLeft] - Box.Margin[sideRight], Input.AvailableWidth);
    if Box.Width >= Available - Box.Margin[sideLeft] - Box.Margin[sideRight] - 0.01 then
      Exit;
  end
  else
    Box.Width := ClampWidth(Box, Specified, Input.AvailableWidth);
  { Auto margins share what is left (CSS 2.2 10.3.3). }
  Remaining := Available - Box.Width - Box.Margin[sideLeft] - Box.Margin[sideRight];
  if LeftAuto and RightAuto then
  begin
    if Remaining < 0 then
    begin
      Box.Margin[sideLeft] := 0;
      Box.Margin[sideRight] := Available - Box.Width;
    end
    else
    begin
      Box.Margin[sideLeft] := Remaining / 2;
      Box.Margin[sideRight] := Remaining / 2;
    end;
  end
  else if LeftAuto then
    Box.Margin[sideLeft] := Box.Margin[sideLeft] + Remaining
  else if RightAuto then
    Box.Margin[sideRight] := Box.Margin[sideRight] + Remaining
  else if Box.Style.Keyword(cpDirection) = kwRtl then
    Box.Margin[sideLeft] := Box.Margin[sideLeft] + Remaining
  else
    Box.Margin[sideRight] := Box.Margin[sideRight] + Remaining;
  { text-align: -webkit-center on the parent centers blocks too (HTML's align). }
  if not LeftAuto and not RightAuto and (Box.Parent <> nil) and (Remaining > 0) and
     (Box.Parent.Style <> nil) and (Box.Parent.Style.Keyword(cpTextAlign) = kwWebkitCenter) and
     not (bfAnonymous in Box.Flags) then
  begin
    Box.Margin[sideLeft] := Box.Margin[sideLeft] + Remaining / 2;
    Box.Margin[sideRight] := Box.Margin[sideRight] - Remaining / 2;
  end;
end;

function DefiniteContentHeight(Box: TLayoutBox; const Input: TLayoutInput): Single;
var
  Specified: Single;
begin
  if Input.FixedHeight >= 0 then
    Exit(Input.FixedHeight - VerticalBorderPadding(Box));
  if Box.Kind = bkViewport then
    Exit(Box.Height);
  if bfAbsolute in Box.Flags then
  begin
    if not IsAutoValue(Box.Style, cpTop) and not IsAutoValue(Box.Style, cpBottom) and
       IsAutoValue(Box.Style, cpHeight) and (Box.Height > 0) then
      Exit(Box.ContentHeight);
  end;
  Specified := SpecifiedBorderBoxHeight(Box, Input.ContainingHeight);
  if Specified < 0 then
    Exit(Indefinite);
  Result := ClampHeight(Box, Specified, Input.ContainingHeight) - VerticalBorderPadding(Box);
  if Result < 0 then
    Result := 0;
end;

procedure ComputeUsedHeight(Box: TLayoutBox; const Input: TLayoutInput; ContentHeight: Single);
var
  Specified: Single;
begin
  if Input.FixedHeight >= 0 then
  begin
    Box.Height := Input.FixedHeight;
    Exit;
  end;
  Specified := SpecifiedBorderBoxHeight(Box, Input.ContainingHeight);
  if Specified < 0 then
    Specified := ContentHeight + VerticalBorderPadding(Box);
  Box.Height := ClampHeight(Box, Specified, Input.ContainingHeight);
end;

procedure ComputeRelativeOffset(Box: TLayoutBox; ContainingWidth, ContainingHeight: Single);
var
  Value: Single;
begin
  Box.RelativeX := 0;
  Box.RelativeY := 0;
  if not (bfRelative in Box.Flags) or (bfSticky in Box.Flags) then
    Exit;
  if TryLength(Box.Style, cpLeft, ContainingWidth, Value) then
    Box.RelativeX := Value
  else if TryLength(Box.Style, cpRight, ContainingWidth, Value) then
    Box.RelativeX := -Value;
  if TryLength(Box.Style, cpTop, ContainingHeight, Value) then
    Box.RelativeY := Value
  else if TryLength(Box.Style, cpBottom, ContainingHeight, Value) then
    Box.RelativeY := -Value;
end;

procedure SetOwnCollapsingMargins(Box: TLayoutBox);
begin
  Box.TopPositive := 0;
  Box.TopNegative := 0;
  Box.BottomPositive := 0;
  Box.BottomNegative := 0;
  if Box.Margin[sideTop] > 0 then
    Box.TopPositive := Box.Margin[sideTop]
  else
    Box.TopNegative := Box.Margin[sideTop];
  if Box.Margin[sideBottom] > 0 then
    Box.BottomPositive := Box.Margin[sideBottom]
  else
    Box.BottomNegative := Box.Margin[sideBottom];
  Box.CollapsesThrough := False;
end;

function CanSkip(Box: TLayoutBox; const Input: TLayoutInput): Boolean;
begin
  Result := ([bfNeedsLayout, bfChildNeedsLayout, bfSawOutsideFloats, bfHasEscapingAbsolute] * Box.Flags = []) and
    SameLayoutInput(Box, Input) and (Box.Kind <> bkViewport);
end;

procedure LayoutBox(Box: TLayoutBox; const Input: TLayoutInput);
var
  OwnList: TPositionedList;
  ContentInput: TLayoutInput;
  PositionedBefore, FixedBefore: Integer;
  IsContainingBlock: Boolean;
begin
  if CanSkip(Box, Input) then
  begin
    Inc(BoxesSkipped);
    Exit;
  end;
  Inc(BoxesLaidOut);
  Box.Flags := Box.Flags - [bfSawOutsideFloats, bfHasEscapingAbsolute];
  ResolveBoxEdges(Box, Input.AvailableWidth);
  IsContainingBlock := Box.IsPositioned or (bfRootElement in Box.Flags) or (Box.Kind = bkViewport) or
    (Box.Style.Value(cpTransform)^.Kind <> cvKeyword);
  ContentInput := Input;
  OwnList := nil;
  if IsContainingBlock then
  begin
    OwnList := TPositionedList.Create;
    ContentInput.Positioned := OwnList;
  end;
  PositionedBefore := 0;
  FixedBefore := 0;
  if Input.Positioned <> nil then
    PositionedBefore := Input.Positioned.Count;
  if Input.FixedBoxes <> nil then
    FixedBefore := Input.FixedBoxes.Count;
  try
    case Box.Kind of
      bkReplaced:
        LayoutReplaced(TReplacedBox(Box), ContentInput);
      bkFlex:
        LayoutFlexContainer(Box, ContentInput);
      bkGrid:
        LayoutGridContainer(Box, ContentInput);
      bkTable:
        LayoutTable(Box, ContentInput);
      bkText, bkLineBreak, bkInline, bkTableColumn, bkTableColumnGroup:
        begin
          Box.Width := 0;
          Box.Height := 0;
        end;
    else
      LayoutBlockFlow(Box, ContentInput);
    end;
    if Box.Kind = bkReplaced then
      SetOwnCollapsingMargins(Box);
    ComputeRelativeOffset(Box, Input.AvailableWidth, Input.ContainingHeight);
    if OwnList <> nil then
      LayoutPositionedBoxes(Box, OwnList, ContentInput);
  finally
    OwnList.Free;
  end;
  if ((Input.Positioned <> nil) and (Input.Positioned.Count > PositionedBefore)) or
     ((Input.FixedBoxes <> nil) and (Input.FixedBoxes.Count > FixedBefore)) then
    Include(Box.Flags, bfHasEscapingAbsolute);
  Box.Flags := Box.Flags - [bfNeedsLayout, bfChildNeedsLayout];
  RememberLayoutInput(Box, Input);
end;

end.
