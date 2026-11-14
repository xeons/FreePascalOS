{
  test, [ - check file types and compare values

  test EXPRESSION
  [ EXPRESSION ]

  Exits with status 0 if EXPRESSION is true, 1 if false, 2 on an error.

    ( EXPR )  ! EXPR  EXPR -a EXPR  EXPR -o EXPR
    -n STRING  -z STRING  STRING  S1 = S2  S1 != S2  S1 < S2  S1 > S2
    N1 -eq N2  -ne  -lt  -le  -gt  -ge
    -e FILE  -f FILE  -d FILE  -h/-L FILE  -s FILE  -r/-w/-x FILE
}
program test;

{$mode objfpc}
{$pointermath on}

uses
  Abi.SystemCalls,
  Runtime.Text,
  Sys.Environment,
  Sys.Files,
  Sys.Format,
  Sys.Streams,
  Sys.Text,
  Util.Messages,
  Util.Paths;

const
  StatusTrue = 0;
  StatusFalse = 1;
  StatusError = 2;

var
  Words: PPChar;
  WordCount: Integer;
  Position: Integer;

procedure SyntaxError(Format: PChar; const Arguments: array of TFormatArgument);
begin
  Report(Format, Arguments);
  Halt(StatusError);
end;

function Peek(Offset: Integer): PChar;
begin
  if Position + Offset < WordCount then
    Result := Words[Position + Offset]
  else
    Result := nil;
end;

function PeekIs(Offset: Integer; Text: PChar): Boolean;
begin
  Result := (Peek(Offset) <> nil) and TextIsEqual(Peek(Offset), Text);
end;

function ParseNumber(Text: PChar): Int64;
begin
  if not ParseInteger(Text, Result) then
    SyntaxError('invalid integer ''%s''', [ArgumentText(Text)]);
end;

function IsBinaryOperator(Text: PChar): Boolean;
begin
  Result := (Text <> nil) and (TextIsEqual(Text, '=') or TextIsEqual(Text, '==') or
    TextIsEqual(Text, '!=') or TextIsEqual(Text, '<') or TextIsEqual(Text, '>') or
    TextIsEqual(Text, '-eq') or TextIsEqual(Text, '-ne') or TextIsEqual(Text, '-lt') or
    TextIsEqual(Text, '-le') or TextIsEqual(Text, '-gt') or TextIsEqual(Text, '-ge') or
    TextIsEqual(Text, '-nt') or TextIsEqual(Text, '-ot') or TextIsEqual(Text, '-ef'));
end;

function EvaluateBinary(Left, Operation, Right: PChar): Boolean;
var
  LeftInformation: TFileInformation;
  RightInformation: TFileInformation;
begin
  if TextIsEqual(Operation, '=') or TextIsEqual(Operation, '==') then
    Result := TextIsEqual(Left, Right)
  else if TextIsEqual(Operation, '!=') then
    Result := not TextIsEqual(Left, Right)
  else if TextIsEqual(Operation, '<') then
    Result := CompareText(Left, Right) < 0
  else if TextIsEqual(Operation, '>') then
    Result := CompareText(Left, Right) > 0
  else if TextIsEqual(Operation, '-eq') then
    Result := ParseNumber(Left) = ParseNumber(Right)
  else if TextIsEqual(Operation, '-ne') then
    Result := ParseNumber(Left) <> ParseNumber(Right)
  else if TextIsEqual(Operation, '-lt') then
    Result := ParseNumber(Left) < ParseNumber(Right)
  else if TextIsEqual(Operation, '-le') then
    Result := ParseNumber(Left) <= ParseNumber(Right)
  else if TextIsEqual(Operation, '-gt') then
    Result := ParseNumber(Left) > ParseNumber(Right)
  else if TextIsEqual(Operation, '-ge') then
    Result := ParseNumber(Left) >= ParseNumber(Right)
  else
  begin
    { File comparisons. }
    if (GetFileInformation(Left, LeftInformation) <> ErrorNone) or
       (GetFileInformation(Right, RightInformation) <> ErrorNone) then
      Exit(False);
    if TextIsEqual(Operation, '-nt') then
      Result := LeftInformation.ModificationTime > RightInformation.ModificationTime
    else if TextIsEqual(Operation, '-ot') then
      Result := LeftInformation.ModificationTime < RightInformation.ModificationTime
    else
      Result := LeftInformation.NodeNumber = RightInformation.NodeNumber;
  end;
end;

function EvaluateUnary(Operation, Operand: PChar): Boolean;
var
  Information: TFileInformation;
  Exists: Boolean;
begin
  case Operation[1] of
    'n': Exit(Operand^ <> #0);
    'z': Exit(Operand^ = #0);
    'h', 'L':
      Exit((GetLinkInformation(Operand, Information) = ErrorNone) and (Information.Kind = KindSymbolicLink));
  end;
  Exists := GetFileInformation(Operand, Information) = ErrorNone;
  case Operation[1] of
    'e', 'r', 'w': Result := Exists;
    'f': Result := Exists and (Information.Kind = KindFile);
    'd': Result := Exists and (Information.Kind = KindDirectory);
    'p': Result := Exists and (Information.Kind = KindFifo);
    's': Result := Exists and (Information.SizeInBytes > 0);
    'x': Result := Exists and ((Information.Kind = KindDirectory) or ((Information.Mode and $49) <> 0));
  else
    begin
      SyntaxError('''%s'': unary operator expected', [ArgumentText(Operation)]);
      Result := False;
    end;
  end;
end;

function IsUnaryOperator(Text: PChar): Boolean;
begin
  Result := (Text <> nil) and (Text[0] = '-') and (Text[1] in ['n', 'z', 'e', 'f', 'd', 'h', 'L', 'p', 's', 'r', 'w', 'x']) and
    (Text[2] = #0);
end;

function ParseOr: Boolean; forward;

function ParsePrimary: Boolean;
var
  Operand: PChar;
begin
  if Peek(0) = nil then
    SyntaxError('argument expected', []);

  if PeekIs(0, '!') and not IsBinaryOperator(Peek(1)) then
  begin
    Inc(Position);
    Exit(not ParsePrimary());
  end;
  if PeekIs(0, '(') and not IsBinaryOperator(Peek(1)) then
  begin
    Inc(Position);
    Result := ParseOr;
    if not PeekIs(0, ')') then
      SyntaxError('missing '')''', []);
    Inc(Position);
    Exit;
  end;
  if IsBinaryOperator(Peek(1)) and (Peek(2) <> nil) then
  begin
    Result := EvaluateBinary(Peek(0), Peek(1), Peek(2));
    Inc(Position, 3);
    Exit;
  end;
  if IsUnaryOperator(Peek(0)) and (Peek(1) <> nil) then
  begin
    Result := EvaluateUnary(Peek(0), Peek(1));
    Inc(Position, 2);
    Exit;
  end;
  { A lone string is true when it is not empty. }
  Operand := Peek(0);
  Inc(Position);
  Result := Operand^ <> #0;
end;

function ParseAnd: Boolean;
var
  Right: Boolean;
begin
  Result := ParsePrimary;
  while PeekIs(0, '-a') do
  begin
    Inc(Position);
    Right := ParsePrimary;
    Result := Result and Right;
  end;
end;

function ParseOr: Boolean;
var
  Right: Boolean;
begin
  Result := ParseAnd;
  while PeekIs(0, '-o') do
  begin
    Inc(Position);
    Right := ParseAnd;
    Result := Result or Right;
  end;
end;

var
  Name: PChar;
  Outcome: Boolean;
begin
  Name := BaseName(Argument(0));
  Words := ArgumentValues + 1;
  WordCount := ArgumentTotal - 1;
  if TextIsEqual(Name, '[') then
  begin
    if (WordCount = 1) and TextIsEqual(Words[0], '--help') then
    begin
      PrintLine('Usage: [ EXPRESSION ]');
      Halt(0);
    end;
    if (WordCount = 0) or not TextIsEqual(Words[WordCount - 1], ']') then
      SyntaxError('missing '']''', []);
    Dec(WordCount);
  end;

  if WordCount = 0 then
    Halt(StatusFalse);
  Position := 0;
  Outcome := ParseOr;
  if Position < WordCount then
    SyntaxError('extra argument ''%s''', [ArgumentText(Words[Position])]);
  if Outcome then
    Halt(StatusTrue);
  Halt(StatusFalse);
end.
