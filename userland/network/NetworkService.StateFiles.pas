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
  The state of each interface, for other programs (the desktop's network
  icon, the Control Panel): /var/lib/network/NAME.state, in the format
  of libconfiguration's settings files, with these keys:

    Method = "dhcp"                    dhcp, static or none
    State = "configured"               down, no-link, configuring,
                                       configured or failed
    Address = "10.0.2.15/24"           or ""
    Gateway = "10.0.2.2"               or ""
    DnsServers = ["10.0.2.3"]
    Domain = ""
    LeaseSeconds = 86400               0 for static and none
    LeaseObtained = 1794787200         Unix time; 0 without a lease
    DhcpServer = "10.0.2.2"            or ""
    Ipv6Method = "auto"                auto, static or none
    Ipv6Addresses = ["fe80::5054:ff:fe12:3456/64", "fec0::5054:ff:fe12:3456/64"]
                                       the kernel's (tentative ones left out)
    Ipv6Gateway = "fe80::2"            the IPv6 default route's, or ""
    Ipv6DnsServers = ["fec0::3"]       what routers advertised (RDNSS)

  A file is written whole as NAME.state.new (mode 0644) and renamed over
  NAME.state, so a reader sees the old state or the new one, never half
  of one; it is written only when its text changes, so a program
  watching the folder hears of real changes only. The folder is made
  (0755) if it is missing.
}
unit NetworkService.StateFiles;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils;

const
  StateFolder = '/var/lib/network';
  StateFileSuffix = '.state';

type
  TInterfaceState = record
    Method: string;
    State: string;
    Address: string;
    Gateway: string;
    DnsServers: TStringArray;
    Domain: string;
    LeaseSeconds: Int64;
    LeaseObtained: Int64;
    DhcpServer: string;
    Ipv6Method: string;
    Ipv6Addresses: TStringArray;
    Ipv6Gateway: string;
    Ipv6DnsServers: TStringArray;
  end;

{ An empty state: Method none, State down. }
function EmptyInterfaceState: TInterfaceState;
{ Writes Name's state if it differs from what was written last. }
procedure WriteInterfaceState(const Name: string; constref State: TInterfaceState);
{ The state file of Name as it was left by an earlier run (the address
  of a lease to ask for again); False if there is none. }
function ReadPreviousInterfaceState(const Name: string; out State: TInterfaceState): Boolean;

implementation

uses
  Abi.SystemCalls,
  Sys.Files,
  Configuration.Values,
  Configuration.Documents,
  NetworkService.Log;

const
  StateFileMode = $1A4;   { rw-r--r-- }
  FolderMode = $1ED;      { rwxr-xr-x }
  MaximumStateFileBytes = 16384;

type
  TWrittenState = record
    Name: string;
    Text: string;
  end;

var
  Written: array of TWrittenState;

function EmptyInterfaceState: TInterfaceState;
begin
  Result.Method := 'none';
  Result.State := 'down';
  Result.Address := '';
  Result.Gateway := '';
  Result.DnsServers := nil;
  Result.Domain := '';
  Result.LeaseSeconds := 0;
  Result.LeaseObtained := 0;
  Result.DhcpServer := '';
  Result.Ipv6Method := 'auto';
  Result.Ipv6Addresses := nil;
  Result.Ipv6Gateway := '';
  Result.Ipv6DnsServers := nil;
end;

procedure MakeFolder(const Path: string);
begin
  if IsDirectory(PChar(Path)) then
    Exit;
  if CreateDirectory(PChar(Path)) = ErrorNone then
    ChangeMode(PChar(Path), FolderMode);
end;

function StateText(const Name: string; constref State: TInterfaceState): string;
var
  Document: TSettingsDocument;
begin
  Document := TSettingsDocument.Create;
  try
    Document.Parse('# The state of ' + Name + ', kept by the network service: read, never written.'#10);
    Document.SetValue('', 'Method', StringSetting(State.Method), False);
    Document.SetValue('', 'State', StringSetting(State.State), False);
    Document.SetValue('', 'Address', StringSetting(State.Address), False);
    Document.SetValue('', 'Gateway', StringSetting(State.Gateway), False);
    Document.SetValue('', 'DnsServers', ListSetting(State.DnsServers), False);
    Document.SetValue('', 'Domain', StringSetting(State.Domain), False);
    Document.SetValue('', 'LeaseSeconds', IntegerSetting(State.LeaseSeconds), False);
    Document.SetValue('', 'LeaseObtained', IntegerSetting(State.LeaseObtained), False);
    Document.SetValue('', 'DhcpServer', StringSetting(State.DhcpServer), False);
    Document.SetValue('', 'Ipv6Method', StringSetting(State.Ipv6Method), False);
    Document.SetValue('', 'Ipv6Addresses', ListSetting(State.Ipv6Addresses), False);
    Document.SetValue('', 'Ipv6Gateway', StringSetting(State.Ipv6Gateway), False);
    Document.SetValue('', 'Ipv6DnsServers', ListSetting(State.Ipv6DnsServers), False);
    Result := Document.Serialize;
  finally
    Document.Free;
  end;
end;

function LastWrittenIndex(const Name: string): Integer;
var
  Index: Integer;
begin
  for Index := 0 to High(Written) do
    if Written[Index].Name = Name then
      Exit(Index);
  SetLength(Written, Length(Written) + 1);
  Result := High(Written);
  Written[Result].Name := Name;
  Written[Result].Text := '';
end;

function WriteWholeFile(const Path, Text: string): LongInt;
var
  NewPath: string;
  Handle: Int64;
begin
  NewPath := Path + '.new';
  Handle := OpenFile(PChar(NewPath), OpenWrite or OpenCreate or OpenTruncate);
  if Handle < 0 then
    Exit(LongInt(-Handle));
  Result := ChangeMode(PChar(NewPath), StateFileMode);
  if (Result = ErrorNone) and (Text <> '') then
    Result := WriteAll(Handle, @Text[1], Length(Text));
  CloseFile(Handle);
  if Result = ErrorNone then
    Result := RenamePath(PChar(NewPath), PChar(Path));
  if Result <> ErrorNone then
    RemovePath(PChar(NewPath));
end;

procedure WriteInterfaceState(const Name: string; constref State: TInterfaceState);
var
  Text: string;
  Index: Integer;
  Error: LongInt;
begin
  Text := StateText(Name, State);
  Index := LastWrittenIndex(Name);
  if Written[Index].Text = Text then
    Exit;
  MakeFolder('/var/lib');
  MakeFolder(StateFolder);
  Error := WriteWholeFile(StateFolder + '/' + Name + StateFileSuffix, Text);
  if Error <> ErrorNone then
  begin
    Say(Name + ': cannot write its state file: ' + ErrorText(Error));
    Exit;
  end;
  Written[Index].Text := Text;
end;

function ReadFileText(const Path: string; out Text: string): Boolean;
var
  Handle: Int64;
  Buffer: array[0..MaximumStateFileBytes - 1] of Char;
  Read: Int64;
begin
  Text := '';
  Handle := OpenFile(PChar(Path), OpenRead);
  if Handle < 0 then
    Exit(False);
  Read := ReadFile(Handle, @Buffer[0], SizeOf(Buffer));
  CloseFile(Handle);
  if Read <= 0 then
    Exit(False);
  SetString(Text, PChar(@Buffer[0]), Read);
  Result := True;
end;

function ReadString(Document: TSettingsDocument; const Key: string): string;
var
  Value: TSettingValue;
  Fixed: Boolean;
begin
  Result := '';
  if Document.GetValue('', Key, Value, Fixed) then
    SettingAsString(Value, Result);
end;

function ReadInteger(Document: TSettingsDocument; const Key: string): Int64;
var
  Value: TSettingValue;
  Fixed: Boolean;
begin
  Result := 0;
  if Document.GetValue('', Key, Value, Fixed) then
    SettingAsInteger(Value, Result);
end;

function ReadPreviousInterfaceState(const Name: string; out State: TInterfaceState): Boolean;
var
  Text: string;
  Document: TSettingsDocument;
begin
  State := EmptyInterfaceState;
  if not ReadFileText(StateFolder + '/' + Name + StateFileSuffix, Text) then
    Exit(False);
  Document := TSettingsDocument.Create;
  try
    Document.Parse(Text);
    State.Method := ReadString(Document, 'Method');
    State.State := ReadString(Document, 'State');
    State.Address := ReadString(Document, 'Address');
    State.Gateway := ReadString(Document, 'Gateway');
    State.Domain := ReadString(Document, 'Domain');
    State.DhcpServer := ReadString(Document, 'DhcpServer');
    State.LeaseSeconds := ReadInteger(Document, 'LeaseSeconds');
    State.LeaseObtained := ReadInteger(Document, 'LeaseObtained');
  finally
    Document.Free;
  end;
  Result := True;
end;

end.
