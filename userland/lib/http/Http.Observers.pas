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
  What a client is doing, for a program that tells its user (wget's
  "Resolving...", "Connecting to...", "Reusing existing connection",
  "HTTP request sent, awaiting response..."), and the client's
  settings. Every method does nothing unless a program overrides it;
  they are called on the thread doing the request.

  Plain Pascal (the RTL only), checked on the host by tools/HttpTest.
}
unit Http.Observers;

{$mode objfpc}
{$H+}

interface

uses
  Tls.CipherSuites;

const
  DefaultClientUserAgent = 'FreePascalOS-libhttp/1.0';
  DefaultTimeoutMilliseconds = 60 * 1000;
  { A blocked UDP path costs this much once, then TCP for five minutes. }
  DefaultAltServiceTimeoutMilliseconds = 3000;

type
  THttpClientSettings = record
    { '' sends no User-Agent. }
    UserAgent: string;
    { Each wait on the server (connecting, reading); 0: no limit. }
    TimeoutMilliseconds: Int64;
    VerifyCertificates: Boolean;
    { A PEM file of trusted certificates instead of the system's. }
    HasTrustFile: Boolean;
    TrustFile: string;
    { Count 0: libtls's default. }
    CipherSuites: TCipherSuiteList;
    { Offer "h2" by ALPN over TLS. }
    AllowHttp2: Boolean;
    { Use HTTP/3 where an origin advertised it (Alt-Svc) and an "h3"
      connection factory is registered (libquic's EnableHttp3). }
    AllowHttp3: Boolean;
    { How long connecting to an alternative service (the QUIC
      handshake) may take before the origin's own connection is used. }
    AltServiceTimeoutMilliseconds: Int64;
    { '' sends none (and asks for identity); else the Accept-Encoding sent
      when a request does not set it. }
    AcceptEncoding: string;
    MaximumRedirects: Integer;
  end;

  THttpClientObserver = class
  public
    { A host name being looked up (not for numeric addresses). }
    procedure LookingUp(const Host: string); virtual;
    procedure LookedUp(const Host: string; const Addresses: array of string); virtual;
    procedure LookUpFailed(const Host, Reason: string); virtual;
    procedure Connecting(const Host, Address: string; Port: Word); virtual;
    procedure Connected; virtual;
    procedure ConnectFailed(const Reason: string); virtual;
    { A connection to an alternative service (ProtocolId "h3") the origin
      advertised; Connected or ConnectFailed follows (after a failure the
      origin's own connection is made). }
    procedure ConnectingAlternative(const Host: string; Port: Word; const ProtocolId: string); virtual;
    { With certificate checks off: what the check would have refused. }
    procedure CertificateNotVerified(const Host, Reason: string); virtual;
    { HostText has an IPv6 address in brackets. }
    procedure ReusingConnection(const HostText: string; Port: Word); virtual;
    procedure RequestSent; virtual;
    { A kept connection the server had closed; the request goes again on
      a new one. AfterRequestSent: RequestSent was told already. }
    procedure StaleConnection(AfterRequestSent: Boolean); virtual;
  end;

function DefaultClientSettings: THttpClientSettings;

implementation

uses
  Http.ContentDecoding,
  Http.Redirects;

function DefaultClientSettings: THttpClientSettings;
begin
  Result := Default(THttpClientSettings);
  Result.UserAgent := DefaultClientUserAgent;
  Result.TimeoutMilliseconds := DefaultTimeoutMilliseconds;
  Result.VerifyCertificates := True;
  Result.AllowHttp2 := True;
  Result.AllowHttp3 := True;
  Result.AltServiceTimeoutMilliseconds := DefaultAltServiceTimeoutMilliseconds;
  Result.AcceptEncoding := SupportedAcceptEncoding;
  Result.MaximumRedirects := DefaultMaximumRedirects;
end;

procedure THttpClientObserver.LookingUp(const Host: string);
begin
end;

procedure THttpClientObserver.LookedUp(const Host: string; const Addresses: array of string);
begin
end;

procedure THttpClientObserver.LookUpFailed(const Host, Reason: string);
begin
end;

procedure THttpClientObserver.Connecting(const Host, Address: string; Port: Word);
begin
end;

procedure THttpClientObserver.Connected;
begin
end;

procedure THttpClientObserver.ConnectFailed(const Reason: string);
begin
end;

procedure THttpClientObserver.ConnectingAlternative(const Host: string; Port: Word; const ProtocolId: string);
begin
end;

procedure THttpClientObserver.CertificateNotVerified(const Host, Reason: string);
begin
end;

procedure THttpClientObserver.ReusingConnection(const HostText: string; Port: Word);
begin
end;

procedure THttpClientObserver.RequestSent;
begin
end;

procedure THttpClientObserver.StaleConnection(AfterRequestSent: Boolean);
begin
end;

end.
