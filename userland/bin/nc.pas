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
  nc - netcat: read and write TCP and UDP connections

  nc [-46dNnuvz] [-p PORT] [-q SECONDS] [-w SECONDS] HOST PORT[-PORT]...
  nc -l [-46dkNnuv] [-q SECONDS] [-w SECONDS] [HOST] [-p] PORT

  With OpenBSD's nc options. It connects to HOST (or, with -l, waits
  for a connection) and then copies its standard input to the
  connection and the connection to its standard output, both at once,
  until the peer ends the connection. -N shuts the connection's sending
  side at the end of the input so the peer sees the end too; -q stops
  that many seconds after it; -w stops a connection idle that long (and
  limits connecting). -z only says whether ports take connections (with
  -v, how each went; the exit status is 0 if one did). -k keeps
  listening after a connection ends. -u uses UDP. -n takes only numeric
  addresses; otherwise HOST goes through Sys.HostLookup (IPv6 first
  when it can be reached). -d does not read the standard input. HOST
  may be an IPv6 address (::1, or [::1]); -4 and -6 keep to one IP
  version, and -l -6 listens on :: (without it nc listens on IPv4).

  The pieces are in userland/nc (Netcat.*).
}
program nc;

{$mode objfpc}
{$pointermath on}

uses
  Sys.Format,
  Sys.HostNames,
  Sys.InternetAddresses,
  Sys.Streams,
  Sys.Text,
  Util.Messages,
  Util.Options,
  Netcat.Settings,
  Netcat.Ports,
  Netcat.Sockets,
  Netcat.Client,
  Netcat.Listener;

const
  Usage: PChar = 'Usage: nc [-46dNnuvz] [-p PORT] [-q SECONDS] [-w SECONDS] HOST PORT[-PORT]...'#10 +
    '  or:  nc -l [-46dkNnuv] [-q SECONDS] [-w SECONDS] [HOST] [-p] PORT'#10 +
    'Connect to HOST, or listen for a connection, and copy the standard input to'#10 +
    'it and what comes from it to the standard output.'#10 +
    #10 +
    '  -4           IPv4 only'#10 +
    '  -6           IPv6 only'#10 +
    '  -l           listen for a connection'#10 +
    '  -k           go on listening after a connection ends (with -l)'#10 +
    '  -p PORT      the local port (with -l, the one to listen on)'#10 +
    '  -u           UDP instead of TCP'#10 +
    '  -z           only see whether the ports take connections'#10 +
    '  -v           say what happens'#10 +
    '  -w SECONDS   give up connecting, or end a connection idle, after SECONDS'#10 +
    '  -q SECONDS   end SECONDS after the end of the input (0: at once)'#10 +
    '  -N           shut the connection''s sending side at the end of the input'#10 +
    '  -n           numeric addresses only (no name lookup)'#10 +
    '  -d           do not read the standard input'#10;

  OptionListen = 1;
  OptionKeepListening = 2;
  OptionLocalPort = 3;
  OptionDatagrams = 4;
  OptionScan = 5;
  OptionVerbose = 6;
  OptionTimeout = 7;
  OptionQuitAfter = 8;
  OptionShutdown = 9;
  OptionNumeric = 10;
  OptionIgnoreInput = 11;
  OptionIpv4 = 12;
  OptionIpv6 = 13;

  MillisecondsPerSecond = 1000;

var
  Parser: TOptionParser;

{ Whole seconds, as -w and -q take them; -q also takes a negative
  number (go on until the peer ends). }
function ParseSeconds(Option: Char; Text: PChar; NegativeAllowed: Boolean): Int64;
var
  Seconds: Int64;
begin
  if not ParseInteger(Text, Seconds) or (Seconds > High(LongWord)) or ((Seconds < 0) and not NegativeAllowed) then
    FailWithUsageHint('-%s: bad number of seconds ''%s''', [ArgumentCharacter(Option), ArgumentText(Text)]);
  if Seconds < 0 then
    Exit(NoTimeLimit);
  Result := Seconds * MillisecondsPerSecond;
end;

procedure ParseArguments;
var
  Code: Integer;
  Value: PChar;
begin
  InitializeSettings;
  BeginOptions(Parser, [
    OptionDefinition('l', nil, False, OptionListen),
    OptionDefinition('k', nil, False, OptionKeepListening),
    OptionDefinition('p', nil, True, OptionLocalPort),
    OptionDefinition('u', nil, False, OptionDatagrams),
    OptionDefinition('z', nil, False, OptionScan),
    OptionDefinition('v', nil, False, OptionVerbose),
    OptionDefinition('w', nil, True, OptionTimeout),
    OptionDefinition('q', nil, True, OptionQuitAfter),
    OptionDefinition('N', nil, False, OptionShutdown),
    OptionDefinition('n', nil, False, OptionNumeric),
    OptionDefinition('d', nil, False, OptionIgnoreInput),
    OptionDefinition('4', nil, False, OptionIpv4),
    OptionDefinition('6', nil, False, OptionIpv6)], Usage);
  while NextOption(Parser, Code, Value) do
    case Code of
      OptionListen: Settings.Listen := True;
      OptionKeepListening: Settings.KeepListening := True;
      OptionLocalPort:
        if not ParsePort(Value, Settings.LocalPort) then
          FailWithUsageHint('-p: bad port ''%s''', [ArgumentText(Value)]);
      OptionDatagrams: Settings.Datagrams := True;
      OptionScan: Settings.ScanOnly := True;
      OptionVerbose: Settings.Verbose := True;
      OptionTimeout: Settings.TimeoutMilliseconds := ParseSeconds('w', Value, False);
      OptionQuitAfter: Settings.QuitAfterInputMilliseconds := ParseSeconds('q', Value, True);
      OptionShutdown: Settings.ShutdownAtEndOfInput := True;
      OptionNumeric: Settings.NumericOnly := True;
      OptionIgnoreInput: Settings.IgnoreInput := True;
      OptionIpv4: Settings.Families := HostFamilyIpv4;
      OptionIpv6: Settings.Families := HostFamilyIpv6;
    end;
  if Settings.KeepListening and not Settings.Listen then
    FailWithUsageHint('-k needs -l', []);
  if Settings.KeepListening and Settings.Datagrams then
    FailWithUsageHint('-k works with TCP only', []);
  if Settings.Listen and Settings.ScanOnly then
    FailWithUsageHint('-l and -z cannot be combined', []);
end;

{ nc -l [HOST] PORT, or nc -l [HOST] -p PORT. }
function Listen: Integer;
var
  LocalAddress: TInternetAddress;
  Port: Word;
  PortOperand: Integer;
begin
  LocalAddress := AnyListeningAddress;
  Port := Settings.LocalPort;
  PortOperand := -1;
  if Port = 0 then
    PortOperand := Parser.OperandCount - 1;
  if (PortOperand >= 0) and not ParsePort(Parser.Operands[PortOperand], Port) then
    FailWithUsageHint('bad port ''%s''', [ArgumentText(Parser.Operands[PortOperand])]);
  if Port = 0 then
    FailWithUsageHint('missing port to listen on', []);
  if (Parser.OperandCount > 2) or ((Parser.OperandCount = 2) and (PortOperand < 0)) then
    FailWithUsageHint('too many operands', []);
  if (Parser.OperandCount = 2) or ((Parser.OperandCount = 1) and (PortOperand < 0)) then
    LocalAddress := ResolveHost(Parser.Operands[0]);
  { -p named the port to listen on, not a local port to send from. }
  Settings.LocalPort := 0;
  Result := RunListener(LocalAddress, Port);
end;

function Connect: Integer;
begin
  if Parser.OperandCount < 2 then
    FailWithUsageHint('missing host or port', []);
  Result := RunClient(Parser.Operands[0], @Parser.Operands[1], Parser.OperandCount - 1);
end;

var
  ExitStatus: Integer;

begin
  ParseArguments;
  if Settings.Listen then
    ExitStatus := Listen
  else
    ExitStatus := Connect;
  FlushStream(StandardOutput);
  Halt(ExitStatus);
end.
