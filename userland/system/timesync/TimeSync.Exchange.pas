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
  Asking a time server: its name looked up (Sys.HostLookup: an address,
  /etc/hosts or DNS), then a few SNTP requests over UDP to its first
  address that answers, each timed with the nanosecond wall clock
  (CallGetPreciseTime). Replies that are not answers to the request are
  skipped; a server that does not answer within the timeout counts as
  failed.
}
unit TimeSync.Exchange;

{$mode objfpc}{$H+}

interface

uses
  TimeSync.Packets,
  TimeSync.Corrections;

const
  RequestsPerPoll = 4;
  ReplyTimeoutMilliseconds = 2000;

{ Asks Server (a name or an address, with ":PORT" or 123) up to
  RequestsPerPoll times; Samples gets the accepted answers, Problem
  says what went wrong when there are none. }
function AskTimeServer(const Server: string; out Samples: TSampleArray; out Problem: string): Boolean;

implementation

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Errors,
  Sys.Sockets,
  Sys.Time,
  Sys.InternetAddresses,
  Sys.HostNames,
  Sys.HostLookup,
  Sys.AddressText;

{ "host", "host:123", "[v6]:123". }
procedure SplitServer(const Server: string; out Host: string; out Port: Word);
var
  Colon: Integer;
begin
  Host := Server;
  Port := NtpPort;
  if (Server <> '') and (Server[1] = '[') then
  begin
    Colon := Pos(']', Server);
    if Colon > 0 then
    begin
      Host := Copy(Server, 2, Colon - 2);
      if (Colon < Length(Server)) and (Server[Colon + 1] = ':') then
        Port := StrToIntDef(Copy(Server, Colon + 2, MaxInt), NtpPort);
    end;
    Exit;
  end;
  Colon := LastDelimiter(':', Server);
  { One colon: a port; more: an IPv6 address without brackets. }
  if (Colon > 0) and (Pos(':', Server) = Colon) then
  begin
    Host := Copy(Server, 1, Colon - 1);
    Port := StrToIntDef(Copy(Server, Colon + 1, MaxInt), NtpPort);
  end;
end;

{ One request and its reply over Socket (connected); True with Sample
  if an acceptable answer came in time. }
function Exchange(Socket: Int64; out Sample: TSntpSample; out Verdict: TReplyVerdict): Boolean;
var
  Request: TNtpPacket;
  Reply: TNtpPacket;
  Sent: QWord;
  T1: Int64;
  T4: Int64;
  Deadline: QWord;
  Now: QWord;
  Waited: Int64;
  Received: Int64;
begin
  Result := False;
  Verdict := ReplyWithoutTime;
  T1 := WallClockNanoseconds;
  BuildRequest(Request, T1, Sent);
  if SendOnSocket(Socket, @Request[0], SizeOf(Request), 0) < 0 then
    Exit;
  Deadline := MonotonicNanoseconds div 1000000 + ReplyTimeoutMilliseconds;
  while True do
  begin
    Now := MonotonicNanoseconds div 1000000;
    if Now >= Deadline then
      Exit;
    Waited := WaitForSocket(Socket, SocketReadable, Int64(Deadline - Now));
    if Waited < 0 then
      Exit;
    Received := ReceiveOnSocket(Socket, @Reply[0], SizeOf(Reply), SocketFlagDontWait);
    T4 := WallClockNanoseconds;
    if Received = -ErrorWouldBlock then
      Continue;
    if Received < 0 then
      Exit;
    Verdict := ParseReply(Reply, Integer(Received), Sent, T1, T4, Sample);
    case Verdict of
      ReplyAccepted:
        Exit(True);
      ReplyNotOurs:
        Continue;
    else
      Exit;
    end;
  end;
end;

function AskAddress(constref Address: TAbiSocketAddress; var Samples: TSampleArray; out Problem: string): Boolean;
var
  Socket: Int64;
  Round: Integer;
  Sample: TSntpSample;
  Verdict: TReplyVerdict;
begin
  Result := False;
  Problem := 'no answer from ' + SocketAddressToText(Address);
  Socket := CreateSocket(Address.Family, SocketKindDatagram, ProtocolUdp);
  if Socket < 0 then
  begin
    Problem := 'no socket: ' + ErrorMessage(ErrorCodeOf(Socket));
    Exit;
  end;
  if ConnectSocket(Socket, Address) <> ErrorNone then
  begin
    CloseSocket(Socket);
    Problem := 'no route to ' + SocketAddressToText(Address);
    Exit;
  end;
  for Round := 1 to RequestsPerPoll do
  begin
    if Exchange(Socket, Sample, Verdict) then
    begin
      SetLength(Samples, Length(Samples) + 1);
      Samples[High(Samples)] := Sample;
    end
    else if Verdict in [ReplyKissOfDeath, ReplyUnsynchronized] then
    begin
      Problem := SocketAddressToText(Address) + ': ' + VerdictText(Verdict);
      Break;
    end;
  end;
  CloseSocket(Socket);
  Result := Length(Samples) > 0;
end;

function AskTimeServer(const Server: string; out Samples: TSampleArray; out Problem: string): Boolean;
var
  Host: string;
  Port: Word;
  Addresses: TInternetAddressArray;
  Error: LongInt;
  Index: Integer;
begin
  Samples := nil;
  Result := False;
  SplitServer(Server, Host, Port);
  Error := ResolveHost(Host, HostFamilyAny, Addresses);
  if (Error <> ErrorNone) or (Length(Addresses) = 0) then
  begin
    Problem := Host + ': ' + HostLookupErrorMessage(Error);
    Exit;
  end;
  for Index := 0 to High(Addresses) do
    if AskAddress(MakeSocketAddress(Addresses[Index], Port), Samples, Problem) then
      Exit(True);
end;

end.
