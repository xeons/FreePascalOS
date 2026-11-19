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
  Default address selection for IPv6 (RFC 6724): which of this
  machine's addresses a datagram leaves from (the kernel), and in which
  order a host's addresses are tried (the resolver, as getaddrinfo).
  Self-contained, used by the kernel, libsystem and the host tests.

  Addresses are sixteen bytes; an IPv4 address is written as v4-mapped
  (::ffff:a.b.c.d), which is how the policy table sees it.

  The policy table is RFC 6724 2.1's:
      prefix          precedence  label
      ::1/128             50        0
      ::/0                40        1
      ::ffff:0:0/96       35        4
      2002::/16           30        2
      2001::/32            5        5
      fc00::/7             3       13
      ::/96                1        3
      fec0::/10            1       11
      3ffe::/16            1       12
  Scopes (3.1, 3.2): a multicast address's own; link-local unicast and
  ::1, and IPv4's 127/8 and 169.254/16, are link scope (2); fec0::/10
  site (5); every other address global (14).

  Source selection compares two candidates by rules 1, 2, 3, 5, 6, 7
  and 8 (no mobility, so not rule 4; rule 5.5 needs what this host does
  not keep). Destination ordering sorts by rules 1, 2, 3, 5, 6, 8, 9
  and 10 (no mobility or encapsulation: not 4 or 7); rule 9 (the longest
  matching prefix, up to 64 bits) only between IPv6 destinations, as
  common systems do.
}
unit AddressSelection;

{$mode objfpc}

interface

const
  SelectionAddressBytes = 16;
  ScopeInterfaceLocal = 1;
  ScopeLinkLocal = 2;
  ScopeAdminLocal = 4;
  ScopeSiteLocal = 5;
  ScopeOrganizationLocal = 8;
  ScopeGlobal = 14;

type
  TSelectionAddress = array[0..SelectionAddressBytes - 1] of Byte;

  { A source address the kernel could use. }
  TSourceCandidate = record
    Address: TSelectionAddress;
    { The prefix of its subnet (rule 8 looks no further). }
    PrefixLength: LongWord;
    IsDeprecated: Boolean;
    IsTemporary: Boolean;
    { It belongs to the interface the datagram leaves by. }
    IsOnOutgoingInterface: Boolean;
  end;

  { A destination with the source it would be sent from. }
  TDestinationCandidate = record
    Address: TSelectionAddress;
    { False: no source (no route): unusable (rule 1). }
    HasSource: Boolean;
    Source: TSelectionAddress;
    SourceIsDeprecated: Boolean;
    { Where it was in the list given (rule 10). }
    OriginalPosition: LongInt;
  end;

  PSourceCandidateArray = ^TSourceCandidateArray;
  TSourceCandidateArray = array[0..1023] of TSourceCandidate;

{ An IPv4 address (its four bytes in order) as v4-mapped. }
function MappedIpv4SelectionAddress(First, Second, Third, Fourth: Byte): TSelectionAddress;
function IsMappedIpv4SelectionAddress(constref Address: TSelectionAddress): Boolean;
function SelectionAddressScope(constref Address: TSelectionAddress): LongWord;
function SelectionAddressPrecedence(constref Address: TSelectionAddress): LongWord;
function SelectionAddressLabel(constref Address: TSelectionAddress): LongWord;
{ How many leading bits the two have in common (0-128). }
function CommonSelectionPrefixLength(constref First, Second: TSelectionAddress): LongWord;

{ Negative if First is the better source for Destination, positive if
  Second is, 0 if the rules cannot tell. PreferTemporary: rule 7 (the
  interface does privacy addresses). }
function CompareSourceCandidates(constref First, Second: TSourceCandidate; constref Destination: TSelectionAddress;
  PreferTemporary: Boolean): LongInt;
{ The position of the best candidate (of Count at Candidates); -1 if
  Count is 0. }
function ChooseSourceCandidate(Candidates: PSourceCandidateArray; Count: LongInt;
  constref Destination: TSelectionAddress; PreferTemporary: Boolean): LongInt;

{ Negative if First is to be tried before Second (rules 1 to 10). }
function CompareDestinationCandidates(constref First, Second: TDestinationCandidate): LongInt;
{ Sorts the destinations in the order to try them (stable). }
procedure OrderDestinationCandidates(var Candidates: array of TDestinationCandidate);

implementation

type
  TPolicyEntry = record
    Prefix: TSelectionAddress;
    PrefixLength: LongWord;
    Precedence: LongWord;
    LabelValue: LongWord;
  end;

const
  PolicyEntryCount = 9;
  PolicyTable: array[0..PolicyEntryCount - 1] of TPolicyEntry = (
    (Prefix: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1); PrefixLength: 128; Precedence: 50; LabelValue: 0),
    (Prefix: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0); PrefixLength: 0; Precedence: 40; LabelValue: 1),
    (Prefix: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, $FF, $FF, 0, 0, 0, 0); PrefixLength: 96; Precedence: 35; LabelValue: 4),
    (Prefix: ($20, $02, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0); PrefixLength: 16; Precedence: 30; LabelValue: 2),
    (Prefix: ($20, $01, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0); PrefixLength: 32; Precedence: 5; LabelValue: 5),
    (Prefix: ($FC, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0); PrefixLength: 7; Precedence: 3; LabelValue: 13),
    (Prefix: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0); PrefixLength: 96; Precedence: 1; LabelValue: 3),
    (Prefix: ($FE, $C0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0); PrefixLength: 10; Precedence: 1; LabelValue: 11),
    (Prefix: ($3F, $FE, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0); PrefixLength: 16; Precedence: 1; LabelValue: 12));

  { Rule 9 compares no more than the subnet prefix. }
  DestinationPrefixLimit = 64;

function MappedIpv4SelectionAddress(First, Second, Third, Fourth: Byte): TSelectionAddress;
var
  Index: Integer;
begin
  for Index := 0 to SelectionAddressBytes - 1 do
    Result[Index] := 0;
  Result[10] := $FF;
  Result[11] := $FF;
  Result[12] := First;
  Result[13] := Second;
  Result[14] := Third;
  Result[15] := Fourth;
end;

function IsMappedIpv4SelectionAddress(constref Address: TSelectionAddress): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to 9 do
    if Address[Index] <> 0 then
      Exit(False);
  Result := (Address[10] = $FF) and (Address[11] = $FF);
end;

function CommonSelectionPrefixLength(constref First, Second: TSelectionAddress): LongWord;
var
  Index: Integer;
  Difference: Byte;
begin
  Result := 0;
  for Index := 0 to SelectionAddressBytes - 1 do
  begin
    Difference := First[Index] xor Second[Index];
    if Difference = 0 then
    begin
      Result := Result + 8;
      Continue;
    end;
    while (Difference and $80) = 0 do
    begin
      Inc(Result);
      Difference := Byte(Difference shl 1);
    end;
    Exit;
  end;
end;

function MatchesPrefix(constref Address, Prefix: TSelectionAddress; PrefixLength: LongWord): Boolean;
begin
  Result := CommonSelectionPrefixLength(Address, Prefix) >= PrefixLength;
end;

{ The policy entry with the longest prefix that matches. }
function FindPolicy(constref Address: TSelectionAddress): Integer;
var
  Index: Integer;
  BestLength: LongInt;
begin
  Result := 1;
  BestLength := -1;
  for Index := 0 to PolicyEntryCount - 1 do
    if MatchesPrefix(Address, PolicyTable[Index].Prefix, PolicyTable[Index].PrefixLength) and
       (LongInt(PolicyTable[Index].PrefixLength) > BestLength) then
    begin
      Result := Index;
      BestLength := PolicyTable[Index].PrefixLength;
    end;
end;

function SelectionAddressPrecedence(constref Address: TSelectionAddress): LongWord;
begin
  Result := PolicyTable[FindPolicy(Address)].Precedence;
end;

function SelectionAddressLabel(constref Address: TSelectionAddress): LongWord;
begin
  Result := PolicyTable[FindPolicy(Address)].LabelValue;
end;

function IsLoopbackSelectionAddress(constref Address: TSelectionAddress): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to 14 do
    if Address[Index] <> 0 then
      Exit(False);
  Result := Address[15] = 1;
end;

function SelectionAddressScope(constref Address: TSelectionAddress): LongWord;
begin
  if Address[0] = $FF then
    Exit(Address[1] and $0F);
  if IsMappedIpv4SelectionAddress(Address) then
  begin
    if (Address[12] = 127) or ((Address[12] = 169) and (Address[13] = 254)) then
      Exit(ScopeLinkLocal);
    Exit(ScopeGlobal);
  end;
  if IsLoopbackSelectionAddress(Address) then
    Exit(ScopeLinkLocal);
  if (Address[0] = $FE) and ((Address[1] and $C0) = $80) then
    Exit(ScopeLinkLocal);
  if (Address[0] = $FE) and ((Address[1] and $C0) = $C0) then
    Exit(ScopeSiteLocal);
  Result := ScopeGlobal;
end;

function SameSelectionAddress(constref First, Second: TSelectionAddress): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to SelectionAddressBytes - 1 do
    if First[Index] <> Second[Index] then
      Exit(False);
  Result := True;
end;

{ -1 if the condition prefers First, 1 if it prefers Second, else 0. }
function Prefer(FirstHolds, SecondHolds: Boolean): LongInt;
begin
  if FirstHolds and not SecondHolds then
    Exit(-1);
  if SecondHolds and not FirstHolds then
    Exit(1);
  Result := 0;
end;

function CompareSourceCandidates(constref First, Second: TSourceCandidate; constref Destination: TSelectionAddress;
  PreferTemporary: Boolean): LongInt;
var
  FirstScope: LongWord;
  SecondScope: LongWord;
  DestinationScope: LongWord;
  DestinationLabel: LongWord;
  FirstCommon: LongWord;
  SecondCommon: LongWord;
begin
  { Rule 1: the destination itself. }
  Result := Prefer(SameSelectionAddress(First.Address, Destination), SameSelectionAddress(Second.Address, Destination));
  if Result <> 0 then
    Exit;
  { Rule 2: the appropriate scope. }
  FirstScope := SelectionAddressScope(First.Address);
  SecondScope := SelectionAddressScope(Second.Address);
  DestinationScope := SelectionAddressScope(Destination);
  if FirstScope < SecondScope then
  begin
    if FirstScope < DestinationScope then
      Exit(1);
    Exit(-1);
  end;
  if SecondScope < FirstScope then
  begin
    if SecondScope < DestinationScope then
      Exit(-1);
    Exit(1);
  end;
  { Rule 3: not deprecated. }
  Result := Prefer(not First.IsDeprecated, not Second.IsDeprecated);
  if Result <> 0 then
    Exit;
  { Rule 5: the outgoing interface. }
  Result := Prefer(First.IsOnOutgoingInterface, Second.IsOnOutgoingInterface);
  if Result <> 0 then
    Exit;
  { Rule 6: a matching label. }
  DestinationLabel := SelectionAddressLabel(Destination);
  Result := Prefer(SelectionAddressLabel(First.Address) = DestinationLabel,
    SelectionAddressLabel(Second.Address) = DestinationLabel);
  if Result <> 0 then
    Exit;
  { Rule 7: temporary addresses. }
  if PreferTemporary then
  begin
    Result := Prefer(First.IsTemporary, Second.IsTemporary);
    if Result <> 0 then
      Exit;
  end;
  { Rule 8: the longest matching prefix, within the source's subnet. }
  FirstCommon := CommonSelectionPrefixLength(First.Address, Destination);
  if FirstCommon > First.PrefixLength then
    FirstCommon := First.PrefixLength;
  SecondCommon := CommonSelectionPrefixLength(Second.Address, Destination);
  if SecondCommon > Second.PrefixLength then
    SecondCommon := Second.PrefixLength;
  if FirstCommon > SecondCommon then
    Exit(-1);
  if SecondCommon > FirstCommon then
    Exit(1);
  Result := 0;
end;

function ChooseSourceCandidate(Candidates: PSourceCandidateArray; Count: LongInt;
  constref Destination: TSelectionAddress; PreferTemporary: Boolean): LongInt;
var
  Index: LongInt;
begin
  if Count <= 0 then
    Exit(-1);
  Result := 0;
  for Index := 1 to Count - 1 do
    if CompareSourceCandidates(Candidates^[Index], Candidates^[Result], Destination, PreferTemporary) < 0 then
      Result := Index;
end;

function CompareDestinationCandidates(constref First, Second: TDestinationCandidate): LongInt;
var
  FirstScope: LongWord;
  SecondScope: LongWord;
  FirstPrecedence: LongWord;
  SecondPrecedence: LongWord;
  FirstCommon: LongWord;
  SecondCommon: LongWord;
begin
  { Rule 1: unusable destinations last. }
  Result := Prefer(First.HasSource, Second.HasSource);
  if (Result <> 0) or not First.HasSource then
  begin
    if Result = 0 then
      Result := First.OriginalPosition - Second.OriginalPosition;
    Exit;
  end;
  FirstScope := SelectionAddressScope(First.Address);
  SecondScope := SelectionAddressScope(Second.Address);
  { Rule 2: the scope of the source matches. }
  Result := Prefer(FirstScope = SelectionAddressScope(First.Source),
    SecondScope = SelectionAddressScope(Second.Source));
  if Result <> 0 then
    Exit;
  { Rule 3: no deprecated source. }
  Result := Prefer(not First.SourceIsDeprecated, not Second.SourceIsDeprecated);
  if Result <> 0 then
    Exit;
  { Rule 5: the label of the source matches. }
  Result := Prefer(SelectionAddressLabel(First.Source) = SelectionAddressLabel(First.Address),
    SelectionAddressLabel(Second.Source) = SelectionAddressLabel(Second.Address));
  if Result <> 0 then
    Exit;
  { Rule 6: higher precedence. }
  FirstPrecedence := SelectionAddressPrecedence(First.Address);
  SecondPrecedence := SelectionAddressPrecedence(Second.Address);
  if FirstPrecedence > SecondPrecedence then
    Exit(-1);
  if SecondPrecedence > FirstPrecedence then
    Exit(1);
  { Rule 8: smaller scope. }
  if FirstScope < SecondScope then
    Exit(-1);
  if SecondScope < FirstScope then
    Exit(1);
  { Rule 9: the longest matching prefix (IPv6 only). }
  if not IsMappedIpv4SelectionAddress(First.Address) and not IsMappedIpv4SelectionAddress(Second.Address) then
  begin
    FirstCommon := CommonSelectionPrefixLength(First.Source, First.Address);
    if FirstCommon > DestinationPrefixLimit then
      FirstCommon := DestinationPrefixLimit;
    SecondCommon := CommonSelectionPrefixLength(Second.Source, Second.Address);
    if SecondCommon > DestinationPrefixLimit then
      SecondCommon := DestinationPrefixLimit;
    if FirstCommon > SecondCommon then
      Exit(-1);
    if SecondCommon > FirstCommon then
      Exit(1);
  end;
  { Rule 10: as they came. }
  Result := First.OriginalPosition - Second.OriginalPosition;
end;

procedure OrderDestinationCandidates(var Candidates: array of TDestinationCandidate);
var
  Outer: LongInt;
  Inner: LongInt;
  Moving: TDestinationCandidate;
begin
  { Insertion sort: short lists, and stable. }
  for Outer := 1 to High(Candidates) do
  begin
    Moving := Candidates[Outer];
    Inner := Outer - 1;
    while (Inner >= 0) and (CompareDestinationCandidates(Moving, Candidates[Inner]) < 0) do
    begin
      Candidates[Inner + 1] := Candidates[Inner];
      Dec(Inner);
    end;
    Candidates[Inner + 1] := Moving;
  end;
end;

end.
