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
  Checking the certificates a server sent (RFC 5280 section 6, as TLS
  clients apply it):

  1. The server's own certificate (the first) must be valid at the
     given time, have no unknown critical extension and, where it says,
     be for digital signatures and TLS servers (key usage, extended key
     usage).
  2. A path is built from it to a trust anchor: each step goes to a
     certificate whose subject is the issuer of the one before and whose
     key verifies its signature - an anchor first, else one of the
     certificates the server sent (in any order; several candidates are
     tried in turn, for cross-signed authorities). A certificate the
     server sent that is itself an anchor ends the path. Each issuer on
     the way must be an authority (basic constraints), may sign
     certificates (key usage), must be valid at the time, must allow
     the path below it (path length) and, if it restricts the extended
     key usage, must allow TLS servers. At most 8 issuers.
  3. The server's certificate must be for the host name (Tls.HostNames).

  When no path exists the most telling reason found on the way is given
  (an expired issuer, a bad signature...), else "unknown issuer".
}
unit Tls.CertificateChains;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  Tls.Certificates,
  Tls.TrustStore;

const
  MaximumChainDepth = 8;

type
  TChainCheck = record
    { The certificates the server sent, its own first. }
    Presented: ^PTlsCertificate;
    PresentedCount: Integer;
    Anchors: PTlsTrustStore;
    { Unix seconds. }
    Time: Int64;
    { Empty: the name is not checked. }
    HostName: string;
  end;

  TChainResult = record
    Error: LongInt;
    { The certificate the error is about (for messages), or nil. }
    Culprit: PTlsCertificate;
  end;

function VerifyCertificateChain(constref Check: TChainCheck): TChainResult;

implementation

uses
  Tls.ByteBuffers,
  Tls.Errors,
  Tls.HostNames,
  Tls.Signatures;

type
  TSearch = record
    Check: TChainCheck;
    { Which presented certificates are on the path being tried. }
    Used: array[0..63] of Boolean;
    BestError: LongInt;
    BestCulprit: PTlsCertificate;
  end;

procedure NoteFailure(var Search: TSearch; Error: LongInt; Culprit: PTlsCertificate);
begin
  { The first specific reason is kept; "unknown issuer" is the default. }
  if Search.BestError = TlsErrorCertificateUnknownIssuer then
  begin
    Search.BestError := Error;
    Search.BestCulprit := Culprit;
  end;
end;

function ValidityError(constref Certificate: TTlsCertificate; Time: Int64): LongInt;
begin
  if Time < Certificate.NotBefore then
    Result := TlsErrorCertificateNotYetValid
  else if Time > Certificate.NotAfter then
    Result := TlsErrorCertificateExpired
  else
    Result := TlsErrorNone;
end;

function SignatureError(Check: TSignatureCheck): LongInt;
begin
  if Check = SignatureValid then
    Result := TlsErrorNone
  else if Check = SignatureUnsupported then
    Result := TlsErrorCertificateUnsupported
  else
    Result := TlsErrorCertificateBadSignature;
end;

{ What an intermediate must be to issue Below, Depth intermediates
  above the server's certificate. }
function IssuerError(constref Issuer: TTlsCertificate; Depth: Integer; Time: Int64): LongInt;
begin
  if Issuer.HasUnsupportedCriticalExtension then
    Exit(TlsErrorCertificateUnsupported);
  if not Issuer.HasBasicConstraints or not Issuer.IsAuthority then
    Exit(TlsErrorCertificateNotAuthority);
  if Issuer.HasKeyUsage and ((Issuer.KeyUsage and KeyUsageKeyCertificateSign) = 0) then
    Exit(TlsErrorCertificateNotAuthority);
  if (Issuer.PathLengthLimit >= 0) and (Depth > Issuer.PathLengthLimit) then
    Exit(TlsErrorCertificateChainTooLong);
  if Issuer.HasExtendedKeyUsage and not Issuer.AllowsServerAuthentication then
    Exit(TlsErrorCertificateUsage);
  Result := ValidityError(Issuer, Time);
end;

{ Anchors are trusted as they are; only their validity and any path
  length they set are applied. }
function AnchorError(constref Anchor: TTlsCertificate; Depth: Integer; Time: Int64): LongInt;
begin
  if Anchor.HasBasicConstraints and (Anchor.PathLengthLimit >= 0) and (Depth > Anchor.PathLengthLimit) then
    Exit(TlsErrorCertificateChainTooLong);
  Result := ValidityError(Anchor, Time);
end;

function FindPath(var Search: TSearch; Current: PTlsCertificate; Depth: Integer): Boolean;
var
  Index: Integer;
  Candidate: PTlsCertificate;
  Error: LongInt;
begin
  if StoreContainsCertificate(Search.Check.Anchors, Current^) then
    Exit(True);
  if Depth >= MaximumChainDepth then
  begin
    NoteFailure(Search, TlsErrorCertificateChainTooLong, Current);
    Exit(False);
  end;

  { An anchor that issued Current. }
  if Search.Check.Anchors <> nil then
    for Index := 0 to Search.Check.Anchors^.Count - 1 do
    begin
      Candidate := TrustedCertificate(Search.Check.Anchors, Index);
      if not ByteRangesEqual(Candidate^.Subject, Current^.Issuer) then
        Continue;
      Error := SignatureError(CheckCertificateSignature(Candidate^, Current^));
      if Error = TlsErrorNone then
        Error := AnchorError(Candidate^, Depth, Search.Check.Time);
      if Error = TlsErrorNone then
        Exit(True);
      NoteFailure(Search, Error, Candidate);
    end;

  { One of the certificates the server sent. }
  for Index := 1 to Search.Check.PresentedCount - 1 do
  begin
    if Search.Used[Index] then
      Continue;
    Candidate := Search.Check.Presented[Index];
    if not ByteRangesEqual(Candidate^.Subject, Current^.Issuer) then
      Continue;
    Error := IssuerError(Candidate^, Depth, Search.Check.Time);
    if Error = TlsErrorNone then
      Error := SignatureError(CheckCertificateSignature(Candidate^, Current^));
    if Error <> TlsErrorNone then
    begin
      NoteFailure(Search, Error, Candidate);
      Continue;
    end;
    Search.Used[Index] := True;
    if FindPath(Search, Candidate, Depth + 1) then
      Exit(True);
    Search.Used[Index] := False;
  end;

  if Search.BestCulprit = nil then
    Search.BestCulprit := Current;
  Result := False;
end;

function LeafError(constref Leaf: TTlsCertificate; Time: Int64): LongInt;
begin
  Result := ValidityError(Leaf, Time);
  if Result <> TlsErrorNone then
    Exit;
  if Leaf.HasUnsupportedCriticalExtension then
    Exit(TlsErrorCertificateUnsupported);
  if Leaf.HasKeyUsage and ((Leaf.KeyUsage and KeyUsageDigitalSignature) = 0) then
    Exit(TlsErrorCertificateUsage);
  if Leaf.HasExtendedKeyUsage and not Leaf.AllowsServerAuthentication then
    Exit(TlsErrorCertificateUsage);
end;

function VerifyCertificateChain(constref Check: TChainCheck): TChainResult;
var
  Search: TSearch;
  Leaf: PTlsCertificate;
begin
  Result.Error := TlsErrorNone;
  Result.Culprit := nil;
  if (Check.Presented = nil) or (Check.PresentedCount < 1) then
  begin
    Result.Error := TlsErrorCertificateMissing;
    Exit;
  end;
  if Check.PresentedCount > Length(Search.Used) then
  begin
    Result.Error := TlsErrorCertificateChainTooLong;
    Exit;
  end;
  Leaf := Check.Presented[0];
  Result.Culprit := Leaf;
  Result.Error := LeafError(Leaf^, Check.Time);
  if Result.Error <> TlsErrorNone then
    Exit;

  Search := Default(TSearch);
  Search.Check := Check;
  Search.BestError := TlsErrorCertificateUnknownIssuer;
  Search.BestCulprit := nil;
  Search.Used[0] := True;
  if not FindPath(Search, Leaf, 0) then
  begin
    Result.Error := Search.BestError;
    Result.Culprit := Search.BestCulprit;
    Exit;
  end;

  if (Check.HostName <> '') and not CertificateMatchesHost(Leaf^, Check.HostName) then
  begin
    Result.Error := TlsErrorCertificateNameMismatch;
    Result.Culprit := Leaf;
  end;
end;

end.
