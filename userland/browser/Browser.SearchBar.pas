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
  The search bar beside the location bar: the engine selector at the
  left (a menu of the search engines, the chosen one ticked, and Manage
  Search Engines...), the words (the chosen engine's name shown greyed
  while empty), and the go button. Enter or the button searches
  (Alt+Enter in a new tab). Until an engine is chosen nothing is sent:
  searching opens the engine menu instead, with a note to pick one.
}
unit Browser.SearchBar;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Drawing.Canvas,
  Drawing.Rectangles,
  Controls.Base,
  Controls.EditBox,
  Controls.Menus,
  Browser.SearchEngines;

type
  TSearchBar = class;

  TSearchEvent = procedure(Sender: TSearchBar; const Words: string; NewTab: Boolean) of object;
  TEngineEvent = procedure(Sender: TSearchBar; const Name: string) of object;

  TSearchBarButtonKind = (SearchEngineButton, SearchGoButton);

  TSearchBarButton = class(TControl)
  private
    FBar: TSearchBar;
    FKind: TSearchBarButtonKind;
    FHot: Boolean;
  protected
    procedure Paint(var Canvas: TCanvas); override;
    procedure PointerEnter; override;
    procedure PointerLeave; override;
    procedure PointerDown(X, Y: LongInt; Button: LongWord); override;
  end;

  TSearchBar = class(TControl)
  private
    FEngineButton: TSearchBarButton;
    FEdit: TEditBox;
    FGoButton: TSearchBarButton;
    FMenu: TMenuItem;
    FEngines: TSearchEngineList;
    FEngineName: string;
    FOnSearch: TSearchEvent;
    FOnChooseEngine: TEngineEvent;
    FOnManage: TControlEvent;
    procedure EditKey(Sender: TControl; Code, Character, Modifiers: LongWord; var Handled: Boolean);
    procedure EngineChosen(Item: TMenuItem);
    procedure ManageChosen(Item: TMenuItem);
    procedure SetEngineName(const Value: string);
  protected
    procedure Paint(var Canvas: TCanvas); override;
    procedure PlaceChildren(const Area: TRectangle); override;
  public
    constructor Create(AParent: TControl); override;
    destructor Destroy; override;
    function PreferredSize: TSize; override;
    procedure Search(NewTab: Boolean);
    procedure OpenEngineMenu;
    procedure FocusAndSelect;
    property Edit: TEditBox read FEdit;
    { The list the menu offers (not owned). }
    property Engines: TSearchEngineList read FEngines write FEngines;
    { The chosen engine ('' none). }
    property EngineName: string read FEngineName write SetEngineName;
    property OnSearch: TSearchEvent read FOnSearch write FOnSearch;
    property OnChooseEngine: TEngineEvent read FOnChooseEngine write FOnChooseEngine;
    property OnManage: TControlEvent read FOnManage write FOnManage;
  end;

implementation

uses
  Windowing.Windows,
  Math,
  Abi.SystemCalls,
  Drawing.Colors,
  Windowing.Theme,
  Windowing.Connection,
  Controls.Window,
  Controls.Keys,
  Controls.Text,
  Controls.Painting,
  Controls.IconTheme,
  Controls.LayoutRules;

const
  BarHeight = 26;
  EngineButtonWidth = 30;
  GoButtonWidth = 22;
  ChooseText = 'Choose a search engine';

procedure TSearchBarButton.Paint(var Canvas: TCanvas);
var
  Box, Icon, ArrowBox: TRectangle;
  Size: LongInt;
begin
  Box := MakeRectangle(0, 0, RectangleWidth(PixelBounds), RectangleHeight(PixelBounds));
  if FHot then
    FillRectangle(Canvas, Box, Theme.HotButtonFace);
  Size := Min(Scaled(16), RectangleHeight(Box) - Scaled(4));
  case FKind of
    SearchEngineButton:
      begin
        Icon := MakeRectangle(Box.Left + Scaled(3), Box.Top + (RectangleHeight(Box) - Size) div 2, Size, Size);
        if FBar.FEngineName = '' then
          DrawThemeIcon(Canvas, 'action-question', Icon)
        else
          DrawThemeIcon(Canvas, 'action-search', Icon);
        ArrowBox := MakeRectangle(Icon.Right, Box.Top, Box.Right - Icon.Right, RectangleHeight(Box));
        DrawArrowGlyph(Canvas, ArrowBox, ArrowDown, Max(2, Scaled(2)), Theme.FieldText);
        DrawVerticalLine(Canvas, Box.Right - 1, Box.Top + Scaled(3), Box.Bottom - Scaled(3), Theme.Shadow);
      end;
    SearchGoButton:
      begin
        Icon := MakeRectangle(Box.Left + (RectangleWidth(Box) - Size) div 2, Box.Top + (RectangleHeight(Box) - Size) div 2,
          Size, Size);
        if not DrawThemeIcon(Canvas, 'action-find', Icon) then
          DrawArrowGlyph(Canvas, Box, ArrowRight, Max(3, Scaled(4)), Theme.FieldText);
      end;
  end;
end;

procedure TSearchBarButton.PointerEnter;
begin
  FHot := True;
  Invalidate;
end;

procedure TSearchBarButton.PointerLeave;
begin
  FHot := False;
  Invalidate;
end;

procedure TSearchBarButton.PointerDown(X, Y: LongInt; Button: LongWord);
begin
  if Button <> ButtonLeft then
    Exit;
  case FKind of
    SearchEngineButton:
      FBar.OpenEngineMenu;
    SearchGoButton:
      FBar.Search((HeldModifiers and (ModifierAlt or ModifierControl)) <> 0);
  end;
end;

constructor TSearchBar.Create(AParent: TControl);
begin
  inherited Create(AParent);
  FEngineButton := TSearchBarButton.Create(Self);
  FEngineButton.FBar := Self;
  FEngineButton.FKind := SearchEngineButton;
  FEngineButton.Hint := 'Search engines';
  FEdit := TEditBox.Create(Self);
  FEdit.Borderless := True;
  FEdit.Placeholder := ChooseText;
  FEdit.OnKeyDown := @EditKey;
  FGoButton := TSearchBarButton.Create(Self);
  FGoButton.FBar := Self;
  FGoButton.FKind := SearchGoButton;
  FGoButton.Hint := 'Search';
  FMenu := TMenuItem.Create('');
  SetBounds(0, 0, 200, BarHeight);
end;

destructor TSearchBar.Destroy;
begin
  FMenu.Free;
  inherited Destroy;
end;

function TSearchBar.PreferredSize: TSize;
begin
  Result := MakeSize(200, BarHeight);
end;

procedure TSearchBar.PlaceChildren(const Area: TRectangle);
var
  Inner: TRectangle;
  Engine, Go: LongInt;
begin
  Inner := InflateRectangle(Area, -BevelWidth);
  Engine := Scaled(EngineButtonWidth);
  Go := Scaled(GoButtonWidth);
  PlaceChild(FEngineButton, MakeRectangle(Inner.Left, Inner.Top, Engine, RectangleHeight(Inner)));
  PlaceChild(FGoButton, MakeRectangle(Inner.Right - Go, Inner.Top, Go, RectangleHeight(Inner)));
  PlaceChild(FEdit, MakeRectangle(Inner.Left + Engine + Scaled(2), Inner.Top, Max(0, RectangleWidth(Inner) - Engine -
    Go - Scaled(2)), RectangleHeight(Inner)));
end;

procedure TSearchBar.Paint(var Canvas: TCanvas);
var
  Box: TRectangle;
begin
  Box := MakeRectangle(0, 0, RectangleWidth(PixelBounds), RectangleHeight(PixelBounds));
  FillRectangle(Canvas, Box, Theme.Field);
  DrawSunkenBevel(Canvas, Box);
end;

procedure TSearchBar.SetEngineName(const Value: string);
begin
  FEngineName := Value;
  if Value = '' then
    FEdit.Placeholder := ChooseText
  else
    FEdit.Placeholder := Value;
  if Value = '' then
    FEngineButton.Hint := 'No search engine chosen: nothing is sent until you pick one'
  else
    FEngineButton.Hint := 'Searching with ' + Value;
  Invalidate;
  FEngineButton.Invalidate;
end;

procedure TSearchBar.FocusAndSelect;
begin
  if (Host <> nil) and (Host.OwnerWindow is TControlWindow) then
    TControlWindow(Host.OwnerWindow).FocusControl(FEdit);
  FEdit.SelectAll;
end;

procedure TSearchBar.OpenEngineMenu;
var
  Index: LongInt;
  Item: TMenuItem;
  Window: TControlWindow;
begin
  FMenu.Clear;
  if FEngines <> nil then
    for Index := 0 to FEngines.Count - 1 do
    begin
      Item := FMenu.Add(StringReplace(FEngines[Index].Name, '&', '&&', [rfReplaceAll]), @EngineChosen);
      Item.Tag := Index;
      Item.Checked := SameText(FEngines[Index].Name, FEngineName);
    end;
  if FEngineName <> '' then
  begin
    FMenu.AddSeparator;
    FMenu.Add('&No Search Engine', @EngineChosen).Tag := -1;
  end;
  FMenu.AddSeparator;
  FMenu.Add('&Manage Search Engines...', @ManageChosen);
  if (Host = nil) or not (Host.OwnerWindow is TControlWindow) then
    Exit;
  Window := TControlWindow(Host.OwnerWindow);
  ShowPopupMenu(Window, FMenu, Window.ScreenLeft + Unscaled(PixelBounds.Left),
    Window.ScreenTop + Unscaled(PixelBounds.Bottom));
end;

procedure TSearchBar.EngineChosen(Item: TMenuItem);
begin
  if not Assigned(FOnChooseEngine) then
    Exit;
  if (Item.Tag < 0) or (FEngines = nil) or (Item.Tag >= FEngines.Count) then
    FOnChooseEngine(Self, '')
  else
    FOnChooseEngine(Self, FEngines[Item.Tag].Name);
end;

procedure TSearchBar.ManageChosen(Item: TMenuItem);
begin
  if Assigned(FOnManage) then
    FOnManage(Self);
end;

procedure TSearchBar.Search(NewTab: Boolean);
begin
  if Trim(FEdit.Text) = '' then
    Exit;
  if FEngineName = '' then
  begin
    OpenEngineMenu;
    Exit;
  end;
  if Assigned(FOnSearch) then
    FOnSearch(Self, FEdit.Text, NewTab);
end;

procedure TSearchBar.EditKey(Sender: TControl; Code, Character, Modifiers: LongWord; var Handled: Boolean);
begin
  if IsEnterKey(Code) then
  begin
    Handled := True;
    Search((Modifiers and ModifierAlt) <> 0);
  end
  else if ((Code = KeyArrowDown) or (Code = KeyArrowUp)) and ((Modifiers and ModifierAlt) <> 0) then
  begin
    Handled := True;
    OpenEngineMenu;
  end;
end;

end.
