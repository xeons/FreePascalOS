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

(*
  Regular expressions, POSIX basic (BRE) and extended (ERE) syntax.

    .          any character
    [abc] [^a-z] [[:alpha:]]   bracket expressions with ranges and classes
    ^ $        start and end of the text (BRE: only at the ends)
    *          zero or more of the previous item
    + ? {m,n}  ERE: one or more, zero or one, between m and n
    \+ \? \{m,n\}   the same in BRE
    ( ) |      ERE: grouping and alternation
    \( \) \|   the same in BRE
    \n         a character that is otherwise special

  An expression is compiled once into a tree, then matched with
  backtracking (leftmost, longest for each repetition). The first nine
  groups record what they matched.

    if CompileExpression(Text, SyntaxBasic, Expression) then
      if SearchExpression(Expression, Subject, Match) then ...
*)
unit Util.RegularExpressions;

{$mode objfpc}{$H+}
{$pointermath on}

interface

const
  MaximumGroups = 10; { group 0 is the whole match }

type
  TExpressionSyntax = (SyntaxBasic, SyntaxExtended);

  TNodeKind = (NodeCharacter, NodeAnyCharacter, NodeSet, NodeStart, NodeEnd, NodeGroup,
    NodeSequence, NodeAlternation, NodeRepeat, NodeEmpty);

  PExpressionNode = ^TExpressionNode;
  TExpressionNode = record
    Kind: TNodeKind;
    Character: Char;
    { NodeSet: 256 membership bits. }
    Members: array[0..31] of Byte;
    { NodeSequence, NodeAlternation: children; NodeRepeat, NodeGroup: Child. }
    Children: ^PExpressionNode;
    ChildCount: Integer;
    Child: PExpressionNode;
    Minimum: Integer;
    Maximum: Integer;   { -1 = unlimited }
    GroupNumber: Integer;
  end;

  TExpression = record
    Root: PExpressionNode;
    GroupCount: Integer;
    IgnoreCase: Boolean;
  end;

  TMatch = record
    { Byte offsets into the subject; -1 when a group did not take part. }
    Starts: array[0..MaximumGroups - 1] of PtrInt;
    Ends: array[0..MaximumGroups - 1] of PtrInt;
  end;

{ Returns False with ErrorMessage set if Text is not a valid expression. }
function CompileExpression(Text: PChar; Syntax: TExpressionSyntax; out Expression: TExpression;
  out ErrorMessage: PChar): Boolean; overload;
function CompileExpression(const Text: string; Syntax: TExpressionSyntax; out Expression: TExpression;
  out ErrorMessage: string): Boolean; overload;
procedure FreeExpression(var Expression: TExpression);

{ Finds the leftmost match anywhere in Subject. }
function SearchExpression(const Expression: TExpression; Subject: PChar; out Match: TMatch): Boolean; overload;
function SearchExpression(const Expression: TExpression; const Subject: string;
  out Match: TMatch): Boolean; overload;
{ Matches only at the start of Subject (like expr's ':' operator). }
function MatchExpressionAtStart(const Expression: TExpression; Subject: PChar; out Match: TMatch): Boolean; overload;
function MatchExpressionAtStart(const Expression: TExpression; const Subject: string;
  out Match: TMatch): Boolean; overload;
{ Finds the leftmost match starting at or after byte offset StartOffset;
  "^" still means the start of Subject (as sed's s///g needs). }
function SearchExpressionFrom(const Expression: TExpression; Subject: PChar; StartOffset: PtrInt;
  out Match: TMatch): Boolean; overload;
function SearchExpressionFrom(const Expression: TExpression; const Subject: string; StartOffset: PtrInt;
  out Match: TMatch): Boolean; overload;

{ The text group Group matched (Match from a search of Subject); '' when
  it did not take part. }
function MatchedText(const Subject: string; const Match: TMatch; Group: Integer): string;

implementation

uses
  Runtime.Memory,
  Runtime.Text,
  Sys.Memory,
  Sys.Text;

const
  RepeatLimit = 255;

{ --- Building the tree ----------------------------------------------- }

type
  TParser = record
    Text: PChar;
    Position: PtrInt;
    Syntax: TExpressionSyntax;
    GroupCount: Integer;
    Failed: Boolean;
    ErrorMessage: PChar;
  end;

function NewNode(Kind: TNodeKind): PExpressionNode;
begin
  Result := PExpressionNode(AllocateZeroedMemory(SizeOf(TExpressionNode)));
  Result^.Kind := Kind;
end;

procedure AddChild(Node: PExpressionNode; Child: PExpressionNode);
begin
  Node^.Children := ReallocateMemory(Node^.Children, QWord(Node^.ChildCount + 1) * SizeOf(PExpressionNode));
  Node^.Children[Node^.ChildCount] := Child;
  Inc(Node^.ChildCount);
end;

procedure SetMember(Node: PExpressionNode; Character: Char);
begin
  Node^.Members[Ord(Character) shr 3] := Node^.Members[Ord(Character) shr 3] or (1 shl (Ord(Character) and 7));
end;

function IsMember(Node: PExpressionNode; Character: Char): Boolean;
begin
  Result := (Node^.Members[Ord(Character) shr 3] and (1 shl (Ord(Character) and 7))) <> 0;
end;

procedure Failure(var Parser: TParser; Message: PChar);
begin
  if not Parser.Failed then
  begin
    Parser.Failed := True;
    Parser.ErrorMessage := Message;
  end;
end;

function Current(var Parser: TParser): Char;
begin
  Result := Parser.Text[Parser.Position];
end;

function NextIs(var Parser: TParser; Offset: Integer; Character: Char): Boolean;
begin
  Result := Parser.Text[Parser.Position + Offset] = Character;
end;

function ClassContains(ClassName: PChar; Character: Char): Boolean;
begin
  if TextIsEqual(ClassName, 'alpha') then Result := IsLetter(Character)
  else if TextIsEqual(ClassName, 'digit') then Result := IsDigit(Character)
  else if TextIsEqual(ClassName, 'alnum') then Result := IsAlphanumeric(Character)
  else if TextIsEqual(ClassName, 'upper') then Result := IsUpperCase(Character)
  else if TextIsEqual(ClassName, 'lower') then Result := IsLowerCase(Character)
  else if TextIsEqual(ClassName, 'space') then Result := IsSpace(Character)
  else if TextIsEqual(ClassName, 'blank') then Result := (Character = ' ') or (Character = #9)
  else if TextIsEqual(ClassName, 'punct') then
    Result := (Byte(Character) > 32) and (Byte(Character) < 127) and not IsAlphanumeric(Character)
  else if TextIsEqual(ClassName, 'print') then Result := (Byte(Character) >= 32) and (Byte(Character) < 127)
  else if TextIsEqual(ClassName, 'graph') then Result := (Byte(Character) > 32) and (Byte(Character) < 127)
  else if TextIsEqual(ClassName, 'cntrl') then Result := (Byte(Character) < 32) or (Byte(Character) = 127)
  else if TextIsEqual(ClassName, 'xdigit') then
    Result := IsDigit(Character) or (ToLowerCase(Character) in ['a'..'f'])
  else
    Result := False;
end;

function ParseBracket(var Parser: TParser): PExpressionNode;
var
  Negate: Boolean;
  First: Boolean;
  Low: Char;
  High: Char;
  Character: Char;
  ClassName: array[0..15] of Char;
  ClassLength: Integer;
  Index: Integer;
begin
  Inc(Parser.Position); { '[' }
  Result := NewNode(NodeSet);
  Negate := Current(Parser) = '^';
  if Negate then
    Inc(Parser.Position);
  First := True;
  while (Current(Parser) <> #0) and ((Current(Parser) <> ']') or First) do
  begin
    First := False;
    if (Current(Parser) = '[') and NextIs(Parser, 1, ':') then
    begin
      Parser.Position := Parser.Position + 2;
      ClassLength := 0;
      while (Current(Parser) <> #0) and not ((Current(Parser) = ':') and NextIs(Parser, 1, ']')) do
      begin
        if ClassLength < 15 then
        begin
          ClassName[ClassLength] := Current(Parser);
          Inc(ClassLength);
        end;
        Inc(Parser.Position);
      end;
      ClassName[ClassLength] := #0;
      if Current(Parser) = #0 then
        Break;
      Parser.Position := Parser.Position + 2;
      for Index := 1 to 255 do
        if ClassContains(@ClassName[0], Char(Index)) then
          SetMember(Result, Char(Index));
      Continue;
    end;
    Low := Current(Parser);
    Inc(Parser.Position);
    High := Low;
    if (Current(Parser) = '-') and not NextIs(Parser, 1, ']') and not NextIs(Parser, 1, #0) then
    begin
      High := Parser.Text[Parser.Position + 1];
      Parser.Position := Parser.Position + 2;
      if High < Low then
      begin
        Failure(Parser, 'Invalid range end');
        Exit;
      end;
    end;
    for Character := Low to High do
      SetMember(Result, Character);
  end;
  if Current(Parser) <> ']' then
  begin
    Failure(Parser, 'Unmatched [, [^, [:, [., or [=');
    Exit;
  end;
  Inc(Parser.Position);
  if Negate then
  begin
    for Index := 0 to 31 do
      Result^.Members[Index] := not Result^.Members[Index];
    { A negated set never matches the end of a line. }
    Result^.Members[Ord(#10) shr 3] := Result^.Members[Ord(#10) shr 3] and not (1 shl (Ord(#10) and 7));
  end;
end;

function ParseAlternation(var Parser: TParser): PExpressionNode; forward;

{ True at a group end or alternation bar, which end a sequence. }
function AtSequenceEnd(var Parser: TParser): Boolean;
begin
  if Current(Parser) = #0 then
    Exit(True);
  if Parser.Syntax = SyntaxExtended then
    Result := Current(Parser) in [')', '|']
  else
    Result := (Current(Parser) = '\') and (NextIs(Parser, 1, ')') or NextIs(Parser, 1, '|'));
end;

function ParseAtom(var Parser: TParser; AtSequenceStart: Boolean): PExpressionNode;
var
  Character: Char;
  Inner: PExpressionNode;
begin
  Character := Current(Parser);
  { Groups. }
  if ((Parser.Syntax = SyntaxExtended) and (Character = '(')) or
     ((Parser.Syntax = SyntaxBasic) and (Character = '\') and NextIs(Parser, 1, '(')) then
  begin
    if Parser.Syntax = SyntaxExtended then
      Inc(Parser.Position)
    else
      Parser.Position := Parser.Position + 2;
    Inc(Parser.GroupCount);
    Result := NewNode(NodeGroup);
    Result^.GroupNumber := Parser.GroupCount;
    Inner := ParseAlternation(Parser);
    Result^.Child := Inner;
    if (Parser.Syntax = SyntaxExtended) and (Current(Parser) = ')') then
      Inc(Parser.Position)
    else if (Parser.Syntax = SyntaxBasic) and (Current(Parser) = '\') and NextIs(Parser, 1, ')') then
      Parser.Position := Parser.Position + 2
    else
      Failure(Parser, 'Unmatched ( or \(');
    Exit;
  end;
  case Character of
    '.':
      begin
        Inc(Parser.Position);
        Exit(NewNode(NodeAnyCharacter));
      end;
    '[':
      Exit(ParseBracket(Parser));
    '^':
      { In BRE "^" is an anchor only at the start. }
      if (Parser.Syntax = SyntaxExtended) or AtSequenceStart then
      begin
        Inc(Parser.Position);
        Exit(NewNode(NodeStart));
      end;
    '$':
      { In BRE "$" is an anchor only at the end. }
      if (Parser.Syntax = SyntaxExtended) or (Parser.Text[Parser.Position + 1] = #0) or
         ((Parser.Text[Parser.Position + 1] = '\') and (Parser.Text[Parser.Position + 2] in [')', '|'])) then
      begin
        Inc(Parser.Position);
        Exit(NewNode(NodeEnd));
      end;
    '\':
      begin
        Inc(Parser.Position);
        Character := Current(Parser);
        if Character = #0 then
        begin
          Failure(Parser, 'Trailing backslash');
          Exit(NewNode(NodeEmpty));
        end;
        case Character of
          'n': Character := #10;
          't': Character := #9;
        end;
      end;
  end;
  Inc(Parser.Position);
  Result := NewNode(NodeCharacter);
  Result^.Character := Character;
end;

(* Reads "{m}", "{m,}" or "{m,n}" (after the brace). *)
procedure ParseBounds(var Parser: TParser; Node: PExpressionNode);
var
  Value: Integer;
  HasValue: Boolean;
begin
  Value := 0;
  HasValue := False;
  while IsDigit(Current(Parser)) do
  begin
    Value := Value * 10 + Ord(Current(Parser)) - Ord('0');
    HasValue := True;
    Inc(Parser.Position);
  end;
  if not HasValue then
    Failure(Parser, 'Invalid content of \{\}');
  Node^.Minimum := Value;
  Node^.Maximum := Value;
  if Current(Parser) = ',' then
  begin
    Inc(Parser.Position);
    Node^.Maximum := -1;
    if IsDigit(Current(Parser)) then
    begin
      Value := 0;
      while IsDigit(Current(Parser)) do
      begin
        Value := Value * 10 + Ord(Current(Parser)) - Ord('0');
        Inc(Parser.Position);
      end;
      Node^.Maximum := Value;
    end;
  end;
  if Parser.Syntax = SyntaxBasic then
  begin
    if (Current(Parser) = '\') and NextIs(Parser, 1, '}') then
      Parser.Position := Parser.Position + 2
    else
      Failure(Parser, 'Unmatched \{');
  end
  else if Current(Parser) = '}' then
    Inc(Parser.Position)
  else
    Failure(Parser, 'Unmatched {');
  if (Node^.Minimum > RepeatLimit) or ((Node^.Maximum >= 0) and (Node^.Maximum < Node^.Minimum)) then
    Failure(Parser, 'Invalid content of \{\}');
end;

{ Wraps Atom in a repetition if one follows. }
function ParseRepeats(var Parser: TParser; Atom: PExpressionNode): PExpressionNode;
var
  Node: PExpressionNode;
  IsRepeat: Boolean;
begin
  Result := Atom;
  repeat
    IsRepeat := False;
    Node := nil;
    if Current(Parser) = '*' then
    begin
      Inc(Parser.Position);
      Node := NewNode(NodeRepeat);
      Node^.Minimum := 0;
      Node^.Maximum := -1;
    end
    else if ((Parser.Syntax = SyntaxExtended) and (Current(Parser) in ['+', '?'])) or
            ((Parser.Syntax = SyntaxBasic) and (Current(Parser) = '\') and
             (NextIs(Parser, 1, '+') or NextIs(Parser, 1, '?'))) then
    begin
      if Parser.Syntax = SyntaxBasic then
        Inc(Parser.Position);
      Node := NewNode(NodeRepeat);
      if Current(Parser) = '+' then
      begin
        Node^.Minimum := 1;
        Node^.Maximum := -1;
      end
      else
      begin
        Node^.Minimum := 0;
        Node^.Maximum := 1;
      end;
      Inc(Parser.Position);
    end
    else if ((Parser.Syntax = SyntaxExtended) and (Current(Parser) = '{') and IsDigit(Parser.Text[Parser.Position + 1])) or
            ((Parser.Syntax = SyntaxBasic) and (Current(Parser) = '\') and NextIs(Parser, 1, '{')) then
    begin
      if Parser.Syntax = SyntaxBasic then
        Parser.Position := Parser.Position + 2
      else
        Inc(Parser.Position);
      Node := NewNode(NodeRepeat);
      ParseBounds(Parser, Node);
    end;
    if Node <> nil then
    begin
      Node^.Child := Result;
      Result := Node;
      IsRepeat := True;
    end;
  until not IsRepeat or Parser.Failed;
end;

function ParseSequence(var Parser: TParser): PExpressionNode;
var
  Atom: PExpressionNode;
begin
  Result := NewNode(NodeSequence);
  while not AtSequenceEnd(Parser) and not Parser.Failed do
  begin
    { A leading "*" in BRE is an ordinary character. }
    if (Current(Parser) = '*') and (Result^.ChildCount = 0) then
    begin
      Atom := NewNode(NodeCharacter);
      Atom^.Character := '*';
      Inc(Parser.Position);
    end
    else
      Atom := ParseAtom(Parser, Result^.ChildCount = 0);
    AddChild(Result, ParseRepeats(Parser, Atom));
  end;
end;

function ParseAlternation(var Parser: TParser): PExpressionNode;
var
  Branch: PExpressionNode;
begin
  Branch := ParseSequence(Parser);
  if not (((Parser.Syntax = SyntaxExtended) and (Current(Parser) = '|')) or
          ((Parser.Syntax = SyntaxBasic) and (Current(Parser) = '\') and NextIs(Parser, 1, '|'))) then
    Exit(Branch);
  Result := NewNode(NodeAlternation);
  AddChild(Result, Branch);
  while ((Parser.Syntax = SyntaxExtended) and (Current(Parser) = '|')) or
        ((Parser.Syntax = SyntaxBasic) and (Current(Parser) = '\') and NextIs(Parser, 1, '|')) do
  begin
    if Parser.Syntax = SyntaxExtended then
      Inc(Parser.Position)
    else
      Parser.Position := Parser.Position + 2;
    AddChild(Result, ParseSequence(Parser));
  end;
end;

procedure FreeNode(Node: PExpressionNode);
var
  Index: Integer;
begin
  if Node = nil then
    Exit;
  for Index := 0 to Node^.ChildCount - 1 do
    FreeNode(Node^.Children[Index]);
  FreeMemory(Node^.Children);
  FreeNode(Node^.Child);
  FreeMemory(Node);
end;

function CompileExpression(Text: PChar; Syntax: TExpressionSyntax; out Expression: TExpression;
  out ErrorMessage: PChar): Boolean;
var
  Parser: TParser;
begin
  ZeroMemory(@Parser, SizeOf(Parser));
  Parser.Text := Text;
  Parser.Syntax := Syntax;
  Expression.Root := ParseAlternation(Parser);
  Expression.GroupCount := Parser.GroupCount;
  Expression.IgnoreCase := False;
  ErrorMessage := nil;
  if not Parser.Failed and (Current(Parser) <> #0) then
    Failure(Parser, 'Unmatched ) or \)');
  if Parser.Failed then
  begin
    ErrorMessage := Parser.ErrorMessage;
    FreeExpression(Expression);
    Exit(False);
  end;
  Result := True;
end;

procedure FreeExpression(var Expression: TExpression);
begin
  FreeNode(Expression.Root);
  Expression.Root := nil;
end;

{ --- Matching -------------------------------------------------------- }

type
  { What remains to be matched after the current node: a linked list
    of nodes (with an index into sequences) forming the continuation. }
  PContinuation = ^TContinuation;
  TContinuation = record
    Node: PExpressionNode;
    { For sequences: the next child to match. For repeats: the count so
      far. For groups: 1 once the group's content is done. }
    Index: Integer;
    Start: PtrInt;   { repeats: where this iteration started }
    Next: PContinuation;
  end;

  TMatcher = record
    Expression: ^TExpression;
    Subject: PChar;
    Length: PtrInt;
    Match: TMatch;
    Steps: QWord;
  end;

const
  StepLimit = 50000000;

function CharactersEqual(var Matcher: TMatcher; First, Second: Char): Boolean;
begin
  if Matcher.Expression^.IgnoreCase then
    Result := ToLowerCase(First) = ToLowerCase(Second)
  else
    Result := First = Second;
end;

function MatchNode(var Matcher: TMatcher; Node: PExpressionNode; Position: PtrInt;
  Continuation: PContinuation; out EndPosition: PtrInt): Boolean; forward;

{ Matches the continuation list from Position. }
function MatchContinuation(var Matcher: TMatcher; Continuation: PContinuation; Position: PtrInt;
  out EndPosition: PtrInt): Boolean;
var
  Step: TContinuation;
  SavedStart: PtrInt;
  SavedEnd: PtrInt;
  Group: Integer;
begin
  if Continuation = nil then
  begin
    EndPosition := Position;
    Exit(True);
  end;
  Inc(Matcher.Steps);
  if Matcher.Steps > StepLimit then
    Exit(False);

  case Continuation^.Node^.Kind of
    NodeSequence:
      begin
        if Continuation^.Index >= Continuation^.Node^.ChildCount then
          Exit(MatchContinuation(Matcher, Continuation^.Next, Position, EndPosition));
        Step := Continuation^;
        Inc(Step.Index);
        Result := MatchNode(Matcher, Continuation^.Node^.Children[Continuation^.Index], Position, @Step, EndPosition);
      end;
    NodeGroup:
      begin
        { The group's content has matched up to Position. }
        Group := Continuation^.Node^.GroupNumber;
        if Group < MaximumGroups then
        begin
          SavedStart := Matcher.Match.Starts[Group];
          SavedEnd := Matcher.Match.Ends[Group];
          Matcher.Match.Starts[Group] := Continuation^.Start;
          Matcher.Match.Ends[Group] := Position;
        end;
        Result := MatchContinuation(Matcher, Continuation^.Next, Position, EndPosition);
        if not Result and (Group < MaximumGroups) then
        begin
          Matcher.Match.Starts[Group] := SavedStart;
          Matcher.Match.Ends[Group] := SavedEnd;
        end;
      end;
    NodeRepeat:
      begin
        { One more iteration done (Index counts them). An iteration that
          matched nothing beyond the required minimum adds nothing and
          must not record empty groups (POSIX), so it is refused. }
        if (Position = Continuation^.Start) and (Continuation^.Index > Continuation^.Node^.Minimum) then
          Exit(False);
        { Try another iteration first (longest match). }
        Step := Continuation^;
        if ((Step.Node^.Maximum < 0) or (Step.Index < Step.Node^.Maximum)) and (Position > Step.Start) then
        begin
          Step.Start := Position;
          Inc(Step.Index);
          if MatchNode(Matcher, Step.Node^.Child, Position, @Step, EndPosition) then
            Exit(True);
          Dec(Step.Index);
        end;
        if Continuation^.Index >= Continuation^.Node^.Minimum then
          Exit(MatchContinuation(Matcher, Continuation^.Next, Position, EndPosition));
        Result := False;
      end;
  else
    Result := MatchNode(Matcher, Continuation^.Node, Position, Continuation^.Next, EndPosition);
  end;
end;

function MatchNode(var Matcher: TMatcher; Node: PExpressionNode; Position: PtrInt;
  Continuation: PContinuation; out EndPosition: PtrInt): Boolean;
var
  Step: TContinuation;
  Index: Integer;
  Character: Char;
begin
  EndPosition := Position;
  case Node^.Kind of
    NodeEmpty:
      Result := MatchContinuation(Matcher, Continuation, Position, EndPosition);
    NodeCharacter:
      Result := (Position < Matcher.Length) and CharactersEqual(Matcher, Matcher.Subject[Position], Node^.Character) and
        MatchContinuation(Matcher, Continuation, Position + 1, EndPosition);
    NodeAnyCharacter:
      Result := (Position < Matcher.Length) and (Matcher.Subject[Position] <> #10) and
        MatchContinuation(Matcher, Continuation, Position + 1, EndPosition);
    NodeSet:
      begin
        if Position >= Matcher.Length then
          Exit(False);
        Character := Matcher.Subject[Position];
        Result := IsMember(Node, Character) or (Matcher.Expression^.IgnoreCase and
          (IsMember(Node, ToLowerCase(Character)) or IsMember(Node, ToUpperCase(Character))));
        Result := Result and MatchContinuation(Matcher, Continuation, Position + 1, EndPosition);
      end;
    NodeStart:
      Result := (Position = 0) and MatchContinuation(Matcher, Continuation, Position, EndPosition);
    NodeEnd:
      Result := (Position = Matcher.Length) and MatchContinuation(Matcher, Continuation, Position, EndPosition);
    NodeSequence:
      begin
        Step.Node := Node;
        Step.Index := 0;
        Step.Start := Position;
        Step.Next := Continuation;
        Result := MatchContinuation(Matcher, @Step, Position, EndPosition);
      end;
    NodeAlternation:
      begin
        for Index := 0 to Node^.ChildCount - 1 do
          if MatchNode(Matcher, Node^.Children[Index], Position, Continuation, EndPosition) then
            Exit(True);
        Result := False;
      end;
    NodeGroup:
      begin
        Step.Node := Node;
        Step.Index := 0;
        Step.Start := Position;
        Step.Next := Continuation;
        Result := MatchNode(Matcher, Node^.Child, Position, @Step, EndPosition);
      end;
    NodeRepeat:
      begin
        Step.Node := Node;
        Step.Next := Continuation;
        { Start the first iteration, or skip straight on if none needed. }
        Step.Index := 1;
        Step.Start := Position;
        if (Node^.Maximum <> 0) and MatchNode(Matcher, Node^.Child, Position, @Step, EndPosition) then
          Exit(True);
        Result := (Node^.Minimum = 0) and MatchContinuation(Matcher, Continuation, Position, EndPosition);
      end;
  else
    Result := False;
  end;
end;

procedure ResetMatch(var Match: TMatch);
var
  Index: Integer;
begin
  for Index := 0 to MaximumGroups - 1 do
  begin
    Match.Starts[Index] := -1;
    Match.Ends[Index] := -1;
  end;
end;

function TryAt(var Matcher: TMatcher; Position: PtrInt): Boolean;
var
  EndPosition: PtrInt;
begin
  ResetMatch(Matcher.Match);
  Result := MatchNode(Matcher, Matcher.Expression^.Root, Position, nil, EndPosition);
  if Result then
  begin
    Matcher.Match.Starts[0] := Position;
    Matcher.Match.Ends[0] := EndPosition;
  end;
end;

function MatchExpressionAtStart(const Expression: TExpression; Subject: PChar; out Match: TMatch): Boolean;
var
  Matcher: TMatcher;
begin
  Matcher.Expression := @Expression;
  Matcher.Subject := Subject;
  Matcher.Length := PtrInt(TextLength(Subject));
  Matcher.Steps := 0;
  Result := TryAt(Matcher, 0);
  Match := Matcher.Match;
end;

function SearchExpression(const Expression: TExpression; Subject: PChar; out Match: TMatch): Boolean;
begin
  Result := SearchExpressionFrom(Expression, Subject, 0, Match);
end;

function SearchExpressionFrom(const Expression: TExpression; Subject: PChar; StartOffset: PtrInt;
  out Match: TMatch): Boolean;
var
  Matcher: TMatcher;
  Position: PtrInt;
begin
  Matcher.Expression := @Expression;
  Matcher.Subject := Subject;
  Matcher.Length := PtrInt(TextLength(Subject));
  Matcher.Steps := 0;
  Position := StartOffset;
  if Position > Matcher.Length then
  begin
    ResetMatch(Match);
    Exit(False);
  end;
  repeat
    if TryAt(Matcher, Position) then
    begin
      Match := Matcher.Match;
      Exit(True);
    end;
    Inc(Position);
  until Position > Matcher.Length;
  ResetMatch(Match);
  Result := False;
end;

{ --- Strings ----------------------------------------------------------- }

function CompileExpression(const Text: string; Syntax: TExpressionSyntax; out Expression: TExpression;
  out ErrorMessage: string): Boolean;
var
  MessageText: PChar;
begin
  Result := CompileExpression(PChar(Text), Syntax, Expression, MessageText);
  if Result then
    ErrorMessage := ''
  else
    ErrorMessage := MessageText;
end;

function SearchExpression(const Expression: TExpression; const Subject: string;
  out Match: TMatch): Boolean;
begin
  Result := SearchExpression(Expression, PChar(Subject), Match);
end;

function MatchExpressionAtStart(const Expression: TExpression; const Subject: string;
  out Match: TMatch): Boolean;
begin
  Result := MatchExpressionAtStart(Expression, PChar(Subject), Match);
end;

function SearchExpressionFrom(const Expression: TExpression; const Subject: string; StartOffset: PtrInt;
  out Match: TMatch): Boolean;
begin
  Result := SearchExpressionFrom(Expression, PChar(Subject), StartOffset, Match);
end;

function MatchedText(const Subject: string; const Match: TMatch; Group: Integer): string;
begin
  if (Match.Starts[Group] < 0) or (Match.Ends[Group] < Match.Starts[Group]) then
    Exit('');
  Result := Copy(Subject, Match.Starts[Group] + 1, Match.Ends[Group] - Match.Starts[Group]);
end;

end.
