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
  The location bar's suggestions as the user types (the "AwesomeBar"):
  pages from the history and the bookmarks whose title, address or tags
  hold every typed word, best first.

  - Matching: each word (case folded) must be in the title, the address
    or a tag. Special words narrow it, as in the browsers of old:
    "^" history only, "*" bookmarks only, "+" tagged pages only, "@"
    the words in the address only, "#" in the title only.
  - Ranking by "frecency": the visits (at most ten counted) weighted by
    how long ago the last was (100 within 4 days, 70 within 14, 50
    within 31, 30 within 90, else 10), and 75 more for a bookmark (an
    unvisited bookmark 100). A word found at the start of a word of the
    title or of the host counts half again; typed text the address
    starts with (after the scheme and "www.") counts four times.
  - What is suggested follows the Privacy setting: history and
    bookmarks, history only, bookmarks only, or nothing.

  Plain logic (the RTL only), checked on the host.
}
unit Browser.AwesomeBar;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Browser.History,
  Browser.Bookmarks;

type
  TSuggestBehaviour = (SuggestHistoryAndBookmarks, SuggestHistory, SuggestBookmarks, SuggestNothing);

  TSuggestionCandidate = record
    Title: string;
    Url: string;
    Tags: TStringArray;
    Bookmarked: Boolean;
    VisitCount: Integer;
    LastVisit: Int64;
  end;
  TSuggestionCandidates = array of TSuggestionCandidate;

  TSuggestion = record
    Title: string;
    Url: string;
    Tags: TStringArray;
    Bookmarked: Boolean;
    Score: Double;
  end;
  TSuggestions = array of TSuggestion;

  TSuggestRestriction = (RestrictHistory, RestrictBookmarks, RestrictTagged, RestrictUrl, RestrictTitle);
  TSuggestRestrictions = set of TSuggestRestriction;

const
  DefaultSuggestionCount = 12;

{ The typed text's words (case folded) and the special words in it. }
procedure ParseTyped(const Typed: string; out Words: TStringArray; out Restrictions: TSuggestRestrictions);
{ How much a page is worth suggesting, before matching. }
function Frecency(VisitCount: Integer; LastVisit, Now: Int64; Bookmarked: Boolean): Double;
{ The candidates matching Typed, best first, at most MaximumCount. }
function RankSuggestions(const Typed: string; const Candidates: TSuggestionCandidates; Now: Int64;
  Behaviour: TSuggestBehaviour; MaximumCount: Integer): TSuggestions;
{ Every page of the history and the bookmarks, once each (a bookmark
  with its history's visits). }
function GatherCandidates(History: THistoryStore; Bookmarks: TBookmarkStore): TSuggestionCandidates;
{ The suggestions for Typed from History and Bookmarks. }
function SuggestPlaces(const Typed: string; History: THistoryStore; Bookmarks: TBookmarkStore; Now: Int64;
  Behaviour: TSuggestBehaviour; MaximumCount: Integer = DefaultSuggestionCount): TSuggestions;
{ The address without its scheme and "www.", lowered: what typed text is
  compared with. }
function StrippedAddress(const Url: string): string;

implementation

uses
  Classes,
  Browser.TextFiles;

const
  SecondsPerDay = 86400;
  BookmarkBonus = 75;
  UnvisitedBookmarkPoints = 100;
  MaximumCountedVisits = 10;
  BoundaryFactor = 1.5;
  PrefixFactor = 4.0;

procedure ParseTyped(const Typed: string; out Words: TStringArray; out Restrictions: TSuggestRestrictions);
var
  All: TStringArray;
  Index: Integer;
begin
  Words := nil;
  Restrictions := [];
  All := SplitWords(Typed);
  for Index := 0 to High(All) do
    if All[Index] = '^' then
      Include(Restrictions, RestrictHistory)
    else if All[Index] = '*' then
      Include(Restrictions, RestrictBookmarks)
    else if All[Index] = '+' then
      Include(Restrictions, RestrictTagged)
    else if All[Index] = '@' then
      Include(Restrictions, RestrictUrl)
    else if All[Index] = '#' then
      Include(Restrictions, RestrictTitle)
    else
    begin
      SetLength(Words, Length(Words) + 1);
      Words[High(Words)] := All[Index];
    end;
end;

function Frecency(VisitCount: Integer; LastVisit, Now: Int64; Bookmarked: Boolean): Double;
var
  Age, Weight: Int64;
begin
  if VisitCount <= 0 then
  begin
    if Bookmarked then
      Exit(UnvisitedBookmarkPoints);
    Exit(0);
  end;
  Age := (Now - LastVisit) div SecondsPerDay;
  if Age <= 4 then
    Weight := 100
  else if Age <= 14 then
    Weight := 70
  else if Age <= 31 then
    Weight := 50
  else if Age <= 90 then
    Weight := 30
  else
    Weight := 10;
  if VisitCount > MaximumCountedVisits then
    VisitCount := MaximumCountedVisits;
  Result := VisitCount * Weight;
  if Bookmarked then
    Result := Result + BookmarkBonus;
end;

function StrippedAddress(const Url: string): string;
var
  Scheme: Integer;
begin
  Result := FoldCase(Url);
  Scheme := Pos('://', Result);
  if Scheme > 0 then
    Result := Copy(Result, Scheme + 3, MaxInt);
  if Copy(Result, 1, 4) = 'www.' then
    Result := Copy(Result, 5, MaxInt);
end;

{ Whether Word starts a word of Text (folded): at its start or after a
  character that is not a letter or digit. }
function AtWordStart(const Text, Word: string): Boolean;
var
  Start: Integer;
begin
  Start := Pos(Word, Text);
  while Start > 0 do
  begin
    if (Start = 1) or not (Text[Start - 1] in ['a'..'z', '0'..'9']) then
      Exit(True);
    Start := Pos(Word, Text, Start + 1);
  end;
  Result := False;
end;

function TagsText(const Tags: TStringArray): string;
var
  Index: Integer;
begin
  Result := '';
  for Index := 0 to High(Tags) do
    Result := Result + ' ' + FoldCase(Tags[Index]);
end;

{ Whether the candidate matches every word; Boundary: every word starts
  a word of the title or of the host. }
function Matches(constref Candidate: TSuggestionCandidate; const Words: TStringArray;
  Restrictions: TSuggestRestrictions; out Boundary: Boolean): Boolean;
var
  Title, Url, Tags, Host: string;
  Index: Integer;
  InTitle, InUrl, InTags: Boolean;
begin
  Title := FoldCase(Candidate.Title);
  Url := FoldCase(Candidate.Url);
  Tags := TagsText(Candidate.Tags);
  Host := HostOfUrl(Candidate.Url);
  Boundary := True;
  for Index := 0 to High(Words) do
  begin
    InTitle := Pos(Words[Index], Title) > 0;
    InUrl := Pos(Words[Index], Url) > 0;
    InTags := Pos(Words[Index], Tags) > 0;
    if RestrictUrl in Restrictions then
    begin
      InTitle := False;
      InTags := False;
    end;
    if RestrictTitle in Restrictions then
    begin
      InUrl := False;
      InTags := False;
    end;
    if not (InTitle or InUrl or InTags) then
      Exit(False);
    if not (AtWordStart(Title, Words[Index]) or AtWordStart(Host, Words[Index]) or InTags) then
      Boundary := False;
  end;
  Result := True;
end;

function Allowed(constref Candidate: TSuggestionCandidate; Behaviour: TSuggestBehaviour;
  Restrictions: TSuggestRestrictions): Boolean;
begin
  case Behaviour of
    SuggestNothing:
      Exit(False);
    SuggestHistory:
      if Candidate.VisitCount = 0 then
        Exit(False);
    SuggestBookmarks:
      if not Candidate.Bookmarked then
        Exit(False);
  end;
  if (RestrictHistory in Restrictions) and (Candidate.VisitCount = 0) then
    Exit(False);
  if (RestrictBookmarks in Restrictions) and not Candidate.Bookmarked then
    Exit(False);
  if (RestrictTagged in Restrictions) and (Length(Candidate.Tags) = 0) then
    Exit(False);
  Result := True;
end;

function RankSuggestions(const Typed: string; const Candidates: TSuggestionCandidates; Now: Int64;
  Behaviour: TSuggestBehaviour; MaximumCount: Integer): TSuggestions;
var
  Words: TStringArray;
  Restrictions: TSuggestRestrictions;
  Index, Count, Place: Integer;
  Boundary: Boolean;
  Score: Double;
  Prefix: string;
  Item: TSuggestion;
begin
  Result := nil;
  ParseTyped(Typed, Words, Restrictions);
  if (Length(Words) = 0) and (Restrictions = []) then
    Exit;
  Prefix := StrippedAddress(Trim(Typed));
  SetLength(Result, Length(Candidates));
  Count := 0;
  for Index := 0 to High(Candidates) do
  begin
    if not Allowed(Candidates[Index], Behaviour, Restrictions) then
      Continue;
    if not Matches(Candidates[Index], Words, Restrictions, Boundary) then
      Continue;
    Score := Frecency(Candidates[Index].VisitCount, Candidates[Index].LastVisit, Now, Candidates[Index].Bookmarked);
    if Score <= 0 then
      Score := 1;
    if Boundary then
      Score := Score * BoundaryFactor;
    if (Restrictions = []) and (Prefix <> '') and (Pos(Prefix, StrippedAddress(Candidates[Index].Url)) = 1) then
      Score := Score * PrefixFactor;
    Item.Title := Candidates[Index].Title;
    Item.Url := Candidates[Index].Url;
    Item.Tags := Candidates[Index].Tags;
    Item.Bookmarked := Candidates[Index].Bookmarked;
    Item.Score := Score;
    { Insert in order: higher scores first, equal ones in the order met
      (the history's newest first). }
    Place := Count;
    while (Place > 0) and (Result[Place - 1].Score < Score) do
    begin
      Result[Place] := Result[Place - 1];
      Dec(Place);
    end;
    Result[Place] := Item;
    Inc(Count);
  end;
  if Count > MaximumCount then
    Count := MaximumCount;
  SetLength(Result, Count);
end;

function GatherCandidates(History: THistoryStore; Bookmarks: TBookmarkStore): TSuggestionCandidates;
var
  Places: THistoryPlaceList;
  Marks: TBookmarkNodeList;
  Index, Found, Count: Integer;
  Known: TStringList;
begin
  Result := nil;
  Places := nil;
  Marks := nil;
  if History <> nil then
    Places := History.Places;
  if Bookmarks <> nil then
    Marks := Bookmarks.AllBookmarks;
  SetLength(Result, Length(Places) + Length(Marks));
  Count := 0;
  Known := TStringList.Create;
  try
    Known.Sorted := True;
    Known.CaseSensitive := True;
    for Index := 0 to High(Places) do
    begin
      Result[Count].Title := Places[Index].Title;
      Result[Count].Url := Places[Index].Url;
      Result[Count].Tags := nil;
      Result[Count].Bookmarked := False;
      Result[Count].VisitCount := Places[Index].VisitCount;
      Result[Count].LastVisit := Places[Index].LastVisit;
      Known.AddObject(Places[Index].Url, TObject(PtrInt(Count)));
      Inc(Count);
    end;
    for Index := 0 to High(Marks) do
    begin
      if Marks[Index].Url = '' then
        Continue;
      if Known.Find(Marks[Index].Url, Found) then
      begin
        Found := PtrInt(Known.Objects[Found]);
        Result[Found].Bookmarked := True;
        { The bookmark's name is the one the user gave. }
        if Marks[Index].Title <> '' then
          Result[Found].Title := Marks[Index].Title;
        Result[Found].Tags := Marks[Index].Tags;
        Continue;
      end;
      Result[Count].Title := Marks[Index].Title;
      Result[Count].Url := Marks[Index].Url;
      Result[Count].Tags := Marks[Index].Tags;
      Result[Count].Bookmarked := True;
      Result[Count].VisitCount := 0;
      Result[Count].LastVisit := 0;
      Known.AddObject(Marks[Index].Url, TObject(PtrInt(Count)));
      Inc(Count);
    end;
  finally
    Known.Free;
  end;
  SetLength(Result, Count);
end;

function SuggestPlaces(const Typed: string; History: THistoryStore; Bookmarks: TBookmarkStore; Now: Int64;
  Behaviour: TSuggestBehaviour; MaximumCount: Integer): TSuggestions;
begin
  if Behaviour = SuggestNothing then
    Exit(nil);
  Result := RankSuggestions(Typed, GatherCandidates(History, Bookmarks), Now, Behaviour, MaximumCount);
end;

end.
