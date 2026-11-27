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
  What nc was asked to do (its options), and the messages -v asks for.
}
unit Netcat.Settings;

{$mode objfpc}
{$H+}

interface

const
  { -w and -q not given. }
  NoTimeLimit = -1;

type
  TNetcatSettings = record
    { -l, -k. }
    Listen: Boolean;
    KeepListening: Boolean;
    { -u: UDP instead of TCP. }
    Datagrams: Boolean;
    { -z: only see whether the ports take connections. }
    ScanOnly: Boolean;
    { -v. }
    Verbose: Boolean;
    { -n: the host must be a numeric address. }
    NumericOnly: Boolean;
    { -N: shut the socket's sending side at the end of the input. }
    ShutdownAtEndOfInput: Boolean;
    { -d: do not read the standard input. }
    IgnoreInput: Boolean;
    { -w: milliseconds a connection may take to be made or stay idle. }
    TimeoutMilliseconds: Int64;
    { -q: milliseconds to go on after the end of the input (0: stop at
      once; NoTimeLimit: until the peer ends the connection). }
    QuitAfterInputMilliseconds: Int64;
    { -p: the local port (0: one the system chooses). }
    LocalPort: Word;
    { -4, -6: HostFamily* of Sys.HostNames (both when neither is given). }
    Families: LongWord;
  end;

var
  Settings: TNetcatSettings;

procedure InitializeSettings;
{ A message on the standard error when -v was given (no "nc:" before
  it, as OpenBSD's nc writes "Listening on ..."). }
procedure ReportProgress(const Message: string);

implementation

uses
  Sys.Streams,
  Sys.HostNames;

procedure InitializeSettings;
begin
  Settings := Default(TNetcatSettings);
  Settings.TimeoutMilliseconds := NoTimeLimit;
  Settings.QuitAfterInputMilliseconds := NoTimeLimit;
  Settings.Families := HostFamilyAny;
end;

procedure ReportProgress(const Message: string);
begin
  if not Settings.Verbose then
    Exit;
  FlushStream(StandardOutput);
  PrintErrorStringLine(Message);
  FlushStream(StandardError);
end;

end.
