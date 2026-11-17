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
  What every part of ChartTest checks with: a check prints a line and
  counts.
}
unit ChartTest.Checks;

{$mode objfpc}
{$H+}

interface

var
  Passed: Integer = 0;
  Failed: Integer = 0;

procedure Check(const Name: string; Condition: Boolean);
procedure CheckNear(const Name: string; Got, Expected: Double);
procedure CheckText(const Name, Got, Expected: string);
procedure CheckNumber(const Name: string; Got, Expected: Int64);
procedure CheckColor(const Name: string; Got, Expected: LongWord);

implementation

uses
  SysUtils;

procedure Check(const Name: string; Condition: Boolean);
begin
  if Condition then
  begin
    Inc(Passed);
    WriteLn('[chart] pass: ', Name);
  end
  else
  begin
    Inc(Failed);
    WriteLn('[chart] FAIL: ', Name);
  end;
end;

procedure CheckNear(const Name: string; Got, Expected: Double);
begin
  Check(Name + ' (' + FloatToStr(Got) + ', expected ' + FloatToStr(Expected) + ')',
    Abs(Got - Expected) <= 1E-6 * (1 + Abs(Expected)));
end;

procedure CheckText(const Name, Got, Expected: string);
begin
  Check(Name + ' ("' + Got + '", expected "' + Expected + '")', Got = Expected);
end;

procedure CheckNumber(const Name: string; Got, Expected: Int64);
begin
  Check(Name + ' (' + IntToStr(Got) + ', expected ' + IntToStr(Expected) + ')', Got = Expected);
end;

procedure CheckColor(const Name: string; Got, Expected: LongWord);
begin
  Check(Name + ' (' + IntToHex(Got, 8) + ', expected ' + IntToHex(Expected, 8) + ')', Got = Expected);
end;

end.
