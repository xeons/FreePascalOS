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
  --help prints the usage text given to BeginOptions, --version prints
  the version; both then end the program. Invalid options are reported
  and end the program with exit status 1.

  Typical use:

    BeginOptions(Parser, Definitions, Usage);
    while NextOption(Parser, Code, Value) do
      case Code of
        ...
      end;
    for Index := 0 to Parser.OperandCount - 1 do
      ... Parser.Operands[Index] ...
}
unit Util.Options;

{$mode objfpc}
{$pointermath on}

interface

type
  POptionDefinition = ^TOptionDefinition;
  TOptionDefinition = record
    ShortName: Char;     { #0 if the option has no short form }
    LongName: PChar;     { nil if it has no long form }
    TakesValue: Boolean;
    Code: Integer;       { returned by NextOption }
  end;

  TOptionParser = record
    Definitions: POptionDefinition;
    DefinitionCount: Integer;
    Usage: PChar;
    ArgumentIndex: Integer;
    { Position inside a group of short options, 0 when not in one. }
    GroupPosition: Integer;
    OnlyOperandsRemain: Boolean;
    Operands: PPChar;
    OperandCount: Integer;
    { Treat "-5" as an operand rather than option 5 (seq, and others
      that take negative numbers). }
    NegativeNumbersAreOperands: Boolean;
  end;

const
  CoreutilsVersion = '0.2';

procedure BeginOptions(out Parser: TOptionParser; const Definitions: array of TOptionDefinition;
  Usage: PChar);
{ Returns the next option; False once all arguments are consumed. }
function NextOption(var Parser: TOptionParser; out Code: Integer; out Value: PChar): Boolean;
{ Collects the remaining operands without looking for options (for
  programs that take no options at all). }
procedure ParseOperandsOnly(out Parser: TOptionParser; Usage: PChar);

function OptionDefinition(ShortName: Char; LongName: PChar; TakesValue: Boolean;
  Code: Integer): TOptionDefinition;

implementation

uses
  Runtime.Memory,
  Runtime.Text,
  Sys.Environment,
  Sys.Format,
  Sys.Memory,
  Sys.Streams,
  Sys.Text,
  Util.Messages;

function OptionDefinition(ShortName: Char; LongName: PChar; TakesValue: Boolean;
  Code: Integer): TOptionDefinition;
begin
  Result.ShortName := ShortName;
  Result.LongName := LongName;
  Result.TakesValue := TakesValue;
  Result.Code := Code;
end;

procedure BeginOptions(out Parser: TOptionParser; const Definitions: array of TOptionDefinition;
  Usage: PChar);
var
  Index: Integer;
begin
  Parser.DefinitionCount := Length(Definitions);
  Parser.Definitions := POptionDefinition(AllocateMemory((Parser.DefinitionCount + 1) * SizeOf(TOptionDefinition)));
  for Index := 0 to Parser.DefinitionCount - 1 do
    Parser.Definitions[Index] := Definitions[Index];
  Parser.Usage := Usage;
  Parser.ArgumentIndex := 1;
  Parser.GroupPosition := 0;
  Parser.OnlyOperandsRemain := False;
  Parser.Operands := PPChar(AllocateZeroedMemory((ArgumentTotal + 1) * SizeOf(PChar)));
  Parser.OperandCount := 0;
  Parser.NegativeNumbersAreOperands := False;
end;

procedure ParseOperandsOnly(out Parser: TOptionParser; Usage: PChar);
var
  Code: Integer;
  Value: PChar;
begin
  BeginOptions(Parser, [], Usage);
  while NextOption(Parser, Code, Value) do
    ;
end;

procedure ShowHelp(const Parser: TOptionParser);
begin
  if Parser.Usage <> nil then
    WriteText(StandardOutput, Parser.Usage)
  else
    WriteFormatted(StandardOutput, 'Usage: %s [OPTION]... [ARGUMENT]...'#10, [ArgumentText(ProgramName)]);
  Halt(0);
end;

procedure ShowVersion;
begin
  WriteFormatted(StandardOutput, '%s (FreePascalOS coreutils) %s'#10, [ArgumentText(ProgramName),
    ArgumentText(CoreutilsVersion)]);
  Halt(0);
end;

procedure AddOperand(var Parser: TOptionParser; Operand: PChar);
begin
  Parser.Operands[Parser.OperandCount] := Operand;
  Inc(Parser.OperandCount);
end;

function FindShortOption(const Parser: TOptionParser; Name: Char): POptionDefinition;
var
  Index: Integer;
begin
  for Index := 0 to Parser.DefinitionCount - 1 do
  begin
    if Parser.Definitions[Index].ShortName = Name then
      Exit(@Parser.Definitions[Index]);
  end;
  Result := nil;
end;

{ Finds a long option by its full name or an unambiguous abbreviation.
  NameLength excludes any "=value" part. }
function FindLongOption(const Parser: TOptionParser; Name: PChar; NameLength: PtrUInt;
  out IsAmbiguous: Boolean): POptionDefinition;
var
  Index: Integer;
  Candidate: PChar;
begin
  Result := nil;
  IsAmbiguous := False;
  for Index := 0 to Parser.DefinitionCount - 1 do
  begin
    Candidate := Parser.Definitions[Index].LongName;
    if Candidate = nil then
      Continue;
    if (TextLength(Candidate) >= NameLength) and
       MemoryIsEqual(Candidate, Name, NameLength) then
    begin
      if TextLength(Candidate) = NameLength then
      begin
        { An exact match always wins. }
        IsAmbiguous := False;
        Exit(@Parser.Definitions[Index]);
      end;
      if Result <> nil then
        IsAmbiguous := True;
      Result := @Parser.Definitions[Index];
    end;
  end;
  if IsAmbiguous then
    Result := nil;
end;

function ParseLongOption(var Parser: TOptionParser; Text: PChar; out Code: Integer;
  out Value: PChar): Boolean;
var
  EqualsPosition: PtrInt;
  NameLength: PtrUInt;
  Definition: POptionDefinition;
  IsAmbiguous: Boolean;
begin
  Value := nil;
  EqualsPosition := FindCharacter(Text, '=');
  if EqualsPosition >= 0 then
    NameLength := PtrUInt(EqualsPosition)
  else
    NameLength := TextLength(Text);

  Definition := FindLongOption(Parser, Text, NameLength, IsAmbiguous);
  if Definition = nil then
  begin
    if (NameLength > 0) and (NameLength <= 4) and MemoryIsEqual(PChar('help'), Text, NameLength) then
      ShowHelp(Parser);
    if (NameLength > 0) and (NameLength <= 7) and MemoryIsEqual(PChar('version'), Text, NameLength) then
      ShowVersion;
    if IsAmbiguous then
      FailWithUsageHint('option ''--%s'' is ambiguous', [ArgumentText(Text)])
    else
      FailWithUsageHint('unrecognized option ''--%s''', [ArgumentText(Text)]);
  end;

  if Definition^.TakesValue then
  begin
    if EqualsPosition >= 0 then
      Value := Text + EqualsPosition + 1
    else if Parser.ArgumentIndex < ArgumentTotal then
    begin
      Value := Argument(Parser.ArgumentIndex);
      Inc(Parser.ArgumentIndex);
    end
    else
      FailWithUsageHint('option ''--%s'' requires an argument', [ArgumentText(Definition^.LongName)]);
  end
  else if EqualsPosition >= 0 then
    FailWithUsageHint('option ''--%s'' doesn''t allow an argument', [ArgumentText(Definition^.LongName)]);

  Code := Definition^.Code;
  Result := True;
end;

function NextOption(var Parser: TOptionParser; out Code: Integer; out Value: PChar): Boolean;
var
  Text: PChar;
  Definition: POptionDefinition;
begin
  Code := 0;
  Value := nil;

  { Continue a group of short options such as -abc. }
  if Parser.GroupPosition > 0 then
  begin
    Text := Argument(Parser.ArgumentIndex - 1);
    Definition := FindShortOption(Parser, Text[Parser.GroupPosition]);
    if Definition = nil then
      FailWithUsageHint('invalid option -- ''%c''', [ArgumentCharacter(Text[Parser.GroupPosition])]);
    Inc(Parser.GroupPosition);
    if Definition^.TakesValue then
    begin
      if Text[Parser.GroupPosition] <> #0 then
        Value := Text + Parser.GroupPosition
      else if Parser.ArgumentIndex < ArgumentTotal then
      begin
        Value := Argument(Parser.ArgumentIndex);
        Inc(Parser.ArgumentIndex);
      end
      else
        FailWithUsageHint('option requires an argument -- ''%c''', [ArgumentCharacter(Definition^.ShortName)]);
      Parser.GroupPosition := 0;
    end
    else if Text[Parser.GroupPosition] = #0 then
      Parser.GroupPosition := 0;
    Code := Definition^.Code;
    Exit(True);
  end;

  while Parser.ArgumentIndex < ArgumentTotal do
  begin
    Text := Argument(Parser.ArgumentIndex);
    Inc(Parser.ArgumentIndex);

    if Parser.OnlyOperandsRemain or (Text[0] <> '-') or (Text[1] = #0) or
       (Parser.NegativeNumbersAreOperands and IsDigit(Text[1])) then
    begin
      { "-" alone conventionally means standard input: an operand. }
      AddOperand(Parser, Text);
      Continue;
    end;

    if Text[1] = '-' then
    begin
      if Text[2] = #0 then
      begin
        Parser.OnlyOperandsRemain := True;
        Continue;
      end;
      Exit(ParseLongOption(Parser, Text + 2, Code, Value));
    end;

    Parser.GroupPosition := 1;
    Exit(NextOption(Parser, Code, Value));
  end;
  Result := False;
end;

end.
