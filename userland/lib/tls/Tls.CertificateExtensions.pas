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
  The extensions of an X.509 v3 certificate (RFC 5280 section 4.2) that
  the chain check acts on: basic constraints, key usage, extended key
  usage, subject alternative names, the key identifiers, name
  constraints (kept for Tls.NameConstraints, checked here to be well
  formed) and the TLS feature list (RFC 7633: must staple). Certificate
  policies and authority information access are recognized and not
  acted on. Any other extension marked critical makes the certificate
  unusable. An extension may appear only once.
}
unit Tls.CertificateExtensions;

{$mode objfpc}
{$pointermath on}

interface

uses
  Tls.Asn1,
  Tls.Certificates;

{ Element is the [3] EXPLICIT Extensions field. }
function ReadCertificateExtensions(constref Element: TAsn1Element; var Certificate: TTlsCertificate): Boolean;

implementation

uses
  Tls.ByteBuffers,
  Tls.ObjectIdentifiers;

const
  MaximumExtensions = 64;

type
  TExtensionKind = (ExtensionOther, ExtensionBasicConstraints, ExtensionKeyUsage, ExtensionExtendedKeyUsage,
    ExtensionSubjectAlternativeName, ExtensionSubjectKeyIdentifier, ExtensionAuthorityKeyIdentifier,
    ExtensionCertificatePolicies, ExtensionNameConstraints, ExtensionTlsFeature, ExtensionAuthorityInformation);

function OidIs(constref Element: TAsn1Element; const Identifier: array of Byte): Boolean;
begin
  Result := Asn1ObjectIdentifierIs(Element, @Identifier[0], Length(Identifier));
end;

function ClassifyExtension(constref Identifier: TAsn1Element): TExtensionKind;
begin
  if OidIs(Identifier, OidBasicConstraints) then
    Result := ExtensionBasicConstraints
  else if OidIs(Identifier, OidKeyUsage) then
    Result := ExtensionKeyUsage
  else if OidIs(Identifier, OidExtendedKeyUsage) then
    Result := ExtensionExtendedKeyUsage
  else if OidIs(Identifier, OidSubjectAlternativeName) then
    Result := ExtensionSubjectAlternativeName
  else if OidIs(Identifier, OidSubjectKeyIdentifier) then
    Result := ExtensionSubjectKeyIdentifier
  else if OidIs(Identifier, OidAuthorityKeyIdentifier) then
    Result := ExtensionAuthorityKeyIdentifier
  else if OidIs(Identifier, OidCertificatePolicies) then
    Result := ExtensionCertificatePolicies
  else if OidIs(Identifier, OidNameConstraints) then
    Result := ExtensionNameConstraints
  else if OidIs(Identifier, OidTlsFeature) then
    Result := ExtensionTlsFeature
  else if OidIs(Identifier, OidAuthorityInformationAccess) then
    Result := ExtensionAuthorityInformation
  else
    Result := ExtensionOther;
end;

(* BasicConstraints ::= SEQUENCE { cA BOOLEAN DEFAULT FALSE,
   pathLenConstraint INTEGER (0..MAX) OPTIONAL } *)
function ReadBasicConstraints(Reader: TAsn1Reader; var Certificate: TTlsCertificate): Boolean;
var
  Constraints, Field: TAsn1Element;
  ConstraintsReader: TAsn1Reader;
  Present: Boolean;
begin
  Result := False;
  if not ReadAsn1Expected(Reader, Asn1Sequence, Constraints) or not Asn1ReaderAtEnd(Reader) then
    Exit;
  OpenAsn1Element(ConstraintsReader, Constraints);
  Certificate.HasBasicConstraints := True;
  Certificate.IsAuthority := False;
  if not ReadAsn1Optional(ConstraintsReader, Asn1Boolean, Field, Present) then
    Exit;
  if Present and not ReadAsn1BooleanValue(Field, Certificate.IsAuthority) then
    Exit;
  if not ReadAsn1Optional(ConstraintsReader, Asn1Integer, Field, Present) then
    Exit;
  if Present then
  begin
    if not ReadAsn1SmallInteger(Field, Certificate.PathLengthLimit) then
      Exit;
    { A path length belongs only on an authority. }
    if not Certificate.IsAuthority then
      Exit;
  end;
  Result := Asn1ReaderAtEnd(ConstraintsReader);
end;

function ReadKeyUsage(Reader: TAsn1Reader; var Certificate: TTlsCertificate): Boolean;
var
  Usage: TAsn1Element;
begin
  Result := ReadAsn1Element(Reader, Usage) and Asn1ReaderAtEnd(Reader) and
    ReadAsn1BitFlags(Usage, Certificate.KeyUsage);
  { At least one bit must be set. }
  Result := Result and (Certificate.KeyUsage <> 0);
  Certificate.HasKeyUsage := Result;
end;

{ ExtKeyUsageSyntax ::= SEQUENCE SIZE (1..MAX) OF KeyPurposeId }
function ReadExtendedKeyUsage(Reader: TAsn1Reader; var Certificate: TTlsCertificate): Boolean;
var
  Usages, Purpose: TAsn1Element;
  UsageReader: TAsn1Reader;
begin
  Result := False;
  if not ReadAsn1Expected(Reader, Asn1Sequence, Usages) or not Asn1ReaderAtEnd(Reader) then
    Exit;
  OpenAsn1Element(UsageReader, Usages);
  if Asn1ReaderAtEnd(UsageReader) then
    Exit;
  Certificate.HasExtendedKeyUsage := True;
  while not Asn1ReaderAtEnd(UsageReader) do
  begin
    if not ReadAsn1Expected(UsageReader, Asn1ObjectIdentifier, Purpose) then
      Exit;
    if OidIs(Purpose, OidServerAuthentication) or OidIs(Purpose, OidAnyExtendedKeyUsage) then
      Certificate.AllowsServerAuthentication := True;
  end;
  Result := True;
end;

{ GeneralNames ::= SEQUENCE SIZE (1..MAX) OF GeneralName. Every name
  must be well formed; the host name check reads them again later. }
function ReadSubjectAlternativeNames(Reader: TAsn1Reader; var Certificate: TTlsCertificate): Boolean;
var
  Names, Name: TAsn1Element;
  NameReader: TAsn1Reader;
begin
  Result := False;
  if not ReadAsn1Expected(Reader, Asn1Sequence, Names) or not Asn1ReaderAtEnd(Reader) then
    Exit;
  OpenAsn1Element(NameReader, Names);
  if Asn1ReaderAtEnd(NameReader) then
    Exit;
  while not Asn1ReaderAtEnd(NameReader) do
  begin
    if not ReadAsn1Element(NameReader, Name) then
      Exit;
    if (Name.Tag and Asn1ContextSpecific) = 0 then
      Exit;
    { dNSName [2] IA5String must not be empty; iPAddress [7] is 4 or
      16 bytes. }
    if (Name.Tag = Asn1ContextSpecific or 2) and (Name.ContentsLength = 0) then
      Exit;
    if (Name.Tag = Asn1ContextSpecific or 7) and (Name.ContentsLength <> 4) and (Name.ContentsLength <> 16) then
      Exit;
  end;
  Certificate.HasSubjectAlternativeNames := True;
  Certificate.SubjectAlternativeNames := ByteRange(Names.Contents, Names.ContentsLength);
  Result := True;
end;

function ReadSubjectKeyIdentifier(Reader: TAsn1Reader; var Certificate: TTlsCertificate): Boolean;
var
  Identifier: TAsn1Element;
begin
  Result := ReadAsn1Expected(Reader, Asn1OctetString, Identifier) and Asn1ReaderAtEnd(Reader);
  if Result then
    Certificate.SubjectKeyIdentifier := ByteRange(Identifier.Contents, Identifier.ContentsLength);
end;

(* AuthorityKeyIdentifier ::= SEQUENCE { keyIdentifier [0] OPTIONAL,
   authorityCertIssuer [1] OPTIONAL, authorityCertSerialNumber [2]
   OPTIONAL }; only the key identifier is kept. *)
function ReadAuthorityKeyIdentifier(Reader: TAsn1Reader; var Certificate: TTlsCertificate): Boolean;
var
  Sequence, Field: TAsn1Element;
  SequenceReader: TAsn1Reader;
  Present: Boolean;
begin
  Result := False;
  if not ReadAsn1Expected(Reader, Asn1Sequence, Sequence) or not Asn1ReaderAtEnd(Reader) then
    Exit;
  OpenAsn1Element(SequenceReader, Sequence);
  if not ReadAsn1Optional(SequenceReader, Asn1ContextSpecific or 0, Field, Present) then
    Exit;
  if Present then
    Certificate.AuthorityKeyIdentifier := ByteRange(Field.Contents, Field.ContentsLength);
  while not Asn1ReaderAtEnd(SequenceReader) do
    if not ReadAsn1Element(SequenceReader, Field) then
      Exit;
  Result := True;
end;

{ Only checked to be a well formed SEQUENCE. }
function ReadCertificatePolicies(Reader: TAsn1Reader): Boolean;
var
  Policies: TAsn1Element;
begin
  Result := ReadAsn1Expected(Reader, Asn1Sequence, Policies) and Asn1ReaderAtEnd(Reader) and
    (Policies.ContentsLength > 0);
end;

{ Only checked to be a well formed, non-empty SEQUENCE. }
function ReadAuthorityInformation(Reader: TAsn1Reader): Boolean;
var
  Descriptions: TAsn1Element;
begin
  Result := ReadAsn1Expected(Reader, Asn1Sequence, Descriptions) and Asn1ReaderAtEnd(Reader) and
    (Descriptions.ContentsLength > 0);
end;

(* GeneralSubtrees ::= SEQUENCE SIZE (1..MAX) OF GeneralSubtree
   GeneralSubtree ::= SEQUENCE { base GeneralName,
     minimum [0] BaseDistance DEFAULT 0, maximum [1] BaseDistance OPTIONAL }
   Every subtree must be well formed; RFC 5280 allows neither a minimum
   nor a maximum, and either is refused. *)
function CheckGeneralSubtrees(constref Subtrees: TAsn1Element): Boolean;
var
  ListReader, SubtreeReader: TAsn1Reader;
  Subtree, Base: TAsn1Element;
begin
  Result := False;
  OpenAsn1Element(ListReader, Subtrees);
  if Asn1ReaderAtEnd(ListReader) then
    Exit;
  while not Asn1ReaderAtEnd(ListReader) do
  begin
    if not ReadAsn1Expected(ListReader, Asn1Sequence, Subtree) then
      Exit;
    OpenAsn1Element(SubtreeReader, Subtree);
    if not ReadAsn1Element(SubtreeReader, Base) or ((Base.Tag and Asn1ContextSpecific) = 0) then
      Exit;
    if not Asn1ReaderAtEnd(SubtreeReader) then
      Exit;
  end;
  Result := True;
end;

(* NameConstraints ::= SEQUENCE { permittedSubtrees [0] GeneralSubtrees
   OPTIONAL, excludedSubtrees [1] GeneralSubtrees OPTIONAL }, at least
   one of them. *)
function ReadNameConstraints(Reader: TAsn1Reader; var Certificate: TTlsCertificate): Boolean;
var
  Constraints, Permitted, Excluded: TAsn1Element;
  ConstraintsReader: TAsn1Reader;
  HasPermitted, HasExcluded: Boolean;
begin
  Result := False;
  if not ReadAsn1Expected(Reader, Asn1Sequence, Constraints) or not Asn1ReaderAtEnd(Reader) then
    Exit;
  OpenAsn1Element(ConstraintsReader, Constraints);
  if not ReadAsn1Optional(ConstraintsReader, Asn1ContextSpecific or Asn1Constructed or 0, Permitted,
    HasPermitted) then
    Exit;
  if not ReadAsn1Optional(ConstraintsReader, Asn1ContextSpecific or Asn1Constructed or 1, Excluded,
    HasExcluded) then
    Exit;
  if not Asn1ReaderAtEnd(ConstraintsReader) or (not HasPermitted and not HasExcluded) then
    Exit;
  if HasPermitted then
  begin
    if not CheckGeneralSubtrees(Permitted) then
      Exit;
    Certificate.PermittedSubtrees := ByteRange(Permitted.Contents, Permitted.ContentsLength);
  end;
  if HasExcluded then
  begin
    if not CheckGeneralSubtrees(Excluded) then
      Exit;
    Certificate.ExcludedSubtrees := ByteRange(Excluded.Contents, Excluded.ContentsLength);
  end;
  Certificate.HasNameConstraints := True;
  Result := True;
end;

(* Features ::= SEQUENCE OF INTEGER; 5 is status_request. *)
function ReadTlsFeature(Reader: TAsn1Reader; var Certificate: TTlsCertificate): Boolean;
var
  Features, Feature: TAsn1Element;
  FeatureReader: TAsn1Reader;
  Value: LongInt;
begin
  Result := False;
  if not ReadAsn1Expected(Reader, Asn1Sequence, Features) or not Asn1ReaderAtEnd(Reader) then
    Exit;
  OpenAsn1Element(FeatureReader, Features);
  while not Asn1ReaderAtEnd(FeatureReader) do
  begin
    if not ReadAsn1Expected(FeatureReader, Asn1Integer, Feature) or not ReadAsn1SmallInteger(Feature, Value) then
      Exit;
    if Value = 5 then
      Certificate.RequiresStapledStatus := True;
  end;
  Result := True;
end;

function ReadCertificateExtensions(constref Element: TAsn1Element; var Certificate: TTlsCertificate): Boolean;
var
  OuterReader, ListReader, ExtensionReader, ValueReader: TAsn1Reader;
  List, Extension, Identifier, CriticalField, Value: TAsn1Element;
  Present: Boolean;
  Critical: Boolean;
  Kind: TExtensionKind;
  Seen: array[0..MaximumExtensions - 1] of TAsn1Element;
  SeenCount: Integer;
  Index: Integer;
  Understood: Boolean;
begin
  Result := False;
  OpenAsn1Element(OuterReader, Element);
  if not ReadAsn1Expected(OuterReader, Asn1Sequence, List) or not Asn1ReaderAtEnd(OuterReader) then
    Exit;
  OpenAsn1Element(ListReader, List);
  if Asn1ReaderAtEnd(ListReader) then
    Exit;
  SeenCount := 0;
  FillChar(Seen, SizeOf(Seen), 0);
  while not Asn1ReaderAtEnd(ListReader) do
  begin
    if not ReadAsn1Expected(ListReader, Asn1Sequence, Extension) then
      Exit;
    OpenAsn1Element(ExtensionReader, Extension);
    if not ReadAsn1Expected(ExtensionReader, Asn1ObjectIdentifier, Identifier) then
      Exit;
    { No extension twice. }
    if SeenCount >= MaximumExtensions then
      Exit;
    for Index := 0 to SeenCount - 1 do
      if (Seen[Index].ContentsLength = Identifier.ContentsLength) and
         (CompareByte(Seen[Index].Contents^, Identifier.Contents^, Identifier.ContentsLength) = 0) then
        Exit;
    Seen[SeenCount] := Identifier;
    Inc(SeenCount);

    Critical := False;
    if not ReadAsn1Optional(ExtensionReader, Asn1Boolean, CriticalField, Present) then
      Exit;
    if Present and not ReadAsn1BooleanValue(CriticalField, Critical) then
      Exit;
    if not ReadAsn1Expected(ExtensionReader, Asn1OctetString, Value) or not Asn1ReaderAtEnd(ExtensionReader) then
      Exit;
    InitializeAsn1Reader(ValueReader, Value.Contents, Value.ContentsLength);

    Kind := ClassifyExtension(Identifier);
    Understood := True;
    case Kind of
      ExtensionBasicConstraints: Understood := ReadBasicConstraints(ValueReader, Certificate);
      ExtensionKeyUsage: Understood := ReadKeyUsage(ValueReader, Certificate);
      ExtensionExtendedKeyUsage: Understood := ReadExtendedKeyUsage(ValueReader, Certificate);
      ExtensionSubjectAlternativeName: Understood := ReadSubjectAlternativeNames(ValueReader, Certificate);
      ExtensionSubjectKeyIdentifier: Understood := ReadSubjectKeyIdentifier(ValueReader, Certificate);
      ExtensionAuthorityKeyIdentifier: Understood := ReadAuthorityKeyIdentifier(ValueReader, Certificate);
      ExtensionCertificatePolicies: Understood := ReadCertificatePolicies(ValueReader);
      ExtensionNameConstraints: Understood := ReadNameConstraints(ValueReader, Certificate);
      ExtensionTlsFeature: Understood := ReadTlsFeature(ValueReader, Certificate);
      ExtensionAuthorityInformation: Understood := ReadAuthorityInformation(ValueReader);
      ExtensionOther:
        if Critical then
          Certificate.HasUnsupportedCriticalExtension := True;
    end;
    if not Understood then
      Exit;
  end;
  Result := True;
end;

end.
