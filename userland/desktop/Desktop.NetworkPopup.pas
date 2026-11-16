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
  What the network icon opens: a small pop-up above the taskbar listing
  the network interfaces, each with the picture of its state, its name
  and state, and its address and adapter (Configuration.NetworkStatus),
  and a button that opens the Control Panel's Network page. A press
  outside it closes it, like a menu.

  It says "network-popup" when it opens, "network-popup-row NAME
  SUMMARY" for each interface, and where its button is ("place
  network-settings X Y").
}
unit Desktop.NetworkPopup;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Canvas,
  Controls.Base,
  Controls.Window,
  Controls.Popups,
  Controls.Buttons,
  Configuration.NetworkStatus;

type
  { One interface: its picture, then two lines of text. }
  TNetworkRow = class(TControl)
  private
    FPicture: LongWord;
    FHeading: string;
    FDetail: string;
  protected
    procedure Paint(var Canvas: TCanvas); override;
  public
    procedure ShowStatus(const Status: TInterfaceStatus);
  end;

  TNetworkPopup = class(TPopupWindow)
  private
    FSettingsButton: TButton;
    FList: TInterfaceStatusList;
    procedure SettingsClicked(Sender: TControl);
  public
    { Above the point (Left, Bottom) of the screen, logical units. }
    constructor CreateNetworkPopup(AOwner: TControlWindow; Left, Bottom: LongInt);
    procedure Open;
  end;

implementation

uses
  SysUtils,
  Abi.SystemCalls,
  Drawing.Rectangles,
  Windowing.Connection,
  Windowing.Displays,
  Windowing.Theme,
  Controls.Text,
  Controls.Labels,
  Controls.Panels,
  Desktop.SmallPictures,
  Desktop.NetworkIndicator,
  Desktop.Programs,
  Desktop.Report;

const
  { Logical units. }
  PopupWidth = 280;
  Margin = 10;
  CaptionHeight = 20;
  NetworkRowHeight = 36;
  PictureSize = 16;
  TextLeft = PictureSize + 8;
  LineHeight = 16;
  ButtonWidth = 130;
  ButtonHeight = 23;

function CapitalizedCondition(Condition: TNetworkCondition): string;
var
  Text: string;
begin
  Text := NetworkConditionText(Condition);
  Result := UpperCase(Copy(Text, 1, 1)) + Copy(Text, 2, Length(Text));
end;

procedure TNetworkRow.ShowStatus(const Status: TInterfaceStatus);
begin
  FPicture := NetworkPictureFor(Status.Condition);
  FHeading := Status.Name + ' ' + EmDash + ' ' + CapitalizedCondition(Status.Condition);
  if Status.Address <> '' then
    FDetail := Status.Address + ', ' + Status.Description
  else
    FDetail := Status.Description;
  Invalidate;
end;

procedure TNetworkRow.Paint(var Canvas: TCanvas);
var
  Width: LongInt;
begin
  Width := RectangleWidth(PixelBounds);
  DrawNotificationPicture(Canvas, FPicture, MakeRectangle(0, Scaled(2), Scaled(PictureSize), Scaled(PictureSize)));
  DrawTextInBox(Canvas, ControlBoldFace, FHeading, MakeRectangle(Scaled(TextLeft), 0, Width - Scaled(TextLeft),
    Scaled(LineHeight)), AlignTextLeft, Theme.FaceText);
  DrawTextInBox(Canvas, ControlFace, FDetail, MakeRectangle(Scaled(TextLeft), Scaled(LineHeight),
    Width - Scaled(TextLeft), Scaled(LineHeight)), AlignTextLeft, Theme.FaceText);
end;

constructor TNetworkPopup.CreateNetworkPopup(AOwner: TControlWindow; Left, Bottom: LongInt);
var
  Top: LongInt;
  Height: LongInt;
  RowCount: LongInt;
  Index: LongInt;
  Frame: TPanel;
  Caption: TLabel;
  Row: TNetworkRow;
begin
  if ListInterfaceStatus(FList) <> ErrorNone then
    FList := nil;
  RowCount := Length(FList);
  if RowCount = 0 then
    RowCount := 1;
  Height := Margin + CaptionHeight + RowCount * NetworkRowHeight + ButtonHeight + Margin;
  Left := Left - PopupWidth div 2;
  Top := Bottom - Height;
  KeepOnDisplay(Left, Top, PopupWidth, Height);
  inherited CreatePopup(AOwner, Left, Top, PopupWidth, Height);
  { A raised edge, as a menu has, sets it off from what is behind. }
  Frame := TPanel.Create(Root);
  Frame.Edge := PanelRaised;
  Frame.Align := AlignClient;
  Caption := TLabel.Create(Root);
  Caption.ShowsMnemonic := False;
  Caption.Text := 'Network';
  Caption.SetBounds(Margin, Margin, PopupWidth - 2 * Margin, 18);
  if Length(FList) = 0 then
  begin
    Caption := TLabel.Create(Root);
    Caption.ShowsMnemonic := False;
    Caption.Text := 'No network adapters.';
    Caption.SetBounds(Margin, Margin + CaptionHeight, PopupWidth - 2 * Margin, 18);
  end;
  for Index := 0 to High(FList) do
  begin
    Row := TNetworkRow.Create(Root);
    Row.SetBounds(Margin, Margin + CaptionHeight + Index * NetworkRowHeight, PopupWidth - 2 * Margin,
      NetworkRowHeight - 4);
    Row.ShowStatus(FList[Index]);
  end;
  FSettingsButton := TButton.Create(Root);
  FSettingsButton.Text := '&Network settings...';
  FSettingsButton.SetBounds(PopupWidth - Margin - ButtonWidth, Height - Margin - ButtonHeight, ButtonWidth,
    ButtonHeight);
  FSettingsButton.OnClick := @SettingsClicked;
end;

procedure TNetworkPopup.Open;
var
  Index: LongInt;
begin
  Popup;
  Say('network-popup');
  for Index := 0 to High(FList) do
    Say('network-popup-row ' + FList[Index].Name + ' ' + InterfaceSummary(FList[Index]));
  PrepareToReceive;
  SayPlace('network-settings', Self, (FSettingsButton.PixelBounds.Left + FSettingsButton.PixelBounds.Right) div 2,
    (FSettingsButton.PixelBounds.Top + FSettingsButton.PixelBounds.Bottom) div 2);
end;

procedure TNetworkPopup.SettingsClicked(Sender: TControl);
begin
  { Nothing of the pop-up is touched after this: it is freed later. }
  Dismiss;
  StartCommand('controlpanel', 'network', 'Control Panel');
end;

end.
