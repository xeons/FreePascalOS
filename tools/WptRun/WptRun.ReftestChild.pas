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
  One reftest in its own process (wptrun --reftest PATH --wpt ROOT
  --base URL --seconds S --shots DIR --trust-ca FILE [-f FONTDIR]
  [--user-fonts DIR]): the
  test and its references, each rendered by a webbrowse session of its
  own (WebBrowse.Session: loaded, quiet, reftest-wait honoured) in the
  test's viewport (800x600 unless <meta name=viewport-size>) and saved
  as a PNG in DIR, then compared as wptrunner does
  (tools/wptrunner/wptrunner/executors/base.py, RefTestImplementation):
  a depth-first walk of the references; a pair passes when its
  screenshots are equal (within the left page's fuzzy allowance for that
  reference) for a match, unequal for a mismatch; a reference with
  references of its own continues the chain, one without ends it with a
  pass; when every path fails the test fails. The outcome is printed as
  the harness report (WptRun.Results.ResultMarker): status OK, FAIL,
  ERROR (a page that failed to load) or TIMEOUT, no subtests. The PNGs
  of a failed test stay in DIR; a passing test's are removed.
}
unit WptRun.ReftestChild;

{$mode objfpc}
{$H+}

interface

function RunReftestChild: Integer;

implementation

uses
  SysUtils,
  Classes,
  fpjson,
  Image.Model,
  Image.Files,
  WebBrowse.HostNetwork,
  WebBrowse.Session,
  WptRun.Results,
  WptRun.Reftests,
  WptRun.PixelDifference;

const
  TestDomain = 'web-platform.test';
  AlternateTestDomain = 'not-web-platform.test';
  LoopbackAddress = '127.0.0.1';
  { How long a page must be quiet before its screenshot. }
  QuietMilliseconds = 150;
  { Comparisons before a graph is given up on (cycles). }
  MostComparisons = 64;

type
  TScreenshot = class
  public
    Image: TImage;
    FileName: string;
    { A load that failed: the harness status and why. }
    Failure: THarnessStatus;
    Reason: string;
    destructor Destroy; override;
  end;

  TReftestRun = class
  private
    FShots: TStringList;
    FShotCount: Integer;
    function Screenshot(const Path: string): TScreenshot;
  public
    TestPath, Root, BaseUrl, ShotDirectory, FontDirectory, UserFontDirectory: string;
    PageSeconds: Double;
    Width, Height: Integer;
    constructor Create;
    destructor Destroy; override;
    procedure Run(out Status: THarnessStatus; out Message: string);
    procedure RemoveShots;
  end;

  TPendingComparison = record
    Left: TReftestPage;
    Right: TReftestLink;
  end;

destructor TScreenshot.Destroy;
begin
  Image.Free;
  inherited Destroy;
end;

constructor TReftestRun.Create;
begin
  inherited Create;
  FShots := TStringList.Create;
  FShots.OwnsObjects := True;
  FShots.Sorted := True;
end;

destructor TReftestRun.Destroy;
begin
  FShots.Free;
  inherited Destroy;
end;

function TReftestRun.Screenshot(const Path: string): TScreenshot;
var
  Options: TBrowseOptions;
  Status, Index: Integer;
begin
  Index := FShots.IndexOf(Path);
  if Index >= 0 then
    Exit(TScreenshot(FShots.Objects[Index]));
  Result := TScreenshot.Create;
  FShots.AddObject(Path, Result);
  Inc(FShotCount);
  Result.FileName := IncludeTrailingPathDelimiter(ShotDirectory) + IntToStr(FShotCount) + '-' +
    StringReplace(StringReplace(ExtractFileName(Copy(Path, 1, Pos('?', Path + '?') - 1)), '.', '_', [rfReplaceAll]),
    '#', '_', [rfReplaceAll]) + '.png';
  Options := DefaultBrowseOptions;
  if Pos('://', Path) > 0 then
    Options.Url := Path
  else
    Options.Url := BaseUrl + Path;
  Options.Width := Width;
  Options.Height := Height;
  Options.Scale := 1;
  Options.PngFile := Result.FileName;
  Options.ReftestWait := True;
  Options.QuietMilliseconds := QuietMilliseconds;
  Options.TimeoutSeconds := PageSeconds;
  Options.StallSeconds := 60;
  Options.FontDirectory := FontDirectory;
  Options.UserFontDirectory := UserFontDirectory;
  Status := RunBrowse(Options);
  if Status = 2 then
  begin
    Result.Failure := HarnessTimeout;
    Result.Reason := Path + ' did not finish in time';
    Exit;
  end;
  if Status <> 0 then
  begin
    Result.Failure := HarnessError;
    Result.Reason := Path + ' failed to load';
    Exit;
  end;
  try
    Result.Image := LoadImage(Result.FileName);
  except
    on Error: Exception do
    begin
      Result.Failure := HarnessError;
      Result.Reason := Path + ': no screenshot (' + Error.Message + ')';
    end;
  end;
end;

{ wptrunner's check_pass for one pair of screenshots. }
function ScreenshotsEqual(constref Difference: TPixelDifference; Fuzzy: Boolean;
  constref Allowance: TFuzzyAllowance): Boolean;
begin
  if not Fuzzy or ((Allowance.MaxDifference.Highest = 0) and (Allowance.TotalPixels.Highest = 0)) then
    Exit((Difference.DifferentPixels = 0) and (Difference.MaxChannelDifference = 0));
  Result := ((Difference.DifferentPixels = 0) and (Allowance.TotalPixels.Lowest = 0)) or
    ((Difference.MaxChannelDifference = 0) and (Allowance.MaxDifference.Lowest = 0)) or
    ((Allowance.MaxDifference.Lowest <= Difference.MaxChannelDifference) and
    (Difference.MaxChannelDifference <= Allowance.MaxDifference.Highest) and
    (Allowance.TotalPixels.Lowest <= Difference.DifferentPixels) and
    (Difference.DifferentPixels <= Allowance.TotalPixels.Highest));
end;

const
  RelationText: array[TReftestRelation] of string = ('==', '!=');

procedure TReftestRun.Run(out Status: THarnessStatus; out Message: string);
var
  Stack: array of TPendingComparison;
  Pending: TPendingComparison;
  Test, Next: TReftestPage;
  Left, Right: TScreenshot;
  Difference: TPixelDifference;
  Allowance: TFuzzyAllowance;
  Fuzzy, Passed: Boolean;
  Index, Comparisons: Integer;

  procedure PushLinks(constref Page: TReftestPage);
  var
    LinkIndex: Integer;
  begin
    for LinkIndex := High(Page.Links) downto 0 do
    begin
      SetLength(Stack, Length(Stack) + 1);
      Stack[High(Stack)].Left := Page;
      Stack[High(Stack)].Right := Page.Links[LinkIndex];
    end;
  end;

begin
  Status := HarnessFail;
  Message := '';
  Test := ReadReftestPage(Root, TestPath);
  Width := Test.ViewportWidth;
  Height := Test.ViewportHeight;
  if Test.Links = nil then
  begin
    Status := HarnessError;
    Message := 'no references';
    Exit;
  end;
  Stack := nil;
  PushLinks(Test);
  Comparisons := 0;
  while (Stack <> nil) and (Comparisons < MostComparisons) do
  begin
    Pending := Stack[High(Stack)];
    SetLength(Stack, Length(Stack) - 1);
    Inc(Comparisons);
    Left := Screenshot(Pending.Left.Path);
    Right := Screenshot(Pending.Right.Path);
    for Index := 0 to 1 do
      if ((Index = 0) and (Left.Image = nil)) or ((Index = 1) and (Right.Image = nil)) then
      begin
        if Index = 0 then
        begin
          Status := Left.Failure;
          Message := Left.Reason;
        end
        else
        begin
          Status := Right.Failure;
          Message := Right.Reason;
        end;
        Exit;
      end;
    Difference := ComparePixels(Left.Image, Right.Image);
    Fuzzy := FindAllowance(Pending.Left, Pending.Right.Path, Allowance);
    Passed := ScreenshotsEqual(Difference, Fuzzy, Allowance) = (Pending.Right.Relation = RelationMatch);
    Message := Format('%s %s %s: maxDifference=%d;totalPixels=%d', [Pending.Left.Path,
      RelationText[Pending.Right.Relation], Pending.Right.Path, Difference.MaxChannelDifference,
      Difference.DifferentPixels]);
    if Fuzzy then
      Message := Message + Format(' (allowed %d-%d;%d-%d)', [Allowance.MaxDifference.Lowest,
        Allowance.MaxDifference.Highest, Allowance.TotalPixels.Lowest, Allowance.TotalPixels.Highest]);
    if not Passed then
      Continue;
    Next := ReadReftestPage(Root, Pending.Right.Path);
    if Next.Links = nil then
    begin
      Status := HarnessOk;
      Message := '';
      Exit;
    end;
    PushLinks(Next);
  end;
end;

{ Every PNG of the shot directory (an earlier run's too), and the
  directory. }
procedure TReftestRun.RemoveShots;
var
  Search: TSearchRec;
begin
  if FindFirst(IncludeTrailingPathDelimiter(ShotDirectory) + '*.png', faAnyFile, Search) = 0 then
  begin
    repeat
      DeleteFile(IncludeTrailingPathDelimiter(ShotDirectory) + Search.Name);
    until FindNext(Search) <> 0;
    FindClose(Search);
  end;
  RemoveDir(ShotDirectory);
end;

function ReportLine(const Url: string; Status: THarnessStatus; const Message: string): string;
var
  Report: TJSONObject;
begin
  Report := TJSONObject.Create;
  try
    Report.Add('url', Url);
    Report.Add('status', Ord(Status));
    Report.Add('message', Message);
    Report.Add('tests', TJSONArray.Create);
    Result := ResultMarker + Report.AsJSON;
  finally
    Report.Free;
  end;
end;

function RunReftestChild: Integer;
var
  Run: TReftestRun;
  Index: Integer;
  Argument, Message: string;
  Status: THarnessStatus;
begin
  Run := TReftestRun.Create;
  try
    Run.PageSeconds := 10;
    Run.FontDirectory := 'userland/fonts';
    Index := 1;
    while Index <= ParamCount do
    begin
      Argument := ParamStr(Index);
      if Index < ParamCount then
      begin
        if Argument = '--reftest' then
          Run.TestPath := ParamStr(Index + 1)
        else if Argument = '--wpt' then
          Run.Root := ParamStr(Index + 1)
        else if Argument = '--base' then
          Run.BaseUrl := ParamStr(Index + 1)
        else if Argument = '--seconds' then
          Run.PageSeconds := StrToFloatDef(ParamStr(Index + 1), 10)
        else if Argument = '--shots' then
          Run.ShotDirectory := ParamStr(Index + 1)
        else if Argument = '--trust-ca' then
          TrustCertificateFile(ParamStr(Index + 1))
        else if Argument = '-f' then
          Run.FontDirectory := ParamStr(Index + 1)
        else if Argument = '--user-fonts' then
          Run.UserFontDirectory := ParamStr(Index + 1)
        else
        begin
          Inc(Index);
          Continue;
        end;
        Inc(Index, 2);
      end
      else
        Inc(Index);
    end;
    MapHostToAddress(TestDomain, LoopbackAddress);
    MapHostToAddress(AlternateTestDomain, LoopbackAddress);
    ForceDirectories(Run.ShotDirectory);
    Run.RemoveShots;
    ForceDirectories(Run.ShotDirectory);
    Run.Run(Status, Message);
    if Status = HarnessOk then
      Run.RemoveShots;
    WriteLn(ReportLine(Run.BaseUrl + Run.TestPath, Status, Message));
    Flush(Output);
    Result := 0;
  finally
    Run.Free;
  end;
end;

end.
