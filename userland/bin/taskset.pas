{
  taskset - show or set the processors a process may run on

  taskset [-c] MASK COMMAND [ARG]...   run COMMAND limited to MASK
  taskset -p [-c] [MASK] PID           show (and set) the affinity of PID

  MASK is hexadecimal, bit N for processor N ("5" or "0x5": processors 0
  and 2); with -c it is a list instead ("0,2", "1-3"). The affinity is
  inherited: COMMAND and everything it starts keep to those processors.
}
program taskset;

{$mode objfpc}
{$pointermath on}

uses
  Runtime.Text,
  Sys.Kernel,
  Sys.Errors,
  Sys.Environment,
  Sys.Format,
  Sys.Processes,
  Sys.Streams,
  Sys.Text,
  Util.Commands,
  Util.Messages;

const
  Usage: PChar = 'Usage: taskset [OPTION] [MASK | LIST] [PID | COMMAND [ARG]...]'#10 +
    'Show or change the processor affinity of a process, or run COMMAND'#10 +
    'with the given affinity.'#10#10 +
    '  -p, --pid        operate on the existing process PID'#10 +
    '  -c, --cpu-list   use a list of processors ("0,2-3") instead of a mask'#10;

  MaximumProcessors = 64;

var
  ForProcess: Boolean;
  UseList: Boolean;
  First: Integer;

function HexDigitValue(Character: Char; out Value: QWord): Boolean;
begin
  Result := True;
  case Character of
    '0'..'9': Value := Ord(Character) - Ord('0');
    'a'..'f': Value := Ord(Character) - Ord('a') + 10;
    'A'..'F': Value := Ord(Character) - Ord('A') + 10;
  else
    Result := False;
  end;
end;

function ParseMask(Text: PChar; out Mask: QWord): Boolean;
var
  Digit: QWord;
begin
  Mask := 0;
  if (Text[0] = '0') and (Text[1] in ['x', 'X']) then
    Text := Text + 2;
  if Text^ = #0 then
    Exit(False);
  while Text^ <> #0 do
  begin
    if not HexDigitValue(Text^, Digit) or ((Mask shr 60) <> 0) then
      Exit(False);
    Mask := (Mask shl 4) or Digit;
    Inc(Text);
  end;
  Result := True;
end;

{ Reads a processor number at Text, advancing past it. }
function ParseProcessorNumber(var Text: PChar; out Number: QWord): Boolean;
begin
  Number := 0;
  if not IsDigit(Text^) then
    Exit(False);
  while IsDigit(Text^) do
  begin
    Number := Number * 10 + QWord(Ord(Text^) - Ord('0'));
    if Number >= MaximumProcessors then
      Exit(False);
    Inc(Text);
  end;
  Result := True;
end;

{ "0,2-3" into a mask. }
function ParseList(Text: PChar; out Mask: QWord): Boolean;
var
  Low: QWord;
  High: QWord;
  Number: QWord;
begin
  Mask := 0;
  repeat
    if not ParseProcessorNumber(Text, Low) then
      Exit(False);
    High := Low;
    if Text^ = '-' then
    begin
      Inc(Text);
      if not ParseProcessorNumber(Text, High) or (High < Low) then
        Exit(False);
    end;
    for Number := Low to High do
      Mask := Mask or (QWord(1) shl Number);
    if Text^ = ',' then
      Inc(Text)
    else if Text^ <> #0 then
      Exit(False);
  until Text^ = #0;
  Result := True;
end;

function ParseAffinity(Text: PChar; out Mask: QWord): Boolean;
begin
  if UseList then
    Result := ParseList(Text, Mask)
  else
    Result := ParseMask(Text, Mask);
end;

{ Writes Mask as a list: "0,2-3". }
procedure WriteList(Mask: QWord);
var
  Number: Integer;
  RunEnd: Integer;
  IsFirst: Boolean;
begin
  IsFirst := True;
  Number := 0;
  while Number < MaximumProcessors do
  begin
    if (Mask and (QWord(1) shl Number)) = 0 then
    begin
      Inc(Number);
      Continue;
    end;
    RunEnd := Number;
    while (RunEnd + 1 < MaximumProcessors) and ((Mask and (QWord(1) shl (RunEnd + 1))) <> 0) do
      Inc(RunEnd);
    if not IsFirst then
      WriteCharacter(StandardOutput, ',');
    IsFirst := False;
    WriteDecimal(StandardOutput, Number);
    if RunEnd > Number then
    begin
      WriteCharacter(StandardOutput, '-');
      WriteDecimal(StandardOutput, RunEnd);
    end;
    Number := RunEnd + 1;
  end;
end;

procedure WriteAffinity(ProcessId: Int64; Which: PChar; Mask: QWord);
begin
  if UseList then
  begin
    WriteFormatted(StandardOutput, 'pid %d''s %s affinity list: ', [ArgumentNumber(ProcessId),
      ArgumentText(Which)]);
    WriteList(Mask);
    WriteCharacter(StandardOutput, #10);
  end
  else
    WriteFormatted(StandardOutput, 'pid %d''s %s affinity mask: %x'#10, [ArgumentNumber(ProcessId),
      ArgumentText(Which), ArgumentUnsigned(Mask)]);
end;

function GetAffinityOrFail(ProcessId: Int64): QWord;
var
  CallResult: Int64;
begin
  CallResult := KernelGetAffinity(QWord(ProcessId));
  if CallResult < 0 then
    FailWithError(1, ErrorCodeOf(CallResult), 'failed to get pid %d''s affinity',
      [ArgumentNumber(ProcessId)]);
  Result := QWord(CallResult);
end;

procedure SetAffinityOrFail(ProcessId: Int64; Mask: QWord);
var
  CallResult: Int64;
begin
  CallResult := KernelSetAffinity(QWord(ProcessId), Mask);
  if CallResult < 0 then
    FailWithError(1, ErrorCodeOf(CallResult), 'failed to set pid %d''s affinity',
      [ArgumentNumber(ProcessId)]);
end;

procedure ParseOptions;
var
  Text: PChar;
  Position: PChar;
begin
  ForProcess := False;
  UseList := False;
  First := 1;
  while First < ArgumentTotal do
  begin
    Text := Argument(First);
    if TextIsEqual(Text, '--help') then
    begin
      Print(Usage);
      Halt(0);
    end
    else if TextIsEqual(Text, '--pid') then
      ForProcess := True
    else if TextIsEqual(Text, '--cpu-list') then
      UseList := True
    else if TextIsEqual(Text, '--') then
    begin
      Inc(First);
      Break;
    end
    else if (Text[0] = '-') and (Text[1] <> #0) then
    begin
      Position := Text + 1;
      while Position^ <> #0 do
      begin
        case Position^ of
          'p': ForProcess := True;
          'c': UseList := True;
        else
          FailWithUsageHint('invalid option -- ''%c''', [ArgumentCharacter(Position^)]);
        end;
        Inc(Position);
      end;
    end
    else
      Break;
    Inc(First);
  end;
end;

procedure HandleProcess;
var
  ProcessId: Int64;
  Mask: QWord;
begin
  if (ArgumentTotal - First < 1) or (ArgumentTotal - First > 2) then
    FailWithUsageHint('wrong number of arguments', []);
  if not ParseInteger(Argument(ArgumentTotal - 1), ProcessId) or (ProcessId < 0) then
    Fail(1, 'invalid PID argument: ''%s''', [ArgumentText(Argument(ArgumentTotal - 1))]);
  WriteAffinity(ProcessId, 'current', GetAffinityOrFail(ProcessId));
  if ArgumentTotal - First = 2 then
  begin
    if not ParseAffinity(Argument(First), Mask) then
      Fail(1, 'failed to parse affinity ''%s''', [ArgumentText(Argument(First))]);
    SetAffinityOrFail(ProcessId, Mask);
    WriteAffinity(ProcessId, 'new', GetAffinityOrFail(ProcessId));
  end;
end;

procedure HandleCommand;
var
  Mask: QWord;
  Options: TProcessOptions;
begin
  if ArgumentTotal - First < 2 then
    FailWithUsageHint('missing command', []);
  if not ParseAffinity(Argument(First), Mask) then
    Fail(1, 'failed to parse affinity ''%s''', [ArgumentText(Argument(First))]);
  { Set on this process; the command inherits it. }
  SetAffinityOrFail(0, Mask);
  DefaultProcessOptions(Options);
  RunCommandAndExit(ArgumentValues + First + 1, Options);
end;

begin
  ParseOptions;
  if ForProcess then
    HandleProcess
  else
    HandleCommand;
end.
