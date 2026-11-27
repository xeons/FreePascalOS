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
  A reftest's graph, read from the checkout the way WPT's manifest reads
  it (tools/manifest/sourcefile.py): a page's <link rel=match href> and
  <link rel=mismatch href> (the match links first, each in document
  order; hrefs resolved against the page's path), its <meta name=fuzzy
  content="[REF:]maxDifference=A-B;totalPixels=C-D"> allowances (the
  names may be left out, a single number is a range of one) and its
  <meta name=viewport-size content=WxH>. A reference may have links of
  its own: the chain must hold too.
}
unit WptRun.Reftests;

{$mode objfpc}
{$H+}

interface

type
  TReftestRelation = (RelationMatch, RelationMismatch);

  TReftestLink = record
    { The reference's URL path from the root ("/css/a-ref.html"). }
    Path: string;
    Relation: TReftestRelation;
  end;

  TFuzzyRange = record
    Lowest, Highest: Integer;
  end;

  TFuzzyAllowance = record
    { The reference it is for; '' for every reference without its own. }
    ReferencePath: string;
    MaxDifference, TotalPixels: TFuzzyRange;
  end;

  TReftestPage = record
    Path: string;
    Links: array of TReftestLink;
    Allowances: array of TFuzzyAllowance;
    ViewportWidth, ViewportHeight: Integer;
  end;

const
  ReftestViewportWidth = 800;
  ReftestViewportHeight = 600;

{ Whether markup Text links to a reference (a reftest or a reference
  with references of its own). }
function HasReftestLinks(const Text: string): Boolean;
{ Whether its <meta name=flags> marks a CSS WG manual test (animated,
  font, history, interact, paged, speech, userstyle): not run. }
function HasManualFlags(const Text: string): Boolean;
{ The page at URL path Path of the checkout at Root (a page that cannot
  be read has no links). }
function ReadReftestPage(const Root, Path: string): TReftestPage;
{ The allowance of Page for its reference ReferencePath; False when none
  applies (the screenshots must be equal). }
function FindAllowance(constref Page: TReftestPage; const ReferencePath: string;
  out Allowance: TFuzzyAllowance): Boolean;
{ The distinct pages of the graph from Path (itself included), at most
  Limit. }
function ReftestPageCount(const Root, Path: string; Limit: Integer): Integer;
{ Reference resolved against the directory of BasePath ("/a/b.html" and
  "../c.html": "/c.html"; an absolute path stays; a scheme-relative or
  absolute URL is returned as it is). }
function ResolveUrlPath(const BasePath, Reference: string): string;

implementation

uses
  SysUtils,
  Classes,
  StrUtils;

function ReadFileText(const FileName: string): string;
var
  Stream: TFileStream;
begin
  Result := '';
  if not FileExists(FileName) then
    Exit;
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

{ The value of attribute Name (lower case) in the tag text Tag; '' when
  absent. }
function Attribute(const Tag, Name: string): string;
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
    if (At > 1) and not (Lower[At - 1] in [' ', #9, #10, #12, #13, '"', '''', '/']) then
    begin
      Inc(At);
      Continue;
    end;
    Stop := At + Length(Name);
    while (Stop <= Length(Tag)) and (Tag[Stop] in [' ', #9, #10, #12, #13]) do
      Inc(Stop);
    if (Stop > Length(Tag)) or (Tag[Stop] <> '=') then
    begin
      Inc(At);
      Continue;
    end;
    Inc(Stop);
    while (Stop <= Length(Tag)) and (Tag[Stop] in [' ', #9, #10, #12, #13]) do
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
      while (Stop <= Length(Tag)) and not (Tag[Stop] in [' ', #9, #10, #12, #13, '>']) do
        Inc(Stop);
      { "<link href=a.html/>": the slash closes the tag. }
      if (Stop > At) and (Stop <= Length(Tag)) and (Tag[Stop] = '>') and (Tag[Stop - 1] = '/') then
        Dec(Stop);
    end;
    Exit(Copy(Tag, At, Stop - At));
  until False;
end;

{ The start tags named Element ("link", "meta"), also with a namespace
  prefix ("html:link"), outside comments. }
function TagsNamed(const Text, Element: string): TStringArray;
var
  Lower, Name: string;
  At, Stop, NameStart: Integer;
begin
  Result := nil;
  Lower := LowerCase(Text);
  At := 1;
  while At <= Length(Lower) do
  begin
    At := PosEx('<', Lower, At);
    if At = 0 then
      Break;
    if Copy(Lower, At, 4) = '<!--' then
    begin
      Stop := PosEx('-->', Lower, At + 4);
      if Stop = 0 then
        Break;
      At := Stop + 3;
      Continue;
    end;
    NameStart := At + 1;
    Stop := NameStart;
    while (Stop <= Length(Lower)) and (Lower[Stop] in ['a'..'z', '0'..'9', ':', '-']) do
      Inc(Stop);
    Name := Copy(Lower, NameStart, Stop - NameStart);
    if (Name = Element) or AnsiEndsStr(':' + Element, Name) then
    begin
      At := Stop;
      Stop := PosEx('>', Lower, At);
      if Stop = 0 then
        Break;
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := Copy(Text, NameStart - 1, Stop - NameStart + 2);
      At := Stop + 1;
    end
    else
      At := Stop;
  end;
end;

function IsReftestRelation(const Rel: string; out Relation: TReftestRelation): Boolean;
begin
  Result := True;
  Relation := RelationMatch;
  if Rel = 'match' then
    Relation := RelationMatch
  else if Rel = 'mismatch' then
    Relation := RelationMismatch
  else
    Result := False;
end;

function HasManualFlags(const Text: string): Boolean;
const
  ManualFlags: array[0..6] of string = ('animated', 'font', 'history', 'interact', 'paged', 'speech', 'userstyle');
var
  Tag, Flag, Wanted: string;
begin
  for Tag in TagsNamed(Text, 'meta') do
    if LowerCase(Attribute(Tag, 'name')) = 'flags' then
      for Flag in Attribute(Tag, 'content').Split([' ', #9, #10, #12, #13]) do
        for Wanted in ManualFlags do
          if Flag = Wanted then
            Exit(True);
  Result := False;
end;

function HasReftestLinks(const Text: string): Boolean;
var
  Tag: string;
  Relation: TReftestRelation;
begin
  for Tag in TagsNamed(Text, 'link') do
    if IsReftestRelation(Attribute(Tag, 'rel'), Relation) and (Trim(Attribute(Tag, 'href')) <> '') then
      Exit(True);
  Result := False;
end;

function ResolveUrlPath(const BasePath, Reference: string): string;
var
  Parts, Output: TStringArray;
  Path, Suffix: string;
  Index, Count, Cut: Integer;
begin
  if (Pos('://', Reference) > 0) or (Copy(Reference, 1, 2) = '//') then
    Exit(Reference);
  Suffix := '';
  Path := Reference;
  Cut := Pos('?', Path);
  if (Cut = 0) or ((Pos('#', Path) > 0) and (Pos('#', Path) < Cut)) then
    Cut := Pos('#', Path);
  if Cut > 0 then
  begin
    Suffix := Copy(Path, Cut, MaxInt);
    Path := Copy(Path, 1, Cut - 1);
  end;
  if Path = '' then
    Path := BasePath
  else if Path[1] <> '/' then
    Path := Copy(BasePath, 1, RPos('/', BasePath)) + Path;
  Parts := Path.Split(['/']);
  Output := nil;
  SetLength(Output, Length(Parts));
  Count := 0;
  for Index := 0 to High(Parts) do
    if Parts[Index] = '.' then
      Continue
    else if Parts[Index] = '..' then
    begin
      if Count > 1 then
        Dec(Count);
    end
    else
    begin
      Output[Count] := Parts[Index];
      Inc(Count);
    end;
  Result := '';
  for Index := 0 to Count - 1 do
  begin
    if Index > 0 then
      Result := Result + '/';
    Result := Result + Output[Index];
  end;
  if (Length(Parts) > 0) and ((Parts[High(Parts)] = '.') or (Parts[High(Parts)] = '..')) then
    Result := Result + '/';
  if (Result = '') or (Result[1] <> '/') then
    Result := '/' + Result;
  Result := Result + Suffix;
end;

{ "10-15" or "15" (a range of one); False when malformed. }
function ParseRange(const Text: string; out Range: TFuzzyRange): Boolean;
var
  Dash: Integer;
begin
  Dash := Pos('-', Text);
  if Dash = 0 then
  begin
    Range.Lowest := StrToIntDef(Trim(Text), -1);
    Range.Highest := Range.Lowest;
  end
  else
  begin
    Range.Lowest := StrToIntDef(Trim(Copy(Text, 1, Dash - 1)), -1);
    Range.Highest := StrToIntDef(Trim(Copy(Text, Dash + 1, MaxInt)), -1);
  end;
  Result := (Range.Lowest >= 0) and (Range.Highest >= Range.Lowest);
end;

{ "[REF:]A;B" with optional "maxDifference=" and "totalPixels=". }
function ParseAllowance(const PagePath, Content: string; out Allowance: TFuzzyAllowance): Boolean;
var
  Value, Name, Item: string;
  Colon, Equals, Index, Positional: Integer;
  Items: TStringArray;
  Ranges: array[0..1] of TFuzzyRange;
  Named: array[0..1] of Boolean;
  Range: TFuzzyRange;
begin
  Allowance := Default(TFuzzyAllowance);
  Value := Content;
  Colon := RPos(':', Value);
  if Colon > 0 then
  begin
    Allowance.ReferencePath := ResolveUrlPath(PagePath, Trim(Copy(Value, 1, Colon - 1)));
    Value := Copy(Value, Colon + 1, MaxInt);
  end;
  Items := Value.Split([';']);
  if Length(Items) <> 2 then
    Exit(False);
  Named[0] := False;
  Named[1] := False;
  for Index := 0 to 1 do
  begin
    Item := Items[Index];
    Equals := Pos('=', Item);
    if Equals = 0 then
      Continue;
    Name := Trim(Copy(Item, 1, Equals - 1));
    if not ParseRange(Copy(Item, Equals + 1, MaxInt), Range) then
      Exit(False);
    if Name = 'maxDifference' then
    begin
      Ranges[0] := Range;
      Named[0] := True;
    end
    else if Name = 'totalPixels' then
    begin
      Ranges[1] := Range;
      Named[1] := True;
    end
    else
      Exit(False);
  end;
  Positional := 0;
  for Index := 0 to 1 do
  begin
    Item := Items[Index];
    if Pos('=', Item) > 0 then
      Continue;
    while (Positional <= 1) and Named[Positional] do
      Inc(Positional);
    if (Positional > 1) or not ParseRange(Item, Ranges[Positional]) then
      Exit(False);
    Named[Positional] := True;
  end;
  if not (Named[0] and Named[1]) then
    Exit(False);
  Allowance.MaxDifference := Ranges[0];
  Allowance.TotalPixels := Ranges[1];
  Result := True;
end;

function ReadReftestPage(const Root, Path: string): TReftestPage;
var
  Text, Tag, Href, FilePath, Size: string;
  Relation, Pass: TReftestRelation;
  Allowance: TFuzzyAllowance;
  Cross: Integer;
begin
  Result := Default(TReftestPage);
  Result.Path := Path;
  Result.ViewportWidth := ReftestViewportWidth;
  Result.ViewportHeight := ReftestViewportHeight;
  FilePath := Path;
  if Pos('?', FilePath) > 0 then
    FilePath := Copy(FilePath, 1, Pos('?', FilePath) - 1);
  if Pos('#', FilePath) > 0 then
    FilePath := Copy(FilePath, 1, Pos('#', FilePath) - 1);
  Text := ReadFileText(ExcludeTrailingPathDelimiter(Root) + FilePath);
  if Text = '' then
    Exit;
  for Pass := Low(TReftestRelation) to High(TReftestRelation) do
    for Tag in TagsNamed(Text, 'link') do
    begin
      Href := Trim(Attribute(Tag, 'href'));
      if (Href = '') or not IsReftestRelation(Attribute(Tag, 'rel'), Relation) or (Relation <> Pass) then
        Continue;
      SetLength(Result.Links, Length(Result.Links) + 1);
      Result.Links[High(Result.Links)].Path := ResolveUrlPath(Path, Href);
      Result.Links[High(Result.Links)].Relation := Relation;
    end;
  for Tag in TagsNamed(Text, 'meta') do
  begin
    if LowerCase(Attribute(Tag, 'name')) = 'fuzzy' then
    begin
      if ParseAllowance(Path, Attribute(Tag, 'content'), Allowance) then
      begin
        SetLength(Result.Allowances, Length(Result.Allowances) + 1);
        Result.Allowances[High(Result.Allowances)] := Allowance;
      end;
    end
    else if LowerCase(Attribute(Tag, 'name')) = 'viewport-size' then
    begin
      Size := LowerCase(Trim(Attribute(Tag, 'content')));
      Cross := Pos('x', Size);
      if Cross > 0 then
      begin
        Result.ViewportWidth := StrToIntDef(Copy(Size, 1, Cross - 1), ReftestViewportWidth);
        Result.ViewportHeight := StrToIntDef(Copy(Size, Cross + 1, MaxInt), ReftestViewportHeight);
      end;
    end;
  end;
end;

function FindAllowance(constref Page: TReftestPage; const ReferencePath: string;
  out Allowance: TFuzzyAllowance): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to High(Page.Allowances) do
    if Page.Allowances[Index].ReferencePath = ReferencePath then
    begin
      Allowance := Page.Allowances[Index];
      Exit(True);
    end;
  for Index := 0 to High(Page.Allowances) do
    if Page.Allowances[Index].ReferencePath = '' then
    begin
      Allowance := Page.Allowances[Index];
      Exit(True);
    end;
  Allowance := Default(TFuzzyAllowance);
  Result := False;
end;

function ReftestPageCount(const Root, Path: string; Limit: Integer): Integer;
var
  Seen, Pending: TStringList;
  Page: TReftestPage;
  Index: Integer;
begin
  Seen := TStringList.Create;
  Pending := TStringList.Create;
  try
    Seen.Sorted := True;
    Pending.Add(Path);
    Seen.Add(Path);
    while (Pending.Count > 0) and (Seen.Count < Limit) do
    begin
      Page := ReadReftestPage(Root, Pending[0]);
      Pending.Delete(0);
      for Index := 0 to High(Page.Links) do
        if Seen.IndexOf(Page.Links[Index].Path) < 0 then
        begin
          Seen.Add(Page.Links[Index].Path);
          Pending.Add(Page.Links[Index].Path);
        end;
    end;
    Result := Seen.Count;
    if Result > Limit then
      Result := Limit;
  finally
    Pending.Free;
    Seen.Free;
  end;
end;

end.
