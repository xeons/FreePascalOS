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
{$H+}

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Files,
  Util.CommandLine,
  Util.Messages,
  Util.Numbers,
  Util.Output;

const
  StatusTrue = 0;
  StatusFalse = 1;
  StatusError = 2;

type
  { Evaluates the words of an expression, from the left. }
  TExpressionEvaluator = class
  private
    FWords: array of string;
    FPosition: Integer;
    function HasWord(Offset: Integer): Boolean;
    function Peek(Offset: Integer): string;
    function PeekIs(Offset: Integer; const Text: string): Boolean;
    function PeekIsBinaryOperator(Offset: Integer): Boolean;
    function PeekIsUnaryOperator(Offset: Integer): Boolean;
    function ParsePrimary: Boolean;
    function ParseAnd: Boolean;
    function ParseOr: Boolean;
  public
    constructor Create(const Words: array of string);
    { The value of the whole expression; ends the program on errors. }
    function Evaluate: Boolean;
  end;

procedure SyntaxError(const Message: string);
begin
  Report(Message);
  Halt(StatusError);
end;

function ParseNumber(const Text: string): Int64;
begin
  if not ParseDecimal(Text, Result) then
    SyntaxError(Format('invalid integer ''%s''', [Text]));
end;

function IsBinaryOperator(const Text: string): Boolean;
begin
  case Text of
    '=', '==', '!=', '<', '>', '-eq', '-ne', '-lt', '-le', '-gt', '-ge', '-nt', '-ot', '-ef':
      Result := True;
  else
    Result := False;
  end;
end;

function IsUnaryOperator(const Text: string): Boolean;
begin
  Result := (Length(Text) = 2) and (Text[1] = '-') and
    (Text[2] in ['n', 'z', 'e', 'f', 'd', 'h', 'L', 'p', 'c', 'b', 's', 'r', 'w', 'x']);
end;

function CompareFiles(const Left, Operation, Right: string): Boolean;
var
  LeftInformation: TFileInformation;
  RightInformation: TFileInformation;
begin
  if (GetFileInformation(PChar(Left), LeftInformation) <> ErrorNone) or
     (GetFileInformation(PChar(Right), RightInformation) <> ErrorNone) then
    Exit(False);
  if Operation = '-nt' then
    Result := LeftInformation.ModificationTime > RightInformation.ModificationTime
  else if Operation = '-ot' then
    Result := LeftInformation.ModificationTime < RightInformation.ModificationTime
  else
    Result := LeftInformation.NodeNumber = RightInformation.NodeNumber;
end;

function EvaluateBinary(const Left, Operation, Right: string): Boolean;
begin
  case Operation of
    '=', '==': Result := Left = Right;
    '!=': Result := Left <> Right;
    '<': Result := CompareStr(Left, Right) < 0;
    '>': Result := CompareStr(Left, Right) > 0;
    '-eq': Result := ParseNumber(Left) = ParseNumber(Right);
    '-ne': Result := ParseNumber(Left) <> ParseNumber(Right);
    '-lt': Result := ParseNumber(Left) < ParseNumber(Right);
    '-le': Result := ParseNumber(Left) <= ParseNumber(Right);
    '-gt': Result := ParseNumber(Left) > ParseNumber(Right);
    '-ge': Result := ParseNumber(Left) >= ParseNumber(Right);
  else
    Result := CompareFiles(Left, Operation, Right);
  end;
end;

function EvaluateUnary(const Operation, Operand: string): Boolean;
var
  Information: TFileInformation;
  Exists: Boolean;
begin
  case Operation[2] of
    'n': Exit(Operand <> '');
    'z': Exit(Operand = '');
    'h', 'L':
      Exit((GetLinkInformation(PChar(Operand), Information) = ErrorNone) and
        (Information.Kind = KindSymbolicLink));
  end;
  Exists := GetFileInformation(PChar(Operand), Information) = ErrorNone;
  case Operation[2] of
    'e', 'r', 'w': Result := Exists;
    'f': Result := Exists and (Information.Kind = KindFile);
    'd': Result := Exists and (Information.Kind = KindDirectory);
    'p': Result := Exists and (Information.Kind = KindFifo);
    'c': Result := Exists and (Information.Kind = KindCharacterDevice);
    'b': Result := Exists and (Information.Kind = KindBlockDevice);
    's': Result := Exists and (Information.SizeInBytes > 0);
    'x': Result := Exists and ((Information.Kind = KindDirectory) or ((Information.Mode and $49) <> 0));
  else
    begin
      SyntaxError(Format('''%s'': unary operator expected', [Operation]));
      Result := False;
    end;
  end;
end;

constructor TExpressionEvaluator.Create(const Words: array of string);
var
  Index: Integer;
begin
  inherited Create;
  SetLength(FWords, Length(Words));
  for Index := 0 to High(Words) do
    FWords[Index] := Words[Index];
  FPosition := 0;
end;

function TExpressionEvaluator.HasWord(Offset: Integer): Boolean;
begin
  Result := FPosition + Offset < Length(FWords);
end;

function TExpressionEvaluator.Peek(Offset: Integer): string;
begin
  if HasWord(Offset) then
    Result := FWords[FPosition + Offset]
  else
    Result := '';
end;

function TExpressionEvaluator.PeekIs(Offset: Integer; const Text: string): Boolean;
begin
  Result := HasWord(Offset) and (Peek(Offset) = Text);
end;

function TExpressionEvaluator.PeekIsBinaryOperator(Offset: Integer): Boolean;
begin
  Result := HasWord(Offset) and IsBinaryOperator(Peek(Offset));
end;

function TExpressionEvaluator.PeekIsUnaryOperator(Offset: Integer): Boolean;
begin
  Result := HasWord(Offset) and IsUnaryOperator(Peek(Offset));
end;

function TExpressionEvaluator.ParsePrimary: Boolean;
begin
  if not HasWord(0) then
    SyntaxError('argument expected');

  if PeekIs(0, '!') and not PeekIsBinaryOperator(1) then
  begin
    Inc(FPosition);
    Exit(not ParsePrimary());
  end;
  if PeekIs(0, '(') and not PeekIsBinaryOperator(1) then
  begin
    Inc(FPosition);
    Result := ParseOr;
    if not PeekIs(0, ')') then
      SyntaxError('missing '')''');
    Inc(FPosition);
    Exit;
  end;
  if PeekIsBinaryOperator(1) and HasWord(2) then
  begin
    Result := EvaluateBinary(Peek(0), Peek(1), Peek(2));
    Inc(FPosition, 3);
    Exit;
  end;
  if PeekIsUnaryOperator(0) and HasWord(1) then
  begin
    Result := EvaluateUnary(Peek(0), Peek(1));
    Inc(FPosition, 2);
    Exit;
  end;
  { A lone string is true when it is not empty. }
  Result := Peek(0) <> '';
  Inc(FPosition);
end;

function TExpressionEvaluator.ParseAnd: Boolean;
var
  Right: Boolean;
begin
  Result := ParsePrimary;
  while PeekIs(0, '-a') do
  begin
    Inc(FPosition);
    Right := ParsePrimary;
    Result := Result and Right;
  end;
end;

function TExpressionEvaluator.ParseOr: Boolean;
var
  Right: Boolean;
begin
  Result := ParseAnd;
  while PeekIs(0, '-o') do
  begin
    Inc(FPosition);
    Right := ParseAnd;
    Result := Result or Right;
  end;
end;

function TExpressionEvaluator.Evaluate: Boolean;
begin
  FPosition := 0;
  Result := ParseOr;
  if FPosition < Length(FWords) then
    SyntaxError(Format('extra argument ''%s''', [FWords[FPosition]]));
end;

var
  Name: string;
  Words: TStringArray;
  Evaluator: TExpressionEvaluator;
  Outcome: Boolean;
begin
  Name := ProgramName;
  Words := ProgramArguments;
  if Name = '[' then
  begin
    if (Length(Words) = 1) and (Words[0] = '--help') then
    begin
      PrintStringLine('Usage: [ EXPRESSION ]');
      Halt(0);
    end;
    if (Length(Words) = 0) or (Words[High(Words)] <> ']') then
      SyntaxError('missing '']''');
    SetLength(Words, Length(Words) - 1);
  end;

  if Length(Words) = 0 then
    Halt(StatusFalse);
  Evaluator := TExpressionEvaluator.Create(Words);
  try
    Outcome := Evaluator.Evaluate;
  finally
    Evaluator.Free;
  end;
  if Outcome then
    Halt(StatusTrue);
  Halt(StatusFalse);
end.
