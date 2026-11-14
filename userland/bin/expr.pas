{
  expr - evaluate expressions

  expr EXPRESSION

  Each token is a separate argument. Operators, lowest precedence first:
    |  &  < <= = == != >= >  + -  * / %  : (match a pattern at the start)
  plus "length STRING", "substr STRING POS LENGTH", "index STRING CHARS"
  and parentheses. Prints the result; exits 0 if it is neither empty nor
  0, 1 if it is, 2 for an invalid expression.

  The ':' operator supports a subset of basic regular expressions:
  . * ^ (implied) $ [...] and \( \) for the part to return.
}
program expr;

{$mode objfpc}
{$pointermath on}

uses
  Runtime.Memory,
  Runtime.Text,
  Sys.Environment,
  Sys.Format,
  Sys.Memory,
  Sys.Streams,
  Sys.Text,
  Util.Messages;

var
  Position: Integer;

procedure SyntaxError;
begin
  Report('syntax error', []);
  Halt(2);
end;

function Token(Offset: Integer): PChar;
begin
  if Position + Offset < ArgumentTotal then
    Result := Argument(Position + Offset)
  else
    Result := nil;
end;

function TokenIs(Text: PChar): Boolean;
begin
  Result := (Token(0) <> nil) and TextIsEqual(Token(0), Text);
end;

function IsNumber(Text: PChar; out Value: Int64): Boolean;
begin
  Result := (Text <> nil) and (Text^ <> #0) and ParseInteger(Text, Value);
end;

function MakeNumber(Value: Int64): PChar;
var
  NumberText: TNumberText;
begin
  Result := DuplicateText(FormatSignedDecimal(Value, NumberText));
end;

function IsNullOrZero(Text: PChar): Boolean;
var
  Value: Int64;
begin
  Result := (Text^ = #0) or (IsNumber(Text, Value) and (Value = 0));
end;

function RequireNumber(Text: PChar): Int64;
begin
  if not IsNumber(Text, Result) then
  begin
    Report('non-integer argument', []);
    Halt(2);
  end;
end;

{ --- Pattern matching for ':' ---------------------------------------- }

function MatchHere(Pattern, Text: PChar; out MatchEnd: PChar; var GroupStart, GroupEnd: PChar): Boolean; forward;

{ Matches one pattern element (., [set] or a literal) at Text. Returns
  the element's length in the pattern, or 0 if Text does not match. }
function MatchElement(Pattern, Text: PChar; out ElementLength: Integer): Boolean;
var
  Negate: Boolean;
  Index: Integer;
  Found: Boolean;
begin
  ElementLength := 1;
  if Pattern[0] = '\' then
  begin
    ElementLength := 2;
    Exit((Text^ <> #0) and (Text^ = Pattern[1]));
  end;
  if Pattern[0] = '[' then
  begin
    Index := 1;
    Negate := Pattern[1] = '^';
    if Negate then
      Inc(Index);
    Found := False;
    while (Pattern[Index] <> #0) and ((Pattern[Index] <> ']') or (Index = 1) or (Negate and (Index = 2))) do
    begin
      if (Pattern[Index + 1] = '-') and (Pattern[Index + 2] <> ']') and (Pattern[Index + 2] <> #0) then
      begin
        if (Text^ >= Pattern[Index]) and (Text^ <= Pattern[Index + 2]) then
          Found := True;
        Inc(Index, 3);
      end
      else
      begin
        if Text^ = Pattern[Index] then
          Found := True;
        Inc(Index);
      end;
    end;
    ElementLength := Index + 1;
    Exit((Text^ <> #0) and (Found <> Negate));
  end;
  if Pattern[0] = '.' then
    Exit(Text^ <> #0);
  Result := (Text^ <> #0) and (Text^ = Pattern[0]);
end;

function MatchHere(Pattern, Text: PChar; out MatchEnd: PChar; var GroupStart, GroupEnd: PChar): Boolean;
var
  ElementLength: Integer;
  Repeated: PChar;
begin
  MatchEnd := Text;
  if Pattern^ = #0 then
    Exit(True);
  if (Pattern[0] = '$') and (Pattern[1] = #0) then
    Exit(Text^ = #0);
  if (Pattern[0] = '\') and (Pattern[1] = '(') then
  begin
    GroupStart := Text;
    Exit(MatchHere(Pattern + 2, Text, MatchEnd, GroupStart, GroupEnd));
  end;
  if (Pattern[0] = '\') and (Pattern[1] = ')') then
  begin
    GroupEnd := Text;
    Exit(MatchHere(Pattern + 2, Text, MatchEnd, GroupStart, GroupEnd));
  end;

  MatchElement(Pattern, Text, ElementLength);
  if Pattern[ElementLength] = '*' then
  begin
    { Longest match first, then back off. }
    Repeated := Text;
    while MatchElement(Pattern, Repeated, ElementLength) do
      Inc(Repeated);
    while Repeated >= Text do
    begin
      if MatchHere(Pattern + ElementLength + 1, Repeated, MatchEnd, GroupStart, GroupEnd) then
        Exit(True);
      Dec(Repeated);
    end;
    Exit(False);
  end;
  if not MatchElement(Pattern, Text, ElementLength) then
    Exit(False);
  Result := MatchHere(Pattern + ElementLength, Text + 1, MatchEnd, GroupStart, GroupEnd);
end;

function MatchPattern(Text, Pattern: PChar): PChar;
var
  MatchEnd: PChar;
  GroupStart: PChar;
  GroupEnd: PChar;
  Length: PtrUInt;
begin
  GroupStart := nil;
  GroupEnd := nil;
  if Pattern^ = '^' then
    Inc(Pattern);
  if not MatchHere(Pattern, Text, MatchEnd, GroupStart, GroupEnd) then
  begin
    if FindText(Pattern, '\(') >= 0 then
      Exit(DuplicateText(''));
    Exit(MakeNumber(0));
  end;
  if (GroupStart <> nil) and (GroupEnd <> nil) and (GroupEnd >= GroupStart) then
  begin
    Length := GroupEnd - GroupStart;
    Result := PChar(AllocateMemory(Length + 1));
    CopyMemory(Result, GroupStart, Length);
    Result[Length] := #0;
  end
  else
    Result := MakeNumber(MatchEnd - Text);
end;

{ --- Grammar --------------------------------------------------------- }

function ParseOr: PChar; forward;

function ParsePrimary: PChar;
var
  Text: PChar;
  Start: Int64;
  Count: Int64;
  Length: Int64;
  Index: PtrInt;
  Characters: PChar;
  Found: Int64;
begin
  if Token(0) = nil then
    SyntaxError;
  if TokenIs('(') then
  begin
    Inc(Position);
    Result := ParseOr;
    if not TokenIs(')') then
      SyntaxError;
    Inc(Position);
    Exit;
  end;
  if TokenIs('length') and (Token(1) <> nil) then
  begin
    Result := MakeNumber(TextLength(Token(1)));
    Inc(Position, 2);
    Exit;
  end;
  if TokenIs('substr') and (Token(3) <> nil) then
  begin
    Text := Token(1);
    Length := TextLength(Text);
    Start := RequireNumber(Token(2));
    Count := RequireNumber(Token(3));
    Inc(Position, 4);
    if (Start < 1) or (Start > Length) or (Count < 1) then
      Exit(DuplicateText(''));
    if Start - 1 + Count > Length then
      Count := Length - Start + 1;
    Result := PChar(AllocateMemory(Count + 1));
    CopyMemory(Result, Text + Start - 1, Count);
    Result[Count] := #0;
    Exit;
  end;
  if TokenIs('index') and (Token(2) <> nil) then
  begin
    Text := Token(1);
    Characters := Token(2);
    Found := 0;
    Index := 0;
    while Text[Index] <> #0 do
    begin
      if FindCharacter(Characters, Text[Index]) >= 0 then
      begin
        Found := Index + 1;
        Break;
      end;
      Inc(Index);
    end;
    Inc(Position, 3);
    Exit(MakeNumber(Found));
  end;
  if TokenIs('+') and (Token(1) <> nil) then
    Inc(Position);
  Result := DuplicateText(Token(0));
  Inc(Position);
end;

function ParseMatch: PChar;
var
  Right: PChar;
  Matched: PChar;
begin
  Result := ParsePrimary;
  while TokenIs(':') do
  begin
    Inc(Position);
    Right := ParsePrimary;
    Matched := MatchPattern(Result, Right);
    FreeMemory(Result);
    FreeMemory(Right);
    Result := Matched;
  end;
end;

function ParseProduct: PChar;
var
  Operation: PChar;
  Left: Int64;
  Right: Int64;
  RightText: PChar;
begin
  Result := ParseMatch;
  while TokenIs('*') or TokenIs('/') or TokenIs('%') do
  begin
    Operation := Token(0);
    Inc(Position);
    RightText := ParseMatch;
    Left := RequireNumber(Result);
    Right := RequireNumber(RightText);
    FreeMemory(Result);
    FreeMemory(RightText);
    if (Operation[0] <> '*') and (Right = 0) then
    begin
      Report('division by zero', []);
      Halt(2);
    end;
    case Operation[0] of
      '*': Result := MakeNumber(Left * Right);
      '/': Result := MakeNumber(Left div Right);
    else
      Result := MakeNumber(Left mod Right);
    end;
  end;
end;

function ParseSum: PChar;
var
  IsAddition: Boolean;
  Left: Int64;
  Right: Int64;
  RightText: PChar;
begin
  Result := ParseProduct;
  while TokenIs('+') or TokenIs('-') do
  begin
    IsAddition := TokenIs('+');
    Inc(Position);
    RightText := ParseProduct;
    Left := RequireNumber(Result);
    Right := RequireNumber(RightText);
    FreeMemory(Result);
    FreeMemory(RightText);
    if IsAddition then
      Result := MakeNumber(Left + Right)
    else
      Result := MakeNumber(Left - Right);
  end;
end;

function ParseComparison: PChar;
var
  Operation: PChar;
  RightText: PChar;
  Left: Int64;
  Right: Int64;
  Order: Integer;
  Outcome: Boolean;
begin
  Result := ParseSum;
  while TokenIs('<') or TokenIs('<=') or TokenIs('=') or TokenIs('==') or
        TokenIs('!=') or TokenIs('>=') or TokenIs('>') do
  begin
    Operation := Token(0);
    Inc(Position);
    RightText := ParseSum;
    { Numbers compare as numbers, anything else as text. }
    if IsNumber(Result, Left) and IsNumber(RightText, Right) then
    begin
      if Left < Right then
        Order := -1
      else if Left > Right then
        Order := 1
      else
        Order := 0;
    end
    else
      Order := CompareText(Result, RightText);
    if TextIsEqual(Operation, '<') then
      Outcome := Order < 0
    else if TextIsEqual(Operation, '<=') then
      Outcome := Order <= 0
    else if TextIsEqual(Operation, '=') or TextIsEqual(Operation, '==') then
      Outcome := Order = 0
    else if TextIsEqual(Operation, '!=') then
      Outcome := Order <> 0
    else if TextIsEqual(Operation, '>=') then
      Outcome := Order >= 0
    else
      Outcome := Order > 0;
    FreeMemory(Result);
    FreeMemory(RightText);
    Result := MakeNumber(Ord(Outcome));
  end;
end;

function ParseAnd: PChar;
var
  Right: PChar;
begin
  Result := ParseComparison;
  while TokenIs('&') do
  begin
    Inc(Position);
    Right := ParseComparison;
    if IsNullOrZero(Result) or IsNullOrZero(Right) then
    begin
      FreeMemory(Result);
      Result := MakeNumber(0);
    end;
    FreeMemory(Right);
  end;
end;

function ParseOr: PChar;
var
  Right: PChar;
begin
  Result := ParseAnd;
  while TokenIs('|') do
  begin
    Inc(Position);
    Right := ParseAnd;
    if IsNullOrZero(Result) then
    begin
      FreeMemory(Result);
      if IsNullOrZero(Right) then
      begin
        Result := MakeNumber(0);
        FreeMemory(Right);
      end
      else
        Result := Right;
    end
    else
      FreeMemory(Right);
  end;
end;

var
  Outcome: PChar;
begin
  if ArgumentTotal < 2 then
  begin
    Report('missing operand', []);
    Halt(2);
  end;
  if (ArgumentTotal = 2) and TextIsEqual(Argument(1), '--help') then
  begin
    PrintLine('Usage: expr EXPRESSION');
    Halt(0);
  end;
  Position := 1;
  if TokenIs('--') then
    Inc(Position);
  Outcome := ParseOr;
  if Position < ArgumentTotal then
    SyntaxError;
  PrintLine(Outcome);
  if IsNullOrZero(Outcome) then
    Halt(1);
  Halt(0);
end.
