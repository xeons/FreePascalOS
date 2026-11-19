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
  The IPv6 stack's pure logic on the host:
    - SHA-256 against FIPS 180-4's examples (Network.Sha256);
    - RFC 7217 stable-privacy identifiers (Network.InterfaceIdentifiers)
      against a digest worked out by hand from the same inputs, and the
      reserved identifiers of RFC 5453;
    - RFC 6724 source selection and destination ordering
      (AddressSelection) with the examples of its section 10;
    - the destination cache: path MTUs and redirects with their expiry
      (Network.DestinationTable);
    - cutting a datagram into fragments (Network.FragmentBuilder).
}
program Ipv6Test;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  TestChecks,
  Network.Sha256,
  Network.InterfaceIdentifiers,
  Network.DestinationTable,
  Network.FragmentBuilder,
  AddressSelection;

{ --- Addresses written as text ------------------------------------------- }

function ParseIpv4(const Text: string; out Address: TSelectionAddress): Boolean;
var
  Parts: TStringArray;
  Index: Integer;
  Values: array[0..3] of Byte;
begin
  Parts := Text.Split('.');
  if Length(Parts) <> 4 then
    Exit(False);
  for Index := 0 to 3 do
    Values[Index] := StrToInt(Parts[Index]);
  Address := MappedIpv4SelectionAddress(Values[0], Values[1], Values[2], Values[3]);
  Result := True;
end;

{ An IPv6 address (with at most one "::") or an IPv4 one, as v4-mapped. }
function Address(const Text: string): TSelectionAddress;
var
  Halves: TStringArray;
  Head: TStringArray;
  Tail: TStringArray;
  Groups: array[0..7] of Word;
  Index: Integer;
begin
  if ParseIpv4(Text, Result) then
    Exit;
  for Index := 0 to 7 do
    Groups[Index] := 0;
  Halves := Text.Split(['::']);
  Head := nil;
  Tail := nil;
  if Halves[0] <> '' then
    Head := Halves[0].Split(':');
  if (Length(Halves) > 1) and (Halves[1] <> '') then
    Tail := Halves[1].Split(':');
  for Index := 0 to High(Head) do
    Groups[Index] := StrToInt('$' + Head[Index]);
  for Index := 0 to High(Tail) do
    Groups[8 - Length(Tail) + Index] := StrToInt('$' + Tail[Index]);
  for Index := 0 to 7 do
  begin
    Result[Index * 2] := Byte(Groups[Index] shr 8);
    Result[Index * 2 + 1] := Byte(Groups[Index]);
  end;
end;

function SameAddress(constref First, Second: TSelectionAddress): Boolean;
begin
  Result := CompareMem(@First[0], @Second[0], SelectionAddressBytes);
end;

{ --- SHA-256 -------------------------------------------------------------- }

procedure CheckSha256(const Message, ExpectedHex, Name: string);
var
  Context: TSha256Context;
  Digest: TSha256Digest;
begin
  BeginSha256(Context);
  if Message <> '' then
    AddToSha256(Context, @Message[1], Length(Message));
  FinishSha256(Context, Digest);
  CheckBytes(@Digest[0], Sha256DigestBytes, ExpectedHex, Name);
end;

procedure TestSha256;
var
  Context: TSha256Context;
  Digest: TSha256Digest;
  Million: string;
  Index: Integer;
begin
  CheckSha256('', 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855', 'SHA-256 of nothing');
  CheckSha256('abc', 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad', 'SHA-256 of abc');
  CheckSha256('abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq',
    '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1', 'SHA-256 of two blocks');
  { A million a's, fed in pieces of uneven length. }
  Million := StringOfChar('a', 1000);
  BeginSha256(Context);
  for Index := 1 to 1000 do
    AddToSha256(Context, @Million[1], 1000);
  FinishSha256(Context, Digest);
  CheckBytes(@Digest[0], Sha256DigestBytes, 'cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0',
    'SHA-256 of a million a''s');
end;

{ --- RFC 7217 identifiers ------------------------------------------------- }

procedure TestStableIdentifiers;
var
  Prefix: TByteArray;
  Hardware: TByteArray;
  Secret: TByteArray;
  Input: TByteArray;
  Context: TSha256Context;
  Digest: TSha256Digest;
  Identifier: TInterfaceIdentifier;
  Other: TInterfaceIdentifier;
  Reserved: TInterfaceIdentifier;
  Index: Integer;
  OtherPrefix: TByteArray;
begin
  Prefix := HexToBytes('20010db800010002');
  Hardware := HexToBytes('525400123456');
  Secret := HexToBytes('000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f');
  { The digest of Prefix | Net_Iface | DAD_Counter (0) | secret_key. }
  Input := HexToBytes('20010db800010002' + '525400123456' + '00' +
    '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f');
  BeginSha256(Context);
  AddToSha256(Context, @Input[0], Length(Input));
  FinishSha256(Context, Digest);
  Identifier := MakeStableInterfaceIdentifier(@Prefix[0], @Hardware[0], 6, nil, 0, 0, @Secret[0], 32);
  Check(CompareMem(@Identifier[0], @Digest[0], InterfaceIdentifierBytes),
    'a stable identifier is the first 64 bits of SHA-256 over prefix, interface, counter and secret');
  Other := MakeStableInterfaceIdentifier(@Prefix[0], @Hardware[0], 6, nil, 0, 0, @Secret[0], 32);
  Check(CompareMem(@Identifier[0], @Other[0], InterfaceIdentifierBytes), 'the same inputs give the same identifier');
  OtherPrefix := HexToBytes('20010db800010003');
  Other := MakeStableInterfaceIdentifier(@OtherPrefix[0], @Hardware[0], 6, nil, 0, 0, @Secret[0], 32);
  Check(not CompareMem(@Identifier[0], @Other[0], InterfaceIdentifierBytes), 'another prefix gives another identifier');
  Other := MakeStableInterfaceIdentifier(@Prefix[0], @Hardware[0], 6, nil, 0, 1, @Secret[0], 32);
  Check(not CompareMem(@Identifier[0], @Other[0], InterfaceIdentifierBytes),
    'the next DAD counter gives another identifier');
  Secret[0] := $FF;
  Other := MakeStableInterfaceIdentifier(@Prefix[0], @Hardware[0], 6, nil, 0, 0, @Secret[0], 32);
  Check(not CompareMem(@Identifier[0], @Other[0], InterfaceIdentifierBytes), 'another secret gives another identifier');

  for Index := 0 to 7 do
    Reserved[Index] := 0;
  Check(IsReservedInterfaceIdentifier(Reserved), 'the subnet-router anycast identifier is reserved');
  Reserved[0] := $02; Reserved[1] := $00; Reserved[2] := $5E; Reserved[3] := $FF; Reserved[4] := $FE;
  Reserved[5] := $00; Reserved[6] := $52; Reserved[7] := $13;
  Check(IsReservedInterfaceIdentifier(Reserved), '0200:5eff:fe00:5213 is reserved');
  Reserved[0] := $FD;
  for Index := 1 to 6 do
    Reserved[Index] := $FF;
  Reserved[7] := $80;
  Check(IsReservedInterfaceIdentifier(Reserved), 'fdff:ffff:ffff:ff80 (subnet anycast) is reserved');
  Reserved[7] := $7F;
  Check(not IsReservedInterfaceIdentifier(Reserved), 'fdff:ffff:ffff:ff7f is not reserved');
  Check(not MakeTemporaryInterfaceIdentifier(0, Reserved), 'zero random bits make no temporary identifier');
  Check(MakeTemporaryInterfaceIdentifier(QWord($0123456789ABCDEF), Reserved) and (Reserved[0] = $EF),
    'random bits make a temporary identifier');
end;

{ --- RFC 6724 ------------------------------------------------------------- }

function Source(const Text: string; Deprecated, Temporary: Boolean): TSourceCandidate;
begin
  Result.Address := Address(Text);
  Result.PrefixLength := 64;
  if IsMappedIpv4SelectionAddress(Result.Address) then
    Result.PrefixLength := 96 + 24;
  Result.IsDeprecated := Deprecated;
  Result.IsTemporary := Temporary;
  Result.IsOnOutgoingInterface := True;
end;

procedure CheckSourceChoice(const Destination: string; const Candidates: array of TSourceCandidate;
  const Expected, Name: string);
var
  Chosen: LongInt;
  List: array of TSourceCandidate;
  Index: Integer;
begin
  SetLength(List, Length(Candidates));
  for Index := 0 to High(Candidates) do
    List[Index] := Candidates[Index];
  Chosen := ChooseSourceCandidate(@List[0], Length(List), Address(Destination), True);
  Check((Chosen >= 0) and SameAddress(List[Chosen].Address, Address(Expected)), Name);
end;

procedure TestSourceSelection;
begin
  CheckSourceChoice('2001:db8:1::1', [Source('2001:db8:3::1', False, False), Source('fe80::1', False, False)],
    '2001:db8:3::1', 'source: prefer appropriate scope (global destination)');
  CheckSourceChoice('ff05::1', [Source('2001:db8:3::1', False, False), Source('fe80::1', False, False)],
    '2001:db8:3::1', 'source: prefer appropriate scope (site multicast)');
  CheckSourceChoice('2001:db8:1::1', [Source('2001:db8:1::1', True, False), Source('2001:db8:2::1', False, False)],
    '2001:db8:1::1', 'source: prefer same address');
  CheckSourceChoice('fe80::1', [Source('fe80::2', True, False), Source('2001:db8:1::1', False, False)],
    'fe80::2', 'source: prefer appropriate scope over avoiding deprecated');
  CheckSourceChoice('2001:db8:1::1', [Source('2001:db8:1::2', False, False), Source('2001:db8:3::2', False, False)],
    '2001:db8:1::2', 'source: longest matching prefix');
  CheckSourceChoice('2002:c633:6401::1',
    [Source('2002:c633:6401::d5e3:7953:13eb:22e8', False, True), Source('2001:db8:1::2', False, False)],
    '2002:c633:6401::d5e3:7953:13eb:22e8', 'source: prefer matching label');
  CheckSourceChoice('2001:db8:1::d5e3:0:0:1',
    [Source('2001:db8:1::2', False, False), Source('2001:db8:1::d5e3:7953:13eb:22e8', False, True)],
    '2001:db8:1::d5e3:7953:13eb:22e8', 'source: prefer temporary');
end;

{ Orders Destinations, each with the source chosen from Sources (those of
  its own family), and checks the order against Expected. }
procedure CheckDestinationOrder(const Sources: array of TSourceCandidate; const Destinations: array of string;
  const Expected: array of string; const Name: string);
var
  Candidates: array of TDestinationCandidate;
  Family: array of TSourceCandidate;
  Index: Integer;
  SourceIndex: Integer;
  Chosen: LongInt;
  Matches: Boolean;
begin
  SetLength(Candidates, Length(Destinations));
  for Index := 0 to High(Destinations) do
  begin
    Candidates[Index].Address := Address(Destinations[Index]);
    Candidates[Index].OriginalPosition := Index;
    Family := nil;
    for SourceIndex := 0 to High(Sources) do
      if IsMappedIpv4SelectionAddress(Sources[SourceIndex].Address) =
         IsMappedIpv4SelectionAddress(Candidates[Index].Address) then
      begin
        SetLength(Family, Length(Family) + 1);
        Family[High(Family)] := Sources[SourceIndex];
      end;
    Chosen := -1;
    if Length(Family) > 0 then
      Chosen := ChooseSourceCandidate(@Family[0], Length(Family), Candidates[Index].Address, False);
    Candidates[Index].HasSource := Chosen >= 0;
    if Chosen >= 0 then
    begin
      Candidates[Index].Source := Family[Chosen].Address;
      Candidates[Index].SourceIsDeprecated := Family[Chosen].IsDeprecated;
    end;
  end;
  OrderDestinationCandidates(Candidates);
  Matches := Length(Candidates) = Length(Expected);
  for Index := 0 to High(Expected) do
    if Matches and not SameAddress(Candidates[Index].Address, Address(Expected[Index])) then
      Matches := False;
  Check(Matches, Name);
end;

procedure TestDestinationOrdering;
begin
  CheckDestinationOrder([Source('2001:db8:1::2', False, False), Source('fe80::1', False, False),
    Source('169.254.13.78', False, False)], ['2001:db8:1::1', '198.51.100.121'],
    ['2001:db8:1::1', '198.51.100.121'], 'destinations: prefer matching scope (IPv6 first)');
  CheckDestinationOrder([Source('fe80::1', False, False), Source('198.51.100.117', False, False)],
    ['2001:db8:1::1', '198.51.100.121'], ['198.51.100.121', '2001:db8:1::1'],
    'destinations: prefer matching scope (IPv4 first)');
  CheckDestinationOrder([Source('2001:db8:1::2', False, False), Source('fe80::1', False, False),
    Source('10.1.2.4', False, False)], ['2001:db8:1::1', '10.1.2.3'], ['2001:db8:1::1', '10.1.2.3'],
    'destinations: prefer higher precedence');
  CheckDestinationOrder([Source('2001:db8:1::2', False, False), Source('fe80::2', False, False)],
    ['2001:db8:1::1', 'fe80::1'], ['fe80::1', '2001:db8:1::1'], 'destinations: prefer smaller scope');
  CheckDestinationOrder([Source('2001:db8:1::2', False, False), Source('fe80::2', True, False)],
    ['2001:db8:1::1', 'fe80::1'], ['2001:db8:1::1', 'fe80::1'], 'destinations: avoid deprecated addresses');
  CheckDestinationOrder([Source('2002:c633:6401::2', False, False), Source('fe80::2', False, False)],
    ['2001:db8:1::1', '2002:c633:6401::1'], ['2002:c633:6401::1', '2001:db8:1::1'],
    'destinations: prefer matching label');
  CheckDestinationOrder([Source('2002:c633:6401::2', False, False), Source('2001:db8:1::2', False, False),
    Source('fe80::2', False, False)], ['2002:c633:6401::1', '2001:db8:1::1'],
    ['2001:db8:1::1', '2002:c633:6401::1'], 'destinations: prefer higher precedence (native over 6to4)');
  CheckDestinationOrder([Source('2001:db8:1::2', False, False)], ['198.51.100.1', '2001:db8:1::1'],
    ['2001:db8:1::1', '198.51.100.1'], 'destinations: an unreachable one goes last');
  Check(SelectionAddressScope(Address('ff02::1')) = ScopeLinkLocal, 'ff02::1 is of link scope');
  Check(SelectionAddressScope(Address('127.0.0.1')) = ScopeLinkLocal, '127.0.0.1 is of link scope');
  Check(SelectionAddressScope(Address('10.0.0.1')) = ScopeGlobal, '10.0.0.1 is of global scope');
  Check(SelectionAddressPrecedence(Address('::1')) = 50, '::1 has precedence 50');
  Check(SelectionAddressLabel(Address('fd00::1')) = 13, 'fd00::1 has label 13');
end;

{ --- The destination cache ------------------------------------------------ }

const
  Second = QWord(1000000000);

function Destination(const Text: string): TDestinationAddress;
var
  Parsed: TSelectionAddress;
begin
  Parsed := Address(Text);
  Move(Parsed[0], Result[0], DestinationAddressBytes);
end;

procedure TestDestinationTable;
var
  Table: TDestinationTable;
  NextHop: TDestinationAddress;
  InterfaceIndex: LongWord;
  Index: Integer;
  Filler: TDestinationAddress;
  Router: TDestinationAddress;
begin
  Router := Destination('fe80::9');
  ClearDestinationTable(Table);
  Check(LookupPathMtu(Table, Destination('2001:db8::1'), 0) = 0, 'no path MTU at first');
  Check(RecordPathMtu(Table, Destination('2001:db8::1'), 2, 1400, 1500, 10 * Second, 600 * Second),
    'a smaller path MTU is news');
  Check(LookupPathMtu(Table, Destination('2001:db8::1'), 11 * Second) = 1400, 'the path MTU is kept');
  Check(not RecordPathMtu(Table, Destination('2001:db8::1'), 2, 1450, 1500, 12 * Second, 600 * Second),
    'a larger one than known is no news');
  Check(LookupPathMtu(Table, Destination('2001:db8::1'), 13 * Second) = 1400, 'and does not raise it');
  Check(RecordPathMtu(Table, Destination('2001:db8::1'), 2, 1000, 1500, 14 * Second, 600 * Second),
    'below 1280 is news once');
  Check(LookupPathMtu(Table, Destination('2001:db8::1'), 15 * Second) = MinimumPathMtu, 'but stops at 1280');
  Check(not RecordPathMtu(Table, Destination('2001:db8::2'), 2, 1500, 1500, 15 * Second, 600 * Second),
    'the link MTU itself is no news');
  Check(LookupPathMtu(Table, Destination('2001:db8::1'), 615 * Second) = 0, 'a path MTU expires');
  Check(DestinationEntryCount(Table) = 0, 'and its entry goes');

  RecordRedirect(Table, Destination('2001:db8::5'), Destination('fe80::9'), 2, 0, 60 * Second);
  Check(LookupRedirect(Table, Destination('2001:db8::5'), Second, NextHop, InterfaceIndex) and
    CompareMem(@NextHop[0], @Router[0], 16) and (InterfaceIndex = 2), 'a redirect is kept');
  Check(ExpireDestinations(Table, 2 * Second) = 60 * Second, 'the next expiry is the redirect''s');
  ForgetRedirectsThrough(Table, Destination('fe80::9'), 2);
  Check(not LookupRedirect(Table, Destination('2001:db8::5'), 3 * Second, NextHop, InterfaceIndex),
    'redirects through a router that went are forgotten');
  RecordRedirect(Table, Destination('2001:db8::6'), Destination('fe80::9'), 3, 0, 60 * Second);
  ForgetDestinationsOn(Table, 3);
  Check(DestinationEntryCount(Table) = 0, 'an interface going takes its entries');

  for Index := 0 to MaximumDestinationEntries do
  begin
    Filler := Destination('2001:db8::1');
    Filler[15] := Byte(Index);
    Filler[14] := Byte(Index shr 8);
    RecordPathMtu(Table, Filler, 2, 1300, 1500, QWord(Index + 1) * Second, 600 * Second);
  end;
  Check(DestinationEntryCount(Table) = MaximumDestinationEntries, 'a full table stays full');
  Filler := Destination('2001:db8::1');
  Filler[15] := 0;
  Check(LookupPathMtu(Table, Filler, 100 * Second) = 0, 'the least recently used entry made room');
end;

{ --- Fragments ------------------------------------------------------------ }

procedure TestFragments;
var
  Datagram: array of Byte;
  Output: array[0..1499] of Byte;
  Plan: TFragmentPlan;
  Index: LongWord;
  FragmentLength: LongWord;
  Offsets: array[0..2] of LongWord;
  Lengths: array[0..2] of LongWord;
  Reassembled: array of Byte;
  Offset: LongWord;
  MoreFlags: array[0..2] of Boolean;
  Position: Integer;
  AllSame: Boolean;
begin
  { An IPv6 header (UDP next) and 3000 bytes of payload. }
  SetLength(Datagram, 40 + 3000);
  FillChar(Datagram[0], Length(Datagram), 0);
  Datagram[0] := $60;
  Datagram[4] := Byte(3000 shr 8);
  Datagram[5] := Byte(3000 and $FF);
  Datagram[6] := 17;
  Datagram[7] := 64;
  for Position := 40 to High(Datagram) do
    Datagram[Position] := Byte(Position * 7);
  Check(PlanIpv6Fragments(@Datagram[0], Length(Datagram), 1280, Plan), 'a datagram can be cut for 1280');
  Check(Plan.PieceBytes = 1232, 'pieces of 1232 bytes fit 1280');
  Check(Plan.FragmentCount = 3, 'three fragments');
  SetLength(Reassembled, 3000);
  for Index := 0 to Plan.FragmentCount - 1 do
  begin
    FragmentLength := BuildIpv6Fragment(@Datagram[0], Plan, Index, $12345678, @Output[0]);
    Lengths[Index] := FragmentLength;
    Check(FragmentLength <= 1280, 'fragment ' + IntToStr(Index) + ' fits the MTU');
    Check(Output[6] = 44, 'fragment ' + IntToStr(Index) + ' has a fragment header next');
    Check(Output[40] = 17, 'fragment ' + IntToStr(Index) + ' carries UDP');
    Check((LongWord(Output[4]) shl 8) or Output[5] = FragmentLength - 40,
      'fragment ' + IntToStr(Index) + ' has its own payload length');
    Check((Output[44] = $12) and (Output[47] = $78), 'fragment ' + IntToStr(Index) + ' has the identification');
    Offset := ((LongWord(Output[42]) shl 8) or Output[43]) and $FFF8;
    Offsets[Index] := Offset;
    MoreFlags[Index] := (Output[43] and 1) <> 0;
    Move(Output[48], Reassembled[Offset], FragmentLength - 48);
  end;
  Check((Offsets[0] = 0) and (Offsets[1] = 1232) and (Offsets[2] = 2464), 'the offsets follow each other');
  Check(MoreFlags[0] and MoreFlags[1] and not MoreFlags[2], 'only the last has no more fragments');
  Check(Lengths[2] = 48 + 536, 'the last fragment carries the rest');
  AllSame := CompareMem(@Reassembled[0], @Datagram[40], 3000);
  Check(AllSame, 'the fragments put together give the payload');

  { A hop-by-hop header stays in front of every fragment. }
  Datagram[6] := 0;
  Datagram[40] := 17;
  Datagram[41] := 0;
  Check(PlanIpv6Fragments(@Datagram[0], Length(Datagram), 1280, Plan) and (Plan.UnfragmentableBytes = 48),
    'the hop-by-hop header is unfragmentable');
  FragmentLength := BuildIpv6Fragment(@Datagram[0], Plan, 0, 1, @Output[0]);
  Check((Output[6] = 0) and (Output[40] = 44) and (Output[48] = 17), 'the hop-by-hop header points to the fragment');
  Check(not PlanIpv6Fragments(@Datagram[0], Length(Datagram), 56, Plan), 'an MTU too small cannot be cut for');
end;

begin
  TestSha256;
  TestStableIdentifiers;
  TestSourceSelection;
  TestDestinationOrdering;
  TestDestinationTable;
  TestFragments;
  FinishChecks('IPv6');
end.
