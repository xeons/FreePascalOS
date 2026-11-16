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
  { One interface: its picture, then two lines of text, and a third for
    its IPv6 addresses if it has global ones. }
  TNetworkRow = class(TControl)
  private
    FPicture: LongWord;
    FHeading: string;
    FDetail: string;
    FIpv6Detail: string;
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

{ The global IPv6 addresses without their prefixes, comma separated. }
function Ipv6AddressesText(const Status: TInterfaceStatus): string;
var
  Addresses: TStringArray;
  Index: Integer;
begin
  Result := '';
  Addresses := GlobalIpv6Addresses(Status);
  for Index := 0 to High(Addresses) do
  begin
    if Result <> '' then
      Result := Result + ', ';
    Result := Result + AddressWithoutPrefix(Addresses[Index]);
  end;
end;

{ Logical units: two lines, or three with IPv6 addresses. }
function RowHeightFor(const Status: TInterfaceStatus): LongInt;
begin
  Result := NetworkRowHeight;
  if Ipv6AddressesText(Status) <> '' then
    Result := Result + LineHeight;
end;

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
  FIpv6Detail := Ipv6AddressesText(Status);
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
  if FIpv6Detail <> '' then
    DrawTextInBox(Canvas, ControlFace, FIpv6Detail, MakeRectangle(Scaled(TextLeft), Scaled(2 * LineHeight),
      Width - Scaled(TextLeft), Scaled(LineHeight)), AlignTextLeft, Theme.FaceText);
end;

constructor TNetworkPopup.CreateNetworkPopup(AOwner: TControlWindow; Left, Bottom: LongInt);
var
  Top: LongInt;
  Height: LongInt;
  RowsHeight: LongInt;
  RowTop: LongInt;
  Index: LongInt;
  Frame: TPanel;
  Caption: TLabel;
  Row: TNetworkRow;
begin
  if ListInterfaceStatus(FList) <> ErrorNone then
    FList := nil;
  RowsHeight := 0;
  for Index := 0 to High(FList) do
    RowsHeight := RowsHeight + RowHeightFor(FList[Index]);
  if RowsHeight = 0 then
    RowsHeight := NetworkRowHeight;
  Height := Margin + CaptionHeight + RowsHeight + ButtonHeight + Margin;
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
  RowTop := Margin + CaptionHeight;
  for Index := 0 to High(FList) do
  begin
    Row := TNetworkRow.Create(Root);
    Row.SetBounds(Margin, RowTop, PopupWidth - 2 * Margin, RowHeightFor(FList[Index]) - 4);
    Row.ShowStatus(FList[Index]);
    RowTop := RowTop + RowHeightFor(FList[Index]);
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
  begin
    Say('network-popup-row ' + FList[Index].Name + ' ' + InterfaceSummary(FList[Index]));
    if Ipv6AddressesText(FList[Index]) <> '' then
      Say('network-popup-ipv6 ' + FList[Index].Name + ' ' + Ipv6AddressesText(FList[Index]));
  end;
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
