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
  Command line options in the GNU style.

    -a -b       short options, which can be grouped: -ab
    -n 5, -n5   a short option with a value
    --all       a long option
    --lines=5, --lines 5
                a long option with a value; long names may be shortened
                as long as the abbreviation is unambiguous
    --          everything after this is an operand

  Options and operands may be mixed; the operands are collected in order.
  --help prints the usage text, --version prints the version; both then
  end the program. Invalid options are reported and end the program with
  exit status 1.

  Typical use:

    CommandLine := TCommandLine.Create([
      CommandOption('n', 'lines', True, OptionLines)], Usage);
    while CommandLine.NextOption(Code, Value) do
      case Code of
        ...
      end;
    for Operand in CommandLine.Operands do
      ...

  OptionGiven and OptionValue tell afterwards whether an option was
  given and its (last) value, which may be empty. A program that
  rewrites its arguments first (an old "-5" form, say) passes the
  rewritten list to the constructor.
}
unit Util.CommandLine;

{$mode objfpc}{$H+}

interface

uses
  SysUtils;

const
  CoreutilsVersion = '0.2';

type
  TCommandOption = record
    ShortName: Char;     { #0 if the option has no short form }
    LongName: string;    { '' if it has no long form }
    TakesValue: Boolean;
    Code: Integer;       { returned by NextOption }
  end;

  TCommandLine = class
  private
    FOptions: array of TCommandOption;
    FUsage: string;
    FArguments: TStringArray;
    { The next argument to look at (an index into FArguments). }
    FArgumentIndex: Integer;
    { The argument holding a group of short options and the position
      inside it; 0 when not in a group. }
    FGroup: string;
    FGroupPosition: Integer;
    FOnlyOperandsRemain: Boolean;
    FOperands: TStringArray;
    FOperandPositions: array of Integer;
    FGivenCodes: array of Integer;
    FGivenValues: TStringArray;
    FNegativeNumbersAreOperands: Boolean;
    FStopAtFirstOperand: Boolean;
    procedure ShowHelp;
    procedure ShowVersion;
    procedure AddOperand(const Operand: string);
    function FindShortOption(Name: Char): Integer;
    function FindLongOption(const Name: string; out IsAmbiguous: Boolean): Integer;
    function ParseLongOption(const Text: string; out Code: Integer; out Value: string): Boolean;
    function ContinueGroup(out Code: Integer; out Value: string): Boolean;
    function ReadNextOption(out Code: Integer; out Value: string): Boolean;
    procedure RememberOption(Code: Integer; const Value: string);
    function FindGivenOption(Code: Integer): Integer;
    function GetOperandCount: Integer;
    function GetOperandPosition(Index: Integer): Integer;
  public
    { Parses the program's own arguments. }
    constructor Create(const Options: array of TCommandOption; const Usage: string); overload;
    { Parses Arguments (without argument 0) instead. }
    constructor Create(const Options: array of TCommandOption; const Usage: string;
      const Arguments: TStringArray); overload;
    { Returns the next option; False once all arguments are consumed. }
    function NextOption(out Code: Integer; out Value: string): Boolean;
    { Whether an option with Code was returned by NextOption, and the
      value it had the last time ('' for none). }
    function OptionGiven(Code: Integer): Boolean;
    function OptionValue(Code: Integer): string;
    { Collects the remaining operands without looking for options (for
      programs that take no options at all). }
    procedure ReadOperandsOnly;
    property Operands: TStringArray read FOperands write FOperands;
    property OperandCount: Integer read GetOperandCount;
    { Where operand Index was among the arguments: 0 for the first one
      after argument 0 (-1 for an operand the program added itself). }
    property OperandPositions[Index: Integer]: Integer read GetOperandPosition;
    { Treat "-5" as an operand rather than option 5 (seq, and others
      that take negative numbers). }
    property NegativeNumbersAreOperands: Boolean read FNegativeNumbersAreOperands
      write FNegativeNumbersAreOperands;
    { Everything from the first operand on is an operand (xargs, and
      others whose operands are a command with its own options). }
    property StopAtFirstOperand: Boolean read FStopAtFirstOperand write FStopAtFirstOperand;
  end;

function CommandOption(ShortName: Char; const LongName: string; TakesValue: Boolean;
  Code: Integer): TCommandOption;

{ The arguments the program was started with, without argument 0. }
function ProgramArguments: TStringArray;

implementation

uses
  StrUtils,
  Sys.Environment,
  Util.Messages,
  Sys.Streams;

function CommandOption(ShortName: Char; const LongName: string; TakesValue: Boolean;
  Code: Integer): TCommandOption;
begin
  Result.ShortName := ShortName;
  Result.LongName := LongName;
  Result.TakesValue := TakesValue;
  Result.Code := Code;
end;

function ProgramArguments: TStringArray;
var
  Index: Integer;
begin
  Result := nil;
  if ArgumentTotal < 2 then
    Exit;
  SetLength(Result, ArgumentTotal - 1);
  for Index := 1 to ArgumentTotal - 1 do
    Result[Index - 1] := Argument(Index);
end;

constructor TCommandLine.Create(const Options: array of TCommandOption; const Usage: string);
begin
  Create(Options, Usage, ProgramArguments);
end;

constructor TCommandLine.Create(const Options: array of TCommandOption; const Usage: string;
  const Arguments: TStringArray);
var
  Index: Integer;
begin
  inherited Create;
  SetLength(FOptions, Length(Options));
  for Index := 0 to High(Options) do
    FOptions[Index] := Options[Index];
  FUsage := Usage;
  FArguments := Copy(Arguments);
  FArgumentIndex := 0;
end;

function TCommandLine.GetOperandPosition(Index: Integer): Integer;
begin
  if Index <= High(FOperandPositions) then
    Result := FOperandPositions[Index]
  else
    Result := -1;
end;

function TCommandLine.FindGivenOption(Code: Integer): Integer;
var
  Index: Integer;
begin
  for Index := 0 to High(FGivenCodes) do
    if FGivenCodes[Index] = Code then
      Exit(Index);
  Result := -1;
end;

procedure TCommandLine.RememberOption(Code: Integer; const Value: string);
var
  Index: Integer;
begin
  Index := FindGivenOption(Code);
  if Index < 0 then
  begin
    Index := Length(FGivenCodes);
    SetLength(FGivenCodes, Index + 1);
    SetLength(FGivenValues, Index + 1);
    FGivenCodes[Index] := Code;
  end;
  FGivenValues[Index] := Value;
end;

function TCommandLine.OptionGiven(Code: Integer): Boolean;
begin
  Result := FindGivenOption(Code) >= 0;
end;

function TCommandLine.OptionValue(Code: Integer): string;
var
  Index: Integer;
begin
  Index := FindGivenOption(Code);
  if Index >= 0 then
    Result := FGivenValues[Index]
  else
    Result := '';
end;

function TCommandLine.NextOption(out Code: Integer; out Value: string): Boolean;
begin
  Result := ReadNextOption(Code, Value);
  if Result then
    RememberOption(Code, Value);
end;

function TCommandLine.GetOperandCount: Integer;
begin
  Result := Length(FOperands);
end;

procedure TCommandLine.ReadOperandsOnly;
var
  Code: Integer;
  Value: string;
begin
  while NextOption(Code, Value) do
    ;
end;

procedure TCommandLine.ShowHelp;
begin
  if FUsage <> '' then
    PrintString(FUsage)
  else
    PrintString(Format('Usage: %s [OPTION]... [ARGUMENT]...'#10, [ProgramName]));
  Halt(0);
end;

procedure TCommandLine.ShowVersion;
begin
  PrintString(Format('%s (FreePascalOS coreutils) %s'#10, [ProgramName, CoreutilsVersion]));
  Halt(0);
end;

procedure TCommandLine.AddOperand(const Operand: string);
begin
  SetLength(FOperands, Length(FOperands) + 1);
  FOperands[High(FOperands)] := Operand;
  SetLength(FOperandPositions, Length(FOperands));
  FOperandPositions[High(FOperandPositions)] := FArgumentIndex - 1;
end;

function TCommandLine.FindShortOption(Name: Char): Integer;
var
  Index: Integer;
begin
  for Index := 0 to High(FOptions) do
    if FOptions[Index].ShortName = Name then
      Exit(Index);
  Result := -1;
end;

{ Finds a long option by its full name or an unambiguous abbreviation. }
function TCommandLine.FindLongOption(const Name: string; out IsAmbiguous: Boolean): Integer;
var
  Index: Integer;
  Candidate: string;
begin
  Result := -1;
  IsAmbiguous := False;
  for Index := 0 to High(FOptions) do
  begin
    Candidate := FOptions[Index].LongName;
    if Candidate = '' then
      Continue;
    if StartsStr(Name, Candidate) then
    begin
      if Length(Candidate) = Length(Name) then
      begin
        { An exact match always wins. }
        IsAmbiguous := False;
        Exit(Index);
      end;
      if Result >= 0 then
        IsAmbiguous := True;
      Result := Index;
    end;
  end;
  if IsAmbiguous then
    Result := -1;
end;

function TCommandLine.ParseLongOption(const Text: string; out Code: Integer;
  out Value: string): Boolean;
var
  EqualsPosition: Integer;
  Name: string;
  OptionIndex: Integer;
  IsAmbiguous: Boolean;
begin
  Value := '';
  EqualsPosition := Pos('=', Text);
  if EqualsPosition > 0 then
    Name := Copy(Text, 1, EqualsPosition - 1)
  else
    Name := Text;

  OptionIndex := FindLongOption(Name, IsAmbiguous);
  if OptionIndex < 0 then
  begin
    if (Name <> '') and StartsStr(Name, 'help') then
      ShowHelp;
    if (Name <> '') and StartsStr(Name, 'version') then
      ShowVersion;
    if IsAmbiguous then
      FailWithUsageHint(Format('option ''--%s'' is ambiguous', [Text]))
    else
      FailWithUsageHint(Format('unrecognized option ''--%s''', [Text]));
  end;

  if FOptions[OptionIndex].TakesValue then
  begin
    if EqualsPosition > 0 then
      Value := Copy(Text, EqualsPosition + 1, MaxInt)
    else if FArgumentIndex < Length(FArguments) then
    begin
      Value := FArguments[FArgumentIndex];
      Inc(FArgumentIndex);
    end
    else
      FailWithUsageHint(Format('option ''--%s'' requires an argument', [FOptions[OptionIndex].LongName]));
  end
  else if EqualsPosition > 0 then
    FailWithUsageHint(Format('option ''--%s'' doesn''t allow an argument', [FOptions[OptionIndex].LongName]));

  Code := FOptions[OptionIndex].Code;
  Result := True;
end;

{ The next option of a group of short options such as -abc. }
function TCommandLine.ContinueGroup(out Code: Integer; out Value: string): Boolean;
var
  OptionIndex: Integer;
begin
  Value := '';
  OptionIndex := FindShortOption(FGroup[FGroupPosition]);
  if OptionIndex < 0 then
    FailWithUsageHint(Format('invalid option -- ''%s''', [FGroup[FGroupPosition]]));
  Inc(FGroupPosition);
  if FOptions[OptionIndex].TakesValue then
  begin
    if FGroupPosition <= Length(FGroup) then
      Value := Copy(FGroup, FGroupPosition, MaxInt)
    else if FArgumentIndex < Length(FArguments) then
    begin
      Value := FArguments[FArgumentIndex];
      Inc(FArgumentIndex);
    end
    else
      FailWithUsageHint(Format('option requires an argument -- ''%s''', [FOptions[OptionIndex].ShortName]));
    FGroupPosition := 0;
  end
  else if FGroupPosition > Length(FGroup) then
    FGroupPosition := 0;
  Code := FOptions[OptionIndex].Code;
  Result := True;
end;

function TCommandLine.ReadNextOption(out Code: Integer; out Value: string): Boolean;
var
  Text: string;
begin
  Code := 0;
  Value := '';

  if FGroupPosition > 0 then
    Exit(ContinueGroup(Code, Value));

  while FArgumentIndex < Length(FArguments) do
  begin
    Text := FArguments[FArgumentIndex];
    Inc(FArgumentIndex);

    if FOnlyOperandsRemain or (Length(Text) < 2) or (Text[1] <> '-') or
       (FNegativeNumbersAreOperands and (Text[2] in ['0'..'9'])) then
    begin
      { "-" alone conventionally means standard input: an operand. }
      AddOperand(Text);
      if FStopAtFirstOperand then
        FOnlyOperandsRemain := True;
      Continue;
    end;

    if Text[2] = '-' then
    begin
      if Length(Text) = 2 then
      begin
        FOnlyOperandsRemain := True;
        Continue;
      end;
      Exit(ParseLongOption(Copy(Text, 3, MaxInt), Code, Value));
    end;

    FGroup := Text;
    FGroupPosition := 2;
    Exit(ContinueGroup(Code, Value));
  end;
  Result := False;
end;

end.
