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
  controlstour - the rest of libcontrols in one window, for trying and
  testing them

  controlstour

  A menu bar (File, Help), a toolbar, a tab control with five pages
  (a list box and a combo box; a multi-line edit box and two edit boxes
  to copy and paste between; a tree view; a list view, several items
  selectable and sorted by a header click, with buttons for its views;
  pictures: an animated picture box, a paint box moved on by a timer,
  an image list in a toolbar and a list view, Tour.Pictures) and a
  status bar; controls have hints (tooltips); Ctrl+M asks a question in a message box, Help >
  About shows one. Menus, items and tabs have mnemonics (Alt+H opens
  Help; F10 or Alt alone picks the menu bar). Prints what happens, a
  line each:

    place NAME X Y        where NAME is on the screen (pixels), at start
    menu TEXT             a menu item was chosen
    toolbar TEXT 0|1      a tool button (and whether it is down)
    page N                the tab control shows page N
    list TEXT             the list box's choice
    combo TEXT            the combo box's choice
    edit LINES            the multi-line edit box changed (its line count)
    pasted TEXT           the second edit box changed (its text)
    tree TEXT             the tree view's choice
    row TEXT              the list view's focused item
    selected A,B,...      the list view's selected items
    column N              a list view column header was clicked
    order A,B,...         the list view's items, after sorting
    view N                the list view's view (0 details to 3 large icons)
    answer N              a message box's result
    hint TEXT             a tooltip was shown (its lines joined by " / ")
  and what the Pictures page prints (Tour.Pictures). File > Exit ends it.
}
program ControlsTour;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  Abi.SystemCalls,
  Drawing.Rectangles,
  Windowing.Protocol,
  Windowing.Connection,
  Windowing.Windows,
  Controls.Keys,
  Controls.Base,
  Controls.Window,
  Controls.Buttons,
  Controls.EditBox,
  Controls.StatusBar,
  Controls.ListBox,
  Controls.ComboBox,
  Controls.TextEdit,
  Controls.Menus,
  Controls.ToolBar,
  Controls.TabControl,
  Controls.TreeView,
  Controls.ListView,
  Controls.Dialogs,
  Controls.MessageBoxes,
  Controls.ImageList,
  Controls.Text,
  Tour.Artwork,
  Tour.Output,
  Tour.Pictures;

const
  KeyM = $32;

type
  TTourWindow = class(TControlWindow)
  private
    FMenuBar: TMenuBar;
    FToolBar: TToolBar;
    FBold: TToolButton;
    FTabs: TTabControl;
    FList: TListBox;
    FCombo: TComboBox;
    FEdit: TTextEdit;
    FCopyBox: TEditBox;
    FPasteBox: TEditBox;
    FTree: TTreeView;
    FDetails: TListView;
    FLargeIconsButton: TButton;
    FStatus: TStatusBar;
    FImages: TImageList;
    FPictures: TPicturesPage;
    procedure HintShown(Sender: TControl; const Text: string);
    procedure MenuChosen(Item: TMenuItem);
    procedure ExitChosen(Item: TMenuItem);
    procedure AboutChosen(Item: TMenuItem);
    procedure ToolClicked(Sender: TControl);
    procedure ChildNotified(Sender: TControl; Child: TControl; Code: LongWord);
    procedure ColumnClicked(Sender: TListView; Column: LongInt);
    procedure ViewClicked(Sender: TControl);
    function DetailsTexts(SelectedOnly: Boolean): string;
    procedure AddViewButton(Page: TControl; const Caption: string; Mode: TListViewMode);
    procedure TellPagePlaces(Page: LongInt);
    procedure AskQuestion(Sender: TControlWindow);
    procedure BuildPages;
    procedure TellPlace(const Name: string; Control: TControl; X, Y: LongInt);
  public
    constructor Create;
    destructor Destroy; override;
    procedure TellPlaces;
  end;

constructor TTourWindow.Create;
var
  FileMenu: TMenuItem;
  HelpMenu: TMenuItem;
begin
  inherited Create('Controls tour', 60, 40, 480, 360);
  FImages := MakeTourImages;
  Hints.OnShown := @HintShown;
  FMenuBar := TMenuBar.Create(Root);
  FileMenu := FMenuBar.Menu.Add('&File');
  FileMenu.Add('&New', nil, 'Ctrl+N');
  FileMenu.Add('&Open...', nil, 'Ctrl+O');
  FileMenu.AddSeparator;
  FileMenu.Add('&Recent').Add('&notes.txt');
  FileMenu.AddSeparator;
  FileMenu.Add('E&xit', @ExitChosen);
  HelpMenu := FMenuBar.Menu.Add('&Help');
  HelpMenu.Images := FImages;
  HelpMenu.Add('&About', @AboutChosen).ImageIndex := PicturePicture;
  FMenuBar.OnChoose := @MenuChosen;
  FToolBar := TToolBar.Create(Root);
  FToolBar.AddButton('New', 40, @ToolClicked).Hint := 'Start a new document';
  FToolBar.AddButton('Open', 44, @ToolClicked).Hint := 'Open a document';
  FToolBar.AddSeparator;
  FBold := FToolBar.AddButton('Bold', 40, @ToolClicked);
  FBold.IsToggle := True;
  FBold.Hint := 'Bold'#10'Makes the text bold (stays down)';
  FStatus := TStatusBar.Create(Root);
  FStatus.PanelText[0] := 'Ready';
  FTabs := TTabControl.Create(Root);
  FTabs.Align := AlignClient;
  FTabs.Images := FImages;
  BuildPages;
  Root.OnNotify := @ChildNotified;
  AddAccelerator(KeyM, ModifierControl, @AskQuestion);
end;

procedure TTourWindow.BuildPages;
var
  Page: TControl;
  Node: TTreeNode;
  Index: LongInt;
begin
  Page := FTabs.AddPage('&Lists');
  Page.OnNotify := @ChildNotified;
  FList := TListBox.Create(Page);
  FList.SetBounds(8, 8, 160, 120);
  for Index := 1 to 20 do
    FList.Items.Add('Item ' + IntToStr(Index));
  FCombo := TComboBox.Create(Page);
  FCombo.SetBounds(184, 8, 160, 22);
  FCombo.Items.Add('First');
  FCombo.Items.Add('Second');
  FCombo.Items.Add('Third');
  FCombo.ItemIndex := 0;
  Page := FTabs.AddPage('&Text');
  Page.OnNotify := @ChildNotified;
  FEdit := TTextEdit.Create(Page);
  FEdit.SetBounds(8, 8, 300, 150);
  FEdit.SetAllText('Lines of text'#10'to edit'#10'here');
  FCopyBox := TEditBox.Create(Page);
  FCopyBox.SetBounds(8, 166, 140, 22);
  FCopyBox.Text := 'copy me';
  FPasteBox := TEditBox.Create(Page);
  FPasteBox.SetBounds(160, 166, 140, 22);
  Page := FTabs.AddPage('T&ree');
  Page.OnNotify := @ChildNotified;
  FTree := TTreeView.Create(Page);
  FTree.SetBounds(8, 8, 220, 180);
  Node := FTree.AddRoot('System');
  Node.Add('bin');
  Node.Add('lib').Add('fonts');
  Node.Add('etc');
  Node.Expanded := True;
  FTree.AddRoot('Home').Add('user');
  Page := FTabs.AddPage('&Details');
  Page.OnNotify := @ChildNotified;
  FDetails := TListView.Create(Page);
  FDetails.SetBounds(8, 8, 360, 180);
  FDetails.AddColumn('Name', 120);
  FDetails.AddColumn('Size', 70);
  FDetails.AddColumn('Kind', 100);
  FDetails.AddRow(['notes.txt', '2 KiB', 'Text']);
  FDetails.AddRow(['picture.bmp', '300 KiB', 'Picture']);
  FDetails.AddRow(['tour', '40 KiB', 'Program']);
  FDetails.MultiSelect := True;
  FDetails.SortOnHeaderClick := True;
  FDetails.ColumnNumeric[1] := True;
  FDetails.OnColumnClick := @ColumnClicked;
  AddViewButton(Page, 'Details', ViewDetails);
  AddViewButton(Page, 'List', ViewList);
  AddViewButton(Page, 'Small', ViewSmallIcons);
  AddViewButton(Page, 'Large', ViewLargeIcons);
  FPictures := TPicturesPage.Create(Self, FTabs, FImages);
  FPictures.Page.OnNotify := @ChildNotified;
end;

destructor TTourWindow.Destroy;
begin
  FPictures.Free;
  inherited Destroy;
  FImages.Free;
end;

procedure TTourWindow.HintShown(Sender: TControl; const Text: string);
begin
  Say('hint ' + StringReplace(Text, #10, ' / ', [rfReplaceAll]));
end;

procedure TTourWindow.AddViewButton(Page: TControl; const Caption: string; Mode: TListViewMode);
var
  Button: TButton;
begin
  Button := TButton.Create(Page);
  Button.SetBounds(8 + Ord(Mode) * 72, 196, 64, 22);
  Button.Text := Caption;
  Button.Tag := Ord(Mode);
  Button.OnClick := @ViewClicked;
  if Mode = ViewLargeIcons then
    FLargeIconsButton := Button;
end;

procedure TTourWindow.TellPlace(const Name: string; Control: TControl; X, Y: LongInt);
begin
  Tour.Output.TellPlace(Self, Name, Control, X, Y);
end;

procedure TTourWindow.TellPlaces;
var
  RowHeight: LongInt;
  Tab: TRectangle;
begin
  { Places a test clicks: the Help heading, the Bold button, the tabs,
    the list box's third item, the combo box and its second item when
    dropped, the tree's first line, the list view's second row and its
    first column header. }
  TellPlace('help', FMenuBar, Scaled(50), RectangleHeight(FMenuBar.PixelBounds) div 2);
  TellPlace('bold', FBold, RectangleWidth(FBold.PixelBounds) div 2, RectangleHeight(FBold.PixelBounds) div 2);
  TellPlace('text-tab', FTabs, Scaled(68), Scaled(8));
  TellPlace('tree-tab', FTabs, Scaled(120), Scaled(8));
  TellPlace('details-tab', FTabs, Scaled(170), Scaled(8));
  Tab := FTabs.TabBounds(4);
  TellPlace('pictures-tab', FTabs, (Tab.Left + Tab.Right) div 2, (Tab.Top + Tab.Bottom) div 2);
  RowHeight := FList.ItemHeight;
  TellPlace('list-item-3', FList, Scaled(30), 2 + 2 * RowHeight + RowHeight div 2);
  TellPlace('combo', FCombo, RectangleWidth(FCombo.PixelBounds) div 2, RectangleHeight(FCombo.PixelBounds) div 2);
  TellPlace('combo-second', FCombo, Scaled(30), RectangleHeight(FCombo.PixelBounds) + 2 + RowHeight + RowHeight div 2);
end;

procedure TTourWindow.MenuChosen(Item: TMenuItem);
begin
  Say('menu ' + Item.Caption);
end;

procedure TTourWindow.ExitChosen(Item: TMenuItem);
begin
  QuitMessageLoop(0);
end;

procedure TTourWindow.AboutChosen(Item: TMenuItem);
begin
  Say('answer ' + IntToStr(ShowMessageBox('About', 'Controls tour'#10'libcontrols on FreePascalOS', MessageOk,
    SignInformation, Self)));
end;

procedure TTourWindow.AskQuestion(Sender: TControlWindow);
begin
  Say('answer ' + IntToStr(ShowMessageBox('Question', 'Save the changes?', MessageYesNoCancel, SignQuestion,
    Self)));
end;

procedure TTourWindow.ToolClicked(Sender: TControl);
begin
  Say('toolbar ' + Sender.Text + ' ' + IntToStr(Ord(TToolButton(Sender).Down)));
end;

{ The list view's first column, every item or the selected ones, in
  order, with commas between. }
function TTourWindow.DetailsTexts(SelectedOnly: Boolean): string;
var
  Row: LongInt;
begin
  Result := '';
  for Row := 0 to FDetails.RowCount - 1 do
    if not SelectedOnly or FDetails.Selected[Row] then
    begin
      if Result <> '' then
        Result := Result + ',';
      Result := Result + FDetails.Cells[Row, 0];
    end;
end;

procedure TTourWindow.ColumnClicked(Sender: TListView; Column: LongInt);
begin
  Say('column ' + IntToStr(Column));
  Say('order ' + DetailsTexts(False));
end;

procedure TTourWindow.ViewClicked(Sender: TControl);
var
  Icon: TRectangle;
begin
  FDetails.ViewMode := TListViewMode(Sender.Tag);
  Say('view ' + IntToStr(Sender.Tag));
  { Where the first item's icon is now, to look at. }
  Icon := FDetails.IconBounds(0);
  if not RectangleIsEmpty(Icon) then
    TellPlace('details-icon-1', FDetails, (Icon.Left + Icon.Right) div 2, (Icon.Top + Icon.Bottom) div 2);
end;

{ Where the controls of a page just shown are. }
procedure TTourWindow.TellPagePlaces(Page: LongInt);
begin
  if Page = 1 then
  begin
    TellPlace('copy-box', FCopyBox, Scaled(30), RectangleHeight(FCopyBox.PixelBounds) div 2);
    TellPlace('paste-box', FPasteBox, Scaled(30), RectangleHeight(FPasteBox.PixelBounds) div 2);
    TellPlace('text-edit', FEdit, Scaled(60), Scaled(10));
  end;
  if Page = 2 then
    TellPlace('tree-line-1', FTree, Scaled(40), FTree.RowMiddle(0));
  if Page = 4 then
    FPictures.TellPlaces;
  if Page = 3 then
  begin
    TellPlace('details-row-1', FDetails, Scaled(40), FDetails.RowMiddle(0));
    TellPlace('details-row-2', FDetails, Scaled(40), FDetails.RowMiddle(1));
    TellPlace('details-row-3', FDetails, Scaled(40), FDetails.RowMiddle(2));
    TellPlace('details-header-1', FDetails, Scaled(20), FDetails.HeaderMiddle);
    TellPlace('details-header-2', FDetails, Scaled(140), FDetails.HeaderMiddle);
    TellPlace('large-icons', FLargeIconsButton, RectangleWidth(FLargeIconsButton.PixelBounds) div 2,
      RectangleHeight(FLargeIconsButton.PixelBounds) div 2);
  end;
end;

procedure TTourWindow.ChildNotified(Sender: TControl; Child: TControl; Code: LongWord);
begin
  if Code <> NotifyChanged then
    Exit;
  if Child = FTabs then
  begin
    Say('page ' + IntToStr(FTabs.PageIndex));
    TellPagePlaces(FTabs.PageIndex);
  end
  else if (Child = FList) and (FList.ItemIndex >= 0) then
    Say('list ' + FList.Items[FList.ItemIndex])
  else if Child = FCombo then
    Say('combo ' + FCombo.Text)
  else if Child = FEdit then
    Say('edit ' + IntToStr(FEdit.Lines.Count))
  else if Child = FPasteBox then
    Say('pasted ' + FPasteBox.Text)
  else if (Child = FTree) and (FTree.Selected <> nil) then
    Say('tree ' + FTree.Selected.Text)
  else if Child = FDetails then
  begin
    if FDetails.ItemIndex >= 0 then
      Say('row ' + FDetails.Cells[FDetails.ItemIndex, 0]);
    Say('selected ' + DetailsTexts(True));
  end;
end;

var
  Window: TTourWindow;
begin
  Window := TTourWindow.Create;
  Window.Show;
  Window.TellPlaces;
  RunMessageLoop;
end.
