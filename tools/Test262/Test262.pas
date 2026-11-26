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
  Runs test262, the ECMAScript conformance suite, against libjavascript
  on the host.

  Test262 [options] [TEST262] [FILTER...]

  TEST262 is a checkout of test262 (default ~/Downloads/sources/test262);
  each FILTER keeps the tests whose path under test/ starts with it
  ("built-ins/Array", "language/expressions/class"). Options:
    --jobs N        tests at once (default: half the host's processors;
                    never more than fit in half the available memory)
    --timeout S     seconds a test may take (default 10)
    --memory MB     address space each test may take (default 512)
    --list          every failing test with the first line of its error
    --groups        the pass rate of every second-level directory too
    --expectations FILE   the known failures (default
                    tools/Test262/expectations.txt)
    --skip-features FILE  the features not run (default
                    tools/Test262/skipped-features.txt)
    --write-expectations FILE  writes the failures as a new
                    expectations file
  Exits with 1 when a test fails that the expectations do not list.
}
program Test262;

{$mode objfpc}{$H+}

uses
  SysUtils,
  Classes,
  Test262.Frontmatter,
  Test262.Host,
  Test262.Harness,
  Test262.Execution,
  Test262.Scheduler,
  Test262.Expectations,
  Test262.Skips,
  Test262.Reporter;

type
  TRunner = class
  public
    TestRoot: string;
    Paths: TStringList;
    Metadata: array of TTestMetadata;
    Reporter: TReporter;
    constructor Create;
    destructor Destroy; override;
    procedure Discover(const Directory, Relative: string; const Filters: TStringArray);
    function LoadTest(Index: Integer; out Test: TTestCase): Boolean;
    procedure ResultArrived(Index: Integer; const Result: TTestResult);
  end;

constructor TRunner.Create;
begin
  inherited Create;
  Paths := TStringList.Create;
end;

destructor TRunner.Destroy;
begin
  Paths.Free;
  inherited Destroy;
end;

function MatchesFilters(const RelativePath: string; const Filters: TStringArray): Boolean;
var
  Index: Integer;
begin
  if Length(Filters) = 0 then
    Exit(True);
  for Index := 0 to High(Filters) do
    if (Pos(Filters[Index], RelativePath) = 1) or (Pos(RelativePath + '/', Filters[Index] + '/') = 1) then
      Exit(True);
  Result := False;
end;

{ Every test file under Directory (not the _FIXTURE files modules
  import), as paths relative to test/. }
procedure TRunner.Discover(const Directory, Relative: string; const Filters: TStringArray);
var
  Search: TSearchRec;
  Name, Path: string;
begin
  if FindFirst(Directory + '*', faAnyFile, Search) <> 0 then
    Exit;
  repeat
    Name := Search.Name;
    if (Name = '.') or (Name = '..') then
      Continue;
    Path := Relative + Name;
    if (Search.Attr and faDirectory) <> 0 then
    begin
      if MatchesFilters(Path, Filters) then
        Discover(Directory + Name + '/', Path + '/', Filters);
    end
    else if (ExtractFileExt(Name) = '.js') and (Pos('_FIXTURE', Name) = 0) and MatchesFilters(Path, Filters) then
      Paths.Add(Path);
  until FindNext(Search) <> 0;
  FindClose(Search);
end;

function TRunner.LoadTest(Index: Integer; out Test: TTestCase): Boolean;
begin
  Test := Default(TTestCase);
  Test.RelativePath := Paths[Index];
  Test.FullPath := TestRoot + Paths[Index];
  Test.Metadata := Metadata[Index];
  Test.Source := ReadFileText(Test.FullPath);
  Result := True;
end;

procedure TRunner.ResultArrived(Index: Integer; const Result: TTestResult);
begin
  Reporter.Record_(Index, Result);
end;

procedure Usage;
begin
  WriteLn('usage: Test262 [--jobs N] [--timeout S] [--memory MB] [--list] [--groups] [--expectations FILE]');
  WriteLn('               [--skip-features FILE] [--write-expectations FILE] [TEST262] [FILTER...]');
  Halt(2);
end;

var
  Runner: TRunner;
  Harness: THarnessLibrary;
  Scheduler: TTestScheduler;
  Expectations: TExpectations;
  Skips: TSkipList;
  Filters: TStringArray;
  ToRun: array of Integer;
  Test262Directory, ExpectationsPath, SkipPath, WritePath, Argument, Source, Reason: string;
  Jobs, TimeLimit, MemoryMegabytes, ArgumentIndex, Index, Unexpected, Skipped: Integer;
  ListFailures, ShowGroups: Boolean;
  FailingPaths, FailingMessages: TStringList;

begin
  Test262Directory := GetEnvironmentVariable('HOME') + '/Downloads/sources/test262';
  ExpectationsPath := 'tools/Test262/expectations.txt';
  SkipPath := 'tools/Test262/skipped-features.txt';
  WritePath := '';
  Jobs := HostProcessorCount div 2;
  TimeLimit := 10;
  MemoryMegabytes := 512;
  ListFailures := False;
  ShowGroups := False;
  Filters := nil;
  ArgumentIndex := 1;
  while ArgumentIndex <= ParamCount do
  begin
    Argument := ParamStr(ArgumentIndex);
    Inc(ArgumentIndex);
    if (Argument = '--jobs') or (Argument = '--timeout') or (Argument = '--memory') or (Argument = '--expectations') or
      (Argument = '--skip-features') or (Argument = '--write-expectations') then
    begin
      if ArgumentIndex > ParamCount then
        Usage;
      if Argument = '--jobs' then
        Jobs := StrToIntDef(ParamStr(ArgumentIndex), Jobs)
      else if Argument = '--timeout' then
        TimeLimit := StrToIntDef(ParamStr(ArgumentIndex), TimeLimit)
      else if Argument = '--memory' then
        MemoryMegabytes := StrToIntDef(ParamStr(ArgumentIndex), MemoryMegabytes)
      else if Argument = '--expectations' then
        ExpectationsPath := ParamStr(ArgumentIndex)
      else if Argument = '--skip-features' then
        SkipPath := ParamStr(ArgumentIndex)
      else
        WritePath := ParamStr(ArgumentIndex);
      Inc(ArgumentIndex);
    end
    else if Argument = '--list' then
      ListFailures := True
    else if Argument = '--groups' then
      ShowGroups := True
    else if Copy(Argument, 1, 2) = '--' then
      Usage
    else if (Length(Filters) = 0) and DirectoryExists(Argument + '/harness') then
      Test262Directory := Argument
    else
    begin
      SetLength(Filters, Length(Filters) + 1);
      Filters[High(Filters)] := ExcludeTrailingPathDelimiter(StringReplace(Argument, 'test/', '', []));
    end;
  end;
  Test262Directory := IncludeTrailingPathDelimiter(Test262Directory);
  Jobs := SafeJobCount(Jobs, Int64(MemoryMegabytes) * 1024 * 1024);
  if not DirectoryExists(Test262Directory + 'test') then
  begin
    WriteLn('Test262: no test262 checkout at ', Test262Directory);
    Halt(2);
  end;

  Runner := TRunner.Create;
  Harness := THarnessLibrary.Create(Test262Directory + 'harness');
  Expectations := TExpectations.Create;
  Skips := TSkipList.Create;
  try
    Expectations.Load(ExpectationsPath);
    Skips.Load(SkipPath);
    Runner.TestRoot := Test262Directory + 'test/';
    Runner.Discover(Runner.TestRoot, '', Filters);
    Runner.Paths.Sort;
    Runner.Reporter := TReporter.Create(Runner.Paths);
    SetLength(Runner.Metadata, Runner.Paths.Count);
    ToRun := nil;
    Skipped := 0;
    for Index := 0 to Runner.Paths.Count - 1 do
    begin
      Source := ReadFileText(Runner.TestRoot + Runner.Paths[Index]);
      if not ParseFrontmatter(Source, Runner.Metadata[Index]) then
        Reason := 'no frontmatter'
      else
        Reason := Skips.ReasonToSkip(Runner.Metadata[Index], Source);
      if Reason <> '' then
        Inc(Skipped)
      else
      begin
        SetLength(ToRun, Length(ToRun) + 1);
        ToRun[High(ToRun)] := Index;
      end;
    end;
    WriteLn(Format('test262 at %s: %d tests, %d skipped, %d jobs, %d s and %d MB per test',
      [Test262Directory, Runner.Paths.Count, Skipped, Jobs, TimeLimit, MemoryMegabytes]));
    Flush(Output);
    Runner.Reporter.ExpectRuns(Length(ToRun));
    Scheduler := TTestScheduler.Create(Harness, @Runner.LoadTest, Jobs, TimeLimit, Int64(MemoryMegabytes) * 1024 * 1024);
    try
      Scheduler.Run(ToRun, @Runner.ResultArrived);
    finally
      Scheduler.Free;
    end;
    Unexpected := Runner.Reporter.PrintSummary(Expectations, ListFailures, ShowGroups);
    if WritePath <> '' then
    begin
      FailingPaths := TStringList.Create;
      FailingMessages := TStringList.Create;
      try
        Runner.Reporter.CollectFailures(FailingPaths, FailingMessages);
        WriteExpectations(WritePath, FailingPaths, FailingMessages);
        WriteLn('Wrote ', FailingPaths.Count, ' failures to ', WritePath);
      finally
        FailingMessages.Free;
        FailingPaths.Free;
      end;
    end;
  finally
    Runner.Reporter.Free;
    Skips.Free;
    Expectations.Free;
    Harness.Free;
    Runner.Free;
  end;
  if Unexpected > 0 then
    Halt(1);
end.
