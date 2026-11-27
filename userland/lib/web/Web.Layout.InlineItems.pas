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
  The items of an inline formatting context.

  The inline-level boxes under a block container are flattened into a
  list of items: pieces of text between break opportunities, the start
  and end of inline boxes, atomic inlines, forced breaks, floats,
  absolutely positioned boxes and blocks inside inline boxes. White
  space is processed on the way (CSS Text 3 phase I: collapsing across
  box boundaries, segment breaks, tabs, pre-line), text-transform
  applied, and each text box keeps the resulting text that its items
  and later its line fragments point into. Each piece is measured once
  (Web.Text.FontInstances caches by font and string), with its trailing
  spaces apart (they hang at the end of a line) and its spaces counted
  (for justification and word-spacing).

  The same items serve line layout and the intrinsic (min-content and
  max-content) widths, and stay valid until the container's content
  changes.
}
unit Web.Layout.InlineItems;

{$mode objfpc}
{$H+}

interface

uses
  Web.Layout.Boxes, Web.Text.FontInstances;

type
  TInlineItemKind = (ikText, ikOpen, ikClose, ikAtomic, ikForcedBreak, ikFloat, ikAbsolute, ikBlock);

  TInlineItem = record
    Kind: TInlineItemKind;
    Box: TLayoutBox;
    Font: TTextFont;
    Start, Length: Integer;
    Width: Single;
    { The width of the spaces the piece ends with (they hang). }
    TrailingSpace: Single;
    SpaceCount: Integer;
    CharacterCount: Integer;
    CanBreakAfter: Boolean;
    { The spaces may be dropped at a line's start or end. }
    CollapsibleSpaces: Boolean;
    { overflow-wrap or word-break allow breaking the piece itself. }
    CanSplit: Boolean;
  end;
  PInlineItem = ^TInlineItem;

  TInlineItems = class
  public
    Items: array of TInlineItem;
    Count: Integer;
    function Add(Kind: TInlineItemKind; Box: TLayoutBox): PInlineItem;
    procedure Clear;
  end;

{ Collects the items of Container's inline content. }
procedure CollectInlineItems(Container: TLayoutBox; Items: TInlineItems);
{ The width of part of a text item (for splitting a piece). }
function MeasureTextRange(const Item: TInlineItem; Start, Count: Integer): Single;
{ The text a text box shows (its node's, or generated). }
function SourceTextOf(Box: TTextBox): string;

implementation

uses
  Web.Dom, Css.ComputedStyle, Css.Keywords, Css.PropertyIds, Css.ComputedValues, Web.Layout.Values,
  Web.Text.Breaking;

function TInlineItems.Add(Kind: TInlineItemKind; Box: TLayoutBox): PInlineItem;
begin
  if Count >= System.Length(Items) then
    SetLength(Items, Count * 2 + 16);
  Result := @Items[Count];
  FillChar(Result^, SizeOf(TInlineItem), 0);
  Result^.Kind := Kind;
  Result^.Box := Box;
  Inc(Count);
end;

procedure TInlineItems.Clear;
var
  Index: Integer;
begin
  for Index := 0 to Count - 1 do
    Items[Index].Box := nil;
  Count := 0;
end;

function SourceTextOf(Box: TTextBox): string;
begin
  if Box.IsGenerated or (Box.Node = nil) then
    Result := Box.GeneratedText
  else
    Result := TCharacterData(Box.Node).Data;
end;

type
  TCollectState = record
    Items: TInlineItems;
    { The last character placed was a collapsible space (or nothing yet
      on the line: leading spaces go). }
    PreviousSpace: Boolean;
    PreviousCodePoint: LongWord;
    AtWordStart: Boolean;
    Column: Integer;
  end;

function LetterSpacingOf(Style: TCssComputedStyle): Single;
begin
  Result := LengthOf(Style, cpLetterSpacing, 0);
end;

function WordSpacingOf(Style: TCssComputedStyle): Single;
begin
  Result := LengthOf(Style, cpWordSpacing, 0);
end;

procedure MeasureItem(Item: PInlineItem; const Text: string; Style: TCssComputedStyle);
var
  Position, ByteCount, TrailStart: Integer;
  CodePoint: LongWord;
  LetterSpacing, WordSpacing: Single;
begin
  Item^.Width := Item^.Font.MeasureText(Text, Item^.Start, Item^.Length);
  Item^.SpaceCount := 0;
  Item^.CharacterCount := 0;
  Position := Item^.Start;
  while Position < Item^.Start + Item^.Length do
  begin
    CodePoint := CodePointAt(Text, Position, ByteCount);
    Inc(Item^.CharacterCount);
    if CodePoint = 32 then
      Inc(Item^.SpaceCount);
    Inc(Position, ByteCount);
  end;
  TrailStart := Item^.Start + Item^.Length;
  while (TrailStart > Item^.Start) and (Text[TrailStart - 1] = ' ') do
    Dec(TrailStart);
  Item^.TrailingSpace := 0;
  if TrailStart < Item^.Start + Item^.Length then
    Item^.TrailingSpace := Item^.Font.MeasureText(Text, TrailStart, Item^.Start + Item^.Length - TrailStart);
  LetterSpacing := LetterSpacingOf(Style);
  WordSpacing := WordSpacingOf(Style);
  Item^.Width := Item^.Width + LetterSpacing * Item^.CharacterCount + WordSpacing * Item^.SpaceCount;
  if Item^.TrailingSpace > 0 then
    Item^.TrailingSpace := Item^.TrailingSpace + (LetterSpacing + WordSpacing) *
      (Item^.Start + Item^.Length - TrailStart);
end;

function MeasureTextRange(const Item: TInlineItem; Start, Count: Integer): Single;
var
  Text: string;
  Position, ByteCount, Characters, Spaces: Integer;
begin
  Text := TTextBox(Item.Box).Text;
  Result := Item.Font.MeasureText(Text, Start, Count);
  Characters := 0;
  Spaces := 0;
  Position := Start;
  while Position < Start + Count do
  begin
    if Text[Position] = ' ' then
      Inc(Spaces);
    CodePointAt(Text, Position, ByteCount);
    Inc(Characters);
    Inc(Position, ByteCount);
  end;
  Result := Result + LetterSpacingOf(Item.Box.Style) * Characters + WordSpacingOf(Item.Box.Style) * Spaces;
end;

{ White space processing of one text box: returns the processed text,
  with #10 standing for each forced break. Written into a buffer sized
  once for the source (it only grows for tabs), not appended to. }
function ProcessWhiteSpace(var State: TCollectState; const Source: string; Mode: TCssKeyword): string;
var
  Index, ByteCount, Spaces: Integer;
  Used: SizeInt;
  CodePoint: LongWord;
  Collapse, KeepNewlines: Boolean;
  Output: string;

  procedure AppendSpaces(Count: Integer);
  begin
    while Count > 0 do
    begin
      AppendCodePoint(Output, Used, 32);
      Dec(Count);
    end;
  end;

begin
  Collapse := not KeywordIn(Mode, [kwPre, kwPreWrap, kwBreakSpaces]);
  KeepNewlines := not KeywordIn(Mode, [kwNormal, kwNowrap]);
  Output := '';
  SetLength(Output, Length(Source) + 4);
  Used := 0;
  Index := 1;
  while Index <= Length(Source) do
  begin
    CodePoint := CodePointAt(Source, Index, ByteCount);
    Inc(Index, ByteCount);
    if CodePoint = 13 then
      Continue;
    if (CodePoint = 10) and KeepNewlines then
    begin
      { pre-line: spaces before a kept newline go. }
      if Collapse then
        while (Used > 0) and (Output[Used] = ' ') do
          Dec(Used);
      AppendCodePoint(Output, Used, 10);
      State.PreviousSpace := Collapse;
      State.Column := 0;
      Continue;
    end;
    if Collapse and ((CodePoint = 32) or (CodePoint = 9) or (CodePoint = 10) or (CodePoint = 12)) then
    begin
      if not State.PreviousSpace then
      begin
        AppendCodePoint(Output, Used, 32);
        State.PreviousSpace := True;
      end;
      Continue;
    end;
    if (CodePoint = 9) and not Collapse then
    begin
      Spaces := 8 - (State.Column mod 8);
      AppendSpaces(Spaces);
      Inc(State.Column, Spaces);
      State.PreviousSpace := False;
      Continue;
    end;
    AppendCodePoint(Output, Used, CodePoint);
    State.PreviousSpace := False;
    Inc(State.Column);
  end;
  SetLength(Output, Used);
  Result := Output;
end;

function BreakRulesOf(Style: TCssComputedStyle): TBreakRules;
var
  WhiteSpace, WordBreak: TCssKeyword;
begin
  WhiteSpace := Style.Keyword(cpWhiteSpace);
  WordBreak := Style.Keyword(cpWordBreak);
  Result.Wrap := not KeywordIn(WhiteSpace, [kwNowrap, kwPre]);
  Result.BreakAll := WordBreak = kwBreakAll;
  Result.KeepAll := WordBreak = kwKeepAll;
  Result.Anywhere := Style.Keyword(cpLineBreak) = kwAnywhere;
end;

procedure AddTextBox(var State: TCollectState; Box: TTextBox);
var
  Style: TCssComputedStyle;
  Processed, Piece: string;
  Rules: TBreakRules;
  Font: TTextFont;
  Position, PieceStart, ByteCount, NextByteCount: Integer;
  CodePoint, NextCodePoint: LongWord;
  Item: PInlineItem;
  Collapsible, Split: Boolean;
  WhiteSpace: TCssKeyword;
  LineStart, LineEnd: Integer;

  procedure EmitPiece(StartAt, EndAt: Integer; BreakAfter: Boolean);
  begin
    if EndAt <= StartAt then
      Exit;
    Item := State.Items.Add(ikText, Box);
    Item^.Font := Font;
    Item^.Start := StartAt;
    Item^.Length := EndAt - StartAt;
    Item^.CanBreakAfter := BreakAfter;
    Item^.CollapsibleSpaces := Collapsible;
    Item^.CanSplit := Split;
    MeasureItem(Item, Processed, Style);
  end;

begin
  Style := Box.Style;
  WhiteSpace := Style.Keyword(cpWhiteSpace);
  Collapsible := not KeywordIn(WhiteSpace, [kwPre, kwPreWrap, kwBreakSpaces]);
  Processed := ProcessWhiteSpace(State, SourceTextOf(Box), WhiteSpace);
  Processed := TransformText(Processed, Style.Keyword(cpTextTransform), State.AtWordStart);
  Box.Text := Processed;
  Box.SourceText := SourceTextOf(Box);
  Font := TextFontOf(Style);
  Rules := BreakRulesOf(Style);
  Split := Rules.Wrap and (KeywordIn(Style.Keyword(cpOverflowWrap), [kwBreakWord, kwAnywhere]) or
    (Style.Keyword(cpWordBreak) = kwBreakWord) or Rules.BreakAll);
  { Each line of the processed text (forced breaks are #10). }
  LineStart := 1;
  while LineStart <= Length(Processed) + 1 do
  begin
    LineEnd := LineStart;
    while (LineEnd <= Length(Processed)) and (Processed[LineEnd] <> #10) do
      Inc(LineEnd);
    PieceStart := LineStart;
    Position := LineStart;
    while Position < LineEnd do
    begin
      CodePoint := CodePointAt(Processed, Position, ByteCount);
      if (State.PreviousCodePoint <> 0) and (Position = PieceStart) and (PieceStart = LineStart) and
         (State.Items.Count > 0) and (State.Items.Items[State.Items.Count - 1].Kind = ikText) and
         BreakAllowedBetween(State.PreviousCodePoint, CodePoint, Rules) then
        State.Items.Items[State.Items.Count - 1].CanBreakAfter := True;
      if Position + ByteCount < LineEnd then
      begin
        NextCodePoint := CodePointAt(Processed, Position + ByteCount, NextByteCount);
        if BreakAllowedBetween(CodePoint, NextCodePoint, Rules) then
        begin
          EmitPiece(PieceStart, Position + ByteCount, True);
          PieceStart := Position + ByteCount;
        end;
      end;
      State.PreviousCodePoint := CodePoint;
      Inc(Position, ByteCount);
    end;
    { The last piece: a break after it if it ends with a space. }
    if PieceStart < LineEnd then
      EmitPiece(PieceStart, LineEnd, Rules.Wrap and (Processed[LineEnd - 1] = ' '));
    if LineEnd <= Length(Processed) then
    begin
      State.Items.Add(ikForcedBreak, Box);
      State.PreviousCodePoint := 0;
    end;
    LineStart := LineEnd + 1;
  end;
  Piece := '';
end;

procedure AddBoxItems(var State: TCollectState; Box: TLayoutBox);
var
  Child: TLayoutBox;
  Item: PInlineItem;
begin
  case Box.Kind of
    bkText:
      AddTextBox(State, TTextBox(Box));
    bkInline:
      begin
        State.Items.Add(ikOpen, Box);
        Child := Box.FirstChild;
        while Child <> nil do
        begin
          AddBoxItems(State, Child);
          Child := Child.NextSibling;
        end;
        State.Items.Add(ikClose, Box);
      end;
    bkLineBreak:
      begin
        State.Items.Add(ikForcedBreak, Box);
        State.PreviousSpace := True;
        State.PreviousCodePoint := 0;
        State.Column := 0;
      end;
  else
    if bfOutsideMarker in Box.Flags then
      Exit;
    if Box.IsFloating then
      State.Items.Add(ikFloat, Box)
    else if Box.IsAbsolutelyPositioned then
      State.Items.Add(ikAbsolute, Box)
    else if Box.IsInlineLevel then
    begin
      if (State.Items.Count > 0) and (State.Items.Items[State.Items.Count - 1].Kind = ikText) then
        State.Items.Items[State.Items.Count - 1].CanBreakAfter := True;
      Item := State.Items.Add(ikAtomic, Box);
      Item^.CanBreakAfter := True;
      State.PreviousSpace := False;
      State.PreviousCodePoint := $FFFC;
    end
    else
    begin
      Include(Box.Flags, bfBlockInInline);
      State.Items.Add(ikBlock, Box);
      State.PreviousSpace := True;
      State.PreviousCodePoint := 0;
    end;
  end;
end;

procedure CollectInlineItems(Container: TLayoutBox; Items: TInlineItems);
var
  State: TCollectState;
  Child: TLayoutBox;
begin
  Items.Clear;
  State.Items := Items;
  State.PreviousSpace := True;
  State.PreviousCodePoint := 0;
  State.AtWordStart := True;
  State.Column := 0;
  Child := Container.FirstChild;
  while Child <> nil do
  begin
    AddBoxItems(State, Child);
    Child := Child.NextSibling;
  end;
  { Trailing collapsible spaces at the end of the content go. }
end;

end.
