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
  uptime - tell how long the system has been running

  uptime [-ps]

  Load averages are the kernel's exponentially decayed counts of threads
  running or ready to run, sampled every 5 seconds.
}
program uptime;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Kernel,
  Sys.Time,
  Util.CommandLine,
  Sys.Streams;

const
  Usage = 'Usage: uptime [OPTION]...'#10 +
    'Print the current time, the length of time the system has been up,'#10 +
    'the number of users on the system, and the average number of jobs'#10 +
    'in the run queue over the last 1, 5 and 15 minutes.'#10#10 +
    '  -p, --pretty   show uptime in pretty format'#10 +
    '  -s, --since    system up since, in yyyy-mm-dd HH:MM:SS format'#10;

  OptionPretty = 1;
  OptionSince = 2;

{ "1 day", "2 hours" }
function CountText(Count: Int64; const Noun: string): string;
begin
  Result := IntToStr(Count) + ' ' + Noun;
  if Count <> 1 then
    Result := Result + 's';
end;

function LoadText(Hundredths: LongWord): string;
begin
  Result := Format('%d.%.2d', [Hundredths div 100, Hundredths mod 100]);
end;

procedure PrintSince(UpSeconds: Int64);
var
  Since: Sys.Time.TDateTime;
begin
  DecodeTime(CurrentTime - UpSeconds, Since);
  PrintString(Format('%.4d-%.2d-%.2d %.2d:%.2d:%.2d'#10, [Since.Year, Since.Month, Since.Day,
    Since.Hour, Since.Minute, Since.Second]));
end;

procedure PrintPretty(Days, Hours, Minutes: Int64);
var
  Parts: string;
begin
  Parts := '';
  if Days > 0 then
    Parts := CountText(Days, 'day');
  if Hours > 0 then
  begin
    if Parts <> '' then
      Parts := Parts + ', ';
    Parts := Parts + CountText(Hours, 'hour');
  end;
  if (Minutes > 0) or (Parts = '') then
  begin
    if Parts <> '' then
      Parts := Parts + ', ';
    Parts := Parts + CountText(Minutes, 'minute');
  end;
  PrintString('up ' + Parts + #10);
end;

procedure PrintSummary(Days, Hours, Minutes: Int64);
var
  Information: TAbiSystemInformation;
  Moment: Sys.Time.TDateTime;
  Line: string;
begin
  DecodeTime(CurrentTime, Moment);
  Line := Format(' %.2d:%.2d:%.2d up ', [Moment.Hour, Moment.Minute, Moment.Second]);
  if Days > 0 then
    Line := Line + CountText(Days, 'day') + ', ';
  if Hours > 0 then
    Line := Line + Format('%2d:%.2d, ', [Hours, Minutes])
  else
    Line := Line + Format('%d min, ', [Minutes]);
  Line := Line + ' 1 user,  load average: ';
  if KernelGetSystemInformation(Information) < 0 then
    FillChar(Information, SizeOf(Information), 0);
  Line := Line + LoadText(Information.LoadAverages[0]) + ', ' +
    LoadText(Information.LoadAverages[1]) + ', ' + LoadText(Information.LoadAverages[2]);
  PrintString(Line + #10);
end;

var
  CommandLine: TCommandLine;
  Code: Integer;
  Value: string;
  Mode: Integer;
  UpSeconds: Int64;
  Days, Hours, Minutes: Int64;
begin
  Mode := 0;
  CommandLine := TCommandLine.Create([
    CommandOption('p', 'pretty', False, OptionPretty),
    CommandOption('s', 'since', False, OptionSince)], Usage);
  while CommandLine.NextOption(Code, Value) do
    Mode := Code;

  UpSeconds := Int64(UptimeMilliseconds div 1000);
  Days := UpSeconds div 86400;
  Hours := (UpSeconds mod 86400) div 3600;
  Minutes := (UpSeconds mod 3600) div 60;

  case Mode of
    OptionSince: PrintSince(UpSeconds);
    OptionPretty: PrintPretty(Days, Hours, Minutes);
  else
    PrintSummary(Days, Hours, Minutes);
  end;
end.
