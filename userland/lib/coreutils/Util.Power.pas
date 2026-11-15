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
  The power commands (poweroff, reboot, halt): each asks the kernel to
  shut the system down its way (CallShutdown). Only root may.
}
unit Util.Power;

{$mode objfpc}

interface

{ Runs a power command: no arguments, then the shutdown Action
  (ShutdownPowerOff, ShutdownReboot, ShutdownHalt). }
procedure RunPowerCommand(Action: QWord; Usage: PChar);

implementation

uses
  Sys.Kernel,
  Sys.Errors,
  Util.Messages,
  Util.Options;

procedure RunPowerCommand(Action: QWord; Usage: PChar);
var
  Parser: TOptionParser;
  Status: Int64;
begin
  ParseOperandsOnly(Parser, Usage);
  if Parser.OperandCount <> 0 then
    FailWithUsageHint('no arguments are taken', []);
  Status := KernelShutdown(Action);
  if Status < 0 then
    FailWithError(1, ErrorCodeOf(Status), 'cannot shut down', []);
end;

end.
