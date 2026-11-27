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
  What wget says, on error output, while libhttp connects and sends,
  in GNU wget's words:

    Resolving host... address, address
    Connecting to host|address|:port... connected.
    WARNING: cannot verify host's certificate: reason.
    Reusing existing connection to host:port.
    HTTP request sent, awaiting response...

  Nothing with -q.
}
unit Wget.Observer;

{$mode objfpc}
{$H+}

interface

uses
  Http.Observers;

type
  TWgetObserver = class(THttpClientObserver)
  private
    FQuiet: Boolean;
    FShowServerResponse: Boolean;
    FRequestSent: Boolean;
    procedure Say(const Text: string);
  public
    constructor Create(Quiet, ShowServerResponse: Boolean);
    procedure LookingUp(const Host: string); override;
    procedure LookedUp(const Host: string; const Addresses: array of string); override;
    procedure LookUpFailed(const Host, Reason: string); override;
    procedure Connecting(const Host, Address: string; Port: Word); override;
    procedure Connected; override;
    procedure ConnectFailed(const Reason: string); override;
    procedure ConnectingAlternative(const Host: string; Port: Word; const ProtocolId: string); override;
    procedure CertificateNotVerified(const Host, Reason: string); override;
    procedure ReusingConnection(const HostText: string; Port: Word); override;
    procedure RequestSent; override;
    procedure StaleConnection(AfterRequestSent: Boolean); override;
    { Starts a request: RequestWasSent says whether it got that far. }
    procedure BeginRequest;
    property RequestWasSent: Boolean read FRequestSent;
  end;

implementation

uses
  SysUtils,
  Sys.Streams;

constructor TWgetObserver.Create(Quiet, ShowServerResponse: Boolean);
begin
  inherited Create;
  FQuiet := Quiet;
  FShowServerResponse := ShowServerResponse;
end;

procedure TWgetObserver.Say(const Text: string);
begin
  if not FQuiet then
    PrintErrorString(Text);
end;

procedure TWgetObserver.LookingUp(const Host: string);
begin
  Say(Format('Resolving %s... ', [Host]));
end;

procedure TWgetObserver.LookedUp(const Host: string; const Addresses: array of string);
var
  Line: string;
  Index: Integer;
begin
  Line := '';
  for Index := 0 to High(Addresses) do
  begin
    if Index > 0 then
      Line := Line + ', ';
    Line := Line + Addresses[Index];
  end;
  Say(Line + #10);
end;

procedure TWgetObserver.LookUpFailed(const Host, Reason: string);
begin
  Say(Format('failed: %s.'#10, [Reason]));
end;

procedure TWgetObserver.Connecting(const Host, Address: string; Port: Word);
begin
  Say(Format('Connecting to %s|%s|:%d... ', [Host, Address, Port]));
end;

procedure TWgetObserver.Connected;
begin
  Say('connected.'#10);
end;

procedure TWgetObserver.ConnectFailed(const Reason: string);
begin
  Say(Format('failed: %s.'#10, [Reason]));
end;

procedure TWgetObserver.ConnectingAlternative(const Host: string; Port: Word; const ProtocolId: string);
var
  Name: string;
begin
  Name := ProtocolId;
  if ProtocolId = 'h3' then
    Name := 'HTTP/3';
  if Pos(':', Host) > 0 then
    Say(Format('Connecting to [%s]:%d over %s... ', [Host, Port, Name]))
  else
    Say(Format('Connecting to %s:%d over %s... ', [Host, Port, Name]));
end;

procedure TWgetObserver.CertificateNotVerified(const Host, Reason: string);
begin
  Say(Format('WARNING: cannot verify %s''s certificate: %s.'#10, [Host, Reason]));
end;

procedure TWgetObserver.ReusingConnection(const HostText: string; Port: Word);
begin
  Say(Format('Reusing existing connection to %s:%d.'#10, [HostText, Port]));
end;

procedure TWgetObserver.RequestSent;
begin
  FRequestSent := True;
  Say('HTTP request sent, awaiting response... ');
  { With -S the response's head follows on lines of its own, as GNU wget
    shows it. }
  if FShowServerResponse then
    Say(#10);
end;

procedure TWgetObserver.StaleConnection(AfterRequestSent: Boolean);
begin
  FRequestSent := False;
  if AfterRequestSent then
    Say(#10);
end;

procedure TWgetObserver.BeginRequest;
begin
  FRequestSent := False;
end;

end.
