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
  Tools > Error Console (Ctrl+Shift+J): a window of its own listing the
  pages' console messages and script errors from every tab (their
  content processes send them; Browser.ConsoleLog keeps them), newest
  last: All, Errors, Warnings and Messages filter them, the box filters
  by text, Clear empties the log.
}
unit Browser.ErrorConsole;

{$mode objfpc}
{$H+}

interface

procedure ShowErrorConsole;

implementation

uses
  SysUtils,
  Classes,
  DateUtils,
  Controls.Base,
  Controls.Window,
  Controls.ToolBar,
  Controls.EditBox,
  Controls.ListView,
  Controls.ImageList,
  Controls.IconTheme,
  Controls.Panels,
  Browser.ConsoleLog,
  Browser.Application,
  Browser.Output;

type
  TErrorConsoleWindow = class(TControlWindow)
  private
    FToolBar: TToolBar;
    FImages: TImageList;
    FFilterButtons: array[TConsoleFilter] of TToolButton;
    FFilter: TConsoleFilter;
    FSearch: TEditBox;
    FList: TListView;
    FErrorImage, FWarningImage, FMessageImage: LongInt;
    procedure FilterClicked(Sender: TControl);
    procedure ClearClicked(Sender: TControl);
    procedure SearchChanged(Sender: TControl);
    procedure LogChanged(Sender: TObject);
  protected
    procedure CloseRequested; override;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Fill;
  end;

var
  ConsoleWindow: TErrorConsoleWindow;

constructor TErrorConsoleWindow.Create;
var
  Filter: TConsoleFilter;
const
  FilterNames: array[TConsoleFilter] of string = ('&All', '&Errors', '&Warnings', '&Messages');
var
  Bar: TPanel;
begin
  inherited Create('Error Console', 120, 120, 640, 420);
  IconName := 'app-web-browser';
  FImages := TImageList.Create(16, 16);
  FErrorImage := AddThemeIcon(FImages, 'action-error');
  FWarningImage := AddThemeIcon(FImages, 'action-warning');
  FMessageImage := AddThemeIcon(FImages, 'action-info');
  FToolBar := TToolBar.Create(Root);
  FToolBar.Images := FImages;
  for Filter := Low(TConsoleFilter) to High(TConsoleFilter) do
  begin
    FFilterButtons[Filter] := FToolBar.AddButton(FilterNames[Filter], 0, @FilterClicked);
    FFilterButtons[Filter].IsToggle := True;
    FFilterButtons[Filter].Tag := Ord(Filter);
  end;
  FFilterButtons[FilterAll].Down := True;
  FToolBar.AddSeparator;
  FToolBar.AddButton('&Clear', 0, @ClearClicked);
  Bar := TPanel.Create(Root);
  Bar.Edge := PanelFlat;
  Bar.Align := AlignTop;
  Bar.SetBounds(0, 0, 400, 30);
  FSearch := TEditBox.Create(Bar);
  FSearch.SetBounds(4, 4, 300, 22);
  FSearch.Placeholder := 'Filter';
  FSearch.OnChange := @SearchChanged;
  FList := TListView.Create(Root);
  FList.Align := AlignClient;
  FList.Images := FImages;
  FList.IconsInDetails := True;
  FList.AddColumn('Type', 90);
  FList.AddColumn('Message', 360);
  FList.AddColumn('Source', 160);
  BrowserApp.Console.OnChanged := @LogChanged;
  Fill;
end;

destructor TErrorConsoleWindow.Destroy;
begin
  BrowserApp.Console.OnChanged := nil;
  FImages.Free;
  inherited Destroy;
end;

procedure TErrorConsoleWindow.CloseRequested;
begin
  Hide;
end;

procedure TErrorConsoleWindow.Fill;
var
  Entries: TConsoleEntries;
  Index, Row: Integer;
begin
  Entries := BrowserApp.Console.Filtered(FFilter, FSearch.Text);
  FList.Clear;
  for Index := 0 to High(Entries) do
  begin
    Row := FList.AddRow([SeverityName(Entries[Index].Severity), Entries[Index].Text, Entries[Index].Source]);
    case Entries[Index].Severity of
      SeverityError: FList.Items[Row].ImageIndex := FErrorImage;
      SeverityWarning: FList.Items[Row].ImageIndex := FWarningImage;
    else
      FList.Items[Row].ImageIndex := FMessageImage;
    end;
  end;
end;

procedure TErrorConsoleWindow.FilterClicked(Sender: TControl);
var
  Filter: TConsoleFilter;
begin
  FFilter := TConsoleFilter(Sender.Tag);
  for Filter := Low(TConsoleFilter) to High(TConsoleFilter) do
    FFilterButtons[Filter].Down := Filter = FFilter;
  Fill;
end;

procedure TErrorConsoleWindow.ClearClicked(Sender: TControl);
begin
  BrowserApp.Console.Clear;
end;

procedure TErrorConsoleWindow.SearchChanged(Sender: TControl);
begin
  Fill;
end;

procedure TErrorConsoleWindow.LogChanged(Sender: TObject);
begin
  Fill;
end;

procedure ShowErrorConsole;
begin
  if ConsoleWindow = nil then
    ConsoleWindow := TErrorConsoleWindow.Create;
  ConsoleWindow.Fill;
  ConsoleWindow.Show;
  ConsoleWindow.Activate;
  Say('error-console ' + IntToStr(BrowserApp.Console.Count));
end;

end.
