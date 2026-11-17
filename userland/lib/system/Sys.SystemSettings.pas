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
  Talking to the system settings service (userland/systemsettings), which
  makes the changes to the machine that only root may make, for the
  users who may ask for them: the time zone, the date and time, the
  sound outputs' remembered volumes and the default output, the user
  accounts, and the network's settings (each interface's address or
  DHCP, the DNS servers).

  It runs as root and serves the port "systemsettings". The kernel tells
  it who connected (CallGetChannelPeer), and it decides by that and by
  the password a request carries (Authorization):
    - root may ask for anything, without a password;
    - anyone may set the sound (the volumes, the mute, the default
      output), as anyone at the machine could turn its knobs, and the
      theme (the look of every window);
    - a user may change their own password and full name with their own
      password;
    - everything else needs an administrator: root's password, or the
      caller's own password when the caller is a member of the group
      "wheel" (as sudo asks).
  A wrong password is answered ErrorAccessDenied after a pause, so
  passwords cannot be tried quickly. Each request is one
  TSystemSettingsRequest answered by one TSystemSettingsReply; nothing
  else is said on the channel.

  Why a service rather than set-user-ID helpers: one program, small and
  reviewed, holds every privileged change, checks every caller the same
  way, and keeps what it changes in the system's settings
  (libconfiguration, /etc/settings) for the next boot, when it gives the
  kernel the remembered zone, volumes and default output again. The
  graphical Control Panel and the command-line tools (timezone, date -s,
  mixer -r) all ask it, so they share one implementation.
}
unit Sys.SystemSettings;

{$mode objfpc}{$H+}

interface

const
  SystemSettingsPortName = 'systemsettings';

  { TSystemSettingsRequest.Code. }
  { Is Authorization an administrator's? Changes nothing. }
  SystemRequestCheckAdministrator = 1;
  { Text: the zone's name (Sys.TimeZones); remembered as Time/Zone. }
  SystemRequestSetTimeZone = 2;
  { Time: the new date and time (UTC). }
  SystemRequestSetClock = 3;
  { Output: the output's number; Volume: 0-100; Flags:
    SystemFlagMuted. Applied and remembered (Sound/N/Volume,
    Sound/N/Muted). Anyone may. }
  SystemRequestSetVolume = 4;
  { Output: the default output from now on (Sound/DefaultOutput).
    Anyone may. }
  SystemRequestSetDefaultOutput = 5;
  { UserName, FullName, Password: a new account (Util.AccountChanges:
    the next free id, a group of its own, a home with the right owner
    and modes, /bin/sh); Flags: SystemFlagAdministrator puts it in
    "wheel" too. }
  SystemRequestAddUser = 6;
  { UserName; Flags: SystemFlagRemoveHome removes the home too. }
  SystemRequestRemoveUser = 7;
  { UserName, Password: the new password. }
  SystemRequestSetPassword = 8;
  { UserName, FullName. }
  SystemRequestSetFullName = 9;
  { UserName; Text: the supplementary groups, comma separated (the
    primary group stays). }
  SystemRequestSetGroups = 10;
  { NetworkInterface: an interface (eth0); NetworkMethod: "static",
    "dhcp" or "none"; NetworkAddress: its address with the prefix
    ("10.0.2.15/24"; needed for static, otherwise kept for later if
    given); NetworkGateway: the default route's gateway, on that
    network, or empty; Flags: SystemFlagInterfaceUp; NetworkIpv6Method:
    "auto", "static" or "none" (empty: the IPv6 settings stay as they
    are), NetworkIpv6Address ("fd00::10/64", needed for static) and
    NetworkIpv6Gateway (or empty). Checked
    (Configuration.NetworkSettings) and written to
    /etc/settings/Network.settings, which the network service applies
    as soon as it changes. }
  SystemRequestSetNetworkInterface = 11;
  { Text: the DNS servers, separated by commas or spaces (empty: those
    DHCP gives); SearchDomain: where names without a dot are looked up
    (or empty). Written to Network.settings as above. }
  SystemRequestSetDnsServers = 12;
  { Text: the theme's key (Windowing.Theme: "sunrise", "classic"), a
    short name of lower-case letters, digits and hyphens; remembered as
    Appearance/Theme, which the display server and every program
    follow. Anyone may, as the look is the machine's. }
  SystemRequestSetTheme = 13;

  SystemFlagMuted = $01;
  SystemFlagAdministrator = $02;
  SystemFlagRemoveHome = $04;
  SystemFlagInterfaceUp = $08;

  SystemNameCapacity = 32;
  SystemTextCapacity = 256;
  SystemPasswordCapacity = 128;
  { An interface's name, a method's ("static"), an address with its
    prefix ("255.255.255.255/32"), a domain name. }
  SystemInterfaceNameCapacity = 16;
  SystemMethodCapacity = 16;
  SystemAddressCapacity = 32;
  { An IPv6 address with its prefix ("ffff:...:ffff/128"). }
  SystemIpv6AddressCapacity = 48;
  SystemDomainCapacity = 64;

  { The group whose members are administrators. }
  AdministratorsGroupName = 'wheel';

type
  TSystemSettingsRequest = record
    Code: LongWord;
    Flags: LongWord;
    Output: LongWord;
    Volume: LongWord;
    Time: Int64;
    { A password proving the caller may ask (see above); empty for root
      and for the sound. }
    Authorization: array[0..SystemPasswordCapacity - 1] of Char;
    UserName: array[0..SystemNameCapacity - 1] of Char;
    FullName: array[0..SystemTextCapacity - 1] of Char;
    Password: array[0..SystemPasswordCapacity - 1] of Char;
    Text: array[0..SystemTextCapacity - 1] of Char;
    NetworkInterface: array[0..SystemInterfaceNameCapacity - 1] of Char;
    NetworkMethod: array[0..SystemMethodCapacity - 1] of Char;
    NetworkAddress: array[0..SystemAddressCapacity - 1] of Char;
    NetworkGateway: array[0..SystemAddressCapacity - 1] of Char;
    SearchDomain: array[0..SystemDomainCapacity - 1] of Char;
    NetworkIpv6Method: array[0..SystemMethodCapacity - 1] of Char;
    NetworkIpv6Address: array[0..SystemIpv6AddressCapacity - 1] of Char;
    NetworkIpv6Gateway: array[0..SystemIpv6AddressCapacity - 1] of Char;
  end;

  TSystemSettingsReply = record
    { ErrorNone, or why not (ErrorAccessDenied: a wrong password;
      ErrorNotPermitted: not for this caller; ErrorExists, ErrorNotFound,
      ErrorInvalidArgument...). }
    Error: LongInt;
    Reserved: LongWord;
  end;

{ A request of Code, every other field empty. }
function NewSystemSettingsRequest(Code: LongWord): TSystemSettingsRequest;
{ Copies Text into one of the request's text fields (cut to fit). }
procedure SetRequestText(var Field: array of Char; const Text: string);
{ Sends Request and waits for the answer: the service's ErrorNone or
  refusal, or an error reaching it (ErrorNotFound: it does not run).
  The request's passwords are wiped afterwards. }
function AskSystemSettings(var Request: TSystemSettingsRequest): LongInt;

implementation

uses
  Abi.SystemCalls,
  Runtime.Memory,
  Sys.Errors,
  Sys.Objects;

const
  { Adding a user makes a home folder; a wrong password costs a pause. }
  ReplyTimeoutMilliseconds = 20000;

function NewSystemSettingsRequest(Code: LongWord): TSystemSettingsRequest;
begin
  FillMemory(@Result, SizeOf(Result), 0);
  Result.Code := Code;
end;

procedure SetRequestText(var Field: array of Char; const Text: string);
var
  Count: Integer;
begin
  Count := Length(Text);
  if Count > High(Field) then
    Count := High(Field);
  if Count > 0 then
    Move(Text[1], Field[0], Count);
  Field[Count] := #0;
end;

function AskSystemSettings(var Request: TSystemSettingsRequest): LongInt;
var
  Reply: TSystemSettingsReply;
  Channel: Int64;
  ReplyLength: QWord;
begin
  Channel := ConnectPort(SystemSettingsPortName);
  if Channel < 0 then
    Result := ErrorCodeOf(Channel)
  else
  begin
    Result := CallChannel(Channel, @Request, SizeOf(Request), @Reply, SizeOf(Reply), ReplyLength,
      ReplyTimeoutMilliseconds);
    CloseHandle(Channel);
    if (Result = ErrorNone) and (ReplyLength < SizeOf(Reply)) then
      Result := ErrorIo
    else if Result = ErrorNone then
      Result := Reply.Error;
  end;
  ZeroMemory(@Request.Authorization[0], SystemPasswordCapacity);
  ZeroMemory(@Request.Password[0], SystemPasswordCapacity);
end;

end.
