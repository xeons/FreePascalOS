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
  The keys a client logs in with: each gives its public key blob and
  signs what user authentication needs signed. A key file's key
  (Ssh.KeyFiles: ed25519 or ecdsa-sha2-nistp256) signs itself; an
  agent's key (the ssh program's) asks the agent.

  The signature algorithm for a key: its own name, except for RSA keys,
  which sign with rsa-sha2-512 or rsa-sha2-256 when the server lists
  them in server-sig-algs (and never with SHA-1).
}
unit Ssh.ClientIdentities;

{$mode objfpc}{$H+}

interface

uses
  SysUtils,
  Ssh.HostKeys;

type
  TSshClientIdentity = class
  public
    function PublicBlob: string; virtual; abstract;
    { Where it comes from, for messages (a file name, a comment). }
    function Description: string; virtual; abstract;
    { The signature of Data with Algorithm, in SSH form; '' when it
      cannot be made. }
    function Sign(const Data, Algorithm: string): string; virtual; abstract;
  end;

  TSshClientIdentityArray = array of TSshClientIdentity;

  { A key read from a private key file; owns the key. }
  TSshKeyFileIdentity = class(TSshClientIdentity)
  private
    FKey: TSshHostKey;
    FPath: string;
  public
    constructor Create(Key: TSshHostKey; const Path: string);
    destructor Destroy; override;
    function PublicBlob: string; override;
    function Description: string; override;
    function Sign(const Data, Algorithm: string): string; override;
  end;

{ The algorithm to sign with for Blob's kind of key; '' when none the
  server takes (ServerAlgorithms empty: the server did not say, and the
  key's own name or rsa-sha2-256 is tried). }
function ChooseSignatureAlgorithm(const Blob: string; const ServerAlgorithms: TStringArray): string;

implementation

uses
  Ssh.Constants,
  Ssh.Wire;

constructor TSshKeyFileIdentity.Create(Key: TSshHostKey; const Path: string);
begin
  inherited Create;
  FKey := Key;
  FPath := Path;
end;

destructor TSshKeyFileIdentity.Destroy;
begin
  FKey.Free;
  inherited Destroy;
end;

function TSshKeyFileIdentity.PublicBlob: string;
begin
  Result := FKey.PublicBlob;
end;

function TSshKeyFileIdentity.Description: string;
begin
  Result := FPath;
end;

function TSshKeyFileIdentity.Sign(const Data, Algorithm: string): string;
begin
  if Algorithm <> FKey.Algorithm then
    Exit('');
  Result := FKey.Sign(Data);
end;

function ChooseSignatureAlgorithm(const Blob: string; const ServerAlgorithms: TStringArray): string;
var
  Reader: TSshReader;
  KeyType: string;
begin
  Result := '';
  try
    Reader.Start(Blob);
    KeyType := Reader.ReadString;
  except
    on ESshProtocolError do
      Exit;
  end;
  if KeyType = PublicKeyRsa then
  begin
    if Length(ServerAlgorithms) = 0 then
      Exit(SignatureRsaSha256);
    if NameListContains(ServerAlgorithms, SignatureRsaSha512) then
      Result := SignatureRsaSha512
    else if NameListContains(ServerAlgorithms, SignatureRsaSha256) then
      Result := SignatureRsaSha256;
  end
  else if (KeyType = HostKeyEd25519) or (KeyType = HostKeyEcdsaP256) then
    Result := KeyType;
end;

end.
