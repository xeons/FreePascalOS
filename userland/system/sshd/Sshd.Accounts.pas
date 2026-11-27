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
  Who may log in over SSH, by the system's accounts (Util.Logins,
  Util.Passwords) and the configuration as it applies to the user and
  the client's address (Match blocks):

  - an account that exists, whose password is not locked ("!" in
    /etc/shadow) and whose shell is not /bin/false; root only when
    PermitRootLogin is yes;
  - publickey: a key in the AuthorizedKeysFile (~/.ssh/authorized_keys,
    read as root) with its options (Ssh.AuthorizedKeys): from= must
    match the client's address and expiry-time must not have passed; or
    a user certificate (Ssh.Certificates) signed by a CA of
    TrustedUserCAKeys or of an authorized_keys line with cert-authority
    (and principals=), for this user, valid now, from an address its
    source-address allows; its extensions become the options;
  - password and keyboard-interactive: the account's password, never an
    empty one. A wrong one is answered after a second, so passwords
    cannot be tried quickly.
}
unit Sshd.Accounts;

{$mode objfpc}{$H+}

interface

uses
  SysUtils,
  Ssh.AuthorizedKeys,
  Ssh.UserAuthentication,
  Sshd.Configuration;

type
  TSystemAccountPolicy = class(TSshAccountPolicy)
  private
    FBase: TSshdConfiguration;
    FPeerAddress: string;
    FLocalPort: Word;
    function ConfigurationOf(const User: string): TSshdConfiguration;
    function MayLogIn(const User: string): Boolean;
    function ReadLines(const Path: string; out Lines: TStringArray): Boolean;
    function AuthorizePlainKey(const User, Blob: string; const Configuration: TSshdConfiguration;
      out Options: TSshKeyOptions): Boolean;
    function AuthorizeCertificate(const User, Blob: string; const Configuration: TSshdConfiguration;
      out Options: TSshKeyOptions): Boolean;
    function AuthorizedKeysPath(const User: string; const Configuration: TSshdConfiguration): string;
  public
    constructor Create(const Configuration: TSshdConfiguration; const PeerAddress: string; LocalPort: Word);
    function PublicKeyAuthenticationAllowed(const User: string): Boolean; override;
    function PasswordAuthenticationAllowed(const User: string): Boolean; override;
    function KeyboardInteractiveAllowed(const User: string): Boolean; override;
    function AuthorizeKey(const User, Blob: string; out Options: TSshKeyOptions): Boolean; override;
    function PasswordIsRight(const User, Password: string): Boolean; override;
    procedure Note(const Text: string); override;
  end;

{ The Match context of a user (known or not) at an address and port. }
function MatchContextFor(const User: string; const PeerAddress: string; LocalPort: Word): TSshdMatchContext;

implementation

uses
  Classes,
  Sys.Processes,
  Sys.Time,
  Util.Accounts,
  Util.Logins,
  Util.Passwords,
  Ssh.Wire,
  Ssh.Base64,
  Ssh.PublicKeys,
  Ssh.Certificates,
  Ssh.AddressPatterns,
  Sshd.Log;

const
  PauseAfterWrongPasswordMilliseconds = 1000;
  LockedShell = '/bin/false';

function MatchContextFor(const User: string; const PeerAddress: string; LocalPort: Word): TSshdMatchContext;
var
  UserId, PrimaryGroup: LongWord;
  Groups: TIdArray;
  Index: Integer;
  Name: string;

  procedure AddGroup(GroupId: LongWord);
  begin
    if FindGroupName(GroupId, Name) and not NameListContains(Result.Groups, Name) then
    begin
      SetLength(Result.Groups, Length(Result.Groups) + 1);
      Result.Groups[High(Result.Groups)] := Name;
    end;
  end;

begin
  Result := Default(TSshdMatchContext);
  Result.Address := PeerAddress;
  Result.LocalPort := LocalPort;
  if (User = '') or not FindUserId(User, UserId) then
    Exit;
  Result.User := User;
  Result.UserKnown := True;
  if PrimaryGroupOf(UserId, PrimaryGroup) then
    AddGroup(PrimaryGroup);
  Groups := GroupsOfUser(UserId);
  for Index := 0 to High(Groups) do
    AddGroup(Groups[Index]);
end;

constructor TSystemAccountPolicy.Create(const Configuration: TSshdConfiguration; const PeerAddress: string;
  LocalPort: Word);
begin
  inherited Create;
  FBase := Configuration;
  FPeerAddress := PeerAddress;
  FLocalPort := LocalPort;
end;

function TSystemAccountPolicy.ConfigurationOf(const User: string): TSshdConfiguration;
begin
  Result := ConfigurationFor(FBase, MatchContextFor(User, FPeerAddress, FLocalPort));
end;

function TSystemAccountPolicy.PublicKeyAuthenticationAllowed(const User: string): Boolean;
begin
  Result := ConfigurationOf(User).PublicKeyAuthentication;
end;

function TSystemAccountPolicy.PasswordAuthenticationAllowed(const User: string): Boolean;
begin
  Result := ConfigurationOf(User).PasswordAuthentication;
end;

function TSystemAccountPolicy.KeyboardInteractiveAllowed(const User: string): Boolean;
begin
  Result := ConfigurationOf(User).KeyboardInteractiveAuthentication;
end;

function TSystemAccountPolicy.MayLogIn(const User: string): Boolean;
var
  Account: TLoginAccount;
  Check: TPasswordCheck;
begin
  Result := False;
  if not FindLoginAccount(User, Account) then
    Exit;
  if (Account.Identity.UserId = RootId) and not ConfigurationOf(User).PermitRootLogin then
    Exit;
  if Account.Shell = LockedShell then
    Exit;
  Check := CheckPassword(Account.Name, '');
  Result := (Check <> PasswordLocked) and (Check <> PasswordUnknownUser);
end;

function TSystemAccountPolicy.ReadLines(const Path: string; out Lines: TStringArray): Boolean;
var
  List: TStringList;
  Index: Integer;
begin
  Lines := nil;
  Result := False;
  if (Path = '') or not FileExists(Path) then
    Exit;
  List := TStringList.Create;
  try
    try
      List.LoadFromFile(Path);
    except
      on Error: Exception do
      begin
        Note('cannot read ' + Path + ': ' + Error.Message);
        Exit;
      end;
    end;
    SetLength(Lines, List.Count);
    for Index := 0 to List.Count - 1 do
      Lines[Index] := List[Index];
    Result := True;
  finally
    List.Free;
  end;
end;

function TSystemAccountPolicy.AuthorizedKeysPath(const User: string;
  const Configuration: TSshdConfiguration): string;
var
  Account: TLoginAccount;
begin
  Result := '';
  if FindLoginAccount(User, Account) then
    Result := ExpandAuthorizedKeysPath(Configuration.AuthorizedKeysFile, Account.Home, User);
end;

{ from= and expiry-time= of a line that names the key. }
function KeyOptionsHold(const Options: TSshKeyOptions; const PeerAddress, Where: string;
  Policy: TSystemAccountPolicy): Boolean;
begin
  Result := False;
  if (Options.FromPatterns <> '') and
    (MatchAddressList(PeerAddress, Options.FromPatterns) <> PatternListMatch) then
  begin
    Policy.Note(Where + ': from= does not match ' + PeerAddress);
    Exit;
  end;
  if (Options.ExpiryTime > 0) and (Int64(CurrentTime) >= Options.ExpiryTime) then
  begin
    Policy.Note(Where + ': the key has expired (expiry-time)');
    Exit;
  end;
  Result := True;
end;

function TSystemAccountPolicy.AuthorizePlainKey(const User, Blob: string; const Configuration: TSshdConfiguration;
  out Options: TSshKeyOptions): Boolean;
var
  Path, Problem, Where: string;
  Lines: TStringArray;
  Key: TSshAuthorizedKey;
  Index: Integer;
begin
  Result := False;
  Options := Default(TSshKeyOptions);
  Path := AuthorizedKeysPath(User, Configuration);
  if not ReadLines(Path, Lines) then
    Exit;
  for Index := 0 to High(Lines) do
  begin
    Where := Format('%s line %d', [Path, Index + 1]);
    if not ParseAuthorizedKeysLine(Lines[Index], Key, Problem) then
    begin
      if Problem <> '' then
        Note(Where + ': ' + Problem);
      Continue;
    end;
    if (Key.Blob <> Blob) or Key.Options.CertAuthority then
      Continue;
    if not KeyOptionsHold(Key.Options, FPeerAddress, Where, Self) then
      Continue;
    Options := Key.Options;
    Exit(True);
  end;
end;

{ The CA key blobs of TrustedUserCAKeys. }
function TrustedAuthorities(Policy: TSystemAccountPolicy; const Path: string): TStringArray;
var
  Lines: TStringArray;
  Index: Integer;
  Key: TSshAuthorizedKey;
  Problem: string;
begin
  Result := nil;
  if not Policy.ReadLines(Path, Lines) then
    Exit;
  for Index := 0 to High(Lines) do
    if ParseAuthorizedKeysLine(Lines[Index], Key, Problem) then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := Key.Blob;
    end;
end;

function TSystemAccountPolicy.AuthorizeCertificate(const User, Blob: string;
  const Configuration: TSshdConfiguration; out Options: TSshKeyOptions): Boolean;
var
  Certificate: TSshCertificate;
  Permissions: TSshCertificatePermissions;
  Problem, Path, Where: string;
  Trusted: Boolean;
  Lines: TStringArray;
  Key: TSshAuthorizedKey;
  Index: Integer;
  LineOptions: TSshKeyOptions;
begin
  Result := False;
  Options := Default(TSshKeyOptions);
  LineOptions := Default(TSshKeyOptions);
  if not ParseCertificate(Blob, Certificate) or not CertificateSignatureIsRight(Certificate) then
  begin
    Note('certificate for ' + User + ': malformed or not signed by its CA');
    Exit;
  end;
  Trusted := NameListContains(TrustedAuthorities(Self, Configuration.TrustedUserCaKeysPath),
    Certificate.SignatureKey);
  if not Trusted then
  begin
    { authorized_keys: cert-authority lines, with principals= standing
      for the user's name. }
    Path := AuthorizedKeysPath(User, Configuration);
    if ReadLines(Path, Lines) then
      for Index := 0 to High(Lines) do
      begin
        Where := Format('%s line %d', [Path, Index + 1]);
        if not ParseAuthorizedKeysLine(Lines[Index], Key, Problem) or not Key.Options.CertAuthority or
          (Key.Blob <> Certificate.SignatureKey) or not KeyOptionsHold(Key.Options, FPeerAddress, Where, Self) then
          Continue;
        if Key.Options.Principals <> '' then
        begin
          if not NameListContains(Certificate.Principals, User) and
            (MatchPatternList(User, Key.Options.Principals, True) <> PatternListMatch) then
            Continue;
        end;
        Trusted := True;
        LineOptions := Key.Options;
        Break;
      end;
  end;
  if not Trusted then
  begin
    Note('certificate ' + Certificate.KeyId + ' for ' + User + ': its CA is not trusted');
    Exit;
  end;
  if not CheckUserCertificate(Certificate, User, QWord(CurrentTime), Permissions, Problem) then
  begin
    Note('certificate ' + Certificate.KeyId + ' for ' + User + ': ' + Problem);
    Exit;
  end;
  if (Permissions.SourceAddress <> '') and
    (MatchAddressList(FPeerAddress, Permissions.SourceAddress) <> PatternListMatch) then
  begin
    Note('certificate ' + Certificate.KeyId + ': source-address does not allow ' + FPeerAddress);
    Exit;
  end;
  Options := LineOptions;
  Options.CertAuthority := False;
  if Permissions.ForceCommand <> '' then
    Options.Command := Permissions.ForceCommand;
  Options.NoPty := Options.NoPty or not Permissions.PermitPty;
  Options.NoPortForwarding := Options.NoPortForwarding or not Permissions.PermitPortForwarding;
  Options.NoAgentForwarding := Options.NoAgentForwarding or not Permissions.PermitAgentForwarding;
  Options.NoX11Forwarding := Options.NoX11Forwarding or not Permissions.PermitX11Forwarding;
  Options.NoUserRc := Options.NoUserRc or not Permissions.PermitUserRc;
  Note(Format('certificate %s (serial %d) accepted for %s', [Certificate.KeyId, Certificate.Serial, User]));
  Result := True;
end;

function TSystemAccountPolicy.AuthorizeKey(const User, Blob: string; out Options: TSshKeyOptions): Boolean;
var
  Configuration: TSshdConfiguration;
  Reader: TSshReader;
  KeyType: string;
begin
  Result := False;
  Options := Default(TSshKeyOptions);
  if not MayLogIn(User) then
    Exit;
  Configuration := ConfigurationOf(User);
  try
    Reader.Start(Blob);
    KeyType := Reader.ReadString;
  except
    on ESshProtocolError do
      Exit;
  end;
  if IsCertificateKeyType(KeyType) then
    Result := AuthorizeCertificate(User, Blob, Configuration, Options)
  else
    Result := AuthorizePlainKey(User, Blob, Configuration, Options);
end;

function TSystemAccountPolicy.PasswordIsRight(const User, Password: string): Boolean;
var
  Account: TLoginAccount;
begin
  Result := (Password <> '') and MayLogIn(User) and FindLoginAccount(User, Account) and
    Util.Logins.PasswordIsRight(Account, PChar(Password));
  if not Result then
    SleepMilliseconds(PauseAfterWrongPasswordMilliseconds);
end;

procedure TSystemAccountPolicy.Note(const Text: string);
begin
  LogLine(Text);
end;

end.
