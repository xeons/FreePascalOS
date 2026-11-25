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
  The panel that drops from the star in the location bar: "Page
  Bookmarked" (or "Edit This Bookmark"), the name, the folder, the tags,
  Remove Bookmark and Done. What was typed is kept when it closes (Done,
  Enter, or a click elsewhere); Escape and Remove Bookmark leave nothing
  changed or take the bookmark away.
}
unit Browser.BookmarkPanel;

{$mode objfpc}
{$H+}

interface

uses
  Controls.Base,
  Controls.Window,
  Browser.Bookmarks;

procedure ShowBookmarkPanel(Owner: TControlWindow; Anchor: TControl; Node: TBookmarkNode; IsNew: Boolean);

implementation

uses
  SysUtils,
  Drawing.Canvas,
  Drawing.Rectangles,
  Windowing.Theme,
  Windowing.Connection,
  Controls.Labels,
  Controls.EditBox,
  Controls.Buttons,
  Controls.ComboBox,
  Controls.Popups,
  Controls.Keys,
  Controls.Painting,
  Browser.BookmarkDialogs,
  Browser.Application,
  Browser.Output;

const
  PanelWidth = 340;
  PanelHeight = 168;

type
  TPanelFace = class(TControl)
  protected
    procedure Paint(var Canvas: TCanvas); override;
  end;

  TBookmarkPanel = class
  public
    Popup: TPopupWindow;
    NodeId: Integer;
    NameEdit, TagsEdit: TEditBox;
    FolderBox: TComboBox;
    Folders: TBookmarkNodeList;
    Removed: Boolean;
    procedure Keep;
    procedure Dismissed(Sender: TControl);
    procedure DoneClicked(Sender: TControl);
    procedure RemoveClicked(Sender: TControl);
    procedure EditKey(Sender: TControl; Code, Character, Modifiers: LongWord; var Handled: Boolean);
  end;

procedure TPanelFace.Paint(var Canvas: TCanvas);
var
  Box: TRectangle;
begin
  Box := MakeRectangle(0, 0, RectangleWidth(PixelBounds), RectangleHeight(PixelBounds));
  FillRectangle(Canvas, Box, Theme.Face);
  if Theme.HeaderBandsShown then
    DrawHeaderBand(Canvas, MakeRectangle(0, 0, Box.Right, Scaled(26)), BandHeader);
  DrawRaisedBevel(Canvas, Box);
end;

procedure TBookmarkPanel.Keep;
var
  Node: TBookmarkNode;
  Folder: TBookmarkNode;
begin
  Node := BrowserApp.Bookmarks.NodeById(NodeId);
  if (Node = nil) or Removed then
    Exit;
  BrowserApp.Bookmarks.BeginUpdate;
  try
    Node.Title := Trim(NameEdit.Text);
    Node.Tags := ParseTags(TagsEdit.Text);
    BrowserApp.Bookmarks.Changed;
    if (FolderBox.ItemIndex >= 0) and (FolderBox.ItemIndex <= High(Folders)) then
    begin
      Folder := Folders[FolderBox.ItemIndex];
      if Folder <> Node.Parent then
        BrowserApp.Bookmarks.Move(Node, Folder, -1);
    end;
  finally
    BrowserApp.Bookmarks.EndUpdate;
  end;
end;

procedure TBookmarkPanel.Dismissed(Sender: TControl);
begin
  Keep;
  Free;
end;

procedure TBookmarkPanel.DoneClicked(Sender: TControl);
begin
  Popup.Dismiss;
end;

procedure TBookmarkPanel.RemoveClicked(Sender: TControl);
var
  Node: TBookmarkNode;
begin
  Node := BrowserApp.Bookmarks.NodeById(NodeId);
  Removed := True;
  if Node <> nil then
  begin
    Say('unbookmarked ' + Node.Url);
    BrowserApp.Bookmarks.Delete(Node);
  end;
  Popup.Dismiss;
end;

procedure TBookmarkPanel.EditKey(Sender: TControl; Code, Character, Modifiers: LongWord; var Handled: Boolean);
begin
  if IsEnterKey(Code) then
  begin
    Handled := True;
    Popup.Dismiss;
  end;
end;

function AddLabelTo(Parent: TControl; const Text: string; Left, Top, Width: LongInt): TLabel;
begin
  Result := TLabel.Create(Parent);
  Result.Text := Text;
  Result.SetBounds(Left, Top, Width, 18);
end;

procedure ShowBookmarkPanel(Owner: TControlWindow; Anchor: TControl; Node: TBookmarkNode; IsNew: Boolean);
var
  Panel: TBookmarkPanel;
  Face: TPanelFace;
  Title: TLabel;
  Names: TStringArray;
  Index, Left, Top: LongInt;
  Button: TButton;
begin
  if Node = nil then
    Exit;
  Panel := TBookmarkPanel.Create;
  Panel.NodeId := Node.Id;
  Left := Owner.ScreenLeft + Unscaled(Anchor.PixelBounds.Right) - PanelWidth;
  Top := Owner.ScreenTop + Unscaled(Anchor.PixelBounds.Bottom);
  Panel.Popup := TPopupWindow.CreatePopup(Owner, Left, Top, PanelWidth, PanelHeight);
  Face := TPanelFace.Create(Panel.Popup.Root);
  Face.Align := AlignClient;
  Title := AddLabelTo(Face, '', 10, 5, PanelWidth - 20);
  if IsNew then
    Title.Text := 'Page Bookmarked'
  else
    Title.Text := 'Edit This Bookmark';
  AddLabelTo(Face, '&Name:', 10, 37, 60);
  Panel.NameEdit := TEditBox.Create(Face);
  Panel.NameEdit.SetBounds(70, 34, PanelWidth - 80, 22);
  Panel.NameEdit.Text := Node.Title;
  Panel.NameEdit.OnKeyDown := @Panel.EditKey;
  AddLabelTo(Face, '&Folder:', 10, 65, 60);
  Panel.FolderBox := TComboBox.Create(Face);
  Panel.FolderBox.SetBounds(70, 62, PanelWidth - 80, 22);
  Panel.Folders := AllFolders(BrowserApp.Bookmarks, Names);
  for Index := 0 to High(Names) do
  begin
    Panel.FolderBox.Items.Add(Names[Index]);
    if Panel.Folders[Index] = Node.Parent then
      Panel.FolderBox.ItemIndex := Index;
  end;
  AddLabelTo(Face, '&Tags:', 10, 93, 60);
  Panel.TagsEdit := TEditBox.Create(Face);
  Panel.TagsEdit.SetBounds(70, 90, PanelWidth - 80, 22);
  Panel.TagsEdit.Text := Node.TagText;
  Panel.TagsEdit.Placeholder := 'Separate tags with commas';
  Panel.TagsEdit.OnKeyDown := @Panel.EditKey;
  Button := TButton.Create(Face);
  Button.Text := '&Remove Bookmark';
  Button.SetBounds(10, PanelHeight - 34, 140, 24);
  Button.OnClick := @Panel.RemoveClicked;
  Button := TButton.Create(Face);
  Button.Text := '&Done';
  Button.SetBounds(PanelWidth - 90, PanelHeight - 34, 80, 24);
  Button.OnClick := @Panel.DoneClicked;
  Panel.Popup.OnDismiss := @Panel.Dismissed;
  Panel.Popup.Popup;
  Panel.Popup.FocusControl(Panel.NameEdit);
  Panel.NameEdit.SelectAll;
  Say('bookmark-panel ' + Title.Text);
end;

end.
