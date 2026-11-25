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
  A package file opened: a tar.zst (libarchive) whose first member is
  +MANIFEST, then +DESC and the scripts it names, then the payload.
  The payload is checked against the manifest as it is unpacked: every
  file listed and of the listed size and SHA-256, every link pointing
  where the manifest says, nothing that is not listed.
}
unit Pkg.Archives;

{$mode objfpc}
{$H+}

interface

uses
  Classes,
  SysUtils,
  Archive.Readers,
  Pkg.Manifests;

type
  EPackageError = class(Exception);

  TPackageArchive = class
  private
    FFileName: string;
    FReader: TArchiveReader;
    FManifest: TPackageManifest;
    FDescription: string;
    FScripts: TPackageScripts;
    function ReadMember(const Name: string): string;
  public
    { Raises EPackageError when the file is not a package. }
    constructor Create(const FileName: string);
    destructor Destroy; override;
    { The payload member for a manifest path, or -1. }
    function MemberIndex(const Path: string): Integer;
    { Unpacks a file member into TargetPath (made or replaced), checking
      its size and SHA-256 against the manifest entry; False (and the
      file removed) when it does not match. }
    function ExtractCheckedFile(const Entry: TManifestEntry; const TargetPath: string; out Problem: string): Boolean;
    { Every problem found comparing the payload with the manifest,
      reading every file (nothing is written). }
    function Verify: TStringArray;
    function ScriptText(const Kind: string): string;
    property FileName: string read FFileName;
    property Manifest: TPackageManifest read FManifest;
    property Description: string read FDescription;
    property Scripts: TPackageScripts read FScripts;
  end;

implementation

uses
  Archive.Entries,
  Pkg.Hashing;

constructor TPackageArchive.Create(const FileName: string);
var
  Index: Integer;
  Kind: string;
begin
  inherited Create;
  FFileName := FileName;
  try
    FReader := OpenArchive(FileName);
  except
    on Error: Exception do
      raise EPackageError.CreateFmt('%s: %s', [FileName, Error.Message]);
  end;
  if (FReader.Count = 0) or (FReader[0].Name <> '+MANIFEST') then
    raise EPackageError.CreateFmt('%s is not a package: +MANIFEST is not its first member', [FileName]);
  try
    FManifest := TPackageManifest.Create(ReadMember('+MANIFEST'));
  except
    on Error: EManifestError do
      raise EPackageError.CreateFmt('%s: %s', [FileName, Error.Message]);
  end;
  if FReader.IndexOf('+DESC') >= 0 then
    FDescription := ReadMember('+DESC');
  FScripts := nil;
  for Index := 0 to High(FManifest.Scripts) do
  begin
    Kind := FManifest.Scripts[Index];
    if FReader.IndexOf('+' + Kind) < 0 then
      raise EPackageError.CreateFmt('%s: the manifest names a %s script it does not hold', [FileName, Kind]);
    SetLength(FScripts, Length(FScripts) + 1);
    FScripts[High(FScripts)].Kind := Kind;
    FScripts[High(FScripts)].Text := ReadMember('+' + Kind);
  end;
end;

destructor TPackageArchive.Destroy;
begin
  FManifest.Free;
  FReader.Free;
  inherited Destroy;
end;

function TPackageArchive.ReadMember(const Name: string): string;
var
  Index: Integer;
  Buffer: TStringStream;
begin
  Index := FReader.IndexOf(Name);
  if Index < 0 then
    raise EPackageError.CreateFmt('%s: no member %s', [FFileName, Name]);
  Buffer := TStringStream.Create('');
  try
    FReader.ExtractToStream(Index, Buffer);
    Result := Buffer.DataString;
  finally
    Buffer.Free;
  end;
end;

function TPackageArchive.ScriptText(const Kind: string): string;
var
  Index: Integer;
begin
  for Index := 0 to High(FScripts) do
    if FScripts[Index].Kind = Kind then
      Exit(FScripts[Index].Text);
  Result := '';
end;

function TPackageArchive.MemberIndex(const Path: string): Integer;
begin
  Result := FReader.IndexOf(Path);
end;

function TPackageArchive.ExtractCheckedFile(const Entry: TManifestEntry; const TargetPath: string;
  out Problem: string): Boolean;
var
  Index: Integer;
  Output: TFileStream;
  Hashing: THashingStream;
begin
  Problem := '';
  Index := FReader.IndexOf(Entry.Path);
  if (Index < 0) or FReader[Index].IsFolder or FReader[Index].IsLink then
  begin
    Problem := Format('%s is in the manifest but not in the package', [Entry.Path]);
    Exit(False);
  end;
  Output := TFileStream.Create(TargetPath, fmCreate);
  Hashing := THashingStream.Create(Output);
  try
    try
      FReader.ExtractToStream(Index, Hashing);
    except
      on Error: Exception do
        Problem := Format('%s: %s', [Entry.Path, Error.Message]);
    end;
    if (Problem = '') and ((Hashing.Written <> Entry.Size) or (Hashing.Sha256 <> Entry.Sha256)) then
      Problem := Format('%s does not match its checksum in the manifest', [Entry.Path]);
  finally
    Hashing.Free;
    Output.Free;
  end;
  Result := Problem = '';
  if not Result then
    DeleteFile(TargetPath);
end;

function TPackageArchive.Verify: TStringArray;
var
  Index, EntryIndex: Integer;
  Member: TArchiveEntry;
  Name: string;
  Hashing: THashingStream;
  Listed: TStringList;

  procedure Problem(const Text: string);
  begin
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := Text;
  end;

begin
  Result := nil;
  Listed := TStringList.Create;
  try
    Listed.Sorted := True;
    for Index := 0 to FReader.Count - 1 do
    begin
      Member := FReader[Index];
      Name := Member.Name;
      if (Name <> '') and (Name[Length(Name)] = '/') then
        SetLength(Name, Length(Name) - 1);
      if (Name = '') or (Name[1] = '+') then
        Continue;
      Listed.Add(Name);
      EntryIndex := FManifest.FindPath(Name);
      if Member.IsFolder then
        Continue;
      if EntryIndex < 0 then
      begin
        Problem(Format('%s is in the package but not in the manifest', [Name]));
        Continue;
      end;
      if Member.IsLink then
      begin
        if (FManifest.Entries[EntryIndex].Kind <> EntryLink) or
          (FManifest.Entries[EntryIndex].Target <> Member.LinkTarget) then
          Problem(Format('%s: the link is not as the manifest says', [Name]));
        Continue;
      end;
      Hashing := THashingStream.Create(nil);
      try
        FReader.ExtractToStream(Index, Hashing);
        if (FManifest.Entries[EntryIndex].Kind <> EntryFile) or
          (Hashing.Written <> FManifest.Entries[EntryIndex].Size) or
          (Hashing.Sha256 <> FManifest.Entries[EntryIndex].Sha256) then
          Problem(Format('%s does not match its checksum in the manifest', [Name]));
      finally
        Hashing.Free;
      end;
    end;
    for Index := 0 to High(FManifest.Entries) do
      if (FManifest.Entries[Index].Kind <> EntryDirectory) and (Listed.IndexOf(FManifest.Entries[Index].Path) < 0) then
        Problem(Format('%s is in the manifest but not in the package', [FManifest.Entries[Index].Path]));
  finally
    Listed.Free;
  end;
end;

end.
