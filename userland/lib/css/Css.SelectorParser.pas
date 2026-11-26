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
  Parsing selectors (Selectors Level 4 section 18 grammar, CSS Nesting
  for nested rules) from a range of tokens.

  Top level lists and :not are unforgiving (one bad selector makes the
  list invalid); :is and :where are forgiving (bad entries are dropped);
  :has takes relative selectors. A nested rule's selectors that start
  with a combinator, or have no '&' anywhere, are taken relative to the
  parent: "& " (or "& >", ...) goes in front.
}
unit Css.SelectorParser;

{$mode objfpc}
{$H+}

interface

uses
  Css.Atoms, Css.Tokens, Css.Selectors;

type
  { The namespace prefixes a style sheet declared (@namespace). }
  TCssNamespaces = class
  public
    Prefixes: array of TCssAtom;
    Uris: array of TCssAtom;
    { The default namespace, NoAtom when none was declared. }
    DefaultNamespace: TCssAtom;
    procedure Declare(Prefix, Uri: TCssAtom);
    function Resolve(Prefix: TCssAtom; out Uri: TCssAtom): Boolean;
  end;

  TCssSelectorContext = record
    Namespaces: TCssNamespaces;
    { The enclosing style rule's selectors for a nested rule, else nil. }
    NestingParent: TCssSelectorList;
    { Whether the selectors belong to a nested rule (relative to '&'). }
    Nested: Boolean;
  end;

{ The selectors of Cursor's whole range, or nil when they are invalid. }
function ParseSelectorList(Cursor: TCssTokenCursor; const Context: TCssSelectorContext): TCssSelectorList;
{ The same from text (for tests, @supports selector(), host queries). }
function ParseSelectorText(const Text: string; Namespaces: TCssNamespaces = nil): TCssSelectorList;
function ParseAnPlusBText(const Text: string; out A, B: Integer): Boolean;

implementation

uses
  SysUtils, Css.Tokenizer;

type
  TListMode = (lmUnforgiving, lmForgiving, lmRelative);

  TSelectorParser = record
    Context: TCssSelectorContext;
    { Inside :is/:where/:not/:has, where pseudo-elements are not allowed. }
    Depth: Integer;
  end;

function ParseList(var Parser: TSelectorParser; Cursor: TCssTokenCursor; Mode: TListMode): TCssSelectorList; forward;

procedure TCssNamespaces.Declare(Prefix, Uri: TCssAtom);
var
  Index: Integer;
begin
  if Prefix = NoAtom then
  begin
    DefaultNamespace := Uri;
    Exit;
  end;
  for Index := 0 to High(Prefixes) do
    if Prefixes[Index] = Prefix then
    begin
      Uris[Index] := Uri;
      Exit;
    end;
  SetLength(Prefixes, Length(Prefixes) + 1);
  SetLength(Uris, Length(Uris) + 1);
  Prefixes[High(Prefixes)] := Prefix;
  Uris[High(Uris)] := Uri;
end;

function TCssNamespaces.Resolve(Prefix: TCssAtom; out Uri: TCssAtom): Boolean;
var
  Index: Integer;
begin
  Uri := NoAtom;
  for Index := 0 to High(Prefixes) do
    if Prefixes[Index] = Prefix then
    begin
      Uri := Uris[Index];
      Exit(True);
    end;
  Result := False;
end;

function IsDelim(Token: PCssToken; const Character: string): Boolean; inline;
begin
  Result := (Token^.Kind = tkDelim) and (Token^.Text = Character);
end;

procedure AddSimple(var Compound: TCssCompoundSelector; const Simple: TCssSimpleSelector);
begin
  SetLength(Compound.Simples, Length(Compound.Simples) + 1);
  Compound.Simples[High(Compound.Simples)] := Simple;
end;

procedure ClearSimple(out Simple: TCssSimpleSelector);
begin
  Simple := Default(TCssSimpleSelector);
end;

procedure FreeCompound(var Compound: TCssCompoundSelector);
var
  Index: Integer;
begin
  for Index := 0 to High(Compound.Simples) do
    FreeAndNil(Compound.Simples[Index].Arguments);
  Compound.Simples := nil;
end;

{ A namespace prefix: "ns|", "*|" or "|" followed by a name or '*'.
  Returns False (consuming nothing) when there is none. }
function TryNamespacePrefix(var Parser: TSelectorParser; var Cursor: TCssTokenCursor;
  var Simple: TCssSimpleSelector; out Invalid: Boolean): Boolean;
var
  First, Second, Third: PCssToken;
  Start: Integer;
  Uri: TCssAtom;
begin
  Result := False;
  Invalid := False;
  Start := Cursor.Position;
  First := Cursor.Peek;
  if IsDelim(First, '|') then
  begin
    Second := @EofToken;
    if Cursor.Position + 1 < Cursor.Stop then
      Second := @Cursor.Tokens[Cursor.Position + 1];
    if (Second^.Kind = tkIdent) or IsDelim(Second, '*') then
    begin
      Simple.NamespaceKind := nkNone;
      Inc(Cursor.Position);
      Exit(True);
    end;
    Exit;
  end;
  if not ((First^.Kind = tkIdent) or IsDelim(First, '*')) then
    Exit;
  if Cursor.Position + 2 >= Cursor.Stop + 1 then
    Exit;
  if Cursor.Position + 1 >= Cursor.Stop then
    Exit;
  Second := @Cursor.Tokens[Cursor.Position + 1];
  if not IsDelim(Second, '|') then
    Exit;
  if Cursor.Position + 2 >= Cursor.Stop then
    Exit;
  Third := @Cursor.Tokens[Cursor.Position + 2];
  if not ((Third^.Kind = tkIdent) or IsDelim(Third, '*')) then
    Exit;
  if IsDelim(First, '*') then
    Simple.NamespaceKind := nkAny
  else
  begin
    if (Parser.Context.Namespaces = nil) or
      not Parser.Context.Namespaces.Resolve(InternAtom(First^.Text), Uri) then
    begin
      Invalid := True;
      Cursor.Position := Start;
      Exit;
    end;
    Simple.NamespaceKind := nkSpecific;
    Simple.Namespace := Uri;
    Simple.NamespacePrefix := InternAtom(First^.Text);
  end;
  Inc(Cursor.Position, 2);
  Result := True;
end;

function ParseAnPlusBText(const Text: string; out A, B: Integer): Boolean;
var
  Position, Sign, Value: Integer;
  HasDigits: Boolean;
  Source: string;

  function ReadDigits(out Digits: Integer): Boolean;
  begin
    Digits := 0;
    Result := False;
    while (Position <= Length(Source)) and (Source[Position] in ['0'..'9']) do
    begin
      if Digits < 100000000 then
        Digits := Digits * 10 + (Ord(Source[Position]) - Ord('0'));
      Inc(Position);
      Result := True;
    end;
  end;

  procedure SkipSpaces;
  begin
    while (Position <= Length(Source)) and (Source[Position] = ' ') do
      Inc(Position);
  end;

begin
  A := 0;
  B := 0;
  Result := False;
  Source := Trim(Text);
  if Source = 'odd' then
  begin
    A := 2;
    B := 1;
    Exit(True);
  end;
  if Source = 'even' then
  begin
    A := 2;
    Exit(True);
  end;
  Position := 1;
  Sign := 1;
  if (Position <= Length(Source)) and (Source[Position] in ['+', '-']) then
  begin
    if Source[Position] = '-' then
      Sign := -1;
    Inc(Position);
    if (Position <= Length(Source)) and (Source[Position] = ' ') then
      Exit;
  end;
  HasDigits := ReadDigits(Value);
  if (Position <= Length(Source)) and (Source[Position] = 'n') then
  begin
    if HasDigits then
      A := Sign * Value
    else
      A := Sign;
    Inc(Position);
    SkipSpaces;
    if Position > Length(Source) then
      Exit(True);
    if not (Source[Position] in ['+', '-']) then
      Exit;
    if Source[Position] = '-' then
      Sign := -1
    else
      Sign := 1;
    Inc(Position);
    SkipSpaces;
    if not ReadDigits(Value) then
      Exit;
    B := Sign * Value;
    SkipSpaces;
    Result := Position > Length(Source);
  end
  else
  begin
    if not HasDigits then
      Exit;
    B := Sign * Value;
    Result := Position > Length(Source);
  end;
end;

{ The An+B tokens of Cursor up to an "of" (left at the cursor). }
function ParseAnPlusB(var Cursor: TCssTokenCursor; out A, B: Integer): Boolean;
var
  Text: string;
  Token: PCssToken;
begin
  Text := '';
  Result := False;
  while not Cursor.AtEnd do
  begin
    Token := Cursor.Peek;
    if (Token^.Kind = tkIdent) and AsciiSameText(Token^.Text, 'of') then
      Break;
    case Token^.Kind of
      tkWhitespace: Text := Text + ' ';
      tkIdent: Text := Text + AsciiLowercase(Token^.Text);
      tkNumber, tkDimension:
        begin
          if not (tfInteger in Token^.Flags) then
            Exit;
          if (tfSigned in Token^.Flags) and (Token^.Number >= 0) then
            Text := Text + '+';
          Text := Text + IntToStr(Trunc(Token^.Number));
          if Token^.Kind = tkDimension then
            Text := Text + AsciiLowercase(Token^.Text);
        end;
      tkDelim:
        if (Token^.Text = '+') or (Token^.Text = '-') then
          Text := Text + Token^.Text
        else
          Exit;
    else
      Exit;
    end;
    Inc(Cursor.Position);
  end;
  Result := ParseAnPlusBText(Text, A, B);
end;

{ One compound selector as a whole argument (:host(), :host-context(),
  ::slotted()). }
function ParseCompoundArgument(var Parser: TSelectorParser; Arguments: TCssTokenCursor): TCssSelectorList;
begin
  Inc(Parser.Depth);
  Result := ParseList(Parser, Arguments, lmUnforgiving);
  Dec(Parser.Depth);
  if (Result <> nil) and ((Result.Count <> 1) or (Length(Result.Items[0].Compounds) <> 1)) then
    FreeAndNil(Result);
end;

function ParsePseudoClassFunction(var Parser: TSelectorParser; Token: PCssToken; Arguments: TCssTokenCursor;
  var Simple: TCssSimpleSelector): Boolean;
var
  A, B: Integer;
  Item: PCssToken;
begin
  Result := False;
  Simple.PseudoClass := PseudoClassByName(AsciiLowercase(Token^.Text));
  case Simple.PseudoClass of
    pcIs, pcWhere:
      begin
        Inc(Parser.Depth);
        Simple.Arguments := ParseList(Parser, Arguments, lmForgiving);
        Dec(Parser.Depth);
        Result := Simple.Arguments <> nil;
      end;
    pcNot:
      begin
        Inc(Parser.Depth);
        Simple.Arguments := ParseList(Parser, Arguments, lmUnforgiving);
        Dec(Parser.Depth);
        Result := Simple.Arguments <> nil;
      end;
    pcHas:
      begin
        Inc(Parser.Depth);
        Simple.Arguments := ParseList(Parser, Arguments, lmRelative);
        Dec(Parser.Depth);
        Result := Simple.Arguments <> nil;
      end;
    pcNthChild, pcNthLastChild, pcNthOfType, pcNthLastOfType:
      begin
        if not ParseAnPlusB(Arguments, A, B) then
          Exit;
        Simple.NthA := A;
        Simple.NthB := B;
        if not Arguments.AtEnd then
        begin
          { "of S" only for :nth-child and :nth-last-child. }
          if Simple.PseudoClass in [pcNthOfType, pcNthLastOfType] then
            Exit;
          Inc(Arguments.Position);
          if Arguments.PeekKind <> tkWhitespace then
            Exit;
          Inc(Parser.Depth);
          Simple.Arguments := ParseList(Parser, Arguments, lmUnforgiving);
          Dec(Parser.Depth);
          if Simple.Arguments = nil then
            Exit;
        end;
        Result := True;
      end;
    pcLang:
      begin
        repeat
          Item := Arguments.NextNonWhitespace;
          if not (Item^.Kind in [tkIdent, tkString]) then
            Exit;
          SetLength(Simple.Languages, Length(Simple.Languages) + 1);
          Simple.Languages[High(Simple.Languages)] := Item^.Text;
          Item := Arguments.NextNonWhitespace;
          if Item^.Kind = tkEof then
            Break;
          if Item^.Kind <> tkComma then
            Exit;
        until False;
        Result := Length(Simple.Languages) > 0;
      end;
    pcDir:
      begin
        Item := Arguments.NextNonWhitespace;
        if (Item^.Kind <> tkIdent) or not Arguments.AtEndIgnoringWhitespace then
          Exit;
        Simple.Value := AsciiLowercase(Item^.Text);
        Result := (Simple.Value = 'ltr') or (Simple.Value = 'rtl');
      end;
    pcHost, pcHostContext:
      begin
        Simple.Arguments := ParseCompoundArgument(Parser, Arguments);
        Result := Simple.Arguments <> nil;
      end;
    pcState:
      begin
        Item := Arguments.NextNonWhitespace;
        if (Item^.Kind <> tkIdent) or not Arguments.AtEndIgnoringWhitespace then
          Exit;
        Simple.Value := Item^.Text;
        Result := True;
      end;
  end;
end;

{ ::slotted(compound) and ::part(ident+). }
function ParsePseudoElementFunction(var Parser: TSelectorParser; Token: PCssToken; Arguments: TCssTokenCursor;
  var Simple: TCssSimpleSelector): Boolean;
var
  Item: PCssToken;
begin
  Result := False;
  Simple.PseudoElement := PseudoElementByName(AsciiLowercase(Token^.Text));
  case Simple.PseudoElement of
    peSlotted:
      begin
        Simple.Arguments := ParseCompoundArgument(Parser, Arguments);
        Result := Simple.Arguments <> nil;
      end;
    pePart:
      begin
        repeat
          Item := Arguments.NextNonWhitespace;
          if Item^.Kind = tkEof then
            Break;
          if Item^.Kind <> tkIdent then
            Exit;
          SetLength(Simple.Languages, Length(Simple.Languages) + 1);
          Simple.Languages[High(Simple.Languages)] := Item^.Text;
        until False;
        Result := Length(Simple.Languages) > 0;
      end;
  end;
end;

function ParseAttribute(var Parser: TSelectorParser; Contents: TCssTokenCursor;
  var Simple: TCssSimpleSelector): Boolean;
var
  Token, Next: PCssToken;
  Invalid: Boolean;
  Modifier: string;
begin
  Result := False;
  Simple.Kind := skAttribute;
  Contents.SkipWhitespace;
  if TryNamespacePrefix(Parser, Contents, Simple, Invalid) then
  begin
    if IsDelim(Contents.Peek, '*') then
      Exit;
  end
  else if Invalid then
    Exit;
  Token := Contents.Next;
  if Token^.Kind <> tkIdent then
    Exit;
  Simple.Name := InternAtom(Token^.Text);
  Simple.LowerName := LowercaseAtom(Simple.Name);
  Contents.SkipWhitespace;
  if Contents.AtEnd then
  begin
    Simple.AttributeOperator := aoExists;
    Exit(True);
  end;
  Token := Contents.Next;
  if Token^.Kind <> tkDelim then
    Exit;
  if Token^.Text = '=' then
    Simple.AttributeOperator := aoEquals
  else
  begin
    Next := Contents.Peek;
    if not IsDelim(Next, '=') then
      Exit;
    Inc(Contents.Position);
    if Token^.Text = '~' then Simple.AttributeOperator := aoIncludes
    else if Token^.Text = '|' then Simple.AttributeOperator := aoDashMatch
    else if Token^.Text = '^' then Simple.AttributeOperator := aoPrefix
    else if Token^.Text = '$' then Simple.AttributeOperator := aoSuffix
    else if Token^.Text = '*' then Simple.AttributeOperator := aoSubstring
    else
      Exit;
  end;
  Token := Contents.NextNonWhitespace;
  if not (Token^.Kind in [tkIdent, tkString]) then
    Exit;
  Simple.Value := Token^.Text;
  Contents.SkipWhitespace;
  if not Contents.AtEnd then
  begin
    Token := Contents.Next;
    if Token^.Kind <> tkIdent then
      Exit;
    Modifier := AsciiLowercase(Token^.Text);
    if Modifier = 'i' then
      Simple.AttributeCase := acInsensitive
    else if Modifier = 's' then
      Simple.AttributeCase := acSensitive
    else
      Exit;
    if not Contents.AtEndIgnoringWhitespace then
      Exit;
  end;
  Result := True;
end;

{ One compound selector at the cursor; False if there is none or it is invalid. }
function ParseCompound(var Parser: TSelectorParser; var Cursor: TCssTokenCursor;
  out Compound: TCssCompoundSelector; out Invalid: Boolean): Boolean;
var
  Simple: TCssSimpleSelector;
  Token, NameToken: PCssToken;
  HasPrefix, AfterPseudoElement: Boolean;
  LowerName: string;
  Legacy: TCssPseudoElement;
begin
  Compound := Default(TCssCompoundSelector);
  Invalid := False;
  Result := False;
  AfterPseudoElement := False;
  ClearSimple(Simple);
  { The type selector, possibly with a namespace prefix. }
  HasPrefix := TryNamespacePrefix(Parser, Cursor, Simple, Invalid);
  if Invalid then
    Exit;
  Token := Cursor.Peek;
  if (Token^.Kind = tkIdent) or IsDelim(Token, '*') then
  begin
    Inc(Cursor.Position);
    if Token^.Kind = tkIdent then
    begin
      Simple.Kind := skType;
      Simple.Name := InternAtom(Token^.Text);
      Simple.LowerName := LowercaseAtom(Simple.Name);
    end
    else
      Simple.Kind := skUniversal;
    if (not HasPrefix) and (Parser.Context.Namespaces <> nil) then
      Simple.Namespace := Parser.Context.Namespaces.DefaultNamespace;
    AddSimple(Compound, Simple);
  end
  else if HasPrefix then
  begin
    Invalid := True;
    Exit;
  end;
  { Subclass selectors, pseudo-elements and the pseudo-classes after them. }
  repeat
    Token := Cursor.Peek;
    ClearSimple(Simple);
    if (Token^.Kind = tkHash) and not AfterPseudoElement then
    begin
      if not (tfIdHash in Token^.Flags) then
      begin
        Invalid := True;
        Break;
      end;
      Inc(Cursor.Position);
      Simple.Kind := skId;
      Simple.Name := InternAtom(Token^.Text);
      Simple.LowerName := LowercaseAtom(Simple.Name);
      AddSimple(Compound, Simple);
    end
    else if IsDelim(Token, '.') and not AfterPseudoElement then
    begin
      Inc(Cursor.Position);
      NameToken := Cursor.Peek;
      if NameToken^.Kind <> tkIdent then
      begin
        Invalid := True;
        Break;
      end;
      Inc(Cursor.Position);
      Simple.Kind := skClass;
      Simple.Name := InternAtom(NameToken^.Text);
      Simple.LowerName := LowercaseAtom(Simple.Name);
      AddSimple(Compound, Simple);
    end
    else if (Token^.Kind = tkOpenSquare) and not AfterPseudoElement then
    begin
      Cursor.Next;
      if not ParseAttribute(Parser, Cursor.Contents(Token), Simple) then
      begin
        FreeAndNil(Simple.Arguments);
        Invalid := True;
        Break;
      end;
      AddSimple(Compound, Simple);
    end
    else if IsDelim(Token, '&') and not AfterPseudoElement then
    begin
      Inc(Cursor.Position);
      Simple.Kind := skNesting;
      Simple.NestingParent := Parser.Context.NestingParent;
      AddSimple(Compound, Simple);
    end
    else if Token^.Kind = tkColon then
    begin
      Inc(Cursor.Position);
      NameToken := Cursor.Peek;
      if NameToken^.Kind = tkColon then
      begin
        { A pseudo-element. }
        Inc(Cursor.Position);
        NameToken := Cursor.Next;
        if (NameToken^.Kind = tkFunction) and (Parser.Depth = 0) and not AfterPseudoElement then
        begin
          Simple.Kind := skPseudoElement;
          if not ParsePseudoElementFunction(Parser, NameToken, Cursor.Contents(NameToken), Simple) then
          begin
            FreeAndNil(Simple.Arguments);
            Invalid := True;
            Break;
          end;
          AddSimple(Compound, Simple);
          AfterPseudoElement := True;
          Continue;
        end;
        if (NameToken^.Kind <> tkIdent) or (Parser.Depth > 0) or AfterPseudoElement then
        begin
          Invalid := True;
          Break;
        end;
        Simple.Kind := skPseudoElement;
        Simple.PseudoElement := PseudoElementByName(AsciiLowercase(NameToken^.Text));
        if Simple.PseudoElement in [peNone, peSlotted, pePart] then
        begin
          Invalid := True;
          Break;
        end;
        if Simple.PseudoElement = peUnknownPrefixed then
          Simple.Value := AsciiLowercase(NameToken^.Text);
        AddSimple(Compound, Simple);
        AfterPseudoElement := True;
      end
      else if NameToken^.Kind = tkIdent then
      begin
        Inc(Cursor.Position);
        LowerName := AsciiLowercase(NameToken^.Text);
        Legacy := peNone;
        if (LowerName = 'before') then Legacy := peBefore
        else if (LowerName = 'after') then Legacy := peAfter
        else if (LowerName = 'first-line') then Legacy := peFirstLine
        else if (LowerName = 'first-letter') then Legacy := peFirstLetter;
        if Legacy <> peNone then
        begin
          if (Parser.Depth > 0) or AfterPseudoElement then
          begin
            Invalid := True;
            Break;
          end;
          Simple.Kind := skPseudoElement;
          Simple.PseudoElement := Legacy;
          AfterPseudoElement := True;
        end
        else
        begin
          Simple.Kind := skPseudoClass;
          Simple.PseudoClass := PseudoClassByName(LowerName);
          if (Simple.PseudoClass = pcNone) or
            (Simple.PseudoClass in [pcIs, pcWhere, pcNot, pcHas, pcNthChild, pcNthLastChild,
            pcNthOfType, pcNthLastOfType, pcLang, pcDir, pcHostContext, pcState]) then
          begin
            Invalid := True;
            Break;
          end;
          { After a pseudo-element only user action states may follow. }
          if AfterPseudoElement and not (Simple.PseudoClass in [pcHover, pcActive, pcFocus,
            pcFocusVisible, pcFocusWithin]) then
          begin
            Invalid := True;
            Break;
          end;
        end;
        AddSimple(Compound, Simple);
      end
      else if NameToken^.Kind = tkFunction then
      begin
        Cursor.Next;
        Simple.Kind := skPseudoClass;
        if AfterPseudoElement or
          not ParsePseudoClassFunction(Parser, NameToken, Cursor.Contents(NameToken), Simple) then
        begin
          FreeAndNil(Simple.Arguments);
          Invalid := True;
          Break;
        end;
        AddSimple(Compound, Simple);
      end
      else
      begin
        Invalid := True;
        Break;
      end;
    end
    else
      Break;
  until False;
  if Invalid then
  begin
    FreeCompound(Compound);
    Exit;
  end;
  Result := Length(Compound.Simples) > 0;
end;

function CompoundHasPseudoElement(const Compound: TCssCompoundSelector): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to High(Compound.Simples) do
    if Compound.Simples[Index].Kind = skPseudoElement then
      Exit(True);
  Result := False;
end;

{ A combinator at the cursor (whitespace around it consumed); cmNone at the end. }
function ParseCombinator(var Cursor: TCssTokenCursor; out Combinator: TCssCombinator): Boolean;
var
  SawWhitespace: Boolean;
  Token: PCssToken;
begin
  SawWhitespace := Cursor.PeekKind = tkWhitespace;
  Cursor.SkipWhitespace;
  Combinator := cmNone;
  Result := True;
  if Cursor.AtEnd then
    Exit;
  Token := Cursor.Peek;
  if IsDelim(Token, '>') then
    Combinator := cmChild
  else if IsDelim(Token, '+') then
    Combinator := cmNextSibling
  else if IsDelim(Token, '~') then
    Combinator := cmSubsequentSibling
  else if SawWhitespace then
  begin
    Combinator := cmDescendant;
    Exit;
  end
  else
    Exit(False);
  Inc(Cursor.Position);
  Cursor.SkipWhitespace;
end;

function SelectorContainsNesting(Selector: TCssComplexSelector): Boolean; forward;

function ListContainsNesting(List: TCssSelectorList): Boolean;
var
  Index: Integer;
begin
  Result := False;
  if List <> nil then
    for Index := 0 to High(List.Items) do
      if SelectorContainsNesting(List.Items[Index]) then
        Exit(True);
end;

function SelectorContainsNesting(Selector: TCssComplexSelector): Boolean;
var
  CompoundIndex, SimpleIndex: Integer;
  Simple: ^TCssSimpleSelector;
begin
  for CompoundIndex := 0 to High(Selector.Compounds) do
    for SimpleIndex := 0 to High(Selector.Compounds[CompoundIndex].Simples) do
    begin
      Simple := @Selector.Compounds[CompoundIndex].Simples[SimpleIndex];
      if Simple^.Kind = skNesting then
        Exit(True);
      if ListContainsNesting(Simple^.Arguments) then
        Exit(True);
    end;
  Result := False;
end;

function MakeSingleSimpleCompound(Kind: TCssSimpleKind; NestingParent: TCssSelectorList;
  Combinator: TCssCombinator): TCssCompoundSelector;
var
  Simple: TCssSimpleSelector;
begin
  Result := Default(TCssCompoundSelector);
  ClearSimple(Simple);
  Simple.Kind := Kind;
  Simple.NestingParent := NestingParent;
  AddSimple(Result, Simple);
  Result.Combinator := Combinator;
end;

{ One complex (or relative) selector filling Cursor's range. }
function ParseComplex(var Parser: TSelectorParser; Cursor: TCssTokenCursor; Relative, NestedRule: Boolean): TCssComplexSelector;
var
  LeftToRight: array of TCssCompoundSelector;
  Combinators: array of TCssCombinator;
  Compound: TCssCompoundSelector;
  Combinator, Leading: TCssCombinator;
  Invalid, Failed: Boolean;
  Count, Index: Integer;
  Token: PCssToken;
begin
  Result := nil;
  LeftToRight := nil;
  Combinators := nil;
  Count := 0;
  Failed := False;
  Cursor.SkipWhitespace;
  Leading := cmNone;
  if Relative or NestedRule then
  begin
    Token := Cursor.Peek;
    if IsDelim(Token, '>') then Leading := cmChild
    else if IsDelim(Token, '+') then Leading := cmNextSibling
    else if IsDelim(Token, '~') then Leading := cmSubsequentSibling;
    if Leading <> cmNone then
    begin
      Inc(Cursor.Position);
      Cursor.SkipWhitespace;
    end;
  end;
  repeat
    if not ParseCompound(Parser, Cursor, Compound, Invalid) then
    begin
      Failed := True;
      Break;
    end;
    SetLength(LeftToRight, Count + 1);
    SetLength(Combinators, Count + 1);
    LeftToRight[Count] := Compound;
    Combinators[Count] := cmNone;
    Inc(Count);
    if not ParseCombinator(Cursor, Combinator) then
    begin
      Failed := True;
      Break;
    end;
    if Combinator = cmNone then
      Break;
    Combinators[Count - 1] := Combinator;
  until False;
  { A pseudo-element belongs in the last compound only. }
  if not Failed then
    for Index := 0 to Count - 2 do
      if CompoundHasPseudoElement(LeftToRight[Index]) then
        Failed := True;
  if Failed then
  begin
    for Index := 0 to Count - 1 do
      FreeCompound(LeftToRight[Index]);
    Exit;
  end;
  Result := TCssComplexSelector.Create;
  Result.IsRelative := Relative;
  { Store right to left. }
  SetLength(Result.Compounds, Count);
  for Index := 0 to Count - 1 do
  begin
    Result.Compounds[Index] := LeftToRight[Count - 1 - Index];
    if Count - 2 - Index >= 0 then
      Result.Compounds[Index].Combinator := Combinators[Count - 2 - Index]
    else
      Result.Compounds[Index].Combinator := cmNone;
  end;
  if Relative then
  begin
    if Leading = cmNone then
      Leading := cmDescendant;
    Result.Compounds[Count - 1].Combinator := Leading;
    SetLength(Result.Compounds, Count + 1);
    Result.Compounds[Count] := MakeSingleSimpleCompound(skHasAnchor, nil, cmNone);
  end
  else if NestedRule and ((Leading <> cmNone) or not SelectorContainsNesting(Result)) then
  begin
    if Leading = cmNone then
      Leading := cmDescendant;
    Result.Compounds[Count - 1].Combinator := Leading;
    SetLength(Result.Compounds, Count + 1);
    Result.Compounds[Count] := MakeSingleSimpleCompound(skNesting, Parser.Context.NestingParent, cmNone);
  end
  else if Leading <> cmNone then
  begin
    Result.Free;
    Exit(nil);
  end;
  Result.Finish;
end;

function ParseList(var Parser: TSelectorParser; Cursor: TCssTokenCursor; Mode: TListMode): TCssSelectorList;
var
  ItemStart: Integer;
  Token: PCssToken;
  Selector: TCssComplexSelector;
  AtListEnd: Boolean;
  NestedRule: Boolean;
begin
  Result := TCssSelectorList.Create;
  NestedRule := Parser.Context.Nested and (Parser.Depth = 0);
  ItemStart := Cursor.Position;
  repeat
    AtListEnd := Cursor.AtEnd;
    if not AtListEnd then
    begin
      Token := Cursor.Next;
      if Token^.Kind <> tkComma then
        Continue;
    end;
    { One item: [ItemStart, the comma or the end). }
    if AtListEnd then
      Selector := ParseComplex(Parser, TCssTokenCursor.CreateRange(Cursor.Tokens, ItemStart, Cursor.Stop),
        Mode = lmRelative, NestedRule)
    else
      Selector := ParseComplex(Parser, TCssTokenCursor.CreateRange(Cursor.Tokens, ItemStart, Cursor.Position - 1),
        Mode = lmRelative, NestedRule);
    if Selector <> nil then
      Result.Add(Selector)
    else if Mode <> lmForgiving then
    begin
      FreeAndNil(Result);
      Exit;
    end;
    ItemStart := Cursor.Position;
  until AtListEnd;
  if (Result.Count = 0) and (Mode <> lmForgiving) then
    FreeAndNil(Result);
end;

function ParseSelectorList(Cursor: TCssTokenCursor; const Context: TCssSelectorContext): TCssSelectorList;
var
  Parser: TSelectorParser;
begin
  Parser.Context := Context;
  Parser.Depth := 0;
  if Cursor.AtEndIgnoringWhitespace then
    Exit(nil);
  Result := ParseList(Parser, Cursor, lmUnforgiving);
end;

function ParseSelectorText(const Text: string; Namespaces: TCssNamespaces): TCssSelectorList;
var
  Context: TCssSelectorContext;
begin
  Context.Namespaces := Namespaces;
  Context.NestingParent := nil;
  Context.Nested := False;
  Result := ParseSelectorList(TCssTokenCursor.Create(TokenizeCss(Text)), Context);
end;

end.
