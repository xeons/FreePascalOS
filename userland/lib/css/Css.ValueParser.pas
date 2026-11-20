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
  Parsing the basic value types from tokens: numbers, integers,
  dimensions of each kind (lengths, angles, times, ...), percentages,
  keywords, identifiers, strings and URLs, with math functions wherever
  a number or dimension may stand.

  Every parser skips whitespace first, consumes what it parsed and
  returns a new value; on failure it consumes nothing and returns nil.
}
unit Css.ValueParser;

{$mode objfpc}
{$H+}

interface

uses
  Css.Tokens, Css.Units, Css.Keywords, Css.Values;

{ A dimension of Category (or a percentage when AllowPercentage; a
  unitless 0 for lengths, and for angles when AllowUnitlessZero). }
function ParseDimension(var Cursor: TCssTokenCursor; Category: TCssUnitCategory; AllowPercentage,
  NonNegative: Boolean; AllowUnitlessZero: Boolean = True): TCssValue;
function ParseLength(var Cursor: TCssTokenCursor; NonNegative: Boolean = False): TCssValue;
function ParseLengthPercentage(var Cursor: TCssTokenCursor; NonNegative: Boolean = False): TCssValue;
function ParsePercentage(var Cursor: TCssTokenCursor; NonNegative: Boolean = False): TCssValue;
function ParseNumber(var Cursor: TCssTokenCursor; NonNegative: Boolean = False): TCssValue;
{ An integer of at least Minimum. }
function ParseInteger(var Cursor: TCssTokenCursor; Minimum: Integer = Low(Integer)): TCssValue;
function ParseAngle(var Cursor: TCssTokenCursor; AllowUnitlessZero: Boolean = False): TCssValue;
function ParseTime(var Cursor: TCssTokenCursor; NonNegative: Boolean = False): TCssValue;
{ One of Allowed (any keyword when Allowed is empty). }
function ParseKeyword(var Cursor: TCssTokenCursor; const Allowed: array of TCssKeyword): TCssValue;
{ A keyword at the cursor without consuming it (kwInvalid if none). }
function PeekKeyword(var Cursor: TCssTokenCursor): TCssKeyword;
{ A <custom-ident>: not a CSS-wide keyword, not 'default', not one of Excluded. }
function ParseCustomIdent(var Cursor: TCssTokenCursor; const Excluded: array of TCssKeyword): TCssValue;
function ParseStringValue(var Cursor: TCssTokenCursor): TCssValue;
function ParseUrlValue(var Cursor: TCssTokenCursor): TCssValue;
{ Any run of component values as a generic value: numbers, dimensions,
  identifiers (keywords where known), strings, URLs, colors, math and
  other functions (arguments split at commas). nil if something has no
  value form (a bad token or block). }
function ParseGenericValue(var Cursor: TCssTokenCursor): TCssValue;
{ Whether a token is the delimiter Character. }
function IsDelimToken(Token: PCssToken; const Character: string): Boolean; inline;
{ Consumes a comma (and whitespace before it) if there is one. }
function SkipComma(var Cursor: TCssTokenCursor): Boolean;
function SkipDelim(var Cursor: TCssTokenCursor; const Character: string): Boolean;

implementation

uses
  Css.Atoms, Css.Calc, Css.Colors, Css.ColorParser;

function IsDelimToken(Token: PCssToken; const Character: string): Boolean;
begin
  Result := (Token^.Kind = tkDelim) and (Token^.Text = Character);
end;

function SkipComma(var Cursor: TCssTokenCursor): Boolean;
var
  Saved: Integer;
begin
  Saved := Cursor.Position;
  Cursor.SkipWhitespace;
  Result := Cursor.PeekKind = tkComma;
  if Result then
    Inc(Cursor.Position)
  else
    Cursor.Position := Saved;
end;

function SkipDelim(var Cursor: TCssTokenCursor; const Character: string): Boolean;
var
  Saved: Integer;
begin
  Saved := Cursor.Position;
  Cursor.SkipWhitespace;
  Result := IsDelimToken(Cursor.Peek, Character);
  if Result then
    Inc(Cursor.Position)
  else
    Cursor.Position := Saved;
end;

function ParseMath(var Cursor: TCssTokenCursor; Expected, PercentAs: TCssUnitCategory): TCssValue;
var
  Node: TCssCalcNode;
begin
  Node := ParseMathFunction(Cursor, Expected, PercentAs);
  if Node = nil then
    Result := nil
  else
    Result := NewCalc(Node);
end;

function ParseDimension(var Cursor: TCssTokenCursor; Category: TCssUnitCategory; AllowPercentage,
  NonNegative: Boolean; AllowUnitlessZero: Boolean): TCssValue;
var
  Saved: Integer;
  Token: PCssToken;
  UnitValue: TCssUnit;
  PercentAs: TCssUnitCategory;
begin
  Result := nil;
  Saved := Cursor.Position;
  Cursor.SkipWhitespace;
  Token := Cursor.Peek;
  case Token^.Kind of
    tkDimension:
      begin
        UnitValue := UnitByName(Token^.Text);
        if (UnitValue <> cuNone) and (UnitCategory(UnitValue) = Category) and
          not (NonNegative and (Token^.Number < 0)) then
        begin
          Inc(Cursor.Position);
          Exit(NewDimension(Token^.Number, UnitValue));
        end;
      end;
    tkPercentage:
      if AllowPercentage and not (NonNegative and (Token^.Number < 0)) then
      begin
        Inc(Cursor.Position);
        Exit(NewPercentage(Token^.Number));
      end;
    tkNumber:
      if (Token^.Number = 0) and AllowUnitlessZero and (Category in [ucLength, ucAngle]) then
      begin
        Inc(Cursor.Position);
        Exit(NewDimension(0, CanonicalUnit(Category)));
      end;
    tkFunction:
      begin
        if AllowPercentage then
          PercentAs := Category
        else
          PercentAs := ucNumber;
        Result := ParseMath(Cursor, Category, PercentAs);
        if Result <> nil then
          Exit;
      end;
  end;
  Cursor.Position := Saved;
end;

function ParseLength(var Cursor: TCssTokenCursor; NonNegative: Boolean): TCssValue;
begin
  Result := ParseDimension(Cursor, ucLength, False, NonNegative);
end;

function ParseLengthPercentage(var Cursor: TCssTokenCursor; NonNegative: Boolean): TCssValue;
begin
  Result := ParseDimension(Cursor, ucLength, True, NonNegative);
end;

function ParsePercentage(var Cursor: TCssTokenCursor; NonNegative: Boolean): TCssValue;
var
  Saved: Integer;
  Token: PCssToken;
begin
  Saved := Cursor.Position;
  Cursor.SkipWhitespace;
  Token := Cursor.Peek;
  if (Token^.Kind = tkPercentage) and not (NonNegative and (Token^.Number < 0)) then
  begin
    Inc(Cursor.Position);
    Exit(NewPercentage(Token^.Number));
  end;
  if Token^.Kind = tkFunction then
  begin
    Result := ParseMath(Cursor, ucPercent, ucPercent);
    if Result <> nil then
      Exit;
  end;
  Cursor.Position := Saved;
  Result := nil;
end;

function ParseNumber(var Cursor: TCssTokenCursor; NonNegative: Boolean): TCssValue;
var
  Saved: Integer;
  Token: PCssToken;
begin
  Saved := Cursor.Position;
  Cursor.SkipWhitespace;
  Token := Cursor.Peek;
  if (Token^.Kind = tkNumber) and not (NonNegative and (Token^.Number < 0)) then
  begin
    Inc(Cursor.Position);
    Exit(NewNumber(Token^.Number));
  end;
  if Token^.Kind = tkFunction then
  begin
    Result := ParseMath(Cursor, ucNumber, ucNumber);
    if Result <> nil then
      Exit;
  end;
  Cursor.Position := Saved;
  Result := nil;
end;

function ParseInteger(var Cursor: TCssTokenCursor; Minimum: Integer): TCssValue;
var
  Saved: Integer;
  Token: PCssToken;
begin
  Saved := Cursor.Position;
  Cursor.SkipWhitespace;
  Token := Cursor.Peek;
  if (Token^.Kind = tkNumber) and (tfInteger in Token^.Flags) and (Token^.Number >= Minimum) and
    (Token^.Number <= High(Integer)) then
  begin
    Inc(Cursor.Position);
    Exit(NewInteger(Trunc(Token^.Number)));
  end;
  if Token^.Kind = tkFunction then
  begin
    Result := ParseMath(Cursor, ucNumber, ucNumber);
    if Result <> nil then
      Exit;
  end;
  Cursor.Position := Saved;
  Result := nil;
end;

function ParseAngle(var Cursor: TCssTokenCursor; AllowUnitlessZero: Boolean): TCssValue;
begin
  Result := ParseDimension(Cursor, ucAngle, False, False, AllowUnitlessZero);
end;

function ParseTime(var Cursor: TCssTokenCursor; NonNegative: Boolean): TCssValue;
begin
  Result := ParseDimension(Cursor, ucTime, False, NonNegative, False);
end;

function PeekKeyword(var Cursor: TCssTokenCursor): TCssKeyword;
var
  Saved: Integer;
  Token: PCssToken;
begin
  Saved := Cursor.Position;
  Cursor.SkipWhitespace;
  Token := Cursor.Peek;
  Cursor.Position := Saved;
  if Token^.Kind <> tkIdent then
    Exit(kwInvalid);
  Result := KeywordOfAtom(FindAtom(AsciiLowercase(Token^.Text)));
end;

function ParseKeyword(var Cursor: TCssTokenCursor; const Allowed: array of TCssKeyword): TCssValue;
var
  Keyword: TCssKeyword;
begin
  Result := nil;
  Keyword := PeekKeyword(Cursor);
  if Keyword = kwInvalid then
    Exit;
  if (Length(Allowed) > 0) and not KeywordIn(Keyword, Allowed) then
    Exit;
  Cursor.SkipWhitespace;
  Inc(Cursor.Position);
  Result := NewKeyword(Keyword);
end;

function ParseCustomIdent(var Cursor: TCssTokenCursor; const Excluded: array of TCssKeyword): TCssValue;
var
  Saved: Integer;
  Token: PCssToken;
  Keyword: TCssKeyword;
begin
  Result := nil;
  Saved := Cursor.Position;
  Cursor.SkipWhitespace;
  Token := Cursor.Peek;
  if Token^.Kind = tkIdent then
  begin
    Keyword := KeywordOfAtom(FindAtom(AsciiLowercase(Token^.Text)));
    if not (CssWideKeyword(Keyword) or (Keyword = kwDefault) or
      ((Keyword <> kwInvalid) and KeywordIn(Keyword, Excluded))) then
    begin
      Inc(Cursor.Position);
      Exit(NewCustomIdent(Token^.Text));
    end;
  end;
  Cursor.Position := Saved;
end;

function ParseStringValue(var Cursor: TCssTokenCursor): TCssValue;
var
  Saved: Integer;
begin
  Saved := Cursor.Position;
  Cursor.SkipWhitespace;
  if Cursor.PeekKind = tkString then
    Exit(NewString(Cursor.Next^.Text));
  Cursor.Position := Saved;
  Result := nil;
end;

function ParseUrlValue(var Cursor: TCssTokenCursor): TCssValue;
var
  Saved: Integer;
  Token: PCssToken;
  Contents: TCssTokenCursor;
  Argument: PCssToken;
begin
  Result := nil;
  Saved := Cursor.Position;
  Cursor.SkipWhitespace;
  Token := Cursor.Peek;
  if Token^.Kind = tkUrl then
  begin
    Inc(Cursor.Position);
    Exit(NewUrl(Token^.Text));
  end;
  if (Token^.Kind = tkFunction) and (AsciiSameText(Token^.Text, 'url') or AsciiSameText(Token^.Text, 'src')) then
  begin
    Cursor.Next;
    Contents := Cursor.Contents(Token);
    Argument := Contents.NextNonWhitespace;
    { url("...") with modifiers is not supported: they would be dropped. }
    if (Argument^.Kind = tkString) and Contents.AtEndIgnoringWhitespace then
      Exit(NewUrl(Argument^.Text));
  end;
  Cursor.Position := Saved;
end;

function ParseGenericValue(var Cursor: TCssTokenCursor): TCssValue;
var
  Items: TCssValue;
  Token: PCssToken;
  Item, Argument: TCssValue;
  Contents, Part: TCssTokenCursor;
  UnitValue: TCssUnit;
  Keyword: TCssKeyword;
  Start, Saved: Integer;
  Finished: Boolean;
  Category: TCssUnitCategory;
begin
  Result := nil;
  Items := NewList(lsSpace);
  try
    repeat
      Cursor.SkipWhitespace;
      if Cursor.AtEnd then
        Break;
      Token := Cursor.Peek;
      Item := nil;
      case Token^.Kind of
        tkNumber:
          begin
            Inc(Cursor.Position);
            if tfInteger in Token^.Flags then
              Item := NewInteger(Trunc(Token^.Number))
            else
              Item := NewNumber(Token^.Number);
          end;
        tkPercentage:
          begin
            Inc(Cursor.Position);
            Item := NewPercentage(Token^.Number);
          end;
        tkDimension:
          begin
            UnitValue := UnitByName(Token^.Text);
            if UnitValue = cuNone then
              Exit;
            Inc(Cursor.Position);
            Item := NewDimension(Token^.Number, UnitValue);
          end;
        tkIdent:
          begin
            Item := ParseColor(Cursor);
            if Item = nil then
            begin
              Inc(Cursor.Position);
              Keyword := KeywordOfAtom(FindAtom(AsciiLowercase(Token^.Text)));
              if Keyword <> kwInvalid then
                Item := NewKeyword(Keyword)
              else
                Item := NewCustomIdent(Token^.Text);
            end;
          end;
        tkString:
          begin
            Inc(Cursor.Position);
            Item := NewString(Token^.Text);
          end;
        tkUrl:
          Item := ParseUrlValue(Cursor);
        tkHash:
          begin
            Item := ParseColor(Cursor);
            if Item = nil then
              Exit;
          end;
        tkDelim:
          if Token^.Text = '/' then
          begin
            Inc(Cursor.Position);
            Item := NewCustomIdent('/');
          end
          else
            Exit;
        tkComma:
          begin
            Inc(Cursor.Position);
            Item := NewCustomIdent(',');
          end;
        tkFunction:
          begin
            Saved := Cursor.Position;
            if IsMathFunction(Token^.Text) then
              for Category := Low(TCssUnitCategory) to High(TCssUnitCategory) do
              begin
                if Category = ucPercent then
                  Item := ParseMath(Cursor, Category, ucPercent)
                else
                  Item := ParseMath(Cursor, Category, Category);
                if Item <> nil then
                  Break;
              end;
            if Item = nil then
            begin
              Cursor.Position := Saved;
              Item := ParseColor(Cursor);
            end;
            if Item = nil then
            begin
              Cursor.Position := Saved;
              Item := ParseUrlValue(Cursor);
            end;
            if Item = nil then
            begin
              { Any other function: comma separated arguments. }
              Cursor.Position := Saved;
              Cursor.Next;
              Contents := Cursor.Contents(Token);
              Item := NewFunction(AsciiLowercase(Token^.Text));
              Start := Contents.Position;
              repeat
                Finished := Contents.AtEnd;
                if not Finished then
                  if Contents.Next^.Kind <> tkComma then
                    Continue;
                if Finished then
                  Part := TCssTokenCursor.CreateRange(Contents.Tokens, Start, Contents.Stop)
                else
                  Part := TCssTokenCursor.CreateRange(Contents.Tokens, Start, Contents.Position - 1);
                if not Part.AtEndIgnoringWhitespace then
                begin
                  Argument := ParseGenericValue(Part);
                  if Argument = nil then
                  begin
                    Item.Release;
                    Exit;
                  end;
                  Item.Add(Argument);
                end;
                Start := Contents.Position;
              until Finished;
            end;
          end;
      else
        Exit;
      end;
      if Item = nil then
        Exit;
      Items.Add(Item);
    until False;
    if Items.Count = 1 then
    begin
      Result := Items.Items[0].AddRef;
      Exit;
    end;
    Result := Items.AddRef;
  finally
    Items.Release;
  end;
end;

end.
