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
  Checking an installed package against its manifest: every folder
  there, every file there with its size, SHA-256 and permissions, every
  link there pointing where it should, and its dependencies installed.
}
unit Pkg.Verification;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Pkg.Context,
  Pkg.Database;

{ The problems found (empty when the package is as installed). }
function VerifyPackage(Context: TPackageContext; Package: TInstalledPackage): TStringArray;

implementation

uses
  Classes,
  Pkg.FileSystem,
  Pkg.Hashing,
  Pkg.Installer,
  Pkg.Manifests;

function VerifyPackage(Context: TPackageContext; Package: TInstalledPackage): TStringArray;
var
  Index: Integer;
  Entry: TManifestEntry;
  Target, LinkTarget: string;
  Mode: LongWord;
  Size: Int64;
  Stream: TFileStream;

  procedure Problem(const Text: string);
  begin
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := Text;
  end;

begin
  Result := nil;
  for Index := 0 to High(Package.Manifest.Entries) do
  begin
    Entry := Package.Manifest.Entries[Index];
    Target := Context.Path(Entry.Path);
    case Entry.Kind of
      EntryDirectory:
        if not IsFolder(Target) then
          Problem(Format('/%s: the folder is missing', [Entry.Path]));
      EntryLink:
        if not IsSymbolicLink(Target) then
          Problem(Format('/%s: the link is missing', [Entry.Path]))
        else if not ReadLink(Target, LinkTarget) or (LinkTarget <> Entry.Target) then
          Problem(Format('/%s: the link points to %s, not %s', [Entry.Path, LinkTarget, Entry.Target]));
      EntryFile:
        begin
          if not IsRegularFile(Target) then
          begin
            Problem(Format('/%s: the file is missing', [Entry.Path]));
            Continue;
          end;
          Size := -1;
          try
            Stream := TFileStream.Create(Target, fmOpenRead or fmShareDenyNone);
            try
              Size := Stream.Size;
            finally
              Stream.Free;
            end;
          except
            Size := -1;
          end;
          if Size <> Entry.Size then
            Problem(Format('/%s: the size is %d, not %d', [Entry.Path, Size, Entry.Size]))
          else if Sha256OfFile(Target) <> Entry.Sha256 then
            Problem(Format('/%s: the SHA-256 does not match', [Entry.Path]));
          if PathPermissions(Target, Mode) and ((Mode and &777) <> (Entry.Mode and &777)) then
            Problem(Format('/%s: the permissions are %s, not %s',
              [Entry.Path, OctStr(Mode and &777, 3), OctStr(Entry.Mode and &777, 3)]));
        end;
    end;
  end;
  for Index := 0 to High(Package.Manifest.Depends) do
    if not DependencyInstalled(Context, Package.Manifest.Depends[Index]) then
      Problem(Format('needs %s, which is not installed', [Package.Manifest.Depends[Index]]));
end;

end.
