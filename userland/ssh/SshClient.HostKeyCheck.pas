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
  Whether the server's host key is the one known for it
  (~/.ssh/known_hosts, Ssh.KnownHosts), as StrictHostKeyChecking says:

    ask (default)   a new host is shown with its key's fingerprint and
                    added if the answer is yes
    accept-new      a new host is added without asking
    no              a new host is added without asking
    yes             a new host is refused

  A host whose known key differs, or a revoked key, is always refused,
  with a warning: someone may be in the middle.
}
unit SshClient.HostKeyCheck;

{$mode objfpc}{$H+}

interface

uses
  SshClient.Options;

type
  THostKeyChecker = class
  private
    FOptions: TSshClientOptions;
    procedure Remember(const Blob: string);
  public
    constructor Create(const Options: TSshClientOptions);
    function Check(const Blob: string): Boolean;
  end;

implementation

uses
  SysUtils,
  Classes,
  Ssh.Wire,
  Ssh.PublicKeys,
  Ssh.KnownHosts,
  SshClient.Prompts;

constructor THostKeyChecker.Create(const Options: TSshClientOptions);
begin
  inherited Create;
  FOptions := Options;
end;

function ReadLines(const Path: string): TStringArray;
var
  List: TStringList;
  Index: Integer;
begin
  Result := nil;
  if not FileExists(Path) then
    Exit;
  List := TStringList.Create;
  try
    try
      List.LoadFromFile(Path);
    except
      on Exception do
        Exit;
    end;
    SetLength(Result, List.Count);
    for Index := 0 to List.Count - 1 do
      Result[Index] := List[Index];
  finally
    List.Free;
  end;
end;

procedure THostKeyChecker.Remember(const Blob: string);
var
  Output: TextFile;
  Directory: string;
begin
  if FOptions.KnownHostsFile = '/dev/null' then
    Exit;
  Directory := ExtractFileDir(FOptions.KnownHostsFile);
  if (Directory <> '') and not DirectoryExists(Directory) then
    CreateDir(Directory);
  try
    AssignFile(Output, FOptions.KnownHostsFile);
    if FileExists(FOptions.KnownHostsFile) then
      Append(Output)
    else
      Rewrite(Output);
    WriteLn(Output, KnownHostLine(FOptions.Host, FOptions.Port, Blob));
    CloseFile(Output);
    if not FOptions.Quiet then
      WriteLn(ErrOutput, 'Warning: Permanently added ''', KnownHostName(FOptions.Host, FOptions.Port),
        ''' to the list of known hosts.');
  except
    on Error: Exception do
      WriteLn(ErrOutput, 'ssh: cannot add the host to ', FOptions.KnownHostsFile, ': ', Error.Message);
  end;
end;

function KeyTypeOf(const Blob: string): string;
var
  Reader: TSshReader;
begin
  Reader.Start(Blob);
  Result := Reader.ReadString;
end;

function THostKeyChecker.Check(const Blob: string): Boolean;
var
  Outcome: TKnownHostResult;
begin
  Outcome := LookupKnownHost(ReadLines(FOptions.KnownHostsFile), FOptions.Host, FOptions.Port, Blob);
  case Outcome of
    KnownHostMatches:
      Exit(True);
    KnownHostRevoked:
      begin
        WriteLn(ErrOutput, 'ssh: the host key of ', FOptions.Host, ' is revoked');
        Exit(False);
      end;
    KnownHostDiffers:
      begin
        WriteLn(ErrOutput, '@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@');
        WriteLn(ErrOutput, '@    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @');
        WriteLn(ErrOutput, '@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@');
        WriteLn(ErrOutput, 'Someone could be eavesdropping on you right now (man-in-the-middle attack)!');
        WriteLn(ErrOutput, 'The ', KeyTypeOf(Blob), ' key sent by ', FOptions.Host, ' is ', PublicKeyFingerprint(Blob), '.');
        WriteLn(ErrOutput, 'Remove the old key from ', FOptions.KnownHostsFile, ' if the change is expected.');
        Exit(False);
      end;
  end;
  case FOptions.HostKeyChecking of
    HostKeyCheckingYes:
      begin
        WriteLn(ErrOutput, 'ssh: no ', KeyTypeOf(Blob), ' host key is known for ', FOptions.Host,
          ' and StrictHostKeyChecking is yes');
        Exit(False);
      end;
    HostKeyCheckingAsk:
      begin
        WriteLn(ErrOutput, 'The authenticity of host ''', FOptions.Host, ''' can''t be established.');
        WriteLn(ErrOutput, KeyTypeOf(Blob), ' key fingerprint is ', PublicKeyFingerprint(Blob), '.');
        if FOptions.BatchMode or not AskYesNo('Are you sure you want to continue connecting') then
        begin
          WriteLn(ErrOutput, 'ssh: host key verification failed.');
          Exit(False);
        end;
      end;
  end;
  Remember(Blob);
  Result := True;
end;

end.
