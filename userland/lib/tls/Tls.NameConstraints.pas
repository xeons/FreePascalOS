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
  Name constraints (RFC 5280 section 4.2.1.10): an authority may say
  which names the certificates below it may hold (permitted subtrees)
  and which they may not (excluded subtrees). The chain check applies an
  authority's constraints to every certificate under it on the path.

  The names of a certificate are its subject alternative names, its
  subject (a directoryName, when not empty) and any emailAddress in the
  subject (an rfc822Name). For each name: when the permitted subtrees
  hold any of its type it must lie in one of them, and it must lie in
  none of the excluded subtrees of its type.

    dNSName      "example.com" holds example.com and every name below
                 it; ".example.com" (a common form) only the names
                 below. A wildcard name ("*.example.com") is permitted
                 only when all it can stand for is, and excluded when
                 anything it can stand for is.
    iPAddress    an address and a mask (8 bytes for IPv4, 32 for
                 IPv6); an address of the other family is not in it.
    rfc822Name   "user@host" one mailbox, "host" every mailbox at that
                 host, ".example.com" every mailbox at a host below.
    directoryName  the subject's relative distinguished names begin
                 with the constraint's (compared as DER).

  Comparisons ignore ASCII case (local parts of mailboxes included).
  Names of other types (URIs, other names) cannot be checked: when a
  constraint and a name of such a type meet, the certificate is refused
  as unsupported rather than let through.
}
unit Tls.NameConstraints;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  Tls.Certificates;

{ TlsErrorNone, TlsErrorCertificateNameConstraint, or
  TlsErrorCertificateUnsupported (a constraint that cannot be
  checked). }
function CheckNameConstraints(constref Authority: TTlsCertificate; constref Subject: TTlsCertificate): LongInt;

{ The rules for one name and one constraint (exposed for the tests). }
function DnsNameInSubtree(const Name, Constraint: string): Boolean;
function DnsNameTouchesSubtree(const Name, Constraint: string): Boolean;
function MailboxInSubtree(const Mailbox, Constraint: string): Boolean;
function AddressInSubtree(Address: PByte; AddressLength: PtrUInt; Constraint: PByte; ConstraintLength: PtrUInt): Boolean;

implementation

uses
  SysUtils,
  Tls.Asn1,
  Tls.ByteBuffers,
  Tls.Errors,
  Tls.ObjectIdentifiers;

const
  TagMailbox = Asn1ContextSpecific or 1;
  TagDnsName = Asn1ContextSpecific or 2;
  TagDirectory = Asn1ContextSpecific or Asn1Constructed or 4;
  TagAddress = Asn1ContextSpecific or 7;

type
  { One name of the subject: its GeneralName tag and contents. }
  TSubjectName = record
    Tag: Byte;
    Contents: PByte;
    ContentsLength: PtrUInt;
  end;

  TNameVerdict = (VerdictOutside, VerdictInside, VerdictUnsupported);

function ElementText(Contents: PByte; ContentsLength: PtrUInt): string;
begin
  SetString(Result, PChar(Contents), ContentsLength);
end;

function EndsWithText(const Text, Suffix: string): Boolean;
begin
  Result := (Length(Text) >= Length(Suffix)) and
    SameText(Copy(Text, Length(Text) - Length(Suffix) + 1, Length(Suffix)), Suffix);
end;

function DnsNameInSubtree(const Name, Constraint: string): Boolean;
begin
  if Constraint = '' then
    Exit(True);
  if Constraint[1] = '.' then
    Exit((Length(Name) > Length(Constraint)) and EndsWithText(Name, Constraint));
  Result := SameText(Name, Constraint) or EndsWithText(Name, '.' + Constraint);
end;

{ The parent of a wildcard name: "example.com" for "*.example.com". }
function WildcardParent(const Name: string; out Parent: string): Boolean;
begin
  Result := (Length(Name) > 2) and (Name[1] = '*') and (Name[2] = '.');
  if Result then
    Parent := Copy(Name, 3, Length(Name) - 2)
  else
    Parent := '';
end;

function DnsNameTouchesSubtree(const Name, Constraint: string): Boolean;
var
  Parent: string;
  Dot: Integer;
begin
  if DnsNameInSubtree(Name, Constraint) then
    Exit(True);
  if not WildcardParent(Name, Parent) then
    Exit(False);
  { "*.example.com" can stand for "www.example.com": one label more. }
  if (Constraint = '') or (Constraint[1] = '.') then
    Exit(False);
  Dot := Pos('.', Constraint);
  Result := (Dot > 1) and SameText(Copy(Constraint, Dot + 1, Length(Constraint) - Dot), Parent);
end;

function MailboxInSubtree(const Mailbox, Constraint: string): Boolean;
var
  At: Integer;
  Host: string;
begin
  At := LastDelimiter('@', Mailbox);
  if At = 0 then
    Exit(False);
  Host := Copy(Mailbox, At + 1, Length(Mailbox) - At);
  if Constraint = '' then
    Exit(True);
  if Pos('@', Constraint) > 0 then
    Exit(SameText(Mailbox, Constraint));
  if Constraint[1] = '.' then
    Exit((Length(Host) > Length(Constraint)) and EndsWithText(Host, Constraint));
  Result := SameText(Host, Constraint);
end;

function AddressInSubtree(Address: PByte; AddressLength: PtrUInt; Constraint: PByte; ConstraintLength: PtrUInt): Boolean;
var
  Index: PtrUInt;
begin
  if ((AddressLength <> 4) and (AddressLength <> 16)) or (ConstraintLength <> 2 * AddressLength) then
    Exit(False);
  Index := 0;
  while Index < AddressLength do
  begin
    if (Address[Index] and Constraint[AddressLength + Index]) <> (Constraint[Index] and Constraint[AddressLength + Index])
    then
      Exit(False);
    Inc(Index);
  end;
  Result := True;
end;

{ The relative distinguished names of the constraint (a Name) begin
  those of the subject. }
function DirectoryInSubtree(Subject: PByte; SubjectLength: PtrUInt; Constraint: PByte; ConstraintLength: PtrUInt): Boolean;
var
  SubjectReader, ConstraintReader, SubjectNames, ConstraintNames: TAsn1Reader;
  SubjectName, ConstraintName, SubjectPart, ConstraintPart: TAsn1Element;
begin
  Result := False;
  InitializeAsn1Reader(SubjectReader, Subject, SubjectLength);
  InitializeAsn1Reader(ConstraintReader, Constraint, ConstraintLength);
  if not ReadAsn1Expected(SubjectReader, Asn1Sequence, SubjectName) or
     not ReadAsn1Expected(ConstraintReader, Asn1Sequence, ConstraintName) then
    Exit;
  OpenAsn1Element(SubjectNames, SubjectName);
  OpenAsn1Element(ConstraintNames, ConstraintName);
  while not Asn1ReaderAtEnd(ConstraintNames) do
  begin
    if not ReadAsn1Element(ConstraintNames, ConstraintPart) or not ReadAsn1Element(SubjectNames, SubjectPart) then
      Exit;
    if (ConstraintPart.EncodingLength <> SubjectPart.EncodingLength) or
       (CompareByte(ConstraintPart.Encoding^, SubjectPart.Encoding^, SubjectPart.EncodingLength) <> 0) then
      Exit;
  end;
  Result := True;
end;

{ Whether Name lies in the subtree whose base is Base (of the same
  tag). Excluding asks the wildcard question the other way round. }
function NameInSubtree(constref Name: TSubjectName; constref Base: TAsn1Element; Excluding: Boolean): TNameVerdict;
var
  Inside: Boolean;
begin
  case Name.Tag of
    TagDnsName:
      if Excluding then
        Inside := DnsNameTouchesSubtree(ElementText(Name.Contents, Name.ContentsLength),
          ElementText(Base.Contents, Base.ContentsLength))
      else
        Inside := DnsNameInSubtree(ElementText(Name.Contents, Name.ContentsLength),
          ElementText(Base.Contents, Base.ContentsLength));
    TagMailbox:
      Inside := MailboxInSubtree(ElementText(Name.Contents, Name.ContentsLength),
        ElementText(Base.Contents, Base.ContentsLength));
    TagAddress:
      Inside := AddressInSubtree(Name.Contents, Name.ContentsLength, Base.Contents, Base.ContentsLength);
    TagDirectory:
      Inside := DirectoryInSubtree(Name.Contents, Name.ContentsLength, Base.Contents, Base.ContentsLength);
  else
    Exit(VerdictUnsupported);
  end;
  if Inside then
    Result := VerdictInside
  else
    Result := VerdictOutside;
end;

{ Goes through the subtrees (contents of a GeneralSubtrees) whose base
  has Name's tag: Found says whether there were any, the result whether
  Name is in one of them. }
function SearchSubtrees(constref Subtrees: TTlsByteRange; constref Name: TSubjectName; Excluding: Boolean;
  out Found: Boolean): TNameVerdict;
var
  ListReader, SubtreeReader: TAsn1Reader;
  Subtree, Base: TAsn1Element;
  Verdict: TNameVerdict;
begin
  Found := False;
  Result := VerdictOutside;
  InitializeAsn1Reader(ListReader, Subtrees.Data, Subtrees.Length);
  while ReadAsn1Element(ListReader, Subtree) do
  begin
    OpenAsn1Element(SubtreeReader, Subtree);
    if not ReadAsn1Element(SubtreeReader, Base) or (Base.Tag <> Name.Tag) then
      Continue;
    Found := True;
    Verdict := NameInSubtree(Name, Base, Excluding);
    if Verdict = VerdictUnsupported then
      Exit(VerdictUnsupported);
    if Verdict = VerdictInside then
      Result := VerdictInside;
  end;
end;

function CheckName(constref Authority: TTlsCertificate; constref Name: TSubjectName): LongInt;
var
  Found: Boolean;
  Verdict: TNameVerdict;
begin
  if Authority.PermittedSubtrees.Length > 0 then
  begin
    Verdict := SearchSubtrees(Authority.PermittedSubtrees, Name, False, Found);
    if Verdict = VerdictUnsupported then
      Exit(TlsErrorCertificateUnsupported);
    if Found and (Verdict <> VerdictInside) then
      Exit(TlsErrorCertificateNameConstraint);
  end;
  if Authority.ExcludedSubtrees.Length > 0 then
  begin
    Verdict := SearchSubtrees(Authority.ExcludedSubtrees, Name, True, Found);
    if Verdict = VerdictUnsupported then
      Exit(TlsErrorCertificateUnsupported);
    if Verdict = VerdictInside then
      Exit(TlsErrorCertificateNameConstraint);
  end;
  Result := TlsErrorNone;
end;

function MakeName(Tag: Byte; Contents: PByte; ContentsLength: PtrUInt): TSubjectName;
begin
  Result.Tag := Tag;
  Result.Contents := Contents;
  Result.ContentsLength := ContentsLength;
end;

{ emailAddress attributes of the subject, as mailboxes. }
function CheckSubjectMailboxes(constref Authority, Subject: TTlsCertificate): LongInt;
var
  NameReader, SetReader, AttributeReader: TAsn1Reader;
  Whole, DistinguishedName, Attribute, AttributeType, AttributeValue: TAsn1Element;
begin
  Result := TlsErrorNone;
  InitializeAsn1Reader(NameReader, Subject.Subject.Data, Subject.Subject.Length);
  if not ReadAsn1Expected(NameReader, Asn1Sequence, Whole) then
    Exit;
  OpenAsn1Element(NameReader, Whole);
  while ReadAsn1Element(NameReader, DistinguishedName) do
  begin
    OpenAsn1Element(SetReader, DistinguishedName);
    while ReadAsn1Element(SetReader, Attribute) do
    begin
      OpenAsn1Element(AttributeReader, Attribute);
      if not ReadAsn1Expected(AttributeReader, Asn1ObjectIdentifier, AttributeType) or
         not ReadAsn1Element(AttributeReader, AttributeValue) then
        Continue;
      if not Asn1ObjectIdentifierIs(AttributeType, @OidEmailAddress[0], Length(OidEmailAddress)) then
        Continue;
      Result := CheckName(Authority, MakeName(TagMailbox, AttributeValue.Contents, AttributeValue.ContentsLength));
      if Result <> TlsErrorNone then
        Exit;
    end;
  end;
end;

{ An empty subject is the SEQUENCE header alone. }
function SubjectIsEmpty(constref Subject: TTlsCertificate): Boolean;
begin
  Result := Subject.Subject.Length <= 2;
end;

function CheckNameConstraints(constref Authority: TTlsCertificate; constref Subject: TTlsCertificate): LongInt;
var
  Reader: TAsn1Reader;
  Name: TAsn1Element;
begin
  Result := TlsErrorNone;
  if not Authority.HasNameConstraints then
    Exit;
  if not SubjectIsEmpty(Subject) then
  begin
    Result := CheckName(Authority, MakeName(TagDirectory, Subject.Subject.Data, Subject.Subject.Length));
    if Result <> TlsErrorNone then
      Exit;
    Result := CheckSubjectMailboxes(Authority, Subject);
    if Result <> TlsErrorNone then
      Exit;
  end;
  if not Subject.HasSubjectAlternativeNames then
    Exit;
  InitializeAsn1Reader(Reader, Subject.SubjectAlternativeNames.Data, Subject.SubjectAlternativeNames.Length);
  while ReadAsn1Element(Reader, Name) do
  begin
    { (A directoryName's contents are a Name, as the subject is.) }
    Result := CheckName(Authority, MakeName(Name.Tag, Name.Contents, Name.ContentsLength));
    if Result <> TlsErrorNone then
      Exit;
  end;
end;

end.
