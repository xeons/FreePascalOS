{
  uptime - tell how long the system has been running

  uptime [-ps]

  Load averages are the kernel's exponentially decayed counts of threads
  running or ready to run, sampled every 5 seconds.
}
program uptime;

{$mode objfpc}

uses
  Abi.SystemCalls,
  Runtime.Memory,
  Sys.Kernel,
  Sys.Format,
  Sys.Streams,
  Sys.Time,
  Util.Messages,
  Util.Options;

const
  Usage: PChar = 'Usage: uptime [OPTION]...'#10 +
    'Print the current time, the length of time the system has been up,'#10 +
    'the number of users on the system, and the average number of jobs'#10 +
    'in the run queue over the last 1, 5 and 15 minutes.'#10#10 +
    '  -p, --pretty   show uptime in pretty format'#10 +
    '  -s, --since    system up since, in yyyy-mm-dd HH:MM:SS format'#10;

  OptionPretty = 1;
  OptionSince = 2;

function Plural(Count: Int64): PChar;
begin
  if Count = 1 then
    Result := ''
  else
    Result := 's';
end;

procedure WriteLoad(Hundredths: LongWord);
begin
  WriteFormatted(StandardOutput, '%d.%02d', [ArgumentNumber(Hundredths div 100),
    ArgumentNumber(Hundredths mod 100)]);
end;

var
  Information: TAbiSystemInformation;
  Parser: TOptionParser;
  Code: Integer;
  Value: PChar;
  Mode: Integer;
  UpSeconds: Int64;
  Days, Hours, Minutes: Int64;
  Now: TDateTime;
  Since: TDateTime;
  PrintedPart: Boolean;
begin
  Mode := 0;
  BeginOptions(Parser, [
    OptionDefinition('p', 'pretty', False, OptionPretty),
    OptionDefinition('s', 'since', False, OptionSince)], Usage);
  while NextOption(Parser, Code, Value) do
    Mode := Code;

  UpSeconds := Int64(UptimeMilliseconds div 1000);
  Days := UpSeconds div 86400;
  Hours := (UpSeconds mod 86400) div 3600;
  Minutes := (UpSeconds mod 3600) div 60;

  case Mode of
    OptionSince:
      begin
        DecodeTime(CurrentTime - UpSeconds, Since);
        WriteFormatted(StandardOutput, '%04d-%02d-%02d %02d:%02d:%02d'#10, [ArgumentNumber(Since.Year),
          ArgumentNumber(Since.Month), ArgumentNumber(Since.Day), ArgumentNumber(Since.Hour),
          ArgumentNumber(Since.Minute), ArgumentNumber(Since.Second)]);
      end;
    OptionPretty:
      begin
        WriteText(StandardOutput, 'up ');
        PrintedPart := False;
        if Days > 0 then
        begin
          WriteFormatted(StandardOutput, '%d day%s', [ArgumentNumber(Days), ArgumentText(Plural(Days))]);
          PrintedPart := True;
        end;
        if Hours > 0 then
        begin
          if PrintedPart then
            WriteText(StandardOutput, ', ');
          WriteFormatted(StandardOutput, '%d hour%s', [ArgumentNumber(Hours), ArgumentText(Plural(Hours))]);
          PrintedPart := True;
        end;
        if (Minutes > 0) or not PrintedPart then
        begin
          if PrintedPart then
            WriteText(StandardOutput, ', ');
          WriteFormatted(StandardOutput, '%d minute%s', [ArgumentNumber(Minutes), ArgumentText(Plural(Minutes))]);
        end;
        WriteCharacter(StandardOutput, #10);
      end;
  else
    begin
      DecodeTime(CurrentTime, Now);
      WriteFormatted(StandardOutput, ' %02d:%02d:%02d up ', [ArgumentNumber(Now.Hour), ArgumentNumber(Now.Minute),
        ArgumentNumber(Now.Second)]);
      if Days > 0 then
        WriteFormatted(StandardOutput, '%d day%s, ', [ArgumentNumber(Days), ArgumentText(Plural(Days))]);
      if Hours > 0 then
        WriteFormatted(StandardOutput, '%2d:%02d, ', [ArgumentNumber(Hours), ArgumentNumber(Minutes)])
      else
        WriteFormatted(StandardOutput, '%d min, ', [ArgumentNumber(Minutes)]);
      WriteText(StandardOutput, ' 1 user,  load average: ');
      if KernelGetSystemInformation(Information) < 0 then
        ZeroMemory(@Information, SizeOf(Information));
      WriteLoad(Information.LoadAverages[0]);
      WriteText(StandardOutput, ', ');
      WriteLoad(Information.LoadAverages[1]);
      WriteText(StandardOutput, ', ');
      WriteLoad(Information.LoadAverages[2]);
      WriteCharacter(StandardOutput, #10);
    end;
  end;
end.
