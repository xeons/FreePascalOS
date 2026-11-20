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
  What the browser keeps in the user's settings folder
  (~/.settings/browser/): the history (history.txt, newest last: a
  line per visit with its Unix time, URL and title, tab-separated; at
  most 2000 visits) and the bookmarks (bookmarks.txt: title and URL,
  tab-separated, in order). Each is written whole when it changes.

  Plain logic over files, checked on the host (a folder given).
}
unit Browser.Stores;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Classes;

const
  MaximumHistoryEntries = 2000;

type
  THistoryEntry = record
    Time: Int64;
    Url: string;
    Title: string;
  end;

  THistoryStore = class
  private
    FPath: string;
    FEntries: array of THistoryEntry;
    FCount: Integer;
    function GetEntry(Index: Integer): THistoryEntry;
  public
    constructor Create(const Path: string);
    procedure Load;
    procedure Save;
    { A visit now (the same URL as the newest visit only renews it). }
    procedure AddVisit(const Url, Title: string; Time: Int64);
    { The newest visit of Url gets Title. }
    procedure SetTitle(const Url, Title: string);
    procedure Clear;
    property Count: Integer read FCount;
    { 0 is the oldest. }
    property Entries[Index: Integer]: THistoryEntry read GetEntry;
  end;

  TBookmark = record
    Title: string;
    Url: string;
  end;

  TBookmarkStore = class
  private
    FPath: string;
    FItems: array of TBookmark;
    function GetItem(Index: Integer): TBookmark;
    function GetCount: Integer;
  public
    constructor Create(const Path: string);
    procedure Load;
    procedure Save;
    function IndexOf(const Url: string): Integer;
    procedure Add(const Title, Url: string);
    procedure Delete(Index: Integer);
    property Count: Integer read GetCount;
    property Items[Index: Integer]: TBookmark read GetItem;
  end;

{ ~/.settings/browser (made if missing); /tmp/browser without a home. }
function BrowserProfileFolder: string;
{ Tabs and line breaks in a field become spaces. }
function CleanField(const Text: string): string;

implementation

uses
  Configuration.Locations;

function BrowserProfileFolder: string;
var
  Home: string;
begin
  Home := CurrentHome;
  if Home = '' then
    Result := '/tmp/browser'
  else
    Result := UserSettingsFolder(Home) + '/browser';
  ForceDirectories(Result);
end;

function CleanField(const Text: string): string;
var
  Index: Integer;
begin
  Result := Text;
  for Index := 1 to Length(Result) do
    if Result[Index] in [#9, #10, #13] then
      Result[Index] := ' ';
end;

function ReadLines(const Path: string): TStringList;
begin
  Result := TStringList.Create;
  if FileExists(Path) then
    try
      Result.LoadFromFile(Path);
    except
      Result.Clear;
    end;
end;

procedure WriteLines(Lines: TStringList; const Path: string);
begin
  try
    Lines.SaveToFile(Path);
  except
    { A history that cannot be kept is not worth stopping for. }
  end;
end;

{ ---- history ---- }

constructor THistoryStore.Create(const Path: string);
begin
  inherited Create;
  FPath := Path;
end;

function THistoryStore.GetEntry(Index: Integer): THistoryEntry;
begin
  Result := FEntries[Index];
end;

procedure THistoryStore.Load;
var
  Lines: TStringList;
  Index: Integer;
  Fields: TStringArray;
begin
  FEntries := nil;
  FCount := 0;
  Lines := ReadLines(FPath);
  try
    SetLength(FEntries, Lines.Count);
    for Index := 0 to Lines.Count - 1 do
    begin
      Fields := Lines[Index].Split([#9]);
      if Length(Fields) < 2 then
        Continue;
      FEntries[FCount].Time := StrToInt64Def(Fields[0], 0);
      FEntries[FCount].Url := Fields[1];
      if Length(Fields) > 2 then
        FEntries[FCount].Title := Fields[2]
      else
        FEntries[FCount].Title := '';
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
      Lines.Add(IntToStr(FEntries[Index].Time) + #9 + CleanField(FEntries[Index].Url) + #9 +
        CleanField(FEntries[Index].Title));
    WriteLines(Lines, FPath);
  finally
    Lines.Free;
  end;
end;

procedure THistoryStore.AddVisit(const Url, Title: string; Time: Int64);
begin
  if (FCount > 0) and (FEntries[FCount - 1].Url = Url) then
  begin
    FEntries[FCount - 1].Time := Time;
    if Title <> '' then
      FEntries[FCount - 1].Title := Title;
    Save;
    Exit;
  end;
  if FCount >= MaximumHistoryEntries then
  begin
    { The oldest tenth goes. }
    FEntries := Copy(FEntries, MaximumHistoryEntries div 10, FCount);
    FCount := FCount - MaximumHistoryEntries div 10;
  end;
  if FCount = Length(FEntries) then
    SetLength(FEntries, FCount * 2 + 16);
  FEntries[FCount].Time := Time;
  FEntries[FCount].Url := Url;
  FEntries[FCount].Title := Title;
  Inc(FCount);
  Save;
end;

procedure THistoryStore.SetTitle(const Url, Title: string);
var
  Index: Integer;
begin
  for Index := FCount - 1 downto 0 do
    if FEntries[Index].Url = Url then
    begin
      if FEntries[Index].Title <> Title then
      begin
        FEntries[Index].Title := Title;
        Save;
      end;
      Exit;
    end;
end;

procedure THistoryStore.Clear;
begin
  FEntries := nil;
  FCount := 0;
  Save;
end;

{ ---- bookmarks ---- }

constructor TBookmarkStore.Create(const Path: string);
begin
  inherited Create;
  FPath := Path;
end;

function TBookmarkStore.GetItem(Index: Integer): TBookmark;
begin
  Result := FItems[Index];
end;

function TBookmarkStore.GetCount: Integer;
begin
  Result := Length(FItems);
end;

procedure TBookmarkStore.Load;
var
  Lines: TStringList;
  Index: Integer;
  Fields: TStringArray;
begin
  FItems := nil;
  Lines := ReadLines(FPath);
  try
    for Index := 0 to Lines.Count - 1 do
    begin
      Fields := Lines[Index].Split([#9]);
      if Length(Fields) < 2 then
        Continue;
      SetLength(FItems, Length(FItems) + 1);
      FItems[High(FItems)].Title := Fields[0];
      FItems[High(FItems)].Url := Fields[1];
    end;
  finally
    Lines.Free;
  end;
end;

procedure TBookmarkStore.Save;
var
  Lines: TStringList;
  Index: Integer;
begin
  Lines := TStringList.Create;
  try
    for Index := 0 to High(FItems) do
      Lines.Add(CleanField(FItems[Index].Title) + #9 + CleanField(FItems[Index].Url));
    WriteLines(Lines, FPath);
  finally
    Lines.Free;
  end;
end;

function TBookmarkStore.IndexOf(const Url: string): Integer;
var
  Index: Integer;
begin
  for Index := 0 to High(FItems) do
    if FItems[Index].Url = Url then
      Exit(Index);
  Result := -1;
end;

procedure TBookmarkStore.Add(const Title, Url: string);
begin
  if IndexOf(Url) >= 0 then
    Exit;
  SetLength(FItems, Length(FItems) + 1);
  FItems[High(FItems)].Title := Title;
  FItems[High(FItems)].Url := Url;
  Save;
end;

procedure TBookmarkStore.Delete(Index: Integer);
var
  Position: Integer;
begin
  if (Index < 0) or (Index > High(FItems)) then
    Exit;
  for Position := Index to High(FItems) - 1 do
    FItems[Position] := FItems[Position + 1];
  SetLength(FItems, Length(FItems) - 1);
  Save;
end;

end.
