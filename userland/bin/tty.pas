{
  tty - print the file name of the terminal connected to standard input

  tty [-s]

  The only terminal is the console, /dev/console.
}
program tty;

{$mode objfpc}

uses
  Abi.SystemCalls,
  Sys.Console,
  Sys.Streams,
  Util.Options;

const
  Usage: PChar = 'Usage: tty [OPTION]...'#10 +
    'Print the file name of the terminal connected to standard input.'#10#10 +
    '  -s, --silent, --quiet   print nothing, only return an exit status'#10;

  OptionSilent = 1;

var
  Parser: TOptionParser;
  Code: Integer;
  Value: PChar;
  Silent: Boolean;
begin
  Silent := False;
  BeginOptions(Parser, [
    OptionDefinition('s', 'silent', False, OptionSilent),
    OptionDefinition(#0, 'quiet', False, OptionSilent)], Usage);
  while NextOption(Parser, Code, Value) do
    Silent := True;
  if IsConsole(StandardInputHandle) then
  begin
    if not Silent then
      PrintLine('/dev/console');
    Halt(0);
  end;
  if not Silent then
    PrintLine('not a tty');
  Halt(1);
end.
