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
  Parsing style sheets (CSS Syntax Module Level 3, section 5, with the
  CSS Nesting changes): rules, at-rules and declaration blocks, with
  the spec's error recovery (a bad rule or declaration is skipped to
  its end and parsing goes on).

  Inside a style rule, declarations and nested rules mix: a run of
  "ident : ..." is tried as a declaration first and, if it is not one
  (it holds a block in braces among other things), re-read as a nested rule.
  Declarations after a nested rule become a nested declarations rule.
}
unit Css.Parser;

{$mode objfpc}
{$H+}

interface

uses
  Css.Tokens, Css.Declarations, Css.Stylesheets;

function ParseStyleSheet(const Source: string; Origin: TCssOrigin; const Href: string = ''): TCssStyleSheet;
{ CSSOM's "parse a CSS rule": exactly one rule in Source, else nil.
  The rule belongs to no sheet yet. }
function ParseSingleRule(const Source: string; Origin: TCssOrigin; const Href: string = ''): TCssRule;
{ A style attribute's (or any declaration list's) declarations. }
function ParseStyleAttribute(const Source: string): TCssDeclarationBlock;
{ Declarations from Cursor's range into Block (no nested rules). }
procedure ParseDeclarationsInto(Cursor: TCssTokenCursor; Block: TCssDeclarationBlock);

implementation

uses
  SysUtils, Css.Atoms, Css.Keywords, Css.Tokenizer, Css.Values, Css.ValueParser, Css.Selectors, Css.Properties,
  Css.SelectorParser, Css.MediaQueries, Css.Supports, Css.Serialization, Css.TextParsers, Css.Images;

type
  TPhase = (phImports, phNamespaces, phRules);

  TSheetParser = record
    Source: string;
    Sheet: TCssStyleSheet;
    Phase: TPhase;
  end;

  TBlockMode = (
    { a style rule's block: declarations and nested rules }
    bmStyle,
    { a group at the top level: rules only }
    bmRules,
    { a group inside a style rule: like a style rule's block }
    bmNestedGroup);

procedure ParseBlock(var Parser: TSheetParser; Cursor: TCssTokenCursor; Mode: TBlockMode;
  Owner: TCssGroupingRule; Declarations: TCssDeclarationBlock; StyleParent: TCssStyleRule); forward;

{ The source text of tokens [First, Stop). }
function RawText(const Parser: TSheetParser; Tokens: TCssTokenArray; First, Stop: Integer): string;
var
  StartOffset, EndOffset: Integer;
begin
  if First >= Stop then
    Exit('');
  StartOffset := Tokens[First].Position;
  if Stop < Length(Tokens) then
    EndOffset := Tokens[Stop].Position
  else
    EndOffset := Length(Parser.Source);
  Result := Trim(Copy(Parser.Source, StartOffset + 1, EndOffset - StartOffset));
end;

{ Moves past the end of the current construct: the next top level ';'
  (consumed) or the end of the range. }
procedure SkipToSemicolon(var Cursor: TCssTokenCursor);
var
  Token: PCssToken;
begin
  while not Cursor.AtEnd do
  begin
    Token := Cursor.Next;
    if Token^.Kind = tkSemicolon then
      Exit;
  end;
end;

{ Splits "value !important"; Value is the range without it. }
function StripImportant(var Value: TCssTokenCursor): Boolean;
var
  Last: Integer;
begin
  Result := False;
  Value := TrimRange(Value);
  Last := Value.Stop - 1;
  if (Last <= Value.Position) or (Value.Tokens[Last].Kind <> tkIdent) or
    not AsciiSameText(Value.Tokens[Last].Text, 'important') then
    Exit;
  Dec(Last);
  while (Last >= Value.Position) and (Value.Tokens[Last].Kind = tkWhitespace) do
    Dec(Last);
  if (Last < Value.Position) or (Value.Tokens[Last].Kind <> tkDelim) or (Value.Tokens[Last].Text <> '!') then
    Exit;
  Value.Stop := Last;
  Value := TrimRange(Value);
  Result := True;
end;

{ Tries "ident : value" up to the next top level ';' or the range's end.
  On success the declaration is added (if valid for its property) and
  the cursor is past it; on a syntax failure the cursor is unchanged. }
function TryDeclaration(var Cursor: TCssTokenCursor; Block: TCssDeclarationBlock; AllowImportant: Boolean): Boolean;
var
  Start, ValueStart: Integer;
  NameToken, Token: PCssToken;
  Value: TCssTokenCursor;
  Important, HasBlock, HasOther: Boolean;
  Name: string;
begin
  Result := False;
  Start := Cursor.Position;
  NameToken := Cursor.Next;
  if NameToken^.Kind <> tkIdent then
  begin
    Cursor.Position := Start;
    Exit;
  end;
  Name := NameToken^.Text;
  Cursor.SkipWhitespace;
  if Cursor.PeekKind <> tkColon then
  begin
    Cursor.Position := Start;
    Exit;
  end;
  Inc(Cursor.Position);
  ValueStart := Cursor.Position;
  HasBlock := False;
  HasOther := False;
  while not Cursor.AtEnd do
  begin
    Token := Cursor.Peek;
    if Token^.Kind = tkSemicolon then
      Break;
    if Token^.Kind = tkOpenCurly then
      HasBlock := True
    else if Token^.Kind <> tkWhitespace then
      HasOther := True;
    Cursor.Next;
  end;
  { A block in braces among other things means this was a nested rule. }
  if HasBlock and HasOther and not IsCustomPropertyName(Name) then
  begin
    Cursor.Position := Start;
    Exit;
  end;
  Value := TCssTokenCursor.CreateRange(Cursor.Tokens, ValueStart, Cursor.Position);
  if Cursor.PeekKind = tkSemicolon then
    Inc(Cursor.Position);
  Important := StripImportant(Value);
  if not (Important and not AllowImportant) then
    Block.AddParsed(Name, Value, Important);
  Result := True;
end;

procedure ParseDeclarationList(Cursor: TCssTokenCursor; Block: TCssDeclarationBlock; AllowImportant: Boolean);
begin
  while not Cursor.AtEnd do
  begin
    Cursor.SkipWhitespace;
    if Cursor.AtEnd then
      Break;
    if Cursor.PeekKind = tkSemicolon then
    begin
      Inc(Cursor.Position);
      Continue;
    end;
    if not TryDeclaration(Cursor, Block, AllowImportant) then
      SkipToSemicolon(Cursor);
  end;
end;

procedure ParseDeclarationsInto(Cursor: TCssTokenCursor; Block: TCssDeclarationBlock);
begin
  ParseDeclarationList(Cursor, Block, True);
end;

{ ---- qualified (style) rules ---- }

function SelectorContext(const Parser: TSheetParser; StyleParent: TCssStyleRule): TCssSelectorContext;
begin
  Result.Namespaces := Parser.Sheet.Namespaces;
  Result.Nested := StyleParent <> nil;
  if StyleParent <> nil then
    Result.NestingParent := StyleParent.Selectors
  else
    Result.NestingParent := nil;
end;

{ A qualified rule at the cursor: prelude up to a block in braces. Returns
  the rule or nil (the cursor is past what was consumed). }
function ParseStyleRule(var Parser: TSheetParser; var Cursor: TCssTokenCursor; StyleParent: TCssStyleRule;
  Owner: TCssGroupingRule): TCssStyleRule;
var
  PreludeStart: Integer;
  Token: PCssToken;
  Selectors: TCssSelectorList;
begin
  Result := nil;
  PreludeStart := Cursor.Position;
  repeat
    if Cursor.AtEnd then
      Exit;
    Token := Cursor.Peek;
    if Token^.Kind = tkOpenCurly then
      Break;
    if (Token^.Kind = tkSemicolon) and (StyleParent <> nil) then
    begin
      { A bad declaration inside a style rule. }
      Inc(Cursor.Position);
      Exit;
    end;
    Cursor.Next;
  until False;
  Cursor.Next;
  Selectors := ParseSelectorList(TCssTokenCursor.CreateRange(Cursor.Tokens, PreludeStart,
    Cursor.IndexOf(Token)), SelectorContext(Parser, StyleParent));
  if Selectors = nil then
    Exit;
  Result := TCssStyleRule.Create(rkStyle);
  Result.Selectors := Selectors;
  Result.Sheet := Parser.Sheet;
  if Owner <> nil then
    Owner.AddRule(Result);
  ParseBlock(Parser, Cursor.Contents(Token), bmStyle, Result, Result.Declarations, Result);
end;

{ ---- at-rules ---- }

function ParseLayerName(var Cursor: TCssTokenCursor; out Name: string): Boolean;
var
  Token: PCssToken;
begin
  Result := False;
  Name := '';
  Token := Cursor.NextNonWhitespace;
  if Token^.Kind <> tkIdent then
    Exit;
  Name := Token^.Text;
  while IsDelimToken(Cursor.Peek, '.') do
  begin
    Inc(Cursor.Position);
    Token := Cursor.Next;
    if Token^.Kind <> tkIdent then
      Exit;
    Name := Name + '.' + Token^.Text;
  end;
  Result := not CssWideKeyword(KeywordOfAtom(FindAtom(AsciiLowercase(Name))));
end;

function ParseImport(var Parser: TSheetParser; Prelude: TCssTokenCursor): TCssImportRule;
var
  Token: PCssToken;
  Url, LayerName: string;
  Contents: TCssTokenCursor;
  Lower: string;
  Matches: Boolean;
begin
  Result := nil;
  Token := Prelude.NextNonWhitespace;
  if Token^.Kind in [tkUrl, tkString] then
    Url := Token^.Text
  else if (Token^.Kind = tkFunction) and AsciiSameText(Token^.Text, 'url') then
  begin
    Contents := Prelude.Contents(Token);
    Token := Contents.NextNonWhitespace;
    if Token^.Kind <> tkString then
      Exit;
    Url := Token^.Text;
  end
  else
    Exit;
  Result := TCssImportRule.Create(rkImport);
  Result.Url := Url;
  Result.SupportsMatches := True;
  Prelude.SkipWhitespace;
  Token := Prelude.Peek;
  if (Token^.Kind = tkIdent) and AsciiSameText(Token^.Text, 'layer') then
  begin
    Inc(Prelude.Position);
    Result.HasLayer := True;
  end
  else if (Token^.Kind = tkFunction) and AsciiSameText(Token^.Text, 'layer') then
  begin
    Prelude.Next;
    Contents := Prelude.Contents(Token);
    if not ParseLayerName(Contents, LayerName) or not Contents.AtEndIgnoringWhitespace then
    begin
      FreeAndNil(Result);
      Exit;
    end;
    Result.HasLayer := True;
    Result.LayerName := LayerName;
  end;
  Prelude.SkipWhitespace;
  Token := Prelude.Peek;
  if Token^.Kind = tkFunction then
  begin
    Lower := AsciiLowercase(Token^.Text);
    if Lower = 'supports' then
    begin
      Prelude.Next;
      Contents := Prelude.Contents(Token);
      if not ParseSupportsCondition(Contents, Matches) then
      begin
        { supports(declaration) without parentheses around it. }
        Matches := SupportsConditionText('(' + SerializeTokens(Contents) + ')');
      end;
      Result.SupportsText := SerializeTokens(Contents);
      Result.SupportsMatches := Matches;
    end;
  end;
  Result.Media := ParseMediaQueryList(TCssTokenCursor.CreateRange(Prelude.Tokens, Prelude.Position, Prelude.Stop));
end;

function ParseNamespace(var Parser: TSheetParser; Prelude: TCssTokenCursor): TCssNamespaceRule;
var
  Token: PCssToken;
  Prefix: string;
  Contents: TCssTokenCursor;
begin
  Result := nil;
  Prefix := '';
  Token := Prelude.NextNonWhitespace;
  if Token^.Kind = tkIdent then
  begin
    Prefix := Token^.Text;
    Token := Prelude.NextNonWhitespace;
  end;
  Result := TCssNamespaceRule.Create(rkNamespace);
  Result.Prefix := Prefix;
  if Token^.Kind in [tkUrl, tkString] then
    Result.Uri := Token^.Text
  else if (Token^.Kind = tkFunction) and AsciiSameText(Token^.Text, 'url') then
  begin
    Contents := Prelude.Contents(Token);
    Token := Contents.NextNonWhitespace;
    if Token^.Kind = tkString then
      Result.Uri := Token^.Text
    else
      FreeAndNil(Result);
  end
  else
    FreeAndNil(Result);
  if (Result <> nil) and not Prelude.AtEndIgnoringWhitespace then
    FreeAndNil(Result);
  if Result <> nil then
    Parser.Sheet.Namespaces.Declare(InternAtom(Prefix), InternAtom(Result.Uri));
end;

function HexValue(Character: Char): Integer;
begin
  case Character of
    '0'..'9': Result := Ord(Character) - Ord('0');
    'a'..'f': Result := Ord(Character) - Ord('a') + 10;
    'A'..'F': Result := Ord(Character) - Ord('A') + 10;
  else
    Result := -1;
  end;
end;

{ "U+0-7F, U+4??" }
procedure ParseUnicodeRanges(Rule: TCssFontFaceRule; const Text: string);
var
  Pieces: TStringArray;
  Index, Position, Digits: Integer;
  Piece: string;
  First, Last: LongWord;
  Wildcards: Integer;
  Range: TCssUnicodeRange;
begin
  Pieces := Text.Split([',']);
  for Index := 0 to High(Pieces) do
  begin
    Piece := Trim(Pieces[Index]);
    if (Length(Piece) < 3) or not (Piece[1] in ['u', 'U']) or (Piece[2] <> '+') then
      Continue;
    Position := 3;
    First := 0;
    Digits := 0;
    Wildcards := 0;
    while (Position <= Length(Piece)) and (HexValue(Piece[Position]) >= 0) and (Digits < 6) do
    begin
      First := First * 16 + LongWord(HexValue(Piece[Position]));
      Inc(Position);
      Inc(Digits);
    end;
    while (Position <= Length(Piece)) and (Piece[Position] = '?') and (Digits < 6) do
    begin
      First := First * 16;
      Inc(Wildcards);
      Inc(Position);
      Inc(Digits);
    end;
    if Digits = 0 then
      Continue;
    Last := First;
    if Wildcards > 0 then
      Last := First + (LongWord(1) shl (4 * Wildcards)) - 1
    else if (Position <= Length(Piece)) and (Piece[Position] = '-') then
    begin
      Inc(Position);
      Last := 0;
      Digits := 0;
      while (Position <= Length(Piece)) and (HexValue(Piece[Position]) >= 0) and (Digits < 6) do
      begin
        Last := Last * 16 + LongWord(HexValue(Piece[Position]));
        Inc(Position);
        Inc(Digits);
      end;
      if Digits = 0 then
        Continue;
    end;
    if (Position <= Length(Piece)) or (Last < First) or (Last > $10FFFF) then
      Continue;
    Range.First := First;
    Range.Last := Last;
    SetLength(Rule.UnicodeRanges, Length(Rule.UnicodeRanges) + 1);
    Rule.UnicodeRanges[High(Rule.UnicodeRanges)] := Range;
  end;
end;

{ src: a comma separated list of url() format() tech() or local(). }
function ParseFontSources(var Cursor: TCssTokenCursor): TCssValue;
var
  Pieces: TCssTokenCursorArray;
  Index: Integer;
  Item: TCssValue;
begin
  Result := NewList(lsComma);
  Pieces := SplitAtCommas(Cursor);
  for Index := 0 to High(Pieces) do
  begin
    Item := ParseGenericValue(Pieces[Index]);
    if (Item = nil) or not Pieces[Index].AtEndIgnoringWhitespace then
    begin
      ReleaseValue(Item);
      ReleaseValue(Result);
      Exit;
    end;
    Result.Add(Item);
  end;
  Cursor.Position := Cursor.Stop;
end;

function ParseFontFace(var Parser: TSheetParser; Block: TCssTokenCursor): TCssFontFaceRule;
var
  Token: PCssToken;
  Name: string;
  ValueStart: Integer;
  Value: TCssTokenCursor;
  Descriptor: TCssDescriptor;
begin
  Result := TCssFontFaceRule.Create(rkFontFace);
  while not Block.AtEnd do
  begin
    Block.SkipWhitespace;
    if Block.AtEnd then
      Break;
    Token := Block.Next;
    if Token^.Kind <> tkIdent then
    begin
      SkipToSemicolon(Block);
      Continue;
    end;
    Name := AsciiLowercase(Token^.Text);
    Block.SkipWhitespace;
    if Block.PeekKind <> tkColon then
    begin
      SkipToSemicolon(Block);
      Continue;
    end;
    Inc(Block.Position);
    ValueStart := Block.Position;
    while not Block.AtEnd and (Block.PeekKind <> tkSemicolon) do
      Block.Next;
    Value := TrimRange(TCssTokenCursor.CreateRange(Block.Tokens, ValueStart, Block.Position));
    if Block.PeekKind = tkSemicolon then
      Inc(Block.Position);
    Descriptor.Name := Name;
    Descriptor.Text := RawText(Parser, Value.Tokens, Value.Position, Value.Stop);
    if Name = 'font-family' then
      Descriptor.Value := ParseFamilyName(Value)
    else if Name = 'unicode-range' then
    begin
      Descriptor.Value := nil;
      ParseUnicodeRanges(Result, Descriptor.Text);
    end
    else if Name = 'src' then
      Descriptor.Value := ParseFontSources(Value)
    else
      Descriptor.Value := ParseGenericValue(Value);
    if (Descriptor.Value <> nil) and not Value.AtEndIgnoringWhitespace then
      ReleaseValue(Descriptor.Value);
    if (Descriptor.Value = nil) and (Name = 'font-family') then
      Continue;
    SetLength(Result.Descriptors, Length(Result.Descriptors) + 1);
    Result.Descriptors[High(Result.Descriptors)] := Descriptor;
  end;
end;

function ParseKeyframeSelectors(Prelude: TCssTokenCursor; Rule: TCssKeyframeRule): Boolean;
var
  Token: PCssToken;
  Offset: Double;
begin
  Result := False;
  repeat
    Token := Prelude.NextNonWhitespace;
    if (Token^.Kind = tkIdent) and AsciiSameText(Token^.Text, 'from') then
      Offset := 0
    else if (Token^.Kind = tkIdent) and AsciiSameText(Token^.Text, 'to') then
      Offset := 1
    else if (Token^.Kind = tkPercentage) and (Token^.Number >= 0) and (Token^.Number <= 100) then
      Offset := Token^.Number / 100
    else
      Exit;
    SetLength(Rule.Offsets, Length(Rule.Offsets) + 1);
    Rule.Offsets[High(Rule.Offsets)] := Offset;
  until not SkipComma(Prelude);
  Result := Prelude.AtEndIgnoringWhitespace;
end;

function ParseKeyframes(var Parser: TSheetParser; Prelude, Block: TCssTokenCursor): TCssKeyframesRule;
var
  Token: PCssToken;
  PreludeStart: Integer;
  Keyframe: TCssKeyframeRule;
begin
  Result := nil;
  Token := Prelude.NextNonWhitespace;
  if not (Token^.Kind in [tkIdent, tkString]) or not Prelude.AtEndIgnoringWhitespace then
    Exit;
  if (Token^.Kind = tkIdent) and (CssWideKeyword(KeywordOfAtom(FindAtom(AsciiLowercase(Token^.Text)))) or
    AsciiSameText(Token^.Text, 'none')) then
    Exit;
  Result := TCssKeyframesRule.Create(rkKeyframes);
  Result.Sheet := Parser.Sheet;
  Result.Name := Token^.Text;
  while not Block.AtEnd do
  begin
    Block.SkipWhitespace;
    if Block.AtEnd then
      Break;
    PreludeStart := Block.Position;
    while not Block.AtEnd and (Block.PeekKind <> tkOpenCurly) do
      Block.Next;
    if Block.AtEnd then
      Break;
    Token := Block.Next;
    Keyframe := TCssKeyframeRule.Create(rkKeyframe);
    Keyframe.Declarations := TCssDeclarationBlock.Create;
    if ParseKeyframeSelectors(TCssTokenCursor.CreateRange(Block.Tokens, PreludeStart, Block.IndexOf(Token)),
      Keyframe) then
    begin
      { !important is ignored in keyframes: such declarations are dropped. }
      ParseDeclarationList(Block.Contents(Token), Keyframe.Declarations, False);
      Result.AddRule(Keyframe);
    end
    else
      Keyframe.Free;
  end;
end;

function ParsePropertyRule(var Parser: TSheetParser; Prelude, Block: TCssTokenCursor): TCssPropertyRule;
var
  Token: PCssToken;
  Name: string;
  ValueStart: Integer;
  Value: TCssTokenCursor;
begin
  Result := nil;
  Token := Prelude.NextNonWhitespace;
  if (Token^.Kind <> tkIdent) or not IsCustomPropertyName(Token^.Text) or
    not Prelude.AtEndIgnoringWhitespace then
    Exit;
  Result := TCssPropertyRule.Create(rkProperty);
  Result.Name := Token^.Text;
  Result.Inherits := True;
  while not Block.AtEnd do
  begin
    Token := Block.NextNonWhitespace;
    if Token^.Kind = tkEof then
      Break;
    if Token^.Kind <> tkIdent then
    begin
      SkipToSemicolon(Block);
      Continue;
    end;
    Name := AsciiLowercase(Token^.Text);
    Block.SkipWhitespace;
    if Block.PeekKind <> tkColon then
    begin
      SkipToSemicolon(Block);
      Continue;
    end;
    Inc(Block.Position);
    ValueStart := Block.Position;
    while not Block.AtEnd and (Block.PeekKind <> tkSemicolon) do
      Block.Next;
    Value := TrimRange(TCssTokenCursor.CreateRange(Block.Tokens, ValueStart, Block.Position));
    if Block.PeekKind = tkSemicolon then
      Inc(Block.Position);
    if (Name = 'syntax') and (Value.PeekKind = tkString) then
      Result.Syntax := Value.Peek^.Text
    else if Name = 'inherits' then
    begin
      Result.HasInherits := True;
      Result.Inherits := Value.IsIdent('true');
    end
    else if Name = 'initial-value' then
    begin
      Result.HasInitialValue := True;
      Result.InitialValue := CopyTokens(Value.Tokens, Value.Position, Value.Stop);
    end;
  end;
  { syntax and inherits are required. }
  if (Result.Syntax = '') or not Result.HasInherits then
    FreeAndNil(Result);
end;

function ParsePage(var Parser: TSheetParser; Prelude, Block: TCssTokenCursor): TCssPageRule;
begin
  Result := TCssPageRule.Create(rkPage);
  Result.SelectorText := SerializeTokens(Prelude);
  Result.Declarations := TCssDeclarationBlock.Create;
  ParseDeclarationsInto(Block, Result.Declarations);
end;

function ParseContainer(var Parser: TSheetParser; Prelude: TCssTokenCursor; Rule: TCssContainerRule): Boolean;
var
  Token: PCssToken;
  Keyword: TCssKeyword;
  Saved: Integer;
begin
  Prelude.SkipWhitespace;
  Token := Prelude.Peek;
  Saved := Prelude.Position;
  if Token^.Kind = tkIdent then
  begin
    Keyword := KeywordOfAtom(FindAtom(AsciiLowercase(Token^.Text)));
    if not KeywordIn(Keyword, [kwNot, kwAnd, kwOr, kwNone]) then
    begin
      Rule.Name := Token^.Text;
      Inc(Prelude.Position);
      if Prelude.AtEndIgnoringWhitespace then
      begin
        Prelude.Position := Saved;
        Rule.Name := '';
      end;
    end;
  end;
  Rule.Condition := ParseMediaCondition(Prelude, True);
  Result := (Rule.Condition <> nil) and Prelude.AtEndIgnoringWhitespace;
end;

{ An at-rule at the cursor (an at-keyword token). }
procedure ParseAtRule(var Parser: TSheetParser; var Cursor: TCssTokenCursor; Owner: TCssGroupingRule;
  StyleParent: TCssStyleRule; Mode: TBlockMode);
var
  NameToken, Token, BlockToken: PCssToken;
  Name: string;
  PreludeStart, PreludeStop: Integer;
  Prelude, Block: TCssTokenCursor;
  HasBlock: Boolean;
  Rule: TCssRule;
  Group: TCssGroupingRule;
  LayerName: string;
  Matches: Boolean;
  Statement: TCssLayerStatementRule;
  Nested: Boolean;
begin
  NameToken := Cursor.Next;
  Name := AsciiLowercase(NameToken^.Text);
  PreludeStart := Cursor.Position;
  PreludeStop := -1;
  HasBlock := False;
  BlockToken := nil;
  repeat
    if Cursor.AtEnd then
    begin
      PreludeStop := Cursor.Position;
      Break;
    end;
    Token := Cursor.Peek;
    if Token^.Kind = tkSemicolon then
    begin
      PreludeStop := Cursor.Position;
      Inc(Cursor.Position);
      Break;
    end;
    if Token^.Kind = tkOpenCurly then
    begin
      PreludeStop := Cursor.Position;
      BlockToken := Cursor.Next;
      HasBlock := True;
      Break;
    end;
    Cursor.Next;
  until False;
  Prelude := TCssTokenCursor.CreateRange(Cursor.Tokens, PreludeStart, PreludeStop);
  if HasBlock then
    Block := Cursor.Contents(BlockToken);
  Nested := StyleParent <> nil;
  Rule := nil;
  if Name = 'charset' then
    Exit;
  if (Name = 'import') and not HasBlock and not Nested and (Owner = nil) then
  begin
    if Parser.Phase = phImports then
      Rule := ParseImport(Parser, Prelude);
  end
  else if (Name = 'namespace') and not HasBlock and not Nested and (Owner = nil) then
  begin
    if Parser.Phase <= phNamespaces then
    begin
      Rule := ParseNamespace(Parser, Prelude);
      Parser.Phase := phNamespaces;
    end;
  end
  else if (Name = 'layer') and not HasBlock then
  begin
    { @layer a, b.c; }
    Statement := TCssLayerStatementRule.Create(rkLayerStatement);
    repeat
      if not ParseLayerName(Prelude, LayerName) then
      begin
        FreeAndNil(Statement);
        Break;
      end;
      SetLength(Statement.Names, Length(Statement.Names) + 1);
      Statement.Names[High(Statement.Names)] := LayerName;
    until not SkipComma(Prelude);
    if (Statement <> nil) and not Prelude.AtEndIgnoringWhitespace then
      FreeAndNil(Statement);
    if Nested then
      FreeAndNil(Statement);
    Rule := Statement;
    if (Rule <> nil) and (Owner = nil) and (Parser.Phase = phImports) then
    begin
      { A layer statement may come before @import. }
      Parser.Sheet.AddRule(Rule);
      Exit;
    end;
  end
  else if HasBlock and ((Name = 'media') or (Name = 'supports') or (Name = 'container') or (Name = 'layer')) then
  begin
    Group := nil;
    if Name = 'media' then
    begin
      Group := TCssMediaRule.Create(rkMedia);
      TCssMediaRule(Group).Media := ParseMediaQueryList(Prelude);
    end
    else if Name = 'supports' then
    begin
      if ParseSupportsCondition(Prelude, Matches) then
      begin
        Group := TCssSupportsRule.Create(rkSupports);
        TCssSupportsRule(Group).ConditionText := SerializeTokens(Prelude);
        TCssSupportsRule(Group).Matches := Matches;
      end;
    end
    else if Name = 'container' then
    begin
      Group := TCssContainerRule.Create(rkContainer);
      if not ParseContainer(Parser, Prelude, TCssContainerRule(Group)) then
        FreeAndNil(Group);
    end
    else
    begin
      LayerName := '';
      if Prelude.AtEndIgnoringWhitespace or ParseLayerName(Prelude, LayerName) then
      begin
        if Prelude.AtEndIgnoringWhitespace then
        begin
          Group := TCssLayerBlockRule.Create(rkLayerBlock);
          TCssLayerBlockRule(Group).Name := LayerName;
        end;
      end;
    end;
    if Group = nil then
      Exit;
    Group.Sheet := Parser.Sheet;
    if Nested then
      ParseBlock(Parser, Block, bmNestedGroup, Group, nil, StyleParent)
    else
      ParseBlock(Parser, Block, bmRules, Group, nil, nil);
    Rule := Group;
  end
  else if HasBlock and not Nested and (Name = 'font-face') then
    Rule := ParseFontFace(Parser, Block)
  else if HasBlock and not Nested and ((Name = 'keyframes') or (Name = '-webkit-keyframes')) then
    Rule := ParseKeyframes(Parser, Prelude, Block)
  else if HasBlock and not Nested and (Name = 'page') then
    Rule := ParsePage(Parser, Prelude, Block)
  else if HasBlock and not Nested and (Name = 'property') then
    Rule := ParsePropertyRule(Parser, Prelude, Block);
  if Rule = nil then
    Exit;
  if not ((Rule.Kind = rkImport) or (Rule.Kind = rkNamespace)) and (Owner = nil) then
    Parser.Phase := phRules;
  if Owner <> nil then
    Owner.AddRule(Rule)
  else
    Parser.Sheet.AddRule(Rule);
end;

{ ---- blocks ---- }

procedure ParseBlock(var Parser: TSheetParser; Cursor: TCssTokenCursor; Mode: TBlockMode;
  Owner: TCssGroupingRule; Declarations: TCssDeclarationBlock; StyleParent: TCssStyleRule);
var
  Token: PCssToken;
  Target: TCssDeclarationBlock;
  Pending: TCssStyleRule;
  SawRule: Boolean;

  { A nested declarations rule not added yet is dropped; the next
    declarations start a new one. }
  procedure EndRun;
  begin
    if (Pending <> nil) and (Pending.Parent = nil) then
      Pending.Free;
    Pending := nil;
  end;

begin
  SawRule := False;
  Pending := nil;
  while not Cursor.AtEnd do
  begin
    Token := Cursor.Peek;
    case Token^.Kind of
      tkWhitespace, tkSemicolon:
        begin
          Inc(Cursor.Position);
          Continue;
        end;
      tkCdo, tkCdc:
        if Mode = bmRules then
        begin
          Inc(Cursor.Position);
          Continue;
        end;
      tkAtKeyword:
        begin
          if Mode = bmRules then
            ParseAtRule(Parser, Cursor, Owner, nil, Mode)
          else
            ParseAtRule(Parser, Cursor, Owner, StyleParent, Mode);
          SawRule := True;
          EndRun;
          Continue;
        end;
    end;
    if Mode <> bmRules then
    begin
      { Declarations go to the rule itself until a nested rule comes;
        after one, to a nested declarations rule. }
      if SawRule or (Declarations = nil) then
      begin
        if Pending = nil then
        begin
          Pending := TCssStyleRule.Create(rkNestedDeclarations);
          Pending.Sheet := Parser.Sheet;
        end;
        Target := Pending.Declarations;
      end
      else
        Target := Declarations;
      if TryDeclaration(Cursor, Target, True) then
      begin
        if (Pending <> nil) and (Pending.Parent = nil) and (Pending.Declarations.Count > 0) then
          Owner.AddRule(Pending);
        Continue;
      end;
    end;
    ParseStyleRule(Parser, Cursor, StyleParent, Owner);
    if Mode <> bmRules then
    begin
      SawRule := True;
      EndRun;
    end;
  end;
  EndRun;
end;

function ParseStyleSheet(const Source: string; Origin: TCssOrigin; const Href: string): TCssStyleSheet;
var
  Parser: TSheetParser;
  Tokens: TCssTokenArray;
  Cursor: TCssTokenCursor;
  Token: PCssToken;
  Rule: TCssStyleRule;
begin
  Parser.Source := PreprocessCss(Source);
  Parser.Sheet := TCssStyleSheet.Create(Origin);
  Parser.Sheet.Href := Href;
  Parser.Phase := phImports;
  Tokens := TokenizeCss(Parser.Source);
  Cursor := TCssTokenCursor.Create(Tokens);
  while not Cursor.AtEnd do
  begin
    Token := Cursor.Peek;
    case Token^.Kind of
      tkWhitespace, tkCdo, tkCdc:
        Inc(Cursor.Position);
      tkAtKeyword:
        ParseAtRule(Parser, Cursor, nil, nil, bmRules);
    else
      begin
        Rule := ParseStyleRule(Parser, Cursor, nil, nil);
        if Rule <> nil then
        begin
          Parser.Phase := phRules;
          Parser.Sheet.AddRule(Rule);
        end;
      end;
    end;
  end;
  Result := Parser.Sheet;
end;

function ParseSingleRule(const Source: string; Origin: TCssOrigin; const Href: string): TCssRule;
var
  Sheet: TCssStyleSheet;
begin
  Result := nil;
  Sheet := ParseStyleSheet(Source, Origin, Href);
  try
    if Length(Sheet.Rules) = 1 then
    begin
      Result := Sheet.Rules[0];
      Sheet.Rules := nil;
      SetRuleSheet(Result, nil);
    end;
  finally
    Sheet.Free;
  end;
end;

function ParseStyleAttribute(const Source: string): TCssDeclarationBlock;
begin
  Result := TCssDeclarationBlock.Create;
  ParseDeclarationsInto(TCssTokenCursor.Create(TokenizeCss(Source)), Result);
end;

end.
