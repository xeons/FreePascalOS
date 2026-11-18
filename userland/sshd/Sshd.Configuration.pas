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
  The SSH server's configuration, /etc/ssh/sshd_config: lines of a
  keyword and a value, as OpenSSH's (keywords in any case, # comments).

    Port 22
    PasswordAuthentication yes
    PubkeyAuthentication yes
    PermitRootLogin yes
    HostKey /etc/ssh/ssh_host_ed25519_key      (one line per key)
    HostKey /etc/ssh/ssh_host_ecdsa_key
    Subsystem sftp /bin/sftp-server
    LoginGraceTime 120                          (seconds to log in)
    MaxSessions 8                               (channels per connection)

  A missing file gives these defaults. An unknown keyword or a wrong
  value is reported and the line ignored.
}
unit Sshd.Configuration;

{$mode objfpc}{$H+}

interface

uses
  SysUtils;

const
  DefaultConfigurationPath = '/etc/ssh/sshd_config';
  DefaultEd25519HostKeyPath = '/etc/ssh/ssh_host_ed25519_key';
  DefaultEcdsaHostKeyPath = '/etc/ssh/ssh_host_ecdsa_key';
  DefaultSftpServerPath = '/bin/sftp-server';

type
  TSshdConfiguration = record
    Port: Word;
    PasswordAuthentication: Boolean;
    PublicKeyAuthentication: Boolean;
    PermitRootLogin: Boolean;
    HostKeyPaths: TStringArray;
    SftpServerPath: string;
    LoginGraceSeconds: Integer;
    MaximumSessions: Integer;
  end;

function DefaultConfiguration: TSshdConfiguration;
{ Reads Path over the defaults; Problems gets a line for each wrong
  line. A missing file is no problem. }
function ReadConfiguration(const Path: string; out Problems: TStringArray): TSshdConfiguration;

implementation

uses
  Classes;

function DefaultConfiguration: TSshdConfiguration;
begin
  Result.Port := 22;
  Result.PasswordAuthentication := True;
  Result.PublicKeyAuthentication := True;
  Result.PermitRootLogin := True;
  Result.HostKeyPaths := nil;
  Result.SftpServerPath := DefaultSftpServerPath;
  Result.LoginGraceSeconds := 120;
  Result.MaximumSessions := 8;
end;

procedure AddText(var Texts: TStringArray; const Text: string);
begin
  SetLength(Texts, Length(Texts) + 1);
  Texts[High(Texts)] := Text;
end;

function ParseYesNo(const Value: string; out Flag: Boolean): Boolean;
begin
  Result := True;
  if SameText(Value, 'yes') then
    Flag := True
  else if SameText(Value, 'no') then
    Flag := False
  else
    Result := False;
end;

function ParseNumber(const Value: string; Lowest, Highest: Integer; out Number: Integer): Boolean;
begin
  Result := TryStrToInt(Value, Number) and (Number >= Lowest) and (Number <= Highest);
end;

{ Splits a line into its keyword and the rest. }
procedure SplitLine(const Line: string; out Keyword, Value: string);
var
  Trimmed: string;
  Space: Integer;
begin
  Trimmed := Trim(Line);
  Space := 1;
  while (Space <= Length(Trimmed)) and not (Trimmed[Space] in [' ', #9, '=']) do
    Inc(Space);
  Keyword := Copy(Trimmed, 1, Space - 1);
  Value := Trim(Copy(Trimmed, Space + 1, MaxInt));
  if (Value <> '') and (Value[1] = '=') then
    Value := Trim(Copy(Value, 2, MaxInt));
end;

function ReadConfiguration(const Path: string; out Problems: TStringArray): TSshdConfiguration;
var
  Lines: TStringList;
  Index: Integer;
  Keyword, Value, Name, Program_: string;
  Number: Integer;
  Flag: Boolean;
  Valid: Boolean;
  Space: Integer;
begin
  Result := DefaultConfiguration;
  Problems := nil;
  Lines := TStringList.Create;
  try
    if FileExists(Path) then
    begin
      try
        Lines.LoadFromFile(Path);
      except
        on Error: Exception do
          AddText(Problems, Path + ': ' + Error.Message);
      end;
    end;
    for Index := 0 to Lines.Count - 1 do
    begin
      SplitLine(Lines[Index], Keyword, Value);
      if (Keyword = '') or (Keyword[1] = '#') then
        Continue;
      Valid := True;
      if SameText(Keyword, 'Port') then
      begin
        Valid := ParseNumber(Value, 1, 65535, Number);
        if Valid then
          Result.Port := Word(Number);
      end
      else if SameText(Keyword, 'PasswordAuthentication') then
      begin
        Valid := ParseYesNo(Value, Flag);
        if Valid then
          Result.PasswordAuthentication := Flag;
      end
      else if SameText(Keyword, 'PubkeyAuthentication') then
      begin
        Valid := ParseYesNo(Value, Flag);
        if Valid then
          Result.PublicKeyAuthentication := Flag;
      end
      else if SameText(Keyword, 'PermitRootLogin') then
      begin
        Valid := ParseYesNo(Value, Flag);
        if Valid then
          Result.PermitRootLogin := Flag;
      end
      else if SameText(Keyword, 'HostKey') then
      begin
        Valid := (Value <> '') and (Value[1] = '/');
        if Valid then
          AddText(Result.HostKeyPaths, Value);
      end
      else if SameText(Keyword, 'Subsystem') then
      begin
        Space := Pos(' ', Value);
        Name := Copy(Value, 1, Space - 1);
        Program_ := Trim(Copy(Value, Space + 1, MaxInt));
        Valid := (Space > 0) and SameText(Name, 'sftp') and (Program_ <> '');
        if Valid then
          Result.SftpServerPath := Program_;
      end
      else if SameText(Keyword, 'LoginGraceTime') then
      begin
        Valid := ParseNumber(Value, 0, 3600, Number);
        if Valid then
          Result.LoginGraceSeconds := Number;
      end
      else if SameText(Keyword, 'MaxSessions') then
      begin
        Valid := ParseNumber(Value, 1, 16, Number);
        if Valid then
          Result.MaximumSessions := Number;
      end
      else
      begin
        AddText(Problems, Format('%s line %d: unknown keyword %s', [Path, Index + 1, Keyword]));
        Continue;
      end;
      if not Valid then
        AddText(Problems, Format('%s line %d: bad value for %s: %s', [Path, Index + 1, Keyword, Value]));
    end;
  finally
    Lines.Free;
  end;
  if Length(Result.HostKeyPaths) = 0 then
  begin
    AddText(Result.HostKeyPaths, DefaultEd25519HostKeyPath);
    AddText(Result.HostKeyPaths, DefaultEcdsaHostKeyPath);
  end;
end;

end.
