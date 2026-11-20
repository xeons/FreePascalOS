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
  The table driven property value parser.

  A property's grammar (Css.PropertyTable) is compiled once into a list
  of alternatives: keywords, basic types ("<length-percentage+>" is a
  non-negative length or percentage), keyword sets (keywords in braces: one or
  more of them in any order, each once), optionally as a comma
  separated list ('#'). A grammar of the form "@name" names a parsing
  routine registered by the units that know the value's structure.
}
unit Css.Grammar;

{$mode objfpc}
{$H+}

interface

uses
  Css.Tokens, Css.Values, Css.PropertyIds;

type
  TCssValueRoutine = function(var Cursor: TCssTokenCursor): TCssValue;

procedure RegisterValueRoutine(const Name: string; Routine: TCssValueRoutine);
function FindValueRoutine(const Name: string): TCssValueRoutine;
{ The value of longhand Id filling Cursor's range (no CSS-wide keywords,
  no var()), or nil when it does not match the grammar. }
function ParseLonghandValue(Id: TCssPropertyId; Cursor: TCssTokenCursor): TCssValue;
{ One value of Id's grammar at the cursor, consumed (for shorthands,
  which find their longhands' values in sequence); nil if none. }
function ParseLonghandPart(Id: TCssPropertyId; var Cursor: TCssTokenCursor): TCssValue;

implementation

uses
  SysUtils, Css.Atoms, Css.Keywords, Css.Units, Css.ValueParser, Css.ColorParser, Css.Images,
  Css.PropertyTable;

type
  TGrammarType = (gtNone, gtLength, gtLengthNonNegative, gtPercentage, gtPercentageNonNegative,
    gtLengthPercentage, gtLengthPercentageNonNegative, gtNumber, gtNumberNonNegative, gtInteger,
    gtIntegerNonNegative, gtIntegerPositive, gtColor, gtAngle, gtTime, gtTimeNonNegative, gtString,
    gtUrl, gtImage, gtCustomIdent, gtLineWidth, gtFontWeight, gtAlpha, gtFlex);

  TTermKind = (tmKeyword, tmType, tmKeywordSet);

  TTerm = record
    Kind: TTermKind;
    Keyword: TCssKeyword;
    TypeOf: TGrammarType;
    KeywordSet: array of TCssKeyword;
  end;

  PCompiledGrammar = ^TCompiledGrammar;
  TCompiledGrammar = record
    IsList: Boolean;
    Routine: TCssValueRoutine;
    Terms: array of TTerm;
  end;

var
  RoutineNames: array of string;
  Routines: array of TCssValueRoutine;
  Compiled: array[TCssPropertyId] of PCompiledGrammar;

procedure RegisterValueRoutine(const Name: string; Routine: TCssValueRoutine);
begin
  SetLength(RoutineNames, Length(RoutineNames) + 1);
  SetLength(Routines, Length(Routines) + 1);
  RoutineNames[High(RoutineNames)] := Name;
  Routines[High(Routines)] := Routine;
end;

function FindValueRoutine(const Name: string): TCssValueRoutine;
var
  Index: Integer;
begin
  for Index := 0 to High(RoutineNames) do
    if RoutineNames[Index] = Name then
      Exit(Routines[Index]);
  Result := nil;
end;

function TypeByName(const Name: string): TGrammarType;
begin
  if Name = 'length' then Result := gtLength
  else if Name = 'length+' then Result := gtLengthNonNegative
  else if Name = 'percentage' then Result := gtPercentage
  else if Name = 'percentage+' then Result := gtPercentageNonNegative
  else if Name = 'length-percentage' then Result := gtLengthPercentage
  else if Name = 'length-percentage+' then Result := gtLengthPercentageNonNegative
  else if Name = 'number' then Result := gtNumber
  else if Name = 'number+' then Result := gtNumberNonNegative
  else if Name = 'integer' then Result := gtInteger
  else if Name = 'integer+' then Result := gtIntegerNonNegative
  else if Name = 'integer1' then Result := gtIntegerPositive
  else if Name = 'color' then Result := gtColor
  else if Name = 'angle' then Result := gtAngle
  else if Name = 'time' then Result := gtTime
  else if Name = 'time+' then Result := gtTimeNonNegative
  else if Name = 'string' then Result := gtString
  else if Name = 'url' then Result := gtUrl
  else if Name = 'image' then Result := gtImage
  else if Name = 'custom-ident' then Result := gtCustomIdent
  else if Name = 'line-width' then Result := gtLineWidth
  else if Name = 'font-weight' then Result := gtFontWeight
  else if Name = 'alpha' then Result := gtAlpha
  else if Name = 'flex' then Result := gtFlex
  else
    Result := gtNone;
end;

function KeywordByName(const Name: string): TCssKeyword;
begin
  Result := KeywordOfAtom(FindAtom(Name));
  if Result = kwInvalid then
    raise Exception.Create('libcss: unknown keyword in a property grammar: ' + Name);
end;

function Compile(const Grammar: string): PCompiledGrammar;
var
  Text, Word: string;
  Words: TStringArray;
  Index, SetIndex: Integer;
  Term: TTerm;
  InSet: Boolean;
begin
  New(Result);
  Result^.IsList := False;
  Result^.Routine := nil;
  Result^.Terms := nil;
  Text := Trim(Grammar);
  if Text = '' then
    Exit;
  if Text[1] = '@' then
  begin
    Result^.Routine := FindValueRoutine(Copy(Text, 2, Length(Text)));
    if not Assigned(Result^.Routine) then
      raise Exception.Create('libcss: no value routine ' + Text);
    Exit;
  end;
  if Text[1] = '#' then
  begin
    Result^.IsList := True;
    Delete(Text, 1, 1);
  end;
  Words := Text.Split([' ']);
  InSet := False;
  Term := Default(TTerm);
  for Index := 0 to High(Words) do
  begin
    Word := Words[Index];
    if (Word = '') or (Word = '|') then
      Continue;
    if Word[1] = '{' then
    begin
      InSet := True;
      Term := Default(TTerm);
      Term.Kind := tmKeywordSet;
      Delete(Word, 1, 1);
    end;
    if InSet then
    begin
      if (Word <> '') and (Word[Length(Word)] = '}') then
      begin
        SetLength(Word, Length(Word) - 1);
        InSet := False;
      end;
      if Word <> '' then
      begin
        SetIndex := Length(Term.KeywordSet);
        SetLength(Term.KeywordSet, SetIndex + 1);
        Term.KeywordSet[SetIndex] := KeywordByName(Word);
      end;
      if not InSet then
      begin
        SetLength(Result^.Terms, Length(Result^.Terms) + 1);
        Result^.Terms[High(Result^.Terms)] := Term;
      end;
      Continue;
    end;
    Term := Default(TTerm);
    if Word[1] = '<' then
    begin
      Term.Kind := tmType;
      Term.TypeOf := TypeByName(Copy(Word, 2, Length(Word) - 2));
      if Term.TypeOf = gtNone then
        raise Exception.Create('libcss: unknown type in a property grammar: ' + Word);
    end
    else
    begin
      Term.Kind := tmKeyword;
      Term.Keyword := KeywordByName(Word);
    end;
    SetLength(Result^.Terms, Length(Result^.Terms) + 1);
    Result^.Terms[High(Result^.Terms)] := Term;
  end;
end;

function GrammarOf(Id: TCssPropertyId): PCompiledGrammar;
begin
  if Compiled[Id] = nil then
    Compiled[Id] := Compile(PropertyTable[Id].Grammar);
  Result := Compiled[Id];
end;

function ParseType(var Cursor: TCssTokenCursor; TypeOf: TGrammarType): TCssValue;
var
  Saved: Integer;
begin
  case TypeOf of
    gtLength: Result := ParseLength(Cursor, False);
    gtLengthNonNegative: Result := ParseLength(Cursor, True);
    gtPercentage: Result := ParsePercentage(Cursor, False);
    gtPercentageNonNegative: Result := ParsePercentage(Cursor, True);
    gtLengthPercentage: Result := ParseLengthPercentage(Cursor, False);
    gtLengthPercentageNonNegative: Result := ParseLengthPercentage(Cursor, True);
    gtNumber: Result := ParseNumber(Cursor, False);
    gtNumberNonNegative: Result := ParseNumber(Cursor, True);
    gtInteger: Result := ParseInteger(Cursor);
    gtIntegerNonNegative: Result := ParseInteger(Cursor, 0);
    gtIntegerPositive: Result := ParseInteger(Cursor, 1);
    gtColor: Result := ParseColor(Cursor);
    gtAngle: Result := ParseAngle(Cursor, False);
    gtTime: Result := ParseTime(Cursor, False);
    gtTimeNonNegative: Result := ParseTime(Cursor, True);
    gtString: Result := ParseStringValue(Cursor);
    gtUrl: Result := ParseUrlValue(Cursor);
    gtImage: Result := ParseImage(Cursor);
    gtCustomIdent: Result := ParseCustomIdent(Cursor, []);
    gtLineWidth:
      begin
        Result := ParseKeyword(Cursor, [kwThin, kwMedium, kwThick]);
        if Result = nil then
          Result := ParseLength(Cursor, True);
      end;
    gtFontWeight:
      begin
        Saved := Cursor.Position;
        Result := ParseNumber(Cursor, True);
        if (Result <> nil) and (Result.Kind = vkNumber) and ((Result.Number < 1) or (Result.Number > 1000)) then
        begin
          ReleaseValue(Result);
          Cursor.Position := Saved;
        end;
      end;
    gtAlpha:
      begin
        Result := ParseNumber(Cursor, False);
        if Result = nil then
          Result := ParsePercentage(Cursor, False);
      end;
    gtFlex: Result := ParseDimension(Cursor, ucFlex, False, True, False);
  else
    Result := nil;
  end;
end;

function ParseKeywordSet(var Cursor: TCssTokenCursor; const Term: TTerm): TCssValue;
var
  Seen: array of Boolean;
  Keyword: TCssKeyword;
  Index, Found: Integer;
begin
  Result := NewList(lsSpace);
  SetLength(Seen, Length(Term.KeywordSet));
  repeat
    Keyword := PeekKeyword(Cursor);
    Found := -1;
    for Index := 0 to High(Term.KeywordSet) do
      if Term.KeywordSet[Index] = Keyword then
        Found := Index;
    if (Found < 0) or Seen[Found] then
      Break;
    Seen[Found] := True;
    Result.Add(ParseKeyword(Cursor, []));
  until False;
  if Result.Count = 0 then
    ReleaseValue(Result)
  else if Result.Count = 1 then
  begin
    Keyword := Result.Items[0].Keyword;
    Result.Release;
    Result := NewKeyword(Keyword);
  end;
end;

function ParseAlternatives(var Cursor: TCssTokenCursor; Grammar: PCompiledGrammar): TCssValue;
var
  Index: Integer;
  Term: ^TTerm;
  Keyword: TCssKeyword;
begin
  Result := nil;
  Keyword := PeekKeyword(Cursor);
  for Index := 0 to High(Grammar^.Terms) do
  begin
    Term := @Grammar^.Terms[Index];
    case Term^.Kind of
      tmKeyword:
        if (Keyword <> kwInvalid) and (Term^.Keyword = Keyword) then
          Result := ParseKeyword(Cursor, []);
      tmType: Result := ParseType(Cursor, Term^.TypeOf);
      tmKeywordSet: Result := ParseKeywordSet(Cursor, Term^);
    end;
    if Result <> nil then
      Exit;
  end;
end;

function ParseLonghandPart(Id: TCssPropertyId; var Cursor: TCssTokenCursor): TCssValue;
var
  Grammar: PCompiledGrammar;
  Item: TCssValue;
  Saved: Integer;
begin
  Grammar := GrammarOf(Id);
  Saved := Cursor.Position;
  if Assigned(Grammar^.Routine) then
    Result := Grammar^.Routine(Cursor)
  else if Grammar^.IsList then
  begin
    Result := NewList(lsComma);
    repeat
      Item := ParseAlternatives(Cursor, Grammar);
      if Item = nil then
      begin
        ReleaseValue(Result);
        Break;
      end;
      Result.Add(Item);
    until not SkipComma(Cursor);
  end
  else
    Result := ParseAlternatives(Cursor, Grammar);
  if Result = nil then
    Cursor.Position := Saved;
end;

function ParseLonghandValue(Id: TCssPropertyId; Cursor: TCssTokenCursor): TCssValue;
begin
  if not IsLonghand(Id) then
    Exit(nil);
  Result := ParseLonghandPart(Id, Cursor);
  if (Result <> nil) and not Cursor.AtEndIgnoringWhitespace then
    ReleaseValue(Result);
end;

procedure FreeCompiled;
var
  Id: TCssPropertyId;
begin
  for Id := Low(TCssPropertyId) to High(TCssPropertyId) do
    if Compiled[Id] <> nil then
    begin
      Dispose(Compiled[Id]);
      Compiled[Id] := nil;
    end;
end;

finalization
  FreeCompiled;
end.
