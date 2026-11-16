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
  The Network page's IPv6 tab: how the chosen interface gets its IPv6
  addresses (from routers, a fixed address with an optional gateway, or
  no IPv6 at all), and the addresses and router it has now. The page
  keeps what is chosen per interface (TIpv6Choice) and asks the tab to
  show one and to read it back after a change. Sizes are logical units,
  scaled by the controls.
}
unit ControlPanel.Ipv6Tab;

{$mode objfpc}
{$H+}

interface

uses
  Windowing.Windows,
  Controls.Base,
  Controls.Labels,
  Controls.EditBox,
  Controls.Toggles,
  Configuration.NetworkSettings,
  Configuration.NetworkStatus;

type
  { The IPv6 boxes of one interface as typed. }
  TIpv6Choice = record
    Method: TIpv6Method;
    { "fd00::10/64". }
    AddressText: string;
    GatewayText: string;
  end;

  TIpv6Tab = class
  private
    FAutomatic: TRadioButton;
    FStatic: TRadioButton;
    FOff: TRadioButton;
    FAddress: TEditBox;
    FGateway: TEditBox;
    FGlobalAddresses: TLabel;
    FLinkLocalAddresses: TLabel;
    FRouter: TLabel;
  public
    { Puts the controls on Tab; Handler hears of every change. }
    constructor Create(Tab: TControl; Handler: TControlEvent);
    procedure ShowChoice(const Choice: TIpv6Choice);
    function ReadChoice: TIpv6Choice;
    { Nothing chosen: the controls are cleared. }
    procedure ShowNoChoice;
    procedure UpdateEnabledControls(HasInterface: Boolean);
    procedure ShowStatus(const Status: TInterfaceStatus);
    procedure ShowNoStatus;
    procedure TellPlaces(Window: TWindow);
  end;

function Ipv6ChoiceFromSettings(const Settings: TInterfaceSettings): TIpv6Choice;

implementation

uses
  SysUtils,
  Abi.SystemCalls,
  Windowing.Connection,
  ControlPanel.Report;

const
  TabMargin = 8;
  IndentedLeft = 30;
  BoxLeft = 110;
  BoxWidth = 260;
  BoxHeight = 22;
  ChoiceWidth = 380;
  ChoiceHeight = 20;
  StatusTop = 146;
  StatusRowHeight = 16;
  CaptionWidth = 90;
  StatusWidth = 330;
  NoValue = '-';

function Ipv6ChoiceFromSettings(const Settings: TInterfaceSettings): TIpv6Choice;
begin
  Result.Method := Settings.Ipv6Method;
  Result.AddressText := Settings.Ipv6Address;
  Result.GatewayText := Settings.Ipv6Gateway;
end;

function MakeChoice(Parent: TControl; const Text: string; Top: LongInt; Handler: TControlEvent): TRadioButton;
begin
  Result := TRadioButton.Create(Parent);
  Result.Text := Text;
  Result.SetBounds(TabMargin, Top, ChoiceWidth, ChoiceHeight);
  Result.OnChange := Handler;
end;

function MakeBox(Parent: TControl; Top: LongInt; Handler: TControlEvent): TEditBox;
begin
  Result := TEditBox.Create(Parent);
  Result.SetBounds(BoxLeft, Top, BoxWidth, BoxHeight);
  Result.OnChange := Handler;
end;

function MakeLabel(Parent: TControl; const Text: string; Left, Top, Width: LongInt): TLabel;
begin
  Result := TLabel.Create(Parent);
  Result.ShowsMnemonic := False;
  Result.Text := Text;
  Result.SetBounds(Left, Top, Width, StatusRowHeight);
end;

constructor TIpv6Tab.Create(Tab: TControl; Handler: TControlEvent);
begin
  inherited Create;
  FAutomatic := MakeChoice(Tab, '&Get IPv6 addresses from routers automatically', 8, Handler);
  FStatic := MakeChoice(Tab, 'Use a &fixed IPv6 address:', 32, Handler);
  MakeLabel(Tab, 'Address:', IndentedLeft, 60, BoxLeft - IndentedLeft - 4);
  FAddress := MakeBox(Tab, 58, Handler);
  MakeLabel(Tab, 'Gateway:', IndentedLeft, 88, BoxLeft - IndentedLeft - 4);
  FGateway := MakeBox(Tab, 86, Handler);
  FOff := MakeChoice(Tab, 'Turn IPv6 off on this &interface', 116, Handler);
  MakeLabel(Tab, 'Addresses:', TabMargin, StatusTop, CaptionWidth);
  FGlobalAddresses := MakeLabel(Tab, NoValue, TabMargin + CaptionWidth, StatusTop, StatusWidth);
  MakeLabel(Tab, 'Link-local:', TabMargin, StatusTop + StatusRowHeight, CaptionWidth);
  FLinkLocalAddresses := MakeLabel(Tab, NoValue, TabMargin + CaptionWidth, StatusTop + StatusRowHeight,
    StatusWidth);
  MakeLabel(Tab, 'Router:', TabMargin, StatusTop + 2 * StatusRowHeight, CaptionWidth);
  FRouter := MakeLabel(Tab, NoValue, TabMargin + CaptionWidth, StatusTop + 2 * StatusRowHeight, StatusWidth);
end;

procedure TIpv6Tab.ShowChoice(const Choice: TIpv6Choice);
begin
  FAutomatic.Checked := Choice.Method = Ipv6MethodAuto;
  FStatic.Checked := Choice.Method = Ipv6MethodStatic;
  FOff.Checked := Choice.Method = Ipv6MethodNone;
  FAddress.Text := Choice.AddressText;
  FGateway.Text := Choice.GatewayText;
end;

function TIpv6Tab.ReadChoice: TIpv6Choice;
begin
  if FStatic.Checked then
    Result.Method := Ipv6MethodStatic
  else if FOff.Checked then
    Result.Method := Ipv6MethodNone
  else
    Result.Method := Ipv6MethodAuto;
  Result.AddressText := Trim(FAddress.Text);
  Result.GatewayText := Trim(FGateway.Text);
end;

procedure TIpv6Tab.ShowNoChoice;
begin
  FAddress.Text := '';
  FGateway.Text := '';
end;

procedure TIpv6Tab.UpdateEnabledControls(HasInterface: Boolean);
var
  IsStatic: Boolean;
begin
  IsStatic := HasInterface and FStatic.Checked;
  FAutomatic.Enabled := HasInterface;
  FStatic.Enabled := HasInterface;
  FOff.Enabled := HasInterface;
  FAddress.Enabled := IsStatic;
  FGateway.Enabled := IsStatic;
end;

function ListOrNoValue(const Items: array of string): string;
var
  Index: Integer;
begin
  Result := '';
  for Index := 0 to High(Items) do
  begin
    if Result <> '' then
      Result := Result + ', ';
    Result := Result + Items[Index];
  end;
  if Result = '' then
    Result := NoValue;
end;

procedure TIpv6Tab.ShowStatus(const Status: TInterfaceStatus);
var
  LinkLocal: array of string;
  Index: Integer;
begin
  LinkLocal := nil;
  for Index := 0 to High(Status.Ipv6Addresses) do
    if Status.Ipv6Addresses[Index].IsLinkLocal then
    begin
      SetLength(LinkLocal, Length(LinkLocal) + 1);
      LinkLocal[High(LinkLocal)] := AddressWithoutPrefix(Status.Ipv6Addresses[Index].Text);
    end;
  FGlobalAddresses.Text := ListOrNoValue(GlobalIpv6Addresses(Status));
  FLinkLocalAddresses.Text := ListOrNoValue(LinkLocal);
  if Status.Ipv6Router = '' then
    FRouter.Text := NoValue
  else
    FRouter.Text := Status.Ipv6Router;
end;

procedure TIpv6Tab.ShowNoStatus;
begin
  FGlobalAddresses.Text := NoValue;
  FLinkLocalAddresses.Text := NoValue;
  FRouter.Text := NoValue;
end;

procedure TIpv6Tab.TellPlaces(Window: TWindow);
begin
  SayPlace('network-ipv6-auto', Window, FAutomatic, Scaled(6), Scaled(ChoiceHeight div 2));
  SayPlace('network-ipv6-static', Window, FStatic, Scaled(6), Scaled(ChoiceHeight div 2));
  SayPlace('network-ipv6-none', Window, FOff, Scaled(6), Scaled(ChoiceHeight div 2));
  SayControlPlace('network-ipv6-address', Window, FAddress);
  SayControlPlace('network-ipv6-gateway', Window, FGateway);
end;

end.
