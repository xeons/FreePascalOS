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

  A menu bar (File, Help), a toolbar, a tab control with four pages
  (a list box and a combo box; a multi-line edit box; a tree view; a
  list view) and a status bar; Ctrl+M asks a question in a message box,
  Help > About shows one. Prints what happens, a line each:

    place NAME X Y        where NAME is on the screen (pixels), at start
    menu TEXT             a menu item was chosen
    toolbar TEXT 0|1      a tool button (and whether it is down)
    page N                the tab control shows page N
    list TEXT             the list box's choice
    combo TEXT            the combo box's choice
    edit LINES            the multi-line edit box changed (its line count)
    tree TEXT             the tree view's choice
    row TEXT              the list view's choice
    column N              a list view column header was clicked
    answer N              a message box's result
  File > Exit ends it.
}
program ControlsTour;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Format,
  Sys.Streams,
  Drawing.Rectangles,
  Windowing.Protocol,
  Windowing.Connection,
  Windowing.Windows,
  Controls.Keys,
  Controls.Base,
  Controls.Window,
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
  Controls.MessageBoxes;

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
    FTree: TTreeView;
    FDetails: TListView;
    FStatus: TStatusBar;
    procedure MenuChosen(Item: TMenuItem);
    procedure ExitChosen(Item: TMenuItem);
    procedure AboutChosen(Item: TMenuItem);
    procedure ToolClicked(Sender: TControl);
    procedure ChildNotified(Sender: TControl; Child: TControl; Code: LongWord);
    procedure ColumnClicked(Sender: TListView; Column: LongInt);
    procedure AskQuestion(Sender: TControlWindow);
    procedure BuildPages;
    procedure TellPlace(const Name: string; Control: TControl; X, Y: LongInt);
  public
    constructor Create;
    procedure TellPlaces;
  end;

procedure Say(const Text: string);
begin
  WriteFormatted(StandardOutput, '%s'#10, [ArgumentText(PChar(Text))]);
  FlushStream(StandardOutput);
end;

constructor TTourWindow.Create;
var
  FileMenu: TMenuItem;
  HelpMenu: TMenuItem;
begin
  inherited Create('Controls tour', 60, 40, 480, 360);
  FMenuBar := TMenuBar.Create(Root);
  FileMenu := FMenuBar.Menu.Add('File');
  FileMenu.Add('New', nil, 'Ctrl+N');
  FileMenu.Add('Open...', nil, 'Ctrl+O');
  FileMenu.AddSeparator;
  FileMenu.Add('Recent').Add('notes.txt');
  FileMenu.AddSeparator;
  FileMenu.Add('Exit', @ExitChosen);
  HelpMenu := FMenuBar.Menu.Add('Help');
  HelpMenu.Add('About', @AboutChosen);
  FMenuBar.OnChoose := @MenuChosen;
  FToolBar := TToolBar.Create(Root);
  FToolBar.AddButton('New', 40, @ToolClicked);
  FToolBar.AddButton('Open', 44, @ToolClicked);
  FToolBar.AddSeparator;
  FBold := FToolBar.AddButton('Bold', 40, @ToolClicked);
  FBold.IsToggle := True;
  FStatus := TStatusBar.Create(Root);
  FStatus.PanelText[0] := 'Ready';
  FTabs := TTabControl.Create(Root);
  FTabs.Align := AlignClient;
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
  Page := FTabs.AddPage('Lists');
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
  Page := FTabs.AddPage('Text');
  Page.OnNotify := @ChildNotified;
  FEdit := TTextEdit.Create(Page);
  FEdit.SetBounds(8, 8, 300, 150);
  FEdit.SetAllText('Lines of text'#10'to edit'#10'here');
  Page := FTabs.AddPage('Tree');
  Page.OnNotify := @ChildNotified;
  FTree := TTreeView.Create(Page);
  FTree.SetBounds(8, 8, 220, 180);
  Node := FTree.AddRoot('System');
  Node.Add('bin');
  Node.Add('lib').Add('fonts');
  Node.Add('etc');
  Node.Expanded := True;
  FTree.AddRoot('Home').Add('user');
  Page := FTabs.AddPage('Details');
  Page.OnNotify := @ChildNotified;
  FDetails := TListView.Create(Page);
  FDetails.SetBounds(8, 8, 360, 180);
  FDetails.AddColumn('Name', 120);
  FDetails.AddColumn('Size', 70);
  FDetails.AddColumn('Kind', 100);
  FDetails.AddRow(['notes.txt', '2 KiB', 'Text']);
  FDetails.AddRow(['picture.bmp', '300 KiB', 'Picture']);
  FDetails.AddRow(['tour', '40 KiB', 'Program']);
  FDetails.OnColumnClick := @ColumnClicked;
end;

procedure TTourWindow.TellPlace(const Name: string; Control: TControl; X, Y: LongInt);
begin
  Say(Format('place %s %d %d', [Name, Scaled(ScreenLeft) + Control.PixelBounds.Left + X,
    Scaled(ScreenTop) + Control.PixelBounds.Top + Y]));
end;

procedure TTourWindow.TellPlaces;
var
  RowHeight: LongInt;
begin
  { Places a test clicks: the Help heading, the Bold button, the tabs,
    the list box's third item, the combo box and its second item when
    dropped, the tree's first line, the list view's second row and its
    first column header. }
  TellPlace('help', FMenuBar, Scaled(50), RectangleHeight(FMenuBar.PixelBounds) div 2);
  TellPlace('bold', FBold, RectangleWidth(FBold.PixelBounds) div 2, RectangleHeight(FBold.PixelBounds) div 2);
  TellPlace('tree-tab', FTabs, Scaled(120), Scaled(8));
  TellPlace('details-tab', FTabs, Scaled(170), Scaled(8));
  RowHeight := FList.ItemHeight;
  TellPlace('list-item-3', FList, Scaled(30), 2 + 2 * RowHeight + RowHeight div 2);
  TellPlace('combo', FCombo, RectangleWidth(FCombo.PixelBounds) div 2, RectangleHeight(FCombo.PixelBounds) div 2);
  TellPlace('combo-second', FCombo, Scaled(30), RectangleHeight(FCombo.PixelBounds) + 2 + RowHeight + RowHeight div 2);
end;

procedure TTourWindow.MenuChosen(Item: TMenuItem);
begin
  Say('menu ' + Item.Text);
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

procedure TTourWindow.ColumnClicked(Sender: TListView; Column: LongInt);
begin
  Say('column ' + IntToStr(Column));
end;

procedure TTourWindow.ChildNotified(Sender: TControl; Child: TControl; Code: LongWord);
begin
  if Code <> NotifyChanged then
    Exit;
  if Child = FTabs then
  begin
    Say('page ' + IntToStr(FTabs.PageIndex));
    { Where the newly shown page's controls are. }
    if FTabs.PageIndex = 2 then
      TellPlace('tree-line-1', FTree, Scaled(40), FTree.RowMiddle(0));
    if FTabs.PageIndex = 3 then
    begin
      TellPlace('details-row-2', FDetails, Scaled(40), FDetails.RowMiddle(1));
      TellPlace('details-header-1', FDetails, Scaled(20), FDetails.HeaderMiddle);
    end;
  end
  else if (Child = FList) and (FList.ItemIndex >= 0) then
    Say('list ' + FList.Items[FList.ItemIndex])
  else if Child = FCombo then
    Say('combo ' + FCombo.Text)
  else if Child = FEdit then
    Say('edit ' + IntToStr(FEdit.Lines.Count))
  else if (Child = FTree) and (FTree.Selected <> nil) then
    Say('tree ' + FTree.Selected.Text)
  else if (Child = FDetails) and (FDetails.ItemIndex >= 0) then
    Say('row ' + FDetails.Cells[FDetails.ItemIndex, 0]);
end;

var
  Window: TTourWindow;
begin
  Window := TTourWindow.Create;
  Window.Show;
  Window.TellPlaces;
  RunMessageLoop;
end.
