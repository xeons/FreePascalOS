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
  What installing, removing and checking packages work with: the root,
  the database, how to say things, how to run a package's scripts and
  how to fetch a URL. The program gives the system's ways (Pkg.System:
  /bin/sh, libhttp); the host test gives its own, so everything but
  those two runs on the host.
}
unit Pkg.Context;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Pkg.Database,
  Pkg.Manifests;

type
  EPackageRefused = class(Exception);

  TMessageEvent = procedure(const Text: string) of object;
  { Runs a package's script (its text) for the package; the exit status. }
  TScriptRunner = function(const Kind, Text: string; Manifest: TPackageManifest; const Root: string): Integer
    of object;
  { Fetches Url into TargetPath; False with a Problem when it cannot. }
  TUrlFetcher = function(const Url, TargetPath: string; out Problem: string): Boolean of object;

  TPackageContext = class
  private
    FRoot: string;
    FDatabase: TPackageDatabase;
  public
    { Go ahead past refusals: an older or the same version, files that
      belong to no package, missing dependents. }
    Force: Boolean;
    Architecture: string;
    OnMessage: TMessageEvent;
    OnWarning: TMessageEvent;
    RunScript: TScriptRunner;
    FetchUrl: TUrlFetcher;
    constructor Create(const Root: string);
    destructor Destroy; override;
    procedure Say(const Text: string);
    procedure Warn(const Text: string);
    { ROOT/Relative. }
    function Path(const Relative: string): string;
    property Root: string read FRoot;
    property Database: TPackageDatabase read FDatabase;
  end;

implementation

uses
  Pkg.Paths;

constructor TPackageContext.Create(const Root: string);
begin
  inherited Create;
  FRoot := Root;
  FDatabase := TPackageDatabase.Create(Root);
  FDatabase.Load;
  Architecture := MachineArchitecture;
end;

destructor TPackageContext.Destroy;
begin
  FDatabase.Free;
  inherited Destroy;
end;

procedure TPackageContext.Say(const Text: string);
begin
  if Assigned(OnMessage) then
    OnMessage(Text);
end;

procedure TPackageContext.Warn(const Text: string);
begin
  if Assigned(OnWarning) then
    OnWarning(Text)
  else
    Say(Text);
end;

function TPackageContext.Path(const Relative: string): string;
begin
  Result := RootedPath(FRoot, Relative);
end;

end.
