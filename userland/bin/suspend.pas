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

  suspend

  The machine sleeps with its memory kept (ACPI S3) and comes back where
  it was when woken (the power button, or the platform's other wake
  events); suspend then returns. Only root may.
}
program suspend;

{$mode objfpc}{$H+}

uses
  Sys.Kernel,
  Sys.Errors,
  Util.CommandLine,
  Util.Messages;

const
  Usage = 'Usage: suspend'#10 +
    'Suspend the system to RAM until it is woken.'#10;

var
  CommandLine: TCommandLine;
  Status: Int64;
begin
  CommandLine := TCommandLine.Create([], Usage);
  CommandLine.ReadOperandsOnly;
  if CommandLine.OperandCount <> 0 then
    FailWithUsageHint('no arguments are taken');
  Status := KernelSuspend;
  if Status < 0 then
    FailWithError(1, ErrorCodeOf(Status), 'cannot suspend');
end.
