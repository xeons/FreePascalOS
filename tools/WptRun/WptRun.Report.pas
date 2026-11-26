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
  The pass rates of a run per directory: subtests passed of all (a test
  without subtests counts as one), tests passing entirely, and how the
  results compare with the expectations (unexpected failures, newly
  passing). A directory is a test's path cut to its group's depth (the
  depth of the path asked for, or --depth).
}
unit WptRun.Report;

{$mode objfpc}
{$H+}

interface

uses
  Classes,
  WptRun.Results;

type
  TDirectoryTally = class
  public
    Tests, PassingTests: Integer;
    Subtests, PassingSubtests: Integer;
    Unexpected, NewlyPassing: Integer;
    Milliseconds: Double;
  end;

  TRunReport = class
  private
    { Directory -> TDirectoryTally, sorted. }
    FDirectories: TStringList;
    FTotal: TDirectoryTally;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Add(const Directory: string; constref Outcome: TTestResult; Unexpected, NewlyPassing: Integer);
    procedure Write(var Output: Text; Seconds: Double);
  end;

{ Path cut to Depth directories ("/dom/nodes/a.html", 1: "/dom"). }
function DirectoryAtDepth(const Path: string; Depth: Integer): string;
{ How many directories Path names ("dom/nodes/": 2, "dom/a.html": 1). }
function PathDepth(const Path: string): Integer;

implementation

uses
  SysUtils;

function DirectoryAtDepth(const Path: string; Depth: Integer): string;
var
  Index, Seen: Integer;
begin
  Seen := 0;
  for Index := 2 to Length(Path) do
    if Path[Index] = '/' then
    begin
      Inc(Seen);
      if Seen = Depth then
        Exit(Copy(Path, 1, Index - 1));
    end;
  { Fewer directories than asked: its own directory. }
  Result := Copy(Path, 1, LastDelimiter('/', Path) - 1);
  if Result = '' then
    Result := '/';
end;

function PathDepth(const Path: string): Integer;
var
  Trimmed: string;
  Index: Integer;
begin
  Trimmed := Path;
  while (Trimmed <> '') and (Trimmed[1] = '/') do
    Delete(Trimmed, 1, 1);
  if Pos('?', Trimmed) > 0 then
    Trimmed := Copy(Trimmed, 1, Pos('?', Trimmed) - 1);
  Result := 0;
  for Index := 1 to Length(Trimmed) do
    if Trimmed[Index] = '/' then
      Inc(Result);
  { "dom/nodes" (a directory without its slash) is two deep too. }
  if (Trimmed <> '') and (Trimmed[Length(Trimmed)] <> '/') and (Pos('.', ExtractFileName(Trimmed)) = 0) then
    Inc(Result);
  if Result < 1 then
    Result := 1;
end;

constructor TRunReport.Create;
begin
  inherited Create;
  FDirectories := TStringList.Create;
  FDirectories.Sorted := True;
  FDirectories.OwnsObjects := True;
  FTotal := TDirectoryTally.Create;
end;

destructor TRunReport.Destroy;
begin
  FDirectories.Free;
  FTotal.Free;
  inherited Destroy;
end;

procedure TRunReport.Add(const Directory: string; constref Outcome: TTestResult; Unexpected, NewlyPassing: Integer);
var
  Found: Integer;
  Tally: TDirectoryTally;
  Passed, Total: Integer;

  procedure Count(Into: TDirectoryTally);
  begin
    Inc(Into.Tests);
    if (Passed = Total) and (Outcome.Harness = HarnessOk) then
      Inc(Into.PassingTests);
    Inc(Into.Subtests, Total);
    Inc(Into.PassingSubtests, Passed);
    Inc(Into.Unexpected, Unexpected);
    Inc(Into.NewlyPassing, NewlyPassing);
    Into.Milliseconds := Into.Milliseconds + Outcome.Milliseconds;
  end;

begin
  if not FDirectories.Find(Directory, Found) then
  begin
    Tally := TDirectoryTally.Create;
    FDirectories.AddObject(Directory, Tally);
  end
  else
    Tally := TDirectoryTally(FDirectories.Objects[Found]);
  CountSubtests(Outcome, Passed, Total);
  Count(Tally);
  Count(FTotal);
end;

procedure TRunReport.Write(var Output: Text; Seconds: Double);

  function Percent(Part, Whole: Integer): string;
  begin
    if Whole = 0 then
      Result := '-'
    else
      Result := Format('%.1f%%', [100.0 * Part / Whole]);
  end;

  procedure Line(const Name: string; Tally: TDirectoryTally);
  begin
    WriteLn(Output, Format('%-44s %6d/%-6d %8d/%-8d %7s %6d %6d', [Name, Tally.PassingTests, Tally.Tests,
      Tally.PassingSubtests, Tally.Subtests, Percent(Tally.PassingSubtests, Tally.Subtests), Tally.Unexpected,
      Tally.NewlyPassing]));
  end;

var
  Index: Integer;
begin
  WriteLn(Output, Format('%-44s %13s %17s %7s %6s %6s', ['directory', 'tests passing', 'subtests passing', 'rate',
    'unexp', 'new']));
  for Index := 0 to FDirectories.Count - 1 do
    Line(FDirectories[Index], TDirectoryTally(FDirectories.Objects[Index]));
  Line('total', FTotal);
  WriteLn(Output, Format('%d tests in %.0f s', [FTotal.Tests, Seconds]));
end;

end.
