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
  ChartTest - the chart control's plain logic and drawing, on the host

    ChartTest [dejavu-sans-directory sample.ppm]

  The logic (ChartTest.Logic): nice ticks, ranges, formats, sliding
  series, stacking, bars' places, pie angles, axes. The drawing
  (ChartTest.Rendering): charts drawn on surfaces without text, looked
  at pixel by pixel, and what is under the pointer. With a font
  directory and a path, a sample picture with text is written there
  (and one at 150%, "-150" before the extension), for looking at.

  Every check prints a line; the last reads "N passed, M failed", and
  the exit code is 1 if any failed. This is a host tool, built with the
  normal Free Pascal runtime library.
}
program ChartTest;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  ChartTest.Checks,
  ChartTest.Logic,
  ChartTest.Rendering,
  ChartTest.Sample;

var
  SamplePath: string;
begin
  TestChartLogic;
  TestChartRendering;
  if ParamCount >= 2 then
  begin
    SamplePath := ParamStr(2);
    Check('sample picture written', WriteChartSample(ParamStr(1), SamplePath, 100));
    Check('sample picture at 150% written', WriteChartSample(ParamStr(1),
      ChangeFileExt(SamplePath, '') + '-150' + ExtractFileExt(SamplePath), 150));
  end;
  WriteLn(Passed, ' passed, ', Failed, ' failed');
  if Failed > 0 then
    Halt(1);
end.
