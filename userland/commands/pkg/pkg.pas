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
  pkg - install, remove and check packages

  pkg [-r ROOT] COMMAND [ARGUMENT]...

  Packages are the ports tree's (ports/, scripts/ports.py): tar.zst
  files with a manifest of every file and its SHA-256. Installed ones
  are recorded in /var/db/pkg; repositories are named in
  /etc/pkg/repositories and their indexes checked with the Ed25519 keys
  in /etc/pkg/keys. Installing is a transaction: everything is checked
  and staged first, then renamed into place, and undone on failure.
  The units are in userland/commands/pkg (Pkg.*).

  Exit status: 0 done, 1 something failed or was refused, 2 bad usage.
}
program pkg;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  Pkg.Commands,
  Pkg.Context,
  Pkg.FileSystem,
  Pkg.Paths,
  Pkg.System;

const
  Usage = 'Usage: pkg [-r ROOT] COMMAND [ARGUMENT]...'#10 +
    'Install, remove and check packages.'#10 +
    #10 +
    '  install [-f] [-A] FILE|NAME...  install package files, or packages from the repositories'#10 +
    '                                  (with what they need); -f: past refusals; -A: as a dependency'#10 +
    '  remove [-f] NAME...             remove installed packages (-f: even if others need them)'#10 +
    '  info [-l] [NAME|FILE]...        describe packages (-l: and their files)'#10 +
    '  list [-q]                       the installed packages (-q: names only)'#10 +
    '  which FILE...                   the package a file was installed by'#10 +
    '  verify [NAME]...                check installed files against their checksums'#10 +
    '  search WORD...                  find packages in the repositories'#10 +
    '  update                          fetch the repositories'' indexes'#10 +
    '  upgrade [NAME]...               install newer versions from the repositories'#10 +
    '  test NAME...                    run a package''s own checks'#10 +
    #10 +
    '  -r ROOT                         work on the system under ROOT instead of /';

var
  Root: string;
  Command: string;
  Arguments: TStringArray;
  Force, Automatic, ListFiles, Quiet: Boolean;
  Services: TSystemServices;
  Context: TPackageContext;
  LockHandle: Int64;
  ExitStatus: Integer;

procedure Fail(const Text: string; Status: Integer);
begin
  WriteLn(StdErr, 'pkg: ', Text);
  Halt(Status);
end;

procedure ParseCommandLine;
var
  Index: Integer;
  Parameter: string;
begin
  Root := GetEnvironmentVariable('PKG_ROOT');
  Command := '';
  Arguments := nil;
  Force := False;
  Automatic := False;
  ListFiles := False;
  Quiet := False;
  Index := 1;
  while Index <= ParamCount do
  begin
    Parameter := ParamStr(Index);
    if (Parameter = '-h') or (Parameter = '--help') or (Parameter = 'help') then
    begin
      WriteLn(Usage);
      Halt(0);
    end
    else if (Parameter = '-r') and (Command = '') then
    begin
      Inc(Index);
      if Index > ParamCount then
        Fail('-r needs a folder', 2);
      Root := ParamStr(Index);
    end
    else if (Parameter = '-f') and (Command <> '') then
      Force := True
    else if (Parameter = '-A') and (Command <> '') then
      Automatic := True
    else if (Parameter = '-l') and (Command <> '') then
      ListFiles := True
    else if (Parameter = '-q') and (Command <> '') then
      Quiet := True
    else if (Parameter <> '') and (Parameter[1] = '-') then
      Fail('unknown option ' + Parameter + ' (pkg --help)', 2)
    else if Command = '' then
      Command := Parameter
    else
    begin
      SetLength(Arguments, Length(Arguments) + 1);
      Arguments[High(Arguments)] := Parameter;
    end;
    Inc(Index);
  end;
  if Command = '' then
  begin
    WriteLn(StdErr, Usage);
    Halt(2);
  end;
  if Command = 'delete' then
    Command := 'remove';
end;

function ChangesSystem: Boolean;
begin
  Result := (Command = 'install') or (Command = 'remove') or (Command = 'update') or (Command = 'upgrade');
end;

procedure NeedArguments;
begin
  if Length(Arguments) = 0 then
    Fail(Command + ' needs at least one argument (pkg --help)', 2);
end;

procedure TakeLock;
var
  Made: TStringArray;
begin
  Made := nil;
  MakeFolders(RootedPath(Root, DatabaseFolder), Made);
  LockHandle := AcquireLock(RootedPath(Root, DatabaseFolder + '/' + LockFileName));
  if LockHandle < 0 then
    Fail('another pkg is changing the system (or ' + RootedPath(Root, DatabaseFolder) + ' cannot be written)', 1);
end;

begin
  ParseCommandLine;
  LockHandle := -1;
  if ChangesSystem then
    TakeLock;
  Services := TSystemServices.Create;
  try
    try
      Context := CreateSystemContext(Root, Services);
    except
      on Error: Exception do
        Fail(Error.Message, 1);
    end;
    try
      Context.Force := Force;
      if Command = 'install' then
      begin
        NeedArguments;
        ExitStatus := InstallCommand(Context, Arguments, Automatic);
      end
      else if Command = 'remove' then
      begin
        NeedArguments;
        ExitStatus := RemoveCommand(Context, Arguments);
      end
      else if Command = 'info' then
        ExitStatus := InfoCommand(Context, Arguments, ListFiles)
      else if Command = 'list' then
        ExitStatus := ListCommand(Context, Quiet)
      else if Command = 'which' then
      begin
        NeedArguments;
        ExitStatus := WhichCommand(Context, Arguments);
      end
      else if Command = 'verify' then
        ExitStatus := VerifyCommand(Context, Arguments)
      else if Command = 'search' then
      begin
        NeedArguments;
        ExitStatus := SearchCommand(Context, Arguments);
      end
      else if Command = 'update' then
        ExitStatus := UpdateCommand(Context)
      else if Command = 'upgrade' then
        ExitStatus := UpgradeCommand(Context, Arguments)
      else if Command = 'test' then
      begin
        NeedArguments;
        ExitStatus := TestCommand(Context, Arguments);
      end
      else
        Fail('unknown command ' + Command + ' (pkg --help)', 2);
    finally
      Context.Free;
    end;
  finally
    Services.Free;
    ReleaseLock(LockHandle);
  end;
  Halt(ExitStatus);
end.
