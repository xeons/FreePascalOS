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

{ WebView.Engine: the session history as a list (Back and Forward
  drop-downs, session restore), going several entries at once, and
  Page Info. }

function TWebEngineView.HistoryEntries: TWebHistoryList;
var
  History: TSessionHistory;
  Index: Integer;
begin
  Result := nil;
  if FPage = nil then
    Exit;
  History := FPage.Navigable.History;
  SetLength(Result, History.Count);
  for Index := 0 to History.Count - 1 do
  begin
    Result[Index].Url := History[Index].UrlText;
    Result[Index].Title := History[Index].Title;
  end;
end;

function TWebEngineView.HistoryIndex: Integer;
begin
  if FPage = nil then
    Result := -1
  else
    Result := FPage.Navigable.History.Index;
end;

procedure TWebEngineView.GoToHistoryOffset(Offset: Integer);
begin
  if (FPage = nil) or (Offset = 0) then
    Exit;
  FPage.Navigable.Traverse(Offset);
  PostWake;
end;

procedure TWebEngineView.RestoreHistory(const Entries: TWebHistoryList; Index: Integer);
var
  Restored: array of TSessionRestoreEntry;
  Count, Position: Integer;
begin
  Restored := nil;
  SetLength(Restored, Length(Entries));
  Count := 0;
  for Position := 0 to High(Entries) do
  begin
    if not ParseUrl(Entries[Position].Url, Restored[Count].Url) then
    begin
      { An entry that is not a URL is left out (the current one moves
        with the entries before it). }
      if Position < Index then
        Dec(Index);
      Continue;
    end;
    Restored[Count].Title := Entries[Position].Title;
    Inc(Count);
  end;
  SetLength(Restored, Count);
  if Count = 0 then
    Exit;
  if Index < 0 then
    Index := 0;
  if Index >= Count then
    Index := Count - 1;
  EnsurePage;
  FPage.Navigable.RestoreSession(Restored, Index);
  PostWake;
end;

function TWebEngineView.PageInfo: TWebPageInfo;
begin
  if (FLayout <> nil) and FLayout.NeedsUpdate then
    UpdateLayout(True);
  Result := CollectPageInfo(FDocument, FLayout);
  if Result.Url = '' then
    Result.Url := FUrl;
end;
