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
  touch - change file timestamps

  touch [-acmh] [-d DATE | -t STAMP | -r FILE] FILE...

  Sets the access and modification times of each FILE to now (or to the
  given time), creating it if it does not exist (unless -c). -a changes
  only the access time, -m only the modification time. DATE uses the
  forms of Util.Dates; STAMP is [[CC]YY]MMDDhhmm[.ss].
}
program touch;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  Abi.SystemCalls,
  Runtime.Time,
  Sys.Errors,
  Sys.Files,
  Sys.Time,
  Util.CommandLine,
  Util.Dates,
  Util.Messages;

const
  Usage = 'Usage: touch [OPTION]... FILE...'#10 +
    'Update the access and modification times of each FILE to the current time.'#10#10 +
    'A FILE argument that does not exist is created empty, unless -c or -h'#10 +
    'is supplied.'#10#10 +
    '  -a                     change only the access time'#10 +
    '  -c, --no-create        do not create any files'#10 +
    '  -d, --date=STRING      parse STRING and use it instead of current time'#10 +
    '  -h, --no-dereference   affect each symbolic link instead of any referenced'#10 +
    '                         file'#10 +
    '  -m                     change only the modification time'#10 +
    '  -r, --reference=FILE   use this file''s times instead of current time'#10 +
    '  -t STAMP               use [[CC]YY]MMDDhhmm[.ss] instead of current time'#10;

  OptionAccessOnly = 1;
  OptionNoCreate = 2;
  OptionDate = 3;
  OptionNoDereference = 4;
  OptionModificationOnly = 5;
  OptionReference = 6;
  OptionStamp = 7;

var
  NoCreate: Boolean;
  FollowLinks: Boolean;
  ChangeAccess: Boolean;
  ChangeModification: Boolean;
  AccessTime: TUnixTime;
  ModificationTime: TUnixTime;
  UseNow: Boolean;

{ Creates Path if needed and sets its times; False after reporting a
  failure. }
function TouchFile(const Path: string): Boolean;
var
  Handle: Int64;
  Error: LongInt;
begin
  Result := True;
  if not PathExists(PChar(Path)) then
  begin
    if NoCreate then
      Exit;
    Handle := OpenFile(PChar(Path), OpenWrite or OpenCreate);
    if Handle < 0 then
    begin
      ReportError(ErrorCodeOf(Handle), Format('cannot touch ''%s''', [Path]));
      Exit(False);
    end;
    CloseFile(Handle);
  end;
  if UseNow then
    Error := SetFileTimesToNow(PChar(Path), ChangeModification, ChangeAccess, FollowLinks)
  else
    Error := SetFileTimes(PChar(Path), ModificationTime, AccessTime, FollowLinks);
  if Error <> ErrorNone then
  begin
    ReportError(Error, Format('setting times of ''%s''', [Path]));
    Result := False;
  end;
end;

var
  CommandLine: TCommandLine;
  Code: Integer;
  Value: string;
  Information: TFileInformation;
  Operand: string;
  Error: LongInt;
  ExitStatus: LongInt;
  Time: TUnixTime;
begin
  UseNow := True;
  NoCreate := False;
  FollowLinks := True;
  ChangeAccess := False;
  ChangeModification := False;
  Time := CurrentTime;
  AccessTime := Time;
  ModificationTime := Time;
  CommandLine := TCommandLine.Create([
    CommandOption('a', '', False, OptionAccessOnly),
    CommandOption('c', 'no-create', False, OptionNoCreate),
    CommandOption('d', 'date', True, OptionDate),
    CommandOption('h', 'no-dereference', False, OptionNoDereference),
    CommandOption('m', '', False, OptionModificationOnly),
    CommandOption('r', 'reference', True, OptionReference),
    CommandOption('t', '', True, OptionStamp),
    CommandOption('f', '', False, 0)], Usage);
  while CommandLine.NextOption(Code, Value) do
    case Code of
      OptionAccessOnly: ChangeAccess := True;
      OptionNoCreate: NoCreate := True;
      OptionDate:
        begin
          UseNow := False;
          if not ParseDateText(Value, Time) then
            Fail(1, Format('invalid date format ''%s''', [Value]));
          AccessTime := Time;
          ModificationTime := Time;
        end;
      OptionNoDereference:
        begin
          FollowLinks := False;
          NoCreate := True;
        end;
      OptionModificationOnly: ChangeModification := True;
      OptionReference:
        begin
          UseNow := False;
          Error := GetFileInformation(PChar(Value), Information);
          if Error <> ErrorNone then
            FailWithError(1, Error, Format('failed to get attributes of ''%s''', [Value]));
          AccessTime := Information.AccessTime;
          ModificationTime := Information.ModificationTime;
        end;
      OptionStamp:
        begin
          UseNow := False;
          if not ParseTouchStamp(Value, Time) then
            Fail(1, Format('invalid date format ''%s''', [Value]));
          AccessTime := Time;
          ModificationTime := Time;
        end;
    end;
  { Neither -a nor -m: change both. }
  if not ChangeAccess and not ChangeModification then
  begin
    ChangeAccess := True;
    ChangeModification := True;
  end;
  if not ChangeAccess then
    AccessTime := -1;
  if not ChangeModification then
    ModificationTime := -1;
  if CommandLine.OperandCount = 0 then
    FailWithUsageHint('missing file operand');

  ExitStatus := 0;
  for Operand in CommandLine.Operands do
    if not TouchFile(Operand) then
      ExitStatus := 1;
  Halt(ExitStatus);
end.
