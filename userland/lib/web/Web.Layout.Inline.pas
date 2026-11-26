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
  Inline formatting: breaking the items into line boxes.

  Lines are filled greedily: items are added while they fit the band
  the floats leave at the line's height; when one does not, the line
  ends at the last break opportunity (a piece too wide for an empty
  line is split between characters when overflow-wrap or word-break
  allow it, else it overflows). Floats met on a line are placed beside
  it when they fit and below it otherwise; absolutely positioned boxes
  get their static position; a block inside an inline box takes lines
  of its own.

  A finished line drops its leading and hanging trailing collapsible
  spaces, is aligned (text-align, text-align-last, justify spreading the
  free space over the spaces) and indented (text-indent), and gets its
  height from the inline boxes on it: each inline box's font ascent and
  descent with half the leading of its line-height, shifted by
  vertical-align (baseline, sub, super, text-top, text-bottom, middle,
  lengths and percentages; top and bottom as baseline) and the atomic
  inlines' margin boxes on their baselines. The fragments of the line
  are written in tree order, an inline box's fragment before its
  contents, so painting can follow them.
}
unit Web.Layout.Inline;

{$mode objfpc}
{$H+}

interface

uses
  Web.Layout.Boxes, Web.Layout.Context, Web.Layout.InlineItems;

{ Lays out Container's inline content in ContentWidth; returns the height
  of its lines (content box coordinates start at 0). }
procedure LayoutInlineContent(Container: TLayoutBox; const Input: TLayoutInput; ContentWidth: Single;
  out ContentHeight: Single);
{ The container's items, collected when they are missing or stale. }
function InlineItemsOf(Container: TLayoutBox): TInlineItems;

implementation

uses
  Math, Css.ComputedStyle, Css.ComputedValues, Css.PropertyIds, Css.Keywords, Web.Text.FontInstances,
  Web.Text.Breaking, Web.Layout.Values, Web.Layout.Floats, Web.Layout.Dispatch;

const
  Epsilon = 0.01;

type
  TInlineFrame = record
    Box: TLayoutBox;
    Shift, Ascent, Descent, HalfLeading, FontSize: Single;
    Fragment: Integer;
    StartX: Single;
    HasStart: Boolean;
  end;

  TLineState = record
    Container: TLayoutBox;
    Input: TLayoutInput;
    Items: TInlineItems;
    Content: TInlineContent;
    ContentWidth: Single;
    { Item X positions within the line (from the line's left). }
    Positions: array of Single;
    { Inline boxes open across lines. }
    OpenBoxes: array of TLayoutBox;
    OpenCount: Integer;
    FirstLine: Boolean;
    Y: Single;
    SplitHappened: Boolean;
    DeferredFloats: array of TLayoutBox;
    DeferredCount: Integer;
    { Floats among the items before this index are placed (or deferred
      to the end of the line): a line scanned again - moved down past
      floats, or broken before a float it had passed - must not place
      them a second time, or each new copy narrows the line again and
      the line moves down forever. }
    FloatsPlacedBefore: Integer;
  end;

function InlineItemsOf(Container: TLayoutBox): TInlineItems;
var
  Content: TInlineContent;
begin
  if Container.Inline = nil then
    Container.Inline := TInlineContent.Create;
  Content := Container.Inline;
  if Content.Items = nil then
    Content.Items := TInlineItems.Create;
  Result := TInlineItems(Content.Items);
  if not Content.ItemsValid or (bfNeedsLayout in Container.Flags) then
  begin
    CollectInlineItems(Container, Result);
    Content.ItemsValid := True;
  end;
end;

function StartEdge(Box: TLayoutBox; ContentWidth: Single): Single;
begin
  Result := LengthOf(Box.Style, cpMarginLeft, ContentWidth) + Box.Style.Value(cpBorderLeftWidth)^.Number +
    Abs(LengthOf(Box.Style, cpPaddingLeft, ContentWidth));
end;

function EndEdge(Box: TLayoutBox; ContentWidth: Single): Single;
begin
  Result := LengthOf(Box.Style, cpMarginRight, ContentWidth) + Box.Style.Value(cpBorderRightWidth)^.Number +
    Abs(LengthOf(Box.Style, cpPaddingRight, ContentWidth));
end;

function AtomicBaseline(Box: TLayoutBox): Single;
begin
  if (Box.Kind in [bkBlock, bkFlex, bkTable]) and (Box.LastBaseline >= 0) and not (bfClipsOverflow in Box.Flags) then
  begin
    if Box.Kind = bkBlock then
      Result := Box.Margin[sideTop] + Box.LastBaseline
    else
      Result := Box.Margin[sideTop] + Box.FirstBaseline;
  end
  else
    Result := Box.MarginBoxHeight;
end;

procedure FrameMetrics(Box: TLayoutBox; out Frame: TInlineFrame);
var
  Font: TTextFont;
  LineHeight: Single;
begin
  Font := TextFontOf(Box.Style);
  Frame.Box := Box;
  Frame.Ascent := Font.Ascent;
  Frame.Descent := Font.Descent;
  Frame.FontSize := Box.Style.FontSize;
  LineHeight := UsedLineHeight(Box.Style);
  Frame.HalfLeading := (LineHeight - (Font.Ascent + Font.Descent)) / 2;
  Frame.Shift := 0;
  Frame.Fragment := -1;
  Frame.StartX := 0;
  Frame.HasStart := False;
end;

{ The baseline shift of a box (inline box or atomic) inside Parent. }
function VerticalShift(Box: TLayoutBox; const Parent: TInlineFrame; Ascent, Descent, LineHeight: Single): Single;
var
  Value: PCssComputedValue;
begin
  Value := Box.Style.Value(cpVerticalAlign);
  Result := Parent.Shift;
  case Value^.Kind of
    cvKeyword:
      case TCssKeyword(Value^.Keyword) of
        kwSub: Result := Parent.Shift + Parent.FontSize * 0.2;
        kwSuper: Result := Parent.Shift - Parent.FontSize * 0.34;
        kwTextTop: Result := Parent.Shift - Parent.Ascent + Ascent;
        kwTextBottom: Result := Parent.Shift + Parent.Descent - Descent;
        kwMiddle: Result := Parent.Shift - Parent.FontSize * 0.27 + (Ascent - Descent) / 2;
      end;
    cvLength:
      Result := Parent.Shift - Value^.Number;
    cvPercentage, cvLengthPercentage, cvCalc:
      Result := Parent.Shift - ResolveComputed(Value^, LineHeight);
  end;
end;

procedure PlaceFloat(var State: TLineState; Box: TLayoutBox; MinimumTop: Single);
var
  ChildInput: TLayoutInput;
  PlacedX, PlacedY: Single;
  ContentX, ContentY: Single;
begin
  ContentX := State.Container.ContentLeft;
  ContentY := State.Container.ContentTop;
  ChildInput := MakeChildInput(State.Input, State.ContentWidth, State.Input.ContainingHeight, wmShrinkToFit);
  ChildInput.BfcX := State.Input.BfcX + ContentX;
  ChildInput.BfcY := State.Input.BfcY + ContentY + MinimumTop;
  LayoutBox(Box, ChildInput);
  if State.Input.Floats = nil then
    Exit;
  State.Input.Floats.Place(bfFloatLeft in Box.Flags, Box.MarginBoxWidth, Box.MarginBoxHeight,
    State.Input.BfcY + ContentY + MinimumTop, State.Input.BfcX + ContentX,
    State.Input.BfcX + ContentX + State.ContentWidth, PlacedX, PlacedY);
  Box.X := PlacedX - State.Input.BfcX + Box.Margin[sideLeft];
  Box.Y := PlacedY - State.Input.BfcY + Box.Margin[sideTop];
end;

procedure LineBand(var State: TLineState; Top, Height: Single; out Left, Right: Single);
var
  BandLeft, BandRight, Origin: Single;
begin
  Left := 0;
  Right := State.ContentWidth;
  if (State.Input.Floats = nil) or (State.Input.Floats.Count = 0) then
    Exit;
  Origin := State.Input.BfcX + State.Container.ContentLeft;
  if State.Input.Floats.FreeBand(State.Input.BfcY + State.Container.ContentTop + Top, Height, Origin,
    Origin + State.ContentWidth, BandLeft, BandRight) then
  begin
    Include(State.Container.Flags, bfSawOutsideFloats);
    Left := BandLeft - Origin;
    Right := BandRight - Origin;
  end;
end;

{ Splits a text item so its first part fits in Room (at least one character). }
procedure SplitTextItem(var State: TLineState; Index: Integer; Room: Single);
var
  Item: TInlineItem;
  Text: string;
  Position, ByteCount, Fit: Integer;
  Width: Single;
  Items: TInlineItems;
  Moved: Integer;
begin
  Items := State.Items;
  Item := Items.Items[Index];
  Text := TTextBox(Item.Box).Text;
  Position := Item.Start;
  Fit := 0;
  while Position < Item.Start + Item.Length do
  begin
    CodePointAt(Text, Position, ByteCount);
    Width := MeasureTextRange(Item, Item.Start, Position + ByteCount - Item.Start);
    if (Width > Room) and (Fit > 0) then
      Break;
    Fit := Position + ByteCount - Item.Start;
    Inc(Position, ByteCount);
  end;
  if (Fit <= 0) or (Fit >= Item.Length) then
    Exit;
  Items.Add(ikText, nil);
  for Moved := Items.Count - 1 downto Index + 2 do
    Items.Items[Moved] := Items.Items[Moved - 1];
  Items.Items[Index + 1] := Item;
  Items.Items[Index + 1].Start := Item.Start + Fit;
  Items.Items[Index + 1].Length := Item.Length - Fit;
  Items.Items[Index + 1].Width := MeasureTextRange(Item, Item.Start + Fit, Item.Length - Fit);
  Items.Items[Index].Length := Fit;
  Items.Items[Index].Width := MeasureTextRange(Item, Item.Start, Fit);
  Items.Items[Index].TrailingSpace := 0;
  Items.Items[Index].CanBreakAfter := True;
  State.SplitHappened := True;
  if State.FloatsPlacedBefore > Index + 1 then
    Inc(State.FloatsPlacedBefore);
  if Length(State.Positions) < Items.Count then
    SetLength(State.Positions, Items.Count + 16);
end;

function TextAlignFor(Container: TLayoutBox; LastLine: Boolean): TCssKeyword;
var
  Direction: TCssKeyword;
begin
  Result := Container.Style.Keyword(cpTextAlign);
  if LastLine and (Result = kwJustify) then
  begin
    Result := Container.Style.Keyword(cpTextAlignLast);
    if (Result = kwAuto) or (Result = kwJustify) and False then
      Result := kwStart;
  end;
  Direction := Container.Style.Keyword(cpDirection);
  case Result of
    kwStart, kwMatchParent:
      if Direction = kwRtl then
        Result := kwRight
      else
        Result := kwLeft;
    kwEnd:
      if Direction = kwRtl then
        Result := kwLeft
      else
        Result := kwRight;
    kwWebkitLeft: Result := kwLeft;
    kwWebkitRight: Result := kwRight;
    kwWebkitCenter: Result := kwCenter;
  end;
end;

{ Whether a piece of text continues the line's last fragment (same box,
  next bytes, same baseline): one fragment then holds both. }
function MergesWithLast(Content: TInlineContent; Box: TLayoutBox; Start: Integer; Shift: Single): Boolean;
var
  Last: PLineFragment;
begin
  Last := @Content.Fragments[Content.FragmentCount - 1];
  Result := (Last^.Kind = fkText) and (Last^.Box = Box) and (Last^.TextStart + Last^.TextLength = Start);
end;

function VerticalBorderPaddingOfStyle(Box: TLayoutBox): Single;
begin
  Result := Box.Style.Value(cpPaddingTop)^.Number + Box.Style.Value(cpPaddingBottom)^.Number +
    Box.Style.Value(cpBorderTopWidth)^.Number + Box.Style.Value(cpBorderBottomWidth)^.Number;
end;

{ A line holding only a forced break: the strut's height. }
function FinishEmptyBreakLine(var State: TLineState; Index: Integer; StrutHeight: Single): Single;
var
  Line: TLineBoxRecord;
  Root: TInlineFrame;
begin
  FrameMetrics(State.Container, Root);
  Line.Top := State.Y;
  Line.Height := StrutHeight;
  Line.Baseline := State.Container.ContentTop + State.Y + Root.HalfLeading + Root.Ascent;
  Line.FirstFragment := State.Content.FragmentCount;
  Line.FragmentCount := 0;
  State.Content.AddLine(Line);
  if State.Container.FirstBaseline < 0 then
    State.Container.FirstBaseline := Line.Baseline;
  State.Container.LastBaseline := Line.Baseline;
  State.FirstLine := False;
  Result := StrutHeight;
end;

{ Writes the line of items [First, Last) at State.Y; returns its height
  (0 for a line with nothing to show). }
function FinishLine(var State: TLineState; First, Last: Integer; LineLeft, LineRight: Single;
  Forced, LastLine: Boolean): Single;
var
  Items: TInlineItems;
  Content: TInlineContent;
  Index, FrameCount, Spaces, FirstText, LastText, Skip: Integer;
  Frames: array of TInlineFrame;
  Root, Frame: TInlineFrame;
  Item: PInlineItem;
  X, LineWidth, Free, Offset, SpaceExtra, Indent: Single;
  TopRel, BottomRel, BaselineY, Shift, Above, Below: Single;
  HasContent: Boolean;
  Align: TCssKeyword;
  Fragment: PLineFragment;
  Line: TLineBoxRecord;
  Box: TLayoutBox;
  StartsAt, Lengths: array of Integer;
  Widths: array of Single;
  Shifts: array of Single;
  Text: string;
  ContentX: Single;

  procedure PushFrame(const Value: TInlineFrame);
  begin
    if FrameCount >= Length(Frames) then
      SetLength(Frames, FrameCount * 2 + 4);
    Frames[FrameCount] := Value;
    Inc(FrameCount);
  end;

  procedure Extend(Top, Bottom: Single);
  begin
    if Top < TopRel then
      TopRel := Top;
    if Bottom > BottomRel then
      BottomRel := Bottom;
  end;

begin
  Result := 0;
  Items := State.Items;
  Content := State.Content;
  ContentX := State.Container.ContentLeft;
  SetLength(StartsAt, Last - First + 1);
  SetLength(Lengths, Last - First + 1);
  SetLength(Widths, Last - First + 1);
  SetLength(Shifts, Last - First + 1);
  { Text ranges, with leading and trailing collapsible spaces dropped. }
  FirstText := -1;
  LastText := -1;
  for Index := First to Last - 1 do
  begin
    Item := @Items.Items[Index];
    StartsAt[Index - First] := Item^.Start;
    Lengths[Index - First] := Item^.Length;
    Widths[Index - First] := Item^.Width;
    if Item^.Kind = ikText then
    begin
      if FirstText < 0 then
        FirstText := Index;
      LastText := Index;
    end
    else if Item^.Kind = ikAtomic then
    begin
      if FirstText < 0 then
        FirstText := Index;
      LastText := Index;
    end;
  end;
  if (FirstText >= 0) and (Items.Items[FirstText].Kind = ikText) and Items.Items[FirstText].CollapsibleSpaces then
  begin
    Item := @Items.Items[FirstText];
    Text := TTextBox(Item^.Box).Text;
    Skip := 0;
    while (Skip < Item^.Length) and (Text[Item^.Start + Skip] = ' ') do
      Inc(Skip);
    if Skip > 0 then
    begin
      StartsAt[FirstText - First] := Item^.Start + Skip;
      Lengths[FirstText - First] := Item^.Length - Skip;
      Widths[FirstText - First] := MeasureTextRange(Item^, Item^.Start + Skip, Item^.Length - Skip);
    end;
  end;
  if (LastText >= 0) and (Items.Items[LastText].Kind = ikText) then
  begin
    Item := @Items.Items[LastText];
    Text := TTextBox(Item^.Box).Text;
    Skip := 0;
    while (Skip < Lengths[LastText - First]) and
          (Text[StartsAt[LastText - First] + Lengths[LastText - First] - 1 - Skip] = ' ') do
      Inc(Skip);
    if (Skip > 0) and (Item^.CollapsibleSpaces or (Item^.Box.Style.Keyword(cpWhiteSpace) = kwPreWrap)) then
    begin
      Lengths[LastText - First] := Lengths[LastText - First] - Skip;
      Widths[LastText - First] := MeasureTextRange(Item^, StartsAt[LastText - First], Lengths[LastText - First]);
    end;
  end;
  { Is there anything to show? }
  HasContent := False;
  for Index := First to Last - 1 do
    case Items.Items[Index].Kind of
      ikText:
        if Lengths[Index - First] > 0 then
          HasContent := True;
      ikAtomic:
        HasContent := True;
      ikOpen, ikClose:
        if (StartEdge(Items.Items[Index].Box, State.ContentWidth) > 0) or
           (EndEdge(Items.Items[Index].Box, State.ContentWidth) > 0) then
          HasContent := True;
    end;
  if not HasContent then
  begin
    { Keep the open boxes in step. }
    for Index := First to Last - 1 do
      if Items.Items[Index].Kind = ikOpen then
      begin
        if State.OpenCount >= Length(State.OpenBoxes) then
          SetLength(State.OpenBoxes, State.OpenCount * 2 + 4);
        State.OpenBoxes[State.OpenCount] := Items.Items[Index].Box;
        Inc(State.OpenCount);
      end
      else if (Items.Items[Index].Kind = ikClose) and (State.OpenCount > 0) then
        Dec(State.OpenCount);
    Exit(0);
  end;
  { Horizontal positions. }
  Indent := 0;
  if State.FirstLine then
    Indent := LengthOf(State.Container.Style, cpTextIndent, State.ContentWidth);
  X := Indent;
  Spaces := 0;
  for Index := First to Last - 1 do
  begin
    Item := @Items.Items[Index];
    State.Positions[Index] := X;
    case Item^.Kind of
      ikText:
        begin
          X := X + Widths[Index - First];
          if Lengths[Index - First] > 0 then
          begin
            Text := TTextBox(Item^.Box).Text;
            for Skip := StartsAt[Index - First] to StartsAt[Index - First] + Lengths[Index - First] - 1 do
              if Text[Skip] = ' ' then
                Inc(Spaces);
          end;
        end;
      ikOpen:
        X := X + StartEdge(Item^.Box, State.ContentWidth);
      ikClose:
        X := X + EndEdge(Item^.Box, State.ContentWidth);
      ikAtomic:
        X := X + Item^.Box.MarginBoxWidth;
    end;
  end;
  LineWidth := X;
  Free := (LineRight - LineLeft) - LineWidth;
  Align := TextAlignFor(State.Container, LastLine or Forced);
  Offset := 0;
  SpaceExtra := 0;
  if Free > 0 then
    case Align of
      kwRight: Offset := Free;
      kwCenter: Offset := Free / 2;
      kwJustify:
        if Spaces > 0 then
          SpaceExtra := Free / Spaces;
    end;
  { Vertical metrics. }
  FrameMetrics(State.Container, Root);
  TopRel := -(Root.Ascent + Root.HalfLeading);
  BottomRel := Root.Descent + Root.HalfLeading;
  FrameCount := 0;
  SetLength(Frames, 8);
  PushFrame(Root);
  { The boxes open from earlier lines. }
  for Index := 0 to State.OpenCount - 1 do
  begin
    FrameMetrics(State.OpenBoxes[Index], Frame);
    Frame.Shift := VerticalShift(Frame.Box, Frames[FrameCount - 1], Frame.Ascent, Frame.Descent,
      UsedLineHeight(Frame.Box.Style));
    Frame.HasStart := False;
    Frame.StartX := 0;
    Frame.Fragment := -1;
    PushFrame(Frame);
    Extend(Frame.Shift - Frame.Ascent - Frame.HalfLeading, Frame.Shift + Frame.Descent + Frame.HalfLeading);
  end;
  for Index := First to Last - 1 do
  begin
    Item := @Items.Items[Index];
    case Item^.Kind of
      ikOpen:
        begin
          FrameMetrics(Item^.Box, Frame);
          Frame.Shift := VerticalShift(Item^.Box, Frames[FrameCount - 1], Frame.Ascent, Frame.Descent,
            UsedLineHeight(Item^.Box.Style));
          PushFrame(Frame);
          Extend(Frame.Shift - Frame.Ascent - Frame.HalfLeading, Frame.Shift + Frame.Descent + Frame.HalfLeading);
          Shifts[Index - First] := Frame.Shift;
        end;
      ikClose:
        begin
          Shifts[Index - First] := Frames[FrameCount - 1].Shift;
          if FrameCount > 1 then
            Dec(FrameCount);
        end;
      ikText:
        Shifts[Index - First] := Frames[FrameCount - 1].Shift;
      ikAtomic:
        begin
          Box := Item^.Box;
          Above := AtomicBaseline(Box);
          Below := Box.MarginBoxHeight - Above;
          if KeywordIn(Box.Style.Keyword(cpVerticalAlign), [kwTop, kwBottom]) then
          begin
            { Placed once the line's extent is known. }
            Shifts[Index - First] := 0;
            Continue;
          end;
          if Box.Style.Keyword(cpVerticalAlign) = kwMiddle then
            Shift := Frames[FrameCount - 1].Shift - Frames[FrameCount - 1].FontSize * 0.27 +
              (Above - Below) / 2
          else
            Shift := VerticalShift(Box, Frames[FrameCount - 1], Above, Below, Box.MarginBoxHeight);
          Shifts[Index - First] := Shift;
          Extend(Shift - Above, Shift + Below);
        end;
    end;
  end;
  { vertical-align: top and bottom against the line's extent. }
  for Index := First to Last - 1 do
  begin
    Item := @Items.Items[Index];
    if (Item^.Kind <> ikAtomic) or not KeywordIn(Item^.Box.Style.Keyword(cpVerticalAlign), [kwTop, kwBottom]) then
      Continue;
    Box := Item^.Box;
    Above := AtomicBaseline(Box);
    Below := Box.MarginBoxHeight - Above;
    if Box.Style.Keyword(cpVerticalAlign) = kwTop then
    begin
      if TopRel + Box.MarginBoxHeight > BottomRel then
        BottomRel := TopRel + Box.MarginBoxHeight;
      Shifts[Index - First] := TopRel + Above;
    end
    else
    begin
      if BottomRel - Box.MarginBoxHeight < TopRel then
        TopRel := BottomRel - Box.MarginBoxHeight;
      Shifts[Index - First] := BottomRel - Below;
    end;
  end;
  Result := BottomRel - TopRel;
  BaselineY := State.Y - TopRel;
  { Fragments, in tree order. }
  Line.Top := State.Y;
  Line.Height := Result;
  Line.Baseline := State.Container.ContentTop + BaselineY;
  Line.FirstFragment := Content.FragmentCount;
  FrameCount := 0;
  PushFrame(Root);
  for Index := 0 to State.OpenCount - 1 do
  begin
    FrameMetrics(State.OpenBoxes[Index], Frame);
    Frame.Shift := VerticalShift(Frame.Box, Frames[FrameCount - 1], Frame.Ascent, Frame.Descent,
      UsedLineHeight(Frame.Box.Style));
    Frame.Fragment := Content.FragmentCount;
    Frame.StartX := LineLeft + Offset;
    Frame.HasStart := False;
    Content.AddFragment;
    PushFrame(Frame);
  end;
  X := LineLeft + Offset;
  SpaceExtra := SpaceExtra + 0;
  for Index := First to Last - 1 do
  begin
    Item := @Items.Items[Index];
    case Item^.Kind of
      ikOpen:
        begin
          FrameMetrics(Item^.Box, Frame);
          Frame.Shift := Shifts[Index - First];
          Frame.Fragment := Content.FragmentCount;
          Frame.StartX := X + LengthOf(Item^.Box.Style, cpMarginLeft, State.ContentWidth);
          Frame.HasStart := True;
          Content.AddFragment;
          PushFrame(Frame);
          X := X + StartEdge(Item^.Box, State.ContentWidth);
        end;
      ikClose:
        begin
          if FrameCount > 1 then
          begin
            Frame := Frames[FrameCount - 1];
            Dec(FrameCount);
            X := X + EndEdge(Item^.Box, State.ContentWidth);
            Fragment := @Content.Fragments[Frame.Fragment];
            Fragment^.Box := Frame.Box;
            Fragment^.Kind := fkInlineBox;
            Fragment^.HasStart := Frame.HasStart;
            Fragment^.HasEnd := True;
            Fragment^.X := ContentX + Frame.StartX;
            Fragment^.Width := X - LengthOf(Item^.Box.Style, cpMarginRight, State.ContentWidth) - Frame.StartX;
            Fragment^.Y := State.Container.ContentTop + BaselineY + Frame.Shift - Frame.Ascent -
              Frame.Box.Style.Value(cpPaddingTop)^.Number - Frame.Box.Style.Value(cpBorderTopWidth)^.Number;
            Fragment^.Height := Frame.Ascent + Frame.Descent + VerticalBorderPaddingOfStyle(Frame.Box);
            Fragment^.Baseline := State.Container.ContentTop + BaselineY + Frame.Shift;
          end;
        end;
      ikText:
        begin
          if (Lengths[Index - First] > 0) and (Content.FragmentCount > Line.FirstFragment) and
             MergesWithLast(Content, Item^.Box, StartsAt[Index - First], Shifts[Index - First]) then
          begin
            Fragment := @Content.Fragments[Content.FragmentCount - 1];
            Text := TTextBox(Item^.Box).Text;
            Spaces := 0;
            for Skip := StartsAt[Index - First] to StartsAt[Index - First] + Lengths[Index - First] - 1 do
              if Text[Skip] = ' ' then
                Inc(Spaces);
            Fragment^.TextLength := Fragment^.TextLength + Lengths[Index - First];
            Fragment^.Width := Fragment^.Width + Widths[Index - First] + Spaces * SpaceExtra;
            X := X + Widths[Index - First] + Spaces * SpaceExtra;
          end
          else if Lengths[Index - First] > 0 then
          begin
            Fragment := Content.AddFragment;
            Fragment^.Box := Item^.Box;
            Fragment^.Kind := fkText;
            Fragment^.TextStart := StartsAt[Index - First];
            Fragment^.TextLength := Lengths[Index - First];
            Fragment^.X := ContentX + X;
            Fragment^.Y := State.Container.ContentTop + BaselineY + Shifts[Index - First] - Item^.Font.Ascent;
            Fragment^.Height := Item^.Font.Ascent + Item^.Font.Descent;
            Fragment^.Baseline := State.Container.ContentTop + BaselineY + Shifts[Index - First];
            Fragment^.LetterExtra := LengthOf(Item^.Box.Style, cpLetterSpacing, 0);
            Fragment^.SpaceExtra := SpaceExtra + LengthOf(Item^.Box.Style, cpWordSpacing, 0);
            Text := TTextBox(Item^.Box).Text;
            Spaces := 0;
            for Skip := StartsAt[Index - First] to StartsAt[Index - First] + Lengths[Index - First] - 1 do
              if Text[Skip] = ' ' then
                Inc(Spaces);
            Fragment^.Width := Widths[Index - First] + Spaces * SpaceExtra;
            X := X + Fragment^.Width;
          end;
        end;
      ikAtomic:
        begin
          Box := Item^.Box;
          Above := AtomicBaseline(Box);
          Fragment := Content.AddFragment;
          Fragment^.Box := Box;
          Fragment^.Kind := fkAtomic;
          Fragment^.X := ContentX + X;
          Fragment^.Y := State.Container.ContentTop + BaselineY + Shifts[Index - First] - Above;
          Fragment^.Width := Box.MarginBoxWidth;
          Fragment^.Height := Box.MarginBoxHeight;
          Fragment^.Baseline := State.Container.ContentTop + BaselineY + Shifts[Index - First];
          Box.X := Fragment^.X + Box.Margin[sideLeft];
          Box.Y := Fragment^.Y + Box.Margin[sideTop];
          X := X + Box.MarginBoxWidth;
        end;
      ikForcedBreak:
        if Item^.Box.Kind = bkLineBreak then
        begin
          Fragment := Content.AddFragment;
          Fragment^.Box := Item^.Box;
          Fragment^.Kind := fkLineBreak;
          Fragment^.X := ContentX + X;
          Fragment^.Y := State.Container.ContentTop + State.Y;
          Fragment^.Height := Result;
          Fragment^.Baseline := State.Container.ContentTop + BaselineY;
        end;
      ikAbsolute:
        begin
          Item^.Box.StaticX := ContentX + X;
          Item^.Box.StaticY := State.Container.ContentTop + State.Y;
        end;
    end;
  end;
  { Boxes still open continue on the next line. }
  State.OpenCount := 0;
  for Index := 1 to FrameCount - 1 do
  begin
    Frame := Frames[Index];
    Fragment := @Content.Fragments[Frame.Fragment];
    Fragment^.Box := Frame.Box;
    Fragment^.Kind := fkInlineBox;
    Fragment^.HasStart := Frame.HasStart;
    Fragment^.HasEnd := False;
    Fragment^.X := ContentX + Frame.StartX;
    Fragment^.Width := X - Frame.StartX;
    Fragment^.Y := State.Container.ContentTop + BaselineY + Frame.Shift - Frame.Ascent -
      Frame.Box.Style.Value(cpPaddingTop)^.Number - Frame.Box.Style.Value(cpBorderTopWidth)^.Number;
    Fragment^.Height := Frame.Ascent + Frame.Descent + VerticalBorderPaddingOfStyle(Frame.Box);
    Fragment^.Baseline := State.Container.ContentTop + BaselineY + Frame.Shift;
    if State.OpenCount >= Length(State.OpenBoxes) then
      SetLength(State.OpenBoxes, State.OpenCount * 2 + 4);
    State.OpenBoxes[State.OpenCount] := Frame.Box;
    Inc(State.OpenCount);
  end;
  Line.FragmentCount := Content.FragmentCount - Line.FirstFragment;
  Content.AddLine(Line);
  if State.Container.FirstBaseline < 0 then
    State.Container.FirstBaseline := Line.Baseline;
  State.Container.LastBaseline := Line.Baseline;
  State.FirstLine := False;
end;

procedure LayOutAtomic(var State: TLineState; Box: TLayoutBox; LineTop: Single);
var
  ChildInput: TLayoutInput;
begin
  ChildInput := MakeChildInput(State.Input, State.ContentWidth, State.Input.ContainingHeight, wmShrinkToFit);
  ChildInput.Floats := nil;
  ChildInput.BfcX := 0;
  ChildInput.BfcY := 0;
  LayoutBox(Box, ChildInput);
end;

procedure LayOutBlockInInline(var State: TLineState; Box: TLayoutBox);
var
  ChildInput: TLayoutInput;
begin
  ChildInput := MakeChildInput(State.Input, State.ContentWidth, State.Input.ContainingHeight, wmStretch);
  { Where its border box will be in the formatting context (its margins
    included, as in block flow): the floats its lines go around are
    found from there. }
  ChildInput.BfcX := State.Input.BfcX + State.Container.ContentLeft +
    LengthOf(Box.Style, cpMarginLeft, State.ContentWidth);
  ChildInput.BfcY := State.Input.BfcY + State.Container.ContentTop + State.Y +
    LengthOf(Box.Style, cpMarginTop, State.ContentWidth);
  LayoutBox(Box, ChildInput);
  Box.X := State.Container.ContentLeft + Box.Margin[sideLeft];
  Box.Y := State.Container.ContentTop + State.Y + Box.Margin[sideTop];
  State.Y := State.Y + Box.MarginBoxHeight;
end;

procedure LayoutInlineContent(Container: TLayoutBox; const Input: TLayoutInput; ContentWidth: Single;
  out ContentHeight: Single);
var
  State: TLineState;
  Items: TInlineItems;
  Index, LineStart, LastBreak, Count, Deferred: Integer;
  Item: PInlineItem;
  X, LineLeft, LineRight, StrutHeight, Height, Room, Width: Single;
  HasContent, Forced, LineDone: Boolean;
  Box: TLayoutBox;
begin
  Items := InlineItemsOf(Container);
  State.Container := Container;
  State.Input := Input;
  State.Items := Items;
  State.Content := Container.Inline;
  State.Content.LineCount := 0;
  State.Content.FragmentCount := 0;
  State.ContentWidth := ContentWidth;
  SetLength(State.Positions, Items.Count + 16);
  State.OpenBoxes := nil;
  State.OpenCount := 0;
  State.FirstLine := True;
  State.Y := 0;
  State.SplitHappened := False;
  State.DeferredCount := 0;
  State.FloatsPlacedBefore := 0;
  Container.FirstBaseline := -1;
  Container.LastBaseline := -1;
  StrutHeight := UsedLineHeight(Container.Style);
  Index := 0;
  while Index < Items.Count do
  begin
    LineBand(State, State.Y, StrutHeight, LineLeft, LineRight);
    X := 0;
    if State.FirstLine then
      X := LengthOf(Container.Style, cpTextIndent, ContentWidth);
    LineStart := Index;
    LastBreak := -1;
    HasContent := False;
    Forced := False;
    LineDone := False;
    while (Index < Items.Count) and not LineDone do
    begin
      Item := @Items.Items[Index];
      case Item^.Kind of
        ikOpen:
          begin
            X := X + StartEdge(Item^.Box, ContentWidth);
            Inc(Index);
          end;
        ikClose:
          begin
            X := X + EndEdge(Item^.Box, ContentWidth);
            Inc(Index);
            if LastBreak = Index - 1 then
              LastBreak := Index;
          end;
        ikText, ikAtomic:
          begin
            if Item^.Kind = ikAtomic then
            begin
              LayOutAtomic(State, Item^.Box, State.Y);
              Width := Item^.Box.MarginBoxWidth;
              Room := Width;
            end
            else
            begin
              Width := Item^.Width;
              Room := Width - Item^.TrailingSpace;
              { Leading collapsible spaces of a line cost nothing. }
              if not HasContent and Item^.CollapsibleSpaces and (Item^.Length = Item^.SpaceCount) then
                Room := 0;
            end;
            if HasContent and (X + Room > LineRight - LineLeft + Epsilon) and (LastBreak > LineStart) then
            begin
              Index := LastBreak;
              LineDone := True;
              Continue;
            end;
            if (X + Room > LineRight - LineLeft + Epsilon) and (Item^.Kind = ikText) and Item^.CanSplit and
               ((LastBreak <= LineStart) or not HasContent) then
            begin
              SplitTextItem(State, Index, LineRight - LineLeft - X);
              Item := @Items.Items[Index];
              Width := Item^.Width;
            end;
            { A line narrowed by floats too much for the first item: below them. }
            if not HasContent and (X + Room > LineRight - LineLeft + Epsilon) and
               ((LineLeft > 0) or (LineRight < ContentWidth)) and (Input.Floats <> nil) then
            begin
              Height := Input.Floats.NextBottomBelow(Input.BfcY + Container.ContentTop + State.Y,
                Input.BfcX, Input.BfcX + 1e6) - Input.BfcY - Container.ContentTop;
              if Height > State.Y then
              begin
                State.Y := Height;
                Index := LineStart;
                LineDone := True;
                LastBreak := -2;
                Continue;
              end;
            end;
            X := X + Width;
            if (Item^.Kind = ikAtomic) or (Item^.Length > Item^.SpaceCount) or not Item^.CollapsibleSpaces then
              HasContent := True;
            Inc(Index);
            if Item^.CanBreakAfter then
              LastBreak := Index;
          end;
        ikForcedBreak:
          begin
            Inc(Index);
            Forced := True;
            LineDone := True;
          end;
        ikFloat:
          begin
            Box := Item^.Box;
            Inc(Index);
            { A float placed when this line was scanned before stays. }
            if Index > State.FloatsPlacedBefore then
            begin
              State.FloatsPlacedBefore := Index;
              if HasContent then
              begin
                if State.DeferredCount >= Length(State.DeferredFloats) then
                  SetLength(State.DeferredFloats, State.DeferredCount * 2 + 4);
                State.DeferredFloats[State.DeferredCount] := Box;
                Inc(State.DeferredCount);
              end
              else
              begin
                PlaceFloat(State, Box, State.Y);
                LineBand(State, State.Y, StrutHeight, LineLeft, LineRight);
              end;
            end;
          end;
        ikAbsolute:
          begin
            if bfFixed in Item^.Box.Flags then
            begin
              if Input.FixedBoxes <> nil then
                Input.FixedBoxes.Add(Item^.Box);
            end
            else if Input.Positioned <> nil then
              Input.Positioned.Add(Item^.Box);
            Inc(Index);
          end;
        ikBlock:
          begin
            if Index > LineStart then
            begin
              LineDone := True;
              Continue;
            end;
            LayOutBlockInInline(State, Item^.Box);
            Inc(Index);
            LineStart := Index;
            LineDone := True;
            LastBreak := -3;
          end;
      end;
    end;
    if LastBreak = -2 then
      Continue;
    if LastBreak = -3 then
      Continue;
    { The closes right after the break stay on this line. }
    while (Index < Items.Count) and (Items.Items[Index].Kind in [ikClose, ikAbsolute]) do
    begin
      if Items.Items[Index].Kind = ikAbsolute then
      begin
        if Input.Positioned <> nil then
          Input.Positioned.Add(Items.Items[Index].Box);
      end;
      Inc(Index);
    end;
    Count := Index;
    Height := FinishLine(State, LineStart, Count, LineLeft, LineRight, Forced, Index >= Items.Count);
    { An empty line after a forced break still takes the strut's height. }
    if (Height = 0) and Forced and (Index - LineStart = 1) and
       (Items.Items[LineStart].Kind = ikForcedBreak) then
      Height := FinishEmptyBreakLine(State, LineStart, StrutHeight);
    State.Y := State.Y + Height;
    for Deferred := 0 to State.DeferredCount - 1 do
      PlaceFloat(State, State.DeferredFloats[Deferred], State.Y);
    State.DeferredCount := 0;
  end;
  ContentHeight := State.Y;
  if State.SplitHappened then
    Container.Inline.ItemsValid := False;
end;

end.
