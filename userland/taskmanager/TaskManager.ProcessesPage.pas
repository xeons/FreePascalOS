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
  The Processes tab: every process in a list - its name, id, user, its
  share of the processors since the last look, its own memory, threads,
  state and session - sorted by any column (a click on its header,
  again to turn the order round), several selected at once.

  The list is brought up to date in place at each look: rows of
  processes that ended go, new ones are added, the others' cells
  change, and the order is kept by the chosen column, the selection and
  the focus staying with their processes. Only this user's processes
  are listed unless "Show processes from all users" is ticked.

  A right click (or Shift+F10) on the selection opens End (ask the
  processes to end), End now (outright, after asking), Stop, Continue,
  Priority and Properties; the button below and the Delete key ask the
  selected processes to end. What this user may not do to another's
  processes is greyed out (only root acts on others').
}
unit TaskManager.ProcessesPage;

{$mode objfpc}
{$H+}

interface

uses
  Controls.Base,
  Controls.Window,
  Controls.Buttons,
  Controls.Toggles,
  Controls.ListItems,
  Controls.ListView,
  Controls.Menus,
  TaskManager.Sampler,
  TaskManager.ProcessActions;

const
  ColumnName = 0;
  ColumnProcessId = 1;
  ColumnUser = 2;
  ColumnProcessor = 3;
  ColumnMemory = 4;
  ColumnThreads = 5;
  ColumnState = 6;
  ColumnSession = 7;

type
  { What a row shows, as numbers for sorting. }
  TProcessRow = record
    ProcessId: QWord;
    Name: string;
    UserName: string;
    ProcessorTenths: LongWord;
    PrivateBytes: QWord;
    ThreadCount: LongWord;
    State: LongWord;
    SessionId: QWord;
    Nice: LongInt;
    MayActOn: Boolean;
  end;
  PProcessRow = ^TProcessRow;

  TSortChangedEvent = procedure(Column: LongInt; Ascending: Boolean) of object;

  TProcessesPage = class(TControl)
  private
    FWindow: TControlWindow;
    FSampler: TUsageSampler;
    FList: TListView;
    FShowAllUsers: TCheckBox;
    FEndButton: TButton;
    FMenu: TMenuItem;
    FOnSortChanged: TSortChangedEvent;
    function RowOf(Index: LongInt): PProcessRow;
    function RowIndexOf(ProcessId: QWord): LongInt;
    function IsListed(Index: LongInt): Boolean;
    procedure FillRow(Index: LongInt; SamplerIndex: LongInt);
    procedure RemoveRow(Index: LongInt);
    procedure SortRows;
    procedure TellTopRows;
    function SelectedTargets(OnlyAllowed: Boolean): TProcessTargets;
    function CompareRows(Sender: TListView; First, Second: TListItem; Column: LongInt): LongInt;
    procedure ColumnClicked(Sender: TListView; Column: LongInt);
    procedure ShowAllUsersChanged(Sender: TControl);
    procedure EndClicked(Sender: TControl);
    procedure ListKey(Sender: TControl; Code, Character, Modifiers: LongWord; var Handled: Boolean);
    procedure ContextMenuWanted(Sender: TControl; X, Y: LongInt; FromKeyboard: Boolean);
    procedure BuildMenu;
    procedure MenuChosen(Item: TMenuItem);
  protected
    procedure Layout; override;
  public
    constructor CreatePage(AParent: TControl; Window: TControlWindow; Sampler: TUsageSampler);
    destructor Destroy; override;
    { Brings the list up to date with the sampler's newest look. }
    procedure Update;
    procedure SortBy(Column: LongInt; Ascending: Boolean);
    { Says where its parts are (when the tab is shown). }
    procedure TellPlaces;
    property List: TListView read FList;
    property OnSortChanged: TSortChangedEvent read FOnSortChanged write FOnSortChanged;
  end;

implementation

uses
  SysUtils,
  Abi.SystemCalls,
  Drawing.Rectangles,
  Sys.ProcessList,
  Windowing.Theme,
  Windowing.Connection,
  Windowing.Windows,
  Controls.Keys,
  Util.Accounts,
  TaskManager.Formatting,
  TaskManager.PropertiesDialog,
  TaskManager.Output;

const
  { Logical units. }
  Margin = 6;
  ButtonWidth = 100;
  ButtonHeight = 24;
  CheckBoxWidth = 240;
  { How many of the first rows are told after each look. }
  ToldRows = 5;

  ActionEnd = 1;
  ActionEndNow = 2;
  ActionStop = 3;
  ActionContinue = 4;
  ActionProperties = 5;
  { Priorities: ActionPriority + the index in PriorityNiceValues. }
  ActionPriority = 10;

constructor TProcessesPage.CreatePage(AParent: TControl; Window: TControlWindow; Sampler: TUsageSampler);
begin
  inherited Create(AParent);
  FWindow := Window;
  FSampler := Sampler;
  FList := TListView.Create(Self);
  FList.AddColumn('Name', 120);
  FList.AddColumn('PID', 50);
  FList.AddColumn('User', 70);
  FList.AddColumn('CPU', 56);
  FList.AddColumn('Memory', 80);
  FList.AddColumn('Threads', 62);
  FList.AddColumn('State', 70);
  FList.AddColumn('Session', 60);
  FList.MultiSelect := True;
  FList.SortOnHeaderClick := True;
  FList.OnCompare := @CompareRows;
  FList.OnColumnClick := @ColumnClicked;
  FList.OnContextMenu := @ContextMenuWanted;
  FList.OnKeyDown := @ListKey;
  FShowAllUsers := TCheckBox.Create(Self);
  FShowAllUsers.Text := '&Show processes from all users';
  FShowAllUsers.OnChange := @ShowAllUsersChanged;
  FEndButton := TButton.Create(Self);
  FEndButton.Text := '&End Process';
  FEndButton.OnClick := @EndClicked;
end;

destructor TProcessesPage.Destroy;
var
  Index: LongInt;
begin
  for Index := FList.RowCount - 1 downto 0 do
    RemoveRow(Index);
  FMenu.Free;
  inherited Destroy;
end;

procedure TProcessesPage.Layout;
var
  Width: LongInt;
  Height: LongInt;
  BarTop: LongInt;
begin
  Width := Unscaled(RectangleWidth(PixelBounds));
  Height := Unscaled(RectangleHeight(PixelBounds));
  BarTop := Height - Margin - ButtonHeight;
  FList.AssignBounds(Margin, Margin, Width - 2 * Margin, BarTop - 2 * Margin);
  FShowAllUsers.AssignBounds(Margin, BarTop + 3, CheckBoxWidth, ButtonHeight - 6);
  FEndButton.AssignBounds(Width - Margin - ButtonWidth, BarTop, ButtonWidth, ButtonHeight);
  inherited Layout;
end;

function TProcessesPage.RowOf(Index: LongInt): PProcessRow;
begin
  Result := PProcessRow(FList.Items[Index].Data);
end;

function TProcessesPage.RowIndexOf(ProcessId: QWord): LongInt;
var
  Index: LongInt;
begin
  for Index := 0 to FList.RowCount - 1 do
    if RowOf(Index)^.ProcessId = ProcessId then
      Exit(Index);
  Result := -1;
end;

{ Whether the sampler's process Index belongs in the list. }
function TProcessesPage.IsListed(Index: LongInt): Boolean;
var
  Details: PProcessDetails;
begin
  Details := FSampler.Processes[Index];
  Result := FShowAllUsers.Checked or (Details^.RealUserId = CurrentUserId) or
    (Details^.EffectiveUserId = CurrentUserId);
end;

procedure TProcessesPage.FillRow(Index: LongInt; SamplerIndex: LongInt);
var
  Details: PProcessDetails;
  Row: PProcessRow;
begin
  Details := FSampler.Processes[SamplerIndex];
  Row := RowOf(Index);
  Row^.ProcessId := Details^.ProcessId;
  Row^.Name := StrPas(@Details^.Name[0]);
  Row^.UserName := UserName(Details^.EffectiveUserId);
  Row^.ProcessorTenths := FSampler.ProcessorShare(SamplerIndex);
  Row^.PrivateBytes := Details^.PrivateBytes;
  Row^.ThreadCount := Details^.ThreadCount;
  Row^.State := Details^.State;
  Row^.SessionId := Details^.SessionId;
  Row^.Nice := Details^.Nice;
  Row^.MayActOn := MayActOn(Details^);
  FList.Cells[Index, ColumnName] := Row^.Name;
  FList.Cells[Index, ColumnProcessId] := IntToStr(Row^.ProcessId);
  FList.Cells[Index, ColumnUser] := Row^.UserName;
  FList.Cells[Index, ColumnProcessor] := FormatPercent(Row^.ProcessorTenths);
  FList.Cells[Index, ColumnMemory] := FormatBytes(Row^.PrivateBytes);
  FList.Cells[Index, ColumnThreads] := IntToStr(Row^.ThreadCount);
  FList.Cells[Index, ColumnState] := StrPas(ProcessStateName(Row^.State));
  FList.Cells[Index, ColumnSession] := IntToStr(Row^.SessionId);
end;

procedure TProcessesPage.RemoveRow(Index: LongInt);
begin
  Dispose(RowOf(Index));
  FList.DeleteRow(Index);
end;

procedure TProcessesPage.Update;
var
  Index: LongInt;
  SamplerIndex: LongInt;
  RowIndex: LongInt;
  Found: Boolean;
  Row: PProcessRow;
begin
  { The rows of processes that ended, or are no longer to be listed. }
  for Index := FList.RowCount - 1 downto 0 do
  begin
    Found := False;
    for SamplerIndex := 0 to FSampler.ProcessCount - 1 do
      if (FSampler.Processes[SamplerIndex]^.ProcessId = RowOf(Index)^.ProcessId) and IsListed(SamplerIndex) then
        Found := True;
    if not Found then
      RemoveRow(Index);
  end;
  for SamplerIndex := 0 to FSampler.ProcessCount - 1 do
  begin
    if not IsListed(SamplerIndex) then
      Continue;
    RowIndex := RowIndexOf(FSampler.Processes[SamplerIndex]^.ProcessId);
    if RowIndex < 0 then
    begin
      RowIndex := FList.AddRow(['']);
      New(Row);
      FList.Items[RowIndex].Data := Row;
    end;
    FillRow(RowIndex, SamplerIndex);
  end;
  SortRows;
  TellTopRows;
end;

procedure TProcessesPage.SortRows;
begin
  if FList.SortColumn >= 0 then
    FList.SortByColumn(FList.SortColumn, FList.SortAscending);
end;

procedure TProcessesPage.SortBy(Column: LongInt; Ascending: Boolean);
begin
  FList.SortByColumn(Column, Ascending);
end;

{ "process PID NAME CPU MEMORY" and where its row is, for the first
  rows: what a test looks for. }
procedure TProcessesPage.TellTopRows;
var
  Index: LongInt;
  Row: PProcessRow;
  Cell: TRectangle;
begin
  { The tab's page is what is shown or hidden. }
  if not Parent.Visible then
    Exit;
  for Index := 0 to FList.RowCount - 1 do
  begin
    if Index >= ToldRows then
      Break;
    Row := RowOf(Index);
    Say(Format('process %d %s %d %d', [Row^.ProcessId, Row^.Name, (Row^.ProcessorTenths + 5) div 10,
      Row^.PrivateBytes div 1024]));
    Cell := FList.ItemBounds(Index);
    SayPlace('row-' + IntToStr(Row^.ProcessId), FWindow, FList.PixelBounds.Left + Cell.Left + Scaled(30),
      FList.PixelBounds.Top + (Cell.Top + Cell.Bottom) div 2);
  end;
end;

function TProcessesPage.CompareRows(Sender: TListView; First, Second: TListItem; Column: LongInt): LongInt;
var
  A: PProcessRow;
  B: PProcessRow;
begin
  A := PProcessRow(First.Data);
  B := PProcessRow(Second.Data);
  case Column of
    ColumnName: Result := CompareText(A^.Name, B^.Name);
    ColumnUser: Result := CompareText(A^.UserName, B^.UserName);
    ColumnProcessor: Result := LongInt(A^.ProcessorTenths) - LongInt(B^.ProcessorTenths);
    ColumnMemory: Result := Ord(A^.PrivateBytes > B^.PrivateBytes) - Ord(A^.PrivateBytes < B^.PrivateBytes);
    ColumnThreads: Result := LongInt(A^.ThreadCount) - LongInt(B^.ThreadCount);
    ColumnState: Result := LongInt(A^.State) - LongInt(B^.State);
    ColumnSession: Result := Ord(A^.SessionId > B^.SessionId) - Ord(A^.SessionId < B^.SessionId);
  else
    Result := 0;
  end;
  { Equal rows keep an order (by id), so the list does not shuffle them
    at every look. }
  if Result = 0 then
    Result := Ord(A^.ProcessId > B^.ProcessId) - Ord(A^.ProcessId < B^.ProcessId);
end;

procedure TProcessesPage.ColumnClicked(Sender: TListView; Column: LongInt);
const
  Directions: array[Boolean] of string = ('descending', 'ascending');
begin
  Say('sort ' + IntToStr(FList.SortColumn) + ' ' + Directions[FList.SortAscending]);
  if Assigned(FOnSortChanged) then
    FOnSortChanged(FList.SortColumn, FList.SortAscending);
end;

procedure TProcessesPage.ShowAllUsersChanged(Sender: TControl);
const
  OnOff: array[Boolean] of string = ('off', 'on');
begin
  Say('all-users ' + OnOff[FShowAllUsers.Checked]);
  Update;
end;

function TProcessesPage.SelectedTargets(OnlyAllowed: Boolean): TProcessTargets;
var
  Index: LongInt;
  Count: LongInt;
  Row: PProcessRow;
begin
  Result := nil;
  Count := 0;
  for Index := 0 to FList.RowCount - 1 do
  begin
    if not FList.Selected[Index] then
      Continue;
    Row := RowOf(Index);
    if OnlyAllowed and not Row^.MayActOn then
      Continue;
    SetLength(Result, Count + 1);
    Result[Count].ProcessId := Row^.ProcessId;
    Result[Count].Name := Row^.Name;
    Inc(Count);
  end;
end;

procedure TProcessesPage.EndClicked(Sender: TControl);
begin
  AskToEnd(FWindow, SelectedTargets(False));
end;

procedure TProcessesPage.ListKey(Sender: TControl; Code, Character, Modifiers: LongWord; var Handled: Boolean);
begin
  if Code = KeyDelete then
  begin
    AskToEnd(FWindow, SelectedTargets(False));
    Handled := True;
  end;
end;

procedure TProcessesPage.BuildMenu;
var
  Index: LongInt;
  AnySelected: Boolean;
  AnyAllowed: Boolean;
  AnyStopped: Boolean;
  AnyRunning: Boolean;
  FocusedNice: LongInt;
  Row: PProcessRow;
  Item: TMenuItem;
  Priority: TMenuItem;
begin
  AnySelected := False;
  AnyAllowed := False;
  AnyStopped := False;
  AnyRunning := False;
  FocusedNice := High(LongInt);
  for Index := 0 to FList.RowCount - 1 do
    if FList.Selected[Index] then
    begin
      Row := RowOf(Index);
      AnySelected := True;
      AnyAllowed := AnyAllowed or Row^.MayActOn;
      AnyStopped := AnyStopped or (Row^.State = ProcessStateStopped);
      AnyRunning := AnyRunning or (Row^.State <> ProcessStateStopped);
      if Index = FList.ItemIndex then
        FocusedNice := Row^.Nice;
    end;
  FMenu.Free;
  FMenu := TMenuItem.Create('');
  Item := FMenu.Add('&End', @MenuChosen, 'Del');
  Item.Tag := ActionEnd;
  Item.Enabled := AnyAllowed;
  Item := FMenu.Add('End &now...', @MenuChosen);
  Item.Tag := ActionEndNow;
  Item.Enabled := AnyAllowed;
  FMenu.AddSeparator;
  Item := FMenu.Add('&Stop', @MenuChosen);
  Item.Tag := ActionStop;
  Item.Enabled := AnyAllowed and AnyRunning;
  Item := FMenu.Add('&Continue', @MenuChosen);
  Item.Tag := ActionContinue;
  Item.Enabled := AnyAllowed and AnyStopped;
  FMenu.AddSeparator;
  Priority := FMenu.Add('&Priority');
  Priority.Enabled := AnyAllowed;
  for Index := 0 to High(PriorityNiceValues) do
  begin
    Item := Priority.Add(PriorityCaptions[Index], @MenuChosen);
    Item.Tag := ActionPriority + Index;
    Item.Checked := PriorityNiceValues[Index] = FocusedNice;
  end;
  FMenu.AddSeparator;
  Item := FMenu.Add('P&roperties', @MenuChosen);
  Item.Tag := ActionProperties;
  Item.Enabled := FList.ItemIndex >= 0;
  if not AnySelected then
    for Index := 0 to FMenu.Count - 1 do
      FMenu[Index].Enabled := False;
end;

procedure TProcessesPage.ContextMenuWanted(Sender: TControl; X, Y: LongInt; FromKeyboard: Boolean);
const
  PlaceNames: array[1..5] of string = ('menu-end', 'menu-end-now', 'menu-stop', 'menu-continue',
    'menu-properties');
var
  Shown: TMenuList;
  MenuWindow: TWindow;
  Index: LongInt;
  Left: LongInt;
  Top: LongInt;
begin
  BuildMenu;
  Left := FWindow.ScreenLeft + Unscaled(FList.PixelBounds.Left + X);
  Top := FWindow.ScreenTop + Unscaled(FList.PixelBounds.Top + Y);
  Shown := ShowPopupMenu(FWindow, FMenu, Left, Top);
  Say('context-menu');
  MenuWindow := TWindow(Shown.Host.OwnerWindow);
  for Index := 0 to FMenu.Count - 1 do
    if (FMenu[Index].Tag >= Low(PlaceNames)) and (FMenu[Index].Tag <= High(PlaceNames)) then
      SayPlace(PlaceNames[FMenu[Index].Tag], MenuWindow, Scaled(40),
        Scaled(PopupMenuItemTop(FMenu, Index) + Theme.MenuItemHeight div 2));
end;

procedure TProcessesPage.MenuChosen(Item: TMenuItem);
var
  Details: TProcessDetails;
begin
  case Item.Tag of
    ActionEnd: AskToEnd(FWindow, SelectedTargets(False));
    ActionEndNow: EndNow(FWindow, SelectedTargets(False));
    ActionStop: StopTargets(FWindow, SelectedTargets(False));
    ActionContinue: ContinueTargets(FWindow, SelectedTargets(False));
    ActionProperties:
      if (FList.ItemIndex >= 0) and GetProcessDetails(RowOf(FList.ItemIndex)^.ProcessId, Details) then
        ShowProcessProperties(FWindow, Details);
  else
    if (Item.Tag >= ActionPriority) and (Item.Tag <= ActionPriority + High(PriorityNiceValues)) then
      SetTargetsPriority(FWindow, SelectedTargets(False), PriorityNiceValues[Item.Tag - ActionPriority]);
  end;
end;

procedure TProcessesPage.TellPlaces;
var
  Column: LongInt;
  Left: LongInt;
begin
  SayControlPlace('end-process', FWindow, FEndButton);
  SayControlPlace('all-users', FWindow, FShowAllUsers);
  { The middle of the CPU column's header. }
  Left := 0;
  for Column := 0 to ColumnProcessor - 1 do
    Left := Left + FList.ColumnWidth(Column);
  SayPlace('cpu-header', FWindow, FList.PixelBounds.Left + 2 + Scaled(Left + FList.ColumnWidth(ColumnProcessor) div 2),
    FList.PixelBounds.Top + FList.HeaderMiddle);
end;

end.
