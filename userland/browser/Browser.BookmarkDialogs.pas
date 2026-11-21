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
  Bookmark dialogs: Properties (name, location, tags, keyword and
  description of a bookmark; name and description of a folder), New
  Bookmark / New Folder (the same, making one), and Bookmark All Tabs
  (a new folder with a bookmark per tab, in a folder chosen).
}
unit Browser.BookmarkDialogs;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Windowing.Windows,
  Browser.Bookmarks;

function EditBookmarkProperties(Owner: TWindow; Node: TBookmarkNode): Boolean;
{ Makes a bookmark, folder or separator in Folder at Index (asking for
  the bookmark's or folder's details); nil if cancelled. }
function NewBookmarkNode(Owner: TWindow; Kind: TBookmarkKind; Folder: TBookmarkNode; Index: Integer;
  const Title, Url: string): TBookmarkNode;
procedure BookmarkTabsDialog(Owner: TWindow; const Urls, Titles: TStringArray);
{ Every folder (for a folder chooser), depth first, and their names
  indented by depth. }
function AllFolders(Store: TBookmarkStore; out Names: TStringArray): TBookmarkNodeList;

implementation

uses
  Controls.Base,
  Controls.Labels,
  Controls.EditBox,
  Controls.ComboBox,
  Controls.CommonDialogs,
  Browser.Application,
  Browser.Output;

const
  Width = 420;
  LabelWidth = 90;

type
  TPropertiesDialog = class(TCommonDialog)
  public
    NameEdit, LocationEdit, TagsEdit, KeywordEdit, DescriptionEdit: TEditBox;
    FolderBox: TComboBox;
    function AddRow(var Top: LongInt; const Caption: string): TEditBox;
  protected
    procedure Showing; override;
  end;

function TPropertiesDialog.AddRow(var Top: LongInt; const Caption: string): TEditBox;
var
  Text: TLabel;
begin
  Text := TLabel.Create(Root);
  Text.Text := Caption;
  Text.SetBounds(DialogMargin, Top + 3, LabelWidth, 18);
  Result := TEditBox.Create(Root);
  Result.SetBounds(DialogMargin + LabelWidth, Top, Width - 2 * DialogMargin - LabelWidth, 22);
  Result.Anchors := [akLeft, akTop, akRight];
  Inc(Top, 28);
end;

procedure TPropertiesDialog.Showing;
begin
  FocusControl(NameEdit);
  NameEdit.SelectAll;
  inherited Showing;
end;

function AllFolders(Store: TBookmarkStore; out Names: TStringArray): TBookmarkNodeList;
var
  List: TBookmarkNodeList;
  Labels: TStringArray;

  procedure Visit(Folder: TBookmarkNode; Depth: Integer);
  var
    Index: Integer;
  begin
    SetLength(List, Length(List) + 1);
    List[High(List)] := Folder;
    SetLength(Labels, Length(Labels) + 1);
    Labels[High(Labels)] := StringOfChar(' ', Depth * 4) + Folder.ShownTitle;
    for Index := 0 to Folder.Count - 1 do
      if Folder[Index].IsFolder then
        Visit(Folder[Index], Depth + 1);
  end;

var
  Index: Integer;
begin
  List := nil;
  Labels := nil;
  for Index := 0 to Store.Root.Count - 1 do
    Visit(Store.Root[Index], 0);
  Names := Labels;
  Result := List;
end;

function MakeDialog(Owner: TWindow; const Title: string; Kind: TBookmarkKind; Choosing: Boolean;
  out Folders: TBookmarkNodeList): TPropertiesDialog;
var
  Top, Index: LongInt;
  Names: TStringArray;
  Text: TLabel;
begin
  Folders := nil;
  Top := DialogMargin;
  Result := TPropertiesDialog.CreateDialog(Title, Width, 10, Owner);
  Result.NameEdit := Result.AddRow(Top, '&Name:');
  if Kind = BookmarkItem then
  begin
    Result.LocationEdit := Result.AddRow(Top, '&Location:');
    Result.TagsEdit := Result.AddRow(Top, '&Tags:');
    Result.TagsEdit.Placeholder := 'Separate tags with commas';
    Result.KeywordEdit := Result.AddRow(Top, '&Keyword:');
  end;
  Result.DescriptionEdit := Result.AddRow(Top, '&Description:');
  if Choosing then
  begin
    Text := TLabel.Create(Result.Root);
    Text.Text := '&Folder:';
    Text.SetBounds(DialogMargin, Top + 3, LabelWidth, 18);
    Result.FolderBox := TComboBox.Create(Result.Root);
    Result.FolderBox.SetBounds(DialogMargin + LabelWidth, Top, Width - 2 * DialogMargin - LabelWidth, 22);
    Folders := AllFolders(BrowserApp.Bookmarks, Names);
    for Index := 0 to High(Names) do
      Result.FolderBox.Items.Add(Names[Index]);
    Inc(Top, 28);
  end;
  Inc(Top, DialogMargin + DialogButtonHeight + DialogMargin);
  Result.SetClientSize(Width, Top);
  Result.AddOkAndCancel(Width, Top);
end;

function EditBookmarkProperties(Owner: TWindow; Node: TBookmarkNode): Boolean;
var
  Dialog: TPropertiesDialog;
  Folders: TBookmarkNodeList;
begin
  Result := False;
  if (Node = nil) or (Node.Kind = BookmarkSeparator) then
    Exit;
  Dialog := MakeDialog(Owner, 'Properties for "' + Node.ShownTitle + '"', Node.Kind, False, Folders);
  try
    Dialog.NameEdit.Text := Node.Title;
    Dialog.DescriptionEdit.Text := Node.Description;
    if Node.Kind = BookmarkItem then
    begin
      Dialog.LocationEdit.Text := Node.Url;
      Dialog.TagsEdit.Text := Node.TagText;
      Dialog.KeywordEdit.Text := Node.Keyword;
    end;
    Result := Dialog.Execute;
    if Result then
    begin
      Node.Title := Trim(Dialog.NameEdit.Text);
      Node.Description := Trim(Dialog.DescriptionEdit.Text);
      if Node.Kind = BookmarkItem then
      begin
        Node.Url := Trim(Dialog.LocationEdit.Text);
        Node.Keyword := Trim(Dialog.KeywordEdit.Text);
        Node.Tags := ParseTags(Dialog.TagsEdit.Text);
      end;
      BrowserApp.Bookmarks.Changed;
      Say('bookmark-edited ' + Node.Title);
    end;
  finally
    Dialog.Free;
  end;
end;

function NewBookmarkNode(Owner: TWindow; Kind: TBookmarkKind; Folder: TBookmarkNode; Index: Integer;
  const Title, Url: string): TBookmarkNode;
var
  Dialog: TPropertiesDialog;
  Folders: TBookmarkNodeList;
  Caption: string;
begin
  Result := nil;
  if Kind = BookmarkSeparator then
    Exit(BrowserApp.Bookmarks.AddSeparator(Folder, Index));
  if Kind = BookmarkFolder then
    Caption := 'New Folder'
  else
    Caption := 'New Bookmark';
  Dialog := MakeDialog(Owner, Caption, Kind, False, Folders);
  try
    Dialog.NameEdit.Text := Title;
    if Kind = BookmarkFolder then
      Dialog.NameEdit.Text := 'New Folder'
    else
      Dialog.LocationEdit.Text := Url;
    if not Dialog.Execute then
      Exit;
    if Kind = BookmarkFolder then
      Result := BrowserApp.Bookmarks.AddFolder(Folder, Trim(Dialog.NameEdit.Text), Index, BrowserApp.NowUnix)
    else
    begin
      BrowserApp.Bookmarks.BeginUpdate;
      try
        Result := BrowserApp.Bookmarks.AddBookmark(Folder, Trim(Dialog.NameEdit.Text), Trim(Dialog.LocationEdit.Text),
          Index, BrowserApp.NowUnix);
        Result.Keyword := Trim(Dialog.KeywordEdit.Text);
        Result.Tags := ParseTags(Dialog.TagsEdit.Text);
        Result.Description := Trim(Dialog.DescriptionEdit.Text);
        BrowserApp.Bookmarks.Changed;
      finally
        BrowserApp.Bookmarks.EndUpdate;
      end;
    end;
    Say('bookmark-added ' + Result.ShownTitle);
  finally
    Dialog.Free;
  end;
end;

procedure BookmarkTabsDialog(Owner: TWindow; const Urls, Titles: TStringArray);
var
  Dialog: TPropertiesDialog;
  Folders: TBookmarkNodeList;
  Parent, Folder: TBookmarkNode;
  Index: Integer;
begin
  Dialog := MakeDialog(Owner, 'Bookmark All Tabs', BookmarkFolder, True, Folders);
  try
    Dialog.NameEdit.Text := '[Folder Name]';
    Dialog.FolderBox.ItemIndex := 1;
    if not Dialog.Execute then
      Exit;
    Parent := BrowserApp.Bookmarks.MenuFolder;
    if (Dialog.FolderBox.ItemIndex >= 0) and (Dialog.FolderBox.ItemIndex <= High(Folders)) then
      Parent := Folders[Dialog.FolderBox.ItemIndex];
    BrowserApp.Bookmarks.BeginUpdate;
    try
      Folder := BrowserApp.Bookmarks.AddFolder(Parent, Trim(Dialog.NameEdit.Text), -1, BrowserApp.NowUnix);
      Folder.Description := Trim(Dialog.DescriptionEdit.Text);
      for Index := 0 to High(Urls) do
        if (Urls[Index] <> '') and (Urls[Index] <> 'about:blank') then
          BrowserApp.Bookmarks.AddBookmark(Folder, Titles[Index], Urls[Index], -1, BrowserApp.NowUnix);
    finally
      BrowserApp.Bookmarks.EndUpdate;
    end;
    Say('bookmarked-tabs ' + IntToStr(Folder.Count));
  finally
    Dialog.Free;
  end;
end;

end.
