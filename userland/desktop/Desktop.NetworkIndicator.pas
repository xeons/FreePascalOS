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
  The network's notification icon: how the best connected interface is
  doing (Configuration.NetworkStatus) - connected, with its address in
  the tooltip ("eth0: 10.0.2.15 - connected"), connecting, linked but
  without an address, no cable (crossed out), or no network adapter at
  all. The shell shows it through the same interface as any program
  (Windowing.Notifications).

  The network service's state folder is watched, so a new address or a
  lost lease shows at once; the kernel's link is looked at every second
  (Refresh, from the taskbar's clock), so a cable pulled out shows too.
}
unit Desktop.NetworkIndicator;

{$mode objfpc}
{$H+}

interface

uses
  Configuration.NetworkStatus;

type
  TNetworkIndicator = class
  private
    FShownTooltip: string;
    FShownPicture: LongWord;
    FWatch: Int64;
    procedure StartWatching;
    procedure StopWatching;
    procedure StateFolderChanged(Handle: Int64);
  public
    constructor Create;
    destructor Destroy; override;
    { Shows the icon as the network is now, if that changed. }
    procedure Refresh;
  end;

{ True for the pictures the network icon shows (a click on one opens
  the list of interfaces). }
function IsNetworkPicture(Picture: LongWord): Boolean;
{ The picture (NotificationPicture*) for an interface in Condition. }
function NetworkPictureFor(Condition: TNetworkCondition): LongWord;

implementation

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Objects,
  Windowing.Protocol,
  Windowing.Notifications,
  Windowing.HandleWatches;

const
  NetworkIconNumber = 2;
  NoWatch = -1;

function IsNetworkPicture(Picture: LongWord): Boolean;
begin
  Result := Picture in [NotificationPictureNetwork, NotificationPictureNetworkConnecting,
    NotificationPictureNetworkLimited, NotificationPictureNetworkNoLink, NotificationPictureNetworkNone];
end;

function NetworkPictureFor(Condition: TNetworkCondition): LongWord;
begin
  case Condition of
    ConditionConnected: Result := NotificationPictureNetwork;
    ConditionConnecting: Result := NotificationPictureNetworkConnecting;
    ConditionFailed: Result := NotificationPictureNetworkLimited;
  else
    { No cable, turned off, or never configured: not connected. }
    Result := NotificationPictureNetworkNoLink;
  end;
end;

constructor TNetworkIndicator.Create;
begin
  inherited Create;
  FWatch := NoWatch;
end;

destructor TNetworkIndicator.Destroy;
begin
  StopWatching;
  inherited Destroy;
end;

procedure TNetworkIndicator.StartWatching;
begin
  if FWatch <> NoWatch then
    Exit;
  FWatch := WatchNetworkState;
  if FWatch < 0 then
    FWatch := NoWatch
  else if not WatchHandle(FWatch, @StateFolderChanged) then
    StopWatching;
end;

procedure TNetworkIndicator.StopWatching;
begin
  if FWatch = NoWatch then
    Exit;
  StopWatchingHandle(FWatch);
  CloseHandle(FWatch);
  FWatch := NoWatch;
end;

procedure TNetworkIndicator.StateFolderChanged(Handle: Int64);
begin
  { The folder went: watched again by a later Refresh, once it is back. }
  if not TakeNetworkStateChanges(Handle) then
    StopWatching;
  Refresh;
end;

procedure TNetworkIndicator.Refresh;
var
  List: TInterfaceStatusList;
  Best: LongInt;
  Tooltip: string;
  Picture: LongWord;
begin
  StartWatching;
  if ListInterfaceStatus(List) <> ErrorNone then
    List := nil;
  Best := FindBestInterface(List);
  if Best < 0 then
  begin
    Tooltip := 'No network adapters';
    Picture := NotificationPictureNetworkNone;
  end
  else
  begin
    Tooltip := InterfaceSummary(List[Best]);
    Picture := NetworkPictureFor(List[Best].Condition);
  end;
  if (Tooltip = FShownTooltip) and (Picture = FShownPicture) then
    Exit;
  FShownTooltip := Tooltip;
  FShownPicture := Picture;
  ShowNotificationIcon(NetworkIconNumber, Picture, PChar(Tooltip));
end;

end.
