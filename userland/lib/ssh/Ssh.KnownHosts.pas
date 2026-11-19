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
  known_hosts, as OpenSSH's ssh keeps it (sshd(8), "SSH_KNOWN_HOSTS FILE
  FORMAT"): a line per key,

    hostnames keytype base64-key [comment]

  hostnames a comma separated list of names or addresses (wildcards and
  ! negations allowed), "[host]:port" for a port other than 22, or one
  hashed name: |1|base64 salt|base64 HMAC-SHA1(salt, name). A line
  starting with @revoked names a key that must never be taken;
  @cert-authority lines are skipped.

  Lookup says whether the server's key is known for that name, known to
  be different (someone may be in the middle), or not known at all (the
  ssh program then asks, and appends KnownHostLine).
}
unit Ssh.KnownHosts;

{$mode objfpc}{$H+}

interface

uses
  SysUtils;

type
  TKnownHostResult = (KnownHostUnknown, KnownHostMatches, KnownHostDiffers, KnownHostRevoked);

{ "host" for port 22, else "[host]:port". }
function KnownHostName(const Host: string; Port: Word): string;
function LookupKnownHost(const Lines: TStringArray; const Host: string; Port: Word;
  const Blob: string): TKnownHostResult;
function KnownHostLine(const Host: string; Port: Word; const Blob: string): string;
{ Whether Name matches one hostnames field. }
function HostFieldMatches(const Field, Name: string): Boolean;

implementation

uses
  Crypto.Digests,
  Crypto.Hmac,
  Ssh.Wire,
  Ssh.Base64,
  Ssh.PublicKeys,
  Ssh.AddressPatterns;

function KnownHostName(const Host: string; Port: Word): string;
begin
  if Port = 22 then
    Result := LowerCase(Host)
  else
    Result := '[' + LowerCase(Host) + ']:' + IntToStr(Port);
end;

function HashedNameMatches(const Field, Name: string): Boolean;
var
  Parts: TStringArray;
  Salt, Expected: string;
  Output: TDigestOutput;
begin
  Result := False;
  Parts := Field.Split(['|']);
  { '', '1', salt, hash }
  if (Length(Parts) <> 4) or (Parts[1] <> '1') then
    Exit;
  if not DecodeBase64(Parts[2], Salt) or not DecodeBase64(Parts[3], Expected) or (Salt = '') then
    Exit;
  if Name = '' then
    Exit;
  ComputeHmac(DigestSha1, @Salt[1], Length(Salt), @Name[1], Length(Name), Output);
  Result := BytesToString(@Output[0], DigestSize(DigestSha1)) = Expected;
end;

function HostFieldMatches(const Field, Name: string): Boolean;
begin
  if Copy(Field, 1, 3) = '|1|' then
    Result := HashedNameMatches(Field, Name)
  else
    Result := MatchPatternList(Name, Field, False) = PatternListMatch;
end;

function SplitFields(const Line: string): TStringArray;
var
  Position, Start: Integer;
begin
  Result := nil;
  Position := 1;
  while Position <= Length(Line) do
  begin
    while (Position <= Length(Line)) and (Line[Position] in [' ', #9]) do
      Inc(Position);
    if Position > Length(Line) then
      Break;
    Start := Position;
    while (Position <= Length(Line)) and not (Line[Position] in [' ', #9]) do
      Inc(Position);
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := Copy(Line, Start, Position - Start);
  end;
end;

function LookupKnownHost(const Lines: TStringArray; const Host: string; Port: Word;
  const Blob: string): TKnownHostResult;
var
  Index, First: Integer;
  Fields: TStringArray;
  Name, ListedBlob: string;
  Revoked: Boolean;
begin
  Result := KnownHostUnknown;
  Name := KnownHostName(Host, Port);
  for Index := 0 to High(Lines) do
  begin
    Fields := SplitFields(Lines[Index]);
    if (Length(Fields) < 3) or (Fields[0][1] = '#') then
      Continue;
    First := 0;
    Revoked := False;
    if Fields[0][1] = '@' then
    begin
      if Fields[0] <> '@revoked' then
        Continue;
      Revoked := True;
      First := 1;
      if Length(Fields) < 4 then
        Continue;
    end;
    if not DecodeBase64(Fields[First + 2], ListedBlob) then
      Continue;
    if Revoked then
    begin
      if ListedBlob = Blob then
        Exit(KnownHostRevoked);
      Continue;
    end;
    if not HostFieldMatches(Fields[First], Name) then
      Continue;
    if ListedBlob = Blob then
      Result := KnownHostMatches
    else if (Result = KnownHostUnknown) and (Copy(ListedBlob, 1, Length(Fields[First + 1]) + 4) =
      SshString(Fields[First + 1])) and (Copy(Blob, 1, Length(Fields[First + 1]) + 4) = SshString(Fields[First + 1])) then
      { A different key of the same type for this host. }
      Result := KnownHostDiffers;
  end;
end;

function KnownHostLine(const Host: string; Port: Word; const Blob: string): string;
begin
  Result := KnownHostName(Host, Port) + ' ' + PublicKeyLine(Blob, '');
end;

end.
