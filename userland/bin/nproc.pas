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
  nproc - print the number of processing units available

  nproc [--all] [--ignore=N]

  Without --all, only the processors this process may run on (its
  affinity, see taskset) are counted.
}
program nproc;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  Sys.Information,
  Sys.Kernel,
  Util.CommandLine,
  Util.Messages,
  Util.Numbers,
  Util.Output;

const
  Usage = 'Usage: nproc [OPTION]...'#10 +
    'Print the number of processing units available to the current process.'#10#10 +
    '      --all       print the number of installed processors'#10 +
    '      --ignore=N  if possible, exclude N processing units'#10;

  OptionAll = 1;
  OptionIgnore = 2;

var
  CommandLine: TCommandLine;
  Code: Integer;
  Value: string;
  Ignore: Int64;
  Information: TSystemInformation;
  Count: Int64;
  CountAll: Boolean;
  Mask: Int64;
begin
  CountAll := False;
  Ignore := 0;
  CommandLine := TCommandLine.Create([
    CommandOption(#0, 'all', False, OptionAll),
    CommandOption(#0, 'ignore', True, OptionIgnore)], Usage);
  while CommandLine.NextOption(Code, Value) do
    if Code = OptionAll then
      CountAll := True
    else if Code = OptionIgnore then
      if not ParseDecimal(Value, Ignore) or (Ignore < 0) then
        Fail(1, Format('invalid number: ''%s''', [Value]));
  GetSystemInformation(Information);
  Count := Information.ProcessorCount;
  Mask := KernelGetAffinity(0);
  if not CountAll and (Mask > 0) then
  begin
    Count := 0;
    while Mask <> 0 do
    begin
      Count := Count + (Mask and 1);
      Mask := Mask shr 1;
    end;
  end;
  Count := Count - Ignore;
  if Count < 1 then
    Count := 1;
  PrintStringLine(IntToStr(Count));
end.
