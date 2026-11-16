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
  ln - make links between files

  ln [-sfnTv] TARGET LINK_NAME
  ln [-sfnv] TARGET... DIRECTORY

  Makes hard links (other names for the same file; ext2/3/4 only, within
  one volume), or symbolic links with -s.
}
program ln;

{$mode objfpc}{$H+}

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Files,
  Util.CommandLine,
  Util.Messages,
  Util.Output,
  Util.Paths;

const
  Usage = 'Usage: ln [OPTION]... TARGET LINK_NAME'#10 +
    '  or:  ln [OPTION]... TARGET... DIRECTORY'#10 +
    'Create hard links by default, symbolic links with --symbolic.'#10 +
    #10 +
    '  -f, --force                remove existing destination files'#10 +
    '  -n, --no-dereference       treat LINK_NAME as a normal file if it is a'#10 +
    '                               symbolic link to a directory'#10 +
    '  -s, --symbolic             make symbolic links instead of hard links'#10 +
    '  -T, --no-target-directory  treat LINK_NAME as a normal file always'#10 +
    '  -v, --verbose              print name of each linked file'#10;

  OptionForce = 1;
  OptionNoDereference = 2;
  OptionSymbolic = 3;
  OptionNoTargetDirectory = 4;
  OptionVerbose = 5;

var
  Force: Boolean;
  Verbose: Boolean;
  Symbolic: Boolean;

function LinkOne(const Target, LinkName: string): Boolean;
var
  Error: LongInt;
begin
  if Force and PathExists(PChar(LinkName)) and not IsDirectory(PChar(LinkName)) then
    RemovePath(PChar(LinkName));
  if Symbolic then
    Error := CreateSymbolicLink(PChar(Target), PChar(LinkName))
  else
    Error := CreateHardLink(PChar(Target), PChar(LinkName));
  if Error <> ErrorNone then
  begin
    if Symbolic then
      ReportError(Error, Format('failed to create symbolic link ''%s''', [LinkName]))
    else
      ReportError(Error, Format('failed to create hard link ''%s'' => ''%s''', [LinkName, Target]));
    Exit(False);
  end;
  if Verbose then
  begin
    if Symbolic then
      PrintString(Format('''%s'' -> ''%s'''#10, [LinkName, Target]))
    else
      PrintString(Format('''%s'' => ''%s'''#10, [LinkName, Target]));
  end;
  Result := True;
end;

{ True if Destination names a directory to link into. }
function IsDestinationDirectory(const Destination: string; NoDereference: Boolean): Boolean;
var
  Information: TFileInformation;
begin
  Result := IsDirectory(PChar(Destination));
  if Result and NoDereference and
     (GetLinkInformation(PChar(Destination), Information) = ErrorNone) and
     (Information.Kind = KindSymbolicLink) then
    Result := False;
end;

var
  CommandLine: TCommandLine;
  Code: Integer;
  Value: string;
  NoDereference: Boolean;
  NoTargetDirectory: Boolean;
  Destination: string;
  Index: Integer;
  ExitStatus: LongInt;
  DestinationIsDirectory: Boolean;
begin
  Force := False;
  Verbose := False;
  Symbolic := False;
  NoDereference := False;
  NoTargetDirectory := False;
  CommandLine := TCommandLine.Create([
    CommandOption('f', 'force', False, OptionForce),
    CommandOption('n', 'no-dereference', False, OptionNoDereference),
    CommandOption('s', 'symbolic', False, OptionSymbolic),
    CommandOption('T', 'no-target-directory', False, OptionNoTargetDirectory),
    CommandOption('v', 'verbose', False, OptionVerbose)], Usage);
  while CommandLine.NextOption(Code, Value) do
    case Code of
      OptionForce: Force := True;
      OptionNoDereference: NoDereference := True;
      OptionSymbolic: Symbolic := True;
      OptionNoTargetDirectory: NoTargetDirectory := True;
      OptionVerbose: Verbose := True;
    end;
  if CommandLine.OperandCount = 0 then
    FailWithUsageHint('missing file operand');

  if CommandLine.OperandCount = 1 then
  begin
    { "ln -s TARGET" links into the current directory. }
    if LinkOne(CommandLine.Operands[0], BaseName(CommandLine.Operands[0])) then
      Halt(0);
    Halt(1);
  end;

  Destination := CommandLine.Operands[CommandLine.OperandCount - 1];
  DestinationIsDirectory := IsDestinationDirectory(Destination, NoDereference);
  if NoTargetDirectory or ((CommandLine.OperandCount = 2) and not DestinationIsDirectory) then
  begin
    if CommandLine.OperandCount > 2 then
      FailWithUsageHint(Format('extra operand ''%s''', [CommandLine.Operands[2]]));
    if LinkOne(CommandLine.Operands[0], Destination) then
      Halt(0);
    Halt(1);
  end;
  if not DestinationIsDirectory then
    Fail(1, Format('target ''%s'' is not a directory', [Destination]));

  ExitStatus := 0;
  for Index := 0 to CommandLine.OperandCount - 2 do
    if not LinkOne(CommandLine.Operands[Index],
                   JoinPath(Destination, BaseName(CommandLine.Operands[Index]))) then
      ExitStatus := 1;
  Halt(ExitStatus);
end.
