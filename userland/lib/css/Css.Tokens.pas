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
  Tokens (CSS Syntax Module Level 3, section 4) and the cursor the
  parsers walk them with.

  A token list is a dynamic array (shared by reference counting) that
  always ends with an EOF token. The tokenizer pairs every opening bracket
  and function token with its closing token the way the spec's
  "consume a simple block" and "consume a function" would, and keeps
  the closer's index in Match. A component value is then a token, or a
  range [opener, Match]: skipping one is a jump, and nothing builds a
  tree of component values.
}
unit Css.Tokens;

{$mode objfpc}
{$H+}
{$modeswitch advancedrecords}

interface

type
  TCssTokenKind = (
    tkIdent, tkFunction, tkAtKeyword, tkHash, tkString, tkBadString, tkUrl, tkBadUrl,
    tkDelim, tkNumber, tkPercentage, tkDimension, tkWhitespace, tkCdo, tkCdc, tkColon,
    tkSemicolon, tkComma, tkOpenSquare, tkCloseSquare, tkOpenParen, tkCloseParen,
    tkOpenCurly, tkCloseCurly, tkEof);

  TCssTokenFlag = (
    { A number whose type flag is "integer". }
    tfInteger,
    { A hash token whose type flag is "id". }
    tfIdHash,
    { A number that was written with an explicit + or - sign. }
    tfSigned);
  TCssTokenFlags = set of TCssTokenFlag;

  PCssToken = ^TCssToken;
  TCssToken = record
    Kind: TCssTokenKind;
    Flags: TCssTokenFlags;
    { For an opener or function token, the index of its closing token
      (or of the EOF token when the block is never closed); else -1. }
    Match: LongInt;
    { Byte offset in the source. }
    Position: LongInt;
    { The value of ident, function (its name), at-keyword, hash,
      string and url tokens; the code point of a delim token (UTF-8);
      the unit of a dimension. }
    Text: string;
    Number: Double;
  end;

  TCssTokenArray = array of TCssToken;

  { A range of tokens being parsed: Tokens[Position..Stop - 1]. }
  TCssTokenCursor = record
    Tokens: TCssTokenArray;
    Position: Integer;
    Stop: Integer;
    class function Create(const List: TCssTokenArray): TCssTokenCursor; static;
    class function CreateRange(const List: TCssTokenArray; First, StopIndex: Integer): TCssTokenCursor; static;
    { The current token (an EOF token at the end of the range). }
    function Peek: PCssToken;
    function PeekKind: TCssTokenKind;
    function AtEnd: Boolean;
    procedure SkipWhitespace;
    { At the end once whitespace is skipped. }
    function AtEndIgnoringWhitespace: Boolean;
    { Consumes one component value (a whole block or function) and
      returns its first token. }
    function Next: PCssToken;
    { Skips whitespace, then consumes one component value. }
    function NextNonWhitespace: PCssToken;
    { The contents of the block or function whose opener is Opener. }
    function Contents(Opener: PCssToken): TCssTokenCursor;
    function IndexOf(Token: PCssToken): Integer;
    function IsIdent(const LowercaseName: string): Boolean;
  end;

  TCssTokenCursorArray = array of TCssTokenCursor;

const
  OpenerKinds = [tkFunction, tkOpenParen, tkOpenSquare, tkOpenCurly];

var
  EofToken: TCssToken;

{ The closing kind of an opening kind. }
function CloserOf(Kind: TCssTokenKind): TCssTokenKind;
{ Pairs openers with closers (sets Match) in Tokens[0..Count - 1]. }
procedure MatchBlocks(var Tokens: TCssTokenArray);
{ The pieces of Cursor's range between top level commas. }
function SplitAtCommas(Cursor: TCssTokenCursor): TCssTokenCursorArray;
{ A standalone copy of Tokens[First..StopIndex - 1] ending in EOF. }
function CopyTokens(const Tokens: TCssTokenArray; First, StopIndex: Integer): TCssTokenArray;

implementation

uses
  Css.Atoms;

function CloserOf(Kind: TCssTokenKind): TCssTokenKind;
begin
  case Kind of
    tkFunction, tkOpenParen: Result := tkCloseParen;
    tkOpenSquare: Result := tkCloseSquare;
    tkOpenCurly: Result := tkCloseCurly;
  else
    Result := tkEof;
  end;
end;

procedure MatchBlocks(var Tokens: TCssTokenArray);
var
  Stack: array of Integer;
  Depth, Index, Last: Integer;
  Kind: TCssTokenKind;
begin
  Stack := nil;
  Depth := 0;
  Last := High(Tokens);
  for Index := 0 to Last do
  begin
    Kind := Tokens[Index].Kind;
    Tokens[Index].Match := -1;
    if Kind in OpenerKinds then
    begin
      if Depth >= Length(Stack) then
        SetLength(Stack, Depth * 2 + 16);
      Stack[Depth] := Index;
      Inc(Depth);
    end
    else if (Kind in [tkCloseParen, tkCloseSquare, tkCloseCurly]) and (Depth > 0) and
      (CloserOf(Tokens[Stack[Depth - 1]].Kind) = Kind) then
    begin
      Dec(Depth);
      Tokens[Stack[Depth]].Match := Index;
    end;
  end;
  { Blocks left open end at the EOF token. }
  while Depth > 0 do
  begin
    Dec(Depth);
    Tokens[Stack[Depth]].Match := Last;
  end;
end;

function SplitAtCommas(Cursor: TCssTokenCursor): TCssTokenCursorArray;
var
  Start, Count: Integer;
  Finished: Boolean;
begin
  Result := nil;
  Count := 0;
  Start := Cursor.Position;
  repeat
    Finished := Cursor.AtEnd;
    if not Finished then
      if Cursor.Next^.Kind <> tkComma then
        Continue;
    SetLength(Result, Count + 1);
    if Finished then
      Result[Count] := TCssTokenCursor.CreateRange(Cursor.Tokens, Start, Cursor.Stop)
    else
      Result[Count] := TCssTokenCursor.CreateRange(Cursor.Tokens, Start, Cursor.Position - 1);
    Inc(Count);
    Start := Cursor.Position;
  until Finished;
end;

function CopyTokens(const Tokens: TCssTokenArray; First, StopIndex: Integer): TCssTokenArray;
var
  Index, Count: Integer;
begin
  Result := nil;
  Count := StopIndex - First;
  if Count < 0 then
    Count := 0;
  SetLength(Result, Count + 1);
  for Index := 0 to Count - 1 do
    Result[Index] := Tokens[First + Index];
  Result[Count] := EofToken;
  if Count > 0 then
    Result[Count].Position := Tokens[StopIndex - 1].Position;
  MatchBlocks(Result);
end;

class function TCssTokenCursor.Create(const List: TCssTokenArray): TCssTokenCursor;
begin
  Result.Tokens := List;
  Result.Position := 0;
  Result.Stop := Length(List);
  { The EOF token is not part of the range. }
  if (Result.Stop > 0) and (List[Result.Stop - 1].Kind = tkEof) then
    Dec(Result.Stop);
end;

class function TCssTokenCursor.CreateRange(const List: TCssTokenArray; First, StopIndex: Integer): TCssTokenCursor;
begin
  Result.Tokens := List;
  Result.Position := First;
  Result.Stop := StopIndex;
end;

function TCssTokenCursor.Peek: PCssToken;
begin
  if Position < Stop then
    Result := @Tokens[Position]
  else
    Result := @EofToken;
end;

function TCssTokenCursor.PeekKind: TCssTokenKind;
begin
  if Position < Stop then
    Result := Tokens[Position].Kind
  else
    Result := tkEof;
end;

function TCssTokenCursor.AtEnd: Boolean;
begin
  Result := Position >= Stop;
end;

procedure TCssTokenCursor.SkipWhitespace;
begin
  while (Position < Stop) and (Tokens[Position].Kind = tkWhitespace) do
    Inc(Position);
end;

function TCssTokenCursor.AtEndIgnoringWhitespace: Boolean;
begin
  SkipWhitespace;
  Result := Position >= Stop;
end;

function TCssTokenCursor.Next: PCssToken;
var
  MatchIndex: Integer;
begin
  if Position >= Stop then
    Exit(@EofToken);
  Result := @Tokens[Position];
  if Result^.Kind in OpenerKinds then
  begin
    MatchIndex := Result^.Match;
    if (MatchIndex < 0) or (MatchIndex >= Stop) then
      Position := Stop
    else
      Position := MatchIndex + 1;
  end
  else
    Inc(Position);
end;

function TCssTokenCursor.NextNonWhitespace: PCssToken;
begin
  SkipWhitespace;
  Result := Next;
end;

function TCssTokenCursor.Contents(Opener: PCssToken): TCssTokenCursor;
var
  First, Last: Integer;
begin
  Result.Tokens := Tokens;
  First := IndexOf(Opener);
  if (First < 0) or not (Opener^.Kind in OpenerKinds) then
  begin
    Result.Position := 0;
    Result.Stop := 0;
    Exit;
  end;
  Last := Opener^.Match;
  if (Last < 0) or (Last > Stop) then
    Last := Stop;
  Result.Position := First + 1;
  Result.Stop := Last;
end;

function TCssTokenCursor.IndexOf(Token: PCssToken): Integer;
begin
  if (Length(Tokens) = 0) or (Token = @EofToken) then
    Exit(-1);
  Result := (PtrUInt(Token) - PtrUInt(@Tokens[0])) div SizeOf(TCssToken);
end;

function TCssTokenCursor.IsIdent(const LowercaseName: string): Boolean;
var
  Token: PCssToken;
begin
  Token := Peek;
  Result := (Token^.Kind = tkIdent) and AsciiSameText(Token^.Text, LowercaseName);
end;

initialization
  EofToken.Kind := tkEof;
  EofToken.Match := -1;
end.
