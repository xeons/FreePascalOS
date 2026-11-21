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
  Block formatting (CSS 2.2 9.4.1, 10.3.3, 10.6.3, 8.3.1).

  A block container's in-flow block-level children are stacked
  vertically. Adjoining vertical margins collapse: a run of them
  becomes the largest positive plus the most negative; the first
  child's top margin collapses through its parent's top (and the last
  child's bottom margin through its bottom) when the parent has no
  border or padding there and does not establish a formatting context;
  an empty block lets its own margins collapse through it. Each box
  reports the margins that collapse through its top and bottom
  (TopPositive ...), so its parent can go on collapsing.

  Floats are placed in the formatting context's float list; clear moves
  a box below them (clearance stops the collapsing above it); a box
  that establishes a formatting context is placed beside the floats.
  A child placed somewhere else than first guessed is laid out again
  when floats could have affected it. A formatting context root's auto
  height includes its floats. List markers outside the content are put
  left of the first line.
}
unit Web.Layout.Block;

{$mode objfpc}
{$H+}

interface

uses
  Web.Layout.Boxes, Web.Layout.Context;

{ The contents of a block container (width set here, height too). }
procedure LayoutBlockFlow(Box: TLayoutBox; const Input: TLayoutInput);

implementation

uses
  Css.ComputedStyle, Css.ComputedValues, Css.PropertyIds, Css.Keywords, Web.Layout.Values, Web.Layout.Floats,
  Web.Layout.Inline, Web.Layout.Dispatch, Web.Layout.Sizing;

type
  TMarginStrut = record
    Positive, Negative: Single;
  end;

procedure AddMargin(var Strut: TMarginStrut; Margin: Single); inline;
begin
  if Margin > Strut.Positive then
    Strut.Positive := Margin;
  if Margin < Strut.Negative then
    Strut.Negative := Margin;
end;

procedure JoinStrut(var Strut: TMarginStrut; Positive, Negative: Single); inline;
begin
  if Positive > Strut.Positive then
    Strut.Positive := Positive;
  if Negative < Strut.Negative then
    Strut.Negative := Negative;
end;

function Resolve(const Strut: TMarginStrut): Single; inline;
begin
  Result := Strut.Positive + Strut.Negative;
end;

function EmptyStrut: TMarginStrut; inline;
begin
  Result.Positive := 0;
  Result.Negative := 0;
end;

procedure SetOwnMargins(Box: TLayoutBox);
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

{ The box's own top (or bottom) margin as what collapses there. }
procedure AddMarginTo(Box: TLayoutBox; Top: Boolean);
var
  Margin: Single;
begin
  if Top then
  begin
    Margin := Box.Margin[sideTop];
    if Margin > 0 then
      Box.TopPositive := Margin
    else
      Box.TopNegative := Margin;
  end
  else
  begin
    Margin := Box.Margin[sideBottom];
    if Margin > 0 then
      Box.BottomPositive := Margin
    else
      Box.BottomNegative := Margin;
  end;
end;

procedure PlaceOutsideMarker(Box, Marker: TLayoutBox; const Input: TLayoutInput);
var
  ChildInput: TLayoutInput;
  Baseline: Single;
  Child: TLayoutBox;
begin
  ChildInput := MakeChildInput(Input, Box.ContentWidth, Indefinite, wmShrinkToFit);
  ChildInput.Floats := nil;
  LayoutBox(Marker, ChildInput);
  Baseline := Box.FirstBaseline;
  if Baseline < 0 then
  begin
    { The first in-flow child's first line. }
    Child := Box.FirstChild;
    while (Child <> nil) and ((Child = Marker) or Child.IsOutOfFlow) do
      Child := Child.NextSibling;
    if (Child <> nil) and (Child.FirstBaseline >= 0) then
      Baseline := Child.Y + Child.FirstBaseline;
  end;
  Marker.X := Box.ContentLeft - Marker.Width - Marker.Margin[sideRight] - Marker.Style.FontSize * 0.3;
  if Baseline >= 0 then
    Marker.Y := Baseline - Marker.FirstBaseline
  else
    Marker.Y := Box.ContentTop;
end;

procedure LayoutFloat(Box, Child: TLayoutBox; const Input: TLayoutInput; ContentWidth, ContentHeight, Y: Single);
var
  ChildInput: TLayoutInput;
  PlacedX, PlacedY, MinimumY: Single;
  Floats: TFloatContext;
  ClearBottom: Single;
  Clear: TCssKeyword;
begin
  ChildInput := MakeChildInput(Input, ContentWidth, ContentHeight, wmShrinkToFit);
  LayoutBox(Child, ChildInput);
  Floats := Input.Floats;
  MinimumY := Input.BfcY + Box.ContentTop + Y;
  Clear := Child.Style.Keyword(cpClear);
  if Clear <> kwNone then
  begin
    ClearBottom := Floats.ClearanceBottom(KeywordIn(Clear, [kwLeft, kwBoth, kwInlineStart]),
      KeywordIn(Clear, [kwRight, kwBoth, kwInlineEnd]));
    if ClearBottom > MinimumY then
      MinimumY := ClearBottom;
  end;
  Floats.Place(bfFloatLeft in Child.Flags, Child.MarginBoxWidth, Child.MarginBoxHeight, MinimumY,
    Input.BfcX + Box.ContentLeft, Input.BfcX + Box.ContentLeft + ContentWidth, PlacedX, PlacedY);
  Child.X := PlacedX - Input.BfcX + Child.Margin[sideLeft];
  Child.Y := PlacedY - Input.BfcY + Child.Margin[sideTop];
end;

procedure LayoutBlockChildren(Box: TLayoutBox; const Input: TLayoutInput; ContentWidth, ContentHeight: Single;
  out UsedContentHeight: Single);
var
  Child, Marker: TLayoutBox;
  ChildInput: TLayoutInput;
  Y, Estimate, ChildY, ClearY, BandLeft, BandRight, Origin, Shift: Single;
  Pending, ParentTop, Combined: TMarginStrut;
  CollapseTop, CollapseBottom, FirstInFlow, Cleared, NewContext: Boolean;
  Clear: TCssKeyword;
  Attempt, FloatsBefore: Integer;
begin
  CollapseTop := not (bfNewFormattingContext in Box.Flags) and (Box.Border[sideTop] = 0) and
    (Box.Padding[sideTop] = 0) and (Box.Kind <> bkViewport);
  CollapseBottom := not (bfNewFormattingContext in Box.Flags) and (Box.Border[sideBottom] = 0) and
    (Box.Padding[sideBottom] = 0) and IsAutoValue(Box.Style, cpHeight) and (Box.Kind <> bkViewport);
  ParentTop := EmptyStrut;
  AddMargin(ParentTop, Box.Margin[sideTop]);
  Pending := EmptyStrut;
  Y := 0;
  FirstInFlow := True;
  Marker := nil;
  Child := Box.FirstChild;
  while Child <> nil do
  begin
    if bfOutsideMarker in Child.Flags then
    begin
      Marker := Child;
      Child := Child.NextSibling;
      Continue;
    end;
    if Child.IsAbsolutelyPositioned then
    begin
      Child.StaticX := Box.ContentLeft;
      if FirstInFlow and CollapseTop then
        Child.StaticY := Box.ContentTop + Y
      else
        Child.StaticY := Box.ContentTop + Y + Resolve(Pending);
      if bfFixed in Child.Flags then
      begin
        if Input.FixedBoxes <> nil then
          Input.FixedBoxes.Add(Child);
      end
      else if Input.Positioned <> nil then
        Input.Positioned.Add(Child);
      Child := Child.NextSibling;
      Continue;
    end;
    if Child.IsFloating then
    begin
      if FirstInFlow and CollapseTop then
        LayoutFloat(Box, Child, Input, ContentWidth, ContentHeight, Y)
      else
        LayoutFloat(Box, Child, Input, ContentWidth, ContentHeight, Y + Resolve(Pending));
      Child := Child.NextSibling;
      Continue;
    end;
    { An in-flow block-level box. }
    { The edges are the child's layout's to set (a skipped layout keeps them). }
    Combined := Pending;
    AddMargin(Combined, LengthOf(Child.Style, cpMarginTop, ContentWidth));
    if FirstInFlow and CollapseTop then
      Estimate := Y
    else
      Estimate := Y + Resolve(Combined);
    { Clearance. }
    Cleared := False;
    ClearY := 0;
    Clear := Child.Style.Keyword(cpClear);
    if (Clear <> kwNone) and (Input.Floats.Count > 0) then
    begin
      ClearY := Input.Floats.ClearanceBottom(KeywordIn(Clear, [kwLeft, kwBoth, kwInlineStart]),
        KeywordIn(Clear, [kwRight, kwBoth, kwInlineEnd])) - Input.BfcY - Box.ContentTop;
      if ClearY > Estimate then
      begin
        Cleared := True;
        Estimate := ClearY;
      end;
    end;
    NewContext := (bfNewFormattingContext in Child.Flags) or (Child.Kind = bkReplaced);
    Attempt := 0;
    FloatsBefore := Input.Floats.Count;
    repeat
      Input.Floats.Truncate(FloatsBefore);
      ChildInput := MakeChildInput(Input, ContentWidth, ContentHeight, wmStretch);
      Shift := 0;
      if NewContext and (Input.Floats.Count > 0) then
      begin
        { Beside the floats. }
        Origin := Input.BfcX + Box.ContentLeft;
        if Input.Floats.FreeBand(Input.BfcY + Box.ContentTop + Estimate, 1, Origin, Origin + ContentWidth,
          BandLeft, BandRight) then
        begin
          Include(Box.Flags, bfSawOutsideFloats);
          Shift := BandLeft - Origin;
          ChildInput.AvailableWidth := BandRight - BandLeft;
          if IsAutoValue(Child.Style, cpWidth) and not (Child.Kind in [bkTable, bkReplaced]) then
          begin
            ChildInput.WidthMode := wmFixed;
            ChildInput.FixedWidth := ChildInput.AvailableWidth - LengthOf(Child.Style, cpMarginLeft, ContentWidth) -
              LengthOf(Child.Style, cpMarginRight, ContentWidth);
            if ChildInput.FixedWidth < 0 then
              ChildInput.FixedWidth := 0;
          end;
        end;
      end;
      if Child.Kind = bkTable then
        ChildInput.WidthMode := wmShrinkToFit;
      ChildInput.BfcX := Input.BfcX + Box.ContentLeft + Shift + LengthOf(Child.Style, cpMarginLeft, ContentWidth);
      ChildInput.BfcY := Input.BfcY + Box.ContentTop + Estimate;
      if bfNewFormattingContext in Child.Flags then
      begin
        ChildInput.Floats := nil;
        ChildInput.BfcX := 0;
        ChildInput.BfcY := 0;
      end;
      LayoutBox(Child, ChildInput);
      Combined := Pending;
      JoinStrut(Combined, Child.TopPositive, Child.TopNegative);
      if Cleared then
        ChildY := ClearY
      else if FirstInFlow and CollapseTop then
        ChildY := Y
      else
        ChildY := Y + Resolve(Combined);
      ChildY := ChildY + Child.LeadingOffset;
      Inc(Attempt);
      if (Abs(ChildY - Estimate) < 0.01) or (Input.Floats.Count = 0) or (Attempt >= 2) or
         (bfNewFormattingContext in Child.Flags) and not NewContext then
        Break;
      Estimate := ChildY;
      Child.MarkNeedsLayout;
    until False;
    { A table centred with auto margins: its width came from shrink-to-fit. }
    if (Child.Kind = bkTable) and IsAutoValue(Child.Style, cpMarginLeft) and IsAutoValue(Child.Style, cpMarginRight) then
    begin
      Child.Margin[sideLeft] := (ChildInput.AvailableWidth - Child.Width) / 2;
      if Child.Margin[sideLeft] < 0 then
        Child.Margin[sideLeft] := 0;
    end
    else if (Child.Kind = bkTable) and IsAutoValue(Child.Style, cpMarginLeft) then
      Child.Margin[sideLeft] := ChildInput.AvailableWidth - Child.Width - Child.Margin[sideRight]
    else if (Child.Kind = bkTable) and not IsAutoValue(Child.Style, cpMarginRight) and
      (Box.Style.Keyword(cpTextAlign) = kwWebkitCenter) and
      (ChildInput.AvailableWidth - Child.Width - Child.Margin[sideLeft] - Child.Margin[sideRight] > 0) then
      { In <center> (text-align: -webkit-center) a table is centred too. }
      Child.Margin[sideLeft] := Child.Margin[sideLeft] +
        (ChildInput.AvailableWidth - Child.Width - Child.Margin[sideLeft] - Child.Margin[sideRight]) / 2;
    Child.X := Box.ContentLeft + Shift + Child.Margin[sideLeft];
    if FirstInFlow and CollapseTop and not Cleared then
    begin
      JoinStrut(ParentTop, Combined.Positive, Combined.Negative);
      if Child.CollapsesThrough then
      begin
        JoinStrut(ParentTop, Child.BottomPositive, Child.BottomNegative);
        Child.Y := Box.ContentTop + Y;
        Pending := EmptyStrut;
      end
      else
      begin
        Child.Y := Box.ContentTop + Y + Child.LeadingOffset;
        Y := Y + Child.LeadingOffset + Child.Height;
        Pending := EmptyStrut;
        Pending.Positive := Child.BottomPositive;
        Pending.Negative := Child.BottomNegative;
        FirstInFlow := False;
      end;
    end
    else if Child.CollapsesThrough and not Cleared then
    begin
      Child.Y := Box.ContentTop + ChildY;
      Pending := Combined;
      JoinStrut(Pending, Child.BottomPositive, Child.BottomNegative);
      FirstInFlow := False;
    end
    else
    begin
      Child.Y := Box.ContentTop + ChildY;
      Y := ChildY + Child.Height;
      Pending := EmptyStrut;
      Pending.Positive := Child.BottomPositive;
      Pending.Negative := Child.BottomNegative;
      FirstInFlow := False;
    end;
    if (Box.FirstBaseline < 0) and (Child.FirstBaseline >= 0) then
      Box.FirstBaseline := Child.Y + Child.FirstBaseline;
    if Child.LastBaseline >= 0 then
      Box.LastBaseline := Child.Y + Child.LastBaseline;
    Child := Child.NextSibling;
  end;
  { The bottom. }
  Box.TopPositive := 0;
  Box.TopNegative := 0;
  Box.BottomPositive := 0;
  Box.BottomNegative := 0;
  Box.CollapsesThrough := False;
  if CollapseTop then
  begin
    Box.TopPositive := ParentTop.Positive;
    Box.TopNegative := ParentTop.Negative;
  end
  else
    AddMarginTo(Box, True);
  if CollapseBottom then
  begin
    AddMargin(Pending, Box.Margin[sideBottom]);
    Box.BottomPositive := Pending.Positive;
    Box.BottomNegative := Pending.Negative;
    UsedContentHeight := Y;
    if FirstInFlow and CollapseTop and (Y = 0) and
       (MinBorderBoxHeight(Box, Input.ContainingHeight) <= 0) then
    begin
      Box.CollapsesThrough := True;
      JoinStrut(ParentTop, Pending.Positive, Pending.Negative);
      Box.TopPositive := ParentTop.Positive;
      Box.TopNegative := ParentTop.Negative;
      Box.BottomPositive := ParentTop.Positive;
      Box.BottomNegative := ParentTop.Negative;
    end;
  end
  else
  begin
    UsedContentHeight := Y + Resolve(Pending);
    AddMarginTo(Box, False);
  end;
end;

procedure LayoutBlockFlow(Box: TLayoutBox; const Input: TLayoutInput);
var
  ContentHeight, ContentWidth, ChildContainingHeight, Lowest: Single;
  OwnFloats: TFloatContext;
  Inner: TLayoutInput;
  Marker, Child: TLayoutBox;
begin
  if Box.Kind = bkViewport then
  begin
    Box.Width := Input.AvailableWidth;
    Box.Height := Input.ContainingHeight;
    Box.Margin[sideTop] := 0;
    Box.Margin[sideBottom] := 0;
  end
  else
    ComputeUsedWidth(Box, Input);
  ContentWidth := Box.ContentWidth;
  Box.FirstBaseline := -1;
  Box.LastBaseline := -1;
  ChildContainingHeight := DefiniteContentHeight(Box, Input);
  Inner := Input;
  OwnFloats := nil;
  if (bfNewFormattingContext in Box.Flags) or (Input.Floats = nil) then
  begin
    OwnFloats := TFloatContext.Create;
    Inner.Floats := OwnFloats;
    Inner.BfcX := 0;
    Inner.BfcY := 0;
  end;
  try
    if bfChildrenInline in Box.Flags then
    begin
      LayoutInlineContent(Box, Inner, ContentWidth, ContentHeight);
      SetOwnMargins(Box);
      if (ContentHeight = 0) and (Box.Inline.LineCount = 0) and IsAutoValue(Box.Style, cpHeight) and
         (VerticalBorderPadding(Box) = 0) and not (bfNewFormattingContext in Box.Flags) and
         (MinBorderBoxHeight(Box, Input.ContainingHeight) <= 0) then
      begin
        Box.CollapsesThrough := True;
        if Box.BottomPositive > Box.TopPositive then
          Box.TopPositive := Box.BottomPositive;
        if Box.BottomNegative < Box.TopNegative then
          Box.TopNegative := Box.BottomNegative;
        Box.BottomPositive := Box.TopPositive;
        Box.BottomNegative := Box.TopNegative;
      end;
    end
    else
    begin
      Inner.ContainingHeight := ChildContainingHeight;
      LayoutBlockChildren(Box, Inner, ContentWidth, ChildContainingHeight, ContentHeight);
    end;
    if OwnFloats <> nil then
    begin
      Lowest := OwnFloats.LowestBottom - Box.ContentTop;
      if (Box.Kind <> bkViewport) and (Lowest > ContentHeight) then
        ContentHeight := Lowest;
    end;
  finally
    OwnFloats.Free;
  end;
  Box.ContentExtent := ContentHeight;
  if Box.Kind <> bkViewport then
    ComputeUsedHeight(Box, Input, ContentHeight)
  else
  begin
    Box.ScrollHeight := ContentHeight;
  end;
  { An outside list marker. }
  Marker := nil;
  Child := Box.FirstChild;
  while Child <> nil do
  begin
    if bfOutsideMarker in Child.Flags then
      Marker := Child;
    Child := Child.NextSibling;
  end;
  if Marker <> nil then
    PlaceOutsideMarker(Box, Marker, Input);
end;

end.
