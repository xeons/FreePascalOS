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
  Removing an installed package: refused while another installed
  package needs it (unless it goes too, or --force); then its
  pre-remove script (a failure stops the removal), its files and links,
  its folders that are left empty (never the prefix's own hierarchy),
  its database entry, and its post-remove script. A file changed since
  it was installed is removed all the same, and said so.
}
unit Pkg.Remover;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Pkg.Context;

{ Removes the package called Name. Leaving lists packages removed in
  the same command, whose needs do not count. Raises EPackageRefused. }
procedure RemovePackage(Context: TPackageContext; const Name: string; const Leaving: TStringArray);

implementation

uses
  Archive.FileSystem,
  Pkg.Database,
  Pkg.FileSystem,
  Pkg.Hashing,
  Pkg.Manifests,
  Pkg.Paths;

function Contains(const Items: TStringArray; const Value: string): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to High(Items) do
    if Items[Index] = Value then
      Exit(True);
  Result := False;
end;

function RunStoredScript(Context: TPackageContext; Package: TInstalledPackage; const Kind: string): Integer;
var
  ScriptPath: string;
begin
  Result := 0;
  ScriptPath := Context.Database.EntryFolder(Package.Manifest.Name) + '/+' + Kind;
  if not FileExists(ScriptPath) or not Assigned(Context.RunScript) then
    Exit;
  Context.Say(Format('running the %s script of %s', [Kind, Package.Manifest.Name]));
  Result := Context.RunScript(Kind, ReadTextFile(ScriptPath), Package.Manifest, Context.Root);
end;

procedure RemovePackage(Context: TPackageContext; const Name: string; const Leaving: TStringArray);
var
  Package: TInstalledPackage;
  Manifest: TPackageManifest;
  Needing: TStringArray;
  Blocking: string;
  Index, Status: Integer;
  Entry: TManifestEntry;
  Target, PostRemoveScript, FullVersion: string;
begin
  Package := Context.Database.Find(Name);
  if Package = nil then
    raise EPackageRefused.CreateFmt('%s is not installed', [Name]);
  Needing := Context.Database.Dependents(Name);
  Blocking := '';
  for Index := 0 to High(Needing) do
    if not Contains(Leaving, Needing[Index]) then
    begin
      if Blocking <> '' then
        Blocking := Blocking + ', ';
      Blocking := Blocking + Needing[Index];
    end;
  if (Blocking <> '') and not Context.Force then
    raise EPackageRefused.CreateFmt('%s is needed by %s', [Name, Blocking]);

  Status := RunStoredScript(Context, Package, 'pre-remove');
  if (Status <> 0) and not Context.Force then
    raise EPackageRefused.CreateFmt('the pre-remove script of %s failed (status %d)', [Name, Status]);

  Manifest := Package.Manifest;
  FullVersion := Manifest.FullVersion;
  PostRemoveScript := '';
  if FileExists(Context.Database.EntryFolder(Name) + '/+post-remove') then
    PostRemoveScript := ReadTextFile(Context.Database.EntryFolder(Name) + '/+post-remove');

  for Index := 0 to High(Manifest.Entries) do
  begin
    Entry := Manifest.Entries[Index];
    if Entry.Kind = EntryDirectory then
      Continue;
    Target := Context.Path(Entry.Path);
    if not PathIsTaken(Target) then
    begin
      Context.Warn(Format('/%s was gone already', [Entry.Path]));
      Continue;
    end;
    if (Entry.Kind = EntryFile) and (Sha256OfFile(Target) <> Entry.Sha256) then
      Context.Warn(Format('/%s was changed since it was installed; removed all the same', [Entry.Path]));
    if not RemoveFileOrLink(Target) then
      Context.Warn(Format('cannot remove /%s', [Entry.Path]));
  end;
  { Deepest first: the manifest lists folders by path, parents first. }
  for Index := High(Manifest.Entries) downto 0 do
  begin
    Entry := Manifest.Entries[Index];
    if (Entry.Kind = EntryDirectory) and not IsStandardFolder(Entry.Path) then
      RemoveEmptyFolder(Context.Path(Entry.Path));
  end;

  { The manifest goes with the entry: keep what the script needs. }
  Manifest := TPackageManifest.Create(Manifest.Text);
  try
    Context.Database.Forget(Name);
    Context.Say(Format('removed %s %s', [Name, FullVersion]));
    if (PostRemoveScript <> '') and Assigned(Context.RunScript) then
    begin
      Context.Say(Format('running the post-remove script of %s', [Name]));
      Status := Context.RunScript('post-remove', PostRemoveScript, Manifest, Context.Root);
      if Status <> 0 then
        Context.Warn(Format('the post-remove script of %s failed (status %d)', [Name, Status]));
    end;
  finally
    Manifest.Free;
  end;
end;

end.
