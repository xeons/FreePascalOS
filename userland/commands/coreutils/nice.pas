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
  nice - run a program with modified scheduling priority

  nice [-n ADJUSTMENT] [COMMAND [ARG]...]

  Without COMMAND prints the current niceness. Otherwise adds ADJUSTMENT
  to it (clamped to -20 .. 19) and runs COMMAND, which inherits it. Only
  root may lower the niceness; for others nice warns and runs COMMAND
  anyway, as GNU nice does.
}
program nice;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  StrUtils,
  Sys.Kernel,
  Sys.Errors,
  Sys.Processes,
  Sys.Text,
  Util.CommandLine,
  Util.Commands,
  Util.Messages,
  Util.Numbers,
  Sys.Streams;

const
  Usage = 'Usage: nice [OPTION] [COMMAND [ARG]...]'#10 +
    'Run COMMAND with an adjusted niceness, which affects process scheduling.'#10 +
    'With no COMMAND, print the current niceness.'#10#10 +
    '  -n, --adjustment=N   add integer N to the niceness (default 10)'#10;

function ParseAdjustment(const Text: string): Int64;
begin
  if not ParseDecimal(Text, Result) then
    Fail(125, Format('invalid adjustment ''%s''', [Text]));
end;

{ The old form "nice -5 command" (or "nice --5 command"). }
function IsOldStyleAdjustment(const Text: string): Boolean;
begin
  Result := (Length(Text) >= 2) and (Text[1] = '-') and
    (IsDigit(Text[2]) or ((Text[2] = '-') and (Length(Text) >= 3) and IsDigit(Text[3])));
end;

var
  Arguments: TStringArray;
  First: Integer;
  Adjustment: Int64;
  Options: TProcessOptions;
  Text: string;
  Current: LongInt;
  Wanted: Int64;
  Error: Int64;
begin
  Arguments := ProgramArguments;
  First := 0;
  Adjustment := 10;
  if (Length(Arguments) > 0) and (Arguments[0] = '--help') then
  begin
    PrintString(Usage);
    Halt(0);
  end;
  if First < Length(Arguments) then
  begin
    Text := Arguments[First];
    if ((Text = '-n') or (Text = '--adjustment')) and (First + 1 < Length(Arguments)) then
    begin
      Adjustment := ParseAdjustment(Arguments[First + 1]);
      First := First + 2;
    end
    else if StartsStr('--adjustment=', Text) then
    begin
      Adjustment := ParseAdjustment(Copy(Text, 14, MaxInt));
      Inc(First);
    end
    else if IsOldStyleAdjustment(Text) then
    begin
      Adjustment := ParseAdjustment(Copy(Text, 2, MaxInt));
      Inc(First);
    end;
  end;
  if (First < Length(Arguments)) and (Arguments[First] = '--') then
    Inc(First);

  KernelGetPriority(0, Current);
  if First >= Length(Arguments) then
  begin
    PrintStringLine(IntToStr(Current));
    Halt(0);
  end;
  Wanted := Current + Adjustment;
  if Wanted < -20 then
    Wanted := -20;
  if Wanted > 19 then
    Wanted := 19;
  Error := KernelSetPriority(0, LongInt(Wanted));
  if Error < 0 then
    Report(Format('cannot set niceness: %s', [ErrorText(ErrorCodeOf(Error))]));
  DefaultProcessOptions(Options);
  RunCommandAndExit(Copy(Arguments, First, MaxInt), Options);
end.
