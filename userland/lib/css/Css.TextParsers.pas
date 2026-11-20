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
  Value routines for fonts, text, generated content, lists, the user
  interface and animations: font families, font-style, font feature
  and variation settings, shadows, cursors, color-scheme, list styles,
  quotes, text-overflow, content, counters, transition properties,
  easing functions and animation names.
}
unit Css.TextParsers;

{$mode objfpc}
{$H+}

interface

uses
  Css.Tokens, Css.Values;

function ParseFontFamily(var Cursor: TCssTokenCursor): TCssValue;
{ One family: a string, a generic keyword, or a run of identifiers
  (joined by single spaces into a string value). }
function ParseFamilyName(var Cursor: TCssTokenCursor): TCssValue;
function ParseFontStyle(var Cursor: TCssTokenCursor): TCssValue;
function ParseFontFeatureSettings(var Cursor: TCssTokenCursor): TCssValue;
function ParseFontVariationSettings(var Cursor: TCssTokenCursor): TCssValue;
function ParseTextShadow(var Cursor: TCssTokenCursor): TCssValue;
function ParseBoxShadow(var Cursor: TCssTokenCursor): TCssValue;
function ParseCursor(var Cursor: TCssTokenCursor): TCssValue;
function ParseColorScheme(var Cursor: TCssTokenCursor): TCssValue;
function ParseListStyleType(var Cursor: TCssTokenCursor): TCssValue;
function ParseQuotes(var Cursor: TCssTokenCursor): TCssValue;
function ParseTextOverflow(var Cursor: TCssTokenCursor): TCssValue;
function ParseContent(var Cursor: TCssTokenCursor): TCssValue;
function ParseCounterReset(var Cursor: TCssTokenCursor): TCssValue;
function ParseCounterIncrement(var Cursor: TCssTokenCursor): TCssValue;
function ParseTransitionProperty(var Cursor: TCssTokenCursor): TCssValue;
{ One transition property name: all or an identifier. }
function ParseSingleTransitionProperty(var Cursor: TCssTokenCursor): TCssValue;
function ParseEasing(var Cursor: TCssTokenCursor): TCssValue;
function ParseEasingList(var Cursor: TCssTokenCursor): TCssValue;
function ParseAnimationName(var Cursor: TCssTokenCursor): TCssValue;
function ParseSingleAnimationName(var Cursor: TCssTokenCursor): TCssValue;

implementation

uses
  Css.Atoms, Css.Keywords, Css.Units, Css.ValueParser, Css.ColorParser, Css.Images;

function IsGenericFamily(Keyword: TCssKeyword): Boolean;
begin
  Result := KeywordIn(Keyword, [kwSerif, kwSansSerif, kwMonospace, kwCursive, kwFantasy, kwSystemUi,
    kwUiSerif, kwUiSansSerif, kwUiMonospace, kwUiRounded, kwMath, kwEmoji, kwFangsong]);
end;

function ParseFamilyName(var Cursor: TCssTokenCursor): TCssValue;
var
  Saved: Integer;
  Token: PCssToken;
  Name: string;
  Keyword: TCssKeyword;
  Count: Integer;
begin
  Result := ParseStringValue(Cursor);
  if Result <> nil then
    Exit;
  Saved := Cursor.Position;
  Keyword := PeekKeyword(Cursor);
  if IsGenericFamily(Keyword) then
  begin
    Result := ParseKeyword(Cursor, []);
    { A generic keyword followed by more identifiers is an ordinary name. }
    Cursor.SkipWhitespace;
    if Cursor.PeekKind <> tkIdent then
      Exit;
    ReleaseValue(Result);
    Cursor.Position := Saved;
  end;
  Name := '';
  Count := 0;
  repeat
    Cursor.SkipWhitespace;
    Token := Cursor.Peek;
    if Token^.Kind <> tkIdent then
      Break;
    Keyword := KeywordOfAtom(FindAtom(AsciiLowercase(Token^.Text)));
    { CSS-wide keywords and 'default' cannot start a family name. }
    if (Count = 0) and (CssWideKeyword(Keyword) or (Keyword = kwDefault)) then
      Break;
    if Count > 0 then
      Name := Name + ' ';
    Name := Name + Token^.Text;
    Inc(Count);
    Inc(Cursor.Position);
  until False;
  if Count = 0 then
  begin
    Cursor.Position := Saved;
    Exit(nil);
  end;
  Result := NewCustomIdent(Name);
end;

function ParseFontFamily(var Cursor: TCssTokenCursor): TCssValue;
var
  Item: TCssValue;
begin
  Result := NewList(lsComma);
  repeat
    Item := ParseFamilyName(Cursor);
    if Item = nil then
    begin
      ReleaseValue(Result);
      Exit;
    end;
    Result.Add(Item);
  until not SkipComma(Cursor);
end;

function ParseFontStyle(var Cursor: TCssTokenCursor): TCssValue;
var
  Angle: TCssValue;
begin
  Result := ParseKeyword(Cursor, [kwNormal, kwItalic]);
  if Result <> nil then
    Exit;
  Result := ParseKeyword(Cursor, [kwOblique]);
  if Result = nil then
    Exit;
  Angle := ParseAngle(Cursor, False);
  if Angle <> nil then
  begin
    if (Angle.Kind = vkDimension) and (Abs(Angle.Number * CanonicalFactor(Angle.UnitValue)) > 90) then
    begin
      Angle.Release;
      ReleaseValue(Result);
      Exit;
    end;
    Result := NewListOf(lsSpace, [Result, Angle]);
  end;
end;

{ normal | [ <string> [ <integer [0,inf]> | on | off ]? ]# }
function ParseFontFeatureSettings(var Cursor: TCssTokenCursor): TCssValue;
var
  Tag, Setting, Item: TCssValue;
begin
  Result := ParseKeyword(Cursor, [kwNormal]);
  if Result <> nil then
    Exit;
  Result := NewList(lsComma);
  repeat
    Tag := ParseStringValue(Cursor);
    if (Tag = nil) or (Length(Tag.Text) <> 4) then
    begin
      ReleaseValue(Tag);
      ReleaseValue(Result);
      Exit;
    end;
    Setting := ParseInteger(Cursor, 0);
    if Setting = nil then
      Setting := ParseKeyword(Cursor, [kwOn, kwOff]);
    if Setting = nil then
      Item := Tag
    else
      Item := NewListOf(lsSpace, [Tag, Setting]);
    Result.Add(Item);
  until not SkipComma(Cursor);
end;

function ParseFontVariationSettings(var Cursor: TCssTokenCursor): TCssValue;
var
  Tag, Setting: TCssValue;
begin
  Result := ParseKeyword(Cursor, [kwNormal]);
  if Result <> nil then
    Exit;
  Result := NewList(lsComma);
  repeat
    Tag := ParseStringValue(Cursor);
    Setting := nil;
    if Tag <> nil then
      Setting := ParseNumber(Cursor);
    if (Tag = nil) or (Setting = nil) or (Length(Tag.Text) <> 4) then
    begin
      ReleaseValue(Tag);
      ReleaseValue(Setting);
      ReleaseValue(Result);
      Exit;
    end;
    Result.Add(NewListOf(lsSpace, [Tag, Setting]));
  until not SkipComma(Cursor);
end;

{ One shadow: lengths (2 to MaxLengths), a color, and inset (box shadows), in any order. }
function ParseShadow(var Cursor: TCssTokenCursor; MaxLengths: Integer; AllowInset: Boolean): TCssValue;
var
  Color, Inset, Length: TCssValue;
  Lengths: array[0..3] of TCssValue;
  Count, Index: Integer;
  Progress: Boolean;
begin
  Result := nil;
  Color := nil;
  Inset := nil;
  Count := 0;
  repeat
    Progress := False;
    if (Count = 0) then
    begin
      repeat
        { Blur must not be negative. }
        Length := ParseLength(Cursor, Count = 2);
        if Length = nil then
          Break;
        Lengths[Count] := Length;
        Inc(Count);
        Progress := True;
      until Count = MaxLengths;
      if Progress then
        Continue;
    end;
    if Color = nil then
    begin
      Color := ParseColor(Cursor);
      if Color <> nil then
      begin
        Progress := True;
        Continue;
      end;
    end;
    if AllowInset and (Inset = nil) then
    begin
      Inset := ParseKeyword(Cursor, [kwInset]);
      if Inset <> nil then
      begin
        Progress := True;
        Continue;
      end;
    end;
  until not Progress;
  if Count < 2 then
  begin
    for Index := 0 to Count - 1 do
      Lengths[Index].Release;
    ReleaseValue(Color);
    ReleaseValue(Inset);
    Exit;
  end;
  Result := NewList(lsSpace);
  if Color <> nil then
    Result.Add(Color);
  for Index := 0 to Count - 1 do
    Result.Add(Lengths[Index]);
  if Inset <> nil then
    Result.Add(Inset);
end;

function ParseShadowList(var Cursor: TCssTokenCursor; MaxLengths: Integer; AllowInset: Boolean): TCssValue;
var
  Item: TCssValue;
begin
  Result := ParseKeyword(Cursor, [kwNone]);
  if Result <> nil then
    Exit;
  Result := NewList(lsComma);
  repeat
    Item := ParseShadow(Cursor, MaxLengths, AllowInset);
    if Item = nil then
    begin
      ReleaseValue(Result);
      Exit;
    end;
    Result.Add(Item);
  until not SkipComma(Cursor);
end;

function ParseTextShadow(var Cursor: TCssTokenCursor): TCssValue;
begin
  Result := ParseShadowList(Cursor, 3, False);
end;

function ParseBoxShadow(var Cursor: TCssTokenCursor): TCssValue;
begin
  Result := ParseShadowList(Cursor, 4, True);
end;

const
  CursorKeywords: array[0..35] of TCssKeyword = (kwAuto, kwDefault, kwNone, kwContextMenu, kwHelp,
    kwPointer, kwProgress, kwWait, kwCell, kwCrosshair, kwText, kwVerticalText, kwAlias, kwCopy, kwMove,
    kwNoDrop, kwNotAllowed, kwGrab, kwGrabbing, kwEResize, kwNResize, kwNeResize, kwNwResize, kwSResize,
    kwSeResize, kwSwResize, kwWResize, kwEwResize, kwNsResize, kwNeswResize, kwNwseResize, kwColResize,
    kwRowResize, kwAllScroll, kwZoomIn, kwZoomOut);

{ [ [ <url> [<x> <y>]? ]# , ]? <keyword> }
function ParseCursor(var Cursor: TCssTokenCursor): TCssValue;
var
  Image, X, Y, Keyword: TCssValue;
  Entry: TCssValue;
begin
  Result := NewList(lsComma);
  repeat
    Keyword := ParseKeyword(Cursor, CursorKeywords);
    if Keyword <> nil then
    begin
      Result.Add(Keyword);
      if Result.Count = 1 then
      begin
        Keyword := Result.Items[0].AddRef;
        Result.Release;
        Result := Keyword;
      end;
      Exit;
    end;
    Image := ParseImage(Cursor);
    if Image = nil then
      Break;
    Entry := NewListOf(lsSpace, [Image]);
    X := ParseNumber(Cursor);
    if X <> nil then
    begin
      Y := ParseNumber(Cursor);
      if Y = nil then
      begin
        X.Release;
        Entry.Release;
        Break;
      end;
      Entry.Add(X);
      Entry.Add(Y);
    end;
    Result.Add(Entry);
  until not SkipComma(Cursor);
  ReleaseValue(Result);
end;

function ParseColorScheme(var Cursor: TCssTokenCursor): TCssValue;
var
  Item, Only: TCssValue;
begin
  Result := ParseKeyword(Cursor, [kwNormal]);
  if Result <> nil then
    Exit;
  Result := NewList(lsSpace);
  Only := ParseKeyword(Cursor, [kwOnly]);
  repeat
    Item := ParseKeyword(Cursor, [kwLight, kwDark]);
    if Item = nil then
      Item := ParseCustomIdent(Cursor, [kwNormal, kwOnly, kwLight, kwDark]);
    if Item = nil then
      Break;
    Result.Add(Item);
  until False;
  if Only = nil then
    Only := ParseKeyword(Cursor, [kwOnly]);
  if Result.Count = 0 then
  begin
    ReleaseValue(Only);
    ReleaseValue(Result);
    Exit;
  end;
  if Only <> nil then
    Result.Add(Only);
end;

function ParseListStyleType(var Cursor: TCssTokenCursor): TCssValue;
var
  Keyword: TCssKeyword;
begin
  Result := ParseStringValue(Cursor);
  if Result <> nil then
    Exit;
  Keyword := PeekKeyword(Cursor);
  if KeywordIn(Keyword, [kwNone, kwDisc, kwCircle, kwSquare, kwDecimal, kwDecimalLeadingZero, kwLowerRoman,
    kwUpperRoman, kwLowerAlpha, kwUpperAlpha, kwLowerLatin, kwUpperLatin, kwLowerGreek, kwArmenian,
    kwGeorgian, kwHebrew, kwDisclosureOpen, kwDisclosureClosed]) then
    Exit(ParseKeyword(Cursor, []));
  { Any other counter style name. }
  Result := ParseCustomIdent(Cursor, [kwNone]);
end;

function ParseQuotes(var Cursor: TCssTokenCursor): TCssValue;
var
  Open, Close: TCssValue;
begin
  Result := ParseKeyword(Cursor, [kwNone, kwAuto]);
  if Result <> nil then
    Exit;
  Result := NewList(lsSpace);
  repeat
    Open := ParseStringValue(Cursor);
    if Open = nil then
      Break;
    Close := ParseStringValue(Cursor);
    if Close = nil then
    begin
      Open.Release;
      ReleaseValue(Result);
      Exit;
    end;
    Result.Add(Open);
    Result.Add(Close);
  until False;
  if Result.Count = 0 then
    ReleaseValue(Result);
end;

function ParseOverflowSide(var Cursor: TCssTokenCursor): TCssValue;
begin
  Result := ParseKeyword(Cursor, [kwClip, kwEllipsis]);
  if Result = nil then
    Result := ParseStringValue(Cursor);
end;

function ParseTextOverflow(var Cursor: TCssTokenCursor): TCssValue;
var
  First, Second: TCssValue;
begin
  Result := nil;
  First := ParseOverflowSide(Cursor);
  if First = nil then
    Exit;
  Second := ParseOverflowSide(Cursor);
  if Second = nil then
    Exit(First);
  Result := NewListOf(lsSpace, [First, Second]);
end;

{ counter(name, style?), counters(name, string, style?), attr(name fallback?) }
function ParseContentFunction(var Cursor: TCssTokenCursor): TCssValue;
var
  Saved: Integer;
  Token: PCssToken;
  Lower: string;
  Contents: TCssTokenCursor;
  Name, Separator, Style: TCssValue;
begin
  Result := nil;
  Saved := Cursor.Position;
  Cursor.SkipWhitespace;
  Token := Cursor.Peek;
  if Token^.Kind <> tkFunction then
    Exit;
  Lower := AsciiLowercase(Token^.Text);
  Cursor.Next;
  Contents := Cursor.Contents(Token);
  if (Lower = 'counter') or (Lower = 'counters') then
  begin
    Name := ParseCustomIdent(Contents, [kwNone]);
    if Name <> nil then
    begin
      Result := NewFunction(Lower);
      Result.Add(Name);
      if Lower = 'counters' then
      begin
        Separator := nil;
        if SkipComma(Contents) then
          Separator := ParseStringValue(Contents);
        if Separator = nil then
          ReleaseValue(Result)
        else
          Result.Add(Separator);
      end;
      if (Result <> nil) and SkipComma(Contents) then
      begin
        Style := ParseListStyleType(Contents);
        if Style = nil then
          ReleaseValue(Result)
        else
          Result.Add(Style);
      end;
      if (Result <> nil) and not Contents.AtEndIgnoringWhitespace then
        ReleaseValue(Result);
    end;
  end
  else if Lower = 'attr' then
  begin
    Name := ParseCustomIdent(Contents, []);
    if Name <> nil then
    begin
      Result := NewFunction('attr');
      Result.Add(Name);
      if SkipComma(Contents) then
      begin
        Separator := ParseStringValue(Contents);
        if Separator = nil then
          ReleaseValue(Result)
        else
          Result.Add(Separator);
      end;
      if (Result <> nil) and not Contents.AtEndIgnoringWhitespace then
        ReleaseValue(Result);
    end;
  end;
  if Result = nil then
    Cursor.Position := Saved;
end;

function ParseContent(var Cursor: TCssTokenCursor): TCssValue;
var
  Item, Alternative, Items: TCssValue;
begin
  Result := ParseKeyword(Cursor, [kwNormal, kwNone]);
  if Result <> nil then
    Exit;
  Items := NewList(lsSpace);
  repeat
    Item := ParseStringValue(Cursor);
    if Item = nil then
      Item := ParseKeyword(Cursor, [kwOpenQuote, kwCloseQuote, kwNoOpenQuote, kwNoCloseQuote]);
    if Item = nil then
      Item := ParseImage(Cursor);
    if Item = nil then
      Item := ParseContentFunction(Cursor);
    if Item = nil then
      Break;
    Items.Add(Item);
  until False;
  if Items.Count = 0 then
  begin
    Items.Release;
    Exit;
  end;
  { Alternative text after a slash. }
  if SkipDelim(Cursor, '/') then
  begin
    Alternative := NewList(lsSpace);
    repeat
      Item := ParseStringValue(Cursor);
      if Item = nil then
        Item := ParseContentFunction(Cursor);
      if Item = nil then
        Break;
      Alternative.Add(Item);
    until False;
    if Alternative.Count = 0 then
    begin
      Alternative.Release;
      Items.Release;
      Exit;
    end;
    Exit(NewListOf(lsSlash, [Items, Alternative]));
  end;
  Result := Items;
end;

function ParseCounterList(var Cursor: TCssTokenCursor; DefaultValue: Integer): TCssValue;
var
  Name, Value: TCssValue;
begin
  Result := ParseKeyword(Cursor, [kwNone]);
  if Result <> nil then
    Exit;
  Result := NewList(lsSpace);
  repeat
    Name := ParseCustomIdent(Cursor, [kwNone]);
    if Name = nil then
      Break;
    Value := ParseInteger(Cursor);
    if Value = nil then
      Value := NewInteger(DefaultValue);
    Result.Add(NewListOf(lsSpace, [Name, Value]));
  until False;
  if Result.Count = 0 then
    ReleaseValue(Result);
end;

function ParseCounterReset(var Cursor: TCssTokenCursor): TCssValue;
begin
  Result := ParseCounterList(Cursor, 0);
end;

function ParseCounterIncrement(var Cursor: TCssTokenCursor): TCssValue;
begin
  Result := ParseCounterList(Cursor, 1);
end;

function ParseSingleTransitionProperty(var Cursor: TCssTokenCursor): TCssValue;
begin
  Result := ParseKeyword(Cursor, [kwAll]);
  if Result = nil then
    Result := ParseCustomIdent(Cursor, [kwNone]);
end;

function ParseTransitionProperty(var Cursor: TCssTokenCursor): TCssValue;
var
  Item: TCssValue;
begin
  Result := ParseKeyword(Cursor, [kwNone]);
  if Result <> nil then
    Exit;
  Result := NewList(lsComma);
  repeat
    Item := ParseSingleTransitionProperty(Cursor);
    if Item = nil then
    begin
      ReleaseValue(Result);
      Exit;
    end;
    Result.Add(Item);
  until not SkipComma(Cursor);
end;

function ParseEasing(var Cursor: TCssTokenCursor): TCssValue;
var
  Saved, Index: Integer;
  Token: PCssToken;
  Lower: string;
  Contents: TCssTokenCursor;
  Argument, Point: TCssValue;
begin
  Result := ParseKeyword(Cursor, [kwLinear, kwEase, kwEaseIn, kwEaseOut, kwEaseInOut, kwStepStart, kwStepEnd]);
  if Result <> nil then
    Exit;
  Saved := Cursor.Position;
  Cursor.SkipWhitespace;
  Token := Cursor.Peek;
  if Token^.Kind <> tkFunction then
    Exit;
  Lower := AsciiLowercase(Token^.Text);
  Cursor.Next;
  Contents := Cursor.Contents(Token);
  if Lower = 'cubic-bezier' then
  begin
    Result := NewFunction(Lower);
    for Index := 0 to 3 do
    begin
      if (Index > 0) and not SkipComma(Contents) then
      begin
        ReleaseValue(Result);
        Break;
      end;
      Argument := ParseNumber(Contents);
      { The x coordinates must lie in [0, 1]. }
      if (Argument = nil) or ((Index mod 2 = 0) and (Argument.Kind = vkNumber) and
        ((Argument.Number < 0) or (Argument.Number > 1))) then
      begin
        ReleaseValue(Argument);
        ReleaseValue(Result);
        Break;
      end;
      Result.Add(Argument);
    end;
  end
  else if Lower = 'steps' then
  begin
    Argument := ParseInteger(Contents, 1);
    if Argument <> nil then
    begin
      Result := NewFunction(Lower);
      Result.Add(Argument);
      if SkipComma(Contents) then
      begin
        Argument := ParseKeyword(Contents, [kwJumpStart, kwJumpEnd, kwJumpNone, kwJumpBoth, kwStart, kwEnd]);
        if Argument = nil then
          ReleaseValue(Result)
        else
          Result.Add(Argument);
      end;
    end;
  end
  else if Lower = 'linear' then
  begin
    Result := NewFunction(Lower);
    repeat
      Argument := ParseNumber(Contents);
      if Argument = nil then
      begin
        ReleaseValue(Result);
        Break;
      end;
      Point := NewListOf(lsSpace, [Argument]);
      for Index := 1 to 2 do
      begin
        Argument := ParsePercentage(Contents);
        if Argument = nil then
          Break;
        Point.Add(Argument);
      end;
      Result.Add(Point);
    until not SkipComma(Contents);
  end;
  if (Result <> nil) and not Contents.AtEndIgnoringWhitespace then
    ReleaseValue(Result);
  if Result = nil then
    Cursor.Position := Saved;
end;

function ParseEasingList(var Cursor: TCssTokenCursor): TCssValue;
var
  Item: TCssValue;
begin
  Result := NewList(lsComma);
  repeat
    Item := ParseEasing(Cursor);
    if Item = nil then
    begin
      ReleaseValue(Result);
      Exit;
    end;
    Result.Add(Item);
  until not SkipComma(Cursor);
end;

function ParseSingleAnimationName(var Cursor: TCssTokenCursor): TCssValue;
begin
  Result := ParseKeyword(Cursor, [kwNone]);
  if Result = nil then
    Result := ParseStringValue(Cursor);
  if Result = nil then
    Result := ParseCustomIdent(Cursor, [kwNone]);
end;

function ParseAnimationName(var Cursor: TCssTokenCursor): TCssValue;
var
  Item: TCssValue;
begin
  Result := NewList(lsComma);
  repeat
    Item := ParseSingleAnimationName(Cursor);
    if Item = nil then
    begin
      ReleaseValue(Result);
      Exit;
    end;
    Result.Add(Item);
  until not SkipComma(Cursor);
end;

end.
