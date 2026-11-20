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
  Value routines for the box: display, sizes, alignment, aspect-ratio,
  corner radii, border images, background layers, transforms, origins,
  containment names, clipping and filters.
}
unit Css.BoxParsers;

{$mode objfpc}
{$H+}

interface

uses
  Css.Tokens, Css.Values;

function ParseDisplay(var Cursor: TCssTokenCursor): TCssValue;
function ParseSize(var Cursor: TCssTokenCursor): TCssValue;
function ParseMaxSize(var Cursor: TCssTokenCursor): TCssValue;
function ParseFlexBasis(var Cursor: TCssTokenCursor): TCssValue;
function ParseContentAlignment(var Cursor: TCssTokenCursor): TCssValue;
function ParseItemsAlignment(var Cursor: TCssTokenCursor): TCssValue;
function ParseSelfAlignment(var Cursor: TCssTokenCursor): TCssValue;
function ParseJustifyItems(var Cursor: TCssTokenCursor): TCssValue;
function ParseAspectRatio(var Cursor: TCssTokenCursor): TCssValue;
function ParseRadiusCorner(var Cursor: TCssTokenCursor): TCssValue;
function ParseBorderSpacing(var Cursor: TCssTokenCursor): TCssValue;
function ParseBorderImageSlice(var Cursor: TCssTokenCursor): TCssValue;
function ParseBorderImageWidth(var Cursor: TCssTokenCursor): TCssValue;
function ParseBorderImageOutset(var Cursor: TCssTokenCursor): TCssValue;
function ParseBorderImageRepeat(var Cursor: TCssTokenCursor): TCssValue;
function ParseBackgroundPositionX(var Cursor: TCssTokenCursor): TCssValue;
function ParseBackgroundPositionY(var Cursor: TCssTokenCursor): TCssValue;
function ParseBackgroundSize(var Cursor: TCssTokenCursor): TCssValue;
function ParseBackgroundRepeat(var Cursor: TCssTokenCursor): TCssValue;
{ One layer's size / repeat (the background shorthand's pieces). }
function ParseOneBackgroundSize(var Cursor: TCssTokenCursor): TCssValue;
function ParseOneBackgroundRepeat(var Cursor: TCssTokenCursor): TCssValue;
function ParseTransformOrigin(var Cursor: TCssTokenCursor): TCssValue;
function ParsePositionValue(var Cursor: TCssTokenCursor): TCssValue;
function ParseTransformValue(var Cursor: TCssTokenCursor): TCssValue;
function ParseTranslateValue(var Cursor: TCssTokenCursor): TCssValue;
function ParseRotateValue(var Cursor: TCssTokenCursor): TCssValue;
function ParseScaleValue(var Cursor: TCssTokenCursor): TCssValue;
function ParseWillChange(var Cursor: TCssTokenCursor): TCssValue;
function ParseContainerName(var Cursor: TCssTokenCursor): TCssValue;
function ParseClip(var Cursor: TCssTokenCursor): TCssValue;
function ParseClipPath(var Cursor: TCssTokenCursor): TCssValue;
function ParseFilter(var Cursor: TCssTokenCursor): TCssValue;
function ParseScrollbarColor(var Cursor: TCssTokenCursor): TCssValue;

implementation

uses
  Css.Atoms, Css.Keywords, Css.Units, Css.ValueParser, Css.ColorParser, Css.Images, Css.Transforms;

{ ---- display ---- }

function ParseDisplay(var Cursor: TCssTokenCursor): TCssValue;
var
  Outer, Inner: TCssKeyword;
  ListItem: Boolean;
  Keyword: TCssKeyword;
  Count: Integer;
begin
  Result := nil;
  Keyword := PeekKeyword(Cursor);
  { The single keywords that are not part of the two-value syntax. }
  if KeywordIn(Keyword, [kwNone, kwContents, kwTableRowGroup, kwTableHeaderGroup, kwTableFooterGroup,
    kwTableRow, kwTableCell, kwTableColumnGroup, kwTableColumn, kwTableCaption, kwRubyBase, kwRubyText,
    kwRubyBaseContainer, kwRubyTextContainer, kwInlineBlock, kwInlineTable, kwInlineFlex, kwInlineGrid,
    kwWebkitBox, kwWebkitInlineBox]) then
    Exit(ParseKeyword(Cursor, []));
  Outer := kwInvalid;
  Inner := kwInvalid;
  ListItem := False;
  Count := 0;
  repeat
    Keyword := PeekKeyword(Cursor);
    if KeywordIn(Keyword, [kwBlock, kwInline, kwRunIn]) and (Outer = kwInvalid) then
      Outer := Keyword
    else if KeywordIn(Keyword, [kwFlow, kwFlowRoot, kwTable, kwFlex, kwGrid, kwRuby, kwMath]) and
      (Inner = kwInvalid) then
      Inner := Keyword
    else if (Keyword = kwListItem) and not ListItem then
      ListItem := True
    else
      Break;
    Cursor.NextNonWhitespace;
    Inc(Count);
  until False;
  if Count = 0 then
    Exit;
  if ListItem and not KeywordIn(Inner, [kwInvalid, kwFlow, kwFlowRoot]) then
    Exit;
  { The short forms, as CSSOM serializes them. }
  if ListItem then
  begin
    if KeywordIn(Outer, [kwInvalid, kwBlock]) and KeywordIn(Inner, [kwInvalid, kwFlow]) then
      Exit(NewKeyword(kwListItem));
    Result := NewList(lsSpace);
    if Outer = kwInline then
      Result.Add(NewKeyword(kwInline));
    if Inner = kwFlowRoot then
      Result.Add(NewKeyword(kwFlowRoot));
    Result.Add(NewKeyword(kwListItem));
    Exit;
  end;
  if Outer = kwInvalid then
  begin
    if KeywordIn(Inner, [kwRuby, kwMath]) then
      Outer := kwInline
    else
      Outer := kwBlock;
  end;
  if Inner = kwInvalid then
    Inner := kwFlow;
  case Outer of
    kwBlock:
      case Inner of
        kwFlow: Exit(NewKeyword(kwBlock));
        kwFlowRoot: Exit(NewKeyword(kwFlowRoot));
        kwTable: Exit(NewKeyword(kwTable));
        kwFlex: Exit(NewKeyword(kwFlex));
        kwGrid: Exit(NewKeyword(kwGrid));
      end;
    kwInline:
      case Inner of
        kwFlow: Exit(NewKeyword(kwInline));
        kwFlowRoot: Exit(NewKeyword(kwInlineBlock));
        kwTable: Exit(NewKeyword(kwInlineTable));
        kwFlex: Exit(NewKeyword(kwInlineFlex));
        kwGrid: Exit(NewKeyword(kwInlineGrid));
        kwRuby: Exit(NewKeyword(kwRuby));
        kwMath: Exit(NewKeyword(kwMath));
      end;
    kwRunIn:
      if Inner = kwFlow then
        Exit(NewKeyword(kwRunIn));
  end;
  Result := NewListOf(lsSpace, [NewKeyword(Outer), NewKeyword(Inner)]);
end;

{ ---- sizes ---- }

function ParseFitContentFunction(var Cursor: TCssTokenCursor): TCssValue;
var
  Saved: Integer;
  Token: PCssToken;
  Contents: TCssTokenCursor;
  Argument: TCssValue;
begin
  Result := nil;
  Saved := Cursor.Position;
  Cursor.SkipWhitespace;
  Token := Cursor.Peek;
  if (Token^.Kind = tkFunction) and AsciiSameText(Token^.Text, 'fit-content') then
  begin
    Cursor.Next;
    Contents := Cursor.Contents(Token);
    Argument := ParseLengthPercentage(Contents, True);
    if (Argument <> nil) and Contents.AtEndIgnoringWhitespace then
    begin
      Result := NewFunction('fit-content');
      Result.Add(Argument);
      Exit;
    end;
    ReleaseValue(Argument);
  end;
  Cursor.Position := Saved;
end;

function ParseSizeKeywordsOr(var Cursor: TCssTokenCursor; First: TCssKeyword): TCssValue;
begin
  Result := ParseKeyword(Cursor, [First, kwMinContent, kwMaxContent, kwFitContent, kwStretch]);
  if Result <> nil then
    Exit;
  { The prefixed spellings of stretch. }
  if Cursor.IsIdent('-webkit-fill-available') or Cursor.IsIdent('-moz-available') then
  begin
    Cursor.NextNonWhitespace;
    Exit(NewKeyword(kwStretch));
  end;
  Result := ParseLengthPercentage(Cursor, True);
  if Result = nil then
    Result := ParseFitContentFunction(Cursor);
end;

function ParseSize(var Cursor: TCssTokenCursor): TCssValue;
begin
  Cursor.SkipWhitespace;
  Result := ParseSizeKeywordsOr(Cursor, kwAuto);
end;

function ParseMaxSize(var Cursor: TCssTokenCursor): TCssValue;
begin
  Cursor.SkipWhitespace;
  Result := ParseSizeKeywordsOr(Cursor, kwNone);
end;

function ParseFlexBasis(var Cursor: TCssTokenCursor): TCssValue;
begin
  Result := ParseKeyword(Cursor, [kwContent]);
  if Result = nil then
    Result := ParseSize(Cursor);
end;

{ ---- alignment (CSS Box Alignment Level 3) ---- }

function ParseBaselinePosition(var Cursor: TCssTokenCursor): TCssValue;
var
  Saved: Integer;
  Keyword: TCssKeyword;
begin
  Saved := Cursor.Position;
  Keyword := PeekKeyword(Cursor);
  if Keyword = kwBaseline then
    Exit(ParseKeyword(Cursor, []));
  if (Keyword = kwFirst) or (Keyword = kwLast) then
  begin
    Cursor.NextNonWhitespace;
    if PeekKeyword(Cursor) = kwBaseline then
    begin
      Cursor.NextNonWhitespace;
      if Keyword = kwFirst then
        Exit(NewKeyword(kwBaseline));
      Exit(NewListOf(lsSpace, [NewKeyword(kwLast), NewKeyword(kwBaseline)]));
    end;
  end;
  Cursor.Position := Saved;
  Result := nil;
end;

{ <overflow-position>? <position> from Positions. }
function ParsePositionWithOverflow(var Cursor: TCssTokenCursor; const Positions: array of TCssKeyword): TCssValue;
var
  Saved: Integer;
  Overflow, Position: TCssValue;
begin
  Result := nil;
  Saved := Cursor.Position;
  Overflow := ParseKeyword(Cursor, [kwSafe, kwUnsafe]);
  Position := ParseKeyword(Cursor, Positions);
  if Position = nil then
  begin
    ReleaseValue(Overflow);
    Cursor.Position := Saved;
    Exit;
  end;
  if Overflow = nil then
    Exit(Position);
  Result := NewListOf(lsSpace, [Overflow, Position]);
end;

function ParseContentAlignment(var Cursor: TCssTokenCursor): TCssValue;
begin
  Result := ParseKeyword(Cursor, [kwNormal, kwSpaceBetween, kwSpaceAround, kwSpaceEvenly, kwStretch]);
  if Result = nil then
    Result := ParseBaselinePosition(Cursor);
  if Result = nil then
    Result := ParsePositionWithOverflow(Cursor, [kwCenter, kwStart, kwEnd, kwFlexStart, kwFlexEnd,
      kwLeft, kwRight]);
end;

function ParseItemsAlignment(var Cursor: TCssTokenCursor): TCssValue;
begin
  Result := ParseKeyword(Cursor, [kwNormal, kwStretch, kwAnchorCenter]);
  if Result = nil then
    Result := ParseBaselinePosition(Cursor);
  if Result = nil then
    Result := ParsePositionWithOverflow(Cursor, [kwCenter, kwStart, kwEnd, kwSelfStart, kwSelfEnd,
      kwFlexStart, kwFlexEnd, kwLeft, kwRight]);
end;

function ParseSelfAlignment(var Cursor: TCssTokenCursor): TCssValue;
begin
  Result := ParseKeyword(Cursor, [kwAuto]);
  if Result = nil then
    Result := ParseItemsAlignment(Cursor);
end;

function ParseJustifyItems(var Cursor: TCssTokenCursor): TCssValue;
var
  Saved: Integer;
  First, Second: TCssValue;
begin
  Saved := Cursor.Position;
  First := ParseKeyword(Cursor, [kwLegacy]);
  if First <> nil then
  begin
    Second := ParseKeyword(Cursor, [kwLeft, kwRight, kwCenter]);
    if Second = nil then
      Exit(First);
    Exit(NewListOf(lsSpace, [First, Second]));
  end;
  First := ParseKeyword(Cursor, [kwLeft, kwRight, kwCenter]);
  if First <> nil then
  begin
    Second := ParseKeyword(Cursor, [kwLegacy]);
    if Second <> nil then
      Exit(NewListOf(lsSpace, [Second, First]));
    First.Release;
    Cursor.Position := Saved;
  end;
  Result := ParseItemsAlignment(Cursor);
end;

{ ---- aspect-ratio, radii, border images ---- }

function ParseRatio(var Cursor: TCssTokenCursor): TCssValue;
var
  First, Second: TCssValue;
begin
  Result := nil;
  First := ParseNumber(Cursor, True);
  if First = nil then
    Exit;
  if SkipDelim(Cursor, '/') then
  begin
    Second := ParseNumber(Cursor, True);
    if Second = nil then
    begin
      First.Release;
      Exit;
    end;
  end
  else
    Second := NewNumber(1);
  Result := NewListOf(lsSlash, [First, Second]);
end;

function ParseAspectRatio(var Cursor: TCssTokenCursor): TCssValue;
var
  Auto, Ratio: TCssValue;
begin
  Auto := ParseKeyword(Cursor, [kwAuto]);
  Ratio := ParseRatio(Cursor);
  if (Auto = nil) and (Ratio <> nil) then
    Auto := ParseKeyword(Cursor, [kwAuto]);
  if Ratio = nil then
    Exit(Auto);
  if Auto = nil then
    Exit(Ratio);
  Result := NewListOf(lsSpace, [Auto, Ratio]);
end;

function ParseRadiusCorner(var Cursor: TCssTokenCursor): TCssValue;
var
  First, Second: TCssValue;
begin
  Result := nil;
  First := ParseLengthPercentage(Cursor, True);
  if First = nil then
    Exit;
  Second := ParseLengthPercentage(Cursor, True);
  if Second = nil then
    Exit(First);
  Result := NewListOf(lsSpace, [First, Second]);
end;

function ParseBorderSpacing(var Cursor: TCssTokenCursor): TCssValue;
var
  First, Second: TCssValue;
begin
  Result := nil;
  First := ParseLength(Cursor, True);
  if First = nil then
    Exit;
  Second := ParseLength(Cursor, True);
  if Second = nil then
    Exit(First);
  Result := NewListOf(lsSpace, [First, Second]);
end;

function ParseNumberOrPercentage(var Cursor: TCssTokenCursor): TCssValue;
begin
  Result := ParseNumber(Cursor, True);
  if Result = nil then
    Result := ParsePercentage(Cursor, True);
end;

function ParseBorderImageSlice(var Cursor: TCssTokenCursor): TCssValue;
var
  Fill, Item: TCssValue;
begin
  Result := NewList(lsSpace);
  Fill := ParseKeyword(Cursor, [kwFill]);
  while Result.Count < 4 do
  begin
    Item := ParseNumberOrPercentage(Cursor);
    if Item = nil then
      Break;
    Result.Add(Item);
  end;
  if Result.Count = 0 then
  begin
    ReleaseValue(Fill);
    ReleaseValue(Result);
    Exit;
  end;
  if Fill = nil then
    Fill := ParseKeyword(Cursor, [kwFill]);
  if Fill <> nil then
    Result.Add(Fill);
end;

function ParseBorderImageWidthItem(var Cursor: TCssTokenCursor): TCssValue;
begin
  Result := ParseKeyword(Cursor, [kwAuto]);
  if Result = nil then
    Result := ParseNumber(Cursor, True);
  if Result = nil then
    Result := ParseLengthPercentage(Cursor, True);
end;

function ParseBorderImageWidth(var Cursor: TCssTokenCursor): TCssValue;
var
  Item: TCssValue;
begin
  Result := NewList(lsSpace);
  while Result.Count < 4 do
  begin
    Item := ParseBorderImageWidthItem(Cursor);
    if Item = nil then
      Break;
    Result.Add(Item);
  end;
  if Result.Count = 0 then
    ReleaseValue(Result);
end;

function ParseBorderImageOutset(var Cursor: TCssTokenCursor): TCssValue;
var
  Item: TCssValue;
begin
  Result := NewList(lsSpace);
  while Result.Count < 4 do
  begin
    Item := ParseNumber(Cursor, True);
    if Item = nil then
      Item := ParseLength(Cursor, True);
    if Item = nil then
      Break;
    Result.Add(Item);
  end;
  if Result.Count = 0 then
    ReleaseValue(Result);
end;

function ParseBorderImageRepeat(var Cursor: TCssTokenCursor): TCssValue;
var
  Item: TCssValue;
begin
  Result := NewList(lsSpace);
  while Result.Count < 2 do
  begin
    Item := ParseKeyword(Cursor, [kwStretch, kwRepeat, kwRound, kwSpace]);
    if Item = nil then
      Break;
    Result.Add(Item);
  end;
  if Result.Count = 0 then
    ReleaseValue(Result);
end;

{ ---- backgrounds ---- }

type
  TLayerRoutine = function(var Cursor: TCssTokenCursor): TCssValue;

function ParseLayers(var Cursor: TCssTokenCursor; Routine: TLayerRoutine): TCssValue;
var
  Item: TCssValue;
begin
  Result := NewList(lsComma);
  repeat
    Item := Routine(Cursor);
    if Item = nil then
    begin
      ReleaseValue(Result);
      Exit;
    end;
    Result.Add(Item);
  until not SkipComma(Cursor);
end;

function ParseOnePositionCoordinate(var Cursor: TCssTokenCursor; Low, High: TCssKeyword): TCssValue;
var
  Edge, Offset: TCssValue;
begin
  Result := ParseKeyword(Cursor, [kwCenter]);
  if Result <> nil then
    Exit;
  Edge := ParseKeyword(Cursor, [Low, High]);
  Offset := ParseLengthPercentage(Cursor);
  if Edge = nil then
    Exit(Offset);
  if Offset = nil then
    Exit(Edge);
  Result := NewListOf(lsSpace, [Edge, Offset]);
end;

function ParseOnePositionX(var Cursor: TCssTokenCursor): TCssValue;
begin
  Result := ParseOnePositionCoordinate(Cursor, kwLeft, kwRight);
end;

function ParseOnePositionY(var Cursor: TCssTokenCursor): TCssValue;
begin
  Result := ParseOnePositionCoordinate(Cursor, kwTop, kwBottom);
end;

function ParseBackgroundPositionX(var Cursor: TCssTokenCursor): TCssValue;
begin
  Result := ParseLayers(Cursor, @ParseOnePositionX);
end;

function ParseBackgroundPositionY(var Cursor: TCssTokenCursor): TCssValue;
begin
  Result := ParseLayers(Cursor, @ParseOnePositionY);
end;

function ParseOneBackgroundSize(var Cursor: TCssTokenCursor): TCssValue;
var
  First, Second: TCssValue;
begin
  Result := ParseKeyword(Cursor, [kwCover, kwContain]);
  if Result <> nil then
    Exit;
  First := ParseKeyword(Cursor, [kwAuto]);
  if First = nil then
    First := ParseLengthPercentage(Cursor, True);
  if First = nil then
    Exit;
  Second := ParseKeyword(Cursor, [kwAuto]);
  if Second = nil then
    Second := ParseLengthPercentage(Cursor, True);
  if Second = nil then
    Exit(First);
  Result := NewListOf(lsSpace, [First, Second]);
end;

function ParseBackgroundSize(var Cursor: TCssTokenCursor): TCssValue;
begin
  Result := ParseLayers(Cursor, @ParseOneBackgroundSize);
end;

function ParseOneBackgroundRepeat(var Cursor: TCssTokenCursor): TCssValue;
var
  First, Second: TCssValue;
begin
  Result := ParseKeyword(Cursor, [kwRepeatX, kwRepeatY]);
  if Result <> nil then
    Exit;
  First := ParseKeyword(Cursor, [kwRepeat, kwSpace, kwRound, kwNoRepeat]);
  if First = nil then
    Exit;
  Second := ParseKeyword(Cursor, [kwRepeat, kwSpace, kwRound, kwNoRepeat]);
  if Second = nil then
    Exit(First);
  Result := NewListOf(lsSpace, [First, Second]);
end;

function ParseBackgroundRepeat(var Cursor: TCssTokenCursor): TCssValue;
begin
  Result := ParseLayers(Cursor, @ParseOneBackgroundRepeat);
end;

{ ---- transforms and origins ---- }

function ParseTransformOrigin(var Cursor: TCssTokenCursor): TCssValue;
var
  First, Second, Third, Swap: TCssValue;
  Keyword: TCssKeyword;

  function Part: TCssValue;
  begin
    Result := ParseKeyword(Cursor, [kwLeft, kwRight, kwTop, kwBottom, kwCenter]);
    if Result = nil then
      Result := ParseLengthPercentage(Cursor);
  end;

  function KeywordOf(Value: TCssValue): TCssKeyword;
  begin
    if (Value <> nil) and (Value.Kind = vkKeyword) then
      Result := Value.Keyword
    else
      Result := kwInvalid;
  end;

begin
  Result := nil;
  First := Part;
  if First = nil then
    Exit;
  Second := Part;
  if Second = nil then
  begin
    Keyword := KeywordOf(First);
    if (Keyword = kwTop) or (Keyword = kwBottom) then
      Exit(NewListOf(lsSpace, [NewKeyword(kwCenter), First]));
    Exit(NewListOf(lsSpace, [First, NewKeyword(kwCenter)]));
  end;
  { The vertical keyword goes second. }
  if KeywordIn(KeywordOf(First), [kwTop, kwBottom]) or KeywordIn(KeywordOf(Second), [kwLeft, kwRight]) then
  begin
    Swap := First;
    First := Second;
    Second := Swap;
  end;
  if KeywordIn(KeywordOf(First), [kwTop, kwBottom]) or KeywordIn(KeywordOf(Second), [kwLeft, kwRight]) then
  begin
    First.Release;
    Second.Release;
    Exit;
  end;
  Result := NewListOf(lsSpace, [First, Second]);
  Third := ParseLength(Cursor);
  if Third <> nil then
    Result.Add(Third);
end;

function ParsePositionValue(var Cursor: TCssTokenCursor): TCssValue;
begin
  Result := ParsePosition(Cursor);
end;

function ParseTransformValue(var Cursor: TCssTokenCursor): TCssValue;
begin
  Result := ParseTransformList(Cursor);
end;

function ParseTranslateValue(var Cursor: TCssTokenCursor): TCssValue;
begin
  Result := ParseTranslateProperty(Cursor);
end;

function ParseRotateValue(var Cursor: TCssTokenCursor): TCssValue;
begin
  Result := ParseRotateProperty(Cursor);
end;

function ParseScaleValue(var Cursor: TCssTokenCursor): TCssValue;
begin
  Result := ParseScaleProperty(Cursor);
end;

{ ---- containment, will-change ---- }

function ParseWillChange(var Cursor: TCssTokenCursor): TCssValue;
var
  Item: TCssValue;
begin
  Result := ParseKeyword(Cursor, [kwAuto]);
  if Result <> nil then
    Exit;
  Result := NewList(lsComma);
  repeat
    Item := ParseKeyword(Cursor, [kwScrollPosition, kwContents]);
    if Item = nil then
      Item := ParseCustomIdent(Cursor, [kwNone, kwAll, kwAuto]);
    if Item = nil then
    begin
      ReleaseValue(Result);
      Exit;
    end;
    Result.Add(Item);
  until not SkipComma(Cursor);
end;

function ParseContainerName(var Cursor: TCssTokenCursor): TCssValue;
var
  Item: TCssValue;
begin
  Result := ParseKeyword(Cursor, [kwNone]);
  if Result <> nil then
    Exit;
  Result := NewList(lsSpace);
  repeat
    Item := ParseCustomIdent(Cursor, [kwAnd, kwOr, kwNot, kwNone]);
    if Item = nil then
      Break;
    Result.Add(Item);
  until False;
  if Result.Count = 0 then
    ReleaseValue(Result);
end;

{ ---- clipping and filters ---- }

{ A function value named one of Names, its arguments taken generically. }
function ParseNamedFunction(var Cursor: TCssTokenCursor; const Names: array of string): TCssValue;
var
  Saved, Index: Integer;
  Token: PCssToken;
  Lower: string;
  Single: TCssTokenCursor;
begin
  Result := nil;
  Saved := Cursor.Position;
  Cursor.SkipWhitespace;
  Token := Cursor.Peek;
  if Token^.Kind <> tkFunction then
    Exit;
  Lower := AsciiLowercase(Token^.Text);
  for Index := 0 to High(Names) do
    if Names[Index] = Lower then
    begin
      Cursor.Next;
      Single := TCssTokenCursor.CreateRange(Cursor.Tokens, Saved, Cursor.Position);
      Result := ParseGenericValue(Single);
      if (Result <> nil) and (Result.Kind = vkFunction) then
        Exit;
      ReleaseValue(Result);
      Break;
    end;
  Cursor.Position := Saved;
end;

function ParseClip(var Cursor: TCssTokenCursor): TCssValue;
begin
  Result := ParseKeyword(Cursor, [kwAuto]);
  if Result = nil then
    Result := ParseNamedFunction(Cursor, ['rect']);
end;

function ParseClipPath(var Cursor: TCssTokenCursor): TCssValue;
var
  Shape, Box: TCssValue;
begin
  Result := ParseKeyword(Cursor, [kwNone]);
  if Result <> nil then
    Exit;
  Result := ParseUrlValue(Cursor);
  if Result <> nil then
    Exit;
  Shape := ParseNamedFunction(Cursor, ['inset', 'circle', 'ellipse', 'polygon', 'path', 'rect', 'xywh', 'shape']);
  Box := ParseKeyword(Cursor, [kwBorderBox, kwPaddingBox, kwContentBox, kwMarginBox, kwFillBox, kwStrokeBox,
    kwViewBox]);
  if (Shape = nil) and (Box <> nil) then
    Shape := ParseNamedFunction(Cursor, ['inset', 'circle', 'ellipse', 'polygon', 'path', 'rect', 'xywh', 'shape']);
  if Shape = nil then
    Exit(Box);
  if Box = nil then
    Exit(Shape);
  Result := NewListOf(lsSpace, [Shape, Box]);
end;

function ParseFilter(var Cursor: TCssTokenCursor): TCssValue;
var
  Item: TCssValue;
begin
  Result := ParseKeyword(Cursor, [kwNone]);
  if Result <> nil then
    Exit;
  Result := NewList(lsSpace);
  repeat
    Item := ParseUrlValue(Cursor);
    if Item = nil then
      Item := ParseNamedFunction(Cursor, ['blur', 'brightness', 'contrast', 'drop-shadow', 'grayscale',
        'hue-rotate', 'invert', 'opacity', 'saturate', 'sepia']);
    if Item = nil then
      Break;
    Result.Add(Item);
  until False;
  if Result.Count = 0 then
    ReleaseValue(Result);
end;

function ParseScrollbarColor(var Cursor: TCssTokenCursor): TCssValue;
var
  Thumb, Track: TCssValue;
begin
  Result := ParseKeyword(Cursor, [kwAuto]);
  if Result <> nil then
    Exit;
  Thumb := ParseColor(Cursor);
  if Thumb = nil then
    Exit;
  Track := ParseColor(Cursor);
  if Track = nil then
  begin
    Thumb.Release;
    Exit;
  end;
  Result := NewListOf(lsSpace, [Thumb, Track]);
end;

end.
