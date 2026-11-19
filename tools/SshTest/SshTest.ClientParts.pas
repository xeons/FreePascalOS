{LICENSE}

{
  The pieces added with the client and the server's new features:
  the mlkem768x25519-sha256 exchange (against Python and OpenSSL), the
  authorized_keys option parser, OpenSSH certificates made by
  ssh-keygen -s, address pattern lists, known_hosts (a hashed name
  too), sshd_config Match blocks, and the agent protocol's framing
  (SshTest.ClientVectors.inc is made by make-client-vectors.py).
}
unit SshTest.ClientParts;

{$mode objfpc}
{$H+}

interface

procedure TestHybridKeyExchange;
procedure TestAuthorizedKeyOptions;
procedure TestCertificates;
procedure TestAddressPatterns;
procedure TestKnownHosts;
procedure TestMatchBlocks;
procedure TestAgentFraming;

implementation

uses
  SysUtils,
  Classes,
  TestChecks,
  SshTest.Helpers,
  Crypto.MlKem,
  Ssh.Wire,
  Ssh.Base64,
  Ssh.KeyExchange,
  Ssh.KeyExchangeMethods,
  Ssh.PublicKeys,
  Ssh.AuthorizedKeys,
  Ssh.Certificates,
  Ssh.AddressPatterns,
  Ssh.KnownHosts,
  Ssh.AgentProtocol,
  Ssh.UserAuthentication,
  Sshd.Configuration;

{$I SshTest.ClientVectors.inc}

procedure TestHybridKeyExchange;
var
  Secret: TSshClientExchangeSecret;
  EncapsulationKey, Encoded, Hash, ServerValue, ServerSecret, Changed: string;
  Method: TSshKeyExchangeMethod;
begin
  Check(FindKeyExchangeMethod('mlkem768x25519-sha256', Method) and (Method = KeyExchangeMethodMlKem768X25519),
    'mlkem768x25519-sha256 is a known method');
  Secret := Default(TSshClientExchangeSecret);
  Secret.Method := KeyExchangeMethodMlKem768X25519;
  Secret.X25519.PrivateKey := FromHex(HybridClientX25519);
  EncapsulationKey := StringOfChar(#0, MlKem768EncapsulationKeySize);
  Secret.MlKemDecapsulationKey := StringOfChar(#0, MlKem768DecapsulationKeySize);
  MlKem768KeyPairFromSeed(@FromHex(HybridMlKemSeed)[1], @EncapsulationKey[1], @Secret.MlKemDecapsulationKey[1]);
  CheckEqual(Copy(FromHex(HybridClientInit), 1, MlKem768EncapsulationKeySize), EncapsulationKey,
    'mlkem768x25519: the client''s ML-KEM key from its seed');
  Check(FinishClientExchange(Secret, FromHex(HybridServerReply), Encoded), 'mlkem768x25519: the server''s reply taken');
  CheckEqual(Encoded, FromHex(HybridEncodedSecret), 'mlkem768x25519: K = SHA-256(ML-KEM secret || X25519 secret) as a string');
  Hash := ExchangeHashOf(KeyExchangeMethodMlKem768X25519, 'SSH-2.0-OpenSSH_9.9', 'SSH-2.0-FreePascalOS_1.0',
    FromHex(HybridClientKexInit), FromHex(HybridServerKexInit), FromHex(HybridHostBlob), FromHex(HybridClientInit),
    FromHex(HybridServerReply), Encoded);
  CheckEqual(Hash, FromHex(HybridExchangeHash), 'mlkem768x25519-sha256: exchange hash H');
  CheckEqual(DeriveExchangeKey(KeyExchangeMethodMlKem768X25519, Encoded, Hash, Hash, 'C', 64),
    FromHex(HybridDerivedKeyC), 'mlkem768x25519-sha256: key C from K as a string');
  { The server's side against the same client value, and the client's. }
  Check(AnswerClientExchange(KeyExchangeMethodMlKem768X25519, FromHex(HybridClientInit), ServerValue, ServerSecret),
    'mlkem768x25519: the server answers a client value');
  Check((Length(ServerValue) = 1088 + 32) and FinishClientExchange(Secret, ServerValue, Encoded) and
    (Encoded = ServerSecret), 'mlkem768x25519: both sides get the same K');
  Check(not AnswerClientExchange(KeyExchangeMethodMlKem768X25519, Copy(FromHex(HybridClientInit), 1, 1000),
    ServerValue, ServerSecret), 'mlkem768x25519: a short client value refused');
  Changed := FromHex(HybridClientInit);
  Changed[1] := #$FF;
  Changed[2] := Chr(Ord(Changed[2]) or $0F);
  Check(not AnswerClientExchange(KeyExchangeMethodMlKem768X25519, Changed, ServerValue, ServerSecret),
    'mlkem768x25519: a client key failing the modulus check refused');
  WipeClientExchangeSecret(Secret);
end;

procedure TestAuthorizedKeyOptions;
var
  Key: TSshAuthorizedKey;
  Options: TSshKeyOptions;
  Problem, Line, KeyText: string;
  Time: Int64;
begin
  KeyText := 'ssh-ed25519 ' + EncodeBase64(FromHex(UserKeyEd25519));
  Line := 'command="echo \"hi\" there",from="10.0.0.0/8,!10.1.2.3",no-pty,permitopen="localhost:80",' +
    'permitopen="[::1]:*",environment="FOO=bar baz",expiry-time="20300102" ' + KeyText + ' a comment';
  Check(ParseAuthorizedKeysLine(Line, Key, Problem), 'authorized_keys: a line with options read (' + Problem + ')');
  Check(Key.Options.Command = 'echo "hi" there', 'authorized_keys: command= with \" inside');
  Check(Key.Options.FromPatterns = '10.0.0.0/8,!10.1.2.3', 'authorized_keys: from=');
  Check(Key.Options.NoPty and not Key.Options.NoPortForwarding, 'authorized_keys: no-pty alone');
  Check((Length(Key.Options.PermitOpen) = 2) and PermitOpenAllows(Key.Options.PermitOpen, 'localhost', 80) and
    not PermitOpenAllows(Key.Options.PermitOpen, 'localhost', 81) and PermitOpenAllows(Key.Options.PermitOpen, '::1', 22),
    'authorized_keys: permitopen= entries');
  Check((Length(Key.Options.Environment) = 1) and (Key.Options.Environment[0] = 'FOO=bar baz'),
    'authorized_keys: environment=');
  Check(ParseExpiryTime('20300102', Time) and (Key.Options.ExpiryTime = Time) and (Time = 1893542400),
    'authorized_keys: expiry-time= as Unix time');
  Check(Key.Comment = 'a comment', 'authorized_keys: the comment kept');
  Check(ParseKeyOptions('restrict,pty', Options, Problem) and not Options.NoPty and Options.NoPortForwarding and
    Options.NoAgentForwarding and Options.NoX11Forwarding, 'authorized_keys: restrict, pty given back');
  Check(ParseKeyOptions('NO-AGENT-FORWARDING,No-X11-Forwarding', Options, Problem) and Options.NoAgentForwarding and
    Options.NoX11Forwarding, 'authorized_keys: option names in any case');
  Check(not ParseKeyOptions('frobnicate', Options, Problem), 'authorized_keys: an unknown option refuses the line');
  Check(not ParseKeyOptions('command=unquoted', Options, Problem), 'authorized_keys: an unquoted value refused');
  Check(not ParseKeyOptions('command="open', Options, Problem), 'authorized_keys: an unclosed quote refused');
  Check(not ParseKeyOptions('expiry-time="2030"', Options, Problem), 'authorized_keys: a bad expiry-time refused');
  Check(not ParseAuthorizedKeysLine('bogus ' + KeyText, Key, Problem) and (Problem <> ''),
    'authorized_keys: a line with a bad option refused with a reason');
  Check(ParseAuthorizedKeysLine('cert-authority,principals="tester" ssh-ed25519 ' +
    EncodeBase64(FromHex(CertificateAuthorityBlob)), Key, Problem) and Key.Options.CertAuthority and
    (Key.Options.Principals = 'tester'), 'authorized_keys: cert-authority with principals=');
  Check(ParseAuthorizedKeysLine('ssh-ed25519-cert-v01@openssh.com ' + EncodeBase64(FromHex(UserCertificateEd25519)),
    Key, Problem), 'authorized_keys: a certificate line read');
  Check(not ParseAuthorizedKeysLine('   # comment', Key, Problem) and (Problem = ''), 'authorized_keys: comment skipped');
  Check(DaysFromCivil(1970, 1, 1) = 0, 'days from 1970-01-01');
end;

procedure CheckUserCertificateOf(const Name, Blob, KeyBlob: string);
var
  Certificate: TSshCertificate;
  Permissions: TSshCertificatePermissions;
  Problem: string;
begin
  Check(ParseCertificate(FromHex(Blob), Certificate), Name + ' certificate parsed');
  Check(Certificate.Key.Blob = FromHex(KeyBlob), Name + ' certificate: its key');
  Check((Certificate.CertificateType = CertificateTypeUser) and (Certificate.Serial = 7) and
    (Certificate.KeyId = 'id-' + LowerCase(Name)), Name + ' certificate: type, serial and key id');
  Check((Length(Certificate.Principals) = 2) and (Certificate.Principals[0] = 'tester'),
    Name + ' certificate: principals');
  Check(Certificate.SignatureKey = FromHex(CertificateAuthorityBlob), Name + ' certificate: signed by the CA');
  Check(CertificateSignatureIsRight(Certificate), Name + ' certificate: the CA''s signature is right');
  Check(CheckUserCertificate(Certificate, 'tester', CertificateCheckTime, Permissions, Problem),
    Name + ' certificate: valid for tester now (' + Problem + ')');
  Check((Permissions.ForceCommand = '/bin/echo forced') and (Permissions.SourceAddress = '10.0.0.0/8,::1') and
    Permissions.PermitPty and Permissions.PermitPortForwarding and Permissions.PermitAgentForwarding,
    Name + ' certificate: force-command, source-address and the default extensions');
  Check(not CheckUserCertificate(Certificate, 'mallory', CertificateCheckTime, Permissions, Problem),
    Name + ' certificate: refused for a user it does not list');
  Check(not CheckUserCertificate(Certificate, 'tester', 4102444800 + 86400, Permissions, Problem),
    Name + ' certificate: refused after its validity');
end;

procedure TestCertificates;
var
  Certificate: TSshCertificate;
  Permissions: TSshCertificatePermissions;
  Problem, Blob: string;
begin
  CheckUserCertificateOf('Ed25519', UserCertificateEd25519, UserKeyEd25519);
  CheckUserCertificateOf('Ecdsa', UserCertificateEcdsa, UserKeyEcdsa);
  CheckUserCertificateOf('Rsa', UserCertificateRsa, UserKeyRsa);
  Check(ParseCertificate(FromHex(BareCertificate), Certificate) and
    CheckUserCertificate(Certificate, 'tester', CertificateCheckTime, Permissions, Problem) and
    not Permissions.PermitPty and not Permissions.PermitPortForwarding and not Permissions.PermitAgentForwarding,
    'a certificate without extensions allows no pty, forwarding or agent');
  Check(ParseCertificate(FromHex(ExpiredCertificate), Certificate) and
    not CheckUserCertificate(Certificate, 'tester', CertificateCheckTime, Permissions, Problem),
    'an expired certificate refused');
  Check(ParseCertificate(FromHex(HostCertificate), Certificate) and
    (Certificate.CertificateType = CertificateTypeHost) and (Certificate.Key.Blob = FromHex(HostCertifiedKey)) and
    CertificateSignatureIsRight(Certificate) and
    not CheckUserCertificate(Certificate, 'fpos.example', CertificateCheckTime, Permissions, Problem),
    'a host certificate parsed, and refused as a user certificate');
  Blob := FromHex(UserCertificateEd25519);
  Blob[Length(Blob) - 5] := Chr(Ord(Blob[Length(Blob) - 5]) xor 1);
  Check(ParseCertificate(Blob, Certificate) and not CertificateSignatureIsRight(Certificate),
    'a certificate with a changed signature refused');
  Check(PublicKeySignatureIsRight(FromHex(UserCertificateEd25519), 'ssh-ed25519-cert-v01@openssh.com',
    FromHex(CertificateSignedData), FromHex(CertificateSignature)),
    'publickey with a certificate: the signature checked with its key');
  Check(not PublicKeySignatureIsRight(FromHex(UserCertificateEd25519), 'ssh-ed25519',
    FromHex(CertificateSignedData), FromHex(CertificateSignature)),
    'publickey with a certificate: the plain algorithm name refused');
  Check(PlainSignatureAlgorithm(CertificateRsa, 'rsa-sha2-512-cert-v01@openssh.com') = 'rsa-sha2-512',
    'rsa-sha2-512-cert-v01 signs with rsa-sha2-512');
  Check(PlainSignatureAlgorithm(CertificateRsa, 'ssh-rsa-cert-v01@openssh.com') = '',
    'ssh-rsa-cert-v01 (SHA-1) refused');
end;

procedure TestAddressPatterns;
begin
  Check(MatchWildcard('alice', 'a*e', True) and MatchWildcard('alice', 'al?ce', True) and
    not MatchWildcard('alice', 'b*', True), 'patterns: * and ?');
  Check(MatchPatternList('bob', 'alice,b*', True) = PatternListMatch, 'pattern list: a match');
  Check(MatchPatternList('bob', 'b*,!bob', True) = PatternListRefused, 'pattern list: a negation refuses');
  Check(MatchPatternList('carol', 'alice,bob', True) = PatternListNoMatch, 'pattern list: no match');
  Check(MatchAddressList('10.1.2.3', '10.0.0.0/8') = PatternListMatch, 'addresses: IPv4 CIDR');
  Check(MatchAddressList('11.1.2.3', '10.0.0.0/8') = PatternListNoMatch, 'addresses: outside the block');
  Check(MatchAddressList('10.1.2.3', '10.0.0.0/8,!10.1.2.3') = PatternListRefused, 'addresses: a negated address');
  Check(MatchAddressList('192.168.1.7', '192.168.1.*') = PatternListMatch, 'addresses: a wildcard');
  Check(MatchAddressList('fe80::1:2', 'fe80::/64') = PatternListMatch, 'addresses: IPv6 CIDR');
  Check(MatchAddressList('::1', '::1') = PatternListMatch, 'addresses: IPv6 loopback');
  Check(MatchAddressList('::ffff:10.0.0.5', '10.0.0.0/24') = PatternListMatch,
    'addresses: an IPv4 mapped address matched as IPv4');
  Check(MatchAddressList('2001:db8::1', '10.0.0.0/8') = PatternListNoMatch, 'addresses: families do not mix');
  Check(IsAddressList('10.0.0.0/8,::1') and not IsAddressList('10.*'), 'source-address lists');
end;

procedure TestKnownHosts;
var
  Lines: TStringArray;
  Blob, Other: string;
begin
  Blob := FromHex(HostCertifiedKey);
  Other := FromHex(UserKeyEd25519);
  Lines := TStringArray.Create('# comment', 'fpos,10.0.0.9 ' + PublicKeyLine(Blob, 'x'),
    '[fpos]:2222 ' + PublicKeyLine(Other, ''), HashedKnownHostsLine);
  Check(LookupKnownHost(Lines, 'fpos', 22, Blob) = KnownHostMatches, 'known_hosts: a name of the list');
  Check(LookupKnownHost(Lines, '10.0.0.9', 22, Blob) = KnownHostMatches, 'known_hosts: an address of the list');
  Check(LookupKnownHost(Lines, 'fpos', 22, Other) = KnownHostDiffers, 'known_hosts: another key for the host');
  Check(LookupKnownHost(Lines, 'fpos', 2222, Other) = KnownHostMatches, 'known_hosts: [host]:port');
  Check(LookupKnownHost(Lines, 'elsewhere', 22, Blob) = KnownHostUnknown, 'known_hosts: an unknown host');
  Check(LookupKnownHost(Lines, 'fpos.example', 2222, Blob) = KnownHostMatches, 'known_hosts: a hashed name');
  Check(KnownHostLine('Fpos', 2222, Blob) = '[fpos]:2222 ' + PublicKeyLine(Blob, ''), 'known_hosts: a new line');
  SetLength(Lines, Length(Lines) + 1);
  Lines[High(Lines)] := '@revoked * ' + PublicKeyLine(Blob, '');
  Check(LookupKnownHost(Lines, 'fpos', 22, Blob) = KnownHostRevoked, 'known_hosts: a revoked key');
end;

procedure TestMatchBlocks;
var
  Lines: TStringList;
  Problems: TStringArray;
  Base, Effective: TSshdConfiguration;
  Context: TSshdMatchContext;
begin
  Lines := TStringList.Create;
  try
    Lines.Add('PasswordAuthentication yes');
    Lines.Add('AllowTcpForwarding yes');
    Lines.Add('ClientAliveInterval 30');
    Lines.Add('Match User alice,bob Address 10.0.0.0/8');
    Lines.Add('  PasswordAuthentication no');
    Lines.Add('  AllowTcpForwarding local');
    Lines.Add('Match Group admins');
    Lines.Add('  PermitTTY no');
    Lines.Add('  AllowTcpForwarding no');
    Lines.Add('Match LocalPort 2222');
    Lines.Add('  ForceCommand /bin/date');
    Lines.Add('  Port 99');
    Lines.Add('Match Frobnicate x');
    Lines.Add('  PermitTTY no');
    Base := ParseConfigurationLines(Lines, 'test', Problems);
  finally
    Lines.Free;
  end;
  Check((Length(Base.MatchBlocks) = 4) and (Length(Problems) = 2), 'Match: blocks read, a bad keyword and criterion reported');
  Check((Base.ClientAliveInterval = 30) and Base.PasswordAuthentication, 'Match: the global settings');
  Context := Default(TSshdMatchContext);
  Context.User := 'alice';
  Context.UserKnown := True;
  Context.Address := '10.4.4.4';
  Context.LocalPort := 22;
  Effective := ConfigurationFor(Base, Context);
  Check(not Effective.PasswordAuthentication and (Effective.AllowTcpForwarding = ForwardingLocal) and
    Effective.PermitTty, 'Match User and Address: applied');
  Context.Address := '192.168.0.1';
  Effective := ConfigurationFor(Base, Context);
  Check(Effective.PasswordAuthentication and (Effective.AllowTcpForwarding = ForwardingAll),
    'Match: an address outside leaves the defaults');
  Context.Groups := TStringArray.Create('users', 'admins');
  Context.Address := '10.4.4.4';
  Effective := ConfigurationFor(Base, Context);
  Check((Effective.AllowTcpForwarding = ForwardingLocal) and not Effective.PermitTty,
    'Match: the first value of a keyword wins, others still apply');
  Context.User := 'carol';
  Context.LocalPort := 2222;
  Effective := ConfigurationFor(Base, Context);
  Check((Effective.ForceCommand = '/bin/date') and (Effective.AllowTcpForwarding = ForwardingNone),
    'Match Group and LocalPort');
  Context.UserKnown := False;
  Context.User := '';
  Effective := ConfigurationFor(Base, Context);
  Check(Effective.PermitTty and (Effective.ForceCommand = '/bin/date'),
    'Match: before the user is known only LocalPort and Address apply');
  Check(ExpandAuthorizedKeysPath('%h/.ssh/keys_%u', '/home/al', 'al') = '/home/al/.ssh/keys_al',
    'AuthorizedKeysFile tokens');
end;

procedure TestAgentFraming;
var
  Reader: TSshAgentFrameReader;
  Message, Signature, Stream: string;
  Identities: TSshAgentIdentities;
  Index: Integer;
begin
  Stream := FrameAgentMessage(SshByte(AgentIdentitiesAnswer) + SshUInt32(1) + SshString('blob') + SshString('me')) +
    FrameAgentMessage(SshByte(AgentSignResponse) + SshString('sig'));
  Reader := Default(TSshAgentFrameReader);
  for Index := 1 to Length(Stream) - 1 do
    Reader.Append(Stream[Index]);
  Check(Reader.NextMessage(Message) and ParseIdentitiesAnswer(Message, Identities) and (Length(Identities) = 1) and
    (Identities[0].Blob = 'blob') and (Identities[0].Comment = 'me'), 'agent: an identities answer a byte at a time');
  Check(not Reader.NextMessage(Message), 'agent: a message not yet whole');
  Reader.Append(Stream[Length(Stream)]);
  Check(Reader.NextMessage(Message) and ParseSignResponse(Message, Signature) and (Signature = 'sig'),
    'agent: a sign response');
  CheckEqual(MakeSignRequest('k', 'd', AgentRsaSha512), SshUInt32(15) + #13 + SshString('k') + SshString('d') +
    SshUInt32(4), 'agent: a sign request');
end;

end.
