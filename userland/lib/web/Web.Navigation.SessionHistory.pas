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
  A navigable's session history (HTML Standard 7.4.1): its entries in
  order and the current one. An entry has the URL, the title shown in
  the history menus, a scroll position (the web view saves it before
  leaving and gets it back when returning), the document it belongs to
  (entries made by fragment navigation or pushState share one; going
  between them does not load anything) and a slot for the serialized
  state of history.pushState. Adding an entry drops the ones after the
  current one; the oldest go beyond MaximumEntries.
}
unit Web.Navigation.SessionHistory;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Classes,
  Url.Records;

const
  MaximumSessionHistoryEntries = 50;

type
  TSessionHistoryEntry = class
  public
    Url: TUrlRecord;
    Title: string;
    HasScrollPosition: Boolean;
    ScrollX, ScrollY: Double;
    { Entries of one document share it. }
    DocumentId: QWord;
    { history.pushState's serialized state (the bindings own it). }
    State: Pointer;
    function UrlText: string;
  end;

  TSessionHistory = class
  private
    FEntries: TList;
    FIndex: Integer;
    function GetEntry(Position: Integer): TSessionHistoryEntry;
    function GetCount: Integer;
  public
    constructor Create;
    destructor Destroy; override;
    { Adds Entry after the current one (dropping those after it); it
      becomes current. }
    procedure Push(Entry: TSessionHistoryEntry);
    { Entry takes the current one's place. }
    procedure ReplaceCurrent(Entry: TSessionHistoryEntry);
    function Current: TSessionHistoryEntry;
    function CanTraverse(Delta: Integer): Boolean;
    function CanGoBack: Boolean;
    function CanGoForward: Boolean;
    property Count: Integer read GetCount;
    property Index: Integer read FIndex write FIndex;
    property Entries[Position: Integer]: TSessionHistoryEntry read GetEntry; default;
  end;

implementation

function TSessionHistoryEntry.UrlText: string;
begin
  Result := SerializeUrl(Url);
end;

constructor TSessionHistory.Create;
begin
  inherited Create;
  FEntries := TList.Create;
  FIndex := -1;
end;

destructor TSessionHistory.Destroy;
var
  Position: Integer;
begin
  for Position := 0 to FEntries.Count - 1 do
    TSessionHistoryEntry(FEntries[Position]).Free;
  FEntries.Free;
  inherited Destroy;
end;

function TSessionHistory.GetEntry(Position: Integer): TSessionHistoryEntry;
begin
  Result := TSessionHistoryEntry(FEntries[Position]);
end;

function TSessionHistory.GetCount: Integer;
begin
  Result := FEntries.Count;
end;

procedure TSessionHistory.Push(Entry: TSessionHistoryEntry);
begin
  while FEntries.Count > FIndex + 1 do
  begin
    TSessionHistoryEntry(FEntries[FEntries.Count - 1]).Free;
    FEntries.Delete(FEntries.Count - 1);
  end;
  FEntries.Add(Entry);
  while FEntries.Count > MaximumSessionHistoryEntries do
  begin
    TSessionHistoryEntry(FEntries[0]).Free;
    FEntries.Delete(0);
  end;
  FIndex := FEntries.Count - 1;
end;

procedure TSessionHistory.ReplaceCurrent(Entry: TSessionHistoryEntry);
begin
  if FIndex < 0 then
  begin
    Push(Entry);
    Exit;
  end;
  TSessionHistoryEntry(FEntries[FIndex]).Free;
  FEntries[FIndex] := Entry;
end;

function TSessionHistory.Current: TSessionHistoryEntry;
begin
  if (FIndex < 0) or (FIndex >= FEntries.Count) then
    Exit(nil);
  Result := TSessionHistoryEntry(FEntries[FIndex]);
end;

function TSessionHistory.CanTraverse(Delta: Integer): Boolean;
begin
  Result := (Delta <> 0) and (FIndex + Delta >= 0) and (FIndex + Delta < FEntries.Count);
end;

function TSessionHistory.CanGoBack: Boolean;
begin
  Result := CanTraverse(-1);
end;

function TSessionHistory.CanGoForward: Boolean;
begin
  Result := CanTraverse(1);
end;

end.
