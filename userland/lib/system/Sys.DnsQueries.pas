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

  EDNS(0): queries carry an OPT record advertising EdnsPayloadSize
  bytes (1232 from SystemDnsQueryOptions), so larger answers come over
  UDP; a truncated one still goes to TCP. A server that answers FORMERR
  without an OPT record of its own does not know EDNS, and is asked
  again without it.

  With UseCache (Sys.HostNames sets it) answers are kept in the
  process's cache (Sys.DnsCache: times to live, negative answers by RFC
  2308) and a question asked again is answered from it. The cache is
  emptied when the servers asked change, so an answer from one set of
  servers is never given for another.
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
    { The largest UDP answer advertised with EDNS(0); 0: no EDNS. }
    EdnsPayloadSize: Word;
    { Answer from, and keep answers in, the process's cache. }
    UseCache: Boolean;
  end;

  { How a query went. }
  TDnsQueryDetails = record
    { Who answered. }
    Server: TAbiSocketAddress;
    { The name asked for (with the search domain, if it was tried). }
    QueriedName: string;
    UsedTcp: Boolean;
    { The query that was answered carried an OPT record. }
    UsedEdns: Boolean;
    { The answer came from the cache (Server is who gave it first). }
    FromCache: Boolean;
    { From sending the query that was answered to its answer. }
    ElapsedMilliseconds: QWord;
  end;

{ The system's servers and search domain, the default timeout and
  attempts, recursion wanted, EDNS(0) with 1232 bytes; no cache. }
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
{ Empties the process's cache of answers. }
procedure ClearDnsCache;

implementation

uses
  SysUtils,
  Sys.Errors,
  Sys.Kernel,
  Sys.Sockets,
  Sys.InternetAddresses,
  Sys.NetworkInterfaces,
  Sys.RandomNumbers,
  Sys.DnsCache,
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
    RecursionDesired: Boolean;
    Id: Word;
    Query: array[0..MaximumUdpDnsMessage - 1] of Byte;
    QueryLength: LongWord;
    { The query carries an OPT record. }
    UsesEdns: Boolean;
  end;

var
  AnswerCache: TDnsCache = nil;
  CacheLock: TRTLCriticalSection;
  { The servers the cached answers came from. }
  CachedServers: string = '';

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
  Options.EdnsPayloadSize := DefaultEdnsPayloadSize;
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
  Details.UsedEdns := Pending.UsesEdns;
  Details.FromCache := False;
  Details.ElapsedMilliseconds := NowMilliseconds - Started;
end;

{ The query of Pending again, with an OPT record or without. }
function BuildPendingQuery(var Pending: TPendingQuery; EdnsPayloadSize: Word): Boolean;
begin
  Result := BuildDnsQuery(Pending.Id, Pending.Name, Pending.RecordType, Pending.RecursionDesired, EdnsPayloadSize,
    @Pending.Query[0], SizeOf(Pending.Query), Pending.QueryLength);
  Pending.UsesEdns := Result and (EdnsPayloadSize <> 0);
end;

{ AskServer, and once more without EDNS if the server did not know it
  (FORMERR and no OPT record in the answer, RFC 6891 section 7). }
function AskServerWithEdnsFallback(constref Server: TAbiSocketAddress; var Pending: TPendingQuery;
  constref Options: TDnsQueryOptions; Reply: PByte; out Message: TDnsMessage;
  var Details: TDnsQueryDetails): LongInt;
begin
  Result := AskServer(Server, Pending, Options, Reply, Message, Details);
  if (Result <> ErrorNone) or not Pending.UsesEdns or (Message.ResponseCode <> DnsResponseFormatError) or
     Message.HasEdns then
    Exit;
  if not BuildPendingQuery(Pending, 0) then
    Exit;
  Result := AskServer(Server, Pending, Options, Reply, Message, Details);
  { Later servers are asked with EDNS again. }
  BuildPendingQuery(Pending, Options.EdnsPayloadSize);
end;

{ "10.0.2.3:53 [::1]:53 ...": what the cache's answers depend on. }
function ServersText(constref Options: TDnsQueryOptions): string;
var
  Index: Integer;
begin
  Result := '';
  for Index := 0 to High(Options.Servers) do
    Result := Result + AddressToText(SocketAddressHost(Options.Servers[Index])) + ':' +
      IntToStr(Options.Servers[Index].Port) + ' ';
end;

{ The cache, emptied first if the servers are not those it was filled
  from. Under CacheLock. }
procedure SelectCacheFor(constref Options: TDnsQueryOptions);
var
  Servers: string;
begin
  if AnswerCache = nil then
    AnswerCache := TDnsCache.Create;
  Servers := ServersText(Options);
  if Servers <> CachedServers then
  begin
    AnswerCache.Clear;
    CachedServers := Servers;
  end;
end;

function FindCachedAnswer(const Name: string; RecordType: Word; constref Options: TDnsQueryOptions;
  out Message: TDnsMessage): Boolean;
begin
  EnterCriticalSection(CacheLock);
  try
    SelectCacheFor(Options);
    Result := AnswerCache.Find(Name, RecordType, NowMilliseconds, Message);
  finally
    LeaveCriticalSection(CacheLock);
  end;
end;

procedure StoreAnswer(const Name: string; RecordType: Word; constref Options: TDnsQueryOptions;
  constref Message: TDnsMessage);
begin
  EnterCriticalSection(CacheLock);
  try
    SelectCacheFor(Options);
    AnswerCache.Store(Name, RecordType, Message, NowMilliseconds);
  finally
    LeaveCriticalSection(CacheLock);
  end;
end;

procedure ClearDnsCache;
begin
  EnterCriticalSection(CacheLock);
  try
    if AnswerCache <> nil then
      AnswerCache.Clear;
  finally
    LeaveCriticalSection(CacheLock);
  end;
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
  Pending.RecursionDesired := Options.RecursionDesired;
  Pending.Id := 0;
  if not BuildPendingQuery(Pending, Options.EdnsPayloadSize) then
    Exit(ErrorInvalidArgument);
  if Options.UseCache and FindCachedAnswer(Name, RecordType, Options, Message) then
  begin
    Details.FromCache := True;
    Details.Server := Options.Servers[0];
    Exit(ErrorNone);
  end;
  Reply := GetMem(MaximumTcpDnsMessage);
  HaveFailure := False;
  Result := ErrorTimedOut;
  try
    for Attempt := 1 to Options.Attempts do
      for ServerIndex := 0 to High(Options.Servers) do
      begin
        Error := AskServerWithEdnsFallback(Options.Servers[ServerIndex], Pending, Options, Reply, Message, Details);
        if Error <> ErrorNone then
        begin
          if not HaveFailure then
            Result := Error;
          Continue;
        end;
        if not ServerFailed(Message.ResponseCode) then
        begin
          if Options.UseCache then
            StoreAnswer(Name, RecordType, Options, Message);
          Exit(ErrorNone);
        end;
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

initialization
  InitCriticalSection(CacheLock);

finalization
  AnswerCache.Free;
  DoneCriticalSection(CacheLock);

end.
