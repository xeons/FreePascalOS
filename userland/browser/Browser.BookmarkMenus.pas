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
  Menus of bookmarks (the Bookmarks menu, a folder on the bookmarks
  toolbar, Recently Bookmarked): a folder's bookmarks, separators and
  folders (as submenus) in order, each folder ending with "Open All in
  Tabs". A bookmark item's Tag is its node's id; Open All in Tabs has
  the folder's id negated.
}
unit Browser.BookmarkMenus;

{$mode objfpc}
{$H+}

interface

uses
  Controls.Menus,
  Browser.Bookmarks;

{ Adds Folder's contents to Menu; Choose runs for every bookmark and
  for Open All in Tabs. }
procedure AddFolderItems(Menu: TMenuItem; Folder: TBookmarkNode; Choose: TMenuItemEvent; OpenAll: Boolean = True);
{ A menu caption: & doubled, cut to 60 characters. }
function MenuCaption(const Text: string): string;
{ Adds bookmarks as items (Recently Bookmarked, a tag's). }
procedure AddBookmarkItems(Menu: TMenuItem; const Nodes: TBookmarkNodeList; Choose: TMenuItemEvent);

implementation

uses
  SysUtils;

const
  MaximumCaptionLength = 60;

function MenuCaption(const Text: string): string;
begin
  Result := Text;
  if Length(Result) > MaximumCaptionLength then
    Result := Copy(Result, 1, MaximumCaptionLength - 3) + '...';
  Result := StringReplace(Result, '&', '&&', [rfReplaceAll]);
end;

procedure AddBookmarkItems(Menu: TMenuItem; const Nodes: TBookmarkNodeList; Choose: TMenuItemEvent);
var
  Index: Integer;
begin
  for Index := 0 to High(Nodes) do
    Menu.Add(MenuCaption(Nodes[Index].ShownTitle), Choose).Tag := Nodes[Index].Id;
end;

procedure AddFolderItems(Menu: TMenuItem; Folder: TBookmarkNode; Choose: TMenuItemEvent; OpenAll: Boolean);
var
  Index, Bookmarks: Integer;
  Node: TBookmarkNode;
  Sub: TMenuItem;
begin
  Bookmarks := 0;
  for Index := 0 to Folder.Count - 1 do
  begin
    Node := Folder[Index];
    case Node.Kind of
      BookmarkSeparator:
        Menu.AddSeparator;
      BookmarkFolder:
        begin
          Sub := Menu.Add(MenuCaption(Node.ShownTitle));
          AddFolderItems(Sub, Node, Choose);
          if Sub.Count = 0 then
            Sub.Add('(Empty)').Enabled := False;
        end;
      BookmarkItem:
        begin
          Menu.Add(MenuCaption(Node.ShownTitle), Choose).Tag := Node.Id;
          Inc(Bookmarks);
        end;
    end;
  end;
  if OpenAll and (Bookmarks > 1) then
  begin
    Menu.AddSeparator;
    Menu.Add('Open All in &Tabs', Choose).Tag := -Folder.Id;
  end;
end;

end.
