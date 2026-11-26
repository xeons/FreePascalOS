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
  Flex layout (CSS Flexible Box Layout 1, section 9).

  The items (in-flow children in order-modified document order) get
  their flex base sizes (flex-basis, else the main size property, else
  the content size) and hypothetical main sizes (clamped by min/max,
  with the automatic minimum size of items whose overflow is visible),
  are collected into lines (one unless flex-wrap; gaps between items),
  and each line's flexible lengths are resolved by the specification's
  loop: grow or shrink by the flex factors (shrink weighted by the base
  size), freeze the items that hit their min or max, repeat. Then the
  cross sizes: each item laid out at its main size, lines as tall as
  their tallest item (the container's size for a single line with a
  definite cross size), align-content shares the free cross space
  between lines, stretched items are laid out again at the line's
  cross size. Main axis alignment gives free space to auto margins or
  by justify-content; cross axis alignment by align-self/align-items
  (start, end, center, baseline, stretch). Reversed directions and
  wrap-reverse mirror the placement.
}
unit Web.Layout.Flex;

{$mode objfpc}
{$H+}

interface

uses
  Web.Layout.Boxes, Web.Layout.Context;

procedure LayoutFlexContainer(Box: TLayoutBox; const Input: TLayoutInput);

implementation

uses
  Math, Css.ComputedStyle, Css.ComputedValues, Css.PropertyIds, Css.Keywords, Web.Layout.Values,
  Web.Layout.Sizing, Web.Layout.Dispatch;

type
  TFlexItem = record
    Box: TLayoutBox;
    Order: Integer;
    Grow, Shrink: Single;
    BaseSize: Single;
    Hypothetical: Single;
    MinMain, MaxMain: Single;
    Target: Single;
    Frozen: Boolean;
    { Margins along the main axis (auto counts 0 here) and cross. }
    MainMarginStart, MainMarginEnd, CrossMarginStart, CrossMarginEnd: Single;
    MainAutoStart, MainAutoEnd, CrossAutoStart, CrossAutoEnd: Boolean;
    CrossSize: Single;
    Baseline: Single;
    Align: TCssKeyword;
    MainPosition, CrossPosition: Single;
  end;

  TFlexLine = record
    First, Count: Integer;
    CrossSize: Single;
    CrossPosition: Single;
    MaxBaseline: Single;
  end;

  TFlexState = record
    Box: TLayoutBox;
    Input: TLayoutInput;
    Row, MainReverse, WrapReverse, Wraps: Boolean;
    InnerMain: Single;
    InnerCross: Single;
    MainGap, CrossGap: Single;
    Items: array of TFlexItem;
    Lines: array of TFlexLine;
    LineCount: Integer;
  end;

function KeywordValue(Style: TCssComputedStyle; Id: TCssPropertyId): TCssKeyword;
var
  Value: PCssComputedValue;
  Index: Integer;
begin
  Value := Style.Value(Id);
  if Value^.Kind = cvKeyword then
    Exit(TCssKeyword(Value^.Keyword));
  Result := kwNormal;
  if (Value^.Kind = cvValue) and (Value^.Data <> nil) then
    for Index := 0 to Value^.Data.Count - 1 do
      if not KeywordIn(Value^.Data.Items[Index].Keyword, [kwSafe, kwUnsafe, kwFirst, kwLast, kwLegacy]) then
        Exit(Value^.Data.Items[Index].Keyword);
end;

function GapOf(Style: TCssComputedStyle; Id: TCssPropertyId; Basis: Single): Single;
begin
  if IsAutoValue(Style, Id) then
    Result := 0
  else
    Result := LengthOf(Style, Id, Basis);
end;

{ Lays out an item with its main size (and cross size if given) fixed. }
procedure LayItemOut(var State: TFlexState; var Item: TFlexItem; MainSize, CrossSize: Single);
var
  ChildInput: TLayoutInput;
  Box: TLayoutBox;
  ContentHeight: Single;
begin
  Box := Item.Box;
  ContentHeight := Indefinite;
  if not State.Row and (State.InnerMain >= 0) then
    ContentHeight := State.InnerMain
  else if State.Row and (State.InnerCross >= 0) then
    ContentHeight := State.InnerCross;
  ChildInput := MakeChildInput(State.Input, State.Box.ContentWidth, ContentHeight, wmFixed);
  ChildInput.Floats := nil;
  ChildInput.BfcX := 0;
  ChildInput.BfcY := 0;
  if State.Row then
  begin
    ChildInput.FixedWidth := MainSize;
    ChildInput.FixedHeight := CrossSize;
  end
  else
  begin
    if CrossSize >= 0 then
      ChildInput.FixedWidth := CrossSize
    else
    begin
      ChildInput.WidthMode := wmShrinkToFit;
      ChildInput.AvailableWidth := State.Box.ContentWidth;
    end;
    ChildInput.FixedHeight := MainSize;
  end;
  LayoutBox(Box, ChildInput);
end;

procedure CollectItems(var State: TFlexState);
var
  Child: TLayoutBox;
  Count, Index, Other: Integer;
  Item: TFlexItem;
begin
  Count := 0;
  Child := State.Box.FirstChild;
  while Child <> nil do
  begin
    if Child.IsAbsolutelyPositioned then
    begin
      Child.StaticX := State.Box.ContentLeft;
      Child.StaticY := State.Box.ContentTop;
      if (bfFixed in Child.Flags) and (State.Input.FixedBoxes <> nil) then
        State.Input.FixedBoxes.Add(Child)
      else if State.Input.Positioned <> nil then
        State.Input.Positioned.Add(Child);
    end
    else
    begin
      if Count >= Length(State.Items) then
        SetLength(State.Items, Count * 2 + 4);
      FillChar(State.Items[Count], SizeOf(TFlexItem), 0);
      State.Items[Count].Box := Child;
      State.Items[Count].Order := Round(Child.Style.Value(cpOrder)^.Number);
      Inc(Count);
    end;
    Child := Child.NextSibling;
  end;
  SetLength(State.Items, Count);
  { A stable insertion sort by order. }
  for Index := 1 to Count - 1 do
  begin
    Item := State.Items[Index];
    Other := Index - 1;
    while (Other >= 0) and (State.Items[Other].Order > Item.Order) do
    begin
      State.Items[Other + 1] := State.Items[Other];
      Dec(Other);
    end;
    State.Items[Other + 1] := Item;
  end;
end;

function AlignOf(Container, Item: TLayoutBox): TCssKeyword;
begin
  Result := KeywordValue(Item.Style, cpAlignSelf);
  if KeywordIn(Result, [kwAuto, kwNormal]) then
    Result := KeywordValue(Container.Style, cpAlignItems);
  if KeywordIn(Result, [kwNormal]) then
    Result := kwStretch;
end;

{ The width a column's item is laid out at: its own width (kept to
  min-width and max-width), else the container's inner width when it is
  stretched in a single line (CSS Flexbox 9.4 and 9.8: that cross size
  is definite), else -1 (fit-content). }
function ColumnItemWidth(const State: TFlexState; const Item: TFlexItem; Align: TCssKeyword): Single;
var
  ContainerWidth: Single;
begin
  ContainerWidth := State.Box.ContentWidth;
  Result := SpecifiedBorderBoxWidth(Item.Box, ContainerWidth);
  if Result >= 0 then
    Result := ClampWidth(Item.Box, Result, ContainerWidth)
  else if (Align = kwStretch) and not Item.CrossAutoStart and not Item.CrossAutoEnd then
    Result := Max(0, ContainerWidth - Item.CrossMarginStart - Item.CrossMarginEnd);
end;

procedure ResolveBaseSizes(var State: TFlexState);
var
  Index: Integer;
  Item: ^TFlexItem;
  Box: TLayoutBox;
  Style: TCssComputedStyle;
  Basis: PCssComputedValue;
  Value, MinContent, MaxContent, Specified, Edges: Single;
  HasBasis: Boolean;
  BorderBox: Boolean;
begin
  for Index := 0 to High(State.Items) do
  begin
    Item := @State.Items[Index];
    Box := Item^.Box;
    Style := Box.Style;
    ResolveBoxEdges(Box, State.Box.ContentWidth);
    Item^.Grow := Style.Value(cpFlexGrow)^.Number;
    Item^.Shrink := Style.Value(cpFlexShrink)^.Number;
    BorderBox := Style.Keyword(cpBoxSizing) = kwBorderBox;
    if State.Row then
    begin
      Item^.MainMarginStart := Box.Margin[sideLeft];
      Item^.MainMarginEnd := Box.Margin[sideRight];
      Item^.CrossMarginStart := Box.Margin[sideTop];
      Item^.CrossMarginEnd := Box.Margin[sideBottom];
      Item^.MainAutoStart := IsAutoValue(Style, cpMarginLeft);
      Item^.MainAutoEnd := IsAutoValue(Style, cpMarginRight);
      Item^.CrossAutoStart := IsAutoValue(Style, cpMarginTop);
      Item^.CrossAutoEnd := IsAutoValue(Style, cpMarginBottom);
      Edges := HorizontalBorderPadding(Box);
    end
    else
    begin
      Item^.MainMarginStart := Box.Margin[sideTop];
      Item^.MainMarginEnd := Box.Margin[sideBottom];
      Item^.CrossMarginStart := Box.Margin[sideLeft];
      Item^.CrossMarginEnd := Box.Margin[sideRight];
      Item^.MainAutoStart := IsAutoValue(Style, cpMarginTop);
      Item^.MainAutoEnd := IsAutoValue(Style, cpMarginBottom);
      Item^.CrossAutoStart := IsAutoValue(Style, cpMarginLeft);
      Item^.CrossAutoEnd := IsAutoValue(Style, cpMarginRight);
      Edges := VerticalBorderPadding(Box);
    end;
    { flex-basis }
    Basis := Style.Value(cpFlexBasis);
    HasBasis := False;
    if Basis^.Kind in [cvLength, cvPercentage, cvLengthPercentage, cvCalc] then
    begin
      HasBasis := TryLength(Style, cpFlexBasis, State.InnerMain, Value);
      if HasBasis then
      begin
        if BorderBox then
          Value := Max(Value, Edges)
        else
          Value := Value + Edges;
      end;
    end;
    if not HasBasis and not ((Basis^.Kind = cvKeyword) and (TCssKeyword(Basis^.Keyword) = kwContent)) then
    begin
      if State.Row then
        Specified := SpecifiedBorderBoxWidth(Box, State.InnerMain)
      else
        Specified := SpecifiedBorderBoxHeight(Box, State.InnerMain);
      if Specified >= 0 then
      begin
        Value := Specified;
        HasBasis := True;
      end;
    end;
    if not HasBasis then
    begin
      if State.Row then
      begin
        IntrinsicWidths(Box, MinContent, MaxContent);
        Value := MaxContent;
      end
      else
      begin
        if State.Wraps then
          LayItemOut(State, Item^, -1, -1)
        else
          LayItemOut(State, Item^, -1, ColumnItemWidth(State, Item^, AlignOf(State.Box, Box)));
        Value := Box.Height;
      end;
    end;
    Item^.BaseSize := Value;
    { min/max main sizes, with the automatic minimum. }
    if State.Row then
    begin
      Item^.MaxMain := MaxBorderBoxWidth(Box, State.InnerMain);
      if IsAutoValue(Style, cpMinWidth) and not (bfClipsOverflow in Box.Flags) then
      begin
        { The content-based minimum: the min-content width, but no more
          than a specified width. }
        ContentIntrinsicWidths(Box, MinContent, MaxContent);
        Item^.MinMain := MinContent;
        Specified := SpecifiedBorderBoxWidth(Box, State.InnerMain);
        if (Specified >= 0) and (Specified < Item^.MinMain) then
          Item^.MinMain := Specified;
      end
      else
        Item^.MinMain := MinBorderBoxWidth(Box, State.InnerMain);
    end
    else
    begin
      Item^.MaxMain := MaxBorderBoxHeight(Box, State.InnerMain);
      Item^.MinMain := MinBorderBoxHeight(Box, State.InnerMain);
      if IsAutoValue(Style, cpMinHeight) and not (bfClipsOverflow in Box.Flags) and not HasBasis then
        Item^.MinMain := Max(Item^.MinMain, 0);
    end;
    if (Item^.MaxMain >= 0) and (Item^.MinMain > Item^.MaxMain) then
      Item^.MinMain := Item^.MaxMain;
    Item^.Hypothetical := Item^.BaseSize;
    if (Item^.MaxMain >= 0) and (Item^.Hypothetical > Item^.MaxMain) then
      Item^.Hypothetical := Item^.MaxMain;
    if Item^.Hypothetical < Item^.MinMain then
      Item^.Hypothetical := Item^.MinMain;
    if Item^.Hypothetical < Edges then
      Item^.Hypothetical := Edges;
  end;
end;

procedure CollectLines(var State: TFlexState);
var
  Index, Count: Integer;
  Used, Outer, Limit: Single;
begin
  State.LineCount := 0;
  SetLength(State.Lines, Length(State.Items) + 1);
  Index := 0;
  Limit := State.InnerMain;
  while Index < Length(State.Items) do
  begin
    State.Lines[State.LineCount].First := Index;
    Count := 0;
    Used := 0;
    while Index < Length(State.Items) do
    begin
      Outer := State.Items[Index].Hypothetical + State.Items[Index].MainMarginStart + State.Items[Index].MainMarginEnd;
      if Count > 0 then
        Outer := Outer + State.MainGap;
      if State.Wraps and (Count > 0) and (Limit >= 0) and (Used + Outer > Limit + 0.01) then
        Break;
      Used := Used + Outer;
      Inc(Count);
      Inc(Index);
    end;
    State.Lines[State.LineCount].Count := Count;
    Inc(State.LineCount);
  end;
  if State.LineCount = 0 then
  begin
    State.Lines[0].First := 0;
    State.Lines[0].Count := 0;
    State.LineCount := 1;
  end;
end;

{ 9.7: resolving flexible lengths of one line. }
procedure ResolveFlexibleLengths(var State: TFlexState; const Line: TFlexLine; Available: Single);
var
  Index, Last: Integer;
  Item: ^TFlexItem;
  Used, Free, InitialFree, FactorSum, ScaledSum, Violation, TotalViolation, Clamped: Single;
  Growing: Boolean;
  Guard: Integer;
begin
  Last := Line.First + Line.Count - 1;
  Used := 0;
  for Index := Line.First to Last do
    Used := Used + State.Items[Index].Hypothetical + State.Items[Index].MainMarginStart +
      State.Items[Index].MainMarginEnd;
  if Line.Count > 1 then
    Used := Used + State.MainGap * (Line.Count - 1);
  Growing := (Available >= 0) and (Used < Available);
  for Index := Line.First to Last do
  begin
    Item := @State.Items[Index];
    Item^.Target := Item^.BaseSize;
    Item^.Frozen := (Available < 0) or (Growing and (Item^.Grow = 0)) or (not Growing and (Item^.Shrink = 0)) or
      (Growing and (Item^.BaseSize > Item^.Hypothetical)) or (not Growing and (Item^.BaseSize < Item^.Hypothetical));
    if Item^.Frozen then
      Item^.Target := Item^.Hypothetical;
  end;
  if Available < 0 then
    Exit;
  { The initial free space. }
  InitialFree := Available;
  for Index := Line.First to Last do
  begin
    Item := @State.Items[Index];
    InitialFree := InitialFree - Item^.MainMarginStart - Item^.MainMarginEnd;
    if Item^.Frozen then
      InitialFree := InitialFree - Item^.Target
    else
      InitialFree := InitialFree - Item^.BaseSize;
  end;
  if Line.Count > 1 then
    InitialFree := InitialFree - State.MainGap * (Line.Count - 1);
  Guard := 0;
  repeat
    Inc(Guard);
    Free := Available;
    FactorSum := 0;
    for Index := Line.First to Last do
    begin
      Item := @State.Items[Index];
      Free := Free - Item^.MainMarginStart - Item^.MainMarginEnd;
      if Item^.Frozen then
        Free := Free - Item^.Target
      else
      begin
        Free := Free - Item^.BaseSize;
        if Growing then
          FactorSum := FactorSum + Item^.Grow
        else
          FactorSum := FactorSum + Item^.Shrink;
      end;
    end;
    if Line.Count > 1 then
      Free := Free - State.MainGap * (Line.Count - 1);
    if FactorSum = 0 then
      Break;
    if FactorSum < 1 then
      if Abs(InitialFree * FactorSum) < Abs(Free) then
        Free := InitialFree * FactorSum;
    { Distribute. }
    if Growing then
    begin
      for Index := Line.First to Last do
      begin
        Item := @State.Items[Index];
        if not Item^.Frozen then
          Item^.Target := Item^.BaseSize + Free * Item^.Grow / FactorSum;
      end;
    end
    else
    begin
      ScaledSum := 0;
      for Index := Line.First to Last do
        if not State.Items[Index].Frozen then
          ScaledSum := ScaledSum + State.Items[Index].Shrink * State.Items[Index].BaseSize;
      for Index := Line.First to Last do
      begin
        Item := @State.Items[Index];
        if not Item^.Frozen then
          if ScaledSum > 0 then
            Item^.Target := Item^.BaseSize + Free * Item^.Shrink * Item^.BaseSize / ScaledSum
          else
            Item^.Target := Item^.BaseSize;
      end;
    end;
    { Fix min/max violations. }
    TotalViolation := 0;
    for Index := Line.First to Last do
    begin
      Item := @State.Items[Index];
      if Item^.Frozen then
        Continue;
      Clamped := Item^.Target;
      if (Item^.MaxMain >= 0) and (Clamped > Item^.MaxMain) then
        Clamped := Item^.MaxMain;
      if Clamped < Item^.MinMain then
        Clamped := Item^.MinMain;
      if Clamped < 0 then
        Clamped := 0;
      Violation := Clamped - Item^.Target;
      TotalViolation := TotalViolation + Violation;
      Item^.Target := Clamped;
      { Remember the sign in Baseline for the freezing below. }
      Item^.Baseline := Violation;
    end;
    for Index := Line.First to Last do
    begin
      Item := @State.Items[Index];
      if Item^.Frozen then
        Continue;
      if (Abs(TotalViolation) < 0.001) or ((TotalViolation > 0) and (Item^.Baseline > 0)) or
         ((TotalViolation < 0) and (Item^.Baseline < 0)) then
        Item^.Frozen := True;
      Item^.Baseline := 0;
    end;
    Clamped := 0;
    for Index := Line.First to Last do
      if not State.Items[Index].Frozen then
        Clamped := 1;
  until (Clamped = 0) or (Guard > 50);
end;

function ItemBaseline(Box: TLayoutBox; Row: Boolean): Single;
begin
  if Box.FirstBaseline >= 0 then
    Result := Box.FirstBaseline
  else
    Result := Box.Height;
end;

procedure LayoutFlexContainer(Box: TLayoutBox; const Input: TLayoutInput);
var
  State: TFlexState;
  Direction, Justify, AlignContent: TCssKeyword;
  LineIndex, Index, Last, AutoMargins: Integer;
  Item: ^TFlexItem;
  Line: ^TFlexLine;
  Used, Free, Position, Between, CrossTotal, CrossFree, LineGapExtra, Offset, Size, Specified: Single;
  ContentMain, ContentCross, Stretched: Single;
  ContentHeight: Single;
begin
  { The container's own width. }
  if Input.WidthMode = wmShrinkToFit then
    ComputeUsedWidth(Box, Input)
  else
    ComputeUsedWidth(Box, Input);
  Box.FirstBaseline := -1;
  Box.LastBaseline := -1;
  State.Box := Box;
  State.Input := Input;
  State.Items := nil;
  Direction := Box.Style.Keyword(cpFlexDirection);
  State.Row := KeywordIn(Direction, [kwRow, kwRowReverse]);
  { The legacy -webkit-box lays its children out in a column when
    -webkit-box-orient says vertical. }
  if KeywordIn(Box.Style.Keyword(cpDisplay), [kwWebkitBox, kwWebkitInlineBox]) then
    State.Row := not KeywordIn(Box.Style.Keyword(cpWebkitBoxOrient), [kwVertical, kwBlockAxis]);
  State.MainReverse := KeywordIn(Direction, [kwRowReverse, kwColumnReverse]);
  State.Wraps := Box.Style.Keyword(cpFlexWrap) <> kwNowrap;
  State.WrapReverse := Box.Style.Keyword(cpFlexWrap) = kwWrapReverse;
  ContentHeight := DefiniteContentHeight(Box, Input);
  if State.Row then
  begin
    State.InnerMain := Box.ContentWidth;
    State.InnerCross := ContentHeight;
    State.MainGap := GapOf(Box.Style, cpColumnGap, Box.ContentWidth);
    State.CrossGap := GapOf(Box.Style, cpRowGap, Max(ContentHeight, 0));
  end
  else
  begin
    State.InnerMain := ContentHeight;
    State.InnerCross := Box.ContentWidth;
    State.MainGap := GapOf(Box.Style, cpRowGap, Max(ContentHeight, 0));
    State.CrossGap := GapOf(Box.Style, cpColumnGap, Box.ContentWidth);
  end;
  CollectItems(State);
  ResolveBaseSizes(State);
  { A column with an indefinite height: its main size is the content's. }
  CollectLines(State);
  for LineIndex := 0 to State.LineCount - 1 do
    ResolveFlexibleLengths(State, State.Lines[LineIndex], State.InnerMain);
  { Hypothetical cross sizes. }
  for Index := 0 to High(State.Items) do
  begin
    Item := @State.Items[Index];
    Item^.Align := AlignOf(Box, Item^.Box);
    if State.Row then
    begin
      LayItemOut(State, Item^, Item^.Target, -1);
      Item^.CrossSize := Item^.Box.Height;
    end
    else
    begin
      LayItemOut(State, Item^, Item^.Target, ColumnItemWidth(State, Item^, Item^.Align));
      Item^.CrossSize := Item^.Box.Width;
    end;
    Item^.Baseline := ItemBaseline(Item^.Box, State.Row);
  end;
  { Line cross sizes. }
  CrossTotal := 0;
  for LineIndex := 0 to State.LineCount - 1 do
  begin
    Line := @State.Lines[LineIndex];
    Line^.CrossSize := 0;
    Line^.MaxBaseline := 0;
    for Index := Line^.First to Line^.First + Line^.Count - 1 do
      if (State.Items[Index].Align = kwBaseline) and State.Row then
        Line^.MaxBaseline := Max(Line^.MaxBaseline, State.Items[Index].Baseline + State.Items[Index].CrossMarginStart);
    for Index := Line^.First to Line^.First + Line^.Count - 1 do
    begin
      Item := @State.Items[Index];
      Size := Item^.CrossSize + Item^.CrossMarginStart + Item^.CrossMarginEnd;
      if (Item^.Align = kwBaseline) and State.Row then
        Size := Size + Line^.MaxBaseline - Item^.Baseline - Item^.CrossMarginStart;
      if Size > Line^.CrossSize then
        Line^.CrossSize := Size;
    end;
    CrossTotal := CrossTotal + Line^.CrossSize;
  end;
  if State.LineCount > 1 then
    CrossTotal := CrossTotal + State.CrossGap * (State.LineCount - 1);
  if not State.Wraps and (State.InnerCross >= 0) then
  begin
    State.Lines[0].CrossSize := State.InnerCross;
    CrossTotal := State.InnerCross;
  end;
  { The container's cross size. }
  if State.Row then
  begin
    if State.InnerCross >= 0 then
      ContentCross := State.InnerCross
    else
      ContentCross := CrossTotal;
  end
  else
    ContentCross := Box.ContentWidth;
  { align-content. }
  AlignContent := KeywordValue(Box.Style, cpAlignContent);
  CrossFree := ContentCross - CrossTotal;
  Position := 0;
  LineGapExtra := 0;
  if (CrossFree > 0) and State.Wraps then
    case AlignContent of
      kwFlexEnd, kwEnd: Position := CrossFree;
      kwCenter: Position := CrossFree / 2;
      kwSpaceBetween:
        if State.LineCount > 1 then
          LineGapExtra := CrossFree / (State.LineCount - 1);
      kwSpaceAround:
        begin
          LineGapExtra := CrossFree / State.LineCount;
          Position := LineGapExtra / 2;
        end;
      kwSpaceEvenly:
        begin
          LineGapExtra := CrossFree / (State.LineCount + 1);
          Position := LineGapExtra;
        end;
      kwNormal, kwStretch:
        for LineIndex := 0 to State.LineCount - 1 do
          State.Lines[LineIndex].CrossSize := State.Lines[LineIndex].CrossSize + CrossFree / State.LineCount;
    end;
  for LineIndex := 0 to State.LineCount - 1 do
  begin
    State.Lines[LineIndex].CrossPosition := Position;
    Position := Position + State.Lines[LineIndex].CrossSize + State.CrossGap + LineGapExtra;
  end;
  { Stretch, main axis placement, cross placement. }
  ContentMain := 0;
  for LineIndex := 0 to State.LineCount - 1 do
  begin
    Line := @State.Lines[LineIndex];
    Last := Line^.First + Line^.Count - 1;
    for Index := Line^.First to Last do
    begin
      Item := @State.Items[Index];
      if (Item^.Align = kwStretch) and not Item^.CrossAutoStart and not Item^.CrossAutoEnd then
      begin
        if State.Row and IsAutoValue(Item^.Box.Style, cpHeight) then
        begin
          Stretched := ClampHeight(Item^.Box, Line^.CrossSize - Item^.CrossMarginStart - Item^.CrossMarginEnd,
            State.InnerCross);
          if Abs(Stretched - Item^.CrossSize) > 0.01 then
          begin
            Item^.Box.MarkNeedsLayout;
            LayItemOut(State, Item^, Item^.Target, Stretched);
          end;
          Item^.CrossSize := Stretched;
        end
        else if not State.Row and IsAutoValue(Item^.Box.Style, cpWidth) then
        begin
          Stretched := ClampWidth(Item^.Box, Line^.CrossSize - Item^.CrossMarginStart - Item^.CrossMarginEnd,
            Box.ContentWidth);
          if Abs(Stretched - Item^.CrossSize) > 0.01 then
            LayItemOut(State, Item^, Item^.Target, Stretched);
          Item^.CrossSize := Stretched;
        end;
      end;
    end;
    { Main axis. }
    Used := 0;
    AutoMargins := 0;
    for Index := Line^.First to Last do
    begin
      Item := @State.Items[Index];
      if State.Row then
        Size := Item^.Box.Width
      else
        Size := Item^.Box.Height;
      Used := Used + Size + Item^.MainMarginStart + Item^.MainMarginEnd;
      if Item^.MainAutoStart then
        Inc(AutoMargins);
      if Item^.MainAutoEnd then
        Inc(AutoMargins);
    end;
    if Line^.Count > 1 then
      Used := Used + State.MainGap * (Line^.Count - 1);
    if State.InnerMain >= 0 then
      Free := State.InnerMain - Used
    else
      Free := 0;
    if Used > ContentMain then
      ContentMain := Used;
    Position := 0;
    Between := 0;
    if (AutoMargins > 0) and (Free > 0) then
    begin
      for Index := Line^.First to Last do
      begin
        Item := @State.Items[Index];
        if Item^.MainAutoStart then
          Item^.MainMarginStart := Item^.MainMarginStart + Free / AutoMargins;
        if Item^.MainAutoEnd then
          Item^.MainMarginEnd := Item^.MainMarginEnd + Free / AutoMargins;
      end;
      Free := 0;
    end;
    Justify := KeywordValue(Box.Style, cpJustifyContent);
    if Free > 0 then
      case Justify of
        kwFlexEnd, kwEnd, kwRight: Position := Free;
        kwCenter: Position := Free / 2;
        kwSpaceBetween:
          if Line^.Count > 1 then
            Between := Free / (Line^.Count - 1);
        kwSpaceAround:
          begin
            Between := Free / Line^.Count;
            Position := Between / 2;
          end;
        kwSpaceEvenly:
          begin
            Between := Free / (Line^.Count + 1);
            Position := Between;
          end;
      end
    else if (Free < 0) and KeywordIn(Justify, [kwCenter]) then
      Position := Free / 2
    else if (Free < 0) and KeywordIn(Justify, [kwFlexEnd, kwEnd]) then
      Position := Free;
    for Index := Line^.First to Last do
    begin
      Item := @State.Items[Index];
      Position := Position + Item^.MainMarginStart;
      Item^.MainPosition := Position;
      if State.Row then
        Size := Item^.Box.Width
      else
        Size := Item^.Box.Height;
      Position := Position + Size + Item^.MainMarginEnd + State.MainGap + Between;
      { Cross axis. }
      if State.Row then
        Size := Item^.Box.Height
      else
        Size := Item^.Box.Width;
      Offset := 0;
      CrossFree := Line^.CrossSize - Size - Item^.CrossMarginStart - Item^.CrossMarginEnd;
      if Item^.CrossAutoStart and Item^.CrossAutoEnd then
        Offset := CrossFree / 2
      else if Item^.CrossAutoStart then
        Offset := CrossFree
      else if Item^.CrossAutoEnd then
        Offset := 0
      else
        case Item^.Align of
          kwFlexEnd, kwEnd, kwSelfEnd: Offset := CrossFree;
          kwCenter: Offset := CrossFree / 2;
          kwBaseline:
            if State.Row then
              Offset := Line^.MaxBaseline - Item^.Baseline - Item^.CrossMarginStart;
        end;
      if State.WrapReverse then
        Offset := CrossFree - Offset;
      Item^.CrossPosition := Line^.CrossPosition + Item^.CrossMarginStart + Offset;
    end;
  end;
  { The container's height. }
  if State.Row then
    ComputeUsedHeight(Box, Input, ContentCross)
  else
  begin
    if State.InnerMain >= 0 then
      ComputeUsedHeight(Box, Input, State.InnerMain)
    else
      ComputeUsedHeight(Box, Input, ContentMain);
  end;
  { Positions (reversed axes mirrored). }
  for Index := 0 to High(State.Items) do
  begin
    Item := @State.Items[Index];
    if State.Row then
    begin
      if State.MainReverse then
        Item^.Box.X := Box.ContentLeft + Box.ContentWidth - Item^.MainPosition - Item^.Box.Width
      else
        Item^.Box.X := Box.ContentLeft + Item^.MainPosition;
      if State.WrapReverse then
        Item^.Box.Y := Box.ContentTop + Box.ContentHeight - Item^.CrossPosition - Item^.Box.Height
      else
        Item^.Box.Y := Box.ContentTop + Item^.CrossPosition;
    end
    else
    begin
      if State.MainReverse then
        Item^.Box.Y := Box.ContentTop + Box.ContentHeight - Item^.MainPosition - Item^.Box.Height
      else
        Item^.Box.Y := Box.ContentTop + Item^.MainPosition;
      if State.WrapReverse then
        Item^.Box.X := Box.ContentLeft + Box.ContentWidth - Item^.CrossPosition - Item^.Box.Width
      else
        Item^.Box.X := Box.ContentLeft + Item^.CrossPosition;
    end;
    if Item^.Box.FirstBaseline >= 0 then
    begin
      if Box.FirstBaseline < 0 then
        Box.FirstBaseline := Item^.Box.Y + Item^.Box.FirstBaseline;
      Box.LastBaseline := Item^.Box.Y + Item^.Box.FirstBaseline;
    end;
  end;
  if (Box.FirstBaseline < 0) and (Length(State.Items) > 0) then
  begin
    Box.FirstBaseline := State.Items[0].Box.Y + State.Items[0].Box.Height;
    Box.LastBaseline := Box.FirstBaseline;
  end;
  Box.TopPositive := Max(Box.Margin[sideTop], 0);
  Box.TopNegative := Min(Box.Margin[sideTop], 0);
  Box.BottomPositive := Max(Box.Margin[sideBottom], 0);
  Box.BottomNegative := Min(Box.Margin[sideBottom], 0);
  Box.CollapsesThrough := False;
end;

end.
