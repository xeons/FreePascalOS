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
  The known failures (tools/WptRun/expectations/AREA.txt, one file per
  top-level WPT directory): each test that does not fully pass, then
  indented, what fails in it:

    /dom/nodes/Node-cloneNode.html
      !harness TIMEOUT
      createElement(audio)

  "!harness STATUS" when the harness itself does not finish OK, and the
  name of each subtest that does not pass (a backslash escapes a leading
  "!" or "\", "\n" a line break). Only passing or not counts: a known
  failure that now times out is still known. Tests without an entry are
  expected to pass.
}
unit WptRun.Expectations;

{$mode objfpc}
{$H+}

interface

uses
  Classes,
  WptRun.Results;

type
  TTestExpectation = class
  public
    HarnessFails: Boolean;
    HarnessStatus: string;
    { Sorted names of the subtests known to fail. }
    FailingSubtests: TStringList;
    constructor Create;
    destructor Destroy; override;
  end;

  TComparison = record
    { "subtest name: STATUS: message" lines. }
    UnexpectedFailures: TStringList;
    NewlyPassing: TStringList;
  end;

  TExpectationSet = class
  private
    FDirectory: string;
    { Test path -> TTestExpectation, sorted. }
    FTests: TStringList;
    procedure LoadFile(const FileName: string);
  public
    constructor Create(const Directory: string);
    destructor Destroy; override;
    procedure Load;
    { nil when the test is expected to pass entirely. }
    function Find(const Path: string): TTestExpectation;
    { The test's entry becomes what it did now. }
    procedure Update(constref Outcome: TTestResult);
    procedure Save;
  end;

{ What differs from the expectation (nil: expected to pass); the caller
  frees both lists. }
function CompareWithExpectation(constref Outcome: TTestResult; Expectation: TTestExpectation): TComparison;

implementation

uses
  SysUtils;

const
  HarnessPrefix = '!harness ';
  FileHeader = '# Known failures for tools/WptRun: a test path, then indented: "!harness STATUS"'#10 +
    '# when the harness does not finish OK, and each subtest that does not pass.'#10 +
    '# Rewritten by "wptrun --update"; tests not listed are expected to pass.'#10;

function EscapeName(const Name: string): string;
begin
  Result := StringReplace(Name, '\', '\\', [rfReplaceAll]);
  Result := StringReplace(Result, #13, '\r', [rfReplaceAll]);
  Result := StringReplace(Result, #10, '\n', [rfReplaceAll]);
  if (Result <> '') and (Result[1] = '!') then
    Result := '\' + Result;
  if (Result <> '') and (Result[Length(Result)] = ' ') then
    Result := Result + '\s';
end;

function UnescapeName(const Text: string): string;
var
  Index: Integer;
begin
  Result := '';
  Index := 1;
  while Index <= Length(Text) do
  begin
    if (Text[Index] = '\') and (Index < Length(Text)) then
    begin
      Inc(Index);
      case Text[Index] of
        'n': Result := Result + #10;
        'r': Result := Result + #13;
        's': ;
      else
        Result := Result + Text[Index];
      end;
    end
    else
      Result := Result + Text[Index];
    Inc(Index);
  end;
end;

{ "dom" for "/dom/nodes/a.html". }
function AreaOf(const Path: string): string;
var
  Rest: string;
begin
  Rest := Copy(Path, 2, MaxInt);
  if Pos('/', Rest) > 0 then
    Result := Copy(Rest, 1, Pos('/', Rest) - 1)
  else
    Result := 'root';
end;

constructor TTestExpectation.Create;
begin
  inherited Create;
  FailingSubtests := TStringList.Create;
  FailingSubtests.Sorted := True;
  FailingSubtests.Duplicates := dupIgnore;
  FailingSubtests.CaseSensitive := True;
end;

destructor TTestExpectation.Destroy;
begin
  FailingSubtests.Free;
  inherited Destroy;
end;

constructor TExpectationSet.Create(const Directory: string);
begin
  inherited Create;
  FDirectory := Directory;
  FTests := TStringList.Create;
  FTests.Sorted := True;
  FTests.Duplicates := dupIgnore;
  FTests.CaseSensitive := True;
  FTests.OwnsObjects := True;
end;

destructor TExpectationSet.Destroy;
begin
  FTests.Free;
  inherited Destroy;
end;

procedure TExpectationSet.LoadFile(const FileName: string);
var
  Lines: TStringList;
  Index, Found: Integer;
  Line: string;
  Current: TTestExpectation;
begin
  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(FileName);
    Current := nil;
    for Index := 0 to Lines.Count - 1 do
    begin
      Line := Lines[Index];
      if (Line = '') or (Line[1] = '#') then
        Continue;
      if Line[1] <> ' ' then
      begin
        if FTests.Find(Line, Found) then
          Current := TTestExpectation(FTests.Objects[Found])
        else
        begin
          Current := TTestExpectation.Create;
          FTests.AddObject(Line, Current);
        end;
        Continue;
      end;
      if Current = nil then
        Continue;
      Line := Copy(Line, 3, MaxInt);
      if Copy(Line, 1, Length(HarnessPrefix)) = HarnessPrefix then
      begin
        Current.HarnessFails := True;
        Current.HarnessStatus := Copy(Line, Length(HarnessPrefix) + 1, MaxInt);
      end
      else
        Current.FailingSubtests.Add(UnescapeName(Line));
    end;
  finally
    Lines.Free;
  end;
end;

procedure TExpectationSet.Load;
var
  Search: TSearchRec;
begin
  if FindFirst(IncludeTrailingPathDelimiter(FDirectory) + '*.txt', faAnyFile, Search) = 0 then
  begin
    repeat
      LoadFile(IncludeTrailingPathDelimiter(FDirectory) + Search.Name);
    until FindNext(Search) <> 0;
    FindClose(Search);
  end;
end;

function TExpectationSet.Find(const Path: string): TTestExpectation;
var
  Found: Integer;
begin
  if FTests.Find(Path, Found) then
    Result := TTestExpectation(FTests.Objects[Found])
  else
    Result := nil;
end;

procedure TExpectationSet.Update(constref Outcome: TTestResult);
var
  Found, Index: Integer;
  Entry: TTestExpectation;
begin
  if FTests.Find(Outcome.Path, Found) then
    FTests.Delete(Found);
  Entry := TTestExpectation.Create;
  Entry.HarnessFails := Outcome.Harness <> HarnessOk;
  Entry.HarnessStatus := HarnessStatusName(Outcome.Harness);
  for Index := 0 to High(Outcome.Subtests) do
    if Outcome.Subtests[Index].Status <> SubtestPass then
      Entry.FailingSubtests.Add(Outcome.Subtests[Index].Name);
  if Entry.HarnessFails or (Entry.FailingSubtests.Count > 0) then
    FTests.AddObject(Outcome.Path, Entry)
  else
    Entry.Free;
end;

procedure TExpectationSet.Save;
var
  Areas: TStringList;
  Index, AreaIndex, Subtest: Integer;
  Area: string;
  Entry: TTestExpectation;
  Text: TStringList;
  Search: TSearchRec;
begin
  ForceDirectories(FDirectory);
  { Areas whose every test now passes lose their file. }
  if FindFirst(IncludeTrailingPathDelimiter(FDirectory) + '*.txt', faAnyFile, Search) = 0 then
  begin
    repeat
      DeleteFile(IncludeTrailingPathDelimiter(FDirectory) + Search.Name);
    until FindNext(Search) <> 0;
    FindClose(Search);
  end;
  Areas := TStringList.Create;
  Areas.Sorted := True;
  Areas.Duplicates := dupIgnore;
  try
    for Index := 0 to FTests.Count - 1 do
      Areas.Add(AreaOf(FTests[Index]));
    for AreaIndex := 0 to Areas.Count - 1 do
    begin
      Area := Areas[AreaIndex];
      Text := TStringList.Create;
      try
        Text.LineBreak := #10;
        Text.Text := FileHeader;
        for Index := 0 to FTests.Count - 1 do
        begin
          if AreaOf(FTests[Index]) <> Area then
            Continue;
          Entry := TTestExpectation(FTests.Objects[Index]);
          Text.Add(FTests[Index]);
          if Entry.HarnessFails then
            Text.Add('  ' + HarnessPrefix + Entry.HarnessStatus);
          for Subtest := 0 to Entry.FailingSubtests.Count - 1 do
            Text.Add('  ' + EscapeName(Entry.FailingSubtests[Subtest]));
        end;
        Text.SaveToFile(IncludeTrailingPathDelimiter(FDirectory) + Area + '.txt');
      finally
        Text.Free;
      end;
    end;
  finally
    Areas.Free;
  end;
end;

function CompareWithExpectation(constref Outcome: TTestResult; Expectation: TTestExpectation): TComparison;
var
  Index: Integer;
  Subtest: TSubtestResult;
  Known: Boolean;
begin
  Result.UnexpectedFailures := TStringList.Create;
  Result.NewlyPassing := TStringList.Create;
  if Outcome.Harness <> HarnessOk then
  begin
    if (Expectation = nil) or not Expectation.HarnessFails then
      Result.UnexpectedFailures.Add('harness: ' + HarnessStatusName(Outcome.Harness) + ': ' + Outcome.Message);
  end
  else if (Expectation <> nil) and Expectation.HarnessFails then
    Result.NewlyPassing.Add('harness: OK');
  for Index := 0 to High(Outcome.Subtests) do
  begin
    Subtest := Outcome.Subtests[Index];
    Known := (Expectation <> nil) and (Expectation.FailingSubtests.IndexOf(Subtest.Name) >= 0);
    if (Subtest.Status <> SubtestPass) and not Known then
      Result.UnexpectedFailures.Add(Subtest.Name + ': ' + SubtestStatusName(Subtest.Status) + ': ' + Subtest.Message)
    else if (Subtest.Status = SubtestPass) and Known then
      Result.NewlyPassing.Add(Subtest.Name);
  end;
end;

end.
