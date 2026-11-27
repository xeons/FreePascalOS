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
  networktest's dealings with the network service: starting /bin/network
  as a child (its output in /tmp/network-service.log), asking it to end,
  reading the state files it writes (/var/lib/network/NAME.state) and
  changing /etc/settings/Network.settings as the Control Panel would.
}
unit NetworkTest.Service;

{$mode objfpc}
{$H+}

interface

const
  ServiceLogPath = '/tmp/network-service.log';

{ The service's process handle, or minus an error. }
function StartNetworkService: Int64;
{ Asks it to end (as a service stop does) and waits; its exit status,
  or minus an error (ErrorTimedOut). The handle is closed. }
function StopNetworkService(Process: Int64; Milliseconds: QWord): LongInt;

{ A key of NAME.state as text (a list as "a,b"); '' if there is none. }
function StateValue(const InterfaceName, Key: string): string;
{ Waits until StateValue is Expected; True if it came in time. }
function WaitForStateValue(const InterfaceName, Key, Expected: string; Milliseconds: QWord): Boolean;

{ Gives InterfaceName a static address in the system's settings. }
function SetStaticAddressSetting(const InterfaceName, AddressWithPrefix: string): Boolean;
{ Gives InterfaceName a static IPv6 address (Ipv6Method static) and
  leaves IPv4 alone (Method none). }
function SetStaticIpv6Setting(const InterfaceName, AddressWithPrefix: string): Boolean;
{ Removes InterfaceName's section from the system's settings. }
function RemoveInterfaceSetting(const InterfaceName: string): Boolean;

implementation

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Kernel,
  Sys.Files,
  Sys.Objects,
  Sys.Processes,
  Sys.Notifications,
  Configuration.Values,
  Configuration.Documents,
  Configuration.Settings,
  Configuration.Locations;

const
  PollMilliseconds = 100;

function StartNetworkService: Int64;
var
  Arguments: array[0..1] of PChar;
  Options: TProcessOptions;
  Log: Int64;
begin
  Log := OpenFile(ServiceLogPath, OpenWrite or OpenCreate or OpenAppend);
  Arguments[0] := 'network';
  Arguments[1] := nil;
  DefaultProcessOptions(Options);
  if Log >= 0 then
  begin
    Options.OutputHandle := Log;
    Options.ErrorHandle := Log;
  end;
  Options.InputHandle := NoHandle;
  Result := StartProgram('/bin/network', @Arguments[0], Options);
  if Log >= 0 then
    CloseFile(Log);
end;

function StopNetworkService(Process: Int64; Milliseconds: QWord): LongInt;
var
  ExitCode: LongInt;
  Error: LongInt;
begin
  Error := AskProcessToEnd(QWord(ProcessIdOf(Process)), EndReasonServiceStop);
  if Error <> ErrorNone then
    Exit(-Error);
  Error := WaitForProgramWithTimeout(Process, Milliseconds, ExitCode);
  if Error <> ErrorNone then
    Exit(-Error);
  CloseHandle(Process);
  Result := ExitCode;
end;

function ReadWholeFile(const Path: string; out Text: string): Boolean;
var
  Handle: Int64;
  Buffer: array[0..8191] of Char;
  Chunk: string;
  Read: Int64;
begin
  Text := '';
  Handle := OpenFile(PChar(Path), OpenRead);
  if Handle < 0 then
    Exit(False);
  repeat
    Read := ReadFile(Handle, @Buffer[0], SizeOf(Buffer));
    if Read > 0 then
    begin
      SetString(Chunk, PChar(@Buffer[0]), Read);
      Text := Text + Chunk;
    end;
  until Read <= 0;
  CloseFile(Handle);
  Result := Text <> '';
end;

function StateValue(const InterfaceName, Key: string): string;
var
  Text: string;
  Document: TSettingsDocument;
  Value: TSettingValue;
  Fixed: Boolean;
  Items: TStringArray;
  Index: Integer;
begin
  Result := '';
  if not ReadWholeFile('/var/lib/network/' + InterfaceName + '.state', Text) then
    Exit;
  Document := TSettingsDocument.Create;
  try
    Document.Parse(Text);
    if not Document.GetValue('', Key, Value, Fixed) then
      Exit;
    if SettingAsList(Value, Items) then
    begin
      for Index := 0 to High(Items) do
      begin
        if Index > 0 then
          Result := Result + ',';
        Result := Result + Items[Index];
      end;
    end
    else
      SettingAsString(Value, Result);
  finally
    Document.Free;
  end;
end;

function WaitForStateValue(const InterfaceName, Key, Expected: string; Milliseconds: QWord): Boolean;
var
  Deadline: QWord;
begin
  Deadline := QWord(KernelGetTime(TimeUptimeMilliseconds)) + Milliseconds;
  repeat
    if StateValue(InterfaceName, Key) = Expected then
      Exit(True);
    SleepMilliseconds(PollMilliseconds);
  until QWord(KernelGetTime(TimeUptimeMilliseconds)) >= Deadline;
  Result := StateValue(InterfaceName, Key) = Expected;
end;

function SetStaticAddressSetting(const InterfaceName, AddressWithPrefix: string): Boolean;
var
  Store: TSettings;
  Section: string;
begin
  Store := OpenSystemSettings;
  try
    Section := 'Network/Interfaces/' + InterfaceName;
    Store.WriteString(Section + '/Method', 'static', ScopeSystem);
    Store.WriteString(Section + '/Address', AddressWithPrefix, ScopeSystem);
    Store.WriteBoolean(Section + '/Up', True, ScopeSystem);
    Result := Store.Flush = ErrorNone;
  finally
    Store.Free;
  end;
end;

function SetStaticIpv6Setting(const InterfaceName, AddressWithPrefix: string): Boolean;
var
  Store: TSettings;
  Section: string;
begin
  Store := OpenSystemSettings;
  try
    Section := 'Network/Interfaces/' + InterfaceName;
    Store.WriteString(Section + '/Method', 'none', ScopeSystem);
    Store.WriteString(Section + '/Ipv6Method', 'static', ScopeSystem);
    Store.WriteString(Section + '/Ipv6Address', AddressWithPrefix, ScopeSystem);
    Store.WriteBoolean(Section + '/Up', True, ScopeSystem);
    Result := Store.Flush = ErrorNone;
  finally
    Store.Free;
  end;
end;

function RemoveInterfaceSetting(const InterfaceName: string): Boolean;
var
  Store: TSettings;
begin
  Store := OpenSystemSettings;
  try
    Store.Delete('Network/Interfaces/' + InterfaceName, ScopeSystem);
    Result := Store.Flush = ErrorNone;
  finally
    Store.Free;
  end;
end;

end.
