{
  who - show who is logged on

  who [-abHqs] [am i]

  The system has one session: the real user of the process on the
  console, logged in since the system started.
}
program who;

{$mode objfpc}

uses
  Sys.Format,
  Sys.Streams,
  Sys.Time,
  Util.Accounts,
  Util.Messages,
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

procedure WriteTimestamp(Time: Int64);
var
  DateTime: TDateTime;
begin
  DecodeTime(Time, DateTime);
  WriteFormatted(StandardOutput, '%04d-%02d-%02d %02d:%02d', [ArgumentNumber(DateTime.Year),
    ArgumentNumber(DateTime.Month), ArgumentNumber(DateTime.Day), ArgumentNumber(DateTime.Hour),
    ArgumentNumber(DateTime.Minute)]);
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
  Name: PChar;
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

  Name := UserNameOf(CurrentRealUserId);
  if Name = nil then
    Name := 'root';
  if ShowCount then
  begin
    PrintLine(Name);
    PrintLine('# users=1');
    Halt(0);
  end;

  BootTime := CurrentTime - Int64(UptimeMilliseconds div 1000);
  if ShowHeading then
    PrintLine('NAME     LINE         TIME');
  if ShowBoot then
  begin
    WriteText(StandardOutput, '         system boot  ');
    WriteTimestamp(BootTime);
    WriteCharacter(StandardOutput, #10);
  end;
  if ShowSessions then
  begin
    WriteFormatted(StandardOutput, '%-8s console      ', [ArgumentText(Name)]);
    WriteTimestamp(BootTime);
    WriteCharacter(StandardOutput, #10);
  end;
end.
