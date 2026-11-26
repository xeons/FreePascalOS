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
  One test's results: the harness status and each subtest's, read from
  the report line tools/WptRun/harness/testharnessreport.js prints
  ("wptrun-result:" and JSON). A run that ends without that line is a
  CRASH (the session exited) or a TIMEOUT (the runner stopped it).
}
unit WptRun.Results;

{$mode objfpc}
{$H+}

interface

const
  ResultMarker = 'wptrun-result:';

type
  { testharness.js's harness statuses, a reftest's FAIL (its screenshots
    did not compare as its links say), then the runner's own. }
  THarnessStatus = (HarnessOk, HarnessError, HarnessTimeout, HarnessPreconditionFailed, HarnessFail, HarnessCrash,
    HarnessExternalTimeout);
  { testharness.js's subtest statuses. }
  TSubtestStatus = (SubtestPass, SubtestFail, SubtestTimeout, SubtestNotRun, SubtestPreconditionFailed);

  TSubtestResult = record
    Name: string;
    Status: TSubtestStatus;
    Message: string;
  end;

  TTestResult = record
    Path: string;
    Harness: THarnessStatus;
    Message: string;
    Subtests: array of TSubtestResult;
    Milliseconds: Double;
    Reftest: Boolean;
  end;
  TTestResultList = array of TTestResult;

function HarnessStatusName(Status: THarnessStatus): string;
function SubtestStatusName(Status: TSubtestStatus): string;
{ Reads the report of test Path from a session's output; False when there
  is none (Outcome then holds only Path). }
function ParseTestOutput(const Path, Output: string; out Outcome: TTestResult): Boolean;
{ Subtests that pass, and all of them; a test without subtests counts as
  one, passing when its harness status is OK. }
procedure CountSubtests(constref Outcome: TTestResult; out Passed, Total: Integer);

implementation

uses
  SysUtils,
  Classes,
  fpjson,
  jsonparser;

function HarnessStatusName(Status: THarnessStatus): string;
const
  Names: array[THarnessStatus] of string = ('OK', 'ERROR', 'TIMEOUT', 'PRECONDITION_FAILED', 'FAIL', 'CRASH',
    'EXTERNAL-TIMEOUT');
begin
  Result := Names[Status];
end;

function SubtestStatusName(Status: TSubtestStatus): string;
const
  Names: array[TSubtestStatus] of string = ('PASS', 'FAIL', 'TIMEOUT', 'NOTRUN', 'PRECONDITION_FAILED');
begin
  Result := Names[Status];
end;

function TextOf(Data: TJSONData): string;
begin
  if (Data = nil) or (Data.JSONType = jtNull) then
    Result := ''
  else
    Result := Data.AsString;
end;

{ The report whose url ends with Path (a page the test opened can carry
  testharness.js too). }
function FindReportLine(const Path, Output: string): string;
var
  Lines: TStringList;
  Index, At: Integer;
  Line, Fallback: string;
begin
  Result := '';
  Fallback := '';
  Lines := TStringList.Create;
  try
    Lines.Text := Output;
    for Index := 0 to Lines.Count - 1 do
    begin
      At := Pos(ResultMarker, Lines[Index]);
      if At = 0 then
        Continue;
      Line := Copy(Lines[Index], At + Length(ResultMarker), MaxInt);
      if Pos(Path + '"', Line) > 0 then
        Exit(Line);
      if Fallback = '' then
        Fallback := Line;
    end;
  finally
    Lines.Free;
  end;
  Result := Fallback;
end;

function ParseTestOutput(const Path, Output: string; out Outcome: TTestResult): Boolean;
var
  Line: string;
  Data: TJSONData;
  Report: TJSONObject;
  Tests: TJSONArray;
  Index, Status: Integer;
begin
  Outcome := Default(TTestResult);
  Outcome.Path := Path;
  Line := FindReportLine(Path, Output);
  if Line = '' then
    Exit(False);
  try
    Data := GetJSON(Line);
  except
    Exit(False);
  end;
  try
    if not (Data is TJSONObject) then
      Exit(False);
    Report := TJSONObject(Data);
    Status := Report.Get('status', 1);
    if (Status < 0) or (Status > Ord(HarnessFail)) then
      Status := Ord(HarnessError);
    Outcome.Harness := THarnessStatus(Status);
    Outcome.Message := TextOf(Report.Find('message'));
    Tests := Report.Get('tests', TJSONArray(nil));
    if Tests <> nil then
    begin
      SetLength(Outcome.Subtests, Tests.Count);
      for Index := 0 to Tests.Count - 1 do
      begin
        if not (Tests[Index] is TJSONObject) then
          Continue;
        Outcome.Subtests[Index].Name := TextOf(TJSONObject(Tests[Index]).Find('name'));
        Status := TJSONObject(Tests[Index]).Get('status', 1);
        if (Status < 0) or (Status > Ord(High(TSubtestStatus))) then
          Status := Ord(SubtestFail);
        Outcome.Subtests[Index].Status := TSubtestStatus(Status);
        Outcome.Subtests[Index].Message := TextOf(TJSONObject(Tests[Index]).Find('message'));
      end;
    end;
  finally
    Data.Free;
  end;
  Exit(True);
end;

procedure CountSubtests(constref Outcome: TTestResult; out Passed, Total: Integer);
var
  Index: Integer;
begin
  Passed := 0;
  Total := Length(Outcome.Subtests);
  if Total = 0 then
  begin
    Total := 1;
    if Outcome.Harness = HarnessOk then
      Passed := 1;
    Exit;
  end;
  for Index := 0 to High(Outcome.Subtests) do
    if Outcome.Subtests[Index].Status = SubtestPass then
      Inc(Passed);
end;

end.
