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
  The numbers and names of the SSH protocol: message numbers (RFC 4250
  section 4.1), disconnect reasons, channel open failures, extended data
  types, and the algorithm names this implementation speaks.
}
unit Ssh.Constants;

{$mode objfpc}{$H+}

interface

const
  { Transport layer generic (RFC 4253). }
  MessageDisconnect = 1;
  MessageIgnore = 2;
  MessageUnimplemented = 3;
  MessageDebug = 4;
  MessageServiceRequest = 5;
  MessageServiceAccept = 6;
  { RFC 8308. }
  MessageExtensionInformation = 7;
  { Algorithm negotiation. }
  MessageKeyExchangeInit = 20;
  MessageNewKeys = 21;
  { Key exchange method specific (curve25519-sha256: RFC 5656's ECDH
    messages). }
  MessageKeyExchangeEcdhInit = 30;
  MessageKeyExchangeEcdhReply = 31;
  FirstKeyExchangeMethodMessage = 30;
  LastKeyExchangeMethodMessage = 49;

  { User authentication (RFC 4252). }
  MessageUserAuthenticationRequest = 50;
  MessageUserAuthenticationFailure = 51;
  MessageUserAuthenticationSuccess = 52;
  MessageUserAuthenticationBanner = 53;
  { publickey: the key would do (RFC 4252 section 7). }
  MessageUserAuthenticationPublicKeyOk = 60;
  { keyboard-interactive (RFC 4256): the same numbers as PK_OK and the
    next, for another method. }
  MessageUserAuthenticationInfoRequest = 60;
  MessageUserAuthenticationInfoResponse = 61;

  { Connection protocol (RFC 4254). }
  MessageGlobalRequest = 80;
  MessageRequestSuccess = 81;
  MessageRequestFailure = 82;
  MessageChannelOpen = 90;
  MessageChannelOpenConfirmation = 91;
  MessageChannelOpenFailure = 92;
  MessageChannelWindowAdjust = 93;
  MessageChannelData = 94;
  MessageChannelExtendedData = 95;
  MessageChannelEof = 96;
  MessageChannelClose = 97;
  MessageChannelRequest = 98;
  MessageChannelSuccess = 99;
  MessageChannelFailure = 100;

  { Disconnect reasons. }
  DisconnectHostNotAllowedToConnect = 1;
  DisconnectProtocolError = 2;
  DisconnectKeyExchangeFailed = 3;
  DisconnectMacError = 5;
  DisconnectServiceNotAvailable = 7;
  DisconnectProtocolVersionNotSupported = 8;
  DisconnectHostKeyNotVerifiable = 9;
  DisconnectConnectionLost = 10;
  DisconnectByApplication = 11;
  DisconnectTooManyConnections = 12;
  DisconnectAuthenticationCancelledByUser = 13;
  DisconnectNoMoreAuthenticationMethods = 14;

  { Channel open failures. }
  OpenAdministrativelyProhibited = 1;
  OpenConnectFailed = 2;
  OpenUnknownChannelType = 3;
  OpenResourceShortage = 4;

  { Extended data: standard error. }
  ExtendedDataStandardError = 1;

  { Names. }
  ServiceUserAuthentication = 'ssh-userauth';
  ServiceConnection = 'ssh-connection';

  KeyExchangeCurve25519 = 'curve25519-sha256';
  KeyExchangeCurve25519LibSsh = 'curve25519-sha256@libssh.org';
  { Pseudo algorithms in the key exchange list: the client takes
    SSH_MSG_EXT_INFO (RFC 8308), and the strict key exchange that closes
    the Terrapin attack (OpenSSH's PROTOCOL, section 1.10). }
  ExtensionInformationClient = 'ext-info-c';
  StrictKeyExchangeClient = 'kex-strict-c-v00@openssh.com';
  StrictKeyExchangeServer = 'kex-strict-s-v00@openssh.com';

  HostKeyEd25519 = 'ssh-ed25519';
  HostKeyEcdsaP256 = 'ecdsa-sha2-nistp256';
  PublicKeyRsa = 'ssh-rsa';
  SignatureRsaSha256 = 'rsa-sha2-256';
  SignatureRsaSha512 = 'rsa-sha2-512';
  CurveNameP256 = 'nistp256';

  CipherChaCha20Poly1305 = 'chacha20-poly1305@openssh.com';
  CipherAes256Gcm = 'aes256-gcm@openssh.com';
  CipherAes128Gcm = 'aes128-gcm@openssh.com';
  CompressionNone = 'none';

  ExtensionServerSignatureAlgorithms = 'server-sig-algs';

implementation

end.
