{
  printf - format and print data

  printf FORMAT [ARGUMENT]...

  Like the C function: FORMAT is printed with each % conversion replaced
  by the next ARGUMENT. Conversions: %s %b (text with escapes) %c
  %d %i %u %x %X %o %%, with flags (- 0 +), width and precision
  ("*" takes them from an argument). Escapes in FORMAT: \n \t \\ \"
  \a \b \f \r \v \NNN (octal). If there are more arguments than
  conversions, FORMAT is used again.
}
program printf;

{$mode objfpc}
{$pointermath on}

uses
  Runtime.Text,
  Sys.Environment,
  Sys.Format,
  Sys.Streams,
  Sys.Text,
  Util.Messages;

var
  Arguments: PPChar;
  ArgumentCountLeft: Integer;
  ExitStatus: LongInt;
  ConsumedAny: Boolean;

function NextArgument: PChar;
begin
  if ArgumentCountLeft = 0 then
    Exit(nil);
  Result := Arguments^;
  Inc(Arguments);
  Dec(ArgumentCountLeft);
  ConsumedAny := True;
end;

{ Numbers may be written 'c (the code of character c) or in decimal,
  0x hexadecimal or 0 octal. }
function ArgumentAsNumber(Text: PChar): Int64;
var
  IsNegative: Boolean;
  Base: Integer;
  Digit: Integer;
  Position: Integer;
begin
  Result := 0;
  if Text = nil then
    Exit;
  if (Text[0] = '''') or (Text[0] = '"') then
    Exit(Ord(Text[1]));
  if ParseInteger(Text, Result) then
    Exit;

  Position := 0;
  IsNegative := Text[0] = '-';
  if IsNegative or (Text[0] = '+') then
    Inc(Position);
  Base := 10;
  if (Text[Position] = '0') and (ToLowerCase(Text[Position + 1]) = 'x') then
  begin
    Base := 16;
    Inc(Position, 2);
  end
  else if Text[Position] = '0' then
    Base := 8;
  while Text[Position] <> #0 do
  begin
    if IsDigit(Text[Position]) then
      Digit := Ord(Text[Position]) - Ord('0')
    else if ToLowerCase(Text[Position]) in ['a'..'f'] then
      Digit := Ord(ToLowerCase(Text[Position])) - Ord('a') + 10
    else
      Digit := 99;
    if Digit >= Base then
    begin
      Report('''%s'': expected a numeric value', [ArgumentText(Text)]);
      ExitStatus := 1;
      Break;
    end;
    Result := Result * Base + Digit;
    Inc(Position);
  end;
  if IsNegative then
    Result := -Result;
end;

{ Interprets one backslash escape at Text[Position] (just after the
  backslash); returns False for \c, which stops all output. }
function WriteEscape(Text: PChar; var Position: Integer; OctalNeedsZero: Boolean): Boolean;
var
  Value: Integer;
  DigitCount: Integer;
begin
  Result := True;
  case Text[Position] of
    'n': WriteCharacter(StandardOutput, #10);
    't': WriteCharacter(StandardOutput, #9);
    'r': WriteCharacter(StandardOutput, #13);
    'a': WriteCharacter(StandardOutput, #7);
    'b': WriteCharacter(StandardOutput, #8);
    'f': WriteCharacter(StandardOutput, #12);
    'v': WriteCharacter(StandardOutput, #11);
    'e': WriteCharacter(StandardOutput, #27);
    '\': WriteCharacter(StandardOutput, '\');
    '"': WriteCharacter(StandardOutput, '"');
    '''': WriteCharacter(StandardOutput, '''');
    'c': Exit(False);
    '0'..'7':
      begin
        if OctalNeedsZero and (Text[Position] <> '0') then
        begin
          WriteCharacter(StandardOutput, '\');
          WriteCharacter(StandardOutput, Text[Position]);
        end
        else
        begin
          Value := 0;
          DigitCount := 0;
          if OctalNeedsZero then
            Inc(Position);
          while (DigitCount < 3) and (Text[Position] in ['0'..'7']) do
          begin
            Value := Value * 8 + Ord(Text[Position]) - Ord('0');
            Inc(Position);
            Inc(DigitCount);
          end;
          Dec(Position);
          WriteCharacter(StandardOutput, Char(Value and $FF));
        end;
      end;
  else
    begin
      WriteCharacter(StandardOutput, '\');
      WriteCharacter(StandardOutput, Text[Position]);
    end;
  end;
  Inc(Position);
end;

{ %b: the argument with escapes interpreted. }
function WriteWithEscapes(Text: PChar): Boolean;
var
  Position: Integer;
begin
  Result := True;
  if Text = nil then
    Exit;
  Position := 0;
  while Text[Position] <> #0 do
  begin
    if (Text[Position] = '\') and (Text[Position + 1] <> #0) then
    begin
      Inc(Position);
      if not WriteEscape(Text, Position, True) then
        Exit(False);
    end
    else
    begin
      WriteCharacter(StandardOutput, Text[Position]);
      Inc(Position);
    end;
  end;
end;

{ Prints FORMAT once. Returns False if output must stop (\c). }
function PrintFormatOnce(Format: PChar): Boolean;
var
  Position: Integer;
  Specification: TTextBuilder;
  Conversion: Char;
  Number: Int64;
  NumberText: TNumberText;
  Value: PChar;
begin
  Result := True;
  Position := 0;
  while Format[Position] <> #0 do
  begin
    if Format[Position] = '\' then
    begin
      Inc(Position);
      if Format[Position] = #0 then
      begin
        WriteCharacter(StandardOutput, '\');
        Break;
      end;
      if not WriteEscape(Format, Position, False) then
        Exit(False);
      Continue;
    end;
    if Format[Position] <> '%' then
    begin
      WriteCharacter(StandardOutput, Format[Position]);
      Inc(Position);
      Continue;
    end;
    if Format[Position + 1] = '%' then
    begin
      WriteCharacter(StandardOutput, '%');
      Inc(Position, 2);
      Continue;
    end;

    { Collect the specification, replacing * with argument values, and
      hand it to the library formatter. }
    BeginText(Specification);
    AppendCharacter(Specification, '%');
    Inc(Position);
    while Format[Position] in ['-', '+', ' ', '#', '0'..'9', '.', '*'] do
    begin
      if Format[Position] = '*' then
        AppendText(Specification, FormatSignedDecimal(ArgumentAsNumber(NextArgument), NumberText))
      else
        AppendCharacter(Specification, Format[Position]);
      Inc(Position);
    end;
    { Length modifiers such as l or h make no difference here. }
    while Format[Position] in ['l', 'h', 'j', 'z', 't', 'L'] do
      Inc(Position);
    Conversion := Format[Position];
    if Conversion = #0 then
    begin
      Report('%s: missing conversion specifier', [ArgumentText(Specification.Text)]);
      ExitStatus := 1;
      DiscardText(Specification);
      Break;
    end;
    Inc(Position);

    case Conversion of
      's':
        begin
          AppendCharacter(Specification, 's');
          Value := NextArgument;
          if Value = nil then
            Value := '';
          WriteFormatted(StandardOutput, Specification.Text, [ArgumentText(Value)]);
        end;
      'b':
        if not WriteWithEscapes(NextArgument) then
        begin
          DiscardText(Specification);
          Exit(False);
        end;
      'c':
        begin
          Value := NextArgument;
          if (Value <> nil) and (Value^ <> #0) then
            WriteCharacter(StandardOutput, Value^);
        end;
      'd', 'i', 'u', 'x', 'X', 'o':
        begin
          AppendCharacter(Specification, Conversion);
          Number := ArgumentAsNumber(NextArgument);
          if Conversion in ['d', 'i'] then
            WriteFormatted(StandardOutput, Specification.Text, [ArgumentNumber(Number)])
          else
            WriteFormatted(StandardOutput, Specification.Text, [ArgumentUnsigned(QWord(Number))]);
        end;
    else
      begin
        Report('%%%s: invalid conversion specification', [ArgumentCharacter(Conversion)]);
        ExitStatus := 1;
        DiscardText(Specification);
        Exit(False);
      end;
    end;
    DiscardText(Specification);
  end;
end;

var
  Format: PChar;
begin
  ExitStatus := 0;
  if ArgumentTotal < 2 then
  begin
    Report('missing operand', []);
    WriteFormatted(StandardError, 'Try ''%s --help'' for more information.'#10, [ArgumentText(ProgramName)]);
    Halt(1);
  end;
  if TextIsEqual(Argument(1), '--help') then
  begin
    PrintLine('Usage: printf FORMAT [ARGUMENT]...');
    PrintLine('Print ARGUMENT(s) according to FORMAT.');
    Halt(0);
  end;

  Format := Argument(1);
  if TextIsEqual(Format, '--') and (ArgumentTotal >= 3) then
  begin
    Format := Argument(2);
    Arguments := ArgumentValues + 3;
    ArgumentCountLeft := ArgumentTotal - 3;
  end
  else
  begin
    Arguments := ArgumentValues + 2;
    ArgumentCountLeft := ArgumentTotal - 2;
  end;

  repeat
    ConsumedAny := False;
    if not PrintFormatOnce(Format) then
      Break;
  until (ArgumentCountLeft = 0) or not ConsumedAny;
  Halt(ExitStatus);
end.
