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
  pinky - lightweight finger

  pinky [-ls] [USER]...

  Shows the console session (-s, the default) or account details (-l).
}
program pinky;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  Sys.Streams,
  Sys.Time,
  Util.Accounts,
  Util.Messages,
  Util.Options;

const
  Usage: PChar = 'Usage: pinky [OPTION]... [USER]...'#10 +
    'A lightweight ''finger'' program;  print user information.'#10#10 +
    '  -l              produce long format output for the specified USERs'#10 +
    '  -s              do short format output, this is the default'#10;

  OptionLong = 1;
  OptionShort = 2;

procedure Print(const Text: string);
begin
  WriteText(StandardOutput, PChar(Text));
end;

procedure PrintLongFormat(const Requested: string);
var
  UserId: LongWord;
  Name: string;
begin
  if not FindUserId(PChar(Requested), UserId) or (UserNameOf(UserId) = nil) then
  begin
    Print(Format('Login name: %-28s In real life:  ???'#10, [Requested]));
    Exit;
  end;
  Name := UserNameOf(UserId);
  Print(Format('Login name: %-28s In real life:  %s'#10, [Name, Name]));
  Print(Format('Directory: %-29s Shell:  /bin/sh'#10#10, [string(HomeDirectoryOf(UserId))]));
end;

var
  Parser: TOptionParser;
  Code: Integer;
  Value: PChar;
  LongFormat: Boolean;
  Index: Integer;
  Name: string;
  BootTime: Int64;
  DateTime: Sys.Time.TDateTime;
begin
  LongFormat := False;
  BeginOptions(Parser, [
    OptionDefinition('l', nil, False, OptionLong),
    OptionDefinition('s', nil, False, OptionShort)], Usage);
  while NextOption(Parser, Code, Value) do
    LongFormat := Code = OptionLong;

  if LongFormat then
  begin
    if Parser.OperandCount = 0 then
      FailWithUsageHint('no username specified; at least one must be specified when using -l', []);
    for Index := 0 to Parser.OperandCount - 1 do
      PrintLongFormat(Parser.Operands[Index]);
    Halt(0);
  end;

  if UserNameOf(CurrentRealUserId) = nil then
    Name := 'root'
  else
    Name := UserNameOf(CurrentRealUserId);
  PrintLine('Login    Name                 TTY      Idle   When');
  BootTime := CurrentTime - Int64(UptimeMilliseconds div 1000);
  DecodeTime(BootTime, DateTime);
  Print(Format('%-8s %-20s console         %.4d-%.2d-%.2d %.2d:%.2d'#10, [Name, Name,
    DateTime.Year, DateTime.Month, DateTime.Day, DateTime.Hour, DateTime.Minute]));
end.
