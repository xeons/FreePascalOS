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
  The Network page: the network interfaces (each with its adapter,
  Ethernet address, link and state), and for the one chosen three tabs:

    Address  turned on or not; an address from DHCP, this address (with
             its prefix or netmask, and a gateway), or left alone
    DNS      the DNS servers from DHCP or these, and the search domain
             (the same for every interface)
    Status   how it is doing now (ControlPanel.NetworkDetails)

  The settings shown are /etc/settings/Network.settings
  (Configuration.NetworkSettings); the state and the counters come from
  the network service and the kernel (Configuration.NetworkStatus), and
  are shown again every second and whenever the service's state folder
  changes. Each interface remembers what was chosen for it until Apply,
  so moving between them loses nothing. Applying checks the values
  (saying what is wrong), then sends them to the system settings
  service as an administrator; it checks them again and writes the
  file, which the network service applies at once.
}
unit ControlPanel.NetworkPage;

{$mode objfpc}
{$H+}

interface

uses
  Controls.Base,
  Controls.Window,
  Controls.Labels,
  Controls.EditBox,
  Controls.Toggles,
  Controls.ListView,
  Controls.TabControl,
  Configuration.NetworkSettings,
  Configuration.NetworkStatus,
  ControlPanel.Pages,
  ControlPanel.NetworkDetails,
  ControlPanel.Ipv6Tab;

type
  { What is chosen for one interface: the boxes as typed. }
  TInterfaceChoice = record
    Name: string;
    Loaded: TInterfaceSettings;
    Method: TNetworkMethod;
    Up: Boolean;
    AddressText: string;
    PrefixText: string;
    GatewayText: string;
    Ipv6: TIpv6Choice;
    Changed: Boolean;
  end;

  TNetworkPage = class(TSettingsPage)
  private
    FList: TListView;
    FTabs: TTabControl;
    FEnabled: TCheckBox;
    FDhcp: TRadioButton;
    FStatic: TRadioButton;
    FNone: TRadioButton;
    FAddress: TEditBox;
    FPrefix: TEditBox;
    FGateway: TEditBox;
    FDnsAutomatic: TRadioButton;
    FDnsManual: TRadioButton;
    FDnsServers: TEditBox;
    FSearchDomain: TEditBox;
    FDetails: TNetworkDetails;
    FIpv6Tab: TIpv6Tab;
    FStatus: TInterfaceStatusList;
    FChoices: array of TInterfaceChoice;
    { The interface whose choice the controls show, -1 for none. }
    FShown: LongInt;
    FLoadedDns: TDnsSettings;
    FDnsChanged: Boolean;
    { The controls are being filled: not the user's changes. }
    FFilling: Boolean;
    FWatch: Int64;
    { What was said last about each interface's state. }
    FReportedStates: array of string;
    procedure MakeAddressTab(Tab: TControl);
    procedure MakeDnsTab(Tab: TControl);
    procedure InterfaceChosen(Sender: TControl);
    procedure AddressChanged(Sender: TControl);
    procedure DnsChanged(Sender: TControl);
    procedure ShowChoice;
    procedure ShowDns;
    procedure UpdateEnabledControls;
    procedure RefreshStatus;
    procedure ShowStatusRows;
    procedure ReportStates;
    procedure StartWatching;
    procedure StopWatching;
    procedure StateFolderChanged(Handle: Int64);
    function IndexOfStatus(const Name: string): LongInt;
    function ApplyInterface(var Choice: TInterfaceChoice): Boolean;
    function ApplyDns: Boolean;
  protected
    procedure LoadSettings; override;
  public
    constructor CreatePage(AParent: TControl; AWindow: TControlWindow; const ATitle: string); override;
    destructor Destroy; override;
    function PageName: string; override;
    function Apply: Boolean; override;
    procedure TellPlaces; override;
    procedure Tick; override;
  end;

implementation

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Objects,
  Sys.SystemSettings,
  Windowing.Connection,
  Windowing.HandleWatches,
  Drawing.Rectangles,
  Configuration.Settings,
  Configuration.Locations,
  Controls.MessageBoxes,
  ControlPanel.Administrator,
  ControlPanel.Report;

const
  ListTop = 26;
  ListHeight = 92;
  TabsTop = ListTop + ListHeight + 8;
  TabsHeight = PageHeight - TabsTop - 8;
  ColumnName = 0;
  ColumnAdapter = 1;
  ColumnHardwareAddress = 2;
  ColumnLink = 3;
  ColumnState = 4;
  { Inside a tab. }
  TabMargin = 8;
  IndentedLeft = 30;
  BoxLeft = 110;
  BoxWidth = 120;
  BoxHeight = 22;
  ChoiceWidth = 380;
  ChoiceHeight = 20;
  NoWatch = -1;
  Title = 'Network';

{ One word for the output: "connected", "no-link"... }
function ConditionToken(Condition: TNetworkCondition): string;
begin
  case Condition of
    ConditionDisabled: Result := 'disabled';
    ConditionNotConfigured: Result := 'unconfigured';
    ConditionNoLink: Result := 'no-link';
    ConditionFailed: Result := 'failed';
    ConditionConnecting: Result := 'connecting';
    ConditionConnected: Result := 'connected';
  else
    Result := 'unknown';
  end;
end;

function MakeCaption(Parent: TControl; const Text: string; Left, Top, Width: LongInt): TLabel;
begin
  Result := TLabel.Create(Parent);
  Result.ShowsMnemonic := False;
  Result.Text := Text;
  Result.SetBounds(Left, Top + 2, Width, 18);
end;

function MakeChoice(Parent: TControl; const Text: string; Top: LongInt; Handler: TControlEvent): TRadioButton;
begin
  Result := TRadioButton.Create(Parent);
  Result.Text := Text;
  Result.SetBounds(TabMargin, Top, ChoiceWidth, ChoiceHeight);
  Result.OnChange := Handler;
end;

function MakeBox(Parent: TControl; Left, Top, Width: LongInt; Handler: TControlEvent): TEditBox;
begin
  Result := TEditBox.Create(Parent);
  Result.SetBounds(Left, Top, Width, BoxHeight);
  Result.OnChange := Handler;
end;

constructor TNetworkPage.CreatePage(AParent: TControl; AWindow: TControlWindow; const ATitle: string);
var
  Tab: TControl;
begin
  inherited CreatePage(AParent, AWindow, ATitle);
  FShown := -1;
  FWatch := NoWatch;
  FList := TListView.Create(Self);
  FList.SetBounds(PageMargin, ListTop, PageWidth - 2 * PageMargin, ListHeight);
  FList.AddColumn('Interface', 54);
  FList.AddColumn('Adapter', 116);
  FList.AddColumn('Ethernet address', 108);
  FList.AddColumn('Link', 40);
  FList.AddColumn('State', 88);
  FList.OnChange := @InterfaceChosen;
  FTabs := TTabControl.Create(Self);
  FTabs.SetBounds(PageMargin, TabsTop, PageWidth - 2 * PageMargin, TabsHeight);
  MakeAddressTab(FTabs.AddPage('Add&ress'));
  FIpv6Tab := TIpv6Tab.Create(FTabs.AddPage('IPv&6'), @AddressChanged);
  MakeDnsTab(FTabs.AddPage('&DNS'));
  Tab := FTabs.AddPage('&Status');
  FDetails := TNetworkDetails.Create(Tab, TabMargin, 4, PageWidth - 2 * PageMargin - 2 * TabMargin - 6);
end;

procedure TNetworkPage.MakeAddressTab(Tab: TControl);
begin
  FEnabled := TCheckBox.Create(Tab);
  FEnabled.Text := 'E&nable this interface';
  FEnabled.SetBounds(TabMargin, 8, 220, ChoiceHeight);
  FEnabled.OnChange := @AddressChanged;
  FDhcp := MakeChoice(Tab, 'Obtain an address a&utomatically (DHCP)', 36, @AddressChanged);
  FStatic := MakeChoice(Tab, 'Use &this address:', 60, @AddressChanged);
  MakeCaption(Tab, 'Address:', IndentedLeft, 86, BoxLeft - IndentedLeft - 4);
  FAddress := MakeBox(Tab, BoxLeft, 86, BoxWidth, @AddressChanged);
  MakeCaption(Tab, 'Prefix or mask:', BoxLeft + BoxWidth + 10, 86, 92);
  FPrefix := MakeBox(Tab, BoxLeft + BoxWidth + 104, 86, 100, @AddressChanged);
  MakeCaption(Tab, 'Gateway:', IndentedLeft, 114, BoxLeft - IndentedLeft - 4);
  FGateway := MakeBox(Tab, BoxLeft, 114, BoxWidth, @AddressChanged);
  FNone := MakeChoice(Tab, '&Leave this interface unconfigured', 146, @AddressChanged);
end;

procedure TNetworkPage.MakeDnsTab(Tab: TControl);
var
  Caption: TLabel;
begin
  MakeCaption(Tab, 'These apply to every interface.', TabMargin, 6, ChoiceWidth);
  FDnsAutomatic := MakeChoice(Tab, 'Obtain DNS servers aut&omatically (DHCP)', 32, @DnsChanged);
  FDnsManual := MakeChoice(Tab, 'Use these DNS ser&vers:', 56, @DnsChanged);
  FDnsServers := MakeBox(Tab, IndentedLeft, 82, ChoiceWidth - IndentedLeft, @DnsChanged);
  MakeCaption(Tab, 'Separate them with commas, such as 10.0.2.3, 9.9.9.9.', IndentedLeft, 106, ChoiceWidth);
  Caption := TLabel.Create(Tab);
  Caption.Text := 'Search do&main:';
  Caption.SetBounds(TabMargin, 142, BoxLeft - TabMargin - 4, 18);
  FSearchDomain := MakeBox(Tab, BoxLeft, 140, ChoiceWidth - BoxLeft + TabMargin, @DnsChanged);
end;

destructor TNetworkPage.Destroy;
begin
  StopWatching;
  FDetails.Free;
  FIpv6Tab.Free;
  inherited Destroy;
end;

function TNetworkPage.PageName: string;
begin
  Result := 'network';
end;

{ --- Watching the network service's state ------------------------------------------- }

procedure TNetworkPage.StartWatching;
begin
  if FWatch <> NoWatch then
    Exit;
  FWatch := WatchNetworkState;
  if FWatch < 0 then
    FWatch := NoWatch
  else if not WatchHandle(FWatch, @StateFolderChanged) then
    StopWatching;
end;

procedure TNetworkPage.StopWatching;
begin
  if FWatch = NoWatch then
    Exit;
  StopWatchingHandle(FWatch);
  CloseHandle(FWatch);
  FWatch := NoWatch;
end;

procedure TNetworkPage.StateFolderChanged(Handle: Int64);
begin
  { The folder went: watched again on a later tick, once it is back. }
  if not TakeNetworkStateChanges(Handle) then
    StopWatching;
  RefreshStatus;
end;

{ --- Showing ------------------------------------------------------------------------- }

function TNetworkPage.IndexOfStatus(const Name: string): LongInt;
var
  Index: LongInt;
begin
  for Index := 0 to High(FStatus) do
    if FStatus[Index].Name = Name then
      Exit(Index);
  Result := -1;
end;

procedure TNetworkPage.ShowStatusRows;
var
  Index: LongInt;
  Link: string;
begin
  for Index := 0 to High(FStatus) do
  begin
    if Index >= FList.RowCount then
      Break;
    if FStatus[Index].LinkUp then
      Link := 'Up'
    else
      Link := 'Down';
    FList.Cells[Index, ColumnLink] := Link;
    FList.Cells[Index, ColumnState] := NetworkConditionText(FStatus[Index].Condition);
  end;
  if (FShown >= 0) and (FShown <= High(FStatus)) then
  begin
    FDetails.ShowStatus(FStatus[FShown]);
    FIpv6Tab.ShowStatus(FStatus[FShown]);
  end
  else
  begin
    FDetails.ShowNothing;
    FIpv6Tab.ShowNoStatus;
  end;
end;

procedure TNetworkPage.ReportStates;
var
  Index: LongInt;
  Line: string;
begin
  SetLength(FReportedStates, Length(FStatus));
  for Index := 0 to High(FStatus) do
  begin
    Line := Format('%s %s %s', [FStatus[Index].Name, ConditionToken(FStatus[Index].Condition),
      FStatus[Index].Address]);
    if Line <> FReportedStates[Index] then
      Say('network-state ' + Trim(Line));
    FReportedStates[Index] := Line;
  end;
end;

{ The interfaces stay as listed (new ones show at the next Load); their
  state and counters are looked at again. }
procedure TNetworkPage.RefreshStatus;
var
  Fresh: TInterfaceStatusList;
  Index: LongInt;
  Found: LongInt;
begin
  if ListInterfaceStatus(Fresh) <> ErrorNone then
    Exit;
  for Index := 0 to High(Fresh) do
  begin
    Found := IndexOfStatus(Fresh[Index].Name);
    if Found >= 0 then
      FStatus[Found] := Fresh[Index];
  end;
  ShowStatusRows;
  ReportStates;
end;

procedure TNetworkPage.UpdateEnabledControls;
var
  HasInterface: Boolean;
  IsStatic: Boolean;
begin
  HasInterface := FShown >= 0;
  IsStatic := HasInterface and FStatic.Checked;
  FEnabled.Enabled := HasInterface;
  FDhcp.Enabled := HasInterface;
  FStatic.Enabled := HasInterface;
  FNone.Enabled := HasInterface;
  FAddress.Enabled := IsStatic;
  FPrefix.Enabled := IsStatic;
  FGateway.Enabled := IsStatic;
  FIpv6Tab.UpdateEnabledControls(HasInterface);
  FDnsServers.Enabled := FDnsManual.Checked;
end;

procedure TNetworkPage.ShowChoice;
begin
  FFilling := True;
  if FShown >= 0 then
  begin
    FEnabled.Checked := FChoices[FShown].Up;
    FDhcp.Checked := FChoices[FShown].Method = NetworkMethodDhcp;
    FStatic.Checked := FChoices[FShown].Method = NetworkMethodStatic;
    FNone.Checked := FChoices[FShown].Method = NetworkMethodNone;
    FAddress.Text := FChoices[FShown].AddressText;
    FPrefix.Text := FChoices[FShown].PrefixText;
    FGateway.Text := FChoices[FShown].GatewayText;
    FIpv6Tab.ShowChoice(FChoices[FShown].Ipv6);
  end
  else
  begin
    FEnabled.Checked := False;
    FAddress.Text := '';
    FPrefix.Text := '';
    FGateway.Text := '';
    FIpv6Tab.ShowNoChoice;
  end;
  FFilling := False;
  UpdateEnabledControls;
end;

procedure TNetworkPage.ShowDns;
begin
  FFilling := True;
  FDnsAutomatic.Checked := Length(FLoadedDns.Servers) = 0;
  FDnsManual.Checked := Length(FLoadedDns.Servers) > 0;
  FDnsServers.Text := JoinServerList(FLoadedDns.Servers);
  FSearchDomain.Text := FLoadedDns.SearchDomain;
  FFilling := False;
  UpdateEnabledControls;
end;

function ChoiceFromSettings(const Settings: TInterfaceSettings): TInterfaceChoice;
begin
  Result := Default(TInterfaceChoice);
  Result.Name := Settings.Name;
  Result.Loaded := Settings;
  Result.Method := Settings.Method;
  Result.Up := Settings.Up;
  SplitAddressAndPrefix(Settings.Address, Result.AddressText, Result.PrefixText);
  Result.GatewayText := Settings.Gateway;
  Result.Ipv6 := Ipv6ChoiceFromSettings(Settings);
end;

procedure TNetworkPage.LoadSettings;
var
  Store: TSettings;
  Index: LongInt;
  Chosen: string;
  Status: TInterfaceStatus;
begin
  Chosen := '';
  if FShown >= 0 then
    Chosen := FChoices[FShown].Name;
  if ListInterfaceStatus(FStatus) <> ErrorNone then
    FStatus := nil;
  Store := OpenSystemSettings;
  try
    SetLength(FChoices, Length(FStatus));
    for Index := 0 to High(FStatus) do
      FChoices[Index] := ChoiceFromSettings(ReadInterfaceSettings(Store, FStatus[Index].Name));
    FLoadedDns := ReadDnsSettings(Store);
  finally
    Store.Free;
  end;
  FDnsChanged := False;
  FFilling := True;
  FList.Clear;
  for Index := 0 to High(FStatus) do
  begin
    Status := FStatus[Index];
    FList.AddRow([Status.Name, Status.Description, Status.HardwareAddress, '', '']);
    Say(Trim(Format('network-interface %s %s %s %s %s', [Status.Name, NetworkMethodName(FChoices[Index].Method),
      BoolToStr(FChoices[Index].Up, 'up', 'down'), ConditionToken(Status.Condition), Status.Address])));
  end;
  FShown := IndexOfStatus(Chosen);
  if (FShown < 0) and (Length(FStatus) > 0) then
    FShown := 0;
  FList.ItemIndex := FShown;
  FFilling := False;
  FReportedStates := nil;
  ShowChoice;
  ShowDns;
  ShowStatusRows;
  ReportStates;
  StartWatching;
end;

{ --- Changes ------------------------------------------------------------------------- }

procedure TNetworkPage.InterfaceChosen(Sender: TControl);
begin
  if FFilling or (FList.ItemIndex = FShown) or (FList.ItemIndex < 0) or (FList.ItemIndex > High(FChoices)) then
    Exit;
  FShown := FList.ItemIndex;
  ShowChoice;
  ShowStatusRows;
  Say('network-chosen ' + FChoices[FShown].Name);
end;

procedure TNetworkPage.AddressChanged(Sender: TControl);
begin
  if FFilling or (FShown < 0) then
    Exit;
  { A radio button being unchecked announces itself too: the one now
    checked says the same a moment later. }
  if FDhcp.Checked then
    FChoices[FShown].Method := NetworkMethodDhcp
  else if FStatic.Checked then
    FChoices[FShown].Method := NetworkMethodStatic
  else
    FChoices[FShown].Method := NetworkMethodNone;
  FChoices[FShown].Up := FEnabled.Checked;
  FChoices[FShown].AddressText := Trim(FAddress.Text);
  FChoices[FShown].PrefixText := Trim(FPrefix.Text);
  FChoices[FShown].GatewayText := Trim(FGateway.Text);
  FChoices[FShown].Ipv6 := FIpv6Tab.ReadChoice;
  FChoices[FShown].Changed := True;
  UpdateEnabledControls;
  MarkModified;
end;

procedure TNetworkPage.DnsChanged(Sender: TControl);
begin
  if FFilling then
    Exit;
  FDnsChanged := True;
  UpdateEnabledControls;
  MarkModified;
end;

{ --- Applying ------------------------------------------------------------------------ }

procedure Complain(Owner: TControlWindow; const Text: string);
begin
  ShowMessageBox(Title, Text, MessageOk, SignWarning, Owner);
end;

{ What Choice's boxes say, as settings; False (Problem set) if the
  address boxes cannot be read for a static address. For DHCP and none
  the boxes are kept only when they are valid. }
function SettingsFromChoice(const Choice: TInterfaceChoice; out Settings: TInterfaceSettings;
  out Problem: TNetworkSettingsProblem): Boolean;
var
  Joined: string;
  AddressValue: LongWord;
begin
  Settings := Default(TInterfaceSettings);
  Settings.Name := Choice.Name;
  Settings.Method := Choice.Method;
  Settings.Up := Choice.Up;
  Settings.Configured := True;
  Settings.Gateway := Choice.GatewayText;
  if (Choice.AddressText <> '') or (Choice.PrefixText <> '') then
  begin
    if JoinAddressAndPrefix(Choice.AddressText, Choice.PrefixText, Joined) then
      Settings.Address := Joined
    else if ParseHostAddress(Choice.AddressText, AddressValue) then
      { The address is good: the check below finds the prefix wanting. }
      Settings.Address := Choice.AddressText
    else
      Settings.Address := Choice.AddressText + '/' + Choice.PrefixText;
  end;
  Settings.Ipv6Method := Choice.Ipv6.Method;
  Settings.Ipv6Address := Choice.Ipv6.AddressText;
  Settings.Ipv6Gateway := Choice.Ipv6.GatewayText;
  Problem := CheckInterfaceSettings(Settings);
  if (Problem in [ProblemNoIpv6Address..ProblemIpv6GatewayIsAddress]) and
     (Settings.Ipv6Method <> Ipv6MethodStatic) then
  begin
    { Boxes of a fixed IPv6 address not chosen are kept only if valid. }
    Settings.Ipv6Address := '';
    Settings.Ipv6Gateway := '';
    Problem := CheckInterfaceSettings(Settings);
  end;
  if (Problem <> NetworkSettingsValid) and (Settings.Method <> NetworkMethodStatic) and
     not (Problem in [ProblemNoIpv6Address..ProblemIpv6GatewayIsAddress]) then
  begin
    Settings.Address := '';
    Settings.Gateway := '';
    Problem := CheckInterfaceSettings(Settings);
  end;
  Result := Problem = NetworkSettingsValid;
end;

function TNetworkPage.ApplyInterface(var Choice: TInterfaceChoice): Boolean;
var
  Settings: TInterfaceSettings;
  Problem: TNetworkSettingsProblem;
  Request: TSystemSettingsRequest;
  Error: LongInt;
  Applied: string;
begin
  if not SettingsFromChoice(Choice, Settings, Problem) then
  begin
    Complain(Window, Choice.Name + ': ' + NetworkSettingsProblemText(Problem));
    Exit(False);
  end;
  Request := NewSystemSettingsRequest(SystemRequestSetNetworkInterface);
  SetRequestText(@Request.NetworkInterface[0], SystemInterfaceNameCapacity, PChar(Settings.Name));
  SetRequestText(@Request.NetworkMethod[0], SystemMethodCapacity, PChar(NetworkMethodName(Settings.Method)));
  SetRequestText(@Request.NetworkAddress[0], SystemAddressCapacity, PChar(Settings.Address));
  SetRequestText(@Request.NetworkGateway[0], SystemAddressCapacity, PChar(Settings.Gateway));
  SetRequestText(@Request.NetworkIpv6Method[0], SystemMethodCapacity, PChar(Ipv6MethodName(Settings.Ipv6Method)));
  SetRequestText(@Request.NetworkIpv6Address[0], SystemIpv6AddressCapacity, PChar(Settings.Ipv6Address));
  SetRequestText(@Request.NetworkIpv6Gateway[0], SystemIpv6AddressCapacity, PChar(Settings.Ipv6Gateway));
  if Settings.Up then
    Request.Flags := SystemFlagInterfaceUp;
  Error := SendAsAdministrator(Window, Request);
  Result := Error = ErrorNone;
  if not Result then
  begin
    if Error <> ErrorInterrupted then
      ShowMessageBox(Title, 'The settings of ' + Settings.Name + ' could not be changed. ' + RefusalText(Error),
        MessageOk, SignError, Window);
    Exit;
  end;
  Choice.Loaded := Settings;
  Choice.Changed := False;
  Applied := 'applied network ' + Settings.Name + ' ' + NetworkMethodName(Settings.Method);
  if Settings.Method = NetworkMethodStatic then
  begin
    Applied := Applied + ' ' + Settings.Address;
    if Settings.Gateway <> '' then
      Applied := Applied + ' via ' + Settings.Gateway;
  end;
  Say(Applied + BoolToStr(Settings.Up, ' up', ' down'));
  Applied := 'applied network-ipv6 ' + Settings.Name + ' ' + Ipv6MethodName(Settings.Ipv6Method);
  if Settings.Ipv6Method = Ipv6MethodStatic then
  begin
    Applied := Applied + ' ' + Settings.Ipv6Address;
    if Settings.Ipv6Gateway <> '' then
      Applied := Applied + ' via ' + Settings.Ipv6Gateway;
  end;
  Say(Applied);
end;

function TNetworkPage.ApplyDns: Boolean;
var
  Dns: TDnsSettings;
  Problem: TNetworkSettingsProblem;
  Request: TSystemSettingsRequest;
  Error: LongInt;
begin
  Dns := Default(TDnsSettings);
  if FDnsManual.Checked then
    Dns.Servers := SplitServerList(FDnsServers.Text);
  Dns.SearchDomain := Trim(FSearchDomain.Text);
  if FDnsManual.Checked and (Length(Dns.Servers) = 0) then
  begin
    Complain(Window, 'Type the addresses of the DNS servers, or have them obtained automatically.');
    Exit(False);
  end;
  Problem := CheckDnsSettings(Dns);
  if Problem <> NetworkSettingsValid then
  begin
    Complain(Window, NetworkSettingsProblemText(Problem));
    Exit(False);
  end;
  Request := NewSystemSettingsRequest(SystemRequestSetDnsServers);
  SetRequestText(@Request.Text[0], SystemTextCapacity, PChar(JoinServerList(Dns.Servers)));
  SetRequestText(@Request.SearchDomain[0], SystemDomainCapacity, PChar(Dns.SearchDomain));
  Error := SendAsAdministrator(Window, Request);
  Result := Error = ErrorNone;
  if not Result then
  begin
    if Error <> ErrorInterrupted then
      ShowMessageBox(Title, 'The DNS servers could not be changed. ' + RefusalText(Error), MessageOk, SignError,
        Window);
    Exit;
  end;
  FLoadedDns := Dns;
  FDnsChanged := False;
  if Length(Dns.Servers) = 0 then
    Say('applied dns automatic ' + Dns.SearchDomain)
  else
    Say('applied dns ' + JoinServerList(Dns.Servers) + ' ' + Dns.SearchDomain);
end;

function TNetworkPage.Apply: Boolean;
var
  Index: LongInt;
begin
  Result := True;
  for Index := 0 to High(FChoices) do
    if FChoices[Index].Changed and not ApplyInterface(FChoices[Index]) then
      Exit(False);
  if FDnsChanged then
    Result := ApplyDns;
  if Result then
    inherited Apply;
end;

{ --- Every second, and where things are -------------------------------------------- }

procedure TNetworkPage.Tick;
begin
  StartWatching;
  RefreshStatus;
end;

procedure TNetworkPage.TellPlaces;
var
  Index: LongInt;
  Tab: TRectangle;
const
  TabNames: array[0..3] of string = ('address', 'ipv6', 'dns', 'status');
begin
  for Index := 0 to High(FStatus) do
    if Index < FList.RowCount then
      SayPlace('network-row-' + FStatus[Index].Name, Window, FList, Scaled(30), FList.RowMiddle(Index));
  for Index := 0 to High(TabNames) do
  begin
    Tab := FTabs.TabBounds(Index);
    SayPlace('network-tab-' + TabNames[Index], Window, FTabs, (Tab.Left + Tab.Right) div 2,
      (Tab.Top + Tab.Bottom) div 2);
  end;
  SayPlace('network-enabled', Window, FEnabled, Scaled(6), Scaled(ChoiceHeight div 2));
  SayPlace('network-method-dhcp', Window, FDhcp, Scaled(6), Scaled(ChoiceHeight div 2));
  SayPlace('network-method-static', Window, FStatic, Scaled(6), Scaled(ChoiceHeight div 2));
  SayPlace('network-method-none', Window, FNone, Scaled(6), Scaled(ChoiceHeight div 2));
  SayControlPlace('network-address', Window, FAddress);
  SayControlPlace('network-prefix', Window, FPrefix);
  SayControlPlace('network-gateway', Window, FGateway);
  FIpv6Tab.TellPlaces(Window);
  SayPlace('network-dns-automatic', Window, FDnsAutomatic, Scaled(6), Scaled(ChoiceHeight div 2));
  SayPlace('network-dns-manual', Window, FDnsManual, Scaled(6), Scaled(ChoiceHeight div 2));
  SayControlPlace('network-dns-servers', Window, FDnsServers);
  SayControlPlace('network-search-domain', Window, FSearchDomain);
end;

end.
