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
  SHA-256 (libcryptography's Crypto.Digests) of files and of data as it
  is written: THashingStream passes what is written to it on to another
  stream (or nowhere) and counts and hashes it on the way, so a member
  is checked while it is unpacked.
}
unit Pkg.Hashing;

{$mode objfpc}
{$H+}

interface

uses
  Classes,
  SysUtils,
  Crypto.Digests;

type
  THashingStream = class(TStream)
  private
    FTarget: TStream;
    FContext: TDigestContext;
    FWritten: Int64;
    FFinished: Boolean;
    FHash: string;
  public
    { Target may be nil: the data is only hashed. }
    constructor Create(Target: TStream);
    function Write(const Buffer; Count: LongInt): LongInt; override;
    function Read(var Buffer; Count: LongInt): LongInt; override;
    function Seek(const Offset: Int64; Origin: TSeekOrigin): Int64; override;
    { The SHA-256 of everything written, in lower case hex. }
    function Sha256: string;
    property Written: Int64 read FWritten;
  end;

function DigestHex(const Digest: TDigestOutput; Size: Integer): string;
function Sha256OfBytes(Data: PByte; Count: QWord): string;
{ '' when the file cannot be read. }
function Sha256OfFile(const Path: string): string;

implementation

function DigestHex(const Digest: TDigestOutput; Size: Integer): string;
const
  HexDigits: array[0..15] of Char = '0123456789abcdef';
var
  Index: Integer;
begin
  Result := '';
  SetLength(Result, Size * 2);
  for Index := 0 to Size - 1 do
  begin
    Result[Index * 2 + 1] := HexDigits[Digest[Index] shr 4];
    Result[Index * 2 + 2] := HexDigits[Digest[Index] and 15];
  end;
end;

constructor THashingStream.Create(Target: TStream);
begin
  inherited Create;
  FTarget := Target;
  BeginDigest(FContext, DigestSha256);
end;

function THashingStream.Write(const Buffer; Count: LongInt): LongInt;
begin
  if Count <= 0 then
    Exit(0);
  if FTarget <> nil then
    FTarget.WriteBuffer(Buffer, Count);
  UpdateDigest(FContext, @Buffer, Count);
  Inc(FWritten, Count);
  Result := Count;
end;

function THashingStream.Read(var Buffer; Count: LongInt): LongInt;
begin
  raise EStreamError.Create('A hashing stream is only written');
  Result := 0;
end;

function THashingStream.Seek(const Offset: Int64; Origin: TSeekOrigin): Int64;
begin
  if (Offset = 0) and (Origin in [soCurrent, soEnd]) then
    Exit(FWritten);
  raise EStreamError.Create('A hashing stream cannot seek');
  Result := 0;
end;

function THashingStream.Sha256: string;
var
  Digest: TDigestOutput;
begin
  if not FFinished then
  begin
    FinishDigest(FContext, Digest);
    FHash := DigestHex(Digest, DigestSize(DigestSha256));
    FFinished := True;
  end;
  Result := FHash;
end;

function Sha256OfBytes(Data: PByte; Count: QWord): string;
var
  Digest: TDigestOutput;
begin
  ComputeDigest(DigestSha256, Data, Count, Digest);
  Result := DigestHex(Digest, DigestSize(DigestSha256));
end;

function Sha256OfFile(const Path: string): string;
var
  Source: TFileStream;
  Hashing: THashingStream;
begin
  Result := '';
  try
    Source := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
  except
    Exit;
  end;
  Hashing := THashingStream.Create(nil);
  try
    try
      Hashing.CopyFrom(Source, 0);
      Result := Hashing.Sha256;
    except
      Result := '';
    end;
  finally
    Hashing.Free;
    Source.Free;
  end;
end;

end.
