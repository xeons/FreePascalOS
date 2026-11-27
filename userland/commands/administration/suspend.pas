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
  suspend - suspend the system to RAM

  suspend [-t SECONDS]

  The machine sleeps with its memory kept (ACPI S3) and comes back where
  it was when woken (the power button, or the platform's other wake
  sources: see powerstat); suspend then returns. With -t the battery
  backed clock's alarm wakes it SECONDS later (CallSetWakeAlarm; at
  most a day on a PC). Only root may.
}
program suspend;

{$mode objfpc}{$H+}

uses
  SysUtils,
  Sys.Kernel,
  Sys.Errors,
  Util.CommandLine,
  Util.Messages;

const
  Usage = 'Usage: suspend [-t SECONDS]'#10 +
    'Suspend the system to RAM until it is woken (with -t, by the clock''s alarm'#10 +
    'SECONDS later at the latest).'#10;

var
  Status: Int64;
  Seconds: Int64;
begin
  Seconds := 0;
  if (ParamCount = 2) and (ParamStr(1) = '-t') then
  begin
    Seconds := StrToInt64Def(ParamStr(2), -1);
    if Seconds <= 0 then
      FailWithUsageHint('-t takes a number of seconds');
  end
  else if ParamCount = 1 then
  begin
    if (ParamStr(1) = '--help') or (ParamStr(1) = '-h') then
    begin
      Write(Usage);
      Halt(0);
    end;
    FailWithUsageHint('unknown argument: ' + ParamStr(1));
  end
  else if ParamCount <> 0 then
    FailWithUsageHint('too many arguments');
  if Seconds > 0 then
  begin
    Status := KernelSetWakeAlarm(QWord(Seconds));
    if Status < 0 then
      FailWithError(1, ErrorCodeOf(Status), 'cannot set the wake alarm');
  end;
  Status := KernelSuspend;
  if Status < 0 then
    FailWithError(1, ErrorCodeOf(Status), 'cannot suspend');
end.
