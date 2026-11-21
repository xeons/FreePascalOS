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
  umount - unmount volumes

  umount [-f] DIRECTORY|/volumes/NAME|/dev/DEVICE...

  Writes the volume back and takes it away: from its directory and
  from /volumes (a USB disk may then be unplugged safely). Refused
  while a file or folder on it is open or a program works in it,
  unless -f is given (its open files then fail).
}
program umount;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Errors,
  Sys.Mounts,
  Sys.Streams,
  Util.CommandLine,
  Util.Messages;

const
  Usage = 'Usage: umount [OPTION]... DIRECTORY...'#10 +
    'Unmount the volumes at the directories (or /volumes/NAME, /dev/DEVICE).'#10 +
    #10 +
    '  -f, --force    unmount even while it is in use'#10 +
    '  -v, --verbose  say what was unmounted'#10;

  OptionForce = 1;
  OptionVerbose = 2;

{ /dev/DEVICE stands for the mounted volume of that device. }
function PathOfDevice(const Path: string): string;
var
  Index: Integer;
  Description: TMountDescription;
begin
  Result := Path;
  if Copy(Path, 1, 5) <> '/dev/' then
    Exit;
  Index := 0;
  while GetMountDescription(Index, Description) do
  begin
    if Description.Source = Path then
      Exit(Description.MountPoint);
    Inc(Index);
  end;
end;

var
  CommandLine: TCommandLine;
  Code: Integer;
  Value: string;
  Force: Boolean;
  Verbose: Boolean;
  Operand: string;
  Error: LongInt;
  ExitStatus: LongInt;
begin
  Force := False;
  Verbose := False;
  CommandLine := TCommandLine.Create([
    CommandOption('f', 'force', False, OptionForce),
    CommandOption('v', 'verbose', False, OptionVerbose)], Usage);
  while CommandLine.NextOption(Code, Value) do
    case Code of
      OptionForce: Force := True;
      OptionVerbose: Verbose := True;
    end;
  if CommandLine.OperandCount = 0 then
    FailWithUsageHint('missing operand');

  ExitStatus := 0;
  for Operand in CommandLine.Operands do
  begin
    Error := UnmountVolume(PathOfDevice(Operand), Force);
    if Error = ErrorInvalidArgument then
    begin
      PrintErrorStringLine(Format('umount: %s: not a mount point', [Operand]));
      ExitStatus := 1;
    end
    else if Error = ErrorBusy then
    begin
      PrintErrorStringLine(Format('umount: %s: target is busy', [Operand]));
      ExitStatus := 1;
    end
    else if Error <> ErrorNone then
    begin
      ReportError(Error, Format('cannot unmount %s', [Operand]));
      ExitStatus := 1;
    end
    else if Verbose then
      PrintStringLine(Format('unmounted %s', [Operand]));
  end;
  CommandLine.Free;
  Halt(ExitStatus);
end.
