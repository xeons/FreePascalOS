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

uses
  Sys.Format,
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

var
  Parser: TOptionParser;
  Code: Integer;
  Value: PChar;
  LongFormat: Boolean;
  Index: Integer;
  UserId: LongWord;
  Name: PChar;
  BootTime: Int64;
  DateTime: TDateTime;
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
    begin
      if not FindUserId(Parser.Operands[Index], UserId) or (UserNameOf(UserId) = nil) then
      begin
        WriteFormatted(StandardOutput, 'Login name: %-28s In real life:  ???'#10, [ArgumentText(Parser.Operands[Index])]);
        Continue;
      end;
      WriteFormatted(StandardOutput, 'Login name: %-28s In real life:  %s'#10, [ArgumentText(UserNameOf(UserId)),
        ArgumentText(UserNameOf(UserId))]);
      WriteFormatted(StandardOutput, 'Directory: %-29s Shell:  /bin/sh'#10#10, [ArgumentText(HomeDirectoryOf(UserId))]);
    end;
    Halt(0);
  end;

  Name := UserNameOf(CurrentRealUserId);
  if Name = nil then
    Name := 'root';
  PrintLine('Login    Name                 TTY      Idle   When');
  BootTime := CurrentTime - Int64(UptimeMilliseconds div 1000);
  DecodeTime(BootTime, DateTime);
  WriteFormatted(StandardOutput, '%-8s %-20s console         %04d-%02d-%02d %02d:%02d'#10, [ArgumentText(Name),
    ArgumentText(Name), ArgumentNumber(DateTime.Year), ArgumentNumber(DateTime.Month),
    ArgumentNumber(DateTime.Day), ArgumentNumber(DateTime.Hour), ArgumentNumber(DateTime.Minute)]);
end.
