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
  AppsTest's checks: each prints a pass or FAIL line and is counted.
}
unit AppsTest.Checks;

{$mode objfpc}
{$H+}

interface

var
  Passed: LongInt = 0;
  Failed: LongInt = 0;

procedure Check(const Name: string; Condition: Boolean);
procedure CheckText(const Name, Actual, Expected: string);
procedure CheckNumber(const Name: string; Actual, Expected: Int64);
procedure CheckNear(const Name: string; Actual, Expected, Tolerance: Double);

implementation

uses
  SysUtils;

procedure Check(const Name: string; Condition: Boolean);
begin
  if Condition then
  begin
    Inc(Passed);
    WriteLn('[apps] pass: ', Name);
  end
  else
  begin
    Inc(Failed);
    WriteLn('[apps] FAIL: ', Name);
  end;
end;

procedure CheckText(const Name, Actual, Expected: string);
begin
  if Actual = Expected then
    Check(Name, True)
  else
    Check(Name + ' (got "' + Actual + '", expected "' + Expected + '")', False);
end;

procedure CheckNumber(const Name: string; Actual, Expected: Int64);
begin
  if Actual = Expected then
    Check(Name, True)
  else
    Check(Name + ' (got ' + IntToStr(Actual) + ', expected ' + IntToStr(Expected) + ')', False);
end;

procedure CheckNear(const Name: string; Actual, Expected, Tolerance: Double);
begin
  if Abs(Actual - Expected) <= Tolerance then
    Check(Name, True)
  else
    Check(Name + ' (got ' + FloatToStr(Actual) + ', expected ' + FloatToStr(Expected) + ')', False);
end;

end.
