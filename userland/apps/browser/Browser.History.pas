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
  The browsing history (history.txt in the profile, oldest first: a
  line per visit with its Unix time, URL and title, tab-separated; at
  most MaximumHistoryVisits, the oldest tenth dropped when full).

  Besides the visits it answers what the Library, the History menu and
  the location bar ask: the pages visited (a place per URL with its
  visit count and last visit), newest first, matching words, since a
  time, and forgets a page, a site or everything since a time (Clear
  Recent History). While Enabled is False (private browsing, "never
  remember history") visits are not kept.

  Plain logic (the RTL only), checked on the host.
}
unit Browser.History;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Classes;

const
  MaximumHistoryVisits = 5000;

type
  THistoryVisit = record
    Time: Int64;
    Url: string;
    Title: string;
  end;

  { A page of the history: every visit of one URL. }
  THistoryPlace = record
    Url: string;
    Title: string;
    VisitCount: Integer;
    FirstVisit: Int64;
    LastVisit: Int64;
  end;
  THistoryPlaceList = array of THistoryPlace;

  { How old a visit is, as the Library's "By Date" view groups them. }
  THistoryAge = (AgeToday, AgeYesterday, AgeLastWeek, AgeThisMonth, AgeOlder);

  THistoryStore = class
  private
    FPath: string;
    FVisits: array of THistoryVisit;
    FCount: Integer;
    FEnabled: Boolean;
    FUpdating: Integer;
    FDirty: Boolean;
    FOnChanged: TNotifyEvent;
    function GetVisit(Index: Integer): THistoryVisit;
    procedure Changed;
    procedure Compact(const Keep: array of Boolean);
  public
    constructor Create(const Path: string);
    procedure Load;
    procedure Save;
    { Saves (and tells OnChanged) once, at the outermost EndUpdate. }
    procedure BeginUpdate;
    procedure EndUpdate;
    { A visit at Time (the same URL as the newest visit only renews it).
      Nothing while not Enabled. }
    procedure AddVisit(const Url, Title: string; Time: Int64);
    { The newest visit of Url gets Title. }
    procedure SetTitle(const Url, Title: string);
    procedure Clear;
    { Forgets every visit of Url. }
    procedure RemoveUrl(const Url: string);
    { Forgets every visit to Host (and its subdomains): "Forget About
      This Site". }
    procedure RemoveHost(const Host: string);
    { Forgets the visits at or after Time. }
    procedure RemoveSince(Time: Int64);
    { The pages visited, newest last visit first. }
    function Places: THistoryPlaceList;
    { Those whose title or URL holds every word of Text (case folded). }
    function Search(const Text: string): THistoryPlaceList;
    { Those last visited at or after Time. }
    function PlacesSince(Time: Int64): THistoryPlaceList;
    { The Count pages visited last (the History menu). }
    function RecentPlaces(MaximumCount: Integer): THistoryPlaceList;
    function FindPlace(const Url: string; out Place: THistoryPlace): Boolean;
    property Count: Integer read FCount;
    { 0 is the oldest. }
    property Visits[Index: Integer]: THistoryVisit read GetVisit;
    property Enabled: Boolean read FEnabled write FEnabled;
    property OnChanged: TNotifyEvent read FOnChanged write FOnChanged;
  end;

{ Which group a visit at Time falls in, seen at Now (Unix times, local
  days counted from Now's midnight: OffsetSeconds is the local time's
  offset from UTC). }
function HistoryAgeOf(Time, Now: Int64; OffsetSeconds: Int64 = 0): THistoryAge;
function HistoryAgeName(Age: THistoryAge): string;
{ The host of a URL ("" when it has none), lowered. }
function HostOfUrl(const Url: string): string;
{ Whether every word of Words is in Text (both case folded). }
function MatchesAllWords(const Text: string; const Words: TStringArray): Boolean;
{ Text split at spaces, case folded, empty words dropped. }
function SplitWords(const Text: string): TStringArray;

implementation

uses
  Browser.TextFiles;

const
  SecondsPerDay = 86400;

function SplitWords(const Text: string): TStringArray;
var
  Parts: TStringArray;
  Index: Integer;
begin
  Result := nil;
  Parts := FoldCase(Text).Split([' ', #9]);
  for Index := 0 to High(Parts) do
    if Parts[Index] <> '' then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := Parts[Index];
    end;
end;

function MatchesAllWords(const Text: string; const Words: TStringArray): Boolean;
var
  Folded: string;
  Index: Integer;
begin
  Folded := FoldCase(Text);
  for Index := 0 to High(Words) do
    if Pos(Words[Index], Folded) = 0 then
      Exit(False);
  Result := True;
end;

function HostOfUrl(const Url: string): string;
var
  Start, Finish: Integer;
begin
  Result := '';
  Start := Pos('://', Url);
  if Start = 0 then
    Exit;
  Inc(Start, 3);
  Finish := Start;
  while (Finish <= Length(Url)) and not (Url[Finish] in ['/', '?', '#']) do
    Inc(Finish);
  Result := FoldCase(Copy(Url, Start, Finish - Start));
  { Without credentials or a port. }
  if Pos('@', Result) > 0 then
    Result := Copy(Result, Pos('@', Result) + 1, MaxInt);
  if (Result <> '') and (Result[1] <> '[') and (Pos(':', Result) > 0) then
    Result := Copy(Result, 1, Pos(':', Result) - 1);
end;

function HistoryAgeOf(Time, Now: Int64; OffsetSeconds: Int64): THistoryAge;
var
  Midnight, Local: Int64;
begin
  Local := Now + OffsetSeconds;
  Midnight := Local - (Local mod SecondsPerDay) - OffsetSeconds;
  if Time >= Midnight then
    Result := AgeToday
  else if Time >= Midnight - SecondsPerDay then
    Result := AgeYesterday
  else if Time >= Midnight - 7 * SecondsPerDay then
    Result := AgeLastWeek
  else if Time >= Midnight - 31 * SecondsPerDay then
    Result := AgeThisMonth
  else
    Result := AgeOlder;
end;

function HistoryAgeName(Age: THistoryAge): string;
begin
  case Age of
    AgeToday: Result := 'Today';
    AgeYesterday: Result := 'Yesterday';
    AgeLastWeek: Result := 'Last 7 days';
    AgeThisMonth: Result := 'This month';
  else
    Result := 'Older than a month';
  end;
end;

constructor THistoryStore.Create(const Path: string);
begin
  inherited Create;
  FPath := Path;
  FEnabled := True;
end;

function THistoryStore.GetVisit(Index: Integer): THistoryVisit;
begin
  Result := FVisits[Index];
end;

procedure THistoryStore.Load;
var
  Lines: TStringList;
  Index: Integer;
  Fields: TStringArray;
begin
  FVisits := nil;
  FCount := 0;
  Lines := ReadLines(FPath);
  try
    SetLength(FVisits, Lines.Count);
    for Index := 0 to Lines.Count - 1 do
    begin
      Fields := Lines[Index].Split([#9]);
      if (Length(Fields) < 2) or (Fields[1] = '') then
        Continue;
      FVisits[FCount].Time := StrToInt64Def(Fields[0], 0);
      FVisits[FCount].Url := Fields[1];
      FVisits[FCount].Title := FieldAt(Fields, 2);
      Inc(FCount);
    end;
  finally
    Lines.Free;
  end;
end;

procedure THistoryStore.Save;
var
  Lines: TStringList;
  Index: Integer;
begin
  Lines := TStringList.Create;
  try
    for Index := 0 to FCount - 1 do
      Lines.Add(JoinFields([IntToStr(FVisits[Index].Time), FVisits[Index].Url, FVisits[Index].Title]));
    WriteLines(Lines, FPath);
  finally
    Lines.Free;
  end;
end;

procedure THistoryStore.BeginUpdate;
begin
  Inc(FUpdating);
end;

procedure THistoryStore.EndUpdate;
begin
  Dec(FUpdating);
  if (FUpdating = 0) and FDirty then
    Changed;
end;

procedure THistoryStore.Changed;
begin
  if FUpdating > 0 then
  begin
    FDirty := True;
    Exit;
  end;
  FDirty := False;
  Save;
  if Assigned(FOnChanged) then
    FOnChanged(Self);
end;

procedure THistoryStore.AddVisit(const Url, Title: string; Time: Int64);
var
  Dropped: Integer;
begin
  if not FEnabled or (Url = '') then
    Exit;
  if (FCount > 0) and (FVisits[FCount - 1].Url = Url) then
  begin
    FVisits[FCount - 1].Time := Time;
    if Title <> '' then
      FVisits[FCount - 1].Title := Title;
    Changed;
    Exit;
  end;
  if FCount >= MaximumHistoryVisits then
  begin
    Dropped := MaximumHistoryVisits div 10;
    FVisits := Copy(FVisits, Dropped, FCount - Dropped);
    FCount := FCount - Dropped;
  end;
  if FCount >= Length(FVisits) then
    SetLength(FVisits, FCount * 2 + 16);
  FVisits[FCount].Time := Time;
  FVisits[FCount].Url := Url;
  FVisits[FCount].Title := Title;
  Inc(FCount);
  Changed;
end;

procedure THistoryStore.SetTitle(const Url, Title: string);
var
  Index: Integer;
begin
  if not FEnabled then
    Exit;
  for Index := FCount - 1 downto 0 do
    if FVisits[Index].Url = Url then
    begin
      if FVisits[Index].Title <> Title then
      begin
        FVisits[Index].Title := Title;
        Changed;
      end;
      Exit;
    end;
end;

procedure THistoryStore.Clear;
begin
  FVisits := nil;
  FCount := 0;
  Changed;
end;

procedure THistoryStore.Compact(const Keep: array of Boolean);
var
  Index, Kept: Integer;
begin
  Kept := 0;
  for Index := 0 to FCount - 1 do
    if Keep[Index] then
    begin
      FVisits[Kept] := FVisits[Index];
      Inc(Kept);
    end;
  if Kept <> FCount then
  begin
    FCount := Kept;
    SetLength(FVisits, Kept);
    Changed;
  end;
end;

procedure THistoryStore.RemoveUrl(const Url: string);
var
  Keep: array of Boolean;
  Index: Integer;
begin
  Keep := nil;
  SetLength(Keep, FCount);
  for Index := 0 to FCount - 1 do
    Keep[Index] := FVisits[Index].Url <> Url;
  Compact(Keep);
end;

procedure THistoryStore.RemoveHost(const Host: string);
var
  Keep: array of Boolean;
  Index: Integer;
  Lowered, VisitHost: string;
begin
  Lowered := FoldCase(Host);
  Keep := nil;
  SetLength(Keep, FCount);
  for Index := 0 to FCount - 1 do
  begin
    VisitHost := HostOfUrl(FVisits[Index].Url);
    Keep[Index] := not ((VisitHost = Lowered) or
      ((Length(VisitHost) > Length(Lowered)) and
       (Copy(VisitHost, Length(VisitHost) - Length(Lowered), MaxInt) = '.' + Lowered)));
  end;
  Compact(Keep);
end;

procedure THistoryStore.RemoveSince(Time: Int64);
var
  Keep: array of Boolean;
  Index: Integer;
begin
  Keep := nil;
  SetLength(Keep, FCount);
  for Index := 0 to FCount - 1 do
    Keep[Index] := FVisits[Index].Time < Time;
  Compact(Keep);
end;

function THistoryStore.Places: THistoryPlaceList;
var
  Seen: TStringList;
  Index, Found, Total: Integer;
  Visit: THistoryVisit;
begin
  Result := nil;
  Seen := TStringList.Create;
  try
    Seen.Sorted := True;
    Seen.CaseSensitive := True;
    SetLength(Result, FCount);
    Total := 0;
    { Newest first: the first visit seen of a URL is its last. }
    for Index := FCount - 1 downto 0 do
    begin
      Visit := FVisits[Index];
      if Seen.Find(Visit.Url, Found) then
      begin
        Found := PtrInt(Seen.Objects[Found]);
        Inc(Result[Found].VisitCount);
        Result[Found].FirstVisit := Visit.Time;
        if Result[Found].Title = '' then
          Result[Found].Title := Visit.Title;
      end
      else
      begin
        Seen.AddObject(Visit.Url, TObject(PtrInt(Total)));
        Result[Total].Url := Visit.Url;
        Result[Total].Title := Visit.Title;
        Result[Total].VisitCount := 1;
        Result[Total].FirstVisit := Visit.Time;
        Result[Total].LastVisit := Visit.Time;
        Inc(Total);
      end;
    end;
    SetLength(Result, Total);
  finally
    Seen.Free;
  end;
end;

function THistoryStore.Search(const Text: string): THistoryPlaceList;
var
  All: THistoryPlaceList;
  Words: TStringArray;
  Index, Total: Integer;
begin
  All := Places;
  Words := SplitWords(Text);
  Result := nil;
  SetLength(Result, Length(All));
  Total := 0;
  for Index := 0 to High(All) do
    if MatchesAllWords(All[Index].Title + ' ' + All[Index].Url, Words) then
    begin
      Result[Total] := All[Index];
      Inc(Total);
    end;
  SetLength(Result, Total);
end;

function THistoryStore.PlacesSince(Time: Int64): THistoryPlaceList;
var
  All: THistoryPlaceList;
  Index, Total: Integer;
begin
  All := Places;
  Result := nil;
  SetLength(Result, Length(All));
  Total := 0;
  for Index := 0 to High(All) do
    if All[Index].LastVisit >= Time then
    begin
      Result[Total] := All[Index];
      Inc(Total);
    end;
  SetLength(Result, Total);
end;

function THistoryStore.RecentPlaces(MaximumCount: Integer): THistoryPlaceList;
begin
  Result := Places;
  if Length(Result) > MaximumCount then
    SetLength(Result, MaximumCount);
end;

function THistoryStore.FindPlace(const Url: string; out Place: THistoryPlace): Boolean;
var
  Index: Integer;
begin
  Result := False;
  Place := Default(THistoryPlace);
  for Index := FCount - 1 downto 0 do
    if FVisits[Index].Url = Url then
    begin
      if not Result then
      begin
        Place.Url := Url;
        Place.Title := FVisits[Index].Title;
        Place.LastVisit := FVisits[Index].Time;
        Result := True;
      end;
      Inc(Place.VisitCount);
      Place.FirstVisit := FVisits[Index].Time;
    end;
end;

end.
