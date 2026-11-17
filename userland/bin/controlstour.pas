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
  layout without positions: a split container holding a flow panel of
  buttons that wrap, a form in a table and a panel that scrolls, over a
  bar whose button is anchored to the bottom right, so it follows the
  window's corner when the window is resized) and a status bar; Ctrl+M asks a question in a message box, Help >
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
    place anchored-apply X Y  the anchored button, when the layout page
                          is shown and whenever the window is resized
    answer N              a message box's result
  File > Exit ends it.
}
program ControlsTour;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Streams,
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
  Controls.Text,
  Controls.Labels,
  Controls.Toggles,
  Controls.Panels,
  Controls.FlowPanel,
  Controls.TablePanel,
  Controls.TableArrangement,
  Controls.SplitContainer,
  Controls.SplitRules,
  Controls.LayoutRules;

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
    FLayoutBar: TPanel;
    FAnchoredButton: TButton;
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
    procedure BuildLayoutPage;
    procedure BuildFlowAndForm(Area: TControl);
    procedure BuildScrollingPanel(Area: TControl);
    procedure LayoutBarResized(Sender: TControl);
    procedure TellPlace(const Name: string; Control: TControl; X, Y: LongInt);
  public
    constructor Create;
    procedure TellPlaces;
  end;

procedure Say(const Text: string);
begin
  PrintStringLine(Text);
  FlushStream(StandardOutput);
end;

constructor TTourWindow.Create;
var
  FileMenu: TMenuItem;
  HelpMenu: TMenuItem;
begin
  inherited Create('Controls tour', 60, 40, 480, 360);
  FMenuBar := TMenuBar.Create(Root);
  FileMenu := FMenuBar.Menu.Add('&File');
  FileMenu.Add('&New', nil, 'Ctrl+N');
  FileMenu.Add('&Open...', nil, 'Ctrl+O');
  FileMenu.AddSeparator;
  FileMenu.Add('&Recent').Add('&notes.txt');
  FileMenu.AddSeparator;
  FileMenu.Add('E&xit', @ExitChosen);
  HelpMenu := FMenuBar.Menu.Add('&Help');
  HelpMenu.Add('&About', @AboutChosen);
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
  BuildLayoutPage;
end;

{ No positions computed but the anchored button's, placed once from the
  bar's width: a split container fills the page above a bar docked to
  its bottom. }
procedure TTourWindow.BuildLayoutPage;
var
  Page: TControl;
  Note: TLabel;
  Split: TSplitContainer;
  BarWidth: LongInt;
begin
  Page := FTabs.AddPage('La&yout');
  Page.OnNotify := @ChildNotified;
  FLayoutBar := TPanel.Create(Page);
  FLayoutBar.SetBounds(0, 0, 0, 36);
  FLayoutBar.Align := AlignBottom;
  FLayoutBar.OnResize := @LayoutBarResized;
  Note := TLabel.Create(FLayoutBar);
  Note.ShowsMnemonic := False;
  Note.Text := 'Resize the window: the button keeps to the corner';
  Note.SetBounds(8, 9, 0, 0);
  Note.AutoSize := True;
  { The bar's width now (reading it lays the window out), for the button
    to be put at its right end; its anchors keep it there. }
  BarWidth := Unscaled(RectangleWidth(FLayoutBar.PixelBounds));
  FAnchoredButton := TButton.Create(FLayoutBar);
  FAnchoredButton.Text := 'Apply';
  FAnchoredButton.SetBounds(BarWidth - 8 - 75, 6, 75, 23);
  FAnchoredButton.Anchors := [akRight, akBottom];
  Split := TSplitContainer.Create(Page);
  Split.Align := AlignClient;
  Split.FixedPanel := FixedPanel1;
  Split.Panel1MinSize := 150;
  Split.Panel2MinSize := 100;
  Split.SplitterDistance := 270;
  BuildFlowAndForm(Split.Panel1);
  BuildScrollingPanel(Split.Panel2);
end;

{ Buttons in a row that wraps when the panel is narrow (sized to them),
  and a form in a table under them: captions as wide as the widest, the
  fields stretched across the rest. }
procedure TTourWindow.BuildFlowAndForm(Area: TControl);
const
  Captions: array[0..4] of string = ('One', 'Two', 'Three', 'Four', 'Five');
var
  Flow: TFlowLayoutPanel;
  Table: TTableLayoutPanel;
  Button: TButton;
  Caption: TLabel;
  Field: TEditBox;
  Choice: TComboBox;
  Remember: TCheckBox;
  Index: LongInt;
begin
  Flow := TFlowLayoutPanel.Create(Area);
  Flow.Align := AlignTop;
  Flow.AutoSize := True;
  Flow.ContentPadding := UniformSpacing(4);
  for Index := Low(Captions) to High(Captions) do
  begin
    Button := TButton.Create(Flow);
    Button.Text := Captions[Index];
    Button.AutoSize := True;
    Button.Margins := UniformSpacing(2);
  end;
  Table := TTableLayoutPanel.Create(Area);
  Table.Align := AlignClient;
  Table.ContentPadding := UniformSpacing(4);
  Table.AddColumn(TrackAutoSize);
  Table.AddColumn(TrackPercent, 100);
  Caption := TLabel.Create(Table);
  Caption.Text := '&Name:';
  Caption.AutoSize := True;
  Caption.Anchors := [akLeft];
  Caption.Margins := UniformSpacing(3);
  Field := TEditBox.Create(Table);
  Field.SetBounds(0, 0, 100, 22);
  Field.Anchors := [akLeft, akRight];
  Field.Margins := UniformSpacing(3);
  Caption := TLabel.Create(Table);
  Caption.Text := 'C&ity:';
  Caption.AutoSize := True;
  Caption.Anchors := [akLeft];
  Caption.Margins := UniformSpacing(3);
  Choice := TComboBox.Create(Table);
  Choice.SetBounds(0, 0, 100, 22);
  Choice.Anchors := [akLeft, akRight];
  Choice.Margins := UniformSpacing(3);
  Choice.Items.Add('Berlin');
  Choice.Items.Add('Lisbon');
  Choice.Items.Add('Oslo');
  Choice.ItemIndex := 0;
  Remember := TCheckBox.Create(Table);
  Remember.Text := 'Re&member these';
  Remember.AutoSize := True;
  Remember.Margins := UniformSpacing(3);
  Table.SetSpan(Remember, 2, 1);
end;

{ More options than fit: the panel scrolls (a control focused with Tab
  is scrolled into view). }
procedure TTourWindow.BuildScrollingPanel(Area: TControl);
var
  Scroller: TPanel;
  Heading: TLabel;
  Box: TCheckBox;
  Index: LongInt;
begin
  Heading := TLabel.Create(Area);
  Heading.ShowsMnemonic := False;
  Heading.Text := 'Options (scrolling):';
  Heading.SetBounds(0, 0, 0, 20);
  Heading.Align := AlignTop;
  Heading.Margins := MakeSpacing(4, 2, 4, 0);
  Scroller := TPanel.Create(Area);
  Scroller.Align := AlignClient;
  Scroller.AutoScroll := True;
  Scroller.ContentPadding := UniformSpacing(4);
  for Index := 1 to 14 do
  begin
    Box := TCheckBox.Create(Scroller);
    Box.Text := 'Option ' + IntToStr(Index);
    Box.SetBounds(0, (Index - 1) * 24, 0, 0);
    Box.AutoSize := True;
  end;
end;

procedure TTourWindow.LayoutBarResized(Sender: TControl);
begin
  if FTabs.PageIndex = 4 then
    TellPlace('anchored-apply', FAnchoredButton, RectangleWidth(FAnchoredButton.PixelBounds) div 2,
      RectangleHeight(FAnchoredButton.PixelBounds) div 2);
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
  Say(Format('place %s %d %d', [Name, Scaled(ScreenLeft) + Control.PixelBounds.Left + X,
    Scaled(ScreenTop) + Control.PixelBounds.Top + Y]));
end;

procedure TTourWindow.TellPlaces;
var
  RowHeight: LongInt;
  LayoutTab: TRectangle;
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
  LayoutTab := FTabs.TabBounds(4);
  TellPlace('layout-tab', FTabs, (LayoutTab.Left + LayoutTab.Right) div 2, (LayoutTab.Top + LayoutTab.Bottom) div 2);
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
  if Page = 4 then
    LayoutBarResized(FLayoutBar);
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
