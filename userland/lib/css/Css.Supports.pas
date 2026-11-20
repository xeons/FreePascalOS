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
  @supports conditions (CSS Conditional Rules Level 3 and 4): "not",
  "and", "or", declarations in parentheses (supported when the value
  parses for the property), selector() and font-tech()/font-format().
  What the engine supports does not change while it runs, so a
  condition is decided when it is parsed.
}
unit Css.Supports;

{$mode objfpc}
{$H+}

interface

uses
  Css.Tokens;

{ Whether Cursor's range is a valid condition, and if so whether it holds. }
function ParseSupportsCondition(Cursor: TCssTokenCursor; out Matches: Boolean): Boolean;
function SupportsConditionText(const Text: string): Boolean;

implementation

uses
  Css.Atoms, Css.Keywords, Css.Tokenizer, Css.Values, Css.ValueParser, Css.Declarations, Css.Selectors,
  Css.SelectorParser;

type
  TState = (stFalse, stTrue, stInvalid);

function ParseCondition(var Cursor: TCssTokenCursor): TState; forward;

function DeclarationSupported(Contents: TCssTokenCursor): TState;
var
  Token: PCssToken;
  Name: string;
  Block: TCssDeclarationBlock;
  Value: TCssTokenCursor;
  Important: Boolean;
  Last: Integer;
begin
  Result := stInvalid;
  Token := Contents.NextNonWhitespace;
  if Token^.Kind <> tkIdent then
    Exit;
  Name := Token^.Text;
  Contents.SkipWhitespace;
  if Contents.PeekKind <> tkColon then
    Exit;
  Inc(Contents.Position);
  Value := TrimRange(Contents);
  { A trailing !important is allowed. }
  Important := False;
  Last := Value.Stop - 1;
  if (Last > Value.Position) and (Value.Tokens[Last].Kind = tkIdent) and
    AsciiSameText(Value.Tokens[Last].Text, 'important') then
  begin
    Dec(Last);
    while (Last > Value.Position) and (Value.Tokens[Last].Kind = tkWhitespace) do
      Dec(Last);
    if (Value.Tokens[Last].Kind = tkDelim) and (Value.Tokens[Last].Text = '!') then
    begin
      Value.Stop := Last;
      Important := True;
    end;
  end;
  Block := TCssDeclarationBlock.Create;
  try
    if Block.AddParsed(Name, Value, Important) then
      Result := stTrue
    else
      Result := stFalse;
  finally
    Block.Free;
  end;
end;

function InParens(var Cursor: TCssTokenCursor): TState;
var
  Token: PCssToken;
  Contents, Inner: TCssTokenCursor;
  Lower: string;
  Selectors: TCssSelectorList;
  Context: TCssSelectorContext;
begin
  Cursor.SkipWhitespace;
  Token := Cursor.Peek;
  if Token^.Kind = tkOpenParen then
  begin
    Cursor.Next;
    Contents := Cursor.Contents(Token);
    Inner := Contents;
    Result := ParseCondition(Inner);
    if (Result <> stInvalid) and Inner.AtEndIgnoringWhitespace then
      Exit;
    Result := DeclarationSupported(Contents);
    { Anything else in parentheses is valid and false. }
    if Result = stInvalid then
      Result := stFalse;
    Exit;
  end;
  if Token^.Kind = tkFunction then
  begin
    Cursor.Next;
    Lower := AsciiLowercase(Token^.Text);
    Contents := Cursor.Contents(Token);
    if Lower = 'selector' then
    begin
      Context := Default(TCssSelectorContext);
      Selectors := ParseSelectorList(Contents, Context);
      Result := stFalse;
      if Selectors <> nil then
        Result := stTrue;
      Selectors.Free;
    end
    else
      { font-tech(), font-format() and unknown functions. }
      Result := stFalse;
    Exit;
  end;
  Result := stInvalid;
end;

function ParseCondition(var Cursor: TCssTokenCursor): TState;
var
  Keyword, Joiner: TCssKeyword;
  Next: TState;
  Saved: Integer;
begin
  Keyword := PeekKeyword(Cursor);
  if Keyword = kwNot then
  begin
    Cursor.NextNonWhitespace;
    Result := InParens(Cursor);
    if Result = stTrue then
      Result := stFalse
    else if Result = stFalse then
      Result := stTrue;
    Exit;
  end;
  Result := InParens(Cursor);
  if Result = stInvalid then
    Exit;
  Joiner := kwInvalid;
  repeat
    Saved := Cursor.Position;
    Keyword := PeekKeyword(Cursor);
    if not ((Keyword = kwAnd) or (Keyword = kwOr)) or ((Joiner <> kwInvalid) and (Keyword <> Joiner)) then
    begin
      Cursor.Position := Saved;
      Break;
    end;
    Joiner := Keyword;
    Cursor.NextNonWhitespace;
    Next := InParens(Cursor);
    if Next = stInvalid then
      Exit(stInvalid);
    if Joiner = kwAnd then
    begin
      if Next = stFalse then
        Result := stFalse;
    end
    else if Next = stTrue then
      Result := stTrue;
  until False;
end;

function ParseSupportsCondition(Cursor: TCssTokenCursor; out Matches: Boolean): Boolean;
var
  State: TState;
begin
  State := ParseCondition(Cursor);
  Result := (State <> stInvalid) and Cursor.AtEndIgnoringWhitespace;
  Matches := Result and (State = stTrue);
end;

function SupportsConditionText(const Text: string): Boolean;
begin
  if not ParseSupportsCondition(TCssTokenCursor.Create(TokenizeCss(Text)), Result) then
    Result := False;
end;

end.
