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
  libssh: the units of the SSH library (both sides), named here so that
  compiling this unit compiles them all.
}
unit Ssh.Contents;

{$mode objfpc}

interface

uses
  Ssh.Constants,
  Ssh.Wire,
  Ssh.Base64,
  Ssh.PacketCiphers,
  Ssh.ChaChaPolyCipher,
  Ssh.AesGcmCipher,
  Ssh.CipherSuites,
  Ssh.PacketLayer,
  Ssh.Algorithms,
  Ssh.KeyExchange,
  Ssh.KeyExchangeMethods,
  Ssh.HostKeys,
  Ssh.KeyFiles,
  Ssh.PublicKeys,
  Ssh.Transport,
  Ssh.ServerTransport,
  Ssh.ClientTransport,
  Ssh.AddressPatterns,
  Ssh.AuthorizedKeys,
  Ssh.Certificates,
  Ssh.AgentProtocol,
  Ssh.ClientIdentities,
  Ssh.ClientAuthentication,
  Ssh.KnownHosts,
  Ssh.PolledChannels,
  Ssh.HandleWriters,
  Ssh.SocketChannels,
  Ssh.UserAuthentication,
  Ssh.Connection,
  Ssh.TerminalOutput;

implementation

end.
