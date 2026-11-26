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
  wptrun: web-platform-tests on the Linux host with the browser engine
  (make wpt; not part of make test). It starts WPT's own server from a
  checkout (WptRun.Server), finds the testharness tests under the paths
  given (WptRun.Tests), runs each in a webbrowse session of its own,
  several at once (WptRun.Jobs, WptRun.Child), with the real
  testharness.js and our testharnessreport.js, and reports pass rates
  per directory, the failures the expectations do not know and the
  known failures that now pass (WptRun.Expectations).

    wptrun [options] PATH...     PATH: a directory or test of the
                                 checkout (dom/nodes, url/a.any.js,
                                 url/a.any.worker.html), or @FILE with
                                 one per line

    -j N           sessions at once (half the processors)
    --wpt DIR      the checkout ($WPT_ROOT, else ~/Downloads/sources/wpt)
    --list         every failing subtest with its message
    --update       the expectations become this run's results (for the
                   tests run)
    --expectations DIR   (tools/WptRun/expectations)
    --depth N      report directories this deep (the depth of each PATH)
    --multiplier X scale the time limits (1)
    -v             each test as it finishes
    --dry-run      print the tests the paths hold; run none
    -f FONTDIR     font directory (userland/fonts)

  Exit status: 0 when nothing failed unexpectedly, 1 otherwise, 2 when
  the run could not start.
}
program WptRun;

{$mode objfpc}
{$H+}

uses
  cthreads,
  SysUtils,
  Classes,
  Linux,
  UnixType,
  WptRun.Tests,
  WptRun.Results,
  WptRun.Expectations,
  WptRun.Jobs,
  WptRun.Server,
  WptRun.Report,
  WptRun.Child,
  WptRun.Limits;

type
  TWptRunner = class
  private
    FPaths: TStringList;
    FTests: TWptTestList;
    FExpectations: TExpectationSet;
    FReport: TRunReport;
    FDetails: TStringList;
    { --list: one text per failing test (its line, then its subtests'). }
    FFailing: TStringList;
    FDone: Integer;
    FUnexpectedTotal, FNewlyPassingTotal: Integer;
    function GroupOf(const Path: string): string;
    procedure TestFinished(constref Outcome: TTestResult; const Output: string);
  public
    WptRoot: string;
    ExpectationDirectory: string;
    Jobs: Integer;
    Depth: Integer;
    List, Update, Verbose, DryRun: Boolean;
    Multiplier: Double;
    FontDirectory: string;
    constructor Create;
    destructor Destroy; override;
    procedure AddPath(const Path: string);
    function Run: Integer;
  end;

function NowSeconds: Double;
var
  Spec: TTimeSpec;
begin
  clock_gettime(CLOCK_MONOTONIC, @Spec);
  Result := Double(Spec.tv_sec) + Double(Spec.tv_nsec) / 1E9;
end;

const
  { sysconf's name for the processors online (Linux, glibc and musl). }
  SysconfProcessorsOnline = 84;

function sysconf(Name: cint): clong; cdecl; external 'c' name 'sysconf';

{ The processors the host has online (sysconf: FPC's TThread.ProcessorCount
  answers 1 on Linux, and /proc/cpuinfo read through a file stream stops
  early because /proc files report no size). }
function OnlineProcessorCount: Integer;
begin
  Result := sysconf(SysconfProcessorsOnline);
  if Result < 1 then
    Result := 1;
end;

constructor TWptRunner.Create;
begin
  inherited Create;
  FPaths := TStringList.Create;
  FDetails := TStringList.Create;
  FFailing := TStringList.Create;
  FReport := TRunReport.Create;
  WptRoot := GetEnvironmentVariable('WPT_ROOT');
  if WptRoot = '' then
    WptRoot := IncludeTrailingPathDelimiter(GetEnvironmentVariable('HOME')) + 'Downloads/sources/wpt';
  ExpectationDirectory := 'tools/WptRun/expectations';
  Jobs := OnlineProcessorCount div 2;
  if Jobs < 1 then
    Jobs := 1;
  Multiplier := 1;
  FontDirectory := 'userland/fonts';
end;

destructor TWptRunner.Destroy;
begin
  FExpectations.Free;
  FReport.Free;
  FDetails.Free;
  FFailing.Free;
  FPaths.Free;
  inherited Destroy;
end;

procedure TWptRunner.AddPath(const Path: string);
var
  Lines: TStringList;
  Index: Integer;
begin
  if Copy(Path, 1, 1) <> '@' then
  begin
    FPaths.Add(Path);
    Exit;
  end;
  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(Copy(Path, 2, MaxInt));
    for Index := 0 to Lines.Count - 1 do
      if (Trim(Lines[Index]) <> '') and (Trim(Lines[Index])[1] <> '#') then
        FPaths.Add(Trim(Lines[Index]));
  finally
    Lines.Free;
  end;
end;

{ The directory a test is reported under: its path cut to the depth of
  the longest PATH it came from (or --depth). }
function TWptRunner.GroupOf(const Path: string): string;
var
  Index, Best, BestLength: Integer;
  Prefix: string;
begin
  if Depth > 0 then
    Exit(DirectoryAtDepth(Path, Depth));
  Best := -1;
  BestLength := -1;
  for Index := 0 to FPaths.Count - 1 do
  begin
    Prefix := '/' + FPaths[Index];
    while Copy(Prefix, 1, 2) = '//' do
      Delete(Prefix, 1, 1);
    if (Copy(Path, 1, Length(Prefix)) = Prefix) and (Length(Prefix) > BestLength) then
    begin
      Best := Index;
      BestLength := Length(Prefix);
    end;
  end;
  if Best < 0 then
    Result := DirectoryAtDepth(Path, 1)
  else
    Result := DirectoryAtDepth(Path, PathDepth(FPaths[Best]));
end;

function OneLine(const Text: string): string;
begin
  Result := StringReplace(StringReplace(Text, #13, ' ', [rfReplaceAll]), #10, ' ', [rfReplaceAll]);
end;

procedure TWptRunner.TestFinished(constref Outcome: TTestResult; const Output: string);
var
  Block: string;
  Comparison: TComparison;
  Index: Integer;
  Passed, Total: Integer;
begin
  Inc(FDone);
  Comparison := CompareWithExpectation(Outcome, FExpectations.Find(Outcome.Path));
  try
    FReport.Add(GroupOf(Outcome.Path), Outcome, Comparison.UnexpectedFailures.Count, Comparison.NewlyPassing.Count);
    Inc(FUnexpectedTotal, Comparison.UnexpectedFailures.Count);
    Inc(FNewlyPassingTotal, Comparison.NewlyPassing.Count);
    CountSubtests(Outcome, Passed, Total);
    if Verbose then
      WriteLn(StdErr, Format('[%d/%d] %s %s %d/%d (%.1f s)', [FDone, Length(FTests), Outcome.Path,
        HarnessStatusName(Outcome.Harness), Passed, Total, Outcome.Milliseconds / 1000]))
    else if FDone mod 100 = 0 then
      WriteLn(StdErr, Format('wptrun: %d of %d tests', [FDone, Length(FTests)]));
    for Index := 0 to Comparison.UnexpectedFailures.Count - 1 do
      FDetails.Add('UNEXPECTED ' + Outcome.Path + ' | ' + OneLine(Comparison.UnexpectedFailures[Index]));
    for Index := 0 to Comparison.NewlyPassing.Count - 1 do
      FDetails.Add('NOW PASSES ' + Outcome.Path + ' | ' + OneLine(Comparison.NewlyPassing[Index]));
    if List and ((Outcome.Harness <> HarnessOk) or (Passed < Total)) then
    begin
      Block := 'FAILING ' + Outcome.Path + ' (harness ' + HarnessStatusName(Outcome.Harness) + ': ' +
        OneLine(Outcome.Message) + ')';
      for Index := 0 to High(Outcome.Subtests) do
        if Outcome.Subtests[Index].Status <> SubtestPass then
          Block := Block + LineEnding + '  ' + SubtestStatusName(Outcome.Subtests[Index].Status) + ' ' +
            OneLine(Outcome.Subtests[Index].Name) + ': ' + OneLine(Outcome.Subtests[Index].Message);
      FFailing.Add(Block);
    end;
  finally
    Comparison.UnexpectedFailures.Free;
    Comparison.NewlyPassing.Free;
  end;
  if Update then
    FExpectations.Update(Outcome);
end;

function TWptRunner.Run: Integer;
var
  Settings: TRunSettings;
  Started: Double;
  Index: Integer;
  Paths: array of string;
begin
  if not FileExists(IncludeTrailingPathDelimiter(WptRoot) + 'wpt') then
  begin
    WriteLn(StdErr, 'wptrun: no WPT checkout at ', WptRoot, ' (git clone --depth 1 ',
      'https://github.com/web-platform-tests/wpt there, or --wpt DIR)');
    Exit(2);
  end;
  SetLength(Paths, FPaths.Count);
  for Index := 0 to FPaths.Count - 1 do
    Paths[Index] := FPaths[Index];
  FTests := CollectTests(WptRoot, Paths);
  if FTests = nil then
  begin
    WriteLn(StdErr, 'wptrun: no tests');
    Exit(2);
  end;
  if DryRun then
  begin
    for Index := 0 to High(FTests) do
      WriteLn(TestUrl(FTests[Index]), BoolToStr(FTests[Index].LongTimeout, ' (long)', ''));
    WriteLn(Length(FTests), ' tests');
    Exit(0);
  end;
  FExpectations := TExpectationSet.Create(ExpectationDirectory);
  FExpectations.Load;
  StopServerOnSignals;
  if not StartWptServer(WptRoot, 'tools/WptRun/server/config.json', 'tools/WptRun/harness', 'build/wpt') then
    Exit(2);
  try
    Jobs := JobsThatFitInMemory(Jobs);
    WriteLn(StdErr, Format('wptrun: %d tests, %d at once', [Length(FTests), Jobs]));
    Settings := Default(TRunSettings);
    Settings.Executable := ExpandFileName(ParamStr(0));
    Settings.Jobs := Jobs;
    Settings.CertificateFile := IncludeTrailingPathDelimiter(WptRoot) + 'tools/certs/cacert.pem';
    Settings.FontDirectory := FontDirectory;
    Settings.TimeoutMultiplier := Multiplier;
    Started := NowSeconds;
    RunTests(FTests, Settings, @TestFinished);
  finally
    StopWptServer;
  end;
  FFailing.Sort;
  for Index := 0 to FFailing.Count - 1 do
    WriteLn(FFailing[Index]);
  FDetails.Sort;
  for Index := 0 to FDetails.Count - 1 do
    WriteLn(FDetails[Index]);
  FReport.Write(Output, NowSeconds - Started);
  WriteLn(Format('%d unexpected failures, %d newly passing', [FUnexpectedTotal, FNewlyPassingTotal]));
  if Update then
  begin
    FExpectations.Save;
    WriteLn('expectations updated in ', ExpectationDirectory);
    Exit(0);
  end;
  if FUnexpectedTotal > 0 then
    Result := 1
  else
    Result := 0;
end;

procedure Usage;
begin
  WriteLn(StdErr, 'usage: wptrun [-j N] [--wpt DIR] [--list] [--update] [--expectations DIR] [--depth N]');
  WriteLn(StdErr, '         [--multiplier X] [-v] [--dry-run] [-f FONTDIR] PATH|@FILE...');
  Halt(2);
end;

var
  Runner: TWptRunner;
  Index: Integer;
  Argument: string;

function NextArgument: string;
begin
  if Index >= ParamCount then
    Usage;
  Inc(Index);
  Result := ParamStr(Index);
end;

begin
  if (ParamCount >= 1) and (ParamStr(1) = '--child') then
  begin
    LimitChildResources;
    Halt(RunChild);
  end;
  Runner := TWptRunner.Create;
  try
    Index := 1;
    while Index <= ParamCount do
    begin
      Argument := ParamStr(Index);
      if Argument = '-j' then
        Runner.Jobs := StrToIntDef(NextArgument, Runner.Jobs)
      else if Argument = '--wpt' then
        Runner.WptRoot := NextArgument
      else if Argument = '--list' then
        Runner.List := True
      else if Argument = '--update' then
        Runner.Update := True
      else if Argument = '--expectations' then
        Runner.ExpectationDirectory := NextArgument
      else if Argument = '--depth' then
        Runner.Depth := StrToIntDef(NextArgument, 0)
      else if Argument = '--multiplier' then
        Runner.Multiplier := StrToFloatDef(NextArgument, 1)
      else if Argument = '--dry-run' then
        Runner.DryRun := True
      else if Argument = '-v' then
        Runner.Verbose := True
      else if Argument = '-f' then
        Runner.FontDirectory := NextArgument
      else if (Argument <> '') and (Argument[1] = '-') then
        Usage
      else
        Runner.AddPath(Argument);
      Inc(Index);
    end;
    if Runner.FPaths.Count = 0 then
      Usage;
    if Runner.Jobs < 1 then
      Runner.Jobs := 1;
    Halt(Runner.Run);
  finally
    Runner.Free;
  end;
end.
