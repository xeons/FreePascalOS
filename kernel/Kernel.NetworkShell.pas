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
  The kernel debug shell over TCP, for a board nobody can type at:

    netshell=PORT    listen on PORT (off by default)

  then "nc BOARD PORT" (or telnet) gives the kshell prompt. Its commands
  are Kernel.DebugShell's; it runs in the kernel, whether user mode came
  up or not. NO AUTHENTICATION: anyone who can reach the port can read
  files and reset the machine. For a trusted local network only.

  One connection at a time, served by a system thread. Lines end with
  LF (CR is dropped; telnet's option bytes are ignored). While a command
  runs, everything written to the kernel log is copied into a buffer
  (Debug.Output's output copy) and sent afterwards - the command's
  output, and any other log line written meanwhile; at most 64 KiB per
  command, the rest is cut. "exit" closes the connection; "poweroff" and
  "reboot" do what they say.
}
unit Kernel.NetworkShell;

{$mode objfpc}
{$pointermath on}

interface

{ Starts the listener if the netshell option asks for it. }
procedure StartNetworkShell;
function NetworkShellIsWanted: Boolean;

implementation

uses
  Abi.SystemCalls,
  Runtime.Text,
  Kernel.Options,
  Kernel.Scheduler,
  Kernel.Threads,
  Processes.Thread,
  Objects.Manager,
  Network.Addresses,
  Network.Sockets,
  Network.SocketOperations,
  Kernel.DebugShell,
  Debug.Output;

const
  OptionNetworkShell = 'netshell';
  LineCapacity = 256;
  OutputCapacity = 64 * 1024;
  ShellThreadPriority = DefaultThreadPriority + 2;
  RetryMilliseconds = 2000;
  Prompt = 'kshell> ';
  Greeting = 'FreePascalOS kernel debug shell (unauthenticated; trusted networks only). ' +
    '"help" lists the commands, "exit" closes.';
  CutNotice = '[output cut at 64 KiB]';

var
  ListenPort: Word;
  Output: array[0..OutputCapacity - 1] of Char;
  OutputLength: LongWord;
  OutputWasCut: Boolean;

function NetworkShellIsWanted: Boolean;
var
  Port: QWord;
begin
  Result := GetKernelOptionNumber(OptionNetworkShell, Port) and (Port > 0) and (Port <= $FFFF);
end;

{ The output copy: with the debug output lock held, only store. }
procedure CopyOutputCharacter(Character: Char);
begin
  if OutputLength >= OutputCapacity then
  begin
    OutputWasCut := True;
    Exit;
  end;
  Output[OutputLength] := Character;
  Inc(OutputLength);
end;

function KernelOwner: TSocketOwner;
begin
  Result.UserId := 0;
  Result.ProcessId := 0;
end;

function SendAll(Connection: PSocket; Data: PChar; Length: LongWord): Boolean;
var
  Sent: Int64;
begin
  while Length > 0 do
  begin
    Sent := SendOnSocket(Connection, PByte(Data), Length, 0, nil);
    if Sent <= 0 then
      Exit(False);
    Inc(Data, Sent);
    Dec(Length, Sent);
  end;
  Result := True;
end;

function SendText(Connection: PSocket; Text: PChar): Boolean;
begin
  Result := SendAll(Connection, Text, TextLength(Text));
end;

{ Sends Data with each LF as CR LF (for telnet and raw terminals). }
function SendLines(Connection: PSocket; Data: PChar; Length: LongWord): Boolean;
var
  Start: LongWord;
  Index: LongWord;
begin
  Result := True;
  Start := 0;
  Index := 0;
  while Index < Length do
  begin
    if Data[Index] = #10 then
    begin
      if not SendAll(Connection, @Data[Start], Index - Start) or not SendText(Connection, #13#10) then
        Exit(False);
      Start := Index + 1;
    end;
    Inc(Index);
  end;
  if Index > Start then
    Result := SendAll(Connection, @Data[Start], Index - Start);
end;

{ Runs Line, sending what it wrote; False when the connection should
  close. }
function RunLine(Connection: PSocket; Line: PChar): Boolean;
begin
  OutputLength := 0;
  OutputWasCut := False;
  SetDebugOutputCopy(@CopyOutputCharacter);
  Result := RunDebugShellCommand(Line);
  SetDebugOutputCopy(nil);
  if not SendLines(Connection, @Output[0], OutputLength) then
    Exit(False);
  if OutputWasCut and not SendText(Connection, CutNotice + #13#10) then
    Exit(False);
end;

type
  { Where the reader is in a telnet command (IAC ...), which is skipped. }
  TTelnetState = (TelnetData, TelnetCommand, TelnetOption, TelnetSubnegotiation, TelnetSubnegotiationCommand);

const
  TelnetInterpretAsCommand = #255;
  TelnetSubnegotiationBegin = #250;
  TelnetSubnegotiationEnd = #240;
  { WILL, WONT, DO, DONT: one option byte follows. }
  TelnetFirstOptionCommand = #251;

{ Takes one received character; True if it is text for the line. }
function TakeTelnetCharacter(var State: TTelnetState; Character: Char): Boolean;
begin
  Result := False;
  case State of
    TelnetData:
      if Character = TelnetInterpretAsCommand then
        State := TelnetCommand
      else
        Result := True;
    TelnetCommand:
      if Character = TelnetInterpretAsCommand then
      begin
        State := TelnetData;
        Result := True;
      end
      else if Character = TelnetSubnegotiationBegin then
        State := TelnetSubnegotiation
      else if Character >= TelnetFirstOptionCommand then
        State := TelnetOption
      else
        State := TelnetData;
    TelnetOption:
      State := TelnetData;
    TelnetSubnegotiation:
      if Character = TelnetInterpretAsCommand then
        State := TelnetSubnegotiationCommand;
    TelnetSubnegotiationCommand:
      if Character = TelnetSubnegotiationEnd then
        State := TelnetData
      else
        State := TelnetSubnegotiation;
  end;
end;

{ Serves one connection until it closes or "exit". }
procedure Serve(Connection: PSocket);
var
  Received: array[0..511] of Char;
  Count: Int64;
  Index: Integer;
  Line: array[0..LineCapacity - 1] of Char;
  LineLength: Integer;
  Source: TNetworkEndpoint;
  Character: Char;
  Telnet: TTelnetState;
begin
  if not SendText(Connection, Greeting + #13#10 + Prompt) then
    Exit;
  LineLength := 0;
  Telnet := TelnetData;
  repeat
    Count := ReceiveOnSocket(Connection, @Received[0], SizeOf(Received), 0, Source);
    if Count <= 0 then
      Exit;
    for Index := 0 to Integer(Count) - 1 do
    begin
      Character := Received[Index];
      if not TakeTelnetCharacter(Telnet, Character) then
        Continue;
      if Character = #10 then
      begin
        Line[LineLength] := #0;
        LineLength := 0;
        if not RunLine(Connection, @Line[0]) then
          Exit;
        if not SendText(Connection, Prompt) then
          Exit;
      end
      { CR and other control characters are dropped. }
      else if (Character >= ' ') and (Character < #127) and (LineLength < LineCapacity - 1) then
      begin
        Line[LineLength] := Character;
        Inc(LineLength);
      end;
    end;
  until False;
end;

function OpenListener(out Listener: PSocket): Boolean;
begin
  Result := False;
  if CreateSocket(AddressFamilyIPv4, SocketKindStream, ProtocolDefault, KernelOwner, True, Listener) <> ErrorNone then
  begin
    Listener := nil;
    Exit;
  end;
  SetSocketOption(Listener, SocketOptionReuseAddress, 1, True);
  Result := (BindSocket(Listener, MakeEndpoint(AnyAddress, ListenPort), True) = ErrorNone) and
    (ListenOnSocket(Listener, 1) = ErrorNone);
end;

procedure WriteConnection(constref Peer: TNetworkEndpoint; Opened: Boolean);
var
  Number: TNumberText;
begin
  DebugBeginMessage;
  DebugWriteTag('netshell');
  if Opened then
    DebugWrite('connection from ')
  else
    DebugWrite('connection closed: ');
  DebugWrite(FormatDecimal((Peer.Address shr 24) and $FF, Number));
  DebugWrite('.');
  DebugWrite(FormatDecimal((Peer.Address shr 16) and $FF, Number));
  DebugWrite('.');
  DebugWrite(FormatDecimal((Peer.Address shr 8) and $FF, Number));
  DebugWrite('.');
  DebugWriteLine(FormatDecimal(Peer.Address and $FF, Number));
  DebugEndMessage;
end;

procedure RunNetworkShell(Context: Pointer);
var
  Listener: PSocket;
  Connection: PSocket;
  Peer: TNetworkEndpoint;
begin
  while not OpenListener(Listener) do
  begin
    if Listener <> nil then
      DereferenceObject(Listener);
    SleepMilliseconds(RetryMilliseconds);
  end;
  DebugBeginMessage;
  DebugWriteTag('netshell');
  DebugWrite('the kernel debug shell listens on TCP port ');
  DebugWriteDecimal(ListenPort);
  DebugWriteLine(' (no authentication: trusted networks only)');
  DebugEndMessage;
  repeat
    if AcceptOnSocket(Listener, KernelOwner, Connection, Peer) <> ErrorNone then
    begin
      SleepMilliseconds(RetryMilliseconds);
      Continue;
    end;
    WriteConnection(Peer, True);
    Serve(Connection);
    ShutdownSocket(Connection, SocketShutdownBoth);
    DereferenceObject(Connection);
    WriteConnection(Peer, False);
  until False;
end;

procedure StartNetworkShell;
var
  Port: QWord;
begin
  if not GetKernelOptionNumber(OptionNetworkShell, Port) or (Port = 0) or (Port > $FFFF) then
    Exit;
  ListenPort := Word(Port);
  if CreateSystemThread(@RunNetworkShell, nil, ShellThreadPriority, 'NetworkShell', False) = nil then
  begin
    DebugWriteTag('netshell');
    DebugWriteLine('could not start the network shell thread');
  end;
end;

end.
