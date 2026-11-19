{LICENSE}

{
  The SSH server's configuration, /etc/ssh/sshd_config: lines of a
  keyword and a value, as OpenSSH's (keywords in any case, # comments).

    Port 22
    PasswordAuthentication yes
    PubkeyAuthentication yes
    KbdInteractiveAuthentication yes          (a password prompt)
    PermitRootLogin yes
    HostKey /etc/ssh/ssh_host_ed25519_key      (one line per key)
    HostCertificate /etc/ssh/ssh_host_ed25519_key-cert.pub
    TrustedUserCAKeys /etc/ssh/user_ca.pub     (CA keys for user certificates)
    AuthorizedKeysFile .ssh/authorized_keys    (%h home, %u user, %% a %)
    Subsystem sftp /bin/sftp-server
    LoginGraceTime 120                          (seconds to log in)
    MaxSessions 8                               (channels per connection)
    AllowTcpForwarding yes                      (yes, all, local, remote, no)
    GatewayPorts no                             (no, yes, clientspecified)
    PermitOpen any                              (any, none, or host:port ...)
    AllowAgentForwarding yes
    PermitTTY yes
    PermitUserEnvironment no                    (authorized_keys environment=)
    ForceCommand COMMAND                        (runs whatever is asked)
    ClientAliveInterval 0                       (seconds; 0: no keep-alives)
    ClientAliveCountMax 3
    TCPKeepAlive yes

    Match User alice,bob Address 10.0.0.0/8     (the lines after it, up to
      AllowTcpForwarding no                      the next Match, for the
                                                 connections it matches)

  Match takes User, Group, Address and LocalPort (pattern lists, ! to
  refuse, CIDR for addresses; all of them must match) or All; only the
  keywords that can differ per connection may follow it. A missing file
  gives the defaults; an unknown keyword or a wrong value is reported
  and the line ignored.
}
unit Sshd.Configuration;

{$mode objfpc}{$H+}

interface

uses
  SysUtils,
  Classes;

const
  DefaultConfigurationPath = '/etc/ssh/sshd_config';
  DefaultEd25519HostKeyPath = '/etc/ssh/ssh_host_ed25519_key';
  DefaultEcdsaHostKeyPath = '/etc/ssh/ssh_host_ecdsa_key';
  DefaultSftpServerPath = '/bin/sftp-server';
  DefaultAuthorizedKeysFile = '.ssh/authorized_keys';

type
  TSshdForwarding = (ForwardingNone, ForwardingLocal, ForwardingRemote, ForwardingAll);
  TSshdGatewayPorts = (GatewayPortsNo, GatewayPortsYes, GatewayPortsClientSpecified);

  TSshdMatchKind = (MatchUser, MatchGroup, MatchAddress, MatchLocalPort, MatchAll);

  TSshdMatchCriterion = record
    Kind: TSshdMatchKind;
    Patterns: string;
  end;

  TSshdSettingLine = record
    Keyword: string;
    Value: string;
    LineNumber: Integer;
  end;

  TSshdMatchBlock = record
    Criteria: array of TSshdMatchCriterion;
    Lines: array of TSshdSettingLine;
  end;

  TSshdConfiguration = record
    Port: Word;
    PasswordAuthentication: Boolean;
    PublicKeyAuthentication: Boolean;
    KeyboardInteractiveAuthentication: Boolean;
    PermitRootLogin: Boolean;
    HostKeyPaths: TStringArray;
    HostCertificatePaths: TStringArray;
    TrustedUserCaKeysPath: string;
    AuthorizedKeysFile: string;
    SftpServerPath: string;
    LoginGraceSeconds: Integer;
    MaximumSessions: Integer;
    AllowTcpForwarding: TSshdForwarding;
    GatewayPorts: TSshdGatewayPorts;
    { Empty: any. }
    PermitOpen: TStringArray;
    PermitOpenNone: Boolean;
    AllowAgentForwarding: Boolean;
    PermitTty: Boolean;
    PermitUserEnvironment: Boolean;
    ForceCommand: string;
    ClientAliveInterval: Integer;
    ClientAliveCountMax: Integer;
    TcpKeepAlive: Boolean;
    MatchBlocks: array of TSshdMatchBlock;
  end;

  { What a connection is, for Match. }
  TSshdMatchContext = record
    User: string;
    UserKnown: Boolean;
    Groups: TStringArray;
    Address: string;
    LocalPort: Word;
  end;

function DefaultConfiguration: TSshdConfiguration;
{ Reads Path over the defaults; Problems gets a line for each wrong
  line. A missing file is no problem. }
function ReadConfiguration(const Path: string; out Problems: TStringArray): TSshdConfiguration;
{ The same from lines already read (Name is for the messages). }
function ParseConfigurationLines(Lines: TStrings; const Name: string; out Problems: TStringArray): TSshdConfiguration;
{ Base with the Match blocks that match Context applied. }
function ConfigurationFor(const Base: TSshdConfiguration; const Context: TSshdMatchContext): TSshdConfiguration;
function MatchBlockApplies(const Block: TSshdMatchBlock; const Context: TSshdMatchContext): Boolean;
{ %h, %u and %% of AuthorizedKeysFile; relative paths are under Home. }
function ExpandAuthorizedKeysPath(const Pattern, Home, User: string): string;

implementation

uses
  Ssh.AddressPatterns;

function DefaultConfiguration: TSshdConfiguration;
begin
  Result := Default(TSshdConfiguration);
  Result.Port := 22;
  Result.PasswordAuthentication := True;
  Result.PublicKeyAuthentication := True;
  Result.KeyboardInteractiveAuthentication := True;
  Result.PermitRootLogin := True;
  Result.HostKeyPaths := nil;
  Result.AuthorizedKeysFile := DefaultAuthorizedKeysFile;
  Result.SftpServerPath := DefaultSftpServerPath;
  Result.LoginGraceSeconds := 120;
  Result.MaximumSessions := 8;
  Result.AllowTcpForwarding := ForwardingAll;
  Result.GatewayPorts := GatewayPortsNo;
  Result.AllowAgentForwarding := True;
  Result.PermitTty := True;
  Result.ClientAliveInterval := 0;
  Result.ClientAliveCountMax := 3;
  Result.TcpKeepAlive := True;
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

function Words(const Text: string): TStringArray;
var
  Position, Start: Integer;
begin
  Result := nil;
  Position := 1;
  while Position <= Length(Text) do
  begin
    while (Position <= Length(Text)) and (Text[Position] in [' ', #9]) do
      Inc(Position);
    if Position > Length(Text) then
      Break;
    Start := Position;
    while (Position <= Length(Text)) and not (Text[Position] in [' ', #9]) do
      Inc(Position);
    AddText(Result, Copy(Text, Start, Position - Start));
  end;
end;

{ The keywords that may follow Match. }
function AllowedInMatch(const Keyword: string): Boolean;
const
  Allowed: array[0..15] of string = ('PasswordAuthentication', 'PubkeyAuthentication',
    'KbdInteractiveAuthentication', 'ChallengeResponseAuthentication', 'PermitRootLogin', 'AllowTcpForwarding',
    'GatewayPorts', 'PermitOpen', 'AllowAgentForwarding', 'PermitTTY', 'ForceCommand', 'ClientAliveInterval',
    'ClientAliveCountMax', 'MaxSessions', 'TrustedUserCAKeys', 'AuthorizedKeysFile');
var
  Index: Integer;
begin
  for Index := 0 to High(Allowed) do
    if SameText(Keyword, Allowed[Index]) then
      Exit(True);
  Result := SameText(Keyword, 'PermitUserEnvironment');
end;

{ One setting; False for a bad value, Known False for an unknown
  keyword. }
function ApplySetting(var Configuration: TSshdConfiguration; const Keyword, Value: string;
  out Known: Boolean): Boolean;
var
  Number, Space: Integer;
  Flag: Boolean;
  Name, Program_: string;
begin
  Known := True;
  Result := True;
  if SameText(Keyword, 'Port') then
  begin
    Result := ParseNumber(Value, 1, 65535, Number);
    if Result then
      Configuration.Port := Word(Number);
  end
  else if SameText(Keyword, 'PasswordAuthentication') then
  begin
    Result := ParseYesNo(Value, Flag);
    if Result then
      Configuration.PasswordAuthentication := Flag;
  end
  else if SameText(Keyword, 'PubkeyAuthentication') then
  begin
    Result := ParseYesNo(Value, Flag);
    if Result then
      Configuration.PublicKeyAuthentication := Flag;
  end
  else if SameText(Keyword, 'KbdInteractiveAuthentication') or
    SameText(Keyword, 'ChallengeResponseAuthentication') then
  begin
    Result := ParseYesNo(Value, Flag);
    if Result then
      Configuration.KeyboardInteractiveAuthentication := Flag;
  end
  else if SameText(Keyword, 'PermitRootLogin') then
  begin
    Result := ParseYesNo(Value, Flag);
    if Result then
      Configuration.PermitRootLogin := Flag;
  end
  else if SameText(Keyword, 'HostKey') then
  begin
    Result := (Value <> '') and (Value[1] = '/');
    if Result then
      AddText(Configuration.HostKeyPaths, Value);
  end
  else if SameText(Keyword, 'HostCertificate') then
  begin
    Result := (Value <> '') and (Value[1] = '/');
    if Result then
      AddText(Configuration.HostCertificatePaths, Value);
  end
  else if SameText(Keyword, 'TrustedUserCAKeys') then
  begin
    Result := (Value <> '') and ((Value[1] = '/') or SameText(Value, 'none'));
    if Result then
      if SameText(Value, 'none') then
        Configuration.TrustedUserCaKeysPath := ''
      else
        Configuration.TrustedUserCaKeysPath := Value;
  end
  else if SameText(Keyword, 'AuthorizedKeysFile') then
  begin
    Result := Value <> '';
    if Result then
      Configuration.AuthorizedKeysFile := Value;
  end
  else if SameText(Keyword, 'Subsystem') then
  begin
    Space := Pos(' ', Value);
    Name := Copy(Value, 1, Space - 1);
    Program_ := Trim(Copy(Value, Space + 1, MaxInt));
    Result := (Space > 0) and SameText(Name, 'sftp') and (Program_ <> '');
    if Result then
      Configuration.SftpServerPath := Program_;
  end
  else if SameText(Keyword, 'LoginGraceTime') then
  begin
    Result := ParseNumber(Value, 0, 3600, Number);
    if Result then
      Configuration.LoginGraceSeconds := Number;
  end
  else if SameText(Keyword, 'MaxSessions') then
  begin
    Result := ParseNumber(Value, 1, 16, Number);
    if Result then
      Configuration.MaximumSessions := Number;
  end
  else if SameText(Keyword, 'AllowTcpForwarding') then
  begin
    if SameText(Value, 'yes') or SameText(Value, 'all') then
      Configuration.AllowTcpForwarding := ForwardingAll
    else if SameText(Value, 'no') then
      Configuration.AllowTcpForwarding := ForwardingNone
    else if SameText(Value, 'local') then
      Configuration.AllowTcpForwarding := ForwardingLocal
    else if SameText(Value, 'remote') then
      Configuration.AllowTcpForwarding := ForwardingRemote
    else
      Result := False;
  end
  else if SameText(Keyword, 'GatewayPorts') then
  begin
    if SameText(Value, 'yes') then
      Configuration.GatewayPorts := GatewayPortsYes
    else if SameText(Value, 'no') then
      Configuration.GatewayPorts := GatewayPortsNo
    else if SameText(Value, 'clientspecified') then
      Configuration.GatewayPorts := GatewayPortsClientSpecified
    else
      Result := False;
  end
  else if SameText(Keyword, 'PermitOpen') then
  begin
    Configuration.PermitOpen := nil;
    Configuration.PermitOpenNone := False;
    if SameText(Value, 'none') then
      Configuration.PermitOpenNone := True
    else if not SameText(Value, 'any') then
      Configuration.PermitOpen := Words(Value);
    Result := Value <> '';
  end
  else if SameText(Keyword, 'AllowAgentForwarding') then
  begin
    Result := ParseYesNo(Value, Flag);
    if Result then
      Configuration.AllowAgentForwarding := Flag;
  end
  else if SameText(Keyword, 'PermitTTY') then
  begin
    Result := ParseYesNo(Value, Flag);
    if Result then
      Configuration.PermitTty := Flag;
  end
  else if SameText(Keyword, 'PermitUserEnvironment') then
  begin
    Result := ParseYesNo(Value, Flag);
    if Result then
      Configuration.PermitUserEnvironment := Flag;
  end
  else if SameText(Keyword, 'ForceCommand') then
  begin
    if SameText(Value, 'none') then
      Configuration.ForceCommand := ''
    else
      Configuration.ForceCommand := Value;
    Result := Value <> '';
  end
  else if SameText(Keyword, 'ClientAliveInterval') then
  begin
    Result := ParseNumber(Value, 0, 86400, Number);
    if Result then
      Configuration.ClientAliveInterval := Number;
  end
  else if SameText(Keyword, 'ClientAliveCountMax') then
  begin
    Result := ParseNumber(Value, 0, 1000, Number);
    if Result then
      Configuration.ClientAliveCountMax := Number;
  end
  else if SameText(Keyword, 'TCPKeepAlive') then
  begin
    Result := ParseYesNo(Value, Flag);
    if Result then
      Configuration.TcpKeepAlive := Flag;
  end
  else
  begin
    Known := False;
    Result := False;
  end;
end;

{ The criteria of a Match line; False with a problem for bad ones. }
function ParseMatchCriteria(const Value: string; out Block: TSshdMatchBlock; out Problem: string): Boolean;
var
  Parts: TStringArray;
  Index, Count, Port: Integer;
  Kind: TSshdMatchKind;
  Ports: TStringArray;
begin
  Block := Default(TSshdMatchBlock);
  Problem := '';
  Parts := Words(Value);
  if Length(Parts) = 0 then
  begin
    Problem := 'Match without criteria';
    Exit(False);
  end;
  Index := 0;
  while Index <= High(Parts) do
  begin
    if SameText(Parts[Index], 'All') then
    begin
      if Length(Parts) <> 1 then
      begin
        Problem := 'Match All goes alone';
        Exit(False);
      end;
      Kind := MatchAll;
    end
    else if SameText(Parts[Index], 'User') then
      Kind := MatchUser
    else if SameText(Parts[Index], 'Group') then
      Kind := MatchGroup
    else if SameText(Parts[Index], 'Address') then
      Kind := MatchAddress
    else if SameText(Parts[Index], 'LocalPort') then
      Kind := MatchLocalPort
    else
    begin
      Problem := 'unknown Match criterion ' + Parts[Index];
      Exit(False);
    end;
    Count := Length(Block.Criteria);
    SetLength(Block.Criteria, Count + 1);
    Block.Criteria[Count].Kind := Kind;
    if Kind <> MatchAll then
    begin
      if Index = High(Parts) then
      begin
        Problem := 'Match ' + Parts[Index] + ' without patterns';
        Exit(False);
      end;
      Inc(Index);
      Block.Criteria[Count].Patterns := Parts[Index];
      if Kind = MatchLocalPort then
      begin
        Ports := Parts[Index].Split([',']);
        for Port := 0 to High(Ports) do
          if not ParseNumber(Ports[Port], 1, 65535, Count) then
          begin
            Problem := 'bad LocalPort ' + Ports[Port];
            Exit(False);
          end;
      end;
    end;
    Inc(Index);
  end;
  Result := True;
end;

function ParseConfigurationLines(Lines: TStrings; const Name: string; out Problems: TStringArray): TSshdConfiguration;
var
  Index, Count: Integer;
  Keyword, Value, Problem: string;
  Valid, Known: Boolean;
  InMatch: Boolean;
  Block: TSshdMatchBlock;
begin
  Result := DefaultConfiguration;
  Problems := nil;
  InMatch := False;
  for Index := 0 to Lines.Count - 1 do
  begin
    SplitLine(Lines[Index], Keyword, Value);
    if (Keyword = '') or (Keyword[1] = '#') then
      Continue;
    if SameText(Keyword, 'Match') then
    begin
      if not ParseMatchCriteria(Value, Block, Problem) then
      begin
        AddText(Problems, Format('%s line %d: %s', [Name, Index + 1, Problem]));
        { The lines after a bad Match apply to no one. }
        Block := Default(TSshdMatchBlock);
        SetLength(Block.Criteria, 1);
        Block.Criteria[0].Kind := MatchUser;
        Block.Criteria[0].Patterns := '!*';
      end;
      SetLength(Result.MatchBlocks, Length(Result.MatchBlocks) + 1);
      Result.MatchBlocks[High(Result.MatchBlocks)] := Block;
      InMatch := True;
      Continue;
    end;
    if InMatch then
    begin
      if not AllowedInMatch(Keyword) then
      begin
        AddText(Problems, Format('%s line %d: %s cannot be in a Match block', [Name, Index + 1, Keyword]));
        Continue;
      end;
      { Checked now on a copy, applied for each connection it matches. }
      Block.Lines := nil;
      if not ApplySetting(DefaultConfiguration, Keyword, Value, Known) then
      begin
        AddText(Problems, Format('%s line %d: bad value for %s: %s', [Name, Index + 1, Keyword, Value]));
        Continue;
      end;
      with Result.MatchBlocks[High(Result.MatchBlocks)] do
      begin
        Count := Length(Lines);
        SetLength(Lines, Count + 1);
        Lines[Count].Keyword := Keyword;
        Lines[Count].Value := Value;
        Lines[Count].LineNumber := Index + 1;
      end;
      Continue;
    end;
    Valid := ApplySetting(Result, Keyword, Value, Known);
    if not Known then
      AddText(Problems, Format('%s line %d: unknown keyword %s', [Name, Index + 1, Keyword]))
    else if not Valid then
      AddText(Problems, Format('%s line %d: bad value for %s: %s', [Name, Index + 1, Keyword, Value]));
  end;
  if Length(Result.HostKeyPaths) = 0 then
  begin
    AddText(Result.HostKeyPaths, DefaultEd25519HostKeyPath);
    AddText(Result.HostKeyPaths, DefaultEcdsaHostKeyPath);
  end;
end;

function ReadConfiguration(const Path: string; out Problems: TStringArray): TSshdConfiguration;
var
  Lines: TStringList;
  ReadProblem: string;
begin
  ReadProblem := '';
  Lines := TStringList.Create;
  try
    if FileExists(Path) then
    begin
      try
        Lines.LoadFromFile(Path);
      except
        on Error: Exception do
          ReadProblem := Path + ': ' + Error.Message;
      end;
    end;
    Result := ParseConfigurationLines(Lines, Path, Problems);
  finally
    Lines.Free;
  end;
  if ReadProblem <> '' then
    AddText(Problems, ReadProblem);
end;

function CriterionApplies(const Criterion: TSshdMatchCriterion; const Context: TSshdMatchContext): Boolean;
var
  Index: Integer;
  Ports: TStringArray;
  Outcome: TPatternListResult;
begin
  case Criterion.Kind of
    MatchAll: Result := True;
    MatchUser:
      Result := Context.UserKnown and (MatchPatternList(Context.User, Criterion.Patterns, True) = PatternListMatch);
    MatchGroup:
      begin
        Result := False;
        if not Context.UserKnown then
          Exit;
        for Index := 0 to High(Context.Groups) do
        begin
          Outcome := MatchPatternList(Context.Groups[Index], Criterion.Patterns, True);
          if Outcome = PatternListRefused then
            Exit(False);
          if Outcome = PatternListMatch then
            Result := True;
        end;
      end;
    MatchAddress:
      Result := MatchAddressList(Context.Address, Criterion.Patterns) = PatternListMatch;
    MatchLocalPort:
      begin
        Result := False;
        Ports := Criterion.Patterns.Split([',']);
        for Index := 0 to High(Ports) do
          if Trim(Ports[Index]) = IntToStr(Context.LocalPort) then
            Exit(True);
      end;
  else
    Result := False;
  end;
end;

function MatchBlockApplies(const Block: TSshdMatchBlock; const Context: TSshdMatchContext): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to High(Block.Criteria) do
    if not CriterionApplies(Block.Criteria[Index], Context) then
      Exit(False);
  Result := Length(Block.Criteria) > 0;
end;

function ConfigurationFor(const Base: TSshdConfiguration; const Context: TSshdMatchContext): TSshdConfiguration;
var
  BlockIndex, LineIndex: Integer;
  Known: Boolean;
  Applied: array of string;

  function AlreadyApplied(const Keyword: string): Boolean;
  var
    Index: Integer;
  begin
    for Index := 0 to High(Applied) do
      if SameText(Applied[Index], Keyword) then
        Exit(True);
    Result := False;
  end;

begin
  Result := Base;
  Applied := nil;
  for BlockIndex := 0 to High(Base.MatchBlocks) do
    if MatchBlockApplies(Base.MatchBlocks[BlockIndex], Context) then
      for LineIndex := 0 to High(Base.MatchBlocks[BlockIndex].Lines) do
        with Base.MatchBlocks[BlockIndex].Lines[LineIndex] do
          { As in OpenSSH, the first value given for a keyword wins. }
          if not AlreadyApplied(Keyword) then
          begin
            ApplySetting(Result, Keyword, Value, Known);
            SetLength(Applied, Length(Applied) + 1);
            Applied[High(Applied)] := Keyword;
          end;
end;

function ExpandAuthorizedKeysPath(const Pattern, Home, User: string): string;
var
  Index: Integer;
begin
  Result := '';
  Index := 1;
  while Index <= Length(Pattern) do
  begin
    if (Pattern[Index] = '%') and (Index < Length(Pattern)) then
    begin
      Inc(Index);
      case Pattern[Index] of
        'h': Result := Result + Home;
        'u': Result := Result + User;
        '%': Result := Result + '%';
      else
        Result := Result + '%' + Pattern[Index];
      end;
    end
    else
      Result := Result + Pattern[Index];
    Inc(Index);
  end;
  if (Result = '') or (Result[1] <> '/') then
    Result := IncludeTrailingPathDelimiter(Home) + Result;
end;

end.
