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
  Package repositories: folders of packages with an INDEX, served over
  HTTP or HTTPS (or a local folder: file:///path or a plain path),
  named in ROOT/etc/pkg/repositories, one a line:

    NAME URL                 the index must be signed with the key in
                             /etc/pkg/keys/NAME.pub
    NAME URL key=PATH        ... with the key in PATH
    NAME URL signature=none  unsigned (a local folder one trusts)

  `pkg update` fetches each INDEX (and INDEX.sig, an Ed25519 signature
  of it checked with libcryptography) into ROOT/var/cache/pkg/repos/NAME;
  a package is fetched into ROOT/var/cache/pkg and used only when its
  size and SHA-256 are the index's.
}
unit Pkg.Repositories;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Pkg.Context,
  Pkg.Index;

type
  TRepository = record
    Name: string;
    Url: string;
    KeyPath: string;
    Signed: Boolean;
  end;

  TRepositoryList = array of TRepository;
  TRepositoryIndexes = array of TRepositoryIndex;

function ReadRepositories(Context: TPackageContext): TRepositoryList;
{ Fetches and checks the repository's index into the cache. Raises
  EPackageRefused when it cannot be fetched or its signature is bad. }
procedure UpdateRepository(Context: TPackageContext; const Repository: TRepository);
{ The indexes in the cache (the caller frees them). }
function LoadCachedIndexes(Context: TPackageContext): TRepositoryIndexes;
procedure FreeIndexes(var Indexes: TRepositoryIndexes);
{ The newest package called (or providing) Name in any index. }
function FindInIndexes(const Indexes: TRepositoryIndexes; const Name, Architecture: string;
  out Entry: TIndexEntry): Boolean;
{ Fetches the package into the cache and checks it; its path. }
function FetchPackage(Context: TPackageContext; const Entry: TIndexEntry): string;
{ "ed25519 HEX" (32 bytes). }
function ReadPublicKey(const Path: string; out Key: TBytes): Boolean;
function SignatureMatches(const Text, SignatureText: string; const Key: TBytes): Boolean;
function JoinUrl(const Base, Name: string): string;

implementation

uses
  Classes,
  Crypto.Ed25519,
  Pkg.Database,
  Pkg.FileSystem,
  Pkg.Hashing,
  Pkg.Paths,
  Pkg.Versions;

function JoinUrl(const Base, Name: string): string;
var
  Trimmed: string;
begin
  Trimmed := Base;
  while (Length(Trimmed) > 0) and (Trimmed[Length(Trimmed)] = '/') do
    SetLength(Trimmed, Length(Trimmed) - 1);
  Result := Trimmed + '/' + Name;
end;

function ReadRepositories(Context: TPackageContext): TRepositoryList;
var
  Path, Line: string;
  Lines, Words: TStringArray;
  Index, WordIndex, Comment: Integer;
  Repository: TRepository;
begin
  Result := nil;
  Path := Context.Path(RepositoriesFile);
  if not FileExists(Path) then
    Exit;
  Lines := ReadTextFile(Path).Split([#10]);
  for Index := 0 to High(Lines) do
  begin
    Line := Lines[Index];
    Comment := Pos('#', Line);
    if Comment > 0 then
      Line := Copy(Line, 1, Comment - 1);
    Words := Trim(Line).Split([' ', #9], TStringSplitOptions.ExcludeEmpty);
    if Length(Words) = 0 then
      Continue;
    if Length(Words) < 2 then
    begin
      Context.Warn(Format('%s line %d: NAME URL [key=PATH|signature=none]', [Path, Index + 1]));
      Continue;
    end;
    Repository.Name := Words[0];
    Repository.Url := Words[1];
    Repository.KeyPath := Context.Path(KeysFolder + '/' + Words[0] + '.pub');
    Repository.Signed := True;
    for WordIndex := 2 to High(Words) do
      if Copy(Words[WordIndex], 1, 4) = 'key=' then
        Repository.KeyPath := Context.Path(Copy(Words[WordIndex], 5, MaxInt))
      else if Words[WordIndex] = 'signature=none' then
        Repository.Signed := False
      else
        Context.Warn(Format('%s line %d: what is %s?', [Path, Index + 1, Words[WordIndex]]));
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := Repository;
  end;
end;

function HexToBytes(const Text: string; out Bytes: TBytes): Boolean;
var
  Index, Value: Integer;
begin
  Bytes := nil;
  if Odd(Length(Text)) then
    Exit(False);
  SetLength(Bytes, Length(Text) div 2);
  for Index := 0 to High(Bytes) do
  begin
    if not TryStrToInt('$' + Copy(Text, Index * 2 + 1, 2), Value) then
      Exit(False);
    Bytes[Index] := Byte(Value);
  end;
  Result := True;
end;

function ReadPublicKey(const Path: string; out Key: TBytes): Boolean;
var
  Words: TStringArray;
begin
  Key := nil;
  if not FileExists(Path) then
    Exit(False);
  Words := Trim(ReadTextFile(Path)).Split([' ', #9, #10], TStringSplitOptions.ExcludeEmpty);
  Result := (Length(Words) = 2) and (Words[0] = 'ed25519') and HexToBytes(Words[1], Key) and (Length(Key) = 32);
end;

function SignatureMatches(const Text, SignatureText: string; const Key: TBytes): Boolean;
var
  Words: TStringArray;
  Signature: TBytes;
begin
  Words := Trim(SignatureText).Split([' ', #9, #10], TStringSplitOptions.ExcludeEmpty);
  if (Length(Words) <> 2) or (Words[0] <> 'ed25519') or not HexToBytes(Words[1], Signature) or
    (Length(Signature) <> 64) or (Length(Key) <> 32) then
    Exit(False);
  if Text = '' then
    Result := Ed25519Verify(@Key[0], nil, 0, @Signature[0])
  else
    Result := Ed25519Verify(@Key[0], PByte(@Text[1]), Length(Text), @Signature[0]);
end;

function CacheFolderOf(Context: TPackageContext; const Repository: string): string;
begin
  Result := Context.Path(RepositoryCacheFolder + '/' + Repository);
end;

procedure UpdateRepository(Context: TPackageContext; const Repository: TRepository);
var
  Folder, Problem, IndexText, SignatureText: string;
  Made: TStringArray;
  Key: TBytes;
  Index: TRepositoryIndex;
begin
  if not Assigned(Context.FetchUrl) then
    raise EPackageRefused.Create('no way to fetch repositories here');
  Folder := CacheFolderOf(Context, Repository.Name);
  Made := nil;
  if not MakeFolders(Folder, Made) then
    raise EPackageRefused.CreateFmt('cannot make %s', [Folder]);
  if not Context.FetchUrl(JoinUrl(Repository.Url, 'INDEX'), Folder + '/INDEX.new', Problem) then
    raise EPackageRefused.CreateFmt('%s: cannot fetch its index: %s', [Repository.Name, Problem]);
  IndexText := ReadTextFile(Folder + '/INDEX.new');
  if Repository.Signed then
  begin
    if not ReadPublicKey(Repository.KeyPath, Key) then
      raise EPackageRefused.CreateFmt('%s: no key in %s (or signature=none in %s)',
        [Repository.Name, Repository.KeyPath, RepositoriesFile]);
    if not Context.FetchUrl(JoinUrl(Repository.Url, 'INDEX.sig'), Folder + '/INDEX.sig.new', Problem) then
      raise EPackageRefused.CreateFmt('%s: cannot fetch the index''s signature: %s', [Repository.Name, Problem]);
    SignatureText := ReadTextFile(Folder + '/INDEX.sig.new');
    if not SignatureMatches(IndexText, SignatureText, Key) then
    begin
      DeleteFile(Folder + '/INDEX.new');
      DeleteFile(Folder + '/INDEX.sig.new');
      raise EPackageRefused.CreateFmt('%s: the index''s signature is bad', [Repository.Name]);
    end;
  end;
  { Read it before taking it, so a damaged index never replaces a good one. }
  try
    Index := TRepositoryIndex.Create(IndexText, Repository.Name);
  except
    on Error: Exception do
      raise EPackageRefused.CreateFmt('%s: %s', [Repository.Name, Error.Message]);
  end;
  Context.Say(Format('%s: %d package(s)', [Repository.Name, Length(Index.Entries)]));
  Index.Free;
  RenamePathOver(Folder + '/INDEX.new', Folder + '/INDEX');
  if Repository.Signed then
    RenamePathOver(Folder + '/INDEX.sig.new', Folder + '/INDEX.sig');
end;

function LoadCachedIndexes(Context: TPackageContext): TRepositoryIndexes;
var
  Repositories: TRepositoryList;
  Index: Integer;
  Path: string;
begin
  Result := nil;
  Repositories := ReadRepositories(Context);
  for Index := 0 to High(Repositories) do
  begin
    Path := CacheFolderOf(Context, Repositories[Index].Name) + '/INDEX';
    if not FileExists(Path) then
    begin
      Context.Warn(Format('%s has no index yet (pkg update)', [Repositories[Index].Name]));
      Continue;
    end;
    try
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := TRepositoryIndex.Create(ReadTextFile(Path), Repositories[Index].Name);
    except
      on Error: Exception do
      begin
        SetLength(Result, Length(Result) - 1);
        Context.Warn(Format('%s: %s', [Path, Error.Message]));
      end;
    end;
  end;
end;

procedure FreeIndexes(var Indexes: TRepositoryIndexes);
var
  Index: Integer;
begin
  for Index := 0 to High(Indexes) do
    Indexes[Index].Free;
  Indexes := nil;
end;

function FindInIndexes(const Indexes: TRepositoryIndexes; const Name, Architecture: string;
  out Entry: TIndexEntry): Boolean;
var
  Index, Found: Integer;
  Best: TIndexEntry;
  HaveBest, BestIsNamed, CandidateIsNamed: Boolean;
begin
  Best := Default(TIndexEntry);
  HaveBest := False;
  BestIsNamed := False;
  for Index := 0 to High(Indexes) do
  begin
    Found := Indexes[Index].FindNewest(Name, Architecture);
    if Found < 0 then
      Continue;
    CandidateIsNamed := Indexes[Index].Entries[Found].Name = Name;
    { A package of that name wins over one providing it; then the newest. }
    if not HaveBest or (CandidateIsNamed and not BestIsNamed) or
      ((CandidateIsNamed = BestIsNamed) and
      (CompareVersions(IndexEntryFullVersion(Indexes[Index].Entries[Found]), IndexEntryFullVersion(Best)) > 0)) then
    begin
      Best := Indexes[Index].Entries[Found];
      BestIsNamed := CandidateIsNamed;
      HaveBest := True;
    end;
  end;
  Result := HaveBest;
  if Result then
    Entry := Best;
end;

function RepositoryUrl(Context: TPackageContext; const Name: string): string;
var
  Repositories: TRepositoryList;
  Index: Integer;
begin
  Result := '';
  Repositories := ReadRepositories(Context);
  for Index := 0 to High(Repositories) do
    if Repositories[Index].Name = Name then
      Exit(Repositories[Index].Url);
end;

function FileSize(const Path: string): Int64;
var
  Stream: TFileStream;
begin
  Result := -1;
  try
    Stream := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
    try
      Result := Stream.Size;
    finally
      Stream.Free;
    end;
  except
    Result := -1;
  end;
end;

function FetchPackage(Context: TPackageContext; const Entry: TIndexEntry): string;
var
  Folder, Partial, Problem, Url: string;
  Made: TStringArray;
begin
  Folder := Context.Path(CacheFolder);
  Made := nil;
  MakeFolders(Folder, Made);
  Result := Folder + '/' + Entry.FileName;
  if (FileSize(Result) = Entry.Size) and (Sha256OfFile(Result) = Entry.Sha256) then
    Exit;
  Url := RepositoryUrl(Context, Entry.Repository);
  if Url = '' then
    raise EPackageRefused.CreateFmt('repository %s is no longer configured', [Entry.Repository]);
  if not Assigned(Context.FetchUrl) then
    raise EPackageRefused.Create('no way to fetch packages here');
  Partial := Result + '.partial';
  Context.Say(Format('fetching %s', [Entry.FileName]));
  if not Context.FetchUrl(JoinUrl(Url, Entry.FileName), Partial, Problem) then
    raise EPackageRefused.CreateFmt('cannot fetch %s: %s', [Entry.FileName, Problem]);
  if (FileSize(Partial) <> Entry.Size) or (Sha256OfFile(Partial) <> Entry.Sha256) then
  begin
    DeleteFile(Partial);
    raise EPackageRefused.CreateFmt('%s does not match the index''s size and SHA-256', [Entry.FileName]);
  end;
  if not RenamePathOver(Partial, Result) then
    raise EPackageRefused.CreateFmt('cannot keep %s', [Result]);
end;

end.
