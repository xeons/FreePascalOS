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

  A menu bar (File, Help), a toolbar, a tab control with six pages
  (a list box and a combo box; a multi-line edit box and two edit boxes
  to copy and paste between; a tree view; a list view, several items
  selectable and sorted by a header click, with buttons for its views;
  a checked list box, numeric up/down boxes, date and time pickers and
  a month calendar; charts of each kind, ControlsTour.ChartsPage) and a
  status bar; Ctrl+M asks a question in a message box, Help >
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
    checked TEXT 0|1      a checked list box item was toggled
    quantity N            the numeric up/down box's value
    hex N                 the hexadecimal up/down box's value
    date YYYY-MM-DD       the date picker's date
    time TEXT|none        the time picker's time (none: unchecked)
    calendar FIRST LAST   the calendar's selected dates
    chart variant N       the charts switched to variant N (0 or 1)
    chart toggled NAME S  a chart legend entry hid (0) or showed (1) NAME
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
  Controls.Labels,
  Controls.CheckedListBox,
  Controls.NumericUpDown,
  Controls.CalendarDates,
  Controls.Calendar,
  Controls.DateTimePicker,
  Controls.Text,
  ControlsTour.ChartsPage;

const
  KeyM = $32;
  ChartTimer = 1;

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
    FChecklist: TCheckedListBox;
    FQuantity: TNumericUpDown;
    FHexValue: TNumericUpDown;
    FDatePicker: TDateTimePicker;
    FTimePicker: TDateTimePicker;
    FCalendar: TCalendar;
    FStatus: TStatusBar;
    FCharts: TChartsPage;
    FChartsPageIndex: LongInt;
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
    procedure BuildPickersPage;
    procedure BuildChartsPage;
    procedure AddCaption(Page: TControl; const Caption: string; Left, Top: LongInt);
    procedure ItemChecked(Sender: TControl; Index: LongInt; Checked: Boolean);
    procedure NumberChanged(Sender: TControl);
    procedure PickerChanged(Sender: TControl);
    procedure CalendarChanged(Sender: TControl);
    procedure CalendarDropped(Sender: TControl);
    procedure TellPlace(const Name: string; Control: TControl; X, Y: LongInt);
  protected
    procedure TimerFired(TimerId: LongWord); override;
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
  BuildPickersPage;
  BuildChartsPage;
end;

{ The charts, last: its place among the pages is remembered rather than
  fixed, so pages added before it move nothing. }
procedure TTourWindow.BuildChartsPage;
var
  Page: TControl;
begin
  Page := FTabs.AddPage('Ch&arts');
  FChartsPageIndex := FTabs.PageCount - 1;
  FCharts := TChartsPage.Create(Page);
  FCharts.Align := AlignClient;
end;

procedure TTourWindow.AddCaption(Page: TControl; const Caption: string; Left, Top: LongInt);
var
  CaptionLabel: TLabel;
begin
  CaptionLabel := TLabel.Create(Page);
  CaptionLabel.Text := Caption;
  CaptionLabel.SetBounds(Left, Top, 130, 16);
end;

{ The checked list box, the numeric up/down boxes, the date and time
  pickers and the calendar. The date picker starts on a fixed date, so
  its calendar shows the same month whenever the tour runs. }
procedure TTourWindow.BuildPickersPage;
var
  Page: TControl;
  Width: LongInt;
  Height: LongInt;
begin
  Page := FTabs.AddPage('&Pickers');
  AddCaption(Page, 'To &buy:', 8, 6);
  FChecklist := TCheckedListBox.Create(Page);
  FChecklist.SetBounds(8, 24, 130, 100);
  FChecklist.Items.Add('Apples');
  FChecklist.Items.Add('Pears');
  FChecklist.Items.Add('Plums');
  FChecklist.Items.Add('Cherries');
  FChecklist.Items.Add('Grapes');
  FChecklist.Checked[0] := True;
  FChecklist.AllowMixed := True;
  FChecklist.OnItemCheck := @ItemChecked;
  AddCaption(Page, '&Quantity:', 8, 132);
  FQuantity := TNumericUpDown.Create(Page);
  FQuantity.SetBounds(8, 150, 90, 22);
  FQuantity.SetRange(0, 1000000);
  FQuantity.ThousandsSeparator := True;
  FQuantity.Value := 5;
  FQuantity.OnValueChanged := @NumberChanged;
  AddCaption(Page, 'He&x value:', 8, 180);
  FHexValue := TNumericUpDown.Create(Page);
  FHexValue.SetBounds(8, 198, 90, 22);
  FHexValue.Hexadecimal := True;
  FHexValue.SetRange(0, 4095);
  FHexValue.Value := 255;
  FHexValue.OnValueChanged := @NumberChanged;
  AddCaption(Page, 'D&ate:', 150, 6);
  FDatePicker := TDateTimePicker.Create(Page);
  FDatePicker.SetBounds(150, 24, 150, 22);
  FDatePicker.Date := MakeCalendarDate(2026, 11, 16);
  FDatePicker.OnChange := @PickerChanged;
  FDatePicker.OnDropDown := @CalendarDropped;
  AddCaption(Page, 'Ti&me:', 310, 6);
  FTimePicker := TDateTimePicker.Create(Page);
  FTimePicker.Kind := DateTimeKindTime;
  FTimePicker.Format := DateTimeFormatCustom;
  FTimePicker.CustomPattern := 'h:mm:ss tt';
  FTimePicker.ShowCheckBox := True;
  FTimePicker.SetBounds(310, 24, 140, 22);
  FTimePicker.OnChange := @PickerChanged;
  AddCaption(Page, '&Calendar:', 150, 54);
  FCalendar := TCalendar.Create(Page);
  FCalendar.ShowWeekNumbers := True;
  FCalendar.ShowToday := False;
  FCalendar.MaxSelectionCount := 7;
  FCalendar.AddBoldDate(MakeCalendarDate(LocalToday.Year, LocalToday.Month, 1));
  FCalendar.AddBoldDate(MakeCalendarDate(LocalToday.Year, LocalToday.Month, 15));
  FCalendar.GetPreferredSize(Width, Height);
  FCalendar.SetBounds(150, 72, Width, Height);
  FCalendar.OnDateChanged := @CalendarChanged;
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
  TellPlace('pickers-tab', FTabs, (FTabs.TabBounds(4).Left + FTabs.TabBounds(4).Right) div 2, Scaled(8));
  RowHeight := FList.ItemHeight;
  TellPlace('list-item-3', FList, Scaled(30), 2 + 2 * RowHeight + RowHeight div 2);
  TellPlace('combo', FCombo, RectangleWidth(FCombo.PixelBounds) div 2, RectangleHeight(FCombo.PixelBounds) div 2);
  TellPlace('combo-second', FCombo, Scaled(30), RectangleHeight(FCombo.PixelBounds) + 2 + RowHeight + RowHeight div 2);
end;

procedure TTourWindow.ItemChecked(Sender: TControl; Index: LongInt; Checked: Boolean);
begin
  Say(Format('checked %s %d', [FChecklist.Items[Index], Ord(Checked)]));
end;

procedure TTourWindow.NumberChanged(Sender: TControl);
begin
  if Sender = FQuantity then
    Say('quantity ' + FQuantity.Editor.Text)
  else
    Say('hex ' + FHexValue.Editor.Text);
end;

procedure TTourWindow.PickerChanged(Sender: TControl);
begin
  if Sender = FDatePicker then
    Say('date ' + DateToIsoText(FDatePicker.Date))
  else if FTimePicker.Checked then
    Say('time ' + FTimePicker.ValueText)
  else
    Say('time none');
end;

procedure TTourWindow.CalendarChanged(Sender: TControl);
begin
  Say('calendar ' + DateToIsoText(FCalendar.SelectionStart) + ' ' + DateToIsoText(FCalendar.SelectionEnd));
end;

{ Where a day of the dropped calendar is (it is in its own pop-up
  window): the 20th, to click. }
procedure TTourWindow.CalendarDropped(Sender: TControl);
var
  Dropped: TCalendar;
  PopupWindow: TControlWindow;
  Cell: TRectangle;
begin
  Dropped := FDatePicker.DroppedCalendar;
  if (Dropped = nil) or not (Dropped.Host.OwnerWindow is TControlWindow) then
    Exit;
  PopupWindow := TControlWindow(Dropped.Host.OwnerWindow);
  Cell := Dropped.DateBounds(MakeCalendarDate(Dropped.ShownYear, Dropped.ShownMonth, 20));
  if RectangleIsEmpty(Cell) then
    Exit;
  Say(Format('place calendar-day-20 %d %d', [Scaled(PopupWindow.ScreenLeft) + Dropped.PixelBounds.Left +
    (Cell.Left + Cell.Right) div 2, Scaled(PopupWindow.ScreenTop) + Dropped.PixelBounds.Top + (Cell.Top + Cell.Bottom) div 2]));
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
  begin
    TellPlace('checked-item-2', FChecklist, Scaled(60), 2 + FChecklist.ItemHeight + FChecklist.ItemHeight div 2);
    TellPlace('quantity', FQuantity, Scaled(30), RectangleHeight(FQuantity.PixelBounds) div 2);
    TellPlace('date-button', FDatePicker, RectangleWidth(FDatePicker.PixelBounds) - Scaled(9),
      RectangleHeight(FDatePicker.PixelBounds) div 2);
  end;
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
  if Page = FChartsPageIndex then
    TellPlace('charts-variant', FCharts.VariantButton, RectangleWidth(FCharts.VariantButton.PixelBounds) div 2,
      RectangleHeight(FCharts.VariantButton.PixelBounds) div 2);
end;

procedure TTourWindow.TimerFired(TimerId: LongWord);
begin
  if TimerId = ChartTimer then
    FCharts.Tick
  else
    inherited TimerFired(TimerId);
end;

procedure TTourWindow.ChildNotified(Sender: TControl; Child: TControl; Code: LongWord);
begin
  if Code <> NotifyChanged then
    Exit;
  if Child = FTabs then
  begin
    Say('page ' + IntToStr(FTabs.PageIndex));
    TellPagePlaces(FTabs.PageIndex);
    { The live chart moves on only while it can be seen. }
    if FTabs.PageIndex = FChartsPageIndex then
      StartTimer(ChartTimer, ChartTickMilliseconds)
    else
      StopTimer(ChartTimer);
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
