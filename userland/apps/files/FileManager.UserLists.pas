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
  The user's lists, kept in the settings (group Files) so every window
  and the next run see them:

    Pinned        folders pinned to Home and the navigation pane, in
                  the user's order (the standard folders at first)
    Favorites     files starred
    Recent        files opened from the file manager, the latest first
                  (at most MostRecent)
    SearchHistory what was searched for, the latest first

  Every change is written at once; reading takes what is there now.
  Moved or renamed items are followed by RenameInLists.
}
unit FileManager.UserLists;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils;

type
  TUserList = (ListPinned, ListFavorites, ListRecent, ListSearchHistory);

const
  MostRecent = 40;
  MostSearches = 20;

function ReadUserList(List: TUserList): TStringArray;
procedure WriteUserList(List: TUserList; const Items: TStringArray);
function IsInUserList(List: TUserList; const Item: string): Boolean;
{ Adds Item (at the end, or for Recent and searches at the front, once). }
procedure AddToUserList(List: TUserList; const Item: string);
procedure RemoveFromUserList(List: TUserList; const Item: string);
procedure ClearUserList(List: TUserList);
{ Moves Item to Position in the list (pinned folders reordered). }
procedure MoveInUserList(List: TUserList; const Item: string; Position: LongInt);
{ A path renamed or moved: the lists follow it (and what was inside). }
procedure RenameInLists(const OldPath, NewPath: string);

implementation

uses
  Configuration.Settings,
  Configuration.Locations,
  FileManager.Paths,
  FileManager.Locations;

const
  ListKeys: array[TUserList] of string = ('Files/Pinned', 'Files/Favorites', 'Files/Recent', 'Files/SearchHistory');
  { Written once, so unpinning everything stays unpinned. }
  PinnedStartedKey = 'Files/PinnedStarted';

function StandardPins: TStringArray;
var
  Folder: TStandardFolder;
begin
  Result := nil;
  for Folder := Low(TStandardFolder) to High(TStandardFolder) do
  begin
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := StandardFolderPath(Folder);
  end;
end;

function ReadUserList(List: TUserList): TStringArray;
var
  Store: TSettings;
  Empty: TStringArray;
begin
  Store := OpenSettings;
  try
    Empty := nil;
    if (List = ListPinned) and not Store.ReadBoolean(PinnedStartedKey, False) then
      Result := StandardPins
    else
      Result := Store.ReadList(ListKeys[List], Empty);
  finally
    Store.Free;
  end;
end;

procedure WriteUserList(List: TUserList; const Items: TStringArray);
var
  Store: TSettings;
begin
  Store := OpenSettings;
  try
    Store.WriteList(ListKeys[List], Items);
    if List = ListPinned then
      Store.WriteBoolean(PinnedStartedKey, True);
  finally
    Store.Free;
  end;
end;

function IndexIn(const Items: TStringArray; const Item: string): LongInt;
var
  Index: LongInt;
begin
  for Index := 0 to High(Items) do
    if Items[Index] = Item then
      Exit(Index);
  Result := -1;
end;

function IsInUserList(List: TUserList; const Item: string): Boolean;
begin
  Result := IndexIn(ReadUserList(List), Item) >= 0;
end;

function Without(const Items: TStringArray; const Item: string): TStringArray;
var
  Each: string;
begin
  Result := nil;
  for Each in Items do
    if Each <> Item then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := Each;
    end;
end;

procedure AddToUserList(List: TUserList; const Item: string);
var
  Items: TStringArray;
  Index: LongInt;
  Most: LongInt;
begin
  if Trim(Item) = '' then
    Exit;
  Items := Without(ReadUserList(List), Item);
  if List in [ListRecent, ListSearchHistory] then
  begin
    SetLength(Items, Length(Items) + 1);
    for Index := High(Items) downto 1 do
      Items[Index] := Items[Index - 1];
    Items[0] := Item;
    if List = ListRecent then
      Most := MostRecent
    else
      Most := MostSearches;
    if Length(Items) > Most then
      SetLength(Items, Most);
  end
  else
  begin
    SetLength(Items, Length(Items) + 1);
    Items[High(Items)] := Item;
  end;
  WriteUserList(List, Items);
end;

procedure RemoveFromUserList(List: TUserList; const Item: string);
begin
  WriteUserList(List, Without(ReadUserList(List), Item));
end;

procedure ClearUserList(List: TUserList);
begin
  WriteUserList(List, nil);
end;

procedure MoveInUserList(List: TUserList; const Item: string; Position: LongInt);
var
  Items: TStringArray;
  Index: LongInt;
begin
  Items := Without(ReadUserList(List), Item);
  if Position < 0 then
    Position := 0;
  if Position > Length(Items) then
    Position := Length(Items);
  SetLength(Items, Length(Items) + 1);
  Index := High(Items);
  while Index > Position do
  begin
    Items[Index] := Items[Index - 1];
    Dec(Index);
  end;
  Items[Position] := Item;
  WriteUserList(List, Items);
end;

procedure RenameInLists(const OldPath, NewPath: string);
var
  List: TUserList;
  Items: TStringArray;
  Index: LongInt;
  Changed: Boolean;
begin
  for List := ListPinned to ListRecent do
  begin
    Items := ReadUserList(List);
    Changed := False;
    for Index := 0 to High(Items) do
      if IsSameOrInside(Items[Index], OldPath) then
      begin
        Items[Index] := NewPath + Copy(Items[Index], Length(OldPath) + 1, Length(Items[Index]));
        Changed := True;
      end;
    if Changed then
      WriteUserList(List, Items);
  end;
end;

end.
