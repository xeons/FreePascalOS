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
  The per-origin records of the content process's pages (the Cache
  API's caches, service worker registrations: Web.Storage.OriginData),
  kept by the browser: a record is asked for when an origin's store is
  first used, and the whole record is sent back after each change (the
  browser writes it and refuses origins of other sites than this
  process's). The sandbox lets the process write no file itself.
}
unit WebContent.OriginData;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Web.Storage.OriginData,
  WebContent.Connection;

type
  TContentOriginData = class(TOriginDataBackend)
  private
    FConnection: TContentConnection;
  public
    constructor Create(Connection: TContentConnection);
    function Load(const Kind, Origin: string): TBytes; override;
    procedure Save(const Kind, Origin: string; const Data: TBytes); override;
  end;

implementation

uses
  WebIpc.Messages,
  WebIpc.NetworkMessages;

const
  LoadTimeout = 10000;

constructor TContentOriginData.Create(Connection: TContentConnection);
begin
  inherited Create;
  FConnection := Connection;
end;

function TContentOriginData.Load(const Kind, Origin: string): TBytes;
var
  Answer: TIpcMessage;
begin
  Result := nil;
  Answer := FConnection.Call(IpcOriginDataLoad, 0, EncodeOriginData(Kind, Origin, nil), LoadTimeout);
  if Answer = nil then
    Exit;
  try
    Result := DecodeOriginDataRecord(Answer.Payload);
  finally
    Answer.Free;
  end;
end;

procedure TContentOriginData.Save(const Kind, Origin: string; const Data: TBytes);
begin
  FConnection.Send(IpcOriginDataSave, 0, EncodeOriginData(Kind, Origin, Data));
end;

end.
