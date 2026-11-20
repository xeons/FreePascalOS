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
  Shorthand properties: which longhands each one sets, and expanding a
  shorthand's value into values for all of them. A longhand the value
  leaves out gets its initial value, as the specs require.
}
unit Css.Shorthands;

{$mode objfpc}
{$H+}

interface

uses
  Css.Tokens, Css.Values, Css.PropertyIds;

{ The longhands Id sets, in the canonical order. }
function ShorthandLonghands(Id: TCssPropertyId): TCssPropertyIdArray;
{ Parses a shorthand's value (Cursor's whole range); Values gets one
  new value per longhand of ShorthandLonghands(Id). False when invalid. }
function ExpandShorthand(Id: TCssPropertyId; Cursor: TCssTokenCursor; out Values: TCssValueArray): Boolean;

implementation

uses
  Css.Atoms, Css.Keywords, Css.Units, Css.Colors, Css.Grammar, Css.ValueParser, Css.ColorParser, Css.Images,
  Css.InitialValues, Css.BoxParsers, Css.GridParsers, Css.TextParsers;

function Ids(const List: array of TCssPropertyId): TCssPropertyIdArray;
var
  Index: Integer;
begin
  Result := nil;
  SetLength(Result, Length(List));
  for Index := 0 to High(List) do
    Result[Index] := List[Index];
end;

function ShorthandLonghands(Id: TCssPropertyId): TCssPropertyIdArray;
begin
  case Id of
    cpMargin: Result := Ids([cpMarginTop, cpMarginRight, cpMarginBottom, cpMarginLeft]);
    cpPadding: Result := Ids([cpPaddingTop, cpPaddingRight, cpPaddingBottom, cpPaddingLeft]);
    cpInset: Result := Ids([cpTop, cpRight, cpBottom, cpLeft]);
    cpBorderWidth: Result := Ids([cpBorderTopWidth, cpBorderRightWidth, cpBorderBottomWidth, cpBorderLeftWidth]);
    cpBorderStyle: Result := Ids([cpBorderTopStyle, cpBorderRightStyle, cpBorderBottomStyle, cpBorderLeftStyle]);
    cpBorderColor: Result := Ids([cpBorderTopColor, cpBorderRightColor, cpBorderBottomColor, cpBorderLeftColor]);
    cpBorderTop: Result := Ids([cpBorderTopWidth, cpBorderTopStyle, cpBorderTopColor]);
    cpBorderRight: Result := Ids([cpBorderRightWidth, cpBorderRightStyle, cpBorderRightColor]);
    cpBorderBottom: Result := Ids([cpBorderBottomWidth, cpBorderBottomStyle, cpBorderBottomColor]);
    cpBorderLeft: Result := Ids([cpBorderLeftWidth, cpBorderLeftStyle, cpBorderLeftColor]);
    cpBorder: Result := Ids([cpBorderTopWidth, cpBorderRightWidth, cpBorderBottomWidth, cpBorderLeftWidth,
      cpBorderTopStyle, cpBorderRightStyle, cpBorderBottomStyle, cpBorderLeftStyle, cpBorderTopColor,
      cpBorderRightColor, cpBorderBottomColor, cpBorderLeftColor, cpBorderImageSource, cpBorderImageSlice,
      cpBorderImageWidth, cpBorderImageOutset, cpBorderImageRepeat]);
    cpBorderRadius: Result := Ids([cpBorderTopLeftRadius, cpBorderTopRightRadius, cpBorderBottomRightRadius,
      cpBorderBottomLeftRadius]);
    cpBorderImage: Result := Ids([cpBorderImageSource, cpBorderImageSlice, cpBorderImageWidth,
      cpBorderImageOutset, cpBorderImageRepeat]);
    cpBorderBlock: Result := Ids([cpBorderBlockStartWidth, cpBorderBlockEndWidth, cpBorderBlockStartStyle,
      cpBorderBlockEndStyle, cpBorderBlockStartColor, cpBorderBlockEndColor]);
    cpBorderInline: Result := Ids([cpBorderInlineStartWidth, cpBorderInlineEndWidth, cpBorderInlineStartStyle,
      cpBorderInlineEndStyle, cpBorderInlineStartColor, cpBorderInlineEndColor]);
    cpBorderBlockStart: Result := Ids([cpBorderBlockStartWidth, cpBorderBlockStartStyle, cpBorderBlockStartColor]);
    cpBorderBlockEnd: Result := Ids([cpBorderBlockEndWidth, cpBorderBlockEndStyle, cpBorderBlockEndColor]);
    cpBorderInlineStart: Result := Ids([cpBorderInlineStartWidth, cpBorderInlineStartStyle,
      cpBorderInlineStartColor]);
    cpBorderInlineEnd: Result := Ids([cpBorderInlineEndWidth, cpBorderInlineEndStyle, cpBorderInlineEndColor]);
    cpBorderBlockWidth: Result := Ids([cpBorderBlockStartWidth, cpBorderBlockEndWidth]);
    cpBorderBlockStyle: Result := Ids([cpBorderBlockStartStyle, cpBorderBlockEndStyle]);
    cpBorderBlockColor: Result := Ids([cpBorderBlockStartColor, cpBorderBlockEndColor]);
    cpBorderInlineWidth: Result := Ids([cpBorderInlineStartWidth, cpBorderInlineEndWidth]);
    cpBorderInlineStyle: Result := Ids([cpBorderInlineStartStyle, cpBorderInlineEndStyle]);
    cpBorderInlineColor: Result := Ids([cpBorderInlineStartColor, cpBorderInlineEndColor]);
    cpMarginBlock: Result := Ids([cpMarginBlockStart, cpMarginBlockEnd]);
    cpMarginInline: Result := Ids([cpMarginInlineStart, cpMarginInlineEnd]);
    cpPaddingBlock: Result := Ids([cpPaddingBlockStart, cpPaddingBlockEnd]);
    cpPaddingInline: Result := Ids([cpPaddingInlineStart, cpPaddingInlineEnd]);
    cpInsetBlock: Result := Ids([cpInsetBlockStart, cpInsetBlockEnd]);
    cpInsetInline: Result := Ids([cpInsetInlineStart, cpInsetInlineEnd]);
    cpOutline: Result := Ids([cpOutlineWidth, cpOutlineStyle, cpOutlineColor]);
    cpBackground: Result := Ids([cpBackgroundColor, cpBackgroundImage, cpBackgroundPositionX,
      cpBackgroundPositionY, cpBackgroundSize, cpBackgroundRepeat, cpBackgroundAttachment, cpBackgroundOrigin,
      cpBackgroundClip]);
    cpBackgroundPosition: Result := Ids([cpBackgroundPositionX, cpBackgroundPositionY]);
    cpFont: Result := Ids([cpFontStyle, cpFontVariantCaps, cpFontWeight, cpFontStretch, cpFontSize, cpLineHeight,
      cpFontFamily, cpFontVariantLigatures, cpFontVariantNumeric, cpFontVariantEastAsian, cpFontVariantPosition,
      cpFontKerning, cpFontOpticalSizing, cpFontFeatureSettings, cpFontVariationSettings, cpFontSizeAdjust]);
    cpFontVariant: Result := Ids([cpFontVariantCaps, cpFontVariantLigatures, cpFontVariantNumeric,
      cpFontVariantEastAsian, cpFontVariantPosition]);
    cpFlex: Result := Ids([cpFlexGrow, cpFlexShrink, cpFlexBasis]);
    cpFlexFlow: Result := Ids([cpFlexDirection, cpFlexWrap]);
    cpGrid: Result := Ids([cpGridTemplateRows, cpGridTemplateColumns, cpGridTemplateAreas, cpGridAutoRows,
      cpGridAutoColumns, cpGridAutoFlow]);
    cpGridTemplate: Result := Ids([cpGridTemplateRows, cpGridTemplateColumns, cpGridTemplateAreas]);
    cpGridRow: Result := Ids([cpGridRowStart, cpGridRowEnd]);
    cpGridColumn: Result := Ids([cpGridColumnStart, cpGridColumnEnd]);
    cpGridArea: Result := Ids([cpGridRowStart, cpGridColumnStart, cpGridRowEnd, cpGridColumnEnd]);
    cpGap: Result := Ids([cpRowGap, cpColumnGap]);
    cpPlaceContent: Result := Ids([cpAlignContent, cpJustifyContent]);
    cpPlaceItems: Result := Ids([cpAlignItems, cpJustifyItems]);
    cpPlaceSelf: Result := Ids([cpAlignSelf, cpJustifySelf]);
    cpOverflow: Result := Ids([cpOverflowX, cpOverflowY]);
    cpListStyle: Result := Ids([cpListStylePosition, cpListStyleImage, cpListStyleType]);
    cpTextDecoration: Result := Ids([cpTextDecorationLine, cpTextDecorationStyle, cpTextDecorationColor,
      cpTextDecorationThickness]);
    cpTransition: Result := Ids([cpTransitionProperty, cpTransitionDuration, cpTransitionTimingFunction,
      cpTransitionDelay, cpTransitionBehavior]);
    cpAnimation: Result := Ids([cpAnimationName, cpAnimationDuration, cpAnimationTimingFunction,
      cpAnimationDelay, cpAnimationIterationCount, cpAnimationDirection, cpAnimationFillMode,
      cpAnimationPlayState, cpAnimationComposition]);
    cpColumns: Result := Ids([cpColumnWidth, cpColumnCount]);
    cpColumnRule: Result := Ids([cpColumnRuleWidth, cpColumnRuleStyle, cpColumnRuleColor]);
    cpContainer: Result := Ids([cpContainerName, cpContainerType]);
  else
    Result := nil;
  end;
end;

{ ---- helpers ---- }

type
  TExpansion = record
    Longhands: TCssPropertyIdArray;
    Values: TCssValueArray;
  end;

procedure Put(var Expansion: TExpansion; Id: TCssPropertyId; Value: TCssValue);
var
  Index: Integer;
begin
  for Index := 0 to High(Expansion.Longhands) do
    if Expansion.Longhands[Index] = Id then
    begin
      ReleaseValue(Expansion.Values[Index]);
      Expansion.Values[Index] := Value;
      Exit;
    end;
  Value.Release;
end;

{ Shares one value among several longhands. }
procedure PutShared(var Expansion: TExpansion; const Targets: array of TCssPropertyId; Value: TCssValue);
var
  Index: Integer;
begin
  for Index := 0 to High(Targets) do
    Put(Expansion, Targets[Index], Value.AddRef);
  Value.Release;
end;

procedure ReleaseExpansion(var Expansion: TExpansion);
var
  Index: Integer;
begin
  for Index := 0 to High(Expansion.Values) do
    ReleaseValue(Expansion.Values[Index]);
end;

{ Values for the longhands in Parts in any order, each at most once
  (the longhand grammars decide). Values[I] is nil for parts left out. }
function ParseAnyOrder(var Cursor: TCssTokenCursor; const Parts: array of TCssPropertyId;
  var Values: array of TCssValue): Integer;
var
  Index: Integer;
  Progress: Boolean;
  Value: TCssValue;
begin
  Result := 0;
  for Index := 0 to High(Values) do
    Values[Index] := nil;
  repeat
    Progress := False;
    if Cursor.AtEndIgnoringWhitespace then
      Break;
    for Index := 0 to High(Parts) do
      if Values[Index] = nil then
      begin
        Value := ParseLonghandPart(Parts[Index], Cursor);
        if Value <> nil then
        begin
          Values[Index] := Value;
          Inc(Result);
          Progress := True;
          Break;
        end;
      end;
  until not Progress;
end;

{ One to Maximum values of Grammar's longhand, as for the box sides. }
function ParseRepeatedValues(var Cursor: TCssTokenCursor; Grammar: TCssPropertyId; Maximum: Integer;
  var Values: array of TCssValue): Integer;
var
  Value: TCssValue;
begin
  Result := 0;
  while Result < Maximum do
  begin
    Value := ParseLonghandPart(Grammar, Cursor);
    if Value = nil then
      Break;
    Values[Result] := Value;
    Inc(Result);
  end;
end;

{ ---- the box sides ---- }

function ExpandSides(var Expansion: TExpansion; var Cursor: TCssTokenCursor): Boolean;
var
  Values: array[0..3] of TCssValue;
  Count, Index: Integer;
begin
  Count := ParseRepeatedValues(Cursor, Expansion.Longhands[0], 4, Values);
  Result := Count > 0;
  if not Result then
    Exit;
  case Count of
    1:
      begin
        Values[1] := Values[0].AddRef;
        Values[2] := Values[0].AddRef;
        Values[3] := Values[0].AddRef;
      end;
    2:
      begin
        Values[2] := Values[0].AddRef;
        Values[3] := Values[1].AddRef;
      end;
    3: Values[3] := Values[1].AddRef;
  end;
  for Index := 0 to 3 do
    Put(Expansion, Expansion.Longhands[Index], Values[Index]);
end;

function ExpandPair(var Expansion: TExpansion; var Cursor: TCssTokenCursor): Boolean;
var
  Values: array[0..1] of TCssValue;
  Count: Integer;
begin
  Count := ParseRepeatedValues(Cursor, Expansion.Longhands[0], 2, Values);
  Result := Count > 0;
  if not Result then
    Exit;
  if Count = 1 then
    Values[1] := Values[0].AddRef;
  Put(Expansion, Expansion.Longhands[0], Values[0]);
  Put(Expansion, Expansion.Longhands[1], Values[1]);
end;

{ width || style || color, for the sides listed. }
function ExpandBorderSides(var Expansion: TExpansion; var Cursor: TCssTokenCursor;
  const Widths, Styles, Colors: array of TCssPropertyId): Boolean;
var
  Values: array[0..2] of TCssValue;
begin
  Result := ParseAnyOrder(Cursor, [cpBorderTopWidth, cpBorderTopStyle, cpBorderTopColor], Values) > 0;
  if not Result then
    Exit;
  if Values[0] <> nil then PutShared(Expansion, Widths, Values[0]);
  if Values[1] <> nil then PutShared(Expansion, Styles, Values[1]);
  if Values[2] <> nil then PutShared(Expansion, Colors, Values[2]);
end;

function ExpandBorderRadius(var Expansion: TExpansion; var Cursor: TCssTokenCursor): Boolean;
var
  Horizontal, Vertical: array[0..3] of TCssValue;
  HorizontalCount, VerticalCount, Index: Integer;

  procedure Complete(var Values: array of TCssValue; Count: Integer);
  begin
    case Count of
      1:
        begin
          Values[1] := Values[0].AddRef;
          Values[2] := Values[0].AddRef;
          Values[3] := Values[0].AddRef;
        end;
      2:
        begin
          Values[2] := Values[0].AddRef;
          Values[3] := Values[1].AddRef;
        end;
      3: Values[3] := Values[1].AddRef;
    end;
  end;

  function Next: TCssValue;
  begin
    Result := ParseLengthPercentage(Cursor, True);
  end;

begin
  Result := False;
  HorizontalCount := 0;
  while HorizontalCount < 4 do
  begin
    Horizontal[HorizontalCount] := Next;
    if Horizontal[HorizontalCount] = nil then
      Break;
    Inc(HorizontalCount);
  end;
  if HorizontalCount = 0 then
    Exit;
  Complete(Horizontal, HorizontalCount);
  VerticalCount := 0;
  if SkipDelim(Cursor, '/') then
  begin
    while VerticalCount < 4 do
    begin
      Vertical[VerticalCount] := Next;
      if Vertical[VerticalCount] = nil then
        Break;
      Inc(VerticalCount);
    end;
    if VerticalCount = 0 then
    begin
      for Index := 0 to 3 do
        Horizontal[Index].Release;
      Exit;
    end;
    Complete(Vertical, VerticalCount);
  end;
  for Index := 0 to 3 do
    if VerticalCount = 0 then
      Put(Expansion, Expansion.Longhands[Index], Horizontal[Index])
    else
      Put(Expansion, Expansion.Longhands[Index], NewListOf(lsSpace, [Horizontal[Index], Vertical[Index]]));
  Result := True;
end;

function ExpandBorderImage(var Expansion: TExpansion; var Cursor: TCssTokenCursor): Boolean;
var
  Source, Slice, Width, Outset, RepeatValue: TCssValue;
  Progress: Boolean;
begin
  Source := nil;
  Slice := nil;
  Width := nil;
  Outset := nil;
  RepeatValue := nil;
  repeat
    Progress := False;
    if Source = nil then
    begin
      Source := ParseKeyword(Cursor, [kwNone]);
      if Source = nil then
        Source := ParseImage(Cursor);
      Progress := Source <> nil;
    end;
    if not Progress and (Slice = nil) then
    begin
      Slice := ParseBorderImageSlice(Cursor);
      if Slice <> nil then
      begin
        Progress := True;
        if SkipDelim(Cursor, '/') then
        begin
          Width := ParseBorderImageWidth(Cursor);
          if SkipDelim(Cursor, '/') then
          begin
            Outset := ParseBorderImageOutset(Cursor);
            if Outset = nil then
              Break;
          end
          else if Width = nil then
            Break;
        end;
      end;
    end;
    if not Progress and (RepeatValue = nil) then
    begin
      RepeatValue := ParseBorderImageRepeat(Cursor);
      Progress := RepeatValue <> nil;
    end;
  until not Progress;
  Result := (Source <> nil) or (Slice <> nil) or (RepeatValue <> nil);
  if Source <> nil then Put(Expansion, cpBorderImageSource, Source);
  if Slice <> nil then Put(Expansion, cpBorderImageSlice, Slice);
  if Width <> nil then Put(Expansion, cpBorderImageWidth, Width);
  if Outset <> nil then Put(Expansion, cpBorderImageOutset, Outset);
  if RepeatValue <> nil then Put(Expansion, cpBorderImageRepeat, RepeatValue);
end;

{ ---- backgrounds ---- }

function ExpandBackground(var Expansion: TExpansion; var Cursor: TCssTokenCursor): Boolean;
var
  Layers: array[0..7] of TCssValue;
  Color, Image, Position, Size, RepeatValue, Attachment, FirstBox, SecondBox, Item: TCssValue;
  Index: Integer;
  Progress, LastLayer: Boolean;
begin
  Result := False;
  { Image, position x and y, size, repeat, attachment, origin, clip. }
  for Index := 0 to 7 do
    Layers[Index] := NewList(lsComma);
  Color := nil;
  try
    repeat
      Image := nil;
      Position := nil;
      Size := nil;
      RepeatValue := nil;
      Attachment := nil;
      FirstBox := nil;
      SecondBox := nil;
      repeat
        Progress := False;
        if Image = nil then
        begin
          Image := ParseKeyword(Cursor, [kwNone]);
          if Image = nil then
            Image := ParseImage(Cursor);
          if Image <> nil then
            Progress := True;
        end;
        if not Progress and (Position = nil) then
        begin
          Position := ParsePosition(Cursor);
          if Position <> nil then
          begin
            Progress := True;
            if SkipDelim(Cursor, '/') then
            begin
              Size := ParseOneBackgroundSize(Cursor);
              if Size = nil then
                Break;
            end;
          end;
        end;
        if not Progress and (RepeatValue = nil) then
        begin
          RepeatValue := ParseOneBackgroundRepeat(Cursor);
          Progress := RepeatValue <> nil;
        end;
        if not Progress and (Attachment = nil) then
        begin
          Attachment := ParseKeyword(Cursor, [kwScroll, kwFixed, kwLocal]);
          Progress := Attachment <> nil;
        end;
        if not Progress and (SecondBox = nil) then
        begin
          Item := ParseKeyword(Cursor, [kwBorderBox, kwPaddingBox, kwContentBox]);
          if Item <> nil then
          begin
            if FirstBox = nil then
              FirstBox := Item
            else
              SecondBox := Item;
            Progress := True;
          end;
        end;
        if not Progress and (Color = nil) then
        begin
          Color := ParseColor(Cursor);
          Progress := Color <> nil;
        end;
      until not Progress;
      LastLayer := not SkipComma(Cursor);
      if (Color <> nil) and not LastLayer then
        Exit;
      if Image = nil then Image := NewKeyword(kwNone);
      Layers[0].Add(Image);
      if Position = nil then
      begin
        Layers[1].Add(NewPercentage(0));
        Layers[2].Add(NewPercentage(0));
      end
      else
      begin
        Layers[1].Add(Position.Items[0].AddRef);
        Layers[2].Add(Position.Items[1].AddRef);
        Position.Release;
      end;
      if Size = nil then Size := NewKeyword(kwAuto);
      Layers[3].Add(Size);
      if RepeatValue = nil then RepeatValue := NewKeyword(kwRepeat);
      Layers[4].Add(RepeatValue);
      if Attachment = nil then Attachment := NewKeyword(kwScroll);
      Layers[5].Add(Attachment);
      if FirstBox = nil then
      begin
        Layers[6].Add(NewKeyword(kwPaddingBox));
        Layers[7].Add(NewKeyword(kwBorderBox));
      end
      else
      begin
        Layers[6].Add(FirstBox);
        if SecondBox = nil then
          Layers[7].Add(FirstBox.AddRef)
        else
          Layers[7].Add(SecondBox);
      end;
    until LastLayer;
    if not Cursor.AtEndIgnoringWhitespace then
      Exit;
    if Color = nil then
      Color := NewColor(TransparentColor);
    Put(Expansion, cpBackgroundColor, Color);
    Color := nil;
    Put(Expansion, cpBackgroundImage, Layers[0].AddRef);
    Put(Expansion, cpBackgroundPositionX, Layers[1].AddRef);
    Put(Expansion, cpBackgroundPositionY, Layers[2].AddRef);
    Put(Expansion, cpBackgroundSize, Layers[3].AddRef);
    Put(Expansion, cpBackgroundRepeat, Layers[4].AddRef);
    Put(Expansion, cpBackgroundAttachment, Layers[5].AddRef);
    Put(Expansion, cpBackgroundOrigin, Layers[6].AddRef);
    Put(Expansion, cpBackgroundClip, Layers[7].AddRef);
    Result := True;
  finally
    for Index := 0 to 7 do
      Layers[Index].Release;
    ReleaseValue(Color);
  end;
end;

function ExpandBackgroundPosition(var Expansion: TExpansion; var Cursor: TCssTokenCursor): Boolean;
var
  X, Y, Position: TCssValue;
begin
  X := NewList(lsComma);
  Y := NewList(lsComma);
  repeat
    Position := ParsePosition(Cursor);
    if Position = nil then
    begin
      X.Release;
      Y.Release;
      Exit(False);
    end;
    X.Add(Position.Items[0].AddRef);
    Y.Add(Position.Items[1].AddRef);
    Position.Release;
  until not SkipComma(Cursor);
  Put(Expansion, cpBackgroundPositionX, X);
  Put(Expansion, cpBackgroundPositionY, Y);
  Result := True;
end;

{ ---- fonts ---- }

function ExpandFont(var Expansion: TExpansion; var Cursor: TCssTokenCursor): Boolean;
var
  Style, Caps, Weight, Stretch, Size, LineHeight, Family: TCssValue;
  Keyword: TCssKeyword;
  Count: Integer;
  Progress: Boolean;
begin
  Result := False;
  Keyword := PeekKeyword(Cursor);
  { The system fonts. }
  if KeywordIn(Keyword, [kwCaption, kwIcon, kwMenu, kwMessageBox, kwSmallCaption, kwStatusBar]) then
  begin
    Cursor.NextNonWhitespace;
    Put(Expansion, cpFontFamily, NewListOf(lsComma, [NewKeyword(kwSystemUi)]));
    if Keyword = kwSmallCaption then
      Put(Expansion, cpFontSize, NewKeyword(kwSmall))
    else
      Put(Expansion, cpFontSize, NewKeyword(kwMedium));
    Exit(True);
  end;
  Style := nil;
  Caps := nil;
  Weight := nil;
  Stretch := nil;
  Count := 0;
  repeat
    Progress := False;
    if Count = 4 then
      Break;
    if PeekKeyword(Cursor) = kwNormal then
    begin
      Cursor.NextNonWhitespace;
      Progress := True;
    end
    else if Style = nil then
    begin
      Style := ParseFontStyle(Cursor);
      Progress := Style <> nil;
    end;
    if not Progress and (Caps = nil) then
    begin
      Caps := ParseKeyword(Cursor, [kwSmallCaps]);
      Progress := Caps <> nil;
    end;
    if not Progress and (Weight = nil) then
    begin
      Weight := ParseLonghandPart(cpFontWeight, Cursor);
      Progress := Weight <> nil;
    end;
    if not Progress and (Stretch = nil) then
    begin
      Stretch := ParseKeyword(Cursor, [kwUltraCondensed, kwExtraCondensed, kwCondensed, kwSemiCondensed,
        kwSemiExpanded, kwExpanded, kwExtraExpanded, kwUltraExpanded]);
      Progress := Stretch <> nil;
    end;
    if Progress then
      Inc(Count);
  until not Progress;
  Size := ParseLonghandPart(cpFontSize, Cursor);
  LineHeight := nil;
  Family := nil;
  if Size <> nil then
  begin
    if SkipDelim(Cursor, '/') then
    begin
      LineHeight := ParseLonghandPart(cpLineHeight, Cursor);
      if LineHeight = nil then
        ReleaseValue(Size);
    end;
  end;
  if Size <> nil then
    Family := ParseFontFamily(Cursor);
  if (Size = nil) or (Family = nil) then
  begin
    ReleaseValue(Style);
    ReleaseValue(Caps);
    ReleaseValue(Weight);
    ReleaseValue(Stretch);
    ReleaseValue(Size);
    ReleaseValue(LineHeight);
    ReleaseValue(Family);
    Exit;
  end;
  if Style <> nil then Put(Expansion, cpFontStyle, Style);
  if Caps <> nil then Put(Expansion, cpFontVariantCaps, Caps);
  if Weight <> nil then Put(Expansion, cpFontWeight, Weight);
  if Stretch <> nil then Put(Expansion, cpFontStretch, Stretch);
  Put(Expansion, cpFontSize, Size);
  if LineHeight <> nil then Put(Expansion, cpLineHeight, LineHeight);
  Put(Expansion, cpFontFamily, Family);
  Result := True;
end;

function ExpandFontVariant(var Expansion: TExpansion; var Cursor: TCssTokenCursor): Boolean;
var
  Values: array[0..4] of TCssValue;
  Index: Integer;
  Keyword: TCssKeyword;
begin
  Keyword := PeekKeyword(Cursor);
  if (Keyword = kwNormal) or (Keyword = kwNone) then
  begin
    Cursor.NextNonWhitespace;
    if Keyword = kwNone then
      Put(Expansion, cpFontVariantLigatures, NewKeyword(kwNone));
    Exit(True);
  end;
  Result := ParseAnyOrder(Cursor, [cpFontVariantCaps, cpFontVariantLigatures, cpFontVariantNumeric,
    cpFontVariantEastAsian, cpFontVariantPosition], Values) > 0;
  for Index := 0 to 4 do
    if Values[Index] <> nil then
    begin
      if Values[Index].IsKeyword(kwNormal) or Values[Index].IsKeyword(kwNone) then
        Result := False;
      Put(Expansion, Expansion.Longhands[Index], Values[Index]);
    end;
end;

{ ---- flexible boxes ---- }

function ExpandFlex(var Expansion: TExpansion; var Cursor: TCssTokenCursor): Boolean;
var
  Grow, Shrink, Basis: TCssValue;
  Keyword: TCssKeyword;
begin
  Keyword := PeekKeyword(Cursor);
  if (Keyword = kwNone) or (Keyword = kwAuto) then
  begin
    Cursor.NextNonWhitespace;
    if Keyword = kwNone then
    begin
      Put(Expansion, cpFlexGrow, NewNumber(0));
      Put(Expansion, cpFlexShrink, NewNumber(0));
    end
    else
    begin
      Put(Expansion, cpFlexGrow, NewNumber(1));
      Put(Expansion, cpFlexShrink, NewNumber(1));
    end;
    Put(Expansion, cpFlexBasis, NewKeyword(kwAuto));
    Exit(True);
  end;
  Grow := ParseNumber(Cursor, True);
  Shrink := nil;
  if Grow <> nil then
    Shrink := ParseNumber(Cursor, True);
  Basis := ParseFlexBasis(Cursor);
  if (Grow = nil) and (Basis <> nil) then
  begin
    Grow := ParseNumber(Cursor, True);
    if Grow <> nil then
      Shrink := ParseNumber(Cursor, True);
  end;
  Result := (Grow <> nil) or (Basis <> nil);
  if not Result then
    Exit;
  if Grow = nil then Grow := NewNumber(1);
  if Shrink = nil then Shrink := NewNumber(1);
  { A flex factor without a basis means a basis of 0. }
  if Basis = nil then Basis := NewPercentage(0);
  Put(Expansion, cpFlexGrow, Grow);
  Put(Expansion, cpFlexShrink, Shrink);
  Put(Expansion, cpFlexBasis, Basis);
end;

{ ---- grids ---- }

{ The areas form of grid-template:
  [ <line-names>? <string> <track-size>? <line-names>? ]+ [ / <explicit-track-list> ]? }
function ExpandGridTemplateAreas(var Expansion: TExpansion; var Cursor: TCssTokenCursor): Boolean;
var
  Rows, Areas, Columns, Names, Size, Row, Merged: TCssValue;
  Index: Integer;
begin
  Result := False;
  Rows := NewList(lsSpace);
  Areas := NewList(lsSpace);
  try
    repeat
      Names := ParseLineNames(Cursor);
      Row := ParseStringValue(Cursor);
      if Row = nil then
      begin
        if Names <> nil then
        begin
          { Line names after the last row's own names join them. }
          if (Rows.Count > 0) and (Rows.Items[Rows.Count - 1].Text = '[') then
          begin
            Merged := Rows.Items[Rows.Count - 1];
            for Index := 0 to Names.Count - 1 do
              Merged.Add(Names.Items[Index].AddRef);
            Names.Release;
          end
          else
            Rows.Add(Names);
        end;
        Break;
      end;
      if Names <> nil then
      begin
        if (Rows.Count > 0) and (Rows.Items[Rows.Count - 1].Text = '[') then
        begin
          Merged := Rows.Items[Rows.Count - 1];
          for Index := 0 to Names.Count - 1 do
            Merged.Add(Names.Items[Index].AddRef);
          Names.Release;
        end
        else
          Rows.Add(Names);
      end;
      Areas.Add(Row);
      Size := ParseTrackSize(Cursor);
      if Size = nil then
        Size := NewKeyword(kwAuto);
      Rows.Add(Size);
      Names := ParseLineNames(Cursor);
      if Names <> nil then
        Rows.Add(Names);
    until False;
    if (Areas.Count = 0) or not AreasAreValid(Areas) then
      Exit;
    Columns := nil;
    if SkipDelim(Cursor, '/') then
    begin
      Columns := ParseExplicitTrackList(Cursor);
      if Columns = nil then
        Exit;
    end
    else
      Columns := NewKeyword(kwNone);
    Put(Expansion, cpGridTemplateRows, Rows.AddRef);
    Put(Expansion, cpGridTemplateColumns, Columns);
    Put(Expansion, cpGridTemplateAreas, Areas.AddRef);
    Result := True;
  finally
    Rows.Release;
    Areas.Release;
  end;
end;

function ExpandGridTemplate(var Expansion: TExpansion; var Cursor: TCssTokenCursor): Boolean;
var
  Saved: Integer;
  Rows, Columns: TCssValue;
begin
  Result := False;
  if PeekKeyword(Cursor) = kwNone then
  begin
    Cursor.NextNonWhitespace;
    Exit(True);
  end;
  Saved := Cursor.Position;
  Rows := ParseTrackListValue(Cursor);
  if (Rows <> nil) and SkipDelim(Cursor, '/') then
  begin
    Columns := ParseTrackListValue(Cursor);
    if (Columns <> nil) and Cursor.AtEndIgnoringWhitespace then
    begin
      Put(Expansion, cpGridTemplateRows, Rows);
      Put(Expansion, cpGridTemplateColumns, Columns);
      Exit(True);
    end;
    ReleaseValue(Columns);
  end;
  ReleaseValue(Rows);
  Cursor.Position := Saved;
  Result := ExpandGridTemplateAreas(Expansion, Cursor);
end;

{ [ auto-flow && dense? ] <grid-auto-*>? on one side of the slash. }
function ParseAutoFlowSide(var Cursor: TCssTokenCursor; out Dense: Boolean; out AutoTracks: TCssValue): Boolean;
var
  Keyword: TCssKeyword;
  SawAutoFlow: Boolean;
  Index: Integer;
begin
  Dense := False;
  SawAutoFlow := False;
  AutoTracks := nil;
  for Index := 1 to 2 do
  begin
    Keyword := PeekKeyword(Cursor);
    if (Keyword = kwAutoFlow) and not SawAutoFlow then
      SawAutoFlow := True
    else if (Keyword = kwDense) and not Dense then
      Dense := True
    else
      Break;
    Cursor.NextNonWhitespace;
  end;
  Result := SawAutoFlow;
  if Result then
    AutoTracks := ParseTrackSizes(Cursor);
end;

function ExpandGrid(var Expansion: TExpansion; var Cursor: TCssTokenCursor): Boolean;
var
  Saved: Integer;
  Dense: Boolean;
  AutoTracks, Template: TCssValue;
begin
  Saved := Cursor.Position;
  if ParseAutoFlowSide(Cursor, Dense, AutoTracks) then
  begin
    { auto-flow on the rows' side: columns after the slash. }
    if SkipDelim(Cursor, '/') then
    begin
      Template := ParseTrackListValue(Cursor);
      if Template <> nil then
      begin
        Put(Expansion, cpGridTemplateColumns, Template);
        if AutoTracks <> nil then
          Put(Expansion, cpGridAutoRows, AutoTracks);
        if Dense then
          Put(Expansion, cpGridAutoFlow, NewKeyword(kwDense))
        else
          Put(Expansion, cpGridAutoFlow, NewKeyword(kwRow));
        Exit(True);
      end;
    end;
    ReleaseValue(AutoTracks);
    Exit(False);
  end;
  Template := ParseTrackListValue(Cursor);
  if (Template <> nil) and SkipDelim(Cursor, '/') and ParseAutoFlowSide(Cursor, Dense, AutoTracks) then
  begin
    Put(Expansion, cpGridTemplateRows, Template);
    if AutoTracks <> nil then
      Put(Expansion, cpGridAutoColumns, AutoTracks);
    if Dense then
      Put(Expansion, cpGridAutoFlow, NewListOf(lsSpace, [NewKeyword(kwColumn), NewKeyword(kwDense)]))
    else
      Put(Expansion, cpGridAutoFlow, NewKeyword(kwColumn));
    Exit(True);
  end;
  ReleaseValue(Template);
  Cursor.Position := Saved;
  Result := ExpandGridTemplate(Expansion, Cursor);
end;

{ The end a grid line shorthand leaves out: the start's name, or auto. }
function DefaultLineEnd(Start: TCssValue): TCssValue;
begin
  if (Start <> nil) and (Start.Kind = vkCustomIdent) then
    Result := Start.AddRef
  else
    Result := NewKeyword(kwAuto);
end;

function ExpandGridLines(var Expansion: TExpansion; var Cursor: TCssTokenCursor; Maximum: Integer): Boolean;
var
  Lines: array[0..3] of TCssValue;
  Count, Index: Integer;
begin
  Count := 0;
  repeat
    Lines[Count] := ParseGridLine(Cursor);
    if Lines[Count] = nil then
    begin
      for Index := 0 to Count - 1 do
        Lines[Index].Release;
      Exit(False);
    end;
    Inc(Count);
  until (Count = Maximum) or not SkipDelim(Cursor, '/');
  if Maximum = 2 then
  begin
    if Count = 1 then
      Lines[1] := DefaultLineEnd(Lines[0]);
  end
  else
  begin
    if Count < 2 then Lines[1] := DefaultLineEnd(Lines[0]);
    if Count < 3 then Lines[2] := DefaultLineEnd(Lines[0]);
    if Count < 4 then Lines[3] := DefaultLineEnd(Lines[1]);
  end;
  for Index := 0 to Maximum - 1 do
    Put(Expansion, Expansion.Longhands[Index], Lines[Index]);
  Result := True;
end;

function ExpandPlace(var Expansion: TExpansion; var Cursor: TCssTokenCursor): Boolean;
var
  First, Second: TCssValue;
begin
  First := ParseLonghandPart(Expansion.Longhands[0], Cursor);
  if First = nil then
    Exit(False);
  Second := ParseLonghandPart(Expansion.Longhands[1], Cursor);
  if Second = nil then
  begin
    { One value sets both; a baseline value is start for justification. }
    if First.IsKeyword(kwBaseline) or ((First.Kind = vkList) and (First.Count = 2) and
      First.Items[1].IsKeyword(kwBaseline)) then
      Second := NewKeyword(kwStart)
    else
      Second := First.AddRef;
  end;
  Put(Expansion, Expansion.Longhands[0], First);
  Put(Expansion, Expansion.Longhands[1], Second);
  Result := True;
end;

{ ---- lists, decoration ---- }

function ExpandListStyle(var Expansion: TExpansion; var Cursor: TCssTokenCursor): Boolean;
var
  Position, Image, ListType: TCssValue;
  Nones: Integer;
  Progress: Boolean;
begin
  Position := nil;
  Image := nil;
  ListType := nil;
  Nones := 0;
  repeat
    Progress := False;
    if PeekKeyword(Cursor) = kwNone then
    begin
      Cursor.NextNonWhitespace;
      Inc(Nones);
      Progress := True;
      Continue;
    end;
    if Position = nil then
    begin
      Position := ParseKeyword(Cursor, [kwInside, kwOutside]);
      Progress := Position <> nil;
    end;
    if not Progress and (Image = nil) then
    begin
      Image := ParseImage(Cursor);
      Progress := Image <> nil;
    end;
    if not Progress and (ListType = nil) then
    begin
      ListType := ParseListStyleType(Cursor);
      Progress := ListType <> nil;
    end;
  until not Progress;
  Result := (Position <> nil) or (Image <> nil) or (ListType <> nil) or (Nones > 0);
  if Nones > 0 then
  begin
    if (Nones = 2) and (Image = nil) and (ListType = nil) then
    begin
      Image := NewKeyword(kwNone);
      ListType := NewKeyword(kwNone);
    end
    else if (Nones = 1) and (Image = nil) then
      Image := NewKeyword(kwNone)
    else if (Nones = 1) and (ListType = nil) then
      ListType := NewKeyword(kwNone)
    else
      Result := False;
  end;
  if Position <> nil then Put(Expansion, cpListStylePosition, Position);
  if Image <> nil then Put(Expansion, cpListStyleImage, Image);
  if ListType <> nil then Put(Expansion, cpListStyleType, ListType);
end;

function ExpandAnyOrder(var Expansion: TExpansion; var Cursor: TCssTokenCursor): Boolean;
var
  Values: array of TCssValue;
  Index: Integer;
begin
  SetLength(Values, Length(Expansion.Longhands));
  Result := ParseAnyOrder(Cursor, Expansion.Longhands, Values) > 0;
  for Index := 0 to High(Values) do
    if Values[Index] <> nil then
      Put(Expansion, Expansion.Longhands[Index], Values[Index]);
end;

{ ---- transitions and animations ---- }

function ExpandTransition(var Expansion: TExpansion; var Cursor: TCssTokenCursor): Boolean;
var
  Lists: array[0..4] of TCssValue;
  PropertyName, Duration, Easing, Delay, Behavior, Time: TCssValue;
  Index, Count: Integer;
  Progress: Boolean;
begin
  Result := False;
  for Index := 0 to 4 do
    Lists[Index] := NewList(lsComma);
  Count := 0;
  try
    repeat
      PropertyName := nil;
      Duration := nil;
      Easing := nil;
      Delay := nil;
      Behavior := nil;
      repeat
        Progress := False;
        if PropertyName = nil then
        begin
          PropertyName := ParseKeyword(Cursor, [kwNone]);
          if PropertyName = nil then
            PropertyName := ParseSingleTransitionProperty(Cursor);
          Progress := PropertyName <> nil;
        end;
        if not Progress and (Delay = nil) then
        begin
          Time := ParseTime(Cursor);
          if Time <> nil then
          begin
            if (Duration = nil) and not ((Time.Kind = vkDimension) and (Time.Number < 0)) then
              Duration := Time
            else
              Delay := Time;
            Progress := True;
          end;
        end;
        if not Progress and (Easing = nil) then
        begin
          Easing := ParseEasing(Cursor);
          Progress := Easing <> nil;
        end;
        if not Progress and (Behavior = nil) then
        begin
          Behavior := ParseKeyword(Cursor, [kwNormal, kwAllowDiscrete]);
          Progress := Behavior <> nil;
        end;
      until not Progress;
      Inc(Count);
      if PropertyName = nil then PropertyName := NewKeyword(kwAll);
      if Duration = nil then Duration := NewDimension(0, cuS);
      if Easing = nil then Easing := NewKeyword(kwEase);
      if Delay = nil then Delay := NewDimension(0, cuS);
      if Behavior = nil then Behavior := NewKeyword(kwNormal);
      Lists[0].Add(PropertyName);
      Lists[1].Add(Duration);
      Lists[2].Add(Easing);
      Lists[3].Add(Delay);
      Lists[4].Add(Behavior);
    until not SkipComma(Cursor);
    { 'none' only as the whole list. }
    if Count > 1 then
      for Index := 0 to Lists[0].Count - 1 do
        if Lists[0].Items[Index].IsKeyword(kwNone) then
          Exit;
    if (Count = 1) and Lists[0].Items[0].IsKeyword(kwNone) then
      Put(Expansion, cpTransitionProperty, NewKeyword(kwNone))
    else
      Put(Expansion, cpTransitionProperty, Lists[0].AddRef);
    Put(Expansion, cpTransitionDuration, Lists[1].AddRef);
    Put(Expansion, cpTransitionTimingFunction, Lists[2].AddRef);
    Put(Expansion, cpTransitionDelay, Lists[3].AddRef);
    Put(Expansion, cpTransitionBehavior, Lists[4].AddRef);
    Result := True;
  finally
    for Index := 0 to 4 do
      Lists[Index].Release;
  end;
end;

function ExpandAnimation(var Expansion: TExpansion; var Cursor: TCssTokenCursor): Boolean;
const
  Targets: array[0..7] of TCssPropertyId = (cpAnimationName, cpAnimationDuration, cpAnimationTimingFunction,
    cpAnimationDelay, cpAnimationIterationCount, cpAnimationDirection, cpAnimationFillMode,
    cpAnimationPlayState);
var
  Lists: array[0..7] of TCssValue;
  Parts: array[0..7] of TCssValue;
  Index: Integer;
  Progress: Boolean;
  Time: TCssValue;
begin
  Result := False;
  for Index := 0 to 7 do
    Lists[Index] := NewList(lsComma);
  try
    repeat
      for Index := 0 to 7 do
        Parts[Index] := nil;
      repeat
        Progress := False;
        if Parts[3] = nil then
        begin
          if Parts[1] = nil then
            Time := ParseKeyword(Cursor, [kwAuto])
          else
            Time := nil;
          if Time = nil then
            Time := ParseTime(Cursor);
          if Time <> nil then
          begin
            if (Parts[1] = nil) and not ((Time.Kind = vkDimension) and (Time.Number < 0)) then
              Parts[1] := Time
            else
              Parts[3] := Time;
            Progress := True;
            Continue;
          end;
        end;
        if Parts[2] = nil then
        begin
          Parts[2] := ParseEasing(Cursor);
          if Parts[2] <> nil then
          begin
            Progress := True;
            Continue;
          end;
        end;
        if Parts[4] = nil then
        begin
          Parts[4] := ParseKeyword(Cursor, [kwInfinite]);
          if Parts[4] = nil then
            Parts[4] := ParseNumber(Cursor, True);
          if Parts[4] <> nil then
          begin
            Progress := True;
            Continue;
          end;
        end;
        if Parts[5] = nil then
        begin
          Parts[5] := ParseKeyword(Cursor, [kwNormal, kwReverse, kwAlternate, kwAlternateReverse]);
          if Parts[5] <> nil then
          begin
            Progress := True;
            Continue;
          end;
        end;
        if Parts[6] = nil then
        begin
          Parts[6] := ParseKeyword(Cursor, [kwNone, kwForwards, kwBackwards, kwBoth]);
          if Parts[6] <> nil then
          begin
            Progress := True;
            Continue;
          end;
        end;
        if Parts[7] = nil then
        begin
          Parts[7] := ParseKeyword(Cursor, [kwRunning, kwPaused]);
          if Parts[7] <> nil then
          begin
            Progress := True;
            Continue;
          end;
        end;
        if Parts[0] = nil then
        begin
          Parts[0] := ParseSingleAnimationName(Cursor);
          Progress := Parts[0] <> nil;
        end;
      until not Progress;
      for Index := 0 to 7 do
        if Parts[Index] = nil then
          Parts[Index] := InitialValue(Targets[Index]).Items[0].AddRef;
      for Index := 0 to 7 do
        Lists[Index].Add(Parts[Index]);
    until not SkipComma(Cursor);
    for Index := 0 to 7 do
      Put(Expansion, Targets[Index], Lists[Index].AddRef);
    Result := True;
  finally
    for Index := 0 to 7 do
      Lists[Index].Release;
  end;
end;

function ExpandContainer(var Expansion: TExpansion; var Cursor: TCssTokenCursor): Boolean;
var
  Name, ContainerType: TCssValue;
begin
  Name := ParseContainerName(Cursor);
  if Name = nil then
    Exit(False);
  Put(Expansion, cpContainerName, Name);
  if SkipDelim(Cursor, '/') then
  begin
    ContainerType := ParseLonghandPart(cpContainerType, Cursor);
    if ContainerType = nil then
      Exit(False);
    Put(Expansion, cpContainerType, ContainerType);
  end;
  Result := True;
end;

function ExpandShorthand(Id: TCssPropertyId; Cursor: TCssTokenCursor; out Values: TCssValueArray): Boolean;
var
  Expansion: TExpansion;
  Index: Integer;
begin
  Values := nil;
  Expansion.Longhands := ShorthandLonghands(Id);
  if Length(Expansion.Longhands) = 0 then
    Exit(False);
  SetLength(Expansion.Values, Length(Expansion.Longhands));
  for Index := 0 to High(Expansion.Values) do
    Expansion.Values[Index] := nil;
  case Id of
    cpMargin, cpPadding, cpInset, cpBorderWidth, cpBorderStyle, cpBorderColor:
      Result := ExpandSides(Expansion, Cursor);
    cpMarginBlock, cpMarginInline, cpPaddingBlock, cpPaddingInline, cpInsetBlock, cpInsetInline,
    cpBorderBlockWidth, cpBorderBlockStyle, cpBorderBlockColor, cpBorderInlineWidth, cpBorderInlineStyle,
    cpBorderInlineColor, cpGap, cpOverflow:
      Result := ExpandPair(Expansion, Cursor);
    cpBorderTop, cpBorderRight, cpBorderBottom, cpBorderLeft, cpBorderBlockStart, cpBorderBlockEnd,
    cpBorderInlineStart, cpBorderInlineEnd:
      Result := ExpandBorderSides(Expansion, Cursor, [Expansion.Longhands[0]], [Expansion.Longhands[1]],
        [Expansion.Longhands[2]]);
    cpBorder:
      Result := ExpandBorderSides(Expansion, Cursor,
        [cpBorderTopWidth, cpBorderRightWidth, cpBorderBottomWidth, cpBorderLeftWidth],
        [cpBorderTopStyle, cpBorderRightStyle, cpBorderBottomStyle, cpBorderLeftStyle],
        [cpBorderTopColor, cpBorderRightColor, cpBorderBottomColor, cpBorderLeftColor]);
    cpBorderBlock:
      Result := ExpandBorderSides(Expansion, Cursor, [cpBorderBlockStartWidth, cpBorderBlockEndWidth],
        [cpBorderBlockStartStyle, cpBorderBlockEndStyle], [cpBorderBlockStartColor, cpBorderBlockEndColor]);
    cpBorderInline:
      Result := ExpandBorderSides(Expansion, Cursor, [cpBorderInlineStartWidth, cpBorderInlineEndWidth],
        [cpBorderInlineStartStyle, cpBorderInlineEndStyle], [cpBorderInlineStartColor, cpBorderInlineEndColor]);
    cpBorderRadius: Result := ExpandBorderRadius(Expansion, Cursor);
    cpBorderImage: Result := ExpandBorderImage(Expansion, Cursor);
    cpOutline, cpFlexFlow, cpTextDecoration, cpColumns, cpColumnRule:
      Result := ExpandAnyOrder(Expansion, Cursor);
    cpBackground: Result := ExpandBackground(Expansion, Cursor);
    cpBackgroundPosition: Result := ExpandBackgroundPosition(Expansion, Cursor);
    cpFont: Result := ExpandFont(Expansion, Cursor);
    cpFontVariant: Result := ExpandFontVariant(Expansion, Cursor);
    cpFlex: Result := ExpandFlex(Expansion, Cursor);
    cpGrid: Result := ExpandGrid(Expansion, Cursor);
    cpGridTemplate: Result := ExpandGridTemplate(Expansion, Cursor);
    cpGridRow, cpGridColumn: Result := ExpandGridLines(Expansion, Cursor, 2);
    cpGridArea: Result := ExpandGridLines(Expansion, Cursor, 4);
    cpPlaceContent, cpPlaceItems, cpPlaceSelf: Result := ExpandPlace(Expansion, Cursor);
    cpListStyle: Result := ExpandListStyle(Expansion, Cursor);
    cpTransition: Result := ExpandTransition(Expansion, Cursor);
    cpAnimation: Result := ExpandAnimation(Expansion, Cursor);
    cpContainer: Result := ExpandContainer(Expansion, Cursor);
  else
    Result := False;
  end;
  if Result and not Cursor.AtEndIgnoringWhitespace then
    Result := False;
  if not Result then
  begin
    ReleaseExpansion(Expansion);
    Exit;
  end;
  for Index := 0 to High(Expansion.Values) do
    if Expansion.Values[Index] = nil then
      Expansion.Values[Index] := InitialValue(Expansion.Longhands[Index]).AddRef;
  Values := Expansion.Values;
end;

end.
