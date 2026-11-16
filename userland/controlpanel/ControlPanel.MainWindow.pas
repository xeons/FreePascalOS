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
  The Control Panel's window: the list of pages on the left, the page
  chosen on the right, and OK, Cancel and Apply along the bottom.

  Apply makes the changes of every page that has some (it can be
  pressed once something was changed); OK does the same and closes the
  window, unless a change failed; Cancel and the close button close it,
  forgetting what was not applied. Every second the page shown hears
  the time (the Date and Time page's clock moves on).
}
unit ControlPanel.MainWindow;

{$mode objfpc}
{$H+}

interface

uses
  Controls.Base,
  Controls.Window,
  Controls.ListBox,
  Controls.Buttons,
  ControlPanel.Pages,
  ControlPanel.DateTimePage;

type
  TControlPanelWindow = class(TControlWindow)
  private
    FPageList: TListBox;
    FPages: array of TSettingsPage;
    FDateTimePage: TDateTimePage;
    FOkButton: TButton;
    FCancelButton: TButton;
    FApplyButton: TButton;
    FCurrent: LongInt;
    { The list is being set to the page shown: not a choice of the user's. }
    FFollowingList: Boolean;
    procedure AddPage(Page: TSettingsPage);
    procedure PageChosen(Sender: TControl);
    procedure PageModified(Sender: TControl);
    procedure OkClicked(Sender: TControl);
    procedure CancelClicked(Sender: TControl);
    procedure ApplyClicked(Sender: TControl);
    function ApplyAll: Boolean;
    procedure UpdateApplyButton;
    procedure KeepInWorkArea;
  protected
    procedure TimerFired(Timer: LongWord); override;
    procedure CloseRequested; override;
    procedure ScaleChanged; override;
    procedure Resized; override;
    procedure Moved; override;
  public
    constructor Create;
    { Shows the page whose name is Name ("display"); False if none is. }
    function ShowPageNamed(const Name: string): Boolean;
    procedure ShowPage(Index: LongInt);
    procedure TellPlaces;
  end;

implementation

uses
  SysUtils,
  Windowing.Protocol,
  Windowing.Connection,
  Windowing.Windows,
  Windowing.Theme,
  Windowing.Displays,
  Controls.Dialogs,
  Controls.CommonDialogs,
  ControlPanel.DisplayPage,
  ControlPanel.MousePage,
  ControlPanel.KeyboardPage,
  ControlPanel.SoundPage,
  ControlPanel.UsersPage,
  ControlPanel.Report;

const
  ListWidth = 150;
  WindowWidth = DialogMargin + ListWidth + 8 + PageWidth + DialogMargin;
  WindowHeight = DialogMargin + PageHeight + 10 + DialogButtonHeight + DialogMargin;
  ClockTimer = 1;

function CentredLeft: LongInt;
begin
  ConnectToDisplay;
  Result := (PixelsToLogical(ScreenWidth, DefaultScale) - WindowWidth) div 2;
  if Result < 0 then
    Result := 0;
end;

function CentredTop: LongInt;
begin
  ConnectToDisplay;
  Result := (PixelsToLogical(ScreenHeight, DefaultScale) - WindowHeight) div 3;
  if Result < 0 then
    Result := 0;
end;

constructor TControlPanelWindow.Create;
var
  ButtonTop: LongInt;
  ButtonLeft: LongInt;
begin
  inherited Create('Control Panel', CentredLeft, CentredTop, WindowWidth, WindowHeight, WindowFramed);
  FPageList := TListBox.Create(Root);
  FPageList.SetBounds(DialogMargin, DialogMargin + 6, ListWidth, PageHeight - 6);
  AddPage(TDisplayPage.CreatePage(Root, Self, 'Display'));
  AddPage(TMousePage.CreatePage(Root, Self, 'Mouse'));
  AddPage(TKeyboardPage.CreatePage(Root, Self, 'Keyboard'));
  AddPage(TSoundPage.CreatePage(Root, Self, 'Sound'));
  FDateTimePage := TDateTimePage.CreatePage(Root, Self, 'Date and Time');
  AddPage(FDateTimePage);
  AddPage(TUsersPage.CreatePage(Root, Self, 'Users'));
  FPageList.OnChange := @PageChosen;
  ButtonTop := WindowHeight - DialogMargin - DialogButtonHeight;
  ButtonLeft := WindowWidth - DialogMargin - 3 * DialogButtonWidth - 2 * DialogButtonGap;
  FOkButton := TButton.Create(Root);
  FOkButton.Text := 'OK';
  FOkButton.IsDefault := True;
  FOkButton.SetBounds(ButtonLeft, ButtonTop, DialogButtonWidth, DialogButtonHeight);
  FOkButton.OnClick := @OkClicked;
  FCancelButton := TButton.Create(Root);
  FCancelButton.Text := 'Cancel';
  FCancelButton.SetBounds(ButtonLeft + DialogButtonWidth + DialogButtonGap, ButtonTop, DialogButtonWidth,
    DialogButtonHeight);
  FCancelButton.OnClick := @CancelClicked;
  FApplyButton := TButton.Create(Root);
  FApplyButton.Text := '&Apply';
  FApplyButton.SetBounds(ButtonLeft + 2 * (DialogButtonWidth + DialogButtonGap), ButtonTop, DialogButtonWidth,
    DialogButtonHeight);
  FApplyButton.OnClick := @ApplyClicked;
  FApplyButton.Enabled := False;
  DefaultControl := FOkButton;
  CancelControl := FCancelButton;
  FCurrent := -1;
  StartTimer(ClockTimer, 1000);
end;

procedure TControlPanelWindow.AddPage(Page: TSettingsPage);
begin
  Page.SetBounds(DialogMargin + ListWidth + 8, DialogMargin, PageWidth, PageHeight);
  Page.Visible := False;
  Page.OnModified := @PageModified;
  SetLength(FPages, Length(FPages) + 1);
  FPages[High(FPages)] := Page;
  FPageList.Items.Add(Page.Text);
end;

procedure TControlPanelWindow.ShowPage(Index: LongInt);
begin
  if (Index < 0) or (Index > High(FPages)) then
    Exit;
  if (FCurrent >= 0) and (FCurrent <> Index) then
    FPages[FCurrent].Visible := False;
  if FCurrent <> Index then
  begin
    FCurrent := Index;
    if not FPages[Index].Modified then
      FPages[Index].Load;
    FPages[Index].Visible := True;
    FPages[Index].Shown;
  end;
  if FPageList.ItemIndex <> Index then
  begin
    FFollowingList := True;
    FPageList.ItemIndex := Index;
    FFollowingList := False;
  end;
  Say('page ' + FPages[Index].PageName);
  TellPlaces;
end;

function TControlPanelWindow.ShowPageNamed(const Name: string): Boolean;
var
  Index: LongInt;
begin
  for Index := 0 to High(FPages) do
    if (FPages[Index].PageName = Name) or ((Name = 'date') and (FPages[Index].PageName = 'datetime')) then
    begin
      ShowPage(Index);
      Exit(True);
    end;
  Result := False;
end;

procedure TControlPanelWindow.PageChosen(Sender: TControl);
begin
  if not FFollowingList then
    ShowPage(FPageList.ItemIndex);
end;

procedure TControlPanelWindow.PageModified(Sender: TControl);
begin
  UpdateApplyButton;
end;

procedure TControlPanelWindow.UpdateApplyButton;
var
  Index: LongInt;
  AnyModified: Boolean;
begin
  AnyModified := False;
  for Index := 0 to High(FPages) do
    if FPages[Index].Modified then
      AnyModified := True;
  FApplyButton.Enabled := AnyModified;
end;

function TControlPanelWindow.ApplyAll: Boolean;
var
  Index: LongInt;
begin
  Result := True;
  for Index := 0 to High(FPages) do
    if FPages[Index].Modified and not FPages[Index].Apply then
      Result := False;
  UpdateApplyButton;
end;

procedure TControlPanelWindow.ApplyClicked(Sender: TControl);
begin
  ApplyAll;
  TellPlaces;
end;

procedure TControlPanelWindow.OkClicked(Sender: TControl);
begin
  if ApplyAll then
  begin
    Say('closed');
    QuitMessageLoop(0);
  end;
end;

procedure TControlPanelWindow.CancelClicked(Sender: TControl);
begin
  Say('cancelled');
  QuitMessageLoop(0);
end;

procedure TControlPanelWindow.CloseRequested;
begin
  Say('closed');
  QuitMessageLoop(0);
end;

procedure TControlPanelWindow.TimerFired(Timer: LongWord);
begin
  if Timer = ClockTimer then
  begin
    if FPages[FCurrent] = FDateTimePage then
      FDateTimePage.Tick;
  end
  else
    inherited TimerFired(Timer);
end;

procedure TControlPanelWindow.KeepInWorkArea;
var
  AreaLeft, AreaTop, AreaWidth, AreaHeight: LongInt;
  Left: LongInt;
  Top: LongInt;
  FrameTop: LongInt;
begin
  if not DescribeWorkArea(0, AreaLeft, AreaTop, AreaWidth, AreaHeight) then
    Exit;
  Left := ScreenLeft;
  Top := ScreenTop;
  FrameTop := Theme.TitleHeight + Theme.BorderWidth;
  if Left + ClientWidth + Theme.BorderWidth > AreaLeft + AreaWidth then
    Left := AreaLeft + AreaWidth - ClientWidth - Theme.BorderWidth;
  if Left - Theme.BorderWidth < AreaLeft then
    Left := AreaLeft + Theme.BorderWidth;
  if Top + ClientHeight + Theme.BorderWidth > AreaTop + AreaHeight then
    Top := AreaTop + AreaHeight - ClientHeight - Theme.BorderWidth;
  if Top - FrameTop < AreaTop then
    Top := AreaTop + FrameTop;
  if (Left <> ScreenLeft) or (Top <> ScreenTop) then
    MoveTo(Left, Top);
end;

procedure TControlPanelWindow.ScaleChanged;
begin
  inherited ScaleChanged;
  Say('scale ' + IntToStr(DisplayScale));
  { A denser display has fewer logical units: this window, which the
    user is changing the scale from, keeps itself in view, so its
    buttons can still be pressed. }
  KeepInWorkArea;
end;

procedure TControlPanelWindow.Resized;
begin
  inherited Resized;
  { A new scale moves everything: say where it is now. }
  if Visible and (FCurrent >= 0) then
    TellPlaces;
end;

procedure TControlPanelWindow.Moved;
begin
  inherited Moved;
  { The server moved it (a smaller mode): its controls moved too. }
  if Visible and (FCurrent >= 0) then
    TellPlaces;
end;

procedure TControlPanelWindow.TellPlaces;
var
  Index: LongInt;
  RowMiddle: LongInt;
begin
  { The window's places move with it: after a new scale too. }
  PrepareToReceive;
  for Index := 0 to High(FPages) do
  begin
    RowMiddle := 2 + Index * FPageList.ItemHeight + FPageList.ItemHeight div 2;
    SayPlace('page-' + FPages[Index].PageName, Self, FPageList, Scaled(30), RowMiddle);
  end;
  SayControlPlace('ok', Self, FOkButton);
  SayControlPlace('cancel', Self, FCancelButton);
  SayControlPlace('apply', Self, FApplyButton);
  if FCurrent >= 0 then
    FPages[FCurrent].TellPlaces;
end;

end.
