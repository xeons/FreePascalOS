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
  taskset - show or set the processors a process may run on

  taskset [-c] MASK COMMAND [ARG]...   run COMMAND limited to MASK
  taskset -p [-c] [MASK] PID           show (and set) the affinity of PID

  MASK is hexadecimal, bit N for processor N ("5" or "0x5": processors 0
  and 2); with -c it is a list instead ("0,2", "1-3"). The affinity is
  inherited: COMMAND and everything it starts keep to those processors.
}
program taskset;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  Sys.Kernel,
  Sys.Errors,
  Sys.Processes,
  Sys.Text,
  Util.CommandLine,
  Util.Commands,
  Util.Messages,
  Util.Numbers,
  Util.Output;

const
  Usage = 'Usage: taskset [OPTION] [MASK | LIST] [PID | COMMAND [ARG]...]'#10 +
    'Show or change the processor affinity of a process, or run COMMAND'#10 +
    'with the given affinity.'#10#10 +
    '  -p, --pid        operate on the existing process PID'#10 +
    '  -c, --cpu-list   use a list of processors ("0,2-3") instead of a mask'#10;

  MaximumProcessors = 64;

var
  Arguments: TStringArray;
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

function ParseMask(const Text: string; out Mask: QWord): Boolean;
var
  Digits: string;
  Digit: QWord;
  Index: Integer;
begin
  Mask := 0;
  Digits := Text;
  if (Length(Digits) >= 2) and (Digits[1] = '0') and (Digits[2] in ['x', 'X']) then
    Delete(Digits, 1, 2);
  if Digits = '' then
    Exit(False);
  for Index := 1 to Length(Digits) do
  begin
    if not HexDigitValue(Digits[Index], Digit) or ((Mask shr 60) <> 0) then
      Exit(False);
    Mask := (Mask shl 4) or Digit;
  end;
  Result := True;
end;

{ Reads a processor number at Text[Position], advancing past it. }
function ParseProcessorNumber(const Text: string; var Position: Integer; out Number: QWord): Boolean;
begin
  Number := 0;
  if (Position > Length(Text)) or not IsDigit(Text[Position]) then
    Exit(False);
  while (Position <= Length(Text)) and IsDigit(Text[Position]) do
  begin
    Number := Number * 10 + QWord(Ord(Text[Position]) - Ord('0'));
    if Number >= MaximumProcessors then
      Exit(False);
    Inc(Position);
  end;
  Result := True;
end;

{ "0,2-3" into a mask. }
function ParseList(const Text: string; out Mask: QWord): Boolean;
var
  Position: Integer;
  Low: QWord;
  High: QWord;
  Number: QWord;
begin
  Mask := 0;
  Position := 1;
  repeat
    if not ParseProcessorNumber(Text, Position, Low) then
      Exit(False);
    High := Low;
    if (Position <= Length(Text)) and (Text[Position] = '-') then
    begin
      Inc(Position);
      if not ParseProcessorNumber(Text, Position, High) or (High < Low) then
        Exit(False);
    end;
    for Number := Low to High do
      Mask := Mask or (QWord(1) shl Number);
    if Position > Length(Text) then
      Break;
    if Text[Position] <> ',' then
      Exit(False);
    Inc(Position);
  until Position > Length(Text);
  Result := True;
end;

function ParseAffinity(const Text: string; out Mask: QWord): Boolean;
begin
  if UseList then
    Result := ParseList(Text, Mask)
  else
    Result := ParseMask(Text, Mask);
end;

{ Mask as a list: "0,2-3". }
function ListText(Mask: QWord): string;
var
  Number: Integer;
  RunEnd: Integer;
begin
  Result := '';
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
    if Result <> '' then
      Result := Result + ',';
    Result := Result + IntToStr(Number);
    if RunEnd > Number then
      Result := Result + '-' + IntToStr(RunEnd);
    Number := RunEnd + 1;
  end;
end;

procedure WriteAffinity(ProcessId: Int64; const Which: string; Mask: QWord);
var
  Line: string;
begin
  if UseList then
    Line := Format('pid %d''s %s affinity list: %s', [ProcessId, Which, ListText(Mask)])
  else
    Line := Format('pid %d''s %s affinity mask: %s', [ProcessId, Which, LowerCase(IntToHex(Mask, 1))]);
  PrintStringLine(Line);
end;

function GetAffinityOrFail(ProcessId: Int64): QWord;
var
  CallResult: Int64;
begin
  CallResult := KernelGetAffinity(QWord(ProcessId));
  if CallResult < 0 then
    FailWithError(1, ErrorCodeOf(CallResult), Format('failed to get pid %d''s affinity', [ProcessId]));
  Result := QWord(CallResult);
end;

procedure SetAffinityOrFail(ProcessId: Int64; Mask: QWord);
var
  CallResult: Int64;
begin
  CallResult := KernelSetAffinity(QWord(ProcessId), Mask);
  if CallResult < 0 then
    FailWithError(1, ErrorCodeOf(CallResult), Format('failed to set pid %d''s affinity', [ProcessId]));
end;

procedure ParseOptions;
var
  Text: string;
  Position: Integer;
begin
  ForProcess := False;
  UseList := False;
  Arguments := ProgramArguments;
  First := 0;
  while First < Length(Arguments) do
  begin
    Text := Arguments[First];
    if Text = '--help' then
    begin
      PrintString(Usage);
      Halt(0);
    end
    else if Text = '--pid' then
      ForProcess := True
    else if Text = '--cpu-list' then
      UseList := True
    else if Text = '--' then
    begin
      Inc(First);
      Break;
    end
    else if (Length(Text) >= 2) and (Text[1] = '-') then
    begin
      for Position := 2 to Length(Text) do
        case Text[Position] of
          'p': ForProcess := True;
          'c': UseList := True;
        else
          FailWithUsageHint('invalid option -- ''' + Text[Position] + '''');
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
  Remaining: Integer;
begin
  Remaining := Length(Arguments) - First;
  if (Remaining < 1) or (Remaining > 2) then
    FailWithUsageHint('wrong number of arguments');
  if not ParseDecimal(Arguments[High(Arguments)], ProcessId) or (ProcessId < 0) then
    Fail(1, Format('invalid PID argument: ''%s''', [Arguments[High(Arguments)]]));
  WriteAffinity(ProcessId, 'current', GetAffinityOrFail(ProcessId));
  if Remaining = 2 then
  begin
    if not ParseAffinity(Arguments[First], Mask) then
      Fail(1, Format('failed to parse affinity ''%s''', [Arguments[First]]));
    SetAffinityOrFail(ProcessId, Mask);
    WriteAffinity(ProcessId, 'new', GetAffinityOrFail(ProcessId));
  end;
end;

procedure HandleCommand;
var
  Mask: QWord;
  Options: TProcessOptions;
begin
  if Length(Arguments) - First < 2 then
    FailWithUsageHint('missing command');
  if not ParseAffinity(Arguments[First], Mask) then
    Fail(1, Format('failed to parse affinity ''%s''', [Arguments[First]]));
  { Set on this process; the command inherits it. }
  SetAffinityOrFail(0, Mask);
  DefaultProcessOptions(Options);
  RunCommandAndExit(Copy(Arguments, First + 1, MaxInt), Options);
end;

begin
  ParseOptions;
  if ForProcess then
    HandleProcess
  else
    HandleCommand;
end.
