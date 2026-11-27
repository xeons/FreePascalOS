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
  The client's session channel: once the server confirms it, the
  requests (agent forwarding, a pseudo-terminal of the local terminal's
  size and type, LANG, then the command or the shell); then standard
  input goes to the channel (through the escape filter on a terminal)
  and the channel's data and extended data to standard output and
  standard error, until the server sends exit-status (or exit-signal)
  and closes. A change of the local terminal's size is sent as
  window-change (looked at every second).
}
unit SshClient.Channels;

{$mode objfpc}{$H+}

interface

uses
  SysUtils,
  Ssh.Wire,
  Ssh.Connection,
  Ssh.PolledChannels,
  SshClient.Terminal;

type
  TClientSessionChannel = class(TSshPolledChannel)
  private
    FCommand: string;
    FWantsTerminal: Boolean;
    FForwardAgent: Boolean;
    FEscape: TEscapeFilter;
    FInputEnded: Boolean;
    FExitStatus: LongInt;
    FHasExitStatus: Boolean;
    FFailed: Boolean;
    FRows, FColumns: LongInt;
    FLastSizeCheck: QWord;
    FTerminalReplyPending: Boolean;
    procedure InputReadable;
    procedure WriteAll(Handle: Int64; const Data: string);
    procedure CheckTerminalSize;
  protected
    function HandleRequest(const RequestType: string; var Reader: TSshReader): Boolean; override;
    procedure HandleData(const Data: string); override;
    procedure HandleExtendedData(DataType: LongWord; const Data: string); override;
    procedure HandleOpenConfirmed; override;
    procedure HandleOpenFailed(Reason: LongWord; const Description: string); override;
    procedure HandleRequestReply(Succeeded: Boolean); override;
  public
    constructor Create(Owner: TSshConnection; const Command: string; WantsTerminal, ForwardAgent: Boolean;
      EscapeCharacter: Integer);
    procedure CollectWaits(var Waits: TSshWaitList); override;
    procedure Poll; override;
    function Done: Boolean;
    function DisconnectRequested: Boolean;
    { The remote program's status: 255 when it is not known. }
    function ExitStatus: LongInt;
  end;

implementation

uses
  Abi.SystemCalls,
  Sys.Console,
  Sys.Kernel,
  Sys.Objects;

const
  ReadChunkBytes = 16 * 1024;
  OutputBackLog = 64 * 1024;
  SizeCheckMilliseconds = 1000;

constructor TClientSessionChannel.Create(Owner: TSshConnection; const Command: string;
  WantsTerminal, ForwardAgent: Boolean; EscapeCharacter: Integer);
begin
  inherited Create(Owner);
  FCommand := Command;
  FWantsTerminal := WantsTerminal;
  FForwardAgent := ForwardAgent;
  if WantsTerminal then
    StartEscapeFilter(FEscape, EscapeCharacter)
  else
    StartEscapeFilter(FEscape, -1);
end;

procedure TClientSessionChannel.HandleOpenConfirmed;
var
  TerminalType, Language: string;
begin
  if FForwardAgent then
    SendRequest('auth-agent-req@openssh.com', '');
  if FWantsTerminal then
  begin
    GetConsoleSize(StandardInputHandle, FRows, FColumns);
    TerminalType := GetEnvironmentVariable('TERM');
    if TerminalType = '' then
      TerminalType := 'xterm';
    FTerminalReplyPending := True;
    { The terminal modes: only TTY_OP_END. }
    SendRequestWithReply('pty-req', SshString(TerminalType) + SshUInt32(LongWord(FColumns)) +
      SshUInt32(LongWord(FRows)) + SshUInt32(0) + SshUInt32(0) + SshString(#0));
  end;
  Language := GetEnvironmentVariable('LANG');
  if Language <> '' then
    SendRequest('env', SshString('LANG') + SshString(Language));
  if FCommand <> '' then
    SendRequestWithReply('exec', SshString(FCommand))
  else
    SendRequestWithReply('shell', '');
end;

procedure TClientSessionChannel.HandleOpenFailed(Reason: LongWord; const Description: string);
begin
  WriteLn(ErrOutput, 'ssh: the session channel was refused: ', Description);
  FFailed := True;
end;

procedure TClientSessionChannel.HandleRequestReply(Succeeded: Boolean);
begin
  { Replies come in order: the pty-req's, then the exec's or shell's. }
  if FTerminalReplyPending then
  begin
    FTerminalReplyPending := False;
    if not Succeeded then
    begin
      WriteLn(ErrOutput, 'ssh: PTY allocation request failed');
      FWantsTerminal := False;
      LeaveRawMode;
      StartEscapeFilter(FEscape, -1);
    end;
    Exit;
  end;
  if Succeeded then
    Exit;
  WriteLn(ErrOutput, 'ssh: the server refused to start the command or shell');
  FFailed := True;
  CloseNow;
end;

function TClientSessionChannel.HandleRequest(const RequestType: string; var Reader: TSshReader): Boolean;
var
  SignalName: string;
begin
  Result := False;
  if RequestType = 'exit-status' then
  begin
    FExitStatus := LongInt(Reader.ReadUInt32);
    FHasExitStatus := True;
    Result := True;
  end
  else if RequestType = 'exit-signal' then
  begin
    SignalName := Reader.ReadString;
    Reader.ReadBoolean;
    WriteLn(ErrOutput, 'ssh: the remote program ended with signal ', SignalName);
    FExitStatus := 255;
    FHasExitStatus := True;
    Result := True;
  end;
end;

procedure TClientSessionChannel.WriteAll(Handle: Int64; const Data: string);
var
  Done_: Integer;
  Count: Int64;
begin
  Done_ := 0;
  while Done_ < Length(Data) do
  begin
    Count := KernelWrite(Handle, @Data[Done_ + 1], Length(Data) - Done_);
    if Count <= 0 then
      Exit;
    Inc(Done_, Integer(Count));
  end;
end;

procedure TClientSessionChannel.HandleData(const Data: string);
begin
  WriteAll(StandardOutputHandle, Data);
  InputConsumed(Length(Data));
end;

procedure TClientSessionChannel.HandleExtendedData(DataType: LongWord; const Data: string);
begin
  WriteAll(StandardErrorHandle, Data);
  InputConsumed(Length(Data));
end;

procedure TClientSessionChannel.InputReadable;
var
  Buffer: array[0..ReadChunkBytes - 1] of Byte;
  Count: Int64;
  Typed: string;
begin
  Count := KernelRead(StandardInputHandle, @Buffer[0], SizeOf(Buffer));
  if Count <= 0 then
  begin
    FInputEnded := True;
    SendEofWhenFlushed;
    Exit;
  end;
  Typed := FilterTyped(FEscape, BytesToString(@Buffer[0], Integer(Count)));
  if Typed <> '' then
    SendData(Typed);
  if FEscape.DisconnectRequested then
    CloseNow;
end;

procedure TClientSessionChannel.CollectWaits(var Waits: TSshWaitList);
begin
  if IsOpen and not FInputEnded and not EofSent and (PendingOutput < OutputBackLog) then
    AddWait(Waits, StandardInputHandle, @InputReadable);
end;

procedure TClientSessionChannel.CheckTerminalSize;
var
  Rows, Columns: LongInt;
begin
  if GetTickCount64 - FLastSizeCheck < SizeCheckMilliseconds then
    Exit;
  FLastSizeCheck := GetTickCount64;
  GetConsoleSize(StandardInputHandle, Rows, Columns);
  if (Rows <= 0) or (Columns <= 0) or ((Rows = FRows) and (Columns = FColumns)) then
    Exit;
  FRows := Rows;
  FColumns := Columns;
  SendRequest('window-change', SshUInt32(LongWord(Columns)) + SshUInt32(LongWord(Rows)) + SshUInt32(0) +
    SshUInt32(0));
end;

procedure TClientSessionChannel.Poll;
begin
  if FWantsTerminal and IsOpen then
    CheckTerminalSize;
end;

function TClientSessionChannel.Done: Boolean;
begin
  Result := FFailed or CloseReceived or (State = ChannelStateFailed);
end;

function TClientSessionChannel.DisconnectRequested: Boolean;
begin
  Result := FEscape.DisconnectRequested;
end;

function TClientSessionChannel.ExitStatus: LongInt;
begin
  if FHasExitStatus and not FFailed then
    Result := FExitStatus
  else
    Result := 255;
end;

end.
