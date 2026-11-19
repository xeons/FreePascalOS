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
  The ssh command line, as OpenSSH's:

    ssh [-AaNTtvq] [-p PORT] [-i FILE] [-l USER] [-o OPTION=VALUE]
        [-L [BIND:]PORT:HOST:HOSTPORT] [-R [BIND:]PORT:HOST:HOSTPORT]
        [-e CHAR] [USER@]HOST [COMMAND [ARGUMENT...]]

  Options stop at the destination: what follows is the command. -o takes
  Port, User, IdentityFile, IdentitiesOnly, StrictHostKeyChecking (yes,
  no, accept-new, ask), UserKnownHostsFile, KexAlgorithms, Ciphers,
  HostKeyAlgorithms, BatchMode, PasswordAuthentication,
  PubkeyAuthentication, KbdInteractiveAuthentication, ForwardAgent,
  RequestTTY, EscapeChar and LogLevel; others are accepted and not used
  (ConnectTimeout, ServerAliveInterval, ...).
}
unit SshClient.Options;

{$mode objfpc}{$H+}

interface

uses
  SysUtils;

type
  THostKeyChecking = (HostKeyCheckingAsk, HostKeyCheckingYes, HostKeyCheckingNo, HostKeyCheckingAcceptNew);
  TTerminalRequest = (TerminalAuto, TerminalYes, TerminalForce, TerminalNo);

  TForwardSpecification = record
    BindHost: string;
    Port: Word;
    TargetHost: string;
    TargetPort: Word;
  end;

  TSshClientOptions = record
    Host: string;
    Port: Word;
    User: string;
    Command: string;
    IdentityFiles: TStringArray;
    IdentitiesOnly: Boolean;
    HostKeyChecking: THostKeyChecking;
    KnownHostsFile: string;
    KeyExchanges: TStringArray;
    Ciphers: TStringArray;
    HostKeyAlgorithms: TStringArray;
    BatchMode: Boolean;
    PasswordAuthentication: Boolean;
    PublicKeyAuthentication: Boolean;
    KeyboardInteractive: Boolean;
    ForwardAgent: Boolean;
    Terminal: TTerminalRequest;
    NoCommand: Boolean;
    EscapeCharacter: Integer;
    Verbose: Integer;
    Quiet: Boolean;
    LocalForwards: array of TForwardSpecification;
    RemoteForwards: array of TForwardSpecification;
  end;

{ Parses the arguments; Problem says what is wrong when False. }
function ParseClientOptions(const Arguments: TStringArray; out Options: TSshClientOptions;
  out Problem: string): Boolean;
function ParseForwardSpecification(const Text: string; out Specification: TForwardSpecification): Boolean;

implementation

uses
  Ssh.Algorithms,
  Ssh.CipherSuites,
  Ssh.ClientTransport;

const
  NoEscapeCharacter = -1;

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

function ParsePort(const Text: string; out Port: Word): Boolean;
var
  Number: Integer;
begin
  Result := TryStrToInt(Text, Number) and (Number >= 0) and (Number <= 65535);
  if Result then
    Port := Word(Number)
  else
    Port := 0;
end;

{ Splits on colons outside [brackets]. }
function SplitColons(const Text: string): TStringArray;
var
  Index, Start: Integer;
  InBrackets: Boolean;

  procedure Take(Finish: Integer);
  var
    Part: string;
  begin
    Part := Copy(Text, Start, Finish - Start);
    if (Part <> '') and (Part[1] = '[') and (Part[Length(Part)] = ']') then
      Part := Copy(Part, 2, Length(Part) - 2);
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := Part;
  end;

begin
  Result := nil;
  Start := 1;
  InBrackets := False;
  for Index := 1 to Length(Text) do
    if Text[Index] = '[' then
      InBrackets := True
    else if Text[Index] = ']' then
      InBrackets := False
    else if (Text[Index] = ':') and not InBrackets then
    begin
      Take(Index);
      Start := Index + 1;
    end;
  Take(Length(Text) + 1);
end;

function ParseForwardSpecification(const Text: string; out Specification: TForwardSpecification): Boolean;
var
  Parts: TStringArray;
begin
  Specification := Default(TForwardSpecification);
  Parts := SplitColons(Text);
  Result := False;
  case Length(Parts) of
    3:
      Result := ParsePort(Parts[0], Specification.Port) and ParsePort(Parts[2], Specification.TargetPort);
    4:
      begin
        Specification.BindHost := Parts[0];
        Result := ParsePort(Parts[1], Specification.Port) and ParsePort(Parts[3], Specification.TargetPort);
      end;
  end;
  if not Result then
    Exit;
  Specification.TargetHost := Parts[High(Parts) - 1];
  Result := (Specification.TargetHost <> '') and (Specification.TargetPort <> 0);
end;

procedure AddText(var Texts: TStringArray; const Text: string);
begin
  SetLength(Texts, Length(Texts) + 1);
  Texts[High(Texts)] := Text;
end;

function ExpandHome(const Path: string): string;
begin
  if Copy(Path, 1, 2) = '~/' then
    Result := IncludeTrailingPathDelimiter(GetEnvironmentVariable('HOME')) + Copy(Path, 3, MaxInt)
  else
    Result := Path;
end;

function ApplyOption(var Options: TSshClientOptions; const Text: string; out Problem: string): Boolean;
var
  Separator: Integer;
  Name, Value: string;

  Port: Word;
  Specification: TForwardSpecification;
begin
  Problem := '';
  Result := True;
  Separator := 1;
  while (Separator <= Length(Text)) and not (Text[Separator] in ['=', ' ', #9]) do
    Inc(Separator);
  Name := Copy(Text, 1, Separator - 1);
  Value := Trim(Copy(Text, Separator + 1, MaxInt));
  if SameText(Name, 'Port') then
  begin
    Result := ParsePort(Value, Port) and (Port > 0);
    Options.Port := Port;
  end
  else if SameText(Name, 'User') then
    Options.User := Value
  else if SameText(Name, 'IdentityFile') then
    AddText(Options.IdentityFiles, ExpandHome(Value))
  else if SameText(Name, 'IdentitiesOnly') then
    Result := ParseYesNo(Value, Options.IdentitiesOnly)
  else if SameText(Name, 'StrictHostKeyChecking') then
  begin
    if SameText(Value, 'yes') then
      Options.HostKeyChecking := HostKeyCheckingYes
    else if SameText(Value, 'no') or SameText(Value, 'off') then
      Options.HostKeyChecking := HostKeyCheckingNo
    else if SameText(Value, 'accept-new') then
      Options.HostKeyChecking := HostKeyCheckingAcceptNew
    else if SameText(Value, 'ask') then
      Options.HostKeyChecking := HostKeyCheckingAsk
    else
      Result := False;
  end
  else if SameText(Name, 'UserKnownHostsFile') then
    Options.KnownHostsFile := ExpandHome(Value)
  else if SameText(Name, 'KexAlgorithms') then
    Options.KeyExchanges := Value.Split([','])
  else if SameText(Name, 'Ciphers') then
    Options.Ciphers := Value.Split([','])
  else if SameText(Name, 'HostKeyAlgorithms') then
    Options.HostKeyAlgorithms := Value.Split([','])
  else if SameText(Name, 'BatchMode') then
    Result := ParseYesNo(Value, Options.BatchMode)
  else if SameText(Name, 'PasswordAuthentication') then
    Result := ParseYesNo(Value, Options.PasswordAuthentication)
  else if SameText(Name, 'PubkeyAuthentication') then
    Result := ParseYesNo(Value, Options.PublicKeyAuthentication)
  else if SameText(Name, 'KbdInteractiveAuthentication') then
    Result := ParseYesNo(Value, Options.KeyboardInteractive)
  else if SameText(Name, 'ForwardAgent') then
    Result := ParseYesNo(Value, Options.ForwardAgent)
  else if SameText(Name, 'RequestTTY') then
  begin
    if SameText(Value, 'yes') then
      Options.Terminal := TerminalYes
    else if SameText(Value, 'force') then
      Options.Terminal := TerminalForce
    else if SameText(Value, 'no') then
      Options.Terminal := TerminalNo
    else if SameText(Value, 'auto') then
      Options.Terminal := TerminalAuto
    else
      Result := False;
  end
  else if SameText(Name, 'EscapeChar') then
  begin
    if SameText(Value, 'none') then
      Options.EscapeCharacter := NoEscapeCharacter
    else if Length(Value) = 1 then
      Options.EscapeCharacter := Ord(Value[1])
    else
      Result := False;
  end
  else if SameText(Name, 'LogLevel') then
  begin
    if SameText(Value, 'QUIET') or SameText(Value, 'ERROR') or SameText(Value, 'FATAL') then
      Options.Quiet := True
    else if Copy(UpperCase(Value), 1, 5) = 'DEBUG' then
      Options.Verbose := 1;
  end
  else if SameText(Name, 'LocalForward') or SameText(Name, 'RemoteForward') then
  begin
    Result := ParseForwardSpecification(StringReplace(Value, ' ', ':', [rfReplaceAll]), Specification);
    if Result and SameText(Name, 'LocalForward') then
    begin
      SetLength(Options.LocalForwards, Length(Options.LocalForwards) + 1);
      Options.LocalForwards[High(Options.LocalForwards)] := Specification;
    end
    else if Result then
    begin
      SetLength(Options.RemoteForwards, Length(Options.RemoteForwards) + 1);
      Options.RemoteForwards[High(Options.RemoteForwards)] := Specification;
    end;
  end;
  if not Result then
    Problem := 'bad value for ' + Name + ': ' + Value;
end;

procedure SetDefaults(out Options: TSshClientOptions);
begin
  Options := Default(TSshClientOptions);
  Options.Port := 22;
  Options.PasswordAuthentication := True;
  Options.PublicKeyAuthentication := True;
  Options.KeyboardInteractive := True;
  Options.EscapeCharacter := Ord('~');
  Options.KnownHostsFile := IncludeTrailingPathDelimiter(GetEnvironmentVariable('HOME')) + '.ssh/known_hosts';
  Options.KeyExchanges := ToStringArray(SupportedKeyExchanges);
  Options.Ciphers := ToStringArray(SupportedCiphers);
  Options.HostKeyAlgorithms := ToStringArray(ClientHostKeyAlgorithms);
end;

function ParseClientOptions(const Arguments: TStringArray; out Options: TSshClientOptions;
  out Problem: string): Boolean;
var
  Index, Position: Integer;
  Argument, Value, Destination: string;
  Letter: Char;
  Specification: TForwardSpecification;
  At: Integer;
  Port: Word;

  function TakeValue: Boolean;
  begin
    if Position < Length(Argument) then
    begin
      Value := Copy(Argument, Position + 1, MaxInt);
      Position := Length(Argument);
      Exit(True);
    end;
    Inc(Index);
    if Index > High(Arguments) then
    begin
      Problem := 'option -' + Letter + ' needs a value';
      Exit(False);
    end;
    Value := Arguments[Index];
    Result := True;
  end;

begin
  SetDefaults(Options);
  Problem := '';
  Result := False;
  Destination := '';
  Index := 0;
  while Index <= High(Arguments) do
  begin
    Argument := Arguments[Index];
    if (Argument = '') or (Argument[1] <> '-') or (Argument = '-') then
    begin
      Destination := Argument;
      Inc(Index);
      Break;
    end;
    Position := 2;
    while Position <= Length(Argument) do
    begin
      Letter := Argument[Position];
      case Letter of
        'A': Options.ForwardAgent := True;
        'a': Options.ForwardAgent := False;
        'N': Options.NoCommand := True;
        'T': Options.Terminal := TerminalNo;
        't':
          if Options.Terminal = TerminalYes then
            Options.Terminal := TerminalForce
          else
            Options.Terminal := TerminalYes;
        'v': Inc(Options.Verbose);
        'q': Options.Quiet := True;
        '4', '6', 'C', 'x', 'X', 'n', 'f':
          ;
        'p', 'i', 'l', 'o', 'L', 'R', 'e', 'F':
          begin
            if not TakeValue then
              Exit;
            case Letter of
              'p':
                if not ParsePort(Value, Port) or (Port = 0) then
                begin
                  Problem := 'bad port ' + Value;
                  Exit;
                end
                else
                  Options.Port := Port;
              'i': AddText(Options.IdentityFiles, ExpandHome(Value));
              'l': Options.User := Value;
              'o':
                if not ApplyOption(Options, Value, Problem) then
                  Exit;
              'L', 'R':
                begin
                  if not ParseForwardSpecification(Value, Specification) then
                  begin
                    Problem := 'bad forwarding specification ' + Value;
                    Exit;
                  end;
                  if Letter = 'L' then
                  begin
                    SetLength(Options.LocalForwards, Length(Options.LocalForwards) + 1);
                    Options.LocalForwards[High(Options.LocalForwards)] := Specification;
                  end
                  else
                  begin
                    SetLength(Options.RemoteForwards, Length(Options.RemoteForwards) + 1);
                    Options.RemoteForwards[High(Options.RemoteForwards)] := Specification;
                  end;
                end;
              'e':
                if not ApplyOption(Options, 'EscapeChar=' + Value, Problem) then
                  Exit;
              'F': ;
            end;
            Break;
          end;
      else
        Problem := 'unknown option -' + Letter;
        Exit;
      end;
      Inc(Position);
    end;
    Inc(Index);
  end;
  if Destination = '' then
  begin
    Problem := 'no destination';
    Exit;
  end;
  At := LastDelimiter('@', Destination);
  if At > 0 then
  begin
    Options.User := Copy(Destination, 1, At - 1);
    Options.Host := Copy(Destination, At + 1, MaxInt);
  end
  else
    Options.Host := Destination;
  if Copy(Options.Host, 1, 6) = 'ssh://' then
    Options.Host := Copy(Options.Host, 7, MaxInt);
  while Index <= High(Arguments) do
  begin
    if Options.Command <> '' then
      Options.Command := Options.Command + ' ';
    Options.Command := Options.Command + Arguments[Index];
    Inc(Index);
  end;
  if Options.User = '' then
    Options.User := GetEnvironmentVariable('USER');
  Result := Options.Host <> '';
  if not Result then
    Problem := 'no host';
end;

end.
