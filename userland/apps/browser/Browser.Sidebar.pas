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
  The sidebar beside the pages (View > Sidebar, Ctrl+B and Ctrl+H): a
  header with its name and a close button, a search box, and a tree -
  the bookmarks (the toolbar, menu and unsorted folders) or the history
  grouped by day (Today, Yesterday, Last 7 days...). A double click or
  Enter opens a page in the tab, a middle click in a new tab.
}
unit Browser.Sidebar;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Canvas,
  Controls.Base,
  Controls.Labels,
  Controls.Buttons,
  Controls.EditBox,
  Controls.TreeView,
  WebView.Control;

type
  TSidebarKind = (SidebarBookmarks, SidebarHistory);
  TSidebarOpenEvent = procedure(const Url: string; Disposition: TLinkDisposition) of object;

  TBrowserSidebar = class(TControl)
  private
    FKind: TSidebarKind;
    FTitle: TLabel;
    FClose: TButton;
    FSearch: TEditBox;
    FTree: TTreeView;
    FUrls: array of string;
    FOnOpen: TSidebarOpenEvent;
    FOnClose: TControlEvent;
    procedure SetKind(Value: TSidebarKind);
    procedure SearchChanged(Sender: TControl);
    procedure CloseClicked(Sender: TControl);
    procedure NodeActivated(Sender: TTreeView; Node: TTreeNode);
    function AddUrl(const Url: string): Pointer;
    procedure FillBookmarks;
    procedure FillHistory;
  protected
    procedure Paint(var Canvas: TCanvas); override;
  public
    constructor Create(AParent: TControl); override;
    procedure Refresh;
    procedure FocusSearch;
    property Kind: TSidebarKind read FKind write SetKind;
    property Tree: TTreeView read FTree;
    property OnOpen: TSidebarOpenEvent read FOnOpen write FOnOpen;
    property OnClose: TControlEvent read FOnClose write FOnClose;
  end;

implementation

uses
  SysUtils,
  Drawing.Rectangles,
  Windowing.Theme,
  Controls.Icons,
  Controls.Window,
  Controls.LayoutRules,
  Browser.History,
  Browser.Bookmarks,
  Browser.Application;

constructor TBrowserSidebar.Create(AParent: TControl);
begin
  inherited Create(AParent);
  FTitle := TLabel.Create(Self);
  FTitle.SetBounds(6, 4, 150, 18);
  FTitle.Anchors := [akLeft, akTop, akRight];
  FClose := TButton.Create(Self);
  FClose.Text := #195#151;
  FClose.Flat := True;
  FClose.Hint := 'Close the sidebar';
  FClose.SetBounds(196, 2, 22, 22);
  FClose.Anchors := [akRight, akTop];
  FClose.OnClick := @CloseClicked;
  FSearch := TEditBox.Create(Self);
  FSearch.SetBounds(4, 28, 212, 22);
  FSearch.Anchors := [akLeft, akTop, akRight];
  FSearch.Placeholder := 'Search';
  FSearch.OnChange := @SearchChanged;
  FTree := TTreeView.Create(Self);
  FTree.SetBounds(4, 54, 212, 240);
  FTree.Anchors := [akLeft, akTop, akRight, akBottom];
  FTree.OnActivate := @NodeActivated;
  SetBounds(0, 0, 220, 300);
  Kind := SidebarBookmarks;
end;

procedure TBrowserSidebar.Paint(var Canvas: TCanvas);
begin
  FillRectangle(Canvas, MakeRectangle(0, 0, RectangleWidth(PixelBounds), RectangleHeight(PixelBounds)), Theme.Face);
end;

procedure TBrowserSidebar.SetKind(Value: TSidebarKind);
begin
  FKind := Value;
  if Value = SidebarBookmarks then
    FTitle.Text := 'Bookmarks'
  else
    FTitle.Text := 'History';
  FSearch.Text := '';
  Refresh;
end;

procedure TBrowserSidebar.FocusSearch;
begin
  if (Host <> nil) and (Host.OwnerWindow is TControlWindow) then
    TControlWindow(Host.OwnerWindow).FocusControl(FSearch);
end;

function TBrowserSidebar.AddUrl(const Url: string): Pointer;
begin
  SetLength(FUrls, Length(FUrls) + 1);
  FUrls[High(FUrls)] := Url;
  Result := Pointer(PtrInt(Length(FUrls)));
end;

procedure TBrowserSidebar.FillBookmarks;
var
  Found: TBookmarkNodeList;
  Index: Integer;
  Node: TTreeNode;

  procedure AddFolder(Parent: TTreeNode; Folder: TBookmarkNode);
  var
    Item: Integer;
    Child: TTreeNode;
  begin
    for Item := 0 to Folder.Count - 1 do
      case Folder[Item].Kind of
        BookmarkFolder:
          begin
            if Parent = nil then
              Child := FTree.AddRoot(Folder[Item].ShownTitle)
            else
              Child := Parent.Add(Folder[Item].ShownTitle);
            Child.SetIcon(StockIconFolder);
            AddFolder(Child, Folder[Item]);
          end;
        BookmarkItem:
          begin
            if Parent = nil then
              Child := FTree.AddRoot(Folder[Item].ShownTitle)
            else
              Child := Parent.Add(Folder[Item].ShownTitle);
            Child.SetIcon(StockIconInternet);
            Child.Data := AddUrl(Folder[Item].Url);
          end;
      end;
  end;

begin
  if Trim(FSearch.Text) <> '' then
  begin
    Found := BrowserApp.Bookmarks.Search(FSearch.Text);
    for Index := 0 to High(Found) do
    begin
      Node := FTree.AddRoot(Found[Index].ShownTitle);
      Node.SetIcon(StockIconInternet);
      Node.Data := AddUrl(Found[Index].Url);
    end;
    Exit;
  end;
  AddFolder(nil, BrowserApp.Bookmarks.Root);
end;

procedure TBrowserSidebar.FillHistory;
var
  Places: THistoryPlaceList;
  Groups: array[THistoryAge] of TTreeNode;
  Age: THistoryAge;
  Index: Integer;
  Node: TTreeNode;
  Title: string;
  Now: Int64;
begin
  if Trim(FSearch.Text) <> '' then
    Places := BrowserApp.History.Search(FSearch.Text)
  else
    Places := BrowserApp.History.Places;
  for Age := Low(THistoryAge) to High(THistoryAge) do
    Groups[Age] := nil;
  Now := BrowserApp.NowUnix;
  for Index := 0 to High(Places) do
  begin
    Age := HistoryAgeOf(Places[Index].LastVisit, Now);
    if Groups[Age] = nil then
    begin
      Groups[Age] := FTree.AddRoot(HistoryAgeName(Age));
      Groups[Age].SetIcon(StockIconFolder);
      Groups[Age].Expanded := Age = AgeToday;
    end;
    Title := Places[Index].Title;
    if Title = '' then
      Title := Places[Index].Url;
    Node := Groups[Age].Add(Title);
    Node.SetIcon(StockIconInternet);
    Node.Data := AddUrl(Places[Index].Url);
  end;
end;

procedure TBrowserSidebar.Refresh;
begin
  FTree.Clear;
  FUrls := nil;
  if FKind = SidebarBookmarks then
    FillBookmarks
  else
    FillHistory;
end;

procedure TBrowserSidebar.SearchChanged(Sender: TControl);
begin
  Refresh;
end;

procedure TBrowserSidebar.CloseClicked(Sender: TControl);
begin
  if Assigned(FOnClose) then
    FOnClose(Self);
end;

procedure TBrowserSidebar.NodeActivated(Sender: TTreeView; Node: TTreeNode);
var
  Index: PtrInt;
begin
  Index := PtrInt(Node.Data) - 1;
  if (Index >= 0) and (Index <= High(FUrls)) and Assigned(FOnOpen) then
    FOnOpen(FUrls[Index], LinkInView);
end;

end.
