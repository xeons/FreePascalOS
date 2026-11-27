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
  The calculator behind the keys: what was typed, the expression built
  up, memory and history, as a pocket calculator (and the Windows one)
  behaves.

  Digits and the point type a number (MaximumTypedDigits at most); an
  operator puts the number and itself into the expression; a function
  (square root, sine...) applies at once to the number shown and shows
  its result; parentheses group; Equals evaluates the expression
  (Calculator.Expressions: left to right in the standard mode, by
  precedence otherwise) and adds it to the history; Equals again
  repeats the last operation (5 + 3 = = gives 11). Percent is of the
  number before a + or - (50 + 10 % is 50 + 5), else a hundredth.
  Backspace takes back a digit, Clear Entry the number, Clear all but
  memory and history. An error (division by zero, a square root of a
  negative number) is shown until the next key.

  In the programmer mode numbers are integers of the word size
  (Calculator.Numbers), typed and shown in the base chosen; the bit
  operators join the others and the point does nothing.

  The expression is kept as text the evaluator reads, each token
  apart ("12 * ( 3 + 4 )"), and shown prettier ("12 × (3 + 4)").

  Plain logic: the host checks it (make apps-test).
}
unit Calculator.Engine;

{$mode objfpc}
{$H+}

interface

uses
  Calculator.MathFunctions,
  Calculator.Expressions;

type
  TCalculatorMode = (ModeStandard, ModeScientific, ModeProgrammer);

  TEntryState = (
    { Nothing typed since an operator, a parenthesis or Clear: the value
      shown is the operand if one is needed. }
    EntryStart,
    EntryTyping,
    { A value from a function, a constant, memory or the history, with
      the expression that gives it (FOperandText). }
    EntryComputed,
    { A closed group, already in the expression, is the operand. }
    EntryGroup,
    { Equals was pressed: the value is the result. }
    EntryResult);

  THistoryEntry = record
    Expression: string;
    Result: string;
    Value: TCalculatorValue;
  end;

  TCalculatorEngine = class
  private
    FMode: TCalculatorMode;
    FAngles: TAngleUnit;
    FBase: LongInt;
    FWordBits: LongInt;
    FState: TEntryState;
    FTokens: string;
    FGroupStarts: array of LongInt;
    FOperandStart: LongInt;
    FEntry: string;
    FValue: TCalculatorValue;
    FOperandText: string;
    FShownExpression: string;
    FError: TCalculationError;
    FMemory: TCalculatorValue;
    FHasMemory: Boolean;
    FRepeatOperator: string;
    FRepeatOperand: string;
    FHistory: array of THistoryEntry;
    function Settings: TEvaluationSettings;
    function IsProgrammer: Boolean;
    function ValueText(const Value: TCalculatorValue): string;
    function OperandOfValue(const Value: TCalculatorValue): string;
    function CurrentOperandText: string;
    function Evaluate(const Text: string; out Value: TCalculatorValue): Boolean;
    function LastToken: string;
    function EndsWithOperator: Boolean;
    function OpenCount: LongInt;
    function CurrentGroupStart: LongInt;
    procedure StartFresh;
    procedure DropGroupOperand;
    procedure AppendToken(const Token: string);
    procedure AppendOperand;
    procedure UpdateValueFromEntry;
    procedure ShowComputed(const Text: string; const Value: TCalculatorValue);
    procedure ShowRunningValue(const Operation: string);
    procedure SetError(Error: TCalculationError; const Expression: string);
    function TypedDigitFits(const Candidate: string): Boolean;
    function GetHistoryCount: LongInt;
    function GetHistory(Index: LongInt): THistoryEntry;
    procedure SetMode(Value: TCalculatorMode);
    procedure SetBase(Value: LongInt);
    procedure SetWordBits(Value: LongInt);
  public
    constructor Create;
    { Digit is 0 to 15 (above 9 only in base 16). }
    procedure TypeDigit(Digit: LongInt);
    procedure TypePoint;
    procedure ApplyOperator(Operation: TBinaryOperator);
    procedure ApplyFunction(Operation: TUnaryFunction);
    { Changes the sign of the number being typed, else applies negate. }
    procedure Negate;
    procedure BitwiseNot;
    procedure OpenParenthesis;
    procedure CloseParenthesis;
    procedure ComputeResult;
    procedure Percent;
    procedure InsertPi;
    procedure InsertEuler;
    procedure Backspace;
    procedure ClearEntry;
    procedure ClearAll;
    procedure MemoryClear;
    procedure MemoryRecall;
    procedure MemoryStore;
    procedure MemoryAdd;
    procedure MemorySubtract;
    { Takes Text as the number shown: a number of the base, or an
      expression that evaluates; False if it is neither. }
    function Paste(const Text: string): Boolean;
    { The history's entry Index becomes the number shown. }
    procedure RecallHistory(Index: LongInt);
    procedure ClearHistory;
    { The number shown (an error's text if there is one). }
    function DisplayText: string;
    { The number shown, to copy ('' while an error is shown). }
    function CopyText: string;
    { The expression above it ("12 × (3 + 4) =" after Equals). }
    function ExpressionText: string;
    function HasError: Boolean;
    property Mode: TCalculatorMode read FMode write SetMode;
    property Angles: TAngleUnit read FAngles write FAngles;
    { 2, 8, 10 or 16 (the programmer mode). }
    property Base: LongInt read FBase write SetBase;
    { 8, 16, 32 or 64 (the programmer mode). }
    property WordBits: LongInt read FWordBits write SetWordBits;
    property Value: TCalculatorValue read FValue;
    property State: TEntryState read FState;
    property HasMemory: Boolean read FHasMemory;
    property Memory: TCalculatorValue read FMemory;
    property HistoryCount: LongInt read GetHistoryCount;
    property History[Index: LongInt]: THistoryEntry read GetHistory;
  end;

const
  OperatorTokens: array[TBinaryOperator] of string = ('+', '-', '*', '/', '^', 'yroot', 'mod', 'and', 'or', 'xor',
    'lsh', 'rsh');
  MaximumHistory = 100;

{ The expression as shown: × ÷ −, √, π, no spaces inside parentheses. }
function PrettyExpression(const Text: string): string;

implementation

uses
  SysUtils,
  Calculator.Numbers;

function MakeValue(Real: Double; Whole: Int64): TCalculatorValue;
begin
  Result.Real := Real;
  Result.Whole := Whole;
end;

function PrettyExpression(const Text: string): string;
begin
  Result := ' ' + Trim(Text) + ' ';
  Result := StringReplace(Result, ' * ', ' ' + #$C3#$97 + ' ', [rfReplaceAll]);
  Result := StringReplace(Result, ' / ', ' ' + #$C3#$B7 + ' ', [rfReplaceAll]);
  Result := StringReplace(Result, ' - ', ' ' + #$E2#$88#$92 + ' ', [rfReplaceAll]);
  Result := StringReplace(Result, '( ', '(', [rfReplaceAll]);
  Result := StringReplace(Result, ' )', ')', [rfReplaceAll]);
  Result := StringReplace(Result, 'sqrt(', #$E2#$88#$9A + '(', [rfReplaceAll]);
  Result := StringReplace(Result, 'cbrt(', #$E2#$88#$9B + '(', [rfReplaceAll]);
  Result := StringReplace(Result, 'recip(', '1/(', [rfReplaceAll]);
  Result := StringReplace(Result, 'tenpow(', '10^(', [rfReplaceAll]);
  Result := StringReplace(Result, 'exp(', 'e^(', [rfReplaceAll]);
  Result := StringReplace(Result, 'pi', #$CF#$80, [rfReplaceAll]);
  Result := Trim(Result);
end;

constructor TCalculatorEngine.Create;
begin
  inherited Create;
  FMode := ModeStandard;
  FAngles := AngleDegrees;
  FBase := 10;
  FWordBits := 64;
  ClearAll;
end;

function TCalculatorEngine.IsProgrammer: Boolean;
begin
  Result := FMode = ModeProgrammer;
end;

function TCalculatorEngine.Settings: TEvaluationSettings;
begin
  Result := DefaultEvaluationSettings;
  if FMode = ModeStandard then
    Result.Order := OrderLeftToRight;
  Result.Angles := FAngles;
  Result.Integers := IsProgrammer;
  Result.WordBits := FWordBits;
end;

function TCalculatorEngine.ValueText(const Value: TCalculatorValue): string;
begin
  if IsProgrammer then
    Result := FormatInBase(Value.Whole, FBase, FWordBits)
  else
    Result := FormatCalculatorNumber(Value.Real);
end;

{ A value as the evaluator reads it: exactly what is shown. }
function TCalculatorEngine.OperandOfValue(const Value: TCalculatorValue): string;
begin
  if IsProgrammer then
    Result := IntToStr(Value.Whole)
  else
    Result := FormatCalculatorNumber(Value.Real);
end;

function TCalculatorEngine.Evaluate(const Text: string; out Value: TCalculatorValue): Boolean;
var
  Error: TCalculationError;
begin
  Result := EvaluateExpression(Text, Settings, Value, Error);
  if Result and not IsProgrammer then
    Value.Real := RoundToShown(Value.Real);
  if not Result then
    SetError(Error, Text);
end;

procedure TCalculatorEngine.SetError(Error: TCalculationError; const Expression: string);
begin
  FError := Error;
  FShownExpression := PrettyExpression(Expression);
end;

function TCalculatorEngine.HasError: Boolean;
begin
  Result := FError <> CalculationOk;
end;

function TCalculatorEngine.LastToken: string;
var
  Trimmed: string;
  Space: LongInt;
begin
  Trimmed := TrimRight(FTokens);
  Space := Length(Trimmed);
  while (Space > 0) and (Trimmed[Space] <> ' ') do
    Dec(Space);
  Result := Copy(Trimmed, Space + 1, Length(Trimmed) - Space);
end;

function TCalculatorEngine.EndsWithOperator: Boolean;
var
  Last: string;
  Operation: TBinaryOperator;
begin
  Last := LastToken;
  for Operation := Low(TBinaryOperator) to High(TBinaryOperator) do
    if OperatorTokens[Operation] = Last then
      Exit(True);
  Result := False;
end;

function TCalculatorEngine.OpenCount: LongInt;
begin
  Result := Length(FGroupStarts);
end;

{ Where the innermost open group's contents start (1: the whole). }
function TCalculatorEngine.CurrentGroupStart: LongInt;
begin
  if OpenCount = 0 then
    Result := 1
  else
    Result := FGroupStarts[High(FGroupStarts)] + 1;
end;

procedure TCalculatorEngine.AppendToken(const Token: string);
begin
  FTokens := FTokens + ' ' + Token;
end;

function TCalculatorEngine.CurrentOperandText: string;
begin
  case FState of
    EntryTyping:
      if IsProgrammer then
        Result := IntToStr(FValue.Whole)
      else
        Result := FormatCalculatorNumber(FValue.Real);
    EntryComputed: Result := FOperandText;
    EntryGroup: Result := Trim(Copy(FTokens, FOperandStart, Length(FTokens)));
  else
    Result := OperandOfValue(FValue);
  end;
end;

{ A new calculation after a result. }
procedure TCalculatorEngine.StartFresh;
begin
  FTokens := '';
  SetLength(FGroupStarts, 0);
  FShownExpression := '';
end;

{ The closed group that was the operand leaves the expression (a
  function or a new number takes its place). }
procedure TCalculatorEngine.DropGroupOperand;
begin
  if FState = EntryGroup then
    SetLength(FTokens, FOperandStart - 1);
end;

procedure TCalculatorEngine.AppendOperand;
begin
  if FState = EntryResult then
    StartFresh;
  if FState <> EntryGroup then
    AppendToken(CurrentOperandText);
end;

procedure TCalculatorEngine.UpdateValueFromEntry;
var
  Real: Double;
  Whole: Int64;
begin
  if IsProgrammer then
  begin
    if not ParseInBase(FEntry, FBase, FWordBits, Whole) then
      Whole := 0;
    FValue := MakeValue(0, Whole);
  end
  else
  begin
    if not ParseCalculatorNumber(FEntry, Real) then
      Real := 0;
    FValue := MakeValue(Real, 0);
  end;
end;

procedure TCalculatorEngine.ShowComputed(const Text: string; const Value: TCalculatorValue);
begin
  FOperandText := Text;
  FValue := Value;
  FState := EntryComputed;
end;

{ After an operator: the value so far where it is plain what it is (left
  to right, or a + or - closing what came before). }
procedure TCalculatorEngine.ShowRunningValue(const Operation: string);
var
  Prefix: string;
  Running: TCalculatorValue;
  Error: TCalculationError;
begin
  if (FMode <> ModeStandard) and (Operation <> '+') and (Operation <> '-') and (Operation <> 'or') then
    Exit;
  Prefix := Copy(FTokens, CurrentGroupStart, Length(FTokens));
  { Without the operator just added. }
  SetLength(Prefix, Length(TrimRight(Prefix)) - Length(Operation));
  if Trim(Prefix) = '' then
    Exit;
  if EvaluateExpression(Prefix, Settings, Running, Error) then
  begin
    if not IsProgrammer then
      Running.Real := RoundToShown(Running.Real);
    FValue := Running;
  end;
end;

function TCalculatorEngine.TypedDigitFits(const Candidate: string): Boolean;
var
  Digits: LongInt;
  Index: LongInt;
  Whole: Int64;
begin
  if not IsProgrammer then
  begin
    Digits := 0;
    for Index := 1 to Length(Candidate) do
      if Candidate[Index] in ['0'..'9'] then
        Inc(Digits);
    Exit(Digits <= MaximumTypedDigits);
  end;
  if not ParseInBase(Candidate, FBase, 64, Whole) then
    Exit(False);
  if FBase = 10 then
    Result := WrapToWord(Whole, FWordBits) = Whole
  else
    Result := (FWordBits >= 64) or ((QWord(Whole) shr FWordBits) = 0);
end;

{ --- Typing ----------------------------------------------------------------------- }

procedure TCalculatorEngine.TypeDigit(Digit: LongInt);
const
  DigitCharacters = '0123456789ABCDEF';
var
  Candidate: string;
begin
  if (Digit < 0) or (Digit >= FBase) then
    Exit;
  if HasError then
    ClearAll;
  if FState = EntryResult then
    StartFresh;
  DropGroupOperand;
  if FState <> EntryTyping then
    FEntry := '0';
  Candidate := FEntry;
  if Candidate = '0' then
    Candidate := ''
  else if Candidate = '-0' then
    Candidate := '-';
  Candidate := Candidate + DigitCharacters[Digit + 1];
  if not TypedDigitFits(Candidate) then
  begin
    FState := EntryTyping;
    Exit;
  end;
  FEntry := Candidate;
  FState := EntryTyping;
  UpdateValueFromEntry;
end;

procedure TCalculatorEngine.TypePoint;
begin
  if IsProgrammer then
    Exit;
  if HasError then
    ClearAll;
  if FState = EntryResult then
    StartFresh;
  DropGroupOperand;
  if FState <> EntryTyping then
    FEntry := '0';
  if Pos('.', FEntry) = 0 then
    FEntry := FEntry + '.';
  FState := EntryTyping;
  UpdateValueFromEntry;
end;

procedure TCalculatorEngine.Negate;
begin
  if HasError then
    Exit;
  { Only decimal numbers are typed with a sign; in the other bases the
    word is negated. }
  if (FState <> EntryTyping) or (IsProgrammer and (FBase <> 10)) then
  begin
    ApplyFunction(FunctionNegate);
    Exit;
  end;
  if (FEntry <> '') and (FEntry[1] = '-') then
    Delete(FEntry, 1, 1)
  else if FEntry <> '0' then
    FEntry := '-' + FEntry;
  UpdateValueFromEntry;
end;

procedure TCalculatorEngine.Backspace;
begin
  if HasError then
  begin
    ClearEntry;
    Exit;
  end;
  if FState = EntryResult then
  begin
    FShownExpression := '';
    Exit;
  end;
  if FState <> EntryTyping then
    Exit;
  Delete(FEntry, Length(FEntry), 1);
  if (FEntry = '') or (FEntry = '-') then
    FEntry := '0';
  UpdateValueFromEntry;
end;

procedure TCalculatorEngine.ClearEntry;
begin
  if FState = EntryResult then
  begin
    ClearAll;
    Exit;
  end;
  FError := CalculationOk;
  DropGroupOperand;
  FEntry := '0';
  FState := EntryTyping;
  UpdateValueFromEntry;
end;

procedure TCalculatorEngine.ClearAll;
begin
  StartFresh;
  FError := CalculationOk;
  FEntry := '0';
  FOperandText := '';
  FValue := MakeValue(0, 0);
  FState := EntryStart;
  FRepeatOperator := '';
  FRepeatOperand := '';
end;

{ --- Operators and functions ----------------------------------------------------------- }

procedure TCalculatorEngine.ApplyOperator(Operation: TBinaryOperator);
var
  Token: string;
begin
  if HasError then
    Exit;
  Token := OperatorTokens[Operation];
  if (FState = EntryStart) and EndsWithOperator then
  begin
    { Another operator in place of the last. }
    SetLength(FTokens, Length(TrimRight(FTokens)) - Length(LastToken));
    FTokens := TrimRight(FTokens);
  end
  else
    AppendOperand;
  AppendToken(Token);
  FState := EntryStart;
  ShowRunningValue(Token);
end;

procedure TCalculatorEngine.ApplyFunction(Operation: TUnaryFunction);
var
  Text: string;
  Computed: TCalculatorValue;
begin
  if HasError then
    Exit;
  Text := UnaryFunctionNames[Operation] + '(' + CurrentOperandText + ')';
  if FState = EntryResult then
    StartFresh;
  DropGroupOperand;
  if not Evaluate(Text, Computed) then
    Exit;
  ShowComputed(Text, Computed);
end;

procedure TCalculatorEngine.BitwiseNot;
var
  Text: string;
  Computed: TCalculatorValue;
begin
  if HasError or not IsProgrammer then
    Exit;
  Text := 'not(' + CurrentOperandText + ')';
  if FState = EntryResult then
    StartFresh;
  DropGroupOperand;
  if Evaluate(Text, Computed) then
    ShowComputed(Text, Computed);
end;

procedure TCalculatorEngine.OpenParenthesis;
var
  Multiplies: Boolean;
begin
  if HasError then
    Exit;
  { A number before a parenthesis multiplies it. }
  Multiplies := (FState in [EntryComputed, EntryGroup]) or ((FState = EntryTyping) and (FEntry <> '0'));
  if FState = EntryResult then
    StartFresh
  else if Multiplies then
  begin
    AppendOperand;
    AppendToken('*');
  end;
  AppendToken('(');
  SetLength(FGroupStarts, Length(FGroupStarts) + 1);
  FGroupStarts[High(FGroupStarts)] := Length(FTokens);
  FEntry := '0';
  FValue := MakeValue(0, 0);
  FState := EntryStart;
end;

procedure TCalculatorEngine.CloseParenthesis;
var
  Group: TCalculatorValue;
begin
  if HasError or (OpenCount = 0) then
    Exit;
  AppendOperand;
  AppendToken(')');
  FOperandStart := FGroupStarts[High(FGroupStarts)];
  SetLength(FGroupStarts, Length(FGroupStarts) - 1);
  FState := EntryGroup;
  if Evaluate(Copy(FTokens, FOperandStart, Length(FTokens)), Group) then
    FValue := Group;
end;

procedure TCalculatorEngine.ComputeResult;
var
  Full: string;
  Outcome: TCalculatorValue;
  Entry: THistoryEntry;
  Index: LongInt;
begin
  if HasError then
  begin
    ClearAll;
    Exit;
  end;
  if FState = EntryResult then
  begin
    if FRepeatOperator = '' then
      Exit;
    Full := OperandOfValue(FValue) + ' ' + FRepeatOperator + ' ' + FRepeatOperand;
  end
  else
  begin
    { What Equals again repeats: the last operator and its operand. }
    FRepeatOperator := '';
    FRepeatOperand := '';
    if (FState <> EntryGroup) and (OpenCount = 0) and EndsWithOperator then
    begin
      FRepeatOperator := LastToken;
      FRepeatOperand := CurrentOperandText;
    end;
    AppendOperand;
    Full := FTokens;
    for Index := 1 to OpenCount do
      Full := Full + ' )';
  end;
  Full := Trim(Full);
  if not Evaluate(Full, Outcome) then
    Exit;
  Entry.Expression := PrettyExpression(Full) + ' =';
  Entry.Value := Outcome;
  Entry.Result := ValueText(Outcome);
  FValue := Outcome;
  if Length(FHistory) >= MaximumHistory then
    Delete(FHistory, 0, 1);
  SetLength(FHistory, Length(FHistory) + 1);
  FHistory[High(FHistory)] := Entry;
  StartFresh;
  FShownExpression := Entry.Expression;
  FState := EntryResult;
end;

procedure TCalculatorEngine.Percent;
var
  Left: TCalculatorValue;
  Prefix: string;
  Error: TCalculationError;
  Share: Double;
begin
  if HasError or IsProgrammer then
    Exit;
  Share := FValue.Real / 100;
  if (FState <> EntryResult) and (OpenCount = 0) and (FState <> EntryGroup) and
     ((LastToken = '+') or (LastToken = '-')) then
  begin
    Prefix := Copy(FTokens, 1, Length(TrimRight(FTokens)) - 1);
    if EvaluateExpression(Prefix, Settings, Left, Error) then
      Share := Left.Real * FValue.Real / 100;
  end;
  if FState = EntryResult then
    StartFresh;
  DropGroupOperand;
  Left := MakeValue(RoundToShown(Share), 0);
  ShowComputed(FormatCalculatorNumber(Left.Real), Left);
end;

procedure TCalculatorEngine.InsertPi;
begin
  if IsProgrammer then
    Exit;
  if HasError then
    ClearAll;
  if FState = EntryResult then
    StartFresh;
  DropGroupOperand;
  ShowComputed('pi', MakeValue(RoundToShown(Pi), 0));
end;

procedure TCalculatorEngine.InsertEuler;
begin
  if IsProgrammer then
    Exit;
  if HasError then
    ClearAll;
  if FState = EntryResult then
    StartFresh;
  DropGroupOperand;
  ShowComputed('e', MakeValue(RoundToShown(Exp(1)), 0));
end;

{ --- Memory and history ------------------------------------------------------------------ }

procedure TCalculatorEngine.MemoryClear;
begin
  FHasMemory := False;
  FMemory := MakeValue(0, 0);
end;

procedure TCalculatorEngine.MemoryRecall;
begin
  if not FHasMemory then
    Exit;
  if HasError then
    ClearAll;
  if FState = EntryResult then
    StartFresh;
  DropGroupOperand;
  ShowComputed(OperandOfValue(FMemory), FMemory);
end;

procedure TCalculatorEngine.MemoryStore;
begin
  if HasError then
    Exit;
  FMemory := FValue;
  FHasMemory := True;
end;

procedure TCalculatorEngine.MemoryAdd;
var
  Error: TCalculationError;
begin
  if HasError then
    Exit;
  Error := CalculationOk;
  if IsProgrammer then
    FMemory.Whole := ApplyIntegerBinary(OperatorAdd, FMemory.Whole, FValue.Whole, FWordBits, Error)
  else
    FMemory.Real := RoundToShown(ApplyBinary(OperatorAdd, FMemory.Real, FValue.Real, Error));
  FHasMemory := True;
end;

procedure TCalculatorEngine.MemorySubtract;
var
  Error: TCalculationError;
begin
  if HasError then
    Exit;
  Error := CalculationOk;
  if IsProgrammer then
    FMemory.Whole := ApplyIntegerBinary(OperatorSubtract, FMemory.Whole, FValue.Whole, FWordBits, Error)
  else
    FMemory.Real := RoundToShown(ApplyBinary(OperatorSubtract, FMemory.Real, FValue.Real, Error));
  FHasMemory := True;
end;

function TCalculatorEngine.GetHistoryCount: LongInt;
begin
  Result := Length(FHistory);
end;

function TCalculatorEngine.GetHistory(Index: LongInt): THistoryEntry;
begin
  Result := FHistory[Index];
end;

procedure TCalculatorEngine.RecallHistory(Index: LongInt);
begin
  if (Index < 0) or (Index >= Length(FHistory)) then
    Exit;
  if HasError then
    ClearAll;
  if FState = EntryResult then
    StartFresh;
  DropGroupOperand;
  ShowComputed(OperandOfValue(FHistory[Index].Value), FHistory[Index].Value);
end;

procedure TCalculatorEngine.ClearHistory;
begin
  SetLength(FHistory, 0);
end;

function TCalculatorEngine.Paste(const Text: string): Boolean;
var
  Cleaned: string;
  Real: Double;
  Whole: Int64;
  Computed: TCalculatorValue;
  Error: TCalculationError;
begin
  Cleaned := Trim(Text);
  if Cleaned = '' then
    Exit(False);
  if IsProgrammer and ParseInBase(Cleaned, FBase, FWordBits, Whole) then
    Computed := MakeValue(0, Whole)
  else if not IsProgrammer and ParseCalculatorNumber(Cleaned, Real) then
    Computed := MakeValue(RoundToShown(Real), 0)
  else if EvaluateExpression(Cleaned, Settings, Computed, Error) then
  begin
    if not IsProgrammer then
      Computed.Real := RoundToShown(Computed.Real);
  end
  else
    Exit(False);
  if HasError then
    ClearAll;
  if FState = EntryResult then
    StartFresh;
  DropGroupOperand;
  ShowComputed(OperandOfValue(Computed), Computed);
  Result := True;
end;

{ --- Showing ------------------------------------------------------------------------------- }

function TCalculatorEngine.DisplayText: string;
begin
  if HasError then
    Exit(CalculationErrorTexts[FError]);
  if (FState = EntryTyping) and not IsProgrammer then
    Result := FEntry
  else
    Result := ValueText(FValue);
end;

function TCalculatorEngine.CopyText: string;
begin
  if HasError then
    Exit('');
  Result := StringReplace(DisplayText, ' ', '', [rfReplaceAll]);
end;

function TCalculatorEngine.ExpressionText: string;
begin
  if HasError or (FState = EntryResult) then
    Exit(FShownExpression);
  if FState = EntryComputed then
    Result := PrettyExpression(FTokens + ' ' + FOperandText)
  else
    Result := PrettyExpression(FTokens);
end;

{ --- Modes ----------------------------------------------------------------------------------- }

procedure TCalculatorEngine.SetMode(Value: TCalculatorMode);
begin
  if FMode = Value then
    Exit;
  FMode := Value;
  if Value <> ModeProgrammer then
    FBase := 10;
  ClearAll;
end;

procedure TCalculatorEngine.SetBase(Value: LongInt);
begin
  if not (Value in [2, 8, 10, 16]) or (Value = FBase) then
    Exit;
  FBase := Value;
  { What is being typed becomes a value shown in the new base. }
  if FState = EntryTyping then
    ShowComputed(IntToStr(FValue.Whole), FValue);
end;

procedure TCalculatorEngine.SetWordBits(Value: LongInt);
begin
  if not (Value in [8, 16, 32, 64]) then
    Exit;
  FWordBits := Value;
  FValue.Whole := WrapToWord(FValue.Whole, Value);
  FMemory.Whole := WrapToWord(FMemory.Whole, Value);
  if FState = EntryTyping then
    ShowComputed(IntToStr(FValue.Whole), FValue);
end;

end.
