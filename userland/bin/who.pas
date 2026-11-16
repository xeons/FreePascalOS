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
  who - show who is logged on

  who [-abHqs] [am i]

  The system has one session: the real user of the process on the
  console, logged in since the system started.
}
program who;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  Sys.Streams,
  Sys.Time,
  Util.Accounts,
  Util.Options;

const
  Usage: PChar = 'Usage: who [OPTION]... [ am i ]'#10 +
    'Print information about users who are currently logged in.'#10#10 +
    '  -a, --all         same as -b -H'#10 +
    '  -b, --boot        time of last system boot'#10 +
    '  -H, --heading     print line of column headings'#10 +
    '  -q, --count       all login names and number of users logged on'#10 +
    '  -s, --short       print only name, line, and time (default)'#10;

  OptionAll = 1;
  OptionBoot = 2;
  OptionHeading = 3;
  OptionCount = 4;
  OptionShort = 5;

function TimestampText(Time: Int64): string;
var
  DateTime: Sys.Time.TDateTime;
begin
  DecodeTime(Time, DateTime);
  Result := Format('%.4d-%.2d-%.2d %.2d:%.2d', [DateTime.Year, DateTime.Month, DateTime.Day,
    DateTime.Hour, DateTime.Minute]);
end;

procedure PrintText(const Text: string);
begin
  PrintLine(PChar(Text));
end;

var
  Parser: TOptionParser;
  Code: Integer;
  Value: PChar;
  ShowBoot: Boolean;
  ShowHeading: Boolean;
  ShowCount: Boolean;
  ShowSessions: Boolean;
  BootTime: Int64;
  Name: string;
begin
  ShowBoot := False;
  ShowHeading := False;
  ShowCount := False;
  ShowSessions := True;
  BeginOptions(Parser, [
    OptionDefinition('a', 'all', False, OptionAll),
    OptionDefinition('b', 'boot', False, OptionBoot),
    OptionDefinition('H', 'heading', False, OptionHeading),
    OptionDefinition('q', 'count', False, OptionCount),
    OptionDefinition('s', 'short', False, OptionShort)], Usage);
  while NextOption(Parser, Code, Value) do
    case Code of
      OptionAll:
        begin
          ShowBoot := True;
          ShowHeading := True;
        end;
      OptionBoot:
        begin
          ShowBoot := True;
          ShowSessions := False;
        end;
      OptionHeading: ShowHeading := True;
      OptionCount: ShowCount := True;
    end;

  if UserNameOf(CurrentRealUserId) = nil then
    Name := 'root'
  else
    Name := UserNameOf(CurrentRealUserId);
  if ShowCount then
  begin
    PrintText(Name);
    PrintLine('# users=1');
    Halt(0);
  end;

  BootTime := CurrentTime - Int64(UptimeMilliseconds div 1000);
  if ShowHeading then
    PrintLine('NAME     LINE         TIME');
  if ShowBoot then
    PrintText('         system boot  ' + TimestampText(BootTime));
  if ShowSessions then
    PrintText(Format('%-8s console      ', [Name]) + TimestampText(BootTime));
end.
