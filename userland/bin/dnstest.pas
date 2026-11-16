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
  dnstest - checks the resolver (Sys.HostNames, Sys.DnsQueries)

  dnstest              (root) the checks below
  dnstest --serve      runs the test DNS server until asked to end
  dnstest --wait       waits (5 s at most) until that server answers

  The checks run a DNS server of their own on 127.0.0.1 port 53 with a
  fixed zone (DnsTest.Zone), on a thread, and make it the system's DNS
  server for a while (the servers before are put back): /etc/hosts
  (localhost both ways, ::1), an A record, a CNAME with its target in
  the same answer and one the resolver has to ask again for, the search
  domain for a single label, several addresses, AAAA, a name that does
  not exist, a reverse lookup (PTR), a truncated answer asked again over
  TCP, an answer whose name compression points at itself (refused, not
  followed for ever), a reply with a wrong id (ignored), a server that
  is not there passed over for the next, and new random ids and source
  ports for every query; the server asked over IPv6 ([::1]:53), and
  localhost tried over ::1 first when connecting (Sys.HostLookup).
  Nothing here needs the internet.

  --serve and --wait are for coretest's host and nslookup command lines.

  Each check prints a line; the exit status is 1 if any failed.
}
program DnsTest;

{$mode objfpc}{$H+}

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Streams,
  Sys.Objects,
  Sys.Threads,
  Sys.Processes,
  Sys.Notifications,
  Sys.InternetAddresses,
  Sys.AddressText,
  Sys.HostLookup,
  Sys.NetworkInterfaces,
  Sys.DnsMessages,
  Sys.DnsQueries,
  Sys.HostNames,
  Util.CommandLine,
  Util.Messages,
  Util.Output,
  DnsTest.Zone,
  DnsTest.Server;

var
  Failures: Integer = 0;
  Checks: Integer = 0;
  StopEvent: Int64;
  Message: TDnsMessage;

procedure Check(const Name: string; Passed: Boolean);
begin
  Inc(Checks);
  if Passed then
    PrintStringLine('dnstest: pass: ' + Name)
  else
  begin
    PrintStringLine('dnstest: FAIL: ' + Name);
    Inc(Failures);
  end;
  FlushStream(StandardOutput);
end;

function RunServerThread(Argument: Pointer): LongInt;
begin
  ServeTestZone(StopEvent);
  Result := 0;
end;

function SameAddress(constref Address: TInternetAddress; A, B, C, D: Byte): Boolean;
begin
  Result := AddressesAreEqual(Address, Ipv4Address(A, B, C, D));
end;

function HostIs(const Host: string; A, B, C, D: Byte): Boolean;
var
  Address: TInternetAddress;
begin
  Result := (LookUpHost(Host, Address) = ErrorNone) and SameAddress(Address, A, B, C, D);
end;

{ The address the text stands for (it is a valid one). }
function AddressOf(const Text: string): TInternetAddress;
begin
  TextToAddress(Text, Result);
end;

function AddressNameIs(constref Address: TInternetAddress; const Expected: string): Boolean;
var
  Name: string;
begin
  Result := (LookUpAddressName(Address, Name) = ErrorNone) and (Name = Expected);
end;

function TestServers(const SearchDomain: string; WithMissingServer: Boolean): TAbiDnsServers;
begin
  Result := Default(TAbiDnsServers);
  if WithMissingServer then
  begin
    { Nobody listens on 5399: the port is unreachable at once. }
    Result.Servers[Result.Count] := MakeSocketAddress(LoopbackIpv4Address, 5399);
    Inc(Result.Count);
  end;
  Result.Servers[Result.Count] := MakeSocketAddress(LoopbackIpv4Address, TestServerPort);
  Inc(Result.Count);
  StrPLCopy(PChar(@Result.SearchDomain[0]), SearchDomain, High(Result.SearchDomain));
end;

procedure TestHostsFile;
var
  Found: THostAddresses;
  Address: TInternetAddress;
  HasIpv6: Boolean;
begin
  Check('/etc/hosts: localhost is 127.0.0.1', HostIs('localhost', 127, 0, 0, 1));
  Check('/etc/hosts: LOCALHOST (any case) too', HostIs('LOCALHOST', 127, 0, 0, 1));
  HasIpv6 := False;
  if LookUpHostAddresses('localhost', HostFamilyAny, Found) = ErrorNone then
    for Address in Found.Addresses do
      if AddressesAreEqual(Address, AddressOf('::1')) then
        HasIpv6 := True;
  Check('/etc/hosts: localhost is ::1 as well', HasIpv6);
  Check('/etc/hosts: 127.0.0.1 is named localhost', AddressNameIs(LoopbackIpv4Address, 'localhost'));
  Check('a numeric address needs no lookup', HostIs('10.0.2.15', 10, 0, 2, 15));
end;

procedure TestNames;
var
  Found: THostAddresses;
  Address: TInternetAddress;
begin
  Check('A: www.test.example is 192.0.2.10', HostIs('www.test.example', 192, 0, 2, 10));
  Check('CNAME in the same answer: alias.test.example',
    (LookUpHostAddresses('alias.test.example', HostFamilyIpv4, Found) = ErrorNone) and
    (Length(Found.Addresses) = 1) and SameAddress(Found.Addresses[0], 192, 0, 2, 10) and
    (Found.CanonicalName = 'www.test.example'));
  Check('CNAME asked for again: far.test.example', HostIs('far.test.example', 192, 0, 2, 10));
  Check('the search domain: www is www.test.example', HostIs('www', 192, 0, 2, 10));
  Check('a final dot: www.test.example.', HostIs('www.test.example.', 192, 0, 2, 10));
  Check('two addresses: multi.test.example',
    (LookUpHostAddresses('multi.test.example', HostFamilyIpv4, Found) = ErrorNone) and
    (Length(Found.Addresses) = 2) and SameAddress(Found.Addresses[0], 192, 0, 2, 21) and
    SameAddress(Found.Addresses[1], 192, 0, 2, 22));
  Check('AAAA: www.test.example is 2001:db8::10',
    (LookUpHostAddresses('www.test.example', HostFamilyIpv6, Found) = ErrorNone) and
    (Length(Found.Addresses) = 1) and AddressesAreEqual(Found.Addresses[0], AddressOf('2001:db8::10')));
  Check('a name that does not exist: ErrorNotFound',
    LookUpHost('nosuch.test.example', Address) = ErrorNotFound);
  Check('reverse: 192.0.2.10 is www.test.example',
    AddressNameIs(Ipv4Address(192, 0, 2, 10), 'www.test.example'));
  Check('a reply with a wrong id is ignored: spoof.test.example is 192.0.2.99',
    HostIs('spoof.test.example', 192, 0, 2, 99));
end;

procedure TestQueries;
var
  Options: TDnsQueryOptions;
  Details: TDnsQueryDetails;
  Error: LongInt;
begin
  SystemDnsQueryOptions(Options);
  Error := QueryDns('big.test.example', DnsTypeTxt, Options, Message, Details);
  Check('a truncated answer is asked again over TCP', (Error = ErrorNone) and Details.UsedTcp and
    (Message.RecordCount = 1) and (Message.Records[0].RecordType = DnsTypeTxt) and
    (Message.Records[0].DataLength = BigTextStrings * (BigTextStringBytes + 1)));
  Options.TcpOnly := True;
  Error := QueryDns('www.test.example', DnsTypeMx, Options, Message, Details);
  Check('over TCP from the start: MX 10 mail.test.example', (Error = ErrorNone) and (Message.RecordCount = 1) and
    (Message.Records[0].Preference = 10) and (Message.Records[0].Target = 'mail.test.example'));
  Options.TcpOnly := False;
  Options.Attempts := 1;
  Error := QueryDns('loop.test.example', DnsTypeA, Options, Message, Details);
  Check('name compression that points at itself is refused', Error = ErrorCorrupted);
  Options.Attempts := DefaultDnsAttempts;
  Error := QueryDns('test.example', DnsTypeSoa, Options, Message, Details);
  Check('SOA of test.example', (Error = ErrorNone) and (Message.RecordCount = 1) and
    (Message.Records[0].Serial = 2026111601) and (Message.Records[0].Mailbox = 'hostmaster.test.example'));
  Error := QueryDns('nosuch.test.example', DnsTypeA, Options, Message, Details);
  Check('NXDOMAIN comes with the zone''s SOA', (Error = ErrorNone) and
    (Message.ResponseCode = DnsResponseNameError) and (Message.AuthorityCount = 1));
  Error := QueryDns('www.example.org', DnsTypeA, Options, Message, Details);
  Check('a name outside the zone is refused (the answer is still told)', (Error = ErrorNone) and
    (Message.ResponseCode = DnsResponseRefused));

  QueryDns('www.test.example', DnsTypeA, Options, Message, Details);
  QueryDns('www.test.example', DnsTypeA, Options, Message, Details);
  Check('every query has a new id', ServerRecord.LastIds[0] <> ServerRecord.LastIds[1]);
  Check('every query leaves from a new port', ServerRecord.LastPorts[0] <> ServerRecord.LastPorts[1]);
end;

procedure TestIpv6Server;
var
  Options: TDnsQueryOptions;
  Details: TDnsQueryDetails;
  Error: LongInt;
  Ordered: TInternetAddressArray;
begin
  SystemDnsQueryOptions(Options);
  UseOnlyDnsServer(Options, MakeSocketAddress(LoopbackIpv6Address, TestServerPort));
  Error := QueryDns('www.test.example', DnsTypeAaaa, Options, Message, Details);
  Check('a DNS server over IPv6 ([::1]:53) answers AAAA', (Error = ErrorNone) and (Message.RecordCount = 1) and
    (Message.Records[0].RecordType = DnsTypeAaaa) and (Details.Server.Family = AddressFamilyIPv6));
  Check('to connect, localhost is ::1 first, then 127.0.0.1',
    (ResolveHost('localhost', HostFamilyAny, Ordered) = ErrorNone) and (Length(Ordered) = 2) and
    AddressesAreEqual(Ordered[0], LoopbackIpv6Address) and AddressesAreEqual(Ordered[1], LoopbackIpv4Address));
end;

procedure TestMissingServer;
var
  Servers: TAbiDnsServers;
begin
  Servers := TestServers('test.example', True);
  Check('a server that is not there is passed over', (SetDnsServers(Servers) = ErrorNone) and
    HostIs('www.test.example', 192, 0, 2, 10));
end;

procedure RunChecks;
var
  Saved: TAbiDnsServers;
  Thread: Int64;
  ExitCode: LongInt;
  Error: LongInt;
begin
  TestHostsFile;
  Error := OpenTestServer;
  Check('the test DNS server takes 127.0.0.1 port 53', Error = ErrorNone);
  if Error <> ErrorNone then
    Exit;
  StopEvent := CreateEvent(True, False);
  Thread := CreateThread(@RunServerThread, nil);
  Check('the server thread starts', Thread >= 0);
  GetDnsServers(Saved);
  Check('the test server becomes the system''s', SetDnsServers(TestServers('test.example', False)) = ErrorNone);
  TestNames;
  TestQueries;
  TestIpv6Server;
  TestMissingServer;
  Check('the DNS servers before are put back', SetDnsServers(Saved) = ErrorNone);
  SetEvent(StopEvent);
  Check('the server thread ends', (WaitForThread(Thread, 5000, ExitCode) = 0) and (ExitCode = 0));
  CloseTestServer;
end;

procedure Serve;
var
  Error: LongInt;
begin
  TakeNotifications(NotifyEndRequests or NotifyEndInterrupt);
  Error := OpenTestServer;
  if Error <> ErrorNone then
  begin
    PrintErrorStringLine('dnstest: cannot serve on 127.0.0.1 port 53: ' + ErrorText(Error));
    FlushStream(StandardError);
    Halt(1);
  end;
  ServeTestZone(NotificationsHandle);
  CloseTestServer;
end;

procedure WaitForServer;
var
  Options: TDnsQueryOptions;
  Details: TDnsQueryDetails;
  Tries: Integer;
begin
  SystemDnsQueryOptions(Options);
  UseOnlyDnsServer(Options, MakeSocketAddress(LoopbackIpv4Address, TestServerPort));
  Options.TimeoutMilliseconds := 250;
  Options.Attempts := 1;
  for Tries := 1 to 20 do
  begin
    if QueryDns('www.test.example', DnsTypeA, Options, Message, Details) = ErrorNone then
      Halt(0);
    SleepMilliseconds(250);
  end;
  Halt(1);
end;

var
  Arguments: TStringArray;
  Mode: string = '';
begin
  Arguments := ProgramArguments;
  if Length(Arguments) > 0 then
    Mode := Arguments[0];
  if Mode = '--serve' then
    Serve
  else if Mode = '--wait' then
    WaitForServer
  else
  begin
    RunChecks;
    PrintStringLine(Format('dnstest: %d of %d checks passed', [Checks - Failures, Checks]));
    if Failures > 0 then
      Halt(1);
  end;
end.
