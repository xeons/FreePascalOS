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
  A certificate as text for people: its subject and issuer names
  ("CN=example.com, O=Example Inc, C=US"), validity, serial number and
  SHA-256 fingerprint, for a browser's site identity and certificate
  viewer. Malformed parts are skipped, never raised.
}
unit Tls.CertificateSummaries;

{$mode objfpc}
{$H+}

interface

uses
  Tls.ByteBuffers,
  Tls.Certificates;

type
  TTlsCertificateSummary = record
    Subject, Issuer, CommonName, Organization, ValidFrom, ValidUntil, SerialNumber, Sha256Fingerprint: string;
  end;
  TTlsCertificateSummaryList = array of TTlsCertificateSummary;

function SummarizeCertificate(constref Certificate: TTlsCertificate): TTlsCertificateSummary;
{ 'CN=example.com, O=Example Inc, C=US' from a Name's DER (the whole
  SEQUENCE), in the certificate's order; unknown attributes as dotted
  OIDs. }
function DistinguishedNameText(constref Name: TTlsByteRange): string;
{ An attribute of a Name (the first with that short name, 'CN', 'O' ...),
  '' when it has none. }
function DistinguishedNameAttribute(constref Name: TTlsByteRange; const ShortName: string): string;
{ 'yyyy-mm-dd hh:nn:ss UTC'. }
function UnixTimeText(Time: Int64): string;
{ Upper case hexadecimal bytes joined by ':'. }
function ColonHexText(Bytes: PByte; Count: PtrUInt): string;

implementation

uses
  SysUtils,
  DateUtils,
  Crypto.Digests,
  Tls.Asn1;

type
  TAttributeName = record
    Identifier: array[0..9] of Byte;
    Length: Integer;
    ShortName: string;
  end;

const
  KnownAttributes: array[0..12] of TAttributeName = (
    (Identifier: ($55, $04, $03, 0, 0, 0, 0, 0, 0, 0); Length: 3; ShortName: 'CN'),
    (Identifier: ($55, $04, $0A, 0, 0, 0, 0, 0, 0, 0); Length: 3; ShortName: 'O'),
    (Identifier: ($55, $04, $0B, 0, 0, 0, 0, 0, 0, 0); Length: 3; ShortName: 'OU'),
    (Identifier: ($55, $04, $06, 0, 0, 0, 0, 0, 0, 0); Length: 3; ShortName: 'C'),
    (Identifier: ($55, $04, $07, 0, 0, 0, 0, 0, 0, 0); Length: 3; ShortName: 'L'),
    (Identifier: ($55, $04, $08, 0, 0, 0, 0, 0, 0, 0); Length: 3; ShortName: 'ST'),
    (Identifier: ($55, $04, $05, 0, 0, 0, 0, 0, 0, 0); Length: 3; ShortName: 'SERIALNUMBER'),
    (Identifier: ($55, $04, $09, 0, 0, 0, 0, 0, 0, 0); Length: 3; ShortName: 'STREET'),
    (Identifier: ($55, $04, $11, 0, 0, 0, 0, 0, 0, 0); Length: 3; ShortName: 'POSTALCODE'),
    (Identifier: ($55, $04, $0F, 0, 0, 0, 0, 0, 0, 0); Length: 3; ShortName: 'BUSINESSCATEGORY'),
    (Identifier: ($55, $04, $61, 0, 0, 0, 0, 0, 0, 0); Length: 3; ShortName: 'ORGANIZATIONIDENTIFIER'),
    (Identifier: ($2A, $86, $48, $86, $F7, $0D, $01, $09, $01, 0); Length: 9; ShortName: 'emailAddress'),
    (Identifier: ($09, $92, $26, $89, $93, $F2, $2C, $64, $01, $19); Length: 10; ShortName: 'DC'));

procedure AppendCodePoint(var Text: string; CodePoint: LongWord);
begin
  if (CodePoint >= $D800) and (CodePoint <= $DFFF) or (CodePoint > $10FFFF) then
    CodePoint := $FFFD;
  if CodePoint < $80 then
    Text := Text + Chr(CodePoint)
  else if CodePoint < $800 then
    Text := Text + Chr($C0 or (CodePoint shr 6)) + Chr($80 or (CodePoint and $3F))
  else if CodePoint < $10000 then
    Text := Text + Chr($E0 or (CodePoint shr 12)) + Chr($80 or ((CodePoint shr 6) and $3F)) +
      Chr($80 or (CodePoint and $3F))
  else
    Text := Text + Chr($F0 or (CodePoint shr 18)) + Chr($80 or ((CodePoint shr 12) and $3F)) +
      Chr($80 or ((CodePoint shr 6) and $3F)) + Chr($80 or (CodePoint and $3F));
end;

{ Text of a directory string (or any string type) as UTF-8. }
function AttributeValueText(constref Value: TAsn1Element): string;
var
  Index: PtrUInt;
  CodePoint, Low: LongWord;
begin
  Result := '';
  Index := 0;
  case Value.Tag of
    Asn1Utf8String, Asn1PrintableString, Asn1Ia5String:
      begin
        SetLength(Result, Value.ContentsLength);
        if Value.ContentsLength > 0 then
          Move(Value.Contents^, Result[1], Value.ContentsLength);
      end;
    Asn1BmpString:
      while Index + 1 < Value.ContentsLength do
      begin
        CodePoint := (LongWord(Value.Contents[Index]) shl 8) or Value.Contents[Index + 1];
        Inc(Index, 2);
        if (CodePoint >= $D800) and (CodePoint <= $DBFF) and (Index + 1 < Value.ContentsLength) then
        begin
          Low := (LongWord(Value.Contents[Index]) shl 8) or Value.Contents[Index + 1];
          if (Low >= $DC00) and (Low <= $DFFF) then
          begin
            CodePoint := $10000 + ((CodePoint - $D800) shl 10) + (Low - $DC00);
            Inc(Index, 2);
          end;
        end;
        AppendCodePoint(Result, CodePoint);
      end;
    Asn1UniversalString:
      while Index + 3 < Value.ContentsLength do
      begin
        CodePoint := (LongWord(Value.Contents[Index]) shl 24) or (LongWord(Value.Contents[Index + 1]) shl 16) or
          (LongWord(Value.Contents[Index + 2]) shl 8) or Value.Contents[Index + 3];
        Inc(Index, 4);
        AppendCodePoint(Result, CodePoint);
      end;
  else
    { TeletexString and anything else: as Latin-1. }
    while Index < Value.ContentsLength do
    begin
      AppendCodePoint(Result, Value.Contents[Index]);
      Inc(Index);
    end;
  end;
end;

function DottedObjectIdentifier(constref Element: TAsn1Element): string;
var
  Index: PtrUInt;
  Number: QWord;
  First: Boolean;
begin
  Result := '';
  Number := 0;
  First := True;
  Index := 0;
  while Index < Element.ContentsLength do
  begin
    Number := (Number shl 7) or (Element.Contents[Index] and $7F);
    if Element.Contents[Index] and $80 = 0 then
    begin
      if First then
      begin
        if Number < 80 then
          Result := IntToStr(Number div 40) + '.' + IntToStr(Number mod 40)
        else
          Result := '2.' + IntToStr(Number - 80);
        First := False;
      end
      else
        Result := Result + '.' + IntToStr(Number);
      Number := 0;
    end;
    Inc(Index);
  end;
end;

function AttributeShortName(constref Identifier: TAsn1Element): string;
var
  Index: Integer;
begin
  for Index := Low(KnownAttributes) to High(KnownAttributes) do
    if Asn1ObjectIdentifierIs(Identifier, @KnownAttributes[Index].Identifier[0], KnownAttributes[Index].Length) then
      Exit(KnownAttributes[Index].ShortName);
  Result := DottedObjectIdentifier(Identifier);
end;

type
  TNameVisitor = procedure(const ShortName, Value: string; var State: string; var Done: Boolean);

{ Calls Visit for each attribute of a Name, in order, until Done. }
procedure VisitName(constref Name: TTlsByteRange; Visit: TNameVisitor; var State: string);
var
  Outer, NameReader, SetReader, AttributeReader: TAsn1Reader;
  NameElement, DistinguishedName, Attribute, AttributeType, AttributeValue: TAsn1Element;
  Done: Boolean;
begin
  if (Name.Data = nil) or (Name.Length = 0) then
    Exit;
  InitializeAsn1Reader(Outer, Name.Data, Name.Length);
  if not ReadAsn1Expected(Outer, Asn1Sequence, NameElement) then
    Exit;
  Done := False;
  OpenAsn1Element(NameReader, NameElement);
  while not Done and not Asn1ReaderAtEnd(NameReader) do
  begin
    if not ReadAsn1Expected(NameReader, Asn1Set, DistinguishedName) then
      Exit;
    OpenAsn1Element(SetReader, DistinguishedName);
    while not Done and not Asn1ReaderAtEnd(SetReader) do
    begin
      if not ReadAsn1Expected(SetReader, Asn1Sequence, Attribute) then
        Exit;
      OpenAsn1Element(AttributeReader, Attribute);
      if not ReadAsn1Expected(AttributeReader, Asn1ObjectIdentifier, AttributeType) or
         not ReadAsn1Element(AttributeReader, AttributeValue) then
        Continue;
      Visit(AttributeShortName(AttributeType), AttributeValueText(AttributeValue), State, Done);
    end;
  end;
end;

procedure JoinAttribute(const ShortName, Value: string; var State: string; var Done: Boolean);
begin
  if State <> '' then
    State := State + ', ';
  State := State + ShortName + '=' + Value;
end;

procedure FindAttribute(const ShortName, Value: string; var State: string; var Done: Boolean);
begin
  { State holds #0 + the wanted name until found, then the value. }
  if (State <> '') and (State[1] = #0) and (Copy(State, 2, MaxInt) = ShortName) then
  begin
    State := Value;
    Done := True;
  end;
end;

function DistinguishedNameText(constref Name: TTlsByteRange): string;
begin
  Result := '';
  VisitName(Name, @JoinAttribute, Result);
end;

function DistinguishedNameAttribute(constref Name: TTlsByteRange; const ShortName: string): string;
begin
  Result := #0 + ShortName;
  VisitName(Name, @FindAttribute, Result);
  if (Result <> '') and (Result[1] = #0) then
    Result := '';
end;

function UnixTimeText(Time: Int64): string;
begin
  Result := FormatDateTime('yyyy"-"mm"-"dd hh":"nn":"ss', UnixToDateTime(Time)) + ' UTC';
end;

function ColonHexText(Bytes: PByte; Count: PtrUInt): string;
var
  Index: PtrUInt;
begin
  Result := '';
  Index := 0;
  while Index < Count do
  begin
    if Index > 0 then
      Result := Result + ':';
    Result := Result + IntToHex(Bytes[Index], 2);
    Inc(Index);
  end;
end;

function SummarizeCertificate(constref Certificate: TTlsCertificate): TTlsCertificateSummary;
var
  Digest: TDigestOutput;
begin
  Result := Default(TTlsCertificateSummary);
  Result.Subject := DistinguishedNameText(Certificate.Subject);
  Result.Issuer := DistinguishedNameText(Certificate.Issuer);
  Result.CommonName := DistinguishedNameAttribute(Certificate.Subject, 'CN');
  Result.Organization := DistinguishedNameAttribute(Certificate.Subject, 'O');
  Result.ValidFrom := UnixTimeText(Certificate.NotBefore);
  Result.ValidUntil := UnixTimeText(Certificate.NotAfter);
  Result.SerialNumber := ColonHexText(Certificate.SerialNumber.Data, Certificate.SerialNumber.Length);
  if (Certificate.Encoding.Data <> nil) and (Certificate.Encoding.Length > 0) then
  begin
    ComputeDigest(DigestSha256, Certificate.Encoding.Data, Certificate.Encoding.Length, Digest);
    Result.Sha256Fingerprint := ColonHexText(@Digest[0], DigestSize(DigestSha256));
  end;
end;

end.
