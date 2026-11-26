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
  Tests run in parallel, each in a process of its own (wptrun --child:
  one webbrowse session, WptRun.Child), so a test that crashes or hangs
  the engine costs only itself. The session ends when the harness
  reports; a session that outlives its time (testharness.js's own
  timeout, 10 s or 60 s for timeout=long, and some slack) is killed and
  the test is an EXTERNAL-TIMEOUT. A reftest's child (wptrun --reftest,
  WptRun.ReftestChild) renders the test and its references one after
  another and reports like the harness; it has its time per page.
}
unit WptRun.Jobs;

{$mode objfpc}
{$H+}

interface

uses
  WptRun.Tests,
  WptRun.Results;

type
  TRunSettings = record
    Executable: string;
    Jobs: Integer;
    { The test CA's PEM file (the checkout's tools/certs/cacert.pem). }
    CertificateFile: string;
    FontDirectory: string;
    { Scales every time limit (a slow host). }
    TimeoutMultiplier: Double;
    { The checkout (reftests read their references' links from it). }
    WptRoot: string;
    { Where reftests leave the screenshots of failures (one directory
      per test). }
    ShotDirectory: string;
    { Families installed for the tests (Ahem, as wptrunner installs it). }
    UserFontDirectory: string;
  end;

  TResultEvent = procedure(constref Outcome: TTestResult; const Output: string) of object;

{ The session's own time limit for a test, in seconds. }
function SessionSeconds(constref Test: TWptTest; Multiplier: Double): Double;
{ The test's address on the local server. }
function TestUrl(constref Test: TWptTest): string;
procedure RunTests(const Tests: TWptTestList; constref Settings: TRunSettings; OnResult: TResultEvent);

implementation

uses
  SysUtils,
  Classes,
  Process,
  Linux,
  UnixType,
  WptRun.Server;

const
  TestHost = 'web-platform.test';
  { The runner's wait beyond the session's own limit before it kills. }
  KillSlackSeconds = 15;

type
  TRunningTest = record
    Test: TWptTest;
    Process: TProcess;
    Output: string;
    Started: Double;
  end;

function NowMilliseconds: Double;
var
  Spec: TTimeSpec;
begin
  clock_gettime(CLOCK_MONOTONIC, @Spec);
  Result := Double(Spec.tv_sec) * 1000 + Double(Spec.tv_nsec) / 1000000;
end;

{ The time a reftest's page has to load and settle. }
function ReftestPageSeconds(constref Test: TWptTest; Multiplier: Double): Double;
begin
  if Test.LongTimeout then
    Result := 30 * Multiplier
  else
    Result := 10 * Multiplier;
end;

function SessionSeconds(constref Test: TWptTest; Multiplier: Double): Double;
begin
  if Test.Reftest then
    Result := ReftestPageSeconds(Test, Multiplier) * Test.PageCount
  else if Test.LongTimeout then
    Result := 75 * Multiplier
  else
    Result := 20 * Multiplier;
end;

function TestUrl(constref Test: TWptTest): string;
begin
  if Test.Secure then
    Result := 'https://' + TestHost + ':' + IntToStr(WptHttpsPort) + Test.Path
  else
    Result := 'http://' + TestHost + ':' + IntToStr(WptHttpPort) + Test.Path;
end;

procedure Drain(var Running: TRunningTest);
var
  Buffer: array[0..65535] of Char;
  Count: LongInt;
begin
  while Running.Process.Output.NumBytesAvailable > 0 do
  begin
    Count := Running.Process.Output.Read(Buffer, SizeOf(Buffer));
    if Count <= 0 then
      Break;
    SetLength(Running.Output, Length(Running.Output) + Count);
    Move(Buffer, Running.Output[Length(Running.Output) - Count + 1], Count);
  end;
end;

{ The test's own directory for screenshots ("/css/a.html?x": css_a.html_x). }
function ShotDirectoryOf(constref Test: TWptTest; const Root: string): string;
var
  Name: string;
  Index: Integer;
begin
  Name := Copy(Test.Path, 2, MaxInt);
  for Index := 1 to Length(Name) do
    if not (Name[Index] in ['A'..'Z', 'a'..'z', '0'..'9', '.', '-', '_']) then
      Name[Index] := '_';
  Result := IncludeTrailingPathDelimiter(Root) + Name;
end;

procedure StartTest(var Running: TRunningTest; constref Test: TWptTest; constref Settings: TRunSettings);
begin
  Running.Test := Test;
  Running.Output := '';
  Running.Started := NowMilliseconds;
  Running.Process := TProcess.Create(nil);
  Running.Process.Executable := Settings.Executable;
  if Test.Reftest then
  begin
    Running.Process.Parameters.Add('--reftest');
    Running.Process.Parameters.Add(Test.Path);
    Running.Process.Parameters.Add('--wpt');
    Running.Process.Parameters.Add(Settings.WptRoot);
    Running.Process.Parameters.Add('--base');
    Running.Process.Parameters.Add('http://' + TestHost + ':' + IntToStr(WptHttpPort));
    Running.Process.Parameters.Add('--shots');
    Running.Process.Parameters.Add(ShotDirectoryOf(Test, Settings.ShotDirectory));
    Running.Process.Parameters.Add('--seconds');
    Running.Process.Parameters.Add(FloatToStr(ReftestPageSeconds(Test, Settings.TimeoutMultiplier)));
  end
  else
  begin
    Running.Process.Parameters.Add('--child');
    Running.Process.Parameters.Add(TestUrl(Test));
    Running.Process.Parameters.Add('--seconds');
    Running.Process.Parameters.Add(FloatToStr(SessionSeconds(Test, Settings.TimeoutMultiplier)));
  end;
  Running.Process.Parameters.Add('--trust-ca');
  Running.Process.Parameters.Add(Settings.CertificateFile);
  if Settings.FontDirectory <> '' then
  begin
    Running.Process.Parameters.Add('-f');
    Running.Process.Parameters.Add(Settings.FontDirectory);
  end;
  if Settings.UserFontDirectory <> '' then
  begin
    Running.Process.Parameters.Add('--user-fonts');
    Running.Process.Parameters.Add(Settings.UserFontDirectory);
  end;
  Running.Process.Options := [poUsePipes, poStderrToOutPut];
  Running.Process.Execute;
end;

procedure FinishTest(var Running: TRunningTest; Killed: Boolean; OnResult: TResultEvent);
var
  Outcome: TTestResult;
begin
  Drain(Running);
  if not ParseTestOutput(Running.Test.Path, Running.Output, Outcome) then
  begin
    if Killed or (Pos('webbrowse: timed out', Running.Output) > 0) then
      Outcome.Harness := HarnessExternalTimeout
    else
    begin
      Outcome.Harness := HarnessCrash;
      Outcome.Message := 'exit status ' + IntToStr(Running.Process.ExitStatus);
    end;
  end;
  Outcome.Milliseconds := NowMilliseconds - Running.Started;
  Outcome.Reftest := Running.Test.Reftest;
  OnResult(Outcome, Running.Output);
  FreeAndNil(Running.Process);
end;

procedure RunTests(const Tests: TWptTestList; constref Settings: TRunSettings; OnResult: TResultEvent);
var
  Running: array of TRunningTest;
  Next, Slot, Active: Integer;
  Busy: Boolean;
begin
  SetLength(Running, Settings.Jobs);
  for Slot := 0 to High(Running) do
    Running[Slot].Process := nil;
  Next := 0;
  repeat
    Active := 0;
    Busy := False;
    for Slot := 0 to High(Running) do
    begin
      if (Running[Slot].Process = nil) and (Next < Length(Tests)) then
      begin
        StartTest(Running[Slot], Tests[Next], Settings);
        Inc(Next);
      end;
      if Running[Slot].Process = nil then
        Continue;
      Inc(Active);
      if Running[Slot].Process.Output.NumBytesAvailable > 0 then
      begin
        Drain(Running[Slot]);
        Busy := True;
      end;
      if not Running[Slot].Process.Running then
      begin
        FinishTest(Running[Slot], False, OnResult);
        Busy := True;
      end
      else if NowMilliseconds - Running[Slot].Started >
        (SessionSeconds(Running[Slot].Test, Settings.TimeoutMultiplier) + KillSlackSeconds) * 1000 then
      begin
        Running[Slot].Process.Terminate(9);
        Running[Slot].Process.WaitOnExit;
        FinishTest(Running[Slot], True, OnResult);
        Busy := True;
      end;
    end;
    if not Busy then
      Sleep(5);
  until (Active = 0) and (Next >= Length(Tests));
end;

end.
