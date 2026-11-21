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
  A preferences window in the classic style: a row of large icons with
  captions across the top (one per pane: Main, Tabs, Content...), the
  chosen pane under it, and OK, Cancel and Help along the bottom.

    Window := TPreferencesWindow.CreatePreferences('Options', 520, 440, Owner);
    Page := Window.AddPane('Main', 'app-settings');   { controls go on Page }
    if Window.Execute then ...

  A click on an icon, Ctrl+Tab and Ctrl+Shift+Tab (or Ctrl+Page Down and
  Up) change panes. The chosen icon is drawn in the theme's header band
  (golden in Sunrise), pressed into the face in Classic. Sizes are
  logical units.
}
unit Controls.PreferencesWindow;

{$mode objfpc}
{$H+}

interface

uses
  Classes,
  Drawing.Canvas,
  Windowing.Windows,
  Controls.Base,
  Controls.Window,
  Controls.Buttons,
  Controls.Dialogs,
  Controls.CommonDialogs;

type
  TPreferencesWindow = class;

  { The row of pane icons. }
  TPaneSelector = class(TControl)
  private
    FWindow: TPreferencesWindow;
    FHot: LongInt;
    function PaneAt(X: LongInt): LongInt;
    function PaneLeft(Index: LongInt): LongInt;
    function PaneWidth(Index: LongInt): LongInt;
  protected
    procedure Paint(var Canvas: TCanvas); override;
    procedure PointerDown(X, Y: LongInt; Button: LongWord); override;
    procedure PointerMove(X, Y: LongInt; Buttons: LongWord); override;
    procedure PointerLeave; override;
    function KeyDown(Code, Character, Modifiers: LongWord): Boolean; override;
  public
    function PreferredSize: TSize; override;
  end;

  TPreferencesWindow = class(TCommonDialog)
  private
    FSelector: TPaneSelector;
    FPages: TList;
    FCaptions: TStringList;
    FPaneIndex: LongInt;
    FClientWidth, FClientHeight: LongInt;
    FHelpButton: TButton;
    FOnPaneChanged: TControlEvent;
    FOnHelp: TControlEvent;
    FIconNames: TStringList;
    procedure SetOnHelp(Value: TControlEvent);
    procedure SetPaneIndex(Value: LongInt);
    function GetPage(Index: LongInt): TControl;
    procedure HelpClicked(Sender: TControl);
    procedure NextPane(Sender: TControlWindow);
    procedure PreviousPane(Sender: TControlWindow);
  public
    constructor CreatePreferences(const ATitle: string; Width, Height: LongInt; AOwner: TWindow = nil);
    destructor Destroy; override;
    { A pane with its caption and theme icon; its page (where its
      controls go, logical units from its top left). }
    function AddPane(const Caption, Icon: string): TControl;
    function PaneCount: LongInt;
    function PaneCaption(Index: LongInt): string;
    property PaneIndex: LongInt read FPaneIndex write SetPaneIndex;
    property Pages[Index: LongInt]: TControl read GetPage;
    property HelpButton: TButton read FHelpButton;
    property OnPaneChanged: TControlEvent read FOnPaneChanged write FOnPaneChanged;
    { Help was pressed (it is hidden without a handler). }
    property OnHelp: TControlEvent read FOnHelp write SetOnHelp;
  end;

implementation

uses
  Drawing.Colors,
  Abi.SystemCalls,
  Math,
  Drawing.Rectangles,
  Windowing.Theme,
  Windowing.Connection,
  Controls.Keys,
  Controls.Text,
  Controls.Panels,
  Controls.Painting,
  Controls.IconTheme,
  Controls.LayoutRules;

const
  SelectorHeight = 62;
  PaneIconSize = 32;
  MinimumPaneWidth = 72;
  PanePadding = 10;

{ ---- the selector ---- }

function TPaneSelector.PreferredSize: TSize;
begin
  Result := MakeSize(400, SelectorHeight);
end;

{ Pixels. }
function TPaneSelector.PaneWidth(Index: LongInt): LongInt;
begin
  Result := Max(Scaled(MinimumPaneWidth), TextWidth(ControlFace, FWindow.FCaptions[Index]) + Scaled(2 * PanePadding));
end;

function TPaneSelector.PaneLeft(Index: LongInt): LongInt;
var
  Item: LongInt;
begin
  Result := Scaled(4);
  for Item := 0 to Index - 1 do
    Inc(Result, PaneWidth(Item));
end;

function TPaneSelector.PaneAt(X: LongInt): LongInt;
var
  Index: LongInt;
begin
  for Index := 0 to FWindow.FCaptions.Count - 1 do
    if (X >= PaneLeft(Index)) and (X < PaneLeft(Index) + PaneWidth(Index)) then
      Exit(Index);
  Result := -1;
end;

procedure TPaneSelector.Paint(var Canvas: TCanvas);
var
  Box, Pane, IconBox, TextBox: TRectangle;
  Index, Size: LongInt;
  TextColor: TColor;
begin
  Box := MakeRectangle(0, 0, RectangleWidth(PixelBounds), RectangleHeight(PixelBounds));
  FillRectangle(Canvas, Box, Theme.Field);
  DrawEtchedHorizontalLine(Canvas, 0, Box.Right, Box.Bottom - 2 * BevelLine);
  Size := Scaled(PaneIconSize);
  for Index := 0 to FWindow.FCaptions.Count - 1 do
  begin
    Pane := MakeRectangle(PaneLeft(Index), Scaled(2), PaneWidth(Index), RectangleHeight(Box) - Scaled(6));
    TextColor := Theme.FieldText;
    if Index = FWindow.FPaneIndex then
    begin
      if Theme.HeaderBandsShown then
      begin
        DrawHeaderBand(Canvas, Pane, BandHeader);
        TextColor := HeaderBandText(BandHeader);
      end
      else
      begin
        FillRectangle(Canvas, Pane, Theme.Face);
        DrawSunkenEdge(Canvas, Pane);
        TextColor := Theme.FaceText;
      end;
    end
    else if Index = FHot then
    begin
      FillRectangle(Canvas, Pane, Theme.HotButtonFace);
      DrawRaisedEdge(Canvas, Pane);
      TextColor := Theme.FaceText;
    end;
    IconBox := MakeRectangle(Pane.Left + (RectangleWidth(Pane) - Size) div 2, Pane.Top + Scaled(4), Size, Size);
    DrawThemeIcon(Canvas, FWindow.FIconNames[Index], IconBox);
    TextBox := MakeRectangle(Pane.Left, IconBox.Bottom + Scaled(2), RectangleWidth(Pane), Pane.Bottom -
      IconBox.Bottom - Scaled(2));
    DrawTextInBox(Canvas, ControlFace, FWindow.FCaptions[Index], TextBox, AlignTextCenter, TextColor);
  end;
end;

procedure TPaneSelector.PointerDown(X, Y: LongInt; Button: LongWord);
var
  Index: LongInt;
begin
  if Button <> ButtonLeft then
    Exit;
  Index := PaneAt(X);
  if Index >= 0 then
    FWindow.PaneIndex := Index;
end;

procedure TPaneSelector.PointerMove(X, Y: LongInt; Buttons: LongWord);
var
  Index: LongInt;
begin
  inherited PointerMove(X, Y, Buttons);
  Index := PaneAt(X);
  if Index <> FHot then
  begin
    FHot := Index;
    Invalidate;
  end;
end;

procedure TPaneSelector.PointerLeave;
begin
  inherited PointerLeave;
  FHot := -1;
  Invalidate;
end;

function TPaneSelector.KeyDown(Code, Character, Modifiers: LongWord): Boolean;
begin
  Result := True;
  case Code of
    KeyArrowLeft:
      FWindow.PaneIndex := Max(0, FWindow.PaneIndex - 1);
    KeyArrowRight:
      FWindow.PaneIndex := Min(FWindow.PaneCount - 1, FWindow.PaneIndex + 1);
  else
    Result := False;
  end;
end;

{ ---- the window ---- }

constructor TPreferencesWindow.CreatePreferences(const ATitle: string; Width, Height: LongInt; AOwner: TWindow);
var
  Top: LongInt;
begin
  inherited CreateDialog(ATitle, Width, Height, AOwner);
  FPages := TList.Create;
  FCaptions := TStringList.Create;
  FIconNames := TStringList.Create;
  FPaneIndex := -1;
  FClientWidth := Width;
  FClientHeight := Height;
  FSelector := TPaneSelector.Create(Root);
  FSelector.FWindow := Self;
  FSelector.FHot := -1;
  FSelector.CanFocus := True;
  FSelector.SetBounds(0, 0, Width, SelectorHeight);
  FSelector.Anchors := [akLeft, akTop, akRight];
  AddOkAndCancel(Width, Height);
  Top := Height - DialogMargin - DialogButtonHeight;
  FHelpButton := AddButton('&Help', ResultNone, DialogMargin, Top, DialogButtonWidth, DialogButtonHeight);
  FHelpButton.Anchors := [akLeft, akBottom];
  FHelpButton.OnClick := @HelpClicked;
  FHelpButton.Visible := False;
  AddAccelerator(KeyTab, ModifierControl, @NextPane);
  AddAccelerator(KeyPageDown, ModifierControl, @NextPane);
  AddAccelerator(KeyTab, ModifierControl or ModifierShift, @PreviousPane);
  AddAccelerator(KeyPageUp, ModifierControl, @PreviousPane);
end;

destructor TPreferencesWindow.Destroy;
begin
  FPages.Free;
  FCaptions.Free;
  FIconNames.Free;
  inherited Destroy;
end;

function TPreferencesWindow.AddPane(const Caption, Icon: string): TControl;
var
  Page: TPanel;
  Width, Height: LongInt;
begin
  Width := FClientWidth;
  Height := FClientHeight;
  Page := TPanel.Create(Root);
  Page.Edge := PanelFlat;
  Page.SetBounds(0, SelectorHeight, Width, Height - SelectorHeight - DialogMargin * 2 - DialogButtonHeight);
  Page.Anchors := [akLeft, akTop, akRight, akBottom];
  Page.Visible := False;
  FPages.Add(Page);
  FCaptions.Add(Caption);
  FIconNames.Add(Icon);
  if FPaneIndex < 0 then
    PaneIndex := 0;
  FSelector.Invalidate;
  Result := Page;
end;

function TPreferencesWindow.PaneCount: LongInt;
begin
  Result := FPages.Count;
end;

function TPreferencesWindow.PaneCaption(Index: LongInt): string;
begin
  Result := FCaptions[Index];
end;

function TPreferencesWindow.GetPage(Index: LongInt): TControl;
begin
  Result := TControl(FPages[Index]);
end;

procedure TPreferencesWindow.SetPaneIndex(Value: LongInt);
var
  Index: LongInt;
begin
  if (Value < 0) or (Value >= FPages.Count) or (Value = FPaneIndex) then
    Exit;
  FPaneIndex := Value;
  for Index := 0 to FPages.Count - 1 do
    Pages[Index].Visible := Index = Value;
  FSelector.Invalidate;
  if Assigned(FOnPaneChanged) then
    FOnPaneChanged(Pages[Value]);
end;

procedure TPreferencesWindow.NextPane(Sender: TControlWindow);
begin
  if FPages.Count > 0 then
    PaneIndex := (FPaneIndex + 1) mod FPages.Count;
end;

procedure TPreferencesWindow.PreviousPane(Sender: TControlWindow);
begin
  if FPages.Count > 0 then
    PaneIndex := (FPaneIndex + FPages.Count - 1) mod FPages.Count;
end;

procedure TPreferencesWindow.HelpClicked(Sender: TControl);
begin
  if Assigned(FOnHelp) then
    FOnHelp(Pages[FPaneIndex]);
end;

procedure TPreferencesWindow.SetOnHelp(Value: TControlEvent);
begin
  FOnHelp := Value;
  FHelpButton.Visible := Assigned(Value);
end;

end.
