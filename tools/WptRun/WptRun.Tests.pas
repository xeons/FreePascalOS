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
  Which testharness tests and reftests a path of the WPT checkout holds,
  the way
  WPT's manifest (tools/manifest/sourcefile.py) names them:

    x.html, .htm, .xhtml, .xht, .svg   one test when it loads
                                       /resources/testharness.js
    x.any.js      one test per global of "// META: global=" (window and
                  dedicatedworker when absent): x.any.html,
                  x.any.worker.html, x.any.sharedworker.html,
                  x.any.serviceworker.html, x.any.window-module.html, ...
    x.window.js   x.window.html
    x.worker.js   x.worker.html

  each once per variant (<meta name=variant content=?a>, "// META:
  variant=?a"). A markup file without testharness.js that links to a
  reference (<link rel=match|mismatch>) is a reftest, unless its
  <meta name=flags> marks it a CSS manual test. A test is long ("timeout=long") when its META or
  <meta name=timeout content=long> says so, and loads over https when
  its name has ".https." or ".h2." or its global is a service worker.
  Directories named resources, support or tools, the top-level common,
  and files named -manual, -visual, -crash or as references are not
  tests.
}
unit WptRun.Tests;

{$mode objfpc}
{$H+}

interface

type
  TWptTest = record
    { The test's URL path with its variant ("/url/a.any.worker.html?x"):
      what results and expectations are keyed by. }
    Path: string;
    Secure: Boolean;
    LongTimeout: Boolean;
    { A reftest (WptRun.Reftests): screenshots of it and its references
      compared, PageCount pages rendered at most. }
    Reftest: Boolean;
    PageCount: Integer;
  end;
  TWptTestList = array of TWptTest;

{ The tests under each of Paths (directories or files of the checkout at
  Root, relative to it; a generated test path such as
  "url/a.any.worker.html" names that test of its source), sorted, each
  once. }
function CollectTests(const Root: string; const Paths: array of string): TWptTestList;

implementation

uses
  SysUtils,
  Classes,
  StrUtils,
  WptRun.Reftests;

const
  { The pages of a reftest graph a test is given time for. }
  MostReftestPages = 8;

type
  TMetaPair = record
    Key, Value: string;
  end;
  TMetaPairs = array of TMetaPair;

  TAnyGlobal = record
    Name: string;
    Suffix: string;
    ForceHttps: Boolean;
  end;

const
  AnyGlobals: array[0..7] of TAnyGlobal = (
    (Name: 'window'; Suffix: '.any.html'; ForceHttps: False),
    (Name: 'window-module'; Suffix: '.any.window-module.html'; ForceHttps: False),
    (Name: 'dedicatedworker'; Suffix: '.any.worker.html'; ForceHttps: False),
    (Name: 'dedicatedworker-module'; Suffix: '.any.worker-module.html'; ForceHttps: False),
    (Name: 'sharedworker'; Suffix: '.any.sharedworker.html'; ForceHttps: False),
    (Name: 'sharedworker-module'; Suffix: '.any.sharedworker-module.html'; ForceHttps: False),
    (Name: 'serviceworker'; Suffix: '.any.serviceworker.html'; ForceHttps: True),
    (Name: 'serviceworker-module'; Suffix: '.any.serviceworker-module.html'; ForceHttps: True));

function ReadText(const FileName: string): string;
var
  Stream: TFileStream;
begin
  Result := '';
  try
    Stream := TFileStream.Create(FileName, fmOpenRead or fmShareDenyNone);
    try
      SetLength(Result, Stream.Size);
      if Stream.Size > 0 then
        Stream.ReadBuffer(Result[1], Stream.Size);
    finally
      Stream.Free;
    end;
  except
    Result := '';
  end;
end;

{ The leading "// META: key=value" lines of a script test. }
function ScriptMetadata(const Text: string): TMetaPairs;
var
  Lines: TStringList;
  Index, Equals: Integer;
  Line: string;
begin
  Result := nil;
  Lines := TStringList.Create;
  try
    Lines.Text := Text;
    for Index := 0 to Lines.Count - 1 do
    begin
      Line := Trim(Lines[Index]);
      if Copy(Line, 1, 2) <> '//' then
        Break;
      Line := TrimLeft(Copy(Line, 3, MaxInt));
      if Copy(Line, 1, 5) <> 'META:' then
        Break;
      Line := TrimLeft(Copy(Line, 6, MaxInt));
      Equals := Pos('=', Line);
      if Equals < 1 then
        Break;
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)].Key := Trim(Copy(Line, 1, Equals - 1));
      Result[High(Result)].Value := Trim(Copy(Line, Equals + 1, MaxInt));
    end;
  finally
    Lines.Free;
  end;
end;

{ The value of attribute Name in the tag text Tag ("" when absent). }
function AttributeOf(const Tag, Name: string): string;
var
  Lower: string;
  At, Stop: Integer;
  Quote: Char;
begin
  Result := '';
  Lower := LowerCase(Tag);
  At := 1;
  repeat
    At := PosEx(Name, Lower, At);
    if At = 0 then
      Exit;
    if (At > 1) and not (Lower[At - 1] in [' ', #9, #10, #13, '"', '''', '/']) then
    begin
      Inc(At);
      Continue;
    end;
    Stop := At + Length(Name);
    while (Stop <= Length(Tag)) and (Tag[Stop] in [' ', #9, #10, #13]) do
      Inc(Stop);
    if (Stop > Length(Tag)) or (Tag[Stop] <> '=') then
    begin
      Inc(At);
      Continue;
    end;
    Inc(Stop);
    while (Stop <= Length(Tag)) and (Tag[Stop] in [' ', #9, #10, #13]) do
      Inc(Stop);
    if Stop > Length(Tag) then
      Exit;
    if Tag[Stop] in ['"', ''''] then
    begin
      Quote := Tag[Stop];
      At := Stop + 1;
      Stop := At;
      while (Stop <= Length(Tag)) and (Tag[Stop] <> Quote) do
        Inc(Stop);
    end
    else
    begin
      At := Stop;
      while (Stop <= Length(Tag)) and not (Tag[Stop] in [' ', #9, #10, #13, '>', '/']) do
        Inc(Stop);
    end;
    Exit(Copy(Tag, At, Stop - At));
  until False;
end;

{ The <meta name=timeout|variant content=...> of a markup test. }
function MarkupMetadata(const Text: string): TMetaPairs;
var
  Lower, Tag, Name: string;
  At, Stop: Integer;
begin
  Result := nil;
  Lower := LowerCase(Text);
  At := Pos('<meta', Lower);
  while At > 0 do
  begin
    Stop := PosEx('>', Lower, At);
    if Stop = 0 then
      Break;
    Tag := Copy(Text, At, Stop - At + 1);
    Name := LowerCase(AttributeOf(Tag, 'name'));
    if (Name = 'timeout') or (Name = 'variant') then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)].Key := Name;
      Result[High(Result)].Value := AttributeOf(Tag, 'content');
    end;
    At := PosEx('<meta', Lower, Stop);
  end;
end;

function MetaValue(const Pairs: TMetaPairs; const Key: string): string;
var
  Index: Integer;
begin
  for Index := 0 to High(Pairs) do
    if Pairs[Index].Key = Key then
      Exit(Pairs[Index].Value);
  Result := '';
end;

function Variants(const Pairs: TMetaPairs): TStringArray;
var
  Index: Integer;
begin
  Result := nil;
  for Index := 0 to High(Pairs) do
    if (Pairs[Index].Key = 'variant') and ((Pairs[Index].Value = '') or (Pairs[Index].Value[1] in ['?', '#'])) then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := Pairs[Index].Value;
    end;
  if Result = nil then
  begin
    SetLength(Result, 1);
    Result[0] := '';
  end;
end;

{ The name's flags: the dot-separated parts between the stem and the
  extension ("a.https.any.js": https, any). }
function HasFlag(const FileName, Flag: string): Boolean;
var
  Parts: TStringArray;
  Index: Integer;
begin
  Parts := FileName.Split(['.']);
  for Index := 1 to High(Parts) - 1 do
    if Parts[Index] = Flag then
      Exit(True);
  Result := False;
end;

{ manual, visual, crash, reference files: not testharness tests. }
function NamedAsNonTest(const FileName: string): Boolean;
var
  Stem, Kind, Lower: string;
  Dash: Integer;
begin
  Stem := Copy(FileName, 1, Pos('.', FileName + '.') - 1);
  Dash := RPos('-', Stem);
  Kind := '';
  if Dash > 0 then
    Kind := Copy(Stem, Dash + 1, MaxInt);
  if (Kind = 'manual') or (Kind = 'visual') or (Kind = 'crash') or (Kind = 'print') then
    Exit(True);
  { (^|[-_])(not)?ref[0-9]*([-_]|$) on the stem. }
  Lower := '-' + Stem + '-';
  Lower := StringReplace(Lower, '_', '-', [rfReplaceAll]);
  Result := (Pos('-ref-', Lower) > 0) or (Pos('-notref-', Lower) > 0);
  if not Result then
    for Dash := 0 to 9 do
      if (Pos('-ref' + IntToStr(Dash), Lower) > 0) or (Pos('-notref' + IntToStr(Dash), Lower) > 0) then
        Exit(True);
end;

function NonTestDirectory(const Name: string): Boolean;
begin
  Result := (Name = 'resources') or (Name = 'support') or (Name = 'tools') or (Name = 'crashtests') or
    (Name = 'reference') or (Name = 'print') or ((Name <> '') and (Name[1] = '.'));
end;

procedure AddTest(var List: TWptTestList; const Path: string; Secure, LongTimeout: Boolean;
  Reftest: Boolean = False; PageCount: Integer = 0);
begin
  SetLength(List, Length(List) + 1);
  List[High(List)].Path := Path;
  List[High(List)].Secure := Secure or (Pos('.https.', Path) > 0) or (Pos('.h2.', Path) > 0);
  List[High(List)].LongTimeout := LongTimeout;
  List[High(List)].Reftest := Reftest;
  List[High(List)].PageCount := PageCount;
end;

{ The reftest of markup file FileName (Lower: its text in lower case),
  once per variant, when it is one. }
procedure ExpandReftest(const FileName, UrlPath, Lower: string; var List: TWptTestList);
var
  Root: string;
  Pairs: TMetaPairs;
  Variant: string;
  PageCount: Integer;
begin
  if (Pos('/reference/', UrlPath) > 0) or not HasReftestLinks(Lower) or HasManualFlags(Lower) then
    Exit;
  Root := Copy(FileName, 1, Length(FileName) - Length(UrlPath));
  PageCount := ReftestPageCount(Root, UrlPath, MostReftestPages);
  Pairs := MarkupMetadata(Lower);
  for Variant in Variants(MarkupMetadata(ReadText(FileName))) do
    AddTest(List, UrlPath + Variant, False, MetaValue(Pairs, 'timeout') = 'long', True, PageCount);
end;

{ The tests of one file; UrlPath is its path from the root ("/dom/a.html"). }
procedure ExpandFile(const FileName, UrlPath: string; var List: TWptTestList);
var
  Name, Extension, Lower, Base, Globals, Item: string;
  Pairs: TMetaPairs;
  VariantList: TStringArray;
  Variant: string;
  Long: Boolean;
  Index, GlobalIndex: Integer;
  Wanted: array[Low(AnyGlobals)..High(AnyGlobals)] of Boolean;
begin
  Name := ExtractFileName(FileName);
  Extension := LowerCase(ExtractFileExt(Name));
  if NamedAsNonTest(Name) then
    Exit;
  if Extension = '.js' then
  begin
    if not (HasFlag(Name, 'any') or HasFlag(Name, 'window') or HasFlag(Name, 'worker')) then
      Exit;
    Pairs := ScriptMetadata(ReadText(FileName));
    Long := MetaValue(Pairs, 'timeout') = 'long';
    VariantList := Variants(Pairs);
    if HasFlag(Name, 'any') then
    begin
      Globals := MetaValue(Pairs, 'global');
      if Globals = '' then
        Globals := 'window,dedicatedworker';
      for GlobalIndex := Low(Wanted) to High(Wanted) do
        Wanted[GlobalIndex] := False;
      for Item in Globals.Split([',']) do
        for GlobalIndex := Low(AnyGlobals) to High(AnyGlobals) do
          if (Trim(Item) = AnyGlobals[GlobalIndex].Name) or ((Trim(Item) = 'worker') and
            ((AnyGlobals[GlobalIndex].Name = 'dedicatedworker') or (AnyGlobals[GlobalIndex].Name = 'sharedworker') or
            (AnyGlobals[GlobalIndex].Name = 'serviceworker'))) then
            Wanted[GlobalIndex] := True;
      { "a.https.any.js": a.https.any.worker.html. }
      Base := StringReplace(UrlPath, '.any.', '.', []);
      Base := Copy(Base, 1, Length(Base) - Length('.js'));
      for GlobalIndex := Low(AnyGlobals) to High(AnyGlobals) do
        if Wanted[GlobalIndex] then
          for Variant in VariantList do
            AddTest(List, Base + AnyGlobals[GlobalIndex].Suffix + Variant, AnyGlobals[GlobalIndex].ForceHttps, Long);
    end
    else
      for Variant in VariantList do
        AddTest(List, Copy(UrlPath, 1, Length(UrlPath) - Length('.js')) + '.html' + Variant, False, Long);
    Exit;
  end;
  if (Extension <> '.html') and (Extension <> '.htm') and (Extension <> '.xhtml') and (Extension <> '.xht') and
    (Extension <> '.svg') then
    Exit;
  Lower := LowerCase(ReadText(FileName));
  if Pos('/resources/testharness.js', Lower) = 0 then
  begin
    ExpandReftest(FileName, UrlPath, Lower, List);
    Exit;
  end;
  Pairs := MarkupMetadata(Lower);
  Long := MetaValue(Pairs, 'timeout') = 'long';
  VariantList := Variants(MarkupMetadata(ReadText(FileName)));
  for Index := 0 to High(VariantList) do
    AddTest(List, UrlPath + VariantList[Index], False, Long);
end;

procedure ExpandDirectory(const Directory, UrlPath: string; var List: TWptTestList);
var
  Search: TSearchRec;
  Names: TStringList;
  Index: Integer;
begin
  Names := TStringList.Create;
  try
    if FindFirst(IncludeTrailingPathDelimiter(Directory) + '*', faAnyFile or faDirectory, Search) = 0 then
    begin
      repeat
        if (Search.Name <> '.') and (Search.Name <> '..') then
          Names.Add(Search.Name);
      until FindNext(Search) <> 0;
      FindClose(Search);
    end;
    Names.Sort;
    for Index := 0 to Names.Count - 1 do
      if DirectoryExists(IncludeTrailingPathDelimiter(Directory) + Names[Index]) then
      begin
        if not NonTestDirectory(Names[Index]) then
          ExpandDirectory(IncludeTrailingPathDelimiter(Directory) + Names[Index], UrlPath + Names[Index] + '/', List);
      end
      else
        ExpandFile(IncludeTrailingPathDelimiter(Directory) + Names[Index], UrlPath + Names[Index], List);
  finally
    Names.Free;
  end;
end;

{ The source of a generated test path ("a.any.worker.html": a.any.js). }
function SourceOfGenerated(const Path: string): string;
var
  GlobalIndex: Integer;
  Suffix: string;
begin
  for GlobalIndex := Low(AnyGlobals) to High(AnyGlobals) do
  begin
    Suffix := AnyGlobals[GlobalIndex].Suffix;
    if AnsiEndsStr(Suffix, Path) then
      Exit(Copy(Path, 1, Length(Path) - Length(Suffix)) + '.any.js');
  end;
  if AnsiEndsStr('.window.html', Path) or AnsiEndsStr('.worker.html', Path) then
    Exit(Copy(Path, 1, Length(Path) - Length('.html')) + '.js');
  Result := '';
end;

procedure SortAndDeduplicate(var List: TWptTestList);
var
  Index, Kept: Integer;
  Swap: TWptTest;
  Gap, Inner: Integer;
begin
  { Shell sort by path. }
  Gap := Length(List) div 2;
  while Gap > 0 do
  begin
    for Index := Gap to High(List) do
    begin
      Swap := List[Index];
      Inner := Index;
      while (Inner >= Gap) and (CompareStr(List[Inner - Gap].Path, Swap.Path) > 0) do
      begin
        List[Inner] := List[Inner - Gap];
        Dec(Inner, Gap);
      end;
      List[Inner] := Swap;
    end;
    Gap := Gap div 2;
  end;
  Kept := 0;
  for Index := 0 to High(List) do
    if (Kept = 0) or (List[Kept - 1].Path <> List[Index].Path) then
    begin
      List[Kept] := List[Index];
      Inc(Kept);
    end;
  SetLength(List, Kept);
end;

function CollectTests(const Root: string; const Paths: array of string): TWptTestList;
var
  Index, TestIndex: Integer;
  Relative, Wanted, Source, Query: string;
  Found: TWptTestList;
begin
  Result := nil;
  for Index := 0 to High(Paths) do
  begin
    Relative := Paths[Index];
    while (Relative <> '') and (Relative[1] = '/') do
      Delete(Relative, 1, 1);
    Query := '';
    if Pos('?', Relative) > 0 then
    begin
      Query := Copy(Relative, Pos('?', Relative), MaxInt);
      Relative := Copy(Relative, 1, Pos('?', Relative) - 1);
    end;
    if (Relative = '') or DirectoryExists(IncludeTrailingPathDelimiter(Root) + Relative) then
    begin
      ExpandDirectory(IncludeTrailingPathDelimiter(Root) + Relative, '/' + IncludeTrailingPathDelimiter(Relative), Result);
      Continue;
    end;
    Found := nil;
    Wanted := '';
    if FileExists(IncludeTrailingPathDelimiter(Root) + Relative) then
      ExpandFile(IncludeTrailingPathDelimiter(Root) + Relative, '/' + Relative, Found)
    else
    begin
      Source := SourceOfGenerated(Relative);
      if (Source <> '') and FileExists(IncludeTrailingPathDelimiter(Root) + Source) then
        ExpandFile(IncludeTrailingPathDelimiter(Root) + Source, '/' + Source, Found);
      Wanted := '/' + Relative;
    end;
    if Found = nil then
      WriteLn(StdErr, 'wptrun: no tests in ', Paths[Index]);
    for TestIndex := 0 to High(Found) do
      if ((Wanted = '') or (Copy(Found[TestIndex].Path, 1, Length(Wanted)) = Wanted)) and
        ((Query = '') or (Copy(Found[TestIndex].Path, Length(Found[TestIndex].Path) - Length(Query) + 1, MaxInt) = Query)) then
        AddTest(Result, Found[TestIndex].Path, Found[TestIndex].Secure, Found[TestIndex].LongTimeout,
          Found[TestIndex].Reftest, Found[TestIndex].PageCount);
  end;
  SortAndDeduplicate(Result);
end;

end.
