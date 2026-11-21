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
  Local storage of the content process's pages, kept by the browser:
  an origin's pairs are asked for once, when a page first uses its
  storage, and every change is sent to the browser (which writes it to
  its files and refuses origins of other sites than this process's).
}
unit WebContent.Storage;

{$mode objfpc}
{$H+}

interface

uses
  Web.Storage,
  WebContent.Connection;

type
  TContentStorageBackend = class(TWebStorageBackend)
  private
    FConnection: TContentConnection;
  public
    constructor Create(Connection: TContentConnection);
    procedure LoadArea(const Origin: string; Area: TWebStorageArea); override;
    procedure ItemSet(const Origin, Key, Value: string); override;
    procedure ItemRemoved(const Origin, Key: string); override;
    procedure Cleared(const Origin: string); override;
  end;

implementation

uses
  WebIpc.Messages,
  WebIpc.ViewMessages,
  WebIpc.NetworkMessages;

const
  LoadTimeout = 10000;

constructor TContentStorageBackend.Create(Connection: TContentConnection);
begin
  inherited Create;
  FConnection := Connection;
end;

procedure TContentStorageBackend.LoadArea(const Origin: string; Area: TWebStorageArea);
var
  Answer: TIpcMessage;
  Pairs: TIpcStoragePairs;
  Index: Integer;
begin
  Answer := FConnection.Call(IpcStorageLoad, 0, EncodeText(Origin), LoadTimeout);
  if Answer = nil then
    Exit;
  try
    Pairs := DecodeStoragePairs(Answer.Payload);
  finally
    Answer.Free;
  end;
  for Index := 0 to High(Pairs.Keys) do
    Area.LoadPair(Pairs.Keys[Index], Pairs.Values[Index]);
end;

procedure TContentStorageBackend.ItemSet(const Origin, Key, Value: string);
begin
  FConnection.Send(IpcStorageSet, 0, EncodeStorageChange(Origin, Key, Value));
end;

procedure TContentStorageBackend.ItemRemoved(const Origin, Key: string);
begin
  FConnection.Send(IpcStorageRemove, 0, EncodeStorageChange(Origin, Key, ''));
end;

procedure TContentStorageBackend.Cleared(const Origin: string);
begin
  FConnection.Send(IpcStorageClear, 0, EncodeStorageChange(Origin, '', ''));
end;

end.
