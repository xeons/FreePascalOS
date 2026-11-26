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
  The results: the totals, the pass rate of each directory (the first
  two levels: built-ins/Array, language/expressions, annexB/built-ins,
  intl402/DateTimeFormat... and each top level), the failures the
  expectations do not list, the listed tests that pass now, and with
  --list every failure with the first line of its error.
}
unit Test262.Reporter;

{$mode objfpc}{$H+}

interface

uses
  SysUtils,
  Classes,
  Test262.Scheduler,
  Test262.Expectations;

type
  TReporter = class
  private
    FPaths: TStringList;
    FStatuses: array of TTestStatus;
    FMessages: array of string;
    FFinished: Integer;
    FToRun: Integer;
    FStarted: QWord;
    procedure PrintGroups(Depth: Integer);
  public
    { Paths: every test's relative path, in index order. }
    constructor Create(Paths: TStringList);
    destructor Destroy; override;
    procedure ExpectRuns(Count: Integer);
    procedure Record_(Index: Integer; const Result: TTestResult);
    { Prints everything; returns the number of unexpected failures. }
    function PrintSummary(Expectations: TExpectations; ListFailures, ShowGroups: Boolean): Integer;
    { The failing tests and their messages, sorted by path. }
    procedure CollectFailures(Paths, Messages: TStrings);
  end;

implementation

const
  ProgressInterval = 2000;

constructor TReporter.Create(Paths: TStringList);
var
  Index: Integer;
begin
  inherited Create;
  FPaths := Paths;
  SetLength(FStatuses, Paths.Count);
  SetLength(FMessages, Paths.Count);
  for Index := 0 to Paths.Count - 1 do
    FStatuses[Index] := tsSkipped;
  FStarted := GetTickCount64;
end;

destructor TReporter.Destroy;
begin
  inherited Destroy;
end;

procedure TReporter.ExpectRuns(Count: Integer);
begin
  FToRun := Count;
end;

procedure TReporter.Record_(Index: Integer; const Result: TTestResult);
begin
  FStatuses[Index] := Result.Status;
  FMessages[Index] := Result.Message;
  Inc(FFinished);
  if FFinished mod ProgressInterval = 0 then
  begin
    WriteLn(StdErr, Format('  %d/%d tests, %d s', [FFinished, FToRun, (GetTickCount64 - FStarted) div 1000]));
    Flush(StdErr);
  end;
end;

function Rate(Passed, Run: Integer): string;
begin
  if Run = 0 then
    Result := '    -'
  else
    Result := Format('%5.1f%%', [100.0 * Passed / Run]);
end;

function TopOf(const RelativePath: string): string;
var
  Slash: Integer;
begin
  Slash := Pos('/', RelativePath);
  if Slash = 0 then
    Result := RelativePath
  else
    Result := Copy(RelativePath, 1, Slash - 1);
end;

procedure TReporter.PrintGroups(Depth: Integer);
var
  Groups: TStringList;
  Index, GroupIndex: Integer;
  Group: string;
  Counts: array of record Passed, Failed, Skipped: Integer; end;
begin
  Groups := TStringList.Create;
  try
    Groups.Sorted := True;
    Counts := nil;
    for Index := 0 to FPaths.Count - 1 do
    begin
      if Depth = 1 then
        Group := TopOf(FPaths[Index])
      else
        Group := GroupOf(FPaths[Index]);
      if not Groups.Find(Group, GroupIndex) then
        Groups.Add(Group);
    end;
    SetLength(Counts, Groups.Count);
    for Index := 0 to FPaths.Count - 1 do
    begin
      if Depth = 1 then
        Group := TopOf(FPaths[Index])
      else
        Group := GroupOf(FPaths[Index]);
      Groups.Find(Group, GroupIndex);
      case FStatuses[Index] of
        tsPassed: Inc(Counts[GroupIndex].Passed);
        tsFailed: Inc(Counts[GroupIndex].Failed);
        tsSkipped: Inc(Counts[GroupIndex].Skipped);
      end;
    end;
    for GroupIndex := 0 to Groups.Count - 1 do
      with Counts[GroupIndex] do
        WriteLn(Format('  %-48s %6d/%-6d %s  (%d skipped)', [Groups[GroupIndex], Passed, Passed + Failed,
          Rate(Passed, Passed + Failed), Skipped]));
  finally
    Groups.Free;
  end;
end;

procedure TReporter.CollectFailures(Paths, Messages: TStrings);
var
  Index: Integer;
begin
  for Index := 0 to FPaths.Count - 1 do
    if FStatuses[Index] = tsFailed then
    begin
      Paths.Add(FPaths[Index]);
      Messages.Add(FMessages[Index]);
    end;
end;

function TReporter.PrintSummary(Expectations: TExpectations; ListFailures, ShowGroups: Boolean): Integer;
var
  Index, Passed, Failed, Skipped, NewlyPassing: Integer;
begin
  Passed := 0;
  Failed := 0;
  Skipped := 0;
  NewlyPassing := 0;
  Result := 0;
  for Index := 0 to FPaths.Count - 1 do
    case FStatuses[Index] of
      tsPassed: Inc(Passed);
      tsFailed: Inc(Failed);
      tsSkipped: Inc(Skipped);
    end;
  if ShowGroups then
  begin
    WriteLn('By directory:');
    PrintGroups(2);
  end;
  WriteLn('By top-level directory:');
  PrintGroups(1);
  if ListFailures then
  begin
    WriteLn('Failing tests:');
    for Index := 0 to FPaths.Count - 1 do
      if FStatuses[Index] = tsFailed then
        WriteLn('  ', FPaths[Index], ': ', FMessages[Index]);
  end;
  for Index := 0 to FPaths.Count - 1 do
    if (FStatuses[Index] = tsFailed) and not Expectations.ExpectsFailure(FPaths[Index]) then
    begin
      if Result = 0 then
        WriteLn('Unexpected failures:');
      Inc(Result);
      WriteLn('  FAIL ', FPaths[Index], ': ', FMessages[Index]);
    end;
  for Index := 0 to FPaths.Count - 1 do
    if (FStatuses[Index] = tsPassed) and Expectations.ExpectsFailure(FPaths[Index]) then
    begin
      if NewlyPassing = 0 then
        WriteLn('Newly passing (remove from the expectations):');
      Inc(NewlyPassing);
      WriteLn('  PASS ', FPaths[Index]);
    end;
  WriteLn(Format('test262: %d passed, %d failed, %d skipped: %s of those run pass; ' +
    '%d unexpected failures, %d newly passing; %d s',
    [Passed, Failed, Skipped, Trim(Rate(Passed, Passed + Failed)), Result, NewlyPassing,
    (GetTickCount64 - FStarted) div 1000]));
end;

end.
