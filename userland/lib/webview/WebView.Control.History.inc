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

{ WebView.Control: the session history across processes.

  In a content process the view's history is three lists: the entries
  of the sites it left before (FBackEntries, the nearest last), the
  process's own session history (FRemoteEntries, all of one site, as
  its IpcHistoryState told it, FRemoteIndex the current one), and the
  entries it left going back (FForwardEntries, the nearest last). Going
  to an entry of the process's own history is the process's traversal
  (IpcGoToHistoryOffset); any other is a jump: the run of entries of
  the target's site around it goes to a view of that site's process
  (IpcRestoreHistory: the history becomes that run and the target is
  loaded), the rest become the back and forward lists. Session restore
  is such a jump. In the program the engine's history is all there is. }

const
  { Entries of sites left behind kept at most (the oldest go first). }
  CrossSiteHistoryLimit = 100;

procedure AppendHistoryEntry(var List: TWebHistoryList; constref Entry: TWebHistoryEntry);
begin
  SetLength(List, Length(List) + 1);
  List[High(List)] := Entry;
  if Length(List) > CrossSiteHistoryLimit then
    Delete(List, 0, Length(List) - CrossSiteHistoryLimit);
end;

procedure TWebView.CombinedHistory(out Entries: TWebHistoryList; out Current: Integer);
var
  Count, Index: Integer;
begin
  Entries := nil;
  Current := -1;
  if FEngine <> nil then
  begin
    Entries := FEngine.HistoryEntries;
    Current := FEngine.HistoryIndex;
    Exit;
  end;
  SetLength(Entries, Length(FBackEntries) + Length(FRemoteEntries) + Length(FForwardEntries));
  Count := 0;
  for Index := 0 to High(FBackEntries) do
  begin
    Entries[Count] := FBackEntries[Index];
    Inc(Count);
  end;
  for Index := 0 to High(FRemoteEntries) do
  begin
    Entries[Count] := FRemoteEntries[Index];
    Inc(Count);
  end;
  for Index := High(FForwardEntries) downto 0 do
  begin
    Entries[Count] := FForwardEntries[Index];
    Inc(Count);
  end;
  if (Length(FRemoteEntries) > 0) and (FRemoteIndex >= 0) then
    Current := Length(FBackEntries) + FRemoteIndex
  else if Length(FBackEntries) > 0 then
    Current := High(FBackEntries);
end;

function TWebView.HistoryEntries: TWebHistoryList;
var
  Current: Integer;
begin
  CombinedHistory(Result, Current);
end;

function TWebView.HistoryIndex: Integer;
var
  Entries: TWebHistoryList;
begin
  CombinedHistory(Entries, Result);
end;

{ The process's history goes with a view leaving its site: its entries
  up to the current one become back entries; a page that replaces the
  current one (NewEntry False) leaves its forward entries forward. }
procedure TWebView.LeaveSiteHistory(NewEntry: Boolean);
var
  Index: Integer;
begin
  if NewEntry then
    FForwardEntries := nil;
  if (Length(FRemoteEntries) = 0) or (FRemoteIndex < 0) or (FRemoteIndex > High(FRemoteEntries)) then
  begin
    FRemoteEntries := nil;
    FRemoteIndex := -1;
    Exit;
  end;
  for Index := 0 to FRemoteIndex - 1 do
    AppendHistoryEntry(FBackEntries, FRemoteEntries[Index]);
  if NewEntry then
    AppendHistoryEntry(FBackEntries, FRemoteEntries[FRemoteIndex])
  else
    for Index := High(FRemoteEntries) downto FRemoteIndex + 1 do
      AppendHistoryEntry(FForwardEntries, FRemoteEntries[Index]);
  FRemoteEntries := nil;
  FRemoteIndex := -1;
end;

procedure TWebView.JumpToHistoryEntry(const Entries: TWebHistoryList; Target: Integer);
var
  Site: string;
  First, Last, Index: Integer;
  State: TIpcHistoryState;
begin
  if (Target < 0) or (Target > High(Entries)) then
    Exit;
  if (FModel = ProcessModelInProcess) or RunsInProcess then
  begin
    EnsureEngine;
    FEngine.RestoreHistory(Entries, Target);
    Exit;
  end;
  { The run of the target's site around it. }
  Site := SiteOfText(Entries[Target].Url);
  First := Target;
  while (First > 0) and (SiteOfText(Entries[First - 1].Url) = Site) do
    Dec(First);
  Last := Target;
  while (Last < High(Entries)) and (SiteOfText(Entries[Last + 1].Url) = Site) do
    Inc(Last);
  if (FProcess = nil) or ((Site <> '') and (Site <> FProcess.Site)) then
    if not EnsureProcessFor(Site) then
    begin
      FBackEntries := nil;
      FForwardEntries := nil;
      EnsureEngine;
      FEngine.RestoreHistory(Entries, Target);
      Exit;
    end;
  FBackEntries := Copy(Entries, 0, First);
  FForwardEntries := nil;
  SetLength(FForwardEntries, High(Entries) - Last);
  for Index := 0 to High(FForwardEntries) do
    FForwardEntries[Index] := Entries[High(Entries) - Index];
  State := Default(TIpcHistoryState);
  SetLength(State.Entries, Last - First + 1);
  for Index := 0 to High(State.Entries) do
  begin
    State.Entries[Index].Url := Entries[First + Index].Url;
    State.Entries[Index].Title := Entries[First + Index].Title;
  end;
  State.Index := Target - First;
  SendToProcess(IpcRestoreHistory, EncodeHistoryState(State));
  { Until the process tells its history. }
  FRemoteEntries := Copy(Entries, First, Last - First + 1);
  FRemoteIndex := Target - First;
  TellHistory;
end;

procedure TWebView.GoToHistoryOffset(Offset: Integer);
var
  Entries: TWebHistoryList;
  Current, Target, RemoteFirst, RemoteLast: Integer;
begin
  if FEngine <> nil then
  begin
    FEngine.GoToHistoryOffset(Offset);
    Exit;
  end;
  if Offset = 0 then
    Exit;
  CombinedHistory(Entries, Current);
  if Current < 0 then
    Exit;
  Target := Current + Offset;
  if (Target < 0) or (Target > High(Entries)) then
    Exit;
  RemoteFirst := Length(FBackEntries);
  RemoteLast := RemoteFirst + High(FRemoteEntries);
  if (FProcess <> nil) and (Length(FRemoteEntries) > 0) and (Target >= RemoteFirst) and (Target <= RemoteLast) then
    SendToProcess(IpcGoToHistoryOffset, EncodeNumber(Offset))
  else
    JumpToHistoryEntry(Entries, Target);
end;

procedure TWebView.RestoreHistory(const Entries: TWebHistoryList; Index: Integer);
begin
  if Length(Entries) = 0 then
    Exit;
  if Index < 0 then
    Index := 0;
  if Index > High(Entries) then
    Index := High(Entries);
  FBackEntries := nil;
  FForwardEntries := nil;
  FRemoteEntries := nil;
  FRemoteIndex := -1;
  JumpToHistoryEntry(Entries, Index);
end;

procedure TWebView.TakeHistoryState(Message: TIpcMessage);
var
  State: TIpcHistoryState;
  Index: Integer;
begin
  State := DecodeHistoryState(Message.Payload);
  FRemoteCanGoBack := State.CanGoBack;
  FRemoteCanGoForward := State.CanGoForward;
  FRemoteEntries := nil;
  SetLength(FRemoteEntries, Length(State.Entries));
  for Index := 0 to High(State.Entries) do
  begin
    FRemoteEntries[Index].Url := State.Entries[Index].Url;
    FRemoteEntries[Index].Title := State.Entries[Index].Title;
  end;
  FRemoteIndex := State.Index;
  TellHistory;
end;
