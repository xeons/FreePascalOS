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
  The storage service behind IndexedDB, the Cache API and
  navigator.storage: every origin's databases, the connections and
  transactions on them, quotas and persistence.

  Where it runs: in the browser process (the network service hands it
  what content processes send), or in the program itself for a web view
  without separate processes, webbrowse and the tests. Either way a page
  reaches it only through TIndexedDbBackend.Execute with a request in
  the Web.IndexedDb.Wire format (built by platform/81-indexeddb-
  backend.js) and the origin its host decided, never one the page
  names. A TIndexedDbClient stands for one script context (a window
  and its workers): connections and transactions belong to it, and
  every request naming a connection or transaction of another client is
  refused, so a renderer cannot touch what another one holds.

  What the service decides itself (Indexed Database API 3.0):
  - opening (4.1 "open a database connection"): the version check, the
    upgrade transaction that holds the whole database, versionchange
    notices to the other connections (Notice, which the client delivers
    as an event in its own task) and waiting while they stay open; the
    page asks again until it gets the connection;
  - deleting a database the same way (4.2);
  - transaction scheduling between clients (2.7.2): a transaction
    starts only when no running transaction of the same database
    overlaps it with either being readwrite (or versionchange); the
    page asks again later otherwise;
  - atomic commit and abort (undo logs, Web.IndexedDb.Database);
  - quota: the bytes an origin's keys and values take, at most
    QuotaBytes (QuotaExceededError past it);
  - persistence: an origin with changes is written whole by SaveAll
    (the host calls it every few seconds and at the end); a service made
    without a folder keeps everything in memory (private windows).
}
unit Web.IndexedDb.Service;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Classes,
  Web.IndexedDb.Wire,
  Web.IndexedDb.Database;

const
  { Requests (the first byte). }
  IdbOpOpen = 1;
  IdbOpDeleteDatabase = 2;
  IdbOpDatabases = 3;
  IdbOpClose = 4;
  IdbOpBegin = 5;
  IdbOpCommit = 6;
  IdbOpAbort = 7;
  IdbOpCreateStore = 8;
  IdbOpDeleteStore = 9;
  IdbOpRenameStore = 10;
  IdbOpCreateIndex = 11;
  IdbOpDeleteIndex = 12;
  IdbOpRenameIndex = 13;
  IdbOpPopulateIndex = 14;
  IdbOpGenerateKey = 15;
  IdbOpPut = 16;
  IdbOpDelete = 17;
  IdbOpClear = 18;
  IdbOpGet = 19;
  IdbOpGetAll = 20;
  IdbOpCount = 21;
  IdbOpSeek = 22;
  IdbOpEstimate = 23;
  IdbOpPersist = 24;
  IdbOpPersisted = 25;

  { What an open, a delete or a begin led to (after IdbStatusOk). A
    wait of an open or delete says how many other connections are still
    open and the database's version. }
  IdbOutcomeDone = 1;
  IdbOutcomeUpgrade = 2;
  IdbOutcomeWait = 3;

  { Notices (the first byte). }
  IdbNoticeVersionChange = 1;
  { The connection was closed by the service (storage cleared). }
  IdbNoticeClosed = 2;

  TransactionReadOnly = 0;
  TransactionReadWrite = 1;
  TransactionVersionChange = 2;

  DefaultQuotaBytes = 512 * 1024 * 1024;

type
  { One script context as the service sees it. }
  TIndexedDbClient = class
  public
    { A notice for the context (a versionchange for one of its
      connections), called with the service locked and on any thread:
      deliver it later, in a task of the context's own. }
    procedure Notice(const Payload: TBytes); virtual; abstract;
  end;

  { What the page's natives talk to: the service itself or a way to it
    (a content process's channel to the browser). }
  TIndexedDbBackend = class
  public
    { The reply to Request for Origin (a serialized tuple origin). }
    function Execute(Client: TIndexedDbClient; const Origin: string; const Request: TBytes): TBytes; virtual; abstract;
    { Client's context is gone: its transactions abort, its
      connections close. }
    procedure ClientClosed(Client: TIndexedDbClient); virtual; abstract;
  end;

  TIdbOriginData = class;

  TIdbConnection = class
  public
    Id: LongWord;
    Client: TIndexedDbClient;
    Origin: TIdbOriginData;
    Database: TIdbDatabase;
  end;

  TIdbTransaction = class
  public
    Id: LongWord;
    Client: TIndexedDbClient;
    Connection: TIdbConnection;
    Mode: Byte;
    Scope: array of LongWord;
    Log: TIdbUndoLog;
    { The upgrade made the database (an abort removes it again). }
    CreatedDatabase: Boolean;
    destructor Destroy; override;
    function Covers(StoreId: LongWord): Boolean;
  end;

  { An open or delete waiting for other connections to close. }
  TIdbPending = class
  public
    Client: TIndexedDbClient;
    Token: LongWord;
    Origin: TIdbOriginData;
    Namespace: Byte;
    Name: RawByteString;
    Notified: Boolean;
  end;

  TIdbOriginData = class
  public
    Origin: string;
    FileName: string;
    Persisted: Boolean;
    Dirty: Boolean;
    Databases: TFPList;
    constructor Create;
    destructor Destroy; override;
    function Find(Namespace: Byte; const Name: RawByteString): TIdbDatabase;
    function Usage: Int64;
  end;

  TIndexedDbService = class(TIndexedDbBackend)
  private
    FLock: TRTLCriticalSection;
    FFolder: string;
    FOrigins: TStringList;
    FConnections: TFPList;
    FTransactions: TFPList;
    FPendings: TFPList;
    FNextId: LongWord;
    FQuotaBytes: Int64;
    function NewId: LongWord;
    function OriginData(const Origin: string): TIdbOriginData;
    function FindConnection(Client: TIndexedDbClient; Id: LongWord): TIdbConnection;
    function FindTransaction(Client: TIndexedDbClient; Id: LongWord): TIdbTransaction;
    function FindPending(Origin: TIdbOriginData; Namespace: Byte; const Name: RawByteString): TIdbPending;
    procedure DropPending(Pending: TIdbPending);
    function OthersOpen(Database: TIdbDatabase): Integer;
    function TransactionRunning(Database: TIdbDatabase): Boolean;
    function UpgradeRunning(Database: TIdbDatabase): Boolean;
    function OriginBusy(Origin: TIdbOriginData): Boolean;
    procedure SaveOrigin(Origin: TIdbOriginData);
    function AddConnection(Client: TIndexedDbClient; Origin: TIdbOriginData; Database: TIdbDatabase): TIdbConnection;
    procedure Wait(Client: TIndexedDbClient; Token: LongWord; Origin: TIdbOriginData; Database: TIdbDatabase;
      Pending: TIdbPending; NewVersion: Int64; Writer: TIdbWriter);
    function Conflicts(Transaction: TIdbTransaction; Database: TIdbDatabase; Mode: Byte;
      const Scope: array of LongWord): Boolean;
    procedure NotifyOthers(Database: TIdbDatabase; OldVersion, NewVersion: Int64);
    procedure WriteSchema(Writer: TIdbWriter; Database: TIdbDatabase);
    procedure FinishTransaction(Transaction: TIdbTransaction; Commit: Boolean);
    procedure RemoveDatabase(Origin: TIdbOriginData; Database: TIdbDatabase);
    procedure OpenDatabase(Client: TIndexedDbClient; Origin: TIdbOriginData; Reader: TIdbReader; Writer: TIdbWriter);
    procedure DeleteDatabase(Client: TIndexedDbClient; Origin: TIdbOriginData; Reader: TIdbReader;
      Writer: TIdbWriter);
    procedure ListDatabases(Origin: TIdbOriginData; Writer: TIdbWriter);
    procedure CloseConnection(Client: TIndexedDbClient; Reader: TIdbReader);
    procedure BeginTransaction(Client: TIndexedDbClient; Reader: TIdbReader; Writer: TIdbWriter);
    procedure ChangeSchema(Operation: Byte; Transaction: TIdbTransaction; Reader: TIdbReader; Writer: TIdbWriter);
    procedure RecordOperation(Operation: Byte; Transaction: TIdbTransaction; Reader: TIdbReader;
      Writer: TIdbWriter);
    procedure DispatchRequest(Client: TIndexedDbClient; Origin: TIdbOriginData; Reader: TIdbReader; Writer: TIdbWriter);
  public
    { Folder: where origins' files go ('' keeps everything in memory). }
    constructor Create(const AFolder: string);
    destructor Destroy; override;
    function Execute(Client: TIndexedDbClient; const Origin: string; const Request: TBytes): TBytes; override;
    procedure ClientClosed(Client: TIndexedDbClient); override;
    { Writes every origin that changed. }
    procedure SaveAll;
    { Forgets every origin's databases (and their files); connections
      stay but their databases are gone. }
    procedure ClearAll;
    { The bytes Origin's storage takes. }
    function Usage(const Origin: string): Int64;
    property Folder: string read FFolder;
    property QuotaBytes: Int64 read FQuotaBytes write FQuotaBytes;
  end;

{ The file an origin's storage is kept in (https://example.com:8443
  becomes https_example.com_8443.idb). }
function OriginStorageFileName(const Origin: string): string;

implementation

uses
  Math,
  Web.IndexedDb.Keys,
  Web.IndexedDb.Files,
  Web.IndexedDb.Operations;

function OriginStorageFileName(const Origin: string): string;
var
  Index: Integer;
begin
  Result := Origin;
  for Index := 1 to Length(Result) do
    if not (Result[Index] in ['a'..'z', 'A'..'Z', '0'..'9', '.', '-']) then
      Result[Index] := '_';
  Result := StringReplace(Result, '___', '_', []) + '.idb';
end;

{ TIdbTransaction }

destructor TIdbTransaction.Destroy;
begin
  Log.Free;
  inherited Destroy;
end;

function TIdbTransaction.Covers(StoreId: LongWord): Boolean;
var
  Position: Integer;
begin
  if Mode = TransactionVersionChange then
    Exit(True);
  for Position := 0 to High(Scope) do
    if Scope[Position] = StoreId then
      Exit(True);
  Result := False;
end;

{ TIdbOriginData }

constructor TIdbOriginData.Create;
begin
  inherited Create;
  Databases := TFPList.Create;
end;

destructor TIdbOriginData.Destroy;
var
  Position: Integer;
begin
  for Position := 0 to Databases.Count - 1 do
    TIdbDatabase(Databases[Position]).Free;
  Databases.Free;
  inherited Destroy;
end;

function TIdbOriginData.Find(Namespace: Byte; const Name: RawByteString): TIdbDatabase;
var
  Position: Integer;
begin
  for Position := 0 to Databases.Count - 1 do
  begin
    Result := TIdbDatabase(Databases[Position]);
    if (Result.Namespace = Namespace) and (Result.Name = Name) then
      Exit;
  end;
  Result := nil;
end;

function TIdbOriginData.Usage: Int64;
var
  Position: Integer;
begin
  Result := 0;
  for Position := 0 to Databases.Count - 1 do
    Result := Result + TIdbDatabase(Databases[Position]).Bytes;
end;

{ TIndexedDbService }

constructor TIndexedDbService.Create(const AFolder: string);
begin
  inherited Create;
  InitCriticalSection(FLock);
  FFolder := AFolder;
  FOrigins := TStringList.Create;
  FOrigins.Sorted := True;
  FOrigins.CaseSensitive := True;
  FOrigins.OwnsObjects := True;
  FConnections := TFPList.Create;
  FTransactions := TFPList.Create;
  FPendings := TFPList.Create;
  FQuotaBytes := DefaultQuotaBytes;
end;

destructor TIndexedDbService.Destroy;
var
  Position: Integer;
begin
  { Whatever did not commit is not kept. }
  Position := FTransactions.Count - 1;
  while Position >= 0 do
  begin
    FinishTransaction(TIdbTransaction(FTransactions[Position]), False);
    Position := FTransactions.Count - 1;
  end;
  SaveAll;
  for Position := 0 to FConnections.Count - 1 do
    TIdbConnection(FConnections[Position]).Free;
  for Position := 0 to FPendings.Count - 1 do
    TIdbPending(FPendings[Position]).Free;
  FConnections.Free;
  FTransactions.Free;
  FPendings.Free;
  FOrigins.Free;
  DoneCriticalSection(FLock);
  inherited Destroy;
end;

function TIndexedDbService.NewId: LongWord;
begin
  Inc(FNextId);
  if FNextId = 0 then
    FNextId := 1;
  Result := FNextId;
end;

function TIndexedDbService.OriginData(const Origin: string): TIdbOriginData;
var
  Position, Index: Integer;
  Contents: TIdbOriginContents;
begin
  if FOrigins.Find(Origin, Position) then
    Exit(TIdbOriginData(FOrigins.Objects[Position]));
  Result := TIdbOriginData.Create;
  Result.Origin := Origin;
  if FFolder <> '' then
  begin
    Result.FileName := IncludeTrailingPathDelimiter(FFolder) + OriginStorageFileName(Origin);
    if LoadOriginFile(Result.FileName, Contents) then
    begin
      Result.Persisted := Contents.Persisted;
      for Index := 0 to High(Contents.Databases) do
        Result.Databases.Add(Contents.Databases[Index]);
    end;
  end;
  FOrigins.AddObject(Origin, Result);
end;

function TIndexedDbService.FindConnection(Client: TIndexedDbClient; Id: LongWord): TIdbConnection;
var
  Position: Integer;
begin
  for Position := 0 to FConnections.Count - 1 do
  begin
    Result := TIdbConnection(FConnections[Position]);
    if (Result.Id = Id) and (Result.Client = Client) then
      Exit;
  end;
  raise EIdbFailure.CreateStatus(IdbStatusInvalidState, 'The database connection is closing.');
end;

function TIndexedDbService.FindTransaction(Client: TIndexedDbClient; Id: LongWord): TIdbTransaction;
var
  Position: Integer;
begin
  for Position := 0 to FTransactions.Count - 1 do
  begin
    Result := TIdbTransaction(FTransactions[Position]);
    if (Result.Id = Id) and (Result.Client = Client) then
      Exit;
  end;
  raise EIdbFailure.CreateStatus(IdbStatusAbort, 'The transaction is not active.');
end;

function TIndexedDbService.FindPending(Origin: TIdbOriginData; Namespace: Byte;
  const Name: RawByteString): TIdbPending;
var
  Position: Integer;
begin
  for Position := 0 to FPendings.Count - 1 do
  begin
    Result := TIdbPending(FPendings[Position]);
    if (Result.Origin = Origin) and (Result.Namespace = Namespace) and (Result.Name = Name) then
      Exit;
  end;
  Result := nil;
end;

procedure TIndexedDbService.DropPending(Pending: TIdbPending);
begin
  if Pending = nil then
    Exit;
  FPendings.Remove(Pending);
  Pending.Free;
end;

function TIndexedDbService.OthersOpen(Database: TIdbDatabase): Integer;
var
  Position: Integer;
begin
  Result := 0;
  for Position := 0 to FConnections.Count - 1 do
    if TIdbConnection(FConnections[Position]).Database = Database then
      Inc(Result);
end;

function TIndexedDbService.TransactionRunning(Database: TIdbDatabase): Boolean;
var
  Position: Integer;
begin
  for Position := 0 to FTransactions.Count - 1 do
    if TIdbTransaction(FTransactions[Position]).Connection.Database = Database then
      Exit(True);
  Result := False;
end;

function TIndexedDbService.Conflicts(Transaction: TIdbTransaction; Database: TIdbDatabase; Mode: Byte;
  const Scope: array of LongWord): Boolean;
var
  Position: Integer;
begin
  if Transaction.Connection.Database <> Database then
    Exit(False);
  if (Transaction.Mode = TransactionVersionChange) or (Mode = TransactionVersionChange) then
    Exit(True);
  if (Transaction.Mode = TransactionReadOnly) and (Mode = TransactionReadOnly) then
    Exit(False);
  for Position := 0 to High(Scope) do
    if Transaction.Covers(Scope[Position]) then
      Exit(True);
  Result := False;
end;

procedure TIndexedDbService.NotifyOthers(Database: TIdbDatabase; OldVersion, NewVersion: Int64);
var
  Position: Integer;
  Connection: TIdbConnection;
  Writer: TIdbWriter;
begin
  for Position := 0 to FConnections.Count - 1 do
  begin
    Connection := TIdbConnection(FConnections[Position]);
    if Connection.Database <> Database then
      Continue;
    Writer := TIdbWriter.Create;
    try
      Writer.WriteByte(IdbNoticeVersionChange);
      Writer.WriteLongWord(Connection.Id);
      Writer.WriteDouble(OldVersion);
      { -1: deleted (newVersion null). }
      Writer.WriteDouble(NewVersion);
      Connection.Client.Notice(Writer.Data);
    finally
      Writer.Free;
    end;
  end;
end;

procedure TIndexedDbService.WriteSchema(Writer: TIdbWriter; Database: TIdbDatabase);
var
  StorePosition, IndexPosition: Integer;
  Store: TIdbObjectStore;
  Index: TIdbIndex;
begin
  Writer.WriteLongWord(Database.StoreCount);
  for StorePosition := 0 to Database.StoreCount - 1 do
  begin
    Store := Database.Stores[StorePosition];
    Writer.WriteLongWord(Store.Id);
    Writer.WriteRaw(Store.Name);
    Writer.WriteBytes(Store.KeyPath);
    Writer.WriteBoolean(Store.AutoIncrement);
    Writer.WriteLongWord(Store.IndexCount);
    for IndexPosition := 0 to Store.IndexCount - 1 do
    begin
      Index := Store.Indexes[IndexPosition];
      Writer.WriteLongWord(Index.Id);
      Writer.WriteRaw(Index.Name);
      Writer.WriteBytes(Index.KeyPath);
      Writer.WriteBoolean(Index.Unique);
      Writer.WriteBoolean(Index.MultiEntry);
    end;
  end;
end;

procedure TIndexedDbService.RemoveDatabase(Origin: TIdbOriginData; Database: TIdbDatabase);
var
  Position: Integer;
begin
  Position := FConnections.Count - 1;
  while Position >= 0 do
  begin
    if TIdbConnection(FConnections[Position]).Database = Database then
    begin
      TIdbConnection(FConnections[Position]).Free;
      FConnections.Delete(Position);
    end;
    Dec(Position);
  end;
  Origin.Databases.Remove(Database);
  Database.Free;
  Origin.Dirty := True;
end;

procedure TIndexedDbService.FinishTransaction(Transaction: TIdbTransaction; Commit: Boolean);
var
  Database: TIdbDatabase;
  Origin: TIdbOriginData;
begin
  Database := Transaction.Connection.Database;
  Origin := Transaction.Connection.Origin;
  FTransactions.Remove(Transaction);
  Database.WatchLists(nil);
  if Commit then
  begin
    if Transaction.Log.Count > 0 then
      Origin.Dirty := True;
  end
  else
  begin
    Transaction.Log.Undo;
    if Transaction.CreatedDatabase then
    begin
      Transaction.Free;
      RemoveDatabase(Origin, Database);
      Exit;
    end;
  end;
  Transaction.Free;
end;


function TIndexedDbService.UpgradeRunning(Database: TIdbDatabase): Boolean;
var
  Position: Integer;
  Transaction: TIdbTransaction;
begin
  for Position := 0 to FTransactions.Count - 1 do
  begin
    Transaction := TIdbTransaction(FTransactions[Position]);
    if (Transaction.Connection.Database = Database) and (Transaction.Mode = TransactionVersionChange) then
      Exit(True);
  end;
  Result := False;
end;

function TIndexedDbService.AddConnection(Client: TIndexedDbClient; Origin: TIdbOriginData;
  Database: TIdbDatabase): TIdbConnection;
begin
  Result := TIdbConnection.Create;
  Result.Id := NewId;
  Result.Client := Client;
  Result.Origin := Origin;
  Result.Database := Database;
  FConnections.Add(Result);
end;

{ Waits for the connections still open (or for another request): the
  page asks again. }
procedure TIndexedDbService.Wait(Client: TIndexedDbClient; Token: LongWord; Origin: TIdbOriginData;
  Database: TIdbDatabase; Pending: TIdbPending; NewVersion: Int64; Writer: TIdbWriter);
var
  Others: Integer;
begin
  Others := OthersOpen(Database);
  if Pending = nil then
  begin
    Pending := TIdbPending.Create;
    Pending.Client := Client;
    Pending.Token := Token;
    Pending.Origin := Origin;
    Pending.Namespace := Database.Namespace;
    Pending.Name := Database.Name;
    FPendings.Add(Pending);
  end;
  if not Pending.Notified and (Others > 0) then
  begin
    Pending.Notified := True;
    NotifyOthers(Database, Database.Version, NewVersion);
  end;
  Writer.WriteByte(IdbOutcomeWait);
  Writer.WriteLongWord(Others);
  Writer.WriteDouble(Database.Version);
end;

procedure TIndexedDbService.OpenDatabase(Client: TIndexedDbClient; Origin: TIdbOriginData; Reader: TIdbReader;
  Writer: TIdbWriter);
var
  Namespace: Byte;
  Name: RawByteString;
  Requested: Double;
  Version, OldVersion: Int64;
  Token: LongWord;
  Pending: TIdbPending;
  Database: TIdbDatabase;
  Connection: TIdbConnection;
  Transaction: TIdbTransaction;
  Created: Boolean;
begin
  Namespace := Reader.ReadByte;
  Name := Reader.ReadRaw;
  Requested := Reader.ReadDouble;
  Token := Reader.ReadLongWord;
  if not (Requested >= 0) or (Requested > 9007199254740991.0) then
    raise EIdbMalformed.Create('version out of range');
  Pending := FindPending(Origin, Namespace, Name);
  if (Pending <> nil) and ((Pending.Client <> Client) or (Pending.Token <> Token)) then
  begin
    Writer.WriteByte(IdbOutcomeWait);
    Writer.WriteLongWord(0);
    Writer.WriteDouble(0);
    Exit;
  end;
  Database := Origin.Find(Namespace, Name);
  if (Database <> nil) and UpgradeRunning(Database) then
  begin
    Writer.WriteByte(IdbOutcomeWait);
    Writer.WriteLongWord(0);
    Writer.WriteDouble(0);
    Exit;
  end;
  if Database = nil then
    OldVersion := 0
  else
    OldVersion := Database.Version;
  Version := Trunc(Requested);
  if Version = 0 then
  begin
    if Database = nil then
      Version := 1
    else
      Version := OldVersion;
  end;
  if Version < OldVersion then
  begin
    DropPending(Pending);
    raise EIdbFailure.CreateStatus(IdbStatusVersion, 'The requested version (' + IntToStr(Version) +
      ') is less than the existing version (' + IntToStr(OldVersion) + ').');
  end;
  if (Database <> nil) and (Version = OldVersion) then
  begin
    DropPending(Pending);
    Connection := AddConnection(Client, Origin, Database);
    Writer.WriteByte(IdbOutcomeDone);
    Writer.WriteLongWord(Connection.Id);
    Writer.WriteDouble(Version);
    WriteSchema(Writer, Database);
    Exit;
  end;
  if (Database <> nil) and ((OthersOpen(Database) > 0) or TransactionRunning(Database)) then
  begin
    Wait(Client, Token, Origin, Database, Pending, Version, Writer);
    Exit;
  end;
  DropPending(Pending);
  Created := Database = nil;
  if Created then
  begin
    Database := TIdbDatabase.Create;
    Database.Namespace := Namespace;
    Database.Name := Name;
    Origin.Databases.Add(Database);
  end;
  Connection := AddConnection(Client, Origin, Database);
  Transaction := TIdbTransaction.Create;
  Transaction.Id := NewId;
  Transaction.Client := Client;
  Transaction.Connection := Connection;
  Transaction.Mode := TransactionVersionChange;
  Transaction.Log := TIdbUndoLog.Create(Database);
  Transaction.CreatedDatabase := Created;
  FTransactions.Add(Transaction);
  Transaction.Log.LogVersion(Database.Version);
  Database.Version := Version;
  Writer.WriteByte(IdbOutcomeUpgrade);
  Writer.WriteLongWord(Connection.Id);
  Writer.WriteLongWord(Transaction.Id);
  Writer.WriteDouble(OldVersion);
  Writer.WriteDouble(Version);
  WriteSchema(Writer, Database);
end;

procedure TIndexedDbService.DeleteDatabase(Client: TIndexedDbClient; Origin: TIdbOriginData; Reader: TIdbReader;
  Writer: TIdbWriter);
var
  Namespace: Byte;
  Name: RawByteString;
  Token: LongWord;
  Pending: TIdbPending;
  Database: TIdbDatabase;
  OldVersion: Int64;
begin
  Namespace := Reader.ReadByte;
  Name := Reader.ReadRaw;
  Token := Reader.ReadLongWord;
  Pending := FindPending(Origin, Namespace, Name);
  if (Pending <> nil) and ((Pending.Client <> Client) or (Pending.Token <> Token)) then
  begin
    Writer.WriteByte(IdbOutcomeWait);
    Writer.WriteLongWord(0);
    Writer.WriteDouble(0);
    Exit;
  end;
  Database := Origin.Find(Namespace, Name);
  if Database = nil then
  begin
    DropPending(Pending);
    Writer.WriteByte(IdbOutcomeDone);
    Writer.WriteDouble(0);
    Exit;
  end;
  if (OthersOpen(Database) > 0) or TransactionRunning(Database) then
  begin
    Wait(Client, Token, Origin, Database, Pending, -1, Writer);
    Exit;
  end;
  DropPending(Pending);
  OldVersion := Database.Version;
  RemoveDatabase(Origin, Database);
  Writer.WriteByte(IdbOutcomeDone);
  Writer.WriteDouble(OldVersion);
end;

procedure TIndexedDbService.ListDatabases(Origin: TIdbOriginData; Writer: TIdbWriter);
var
  Position, Count: Integer;
  Database: TIdbDatabase;
begin
  Count := 0;
  for Position := 0 to Origin.Databases.Count - 1 do
  begin
    Database := TIdbDatabase(Origin.Databases[Position]);
    if (Database.Namespace = 0) and (Database.Version > 0) then
      Inc(Count);
  end;
  Writer.WriteLongWord(Count);
  for Position := 0 to Origin.Databases.Count - 1 do
  begin
    Database := TIdbDatabase(Origin.Databases[Position]);
    if (Database.Namespace = 0) and (Database.Version > 0) then
    begin
      Writer.WriteRaw(Database.Name);
      Writer.WriteDouble(Database.Version);
    end;
  end;
end;

procedure TIndexedDbService.CloseConnection(Client: TIndexedDbClient; Reader: TIdbReader);
var
  Connection: TIdbConnection;
  Position: Integer;
begin
  Connection := FindConnection(Client, Reader.ReadLongWord);
  Position := FTransactions.Count - 1;
  while Position >= 0 do
  begin
    if TIdbTransaction(FTransactions[Position]).Connection = Connection then
      FinishTransaction(TIdbTransaction(FTransactions[Position]), False);
    Position := Min(Position - 1, FTransactions.Count - 1);
  end;
  { An aborted upgrade of a database it made took the connection along. }
  if FConnections.IndexOf(Connection) >= 0 then
  begin
    FConnections.Remove(Connection);
    Connection.Free;
  end;
end;

procedure TIndexedDbService.BeginTransaction(Client: TIndexedDbClient; Reader: TIdbReader; Writer: TIdbWriter);
var
  Connection: TIdbConnection;
  Mode: Byte;
  Count, Item: LongWord;
  Scope: array of LongWord;
  Position: Integer;
  Transaction: TIdbTransaction;
begin
  Connection := FindConnection(Client, Reader.ReadLongWord);
  Mode := Reader.ReadByte;
  if Mode > TransactionReadWrite then
    raise EIdbMalformed.Create('unknown transaction mode');
  Count := Reader.ReadLongWord;
  if Count > LongWord(Connection.Database.StoreCount) then
    raise EIdbFailure.CreateStatus(IdbStatusNotFound, 'One of the object stores was not found.');
  Scope := nil;
  SetLength(Scope, Count);
  Item := 0;
  while Item < Count do
  begin
    Scope[Item] := Reader.ReadLongWord;
    if Connection.Database.FindStore(Scope[Item]) = nil then
      raise EIdbFailure.CreateStatus(IdbStatusNotFound, 'One of the object stores was not found.');
    Inc(Item);
  end;
  for Position := 0 to FTransactions.Count - 1 do
    if Conflicts(TIdbTransaction(FTransactions[Position]), Connection.Database, Mode, Scope) then
    begin
      Writer.WriteByte(IdbOutcomeWait);
      Exit;
    end;
  Transaction := TIdbTransaction.Create;
  Transaction.Id := NewId;
  Transaction.Client := Client;
  Transaction.Connection := Connection;
  Transaction.Mode := Mode;
  Transaction.Scope := Scope;
  Transaction.Log := TIdbUndoLog.Create(Connection.Database);
  FTransactions.Add(Transaction);
  Writer.WriteByte(IdbOutcomeDone);
  Writer.WriteLongWord(Transaction.Id);
end;

function RequireStore(Database: TIdbDatabase; StoreId: LongWord): TIdbObjectStore;
begin
  Result := Database.FindStore(StoreId);
  if Result = nil then
    raise EIdbFailure.CreateStatus(IdbStatusNotFound, 'The object store was not found.');
end;

function RequireIndex(Store: TIdbObjectStore; IndexId: LongWord): TIdbIndex;
begin
  Result := Store.FindIndex(IndexId);
  if Result = nil then
    raise EIdbFailure.CreateStatus(IdbStatusNotFound, 'The index was not found.');
end;

procedure TIndexedDbService.ChangeSchema(Operation: Byte; Transaction: TIdbTransaction; Reader: TIdbReader;
  Writer: TIdbWriter);
var
  Database: TIdbDatabase;
  Store: TIdbObjectStore;
  Index: TIdbIndex;
  Name: RawByteString;
begin
  if Transaction.Mode <> TransactionVersionChange then
    raise EIdbFailure.CreateStatus(IdbStatusInvalidState, 'The database is not running a version change ' +
      'transaction.');
  Database := Transaction.Connection.Database;
  case Operation of
    IdbOpCreateStore:
      begin
        Name := Reader.ReadRaw;
        if Database.FindStoreNamed(Name) <> nil then
          raise EIdbFailure.CreateStatus(IdbStatusConstraint, 'An object store with the specified name already ' +
            'exists.');
        Store := TIdbObjectStore.Create;
        Store.Id := Database.NextStoreId;
        Database.NextStoreId := Database.NextStoreId + 1;
        Store.Name := Name;
        Store.KeyPath := Reader.ReadBytes;
        Store.AutoIncrement := Reader.ReadBoolean;
        Database.InsertStore(-1, Store);
        Transaction.Log.LogStoreCreated(Store);
        Writer.WriteLongWord(Store.Id);
      end;
    IdbOpDeleteStore:
      begin
        Store := RequireStore(Database, Reader.ReadLongWord);
        Transaction.Log.LogStoreDeleted(Store, Database.PositionOfStore(Store));
        Database.DetachStore(Store);
      end;
    IdbOpRenameStore:
      begin
        Store := RequireStore(Database, Reader.ReadLongWord);
        Name := Reader.ReadRaw;
        if Name = Store.Name then
          Exit;
        if Database.FindStoreNamed(Name) <> nil then
          raise EIdbFailure.CreateStatus(IdbStatusConstraint, 'An object store with the specified name already ' +
            'exists.');
        Transaction.Log.LogStoreRenamed(Store, Store.Name);
        Store.Name := Name;
      end;
    IdbOpCreateIndex:
      begin
        Store := RequireStore(Database, Reader.ReadLongWord);
        Name := Reader.ReadRaw;
        if Store.FindIndexNamed(Name) <> nil then
          raise EIdbFailure.CreateStatus(IdbStatusConstraint, 'An index with the specified name already exists.');
        Index := TIdbIndex.Create;
        Index.Id := Store.NextIndexId;
        Store.NextIndexId := Store.NextIndexId + 1;
        Index.Name := Name;
        Index.KeyPath := Reader.ReadBytes;
        Index.Unique := Reader.ReadBoolean;
        Index.MultiEntry := Reader.ReadBoolean;
        Store.InsertIndex(-1, Index);
        Database.AttachList(Index.Entries);
        Database.AttachList(Index.Reverse);
        Transaction.Log.LogIndexCreated(Store, Index);
        Writer.WriteLongWord(Index.Id);
      end;
    IdbOpDeleteIndex:
      begin
        Store := RequireStore(Database, Reader.ReadLongWord);
        Index := RequireIndex(Store, Reader.ReadLongWord);
        Transaction.Log.LogIndexDeleted(Store, Index, Store.PositionOfIndex(Index));
        Store.DetachIndex(Index);
      end;
    IdbOpRenameIndex:
      begin
        Store := RequireStore(Database, Reader.ReadLongWord);
        Index := RequireIndex(Store, Reader.ReadLongWord);
        Name := Reader.ReadRaw;
        if Name = Index.Name then
          Exit;
        if Store.FindIndexNamed(Name) <> nil then
          raise EIdbFailure.CreateStatus(IdbStatusConstraint, 'An index with the specified name already exists.');
        Transaction.Log.LogIndexRenamed(Index, Index.Name);
        Index.Name := Name;
      end;
    IdbOpPopulateIndex:
      begin
        Store := RequireStore(Database, Reader.ReadLongWord);
        Index := RequireIndex(Store, Reader.ReadLongWord);
        PopulateIndex(Index, Reader);
      end;
  end;
end;

procedure TIndexedDbService.RecordOperation(Operation: Byte; Transaction: TIdbTransaction; Reader: TIdbReader;
  Writer: TIdbWriter);
var
  Store: TIdbObjectStore;
  Index: TIdbIndex;
  IndexId: LongWord;
  Origin: TIdbOriginData;
begin
  Store := RequireStore(Transaction.Connection.Database, Reader.ReadLongWord);
  if not Transaction.Covers(Store.Id) then
    raise EIdbFailure.CreateStatus(IdbStatusNotFound, 'The object store is not in the transaction''s scope.');
  if (Operation in [IdbOpGenerateKey, IdbOpPut, IdbOpDelete, IdbOpClear]) and
    (Transaction.Mode = TransactionReadOnly) then
    raise EIdbFailure.CreateStatus(IdbStatusInvalidState, 'The transaction is read-only.');
  Index := nil;
  if Operation in [IdbOpGet, IdbOpGetAll, IdbOpCount, IdbOpSeek] then
  begin
    IndexId := Reader.ReadLongWord;
    if IndexId <> 0 then
      Index := RequireIndex(Store, IndexId);
  end;
  case Operation of
    IdbOpGenerateKey: GenerateKey(Store, Writer, Transaction.Log);
    IdbOpPut:
      begin
        Origin := Transaction.Connection.Origin;
        StoreRecord(Store, Reader, Transaction.Log, FQuotaBytes - Origin.Usage);
      end;
    IdbOpDelete: DeleteRecords(Store, ReadKeyRange(Reader));
    IdbOpClear: DeleteRecords(Store, UnboundedRange);
    IdbOpGet: RetrieveFirst(Store, Index, Reader, Writer);
    IdbOpGetAll: RetrieveAll(Store, Index, Reader, Writer);
    IdbOpCount: CountRecords(Store, Index, Reader, Writer);
    IdbOpSeek: IterateCursor(Store, Index, Reader, Writer);
  end;
end;

procedure TIndexedDbService.DispatchRequest(Client: TIndexedDbClient; Origin: TIdbOriginData; Reader: TIdbReader;
  Writer: TIdbWriter);
var
  Operation: Byte;
  Transaction: TIdbTransaction;
  Database: TIdbDatabase;
begin
  Operation := Reader.ReadByte;
  case Operation of
    IdbOpOpen: OpenDatabase(Client, Origin, Reader, Writer);
    IdbOpDeleteDatabase: DeleteDatabase(Client, Origin, Reader, Writer);
    IdbOpDatabases: ListDatabases(Origin, Writer);
    IdbOpClose: CloseConnection(Client, Reader);
    IdbOpBegin: BeginTransaction(Client, Reader, Writer);
    IdbOpCommit: FinishTransaction(FindTransaction(Client, Reader.ReadLongWord), True);
    IdbOpAbort: FinishTransaction(FindTransaction(Client, Reader.ReadLongWord), False);
    IdbOpCreateStore..IdbOpSeek:
      begin
        Transaction := FindTransaction(Client, Reader.ReadLongWord);
        if Transaction.Connection.Origin <> Origin then
          raise EIdbFailure.CreateStatus(IdbStatusSecurity, 'The transaction belongs to another origin.');
        Database := Transaction.Connection.Database;
        Database.WatchLists(Transaction.Log);
        try
          if Operation <= IdbOpPopulateIndex then
            ChangeSchema(Operation, Transaction, Reader, Writer)
          else
            RecordOperation(Operation, Transaction, Reader, Writer);
        finally
          Database.WatchLists(nil);
        end;
      end;
    IdbOpEstimate:
      begin
        Writer.WriteDouble(Origin.Usage);
        Writer.WriteDouble(FQuotaBytes);
      end;
    IdbOpPersist:
      begin
        if not Origin.Persisted then
        begin
          Origin.Persisted := True;
          Origin.Dirty := True;
        end;
        Writer.WriteBoolean(True);
      end;
    IdbOpPersisted: Writer.WriteBoolean(Origin.Persisted);
  else
    raise EIdbMalformed.Create('unknown IndexedDB request');
  end;
end;

function TIndexedDbService.Execute(Client: TIndexedDbClient; const Origin: string; const Request: TBytes): TBytes;
var
  Reader: TIdbReader;
  Body, Reply: TIdbWriter;
  Status: Byte;
  Message: string;
begin
  Status := IdbStatusOk;
  Message := '';
  Body := TIdbWriter.Create;
  Reader := TIdbReader.Create(Request);
  EnterCriticalSection(FLock);
  try
    try
      if (Origin = '') or (Origin = 'null') then
        raise EIdbFailure.CreateStatus(IdbStatusSecurity, 'Access to IndexedDB is denied in this context.');
      DispatchRequest(Client, OriginData(Origin), Reader, Body);
    except
      on Failure: EIdbFailure do
      begin
        Status := Failure.Status;
        Message := Failure.Message;
      end;
      on Malformed: EIdbMalformed do
      begin
        Status := IdbStatusUnknown;
        Message := Malformed.Message;
      end;
      on Error: Exception do
      begin
        Status := IdbStatusUnknown;
        Message := Error.Message;
      end;
    end;
  finally
    LeaveCriticalSection(FLock);
    Reader.Free;
  end;
  Reply := TIdbWriter.Create;
  try
    Reply.WriteByte(Status);
    if Status = IdbStatusOk then
    begin
      Result := Body.Data;
      Body.Free;
      Body := nil;
      Reply.WriteBytes(Result);
    end
    else
      Reply.WriteRaw(Message);
    Result := Reply.Data;
  finally
    Reply.Free;
    Body.Free;
  end;
end;

procedure TIndexedDbService.ClientClosed(Client: TIndexedDbClient);
var
  Position: Integer;
begin
  EnterCriticalSection(FLock);
  try
    Position := FTransactions.Count - 1;
    while Position >= 0 do
    begin
      if TIdbTransaction(FTransactions[Position]).Client = Client then
        FinishTransaction(TIdbTransaction(FTransactions[Position]), False);
      Position := Min(Position - 1, FTransactions.Count - 1);
    end;
    Position := FConnections.Count - 1;
    while Position >= 0 do
    begin
      if TIdbConnection(FConnections[Position]).Client = Client then
      begin
        TIdbConnection(FConnections[Position]).Free;
        FConnections.Delete(Position);
      end;
      Dec(Position);
    end;
    Position := FPendings.Count - 1;
    while Position >= 0 do
    begin
      if TIdbPending(FPendings[Position]).Client = Client then
      begin
        TIdbPending(FPendings[Position]).Free;
        FPendings.Delete(Position);
      end;
      Dec(Position);
    end;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TIndexedDbService.OriginBusy(Origin: TIdbOriginData): Boolean;
var
  Position: Integer;
  Transaction: TIdbTransaction;
begin
  for Position := 0 to FTransactions.Count - 1 do
  begin
    Transaction := TIdbTransaction(FTransactions[Position]);
    if (Transaction.Connection.Origin = Origin) and (Transaction.Log.Count > 0) then
      Exit(True);
  end;
  Result := False;
end;

procedure TIndexedDbService.SaveOrigin(Origin: TIdbOriginData);
var
  Contents: TIdbOriginContents;
  Position: Integer;
begin
  Contents := Default(TIdbOriginContents);
  Contents.Persisted := Origin.Persisted;
  SetLength(Contents.Databases, Origin.Databases.Count);
  for Position := 0 to Origin.Databases.Count - 1 do
    Contents.Databases[Position] := TIdbDatabase(Origin.Databases[Position]);
  if (Length(Contents.Databases) = 0) and not Origin.Persisted then
  begin
    if FileExists(Origin.FileName) then
      DeleteFile(Origin.FileName);
    Origin.Dirty := False;
  end
  else if SaveOriginFile(Origin.FileName, Contents) then
    Origin.Dirty := False;
end;

procedure TIndexedDbService.SaveAll;
var
  Position: Integer;
  Origin: TIdbOriginData;
begin
  EnterCriticalSection(FLock);
  try
    for Position := 0 to FOrigins.Count - 1 do
    begin
      Origin := TIdbOriginData(FOrigins.Objects[Position]);
      { Changes not committed yet are in the lists: the origin waits for
        the next save. }
      if Origin.Dirty and (Origin.FileName <> '') and not OriginBusy(Origin) then
        SaveOrigin(Origin);
    end;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure TIndexedDbService.ClearAll;
var
  Position: Integer;
  Connection: TIdbConnection;
  Writer: TIdbWriter;
  Found: TSearchRec;
  FolderPath: string;
begin
  EnterCriticalSection(FLock);
  try
    while FTransactions.Count > 0 do
      FinishTransaction(TIdbTransaction(FTransactions[FTransactions.Count - 1]), False);
    { Each connection is closed by force (its "close" event). }
    for Position := 0 to FConnections.Count - 1 do
    begin
      Connection := TIdbConnection(FConnections[Position]);
      Writer := TIdbWriter.Create;
      try
        Writer.WriteByte(IdbNoticeClosed);
        Writer.WriteLongWord(Connection.Id);
        Connection.Client.Notice(Writer.Data);
      finally
        Writer.Free;
      end;
      Connection.Free;
    end;
    FConnections.Clear;
    for Position := 0 to FPendings.Count - 1 do
      TIdbPending(FPendings[Position]).Free;
    FPendings.Clear;
    FOrigins.Clear;
    if FFolder <> '' then
    begin
      FolderPath := IncludeTrailingPathDelimiter(FFolder);
      if FindFirst(FolderPath + '*.idb', faAnyFile, Found) = 0 then
      begin
        repeat
          if (Found.Attr and faDirectory) = 0 then
            DeleteFile(FolderPath + Found.Name);
        until FindNext(Found) <> 0;
        FindClose(Found);
      end;
    end;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TIndexedDbService.Usage(const Origin: string): Int64;
begin
  EnterCriticalSection(FLock);
  try
    Result := OriginData(Origin).Usage;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

end.
