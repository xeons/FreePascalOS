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
  Counting the icon test's checks and printing failures.
}
unit IconTest.Checks;

{$mode objfpc}
{$H+}

interface

procedure Check(Condition: Boolean; const Name: string);
{ Checks Actual = Expected, printing both when not. }
procedure CheckEqual(Actual, Expected: Int64; const Name: string);
{ Prints the totals ("TITLE PASSED: N passed, 0 failed" or FAILED); the
  exit code is 1 if anything failed. }
procedure FinishChecks(const Title: string);

implementation

uses
  SysUtils;

var
  PassedChecks: LongInt = 0;
  FailedChecks: LongInt = 0;

procedure Check(Condition: Boolean; const Name: string);
begin
  if Condition then
  begin
    Inc(PassedChecks);
    WriteLn('ok   ', Name);
  end
  else
  begin
    Inc(FailedChecks);
    WriteLn('FAIL ', Name);
  end;
end;

procedure CheckEqual(Actual, Expected: Int64; const Name: string);
begin
  Check(Actual = Expected, Name);
  if Actual <> Expected then
    WriteLn('     expected ', Expected, ', got ', Actual);
end;

procedure FinishChecks(const Title: string);
begin
  if FailedChecks = 0 then
    WriteLn(Title, ' PASSED: ', PassedChecks, ' passed, ', FailedChecks, ' failed')
  else
  begin
    WriteLn(Title, ' FAILED: ', PassedChecks, ' passed, ', FailedChecks, ' failed');
    Halt(1);
  end;
end;

end.
