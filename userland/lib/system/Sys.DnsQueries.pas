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
  Asking DNS servers (the resolver's lower half, which host and nslookup
  use directly).

  A query goes over UDP to the system's DNS servers (the kernel keeps
  them, CallGetDnsServers; the network service sets them) or to the ones
  the caller names: each server in turn, as many rounds as Attempts,
  waiting TimeoutMilliseconds for each. Every query has a new random id
  and leaves from a random source port, and the socket is connected to
  the server, so only datagrams from it are taken; a reply counts only
  if its id and its question are the query's. A truncated reply is
  asked again over TCP. A server that fails (SERVFAIL, REFUSED, NOTIMP,
  FORMERR) or does not answer is passed over for the next; if every one
  failed, the last failure is the answer.

  QueryDnsSearching also tries the search domain for a name of one
  label ("www" is asked as "www.example.com" first, then as it is).
}
unit Sys.DnsQueries;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  Abi.SystemCalls,
  Sys.DnsMessages;

const
  DnsServerPort = 53;
  DefaultDnsTimeoutMilliseconds = 2500;
  DefaultDnsAttempts = 2;

type
  TDnsServerList = array of TAbiSocketAddress;

  TDnsQueryOptions = record
    { Asked in turn. }
    Servers: TDnsServerList;
    SearchDomain: string;
    { For each server, each round. }
    TimeoutMilliseconds: LongWord;
    { Rounds over the servers. }
    Attempts: LongWord;
    RecursionDesired: Boolean;
    { Ask over TCP from the start. }
    TcpOnly: Boolean;
  end;

  { How a query went. }
  TDnsQueryDetails = record
    { Who answered. }
    Server: TAbiSocketAddress;
    { The name asked for (with the search domain, if it was tried). }
    QueriedName: string;
    UsedTcp: Boolean;
    { From sending the query that was answered to its answer. }
    ElapsedMilliseconds: QWord;
  end;

{ The system's servers and search domain, the default timeout and
  attempts, recursion wanted. }
procedure SystemDnsQueryOptions(out Options: TDnsQueryOptions);
{ Asks only Server from now on. }
procedure UseOnlyDnsServer(var Options: TDnsQueryOptions; constref Server: TAbiSocketAddress);

{ Asks for Name's records of RecordType. ErrorNone when a server
  answered (Message holds the answer, whatever its response code),
  ErrorTimedOut if none did, ErrorNotFound if there is no server to
  ask, ErrorInvalidArgument for a name that is not one. }
function QueryDns(const Name: string; RecordType: Word; constref Options: TDnsQueryOptions; out Message: TDnsMessage;
  out Details: TDnsQueryDetails): LongInt;
{ The same, trying Name in the search domain first if it is a single
  label (the name as it is follows if that does not exist). }
function QueryDnsSearching(const Name: string; RecordType: Word; constref Options: TDnsQueryOptions;
  out Message: TDnsMessage; out Details: TDnsQueryDetails): LongInt;

implementation

uses
  SysUtils,
  Sys.Errors,
  Sys.Kernel,
  Sys.Sockets,
  Sys.InternetAddresses,
  Sys.NetworkInterfaces,
  Sys.RandomNumbers,
  Sys.DnsNames;

const
  FirstRandomPort = 49152;
  RandomPortCount = 16384;
  PortTries = 8;
  { Room for a reply over UDP: 512 bytes, or more from a server that
    sends more anyway. }
  UdpReplyCapacity = 1500;

type
  TPendingQuery = record
    Name: string;
    RecordType: Word;
    Id: Word;
    Query: array[0..MaximumUdpDnsMessage - 1] of Byte;
    QueryLength: LongWord;
  end;

function NowMilliseconds: QWord;
begin
  Result := QWord(KernelGetTime(TimeUptimeMilliseconds));
end;

procedure SystemDnsQueryOptions(out Options: TDnsQueryOptions);
var
  Servers: TAbiDnsServers;
  Index: Integer;
begin
  Options := Default(TDnsQueryOptions);
  Options.TimeoutMilliseconds := DefaultDnsTimeoutMilliseconds;
  Options.Attempts := DefaultDnsAttempts;
  Options.RecursionDesired := True;
  if GetDnsServers(Servers) <> ErrorNone then
    Exit;
  if Servers.Count > MaximumDnsServers then
    Servers.Count := MaximumDnsServers;
  SetLength(Options.Servers, Servers.Count);
  for Index := 0 to High(Options.Servers) do
  begin
    Options.Servers[Index] := Servers.Servers[Index];
    if Options.Servers[Index].Port = 0 then
      Options.Servers[Index].Port := DnsServerPort;
  end;
  Servers.SearchDomain[High(Servers.SearchDomain)] := #0;
  Options.SearchDomain := StrPas(PChar(@Servers.SearchDomain[0]));
end;

procedure UseOnlyDnsServer(var Options: TDnsQueryOptions; constref Server: TAbiSocketAddress);
begin
  SetLength(Options.Servers, 1);
  Options.Servers[0] := Server;
  if Options.Servers[0].Port = 0 then
    Options.Servers[0].Port := DnsServerPort;
end;

{ A random port from the dynamic range, so that replies cannot be
  guessed at; the kernel's choice if every try is taken. }
procedure BindToRandomPort(Socket: Int64; Family: Word);
var
  Attempt: Integer;
  Address: TAbiSocketAddress;
  Any: TInternetAddress;
begin
  if Family = AddressFamilyIPv6 then
    Any := AnyIpv6Address
  else
    Any := AnyIpv4Address;
  for Attempt := 1 to PortTries do
  begin
    Address := MakeSocketAddress(Any, Word(FirstRandomPort + RandomBelow(RandomPortCount)));
    if BindSocket(Socket, Address) = ErrorNone then
      Exit;
  end;
end;

{ True if Reply (Length bytes) answers Pending. }
function ReplyMatches(Reply: PByte; Length: LongWord; constref Pending: TPendingQuery): Boolean;
var
  Id: Word;
  Flags: Word;
  QuestionName: string;
  QuestionType: Word;
  QuestionClass: Word;
begin
  Result := False;
  if not ParseDnsHeader(Reply, Length, Id, Flags, QuestionName, QuestionType, QuestionClass) then
    Exit;
  if (Id <> Pending.Id) or ((Flags and DnsFlagResponse) = 0) then
    Exit;
  { A server that could not read the query may leave the question out. }
  if QuestionName = '' then
    Exit((Flags and DnsResponseCodeMask) <> DnsResponseNoError);
  Result := DnsNamesAreEqual(QuestionName, Pending.Name) and (QuestionType = Pending.RecordType) and
    (QuestionClass = DnsClassInternet);
end;

function ExchangeOverUdp(constref Server: TAbiSocketAddress; constref Pending: TPendingQuery;
  Timeout: LongWord; Reply: PByte; out ReplyLength: LongWord): LongInt;
var
  Socket: Int64;
  Deadline: QWord;
  Now: QWord;
  Waited: Int64;
  Received: Int64;
begin
  ReplyLength := 0;
  { A socket of the server's family: servers may be IPv4 or IPv6. }
  Socket := CreateSocket(Server.Family, SocketKindDatagram, ProtocolUdp);
  if Socket < 0 then
    Exit(ErrorCodeOf(Socket));
  BindToRandomPort(Socket, Server.Family);
  Result := ConnectSocket(Socket, Server);
  if Result = ErrorNone then
  begin
    Received := SendOnSocket(Socket, @Pending.Query[0], Pending.QueryLength, 0);
    if Received < 0 then
      Result := ErrorCodeOf(Received);
  end;
  Deadline := NowMilliseconds + Timeout;
  while Result = ErrorNone do
  begin
    Now := NowMilliseconds;
    if Now >= Deadline then
    begin
      Result := ErrorTimedOut;
      Break;
    end;
    Waited := WaitForSocket(Socket, SocketReadable, Int64(Deadline - Now));
    if Waited < 0 then
    begin
      Result := ErrorCodeOf(Waited);
      Break;
    end;
    Received := ReceiveOnSocket(Socket, Reply, UdpReplyCapacity, SocketFlagDontWait);
    if Received = -ErrorWouldBlock then
      Continue;
    if Received < 0 then
    begin
      Result := ErrorCodeOf(Received);
      Break;
    end;
    if ReplyMatches(Reply, LongWord(Received), Pending) then
    begin
      ReplyLength := LongWord(Received);
      Break;
    end;
  end;
  CloseSocket(Socket);
end;

{ Receives exactly Count bytes. }
function ReceiveExactly(Socket: Int64; Buffer: PByte; Count: LongWord): LongInt;
var
  Done: LongWord;
  Received: Int64;
begin
  Done := 0;
  while Done < Count do
  begin
    Received := ReceiveOnSocket(Socket, Buffer + Done, Count - Done, 0);
    if Received = -ErrorWouldBlock then
      Exit(ErrorTimedOut);
    if Received < 0 then
      Exit(ErrorCodeOf(Received));
    if Received = 0 then
      Exit(ErrorConnectionReset);
    Done := Done + LongWord(Received);
  end;
  Result := ErrorNone;
end;

{ Reply is MaximumTcpDnsMessage bytes. }
function ExchangeOverTcp(constref Server: TAbiSocketAddress; constref Pending: TPendingQuery;
  Timeout: LongWord; Reply: PByte; out ReplyLength: LongWord): LongInt;
var
  Socket: Int64;
  Framed: array[0..MaximumUdpDnsMessage + 1] of Byte;
  LengthBytes: array[0..1] of Byte;
  Expected: LongWord;
begin
  ReplyLength := 0;
  Socket := CreateSocket(Server.Family, SocketKindStream, ProtocolTcp);
  if Socket < 0 then
    Exit(ErrorCodeOf(Socket));
  SetSocketOption(Socket, SocketOptionSendTimeout, Timeout);
  SetSocketOption(Socket, SocketOptionReceiveTimeout, Timeout);
  Result := ConnectSocket(Socket, Server);
  if Result = ErrorNone then
  begin
    Framed[0] := Byte(Pending.QueryLength shr 8);
    Framed[1] := Byte(Pending.QueryLength);
    Move(Pending.Query[0], Framed[2], Pending.QueryLength);
    Result := SendAll(Socket, @Framed[0], Pending.QueryLength + 2);
  end;
  if Result = ErrorNone then
    Result := ReceiveExactly(Socket, @LengthBytes[0], 2);
  if Result = ErrorNone then
  begin
    Expected := (LongWord(LengthBytes[0]) shl 8) or LengthBytes[1];
    Result := ReceiveExactly(Socket, Reply, Expected);
    if (Result = ErrorNone) and not ReplyMatches(Reply, Expected, Pending) then
      Result := ErrorCorrupted;
    if Result = ErrorNone then
      ReplyLength := Expected;
  end;
  CloseSocket(Socket);
end;

function ServerFailed(ResponseCode: Byte): Boolean;
begin
  Result := (ResponseCode = DnsResponseServerFailure) or (ResponseCode = DnsResponseRefused) or
    (ResponseCode = DnsResponseNotImplemented) or (ResponseCode = DnsResponseFormatError);
end;

{ One server, once: UDP (or TCP), and TCP again for a truncated reply.
  ErrorNone with Message read. }
function AskServer(constref Server: TAbiSocketAddress; var Pending: TPendingQuery;
  constref Options: TDnsQueryOptions; Reply: PByte; out Message: TDnsMessage;
  var Details: TDnsQueryDetails): LongInt;
var
  ReplyLength: LongWord;
  TcpLength: LongWord;
  Started: QWord;
  UsedTcp: Boolean;
  Truncated: array[0..UdpReplyCapacity - 1] of Byte;
begin
  Pending.Id := RandomWord;
  Pending.Query[0] := Byte(Pending.Id shr 8);
  Pending.Query[1] := Byte(Pending.Id);
  Started := NowMilliseconds;
  UsedTcp := Options.TcpOnly;
  if UsedTcp then
    Result := ExchangeOverTcp(Server, Pending, Options.TimeoutMilliseconds, Reply, ReplyLength)
  else
  begin
    Result := ExchangeOverUdp(Server, Pending, Options.TimeoutMilliseconds, Reply, ReplyLength);
    if (Result = ErrorNone) and (ReplyLength >= 4) and ((Reply[2] and (DnsFlagTruncated shr 8)) <> 0) then
    begin
      { The whole answer over TCP; the truncated one if that fails. }
      Move(Reply^, Truncated[0], ReplyLength);
      if ExchangeOverTcp(Server, Pending, Options.TimeoutMilliseconds, Reply, TcpLength) = ErrorNone then
      begin
        ReplyLength := TcpLength;
        UsedTcp := True;
      end
      else
        Move(Truncated[0], Reply^, ReplyLength);
    end;
  end;
  if Result <> ErrorNone then
    Exit;
  if not ParseDnsMessage(Reply, ReplyLength, Message) then
    Exit(ErrorCorrupted);
  Details.Server := Server;
  Details.UsedTcp := UsedTcp;
  Details.ElapsedMilliseconds := NowMilliseconds - Started;
end;

function QueryDns(const Name: string; RecordType: Word; constref Options: TDnsQueryOptions; out Message: TDnsMessage;
  out Details: TDnsQueryDetails): LongInt;
var
  Pending: TPendingQuery;
  Reply: PByte;
  Attempt: LongWord;
  ServerIndex: Integer;
  Error: LongInt;
  HaveFailure: Boolean;
  Failure: TDnsMessage;
  FailureDetails: TDnsQueryDetails;
begin
  Details := Default(TDnsQueryDetails);
  Message := Default(TDnsMessage);
  Details.QueriedName := Name;
  if Length(Options.Servers) = 0 then
    Exit(ErrorNotFound);
  Pending.Name := Name;
  Pending.RecordType := RecordType;
  Pending.Id := 0;
  if not BuildDnsQuery(0, Name, RecordType, Options.RecursionDesired, @Pending.Query[0], SizeOf(Pending.Query),
       Pending.QueryLength) then
    Exit(ErrorInvalidArgument);
  Reply := GetMem(MaximumTcpDnsMessage);
  HaveFailure := False;
  Result := ErrorTimedOut;
  try
    for Attempt := 1 to Options.Attempts do
      for ServerIndex := 0 to High(Options.Servers) do
      begin
        Error := AskServer(Options.Servers[ServerIndex], Pending, Options, Reply, Message, Details);
        if Error <> ErrorNone then
        begin
          if not HaveFailure then
            Result := Error;
          Continue;
        end;
        if not ServerFailed(Message.ResponseCode) then
          Exit(ErrorNone);
        { Kept in case no other server does better. }
        Failure := Message;
        FailureDetails := Details;
        HaveFailure := True;
        Result := ErrorNone;
      end;
    if HaveFailure then
    begin
      Message := Failure;
      Details := FailureDetails;
    end;
  finally
    FreeMem(Reply);
  end;
end;

function QueryDnsSearching(const Name: string; RecordType: Word; constref Options: TDnsQueryOptions;
  out Message: TDnsMessage; out Details: TDnsQueryDetails): LongInt;
begin
  if (Options.SearchDomain <> '') and IsSingleLabelName(Name) and (Name[Length(Name)] <> '.') then
  begin
    Result := QueryDns(JoinDnsNames(Name, Options.SearchDomain), RecordType, Options, Message, Details);
    if (Result = ErrorNone) and (Message.ResponseCode <> DnsResponseNameError) then
      Exit;
  end;
  Result := QueryDns(Name, RecordType, Options, Message, Details);
end;

end.
