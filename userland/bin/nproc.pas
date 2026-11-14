{
  nproc - print the number of processing units available

  nproc [--all] [--ignore=N]
}
program nproc;

{$mode objfpc}

uses
  Sys.Format,
  Sys.Information,
  Sys.Streams,
  Sys.Text,
  Util.Messages,
  Util.Options;

const
  Usage: PChar = 'Usage: nproc [OPTION]...'#10 +
    'Print the number of processing units available to the current process.'#10#10 +
    '      --all       print the number of installed processors'#10 +
    '      --ignore=N  if possible, exclude N processing units'#10;

  OptionAll = 1;
  OptionIgnore = 2;

var
  Parser: TOptionParser;
  Code: Integer;
  Value: PChar;
  Ignore: Int64;
  Information: TSystemInformation;
  Count: Int64;
begin
  Ignore := 0;
  BeginOptions(Parser, [
    OptionDefinition(#0, 'all', False, OptionAll),
    OptionDefinition(#0, 'ignore', True, OptionIgnore)], Usage);
  while NextOption(Parser, Code, Value) do
    if Code = OptionIgnore then
      if not ParseInteger(Value, Ignore) or (Ignore < 0) then
        Fail(1, 'invalid number: ''%s''', [ArgumentText(Value)]);
  GetSystemInformation(Information);
  Count := Information.ProcessorCount - Ignore;
  if Count < 1 then
    Count := 1;
  WriteDecimal(StandardOutput, Count);
  WriteCharacter(StandardOutput, #10);
end.
